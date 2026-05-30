--- Shared filter utilities for graph and search filtering.
--- Extracts common predicate logic used by both graph_filter.lua and
--- search_filter.lua into a single source of truth.

local M = {}

local date_utils = require("andrew.vault.date_utils")
local pat = require("andrew.vault.patterns")

--- Resolve a timestamp from a vault index entry.
--- Single source of truth for created/modified/day timestamp resolution.
---@param entry table VaultIndexEntry
---@param field "created"|"modified"|"day"
---@param default_hour number|nil hour for date-only values (default 0 = midnight)
---@return number|nil
function M.get_entry_timestamp(entry, field, default_hour)
  if not entry then return nil end

  if field == "day" then
    -- Fast path: use pre-computed timestamp from index parser
    if entry.day_ts then return entry.day_ts end
    -- Fallback: parse from string
    if entry.day then
      return date_utils.parse_iso_datetime(entry.day, default_hour)
    end
    return nil
  end

  -- Fast path: use pre-computed timestamps from index parser
  if field == "created" and entry.created_ts then return entry.created_ts end
  if field == "modified" and entry.modified_ts then return entry.modified_ts end

  -- Fallback: parse from frontmatter
  if entry.frontmatter and entry.frontmatter[field] then
    local ts = date_utils.parse_iso_datetime(tostring(entry.frontmatter[field]), default_hour)
    if ts then return ts end
  end

  -- Filesystem fallbacks
  if field == "modified" then return entry.mtime end
  if field == "created" then return entry.ctime or entry.mtime end

  return nil
end

--- Create a memoized resolver that caches results of resolve_in_index().
--- Use at the top of traversal functions to avoid repeated lookups for the
--- same link_path within a single BFS/iteration pass.
---@param idx table VaultIndex
---@param arena_scope? integer optional render_arena scope for cache table
---@return fun(link_path: string): string|nil resolver closure
function M.create_memoized_resolver(idx, arena_scope)
  local cache = arena_scope and require("andrew.vault.render_arena").alloc_table(arena_scope) or {}
  return function(link_path)
    local cached = cache[link_path]
    if cached ~= nil then
      -- false means previously resolved to nil (not-found)
      return cached or nil
    end
    local result = M.resolve_in_index(idx, link_path) or false
    cache[link_path] = result
    return result or nil
  end
end

--- Normalize a raw link path: strip heading/block fragments, trim, lowercase.
---@param link_path string raw link path (e.g. "Note Name#Heading^block")
---@return string|nil normalized lowercase name, nil if empty
function M.normalize_link_name(link_path)
  local raw = link_path:match("^([^#^]+)") or link_path
  raw = vim.trim(raw)
  if raw == "" then return nil end
  return raw:lower()
end

