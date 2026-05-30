# 33 — Auto-Save on Focus Loss

## Problem

Obsidian auto-saves notes as the user navigates between files, switches to another application, or simply stops typing. Neovim's default behavior requires explicit `:w` to persist changes. This creates a friction mismatch for users who work across both editors on the same vault — edits made in Neovim are invisible to Obsidian (or external sync tools like Syncthing/git) until manually saved.

The current state:

| Component | What It Does | File |
|-----------|-------------|------|
| **frontmatter.lua** | Updates `modified` timestamp on `BufWritePre` for vault markdown files | `lua/andrew/vault/frontmatter.lua` |
| **ftplugin/markdown.lua** | Sets spell, conceallevel, folds, keybindings for markdown buffers | `ftplugin/markdown.lua` |
| **options.lua** | Global options: `undofile=true`, `swapfile=false`, `updatetime=250` | `lua/andrew/core/options.lua` |
| **init.lua (vault)** | Loads all vault modules, registers `BufWritePost` cache invalidation | `lua/andrew/vault/init.lua` |
| **config.lua** | Centralized vault configuration | `lua/andrew/vault/config.lua` |

### Why the Current Design Does Not Auto-Save

There is no mechanism — no autocmd, no timer, no plugin hook — that triggers a write when the user leaves a buffer, window, or Neovim's terminal focus. The `BufWritePre` frontmatter hook and the `BufWritePost` cache invalidation hook only fire when the user explicitly saves. The `FocusGained` handler in `init.lua` handles *incoming* external changes but not *outgoing* unsaved local changes.

**Consequences:**
1. **Data loss risk** — Neovim crash or terminal kill loses all unsaved edits (no swap file since `swapfile=false`).
2. **Sync lag** — vault sync tools (Obsidian Sync, git auto-commit, Syncthing) cannot see unsaved changes, leading to conflicts when editing the same note in both Obsidian and Neovim.
3. **Frontmatter staleness** — the `modified` timestamp only updates on explicit save, so a note edited 30 minutes ago but never saved still shows the old timestamp.

---

## Goal

Add auto-save for vault markdown files so that:

1. Modified markdown buffers in vault directories are saved automatically on `FocusLost`, `BufLeave`, and `WinLeave`.
2. Only buffers that are modified (`vim.bo.modified`) and have a file name (not scratch/unnamed buffers) are saved.
3. Only markdown files (`filetype == "markdown"`) within vault paths (`engine.is_vault_path()`) are targeted.
4. Save uses `vim.cmd("silent! update")` to avoid errors on read-only or special buffers.
5. Saves are debounced (1-second window) to prevent excessive disk writes during rapid buffer switches.
6. `:VaultAutoSave` command toggles the feature on/off with a notification.
7. `vim.bo.modifiable` and `vim.bo.readonly` flags are respected — skip save if either is false/true.
8. Works seamlessly with `frontmatter.lua`'s `BufWritePre` hook — auto-saves trigger timestamp updates.
9. Statusline indicator shows when auto-save is active (e.g., lualine component).
10. Implementation as a dedicated vault module (`lua/andrew/vault/autosave.lua`) with setup registered in `init.lua`.
11. Configurable via `config.lua` — enable/disable, debounce interval, events list.

---

## Approach

### Architecture

Create a new module `lua/andrew/vault/autosave.lua` that:

1. Registers autocmds for `FocusLost`, `BufLeave`, and `WinLeave` on vault markdown buffers.
2. Debounces save operations using a `vim.uv.new_timer()` to coalesce rapid events (e.g., `BufLeave` + `FocusLost` firing within milliseconds).
3. Guards against saving inappropriate buffers (unnamed, readonly, unmodifiable, non-vault, non-markdown).
4. Provides a toggle command and statusline query function.
5. Fires `silent! update` (not `write`) so Neovim only writes when the buffer is actually modified and has a file name.

### Event Flow

```
User leaves buffer/window/focus
  │
  ├─ BufLeave / WinLeave / FocusLost fires
  │
  ├─ Guard checks: is it a named, modified, modifiable, non-readonly,
  │  markdown, vault-path buffer?
  │
  ├─ Start/reset 1-second debounce timer
  │
  └─ Timer fires:
       ├─ Re-validate buffer (still valid, still modified, etc.)
       ├─ vim.cmd("silent! update")
       │    └─ BufWritePre fires → frontmatter.lua updates `modified` timestamp
       │    └─ BufWritePost fires → cache invalidation runs
       └─ Done
```

