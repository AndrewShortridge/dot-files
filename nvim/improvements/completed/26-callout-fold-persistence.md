# 26 — Callout Fold State Persistence

## Problem

The vault uses Obsidian-style collapsible callouts (`> [!TYPE]-` collapsed, `> [!TYPE]+` expanded) with fold states managed by `render-markdown.lua`. When a user manually toggles a callout fold via `<leader>mz`, the fold state is lost on buffer reload (`BufRead`), window change, or Neovim restart. The `apply_callout_folds()` function always resets folds to match the suffix in the source text (`-` = closed, `+` = open), discarding the user's runtime toggle.

This means:
1. **No session memory** — manually opened collapsed callouts snap back shut on `:e` or next session.
2. **No cross-session continuity** — a researcher reviewing a long note must re-expand the same callouts every time.
3. **Editing the source** is the only workaround — changing `[!NOTE]-` to `[!NOTE]+` in the file just to keep it open, which pollutes the document with transient UI preferences.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **render-markdown.lua** | Defines callout rendering (collapsed/expanded variants), `apply_callout_folds()`, `toggle_callout_fold()`, `VaultCalloutFoldtext()` | `lua/andrew/plugins/render-markdown.lua` |
| **ftplugin/markdown.lua** | Sets `foldmethod=expr` (treesitter), `foldlevel=99`, `foldtext` | `ftplugin/markdown.lua` |
| **render-markdown config()** | Overrides `foldmethod` to `manual` on FileType for callout support | `lua/andrew/plugins/render-markdown.lua:148-149` |
| **frecency.lua** | Example of `engine.json_store()` file-based caching pattern | `lua/andrew/vault/frecency.lua` |

### Why the Current Design Cannot Persist State

The `apply_callout_folds()` function in `render-markdown.lua` runs on `BufWinEnter`/`BufRead` and reads the raw callout suffix (`-` or `+`) to determine fold state. It has no memory of previous toggle actions. The `toggle_callout_fold()` function modifies Neovim's fold state in-place but does not record the toggle anywhere persistent.

**Conclusion**: A separate caching module is required to save and restore user fold overrides.

---

## Goal

Add callout fold state persistence so that:

1. Manually toggled callout fold states survive buffer reloads and Neovim restarts.
2. Fold state is stored in a JSON cache file keyed by file path and callout identity.
3. States are restored on `BufReadPost` / `BufWinEnter` after `apply_callout_folds()` runs.
4. Cache updates on `<leader>mz` toggle.
5. File modifications (line insertions, deletions, edits) do not corrupt saved fold states — content-based matching is used instead of raw line numbers.
6. Only non-default overrides are stored (a `[!NOTE]-` that the user opened is stored; a `[!NOTE]-` that remains collapsed is not).
7. `:VaultFoldClear` resets all cached fold states for the current file.
8. Stale entries (deleted files) are auto-pruned on cache load.
9. The cache file remains small and human-readable.

---

## Approach

### Architecture

Create a new module `lua/andrew/vault/callout_folds.lua` that:

1. Maintains a JSON cache file (`.vault-callout-folds.json`) in the vault root via `engine.json_store()`.
2. Identifies callouts by a content fingerprint (callout type + title text + surrounding context hash) rather than line number alone.
3. Records fold overrides: only stores entries where the user's toggle differs from the source suffix default.
4. Integrates with the existing `apply_callout_folds()` and `toggle_callout_fold()` in `render-markdown.lua` via hooks.
5. Auto-prunes entries for files that no longer exist on cache load.
6. Provides `:VaultFoldClear` command and `<leader>mZ` keymap.

### Callout Identity (Content Fingerprint)

Pure line numbers break when lines are inserted or deleted above a callout. Instead, each callout is identified by a fingerprint composed of:

```
fingerprint = callout_type .. "|" .. title_text .. "|" .. content_hash
```

Where:
- `callout_type` — the `[!TYPE]` string (e.g., `NOTE`, `TIP`, `WARNING`), case-normalized to uppercase.
- `title_text` — any text after the `[!TYPE]+/-` on the header line (e.g., `> [!NOTE]- My Title` yields `My Title`), trimmed and lowercased.
- `content_hash` — a short hash (first 8 hex chars of `vim.fn.sha256()`) of the first 3 content lines of the callout body (the lines after the header, stripped of `> ` prefix). This disambiguates multiple callouts of the same type/title in one file.

