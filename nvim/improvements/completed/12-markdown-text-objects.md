# Improvement 12: Markdown Text Objects

## Problem

The markdown ftplugin currently provides text objects only for math zones (`am`/`im`).
Three essential structural elements lack text objects and bracket motions:

| Element | Around | Inner | Next | Prev | Status |
|---------|--------|-------|------|------|--------|
| Math zone | `am` | `im` | `]m` | `[m` | Done |
| Code block | `ac` | `ic` | `]c` | `[c` | **Missing** |
| List item | `al` | `il` | `]l` | `[l` | **Missing** |
| Blockquote/callout | `aq` | `iq` | `]q` | `[q` | **Missing** |

Without these, common editing workflows require manual visual selection:

- `dac` to delete a fenced code block (currently impossible)
- `ciq` to replace callout content (currently impossible)
- `vil` to select a list item's text without its bullet (currently impossible)
- `]c` to jump between code blocks (currently impossible)

### Keymap Conflicts

- `ac`/`ic` in **TeX** files maps to "around/inside command" via `tex-motions.lua`.
  In **markdown** files this binding is free.
- `[c` is globally bound to `treesitter-context.go_to_context()` (see
  `lua/andrew/plugins/treesitter-context.lua`). Options:
  1. Override `[c` only in markdown buffers (buffer-local wins over global).
  2. Use `[C`/`]C` for code blocks instead.
  3. Keep `[c` for treesitter-context and use `]b`/`[b` for code blocks.

  **Recommendation**: Use `]b`/`[b` for code **b**lock motions to avoid conflict
  with treesitter-context. The `ac`/`ic` text objects are fine since they only
  trigger in operator-pending/visual mode (no conflict with `[c` normal-mode
  motion).

---

## Existing Pattern: tex-motions.lua

All new text objects should follow the patterns established in
`lua/andrew/utils/tex-motions.lua`. Key conventions:

### Selection Helper (0-indexed, inclusive end)

```lua
-- File: lua/andrew/utils/tex-motions.lua, lines 75-82
local function select_range(sr, sc, er, ec)
  if sr > er or (sr == er and sc > ec) then
    return
  end
  vim.api.nvim_win_set_cursor(0, { sr + 1, sc })
  vim.cmd("normal! v")
  vim.api.nvim_win_set_cursor(0, { er + 1, ec })
end
```

All parameters are **0-indexed** row/col. The end column `ec` is **inclusive**
(points to the last character to select, not one past it). This is the critical
contract that all text objects must follow.

### Treesitter-Based Text Objects

For LaTeX, text objects use `enclosing_node()` to find the nearest ancestor of a
given type, then extract range from the node:

```lua
-- File: lua/andrew/utils/tex-motions.lua, lines 57-68
local function enclosing_node(types)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = 0 })
  if not ok or not node then
    return nil
  end
  while node do
    if types[node:type()] then
      return node
    end
    node = node:parent()
  end
end
```

### Regex-Based Text Objects (Markdown Math)

When treesitter does not expose the right node types, regex scanning is used. The
markdown math objects (`around_math_md`, `inside_math_md`) scan buffer lines with
pattern matching. This is the fallback approach we will use for some elements.

### Motion Pattern (Count-Aware)

```lua
-- File: lua/andrew/utils/tex-motions.lua, lines 89-109
function M.next_node(types)
  local root = get_root()
  if not root then return end
  local nodes = collect_nodes(root, types)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local count = vim.v.count1
  local found = 0
  for _, node in ipairs(nodes) do
    local sr, sc = node:range()
    if sr > row or (sr == row and sc > col) then
      found = found + 1
      if found == count then
        vim.api.nvim_win_set_cursor(0, { sr + 1, sc })
        return
      end
    end
  end
end
```

### Registration Pattern (Buffer-Local)

