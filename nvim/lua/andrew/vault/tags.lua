local engine = require("andrew.vault.engine")

local M = {}

--- Collect all unique tags from the vault using ripgrep.
--- Finds inline #tags and frontmatter tags, deduplicates, and returns sorted.
---@param callback fun(tags: string[])
local function collect_tags(callback)
  -- Find inline #tags (excluding code blocks is hard with rg alone,
  -- but the pattern avoids common false positives like markdown headings
  -- by requiring no space after # and excluding lines starting with #)
  local inline_cmd = {
    "rg",
    "-o",
    "(?:^|\\s)#([a-zA-Z][a-zA-Z0-9_/-]+)",
    "--no-filename",
    "--no-line-number",
    "--replace", "$1",
    "--glob", "*.md",
    engine.vault_path,
  }

  -- Find frontmatter tags: lines like "  - tagname" that appear under "tags:"
  -- We use a multiline approach: find "tags:" sections in frontmatter
  -- Simpler: match YAML list items in frontmatter tag blocks
  local frontmatter_cmd = {
    "rg",
    "-U",
    "--no-filename",
    "--no-line-number",
    "-o",
    "^tags:\\n(\\s+- .+\\n?)+",
    "--glob", "*.md",
    engine.vault_path,
  }

  local seen = {}
  local tags = {}
  local pending = 2

  local function finish()
    pending = pending - 1
    if pending > 0 then
      return
    end
    table.sort(tags)
    vim.schedule(function()
      callback(tags)
    end)
  end

  local function add_tag(name)
    local trimmed = vim.trim(name)
    if trimmed ~= "" and not seen[trimmed] then
      seen[trimmed] = true
      tags[#tags + 1] = trimmed
    end
  end

  -- Inline tags
  vim.system(inline_cmd, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("Vault tags: inline tag search failed (rg exit " .. (result.code or "?") .. ")", vim.log.levels.WARN)
      end)
    elseif result.stdout and result.stdout ~= "" then
      for line in result.stdout:gmatch("[^\n]+") do
        add_tag(line)
      end
    end
    finish()
  end)

  -- Frontmatter tags
  vim.system(frontmatter_cmd, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("Vault tags: frontmatter tag search failed (rg exit " .. (result.code or "?") .. ")", vim.log.levels.WARN)
      end)
    elseif result.stdout and result.stdout ~= "" then
      for line in result.stdout:gmatch("[^\n]+") do
        -- Parse "  - tagname" lines, skip the "tags:" header itself
        local tag = line:match("^%s+-%s+(.+)$")
        if tag then
          -- Strip quotes if present (e.g., "tag" or 'tag')
          tag = tag:gsub("^[\"'](.+)[\"']$", "%1")
          add_tag(tag)
        end
      end
    end
    finish()
  end)
end

M.collect_tags = collect_tags