This strategy handles:

| Scenario | Behavior |
|----------|----------|
| Lines inserted above callout | Fingerprint unchanged (no line number dependency) |
| Callout title edited | Fingerprint changes, old override is orphaned (no harm, pruned later) |
| Callout body edited significantly | Content hash changes, override orphaned (conservative — reset to default) |
| Minor body edits (typo fix in line 4+) | Content hash unchanged (only first 3 lines hashed) |
| Multiple same-type callouts | Content hash disambiguates them |
| Callout type changed | Different fingerprint, old override orphaned |

### Cache Format

```json
{
  "Projects/simulation-setup.md": {
    "NOTE|setup instructions|a1b2c3d4": "open",
    "WARNING|known issues|e5f6g7h8": "closed"
  },
  "Log/2026-02-25.md": {
    "TODO|morning tasks|1a2b3c4d": "open"
  }
}
```

- **Outer key**: vault-relative file path (from `engine.vault_relative()`).
- **Inner key**: callout fingerprint string.
- **Value**: `"open"` or `"closed"` — the user's override. Only stored when it differs from the source suffix default (`-` defaults to closed, `+` defaults to open).
- Files with no overrides are omitted entirely (keeps the cache minimal).

### Integration with render-markdown.lua

The existing `apply_callout_folds()` and `toggle_callout_fold()` functions in `render-markdown.lua` are modified to call into `callout_folds.lua`:

1. **After `apply_callout_folds(bufnr)`** — call `callout_folds.restore(bufnr)` to apply any saved overrides on top of the suffix-based defaults.
2. **Inside `toggle_callout_fold(bufnr)`** — after toggling, call `callout_folds.record_toggle(bufnr, header_lnum)` to save the new state.

This keeps the core fold logic in `render-markdown.lua` and adds persistence as a layer on top.

---

## Implementation

### File: `lua/andrew/vault/callout_folds.lua`

