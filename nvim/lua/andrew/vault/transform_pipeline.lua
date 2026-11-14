--- Layered Transform Pipeline — orchestrates Layer 0-3 for buffer processing.
---
--- Replaces the per-updater dispatch loop in highlight_coordinator.run_all()
--- with a three-layer pipeline: change tracking → tokenization → semantic
--- resolution → render diffing. Consumers register render functions that
--- receive pre-parsed, pre-resolved tokens instead of scanning buffers.
---
--- Integrates with highlight_coordinator's existing infrastructure:
--- priority-based dispatch, render_arena scoping, debounce via resource_cleanup.

local line_tracker = require("andrew.vault.line_tracker")
local line_parse = require("andrew.vault.line_parse_cache")
local semantic = require("andrew.vault.semantic_resolution")
local render = require("andrew.vault.render_diff")
local render_arena = require("andrew.vault.render_arena")
local viewport = require("andrew.vault.viewport")
local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("pipeline")
local profiler = require("andrew.vault.memory_profiler")
-- vault_index does NOT require any pipeline module, so a top-level require is
-- non-circular (the per-run lazy require was over-cautious).
local vault_index = require("andrew.vault.vault_index")

local M = {}

---@class RenderConsumer
---@field name string
---@field token_types string[] which token types this consumer cares about
---@field ns number extmark namespace
---@field priority number rendering priority
---@field render fun(line_nr: number, resolved: ResolvedToken[]): ExtmarkSpec[]

---@type RenderConsumer[]
local _consumers = {}
local _consumers_registered = false

