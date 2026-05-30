# 38. Syntactic Content Chunking

## Problem

The vault index parser (`vault_index_parser.lua`) reads entire file content and extracts frontmatter, aliases, tags, headings, block_ids, outlinks, tasks, inline_fields, and timestamps in a single pass via `P.parse_file(abs_path, rel_path, stat)` (lines 455-530). For a 2000-line daily note or a large MOC (Map of Content), the full parse is expensive. Incremental indexing detects file-level changes via mtime+size (in `vault_index.lua:_detect_changes()`, lines 1160-1184), but any single-character edit — fixing a typo, adding a tag, checking off a task — triggers a full re-parse of the entire file. This means editing line 5 of a 2000-line file re-parses all 2000 lines, even though 99.9% of the content is unchanged.

The cost compounds during rapid editing sessions: each save triggers `build_async()` (in `vault_index_build.lua`, lines 37-198), which diffs mtime+size, finds the file changed, and runs the full single-pass parser (`vault_index_parser.parse_file()`). For files with hundreds of tasks, outlinks, and inline fields, this parser is the dominant cost in the incremental index cycle — even with the existing optimizations (string interning pools at lines 21-26, structural sharing via `structural_sharing.lua`, adaptive batch sizing with TARGET_MS=16 at line 14).

## Inspiration

Zed's `crates/semantic_index/src/chunking.rs` implements syntax-aware chunking for its semantic index. The approach:

- Split source files into 1KB-8KB chunks at syntax boundaries using tree-sitter outline queries (chunk size range defined at lines 20-23: `ChunkSizeRange { min: 1024, max: 8192 }`)
- For markdown, the outline query (`crates/languages/src/markdown/outline.scm`) targets `atx_heading` nodes, making heading levels the natural chunk boundary
- Compute a SHA-256 digest per chunk (`Sha256::digest(&text[range])`, stored as `[u8; 32]` in the `Chunk` struct at lines 25-29)
- Chunks expand to include preceding comments (context-aware boundaries, lines 102-106: expands `start_offset` backward to the beginning of preceding comment rows)
- The chunking respects language grammar via tree-sitter — it never splits mid-function/mid-heading
- Nesting-aware boundary selection: prefers boundaries at lower nesting depth (lines 172-188: counts syntactic ranges containing current line position, only extends chunk end when below min size OR nesting depth is equal/lower)

**Key difference from Zed's approach**: Zed does NOT perform incremental chunk diffing. When a file's mtime changes, the entire file is re-chunked and all chunks are re-embedded (see `embedding_index.rs:159-162`, where `entry.mtime != saved_mtime` triggers full re-processing through `chunk_files()` → `embed_files()` → `persist_embeddings()`). The entire `EmbeddedFile` record (lines 456-461, containing `Vec<EmbeddedChunk>` entries at lines 463-467, each with a `Chunk` and `Embedding`) is replaced in the database. This is acceptable for Zed because embedding is batch-amortized via API calls. Note: Zed's complementary `summary_index.rs` uses BLAKE3 content hashing (`Blake3Digest` over file path + contents) for digest-based deduplication of LLM summaries (summaries keyed by content hash, not file path), but the embedding index does not use this approach.

For our use case (local single-pass parsing), we can do better by comparing chunk digests and only re-parsing changed chunks — the core value proposition of this optimization.

This is adapted for markdown: instead of tree-sitter outline queries, use Lua pattern matching against heading boundaries. Markdown's hierarchical heading structure (`#` through `######`) provides natural, semantically meaningful chunk points. Frontmatter (`---` delimiters) is always its own chunk.

## Design

### Heading-Based Chunking

Files are split into chunks at heading boundaries:

- **Frontmatter chunk**: Everything between the opening and closing `---` delimiters (always one chunk, never split)
- **Heading chunks**: Each top-level or nested heading starts a new chunk. The chunk includes all content from the heading line up to (but not including) the next heading of equal or higher level
- **Preamble chunk**: Any content between the frontmatter and the first heading (if present)

Each chunk stores:
- `start_line` — 1-indexed first line of the chunk
- `end_line` — 1-indexed last line of the chunk (inclusive)
- `digest` — SHA256 hash of the chunk's raw text content (via `vim.fn.sha256()`, already used in `callout_folds.lua:140` for callout fingerprinting with 8-char truncation)
- `parsed_data` — Extracted metadata (headings, block_ids, outlinks, tasks, inline_fields, tags)