### Why Debounce?

Switching from buffer A to buffer B triggers `BufLeave` on A, then `WinLeave` on A's window if changing windows. Switching to another terminal triggers `FocusLost`. These can all fire within a few milliseconds. Without debouncing, the same buffer could be written 2-3 times in rapid succession. The debounce timer ensures at most one write per second per buffer.

### Why `silent! update` Instead of `write`?

- `update` is a no-op if the buffer is not modified (safe to call unconditionally after guard checks).
- `silent!` suppresses errors for edge cases: buffer was deleted between timer start and fire, file became read-only externally, etc.
- Unlike `write`, `update` does not create the file if it does not exist on disk (prevents creating phantom files from abandoned scratch buffers).

### Interaction with Existing Hooks

| Hook | Trigger | Effect |
|------|---------|--------|
| **BufWritePre** (frontmatter.lua) | Auto-save calls `update` → Neovim fires `BufWritePre` | `modified` timestamp updated automatically |
| **BufWritePost** (init.lua) | Auto-save completes → Neovim fires `BufWritePost` | Cache invalidation runs for the saved file |
| **Undo history** | `undofile=true` in options.lua | Undo history persisted on auto-save (no data loss for undo) |
| **FileChangedShellPost** (init.lua) | Not affected | Only fires on external changes, not our writes |

---

## Implementation

### File: `lua/andrew/vault/config.lua` — Add Config Section

Add after the existing `callout_folds` section:

```lua
-- ---------------------------------------------------------------------------
-- Auto-save on focus loss
-- ---------------------------------------------------------------------------
M.autosave = {
  enabled = true,
  debounce_ms = 1000,   -- debounce interval between save attempts
  events = { "FocusLost", "BufLeave", "WinLeave" },
}
```

### File: `lua/andrew/vault/autosave.lua` — New Module

