-- Perf regression spec for issue D: invert the transform_pipeline render loop
-- so semantic.get_resolved is called ONCE per line instead of once per
-- (line x consumer), and make get_resolved return a shared EMPTY sentinel on a
-- miss instead of allocating a fresh {} table.
--
-- Before the fix the render loop was structured:
--   for each consumer { for each line { semantic.get_resolved(buf, ln) } }
-- so with ~4 registered consumers get_resolved fired 4x per rendered line, and
-- every miss allocated a brand-new empty table.
--
-- After the fix:
--   for each line { local r = get_resolved(buf, ln); if empty skip;
--                   for each consumer { dispatch } }
-- => get_resolved fires once per line, and misses share one frozen table.
--
-- This spec drives the REAL transform_pipeline / semantic_resolution / line_parse
-- modules against a real temp-vault buffer (no mocks, no source-introspection).
--
-- Discriminating power (repo convention):
--   A. Reverting the loop inversion (consumer-outer / line-inner) makes
--      get_resolved fire #lines x #consumers times => assertion A fails.
--   B. Reverting the sentinel ("or {}" instead of "or EMPTY") makes two misses
--      return DIFFERENT tables => assertion B fails.
--   C. Parity: extmark output across all consumer namespaces is still produced
--      (smoke parity that rendered output is unchanged).
-- Verified manually: reintroducing either bug turns the corresponding
-- assertion red, then reverting restores green.
--
-- Run with: nvim --headless -u NONE -l tests/pipeline_consumer_loop_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

print("\n=== Pipeline consumer-loop inversion Perf Tests ===\n")

local semantic = require("andrew.vault.semantic_resolution")
local pipeline = require("andrew.vault.transform_pipeline")

