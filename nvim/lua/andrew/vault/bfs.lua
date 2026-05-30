--- Shared BFS traversal for vault graph operations.
--- Generic breadth-first search over vault index link graph.
--- Used by graph_filter/traversal.lua and search_filter/graph_traversal.lua.

local render_arena = require("andrew.vault.render_arena")

local M = {}

---@class BfsOpts
---@field index table VaultIndex instance
---@field frontier table[] initial queue items (must have .rel and .d fields)
---@field max_depth number maximum BFS depth
---@field max_nodes number maximum discovered nodes
---@field resolve fun(link_path: string): string|nil memoized link resolver
---@field visited table<string, true> visited set (mutated in place)
---@field initial_count? number starting node count (default 0)
---@field process_outlinks? boolean follow outlinks (default true)
---@field process_inlinks? boolean follow inlinks (default true)
---@field on_discover fun(rel: string, entry: table, depth: number, link_type: "outlink"|"inlink", parent: table): table|true|nil
---@field arena_scope? integer optional render_arena scope for ephemeral allocations
---   Called when an unvisited node with a valid index entry is found.
---   Return true to accept, a table of extra queue-item fields to merge, or nil/false to reject.

---@class BfsResult
---@field node_count number total discovered nodes
---@field truncated boolean true if max_nodes cap was reached with items remaining
---@field frontier table[] unconsumed queue items (for incremental extension)

--- Process outlinks and inlinks for a single BFS node.
--- Discovers neighbors, marks visited, and enqueues new items.
---@param current table current queue item with .rel and .d
---@param idx table VaultIndex instance
---@param resolve function link resolver
---@param visited table<string, true> visited set (mutated)
---@param on_discover function discovery callback
---@param do_outlinks boolean follow outlinks
---@param do_inlinks boolean follow inlinks
---@param queue table BFS queue (mutated)
---@param tail number current queue tail (returned updated)
---@param node_count number current count (returned updated)
---@param max_nodes number cap
---@return number tail updated tail
---@return number node_count updated count
local function process_node_links(current, idx, resolve, visited, on_discover,
    do_outlinks, do_inlinks, queue, tail, node_count, max_nodes)
  local cur_entry = idx:get_entry(current.rel)
  if not cur_entry then return tail, node_count end

  if do_outlinks then
    for _, link in ipairs(cur_entry.outlinks) do
      local link_path = link.path or ""
      local target_rel = resolve(link_path)
      if target_rel and not visited[target_rel] then
        local target_entry = idx:get_entry(target_rel)
        if target_entry then
          local extra = on_discover(target_rel, target_entry, current.d + 1, "outlink", current)
          if extra then
            visited[target_rel] = true
            node_count = node_count + 1
            tail = tail + 1
            local item = { rel = target_rel, d = current.d + 1 }
            if type(extra) == "table" then
              for k, v in pairs(extra) do item[k] = v end
            end
            queue[tail] = item
            if node_count >= max_nodes then return tail, node_count end
          end
        end
      end
    end
  end

  if node_count >= max_nodes then return tail, node_count end

  if do_inlinks then
    local inlinks = idx:get_inlinks(current.rel)
    for _, link in ipairs(inlinks) do
      local source_rel = link.path .. ".md"
      if not visited[source_rel] then
        local source_entry = idx:get_entry(source_rel)
        if source_entry then
          local extra = on_discover(source_rel, source_entry, current.d + 1, "inlink", current)
          if extra then
            visited[source_rel] = true
            node_count = node_count + 1
            tail = tail + 1
            local item = { rel = source_rel, d = current.d + 1 }
            if type(extra) == "table" then
              for k, v in pairs(extra) do item[k] = v end
            end
            queue[tail] = item
            if node_count >= max_nodes then return tail, node_count end
          end
        end
      end
    end
  end

  return tail, node_count
end

