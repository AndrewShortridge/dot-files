-- vault_index_collisions.lua — Collision detection and UI for vault index
-- Handles name/alias collision detection, notification popup, and detail window.

local C = {}

local cleanup = require("andrew.vault.resource_cleanup")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local ui = require("andrew.vault.ui")
local text_utils = require("andrew.vault.text_utils")

--- Module-level dismiss timer and window for collision popup.
--- Hoisted so a new popup cancels the previous one's timer and window.
---@type uv_timer_t|nil
local _dismiss_timer = nil
---@type number|nil
local _dismiss_win = nil

--- Detect alias and name collisions.
---@param name_idx table<string, string[]>
---@param alias_idx table<string, string[]>
---@param rel_path_fn fun(abs_path: string): string  converts abs_path to display rel_path
---@return table[] collisions
function C.detect(name_idx, alias_idx, rel_path_fn)
  local collisions = {}

  --- Deduplicate a path list, skipping allocation for single-entry lists.
  local function dedup_paths(paths)
    if #paths <= 1 then return paths end
    local seen = {}
    local result = {}
    for _, p in ipairs(paths) do
      if not seen[p] then
        seen[p] = true
        result[#result + 1] = p
      end
    end
    return result
  end

  -- Combined alias pass: detect alias-alias AND name-alias in one loop
  for key, alias_paths in pairs(alias_idx) do
    local uniq_alias = dedup_paths(alias_paths)

    -- 1. Alias-alias collisions: same alias defined by multiple files
    if #uniq_alias > 1 then
      local files = {}
      for _, p in ipairs(uniq_alias) do
        files[#files + 1] = rel_path_fn(p)
      end
      collisions[#collisions + 1] = {
        type = "alias-alias",
        key = key,
        files = files,
        message = string.format(
          'Alias "%s" defined by %d files: %s',
          key, #files, table.concat(files, ", ")
        ),
      }
    end

    -- 2. Name-alias collisions: a file's basename matches another file's alias
    local name_paths = name_idx[key]
    if name_paths then
      local alias_set = {}
      for _, p in ipairs(uniq_alias) do alias_set[p] = true end
      local name_set = {}
      for _, p in ipairs(name_paths) do name_set[p] = true end

      local conflicting_alias_files = {}
      for p in pairs(alias_set) do
        if not name_set[p] then
          conflicting_alias_files[#conflicting_alias_files + 1] = rel_path_fn(p)
        end
      end

      if #conflicting_alias_files > 0 then
        local name_files = {}
        for p in pairs(name_set) do
          name_files[#name_files + 1] = rel_path_fn(p)
        end
        collisions[#collisions + 1] = {
          type = "name-alias",
          key = key,
          name_files = name_files,
          alias_files = conflicting_alias_files,
          message = string.format(
            'Name-alias conflict on "%s": name in %s, alias in %s',
            key,
            table.concat(name_files, ", "),
            table.concat(conflicting_alias_files, ", ")
          ),
        }
      end
    end
  end

  -- 3. Basename collisions: same basename in different folders (informational)
  for name, paths in pairs(name_idx) do
    if not name:find("/") and #paths > 1 then
      local uniq = dedup_paths(paths)
      if #uniq > 1 then
        local files = {}
        for _, p in ipairs(uniq) do
          files[#files + 1] = rel_path_fn(p)
        end
        collisions[#collisions + 1] = {
          type = "basename",
          key = name,
          files = files,
          message = string.format(
            'Basename "%s" shared by %d files: %s',
            name, #files, table.concat(files, ", ")
          ),
        }
      end
    end
  end

  return collisions
end

--- Emit a styled top-right popup summarizing all collisions.
--- Auto-dismisses after a few seconds. Only fires once per session.
---@param collisions table[]
---@param already_notified boolean
---@return boolean new_notified_state
function C.notify_popup(collisions, already_notified)
  if already_notified then return true end
  if not config.index.warn_collisions then return false end
  if not collisions or #collisions == 0 then return false end

  -- Count by type
  local counts = { ["alias-alias"] = 0, ["name-alias"] = 0, basename = 0 }
  for _, c in ipairs(collisions) do
    counts[c.type] = (counts[c.type] or 0) + 1
  end

  -- Build display lines
  local lines = {}
  local line_hls = {} -- 0-indexed line -> hl_group

  lines[#lines + 1] = " Vault Index Collisions"
  line_hls[0] = "DiagnosticWarn"

  if counts["alias-alias"] > 0 then
    lines[#lines + 1] = "  " .. counts["alias-alias"] .. " alias collision"
      .. (counts["alias-alias"] ~= 1 and "s" or "")
    line_hls[#lines - 1] = "DiagnosticError"
  end
  if counts["name-alias"] > 0 then
    lines[#lines + 1] = "  " .. counts["name-alias"] .. " name-alias conflict"
      .. (counts["name-alias"] ~= 1 and "s" or "")
    line_hls[#lines - 1] = "DiagnosticWarn"
  end
  if counts["basename"] > 0 then
    lines[#lines + 1] = "  " .. counts["basename"] .. " basename ambiguit"
      .. (counts["basename"] ~= 1 and "ies" or "y")
    line_hls[#lines - 1] = "DiagnosticInfo"
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = " :VaultIndexCollisions for details"
  line_hls[#lines - 1] = "Comment"

  -- Use vim.schedule — may be called from a coroutine.
  vim.schedule(function()
    -- Compute dimensions
    local width = text_utils.max_display_width(lines) + 2 -- padding
    local height = #lines

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false

    -- Apply per-line highlights
    for line_idx, hl_group in pairs(line_hls) do
      vim.api.nvim_buf_add_highlight(buf, -1, hl_group, line_idx, 0, -1)
    end

    -- Position: top-right with small margin
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      anchor = "NE",
      row = 1,
      col = vim.o.columns - 1,
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      focusable = false,
      noautocmd = true,
    })

    -- Subtle background
    vim.api.nvim_set_option_value("winblend", 15, { win = win })
    vim.api.nvim_set_option_value("winhighlight", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })

    -- Dismiss any previous popup before showing the new one
    if _dismiss_win and vim.api.nvim_win_is_valid(_dismiss_win) then
      cleanup.close_win(_dismiss_win)
    end
    _dismiss_win = win

    -- Auto-dismiss after configured timeout (cancel previous timer if rapid re-invocation)
    _dismiss_timer = cleanup.debounce(_dismiss_timer, config.index.collision_notify_ms, function()
      _dismiss_timer = nil
      cleanup.close_win(win)
      if _dismiss_win == win then _dismiss_win = nil end
    end)
  end)

  return true
end

--- Show all collisions in a floating window.
---@param collisions table[]
function C.show(collisions)
  collisions = collisions or {}

  if #collisions == 0 then
    notify.info("no index collisions detected")
    return
  end

  -- Build display lines
  local lines = {}
  local highlights = {} -- { line_idx, hl_group, col_start, col_end }

  -- Group by type
  local grouped = { ["alias-alias"] = {}, ["name-alias"] = {}, basename = {} }
  for _, c in ipairs(collisions) do
    local group = grouped[c.type]
    if group then
      group[#group + 1] = c
    end
  end

  local section_order = { "alias-alias", "name-alias", "basename" }
  local section_titles = {
    ["alias-alias"] = "Alias Collisions",
    ["name-alias"]  = "Name-Alias Conflicts",
    basename        = "Basename Ambiguities",
  }
  local section_hl = {
    ["alias-alias"] = "DiagnosticError",
    ["name-alias"]  = "DiagnosticWarn",
    basename        = "DiagnosticInfo",
  }

  for _, stype in ipairs(section_order) do
    local items = grouped[stype]
    if #items > 0 then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      local title = section_titles[stype] .. " (" .. #items .. ")"
      highlights[#highlights + 1] = { #lines, section_hl[stype], 0, #title }
      lines[#lines + 1] = title
      lines[#lines + 1] = string.rep("-", #title)

      for _, c in ipairs(items) do
        lines[#lines + 1] = "  " .. c.message
      end
    end
  end

  -- Create floating window
  local width = math.min(text_utils.max_display_width(lines) + 4, math.floor(vim.o.columns * 0.85))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.7))

  local float = ui.create_float_display({
    title = "Vault Index Collisions",
    lines = lines,
    width = width,
    height = height,
  })

  vim.bo[float.buf].filetype = "vault-collisions"

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(float.buf, -1, hl[2], hl[1], hl[3], hl[4])
  end
end

return C
