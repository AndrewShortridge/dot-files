# 38 — Memory Cleanup Fixes

**Priority:** Medium-High
**Status:** Done
**Files:** `lua/andrew/vault/embed.lua`, `lua/andrew/vault/preview.lua`, `lua/andrew/vault/sidebar.lua`

## Summary

Three related memory/resource cleanup issues that can cause stale handles, leaked
snacks image placements, and unnecessary computation on non-vault buffers:

1. **Image placement leak in embed.lua** — the `image_placements` dict retains
   entries for buffers that have been deleted when the `BufDelete`/`BufWipeout`
   autocmd fires but the placement `:close()` call silently fails or the buffer
   was never properly tracked.  Additionally, `embeds_visible` and `_embed_deps`
   entries for invalid buffers are never garbage-collected during long sessions.
2. **Preview float stale state in preview.lua** — `state.win` / `state.buf` can
   reference invalid handles if the float is closed externally (e.g., `:q` in
   another plugin, `nvim_win_close` from user config) without triggering the
   `WinClosed` autocmd that calls `close_preview()`.
3. **Sidebar unnecessary refresh on non-vault buffers** — the `BufEnter` autocmd
   in `sidebar.lua` fires for every buffer type.  Although `on_buf_change()`
   checks `.md` extension and vault path, the `BufEnter` autocmd itself has no
   `pattern` filter, so it fires on every buffer enter event (help pages,
   terminal buffers, Telescope results, etc.) and runs two API calls before
   early-exiting.

---

## 1. Image Placement Cleanup (embed.lua)

### Current Behavior

`embed.lua` stores snacks image placements in the module-level dict:

```lua
local image_placements = {} -- bufnr -> list of snacks image placements
```

A `BufDelete`/`BufWipeout` autocmd exists (lines 961-971) that calls
`clear_image_placements(ev.buf)`.  However, there are two problems:

**Problem A:** During long editing sessions, buffers may become invalid without
triggering `BufDelete` or `BufWipeout` (e.g., `:bwipeout` from a plugin that
suppresses events, or buffer reuse).  The `embeds_visible`, `_embed_deps`, and
`image_placements` dicts accumulate stale entries keyed by old buffer numbers
that will never be cleaned up.

**Problem B:** The `clear_image_placements()` function calls `p:close()` inside
a `pcall`, which silently swallows errors.  If a placement was already closed or
its internal state is corrupted, the dict entry is still removed — but if the
loop itself errors (e.g., `image_placements[bufnr]` is not a table), the
cleanup is incomplete.

### Fix

Add periodic garbage collection of stale buffer entries, and make the existing
`BufDelete`/`BufWipeout` handler more robust.

#### Before (lines 130-138):

```lua
--- Clean up image placements for a buffer.
---@param bufnr number
local function clear_image_placements(bufnr)
  if image_placements[bufnr] then
    for _, p in ipairs(image_placements[bufnr]) do
      pcall(function() p:close() end)
    end
    image_placements[bufnr] = nil
  end
end
```

#### After:

```lua
--- Clean up image placements for a buffer.
---@param bufnr number
local function clear_image_placements(bufnr)
  local placements = image_placements[bufnr]
  if not placements then return end
  image_placements[bufnr] = nil  -- remove from dict first to avoid re-entrant issues
  if type(placements) == "table" then
    for _, p in ipairs(placements) do
      pcall(function() p:close() end)
    end
  end
end

--- Garbage-collect stale entries for buffers that are no longer valid.
--- Safe to call periodically (e.g., on a timer or BufEnter).
local function gc_stale_buffers()
  for bufnr in pairs(image_placements) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      clear_image_placements(bufnr)
    end
  end
  for bufnr in pairs(embeds_visible) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      embeds_visible[bufnr] = nil
    end
  end
  for bufnr in pairs(_embed_deps) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      _embed_deps[bufnr] = nil
    end
  end
  for bufnr in pairs(_sync_timers) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      cleanup_timer(bufnr)
    end
  end
end
```

