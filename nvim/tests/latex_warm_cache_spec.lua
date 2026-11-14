-- Behavioral spec: async latex2text cache warming (lua/andrew/vault/latex_warm.lua).
--
-- render-markdown.nvim's latex handler converts each $...$ / $$...$$ equation
-- via vim.system(...):wait() — a synchronous main-thread block (latex2text is
-- ~100-300ms cold). latex_warm.lua pre-converts the equations off the main
-- thread on buffer open so the plugin's per-session cache is hot before the
-- user scrolls.
--
-- The plugin exposes no public cache-write/conversion API. The only safe bridge
-- is the single upvalue of `render-markdown.handler.latex`'s `parse` closure —
-- the live `Handler` table. This spec drives the REAL module against the REAL
-- plugin handler (no mocks of the bridge) on a temp vault, asserting:
--   1. cache-bridge identity — the resolved handle IS the plugin's Handler.cache
--   2. key parity — derived keys exactly match the plugin's input() keys, and
--      `$` inside fenced code blocks is excluded (proves treesitter enumeration,
--      not a raw-text regex)
--   3. skip-existing — keys already in the cache spawn zero processes
--   4. concurrency cap — peak in-flight processes <= config.latex_warm.max_concurrent
--
-- DISCRIMINATING POWER (skip-existing): the spec re-runs warm after disabling the
-- cache-miss filter and asserts the spawn count jumps — proving the skip filter
-- is what suppresses the redundant spawns.
--
-- vim.system is stubbed (no real latex2text dependency, deterministic concurrency
-- accounting). The bridge, key derivation, and treesitter enumeration are real.
--
-- Run with: nvim --headless -u NONE -l tests/latex_warm_cache_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
-- Make the real render-markdown plugin requireable headless.
local plug = vim.fn.stdpath("data") .. "/lazy/render-markdown.nvim"
package.path = plug .. "/lua/?.lua;" .. plug .. "/lua/?/init.lua;" .. package.path
-- The latex parser (needed for markdown -> latex injection enumeration) is
-- built into nvim-treesitter's plugin dir, which `-u NONE` leaves off the rtp.
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/nvim-treesitter")

print("\n=== LaTeX Warm Cache Tests ===\n")

local latex_warm = require("andrew.vault.latex_warm")
local config = require("andrew.vault.config")

-- The latex opts the plugin spec is configured with.
local LATEX_OPTS = { enabled = true, converter = "latex2text" }

-- A scratch markdown buffer with given lines, made current.
local function md_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  return buf
end

