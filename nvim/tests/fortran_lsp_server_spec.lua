-- Spec for lua/andrew/fortran/lsp.lua -- the in-process Lua language server
-- that fills the capability gaps fortls leaves.
--
-- WHAT IT PINS
--
-- fortls 3.2.2 advertises eleven capabilities. Six keymaps in
-- andrew.lsp_keymaps are gated on two it does not have, so in a Fortran buffer
-- they were silently never bound:
--
--   ]]  [[  <a-n>  <a-p>   gated on documentHighlight
--   gai gao                gated on callHierarchy/{incoming,outgoing}Calls
--
-- This server exists to flip those gates, and the whole design rests on two
-- facts that a test has to hold down or the thing quietly breaks:
--
--   1. It must advertise what fortls lacks -- and for the three methods it
--      shares with fortls (hover, signatureHelp, completion) the guard lives
--      in the ANSWER, not the capability: every handler returns nil where
--      fortls would answer (see tests/fortran_lsp_hover_spec.lua). What it
--      must never claim is definition, references or rename: fortls answers
--      those scope-aware, and two clients answering one request is the exact
--      situation that forced the python-only hover guard in lspconfig.lua.
--   2. It must negotiate utf-8 position encoding. The scanner reports 1-based
--      BYTE columns; LSP defaults to UTF-16. Any non-ASCII byte earlier in a
--      line -- a comment, a string, an accented name -- shifts every column
--      after it. Under utf-8 the conversion is a subtraction, and to_pos()
--      is correct by construction.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "advertises the gaps plus the documentation surface" fails if
--     definition/references/rename are added to capabilities(), or if hover,
--     signatureHelp or completion are dropped.
--   * "utf-8 position encoding" fails if positionEncoding is dropped, because
--     the negotiated client.offset_encoding falls back to utf-16.
--   * "gates flip for a Fortran buffer" fails if either provider is removed
--     from capabilities() -- this is the test that proves the six keymaps
--     bind, and it evaluates exactly what andrew.lsp_keymaps.has() evaluates.
--   * "fortls-owned gates stay closed" fails if definitionProvider is added.
--   * "to_pos is 0-based" fails if either -1 is dropped.
--   * "name_range spans the name" fails if the end column loses its offset.
--   * "from_pos refuses a position it cannot use" fails if the type check is
--     dropped: a client that omits `character` sends it as `vim.NIL`, a
--     userdata, and `pos.character + 1` then throws "attempt to perform
--     arithmetic on field 'character' (a userdata value)" out of the handler --
--     an error reply where "no result" is the right answer.
--   * "unknown methods answer nil" fails if dispatch raises or returns a
--     MethodNotFound error instead -- a mis-gated caller would then log on
--     every keypress.
--   * "a raising handler degrades to no result" fails if the pcall around the
--     handler is removed: the error escapes into Neovim's RPC dispatch.
--   * "attach refuses non-Fortran buffers" fails if the filetype guard goes.
--   * "notify exit closes the server" fails if is_closing stops tracking it,
--     which leaks a client per buffer.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_lsp_server_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil, assert_deep_eq = _H.assert_nil, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local lsp = require("andrew.fortran.lsp")

-- Helpers -------------------------------------------------------------------

--- A loaded, named Fortran buffer -- attach() needs a path to find a root.
local function fortran_buf(name, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "      END" })
  vim.bo[buf].filetype = "fortran"
  return buf
end

--- Exactly what andrew.lsp_keymaps.has() evaluates for one method.
local function has(buf, method)
  return #vim.lsp.get_clients({ bufnr = buf, method = method }) > 0
end

--- Drive one request through the dispatcher synchronously.
local function call(method, params)
  local got, done = nil, false
  lsp.dispatch(method, params, function(err, result)
    got, done = { err = err, result = result }, true
  end)
  return done and got or nil
end

-- Capabilities --------------------------------------------------------------

test("advertises the gaps plus the documentation surface", function()
  local caps = lsp.capabilities()
  assert_true(caps.documentHighlightProvider ~= nil, "documentHighlight is advertised:")
  assert_true(caps.callHierarchyProvider ~= nil, "callHierarchy is advertised:")
  assert_true(caps.hoverProvider == true, "hover is advertised (MPI/OpenMP/keywords):")
  assert_deep_eq(caps.signatureHelpProvider, { triggerCharacters = { "(", "," } }, "signatureHelp triggers match fortls's:")
  assert_true(caps.completionProvider.resolveProvider == true, "completion docs are lazy:")
  assert_deep_eq(caps.completionProvider.triggerCharacters, { "$" }, "only `$` triggers completion:")
  assert_true(caps.codeActionProvider ~= nil, "quickfixes are advertised:")

  -- The negative half. fortls answers all of these, and its references are
  -- genuinely scope-aware in a way a textual scan is not.
  for _, owned in ipairs({
    "definitionProvider",
    "referencesProvider",
    "renameProvider",
    "documentSymbolProvider",
    "workspaceSymbolProvider",
    "implementationProvider",
  }) do
    assert_nil(caps[owned], owned .. " is left to fortls:")
  end
end)

test("declares utf-8 position encoding", function()
  assert_eq(lsp.capabilities().positionEncoding, "utf-8", "byte columns are the wire format:")
end)

-- Position helpers ----------------------------------------------------------

test("to_pos converts 1-based scanner coords to 0-based LSP", function()
  local p = lsp.to_pos(1, 1)
  assert_eq(p.line, 0, "first line is 0:")
  assert_eq(p.character, 0, "first column is 0:")
  local q = lsp.to_pos(12, 17)
  assert_eq(q.line, 11, "line 12 is 11:")
  assert_eq(q.character, 16, "column 17 is 16:")
end)

test("from_pos round-trips to_pos", function()
  local lnum, col = lsp.from_pos(lsp.to_pos(42, 7))
  assert_eq(lnum, 42, "line survives the round trip:")
  assert_eq(col, 7, "column survives the round trip:")
end)

test("from_pos refuses a position it cannot use", function()
  -- vim.NIL is what a JSON `null` becomes on the way in; it is a userdata and
  -- arithmetic on it raises rather than erroring politely.
  local ok, lnum = pcall(lsp.from_pos, { line = 0, character = vim.NIL })
  assert_true(ok, "a null character does not raise:")
  assert_nil(lnum, "and answers no position:")
  assert_nil(lsp.from_pos({ line = vim.NIL, character = 0 }), "a null line likewise:")
  assert_nil(lsp.from_pos({ line = 0 }), "a missing character likewise:")
  assert_nil(lsp.from_pos(nil), "no position at all likewise:")
  assert_nil(lsp.from_pos({ line = "3", character = 1 }), "a stringly-typed line likewise:")
end)

test("name_range spans exactly the name", function()
  -- HEAT at line 4, column 18, four bytes long.
  local r = lsp.name_range(4, 18, 4)
  assert_eq(r.start.line, 3, "start line:")
  assert_eq(r.start.character, 17, "start column:")
  assert_eq(r["end"].line, 3, "end stays on the same line:")
  assert_eq(r["end"].character, 21, "end column is start + length:")
end)

-- Dispatch ------------------------------------------------------------------

test("initialize answers with the capability set", function()
  local got = call("initialize", {})
  assert_true(got ~= nil, "initialize answered synchronously:")
  assert_nil(got.err, "no error:")
  assert_eq(got.result.capabilities.positionEncoding, "utf-8", "capabilities are carried:")
end)

test("unknown methods answer nil rather than an error", function()
  local got = call("textDocument/somethingNobodyImplements", {})
  assert_true(got ~= nil, "the callback still ran:")
  assert_nil(got.err, "no RPC error is raised:")
  assert_nil(got.result, "the result is empty:")
end)

test("a raising handler degrades to no result", function()
  local saved = lsp.handlers["test/boom"]
  lsp.handlers["test/boom"] = function()
    error("provider exploded")
  end
  local ok, got = pcall(call, "test/boom", {})
  lsp.handlers["test/boom"] = saved

  assert_true(ok, "the error does not escape into Neovim's dispatch loop:")
  assert_true(got ~= nil, "the callback still ran:")
  assert_nil(got.result, "the answer is empty:")
end)

-- The RPC object ------------------------------------------------------------

test("request reports success and an increasing id", function()
  local srv = lsp.server({})
  local ok1, id1 = srv.request("initialize", {}, function() end)
  local ok2, id2 = srv.request("initialize", {}, function() end)
  assert_true(ok1 and ok2, "both requests are accepted:")
  assert_true(id2 > id1, "ids increase:")
end)

test("notify exit closes the server", function()
  local srv = lsp.server({})
  assert_eq(srv.is_closing(), false, "starts open:")
  srv.notify("exit", {})
  assert_eq(srv.is_closing(), true, "exit closes it:")
end)

test("terminate closes the server", function()
  local srv = lsp.server({})
  srv.terminate()
  assert_eq(srv.is_closing(), true, "terminate closes it:")
end)

-- Attach --------------------------------------------------------------------

test("attach refuses a non-Fortran buffer", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "python"
  assert_nil(lsp.attach(buf), "no client is started for python:")
end)

test("gates flip for a Fortran buffer", function()
  local buf = fortran_buf("/tmp/fortran-extras-spec/code/t.f90", {
    "      SUBROUTINE HEAT(T)",
    "      CALL FOO(T)",
    "      END",
  })
  local id = lsp.attach(buf)
  assert_true(id ~= nil, "a client was started:")
  assert_true(
    vim.wait(5000, function()
      local c = vim.lsp.get_client_by_id(id)
      return c ~= nil and c.initialized
    end),
    "the client initialized:"
  )

  local client = vim.lsp.get_client_by_id(id)
  assert_eq(client.offset_encoding, "utf-8", "utf-8 was negotiated, so byte columns are safe:")

  -- The six keymaps in andrew.lsp_keymaps hang off exactly these three.
  assert_true(has(buf, "textDocument/documentHighlight"), "]] [[ <a-n> <a-p> can bind:")
  assert_true(has(buf, "callHierarchy/incomingCalls"), "gai can bind:")
  assert_true(has(buf, "callHierarchy/outgoingCalls"), "gao can bind:")
end)

test("fortls-owned gates stay closed", function()
  local buf = fortran_buf("/tmp/fortran-extras-spec/code/u.f90")
  local id = lsp.attach(buf)
  assert_true(
    vim.wait(5000, function()
      local c = vim.lsp.get_client_by_id(id)
      return c ~= nil and c.initialized
    end),
    "the client initialized:"
  )

  -- Nothing here is fortls's job to lose. If any of these ever comes back
  -- true, two clients are answering one request.
  assert_eq(has(buf, "textDocument/references"), false, "references are left to fortls:")
  assert_eq(has(buf, "textDocument/definition"), false, "definition is left to fortls:")
  assert_eq(has(buf, "textDocument/rename"), false, "rename is left to fortls:")
end)

_H.finish()
