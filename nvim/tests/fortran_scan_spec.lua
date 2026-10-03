-- Spec for lua/andrew/fortran/scan.lua -- the Fortran source scanner behind the
-- symbol picker and the capitalization rule.
--
-- WHAT IT PINS
--
-- The scanner's whole reason to exist is that fortls answers documentSymbol
-- with DEFINITIONS only, so a symbol search never shows call sites. Getting
-- call sites right in Fortran means four things a naive `grep -w call` gets
-- wrong, and each has a test here:
--
--   1. Whitespace between `call` and the callee is arbitrary. Two spaces,
--      eight spaces and a tab are all one call statement.
--   2. `call` inside a comment or a string literal is not a call.
--   3. A `call &` continuation puts the callee on the NEXT line.
--   4. `Foo(x)` is a function call or an array index depending on nothing but
--      whether the project defines a procedure called Foo -- so the paren scan
--      must report candidates and let the caller filter, never guess.
--
-- Plus the case-insensitivity that makes all of the above work: masking
-- lowercases the line, so `CALL`, `Call` and `call` are one keyword, while the
-- reported NAME is sliced out of the raw line and keeps its source spelling.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * Test "mask preserves byte length" fails if mask() ever returns a string
--     of a different length -- which silently corrupts every reported column.
--   * "call with arbitrary whitespace" fails if ident_at stops skipping %s*.
--   * "comments and strings" fails if the ! / quote handling is dropped.
--   * "continuation" fails if the pending_call branch is removed.
--   * "source casing" fails if names are taken from the masked line (the
--     original bug: every name came back lowercased).
--   * "end statements are not definitions" fails if preceded_by_end goes.
--   * "type declaration is not a type definition" fails if the `type(x) :: y`
--     guard is dropped -- every declaration would become a fake symbol.
--   * "project scan" fails if the ripgrep passes or the continuation pass go.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_scan_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil, assert_match = _H.assert_nil, _H.assert_match

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local scan = require("andrew.fortran.scan")

-- Helpers -------------------------------------------------------------------

--- Find the single record naming `name` (case-insensitive) in a scan list.
local function pick(list, name)
  for _, rec in ipairs(list) do
    if rec.lname == name:lower() then
      return rec
    end
  end
  return nil
end

