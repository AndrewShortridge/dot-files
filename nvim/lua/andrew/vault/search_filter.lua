--- Search filter pipeline for advanced vault search.
---
--- Evaluates parsed ASTs against vault index entries and coordinates ripgrep
--- for text/regex content search. Separates metadata filtering (evaluated
--- against the index in-process) from text search (delegated to ripgrep).
---
--- Step 2 of the advanced search implementation.

local M = {}

local config = require("andrew.vault.config")

local date_utils = require("andrew.vault.date_utils")
local filter_utils = require("andrew.vault.filter_utils")

local ast_split = require("andrew.vault.search_filter.ast_split")
local graph_traversal = require("andrew.vault.search_filter.graph_traversal")
local match_field_mod = require("andrew.vault.search_filter.match_field")
local match_has_mod = require("andrew.vault.search_filter.match_has")
local match_task_mod = require("andrew.vault.search_filter.match_task")
local ripgrep_mod = require("andrew.vault.search_filter.ripgrep")
local render_arena = require("andrew.vault.render_arena")
local coalescer = require("andrew.vault.request_coalescer")

-- Dedicated pool for search evaluation (config applied via coalescer.configure() in init.lua)
local search_pool = coalescer.new({ name = "search" })

-- =============================================================================
-- Re-exported public API
-- =============================================================================

M.split_ast = ast_split.split_ast
M.ast_contains_graph = graph_traversal.ast_contains_graph
M.precompute_graph_sets = graph_traversal.precompute_graph_sets
M.precompute_graph_sets_async = graph_traversal.precompute_graph_sets_async
M.ripgrep_in_files = ripgrep_mod.ripgrep_in_files
M.extract_rg_file = ripgrep_mod.extract_rg_file
M.collect_file_set = ripgrep_mod.collect_file_set
M.semaphore_stats = ripgrep_mod.semaphore_stats
M.semaphore_reset = ripgrep_mod.semaphore_reset

-- Date fields that use resolve_date() for filter values
local DATE_FIELDS = {
  created = true, modified = true, day = true,
}

-- Task date meta-fields that use resolve_task_date()
local TASK_DATE_FIELDS = {
  due = true, scheduled = true, completion = true,
}

-- Module-level daily memo: caches resolve_date() results across evaluate() calls.
-- Reset when the calendar day changes. Values like "today", "7d", "this-week"
-- change at most once per day but may be re-resolved hundreds of times per session.
local _date_memo = nil
local _date_memo_day = nil

local function get_or_reset_date_memo()
  local today = os.date("%Y-%m-%d")
  if today ~= _date_memo_day then
    _date_memo_day = today
    _date_memo = {}
  end
  return _date_memo
end

-- =============================================================================
-- is_ast_superset: conservative check for incremental live search filtering
-- =============================================================================

