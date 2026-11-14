-- Spec for the LaTeX math completion source:
--   lua/andrew/latex/symbols.lua       -- the 506-entry command table (data)
--   lua/andrew/latex/blink-source.lua  -- the blink.cmp provider over it
--   lua/andrew/plugins/blink-cmp.lua   -- the `latex_math` provider wiring
--
-- This is a FEATURE spec, not a bug spec. What each test pins:
--
-- THE CONTRACT (symbols.lua header)
--   * `cmd` required and UNIQUE, `kind` required and from the closed set --
--     the source maps `kind` to an LSP CompletionItemKind and falls back to
--     Text(1) for anything unknown, so a typo'd kind is silently mis-iconed.
--   * `body`/`label` carry their own leading `\`; `glyph` is the Unicode
--     rendering (1-2 chars -- combining accents are 2). A body or label that
--     lost its backslash would insert `frac{}{}` into the buffer.
--   * \sum \prod \int \lim have NO `body`: this config's LuaSnip autosnippets
--     (luasnippets/, via utils/tex.math_snippets) own their limits, and a
--     second set from the completion source would double up.
--   * Bodies are LSP snippets, expanded by LuaSnip (blink's configured
--     preset). The escaping rules in the symbols.lua header are subtle --
--     `\}` collapses to `}` under the LSP grammar, so a literal `\right\}`
--     needs `\\}` in snippet text, and a LaTeX `\\` line break needs `\\\\`.
--     Test 4 expands four representative bodies through the REAL engine and
--     asserts the resulting buffer text, which is the only way to catch a
--     backslash that the grammar eats.
--
-- THE SOURCE (blink-source.lua)
--   * `command_start` only fires on a `\`-prefixed token and refuses the
--     second `\` of a `\\` line break.
--   * items carry `filterText` WITHOUT the backslash (blink's Rust matcher
--     hard-codes the keyword charset to [\w-], so after `\al` the keyword is
--     `al`), and a `textEdit` spanning from the `\` to the cursor so accepting
--     replaces the typed `\` instead of producing `\\alpha`. Test 11 applies
--     the edit for real to prove it.
--   * fresh item tables per query: blink stamps `score_offset`/`cursor_column`
--     onto every item it is handed (sources/lib/provider/list.lua), so cached
--     tables would accumulate the provider's +12 -- the exact bug pinned in
--     audit_fortran_blink_source_spec.lua.
--
-- Discriminating power:
--   * Make `get_items()` return its cache directly -> test 10 fails.
--   * Drop the `pos > 1` `\\` guard in command_start -> test 5 fails.
--   * Put `\` back into `filterText`, or widen the textEdit range -> tests 8
--     and 11 fail.
--   * Give \sum a `body` -> test 3 fails; drop a backslash from a body ->
--     tests 2 and 4 fail.
--   * Change the snippet preset away from luasnip -> test 12 fails (the
--     bodies were verified against that engine and no other).
--
-- Drives the REAL data, the REAL source, the REAL LuaSnip and the REAL
-- treesitter latex parser.
--
-- Run with: nvim --headless -u NONE -l tests/latex_math_completion_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil
local assert_false, assert_match = _H.assert_false, _H.assert_match

local cfg = vim.fn.stdpath("config")
local lazy_root = vim.fn.stdpath("data") .. "/lazy"

vim.opt.runtimepath:prepend(lazy_root .. "/nvim-treesitter") -- latex/markdown parsers
vim.opt.runtimepath:prepend(lazy_root .. "/LuaSnip")
vim.opt.runtimepath:prepend(cfg)
package.path = cfg .. "/lua/?.lua;" .. package.path

local symbols = require("andrew.latex.symbols")
local source = require("andrew.latex.blink-source")
local src = source.new({})

local by_cmd = {}
for _, e in ipairs(symbols) do
  by_cmd[e.cmd] = e
end

local function by_label(items, label)
  for _, it in ipairs(items) do
    if it.label == label then
      return it
    end
  end
  return nil
end

local function complete(ctx)
  local res
  src:get_completions(ctx, function(r)
    res = r
  end)
  assert_true(res ~= nil, "get_completions never called back")
  return res
end

-- ---------------------------------------------------------------------------
-- 1-3. the data contract
-- ---------------------------------------------------------------------------

local KINDS = {
  greek = true,
  letterlike = true,
  operator = true,
  bigop = true,
  relation = true,
  arrow = true,
  delimiter = true,
  accent = true,
  ["function"] = true,
  structure = true,
  font = true,
  spacing = true,
  environment = true,
  misc = true,
}

test("symbols.lua is a non-empty array of {cmd, kind} with unique cmds", function()
  assert_eq(type(symbols), "table")
  assert_true(#symbols > 0, "symbol table is empty:")
  assert_eq(#symbols, vim.tbl_count(symbols), "array part must hold every entry (stray string key?):")
  local seen = {}
  for i, e in ipairs(symbols) do
    assert_eq(type(e.cmd), "string", "entry " .. i .. " has a non-string cmd:")
    assert_true(#e.cmd > 0, "entry " .. i .. " has an empty cmd:")
    assert_false(e.cmd:find("\\", 1, true), "cmd " .. e.cmd .. " must NOT carry the leading backslash:")
    assert_true(KINDS[e.kind], "entry " .. e.cmd .. " has kind " .. vim.inspect(e.kind) .. " outside the closed set:")
    assert_nil(seen[e.cmd], "duplicate cmd " .. e.cmd .. " (entries " .. tostring(seen[e.cmd]) .. " and " .. i .. ")")
    seen[e.cmd] = i
  end
end)

test("optional fields obey their shapes: body/label keep the backslash, glyph is 1-2 chars", function()
  for _, e in ipairs(symbols) do
    if e.body ~= nil then
      assert_eq(type(e.body), "string", e.cmd .. ": body")
      assert_eq(e.body:sub(1, 1), "\\", e.cmd .. ": body must start with a backslash:")
    end
    if e.label ~= nil then
      assert_eq(type(e.label), "string", e.cmd .. ": label")
      assert_eq(e.label:sub(1, 1), "\\", e.cmd .. ": label must start with a backslash:")
    end
    if e.glyph ~= nil then
      assert_eq(type(e.glyph), "string", e.cmd .. ": glyph")
      local n = vim.fn.strchars(e.glyph)
      assert_true(n >= 1 and n <= 2, e.cmd .. ": glyph must be 1-2 characters, got " .. n .. ":")
    end
    if e.aliases ~= nil then
      assert_eq(type(e.aliases), "table", e.cmd .. ": aliases")
      assert_true(#e.aliases > 0, e.cmd .. ": empty aliases list:")
      assert_eq(#e.aliases, vim.tbl_count(e.aliases), e.cmd .. ": aliases must be a list:")
      for _, a in ipairs(e.aliases) do
        assert_eq(type(a), "string", e.cmd .. ": alias entry")
      end
    end
    if e.doc ~= nil then
      assert_eq(type(e.doc), "string", e.cmd .. ": doc")
    end
  end
end)

test("spot-check glyphs, and the big operators stay body-less", function()
  local want = {
    alpha = "α",
    varepsilon = "ε",
    epsilon = "ϵ",
    leq = "≤",
    to = "→",
    sum = "∑",
    infty = "∞",
    emptyset = "∅",
  }
  for cmd, glyph in pairs(want) do
    local e = by_cmd[cmd]
    assert_true(e ~= nil, "\\" .. cmd .. " is missing from the table:")
    assert_eq(e.glyph, glyph, "\\" .. cmd .. " glyph:")
  end
  -- The LuaSnip autosnippets own the limits on these.
  for _, cmd in ipairs({ "sum", "prod", "int", "lim" }) do
    local e = by_cmd[cmd]
    assert_true(e ~= nil, "\\" .. cmd .. " is missing from the table:")
    assert_nil(e.body, "\\" .. cmd .. " must stay a plain symbol (the autosnippets add the limits):")
  end
end)

-- ---------------------------------------------------------------------------
-- 4. bodies really expand, through the engine blink is configured with
-- ---------------------------------------------------------------------------

test("snippet bodies expand through LuaSnip into valid LaTeX", function()
  local ls = require("luasnip")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)

  local function expand(cmd)
    local e = by_cmd[cmd]
    assert_true(e ~= nil and e.body ~= nil, "\\" .. cmd .. " has no body to expand:")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("startinsert")
    ls.lsp_expand(e.body)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    ls.unlink_current()
    return lines
  end

  assert_eq(table.concat(expand("frac"), "\n"), "\\frac{}{}", "\\frac body:")

  -- `\}` would collapse to a bare `}` under the LSP snippet grammar, so the
  -- body has to spell it `\\}`. Exactly one backslash must survive in front
  -- of each brace.
  assert_eq(table.concat(expand("leftbrace"), "\n"), "\\left\\{\\right\\}", "\\left\\{ \\right\\} body:")

  local pm = expand("pmatrix")
  local text = table.concat(pm, "\n")
  assert_true(text:find("\\begin{pmatrix}", 1, true) ~= nil, "pmatrix body lost its \\begin:")
  assert_true(text:find("\\end{pmatrix}", 1, true) ~= nil, "pmatrix body lost its \\end:")
  local rows = 0
  for _, l in ipairs(pm) do
    -- a LaTeX line break: exactly two backslashes at end of line
    if l:match("[^\\]\\\\$") then
      rows = rows + 1
    end
  end
  assert_eq(rows, 1, "pmatrix must end its first row with a ` \\\\` line break:")

  local cs = table.concat(expand("cases"), "\n")
  assert_true(cs:find("\\begin{cases}", 1, true) ~= nil, "cases body lost its \\begin:")
  assert_true(cs:find("\\end{cases}", 1, true) ~= nil, "cases body lost its \\end:")
  assert_true(cs:find("\\text{if }", 1, true) ~= nil, "cases body lost its \\text{if }:")

  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- 5-6. the pure helpers
-- ---------------------------------------------------------------------------

test("command_start finds the `\\` that opens the token under the cursor", function()
  assert_eq(source.command_start("x = \\al", 7), 4, "partial command:")
  assert_eq(source.command_start("x = \\", 5), 4, "bare trigger backslash:")
  assert_nil(source.command_start("x = al", 6), "a bare word is not a command:")
  assert_nil(source.command_start("a \\\\ b", 4), "the second `\\` of a `\\\\` line break:")
  assert_eq(source.command_start("\\alpha + \\be", 12), 9, "the LAST command on the line:")
end)

test("`\\` is the trigger character", function()
  local trig = src:get_trigger_characters()
  assert_eq(#trig, 1, "exactly one trigger character:")
  assert_eq(trig[1], "\\", "trigger character:")
end)

-- ---------------------------------------------------------------------------
-- 7. enabled(): filetype + math zone
-- ---------------------------------------------------------------------------

test("enabled() is math-zone gated in markdown and unconditional in tex", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "prose \\alpha here",
    "$x = \\al$",
    "$$",
    "\\fr",
    "$$",
  })
  vim.bo[buf].filetype = "markdown"
  -- Nothing parses the buffer for us in a `-l` process.
  pcall(function()
    vim.treesitter.get_parser(buf):parse(true)
  end)

  vim.api.nvim_win_set_cursor(0, { 1, 12 })
  assert_false(src:enabled(), "prose `\\alpha` outside math must NOT offer completions:")

  vim.api.nvim_win_set_cursor(0, { 2, 8 })
  assert_true(src:enabled(), "inside inline `$...$`:")

  vim.api.nvim_win_set_cursor(0, { 4, 3 })
  assert_true(src:enabled(), "inside a `$$` display block:")

  vim.bo[buf].filetype = "tex"
  assert_true(src:enabled(), "a .tex buffer is math-enabled everywhere:")

  vim.bo[buf].filetype = "lua"
  assert_false(src:enabled(), "never in a non-prose filetype:")

  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ---------------------------------------------------------------------------
-- 8-11. get_completions
-- ---------------------------------------------------------------------------

test("get_completions after `\\al` offers the whole table, shaped for blink", function()
  local res = complete({ line = "$x = \\al$", cursor = { 2, 8 } })
  assert_eq(#res.items, #symbols, "one item per symbol:")
  assert_false(res.is_incomplete_forward, "the list is complete -- blink must not refetch per keystroke:")

  local alpha = by_label(res.items, "\\alpha")
  assert_true(alpha ~= nil, "`\\alpha` is not offered:")
  -- blink's Rust matcher strips the `\` from the keyword, so the filter text
  -- must not carry it either.
  assert_eq(alpha.filterText, "alpha", "filterText must be the bare command:")
  assert_eq(alpha.labelDetails.description, "α", "the glyph is the label description:")
  assert_eq(alpha.insertTextFormat, 1, "a plain symbol is PlainText:")
  assert_eq(alpha.textEdit.newText, "\\alpha", "inserts the COMMAND, not the glyph:")
  assert_eq(alpha.textEdit.range.start.line, 1, "0-based row from cursor[1]:")
  assert_eq(alpha.textEdit.range.start.character, 5, "range starts at the typed `\\`:")
  assert_eq(alpha.textEdit.range["end"].line, 1, "single-line edit:")
  assert_eq(alpha.textEdit.range["end"].character, 8, "range ends at the cursor:")

  local frac = by_label(res.items, "\\frac{}{}")
  assert_true(frac ~= nil, "`\\frac` is not offered:")
  assert_eq(frac.insertTextFormat, 2, "an entry with a body is a Snippet:")
  assert_eq(frac.textEdit.newText:sub(1, 6), "\\frac{", "the snippet body is the insert text:")

  -- aliases are searchable
  local infty = by_label(res.items, "\\infty")
  assert_true(infty ~= nil, "`\\infty` is not offered:")
  assert_match(infty.filterText, "infinity", "aliases must be folded into filterText:")
  assert_match(infty.filterText, "^infty", "the command still leads the filter text:")
end)

test("get_completions offers nothing when the token is not `\\`-prefixed", function()
  local res = complete({ line = "$x = al$", cursor = { 2, 7 } })
  assert_eq(#res.items, 0, "bare words belong to the LuaSnip autosnippets:")
  assert_false(res.is_incomplete_forward)
end)

test("each query hands out fresh item tables (blink mutates what it is given)", function()
  local first = complete({ line = "$\\al$", cursor = { 1, 4 } }).items
  local second = complete({ line = "$\\al$", cursor = { 1, 4 } }).items
  assert_eq(#first, #second)
  for i = 1, #first do
    assert_true(first[i] ~= second[i], "item " .. i .. " is the SAME table in two rounds:")
  end
  -- Exactly what sources/lib/provider/list.lua:append does with the
  -- provider's score_offset = 12.
  for _, it in ipairs(first) do
    it.score_offset = (it.score_offset or 0) + 12
    it.cursor_column = it.cursor_column or 4
  end
  local third = complete({ line = "$\\al$", cursor = { 1, 4 } }).items
  for _, it in ipairs(third) do
    it.score_offset = (it.score_offset or 0) + 12
  end
  assert_eq(by_label(third, "\\alpha").score_offset, 12, "the provider offset accumulated across rounds:")
  assert_nil(by_label(third, "\\alpha").cursor_column, "cursor_column from an earlier round is stuck to the item:")
end)

test("applying the textEdit replaces the typed `\\` instead of doubling it", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# t", "$x = \\al$" })
  local res = complete({ line = "$x = \\al$", cursor = { 2, 8 } })
  local alpha = by_label(res.items, "\\alpha")
  vim.lsp.util.apply_text_edits({ alpha.textEdit }, buf, "utf-8")
  assert_eq(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], "$x = \\alpha$", "accepted completion:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("resolve returns the item unchanged", function()
  local out
  src:resolve({ label = "sentinel" }, function(item)
    out = item
  end)
  assert_eq(out.label, "sentinel")
end)

-- ---------------------------------------------------------------------------
-- 12. the blink.cmp wiring
-- ---------------------------------------------------------------------------

test("blink-cmp.lua wires latex_math first in markdown and tex", function()
  local spec = dofile(cfg .. "/lua/andrew/plugins/blink-cmp.lua")
  local opts = spec.opts
  local p = opts.sources.providers.latex_math
  assert_true(p ~= nil, "the latex_math provider is gone:")
  assert_eq(p.module, "andrew.latex.blink-source", "provider module:")
  assert_eq(p.min_keyword_length, 0, "a bare `\\` must list everything:")
  assert_eq(opts.sources.per_filetype.markdown[1], "latex_math", "markdown source order:")
  assert_eq(opts.sources.per_filetype.tex[1], "latex_math", "tex source order:")
  -- The bodies in symbols.lua were verified against this engine and no other.
  assert_eq(opts.snippets.preset, "luasnip", "snippet engine:")
end)

_H.finish({ style = "results" })
