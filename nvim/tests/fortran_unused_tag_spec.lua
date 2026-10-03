-- Spec for andrew.fortran.unused -- tagging gfortran's "declared but never
-- referenced" warnings so they render as DiagnosticUnnecessary.
--
-- WHAT IT PINS
--
-- Two things that both look like "it works" from the outside while doing
-- nothing at all.
--
-- FIRST, THE FIELD NAME. An LSP server reports this with `tags = { 1 }`
-- (DiagnosticTag.Unnecessary). That spelling is understood by exactly one
-- thing in Neovim -- vim/lsp/diagnostic.lua's tags_lsp_to_vim, which converts
-- it to `_tags` on the way in from a server. nvim-lint calls
-- vim.diagnostic.set directly and never passes through that code, so `tags` on
-- a linter diagnostic is silently ignored: no error, no warning, just no
-- dimming. The renderer reads `diagnostic._tags.unnecessary`
-- (vim/diagnostic.lua:1835), and that is the only field that works here.
--
-- SECOND, THE SPAN. gfortran's caret points at the LAST byte of the name:
--
--       REAL*8 A, UNUSEDV
--                       ^ col 23; the name starts at col 17
--
-- and a linter diagnostic with no end_col is collapsed by vim.diagnostic to a
-- single byte. Dimming one byte of a nine-byte name is indistinguishable from
-- not dimming it, so the span has to be recovered from the name the compiler
-- quotes in its message.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "the tag lands on _tags" fails if M.tag writes `tags = { 1 }` instead --
--     the LSP spelling, and the mistake this module exists to prevent.
--   * "the span covers the whole name" fails if the end_col assignment is
--     dropped, which is the state the linter shipped in.
--   * "a caret that does not line up falls back to a line search" fails if the
--     verification against the source line is removed and the arithmetic is
--     trusted blindly.
--   * "a longer identifier is not a partial match" fails if the fallback
--     search drops its word-boundary check (UNUSED would match inside
--     UNUSEDV).
--   * "an unrelated warning is left alone" fails if M.is_unused falls through
--     to the text patterns when a non-matching -W flag is present.
--   * "a message with no quoted name keeps its position" fails if name_span
--     returns a span when quoted_name found nothing.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_unused_tag_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local unused = require("andrew.fortran.unused")

-- Real gfortran 13 output, captured from
--   gfortran -Wall -Wextra -fsyntax-only -fdiagnostics-plain-output u.f90
-- on a file whose line 2 is `      REAL*8 A, UNUSEDV`. The typographic quotes
-- are U+2018/U+2019 and are what gfortran actually emits.
local GFORTRAN_MSG = "Unused variable \226\128\152unusedv\226\128\153 declared at (1) [-Wunused-variable]"
local SOURCE_LINE = "      REAL*8 A, UNUSEDV"

test("the flag is read out of the message", function()
  assert_eq(unused.flag(GFORTRAN_MSG), "-Wunused-variable", "flag:")
  assert_nil(unused.flag("Unused variable without a flag"), "no bracketed flag:")
end)

test("unused warnings are recognised", function()
  assert_true(unused.is_unused(GFORTRAN_MSG), "gfortran unused-variable:")
  assert_true(
    unused.is_unused("Unused dummy argument \226\128\152k\226\128\153 at (1) [-Wunused-dummy-argument]"),
    "unused dummy argument:"
  )
  assert_true(unused.is_unused("Unused local variable X"), "nagfor wording:")
  assert_true(unused.is_unused("This variable has not been used"), "ifort wording:")
end)

test("an unrelated warning is left alone", function()
  -- The flag is authoritative: a message carrying a -W flag that is not an
  -- unused-name flag must NOT fall through to the text patterns.
  assert_false(
    unused.is_unused("\226\128\152x\226\128\153 may be used uninitialized [-Wmaybe-uninitialized]"),
    "maybe-uninitialized:"
  )
  assert_false(unused.is_unused("Value is never used [-Wunused-value]"), "unused-value names nothing:")
  assert_false(unused.is_unused("Nonconforming tab character [-Wtabs]"), "tabs:")
  assert_false(unused.is_unused("syntax error, unexpected end of statement"), "a syntax error:")
end)

