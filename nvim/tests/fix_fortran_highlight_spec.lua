-- Spec for andrew.fortran.highlight (extmark re-implementation).
--
-- THE BUG THIS PINS
--   The module used to register `syntax match FortranMPIKeyword /\c\<mpi_init\>/
--   containedin=ALL` for all 388 documented keywords. The rules registered --
--   `synID()` answered the right group -- and nothing was ever DRAWN, because
--   andrew.plugins.treesitter enables tree-sitter highlighting for fortran and
--   tree-sitter's extmarks (priority 100) sit on top of the regex-syntax layer
--   (priority 0), which for identifiers is everywhere. The colours appeared
--   only on a file over 20000 lines, where treesitter.lua's `disable`
--   predicate turns the tree-sitter highlighter off.
--
--   The second bug in the old path: `\<mpi_init\>` matched inside comments and
--   string literals too, so `! call MPI_INIT here` was coloured as code.
--
-- Run with: nvim --headless -u NONE -l tests/fix_fortran_highlight_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false, _H.assert_nil

local cfg = vim.fn.stdpath("config")
package.path = cfg .. "/lua/?.lua;" .. package.path

local H = require("andrew.fortran.highlight")
H.setup_highlights()

local NS = H.namespace()

--- A loaded, named Fortran buffer holding `lines`.
---@param lines string[]
---@param name string|nil drives scan.is_fixed for fixed-form tests
local function fbuf(lines, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if name then
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].filetype = "fortran"
  return buf
end

--- Every mark as { row0, col0, end_col, group, text }.
local function marks(buf)
  local out = {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })) do
    local row, col, d = m[2], m[3], m[4]
    out[#out + 1] = {
      row = row,
      col = col,
      group = d.hl_group,
      priority = d.priority,
      text = (lines[row + 1] or ""):sub(col + 1, d.end_col),
    }
  end
  return out
end

--- Group painted on the first occurrence of `text`, or nil.
local function group_of(buf, text)
  for _, m in ipairs(marks(buf)) do
    if m.text == text then
      return m.group, m
    end
  end
  return nil
end

local FREE = {
  "MODULE m",                                       -- 1
  "  USE mpi",                                      -- 2
  "  USE omp_lib",                                  -- 3
  "CONTAINS",                                       -- 4
  "  SUBROUTINE s(n, x)",                           -- 5
  "    INTEGER :: n, ierr, i",                      -- 6
  "    REAL :: x(n)",                               -- 7
  "    CHARACTER(LEN=30) :: t = 'MPI_INIT maxval'", -- 8  string literal
  "    ! comment: MPI_INIT maxval huge",            -- 9  whole-line comment
  "    CALL MPI_INIT(ierr)",                        -- 10
  "!$OMP PARALLEL DO PRIVATE(i)",                   -- 11
  "    x = huge(1.0) + maxval(x)   ! MPI_BARRIER",  -- 12 trailing comment
  "!$OMP END PARALLEL DO",                          -- 13
  "  END SUBROUTINE s",                             -- 14
  "END MODULE m",                                   -- 15
}

-- ---------------------------------------------------------------------------
-- The old path is gone
-- ---------------------------------------------------------------------------

test("no syntax match / matchadd left in the module", function()
  local src = table.concat(vim.fn.readfile(cfg .. "/lua/andrew/fortran/highlight.lua"), "\n")
  assert_nil(src:match("\n%s*vim%.cmd%(string%.format%(\n?%s*\"syntax match"),
    "a syntax match call survived")
  -- Only the header comment may mention them, and only as prose.
  for _, line in ipairs(vim.split(src, "\n")) do
    if not line:match("^%s*%-%-") then
      assert_false(line:match("matchadd") ~= nil, "matchadd in code: " .. line)
      assert_false(line:match("syntax%s+match") ~= nil, "syntax match in code: " .. line)
    end
  end
end)