--- Collect the leaf nodes of an AND-tree into a flat list.
--- Returns nil if the tree contains OR or NOT nodes (not safe for superset check).
---@param node table|nil AST node
---@param out table[] accumulator
---@return boolean ok false if tree shape is not a pure AND-tree
local function collect_and_leaves(node, out)
  if not node then return true end
  if node.type == "and" then
    return collect_and_leaves(node.left, out) and collect_and_leaves(node.right, out)
  end
  if node.type == "or" or node.type == "not" then
    return false
  end
  out[#out + 1] = node
  return true
end

--- Produce a stable string key for a leaf AST node (for set comparison).
--- Returns nil for node types that can't be reliably fingerprinted.
---@param node table AST leaf node
---@return string|nil
local function leaf_key(node)
  local t = node.type
  if t == "text" then
    return "text:" .. (node.value or "")
  elseif t == "regex" then
    return "regex:" .. (node.pattern or "") .. ":" .. (node.flags or "")
  elseif t == "field" then
    return "field:" .. (node.name or "") .. ":" .. (node.op or "") .. ":"
      .. (node.value or "") .. ":" .. (node.value2 or "")
  elseif t == "has" then
    return "has:" .. (node.target or "")
  elseif t == "task" then
    if node.variant == "meta" then
      return "task-meta:" .. (node.meta_field or "") .. ":" .. (node.op or "") .. ":"
        .. (node.value or "") .. ":" .. (node.value2 or "")
    elseif node.variant == "state" then
      return "task-state:" .. (node.pattern or "")
    else
      return "task:" .. (node.pattern or "")
    end
  elseif t == "graph" then
    return "graph:" .. (node._graph_id or tostring(node))
  end
  return nil
end

--- Recursive hash of an AST tree to a stable string key for deduplication.
--- Reuses leaf_key() for leaf nodes and recursively hashes compound nodes.
---@param node table|nil AST node
---@return string
local function ast_hash(node)
  if not node then return "nil" end
  local lk = leaf_key(node)
  if lk then return lk end
  local t = node.type
  if t == "and" or t == "or" then
    return t .. "(" .. ast_hash(node.left) .. "," .. ast_hash(node.right) .. ")"
  elseif t == "not" then
    return "not(" .. ast_hash(node.child) .. ")"
  end
  return tostring(node)
end

--- Conservative check: is `new_ast` strictly more restrictive than `old_ast`?
---
--- Only returns true for pure AND-trees where the new tree contains all leaves
--- of the old tree plus at least one more. False negatives are safe (caller
--- falls back to full evaluation). False positives would be a bug — be cautious.
---
---@param old_ast table|nil previous query AST
---@param new_ast table|nil current query AST
---@return boolean true if new_ast is guaranteed to be a superset (more restrictive)
function M.is_ast_superset(old_ast, new_ast)
  if not old_ast or not new_ast then return false end

  local old_leaves = {}
  local new_leaves = {}

  -- Only handle pure AND-trees (no OR/NOT)
  if not collect_and_leaves(old_ast, old_leaves) then return false end
  if not collect_and_leaves(new_ast, new_leaves) then return false end

  -- New must have at least as many leaves
  if #new_leaves < #old_leaves then return false end

  -- Build set of new leaf keys
  local new_set = {}
  for _, leaf in ipairs(new_leaves) do
    local k = leaf_key(leaf)
    if not k then return false end -- unknown node type, bail out
    new_set[k] = true
  end

  -- Every old leaf must appear in the new set
  for _, leaf in ipairs(old_leaves) do
    local k = leaf_key(leaf)
    if not k then return false end
    if not new_set[k] then return false end
  end

  return true
end

-- =============================================================================
-- FilterContext: pre-compute constant filter values once per evaluate() call
-- =============================================================================

--- Walk an AST and pre-resolve all constant filter values into a context table.
--- This avoids redundant per-entry computation of values that don't change
--- across entries (dates, tag parses, numeric conversions).
---@param ast table|nil parsed query AST
---@param index table VaultIndex instance
---@return table ctx with resolved_dates, parsed_tags, numeric_values
function M.build_filter_context(ast, index, arena_scope)
  local alloc = arena_scope and render_arena.alloc_table or nil
  local ctx = alloc and alloc(arena_scope) or {}
  ctx.resolved_dates = alloc and alloc(arena_scope) or {}   -- filter_val -> timestamp (or false if unresolvable)
  ctx.parsed_tags = alloc and alloc(arena_scope) or {}      -- filter_val -> { includes, excludes }
  ctx.numeric_values = alloc and alloc(arena_scope) or {}   -- filter_val -> number (or false if not numeric)
  ctx.bloom_pre_checked = alloc and alloc(arena_scope) or {} -- AST node -> true: bloom already checked in extract_pre_checks

  local function resolve_and_cache_date(val)
    if val and ctx.resolved_dates[val] == nil then
      local daily = get_or_reset_date_memo()
      if daily[val] ~= nil then
        ctx.resolved_dates[val] = daily[val]
      else
        local result = date_utils.resolve_date(val) or false
        daily[val] = result
        ctx.resolved_dates[val] = result
      end
    end
  end

  local function cache_numeric(val)
    if val and ctx.numeric_values[val] == nil then
      ctx.numeric_values[val] = tonumber(val) or false
    end
  end

  local function walk(node)
    if not node then return end

    if node.type == "field" then
      local name, val, val2 = node.name, node.value, node.value2

      -- Pre-resolve dates for date fields
      if DATE_FIELDS[name] then
        resolve_and_cache_date(val)
        resolve_and_cache_date(val2)
      end

      -- Pre-parse tag filters
      if name == "tag" and val and not ctx.parsed_tags[val] then
        local includes, excludes = filter_utils.parse_tag_filter(val)
        ctx.parsed_tags[val] = { includes, excludes }
      end

      -- Pre-convert numeric values for priority
      if name == "priority" then
        cache_numeric(val)
        cache_numeric(val2)
      end
    end

    if node.type == "task" and node.variant == "meta" then
      local meta_field, val, val2 = node.meta_field, node.value, node.value2

      -- Pre-resolve task date fields
      if TASK_DATE_FIELDS[meta_field] then
        resolve_and_cache_date(val)
        resolve_and_cache_date(val2)
      end

      -- Pre-convert task priority numerics
      if meta_field == "priority" then
        cache_numeric(val)
        cache_numeric(val2)
      end
    end

    walk(node.left)
    walk(node.right)
    walk(node.operand)
  end

  walk(ast)

  -- Memoized link resolver: caches resolve_in_index() results across all
  -- AST nodes within a single evaluate() pass.
  ctx.resolve_link = filter_utils.create_memoized_resolver(index, arena_scope)

  return ctx
end

-- =============================================================================
-- match_entry
-- =============================================================================

--- Evaluate a metadata AST against a single VaultIndexEntry.
---
--- The AST should contain only metadata nodes (field, has, task) and boolean
--- combiners (and, or, not). Text/regex nodes are treated as always-true
--- (they are handled separately by ripgrep).
---
---@param ast table|nil metadata AST node
---@param entry table VaultIndexEntry
---@param index table|nil VaultIndex instance (needed for has:inlinks)
---@param graph_sets table|nil pre-computed graph reachable sets
---@param ctx table|nil FilterContext with pre-resolved values
---@return boolean
function M.match_entry(ast, entry, index, graph_sets, ctx)
  if not ast then return true end
  if not entry then return false end

  local t = ast.type

  if t == "and" then
    return M.match_entry(ast.left, entry, index, graph_sets, ctx)
      and M.match_entry(ast.right, entry, index, graph_sets, ctx)
  end

  if t == "or" then
    return M.match_entry(ast.left, entry, index, graph_sets, ctx)
      or M.match_entry(ast.right, entry, index, graph_sets, ctx)
  end

  if t == "not" then
    return not M.match_entry(ast.operand, entry, index, graph_sets, ctx)
  end

  if t == "field" then
    return match_field_mod.match_field(ast, entry, index, ctx)
  end

  if t == "has" then
    return match_has_mod.match_has(ast, entry, index)
  end

  if t == "task" then
    return match_task_mod.match_task(ast, entry, ctx)
  end

  if t == "graph" then
    if not config.search.graph_operator then return true end
    if not graph_sets or not ast._graph_id then return true end
    local set = graph_sets[ast._graph_id]
    return set ~= nil and set[entry.rel_path] == true
  end

  return false
end

-- =============================================================================
-- evaluate
-- =============================================================================

--- Evaluate a metadata AST against the entire vault index.
---
--- Iterates all files in the index, testing each entry against the AST.
--- Returns a table mapping rel_path to the matching entry.
---
---@param ast table|nil metadata AST node (nil matches everything)
---@param index table VaultIndex instance
---@param graph_sets table|nil pre-computed graph reachable sets
---@param restrict_to table<string, table>|nil optional subset to filter (rel_path -> entry)
---@return table<string, table> matches: rel_path -> VaultIndexEntry
---@return boolean limit_reached true if max_result_files cap was hit
--- Extract cheap pre-check predicates from the AST.
--- Only collects from AND-reachable leaves (OR/NOT subtrees are silently skipped).
--- @param ast table Metadata AST node
--- @param index table VaultIndex instance
--- @param ctx table FilterContext — bloom_pre_checked set is populated here
--- @return function[]|nil pre_checks Array of (entry, rel_path) -> bool functions
local function extract_pre_checks(ast, index, ctx, arena_scope)
  if not config.prefilter.enabled or not config.prefilter.search_pre_checks then
    return nil
  end
  local checks = arena_scope and render_arena.alloc_table(arena_scope) or {}
  local use_sets = config.prefilter.precomputed_sets
  local use_bloom = config.prefilter.bloom_filter

  local function collect(node)
    if not node then return end
    if node.type == "and" then
      collect(node.left)
      collect(node.right)
    elseif node.type == "field" and node.name == "tag" and node.op == "=" and node.value then
      -- Bloom filter pre-check: reject entries whose tag bloom definitely doesn't contain the query tag
      if use_bloom and index._tag_blooms then
        local bloom_mod = require("andrew.vault.bloom_filter")
        local filter_tag = node.value:lower()
        -- For include/exclude patterns, only bloom-check the first include tag
        local first_tag = filter_tag:match("^([^!,]+)")
        if first_tag then
          first_tag = vim.trim(first_tag)
          checks[#checks + 1] = function(_, rel_path)
            local bloom = index._tag_blooms[rel_path]
            if not bloom then return false end
            return bloom_mod.maybe_contains(bloom, first_tag)
          end
          -- Mark this node so match_field skips its redundant bloom check
          ctx.bloom_pre_checked[node] = true
        end
      end
    elseif node.type == "field" and node.name == "type" then
      if use_sets and node.op == "=" and node.value and index._files_by_type then
        -- O(1) complete answer via precomputed set (keys are lowercased)
        local type_set = index._files_by_type[node.value:lower()]
        checks[#checks + 1] = function(_, rel_path)
          return type_set ~= nil and type_set[rel_path] == true
        end
      else
        checks[#checks + 1] = function(entry)
          return entry.frontmatter ~= nil and entry.frontmatter.type ~= nil
        end
      end
    elseif node.type == "has" and node.target == "tags" then
      if use_sets and index._files_with_tags then
        checks[#checks + 1] = function(_, rel_path)
          return index._files_with_tags[rel_path] == true
        end
      else
        checks[#checks + 1] = function(entry)
          return entry.tags ~= nil and #entry.tags > 0
        end
      end
    elseif node.type == "has" and node.target == "tasks" then
      if use_sets and index._files_with_tasks then
        checks[#checks + 1] = function(_, rel_path)
          return index._files_with_tasks[rel_path] == true
        end
      else
        checks[#checks + 1] = function(entry)
          return entry.tasks ~= nil and #entry.tasks > 0
        end
      end
    elseif node.type == "has" and node.target == "aliases" then
      checks[#checks + 1] = function(entry)
        return entry.aliases ~= nil and #entry.aliases > 0
      end
    elseif node.type == "task" then
      if use_sets and index._files_with_tasks then
        checks[#checks + 1] = function(_, rel_path)
          return index._files_with_tasks[rel_path] == true
        end
      else
        checks[#checks + 1] = function(entry)
          return entry.tasks ~= nil and #entry.tasks > 0
        end
      end
    end
  end

  collect(ast)
  return #checks > 0 and checks or nil
end

--- Prepare shared evaluation state: invalidate caches, build filter context,
--- extract pre-checks, and construct matching predicate.
---
--- When iterating the full index (no restrict_to), takes a snapshot so that
--- all reads are consistent even if a build_async() mutates the index
--- between coroutine yields.
---@param ast table|nil metadata AST
---@param index table VaultIndex instance
---@param graph_sets table|nil pre-computed graph reachable sets
---@param restrict_to table|nil optional subset to filter
---@return table|nil files to iterate (nil if index invalid)
---@return function predicate (rel_path, entry) -> boolean
---@return number max_files result cap
local function prepare_evaluate(ast, index, graph_sets, restrict_to, arena_scope)
  match_field_mod.invalidate_section_cache(index, index and index._last_inv_ctx or nil)
  if not index or not index.files then return nil end

  -- When iterating the full index, take a snapshot for consistent reads.
  -- Full snapshot (not just files) because extract_pre_checks uses derived
  -- indexes (_tag_blooms, _files_by_type, etc.) which must be consistent
  -- with the files table. restrict_to is already a separate table.
  local snap = (not restrict_to and require("andrew.vault.config").index.use_snapshots
    and index.snapshot) and index:snapshot() or index
  local files = restrict_to or snap.files

  -- build_filter_context needs the original index for create_memoized_resolver
  -- (which calls idx:resolve_name(), a VaultIndex method). The snapshot's
  -- _name_index/_alias_index are consistent with its files table since both
  -- are captured at the same point in time.
  local ctx = M.build_filter_context(ast, index, arena_scope)
  local pre_checks = extract_pre_checks(ast, snap, ctx, arena_scope)
  local max_files = config.search.max_result_files

  -- match_entry receives the original index (not snap) because match_field
  -- and match_has call index:get_inlinks() which requires VaultIndex methods.
  -- The snapshot's _inlinks reference is the same object, so consistency is
  -- maintained; methods just need the metatable dispatch.
  local function predicate(rel_path, entry)
    if pre_checks then
      for _, check in ipairs(pre_checks) do
        if not check(entry, rel_path) then return false end
      end
    end
    return M.match_entry(ast, entry, index, graph_sets, ctx)
  end

  return files, predicate, max_files
end

function M.evaluate(ast, index, graph_sets, restrict_to, cancelled)
  local stop = require("andrew.vault.memory_profiler").start_timer("search.evaluate")
  local arena_scope = render_arena.begin_scope()
  local ok, r1, r2 = pcall(function()
    local files, predicate, max_files = prepare_evaluate(ast, index, graph_sets, restrict_to, arena_scope)
    if not files then
      return {}, false
    end

    local matches = {}  -- escapes scope, NOT from arena
    local count = 0
    local checked = 0
    for rel_path, entry in pairs(files) do
      if cancelled then
        checked = checked + 1
        if checked % 200 == 0 and cancelled() then
          return nil, "cancelled"
        end
      end
      if predicate(rel_path, entry) then
        matches[rel_path] = entry
        count = count + 1
        if max_files and count >= max_files then
          return matches, true
        end
      end
    end

    return matches, false
  end)
  render_arena.end_scope(arena_scope)
  stop()
  if not ok then error(r1, 2) end
  return r1, r2
end

-- =============================================================================
-- evaluate_async: cooperative yielding version for interactive paths
-- =============================================================================

local yield_iter = require("andrew.vault.yield_iter")

--- Async version of evaluate() that yields periodically to avoid UI freezes.
--- Preserves identical evaluation logic; only scheduling differs.
---
---@param ast table|nil Parsed metadata AST
---@param index table VaultIndex instance
---@param opts table { graph_sets?, restrict_to?, callback, cancelled? }
function M.evaluate_async(ast, index, opts)
  opts = opts or {}

  -- Hash the AST + restrict_to to create a deduplication key
  local key = "search:" .. ast_hash(ast)
  if opts.restrict_to then
    key = key .. ":restricted"
  end

  local batch_size = config.search.evaluate_batch_size or 500

  search_pool:request(key, function(resolve, reject)
    yield_iter.run_async(function()
      local arena_scope = render_arena.begin_scope()
      local ok, r1, r2 = pcall(function()
        local files, predicate, max_files = prepare_evaluate(
          ast, index, opts.graph_sets, opts.restrict_to, arena_scope)
        if not files then
          return {}, false
        end

        local matches, limit_reached = yield_iter.filter_yielding(
          files,
          batch_size,
          predicate,
          {
            cancelled = opts.cancelled,
            max_results = max_files,
          }
        )
        return matches, limit_reached
      end)
      render_arena.end_scope(arena_scope)
      if not ok then error(r1, 2) end
      return r1, r2
    end, function(matches, limit)
      resolve({ matches = matches, limit = limit })
    end)
  end, function(result, err)
    if opts.callback then
      if err or not result then
        opts.callback({}, false)
      else
        opts.callback(result.matches, result.limit)
      end
    end
  end)

end

return M