--- Resolve an outlink target within the vault index.
--- Shared by graph_filter.lua and search_filter.lua.
---@param idx table VaultIndex
---@param link_path string raw link path from outlinks
---@param files? table<string, VaultIndexEntry> optional snapshot files for consistent reads
---@return string|nil rel_path
function M.resolve_in_index(idx, link_path, files)
  local lower = M.normalize_link_name(link_path)
  if not lower then return nil end

  local ft = files or idx.files
  -- Try direct rel_path match (for path-style values like "Projects/Alpha")
  local entry = ft[lower .. ".md"] or ft[lower]
  if entry then return entry.rel_path end

  -- Use O(1) resolve_name() for basename and alias lookups
  local abs_paths = idx:resolve_name(lower)
  if abs_paths and #abs_paths > 0 then
    local prefix = idx.vault_path .. "/"
    local abs = abs_paths[1]
    if abs:sub(1, #prefix) == prefix then
      return abs:sub(#prefix + 1)
    end
  end

  return nil
end

--- Check if a VaultCacheInvalidate event affects a specific buffer.
--- Returns true if the handler should proceed (buffer is affected).
---@param data table autocmd event data (scope, paths)
---@param bufname string current buffer absolute path
---@return boolean
function M.should_invalidate_buffer(data, bufname)
  local scope = data.scope
  if not scope or scope == "all" then return true end

  if scope == "files" and data.paths then
    for _, p in ipairs(data.paths) do
      if p == bufname then return true end
    end
    return false
  end

  return true
end

--- Shared include/exclude matching logic.
--- Returns true if: no excludes match AND (no includes specified OR at least one include matches).
---@param includes table|nil list of items that must match (at least one)
---@param excludes table|nil list of items that must NOT match (none)
---@param matcher fun(item: any): boolean predicate that tests one item against the value
---@return boolean
function M.matches_include_exclude(includes, excludes, matcher)
  if excludes and #excludes > 0 then
    for _, item in ipairs(excludes) do
      if matcher(item) then return false end
    end
  end
  if includes and #includes > 0 then
    for _, item in ipairs(includes) do
      if matcher(item) then return true end
    end
    return false
  end
  return true
end

--- Parse a tag filter value into include and exclude lists.
--- "project,-archived,-template" -> { "project" }, { "archived", "template" }
--- "project" -> { "project" }, {}
--- "-archived" -> {}, { "archived" }
---@param value string comma-separated tag filter
---@return string[] includes, string[] excludes
function M.parse_tag_filter(value)
  local includes = {}
  local excludes = {}
  for part in value:gmatch(pat.CSV_ITEM) do
    part = vim.trim(part)
    if part:sub(1, 1) == "-" then
      local tag = part:sub(2)
      if tag ~= "" then
        excludes[#excludes + 1] = tag
      end
    else
      if part ~= "" then
        includes[#includes + 1] = part
      end
    end
  end
  return includes, excludes
end

--- Return true if a task passes all filter predicates.
--- Shared by task_kanban.lua and task_timeline.lua.
---@param task table  vault index task entry (text, priority, due, tags, ...)
---@param opts table|nil  { priority_max?, due_before?, due_after?, text_pattern?, project? }
---@return boolean
function M.passes_task_filter(task, opts)
  if not opts then return true end

  if opts.priority_max and task.priority then
    local p = tonumber(task.priority)
    if p and p > opts.priority_max then return false end
  end

  if opts.due_before then
    if not task.due or task.due > opts.due_before then return false end
  end

  if opts.due_after then
    if not task.due or task.due < opts.due_after then return false end
  end

  if opts.text_pattern and opts.text_pattern ~= "" then
    -- Cache lowered pattern on opts to avoid re-lowering per task
    if not opts._text_pattern_lower then
      opts._text_pattern_lower = opts.text_pattern:lower()
    end
    if not (task.text_lower or ""):find(opts._text_pattern_lower, 1, true) then
      return false
    end
  end

  if opts.project then
    -- Cache lowered project on opts to avoid re-lowering per task
    if not opts._project_lower then
      opts._project_lower = opts.project:lower()
    end
    local proj = opts._project_lower
    local found = false
    if task.tags_lower then
      for tag_lower in pairs(task.tags_lower) do
        if tag_lower:find(proj, 1, true) then
          found = true
          break
        end
      end
    end
    if not found then return false end
  end

  return true
end

--- Initialize BFS traversal context: resolve center path and create memoized resolver.
--- Shared bootstrap for graph_filter/traversal.lua and search_filter/graph_traversal.lua.
---@param idx table VaultIndex
---@param center_abs string absolute path of center note
---@return string|nil center_rel
---@return table|nil center_entry
---@return fun(link_path: string): string|nil resolver memoized link resolver
function M.bfs_init(idx, center_abs)
  local engine = require("andrew.vault.engine")
  local center_rel = engine.vault_relative(center_abs)
  if not center_rel then return nil, nil, nil end
  local center_entry = idx:get_entry(center_rel)
  if not center_entry then return nil, nil, nil end
  local resolve = M.create_memoized_resolver(idx)
  return center_rel, center_entry, resolve
end

--- Check if a cache entry is valid against the current vault index generation.
--- Shared by modules that cache results keyed by vault index generation.
---@param cached table|nil cache entry with a .gen field (or .index_gen)
---@param gen number current vault index generation
---@param gen_field? string field name in cached entry (default "gen")
---@return boolean
function M.is_cache_gen_valid(cached, gen, gen_field)
  if not cached then return false end
  if gen <= 0 then return false end
  gen_field = gen_field or "gen"
  return cached[gen_field] == gen
end

--- Build a deterministic string key from filter_opts for cache comparison.
--- Shared by task_kanban.lua and task_timeline.lua.
---@param filter_opts table|nil
---@return string
function M.filter_cache_key(filter_opts)
  if not filter_opts or next(filter_opts) == nil then return "" end
  local parts = {}
  for k, v in pairs(filter_opts) do
    parts[#parts + 1] = k .. "=" .. tostring(v)
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

--- Build a row lookup table from a list of position entries.
--- Each entry must have a `.row` field (0-indexed buffer line).
--- Returns a table mapping row number -> position entry for O(1) lookup.
---@param positions table[] list of entries with .row field
---@return table<number, table> row_to_position
function M.build_row_index(positions)
  local index = {}
  for _, pos in ipairs(positions) do
    index[pos.row] = pos
  end
  return index
end

return M
