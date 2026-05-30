local engine = require("andrew.vault.engine")
local wikilinks = require("andrew.vault.wikilinks")
local link_utils = require("andrew.vault.link_utils")
local link_scan = require("andrew.vault.link_scan")
local utils = require("andrew.vault.unlinked.utils")

local M = {}

--- Apply file-based wraps bottom-up, sorting by file then line descending.
---@param results table[] array of { file, line, match, ... } items
---@param wrap_fn fun(file: string, lnum: number, match: string): boolean
---@return number wrapped count of successful wraps
function M.apply_file_wraps_bottom_up(results, wrap_fn)
  local by_file = utils.group_by_file(results, function(r) return r.match end)
  local wrapped = 0
  for file, file_matches in pairs(by_file) do
    table.sort(file_matches, function(a, b) return a.line > b.line end)
    for _, r in ipairs(file_matches) do
      if wrap_fn(file, r.line, r.match) then
        wrapped = wrapped + 1
      end
    end
  end
  return wrapped
end

--- Apply buffer-level wraps bottom-up (row descending, col descending).
---@param bufnr number
---@param items table[] array of { row, start_col, end_col, text }
---@param build_link fun(text: string): string
---@return number wrapped count of successful wraps
function M.apply_buffer_wraps_bottom_up(bufnr, items, build_link)
  local sorted = {}
  for _, m in ipairs(items) do
    sorted[#sorted + 1] = m
  end
  table.sort(sorted, function(a, b)
    if a.row ~= b.row then return a.row > b.row end
    return a.start_col > b.start_col
  end)
  local wrapped = 0
  for _, m in ipairs(sorted) do
    local line = vim.api.nvim_buf_get_lines(bufnr, m.row, m.row + 1, false)[1]
    if line then
      local replacement = build_link(m.text)
      local new_line = line:sub(1, m.start_col) .. replacement .. line:sub(m.end_col + 1)
      vim.api.nvim_buf_set_lines(bufnr, m.row, m.row + 1, false, { new_line })
      wrapped = wrapped + 1
    end
  end
  return wrapped
end

--- Build a [[wikilink]] string for the given match text.
--- Resolves the link to decide between [[text]] and [[resolved|text]].
---@param match_text string the display text
---@return string wikilink formatted wikilink string
function M.build_wikilink_text(match_text)
  local resolved = wikilinks.resolve_link(match_text)
  if resolved and match_text:lower() == link_utils.get_basename(resolved):lower() then
    return "[[" .. match_text .. "]]"
  elseif resolved then
    return "[[" .. link_utils.get_basename(resolved) .. "|" .. match_text .. "]]"
  else
    return "[[" .. match_text .. "]]"
  end
end

--- Wrap a text match in [[wikilinks]] at the given file location.
---@param file string absolute file path
---@param lnum number 1-indexed line number
---@param match_text string the exact text to wrap
---@return boolean success
function M.wrap_in_wikilink(file, lnum, match_text)
  local lines, bufnr = utils.read_lines_prefer_buffer(file)
  local use_buffer = bufnr ~= nil

  if #lines < lnum then return false end

  local line = lines[lnum]
  local line_lower = line:lower()
  local match_lower = match_text:lower()
  local ms, me = line_lower:find(match_lower, 1, true)

  while ms do
    if not link_scan.overlaps_range(ms - 1, me, link_scan.get_link_ranges(line)) then
      local before = line:sub(1, ms - 1)
      local matched = line:sub(ms, me)
      local after = line:sub(me + 1)

      local replacement = M.build_wikilink_text(matched)

      local new_line = before .. replacement .. after

      if use_buffer then
        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
      else
        lines[lnum] = new_line
        engine.write_file(file, table.concat(lines, "\n") .. "\n")
      end
      return true
    end
    ms, me = line_lower:find(match_lower, ms + 1, true)
  end

  return false
end

return M