```lua
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- Whether auto-save is currently active.
---@type boolean
local _enabled = false

--- Per-buffer debounce timers.
--- Keyed by buffer number to allow independent debounce per buffer.
---@type table<number, uv_timer_t>
local _timers = {}

--- Augroup ID (nil when not active).
---@type number|nil
local _augroup = nil

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------

--- Check whether a buffer should be auto-saved.
---@param bufnr number
---@return boolean
local function should_save(bufnr)
  -- Buffer must be valid and loaded
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if not vim.api.nvim_buf_is_loaded(bufnr) then return false end

  -- Must have unsaved changes
  if not vim.bo[bufnr].modified then return false end

  -- Must be modifiable and not readonly
  if not vim.bo[bufnr].modifiable then return false end
  if vim.bo[bufnr].readonly then return false end

  -- Must be a normal buffer (not terminal, prompt, nofile, etc.)
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" then return false end

  -- Must be a markdown file
  if vim.bo[bufnr].filetype ~= "markdown" then return false end

  -- Must have a file name (not a scratch buffer)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then return false end

  -- Must be inside a vault path
  if not engine.is_vault_path(bufname) then return false end

  return true
end

-- ---------------------------------------------------------------------------
-- Core save logic
-- ---------------------------------------------------------------------------

--- Save a single buffer if it passes all guards.
---@param bufnr number
local function save_buffer(bufnr)
  if not should_save(bufnr) then return end

  -- Use nvim_buf_call to ensure the update targets the correct buffer,
  -- even if the current buffer has changed since the timer fired.
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent! update")
  end)
end

--- Schedule a debounced save for the given buffer.
---@param bufnr number
local function schedule_save(bufnr)
  if not _enabled then return end
  if not should_save(bufnr) then return end

  local debounce_ms = config.autosave.debounce_ms

  -- Cancel any existing timer for this buffer
  if _timers[bufnr] then
    _timers[bufnr]:stop()
  else
    _timers[bufnr] = vim.uv.new_timer()
  end

  if not _timers[bufnr] then return end

  _timers[bufnr]:start(debounce_ms, 0, vim.schedule_wrap(function()
    -- Clean up the timer
    if _timers[bufnr] then
      _timers[bufnr]:stop()
      _timers[bufnr]:close()
      _timers[bufnr] = nil
    end

    save_buffer(bufnr)
  end))
end

-- ---------------------------------------------------------------------------
-- Autocmd management
-- ---------------------------------------------------------------------------

--- Create the autocmds that trigger auto-save.
local function create_autocmds()
  if _augroup then return end

  _augroup = vim.api.nvim_create_augroup("VaultAutoSave", { clear = true })

  local events = config.autosave.events

  -- Buffer-specific events (BufLeave, WinLeave): save the buffer being left
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = _augroup,
    pattern = "*.md",
    callback = function(ev)
      schedule_save(ev.buf)
    end,
  })

  -- FocusLost: save ALL modified vault markdown buffers (user left Neovim)
  if vim.tbl_contains(events, "FocusLost") then
    vim.api.nvim_create_autocmd("FocusLost", {
      group = _augroup,
      callback = function()
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if should_save(bufnr) then
            -- On FocusLost, save immediately (no debounce) since the user
            -- has left the editor entirely
            save_buffer(bufnr)
          end
        end
      end,
    })
  end
end

--- Remove autocmds and clean up timers.
local function remove_autocmds()
  if _augroup then
    vim.api.nvim_del_augroup_by_id(_augroup)
    _augroup = nil
  end

  -- Stop and close all pending timers
  for bufnr, timer in pairs(_timers) do
    timer:stop()
    timer:close()
    _timers[bufnr] = nil
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Enable auto-save.
function M.enable()
  _enabled = true
  create_autocmds()
end

--- Disable auto-save.
function M.disable()
  _enabled = false
  remove_autocmds()
end

--- Toggle auto-save on/off.
---@return boolean new_state
function M.toggle()
  if _enabled then
    M.disable()
  else
    M.enable()
  end
  vim.notify(
    "Vault auto-save: " .. (_enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
  return _enabled
end

--- Query whether auto-save is currently active.
--- Used by statusline components.
---@return boolean
function M.is_enabled()
  return _enabled
end

--- Statusline string for lualine or similar.
--- Returns a short indicator when active, empty string when not.
---@return string
function M.statusline()
  if not _enabled then return "" end
  -- Only show in vault markdown buffers
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "markdown" then return "" end
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(bufname) then return "" end
  return "auto-save"
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  -- Register the toggle command
  vim.api.nvim_create_user_command("VaultAutoSave", function()
    M.toggle()
  end, { desc = "Toggle vault auto-save on focus loss" })

  -- Keymap: <leader>vA to toggle
  vim.keymap.set("n", "<leader>vA", function()
    M.toggle()
  end, { desc = "Vault: toggle auto-save", silent = true })

  -- Enable by default if config says so
  if config.autosave.enabled then
    M.enable()
  end

  -- Clean up timers for deleted buffers to prevent leaks
  vim.api.nvim_create_autocmd("BufDelete", {
    callback = function(ev)
      if _timers[ev.buf] then
        _timers[ev.buf]:stop()
        _timers[ev.buf]:close()
        _timers[ev.buf] = nil
      end
    end,
  })
end

return M
```

---

## Integration

### 1. Add config section to `config.lua`

**File:** `lua/andrew/vault/config.lua`

Insert after the `callout_folds` block (around line 144):

```lua
-- ---------------------------------------------------------------------------
-- Auto-save on focus loss
-- ---------------------------------------------------------------------------
M.autosave = {
  enabled = true,
  debounce_ms = 1000,   -- debounce interval between save attempts
  events = { "FocusLost", "BufLeave", "WinLeave" },
}
```

### 2. Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add after the existing module setup chain (after the `highlights` module, before the vault switcher command):

```lua
-- Load auto-save on focus loss
require("andrew.vault.autosave").setup()
```

### 3. Optional: Lualine statusline component

**File:** `lua/andrew/plugins/lualine.lua` (or wherever lualine is configured)

Add a section component that shows the auto-save indicator:

```lua
{
  function()
    local ok, autosave = pcall(require, "andrew.vault.autosave")
    if ok then return autosave.statusline() end
    return ""
  end,
  cond = function()
    local ok, autosave = pcall(require, "andrew.vault.autosave")
    return ok and autosave.is_enabled()
  end,
  color = { fg = "#a6e3a1" },  -- green when active
}
```

This can be placed in `lualine_x` or `lualine_y` alongside other indicators.

---

## Implementation Steps

1. **Add config section** to `lua/andrew/vault/config.lua` — the `M.autosave` table with `enabled`, `debounce_ms`, and `events`.

2. **Create `lua/andrew/vault/autosave.lua`** — the full module as specified above.

