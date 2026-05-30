local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")
local date_utils = require("andrew.vault.date_utils")
local filter_utils = require("andrew.vault.filter_utils")
local vault_index = require("andrew.vault.vault_index")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")
local lru = require("andrew.vault.lru_cache")
local cleanup = require("andrew.vault.resource_cleanup")
local weighers = require("andrew.vault.cache_weighers")
local table_pool = require("andrew.vault.table_pool")
local render_arena = require("andrew.vault.render_arena")
local coalescer = require("andrew.vault.request_coalescer")

-- Dedicated pool for connection scoring (config applied via coalescer.configure() in init.lua)
local conn_pool = coalescer.new({ name = "connections" })

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

-- Forward declaration (defined after pool definitions below)
local release_cache_entry

local _cache_hits = 0
local _cache_misses = 0
local _cache_evictions = 0

local _cache = lru.new_weighted({
  max_bytes = config.cache.connections_bytes,
  max_items = config.cache.connections_max,
  weigher = weighers.connections,
  on_evict = function(_key, entry)
    _cache_evictions = _cache_evictions + 1
    release_cache_entry(entry)
  end,
})

-- IDF is now served directly from vault_index._summary_tree (O(1) lookup).

-- Note data cache (build_note_data results)
-- NOTE: Manual generation tracking (not gen_cache) because prepare_compute()
-- does subscriber-based per-entry LRU removal for changed files only, rather
-- than full cache invalidation. gen_cache doesn't support incremental eviction.
local _note_data_cache = lru.new_weighted({
  max_bytes = config.cache.note_data_bytes,
  max_items = config.cache.note_data_max,
  weigher = weighers.note_data,
})  -- rel_path -> note_data
local _note_data_gen = 0      -- generation when cache was built

-- Subscriber-based change tracking (replaces full cache clear on generation change)
local _pending_changed = {}   -- rel_path -> true (files changed since last compute)
local _pending_full_clear = false  -- true when subscriber context was nil (full rebuild)

-- Object pools for scoring output tables (reduce GC pressure during burst scoring)
local _breakdown_pool = table_pool.new(config.pools.connection_breakdown, function(obj)
  obj.tags = 0
  obj.fm = 0
  obj.colink = 0
  obj.link = 0
  obj.temporal = 0
end)
table_pool.register("conn_breakdown", _breakdown_pool)

local _result_pool = table_pool.new(config.pools.connection_result, function(obj)
  obj.rel_path = nil
  obj.name = nil
  obj.name_lower = nil
  obj.rel_path_lower = nil
  obj.score = 0
  obj.reasons = nil
  obj.breakdown = nil
end)
table_pool.register("conn_result", _result_pool)

--- Release all pool objects from a connection cache entry's results.
--- Must be called before discarding a cache entry to prevent pool object leaks.
---@param entry table|nil Cache entry with .results array
function release_cache_entry(entry)
  if not entry or not entry.results then return end
  for i = 1, #entry.results do
    local item = entry.results[i]
    if item.breakdown then
      _breakdown_pool:release(item.breakdown)
    end
    _result_pool:release(item)
    entry.results[i] = nil
  end
end

-- Subscription handle (initialized after on_index_update is defined)
local _subscription
-- State anchor for weak_callback defense-in-depth: if the module is unloaded
-- (package.loaded cleared), this becomes unreachable and the vault_index
-- subscriber callback silently becomes a no-op on next GC cycle.
local _state_anchor = {}

-- Forward declaration for unsubscribe (defined after subscriber section)
local unsubscribe

--- Invalidate the entire connection cache.
function M.invalidate_cache()
  _cache:clear()  -- on_evict releases pool objects per entry
  _note_data_cache:clear()
  _note_data_gen = 0
  _pending_changed = {}
  _pending_full_clear = false
  -- Unsubscribe from old vault index (will re-subscribe on next setup/compute)
  unsubscribe()
end

-- ---------------------------------------------------------------------------
-- Index access
-- ---------------------------------------------------------------------------

--- Get the vault index and its generation.
---@return VaultIndex|nil, number generation
local function get_vault_index()
  local idx = vault_index.current()
  if not idx then return nil, 0 end
  return idx, idx._generation or 0
end

-- ---------------------------------------------------------------------------
-- Signal: Tag IDF (served from summary tree)
-- ---------------------------------------------------------------------------

