--- Graph filtering module for the vault local graph view.
--- Provides filter state, predicates, multi-hop collection, filter UI, and preset persistence.
---
--- Implementation is split across submodules:
---   graph_filter/presets.lua     - Preset persistence and picker UI
---   graph_filter/sub_filters.lua - Individual filter category pickers
---   graph_filter/traversal.lua   - Multi-hop BFS collection
---   graph_filter/help.lua        - Help display

local M = {}
local notify = require("andrew.vault.notify")

local config = require("andrew.vault.config")
local date_utils = require("andrew.vault.date_utils")
local filter_utils = require("andrew.vault.filter_utils")
local engine = require("andrew.vault.engine")
local search_query = require("andrew.vault.search_query")
local search_filter = require("andrew.vault.search_filter")
local vault_index = require("andrew.vault.vault_index")
local ui = require("andrew.vault.ui")

local presets = require("andrew.vault.graph_filter.presets")
local sub_filters = require("andrew.vault.graph_filter.sub_filters")
local traversal = require("andrew.vault.graph_filter.traversal")
local help = require("andrew.vault.graph_filter.help")

-- ---------------------------------------------------------------------------
-- Filter state
-- ---------------------------------------------------------------------------

---@class GraphFilterState
---@field tags_include string[]
---@field tags_exclude string[]
---@field note_types string[]
---@field date_field "created"|"modified"|nil
---@field date_from string|nil
---@field date_to string|nil
---@field depth number
---@field paths_include string[]
---@field paths_exclude string[]
---@field show_unresolved boolean
---@field existing_only boolean
---@field search_expr string|nil

--- Default filter state (no filters active, depth 1).
---@return GraphFilterState
function M.default_state()
  return {
    tags_include = {},
    tags_exclude = {},
    note_types = {},
    date_field = nil,
    date_from = nil,
    date_to = nil,
    depth = config.graph.default_depth,
    paths_include = {},
    paths_exclude = {},
    show_unresolved = config.graph.show_unresolved,
    existing_only = config.graph.existing_only,
    search_expr = nil,
  }
end

--- The active filter state for the current graph session.
---@type GraphFilterState
M.state = M.default_state()

-- Register BFS cache with engine for centralized invalidation / memory cleanup.
engine.register_cache({
  name = "graph_filter_bfs",
  module = "andrew.vault.graph_filter",
  invalidate = function()
    traversal.invalidate_bfs_cache()
  end,
  stats = function()
    local s = { entries = traversal.bfs_cache_size() }
    local ws = traversal.bfs_cache_stats()
    if ws then
      s.total_bytes = ws.total_bytes
      s.max_bytes = ws.max_bytes
    end
    return s
  end,
})

