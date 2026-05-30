# 29 --- Blockquote Creation Shortcut

## Problem

The markdown ftplugin provides text objects for blockquotes (`aq`/`iq`) and
motions for jumping between them (`]q`/`[q`), but there is no keymap for
*creating* or *removing* blockquotes. Every other structural markdown element has
a creation shortcut:

| Element        | Text Object | Motion   | Creation Shortcut | Status      |
|----------------|-------------|----------|-------------------|-------------|
| Bold           | --          | --       | `<leader>mb`      | Done        |
| Italic         | --          | --       | `<leader>mi`      | Done        |
| Strikethrough  | --          | --       | `<leader>ms`      | Done        |
| Inline code    | --          | --       | `<leader>mc`      | Done        |
| Heading 1-6    | --          | `]h`/`[h`| `<leader>m1`..`m6`| Done        |
| Code block     | `ac`/`ic`   | `]b`/`[b`| --                | No shortcut |
| List item      | `al`/`il`   | `]l`/`[l`| --                | No shortcut |
| Blockquote     | `aq`/`iq`   | `]q`/`[q`| --                | **Missing** |
| Callout        | `aq`/`iq`   | `]q`/`[q`| --                | **Missing** |

To create a blockquote today, the user must either:
1. Manually type `> ` at the beginning of each line.
2. Use a visual block selection (`Ctrl-V`) to prepend `> ` -- awkward for
   varying-length lines and impossible for adding `> ` to blank lines within a
   block.
3. Use a substitution command (`:s/^/> /`) -- requires escaping and is not
   repeatable with `.`.

Obsidian-style callouts (`> [!NOTE]`, `> [!WARNING]`, etc.) are even more
tedious to create manually, requiring the blockquote prefix plus the callout
type syntax on the first line.

### Current `<leader>m` Key Availability

Already taken: `b`, `c`, `f`, `i`, `k`, `K`, `l`, `p`, `s`, `S`, `u`, `x`,
`1`-`6`, `j`, `n`, `z`

Free and relevant: **`q`**, **`Q`**, **`C`** (uppercase C is free since
`<leader>mc` is inline code)

---

## Goal

1. `<leader>mq` in normal mode toggles blockquote on the current line: adds
   `> ` prefix if absent, adds an additional `> ` level if already quoted.
2. `<leader>mq` in visual mode toggles blockquote on all selected lines, adding
   one level of `> ` to each.
3. Repeated `<leader>mq` on already-quoted lines increases nesting depth
   (`> ` becomes `> > `).
4. `<leader>mQ` in normal mode removes one level of blockquote from the current
   line (un-quote).
5. `<leader>mQ` in visual mode removes one level of blockquote from all selected
   lines.
6. Empty lines within a visual selection are given a bare `>` prefix (not left
   unquoted), maintaining valid blockquote structure.
7. `<leader>mC` in visual mode wraps the selection in a callout, prompting for
   the callout type, producing `> [!TYPE]` on the first line and `> ` prefix on
   all subsequent lines.
8. `<leader>mC` in normal mode creates a single-line callout scaffold at the
   cursor: `> [!NOTE]` with cursor positioned to type content.
9. All keybindings are buffer-local to markdown files, defined in
   `ftplugin/markdown.lua`.
10. The new keybindings complement `aq`/`iq` text objects -- `<leader>mq` to
    create, `aq`/`iq` to select, `<leader>mQ` to remove.
11. Dot-repeatable where possible (single-line normal mode operations).

---

## Approach

### Architecture

All logic lives in `ftplugin/markdown.lua` as local functions, following the
pattern established by `toggle_markup()`, `toggle_heading()`, and the existing
`map()`/`vmap()` helpers. No new modules are created.

The implementation uses `nvim_buf_get_lines` / `nvim_buf_set_lines` for all line
manipulation, operating on 0-indexed line ranges. This avoids `:s` commands and
ensures the operations are silent, fast, and work correctly with undo.

### Key Design Decisions

**Toggle vs. always-add for `<leader>mq`**: The keybinding *always adds* a
level rather than toggling (removing if present). This matches the mental model
of "quote this text" as an additive action. To remove quoting, use `<leader>mQ`.
This avoids ambiguity when operating on mixed content (some lines quoted, some
not) in visual mode.

