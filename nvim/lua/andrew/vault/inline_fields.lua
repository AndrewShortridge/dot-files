local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local pat = require("andrew.vault.patterns")
local link_scan = require("andrew.vault.link_scan")
local hl_coord = require("andrew.vault.highlight_coordinator")
local memo = require("andrew.vault.memoize")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("inline_fields")

local M = {}

M.enabled = config.inline_fields.enabled
M.ns = vim.api.nvim_create_namespace("vault_inline_field_hl")

-- Memoized changedtick-based cache for get_buffer_fields()
local _fields_check -- forward declaration; initialized after parse_line is defined

-- ---------------------------------------------------------------------------
-- Value type classification
-- ---------------------------------------------------------------------------

--- Classify a field value string for highlight purposes.
---@param value string trimmed value text
---@return string type_name one of "empty", "boolean", "date", "number", "link", "text"
function M.classify_value(value)
  local trimmed = vim.trim(value)
  if trimmed == "" then return "empty" end
  if trimmed == "true" or trimmed == "false" then return "boolean" end
  if trimmed:match(pat.ISO_DATE_PREFIX) then return "date" end
  if tonumber(trimmed) then return "number" end
  if trimmed:match("^%[%[.+%]%]$") then return "link" end -- variant of pat.WIKILINK_EXACT (no capture, greedy)
  return "text"
end

--- Map a value type to its highlight group.
---@param vtype string from classify_value()
---@return string highlight_group
function M.value_highlight(vtype)
  local map = {
    boolean = "VaultFieldValueBool",
    date = "VaultFieldValueDate",
    number = "VaultFieldValueNumber",
    link = "VaultFieldValueLink",
    text = "VaultFieldValue",
    empty = "VaultFieldValue",
  }
  return map[vtype] or "VaultFieldValue"
end

-- Shared utilities from link_scan
local build_code_exclusion = link_scan.build_code_exclusion
local get_frontmatter_range = link_scan.get_frontmatter_range

-- ---------------------------------------------------------------------------
-- Field parsing
-- ---------------------------------------------------------------------------

--- A parsed inline field occurrence.
---@class InlineField
---@field key string field key name
---@field value string raw value text
---@field syntax "bracket"|"paren"|"standalone" which syntax form
---@field row number 0-indexed line number
---@field col_start number 0-indexed byte offset of the entire field (including delimiter)
---@field col_key_start number 0-indexed byte offset of key start
---@field col_key_end number 0-indexed byte offset past key end
---@field col_sep_start number 0-indexed byte offset of first ':'
---@field col_sep_end number 0-indexed byte offset past second ':'
---@field col_val_start number 0-indexed byte offset of value start
---@field col_val_end number 0-indexed byte offset past value end
---@field col_end number 0-indexed byte offset past the entire field (including delimiter)

--- Build a delimited InlineField (bracket or paren) from parsed match data.
---@param line string source line (for space-skip detection)
---@param row number 0-indexed
---@param syntax "bracket"|"paren"
---@param key string
---@param value string
---@param delim_pos number 1-indexed position of opening delimiter
---@param match_end number 1-indexed position past closing delimiter
---@return InlineField
local function make_delimited_field(line, row, syntax, key, value, delim_pos, match_end)
  local col_open = delim_pos - 1
  local col_key_start = delim_pos
  local col_key_end = col_key_start + #key
  local col_sep_start = col_key_end
  local col_sep_end = col_sep_start + 2
  local space_skip = line:byte(col_sep_end + 1) == 32 and 1 or 0
  local col_val_start = col_sep_end + space_skip
  return {
    key = key,
    value = value,
    syntax = syntax,
    row = row,
    col_start = col_open,
    col_key_start = col_key_start,
    col_key_end = col_key_end,
    col_sep_start = col_sep_start,
    col_sep_end = col_sep_end,
    col_val_start = col_val_start,
    col_val_end = col_val_start + #value,
    col_end = match_end - 1,
  }
end

