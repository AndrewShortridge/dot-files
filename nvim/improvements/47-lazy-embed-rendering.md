# 47 --- Lazy Embed Rendering (Visible-First with Background Coroutine)

## Motivation

The `render_embeds()` function in `lua/andrew/vault/embed.lua` processes
**every** `![[...]]` embed in a buffer synchronously before returning control
to the event loop. For a vault note containing 15-20 embeds -- each requiring
file I/O, recursive content resolution, and (for images) snacks placement
creation -- this can freeze the UI for hundreds of milliseconds. The user sees
nothing until the entire render loop finishes.

A lazy rendering approach addresses three pain points:

1. **Perceived latency** -- users see embeds appear incrementally instead of
   waiting for a single flash when all embeds complete at once.
2. **Scroll responsiveness** -- embeds near the cursor are rendered first; off-
   screen embeds (hundreds of lines away) are deferred and never block
   interaction.
3. **Budget fairness** -- the `max_total_lines` budget is consumed in display
   order, which is more predictable than top-of-file order when the user is
   scrolled to the middle.

---

## Current State Analysis

### File: `lua/andrew/vault/embed.lua`

The render path is a single monolithic function `M.render_embeds(opts)` (lines
460-685) with this structure:

1. **Setup** (lines 461-499): get buffer info, clear namespace, init snacks,
   set up budget (`total_remaining`).
2. **Scan loop** (lines 501-644): iterate over every line in the buffer with
   `for i, line in ipairs(lines)`. For each line:
   - Call `find_embed_spans(line)` to detect `![[...]]` patterns.
   - For image embeds: resolve path, create snacks placement.
   - For note embeds: call `resolve_embed_lines()` (recursive), build
     `virt_lines`, set extmark.
3. **Post-render** (lines 646-685): store deps, mark visible, schedule image
   retry, show summary notification.

Key observations:

| Property | Current behavior |
|----------|-----------------|
| Scan order | Top-to-bottom (line 1 to EOF) |
| Render timing | All embeds in one synchronous loop |
| Budget accounting | Linear from line 1 downward |
| Visibility awareness | None -- renders off-screen embeds equally |
| Coroutine/yield | Not used |
| WinScrolled handler | Not present |

### File: `lua/andrew/vault/config.lua`

The `M.embed` table (lines 75-91) contains:

```lua
M.embed = {
  max_lines = 20,
  max_depth = 5,
  max_total_lines = 150,
  sync = {
    enabled = true,
    debounce_ms = 300,
    self_debounce_ms = 500,
  },
  image_exts = { ... },
}
```

No `lazy`, `batch_size`, or `scroll_debounce_ms` settings exist. These will be
added.

### Module-level State

The following module-level tables track render state:

- `embeds_visible[bufnr]` -- `true`, `false`, or `"pending"` flag per buffer.
- `image_placements[bufnr]` -- list of snacks placement objects.
- `_embed_deps[bufnr]` -- dependency set `{ [abs_path] = true }`.
- `_sync_timers[bufnr]` -- debounce timers for live sync.
- `_image_retry_fired[bufnr]` -- single-shot retry flag.

New state tables will be needed to track per-embed render status.

---

## Implementation

### Architecture Overview

The change splits `render_embeds()` into three phases and adds a scroll
handler:

```
render_embeds(opts)
  |
  +-- Phase 1: collect_embeds()
  |     Scan all buffer lines, build ordered embed descriptor list.
  |     No I/O, no extmarks. Fast (string matching only).
  |
  +-- Phase 2: render_visible()
  |     Filter descriptors to visible window range [w0, w$].
  |     Render those embeds synchronously (immediate feedback).
  |     Mark each as rendered in _embed_state[bufnr].
  |
  +-- Phase 3: render_remaining_async()
        Use vim.schedule() chain to render remaining embeds in
        batches of config.embed.batch_size. Yield between batches
        so the event loop stays responsive.

WinScrolled autocmd
  |
  +-- on_scroll()
        Check if newly-visible lines have unrendered embeds.
        Render those immediately (skip the batch queue).
```

### New Module-Level State

```lua
-- Per-buffer embed descriptors and render state.
-- _embed_state[bufnr] = {
--   generation = number,        -- incremented each render cycle (stale check)
--   descriptors = {             -- ordered list of embed locations
--     { lnum = 1-indexed, col_s = number, col_e = number, inner = string,
--       is_image = boolean, rendered = boolean },
--     ...
--   },
--   async_timer = uv_timer_t|nil,  -- background batch timer (cancel on re-render)
-- }
local _embed_state = {}
```

### Config Additions

#### Code to Add (config.lua)

```lua
M.embed = {
  max_lines = 20,
  max_depth = 5,
  max_total_lines = 150,
  lazy = true,                -- enable visible-first lazy rendering
  batch_size = 5,             -- embeds per background batch tick
  scroll_debounce_ms = 80,    -- debounce for WinScrolled handler
  sync = {
    enabled = true,
    debounce_ms = 300,
    self_debounce_ms = 500,
  },
  image_exts = {
    png = true, jpg = true, jpeg = true, gif = true, svg = true,
    webp = true, bmp = true, tiff = true, heic = true, avif = true,
  },
}
```