local function names(list)
  local out = {}
  for _, rec in ipairs(list) do
    out[#out + 1] = rec.name
  end
  table.sort(out)
  return out
end

-- ---------------------------------------------------------------------------

test("mask preserves byte length and blanks comments", function()
  local line = "  call Foo(x)   ! call Bar(y)"
  local masked = scan.mask(line)
  assert_eq(#masked, #line, "mask must be length-preserving:")
  assert_match(masked, "^  call foo%(x%)", "code half survives, lowercased:")
  assert_eq(masked:sub(17), string.rep(" ", #line - 16), "comment half is blanked:")
end)

test("mask blanks string literals including doubled-quote escapes", function()
  local line = [[  s = 'call A' // "it''s" // 'B']]
  local masked = scan.mask(line)
  assert_eq(#masked, #line)
  assert_nil(masked:find("call", 1, true), "no keyword may survive inside a literal:")
  assert_nil(masked:find("a", 1, true), "literal contents are blanked entirely:")
  assert_match(masked, "//", "operators outside the literals survive:")
end)

test("mask blanks fixed-form column-1 comments only when fixed", function()
  assert_match(scan.mask("c call Foo(x)", true), "^ +$", "fixed form:")
  assert_match(scan.mask("c call Foo(x)", false), "call", "free form keeps it:")
end)

test("mask blanks preprocessor lines", function()
  assert_match(scan.mask("#define CALL_ME call Foo(x)"), "^ +$")
end)

test("call with arbitrary whitespace: two spaces, eight spaces, one tab", function()
  local result = scan.scan_lines({
    "  call Alpha(x)",
    "  call        Beta(x)",
    "  call\tGamma(x)",
    "  CALL Delta(x)",
  })
  assert_deep_eq = _H.assert_deep_eq
  assert_deep_eq(names(result.calls), { "Alpha", "Beta", "Delta", "Gamma" })
  assert_eq(pick(result.calls, "beta").col, 15, "column points at the callee, not the keyword:")
  assert_eq(pick(result.calls, "gamma").col, 8)
end)

test("call inside a comment or a string is not a call", function()
  local result = scan.scan_lines({
    "  ! call Ghost(x)",
    "  write(*,*) 'call Phantom(x)'",
    "  call Real_One(x)",
  })
  assert_eq(#result.calls, 1, "only the genuine call:")
  assert_eq(result.calls[1].name, "Real_One")
end)

test("call continuation puts the callee on the following line", function()
  local result = scan.scan_lines({
    "    call &",
    "      Deferred(t)",
  })
  assert_eq(#result.calls, 1)
  assert_eq(result.calls[1].name, "Deferred")
  assert_eq(result.calls[1].lnum, 2, "reported at the callee's line:")
  assert_eq(result.calls[1].col, 7)
end)

test("call continuation tolerates a leading ampersand on the next line", function()
  local result = scan.scan_lines({ "  call  &", "    & Deferred(t)" })
  assert_eq(#result.calls, 1)
  assert_eq(result.calls[1].name, "Deferred")
end)

test("names keep their source casing, matching stays case-insensitive", function()
  local result = scan.scan_lines({ "  CALL MixedCase_Name(x)" })
  assert_eq(result.calls[1].name, "MixedCase_Name", "displayed name is the raw spelling:")
  assert_eq(result.calls[1].lname, "mixedcase_name", "matching key is lowercase:")
end)

test("definitions cover every program-unit keyword", function()
  local result = scan.scan_lines({
    "module physics",
    "program main",
    "subroutine Heating(t)",
    "real(8) function Energy(t) result(e)",
    "submodule (parent) child",
    "type :: State",
    "type, extends(base) :: Derived",
    "interface Generic",
  })
  local got = {}
  for _, d in ipairs(result.defs) do
    got[d.lname] = d.kind
  end
  assert_eq(got.physics, "module")
  assert_eq(got.main, "program")
  assert_eq(got.heating, "subroutine")
  assert_eq(got.energy, "function")
  assert_eq(got.child, "submodule")
  assert_eq(got.state, "type")
  assert_eq(got.derived, "type")
  assert_eq(got.generic, "interface")
end)

test("end statements are not definitions", function()
  local result = scan.scan_lines({
    "end subroutine Heating",
    "end function Energy",
    "end module physics",
    "endsubroutine Heating",
    "end type State",
    "end interface Generic",
  })
  assert_eq(#result.defs, 0, "nothing here defines anything:")
end)

test("module procedure does not define a module", function()
  local result = scan.scan_lines({ "  module procedure impl_one" })
  assert_eq(#result.defs, 0)
end)

test("type declaration is not a type definition", function()
  local result = scan.scan_lines({
    "  type(State), intent(inout) :: s",
    "  type(State) :: local",
  })
  assert_eq(#result.defs, 0, "declarations are not definitions:")
end)

test("paren scan reports every candidate and filters nothing", function()
  local result = scan.scan_lines({ "  s%t = Energy(s%t) + arr(3) + sqrt(x)" })
  local got = names(result.refs)
  table.sort(got)
  _H.assert_deep_eq(got, { "Energy", "arr", "sqrt" },
    "the scanner reports candidates; deciding which are calls is the caller's job:")
end)

test("paren scan allows whitespace before the parenthesis", function()
  local result = scan.scan_lines({ "  y = Energy (x)" })
  assert_eq(pick(result.refs, "energy").col, 7)
end)

test("identifiers tokenizes a line once, skipping literal exponents", function()
  local toks = scan.identifiers(scan.mask("  if (x1 == 1.0e5 .and. y2_z > 3d0) then"))
  local got = {}
  for _, t in ipairs(toks) do
    got[#got + 1] = t.lname .. "@" .. t.col
  end
  _H.assert_deep_eq(got, { "if@3", "x1@7", "and@20", "y2_z@25", "then@37" },
    "`e5` and `d0` are parts of numeric literals, not identifiers:")
end)

test("prev_nonspace skips whitespace to find the real preceding byte", function()
  assert_eq(scan.prev_nonspace("obj % count", 7), "%")
  assert_eq(scan.prev_nonspace("obj%count", 5), "%")
  assert_eq(scan.prev_nonspace("   count", 4), "", "start of line:")
end)

test("project_root terminates at a fixed point instead of hanging", function()
  -- vim.fs.dirname returns its argument unchanged one level below root; a
  -- `while path ~= '/'` loop hangs nvim outright for a file with no marker
  -- above it. This asserts the underlying fact AND that the walk returns.
  assert_eq(vim.fs.dirname("/tmp"), "/", "if this changes, revisit the guard:")
  local root = scan.project_root("/")
  assert_true(type(root) == "string", "the walk must return, not spin:")
end)

test("ref_pattern refuses to build an alternation from nothing", function()
  assert_nil(scan.ref_pattern({}), "no names means no pattern, not an empty alternation:")
  -- Case folding is the (?i) flag's job, not the alternation's; callers pass
  -- the lowercase lname anyway.
  assert_match(scan.ref_pattern({ "Heating", "Energy" }), "Energy|Heating",
    "names become a sorted alternation:")
  assert_match(scan.ref_pattern({ "Heating" }), "^%(%?i%)", "matching is case-insensitive:")
  assert_nil(scan.ref_pattern({ "not an ident" }), "non-identifiers never reach the regex:")
end)

test("parse_rg_line anchors on the first line-number field", function()
  local path, lnum, text = scan.parse_rg_line("code/a.f90:12:  s = f(x)  ! a:b:c")
  assert_eq(path, "code/a.f90")
  assert_eq(lnum, 12)
  assert_eq(text, "  s = f(x)  ! a:b:c", "colons in the source text are not separators:")
  assert_nil((scan.parse_rg_line("not an rg line")))
end)

-- ---------------------------------------------------------------------------
-- Project scan (drives the real ripgrep passes against a temp tree)
-- ---------------------------------------------------------------------------

test("project scan finds definitions, calls and continued calls across files", function()
  if vim.fn.executable("rg") ~= 1 then
    return -- ripgrep is the transport; nothing to assert without it
  end

  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/code", "p")
  vim.fn.writefile({ "" }, root .. "/.fortls")
  vim.fn.writefile({
    "module physics",
    "contains",
    "  subroutine Heating(t)",
    "    real(8), intent(inout) :: t",
    "  end subroutine Heating",
    "  real(8) function Energy(t) result(e)",
    "    e = t",
    "  end function Energy",
    "end module physics",
  }, root .. "/code/physics.f90")
  vim.fn.writefile({
    "subroutine Step(t)",
    "  real(8) :: t, arr(10)",
    "  ! call Heating(t)",
    "  call        Heating(t)",
    "  t = Energy(t) + arr(3)",
    "  call &",
    "    Heating(t)",
    "end subroutine Step",
  }, root .. "/code/solver.f90")

  local defs, calls
  scan.project_definitions(root, function(result)
    defs = result
  end)
  assert_true(vim.wait(10000, function() return defs ~= nil end), "definition scan timed out")

  local unique, seen = {}, {}
  for _, d in ipairs(defs) do
    if not seen[d.lname] then
      seen[d.lname] = true
      unique[#unique + 1] = d.lname
    end
  end
  table.sort(unique)
  _H.assert_deep_eq(unique, { "energy", "heating", "physics", "step" })

  scan.project_calls(root, unique, function(result)
    calls = result
  end)
  assert_true(vim.wait(10000, function() return calls ~= nil end), "call scan timed out")

  local by_pos = {}
  for _, c in ipairs(calls) do
    by_pos[vim.fn.fnamemodify(c.path, ":t") .. ":" .. c.lnum .. ":" .. c.kind] = c.name
  end
  assert_eq(by_pos["solver.f90:4:call"], "Heating", "eight spaces after `call`:")
  assert_eq(by_pos["solver.f90:5:ref"], "Energy", "a known name in paren position is a call:")
  assert_eq(by_pos["solver.f90:7:call"], "Heating", "the callee of a `call &` continuation:")
  assert_nil(by_pos["solver.f90:3:call"], "the commented-out call is not a call:")

  for _, c in ipairs(calls) do
    assert_true(c.lname ~= "arr", "arr(3) is an array index, not a call:")
  end

  vim.fn.delete(root, "rf")
end)

_H.finish()
