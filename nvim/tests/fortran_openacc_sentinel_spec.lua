-- Spec for the OpenMP sentinel rule -- andrew.fortran.openmp.sentinel and the
-- three consumers that treat a directive line as a closed world.
--
-- THE BUG THIS PINS
--
-- `is_directive` matched `^%s*[!cC%*]%$` and stopped there, so ANY comment
-- whose first two bytes are `!$` was an OpenMP line. `!$` is not a reserved
-- prefix: `!$acc parallel loop` and `!$ACC DATA` are OpenACC, a different
-- standard with a different clause list, `!$dir` is somebody else's directive
-- and `!$x=1` is nothing at all. Three consumers then misfired on all of them:
--
--   * hover (lsp_hover step 2, "a directive line is a closed world") answered
--     the OpenMP documentation for PARALLEL on an OpenACC PARALLEL, whose
--     semantics are a different machine model;
--   * completion offered the OpenMP clause list in an OpenACC clause position,
--     so accepting one wrote a clause the OpenACC compiler rejects;
--   * the highlighter painted the sentinel and the words as OpenMP.
--
-- OpenMP 5.2 §3.2.2 spells both sentinels as TOKENS with a boundary after
-- them: `!$omp` (fixed form `C$OMP` / `*$OMP` in columns 1-5) followed by a
-- space or the fixed-form continuation character, and the conditional
-- sentinel `!$` followed by a space, a tab or the end of the line. Requiring
-- that boundary is what excludes every other vendor's `!$`-shaped sentinel.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "an OpenACC line is not an OpenMP line" fails the moment `sentinel`
--     goes back to a prefix test -- it is the whole defect, stated as a truth
--     table.
--   * "the conditional sentinel still counts" fails if the boundary rule is
--     tightened to `omp` only, which would silently drop `!$ tid = ...` --
--     the line whose meaning depends on -fopenmp and which is the easiest to
--     misread.
--   * "hover says nothing on an OpenACC line" fails if lsp_hover stops gating
--     step 2 on this predicate (it would document OpenMP's PARALLEL there).
--   * "completion offers no OpenMP clause on an OpenACC line" fails if
--     directive_context reintroduces its own sentinel regex.
--   * "the highlighter leaves an OpenACC line alone" fails if paint_directive
--     is called on anything this predicate rejects.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_openacc_sentinel_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_false, _H.assert_nil

local cfg = vim.fn.stdpath("config")
package.path = cfg .. "/lua/?.lua;" .. package.path

local omp = require("andrew.fortran.openmp")
local hover = require("andrew.fortran.lsp_hover")
local completion = require("andrew.fortran.lsp_completion")
local highlight = require("andrew.fortran.highlight")

-- ---------------------------------------------------------------------------
-- The truth table
-- ---------------------------------------------------------------------------

test("an OpenACC or vendor sentinel is not an OpenMP line", function()
  for _, line in ipairs({
    "!$acc parallel loop",
    "!$ACC DATA COPYIN(a)",
    "      !$acc end parallel",
    "!$accel loop",
    "!$dir no_side_effects",
    "C$DIR IVDEP",
    "!$x=1",
    "!$omp_get_wtime()",
    "!$ompx metadirective",
  }) do
    assert_false(omp.is_directive(line), "`" .. line .. "` is not OpenMP:")
    assert_nil(omp.sentinel(line), "`" .. line .. "` has no OpenMP sentinel:")
  end
end)

test("the OpenMP directive sentinel is recognised in both forms", function()
  for _, line in ipairs({
    "!$omp",
    "!$OMP PARALLEL",
    "!$omp parallel do private(i)",
    "      !$OMP END PARALLEL DO",
    "!$omp& reduction(+:s)",
    "c$omp parallel",
    "C$OMP PARALLEL DO",
    "*$omp barrier",
  }) do
    assert_eq(omp.sentinel(line), "directive", "`" .. line .. "` kind:")
    assert_true(omp.is_directive(line), "`" .. line .. "`:")
  end
end)

test("the conditional-compilation sentinel still counts as an OpenMP line", function()
  -- `!$ tid = omp_get_thread_num()` is live code under -fopenmp and a comment
  -- without it. The boundary after `!$` is a space, a tab or end of line.
  for _, line in ipairs({
    "!$",
    "!$ tid = omp_get_thread_num()",
    "!$\tnthreads = 4",
    "C$    nthreads = 4",
    "!$   omp parallel",
  }) do
    assert_eq(omp.sentinel(line), "conditional", "`" .. line .. "` kind:")
    assert_true(omp.is_directive(line), "`" .. line .. "`:")
  end
end)

test("the sentinel's byte offset is the `$`", function()
  local kind, send = omp.sentinel("      !$OMP PARALLEL")
  assert_eq(kind, "directive")
  assert_eq(send, 8, "1-based index of the `$`:")
  assert_eq(("      !$OMP PARALLEL"):sub(send, send), "$", "and it indexes a `$`:")
end)

-- ---------------------------------------------------------------------------
-- The three consumers
-- ---------------------------------------------------------------------------

test("hover says nothing on an OpenACC line", function()
  local line = "!$acc parallel loop"
  -- Column 7 is the `p` of `parallel` -- a word the OpenMP registry documents.
  assert_eq(line:sub(7, 14), "parallel", "the fixture moved:")
  assert_nil(hover.answer(line, 7), "OpenMP's PARALLEL was offered for OpenACC's:")
  assert_nil(hover.answer(line, 16), "OpenACC's `loop`:")
  assert_nil(hover.answer("!$ACC DATA COPYIN(a)", 6), "an uppercase OpenACC DATA:")
  -- ...while the OpenMP line one character different still answers.
  assert_true(hover.answer("!$omp parallel loop", 7) ~= nil, "OpenMP itself must still hover:")
end)

test("completion offers no OpenMP clause on an OpenACC line", function()
  local line = "!$acc parallel loop pri"
  local got = completion.items(line, 23, { trigger_kind = 2 })
  for _, it in ipairs(got) do
    assert_true(it.detail ~= "clause" and it.detail ~= "directive",
      "OpenMP syntax leaked onto an OpenACC line as " .. it.label .. ":")
  end
  -- An OpenACC line is a comment to a Fortran compiler, so nothing at all.
  assert_eq(#got, 0, "an OpenACC line is a comment and completes like one:")
  -- The `$` window does not fire there either.
  assert_eq(#completion.items("!$ac", 4, { trigger_kind = 2 }), 0, "the sentinel window on `!$ac`:")
  -- ...while the OpenMP line one character different still offers PRIVATE.
  local omp_items = completion.items("!$omp parallel do pri", 21, { trigger_kind = 2 })
  local found = false
  for _, it in ipairs(omp_items) do
    found = found or it.label == "PRIVATE(…)"
  end
  assert_true(found, "OpenMP itself must still offer its clauses:")
end)

test("the highlighter leaves an OpenACC line alone", function()
  highlight.setup_highlights()
  highlight.reset_words()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "!$acc parallel loop",
    "!$omp parallel do",
  })
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "_acc.f90")
  vim.bo[buf].filetype = "fortran"
  highlight.paint(buf, 0, 2)

  local acc, omp_row = 0, 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, highlight.namespace(), 0, -1, { details = true })) do
    if m[2] == 0 then
      acc = acc + 1
    else
      omp_row = omp_row + 1
    end
  end
  assert_eq(acc, 0, "an OpenACC line must carry no OpenMP extmark:")
  assert_true(omp_row >= 4, "the OpenMP line below it must still paint (got " .. omp_row .. "):")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

_H.finish()
