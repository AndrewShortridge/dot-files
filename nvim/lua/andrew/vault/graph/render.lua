local text_utils = require("andrew.vault.text_utils")
local lru = require("andrew.vault.lru_cache")
local config = require("andrew.vault.config")
local profiler = require("andrew.vault.memory_profiler")

local M = {}

-- Cache display widths for repeated strings (graph rendering reuses many)
local _dw_cache = lru.new(config.cache.display_width_max)
local function cached_display_width(s)
  local w = _dw_cache:get(s)
  if not w then
    w = text_utils.display_width(s)
    _dw_cache:put(s, w)
  end
  return w
end

-- Optimization 2: Cache space padding strings by length
local _pad_cache = setmetatable({}, {
  __index = function(t, n)
    t[n] = string.rep(" ", n)
    return t[n]
  end
})

--- Return the display width of a UTF-8 string (each codepoint = 1 cell).
--- This is a simplified version that assumes no wide (CJK) characters.
---@param s string
---@return number
function M.display_width(s)
  return cached_display_width(s)
end

--- Truncate a string to fit within max_cols display columns.
--- Properly handles multi-byte UTF-8 characters by iterating codepoint
--- boundaries rather than slicing at arbitrary byte offsets.
---@param s string
---@param max_cols number  display columns available (including ellipsis)
---@return string
function M.truncate_display(s, max_cols)
  local ellipsis = "\u{2026}" -- …
  local ellipsis_w = cached_display_width(ellipsis)
  if cached_display_width(s) <= max_cols then return s end
  local avail = max_cols - ellipsis_w
  if avail <= 0 then return ellipsis end

  local width = 0
  local byte_pos = 1
  local len = #s
  while byte_pos <= len do
    -- Find the start of the next codepoint
    local next_pos = byte_pos + 1
    while next_pos <= len and bit.band(s:byte(next_pos), 0xC0) == 0x80 do
      next_pos = next_pos + 1
    end
    local ch_w = cached_display_width(s:sub(byte_pos, next_pos - 1))
    if width + ch_w > avail then break end
    width = width + ch_w
    byte_pos = next_pos
  end
  return s:sub(1, byte_pos - 1) .. ellipsis
end

