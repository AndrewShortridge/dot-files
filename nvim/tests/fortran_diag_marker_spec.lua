-- Spec for andrew.fortran.diag.is_location_marker -- the guard that keeps
-- gfortran's bare caret-marker lines out of the diagnostic list.
--
-- WHAT IT PINS
--
-- A gfortran diagnostic that names TWO source locations is rendered as two
-- lines under -fdiagnostics-plain-output:
--
--     Share-EAM.f90:14:29: Warning: (1)
--     Share-EAM.f90:11:29: Warning: Array reference at (1) out of bounds
--                                   (26 > 18) in loop beginning at (2) [-Wdo-subscript]
--
-- Every parser in linting.lua matches `file:line:col: severity: message`, so
-- the first line becomes a diagnostic whose entire message is "(1)" -- a
-- marker in the gutter attached to no statement and explaining nothing. Four
-- of them appeared on a single file the moment MPI includes started
-- resolving, which is how a wart that long predated the change became
-- visible.
--
-- The predicate has to be exact. A real compiler message never consists of
-- nothing but a parenthesised number, but a great many real messages CONTAIN
-- one -- the very message above does, twice -- so anything less than a fully
-- anchored, digits-only test silently discards genuine diagnostics, which is
-- strictly worse than the wart it set out to fix.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "a real message containing a marker is kept" fails if the pattern loses
--     either anchor -- this is the over-correction that would hide real bugs,
--     and it is the reason the test exists.
--   * "a bare marker is dropped" fails if the guard is removed entirely.
--   * "a non-numeric parenthesis is kept" fails if `%d` is loosened to `.` or
--     `%w`, which would swallow messages like "(1)" spelled with letters --
--     Fortran array constructors and edit descriptors produce such text.
--   * "junk input is kept" fails if the type check is dropped: parsers can
--     hand over a nil message when a pattern half-matches, and erroring there
--     would take down the whole lint run.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_diag_marker_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true, assert_false = _H.test, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local diag = require("andrew.fortran.diag")
local is_marker = diag.is_location_marker

test("a bare marker is dropped", function()
  -- Verbatim from gfortran on Share-EAM.f90.
  assert_true(is_marker("(1)"), "(1):")
  assert_true(is_marker("(2)"), "(2):")
end)

test("a multi-digit marker is dropped", function()
  assert_true(is_marker("(12)"), "(12):")
end)

test("a real message containing a marker is kept", function()
  -- The whole point. Both of these carry "(1)" inside real prose.
  assert_false(is_marker("Array reference at (1) out of bounds (26 > 18) in loop beginning at (2) [-Wdo-subscript]"),
    "do-subscript message:")
  assert_false(is_marker("Unused variable 'unusedx' declared at (1) [-Wunused-variable]"),
    "unused-variable message:")
  assert_false(is_marker("Nonconforming tab character at (1) [-Wtabs]"), "tabs message:")
end)

test("a marker with surrounding text is kept", function()
  assert_false(is_marker("at (1)"), "trailing marker:")
  assert_false(is_marker("(1) here"), "leading marker:")
  assert_false(is_marker(" (1)"), "leading space:")
  assert_false(is_marker("(1) "), "trailing space:")
end)

test("a non-numeric parenthesis is kept", function()
  assert_false(is_marker("(a)"), "letter:")
  assert_false(is_marker("()"), "empty:")
  assert_false(is_marker("(1a)"), "mixed:")
  assert_false(is_marker("(-1)"), "signed:")
end)

test("junk input is kept", function()
  -- A parser can hand over nil when a pattern half-matches; erroring here
  -- would abort the entire lint run rather than lose one diagnostic.
  assert_false(is_marker(nil), "nil:")
  assert_false(is_marker(42), "number:")
  assert_false(is_marker(""), "empty string:")
end)

_H.finish()
