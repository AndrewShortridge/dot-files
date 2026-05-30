# Smart List Continuation on Enter

## Problem

When pressing Enter inside a markdown list in Neovim, the next line is a blank
line with no bullet marker. Obsidian, VS Code with markdown extensions, and
most dedicated markdown editors automatically continue list markers on Enter.
This is one of the most-missed quality-of-life features for vault note-taking.

Specific gaps:

1. **No bullet continuation.** Pressing Enter after `- item` produces a blank
   line instead of `- `.
2. **No ordered list increment.** Pressing Enter after `1. item` does not
   produce `2. `.
3. **No task checkbox continuation.** Pressing Enter after `- [ ] task` does
   not produce `- [ ] `.
4. **No blockquote continuation.** Pressing Enter after `> text` does not
   produce `> `.
5. **No empty-bullet cleanup.** Pressing Enter on a line containing only
   `- ` (empty bullet) does not remove the bullet and exit list mode.
6. **No indent preservation.** Nested list items lose their indentation on
   Enter.

## Current State

### Enter key behavior in markdown buffers

There is **no** `<CR>` mapping in insert mode for markdown in
`ftplugin/markdown.lua`. The file defines only normal-mode (`n`) and
visual-mode (`v`) keymaps via `map()` and `vmap()` helpers, both of which are
buffer-local.

Pressing Enter in insert mode falls through to the default Neovim behavior
(create a new line, no prefix).

### Completion plugin interaction (blink.cmp)

`lua/andrew/plugins/blink-cmp.lua` maps `<CR>` to `{ "accept", "fallback" }`.
This means:
- If the completion menu is visible and an item is selected, `<CR>` accepts the
  completion.
- Otherwise, `<CR>` falls back to the underlying keymap.

This is compatible with our approach: we set a buffer-local insert-mode `<CR>`
mapping for markdown, and blink.cmp's fallback will invoke it when no
completion is being accepted.

### Autopairs interaction (nvim-autopairs)

`lua/andrew/plugins/autopairs.lua` configures nvim-autopairs with:
- `check_ts = true` (treesitter-aware pair detection)
- cmp integration via `cmp_autopairs.on_confirm_done()`

Autopairs does **not** explicitly map `<CR>` in this config. The default
nvim-autopairs behavior for `<CR>` is to add a newline with proper indentation
between pairs (e.g., `{|}`  pressing Enter gives `{\n  |\n}`). This is
controlled by autopairs' internal `map_cr` option which defaults to `true`.

However, since blink.cmp's `<CR>` mapping takes precedence and uses
`"fallback"`, the chain is:
1. blink.cmp intercepts `<CR>` -- if completion menu is active, accept it.
2. If no completion, blink.cmp falls back to the next `<CR>` mapping.
3. Our buffer-local `<CR>` mapping fires (what we will create).
4. Inside our mapping, if the line is not a list/quote, we call the original
   `<CR>` behavior (which autopairs may have wrapped).

We must capture the existing `<CR>` mapping before overriding it, so autopairs'
bracket expansion still works inside code blocks, frontmatter, etc.

### Existing list-related functionality

`lua/andrew/utils/md-textobjects.lua` already has list item detection with
these patterns (lines 269-271):

```lua
local LIST_BULLET_PATTERN = "^(%s*)([%-%*%+]%s)"       -- unordered
local LIST_ORDERED_PATTERN = "^(%s*)(%d+[%.%)]%s)"      -- ordered
local LIST_TASK_PATTERN = "^(%s*)([%-%*%+]%s%[.%]%s)"   -- task list
```

It also has:
- `parse_list_bullet(line)` -- returns `(indent_len, bullet_len)` or nil
- `find_list_item_node()` -- treesitter-based list item detection
- `find_list_item_extent()` -- regex-based extent detection
- Text objects: `al`/`il` (around/inside list item)
- Motions: `]l`/`[l` (next/prev list item)

The line-continuation module can reuse the same regex patterns for consistency.

### Vault task states

`lua/andrew/vault/config.lua` defines `task_states` (line 32-38):
```lua
M.task_states = {
  { mark = " ", label = "open" },
  { mark = "/", label = "in-progress" },
  { mark = "x", label = "done" },
  { mark = "-", label = "cancelled" },
  { mark = ">", label = "deferred" },
}
```

