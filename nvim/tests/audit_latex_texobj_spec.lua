-- Regression spec for the LaTeX text objects in lua/andrew/utils/tex-motions.lua
-- and the shared math-autosnippet guard in lua/andrew/utils/tex.lua.
--
-- WHAT THIS PINS (all three were live bugs found by executing the maps)
--
--  1. `ie` must not swallow an environment's REQUIRED argument group.
--     tree-sitter-latex puts an OPTIONAL argument INSIDE the `begin` node
--     (`\begin{figure}[htbp]`) but leaves a REQUIRED one as a SIBLING of
--     `begin` (`\begin{tabular}` + `{c|c}`). inside_env started the inner range
--     at the end of `begin`, so `vie` on a tabular selected `{c|c}\n...` and
--     `die` destroyed the column spec.
--
--  2. `ac` / `ic` must work on the commands the grammar gives a dedicated node
--     type -- `\section{...}`, `\caption{...}` -- not only on `generic_command`.
--     They previously did nothing at all on `\section{Title}`, the most common
--     LaTeX command there is. `section` spans the WHOLE section body, so the
--     range must stop after the command's contiguous argument groups, and the
--     cursor must actually lie inside that range (otherwise `ac` in ordinary
--     prose would select the heading far above).
--
--  3. `ic` with the cursor on the command NAME (`\sec|tion{Title}`) falls back
--     to the command's first argument.
--
--  4. The short math autosnippets (`sum`, `lim`, `hat`, `vec`, `inv`, ...) are
--     also the TAIL of the readable `;latex-*` aliases. `-` is not in
--     'iskeyword', so `wordTrig` sees a word boundary right before `sum` in
--     `;latex-sum` and the autosnippet fired MID-TYPING, leaving
--     `;latex-\sum_{i=1}^{n} ` behind: the readable aliases were impossible to
--     type inside math. They must refuse while the token contains `;`, and must
--     still fire on a plain `sum`.
--
-- Run with: nvim --headless -u NONE -l tests/audit_latex_texobj_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
-- `-u NONE` leaves lazy.nvim's plugin dirs off the rtp: the latex parser lives
-- in nvim-treesitter's parser/ and the snippet engine is LuaSnip.
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/nvim-treesitter")
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/LuaSnip")
-- nvim-treesitter's plugin/ files (which map filetype tex -> parser latex) are
-- not sourced when the rtp is extended after startup, and vim.treesitter.get_node
-- resolves the language from the FILETYPE. Without this, get_node returns nil and
-- every text object silently no-ops.
vim.treesitter.language.register("latex", "tex")

local motions = require("andrew.utils.tex-motions")

local DOC = {
  [[\documentclass{article}]],
  [[\begin{document}]],
  [[\section{First Section}]],
  [[Plain prose with no command at all.]],
  [[\begin{tabular}{c|c}]],
  "\t1 & 2 \\\\",
  [[\end{tabular}]],
  "\\begin{figure}[htbp]",
  "\t\\caption{Cap}",
  [[\end{figure}]],
  [[Text with \textbf{bold text} inside.]],
  [[\end{document}]],
}

--- Fresh tex buffer with DOC, the motion maps registered, cursor at (row, col).
local function setup(row, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, DOC)
  vim.bo[buf].filetype = "tex"
  -- The ftplugin does not run under `-u NONE`; register the maps by hand.
  motions.setup()
  local parser = assert(vim.treesitter.get_parser(buf, "latex"), "no latex parser")
  parser:parse(true)
  vim.api.nvim_win_set_cursor(0, { row, col })
  return buf
end

--- Run a visual text object and return the selected text.
local function yank(row, col, keys)
  setup(row, col)
  vim.fn.setreg('"', "")
  vim.cmd("normal " .. keys .. "y")
  return vim.fn.getreg('"')
end

test("latex parser is available to the spec", function()
  assert_true(pcall(vim.treesitter.language.add, "latex"))
end)

-- ---------------------------------------------------------------------------
-- 1. `ie` and an environment argument group
-- ---------------------------------------------------------------------------

test("vie on \\begin{tabular}{c|c} excludes the column spec", function()
  local got = yank(6, 2, "vie")
  assert_eq(got, "\t1 & 2 \\\\")
  -- Discriminating: the pre-fix output started with the argument group.
  assert_false(got:find("{c|c}", 1, true) ~= nil, "inner range still contains {c|c}:")
end)

test("die on a tabular leaves \\begin{tabular}{c|c} intact", function()
  setup(6, 2)
  vim.cmd("normal die")
  assert_eq(vim.api.nvim_buf_get_lines(0, 4, 5, false)[1], [[\begin{tabular}{c|c}]])
end)

test("vie still excludes an OPTIONAL argument that lives inside `begin`", function()
  assert_eq(yank(9, 3, "vie"), "\t\\caption{Cap}")
end)

test("vae still selects the whole environment including its argument", function()
  assert_eq(yank(6, 2, "vae"), "\\begin{tabular}{c|c}\n\t1 & 2 \\\\\n\\end{tabular}")
end)

-- ---------------------------------------------------------------------------
-- 2./3. `ac` / `ic` beyond generic_command
-- ---------------------------------------------------------------------------

