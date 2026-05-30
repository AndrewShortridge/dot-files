-- =============================================================================
-- Markdown text objects and motions
-- =============================================================================
-- Text objects: ac/ic (code blocks), al/il (list items), aq/iq (blockquotes)
-- Motions: ]b/[b (code blocks), ]l/[l (list items), ]q/[q (blockquotes)
-- =============================================================================
local M = {}

-- =============================================================================
-- Selection helper (shared contract: 0-indexed row/col, ec is inclusive)
-- =============================================================================

local function select_range(sr, sc, er, ec)
  if sr > er or (sr == er and sc > ec) then
    return
  end
  vim.api.nvim_win_set_cursor(0, { sr + 1, sc })
  vim.cmd("normal! v")
  vim.api.nvim_win_set_cursor(0, { er + 1, ec })
end

-- =============================================================================
-- Buffer helpers
-- =============================================================================

--- Get total line count (0-indexed max = total - 1)
local function line_count()
  return vim.api.nvim_buf_line_count(0)
end

--- Get a single buffer line (0-indexed row). Returns "" for out of range.
local function get_line(row)
  local lines = vim.api.nvim_buf_get_lines(0, row, row + 1, false)
  return lines[1] or ""
end

--- Get cursor position as (0-indexed row, 0-indexed col).
local function cursor_0()
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1] - 1, pos[2]
end

-- =============================================================================
-- CODE BLOCK TEXT OBJECTS (ac/ic)
-- =============================================================================
-- Fenced code blocks use ``` or ~~~ delimiters.
-- Strategy: regex-based scanning (reliable for fenced blocks).
-- =============================================================================

local FENCE_PATTERN = "^(%s*)(```+)(.*)" -- matches ``` or longer
local TILDE_FENCE_PATTERN = "^(%s*)(~~~+)(.*)" -- matches ~~~ or longer

--- Test if a line is a fence delimiter. Returns (indent, fence_chars, rest) or nil.
local function parse_fence(line)
  local indent, fence, rest = line:match(FENCE_PATTERN)
  if indent then
    return indent, fence, rest
  end
  indent, fence, rest = line:match(TILDE_FENCE_PATTERN)
  if indent then
    return indent, fence, rest
  end
  return nil
end

--- Find the fenced code block enclosing row (0-indexed).
--- Returns (open_row, close_row) or nil.
local function find_code_block(row)
  local total = line_count()

  -- Search upward for opening fence
  local open_row, open_char, open_len
  for r = row, 0, -1 do
    local line = get_line(r)
    local indent, fence, rest = parse_fence(line)
    if indent then
      local char = fence:sub(1, 1)
      local len = #fence
      if r < row then
        local trimmed = vim.trim(rest or "")
        if #trimmed > 0 then
          -- Has info string -> definitely an opener
          open_row = r
          open_char = char
          open_len = len
          break
        else
          -- Bare fence: could be closer of a previous block.
          -- Skip this fence and its matching opener above.
          local skip_char, skip_len = char, len
          for r2 = r - 1, 0, -1 do
            local line2 = get_line(r2)
            local indent2, fence2, rest2 = parse_fence(line2)
            if indent2 and fence2:sub(1, 1) == skip_char and #fence2 >= skip_len then
              r = r2 -- continue searching upward past the opener
              break
            end
          end
        end
      else
        -- Cursor is on a fence line itself
        local trimmed = vim.trim(rest or "")
        if #trimmed > 0 then
          -- On an opening fence
          open_row = r
          open_char = char
          open_len = len
          break
        else
          -- On a closing fence or bare opener. Search upward for the opener.
          local target_char, target_len = char, len
          for r2 = r - 1, 0, -1 do
            local line2 = get_line(r2)
            local indent2, fence2, rest2 = parse_fence(line2)
            if indent2 and fence2:sub(1, 1) == target_char and #fence2 >= target_len then
              open_row = r2
              open_char = target_char
              open_len = #fence2
              break
            end
          end
          break
        end
      end
    end
  end

  if not open_row then
    return nil
  end

  -- Search downward for closing fence (same char type, at least open_len chars)
  for r = open_row + 1, total - 1 do
    local line = get_line(r)
    local indent, fence, rest = parse_fence(line)
    if indent and fence:sub(1, 1) == open_char and #fence >= open_len then
      local trimmed = vim.trim(rest or "")
      if #trimmed == 0 then
        -- Verify cursor is within this block
        if row >= open_row and row <= r then
          return open_row, r
        else
          return nil
        end
      end
    end
  end
  return nil
