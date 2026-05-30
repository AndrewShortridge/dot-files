# 42. Content-Hash Change Detection

## Problem

The vault index (`vault_index.lua:1193-1217`) uses mtime+size as its change detection mechanism in `_detect_changes()`:

```lua
function M.VaultIndex:_detect_changes()
  local changed = {}
  local seen = {}

  self:_walk_files(function(rel_path, abs_path, stat)
    seen[rel_path] = true
    local entry = self.files[rel_path]
    if not entry
      or entry.mtime ~= stat.mtime.sec
      or entry.size ~= stat.size
    then
      changed[#changed + 1] = { rel_path = rel_path, abs_path = abs_path, stat = stat }
    end
  end)

  -- Detect deletions
  local deleted = {}
  for rel_path in pairs(self.files) do
    if not seen[rel_path] then
      deleted[#deleted + 1] = rel_path
    end
  end

  return changed, deleted
end
```

This triggers a full re-parse whenever a file's modification timestamp or byte size changes — even when the file content is identical. Note that the codebase already has **chunk-level** SHA-256 hashing in `vault_index_chunker.lua` (via `chunk_digest()` and `diff_chunks()`), which avoids re-parsing unchanged *sections* of a file. However, even the chunked path requires reading the file and splitting it into chunks before any comparison can happen. A file-level content hash would short-circuit the entire pipeline — skipping the read-chunk-diff-parse cycle entirely when the file content is unchanged.

Several common workflows cause mtime changes without modifying content:

1. **Git operations**: `git checkout`, `git rebase`, `git stash pop`, and `git merge` all touch file mtimes. Switching branches can update the mtime of every file that differs between branches, even if the user switches back to the original branch moments later (restoring identical content with a new mtime).

2. **Backup and sync tools**: Dropbox, Syncthing, rsync, and Time Machine restores update mtimes as a side effect of file synchronization.

3. **Save-without-changes**: Some editors (and Neovim itself with certain configurations) write the buffer to disk on `:w` even when no modifications were made, bumping the mtime.

4. **File system operations**: `touch`, `cp --preserve=no`, and archive extraction all modify mtimes without altering content.

For a vault with 5000+ notes, a `git checkout` that touches 500 files triggers 500 full re-parses in `build_async()`. Each parse involves frontmatter extraction, heading enumeration, block ID scanning, task parsing with inline field extraction, outlink resolution, and tag collection — costing 1-5ms per file. The total rebuild cost of 500-2500ms is entirely wasted when the content is unchanged.

## Inspiration

Zed's semantic index uses two distinct hashing strategies at different levels, found across multiple crates:

### Chunk-Level: SHA-256 (embedding_index)

`crates/semantic_index/src/chunking.rs` uses SHA-256 to identify individual code chunks:

```rust
// chunking.rs:3 (import), 25-29 (struct) — Each chunk carries a 32-byte digest
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Chunk {
    pub range: Range<usize>,
    pub digest: [u8; 32],  // SHA-256 of chunk content
}

// chunking.rs:153-156, 194-197 — computed during chunk boundary detection
chunks.push(Chunk {
    range: range.clone(),
    digest: Sha256::digest(&text[range.clone()]).into(),
});
```

The embedding index (`embedding_index.rs:159`) uses **mtime-only** for file-level change detection — if mtime differs, the file is re-chunked and chunks are compared by SHA-256 digest. The `EmbeddedFile` struct (`embedding_index.rs:456-461`) stores `path`, `mtime`, and `chunks`.

### File-Level: BLAKE3 (summary_index)

`crates/semantic_index/src/summary_index.rs` implements a true **two-phase mtime-first, hash-second** pattern:

```rust
// summary_index.rs:62-63 — BLAKE3 digest type alias
pub type Blake3Digest = ArrayString<{ blake3::OUT_LEN * 2 }>;

// summary_index.rs:65-69 — stored per-file digest
#[derive(Debug, Serialize, Deserialize)]
pub struct FileDigest {
    pub mtime: Option<MTime>,
    pub digest: Blake3Digest,
}

// summary_index.rs:331 (in add_to_backlog) — Phase 1: cheap mtime check
if entry.mtime != opt_saved_digest.and_then(|digest| digest.mtime) {

// summary_index.rs:448-456 (in digest_files) — Phase 2: BLAKE3 hash (only when mtime differs)
let digest = {
    let mut hasher = blake3::Hasher::new();
    // Incorporates both path AND content into hash
    hasher.update(path.display().to_string().as_bytes());
    hasher.update(contents.as_bytes());
    hasher.finalize().to_hex()
};
```