Add a periodic GC call in `setup()`, inside the existing `BufEnter` autocmd
callback (runs cheaply, only iterates small dicts):

#### Before (BufEnter autocmd, lines 921-938):

```lua
vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if not engine.is_vault_path(bufpath) then return end
      ensure_subscription()
      if not embeds_visible[ev.buf] then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf)
            and vim.api.nvim_get_current_buf() == ev.buf
          then
            M.render_embeds({ silent = true })
          end
        end, 50)
      end
    end,
  })
```

#### After:

```lua
vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if not engine.is_vault_path(bufpath) then return end
      ensure_subscription()
      -- Periodically purge stale buffer entries (cheap: iterates small dicts)
      gc_stale_buffers()
      if not embeds_visible[ev.buf] then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf)
            and vim.api.nvim_get_current_buf() == ev.buf
          then
            M.render_embeds({ silent = true })
          end
        end, 50)
      end
    end,
  })
```

### Test Cases

1. Open a vault markdown file with image embeds, confirm placements appear.
   Run `:bwipeout` and verify `image_placements` no longer has an entry for
   that buffer number (inspect via `:VaultEmbedDebug` in another buffer).
2. Open 10+ vault files with embeds, close them all.  Open a new file and
   verify `gc_stale_buffers()` removes all stale entries (add a temporary
   `vim.notify` in `gc_stale_buffers` to confirm count of purged entries).
3. Run `:lua vim.print(vim.tbl_count(image_placements))` after a session with
   many opened/closed buffers — should be 0 or equal to the number of currently
   visible vault buffers with image embeds.

---

## 2. Preview Float State Cleanup (preview.lua)

### Current Behavior

The preview module tracks the active float in a module-level `state` table:

```lua
local state = {
  win = nil,
  buf = nil,
  parent_buf = nil,
  augroup = nil,
  focused = false,
}
```

A `WinClosed` autocmd (lines 707-713) triggers `close_preview()` when the float
window is closed.  The `is_active()` function (line 338) checks
`state.win ~= nil and vim.api.nvim_win_is_valid(state.win)`.

**Problem A:** If the preview float window is closed by an external mechanism
that doesn't fire `WinClosed` for the specific pattern (e.g., `:only`,
`:tabclose`, or a plugin calling `nvim_win_close` with `noautocmd`), `state.win`
retains a stale handle.  Subsequent calls to `is_active()` will correctly return
`false` (since `nvim_win_is_valid` catches it), but `state.buf`, `state.augroup`,
and parent buffer keymaps are never cleaned up.

**Problem B:** The `state.buf` handle can become invalid independently if the
buffer's `bufhidden = "wipe"` triggers buffer deletion before `close_preview()`
runs.  Functions like `replace_float_content()` check `is_active()` (which only
validates the window), then access `state.buf` which may be invalid.

**Problem C:** The `close_preview()` function calls `clear_history()` which
resets the history entries.  But if `close_preview` is called while `state.win`
is already invalid (stale handle scenario), the parent buffer keymaps may fail
to be deleted if `state.parent_buf` has also become invalid — `pcall` hides
the error but the keymaps remain on the (now-reused) buffer number.

### Fix

Add validation of both `state.win` and `state.buf` in `is_active()`, add a
guard in `replace_float_content()`, and add a safety check in `close_preview()`
to handle already-invalid handles.

#### Before `is_active()` (line 337-339):

```lua
local function is_active()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end
```

#### After:

```lua
--- Check if a preview is currently active (window AND buffer are valid).
local function is_active()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return false
  end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end
  return true
end
```

#### Before `close_preview` (lines 559-588):

```lua
close_preview = function()
  if state.focused then
    unfocus_preview()
  end

  if state.parent_buf and vim.api.nvim_buf_is_valid(state.parent_buf) then
    for _, key in ipairs({ "<C-j>", "<C-k>", "<C-o>", "<C-i>", "<BS>", "<CR>" }) do
      pcall(vim.keymap.del, "n", key, { buffer = state.parent_buf })
    end
  end

  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end

  state.win = nil
  state.buf = nil
  state.parent_buf = nil
  state.focused = false

  clear_history()
end
```