**Blank line handling**: When adding `> ` to a range of lines, blank lines
receive a bare `>` (no trailing space). This is the standard markdown convention
for continuing a blockquote across paragraphs:

```markdown
> First paragraph of the quote.
>
> Second paragraph of the quote.
```

**Callout type prompt**: `<leader>mC` uses `vim.ui.select()` with a predefined
list of common callout types (NOTE, TIP, WARNING, IMPORTANT, CAUTION, etc.)
rather than `vim.ui.input()`. This provides completion and avoids typos. A
custom type option is available at the end of the list.

---

## Implementation Steps

### Step 1: Add `quote_lines()` helper function

This is the core function that adds or removes `> ` prefixes from a range of
buffer lines.

Add after the `toggle_heading()` function block (after line 387 in the current
`ftplugin/markdown.lua`):

```lua
-- =============================================================================
-- Blockquote / Callout Creation
-- =============================================================================

--- Add one level of blockquote prefix (`> `) to the given lines.
--- Blank lines receive a bare `>` to maintain blockquote continuity.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
local function add_blockquote(start_row, end_row)
  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  for i, line in ipairs(lines) do
    if line:match("^%s*$") then
      -- Blank line: add bare `>` (no trailing space)
      lines[i] = ">"
    else
      lines[i] = "> " .. line
    end
  end
  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, lines)
end

--- Remove one level of blockquote prefix from the given lines.
--- Handles `> ` (with space), `>` (bare, on blank lines), and nested `> > `.
--- Lines without a `>` prefix are left unchanged.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
local function remove_blockquote(start_row, end_row)
  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  for i, line in ipairs(lines) do
    -- Match `> ` (with trailing space) -- standard prefix
    local rest = line:match("^> (.*)")
    if rest then
      lines[i] = rest
    else
      -- Match bare `>` (blank quoted line or no trailing space)
      rest = line:match("^>(.*)")
      if rest then
        -- If rest is empty or only whitespace, this was a blank quoted line
        lines[i] = rest == "" and "" or rest
      end
      -- else: line has no `>` prefix, leave unchanged
    end
  end
  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, lines)
end
```

### Step 2: Add normal-mode `<leader>mq` (add blockquote level)

```lua
map("<leader>mq", function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  add_blockquote(row, row)
end, "Add blockquote level")
```

### Step 3: Add visual-mode `<leader>mq` (add blockquote to selection)

```lua
vmap("<leader>mq", function()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  add_blockquote(start_row, end_row)
end, "Add blockquote level")
```

### Step 4: Add normal-mode `<leader>mQ` (remove blockquote level)

```lua
map("<leader>mQ", function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  remove_blockquote(row, row)
end, "Remove blockquote level")
```

### Step 5: Add visual-mode `<leader>mQ` (remove blockquote from selection)

```lua
vmap("<leader>mQ", function()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  remove_blockquote(start_row, end_row)
end, "Remove blockquote level")
```

### Step 6: Add callout creation (`<leader>mC`)

The callout types follow the Obsidian/GitHub convention. The list is ordered by
frequency of use.

```lua
--- Callout types for vim.ui.select()
local callout_types = {
  "NOTE",
  "TIP",
  "WARNING",
  "IMPORTANT",
  "CAUTION",
  "ABSTRACT",
  "INFO",
  "TODO",
  "SUCCESS",
  "QUESTION",
  "FAILURE",
  "DANGER",
  "BUG",
  "EXAMPLE",
  "QUOTE",
  "custom...",
}

--- Create a callout block from lines.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
--- @param callout_type string  The callout type (e.g., "NOTE", "WARNING")
local function create_callout(start_row, end_row, callout_type)
  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  local result = {}

  -- First line: `> [!TYPE]` followed by the original first line as title (if non-empty)
  local first = lines[1] or ""
  if first:match("^%s*$") then
    result[1] = "> [!" .. callout_type .. "]"
  else
    result[1] = "> [!" .. callout_type .. "] " .. first
  end

  -- Remaining lines: prefix with `> `
  for i = 2, #lines do
    local line = lines[i]
    if line:match("^%s*$") then
      result[i] = ">"
    else
      result[i] = "> " .. line
    end
  end

  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, result)
end

--- Prompt for callout type, then wrap lines.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
local function prompt_callout(start_row, end_row)
  vim.ui.select(callout_types, { prompt = "Callout type:" }, function(choice)
    if not choice then
      return
    end
    if choice == "custom..." then
      vim.ui.input({ prompt = "Custom callout type: " }, function(custom)
        if not custom or custom == "" then
          return
        end
        create_callout(start_row, end_row, custom:upper())
      end)
    else
      create_callout(start_row, end_row, choice)
    end
  end)
end
```