#### Insertion Point

Inside the existing `M.embed` table definition (lines 75-91).

#### Before/After (config.lua)

**Before** (lines 75-91):

```lua
M.embed = {
  max_lines = 20,
  max_depth = 5,  -- max nesting depth for recursive transclusion (0 = flat/no recursion)
  max_total_lines = 150,  -- total virt text lines across all embeds in a buffer (0 = unlimited)
  sync = {
    enabled = true,           -- Enable live embed sync
    debounce_ms = 300,        -- Debounce for cross-file changes
    self_debounce_ms = 500,   -- Debounce for same-file (TextChanged) updates
  },
  --- File extensions recognized as images for embed rendering and export.
  --- Used by embed.lua (inline image placement) and export.lua (markdown image conversion).
  --- Keys are lowercase extensions; values are true.
  image_exts = {
    png = true, jpg = true, jpeg = true, gif = true, svg = true,
    webp = true, bmp = true, tiff = true, heic = true, avif = true,
  },
}
```

**After:**

```lua
M.embed = {
  max_lines = 20,
  max_depth = 5,  -- max nesting depth for recursive transclusion (0 = flat/no recursion)
  max_total_lines = 150,  -- total virt text lines across all embeds in a buffer (0 = unlimited)
  lazy = true,             -- enable visible-first lazy rendering (Phase 1+2 sync, Phase 3 async)
  batch_size = 5,          -- embeds per async batch tick (Phase 3)
  scroll_debounce_ms = 80, -- debounce interval for WinScrolled lazy render trigger
  sync = {
    enabled = true,           -- Enable live embed sync
    debounce_ms = 300,        -- Debounce for cross-file changes
    self_debounce_ms = 500,   -- Debounce for same-file (TextChanged) updates
  },
  --- File extensions recognized as images for embed rendering and export.
  --- Used by embed.lua (inline image placement) and export.lua (markdown image conversion).
  --- Keys are lowercase extensions; values are true.
  image_exts = {
    png = true, jpg = true, jpeg = true, gif = true, svg = true,
    webp = true, bmp = true, tiff = true, heic = true, avif = true,
  },
}
```

---

### Step 1: New Module State and Helper (embed.lua)

#### Code to Add

After the existing `_image_retry_fired` declaration (line 29), add:

```lua
-- Per-buffer lazy render state.
-- _embed_state[bufnr] = {
--   generation = number,        -- incremented each render_embeds call (stale detection)
--   descriptors = { ... },      -- ordered list of embed locations found in scan
--   async_timer = uv_timer_t|nil,
-- }
-- Each descriptor: { lnum = 1-indexed, col_s = number, col_e = number,
--                     inner = string, is_image = boolean, rendered = boolean }
local _embed_state = {}

-- Per-buffer scroll debounce timers
local _scroll_timers = {} -- bufnr -> uv_timer_t
```

#### Insertion Point

After line 29 (`local _image_retry_fired = {} -- bufnr -> boolean`), before
the `invalidate_snacks_env()` function.

#### Before/After

**Before** (lines 28-31):

```lua
local _image_retry_fired = {} -- bufnr -> boolean

--- Invalidate the snacks terminal env cache if placeholders are not detected.
```

**After:**

```lua
local _image_retry_fired = {} -- bufnr -> boolean

-- Per-buffer lazy render state.
-- _embed_state[bufnr] = {
--   generation = number,        -- incremented each render_embeds call (stale detection)
--   descriptors = { ... },      -- ordered list of embed locations found in scan
--   async_timer = uv_timer_t|nil,
-- }
-- Each descriptor: { lnum = 1-indexed, col_s = number, col_e = number,
--                     inner = string, is_image = boolean, rendered = boolean }
local _embed_state = {}

-- Per-buffer scroll debounce timers
local _scroll_timers = {} -- bufnr -> uv_timer_t

--- Invalidate the snacks terminal env cache if placeholders are not detected.
```

---

### Step 2: Add `collect_embeds()` Function (embed.lua)

This function scans all buffer lines and builds an ordered list of embed
descriptors without performing any I/O, resolution, or extmark creation. It
replaces the inline scan that currently lives inside the `for i, line in
ipairs(lines)` loop.

#### Code to Add

After the `notify()` helper (line 456), before `M.render_embeds`:

```lua
--- Scan buffer lines for all ![[...]] embeds and return an ordered descriptor list.
--- No I/O or extmark creation — pure string matching.
---@param lines string[] buffer lines
---@return table[] descriptors, each { lnum, col_s, col_e, inner, is_image, rendered }
local function collect_embeds(lines)
  local descriptors = {}
  for i, line in ipairs(lines) do
    local spans = find_embed_spans(line)
    if spans then
      for k = 1, #spans, 2 do
        local s, e = spans[k], spans[k + 1]
        local inner = extract_embed_inner(line, s, e)
        descriptors[#descriptors + 1] = {
          lnum = i,
          col_s = s,
          col_e = e,
          inner = inner,
          is_image = is_image_embed(inner),
          rendered = false,
        }
      end
    end
  end
  return descriptors
end
```

