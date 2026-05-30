--- Hierarchical summary index for the vault.
---
--- Uses the natural directory hierarchy as a tree structure where every
--- directory becomes an interior node and every file becomes a leaf node.
--- Each node caches an aggregate summary of its subtree, enabling O(D*C_avg)
--- updates instead of O(N) full iteration.
local M = {}
local log = require("andrew.vault.vault_log").scope("summary_tree")

--- @class SummaryNode
--- @field path string
--- @field is_leaf boolean
--- @field file_count number
--- @field tag_counts table<string, number>
--- @field tag_file_counts table<string, number>
--- @field fm_key_counts table<string, number>
--- @field task_count number
--- @field task_status_counts table<string, number>
--- @field link_count number
--- @field heading_count number
--- @field alias_count number
--- @field block_id_count number
--- @field children table<string, SummaryNode>|nil

local SummaryTree = {}
SummaryTree.__index = SummaryTree

--- Split a relative path into directory segments and filename.
--- "daily/2024-01-01.md" -> {"daily"}, "2024-01-01.md"
--- "notes.md" -> {}, "notes.md"
local function split_path(rel_path)
  local segments = {}
  for seg in rel_path:gmatch("([^/]+)") do
    segments[#segments + 1] = seg
  end
  local filename = table.remove(segments)
  return segments, filename
end

--- Compute a leaf summary from a vault index entry.
--- @param entry table Vault index entry (from self.files[rel_path])
--- @return table summary fields
local function entry_to_summary(entry)
  local tag_counts = {}
  local tag_file_counts = {}
  for _, tag in ipairs(entry.tags or {}) do
    tag_counts[tag] = (tag_counts[tag] or 0) + 1
    tag_file_counts[tag] = 1 -- each file counts once per tag for IDF
  end

  local fm_key_counts = {}
  if entry.frontmatter then
    for key, _ in pairs(entry.frontmatter) do
      fm_key_counts[key] = 1
    end
  end

  local task_status_counts = {}
  for _, task in ipairs(entry.tasks or {}) do
    local mark = task.status or " "
    task_status_counts[mark] = (task_status_counts[mark] or 0) + 1
  end

  return {
    file_count = 1,
    tag_counts = tag_counts,
    tag_file_counts = tag_file_counts,
    fm_key_counts = fm_key_counts,
    task_count = #(entry.tasks or {}),
    task_status_counts = task_status_counts,
    link_count = #(entry.outlinks or {}),
    heading_count = #(entry.headings or {}),
    alias_count = #(entry.aliases or {}),
    block_id_count = #(entry.block_ids or {}),
  }
end

--- Compose summaries from a set of children nodes (element-wise sum).
--- @param children table<string, SummaryNode>
--- @return table composed summary fields
local function compose_summaries(children)
  local summary = {
    file_count = 0,
    tag_counts = {},
    tag_file_counts = {},
    fm_key_counts = {},
    task_count = 0,
    task_status_counts = {},
    link_count = 0,
    heading_count = 0,
    alias_count = 0,
    block_id_count = 0,
  }
  for _, child in pairs(children) do
    summary.file_count = summary.file_count + child.file_count
    summary.task_count = summary.task_count + child.task_count
    summary.link_count = summary.link_count + child.link_count
    summary.heading_count = summary.heading_count + child.heading_count
    summary.alias_count = summary.alias_count + child.alias_count
    summary.block_id_count = summary.block_id_count + child.block_id_count
    for tag, count in pairs(child.tag_counts) do
      summary.tag_counts[tag] = (summary.tag_counts[tag] or 0) + count
    end
    for tag, count in pairs(child.tag_file_counts) do
      summary.tag_file_counts[tag] = (summary.tag_file_counts[tag] or 0) + count
    end
    for key, count in pairs(child.fm_key_counts) do
      summary.fm_key_counts[key] = (summary.fm_key_counts[key] or 0) + count
    end
    for mark, count in pairs(child.task_status_counts) do
      summary.task_status_counts[mark] = (summary.task_status_counts[mark] or 0) + count
    end
  end
  return summary
end

local function make_dir_node(path)
  return {
    path = path,
    is_leaf = false,
    file_count = 0,
    tag_counts = {},
    tag_file_counts = {},
    fm_key_counts = {},
    task_count = 0,
    task_status_counts = {},
    link_count = 0,
    heading_count = 0,
    alias_count = 0,
    block_id_count = 0,
    children = {},
  }
end

--- Create a new SummaryTree.
--- @return table SummaryTree instance
function M.new()
  local self = setmetatable({}, SummaryTree)
  self.root = make_dir_node("")
  self._batch_dirty = nil
  return self
end

--- Ensure all directory nodes along the path exist, return the parent dir node.
--- @param segments string[] directory path segments
--- @return table dir node
function SummaryTree:_ensure_dirs(segments)
  local node = self.root
  for _, seg in ipairs(segments) do
    if not node.children[seg] then
      local dir_path = node.path == "" and seg .. "/" or node.path .. seg .. "/"
      node.children[seg] = make_dir_node(dir_path)
    end
    node = node.children[seg]
  end
  return node
end

--- Recompute summaries for all ancestor directory nodes of a path.
--- Walks from deepest directory up to root.
--- @param segments string[] directory path segments
function SummaryTree:_recompute_ancestors(segments)
  local path_nodes = { self.root }
  local node = self.root
  for _, seg in ipairs(segments) do
    node = node.children[seg]
    if not node then return end
    path_nodes[#path_nodes + 1] = node
  end

  for i = #path_nodes, 1, -1 do
    local dir_node = path_nodes[i]
    local composed = compose_summaries(dir_node.children)
    dir_node.file_count = composed.file_count
    dir_node.tag_counts = composed.tag_counts
    dir_node.tag_file_counts = composed.tag_file_counts
    dir_node.fm_key_counts = composed.fm_key_counts
    dir_node.task_count = composed.task_count
    dir_node.task_status_counts = composed.task_status_counts
    dir_node.link_count = composed.link_count
    dir_node.heading_count = composed.heading_count
    dir_node.alias_count = composed.alias_count
    dir_node.block_id_count = composed.block_id_count
  end
end

--- Remove empty directory nodes upward from the deepest segment.
--- @param segments string[] directory path segments
function SummaryTree:_prune_empty(segments)
  local path_nodes = { self.root }
  local node = self.root
  for _, seg in ipairs(segments) do
    node = node.children and node.children[seg]
    if not node then break end
    path_nodes[#path_nodes + 1] = node
  end

  for i = #path_nodes, 2, -1 do
    local dir_node = path_nodes[i]
    if dir_node.file_count == 0 and not dir_node.is_leaf then
      local parent = path_nodes[i - 1]
      local seg = segments[i - 1]
      parent.children[seg] = nil
    else
      break
    end
  end
end

--- Recompute a single node identified by its directory path string.
--- Used by batch_end() for deferred recomputation.
--- @param path string directory path (e.g. "daily/" or "" for root)
function SummaryTree:_recompute_node(path)
  local node
  if path == "" then
    node = self.root
  else
    node = self.root
    for seg in path:gmatch("([^/]+)") do
      node = node.children and node.children[seg]
      if not node then return end
    end
  end
  if node.is_leaf then return end

  local composed = compose_summaries(node.children)
  node.file_count = composed.file_count
  node.tag_counts = composed.tag_counts
  node.tag_file_counts = composed.tag_file_counts
  node.fm_key_counts = composed.fm_key_counts
  node.task_count = composed.task_count
  node.task_status_counts = composed.task_status_counts
  node.link_count = composed.link_count
  node.heading_count = composed.heading_count
  node.alias_count = composed.alias_count
  node.block_id_count = composed.block_id_count
end

--- Update or insert a file's summary in the tree.
--- @param rel_path string Relative file path (e.g. "daily/2024-01-01.md")
--- @param entry table Vault index entry for this file
function SummaryTree:update(rel_path, entry)
  local segments, filename = split_path(rel_path)
  if not filename then
    log.warn("update called with directory path: " .. rel_path)
    return
  end

  local parent = self:_ensure_dirs(segments)
  local summary = entry_to_summary(entry)
  summary.path = rel_path
  summary.is_leaf = true
  summary.children = nil
  parent.children[filename] = summary

  self:_recompute_ancestors(segments)
end

--- Remove a file from the tree.
--- @param rel_path string
function SummaryTree:remove(rel_path)
  local segments, filename = split_path(rel_path)
  if not filename then return end

  local parent = self:_ensure_dirs(segments)
  if not parent.children[filename] then return end

  parent.children[filename] = nil
  self:_recompute_ancestors(segments)
  self:_prune_empty(segments)
end

--- Begin a batch update. Defers ancestor recomputation until batch_end().
function SummaryTree:batch_begin()
  self._batch_dirty = {}
end

--- Update a file during a batch (deferred ancestor recomputation).
--- @param rel_path string
--- @param entry table Vault index entry
function SummaryTree:batch_update(rel_path, entry)
  local segments, filename = split_path(rel_path)
  if not filename then return end

  local parent = self:_ensure_dirs(segments)
  local summary = entry_to_summary(entry)
  summary.path = rel_path
  summary.is_leaf = true
  summary.children = nil
  parent.children[filename] = summary

  -- Mark ancestor chain as dirty
  for i = 1, #segments do
    self._batch_dirty[table.concat(segments, "/", 1, i)] = true
  end
  self._batch_dirty[""] = true -- root always dirty
end

--- Remove a file during a batch (deferred ancestor recomputation).
--- @param rel_path string
function SummaryTree:batch_remove(rel_path)
  local segments, filename = split_path(rel_path)
  if not filename then return end

  local parent = self:_ensure_dirs(segments)
  if not parent.children[filename] then return end

  parent.children[filename] = nil

  for i = 1, #segments do
    self._batch_dirty[table.concat(segments, "/", 1, i)] = true
  end
  self._batch_dirty[""] = true
end

--- Finish a batch update. Recomputes all dirty nodes (deepest first).
function SummaryTree:batch_end()
  if not self._batch_dirty then return end

  local sorted = vim.tbl_keys(self._batch_dirty)
  table.sort(sorted, function(a, b) return #a > #b end)
  for _, path in ipairs(sorted) do
    self:_recompute_node(path)
  end

  -- Prune empty dirs after batch
  for _, path in ipairs(sorted) do
    if path ~= "" then
      local node = self.root
      local found = true
      for seg in path:gmatch("([^/]+)") do
        node = node.children and node.children[seg]
        if not node then
          found = false
          break
        end
      end
      if found and node and not node.is_leaf and node.file_count == 0 then
        -- Find parent and remove
        local segments = {}
        for seg in path:gmatch("([^/]+)") do
          segments[#segments + 1] = seg
        end
        self:_prune_empty(segments)
      end
    end
  end

  self._batch_dirty = nil
end

--- Query aggregate summary for a directory prefix.
--- @param dir_prefix string e.g. "daily/", "projects/alpha/", or "" for whole vault
--- @return SummaryNode|nil snapshot of the node's summary (no children)
function SummaryTree:query(dir_prefix)
  if dir_prefix == "" then
    return self:_snapshot(self.root)
  end

  local node = self.root
  for seg in dir_prefix:gmatch("([^/]+)") do
    node = node.children and node.children[seg]
    if not node then return nil end
  end

  return self:_snapshot(node)
end

--- Return a read-only view of a node's summary fields (no children reference).
--- Callers must NOT mutate the returned tables (tag_counts, etc.) — they are
--- direct references to the tree's internal state for zero-copy performance.
--- @param node SummaryNode
--- @return table summary snapshot
function SummaryTree:_snapshot(node)
  return {
    path = node.path,
    file_count = node.file_count,
    tag_counts = node.tag_counts,
    tag_file_counts = node.tag_file_counts,
    fm_key_counts = node.fm_key_counts,
    task_count = node.task_count,
    task_status_counts = node.task_status_counts,
    link_count = node.link_count,
    heading_count = node.heading_count,
    alias_count = node.alias_count,
    block_id_count = node.block_id_count,
  }
end

--- Build the entire tree from a files table (used during load/cold start).
--- @param files table<string, table> rel_path -> vault index entry
function SummaryTree:build_from_files(files)
  self.root = make_dir_node("")
  self:batch_begin()
  for rel_path, entry in pairs(files) do
    self:batch_update(rel_path, entry)
  end
  self:batch_end()
  log.debug("summary tree built from " .. self.root.file_count .. " files")
end

return M