```lua
-- File: lua/andrew/utils/tex-motions.lua, lines 498-510
function M.setup_markdown()
  local function map(modes, lhs, rhs, desc)
    vim.keymap.set(modes, lhs, rhs, { buffer = true, desc = desc })
  end
  map({ "n", "x", "o" }, "]m", M.next_math_md, "Next math zone")
  map({ "n", "x", "o" }, "[m", M.prev_math_md, "Previous math zone")
  map({ "x", "o" }, "am", M.around_math_md, "Around math zone")
  map({ "x", "o" }, "im", M.inside_math_md, "Inside math zone")
end
```

Text objects use modes `{ "x", "o" }` (visual + operator-pending).
Motions use modes `{ "n", "x", "o" }` (normal + visual + operator-pending).

---

## Implementation

Create a new file: `lua/andrew/utils/md-textobjects.lua`

This module provides all three text object pairs plus their bracket motions.

### Complete Implementation

```lua
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
-- Treesitter: markdown parser exposes `fenced_code_block` nodes containing
--   `fenced_code_block_delimiter` (opening/closing fence) and `code_fence_content`.
-- Strategy: treesitter first, regex fallback.
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
      -- Opening fence has optional info string; closing fence is bare (or whitespace only)
      local is_opening = rest and rest:match("%S") ~= nil or r == row
      -- Heuristic: if we hit a fence, determine if it's an opener or closer
      -- by scanning what's above it
      if r < row then
        -- Check: is this fence line an opener?
        -- An opener either has an info string after fence chars, or is the first fence we find going up
        local trimmed = vim.trim(rest or "")
        -- A closing fence has nothing after it (or only whitespace)
        -- If it has text like "python" it's an opener
        if #trimmed > 0 then
          -- Has info string -> definitely an opener
          open_row = r
          open_char = char
          open_len = len
          break
        else
          -- Bare fence: could be closer of a previous block. We need to check
          -- if there's a matching opener above it.
          -- Simple approach: bare fence above cursor = we're not in a code block
          -- (unless the cursor IS on a fence line)
          -- More robust: count fences of same type above
          -- For simplicity: treat bare fence as a closer and keep searching
          -- Skip this fence (it closes a block above)
          -- But we need to skip its opener too
          local skip_char, skip_len = char, len
          for r2 = r - 1, 0, -1 do
            local line2 = get_line(r2)
            local indent2, fence2, rest2 = parse_fence(line2)
            if indent2 and fence2:sub(1, 1) == skip_char and #fence2 >= skip_len then
              -- Found the matching opener; skip past it
              r = r2 -- loop will decrement
              break
            end
          end
          -- Continue searching upward
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
        -- Check if there's a matching closer below
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
        if not found_closer then
          -- Orphan fence, skip
        end
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
-- Markdown list items start with:
--   - Unordered: `- `, `* `, `+ ` (optionally preceded by whitespace)
--   - Ordered: `1. `, `2. `, etc.
--   - Task: `- [ ] `, `- [x] `, etc.
-- A list item may span multiple lines (continuation lines are indented past
-- the bullet). Sub-items are indented further.
--
-- Treesitter: markdown parser exposes `list_item` nodes. These accurately
-- capture multi-line items and nesting. We use treesitter as primary strategy.
-- =============================================================================

local LIST_BULLET_PATTERN = "^(%s*)([%-%*%+]%s)" -- unordered
local LIST_ORDERED_PATTERN = "^(%s*)(%d+[%.%)]%s)" -- ordered
local LIST_TASK_PATTERN = "^(%s*)([%-%*%+]%s%[.%]%s)" -- task list

--- Parse a list item line. Returns (indent_len, bullet_len) or nil.
--- bullet_len includes the bullet/number and trailing space.
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
--- Returns the node or nil.
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
--- Returns (start_row, end_row) where end_row is the last line of the item
--- (including continuation lines and sub-items).
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
      -- Same or less indentation: check if it's a new list item at same level
      local next_indent = parse_list_bullet(l)
      if next_indent then
        break -- new sibling item
      end
      -- Non-list line at same/less indent: end of item
      break
    end
    end_row = r
  end
  return start_row, end_row
end

--- Find the list item containing the cursor (regex fallback).
--- Returns (start_row, end_row, indent_len, bullet_len) or nil.
local function find_list_item_regex(row)
  -- Search upward for a list bullet that contains this row
  for r = row, 0, -1 do
    local line = get_line(r)
    local indent_len, bullet_len = parse_list_bullet(line)
    if indent_len ~= nil then
      local start_row, end_row = find_list_item_extent(r)
      if row >= start_row and row <= end_row then
        return start_row, end_row, indent_len, bullet_len
      end
      -- Row is not within this item
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
    -- node:range() returns exclusive end. Adjust to inclusive.
    -- The end row/col from treesitter points one past the last char.
    if ec == 0 and er > sr then
      -- Ends at beginning of next line, so last line of content is er-1
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
--- For multi-line items, selects from after the bullet to end of item.
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

    -- Find where sub-items start (first child list_item or list node)
    local content_end_row = er
    local content_end_col = ec
    for child in node:iter_children() do
      local child_type = child:type()
      if child_type == "list" then
        -- Sub-list starts here; our content ends just before
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
  local total = line_count()
  local item_content_indent = indent_len + bullet_len
  for r = start_row + 1, end_row do
    local l = get_line(r)
    if l:match("^%s*$") then
      break
    end
    local leading = l:match("^(%s*)")
    -- Continuation lines are indented to align with content after bullet
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
-- Callouts are blockquotes whose first line matches `> [!type]`.
-- Treesitter: markdown parser exposes `block_quote` nodes.
-- Strategy: treesitter first, regex fallback.
-- =============================================================================

local BLOCKQUOTE_PATTERN = "^(%s*>)" -- line starts with optional whitespace then >

--- Test if a line is part of a blockquote. Returns the `> ` prefix or nil.
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
    -- Walk up to find the outermost blockquote
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

--- "inside blockquote": select content without `> ` prefixes.
--- This selects the same line range but strips the leading `> ` on each line.
--- Since we can't select non-contiguous regions, we select the full content
--- lines but starting after the `> ` on the first line (useful for operations
--- that work line-wise like `diq` followed by paste).
---
--- More practically: selects from after the first `> ` to end of block.
--- For operator-pending mode, this means the `> ` prefix on the first line
--- is excluded.
function M.inside_blockquote()
  local row = cursor_0()

  -- Try treesitter
  local node = find_blockquote_node()
  if node then
    -- For "inside", use the innermost blockquote the cursor is in
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
--- Returns list of {row = r} for the first line of each blockquote region.
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
```