```lua
local engine = require("andrew.vault.engine")

local M = {}

-- ---------------------------------------------------------------------------
-- Cache store
-- ---------------------------------------------------------------------------

local store = engine.json_store(".vault-callout-folds.json")

--- In-memory cache (invalidated on vault switch).
---@type table<string, table<string, string>>|nil
local _db = nil
local _db_vault = nil

---@return table<string, table<string, string>>
local function load_db()
  if _db and _db_vault == engine.vault_path then
    return _db
  end
  _db_vault = engine.vault_path
  _db = store.load()

  -- Auto-prune: remove entries for files that no longer exist
  local pruned = false
  local vault = engine.vault_path
  for rel, _ in pairs(_db) do
    local abs = vault .. "/" .. rel
    if vim.fn.filereadable(abs) ~= 1 then
      _db[rel] = nil
      pruned = true
    end
  end
  if pruned then
    store.save(_db)
  end

  return _db
end

---@param db table
local function save_db(db)
  _db = db
  _db_vault = engine.vault_path
  store.save(db)
end

-- ---------------------------------------------------------------------------
-- Callout fingerprinting
-- ---------------------------------------------------------------------------

--- Extract callout type, suffix, and title from a callout header line.
---@param line string
---@return string|nil type   e.g. "NOTE"
---@return string|nil suffix e.g. "-" or "+"
---@return string title      text after the suffix (may be empty)
local function parse_callout_header(line)
  -- Match: > [!TYPE]+/- Optional Title
  local ctype, suffix, title = line:match("^>%s*%[!([%w_]+)%]([%-+])%s*(.*)")
  if not ctype then
    -- Also match callouts without +/- suffix (plain callouts, no persistence needed
    -- but we still need to parse them for context)
    ctype = line:match("^>%s*%[!([%w_]+)%]")
    if ctype then
      return ctype:upper(), nil, ""
    end
    return nil, nil, ""
  end
  return ctype:upper(), suffix, vim.trim(title or "")
end

--- Collect the first N content lines of a callout block (after the header).
--- Lines are stripped of the `> ` prefix and joined.
---@param bufnr number
---@param header_lnum number 1-indexed
---@param max_lines? number default 3
---@return string
local function callout_content_preview(bufnr, header_lnum, max_lines)
  max_lines = max_lines or 3
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local parts = {}
  local collected = 0

  for lnum = header_lnum + 1, line_count do
    if collected >= max_lines then break end
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if not line or not line:match("^>") then break end
    -- Strip `> ` prefix
    local content = line:gsub("^>%s?", "")
    -- Skip empty content lines for hashing purposes
    if vim.trim(content) ~= "" then
      parts[#parts + 1] = vim.trim(content)
      collected = collected + 1
    end
  end

  return table.concat(parts, "\n")
end

--- Compute the fingerprint for a callout at the given header line.
---@param bufnr number
---@param header_lnum number 1-indexed
---@return string|nil fingerprint
---@return string|nil suffix  the source suffix ("-" or "+")
local function fingerprint(bufnr, header_lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, header_lnum - 1, header_lnum, false)[1]
  if not line then return nil, nil end

  local ctype, suffix, title = parse_callout_header(line)
  if not ctype or not suffix then return nil, nil end

  local preview = callout_content_preview(bufnr, header_lnum)
  local content_hash = vim.fn.sha256(preview):sub(1, 8)

  local fp = ctype .. "|" .. title:lower() .. "|" .. content_hash
  return fp, suffix
end

--- Determine the default fold state from the source suffix.
---@param suffix string "-" or "+"
---@return string "open" or "closed"
local function default_state(suffix)
  if suffix == "-" then
    return "closed"
  else
    return "open"
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Record a fold toggle for the callout at the given header line.
--- Only stores the override if it differs from the source suffix default.
---@param bufnr number
---@param header_lnum number 1-indexed line of the callout header
---@param is_now_open boolean whether the callout is now open after the toggle
function M.record_toggle(bufnr, header_lnum, is_now_open)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then return end

  local fp, suffix = fingerprint(bufnr, header_lnum)
  if not fp or not suffix then return end

  local rel = engine.vault_relative(fname)
  local db = load_db()

  local user_state = is_now_open and "open" or "closed"
  local def = default_state(suffix)

  if user_state == def then
    -- User toggled back to the default — remove the override
    if db[rel] then
      db[rel][fp] = nil
      -- Remove file entry if no overrides remain
      if next(db[rel]) == nil then
        db[rel] = nil
      end
    end
  else
    -- User overrode the default — store it
    if not db[rel] then
      db[rel] = {}
    end
    db[rel][fp] = user_state
  end

  save_db(db)
end

--- Restore saved fold overrides for all callouts in the buffer.
--- Call this AFTER apply_callout_folds() has set up the default folds.
---@param bufnr number
function M.restore(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then return end

  local rel = engine.vault_relative(fname)
  local db = load_db()
  local file_overrides = db[rel]
  if not file_overrides or next(file_overrides) == nil then return end

  -- Scan the buffer for all collapsible callouts and check for overrides
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local lnum = 1

  while lnum <= line_count do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if line and line:match("^>%s*%[![%w_]+%][%-+]") then
      local fp, suffix = fingerprint(bufnr, lnum)
      if fp and suffix then
        local override = file_overrides[fp]
        if override then
          -- Find the block end to know the fold range
          local block_end = lnum
          for l = lnum + 1, line_count do
            local bl = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
            if not bl or not bl:match("^>") then break end
            block_end = l
          end

          if block_end > lnum then
            local content_start = lnum + 1
            vim.api.nvim_buf_call(bufnr, function()
              if override == "open" then
                -- Source says closed, user wants open
                pcall(vim.cmd, content_start .. "foldopen")
              elseif override == "closed" then
                -- Source says open, user wants closed
                local fold_level = vim.fn.foldlevel(content_start)
                if fold_level > 0 then
                  pcall(vim.cmd, content_start .. "foldclose")
                else
                  -- No fold exists (+ callouts don't get a closed fold by default)
                  pcall(vim.cmd, content_start .. "," .. block_end .. "fold")
                  pcall(vim.cmd, content_start .. "foldclose")
                end
              end
            end)
          end
          lnum = block_end + 1
        else
          -- No override for this callout — skip past it
          local block_end = lnum
          for l = lnum + 1, line_count do
            local bl = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
            if not bl or not bl:match("^>") then break end
            block_end = l
          end
          lnum = block_end + 1
        end
      else
        lnum = lnum + 1
      end
    else
      lnum = lnum + 1
    end
  end
end

--- Clear all cached fold states for the current file (or all files).
---@param all? boolean if true, clear the entire cache
function M.clear(all)
  local db = load_db()

  if all then
    db = {}
    save_db(db)
    vim.notify("Vault: cleared all callout fold states", vim.log.levels.INFO)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then
    vim.notify("Vault: not a vault file", vim.log.levels.WARN)
    return
  end

  local rel = engine.vault_relative(fname)
  if db[rel] then
    db[rel] = nil
    save_db(db)
    vim.notify("Vault: cleared callout fold states for " .. rel, vim.log.levels.INFO)
  else
    vim.notify("Vault: no saved fold states for " .. rel, vim.log.levels.INFO)
  end
end

--- Invalidate the in-memory cache (called on vault switch / FocusGained).
function M.invalidate()
  _db = nil
  _db_vault = nil
end

--- Debug: show cached fold states for the current file.
function M.debug()
  local bufnr = vim.api.nvim_get_current_buf()
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then
    vim.notify("Vault: not a vault file", vim.log.levels.WARN)
    return
  end

  local rel = engine.vault_relative(fname)
  local db = load_db()
  local file_overrides = db[rel]

  if not file_overrides or next(file_overrides) == nil then
    vim.notify("Vault: no fold overrides for " .. rel, vim.log.levels.INFO)
    return
  end

  local lines = { "Callout fold overrides for " .. rel .. ":" }
  for fp_key, state in pairs(file_overrides) do
    local parts = vim.split(fp_key, "|")
    local ctype = parts[1] or "?"
    local title = parts[2] or ""
    local hash = parts[3] or "?"
    local display_title = title ~= "" and (' "' .. title .. '"') or ""
    lines[#lines + 1] = ("  [!%s]%s [%s] -> %s"):format(ctype, display_title, hash, state)
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  vim.api.nvim_create_user_command("VaultFoldClear", function(cmd_opts)
    M.clear(cmd_opts.bang)
  end, {
    desc = "Clear cached callout fold states (! for all files)",
    bang = true,
  })

  vim.api.nvim_create_user_command("VaultFoldDebug", function()
    M.debug()
  end, { desc = "Show cached callout fold states for current file" })

  -- Buffer-local keymap for clearing fold cache
  local group = vim.api.nvim_create_augroup("VaultCalloutFoldPersist", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>mZ", function()
        M.clear()
      end, {
        buffer = ev.buf,
        desc = "Clear callout fold cache (this file)",
        silent = true,
      })
    end,
  })
end

return M
```

