# 38 --- Add Missing Common Keymaps

## Motivation

The core keymaps file (`lua/andrew/core/keymaps.lua`) covers leader-prefixed
operations (splits, tabs, search clearing, number manipulation) but is missing
several widely-used "quality of life" keymaps that most Neovim users expect:

1. **Quickfix navigation** (`]q`/`[q`) -- jumping through compiler errors,
   grep results, and linting output is a bread-and-butter workflow.
2. **Visual-mode line movement** (`J`/`K`) -- moving selected lines up and
   down while preserving selection and re-indenting.
3. **Window resizing via arrow keys** (`<C-Up/Down/Left/Right>`) -- resizing
   splits without memorizing `<C-w>+`, `<C-w>-`, `<C-w><`, `<C-w>>` combos.

These are small, non-controversial additions that fill obvious gaps in the
editor experience.

---

## Current State Analysis

### File: `lua/andrew/core/keymaps.lua`

The file contains 73 lines organized into five sections:

| Section | Keys | Description |
|---------|------|-------------|
| Insert mode | `jk` | Exit insert mode |
| Normal mode | `<leader>nh`, `<leader>+/-` | Clear search, inc/dec number |
| Window mgmt | `<leader>sv/sh/se/sx` | Split create/equalize/close |
| Tab mgmt | `<leader>to/tx/tn/tp/tf` | Tab create/close/navigate |
| Autocommands | `TextYankPost` | Yank highlight |

No bracket-style motions (`]`/`[`), no visual-mode keymaps, and no `<C-Arrow>`
keymaps exist in this file.

### Conflict Check: `]q`/`[q`

**There IS a conflict.** The markdown text-objects module
(`lua/andrew/utils/md-textobjects.lua`, lines 731-732) maps `]q`/`[q` to
blockquote motions in `{ "n", "x", "o" }` modes:

```lua
-- Blockquote motions
map({ "n", "x", "o" }, "]q", M.next_blockquote, "Next blockquote")
map({ "n", "x", "o" }, "[q", M.prev_blockquote, "Previous blockquote")
```

These are set as **buffer-local** keymaps inside `ftplugin/markdown.lua` (line
126 calls `require("andrew.utils.md-textobjects").setup()`), which makes them
buffer-local via the `{ buffer = true }` option that `setup()` uses.

**Resolution:** Buffer-local keymaps take precedence over global keymaps in
Neovim. This means:

- In **markdown buffers**: `]q`/`[q` will continue to jump between blockquotes
  (buffer-local wins).
- In **all other buffers**: `]q`/`[q` will navigate the quickfix list (global
  mapping applies).

This is the **correct and desirable behavior**. When editing markdown, blockquote
navigation is more useful; in code buffers, quickfix navigation is what you want.
No changes to md-textobjects.lua are needed.

**Verification:** Confirm that `md-textobjects.lua`'s `setup()` function uses
buffer-local mappings. Looking at the module (line 700+), the local `map`
helper wraps `vim.keymap.set` with `{ buffer = 0 }`, confirming buffer-local
scope.

### Conflict Check: `J`/`K` in Visual Mode

`J` in visual mode is Neovim's built-in "join lines" command. This is a
**deliberate override** -- the join-lines behavior in visual mode is rarely
used compared to line movement, and the join command remains available via `gJ`
or by exiting visual mode and pressing `J` in normal mode.

`K` in visual mode runs the `keywordprg` (typically `man` or LSP hover). This
is also rarely used in visual mode specifically; LSP hover via `K` in normal
mode remains unaffected.

### Conflict Check: `<C-Arrow>` Keys

No existing `<C-Arrow>` keymaps exist anywhere in the config (confirmed via
grep). These keys have no default Neovim behavior in normal mode, so there are
no conflicts.

### Existing Quickfix Access

The config already has `<leader>xq` (trouble.lua, line 82) to toggle the
quickfix list view. What is missing is the ability to step through quickfix
entries one at a time without opening the full list.

---

## Implementation

### Target File

All three keymap groups go into **`lua/andrew/core/keymaps.lua`** because they
are global, filetype-independent keymaps that should always be available.

### Which-Key Integration

None of these keymaps use `<leader>` prefixes, so no which-key group
registration is needed. The `desc` field on each keymap is sufficient for
which-key to display them when the user presses `]`, `[`, or views keymaps via
`:WhichKey`.

---

### Group 1: Quickfix Navigation (`]q`/`[q`)

#### Code to Add

