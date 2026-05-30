--- Structural sharing utilities for vault index collections.
--- Reuses unchanged sub-tables across index versions to reduce
--- allocation churn and GC pressure during incremental updates.
---
--- Complements string_intern.lua (string-level dedup) by operating
--- at the table/collection level.

local config = require("andrew.vault.config")

local M = {}

-- Phase 1 reuse tracking (per-field counters)
local _share_stats = {
  calls = 0,
  reused = { tags = 0, aliases = 0, frontmatter = 0, inline_fields = 0,
             headings = 0, block_ids = 0, outlinks = 0, tasks = 0 },
  changed = { tags = 0, aliases = 0, frontmatter = 0, inline_fields = 0,
              headings = 0, block_ids = 0, outlinks = 0, tasks = 0 },
}

--- Get Phase 1 share_unchanged reuse statistics.
---@return table
function M.share_stats()
  return _share_stats
end

--- Shallow-compare two arrays (ordered tables with integer keys).
---@param a any[]|nil
---@param b any[]|nil
---@return boolean
function M.arrays_equal(a, b)
  if a == b then return true end
  if a == nil or b == nil then return false end
  local n = #a
  if n ~= #b then return false end
  for i = 1, n do
    if a[i] ~= b[i] then return false end
  end
  return true
end

--- Shallow-compare two flat dictionaries (string keys, scalar values).
---@param a table|nil
---@param b table|nil
---@return boolean
function M.dicts_equal(a, b)
  if a == b then return true end
  if a == nil or b == nil then return false end
  for k, v in pairs(a) do
    if b[k] ~= v then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

--- Compare two arrays of structured items using a key extractor
--- and shallow field comparison.
---@param a table[]|nil
---@param b table[]|nil
---@param key_fn fun(item: table): string
---@return boolean
function M.struct_arrays_equal(a, b, key_fn)
  if a == b then return true end
  if a == nil or b == nil then return false end
  local n = #a
  if n ~= #b then return false end
  for i = 1, n do
    if key_fn(a[i]) ~= key_fn(b[i]) then return false end
    for k, v in pairs(a[i]) do
      if b[i][k] ~= v then return false end
    end
    for k in pairs(b[i]) do
      if a[i][k] == nil then return false end
    end
  end
  return true
end

--- Given an old and new entry, share unchanged sub-tables.
--- Modifies new_entry in-place, replacing sub-tables with old references
--- where content is identical. Returns a set of field names that changed.
---
--- NOTE: Only compares parser-created fields. Lazy derived fields
--- (abs_path, basename, basename_lower, folder, tag_set, heading_slugs,
--- block_id_set) are computed via _entry_mt and must NOT be compared here.
---@param old_entry table
---@param new_entry table
---@return table<string, boolean> changed_fields
function M.share_unchanged(old_entry, new_entry)
  local changed = {}
  local do_freeze = config.sharing and config.sharing.debug_immutability
  _share_stats.calls = _share_stats.calls + 1

  -- Simple arrays (tags, aliases) — sorted string arrays
  local simple_arrays = { "tags", "aliases" }
  for _, field in ipairs(simple_arrays) do
    if M.arrays_equal(old_entry[field], new_entry[field]) then
      new_entry[field] = old_entry[field]
      _share_stats.reused[field] = _share_stats.reused[field] + 1
    else
      changed[field] = true
      _share_stats.changed[field] = _share_stats.changed[field] + 1
    end
  end

  -- Flat dicts (frontmatter, inline_fields)
  local flat_dicts = { "frontmatter", "inline_fields" }
  for _, field in ipairs(flat_dicts) do
    if M.dicts_equal(old_entry[field], new_entry[field]) then
      new_entry[field] = old_entry[field]
      _share_stats.reused[field] = _share_stats.reused[field] + 1
    else
      changed[field] = true
      _share_stats.changed[field] = _share_stats.changed[field] + 1
    end
  end

  -- Structured arrays: headings [{text, text_lower, slug, level, line}, ...]
  if M.struct_arrays_equal(old_entry.headings, new_entry.headings,
      function(h) return (h.text or "") .. ":" .. (h.level or 0) .. ":" .. (h.line or 0) end) then
    new_entry.headings = old_entry.headings
    _share_stats.reused.headings = _share_stats.reused.headings + 1
  else
    changed.headings = true
    _share_stats.changed.headings = _share_stats.changed.headings + 1
  end

  -- Structured arrays: block_ids [{id, text, line}, ...]
  if M.struct_arrays_equal(old_entry.block_ids, new_entry.block_ids,
      function(b) return (b.id or "") .. ":" .. (b.line or 0) end) then
    new_entry.block_ids = old_entry.block_ids
    _share_stats.reused.block_ids = _share_stats.reused.block_ids + 1
  else
    changed.block_ids = true
    _share_stats.changed.block_ids = _share_stats.changed.block_ids + 1
  end

  -- Structured arrays: outlinks [{path, display, embed, _name_lower, ...}, ...]
  if M.struct_arrays_equal(old_entry.outlinks, new_entry.outlinks,
      function(l) return (l.path or "") .. "|" .. tostring(l.embed) end) then
    new_entry.outlinks = old_entry.outlinks
    _share_stats.reused.outlinks = _share_stats.reused.outlinks + 1
  else
    changed.outlinks = true
    _share_stats.changed.outlinks = _share_stats.changed.outlinks + 1
  end

  -- Structured arrays: tasks [{text, status, line, ...}, ...]
  if M.struct_arrays_equal(old_entry.tasks, new_entry.tasks,
      function(t) return (t.text or "") .. ":" .. (t.status or "") .. ":" .. (t.line or 0) end) then
    new_entry.tasks = old_entry.tasks
    _share_stats.reused.tasks = _share_stats.reused.tasks + 1
  else
    changed.tasks = true
    _share_stats.changed.tasks = _share_stats.changed.tasks + 1
  end

  -- Apply immutability guards to shared (reused) tables in debug mode
  if do_freeze then
    for _, field in ipairs(simple_arrays) do
      if not changed[field] and new_entry[field] then
        new_entry[field] = M.freeze(new_entry[field], field)
      end
    end
    for _, field in ipairs(flat_dicts) do
      if not changed[field] and new_entry[field] then
        new_entry[field] = M.freeze(new_entry[field], field)
      end
    end
    local struct_fields = { "headings", "block_ids", "outlinks", "tasks" }
    for _, field in ipairs(struct_fields) do
      if not changed[field] and new_entry[field] then
        new_entry[field] = M.freeze(new_entry[field], field)
      end
    end
  end

  return changed