Normal-mode keymap -- creates a single-line callout scaffold at the cursor:

```lua
map("<leader>mC", function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  prompt_callout(row, row)
end, "Create callout")
```

Visual-mode keymap -- wraps the selection in a callout:

```lua
vmap("<leader>mC", function()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  prompt_callout(start_row, end_row)
end, "Create callout")
```

### Step 7: Update which-key hints (optional)

The existing which-key block at the bottom of `ftplugin/markdown.lua` does not
need changes. The `<leader>m` group is already registered as "Markdown" for
buffer 0, and the individual keymaps will auto-populate via their `desc` fields.

---

## Complete Code Block

The following is the complete code to add to `ftplugin/markdown.lua`, inserted
after the "Toggle Heading Level" section (after line 387) and before the
"Spell Checking Toggle" section:

```lua
-- =============================================================================
-- Blockquote / Callout Creation
-- =============================================================================

--- Add one level of blockquote prefix (`> `) to the given lines.
--- Blank lines receive a bare `>` to maintain blockquote continuity.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
local function add_blockquote(start_row, end_row)
  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  for i, line in ipairs(lines) do
    if line:match("^%s*$") then
      lines[i] = ">"
    else
      lines[i] = "> " .. line
    end
  end
  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, lines)
end

--- Remove one level of blockquote prefix from the given lines.
--- Handles `> ` (with space), `>` (bare, on blank lines), and nested `> > `.
--- Lines without a `>` prefix are left unchanged.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
local function remove_blockquote(start_row, end_row)
  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  for i, line in ipairs(lines) do
    local rest = line:match("^> (.*)")
    if rest then
      lines[i] = rest
    else
      rest = line:match("^>(.*)")
      if rest then
        lines[i] = rest == "" and "" or rest
      end
    end
  end
  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, lines)
end

-- Add blockquote level: <leader>mq
map("<leader>mq", function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  add_blockquote(row, row)
end, "Add blockquote level")

vmap("<leader>mq", function()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  add_blockquote(start_row, end_row)
end, "Add blockquote level")

-- Remove blockquote level: <leader>mQ
map("<leader>mQ", function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  remove_blockquote(row, row)
end, "Remove blockquote level")

vmap("<leader>mQ", function()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  remove_blockquote(start_row, end_row)
end, "Remove blockquote level")

-- Callout creation: <leader>mC
local callout_types = {
  "NOTE",
  "TIP",
  "WARNING",
  "IMPORTANT",
  "CAUTION",
  "ABSTRACT",
  "INFO",
  "TODO",
  "SUCCESS",
  "QUESTION",
  "FAILURE",
  "DANGER",
  "BUG",
  "EXAMPLE",
  "QUOTE",
  "custom...",
}

--- Create a callout block from lines.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
--- @param callout_type string  e.g., "NOTE", "WARNING"
local function create_callout(start_row, end_row, callout_type)
  local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)
  local result = {}
  local first = lines[1] or ""
  if first:match("^%s*$") then
    result[1] = "> [!" .. callout_type .. "]"
  else
    result[1] = "> [!" .. callout_type .. "] " .. first
  end
  for i = 2, #lines do
    local line = lines[i]
    if line:match("^%s*$") then
      result[i] = ">"
    else
      result[i] = "> " .. line
    end
  end
  vim.api.nvim_buf_set_lines(0, start_row - 1, end_row, false, result)
end

--- Prompt for callout type, then wrap lines.
--- @param start_row number  1-indexed start line
--- @param end_row number    1-indexed end line (inclusive)
local function prompt_callout(start_row, end_row)
  vim.ui.select(callout_types, { prompt = "Callout type:" }, function(choice)
    if not choice then
      return
    end
    if choice == "custom..." then
      vim.ui.input({ prompt = "Custom callout type: " }, function(custom)
        if not custom or custom == "" then
          return
        end
        create_callout(start_row, end_row, custom:upper())
      end)
    else
      create_callout(start_row, end_row, choice)
    end
  end)
end

map("<leader>mC", function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  prompt_callout(row, row)
end, "Create callout")

vmap("<leader>mC", function()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  prompt_callout(start_row, end_row)
end, "Create callout")
```

