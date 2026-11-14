-- Spec for lua/andrew/fortran/lsp_signature.lua -- textDocument/signatureHelp
-- for MPI and omp_lib calls.
--
-- WHAT IT PINS
--
-- fortls answers signature help well for procedures the project defines and
-- not at all for the two families this project reads most: `MPI_Comm_rank(`
-- gets no result (mpif.h is a stub to it, a .mod file is binary) and
-- `omp_set_num_threads(` gets `parameters: []` (fortls-baseline.md A.4).
-- Filling that gap has three failure modes, none of which is visible by
-- looking at a float:
--
--   1. Byte offsets. `parameters[i].label` is a `[start, end]` pair of BYTE
--      offsets into the signature label, which nvim slices directly
--      (util.lua:822). An off-by-one underlines the comma instead of the
--      argument. They come from render.signature; this spec re-derives every
--      one of them from the finished label so the two cannot drift.
--   2. Finding the call. The innermost unclosed `(` before the cursor is not
--      a local question in Fortran -- a statement may be spread over `&`
--      continuation lines, and `MPI_Send(size(a), ` has two open parens at
--      different times within one line. Both are here.
--   3. Answering where fortls already does. nvim CYCLES signature help from
--      two clients rather than concatenating it, so a false positive is only
--      noisy -- but a project that defines its own `MPI_SEND` wrapper must
--      see the wrapper's dummies, not the library's.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "activeParameter counts depth-0 commas" fails if commas inside a nested
--     call are counted -- `MPI_Send(size(a,1), ` would then point at `count`.
--   * "parameter labels index the label" fails on any off-by-one, and on any
--     attempt to compute the offsets after the label is built.
--   * "only the active parameter is documented" fails if documentation is
--     attached to every parameter: nvim renders them all at once, which is
--     the wall of text this feature exists to avoid.
--   * "the active parameter's documentation opens with a rule" fails if the
--     leading `---` is dropped -- nvim appends parameter docs with NO
--     separator, so the prose runs into the signature line above it.
--   * "the label stays compact under formatted display" fails if
--     render.signature starts honouring vim.g.fortran_signature_display: a
--     multi-line label makes every byte offset point into the wrong line.
--   * "a continuation line finds its statement" fails if the backward walk
--     for the statement start is dropped, or if the `&` is scanned as text --
--     the cursor on line two then sees no open paren at all.
--   * "an array reference is not a call" fails if the registry lookup is
--     dropped: every `a(i, ` in every loop would open a float.
--   * "a nested intrinsic is not ours" fails if the paren stack is replaced
--     by "the last `(` seen" -- `MPI_Send(size(` would answer for MPI_Send
--     while the cursor is inside size().
--   * "the enclosing call resumes after a nested one closes" fails if the
--     stack is not popped on `)`.
--   * "a project symbol is fortls's" fails if the ownership check is dropped.
--   * "a directive line is not a call" fails if is_directive stops being
--     consulted: `REDUCTION(+:sum)` reads as a one-argument call.
--   * "a comment is not a call" fails if the lines stop being masked.
--   * "activeParameter is clamped" fails if an over-long argument list is
--     allowed to index past the interface -- render.signature then documents
--     nothing and nvim highlights nothing.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_lsp_signature_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil = _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local sighelp = require("andrew.fortran.lsp_signature")
local lsp = require("andrew.fortran.lsp")

-- Helpers -------------------------------------------------------------------