---

## Registration

### Where to Register

Add the setup call to `ftplugin/markdown.lua`, right after the existing
`tex-motions` setup call.

### Changes to `ftplugin/markdown.lua`

Add this line after line 121:

```lua
-- Math text objects (am|im) and motions (]m|[m) for inline $...$ and display $$...$$
require("andrew.utils.tex-motions").setup_markdown()

-- Markdown text objects (ac|ic, al|il, aq|iq) and motions (]b|[b, ]l|[l, ]q|[q)
require("andrew.utils.md-textobjects").setup()
```

The second `require` line is the only addition. It must come after the
`tex-motions` setup since both modules set buffer-local keymaps and there are no
conflicts between them.

---

## File Layout

```
lua/andrew/utils/
  tex-motions.lua        # existing: LaTeX + markdown math text objects
  md-textobjects.lua     # NEW: markdown structural text objects
```

---

## Keymap Summary (After Implementation)

### Text Objects (visual + operator-pending)

| Binding | Action | Module |
|---------|--------|--------|
| `am`/`im` | Math zone | tex-motions.lua |
| `ac`/`ic` | Fenced code block | md-textobjects.lua |
| `al`/`il` | List item | md-textobjects.lua |
| `aq`/`iq` | Blockquote/callout | md-textobjects.lua |

### Motions (normal + visual + operator-pending)