When continuing a task list, the new checkbox should always use `[ ]` (open
state), regardless of the current item's state. Continuing `- [x] done task`
should produce `- [ ] ` not `- [x] `.

### Checkbox cycling (`<leader>mx`)

`ftplugin/markdown.lua` (line 139-158) has `<leader>mx` for cycling checkbox
states. This is orthogonal to list continuation -- the user creates the
checkbox via Enter continuation, then cycles it later.

## Solution

Create `lua/andrew/utils/list-continuation.lua` as a self-contained module
that:

1. Parses the current line to detect list type, indent, blockquote prefix.
2. Computes the appropriate continuation string for the next line.
3. Handles the empty-bullet-delete case.
4. Provides the `<CR>` mapping function.
5. Optionally handles `o` and `O` in normal mode.

The module is activated from `ftplugin/markdown.lua` with a single
`require()` call, keeping the ftplugin file clean.

## Implementation Steps

### Step 1: Line parser -- detect list context

Create `lua/andrew/utils/list-continuation.lua`:

```lua
--- Smart list continuation for markdown buffers.
--- Automatically continues list markers, blockquotes, and task checkboxes
--- when pressing Enter in insert mode.
local M = {}

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

-- Blockquote prefix: one or more `> ` layers (with optional trailing space).
-- Captures the full blockquote prefix and the remaining content.
local BLOCKQUOTE_PREFIX = "^(>[> ]*>?%s?)"

-- List bullet patterns (applied AFTER stripping blockquote prefix).
-- Order matters: task must be checked before unordered (superset).
local patterns = {
  -- Task list: `- [ ] `, `* [x] `, `+ [/] `, etc.
  {
    type = "task",
    pattern = "^(%s*)([%-%*%+])(%s%[.%]%s)",
    ---@param indent string
    ---@param marker string  the bullet char (-, *, +)
    ---@param _checkbox string  the ` [x] ` part
    ---@return string continuation prefix
    continue = function(indent, marker, _checkbox)
      return indent .. marker .. " [ ] "
    end,
    ---@param indent string
    ---@param marker string
    ---@param checkbox string
    ---@return string the "empty" version of this bullet (just marker + checkbox, no content)
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
    ---@param indent string
    ---@param num string  the number as string
    ---@param sep string  the separator (`. ` or `) `)
    continue = function(indent, num, sep)
      return indent .. tostring(tonumber(num) + 1) .. sep
    end,
    empty = function(indent, num, sep)
      return indent .. num .. sep
    end,
  },
}
```

### Step 2: Parse a complete line into its components

```lua
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
```

### Step 3: Empty bullet handler

When the user presses Enter on a line that has a bullet but no content (e.g.,
`- ` or `  1. ` or `> - `), the expected behavior is:

- **Delete the bullet** (replace line with just whitespace/nothing).
- If the line was indented (nested list), **reduce indent by one level** and
  place the cursor there. This effectively "un-nests" the list.
- If the line was at the top indent level, **clear the line entirely** and
  leave the cursor on a blank line (exit list mode).

```lua
--- Handle the empty bullet case: remove bullet and optionally reduce indent.
---@param parsed table  the result from parse_line()
---@param line_nr number  1-indexed line number
---@return boolean handled  true if we handled it (caller should NOT insert a new line)
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
    -- Place cursor at end of the new bullet prefix
    vim.api.nvim_win_set_cursor(0, { line_nr, #new_line })
  else
    -- Top-level bullet: clear the line entirely (keep blockquote prefix if any)
    if bq ~= "" then
      -- Inside a blockquote: just remove the bullet, keep `> `
      vim.api.nvim_set_current_line(bq)
      vim.api.nvim_win_set_cursor(0, { line_nr, #bq })
    else
      -- Not in blockquote: clear line
      vim.api.nvim_set_current_line("")
      vim.api.nvim_win_set_cursor(0, { line_nr, 0 })
    end
  end

  return true
end
```

### Step 4: The CR action function