The summary index uses two databases (`summary_index.rs:85-86`): `file_digest_db` (path → `FileDigest`) for tracking file state, and `summary_db` (BLAKE3 digest → summary string) for **content-addressed caching**. Identical content (same BLAKE3 digest) reuses the cached LLM summary, avoiding expensive re-summarization. After summarization, both databases are updated together (`summary_index.rs:627-635`).

### Worktree-Level: No Content Hash

Zed's worktree change detection (`crates/worktree/src/worktree.rs:4906-5010`, `build_diff()`) is purely mtime+metadata-based — it compares full `Entry` structs via derived `PartialEq` (lines 3435-3471) with no content hashing. The `Entry` struct contains: `id`, `kind`, `path`, `inode`, `mtime` (wrapped in `Option<MTime>` where `MTime` is imported from the `fs` crate), `canonical_path`, `is_ignored`, `is_always_included`, `is_external`, `is_private`, `size`, `char_bag`, `is_fifo`. The `reuse_entry_id()` function (lines 2950-2967) distinguishes renames (same inode+mtime, different path) from updates (same path, changed mtime).

### Key Insight

The pattern across Zed's codebase: **mtime is a cheap but imprecise change signal; content hash is a definitive change signal.** The mtime check gates the more expensive hash computation. Zed's summary index avoids re-summarizing files whose content hasn't actually changed, even when mtimes are bumped by git operations or sync tools.

The same pattern applies to vault indexing. Our existing chunk-level SHA-256 hashing (in `vault_index_chunker.lua`) already avoids re-parsing unchanged *sections*, but a file-level hash would skip the entire read-chunk-diff pipeline when no content changed at all.

## Design

### Three-Phase Change Detection

The current two-phase check (`mtime+size differs → chunked re-parse`) becomes a three-phase pipeline, adding a file-level content hash before the existing chunked parse:

```
Phase 1: mtime+size check (existing, ~0.001ms per file)
  │
  ├─ unchanged → skip (no work needed)
  │
  └─ changed → Phase 2: file-level content hash check (~0.1ms per file)
       │
       ├─ hash matches → update mtime/size, skip entirely (content unchanged)
       │
       └─ hash differs → Phase 3: chunked parse (~1-5ms per file)
            │
            ├─ chunk digests compared (existing vault_index_chunker.lua logic)
            │
            └─ only changed chunks re-parsed (existing incremental behavior)
```

The key property: Phase 2 only runs for files that Phase 1 flags as changed. Phase 3 (the existing chunked parse pipeline) only runs when the file-level hash confirms actual content changes. In steady state (no git operations, no bulk edits), Phase 2 is rarely invoked. When a git checkout touches 500 files, Phase 2 runs 500 hash comparisons (~50ms) and only proceeds to Phase 3 for the files that actually changed.

This layers on top of the existing chunk-level optimization: Phase 2 catches the case where no content changed at all (skipping the entire pipeline), while Phase 3's chunking catches the case where content changed but only in specific sections.

### Hash Storage

Each index entry gains a `content_hash` field. The entry structure (defined in `vault_index_parser.lua:498-520` via `make_entry()`) currently stores: `rel_path`, `rel_stem`, `rel_stem_lower`, `mtime`, `size`, `ctime`, `frontmatter`, `aliases`, `tags`, `headings`, `block_ids`, `outlinks`, `tasks`, `inline_fields`, `day`, `created_ts`, `modified_ts`, `day_ts`, `_chunks`. The new field is added alongside these:

```json
{
  "version": 7,
  "files": {
    "notes/project-alpha.md": {
      "mtime": 1709827200,
      "size": 4523,
      "content_hash": "a3f2b8c1",
      "rel_path": "notes/project-alpha.md",
      "rel_stem": "notes/project-alpha",
      "frontmatter": {...},
      "tags": ["project", "active"],
      "headings": [...],
      "block_ids": [...],
      "outlinks": [...],
      "tasks": [...]
    }
  }
}
```