### Re-Index Flow

1. Read file content, split into lines
2. Run chunk splitter to produce chunk boundaries
3. For each chunk, compute digest from raw lines
4. Compare digest against cached chunk digest for that file
5. If digest matches: reuse cached `parsed_data` (skip parsing entirely)
6. If digest differs: run parser on just that chunk's lines (with correct line offset), update cached data
7. Merge `parsed_data` from all chunks into the final file entry
8. Apply existing post-processing: metatable (`_apply_entry_mt()`), structural sharing, tag interning
9. Store updated chunk array in the index cache

### Integration with Existing Architecture

The chunking optimization slots into the existing build pipeline without disrupting it:

- **`vault_index_parser.lua`**: `P.parse_file(abs_path, rel_path, stat)` (lines 455-530) gains an optional line-range mode. When called with `start_line`/`end_line` parameters, it only processes that subset of lines with correct offsets. The internal extract functions (`extract_tags` at line 200, `extract_headings` at line 230, `extract_links` at line 276, `extract_tasks` at line 369, `extract_inline_fields` at line 427) are all local functions that would need line-offset awareness.
- **`vault_index_build.lua`**: The adaptive batch loop (lines 99-146, targeting ~16ms per batch via `TARGET_MS` at line 14) calls the chunk-aware parse instead of the full parse. The per-file processing (lines 103-123) currently calls `parser.parse_file()` at line 105, applies `_apply_entry_mt()` at line 107, structural sharing at lines 109-113, and tag interning at lines 116-118. The `_apply_staged()` atomic commit (in `vault_index.lua`, lines 642-706) remains unchanged — it receives the same entry shape.
- **`vault_index.lua`**: `_detect_changes()` (lines 1160-1184) continues to use mtime+size for file-level change detection (mtime check at line 1168, size check at line 1169). Chunking adds a second layer: once a file is flagged as changed, only the changed chunks are re-parsed.
- **Persistence**: The `_chunks` field is serialized alongside existing entry fields in `index.json` (schema version 5, defined at line 23). `_prepare_persist_data()` (lines 982-1012) strips derived fields via `strip_derived()` (lines 772-784) before JSON encoding; `_chunks` must be excluded from stripping. The WAL (`changes.jsonl`, written by `_persist_delta()` at lines 906-931) continues to work — chunk data is part of the entry written to WAL on incremental updates. WAL replay in `load()` (lines 833-850) applies "set"/"del" operations.
- **Derived fields**: Metatable-based lazy fields defined in `make_entry_mt()` (lines 36-87) — `abs_path`, `basename`, `basename_lower`, `folder`, `tag_set`, `heading_slugs`, `block_id_set` — are unaffected. They operate on the merged entry, not on chunks. The `DERIVED_FIELDS` constant (lines 27-30) lists fields stripped before persistence.

### Storage

Chunk digests and parsed data are stored per-file in the index:

```
index.json → files[rel_path] → {
  ...,
  _chunks: [
    { start: 1, end: 15, digest: "a1b2c3...", parsed_data: {...} },
    { start: 16, end: 80, digest: "d4e5f6...", parsed_data: {...} },
    ...
  ]
}
```

The `_chunks` field is internal to the index and not exposed to downstream consumers. The public API continues to return the merged flat entry. The `_chunks` field is stripped during `_prepare_persist_data()` (lines 982-1012) if `chunking_persist` is false (to allow opt-out of storage overhead), but included by default. It must be added to the `DERIVED_FIELDS` list (lines 27-30) only if opt-out stripping is desired; otherwise it persists naturally with the entry.

## Target Modules

- **`vault_index_parser.lua`** — `P.parse_file()` at lines 455-530 (add line-range parameters for chunk-scoped parsing). Internal extract functions are all local: `extract_tags` (line 200), `extract_headings` (line 230), `extract_links` (line 276), `extract_block_ids` (line 254, delegates to `block_patterns`), `extract_tasks` (line 369), `extract_inline_fields` (line 427).
- **`vault_index_build.lua`** — adaptive batch loop at lines 99-146 (add chunk splitting, digest comparison, selective re-parse at line 105 before calling `_apply_staged()`). Also `update_files_batch()` at lines 205-310 (with `parse_file()` call at line 232).
- **`vault_index.lua`** — `_detect_changes()` at lines 1160-1184 (no change needed; chunking is a sub-step of per-file processing)
- **`vault_index.lua`** — `_persist()` at lines 1016-1076, `load()` at lines 800-901, `_prepare_persist_data()` at lines 982-1012 (serialize/deserialize `_chunks` field, add `_chunks` handling in WAL replay at lines 833-850)
- **`config.lua`** — `M.index` section at lines 340-388 (add chunking config options alongside existing `batch_size` at line 351, `persist_debounce_ms` at line 354, `watch` at line 360, `use_snapshots` at line 383, etc.)