--- Build a real markdown buffer in a temp vault with `n_content` lines, each
--- carrying a wikilink + a #tag + a ==highlight== + an [inline:: field], plus a
--- run of blank lines so the empty-line fast-skip path is also exercised.
local function make_buffer(n_content, n_blank)
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault, "p")
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/note.md")
  vim.bo[buf].filetype = "markdown"
  local lines = {}
  for i = 1, n_content do
    lines[#lines + 1] =
      "[[Target" .. i .. "]] #tag" .. i .. " ==hl" .. i .. "== [key" .. i .. ":: val]"
  end
  for _ = 1, n_blank do
    lines[#lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf, n_content, n_blank
end

local function code_excl() return false end

-- --------------------------------------------------------------------------
-- A. Call-count: get_resolved fires once per line, NOT once per (line x consumer)
-- --------------------------------------------------------------------------
test("transform_pipeline.run resolves each line once, not once per consumer", function()
  local buf, n_content, n_blank = make_buffer(8, 4)
  local total_lines = n_content + n_blank

  pipeline.attach(buf)
  pipeline.run(buf, code_excl, { full = true }) -- warm caches + resolution gen

  -- (The sibling test below proves >=2 consumers are registered, so the bug's
  -- consumer-major loop would have produced a strictly larger call count.)

  -- Wrap get_resolved with a counter for the next (warm) full run.
  local calls = 0
  local real_get_resolved = semantic.get_resolved
  semantic.get_resolved = function(b, ln)
    calls = calls + 1
    return real_get_resolved(b, ln)
  end

  local ok, err = pcall(function()
    pipeline.run(buf, code_excl, { full = true })
  end)

  semantic.get_resolved = real_get_resolved
  assert_true(ok, "warm full pipeline.run succeeded: " .. tostring(err))

  -- Line-major loop => exactly one get_resolved per line in line_set (all lines,
  -- since this is a small full render). Consumer-major (the bug) would be
  -- total_lines * n_consumers (4) > total_lines.
  assert_eq(calls, total_lines,
    "get_resolved called once per line (line-major loop), not per (line x consumer)")
  -- Guard against a vacuous pass: there must be several lines AND the built-in
  -- consumer set must be > 1 (so the bug's count would differ).
  assert_true(total_lines >= 4, "enough lines to discriminate")

  vim.api.nvim_buf_delete(buf, { force = true })
  pipeline.detach(buf)
end)

-- --------------------------------------------------------------------------
-- A'. Confirm there really are >=2 consumers (so the loop-order matters) by
--     checking the bug's count would have differed. We re-derive #consumers
--     from the number of distinct namespaces that produced extmarks in a render.
-- --------------------------------------------------------------------------
test("more than one consumer is registered (bug would change the count)", function()
  local buf = make_buffer(3, 0)
  pipeline.attach(buf)
  pipeline.run(buf, code_excl, { full = true })

  -- Collect distinct namespaces with extmarks on this buffer. The built-in
  -- consumers use 4 distinct namespaces (wikilink/tag/highlight/inline_field).
  local ns_map = vim.api.nvim_get_namespaces()
  local distinct = 0
  for _, ns in pairs(ns_map) do
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    if #marks > 0 then distinct = distinct + 1 end
  end
  assert_true(distinct >= 2,
    "at least two consumer namespaces emit extmarks (got " .. distinct .. ")")

  vim.api.nvim_buf_delete(buf, { force = true })
  pipeline.detach(buf)
end)

-- --------------------------------------------------------------------------
-- B. Sentinel identity: two misses return the SAME table (no per-miss alloc).
-- --------------------------------------------------------------------------
test("get_resolved returns a shared sentinel table on a miss", function()
  -- Unknown buffer (no cache entry at all) -> miss path.
  local r_nocache_a = semantic.get_resolved(987654321, 0)
  local r_nocache_b = semantic.get_resolved(123456789, 7)
  assert_eq(#r_nocache_a, 0, "no-cache miss is empty")
  assert_true(r_nocache_a == r_nocache_b,
    "two no-cache misses return the SAME sentinel table (not fresh allocations)")

  -- Real buffer with a populated cache: querying line numbers that were never
  -- resolved (rows beyond the buffer) is the miss path (buf.resolved[ln]==nil),
  -- which must return the shared sentinel.
  local buf = make_buffer(2, 0) -- content rows 0,1 cached after run
  pipeline.attach(buf)
  pipeline.run(buf, code_excl, { full = true })

  local r_miss_a = semantic.get_resolved(buf, 500)
  local r_miss_b = semantic.get_resolved(buf, 999)
  assert_eq(#r_miss_a, 0, "unresolved line is empty")
  assert_true(r_miss_a == r_miss_b,
    "two cache-miss lines share one sentinel table")
  -- And the sentinel is the SAME object as the no-cache miss sentinel.
  assert_true(r_miss_a == r_nocache_a, "single module-wide sentinel for all misses")

  -- A content line is a real (distinct) list, never the sentinel.
  local r_hit = semantic.get_resolved(buf, 0)
  assert_true(#r_hit >= 1, "content line resolves tokens")
  assert_true(r_hit ~= r_nocache_a, "a hit is a real list, not the sentinel")

  vim.api.nvim_buf_delete(buf, { force = true })
  pipeline.detach(buf)
end)

-- --------------------------------------------------------------------------
-- C. Parity smoke: rendered extmark output is still produced (count > 0 across
--    several consumer namespaces) after the inversion. Deeper diff parity is
--    covered by line_tracker_shift_spec.lua and the render specs.
-- --------------------------------------------------------------------------
test("rendered output is still produced after the loop inversion (parity smoke)", function()
  local buf = make_buffer(5, 0)
  pipeline.attach(buf)
  pipeline.run(buf, code_excl, { full = true })

  local ns_map = vim.api.nvim_get_namespaces()
  local total_marks = 0
  for _, ns in pairs(ns_map) do
    total_marks = total_marks + #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  end
  assert_true(total_marks > 0, "extmarks were rendered (got " .. total_marks .. ")")

  vim.api.nvim_buf_delete(buf, { force = true })
  pipeline.detach(buf)
end)

_H.finish({ style = "results", exit = "os" })