test("the three groups link where the themes expect", function()
  assert_eq(vim.api.nvim_get_hl(0, { name = "FortranCustomKeyword" }).link, "Function")
  assert_eq(vim.api.nvim_get_hl(0, { name = "FortranMPIKeyword" }).link, "Constant")
  assert_eq(vim.api.nvim_get_hl(0, { name = "FortranOMPKeyword" }).link, "PreProc")
end)

-- ---------------------------------------------------------------------------
-- Word list
-- ---------------------------------------------------------------------------

test("words() comes from the registry: the library names, not the keywords", function()
  H.reset_words()
  local w = H.words()
  assert_eq(w.mpi_init, "FortranMPIKeyword")
  assert_eq(w.mpi_comm_world, "FortranMPIKeyword")
  assert_eq(w.omp_get_thread_num, "FortranOMPKeyword")
  assert_eq(w.omp_get_wtime, "FortranOMPKeyword")
  -- The registry's keyword file is for hover and completion. Colouring
  -- `program`, `integer` or `allocatable` is tree-sitter's job, and an
  -- extmark here would sit at priority 150 on top of its correct answer.
  assert_nil(w.allocatable, "a statement keyword is tree-sitter's to colour:")
  assert_nil(w.program, "a statement keyword is tree-sitter's to colour:")
  assert_nil(w.integer, "a statement keyword is tree-sitter's to colour:")
  -- Keys that can never match an identifier token.
  assert_nil(w["!$omp atomic"])
  assert_nil(w["!dir$"])
  assert_nil(w["=>"])
  assert_nil(w["omp barrier"])
  assert_nil(w["parallel_do"], "a multi-word directive key cannot match a token:")
end)

test("the snippet abbreviations that coloured ordinary variables are gone", function()
  -- omp-audit S3b. fortran-docs.json is generated from the VS Code snippets,
  -- so ~210 of its keys are abbreviations: `mat`, `dp`, `pi` are not Fortran
  -- names at all, and `count`/`flush` are intrinsics fortls documents. All of
  -- them are ordinary variable names in the project this config is aimed at.
  H.reset_words()
  local w = H.words()
  for _, name in ipairs({ "count", "mat", "dp", "pi", "flush", "maxval", "huge", "size", "sum" }) do
    assert_nil(w[name], "`" .. name .. "` must not be a coloured name:")
  end
end)