## Implementation Steps

1. **Add chunk splitting function** to a new `vault_index_chunker.lua` module (pure function, no side effects, no requires beyond `patterns` module at `lua/andrew/vault/patterns.lua` which exports `HEADING`, `FM_OPEN`, `FM_CLOSE` patterns and compiled regex caches)
2. **Add digest computation** using `vim.fn.sha256()` (already available, used in `callout_folds.lua:140` for callout fingerprinting)
3. **Modify `P.parse_file()` in `vault_index_parser.lua`** (lines 455-530) to accept optional `start_line`/`end_line` parameters — parse a subset of lines with correct line offset so that `heading.line`, `task.line`, `block_id.line` values are file-absolute. Key internal functions to adapt: `extract_headings` (line 230, uses `gmatch(pat.LINE)` with line counter at line 233), `extract_tasks` (line 369, uses `vim.split()` at line 371 with line iteration), `extract_links` (line 276), `extract_inline_fields` (line 427). String interning pools (lines 21-26: tags pool cap=500, fm_keys cap=200, fm_values cap=2000, lowercase cap=5000) continue to work — they intern within chunk-scoped parsing.
4. **Add chunk cache** to the per-file entry structure (`_chunks` array)
5. **Modify the per-file processing** in `vault_index_build.lua`'s adaptive batch loop (lines 99-146, specifically the inner loop at lines 103-123 where `parser.parse_file()` is called at line 105) to:
   - Split file into chunks via `vault_index_chunker.chunk_by_headings()`
   - Compute digests via `vim.fn.sha256()`
   - Compare digests against cached chunks from the previous index entry (accessed via `old_entries[file.rel_path]` at line 110)
   - Only re-parse changed chunks (pass line range to `parse_file()`)
   - Reuse `parsed_data` from unchanged cached chunks
   - Merge all chunk results into the final entry
   - Apply existing post-processing: metatable via `index:_apply_entry_mt(entry)` at line 107, structural sharing via `sharing.share_unchanged(old, entry)` at lines 109-113, tag interning via `sharing.intern_array(index._tag_intern, entry.tags)` at lines 116-118
6. **Handle chunk boundary shifts** — if a heading is inserted/deleted, chunk count changes; `diff_chunks()` detects this and falls back to full re-parse when chunk count differs or >50% of chunks changed
7. **Update `_prepare_persist_data()` (lines 982-1012) and `load()` (lines 800-901)** in `vault_index.lua` to serialize/deserialize `_chunks` (bump SCHEMA_VERSION from 5 to 6 at line 23). In `load()`, the WAL replay loop (lines 833-850) naturally handles `_chunks` since it replaces entire entries. The `strip_derived()` call (lines 772-784) in `_prepare_persist_data()` must NOT strip `_chunks` — ensure it's excluded from the `DERIVED_FIELDS` list (lines 27-30).
8. **Add config options** to `config.lua` `M.index` section (lines 340-388, after existing options like `max_waiters` at line 387)
9. **Add `:VaultIndexChunkDebug`** command to inspect chunk state per file (similar pattern to `:VaultEmbedDebug`, `:VaultCompletionDebug`)

## Chunk Splitting Algorithm