---

## Integration

### 1. Modify `toggle_callout_fold()` in render-markdown.lua

**File:** `lua/andrew/plugins/render-markdown.lua`

Inside the `toggle_callout_fold()` function, after the fold is toggled, record the new state:

```lua
local function toggle_callout_fold(bufnr)
  -- ... existing code to find header_lnum and determine fold state ...

  local content_start = header_lnum + 1
  local fold_closed = vim.fn.foldclosed(content_start)
  local is_now_open

  if fold_closed ~= -1 then
    -- Content is folded — open it
    pcall(vim.cmd, content_start .. "foldopen")
    is_now_open = true
  else
    -- Content is visible — close it
    local fold_level = vim.fn.foldlevel(content_start)
    if fold_level > 0 then
      pcall(vim.cmd, content_start .. "foldclose")
    else
      pcall(vim.cmd, content_start .. "," .. block_end .. "fold")
      pcall(vim.cmd, content_start .. "foldclose")
    end
    is_now_open = false
  end

  -- Persist the toggle
  local ok, callout_folds = pcall(require, "andrew.vault.callout_folds")
  if ok then
    callout_folds.record_toggle(bufnr, header_lnum, is_now_open)
  end
end
```

### 2. Modify `apply_callout_folds()` autocmd in render-markdown.lua

**File:** `lua/andrew/plugins/render-markdown.lua`

In the `BufWinEnter` / `BufRead` autocmd callback, after `apply_callout_folds(bufnr)`, call `restore()`:

```lua
vim.api.nvim_create_autocmd({ "BufWinEnter", "BufRead" }, {
  group = callout_group,
  buffer = bufnr,
  callback = function()
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        apply_callout_folds(bufnr)
        -- Restore user overrides from cache
        local ok, callout_folds = pcall(require, "andrew.vault.callout_folds")
        if ok then
          callout_folds.restore(bufnr)
        end
      end
    end, 50)
  end,
})
```

### 3. Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add after the existing module setup chain:

