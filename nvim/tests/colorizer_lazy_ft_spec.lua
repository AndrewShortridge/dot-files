-- Perf regression spec for nvim-colorizer lazy gating + filetype restriction.
--
-- The plugin spec used to declare no event/ft gate and call
-- `require("colorizer").setup({ "*" })`, force-loading ~15 css color-parser
-- submodules at startup AND attaching a color highlighter to EVERY buffer
-- (incl. markdown/text where inline color preview is rarely wanted). The fix:
--   * gate with `ft = { "css", ... }` (mirroring the `filetypes` table) so it
--     defers off startup AND never loads on markdown/text (ft implies lazy;
--     lazy=false would re-break it).
--   * restrict setup to color-relevant filetypes via the NAMED `filetypes` key.
--
-- API subtlety (catgoose fork): only `opts.filetypes` is honored. A positional
-- list (setup({ "css", ... })) is silently ignored and falls back to { "*" }.
-- So the fix MUST use the named key; the spec asserts `captured[1] == nil`.
--
-- This drives the REAL plugin spec table (dofile) and CALLS its real `config`
-- with a stubbed `require("colorizer")` to capture the opts — no real setup
-- (colorizer is not on rtp under -u NONE). No source introspection.
--
-- Discriminating power:
--   * Re-adding setup({ "*" }) -> captured.filetypes == { "*" }, failing the
--     "no *" / "contains css" assertions.
--   * Reverting to positional setup({ "css", ... }) -> captured[1] ~= nil and
--     captured.filetypes == nil, failing the named-key assertion.
--   * Dropping `ft` (or adding lazy=false) -> fails the gate assertions.
--   * Adding "markdown" back -> fails the "no markdown" assertion.
--
-- Run with: nvim --headless -u NONE -l tests/colorizer_lazy_ft_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/colorizer.lua")

test("plugin spec returns a table for catgoose/nvim-colorizer.lua", function()
  assert_true(type(plug) == "table", "spec must return a table")
  assert_eq(plug[1], "catgoose/nvim-colorizer.lua", "spec must point at the catgoose fork")
end)

test("lazy-gated on color-relevant filetypes (not eager at startup)", function()
  -- The whole point: deferred off startup via ft; ft implies lazy (markdown/text
  -- never load it). lazy=false would re-break the deferral.
  assert_nil(plug.lazy, "lazy must not be set (ft implies lazy; lazy=false would re-break startup deferral)")
  assert_nil(plug.event, "event gate must be removed (replaced by ft)")
  assert_true(type(plug.ft) == "table", "ft gate must exist")
  -- ft must mirror the `filetypes` table and must NOT include markdown/'*'.
  local fts = {}
  for _, ft in ipairs(plug.ft) do fts[ft] = true end
  assert_nil(fts["*"], "ft must not contain the '*' wildcard")
  assert_nil(fts["markdown"], "ft must not contain markdown")
  for _, ft in ipairs({ "css", "scss", "sass", "less", "html", "lua", "javascript", "javascriptreact", "typescript", "typescriptreact" }) do
    assert_true(fts[ft], "ft must contain " .. ft)
  end
  assert_true(type(plug.config) == "function", "config function must exist")
end)

test("config restricts setup to color-relevant filetypes via NAMED key", function()
  -- Stub require("colorizer") to capture the opts; restore even on error.
  local captured
  local real_require = _G.require
  _G.require = function(mod)
    if mod == "colorizer" then
      return { setup = function(o) captured = o end }
    end
    return real_require(mod)
  end
  local ok, err = pcall(plug.config)
  _G.require = real_require
  assert_true(ok, "config must not error: " .. tostring(err))

  assert_true(type(captured) == "table", "colorizer.setup must receive an opts table")

  -- Named key, NOT positional (guards against the no-op positional regression).
  assert_nil(captured[1], "must use named `filetypes` key, not positional setup({ ... })")
  assert_true(type(captured.filetypes) == "table", "captured.filetypes must be a table")

  -- Build a set for membership checks.
  local fts = {}
  for _, ft in ipairs(captured.filetypes) do
    fts[ft] = true
  end

  -- Must NOT include the wildcard or markdown (the explicit narrowing goal).
  assert_nil(fts["*"], "filetypes must not contain the '*' wildcard")
  assert_nil(fts["markdown"], "filetypes must not contain markdown")

  -- Must still colorize the color-relevant filetypes.
  for _, ft in ipairs({ "css", "scss", "html", "lua", "javascript", "typescript" }) do
    assert_true(fts[ft], "filetypes must contain " .. ft)
  end
end)

_H.finish({ style = "results", exit = "os" })
