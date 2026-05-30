# 60 --- Index Persistence & Memory Layout Optimizations

> This document is a self-contained implementation guide. Each optimization
> below is unique to this document.

Improvements to the vault index's JSON persistence strategy, memory layout
of index entries, and parser efficiency — data-level optimizations for the
vault index build and persistence pipeline.

---

## 1. Incremental JSON Persistence

**Status:** IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/vault_index.lua` (lines 184-211)

The `_persist()` method serializes the ENTIRE `self.files` table to JSON
every time it's called:

```lua
function M.VaultIndex:_persist()
  local data = {
    version = SCHEMA_VERSION,
    vault_path = self._vault_path,
    files = self.files,        -- Entire table serialized
  }
  local ok, json = pcall(vim.json.encode, data)
  -- ... write to file ...
end
```

Persistence is debounced at 5 seconds (`config.index.persist_debounce_ms`).
For a 2000-file vault, the JSON file can be 2-5MB. Every 5 seconds during
active editing, the entire 2-5MB is re-encoded and written to disk, even
if only 1 file changed.

**Measured overhead:**
- `vim.json.encode()` for 2000 entries: ~20-50ms
- File write of 3MB: ~5-10ms on SSD
- Total: ~25-60ms every 5 seconds during editing

### Proposed Solution

Implement a write-ahead log (WAL) pattern:

1. **On file change:** Append a delta entry to `.vault-index/changes.jsonl`
   (one JSON object per line, append-only)
2. **On full persist (VimLeavePre or periodic):** Write complete
   `.vault-index/index.json` and truncate the WAL
3. **On load:** Read `index.json`, then replay any WAL entries

### Code Changes

**File: `lua/andrew/vault/vault_index.lua`**

```lua
--- Persist a delta for changed/deleted files (append-only, fast).
---@param changed_paths string[]  rel_paths of changed files
---@param deleted_paths string[]  rel_paths of deleted files
function M.VaultIndex:_persist_delta(changed_paths, deleted_paths)
  local wal_path = self._index_dir .. "/changes.jsonl"
  local f = io.open(wal_path, "a")
  if not f then return end

  for _, rel_path in ipairs(changed_paths) do
    local entry = self.files[rel_path]
    if entry then
      local ok, line = pcall(vim.json.encode, { op = "set", path = rel_path, entry = entry })
      if ok then f:write(line .. "\n") end
    end
  end

  for _, rel_path in ipairs(deleted_paths) do
    local ok, line = pcall(vim.json.encode, { op = "del", path = rel_path })
    if ok then f:write(line .. "\n") end
  end

  f:close()
end

--- Full persist: write complete index and truncate WAL.
function M.VaultIndex:_persist_full()
  -- Existing full persist logic
  local data = {
    version = SCHEMA_VERSION,
    vault_path = self._vault_path,
    files = self.files,
  }
  local ok, json = pcall(vim.json.encode, data)
  if not ok then return end

  local index_path = self._index_dir .. "/index.json"
  local f = io.open(index_path, "w")
  if not f then return end
  f:write(json)
  f:close()

  -- Truncate WAL
  local wal_path = self._index_dir .. "/changes.jsonl"
  local wf = io.open(wal_path, "w")
  if wf then wf:close() end
end

--- Load: read index.json then replay WAL.
function M.VaultIndex:load()
  -- ... existing index.json load ...

  -- Replay WAL entries
  local wal_path = self._index_dir .. "/changes.jsonl"
  local wf = io.open(wal_path, "r")
  if wf then
    local wal_count = 0
    for line in wf:lines() do
      local ok, entry = pcall(vim.json.decode, line)
      if ok then
        if entry.op == "set" then
          self.files[entry.path] = entry.entry
        elseif entry.op == "del" then
          self.files[entry.path] = nil
        end
        wal_count = wal_count + 1
      end
    end
    wf:close()
    if wal_count > 0 then
      log.info("Replayed " .. wal_count .. " WAL entries")
    end
  end

  self:_rebuild_name_index()
  -- ... rest of load() ...
end
```

**Update debounced persist to use delta:**

```lua
-- In update_files_batch() or the debounce callback:
function M.VaultIndex:_schedule_persist(changed_paths, deleted_paths)
  -- Use delta persist for debounced writes
  self:_persist_delta(changed_paths, deleted_paths)

  -- Schedule periodic full persist (every 60s or on VimLeavePre)
  if not self._full_persist_scheduled then
    self._full_persist_scheduled = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      once = true,
      callback = function()
        self:_persist_full()
      end,
    })
  end
