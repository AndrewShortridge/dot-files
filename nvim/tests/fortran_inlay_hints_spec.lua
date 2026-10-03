-- Spec for andrew.fortran.lsp_inlayhint -- the callee's dummy-argument names
-- shown against the actual arguments of a call.
--
-- WHAT IT PINS
--
-- Fortran 77 has no keyword arguments, so `CALL DIFFUSE(N, D, F, T, Q)` says
-- nothing about what those five scalars are for. The hint has to survive the
-- three things that make Fortran call sites awkward, and each of them is a
-- silent failure if it breaks -- a missing hint looks exactly like a call to a
-- procedure the index does not know:
--
--   1. CONTINUATIONS. A long argument list is split across lines, by a
--      trailing `&` in free form and by a marker in COLUMN 6 in fixed form.
--      The two are unrelated mechanisms and the fixed-form one is not detected
--      by the scanner's own continuation state.
--   2. `NAME(` IS AMBIGUOUS. Fortran spells a function call and an array
--      reference identically. `arr(3)` must get no hints; the only sound
--      filter is whether the project defines a procedure of that name.
--   3. NESTED PARENTHESES. `CALL F(G(A,B), C)` has three commas and two
--      arguments.
--
-- The project below is real: written to a temp directory and read back through
-- the actual ripgrep-backed signature builder, not a mock. Source-introspection
-- assertions are banned in this repo and none are used.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "a fixed-form continuation is followed" fails if is_fixed_continuation
--     accepts column 6 == "0" or a blank, or if arg_slots does not skip
--     columns 1-6 on a continuation line.
--   * "a free-form continuation is followed" fails if the trailing `&` is
--     scanned as argument text instead of ending the line.
--   * "nested parens do not split an argument" fails if the depth check on the
--     comma is dropped.
--   * "an array reference gets no hints" fails if call_sites stops filtering
--     by the signature index.
--   * "a procedure's own header gets no hints" fails if the definition-line
--     exclusion is removed -- SUBROUTINE DIFFUSE(NNODE, ...) is itself a
--     `NAME(` hit. Asserted on call_sites, because on the HINTS alone the
--     same-name suppression would mask the difference.
--   * "an argument spelled like its dummy is suppressed" fails if that
--     comparison is dropped, or if it is made case-sensitive.
--   * "a continued header's later arguments are indexed" fails if header_args
--     stops at the first line, which silently truncates every signature that
--     wraps.
--   * "an unclosed list produces nothing" fails if arg_slots reports its
--     partial result as closed.
--   * "a builtin function call is annotated with its result type" fails if the
--     return-type hint is positioned from the callee rather than from the
--     closing paren arg_slots reports, or if the label loses its ": " prefix.
--   * "only the return-type hint carries paddingLeft" fails if paddingLeft
--     leaks onto the argument-name hints: every one of them would gain a
--     leading space and stop abutting its argument.
--   * "a project function gets no return-type hint" fails if the `builtin`
--     test is dropped -- a textual scan cannot recover a project function's
--     result type, and printing a guess as fact is worse than silence.
--   * "vim.g.fortran_inlay_hints gates each family" fails if either gate is
--     ignored, and the all-off case fails if inlay() scans before checking --
--     it would run ripgrep to build an answer it then throws away. It also
--     fails if the table goes back to being read as an EXHAUSTIVE statement
--     rather than as overrides: `{ argument_names = false }` would then turn
--     the return types off as well, a feature the user never mentioned, and
--     `vim.g.fortran_inlay_hints = false` -- the documented way to turn
--     everything off -- would turn everything ON.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_inlay_hints_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local IH = require("andrew.fortran.lsp_inlayhint")
local scan = require("andrew.fortran.scan")

-- ---------------------------------------------------------------------------
-- A real project on disk
-- ---------------------------------------------------------------------------

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/code", "p")
-- `.git` is one of scan.project_root's markers, so the temp tree resolves to
-- itself rather than to whatever encloses the system temp directory.
vim.fn.mkdir(root .. "/.git", "p")

