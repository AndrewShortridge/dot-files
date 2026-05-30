-- block_patterns.lua — Shared block ID pattern matching and extraction.
-- Centralizes the block ID regex and extraction logic used across
-- vault_index, completion, blockid, and linkcheck modules.

local text_utils = require("andrew.vault.text_utils")
local pat = require("andrew.vault.patterns")

local M = {}

--- Lua pattern matching a block ID at the end of a line: ^identifier
M.BLOCK_ID_PATTERN = pat.BLOCK_ID

--- Lua pattern for stripping the block ID suffix from a line.
M.BLOCK_ID_STRIP = pat.BLOCK_ID_STRIP

--- Match a block ID at the end of a single line.
---@param line string
---@return string|nil id  The block ID without the ^ prefix, or nil.
function M.match_id(line)
  return line:match(M.BLOCK_ID_PATTERN)
end

--- Extract block IDs from a lines array (e.g. from nvim_buf_get_lines).
--- Returns an ordered array of { id, text, line } without deduplication.
---@param lines string[]
---@return { id: string, text: string, line: number }[]
function M.extract_from_lines(lines)
  local blocks = {}
  for i, line in ipairs(lines) do
    local id = line:match(M.BLOCK_ID_PATTERN)
    if id then
      local text = line:gsub(M.BLOCK_ID_STRIP, "")
      blocks[#blocks + 1] = { id = id, text = text, line = i }
    end
  end
  return blocks
end

--- Extract block IDs from a raw content string (e.g. from file read).
--- Deduplicates by ID (first occurrence wins).
---@param content string Full content (used when lines not provided)
---@param lines? string[] Pre-split lines (avoids redundant vim.split)
---@return { id: string, text: string, line: number }[]
function M.extract_from_content(content, lines)
  local blocks = {}
  local seen = {}
  lines = lines or vim.split(content, "\n", { plain = true })
  for line_num, line in ipairs(lines) do
    local id = line:match(M.BLOCK_ID_PATTERN)
    if id and not seen[id] then
      seen[id] = true
      local text = line:gsub(M.BLOCK_ID_STRIP, "")
      blocks[#blocks + 1] = { id = id, text = text, line = line_num }
    end
  end
  return blocks
end

--- Build a block ID existence set from a lines array.
---@param lines string[]
---@return table<string, boolean>
function M.id_set_from_lines(lines)
  local ids = {}
  for _, line in ipairs(lines) do
    local id = line:match(M.BLOCK_ID_PATTERN)
    if id then ids[id] = true end
  end
  return ids
end

--- Build a block ID existence set from a raw content string.
--- Handles \r\n and \r line endings.
---@param content string
---@return table<string, boolean>
function M.id_set_from_content(content)
  local ids = {}
  for _, line in ipairs(text_utils.split_lines(content)) do
    local id = line:match(M.BLOCK_ID_PATTERN)
    if id then ids[id] = true end
  end
  return ids
end

return M
