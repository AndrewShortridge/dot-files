-- Spec for andrew.fortran.lsp_diagnostics -- the two PUSHED diagnostics the
-- in-process Fortran server publishes.
--
-- WHAT IT PINS
--
-- Both rules exist because the mistake they catch is SILENT. Neither can be
-- checked by running the compiler, so a test is the only thing standing
-- between the rule and a regression nobody would notice:
--
--   1. `!$OMP PARALLEL DO` in a project not built with -fopenmp is a COMMENT.
--      The build succeeds, the tests pass, the loop runs single-threaded. The
--      rule must default to "not built with it" when it cannot tell, because
--      that is the hazardous state, and it must stand down the moment the
--      Makefile or `vim.g.fortran_openmp` says otherwise.
--   2. `call MPI_Comm_rank(MPI_COMM_WORLD, rank)` is a legal external call.
--      The F77 binding has no explicit interface, so MPI writes its status
--      through a dummy that was never passed. The count comes from the
--      registry's generated `interface[]`, and the rule must not fire on a
--      function (MPI_Wtime), on a call the walker could not follow to its
--      closing paren, or on a name the PROJECT defines itself.
--
-- And the delivery path matters as much as the content: the diagnostics are
-- pushed through dispatchers.notification, which is the only route by which
-- `codeDescription.href` survives into user_data.lsp on the client side. A
-- pull-model handler returning the identical table would lose it, and the
-- float would silently stop showing the rule reference.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "an OpenMP sentinel without the flag is a warning" fails if the rule
--     reads masked text (scan.mask blanks every comment, so it would see
--     nothing at all) or if the severity/tag pair is changed.
--   * "the flag silences it" fails if opts.openmp stops being honoured -- the
--     rule would then fire on every correctly built OpenMP project.
--   * "the href anchors the rule section" fails if M.href stops lowercasing,
--     which breaks every markdown anchor.
--   * "a short MPI call is an error naming the missing dummy" fails if the
--     arity comes from anywhere but entry.interface, and if `missing` stops
--     being the trailing slice it is the code action's only input.
--   * "the range covers the callee" fails if the range is taken from the paren
--     column instead of the name start.
--   * "a complete call is clean" and "a continued call is counted whole" fail
--     if arg_slots stops following `&`, which would make every wrapped call in
--     the corpus report as short.
--   * "a function reference is not counted" fails if the kind filter goes --
--     MPI_Wtime() would report "expects 0 arguments, 0 given" today and
--     something worse after any registry regeneration.
--   * "what follows the `$` decides" fails if the conditional branch stops
--     requiring whitespace (or end of line) after `!$`: every `!$acc` line in
--     an OpenACC file is then reported as OpenMP conditional compilation,
--     which is a warning on code that has nothing to do with -fopenmp.
--   * "`!$ use omp_lib` is exempt" and "the omp_lib quickfix's own edit does
--     not reintroduce the warning" fail together if the exemption goes -- the
--     quickfix then creates a fresh instance of the warning it just fixed.
--   * "under mpi_f08 a missing ierror is correct code" fails if the arity
--     stops reading the buffer's binding: `ierror` is OPTIONAL in mpi_f08, so
--     the rule would report an Error on a correctly written modern MPI file,
--     which is worse than not having the rule.
--   * "names the binding it was judged by" fails if the message hard-codes
--     `mpi`, which would tell the user to consult the wrong standard section.
--   * "a project-defined wrapper wins" fails if the project index stops being
--     consulted: a tree with its own MPI_SEND would light up entirely.
--   * "didOpen publishes through the dispatcher" fails if on_change stops
--     calling publish, or publishes before the buffer is loaded.
--   * "didClose withdraws them" fails if on_close publishes nil or nothing --
--     the stale list then reattaches to the next buffer to take the number.
--   * "textDocumentSync advertises save" fails if the `save` field is dropped
--     from the capability. nvim registers its BufWritePost -> didSave handler
--     ONLY when that field is present (vim/lsp/client.lua), so without it the
--     diagnostics are published once on didOpen and then never refresh -- a
--     fix applied and written stays underlined forever. Found live, because
--     nothing about the notification handler itself looks wrong.
--   * "didSave recomputes" fails if the notification stops being routed.
--   * "a real client sees code and codeDescription.href" fails if the
--     diagnostics are answered as a REQUEST result rather than pushed: nvim
--     only stashes user_data.lsp on the publishDiagnostics path.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_lsp_diagnostics_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil, assert_deep_eq = _H.assert_nil, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local D = require("andrew.fortran.lsp_diagnostics")
local lsp = require("andrew.fortran.lsp")

