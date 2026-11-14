-- vault_index_build.lua — Async build and batch update for vault index
-- Complex async/coroutine logic isolated from core indexing.

local B = {}

local parser = require("andrew.vault.vault_index_parser")
local chunker = require("andrew.vault.vault_index_chunker")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local coalescer = require("andrew.vault.request_coalescer")
local pat = require("andrew.vault.patterns")
local sharing = require("andrew.vault.structural_sharing")
local log = require("andrew.vault.vault_log").scope("index.build")
local crc32 = require("andrew.vault.vault_crc32")

-- ---------------------------------------------------------------------------
-- File-level content hashing (CRC32 / SHA-256)
-- ---------------------------------------------------------------------------

local function compute_sha256(data)
  return vim.fn.sha256(data)
end

local hash_functions = {
  crc32 = crc32.crc32,
  sha256 = compute_sha256,
}

--- Compute content hash using the configured algorithm.
---@param data string Raw file content (already line-ending-normalized)
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

-- Dedicated pool for index rebuilds (config applied via coalescer.configure() in init.lua)
local index_pool = coalescer.new({ name = "index_rebuild" })

-- Adaptive batch sizing: target ~16ms per batch for smooth UI.
local TARGET_MS = 16
local MIN_BATCH = 5

--- Apply structural sharing and tag interning to a parsed entry.
---@param index VaultIndex
---@param entry table Parsed entry to optimize
---@param old_entry table|nil Previous entry for sharing (nil = cold start or new file)
---@param is_cold_start boolean Whether this is the initial full build
local function apply_sharing(index, entry, old_entry, is_cold_start)
  if config.sharing.enable and not is_cold_start and old_entry then
    sharing.share_unchanged(old_entry, entry)
  end
  if config.sharing.enable and index._tag_intern then
    entry.tags = sharing.intern_array(index._tag_intern, entry.tags)
  end
end

--- Compute next batch size based on measured elapsed time.
---@param elapsed_ns number  Time taken for the previous batch (nanoseconds)
---@param files_processed number  Files parsed in the previous batch
---@param base number  Configured base batch size (also determines max = base * 4)
---@return number
local function compute_batch_size(elapsed_ns, files_processed, base)
  if elapsed_ns <= 0 or files_processed <= 0 then return base end
  local ms_per_file = elapsed_ns / (files_processed * 1e6)
  local adaptive = math.floor(TARGET_MS / ms_per_file)
  return math.max(MIN_BATCH, math.min(adaptive, base * 4))
end

--- Re-apply a line delta to an unchanged chunk's cached parsed_data.
--- Only headings/block_ids/tasks carry .line numbers; outlinks/inline_fields/tags
--- have none, so they are reused by reference. A fresh copy is produced (rather
--- than mutating the cached pd) so the cached chunk keeps its original absolute
--- lines for the NEXT diff. The result is byte-identical to re-parsing the chunk
--- at its new position (parse_chunk offsets by start_line-1).
---@param pd table Cached parsed_data
---@param delta number new_chunk.start_line - cached_chunk.start_line
---@return table shifted parsed_data
local function offset_parsed_data(pd, delta)
  local function shift(arr)
    local out = {}
    for i, item in ipairs(arr) do
      local copy = {}
      for k, v in pairs(item) do copy[k] = v end
      copy.line = item.line + delta
      out[i] = copy
    end
    return out
  end
  return {
    headings = shift(pd.headings or {}),
    block_ids = shift(pd.block_ids or {}),
    tasks = shift(pd.tasks or {}),
    outlinks = pd.outlinks,
    inline_fields = pd.inline_fields,
    tags = pd.tags,
  }
end

