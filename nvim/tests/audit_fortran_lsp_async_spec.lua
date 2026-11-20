-- Spec for the reply TIMING of the in-process language server in
-- lua/andrew/fortran/lsp.lua.
--
-- THE BUG THIS PINS
--   Half the handlers are synchronous -- documentHighlight reads the buffer and
--   returns -- so `server.request` used to invoke the response callback inside
--   its own call. No out-of-process server can do that, and callers written
--   against real servers break on it. Snacks.words is the one that bit:
--
--       vim.lsp.buf.document_highlight()
--       M.clear()                          -- vim.lsp.buf.clear_references()
--
--   It clears the PREVIOUS round's highlights on the assumption the new reply
--   cannot have landed yet. With a same-tick reply the new highlights were
--   applied and then wiped, so `]]`, `[[`, `<a-n>` and `<a-p>` were silent
--   no-ops in every Fortran buffer and the reference underline never appeared.
--   Measured before the fix: 8 extmarks in `nvim.lsp.references` immediately
--   after document_highlight(), 0 after clear_references(), 0 forever.
--
-- Run with: nvim --headless -u NONE -l tests/audit_fortran_lsp_async_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local lsp = require("andrew.fortran.lsp")
local compat = require("andrew.utils.nvim_compat")

-- lsp.server() is declared `---@return table`; this is the part of the RPC
-- object it builds that these tests drive.
---@class AuditFortranLspAsyncServer
---@field request fun(method: string, params: table, cb: fun(err: lsp.ResponseError?, result: any), notify_reply_callback?: fun(id: integer)): boolean, integer

--- A buffer of Fortran with one name used several times.
local uniq = 0
---@return integer bufnr
local function fortran_buf()
  uniq = uniq + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "/tmp/audit_fortran_async/prog" .. uniq .. ".f90")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "subroutine heating(field)",
    "  real, intent(inout) :: field(:)",
    "  integer :: i",
    "  do i = 1, size(field)",
    "    field(i) = field(i) + 1.0",
    "  end do",
    "end subroutine heating",
  })
  vim.bo[buf].filetype = "fortran"
  return buf
end

test("a synchronous handler still replies on a later tick", function()
  local buf = fortran_buf()
  local server = lsp.server({}) --[[@as AuditFortranLspAsyncServer]]

  local replied_before_return = true
  local result ---@type lsp.DocumentHighlight[]?
  local ok, id = server.request("textDocument/documentHighlight", {
    textDocument = { uri = compat.uri_from_buffer(buf) },
    position = { line = 4, character = 4 },
  },
  ---@param _ lsp.ResponseError?
  ---@param res lsp.DocumentHighlight[]?
  function(_, res)
    result = res
  end)
  assert_true(ok, "request must report success:")
  assert_true(type(id) == "number", "request must return a request id:")
  replied_before_return = result ~= nil
  assert_false(replied_before_return, "the reply arrived inside server.request():")

  vim.wait(2000, function()
    return result ~= nil
  end)
  assert_true(result ~= nil, "the reply never arrived:")
  ---@cast result -nil
  assert_eq(#result, 5, "documentHighlight lost the references for `field`:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("notify_reply_callback fires after the response callback", function()
  local buf = fortran_buf()
  local server = lsp.server({}) --[[@as AuditFortranLspAsyncServer]]
  local order = {} ---@type string[]
  local done = false
  server.request("textDocument/documentHighlight", {
    textDocument = { uri = compat.uri_from_buffer(buf) },
    position = { line = 4, character = 4 },
  }, function()
    order[#order + 1] = "response"
  end,
  ---@param id integer
  function(id)
    order[#order + 1] = "notify:" .. tostring(id)
    done = true
  end)
  vim.wait(2000, function()
    return done
  end)
  assert_eq(order[1], "response")
  assert_eq(order[2], "notify:1")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("an unknown method still answers, on a later tick", function()
  local server = lsp.server({}) --[[@as AuditFortranLspAsyncServer]]
  ---@type boolean, lsp.ResponseError|string|nil, any
  local called, err, res = false, "unset", "unset"
  ---@param e lsp.ResponseError?
  ---@param r any
  server.request("textDocument/nonsense", {}, function(e, r)
    called, err, res = true, e, r
  end)
  assert_false(called, "an unknown method replied inside server.request():")
  vim.wait(1000, function()
    return called
  end)
  assert_true(called, "an unknown method never answered at all:")
  assert_eq(err, nil)
  assert_eq(res, nil)
end)

_H.finish()
