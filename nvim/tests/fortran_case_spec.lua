-- Spec for lua/andrew/fortran/case.lua -- the "intrinsics and project
-- procedures are written in CAPITALS" house rule.
--
-- WHAT MAKES THIS HARD, and therefore what is pinned here:
--
-- Fortran spells a type specification and an intrinsic call identically.
-- `real(8) :: x` declares a variable; `y = real(i)` calls the REAL intrinsic.
-- Same six characters, same following parenthesis, opposite meanings. A rule
-- that uppercases both turns declarations into noise the moment it is enabled,
-- so the checker suppresses type-keyword intrinsics in declaration position --
-- and every one of those suppressions has a test.
--
-- The same ambiguity governs the other direction: `arr(3)` and `Energy(t)` are
-- the same syntax, so a name is only ever flagged when it is a known intrinsic
-- or a procedure the project actually defines. An unknown name is left alone.
--
-- The fix is byte-length-preserving by construction (uppercase of ASCII is the
-- same width), which is what lets edits be applied in any order without
-- recomputing columns. "fix is idempotent" pins that end to end.
--
-- LANGUAGE KEYWORDS are the rule's second half, and they carry their own
-- ambiguity: Fortran reserves nothing, so `integer :: if` is legal and every
-- keyword is also a possible variable name. Uppercasing a variable is
-- semantically free but stylistically wrong, so three positional guards
-- suppress the shapes a variable of that name gets written in -- right of a
-- `::`, after a `%`, and followed by a single `=`. Each has a test.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "type spec in declaration position" fails if is_type_spec_context goes --
--     every `real(8) :: x` in the project becomes a finding.
--   * "type spec as a function prefix" fails if only the `::` half is kept.
--   * "genuine intrinsic call IS flagged" fails if suppression is widened to
--     all occurrences of type-keyword intrinsics -- the over-correction.
--   * "unknown names are never flagged" fails if the known-set filter goes,
--     at which point every array index is a finding.
--   * "comments and strings" fails if scanning stops going through mask().
--   * "already-uppercase" fails if the `actual == actual:upper()` guard goes.
--   * "definitions and end statements" fails if the NAMED_UNIT_KEYWORDS pass
--     is dropped -- calls get capitalized and their definition does not.
--   * "fix is idempotent" fails if replacement stops preserving byte length.
--   * "all_calls" fails if the opt-in for external routines is dropped.
--   * "declaration list is variable names" fails if the `::` guard goes --
--     `real :: value, count, status` would capitalize the variables.
--   * "component reference" fails if the `%` guard goes.
--   * "followed by =" fails if the `=` guard goes, and also if an exception is
--     added back for `==` -- which would let `type` through in `type == 3`.
--   * "intent arguments" fails if the positional IN/OUT/INOUT rule goes, or if
--     those words are ever added to the flat keyword list.
--   * "classes" fails if vim.g.fortran_case_keywords stops selecting classes.
--   * "findings are in source order" fails if the sort in scan_lines goes.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_case_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil, assert_deep_eq = _H.assert_nil, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local case = require("andrew.fortran.case")
local intrinsics = require("andrew.fortran.intrinsics")

-- Helpers -------------------------------------------------------------------

local PROJECT_DEFS = {
  { lname = "heating", kind = "subroutine" },
  { lname = "energy", kind = "function" },
  { lname = "state", kind = "type" },
  { lname = "physics", kind = "module" },
}

-- The tests above the "Language keywords" divider exercise the PROCEDURE rule
-- in isolation, so they turn the keyword rule off. With it on, half of them
-- would also see `real`, `call`, `subroutine` and friends as keyword findings
-- -- correct behaviour, but a different rule, tested separately below.
local function opts(overrides)
  local o = {
    enabled = true,
    severity = vim.diagnostic.severity.WARN,
    intrinsics = true,
    defined = true,
    documented = false,
    all_calls = false,
    units = false,
    unit_names = {},
    keyword_set = {},
    dotted_set = {},
  }
  return vim.tbl_extend("force", o, overrides or {})
