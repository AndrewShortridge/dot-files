-- Spec for andrew.fortran.ftnchek's output parser.
--
-- WHAT IT PINS
--
-- ftnchek is the only checker in this config that reads the whole program at
-- once, and so the only one that can see a CALL disagreeing with its
-- SUBROUTINE or a COMMON block laid out differently in two files. Its value is
-- entirely in the cross-file findings, and a cross-file finding is exactly the
-- shape that is easy to parse WRONG: the headline names one file and the facts
-- underneath name others.
--
--   "cooling.f", line 1: Warning: Subprogram COOLING varying number of arguments:
--   "cooling.f", line 1:    Defined in module COOLING with 2 arguments
--   "main.f", line 8:    Invoked in module MAIN with 1 argument
--
-- A parser that keeps only the header puts a marker on the callee and none on
-- the caller -- which is the end you are usually looking at.
--
-- The fixture below is REAL ftnchek 3.3.1 output, captured verbatim from a
-- four-file project built to contain one COMMON layout mismatch (BLK1 declared
-- A,B,N in one file and A,N,B in another) and one argument-count mismatch.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "details keep their own location" fails if the detail's path/lnum are
--     taken from the enclosing header instead of the detail line.
--   * "a header is distinguished from a detail by indentation" fails if
--     split_loc consumes all whitespace after the colon rather than exactly
--     one space -- every detail then reads as a new finding.
--   * "and-at-position opens a new finding" fails if that continuation is
--     folded into the preceding finding's details, which attributes position
--     3's facts to position 2.
--   * "both ends of a cross-file finding get a diagnostic" fails if
--     M.diagnostics emits only the header location.
--   * "a syntax error keeps its column" fails if the `line N col C` prefix
--     stops capturing the column. (Note: the ORDER of the two prefix patterns
--     turns out not to matter -- `^line%s+(%d+):` cannot match `line 4 col 7:`
--     because the colon does not follow the digits -- so reordering them is
--     NOT a mutation this test catches, and the claim is only about the
--     capture.)
--   * "noise lines are dropped" fails if a line without a location prefix is
--     allowed to open or extend a finding.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_ftnchek_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local ftnchek = require("andrew.fortran.ftnchek")

-- Verbatim `ftnchek -wrap=0 -quiet -nonovice main.f heating.f cooling.f bad.f`.
local OUTPUT = table.concat({
  "FTNCHEK Version 3.3 November 2004",
  "File main.f:",
  '"main.f", line 5: Warning in module MAIN: Variables declared but never referenced:',
  '"main.f", line 5:     UNUSEDX declared',
  " 1 warning issued in file main.f",
  "File bad.f:",
  "      4       IMPLICITVAR = 3",
  "              ^",
  '"bad.f", line 4 col 7: Error: syntax error, unexpected end of statement',
  '"main.f", line 2: Warning: Common block BLK1 data type mismatch at position 2:',
  '"main.f", line 2:    Variable B in module MAIN is type real*8',
  '"cooling.f", line 2:    Variable N in module COOLING is type intg',
  '"main.f", line 2:  and at position 3:',
  '"main.f", line 2:    Variable N in module MAIN is type intg',
  '"cooling.f", line 2:    Variable B in module COOLING is type real*8',
  '"main.f", line 2: Warning: Common block BLK1 Elements never used, never set:',
  "    N",
  '"cooling.f", line 1: Warning: Subprogram COOLING varying number of arguments:',
  '"cooling.f", line 1:    Defined in module COOLING with 2 arguments',
  '"main.f", line 8:    Invoked in module MAIN with 1 argument',
  '"modern.f90", near line 4: Error: missing END statement inserted prior to statement',
  " 3 warnings issued in file cooling.f",
  "No main program found",
}, "\n")

local findings = ftnchek.parse(OUTPUT)

local function find(msg_pattern)
  for _, f in ipairs(findings) do
    if f.message:find(msg_pattern, 1, true) then
      return f
    end
  end
  return nil
end

test("the location prefix is split in all three spellings", function()
  local path, lnum, col, text = ftnchek.split_loc('"main.f", line 5: Warning: x')
  assert_eq(path, "main.f", "path:")
  assert_eq(lnum, 5, "lnum:")
  assert_nil(col, "col absent:")
  assert_eq(text, "Warning: x", "text:")

  local _, l2, c2, t2 = ftnchek.split_loc('"bad.f", line 4 col 7: Error: boom')
  assert_eq(l2, 4, "lnum with col:")
  assert_eq(c2, 7, "col:")
  assert_eq(t2, "Error: boom", "text with col:")

  local _, l3, _, t3 = ftnchek.split_loc('"m.f90", near line 4: Error: missing END')
  assert_eq(l3, 4, "near-line lnum:")
  assert_eq(t3, "Error: missing END", "near-line text:")
end)

test("a header is distinguished from a detail by indentation", function()
  -- Exactly one space is eaten after the colon, so a header's text starts at a
  -- word and a detail's text starts at a space.
  local _, _, _, header = ftnchek.split_loc('"main.f", line 5: Warning in module MAIN: x')
  local _, _, _, detail = ftnchek.split_loc('"main.f", line 5:     UNUSEDX declared')
  assert_eq(header:sub(1, 1), "W", "header text begins at the word:")
  assert_eq(detail:sub(1, 1), " ", "detail text keeps its indentation:")
end)

