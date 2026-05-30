--- Smart list continuation for markdown buffers.
--- Automatically continues list markers, blockquotes, and task checkboxes
--- when pressing Enter in insert mode.
local M = {}

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

-- Blockquote prefix: one or more `> ` layers (with optional trailing space).
local BLOCKQUOTE_PREFIX = "^(>[> ]*>?%s?)"

-- List bullet patterns (applied AFTER stripping blockquote prefix).
-- Order matters: task must be checked before unordered (superset).
local patterns = {
  -- Task list: `- [ ] `, `* [x] `, `+ [/] `, etc.
  {
    type = "task",
    pattern = "^(%s*)([%-%*%+])(%s%[.%]%s)",
    continue = function(indent, marker, _checkbox)
      return indent .. marker .. " [ ] "
    end,
    empty = function(indent, marker, checkbox)
      return indent .. marker .. checkbox
    end,
  },
  -- Unordered: `- `, `* `, `+ `
  {
    type = "unordered",
    pattern = "^(%s*)([%-%*%+])(%s)",
    continue = function(indent, marker, space)
      return indent .. marker .. space
    end,
    empty = function(indent, marker, space)
      return indent .. marker .. space
    end,
  },
  -- Ordered: `1. `, `2) `, `12. `, etc.
  {
    type = "ordered",
    pattern = "^(%s*)(%d+)([%.%)]%s)",
    continue = function(indent, num, sep)
      return indent .. tostring(tonumber(num) + 1) .. sep
    end,
    empty = function(indent, num, sep)
      return indent .. num .. sep
    end,
  },
}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local function get_config()
  local ok, cfg = pcall(require, "andrew.vault.config")
  if ok and cfg.list_continuation then
    return cfg.list_continuation
  end
  return { enabled = true, continue_blockquotes = true, continue_on_o = true }
end

-- ---------------------------------------------------------------------------
-- Treesitter context guards
-- ---------------------------------------------------------------------------

local function in_code_block()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return false
  end
  while node do
    local ntype = node:type()
    if ntype == "fenced_code_block" or ntype == "code_fence_content" then
      return true
    end
    node = node:parent()
  end
  return false
end

local function in_frontmatter()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return false
  end
  while node do
    local ntype = node:type()
    if ntype == "minus_metadata" or ntype == "front_matter" then
      return true
    end
    node = node:parent()
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Line parser
-- ---------------------------------------------------------------------------