```lua
-- =============================================================================
-- Quickfix Navigation
-- =============================================================================
-- Jump through quickfix list entries (compiler errors, grep results, etc.)
-- Note: In markdown buffers, ]q/[q are overridden by buffer-local blockquote motions.

keymap.set("n", "]q", "<cmd>cnext<CR>zz", { desc = "Next quickfix item" })
keymap.set("n", "[q", "<cmd>cprev<CR>zz", { desc = "Previous quickfix item" })
```

The `zz` suffix centers the screen on the target line after jumping, matching
the heading-jump behavior already established in `ftplugin/markdown.lua`.

#### Insertion Point

After the "Number manipulation keybindings" section (after line 29), before the
"Window Management Keybindings" section header (line 31).

#### Before/After

**Before** (lines 28-33):

```lua
keymap.set("n", "<leader>+", "<C-a>", { desc = "Increment number under cursor" })
keymap.set("n", "<leader>-", "<C-x>", { desc = "Decrement number under cursor" })

-- =============================================================================
-- Window Management Keybindings
-- =============================================================================
```

**After:**

```lua
keymap.set("n", "<leader>+", "<C-a>", { desc = "Increment number under cursor" })
keymap.set("n", "<leader>-", "<C-x>", { desc = "Decrement number under cursor" })

-- =============================================================================
-- Quickfix Navigation
-- =============================================================================
-- Jump through quickfix list entries (compiler errors, grep results, etc.)
-- Note: In markdown buffers, ]q/[q are overridden by buffer-local blockquote motions.

keymap.set("n", "]q", "<cmd>cnext<CR>zz", { desc = "Next quickfix item" })
keymap.set("n", "[q", "<cmd>cprev<CR>zz", { desc = "Previous quickfix item" })

-- =============================================================================
-- Window Management Keybindings
-- =============================================================================
```

---

### Group 2: Visual Mode Line Movement (`J`/`K`)

#### Code to Add

```lua
-- =============================================================================
-- Visual Mode Line Movement
-- =============================================================================
-- Move selected lines up/down while maintaining selection and auto-indenting.
-- Overrides visual-mode J (join) and K (keywordprg), which are rarely used in
-- visual mode. Normal-mode J and K remain unaffected.

keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selection down" })
keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selection up" })
```

**How it works:**

- `:m '>+1<CR>` -- the `:move` command places the selected lines after the
  line below the selection end (`'>` is the end-of-selection mark, `+1` is one
  line past it).
- `:m '<-2<CR>` -- places selected lines before the line above the selection
  start (`'<` is the start-of-selection mark, `-2` is two lines above it,
  which is one line above the first selected line).
- `gv` -- re-selects the previously selected visual area (now at its new
  position).
- `=` -- auto-indents the selection to match surrounding context.
- `gv` -- re-selects again after indentation so the user can continue moving.

#### Insertion Point

After the Quickfix Navigation section, before the Window Management section.

#### Before/After

**Before:**

```lua
keymap.set("n", "[q", "<cmd>cprev<CR>zz", { desc = "Previous quickfix item" })

-- =============================================================================
-- Window Management Keybindings
-- =============================================================================
```

**After:**

```lua
keymap.set("n", "[q", "<cmd>cprev<CR>zz", { desc = "Previous quickfix item" })

-- =============================================================================
-- Visual Mode Line Movement
-- =============================================================================
-- Move selected lines up/down while maintaining selection and auto-indenting.
-- Overrides visual-mode J (join) and K (keywordprg), which are rarely used in
-- visual mode. Normal-mode J and K remain unaffected.

keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selection down" })
keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selection up" })

-- =============================================================================
-- Window Management Keybindings
-- =============================================================================
```

---

### Group 3: Window Resizing (`<C-Arrow>`)

#### Code to Add

```lua
-- Window resizing via Ctrl+Arrow keys
keymap.set("n", "<C-Up>", "<cmd>resize +2<CR>", { desc = "Increase window height" })
keymap.set("n", "<C-Down>", "<cmd>resize -2<CR>", { desc = "Decrease window height" })
keymap.set("n", "<C-Left>", "<cmd>vertical resize -2<CR>", { desc = "Decrease window width" })
keymap.set("n", "<C-Right>", "<cmd>vertical resize +2<CR>", { desc = "Increase window width" })
```

The step size of 2 provides a good balance between responsiveness and
precision. The user can hold the key for rapid resizing.

#### Insertion Point

