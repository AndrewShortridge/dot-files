-- Perf regression spec for Issue F: Throttle WinScrolled zone/GC.
--
-- WinScrolled fires many times per frame during continuous scroll. Three
-- per-tick costs used to run unthrottled:
--   (1) coordinator Phase-2 zone math (get_zones + prefetch_zones_changed)
--       ran synchronously every raw tick, even though the prefetch is already
--       400ms-debounced inside schedule_prefetch.
--   (2) viewport.refresh() recomputed from scratch every call, and get_zones()
--       called nvim_buf_line_count a SECOND time after refresh already read it.
--   (3) embed.on_win_scrolled, when newly_visible() returns nil (the common
--       case), called gc_distant_placements unthrottled, looping every
--       placement handle each tick.
--
-- This spec drives the REAL viewport, highlight_coordinator and embed modules
-- headless against a temp vault buffer and asserts at module seams (NO source
-- introspection). It preserves EXACT behavior (zones byte-identical, ranges
-- still advance on a real move) while proving the throttles.
--
-- Run with:
--   nvim --headless -u NONE -l tests/winscrolled_zone_throttle_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local viewport = require("andrew.vault.viewport")
local highlight_coordinator = require("andrew.vault.highlight_coordinator")
local embed = require("andrew.vault.embed")
local config = require("andrew.vault.config")

print("\n=== WinScrolled Zone/GC Throttle Perf Tests ===\n")

-- Create a tall markdown buffer in a real window so w0/w$ are meaningful.
local function make_buf(nlines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  local lines = {}
  for i = 1, nlines do lines[i] = "line " .. i end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  return buf, vim.api.nvim_get_current_win()
end

-- ---------------------------------------------------------------------------
-- Test A — viewport refresh memo + single line-count (Edit 1).
--   Three calls (get_zones, get_range, get_zones) on a STABLE viewport
--   (no topline change, no buffer edit) must hit nvim_buf_line_count at most
--   once, and the two get_zones results must be byte-identical.
-- Discriminating power: removing the memo, or reverting get_zones to call
--   nvim_buf_line_count directly, makes the counter exceed 1 -> fails.
-- ---------------------------------------------------------------------------
test("refresh memo: line_count read at most once across stable-tick calls", function()
  local buf, winid = make_buf(200)
  viewport.clear_state(buf, winid) -- fresh memo

  local orig = vim.api.nvim_buf_line_count
  local count = 0
  vim.api.nvim_buf_line_count = function(b)
    count = count + 1
    return orig(b)
  end

  local ok, zones1, _, zones2 = pcall(function()
    local z1 = viewport.get_zones(winid)
    viewport.get_range(winid)
    local z2 = viewport.get_zones(winid)
    return z1, nil, z2
  end)

  vim.api.nvim_buf_line_count = orig
  assert_true(ok, "calls must not error")
  assert_true(count <= 1, "nvim_buf_line_count must be called <= 1 across 3 stable-tick calls; got " .. count)

  assert_true(_H.deep_equal(zones1, zones2), "get_zones must be byte-identical across the memoized tick")
end)

-- ---------------------------------------------------------------------------
-- Test B — memo does NOT suppress prev-range advancement on a real move (Edit 1).
--   After a genuine topline change, newly_visible() must return non-nil and the
--   second-position zones must be self-consistent across repeated get_zones.
-- Discriminating power: a memo keyed wrongly (caching across distinct toplines)
--   would make newly_visible() return nil after a move -> fails.
-- ---------------------------------------------------------------------------
test("memo preserves prev-range advancement on a real scroll", function()
  local buf, winid = make_buf(300)
  viewport.clear_state(buf, winid)

  -- Establish a baseline range at the top.
  vim.fn.winrestview({ topline = 1, lnum = 1 })
  viewport.refresh(winid)

  -- Scroll down meaningfully, then refresh.
  vim.fn.winrestview({ topline = 120, lnum = 120 })
  viewport.refresh(winid)

  local nv = viewport.newly_visible(winid)
  assert_true(nv ~= nil, "newly_visible must report new lines after a real move (memo must not suppress prev advance)")

  local z1 = viewport.get_zones(winid)
  local z2 = viewport.get_zones(winid)
  assert_true(_H.deep_equal(z1, z2), "settled-position get_zones must be byte-identical across the memoized tick")
end)

-- ---------------------------------------------------------------------------
-- Test C — embed off-path GC is throttled (Edit 3).
--   When newly_visible() is nil, on_win_scrolled must NOT loop placement
--   handles synchronously; the GC runs only after the debounce fires.
-- We make embed active with a buffer state holding placement handles and spy on
--   images.get_placement (the per-handle cost inside gc_distant_placements that
--   fires for EVERY handle regardless of its return value).
-- Discriminating power: reverting to the synchronous gc_distant_placements(bufnr)
--   call makes get_placement fire on every on_win_scrolled call synchronously ->
--   the "0 before debounce" assertion fails. (Verified by temporary revert.)
-- ---------------------------------------------------------------------------
test("embed off-path GC throttled to debounce cadence", function()
  if not config.embed.lazy then
    -- Off-path GC only runs in lazy mode; nothing to assert otherwise.
    return
  end

  local statemod = require("andrew.vault.embed_state")
  local images = require("andrew.vault.embed_images")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "line 2", "line 3" })
  vim.api.nvim_set_current_buf(buf)
  local winid = vim.api.nvim_get_current_win()

  -- Build an active embed buffer state with placement handles so the GC loop
  -- has work to do. Force newly_visible() to be nil for this win.
  viewport.clear_state(buf, winid)

  local bst = statemod.get_buf_state(buf)
  if not bst then
    error("could not obtain embed buf state")
  end
  bst.visible = true
  bst.descriptors = { list = {}, generation = 0 }
  bst.placements = { "handle-a", "handle-b" }

  -- Spy on get_placement: the per-handle indirection inside gc_distant_placements.
  local orig_get = images.get_placement
  local gp_calls = 0
  images.get_placement = function(...)
    gp_calls = gp_calls + 1
    return orig_get(...)
  end

  local ok = pcall(function()
    -- Fire several ticks in immediate succession (same tick window, newly_visible nil).
    for _ = 1, 5 do
      embed.on_win_scrolled({ bufnr = buf, winid = winid })
    end
  end)

  -- BEFORE the debounce fires: no synchronous per-placement GC work.
  local before = gp_calls

  -- Flush the debounce timer; GC should then run exactly once over the handles.
  vim.wait(config.embed.lazy_scroll_debounce_ms + 120, function() return gp_calls > before end)

  images.get_placement = orig_get

  assert_true(ok, "on_win_scrolled must not error")
  assert_eq(before, 0, "off-path GC must NOT loop placements synchronously per tick (got " .. before .. ")")
  assert_true(gp_calls > before, "GC must run once after the debounce fires (got " .. gp_calls .. ")")