```lua
--- Split file lines into chunks at heading boundaries.
--- Frontmatter is always its own chunk. Each heading starts a new chunk.
--- Tracks code fence state to avoid splitting on headings inside fenced code blocks.
--- @param lines string[] File lines (1-indexed content)
--- @return table[] chunks Array of {start_line, end_line, lines}
function M.chunk_by_headings(lines)
  local chunks = {}
  local current = { start_line = 1, lines = {} }
  local in_frontmatter = false
  local in_code_fence = false

  for i, line in ipairs(lines) do
    -- Handle frontmatter boundaries (only line 1 can start frontmatter)
    if i == 1 and line:match("^%-%-%-$") then
      in_frontmatter = true
      table.insert(current.lines, line)
      goto continue
    end

    if in_frontmatter then
      table.insert(current.lines, line)
      if line:match("^%-%-%-$") then
        -- End of frontmatter: finalize this chunk
        in_frontmatter = false
        current.end_line = i
        table.insert(chunks, current)
        current = { start_line = i + 1, lines = {} }
      end
      goto continue
    end

    -- Track code fence state to avoid false heading matches
    if line:match("^```") then
      in_code_fence = not in_code_fence
    end

    -- Heading boundary: start a new chunk (if current has content)
    -- Only match headings outside of fenced code blocks
    if not in_code_fence and line:match("^#+%s") and #current.lines > 0 then
      current.end_line = i - 1
      table.insert(chunks, current)
      current = { start_line = i, lines = {} }
    end

    table.insert(current.lines, line)

    ::continue::
  end

  -- Finalize last chunk
  if #current.lines > 0 then
    current.end_line = #lines
    table.insert(chunks, current)
  end

  return chunks
end
```

**Note on code fence tracking**: This addresses the "Heading inside a code block" edge case from the Risks section. The `^```" pattern matches both opening and closing fences, toggling the `in_code_fence` flag. This prevents lines like `# comment` inside a fenced code block from being treated as heading boundaries.

## Digest Computation

```lua
--- Compute SHA256 digest of a chunk's content.
--- @param chunk_lines string[] Lines in the chunk
--- @return string digest Hex-encoded SHA256 hash
function M.chunk_digest(chunk_lines)
  local content = table.concat(chunk_lines, "\n")
  return vim.fn.sha256(content)
end
```

Using `vim.fn.sha256()` is straightforward and available in all Neovim versions. It's already used in the codebase (`callout_folds.lua:140` for callout fingerprinting, truncated to 8 chars there — we use the full 64-char hex string for chunk digests). For higher performance on very large vaults, a future optimization could use `vim.uv`-based xxhash (xxh3_64), but SHA256 is sufficient given chunks are small (typically 1-8KB of text). Zed uses SHA256 for chunk digests in `chunking.rs` (lines 155 and 196) and BLAKE3 for summary deduplication in `summary_index.rs`.

### Digest Comparison

```lua
--- Compare new chunks against cached chunks, return indices of changed chunks.
--- @param new_chunks table[] Chunks with digest computed
--- @param cached_chunks table[]|nil Previously cached chunks
--- @return integer[] changed_indices 1-indexed list of chunks that need re-parsing
function M.diff_chunks(new_chunks, cached_chunks)
  if not cached_chunks then
    -- No cache: all chunks are new
    local indices = {}
    for i = 1, #new_chunks do indices[i] = i end
    return indices
  end

  -- If chunk count changed, structure shifted — re-parse all
  -- (heading inserted/deleted shifts all boundaries)
  if #new_chunks ~= #cached_chunks then
    local indices = {}
    for i = 1, #new_chunks do indices[#indices + 1] = i end
    return indices
  end

  -- Same count: compare digests positionally
  local changed = {}
  for i = 1, #new_chunks do
    if new_chunks[i].digest ~= cached_chunks[i].digest then
      changed[#changed + 1] = i
    end
  end

  return changed
end
```

## Cache Structure

Per-file chunk cache stored within the index entry:

```lua
-- In index.json, each file entry gains a _chunks field:
entry._chunks = {
  {
    start_line = 1,
    end_line = 12,
    digest = "e3b0c44298fc1c149afbf4c8996fb924...",
    parsed_data = {
      headings = {},
      block_ids = {},
      outlinks = {},
      tasks = {},
      inline_fields = {},
      tags = {},
    },
  },
  {
    start_line = 13,
    end_line = 85,
    digest = "a7ffc6f8bf1ed76651c14756a061d662...",
    parsed_data = {
      headings = { { text = "Daily Log", level = 2, line = 13 } },
      block_ids = { { id = "blk-abc123", line = 45 } },
      outlinks = { { path = "Project Alpha", ... }, { path = "Meeting Notes", ... } },
      tasks = { ... },
      inline_fields = { ... },
      tags = { "#daily", "#work" },
    },
  },
  -- ...
}
```

**Note**: Outlinks in chunk `parsed_data` store the full outlink structure (path, display, embed, `_name_lower`, `stem_lower`, `basename_lower` fields) to match the format produced by `vault_index_parser.lua`'s `extract_links()` (lines 276-295, which uses `make_link_entry()` to construct each link). Tags include hierarchical parent segments as produced by `extract_tags()` (lines 200-227, which processes both frontmatter tags and body `#tag` patterns with interning via `intern_tag()`).