```lua
-- Load callout fold persistence
require("andrew.vault.callout_folds").setup()
```

### 4. Add config section (optional)

**File:** `lua/andrew/vault/config.lua`

```lua
-- ---------------------------------------------------------------------------
-- Callout fold persistence
-- ---------------------------------------------------------------------------
M.callout_folds = {
  enabled = true,
  content_hash_lines = 3,  -- number of content lines used for fingerprint hash
}
```

---

## Fold System Interaction

### The foldmethod Override Chain

Understanding the fold lifecycle is critical for correct integration:

1. **`ftplugin/markdown.lua`** sets `foldmethod=expr` with treesitter `foldexpr`.
2. **`render-markdown.lua` FileType autocmd** overrides to `foldmethod=manual` so callout folds can be created programmatically.
3. **`apply_callout_folds()`** runs on `BufWinEnter`/`BufRead` (50ms defer), creating manual folds based on source suffixes.
4. **`callout_folds.restore()`** runs immediately after step 3, applying user overrides on top.

The `foldmethod=manual` override in step 2 is essential. With `foldmethod=expr`, programmatic folds from `:fold` commands would be immediately recalculated and lost. The override happens on `FileType`, which fires before `BufWinEnter`, so the order is correct.

### Fold State vs. Source Suffix

| Source Suffix | Default State | User Override | Cache Entry |
|--------------|---------------|---------------|-------------|
| `[!NOTE]-` | closed | (none) | not stored |
| `[!NOTE]-` | closed | opened by user | `"open"` |
| `[!NOTE]+` | open | (none) | not stored |
| `[!NOTE]+` | open | closed by user | `"closed"` |
| `[!NOTE]-` | closed | opened, then closed again | removed from cache |

### Timing Considerations

The 50ms defer in `apply_callout_folds()` exists so render-markdown.nvim has time to process the buffer. The `restore()` call happens inside the same deferred callback, immediately after `apply_callout_folds()`, so there is no additional timing concern. The fold operations in `restore()` are synchronous (wrapped in `nvim_buf_call`).

---

## Testing

### Manual Verification

1. **Basic persistence test:**

   ```markdown
   > [!NOTE]- Collapsed by default
   > This content should be hidden.
   > More content here.

   > [!TIP]+ Expanded by default
   > This content should be visible.
   > More content here.
   ```

   - Open the file. Verify `[!NOTE]-` is collapsed, `[!TIP]+` is expanded.
   - Press `<leader>mz` on the NOTE callout to expand it.
   - Run `:e` to reload. Verify the NOTE callout is still expanded (override persisted).
   - Quit and reopen Neovim. Verify the NOTE callout is still expanded.
   - Press `<leader>mz` on the NOTE callout to collapse it (back to default).
   - Run `:e`. Verify it stays collapsed (override removed from cache, default takes over).

2. **Multiple same-type callouts:**

   ```markdown
   > [!WARNING]- First warning
   > Content of first warning.

   > [!WARNING]- Second warning
   > Different content here.
   ```

   - Expand only the second warning.
   - Reload. Verify first stays collapsed, second stays expanded.

3. **Content edit resilience:**

   - Expand a collapsed callout. Save and reload (verify persisted).
   - Add 10 new lines above the callout. Save and reload. Verify the override still applies (fingerprint is content-based, not line-number-based).
   - Edit the callout title. Save and reload. Verify the override is lost (fingerprint changed, reverts to source default).

4. **Cache inspection:**

   ```vim
   :VaultFoldDebug
   ```

   Should show something like:
   ```
   Callout fold overrides for Projects/my-note.md:
     [!NOTE] "collapsed by default" [a1b2c3d4] -> open
   ```

5. **Cache clearing:**

   ```vim
   :VaultFoldClear       " clear current file
   :VaultFoldClear!      " clear all files
   ```

