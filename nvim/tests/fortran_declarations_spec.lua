-- Spec for the declaration scanner in lua/andrew/fortran/scan.lua -- the half
-- of the Fortran symbol picker that finds VARIABLES, and for the one-name
-- reference search behind `gr` and :FortranReferences.
--
-- WHY THIS EXISTS
--
-- The symbol pickers used to list procedures and nothing else, so searching a
-- workspace for a variable returned an empty picker. In the F77-descended code
-- this config targets, a variable is often declared in the one way no other
-- tool looks at: `dift` appears in a COMMON block, in a `.h` include, split
-- across four continuation lines, and gets its type from IMPLICIT rather than
-- from any declaration statement. fortls has never heard of it.
--
-- Getting that right means five things a `grep -w` cannot do, and each has a
-- test here:
--
--   1. A declaration's entity list is comma-separated, but commas also appear
--      inside array bounds -- `difx(0:n), dify(0:n)` is two entities, not
--      four -- so the list must be walked with a paren depth counter.
--   2. Only the identifier that OPENS an entity is a declaration. In
--      `n = size(arr)` the declared name is `n`; `size` and `arr` are not.
--   3. A statement broken by `&` continues onto lines that, read alone, are
--      indistinguishable from any other text. Continuations must be followed.
--   4. `REAL(8) FUNCTION Energy(t)` opens with a type keyword and declares no
--      variable at all -- but it does declare a dummy argument.
--   5. `TYPE(State) :: s` declares a variable, `TYPE :: State` defines a type
--      and `TYPE IS (t)` declares nothing. All three open with `type`.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "array bounds do not split entities" fails if walk_entities stops
--     counting paren depth -- every array bound becomes a phantom variable.
--   * "an initialiser declares nothing" fails if walk_entities stops closing
--     the entity when it takes its name -- `size` is then declared too.
--   * "COMMON block continued across lines" and "the rg-backed project scan
--     agrees with a whole-file scan" both fail if the continuation state is
--     dropped -- the second is the one that catches it in the ASYNC path,
--     where rg never sees the continuation lines at all.
--   * "a line already consumed as a continuation is not rescanned" fails if
--     project_declarations loses its consumed set (names double up).
--   * "a type-prefixed function header declares no variable" fails if the
--     `function` guard in scan_declarations goes -- `function` and `energy`
--     both become variables.
--   * "TYPE IS / CLASS IS declare nothing" fails if consume_type_spec stops
--     requiring an immediate paren -- `is` becomes a variable.
--   * "references skip comments and strings" fails if project_references
--     stops masking.
--   * "references are classified" fails if the column-matched kind lookup
--     goes -- the declaration is no longer findable among the uses.
--   * "include files are scanned" fails if all_globs drops the include globs,
--     which is the entire reason the original report found nothing.
--   * "variable references are the declared names and nothing else" fails if
--     scan_known_names stops filtering by the declared set -- every keyword
--     and every intrinsic becomes a reference.
--   * "nesting depth counts program units, not constructs" fails if the
--     `end if` / `end do` exclusion goes: the document picker then indents
--     every loop body one level deeper and never comes back.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_declarations_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil, assert_deep_eq = _H.assert_nil, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local scan = require("andrew.fortran.scan")

-- Helpers -------------------------------------------------------------------

