-- Perf regression spec for rustaceanvim lazy gating.
--
-- The plugin spec used to declare `lazy = false`, force-loading rustaceanvim AND
-- its nvim-dap dependency (~30 dap/dap-ui submodules) at startup for EVERY
-- filetype, including markdown/text — even though rustaceanvim is purely
-- filetype-driven (it only acts on rust buffers via vim.g.rustaceanvim). The fix:
-- gate the plugin with `ft = { "rust" }` and move the vim.g.rustaceanvim table
-- assignment from `config` (runs only on load) into `init` (runs at startup
-- WITHOUT loading the plugin), so the global is set before the first rust buffer
-- triggers the lazy load. The codelldb adapter table is inlined (byte-identical
-- to rustaceanvim.config.get_codelldb_adapter) so `init` never requires the
-- not-yet-on-rtp plugin module at startup.
--
-- This drives the REAL plugin spec table (dofile) and CALLS its real `init`
-- under `-u NONE` (rustaceanvim NOT on rtp), proving init does not require the
-- plugin. No source introspection / string scanning.
--
-- Discriminating power:
--   * Re-adding `lazy = false` (or dropping `ft`) fails Test 2.
--   * Leaving the table-setup in `config` instead of `init` fails Test 2.
--   * Re-introducing `require("rustaceanvim.config")` inside init makes init()
--     error under `-u NONE`, failing Test 3.
--   * Drifting any vim.g.rustaceanvim settings or the adapter shape fails Test 4/5.
--
-- Run with: nvim --headless -u NONE -l tests/rustaceanvim_lazy_ft_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/rustaceanvim.lua")

test("plugin spec returns a table for mrcjkb/rustaceanvim", function()
  assert_true(type(plug) == "table", "spec must return a table")
  assert_eq(plug[1], "mrcjkb/rustaceanvim", "spec must point at rustaceanvim")
end)

test("lazy-gated on rust filetype (not eager)", function()
  -- The whole point: no `lazy = false`, and `ft` implies lazy.
  assert_nil(plug.lazy, "lazy must not be set (ft implies lazy; lazy=false would re-break it)")
  assert_true(type(plug.ft) == "table", "ft gate must exist")
  assert_eq(plug.ft[1], "rust", "ft must be { 'rust' }")
  -- Table setup moved out of config into init.
  assert_true(type(plug.init) == "function", "init must set vim.g.rustaceanvim at startup")
  assert_nil(plug.config, "config must not remain (moved to init)")
end)

test("init sets vim.g.rustaceanvim WITHOUT loading the plugin (no rtp require)", function()
  -- Under `-u NONE` rustaceanvim is not on the runtimepath. Defensively ensure no
  -- stale cached module masks a require regression.
  package.loaded["rustaceanvim.config"] = nil
  vim.g.rustaceanvim = nil
  -- Must not error (proves init does not require the not-yet-loaded plugin).
  plug.init()
  assert_true(type(vim.g.rustaceanvim) == "table", "init must assign vim.g.rustaceanvim table")
end)

test("vim.g.rustaceanvim settings preserved byte-identical", function()
  vim.g.rustaceanvim = nil
  plug.init()
  local g = vim.g.rustaceanvim
  assert_true(type(g.server.on_attach) == "function", "server.on_attach must be a function")
  local ra = g.server.default_settings["rust-analyzer"]
  assert_eq(ra.cargo.allFeatures, true, "cargo.allFeatures must be preserved")
  assert_eq(ra.checkOnSave, true, "checkOnSave must be preserved")
  assert_eq(ra.check.command, "clippy", "check.command must be clippy")
  assert_eq(ra.inlayHints.bindingModeHints.enable, true, "bindingModeHints preserved")
  assert_eq(ra.inlayHints.closureReturnTypeHints.enable, "always", "closureReturnTypeHints preserved")
  assert_eq(ra.inlayHints.lifetimeElisionHints.enable, "always", "lifetimeElisionHints preserved")
  assert_eq(ra.procMacro.enable, true, "procMacro.enable preserved")
end)

test("dap.adapter branches: nil when codelldb absent, correct shape when present", function()
  local mason_path = vim.fn.stdpath("data") .. "/mason/packages/codelldb"
  local codelldb_path = mason_path .. "/extension/adapter/codelldb"
  local liblldb_path = mason_path .. "/extension/lldb/lib/liblldb.so"
  local real_executable = vim.fn.executable

  -- Absent branch.
  vim.fn.executable = function(_) return 0 end
  vim.g.rustaceanvim = nil
  plug.init()
  assert_nil(vim.g.rustaceanvim.dap.adapter, "adapter must be nil when codelldb not installed")

  -- Present branch — assert byte-identical to get_codelldb_adapter's contract.
  vim.fn.executable = function(p)
    if p == codelldb_path then return 1 end
    return 0
  end
  vim.g.rustaceanvim = nil
  plug.init()
  local a = vim.g.rustaceanvim.dap.adapter
  assert_true(type(a) == "table", "adapter must be a table when codelldb installed")
  assert_eq(a.type, "server", "adapter.type")
  assert_eq(a.port, "${port}", "adapter.port")
  assert_eq(a.host, "127.0.0.1", "adapter.host")
  assert_eq(a.executable.command, codelldb_path, "adapter.executable.command")
  assert_eq(a.executable.args[1], "--liblldb", "adapter args[1]")
  assert_eq(a.executable.args[2], liblldb_path, "adapter args[2]")
  assert_eq(a.executable.args[3], "--port", "adapter args[3]")
  assert_eq(a.executable.args[4], "${port}", "adapter args[4]")

  vim.fn.executable = real_executable
end)

test("dependencies preserve nvim-dap", function()
  assert_true(type(plug.dependencies) == "table", "dependencies must exist")
  assert_eq(plug.dependencies[1], "mfussenegger/nvim-dap", "nvim-dap dependency preserved")
end)

vim.g.rustaceanvim = nil

_H.finish({ style = "results", exit = "os" })