```lua
--- The main CR handler for insert mode in markdown buffers.
--- Returns a string of keys to feed, or nil to fall through to default CR.
---@param fallback_cr string  the original CR key sequence (for non-list lines)
function M.cr_action(fallback_cr)
  local line = vim.api.nvim_get_current_line()
  local row = vim.api.nvim_win_get_cursor(0)[1]  -- 1-indexed
  local col = vim.api.nvim_win_get_cursor(0)[2]  -- 0-indexed byte offset

  local parsed = M.parse_line(line)

  -- Not a list or blockquote line: fall through
  if not parsed then
    return fallback_cr
  end

  -- Empty bullet: delete it instead of continuing
  if parsed.is_empty then
    M.handle_empty_bullet(parsed, row)
    return ""  -- no keys to feed (we already modified the buffer)
  end

  -- Cursor is at or beyond the end of the line (typical case)
  -- Insert a new line below with the continuation prefix
  local continuation = parsed.continuation

  -- If cursor is in the middle of the line content, split the line:
  -- - Current line keeps text before cursor
  -- - New line gets continuation + text after cursor
  local prefix_len = #parsed.blockquote + #parsed.bullet_full
  if col < #line then
    -- Cursor is somewhere in the line (not at the end)
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
```

### Step 5: CR keymap setup with fallback chaining

```lua
--- Set up the <CR> mapping for the current markdown buffer.
--- Should be called from ftplugin/markdown.lua.
function M.setup_buffer()
  -- Capture the existing <CR> mapping so we can fall back to it
  -- (this preserves autopairs' CR behavior for bracket expansion)
  local existing_cr = vim.fn.maparg("<CR>", "i", false, true)
  local fallback_cr

  if existing_cr and existing_cr.rhs and existing_cr.rhs ~= "" then
    -- There's an existing insert-mode CR mapping (likely from autopairs)
    fallback_cr = existing_cr.rhs
  else
    -- No existing mapping: use literal <CR>
    fallback_cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  end

  vim.keymap.set("i", "<CR>", function()
    local result = M.cr_action(fallback_cr)
    if result == "" then
      -- We handled it (buffer already modified)
      return
    end
    if result then
      -- Feed the fallback keys
      vim.api.nvim_feedkeys(result, "n", false)
    end
  end, {
    buffer = true,
    desc = "Smart list continuation",
    silent = true,
  })
end
```

### Step 6: Normal mode `o` and `O` support (optional)

When pressing `o` on a list item line, the new line should also get a
continuation prefix. `O` above a list item should get the same bullet type.

```lua
--- Set up `o` and `O` overrides for the current markdown buffer.
function M.setup_buffer_normal()
  vim.keymap.set("n", "o", function()
    local line = vim.api.nvim_get_current_line()
    local parsed = M.parse_line(line)
    if parsed and not parsed.is_empty then
      local row = vim.api.nvim_win_get_cursor(0)[1]
      vim.api.nvim_buf_set_lines(0, row, row, false, { parsed.continuation })
      vim.api.nvim_win_set_cursor(0, { row + 1, #parsed.continuation })
      vim.cmd("startinsert!")  -- enter insert mode at end of line
    else
      -- Fall through to default `o`
      local keys = vim.api.nvim_replace_termcodes("o", true, false, true)
      vim.api.nvim_feedkeys(keys, "n", false)
    end
  end, {
    buffer = true,
    desc = "Smart list continuation (o)",
    silent = true,
  })

  vim.keymap.set("n", "O", function()
    local line = vim.api.nvim_get_current_line()
    local parsed = M.parse_line(line)
    if parsed and not parsed.is_empty then
      local row = vim.api.nvim_win_get_cursor(0)[1]
      -- For O, insert the continuation above the current line.
      -- For ordered lists, use the same number (the current item
      -- effectively becomes "next").
      local continuation = parsed.continuation
      if parsed.type == "ordered" then
        -- Use the current number, not incremented
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
```

### Step 7: Toggle command

```lua
--- State: whether list continuation is enabled for this buffer.
--- Defaults to true. Stored as buffer variable.
function M.is_enabled()
  local val = vim.b.list_continuation_enabled
  if val == nil then return true end
  return val
end

function M.toggle()
  local current = M.is_enabled()
  vim.b.list_continuation_enabled = not current
  vim.notify(
    "List continuation: " .. (vim.b.list_continuation_enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end

return M
```

