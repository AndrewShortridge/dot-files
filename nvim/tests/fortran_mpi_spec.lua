-- Spec for andrew.fortran.mpi -- mpif.h discovery, external-header
-- classification and builtin signature seeding.
--
-- WHAT IT PINS
--
-- This project brings MPI in as `INCLUDE 'mpif.h'` in 229 files, and mpif.h
-- ships with the MPI installation rather than the source. Before discovery
-- existed, gfortran hit a FATAL include error on line 5 of every one of them
-- and terminated the parse, so each file carried exactly one diagnostic, that
-- diagnostic was false, and it masked everything else. The failure mode is
-- silent in the worst way: it looks like a clean file with one known
-- complaint.
--
-- Three separable pieces are pinned here.
--
-- `discover` is split out of `include_dirs` precisely so it can be driven with
-- a stub `readable` -- the real one depends on which MPI happens to be
-- installed, which is not something a spec may assume.
--
-- `is_external_header` exists because gfortran reports a diagnostic inside an
-- INCLUDE using the name AS WRITTEN, with no directory: `mpif.h:372:36`. The
-- per-buffer lint path drops those by basename, but the workspace path groups
-- by reported name and calls `vim.fn.bufnr(name, true)`, which would
-- FABRICATE an empty `mpif.h` buffer holding ~294 warnings on lines it does
-- not have. Resolving against the project root instead is wrong, because
-- `common.h` arrives equally bare and lives in `code/`.
--
-- `seed` must run AFTER the project scan and fill gaps only, so a project that
-- defines its own MPI_SEND wrapper keeps the wrapper's real dummy names.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "stops at the first hit" fails if the default limit is raised, which
--     would put two MPI implementations on one include path -- the way to get
--     a subtly wrong MPI_STATUS_SIZE rather than an error.
--   * "skips duplicate candidates" fails if the `seen` guard is dropped.
--   * "preserves candidate order" fails if discovery sorts or reverses.
--   * "a project header of the same name wins" fails if the project_dirs loop
--     is removed or moved after the mpi_dirs loop -- the ordering IS the rule.
--   * "an absolute path is judged by prefix alone" fails if the absolute
--     branch falls through to the readable tests instead of returning. Note
--     what this does NOT catch: with a stub holding no paths, falling through
--     also answers false, so merely asserting on an outside path proves
--     nothing -- the first draft of this test did exactly that and passed
--     against the mutant. The case has to be one where concatenation would
--     find something, which on a real filesystem it can: POSIX collapses the
--     "//" that joining a directory to an absolute path produces, so
--     "/opt/mpi/include" + "/elsewhere/mpif.h" resolves to a real path.
--   * "a prefix that is not a path segment does not match" fails if the
--     absolute branch compares with a bare prefix instead of requiring the
--     trailing "/" -- `/opt/mpi-old` must not match dir `/opt/mpi`.
--   * "seeding does not overwrite a project definition" fails if `seed` drops
--     its `if not sigs[lname]` guard.
--   * "every routine that reports status ends in ierror" fails if any
--     signature omits the trailing ierror -- the single commonest Fortran MPI
--     bug is dropping that argument, and a hint list that omits it would
--     actively teach the mistake.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_mpi_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local mpi = require("andrew.fortran.mpi")

--- Build a `readable` stub over a set of paths.
local function reader(paths)
  local set = {}
  for _, p in ipairs(paths) do
    set[p] = true
  end
  return function(p)
    return set[p] == true
  end
end

-- ---------------------------------------------------------------------------
-- discover
-- ---------------------------------------------------------------------------