3. **Register in `lua/andrew/vault/init.lua`** — add `require("andrew.vault.autosave").setup()` in the module setup chain.

4. **Add lualine component** (optional) — add the statusline section to the lualine config.

5. **Test** — verify the full event flow as described in the Testing section below.

---

## Testing

### Manual Verification

1. **Basic auto-save on BufLeave:**

   - Open a vault markdown file. Make an edit (add a word).
   - Switch to another buffer (`:bnext` or open a different file).
   - Wait 1 second (debounce). Switch back.
   - Verify: the file is saved (`:echo &modified` returns `0`), and the `modified` frontmatter timestamp has been updated.

2. **Auto-save on FocusLost:**

   - Open a vault markdown file. Make an edit.
   - Switch to another terminal window or application.
   - Switch back. Verify: the file is saved immediately (no debounce on FocusLost).

3. **Guard: non-vault files excluded:**

   - Open a markdown file outside the vault (e.g., a README in a git repo).
   - Make an edit. Switch buffers. Wait.
   - Verify: the file is NOT auto-saved (`:echo &modified` returns `1`).

4. **Guard: non-markdown files excluded:**

   - Open a `.lua` file inside the vault directory.
   - Make an edit. Switch buffers.
   - Verify: the file is NOT auto-saved.

5. **Guard: readonly/unmodifiable buffers:**

   - Open a vault markdown file. Run `:set readonly`. Make an edit attempt.
   - Switch buffers. Verify: no auto-save attempt occurs.

6. **Guard: unnamed buffers:**

   - Run `:new` to create an unnamed buffer. Set filetype to markdown (`:set ft=markdown`).
   - Type some text. Switch buffers.
   - Verify: no auto-save attempt, no errors.

7. **Debounce verification:**

   - Open a vault markdown file. Make an edit.
   - Rapidly switch between two vault buffers 5 times within 1 second.
   - Verify: the file is written only once (check with `:messages` or watch `BufWritePost` notifications).

8. **Toggle command:**

   ```vim
   :VaultAutoSave     " → notification: "Vault auto-save: OFF"
   :VaultAutoSave     " → notification: "Vault auto-save: ON"
   ```

   - When OFF: edits are not auto-saved on buffer leave.
   - When ON: edits are auto-saved again.

9. **Frontmatter interaction:**

   - Open a vault markdown file with frontmatter. Note the current `modified` timestamp.
   - Make an edit. Switch buffers. Wait for auto-save.
   - Check the `modified` timestamp — it should be updated to the current time.

