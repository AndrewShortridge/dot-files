local engine = require("andrew.vault.engine")

local M = {}

-- ---------------------------------------------------------------------------
-- Shared utilities
-- ---------------------------------------------------------------------------

local function current_note_path()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then
    return nil
  end
  local abs = vim.fn.fnamemodify(bufname, ":p")
  if not engine.is_vault_path(abs) then
    return nil
  end
  return abs
end

local function rg_escape(str)
  return str:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\])", "\\%1")
end

local function reload_open_buffers(modified_files)
  local set = {}
  for _, f in ipairs(modified_files) do
    set[f] = true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if set[name] then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("edit!")
        end)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- collect_rename_changes — gather all wikilink changes without applying them
-- Returns { changes = { {filename, lnum, old_text, new_text}, ... },
--           file_count = N, link_count = N }
-- ---------------------------------------------------------------------------

local function collect_rename_changes(old_name, new_name)
  local escaped = rg_escape(old_name)
  local pattern = "\\[\\[" .. escaped .. "(\\]\\]|\\|[^\\]]*\\]\\]|#[^\\]]*\\]\\])"
  local result = vim.system({
    "rg", "--files-with-matches", "--glob", "*.md", "--ignore-case",
    pattern, engine.vault_path,
  }):wait()

  local changes = {}
  local file_set = {}
  local link_count = 0

  if result.stdout and result.stdout ~= "" then
    for file_path in result.stdout:gmatch("[^\n]+") do
      local content = engine.read_file(file_path)
      if content then
        local lnum = 0
        for line in content:gmatch("([^\n]*)\n?") do
          lnum = lnum + 1
          -- Check whether this line contains a matching wikilink
          local new_line = line:gsub("%[%[(.-)%]%]", function(inner)
            local target = inner:match("^([^|#]+)") or inner
            target = vim.trim(target)
            if target:lower() == old_name:lower() then
              local suffix = inner:sub(#target + 1)
              link_count = link_count + 1
              return "[[" .. new_name .. suffix .. "]]"
            end
            return "[[" .. inner .. "]]"
          end)
          if new_line ~= line then
            changes[#changes + 1] = {
              filename = file_path,
              lnum = lnum,
              old_text = line,
              new_text = new_line,
            }
            file_set[file_path] = true
          end
        end
      end
    end
  end

  local file_count = 0
  for _ in pairs(file_set) do
    file_count = file_count + 1
  end

  return {
    changes = changes,
    file_count = file_count,
    link_count = link_count,
  }
end

-- ---------------------------------------------------------------------------
-- apply_rename_changes — write collected changes to disk
-- Returns list of modified file paths
-- ---------------------------------------------------------------------------

local function apply_rename_changes(old_name, new_name)
  local escaped = rg_escape(old_name)
  local pattern = "\\[\\[" .. escaped .. "(\\]\\]|\\|[^\\]]*\\]\\]|#[^\\]]*\\]\\])"
  local result = vim.system({
    "rg", "--files-with-matches", "--glob", "*.md", "--ignore-case",
    pattern, engine.vault_path,
  }):wait()

  local modified_files = {}
  local link_count = 0

  if result.stdout and result.stdout ~= "" then
    for file_path in result.stdout:gmatch("[^\n]+") do
      local content = engine.read_file(file_path)
      if content then
        local new_content = content:gsub("%[%[(.-)%]%]", function(inner)
          local target = inner:match("^([^|#]+)") or inner
          target = vim.trim(target)
          if target:lower() == old_name:lower() then
            local suffix = inner:sub(#target + 1)
            link_count = link_count + 1
            return "[[" .. new_name .. suffix .. "]]"
          end
          return "[[" .. inner .. "]]"
        end)
        if new_content ~= content then
          engine.write_file(file_path, new_content)
          modified_files[#modified_files + 1] = file_path
        end
      end
    end
  end

  return modified_files, link_count
end

-- ---------------------------------------------------------------------------
-- M.rename_preview — dry-run: populate quickfix list with pending changes
-- ---------------------------------------------------------------------------

function M.rename_preview(new_name)
  local old_name = engine.current_note_name()
  local old_path = current_note_path()
  if not old_name or not old_path then
    vim.notify("Vault: current buffer is not a vault note", vim.log.levels.WARN)
    return
  end

  local function do_preview(name)
    if not name or name == "" then
      return
    end
    if name == old_name then
      vim.notify("Vault: name unchanged", vim.log.levels.INFO)
      return
    end

    local info = collect_rename_changes(old_name, name)

    if #info.changes == 0 then
      vim.notify(
        "Vault: renaming '" .. old_name .. "' -> '" .. name .. "' would update 0 references",
        vim.log.levels.INFO
      )
      return
    end

    -- Build quickfix entries
    local qf_items = {}
    for _, c in ipairs(info.changes) do
      qf_items[#qf_items + 1] = {
        filename = c.filename,
        lnum = c.lnum,
        text = c.old_text .. "  ->  " .. c.new_text,
      }
    end

    vim.fn.setqflist({}, " ", {
      title = "Vault rename preview: '" .. old_name .. "' -> '" .. name
        .. "' (" .. info.link_count .. " links in " .. info.file_count .. " files)",
      items = qf_items,
    })
    vim.cmd("copen")

    vim.notify(
      "Vault: preview — renaming '" .. old_name .. "' -> '" .. name
        .. "' would update " .. info.link_count .. " links in " .. info.file_count .. " files",
      vim.log.levels.INFO
    )
  end

  if new_name and new_name ~= "" then
    do_preview(new_name)
  else
    engine.run(function()
      local name = engine.input({ prompt = "Preview rename '" .. old_name .. "' to: " })
      do_preview(name)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- M.rename — rename the current note and update all wikilinks (with confirm)
-- ---------------------------------------------------------------------------

function M.rename(new_name)
  local old_name = engine.current_note_name()
  local old_path = current_note_path()
  if not old_name or not old_path then
    vim.notify("Vault: current buffer is not a vault note", vim.log.levels.WARN)
    return
  end

  local function do_rename(name)
    if not name or name == "" then
      return
    end
    if name == old_name then
      vim.notify("Vault: name unchanged", vim.log.levels.INFO)
      return
    end

    local dir = vim.fn.fnamemodify(old_path, ":h")
    local new_path = dir .. "/" .. name .. ".md"

    if vim.fn.filereadable(new_path) == 1 then
      vim.notify("Vault: '" .. name .. ".md' already exists", vim.log.levels.ERROR)
      return
    end

    -- Collect changes for the confirmation summary
    local info = collect_rename_changes(old_name, name)

    -- Confirmation prompt
    local prompt = "Renaming '" .. old_name .. "' -> '" .. name .. "' will update "
      .. info.link_count .. " references in " .. info.file_count .. " files. Proceed? [y/N]: "
    local answer = engine.input({ prompt = prompt })
    if not answer or answer:lower() ~= "y" then
      vim.notify("Vault: rename cancelled", vim.log.levels.INFO)
      return
    end

    -- Save current buffer if modified
    if vim.bo.modified then
      vim.cmd("write")
    end

    -- Apply wikilink changes
    local modified_files, link_count = apply_rename_changes(old_name, name)

    -- Rename the file
    vim.fn.rename(old_path, new_path)

    -- Update current buffer to new file
    vim.cmd("edit " .. vim.fn.fnameescape(new_path))
    -- Delete the old buffer (it points to a file that no longer exists)
    local old_bufnr = vim.fn.bufnr(old_path)
    if old_bufnr ~= -1 and old_bufnr ~= vim.api.nvim_get_current_buf() then
      vim.api.nvim_buf_delete(old_bufnr, { force = true })
    end

    -- Reload any open buffers that were modified
    reload_open_buffers(modified_files)

    -- Invalidate wikilink cache
    require("andrew.vault.wikilinks").invalidate_cache()

    vim.notify(
      "Renamed '" .. old_name .. "' -> '" .. name .. "' (" .. link_count .. " links in " .. #modified_files .. " files)",
      vim.log.levels.INFO
    )
  end

  -- Always run inside a coroutine because we now need engine.input() for confirmation
  engine.run(function()
    local name = new_name
    if not name or name == "" then
      name = engine.input({ prompt = "Rename '" .. old_name .. "' to: " })
    end
    do_rename(name)
  end)
end

-- ---------------------------------------------------------------------------
-- M.tag_rename — rename a tag across the entire vault
-- ---------------------------------------------------------------------------

function M.tag_rename(old_tag, new_tag)
  local function do_tag_rename(otag, ntag)
    if not otag or otag == "" or not ntag or ntag == "" then
      return
    end
    if otag == ntag then
      vim.notify("Vault: tag unchanged", vim.log.levels.INFO)
      return
    end
    if not ntag:match("^[a-zA-Z][a-zA-Z0-9_/-]*$") then
      vim.notify("Vault: invalid tag name '" .. ntag .. "'", vim.log.levels.ERROR)
      return
    end

    -- Find files containing the tag (inline #tag or frontmatter - tag)
    local escaped = rg_escape(otag)
    local pattern = "#" .. escaped .. "(\\b|/)|^\\s+- " .. escaped .. "\\s*$"
    local result = vim.system({
      "rg", "--files-with-matches", "--glob", "*.md",
      pattern, engine.vault_path,
    }):wait()

    local modified_files = {}
    local replace_count = 0

    if result.stdout and result.stdout ~= "" then
      for file_path in result.stdout:gmatch("[^\n]+") do
        local content = engine.read_file(file_path)
        if not content then
          goto continue
        end

        local new_content = content
        local file_changed = false

        -- Replace inline tags: #oldtag -> #newtag
        -- Handle exact match and hierarchical children (#oldtag/sub -> #newtag/sub)
        -- Word boundary: must not match #oldtagSuffix (require end-of-word or /)
        new_content = new_content:gsub("(#)" .. otag:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\%-])", "%%%1") .. "([%s,;:%.%)%]}\n])", function(hash, after)
          replace_count = replace_count + 1
          file_changed = true
          return hash .. ntag .. after
        end)
        new_content = new_content:gsub("(#)" .. otag:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\%-])", "%%%1") .. "(/[a-zA-Z0-9_/-]*)", function(hash, suffix)
          replace_count = replace_count + 1
          file_changed = true
          return hash .. ntag .. suffix
        end)
        -- Handle inline tag at end of string (no trailing character)
        new_content = new_content:gsub("(#)" .. otag:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\%-])", "%%%1") .. "$", function(hash)
          replace_count = replace_count + 1
          file_changed = true
          return hash .. ntag
        end)

        -- Replace frontmatter tags
        -- Match the frontmatter block and replace within it
        new_content = new_content:gsub("^(%-%-%-\n.-)(\n%-%-%-)", function(fm, closing)
          local new_fm = fm:gsub("(\n%s+%- )" .. otag:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\%-])", "%%%1") .. "(%s*\n)", function(prefix, suffix)
            replace_count = replace_count + 1
            file_changed = true
            return prefix .. ntag .. suffix
          end)
          -- Handle last item (might not have trailing newline before ---)
          new_fm = new_fm:gsub("(\n%s+%- )" .. otag:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\%-])", "%%%1") .. "(%s*)$", function(prefix, suffix)
            replace_count = replace_count + 1
            file_changed = true
            return prefix .. ntag .. suffix
          end)
          -- Handle inline YAML array: [tag1, tag2]
          new_fm = new_fm:gsub("(%[)(.-)(%])", function(open, inner, close)
            local new_inner = inner:gsub("(%s*)" .. otag:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\%-])", "%%%1") .. "(%s*[,%]]?)", function(before, after)
              -- Only count if this is the exact tag, not a prefix
              local rest = after:match("^%s*[,%]]") or after == ""
              if rest or after == "" then
                replace_count = replace_count + 1
                file_changed = true
                return before .. ntag .. after
              end
              return before .. otag .. after
            end)
            return open .. new_inner .. close
          end)
          return new_fm .. closing
        end)

        if file_changed then
          engine.write_file(file_path, new_content)
          modified_files[#modified_files + 1] = file_path
        end

        ::continue::
      end
    end

    reload_open_buffers(modified_files)

    vim.notify(
      "Renamed tag #" .. otag .. " -> #" .. ntag .. " (" .. replace_count .. " occurrences in " .. #modified_files .. " files)",
      vim.log.levels.INFO
    )
  end

  if old_tag and old_tag ~= "" and new_tag and new_tag ~= "" then
    do_tag_rename(old_tag, new_tag)
  elseif old_tag and old_tag ~= "" then
    engine.run(function()
      local ntag = engine.input({ prompt = "Rename #" .. old_tag .. " to: #" })
      do_tag_rename(old_tag, ntag)
    end)
  else
    -- No args: show fzf-lua tag picker first
    require("andrew.vault.tags").collect_tags(function(tags)
      if #tags == 0 then
        vim.notify("Vault: no tags found", vim.log.levels.INFO)
        return
      end
      local fzf = require("fzf-lua")
      fzf.fzf_exec(tags, {
        prompt = "Rename tag> ",
        actions = {
          ["default"] = function(selected)
            if selected and selected[1] then
              local otag = selected[1]
              engine.run(function()
                local ntag = engine.input({ prompt = "Rename #" .. otag .. " to: #" })
                do_tag_rename(otag, ntag)
              end)
            end
          end,
        },
      })
    end)
  end
end

-- ---------------------------------------------------------------------------
-- M.setup — register commands and keybindings
-- ---------------------------------------------------------------------------

function M.setup()
  vim.api.nvim_create_user_command("VaultRename", function(opts)
    local arg = opts.args and opts.args ~= "" and opts.args or nil
    M.rename(arg)
  end, {
    nargs = "?",
    desc = "Rename current note and update all wikilinks (with confirmation)",
  })

  vim.api.nvim_create_user_command("VaultRenamePreview", function(opts)
    local arg = opts.args and opts.args ~= "" and opts.args or nil
    M.rename_preview(arg)
  end, {
    nargs = "?",
    desc = "Preview rename: show all wikilink changes in the quickfix list",
  })

  vim.api.nvim_create_user_command("VaultTagRename", function(opts)
    local args = vim.split(opts.args or "", "%s+", { trimempty = true })
    M.tag_rename(args[1], args[2])
  end, {
    nargs = "*",
    desc = "Rename a tag across the vault",
  })

  local group = vim.api.nvim_create_augroup("VaultRename", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>ver", function()
        M.rename()
      end, { buffer = ev.buf, desc = "Edit: rename note", silent = true })

      vim.keymap.set("n", "<leader>veR", function()
        M.rename_preview()
      end, { buffer = ev.buf, desc = "Edit: preview rename (dry-run)", silent = true })

      vim.keymap.set("n", "<leader>vet", function()
        M.tag_rename()
      end, { buffer = ev.buf, desc = "Edit: rename tag", silent = true })
    end,
  })
end

return M