--- Signature help with the cursor at the END of `lines[#lines]` unless `col`
--- says otherwise -- the shape of typing `(` or `,` and waiting.
---@param lines string[]
---@param lnum integer|nil
---@param col integer|nil
---@param opts table|nil
local function ask(lines, lnum, col, opts)
  lnum = lnum or #lines
  col = col or (#lines[lnum] + 1)
  return sighelp.answer(lines, lnum, col, opts or {})
end

--- The single signature of an answer.
local function only(res)
  assert_true(res ~= nil, "an answer was produced:")
  assert_eq(#res.signatures, 1, "exactly one signature:")
  return res.signatures[1]
end

-- The MPI_Comm_rank case (design A8) -----------------------------------------

test("activeParameter counts depth-0 commas", function()
  local res = ask({ "      call MPI_Comm_rank(MPI_COMM_WORLD, " })
  local sig = only(res)
  assert_eq(res.activeSignature, 0, "one signature, index 0:")
  assert_eq(res.activeParameter, 1, "the cursor is in the second slot:")
  assert_eq(sig.activeParameter, 1, "the signature agrees with the envelope:")
  assert_eq(sig.label, "MPI_Comm_rank(comm, rank, ierror)", "design A8's label:")
end)

test("parameter labels index the label", function()
  local sig = only(ask({ "      call MPI_Comm_rank(MPI_COMM_WORLD, " }))
  local label = sig.label
  local expected = { "comm", "rank", "ierror" }
  assert_eq(#sig.parameters, 3, "one parameter per dummy:")
  for i, name in ipairs(expected) do
    local pair = sig.parameters[i].label
    assert_eq(type(pair), "table", "parameter " .. i .. " carries an offset pair:")
    -- nvim slices with these exact byte offsets (util.lua:822).
    assert_eq(label:sub(pair[1] + 1, pair[2]), name, "offsets " .. i .. " slice " .. name .. ":")
  end
  -- Design A8 spells them out; pin the literal values so an off-by-one in
  -- either direction is caught even if the label changes shape.
  assert_eq(sig.parameters[1].label[1], 14, "comm starts at byte 14:")
  assert_eq(sig.parameters[3].label[2], 32, "ierror ends at byte 32:")
end)

test("only the active parameter is documented", function()
  local sig = only(ask({ "      call MPI_Comm_rank(MPI_COMM_WORLD, " }))
  assert_eq(sig.parameters[1].documentation.value, "", "comm is silent:")
  assert_eq(sig.parameters[3].documentation.value, "", "ierror is silent:")
  assert_true(#sig.parameters[2].documentation.value > 0, "rank is not:")
end)

test("the active parameter's documentation opens with a rule", function()
  -- nvim appends parameter documentation with NO separator, so the rule has
  -- to be inside the value or the prose runs into the signature above it.
  local sig = only(ask({ "      call MPI_Comm_rank(MPI_COMM_WORLD, " }))
  local v = sig.parameters[2].documentation.value
  assert_eq(v:sub(1, 4), "---\n", "the rule is shipped in the value:")
  assert_true(v:find("`integer, intent(out) :: rank`", 1, true) ~= nil, "with the typed declaration:")
end)

test("the label stays compact under formatted display", function()
  local saved = vim.g.fortran_signature_display
  vim.g.fortran_signature_display = "formatted"
  local sig = only(ask({ "      call MPI_Comm_rank(MPI_COMM_WORLD, " }))
  vim.g.fortran_signature_display = saved
  assert_eq(sig.label, "MPI_Comm_rank(comm, rank, ierror)", "hover may break lines; the label may not:")
  assert_nil(sig.label:find("\n", 1, true), "no newline can appear in a signature label:")
end)

test("the first slot is activeParameter 0", function()
  local res = ask({ "      call MPI_Comm_rank(" })
  assert_eq(res.activeParameter, 0, "right after the open paren:")
end)

-- Continuation lines ----------------------------------------------------------

test("a continuation line finds its statement", function()
  local lines = {
    "      call MPI_Send(buf, n, MPI_INTEGER, &",
    "     dest, tag, MPI_COMM_WORLD, ierr)",
  }
  -- Cursor at the start of `dest` on the second line.
  local res = ask(lines, 2, 6)
  local sig = only(res)
  assert_eq(sig.label, "MPI_Send(buf, count, datatype, dest, tag, comm, ierror)", "the library's dummy names:")
  assert_eq(res.activeParameter, 3, "three commas on line one put the cursor on dest:")
  assert_true(sig.parameters[4].documentation.value:find("dest", 1, true) ~= nil, "and dest is the documented one:")
end)

test("the trailing ampersand is not scanned as an argument", function()
  -- If `&` were statement text the walk would see it as part of the third
  -- argument and nothing would break visibly -- but a `&` inside a comment
  -- would then continue a statement that did not continue.
  local lines = {
    "      call MPI_Send(buf, n, MPI_INTEGER, & ! keep going",
    "     dest, tag, MPI_COMM_WORLD, ierr)",
  }
  assert_eq(ask(lines, 2, 6).activeParameter, 3, "the comment after `&` changes nothing:")
end)

-- Nesting ---------------------------------------------------------------------

test("a nested intrinsic is not ours", function()
  -- fortls owns the intrinsics; `size` is not in the registry at all. With a
  -- "last open paren wins" walk this would answer for MPI_Send instead.
  local line = "      call MPI_Send(size(a), "
  assert_nil(sighelp.answer({ line }, 1, #"      call MPI_Send(size(" + 1, {}), "inside size( there is nothing to say:")
end)

test("the enclosing call resumes after a nested one closes", function()
  local res = ask({ "      call MPI_Send(size(a), " })
  local sig = only(res)
  assert_eq(sig.label, "MPI_Send(buf, count, datatype, dest, tag, comm, ierror)", "back to MPI_Send:")
  assert_eq(res.activeParameter, 1, "one depth-0 comma, so the second slot:")
end)

test("commas inside a nested call do not count", function()
  local res = ask({ "      call MPI_Send(size(a, 1), " })
  assert_eq(res.activeParameter, 1, "size's own comma is at depth 2:")
end)

test("enclosing_call reports the callee and its comma count", function()
  local line = "      call MPI_Send(size(a, 1), n, "
  local callee, commas = sighelp.enclosing_call({ line }, 1, #line + 1, false)
  assert_eq(callee, "mpi_send", "the callee is lowercase:")
  assert_eq(commas, 2, "two commas at depth 0:")
end)

-- What must never answer -------------------------------------------------------

test("an array reference is not a call", function()
  assert_nil(ask({ "      x = a(i, " }), "`a` is not in the registry:")
  assert_nil(ask({ "      x = arr(i, j, " }), "nor is `arr`:")
end)

test("a grouping paren is not a call", function()
  assert_nil(ask({ "      x = (a + b, " }), "no identifier precedes the paren:")
end)

test("a project symbol is fortls's", function()
  local lines = { "      call MPI_Send(buf, " }
  assert_true(ask(lines) ~= nil, "the library routine answers:")
  assert_nil(ask(lines, nil, nil, { locals = { mpi_send = true } }), "a wrapper defined here does not:")
  assert_nil(
    ask(lines, nil, nil, { project = { mpi_send = { name = "MPI_SEND", args = { "b" } } } }),
    "nor one defined elsewhere in the project:"
  )
  assert_true(
    ask(lines, nil, nil, { project = { mpi_send = { name = "MPI_Send", args = {}, builtin = true } } }) ~= nil,
    "but the index's own seeded builtin stays ours:"
  )
end)

test("a directive line is not a call", function()
  assert_nil(ask({ "      !$OMP PARALLEL DO REDUCTION(+:sum, " }), "a clause list is not an argument list:")
  assert_nil(ask({ "!$omp parallel do private(i, " }), "lower-case sentinel too:")
end)

test("a comment is not a call", function()
  assert_nil(ask({ "      ! call MPI_Comm_rank(MPI_COMM_WORLD, " }), "masked away before the walk:")
end)

test("no open paren answers nil", function()
  assert_nil(ask({ "      call MPI_Comm_rank(a, b, c)" }), "the list already closed:")
  assert_nil(ask({ "      x = 1" }), "nothing is open:")
end)

test("a zero-dummy function has nothing to point at", function()
  assert_nil(ask({ "      t = omp_get_wtime(" }), "no interface, no signature help:")
end)

test("a constant is not callable", function()
  assert_nil(ask({ "      x = MPI_COMM_WORLD(" }), "only subroutines and functions answer:")
end)

-- omp_lib ---------------------------------------------------------------------

test("omp_set_num_threads names its one dummy", function()
  local res = ask({ "      call omp_set_num_threads(" })
  local sig = only(res)
  assert_eq(sig.label, "omp_set_num_threads(num_threads)", "fortls returns parameters: [] here:")
  assert_eq(res.activeParameter, 0, "the only slot:")
  assert_eq(sig.label:sub(sig.parameters[1].label[1] + 1, sig.parameters[1].label[2]), "num_threads",
    "the offsets slice the dummy:")
end)

-- Clamping ---------------------------------------------------------------------

test("activeParameter is clamped to the last dummy", function()
  local res = ask({ "      call omp_set_num_threads(n, m, " })
  assert_eq(res.activeParameter, 0, "two extra commas cannot index past one dummy:")
  local rank = ask({ "      call MPI_Comm_rank(a, b, c, d, " })
  assert_eq(rank.activeParameter, 2, "clamped to ierror rather than dropped:")
  assert_true(#only(rank).parameters[3].documentation.value > 0, "and ierror is the documented one:")
end)

-- Malformed input ---------------------------------------------------------------

test("bad arguments answer nil rather than raising", function()
  assert_nil(sighelp.answer(nil, 1, 1, {}), "no lines:")
  assert_nil(sighelp.answer({ "x" }, 9, 1, {}), "a line number past the end:")
  assert_nil(sighelp.answer({ "x" }, 1, nil, {}), "no column:")
end)

-- End to end ---------------------------------------------------------------------

test("signature help over the wire answers a real buffer", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  local path = dir .. "/main.f90"
  local lines = {
    "program main",
    "  include 'mpif.h'",
    "  integer :: rank, ierr",
    "  call MPI_Comm_rank(MPI_COMM_WORLD, ",
    "end program main",
  }
  vim.fn.writefile(lines, path)

  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "fortran"

  local got, done = nil, false
  lsp.dispatch("textDocument/signatureHelp", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = lsp.to_pos(4, #lines[4] + 1),
  }, function(_, result)
    got, done = result, true
  end)
  assert_true(vim.wait(10000, function()
    return done
  end, 10), "the handler called back:")

  assert_true(got ~= nil, "the server answered:")
  assert_eq(got.activeParameter, 1, "the cursor is on rank:")
  assert_eq(got.signatures[1].label, "MPI_Comm_rank(comm, rank, ierror)", "with the compact label:")

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(dir, "rf")
end)

test("signature help refuses a non-Fortran buffer", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "call MPI_Comm_rank(" })
  vim.bo[buf].filetype = "python"
  local got, done = nil, false
  sighelp.signature({
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 0, character = 19 },
  }, function(_, result)
    got, done = result, true
  end)
  assert_true(done, "answered synchronously:")
  assert_nil(got, "python is not ours:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

_H.finish()
