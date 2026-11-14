-- Spec for andrew.fortran.lsp_codeaction -- the three quickfixes the
-- in-process Fortran server offers.
--
-- WHAT IT PINS
--
-- Every one of these actions is an edit at a place the cursor is NOT, which is
-- the whole reason they are code actions and not snippets, and the whole
-- reason each of them has a way of landing in the wrong place:
--
--   1. `!$ use omp_lib` and `include 'mpif.h'` go after the header and after
--      any existing `use` lines, but BEFORE `implicit none`. Fortran enforces
--      that order: a USE statement must precede IMPLICIT. Insert one line too
--      early and the file stops compiling; one line too late and it stops
--      compiling differently.
--   2. The `ierror` argument goes before the CALL's closing paren, which for a
--      continued call is on another line entirely. Appending to the
--      diagnostic's own line would bury the argument inside the middle of the
--      list.
--   3. None of the three may be offered twice. A file that already says
--      `use mpi` must not be told to include mpif.h as well -- that is two
--      bindings of the same names in one scope, and it is a hard error.
--
-- The status-argument name is the fourth trap: this corpus spells it `IERR`,
-- `ierr` and `mpi_err` in different files, and inserting the wrong one
-- produces an undeclared variable under IMPLICIT NONE. It is copied from the
-- buffer's own correct calls, from the RAW line so the casing survives.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "use omp_lib lands after the use block" fails if insert_point stops
--     walking the `use` run, or starts walking past `implicit none`.
--   * "the omp_lib insert is a `!$` line" fails if the sentinel is dropped:
--     the statement then breaks every build WITHOUT -fopenmp, which is
--     precisely the build the action is offered in.
--   * "fixed form puts the sentinel in column 1" fails if the fixed-form
--     branch indents it like free-form code, which makes it a continuation
--     marker rather than a sentinel.
--   * "no duplicate omp_lib / no duplicate binding" fail if the presence
--     checks read MASKED text -- scan.mask blanks `!$ use omp_lib` (a comment)
--     and blanks the `'mpif.h'` literal, so both would be invisible and both
--     actions would be offered forever.
--   * "the ierror fix inserts before the closing paren" fails if the edit is
--     positioned from the diagnostic's range rather than from arg_slots.
--   * "a continued call is closed on its last line" fails if arg_slots stops
--     reporting where the list closed -- the argument would go onto the head
--     line, inside the list.
--   * "the status name is copied from the buffer" fails if the name is read
--     from the MASKED slot text, which is lowercased: `IERR` would come back
--     as `ierr` and not compile under a case-sensitive linter's eye.
--   * "one underline is claimed once" fails if the two offer paths (the
--     client's context and the re-derivation) stop being deduped: the action
--     then carries the same diagnostic twice and nvim counts it as fixing two
--     problems.
--   * "neither MPI action is offered in an mpi_f08 buffer" fails if the
--     binding stops being read off the buffer -- `ierror` is OPTIONAL there,
--     so the quickfix would offer to "repair" a correct call, and the include
--     would bind the same names a second time in one scope.
--   * "actions carry an edit and no command" fails if a command is added --
--     nvim then needs a round trip and an executeCommand provider that this
--     server does not have.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_lsp_codeaction_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil = _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local CA = require("andrew.fortran.lsp_codeaction")
local D = require("andrew.fortran.lsp_diagnostics")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/code", "p")
vim.fn.mkdir(root .. "/.git", "p")

local seq = 0

--- A named, loaded Fortran buffer in the temp project.
local function buf_for(lines, ft)
  seq = seq + 1
  local ext = ft == "fortran_fixed" and ".f" or ".f90"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, ("%s/code/ca%d%s"):format(root, seq, ext))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft or "fortran_free"
  return buf
end

--- Drive actions() to completion. `diags` (optional) becomes the client
--- context; passing nil is the case where the client forwards nothing and the
--- provider has to re-derive them.
local function actions_for(lines, lnum, diags, ft)
  local buf = buf_for(lines, ft)
  local uri = vim.uri_from_bufnr(buf)
  local pos = { line = lnum - 1, character = 0 }
  local got = nil
  CA.actions({
    textDocument = { uri = uri },
    range = { start = pos, ["end"] = pos },
    context = { diagnostics = diags or {} },
  }, function(_, res)
    got = res or {}
  end)
  vim.wait(30000, function()
    return got ~= nil
  end, 20)
  vim.api.nvim_buf_delete(buf, { force = true })
  return got or {}, uri
