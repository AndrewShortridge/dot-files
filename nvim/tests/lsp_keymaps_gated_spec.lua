-- Spec for the capability-gated LSP keymaps (lua/andrew/lsp_keymaps.lua).
--
-- Background: every LSP keymap used to be bound unconditionally inside the
-- LspAttach handler, so keys existed on buffers whose server could not serve
-- them -- <leader>ca on a server with no codeActionProvider just answered "No
-- code actions available". This module ports LazyVim's `has` mechanism: each
-- key names the LSP method it needs and is bound only when some attached
-- client advertises it.
--
-- This drives the REAL module against a stubbed vim.lsp.get_clients (the
-- gating input) and a scratch buffer, then reads back the buffer's actual
-- keymaps via nvim_buf_get_keymap. No source introspection: the assertions are
-- about behaviour (which keys got bound, what the action metatable requests),
-- not about the file's text.
--
-- Test 5 is the important one. `has` strings are resolved by
-- vim.lsp.protocol._request_name_to_server_capability; a method name that is
-- not in that table makes supports_method() fall through to the dynamic
-- registration path and answer false, so a single typo silently unbinds a key
-- FOREVER with no error anywhere. LazyVim ships exactly this bug -- it gates
-- workspace symbols on "workspace/symbols", which is not a method name (the
-- real one is singular) -- so the guard is not hypothetical.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * Test 2 fails if `has` stops prefixing bare names with "textDocument/",
--     or stops treating a list as "any of".
--   * Test 3 fails if a key is bound without its capability, or if a key whose
--     capability IS present gets skipped.
--   * Test 4 fails if <leader>cs / <leader>cS go back to being ungated Trouble
--     commands instead of capability-gated fzf symbol pickers.
--   * Test 4 fails if <leader>co loses its organizeImports kind probe and
--     binds on any server with a codeActionProvider.
--   * Test 5 fails on any misspelled method (verified with "workspace/symbols").
--   * Test 6 fails if <leader>cC is switched to the deprecated
--     vim.lsp.codelens.refresh, which nvim 0.12.5 warns on and 0.13 removes.
--   * Test 7 fails if the source-action metatable drops apply/only.
--
-- Run with: nvim --headless -u NONE -l tests/lsp_keymaps_gated_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local K = require("andrew.lsp_keymaps")

-- ---------------------------------------------------------------------------
-- Stub harness: pretend a client advertising exactly `methods` is attached.
-- ---------------------------------------------------------------------------
local real_get_clients = vim.lsp.get_clients

local function with_methods(methods, fn)
  local set = {}
  for _, m in ipairs(methods) do
    set[m] = true
  end
  vim.lsp.get_clients = function(filter)
    filter = filter or {}
    if filter.method and not set[filter.method] then
      return {}
    end
    return { { name = "stub", id = 1, server_capabilities = {} } }
  end
  local ok, err = pcall(fn)
  vim.lsp.get_clients = real_get_clients
  if not ok then
    error(err, 0)
  end
end

--- Bind into a throwaway buffer and return a set of "lhs|mode".
local function bound_keys(methods, kinds)
  local buf = vim.api.nvim_create_buf(false, true)
  local real_kinds = K.code_action_kinds
  if kinds then
    K.code_action_kinds = function()
      return kinds
    end
  end

  with_methods(methods, function()
    K.on_attach(buf)
  end)
  K.code_action_kinds = real_kinds

  local seen = {}
  for _, mode in ipairs({ "n", "x", "v" }) do
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      seen[m.lhs .. "|" .. mode] = true
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return seen
end

-- Leader is unset under -u NONE, so <leader> resolves to "\" in a stored lhs.
local LEADER = "\\"
local function lk(suffix)
  return LEADER .. suffix
end