In `cr_action()`, add an early exit:

```lua
function M.cr_action(fallback_cr)
  if not M.is_enabled() then
    return fallback_cr
  end
  -- ... rest of function
end
```

### Step 8: Integration in ftplugin/markdown.lua

Add to `ftplugin/markdown.lua`, after the existing utility requires:

```lua
-- =============================================================================
-- Smart List Continuation on Enter
-- =============================================================================

local list_cont = require("andrew.utils.list-continuation")
list_cont.setup_buffer()
list_cont.setup_buffer_normal()  -- optional: o/O support

vim.api.nvim_buf_create_user_command(0, "VaultListContinue", function()
  list_cont.toggle()
end, { desc = "Toggle smart list continuation" })
```

### Step 9: Which-Key registration

Add to the existing which-key block in `ftplugin/markdown.lua`:

```lua
-- Inside the wk.add() call:
{ "<CR>", desc = "Smart list continue (insert)", buffer = 0, mode = "i" },
```

## Line Pattern Recognition

### Detailed regex patterns

Each pattern is applied to the line content AFTER stripping the blockquote
prefix.

| List Type | Lua Pattern | Example Matches |
|-----------|-------------|-----------------|
| Task | `^(%s*)([%-%*%+])(%s%[.%]%s)` | `- [ ] `, `  * [x] `, `+ [/] ` |
| Unordered | `^(%s*)([%-%*%+])(%s)` | `- `, `  * `, `+ ` |
| Ordered | `^(%s*)(%d+)([%.%)]%s)` | `1. `, `  12) `, `3. ` |
| Blockquote | (via `BLOCKQUOTE_PREFIX`) | `> `, `> > `, `>> ` |

### Blockquote prefix pattern

```lua
"^(>[> ]*>?%s?)"
```

This captures:
- `> ` (single level)
- `> > ` (double level)
- `>> ` (compact double level)
- `> > > ` (triple level)

### Nested blockquote + list combinations

For a line like `> > - [ ] nested task`, parsing proceeds:

1. Blockquote prefix match: `> > ` (captured as `bq_prefix`)
2. Remainder: `- [ ] nested task`
3. Task pattern match: indent=`""`, marker=`-`, checkbox=` [ ] `
4. Content: `nested task`
5. Continuation: `> > - [ ] `

For `>   1. ordered in quote`:

1. Blockquote prefix: `> ` (the `> ` before spaces)
2. Remainder: `  1. ordered in quote`
3. Ordered pattern: indent=`  `, num=`1`, sep=`. `
4. Continuation: `>   2. `

## Edge Cases

### Cursor in the middle of a line

When the cursor is not at the end of the line (e.g., `- hello|world` where `|`
is cursor), pressing Enter should:

- Current line becomes: `- hello`
- New line becomes: `- world`
- Cursor is placed at the start of `world` on the new line

This is handled by the `col < #line` branch in `cr_action()`.

### Line with only whitespace after bullet

A line like `- ` (bullet + space, no content) or `  1. ` (ordered, no content)
is treated as an "empty bullet". Pressing Enter triggers the empty-bullet
handler which removes/un-nests the bullet.

The check is: `content:match("^%s*$")` where `content` is everything after the
full bullet prefix.

### Ordered lists: renumbering

This implementation does NOT automatically renumber subsequent ordered list
items after insertion. For example, if you have:

```markdown
1. First
2. Second
3. Third
```

And you press Enter after `1. First`, the result is:

```markdown
1. First
2.
2. Second
3. Third
```

Full renumbering is a separate feature (could be added as a `:VaultListRenum`
command). The simple increment (`N+1`) covers the most common case and matches
Obsidian's behavior.

### Tab-indented vs space-indented lists

The parser uses `(%s*)` for indent capture, which matches both tabs and spaces.
The continuation string preserves whatever whitespace the original line used.

For the empty-bullet un-nest case, `shiftwidth` is used to determine how much
indent to remove. This respects the user's configured indent settings.

### Lines inside fenced code blocks

The list continuation should NOT activate inside fenced code blocks. The parser
will naturally not match most code lines, but edge cases like a line starting
with `- ` inside a code block would incorrectly trigger.

