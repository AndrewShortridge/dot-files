-- Behavioral spec for js2lua.transpile() memoization.
--
-- transpile() is a pure function of its input, so results are memoized by
-- source text to avoid re-tokenizing/parsing identical query blocks on every
-- render. This spec asserts the OBSERVABLE contract of that cache:
--   * repeated transpiles of the same source return byte-identical output
--   * the cached result matches a fresh (post-clear) recomputation
--   * distinct sources never collide on the same cache key
--   * results stay correct after the cache cap is exceeded (eviction is safe)
--   * error inputs are cached and reported consistently
--   * clear_cache() does not break subsequent transpiles
-- No source-file introspection — only public transpile()/clear_cache() behavior.
--
-- Run with: nvim --headless -u NONE -l tests/js2lua_transpile_cache_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local js2lua = require("andrew.vault.query.js2lua")

print("\n=== js2lua Transpile Cache Tests ===\n")

local SRC_A = "const x = dv.pages('#a')\nfor (let p of x) { dv.paragraph(p.file.name) }"
local SRC_B = "const y = dv.pages('#b')\ndv.list(y.map(p => p.file.name))"

test("repeated transpile of same source returns identical output", function()
  js2lua.clear_cache()
  local r1 = js2lua.transpile(SRC_A)
  local r2 = js2lua.transpile(SRC_A) -- cache hit
  assert_true(type(r1) == "string", "first transpile should succeed")
  assert_eq(r2, r1, "cached result must byte-match first result")
end)

test("cached result matches a fresh post-clear recomputation", function()
  js2lua.clear_cache()
  local fresh = js2lua.transpile(SRC_A)
  local cached = js2lua.transpile(SRC_A)
  js2lua.clear_cache()
  local recomputed = js2lua.transpile(SRC_A) -- cold path again
  assert_eq(cached, fresh, "cache hit must equal cold computation")
  assert_eq(recomputed, fresh, "recompute after clear must equal original")
end)

test("distinct sources do not collide on cache key", function()
  js2lua.clear_cache()
  local a = js2lua.transpile(SRC_A)
  local b = js2lua.transpile(SRC_B)
  assert_true(a ~= b, "different sources must yield different output")
  -- Re-fetch both from cache; each must still return its own value.
  assert_eq(js2lua.transpile(SRC_A), a, "A still maps to A's output")
  assert_eq(js2lua.transpile(SRC_B), b, "B still maps to B's output")
end)

test("results stay correct after cache cap is exceeded", function()
  js2lua.clear_cache()
  local baseline = js2lua.transpile(SRC_A)
  -- Push well past the internal cap (128) with unique sources to force eviction.
  for i = 1, 300 do
    local out = js2lua.transpile("dv.paragraph('n" .. i .. "')")
    assert_true(type(out) == "string", "unique source #" .. i .. " should transpile")
  end
  -- SRC_A was likely evicted; a recompute must still produce the same output.
  assert_eq(js2lua.transpile(SRC_A), baseline, "post-eviction recompute matches")
end)

test("error inputs are cached and reported consistently", function()
  js2lua.clear_cache()
  local r1, e1 = js2lua.transpile("")
  local r2, e2 = js2lua.transpile("")
  assert_nil(r1, "empty input returns nil code")
  assert_true(type(e1) == "string", "empty input returns an error string")
  assert_eq(r2, r1, "repeated empty input returns nil consistently")
  assert_eq(e2, e1, "repeated empty input returns same error")
end)

test("non-string input is rejected without caching errors", function()
  js2lua.clear_cache()
  local r, e = js2lua.transpile(nil)
  assert_nil(r, "nil input returns nil code")
  assert_true(type(e) == "string", "nil input returns an error string")
  -- A valid call afterward must still work.
  assert_true(type(js2lua.transpile(SRC_A)) == "string", "valid call still works")
end)

test("clear_cache leaves the transpiler functional", function()
  local before = js2lua.transpile(SRC_B)
  js2lua.clear_cache()
  local after = js2lua.transpile(SRC_B)
  assert_eq(after, before, "transpile output is stable across clear_cache")
end)

_H.finish({ style = "results", exit = "os" })