---

## Testing

### Manual Test Plan

Open a test markdown file:

```
nvim /tmp/test-blockquote.md
```

With this content:

```markdown
# Blockquote Test

This is a plain line.

Another plain line.

An existing quote:

> Already quoted line.
> Second quoted line.

A nested quote:

> Outer level
> > Inner level
> > Still inner
> Back to outer

A multi-paragraph block:

First paragraph line one.
First paragraph line two.

Second paragraph line one.
```

#### `<leader>mq` -- Add Blockquote (Normal Mode)

1. **Plain line**: Cursor on "This is a plain line.", press `<leader>mq`.
   Expected: `> This is a plain line.`

2. **Already quoted**: Cursor on `> Already quoted line.`, press `<leader>mq`.
   Expected: `> > Already quoted line.` (nested one level deeper)

3. **Doubly nested**: Cursor on `> > Inner level`, press `<leader>mq`.
   Expected: `> > > Inner level`

4. **Blank line**: Cursor on an empty line, press `<leader>mq`.
   Expected: `>`

5. **Dot repeat**: After step 1, move to "Another plain line." and press `.`.
   Expected: `> Another plain line.`

#### `<leader>mq` -- Add Blockquote (Visual Mode)

6. **Multi-line selection**: Select lines "First paragraph line one." through
   "Second paragraph line one." (5 lines including blank line) with `V4j`.
   Press `<leader>mq`. Expected:

   ```markdown
   > First paragraph line one.
   > First paragraph line two.
   >
   > Second paragraph line one.
   ```

   Note: the blank line between paragraphs becomes `>` (bare, no trailing space).

7. **Mixed content**: Select a range containing both quoted and unquoted lines.
   All lines should gain one additional `> ` level.

#### `<leader>mQ` -- Remove Blockquote (Normal Mode)

8. **Single level**: Cursor on `> This is a plain line.`, press `<leader>mQ`.
   Expected: `This is a plain line.`

9. **Nested**: Cursor on `> > Already quoted line.`, press `<leader>mQ`.
   Expected: `> Already quoted line.` (one level removed)

10. **Bare quoted blank**: Cursor on `>` (blank quoted line), press `<leader>mQ`.
    Expected: empty line.

11. **Non-quoted line**: Cursor on a line without `>` prefix, press `<leader>mQ`.
    Expected: no change.

#### `<leader>mQ` -- Remove Blockquote (Visual Mode)

12. **Multi-line unquote**: Select the entire existing quote block (`> Already
    quoted line.` through `> Second quoted line.`) with `Vj`. Press
    `<leader>mQ`. Expected: both `> ` prefixes removed.

13. **Mixed nesting**: Select lines with different nesting levels. Each line
    should lose exactly one `> ` level.

#### `<leader>mC` -- Create Callout (Normal Mode)

14. **Empty line**: Cursor on a blank line, press `<leader>mC`. Select "NOTE"
    from the picker. Expected: `> [!NOTE]`

15. **Line with text**: Cursor on "This is a plain line.", press `<leader>mC`.
    Select "WARNING". Expected: `> [!WARNING] This is a plain line.`

#### `<leader>mC` -- Create Callout (Visual Mode)

16. **Multi-line callout**: Select "First paragraph line one." through "First
    paragraph line two." with `Vj`. Press `<leader>mC`. Select "TIP". Expected:

    ```markdown
    > [!TIP] First paragraph line one.
    > First paragraph line two.
    ```

17. **With blank lines**: Select lines including a blank line. Press
    `<leader>mC`, select "IMPORTANT". Expected: blank lines become `>`.

18. **Custom type**: Press `<leader>mC`, select "custom...", enter "RECIPE".
    Expected: `> [!RECIPE] ...`

19. **Cancel**: Press `<leader>mC`, press Escape/cancel in the picker.
    Expected: no changes to the buffer.

