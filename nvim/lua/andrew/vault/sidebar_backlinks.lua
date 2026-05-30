-- sidebar_backlinks.lua — Backlinks panel for the vault sidebar
-- Shows all notes linking to the current note with context.

local vault_index = require("andrew.vault.vault_index")
local backlinks_mod = require("andrew.vault.backlinks")
local sort_utils = require("andrew.vault.sort_utils")
local link_utils = require("andrew.vault.link_utils")
local log = require("andrew.vault.vault_log").scope("sidebar_backlinks")

local M = {}

-- ---------------------------------------------------------------------------
-- Data collection (reuses find_link_lines from backlinks.lua)
-- ---------------------------------------------------------------------------

--- Collect backlink data for the current note.
---@param source_buf number
---@return { name: string, path: string, lines: { lnum: number, text: string }[] }[]
local function collect_backlinks(source_buf)
  local bufname = vim.api.nvim_buf_get_name(source_buf)
  if bufname == "" then return {} end

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return {} end

  local entry = idx:get_entry_by_abs(bufname)
  if not entry then return {} end

  local inlinks = idx:get_inlinks(entry.rel_path)
  if #inlinks == 0 then return {} end

  local note_name = entry.basename
  local results = {}

  -- Filter out self-references, then batch-read unique source files
  local filtered_inlinks = {}
  for _, inlink in ipairs(inlinks) do
    local source_rel = inlink.path .. ".md"
    local source_entry = idx:get_entry(source_rel)
    if source_entry and source_entry.abs_path ~= bufname then
      filtered_inlinks[#filtered_inlinks + 1] = inlink
    end
  end

  local file_lines_cache = backlinks_mod.batch_read_inlink_sources(filtered_inlinks, idx)

  local seen_paths = {}
  for _, inlink in ipairs(filtered_inlinks) do
    local source_rel = inlink.path .. ".md"
    local source_entry = idx:get_entry(source_rel)
    if source_entry and not seen_paths[source_entry.abs_path] then
      seen_paths[source_entry.abs_path] = true
      local cached_lines = file_lines_cache[source_entry.abs_path]
      if cached_lines then
        local lines = backlinks_mod.find_link_lines_from_cache(cached_lines, note_name)
        results[#results + 1] = {
          name = source_entry.basename,
          path = source_entry.abs_path,
          lines = lines,
        }
      end
    end
  end

  sort_utils.sort_by_name(results)
  return results
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Line-to-action map for navigation.
---@type table<number, { path: string, lnum: number|nil }>
local _line_actions = {}

--- Render the backlinks panel content.
---@param buf number Sidebar buffer
---@param width number Available width in columns
---@param source_buf number The note buffer being inspected
---@param start_line number First line to write content (after tab bar)
---@param ns number Namespace for extmarks
function M.render(buf, width, source_buf, start_line, ns)
  _line_actions = {}

  local backlinks = collect_backlinks(source_buf)

  local lines = {}
  local highlights = {} -- { line_offset, col_start, col_end, hl_group }

  -- Header
  local note_name = link_utils.get_basename(vim.api.nvim_buf_get_name(source_buf))
  local header = " " .. #backlinks .. " backlink" .. (#backlinks == 1 and "" or "s")
  if note_name and note_name ~= "" then
    header = header .. ' to "' .. note_name .. '"'
  end
  lines[#lines + 1] = header
  highlights[#highlights + 1] = { 0, 0, #header, "VaultSidebarHeader" }
  lines[#lines + 1] = ""

  if #backlinks == 0 then
    local msg = "  (no backlinks found)"
    lines[#lines + 1] = msg
    highlights[#highlights + 1] = { #lines - 1, 0, #msg, "VaultSidebarEmpty" }
  else
    for _, bl in ipairs(backlinks) do
      -- File name line
      local name_line = "  " .. bl.name
      local line_idx = #lines
      lines[#lines + 1] = name_line
      highlights[#highlights + 1] = { line_idx, 2, 2 + #bl.name, "VaultSidebarFile" }
      _line_actions[start_line + #lines] = { path = bl.path, lnum = nil }

      -- Context lines
      for _, hit in ipairs(bl.lines) do
        local ctx_text = vim.trim(hit.text)
        if #ctx_text > width - 8 then
          ctx_text = ctx_text:sub(1, width - 10) .. "\u{2026}"
        end
        local ctx_line = "    L" .. hit.lnum .. ": " .. ctx_text
        local ctx_idx = #lines
        lines[#lines + 1] = ctx_line
        -- Highlight line number
        local lnum_str = "L" .. hit.lnum
        highlights[#highlights + 1] = { ctx_idx, 4, 4 + #lnum_str, "VaultSidebarLineNr" }
        -- Highlight rest as context
        highlights[#highlights + 1] = { ctx_idx, 4 + #lnum_str + 2, #ctx_line, "VaultSidebarContext" }
        _line_actions[start_line + #lines] = { path = bl.path, lnum = hit.lnum }
      end

      -- Blank line between entries
      lines[#lines + 1] = ""
    end
  end

  -- Write lines into buffer
  vim.api.nvim_buf_set_lines(buf, start_line, -1, false, lines)

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    local row = start_line + hl[1]
    local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
    if not ok then log.debug("extmark failed at row %d: %s", row, err) end
  end
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

--- Setup panel-specific keymaps on the sidebar buffer.
---@param buf number
---@param source_win number|nil The editing window to navigate in
function M.setup_keymaps(buf, source_win)
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Enter: jump to backlink source
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local action = _line_actions[cursor[1]]
    if not action then return end

    -- Navigate in the source (editing) window, not the sidebar
    local target_win = source_win
    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
      -- Find a non-sidebar window
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local wbuf = vim.api.nvim_win_get_buf(w)
        if vim.bo[wbuf].filetype ~= "vault_sidebar" then
          target_win = w
          break
        end
      end
    end
    if not target_win then return end

    vim.api.nvim_set_current_win(target_win)
    vim.cmd("edit " .. vim.fn.fnameescape(action.path))
    if action.lnum then
      local ok, err = pcall(vim.api.nvim_win_set_cursor, target_win, { action.lnum, 0 })
      if not ok then log.debug("set_cursor failed: %s", err) end
    end
  end, vim.tbl_extend("force", opts, { desc = "Jump to backlink" }))

  -- o: open in split
  vim.keymap.set("n", "o", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local action = _line_actions[cursor[1]]
    if not action then return end

    local target_win = source_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    end
    vim.cmd("split " .. vim.fn.fnameescape(action.path))
    if action.lnum then
      local ok, err = pcall(vim.api.nvim_win_set_cursor, 0, { action.lnum, 0 })
      if not ok then log.debug("set_cursor failed: %s", err) end
    end
  end, vim.tbl_extend("force", opts, { desc = "Open in split" }))

  -- v: open in vsplit
  vim.keymap.set("n", "v", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local action = _line_actions[cursor[1]]
    if not action then return end

    local target_win = source_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    end
    vim.cmd("vsplit " .. vim.fn.fnameescape(action.path))
    if action.lnum then
      local ok, err = pcall(vim.api.nvim_win_set_cursor, 0, { action.lnum, 0 })
      if not ok then log.debug("set_cursor failed: %s", err) end
    end
  end, vim.tbl_extend("force", opts, { desc = "Open in vsplit" }))
end

return M