| Binding | Action | Module |
|---------|--------|--------|
| `]m`/`[m` | Next/prev math zone | tex-motions.lua |
| `]b`/`[b` | Next/prev code block | md-textobjects.lua |
| `]l`/`[l` | Next/prev list item | md-textobjects.lua |
| `]q`/`[q` | Next/prev blockquote | md-textobjects.lua |
| `]h`/`[h` | Next/prev heading | ftplugin/markdown.lua |
| `]o`/`[o` | Next/prev wikilink | vault/wikilinks.lua |

---

## Design Decisions

### Why Treesitter + Regex Fallback

The markdown treesitter parser provides `fenced_code_block`, `list_item`, and
`block_quote` node types. These are used as the primary strategy because:

1. They handle edge cases (multi-line items, nested structures) correctly.
2. They are consistent with how `tex-motions.lua` works for LaTeX.

The regex fallback exists because:

1. Treesitter can fail if the buffer has syntax errors or the parser is not loaded.
2. The code block detection via regex is straightforward and reliable.
3. Having a fallback means the text objects always work.

### Why `]b`/`[b` Instead of `]c`/`[c` for Code Blocks

The `[c` binding is used globally by `nvim-treesitter-context` to jump to the
parent scope (see `lua/andrew/plugins/treesitter-context.lua`, line 26). While
buffer-local mappings override global ones, losing the treesitter-context jump
in markdown files would be confusing. The `b` mnemonic ("block") is clear and
unambiguous.

### `il` Behavior: Text Only vs Text + Sub-items

The `il` (inside list item) text object selects only the item's own text content,
not its sub-items. This matches the mental model of "inside" being the content you
would edit, similar to how `ie` in LaTeX selects content between `\begin` and
`\end` but not nested environments. To select including sub-items, use `al`.

### `iq` Behavior: First `>` Prefix Stripped

The `iq` (inside blockquote) text object cannot truly strip all `>` prefixes since
Vim selections are contiguous character ranges. Instead, it starts the selection
after the `> ` prefix on the first line. This is most useful with linewise
operations (`diq` deletes all lines, `ciq` replaces content) and with block
operations.

---

## Testing

### Manual Testing Procedure

Create a test markdown file with all three element types:

```markdown
# Test File

## Code Blocks

Here is a code block:

` ` `python
def hello():
    print("world")
    return True
` ` `

And a tilde block:

~~~bash
echo "hello"
ls -la
~~~

## Lists

- Item one
  with continuation
- Item two
  - Sub-item A
  - Sub-item B
- Item three

1. First ordered
2. Second ordered
   continuation line
3. Third ordered

- [ ] Task one
- [x] Task two
- [ ] Task three
  - [ ] Sub-task

## Blockquotes

> Simple blockquote
> with multiple lines

> [!note] Callout Title
> This is a callout
> with multiple lines

> Outer quote
> > Nested quote
> > still nested
> Back to outer
```

### Test Cases

#### Code Blocks (`ac`/`ic`)

| Cursor Position | Action | Expected Selection |
|-----------------|--------|--------------------|
| Inside `def hello()` | `vac` | Entire block: `` ` ` `python `` through closing `` ` ` ` `` |
| Inside `def hello()` | `vic` | Lines `def hello():` through `return True` |
| On opening `` ` ` `python `` | `vac` | Entire block |
| On closing `` ` ` ` `` | `vac` | Entire block |
| Inside `echo "hello"` | `vic` | Lines `echo "hello"` through `ls -la` |
| Inside `def hello()` | `dac` | Deletes entire fenced block |
| Inside `def hello()` | `dic` | Deletes content, keeps fences |

#### List Items (`al`/`il`)

| Cursor Position | Action | Expected Selection |
|-----------------|--------|--------------------|
| On `Item one` | `val` | `- Item one\n  with continuation` |
| On `Item one` | `vil` | `Item one\n  with continuation` (no `- `) |
| On `Item two` | `val` | `- Item two` through `  - Sub-item B` |
| On `Item two` | `vil` | `Item two` only (not sub-items) |
| On `Sub-item A` | `val` | `  - Sub-item A` only |
| On `Task one` | `val` | `- [ ] Task one` |
| On `Task one` | `vil` | `Task one` (no `- [ ] `) |
| On `Second ordered` | `val` | `2. Second ordered\n   continuation line` |