test("discover finds the directory holding mpif.h", function()
  local got = mpi.discover(
    { "/a", "/b", "/c" },
    reader({ "/b/mpif.h" })
  )
  assert_eq(#got, 1, "one hit:")
  assert_eq(got[1], "/b", "the directory, not the file:")
end)

test("discover stops at the first hit", function()
  -- Two MPI implementations on one include path is how MPI_STATUS_SIZE ends
  -- up subtly wrong, so the default limit of one is deliberate.
  local got = mpi.discover(
    { "/a", "/b", "/c" },
    reader({ "/a/mpif.h", "/b/mpif.h", "/c/mpif.h" })
  )
  assert_eq(#got, 1, "only the first:")
  assert_eq(got[1], "/a", "which one:")
end)

test("discover honours an explicit limit", function()
  local got = mpi.discover(
    { "/a", "/b", "/c" },
    reader({ "/a/mpif.h", "/c/mpif.h" }),
    5
  )
  assert_eq(#got, 2, "both hits:")
  assert_eq(got[1] .. "," .. got[2], "/a,/c", "in candidate order:")
end)

test("discover preserves candidate order", function()
  -- Order encodes priority: environment variables, then the active conda
  -- prefix, then sibling environments, then system paths.
  local got = mpi.discover(
    { "/z", "/y", "/x" },
    reader({ "/y/mpif.h", "/x/mpif.h" }),
    9
  )
  assert_eq(got[1], "/y", "first hit in the given order:")
  assert_eq(got[2], "/x", "second:")
end)

test("discover skips duplicate candidates", function()
  local seen = 0
  local got = mpi.discover({ "/a", "/a", "/a" }, function(p)
    seen = seen + 1
    return false
  end)
  assert_eq(#got, 0, "no hits:")
  assert_eq(seen, 1, "the same directory is tested once:")
end)

test("discover returns empty when nothing holds mpif.h", function()
  local got = mpi.discover({ "/a", "/b" }, reader({}))
  assert_eq(#got, 0, "no MPI installed:")
end)

-- ---------------------------------------------------------------------------
-- is_external_header
-- ---------------------------------------------------------------------------

local MPI_DIRS = { "/opt/mpi/include" }
local PROJ_DIRS = { "/proj", "/proj/code" }

test("a bare MPI header name is external", function()
  -- Exactly how gfortran reports it: `mpif.h:372:36: Warning: ...`
  assert_true(mpi.is_external_header("mpif.h", MPI_DIRS, PROJ_DIRS,
    reader({ "/opt/mpi/include/mpif.h" })), "mpif.h:")
end)

test("a project header is not external", function()
  -- common.h and parameters.h arrive just as bare as mpif.h does.
  assert_false(mpi.is_external_header("common.h", MPI_DIRS, PROJ_DIRS,
    reader({ "/proj/code/common.h" })), "common.h:")
end)

test("a project header of the same name wins", function()
  -- A project shipping its own mpif.h keeps its diagnostics. The project
  -- directories MUST be tested first for this to hold.
  assert_false(mpi.is_external_header("mpif.h", MPI_DIRS, PROJ_DIRS,
    reader({ "/proj/code/mpif.h", "/opt/mpi/include/mpif.h" })), "shadowed mpif.h:")
end)

test("an unknown name is not external", function()
  assert_false(mpi.is_external_header("Share-EAM.f90", MPI_DIRS, PROJ_DIRS,
    reader({})), "unknown:")
end)

test("an absolute path inside an MPI dir is external", function()
  -- Answered without touching the filesystem at all.
  assert_true(mpi.is_external_header("/opt/mpi/include/mpif.h", MPI_DIRS, PROJ_DIRS,
    reader({})), "absolute inside:")
end)

test("an absolute path outside the MPI dirs is not external", function()
  assert_false(mpi.is_external_header("/proj/code/Share-EAM.f90", MPI_DIRS, PROJ_DIRS,
    reader({})), "absolute outside:")
end)

test("an absolute path is judged by prefix alone", function()
  -- The absolute branch must ANSWER, not fall through to the readable tests.
  -- Falling through would join the MPI directory to an already-absolute path;
  -- POSIX collapses the resulting "//", so that join can name a real file and
  -- would report an unrelated header as external.
  assert_false(mpi.is_external_header("/elsewhere/mpif.h", MPI_DIRS, PROJ_DIRS,
    reader({ "/opt/mpi/include//elsewhere/mpif.h" })), "concatenation must not decide:")
end)

test("a prefix that is not a path segment does not match", function()
  -- /opt/mpi-old is not inside /opt/mpi.
  assert_false(mpi.is_external_header("/opt/mpi/include-old/x.h", { "/opt/mpi/include" },
    PROJ_DIRS, reader({})), "sibling directory:")
end)

test("junk input is not external", function()
  assert_false(mpi.is_external_header("", MPI_DIRS, PROJ_DIRS, reader({})), "empty:")
  assert_false(mpi.is_external_header(nil, MPI_DIRS, PROJ_DIRS, reader({})), "nil:")
end)

-- ---------------------------------------------------------------------------
-- Signatures and seeding
-- ---------------------------------------------------------------------------

test("MPI_Bcast has the standard six arguments", function()
  local a = mpi.SIGNATURES.mpi_bcast
  assert_eq(#a, 6, "argument count:")
  assert_eq(table.concat(a, ","), "buffer,count,datatype,root,comm,ierror", "names:")
end)

test("MPI_Recv carries status before ierror", function()
  -- The receive is the one that gains a status argument; getting this pair
  -- backwards puts every later hint on the wrong argument.
  local a = mpi.SIGNATURES.mpi_recv
  assert_eq(a[#a - 1], "status", "penultimate:")
  assert_eq(a[#a], "ierror", "last:")
end)

test("every routine that reports status ends in ierror", function()
  -- Omitting the trailing ierror is the classic Fortran MPI bug and the
  -- compiler cannot catch it. A hint list that omitted it would teach it.
  for name, args in pairs(mpi.SIGNATURES) do
    if #args > 0 then
      assert_eq(args[#args], "ierror", name .. " last argument:")
    end
  end
end)

test("the timing functions take no arguments", function()
  assert_eq(#mpi.SIGNATURES.mpi_wtime, 0, "MPI_Wtime:")
  assert_eq(#mpi.SIGNATURES.mpi_wtick, 0, "MPI_Wtick:")
end)

test("constants are absent from the signature table", function()
  -- A constant here would make call_sites treat MPI_STATUS_SIZE in
  -- `INTEGER status(MPI_STATUS_SIZE)` as a one-argument call and hang a hint
  -- off an array bound.
  for _, c in ipairs({
    "mpi_comm_world", "mpi_double_precision", "mpi_status_size",
    "mpi_integer", "mpi_sum", "mpi_any_source", "mpi_source",
  }) do
    assert_eq(mpi.SIGNATURES[c], nil, c .. " must not be callable:")
  end
end)

test("seeding fills a gap", function()
  local sigs = {}
  mpi.seed(sigs)
  assert_true(sigs.mpi_bcast ~= nil, "mpi_bcast seeded:")
  assert_eq(sigs.mpi_bcast.args[1], "buffer", "first dummy:")
  assert_eq(sigs.mpi_bcast.builtin, true, "marked builtin:")
end)

test("seeding does not overwrite a project definition", function()
  -- A project wrapper named MPI_SEND must keep its own dummy names.
  local sigs = { mpi_send = { name = "MPI_SEND", args = { "mine", "yours" }, path = "/proj/w.f90" } }
  mpi.seed(sigs)
  assert_eq(#sigs.mpi_send.args, 2, "project args kept:")
  assert_eq(sigs.mpi_send.args[1], "mine", "first dummy:")
  assert_eq(sigs.mpi_send.path, "/proj/w.f90", "project entry untouched:")
  assert_true(sigs.mpi_recv ~= nil, "other builtins still seeded:")
end)

test("seed returns the same table it was given", function()
  local sigs = {}
  assert_true(mpi.seed(sigs) == sigs, "identity:")
end)

_H.finish()
