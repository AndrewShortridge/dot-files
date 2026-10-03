-- Spec for lua/andrew/fortran/lsp_highlight.lua -- the documentHighlight
-- provider of the in-process Fortran language server.
--
-- WHAT IT PINS
--
-- fortls has no documentHighlight, so this module is the only thing standing
-- between `]]` / `[[` / Snacks.words and a Fortran buffer. Four things decide
-- whether its answer is useful rather than actively harmful, and each has a
-- test here:
--
--   1. SCOPE. A file of F77-descended subroutines declares `I` and `NNODE` a
--      dozen times over. An answer covering the whole file would make `]]`
--      jump into an unrelated procedure, so the answer stops at the innermost
--      program unit -- counted with unit keywords only, so `end do` and
--      `end if` do not close a subroutine.
--   2. COMMENTS AND STRINGS. The cursor token is looked up in the masked line,
--      so a word in a comment or a literal is not an identifier at all.
--   3. CASE. Fortran is case-insensitive: `TEMP` and `temp` are one name.
--   4. READ vs WRITE. `x = 1` writes, `x == y` does not, `ptr => tgt` does,
--      `a /= b` does not, and an `=` inside parentheses (`real(kind=8)`) is a
--      keyword argument, not an assignment.
--
-- Plus the cache: this runs on every cursor movement, so a 500-line scan per
-- CursorMoved is the failure mode, and the changedtick key is tested by
-- counting real calls into the scanner.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "comment" / "string literal" fail if the cursor token is looked up in
--     the raw line instead of the masked one.
--   * "case-insensitive" fails if occurrences are compared by their raw source
--     text rather than by the masked (lowercased) name.
--   * "unit scoping" and "nnode is scoped" fail if the answer is not clipped
--     to unit_range -- the other subroutine's occurrences come back.
--   * "end do / end if" fails if the construct keywords are added to
--     UNIT_END_KEYWORDS: the unit then closes at the first `end do`.
--   * "unit_range" fails if the no-unit fallback stops returning the file.
--   * "a declaration is a write" fails if the decls set is dropped.
--   * "an assignment target is a write" fails if is_assignment_target always
--     answers false.
--   * "`==`" fails if the second `=` is not checked for.
--   * "`/=`" fails if the operator character in front of the `=` is skipped
--     over (the occurrence is at paren depth 0, so only that test saves it).
--   * "`=>`" fails if `>` is excluded alongside `=`.
--   * "an `=` inside parentheses" fails if the paren-depth test on the token
--     is dropped.
--   * "a bare keyword" fails if the keyword filter goes.
--   * "cached per changedtick" fails both ways: without a cache the first
--     assertion sees two scans, and keyed on the buffer alone the edit is
--     never noticed.
--   * "positions are byte columns" fails if the column is converted to utf-16
--     (the server declares utf-8, so it must not be).
--
-- Run with: nvim --headless -u NONE -l tests/fortran_lsp_highlight_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil, assert_deep_eq = _H.assert_nil, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local hl = require("andrew.fortran.lsp_highlight")
local scan = require("andrew.fortran.scan")

-- Helpers -------------------------------------------------------------------

--- A named, loaded buffer holding `lines`, plus its URI.
---@param lines string[]
---@return integer bufnr, string uri
local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".f90")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  hl.reset_cache()
  return buf, vim.uri_from_bufnr(buf)
end

--- Ask for highlights with 1-based line / 1-based byte column, the way the
--- scanner counts, converting to LSP's 0-based position on the way in.
---@param uri string
---@param lnum integer
---@param col integer
---@return table[]|nil
local function highlights(uri, lnum, col)
  return hl.highlight({
    textDocument = { uri = uri },
    position = { line = lnum - 1, character = col - 1 },
  })
end

--- 1-based column of the `n`th occurrence of `needle` in `line`.
local function col_of(line, needle, n)
  local init, col = 1, nil
  for _ = 1, n or 1 do
    local s, e = line:lower():find(needle:lower(), init, true)
    if not s then
      return nil
    end
    col, init = s, e + 1
  end
  return col