test("module exposes the LazyVim-shaped surface", function()
  assert_true(type(K._keys) == "table" and #K._keys > 0, "_keys must be a non-empty list")
  assert_true(type(K.has) == "function", "has() must exist")
  assert_true(type(K.on_attach) == "function", "on_attach() must exist")
  assert_true(type(K.action) == "table", "action metatable must exist")
end)

test("has() qualifies bare method names and treats a list as any-of", function()
  with_methods({ "textDocument/codeAction" }, function()
    assert_true(K.has(0, "codeAction"), "bare name must be prefixed with textDocument/")
    assert_true(K.has(0, "textDocument/codeAction"), "qualified name must pass through unchanged")
    assert_false(K.has(0, "codeLens"), "unsupported method must not pass")
    assert_true(K.has(0, nil), "nil method means ungated")
  end)

  with_methods({ "workspace/willRenameFiles" }, function()
    assert_true(
      K.has(0, { "workspace/didRenameFiles", "workspace/willRenameFiles" }),
      "a list must pass when ANY member is supported"
    )
    assert_false(K.has(0, { "workspace/didRenameFiles" }), "a list must fail when no member is supported")
  end)
end)

test("on_attach binds only the keys whose capability is advertised", function()
  -- A server like fortls: definitions/references/rename/symbols, but NO
  -- codeAction, codeLens, typeDefinition, signatureHelp or documentHighlight.
  local seen = bound_keys({
    "textDocument/definition",
    "textDocument/references",
    "textDocument/rename",
    "textDocument/documentSymbol",
    "workspace/symbol",
  })

  for _, want in ipairs({
    "gd|n",
    "gr|n",
    lk("cr") .. "|n",
    lk("ss") .. "|n",
    lk("sS") .. "|n",
    -- <leader>cs / <leader>cS are fzf symbol pickers here, NOT Trouble views,
    -- so they gate on the same symbol capabilities as <leader>ss / <leader>sS.
    lk("cs") .. "|n",
    lk("cS") .. "|n",
  }) do
    assert_true(seen[want], "expected bound: " .. want)
  end

  for _, unwanted in ipairs({
    lk("ca") .. "|n",
    lk("cA") .. "|n",
    lk("cc") .. "|n",
    lk("cC") .. "|n",
    lk("cR") .. "|n",
    "gy|n",
    "gI|n",
    "gK|n",
    "gai|n",
    "gao|n",
    "]]|n",
    "[[|n",
  }) do
    assert_false(seen[unwanted], "must NOT be bound without its capability: " .. unwanted)
  end

  -- Ungated keys are always present.
  assert_true(seen["gD|n"], "gD is ungated (its fallback is the feature)")
  assert_true(seen[lk("cl") .. "|n"], "<leader>cl is ungated")
end)

test("<leader>cs / <leader>cS are symbol-gated, not unconditional Trouble keys", function()
  -- Trouble keys would be global and always present; these must disappear on a
  -- server with no symbol support, and must not require codeAction.
  local none = bound_keys({ "textDocument/definition" })
  assert_false(none[lk("cs") .. "|n"], "<leader>cs must not bind without documentSymbol")
  assert_false(none[lk("cS") .. "|n"], "<leader>cS must not bind without workspace/symbol")

  local doc_only = bound_keys({ "textDocument/documentSymbol" })
  assert_true(doc_only[lk("cs") .. "|n"], "<leader>cs binds on documentSymbol")
  assert_false(doc_only[lk("cS") .. "|n"], "<leader>cS needs workspace/symbol specifically")
end)

test("<leader>co needs the organizeImports KIND, not just codeAction", function()
  local ca = { "textDocument/codeAction" }

  local without = bound_keys(ca, { "quickfix", "refactor" })
  assert_true(without[lk("ca") .. "|n"], "<leader>ca binds on any codeAction server")
  assert_false(without[lk("co") .. "|n"], "<leader>co must NOT bind without the organizeImports kind")

  local with = bound_keys(ca, { "quickfix", "source.organizeImports" })
  assert_true(with[lk("co") .. "|n"], "<leader>co must bind when the kind is advertised")
end)

test("every `has` method exists in nvim's capability map", function()
  local map = vim.lsp.protocol._request_name_to_server_capability
  assert_true(type(map) == "table", "nvim must expose _request_name_to_server_capability")

  for _, key in ipairs(K._keys) do
    if key.has then
      local methods = type(key.has) == "string" and { key.has } or key.has
      for _, m in ipairs(methods) do
        local qualified = m:find("/") and m or ("textDocument/" .. m)
        assert_true(
          map[qualified] ~= nil,
          ("key %s gates on %q, which is not a real LSP method -- it would never bind"):format(key[1], qualified)
        )
      end
    end
  end
end)

test("<leader>cC uses codelens.enable, not the deprecated refresh", function()
  local rhs
  for _, key in ipairs(K._keys) do
    if key[1] == "<leader>cC" then
      rhs = key[2]
    end
  end
  assert_true(type(rhs) == "function", "<leader>cC must exist with a function rhs")

  local real = vim.lsp.codelens
  local called = {}
  vim.lsp.codelens = {
    enable = function(on, opts)
      called.enable = { on, opts }
    end,
    refresh = function()
      called.refresh = true
    end,
  }
  local ok, err = pcall(rhs)
  vim.lsp.codelens = real

  assert_true(ok, "rhs must not error: " .. tostring(err))
  assert_true(called.refresh == nil, "must NOT call the deprecated vim.lsp.codelens.refresh")
  assert_true(called.enable ~= nil, "must call vim.lsp.codelens.enable")
  assert_eq(called.enable[1], true, "enable must be called with true")
  assert_eq(called.enable[2] and called.enable[2].bufnr, 0, "enable must target the current buffer")
end)

test("action metatable requests one kind and applies it without a prompt", function()
  local real = vim.lsp.buf.code_action
  local got
  vim.lsp.buf.code_action = function(o)
    got = o
  end
  local ok, err = pcall(K.action["source.organizeImports"])
  vim.lsp.buf.code_action = real

  assert_true(ok, "action must not error: " .. tostring(err))
  assert_true(got ~= nil, "action must call vim.lsp.buf.code_action")
  assert_eq(got.apply, true, "apply must be true (no prompt for a single action)")
  assert_eq(got.context and got.context.only and got.context.only[1], "source.organizeImports", "only must carry the kind")
  assert_true(
    got.context and type(got.context.diagnostics) == "table" and #got.context.diagnostics == 0,
    "diagnostics must be an empty table, not nil"
  )
end)

_H.finish({ style = "results", exit = "os" })
