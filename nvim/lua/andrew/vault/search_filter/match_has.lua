--- has: node matching for search filter pipeline.

local config = require("andrew.vault.config")

local M = {}

--- Match a has: node against an entry.
---@param node table has AST node { target = string }
---@param entry table VaultIndexEntry
---@param index table VaultIndex instance (for _inlinks lookup)
---@return boolean
function M.match_has(node, entry, index)
  local target = node.target
  local use_sets = config.prefilter.enabled and config.prefilter.precomputed_sets

  if target == "tags" then
    if use_sets and index and index._files_with_tags then
      return index._files_with_tags[entry.rel_path] == true
    end
    return entry.tags ~= nil and #entry.tags > 0
  end

  if target == "aliases" then
    return entry.aliases ~= nil and #entry.aliases > 0
  end

  if target == "tasks" then
    if use_sets and index and index._files_with_tasks then
      return index._files_with_tasks[entry.rel_path] == true
    end
    return entry.tasks ~= nil and #entry.tasks > 0
  end

  if target == "outlinks" then
    return entry.outlinks ~= nil and #entry.outlinks > 0
  end

  if target == "inlinks" then
    local inlinks = index and index:get_inlinks(entry.rel_path)
    return inlinks ~= nil and #inlinks > 0
  end

  if target == "frontmatter" then
    if not entry.frontmatter then return false end
    return next(entry.frontmatter) ~= nil
  end

  -- Unknown has: target -- check if the entry has a non-empty field by that name
  local val = entry[target]
    or (entry.frontmatter and entry.frontmatter[target])
    or (entry.inline_fields and entry.inline_fields[target])
  if type(val) == "table" then return next(val) ~= nil end
  return val ~= nil
end

return M