#### After:

```lua
close_preview = function()
  -- Guard against re-entrant calls (WinClosed -> close_preview -> nvim_win_close
  -- could fire WinClosed again in some edge cases).
  if state.win == nil and state.buf == nil then
    return
  end

  if state.focused then
    unfocus_preview()
  end

  -- Clean up parent buffer keymaps.  Validate that the parent buffer is still
  -- valid AND still has the same buffer number we expect (buffer numbers can be
  -- reused after :bwipeout).
  if state.parent_buf and vim.api.nvim_buf_is_valid(state.parent_buf) then
    for _, key in ipairs({ "<C-j>", "<C-k>", "<C-o>", "<C-i>", "<BS>", "<CR>" }) do
      pcall(vim.keymap.del, "n", key, { buffer = state.parent_buf })
    end
  end

  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end

  -- Reset state BEFORE clear_history to prevent re-entrant access
  state.win = nil
  state.buf = nil
  state.parent_buf = nil
  state.focused = false

  clear_history()
end
```

#### Before `replace_float_content` (lines 407-426):

```lua
local function replace_float_content(target)
  if not is_active() then return end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, target.lines)
  -- ...
```

#### After:

```lua
local function replace_float_content(target)
  if not is_active() then return end
  -- Double-check buf validity (is_active now checks both, but guard against
  -- races where buf is wiped between is_active() and vim.bo[] access).
  if not vim.api.nvim_buf_is_valid(state.buf) then
    close_preview()
    return
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, target.lines)
  -- ...
```

### Test Cases

1. Open a preview float (K on a wikilink).  Run `:only` from the parent
   window.  The preview should close and all state fields should be nil.
   Press K again — a new preview should open without errors.
2. Open a preview, then run `:lua vim.api.nvim_win_close(<win_id>, true)`
   with the float's window ID.  Verify no errors and `state.win == nil`.
3. Open a preview, navigate with C-o/C-i history.  Close the float externally.
   Re-open a preview — history should be fresh (no stale entries from
   previous session).
4. Open a preview.  Run `:bwipeout` on the parent buffer.  Verify the
   preview closes cleanly and no keymap errors appear in `:messages`.

---

## 3. Sidebar Non-Vault Buffer Skip (sidebar.lua)

### Current Behavior

The `BufEnter` autocmd in `sidebar.lua` `setup()` fires for all buffers:

```lua
vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = group,
    callback = on_buf_change,
  })
```

The `on_buf_change` handler does check for vault markdown files:

```lua
local function on_buf_change(ev)
  if not _state.visible then return end
  if not _state.win or not vim.api.nvim_win_is_valid(_state.win) then return end
  if ev.buf == _state.buf then return end

  local bufname = vim.api.nvim_buf_get_name(ev.buf)
  if not vim.endswith(bufname, ".md") then return end
  if not engine.is_vault_path(bufname) then return end

  _state.source_buf = ev.buf
  _state.source_win = vim.api.nvim_get_current_win()
  schedule_render()
end
```

**Problem:** While the function does early-exit correctly, the autocmd fires
for every `BufEnter` event in the entire editor — terminal buffers, help pages,
Telescope pickers, fzf-lua buffers, quickfix, etc.  Each invocation runs:
1. `_state.visible` check
2. `vim.api.nvim_win_is_valid()` check
3. Buffer number comparison
4. `vim.api.nvim_buf_get_name()` API call
5. String suffix check
6. `engine.is_vault_path()` call (string prefix comparison)

Although each check is cheap, the autocmd fires very frequently in normal
editing workflows.  Adding a `pattern = "*.md"` to the autocmd would avoid
steps 3-6 entirely for non-markdown buffers.

Additionally, when the sidebar is not visible, the early-exit on the first
line is fast, but the autocmd registration itself still consumes a slot in
Neovim's autocmd dispatch table for every `BufEnter` event.

### Fix

Add `pattern = "*.md"` to the `BufEnter` autocmd so Neovim's C-level pattern
matching filters out non-markdown buffers before the Lua callback is invoked.
This also documents the intent more clearly.