--- Parse a markdown line into its structural components.
---@param line string
---@return table|nil result with fields:
---   - blockquote: string  blockquote prefix (empty string if none)
---   - indent: string      whitespace before bullet
---   - bullet_full: string the full bullet prefix (e.g., "- [ ] ", "1. ")
---   - continuation: string what to put on the next line
---   - content: string     text after the bullet
---   - is_empty: boolean   true if content is empty/whitespace-only
---   - type: string        "task"|"unordered"|"ordered"|"blockquote"
function M.parse_line(line)
  -- Extract blockquote prefix
  local bq_prefix = ""
  local rest = line
  local bq_match = line:match(BLOCKQUOTE_PREFIX)
  if bq_match then
    bq_prefix = bq_match
    rest = line:sub(#bq_prefix + 1)
  end

  -- Try each list pattern against the remainder
  for _, pat in ipairs(patterns) do
    local c1, c2, c3 = rest:match(pat.pattern)
    if c1 then
      local bullet_full = c1 .. c2 .. c3
      local content = rest:sub(#bullet_full + 1)
      return {
        blockquote = bq_prefix,
        indent = c1,
        bullet_full = bullet_full,
        continuation = bq_prefix .. pat.continue(c1, c2, c3),
        content = content,
        is_empty = content:match("^%s*$") ~= nil,
        type = pat.type,
      }
    end
  end

  -- No list bullet found -- check for bare blockquote
  if bq_prefix ~= "" then
    local content = rest
    return {
      blockquote = bq_prefix,
      indent = "",
      bullet_full = "",
      continuation = bq_prefix,
      content = content,
      is_empty = content:match("^%s*$") ~= nil,
      type = "blockquote",
    }
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Empty bullet handler
-- ---------------------------------------------------------------------------

--- Handle the empty bullet case: remove bullet and optionally reduce indent.
---@param parsed table  the result from parse_line()
---@param line_nr number  1-indexed line number
---@return boolean handled  true if we handled it
function M.handle_empty_bullet(parsed, line_nr)
  if not parsed.is_empty then
    return false
  end

  local indent = parsed.indent
  local bq = parsed.blockquote

  if #indent > 0 then
    -- Reduce indent by one shiftwidth level (or 2 spaces as fallback)
    local sw = vim.bo.shiftwidth
    if sw == 0 then sw = vim.bo.tabstop end
    if sw == 0 then sw = 2 end
    local new_indent_len = math.max(0, #indent - sw)
    local new_indent = indent:sub(1, new_indent_len)
    -- Keep the same bullet type but at reduced indent, still empty
    local new_line = bq .. new_indent .. parsed.bullet_full:sub(#indent + 1)
    vim.api.nvim_set_current_line(new_line)
    vim.api.nvim_win_set_cursor(0, { line_nr, #new_line })
  else
    -- Top-level bullet: clear the line entirely (keep blockquote prefix if any)
    if bq ~= "" then
      vim.api.nvim_set_current_line(bq)
      vim.api.nvim_win_set_cursor(0, { line_nr, #bq })
    else
      vim.api.nvim_set_current_line("")
      vim.api.nvim_win_set_cursor(0, { line_nr, 0 })
    end
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Enable/disable toggle
-- ---------------------------------------------------------------------------

function M.is_enabled()
  local buf_val = vim.b.list_continuation_enabled
  if buf_val ~= nil then return buf_val end
  return get_config().enabled
end

function M.toggle()
  local current = M.is_enabled()
  vim.b.list_continuation_enabled = not current
  vim.notify(
    "List continuation: " .. (vim.b.list_continuation_enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end

-- ---------------------------------------------------------------------------
-- CR action (insert mode)
-- ---------------------------------------------------------------------------

--- The main CR handler for insert mode in markdown buffers.
---@param fallback_cr string  the original CR key sequence (for non-list lines)
---@return string result  "" if handled, or fallback keys to feed
function M.cr_action(fallback_cr)
  if not M.is_enabled() then
    return fallback_cr
  end

  if in_code_block() or in_frontmatter() then
    return fallback_cr
  end

  local line = vim.api.nvim_get_current_line()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] -- 1-indexed
  local col = cursor[2] -- 0-indexed byte offset

  local parsed = M.parse_line(line)

  -- Not a list or blockquote line: fall through
  if not parsed then
    return fallback_cr
  end

  -- Skip bare blockquote continuation if disabled
  if parsed.type == "blockquote" and not get_config().continue_blockquotes then
    return fallback_cr
  end

  -- Empty bullet: delete it instead of continuing
  if parsed.is_empty then
    M.handle_empty_bullet(parsed, row)
    return ""
  end

  local continuation = parsed.continuation

  -- Cursor is somewhere in the line (not at the end): split
  if col < #line then
    local before = line:sub(1, col)
    local after = line:sub(col + 1)
    vim.api.nvim_set_current_line(before)
    vim.api.nvim_buf_set_lines(0, row, row, false, { continuation .. after })
    vim.api.nvim_win_set_cursor(0, { row + 1, #continuation })
    return ""
  end

  -- Cursor at end of line: simple case
  vim.api.nvim_buf_set_lines(0, row, row, false, { continuation })
  vim.api.nvim_win_set_cursor(0, { row + 1, #continuation })
  return ""
end

-- ---------------------------------------------------------------------------
-- Buffer setup: insert-mode <CR>
-- ---------------------------------------------------------------------------

--- Set up the <CR> mapping for the current markdown buffer.
--- Should be called from ftplugin/markdown.lua (deferred to InsertEnter).
function M.setup_buffer()
  -- Capture the existing <CR> mapping so we can fall back to it
  -- (this preserves autopairs' CR behavior for bracket expansion)
  local existing_cr = vim.fn.maparg("<CR>", "i", false, true)
  local fallback_cr

  if existing_cr and existing_cr.rhs and existing_cr.rhs ~= "" then
    fallback_cr = existing_cr.rhs
  else
    fallback_cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  end

  vim.keymap.set("i", "<CR>", function()
    local result = M.cr_action(fallback_cr)
    if result == "" then
      return
    end
    if result then
      vim.api.nvim_feedkeys(result, "n", false)
    end
  end, {
    buffer = true,
    desc = "Smart list continuation",
    silent = true,
  })
end

-- ---------------------------------------------------------------------------
-- Buffer setup: normal-mode o / O
-- ---------------------------------------------------------------------------

--- Set up `o` and `O` overrides for the current markdown buffer.
function M.setup_buffer_normal()
  if not get_config().continue_on_o then
    return
  end

  vim.keymap.set("n", "o", function()
    if not M.is_enabled() or in_code_block() or in_frontmatter() then
      local keys = vim.api.nvim_replace_termcodes("o", true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
      return
    end

    local line = vim.api.nvim_get_current_line()
    local parsed = M.parse_line(line)
    if parsed and not parsed.is_empty then
      local row = vim.api.nvim_win_get_cursor(0)[1]
      vim.api.nvim_buf_set_lines(0, row, row, false, { parsed.continuation })
      vim.api.nvim_win_set_cursor(0, { row + 1, #parsed.continuation })
      vim.cmd("startinsert!")
    else
      local keys = vim.api.nvim_replace_termcodes("o", true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
    end
  end, {
    buffer = true,
    desc = "Smart list continuation (o)",
    silent = true,
  })

  vim.keymap.set("n", "O", function()
    if not M.is_enabled() or in_code_block() or in_frontmatter() then
      local keys = vim.api.nvim_replace_termcodes("O", true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
      return
    end

    local line = vim.api.nvim_get_current_line()
    local parsed = M.parse_line(line)
    if parsed and not parsed.is_empty then
      local row = vim.api.nvim_win_get_cursor(0)[1]
      -- For O, insert above. For ordered lists, use the current number.
      local continuation = parsed.continuation
      if parsed.type == "ordered" then
        continuation = parsed.blockquote .. parsed.bullet_full
      end
      vim.api.nvim_buf_set_lines(0, row - 1, row - 1, false, { continuation })
      vim.api.nvim_win_set_cursor(0, { row, #continuation })
      vim.cmd("startinsert!")
    else
      local keys = vim.api.nvim_replace_termcodes("O", true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
    end
  end, {
    buffer = true,
    desc = "Smart list continuation (O)",
    silent = true,
  })
end

return M