--- Compute tag similarity score between two tag sets using IDF weighting.
---@param tags_a table<string, true>
---@param tags_b table<string, true>
---@param idf table<string, number>
---@param total number
---@param arena_scope? integer arena scope for ephemeral allocation
---@return number score
---@return string[] shared_tags list of shared tag names for display
local function score_tags(tags_a, tags_b, idf, total, arena_scope)
  local score = 0
  local shared = arena_scope and render_arena.alloc_table(arena_scope) or {}
  for tag in pairs(tags_a) do
    if tags_b[tag] then
      local df = idf[tag] or 1
      -- IDF: log(N / df), minimum 0.1 to avoid log(1)=0 for unique tags
      local tag_idf = math.log(total / df)
      if tag_idf < 0.1 then tag_idf = 0.1 end
      score = score + tag_idf
      shared[#shared + 1] = tag
    end
  end
  return score, shared
end

-- ---------------------------------------------------------------------------
-- Signal: Frontmatter field matching
-- ---------------------------------------------------------------------------

--- Fields to compare and their individual sub-weights (relative within the fm signal).
local FM_FIELDS = {
  { key = "type",    weight = 1.0 },
  { key = "project", weight = 1.5 },
  { key = "domain",  weight = 1.0 },
  { key = "status",  weight = 0.3 },
}

--- Extract comparable frontmatter values from a vault index entry.
---@param entry VaultIndexEntry
---@return table<string, string> key -> normalized string value
local function extract_fm_values(entry)
  local fm = entry.frontmatter
  if not fm then return {} end
  local vals = {}
  for _, field in ipairs(FM_FIELDS) do
    local v = fm[field.key]
    if v ~= nil then
      if type(v) == "string" then
        vals[field.key] = v:lower()
      else
        vals[field.key] = tostring(v):lower()
      end
    end
  end
  return vals
end

--- Score frontmatter field similarity.
---@param fm_a table<string, string>
---@param fm_b table<string, string>
---@param arena_scope? integer arena scope for ephemeral allocation
---@return number score
---@return string[] reasons
local function score_frontmatter(fm_a, fm_b, arena_scope)
  local score = 0
  local reasons = arena_scope and render_arena.alloc_table(arena_scope) or {}
  for _, field in ipairs(FM_FIELDS) do
    local va = fm_a[field.key]
    local vb = fm_b[field.key]
    if va and vb and va == vb then
      score = score + field.weight
      reasons[#reasons + 1] = field.key .. ": " .. va
    end
  end
  return score, reasons
end

-- ---------------------------------------------------------------------------
-- Signal: Co-occurrence (bibliographic coupling)
-- ---------------------------------------------------------------------------

--- Score based on shared outlink targets (notes both A and B link to).
---@param out_a table<string, true>
---@param out_b table<string, true>
---@param count_a number pre-computed size of out_a
---@param count_b number pre-computed size of out_b
---@return number score (0..1 normalized)
---@return number shared_count
local function score_colinks(out_a, out_b, count_a, count_b)
  local shared = 0
  for target in pairs(out_a) do
    if out_b[target] then
      shared = shared + 1
    end
  end
  if shared == 0 then
    return 0, 0
  end
  -- Normalize by the smaller outlink set to get a 0..1 ratio
  local min_size = math.min(count_a, count_b)
  if min_size == 0 then min_size = 1 end
  return shared / min_size, shared
end

-- ---------------------------------------------------------------------------
-- Signal: Direct link proximity
-- ---------------------------------------------------------------------------

--- Score direct and 2-hop link proximity.
---@param rel_a string source note rel_path
---@param neighbors_a table<string, true>
---@param rel_b string candidate note rel_path
---@param neighbors_b table<string, true>
---@param weights table connection weights config
---@return number score
---@return string|nil reason
local function score_link_proximity(rel_a, neighbors_a, rel_b, neighbors_b, weights)
  -- 1-hop: A directly links to B or B directly links to A
  if neighbors_a[rel_b] or neighbors_b[rel_a] then
    return weights.link_1hop, "1-hop link"
  end

  -- 2-hop: count shared neighbors (notes connected to both A and B)
  local shared = 0
  local max_2hop = weights.max_2hop_bridges or 5
  for n in pairs(neighbors_a) do
    if neighbors_b[n] then
      shared = shared + 1
    end
  end
  if shared > 0 then
    local capped = math.min(shared, max_2hop)
    local score = weights.link_2hop * (capped / max_2hop)
    return score, shared .. " 2-hop bridge" .. (shared > 1 and "s" or "")
  end

  return 0, nil
end

-- ---------------------------------------------------------------------------
-- Signal: Temporal proximity
-- ---------------------------------------------------------------------------

--- Convert a timestamp or Date object to epoch seconds.
---@param d number|table|nil timestamp number or Date object
---@return number epoch seconds
local function date_to_epoch(d)
  if not d then return 0 end
  if type(d) == "number" then return d end
  if type(d) == "table" and d.year then
    local ok, ts = pcall(os.time, {
      year = d.year,
      month = d.month or 1,
      day = d.day or 1,
      hour = d.hour or 12,
      min = d.min or 0,
      sec = d.sec or 0,
    })
    return ok and ts or 0
  end
  return 0
end

--- Score temporal proximity between two notes.
--- Decay: same day=1.0, <3d=0.7, <7d=0.4, <30d=0.2, else 0.
---@param ctime_a number epoch seconds
---@param mtime_a number epoch seconds
---@param ctime_b number epoch seconds
---@param mtime_b number epoch seconds
---@return number score (0..1)
local function score_temporal(ctime_a, mtime_a, ctime_b, mtime_b)
  if ctime_a == 0 or ctime_b == 0 then return 0 end
  local ctime_days = math.abs(ctime_a - ctime_b) / date_utils.SECS_PER_DAY
  local mtime_days = math.abs(mtime_a - mtime_b) / date_utils.SECS_PER_DAY
  -- Inline temporal decay for each delta
  local c_decay
  if ctime_days < 1 then c_decay = 1.0
  elseif ctime_days < 3 then c_decay = 0.7
  elseif ctime_days < 7 then c_decay = 0.4
  elseif ctime_days < 30 then c_decay = 0.2
  else c_decay = 0.0 end
  local m_decay
  if mtime_days < 1 then m_decay = 1.0
  elseif mtime_days < 3 then m_decay = 0.7
  elseif mtime_days < 7 then m_decay = 0.4
  elseif mtime_days < 30 then m_decay = 0.2
  else m_decay = 0.0 end
  return math.max(c_decay, m_decay)
end

-- ---------------------------------------------------------------------------
-- Precompute note data
-- ---------------------------------------------------------------------------

--- Build a ConnectionNoteData table for a vault index entry.
---@param entry VaultIndexEntry
---@param vi VaultIndex vault index instance (for inlinks lookup)
---@param resolve fun(link_path: string): string|nil memoized resolver
---@param prebuilt_tags? table pre-built tag set to avoid rebuilding
---@return ConnectionNoteData
local function build_note_data(entry, vi, resolve, prebuilt_tags)
  -- Reuse pre-built tag set: prefer explicit override, then lazy tag_set
  local tags = prebuilt_tags or entry.tag_set

  -- Build outlink target set (resolved rel_paths)
  local outlink_targets = {}
  local outlink_count = 0
  for _, link in ipairs(entry.outlinks or {}) do
    local target_rel = resolve(link.path or "")
    if target_rel then
      local key = target_rel:lower()
      if not outlink_targets[key] then
        outlink_targets[key] = true
        outlink_count = outlink_count + 1
      end
    end
  end

  -- Build inlink source set
  local inlink_sources = {}
  local inlinks = vi:get_inlinks(entry.rel_path)
  for _, link in ipairs(inlinks) do
    local lower = link.path_lower
    if lower ~= "" then
      local key = lower:match(pat.MD_EXTENSION) and lower or (lower .. ".md")
      inlink_sources[key] = true
    end
  end

  -- Neighbors = union of outlink targets and inlink sources
  local neighbors = {}
  for k in pairs(outlink_targets) do neighbors[k] = true end
  for k in pairs(inlink_sources) do neighbors[k] = true end

  -- Frontmatter values
  local fm_fields = extract_fm_values(entry)

  -- Timestamps
  local ctime = date_to_epoch(entry.ctime)
  local mtime = date_to_epoch(entry.mtime)

  local rel_path = entry.rel_path
  return {
    rel_path = rel_path,
    rel_path_lower = rel_path:lower(),
    name_lower = entry.basename_lower,
    tags = tags,
    outlink_targets = outlink_targets,
    outlink_count = outlink_count,
    inlink_sources = inlink_sources,
    neighbors = neighbors,
    fm_fields = fm_fields,
    ctime = ctime,
    mtime = mtime,
  }
end

--- Get or build cached note data for a vault index entry.
---@param entry VaultIndexEntry
---@param vi VaultIndex vault index instance (for inlinks lookup)
---@param resolve fun(link_path: string): string|nil memoized resolver
---@param prebuilt_tags? table pre-built tag set to avoid rebuilding
---@return ConnectionNoteData
local function get_note_data(entry, vi, resolve, prebuilt_tags)
  local rel = entry.rel_path
  local cached = _note_data_cache:get(rel)
  if cached then return cached end
  local data = build_note_data(entry, vi, resolve, prebuilt_tags)
  _note_data_cache:put(rel, data)
  return data
end

-- ---------------------------------------------------------------------------
-- Main scoring
-- ---------------------------------------------------------------------------

--- Get connection weights from config with defaults.
---@return table
local function get_weights()
  local defaults = {
    tags = 3.0,
    frontmatter = 2.0,
    colink = 2.5,
    link_1hop = 5.0,
    link_2hop = 2.0,
    temporal = 1.0,
    max_2hop_bridges = 5,
  }
  local cfg = config.connections.weights
  return vim.tbl_extend("keep", cfg, defaults)
end

-- ---------------------------------------------------------------------------
-- Top-K min-heap for scoring
-- ---------------------------------------------------------------------------

--- Create a fixed-size min-heap for tracking top-K scored items.
---@param k number maximum number of items to keep
---@return table heap object with insert, min_score, results methods
local function create_top_k(k, result_pool, breakdown_pool)
  local heap = {}
  local size = 0

  local function sift_down(i)
    while true do
      local smallest = i
      local l, r = 2 * i, 2 * i + 1
      if l <= size and heap[l].score < heap[smallest].score then smallest = l end
      if r <= size and heap[r].score < heap[smallest].score then smallest = r end
      if smallest == i then break end
      heap[i], heap[smallest] = heap[smallest], heap[i]
      i = smallest
    end
  end

  return {
    --- Try to insert a scored item. Returns true if inserted.
    ---@param score number
    ---@param item table
    ---@return boolean
    insert = function(score, item)
      if size < k then
        size = size + 1
        heap[size] = { score = score, item = item }
        -- Bubble up
        local i = size
        while i > 1 do
          local parent = math.floor(i / 2)
          if heap[i].score < heap[parent].score then
            heap[i], heap[parent] = heap[parent], heap[i]
            i = parent
          else
            break
          end
        end
        return true
      elseif score > heap[1].score then
        local evicted = heap[1].item
        if evicted.breakdown then
          breakdown_pool:release(evicted.breakdown)
        end
        result_pool:release(evicted)
        heap[1] = { score = score, item = item }
        sift_down(1)
        return true
      end
      return false
    end,

    --- Get minimum score in heap (threshold for pruning).
    ---@return number
    min_score = function()
      return size >= k and heap[1].score or 0
    end,

    --- Extract sorted results (descending by score).
    ---@return table[]
    results = function()
      table.sort(heap, function(a, b) return a.score > b.score end)
      local out = {}
      for i = 1, size do out[i] = heap[i].item end
      return out
    end,
  }
end

--- Precompute the maximum possible remaining score after tag scoring.
--- Used for early pruning: if tag_score + max_remaining < heap minimum, skip.
---@param weights table scoring weights
---@return number max_remaining
local function compute_max_remaining(weights)
  local fm_max_raw = 0
  for _, field in ipairs(FM_FIELDS) do fm_max_raw = fm_max_raw + field.weight end
  return weights.frontmatter * fm_max_raw
    + weights.colink
    + weights.link_1hop
    + weights.temporal
end

--- Score a single candidate entry against a source and insert into top-K heap.
--- Shared scoring logic for both compute() and compute_async().
---@param rel_path string candidate rel_path
---@param entry table candidate VaultIndexEntry
---@param source_rel_path string source to skip
---@param source_data table pre-computed ConnectionNoteData for source
---@param weights table scoring weights
---@param idf table tag → doc_count
---@param total_pages number total document count
---@param max_remaining number from compute_max_remaining()
---@param top table top-K heap from create_top_k()
---@param vi table VaultIndex instance
---@param resolve function memoized link resolver
local function score_candidate(rel_path, entry, source_rel_path, source_data,
    weights, idf, total_pages, max_remaining, top, vi, resolve, arena_scope)
  if rel_path == source_rel_path then return end

  -- 1. Cheap signal first: tag overlap (no build_note_data needed)
  local candidate_tags = entry.tag_set
  local tag_raw, shared_tags = score_tags(
    source_data.tags, candidate_tags, idf, total_pages, arena_scope
  )
  local tag_score = weights.tags * tag_raw

  -- Early pruning: if tag_score + max possible remaining can't beat heap minimum
  local heap_min = top.min_score()
  if heap_min > 0 and tag_score + max_remaining < heap_min then return end

  -- Build full candidate data (only if candidate has a chance)
  local candidate = get_note_data(entry, vi, resolve, candidate_tags)
  local total_score = tag_score
  local reasons = {}
  local breakdown = _breakdown_pool:acquire(function()
    return { tags = 0, fm = 0, colink = 0, link = 0, temporal = 0 }
  end)
  breakdown.tags = tag_score

  if tag_score > 0 and #shared_tags > 0 then
    local display_tags = arena_scope and render_arena.alloc_array(arena_scope, 3) or {}
    for i = 1, math.min(3, #shared_tags) do
      display_tags[i] = "#" .. shared_tags[i]
    end
    local suffix = #shared_tags > 3 and (" +" .. (#shared_tags - 3)) or ""
    reasons[#reasons + 1] = "tags: " .. table.concat(display_tags, ", ") .. suffix
  end

  -- 2. Frontmatter
  local fm_score, fm_reasons = score_frontmatter(
    source_data.fm_fields, candidate.fm_fields, arena_scope
  )
  fm_score = weights.frontmatter * fm_score
  breakdown.fm = fm_score
  if fm_score > 0 then
    reasons[#reasons + 1] = "fm: " .. table.concat(fm_reasons, ", ")
  end
  total_score = total_score + fm_score

  -- 3. Co-occurrence (bibliographic coupling)
  local colink_raw, colink_count = score_colinks(
    source_data.outlink_targets, candidate.outlink_targets,
    source_data.outlink_count, candidate.outlink_count
  )
  local colink_score = weights.colink * colink_raw
  breakdown.colink = colink_score
  if colink_count > 0 then
    reasons[#reasons + 1] = "colink: " .. colink_count .. " shared"
  end
  total_score = total_score + colink_score

  -- 4. Link proximity
  local link_score, link_reason = score_link_proximity(
    source_data.rel_path_lower,
    source_data.neighbors,
    candidate.rel_path_lower,
    candidate.neighbors,
    weights
  )
  breakdown.link = link_score
  if link_reason then
    reasons[#reasons + 1] = link_reason
  end
  total_score = total_score + link_score

  -- 5. Temporal proximity
  local temporal_raw = score_temporal(
    source_data.ctime, source_data.mtime,
    candidate.ctime, candidate.mtime
  )
  local temporal_score = weights.temporal * temporal_raw
  breakdown.temporal = temporal_score
  if temporal_raw >= 0.4 then
    local label = temporal_raw >= 0.7 and "recent" or "near"
    reasons[#reasons + 1] = "time: " .. label
  end
  total_score = total_score + temporal_score

  if total_score > 0 then
    local item = _result_pool:acquire(function()
      return { rel_path = nil, name = nil, name_lower = nil,
               rel_path_lower = nil, score = 0, reasons = nil, breakdown = nil }
    end)
    item.rel_path = rel_path
    item.name = entry.basename
    item.name_lower = candidate.name_lower
    item.rel_path_lower = candidate.rel_path_lower
    item.score = total_score
    item.reasons = reasons
    item.breakdown = breakdown
    top.insert(total_score, item)
  else
    _breakdown_pool:release(breakdown)
  end
end

--- Ensure IDF data is available via the summary tree (O(1) lookup).
--- Returns tag document frequencies and total file count from the tree root.
---@return table idf (tag -> doc_count)
---@return number total_pages
local function ensure_idf()
  local vi = vault_index.current()
  if not vi then return {}, 0 end
  local root = vi._summary_tree:query("")
  return root.tag_file_counts, root.file_count
end

--- Shared setup for compute() and compute_async().
--- Subscribes to vault index, resolves source entry, builds IDF/weights/resolver.
---@param source_rel_path string
---@return table|nil state All shared state needed for scoring, or nil if setup fails
local function prepare_compute(source_rel_path)
  -- Ensure we're subscribed to vault index for targeted invalidation
  ensure_subscription()

  local vi, index_gen = get_vault_index()
  if not vi then return nil end

  -- Invalidate note data cache: targeted removal via subscriber, full clear as fallback
  if _note_data_gen ~= index_gen then
    if _pending_full_clear or not _subscription.is_active() then
      -- No subscriber or no context: full clear (safe fallback)
      _note_data_cache:clear()
    elseif next(_pending_changed) then
      -- Incremental: only remove entries for files that actually changed
      for rel_path in pairs(_pending_changed) do
        _note_data_cache:remove(rel_path)
      end
    end
    _pending_changed = {}
    _pending_full_clear = false
    _note_data_gen = index_gen
  end

  local source_entry = vi:get_entry(source_rel_path)
  if not source_entry then return nil end

  local weights = get_weights()
  -- Snapshot for consistent iteration during scoring.
  -- IDF and scoring iterate the full files table; a snapshot prevents
  -- mid-build inconsistency if build_async() mutates between yields.
  local files = vi:snapshot_files()
  local idf, total_pages = ensure_idf()
  local resolve = filter_utils.create_memoized_resolver(vi)
  local source_data = get_note_data(source_entry, vi, resolve)
  local max_remaining = compute_max_remaining(weights)

  return {
    vi = vi,
    index_gen = index_gen,
    weights = weights,
    files = files,
    idf = idf,
    total_pages = total_pages,
    resolve = resolve,
    source_data = source_data,
    max_remaining = max_remaining,
  }
end

--- Compute related notes for a given source page.
---@param source_rel_path string
---@param max_results? number (default 30)
---@param opts_cancel? fun(): boolean Optional cancellation check (returns true to cancel)
---@return ConnectionResult[]|nil results, string|nil status
function M.compute(source_rel_path, max_results, opts_cancel)
  local stop = require("andrew.vault.memory_profiler").start_timer("connections.compute")
  max_results = max_results or config.connections.max_results

  -- Check cache before doing full setup
  local vi_check, index_gen_check = get_vault_index()
  if vi_check then
    local ttl = config.connections.cache_ttl
    local now = vim.uv.now() / 1000
    local cached = _cache:get(source_rel_path)
    if filter_utils.is_cache_gen_valid(cached, index_gen_check, "index_gen")
      and (now - cached.timestamp) < ttl
    then
      _cache_hits = _cache_hits + 1
      stop()
      return cached.results
    end
  end
  _cache_misses = _cache_misses + 1

  local s = prepare_compute(source_rel_path)
  if not s then stop() return {} end

  local now = vim.uv.now() / 1000

  -- Score every other entry using top-K heap with early pruning
  local top = create_top_k(max_results, _result_pool, _breakdown_pool)
  local arena_scope = render_arena.begin_scope()

  local checked = 0
  for rel_path, entry in pairs(s.files) do
    if opts_cancel then
      checked = checked + 1
      if checked % 200 == 0 and opts_cancel() then
        render_arena.end_scope(arena_scope)
        stop()
        return nil, "cancelled"
      end
    end
    score_candidate(rel_path, entry, source_rel_path, s.source_data,
      s.weights, s.idf, s.total_pages, s.max_remaining, top, s.vi, s.resolve, arena_scope)
  end

  render_arena.end_scope(arena_scope)
  local results = top.results()

  -- Build dependency set: files whose changes should invalidate this entry
  local deps = {}
  for _, r in ipairs(results) do
    deps[r.rel_path] = true
  end

  -- Cache (LRU eviction handles size bounds)
  _cache:put(source_rel_path, {
    source_path = source_rel_path,
    results = results,
    deps = deps,
    timestamp = now,
    index_gen = s.index_gen,
  })

  stop()
  return results
end

-- ---------------------------------------------------------------------------
-- compute_async: cooperative yielding version for interactive paths
-- ---------------------------------------------------------------------------

--- Async connection scoring with cooperative yielding.
--- Identical scoring logic to compute(), but yields every score_batch_size entries.
--- Does NOT use the result cache (callers are expected to be interactive/one-shot).
---@param source_rel_path string
---@param opts table { max_results?, callback, cancelled? }
function M.compute_async(source_rel_path, opts)
  opts = opts or {}
  local key = "connections:" .. source_rel_path

  conn_pool:request(key, function(resolve, reject)
    local yield_iter = require("andrew.vault.yield_iter")
    local batch_size = config.connections.score_batch_size or 200
    local max_results_arg = opts.max_results or config.connections.max_results

    yield_iter.run_async(function()
      local s = prepare_compute(source_rel_path)
      if not s then return {} end

      local top = create_top_k(max_results_arg, _result_pool, _breakdown_pool)
      local arena_scope = render_arena.begin_scope()

      yield_iter.for_each_yielding(
        s.files,
        batch_size,
        function(rel_path, entry)
          score_candidate(rel_path, entry, source_rel_path, s.source_data,
            s.weights, s.idf, s.total_pages, s.max_remaining, top, s.vi, s.resolve, arena_scope)
        end,
        { cancelled = opts.cancelled }
      )

      render_arena.end_scope(arena_scope)
      return top.results()
    end, function(results) resolve(results) end)
  end, function(result, err)
    if opts.callback then
      opts.callback(err and {} or result)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- fzf-lua picker
-- ---------------------------------------------------------------------------

local ANSI = require("andrew.vault.ansi")

--- Format a score for display in the picker.
---@param score number
---@return string
local function format_score(score)
  local color
  if score >= 10 then
    color = ANSI.magenta
  elseif score >= 5 then
    color = ANSI.green
  elseif score >= 2 then
    color = ANSI.cyan
  else
    color = ANSI.dim
  end
  return color .. string.format("[%4.1f]", score) .. ANSI.reset
end

--- Format a result line for the fzf-lua picker.
---@param result ConnectionResult
---@return string formatted ANSI string
local function format_entry(result)
  local score_str = format_score(result.score)
  local reasons_str = ""
  if #result.reasons > 0 then
    reasons_str = ANSI.dim .. "  " .. table.concat(result.reasons, " | ") .. ANSI.reset
  end
  -- Embed the rel_path as a hidden prefix for action extraction
  return result.rel_path .. "\t" .. score_str .. "  " .. result.name .. reasons_str
end

--- Open the related notes picker for the current buffer.
function M.related_notes()
  local buf_path = vim.api.nvim_buf_get_name(0)
  if not engine.is_vault_buf(0) then
    notify.not_vault_file()
    return
  end

  local rel_path = engine.vault_relative(buf_path)
  if not rel_path then
    notify.warn("cannot determine relative path")
    return
  end

  M.compute_async(rel_path, {
    callback = function(results)
      if not results or #results == 0 then
        notify.info("no related notes found")
        return
      end

      -- Build picker entries
      local entries = {}
      for _, r in ipairs(results) do
        entries[#entries + 1] = format_entry(r)
      end

      local function open_selected(selected, cmd)
        if not selected or not selected[1] then return end
        local rel_sel = selected[1]:match("^([^\t]+)")
        if rel_sel then
          local abs = engine.vault_path .. "/" .. rel_sel
          vim.cmd(cmd .. " " .. vim.fn.fnameescape(abs))
        end
      end

      local fzf = require("fzf-lua")
      fzf.fzf_exec(entries, {
        prompt = "Related notes> ",
        fzf_opts = {
          ["--ansi"] = "",
          ["--delimiter"] = "\t",
          ["--with-nth"] = "2..",
          ["--no-sort"] = "",  -- preserve score ordering
        },
        actions = {
          ["default"] = function(s) open_selected(s, "edit") end,
          ["ctrl-s"] = function(s) open_selected(s, "split") end,
          ["ctrl-v"] = function(s) open_selected(s, "vsplit") end,
          ["ctrl-t"] = function(s) open_selected(s, "tabedit") end,
        },
      })
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Debug: show score breakdown for a specific pair
-- ---------------------------------------------------------------------------

--- Print a detailed score breakdown between the current note and a target.
---@param target_name string note name (without .md)
function M.debug_pair(target_name)
  local buf_path = vim.api.nvim_buf_get_name(0)
  if not engine.is_vault_buf(0) then
    notify.not_vault_file()
    return
  end

  local rel_path = engine.vault_relative(buf_path)
  local results = M.compute(rel_path, 999)

  local lower_target = target_name:lower()
  for _, r in ipairs(results) do
    if r.name_lower == lower_target or r.rel_path_lower:match(lower_target) then
      local lines = {
        "Connection: " .. link_utils.get_basename(buf_path) .. " <-> " .. r.name,
        string.format("Total score: %.2f", r.score),
        "",
        "Breakdown:",
        string.format("  Tags:        %6.2f", r.breakdown.tags or 0),
        string.format("  Frontmatter: %6.2f", r.breakdown.fm or 0),
        string.format("  Co-links:    %6.2f", r.breakdown.colink or 0),
        string.format("  Link prox:   %6.2f", r.breakdown.link or 0),
        string.format("  Temporal:    %6.2f", r.breakdown.temporal or 0),
        "",
        "Reasons:",
      }
      for _, reason in ipairs(r.reasons) do
        lines[#lines + 1] = "  - " .. reason
      end
      notify.info_lines(lines)
      return
    end
  end
  notify.info("no connection found to '" .. target_name .. "'")
end

-- ---------------------------------------------------------------------------
-- Subscriber
-- ---------------------------------------------------------------------------

--- Handle vault index update notifications for targeted cache invalidation.
--- Supports tiered InvalidationContext from vault_index._notify_update.
---@param _gen number new generation (unused, tracked via get_index)
---@param ctx? InvalidationContext|table Tiered invalidation context or legacy context
local function on_index_update(_gen, ctx)
  if not ctx then
    -- No context = full rebuild (build_async completion or vault switch)
    _pending_full_clear = true
    return
  end

  -- Tiered invalidation support
  if ctx.tier == "full" then
    _pending_full_clear = true
    return
  end

  if ctx.tier == "additive" then
    -- New files don't affect existing connection scores.
    -- IDF is served from summary tree (always current).
    return
  end

  -- PARTIAL: track changed files for incremental removal
  for _, list in ipairs({ ctx.changed_paths, ctx.deleted_paths }) do
    if list then
      for _, path in ipairs(list) do
        -- Handle both abs and rel paths (context format varies by caller)
        local rel = engine.vault_relative(path) or path
        _pending_changed[rel] = true
      end
    end
  end
end

-- Initialize subscription handle now that on_index_update is defined.
-- weak_state: subscriber becomes no-op if module is unloaded (defense-in-depth).
-- Interest declaration: only notify for changes to tags, outlinks, frontmatter, aliases.
_subscription = cleanup.subscription_handle(function()
  return vault_index.current()
end, {
  fn = on_index_update,
  interests = { "tags", "outlinks", "frontmatter", "aliases" },
}, { weak_state = _state_anchor })

--- Subscribe to vault index updates. Safe to call multiple times.
--- Re-subscribes if vault index instance changed (vault switch).
local function ensure_subscription()
  _subscription.ensure()
end

--- Teardown: unsubscribe from vault index updates (called on VimLeavePre).
function M.teardown()
  _cache:clear()  -- on_evict releases pool objects per entry
  unsubscribe()
end

--- Unsubscribe from vault index updates.
function unsubscribe()
  _subscription.unsubscribe()
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  engine.register_cache({
    name = "connections",
    module = "andrew.vault.connections",
    invalidate = M.invalidate_cache,
    invalidate_file = function(abs_path)
      local rel = engine.vault_relative(abs_path)
      if rel then
        -- Remove the changed file's own cache entry
        _cache:remove(rel)
        -- Collect keys that depend on the changed file, then remove
        local to_remove = {}
        for cached_rel, entry in _cache:entries() do
          if entry.deps and entry.deps[rel] then
            to_remove[#to_remove + 1] = cached_rel
          end
        end
        for _, key in ipairs(to_remove) do
          _cache:remove(key)
        end
        -- Note: _note_data_cache invalidation is handled by the subscriber
        -- (on_index_update → _pending_changed → incremental removal in compute())
      end
    end,
    stats = function()
      local vi = vault_index.current()
      local cache_stats = _cache.stats and _cache:stats() or {}
      local nd_stats = _note_data_cache.stats and _note_data_cache:stats() or {}
      return {
        entries = _cache:size(),
        note_data_entries = _note_data_cache:size(),
        index_generation = vi and vi._generation or 0,
        subscribed = _subscription.is_active(),
        pending_changes = vim.tbl_count(_pending_changed),
        total_bytes = (cache_stats.total_bytes or 0) + (nd_stats.total_bytes or 0),
        max_bytes = (cache_stats.max_bytes or 0) + (nd_stats.max_bytes or 0),
      }
    end,
  })

  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "connections",
      get_size = function() return _cache:size() end,
      get_capacity = function() return config.cache.connections_max end,
      get_hits = function() return _cache_hits end,
      get_misses = function() return _cache_misses end,
      get_evictions = function() return _cache_evictions end,
      get_generation = function()
        local vi = vault_index.current()
        return vi and vi._generation or 0
      end,
      get_bytes = function()
        local cs = _cache.stats and _cache:stats() or {}
        local ns = _note_data_cache.stats and _note_data_cache:stats() or {}
        return (cs.total_bytes or 0) + (ns.total_bytes or 0)
      end,
      get_max_bytes = function() return config.cache.connections_bytes end,
    })
  end

  -- Commands, keymaps, and palette registrations are handled by init.lua lazy stubs
end

return M