Inside the existing "Window Management Keybindings" section, after the
`<leader>sx` close-split keymap (line 42) and before the "Tab Management
Keybindings" section header (line 44).

#### Before/After

**Before** (lines 41-46):

```lua
keymap.set("n", "<leader>se", "<C-w>=", { desc = "Make all split windows equal size" })
keymap.set("n", "<leader>sx", "<cmd>close<CR>", { desc = "Close current split window" })

-- =============================================================================
-- Tab Management Keybindings
-- =============================================================================
```

**After:**

```lua
keymap.set("n", "<leader>se", "<C-w>=", { desc = "Make all split windows equal size" })
keymap.set("n", "<leader>sx", "<cmd>close<CR>", { desc = "Close current split window" })

-- Window resizing via Ctrl+Arrow keys
keymap.set("n", "<C-Up>", "<cmd>resize +2<CR>", { desc = "Increase window height" })
keymap.set("n", "<C-Down>", "<cmd>resize -2<CR>", { desc = "Decrease window height" })
keymap.set("n", "<C-Left>", "<cmd>vertical resize -2<CR>", { desc = "Decrease window width" })
keymap.set("n", "<C-Right>", "<cmd>vertical resize +2<CR>", { desc = "Increase window width" })

-- =============================================================================
-- Tab Management Keybindings
-- =============================================================================
```

---

## Complete File After All Changes

For reference, the full `lua/andrew/core/keymaps.lua` after all three groups
are added:

```lua
-- =============================================================================
-- Core Keybindings
-- =============================================================================
-- Global key mappings that apply to the entire editor.
-- These bindings are set before plugins load and provide essential editor navigation.

-- Set the leader key to space (all leader keymaps use this prefix)
vim.g.mapleader = " "

-- Local alias for vim.keymap to make keybinding definitions more concise
local keymap = vim.keymap

-- =============================================================================
-- Insert Mode Keybindings
-- =============================================================================

-- Exit insert mode quickly by typing "jk" (ergonomic alternative to Escape)
keymap.set("i", "jk", "<ESC>", { desc = "Exit insert mode with jk" })

-- =============================================================================
-- Normal Mode Keybindings
-- =============================================================================

-- Search-related keybindings
keymap.set("n", "<leader>nh", ":nohl<CR>", { desc = "Clear search results" })

-- Number manipulation keybindings
keymap.set("n", "<leader>+", "<C-a>", { desc = "Increment number under cursor" })
keymap.set("n", "<leader>-", "<C-x>", { desc = "Decrement number under cursor" })

-- =============================================================================
-- Quickfix Navigation
-- =============================================================================
-- Jump through quickfix list entries (compiler errors, grep results, etc.)
-- Note: In markdown buffers, ]q/[q are overridden by buffer-local blockquote motions.

keymap.set("n", "]q", "<cmd>cnext<CR>zz", { desc = "Next quickfix item" })
keymap.set("n", "[q", "<cmd>cprev<CR>zz", { desc = "Previous quickfix item" })

-- =============================================================================
-- Visual Mode Line Movement
-- =============================================================================
-- Move selected lines up/down while maintaining selection and auto-indenting.
-- Overrides visual-mode J (join) and K (keywordprg), which are rarely used in
-- visual mode. Normal-mode J and K remain unaffected.

keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selection down" })
keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selection up" })

-- =============================================================================
-- Window Management Keybindings
-- =============================================================================
-- These keybindings use the window prefix <leader>s for split operations

-- Create new splits for horizontal/vertical window layouts
keymap.set("n", "<leader>sv", "<C-w>v", { desc = "Split window vertically" })
keymap.set("n", "<leader>sh", "<C-w>s", { desc = "Split window horizontally" })

-- Window layout adjustments
keymap.set("n", "<leader>se", "<C-w>=", { desc = "Make all split windows equal size" })
keymap.set("n", "<leader>sx", "<cmd>close<CR>", { desc = "Close current split window" })

-- Window resizing via Ctrl+Arrow keys
keymap.set("n", "<C-Up>", "<cmd>resize +2<CR>", { desc = "Increase window height" })
keymap.set("n", "<C-Down>", "<cmd>resize -2<CR>", { desc = "Decrease window height" })
keymap.set("n", "<C-Left>", "<cmd>vertical resize -2<CR>", { desc = "Decrease window width" })
keymap.set("n", "<C-Right>", "<cmd>vertical resize +2<CR>", { desc = "Increase window width" })

-- =============================================================================
-- Tab Management Keybindings
-- =============================================================================
-- These keybindings use the tab prefix <leader>t for tab operations

-- Tab creation and closure
keymap.set("n", "<leader>to", "<cmd>tabnew<CR>", { desc = "Open new tab" })
keymap.set("n", "<leader>tx", "<cmd>tabclose<CR>", { desc = "Close current tab" })

-- Tab navigation
keymap.set("n", "<leader>tn", "<cmd>tabn<CR>", { desc = "Go to next tab (navigate right)" })
keymap.set("n", "<leader>tp", "<cmd>tabp<CR>", { desc = "Go to previous tab (navigate left)" })

-- Move current buffer to a new tab
keymap.set("n", "<leader>tf", "<cmd>tabnew %<CR>", { desc = "Open current buffer in new tab" })

-- =============================================================================
-- Visual Feedback Autocommands
-- =============================================================================

-- Highlight text briefly after yanking (copying) to provide visual confirmation
-- This autocmd triggers on the TextYankPost event which fires after any yank operation
vim.api.nvim_create_autocmd("TextYankPost", {
  desc = "Highlight text briefly after yanking",
  group = vim.api.nvim_create_augroup("highlight-yank", { clear = true }),
  callback = function()
    -- Highlight the yanked text region for 300ms
    vim.hl.on_yank({ higroup = "IncSearch", timeout = 300 })
  end,
})
```