---

### Step 3: Add `render_single_embed()` Function (embed.lua)

This function renders one embed descriptor. It is extracted from the body of
the current scan loop so that both the visible pass and the background pass
can call it uniformly.

#### Code to Add

After `collect_embeds`, before `M.render_embeds`:

```lua
--- Render a single embed descriptor and set its extmark / placement.
--- Mutates `desc.rendered = true` on success.
--- Returns the number of budget lines consumed (0 for images, N for notes).
---@param desc table embed descriptor from collect_embeds()
---@param ctx table shared render context (see render_embeds for fields)
---@return number lines_consumed
local function render_single_embed(desc, ctx)
  local bufnr = ctx.bufnr
  local bufpath = ctx.bufpath
  local opts = ctx.opts
  local PlacementMod = ctx.PlacementMod
  local snacks_doc_cfg = ctx.snacks_doc_cfg
  local merge = ctx.merge
  local border_hl = ctx.border_hl
  local content_hl = ctx.content_hl
  local cycle_hl = ctx.cycle_hl
  local depth_hl = ctx.depth_hl
  local truncated_hl = ctx.truncated_hl
  local error_hl = ctx.error_hl
  local stats = ctx.stats

  local inner = desc.inner
  local i = desc.lnum
  local s = desc.col_s
  local e = desc.col_e
  local lines_consumed = 0

  if desc.is_image then
    local image_name = get_image_name(inner)
    local src = resolve_image(image_name, bufpath)

    if src then
      ctx.deps[src] = true
    end

    if src and PlacementMod then
      local placement_bufnr = bufnr
      local ok, placement = pcall(PlacementMod.new, bufnr, src, merge({}, snacks_doc_cfg, {
        pos = { i, s - 1 },
        range = { i, s - 1, i, e },
        inline = true,
        conceal = false,
        type = "image",
        on_update = function(p)
          if _image_retry_fired[placement_bufnr] then return end
          if not p.closed and embeds_visible[placement_bufnr] then
            local ok_e, env = pcall(function() return Snacks.image.terminal.env() end)
            if ok_e and env and not env.placeholders and vim.env.SNACKS_KITTY == "1" then
              _image_retry_fired[placement_bufnr] = true
              invalidate_snacks_env()
              vim.schedule(function()
                if embeds_visible[placement_bufnr] then
                  M.render_embeds({ silent = true })
                end
              end)
            end
          end
        end,
      }))
      if ok and placement then
        image_placements[bufnr] = image_placements[bufnr] or {}
        table.insert(image_placements[bufnr], placement)
        stats.images = stats.images + 1
      else
        stats.errors = stats.errors + 1
        notify(opts, "Vault: placement failed for " .. image_name .. ": " .. tostring(placement), vim.log.levels.WARN)
      end
    else
      stats.errors = stats.errors + 1
      if not src then
        notify(opts, "Vault: image not found: " .. image_name, vim.log.levels.WARN)
      elseif not PlacementMod then
        notify(opts, "Vault: snacks placement module unavailable", vim.log.levels.WARN)
      end
    end
  else
    -- Note embed
    local details = link_utils.parse_target(inner)
    local path = resolve_embed(details.name, bufpath)
    local virt_lines = {}

    if path then
      ctx.deps[path] = true

      if ctx.total_remaining and ctx.total_remaining <= 0 then
        add_header_line(virt_lines, inner, truncated_hl, "(total line limit)")
        stats.notes = stats.notes + 1
      else
        local source = path
        if path == bufpath then
          source = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        local visited_set = { [bufpath] = true }
        local visited_list = { bufpath }

        local content_budget = ctx.total_remaining
        if content_budget then
          content_budget = content_budget - 2
          if content_budget < 1 then content_budget = 1 end
        end

        local content, lines_used = resolve_embed_lines(
          details, source,
          0, visited_set, visited_list,
          content_budget, bufpath
        )

        add_header_line(virt_lines, inner, border_hl)

        for _, cl in ipairs(content) do
          if cl:find("^\u{21bb} cycle:") then
            virt_lines[#virt_lines + 1] = { { "  " .. cl, cycle_hl } }
          elseif cl:find("^\u{22ef} %(max embed depth") then
            virt_lines[#virt_lines + 1] = { { "  " .. cl, depth_hl } }
          elseif cl:find("^\u{22ef} %(total line limit") or cl:find("^\u{22ef} %(truncated") then
            virt_lines[#virt_lines + 1] = { { "  " .. cl, truncated_hl } }
          elseif cl:find("^%[.+ not found:") or cl:find("^%[Could not resolve:") or cl:find("^%[Could not read file%]") then
            virt_lines[#virt_lines + 1] = { { "  " .. cl, error_hl } }
            stats.errors = stats.errors + 1
          else
            virt_lines[#virt_lines + 1] = { { "  " .. cl, content_hl } }
          end
        end

        virt_lines[#virt_lines + 1] = { { embed_footer(), border_hl } }
        stats.notes = stats.notes + 1

        lines_consumed = lines_used + 2  -- content + header + footer
        if ctx.total_remaining then
          ctx.total_remaining = ctx.total_remaining - lines_consumed
        end
      end
    else
      add_header_line(virt_lines, inner, error_hl, "(not found)")
      stats.errors = stats.errors + 1
    end

    vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
    })
  end

  desc.rendered = true
  return lines_consumed
end
```