Solution: check if the cursor is inside a treesitter `fenced_code_block` node
before applying list continuation:

```lua
--- Check if cursor is inside a fenced code block.
---@return boolean
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
```

Add at the top of `cr_action()`:

```lua
if in_code_block() then
  return fallback_cr
end
```

### Lines inside frontmatter

YAML frontmatter (`---` delimited) should not trigger list continuation. The
treesitter check handles this since frontmatter nodes are `minus_metadata` or
`front_matter`, not list items. But as an extra guard:

```lua
if in_code_block() or in_frontmatter() then
  return fallback_cr
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
```

### Interaction with blink.cmp `<CR>`

blink.cmp maps `<CR>` to `{ "accept", "fallback" }`. When the completion menu
is visible and an item is selected, blink consumes the `<CR>`. When no
completion is active, blink calls the fallback.

Since our mapping is buffer-local and blink's is global, the chain is:
1. blink.cmp checks if completion should be accepted.
2. If not, blink falls back to the buffer-local `<CR>`.
3. Our `cr_action()` handles list continuation or falls back to the original CR.

This works correctly without any special integration code.

### Interaction with nvim-autopairs `<CR>`

nvim-autopairs' CR handler expands pairs like `{|}` into multi-line blocks. Our
module captures the existing CR mapping before overriding, so the chain is:
1. Our `cr_action()` checks for list context.
2. If not a list line, we feed the captured fallback (autopairs' CR).
3. Autopairs' CR does its bracket expansion or feeds the bare `<CR>`.

The capture happens in `setup_buffer()` via `vim.fn.maparg("<CR>", "i", false,
true)`. This must be called AFTER autopairs has set up its mapping (autopairs
loads on `InsertEnter`, and ftplugin loads on `BufRead`/`FileType`, so
autopairs may not be loaded yet on the very first buffer).

To handle the lazy-loading timing, use a deferred setup:

```lua
-- In ftplugin/markdown.lua:
vim.schedule(function()
  list_cont.setup_buffer()
end)
```

Or more robustly, set up on the first InsertEnter for the buffer:

```lua
vim.api.nvim_create_autocmd("InsertEnter", {
  buffer = 0,
  once = true,
  callback = function()
    list_cont.setup_buffer()
  end,
  desc = "Lazy setup list continuation after autopairs loads",
})
```

This ensures autopairs' `<CR>` mapping exists before we capture it.

## Files to Create

### `lua/andrew/utils/list-continuation.lua`

Single new file (~180-220 lines). Contains:

- `BLOCKQUOTE_PREFIX` pattern constant
- `patterns` table with task, unordered, ordered list definitions
- `M.parse_line(line)` -- parse a line into structural components
- `M.handle_empty_bullet(parsed, line_nr)` -- remove/un-nest empty bullets
- `M.cr_action(fallback_cr)` -- main CR handler
- `M.setup_buffer()` -- set up insert-mode `<CR>` for current buffer
- `M.setup_buffer_normal()` -- set up `o`/`O` overrides for current buffer
- `M.is_enabled()` / `M.toggle()` -- per-buffer enable/disable
- `in_code_block()` / `in_frontmatter()` -- treesitter context guards

## Files to Modify

### `ftplugin/markdown.lua`

Add after the existing `require("andrew.utils.md-textobjects").setup()` line
(line 137):

```lua
-- =============================================================================
-- Smart List Continuation on Enter
-- =============================================================================

local list_cont = require("andrew.utils.list-continuation")

-- Defer setup to InsertEnter so autopairs' <CR> mapping is captured correctly
vim.api.nvim_create_autocmd("InsertEnter", {
  buffer = 0,
  once = true,
  callback = function()
    list_cont.setup_buffer()
  end,
  desc = "Setup smart list continuation",
})

-- Normal mode o/O can be set up immediately (no autopairs dependency)
list_cont.setup_buffer_normal()

vim.api.nvim_buf_create_user_command(0, "VaultListContinue", function()
  list_cont.toggle()
end, { desc = "Toggle smart list continuation" })
```

Add to the which-key block (inside the existing `wk.add()` call):

```lua
{ "<CR>", desc = "Smart list continue", buffer = 0, mode = "i" },
```

### `lua/andrew/vault/config.lua`

Add a new configuration section:

```lua
-- ---------------------------------------------------------------------------
-- Smart list continuation
-- ---------------------------------------------------------------------------
M.list_continuation = {
  enabled = true,
  continue_blockquotes = true,  -- whether to continue `> ` on Enter
  continue_on_o = true,         -- whether `o`/`O` also continue lists
}
```

## Configuration

The module reads from `vault/config.lua` for its defaults:

```lua
-- In list-continuation.lua:
local function get_config()
  local ok, cfg = pcall(require, "andrew.vault.config")
  if ok and cfg.list_continuation then
    return cfg.list_continuation
  end
  return { enabled = true, continue_blockquotes = true, continue_on_o = true }
end
```

The per-buffer toggle (`vim.b.list_continuation_enabled`) overrides the global
config when set explicitly.

## Testing

### Manual test scenarios

Each scenario should be tested in a markdown buffer (`.md` file in the vault).

**Basic unordered list:**

1. Type `- first item` and press Enter.
   - Expected: new line with `- ` prefix, cursor after the space.
2. Type `second item` and press Enter.
   - Expected: new line with `- `.
3. Press Enter again (on empty `- ` line).
   - Expected: bullet removed, blank line.

**Ordered list:**

1. Type `1. first` and press Enter.
   - Expected: `2. ` on new line.
2. Type `second` and press Enter.
   - Expected: `3. `.
3. Delete the text, leaving `3. `, and press Enter.
   - Expected: `3. ` removed, blank line.

**Task list:**

1. Type `- [ ] todo item` and press Enter.
   - Expected: `- [ ] ` on new line (always unchecked).
2. Go back to first line, change to `- [x] todo item` via `<leader>mx`.
3. Press Enter at end of that line.
   - Expected: `- [ ] ` (new task is unchecked, regardless of parent state).

**Nested lists:**

1. Type `- outer` and press Enter.
   - Expected: `- `.
2. Press Tab (or manually type spaces), then type `- inner` and press Enter.
   - Expected: `  - ` (preserves 2-space indent).
3. Press Enter on empty `  - `.
   - Expected: indent reduced to `- ` (un-nested, still has bullet).
4. Press Enter on empty `- `.
   - Expected: blank line (exited list).

**Blockquote:**

1. Type `> some quote` and press Enter.
   - Expected: `> ` on new line.
2. Press Enter on empty `> ` line.
   - Expected: blank line (exited blockquote).

**Blockquote + list:**

1. Type `> - list in quote` and press Enter.
   - Expected: `> - ` on new line.
2. Type `> 1. ordered in quote` and press Enter.
   - Expected: `> 2. `.

**Nested blockquote:**

1. Type `> > deeply nested` and press Enter.
   - Expected: `> > ` on new line.

**Mid-line Enter:**

1. Type `- hello world`, move cursor between `hello` and ` world`.
2. Press Enter.
   - Expected: current line becomes `- hello`, new line becomes `- world`.

**Code block immunity:**

1. Create a fenced code block with `` ``` ``.
2. Inside it, type `- not a list` and press Enter.
   - Expected: normal Enter (no bullet continuation).

**Normal mode o/O:**

1. On line `- item`, press `o`.
   - Expected: new line below with `- `, in insert mode.
2. On line `1. first`, press `O`.
   - Expected: new line above with `1. `, in insert mode.

**Toggle:**

1. Run `:VaultListContinue` to disable.
2. Type `- item` and press Enter.
   - Expected: normal Enter (no continuation).
3. Run `:VaultListContinue` to re-enable.
4. Type `- item` and press Enter.
   - Expected: `- ` continuation resumes.

**Completion interaction:**

1. Start typing `- som` and trigger completion with `<C-Space>`.
2. Select an item and press Enter.
   - Expected: completion is accepted (blink.cmp handles it), no list continuation interference.

**Autopairs interaction:**

1. On a non-list line, type `{` (autopairs inserts `{}`).
2. Press Enter between `{` and `}`.
   - Expected: autopairs' bracket expansion (`{\n  \n}`) works normally.
