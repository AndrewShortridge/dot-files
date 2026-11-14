-- Spec for andrew.fortran.openmp -- directive recognition and builtin
-- signature seeding.
--
-- WHAT IT PINS
--
-- OpenMP's failure mode is uniquely quiet. Without -fopenmp a compiler treats
-- `!$OMP` as an ordinary comment, so a malformed directive is not diagnosed,
-- the program compiles cleanly, and it runs on one thread. "It works, it is
-- just slow" is the symptom of a syntax error.
--
-- `is_directive` therefore has to recognise both spellings that carry that
-- risk. The obvious one is the `!$OMP` directive. The subtler one is the
-- single-character conditional-compilation sentinel `!$`, which turns the
-- REST OF THE LINE into live Fortran under -fopenmp and leaves it a comment
-- without -- so the same source is two different programs depending on a
-- flag, and the sentinel is easy to miss when reading.
--
-- Fixed-form source accepts `C$` and `*$` in column 1 as well, which this
-- project's Fortran 77 files would use. All three must be recognised.
--
-- The position rule is what stops it over-matching: the sentinel must be the
-- first non-blank text on the line. `x = 1 !$OMP parallel` is a trailing
-- comment and nothing more.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "a trailing sentinel is not a directive" fails if the `^%s*` anchor is
--     dropped -- the over-match that would treat ordinary comments as
--     directives.
--   * "fixed-form sentinels are recognised" fails if the character class is
--     narrowed to `!` alone, which silently excludes exactly the Fortran 77
--     files this config exists to serve.
--   * "a plain comment is not a directive" fails if the `%$` is dropped from
--     the pattern, which would make every comment in the file a directive.
--   * "a foreign `!$` sentinel is not a directive" fails if the token boundary
--     after the sentinel is dropped -- `!$acc` is OpenACC, and reading it as
--     OpenMP hands it the wrong standard's clause list.
--   * "seeding does not overwrite a project definition" fails if `seed` loses
--     its `if not sigs[lname]` guard.
--   * "the lock routines take exactly one argument" fails if a lock signature
--     gains or loses an argument -- omp_test_nest_lock returning an INTEGER
--     count while omp_test_lock returns a LOGICAL is a genuine asymmetry in
--     the standard and easy to "fix" wrongly.
--
-- The `doc_keys` / `best_key` tests that used to close this file are gone with
-- the functions: directive and clause documentation is reached through
-- `registry.directive(word)` now, by hover, by completion and by the
-- highlighter alike. `is_directive` -- the gate that keeps `private`, `do` and
-- `if` from being read as OpenMP anywhere else in the file -- is still this
-- module's, and is what the tests above hold down.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_openmp_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local omp = require("andrew.fortran.openmp")

-- ---------------------------------------------------------------------------
-- is_directive
-- ---------------------------------------------------------------------------

test("a free-form directive is recognised", function()
  assert_true(omp.is_directive("!$omp parallel do"), "lowercase:")
  assert_true(omp.is_directive("!$OMP PARALLEL DO"), "uppercase:")
  assert_true(omp.is_directive("      !$OMP END PARALLEL"), "indented:")
end)

test("fixed-form sentinels are recognised", function()
  -- The Fortran 77 files in this project would use these, and narrowing the
  -- character class to `!` would silently exclude them.
  assert_true(omp.is_directive("C$OMP PARALLEL"), "C sentinel:")
  assert_true(omp.is_directive("c$omp parallel"), "lowercase c:")
  assert_true(omp.is_directive("*$OMP PARALLEL"), "star sentinel:")
end)

test("the conditional-compilation sentinel is recognised", function()
  -- `!$ tid = omp_get_thread_num()` is live code under -fopenmp and a comment
  -- without it -- the same source is two programs.
  assert_true(omp.is_directive("!$ tid = omp_get_thread_num()"), "free form:")
  assert_true(omp.is_directive("C$    nthreads = 4"), "fixed form:")
end)

test("a plain comment is not a directive", function()
  assert_false(omp.is_directive("! this is a comment"), "bang:")
  assert_false(omp.is_directive("C     legacy comment"), "C column 1:")
  assert_false(omp.is_directive("* another legacy comment"), "star:")
end)

test("a trailing sentinel is not a directive", function()
  -- The sentinel must be the first non-blank text on the line.
  assert_false(omp.is_directive("x = 1 !$OMP parallel"), "after code:")
  assert_false(omp.is_directive("      call foo()   !$ y = 2"), "after a call:")
end)