-- ---------------------------------------------------------------------------
-- A project on disk with NO build file, so the openmp probe answers "no"
-- ---------------------------------------------------------------------------

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/code", "p")
-- `.git` is one of scan.project_root's markers, so the tree resolves to itself
-- rather than to whatever encloses the system temp directory.
vim.fn.mkdir(root .. "/.git", "p")

--- Only the diagnostics carrying `code`.
---@param list table[]
---@param code string
local function only(list, code)
  local out = {}
  for _, d in ipairs(list) do
    if d.code == code then
      out[#out + 1] = d
    end
  end
  return out
end

--- The bytes a diagnostic's range covers on a single line.
local function covered(lines, d)
  local line = lines[d.range.start.line + 1]
  return line:sub(d.range.start.character + 1, d.range["end"].character)
end

local function fortran_buf(name, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "fortran_free"
  return buf
end

-- ---------------------------------------------------------------------------
-- Rule 1 -- ompDirectiveWithoutFlag
-- ---------------------------------------------------------------------------

local OMP = {
  "program p",
  "  implicit none",
  "  integer :: i",
  "!$OMP PARALLEL DO PRIVATE(i)",
  "  do i = 1, 10",
  "  end do",
  "end program p",
}

test("an OpenMP sentinel without the flag is a warning", function()
  local ds = only(D.analyse(OMP, { openmp = false }), "ompDirectiveWithoutFlag")
  assert_eq(#ds, 1, "exactly one directive line: ")
  local d = ds[1]
  assert_eq(d.severity, 2, "Warning, not Error -- the code still builds: ")
  assert_eq(d.source, "fortran-extras", "the server names itself: ")
  assert_deep_eq(d.tags, { 1 }, "DiagnosticTag.Unnecessary -- the line is dead as built: ")
  assert_eq(d.range.start.line, 3, "the sentinel line: ")
  assert_eq(covered(OMP, d), "!$OMP PARALLEL", "sentinel plus the directive word: ")
  assert_true(d.message:find("-fopenmp", 1, true) ~= nil, "the message names the flag: ")
end)

test("the href anchors the rule's section in the reference", function()
  local ds = only(D.analyse(OMP, { openmp = false }), "ompDirectiveWithoutFlag")
  local href = ds[1].codeDescription.href
  assert_true(href:sub(-#"#ompdirectivewithoutflag") == "#ompdirectivewithoutflag", "lowercased anchor: " .. href)
  assert_true(href:match("^file://") ~= nil, "a file URL vim.ui.open can open: " .. href)
  assert_true(href:find("/doc/fortran%-extras%.md#") ~= nil, "points at the rule reference: " .. href)
end)

test("the doc file the href points at exists, with a section per rule", function()
  local path = vim.fn.stdpath("config") .. "/" .. D.DOC
  assert_eq(vim.fn.filereadable(path), 1, "doc/fortran-extras.md is shipped: ")
  local body = table.concat(vim.fn.readfile(path), "\n")
  assert_true(body:find("\n## ompDirectiveWithoutFlag", 1, true) ~= nil, "rule 1 has a heading: ")
  assert_true(body:find("\n## mpiArgumentCount", 1, true) ~= nil, "rule 2 has a heading: ")
end)

test("the flag silences it", function()
  assert_eq(#only(D.analyse(OMP, { openmp = true }), "ompDirectiveWithoutFlag"), 0, "built with -fopenmp: ")
end)

test("a fixed-form sentinel in column 1 counts", function()
  local lines = { "      PROGRAM P", "C$OMP PARALLEL DO", "      END" }
  local ds = only(D.analyse(lines, { openmp = false, fixed = true }), "ompDirectiveWithoutFlag")
  assert_eq(#ds, 1, "C$OMP is a sentinel too: ")
  assert_eq(covered(lines, ds[1]), "C$OMP PARALLEL", "the range spans it: ")
end)

test("an ordinary comment is not a sentinel", function()
  local lines = { "program p", "  ! $OMP PARALLEL DO", "  !! not a directive", "end program p" }
  assert_eq(#only(D.analyse(lines, { openmp = false }), "ompDirectiveWithoutFlag"), 0, "no sentinel: ")
end)

test("what follows the `$` decides: OpenMP sentinels only, never OpenACC's", function()
  -- OpenMP 5.2 §3.2.2: the conditional-compilation sentinel is `!$` followed
  -- by a space, a tab or the end of the line; `!$omp` is followed by
  -- whitespace and a directive name. A `$` glued to a word belongs to another
  -- vendor -- `!$acc` is OpenACC, `!$dir` is a compiler directive -- and
  -- reporting either as an OpenMP conditional line is a false positive on a
  -- line that has nothing to do with -fopenmp.
  local cases = {
    { "!$OMP PARALLEL", "directive" },
    { "!$omp end do", "directive" },
    { "  !$OMP parallel do private(i)", "directive" },
    { "!$ use omp_lib", "conditional" },
    { "!$ x = 1", "conditional" },
    { "!$", "conditional" },
    { "!$acc parallel loop", nil },
    { "!$ACC KERNELS", nil },
    { "!$dir ivdep", nil },
    { "!$x = 1", nil },
    { "! $omp parallel", nil },
    { "  ! not a directive", nil },
  }
  for _, case in ipairs(cases) do
    local s = D.sentinel(case[1], false)
    assert_eq(s and s.kind or nil, case[2], ("free form %q: "):format(case[1]))
  end

  local fixed_cases = {
    { "c$omp parallel", "directive" },
    { "C$OMP END PARALLEL", "directive" },
    { "*$omp do", "directive" },
    { "C$    use omp_lib", "conditional" },
    { "c$acc parallel loop", nil },
    { "C$ACCEL", nil },
  }
  for _, case in ipairs(fixed_cases) do
    local s = D.sentinel(case[1], true)
    assert_eq(s and s.kind or nil, case[2], ("fixed form %q: "):format(case[1]))
  end
end)

test("an OpenACC directive is not an OpenMP diagnostic", function()
  local lines = {
    "program p",
    "  implicit none",
    "  integer :: i",
    "!$acc parallel loop",
    "  do i = 1, 10",
    "  end do",
    "end program p",
  }
  assert_eq(#only(D.analyse(lines, { openmp = false }), "ompDirectiveWithoutFlag"), 0, "OpenACC is not ours: ")
end)

test("`!$ use omp_lib` is exempt -- it is the idiom, not the mistake", function()
  -- Otherwise the "Add `!$ use omp_lib`" quickfix inserts a fresh instance of
  -- the warning it just fixed, one line above the old one.
  local lines = {
    "program p",
    "  !$ use omp_lib",
    "  implicit none",
    "end program p",
  }
  assert_eq(#only(D.analyse(lines, { openmp = false }), "ompDirectiveWithoutFlag"), 0, "the guard line is fine: ")

  for _, stmt in ipairs({
    "!$ USE OMP_LIB",
    "!$ use :: omp_lib",
    "!$ use omp_lib, only: omp_get_wtime",
    "!$ use omp_lib_kinds",
    "!$   use, intrinsic :: omp_lib",
  }) do
    local one = { "program p", "  " .. stmt, "end program p" }
    assert_eq(#only(D.analyse(one, { openmp = false }), "ompDirectiveWithoutFlag"), 0, stmt .. ": ")
  end

  -- But only that statement: any other conditional line still reports.
  local other = { "program p", "  !$ nthreads = omp_get_max_threads()", "end program p" }
  assert_eq(#only(D.analyse(other, { openmp = false }), "ompDirectiveWithoutFlag"), 1, "a real conditional line: ")
end)

test("the omp_lib quickfix's own edit does not reintroduce the warning", function()
  local CA = require("andrew.fortran.lsp_codeaction")
  local lines = {
    "program p",
    "  implicit none",
    "  integer :: i",
    "!$OMP PARALLEL DO",
    "  do i = 1, 4",
    "  end do",
    "end program p",
  }
  local buf = fortran_buf(root .. "/code/omplib.f90", lines)
  local uri = vim.uri_from_bufnr(buf)
  local before = #D.analyse(lines, { openmp = false })

  local got = nil
  CA.actions({
    textDocument = { uri = uri },
    range = { start = { line = 3, character = 0 }, ["end"] = { line = 3, character = 0 } },
    context = { diagnostics = {} },
  }, function(_, res)
    got = res or {}
  end)
  assert_true(vim.wait(30000, function()
    return got ~= nil
  end, 20), "the provider answered: ")

  local action
  for _, a in ipairs(got) do
    if a.title == CA.TITLE_OMP_LIB then
      action = a
    end
  end
  assert_true(action ~= nil, "the omp_lib quickfix is offered: ")
  vim.lsp.util.apply_workspace_edit(action.edit, "utf-8")

  local after_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local after = D.analyse(after_lines, { openmp = false })
  assert_eq(#after, before, "applying the fix does not add a diagnostic: ")
  local inserted = nil
  for lnum, line in ipairs(after_lines) do
    if line:find("use omp_lib", 1, true) then
      inserted = lnum - 1
    end
  end
  assert_true(inserted ~= nil, "the statement was inserted: ")
  for _, d in ipairs(after) do
    assert_true(d.range.start.line ~= inserted, "nothing is reported on the inserted line: ")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("vim.g.fortran_openmp overrides the build-file probe", function()
  local saved = vim.g.fortran_openmp
  vim.g.fortran_openmp = true
  D.invalidate_openmp()
  assert_eq(D.openmp_enabled(root), true, "the escape hatch wins: ")
  vim.g.fortran_openmp = false
  D.invalidate_openmp()
  assert_eq(D.openmp_enabled(root), false, "and can force the warning on: ")
  vim.g.fortran_openmp = saved
  D.invalidate_openmp()
  assert_eq(D.openmp_enabled(root), false, "a project with no build file is assumed NOT to set it: ")
end)

test("a Makefile carrying -fopenmp turns the rule off", function()
  vim.fn.writefile({ "FC = gfortran", "FFLAGS = -O2 -fopenmp" }, root .. "/Makefile")
  D.invalidate_openmp()
  assert_eq(D.openmp_enabled(root), true, "the flag is visible in the build: ")
  vim.fn.delete(root .. "/Makefile")
  D.invalidate_openmp()
  assert_eq(D.openmp_enabled(root), false, "and gone once it is removed: ")
end)

-- ---------------------------------------------------------------------------
-- Rule 2 -- mpiArgumentCount
-- ---------------------------------------------------------------------------

local SHORT = {
  "program p",
  "  implicit none",
  "  integer :: rank",
  "  call MPI_Comm_rank(MPI_COMM_WORLD, rank)",
  "end program p",
}

test("a short MPI call is an error naming the missing dummy", function()
  local ds = only(D.analyse(SHORT, { openmp = true }), "mpiArgumentCount")
  assert_eq(#ds, 1, "one bad call: ")
  local d = ds[1]
  assert_eq(d.severity, 1, "Error -- this one corrupts memory: ")
  assert_eq(d.source, "fortran-extras", "the server names itself: ")
  assert_eq(
    d.message,
    "MPI_Comm_rank expects 3 arguments in the `mpi` binding, 2 given — `ierror` is mandatory",
    "the message: "
  )
  assert_deep_eq(d.data, { rule = "mpiArgumentCount", callee = "mpi_comm_rank", missing = { "ierror" } }, "data: ")
  assert_nil(d.tags, "nothing is unnecessary here: ")
end)

test("the range covers the callee, not the argument list", function()
  local d = only(D.analyse(SHORT, { openmp = true }), "mpiArgumentCount")[1]
  assert_eq(covered(SHORT, d), "MPI_Comm_rank", "exactly the name: ")
  assert_eq(d.range.start.line, 3, "on the call line: ")
end)

test("the href is the routine's own man page", function()
  local d = only(D.analyse(SHORT, { openmp = true }), "mpiArgumentCount")[1]
  assert_eq(d.codeDescription.href, "https://www.open-mpi.org/doc/current/man3/MPI_Comm_rank.3.php", "man page: ")
end)

test("a complete call is clean", function()
  local lines = {
    "program p",
    "  integer :: rank, ierr",
    "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)",
    "end program p",
  }
  assert_eq(#only(D.analyse(lines, { openmp = true }), "mpiArgumentCount"), 0, "three arguments: ")
end)

test("a continued call is counted whole", function()
  local lines = {
    "program p",
    "  integer :: rank, ierr",
    "  call MPI_Comm_rank(MPI_COMM_WORLD, &",
    "                     rank, ierr)",
    "end program p",
  }
  assert_eq(#only(D.analyse(lines, { openmp = true }), "mpiArgumentCount"), 0, "the `&` is followed: ")
end)

test("an unclosed call is not reported", function()
  local lines = { "program p", "  call MPI_Comm_rank(MPI_COMM_WORLD, rank", "end program p" }
  assert_eq(#only(D.analyse(lines, { openmp = true }), "mpiArgumentCount"), 0, "half-typed is not wrong: ")
end)

test("a function reference is not counted", function()
  local lines = { "program p", "  double precision :: t", "  t = MPI_Wtime()", "end program p" }
  assert_eq(#only(D.analyse(lines, { openmp = true }), "mpiArgumentCount"), 0, "MPI_Wtime is a function: ")
end)

test("too many arguments reports the count without a missing list", function()
  local lines = { "program p", "  call MPI_Init(ierr, extra)", "end program p" }
  local ds = only(D.analyse(lines, { openmp = true }), "mpiArgumentCount")
  assert_eq(#ds, 1, "one bad call: ")
  assert_eq(ds[1].message, "MPI_Init expects 1 argument in the `mpi` binding, 2 given", "singular, no missing list: ")
  assert_deep_eq(ds[1].data.missing, {}, "nothing is missing: ")
end)

-- The binding in scope decides whether `ierror` is mandatory at all: in
-- `mpi` / `mpif.h` it is a plain final dummy, in `mpi_f08` it is OPTIONAL
-- (MPI-3.0 §17.1.6, and every registry entry's `binding_note`). Reporting the
-- f08 call would be an Error on the file that did it right.
local F08_SHORT = {
  "program p",
  "  use mpi_f08",
  "  implicit none",
  "  integer :: rank",
  "  call MPI_Comm_rank(MPI_COMM_WORLD, rank)",
  "end program p",
}

test("under mpif.h a missing ierror is still an Error", function()
  local lines = {
    "program p",
    "  include 'mpif.h'",
    "  integer :: rank",
    "  call MPI_Comm_rank(MPI_COMM_WORLD, rank)",
    "end program p",
  }
  local ds = only(D.analyse(lines, { openmp = true }), "mpiArgumentCount")
  assert_eq(#ds, 1, "the F77 binding has no optional dummies: ")
  assert_eq(ds[1].severity, 1, "Error: ")
  assert_true(ds[1].message:find("`mpi` binding", 1, true) ~= nil, "named as the mpi binding: " .. ds[1].message)
end)

test("under mpi_f08 a missing ierror is correct code, not a diagnostic", function()
  assert_eq(#only(D.analyse(F08_SHORT, { openmp = true }), "mpiArgumentCount"), 0, "ierror is OPTIONAL there: ")
  assert_eq(D.mpi_binding(F08_SHORT), "mpi_f08", "the binding is read off the buffer: ")
  for _, spelling in ipairs({ "  use mpi_f08", "  use :: mpi_f08", "  use mpi_f08, only: MPI_Comm_rank" }) do
    local lines = vim.deepcopy(F08_SHORT)
    lines[2] = spelling
    assert_eq(#only(D.analyse(lines, { openmp = true }), "mpiArgumentCount"), 0, spelling .. ": ")
  end
  -- A mixed-binding file is read permissively: a false Error costs more than a
  -- missed report.
  local mixed = vim.deepcopy(F08_SHORT)
  table.insert(mixed, 2, "  use mpi")
  assert_eq(#only(D.analyse(mixed, { openmp = true }), "mpiArgumentCount"), 0, "both modules in scope: ")
end)

test("under mpi_f08 a full argument list is clean too", function()
  local lines = vim.deepcopy(F08_SHORT)
  lines[4] = "  integer :: rank, ierr"
  lines[5] = "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)"
  assert_eq(#only(D.analyse(lines, { openmp = true }), "mpiArgumentCount"), 0, "passing ierror is legal as well: ")
end)

test("under mpi_f08 a genuinely short call names the binding it was judged by", function()
  local lines = vim.deepcopy(F08_SHORT)
  lines[5] = "  call MPI_Comm_rank(MPI_COMM_WORLD)"
  local ds = only(D.analyse(lines, { openmp = true }), "mpiArgumentCount")
  assert_eq(#ds, 1, "`rank` is mandatory in every binding: ")
  assert_eq(
    ds[1].message,
    "MPI_Comm_rank expects 2 or 3 arguments in the `mpi_f08` binding, 1 given — `rank` is mandatory",
    "the message names the binding actually detected: "
  )
end)

test("a project-defined wrapper wins over the standard binding", function()
  local lines = { "program p", "  call MPI_Send(buf, n)", "end program p" }
  assert_eq(#only(D.analyse(lines, { openmp = true }), "mpiArgumentCount"), 1, "without the project index it fires: ")
  local ds = only(D.analyse(lines, { openmp = true, project = { mpi_send = true } }), "mpiArgumentCount")
  assert_eq(#ds, 0, "the project's own MPI_Send owns the name: ")
end)

-- ---------------------------------------------------------------------------
-- The push path
-- ---------------------------------------------------------------------------

local BOTH = {
  "program p",
  "  implicit none",
  "  integer :: rank",
  "!$OMP PARALLEL DO",
  "  call MPI_Comm_rank(MPI_COMM_WORLD, rank)",
  "end program p",
}

test("didOpen publishes through the dispatcher", function()
  local buf = fortran_buf(root .. "/code/push.f90", BOTH)
  local uri = vim.uri_from_bufnr(buf)
  local seen = nil
  local srv = lsp.server({
    notification = function(method, params)
      if method == "textDocument/publishDiagnostics" then
        seen = params
      end
    end,
  })
  srv.notify("textDocument/didOpen", { textDocument = { uri = uri } })
  assert_true(vim.wait(30000, function()
    return seen ~= nil
  end, 20), "a publishDiagnostics notification arrived: ")

  assert_eq(seen.uri, uri, "for this document: ")
  local codes = {}
  for _, d in ipairs(seen.diagnostics) do
    codes[#codes + 1] = d.code
  end
  table.sort(codes)
  assert_deep_eq(codes, { "mpiArgumentCount", "ompDirectiveWithoutFlag" }, "both rules fired: ")
  for _, d in ipairs(seen.diagnostics) do
    assert_true(d.codeDescription ~= nil and d.codeDescription.href ~= nil, d.code .. " carries an href: ")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("textDocumentSync advertises save, or nvim never sends didSave", function()
  local sync = lsp.capabilities().textDocumentSync
  assert_true(sync ~= nil, "document sync is declared: ")
  assert_true(sync.save ~= nil, "and `save` with it -- the didSave gate: ")
  assert_true(sync.openClose == true, "openClose stays, for didOpen/didClose: ")
end)

test("didSave recomputes and republishes", function()
  local buf = fortran_buf(root .. "/code/resave.f90", BOTH)
  local uri = vim.uri_from_bufnr(buf)
  local seen = nil
  local srv = lsp.server({
    notification = function(method, params)
      if method == "textDocument/publishDiagnostics" then
        seen = params
      end
    end,
  })
  srv.notify("textDocument/didOpen", { textDocument = { uri = uri } })
  assert_true(vim.wait(30000, function()
    return seen ~= nil
  end, 20), "the first publish arrived: ")
  assert_eq(#seen.diagnostics, 2, "two rules on the way in: ")

  -- Repair the call in the buffer and save: the count rule must stand down.
  vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)" })
  seen = nil
  srv.notify("textDocument/didSave", { textDocument = { uri = uri } })
  assert_true(vim.wait(30000, function()
    return seen ~= nil
  end, 20), "a second publish arrived: ")
  local codes = {}
  for _, d in ipairs(seen.diagnostics) do
    codes[#codes + 1] = d.code
  end
  assert_deep_eq(codes, { "ompDirectiveWithoutFlag" }, "only the directive warning is left: ")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("didClose withdraws them", function()
  local seen = nil
  local srv = lsp.server({
    notification = function(method, params)
      if method == "textDocument/publishDiagnostics" then
        seen = params
      end
    end,
  })
  srv.notify("textDocument/didClose", { textDocument = { uri = "file:///nowhere/x.f90" } })
  assert_true(vim.wait(5000, function()
    return seen ~= nil
  end, 10), "a notification arrived: ")
  assert_eq(seen.uri, "file:///nowhere/x.f90", "for the closed document: ")
  assert_eq(#seen.diagnostics, 0, "an EMPTY list, not nil: ")
end)

test("a real client sees code and codeDescription.href", function()
  local buf = fortran_buf(root .. "/code/live.f90", BOTH)
  local id = lsp.attach(buf)
  assert_true(id ~= nil, "the server attached: ")
  assert_true(
    vim.wait(30000, function()
      return #vim.diagnostic.get(buf) > 0
    end, 50),
    "diagnostics reached vim.diagnostic: "
  )

  local by_code = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    by_code[d.code] = d
  end
  assert_true(by_code.ompDirectiveWithoutFlag ~= nil, "the OpenMP rule is visible client-side: ")
  assert_true(by_code.mpiArgumentCount ~= nil, "the MPI rule is visible client-side: ")
  assert_eq(by_code.mpiArgumentCount.source, "fortran-extras", "source survives: ")

  -- The point of pushing rather than pulling: nvim parks the raw LSP
  -- diagnostic under user_data.lsp, which is the only place the href lives.
  local href = vim.tbl_get(by_code.ompDirectiveWithoutFlag, "user_data", "lsp", "codeDescription", "href")
  assert_true(href ~= nil, "codeDescription.href survived into user_data.lsp: ")
  assert_true(href:sub(-#"#ompdirectivewithoutflag") == "#ompdirectivewithoutflag", "and still anchors: " .. href)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

vim.fn.delete(root, "rf")
_H.finish()