#### Interaction with `aq`/`iq` Text Objects

20. **Create then select**: On a plain line, press `<leader>mq` to quote it.
    Then press `vaq`. Expected: the newly quoted line is selected.

21. **Select then unquote**: On a multi-line blockquote, press `vaq` to select
    it, then press `<leader>mQ`. Expected: all `> ` prefixes removed from the
    selected lines.

22. **Delete inside then re-quote**: Press `diq` on a blockquote to delete
    content (leaving the `> ` skeleton or removing it). Verify the operation
    works cleanly. Then `u` to undo and try `<leader>mQ` instead.

### Automated Verification

Check that all keymaps are registered:

```vim
:verbose nmap <leader>mq
:verbose nmap <leader>mQ
:verbose nmap <leader>mC
:verbose vmap <leader>mq
:verbose vmap <leader>mQ
:verbose vmap <leader>mC
```

All six should show source as `ftplugin/markdown.lua` with buffer-local scope.

---

## Risks & Mitigations

### 1. `<leader>mq` conflicts

**Risk**: `<leader>mq` could conflict with a future keymap or plugin.

**Mitigation**: The `q` mnemonic is natural for "quote" and `<leader>m` is
already the markdown prefix. No current global or buffer-local binding uses
`<leader>mq`. The binding is buffer-local so it cannot leak to other filetypes.

### 2. Undo granularity

**Risk**: Visual-mode operations modify multiple lines in a single
`nvim_buf_set_lines` call, which creates a single undo entry. This is correct
behavior -- undoing a "quote 10 lines" operation should undo all 10 lines at
once, not one at a time.

**Mitigation**: No action needed. The current behavior matches user expectations.

### 3. Lines already prefixed with `>` but not a blockquote

**Risk**: Some content (e.g., email-style quotes, diff output) starts with `>`
but is not a markdown blockquote. `<leader>mQ` would strip the `>` prefix.

**Mitigation**: This is a conscious trade-off. The keybinding operates on raw
text, not semantic analysis. If the user presses `<leader>mQ` on a line starting
with `>`, it will remove the prefix regardless of intent. This matches how
`<leader>m1` through `<leader>m6` operate on `#` prefixes without checking
whether the `#` is truly a heading.

### 4. Callout on already-quoted lines

**Risk**: If the user selects lines that are already inside a blockquote and
presses `<leader>mC`, the result will be a nested callout:
`> > [!NOTE] content`. This may not be the intended outcome.

**Mitigation**: Document this behavior. If the user wants to convert an existing
blockquote into a callout, they should first `<leader>mQ` to remove the quoting,
then `<leader>mC` to create the callout. Alternatively, the `create_callout`
function could detect and strip existing `> ` prefixes before adding the callout,
but this adds complexity and is not always the desired behavior (sometimes nested
callouts are intentional).

### 5. `vim.ui.select()` backend differences

**Risk**: The callout type picker uses `vim.ui.select()`, which may render
differently depending on the UI backend (default, telescope, dressing.nvim,
etc.). Some backends may not support the `prompt` option.

**Mitigation**: `vim.ui.select()` is a stable Neovim API. All major UI backends
(telescope, dressing, fzf-lua) support it. The fallback default Neovim
implementation also works. No special handling is needed.

### 6. Cursor position after operation

**Risk**: After adding/removing blockquote prefixes, the cursor column position
may shift. For example, if the cursor was on column 5 and `> ` (2 chars) is
prepended, the cursor should ideally be on column 7 to stay on the same
character.

**Mitigation**: The `nvim_buf_set_lines` API does not move the cursor; Neovim
adjusts it automatically to stay within the line bounds. For normal-mode
single-line operations, the cursor remains on the same line. The column shift is
minor (2 characters) and matches how other prefix operations (`<leader>m1` for
headings) behave -- they also do not adjust cursor column. If this proves
annoying in practice, a future enhancement can save/restore the cursor column
with an offset of `+2` or `-2`.

### 7. Backwards compatibility

**Risk**: No existing keybindings are overridden. `<leader>mq`, `<leader>mQ`,
and `<leader>mC` are all currently unbound in markdown buffers.

**Mitigation**: None needed. This is purely additive.