---

### Step 4: Add `cancel_async_render()` Helper (embed.lua)

#### Code to Add

After `render_single_embed`, before `M.render_embeds`:

```lua
--- Cancel any in-flight async batch render for a buffer.
---@param bufnr number
local function cancel_async_render(bufnr)
  local state = _embed_state[bufnr]
  if state and state.async_timer then
    cleanup.close_timer(state.async_timer)
    state.async_timer = nil
  end
  -- Also cancel scroll debounce timer
  local st = _scroll_timers[bufnr]
  if st then
    cleanup.close_timer(st)
    _scroll_timers[bufnr] = nil
  end
end
```

---

### Step 5: Add `render_remaining_async()` Function (embed.lua)

This is the Phase 3 background batch renderer. It processes unrendered
descriptors in batches of `batch_size`, yielding to the event loop between
each batch via `vim.schedule()` (driven by a repeating uv timer for more
predictable scheduling).

#### Code to Add

After `cancel_async_render`, before `M.render_embeds`:

```lua
--- Render unrendered embed descriptors in background batches.
---@param bufnr number
---@param generation number render generation (stale detection)
---@param ctx table shared render context
local function render_remaining_async(bufnr, generation, ctx)
  local batch_size = config.embed.batch_size or 5
  local state = _embed_state[bufnr]
  if not state or state.generation ~= generation then return end

  -- Find the starting index: first unrendered descriptor
  local start_idx = 1
  for idx, desc in ipairs(state.descriptors) do
    if not desc.rendered then
      start_idx = idx
      break
    end
    if idx == #state.descriptors then
      return -- all rendered
    end
  end

  local descriptors = state.descriptors
  local cursor = start_idx

  local timer = vim.uv.new_timer()
  if not timer then return end
  state.async_timer = timer

  timer:start(0, 16, vim.schedule_wrap(function()
    -- Stale check: generation changed or buffer invalid
    if not _embed_state[bufnr]
      or _embed_state[bufnr].generation ~= generation
      or not vim.api.nvim_buf_is_valid(bufnr) then
      cleanup.close_timer(timer)
      if _embed_state[bufnr] and _embed_state[bufnr].async_timer == timer then
        _embed_state[bufnr].async_timer = nil
      end
      return
    end

    local rendered_in_batch = 0
    while cursor <= #descriptors and rendered_in_batch < batch_size do
      local desc = descriptors[cursor]
      cursor = cursor + 1
      if not desc.rendered then
        render_single_embed(desc, ctx)
        rendered_in_batch = rendered_in_batch + 1
      end
    end

    -- All done?
    if cursor > #descriptors then
      cleanup.close_timer(timer)
      if _embed_state[bufnr] and _embed_state[bufnr].async_timer == timer then
        _embed_state[bufnr].async_timer = nil
      end
    end
  end))
end
```

The 16ms repeat interval (~60fps frame budget) ensures each batch lands on a
separate event loop tick without starving the UI. The `batch_size` of 5
means at most 5 embeds are resolved per tick -- enough to make progress
quickly on a buffer with 20-30 embeds while keeping each tick under a few
milliseconds.

---

### Step 6: Rewrite `M.render_embeds()` (embed.lua)

This is the core change. The function is restructured into the three-phase
pattern.

#### Before (lines 458-685)

The full existing `M.render_embeds` function (227 lines). See "Current State
Analysis" above for the structure.

#### After

