--- Graph traversal for graph: operator in search filter pipeline.

local M = {}

local bfs = require("andrew.vault.bfs")
local config = require("andrew.vault.config")
local filter_utils = require("andrew.vault.filter_utils")
local notify = require("andrew.vault.notify")

--- Resolve the center note for a graph: operator.
---@param center_spec string "current" or a note name
---@param current_path string|nil absolute path of current buffer
---@param index table VaultIndex
---@return string|nil absolute path
local function resolve_graph_center(center_spec, current_path, index)
  if center_spec == "current" or center_spec == nil then
    return current_path
  end
  -- Resolve as a note name via the index
  local rel = filter_utils.resolve_in_index(index, center_spec)
  if rel then
    local entry = index.files[rel]
    if entry then return entry.abs_path end
  end
  return nil
end

--- Prepare BFS options shared by sync and async collect_reachable.
---@param index table VaultIndex
---@param center_abs string absolute path of center note
---@param depth number max hops
---@param direction "both"|"forward"|"backward"
---@return table|nil bfs_opts (nil if center cannot be resolved)
---@return table<string, boolean> reachable set (shared reference)
local function prepare_bfs_opts(index, center_abs, depth, direction)
  local max_depth = config.search.graph_max_depth
  if depth > max_depth then depth = max_depth end

  local max_nodes = config.graph.max_nodes

  local center_rel, _, resolve = filter_utils.bfs_init(index, center_abs)
  if not center_rel then return nil, {} end

  local reachable = bfs.init_visited(center_rel)

  return bfs.make_opts({
    index = index,
    frontier = bfs.init_frontier(center_rel),
    max_depth = depth,
    max_nodes = max_nodes,
    resolve = resolve,
    visited = reachable,
    initial_count = 1, -- center already counted
    process_outlinks = direction == "both" or direction == "forward",
    process_inlinks = direction == "both" or direction == "backward",
    on_discover = function() return true end,
  }), reachable
end

--- Collect all notes reachable within N hops from a center note.
---@param index table VaultIndex
---@param center_abs string absolute path of center note
---@param depth number max hops
---@param direction "both"|"forward"|"backward"
---@return table<string, boolean> reachable rel_paths (including center)
---@return boolean truncated
local function collect_reachable(index, center_abs, depth, direction)
  local opts, reachable = prepare_bfs_opts(index, center_abs, depth, direction)
  if not opts then return {}, false end

  local result = bfs.traverse(opts)
  return reachable, result.truncated
end

--- Build a unique identity string for a graph AST node.
---@param node table graph AST node with center, depth, direction fields
---@return string
local function make_graph_id(node)
  return string.format("graph_%s_%d_%s", node.center, node.depth, node.direction)
end

--- Walk an AST and collect all graph: nodes in traversal order.
---@param ast table|nil parsed AST
---@return table[] list of graph AST nodes
local function collect_graph_nodes_from_ast(ast)
  local nodes = {}
  local function walk(node)
    if not node then return end
    if node.type == "graph" then
      nodes[#nodes + 1] = node
      return
    end
    if node.type == "and" or node.type == "or" then
      walk(node.left)
      walk(node.right)
    elseif node.type == "not" then
      walk(node.operand)
    end
  end
  walk(ast)
  return nodes
end

--- Check if an AST contains any graph: nodes.
---@param ast table|nil
---@return boolean
function M.ast_contains_graph(ast)
  return #collect_graph_nodes_from_ast(ast) > 0
end

--- Pre-compute graph traversal results for all graph: nodes in an AST.
--- Returns a table mapping graph node identity to a set of reachable rel_paths.
---@param ast table parsed AST
---@param index table VaultIndex
---@param current_path string|nil absolute path of current buffer
---@return table<string, table<string, boolean>> graph_id -> {rel_path -> true}
function M.precompute_graph_sets(ast, index, current_path)
  local sets = {}
  local graph_nodes = collect_graph_nodes_from_ast(ast)

  for _, node in ipairs(graph_nodes) do
    local graph_id = make_graph_id(node)
    node._graph_id = graph_id -- annotate for match_entry

    if not sets[graph_id] then
      local center_abs = resolve_graph_center(node.center, current_path, index)
      if center_abs then
        local reachable, truncated = collect_reachable(index, center_abs, node.depth, node.direction)
        sets[graph_id] = reachable
        if truncated then
          local max_nodes = config.graph.max_nodes
          notify.info(string.format("search graph '%s' truncated at %d nodes", graph_id, max_nodes))
        end
      else
        sets[graph_id] = {}
      end
    end
  end

  return sets
end

--- Collect all reachable notes asynchronously using bfs.traverse_async.
---@param index table VaultIndex
---@param center_abs string absolute path of center note
---@param depth number max hops
---@param direction "both"|"forward"|"backward"
---@param callback fun(reachable: table<string, boolean>, truncated: boolean)
---@return function cancel
local function collect_reachable_async(index, center_abs, depth, direction, callback, cancelled)
  local opts, reachable = prepare_bfs_opts(index, center_abs, depth, direction)
  if not opts then
    callback({}, false)
    return function() end
  end

  return bfs.traverse_async(opts, {
    cancelled = cancelled,
    callback = function(result)
      callback(reachable, result.truncated)
    end,
  })
end

--- Async version of precompute_graph_sets.
--- Pre-computes graph traversal for all graph: nodes in AST using cooperative yielding.
--- Processes graph nodes sequentially (each BFS must complete before next starts).
---@param ast table parsed AST
---@param index table VaultIndex
---@param current_path string|nil absolute path of current buffer
---@param callback fun(sets: table<string, table<string, boolean>>)
---@return function cancel
function M.precompute_graph_sets_async(ast, index, current_path, callback)
  local sets = {}
  local cancelled = false
  local function is_cancelled() return cancelled end

  local graph_nodes = collect_graph_nodes_from_ast(ast)

  if #graph_nodes == 0 then
    callback(sets)
    return function() cancelled = true end
  end

  -- Process graph nodes sequentially (each BFS async)
  local current_cancel
  local function process_next(i)
    if cancelled or i > #graph_nodes then
      callback(sets)
      return
    end

    local node = graph_nodes[i]
    local graph_id = make_graph_id(node)
    node._graph_id = graph_id

    if sets[graph_id] then
      -- Already computed (duplicate graph node in AST)
      process_next(i + 1)
      return
    end

    local center_abs = resolve_graph_center(node.center, current_path, index)
    if not center_abs then
      sets[graph_id] = {}
      process_next(i + 1)
      return
    end

    current_cancel = collect_reachable_async(index, center_abs, node.depth, node.direction,
      function(reachable, truncated)
        if cancelled then return end
        sets[graph_id] = reachable
        if truncated then
          local max_nodes_val = config.graph.max_nodes
          notify.info(string.format("search graph '%s' truncated at %d nodes", graph_id, max_nodes_val))
        end
        process_next(i + 1)
      end, is_cancelled)
  end

  process_next(1)

  return function()
    cancelled = true
    if current_cancel then current_cancel() end
  end
end

return M