test("the quoted name is extracted from all three quoting styles", function()
  assert_eq(unused.quoted_name(GFORTRAN_MSG), "unusedv", "typographic quotes:")
  assert_eq(unused.quoted_name("Unused variable `foo' declared"), "foo", "backtick-apostrophe:")
  assert_eq(unused.quoted_name("Unused variable 'bar' declared"), "bar", "ascii apostrophes:")
end)

test("the span covers the whole name", function()
  -- Caret at 23, name 7 bytes -> starts at 17, stop is exclusive at 24.
  local first, stop = unused.name_span(GFORTRAN_MSG, SOURCE_LINE, 23)
  assert_eq(first, 17, "start:")
  assert_eq(stop, 24, "stop (exclusive):")
  assert_eq(SOURCE_LINE:sub(first, stop - 1), "UNUSEDV", "the slice is exactly the name:")
end)

test("a caret that does not line up falls back to a line search", function()
  -- A compiler pointing at the first byte instead of the last: the arithmetic
  -- guess lands on "8 A, UN" and must be rejected, not used.
  local first, stop = unused.name_span(GFORTRAN_MSG, SOURCE_LINE, 17)
  assert_eq(first, 17, "recovered start:")
  assert_eq(stop, 24, "recovered stop:")
end)

test("a longer identifier is not a partial match", function()
  -- UNUSED is a prefix of UNUSEDV; a search with no word boundary would
  -- happily return the first six bytes of the wrong name.
  local line = "      REAL*8 UNUSEDV, UNUSED"
  local msg = "Unused variable \226\128\152unused\226\128\153 declared at (1) [-Wunused-variable]"
  local first, stop = unused.name_span(msg, line, 1)
  assert_eq(first, 23, "start of the standalone UNUSED:")
  assert_eq(line:sub(first, stop - 1), "UNUSED", "the slice:")
end)

test("a message with no quoted name keeps its position", function()
  local first, stop = unused.name_span("Unused something or other", SOURCE_LINE, 23)
  assert_nil(first, "start:")
  assert_nil(stop, "stop:")
end)

test("the tag lands on _tags, and the span is narrowed", function()
  local diag = { lnum = 1, col = 22, message = GFORTRAN_MSG, severity = vim.diagnostic.severity.WARN }
  unused.tag(diag, SOURCE_LINE)
  assert_true(diag._tags ~= nil, "_tags present:")
  assert_eq(diag._tags.unnecessary, true, "_tags.unnecessary:")
  -- `tags` is the LSP wire spelling and must not be what carries this.
  assert_nil(diag.tags, "the LSP `tags` field is not used:")
  assert_eq(diag.col, 16, "0-based col narrowed to the name start:")
  assert_eq(diag.end_col, 23, "0-based end_col past the name:")
  assert_eq(diag.end_lnum, 1, "end_lnum matches lnum:")
end)

test("a non-unused diagnostic is untouched", function()
  local diag = { lnum = 4, col = 6, message = "syntax error", severity = vim.diagnostic.severity.ERROR }
  unused.tag(diag, "      X = Y +")
  assert_nil(diag._tags, "_tags:")
  assert_eq(diag.col, 6, "col unchanged:")
  assert_nil(diag.end_col, "end_col unchanged:")
end)

test("with no source line the arithmetic still narrows the span", function()
  -- The workspace lint path: the file may not be loaded, so there is nothing
  -- to verify against and the caret arithmetic is used as-is.
  local diag = { lnum = 1, col = 22, message = GFORTRAN_MSG }
  unused.tag(diag, nil)
  assert_eq(diag._tags.unnecessary, true, "still tagged:")
  assert_eq(diag.col, 16, "col:")
  assert_eq(diag.end_col, 23, "end_col:")
end)

test("an impossible caret does not produce a negative column", function()
  local diag = { lnum = 1, col = 0, message = GFORTRAN_MSG }
  unused.tag(diag, nil)
  assert_eq(diag._tags.unnecessary, true, "tagged:")
  assert_eq(diag.col, 0, "col left alone rather than driven negative:")
  assert_nil(diag.end_col, "no end_col invented:")
end)

_H.finish()