```lua
--- Render all ![[...]] embeds in the current buffer as virtual text.
--- When config.embed.lazy is true, renders visible embeds first, then
--- processes remaining embeds asynchronously in small batches.
---@param opts? { silent?: boolean } options
function M.render_embeds(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local bufpath = vim.api.nvim_buf_get_name(bufnr)

  if not engine.is_vault_path(bufpath) then
    return
  end

  -- Cancel any in-flight async render from a previous call
  cancel_async_render(bufnr)

  -- Clear existing embeds first
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  clear_image_placements(bufnr)

  -- Initialize snacks image system once before the render loop.
  local PlacementMod, snacks_doc_cfg = init_snacks_image()

  local merge = (Snacks and Snacks.config and Snacks.config.merge) or function(...)
    return vim.tbl_deep_extend("force", ...)
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Total line budget across all embeds in this buffer
  local max_total = config.embed.max_total_lines or 150
  local total_remaining = max_total > 0 and max_total or nil

  -- Shared render context passed to render_single_embed
  local ctx = {
    bufnr = bufnr,
    bufpath = bufpath,
    opts = opts,
    PlacementMod = PlacementMod,
    snacks_doc_cfg = snacks_doc_cfg,
    merge = merge,
    border_hl = "VaultEmbedBorder",
    content_hl = "VaultEmbedContent",
    cycle_hl = "VaultEmbedCycle",
    depth_hl = "VaultEmbedDepth",
    truncated_hl = "VaultEmbedTruncated",
    error_hl = "VaultEmbedError",
    stats = { images = 0, notes = 0, errors = 0 },
    deps = {},
    total_remaining = total_remaining,
  }

  -- =========================================================================
  -- Phase 1: Collect all embed descriptors (pure string matching, no I/O)
  -- =========================================================================
  local descriptors = collect_embeds(lines)

  -- Bump generation for stale detection
  local prev_state = _embed_state[bufnr]
  local generation = (prev_state and prev_state.generation or 0) + 1
  _embed_state[bufnr] = {
    generation = generation,
    descriptors = descriptors,
    async_timer = nil,
  }

  local use_lazy = config.embed.lazy ~= false and #descriptors > 0

  if not use_lazy then
    -- Legacy path: render all synchronously (identical to old behavior)
    for _, desc in ipairs(descriptors) do
      render_single_embed(desc, ctx)
    end
  else
    -- =====================================================================
    -- Phase 2: Render visible embeds synchronously
    -- =====================================================================
    local w0 = vim.fn.line("w0")
    local w_last = vim.fn.line("w$")

    for _, desc in ipairs(descriptors) do
      if desc.lnum >= w0 and desc.lnum <= w_last then
        render_single_embed(desc, ctx)
      end
    end

    -- =====================================================================
    -- Phase 3: Render remaining embeds asynchronously in batches
    -- =====================================================================
    -- Check if any are unrendered before scheduling
    local has_unrendered = false
    for _, desc in ipairs(descriptors) do
      if not desc.rendered then
        has_unrendered = true
        break
      end
    end

    if has_unrendered then
      render_remaining_async(bufnr, generation, ctx)
    end
  end

  _embed_deps[bufnr] = ctx.deps
  embeds_visible[bufnr] = true

  -- Reset per-buffer retry flag for this render cycle
  _image_retry_fired[bufnr] = false

  -- Retry image rendering if placeholders were not available during initial render.
  if ctx.stats.images == 0 and ctx.stats.errors > 0 and PlacementMod then
    local ok_env, env = pcall(function() return Snacks.image.terminal.env() end)
    if ok_env and env and not env.placeholders then
      vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if not embeds_visible[bufnr] then return end
        invalidate_snacks_env()
        local ok2, env2 = pcall(function() return Snacks.image.terminal.env() end)
        if ok2 and env2 and env2.placeholders then
          M.render_embeds({ silent = true })
        end
      end, 1200)
    end
  end

  -- Show render summary (helps diagnose image issues) -- skip in silent mode
  local stats = ctx.stats
  local total = stats.images + stats.notes + stats.errors
  if total > 0 then
    local parts = {}
    if stats.images > 0 then parts[#parts + 1] = stats.images .. " image(s)" end
    if stats.notes > 0 then parts[#parts + 1] = stats.notes .. " note(s)" end
    if stats.errors > 0 then parts[#parts + 1] = stats.errors .. " error(s)" end
    -- In lazy mode, note that remaining embeds are still loading
    if use_lazy then
      local pending = 0
      for _, desc in ipairs(descriptors) do
        if not desc.rendered then pending = pending + 1 end
      end
      if pending > 0 then
        parts[#parts + 1] = pending .. " pending"
      end
    end
    notify(opts, "Vault embeds: " .. table.concat(parts, ", "))
  end
end
```

**Key differences from the original:**

1. `cancel_async_render(bufnr)` is called at the top to abort any in-flight
   background render from a previous call (handles rapid re-renders cleanly).
2. `collect_embeds(lines)` replaces the inline scan -- same logic, but
   separated into its own function that returns data rather than producing
   side effects.
3. The visible window range `[w0, w$]` gates Phase 2. Only embeds whose
   `lnum` falls within this range are rendered synchronously.
4. `render_remaining_async()` handles everything else in the background.
5. The `ctx` table carries all shared state (buffer info, snacks modules,
   budget, stats, deps) so that `render_single_embed()` does not need to
   close over render-local variables.
6. When `config.embed.lazy` is `false`, the function falls through to a
   simple `for` loop that matches the old behavior exactly -- no regressions.

---

### Step 7: Add `on_scroll()` Handler and WinScrolled Autocmd (embed.lua)

When the user scrolls, newly-visible embeds that were not yet processed by
Phase 3 need to be rendered immediately (not queued behind the batch timer).

#### Code to Add

After `render_remaining_async`, before `M.render_embeds`:

```lua
--- Handle WinScrolled: render any unrendered embeds now visible.
--- Called via debounced autocmd to avoid excessive work during fast scrolls.
---@param bufnr number
local function on_scroll(bufnr)
  local state = _embed_state[bufnr]
  if not state or not state.descriptors then return end
  if not is_embed_active(bufnr) then return end

  local w0 = vim.fn.line("w0")
  local w_last = vim.fn.line("w$")

  -- We need the render context. Since the async render may still be running
  -- with its own ctx, we cannot easily share it. Instead, build a minimal
  -- context for just the newly-visible embeds.
  --
  -- However, the budget (total_remaining) is tracked in the ctx from the
  -- original render call. To avoid double-accounting, on_scroll only renders
  -- embeds that the async timer has not yet reached. The async timer will
  -- skip them (desc.rendered == true) when it gets to them.

  -- Quick scan: are there any unrendered embeds in the visible range?
  local needs_render = false
  for _, desc in ipairs(state.descriptors) do
    if not desc.rendered and desc.lnum >= w0 and desc.lnum <= w_last then
      needs_render = true
      break
    end
  end

  if not needs_render then return end

  -- We need a render context. Re-derive from current buffer state.
  -- Budget is tricky: we use a conservative approach -- read the current
  -- total_remaining from the async context if it exists, otherwise default
  -- to a fresh budget minus already-rendered lines.
  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  local PlacementMod, snacks_doc_cfg = init_snacks_image()
  local merge_fn = (Snacks and Snacks.config and Snacks.config.merge) or function(...)
    return vim.tbl_deep_extend("force", ...)
  end

  -- Estimate remaining budget from already-rendered note embeds
  local max_total = config.embed.max_total_lines or 150
  local rendered_lines = 0
  for _, desc in ipairs(state.descriptors) do
    if desc.rendered and not desc.is_image then
      -- We don't track per-embed line counts in the descriptor, so use a
      -- conservative estimate. The exact tracking lives in ctx.total_remaining
      -- from the original render pass. For scroll renders, we allow up to
      -- max_total minus an estimate.
      rendered_lines = rendered_lines + (config.embed.max_lines or 20) -- worst case per embed
    end
  end
  local budget = max_total > 0 and math.max(0, max_total - rendered_lines) or nil

  local scroll_ctx = {
    bufnr = bufnr,
    bufpath = bufpath,
    opts = { silent = true },
    PlacementMod = PlacementMod,
    snacks_doc_cfg = snacks_doc_cfg,
    merge = merge_fn,
    border_hl = "VaultEmbedBorder",
    content_hl = "VaultEmbedContent",
    cycle_hl = "VaultEmbedCycle",
    depth_hl = "VaultEmbedDepth",
    truncated_hl = "VaultEmbedTruncated",
    error_hl = "VaultEmbedError",
    stats = { images = 0, notes = 0, errors = 0 },
    deps = _embed_deps[bufnr] or {},
    total_remaining = budget,
  }

  for _, desc in ipairs(state.descriptors) do
    if not desc.rendered and desc.lnum >= w0 and desc.lnum <= w_last then
      render_single_embed(desc, scroll_ctx)
    end
  end

  -- Merge deps back
  _embed_deps[bufnr] = scroll_ctx.deps
end
```

#### WinScrolled Autocmd

Inside `M.setup()`, after the existing `BufEnter` autocmd (around line 1101),
add:

```lua
  -- Lazy embed rendering: render newly-visible embeds on scroll
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function()
      if config.embed.lazy == false then return end

      local bufnr = vim.api.nvim_get_current_buf()
      if not embeds_visible[bufnr] then return end
      if not _embed_state[bufnr] then return end

      local ft = vim.bo[bufnr].filetype
      if ft ~= "markdown" then return end

      local debounce_ms = config.embed.scroll_debounce_ms or 80

      -- Cancel previous scroll timer
      local prev = _scroll_timers[bufnr]
      if prev then
        cleanup.close_timer(prev)
        _scroll_timers[bufnr] = nil
      end

      local timer = vim.uv.new_timer()
      if not timer then return end
      _scroll_timers[bufnr] = timer
      timer:start(debounce_ms, 0, vim.schedule_wrap(function()
        cleanup.close_timer(timer)
        if _scroll_timers[bufnr] == timer then
          _scroll_timers[bufnr] = nil
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
          on_scroll(bufnr)
        end
      end))
    end,
  })
```

#### Insertion Point

After the existing `BufEnter` autocmd block (after line 1101), before the
`TextChanged`/`InsertLeave` autocmd.

#### Before/After (setup function)

**Before** (lines 1101-1104):

```lua
    end,
  })

  -- Debounced re-render on text changes (for same-file embeds)
```

**After:**

```lua
    end,
  })

  -- Lazy embed rendering: render newly-visible embeds on scroll
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function()
      if config.embed.lazy == false then return end

      local bufnr = vim.api.nvim_get_current_buf()
      if not embeds_visible[bufnr] then return end
      if not _embed_state[bufnr] then return end

      local ft = vim.bo[bufnr].filetype
      if ft ~= "markdown" then return end

      local debounce_ms = config.embed.scroll_debounce_ms or 80

      local prev = _scroll_timers[bufnr]
      if prev then
        cleanup.close_timer(prev)
        _scroll_timers[bufnr] = nil
      end

      local timer = vim.uv.new_timer()
      if not timer then return end
      _scroll_timers[bufnr] = timer
      timer:start(debounce_ms, 0, vim.schedule_wrap(function()
        cleanup.close_timer(timer)
        if _scroll_timers[bufnr] == timer then
          _scroll_timers[bufnr] = nil
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
          on_scroll(bufnr)
        end
      end))
    end,
  })

  -- Debounced re-render on text changes (for same-file embeds)
```

