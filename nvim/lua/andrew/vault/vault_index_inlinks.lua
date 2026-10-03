-- vault_index_inlinks.lua — Inlink computation subsystem for vault index
-- Self-contained link resolution. No external dependencies beyond parameters.

local pat = require("andrew.vault.patterns")

local I = {}

--- Add an inlink record from source_entry to a target's inlink list.
--- Also records the reverse edge (source_stem -> target_rel set) so that
--- incremental removal can visit only the targets a source contributed to.
local function add_inlink(inlinks_table, reverse, target_rel, source_entry)
  if not inlinks_table[target_rel] then
    inlinks_table[target_rel] = {}
  end
  local t = inlinks_table[target_rel]
  local stem = source_entry.rel_stem
  t[#t + 1] = {
    path = stem,
    path_lower = source_entry.rel_stem_lower,
    display = source_entry.basename,
  }
  local rset = reverse[stem]
  if not rset then
    rset = {}
    reverse[stem] = rset
  end
  rset[target_rel] = true
end

--- Recompute all inlinks from scratch.
---@param files table<string, VaultIndexEntry>
---@param resolve_fn fun(link: table): table|nil  resolver backed by existing name/alias indexes
---@return table<string, table[]> inlinks map
---@return table<string, table<string, boolean>> reverse map (source_stem -> target_rel set)
function I.recompute(files, resolve_fn)
  local inlinks = {}
  local reverse = {}

  for _, source_entry in pairs(files) do
    for _, link in ipairs(source_entry.outlinks) do
      local target = resolve_fn(link)
      if target and target.rel_path ~= source_entry.rel_path then
        add_inlink(inlinks, reverse, target.rel_path, source_entry)
      end
    end
  end

  return inlinks, reverse
end

--- Incrementally update inlinks for a set of changed/deleted files.
--- Must be called AFTER files table has been updated (new entries in place,
--- deleted entries removed).
---@param files table<string, VaultIndexEntry>
---@param inlinks table<string, table[]> existing inlinks (modified in-place)
---@param reverse table<string, table<string, boolean>> source_stem -> target_rel set (modified in-place)
---@param changed_rel_paths string[] files that were re-parsed (still exist)
---@param deleted_rel_paths string[] files that were removed
---@param resolve_fn fun(link: table): table|nil  resolver backed by existing name/alias indexes
---@param outlinks_changed_set table<string, boolean>|nil  set of changed
---  rel_paths whose outlink SET actually changed. A changed source NOT in this
---  set contributes byte-identical inlink edges, so removing+re-adding them is
---  pure churn that yields an identical result — those sources are skipped in
---  BOTH phases (net zero). Deleted sources are always processed. When nil,
---  every changed source is processed (back-compat behavior).
function I.recompute_incremental(files, inlinks, reverse, changed_rel_paths, deleted_rel_paths, resolve_fn, outlinks_changed_set)
  -- Collect all affected source rel_paths: changed sources whose outlinks
  -- actually changed, plus ALL deleted sources (their edges must be removed).
  local affected_sources = {}
  for _, rel_path in ipairs(changed_rel_paths) do
    if not outlinks_changed_set or outlinks_changed_set[rel_path] then
      affected_sources[rel_path] = true
    end
  end
  for _, rel_path in ipairs(deleted_rel_paths) do
    affected_sources[rel_path] = true
  end

  -- Phase 1: Remove old inlink contributions from affected sources.
  -- Using the reverse map, visit ONLY the targets each affected source
  -- contributed to (O(edges-from-changed-files)) rather than sweeping every
  -- target in the vault.
  local affected_source_stems = {}
  for rel_path in pairs(affected_sources) do
    local entry = files[rel_path]
    affected_source_stems[entry and entry.rel_stem or rel_path:gsub(pat.MD_EXTENSION, "")] = true
  end

  for stem in pairs(affected_source_stems) do
    local targets = reverse[stem]
    if targets then
      for target_rel in pairs(targets) do
        local inlink_list = inlinks[target_rel]
        if inlink_list then
          local j = 1
          for i = 1, #inlink_list do
            if not affected_source_stems[inlink_list[i].path] then
              if j ~= i then
                inlink_list[j] = inlink_list[i]
              end
              j = j + 1
            end
          end
          -- Trim the list
          for i = j, #inlink_list do
            inlink_list[i] = nil
          end
          -- Remove empty lists
          if #inlink_list == 0 then
            inlinks[target_rel] = nil
          end
        end
      end
      -- Clear reverse edges for this source; Phase 2 rebuilds them for
      -- changed (non-deleted) sources. Deleted sources stay cleared.
      reverse[stem] = nil
    end
  end

  -- Phase 2: Add new inlink contributions for changed (non-deleted) files.
  -- A source skipped here (outlinks unchanged) was also skipped in Phase 1, so
  -- its existing reverse edges and inlink records are untouched — net zero.
  if #changed_rel_paths > 0 then
    for _, source_rel in ipairs(changed_rel_paths) do
      local source_entry = files[source_rel]
      if source_entry and (not outlinks_changed_set or outlinks_changed_set[source_rel]) then
        for _, link in ipairs(source_entry.outlinks) do
          local target = resolve_fn(link)
          if target and target.rel_path ~= source_entry.rel_path then
            add_inlink(inlinks, reverse, target.rel_path, source_entry)
          end
        end
      end
    end
  end
end

return I