--- Build the ASCII graph lines and collect metadata for highlights / actions.
--- All layout math uses display-width columns; highlight byte offsets are
--- derived from tracked positions during string construction (hot loop) or
--- string.find (header/footer sections).
---@param note_name string
---@param backlinks {name: string, path: string|nil}[]
---@param forward_links {name: string, path: string|nil}[]
---@param total_width number  display columns
---@return string[] lines, table[] highlight_ranges, table<number, {backlink: string|nil, forward: string|nil, backlink_name: string|nil, forward_name: string|nil}> line_to_note
function M.render_graph(note_name, backlinks, forward_links, total_width)
  local stop = profiler.start_timer("graph.layout")
  local lines = {}
  local highlights = {} -- { line (0-indexed), col_start, col_end, group } (byte offsets)
  local line_to_note = {} -- 1-indexed line -> { backlink = path|nil, forward = path|nil }

  local half = math.floor(total_width / 2)

  -- Box-drawing literals and their display widths
  local connector_in  = " \u{2500}\u{2500}\u{2500}\u{2500}\u{2524}" -- " ────┤"
  local connector_out = "\u{251C}\u{2500}\u{2500}\u{2500}\u{2500} " -- "├──── "
  local divider_char  = "\u{2502}" -- "│"
  local border_char   = "\u{2501}" -- "━"

  local connector_in_dw  = cached_display_width(connector_in)   -- 6
  local connector_out_dw = cached_display_width(connector_out)   -- 6
  local divider_dw       = cached_display_width(divider_char)    -- 1

  -- Pre-compute byte lengths for static strings used in the hot loop
  local connector_in_bytes  = #connector_in
  local connector_out_bytes = #connector_out
  local divider_char_bytes  = #divider_char

  local function add_hl(line_idx, col_start, col_end, group)
    highlights[#highlights + 1] = { line_idx, col_start, col_end, group }
  end

  --- Add highlight by finding a literal substring in the line (byte positions).
  --- Used for header/footer sections where tracking positions is not worth it.
  local function hl_find(row_0, line_str, needle, group, search_from)
    local s, e = line_str:find(needle, search_from or 1, true)
    if s then
      add_hl(row_0, s - 1, e, group)
    end
  end

  -- Top border
  local border_line = string.rep(border_char, total_width)
  lines[#lines + 1] = border_line
  add_hl(0, 0, #border_line, "VaultGraphDivider")

  -- Column headers (labels are ASCII; divider is multibyte)
  local lbl_back = "Backlinks"
  local lbl_fwd = "Forward Links"
  local left_header = _pad_cache[math.max(0, half - #lbl_back - 1)] .. lbl_back
  local gap_left = half - cached_display_width(left_header)
  local header_line = left_header
    .. _pad_cache[math.max(1, gap_left)]
    .. divider_char
    .. "   "
    .. lbl_fwd
  lines[#lines + 1] = header_line
  do
    local row_0 = #lines - 1
    hl_find(row_0, header_line, lbl_back, "VaultGraphDivider")
    hl_find(row_0, header_line, lbl_fwd, "VaultGraphDivider")
    hl_find(row_0, header_line, divider_char, "VaultGraphDivider")
  end

  -- Empty line with just the divider
  local empty_div = _pad_cache[half] .. divider_char
  lines[#lines + 1] = empty_div
  add_hl(#lines - 1, half, half + divider_char_bytes, "VaultGraphDivider")

  -- Link rows: pair up backlinks and forward links side by side
  local unresolved_prefix = "? "
  local bl_unresolved = 0
  local fl_unresolved = 0

  local max_rows = math.max(#backlinks, #forward_links)
  for i = 1, max_rows do
    local bl = backlinks[i]
    local fl = forward_links[i]

    -- Optimization 3: Build line via parts table, tracking byte offsets
    local parts = {}
    local parts_n = 0
    local byte_offset = 0 -- running byte position (0-indexed)

    -- Track highlight positions for this row
    local bl_display_start, bl_display_end
    local bl_connector_start, bl_connector_end
    local divider_start, divider_end
    local fl_connector_start, fl_connector_end
    local fl_display_start, fl_display_end

    local bl_display, fl_display

    if bl then
      -- Available display columns for the name on the left side
      local avail = half - connector_in_dw
      bl_display = bl.name
      if not bl.path then
        bl_unresolved = bl_unresolved + 1
        bl_display = unresolved_prefix .. bl_display
      end
      bl_display = M.truncate_display(bl_display, avail)
      local name_dw = cached_display_width(bl_display)
      local pad = math.max(0, avail - name_dw)

      -- Part 1: padding
      local pad_str = _pad_cache[pad]
      parts_n = parts_n + 1
      parts[parts_n] = pad_str
      byte_offset = byte_offset + pad -- ASCII spaces = 1 byte each

      -- Part 2: backlink display name
      bl_display_start = byte_offset
      parts_n = parts_n + 1
      parts[parts_n] = bl_display
      byte_offset = byte_offset + #bl_display
      bl_display_end = byte_offset

      -- Part 3: connector_in
      bl_connector_start = byte_offset
      parts_n = parts_n + 1
      parts[parts_n] = connector_in
      byte_offset = byte_offset + connector_in_bytes
      bl_connector_end = byte_offset
    else
      -- No backlink: just draw the center divider
      local pad = half - divider_dw
      local pad_str = _pad_cache[pad]
      parts_n = parts_n + 1
      parts[parts_n] = pad_str
      byte_offset = byte_offset + pad

      divider_start = byte_offset
      parts_n = parts_n + 1
      parts[parts_n] = divider_char
      byte_offset = byte_offset + divider_char_bytes
      divider_end = byte_offset
    end

    if fl then
      local avail = half - connector_out_dw - 1
      fl_display = fl.name
      if not fl.path then
        fl_unresolved = fl_unresolved + 1
        fl_display = unresolved_prefix .. fl_display
      end
      fl_display = M.truncate_display(fl_display, avail)

      -- Part: connector_out
      fl_connector_start = byte_offset
      parts_n = parts_n + 1
      parts[parts_n] = connector_out
      byte_offset = byte_offset + connector_out_bytes
      fl_connector_end = byte_offset

      -- Part: forward link display name
      fl_display_start = byte_offset
      parts_n = parts_n + 1
      parts[parts_n] = fl_display
      byte_offset = byte_offset + #fl_display
      fl_display_end = byte_offset
    end

    local line_str = table.concat(parts)

    lines[#lines + 1] = line_str
    local row = #lines - 1

    -- Store navigation targets; include names for unresolved link creation
    local line_1idx = #lines
    if bl or fl then
      line_to_note[line_1idx] = {
        backlink = bl and bl.path or nil,
        forward = fl and fl.path or nil,
        backlink_name = bl and (not bl.path) and bl.name or nil,
        forward_name = fl and (not fl.path) and fl.name or nil,
      }
    end

    -- Highlights for this row using tracked byte positions (no string.find)
    if bl then
      local hl_group = bl.path and "VaultGraphExistingLink" or "VaultGraphUnresolvedLink"
      add_hl(row, bl_display_start, bl_display_end, hl_group)
      add_hl(row, bl_connector_start, bl_connector_end, "VaultGraphConnector")
    else
      add_hl(row, divider_start, divider_end, "VaultGraphDivider")
    end

    if fl then
      add_hl(row, fl_connector_start, fl_connector_end, "VaultGraphConnector")
      local hl_group = fl.path and "VaultGraphExistingLink" or "VaultGraphUnresolvedLink"
      add_hl(row, fl_display_start, fl_display_end, hl_group)
    end
  end

  -- If no links at all, show a message
  if max_rows == 0 then
    local msg = "(no connections)"
    local pad = math.max(0, math.floor((total_width - #msg) / 2))
    local msg_line = _pad_cache[pad] .. msg
    lines[#lines + 1] = msg_line
    add_hl(#lines - 1, pad, pad + #msg, "VaultGraphCount")
  end

  -- Empty line with divider
  lines[#lines + 1] = empty_div
  add_hl(#lines - 1, half, half + divider_char_bytes, "VaultGraphDivider")

  -- Bottom border
  lines[#lines + 1] = border_line
  add_hl(#lines - 1, 0, #border_line, "VaultGraphDivider")

  -- Summary line with unresolved counts
  local function fmt_count(total, unresolved, label)
    local s = string.format("%d %s%s", total, label, total == 1 and "" or "s")
    if unresolved > 0 then
      s = s .. string.format(" (%d unresolved)", unresolved)
    end
    return s
  end

  local summary = "  " .. fmt_count(#backlinks, bl_unresolved, "backlink")
  local summary_right = fmt_count(#forward_links, fl_unresolved, "forward link")
  local summary_line = summary
    .. _pad_cache[math.max(1, half - cached_display_width(summary))]
    .. divider_char
    .. "  "
    .. summary_right
  lines[#lines + 1] = summary_line
  add_hl(#lines - 1, 0, #summary_line, "VaultGraphCount")

  stop()
  return lines, highlights, line_to_note
end

return M