--- Compute digests and parse parsed_data for each chunk from its own lines.
--- Every chunk is parsed from its in-memory lines (no disk re-read); this is
--- cheap (string ops over already-split lines) and removes the need to persist
--- parsed_data, which verbatim duplicates the entry's merged top-level fields.
--- When changed_set is supplied (partial update), unchanged chunks reuse the
--- prior entry's cached parsed_data instead of re-parsing: shared by reference
--- when the position is identical, or line-shifted when the chunk moved but its
--- digest is unchanged. changed_set == nil means "parse every chunk" (cold build
--- and fallback paths). Strips raw lines from chunks after processing.
---@param chunks table[] Chunks from chunk_by_headings (with .lines)
---@param has_fm boolean Whether the file has frontmatter (chunk 1 is FM)
---@param fm_fields table|nil Parsed frontmatter fields (needed so an FM chunk's YAML isn't mis-parsed as body)
---@param cached_chunks table[]|nil Prior entry's chunks (positionally aligned; carry parsed_data)
---@param changed_set table<integer,boolean>|nil Set of 1-indexed changed chunks (nil = parse all)
local function process_chunks(chunks, has_fm, fm_fields, cached_chunks, changed_set)
  for i, chunk in ipairs(chunks) do
    if not chunk.digest then
      chunk.digest = chunker.chunk_digest(chunk.lines)
    end
    local is_fm = (i == 1 and has_fm)
    local cached = cached_chunks and cached_chunks[i]
    -- Reuse cached parsed_data for an unchanged chunk whose digest still matches.
    -- Requires cached.parsed_data to exist (loaded-from-disk chunks have none, so
    -- they fall through to a full parse — see strip_derived in vault_index.lua).
    if changed_set and not changed_set[i]
      and cached and cached.parsed_data and cached.digest == chunk.digest then
      if cached.start_line == chunk.start_line then
        chunk.parsed_data = cached.parsed_data
      else
        chunk.parsed_data = offset_parsed_data(
          cached.parsed_data, chunk.start_line - cached.start_line
        )
      end
    else
      chunk.parsed_data = parser.parse_chunk(
        chunk.lines, chunk.start_line, is_fm and fm_fields or nil
      )
    end
    chunk.lines = nil
  end
end

--- Warm a loaded entry's per-chunk parsed_data in the background.
--- Post-load entries carry only slim chunks ({start_line, end_line, digest}, see
--- strip_derived); without parsed_data the reuse guard in process_chunks misses,
--- so the file's FIRST incremental update re-parses ALL chunks instead of only
--- the touched one(s). This pre-derives parsed_data from the on-disk chunk lines
--- so that first save hits the fast reuse path. Pure-additive: only attaches
--- parsed_data onto the live chunks (start_line/end_line/digest untouched), so a
--- race with a real update can at worst waste a parse, never corrupt the entry.
--- Reads from DISK (not the buffer) so it is safe off the open path; an alignment
--- guard skips warming entirely if the file diverged from the loaded chunks
--- (the next update_file then does the correct diff). Idempotent: a no-op once
--- parsed_data is present (the live/post-update state).
---@param index VaultIndex
---@param abs_path string
function B.warm_chunk_cache(index, abs_path)
  if not config.index.chunking_enabled then return end

  local rel_path = index:_rel_path(abs_path)
  if not rel_path or not rel_path:match(pat.MD_EXTENSION) then return end

  local entry = index.files[rel_path]
  if not entry or not entry._chunks or #entry._chunks <= 1 then return end

  -- Already warmed (live entry after a real update) — nothing to do.
  if entry._chunks[1].parsed_data ~= nil then return end

  local content = parser.read_file(abs_path)
  if not content then return end

  local lines = vim.split(content, "\n", { plain = true })
  if #lines < config.index.min_chunk_lines then return end

  local new_chunks, has_fm = chunker.chunk_by_headings(lines)
  if #new_chunks <= 1 then return end

  for _, chunk in ipairs(new_chunks) do
    chunk.digest = chunker.chunk_digest(chunk.lines)
  end

  -- Safety guard: only warm when the file on disk still matches the loaded
  -- chunks (same count AND positionally-aligned digests). If they diverge the
  -- file changed since persist/load, so attaching parsed_data keyed to new
  -- digests onto the old slim chunks would be inconsistent — skip and let the
  -- next real update_file diff and re-parse correctly.
  if #new_chunks ~= #entry._chunks then return end
  for i = 1, #new_chunks do
    if new_chunks[i].digest ~= entry._chunks[i].digest then return end
  end

  -- Parse every chunk fresh (changed_set=nil) — the exact "parse everything"
  -- path a cold parse_file_chunked uses, so the result is byte-identical.
  process_chunks(new_chunks, has_fm, entry.frontmatter, nil, nil)
  for i = 1, #new_chunks do
    entry._chunks[i].parsed_data = new_chunks[i].parsed_data
  end
end