--- Show notes containing a specific tag using fzf-lua grep.
---@param tag string the tag name (without #)
function M.search_tag(tag)
  if not tag or tag == "" then
    vim.notify("Vault: no tag specified", vim.log.levels.WARN)
    return
  end

  local fzf = require("fzf-lua")
  -- Search for both inline #tag and frontmatter "- tag" occurrences
  local pattern = "#" .. fzf.utils.rg_escape(tag) .. "\\b|^\\s+- " .. fzf.utils.rg_escape(tag) .. "\\s*$"
  fzf.grep({
    search = pattern,
    cwd = engine.vault_path,
    no_esc = true,
    prompt = "Tag #" .. tag .. "> ",
    file_icons = true,
    git_icons = false,
    rg_opts = '--column --line-number --no-heading --color=always --smart-case --glob "*.md"',
  })
end

--- Two-step tag picker:
--- 1. Show all unique tags in the vault
--- 2. On selection, show all notes containing that tag
function M.tags()
  collect_tags(function(tags)
    if #tags == 0 then
      vim.notify("Vault: no tags found", vim.log.levels.INFO)
      return
    end

    local fzf = require("fzf-lua")
    fzf.fzf_exec(tags, {
      prompt = "Vault tags> ",
      actions = {
        ["default"] = function(selected)
          if selected and selected[1] then
            M.search_tag(selected[1])
          end
        end,
      },
    })
  end)
end

--- Add a tag to multiple notes at once.
--- Prompts for a tag name, then opens fzf-lua multi-select to pick notes.
--- Inserts the tag into each selected file's YAML frontmatter.
function M.add_tag()
  vim.ui.input({ prompt = "Tag to add: " }, function(tag)
    if not tag or vim.trim(tag) == "" then
      return
    end
    tag = vim.trim(tag)

    local fzf = require("fzf-lua")
    local fd_bin = vim.fn.executable("fd") == 1 and "fd"
      or vim.fn.executable("fdfind") == 1 and "fdfind"
      or nil
    if not fd_bin then
      vim.notify("Vault: fd/fdfind not found", vim.log.levels.ERROR)
      return
    end
    local cmd = fd_bin .. " --type f --extension md --base-directory " .. vim.fn.shellescape(engine.vault_path)

    fzf.fzf_exec(cmd, {
      prompt = "Add #" .. tag .. " to> ",
      cwd = engine.vault_path,
      fzf_opts = { ["--multi"] = "" },
      actions = {
        ["default"] = function(selected)
          if not selected or #selected == 0 then
            return
          end

          local updated = 0
          local modified_paths = {}
          for _, rel in ipairs(selected) do
            local clean = rel:gsub("^%./", "")
            local path = clean:match("^/") and clean or engine.vault_path .. "/" .. clean
            local file = io.open(path, "r")
            if file then
              local content = file:read("*a")
              file:close()

              local lines = {}
              for line in (content .. "\n"):gmatch("(.-)\n") do
                lines[#lines + 1] = line
              end
              -- Remove trailing empty line added by pattern
              if #lines > 0 and lines[#lines] == "" and not content:match("\n$") then
                lines[#lines] = nil
              end

              local new_lines = {}
              local modified = false

              -- Check if file has frontmatter
              if #lines > 0 and lines[1] == "---" then
                local fm_end = nil
                for i = 2, #lines do
                  if lines[i] == "---" then
                    fm_end = i
                    break
                  end
                end

                if fm_end then
                  -- Find existing tags: field
                  local tags_line = nil
                  for i = 2, fm_end - 1 do
                    if lines[i]:match("^tags:") then
                      tags_line = i
                      break
                    end
                  end

                  if tags_line then
                    -- Find last tag entry after tags_line
                    local insert_at = tags_line
                    for i = tags_line + 1, fm_end - 1 do
                      if lines[i]:match("^%s+%- ") then
                        insert_at = i
                      else
                        break
                      end
                    end
                    -- Check if tag already exists
                    local already = false
                    for i = tags_line + 1, insert_at do
                      local existing = lines[i]:match("^%s+-%s+(.+)$")
                      if existing then
                        existing = existing:gsub("^[\"'](.+)[\"']$", "%1")
                        if vim.trim(existing) == tag then
                          already = true
                          break
                        end
                      end
                    end
                    if not already then
                      for i = 1, insert_at do
                        new_lines[#new_lines + 1] = lines[i]
                      end
                      new_lines[#new_lines + 1] = "  - " .. tag
                      for i = insert_at + 1, #lines do
                        new_lines[#new_lines + 1] = lines[i]
                      end
                      modified = true
                    end
                  else
                    -- No tags: field — add before closing ---
                    for i = 1, fm_end - 1 do
                      new_lines[#new_lines + 1] = lines[i]
                    end
                    new_lines[#new_lines + 1] = "tags:"
                    new_lines[#new_lines + 1] = "  - " .. tag
                    for i = fm_end, #lines do
                      new_lines[#new_lines + 1] = lines[i]
                    end
                    modified = true
                  end
                end
              else
                -- No frontmatter — create one
                new_lines[#new_lines + 1] = "---"
                new_lines[#new_lines + 1] = "tags:"
                new_lines[#new_lines + 1] = "  - " .. tag
                new_lines[#new_lines + 1] = "---"
                for i = 1, #lines do
                  new_lines[#new_lines + 1] = lines[i]
                end
                modified = true
              end

              if modified then
                local out = io.open(path, "w")
                if out then
                  out:write(table.concat(new_lines, "\n"))
                  -- Preserve original trailing newline
                  if content:match("\n$") then
                    out:write("\n")
                  end
                  out:close()
                  updated = updated + 1
                  modified_paths[#modified_paths + 1] = path
                end
              end
            end
          end

          vim.schedule(function()
            -- Reload any open buffers whose files were modified
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_loaded(buf) then
                local bufname = vim.api.nvim_buf_get_name(buf)
                for _, abs in ipairs(modified_paths) do
                  if bufname == abs then
                    vim.api.nvim_buf_call(buf, function()
                      vim.cmd("edit!")
                    end)
                    break
                  end
                end
              end
            end
            vim.notify("Vault: added #" .. tag .. " to " .. updated .. " file(s)", vim.log.levels.INFO)
          end)
        end,
      },
    })
  end)
end

--- Remove a tag from all notes that contain it.
--- Shows available tags via fzf, then removes the selected tag from
--- both YAML frontmatter and inline #tag occurrences in every matching file.
function M.remove_tag()
  collect_tags(function(tags)
    if #tags == 0 then
      vim.notify("Vault: no tags found", vim.log.levels.INFO)
      return
    end

    local fzf = require("fzf-lua")
    fzf.fzf_exec(tags, {
      prompt = "Remove tag> ",
      actions = {
        ["default"] = function(selected)
          if not selected or not selected[1] then
            return
          end
          local tag = selected[1]

          -- Find all files containing this tag
          local rg_cmd = {
            "rg",
            "-l",
            "--glob", "*.md",
            "#" .. tag .. "\\b|^\\s+- \\s*" .. tag .. "\\s*$",
            engine.vault_path,
          }

          vim.system(rg_cmd, { text = true }, function(result)
            vim.schedule(function()
              local files = {}
              if result.stdout and result.stdout ~= "" then
                for line in result.stdout:gmatch("[^\n]+") do
                  if vim.trim(line) ~= "" then
                    files[#files + 1] = vim.trim(line)
                  end
                end
              end

              if #files == 0 then
                vim.notify("Vault: tag #" .. tag .. " not found in any files", vim.log.levels.INFO)
                return
              end

              local updated = 0
              for _, path in ipairs(files) do
                local file = io.open(path, "r")
                if file then
                  local content = file:read("*a")
                  file:close()

                  local lines = {}
                  for line in (content .. "\n"):gmatch("(.-)\n") do
                    lines[#lines + 1] = line
                  end
                  if #lines > 0 and lines[#lines] == "" and not content:match("\n$") then
                    lines[#lines] = nil
                  end

                  local new_lines = {}
                  local modified = false
                  local in_frontmatter = false
                  local in_tags_block = false
                  local fm_count = 0

                  for i, line in ipairs(lines) do
                    local skip = false

                    -- Track frontmatter boundaries
                    if line == "---" then
                      fm_count = fm_count + 1
                      if fm_count == 1 then
                        in_frontmatter = true
                      elseif fm_count == 2 then
                        in_frontmatter = false
                        in_tags_block = false
                      end
                    end

                    if in_frontmatter then
                      -- Detect tags: field
                      if line:match("^tags:") then
                        in_tags_block = true
                      elseif in_tags_block then
                        if line:match("^%s+%- ") then
                          -- Check if this is the tag to remove
                          local entry = line:match("^%s+-%s+(.+)$")
                          if entry then
                            entry = entry:gsub("^[\"'](.+)[\"']$", "%1")
                            if vim.trim(entry) == tag then
                              skip = true
                              modified = true
                            end
                          end
                        else
                          in_tags_block = false
                        end
                      end
                    end

                    if not skip then
                      -- Remove inline #tag occurrences outside frontmatter
                      if not in_frontmatter and fm_count >= 2 then
                        local cleaned = line:gsub("#" .. tag .. "(%f[%s%p%z])", "")
                        -- Also handle #tag at end of line
                        cleaned = cleaned:gsub("#" .. tag .. "$", "")
                        if cleaned ~= line then
                          -- Clean up extra whitespace left behind
                          cleaned = cleaned:gsub("%s+$", "")
                          modified = true
                          line = cleaned
                        end
                      end
                      new_lines[#new_lines + 1] = line
                    end
                  end

                  -- Clean up empty tags: field (tags: with no entries after it)
                  local final_lines = {}
                  for i, line in ipairs(new_lines) do
                    if line:match("^tags:%s*$") then
                      -- Check if next line is NOT a tag entry
                      local next_line = new_lines[i + 1]
                      if not next_line or not next_line:match("^%s+%- ") then
                        modified = true
                        -- skip this empty tags: line
                      else
                        final_lines[#final_lines + 1] = line
                      end
                    else
                      final_lines[#final_lines + 1] = line
                    end
                  end

                  if modified then
                    local out = io.open(path, "w")
                    if out then
                      out:write(table.concat(final_lines, "\n"))
                      if content:match("\n$") then
                        out:write("\n")
                      end
                      out:close()
                      updated = updated + 1
                    end
                  end
                end
              end

              -- Reload any open buffers whose files were modified
              for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_loaded(buf) then
                  local bufname = vim.api.nvim_buf_get_name(buf)
                  for _, path in ipairs(files) do
                    if bufname == path then
                      vim.api.nvim_buf_call(buf, function()
                        vim.cmd("edit!")
                      end)
                      break
                    end
                  end
                end
              end

              vim.notify(
                "Vault: removed #" .. tag .. " from " .. updated .. " file(s)",
                vim.log.levels.INFO
              )
            end)
          end)
        end,
      },
    })
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("VaultTags", function(opts)
    if opts.args and opts.args ~= "" then
      M.search_tag(opts.args)
    else
      M.tags()
    end
  end, {
    nargs = "?",
    desc = "Browse vault tags or search for a specific tag",
  })

  vim.keymap.set("n", "<leader>vft", function()
    M.tags()
  end, { desc = "Find: tags", silent = true })

  vim.api.nvim_create_user_command("VaultTagAdd", function()
    M.add_tag()
  end, {
    desc = "Add a tag to multiple vault notes",
  })

  vim.api.nvim_create_user_command("VaultTagRemove", function()
    M.remove_tag()
  end, {
    desc = "Remove a tag from all vault notes",
  })

  vim.keymap.set("n", "<leader>vga", function()
    M.add_tag()
  end, { desc = "Tag: add to notes", silent = true })

  vim.keymap.set("n", "<leader>vgr", function()
    M.remove_tag()
  end, { desc = "Tag: remove from notes", silent = true })
end

return M