--- Register a render consumer (replaces per-module buffer scanning).
---@param consumer RenderConsumer
function M.register_consumer(consumer)
  -- Precompute the token-type lookup set once (token_types never changes) so
  -- the per-line consumer loop can skip rebuilding it on every run.
  local type_set = {}
  for _, tt in ipairs(consumer.token_types or {}) do
    type_set[tt] = true
  end
  consumer._type_set = type_set
  _consumers[#_consumers + 1] = consumer
  table.sort(_consumers, function(a, b) return (a.priority or 50) < (b.priority or 50) end)
end

--- Ensure all built-in consumers are registered (called once on first run).
local function ensure_consumers()
  if _consumers_registered then return end
  _consumers_registered = true
  local ok, consumers = pcall(require, "andrew.vault.pipeline_consumers")
  if ok then
    consumers.register_all(M)
  else
    log.warn("failed to load pipeline_consumers: %s", consumers)
  end
end

--- Run the pipeline for a buffer.
--- Called by highlight_coordinator's run_all() in place of per-updater dispatch.
---@param bufnr number
---@param code_excl fun(row: number, col: number): boolean
---@param opts table coordinator options
function M.run(bufnr, code_excl, opts)
  local stop = profiler.start_timer("pipeline.run")
  ensure_consumers()

  -- Layer 0: determine what changed
  local dirty_lines, shifts = line_tracker.consume(bufnr)
  local index = vault_index.current()
  local index_gen = index and index._generation or 0

  -- Apply any pending row-shifts (insert/delete edits) to the line-keyed
  -- caches BEFORE re-parsing, so off-screen cache entries stay correctly
  -- numbered and only the bounded dirty region is re-tokenized. Shifts are
  -- applied in arrival order. Guarded so partial rollout stays safe.
  if shifts then
    for _, s in ipairs(shifts) do
      if line_parse.shift_lines then line_parse.shift_lines(bufnr, s.start_row, s.delta) end
      if semantic.shift_lines then semantic.shift_lines(bufnr, s.start_row, s.delta) end
      -- render needs old_end_row: extmarks on the directly-replaced span are not
      -- auto-tracked by delta, so they must be recreated rather than renumbered.
      if render.shift_lines then render.shift_lines(bufnr, s.start_row, s.delta, s.old_end_row) end
    end
  end

  -- When opts.full is set (e.g., toggle-on, manual refresh), force full reparse/render
  if opts and opts.full then
    dirty_lines = nil
  end

  -- If too many dirty lines, full reparse is cheaper than N individual buf_get_lines calls
  if dirty_lines then
    local threshold = config.pipeline.full_reparse_threshold or 100
    if #dirty_lines > threshold then
      dirty_lines = nil
    end
  end

  -- No-op scroll fast path: an attached buffer with no pending edit yields an
  -- EMPTY (non-nil) dirty list and nil shifts. When the semantic cache is also
  -- current (index unchanged), there is nothing to reparse/resolve/render — the
  -- newly-visible region on large buffers is handled by run_prefetch, not here.
  -- Skip the O(N) line_parse.update / semantic.resolve / apply_diff walks.
  -- Gated by config.pipeline.skip_empty_runs (default true) so it can be disabled.
  local skip_empty = config.pipeline.skip_empty_runs
  if skip_empty == nil then skip_empty = true end
  if skip_empty
    and not (opts and opts.full)
    and dirty_lines
    and #dirty_lines == 0
    and shifts == nil
    and not semantic.is_stale(bufnr, index_gen)
  then
    stop()
    return
  end

  -- Layer 1: re-parse changed lines (or all if dirty_lines is nil)
  line_parse.update(bufnr, dirty_lines, code_excl)

  -- Layer 2: re-resolve changed tokens
  if semantic.is_stale(bufnr, index_gen) then
    -- Index changed: re-resolve everything
    semantic.resolve(bufnr, nil, line_parse, index)
    dirty_lines = nil -- force full render diff
  else
    semantic.resolve(bufnr, dirty_lines, line_parse, index)
  end

  -- Layer 3: compute render instructions and apply diff
  local line_set = {}
  if dirty_lines then
    for _, ln in ipairs(dirty_lines) do line_set[ln] = true end
  else
    -- Full: render all lines for small buffers, but restrict large buffers to
    -- the viewport + margin. apply_diff only touches extmarks whose line is in
    -- line_set, so off-screen highlights persist until scroll/prefetch
    -- re-renders them lazily — no missed highlights within the viewport.
    local total = vim.api.nvim_buf_line_count(bufnr)
    local threshold = config.viewport.full_buffer_threshold or 200
    if total <= threshold then
      for i = 0, total - 1 do line_set[i] = true end
    else
      -- get_margin_range returns 0-indexed start, exclusive end; for a
      -- non-current window it returns 0,total (i.e. full).
      local s, e = viewport.get_margin_range(bufnr)
      local last = math.min(e - 1, total - 1)
      for i = s, last do line_set[i] = true end
    end
  end

  local arena = opts and opts.arena
  local all_specs = {}
  -- Line-outer / consumer-inner: resolve each line ONCE (semantic.get_resolved
  -- was previously called once per (line x consumer) = ~4x redundant). Lines
  -- with no resolved tokens (blank/plain — the common case) get a single
  -- get_resolved call returning the shared EMPTY sentinel and are skipped
  -- before the consumer loop. Consumer dispatch order is preserved because
  -- _consumers is sorted by priority once at registration, so iterating it in
  -- inner position yields the same per-line dispatch order as before.
  for ln in pairs(line_set) do
    local resolved = semantic.get_resolved(bufnr, ln)
    -- resolved lists are always built as sequences, so [1] == nil means empty.
    if resolved[1] ~= nil then
      for _, consumer in ipairs(_consumers) do
        -- type_set was precomputed at registration (token_types never changes).
        local type_set = consumer._type_set
        -- Filter to token types this consumer handles. Allocate `relevant`
        -- lazily on the first match (arena-pooled when available) so lines with
        -- no matching tokens cost no table allocation.
        local relevant
        for _, rt in ipairs(resolved) do
          if type_set[rt.token.type] then
            if not relevant then
              relevant = arena and render_arena.alloc_table(arena) or {}
            end
            relevant[#relevant + 1] = rt
          end
        end

        if relevant then
          local ok, specs = pcall(consumer.render, ln, relevant)
          if ok and specs then
            for _, spec in ipairs(specs) do
              spec.ns = consumer.ns
              all_specs[#all_specs + 1] = spec
            end
          elseif not ok then
            log.warn("consumer %s render error on line %d: %s", consumer.name, ln, specs)
          end
        end
      end
    end
  end

  -- A `full` run is an explicit "repaint from scratch" (highlight toggle-on,
  -- :Vault*HLRefresh, colorscheme change). Those callers may have cleared a
  -- consumer namespace out of band (hl_coord.make_toggle wipes mod.ns directly),
  -- which leaves render_diff's shadow copy claiming those extmarks still exist —
  -- the diff then sees "no change" and re-paints NOTHING, so toggling a highlight
  -- group back on never restored it. Drop the shadow and wipe the namespaces over
  -- the range we are about to re-render so the specs below are applied fresh.
  if opts and opts.full then
    local lo, hi
    for ln in pairs(line_set) do
      if not lo or ln < lo then lo = ln end
      if not hi or ln > hi then hi = ln end
    end
    if lo then
      for _, consumer in ipairs(_consumers) do
        pcall(vim.api.nvim_buf_clear_namespace, bufnr, consumer.ns, lo, hi + 1)
      end
    end
    render.invalidate(bufnr)
  end

  render.apply_diff(bufnr, all_specs, line_set)

  stop()

  log.debug("pipeline run", {
    bufnr = bufnr,
    dirty_lines = dirty_lines and #dirty_lines or "full",
    specs = #all_specs,
    consumers = #_consumers,
  })
end

--- Track which buffers have been attached to avoid re-clearing.
---@type table<number, true>
local _attached = {}

--- Attach pipeline to a buffer (called once per buffer).
--- On first attach, clears legacy extmarks from shared namespaces
--- to prevent duplicates when switching from legacy to pipeline mode.
---@param bufnr number
function M.attach(bufnr)
  if _attached[bufnr] then return end
  _attached[bufnr] = true
  line_tracker.attach(bufnr)

  -- Clear legacy extmarks from namespaces that pipeline consumers will manage.
  -- This prevents ghost extmarks from the legacy per-updater dispatch.
  ensure_consumers()
  for _, consumer in ipairs(_consumers) do
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, consumer.ns, 0, -1)
  end
end

--- Full invalidation (buffer closed, etc.)
---@param bufnr number
function M.detach(bufnr)
  _attached[bufnr] = nil
  line_tracker.detach(bufnr)
  line_parse.invalidate(bufnr)
  semantic.invalidate(bufnr)
  render.invalidate(bufnr)
end

--- Get the set of coordinator updater names that are covered by pipeline consumers.
--- Updaters not in this set should still be called via legacy dispatch in pipeline mode.
---@type table<string, true>
local _covered_updaters = {
  wikilink_highlights = true,
  tag_highlights = true,
  highlights = true,
  inline_fields = true,
  -- NOTE: footnotes has a no-op consumer (returns {}) — its actual rendering
  -- is in coordinated_update → render_footnotes(), so it must NOT be listed
  -- here. It needs to be dispatched via the uncovered-updater fallback.
  -- NOTE: autolink uses name-based substring matching (not pattern-based
  -- tokenization), so it cannot be a pipeline consumer.
}

--- Check if a coordinator updater is covered by a pipeline consumer.
---@param updater_name string
---@return boolean
function M.is_updater_covered(updater_name)
  ensure_consumers()
  return _covered_updaters[updater_name] == true
end

--- Get the line parse cache module (for downstream modules like footnotes/embed
--- that need to read token positions without re-scanning).
---@return table line_parse_cache module
function M.get_parse_cache()
  return line_parse
end

--- Get the semantic resolution module.
---@return table semantic_resolution module
function M.get_semantic()
  return semantic
end

return M
