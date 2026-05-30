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
local bit = require("bit")

-- ---------------------------------------------------------------------------
-- File-level content hashing (CRC32 / SHA-256)
-- ---------------------------------------------------------------------------

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

--- Compute digests and parsed_data for each chunk, reusing cached data where available.
--- When cached_chunks and changed_set are provided, only re-parses changed chunks.
--- Strips raw lines from chunks after processing.
---@param chunks table[] Chunks from chunk_by_headings (with .lines)
---@param has_fm boolean Whether the file has frontmatter (chunk 1 is FM)
---@param fm_fields table|nil Parsed frontmatter fields
---@param cached_chunks table[]|nil Previous chunks with .parsed_data
---@param changed_set table<integer, boolean>|nil Set of changed chunk indices (nil = all changed)
local function process_chunks(chunks, has_fm, fm_fields, cached_chunks, changed_set)
  for i, chunk in ipairs(chunks) do
    if not chunk.digest then
      chunk.digest = chunker.chunk_digest(chunk.lines)
    end
    if not changed_set or changed_set[i] then
      local is_fm = (i == 1 and has_fm)
      chunk.parsed_data = parser.parse_chunk(
        chunk.lines, chunk.start_line, is_fm and fm_fields or nil
      )
    else
      chunk.parsed_data = cached_chunks[i].parsed_data
    end
    chunk.lines = nil
  end
end

--- Build entry by copying old_entry fields and applying selective overrides.
--- Shallow-copies raw fields from old_entry (skipping metatable-derived values),
--- updates stat fields, applies overrides, then delegates to make_entry which
--- is the single source of truth for the entry shape.
---@param old_entry table Previous entry to copy fields from
---@param stat table File stat
---@param overrides table|nil Fields to override (any key in make_entry's fields table)
---@return VaultIndexEntry
local function entry_from_old(old_entry, stat, overrides)
  local fields = {}
  for k, v in pairs(old_entry) do
    fields[k] = v
  end
  fields.mtime = stat.mtime.sec
  fields.size = stat.size
  if overrides then
    for k, v in pairs(overrides) do
      fields[k] = v
    end
  end
  return parser.make_entry(fields)
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

  -- Build changed set for O(1) lookup
  local changed_set = {}
  for _, idx in ipairs(changed_indices) do
    changed_set[idx] = true
  end

  local fm_changed = (has_fm and changed_set[1])

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
    -- FM unchanged (or no FM): reuse old frontmatter and file-level fields
    process_chunks(new_chunks, has_fm, nil, cached_chunks, changed_set)

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
    index:_update_name_index_incremental(old_entries, changed_rel_paths, deleted_rel_paths)
    index:_recompute_inlinks_incremental(changed_rel_paths, deleted_rel_paths)
    index:_update_precomputed_sets_incremental(old_entries, changed_rel_paths, deleted_rel_paths)
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

    -- Compute change_types by diffing old vs new entries for interest-based filtering
    local vi_mod = package.loaded["andrew.vault.vault_index"]
    local change_types = vi_mod and vi_mod._compute_change_types
      and vi_mod._compute_change_types(old_entries, index.files, modified, added, deleted_rel_paths)
      or nil

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
