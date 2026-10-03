-- Spec for the server declarations in lua/andrew/plugins/lsp/lspconfig.lua.
--
-- Pins three fixes that are each invisible when they regress:
--
-- 1. ctags_lsp serves C/C++ ONLY. Fortran was added on 2026-09-06 and reverted
--    the same day: ctags-lsp scopes results to the current file, so it could not
--    do the ISO_C_BINDING interop job it was added for, and everything it DID
--    contribute duplicated fortls -- both answered documentTextSymbol with the
--    same names, so <leader>ss listed every subroutine twice. A duplicate-symbol
--    regression looks like a picker quirk, not a config error, so it is worth a
--    test.
--
-- 2. fortls is configured by CLI FLAGS, never init_options. fortls 3.2.2 does
--    not read initializationOptions at all, so an init_options table there is
--    silently discarded -- which is how enable_code_actions went missing and
--    <leader>ca was a dead key in Fortran buffers for as long as it existed.
--
-- 3. Servers with an explicit cmd are enabled only when that binary resolved.
--    Enabling a missing one is silent: nvim spawns it, the client dies, and the
--    only trace is :LspLog. That is how lua_ls was dead while mason had it
--    installed the whole time.
--
-- Drives the REAL spec's config() with vim.lsp.config / vim.lsp.enable replaced
-- by capturing stubs, so the assertions are on what the config actually declares
-- rather than on file text.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * Test 2 fails if any Fortran filetype is added back to ctags_lsp.
--   * Test 3 fails if fortls grows an init_options table, or loses
--     --enable_code_actions from its cmd.
--   * Test 4 fails if a server is enabled unconditionally again.
--
-- Run with: nvim --headless -u NONE -l tests/lsp_server_config_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil, assert_deep_eq =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- blink.cmp is a dependency of the spec's capabilities call; stub it.
package.loaded["blink.cmp"] = { get_lsp_capabilities = function() return {} end }

local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/lsp/lspconfig.lua")

--- Run the real config() with vim.lsp.config/enable captured.
--- `missing` is an optional binary basename that executable() should deny, so
--- the "do not enable a server whose binary is absent" guard can be exercised
--- on a machine where the binary is in fact present.
local function run_config(missing)
  local captured, enabled = {}, {}
  local real_config, real_enable = vim.lsp.config, vim.lsp.enable
  local real_executable = vim.fn.executable

  vim.lsp.config = setmetatable({}, {
    __call = function(_, name, cfg)
      captured[name] = cfg
    end,
  })
  vim.lsp.enable = function(name)
    enabled[#enabled + 1] = name
  end
  if missing then
    vim.fn.executable = function(path)
      if type(path) == "string" and path:find(missing, 1, true) then
        return 0
      end
      return real_executable(path)
    end
  end

  local ok, err = pcall(plug.config)

  vim.lsp.config, vim.lsp.enable = real_config, real_enable
  vim.fn.executable = real_executable

  return ok, err, captured, enabled
end

local cfg_ok, cfg_err, captured, enabled = run_config()

local function is_enabled(name)
  return vim.tbl_contains(enabled, name)
end

test("config() runs and declares the expected servers", function()
  assert_true(cfg_ok, "config() must not error: " .. tostring(cfg_err))
  for _, name in ipairs({ "lua_ls", "fortls", "pylsp", "ctags_lsp" }) do
    assert_true(captured[name] ~= nil, "missing vim.lsp.config for " .. name)
  end
end)

test("ctags_lsp serves C/C++ ONLY -- never Fortran", function()
  local ft = captured.ctags_lsp and captured.ctags_lsp.filetypes
  assert_true(type(ft) == "table", "ctags_lsp must declare filetypes")
  assert_deep_eq(ft, { "c", "cpp" }, "ctags_lsp filetypes must be exactly c/cpp")

  for _, bad in ipairs({ "fortran", "fortran_free", "fortran_fixed", "f90", "f95" }) do
    assert_true(
      not vim.tbl_contains(ft, bad),
      "'" .. bad .. "' must not be here: ctags_lsp duplicates fortls's document symbols"
    )
  end
end)

test("fortls is configured by CLI flags, not initializationOptions", function()
  local f = captured.fortls
  assert_nil(f.init_options, "fortls ignores initializationOptions entirely -- options must be CLI flags")

  assert_true(type(f.cmd) == "table", "fortls must declare a cmd")
  local flags = {}
  for _, a in ipairs(f.cmd) do
    flags[a] = true
  end
  for _, want in ipairs({ "--enable_code_actions", "--hover_signature", "--use_signature_help" }) do
    assert_true(flags[want], "fortls cmd must carry " .. want)
  end
end)

test("a server whose binary is MISSING is not enabled", function()
  -- Both binaries are present on this machine, so the guard is only observable
  -- by denying one. Without this stub the assertion passes even if the guard is
  -- deleted outright -- which is exactly how the first draft of this test let a
  -- mutation through.
  local ok, err, cap, en = run_config("lua-language-server")
  assert_true(ok, "config() must survive a missing binary: " .. tostring(err))

  assert_nil(cap.lua_ls.cmd, "with the binary gone, lua_ls must declare no cmd")
  assert_true(
    not vim.tbl_contains(en, "lua_ls"),
    "lua_ls must NOT be enabled when its binary is missing -- enabling it dies silently"
  )
  -- The other servers are unaffected.
  assert_true(vim.tbl_contains(en, "fortls"), "fortls must still be enabled")
  assert_true(vim.tbl_contains(en, "pylsp"), "pylsp must still be enabled")
end)

test("resolved servers ARE enabled, and rust_analyzer never is", function()
  for _, name in ipairs({ "lua_ls", "ctags_lsp" }) do
    assert_true(captured[name].cmd ~= nil, name .. " binary should resolve on this machine")
    assert_true(is_enabled(name), name .. " must be enabled once its binary resolves")
  end

  -- pylsp has no explicit cmd (resolved from $PATH) and is always enabled.
  assert_true(is_enabled("pylsp"), "pylsp is enabled unconditionally by design")
  assert_nil(captured.pylsp.cmd, "pylsp must not hardcode a cmd -- $PATH resolution is the point")

  -- rust_analyzer belongs to rustaceanvim and must never be enabled here.
  assert_true(not is_enabled("rust_analyzer"), "rust_analyzer is owned by rustaceanvim")
end)

_H.finish({ style = "results", exit = "os" })