test("ordinary code is not a directive", function()
  assert_false(omp.is_directive("      SUBROUTINE SHARE_EAM()"), "a subroutine header:")
  assert_false(omp.is_directive(""), "empty:")
  assert_false(omp.is_directive("   "), "blank:")
end)

test("a foreign `!$` sentinel is not a directive", function()
  -- `!$` is not a reserved prefix. OpenACC has its own clause list and its own
  -- machine model, and reading `!$acc` as OpenMP made hover, completion and the
  -- highlighter all answer from the wrong standard. The full truth table lives
  -- in tests/fortran_openacc_sentinel_spec.lua; these are the two spellings
  -- that appear in real code.
  assert_false(omp.is_directive("!$acc parallel loop"), "OpenACC:")
  assert_false(omp.is_directive("!$ACC DATA COPYIN(a)"), "uppercase OpenACC:")
  assert_false(omp.is_directive("!$dir ivdep"), "a vendor directive:")
end)

test("the sentinel kind distinguishes a directive from conditional code", function()
  -- Callers that need to know WHICH sentinel (completion, to decide between
  -- the directive world and ordinary code) ask for the kind; `is_directive`
  -- is the union of the two.
  assert_eq(omp.sentinel("!$OMP PARALLEL"), "directive", "directive:")
  assert_eq(omp.sentinel("!$ use omp_lib"), "conditional", "conditional:")
  assert_eq(omp.sentinel("! plain"), nil, "a comment:")
end)

test("junk input is not a directive", function()
  assert_false(omp.is_directive(nil), "nil:")
  assert_false(omp.is_directive(42), "number:")
end)

-- ---------------------------------------------------------------------------
-- Signatures and seeding
-- ---------------------------------------------------------------------------

test("the zero-argument queries take no arguments", function()
  for _, n in ipairs({
    "omp_get_thread_num", "omp_get_num_threads", "omp_get_max_threads",
    "omp_get_wtime", "omp_in_parallel", "omp_get_num_procs",
  }) do
    assert_eq(#omp.SIGNATURES[n], 0, n .. ":")
  end
end)

test("omp_set_num_threads takes the thread count", function()
  assert_eq(#omp.SIGNATURES.omp_set_num_threads, 1, "argument count:")
  assert_eq(omp.SIGNATURES.omp_set_num_threads[1], "num_threads", "name:")
end)

test("the lock routines take exactly one argument", function()
  -- Simple locks take svar, nestable locks take nvar; both are one argument.
  for _, n in ipairs({ "omp_init_lock", "omp_set_lock", "omp_unset_lock", "omp_test_lock", "omp_destroy_lock" }) do
    assert_eq(#omp.SIGNATURES[n], 1, n .. " argument count:")
    assert_eq(omp.SIGNATURES[n][1], "svar", n .. " argument name:")
  end
  for _, n in ipairs({ "omp_init_nest_lock", "omp_set_nest_lock", "omp_unset_nest_lock",
                       "omp_test_nest_lock", "omp_destroy_nest_lock" }) do
    assert_eq(#omp.SIGNATURES[n], 1, n .. " argument count:")
    assert_eq(omp.SIGNATURES[n][1], "nvar", n .. " argument name:")
  end
end)

test("the schedule routines take a kind and a chunk size", function()
  assert_eq(table.concat(omp.SIGNATURES.omp_set_schedule, ","), "kind,chunk_size", "set:")
  assert_eq(table.concat(omp.SIGNATURES.omp_get_schedule, ","), "kind,chunk_size", "get:")
end)

test("no OpenMP signature carries an ierror", function()
  -- OpenMP is not MPI: its runtime routines report through return values, and
  -- a trailing ierror copied over from the MPI table would be wrong.
  for name, args in pairs(omp.SIGNATURES) do
    for _, a in ipairs(args) do
      assert_true(a ~= "ierror", name .. " must not take ierror:")
    end
  end
end)

test("seeding fills a gap", function()
  local sigs = {}
  omp.seed(sigs)
  assert_true(sigs.omp_set_num_threads ~= nil, "seeded:")
  assert_eq(sigs.omp_set_num_threads.builtin, true, "marked builtin:")
end)

test("seeding does not overwrite a project definition", function()
  local sigs = { omp_get_wtime = { name = "omp_get_wtime", args = { "mine" }, path = "/proj/t.f90" } }
  omp.seed(sigs)
  assert_eq(#sigs.omp_get_wtime.args, 1, "project args kept:")
  assert_eq(sigs.omp_get_wtime.args[1], "mine", "first dummy:")
  assert_true(sigs.omp_get_thread_num ~= nil, "other builtins still seeded:")
end)

_H.finish()