local DIFFUSE = {
  "      SUBROUTINE DIFFUSE(NNODE, DT, FLUX,",
  "     &                   TEMPTR, QSRC)",
  "      REAL*8 DT, FLUX, TEMPTR, QSRC",
  "      INTEGER NNODE",
  "      TEMPTR = TEMPTR + DT*FLUX",
  "      RETURN",
  "      END",
}
local ENERGY = {
  "      REAL*8 FUNCTION ENERGY(MASS, VEL)",
  "      REAL*8 MASS, VEL",
  "      ENERGY = 0.5D0*MASS*VEL*VEL",
  "      RETURN",
  "      END",
}
local MAIN = {
  "      PROGRAM MAIN", -- 1
  "      REAL*8 D, F, T, Q, E, M, V", -- 2
  "      INTEGER N", -- 3
  "      DIMENSION ARR(10)", -- 4
  "      CALL DIFFUSE(N, D, F, T, Q)", -- 5
  "      CALL DIFFUSE(N, D,", -- 6
  "     &             F, T, Q)", -- 7
  "      E = ENERGY(M, V)", -- 8
  "      X = ARR(3)", -- 9
  "      CALL DIFFUSE(NNODE, DT, FLUX, TEMPTR, QSRC)", -- 10
  "      E = ENERGY(ENERGY(M, V), V)", -- 11
  "      END", -- 12
}
vim.fn.writefile(DIFFUSE, root .. "/code/diffuse.f")
vim.fn.writefile(ENERGY, root .. "/code/energy.f")
vim.fn.writefile(MAIN, root .. "/code/main.f")

--- Block until the async signature build finishes.
local function signatures()
  local result = nil
  IH.invalidate()
  IH.build_signatures(root, function(sigs)
    result = sigs
  end)
  vim.wait(20000, function()
    return result ~= nil
  end, 20)
  return result or {}
end

local sigs = signatures()