end

-- ---------------------------------------------------------------------------
-- Content-addressed table interning
-- ---------------------------------------------------------------------------

---@class TableIntern
---@field _store table<string, table>
---@field _refcounts table<string, number>
---@field _hits number
---@field _misses number

--- Create a new table intern store.
---@return TableIntern
function M.new_intern_store()
  return {
    _store = {},
    _refcounts = {},
    _hits = 0,
    _misses = 0,
  }
end

--- Intern an array table by its content hash.
--- Returns a canonical shared table for arrays with identical content.
---@param store TableIntern
---@param tbl any[]|nil
---@return any[]|nil
function M.intern_array(store, tbl)
  if tbl == nil or #tbl == 0 then return tbl end
  local hash = table.concat(tbl, "\0")
  local canonical = store._store[hash]
  if canonical then
    store._hits = store._hits + 1
    store._refcounts[hash] = store._refcounts[hash] + 1
    if config.sharing and config.sharing.debug_immutability then
      return M.freeze(canonical, "interned_array")
    end
    return canonical
  end
  store._misses = store._misses + 1
  store._store[hash] = tbl
  store._refcounts[hash] = 1
  if config.sharing and config.sharing.debug_immutability then
    return M.freeze(tbl, "interned_array")
  end
  return tbl
end

--- Get statistics for an intern store.
---@param store TableIntern
---@return { size: number, hits: number, misses: number, hit_rate: number }
function M.intern_store_stats(store)
  local size = 0
  for _ in pairs(store._store) do size = size + 1 end
  local total = store._hits + store._misses
  return {
    size = size,
    hits = store._hits,
    misses = store._misses,
    hit_rate = total > 0 and (store._hits / total) or 0,
  }
end

-- ---------------------------------------------------------------------------
-- Immutability guards (debug mode)
-- ---------------------------------------------------------------------------

--- Freeze a table to prevent modification (debug mode only).
---@param tbl table
---@param label string
---@return table
function M.freeze(tbl, label)
  if not config.sharing or not config.sharing.debug_immutability then
    return tbl
  end
  return setmetatable({}, {
    __index = tbl,
    __newindex = function(_, k, v)
      error(string.format(
        "Attempted to modify shared %s table: key=%s value=%s",
        label, tostring(k), tostring(v)
      ))
    end,
    __len = function() return #tbl end,
    __pairs = function() return pairs(tbl) end,
    __ipairs = function() return ipairs(tbl) end,
  })
end

return M
