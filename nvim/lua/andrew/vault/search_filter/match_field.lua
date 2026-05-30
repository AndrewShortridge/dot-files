--- Field matching for search filter pipeline.

local M = {}

local config = require("andrew.vault.config")
local date_utils = require("andrew.vault.date_utils")
local file_cache = require("andrew.vault.file_cache")
local filter_utils = require("andrew.vault.filter_utils")
local link_utils = require("andrew.vault.link_utils")
local lru = require("andrew.vault.lru_cache")
local pat = require("andrew.vault.patterns")
local match_helpers = require("andrew.vault.search_filter.match_helpers")
local string_intern = require("andrew.vault.string_intern")
local vault_index = require("andrew.vault.vault_index")
local weighers = require("andrew.vault.cache_weighers")

local _lowercase_pool = string_intern.new(config.intern.lowercase_pool_max)

local compare_date = match_helpers.compare_date
local compare_num = match_helpers.compare_num
local field_exists = match_helpers.field_exists
local get_generic_field = match_helpers.get_generic_field
local in_num_range = match_helpers.in_num_range
local parse_entry_date = filter_utils.get_entry_timestamp
local tonumber_cached = match_helpers.tonumber_cached
local same_day = date_utils.same_day

--- Get or cache a lowered string value on an AST node.
--- Avoids per-entry string.lower() allocation for values that don't change across entries.
---@param node table AST node (used as cache storage)
---@param cache_key string field name on node to cache under
---@param val string value to lowercase
---@return string lowered value
local function cached_lower(node, cache_key, val)
  local cached = node[cache_key]
  if cached then return cached end
  cached = val:lower()
  node[cache_key] = cached
  return cached
end

--- Get the lowered link name from a link object (pre-computed by parser).
---@param link table outlink entry with ._name_lower field
---@return string lowered trimmed link name
local function get_link_name_lower(link)
  return link._name_lower or ""
end

-- =============================================================================
-- Section outlinks cache (generation-aware, persists across evaluate() calls)
-- =============================================================================

--- Per-file section outlinks cache (LRU-bounded).
--- Structure: { [rel_path] = { sections = { [heading_slug] = outlinks[] } } }
local _section_cache_hits = 0
local _section_cache_misses = 0
local _section_cache_evictions = 0

local _section_cache = lru.new_weighted({
  max_bytes = config.cache.section_outlinks_bytes,
  max_items = config.cache.section_cache_max,
  weigher = weighers.section_outlinks,
  on_evict = function() _section_cache_evictions = _section_cache_evictions + 1 end,
})
local _section_cache_generation = -1

--- Tiered section cache invalidation.
--- Supports per-file removal for partial tier; full clear for full tier.
---@param index table VaultIndex instance
---@param ctx? InvalidationContext Tiered invalidation context
function M.invalidate_section_cache(index, ctx)
  local gen = index and index._generation or 0
  if gen == _section_cache_generation then return end

  -- Full clear when: no context, full tier, or multiple generations skipped
  -- (multi-gen skip means _last_inv_ctx only has the latest context, missing intermediates)
  if not ctx or ctx.tier == "full" or (gen - _section_cache_generation) > 1 then
    _section_cache:clear()
    string_intern.clear(_lowercase_pool)
    _section_cache_generation = gen
    return
  end

  if ctx.tier == "partial" then
    -- Only remove cache entries for changed/deleted files
    for _, list in ipairs({ ctx.changed_paths, ctx.deleted_paths }) do
      for _, p in ipairs(list or {}) do
        _section_cache:remove(p)
      end
    end
    _section_cache_generation = gen
    -- Note: intern pool is NOT cleared — entries for unchanged files remain valid
    return
  end

  -- ADDITIVE: new files have no existing cache entries. No action needed.
  _section_cache_generation = gen
end

--- Extract outlinks from a single line of markdown.
--- Delegates to link_utils.extract_line_links and converts to {path} format.
---@param line string
---@return table[] links
local function extract_line_outlinks(line)
  local links = {}
  for _, link in ipairs(link_utils.extract_line_links(line)) do
    if link.name ~= "" then
      local path = link.name .. (link.heading and "#" .. link.heading or "")
        .. (link.block_id and "^" .. link.block_id or "")
      local name_lower = string_intern.intern(_lowercase_pool, filter_utils.normalize_link_name(path))
      links[#links + 1] = {
        path = path,
        _name_lower = name_lower,
      }
    end
  end
  return links
end