--- Declared names on a block of source, as "kind:Name" in source order.
local function decls(lines)
  local out = {}
  for _, d in ipairs(scan.scan_lines(lines).decls) do
    out[#out + 1] = d.kind .. ":" .. d.name
  end
  return out
end

local function find(lines, name)
  for _, d in ipairs(scan.scan_lines(lines).decls) do
    if d.lname == name:lower() then
      return d
    end
  end
  return nil
end

local function tmp_project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/code", "p")
  return root
end

-- Entity lists --------------------------------------------------------------

test("a type declaration declares every name in its entity list", function()
  assert_deep_eq(decls({ "      LOGICAL IMMOV,IBULK,ISurf" }),
    { "var:IMMOV", "var:IBULK", "var:ISurf" })
end)

test("array bounds do not split entities", function()
  -- Three commas, two variables. Without a depth counter the comma inside
  -- `grid(nx,ny)` opens a new entity and `ny` becomes a phantom declaration.
  assert_deep_eq(decls({ "      REAL*8 grid(nx,ny),edge(0:mnlc2-1)" }),
    { "var:grid", "var:edge" })
end)

test("an initialiser declares nothing", function()
  -- One name per entity: taking `n` closes the entity, so `size` -- which sits
  -- at depth 0, right where a declared name would -- is not one.
  assert_deep_eq(decls({ "      integer :: n = size(arr), m" }), { "var:n", "var:m" })
end)

test("the legacy type spellings all parse", function()
  assert_deep_eq(decls({
    "      REAL*8 DEPTHZ(nlcz)",
    "      Real *8 rCenter1(3)",
    "      CHARACTER (LEN=17) nFile",
    "      character*(*) label",
    "      DOUBLE PRECISION acc",
    "      INTEGER status(MPI_STATUS_SIZE)",
  }), {
    "var:DEPTHZ", "var:rCenter1", "var:nFile", "var:label", "var:acc", "var:status",
  })
end)

test("modern declarations with attributes parse", function()
  assert_deep_eq(decls({
    "    real(8), intent(inout) :: t",
    "    integer, parameter :: n = 10",
    "    type(State), allocatable :: s(:)",
  }), { "var:t", "var:n", "var:s" })
end)

test("PARAMETER and DIMENSION statements declare names", function()
  assert_deep_eq(decls({
    "      PARAMETER(ITTM      =  9)",
    "      PARAMETER (A=1.0D0, B=2)",
    "      DIMENSION a(10), b(2,3)",
  }), { "var:ITTM", "var:A", "var:B", "var:a", "var:b" })
end)

test("declarations inside comments and strings are not declarations", function()
  assert_deep_eq(decls({
    "      ! REAL*8 ghost",
    "      write(*,*) 'INTEGER phantom'",
  }), {})
end)

-- The three faces of `type` -------------------------------------------------

test("TYPE(x) :: y declares y, TYPE :: X does not declare", function()
  assert_deep_eq(decls({ "    type(State) :: s" }), { "var:s" })
  -- `type :: State` DEFINES a derived type; scan_definitions owns it, and it
  -- must not also appear as a variable.
  assert_deep_eq(decls({ "  type :: State" }), {})
  assert_deep_eq(decls({ "  type, extends(Base) :: Derived" }), {})
end)

test("TYPE IS / CLASS IS declare nothing", function()
  assert_deep_eq(decls({
    "      type is (real)",
    "      class is (State)",
  }), {})
end)

test("a bare DOUBLE is not a declaration", function()
  assert_deep_eq(decls({ "      double = 2" }), {})
end)

-- Procedure headers ---------------------------------------------------------

test("dummy arguments are declared, and the header itself is not a variable", function()
  assert_deep_eq(decls({ "      SUBROUTINE Diffuse(nnode, dt)" }),
    { "arg:nnode", "arg:dt" })
end)

test("a type-prefixed function header declares no variable", function()
  -- Opens with `real`, so a naive type-declaration parser reads `function` and
  -- `Energy` as declared names.
  assert_deep_eq(decls({ "  real(8) function Energy(t) result(e)" }), { "arg:t" })
end)

test("END statements declare nothing", function()
  assert_deep_eq(decls({
    "      end subroutine Diffuse",
    "      end function Energy",
  }), {})
end)

-- COMMON blocks -------------------------------------------------------------

test("a COMMON statement declares the block name and every member", function()
  assert_deep_eq(decls({ "      COMMON/DIFFST/ dift,difx(0:n)" }),
    { "common:DIFFST", "var:dift", "var:difx" })
end)

test("one COMMON statement may hold several blocks", function()
  assert_deep_eq(decls({ "      COMMON /A/ x, y /B/ z" }),
    { "common:A", "var:x", "var:y", "common:B", "var:z" })
end)

test("COMMON block continued across lines", function()
  local lines = {
    "      COMMON/XYZDEP/ XED(0:n),YED(0:n),ZED(0:n), &",
    "      Xsh(0:n),Ysh(0:n),Zsh(0:n)",
  }
  assert_deep_eq(decls(lines), {
    "common:XYZDEP", "var:XED", "var:YED", "var:ZED", "var:Xsh", "var:Ysh", "var:Zsh",
  })
  local xsh = find(lines, "Xsh")
  assert_eq(xsh.lnum, 2, "a continued name keeps its own line number:")
  assert_eq(xsh.col, 7, "and its own column:")
end)

test("a continuation with a leading ampersand parses", function()
  assert_deep_eq(decls({
    "      integer :: alpha, &",
    "     &          beta",
  }), { "var:alpha", "var:beta" })
end)

test("names keep their source casing", function()
  local d = find({ "      COMMON/DIFFST/ MixedCase_Name" }, "mixedcase_name")
  assert_eq(d.name, "MixedCase_Name")
  assert_eq(d.kind, "var")
end)

-- The ripgrep-backed project pass -------------------------------------------

test("the rg-backed project scan agrees with a whole-file scan", function()
  local root = tmp_project()
  -- Deliberately pathological: `real` is a legal Fortran variable name, so the
  -- second line of the first COMMON block matches the declaration pattern on
  -- its own and would be rescanned as a fresh statement without the consumed
  -- set. The second COMMON must still be scanned -- consuming too much is the
  -- opposite failure.
  local source = {
    "      COMMON /A/ alpha, &",
    "      real, beta(0:n)",
    "      COMMON /B/ gamma",
    "      REAL*8 delta(3), epsilon",
    "      SUBROUTINE Solve(nn, &",
    "                       dt)",
  }
  vim.fn.writefile(source, root .. "/code/decl.f90")

  local want = {}
  for _, d in ipairs(scan.scan_lines(source).decls) do
    want[#want + 1] = ("%d:%d:%s:%s"):format(d.lnum, d.col, d.kind, d.name)
  end
  table.sort(want)

  local got
  scan.project_declarations(root, function(result)
    got = result
  end)
  assert_true(vim.wait(10000, function() return got ~= nil end), "declaration scan timed out")

  local have = {}
  for _, d in ipairs(got) do
    have[#have + 1] = ("%d:%d:%s:%s"):format(d.lnum, d.col, d.kind, d.name)
  end
  table.sort(have)

  assert_deep_eq(have, want, "the async path must see exactly what a whole-file scan sees:")
  vim.fn.delete(root, "rf")
end)

test("a line already consumed as a continuation is not rescanned", function()
  local root = tmp_project()
  vim.fn.writefile({
    "      COMMON /A/ alpha, &",
    "      real, beta",
  }, root .. "/code/dup.f90")

  local got
  scan.project_declarations(root, function(result)
    got = result
  end)
  assert_true(vim.wait(10000, function() return got ~= nil end), "declaration scan timed out")

  local seen = {}
  for _, d in ipairs(got) do
    local key = ("%d:%d:%s"):format(d.lnum, d.col, d.name)
    assert_nil(seen[key], "duplicate declaration " .. key .. ":")
    seen[key] = true
  end
  vim.fn.delete(root, "rf")
end)

test("include files are scanned", function()
  local root = tmp_project()
  -- The original report: the variable lives only in a `.h` include, which the
  -- source-file globs never looked at.
  vim.fn.writefile({ "      COMMON/DIFFST/ dift,difx(0:n)" }, root .. "/code/commonTTM.h")
  vim.fn.writefile({ "      INCLUDE 'commonTTM.h'" }, root .. "/code/main.f90")

  local got
  scan.project_declarations(root, function(result)
    got = result
  end)
  assert_true(vim.wait(10000, function() return got ~= nil end), "declaration scan timed out")

  local found
  for _, d in ipairs(got) do
    if d.lname == "dift" then
      found = d
    end
  end
  assert_true(found ~= nil, "dift is declared in the include file:")
  assert_true(found.path:match("%.h$") ~= nil, "and is reported from it:")
  vim.fn.delete(root, "rf")
end)

-- Variable references and nesting --------------------------------------------

test("variable references are the declared names and nothing else", function()
  local lines = {
    "      SUBROUTINE Step(dt)",
    "      REAL*8 dift",
    "      IF (dift .GT. dt) dift = dt / 2.0d0",
    "      END SUBROUTINE Step",
  }
  local r = scan.scan_lines(lines)
  local known = {}
  for _, d in ipairs(r.decls) do
    known[d.lname] = true
  end
  local refs = scan.variable_refs(r.masked, lines, known)

  local at = {}
  for _, ref in ipairs(refs) do
    at[ref.lnum .. ":" .. ref.col] = ref.name
    assert_eq(ref.kind, "varref")
  end
  assert_eq(at["3:11"], "dift", "the test:")
  assert_eq(at["3:21"], "dt", "the other operand:")
  assert_eq(at["3:25"], "dift", "the assignment target:")
  assert_eq(at["3:32"], "dt", "and the right-hand side:")
  -- `IF`, `GT` and the literal are not declared, so they are not references;
  -- the declaration and the header ARE occurrences of declared names, and the
  -- picker's precedence -- not this scan -- decides which row wins.
  assert_nil(at["3:7"], "IF is not a declared name:")
  assert_nil(at["3:17"], "GT is not a declared name:")
  assert_eq(#refs, 6, "two on the declaring lines, four on line 3:")
end)

test("nesting depth counts program units, not constructs", function()
  local lines = {
    "      module physics",          -- 1  depth 0
    "      contains",                -- 2  depth 1
    "        subroutine Step(t)",    -- 3  depth 1
    "          integer :: i",        -- 4  depth 2
    "          do i = 1, 10",        -- 5  depth 2
    "            if (i > 2) then",   -- 6  depth 2
    "              t = t + 1",       -- 7  depth 2
    "            end if",            -- 8  depth 2
    "          end do",              -- 9  depth 2
    "        end subroutine Step",   -- 10 depth 1
    "      end module physics",      -- 11 depth 0
  }
  local r = scan.scan_lines(lines)
  assert_deep_eq(scan.nesting_depths(r.masked, r.defs),
    { 0, 1, 1, 2, 2, 2, 2, 2, 2, 1, 0 })
end)

test("a bare END closes a unit", function()
  local lines = {
    "      SUBROUTINE Step()",  -- 1  depth 0
    "      REAL*8 x",           -- 2  depth 1
    "      END",                -- 3  depth 0
    "      SUBROUTINE Next()",  -- 4  depth 0
  }
  local r = scan.scan_lines(lines)
  assert_deep_eq(scan.nesting_depths(r.masked, r.defs), { 0, 1, 0, 0 })
end)

-- One-name reference search -------------------------------------------------

test("references are found, classified, and skip comments and strings", function()
  local root = tmp_project()
  vim.fn.writefile({ "      COMMON/DIFFST/ dift" }, root .. "/code/common.h")
  vim.fn.writefile({
    "      SUBROUTINE Step()",           -- 1
    "      INCLUDE 'common.h'",          -- 2
    "      dift = 1.0d0",                -- 3
    "!     dift = 2.0d0",                -- 4  comment only
    "      write(*,*) 'dift'",           -- 5  string only
    "      dift = dift/4.0d0",           -- 6  twice on one line
    "      END SUBROUTINE Step",         -- 7
  }, root .. "/code/step.f90")

  local refs
  scan.project_references(root, "dift", function(result)
    refs = result
  end)
  assert_true(vim.wait(10000, function() return refs ~= nil end), "reference scan timed out")

  local at = {}
  for _, r in ipairs(refs) do
    at[vim.fn.fnamemodify(r.path, ":t") .. ":" .. r.lnum .. ":" .. r.col] = r.kind
  end

  assert_eq(at["common.h:1:22"], "var", "the COMMON declaration is labelled, not buried:")
  assert_eq(at["step.f90:3:7"], "varref", "an ordinary use:")
  assert_nil(at["step.f90:4:7"], "a comment is not a reference:")
  assert_nil(at["step.f90:5:19"], "a string literal is not a reference:")
  assert_eq(at["step.f90:6:7"], "varref", "first of two on one line:")
  assert_eq(at["step.f90:6:14"], "varref", "second of two on one line:")
  assert_eq(#refs, 4, "and nothing else:")

  vim.fn.delete(root, "rf")
end)

test("a call statement is labelled among the references", function()
  local root = tmp_project()
  vim.fn.writefile({
    "      SUBROUTINE Heating(t)",
    "      END SUBROUTINE Heating",
    "      SUBROUTINE Step()",
    "      CALL        Heating(t)",
    "      END SUBROUTINE Step",
  }, root .. "/code/p.f90")

  local refs
  scan.project_references(root, "Heating", function(result)
    refs = result
  end)
  assert_true(vim.wait(10000, function() return refs ~= nil end), "reference scan timed out")

  local at = {}
  for _, r in ipairs(refs) do
    at[r.lnum .. ":" .. r.col] = r.kind
  end
  assert_eq(at["1:18"], "subroutine", "the definition:")
  assert_eq(at["4:19"], "call", "the call site, whatever the whitespace:")
  vim.fn.delete(root, "rf")
end)

test("a non-identifier is refused rather than injected into the regex", function()
  local refs
  scan.project_references(vim.fn.tempname(), "a|b", function(result)
    refs = result
  end)
  assert_true(vim.wait(5000, function() return refs ~= nil end), "call did not return")
  assert_deep_eq(refs, {})
end)

_H.finish()