6. **Edge case — file deleted:**

   - Create overrides for a file. Delete the file. Open any other vault file.
   - Run `:VaultFoldDebug` — the deleted file's entries should be gone (auto-pruned on load).

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: callout_folds module structure
do
  local source = io.open("lua/andrew/vault/callout_folds.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- Core functionality present
    assert_true(content:find("fingerprint") ~= nil, "has fingerprint function")
    assert_true(content:find("record_toggle") ~= nil, "has record_toggle function")
    assert_true(content:find("restore") ~= nil, "has restore function")
    assert_true(content:find("clear") ~= nil, "has clear function")
    assert_true(content:find("json_store") ~= nil, "uses json_store for persistence")
    assert_true(content:find("vault%-callout%-folds") ~= nil, "uses correct cache filename")
    assert_true(content:find("sha256") ~= nil, "uses sha256 for content hashing")
    assert_true(content:find("VaultFoldClear") ~= nil, "defines VaultFoldClear command")
    assert_true(content:find("auto%-prune") ~= nil or content:find("prune") ~= nil, "has auto-prune logic")
    assert_true(content:find("default_state") ~= nil, "has default_state function")
  end
end
```

### Performance Verification

The module should add negligible overhead. The main costs are:

1. **`fingerprint()`** — one `sha256()` call per callout (microseconds).
2. **`restore()`** — one buffer scan (same as `apply_callout_folds()`), plus table lookups.
3. **`record_toggle()`** — one fingerprint computation + one JSON write.

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.callout_folds").restore(0); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

Target: < 5ms for a buffer with 20 callouts. The JSON file is typically < 5KB.

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Callout with no content (header only) | No fold created, no override stored |
| Callout with only empty `> ` lines | Content hash is hash of empty string; fingerprint still works |
| Same type + same title + same content | Identical fingerprint; overrides apply to "first match" (rare in practice) |
| Non-vault markdown file | Skipped — `is_vault_path()` check in all public functions |
| Callout without `+`/`-` suffix (plain `[!NOTE]`) | No suffix detected, `fingerprint()` returns nil, not tracked |
| Vault switch | In-memory cache invalidated on next `load_db()` call |
| Corrupt cache file | `json_store.load()` returns `{}` (graceful fallback) |
| Very large cache (hundreds of files) | Auto-prune removes deleted files; only non-default overrides stored |
| Buffer not yet loaded (BufReadPost race) | `restore()` deferred 50ms (same as `apply_callout_folds`) |
| Nested blockquotes (`>> nested`) | Inner `>>` lines still match `^>`, so they are included in the block range correctly |
| Callout type with underscores (`[!MY_TYPE]-`) | Matched by `[%w_]+` pattern in header parsing |
| Title with special characters | Title is used as-is in fingerprint (lowercased); no escaping needed since it is a JSON value key |
| `<leader>mZ` on non-vault file | Warning notification: "not a vault file" |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `json_store()`, `is_vault_path()`, `vault_relative()`, `vault_path` | Yes |
| `render-markdown.lua` | Calls `record_toggle()` from `toggle_callout_fold()`, calls `restore()` from fold autocmd | Yes (integration point) |
| `config.lua` | Optional `callout_folds` config section | No (hardcoded defaults) |

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/callout_folds.lua` | **New file** — complete module |
| `lua/andrew/plugins/render-markdown.lua` | Add `record_toggle()` call in `toggle_callout_fold()`, add `restore()` call in `BufWinEnter`/`BufRead` autocmd |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.callout_folds").setup()` |
| `lua/andrew/vault/config.lua` | Add `callout_folds` config section (optional) |

---

## Risk Assessment

**Risk: Low**

- New module with minimal touchpoints (two `pcall(require, ...)` calls added to existing code in `render-markdown.lua`).
- Uses the proven `engine.json_store()` pattern (same as `frecency.lua`, `pins.lua`, `saved_searches.lua`).
- All integration calls are wrapped in `pcall` — if `callout_folds.lua` fails to load, the existing fold behavior is completely unaffected.
- Content-based fingerprinting is conservative: when in doubt (title changed, body rewritten), the override is silently dropped and the source suffix default takes over. This is the safe direction (no stale overrides applied to wrong callouts).
- Cache auto-prune prevents unbounded growth.
- `<leader>mZ` and `:VaultFoldClear` provide escape hatches if anything behaves unexpectedly.

---

## Future Enhancements

1. **Bulk fold toggle** — `:VaultFoldAll` / `:VaultUnfoldAll` to collapse/expand all callouts in a buffer with persistence.
2. **Per-type defaults** — config option to always collapse/expand certain callout types regardless of source suffix (e.g., "always collapse `[!QUOTE]`").
3. **Sync with source** — optional command to rewrite source suffixes (`-`/`+`) to match the cached user preferences, making the override permanent in the file.
4. **Cache statistics** — `:VaultFoldStats` showing number of cached overrides per file.