end)

-- ---------------------------------------------------------------------------
-- Test D — coordinator still advances ranges synchronously (Edit 2 ordering).
--   embed.on_win_scrolled (run after coordinator) reads _ranges/_prev_ranges
--   via newly_visible(); the coordinator MUST call viewport.refresh synchronously
--   each tick. Spy on viewport.refresh and fire one coordinator tick.
-- Discriminating power: deferring the synchronous refresh into the throttle
--   timer drops the synchronous refresh count to 0 -> fails.
-- ---------------------------------------------------------------------------
test("coordinator refreshes viewport synchronously each tick (ordering invariant)", function()
  local buf, winid = make_buf(200)
  viewport.clear_state(buf, winid)

  local orig_refresh = viewport.refresh
  local refresh_calls = 0
  viewport.refresh = function(...)
    refresh_calls = refresh_calls + 1
    return orig_refresh(...)
  end

  local ok = pcall(function()
    highlight_coordinator.on_win_scrolled({ bufnr = buf, winid = winid })
  end)

  viewport.refresh = orig_refresh

  assert_true(ok, "coordinator on_win_scrolled must not error")
  assert_true(refresh_calls >= 1, "coordinator must call viewport.refresh synchronously (>=1) so embed's newly_visible sees advanced ranges; got " .. refresh_calls)
end)

-- ---------------------------------------------------------------------------
-- Test E — refresh memo invalidates on window RESIZE (Edit 2 correctness).
--   WinScrolled also fires on window height/width changes WITHOUT a topline or
--   changedtick change. The memo must invalidate when botline ("w$") moves so
--   callers never see a stale pre-resize range (which would under-render newly
--   visible lines on a grow). -l headless mode cannot attach a UI to drive a
--   real resize, so we stub vim.fn.line to control w0/w$ deterministically and
--   drive the REAL viewport.refresh against those inputs (no source introspection).
-- Discriminating power: drop botline from the memo key -> step 2 returns the
--   stale last=5 instead of 19 and the assertion fails. Re-add -> passes.
--   The identity re-assert (step 4) guards against "fix by removing the memo".
-- ---------------------------------------------------------------------------
test("refresh memo invalidates on resize (botline change, stable topline+changedtick)", function()
  local buf, winid = make_buf(50)
  viewport.clear_state(buf, winid)

  local orig_line = vim.fn.line
  local fake_first, fake_last = 1, 5

  local ok, err = pcall(function()
    vim.fn.line = function(expr, w)
      if expr == "w0" then return fake_first
      elseif expr == "w$" then return fake_last
      else return orig_line(expr, w) end
    end

    -- 1. Baseline: small viewport (5 lines). No buffer edit -> changedtick stable.
    local r1 = viewport.refresh(winid)
    assert_eq(r1.last, 5, "baseline last must reflect w$=5")
    assert_eq(r1.height, 5, "baseline height must be 5")

    -- 2. GROW the window (w$ -> 19) WITHOUT changing topline or editing the buffer.
    --    The memo must invalidate so refresh returns the fresh range, not stale 5.
    fake_last = 19
    local r2 = viewport.refresh(winid)
    assert_eq(r2.last, 19, "grow must return fresh last=19, not stale 5")
    assert_eq(r2.height, 19, "grow must return fresh height=19, not stale 5")

    -- 3. SHRINK the window (w$ -> 4) with topline/changedtick still stable.
    fake_last = 4
    local r3 = viewport.refresh(winid)
    assert_eq(r3.last, 4, "shrink must return fresh last=4, not stale 19")

    -- 4. Dedupe still holds: identical first/last/changedtick -> same object,
    --    proving the fix did not disable intra-tick memoization.
    assert_true(viewport.refresh(winid) == viewport.refresh(winid),
      "stable-position refresh must return the SAME memoized range object")
  end)

  vim.fn.line = orig_line
  assert_true(ok, "resize test must not error: " .. tostring(err))
end)

_H.finish({ style = "results", exit = "os" })
