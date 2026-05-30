--- Multi-hop graph traversal via vault index.
--- BFS collection of nodes at depth N from a center note.
--- Supports incremental depth extension via cached BFS layers.

local M = {}

local bfs = require("andrew.vault.bfs")
local filter_utils = require("andrew.vault.filter_utils")
local vault_index_mod = require("andrew.vault.vault_index")
local config = require("andrew.vault.config")
local sort_utils = require("andrew.vault.sort_utils")
local lru = require("andrew.vault.lru_cache")
local weighers = require("andrew.vault.cache_weighers")
local render_arena = require("andrew.vault.render_arena")

-- ---------------------------------------------------------------------------
-- BFS layer cache
-- ---------------------------------------------------------------------------

--- @class BfsCacheEntry
--- @field gen number vault index generation
--- @field state_hash string serialized filter state
--- @field depth number depth that was computed
--- @field forward_like {name: string, path: string}[]
--- @field backlink_like {name: string, path: string}[]
--- @field all_nodes {name: string, path: string}[]
--- @field visited table<string, true>
--- @field frontier {rel: string, d: number, direction: string}[]
--- @field truncated boolean
--- @field resolve fun(link_path: string): string|nil memoized resolver

local _bfs_cache_hits = 0
local _bfs_cache_misses = 0
local _bfs_cache_evictions = 0

local _bfs_cache = lru.new_weighted({
  max_bytes = config.cache.bfs_traversal_bytes,
  max_items = config.cache.bfs_traversal_max,
  weigher = weighers.bfs_result,
  on_evict = function() _bfs_cache_evictions = _bfs_cache_evictions + 1 end,
})

--- Invalidate the BFS layer cache.
--- Call when graph filters change (new predicate).
function M.invalidate_bfs_cache()
  _bfs_cache:clear()
end

-- ---------------------------------------------------------------------------
-- BFS core (delegates to shared bfs module)
-- ---------------------------------------------------------------------------

local sort_nodes = sort_utils.sort_by_name