10. **Statusline indicator:**

    - With auto-save ON, open a vault markdown file. Verify "auto-save" appears in the statusline.
    - Toggle OFF. Verify the indicator disappears.
    - Open a non-vault file. Verify the indicator does not appear even when auto-save is ON.

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: autosave module structure
do
  local source = io.open("lua/andrew/vault/autosave.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- Core API present
    assert_true(content:find("function M.setup") ~= nil, "has setup function")
    assert_true(content:find("function M.enable") ~= nil, "has enable function")
    assert_true(content:find("function M.disable") ~= nil, "has disable function")
    assert_true(content:find("function M.toggle") ~= nil, "has toggle function")
    assert_true(content:find("function M.is_enabled") ~= nil, "has is_enabled query")
    assert_true(content:find("function M.statusline") ~= nil, "has statusline function")

    -- Guard checks present
    assert_true(content:find("vim.bo%[bufnr%].modified") ~= nil, "checks modified flag")
    assert_true(content:find("vim.bo%[bufnr%].modifiable") ~= nil, "checks modifiable flag")
    assert_true(content:find("vim.bo%[bufnr%].readonly") ~= nil, "checks readonly flag")
    assert_true(content:find("is_vault_path") ~= nil, "checks vault path")
    assert_true(content:find('filetype.-"markdown"') ~= nil, "checks markdown filetype")
    assert_true(content:find("buftype") ~= nil, "checks buftype")

    -- Core mechanism
    assert_true(content:find("silent! update") ~= nil, "uses silent! update for safe saving")
    assert_true(content:find("vim.uv.new_timer") ~= nil, "uses uv timer for debounce")
    assert_true(content:find("VaultAutoSave") ~= nil, "defines VaultAutoSave command")
    assert_true(content:find("FocusLost") ~= nil, "handles FocusLost event")
    assert_true(content:find("BufLeave") ~= nil, "handles BufLeave event")
    assert_true(content:find("nvim_buf_call") ~= nil, "uses nvim_buf_call for correct buffer targeting")
  end
end
```

### Performance Verification

The module should add zero measurable overhead to normal editing:

- **Guard checks:** 6 field lookups per event — nanoseconds.
- **Timer management:** one `uv_timer_t` per modified buffer at most.
- **Save operation:** `update` is a Neovim built-in with optimized I/O.

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.autosave"); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

Target: < 1ms for module load. Timer overhead is managed by libuv, not Lua.

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Buffer deleted between timer start and fire | `nvim_buf_is_valid()` check in `should_save()` returns false; no-op |
| File becomes read-only externally during debounce | `silent! update` suppresses the error; no crash |
| Rapid buffer switching (A→B→A→B) | Each buffer gets its own timer; at most one save per buffer per debounce window |
| FocusLost during insert mode | `update` writes the current buffer state; user continues editing on FocusGained |
| Vault switch while timer pending | Timer fires, `is_vault_path()` check uses the new vault path; buffer may no longer match → no-op |
| New unnamed buffer (`:new`) with `ft=markdown` | `bufname == ""` guard prevents save attempt |
| Terminal buffer or quickfix | `buftype ~= ""` guard prevents save attempt |
| File with no frontmatter | Auto-save triggers `BufWritePre` → `frontmatter.lua` creates frontmatter block (this is existing behavior for any save) |
| Neovim quitting (`:qa`) | `FocusLost` does not fire on quit; but Neovim's own write-on-quit prompts handle this. Alternatively, adding `VimLeavePre` could ensure a final save |
| `vim.cmd("silent! update")` in a float/popup | Pattern `*.md` on `BufLeave`/`WinLeave` prevents firing for non-file buffers; `buftype` guard catches the rest |
| Multiple vaults with different configs | Config is global (`config.autosave`); toggle state is also global. This is sufficient — both vaults benefit equally |
| Undo history after auto-save | `undofile=true` means undo history is persisted to disk on save; user can still undo after auto-save |

---

## Risks & Mitigations

**Risk: Low**

- **No data loss risk** — `update` is strictly safer than the current state (no auto-save at all). It only writes when the buffer is modified and named.
- **No interference with explicit saves** — if the user types `:w` during the debounce window, the timer's subsequent `update` is a no-op (buffer is no longer modified).
- **Frontmatter churn** — auto-saves update the `modified` timestamp. This means the timestamp changes every time the user leaves a buffer after editing, even for trivial edits. This is consistent with Obsidian's behavior (which updates timestamps on every save). If this becomes noisy in git diffs, the user can disable auto-save with `:VaultAutoSave` or set `config.autosave.enabled = false`.
- **Performance** — debouncing prevents write amplification. One write per buffer per second is well within acceptable I/O for SSDs. The `uv_timer_t` objects are cleaned up on `BufDelete` to prevent memory leaks.
- **Backward compatibility** — the feature is entirely additive. Setting `config.autosave.enabled = false` completely disables it. The toggle command provides runtime control.

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `is_vault_path()` for vault path checking | Yes |
| `config.lua` | `config.autosave` for settings | Yes |
| `frontmatter.lua` | Existing `BufWritePre` hook fires automatically on `update` | No (works independently) |
| `init.lua` | `BufWritePost` cache invalidation fires automatically on `update` | No (works independently) |
| `lualine` | Optional statusline component | No |

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/autosave.lua` | **New file** — complete auto-save module |
| `lua/andrew/vault/config.lua` | Add `M.autosave` config section |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.autosave").setup()` |
| Lualine config (optional) | Add statusline component for auto-save indicator |

---

## Future Enhancements

1. **Idle timer auto-save** — save after N seconds of no keystrokes (`CursorHold` event), in addition to focus/buffer leave events.
2. **Per-buffer opt-out** — buffer-local variable (`vim.b.vault_autosave_disable = true`) to exclude specific files from auto-save.
3. **Save notification** — brief non-intrusive indicator (e.g., a brief icon flash in the statusline) when an auto-save occurs, so the user has feedback without being interrupted.
4. **Write count tracking** — `:VaultAutoSaveStats` showing how many auto-saves have occurred this session, per file.
5. **Conflict detection** — before auto-saving, check if the file on disk has been modified externally since the buffer was loaded (mtime comparison), to avoid overwriting Obsidian edits.