end

local function by_title(list, title)
  for _, a in ipairs(list) do
    if a.title == title then
      return a
    end
  end
  return nil
end

--- The single TextEdit of an action.
local function edit_of(action, uri)
  local edits = action.edit.changes[uri]
  assert_true(#edits == 1, "exactly one edit: ")
  return edits[1]
end

-- ---------------------------------------------------------------------------
-- Add `!$ use omp_lib`
-- ---------------------------------------------------------------------------

local OMP = {
  "program p", -- 1
  "  use iso_fortran_env", -- 2
  "  implicit none", -- 3
  "  integer :: i", -- 4
  "!$OMP PARALLEL DO", -- 5
  "  do i = 1, 4", -- 6
  "  end do", -- 7
  "end program p", -- 8
}

test("use omp_lib lands after the use block and before implicit none", function()
  local list, uri = actions_for(OMP, 5)
  local a = by_title(list, CA.TITLE_OMP_LIB)
  assert_true(a ~= nil, "the action is offered: " .. vim.inspect(vim.tbl_map(function(x)
    return x.title
  end, list)))
  assert_eq(a.kind, "quickfix", "kind: ")
  assert_eq(a.isPreferred, true, "preferred: ")
  local e = edit_of(a, uri)
  assert_eq(e.range.start.line, 2, "line 3 (1-based) -- just before `implicit none`: ")
  assert_eq(e.range.start.character, 0, "at the start of the line: ")
  assert_eq(e.range["end"].line, 2, "a zero-width insertion: ")
  assert_eq(e.newText, "  !$ use omp_lib\n", "the statement, sentinel and all: ")
end)

test("the action carries an edit and no command", function()
  local list = actions_for(OMP, 5)
  for _, a in ipairs(list) do
    assert_nil(a.command, a.title .. " needs no executeCommand round trip: ")
    assert_true(a.edit ~= nil and a.edit.changes ~= nil, a.title .. " carries the edit itself: ")
  end
end)

test("no duplicate when omp_lib is already used", function()
  local lines = vim.deepcopy(OMP)
  table.insert(lines, 2, "!$ use omp_lib")
  local list = actions_for(lines, 6)
  assert_nil(by_title(list, CA.TITLE_OMP_LIB), "a commented `!$ use omp_lib` still counts as present: ")
end)

test("no offer without a directive", function()
  local list = actions_for({ "program p", "  implicit none", "end program p" }, 2)
  assert_nil(by_title(list, CA.TITLE_OMP_LIB), "nothing to enable: ")
end)

test("fixed form puts the sentinel in column 1 and the statement in column 7", function()
  local lines = {
    "      PROGRAM P",
    "      IMPLICIT NONE",
    "C$OMP PARALLEL DO",
    "      END",
  }
  local list, uri = actions_for(lines, 3, nil, "fortran_fixed")
  local a = by_title(list, CA.TITLE_OMP_LIB)
  assert_true(a ~= nil, "offered in fixed form too: ")
  local e = edit_of(a, uri)
  assert_eq(e.newText, "!$    use omp_lib\n", "sentinel in columns 1-2, statement from column 7: ")
  assert_eq(e.range.start.line, 1, "straight after the PROGRAM line: ")
end)

-- ---------------------------------------------------------------------------
-- Add `include 'mpif.h'`
-- ---------------------------------------------------------------------------

local MPI = {
  "program p", -- 1
  "  implicit none", -- 2
  "  integer :: rank, ierr", -- 3
  "  call MPI_Init(ierr)", -- 4
  "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)", -- 5
  "end program p", -- 6
}

test("include mpif.h lands straight after the header", function()
  local list, uri = actions_for(MPI, 4)
  local a = by_title(list, CA.TITLE_MPIF_H)
  assert_true(a ~= nil, "the action is offered: ")
  local e = edit_of(a, uri)
  assert_eq(e.range.start.line, 1, "line 2 -- before `implicit none`, no `use` lines to clear: ")
  assert_eq(e.newText, "  include 'mpif.h'\n", "the statement: ")
end)

test("no duplicate when a binding is already in scope", function()
  for _, present in ipairs({ "  include 'mpif.h'", "  use mpi", "  use mpi_f08" }) do
    local lines = vim.deepcopy(MPI)
    table.insert(lines, 2, present)
    local list = actions_for(lines, 5)
    assert_nil(by_title(list, CA.TITLE_MPIF_H), "`" .. present .. "` already binds the names: ")
  end
end)

test("no offer without an MPI reference", function()
  local list = actions_for({ "program p", "  implicit none", "  call solve(x)", "end program p" }, 3)
  assert_nil(by_title(list, CA.TITLE_MPIF_H), "no MPI in the buffer: ")
end)

-- ---------------------------------------------------------------------------
-- Add the missing `ierror` argument
-- ---------------------------------------------------------------------------

local SHORT = {
  "program p", -- 1
  "  include 'mpif.h'", -- 2
  "  integer :: rank, n, ierr", -- 3
  "  call MPI_Comm_size(MPI_COMM_WORLD, n, ierr)", -- 4
  "  call MPI_Comm_rank(MPI_COMM_WORLD, rank)", -- 5
  "end program p", -- 6
}

test("the ierror fix inserts before the closing paren", function()
  local diags = D.analyse(SHORT, { openmp = true })
  local list, uri = actions_for(SHORT, 5, diags)
  local a = by_title(list, CA.TITLE_IERROR)
  assert_true(a ~= nil, "the action is offered: ")
  assert_eq(a.kind, "quickfix", "kind: ")
  assert_eq(#a.diagnostics, 1, "it is attached to its diagnostic: ")
  assert_eq(a.diagnostics[1].code, "mpiArgumentCount", "the right one: ")
  local e = edit_of(a, uri)
  assert_eq(e.range.start.line, 4, "on the call line: ")
  -- `  call MPI_Comm_rank(MPI_COMM_WORLD, rank)` -- the `)` is the 42nd byte,
  -- so the zero-width insertion sits at 0-based character 41.
  assert_eq(e.range.start.character, 41, "immediately before the `)`: ")
  assert_eq(e.newText, ", ierr", "the status argument, comma and all: ")
  assert_eq(SHORT[5]:sub(42, 42), ")", "the character it goes before: ")
end)

test("the status name is copied from the buffer's own correct calls", function()
  local lines = vim.deepcopy(SHORT)
  lines[3] = "  integer :: rank, n, IERR"
  lines[4] = "  call MPI_Comm_size(MPI_COMM_WORLD, n, IERR)"
  local list, uri = actions_for(lines, 5, D.analyse(lines, { openmp = true }))
  local e = edit_of(by_title(list, CA.TITLE_IERROR), uri)
  assert_eq(e.newText, ", IERR", "the buffer's own casing, read from the RAW line: ")
end)

test("a buffer with no correct call falls back to ierr", function()
  local lines = {
    "program p",
    "  include 'mpif.h'",
    "  integer :: rank",
    "  call MPI_Comm_rank(MPI_COMM_WORLD, rank)",
    "end program p",
  }
  local list, uri = actions_for(lines, 4, D.analyse(lines, { openmp = true }))
  local e = edit_of(by_title(list, CA.TITLE_IERROR), uri)
  assert_eq(e.newText, ", ierr", "the registry's own spelling: ")
end)

test("a continued call is closed on its last line", function()
  local lines = {
    "program p", -- 1
    "  include 'mpif.h'", -- 2
    "  integer :: rank, ierr", -- 3
    "  call MPI_Comm_rank(MPI_COMM_WORLD, &", -- 4
    "                     rank)", -- 5
    "end program p", -- 6
  }
  local list, uri = actions_for(lines, 4, D.analyse(lines, { openmp = true }))
  local a = by_title(list, CA.TITLE_IERROR)
  assert_true(a ~= nil, "offered for the continued call: ")
  local e = edit_of(a, uri)
  assert_eq(e.range.start.line, 4, "the CONTINUATION line, not the diagnostic's line: ")
  assert_eq(e.range.start.character, 25, "before the `)` that actually closes the list: ")
  assert_eq(lines[5]:sub(26, 26), ")", "the character it goes before: ")
end)

test("the fix is offered with no client context at all", function()
  -- nvim's own vim.lsp.buf.code_action forwards the diagnostics at the cursor,
  -- but a programmatic buf_request_sync frequently forwards none. The offer
  -- has to be the same either way or the action is untestable and unreliable.
  local list, uri = actions_for(SHORT, 5, nil)
  local a = by_title(list, CA.TITLE_IERROR)
  assert_true(a ~= nil, "re-derived from the buffer: ")
  assert_eq(edit_of(a, uri).newText, ", ierr", "the same edit: ")
end)

test("one underline is claimed once, not twice", function()
  -- Both offer paths can produce the same report: a client that forwards the
  -- OpenMP warning still leaves the ierror list empty, which sends the
  -- provider down the re-derivation path, which recomputes that same warning.
  -- Two entries for one underline makes nvim count the action as fixing two
  -- problems.
  local diags = D.analyse(OMP, { openmp = false })
  local omp = nil
  for _, d in ipairs(diags) do
    if d.code == "ompDirectiveWithoutFlag" then
      omp = d
    end
  end
  assert_true(omp ~= nil, "the fixture has an OpenMP warning: ")
  local list = actions_for(OMP, 5, { omp })
  local a = by_title(list, CA.TITLE_OMP_LIB)
  assert_true(a ~= nil, "the action is offered: ")
  assert_eq(#a.diagnostics, 1, "one diagnostic for one underline: ")
  assert_eq(a.diagnostics[1].code, "ompDirectiveWithoutFlag", "the one the client sent: ")
end)

-- ---------------------------------------------------------------------------
-- The mpi_f08 binding
-- ---------------------------------------------------------------------------

local F08 = {
  "program p", -- 1
  "  use mpi_f08", -- 2
  "  implicit none", -- 3
  "  integer :: rank", -- 4
  "  call MPI_Comm_rank(MPI_COMM_WORLD, rank)", -- 5
  "end program p", -- 6
}

test("neither MPI action is offered in an mpi_f08 buffer", function()
  -- `ierror` is OPTIONAL in that binding, so there is nothing missing to add;
  -- and `include 'mpif.h'` on top of `use mpi_f08` binds the same names twice
  -- in one scope, which is a hard error.
  local list = actions_for(F08, 5, nil)
  assert_nil(by_title(list, CA.TITLE_IERROR), "the call is already correct: ")
  assert_nil(by_title(list, CA.TITLE_MPIF_H), "the module is the binding: ")

  -- Even when the client forwards a stale diagnostic from before the `use`
  -- line was added, the offer must not come back.
  local stale = D.analyse(F08, { openmp = true, binding = "mpi" })
  assert_true(#stale > 0, "the fixture would report under the mpi binding: ")
  local again = actions_for(F08, 5, stale)
  assert_nil(by_title(again, CA.TITLE_IERROR), "a stale diagnostic does not resurrect it: ")
end)

test("`use :: mpi` spellings still suppress the include quickfix", function()
  for _, present in ipairs({ "  use :: mpi", "  use mpi, only: MPI_COMM_WORLD", "  use, intrinsic :: mpi_f08" }) do
    local lines = vim.deepcopy(MPI)
    table.insert(lines, 2, present)
    local list = actions_for(lines, 5)
    assert_nil(by_title(list, CA.TITLE_MPIF_H), "`" .. present .. "` already binds the names: ")
  end
end)

test("the fix is not offered on an unrelated line", function()
  local list = actions_for(SHORT, 4, nil)
  assert_nil(by_title(list, CA.TITLE_IERROR), "line 4's call is correct: ")
end)

test("applying the fix produces a compilable call", function()
  -- The end of the loop: take the edit and apply it the way the client does.
  local buf = buf_for(SHORT, "fortran_free")
  local uri = vim.uri_from_bufnr(buf)
  local got = nil
  CA.actions({
    textDocument = { uri = uri },
    range = { start = { line = 4, character = 0 }, ["end"] = { line = 4, character = 0 } },
    context = { diagnostics = D.analyse(SHORT, { openmp = true }) },
  }, function(_, res)
    got = res or {}
  end)
  vim.wait(30000, function()
    return got ~= nil
  end, 20)
  local a = by_title(got or {}, CA.TITLE_IERROR)
  assert_true(a ~= nil, "the action is there: ")
  vim.lsp.util.apply_workspace_edit(a.edit, "utf-8")
  local line = vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
  assert_eq(line, "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)", "the repaired call: ")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

vim.fn.delete(root, "rf")
_H.finish()