end

--- opts() with the keyword rule on, for the given classes (nil = all).
local function kw_opts(classes, overrides)
  local kw = require("andrew.fortran.keywords")
  return opts(vim.tbl_extend("force",
    { keyword_set = kw.set(classes), dotted_set = kw.dotted_set(classes) },
    overrides or {}))
end

--- opts() with unit names (module / type / program) on and keywords off, so
--- the unit rule is exercised alone.
local function unit_findings(lines, overrides)
  local o = opts(vim.tbl_extend("force", { units = true }, overrides or {}))
  o.unit_names = case.known_units(PROJECT_DEFS, o)
  return case.scan_lines(lines, case.known_names(PROJECT_DEFS, o), o)
end

local function kw_findings(lines, classes, overrides)
  local o = kw_opts(classes, overrides)
  return case.scan_lines(lines, case.known_names(PROJECT_DEFS, o), o)
end

local function findings(lines, overrides)
  local o = opts(overrides)
  return case.scan_lines(lines, case.known_names(PROJECT_DEFS, o), o)
end

local function summarize(list)
  local out = {}
  for _, f in ipairs(list) do
    out[#out + 1] = string.format("%d:%d %s->%s", f.lnum, f.col, f.name, f.upper)
  end
  return out
end

-- ---------------------------------------------------------------------------

test("known_names labels intrinsics and project procedures apart", function()
  local known = case.known_names(PROJECT_DEFS, opts())
  assert_eq(known.sqrt, "intrinsic")
  assert_eq(known.heating, "defined")
  assert_eq(known.energy, "defined")
  assert_nil(known.state, "a derived type is not a procedure:")
  assert_nil(known.physics, "nor is a module:")
  assert_nil(known.write, "write is a statement, not an intrinsic:")
  assert_nil(known.allocate, "allocate is a statement:")
  assert_true(known.allocated ~= nil, "allocated() however is an intrinsic:")
end)

test("known_names honours the per-source switches", function()
  assert_nil(case.known_names(PROJECT_DEFS, opts({ intrinsics = false })).sqrt)
  assert_nil(case.known_names(PROJECT_DEFS, opts({ defined = false })).heating)
end)

test("type spec in declaration position is not a call", function()
  assert_deep_eq(summarize(findings({
    "  real(8) :: t",
    "  character(len=*), intent(in) :: msg",
    "  type(State), intent(inout) :: s",
    "  integer(kind=int64) :: n",
    "  class(base), pointer :: p",
  })), {}, "declarations must produce nothing:")
end)

test("type spec as a function prefix is not a call", function()
  assert_deep_eq(summarize(findings({ "  real(8) function Energy(t) result(e)" })),
    { "1:20 Energy->ENERGY" },
    "only the procedure name, never the REAL prefix:")
end)

test("a genuine intrinsic call IS flagged even for type-keyword names", function()
  assert_deep_eq(summarize(findings({ "  y = real(i) + int(x) + char(65)" })),
    { "1:7 real->REAL", "1:17 int->INT", "1:26 char->CHAR" })
end)

test("unknown names are never flagged", function()
  assert_deep_eq(summarize(findings({
    "  y = arr(3) + myLocalThing(4)",
    "  call ExternalLib_Thing(x)",
  })), {}, "Fortran cannot distinguish these from array indexing:")
end)

test("all_calls opts in to CALL targets the project does not define", function()
  assert_deep_eq(summarize(findings({ "  call MPI_Init(ierr)" }, { all_calls = true })),
    { "1:8 MPI_Init->MPI_INIT" })
  assert_deep_eq(summarize(findings({ "  call MPI_Init(ierr)" })), {},
    "off by default -- external libraries have their own conventions:")
end)

test("call with arbitrary whitespace is flagged at the callee", function()
  assert_deep_eq(summarize(findings({
    "  call Heating(t)",
    "  call        Heating(t)",
    "  call\tHeating(t)",
  })), { "1:8 Heating->HEATING", "2:15 Heating->HEATING", "3:8 Heating->HEATING" })
end)

test("an argument-less call is flagged -- the CALL rule, not the paren rule", function()
  -- With parentheses present the paren scan would find these anyway, so this
  -- is the case that actually exercises `call <whitespace> NAME`.
  assert_deep_eq(summarize(findings({
    "  call Heating",
    "  call        Heating",
    "  call\tHeating",
  })), { "1:8 Heating->HEATING", "2:15 Heating->HEATING", "3:8 Heating->HEATING" })
end)

test("comments and string literals are never flagged", function()
  assert_deep_eq(summarize(findings({
    "  ! call Heating(t) and sqrt(x)",
    "  write(*,*) 'call Heating(t)'",
  })), {})
end)

test("already-uppercase names produce no finding", function()
  assert_deep_eq(summarize(findings({
    "  call HEATING(t)",
    "  y = SQRT(x)",
    "  y = MPI_INIT(x)",
  })), {})
end)

test("mixed case is flagged, including a single lowercase letter", function()
  assert_deep_eq(summarize(findings({ "  y = SQRt(x)" })), { "1:7 SQRt->SQRT" })
end)

test("definitions and end statements are flagged with their calls", function()
  assert_deep_eq(summarize(findings({
    "subroutine Heating(t)",
    "  call Heating(t)",
    "end subroutine Heating",
  })), { "1:12 Heating->HEATING", "2:8 Heating->HEATING", "3:16 Heating->HEATING" },
    "a half-capitalized procedure is worse than a lowercase one:")
end)

test("each name is reported once even when several rules match it", function()
  -- `subroutine Heating(` matches both the paren scan and the unit-keyword
  -- scan; the finding must not be duplicated.
  assert_eq(#findings({ "subroutine Heating(t)" }), 1)
end)

test("to_diagnostics converts to 0-based nvim ranges", function()
  local diags = case.to_diagnostics(findings({ "  call Heating(t)" }), vim.diagnostic.severity.WARN)
  assert_eq(#diags, 1)
  assert_eq(diags[1].lnum, 0, "0-based line:")
  assert_eq(diags[1].col, 7, "0-based column:")
  assert_eq(diags[1].end_col, 14, "range covers exactly the name:")
  assert_eq(diags[1].source, "fortran-case")
  assert_eq(diags[1].severity, vim.diagnostic.severity.WARN)
end)

test("fix rewrites only the names and is idempotent", function()
  local lines = {
    "subroutine Heating(t)",
    "  real(8) :: t, arr(10)",
    "  ! call Heating(t)",
    "  call        Heating(t)",
    "  t = Energy(t) + arr(3) + sqrt(t)",
    "  write(*,*) 'call Heating(t)'",
    "end subroutine Heating",
  }

  local o = opts()
  local known = case.known_names(PROJECT_DEFS, o)
  local function apply(src)
    local out = vim.deepcopy(src)
    for _, f in ipairs(case.scan_lines(out, known, o)) do
      local line = out[f.lnum]
      out[f.lnum] = line:sub(1, f.col - 1) .. f.upper .. line:sub(f.col + #f.name)
    end
    return out
  end

  local fixed = apply(lines)
  assert_deep_eq(fixed, {
    "subroutine HEATING(t)",
    "  real(8) :: t, arr(10)",
    "  ! call Heating(t)",
    "  call        HEATING(t)",
    "  t = ENERGY(t) + arr(3) + SQRT(t)",
    "  write(*,*) 'call Heating(t)'",
    "end subroutine HEATING",
  })

  for i, line in ipairs(fixed) do
    assert_eq(#line, #lines[i], "replacement is byte-length preserving on line " .. i .. ":")
  end
  assert_eq(#case.scan_lines(fixed, known, o), 0, "a second pass finds nothing:")
  assert_deep_eq(apply(fixed), fixed, "fix is idempotent:")
end)

test("is_type_spec_context is exercised directly at both shapes", function()
  local scan = require("andrew.fortran.scan")
  local decl = "  real(8), intent(in) :: t"
  assert_true(case.is_type_spec_context(scan.mask(decl), 3, "real"), "left of the `::`:")

  local prefix = "real(8) function Energy(t)"
  assert_true(case.is_type_spec_context(scan.mask(prefix), 1, "real"), "prefix of a function statement:")

  local call = "  y = real(i)"
  assert_true(not case.is_type_spec_context(scan.mask(call), 7, "real"), "a genuine call is not a type spec:")
end)

test("every ambiguous type keyword is guarded, and only the ambiguous ones", function()
  -- The suppression only matters for names that are BOTH a type keyword and an
  -- intrinsic procedure -- those are the ones the checker would otherwise flag
  -- inside a declaration. Each must appear in both sets.
  for _, name in ipairs({ "real", "logical", "len", "int", "char", "cmplx", "dble", "kind" }) do
    assert_true(intrinsics.type_spec[name], name .. " must be treated as a type keyword")
    assert_true(intrinsics.set[name], name .. " must also be a known intrinsic")
  end

  -- These are type keywords with no intrinsic of the same name. Listing them
  -- in type_spec is harmless (nothing ever looks them up) but listing them as
  -- INTRINSICS would be a bug: `integer :: n` would become a finding on any
  -- line without a `::`, e.g. inside an interface body.
  for _, name in ipairs({ "integer", "character", "double", "type", "class" }) do
    assert_true(intrinsics.type_spec[name], name .. " must be treated as a type keyword")
    assert_nil(intrinsics.set[name], name .. " is not an intrinsic procedure")
  end
end)

-- ---------------------------------------------------------------------------
-- Language keywords
-- ---------------------------------------------------------------------------

test("control-flow keywords are flagged", function()
  assert_deep_eq(summarize(kw_findings({
    "    if (x == 1) then",
    "      do i = 1, n",
    "        select case (i)",
    "        case default",
    "        end select",
    "      end do",
    "    end if",
  }, { "control" })), {
    "1:5 if->IF", "1:17 then->THEN",
    "2:7 do->DO",
    "3:9 select->SELECT", "3:16 case->CASE",
    "4:9 case->CASE", "4:14 default->DEFAULT",
    "5:9 end->END", "5:13 select->SELECT",
    "6:7 end->END", "6:11 do->DO",
    "7:5 end->END", "7:9 if->IF",
  })
end)

test("a declaration list is variable names, not keywords", function()
  -- `value`, `count` and `status` are all keyword-shaped in some dialect or
  -- other; right of the `::` they are names being declared.
  assert_deep_eq(summarize(kw_findings({
    "  real(8), intent(in) :: value, count, status, if",
  })), {
    "1:3 real->REAL", "1:12 intent->INTENT", "1:19 in->IN",
  })
end)

test("a component reference after % is not a keyword", function()
  assert_deep_eq(summarize(kw_findings({ "    y = obj%count + obj % end" }, { "control" })), {})
end)

test("a keyword-shaped word followed by = is a variable", function()
  -- `format`, `result` and `type` are all in the keyword set AND all plausible
  -- variable names. Being followed by `=` settles which one it is, in every
  -- form: assignment, keyword argument, and comparison.
  assert_deep_eq(summarize(kw_findings({
    "    format = '(A)'",
    "    result = 5",
    "    if (type == 3) then",
    "    call Foo(status=1, result=r)",
  })), { "3:5 if->IF", "3:20 then->THEN", "4:5 call->CALL" })
end)

test("I/O specifiers are left alone", function()
  assert_deep_eq(summarize(kw_findings({
    "    open(unit=10, file=path, iostat=ios)",
    "    p => target",
  }, { "io", "declaration" })), { "1:5 open->OPEN" },
    "only the statement; every specifier is written `name=`:")
end)

test("intent arguments are keywords only inside intent(...)", function()
  assert_deep_eq(summarize(kw_findings({ "  integer, intent(inout) :: n" })), {
    "1:3 integer->INTEGER", "1:12 intent->INTENT", "1:19 inout->INOUT",
  })
  -- The same words as ordinary variables, which is what they usually are.
  assert_deep_eq(summarize(kw_findings({ "    total = in + out" })), {},
    "IN and OUT are not reserved:")
end)

test("keyword classes are selected independently", function()
  local lines = { "  subroutine Step(s)", "    if (x) call Heating(s)", "    write(*,*) s" }

  local control = summarize(kw_findings(lines, { "control" }))
  assert_true(vim.tbl_contains(control, "2:5 if->IF"), "control is on")
  assert_true(vim.tbl_contains(control, "2:12 call->CALL"), "call is control")
  assert_true(not vim.tbl_contains(control, "1:3 subroutine->SUBROUTINE"), "unit class is off")
  assert_true(not vim.tbl_contains(control, "3:5 write->WRITE"), "io class is off")

  local io_only = summarize(kw_findings(lines, { "io" }))
  assert_true(vim.tbl_contains(io_only, "3:5 write->WRITE"))
  assert_true(not vim.tbl_contains(io_only, "2:5 if->IF"))

  assert_deep_eq(summarize(kw_findings(lines, {})), summarize(findings(lines)),
    "no classes selected is the same as the keyword rule being off:")
end)

test("keyword_set reads vim.g.fortran_case_keywords", function()
  local saved = vim.g.fortran_case_keywords

  vim.g.fortran_case_keywords = false
  assert_deep_eq(case.keyword_set(), {}, "false disables the rule:")

  vim.g.fortran_case_keywords = { "control" }
  local only_control = case.keyword_set()
  assert_eq(only_control["if"], "control")
  assert_nil(only_control.write, "io class not requested:")

  vim.g.fortran_case_keywords = nil
  local all = case.keyword_set()
  assert_eq(all["if"], "control")
  assert_eq(all.write, "io")
  assert_eq(all.subroutine, "unit")
  assert_eq(all.allocate, "memory")

  vim.g.fortran_case_keywords = saved
end)

test("keyword-shaped words that are too common as variables are absent", function()
  local all = require("andrew.fortran.keywords").set(nil)
  for _, name in ipairs({ "value", "data", "target", "in", "out", "inout",
                          "len", "kind", "unit", "file", "status", "iostat", "error" }) do
    assert_nil(all[name], name .. " must not be in the flat keyword set")
  end
end)

test("the keyword and procedure rules do not double-report a name", function()
  -- `real` is a declaration keyword AND an intrinsic; `Heating` is reported by
  -- the call rule AND the paren rule. Each position yields exactly one finding.
  assert_deep_eq(summarize(kw_findings({ "  y = real(i)" })), { "1:7 real->REAL" })
  assert_eq(#kw_findings({ "  call Heating(t)" }), 2, "the CALL keyword and the callee:")
end)

test("findings are in source order within a line", function()
  assert_deep_eq(summarize(kw_findings({ "    call Heating(t)", "    write(*,*) trim(s)" })), {
    "1:5 call->CALL", "1:10 Heating->HEATING",
    "2:5 write->WRITE", "2:16 trim->TRIM",
  })
end)

test("keywords in comments and strings are still untouched", function()
  assert_deep_eq(summarize(kw_findings({
    "    ! if (x) then",
    "    s = 'end do'",
  })), {})
end)

-- ---------------------------------------------------------------------------
-- Module, submodule, program and derived-type NAMES
-- ---------------------------------------------------------------------------

test("unit names are opt-outable and off does not reach them", function()
  local off = opts()
  assert_deep_eq(case.known_units(PROJECT_DEFS, off), {}, "units = false yields nothing:")
  local on = opts({ units = true })
  assert_eq(case.known_units(PROJECT_DEFS, on).physics, "module")
  assert_eq(case.known_units(PROJECT_DEFS, on).state, "type")
  assert_nil(case.known_units(PROJECT_DEFS, on).heating, "a subroutine is not a unit:")
end)

test("a unit name is found next to every keyword that can introduce it", function()
  assert_deep_eq(summarize(unit_findings({
    "module physics",
    "end module physics",
    "  use physics",
    "  use physics, only: x",
    "  type :: State",
    "  end type State",
    "  type(State) :: s",
    "  class(State), pointer :: p",
    "  type, extends(State) :: Big",
  })), {
    "1:8 physics->PHYSICS",
    "2:12 physics->PHYSICS",
    "3:7 physics->PHYSICS",
    "4:7 physics->PHYSICS",
    "5:11 State->STATE",
    "6:12 State->STATE",
    "7:8 State->STATE",
    "8:9 State->STATE",
    "9:17 State->STATE",
  })
end)

test("a structure constructor is caught by the invocation scan", function()
  assert_deep_eq(summarize(unit_findings({ "    s = State(1.0d0)" })), { "1:9 State->STATE" })
end)

test("a variable that merely resembles a unit name is left alone", function()
  assert_deep_eq(summarize(unit_findings({
    "  real :: state_of_charge, physics_mode",
    "  x = state_of_charge",
  })), {}, "the unit rule only fires next to a unit keyword:")
end)

-- ---------------------------------------------------------------------------
-- Import and access lists
-- ---------------------------------------------------------------------------

test("only: and access statements name procedures, declarations do not", function()
  assert_deep_eq(summarize(findings({
    "  use physics, only: Heating, Energy",
    "  public :: Heating",
    "  intrinsic :: sqrt",
  })), {
    "1:22 Heating->HEATING", "1:31 Energy->ENERGY",
    "2:13 Heating->HEATING",
    "3:16 sqrt->SQRT",
  })

  -- The same syntax in a type declaration declares variables of those names.
  assert_deep_eq(summarize(findings({ "  real :: energy, heating" })), {},
    "`real :: energy` declares a variable, it does not name the function:")
end)

-- ---------------------------------------------------------------------------
-- Dotted logical operators and literals
-- ---------------------------------------------------------------------------

test("dotted operators and literals are capitalized between their dots", function()
  assert_deep_eq(summarize(kw_findings({
    "    if (a .and. .not. b .or. c .eqv. d) then",
  }, { "operator" })), {
    "1:12 and->AND", "1:18 not->NOT", "1:26 or->OR", "1:33 eqv->EQV",
  }, "only the letters -- the dots keep the replacement the same width:")
end)

test("old-style relational operators are covered", function()
  assert_deep_eq(summarize(kw_findings({ "    if (x .gt. 1.0 .and. y .le. 2) then" }, { "operator" })), {
    "1:12 gt->GT", "1:21 and->AND", "1:29 le->LE",
  }, "a decimal literal next to an operator does not confuse the dot scan:")
end)

test("logical literals are checked even inside an initializer", function()
  -- `logical :: flag = .true.` puts the literal right of the `::`. The
  -- variable-position guards must NOT apply to dotted words -- a `.true.` is
  -- never a variable name.
  assert_deep_eq(summarize(kw_findings({ "  logical :: flag = .false." }, { "operator" })), {
    "1:22 false->FALSE",
  })
end)

test("a dotted word that is not an operator is left alone", function()
  assert_deep_eq(summarize(kw_findings({ "    if (a .myop. b) then" }, { "operator" })), {},
    "user-defined operators are not the config's business:")
end)

test("operators in comments and strings are untouched", function()
  assert_deep_eq(summarize(kw_findings({
    "    ! a .and. b",
    "    s = '.true.'",
  }, { "operator" })), {})
end)

test("the operator class is dotted, so it never enters the identifier set", function()
  local kw = require("andrew.fortran.keywords")
  assert_nil(kw.set(nil)["and"], "`and` is a legal variable name; only `.and.` is an operator:")
  assert_nil(kw.set(nil)["true"])
  assert_eq(kw.dotted_set(nil)["and"], "operator")
  assert_eq(kw.dotted_set(nil)["true"], "logical constant")
  assert_nil(kw.dotted_set({ "control" })["and"], "classes select the dotted half too:")
end)

_H.finish()