--- Read a file once and build a per-heading-section outlinks map.
--- Parses all headings in a single pass. Links are accumulated only under
--- the immediate (deepest) heading during the line scan, then propagated
--- upward through the heading hierarchy in a single post-processing pass.
---@param abs_path string
---@return table<string, table[]> sections: heading_slug -> outlinks[]
local function build_file_section_map(abs_path)
  local lines = file_cache.read(abs_path)
  if not lines then return {} end

  local sections = {}
  -- Stack of { slug, level } for ancestor headings
  local heading_stack = {}
  -- parent_map: child_slug -> parent_slug (immediate parent in heading hierarchy)
  local parent_map = {}
  local in_code_block = false

  for _, line in ipairs(lines) do
    -- Track fenced code blocks to skip link extraction inside them
    if link_utils.is_fence_delimiter(line) then
      in_code_block = not in_code_block
    end

    local level_str, text = line:match(pat.HEADING)
    if level_str then
      local level = #level_str
      local heading_slug = link_utils.heading_to_slug(vim.trim(text))

      -- Pop headings from stack that are same or deeper level
      while #heading_stack > 0
        and heading_stack[#heading_stack].level >= level do
        table.remove(heading_stack)
      end

      -- Initialize section for this heading
      if not sections[heading_slug] then
        sections[heading_slug] = {}
      end

      -- Record parent relationship (top of stack after popping is the parent)
      if #heading_stack > 0 then
        parent_map[heading_slug] = heading_stack[#heading_stack].slug
      end

      -- Push this heading onto the stack
      heading_stack[#heading_stack + 1] = {
        slug = heading_slug,
        level = level,
      }
    end

    -- Extract links and add to the current (deepest) heading only (skip code blocks)
    if #heading_stack > 0 and not in_code_block then
      local line_links = extract_line_outlinks(line)
      if #line_links > 0 then
        local current_slug = heading_stack[#heading_stack].slug
        local sec = sections[current_slug]
        for _, lnk in ipairs(line_links) do
          sec[#sec + 1] = lnk
        end
      end
    end
  end

  -- Post-processing: propagate outlinks upward through the heading hierarchy.
  -- Each parent section accumulates all outlinks from its descendant sections.
  -- We snapshot direct link counts first so each section propagates only its
  -- own direct links (not already-propagated descendant links).
  local direct_count = {}
  for slug, links in pairs(sections) do
    direct_count[slug] = #links
  end
  for child_slug, _ in pairs(parent_map) do
    local child_links = sections[child_slug]
    local count = direct_count[child_slug] or 0
    if count > 0 then
      -- Walk up the ancestor chain, appending only direct links to each ancestor
      local ancestor = parent_map[child_slug]
      while ancestor do
        local ancestor_sec = sections[ancestor]
        if ancestor_sec then
          for i = 1, count do
            ancestor_sec[#ancestor_sec + 1] = child_links[i]
          end
        end
        ancestor = parent_map[ancestor]
      end
    end
  end

  return sections
end

--- Get outlinks from a specific heading section of a note.
--- Uses generation-aware cache to avoid redundant disk reads.
---@param entry table VaultIndexEntry
---@param heading string heading text to scope to
---@param index table|nil VaultIndex instance (for generation tracking)
---@return table[] outlinks within the section
local function get_section_outlinks(entry, heading, index)
  -- Note: cache invalidation is handled once per evaluate() call in search_filter.lua.
  -- Callers outside evaluate() should call invalidate_section_cache() themselves.

  local rel = entry.rel_path

  -- Populate file cache on first access
  local cached = _section_cache:get(rel)
  if cached then
    _section_cache_hits = _section_cache_hits + 1
  else
    _section_cache_misses = _section_cache_misses + 1
    cached = {
      sections = build_file_section_map(entry.abs_path),
    }
    _section_cache:put(rel, cached)
  end

  local heading_slug = link_utils.heading_to_slug(heading)
  return cached.sections[heading_slug] or {}
end

--- Match an entry's tags against include/exclude lists.
--- An entry matches if ANY include tag matches (hierarchical) AND
--- NO exclude tag matches (hierarchical).
---@param entry_tags string[]|nil tags from the vault index entry
---@param includes string[] tags that must match (at least one)
---@param excludes string[] tags that must NOT match (none)
---@return boolean
local function match_tag_filter(entry_tags, includes, excludes)
  if not entry_tags or #entry_tags == 0 then return false end
  return filter_utils.matches_include_exclude(includes, excludes, function(filter_tag)
    return vault_index.tag_matches(entry_tags, filter_tag, { case_insensitive = true })
  end)
end

--- Resolve a date filter value, using FilterContext cache when available.
---@param val string|nil date filter value
---@param ctx table|nil FilterContext
---@return number|nil timestamp
local function resolve_date_cached(val, ctx)
  if not val then return nil end
  if ctx then
    local cached = ctx.resolved_dates[val]
    if cached ~= nil then return cached or nil end
  end
  return date_utils.resolve_date(val)
end

--- Match a field AST node against an entry.
---@param node table field AST node { name, op, value, value2 }
---@param entry table VaultIndexEntry
---@param index table|nil VaultIndex instance (needed for links-to/linked-from)
---@param ctx table|nil FilterContext with pre-resolved values
---@return boolean
function M.match_field(node, entry, index, ctx)
  local name = node.name
  local op = node.op
  local filter_val = node.value
  local filter_val2 = node.value2

  -- Empty value with = operator means "field exists"
  if op == "=" and (filter_val == nil or filter_val == "") then
    return field_exists(name, entry)
  end

  -- ── type ──
  if name == "type" then
    local entry_val = entry.frontmatter and entry.frontmatter.type
    if op == "=" then
      local fv = cached_lower(node, "_type_val_lower", filter_val)
      local ev = entry_val and tostring(entry_val):lower() or nil
      return ev == fv
    end
    return false
  end

  -- ── tag ──
  if name == "tag" then
    if op ~= "=" then return false end
    -- Bloom filter early-out: skip full match if bloom says definitely absent
    -- Skip if extract_pre_checks already performed this bloom check for this node
    if config.prefilter.enabled and config.prefilter.bloom_filter and index
      and not (ctx and ctx.bloom_pre_checked and ctx.bloom_pre_checked[node]) then
      local blooms = index._tag_blooms
      if blooms then
        local bloom = blooms[entry.rel_path]
        if bloom then
          local bloom_mod = require("andrew.vault.bloom_filter")
          local check_tag = cached_lower(node, "_tag_bloom_lower", filter_val)
          -- Strip exclude markers for bloom check (only check first include tag)
          local first = check_tag:match("^([^!,]+)")
          if first then
            first = vim.trim(first)
            if not bloom_mod.maybe_contains(bloom, first) then
              return false
            end
          end
        elseif not entry.tags or #entry.tags == 0 then
          return false
        end
      end
    end
    local includes, excludes
    local cached = ctx and ctx.parsed_tags[filter_val]
    if cached then
      includes, excludes = cached[1], cached[2]
    else
      includes, excludes = filter_utils.parse_tag_filter(filter_val)
    end
    return match_tag_filter(entry.tags, includes, excludes)
  end

  -- ── path ──
  if name == "path" then
    if op ~= "=" then return false end
    if not entry.rel_path then return false end
    -- Prefix match, case-sensitive
    return entry.rel_path:sub(1, #filter_val) == filter_val
  end

  -- ── file ──
  if name == "file" then
    if op ~= "=" then return false end
    if not entry.basename then return false end
    -- Case-insensitive substring match (use pre-lowered basename from index)
    local bn_lower = entry.basename_lower
    local fv_lower = cached_lower(node, "_file_val_lower", filter_val)
    return bn_lower:find(fv_lower, 1, true) ~= nil
  end

  -- ── folder ──
  if name == "folder" then
    if op ~= "=" then return false end
    if not entry.folder then return false end
    -- Exact match or slash-terminated prefix (e.g. folder:Projects matches Projects/Alpha)
    return entry.folder == filter_val
      or entry.folder:sub(1, #filter_val + 1) == filter_val .. "/"
  end

  -- ── links-to ──
  if name == "links-to" then
    if op ~= "=" then return false end
    if not index then return false end

    local parsed_target = link_utils.parse_target(filter_val)
    local target_name, target_heading = parsed_target.name, parsed_target.heading

    -- Empty note name with heading (e.g., "#Heading") is not meaningful for cross-file search
    if target_name == "" then return false end

    -- Cache resolved target on AST node (same node reused across all entries).
    -- Use memoized resolver from FilterContext when available to deduplicate
    -- across different AST nodes that reference the same link path.
    local target_rel = node._links_to_target_rel
    if target_rel == nil then
      local resolver = ctx and ctx.resolve_link
      target_rel = (resolver and resolver(target_name)
        or filter_utils.resolve_in_index(index, target_name)) or false
      node._links_to_target_rel = target_rel
    end
    if not target_rel then return false end

    if not target_heading then
      -- No heading: use existing fast inlinks path
      local inlinks = index:get_inlinks(target_rel)
      local source_stem = entry.rel_stem
      for _, inlink in ipairs(inlinks) do
        if inlink.path == source_stem then
          return true
        end
      end
      return false
    end

    -- Heading specified: scan outlinks of the candidate entry
    local target_heading_slug = link_utils.heading_to_slug(target_heading)
    local target_entry = index.files[target_rel]
    if not target_entry then return false end
    -- Use pre-computed lowercase fields from the target entry
    local target_name_lower = node._links_to_target_lower
    if not target_name_lower then target_name_lower = cached_lower(node, "_links_to_target_lower", target_name) end
    local target_stem_lower = target_entry.rel_stem_lower
    local target_stem_basename_lower = target_entry.basename_lower
    for _, link in ipairs(entry.outlinks or {}) do
      local raw = link.path or ""
      local link_heading = raw:match("#([^#^|]+)")
      if link_heading then
        local link_name_lower = get_link_name_lower(link)
        -- Check if this outlink points to our target note
        local matches_note = link_name_lower == target_name_lower
          or link_name_lower == target_stem_lower
          or link_name_lower == target_stem_basename_lower
        if matches_note then
          local link_heading_slug = link_utils.heading_to_slug(link_heading)
          if link_heading_slug == target_heading_slug then
            return true
          end
        end
      end
    end
    return false
  end

  -- ── linked-from ──
  if name == "linked-from" then
    if op ~= "=" then return false end
    if not index then return false end

    local parsed_target = link_utils.parse_target(filter_val)
    local source_name, source_heading = parsed_target.name, parsed_target.heading
    if source_name == "" then return false end

    -- Cache resolved source on AST node (same node reused across all entries).
    -- Use memoized resolver from FilterContext when available to deduplicate
    -- across different AST nodes that reference the same link path.
    local source_rel = node._linked_from_source_rel
    if source_rel == nil then
      local resolver = ctx and ctx.resolve_link
      source_rel = (resolver and resolver(source_name)
        or filter_utils.resolve_in_index(index, source_name)) or false
      node._linked_from_source_rel = source_rel
    end
    if not source_rel then return false end

    if not source_heading then
      -- No heading: use existing inlinks path
      local inlinks = index:get_inlinks(entry.rel_path)
      local source_entry = index.files[source_rel]
      local source_stem = source_entry and source_entry.rel_stem or link_utils.rel_to_stem(source_rel)
      for _, inlink in ipairs(inlinks) do
        if inlink.path == source_stem then
          return true
        end
      end
      return false
    end

    -- Heading specified: find outlinks within the heading section of source
    local source_entry = index.files[source_rel]
    if not source_entry then return false end

    local section_outlinks = get_section_outlinks(source_entry, source_heading, index)
    local entry_basename_lower = entry.basename_lower
    local entry_stem_lower = entry.rel_stem_lower

    for _, link in ipairs(section_outlinks) do
      local link_name = get_link_name_lower(link)
      if link_name == entry_basename_lower or link_name == entry_stem_lower then
        return true
      end
    end
    return false
  end

  -- ── alias ──
  if name == "alias" then
    if op ~= "=" then return false end
    if not entry.aliases or #entry.aliases == 0 then return false end
    local lower_val = cached_lower(node, "_alias_val_lower", filter_val)
    for _, a in ipairs(entry.aliases) do
      if a == lower_val then
        return true
      end
    end
    return false
  end

  -- ── status ──
  if name == "status" then
    local entry_val = (entry.frontmatter and entry.frontmatter.status)
      or (entry.inline_fields and entry.inline_fields.status)
    if op == "=" then
      local fv = cached_lower(node, "_status_val_lower", filter_val)
      local ev = entry_val and tostring(entry_val):lower() or nil
      return ev == fv
    end
    return false
  end

  -- ── priority ──
  if name == "priority" then
    local entry_val = (entry.frontmatter and entry.frontmatter.priority)
      or (entry.inline_fields and entry.inline_fields.priority)
    local num_entry = tonumber(entry_val)
    local num_filter = tonumber_cached(filter_val, ctx)
    if not num_entry or not num_filter then return false end
    if op == ".." then
      local num_filter2 = tonumber_cached(filter_val2, ctx)
      if not num_filter2 then return false end
      return in_num_range(num_entry, num_filter, num_filter2)
    end
    return compare_num(num_entry, op, num_filter)
  end

  -- ── created / modified ──
  if name == "created" or name == "modified" then
    local entry_ts = parse_entry_date(entry, name)
    if not entry_ts then return false end
    if op == "=" then
      local range_match = date_utils.in_keyword_range(entry_ts, filter_val)
      if range_match ~= nil then return range_match end
      local filter_ts = resolve_date_cached(filter_val, ctx)
      if not filter_ts then return false end
      return same_day(entry_ts, filter_ts)
    end
    local filter_ts = resolve_date_cached(filter_val, ctx)
    if not filter_ts then return false end
    if op == ".." then
      local filter_ts2 = resolve_date_cached(filter_val2, ctx)
      if not filter_ts2 then return false end
      return date_utils.in_date_range(entry_ts, filter_ts, filter_ts2)
    end
    return compare_date(entry_ts, op, filter_ts, filter_val)
  end

  -- ── day ──
  if name == "day" then
    if not entry.day then return false end
    if op == "=" then
      if entry.day == filter_val then return true end
      local entry_ts = entry.day_ts or date_utils.parse_iso_datetime(entry.day)
      if not entry_ts then return false end
      local range_match = date_utils.in_keyword_range(entry_ts, filter_val)
      if range_match ~= nil then return range_match end
      local resolved = resolve_date_cached(filter_val, ctx)
      if resolved then return same_day(entry_ts, resolved) end
      return false
    end
    -- For comparison/range operators, parse both sides as dates
    local entry_ts = parse_entry_date(entry, "day")
    local filter_ts = resolve_date_cached(filter_val, ctx)
    if not entry_ts or not filter_ts then return false end
    if op == ".." then
      local filter_ts2 = resolve_date_cached(filter_val2, ctx)
      if not filter_ts2 then return false end
      return date_utils.in_date_range(entry_ts, filter_ts, filter_ts2)
    end
    return compare_date(entry_ts, op, filter_ts, filter_val)
  end

  -- ── Generic (unknown) fields ──
  local entry_val = get_generic_field(entry, name)
  if entry_val == nil then return false end

  local num_entry = tonumber(entry_val)
  local num_filter = tonumber_cached(filter_val, ctx)

  if op == ".." then
    if num_entry and num_filter then
      local num_filter2 = tonumber_cached(filter_val2, ctx)
      if not num_filter2 then return false end
      return in_num_range(num_entry, num_filter, num_filter2)
    end
    -- String range: lexicographic, case-insensitive
    local lo = cached_lower(node, "_range_lo_lower", filter_val)
    local hi = cached_lower(node, "_range_hi_lower", filter_val2 or "")
    local s = tostring(entry_val):lower()
    return lo <= s and s <= hi
  end

  if op == "=" then
    if num_entry and num_filter then
      return num_entry == num_filter
    end
    local fv = cached_lower(node, "_generic_eq_lower", filter_val)
    return tostring(entry_val):lower() == fv
  end

  -- Ordered comparisons: try numeric first, then date, then fail
  if num_entry and num_filter then
    return compare_num(num_entry, op, num_filter)
  end
  local entry_ts = date_utils.parse_iso_datetime(tostring(entry_val))
  local filter_ts = resolve_date_cached(filter_val, ctx)
  if entry_ts and filter_ts then
    return compare_date(entry_ts, op, filter_ts, filter_val)
  end

  return false
end

--- Clear the section outlinks cache and intern pool.
function M.clear_section_cache()
  _section_cache:clear()
  string_intern.clear(_lowercase_pool)
  _section_cache_generation = -1
end

--- Return stats for the section outlinks cache (for engine registry).
---@return { entries: number, total_bytes: number, max_bytes: number }
function M.section_cache_stats()
  local s = _section_cache:stats()
  return {
    entries = s.items,
    total_bytes = s.total_bytes,
    max_bytes = s.max_bytes,
  }
end

do
  local profiler = require("andrew.vault.memory_profiler")
  profiler.register_cache({
    name = "section_outlinks",
    get_size = function()
      local s = _section_cache:stats()
      return s.items or 0
    end,
    get_capacity = function() return config.cache.section_cache_max end,
    get_hits = function() return _section_cache_hits end,
    get_misses = function() return _section_cache_misses end,
    get_evictions = function() return _section_cache_evictions end,
    get_bytes = function()
      local s = _section_cache:stats()
      return s.total_bytes or 0
    end,
    get_max_bytes = function() return config.cache.section_outlinks_bytes end,
  })
end

return M