test("vac on \\section{...} selects just the command", function()
  assert_eq(yank(3, 12, "vac"), [[\section{First Section}]])
end)

test("vic inside \\section{...} selects the title", function()
  assert_eq(yank(3, 12, "vic"), "First Section")
end)

test("vic on the \\section command NAME still selects the title", function()
  assert_eq(yank(3, 4, "vic"), "First Section")
end)

test("vac / vic work on \\caption{...}", function()
  assert_eq(yank(9, 12, "vac"), [[\caption{Cap}]])
  assert_eq(yank(9, 12, "vic"), "Cap")
end)

test("vac / vic still work on a generic_command", function()
  assert_eq(yank(11, 22, "vac"), [[\textbf{bold text}]])
  assert_eq(yank(11, 22, "vic"), "bold text")
end)

test("vac in plain prose selects nothing (no enclosing command)", function()
  -- Line 4 sits inside the `section` node, whose range covers the whole body:
  -- without the containment test this returned the heading two lines above.
  local got = yank(4, 5, "vac")
  assert_eq(#got, 1, "expected the single char under the cursor, got: " .. vim.inspect(got))
end)

test("vic on \\begin{itemize}-style name groups is still refused", function()
  -- `\begin{...}` uses curly_group_text, and `ie`/`ae` own environments.
  local got = yank(5, 9, "vic")
  assert_eq(#got, 1, "expected no selection, got: " .. vim.inspect(got))
end)

-- ---------------------------------------------------------------------------
-- 4. math autosnippet `;`-alias guard
-- ---------------------------------------------------------------------------

local function sum_autosnippet()
  local _, autosnippets = require("andrew.utils.tex").math_snippets()
  for _, snip in ipairs(autosnippets) do
    if snip.trigger == "sum" then
      return snip
    end
  end
end

test("the short `sum` autosnippet exists", function()
  assert_true(sum_autosnippet() ~= nil)
end)

test("`sum` still expands on its own inside math", function()
  setup(6, 2) -- inside no math zone yet; put the cursor in one below
  vim.api.nvim_buf_set_lines(0, 5, 6, false, { "\t$sum$" })
  vim.treesitter.get_parser(0, "latex"):parse(true)
  vim.api.nvim_win_set_cursor(0, { 6, 5 })
  assert_true(sum_autosnippet():matches("\t$sum") ~= nil, "`sum` refused inside math:")
end)

test("`sum` refuses while a `;`-alias is being typed", function()
  setup(6, 2)
  vim.api.nvim_buf_set_lines(0, 5, 6, false, { "\t$;latex-sum$" })
  vim.treesitter.get_parser(0, "latex"):parse(true)
  vim.api.nvim_win_set_cursor(0, { 6, 12 })
  assert_eq(sum_autosnippet():matches("\t$;latex-sum"), nil,
    "`sum` still hijacks `;latex-sum` -- the readable alias cannot be typed")
end)

test("`sum` refuses outside math", function()
  setup(4, 5)
  assert_eq(sum_autosnippet():matches("Plain prose with sum"), nil)
end)

-- ---------------------------------------------------------------------------
-- 5. markdown math text objects (regex path, setup_markdown)
-- ---------------------------------------------------------------------------

local MD = {
  "# T",
  "",
  "A $a$ B $b$ C",
  "",
  "Esc \\$5 plain \\$6",
  "",
  "$$",
  "x = 1",
  "$$",
}

local function md_yank(row, col, keys)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, MD)
  vim.bo[buf].filetype = "markdown"
  motions.setup_markdown()
  vim.api.nvim_win_set_cursor(0, { row, col })
  vim.fn.setreg('"', "")
  vim.cmd("normal " .. keys .. "y")
  return vim.fn.getreg('"')
end

test("markdown am/im work with the cursor ON either `$`", function()
  -- "A $a$ B $b$ C": the `$` of the first zone are at cols 2 and 4.
  for _, col in ipairs({ 2, 3, 4 }) do
    assert_eq(md_yank(3, col, "vam"), "$a$", "vam at col " .. col .. ":")
    assert_eq(md_yank(3, col, "vim"), "a", "vim at col " .. col .. ":")
  end
  -- ... and the second zone is still picked correctly, not the first.
  for _, col in ipairs({ 8, 9, 10 }) do
    assert_eq(md_yank(3, col, "vam"), "$b$", "vam at col " .. col .. ":")
  end
end)

test("markdown am ignores escaped \\$ and plain prose", function()
  assert_eq(#md_yank(5, 6, "vam"), 1)
  assert_eq(#md_yank(3, 0, "vam"), 1)
  assert_eq(#md_yank(3, 6, "vam"), 1)
end)

test("markdown am/im work from the CLOSING `$$` line of a display block", function()
  assert_eq(md_yank(9, 0, "vam"), "$$\nx = 1\n$$")
  assert_eq(md_yank(9, 0, "vim"), "x = 1")
  -- and from the opening line / inside, which already worked
  assert_eq(md_yank(7, 1, "vam"), "$$\nx = 1\n$$")
  assert_eq(md_yank(8, 2, "vim"), "x = 1")
end)

_H.finish()