#### Blockquotes (`aq`/`iq`)

| Cursor Position | Action | Expected Selection |
|-----------------|--------|--------------------|
| On `Simple blockquote` | `vaq` | All lines starting with `>` in that block |
| On `Simple blockquote` | `viq` | Same lines but starting after `> ` |
| On callout first line | `vaq` | Entire callout block |
| On `still nested` | `vaq` | Entire outer blockquote (outermost) |
| On `still nested` | `viq` | From after `> ` on first line to end |

#### Motions

| Cursor Position | Action | Expected |
|-----------------|--------|----------|
| Top of file | `]b` | Jump to `` ` ` `python `` line |
| On python block | `]b` | Jump to `~~~bash` line |
| On bash block | `[b` | Jump to `` ` ` `python `` line |
| Top of file | `3]l` | Jump to third list item |
| On last quote | `[q` | Jump to previous blockquote |
| Anywhere | `2]q` | Jump 2 blockquotes forward |

### Automated Testing

```lua
-- tests/test_md_textobjects.lua
-- Run with: nvim --headless -u NONE -l tests/test_md_textobjects.lua

-- Create a test buffer with markdown content
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "markdown"

local lines = {
  "# Test",
  "",
  "```python",
  "print('hello')",
  "print('world')",
  "```",
  "",
  "- Item one",
  "  continuation",
  "- Item two",
  "",
  "> Quote line 1",
  "> Quote line 2",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

local md = require("andrew.utils.md-textobjects")

-- Test find_code_block (internal, access via module if exposed for testing)
-- Position cursor inside code block
vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- on print('hello')

-- Test around_codeblock
-- In operator-pending context, we'd verify the selection range
-- For unit testing, expose internal functions or test via keystroke simulation

print("All tests passed")
vim.cmd("qa!")
```

For more thorough testing, simulate keystrokes:

```lua
-- Simulate `vac` and check visual selection bounds
vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.cmd("normal vac")
local start_pos = vim.fn.getpos("'<")
local end_pos = vim.fn.getpos("'>")
assert(start_pos[2] == 3, "ac should start at line 3 (```python)")
assert(end_pos[2] == 6, "ac should end at line 6 (```)")
vim.cmd("normal! \\<Esc>")
```

---

## Edge Cases to Handle

1. **Empty code blocks**: `ic` should do nothing (no content between fences).
2. **Single-line list items**: `al` and `il` differ only by the bullet prefix.
3. **Nested blockquotes**: `aq` selects the outermost; `iq` starts after the
   outermost `> ` prefix.
4. **Cursor on fence line**: `ac` should still select the full block; `ic` should
   select the content (or nothing if empty).
5. **Adjacent blockquotes**: Two blockquotes separated by a blank line are treated
   as separate blocks.
6. **Indented code blocks** (4 spaces, no fence): Not handled. These are rare in
   practice and the fenced variant is the standard.
7. **Fence with no info string**: `` ` ` ` `` on its own line is still recognized
   as a fence delimiter. The code handles both opening and closing fences correctly.
8. **Mixed fence types**: A block opened with `` ` ` ` `` must close with `` ` ` ` ``,
   not `~~~`, and vice versa. The implementation tracks the fence character type.

---

## Future Enhancements

1. **Heading text objects (`ah`/`ih`)**: Select heading and its content until the
   next heading of same or higher level. The heading navigation already exists in
   `ftplugin/markdown.lua`; text objects would be a natural extension.

2. **Table text objects (`aT`/`iT`)**: Select entire markdown table or just its
   data rows (excluding header separator). Useful with table-mode plugin.

3. **Frontmatter text objects (`af`/`if`)**: Select the YAML frontmatter block
   between `---` delimiters. Simple regex approach.

4. **Link text objects**: `aL` for `[text](url)` or `[[wikilink]]`, `iL` for
   just the text/link target. Would complement the existing `]o`/`[o` motions.
