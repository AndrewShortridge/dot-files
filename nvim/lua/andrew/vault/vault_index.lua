-- vault_index.lua — Unified persistent vault index
-- Single source of truth for all vault metadata. Replaces independent caches
-- across engine, wikilinks, query/index, tags, completion, linkdiag, autolink.

local M = {}

local cleanup = require("andrew.vault.resource_cleanup")
local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("index")

-- Sub-modules (leaf dependencies only — no circular requires)
local summary_tree = require("andrew.vault.summary_tree")
local parser = require("andrew.vault.vault_index_parser")
local inlinks_mod = require("andrew.vault.vault_index_inlinks")
local collisions_mod = require("andrew.vault.vault_index_collisions")
local build_mod = require("andrew.vault.vault_index_build")
local string_intern = require("andrew.vault.string_intern")
local pat = require("andrew.vault.patterns")

-- Folder path intern pool (shared across entries for deduplication)
local _folder_pool = string_intern.new(500)

-- Lowercase intern pool for rebuild_*_derived (mirrors parser's _pools.lowercase).
-- During load, computed strings from :lower()/:gsub()/:match() are interned here
-- so identical lowercase values across entries share a single Lua string object.
local _rebuild_lower_pool = string_intern.new(5000)

local SCHEMA_VERSION = 7

-- Fields derived from other entry data; stripped before JSON persistence to
-- reduce index size (~30% smaller).  Rebuilt lazily on load / WAL replay.
local DERIVED_FIELDS = {
  "tag_set", "heading_slugs", "block_id_set",
  "abs_path", "basename", "basename_lower", "folder",
}

--- Create a metatable for lazy derived field computation on index entries.
--- Fields are computed on first access and cached via rawset for O(1) subsequent reads.
---@param vault_path string
---@return table metatable
local function make_entry_mt(vault_path)
  return {
    __index = function(self, key)
      if key == "abs_path" then
        local v = vault_path .. "/" .. rawget(self, "rel_path")
        rawset(self, "abs_path", v)
        return v
      elseif key == "basename" then
        local rp = rawget(self, "rel_path")
        local v = rp:match("([^/]+)" .. pat.MD_EXTENSION) or rp:gsub(pat.MD_EXTENSION, "")
        rawset(self, "basename", v)
        return v
      elseif key == "basename_lower" then
        -- Triggers __index for basename if not yet cached
        local v = string_intern.intern_lower(_folder_pool, self.basename)
        rawset(self, "basename_lower", v)
        return v
      elseif key == "folder" then
        local rp = rawget(self, "rel_path")
        local raw = rp:match(pat.PARENT_PATH) or ""
        local v = string_intern.intern(_folder_pool, raw)
        rawset(self, "folder", v)
        return v
      elseif key == "tag_set" then
        local tags = rawget(self, "tags")
        if not tags then return nil end
        local ts = {}
        for _, tag in ipairs(tags) do ts[tag] = true end
        rawset(self, "tag_set", ts)
        return ts
      elseif key == "heading_slugs" then
        local headings = rawget(self, "headings")
        if not headings then return nil end
        local hs = {}
        for _, h in ipairs(headings) do
          if h.slug then hs[h.slug] = true end
        end
        rawset(self, "heading_slugs", hs)
        return hs
      elseif key == "block_id_set" then
        local block_ids = rawget(self, "block_ids")
        if not block_ids then return nil end
        local bs = {}
        for _, b in ipairs(block_ids) do
          bs[b.id] = true
        end
        rawset(self, "block_id_set", bs)
        return bs
      end
    end,
  }
end

-- Re-export parse_task_fields for external callers (recurrence.lua)
M.parse_task_fields = parser.parse_task_fields

-- ---------------------------------------------------------------------------
-- VaultIndex class
-- ---------------------------------------------------------------------------

---@class InvalidationContext
---@field tier "full"|"partial"|"additive"
---@field changed_paths string[]|nil    -- relative paths of changed files
---@field deleted_paths string[]|nil    -- relative paths of deleted files
---@field added_paths string[]|nil      -- relative paths of newly created files
---@field change_types ChangeTypes|nil  -- what kinds of data changed
---@field generation number             -- current _generation value

---@class ChangeTypes
---@field frontmatter boolean
---@field tags boolean
---@field headings boolean
---@field outlinks boolean
---@field tasks boolean
---@field aliases boolean
---@field block_ids boolean

---@class SubscriberEntry
---@field fn function
---@field interests string[]|nil

---@class VaultIndex
---@field vault_path string
---@field files table<string, VaultIndexEntry>
---@field _file_count number
---@field _name_index table<string, string[]>
---@field _alias_index table<string, string[]>
---@field _inlinks table<string, table[]>
---@field _persist_timer uv.uv_timer_t|nil
---@field _generation number
---@field _last_persisted_generation number
---@field _persist_in_flight boolean
---@field _last_persist_time number
---@field _wal_count number
---@field _subscribers SubscriberEntry[]
---@field _ready boolean
---@field _building boolean
---@field _collisions table[]
---@field _collision_notified boolean
---@field _files_with_tags table<string, boolean>
---@field _files_with_tasks table<string, boolean>
---@field _files_by_type table<string, table<string, boolean>>
---@field _tag_blooms table<string, table<integer, boolean>>
---@field _last_inv_ctx InvalidationContext|nil
---@field _inv_stats table
---@field _summary_tree table Hierarchical summary tree for O(1) aggregate queries

M.VaultIndex = {}
M.VaultIndex.__index = M.VaultIndex

--- Module-level singleton
---@type VaultIndex|nil
M._instance = nil

--- Get or create the singleton index for the given vault path.
---@param vault_path string
---@return VaultIndex
function M.get(vault_path)
  if M._instance and M._instance.vault_path == vault_path:gsub("/$", "") then
    return M._instance
  end
  M._instance = M.VaultIndex.new(vault_path)
  return M._instance
end

--- Get the current instance (nil if not initialized).
---@return VaultIndex|nil
function M.current()
  return M._instance
end



function M.VaultIndex.new(vault_path)
  -- Configure intern pool capacities from config
  parser.configure_pools(config.intern)
  _folder_pool._max = config.intern.folder_pool_max or 500
  _rebuild_lower_pool._max = config.intern.lowercase_pool_max or 5000

  local self = setmetatable({}, M.VaultIndex)
  self.vault_path = vault_path:gsub("/$", "")
  self._entry_mt = make_entry_mt(self.vault_path)
  self.files = {}
  self._file_count = 0
  self._name_index = {}
  self._alias_index = {}
  self._inlinks = {}
  self._persist_timer = nil
  self._generation = 0
  self._last_persisted_generation = 0
  self._persist_in_flight = false
  self._last_persist_time = 0
  self._subscribers = {}
  self._ready = false
  self._building = false
  self._collisions = {}
  self._collision_notified = false
  self._wal_count = 0
  self._index_dir = self.vault_path .. "/.vault-index"
  vim.fn.mkdir(self._index_dir, "p")
  -- Lazy caches derived from _name_index/_alias_index (invalidated on index rebuild)
  self._name_cache = nil
  self._sorted_names = nil
  -- Hierarchical summary tree for O(1) aggregate queries
  self._summary_tree = summary_tree.new()
  self._last_inv_ctx = nil
  self._inv_stats = { total = 0, full = 0, partial = 0, additive = 0, subscriber_skips = 0, partial_cache_hits = 0 }
  -- Precomputed sets for early-exit pre-filtering in search
  self._files_with_tags = {}
  self._files_with_tasks = {}
  self._files_by_type = {}
  self._tag_blooms = {}  -- rel_path -> bloom filter for tag membership pre-checks
  -- Scan completion waiters: one-shot callbacks for "index ready" or "generation >= X"
  self._waiters = {}
  self._waiter_seq = 0
  -- Structural sharing: content-addressed tag table interning
  if config.sharing and config.sharing.enable then
    local ss = require("andrew.vault.structural_sharing")
    self._tag_intern = ss.new_intern_store()
  end
  return self
end

--- Apply the lazy-derived-field metatable to an index entry.
--- Called after parser creates an entry or after loading from JSON.
---@param entry VaultIndexEntry
function M.VaultIndex:_apply_entry_mt(entry)
  setmetatable(entry, self._entry_mt)
end

--- Convert an absolute path to a vault-relative path, or nil if outside vault.
function M.VaultIndex:_rel_path(abs_path)
  local prefix = self.vault_path .. "/"
  if abs_path:sub(1, #prefix) ~= prefix then return nil end
  return abs_path:sub(#prefix + 1)
end

-- ---------------------------------------------------------------------------
-- Subscriber system
-- ---------------------------------------------------------------------------

--- Subscribe to index updates. Returns an unsubscribe function.
--- Supports both plain functions (backward compat) and {fn, interests} tables.
---@param opts function|{ fn: function, interests?: string[] }
---@return function unsubscribe
function M.VaultIndex:subscribe(opts)
  local entry
  if type(opts) == "function" then
    entry = { fn = opts, interests = nil } -- nil = all interests
  else
    entry = { fn = opts.fn, interests = opts.interests }
  end

  self._subscribers[#self._subscribers + 1] = entry
  return function()
    for i, sub in ipairs(self._subscribers) do
      if sub == entry then
        table.remove(self._subscribers, i)
        return
      end
    end
  end
end

--- Get count of active subscribers.
---@return number
function M.VaultIndex:subscriber_count()
  return #self._subscribers
end

-- ---------------------------------------------------------------------------
-- Scan completion waiters (one-shot callbacks)
-- ---------------------------------------------------------------------------

--- Wait for the index to reach a specific generation.
--- If the condition is already met, callback fires immediately (synchronous).
---@param generation number  Target generation (fires when _generation >= generation)
---@param callback function  Called with (current_generation)
---@param description string|nil  Debug label
---@return function cancel  Call to remove the waiter
function M.VaultIndex:wait_for(generation, callback, description)
  -- Fast path: condition already met
  if self._generation >= generation then
    callback(self._generation)
    return function() end
  end

  -- Safety cap
  if #self._waiters >= config.index.max_waiters then
    log.warn("waiter cap reached (%d), dropping oldest", config.index.max_waiters)
    table.remove(self._waiters, 1)
  end

  self._waiter_seq = self._waiter_seq + 1
  local waiter = {
    id = self._waiter_seq,
    generation = generation,
    callback = callback,
    description = description,
  }

  -- Insert sorted by generation (ascending)
  local inserted = false
  for i, w in ipairs(self._waiters) do
    if generation < w.generation then
      table.insert(self._waiters, i, waiter)
      inserted = true
      break
    end
  end
  if not inserted then
    self._waiters[#self._waiters + 1] = waiter
  end

  -- Return cancel handle
  local id = waiter.id
  return function()
    for i, w in ipairs(self._waiters) do
      if w.id == id then
        table.remove(self._waiters, i)
        return
      end
    end
  end
end

--- Wait for the index to become ready.
--- "Ready" means _ready == true (at least one successful load/build).
---@param callback function  Called with (current_generation)
---@param description string|nil  Debug label
---@return function cancel
function M.VaultIndex:wait_for_ready(callback, description)
  -- Fast path
  if self._ready then
    callback(self._generation)
    return function() end
  end

  self._waiter_seq = self._waiter_seq + 1
  local waiter = {
    id = self._waiter_seq,
    generation = 0,
    callback = callback,
    description = description or "wait_for_ready",
    ready_waiter = true,
  }

  -- Ready waiters go at the front
  table.insert(self._waiters, 1, waiter)

  local id = waiter.id
  return function()
    for i, w in ipairs(self._waiters) do
      if w.id == id then
        table.remove(self._waiters, i)
        return
      end
    end
  end
end

--- Check and fire any waiters whose conditions are met.
--- Called after _generation increments or _ready becomes true.
function M.VaultIndex:_check_waiters()
  if #self._waiters == 0 then return end
  local still_waiting = {}
  for _, waiter in ipairs(self._waiters) do
    local should_fire = false

    if waiter.ready_waiter then
      should_fire = self._ready
    else
      should_fire = self._generation >= waiter.generation
    end

    if should_fire then
      local ok, err = pcall(waiter.callback, self._generation)
      if not ok then
        log.error("waiter '%s' callback failed: %s", waiter.description or "?", err)
      end
    else
      still_waiting[#still_waiting + 1] = waiter
    end
  end
  self._waiters = still_waiting
end

--- Check whether a subscriber's interests overlap with the change types.
---@param interests string[]|nil  Subscriber's declared interests (nil = match all)
---@param change_types ChangeTypes|nil  What changed (nil = assume all changed)
---@return boolean
local function interests_overlap(interests, change_types)
  if not interests or not change_types then return true end
  for _, field in ipairs(interests) do
    if change_types[field] then return true end
  end
  return false
end

--- Compare old and new parsed entry to determine what changed.
---@param old_entry table|nil Previous index entry for this file
---@param new_entry table|nil Newly parsed entry
---@return ChangeTypes
local function diff_entry(old_entry, new_entry)
  if not old_entry then
    return {
      frontmatter = true, tags = true, headings = true,
      outlinks = true, tasks = true, aliases = true, block_ids = true,
    }
  end
  if not new_entry then
    -- Deleted file: everything changed
    return {
      frontmatter = true, tags = true, headings = true,
      outlinks = true, tasks = true, aliases = true, block_ids = true,
    }
  end

  -- Set equality for arrays of strings (tags, aliases)
  local function string_set_equal(a, b)
    if not a and not b then return true end
    if not a or not b then return false end
    if #a ~= #b then return false end
    local set = {}
    for _, v in ipairs(a) do set[v] = true end
    for _, v in ipairs(b) do
      if not set[v] then return false end
    end
    return true
  end

  -- Set equality for arrays of tables, using a key function to extract a string key
  local function keyed_set_equal(a, b, key_fn)
    if not a and not b then return true end
    if not a or not b then return false end
    if #a ~= #b then return false end
    local set = {}
    for _, v in ipairs(a) do set[key_fn(v)] = true end
    for _, v in ipairs(b) do
      if not set[key_fn(v)] then return false end
    end
    return true
  end

  -- List equality for arrays of tables, using a key function
  local function keyed_list_equal(a, b, key_fn)
    if not a and not b then return true end
    if not a or not b then return false end
    if #a ~= #b then return false end
    for i = 1, #a do
      if key_fn(a[i]) ~= key_fn(b[i]) then return false end
    end
    return true
  end

  -- Shallow table key equality (for frontmatter: checks key presence, not values)
  local function keys_equal(a, b)
    if not a and not b then return true end
    if not a or not b then return false end
    local count_a, count_b = 0, 0
    for _ in pairs(a) do count_a = count_a + 1 end
    for _ in pairs(b) do count_b = count_b + 1 end
    if count_a ~= count_b then return false end
    for k in pairs(a) do
      if b[k] == nil then return false end
    end
    return true
  end

  -- Key extractors for table-typed fields
  local function heading_key(h) return (h.slug or "") .. ":" .. (h.level or 0) end
  local function outlink_key(l) return l._name_lower or l.path or "" end
  local function block_id_key(b) return b.id or "" end

  return {
    frontmatter = not keys_equal(old_entry.frontmatter, new_entry.frontmatter),
    tags        = not string_set_equal(old_entry.tags, new_entry.tags),
    headings    = not keyed_list_equal(old_entry.headings, new_entry.headings, heading_key),
    outlinks    = not keyed_set_equal(old_entry.outlinks, new_entry.outlinks, outlink_key),
    tasks       = #(old_entry.tasks or {}) ~= #(new_entry.tasks or {}),
    aliases     = not string_set_equal(old_entry.aliases, new_entry.aliases),
    block_ids   = not keyed_set_equal(old_entry.block_ids, new_entry.block_ids, block_id_key),
  }
end

--- Classify the invalidation tier based on the change context.
---@param context table|nil Raw context from _apply_staged or update_files_batch
---@return InvalidationContext
function M.VaultIndex:_classify_invalidation(context)
  if not config.invalidation or not config.invalidation.enable_tiered then
    return { tier = "full", generation = self._generation }
  end

  if not context then
    return { tier = "full", generation = self._generation }
  end

  local changed = context.changed_paths or {}
  local deleted = context.deleted_paths or {}
  local added = context.added_paths or {}

  local total_affected = #changed + #deleted + #added
  if total_affected > (config.invalidation.partial_file_threshold or 50) then
    return {
      tier = "full",
      generation = self._generation,
      changed_paths = changed,
      deleted_paths = deleted,
      added_paths = added,
    }
  end

  -- If only additions (no modifications or deletions), use additive tier
  if #changed == 0 and #deleted == 0 and #added > 0 then
    return {
      tier = "additive",
      generation = self._generation,
      added_paths = added,
      change_types = context.change_types,
    }
  end

  -- Default: partial invalidation scoped to affected files
  return {
    tier = "partial",
    generation = self._generation,
    changed_paths = changed,
    deleted_paths = deleted,
    added_paths = added,
    change_types = context.change_types,
  }
end

--- Notify all subscribers with tiered invalidation context.
---@param context? table Raw context with changed_paths, deleted_paths, added_paths, change_types, old_entries
function M.VaultIndex:_notify_update(context)
  self._generation = self._generation + 1
  self:_check_waiters()

  local inv_ctx = self:_classify_invalidation(context)
  inv_ctx.generation = self._generation
  self._last_inv_ctx = inv_ctx

  -- Track stats
  self._inv_stats.total = self._inv_stats.total + 1
  self._inv_stats[inv_ctx.tier] = (self._inv_stats[inv_ctx.tier] or 0) + 1

  if config.invalidation and config.invalidation.debug then
    log.debug("invalidation tier=%s gen=%d changed=%d deleted=%d added=%d",
      inv_ctx.tier, inv_ctx.generation,
      inv_ctx.changed_paths and #inv_ctx.changed_paths or 0,
      inv_ctx.deleted_paths and #inv_ctx.deleted_paths or 0,
      inv_ctx.added_paths and #inv_ctx.added_paths or 0)
  end

  for _, sub in ipairs(self._subscribers) do
    -- Skip subscribers whose interests do not overlap
    if inv_ctx.tier == "full"
        or interests_overlap(sub.interests, inv_ctx.change_types) then
      local ok, err = pcall(sub.fn, self._generation, inv_ctx)
      if not ok then log.debug("subscriber notification failed: %s", err) end
    else
      self._inv_stats.subscriber_skips = self._inv_stats.subscriber_skips + 1
    end
  end
end

--- Is the index ready for queries?
function M.VaultIndex:is_ready()
  return self._ready
end

--- Is a full build currently in progress?
---@return boolean
function M.VaultIndex:is_building()
  return self._building
end

-- ---------------------------------------------------------------------------
-- Snapshot
-- ---------------------------------------------------------------------------

--- @class IndexSnapshot
--- @field files table<string, VaultIndexEntry>
--- @field _name_index table<string, string[]>
--- @field _alias_index table<string, string[]>
--- @field _inlinks table<string, table[]>
--- @field _files_with_tags table<string, boolean>
--- @field _files_with_tasks table<string, boolean>
--- @field _files_by_type table<string, table<string, boolean>>
--- @field _tag_blooms table<string, table<integer, boolean>>
--- @field _generation number
--- @field _file_count number

--- Shallow-copy the files table. Entries are shared references (never
--- mutated in-place after insertion), so only the table shell is copied.
---@return table<string, VaultIndexEntry>
local function copy_files(files)
  local t = {}
  for k, v in pairs(files) do t[k] = v end
  return t
end

--- Create an immutable snapshot of the current index state.
--- The files table is shallow-copied (O(N)); derived indexes are shared by
--- reference since they are rebuilt atomically (not mutated during builds).
---@return IndexSnapshot
function M.VaultIndex:snapshot()
  return {
    files = copy_files(self.files),
    _name_index = self._name_index,
    _alias_index = self._alias_index,
    _inlinks = self._inlinks,
    _files_with_tags = self._files_with_tags,
    _files_with_tasks = self._files_with_tasks,
    _files_by_type = self._files_by_type,
    _tag_blooms = self._tag_blooms,
    _generation = self._generation,
    _file_count = self._file_count,
  }
end

--- Return a snapshot-safe files table for iteration.
--- When config.index.use_snapshots is true, returns a shallow copy of
--- self.files (same as snapshot().files but avoids allocating the full
--- IndexSnapshot wrapper). Otherwise returns the live table.
---@return table<string, VaultIndexEntry>
function M.VaultIndex:snapshot_files()
  if not require("andrew.vault.config").index.use_snapshots then
    return self.files
  end
  return copy_files(self.files)
end

-- ---------------------------------------------------------------------------
-- Staged apply (atomic batch commit for build_async)
-- ---------------------------------------------------------------------------

--- Apply staged mutations atomically and rebuild derived indexes.
--- Called from build_async() after all batches complete.
--- Runs synchronously (no yield) so the update is atomic from the event
--- loop's perspective.
---@param staged table<string, VaultIndexEntry> rel_path -> new entry
---@param deleted string[] list of rel_paths to remove
---@param old_entries table<string, VaultIndexEntry> pre-mutation entries
---@param changed_rel_paths string[] rel_paths that were changed
---@param is_cold_start boolean
function M.VaultIndex:_apply_staged(staged, deleted, old_entries, changed_rel_paths, is_cold_start)
  -- Apply staged entries
  for rel_path, entry in pairs(staged) do
    if self.files[rel_path] == nil then
      self._file_count = self._file_count + 1
    end
    self.files[rel_path] = entry
  end

  -- Remove deleted entries
  for _, rel_path in ipairs(deleted) do
    if self.files[rel_path] ~= nil then
      self._file_count = self._file_count - 1
      self.files[rel_path] = nil
    end
  end

  -- Update summary tree
  if is_cold_start then
    self._summary_tree:build_from_files(self.files)
  else
    local use_batch = (#changed_rel_paths + #deleted) > 10
    if use_batch then self._summary_tree:batch_begin() end
    for rel_path, entry in pairs(staged) do
      if use_batch then
        self._summary_tree:batch_update(rel_path, entry)
      else
        self._summary_tree:update(rel_path, entry)
      end
    end
    for _, rel_path in ipairs(deleted) do
      if use_batch then
        self._summary_tree:batch_remove(rel_path)
      else
        self._summary_tree:remove(rel_path)
      end
    end
    if use_batch then self._summary_tree:batch_end() end
  end

  -- Rebuild derived indexes
  if is_cold_start then
    self:_rebuild_name_index()
    self:_recompute_inlinks()
    self:_rebuild_precomputed_sets()
  else
    if #changed_rel_paths > 0 or #deleted > 0 then
      self:_update_name_index_incremental(old_entries, changed_rel_paths, deleted)
      self:_update_precomputed_sets_incremental(old_entries, changed_rel_paths, deleted)
    end
    if not self._inlinks or not next(self._inlinks) then
      self:_recompute_inlinks()
    else
      self:_recompute_inlinks_incremental(changed_rel_paths, deleted)
    end
  end

  self._ready = true
  self:_check_waiters()
  self._building = false
  if is_cold_start then
    self:_schedule_persist()
  else
    self:_schedule_persist(changed_rel_paths, deleted)
  end

  -- Build tiered invalidation context
  local added_paths = {}
  local modified_paths = {}
  for _, rel_path in ipairs(changed_rel_paths) do
    if old_entries[rel_path] then
      modified_paths[#modified_paths + 1] = rel_path
    else
      added_paths[#added_paths + 1] = rel_path
    end
  end

  -- Compute change_types by diffing old vs new entries (OR'd across all files)
  local change_types = nil
  if not is_cold_start then
    change_types = M._compute_change_types(
      old_entries, self.files, modified_paths, added_paths, deleted
    )
  end

  self:_notify_update({
    changed_paths = modified_paths,
    deleted_paths = deleted,
    added_paths = added_paths,
    change_types = change_types,
    old_entries = old_entries,
  })
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

--- Get the path to the persistent index file.
function M.VaultIndex:_index_path()
  return self._index_dir .. "/index.json"
end

--- Get the path to the write-ahead log file.
function M.VaultIndex:_wal_path()
  return self._index_dir .. "/changes.jsonl"
end

--- Strip pre-computed lowercase fields from outlinks (recomputed on load).
---@param outlinks table[]|nil
local function strip_outlinks_derived(outlinks)
  if not outlinks then return end
  for _, link in ipairs(outlinks) do
    link._name_lower = nil
    link.stem_lower = nil
    link.basename_lower = nil
  end
end

--- Strip pre-computed lowercase fields from tasks (recomputed on load).
---@param tasks table[]|nil
local function strip_tasks_derived(tasks)
  if not tasks then return end
  for _, task in ipairs(tasks) do
    task.text_lower = nil
    task.tags_lower = nil
    task.repeat_rule_lower = nil
  end
end

--- Rebuild pre-computed lowercase fields on outlinks after loading from disk.
--- Uses _rebuild_lower_pool to intern computed strings, matching the parser's
--- make_link_entry() which interns via _pools.lowercase.
---@param outlinks table[]|nil
local function rebuild_outlinks_derived(outlinks)
  if not outlinks then return end
  local fu = require("andrew.vault.filter_utils")
  local intern_l = string_intern.intern
  local pool = _rebuild_lower_pool
  for _, link in ipairs(outlinks) do
    if not link._name_lower then
      local raw = fu.normalize_link_name(link.path or "") or ""
      link._name_lower = intern_l(pool, raw)
      link.stem_lower = intern_l(pool, link._name_lower:gsub(pat.MD_EXTENSION, ""))
      link.basename_lower = intern_l(pool, link.stem_lower:match(pat.BASENAME) or link.stem_lower)
    end
  end
end

--- Rebuild pre-computed lowercase fields on tasks after loading from disk.
--- Uses _rebuild_lower_pool to intern computed strings, matching the parser's
--- extract_tasks() which interns via intern_lower().
---@param tasks table[]|nil
local function rebuild_tasks_derived(tasks)
  if not tasks then return end
  local intern_l = string_intern.intern
  local pool = _rebuild_lower_pool
  for _, task in ipairs(tasks) do
    if task.tags and not task.tags_lower then
      local tl = {}
      for _, tag in ipairs(task.tags) do tl[intern_l(pool, tag:lower())] = true end
      task.tags_lower = tl
    end
    if task.text and not task.text_lower then
      task.text_lower = intern_l(pool, task.text:lower())
    end
    if task.repeat_rule and not task.repeat_rule_lower then
      task.repeat_rule_lower = intern_l(pool, task.repeat_rule:lower())
    end
  end
end

--- Strip derived fields from a single entry before JSON encoding.
--- Removes any rawset-cached derived values; __index will recompute on demand.
---@param entry VaultIndexEntry
local function strip_derived(entry)
  for _, key in ipairs(DERIVED_FIELDS) do
    rawset(entry, key, nil)
  end
  -- Strip redundant stem fields (recomputed on load from rel_path)
  entry.rel_stem = nil
  entry.rel_stem_lower = nil
  strip_outlinks_derived(entry.outlinks)
  strip_tasks_derived(entry.tasks)
  if entry._chunks then
    for _, chunk in ipairs(entry._chunks) do
      local pd = chunk.parsed_data
      if pd then
        strip_outlinks_derived(pd.outlinks)
        strip_tasks_derived(pd.tasks)
      end
    end
  end
end

--- Load from persisted index. Returns true if successful.
---@return boolean success
---@return string|nil err
function M.VaultIndex:load()
  local path = self:_index_path()
  local f, io_err = io.open(path, "r")
  if not f then
    log.debug("no persisted index: %s", io_err or "unknown")
    return false, "cannot open " .. path .. ": " .. (io_err or "unknown")
  end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then
    log.debug("persisted index empty: %s", path)
    return false, "persisted index is empty"
  end

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    log.warn("persisted index JSON decode failed: %s", tostring(data))
    return false, "JSON decode failed: " .. tostring(data)
  end

  if data.version ~= SCHEMA_VERSION then
    log.debug("schema version mismatch: got %s, want %s", tostring(data.version), tostring(SCHEMA_VERSION))
    return false, "schema version mismatch"
  end
  if data.vault_path ~= self.vault_path then
    log.debug("vault path mismatch: got %s, want %s", data.vault_path, self.vault_path)
    return false, "vault path mismatch"
  end

  self.files = data.files or {}

  -- Replay WAL entries that were written since the last full persist
  local wal_path = self:_wal_path()
  local wf = io.open(wal_path, "r")
  if wf then
    local wal_count = 0
    for line in wf:lines() do
      local wok, wentry = pcall(vim.json.decode, line)
      if wok and type(wentry) == "table" then
        if wentry.op == "set" and wentry.path and wentry.entry then
          self.files[wentry.path] = wentry.entry
          wal_count = wal_count + 1
        elseif wentry.op == "del" and wentry.path then
          self.files[wentry.path] = nil
          wal_count = wal_count + 1
        end
      end
    end
    wf:close()
    if wal_count > 0 then
      log.info("replayed %d WAL entries", wal_count)
    end
  end

  -- Rebuild derived fields not persisted to disk
  local file_count = 0
  for _, entry in pairs(self.files) do
    file_count = file_count + 1
    -- Set lazy-derived-field metatable (abs_path, basename, folder, etc.)
    self:_apply_entry_mt(entry)
    -- Recompute rel_stem and rel_stem_lower (stripped before persist)
    entry.rel_stem = entry.rel_path:gsub(pat.MD_EXTENSION, "")
    entry.rel_stem_lower = entry.rel_stem:lower()
    -- Rebuild pre-computed lowercase fields on outlinks and tasks
    rebuild_outlinks_derived(entry.outlinks)
    rebuild_tasks_derived(entry.tasks)
    -- Rebuild derived fields inside chunk parsed_data (stripped before persist)
    if entry._chunks then
      for _, chunk in ipairs(entry._chunks) do
        local pd = chunk.parsed_data
        if pd then
          rebuild_outlinks_derived(pd.outlinks)
          rebuild_tasks_derived(pd.tasks)
        end
      end
    end
  end
  self._file_count = file_count
  -- Rebuild derived indexes so the index is immediately queryable
  self:_rebuild_name_index()
  self:_recompute_inlinks()
  self:_rebuild_precomputed_sets()
  -- Build hierarchical summary tree from loaded files
  self._summary_tree:build_from_files(self.files)
  self._ready = true
  self:_check_waiters()
  log.debug("loaded persisted index (%d files)", self._file_count)
  return true, nil
end

--- Append delta entries to the WAL (fast, append-only I/O).
---@param changed_rel_paths string[]  rel_paths of changed/new files
---@param deleted_rel_paths string[]  rel_paths of deleted files
function M.VaultIndex:_persist_delta(changed_rel_paths, deleted_rel_paths)
  local wal_path = self:_wal_path()
  local f = io.open(wal_path, "a")
  if not f then
    log.warn("WAL open failed: %s", wal_path)
    return
  end

  for _, rel_path in ipairs(changed_rel_paths) do
    local entry = self.files[rel_path]
    if entry then
      strip_derived(entry)
      local ok, line = pcall(vim.json.encode, { op = "set", path = rel_path, entry = entry })
      -- No restore needed: __index metatable recomputes on demand
      if ok then f:write(line .. "\n") end
    end
  end

  for _, rel_path in ipairs(deleted_rel_paths) do
    local ok, line = pcall(vim.json.encode, { op = "del", path = rel_path })
    if ok then f:write(line .. "\n") end
  end

  f:close()
  self._wal_count = self._wal_count + #changed_rel_paths + #deleted_rel_paths
end

--- Truncate the WAL file after a successful full persist.
function M.VaultIndex:_truncate_wal()
  local wf = io.open(self:_wal_path(), "w")
  if wf then wf:close() end
  self._wal_count = 0
end

--- Schedule persistence for incremental changes.
--- When changed/deleted paths are provided, writes a fast WAL delta and only
--- schedules a full persist if the WAL has grown large.  Without paths (e.g.
--- after build_async), schedules a normal debounced full persist.
---@param changed_rel_paths? string[]
---@param deleted_rel_paths? string[]
function M.VaultIndex:_schedule_persist(changed_rel_paths, deleted_rel_paths)
  if changed_rel_paths or deleted_rel_paths then
    -- Incremental change: write delta to WAL (fast, <2ms)
    self:_persist_delta(changed_rel_paths or {}, deleted_rel_paths or {})
    -- Large WAL: debounced full persist (existing path)
    -- Small WAL: defer to IDLE (CursorHold) to avoid typing interference
    if self._wal_count > 1000 then
      self:_schedule_full_persist()
    else
      local scheduler = require("andrew.vault.work_scheduler")
      local idx = self
      scheduler.schedule(scheduler.IDLE, function()
        idx:_persist()
      end, { domain = "index", label = "persist" })
    end
  else
    -- Full rebuild: schedule debounced full persist with adaptive delay
    self:_schedule_full_persist()
  end
end

--- Schedule a full persist with adaptive delay based on time since last persist.
--- Prevents redundant full persists during burst editing sessions.
function M.VaultIndex:_schedule_full_persist()
  local now = vim.uv.now()
  local since_last = now - self._last_persist_time
  local min_interval = config.index.persist_min_interval_ms

  local delay = math.max(
    config.index.persist_debounce_ms,
    min_interval - since_last
  )

  self._persist_timer = cleanup.debounce(self._persist_timer, delay, function()
    self:_persist()
  end)
end

--- Prepare persist data: clean up timer, check generation, create dir, encode JSON.
--- Returns nil if persistence should be skipped (generation unchanged).
--- Returns the JSON string on success, or nil on encode failure.
---@param caller string  Name of the calling function (for log messages)
---@return string|nil json
function M.VaultIndex:_prepare_persist_data(caller)
  cleanup.close_timer(self._persist_timer)
  self._persist_timer = nil

  -- Skip if nothing changed since last persist
  if self._generation == self._last_persisted_generation then
    log.debug("%s skipped: generation %d unchanged", caller, self._generation)
    return nil
  end

  -- Strip cached derived fields to reduce JSON size (~30% smaller).
  -- No restore needed: __index metatable recomputes on demand.
  for _, entry in pairs(self.files) do
    strip_derived(entry)
  end

  local data = {
    version = SCHEMA_VERSION,
    vault_path = self.vault_path,
    built_at = os.time(),
    files = self.files,
  }
  local ok, json = pcall(vim.json.encode, data)

  if not ok then
    log.error("JSON encode failed: %s", tostring(json))
    return nil
  end

  return json
end

--- Write index to disk (async file I/O via vim.uv).
--- Skips if nothing changed since last persist or if a write is already in flight.
function M.VaultIndex:_persist()
  -- Skip if an async write is already in progress (debounce will reschedule)
  if self._persist_in_flight then
    log.debug("persist skipped: write already in flight")
    return
  end

  local json = self:_prepare_persist_data("persist")
  if not json then return end

  local path = self:_index_path()
  local gen_at_write = self._generation
  local wal_count_at_write = self._wal_count
  self._persist_in_flight = true

  vim.uv.fs_open(path, "w", 438, function(open_err, fd)
    if open_err or not fd then
      self._persist_in_flight = false
      vim.schedule(function()
        log.error("cannot open index for write: %s", open_err or "unknown")
      end)
      return
    end

    vim.uv.fs_write(fd, json, 0, function(write_err)
      if write_err then
        vim.uv.fs_close(fd, function() end)
        self._persist_in_flight = false
        vim.schedule(function()
          log.error("index write failed: %s", write_err)
        end)
        return
      end

      vim.uv.fs_close(fd, function(close_err)
        self._persist_in_flight = false
        if close_err then
          vim.schedule(function()
            log.error("index close failed: %s", close_err)
          end)
          return
        end
        -- Truncate WAL only if no new deltas were appended during async write.
        -- If new entries exist, keep the WAL — redundant entries are harmless
        -- on replay, and missing entries would cause data loss on crash.
        if self._wal_count == wal_count_at_write then
          self:_truncate_wal()
        end
        vim.schedule(function()
          -- Only update if a synchronous persist_now() hasn't already
          -- written a newer generation (e.g. during VimLeavePre).
          if gen_at_write >= self._last_persisted_generation then
            self._last_persisted_generation = gen_at_write
            self._last_persist_time = vim.uv.now()
          end
          log.debug("persisted index (%d files, gen %d)", self._file_count, gen_at_write)
        end)
      end)
    end)
  end)
end

--- Persist immediately and synchronously (for VimLeavePre).
--- Uses blocking I/O to ensure data is written before Neovim exits.
function M.VaultIndex:persist_now()
  if not self._ready then return end

  -- If an async write is in flight, its callback may not have updated
  -- _last_persisted_generation yet. Clear the flag and force a fresh
  -- sync write so no changes are lost on shutdown.
  if self._persist_in_flight then
    log.debug("persist_now: superseding in-flight async write")
    self._persist_in_flight = false
  end

  local json = self:_prepare_persist_data("persist_now")
  if not json then return end

  local f, io_err = io.open(self:_index_path(), "w")
  if not f then
    log.error("cannot write index: %s", io_err or "unknown")
    return
  end
  local ok, write_err2 = f:write(json)
  f:close()
  if not ok then
    log.error("index write failed: %s", write_err2 or "unknown")
    return
  end
  self:_truncate_wal()
  self._last_persisted_generation = self._generation
  self._last_persist_time = vim.uv.now()
  log.debug("persist_now: wrote index (%d files, gen %d)", self._file_count, self._generation)
end

-- ---------------------------------------------------------------------------
-- Directory walking (shared helper to deduplicate _walk / _detect_changes)
-- ---------------------------------------------------------------------------

--- Walk the vault directory tree, calling callback for each .md file.
---@param callback fun(rel_path: string, abs_path: string, stat: table)
function M.VaultIndex:_walk_files(callback)
  local skip_dirs = config.index.skip_dirs
  local function walk(abs_dir, rel_dir)
    local handle = vim.uv.fs_scandir(abs_dir)
    if not handle then return end

    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end

      local abs_path = abs_dir .. "/" .. name
      local rel_path = (rel_dir == "") and name or (rel_dir .. "/" .. name)

      if ftype == "directory" then
        if not skip_dirs[name] then
          walk(abs_path, rel_path)
        end
      elseif ftype == "file" and name:match(pat.MD_EXTENSION) then
        local stat = vim.uv.fs_stat(abs_path)
        if stat then
          callback(rel_path, abs_path, stat)
        end
      end
    end
  end

  walk(self.vault_path, "")
end

--- Walk all files and parse them into the index.
function M.VaultIndex:_walk()
  self:_walk_files(function(rel_path, abs_path, stat)
    local entry = parser.parse_file(abs_path, rel_path, stat)
    if entry then
      if self.files[rel_path] == nil then
        self._file_count = self._file_count + 1
      end
      self.files[rel_path] = entry
    end
  end)
end

--- Walk filesystem and compare against stored index to find changes.
--- Uses three-phase detection: (1) mtime+size, (2) content hash, (3) chunked parse.
--- Phase 2 avoids re-parsing files whose content is unchanged despite mtime bumps
--- (e.g. git checkout, sync tools, save-without-changes).
function M.VaultIndex:_detect_changes()
  local changed = {}
  local seen = {}
  local hash_enabled = config.index.content_hash_enabled
  local hash_skipped = 0

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
      return -- Nothing changed
    end

    -- Phase 2: content hash check (if enabled and entry has a stored hash)
    if hash_enabled and entry.content_hash then
      local content = parser.read_file(abs_path)
      if content then
        local new_hash = build_mod.compute_hash(content)
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
    -- Schedule persist so updated mtime/size values reach disk
    self:_schedule_persist()
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

-- ---------------------------------------------------------------------------
-- Name/alias indexing
-- ---------------------------------------------------------------------------

--- Return the index keys for an entry: basename_lower, optional rel_stem, aliases.
--- rel_stem is nil when it equals basename_lower (no extra key needed).
---@param entry VaultIndexEntry
---@return string basename_lower
---@return string|nil rel_stem  (nil if same as basename_lower)
---@return string[] aliases
local function entry_index_keys(entry)
  local lower = entry.basename_lower
  local rel_stem = entry.rel_stem_lower
  if rel_stem == lower then rel_stem = nil end
  return lower, rel_stem, entry.aliases
end

--- Add a path to an index list, skipping if already present.
---@param idx table<string, string[]>
---@param key string
---@param abs_path string
local function add_to_index(idx, key, abs_path)
  if not idx[key] then
    idx[key] = { abs_path }
    return
  end
  local list = idx[key]
  for _, p in ipairs(list) do
    if p == abs_path then return end
  end
  list[#list + 1] = abs_path
end

--- Add an entry's keys (basename, rel_stem, aliases) to the name/alias indexes.
---@param entry VaultIndexEntry
---@param name_idx table<string, string[]>
---@param alias_idx table<string, string[]>
local function add_entry_to_indexes(entry, name_idx, alias_idx)
  local lower, rel_stem, aliases = entry_index_keys(entry)
  add_to_index(name_idx, lower, entry.abs_path)

  if rel_stem then
    add_to_index(name_idx, rel_stem, entry.abs_path)
  end

  for _, alias in ipairs(aliases) do
    add_to_index(alias_idx, alias, entry.abs_path)
  end
end

--- Rebuild the name lookup table (basename -> [abs_paths]).
function M.VaultIndex:_rebuild_name_index()
  local name_idx = {}
  local alias_idx = {}

  for _, entry in pairs(self.files) do
    add_entry_to_indexes(entry, name_idx, alias_idx)
  end

  self._name_index = name_idx
  self._alias_index = alias_idx
  -- Invalidate lazy caches derived from name/alias indexes
  self._name_cache = nil
  self._sorted_names = nil

  -- Collision detection
  self:_detect_collisions(name_idx, alias_idx)
end

--- Incrementally update the name and alias indexes for changed files.
--- Removes old contributions from old_entries, adds new ones from the
--- current self.files state for the given rel_paths.
---
--- This is O(changed) instead of O(N) for _rebuild_name_index().
---
---@param old_entries table<string, VaultIndexEntry|nil>  rel_path -> old entry (nil if new file)
---@param changed_rel_paths string[]  files that were re-parsed (still exist)
---@param deleted_rel_paths string[]  files that were removed
function M.VaultIndex:_update_name_index_incremental(old_entries, changed_rel_paths, deleted_rel_paths)
  local name_idx = self._name_index
  local alias_idx = self._alias_index

  -- Helper: remove a specific abs_path from a list in an index table.
  local function remove_from_list(idx_table, key, abs_path)
    local list = idx_table[key]
    if not list then return end
    for i = #list, 1, -1 do
      if list[i] == abs_path then
        table.remove(list, i)
      end
    end
    if #list == 0 then
      idx_table[key] = nil
    end
  end

  -- Structural sharing: skip remove+add cycle for changed files whose index
  -- keys (basename_lower, rel_stem_lower, aliases) are identical. Only perform
  -- the expensive remove+add for files whose keys actually changed.
  local skip_set = {} -- rel_paths that can be skipped (keys unchanged)
  for _, rp in ipairs(changed_rel_paths) do
    local old = old_entries[rp]
    local new = self.files[rp]
    if old and new then
      local old_lower, old_stem, old_aliases = entry_index_keys(old)
      local new_lower, new_stem, new_aliases = entry_index_keys(new)
      if old_lower == new_lower and old_stem == new_stem then
        -- Check aliases: identity check first (structural sharing may have
        -- made them the same table), then element-by-element comparison
        local aliases_same = old_aliases == new_aliases
        if not aliases_same then
          aliases_same = #old_aliases == #new_aliases
          if aliases_same then
            for i = 1, #old_aliases do
              if old_aliases[i] ~= new_aliases[i] then
                aliases_same = false
                break
              end
            end
          end
        end
        if aliases_same then
          skip_set[rp] = true
        end
      end
    end
  end

  -- Phase 1: Remove old contributions for affected files (changed + deleted),
  -- skipping changed files whose index keys are unchanged.
  local all_affected = {}
  for _, rp in ipairs(changed_rel_paths) do
    if not skip_set[rp] then
      all_affected[#all_affected + 1] = rp
    end
  end
  for _, rp in ipairs(deleted_rel_paths) do all_affected[#all_affected + 1] = rp end

  for _, rel_path in ipairs(all_affected) do
    local old = old_entries[rel_path]
    if not old then goto next_remove end

    local lower, rel_stem, aliases = entry_index_keys(old)
    remove_from_list(name_idx, lower, old.abs_path)
    if rel_stem then
      remove_from_list(name_idx, rel_stem, old.abs_path)
    end
    for _, alias in ipairs(aliases) do
      remove_from_list(alias_idx, alias, old.abs_path)
    end

    ::next_remove::
  end

  -- Phase 2: Add new contributions for changed (non-deleted) files,
  -- skipping files whose index keys are unchanged.
  for _, rel_path in ipairs(changed_rel_paths) do
    if not skip_set[rel_path] then
      local entry = self.files[rel_path]
      if entry then
        add_entry_to_indexes(entry, name_idx, alias_idx)
      end
    end
  end

  -- Invalidate lazy caches derived from name/alias indexes
  self._name_cache = nil
  self._sorted_names = nil

  -- Collision detection: skip for small batches (< 5 files) to avoid
  -- the O(N) scan in _detect_collisions(). The next full build will
  -- catch any new collisions.
  local total_affected = #changed_rel_paths + #deleted_rel_paths
  if total_affected >= 5 then
    self:_detect_collisions(name_idx, alias_idx)
  end
end

-- ---------------------------------------------------------------------------
-- Collision detection (delegates to vault_index_collisions)
-- ---------------------------------------------------------------------------

--- Detect alias and name collisions, store results, optionally warn.
---@param name_idx table<string, string[]>
---@param alias_idx table<string, string[]>
function M.VaultIndex:_detect_collisions(name_idx, alias_idx)
  self._collisions = collisions_mod.detect(name_idx, alias_idx, function(abs_path)
    return self:_rel_path(abs_path) or abs_path
  end)
  self._collision_notified = collisions_mod.notify_popup(
    self._collisions, self._collision_notified
  )
end

-- ---------------------------------------------------------------------------
-- Inlinks (delegates to vault_index_inlinks)
-- ---------------------------------------------------------------------------

--- Build a resolver function backed by the existing _name_index/_alias_index.
--- Avoids a separate O(N) resolution pass by reusing pre-built indexes.
--- Expects a link table with pre-computed _name_lower/stem_lower/basename_lower
--- (as produced by vault_index_parser.make_link_entry and load()).
--- Only called from vault_index_inlinks with entry.outlinks items.
---@return fun(link: table): table|nil
function M.VaultIndex:_build_resolve_fn()
  local name_idx, alias_idx, files = self._name_index, self._alias_index, self.files
  local prefix = self.vault_path .. "/"

  return function(link)
    local lower = link._name_lower
    local stem = link.stem_lower
    local base = link.basename_lower
    if not lower or lower == "" then return nil end

    -- Try name index (covers basename and rel_stem lookups)
    local paths = name_idx[lower]
      or name_idx[stem or lower]
      or name_idx[base or lower]
    if paths and #paths > 0 then
      local abs = paths[1]
      if abs:sub(1, #prefix) == prefix then
        local entry = files[abs:sub(#prefix + 1)]
        if entry then return entry end
      end
    end

    -- Try alias index
    paths = alias_idx[lower]
    if paths and #paths > 0 then
      local abs = paths[1]
      if abs:sub(1, #prefix) == prefix then
        return files[abs:sub(#prefix + 1)]
      end
    end

    return nil
  end
end

--- Recompute all inlinks.
function M.VaultIndex:_recompute_inlinks()
  self._inlinks = inlinks_mod.recompute(self.files, self:_build_resolve_fn())
end

--- Build a bloom filter for an entry's tags, including hierarchical prefixes.
---@param bloom_mod table The bloom_filter module
---@param tags string[] Tag list from entry
---@return table bloom New bloom filter populated with all tag variants
local function build_tag_bloom(bloom_mod, tags)
  local bloom = bloom_mod.new()
  for _, tag in ipairs(tags) do
    local lower = tag:lower()
    bloom_mod.add(bloom, lower)
    -- Add all hierarchical segments (e.g., "project/alpha" -> also add "project", "alpha")
    for segment in lower:gmatch("([^/]+)") do
      bloom_mod.add(bloom, segment)
    end
    -- Add intermediate paths: "a/b/c" -> "a", "a/b"
    local pos = 1
    while true do
      local slash = lower:find("/", pos, true)
      if not slash then break end
      bloom_mod.add(bloom, lower:sub(1, slash - 1))
      pos = slash + 1
    end
  end
  return bloom
end

--- Tag/frontmatter aggregates served by _summary_tree.
--- name_cache/sorted_names lazily derived from _name_index (invalidated on rebuild).

--- Rebuild precomputed sets for early-exit pre-filtering.
--- Called from load() and build_async() (same lifecycle as _rebuild_name_index).
function M.VaultIndex:_rebuild_precomputed_sets()
  local bloom_enabled = config.prefilter.enabled and config.prefilter.bloom_filter
  local bloom_mod = bloom_enabled and require("andrew.vault.bloom_filter") or nil
  local with_tags = {}
  local with_tasks = {}
  local by_type = {}
  local tag_blooms = {}
  for rel_path, entry in pairs(self.files) do
    if entry.tags and #entry.tags > 0 then
      with_tags[rel_path] = true
      if bloom_mod then
        tag_blooms[rel_path] = build_tag_bloom(bloom_mod, entry.tags)
      end
    end
    if entry.tasks and #entry.tasks > 0 then
      with_tasks[rel_path] = true
    end
    local ftype = entry.frontmatter and entry.frontmatter.type
    if ftype then
      local ftype_lower = tostring(ftype):lower()
      by_type[ftype_lower] = by_type[ftype_lower] or {}
      by_type[ftype_lower][rel_path] = true
    end
  end
  self._files_with_tags = with_tags
  self._files_with_tasks = with_tasks
  self._files_by_type = by_type
  self._tag_blooms = tag_blooms
end

--- Incrementally update precomputed sets for changed/deleted files.
---@param old_entries table<string, VaultIndexEntry|nil>
---@param changed_rel_paths string[]
---@param deleted_rel_paths string[]
function M.VaultIndex:_update_precomputed_sets_incremental(old_entries, changed_rel_paths, deleted_rel_paths)
  local bloom_enabled = config.prefilter.enabled and config.prefilter.bloom_filter
  local bloom_mod = bloom_enabled and require("andrew.vault.bloom_filter") or nil

  -- Helper: remove a rel_path's old type from _files_by_type
  local by_type = self._files_by_type
  local function remove_old_type(rel_path, old)
    if not old then return end
    local old_type = old.frontmatter and old.frontmatter.type
    if not old_type then return end
    local old_type_lower = tostring(old_type):lower()
    if by_type[old_type_lower] then
      by_type[old_type_lower][rel_path] = nil
      if next(by_type[old_type_lower]) == nil then
        by_type[old_type_lower] = nil
      end
    end
  end

  -- Remove old contributions for all affected files
  local all_removed = {}
  for i = 1, #changed_rel_paths do all_removed[#all_removed + 1] = changed_rel_paths[i] end
  for i = 1, #deleted_rel_paths do all_removed[#all_removed + 1] = deleted_rel_paths[i] end
  for _, rel_path in ipairs(all_removed) do
    self._files_with_tags[rel_path] = nil
    self._files_with_tasks[rel_path] = nil
    self._tag_blooms[rel_path] = nil
    remove_old_type(rel_path, old_entries[rel_path])
  end

  -- Add new contributions for changed files
  for _, rel_path in ipairs(changed_rel_paths) do
    local entry = self.files[rel_path]
    if entry then
      if entry.tags and #entry.tags > 0 then
        self._files_with_tags[rel_path] = true
        if bloom_mod then
          self._tag_blooms[rel_path] = build_tag_bloom(bloom_mod, entry.tags)
        end
      end
      if entry.tasks and #entry.tasks > 0 then
        self._files_with_tasks[rel_path] = true
      end
      local ftype = entry.frontmatter and entry.frontmatter.type
      if ftype then
        local ftype_lower = tostring(ftype):lower()
        by_type[ftype_lower] = by_type[ftype_lower] or {}
        by_type[ftype_lower][rel_path] = true
      end
    end
  end
end

--- Incrementally update inlinks for a set of changed/deleted files.
---@param changed_rel_paths string[]
---@param deleted_rel_paths string[]
function M.VaultIndex:_recompute_inlinks_incremental(changed_rel_paths, deleted_rel_paths)
  inlinks_mod.recompute_incremental(
    self.files, self._inlinks, changed_rel_paths, deleted_rel_paths, self:_build_resolve_fn()
  )
end

-- ---------------------------------------------------------------------------
-- Build operations
-- ---------------------------------------------------------------------------

--- Full synchronous build.
function M.VaultIndex:build_sync()
  parser.reset_intern_pool()
  string_intern.clear(_folder_pool)
  string_intern.reset_stats(_folder_pool)
  string_intern.clear(_rebuild_lower_pool)
  string_intern.reset_stats(_rebuild_lower_pool)
  self.files = {}
  self._file_count = 0
  self:_walk()
  self:_rebuild_name_index()
  self:_recompute_inlinks()
  self:_rebuild_precomputed_sets()
  self._ready = true
  self:_check_waiters()
  self:_schedule_persist()
  self:_notify_update()
  return self
end

--- Async incremental build (normal startup path).
function M.VaultIndex:build_async(callback)
  build_mod.build_async(self, callback)
end

--- Update a single file in the vault index.
--- Convenience wrapper around update_files_batch for single-file updates.
---@param abs_path string  Absolute path to re-index
function M.VaultIndex:update_file(abs_path)
  build_mod.update_files_batch(self, { abs_path })
end

--- Batch-update multiple files in the vault index.
---@param abs_paths string[]  Absolute paths to re-index
function M.VaultIndex:update_files_batch(abs_paths)
  build_mod.update_files_batch(self, abs_paths)
end

-- ---------------------------------------------------------------------------
-- Query API (consumed by downstream modules)
-- ---------------------------------------------------------------------------

--- Resolve a note name to absolute path(s).
--- Checks basenames, relative path stems, and aliases.
function M.VaultIndex:resolve_name(name)
  local lower = name:lower()
  local by_name = self._name_index[lower]
  if by_name and #by_name > 0 then return by_name end
  local by_alias = self._alias_index[lower]
  if by_alias and #by_alias > 0 then return by_alias end
  return nil
end

--- Get the name cache in the format expected by engine.get_name_cache().
--- Returns { names = {name=true,...}, paths = {name=abs_path,...} }
--- Lazily derived from _name_index (O(K) where K = unique name keys).
function M.VaultIndex:get_name_cache()
  if not self._name_cache then
    local names = {}
    local paths = {}
    for key, abs_list in pairs(self._name_index) do
      names[key] = true
      paths[key] = abs_list[1]
    end
    self._name_cache = { names = names, paths = paths }
  end
  return self._name_cache
end

--- Get sorted list of {name, name_lower} for all files.
--- Lazily rebuilt from self.files when invalidated.
---@return table[]
function M.VaultIndex:sorted_names()
  if not self._sorted_names then
    local sorted = {}
    for _, entry in pairs(self.files) do
      sorted[#sorted + 1] = { name = entry.basename or "", name_lower = entry.basename_lower }
    end
    table.sort(sorted, function(a, b) return a.name_lower < b.name_lower end)
    self._sorted_names = sorted
  end
  return self._sorted_names
end

--- Get all tags across the vault, sorted.
function M.VaultIndex:all_tags()
  local root = self._summary_tree:query("")
  local tags = vim.tbl_keys(root.tag_counts)
  table.sort(tags)
  return tags
end

--- Get all aliases across the vault, sorted (lowercased at parse time).
--- Derived directly from _alias_index keys (O(A) where A = unique aliases).
---@return string[]
function M.VaultIndex:all_aliases()
  local aliases = vim.tbl_keys(self._alias_index)
  table.sort(aliases)
  return aliases
end

--- Get all unique frontmatter key names across the vault.
---@return string[]
function M.VaultIndex:all_frontmatter_keys()
  local root = self._summary_tree:query("")
  local keys = vim.tbl_keys(root.fm_key_counts)
  table.sort(keys)
  return keys
end

--- Get all tags with their direct file counts.
---@return table<string, number> tag -> count of files directly tagged
function M.VaultIndex:tags_with_counts()
  return self._summary_tree:query("").tag_file_counts
end

--- Check if a tag list contains a match for the given tag (or any descendant).
---@param tags string[] tag list to search
---@param target string tag to match against (without #)
---@param opts? { exact?: boolean, case_insensitive?: boolean }
---@return boolean
function M.tag_matches(tags, target, opts)
  if not tags or #tags == 0 then return false end
  local exact = opts and opts.exact
  local ci = opts and opts.case_insensitive
  local match_tag = ci and target:lower() or target
  local prefix = match_tag .. "/"
  for _, t in ipairs(tags) do
    local cmp = ci and t:lower() or t
    if cmp == match_tag or (not exact and cmp:sub(1, #prefix) == prefix) then
      return true
    end
  end
  return false
end

--- Get headings for a file by absolute path.
---@return table<string, boolean> slug_set
---@return VaultHeading[] headings
function M.VaultIndex:get_headings(abs_path)
  local rel_path = self:_rel_path(abs_path)
  if not rel_path then return {}, {} end
  local entry = self.files[rel_path]
  if not entry then return {}, {} end
  return entry.heading_slugs or {}, entry.headings or {}
end

--- Get block IDs for a file by absolute path.
---@param abs_path string
---@return table<string, boolean> block_id_set  Maps block IDs (without ^) to true
function M.VaultIndex:get_block_ids(abs_path)
  local rel_path = self:_rel_path(abs_path)
  if not rel_path then return {} end
  local entry = self.files[rel_path]
  if not entry then return {} end
  return entry.block_id_set or {}
end

--- Get inlinks for a file by relative path.
function M.VaultIndex:get_inlinks(rel_path)
  return self._inlinks[rel_path] or {}
end

--- Get entry by relative path.
function M.VaultIndex:get_entry(rel_path)
  return self.files[rel_path]
end

--- Get entry by absolute path.
function M.VaultIndex:get_entry_by_abs(abs_path)
  local rel_path = self:_rel_path(abs_path)
  if not rel_path then return nil end
  return self.files[rel_path]
end

--- Count indexed files (O(1) via cached counter).
function M.VaultIndex:file_count()
  return self._file_count
end

--- Show all collisions in a floating window.
function M.VaultIndex:show_collisions()
  collisions_mod.show(self._collisions)
end

--- Return intern pool statistics for debug display.
--- Combines parser pools with index-level folder pool.
--- @return table<string, table>
function M.intern_pool_stats()
  local stats = parser.intern_pool_stats()
  stats.folders = string_intern.stats(_folder_pool)
  stats.rebuild_lower = string_intern.stats(_rebuild_lower_pool)
  return stats
end

--- Exposed for vault_index_build.lua to compute change_types.
M._diff_entry = diff_entry

--- Compute change_types by diffing old vs new entries for interest-based filtering.
--- OR's change flags across all modified/added/deleted paths.
---@param old_entries table<string, table> Old entries keyed by rel_path
---@param files table<string, table> Current index files table
---@param modified string[] Modified rel_paths
---@param added string[] Added rel_paths
---@param deleted string[] Deleted rel_paths
---@return table|nil change_types
function M._compute_change_types(old_entries, files, modified, added, deleted)
  if #modified == 0 and #added == 0 and #deleted == 0 then return nil end
  local change_types = {
    frontmatter = false, tags = false, headings = false,
    outlinks = false, tasks = false, aliases = false, block_ids = false,
  }
  for _, rp in ipairs(modified) do
    local dt = diff_entry(old_entries[rp], files[rp])
    for k, v in pairs(dt) do
      if v then change_types[k] = true end
    end
  end
  for _, rp in ipairs(added) do
    local dt = diff_entry(nil, files[rp])
    for k, v in pairs(dt) do
      if v then change_types[k] = true end
    end
  end
  for _, rp in ipairs(deleted) do
    local dt = diff_entry(old_entries[rp], nil)
    for k, v in pairs(dt) do
      if v then change_types[k] = true end
    end
  end
  return change_types
end

-- Deferred profiler registration (safe: profiler may not be loaded yet)
do
  local ok, profiler = pcall(require, "andrew.vault.memory_profiler")
  if ok then
    profiler.register_counter_deferred({
      name = "index_subscribers",
      get_count = function()
        local idx = M.current()
        return idx and idx:subscriber_count() or 0
      end,
      description = "vault index subscriber count",
    })
  end
end

return M