end

--- Highlights as sorted "lnum:col:kind" strings, in scanner coordinates.
local function shape(list)
  local out = {}
  for _, h in ipairs(list or {}) do
    out[#out + 1] = string.format(
      "%d:%d:%d",
      h.range.start.line + 1,
      h.range.start.character + 1,
      h.kind
    )
  end
  table.sort(out)
  return out
end

--- The kind reported at (lnum, col), or nil when nothing is reported there.
local function kind_at(list, lnum, col)
  for _, h in ipairs(list or {}) do
    if h.range.start.line + 1 == lnum and h.range.start.character + 1 == col then
      return h.kind
    end
  end
  return nil
end

local function lines_of(list)
  local seen, out = {}, {}
  for _, h in ipairs(list or {}) do
    local l = h.range.start.line + 1
    if not seen[l] then
      seen[l] = true
      out[#out + 1] = l
    end
  end
  table.sort(out)
  return out
end

-- The fixture. Two subroutines in one module, each with its own `i` and
-- `nnode`, which is the shape the scoping rule exists for.
local FIX = {
  "module physics", -- 1
  "  implicit none", -- 2
  "contains", -- 3
  "", -- 4
  "  subroutine heat(nnode, temp)", -- 5
  "    integer :: nnode", -- 6
  "    real :: TEMP(nnode)", -- 7
  "    integer :: i", -- 8
  "    logical :: flag", -- 9
  "    ! temp of i is only prose here", -- 10
  "    do i = 1, nnode", -- 11
  "      temp(i) = temp(i) + 1.0", -- 12
  "    end do", -- 13
  "    flag = i == nnode", -- 14
  "    write(*,*) 'temp of i'", -- 15
  "    if (flag) then", -- 16
  "    end if", -- 17
  "  end subroutine heat", -- 18
  "", -- 19
  "  subroutine cool(nnode)", -- 20
  "    integer :: nnode", -- 21
  "    integer :: i", -- 22
  "    do i = 1, nnode", -- 23
  "      call step(i)", -- 24
  "    end do", -- 25
  "  end subroutine cool", -- 26
  "", -- 27
  "end module physics", -- 28
}

local WRITE, READ = 2, 3

-- ---------------------------------------------------------------------------

test("a word in a comment yields no highlights", function()
  local _, uri = make_buf(FIX)
  local col = col_of(FIX[10], "temp", 1)
  assert_true(col ~= nil, "fixture must have `temp` on the comment line:")
  assert_nil(highlights(uri, 10, col), "a comment word is not an identifier:")
  -- ...while the same word one line away is.
  assert_true(highlights(uri, 12, col_of(FIX[12], "temp", 1)) ~= nil, "control:")
end)

test("a word inside a string literal yields no highlights", function()
  local _, uri = make_buf(FIX)
  local col = col_of(FIX[15], "temp", 1)
  assert_nil(highlights(uri, 15, col), "a literal's contents are not identifiers:")
end)

test("matching is case-insensitive and finds the uppercase declaration", function()
  local _, uri = make_buf(FIX)
  -- Cursor on the lowercase `temp` of line 12; the declaration on line 7 is
  -- spelled TEMP.
  local got = highlights(uri, 12, col_of(FIX[12], "temp", 1))
  assert_deep_eq(lines_of(got), { 5, 7, 12 }, "TEMP on line 7 must match temp:")
end)

test("highlights stop at the enclosing program unit", function()
  local _, uri = make_buf(FIX)
  local got = highlights(uri, 11, col_of(FIX[11], "i", 1))
  -- heat's `i`: declaration (8), loop control (11), two subscripts (12), the
  -- comparison (14). Nothing from cool, whose `i` lives on 22, 23 and 24.
  assert_deep_eq(lines_of(got), { 8, 11, 12, 14 }, "cool's `i` must not appear:")

  local other = highlights(uri, 23, col_of(FIX[23], "i", 1))
  assert_deep_eq(lines_of(other), { 22, 23, 24 }, "and heat's must not appear in cool:")
end)

test("`end do` and `end if` do not close the program unit", function()
  local _, uri = make_buf(FIX)
  -- Line 16 sits past both an `end do` (13) and inside an `if`; if either
  -- construct closed the unit, flag's declaration on line 9 would be out of
  -- range.
  local got = highlights(uri, 16, col_of(FIX[16], "flag", 1))
  assert_deep_eq(lines_of(got), { 9, 14, 16 }, "the unit must survive `end do`:")
end)

test("nnode is scoped per subroutine too", function()
  local _, uri = make_buf(FIX)
  local got = highlights(uri, 6, col_of(FIX[6], "nnode", 1))
  assert_deep_eq(lines_of(got), { 5, 6, 7, 11, 14 }, "cool's nnode is a different name:")
end)

test("a declaration is a write", function()
  local _, uri = make_buf(FIX)
  local got = highlights(uri, 11, col_of(FIX[11], "i", 1))
  assert_eq(kind_at(got, 8, col_of(FIX[8], "i", 2)), WRITE, "`integer :: i` declares:")
end)

test("an assignment target is a write, its uses are reads", function()
  local _, uri = make_buf(FIX)
  local got = highlights(uri, 12, col_of(FIX[12], "temp", 1))
  assert_eq(kind_at(got, 12, col_of(FIX[12], "temp", 1)), WRITE, "temp(i) = ... writes:")
  assert_eq(kind_at(got, 12, col_of(FIX[12], "temp", 2)), READ, "... = temp(i) reads:")

  local loop = highlights(uri, 11, col_of(FIX[11], "i", 1))
  assert_eq(kind_at(loop, 11, col_of(FIX[11], "i", 1)), WRITE, "a do-loop control writes:")
  assert_eq(kind_at(loop, 12, col_of(FIX[12], "i", 1)), READ, "a subscript reads:")
end)

test("`==` is a comparison, not a write", function()
  local _, uri = make_buf(FIX)
  -- Line 14 is `flag = i == nnode`: flag is written, i is compared at paren
  -- depth 0 -- the position where a naive "followed by =" test breaks.
  local got = highlights(uri, 11, col_of(FIX[11], "i", 1))
  assert_eq(kind_at(got, 14, col_of(FIX[14], "i", 1)), READ, "`i ==` is not an assignment:")

  local f = highlights(uri, 16, col_of(FIX[16], "flag", 1))
  assert_eq(kind_at(f, 14, col_of(FIX[14], "flag", 1)), WRITE, "but `flag =` is:")
end)

test("`=>` is a write and `/=` is not", function()
  local src = {
    "subroutine link(a, b)", -- 1
    "  real, pointer :: ptr", -- 2
    "  real, target :: tgt", -- 3
    "  logical :: ok", -- 4
    "  ptr => tgt", -- 5
    "  ok = a /= b", -- 6
    "  a = 1", -- 7
    "end subroutine link", -- 8
  }
  local _, uri = make_buf(src)

  local p = highlights(uri, 5, col_of(src[5], "ptr", 1))
  assert_eq(kind_at(p, 5, col_of(src[5], "ptr", 1)), WRITE, "pointer association writes:")

  -- Line 6 puts `a` at paren depth 0 in front of a `/=`, so the paren-depth
  -- test cannot rescue it: only looking at the operator character can.
  local a = highlights(uri, 7, col_of(src[7], "a", 1))
  assert_eq(kind_at(a, 6, col_of(src[6], "a", 1)), READ, "`a /=` compares:")
  assert_eq(kind_at(a, 7, col_of(src[7], "a", 1)), WRITE, "`a =` assigns:")
end)

test("an `=` inside parentheses is a keyword argument, not a write", function()
  local src = {
    "subroutine sel()", -- 1
    "  real(kind=8) :: x", -- 2
    "  x = 1.0", -- 3
    "end subroutine sel", -- 4
  }
  local _, uri = make_buf(src)
  local got = highlights(uri, 2, col_of(src[2], "kind", 1))
  assert_eq(kind_at(got, 2, col_of(src[2], "kind", 1)), READ, "kind=8 is not an assignment:")
end)

test("a bare keyword under the cursor yields nothing", function()
  local _, uri = make_buf(FIX)
  assert_nil(highlights(uri, 11, col_of(FIX[11], "do", 1)), "`do` is not a symbol:")
  -- ...unless the file declares a variable by that name.
  local src = { "subroutine k()", "  integer :: type", "  type = 3", "end subroutine k" }
  local _, uri2 = make_buf(src)
  local got = highlights(uri2, 3, col_of(src[3], "type", 1))
  assert_deep_eq(lines_of(got), { 2, 3 }, "a variable named `type` is still a variable:")
end)

test("unit_range picks the innermost unit and falls back to the file", function()
  local data = scan.scan_lines(FIX)

  local first, last = hl.unit_range(data.masked, data.defs, 12)
  assert_eq(first, 5, "heat opens on line 5:")
  assert_eq(last, 18, "and closes on line 18:")

  first, last = hl.unit_range(data.masked, data.defs, 23)
  assert_eq(first, 20, "cool opens on line 20:")
  assert_eq(last, 26, "and closes on line 26:")

  -- Line 3 (`contains`) is in the module and in no subroutine.
  first, last = hl.unit_range(data.masked, data.defs, 3)
  assert_eq(first, 1, "the module is the innermost unit there:")
  assert_eq(last, 28)

  -- An include file of bare COMMON blocks opens no unit at all.
  local inc = { "      common /geom/ nx, ny", "      nx = 1" }
  local incdata = scan.scan_lines(inc)
  first, last = hl.unit_range(incdata.masked, incdata.defs, 2)
  assert_eq(first, 1, "no unit means the whole file:")
  assert_eq(last, 2)
end)

test("the scan is cached per changedtick and invalidated by an edit", function()
  local buf, uri = make_buf(FIX)
  local original = scan.scan_buffer
  local calls = 0
  scan.scan_buffer = function(b)
    calls = calls + 1
    return original(b)
  end

  local ok, err = pcall(function()
    local a = highlights(uri, 11, col_of(FIX[11], "i", 1))
    local b = highlights(uri, 12, col_of(FIX[12], "temp", 1))
    assert_true(a ~= nil and b ~= nil, "both requests answered:")
    assert_eq(calls, 1, "a second request on an unchanged buffer must not rescan:")

    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "! a new first line" })
    local c = highlights(uri, 12, col_of(FIX[11], "i", 1))
    assert_eq(calls, 2, "an edit must invalidate the cache:")
    -- Everything has shifted down one line, which is only true if the cached
    -- masked lines were rebuilt.
    assert_deep_eq(lines_of(c), { 9, 12, 13, 15 }, "the rescan sees the new line numbers:")
  end)

  scan.scan_buffer = original
  if not ok then
    error(err, 0)
  end
end)

test("positions are byte columns, not utf-16 characters", function()
  -- The server declares positionEncoding = "utf-8", so a multi-byte character
  -- earlier on the line must NOT shift the reported column. `café` is one
  -- byte longer than it is characters long, which is exactly the shift a
  -- utf-16 conversion would introduce.
  local src = {
    "subroutine widen()", -- 1
    "  integer :: idx, nn", -- 2
    "  nn = len('caf" .. string.char(0xC3, 0xA9) .. "') + idx", -- 3
    "  idx = 1", -- 4
    "end subroutine widen", -- 5
  }
  local _, uri = make_buf(src)
  local got = highlights(uri, 4, col_of(src[4], "idx", 1))
  assert_eq(kind_at(got, 3, col_of(src[3], "idx", 1)), READ, "byte column past a multi-byte literal:")
  assert_deep_eq(shape(got), { "2:14:2", "3:23:3", "4:3:2" }, "every position in scanner coordinates:")
end)

_H.finish()