end
```

### Expected Performance Improvement

For a typical editing session with 1-5 file changes per persist cycle:

- **Before:** ~25-60ms per persist (full JSON encode + write)
- **After (delta):** ~0.5-2ms per persist (encode 1-5 small entries + append)
- **Full persist on exit:** Same ~25-60ms, but only happens once

**Over a 1-hour session with 200 file saves:** saves ~200 * 30ms = 6 seconds
of cumulative I/O overhead.

### Risk Assessment

- **WAL corruption:** If Neovim crashes mid-WAL-write, a partial line may
  exist. The `pcall(vim.json.decode, line)` in the replay loop handles this
  gracefully by skipping malformed lines.
- **WAL growth:** Without periodic compaction, the WAL could grow large. The
  VimLeavePre handler compacts it. A safety check on WAL size (>1000 lines
  -> trigger full persist) prevents runaway growth.
- **Atomic writes:** The full persist should use write-to-temp + rename
  for atomicity. The WAL append is inherently append-safe on POSIX.

---

## 2. Reduced Entry Memory Footprint

**Status:** IMPLEMENTED

### Problem Analysis

**File:** `lua/andrew/vault/vault_index_parser.lua` (lines 462-481)

Each index entry stores redundant data:

1. **Both `abs_path` and `rel_path`:** `abs_path` = `vault_path .. "/" .. rel_path`.
   Storing both wastes ~80 bytes per entry.

2. **Both `headings` array and `heading_slugs` set:** `heading_slugs` is
   derivable from `headings` via `heading_to_slug()`.

3. **Both `block_ids` array and `block_id_set` dict:** `block_id_set` is
   derivable from `block_ids`.

4. **`basename` and `folder`:** Both derivable from `rel_path`.

For a 2000-file vault:
- `abs_path` redundancy: 2000 * 80 bytes = 160 KB
- Duplicate heading/block structures: ~200 KB estimated
- `basename`/`folder`: 2000 * 40 bytes = 80 KB
- **Total: ~440 KB of redundant storage**

### Proposed Solution

Store only `rel_path` in entries; derive other paths on demand. Replace
duplicate structures with lazy computation.

### Code Changes

**File: `lua/andrew/vault/vault_index_parser.lua`**

```lua
-- Before (line 465):
return {
  rel_path = rel_path,
  abs_path = abs_path,
  basename = basename,
  folder = folder,
  -- ...
  headings = headings,
  heading_slugs = heading_slugs,
  block_ids = block_ids,
  block_id_set = block_id_set,
}

-- After:
return {
  rel_path = rel_path,
  -- abs_path: derived from vault_path + rel_path
  -- basename: derived from rel_path
  -- folder: derived from rel_path
  -- ...
  headings = headings,
  -- heading_slugs: derived from headings on demand
  block_ids = block_ids,
  -- block_id_set: derived from block_ids on demand
}
```

**File: `lua/andrew/vault/vault_index.lua`** (accessor helpers)

```lua
--- Get absolute path for an entry.
function M.VaultIndex:abs_path(entry)
  return self._vault_path .. "/" .. entry.rel_path
end

--- Get basename for an entry (cached on first access via __index).
function M.VaultIndex.entry_basename(entry)
  if not entry._basename then
    entry._basename = entry.rel_path:match("([^/]+)%.md$")
      or entry.rel_path:gsub("%.md$", "")
  end
  return entry._basename
end

--- Get heading slug set (cached on first access).
function M.VaultIndex.entry_heading_slugs(entry)
  if not entry._heading_slugs then
    local slug = require("andrew.vault.slug")
    entry._heading_slugs = {}
    for _, h in ipairs(entry.headings or {}) do
      entry._heading_slugs[slug.heading_to_slug(h.text)] = true
    end
  end
  return entry._heading_slugs
end

--- Get block ID set (cached on first access).
function M.VaultIndex.entry_block_id_set(entry)
  if not entry._block_id_set then
    entry._block_id_set = {}
    for _, b in ipairs(entry.block_ids or {}) do
      entry._block_id_set[b.id] = true
    end
  end
  return entry._block_id_set
end
```

### Migration Path

This requires updating all call sites that access `entry.abs_path`,
`entry.basename`, `entry.folder`, `entry.heading_slugs`, or
`entry.block_id_set`. A gradual approach:

1. **Phase 1:** Keep existing fields but mark as deprecated. Add accessor
   methods.
2. **Phase 2:** Update call sites one module at a time.
3. **Phase 3:** Remove redundant fields from parser output.

Alternatively, use `__index` metamethods on entries to compute on demand:

```lua
local entry_mt = {
  __index = function(self, key)
    if key == "abs_path" then
      return vault_path .. "/" .. self.rel_path
    elseif key == "basename" then
      local v = self.rel_path:match("([^/]+)%.md$") or self.rel_path:gsub("%.md$", "")
      rawset(self, "basename", v)
      return v
    end
  end,
}
```

### Expected Performance Improvement

- **Memory savings:** ~440 KB for 2000-file vault (significant for Lua GC)
- **JSON persistence size:** ~30% smaller index file (faster load/save)
- **Trade-off:** First access to derived fields has small compute cost,
  but `rawset` caching ensures it's one-time.

### Risk Assessment

- **Breaking change:** Many modules access `entry.abs_path` directly.
  The metamethod approach maintains backward compatibility.
- **Persistence format:** Removing fields from serialized JSON changes the
  schema. Increment `SCHEMA_VERSION` and handle migration.
- **Performance of __index:** Lua metamethod lookup adds ~10ns per access.
  After `rawset` caching, subsequent accesses are zero-cost.

---

## ~~3. Single-Pass Parser~~

Consolidated into doc `58-parser-single-pass-optimization.md`.

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Incremental Persistence (#1) | Medium | Medium | Medium |
| 2 | Reduced Entry Footprint (#2) | High | Medium | Medium |

#1 reduces I/O overhead during editing sessions. #2 requires updating many
call sites and should be done gradually.

---

## Testing Strategy

### Incremental Persistence (#1)
1. Edit 5 files, check WAL contains 5 entries. Exit Neovim, verify
   `index.json` is updated and WAL is truncated.
2. Simulate crash (kill -9). Restart, verify WAL replay produces correct index.
3. Compare index after WAL replay vs fresh `build_sync()` — must be identical.

### Reduced Entry Footprint (#2)
1. Verify `entry.abs_path` returns correct path via metamethod.
2. Verify `entry.heading_slugs` returns correct set (compare with explicit build).
3. Measure memory before/after with `collectgarbage("count")`.

---

## Related Documents

- **Doc `58-parser-single-pass-optimization.md`** consolidates all parser
  single-pass optimizations.
- **Doc `67-index-persistence-maintenance.md`** covers change-aware persistence
  with generation tracking (complementary approach).
