local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("embed")
local display_width = require("andrew.vault.text_utils").display_width

local state = require("andrew.vault.embed_state")
local images = require("andrew.vault.embed_images")
local resolver = require("andrew.vault.embed_resolver")
local sync = require("andrew.vault.embed_sync")
local cleanup = require("andrew.vault.resource_cleanup")

local file_cache = require("andrew.vault.file_cache")
local table_pool = require("andrew.vault.table_pool")
local render_arena = require("andrew.vault.render_arena")
local coalescer = require("andrew.vault.request_coalescer")
local viewport = require("andrew.vault.viewport")
local FrameCache = require("andrew.vault.frame_cache")

-- Dedicated pool for embed rendering (config applied via coalescer.configure() in init.lua)
local embed_pool = coalescer.new({ name = "embed" })

local M = {}

local _frame_caches = {} -- bufnr → FrameCache

local function get_frame_cache(bufnr)
  return FrameCache.buf_get(_frame_caches, bufnr)
end

--- Update embed dependencies for a buffer and mark the dep index dirty.
---@param bufnr number
---@param deps table
local function update_deps(bufnr, deps)
  state.get_buf_state(bufnr).deps = deps
  sync.mark_dep_index_dirty()
end

--- Conditional notify shorthand (delegates to notify.conditional with embed logger).
---@param opts { silent?: boolean }
---@param msg string message WITHOUT "Vault: " prefix
---@param level? "info"|"warn"|"error"
local function silent_notify(opts, msg, level)
  notify.conditional(opts, msg, level, log.debug)
end

--- Build an embed header border line.
---@param inner string  the text from between ![[  and ]]
---@param suffix string|nil  optional annotation like "(not found)" or "(total line limit)"
---@return string
local function embed_header(inner, suffix)
  local label = " ![[" .. inner .. "]]"
  if suffix then
    label = label .. " " .. suffix
  end
  label = label .. " "
  local prefix_w = 2
  local border_w = config.embed.border_width
  local tail_w = math.max(4, border_w - prefix_w - display_width(label))
  return string.rep("─", prefix_w) .. label .. string.rep("─", tail_w)
end

--- Build an embed footer border line.
---@return string
local function embed_footer()
  return string.rep("─", config.embed.border_width)
end

