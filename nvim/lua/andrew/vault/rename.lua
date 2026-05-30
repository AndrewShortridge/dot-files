local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local link_utils = require("andrew.vault.link_utils")
local cleanup = require("andrew.vault.resource_cleanup")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("rename")
local semaphore = require("andrew.vault.process_semaphore")
local pat = require("andrew.vault.patterns")

local M = {}

local function notify_name_unchanged()
  notify.info("name unchanged")
end

-- ---------------------------------------------------------------------------
-- Shared utilities
-- ---------------------------------------------------------------------------

local function current_note_path()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then
    return nil
  end
  local abs = vim.fn.fnamemodify(bufname, ":p")
  if not engine.is_vault_buf(0) then
    return nil
  end
  return abs
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
-- Discovery: find files containing links to a given note
-- ---------------------------------------------------------------------------

--- Discover linking files using the vault index (O(1) lookup).
--- Returns nil if the index is not available (caller should fall back to rg).
---@param old_name string  Note basename without extension
---@param old_path string  Absolute path of the note
---@return string[]|nil
local function discover_from_index(old_name, old_path)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    return nil
  end

  local rel_path = engine.vault_relative(old_path)
  if not rel_path then
    log.debug("discover_from_index: vault_relative returned nil for %s", old_path)
    return nil
  end

  local source_set = {}

  -- Get files that link to this note (by resolved path)
  local inlinks = idx:get_inlinks(rel_path)
  for _, inlink in ipairs(inlinks) do
    local source_rel = inlink.path .. ".md"
    local source_entry = idx:get_entry(source_rel)
    if source_entry then
      source_set[source_entry.abs_path] = true
    end
  end

  -- Check for self-references (note linking to itself)
  local self_entry = idx:get_entry(rel_path)
  if self_entry then
    for _, link in ipairs(self_entry.outlinks) do
      local target = link.path or ""
      target = target:match("^([^#^|]+)") or target
      target = vim.trim(target)
      if target:lower() == old_name:lower() then
        source_set[old_path] = true
        break
      end
    end
  end

  local result = {}
  for path in pairs(source_set) do
    result[#result + 1] = path
  end
  return result
end

--- Discover linking files using ripgrep (fallback, async).
---@param old_name string  Note basename without extension
---@param callback fun(files: string[])
local function discover_from_rg(old_name, callback)
  local escaped = engine.rg_escape(old_name)
  -- Match [[name]], [[name|...]], [[name#...]], [[name^...]]
  local pattern = "\\[\\[" .. escaped .. "(\\]\\]|\\|[^\\]]*\\]\\]|#[^\\]]*\\]\\]|\\^[^\\]]*\\]\\])"
  semaphore.acquire(semaphore.rg_semaphore(), function(release)
    vim.system({
      "rg", "--files-with-matches", "--glob", "*.md", "--ignore-case",
      pattern, engine.vault_path,
    }, { text = true }, function(result)
      release()
      vim.schedule(function()
        local files = {}
        if result.stdout and result.stdout ~= "" then
          for file_path in result.stdout:gmatch(pat.LINE_NONEMPTY) do
            files[#files + 1] = file_path
          end
        end
        callback(files)
      end)
    end)
  end)
end

--- Build the set of names to match during rewriting.
--- Includes the basename and any aliases from the vault index.
---@param old_name string  Note basename without extension
---@param old_path string  Absolute path of the note
---@return table<string, true>  Lowercase name set
local function build_old_name_set(old_name, old_path)
  local names = { [old_name:lower()] = true }

  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local entry = idx:get_entry_by_abs(old_path)
    if entry then
      for _, alias in ipairs(entry.aliases) do
        names[alias] = true  -- already lowercased in the index
      end
    end
  end

  return names
end

-- ---------------------------------------------------------------------------
-- collect_rename_changes — gather all wikilink changes without applying them
-- Returns { changes = { {filename, lnum, old_text, new_text}, ... },
--           file_count = N, link_count = N }
-- ---------------------------------------------------------------------------

--- Phase 2 of rename: given a list of linking files, compute all changes.
---@param linking_files string[]
---@param old_name string
---@param new_name string
---@param old_path string
---@return table
local function compute_rename_changes(linking_files, old_name, new_name, old_path)
  local old_names = build_old_name_set(old_name, old_path)
  local changes = {}
  local file_set = {}
  local link_count = 0
  local file_writes = {}

  for _, file_path in ipairs(linking_files) do
    local content, read_err = engine.read_file(file_path)
    if not content then
      log.debug("skipping file: %s", read_err or "read failed")
      goto continue
    end

    local new_content_lines = {}
    local file_changed = false
    local lnum = 0

    for line in content:gmatch(pat.LINE_WITH_NEWLINE) do
      lnum = lnum + 1
      local new_line = line:gsub(link_utils.WIKILINK_PAT, function(inner)
        local target = inner:match("^([^|#^]+)") or inner
        target = vim.trim(target)
        if old_names[target:lower()] then
          local suffix = inner:sub(#target + 1)
          link_count = link_count + 1
          return "[[" .. new_name .. suffix .. "]]"
        end
        return "[[" .. inner .. "]]"
      end)
      new_content_lines[#new_content_lines + 1] = new_line
      if new_line ~= line then
        changes[#changes + 1] = {
          filename = file_path,
          lnum = lnum,
          old_text = line,
          new_text = new_line,
        }
        file_set[file_path] = true
        file_changed = true
      end
    end

    if file_changed then
      file_writes[file_path] = table.concat(new_content_lines, "\n")
    end

    ::continue::
  end

  local file_count = 0
  for _ in pairs(file_set) do
    file_count = file_count + 1
  end

  return {
    changes = changes,
    file_count = file_count,
    link_count = link_count,
    file_writes = file_writes,
  }
end

--- Collect all rename changes (async when index is unavailable).
---@param old_name string
---@param new_name string
---@param old_path string
---@param callback fun(info: table)
local function collect_rename_changes(old_name, new_name, old_path, callback)
  -- Phase 1: Discovery
  local linking_files = discover_from_index(old_name, old_path)
  if linking_files then
    -- Index available: compute synchronously and call back immediately
    callback(compute_rename_changes(linking_files, old_name, new_name, old_path))
  else
    -- Fall back to async ripgrep
    discover_from_rg(old_name, function(files)
      callback(compute_rename_changes(files, old_name, new_name, old_path))
    end)
  end
end

-- ---------------------------------------------------------------------------
-- apply_rename_changes — write pre-computed content from collect_rename_changes
-- Returns list of modified file paths and link count
-- ---------------------------------------------------------------------------

local function apply_rename_changes(info)
  local modified_files = {}
  for path, new_content in pairs(info.file_writes) do
    if engine.write_file(path, new_content) then
      modified_files[#modified_files + 1] = path
    else
      log.debug("apply_rename_changes: failed to write %s", path)
    end
  end
  return modified_files, info.link_count
end

-- ---------------------------------------------------------------------------
-- M.rename_preview — dry-run: populate quickfix list with pending changes
-- ---------------------------------------------------------------------------

function M.rename_preview(new_name)
  local old_name = engine.current_note_name()
  local old_path = current_note_path()
  if not old_name or not old_path then
    notify.not_vault_file()
    return
  end

  local function do_preview(name)
    if not name or name == "" then
      return
    end
    if name == old_name then
      notify_name_unchanged()
      return
    end

    collect_rename_changes(old_name, name, old_path, function(info)
      if #info.changes == 0 then
        notify.info("renaming '" .. old_name .. "' -> '" .. name .. "' would update 0 references")
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

      notify.info(
        "preview — renaming '" .. old_name .. "' -> '" .. name
          .. "' would update " .. info.link_count .. " links in " .. info.file_count .. " files"
      )
    end)
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
    notify.not_vault_file()
    return
  end

  local function do_rename(name)
    if not name or name == "" then
      return
    end
    if name == old_name then
      notify_name_unchanged()
      return
    end

    local dir = link_utils.lua_dirname(old_path)
    local new_path = dir .. "/" .. name .. ".md"

    if vim.fn.filereadable(new_path) == 1 then
      notify.warn("'" .. name .. ".md' already exists")
      return
    end

    -- Collect changes for the confirmation summary (async when index unavailable)
    collect_rename_changes(old_name, name, old_path, function(info)
      -- Confirm via select dialog — needs a coroutine for engine.select()
      engine.run(function()
        local confirm_prompt = "Rename '" .. old_name .. "' -> '" .. name
          .. "' (" .. info.link_count .. " refs in " .. info.file_count .. " files)"
        local choice = engine.select({ "Yes", "No" }, { prompt = confirm_prompt })
        if choice ~= "Yes" then
          notify.info("rename cancelled")
          return
        end

        -- Save current buffer if modified
        if vim.bo.modified then
          vim.cmd("write")
        end

        -- Apply wikilink changes
        local modified_files, link_count = apply_rename_changes(info)

        -- Rename the file
        vim.fn.rename(old_path, new_path)

        -- Update current buffer to new file
        vim.cmd("edit " .. vim.fn.fnameescape(new_path))
        -- Delete the old buffer (it points to a file that no longer exists)
        local old_bufnr = vim.fn.bufnr(old_path)
        if old_bufnr ~= -1 and old_bufnr ~= vim.api.nvim_get_current_buf() then
          cleanup.delete_buf(old_bufnr)
        end

        -- Reload any open buffers that were modified
        reload_open_buffers(modified_files)

        -- Update vault index: remove old path, add new path, re-index modified files
        local idx = vault_index.current()
        if idx and idx:is_ready() then
          idx:update_files_batch({ old_path, new_path })
          -- Batch re-index all files whose outlinks were rewritten
          local reindex_paths = {}
          for _, path in ipairs(modified_files) do
            if path ~= old_path and path ~= new_path then
              reindex_paths[#reindex_paths + 1] = path
            end
          end
          if #reindex_paths > 0 then
            idx:update_files_batch(reindex_paths)
          end
          idx:persist_now()
        end

        notify.info(
          "renamed '" .. old_name .. "' -> '" .. name .. "' (" .. link_count .. " links in " .. #modified_files .. " files)"
        )
      end)
    end)
  end

  -- Run inside a coroutine for engine.input() support
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
      notify.info("tag unchanged")
      return
    end
    if not ntag:match("^[a-zA-Z][a-zA-Z0-9_/-]*$") then
      notify.warn("invalid tag name '" .. ntag .. "'")
      return
    end

    -- Find files containing the tag (inline #tag or frontmatter - tag)
    local escaped = engine.rg_escape(otag)
    local pattern = "#" .. escaped .. "(\\b|/)|^\\s+- " .. escaped .. "\\s*$"
    semaphore.acquire(semaphore.rg_semaphore(), function(release)
      vim.system({
        "rg", "--files-with-matches", "--glob", "*.md",
        pattern, engine.vault_path,
      }, { text = true }, function(result)
        release()
        vim.schedule(function()
          local modified_files = {}
          local replace_count = 0

          -- Pre-escape tag name once for all pattern constructions
          local escaped_otag = vim.pesc(otag)

        if result.stdout and result.stdout ~= "" then
          for file_path in result.stdout:gmatch(pat.LINE_NONEMPTY) do
            local content, read_err = engine.read_file(file_path)
            if not content then
              log.debug("skipping file: %s", read_err or "read failed")
              goto continue
            end

            local new_content = content
            local file_changed = false

            -- Replace inline tags: #oldtag -> #newtag
            -- Handle exact match and hierarchical children (#oldtag/sub -> #newtag/sub)
            -- Word boundary: must not match #oldtagSuffix (require end-of-word or /)
            new_content = new_content:gsub("(#)" .. escaped_otag .. "([%s,;:%.%)%]}\n])", function(hash, after)
              replace_count = replace_count + 1
              file_changed = true
              return hash .. ntag .. after
            end)
            new_content = new_content:gsub("(#)" .. escaped_otag .. "(/[a-zA-Z0-9_/-]*)", function(hash, suffix)
              replace_count = replace_count + 1
              file_changed = true
              return hash .. ntag .. suffix
            end)
            -- Handle inline tag at end of string (no trailing character)
            new_content = new_content:gsub("(#)" .. escaped_otag .. "$", function(hash)
              replace_count = replace_count + 1
              file_changed = true
              return hash .. ntag
            end)

            -- Replace frontmatter tags
            -- Match the frontmatter block and replace within it
            new_content = new_content:gsub("^(%-%-%-\n.-)(\n%-%-%-)", function(fm, closing)
              local new_fm = fm:gsub("(\n%s+%- )" .. escaped_otag .. "(%s*\n)", function(prefix, suffix)
                replace_count = replace_count + 1
                file_changed = true
                return prefix .. ntag .. suffix
              end)
              -- Handle last item (might not have trailing newline before ---)
              new_fm = new_fm:gsub("(\n%s+%- )" .. escaped_otag .. "(%s*)$", function(prefix, suffix)
                replace_count = replace_count + 1
                file_changed = true
                return prefix .. ntag .. suffix
              end)
              -- Handle inline YAML array: [tag1, tag2]
              new_fm = new_fm:gsub("(%[)(.-)(%])", function(open, inner, close)
                local new_inner = inner:gsub("(%s*)" .. escaped_otag .. "(%s*[,%]]?)", function(before, after)
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
              if engine.write_file(file_path, new_content) then
                modified_files[#modified_files + 1] = file_path
              else
                log.debug("tag_rename: failed to write %s", file_path)
              end
            end

            ::continue::
          end
        end

        reload_open_buffers(modified_files)

        notify.info(
          "renamed tag #" .. otag .. " -> #" .. ntag .. " (" .. replace_count .. " occurrences in " .. #modified_files .. " files)"
        )
      end)
    end)
    end)
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
        notify.no_tags()
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
return M
