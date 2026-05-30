# 43 --- JSON Parse Error Logging in vault_index.lua

## Motivation

Several JSON decode/encode operations across the vault module silently swallow
failures. When the persisted index file becomes corrupted (truncated write,
disk full, manual edit gone wrong), the user sees no indication of the problem.
The index simply falls back to an empty state and triggers a full rebuild,
which can take several seconds on large vaults. Worse, if the *encode* path
fails during persist, the index is never saved -- but nothing tells the user
their vault index is not being persisted.

The affected locations are:

1. **`vault_index.lua` line 152-153** -- `pcall(vim.json.decode, content)` in
   `load()`. If the persisted `index.json` is corrupted, `ok` is false and the
   function returns `false` with zero diagnostic output.
2. **`vault_index.lua` line 190-191** -- `pcall(vim.json.encode, data)` in
   `_persist()`. If encoding fails (e.g., a NaN or userdata value snuck into
   the index), the persist silently aborts.
3. **`engine.lua` line 275-276** -- `pcall(vim.json.decode, raw)` in
   `json_store().load()`. Every JSON-backed store (frecency, saved searches,
   URL cache, etc.) uses this helper. A corrupt store file is silently replaced
   with defaults.
4. **`engine.lua` line 286** -- `vim.json.encode(data)` in
   `json_store().save()`. This call is *not* wrapped in pcall at all. If
   encoding fails, it throws an unhandled error that propagates to whatever
   triggered the save.

This document proposes adding WARN-level notifications at each silent failure
point while preserving the existing graceful fallback behavior.

---

## Current State Analysis

### File: `lua/andrew/vault/vault_index.lua`

#### Location 1: `load()` method (lines 143-164)

```lua
--- Load from persisted index. Returns true if successful.
function M.VaultIndex:load()
  local path = self:_index_path()
  local f = io.open(path, "r")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return false end

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return false end

  if data.version ~= SCHEMA_VERSION then return false end
  if data.vault_path ~= self.vault_path then return false end

  self.files = data.files or {}
  -- Rebuild derived indexes so the index is immediately queryable
  self:_rebuild_name_index()
  self:_recompute_inlinks()
  self._ready = true
  return true
end
```

**Problem:** Line 153 conflates two different failure modes into a single
silent `return false`:

- `not ok` -- the JSON is malformed (parse error). The error message is in
  `data` (pcall's second return value on failure).
- `type(data) ~= "table"` -- the JSON is valid but is not an object (e.g.,
  the file contains `"hello"` or `null`). Less common but still worth
  distinguishing.

In both cases, the caller (`prebuild_name_cache_async` in engine.lua, line
815) receives `false` and triggers a full async rebuild. The user never learns
their index file was corrupt.

#### Location 2: `_persist()` method (lines 177-197)

```lua
--- Write index to disk immediately.
function M.VaultIndex:_persist()
  cleanup.close_timer(self._persist_timer)
  self._persist_timer = nil

  local dir = self.vault_path .. "/.vault-index"
  vim.fn.mkdir(dir, "p")

  local data = {
    version = SCHEMA_VERSION,
    vault_path = self.vault_path,
    built_at = os.time(),
    files = self.files,
  }
  local ok, json = pcall(vim.json.encode, data)
  if not ok then return end

  local f = io.open(self:_index_path(), "w")
  if not f then return end
  f:write(json)
  f:close()
end
```

**Problem:** Two silent failures:

- Line 191: `if not ok then return end` -- the JSON encode error message is
  in `json` (pcall's second return value), but it is discarded. The index
  will not be persisted for this session. On next startup, a stale or missing
  index triggers a full rebuild.
- Line 194: `if not f then return end` -- file open failure. Could be a
  permissions issue, disk full, or the directory somehow not created despite
  the `mkdir` call on line 182.

#### Existing notification helper

`vault_index.lua` already defines a `progress_notify` helper (lines 78-84)
that uses a stable notification ID for in-place replacement:

```lua
local function progress_notify(msg, level)
  vim.notify(msg, level, {
    title = "Vault Index",
    id = "vault_index_progress",
    replace = "vault_index_progress",
  })
end
```

The error notifications proposed below should NOT reuse this helper or its ID.
Progress notifications and error notifications serve different purposes and
should not replace each other. A distinct notification without `id`/`replace`
is appropriate for error conditions -- these should stack, not vanish when the
next progress update fires.

### File: `lua/andrew/vault/engine.lua`

#### Location 3: `json_store().load()` (lines 269-278)

```lua
  local function load()
    local file = io.open(path(), "r")
    if not file then return vim.deepcopy(defaults) end
    local raw = file:read("*a")
    file:close()
    if raw == "" then return vim.deepcopy(defaults) end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then return vim.deepcopy(defaults) end
    return decoded
  end
```

**Problem:** Line 276 silently falls back to defaults on decode failure.
Unlike `vault_index.lua:load()`, this is a *generic* helper used by multiple
subsystems (frecency, saved searches, URL validation cache). When any of these
files become corrupt, the user's stored data is silently replaced with empty
defaults.

The `path()` closure captures the filename, so the error message can include
which specific store file failed to parse.

#### Location 4: `json_store().save()` (lines 280-288)

```lua
  local function save(data)
    local file = io.open(path(), "w")
    if not file then
      vim.notify("Vault: failed to write " .. path(), vim.log.levels.WARN)
      return
    end
    file:write(vim.json.encode(data))
    file:close()
  end
```

**Problem:** Line 286 calls `vim.json.encode(data)` without pcall. If
encoding fails (e.g., data contains a function value, userdata, or NaN), an
unhandled Lua error propagates up to whoever called `save()`. The file open on
line 281 already succeeded, so the file has been truncated to zero bytes. On
next `load()`, the store returns defaults -- but the user also sees a raw Lua
stack trace instead of a clean error message.

### Additional occurrence: `url_validate.lua`

#### Location 5: `load_cache()` (lines 220-235)

```lua
function M.load_cache(vault_path)
  _cache_path = vault_path .. "/.vault-index/url-cache.json"
  local f = io.open(_cache_path, "r")
  if not f then
    _cache = {}
    return
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    _cache = data
  else
    _cache = {}
  end
end
```

**Problem:** The else branch (line 232-233) silently resets the cache on
decode failure. Same pattern as the others.

#### Location 6: `_persist()` (lines 249-267)

```lua
function M._persist()
  if not _cache_dirty or not _cache_path then return end
  local pruned = {}
  for url, entry in pairs(_cache) do
    if cache_valid(entry) then
      pruned[url] = entry
    end
  end
  local dir = vim.fn.fnamemodify(_cache_path, ":h")
  vim.fn.mkdir(dir, "p")
  local f = io.open(_cache_path, "w")
  if f then
    f:write(vim.json.encode(pruned))
    f:close()
    _cache = pruned
    _cache_dirty = false
  end
end
```

**Problem:** Line 262 calls `vim.json.encode(pruned)` without pcall, same
issue as `json_store().save()`. An encoding failure would throw an unhandled
error.

---

## Implementation

### Principle

For each silent failure point:

1. Add a `vim.notify` at `vim.log.levels.WARN` with the parse/encode error
   message and the file path that failed.
2. Keep the existing graceful fallback behavior (`return false`, return
   defaults, etc.) -- just add logging before it.
3. Do not use the `progress_notify` helper or its notification ID.
4. Wrap unprotected `vim.json.encode` calls in pcall where they are not
   already protected.

---

### Change 1: `vault_index.lua` -- `load()` method

#### Before (lines 152-153):

```lua
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return false end
```

#### After:

```lua
  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    vim.notify(
      "Vault Index: failed to parse " .. path .. ": " .. tostring(data),
      vim.log.levels.WARN
    )
    return false
  end
  if type(data) ~= "table" then
    vim.notify(
      "Vault Index: unexpected format in " .. path .. " (expected object, got " .. type(data) .. ")",
      vim.log.levels.WARN
    )
    return false
  end
```

**Why separate the two conditions:** The `not ok` case means the JSON is
malformed and `data` contains the parse error string from `vim.json.decode`.
The `type(data) ~= "table"` case means the JSON is valid but is not an object
-- a different diagnostic message is appropriate. Splitting them also keeps
each `vim.notify` call focused and readable.

---

### Change 2: `vault_index.lua` -- `_persist()` method

#### Before (lines 190-196):

```lua
  local ok, json = pcall(vim.json.encode, data)
  if not ok then return end

  local f = io.open(self:_index_path(), "w")
  if not f then return end
  f:write(json)
  f:close()
```

#### After:

```lua
  local ok, json = pcall(vim.json.encode, data)
  if not ok then
    vim.notify(
      "Vault Index: failed to encode index for persist: " .. tostring(json),
      vim.log.levels.WARN
    )
    return
  end

  local index_path = self:_index_path()
  local f, err = io.open(index_path, "w")
  if not f then
    vim.notify(
      "Vault Index: failed to write " .. index_path .. ": " .. (err or "unknown error"),
      vim.log.levels.WARN
    )
    return
  end
  f:write(json)
  f:close()
```

**Why also fix the `io.open` failure:** The file open failure on line 194 is
the same class of silent-swallow bug. While the user's request focuses on JSON
errors, fixing the adjacent `io.open` is trivial (one line change) and
addresses the same diagnostic gap. The `io.open` already returns an error
string as its second value, so we capture it with `local f, err = ...`.

---

### Change 3: `engine.lua` -- `json_store().load()`

#### Before (lines 275-276):

```lua
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then return vim.deepcopy(defaults) end
```

#### After:

```lua
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok then
      vim.notify(
        "Vault: failed to parse " .. path() .. ": " .. tostring(decoded),
        vim.log.levels.WARN
      )
      return vim.deepcopy(defaults)
    end
    if type(decoded) ~= "table" then
      vim.notify(
        "Vault: unexpected format in " .. path() .. " (expected object, got " .. type(decoded) .. ")",
        vim.log.levels.WARN
      )
      return vim.deepcopy(defaults)
    end
```

**Note on `path()`:** The `path` closure is already defined within the
`json_store` scope and returns the full file path. This means the error
message includes the specific store file (e.g.,
`.vault-frecency.json`, `.vault-saved-searches.json`), making it easy to
identify which store is corrupt.

---

### Change 4: `engine.lua` -- `json_store().save()`

#### Before (lines 280-288):

```lua
  local function save(data)
    local file = io.open(path(), "w")
    if not file then
      vim.notify("Vault: failed to write " .. path(), vim.log.levels.WARN)
      return
    end
    file:write(vim.json.encode(data))
    file:close()
  end
```

#### After:

```lua
  local function save(data)
    local ok_enc, json = pcall(vim.json.encode, data)
    if not ok_enc then
      vim.notify(
        "Vault: failed to encode data for " .. path() .. ": " .. tostring(json),
        vim.log.levels.WARN
      )
      return
    end
    local file = io.open(path(), "w")
    if not file then
      vim.notify("Vault: failed to write " .. path(), vim.log.levels.WARN)
      return
    end
    file:write(json)
    file:close()
  end
```

**Why encode before opening the file:** The original code opens the file
first (truncating it to zero bytes), then calls `vim.json.encode`. If encode
throws, the file is left empty. By encoding first and only opening the file
after a successful encode, we avoid corrupting the existing store on encode
failure. This is a correctness fix beyond just adding logging.

---

### Change 5: `url_validate.lua` -- `load_cache()`

#### Before (lines 229-234):

```lua
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    _cache = data
  else
    _cache = {}
  end
```

#### After:

```lua
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    _cache = data
  else
    vim.notify(
      "Vault: failed to parse URL cache at " .. _cache_path .. (not ok and (": " .. tostring(data)) or ""),
      vim.log.levels.WARN
    )
    _cache = {}
  end
```

---

### Change 6: `url_validate.lua` -- `_persist()`

#### Before (lines 260-266):

```lua
  local f = io.open(_cache_path, "w")
  if f then
    f:write(vim.json.encode(pruned))
    f:close()
    _cache = pruned
    _cache_dirty = false
  end
```

#### After:

```lua
  local ok_enc, json = pcall(vim.json.encode, pruned)
  if not ok_enc then
    vim.notify(
      "Vault: failed to encode URL cache: " .. tostring(json),
      vim.log.levels.WARN
    )
    return
  end
  local f = io.open(_cache_path, "w")
  if f then
    f:write(json)
    f:close()
    _cache = pruned
    _cache_dirty = false
  end
```

Same encode-before-open pattern as Change 4.

---

## Complete Files After All Changes

### `vault_index.lua` -- `load()` method (lines 143-164)

```lua
--- Load from persisted index. Returns true if successful.
function M.VaultIndex:load()
  local path = self:_index_path()
  local f = io.open(path, "r")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return false end

  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    vim.notify(
      "Vault Index: failed to parse " .. path .. ": " .. tostring(data),
      vim.log.levels.WARN
    )
    return false
  end
  if type(data) ~= "table" then
    vim.notify(
      "Vault Index: unexpected format in " .. path .. " (expected object, got " .. type(data) .. ")",
      vim.log.levels.WARN
    )
    return false
  end

  if data.version ~= SCHEMA_VERSION then return false end
  if data.vault_path ~= self.vault_path then return false end

  self.files = data.files or {}
  -- Rebuild derived indexes so the index is immediately queryable
  self:_rebuild_name_index()
  self:_recompute_inlinks()
  self._ready = true
  return true
end
```

### `vault_index.lua` -- `_persist()` method (lines 177-197)

```lua
--- Write index to disk immediately.
function M.VaultIndex:_persist()
  cleanup.close_timer(self._persist_timer)
  self._persist_timer = nil

  local dir = self.vault_path .. "/.vault-index"
  vim.fn.mkdir(dir, "p")

  local data = {
    version = SCHEMA_VERSION,
    vault_path = self.vault_path,
    built_at = os.time(),
    files = self.files,
  }
  local ok, json = pcall(vim.json.encode, data)
  if not ok then
    vim.notify(
      "Vault Index: failed to encode index for persist: " .. tostring(json),
      vim.log.levels.WARN
    )
    return
  end

  local index_path = self:_index_path()
  local f, err = io.open(index_path, "w")
  if not f then
    vim.notify(
      "Vault Index: failed to write " .. index_path .. ": " .. (err or "unknown error"),
      vim.log.levels.WARN
    )
    return
  end
  f:write(json)
  f:close()
end
```

### `engine.lua` -- `json_store()` function (lines 262-291)

```lua
function M.json_store(filename, defaults)
  defaults = defaults or {}

  local function path()
    return M.vault_path .. "/" .. filename
  end

  local function load()
    local file = io.open(path(), "r")
    if not file then return vim.deepcopy(defaults) end
    local raw = file:read("*a")
    file:close()
    if raw == "" then return vim.deepcopy(defaults) end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok then
      vim.notify(
        "Vault: failed to parse " .. path() .. ": " .. tostring(decoded),
        vim.log.levels.WARN
      )
      return vim.deepcopy(defaults)
    end
    if type(decoded) ~= "table" then
      vim.notify(
        "Vault: unexpected format in " .. path() .. " (expected object, got " .. type(decoded) .. ")",
        vim.log.levels.WARN
      )
      return vim.deepcopy(defaults)
    end
    return decoded
  end

  local function save(data)
    local ok_enc, json = pcall(vim.json.encode, data)
    if not ok_enc then
      vim.notify(
        "Vault: failed to encode data for " .. path() .. ": " .. tostring(json),
        vim.log.levels.WARN
      )
      return
    end
    local file = io.open(path(), "w")
    if not file then
      vim.notify("Vault: failed to write " .. path(), vim.log.levels.WARN)
      return
    end
    file:write(json)
    file:close()
  end

  return { load = load, save = save, path = path }
end
```

### `url_validate.lua` -- `load_cache()` (lines 220-235)

```lua
function M.load_cache(vault_path)
  _cache_path = vault_path .. "/.vault-index/url-cache.json"
  local f = io.open(_cache_path, "r")
  if not f then
    _cache = {}
    return
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    _cache = data
  else
    vim.notify(
      "Vault: failed to parse URL cache at " .. _cache_path .. (not ok and (": " .. tostring(data)) or ""),
      vim.log.levels.WARN
    )
    _cache = {}
  end
end
```

### `url_validate.lua` -- `_persist()` (lines 249-267)

```lua
function M._persist()
  if not _cache_dirty or not _cache_path then return end
  -- Prune expired entries before writing
  local pruned = {}
  for url, entry in pairs(_cache) do
    if cache_valid(entry) then
      pruned[url] = entry
    end
  end
  local dir = vim.fn.fnamemodify(_cache_path, ":h")
  vim.fn.mkdir(dir, "p")
  local ok_enc, json = pcall(vim.json.encode, pruned)
  if not ok_enc then
    vim.notify(
      "Vault: failed to encode URL cache: " .. tostring(json),
      vim.log.levels.WARN
    )
    return
  end
  local f = io.open(_cache_path, "w")
  if f then
    f:write(json)
    f:close()
    _cache = pruned
    _cache_dirty = false
  end
end
```

---

## Testing Instructions

### 1. Corrupt Index File (vault_index.lua load)

1. Open a vault file so the index initializes normally.
2. Close Neovim to ensure the index is persisted.
3. Manually corrupt the index file:
   ```bash
   echo "this is not json" > ~/Documents/Obsidian-Vault/Obsidian-Vault/.vault-index/index.json
   ```
4. Reopen Neovim and open a vault file.
5. **Expected:** A WARN notification appears: `Vault Index: failed to parse
   .../index.json: Expected value but found T_STRING at character 1`.
6. **Expected:** The index falls back to a full async rebuild (same behavior
   as before, but now with a visible warning).
7. Verify the index is functional after rebuild: `:VaultIndexStatus` should
   show ready=true with the correct file count.

### 2. Non-object Index File (vault_index.lua load)

1. Write valid JSON that is not an object:
   ```bash
   echo '"just a string"' > ~/Documents/Obsidian-Vault/Obsidian-Vault/.vault-index/index.json
   ```
2. Reopen Neovim and open a vault file.
3. **Expected:** A WARN notification appears: `Vault Index: unexpected format
   in .../index.json (expected object, got string)`.
4. **Expected:** Full rebuild proceeds as before.

### 3. Encode Failure (vault_index.lua persist)

This is harder to trigger in practice because the index data is all
strings/numbers/tables. To test:

1. Temporarily inject a non-serializable value into the index:
   ```lua
   -- In :lua
   local vi = require("andrew.vault.vault_index")
   local idx = vi.current()
   idx.files["__test__"] = { bad_field = function() end }
   idx:_persist()
   ```
2. **Expected:** A WARN notification appears: `Vault Index: failed to encode
   index for persist: ...` with the Lua error about encoding a function value.
3. **Expected:** The persist aborts; the existing index.json on disk is
   unchanged (no data loss).
4. Clean up: `idx.files["__test__"] = nil`.

### 4. Corrupt JSON Store File (engine.lua json_store)

1. Identify a JSON store file (e.g., frecency):
   ```bash
   echo "corrupt{{{" > ~/Documents/Obsidian-Vault/Obsidian-Vault/.vault-frecency.json
   ```
2. Reopen Neovim and trigger the subsystem that uses that store (e.g., open a
   vault note picker that uses frecency sorting).
3. **Expected:** A WARN notification appears: `Vault: failed to parse
   .../.vault-frecency.json: Expected value but found ...`.
4. **Expected:** The store falls back to defaults (empty frecency data).
   Functionality continues normally, just without historical data.

### 5. Encode-Before-Open Safety (engine.lua json_store save)

1. Temporarily create a store with a non-serializable value:
   ```lua
   -- In :lua
   local engine = require("andrew.vault.engine")
   local store = engine.json_store(".vault-test-encode.json")
   store.save({ bad = coroutine.create(function() end) })
   ```
2. **Expected:** A WARN notification appears: `Vault: failed to encode data
   for .../.vault-test-encode.json: ...`.
3. **Expected:** The store file on disk is NOT created (or if it existed
   before, is NOT truncated). This confirms the encode-before-open ordering
   prevents data loss.

### 6. URL Cache Corruption (url_validate.lua)

1. Corrupt the URL cache:
   ```bash
   echo "not json" > ~/Documents/Obsidian-Vault/Obsidian-Vault/.vault-index/url-cache.json
   ```
2. Reopen Neovim and open a vault file (triggers `load_cache`).
3. **Expected:** A WARN notification appears: `Vault: failed to parse URL
   cache at .../url-cache.json: ...`.
4. **Expected:** URL validation continues with an empty cache.

### 7. Regression: Normal Operation

1. Restore all files to valid state (or delete them so they regenerate).
2. Open Neovim, open vault files, navigate, search, use embeds.
3. **Expected:** No spurious WARN notifications. All operations behave
   identically to before these changes.
4. Close Neovim and reopen. **Expected:** Index loads from persisted file
   without warnings. `:VaultIndexStatus` shows the persisted file count.

---

## Summary of Changes

| File | Lines Changed | Description |
|------|---------------|-------------|
| `lua/andrew/vault/vault_index.lua` | ~18 | Add WARN notifications to `load()` and `_persist()` for JSON decode/encode failures and file write failure |
| `lua/andrew/vault/engine.lua` | ~20 | Add WARN notifications to `json_store().load()` for decode failure; wrap `json_store().save()` encode in pcall with encode-before-open ordering |
| `lua/andrew/vault/url_validate.lua` | ~12 | Add WARN notification to `load_cache()` for decode failure; wrap `_persist()` encode in pcall with encode-before-open ordering |

No new files. No new dependencies. No behavioral changes beyond adding WARN
notifications on error paths that previously failed silently. The
encode-before-open reordering in `json_store().save()` and
`url_validate._persist()` is a correctness improvement that prevents data loss
on encode failure.