The hash is computed over the raw file content as a single byte string — after line-ending normalization (via `parser.read_file()` which calls `text_utils.normalize_line_endings()`) but before any parsing occurs. This means the hash captures everything: frontmatter, body text, whitespace, and normalized line endings. Any change to any part of the file produces a different hash.

### Algorithm Selection

Two hash algorithms are supported, selectable via config:

| Algorithm | Speed (per file) | Collision resistance | Implementation |
|-----------|-------------------|----------------------|----------------|
| CRC32 | ~0.01ms | Adequate for text files (1 in 4 billion) | LuaJIT bit operations |
| SHA-256 | ~0.05ms | Cryptographic (effectively zero) | `vim.fn.sha256()` |

CRC32 is the default. For a vault of 10,000 files, the probability of any two files sharing a CRC32 hash is approximately 1 in 400,000 (birthday problem). In practice, collisions are vanishingly rare because:
- Colliding files would need to have both the same CRC32 AND the same size (Phase 1 already checks size).
- A false collision means one skipped re-parse, which self-corrects on the next edit.

SHA-256 is available for users who want cryptographic certainty. The speed difference is negligible at vault scale.

## Implementation Details

### Step 1: Add config entries

Add to the existing `M.index` section in `config.lua` (lines 338-402), alongside the existing fields (`skip_dirs`, `batch_size`, `persist_debounce_ms`, `persist_min_interval_ms`, `watch`, `watch_debounce_ms`, `warn_collisions`, `show_progress`, `progress_threshold`, `collision_notify_ms`, `use_snapshots`, `max_waiters`, `chunking_enabled`, `min_chunk_lines`, `fallback_threshold`, `chunking_validate`):

```lua
-- In config.lua, within the existing M.index table (after chunking_validate at line 401):

  -- Enable file-level content hash for two-phase change detection.
  -- When true, files flagged by mtime+size are hash-checked before
  -- entering the chunked parse pipeline.
  content_hash_enabled = true,

  -- Hash algorithm for file-level content hashing.
  -- "crc32": fast LuaJIT bit ops (~0.01ms/file), adequate collision resistance
  -- "sha256": uses vim.fn.sha256() (~0.05ms/file), cryptographic certainty
  hash_algorithm = "crc32",
```

### Step 2: Create hash computation utility

