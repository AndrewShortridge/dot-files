-- vault_index_inlinks.lua — Inlink computation subsystem for vault index
-- Self-contained link resolution. No external dependencies beyond parameters.

local pat = require("andrew.vault.patterns")

local I = {}

--- Add an inlink record from source_entry to a target's inlink list.
local function add_inlink(inlinks_table, target_rel, source_entry)
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
end

--- Recompute all inlinks from scratch.
---@param files table<string, VaultIndexEntry>
---@param resolve_fn fun(link: table): table|nil  resolver backed by existing name/alias indexes
---@return table<string, table[]> inlinks map
function I.recompute(files, resolve_fn)
  local inlinks = {}

  for _, source_entry in pairs(files) do
    for _, link in ipairs(source_entry.outlinks) do
      local target = resolve_fn(link)
      if target and target.rel_path ~= source_entry.rel_path then
        add_inlink(inlinks, target.rel_path, source_entry)
      end
    end
  end

  return inlinks
end

--- Incrementally update inlinks for a set of changed/deleted files.
--- Must be called AFTER files table has been updated (new entries in place,
--- deleted entries removed).
---@param files table<string, VaultIndexEntry>
---@param inlinks table<string, table[]> existing inlinks (modified in-place)
---@param changed_rel_paths string[] files that were re-parsed (still exist)
---@param deleted_rel_paths string[] files that were removed
---@param resolve_fn fun(link: table): table|nil  resolver backed by existing name/alias indexes
function I.recompute_incremental(files, inlinks, changed_rel_paths, deleted_rel_paths, resolve_fn)
  -- Collect all affected source rel_paths (both changed and deleted)
  local affected_sources = {}
  for _, rel_path in ipairs(changed_rel_paths) do
    affected_sources[rel_path] = true
  end
  for _, rel_path in ipairs(deleted_rel_paths) do
    affected_sources[rel_path] = true
  end

  -- Phase 1: Remove old inlink contributions from affected sources.
  local affected_source_stems = {}
  for rel_path in pairs(affected_sources) do
    local entry = files[rel_path]
    affected_source_stems[entry and entry.rel_stem or rel_path:gsub(pat.MD_EXTENSION, "")] = true
  end

  for target_rel, inlink_list in pairs(inlinks) do
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

  -- Phase 2: Add new inlink contributions for changed (non-deleted) files.
  if #changed_rel_paths > 0 then
    for _, source_rel in ipairs(changed_rel_paths) do
      local source_entry = files[source_rel]
      if source_entry then
        for _, link in ipairs(source_entry.outlinks) do
          local target = resolve_fn(link)
          if target and target.rel_path ~= source_entry.rel_path then
            add_inlink(inlinks, target.rel_path, source_entry)
          end
        end
      end
    end
  end
end

return I