test("variables named count, mat and dp are not painted", function()
  local buf = fbuf({
    "SUBROUTINE s(n)",
    "  INTEGER :: count, mat(3), dp",
    "  count = 0",
    "  mat = dp",
    "  CALL MPI_INIT(ierr)",
    "  t = omp_get_wtime()",
    "!$OMP PARALLEL DO PRIVATE(i)",
    "END SUBROUTINE s",
  }, "fixhl_s3b.f90")
  H.paint(buf, 0, 8)
  assert_nil(group_of(buf, "count"), "`count` is an ordinary variable here:")
  assert_nil(group_of(buf, "mat"), "`mat` is an ordinary variable here:")
  assert_nil(group_of(buf, "dp"), "`dp` is an ordinary variable here:")
  assert_nil(group_of(buf, "INTEGER"), "a statement keyword is tree-sitter's to colour:")
  -- ...and the names that ARE documented still colour.
  assert_eq(group_of(buf, "MPI_INIT"), "FortranMPIKeyword", "MPI_INIT must still paint:")
  assert_eq(group_of(buf, "omp_get_wtime"), "FortranOMPKeyword", "omp_get_wtime must still paint:")
  assert_eq(group_of(buf, "PRIVATE"), "FortranOMPKeyword", "a clause on a directive line must paint:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- Painting, free form
-- ---------------------------------------------------------------------------

test("paint colours the MPI and OpenMP names, not the intrinsics", function()
  local buf = fbuf(FREE, "fixhl_free.f90")
  H.paint(buf, 0, 15)
  assert_eq(group_of(buf, "MPI_INIT"), "FortranMPIKeyword")
  assert_eq(group_of(buf, "omp_lib"), "FortranOMPKeyword")
  -- The intrinsics are fortls's; the registry holds none, so neither does this.
  assert_nil(group_of(buf, "maxval"), "`maxval` is an intrinsic fortls documents:")
  assert_nil(group_of(buf, "huge"), "`huge` is an intrinsic fortls documents:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("paint sits above tree-sitter's priority 100", function()
  local buf = fbuf(FREE, "fixhl_prio.f90")
  H.paint(buf, 0, 15)
  local _, m = group_of(buf, "MPI_INIT")
  assert_true(m ~= nil, "no MPI_INIT mark")
  assert_true(m.priority > 100, "priority must beat tree-sitter, got " .. tostring(m.priority))
  assert_eq(m.priority, H.PRIORITY)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("a keyword inside a comment or a string is not coloured", function()
  local buf = fbuf(FREE, "fixhl_cmt.f90")
  H.paint(buf, 0, 15)
  for _, m in ipairs(marks(buf)) do
    -- row 7 = the string literal, row 8 = the whole-line comment.
    assert_true(m.row ~= 7, "coloured inside a string literal: " .. m.text)
    assert_true(m.row ~= 8, "coloured inside a comment: " .. m.text)
    if m.row == 11 then
      -- the trailing `! MPI_BARRIER` on the same line as real code
      assert_true(m.col < 30, "coloured inside a trailing comment: " .. m.text)
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("OpenMP directive lines are painted, END is not", function()
  local buf = fbuf(FREE, "fixhl_omp.f90")
  H.paint(buf, 0, 15)
  local found = {}
  for _, m in ipairs(marks(buf)) do
    if m.row == 10 or m.row == 12 then
      assert_eq(m.group, "FortranOMPKeyword", "directive token in the wrong group: " .. m.text)
      found[m.text] = true
    end
  end
  assert_true(found["!$"], "the sentinel was not coloured")
  assert_true(found["OMP"], "OMP was not coloured")
  assert_true(found["PARALLEL"], "PARALLEL was not coloured")
  assert_true(found["DO"], "DO was not coloured")
  assert_true(found["PRIVATE"], "PRIVATE was not coloured")
  assert_nil(found["END"], "structural END should not be coloured")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- Painting, fixed form
-- ---------------------------------------------------------------------------

local FIXED = {
  "C     column-1 comment naming MPI_INIT and maxval",
  "*     star comment naming huge",
  "      PROGRAM P",
  "      CALL MPI_INIT(IERR)",
  "      X = maxval(A) ! trailing MPI_BARRIER",
  "C$OMP PARALLEL DO PRIVATE(I)",
  "      END",
}

test("fixed form: column-1 C/* comments are skipped, code is not", function()
  local buf = fbuf(FIXED, "fixhl_fixed.f")
  local scan = require("andrew.fortran.scan")
  assert_true(scan.is_fixed(buf), "precondition: .f must be detected as fixed form")
  H.paint(buf, 0, #FIXED)
  for _, m in ipairs(marks(buf)) do
    assert_true(m.row ~= 0, "coloured inside a column-1 C comment: " .. m.text)
    assert_true(m.row ~= 1, "coloured inside a column-1 * comment: " .. m.text)
  end
  assert_eq(group_of(buf, "MPI_INIT"), "FortranMPIKeyword")
  assert_nil(group_of(buf, "maxval"), "`maxval` is an intrinsic, not a registry name:")
  assert_nil(group_of(buf, "PROGRAM"), "a statement keyword is tree-sitter's to colour:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("fixed form: a C$OMP sentinel in column 1 is a directive", function()
  local buf = fbuf(FIXED, "fixhl_fixed2.f")
  H.paint(buf, 0, #FIXED)
  local g, m = group_of(buf, "C$")
  assert_eq(g, "FortranOMPKeyword", "the fixed-form sentinel was not coloured")
  assert_eq(m.row, 5)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("free-form masking of the same text WOULD have coloured the comment", function()
  -- Pins that the fixed-form branch is what does the work, not luck.
  local buf = fbuf(FIXED, "fixhl_asfree.f90")
  local scan = require("andrew.fortran.scan")
  assert_false(scan.is_fixed(buf), "precondition: .f90 is free form")
  H.paint(buf, 0, #FIXED)
  local hit = false
  for _, m in ipairs(marks(buf)) do
    if m.row == 0 then
      hit = true
    end
  end
  assert_true(hit, "free-form masking should treat the column-1 C line as code")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- Range discipline
-- ---------------------------------------------------------------------------

test("paint clears only the range it is given", function()
  local buf = fbuf(FREE, "fixhl_range.f90")
  H.paint(buf, 0, 15)
  local before = #marks(buf)
  assert_true(before > 3, "precondition: expected several marks, got " .. before)
  -- Repaint one line; everything outside it must survive.
  H.paint(buf, 9, 10)
  assert_eq(#marks(buf), before, "a single-line repaint changed the total")
  -- And a range with no keywords clears only its own lines.
  H.paint(buf, 0, 2)
  local after = #marks(buf)
  assert_true(after <= before, "clearing lines 1-2 must not add marks")
  assert_true(group_of(buf, "MPI_INIT") == "FortranMPIKeyword", "line 10 lost its mark")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("paint is idempotent", function()
  local buf = fbuf(FREE, "fixhl_idem.f90")
  H.paint(buf, 0, 15)
  local n = #marks(buf)
  H.paint(buf, 0, 15)
  H.paint(buf, 0, 15)
  assert_eq(#marks(buf), n, "repainting the same range duplicated marks")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- No parser: must not throw
-- ---------------------------------------------------------------------------

test("ts_skip returns nil with no fortran parser and paint still works", function()
  local buf = fbuf(FREE, "fixhl_nots.f90")
  local has_parser = pcall(vim.treesitter.get_parser, buf, "fortran")
  if not has_parser then
    assert_nil(H.ts_skip(buf, 0, 15), "ts_skip must answer nil without a parser")
  end
  -- Either way this must not raise.
  local ok, err = pcall(H.paint, buf, 0, 15)
  assert_true(ok, "paint raised: " .. tostring(err))
  assert_eq(group_of(buf, "MPI_INIT"), "FortranMPIKeyword")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("with a parser available, TS comment ranges are honoured", function()
  local parser_dir = vim.fn.stdpath("data") .. "/lazy/nvim-treesitter"
  if vim.fn.filereadable(parser_dir .. "/parser/fortran.so") == 0 then
    return -- parser not installed here; the masker path is covered above
  end
  vim.opt.runtimepath:append(parser_dir)
  local buf = fbuf(FREE, "fixhl_ts.f90")
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "fortran")
  if not ok or not parser then
    return
  end
  -- ts_skip deliberately never forces a parse (a dirty-tree reparse of a
  -- 5000-line Fortran file costs ~90 ms, i.e. one stutter per keystroke), so
  -- stand in for the tree-sitter highlighter, which keeps the tree current.
  parser:parse(true)
  local skip = H.ts_skip(buf, 0, 15)
  assert_true(skip ~= nil, "ts_skip answered nil with a parser present")
  assert_true(skip[8] ~= nil, "the whole-line comment was not reported as a skip range")
  H.paint(buf, 0, 15)
  for _, m in ipairs(marks(buf)) do
    assert_true(m.row ~= 8, "coloured inside a comment with TS active: " .. m.text)
  end
  assert_eq(group_of(buf, "MPI_INIT"), "FortranMPIKeyword")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

test("attach paints, is idempotent, and detach leaves nothing behind", function()
  local before = H.attached_count()
  local buf = fbuf(FREE, "fixhl_life.f90")
  vim.api.nvim_win_set_buf(0, buf)
  H.attach(buf)
  H.attach(buf) -- FileType can fire twice
  assert_true(H.attached(buf), "attach did not record the buffer")
  assert_eq(H.attached_count(), before + 1, "attaching twice registered twice")
  assert_eq(group_of(buf, "MPI_INIT"), "FortranMPIKeyword", "attach did not paint")

  H.detach(buf)
  assert_false(H.attached(buf), "detach did not clear the state")
  assert_eq(H.attached_count(), before, "detach leaked state")
  assert_eq(#marks(buf), 0, "detach left marks behind")
  assert_eq(vim.fn.exists("#FortranHighlightBuf" .. buf), 0, "detach left the augroup behind")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("an edit repaints just the changed lines", function()
  local buf = fbuf(FREE, "fixhl_edit.f90")
  vim.api.nvim_win_set_buf(0, buf)
  H.attach(buf)
  assert_nil(group_of(buf, "MPI_FINALIZE"), "precondition: no MPI_FINALIZE yet")
  vim.api.nvim_buf_set_lines(buf, 9, 10, false, { "    CALL MPI_FINALIZE(ierr)" })
  vim.wait(500, function()
    return group_of(buf, "MPI_FINALIZE") ~= nil
  end, 10)
  assert_eq(group_of(buf, "MPI_FINALIZE"), "FortranMPIKeyword", "the edited line was not repainted")
  -- The old token on that line is gone, and untouched lines kept their marks.
  assert_nil(group_of(buf, "MPI_INIT"), "the replaced text kept its stale mark")
  assert_eq(group_of(buf, "omp_lib"), "FortranOMPKeyword", "an untouched line lost its mark")
  H.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("a filetype change away from Fortran detaches", function()
  local buf = fbuf(FREE, "fixhl_ftchange.f90")
  vim.api.nvim_win_set_buf(0, buf)
  H.attach(buf)
  assert_true(H.attached(buf))
  vim.bo[buf].filetype = "text"
  assert_false(H.attached(buf), "a non-Fortran filetype must detach")
  assert_eq(#marks(buf), 0, "marks survived the filetype change")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("wiping the buffer detaches", function()
  local before = H.attached_count()
  local buf = fbuf(FREE, "fixhl_wipe.f90")
  vim.api.nvim_win_set_buf(0, buf)
  H.attach(buf)
  assert_eq(H.attached_count(), before + 1)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.wait(200, function()
    return H.attached_count() == before
  end, 10)
  assert_eq(H.attached_count(), before, "a wiped buffer leaked its state")
end)

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

test("toggle off unpaints and stops painting; toggle on restores", function()
  local buf = fbuf(FREE, "fixhl_toggle.f90")
  vim.api.nvim_win_set_buf(0, buf)
  H.attach(buf)
  local n = #marks(buf)
  assert_true(n > 0, "precondition: expected marks")

  assert_false(H.toggle(), "toggle should report off")
  assert_false(H.enabled())
  assert_eq(#marks(buf), 0, "toggle off left marks")
  H.paint(buf, 0, 15)
  assert_eq(#marks(buf), 0, "paint drew while disabled")

  assert_true(H.toggle(), "toggle should report on")
  assert_true(H.enabled())
  assert_eq(#marks(buf), n, "toggle on did not restore the marks")

  H.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.g.fortran_highlight = nil
end)

-- ---------------------------------------------------------------------------
-- Cost
-- ---------------------------------------------------------------------------

test("a viewport-sized paint on a 5000-line buffer stays well under 5ms", function()
  local unit = {
    "  SUBROUTINE sub(n, x, ierr)",
    "    INTEGER, INTENT(IN) :: n",
    "    REAL, INTENT(INOUT) :: x(n)",
    "    INTEGER :: ierr, rank, j",
    "    CHARACTER(LEN=40) :: note = 'MPI_INIT inside a literal maxval'",
    "    CALL MPI_COMM_RANK(MPI_COMM_WORLD, rank, ierr)",
    "    ! comment mentioning MPI_BARRIER maxval huge allocated",
    "!$OMP PARALLEL DO PRIVATE(j) SHARED(x)",
    "    DO j = 1, n",
    "      x(j) = x(j) + huge(1.0) * REAL(maxval(SHAPE(x)))",
    "    END DO",
    "!$OMP END PARALLEL DO",
    "    IF (allocated(x)) CALL MPI_BARRIER(MPI_COMM_WORLD, ierr)",
    "    PRINT *, size(x), omp_get_thread_num(), present(n)",
    "  END SUBROUTINE sub",
  }
  local lines = {}
  while #lines < 5000 do
    for _, l in ipairs(unit) do
      lines[#lines + 1] = l
    end
  end
  local buf = fbuf(lines, "fixhl_big.f90")

  -- 66 lines = a 50-row window plus the module's 8-line margin either side.
  H.paint(buf, 2000, 2066) -- warm
  local t0 = vim.uv.hrtime()
  local N = 50
  for _ = 1, N do
    H.paint(buf, 2000, 2066)
  end
  local ms = (vim.uv.hrtime() - t0) / 1e6 / N
  print(string.format("    viewport paint (66 lines of 5000): %.3f ms", ms))
  assert_true(ms < 5, string.format("viewport paint took %.3f ms (budget 5 ms)", ms))

  -- A one-line repaint is what typing costs.
  H.paint(buf, 2010, 2012)
  t0 = vim.uv.hrtime()
  for _ = 1, 200 do
    H.paint(buf, 2010, 2012)
  end
  local ms1 = (vim.uv.hrtime() - t0) / 1e6 / 200
  print(string.format("    single-line repaint (typing):      %.3f ms", ms1))
  assert_true(ms1 < 1, string.format("single-line repaint took %.3f ms (budget 1 ms)", ms1))

  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("ts_skip never forces a parse", function()
  -- THE PERF BUG THIS PINS: ts_skip used to call parser:parse({first, last}).
  -- On a 5000-line Fortran buffer with a dirty tree that measured 85-95 ms --
  -- paid on every keystroke, because every edit dirties the tree. It now reads
  -- the tree only while it is already valid for the rows in question.
  local parser_dir = vim.fn.stdpath("data") .. "/lazy/nvim-treesitter"
  if vim.fn.filereadable(parser_dir .. "/parser/fortran.so") == 0 then
    return
  end
  vim.opt.runtimepath:append(parser_dir)
  local buf = fbuf(FREE, "fixhl_noparse.f90")
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "fortran")
  if not ok or not parser then
    return
  end
  parser:parse(true)
  assert_true(H.ts_skip(buf, 0, 15) ~= nil, "precondition: a parsed tree must be used")
  -- Dirty the tree without letting anything re-parse it.
  vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "    INTEGER :: n, ierr, i, k" })
  assert_nil(H.ts_skip(buf, 0, 15), "ts_skip read (and so must have parsed) a dirty tree")
  -- The masker still answers, so nothing is lost but the second opinion.
  H.paint(buf, 0, 15)
  assert_eq(group_of(buf, "MPI_INIT"), "FortranMPIKeyword")
  for _, m in ipairs(marks(buf)) do
    assert_true(m.row ~= 8, "the masker failed to skip the comment: " .. m.text)
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("the viewport autocmds are global (WinScrolled cannot be buffer-local)", function()
  -- WinScrolled/WinResized match their pattern against the window ID, so a
  -- `buffer = bufnr` registration yields `<buffer=N>` and never fires. This
  -- pins that the module registers them globally instead.
  local before = H.attached_count()
  local buf = fbuf(FREE, "fixhl_view.f90")
  vim.api.nvim_win_set_buf(0, buf)
  H.attach(buf)
  local acs = vim.api.nvim_get_autocmds({ group = "FortranHighlightView", event = "WinScrolled" })
  assert_true(#acs > 0, "no global WinScrolled autocmd was registered")
  for _, ac in ipairs(acs) do
    assert_false(ac.buflocal, "WinScrolled must not be buffer-local (pattern: " .. tostring(ac.pattern) .. ")")
  end
  H.detach(buf)
  assert_eq(H.attached_count(), before)
  assert_eq(vim.fn.exists("#FortranHighlightView"), 0,
    "the global augroup outlived the last attached buffer")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

_H.finish()