### Merge Strategy

After selective re-parsing, all chunks' `parsed_data` are merged into the flat entry fields:

```lua
function M.merge_chunk_data(chunks)
  local merged = {
    headings = {},
    block_ids = {},
    outlinks = {},
    tasks = {},
    inline_fields = {},
    tags = {},
  }
  for _, chunk in ipairs(chunks) do
    local pd = chunk.parsed_data
    if pd then
      vim.list_extend(merged.headings, pd.headings or {})
      vim.list_extend(merged.block_ids, pd.block_ids or {})
      vim.list_extend(merged.outlinks, pd.outlinks or {})
      vim.list_extend(merged.tasks, pd.tasks or {})
      -- inline_fields is a key-value table, not an array
      for k, v in pairs(pd.inline_fields or {}) do
        merged.inline_fields[k] = v
      end
      vim.list_extend(merged.tags, pd.tags or {})
    end
  end
  return merged
end
```

**Note**: `inline_fields` uses key-value merge (not `vim.list_extend`) because the parser's `extract_inline_fields()` (lines 427-447) stores inline fields as `{key = value}` tables, not arrays.

## Configuration

```lua
-- In config.lua, under M.index (lines 340-388, alongside existing options):
M.index = {
  -- ... existing options (current state) ...
  skip_dirs = { ".obsidian", ".git", ".trash", ".vault-index", "node_modules" }, -- lines 342-348
  batch_size = 20,              -- line 351
  persist_debounce_ms = 5000,   -- line 354
  persist_min_interval_ms = 10000, -- line 357
  watch = true,                 -- line 360
  watch_debounce_ms = 500,      -- line 363
  warn_collisions = true,       -- line 367
  show_progress = true,         -- line 370
  progress_threshold = 50,      -- line 374
  collision_notify_ms = 5000,   -- line 377
  use_snapshots = true,         -- line 383
  max_waiters = 50,             -- line 387

  -- Chunking options (new, to be added after line 387)
  chunking_enabled = true,       -- Enable/disable chunk-based incremental parsing
  min_chunk_lines = 20,          -- Only chunk files with more lines than this threshold
  fallback_threshold = 0.5,      -- If >50% of chunks changed, fall back to full re-parse
}
```

- `chunking_enabled`: Master toggle. When false, the parser behaves exactly as before (full single-pass). Useful for debugging or if chunking introduces edge cases.
- `min_chunk_lines`: Files shorter than this are not worth chunking — the overhead of splitting, hashing, and merging exceeds the savings of skipping a few lines. Default 20 means files under 20 lines always get a full parse.
- `fallback_threshold`: If more than this fraction of chunks have changed digests, skip the selective approach and do a full re-parse. This handles the case where a heading insertion shifts all chunk boundaries, causing a cascade of digest mismatches where positional comparison breaks down.

## Expected Impact

For files over 100 lines (the typical case for daily notes, MOCs, project pages):

- **Typical edit** (modify text within one section): 1 chunk re-parsed out of 10-20 chunks. ~5-10% of file parsed instead of 100%.
- **Add a task to a section**: 1 chunk re-parsed. Same 5-10% savings.
- **Add a new heading**: Chunk count changes, triggers full re-parse (fallback). Same cost as current behavior — no regression.
- **Frontmatter-only edit** (add a tag): Only the frontmatter chunk re-parsed. For a 2000-line file, this is <1% of content.

Estimated savings on a 500-file vault with average file size of 200 lines:
- Current: ~100,000 lines parsed per incremental index cycle (assuming 50% of files changed)
- With chunking: ~10,000 lines parsed (assuming typical edits touch 1 chunk per file)
- **~10x reduction** in parse work for typical editing sessions

The savings compound with existing optimizations: structural sharing (reuse unchanged sub-tables via `sharing.share_unchanged()` at `vault_index_build.lua:112`), string interning (dedup tags/keys via four pools in `vault_index_parser.lua:21-26`), tag array interning (`sharing.intern_array()` at `vault_index_build.lua:117`), and adaptive batch sizing (`TARGET_MS = 16` at `vault_index_build.lua:14`, with dynamic batch resizing via `compute_batch_size()` at lines 22-27 clamped to `[MIN_BATCH=5, base*4]`) all still apply to the chunks that do get re-parsed.

## Risks

