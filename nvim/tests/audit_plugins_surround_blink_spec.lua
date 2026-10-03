-- Spec for two audit fixes in lua/andrew/plugins/.
--
-- =============================================================================
-- 1) nvim-surround LaTeX `change.target` patterns (plugins/surround.lua)
-- =============================================================================
-- nvim-surround reads `change.target` as FOUR captures in the order
-- (text)(pos)(text)(pos) and derives each replaced region in
-- nvim-surround/patterns.lua get_selections() as:
--
--     first_pos = offset + pos - #text - 1
--     last_pos  = offset + pos - 2
--
-- i.e. "the #text bytes ending immediately BEFORE pos". The empty position
-- capture must therefore sit DIRECTLY after the text capture it belongs to.
-- Both LaTeX surrounds in this config had a literal brace wedged in between
-- (`...(.-)}()...` and `...(%a+){()...`), which slid both regions one byte to
-- the right, so `cs?e` / `cs?c` rewrote "temize}" instead of "itemize" and
-- "extbf{" instead of "textbf" -- silently corrupting the buffer:
--
--     \begin{itemize}stuff\end{itemize}  --csee-->  \begin{ialignstuff\end{ialign
--     \textbf{word}                      --cscc-->  \talignword
--
-- This spec re-implements that index arithmetic (it is pure string maths, no
-- buffer needed) and asserts the regions each pattern actually selects.
--
-- Discriminating power: restoring either old pattern makes the corresponding
-- "selects exactly the name" assertion fail with the off-by-one text.
--
-- =============================================================================
-- 2) blink.cmp per_filetype keys for Fortran (plugins/blink-cmp.lua)
-- =============================================================================
-- blink splits `vim.bo.filetype` on "." and looks each SEGMENT up in
-- sources.per_filetype (blink/cmp/sources/lib/init.lua:77), so a DOTTED key can
-- never be matched by anything. The config carried `["fortran.fixed"]` and
-- `["fortran.free"]`, which were therefore dead config, while every other
-- Fortran-aware module in this repo (andrew.lsp_filetypes,
-- andrew.fortran.lsp.FILETYPES, fortran/scan.lua, fortran/lsp_inlayhint.lua)
-- uses the underscore spellings. A buffer that really did come up as
-- `fortran_fixed` would have fallen back to sources.default and lost its
-- Fortran-specific source list.
--
-- Discriminating power: re-introducing a dotted key fails the "no dotted keys"
-- assertion; dropping either underscore key fails its provider-list assertion.
--
-- Run with: nvim --headless -u NONE -l tests/audit_plugins_surround_blink_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_deep_eq = _H.test, _H.assert_eq, _H.assert_true, _H.assert_deep_eq

local cfgdir = vim.fn.stdpath("config")

-- =============================================================================
-- nvim-surround index arithmetic, copied from patterns.lua get_selections()
-- =============================================================================

--- @return string left, string right  the byte ranges the pattern selects
local function selected(str, pattern)
  local ok, _, ltext, lpos, rtext, rpos = str:find(pattern)
  assert_true(ok ~= nil, "pattern must match " .. vim.inspect(str))
  assert_true(type(lpos) == "number", "2nd capture must be an empty position capture")
  assert_true(type(rpos) == "number", "4th capture must be an empty position capture")
  local offset = 1 -- the selection under test starts at byte 1 of `str`
  local llen = type(ltext) == "string" and #ltext or 0
  local rlen = type(rtext) == "string" and #rtext or 0
  return str:sub(offset + lpos - llen - 1, offset + lpos - 2),
    str:sub(offset + rpos - rlen - 1, offset + rpos - 2)
end

local surround = dofile(cfgdir .. "/lua/andrew/plugins/surround.lua")
local ENV = [[\begin{itemize}stuff\end{itemize}]]
local CMD = [[\textbf{word}]]

test("surround spec returns kylechui/nvim-surround with both LaTeX surrounds", function()
  assert_eq(surround[1], "kylechui/nvim-surround", "spec must point at kylechui/nvim-surround")
  assert_true(type(surround.opts.surrounds["e"]) == "table", "the LaTeX environment surround must exist")
  assert_true(type(surround.opts.surrounds["c"]) == "table", "the LaTeX command surround must exist")
end)

test("cs on a LaTeX environment replaces exactly the two environment names", function()
  local left, right = selected(ENV, surround.opts.surrounds["e"].change.target)
  assert_eq(left, "itemize", "left region must be the \\begin{} name only")
  assert_eq(right, "itemize", "right region must be the \\end{} name only")
end)

test("cs on a LaTeX command replaces exactly the command name", function()
  local left, right = selected(CMD, surround.opts.surrounds["c"].change.target)
  assert_eq(left, "textbf", "left region must be the command name only")
  -- `replacement` returns { { cmd }, { "" } }, matching nvim-surround's own `f`
  -- (function call) surround: only the identifier is rewritten.
  assert_eq(right, "", "right region must be empty, as replacement supplies \"\"")
end)

test("ds on a LaTeX environment still removes both whole delimiters", function()
  local left, right = selected(ENV, surround.opts.surrounds["e"].delete)
  assert_eq(left, [[\begin{itemize}]], "delete must take the whole \\begin{...}")
  assert_eq(right, [[\end{itemize}]], "delete must take the whole \\end{...}")
end)

test("ds on a LaTeX command still removes the opening and closing braces", function()
  local left, right = selected(CMD, surround.opts.surrounds["c"].delete)
  assert_eq(left, [[\textbf{]], "delete must take \\cmd{")
  assert_eq(right, "}", "delete must take the closing brace")
end)

-- =============================================================================
-- blink.cmp per_filetype keys
-- =============================================================================

local blink = dofile(cfgdir .. "/lua/andrew/plugins/blink-cmp.lua")
local per_ft = blink.opts.sources.per_filetype

test("blink spec returns saghen/blink.cmp with a per_filetype table", function()
  assert_eq(blink[1], "saghen/blink.cmp", "spec must point at saghen/blink.cmp")
  assert_true(type(per_ft) == "table", "sources.per_filetype must be a table")
end)

test("no per_filetype key contains a dot (blink splits filetype on '.')", function()
  for key in pairs(per_ft) do
    assert_true(not key:find(".", 1, true), "dotted per_filetype key can never match: " .. key)
  end
end)

test("every Fortran filetype variant gets the LSP source first", function()
  -- `fortran_docs` (andrew.fortran.blink-source) was retired: Fortran
  -- completion comes from the fortran-extras server now, which is the `lsp`
  -- source. See tests/audit_fortran_blink_source_spec.lua for the removal and
  -- tests/fortran_lsp_completion_spec.lua for what replaced it.
  local expected = { "lsp", "snippets", "path", "buffer" }
  for _, ft in ipairs({ "fortran", "fortran_free", "fortran_fixed", "f90", "f95" }) do
    assert_deep_eq(per_ft[ft], expected, "per_filetype." .. ft .. " must list lsp first")
  end
end)

test("the Fortran keys match the spellings the rest of the config uses", function()
  local lsp_fts = dofile(cfgdir .. "/lua/andrew/lsp_filetypes.lua")
  local known = {}
  for _, ft in ipairs(lsp_fts) do
    known[ft] = true
  end
  for _, ft in ipairs({ "fortran", "fortran_free", "fortran_fixed", "f90", "f95" }) do
    assert_true(known[ft], ft .. " must also be a filetype andrew.lsp_filetypes knows about")
  end
end)

test("markdown and the default list are untouched by the Fortran change", function()
  assert_deep_eq(blink.opts.sources.default, { "lsp", "path", "snippets", "buffer" }, "default sources")
  assert_deep_eq(per_ft.markdown, {
    "latex_math", -- LaTeX commands inside $...$ (latex_math_completion_spec.lua)
    "wikilinks",
    "vault_tags",
    "vault_frontmatter",
    "vault_inline_fields",
    "lsp",
    "snippets",
    "path",
    "buffer",
    "spell",
  }, "markdown sources")
end)

_H.finish({ style = "results", exit = "os" })