end

--- Collect all code block positions for motions.
--- Returns list of {row} (0-indexed) for each opening fence.
local function collect_code_blocks()
  local total = line_count()
  local blocks = {}
  local r = 0
  while r < total do
    local line = get_line(r)
    local indent, fence, rest = parse_fence(line)
    if indent then
      local char = fence:sub(1, 1)
      local len = #fence
      local trimmed = vim.trim(rest or "")
      if #trimmed > 0 then
        -- Opening fence with info string
        blocks[#blocks + 1] = { row = r }
        -- Skip to closing fence
        for r2 = r + 1, total - 1 do
          local line2 = get_line(r2)
          local indent2, fence2, rest2 = parse_fence(line2)
          if indent2 and fence2:sub(1, 1) == char and #fence2 >= len then
            r = r2
            break
          end
        end
      else
        -- Bare fence: could be an opening fence for a code block with no info string
        local found_closer = false
        for r2 = r + 1, total - 1 do
          local line2 = get_line(r2)
          local indent2, fence2, rest2 = parse_fence(line2)
          if indent2 and fence2:sub(1, 1) == char and #fence2 >= len then
            local trimmed2 = vim.trim(rest2 or "")
            if #trimmed2 == 0 then
              blocks[#blocks + 1] = { row = r }
              r = r2
              found_closer = true
              break
            end
          end
        end
        -- Orphan fence if not found_closer, skip
      end
    end
    r = r + 1
  end
  return blocks
end

--- "around code block": select entire fenced code block including delimiters.
function M.around_codeblock()
  local row = cursor_0()
  local open_row, close_row = find_code_block(row)
  if not open_row or not close_row then
    return
  end
  local close_line = get_line(close_row)
  select_range(open_row, 0, close_row, math.max(0, #close_line - 1))
end

--- "inside code block": select content between fence delimiters.
function M.inside_codeblock()
  local row = cursor_0()
  local open_row, close_row = find_code_block(row)
  if not open_row or not close_row then
    return
  end
  -- Inner range: line after opener to line before closer
  local isr = open_row + 1
  local ier = close_row - 1
  if isr > ier then
    return -- empty code block
  end
  local last_line = get_line(ier)
  select_range(isr, 0, ier, math.max(0, #last_line - 1))
end

--- Jump to next code block opening fence.
function M.next_codeblock()
  local row = cursor_0()
  local blocks = collect_code_blocks()
  local count = vim.v.count1
  local found = 0
  for _, blk in ipairs(blocks) do
    if blk.row > row then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { blk.row + 1, 0 })
        return
      end
    end
  end
end

--- Jump to previous code block opening fence.
function M.prev_codeblock()
  local row = cursor_0()
  local blocks = collect_code_blocks()
  local count = vim.v.count1
  local found = 0
  for i = #blocks, 1, -1 do
    if blocks[i].row < row then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { blocks[i].row + 1, 0 })
        return
      end
    end
  end
end

-- =============================================================================
-- LIST ITEM TEXT OBJECTS (al/il)
-- =============================================================================
-- Markdown list items: unordered (- * +), ordered (1. 2.), task (- [ ] - [x])
-- Strategy: treesitter first, regex fallback.
-- =============================================================================

local LIST_BULLET_PATTERN = "^(%s*)([%-%*%+]%s)" -- unordered
local LIST_ORDERED_PATTERN = "^(%s*)(%d+[%.%)]%s)" -- ordered
local LIST_TASK_PATTERN = "^(%s*)([%-%*%+]%s%[.%]%s)" -- task list

--- Parse a list item line. Returns (indent_len, bullet_len) or nil.
local function parse_list_bullet(line)
  -- Task list (must check before unordered since it's a superset)
  local indent, bullet = line:match(LIST_TASK_PATTERN)
  if indent then
    return #indent, #bullet
  end
  -- Unordered
  indent, bullet = line:match(LIST_BULLET_PATTERN)
  if indent then
    return #indent, #bullet
  end
  -- Ordered
  indent, bullet = line:match(LIST_ORDERED_PATTERN)
  if indent then
    return #indent, #bullet
  end
  return nil
end

--- Find the list_item treesitter node enclosing the cursor.
local function find_list_item_node()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return nil
  end
  while node do
    if node:type() == "list_item" then
      return node
    end
    node = node:parent()
  end
  return nil
end

--- Find the full extent of a list item starting at row (0-indexed).
--- Fallback regex-based approach when treesitter is unavailable.
local function find_list_item_extent(start_row)
  local total = line_count()
  local line = get_line(start_row)
  local item_indent = parse_list_bullet(line)
  if not item_indent then
    return start_row, start_row
  end

  local end_row = start_row
  for r = start_row + 1, total - 1 do
    local l = get_line(r)
    -- Empty line ends the item
    if l:match("^%s*$") then
      break
    end
    -- Check indentation: continuation lines and sub-items are indented more
    local leading = l:match("^(%s*)")
    if #leading <= item_indent then
      -- Same or less indentation: new sibling or non-list content
      break
    end
    end_row = r
  end
  return start_row, end_row
end

--- Find the list item containing the cursor (regex fallback).
--- Returns (start_row, end_row, indent_len, bullet_len) or nil.
local function find_list_item_regex(row)
  for r = row, 0, -1 do
    local line = get_line(r)
    local indent_len, bullet_len = parse_list_bullet(line)
    if indent_len ~= nil then
      local start_row, end_row = find_list_item_extent(r)
      if row >= start_row and row <= end_row then
        return start_row, end_row, indent_len, bullet_len
      end
      if r < row then
        return nil
      end
    end
  end
  return nil
end

--- "around list item": select entire list item including bullet and sub-items.
function M.around_listitem()
  -- Try treesitter first
  local node = find_list_item_node()
  if node then
    local sr, sc, er, ec = node:range()
    -- node:range() returns exclusive end
    if ec == 0 and er > sr then
      er = er - 1
      local last_line = get_line(er)
      ec = math.max(0, #last_line - 1)
    else
      ec = math.max(0, ec - 1)
    end
    select_range(sr, sc, er, ec)
    return
  end

  -- Regex fallback
  local row = cursor_0()
  local start_row, end_row, indent_len, _ = find_list_item_regex(row)
  if not start_row then
    return
  end
  local last_line = get_line(end_row)
  select_range(start_row, indent_len, end_row, math.max(0, #last_line - 1))
end

--- "inside list item": select list item text without the bullet prefix.
--- Does NOT include sub-items (only the item's own text).
function M.inside_listitem()
  -- Try treesitter first
  local node = find_list_item_node()
  local row = cursor_0()

  if node then
    local sr, _, er, ec = node:range()
    local first_line = get_line(sr)
    local _, bullet_len = parse_list_bullet(first_line)
    if not bullet_len then
      return
    end

    -- Find where sub-items start (first child list node)
    local content_end_row = er
    local content_end_col = ec
    for child in node:iter_children() do
      local child_type = child:type()
      if child_type == "list" then
        local sub_sr = child:range()
        if sub_sr > sr then
          content_end_row = sub_sr - 1
          local prev_line = get_line(content_end_row)
          content_end_col = #prev_line
          break
        end
      end
    end

    -- Adjust exclusive end to inclusive
    if content_end_col == 0 and content_end_row > sr then
      content_end_row = content_end_row - 1
      local prev_line = get_line(content_end_row)
      content_end_col = math.max(0, #prev_line - 1)
    else
      content_end_col = math.max(0, content_end_col - 1)
    end

    -- Inner: skip the bullet on the first line
    local indent_len = #(first_line:match("^(%s*)") or "")
    local inner_sc = indent_len + bullet_len
    if inner_sc > #first_line - 1 and content_end_row == sr then
      return -- empty item
    end
    select_range(sr, inner_sc, content_end_row, content_end_col)
    return
  end

  -- Regex fallback
  local start_row, end_row, indent_len, bullet_len = find_list_item_regex(row)
  if not start_row then
    return
  end
  local inner_sc = indent_len + bullet_len
  local first_line = get_line(start_row)
  if inner_sc >= #first_line then
    return -- empty item
  end
  -- For inner, only select the item's own text lines (not sub-items)
  local own_end = start_row
  local item_content_indent = indent_len + bullet_len
  for r = start_row + 1, end_row do
    local l = get_line(r)
    if l:match("^%s*$") then
      break
    end
    local leading = l:match("^(%s*)")
    if #leading >= item_content_indent then
      local sub_indent = parse_list_bullet(l)
      if sub_indent and sub_indent >= item_content_indent then
        break -- sub-item
      end
      own_end = r
    else
      break
    end
  end
  local last_line = get_line(own_end)
  select_range(start_row, inner_sc, own_end, math.max(0, #last_line - 1))
end

--- Collect all list item start positions for motions.
local function collect_list_items()
  local total = line_count()
  local items = {}
  for r = 0, total - 1 do
    local line = get_line(r)
    local indent_len, _ = parse_list_bullet(line)
    if indent_len ~= nil then
      items[#items + 1] = { row = r, col = indent_len }
    end
  end
  return items
end

--- Jump to next list item.
function M.next_listitem()
  local row, col = cursor_0()
  local items = collect_list_items()
  local count = vim.v.count1
  local found = 0
  for _, item in ipairs(items) do
    if item.row > row or (item.row == row and item.col > col) then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { item.row + 1, item.col })
        return
      end
    end
  end
end

--- Jump to previous list item.
function M.prev_listitem()
  local row, col = cursor_0()
  local items = collect_list_items()
  local count = vim.v.count1
  local found = 0
  for i = #items, 1, -1 do
    local item = items[i]
    if item.row < row or (item.row == row and item.col < col) then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { item.row + 1, item.col })
        return
      end
    end
  end
end

-- =============================================================================
-- BLOCKQUOTE / CALLOUT TEXT OBJECTS (aq/iq)
-- =============================================================================
-- Blockquotes are lines starting with `> ` (possibly nested: `> > `).
-- Strategy: treesitter first, regex fallback.
-- =============================================================================

local BLOCKQUOTE_PATTERN = "^(%s*>)" -- line starts with optional whitespace then >

--- Test if a line is part of a blockquote.
local function is_blockquote_line(line)
  return line:match(BLOCKQUOTE_PATTERN)
end

--- Find the blockquote node enclosing the cursor via treesitter.
local function find_blockquote_node()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return nil
  end
  while node do
    if node:type() == "block_quote" then
      return node
    end
    node = node:parent()
  end
  return nil
end

--- Find the contiguous blockquote region containing row (0-indexed).
--- Returns (start_row, end_row) or nil.
local function find_blockquote_region(row)
  local line = get_line(row)
  if not is_blockquote_line(line) then
    return nil
  end
  local total = line_count()

  -- Expand upward
  local start_row = row
  for r = row - 1, 0, -1 do
    if is_blockquote_line(get_line(r)) then
      start_row = r
    else
      break
    end
  end

  -- Expand downward
  local end_row = row
  for r = row + 1, total - 1 do
    if is_blockquote_line(get_line(r)) then
      end_row = r
    else
      break
    end
  end

  return start_row, end_row
end

--- "around blockquote": select entire blockquote including `>` prefixes.
function M.around_blockquote()
  -- Try treesitter: find the outermost block_quote
  local node = find_blockquote_node()
  if node then
    local outer = node
    local parent = node:parent()
    while parent do
      if parent:type() == "block_quote" then
        outer = parent
      end
      parent = parent:parent()
    end

    local sr, sc, er, ec = outer:range()
    if ec == 0 and er > sr then
      er = er - 1
      local last_line = get_line(er)
      ec = math.max(0, #last_line - 1)
    else
      ec = math.max(0, ec - 1)
    end
    select_range(sr, sc, er, ec)
    return
  end

  -- Regex fallback
  local row = cursor_0()
  local start_row, end_row = find_blockquote_region(row)
  if not start_row then
    return
  end
  local last_line = get_line(end_row)
  select_range(start_row, 0, end_row, math.max(0, #last_line - 1))
end

--- "inside blockquote": select content after the `> ` prefix.
function M.inside_blockquote()
  local row = cursor_0()

  -- Try treesitter
  local node = find_blockquote_node()
  if node then
    local sr, sc, er, ec = node:range()
    if ec == 0 and er > sr then
      er = er - 1
      local last_line = get_line(er)
      ec = math.max(0, #last_line - 1)
    else
      ec = math.max(0, ec - 1)
    end

    -- Find the `> ` prefix on the first line and skip past it
    local first_line = get_line(sr)
    local prefix = first_line:match("^(%s*>%s?)")
    local inner_sc = prefix and #prefix or sc
    select_range(sr, inner_sc, er, ec)
    return
  end

  -- Regex fallback
  local start_row, end_row = find_blockquote_region(row)
  if not start_row then
    return
  end
  local first_line = get_line(start_row)
  local prefix = first_line:match("^(%s*>%s?)")
  local inner_sc = prefix and #prefix or 0
  local last_line = get_line(end_row)
  select_range(start_row, inner_sc, end_row, math.max(0, #last_line - 1))
end

--- Collect all blockquote start positions for motions.
local function collect_blockquotes()
  local total = line_count()
  local quotes = {}
  local in_quote = false
  for r = 0, total - 1 do
    local line = get_line(r)
    if is_blockquote_line(line) then
      if not in_quote then
        quotes[#quotes + 1] = { row = r }
        in_quote = true
      end
    else
      in_quote = false
    end
  end
  return quotes
end

--- Jump to next blockquote.
function M.next_blockquote()
  local row = cursor_0()
  local quotes = collect_blockquotes()
  local count = vim.v.count1
  local found = 0
  for _, q in ipairs(quotes) do
    if q.row > row then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { q.row + 1, 0 })
        return
      end
    end
  end
end

--- Jump to previous blockquote.
function M.prev_blockquote()
  local row = cursor_0()
  local quotes = collect_blockquotes()
  local count = vim.v.count1
  local found = 0
  for i = #quotes, 1, -1 do
    if quotes[i].row < row then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { quotes[i].row + 1, 0 })
        return
      end
    end
  end
end

-- =============================================================================
-- Setup: register buffer-local keymaps for markdown
-- =============================================================================

function M.setup()
  local function map(modes, lhs, rhs, desc)
    vim.keymap.set(modes, lhs, rhs, { buffer = true, desc = desc })
  end

  -- Code block text objects
  map({ "x", "o" }, "ac", M.around_codeblock, "Around code block")
  map({ "x", "o" }, "ic", M.inside_codeblock, "Inside code block")

  -- List item text objects
  map({ "x", "o" }, "al", M.around_listitem, "Around list item")
  map({ "x", "o" }, "il", M.inside_listitem, "Inside list item")

  -- Blockquote/callout text objects
  map({ "x", "o" }, "aq", M.around_blockquote, "Around blockquote")
  map({ "x", "o" }, "iq", M.inside_blockquote, "Inside blockquote")

  -- Code block motions (]b/[b to avoid conflict with [c treesitter-context)
  map({ "n", "x", "o" }, "]b", M.next_codeblock, "Next code block")
  map({ "n", "x", "o" }, "[b", M.prev_codeblock, "Previous code block")

  -- List item motions
  map({ "n", "x", "o" }, "]l", M.next_listitem, "Next list item")
  map({ "n", "x", "o" }, "[l", M.prev_listitem, "Previous list item")

  -- Blockquote motions
  map({ "n", "x", "o" }, "]q", M.next_blockquote, "Next blockquote")
  map({ "n", "x", "o" }, "[q", M.prev_blockquote, "Previous blockquote")
end

return M