--- Collect remaining frontier items from the BFS queue.
---@param queue table BFS queue
---@param head number current head position
---@param tail number current tail position
---@param arena_scope? integer optional arena scope for the container array
---@return table[] frontier unconsumed items
local function collect_frontier(queue, head, tail, arena_scope)
  local frontier = arena_scope and render_arena.alloc_table(arena_scope) or {}
  for i = head, tail do
    if queue[i] then
      frontier[#frontier + 1] = queue[i]
    end
  end
  return frontier
end

--- Core BFS loop shared by sync and async traversals.
--- Sets up the queue from opts.frontier, runs the BFS main loop calling
--- process_node_links for each node, and returns a BfsResult.
---@param opts BfsOpts
---@param iter_hook? fun(): boolean called after each node is processed; return true to break
---@return BfsResult
local function run_bfs_loop(opts, iter_hook)
  local idx = opts.index
  local max_depth = opts.max_depth
  local max_nodes = opts.max_nodes
  local resolve = opts.resolve
  local visited = opts.visited
  local do_outlinks = opts.process_outlinks ~= false
  local do_inlinks = opts.process_inlinks ~= false
  local on_discover = opts.on_discover
  local node_count = opts.initial_count or 0
  local arena = opts.arena_scope

  -- Queue container is ephemeral (items inside are NOT arena-allocated,
  -- as some escape to frontier → cache)
  local queue = arena and render_arena.alloc_table(arena) or {}
  local head, tail = 1, 0
  for _, item in ipairs(opts.frontier) do
    tail = tail + 1
    queue[tail] = item
  end

  while head <= tail and node_count < max_nodes do
    local current = queue[head]
    queue[head] = nil
    head = head + 1

    if current.d < max_depth then
      tail, node_count = process_node_links(current, idx, resolve, visited,
        on_discover, do_outlinks, do_inlinks, queue, tail, node_count, max_nodes)
    end

    if iter_hook and iter_hook() then break end
  end

  -- Frontier array container is ephemeral (consumed by filter_frontier,
  -- then discarded); items inside persist independently
  local result = arena and render_arena.alloc_table(arena) or {}
  result.node_count = node_count
  result.truncated = node_count >= max_nodes and head <= tail
  result.frontier = collect_frontier(queue, head, tail, arena)
  return result
end

--- Build a BFS options table with standard fields.
--- Shared helper to avoid duplicating option construction across consumers.
---@param params table { index, frontier, max_depth, max_nodes, resolve, visited, initial_count?, on_discover, process_outlinks?, process_inlinks?, arena_scope? }
---@return BfsOpts
function M.make_opts(params)
  return {
    index = params.index,
    frontier = params.frontier,
    max_depth = params.max_depth,
    max_nodes = params.max_nodes,
    resolve = params.resolve,
    visited = params.visited,
    initial_count = params.initial_count or 0,
    process_outlinks = params.process_outlinks,
    process_inlinks = params.process_inlinks,
    on_discover = params.on_discover,
    arena_scope = params.arena_scope,
  }
end

--- Initialize a visited set with the center node.
---@param center_rel string center note rel_path
---@return table<string, true>
function M.init_visited(center_rel)
  return { [center_rel] = true }
end

--- Initialize a frontier queue with the center node at depth 0.
---@param center_rel string center note rel_path
---@return table[] frontier queue
function M.init_frontier(center_rel)
  return { { rel = center_rel, d = 0 } }
end

--- Run BFS over the vault index link graph.
---@param opts BfsOpts
---@return BfsResult
function M.traverse(opts)
  return run_bfs_loop(opts, nil)
end

-- =============================================================================
-- traverse_async: cooperative yielding version for interactive paths
-- =============================================================================

---@class BfsAsyncOpts
---@field batch_size? number nodes per yield (default from config.graph.bfs_batch_size)
---@field cancelled? fun(): boolean cancellation check
---@field callback? fun(result: BfsResult) called on completion

--- Async BFS with cooperative yielding during queue processing.
--- Yields control to Neovim's event loop every batch_size nodes to prevent UI freezes.
--- Produces identical results to traverse(); only scheduling differs.
---@param opts BfsOpts same options as traverse()
---@param async_opts BfsAsyncOpts async-specific options
---@return function cancel cancel the traversal
function M.traverse_async(opts, async_opts)
  async_opts = async_opts or {}
  local yield_iter = require("andrew.vault.yield_iter")
  local batch_size = async_opts.batch_size
    or require("andrew.vault.config").graph.bfs_batch_size or 100

  return yield_iter.run_async(function()
    local batch_count = 0
    return run_bfs_loop(opts, function()
      if async_opts.cancelled and async_opts.cancelled() then return true end
      batch_count = batch_count + 1
      if batch_count >= batch_size then
        batch_count = 0
        coroutine.yield()
      end
      return false
    end)
  end, async_opts.callback)
end

return M