--- Append an embed header line to a virt_lines list.
---@param virt_lines table[] target list
---@param inner string embed inner text
---@param hl string highlight group
---@param suffix? string optional annotation like "(not found)"
local function add_header_line(virt_lines, inner, hl, suffix)
  virt_lines[#virt_lines + 1] = { { embed_header(inner, suffix), hl } }
end

local iterate_embeds = state.iterate_embeds

-- Highlight group names (shared across render paths)
local HL_BORDER    = "VaultEmbedBorder"
local HL_CONTENT   = "VaultEmbedContent"
local HL_CYCLE     = "VaultEmbedCycle"
local HL_DEPTH     = "VaultEmbedDepth"
local HL_TRUNCATED = "VaultEmbedTruncated"
local HL_ERROR     = "VaultEmbedError"

--- Classify a content line into its highlight group.
---@param cl string
---@return string highlight group name
local function content_line_hl(cl)
  if cl:find("^\u{21bb} cycle:") then return HL_CYCLE
  elseif cl:find("^\u{22ef} %(max embed depth") then return HL_DEPTH
  elseif cl:find("^\u{22ef} %(total line limit") or cl:find("^\u{22ef} %(truncated") then return HL_TRUNCATED
  elseif cl:find("^%[.+ not found:") or cl:find("^%[Could not resolve:") or cl:find("^%[Could not read file%]") then return HL_ERROR
  else return HL_CONTENT end
end

--- Cached config merge function (resolved once, never changes mid-session).
---@type function|nil
local _cached_merge = nil

--- Initialize snacks image rendering dependencies.
---@return table|nil PlacementMod
---@return table|nil snacks_doc_cfg
---@return function merge
local function init_render_deps()
  local PlacementMod, snacks_doc_cfg = images.init_snacks_image()
  if not _cached_merge then
    _cached_merge = (Snacks and Snacks.config and Snacks.config.merge) or function(...)
      return vim.tbl_deep_extend("force", ...)
    end
  end
  return PlacementMod, snacks_doc_cfg, _cached_merge
end

--- Create a scope-local memoized resolver for resolve_embed().
--- Same false-sentinel pattern as filter_utils.create_memoized_resolver().
---@param bufpath string buffer file path
---@param cache table arena-allocated or plain table for memoization
---@return fun(name: string): string|nil
local function create_resolve_memo(bufpath, cache)
  return function(name)
    local cached = cache[name]
    if cached ~= nil then return cached or nil end
    local result = resolver.resolve_embed(name, bufpath) or false
    cache[name] = result
    return result or nil
  end
end

--- Build a render context table.
---@param resolve_fn? fun(name: string): string|nil memoized resolve_embed wrapper
local function build_render_ctx(bufnr, bufpath, opts, descs, PlacementMod, snacks_doc_cfg, merge, deps, buf_lines, resolve_fn)
  return {
    bufnr = bufnr,
    bufpath = bufpath,
    opts = opts,
    PlacementMod = PlacementMod,
    snacks_doc_cfg = snacks_doc_cfg,
    merge = merge,
    descs = descs,
    deps = deps or {},
    buf_lines = buf_lines, -- cached buffer lines to avoid re-reading for same-file embeds
    stats = { images = 0, notes = 0, errors = 0 },
    border_hl = HL_BORDER,
    truncated_hl = HL_TRUNCATED,
    error_hl = HL_ERROR,
    content_line_hl = content_line_hl,
    frame_cache = get_frame_cache(bufnr),
    resolve_fn = resolve_fn or create_resolve_memo(bufpath, {}),
  }
end

local _desc_pool = table_pool.new(config.pools.embed_descriptor, function(obj)
  obj.lnum = 0
  obj.col_s = 0
  obj.col_e = 0
  obj.inner = nil
  obj.is_image = false
  obj.rendered = false
  obj.lines_used = 0
end)
table_pool.register("embed_descriptor", _desc_pool)

--- Build lightweight descriptors for all embeds in the buffer.
--- Pattern matching only — no I/O or file resolution.
--- When the pipeline parse cache is warm, uses cached tokens instead of
--- re-scanning lines (avoids duplicate regex work).
---@param lines string[]
---@param bufnr number|nil  buffer number (needed for pipeline cache lookup)
---@return table[]
local function build_descriptors(lines, bufnr, range_start, range_end)
  local descs = {}

  local acquire_desc = function()
    return _desc_pool:acquire(function()
      return { lnum = 0, col_s = 0, col_e = 0, inner = nil,
               is_image = false, rendered = false, lines_used = 0 }
    end)
  end

  -- Pipeline path: use cached token positions (cold cache → empty descriptors)
  if bufnr then
    local lpc = require("andrew.vault.line_parse_cache")
    local iter = lpc.pipeline_token_iter(bufnr, "embed")
    if iter then
      for line_nr, token in iter do
        -- If range is specified, skip tokens outside it (0-indexed)
        if range_start and (line_nr < range_start or line_nr >= range_end) then
          goto continue
        end
        local d = acquire_desc()
        d.lnum = line_nr + 1          -- 0-indexed → 1-indexed
        d.col_s = token.start_col + 1 -- 0-indexed → 1-indexed (matches Lua string.find convention)
        d.col_e = token.end_col        -- 0-indexed exclusive end == 1-indexed inclusive end
        d.inner = vim.trim(token.captures[1])
        d.is_image = images.is_image_embed(d.inner)
        descs[#descs + 1] = d
        ::continue::
      end
    end
  end

  return descs
end

--- Pre-read cross-file embed targets into the file cache.
--- Called before rendering so that render_single_embed hits cached content
--- instead of performing individual disk reads per embed.
--- Same-file embeds (path == bufpath) use nvim_buf_get_lines and skip disk I/O.
---@param descs table[] embed descriptors from build_descriptors()
---@param bufpath string current buffer path
local function warm_embed_cache(descs, bufpath, arena_scope, resolve_fn)
  local seen = arena_scope and render_arena.alloc_table(arena_scope) or {}
  for _, desc in ipairs(descs) do
    if not desc.is_image then
      local details = link_utils.parse_target(desc.inner)
      local path = resolve_fn(details.name)
      if path and path ~= bufpath and not seen[path] then
        seen[path] = true
        file_cache.read(path)
      end
    end
  end
end

--- Compute remaining line budget from the descriptor list.
---@param descs table[]
---@param max_total number
---@return number|nil  remaining lines, or nil if unlimited
local function compute_remaining(descs, max_total)
  if max_total <= 0 then return nil end
  local used = 0
  for _, d in ipairs(descs) do
    if d.rendered and not d.is_image then
      used = used + d.lines_used + 2  -- +2 for header/footer
    end
  end
  return max_total - used
end

--- Cancel any in-flight scroll render timer for a buffer.
---@param bufnr number
local function cancel_async_render(bufnr)
  local bst = state.try_get_buf_state(bufnr)
  if bst and bst.scroll_timer then
    bst.scroll_timer:close()
    bst.scroll_timer = nil
  end
end


--- Render a single embed descriptor.
--- Mutates desc (sets .rendered, .lines_used) and ctx (stats, deps).
---@param desc table  embed descriptor
---@param ctx table   render context
local function render_single_embed(desc, ctx)
  local bufnr, bufpath, opts = ctx.bufnr, ctx.bufpath, ctx.opts
  local i, inner, s, e = desc.lnum, desc.inner, desc.col_s, desc.col_e

  -- Parse target once for all non-image paths (cache hit + render both need it)
  local details, path
  if not desc.is_image then
    details = link_utils.parse_target(inner)
    path = ctx.resolve_fn(details.name)
    if path then ctx.deps[path] = true end
  end

  -- Frame cache lookup (note embeds only, not images)
  if not desc.is_image and ctx.frame_cache then
    local cache_key = bufnr .. ":" .. i .. ":" .. inner
    local cached = ctx.frame_cache:get(cache_key)
    if cached then
      vim.api.nvim_buf_set_extmark(bufnr, state.ns, i - 1, 0, {
        virt_lines = cached.virt_lines,
        virt_lines_above = false,
      })
      desc.rendered = true
      desc.lines_used = cached.lines_used
      ctx.stats.notes = ctx.stats.notes + 1
      return
    end
  end

  if desc.is_image then
    local image_name = images.get_image_name(inner)
    local src = images.resolve_image(image_name, bufpath)

    if src then
      ctx.deps[src] = true
    end

    if src and ctx.PlacementMod then
      local placement, err = images.create_placement(
        bufnr, src, ctx.PlacementMod, ctx.snacks_doc_cfg, ctx.merge,
        { i, s - 1 }, { i, s - 1, i, e },
        images.make_on_update(bufnr, function(o) M.render_embeds(o) end)
      )
      if placement then
        ctx.stats.images = ctx.stats.images + 1
      else
        ctx.stats.errors = ctx.stats.errors + 1
        silent_notify(opts, "placement failed for " .. image_name .. ": " .. tostring(err), "warn")
      end
    else
      ctx.stats.errors = ctx.stats.errors + 1
      if not src then
        silent_notify(opts, "image not found: " .. image_name, "warn")
      elseif not ctx.PlacementMod then
        silent_notify(opts, "snacks placement module unavailable", "warn")
      end
    end
    desc.rendered = true
  else
    -- details and path already computed above (hoisted before cache lookup)
    -- Per-embed arena scope: virt_lines is consumed by nvim_buf_set_extmark
    -- (Neovim copies virtual text data into C structs), so the Lua table is
    -- ephemeral and safe to recycle after the API call returns.
    local embed_scope = render_arena.begin_scope()
    local virt_lines = render_arena.alloc_table(embed_scope)

    if path then
      local total_remaining = compute_remaining(ctx.descs, config.embed.max_total_lines)

      if total_remaining and total_remaining <= 0 then
        add_header_line(virt_lines, inner, ctx.truncated_hl, "(total line limit)")
        ctx.stats.notes = ctx.stats.notes + 1
        desc.lines_used = 0
      else
        local source = path
        if path == bufpath then
          source = ctx.buf_lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        local visited_set = render_arena.alloc_table(embed_scope)
        visited_set[bufpath] = true
        local visited_list = render_arena.alloc_array(embed_scope, 8)
        visited_list[1] = bufpath

        local content_budget = total_remaining
        if content_budget then
          content_budget = content_budget - 2
          if content_budget < 1 then content_budget = 1 end
        end

        local content, lines_used = resolver.resolve_embed_lines(
          details, source, 0, visited_set, visited_list, content_budget, bufpath
        )

        add_header_line(virt_lines, inner, ctx.border_hl)

        for _, cl in ipairs(content) do
          local hl = ctx.content_line_hl(cl)
          virt_lines[#virt_lines + 1] = { { "  " .. cl, hl } }
          if hl == ctx.error_hl then ctx.stats.errors = ctx.stats.errors + 1 end
        end

        virt_lines[#virt_lines + 1] = { { embed_footer(), ctx.border_hl } }
        ctx.stats.notes = ctx.stats.notes + 1
        desc.lines_used = lines_used
      end
    else
      add_header_line(virt_lines, inner, ctx.error_hl, "(not found)")
      ctx.stats.errors = ctx.stats.errors + 1
      desc.lines_used = 0
    end

    vim.api.nvim_buf_set_extmark(bufnr, state.ns, i - 1, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
    })
    -- Store in frame cache (deep copy before arena recycles the tables)
    if ctx.frame_cache then
      local cache_key = bufnr .. ":" .. i .. ":" .. inner
      ctx.frame_cache:set(cache_key, {
        virt_lines = FrameCache.copy_virt_lines(virt_lines),
        lines_used = desc.lines_used,
      })
    end
    render_arena.end_scope(embed_scope)
    desc.rendered = true
  end
end

--- Render unrendered descriptors whose line falls within [top, bot].
---@param descs table[] descriptor list
---@param ctx table render context
---@param top number 1-indexed top line (inclusive)
---@param bot number 1-indexed bottom line (inclusive)
---@return number rendered_count
local function render_in_range(descs, ctx, top, bot)
  local count = 0
  for _, d in ipairs(descs) do
    if not d.rendered and d.lnum >= top and d.lnum <= bot then
      render_single_embed(d, ctx)
      count = count + 1
    end
  end
  return count
end

--- Check if a descriptor generation is still current for a buffer.
--- Returns the current descriptor state if valid, nil otherwise.
---@param bufnr number
---@param generation number expected generation
---@return table|nil current descriptor state
local function check_generation(bufnr, generation)
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local bst_chk = state.try_get_buf_state(bufnr)
  local ds = bst_chk and bst_chk.descriptors
  if not ds or ds.generation ~= generation then return nil end
  return ds
end

--- Close image placements that have scrolled far off-screen.
--- Uses viewport.should_cleanup() to determine threshold.
--- Marks associated descriptors as unrendered for re-render on scroll-back.
---@param bufnr number
local function gc_distant_placements(bufnr)
  local gc_bst = state.try_get_buf_state(bufnr)
  local handles = gc_bst and gc_bst.placements
  if not handles or #handles == 0 then return end

  local ds = gc_bst.descriptors
  local kept = {}

  for _, handle in ipairs(handles) do
    local entry = images.get_placement(handle)
    if not entry then goto continue end
    local lnum = entry.lnum
    if lnum and viewport.should_cleanup(lnum) then
      images.remove_placement(handle)
      -- Mark matching descriptor as unrendered for re-render on scroll-back
      if ds then
        for _, desc in ipairs(ds.list) do
          if desc.lnum == lnum and desc.is_image then
            desc.rendered = false
            break
          end
        end
      end
    else
      kept[#kept + 1] = handle
    end
    ::continue::
  end

  gc_bst.placements = kept
end


--- Render all ![[...]] embeds in the current buffer as virtual text.
---@param opts? { silent?: boolean, force?: boolean } options
function M.render_embeds(opts)
  opts = opts or {}
  local stop = require("andrew.vault.memory_profiler").start_timer("embed.render_embeds")
  local bufnr = vim.api.nvim_get_current_buf()
  local bufpath = vim.api.nvim_buf_get_name(bufnr)

  if not engine.is_vault_buf(bufnr) then
    stop()
    return
  end

  -- Quick prefilter: if buffer has never had embeds rendered and doesn't
  -- contain any embed syntax, skip the expensive render path entirely.
  local pre_bst = state.try_get_buf_state(bufnr)
  if not (pre_bst and pre_bst.visible) and not state.has_embeds(bufnr) then
    stop()
    return
  end

  -- Cancel any stale scheduled embed work for this buffer
  local scheduler = require("andrew.vault.work_scheduler")
  scheduler.cancel_domain("embed:" .. bufnr)

  local coalesce_key = "embed_render:" .. bufnr

  -- If a render is already in-flight for this buffer and this is a
  -- non-forced call (BufReadPost/BufEnter), skip — the existing render
  -- will cover it. Forced calls (TextChanged via embed_sync) cancel
  -- the in-flight render and restart.
  if embed_pool:is_pending(coalesce_key) then
    if not opts.force then
      log.debug("render coalesced for buf %d (already in-flight)", bufnr)
      stop()
      return
    end
    embed_pool:cancel(coalesce_key)
  end

  -- Cancel any in-flight async render
  cancel_async_render(bufnr)

  -- Region-scoped invalidation: only clear/rebuild in dirty ranges
  local region_tracker = require("andrew.vault.region_tracker")
  local invalid_ranges = region_tracker.clear_extmarks_in_invalid_ranges(
    bufnr, state.ns, "embed", opts
  )
  if not invalid_ranges then
    silent_notify(opts, "embeds up to date")
    stop()
    return
  end

  -- Clear image placements in invalid ranges (not handled by shared helper)
  for _, range in ipairs(invalid_ranges) do
    images.clear_image_placements_in_range(bufnr, range.start_line, range.end_line)
  end

  -- Mark render as in-flight. The resolve callback is a no-op — the
  -- coalescer entry exists solely so concurrent callers can detect it
  -- via is_pending() and skip the duplicate render.
  embed_pool:request(coalesce_key, function(resolve)
    -- Resolve synchronously at end of render
    local arena_scope = render_arena.begin_scope()

    local ok_inner, err_inner = pcall(function()
      local PlacementMod, snacks_doc_cfg, merge = init_render_deps()

      -- Build descriptors only for invalid ranges, merging with existing
      local new_descs = {}
      for _, range in ipairs(invalid_ranges) do
        local range_descs = build_descriptors(nil, bufnr, range.start_line, range.end_line)
        for _, d in ipairs(range_descs) do
          new_descs[#new_descs + 1] = d
        end
      end

      -- Only read full buffer when there are same-file embeds (![[#Heading]],
      -- ![[^blockid]]). render_single_embed has a fallback read at line 326,
      -- but pre-reading avoids repeated full reads for multiple same-file embeds.
      local lines
      local has_self_embed = false
      for _, d in ipairs(new_descs) do
        if not d.is_image and d.inner then
          local first_char = d.inner:sub(1, 1)
          if first_char == "#" or first_char == "^" then
            has_self_embed = true
            break
          end
        end
      end
      if has_self_embed then
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      end
      local resolve_memo = create_resolve_memo(bufpath, arena_scope and render_arena.alloc_table(arena_scope) or {})
      warm_embed_cache(new_descs, bufpath, arena_scope, resolve_memo)

      -- Merge: keep existing descriptors from valid regions, replace invalid ones
      local render_bst = state.get_buf_state(bufnr)
      local old_state = render_bst.descriptors
      local merged_descs = {}
      local stale_descs = {}
      if old_state and old_state.list then
        for _, d in ipairs(old_state.list) do
          local lnum_0 = d.lnum - 1 -- convert 1-indexed to 0-indexed
          if region_tracker.is_line_in_ranges(lnum_0, invalid_ranges) then
            stale_descs[#stale_descs + 1] = d
          else
            merged_descs[#merged_descs + 1] = d
          end
        end
      end
      -- Release only stale descriptors (from invalid ranges)
      if #stale_descs > 0 then
        _desc_pool:release_batch(stale_descs)
      end
      -- Add new descriptors from invalid ranges
      for _, d in ipairs(new_descs) do
        merged_descs[#merged_descs + 1] = d
      end
      -- Sort by lnum for consistent iteration order
      table.sort(merged_descs, function(a, b) return a.lnum < b.lnum end)

      local generation = (old_state and old_state.generation or 0) + 1
      render_bst.descriptors = { generation = generation, list = merged_descs }
      local descs = new_descs -- render only the new descriptors

      -- Pass merged_descs (not new_descs) so compute_remaining sees the full
      -- descriptor list and correctly accounts for already-rendered embeds.
      -- The rendering loop uses `descs` (new_descs) and guards with d.rendered.
      local ctx = build_render_ctx(bufnr, bufpath, opts, merged_descs, PlacementMod, snacks_doc_cfg, merge, nil, lines, resolve_memo)

      if config.embed.lazy then
        -- Viewport-restricted: render visible zone embeds immediately (synchronous).
        -- Off-screen embeds scheduled as DEFERRED via work_scheduler.
        local zones = viewport.get_zones()
        render_in_range(descs, ctx, zones.visible.start_line, zones.visible.end_line)

        -- Schedule prefetch zones as DEFERRED (300ms delay, behind visible work)
        local gen = generation
        scheduler.schedule(scheduler.DEFERRED, function()
          if not state.is_embed_active(bufnr) then return end
          local ds = render_bst.descriptors
          if not ds or ds.generation ~= gen then return end
          M.on_prefetch(bufnr, zones.above.start_line, zones.above.end_line)
          M.on_prefetch(bufnr, zones.below.start_line, zones.below.end_line)
        end, { domain = "embed:" .. bufnr, label = "prefetch-embed" })
      else
        -- Legacy: render everything synchronously
        for _, desc in ipairs(descs) do
          render_single_embed(desc, ctx)
        end
      end

      update_deps(bufnr, ctx.deps)
      render_bst.visible = true

      render_bst.image_retry_fired = false

      if ctx.stats.images == 0 and ctx.stats.errors > 0 and PlacementMod then
        images.schedule_retry(bufnr, function(o) M.render_embeds(o) end)
      end

      local total = ctx.stats.images + ctx.stats.notes + ctx.stats.errors
      if total > 0 then
        local parts = render_arena.alloc_table(arena_scope)
        if ctx.stats.images > 0 then parts[#parts + 1] = ctx.stats.images .. " image(s)" end
        if ctx.stats.notes > 0 then parts[#parts + 1] = ctx.stats.notes .. " note(s)" end
        if ctx.stats.errors > 0 then parts[#parts + 1] = ctx.stats.errors .. " error(s)" end
        silent_notify(opts, "embeds: " .. table.concat(parts, ", "))
      end
    end)

    render_arena.end_scope(arena_scope)
    if ok_inner then
      -- Mark rendered ranges as valid only on success — if rendering
      -- failed, ranges stay dirty so the next cycle retries them.
      region_tracker.mark_ranges_valid(bufnr, invalid_ranges, "embed")
    else
      log.error("render_embeds failed: %s", err_inner)
    end

    local fc = get_frame_cache(bufnr)
    if fc then fc:finish_frame() end

    -- Resolve synchronously (not via vim.schedule) since we're already
    -- on the main thread and want the entry removed before returning.
    embed_pool:resolve_now(coalesce_key, true, nil)
    stop()
  end, function() end) -- waiter callback is a no-op
end

--- Build render context, render in range, and update deps.
--- Shared between on_prefetch and WinScrolled scroll callback.
---@param bufnr number
---@param descs table descriptor list
---@param start_line number
---@param end_line number
---@param deps table existing deps to reuse
---@param buf_lines? string[] optional cached buffer lines
local function do_render_pass(bufnr, descs, start_line, end_line, deps, buf_lines)
  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  local PlacementMod, snacks_doc_cfg, merge = init_render_deps()
  local ctx = build_render_ctx(
    bufnr, bufpath, { silent = true }, descs,
    PlacementMod, snacks_doc_cfg, merge,
    deps, buf_lines
  )
  render_in_range(descs, ctx, start_line, end_line)
  update_deps(bufnr, ctx.deps)
end

--- Prefetch callback for the coordinator's Phase 2 dispatch.
--- Renders unrendered embeds in the given line range (above/below prefetch zones).
--- Uses embed's own frame cache for cache warming — prefetched embeds get
--- cache hits when they later enter the visible zone.
--- @param bufnr number
--- @param start_line number 1-indexed
--- @param end_line number 1-indexed
function M.on_prefetch(bufnr, start_line, end_line)
  if not config.embed.lazy then return end
  if not state.is_embed_active(bufnr) then return end
  local pf_bst = state.try_get_buf_state(bufnr)
  local ds = pf_bst and pf_bst.descriptors
  if not ds then return end

  -- Avoid prefetching while a full render is in-flight
  local coalesce_key = "embed_render:" .. bufnr
  if embed_pool:is_pending(coalesce_key) then return end

  -- Check if any unrendered embeds exist in the prefetch range
  local has_work = false
  for _, d in ipairs(ds.list) do
    if not d.rendered and d.lnum >= start_line and d.lnum <= end_line then
      has_work = true
      break
    end
  end
  if not has_work then return end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  do_render_pass(bufnr, ds.list, start_line, end_line, pf_bst.deps or {}, buf_lines)
end

--- Clear all embed virtual text and image placements from the current buffer.
function M.clear_embeds()
  local bufnr = vim.api.nvim_get_current_buf()
  state.clear_buffer_state(bufnr, { clear_namespace = true })
end

--- Toggle embed rendering on/off in the current buffer.
function M.toggle_embeds()
  local bufnr = vim.api.nvim_get_current_buf()
  local tog_bst = state.try_get_buf_state(bufnr)
  if tog_bst and tog_bst.visible then
    M.clear_embeds()
  else
    M.render_embeds()
  end
end

--- Show diagnostic info about the embed/image system.
function M.debug_info()
  local info = { "Embed Debug:" }

  local placement_mod = images.init_snacks_image()
  info[#info + 1] = "  Snacks global: " .. tostring(Snacks ~= nil)
  info[#info + 1] = "  Snacks.image: " .. tostring(Snacks and Snacks.image ~= nil)

  if Snacks and Snacks.image then
    local cfg = Snacks.image.config
    info[#info + 1] = "  image.config.enabled: " .. tostring(cfg and cfg.enabled)
    info[#info + 1] = "  image.config.force: " .. tostring(cfg and cfg.force)
    if cfg and cfg.doc then
      info[#info + 1] = "  doc.enabled: " .. tostring(cfg.doc.enabled)
      info[#info + 1] = "  doc.inline: " .. tostring(cfg.doc.inline)
      info[#info + 1] = "  doc.max_width: " .. tostring(cfg.doc.max_width)
      info[#info + 1] = "  doc.max_height: " .. tostring(cfg.doc.max_height)
    end

    local ok, env = images.safe_terminal_env("debug_info")
    if ok and env then
      info[#info + 1] = "  terminal.env.name: " .. tostring(env.name)
      info[#info + 1] = "  terminal.env.supported: " .. tostring(env.supported)
      info[#info + 1] = "  terminal.env.placeholders: " .. tostring(env.placeholders)
      if not env.placeholders then
        info[#info + 1] = "  *** WARNING: placeholders=false — inline images need Kitty Unicode placeholders"
      end
    else
      info[#info + 1] = "  terminal.env: " .. (ok and "nil" or tostring(env))
    end

    info[#info + 1] = "  placement module: " .. tostring(placement_mod ~= nil)
    info[#info + 1] = "  placement.new: " .. tostring(placement_mod and type(placement_mod.new))
  end

  info[#info + 1] = "  SNACKS_KITTY: " .. tostring(os.getenv("SNACKS_KITTY") or "unset")
  info[#info + 1] = "  KITTY_WINDOW_ID: " .. tostring(os.getenv("KITTY_WINDOW_ID") or "unset")
  info[#info + 1] = "  KITTY_PID: " .. tostring(os.getenv("KITTY_PID") or "unset")
  info[#info + 1] = "  TERM: " .. tostring(os.getenv("TERM") or "unset")

  if Snacks and Snacks.image and Snacks.image.terminal then
    local term = Snacks.image.terminal
    info[#info + 1] = ""
    info[#info + 1] = "  --- Terminal detection state ---"
    info[#info + 1] = "  _env cached: " .. tostring(term._env ~= nil)
    if term._env then
      info[#info + 1] = "  _env.name: " .. tostring(term._env.name)
      info[#info + 1] = "  _env.supported: " .. tostring(term._env.supported)
      info[#info + 1] = "  _env.placeholders: " .. tostring(term._env.placeholders)
    end
    info[#info + 1] = "  _terminal cached: " .. tostring(term._terminal ~= nil)
    if term._terminal then
      info[#info + 1] = "  _terminal.terminal: " .. tostring(term._terminal.terminal)
      info[#info + 1] = "  _terminal.version: " .. tostring(term._terminal.version)
      local pending = term._terminal.pending
      info[#info + 1] = "  _terminal.pending: " .. (pending and (#pending .. " callbacks") or "nil (detection complete)")
    end
    if vim.env.SNACKS_KITTY == "1" and term._env and not term._env.placeholders then
      info[#info + 1] = "  *** RACE DETECTED: SNACKS_KITTY=1 but placeholders=" .. tostring(term._env.placeholders)
      info[#info + 1] = "  *** env() was cached before SNACKS_KITTY was set or before DA3 completed"
      info[#info + 1] = "  *** Run :VaultImageRetry to invalidate cache and re-render"
    end
  end

  local magick_ok = vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1
  info[#info + 1] = "  imagemagick: " .. (magick_ok and "available" or "NOT FOUND")
  if not magick_ok then
    info[#info + 1] = "  *** WARNING: imagemagick not found — image conversion will fail"
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local dbg_bst = state.try_get_buf_state(bufnr)
  local resolved = images.resolve_placements(bufnr)
  info[#info + 1] = "  Active placements (buf " .. bufnr .. "): " .. #resolved
  for idx, pair in ipairs(resolved) do
    local p = pair.entry.placement
    local pinfo = "    [" .. idx .. "] "
    local p_ok, p_err = pcall(function()
      local src_name = p.img and vim.fs.basename(p.img.src or "?") or "?"
      local ready = p.img and p.img:ready() or false
      local failed = p.img and p.img:failed() or false
      local sent = p.img and p.img.sent or false
      local closed = p.closed or false
      pinfo = pinfo .. src_name
        .. " lnum=" .. tostring(pair.entry.lnum)
        .. " ready=" .. tostring(ready)
        .. " failed=" .. tostring(failed)
        .. " sent=" .. tostring(sent)
        .. " closed=" .. tostring(closed)
      if failed and p.img._convert then
        for _, step in ipairs(p.img._convert.steps or {}) do
          if step.err then
            pinfo = pinfo .. "\n      convert error (" .. (step.name or "?") .. "): " .. tostring(step.err)
          end
        end
      end
    end)
    if not p_ok then
      log.debug("debug_info placement[%d] inspection failed: %s", idx, tostring(p_err))
    end
    info[#info + 1] = pinfo
  end
  info[#info + 1] = "  Embeds visible: " .. tostring(dbg_bst and dbg_bst.visible or false)
  info[#info + 1] = "  config.embed.max_depth: " .. tostring(config.embed.max_depth)
  info[#info + 1] = "  config.embed.max_lines: " .. tostring(config.embed.max_lines)
  info[#info + 1] = "  config.embed.max_total_lines: " .. tostring(config.embed.max_total_lines)

  info[#info + 1] = ""
  info[#info + 1] = "  --- Live sync state ---"
  info[#info + 1] = "  Subscription active: " .. tostring(state._subscription ~= nil and state._subscription.is_active())
  local dep_set_count = 0
  for _, st_rec in state.iter_buffers() do
    if st_rec.deps and next(st_rec.deps) then dep_set_count = dep_set_count + 1 end
  end
  info[#info + 1] = "  Tracked dep sets: " .. tostring(dep_set_count)
  info[#info + 1] = "  Active sync channels: " .. tostring(sync.channel_count())
  local buf_deps = dbg_bst and dbg_bst.deps
  if buf_deps then
    local dep_count = vim.tbl_count(buf_deps)
    info[#info + 1] = "  Deps for buf " .. bufnr .. ": " .. dep_count
    for dep_path in pairs(buf_deps) do
      info[#info + 1] = "    " .. dep_path
    end
  else
    info[#info + 1] = "  Deps for buf " .. bufnr .. ": (none)"
  end

  info[#info + 1] = ""
  info[#info + 1] = "  --- Embed scan (current buffer) ---"
  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  info[#info + 1] = "  Buffer: " .. bufpath
  info[#info + 1] = "  Is vault path: " .. tostring(engine.is_vault_path(bufpath))
  info[#info + 1] = "  Vault root: " .. tostring(engine.vault_path)

  info[#info + 1] = "  PlacementMod available: " .. tostring(placement_mod ~= nil)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local embed_count = 0
  iterate_embeds(lines, function(i, inner, s)
    embed_count = embed_count + 1
    local is_img = images.is_image_embed(inner)
    local detail = "    L" .. i .. ":" .. s .. " ![[" .. inner .. "]]"
    if is_img then
      local image_name = images.get_image_name(inner)
      local src = images.resolve_image(image_name, bufpath)
      if src then
        detail = detail .. "  -> IMAGE (resolved: " .. src .. ")"
      else
        detail = detail .. "  -> IMAGE *** NOT FOUND ***"
        for _, searched in ipairs(images.get_image_search_paths(image_name, bufpath)) do
          detail = detail .. "\n      searched: " .. searched
        end
      end
    else
      local details = link_utils.parse_target(inner)
      local path = resolver.resolve_embed(details.name, bufpath)
      detail = detail .. "  -> NOTE (resolved: " .. tostring(path) .. ")"
    end
    info[#info + 1] = detail
  end)
  if embed_count == 0 then
    info[#info + 1] = "    (no ![[...]] patterns found in buffer)"
  end
  info[#info + 1] = "  Total embeds found: " .. embed_count

  info[#info + 1] = ""
  info[#info + 1] = "  --- Snacks inline state ---"
  info[#info + 1] = "  snacks_image_attached: " .. tostring(vim.b[bufnr].snacks_image_attached or false)

  if Snacks and Snacks.image and Snacks.image.placement then
    local snacks_ns = Snacks.image.placement.ns
    if snacks_ns then
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, snacks_ns, 0, -1, {})
      info[#info + 1] = "  snacks extmarks in buf: " .. #marks
    end
  end

  if Snacks and Snacks.image and Snacks.image.doc then
    local find_ok, find_err = pcall(function()
      Snacks.image.doc.find(bufnr, function(imgs)
        info[#info + 1] = "  snacks doc.find() results: " .. #imgs
        for idx, img in ipairs(imgs) do
          info[#info + 1] = "    [" .. idx .. "] src=" .. tostring(img.src)
            .. " type=" .. tostring(img.type)
            .. " pos=" .. vim.inspect(img.pos)
        end
        notify.info_lines(info)
      end)
    end)
    if not find_ok then
      log.debug("debug_info doc.find() failed: %s", tostring(find_err))
      info[#info + 1] = "  snacks doc.find() error"
      notify.info_lines(info)
    end
    return
  end

  notify.info_lines(info)
end

--- Render embeds for a specific buffer.
--- When bufnr is the current buffer, renders immediately.
--- When bufnr is not current, invalidates state so the buffer re-renders
--- on next BufEnter (rendering a non-visible buffer is wasteful since
--- lazy mode needs a visible window range).
---@param bufnr number
---@param opts? { silent?: boolean }
function M.render_embeds_buf(bufnr, opts)
  if vim.api.nvim_get_current_buf() == bufnr then
    M.render_embeds(opts)
    return
  end

  cancel_async_render(bufnr)
  local reb_bst = state.get_buf_state(bufnr)
  reb_bst.descriptors = nil
  reb_bst.visible = false
end

function M.setup()
  local palette = require("andrew.vault.command_palette")

  local function register_cmd(name, desc, fn)
    vim.api.nvim_create_user_command(name, fn, { desc = desc })
    palette.register_command(name, desc, "Embed", fn)
  end

  register_cmd("VaultEmbedRender", "Vault: render embed transclusions", function()
    M.render_embeds()
  end)

  register_cmd("VaultEmbedClear", "Vault: clear embed transclusions", function()
    M.clear_embeds()
  end)

  register_cmd("VaultEmbedToggle", "Vault: toggle embed transclusions", function()
    M.toggle_embeds()
  end)

  register_cmd("VaultEmbedDebug", "Vault: show embed/image debug info", function()
    M.debug_info()
  end)

  register_cmd("VaultViewportDebug", "Vault: show viewport rendering debug info", function()
    local info = { "Viewport Debug:" }
    local winid = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_get_current_buf()
    local vp = viewport.refresh(winid)

    info[#info + 1] = string.format("  Window: %d, Buffer: %d", winid, bufnr)
    info[#info + 1] = string.format("  Visible: %d-%d (%d lines)", vp.first, vp.last, vp.height)
    local zones = viewport.get_zones(winid)
    info[#info + 1] = string.format("  Prefetch above: %d-%d", zones.above.start_line, zones.above.end_line)
    info[#info + 1] = string.format("  Prefetch below: %d-%d", zones.below.start_line, zones.below.end_line)
    info[#info + 1] = string.format("  Prefetch size: %d lines", zones.prefetch_size)

    local vp_bst = state.try_get_buf_state(bufnr)
    local ds = vp_bst and vp_bst.descriptors
    if ds and ds.list then
      local total = #ds.list
      local rendered = 0
      for _, d in ipairs(ds.list) do
        if d.rendered then rendered = rendered + 1 end
      end
      info[#info + 1] = string.format("  Embeds: %d rendered / %d total", rendered, total)
    else
      info[#info + 1] = "  Embeds: no descriptors"
    end

    info[#info + 1] = string.format("  Image placements: %d", images.placement_count(bufnr))

    local total_extmarks = #vim.api.nvim_buf_get_extmarks(bufnr, state.ns, 0, -1, {})
    local vp_extmarks = #vim.api.nvim_buf_get_extmarks(
      bufnr, state.ns, { vp.first - 1, 0 }, { vp.last - 1, -1 }, {}
    )
    info[#info + 1] = string.format("  Extmarks: %d in viewport / %d total", vp_extmarks, total_extmarks)

    info[#info + 1] = string.format("  Config: prefetch_mult=%.1f, cleanup_threshold=%.1f, full_threshold=%d, prefetch_debounce=%dms",
      config.viewport.prefetch_multiplier, config.viewport.cleanup_threshold, config.viewport.full_buffer_threshold, config.viewport.prefetch_debounce_ms)

    vim.notify(table.concat(info, "\n"), vim.log.levels.INFO)
  end)

  register_cmd("VaultImageRetry", "Vault: invalidate terminal cache and re-render images", function()
    if Snacks and Snacks.image and Snacks.image.terminal then
      local term = Snacks.image.terminal
      local old_placeholders = term._env and term._env.placeholders
      term._env = nil  -- Force unconditional re-detect (unlike invalidate_snacks_env which is conditional)
      local ok, env = images.safe_terminal_env("VaultImageRetry")
      if ok and env then
        notify.info(
          "terminal re-detected:"
          .. " name=" .. tostring(env.name)
          .. " placeholders=" .. tostring(env.placeholders)
          .. " (was " .. tostring(old_placeholders) .. ")"
        )
      end
    end
    M.render_embeds()
  end)

  register_cmd("VaultEmbedSync", "Vault: ensure embed live sync is active", function()
    if sync.ensure_subscription() then
      notify.info("embed sync active")
    else
      notify.index_not_ready("sync not started")
    end
  end)

  local function is_valid_current_buf(bufnr)
    return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr
  end

  local augroup = vim.api.nvim_create_augroup("VaultEmbed", { clear = true })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = augroup,
    pattern = "*.md",
    callback = function(ev)
      if not engine.is_vault_buf(ev.buf) then return end
      state.get_buf_state(ev.buf).visible = "pending"
      local vault_index = require("andrew.vault.vault_index")
      local idx = vault_index.current()
      if idx then
        idx:wait_for_ready(function()
          local sched = require("andrew.vault.work_scheduler")
          sched.schedule(sched.NORMAL, function()
            local ev_bst = state.try_get_buf_state(ev.buf)
            if is_valid_current_buf(ev.buf) and ev_bst and ev_bst.visible == "pending" then
              M.render_embeds({ silent = true })
            end
          end, { domain = "embed:" .. ev.buf, label = "render-on-open" })
        end, "embed.render_on_open")
      end
    end,
  })

  -- BufEnter and TextChanged autocmds removed: now dispatched via event_dispatch.lua

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function()
      if not config.embed.lazy then return end
      local bufnr = vim.api.nvim_get_current_buf()
      local scroll_bst = state.try_get_buf_state(bufnr)
      if not scroll_bst or not scroll_bst.visible then return end
      local ds = scroll_bst.descriptors
      if not ds then return end

      local zones = viewport.get_zones()
      local new_ranges = viewport.newly_visible()
      if not new_ranges then
        gc_distant_placements(bufnr)
        return
      end

      -- Check if any unrendered embeds fall in the visible zone's newly visible lines
      local need_render = false
      for _, range in ipairs(new_ranges) do
        for _, d in ipairs(ds.list) do
          if not d.rendered and d.lnum >= range.first and d.lnum <= range.last then
            need_render = true
            break
          end
        end
        if need_render then break end
      end

      if not need_render then
        gc_distant_placements(bufnr)
        return
      end

      -- Debounced render of newly visible embeds (visible zone only)
      -- Prefetch zones are handled by highlight_coordinator's Phase 2 dispatch
      scroll_bst.scroll_timer = cleanup.debounce(scroll_bst.scroll_timer, config.embed.lazy_scroll_debounce_ms, function()
        if not state.is_embed_active(bufnr) then return end
        -- Note: is_embed_active already validates buf, so check_generation's
        -- buf_is_valid check is redundant but harmless (kept for safety in
        -- other call sites where is_embed_active is not checked first).
        local cur_ds = check_generation(bufnr, ds.generation)
        if not cur_ds then return end

        local cur_zones = viewport.get_zones()
        do_render_pass(bufnr, cur_ds.list, cur_zones.visible.start_line, cur_zones.visible.end_line, (state.try_get_buf_state(bufnr) or {}).deps or {})
        gc_distant_placements(bufnr)
      end)
    end,
  })

  cleanup.on_buf_delete(augroup, function(bufnr)
    state.clear_buffer_state(bufnr)
    _frame_caches[bufnr] = nil
  end)

  -- VimLeavePre autocmd removed: now dispatched via event_dispatch.lua

  local sched = require("andrew.vault.work_scheduler")
  sched.schedule(sched.DEFERRED, function()
    sync.ensure_subscription()
  end, { domain = "embed-sync", label = "init-subscription" })
end

--- Called by event_dispatch.lua on BufEnter for vault markdown buffers.
--- @param ctx { bufnr: number, file: string, is_vault_md: boolean }
function M.on_buf_enter(ctx)
  local scheduler = require("andrew.vault.work_scheduler")

  sync.ensure_subscription()

  -- GC stale buffers as IDLE work (no user-visible effect)
  scheduler.schedule(scheduler.IDLE, function()
    state.gc_stale_buffers()
  end, { domain = "embed-gc", label = "stale-buf-gc" })

  -- Cancel pending embed render work for other buffers (user navigated away)
  for bufnr, st_rec in state.iter_buffers() do
    if bufnr ~= ctx.bufnr and st_rec.visible then
      scheduler.cancel_domain("embed:" .. bufnr)
    end
  end

  local enter_bst = state.try_get_buf_state(ctx.bufnr)
  if not (enter_bst and enter_bst.visible) then
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if idx then
      idx:wait_for_ready(function()
        scheduler.schedule(scheduler.NORMAL, function()
          if is_valid_current_buf(ctx.bufnr) then
            M.render_embeds({ silent = true })
          end
        end, { domain = "embed:" .. ctx.bufnr, label = "render-on-enter" })
      end, "embed.render_on_enter")
    end
  end
end

--- Called by event_dispatch.lua on TextChanged/InsertLeave for vault markdown buffers.
--- @param bufnr number
--- @param file string
function M.on_text_changed(bufnr, file)
  if not config.embed.sync or not config.embed.sync.enabled then return end
  local tc_bst = state.try_get_buf_state(bufnr)
  if not (tc_bst and tc_bst.visible) then return end

  local deps = tc_bst.deps
  if deps and deps[file] then
    sync.schedule_rerender(bufnr)
  end
end

--- Called by event_dispatch.lua on VimLeavePre for cleanup.
function M.teardown()
  for bufnr in pairs(state.all_tracked_buffers()) do
    state.clear_buffer_state(bufnr)
  end
  _frame_caches = {}
  sync.unsubscribe()
end

--- Get the frame cache for a buffer (for debug commands).
---@param bufnr number
---@return table|nil
function M.get_frame_cache(bufnr)
  return _frame_caches[bufnr]
end

-- Deferred profiler registration (safe: profiler may not be loaded yet)
do
  local ok, profiler = pcall(require, "andrew.vault.memory_profiler")
  if ok then
    profiler.register_counter_deferred({
      name = "embed_frame_caches",
      get_count = function()
        local count = 0
        for _, cache in pairs(_frame_caches) do count = count + cache:size() end
        return count
      end,
      description = "embed frame cache entries across all buffers",
    })
  end
end

return M