do
  local profiler = require("andrew.vault.memory_profiler")
  profiler.register_cache({
    name = "graph_filter_bfs",
    get_size = function() return traversal.bfs_cache_size() end,
    get_capacity = function() return config.cache.bfs_traversal_max end,
    get_hits = function()
      return (traversal.bfs_cache_counters())
    end,
    get_misses = function()
      local _, m = traversal.bfs_cache_counters()
      return m
    end,
    get_evictions = function()
      local _, _, e = traversal.bfs_cache_counters()
      return e
    end,
    get_bytes = function()
      local ws = traversal.bfs_cache_stats()
      return ws and ws.total_bytes or nil
    end,
    get_max_bytes = function()
      return config.cache.bfs_traversal_bytes
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Predicate composition (batched index lookups)
-- ---------------------------------------------------------------------------

--- Serialize filter state into a stable string for BFS cache validation.
---@param state GraphFilterState
---@return string
local function state_key(state)
  return table.concat({
    table.concat(state.tags_include, ","),
    table.concat(state.tags_exclude, ","),
    table.concat(state.note_types, ","),
    state.date_field or "",
    state.date_from or "",
    state.date_to or "",
    table.concat(state.paths_include, ","),
    table.concat(state.paths_exclude, ","),
    tostring(state.show_unresolved),
    tostring(state.existing_only),
    state.search_expr or "",
  }, "|")
end

--- Build a combined predicate from the current filter state.
--- Uses batched index lookups: the entry is resolved once per path and
--- passed to all entry-based predicates, eliminating redundant lookups.
---@param state GraphFilterState
---@return fun(path: string|nil): boolean
function M.build_predicate(state)
  -- Entry-based predicates: accept (entry) instead of (path)
  local entry_preds = {}
  -- Path-based predicates: accept (abs_path), no index lookup needed
  local path_preds = {}

  -- Tag filter (entry-based)
  if #state.tags_include > 0 or #state.tags_exclude > 0 then
    local include = state.tags_include
    local exclude = state.tags_exclude
    entry_preds[#entry_preds + 1] = function(entry)
      local entry_tags = entry.tags or {}
      return filter_utils.matches_include_exclude(include, exclude, function(filter_tag)
        return vault_index.tag_matches(entry_tags, filter_tag, { case_insensitive = true })
      end)
    end
  end

  -- Type filter (entry-based)
  if #state.note_types > 0 then
    local set = {}
    for _, t in ipairs(state.note_types) do set[t:lower()] = true end
    entry_preds[#entry_preds + 1] = function(entry)
      local note_type = entry.frontmatter and entry.frontmatter.type
      if not note_type then return true end
      return set[tostring(note_type):lower()] ~= nil
    end
  end

  -- Date filter (entry-based)
  if state.date_field and (state.date_from or state.date_to) then
    local field = state.date_field
    local from_ts = state.date_from and date_utils.parse_iso_datetime(state.date_from) or nil
    local to_ts = state.date_to and date_utils.parse_iso_datetime(state.date_to) or nil
    entry_preds[#entry_preds + 1] = function(entry)
      local ts = filter_utils.get_entry_timestamp(entry, field, 12)
      if not ts then return true end
      if from_ts and to_ts then
        return date_utils.in_date_range(ts, from_ts, to_ts)
      elseif from_ts and ts < from_ts then
        return false
      elseif to_ts and ts >= to_ts + date_utils.SECS_PER_DAY then
        return false
      end
      return true
    end
  end

  -- Path filter (path-based, no index lookup)
  if #state.paths_include > 0 or #state.paths_exclude > 0 then
    local include_p = state.paths_include
    local exclude_p = state.paths_exclude
    path_preds[#path_preds + 1] = function(abs_path)
      local rel = engine.vault_relative(abs_path)
      if not rel then return false end
      return filter_utils.matches_include_exclude(include_p, exclude_p, function(prefix)
        return rel:sub(1, #prefix) == prefix
      end)
    end
  end

  -- Existing-only filter (path-based)
  if state.existing_only then
    path_preds[#path_preds + 1] = function(path) return path ~= nil end
  end

  -- Search expression filter (entry-based)
  if config.graph.search_expr_enabled and state.search_expr and state.search_expr ~= "" then
    local ast = search_query.parse_query(state.search_expr)
    if ast then
      local build_idx = vault_index.current()
      if build_idx and build_idx:is_ready() then
        local split = search_filter.split_ast(ast)
        local meta_ast = split.metadata_ast
        if not meta_ast then
          notify.warn("text search terms are not supported in " ..
            "search expressions. Use metadata filters only (tag:, type:, has:, etc.)")
        else
          if split.text_ast then
            notify.info("text search terms ignored in search expression. " ..
              "Only metadata filters are applied.")
          end
          local ctx = search_filter.build_filter_context(meta_ast, build_idx)
          local ctx_gen = build_idx._generation
          entry_preds[#entry_preds + 1] = function(entry, runtime_idx)
            local effective_idx = runtime_idx or build_idx
            if effective_idx._generation ~= ctx_gen then
              ctx = search_filter.build_filter_context(meta_ast, effective_idx)
              ctx_gen = effective_idx._generation
            end
            return search_filter.match_entry(meta_ast, entry, effective_idx, nil, ctx)
          end
        end
      end
    end
  end

  local has_entry_preds = #entry_preds > 0

  return function(path)
    if not path then return not state.existing_only end
    -- Path-based predicates first (no index lookup needed)
    for _, pred in ipairs(path_preds) do
      if not pred(path) then return false end
    end
    -- Single index lookup for all entry-based predicates
    if has_entry_preds then
      local rt_idx = vault_index.current()
      local entry = rt_idx and rt_idx:get_entry_by_abs(path)
      if not entry then return not state.existing_only end
      for _, pred in ipairs(entry_preds) do
        if not pred(entry, rt_idx) then return false end
      end
    end
    return true
  end
end

-- ---------------------------------------------------------------------------
-- Filter application
-- ---------------------------------------------------------------------------

--- Apply filter predicate to a list of link entries.
---@param links {name: string, path: string|nil}[]
---@param predicate fun(path: string|nil): boolean
---@return {name: string, path: string|nil}[]
function M.apply(links, predicate)
  local filtered = {}
  for _, entry in ipairs(links) do
    if predicate(entry.path) then
      filtered[#filtered + 1] = entry
    end
  end
  return filtered
end

-- ---------------------------------------------------------------------------
-- Delegated to submodules
-- ---------------------------------------------------------------------------

--- Async version of collect_at_depth using cooperative yielding.
---@param center_path string absolute path
---@param depth number
---@param predicate fun(path: string|nil): boolean
---@param callback fun(forward_like: table[], backlink_like: table[], truncated: boolean)
---@return function cancel
function M.collect_at_depth_async(center_path, depth, predicate, callback)
  return traversal.collect_at_depth_async(center_path, depth, predicate, state_key(M.state), callback)
end

--- Invalidate the BFS layer cache (call when filters change externally).
M.invalidate_bfs_cache = traversal.invalidate_bfs_cache

M.show_help = help.show_help

--- Open the preset picker (load/delete).
---@param on_apply fun() callback after loading a preset
function M.open_preset_picker(on_apply)
  presets.open_preset_picker(M, M.default_state, on_apply)
end

--- Save a preset with user-provided name.
---@param on_done fun()|nil
function M.save_preset_prompt(on_done)
  presets.save_preset_prompt(M.state, on_done)
end

-- ---------------------------------------------------------------------------
-- Status line formatting
-- ---------------------------------------------------------------------------

--- Format active filters as a compact status string.
---@param state GraphFilterState
---@return string
function M.format_status(state)
  local parts = {}
  if #state.tags_include > 0 then
    parts[#parts + 1] = "#" .. table.concat(state.tags_include, " #")
  end
  if #state.tags_exclude > 0 then
    parts[#parts + 1] = "-#" .. table.concat(state.tags_exclude, " -#")
  end
  if #state.note_types > 0 then
    parts[#parts + 1] = "type:" .. table.concat(state.note_types, ",")
  end
  if state.date_field then
    local range = state.date_from or "*"
    range = range .. ".." .. (state.date_to or "*")
    parts[#parts + 1] = state.date_field .. ":" .. range
  end
  if state.depth > 1 then
    parts[#parts + 1] = "depth:" .. state.depth
  end
  if #state.paths_include > 0 then
    parts[#parts + 1] = "+" .. table.concat(state.paths_include, " +")
  end
  if #state.paths_exclude > 0 then
    parts[#parts + 1] = "-" .. table.concat(state.paths_exclude, " -")
  end
  if state.existing_only then
    parts[#parts + 1] = "existing-only"
  end
  if not state.show_unresolved then
    parts[#parts + 1] = "hide-unresolved"
  end
  if state.search_expr and state.search_expr ~= "" then
    parts[#parts + 1] = "expr:" .. state.search_expr
  end
  if #parts == 0 then return "(no filters)" end
  return table.concat(parts, "  ")
end

-- ---------------------------------------------------------------------------
-- Filter UI (orchestrator)
-- ---------------------------------------------------------------------------

--- Open the filter configuration popup.
---@param on_apply fun() callback when filters are applied (triggers graph re-render)
function M.open_filter_ui(on_apply)
  local state = M.state
  local search_expr_enabled = config.graph.search_expr_enabled

  local function render_menu()
    local lines = {
      "  [1] Tags include: " .. (#state.tags_include > 0 and ("#" .. table.concat(state.tags_include, " #")) or "(none)"),
      "  [2] Tags exclude: " .. (#state.tags_exclude > 0 and ("#" .. table.concat(state.tags_exclude, " #")) or "(none)"),
      "  [3] Note type:    " .. (#state.note_types > 0 and table.concat(state.note_types, ", ") or "(none)"),
      "  [4] Date range:   " .. sub_filters.format_date_filter(state),
      "  [5] Depth:        " .. state.depth,
      "  [6] Path exclude: " .. (#state.paths_exclude > 0 and table.concat(state.paths_exclude, ", ") or "(none)"),
      "  [7] Toggles:      " .. sub_filters.format_toggles(state),
    }
    if search_expr_enabled then
      lines[#lines + 1] = "  [8] Search expr:  " .. (state.search_expr or "(none)")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  [r] Reset all   [a] Apply & close   [q] Cancel"
    return lines
  end

  local menu_lines = render_menu()
  local float = ui.create_float_display({
    title = "Graph Filters",
    lines = menu_lines,
    width = config.graph.filter_menu_width,
    height = #menu_lines,
    cursor_line = true,
  })

  -- Number keys open sub-pickers
  local max_category = search_expr_enabled and 8 or 7
  for i = 1, max_category do
    vim.keymap.set("n", tostring(i), function()
      float.close()
      sub_filters.open_sub_filter(i, state, function()
        M.open_filter_ui(on_apply)
      end)
    end, { buffer = float.buf, nowait = true, silent = true })
  end

  -- Override q/Esc to not apply
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      float.close()
    end, { buffer = float.buf, nowait = true, silent = true })
  end

  vim.keymap.set("n", "a", function()
    float.close()
    on_apply()
  end, { buffer = float.buf, nowait = true, silent = true })

  vim.keymap.set("n", "r", function()
    M.state = M.default_state()
    state = M.state
    vim.bo[float.buf].modifiable = true
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, render_menu())
    vim.bo[float.buf].modifiable = false
  end, { buffer = float.buf, nowait = true, silent = true })
end

return M