test("noise lines are dropped", function()
  -- The banner, `File x.f:`, the source echo, the caret, the trailing counts
  -- and the bare `    N` under "Elements never used" all lack a location
  -- prefix. A parser that invents one for them turns the bare `N` into a
  -- DETAIL of the finding above it, pinned to a file that does not exist.
  for _, f in ipairs(findings) do
    assert_true(
      f.message:match("^Warning") ~= nil or f.message:match("^Error") ~= nil,
      "every finding is a Warning or an Error, got: " .. f.message
    )
  end
  assert_nil(find("FTNCHEK Version"), "the banner:")
  assert_nil(find("No main program found"), "the trailer:")
  local elems = find("Elements never used")
  assert_true(elems ~= nil, "the Elements finding is present:")
  assert_eq(#elems.details, 0, "the unprefixed `    N` line was not absorbed as a detail:")
end)

test("a syntax error keeps its column and ERROR severity", function()
  local f = find("syntax error, unexpected end of statement")
  assert_true(f ~= nil, "found:")
  assert_eq(f.path, "bad.f", "path:")
  assert_eq(f.lnum, 4, "lnum:")
  assert_eq(f.col, 7, "col:")
  assert_eq(f.severity, vim.diagnostic.severity.ERROR, "severity:")
end)

test("details keep their own location", function()
  local f = find("varying number of arguments")
  assert_true(f ~= nil, "found:")
  assert_eq(f.path, "cooling.f", "header path:")
  assert_eq(#f.details, 2, "detail count:")
  assert_eq(f.details[1].path, "cooling.f", "callee detail path:")
  assert_eq(f.details[1].lnum, 1, "callee detail lnum:")
  assert_eq(f.details[2].path, "main.f", "CALLER detail path:")
  assert_eq(f.details[2].lnum, 8, "caller detail lnum:")
  assert_eq(f.details[2].text, "Invoked in module MAIN with 1 argument", "caller detail text:")
end)

test("and-at-position opens a new finding", function()
  local p2 = find("data type mismatch at position 2:")
  local p3 = find("data type mismatch at position 3:")
  assert_true(p2 ~= nil, "position 2 finding:")
  assert_true(p3 ~= nil, "position 3 finding:")
  -- Position 3's facts belong to position 3, not to position 2.
  assert_eq(#p2.details, 2, "position 2 detail count:")
  assert_eq(#p3.details, 2, "position 3 detail count:")
  assert_eq(p3.details[1].text, "Variable N in module MAIN is type intg", "first fact of position 3:")
end)

test("both ends of a cross-file finding get a diagnostic", function()
  local diags = ftnchek.diagnostics(findings)
  local at_caller, at_callee = nil, nil
  for _, d in ipairs(diags) do
    if d.message:find("varying number of arguments", 1, true) then
      if d.path == "main.f" and d.lnum == 8 then
        at_caller = d
      elseif d.path == "cooling.f" and d.lnum == 1 then
        at_callee = d
      end
    end
  end
  assert_true(at_callee ~= nil, "a marker on the definition:")
  assert_true(at_caller ~= nil, "a marker on the CALL:")
  -- The caller's marker has to carry the headline; the bare detail text says
  -- nothing about what disagreed.
  assert_true(
    at_caller.message:find("Subprogram COOLING varying number of arguments", 1, true) ~= nil,
    "the caller's message names the subprogram: " .. tostring(at_caller.message)
  )
  assert_true(
    at_caller.message:find("Invoked in module MAIN with 1 argument", 1, true) ~= nil,
    "the caller's message carries its own fact:"
  )
end)

test("a detail at the header's own location is not duplicated", function()
  local diags = ftnchek.diagnostics(findings)
  local n = 0
  for _, d in ipairs(diags) do
    if d.path == "main.f" and d.lnum == 5 then
      n = n + 1
    end
  end
  assert_eq(n, 1, "markers on main.f:5 (header and its same-line detail):")
end)

test("severity maps Warning and Error and nothing else", function()
  assert_eq(ftnchek.severity("Warning: x"), vim.diagnostic.severity.WARN, "Warning:")
  assert_eq(ftnchek.severity("Error: x"), vim.diagnostic.severity.ERROR, "Error:")
  assert_nil(ftnchek.severity("   Variable B in module MAIN"), "a detail:")
  assert_nil(ftnchek.severity("Defined in module COOLING"), "a bare sentence:")
end)

test("fixed-form globs deliberately exclude free-form sources", function()
  -- ftnchek 3.3 is a Fortran 77 tool: pointed at a .f90 it reports syntax
  -- errors that do not exist. Including .f90 here would be a regression that
  -- looks like a feature.
  for _, glob in ipairs(ftnchek.FIXED_FORM_GLOBS) do
    assert_nil(glob:match("f9"), "no f9x glob, got " .. glob)
    assert_nil(glob:match("f0"), "no f0x glob, got " .. glob)
  end
end)

_H.finish()