-- ---------------------------------------------------------------------------
-- Stub vim.system: record spawns + track peak concurrency. The "process"
-- completes only when we drain it, so we can observe in-flight peak.
-- ---------------------------------------------------------------------------
local function with_stubbed_system(fn)
  local real_system = vim.system
  local real_exec = vim.fn.executable
  -- Pretend latex2text is installed regardless of host.
  vim.fn.executable = function(name)
    if name == "latex2text" then return 1 end
    return real_exec(name)
  end

  local state = {
    spawned = {},      -- list of stdin keys spawned
    in_flight = 0,
    peak = 0,
    pending = {},      -- list of on_exit callbacks awaiting drain
  }
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(_cmd, opts, on_exit)
    state.spawned[#state.spawned + 1] = opts and opts.stdin
    state.in_flight = state.in_flight + 1
    if state.in_flight > state.peak then state.peak = state.in_flight end
    state.pending[#state.pending + 1] = function()
      state.in_flight = state.in_flight - 1
      on_exit({ code = 0, stdout = "RESULT(" .. tostring(opts and opts.stdin) .. ")" })
    end
    return { wait = function() return { code = 0, stdout = "" } end }
  end

  -- Drain all pending completions; runs scheduled callbacks so the pool pumps.
  state.drain = function()
    -- Process FIFO; the pool may enqueue more as each completes.
    local guard = 0
    while #state.pending > 0 do
      guard = guard + 1
      if guard > 10000 then error("drain runaway") end
      local cb = table.remove(state.pending, 1)
      cb()
      vim.wait(0) -- flush vim.schedule callbacks queued by convert_async
    end
    vim.wait(0)
  end

  local ok, err = pcall(fn, state)
  vim.system = real_system
  vim.fn.executable = real_exec
  if not ok then error(err) end
end

-- ---------------------------------------------------------------------------
-- 1. Cache-bridge identity: the resolved handle aliases the plugin's real cache.
-- ---------------------------------------------------------------------------
test("cache handle is the plugin's live Handler.cache", function()
  local handler = latex_warm._cache_handle()
  assert_true(handler ~= nil, "should resolve the plugin Handler:")
  assert_eq(type(handler.cache), "table", "Handler.cache should be a table:")

  -- Write through the handle, then re-resolve and confirm same identity.
  local sentinel = "__warm_identity_probe__"
  handler.cache[sentinel] = "x"
  local again = latex_warm._cache_handle()
  assert_eq(again, handler, "resolution is memoized to the same Handler:")
  assert_eq(again.cache[sentinel], "x", "second resolution sees the same cache:")
  handler.cache[sentinel] = nil
end)

-- ---------------------------------------------------------------------------
-- 2. Key parity: derived keys == plugin input() keys; code-block `$` excluded.
-- ---------------------------------------------------------------------------
test("warmed keys match plugin keys and exclude code-block dollars", function()
  local handler = latex_warm._cache_handle()
  -- Clear any prior cache so all equations are misses.
  for k in pairs(handler.cache) do handler.cache[k] = nil end

  -- The inline-code span `$y$` is NOT a latex injection, so treesitter
  -- enumeration must exclude it (a raw $...$ regex would wrongly match it).
  local buf = md_buf({
    "Inline $x^2$ here and `$y$ in code`.",
    "",
    "$$\\frac{a}{b}$$",
  })

  with_stubbed_system(function(state)
    latex_warm.warm(buf, LATEX_OPTS)
    state.drain()

    -- Exactly the two real equations were spawned (sorted for determinism).
    local got = vim.deepcopy(state.spawned)
    table.sort(got)
    assert_eq(#got, 2, "exactly two equations warmed (inline-code $ excluded):")
    assert_eq(got[1], "\\frac{a}{b}", "block equation key:")
    assert_eq(got[2], "x^2", "inline equation key:")

    -- Successes were written into the plugin cache.
    assert_eq(handler.cache["x^2"], "RESULT(x^2)", "inline result cached:")
    assert_eq(handler.cache["\\frac{a}{b}"], "RESULT(\\frac{a}{b})", "block result cached:")
  end)
end)

-- ---------------------------------------------------------------------------
-- 3. Skip-existing + DISCRIMINATING POWER.
-- ---------------------------------------------------------------------------
test("cache misses only — pre-seeded keys are not re-spawned", function()
  local handler = latex_warm._cache_handle()
  for k in pairs(handler.cache) do handler.cache[k] = nil end
  -- Pre-seed both equations (including an 'error' sentinel, which must be kept).
  handler.cache["x^2"] = "PRESEEDED"
  handler.cache["\\frac{a}{b}"] = "error"

  local buf = md_buf({ "Inline $x^2$.", "", "$$\\frac{a}{b}$$" })

  with_stubbed_system(function(state)
    latex_warm.warm(buf, LATEX_OPTS)
    state.drain()
    assert_eq(#state.spawned, 0, "no spawns when all keys already cached:")
    assert_eq(handler.cache["x^2"], "PRESEEDED", "existing value untouched:")
    assert_eq(handler.cache["\\frac{a}{b}"], "error", "error sentinel preserved:")
  end)

  -- Discriminating power: clear the cache (the "bug" = filter not skipping) and
  -- warm again; now both equations DO spawn. Proves the skip filter is what
  -- suppressed the spawns above.
  for k in pairs(handler.cache) do handler.cache[k] = nil end
  with_stubbed_system(function(state)
    latex_warm.warm(buf, LATEX_OPTS)
    state.drain()
    assert_eq(#state.spawned, 2, "with cache empty, both equations spawn (filter discriminates):")
  end)
end)

-- ---------------------------------------------------------------------------
-- 4. Concurrency cap: peak in-flight <= config.latex_warm.max_concurrent.
-- ---------------------------------------------------------------------------
test("bounded concurrency — peak in-flight respects max_concurrent", function()
  local handler = latex_warm._cache_handle()
  for k in pairs(handler.cache) do handler.cache[k] = nil end

  local cap = config.latex_warm.max_concurrent
  local n = cap + 4

  -- Build a buffer with N distinct inline equations.
  local lines = {}
  for i = 1, n do
    lines[i] = "Eq $a_{" .. i .. "}$ text."
  end
  local buf = md_buf(lines)

  with_stubbed_system(function(state)
    latex_warm.warm(buf, LATEX_OPTS)
    -- Before draining, the pool should have launched exactly `cap` processes.
    assert_eq(state.in_flight, cap, "initial burst equals the concurrency cap:")
    state.drain()
    assert_eq(#state.spawned, n, "all equations eventually spawned:")
    assert_true(state.peak <= cap,
      "peak concurrency must not exceed max_concurrent (" .. cap .. "), got " .. state.peak)
  end)
end)

_H.finish({ style = "results", exit = "os" })