---

## Testing Instructions

### 1. Quickfix Navigation (`]q`/`[q`)

1. Open any non-markdown file (e.g., a Lua file).
2. Populate the quickfix list:
   ```
   :vimgrep /keymap/ lua/andrew/core/keymaps.lua
   ```
3. Press `]q` -- cursor should jump to the next quickfix entry and center the
   screen.
4. Press `[q` -- cursor should jump to the previous quickfix entry and center.
5. At the first item, `[q` should show an error (`E553: No more items`).
6. At the last item, `]q` should show an error (`E553: No more items`).
7. Open a markdown file and verify `]q`/`[q` still jump between blockquotes
   (buffer-local override), not quickfix entries.

### 2. Visual Mode Line Movement (`J`/`K`)

1. Open any file with multiple lines of code.
2. Enter visual line mode (`V`) and select 2-3 lines.
3. Press `J` -- the selected lines should move down one line. The selection
   should remain active on the moved lines. Indentation should adjust if
   needed.
4. Press `K` -- the selected lines should move back up. Selection stays active.
5. Verify rapid `J`/`K` presses move the block smoothly without losing
   selection.
6. Verify that `J` in **normal mode** still joins lines (the override only
   applies to visual mode).
7. Verify that `K` in **normal mode** still triggers LSP hover or keywordprg.
8. Test at file boundaries: selecting the last line and pressing `J` should do
   nothing (`:move` past end-of-file is a no-op). Selecting the first line and
   pressing `K` should do nothing.

### 3. Window Resizing (`<C-Arrow>`)

1. Open a file and create a vertical split: `<leader>sv`.
2. Press `<C-Right>` several times -- the current window should get wider.
3. Press `<C-Left>` several times -- the current window should get narrower.
4. Create a horizontal split: `<leader>sh`.
5. Press `<C-Up>` several times -- the current window should get taller.
6. Press `<C-Down>` several times -- the current window should get shorter.
7. With only a single window (no splits), all `<C-Arrow>` keys should be
   no-ops (`:resize` on a single window has no visible effect).
8. Verify that the step size of 2 feels responsive when held down.

---

## Post-Implementation Cleanup

After implementing these keymaps, the corresponding items should be removed
from any TODO tracking. Since `TODO.md` does not currently exist in the repo
root, check if these items are tracked elsewhere (e.g., inline TODO comments,
a project board, or personal notes) and mark them as complete.

Update the keymap reference documents if they exist:

- `KEYMAPS.md` -- add entries for the three new keymap groups.
- `KEYMAPS-REFERENCE.md` -- add quickfix nav and visual line movement.
- `KEYMAPS-COMPLETE.md` -- add all new keymaps to the comprehensive listing.
- `KEYMAPS-GUIDE.md` -- add to the relevant guide sections.

---

## Summary of Changes

| File | Lines Added | Description |
|------|-------------|-------------|
| `lua/andrew/core/keymaps.lua` | ~24 | Three new keymap sections: quickfix nav, visual line movement, window resizing |

No other files require modification. No new dependencies. No which-key group
registration needed (none of these use `<leader>` prefixes).
