-- =============================================================================
-- JSON formatter: one JSON value as indented lines, trimmed where it is long
-- =============================================================================
-- Re-indents JSON TEXT. The value is never decoded, so what is shown is what
-- the file holds byte for byte: the keys in their order, `1.2e-3` and a
-- 20-digit integer as written. (Decoding into a Lua table loses the order of
-- the keys and rounds large integers; `jq` keeps the order but rewrites
-- numbers.)
--
-- Trimming is one rule for every value, with no size at which the output
-- starts behaving differently: an array shows its first `array_items` items,
-- a string its first `string_characters` characters, and a marker says how
-- much was left out. A marker starts with `…` and is not JSON; that is the
-- point of it.
--
--     "history": [
--       { ... },
--       … 9,979 more items
--     ],
--     "text": "the first 2,000 characters",  … 37,907 more characters
--
-- NO EDITOR CALLS, and no `vim` at all: the record preview loads this file by
-- path inside a worker thread, which has its own Lua state. Keep it to the Lua
-- standard library.
--
-- The input is expected to be valid JSON; the caller checks. Text that is not
-- comes out re-indented as far as it can be read and never raises. No line
-- returned holds a line break, so the lines can be buffer lines directly.
-- Pinned by tests/jsonl_json_formatter_spec.lua.

local M = {}

---@class JsonTrimLimits
---@field array_items integer items of an array shown before the rest is left out
---@field string_characters integer characters of a string shown before the rest is left out

---@alias JsonTokenKind "key"|"string"|"number"|"literal"|"trimmed"

---@class JsonSpan a run of one line that is one kind of token
---@field start_column integer first byte, counted from 0
---@field end_column integer byte after the last, counted from 0
---@field kind JsonTokenKind

---@type JsonTrimLimits
M.DEFAULT_LIMITS = { array_items = 20, string_characters = 2000 }

local INDENT_UNIT = "  "
--- What every marker starts with. A formatted line holds it outside a string
--- only where something was left out.
local TRIM_MARK = "…"

local QUOTE, COMMA, COLON, BACKSLASH = 34, 44, 58, 92
local OPEN_ARRAY, CLOSE_ARRAY, OPEN_OBJECT, CLOSE_OBJECT = 91, 93, 123, 125
local LOWERCASE_F, LOWERCASE_N, LOWERCASE_T, LOWERCASE_U = 102, 110, 116, 117

--- Every byte that ends a scalar or changes the structure.
local STRUCTURAL_PATTERN = '[%[%]{},:"]'

---@type table<integer, string>
local indent_of_depth = {}

---@param depth integer
---@return string
local function indent(depth)
  local text = indent_of_depth[depth]
  if not text then
    text = INDENT_UNIT:rep(depth)
    indent_of_depth[depth] = text
  end
  return text
end

--- Where the string opened at `open_at` closes. The end of the text when it
--- never does.
---@param text string
---@param open_at integer index of the opening quote
---@return integer close_at index of the closing quote
local function string_end(text, open_at)
  local position = open_at + 1
  while true do
    local hit = text:find('["\\]', position)
    if not hit then
      return #text
    end
    if text:byte(hit) ~= BACKSLASH then
      return hit
    end
    -- The byte after a backslash is part of the escape, a quote included.
    position = hit + 2
  end
end

--- The last byte of a string's content to keep so that at least
--- `character_limit` characters are shown, or nil when it has no more than
--- that. An escape is counted as the characters it is written with (`\n` is
--- two) and is never split, and neither is a multi-byte character.
---@param text string
---@param first integer first byte of the content, after the opening quote
---@param last integer last byte of the content, before the closing quote
---@param character_limit integer
---@return integer? last_kept_byte
local function last_kept_byte(text, first, last, character_limit)
  local position, characters = first, 0
  while position <= last do
    if characters >= character_limit then
      return position - 1
    end
    local byte = text:byte(position)
    local width
    if byte == BACKSLASH then
      width = text:byte(position + 1) == LOWERCASE_U and 6 or 2
      characters = characters + width
    else
      width = byte < 0xC0 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
      characters = characters + 1
    end
    position = position + width
  end
  return nil
end

--- Characters in a byte range of UTF-8 text.
---@param text string
---@param first integer
---@param last integer
---@return integer
local function character_count(text, first, last)
  local piece = text:sub(first, last)
  local _, continuation_bytes = piece:gsub("[\128-\191]", "")
  return #piece - continuation_bytes
end

--- `37907` as `37,907`.
---@param count integer
---@return string
local function with_thousands(count)
  local digits = tostring(count)
  local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (grouped:gsub("^,", ""))
end

--- Pass over the rest of an array without keeping any of it.
---@param text string
---@param from integer first byte after the comma that follows the last item shown
---@return integer skipped_items
---@return integer close_at index of the array's closing bracket; past the end of the text when it has none
local function skip_items(text, from)
  local position, nesting, skipped_items = from, 0, 1
  while true do
    local at = text:find(STRUCTURAL_PATTERN, position)
    if not at then
      return skipped_items, #text + 1
    end
    local byte = text:byte(at)
    position = at + 1
    if byte == QUOTE then
      position = string_end(text, at) + 1
    elseif byte == OPEN_ARRAY or byte == OPEN_OBJECT then
      nesting = nesting + 1
    elseif byte == CLOSE_ARRAY or byte == CLOSE_OBJECT then
      if nesting == 0 then
        return skipped_items, at
      end
      nesting = nesting - 1
    elseif byte == COMMA and nesting == 0 then
      skipped_items = skipped_items + 1
    end
  end
end