--- Create the on_discover callback for BFS traversal.
--- Classifies discovered nodes as "forward" or "backlink" relative to center.
---@param center_rel string center note rel_path
---@param predicate fun(path: string|nil): boolean
---@param all_nodes table[] accumulator for all discovered nodes
---@param forward_like table[] accumulator for forward-direction nodes
---@param backlink_like table[] accumulator for backlink-direction nodes
---@param arena_scope? integer optional arena scope for ephemeral extra tables
---@return fun(rel: string, entry: table, depth: number, link_type: string, parent: table): table|nil
local function make_on_discover(center_rel, predicate, all_nodes, forward_like, backlink_like, arena_scope)
  return function(rel, entry, depth, link_type, parent)
    local abs = entry.abs_path
    if not predicate(abs) then return nil end
    local name = entry.basename
    local node = { name = name, path = abs }
    all_nodes[#all_nodes + 1] = node
    local dir
    if link_type == "outlink" then
      dir = (parent.rel == center_rel) and "forward" or (parent.direction or "forward")
    else
      dir = (parent.rel == center_rel) and "backlink" or (parent.direction or "backlink")
    end
    if dir == "forward" then
      forward_like[#forward_like + 1] = node
    else
      backlink_like[#backlink_like + 1] = node
    end
    -- Extra table is ephemeral: merged into queue item via pairs(), then discarded
    local extra = arena_scope and render_arena.alloc_table(arena_scope) or {}
    extra.direction = dir
    return extra
  end
end

--- Filter BFS result frontier to items at target_depth.
---@param result_frontier table[] raw frontier from BFS
---@param target_depth number
---@return table[] filtered frontier
local function filter_frontier(result_frontier, target_depth)
  local new_frontier = {}
  for _, item in ipairs(result_frontier) do
    if item.d == target_depth then
      new_frontier[#new_frontier + 1] = item
    end
  end
  return new_frontier
end

--- Deep copy arrays of node tables (shallow copy of each node).
local function copy_nodes(src)
  local out = {}
  for i, node in ipairs(src) do
    out[i] = { name = node.name, path = node.path }
  end
  return out
end

--- Copy a frontier array.  BFS mutates the frontier during traversal.
local function copy_frontier(src)
  local out = {}
  for i, item in ipairs(src) do
    out[i] = { rel = item.rel, d = item.d, direction = item.direction }
  end
  return out
end

--- Copy a visited set.  Needed when extending from cache: BFS mutates the
--- visited set during traversal, so we must not hand it the cached original.
local function copy_visited(src)
  local out = {}
  for k, v in pairs(src) do out[k] = v end
  return out
end

-- ---------------------------------------------------------------------------
-- Shared cache helpers
-- ---------------------------------------------------------------------------

--- @class CacheSetup
--- @field idx table VaultIndex
--- @field center_rel string
--- @field gen number
--- @field max_nodes number

--- Validate index readiness and check BFS cache for a hit or incremental extension.
--- Returns nil on index-not-ready or center-not-found (caller should return empty).
--- Otherwise returns a setup table plus one of:
---   hit="exact"   → fwd, bk, truncated are populated (ready to return)
---   hit="extend"  → frontier, visited, forward_like, backlink_like, all_nodes, resolve ready for BFS
---   hit=nil       → full BFS needed; visited, forward_like, backlink_like, all_nodes, resolve, frontier ready
---@param center_path string
---@param depth number
---@param state_hash string
---@return table|nil setup
local function check_cache(center_path, depth, state_hash)
  local max_nodes = config.graph.max_nodes

  local idx = vault_index_mod.current()
  if not idx or not idx:is_ready() then return nil end

  local center_rel, _, resolve = filter_utils.bfs_init(idx, center_path)
  if not center_rel then return nil end

  local gen = idx._generation or 0

  local setup = {
    idx = idx,
    center_rel = center_rel,
    gen = gen,
    max_nodes = max_nodes,
  }

  -- Check cache
  local cached = _bfs_cache:get(center_rel)
  if filter_utils.is_cache_gen_valid(cached, gen)
    and cached.state_hash == state_hash
  then
    if cached.depth == depth then
      -- Exact cache hit: return copies to prevent mutation
      _bfs_cache_hits = _bfs_cache_hits + 1
      local fwd = copy_nodes(cached.forward_like)
      local bk = copy_nodes(cached.backlink_like)
      sort_nodes(fwd)
      sort_nodes(bk)
      setup.hit = "exact"
      setup.fwd = fwd
      setup.bk = bk
      setup.truncated = cached.truncated
      return setup
    elseif cached.depth < depth and not cached.truncated then
      -- Incremental extension: copy from cache, BFS from cached frontier
      _bfs_cache_hits = _bfs_cache_hits + 1
      setup.hit = "extend"
      setup.visited = copy_visited(cached.visited)
      setup.forward_like = copy_nodes(cached.forward_like)
      setup.backlink_like = copy_nodes(cached.backlink_like)
      setup.all_nodes = copy_nodes(cached.all_nodes)
      setup.frontier = copy_frontier(cached.frontier)
      setup.resolve = cached.resolve
      return setup
    end
  end
  _bfs_cache_misses = _bfs_cache_misses + 1

  -- Full BFS needed
  setup.hit = nil
  setup.visited = bfs.init_visited(center_rel)
  setup.forward_like = {}
  setup.backlink_like = {}
  setup.all_nodes = {}
  setup.resolve = resolve
  setup.frontier = bfs.init_frontier(center_rel)
  return setup
end

--- Build the BFS options table from setup + parameters.
---@param s table setup from check_cache
---@param depth number
---@param predicate fun(path: string|nil): boolean
---@param arena_scope? integer optional arena scope for ephemeral BFS allocations
---@return table bfs_opts
local function make_bfs_opts(s, depth, predicate, arena_scope)
  return bfs.make_opts({
    index = s.idx,
    frontier = s.frontier,
    max_depth = depth,
    max_nodes = s.max_nodes,
    resolve = s.resolve,
    visited = s.visited,
    initial_count = #s.all_nodes,
    on_discover = make_on_discover(s.center_rel, predicate, s.all_nodes, s.forward_like, s.backlink_like, arena_scope),
    arena_scope = arena_scope,
  })
end

--- Store BFS results into the cache and return the sorted forward/backlink lists.
--- For incremental extension (hit="extend"), working copies are already fresh so we
--- store them directly. For full BFS (hit=nil), we copy before caching.
--- Sorting is done before caching so cached data is pre-sorted and immutable.
---@param s table setup from check_cache
---@param depth number
---@param state_hash string
---@param result_frontier table[] raw frontier from BFS
---@param truncated boolean
---@return table[] forward_like (sorted)
---@return table[] backlink_like (sorted)
---@return boolean truncated
local function store_and_return(s, depth, state_hash, result_frontier, truncated)
  local new_frontier = filter_frontier(result_frontier, depth)
  local is_extension = (s.hit == "extend")

  -- Sort before caching so the cached arrays are never mutated after storage.
  sort_nodes(s.forward_like)
  sort_nodes(s.backlink_like)

  -- For extension, s.forward_like etc. are already working copies (made in check_cache),
  -- so storing them directly is safe. For full BFS, copy to isolate cache from caller.
  -- visited is not copied: after store_and_return, s.visited is never referenced again
  -- (callers receive only forward_like, backlink_like, truncated).
  _bfs_cache:put(s.center_rel, {
    gen = s.gen,
    state_hash = state_hash,
    depth = depth,
    forward_like = is_extension and s.forward_like or copy_nodes(s.forward_like),
    backlink_like = is_extension and s.backlink_like or copy_nodes(s.backlink_like),
    all_nodes = is_extension and s.all_nodes or copy_nodes(s.all_nodes),
    visited = s.visited,
    frontier = new_frontier,
    truncated = truncated,
    resolve = s.resolve,
  })

  return s.forward_like, s.backlink_like, truncated
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Collect nodes at a given BFS depth using cooperative yielding via bfs.traverse_async.
--- Uses incremental cache with depth extension and generation validation.
---@param center_path string absolute path
---@param depth number
---@param predicate fun(path: string|nil): boolean
---@param state_hash? string serialized filter state for cache validation
---@param callback fun(forward_like: table[], backlink_like: table[], truncated: boolean)
---@return function cancel
function M.collect_at_depth_async(center_path, depth, predicate, state_hash, callback)
  state_hash = state_hash or ""

  local s = check_cache(center_path, depth, state_hash)
  if not s then
    callback({}, {}, false)
    return function() end
  end

  if s.hit == "exact" then
    callback(s.fwd, s.bk, s.truncated)
    return function() end
  end

  -- Arena scope spans the entire async BFS traversal, ended in callback or on cancel
  local arena_scope = render_arena.begin_scope()

  -- BFS (either incremental extension or full)
  local cancel = bfs.traverse_async(make_bfs_opts(s, depth, predicate, arena_scope), {
    callback = function(result)
      local fwd, bk, trunc = store_and_return(s, depth, state_hash, result.frontier, result.truncated)
      render_arena.end_scope(arena_scope)
      callback(fwd, bk, trunc)
    end,
  })

  -- Wrap cancel to ensure arena scope is cleaned up on cancellation
  return function()
    cancel()
    if render_arena.is_valid(arena_scope) then
      render_arena.end_scope(arena_scope)
    end
  end
end

--- Return the number of entries in the BFS cache.
---@return number
function M.bfs_cache_size()
  return _bfs_cache:size()
end

--- Return memory utilization stats for the BFS cache.
---@return table|nil stats table with items, total_bytes, max_bytes, utilization
function M.bfs_cache_stats()
  if _bfs_cache.stats then
    return _bfs_cache:stats()
  end
  return nil
end

--- Return hit/miss/eviction counters for the BFS cache.
---@return number hits, number misses, number evictions
function M.bfs_cache_counters()
  return _bfs_cache_hits, _bfs_cache_misses, _bfs_cache_evictions
end

return M