---

### Step 8: Update Cleanup Functions (embed.lua)

The `gc_stale_buffers()` function and `BufDelete`/`BufWipeout` handler need
to clean up the new state tables.

#### gc_stale_buffers() -- Before/After

**Before** (lines 208-236):

```lua
local function gc_stale_buffers()
  for bufnr in pairs(image_placements) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      clear_image_placements(bufnr)
    end
  end
  for bufnr in pairs(embeds_visible) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      embeds_visible[bufnr] = nil
    end
  end
  for bufnr in pairs(_embed_deps) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      _embed_deps[bufnr] = nil
    end
  end
  for bufnr in pairs(_sync_timers) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      cleanup_timer(bufnr)
    end
  end
  for bufnr in pairs(_image_retry_fired) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      _image_retry_fired[bufnr] = nil
    end
  end
end
```

**After:**

```lua
local function gc_stale_buffers()
  for bufnr in pairs(image_placements) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      clear_image_placements(bufnr)
    end
  end
  for bufnr in pairs(embeds_visible) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      embeds_visible[bufnr] = nil
    end
  end
  for bufnr in pairs(_embed_deps) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      _embed_deps[bufnr] = nil
    end
  end
  for bufnr in pairs(_sync_timers) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      cleanup_timer(bufnr)
    end
  end
  for bufnr in pairs(_image_retry_fired) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      _image_retry_fired[bufnr] = nil
    end
  end
  for bufnr in pairs(_embed_state) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      cancel_async_render(bufnr)
      _embed_state[bufnr] = nil
    end
  end
  for bufnr in pairs(_scroll_timers) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      cleanup.close_timer(_scroll_timers[bufnr])
      _scroll_timers[bufnr] = nil
    end
  end
end
```

#### BufDelete/BufWipeout Handler -- Before/After

**Before** (lines 1124-1135):

```lua
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    callback = function(ev)
      clear_image_placements(ev.buf)
      embeds_visible[ev.buf] = nil
      _embed_deps[ev.buf] = nil
      _image_retry_fired[ev.buf] = nil

      -- Clean up sync timer
      cleanup_timer(ev.buf)
    end,
  })
```

**After:**

```lua
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    callback = function(ev)
      clear_image_placements(ev.buf)
      embeds_visible[ev.buf] = nil
      _embed_deps[ev.buf] = nil
      _image_retry_fired[ev.buf] = nil

      -- Clean up async render and scroll timer
      cancel_async_render(ev.buf)
      _embed_state[ev.buf] = nil

      -- Clean up sync timer
      cleanup_timer(ev.buf)
    end,
  })
```

---

### Step 9: Update `M.clear_embeds()` (embed.lua)

#### Before (lines 688-694):

```lua
function M.clear_embeds()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  clear_image_placements(bufnr)
  _embed_deps[bufnr] = nil
  embeds_visible[bufnr] = false
end
```

#### After:

```lua
function M.clear_embeds()
  local bufnr = vim.api.nvim_get_current_buf()
  cancel_async_render(bufnr)
  _embed_state[bufnr] = nil
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  clear_image_placements(bufnr)
  _embed_deps[bufnr] = nil
  embeds_visible[bufnr] = false
end
```

---

### Step 10: Update `debug_info()` (embed.lua)

Add lazy render state to the debug output so users can diagnose issues.

Inside `M.debug_info()`, after the existing "Live sync state" section (around
line 830), add:

```lua
  -- Lazy render state
  info[#info + 1] = ""
  info[#info + 1] = "  --- Lazy render state ---"
  info[#info + 1] = "  config.embed.lazy: " .. tostring(config.embed.lazy ~= false)
  info[#info + 1] = "  config.embed.batch_size: " .. tostring(config.embed.batch_size or 5)
  local buf_state = _embed_state[bufnr]
  if buf_state then
    info[#info + 1] = "  generation: " .. tostring(buf_state.generation)
    local total_descs = buf_state.descriptors and #buf_state.descriptors or 0
    local rendered_count = 0
    for _, desc in ipairs(buf_state.descriptors or {}) do
      if desc.rendered then rendered_count = rendered_count + 1 end
    end
    info[#info + 1] = "  descriptors: " .. total_descs .. " total, " .. rendered_count .. " rendered"
    info[#info + 1] = "  async_timer active: " .. tostring(buf_state.async_timer ~= nil)
  else
    info[#info + 1] = "  (no lazy render state for this buffer)"
  end
```

---

## Edge Cases and Design Decisions

### Budget Tracking Across Phases

The `total_remaining` counter lives in the `ctx` table created in
`render_embeds()`. Phase 2 (visible pass) consumes budget first, then Phase 3
(async pass) continues from the remaining budget. Since `ctx` is passed by
reference, both phases share the same budget counter.