local function buf_for(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

--- Hints for `lines`, rendered as "lnum:col label" for readable assertions.
local function hints_for(lines, ft)
  local buf = buf_for(lines, ft)
  local fixed = ft == "fortran_fixed"
  local bs = scan.scan_lines(lines, { fixed = fixed })
  local hs = IH.build_hints(bs, sigs, fixed, 1, #lines)
  local out = {}
  for _, h in ipairs(hs) do
    out[#out + 1] = ("%d:%d %s"):format(h.position.line + 1, h.position.character + 1, h.label)
  end
  table.sort(out)
  vim.api.nvim_buf_delete(buf, { force = true })
  return out
end

local function has(list, entry)
  for _, v in ipairs(list) do
    if v == entry then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------

test("the signature index finds both procedures", function()
  assert_true(sigs.diffuse ~= nil, "DIFFUSE indexed:")
  assert_true(sigs.energy ~= nil, "ENERGY indexed:")
  assert_eq(sigs.energy.name, "ENERGY", "the original casing is kept:")
end)

test("a continued header's later arguments are indexed", function()
  -- TEMPTR and QSRC live on the continuation line. A signature that stops at
  -- the first line has three of five arguments and silently drops the hints
  -- for the other two.
  assert_eq(table.concat(sigs.diffuse.args, ","), "NNODE,DT,FLUX,TEMPTR,QSRC", "DIFFUSE dummies:")
  assert_eq(table.concat(sigs.energy.args, ","), "MASS,VEL", "ENERGY dummies:")
end)

test("a plain call is labelled with the dummy names", function()
  local hs = hints_for(MAIN, "fortran_fixed")
  assert_true(has(hs, "5:20 NNODE:"), "NNODE on line 5: " .. vim.inspect(hs))
  assert_true(has(hs, "5:23 DT:"), "DT on line 5:")
  assert_true(has(hs, "5:26 FLUX:"), "FLUX on line 5:")
  assert_true(has(hs, "5:29 TEMPTR:"), "TEMPTR on line 5:")
  assert_true(has(hs, "5:32 QSRC:"), "QSRC on line 5:")
end)

test("a fixed-form continuation is followed", function()
  -- Line 6 opens the list, line 7 continues it with a marker in column 6.
  local hs = hints_for(MAIN, "fortran_fixed")
  assert_true(has(hs, "6:20 NNODE:"), "first argument on the opening line:")
  assert_true(has(hs, "7:20 FLUX:"), "third argument on the CONTINUATION line: " .. vim.inspect(hs))
  assert_true(has(hs, "7:23 TEMPTR:"), "fourth argument:")
  assert_true(has(hs, "7:26 QSRC:"), "fifth argument:")
end)

test("a free-form continuation is followed", function()
  local lines = {
    "program driver",
    "  real(8) :: d, f, t, q",
    "  integer :: n",
    "  call diffuse(n, d, &",
    "               f, t, q)",
    "end program driver",
  }
  local hs = hints_for(lines, "fortran_free")
  assert_true(has(hs, "4:16 NNODE:"), "first argument: " .. vim.inspect(hs))
  assert_true(has(hs, "5:16 FLUX:"), "argument after the ampersand:")
  assert_true(has(hs, "5:22 QSRC:"), "last argument:")
end)

test("a function reference is labelled too", function()
  local hs = hints_for(MAIN, "fortran_fixed")
  assert_true(has(hs, "8:18 MASS:"), "MASS: " .. vim.inspect(hs))
  assert_true(has(hs, "8:21 VEL:"), "VEL:")
end)

test("an array reference gets no hints", function()
  -- ARR is not a procedure this project defines, so ARR(3) must be left alone.
  local hs = hints_for(MAIN, "fortran_fixed")
  for _, h in ipairs(hs) do
    assert_false(h:match("^9:") ~= nil, "nothing on the ARR(3) line, got " .. h)
  end
end)

test("an argument spelled like its dummy is suppressed", function()
  -- Line 10 passes NNODE, DT, FLUX, TEMPTR, QSRC by those very names.
  local hs = hints_for(MAIN, "fortran_fixed")
  for _, h in ipairs(hs) do
    assert_false(h:match("^10:") ~= nil, "nothing on the pass-through line, got " .. h)
  end
end)

test("the suppression is case-insensitive", function()
  local lines = {
    "      PROGRAM P",
    "      REAL*8 MASS, VEL",
    "      E = ENERGY(mass, vel)",
    "      END",
  }
  assert_eq(#hints_for(lines, "fortran_fixed"), 0, "lowercase spellings still suppressed:")
end)

test("a procedure's own header gets no hints", function()
  -- SUBROUTINE DIFFUSE(NNODE, ...) is a `NAME(` hit for DIFFUSE.
  --
  -- Asserted at the call_sites level, not just on the hints. A definition's
  -- actual arguments ARE its dummy names by construction, so the same-name
  -- suppression would hide these anyway and an assertion on the hints alone
  -- cannot tell the exclusion from the suppression. Only the site list can.
  local bs = scan.scan_lines(DIFFUSE, { fixed = true })
  assert_eq(#IH.call_sites(bs, sigs), 0, "the header is not a call site:")
  local hs = hints_for(DIFFUSE, "fortran_fixed")
  assert_eq(#hs, 0, "the definition is not annotated: " .. vim.inspect(hs))
end)

test("nested parens do not split an argument", function()
  -- ENERGY(ENERGY(M, V), V) is TWO arguments; a depth-blind comma split reads
  -- three and labels the wrong things.
  local masked = scan.mask(MAIN[11], true)
  local open = masked:find("%(")
  local slots, closed = IH.arg_slots({ [1] = masked }, 1, open, true)
  assert_true(closed, "the list closed:")
  assert_eq(#slots, 2, "argument count:")
  -- Slot text comes from the MASKED line, so it is lowercased and has string
  -- literals blanked. It is only ever compared against a dummy name, never
  -- displayed, so that is fine -- but it means the expectation is lowercase.
  assert_eq(slots[1].text, "energy(m, v)", "the nested call is one argument:")
  assert_eq(slots[2].text, "v", "the second argument:")
end)

test("an unclosed list produces nothing", function()
  local masked = scan.mask("      CALL DIFFUSE(N, D, F", true)
  local open = masked:find("%(")
  local slots, closed = IH.arg_slots({ [1] = masked }, 1, open, true)
  assert_false(closed, "not reported as closed:")
  -- build_hints requires `closed`, so an unbalanced statement is silent
  -- rather than mislabelled.
  local hs = hints_for({ "      CALL DIFFUSE(N, D, F" }, "fortran_fixed")
  assert_eq(#hs, 0, "no hints from a truncated call: " .. vim.inspect(hs))
  assert_true(#slots >= 1, "the partial walk still collected something:")
end)

test("an empty argument list yields no slots", function()
  local masked = scan.mask("      CALL DIFFUSE()", true)
  local slots, closed = IH.arg_slots({ [1] = masked }, 1, masked:find("%("), true)
  assert_true(closed, "closed:")
  assert_eq(#slots, 0, "no slots for F():")
end)

test("column 6 rules decide a fixed-form continuation", function()
  assert_true(IH.is_fixed_continuation("     &  X, Y"), "ampersand in column 6:")
  assert_true(IH.is_fixed_continuation("     1  X, Y"), "digit in column 6:")
  assert_false(IH.is_fixed_continuation("     0  X, Y"), "zero is NOT a continuation:")
  assert_false(IH.is_fixed_continuation("        X = 1"), "blank column 6:")
  assert_false(IH.is_fixed_continuation("  100 CONTINUE"), "a statement label is not a continuation:")
  assert_false(IH.is_fixed_continuation("     "), "too short:")
end)

test("source form is decided by extension, not by guesswork", function()
  assert_true(IH.is_fixed(nil, "/p/code/main.f"), ".f:")
  assert_true(IH.is_fixed(nil, "/p/code/MAIN.FOR"), ".FOR:")
  assert_true(IH.is_fixed(nil, "/p/code/x.fpp"), ".fpp is fixed:")
  assert_false(IH.is_fixed(nil, "/p/src/mod.f90"), ".f90:")
  assert_false(IH.is_fixed(nil, "/p/src/mod.f95"), ".f95 is free:")
end)

test("hints outside the requested range are not emitted", function()
  local buf_scan = scan.scan_lines(MAIN, { fixed = true })
  local hs = IH.build_hints(buf_scan, sigs, true, 8, 8)
  assert_true(#hs > 0, "line 8 has hints:")
  for _, h in ipairs(hs) do
    assert_eq(h.position.line + 1, 8, "only line 8:")
  end
end)

test("a call opening above the range still labels its in-range arguments", function()
  -- The call head is on line 6 and the range starts at line 7. Filtering call
  -- SITES by the range would drop these; the hints are filtered instead.
  local buf_scan = scan.scan_lines(MAIN, { fixed = true })
  local hs = IH.build_hints(buf_scan, sigs, true, 7, 7)
  local labels = {}
  for _, h in ipairs(hs) do
    labels[#labels + 1] = h.label
  end
  table.sort(labels)
  assert_eq(table.concat(labels, ","), "FLUX:,QSRC:,TEMPTR:", "the continuation line's hints:")
end)

test("the hint is an LSP Parameter hint", function()
  local buf_scan = scan.scan_lines(MAIN, { fixed = true })
  local hs = IH.build_hints(buf_scan, sigs, true, 5, 5)
  assert_true(#hs > 0, "hints present:")
  assert_eq(hs[1].kind, 2, "InlayHintKind.Parameter:")
  assert_eq(hs[1].paddingRight, true, "a space after the label:")
end)

-- ---------------------------------------------------------------------------
-- Return-type hints (E3)
-- ---------------------------------------------------------------------------

-- `omp_get_wtime` is a registry builtin with a result type; `energy` is a
-- project function, whose result type a textual scan has no business printing.
local MIXED = {
  "program timing", -- 1
  "  double precision :: t", -- 2
  "  real(8) :: m, v, e", -- 3
  "  t = omp_get_wtime()", -- 4
  "  e = energy(m, v)", -- 5
  "end program timing", -- 6
}

--- Every hint for MIXED, free form, whatever the current gate says.
local function mixed_hints()
  local bs = scan.scan_lines(MIXED, { fixed = false })
  return IH.build_hints(bs, sigs, false, 1, #MIXED)
end

--- The first hint of `kind`.
local function first_of_kind(hs, kind)
  for _, h in ipairs(hs) do
    if h.kind == kind then
      return h
    end
  end
  return nil
end

test("a builtin function call is annotated with its result type", function()
  local h = first_of_kind(mixed_hints(), IH.KIND_TYPE)
  assert_true(h ~= nil, "a type hint was produced: ")
  assert_eq(h.label, ": double precision", "the result type, with its separator: ")
  assert_eq(h.kind, 1, "InlayHintKind.Type: ")
  assert_eq(h.paddingLeft, true, "a space before it, because it abuts the `)`: ")
  assert_eq(h.paddingRight, nil, "and never a space after -- upstream sets paddingRight nowhere: ")
  assert_eq(#h.textEdits, 0, "accepting it would write invalid Fortran, so there is nothing to accept: ")
  -- `  t = omp_get_wtime()` -- the `)` is the 21st byte, so the hint sits at
  -- 0-based character 21, just PAST it.
  assert_eq(h.position.line, 3, "on the call's closing line: ")
  assert_eq(h.position.character, 21, "immediately after the `)`: ")
  assert_eq(MIXED[4]:sub(21, 21), ")", "the character it follows: ")
end)

test("only the return-type hint carries paddingLeft", function()
  local seen = 0
  for _, h in ipairs(mixed_hints()) do
    if h.kind == IH.KIND_PARAMETER then
      seen = seen + 1
      assert_eq(h.paddingLeft, nil, h.label .. " is an argument-name hint: ")
      assert_eq(h.paddingRight, true, h.label .. " pads to the right instead: ")
    end
  end
  assert_true(seen > 0, "there were argument-name hints to check: ")
end)

test("a project function gets no return-type hint", function()
  local types = {}
  for _, h in ipairs(mixed_hints()) do
    if h.kind == IH.KIND_TYPE then
      types[#types + 1] = h.position.line + 1
    end
  end
  assert_eq(#types, 1, "exactly one, for omp_get_wtime: " .. vim.inspect(types))
  assert_eq(types[1], 4, "line 5's `energy(...)` is fortls's to type: ")
end)

test("vim.g.fortran_inlay_hints gates each family", function()
  local saved = vim.g.fortran_inlay_hints

  local function kinds()
    local out = { [IH.KIND_PARAMETER] = 0, [IH.KIND_TYPE] = 0 }
    for _, h in ipairs(mixed_hints()) do
      out[h.kind] = (out[h.kind] or 0) + 1
    end
    return out
  end

  vim.g.fortran_inlay_hints = nil
  local both = kinds()
  assert_true(both[IH.KIND_PARAMETER] > 0 and both[IH.KIND_TYPE] > 0, "unset means both families: ")

  vim.g.fortran_inlay_hints = { argument_names = true, return_types = false }
  local names_only = kinds()
  assert_true(names_only[IH.KIND_PARAMETER] > 0, "argument names stay: ")
  assert_eq(names_only[IH.KIND_TYPE], 0, "return types go: ")

  -- The table is a set of OVERRIDES: a field that is MISSING keeps its
  -- default, which is on. Naming one family must not silently disable the
  -- other -- they are independent, and a user who writes
  -- `{ argument_names = false }` has said nothing about return types.
  vim.g.fortran_inlay_hints = { argument_names = false }
  local types_only = kinds()
  assert_eq(types_only[IH.KIND_PARAMETER], 0, "the named family goes off: ")
  assert_true(types_only[IH.KIND_TYPE] > 0, "the unnamed one stays on: ")

  vim.g.fortran_inlay_hints = { return_types = false }
  local names_kept = kinds()
  assert_true(names_kept[IH.KIND_PARAMETER] > 0, "and symmetrically: ")
  assert_eq(names_kept[IH.KIND_TYPE], 0, "only return types go: ")

  vim.g.fortran_inlay_hints = {}
  local empty = kinds()
  assert_true(empty[IH.KIND_PARAMETER] > 0 and empty[IH.KIND_TYPE] > 0, "an empty table overrides nothing: ")

  vim.g.fortran_inlay_hints = false
  local none = kinds()
  assert_eq(none[IH.KIND_PARAMETER], 0, "`false` is how BOTH are turned off: ")
  assert_eq(none[IH.KIND_TYPE], 0, "both of them: ")

  vim.g.fortran_inlay_hints = { argument_names = false, return_types = false }
  local none2 = kinds()
  assert_eq(none2[IH.KIND_PARAMETER], 0, "naming both off works too: ")
  assert_eq(none2[IH.KIND_TYPE], 0, "both of them: ")

  vim.g.fortran_inlay_hints = saved
end)

test("both families off answers without scanning the project", function()
  local saved = vim.g.fortran_inlay_hints
  vim.g.fortran_inlay_hints = false
  -- ensure_signatures would have to shell out to answer this, so a synchronous
  -- empty answer is proof the gate is checked before the scan.
  local buf = buf_for(MIXED, "fortran_free")
  vim.api.nvim_buf_set_name(buf, root .. "/code/gated.f90")
  local got = nil
  IH.inlay({ textDocument = { uri = vim.uri_from_bufnr(buf) } }, function(_, res)
    got = res
  end)
  assert_true(got ~= nil, "answered synchronously, before any subprocess: ")
  assert_eq(#got, 0, "with nothing: ")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.g.fortran_inlay_hints = saved
end)

vim.fn.delete(root, "rf")
_H.finish()