--- Build entry from old_entry with updated stat fields and selective overrides.
--- Delegates straight to make_entry, which inherits any unset named field from
--- old_entry — so there is no intermediate shallow copy, and the lazy
--- metatable-derived keys (abs_path, tag_set, …) on old_entry are never
--- forwarded. The overrides table doubles as make_entry's `fields` arg; we
--- write the stat updates into it (callers at the chunk paths pass a fresh
--- literal; the no-change path passes nil, so allocate one).
---@param old_entry table Previous entry to inherit unset fields from
---@param stat table File stat
---@param overrides table|nil Fields to override (any key in make_entry's fields table)
---@return VaultIndexEntry
local function entry_from_old(old_entry, stat, overrides)
  overrides = overrides or {}
  overrides.mtime = stat.mtime.sec
  overrides.size = stat.size
  return parser.make_entry(overrides, old_entry)
end

--- Validate a chunked-parse entry against a full parse of the same content.
--- Compares array fields by count and key-value fields by key set.
--- Logs discrepancies via the "chunker" log scope. Dev-only (high overhead).
---@param entry VaultIndexEntry Chunked-parse result
---@param content string Normalized file content
---@param rel_path string
---@param stat table
local validate_log = require("andrew.vault.vault_log").scope("chunker")
local function validate_chunked_entry(entry, content, rel_path, stat)
  local full = parser.parse_content(content, rel_path, stat)
  if not full then
    validate_log.warn("validation: full parse returned nil for %s", rel_path)
    return
  end

  local array_fields = { "tags", "headings", "block_ids", "outlinks", "tasks" }
  for _, field in ipairs(array_fields) do
    local ce = entry[field] or {}
    local fe = full[field] or {}
    if #ce ~= #fe then
      validate_log.warn(
        "validation mismatch [%s] %s: chunked=%d full=%d",
        rel_path, field, #ce, #fe
      )
    end
  end

  -- Compare inline_fields keys
  local ci = entry.inline_fields or {}
  local fi = full.inline_fields or {}
  for k in pairs(fi) do
    if ci[k] == nil then
      validate_log.warn("validation mismatch [%s] inline_fields: missing key %q", rel_path, k)
    end
  end
  for k in pairs(ci) do
    if fi[k] == nil then
      validate_log.warn("validation mismatch [%s] inline_fields: extra key %q", rel_path, k)
    end
  end
end

--- Parse a file using chunk-aware incremental parsing.
--- Reads the file, splits into heading-based chunks, computes digests,
--- diffs against cached chunks from old_entry, re-parses only changed chunks,
--- then merges results into a complete entry.
--- Falls back to full parse for small files or when chunking is disabled.
---@param abs_path string
---@param rel_path string
---@param stat table
---@param old_entry table|nil Previous index entry (for cached chunks)
---@param pre_content string|nil Pre-read content from _detect_changes hash check
---@param pre_hash string|nil Pre-computed content hash from _detect_changes
---@return VaultIndexEntry|nil entry
local function parse_file_chunked(abs_path, rel_path, stat, old_entry, pre_content, pre_hash)
  local hash_enabled = config.index.content_hash_enabled

  -- Guard: chunking disabled or not configured
  if not config.index.chunking_enabled then
    local content = pre_content or parser.read_file(abs_path)
    if not content then return nil end
    local entry = parser.parse_content(content, rel_path, stat)
    if entry and hash_enabled then
      entry.content_hash = pre_hash or compute_hash(content)
    end
    return entry
  end

  -- Read file content once — all paths below reuse this.
  local content = pre_content or parser.read_file(abs_path)
  if not content then return nil end

  -- Compute file-level content hash (reuse pre-computed if available)
  local content_hash = nil
  if hash_enabled then
    content_hash = pre_hash or compute_hash(content)
  end

  local lines = vim.split(content, "\n", { plain = true })

  -- No old entry means first parse — no cache to diff against.
  -- Do a full parse and build the chunk cache for next time.
  if not old_entry or not old_entry._chunks then
    local entry = parser.parse_content(content, rel_path, stat)
    if entry then
      entry.content_hash = content_hash
      if #lines >= config.index.min_chunk_lines then
        local new_chunks, has_fm = chunker.chunk_by_headings(lines)
        if #new_chunks > 1 then
          process_chunks(new_chunks, has_fm, entry.frontmatter)
          entry._chunks = new_chunks
        end
      end
    end
    return entry
  end

  -- Small files: not worth chunking
  if #lines < config.index.min_chunk_lines then
    local entry = parser.parse_content(content, rel_path, stat)
    if entry then entry.content_hash = content_hash end
    return entry
  end

  -- Split into chunks and compute digests
  local new_chunks, has_fm = chunker.chunk_by_headings(lines)
  if #new_chunks <= 1 then
    local entry = parser.parse_content(content, rel_path, stat)
    if entry then entry.content_hash = content_hash end
    return entry
  end

  for _, chunk in ipairs(new_chunks) do
    chunk.digest = chunker.chunk_digest(chunk.lines)
  end

  -- Diff against cache
  local cached_chunks = old_entry._chunks
  local changed_indices = chunker.diff_chunks(new_chunks, cached_chunks)

  -- Set form of changed_indices, used by process_chunks to skip re-parsing
  -- unchanged chunks (reusing their cached parsed_data instead).
  local changed_set = {}
  for _, idx in ipairs(changed_indices) do
    changed_set[idx] = true
  end

  -- Nothing changed: create new entry with updated mtime/size,
  -- reusing all sub-tables from old_entry (avoids mutating the live index entry).
  if #changed_indices == 0 then
    local entry = entry_from_old(old_entry, stat)
    entry.content_hash = content_hash
    if config.index.chunking_validate then
      validate_chunked_entry(entry, content, rel_path, stat)
    end
    return entry
  end

  -- Fallback: too many chunks changed — do full parse but build cache
  if chunker.should_fallback(changed_indices, #new_chunks, config.index.fallback_threshold) then
    local entry = parser.parse_content(content, rel_path, stat)
    if entry then
      entry.content_hash = content_hash
      process_chunks(new_chunks, has_fm, entry.frontmatter)
      entry._chunks = new_chunks
    end
    return entry
  end

  -- Whether the frontmatter chunk (always chunk 1) is among the changed set.
  -- process_chunks re-parses only changed chunks (reusing cached parsed_data for
  -- the rest); this only selects between re-parsing frontmatter vs reusing the
  -- old entry's frontmatter.
  local fm_changed = false
  if has_fm then
    for _, idx in ipairs(changed_indices) do
      if idx == 1 then fm_changed = true break end
    end
  end

  local entry
  if fm_changed then
    -- FM chunk changed: parse only frontmatter (not entire file body).
    -- Body-derived fields come from chunk merge, so full parse is wasteful.
    local fm_fields, aliases, created_ts, modified_ts =
      parser.parse_frontmatter_only(content)

    process_chunks(new_chunks, has_fm, fm_fields, cached_chunks, changed_set)

    local merged = chunker.merge_chunk_data(new_chunks)
    local rel_stem, rel_stem_lower, day, day_ts = parser.compute_file_identity(rel_path)

    entry = entry_from_old(old_entry, stat, {
      rel_path = rel_path,
      rel_stem = rel_stem,
      rel_stem_lower = rel_stem_lower,
      ctime = stat.birthtime and stat.birthtime.sec or nil,
      frontmatter = fm_fields,
      aliases = aliases,
      tags = merged.tags,
      headings = merged.headings,
      block_ids = merged.block_ids,
      outlinks = merged.outlinks,
      tasks = merged.tasks,
      inline_fields = merged.inline_fields,
      day = day,
      created_ts = created_ts,
      modified_ts = modified_ts,
      day_ts = day_ts,
      _chunks = new_chunks,
    })
  else
    -- FM unchanged (or no FM): reuse old frontmatter and file-level fields.
    -- Pass old_entry.frontmatter so an unchanged FM chunk re-parses with its
    -- frontmatter fields (else parse_chunk treats the YAML as body, mis-extracting tags).
    process_chunks(new_chunks, has_fm, old_entry.frontmatter, cached_chunks, changed_set)

    local merged = chunker.merge_chunk_data(new_chunks)

    entry = entry_from_old(old_entry, stat, {
      tags = merged.tags,
      headings = merged.headings,
      block_ids = merged.block_ids,
      outlinks = merged.outlinks,
      tasks = merged.tasks,
      inline_fields = merged.inline_fields,
      _chunks = new_chunks,
    })
  end

  entry.content_hash = content_hash

  if config.index.chunking_validate then
    validate_chunked_entry(entry, content, rel_path, stat)
  end

  return entry
end

--- Async incremental build (normal startup path).
--- Runs change detection, parses changed files in batches via coroutine,
--- then rebuilds derived indexes. Mutations are staged in local tables
--- during batch processing and applied atomically after all batches
--- complete, eliminating mid-build inconsistency between the files table
--- and derived indexes.
---@param index VaultIndex
---@param callback? function
function B.build_async(index, callback)
  index_pool:request("index_rebuild", function(resolve, reject)
    local stop = require("andrew.vault.memory_profiler").start_timer("index.build_async")
    -- The _building flag is retained for update_files_batch() guard
    index._building = true
    parser.reset_intern_pool()

    local start_time = vim.uv.hrtime()
    local is_cold_start = not index._ready

    local yield_iter = require("andrew.vault.yield_iter")
    yield_iter.run_async(function()
      local changed, deleted = index:_detect_changes()

      local total = #changed
      local total_deleted = #deleted
      local show_progress = config.index.show_progress
        and (total >= config.index.progress_threshold or is_cold_start)
      local batch_notify_interval = 5 -- notify every N batches

    -- Initial notification
    if show_progress and total > 0 then
      local verb = is_cold_start and "Indexing vault" or "Updating index"
      vim.schedule(function()
        notify.progress(
          string.format("%s [0/%d]...", verb, total),
          vim.log.levels.INFO,
          "vault_index_progress"
        )
      end)
    end

    -- Capture old entries before overwriting (needed for incremental name index)
    local old_entries = {}
    if not is_cold_start then
      for _, file in ipairs(changed) do
        old_entries[file.rel_path] = index.files[file.rel_path]
      end
      for _, rel_path in ipairs(deleted) do
        old_entries[rel_path] = index.files[rel_path]
      end
    end

    -- Collect deleted rel_paths (deferred until _apply_staged).
    local deleted_rel_paths = {}
    for _, rel_path in ipairs(deleted) do
      if index.files[rel_path] ~= nil then
        deleted_rel_paths[#deleted_rel_paths + 1] = rel_path
      end
    end

    -- Parse into a local staging table instead of mutating index.files
    -- directly. Readers see the previous consistent state until
    -- _apply_staged() swaps everything in one synchronous pass.
    local staged = {}

    -- Process changed files in adaptive batches (targeting ~16ms per batch)
    local processed = 0
    local batch_count = 0
    local changed_rel_paths = {}
    local base_batch = config.index.batch_size
    local current_batch_size = base_batch
    while processed < total do
      local batch_start_ns = vim.uv.hrtime()
      local batch_end = math.min(processed + current_batch_size, total)
      local files_this_batch = 0
      for j = processed + 1, batch_end do
        local file = changed[j]
        local old_ent = old_entries[file.rel_path]
        local entry = parse_file_chunked(
          file.abs_path, file.rel_path, file.stat, old_ent,
          file.content, file.content_hash
        )
        if entry then
          index:_apply_entry_mt(entry)
          apply_sharing(index, entry, old_ent, is_cold_start)
          staged[file.rel_path] = entry
          changed_rel_paths[#changed_rel_paths + 1] = file.rel_path
        end
        files_this_batch = files_this_batch + 1
      end
      processed = processed + files_this_batch
      batch_count = batch_count + 1

      -- Adapt batch size based on measured time
      local elapsed_ns = vim.uv.hrtime() - batch_start_ns
      current_batch_size = compute_batch_size(elapsed_ns, files_this_batch, base_batch)

      -- Periodic progress notification
      if show_progress and total > 0 and batch_count % batch_notify_interval == 0 then
        local pct = math.floor(processed / total * 100)
        local verb = is_cold_start and "Indexing" or "Updating index"
        local p = processed -- capture for closure
        vim.schedule(function()
          notify.progress(
            string.format("%s [%d/%d] %d%%", verb, p, total, pct),
            vim.log.levels.INFO,
            "vault_index_progress"
          )
        end)
      end

      coroutine.yield()
    end

    -- Atomic apply: all mutations + derived index rebuilds in one
    -- synchronous pass (no yield), so the event loop never sees
    -- partial state.
    index:_apply_staged(staged, deleted_rel_paths, old_entries,
                        changed_rel_paths, is_cold_start)

    -- Completion notification
    if config.index.show_progress and (total > 0 or total_deleted > 0 or is_cold_start) then
      local elapsed = (vim.uv.hrtime() - start_time) / 1e9
      local msg
      if is_cold_start then
        msg = string.format(
          "Index ready (%d files, %.1fs)",
          index:file_count(), elapsed
        )
      elseif total > 0 or total_deleted > 0 then
        local parts = {}
        if total > 0 then
          parts[#parts + 1] = total .. " updated"
        end
        if total_deleted > 0 then
          parts[#parts + 1] = total_deleted .. " removed"
        end
        msg = string.format(
          "Index updated (%s, %.1fs)",
          table.concat(parts, ", "), elapsed
        )
      end
      if msg then
        vim.schedule(function()
          notify.progress(msg, vim.log.levels.INFO, "vault_index_progress")
        end)
      end
    end

    stop()
    resolve(true)
    end, {
      on_error = function(err)
        stop()
        index._building = false
        reject(err)
      end,
    })
  end, function(_, err)
    if callback then callback() end
    if err then
      notify.error("index error: " .. err)
    end
  end)
end

--- Batch-update multiple files in the vault index.
--- More efficient than calling update_file() in a loop because derived indexes
--- (name index, inlinks) are rebuilt only once.
---@param index VaultIndex
---@param abs_paths string[]  Absolute paths to re-index
function B.update_files_batch(index, abs_paths)
  -- Skip incremental updates while a full build_async() is running.
  if index._building then return end

  local old_entries = {}
  local changed_rel_paths = {}
  local deleted_rel_paths = {}

  for _, abs_path in ipairs(abs_paths) do
    local rel_path = index:_rel_path(abs_path)
    if not rel_path then goto continue end
    if not rel_path:match(pat.MD_EXTENSION) then goto continue end

    local old_entry = index.files[rel_path]
    if old_entry then
      old_entries[rel_path] = old_entry
    end

    local stat = vim.uv.fs_stat(abs_path)
    if not stat then
      -- File was deleted
      if old_entry then
        index.files[rel_path] = nil
        index._file_count = index._file_count - 1
        deleted_rel_paths[#deleted_rel_paths + 1] = rel_path
      end
    else
      local entry = parse_file_chunked(abs_path, rel_path, stat, old_entry)
      if entry then
        index:_apply_entry_mt(entry)
        apply_sharing(index, entry, old_entry, false)
        if index.files[rel_path] == nil then
          index._file_count = index._file_count + 1
        end
        index.files[rel_path] = entry
        changed_rel_paths[#changed_rel_paths + 1] = rel_path
      end
    end

    ::continue::
  end

  if #changed_rel_paths > 0 or #deleted_rel_paths > 0 then
    local vi_mod = package.loaded["andrew.vault.vault_index"]
    index:_update_name_index_incremental(old_entries, changed_rel_paths, deleted_rel_paths)
    -- Only sources whose outlink SET actually changed contribute new inlink
    -- edges; prose-only edits leave the outlink set byte-identical and are
    -- skipped to avoid re-resolving every outlink on every save.
    local outlinks_changed = nil
    if vi_mod and vi_mod._build_outlinks_changed_set then
      outlinks_changed = vi_mod._build_outlinks_changed_set(old_entries, index.files, changed_rel_paths)
    end
    index:_recompute_inlinks_incremental(changed_rel_paths, deleted_rel_paths, outlinks_changed)
    index:_update_precomputed_sets_incremental(old_entries, changed_rel_paths, deleted_rel_paths)
    -- Keep the summary tree fresh so all_tags()/tags_with_counts()/
    -- all_frontmatter_keys()/all_inline_field_keys() reflect this save without
    -- waiting for the next full build. apply_delta is O(depth * fields-changed)
    -- — no sibling sweep. Run it unconditionally for changed files: inline_field
    -- keys feed the tree but aren't tracked by the diff machinery, so a
    -- diff-based skip-guard would reintroduce staleness for inline keys.
    for _, rp in ipairs(changed_rel_paths) do
      index._summary_tree:apply_delta(rp, old_entries[rp], index.files[rp])
    end
    for _, rp in ipairs(deleted_rel_paths) do
      index._summary_tree:apply_delta(rp, old_entries[rp], nil)
    end
    index:_schedule_persist(changed_rel_paths, deleted_rel_paths)

    -- Separate added (new) vs modified paths for tiered invalidation
    local added = {}
    local modified = {}
    for _, rp in ipairs(changed_rel_paths) do
      if old_entries[rp] then
        modified[#modified + 1] = rp
      else
        added[#added + 1] = rp
      end
    end

    -- Compute change_types by diffing old vs new entries for interest-based
    -- filtering. Skip the diff entirely when no subscriber declares interests —
    -- nil change_types is treated as "all changed" by interests_overlap().
    local change_types = nil
    if vi_mod and vi_mod._compute_change_types and index:_has_interest_subscribers() then
      change_types = vi_mod._compute_change_types(old_entries, index.files, modified, added, deleted_rel_paths)
    end

    -- Pass relative paths (normalized at source) for consistent subscriber handling
    local ctx = {
      changed_paths = #modified > 0 and modified or nil,
      deleted_paths = #deleted_rel_paths > 0 and deleted_rel_paths or nil,
      added_paths = #added > 0 and added or nil,
      change_types = change_types,
      old_entries = old_entries,
    }
    index:_notify_update(ctx)
  end
end

B.compute_hash = compute_hash

return B