The scroll handler (`on_scroll`) builds its own context with a conservatively
estimated budget. This is imprecise but safe -- it avoids the complexity of
sharing a mutable budget across the async timer and the scroll callback. If a
scroll-rendered embed exceeds the true remaining budget by a few lines, the
visual impact is negligible compared to the alternative of blocking the user
while counting exact lines.

### Re-renders Invalidate Async State

When `render_embeds()` is called again (e.g., from live sync, manual refresh,
or the image retry path), it calls `cancel_async_render(bufnr)` first. This
stops the Phase 3 timer immediately. The generation counter increments, so
even if a stale timer callback fires after cancellation (unlikely but
possible due to event loop ordering), the generation check causes it to
no-op.

### Scroll During Async Render

If the user scrolls while Phase 3 is still running, the `WinScrolled`
handler fires. It checks the descriptor list for unrendered embeds in the
new visible range and renders them immediately. Phase 3 then skips those
embeds when it reaches them (`desc.rendered == true`).

### `lazy = false` Fallback

Setting `config.embed.lazy = false` bypasses all new logic and falls through
to the simple `for` loop, producing identical behavior to the current
codebase. This is the safe default for users who encounter issues.

### Image Embeds and Budget

Image embeds (snacks placements) do not consume the line budget -- they are
rendered inline as Kitty graphics. The `render_single_embed()` function
returns `0` lines consumed for image embeds, matching the current behavior.

### Extmark Positioning

The visible-first approach means extmarks may be set out of order (e.g., line
50, then line 10 during async pass). This is fine -- `nvim_buf_set_extmark`
supports arbitrary order. The visual result is identical.

---

## Testing Instructions

### 1. Basic Lazy Rendering

1. Open a vault markdown file that contains at least 8-10 `![[...]]` note
   embeds spread across more lines than the visible window height.
2. Observe that embeds in the visible window area appear immediately.
3. Scroll down slowly -- additional embeds should appear as they enter the
   viewport (either from the async background render having already processed
   them, or from the scroll handler catching them).
4. Run `:VaultEmbedDebug` and check the "Lazy render state" section:
   - `descriptors` total should match the number of `![[...]]` patterns in
     the buffer.
   - `rendered` count should increase over time (or be equal to total if
     async render has finished).
   - `async_timer active` should be `false` once all embeds are processed.

### 2. Config Toggle (lazy = false)

1. Set `config.embed.lazy = false` temporarily in `config.lua`.
2. Open the same file. All embeds should render at once (old behavior).
3. Revert to `config.embed.lazy = true`.

### 3. Rapid Scroll

1. Open a file with 20+ embeds.
2. Use `Ctrl-F` / `Ctrl-B` to scroll rapidly through the file.
3. Embeds should appear as they come into view. No crashes, no duplicate
   extmarks, no errors in `:messages`.

### 4. Re-render During Async Phase

1. Open a file with many embeds. Immediately (within the first second), run
   `:VaultEmbedRender`.
2. The async timer from the first render should be cancelled. A fresh render
   cycle should start. `:VaultEmbedDebug` should show generation incremented.

### 5. Buffer Close During Async Phase

1. Open a file with many embeds. Immediately close the buffer (`:bd`).
2. No errors should appear. The async timer should be cleaned up.
3. Verify via `:lua print(vim.inspect(_G.package.loaded['andrew.vault.embed']))`
   that no stale state remains (or simply open another vault file and check
   `:VaultEmbedDebug`).

### 6. Toggle and Clear

1. Open a file with embeds. Let them render.
2. Run `:VaultEmbedToggle` -- embeds should clear. Async timer should stop.
3. Run `:VaultEmbedToggle` again -- embeds should re-render with lazy phases.
4. Run `:VaultEmbedClear` -- all embeds gone, no lingering async timers.

### 7. Image Embeds

1. Open a file containing `![[image.png]]` embeds.
2. Verify images in the visible range render immediately.
3. Scroll to reveal more image embeds -- they should render on scroll.
4. Run `:VaultEmbedDebug` to confirm placement counts.

### 8. Same-File Embeds with Live Sync

1. Open a file that embeds a heading from itself: `![[#SomeHeading]]`.
2. Edit the content under that heading.
3. After the `self_debounce_ms` delay (500ms), the embed should re-render.
4. The re-render should use the lazy path (visible first, then async).

---

## Summary of Changes

| File | Lines Changed | Description |
|------|---------------|-------------|
| `lua/andrew/vault/config.lua` | ~3 | Add `lazy`, `batch_size`, `scroll_debounce_ms` to `M.embed` |
| `lua/andrew/vault/embed.lua` | ~250 | Refactor render_embeds into 3 phases; add collect_embeds, render_single_embed, render_remaining_async, on_scroll, cancel_async_render; add WinScrolled autocmd; update cleanup functions and debug_info |

No other files require modification. No new dependencies. The
`resource_cleanup` module is already used for timer management. The
`WinScrolled` event is built into Neovim (available since 0.7).