Also clean up the `update_timer` in `close_sidebar()` to avoid a dangling timer.

#### Before (BufEnter autocmd, lines 396-399):

```lua
vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = group,
    callback = on_buf_change,
  })
```

#### After:

```lua
vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = group,
    pattern = "*.md",
    callback = on_buf_change,
  })
```

#### Before `close_sidebar()` (lines 119-129):

```lua
local function close_sidebar()
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_close(_state.win, true)
  end
  if _state.buf and vim.api.nvim_buf_is_valid(_state.buf) then
    pcall(vim.api.nvim_buf_delete, _state.buf, { force = true })
  end
  _state.win = nil
  _state.buf = nil
  _state.visible = false
end
```

#### After:

```lua
local function close_sidebar()
  -- Stop any pending debounce timer
  if _state.update_timer then
    pcall(function()
      _state.update_timer:stop()
      _state.update_timer:close()
    end)
    _state.update_timer = nil
  end

  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_close(_state.win, true)
  end
  if _state.buf and vim.api.nvim_buf_is_valid(_state.buf) then
    pcall(vim.api.nvim_buf_delete, _state.buf, { force = true })
  end
  _state.win = nil
  _state.buf = nil
  _state.visible = false
  _state.source_win = nil
  _state.source_buf = nil
end
```

Additionally, add a guard in `schedule_render()` to avoid creating new timers
after the sidebar is closed:

#### Before `schedule_render()` (lines 213-221):

```lua
local function schedule_render()
  if _state.update_timer then
    _state.update_timer:stop()
  end
  _state.update_timer = vim.uv.new_timer()
  _state.update_timer:start(config.sidebar.update_debounce_ms, 0, vim.schedule_wrap(function()
    M.render()
  end))
end
```

#### After:

```lua
local function schedule_render()
  if not _state.visible then return end

  if _state.update_timer then
    _state.update_timer:stop()
    _state.update_timer:close()
  end
  _state.update_timer = vim.uv.new_timer()
  if not _state.update_timer then return end
  _state.update_timer:start(config.sidebar.update_debounce_ms, 0, vim.schedule_wrap(function()
    if _state.update_timer then
      _state.update_timer:stop()
      _state.update_timer:close()
      _state.update_timer = nil
    end
    M.render()
  end))
end
```

### Test Cases

1. Open the sidebar (`:VaultSidebar`).  Switch to a terminal buffer
   (`:terminal`).  Verify no sidebar render is triggered (add a temporary
   `vim.notify("sidebar render")` at the top of `M.render()` to confirm).
2. Open the sidebar.  Open a help page (`:help`).  Verify `on_buf_change`
   is never called (the `*.md` pattern filters it at the autocmd level).
3. Open the sidebar.  Open a non-vault markdown file (e.g., a README.md in
   another project).  Verify `on_buf_change` is called but early-exits at
   the `engine.is_vault_path()` check — no render is scheduled.
4. Open the sidebar, close it with `q`, then switch buffers rapidly.
   Verify no errors from the update timer (dangling timer cleaned up).
5. Open the sidebar.  Switch between 5 vault markdown files rapidly.
   Verify only one debounced render fires (not 5).

---

## Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/embed.lua` | Add `gc_stale_buffers()`, harden `clear_image_placements()`, call GC from BufEnter |
| `lua/andrew/vault/preview.lua` | Validate `state.buf` in `is_active()`, add re-entrancy guard in `close_preview()`, guard `replace_float_content()` |
| `lua/andrew/vault/sidebar.lua` | Add `pattern = "*.md"` to BufEnter autocmd, clean up timer in `close_sidebar()`, guard `schedule_render()` |

## Risk Assessment

All three changes are defensive hardening with no behavioral changes for normal
workflows.  The sidebar `pattern` filter is the most impactful change (reduces
autocmd invocations) but is semantically equivalent to the existing early-exit
logic.  The preview and embed changes only affect edge cases (external window
close, long sessions with many buffers).