### Cross-Chunk References
Block IDs defined in one chunk may be referenced by outlinks or embeds in another chunk. The merge step handles this correctly since all chunks' parsed_data are combined. However, if a block ID is deleted from chunk A, we must ensure it is removed from the merged result even if chunk B (which references it) is unchanged. The merge-from-scratch approach (rebuild merged data from all chunks' parsed_data on every cycle) handles this naturally.

### Chunk Boundary Edge Cases
- **Heading inside a code block**: The chunk splitter tracks code fence state (`in_code_fence` flag toggled on `^```" lines) to avoid treating `# comment` inside a fenced code block as a heading boundary. This is implemented in the algorithm above.
- **YAML frontmatter edge cases**: Files with `---` used as horizontal rules (not frontmatter) could cause incorrect chunking. Mitigated by only treating `---` on line 1 as frontmatter start (matching the existing behavior of `vault_index_parser.lua`'s `split_frontmatter()` at lines 117-132).
- **Very long sections**: A single heading section with 5000 lines produces one large chunk, defeating the purpose. Consider a secondary split point (e.g., every 500 lines within a section) for extreme cases. Zed handles this with its 8KB max chunk size, but for our line-based approach a line count threshold is more natural.

### Storage Overhead
Each chunk adds ~80 bytes of metadata (start_line, end_line, 64-char digest hex string) to the persisted index. For a 500-file vault averaging 10 chunks per file, this is ~400KB additional storage. Acceptable given index.json is already typically 1-5MB. The `_chunks` field is included in WAL entries (`changes.jsonl`) as well, but WAL entries are transient and truncated after full persist.

### Schema Version Bump
Adding `_chunks` to the persisted entry requires bumping `SCHEMA_VERSION` from 5 to 6 (currently defined at `vault_index.lua:23`). The `load()` function (lines 800-899) validates the schema version at line 820 (`if data.version ~= SCHEMA_VERSION then`); files with version < 6 will trigger a full rebuild on first load (existing behavior — returns `false, "schema version mismatch"` at line 822). This is a one-time cost per vault.

### Interaction with Existing Optimizations
- **Structural sharing** (`structural_sharing.lua:81-181`, called from `vault_index_build.lua:109-113`): Still applies — unchanged chunks reuse their `parsed_data` tables directly; `sharing.share_unchanged(old, entry)` then compares the merged entry against the old entry for additional sub-table reuse across 8 field categories (simple arrays: tags, aliases; flat dictionaries: frontmatter, inline_fields; structured arrays with key functions: headings, block_ids, outlinks, tasks).
- **String interning** (`vault_index_parser.lua:21-26`, four pools: tags=500, fm_keys=200, fm_values=2000, lowercase=5000): Applies to chunks that are re-parsed via `intern()`, `intern_key()`, `intern_tag()`, `intern_lower()` helpers. Cached chunk data already contains interned strings from when they were originally parsed.
- **Tag interning** (`vault_index_build.lua:116-118`, using `sharing.intern_array()` from `structural_sharing.lua:209-228`): Applies to the merged tags array after chunk merge. Content-addressed deduplication via `table.concat(tbl, "\0")` hash key.
- **Metatable lazy fields** (`vault_index.lua:36-87` via `make_entry_mt()`): Unaffected — applied to the merged entry, not to chunks. Seven lazy fields: `abs_path`, `basename`, `basename_lower`, `folder`, `tag_set`, `heading_slugs`, `block_id_set`.
- **WAL** (`vault_index.lua:906-931`, `_persist_delta()`): Chunk data is included in WAL "set" operations since it's part of the entry. WAL entries are stripped of derived fields (via `strip_derived()` at lines 772-784) but `_chunks` is not a derived field.

### Second Call Site: update_files_batch()
`vault_index_build.lua` has a second `parse_file()` call site at line 232 in `update_files_batch()` (function defined at lines 205-310, used for single-file or small-batch updates outside the main `build_async()` coroutine). This function also applies `_apply_entry_mt()` at line 234, structural sharing (lines 236-238) and tag interning (lines 240-242), and directly updates `index.files[rel_path]` at line 246. The chunking optimization must be applied here as well to avoid inconsistent behavior between full rebuilds and incremental updates.

### Correctness Validation
During initial rollout, run both paths (chunked parse and full parse) and compare results. Log any discrepancies via `vault_log.scope("chunker")`. This can be gated behind a `config.index.chunking_validate` flag (default false, enable during development).