--- Scan a single line for all bracketed [key:: value] and parenthesized (key:: value)
--- inline fields in a single pass. Processes the line left-to-right, dispatching
--- on whichever delimiter ('[ or '(') comes first.
---@param line string
---@param row number 0-indexed
---@return InlineField[]
local function find_delimited_fields(line, row)
  local fields = {}
  local pos = 1
  local len = #line

  while pos <= len do
    -- Find the next '[' or '(' in one scan
    local delim_pos = line:find("[%[%(]", pos)
    if not delim_pos then break end

    local ch = line:byte(delim_pos)

    if ch == 91 then -- '[' : bracket field candidate
      -- Skip wikilinks [[
      if line:byte(delim_pos + 1) == 91 then
        pos = delim_pos + 2
        goto continue
      end
      -- Skip footnote refs [^
      if line:byte(delim_pos + 1) == 94 then
        pos = delim_pos + 2
        goto continue
      end

      local key, value, match_end = line:match("^%[([%w_%-]+)::%s*(.-)%]()", delim_pos)
      if key then
        -- Skip markdown links [text](url)
        if line:sub(match_end, match_end) == "(" then
          pos = match_end
          goto continue
        end
        -- Skip URL schemes
        if key:match("^https?$") then
          pos = match_end
          goto continue
        end

        fields[#fields + 1] = make_delimited_field(line, row, "bracket", key, value, delim_pos, match_end)
        pos = match_end
      else
        pos = delim_pos + 1
      end

    else -- '(' : paren field candidate
      local key, value, match_end = line:match("^%(([%w_%-]+)::%s*(.-)%)()", delim_pos)
      if key then
        if key:match("^https?$") then
          pos = match_end
          goto continue
        end

        fields[#fields + 1] = make_delimited_field(line, row, "paren", key, value, delim_pos, match_end)
        pos = match_end
      else
        pos = delim_pos + 1
      end
    end

    ::continue::
  end

  return fields
end

--- Build a standalone InlineField from key, value, and column offset.
---@param line string source line
---@param row number 0-indexed
---@param key string
---@param value string raw captured value (will be trimmed)
---@param col_key_start number 0-indexed byte offset of key
---@return InlineField
local function make_standalone_field(line, row, key, value, col_key_start)
  local col_key_end = col_key_start + #key
  local col_sep_end = col_key_end + 2
  local space_skip = line:byte(col_sep_end + 1) == 32 and 1 or 0
  local trimmed_value = vim.trim(value)
  local col_val_start = col_sep_end + space_skip
  return {
    key = key,
    value = trimmed_value,
    syntax = "standalone",
    row = row,
    col_start = col_key_start,
    col_key_start = col_key_start,
    col_key_end = col_key_end,
    col_sep_start = col_key_end,
    col_sep_end = col_sep_end,
    col_val_start = col_val_start,
    col_val_end = col_val_start + #trimmed_value,
    col_end = #line,
  }
end

--- Scan a single line for standalone inline fields: key:: value
--- These must appear at the start of a line (optionally after a list marker).
---@param line string
---@param row number 0-indexed
---@return InlineField[]
local function find_standalone_fields(line, row)
  local fields = {}

  -- Pattern 1: list item with field — `- key:: value` or `* key:: value`
  local list_prefix, key, value = line:match(pat.INLINE_FIELD_LIST_ITEM)
  if list_prefix and key then
    if not key:match("^https?$") then
      fields[#fields + 1] = make_standalone_field(line, row, key, value, #list_prefix)
      return fields
    end
  end

  -- Pattern 2: bare line — `key:: value`
  key, value = line:match(pat.INLINE_FIELD_STANDALONE)
  if key and not key:match("^https?$") then
    fields[#fields + 1] = make_standalone_field(line, row, key, value, 0)
  end

  return fields
end

--- Parse all inline fields from a single line.
---@param line string
---@param row number 0-indexed
---@return InlineField[]
--- Exported for pipeline tokenizer (line_parse_cache.lua) to reuse parsing logic.
function M.parse_line(line, row)
  -- Single pass for bracket [key:: value] and paren (key:: value) fields
  local all = find_delimited_fields(line, row)

  -- Standalone fields: key:: value (start-of-line only, at most 1 per line).
  -- Cannot overlap with delimited fields since standalone keys must begin at
  -- column 0 (or after a list marker), outside any bracket/paren delimiter.
  vim.list_extend(all, find_standalone_fields(line, row))

  return all
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

M.toggle = hl_coord.make_toggle(M, "inline field highlights")

-- ---------------------------------------------------------------------------
-- Field extraction (for external consumers)
-- ---------------------------------------------------------------------------

-- Now that parse_line is defined, initialize the memoized check.
_fields_check = memo.new(memo.changedtick, function(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local is_in_code = build_code_exclusion(bufnr)
  local fm_start, fm_end = get_frontmatter_range(bufnr)
  local result = {}

  for i, line in ipairs(lines) do
    local row = i - 1
    if fm_start and fm_end and row >= fm_start and row <= fm_end then
      goto skip
    end

    local fields = M.parse_line(line, row)
    for _, field in ipairs(fields) do
      if not is_in_code(row, field.col_key_start) then
        result[#result + 1] = field
      end
    end

    ::skip::
  end

  return result
end, "inline_fields")
memo.register_buf_cleanup(_fields_check)

--- Extract all inline fields from the current buffer.
--- Returns a list of { key, value, syntax, row, col_start } tables.
--- Useful for the field key registry and completion.
---@param bufnr number
---@return InlineField[]
function M.get_buffer_fields(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return _fields_check:get(bufnr)
end


-- ---------------------------------------------------------------------------
-- Field navigation (jump to next/prev inline field)
-- ---------------------------------------------------------------------------

local function get_field_positions(bufnr)
  local all_fields = M.get_buffer_fields(bufnr)
  local positions = {}
  for _, f in ipairs(all_fields) do
    positions[#positions + 1] = { row = f.row + 1, col = f.col_start + 1 }
  end
  return positions
end

local jump_field = hl_coord.make_jump(get_field_positions)


-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local palette = require("andrew.vault.command_palette")
  local group = vim.api.nvim_create_augroup("VaultInlineFieldHL", { clear = true })

  hl_coord.setup_buf_cleanup(group, M.ns, {})

  -- Commands
  vim.api.nvim_create_user_command("VaultFieldHLToggle", function()
    M.toggle()
  end, { desc = "Toggle inline field highlighting" })

  hl_coord.make_refresh_command("VaultFieldHLRefresh", "Refresh inline field highlights in current buffer")

  vim.api.nvim_create_user_command("VaultFieldList", function()
    local fields = M.get_buffer_fields(vim.api.nvim_get_current_buf())
    if #fields == 0 then
      notify.info("no inline fields found in this buffer")
      return
    end
    local items = {}
    for _, f in ipairs(fields) do
      items[#items + 1] = string.format(
        "L%d  %s [%s:: %s] (%s)",
        f.row + 1, f.syntax, f.key, f.value, M.classify_value(f.value)
      )
    end
    notify.info_lines(items)
  end, { desc = "List all inline fields in current buffer" })

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  palette.register_command("VaultFieldHLToggle", "Toggle inline field highlighting", "Debug", function()
    M.toggle()
  end, "<leader>vfF")
  palette.register_command("VaultFieldHLRefresh", "Refresh inline field highlights in current buffer", "Debug", function()
    vim.cmd("VaultFieldHLRefresh")
  end)
  palette.register_command("VaultFieldList", "List all inline fields in current buffer", "Debug", function()
    vim.cmd("VaultFieldList")
  end)
  palette.register_keymap("]f", "Next inline field", "Debug", function()
    jump_field(1)
  end, true)
  palette.register_keymap("[f", "Previous inline field", "Debug", function()
    jump_field(-1)
  end, true)

end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "<leader>vfF", function()
    M.toggle()
  end, {
    buffer = ev.buf,
    desc = "Fields: highlights toggle",
    silent = true,
  })

  vim.keymap.set("n", "]f", function()
    jump_field(1)
  end, {
    buffer = ev.buf,
    desc = "Next inline field",
    silent = true,
  })

  vim.keymap.set("n", "[f", function()
    jump_field(-1)
  end, {
    buffer = ev.buf,
    desc = "Previous inline field",
    silent = true,
  })
end

return M
