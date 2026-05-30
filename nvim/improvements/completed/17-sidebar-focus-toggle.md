# 17 — Sidebar Focus Toggle

> Switch focus between the current editor buffer and the sidebar panel when
> the `<leader>vS` sidebar group is open.

## Problem

When the sidebar is visible, there is no dedicated keybinding to move focus
into the sidebar window or back to the editor. Users must rely on generic
window navigation (`<C-h>`/`<C-l>` via tmux-navigator) to reach the sidebar.
This is unintuitive because:

1. The sidebar position is configurable (left or right), so the correct
   directional key varies.
2. There is no semantic "toggle focus to sidebar" action — the user must
   remember which direction the sidebar is in.
3. `<leader>vS` currently closes the sidebar if it is open, rather than
   focusing it. Closing is destructive when the user just wants to interact
   with the panel.

## Desired Behavior

| Context                       | `<leader>vSf` Action                     |
|-------------------------------|-------------------------------------------|
| Sidebar closed                | Open sidebar (default panel), keep focus on editor |
| Sidebar open, focus on editor | Move focus to sidebar window              |
| Sidebar open, focus on sidebar| Return focus to source (editor) window    |

A dedicated **`<leader>vSf`** keybinding provides a quick, position-agnostic
focus toggle. The existing `<leader>vS` toggle (open/close) remains unchanged.

Additionally, inside the sidebar buffer, **`<Esc>`** returns focus to the
editor (matching the "escape back" convention used in preview.lua and other
vault floating windows).

## Files to Modify

| File | Change |
|------|--------|
| `lua/andrew/vault/sidebar.lua` | Add `M.focus_toggle()`, keybinding, command, palette entry, `<Esc>` keymap |
| `lua/andrew/plugins/which-key.lua` | No change needed (auto-discovered by which-key from desc) |

## Implementation

### 1. Add `M.focus_toggle()` to `sidebar.lua`

Insert after `M.is_visible()` (after line 367):

```lua
--- Toggle focus between the sidebar and the source (editor) window.
--- If the sidebar is not visible, open it first (focus stays on editor).
--- If focus is currently on the sidebar, return to source window.
--- If focus is on the editor, move to the sidebar.
function M.focus_toggle()
  -- If sidebar is not open, open it (opens with focus on editor by default)
  if not M.is_visible() then
    M.open()
    return
  end

  local cur_win = vim.api.nvim_get_current_win()

  if cur_win == _state.win then
    -- Currently in sidebar → return to source window
    if _state.source_win and vim.api.nvim_win_is_valid(_state.source_win) then
      vim.api.nvim_set_current_win(_state.source_win)
    end
  else
    -- Currently in editor → focus sidebar
    -- Update source tracking before switching
    _state.source_win = cur_win
    _state.source_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_win(_state.win)
  end
end
```

**Key detail:** When moving focus *to* the sidebar, we first update
`_state.source_win` and `_state.source_buf` to the current editor window/buf.
This ensures "return to editor" always goes back to the right place, even if
the user has moved to a different split since the sidebar was opened.

### 2. Add `<Esc>` keymap inside the sidebar buffer

In `setup_shared_keymaps(buf)`, add alongside the existing `q` close keymap
(after line 240):

```lua
  -- Return focus to editor (without closing)
  vim.keymap.set("n", "<Esc>", function()
    if _state.source_win and vim.api.nvim_win_is_valid(_state.source_win) then
      vim.api.nvim_set_current_win(_state.source_win)
    end
  end, vim.tbl_extend("force", opts, { desc = "Return focus to editor" }))
```

### 3. Add global keybinding

In `M.setup()`, alongside the existing `<leader>vS*` keymaps (after line 468):

```lua
  vim.keymap.set("n", "<leader>vSf", function()
    M.focus_toggle()
  end, { desc = "Vault: sidebar focus toggle", silent = true })
```

### 4. Add user command

In `M.setup()`, alongside existing user commands (after line 451):

```lua
  vim.api.nvim_create_user_command("VaultSidebarFocus", function()
    M.focus_toggle()
  end, { desc = "Toggle focus between sidebar and editor" })
```

### 5. Register in command palette

In `M.setup()`, alongside existing palette registrations (after line 483):

```lua
  palette.register_command("VaultSidebarFocus", "Toggle focus between sidebar and editor", "Sidebar", function()
    M.focus_toggle()
  end, "<leader>vSf")
```

### 6. Update help text

In `setup_shared_keymaps`, update the `?` help table to include the new
keybindings:

```lua
    local help = {
      "Sidebar Keybindings:",
      "",
      "  q          Close sidebar",
      "  <Esc>      Return focus to editor",
      "  1 / b      Backlinks panel",
      "  2 / t      Tag tree panel",
      "  3 / m      Metadata panel",
      "  Tab        Next panel",
      "  S-Tab      Previous panel",
      "  R          Force refresh",
      "  ?          This help",
      "",
      "Global:  <leader>vSf  Toggle sidebar focus",
      "",
      "Panel-specific keys shown in each panel.",
    }
```

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Source window was closed (e.g., `:q` on last split) | `nvim_win_is_valid` check fails; sidebar stays focused (no crash) |
| Multiple editor splits open | `source_win` is updated on every focus-to-sidebar, so it always returns to the most recently active editor window |
| `BufEnter` autocmd fires on sidebar focus | Already guarded: `on_buf_change` returns early if `ev.buf == _state.buf` (line 379) |
| Sidebar is on the left instead of right | Focus toggle is position-agnostic (uses window handles, not directional commands) |
| User navigates to sidebar via `<C-l>` then uses `<leader>vSf` | `cur_win == _state.win` detects this correctly and returns to `_state.source_win` |

## Testing

1. Open a vault markdown file.
2. `<leader>vS` to open sidebar (focus stays on editor).
3. `<leader>vSf` to focus sidebar (cursor moves into sidebar window).
4. `<leader>vSf` again to return to editor.
5. `<Esc>` while in sidebar also returns focus to editor.
6. Close the editor split (`:q`), verify `<leader>vSf` from sidebar does not crash.
7. Open two editor splits, focus one, `<leader>vSf` to sidebar, `<leader>vSf`
   back — verify it returns to the split you came from, not the original one.

## Summary of Changes

| What | Details |
|------|---------|
| New function | `M.focus_toggle()` — 15 lines |
| New global keymap | `<leader>vSf` |
| New buffer keymap | `<Esc>` (inside sidebar) |
| New user command | `:VaultSidebarFocus` |
| New palette entry | "Toggle focus between sidebar and editor" |
| Modified help text | 2 lines added to `?` help |
| Total LoC changed | ~35 lines added to `sidebar.lua` |