--- One JSON value as indented lines.
---@param text string the value as JSON text
---@param limits JsonTrimLimits? nil shows everything
---@return string[] lines none for text that is blank
---@return integer trimmed_places how many arrays and strings were cut short
function M.format(text, limits)
  if not text:find("%S") then
    return {}, 0
  end

  ---@type string[]
  local lines = {}
  ---@type string[]
  local pieces = {}
  local depth = 0
  --- Per depth: how many items of the array open there are shown so far;
  --- false for an object.
  ---@type table<integer, integer|false>
  local shown_items = {}
  --- The markers of the strings cut on the current line, a cut key's before
  --- its value's, each after two spaces; they go at the end of the line, after
  --- its comma if it gets one.
  ---@type string?
  local line_marker = nil
  local trimmed_places = 0

  local function end_line()
    if line_marker then
      pieces[#pieces + 1] = line_marker
      line_marker = nil
    end
    local line = table.concat(pieces)
    -- Only text that is not valid JSON has a line break here, inside a string
    -- or between the bytes of a word; each piece of it becomes a line. Two
    -- plain finds cost nothing on valid JSON; a pattern find would.
    if line:find("\n", 1, true) or line:find("\r", 1, true) then
      for part in (line:gsub("\r\n?", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = part
      end
    else
      lines[#lines + 1] = line
    end
    pieces = { indent(depth) }
  end

  local position, length = 1, #text
  while position <= length do
    local at = text:find(STRUCTURAL_PATTERN, position)
    -- A number, true, false or null sits between two structural bytes.
    local scalar = text:sub(position, (at or length + 1) - 1):match("^%s*(.-)%s*$")
    if scalar ~= "" then
      pieces[#pieces + 1] = scalar
    end
    if not at then
      break
    end

    local byte = text:byte(at)
    position = at + 1
    if byte == QUOTE then
      local close_at = string_end(text, at)
      local kept_until = limits and last_kept_byte(text, at + 1, close_at - 1, limits.string_characters)
      if kept_until then
        pieces[#pieces + 1] = text:sub(at, kept_until) .. '"'
        local left_out = character_count(text, kept_until + 1, close_at - 1)
        local marker = ("%s %s more characters"):format(TRIM_MARK, with_thousands(left_out))
        line_marker = (line_marker or "") .. INDENT_UNIT .. marker
        trimmed_places = trimmed_places + 1
      else
        pieces[#pieces + 1] = text:sub(at, close_at)
      end
      position = close_at + 1
    elseif byte == OPEN_ARRAY or byte == OPEN_OBJECT then
      local closer = byte == OPEN_ARRAY and CLOSE_ARRAY or CLOSE_OBJECT
      local next_at = text:find("%S", at + 1)
      if next_at and text:byte(next_at) == closer then
        -- An empty array or object stays on one line.
        pieces[#pieces + 1] = string.char(byte, closer)
        position = next_at + 1
      else
        pieces[#pieces + 1] = string.char(byte)
        depth = depth + 1
        shown_items[depth] = byte == OPEN_ARRAY and 1
        end_line()
      end
    elseif byte == CLOSE_ARRAY or byte == CLOSE_OBJECT then
      if depth > 0 then
        shown_items[depth] = nil
        depth = depth - 1
      end
      end_line()
      pieces[#pieces + 1] = string.char(byte)
    elseif byte == COMMA then
      pieces[#pieces + 1] = ","
      local items = shown_items[depth]
      if limits and items and items >= limits.array_items then
        end_line()
        local skipped_items, close_at = skip_items(text, position)
        local noun = skipped_items == 1 and "item" or "items"
        pieces[#pieces + 1] = ("%s %s more %s"):format(TRIM_MARK, with_thousands(skipped_items), noun)
        trimmed_places = trimmed_places + 1
        -- The closing bracket is handled by the next round of the loop.
        position = close_at
      else
        if items then
          shown_items[depth] = items + 1
        end
        end_line()
      end
    else
      pieces[#pieces + 1] = ": "
    end
  end
  end_line()
  -- end_line() started a line that nothing was put on.
  return lines, trimmed_places
end

--- The tokens of one line `format` produced, for colouring it. Works on the
--- line alone, so only the lines on screen ever need it.
---@param line string
---@return JsonSpan[]
function M.spans(line)
  ---@type JsonSpan[]
  local spans = {}
  local position = line:find("%S")
  if not position then
    return spans
  end

  ---@param first integer
  ---@param last integer
  ---@param kind JsonTokenKind
  local function add(first, last, kind)
    spans[#spans + 1] = { start_column = first - 1, end_column = last, kind = kind }
  end

  -- A marker on a line of its own: the rest of an array.
  if line:sub(position, position + #TRIM_MARK - 1) == TRIM_MARK then
    add(position, #line, "trimmed")
    return spans
  end

  if line:byte(position) == QUOTE then
    local close_at = string_end(line, position)
    if line:byte(close_at + 1) == COLON then
      add(position, close_at, "key")
      position = line:find("%S", close_at + 2)
      if not position then
        return spans
      end
    end
  end

  local byte = line:byte(position)
  local value_end = position
  if byte == QUOTE then
    value_end = string_end(line, position)
    add(position, value_end, "string")
  elseif byte ~= OPEN_ARRAY and byte ~= CLOSE_ARRAY and byte ~= OPEN_OBJECT and byte ~= CLOSE_OBJECT then
    value_end = (line:find("[,%s]", position) or #line + 1) - 1
    local is_literal = byte == LOWERCASE_T or byte == LOWERCASE_F or byte == LOWERCASE_N
    add(position, value_end, is_literal and "literal" or "number")
  end

  -- A marker after a value: the rest of a string.
  local marker_at = line:find(TRIM_MARK, value_end + 1, true)
  if marker_at then
    add(marker_at, #line, "trimmed")
  end
  return spans
end

return M
