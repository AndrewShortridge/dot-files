--- Weigher functions for memory-weighted LRU caches.
--- Each weigher estimates the byte size of a cache entry (key + value).
--- Used with lru_cache.new_weighted().
local M = {}

--- Lines entry: { lines = string[], mtime = number }
--- Used by: file_cache._cache (file content) and file_cache._section_cache (sections)
function M.file_content(key, entry)
  local size = #key + 64 -- key + table overhead + mtime
  if entry.lines then
    for _, line in ipairs(entry.lines) do
      size = size + #line + 16 -- string header + array pointer
    end
  end
  return size
end

M.section_lines = M.file_content

--- Connection result: { source_path, results, deps, timestamp, index_gen }
--- Used by: connections._cache
function M.connections(key, entry)
  local size = #key + 128 -- key + table overhead + source_path + timestamp + index_gen
  if entry.results then
    for _, r in ipairs(entry.results) do
      size = size + #(r.rel_path or "") + #(r.title or "") + 120
    end
  end
  if entry.deps then
    for dep_path in pairs(entry.deps) do
      size = size + #dep_path + 32
    end
  end
  return size
end

--- Note data: ConnectionNoteData with tags, outlinks, inlinks, neighbors, fm_fields
--- Used by: connections._note_data_cache
function M.note_data(key, data)
  local size = #key + 128
  if data.tags then
    for tag in pairs(data.tags) do size = size + #tag + 24 end
  end
  if data.outlink_targets then
    for path in pairs(data.outlink_targets) do size = size + #path + 24 end
  end
  if data.inlink_sources then
    for path in pairs(data.inlink_sources) do size = size + #path + 24 end
  end
  if data.neighbors then
    for path in pairs(data.neighbors) do size = size + #path + 24 end
  end
  if data.fm_fields then
    for k, v in pairs(data.fm_fields) do
      size = size + #k + #tostring(v) + 32
    end
  end
  return size
end

--- Section outlinks: { sections = { heading_slug -> outlinks[] } }
--- Used by: search_filter/match_field._section_cache
function M.section_outlinks(key, data)
  local size = #key + 64
  if data.sections then
    for slug, links in pairs(data.sections) do
      size = size + #slug + 32
      for _, link in ipairs(links) do
        size = size + #(link.path or "") + #(link._name_lower or "") + 48
      end
    end
  end
  return size
end

--- BFS traversal results (BfsCacheEntry)
--- Used by: graph_filter/traversal._bfs_cache
function M.bfs_result(key, result)
  local size = #key + 128
  if result.state_hash then size = size + #result.state_hash end
  if result.visited then
    for path in pairs(result.visited) do size = size + #path + 24 end
  end
  if result.frontier then
    for _, f in ipairs(result.frontier) do
      size = size + #(f.rel or "") + 48
    end
  end
  if result.forward_like then
    for _, n in ipairs(result.forward_like) do size = size + #(n.name or "") + #(n.path or "") + 48 end
  end
  if result.backlink_like then
    for _, n in ipairs(result.backlink_like) do size = size + #(n.name or "") + #(n.path or "") + 48 end
  end
  if result.all_nodes then
    for _, n in ipairs(result.all_nodes) do size = size + #(n.name or "") + #(n.path or "") + 48 end
  end
  return size
end

return M