Place in `vault_index.lua` alongside the existing require statements (lines 5-18). The file already requires: `resource_cleanup`, `config`, `vault_log`, `summary_tree`, `vault_index_parser`, `vault_index_inlinks`, `vault_index_collisions`, `vault_index_build`, `string_intern`, and `patterns`. The `bit` module is available in LuaJIT (Neovim's Lua runtime). The `vim.fn.sha256()` call is safe here since `vault_index.lua` already uses `vim.uv`, `vim.json`, and `vim.fn` elsewhere.

Note: The codebase already uses `vim.fn.sha256()` for chunk-level hashing in `vault_index_chunker.lua:73-76` (`chunk_digest()`). The file-level hash uses the same function for SHA-256 mode, or a faster CRC32 for the default mode.

```lua
-- In vault_index.lua, near the top-level locals

local bit = require("bit")

--- Compute CRC32 of a string using LuaJIT bit operations.
--- Uses the standard CRC-32/ISO-HDLC polynomial (0xEDB88320).
local crc32_table
local function ensure_crc32_table()
  if crc32_table then return end
  crc32_table = {}
  for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
      if bit.band(crc, 1) == 1 then
        crc = bit.bxor(bit.rshift(crc, 1), 0xEDB88320)
      else
        crc = bit.rshift(crc, 1)
      end
    end
    crc32_table[i] = crc
  end
end

local function compute_crc32(data)
  ensure_crc32_table()
  local crc = 0xFFFFFFFF
  for i = 1, #data do
    local byte = data:byte(i)
    local idx = bit.band(bit.bxor(crc, byte), 0xFF)
    crc = bit.bxor(bit.rshift(crc, 8), crc32_table[idx])
  end
  return string.format("%08x", bit.bxor(crc, 0xFFFFFFFF))
end

local function compute_sha256(data)
  return vim.fn.sha256(data)
end

local hash_functions = {
  crc32 = compute_crc32,
  sha256 = compute_sha256,
}

--- Compute content hash using the configured algorithm.
---@param data string Raw file content (already line-ending-normalized by parser.read_file)
---@return string hex-encoded hash
local function compute_hash(data)
  local algo = config.index.hash_algorithm
  local fn = hash_functions[algo]
  if not fn then
    log.warn("unknown hash algorithm %q, falling back to crc32", algo)
    fn = hash_functions.crc32
  end
  return fn(data)
end
```

### Step 3: Modify _detect_changes() to include hash check

The current implementation is at `vault_index.lua:1193-1217`. The file read uses `parser.read_file()` (defined in `vault_index_parser.lua:588-600`) which opens the file via `io.open()`, reads with `f:read("*a")`, closes, and normalizes line endings via `text_utils.normalize_line_endings()`. Note that `_detect_changes()` calls `_walk_files()` (lines 1150-1177), which recursively scans the vault using `vim.uv.fs_scandir`, filtering by `config.index.skip_dirs` and `.md` extension — file reads here are blocking but brief (one per mtime-changed file).

```lua
function M.VaultIndex:_detect_changes()
  local changed = {}
  local seen = {}
  local hash_enabled = config.index.content_hash_enabled
  local hash_skipped = 0  -- Track for logging

  self:_walk_files(function(rel_path, abs_path, stat)
    seen[rel_path] = true
    local entry = self.files[rel_path]

    if not entry then
      -- New file: always parse
      changed[#changed + 1] = { rel_path = rel_path, abs_path = abs_path, stat = stat }
      return
    end

    -- Phase 1: mtime+size check (cheap)
    if entry.mtime == stat.mtime.sec and entry.size == stat.size then
      return  -- Nothing changed
    end

    -- Phase 2: content hash check (if enabled and entry has a stored hash)
    if hash_enabled and entry.content_hash then
      local content = parser.read_file(abs_path)
      if content then
        local new_hash = compute_hash(content)
        if new_hash == entry.content_hash then
          -- Content unchanged — update mtime/size but skip re-parse
          entry.mtime = stat.mtime.sec
          entry.size = stat.size
          hash_skipped = hash_skipped + 1
          return
        end
        -- Hash differs — store content for reuse during parse (avoid double read)
        changed[#changed + 1] = {
          rel_path = rel_path,
          abs_path = abs_path,
          stat = stat,
          content = content,
          content_hash = new_hash,
        }
        return
      end
    end

    -- Fallback: no hash available or hash disabled — always re-parse
    changed[#changed + 1] = { rel_path = rel_path, abs_path = abs_path, stat = stat }
  end)

  if hash_skipped > 0 then
    log.debug("hash match, skipped reparse: %d files", hash_skipped)
  end

  -- Detect deletions
  local deleted = {}
  for rel_path in pairs(self.files) do
    if not seen[rel_path] then
      deleted[#deleted + 1] = rel_path
    end
  end

  return changed, deleted
end
```

**Important**: When a hash match updates `entry.mtime` and `entry.size` in-place, the dirty flag for debounced persistence must be set so the updated mtime/size values are eventually written to `index.json`. The simplest approach is to increment `_generation` and mark dirty after the walk completes if `hash_skipped > 0`. Note that `_schedule_persist()` (lines 979-1008) accepts `(changed_rel_paths, deleted_rel_paths)` — when called with arguments it writes a delta via `_persist_delta()` (lines 939-964) to the WAL; when called without arguments it schedules a full debounced persist via `_schedule_full_persist()` (lines 997-1008). For hash-match mtime/size updates, a full persist schedule (no args) is appropriate since no entry content changed.

### Step 4: Store hash during parse

The actual build path uses `parse_file_chunked()` in `vault_index_build.lua:138-273` (signature at line 138: `local function parse_file_chunked(abs_path, rel_path, stat, old_entry)`), which calls `parser.read_file(abs_path)` at line 155 and then `parser.parse_content(content, rel_path, stat)` at line 162. The function has multiple code paths: cold start (no cache), small files (below `config.index.min_chunk_lines`), no changes detected (reuse old entry via `entry_from_old()`), too many chunks changed (full re-parse fallback), frontmatter-only change, and body-only changes. The hash must be computed from the same content and attached to the entry after parsing.

There are two approaches:

**Approach A: Compute hash in parse_file_chunked() (preferred)**

`parse_file_chunked()` already reads the file content. Add hash computation after the read, before parsing:

```lua
-- In vault_index_build.lua, within parse_file_chunked():

local content = parser.read_file(abs_path)
if not content then return nil end

-- Compute file-level content hash (reuse pre-computed if available from _detect_changes)
local content_hash = nil
if config.index.content_hash_enabled then
  content_hash = opts_content_hash or compute_hash(content)
end

local lines = vim.split(content, "\n", { plain = true })
-- ... existing chunked parse logic ...

-- After entry is constructed (either via parse_content or chunk merge):
entry.content_hash = content_hash
```

**Approach B: Add content_hash to make_entry()**

Extend `vault_index_parser.lua:498-520` (`make_entry()`) to accept `content_hash`:

```lua
function P.make_entry(fields)
  return {
    rel_path = fields.rel_path,
    rel_stem = fields.rel_stem,
    rel_stem_lower = fields.rel_stem_lower,
    mtime = fields.mtime,
    size = fields.size,
    ctime = fields.ctime,
    content_hash = fields.content_hash,  -- New field
    frontmatter = fields.frontmatter,
    aliases = fields.aliases,
    -- ... rest unchanged ...
  }
end
```

Approach A is preferred because it avoids threading the hash through `parse_content()` — the hash is a file-level concern, not a parsing concern. The hash is simply attached to the entry after parsing completes.

### Step 5: Pass pre-read content through to parser

When `_detect_changes()` reads the file for hash comparison and finds a mismatch, the `content` and `content_hash` are stored on the changed entry. The build loop in `vault_index_build.lua:345-383` calls `parse_file_chunked()` for each changed file. The pre-read content must be threaded through to avoid a second `parser.read_file()` call:

```lua
-- In vault_index_build.lua, modify parse_file_chunked() signature (line 138) to accept optional pre-read content:
local function parse_file_chunked(abs_path, rel_path, stat, old_entry, pre_content, pre_hash)
  -- Use pre-read content if available (from _detect_changes hash check)
  local content = pre_content or parser.read_file(abs_path)
  if not content then return nil end

  -- Use pre-computed hash if available
  local content_hash = pre_hash
  if not content_hash and config.index.content_hash_enabled then
    content_hash = compute_hash(content)
  end

  -- ... existing chunked parse logic (lines, chunks, etc.) ...

  entry.content_hash = content_hash
  return entry
end

-- In the build loop (lines 345-383):
for j = processed + 1, batch_end do
  local file = changed[j]
  local old_entry = old_entries[file.rel_path]
  local entry = parse_file_chunked(
    file.abs_path, file.rel_path, file.stat, old_entry,
    file.content,       -- Pre-read content from _detect_changes (may be nil)
    file.content_hash   -- Pre-computed hash from _detect_changes (may be nil)
  )
  if entry then
    index:_apply_entry_mt(entry)
    apply_sharing(index, entry, old_entry, is_cold_start)
    staged[file.rel_path] = entry
    changed_rel_paths[#changed_rel_paths + 1] = file.rel_path
  end
  files_this_batch = files_this_batch + 1
end
```

This ensures zero redundant file reads: when `_detect_changes()` reads a file for hash comparison and finds a mismatch, that same content is reused by the parser.

### Step 6: Handle schema migration

```lua
local SCHEMA_VERSION = 7  -- Bump from 6

-- In load() (vault_index.lua:866-869):
if data.version ~= SCHEMA_VERSION then
  log.debug("schema version mismatch: got %s, want %s", tostring(data.version), tostring(SCHEMA_VERSION))
  -- Full rebuild will compute hashes for all entries
  return false, "schema version mismatch"
end

-- Entries loaded from a v6 index will have content_hash = nil.
-- This is handled gracefully: _detect_changes() treats a nil stored hash
-- as "no hash available" and falls through to full re-parse, which
-- computes and stores the hash for subsequent checks.
```

No explicit migration logic is needed. When loading a v6 index with schema version 7, the version mismatch in `load()` (line 866) triggers a full rebuild via `build_async()`. During this rebuild, every file is parsed by `parse_file_chunked()` and receives a `content_hash`. Subsequent incremental builds benefit from the stored hashes.

The existing WAL replay logic (`load()` lines 877-898) also works correctly: WAL entries written before the upgrade will lack `content_hash`, and after the version-mismatch triggers a full rebuild, the WAL is truncated on the next persist. WAL replay handles both `op = "set"` (with entry) and `op = "del"` (deletion) operations.

### Step 7: Persist hash in index.json

The existing `_persist()` method (`vault_index.lua:1049-1109`) serializes entry fields via `_prepare_persist_data()` (`vault_index.lua:1015-1045`). Before serialization, derived fields listed in `DERIVED_FIELDS` (`vault_index.lua:32-35`) are stripped:

```lua
local DERIVED_FIELDS = {
  "tag_set", "heading_slugs", "block_id_set",
  "abs_path", "basename", "basename_lower", "folder",
}
```

Since `content_hash` is NOT in this strip list, it persists automatically via `vim.json.encode()`. No changes to the persistence logic are needed.

Similarly, `load()` rebuilds derived fields but does not touch `content_hash` — it's a plain string field that survives the JSON round-trip unchanged.

**WAL consideration**: The WAL system uses `_persist_delta()` (`vault_index.lua:939-964`) to write individual entry updates as JSON lines (operations: `"set"` with entry, `"del"` for deletions), and `_truncate_wal()` (`vault_index.lua:967-971`) to clear the WAL after a full persist. When a hash-match updates only `mtime`/`size` on an entry (without re-parsing), the entry is already in `self.files` and the mtime/size changes should be persisted. A debounced full persist ensures crash safety:

```lua
-- After hash-match mtime/size update in _detect_changes:
if hash_skipped > 0 then
  self:_schedule_persist()  -- No args → schedules full debounced persist via _schedule_full_persist()
end
```

## Performance Impact

### Per-file cost breakdown

| Operation | Time | When |
|-----------|------|------|
| stat() call | ~0.005ms | Every file, every build |
| mtime+size comparison | ~0.001ms | Every file, every build |
| File read (for hash) | ~0.1ms | Only when mtime/size changed |
| CRC32 computation | ~0.01ms | Only when mtime/size changed |
| SHA-256 computation | ~0.05ms | Only when mtime/size changed (if configured) |
| Chunked parse (existing) | ~1-5ms | Only when hash differs (actual content change) |
| — chunk splitting + digest | ~0.1ms | Part of chunked parse |
| — per-chunk re-parse | ~0.5-2ms | Only changed chunks (existing optimization) |

Note: The existing chunked parsing system (doc references: `config.index.chunking_enabled`, `vault_index_chunker.lua`) already optimizes the *within-file* case — when content changes, only modified chunks are re-parsed. The file-level hash optimization targets the *cross-file* case — skipping the entire pipeline (read + chunk + diff + parse) for files whose content hasn't changed despite mtime bumps.

### Scenario analysis

**Normal editing session** (1 file changed):
- Current: 1 file chunked re-parse = ~1-3ms (only changed chunks)
- With hash: 1 file read + hash + chunked re-parse = ~1.1-3.1ms (negligible overhead)
- No benefit expected — the file actually changed.

**Git checkout touching 500 files, 20 actually modified**:
- Current: 500 files read + chunked parse = ~500-1500ms
- With hash: 500 reads + 500 hashes + 20 chunked re-parses = ~75-115ms
- Savings: **~85-92% reduction**

**Git checkout touching 500 files, 0 actually modified** (e.g., branch switch and switch back):
- Current: 500 files read + chunked parse = ~500-1500ms
- With hash: 500 reads + 500 hashes + 0 parses = ~55ms
- Savings: **~89-96% reduction**

**Backup tool touches all 5000 files**:
- Current: 5000 files read + chunked parse = ~5000-15000ms
- With hash: 5000 reads + 5000 hashes + 0 parses = ~550ms
- Savings: **~89-96% reduction**

### Index.json size impact

Each `content_hash` field adds:
- CRC32: 8 hex characters + JSON key overhead = ~25 bytes per entry
- SHA-256: 64 hex characters + JSON key overhead = ~80 bytes per entry

For 5000 files: +125KB (CRC32) or +400KB (SHA-256). This is modest relative to the existing index size, which stores headings, tags, tasks, and outlinks per file.

## Integration Points

### vault_index.lua (main index module)

- `_detect_changes()` (lines 1193-1217): Add Phase 2 hash check between mtime/size test and changed-list insertion. Store pre-read `content` and `content_hash` on changed entries for reuse.
- `SCHEMA_VERSION` (line 28): Bump from 6 to 7.
- `_persist()` (lines 1049-1109) / `_prepare_persist_data()` (lines 1015-1045) / `load()` (lines 846-934): No changes needed — `content_hash` is a regular string field, persisted/loaded automatically. Not in `DERIVED_FIELDS` strip list (lines 32-35).
- Add `compute_hash()`, `compute_crc32()`, `compute_sha256()` utility functions near top-level locals (after existing requires at lines 5-18).
- Schedule persist after hash-match mtime/size updates via `_schedule_persist()` (lines 979-1008, no args → full debounced persist).

### vault_index_build.lua (async build + chunked parser)

- `parse_file_chunked()` (lines 138-273, signature: `abs_path, rel_path, stat, old_entry`): Add optional `pre_content` and `pre_hash` parameters (5th, 6th) to reuse content read during `_detect_changes()` hash check. Attach `content_hash` to the returned entry across all code paths (cold start, small files, chunk-diff, fallback, frontmatter-only, body-only).
- Build loop (lines 345-383): Pass `file.content` and `file.content_hash` from changed entries through to `parse_file_chunked()`.
- Also update `update_files_batch()` (lines 442-517) which calls `parse_file_chunked()` at line 469 — pass `nil, nil` for the new params since it doesn't pre-read content.

### vault_index_parser.lua (entry construction)

- `make_entry()` (lines 498-520): Add `content_hash` field to the entry table. This is the cleanest integration point if using Approach B (see Step 4).
- `parse_file()` (lines 608-614) and `parse_content()` (lines 540-578): No changes needed if hash is attached in `parse_file_chunked()` (Approach A).

### config.lua

- `M.index` section (lines 338-402): Add `content_hash_enabled = true` and `hash_algorithm = "crc32"` after the existing `chunking_validate` field (line 401). Existing chunking fields for reference: `chunking_enabled = true` (line 389), `min_chunk_lines = 20` (line 393), `fallback_threshold = 0.5` (line 397), `chunking_validate = false` (line 401).

### engine.lua

- No changes needed. Engine accesses vault_index via lazy-loaded `get_vault_index()` (lines 13-16) which calls `require("andrew.vault.vault_index")` on first use. The index reads config directly via `require("andrew.vault.config")`. Key integration points: `idx:update_files_batch()` (line 100), `idx:build_async()` (line 102), debug stats reporting (lines 275-305).

## Risks & Mitigations

### CRC32 hash collisions

**Risk**: CRC32 produces a 32-bit hash, giving a theoretical collision probability of 1 in ~4 billion for any two arbitrary strings. With 5000 files, the birthday-problem probability of any collision in the vault is approximately 1 in 170,000.

**Mitigation**: A collision means one file skips re-parsing when it should not have. This is a silent correctness issue, but it self-corrects on the next actual edit to that file (which changes the hash). For users who need guaranteed correctness, `hash_algorithm = "sha256"` eliminates collision risk entirely. Additionally, the mtime+size check has already confirmed the file was touched — a CRC32 collision would require the file to change to different content that happens to produce the same CRC32. This is qualitatively different from a random collision: the new content must be a valid markdown file with the same CRC32, which is astronomically unlikely for natural edits.

### Extra I/O for hash-only check

**Risk**: Reading a file solely to compute its hash (when the hash matches and parse is skipped) adds I/O that the current code does not perform.

**Mitigation**: The file read is only triggered when mtime or size has changed — meaning a re-parse would have occurred anyway, which also reads the file. The hash check replaces a read-then-parse with a read-then-hash (cheaper). On hash match, the parse is skipped entirely. On hash mismatch, the read content is passed through to the parser, so no additional I/O occurs. Net I/O is identical or lower in all cases.

### Schema migration

**Risk**: Upgrading from schema v6 to v7 requires a full index rebuild, which takes ~15 seconds for a 5000-file vault.

**Mitigation**: This is a one-time cost. The existing schema migration path handles this correctly: a version mismatch in `load()` (line 866) returns `false`, causing `init.lua` to run a full `build_async()` rebuild. All entries receive their `content_hash` during this rebuild. Subsequent builds are incremental and benefit from the stored hashes. The rebuild happens asynchronously via the coroutine-based `build_async()` with adaptive batch sizing (~16ms per batch), so the editor remains responsive during migration.

### Entries missing content_hash field

**Risk**: If a user downgrades or manually edits `index.json`, entries may lack the `content_hash` field.

**Mitigation**: `_detect_changes()` checks `entry.content_hash` before attempting the hash comparison. A nil hash falls through to the full re-parse path, which computes and stores the hash. Missing hashes are self-healing: after one incremental build cycle, all entries have hashes.

```lua
-- Graceful handling of missing hash:
if hash_enabled and entry.content_hash then
  -- Phase 2 hash check
else
  -- No hash stored — fall through to re-parse (which stores the hash)
end
```

### Memory overhead during hash check

**Risk**: Reading file content for hash comparison holds the file's content in memory briefly. For the hash-match case, this content is discarded after hashing. For the hash-mismatch case, the content is passed to the parser.

**Mitigation**: Content is a single Lua string, garbage collected after use. Even for a large file (100KB), this is trivial. The content is not held across yield points in the coroutine — it is read, hashed, and either discarded or forwarded within a single batch iteration.

## Relationship to Other Documents

### Doc 09 (Index Memory Reduction)

Doc 09 focuses on reducing the steady-state memory footprint of the in-memory index (string interning, compact representations). The codebase already implements string interning via intern pools configured through `config.intern` (see `vault_index.lua:175-178` and `vault_index_parser.lua`). Doc 42 adds a small per-entry field (`content_hash`: 8-64 bytes) but provides large savings in rebuild CPU time. The memory cost is modest and falls within the budgets discussed in doc 09.

### Doc 07 (Debounced Persistence)

The content hash is persisted alongside other index data using the existing debounced persistence mechanism (`_persist()` at `vault_index.lua:1049-1109` with `_prepare_persist_data()`). No changes to the persistence strategy are needed. The hash simply travels with the entry through the existing persist pipeline. Hash-match mtime/size updates trigger `_schedule_persist()` so updated metadata reaches disk.

### WAL (Write-Ahead Log) Integration

The existing WAL system (`_persist_delta()` at lines 939-964, replayed in `load()` at lines 877-898) writes individual entry mutations as JSON lines with `op = "set"` or `op = "del"`. The WAL is truncated by `_truncate_wal()` (lines 967-971) after a successful full persist, but only if no new deltas were appended during the async write (line 1093). When `_detect_changes()` updates `mtime`/`size` on a hash-match entry, this is an in-place mutation that skips the normal `_apply_staged()` path. To ensure crash safety, either:
1. Write a WAL entry for each hash-match update via `_persist_delta()` (precise but adds WAL traffic), or
2. Rely on the debounced `_schedule_persist()` (no args → `_schedule_full_persist()`) to capture the updated state (simpler, small window of stale mtime on crash).

Option 2 is recommended: the worst case on crash is that a subsequent build re-reads and re-hashes files whose mtime was updated but not yet persisted — the same behavior as before this feature.

### Doc 37 (Scan Completion Waiters)

When a build is triggered by git operations touching many files, the hash check reduces the build time from seconds to milliseconds. Modules waiting for scan completion (via doc 37's waiter pattern, `_check_waiters()`) receive their notification faster, improving perceived responsiveness.

### Doc 17 (Snapshot-Based Index Reads)

Snapshots (enabled via `config.index.use_snapshots`) capture the index state including content hashes. If a snapshot is taken mid-rebuild, entries may have stale hashes for files that have been touched but not yet hash-checked. This is harmless: the snapshot reflects the last fully-parsed state, and the ongoing build will update hashes upon completion.

### Existing Chunking System

The chunked incremental parser (`vault_index_build.lua:138-273`, controlled by `config.index.chunking_enabled`) already uses SHA-256 digests per heading-delimited chunk (`vault_index_chunker.lua:73-76` via `chunk_digest()`, compared positionally in `diff_chunks()` at lines 82-106). This doc's file-level hash is complementary:
- **Chunking** optimizes the case where content changed but only in a few sections (avoids re-parsing unchanged chunks).
- **File-level hash** optimizes the case where content didn't change at all (avoids the entire read-chunk-diff pipeline).

The two features stack: file-level hash is checked first (Phase 2), and chunking kicks in only when the hash confirms actual content changes (Phase 3).
