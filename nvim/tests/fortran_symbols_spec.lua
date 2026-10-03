-- Spec for lua/andrew/fortran/symbols.lua and the symbol-key dispatcher in
-- lua/andrew/fortran/init.lua.
--
-- Rows are laid out the way fzf-lua lays out LSP document symbols -- location
-- first, then the symbol -- as nbsp-separated fields, of which the picker
-- hides the first with `--with-nth 2..`:
--
--   code/solver.f90:12:17:<nbsp>  12:17<nbsp>[<glyph> Call] Heating
--   \____________________/        \_____/  \_____________________/
--     parsed, never shown          shown         shown + matched
--
-- Every part of that is load-bearing.
--
-- Field 1 is what fzf-lua's path.entry_to_file reads, and it is the only
-- reason the builtin previewer, <CR>-to-jump and select-to-quickfix work on a
-- list this config built by hand rather than on rg output. Break it and the
-- picker still opens, still looks right, and silently jumps nowhere. Its
-- TRAILING COLON terminates the column number; without it entry_to_file reads
-- the column as 0.
--
-- `--nth 2` scopes matching to the symbol -- indices count fields of the
-- `--with-nth` view, so field 2 there is field 3 here. Letting the whole row
-- into the match was a real bug: with the path, the line number and the source
-- line in scope, a query like "dift" fuzzy-matched a subsequence spread across
-- `code/physics.f90` and `function`, and every real hit was buried.
--
-- The other half is de-duplication. Three scans feed one list and they overlap
-- by construction: `subroutine Heating(t)` is found by the definition scan AND
-- by the `NAME(` scan, `call Heating(t)` by the call scan AND the `NAME(`
-- scan. Without precedence every definition would appear twice, tagged
-- inconsistently.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "searchable field" fails if anything but the kind and the name gets into
--     the matched field -- the regression that caused the over-matching report.
--   * "field one" fails if the path/lnum/col prefix changes shape, INCLUDING
--     its trailing colon.
--   * "the visible location leads the row" fails if the layout goes back to
--     symbol-first, or if the workspace picker stops showing which file a row
--     is in.
--   * "the picker hides field one" fails if --with-nth goes (the raw location
--     shows up in the list) or if --nth stops pointing at the symbol -- the
--     two indices count different things and have to agree.
--   * "separator" fails if it stops being the character fzf-lua splits on.
--   * "definition outranks a bare reference" fails if PRECEDENCE is dropped --
--     duplicate rows, and half of them tagged [ref].
--   * "call outranks a bare reference" likewise.
--   * "a declaration outranks a call" fails if the var/arg/common tier is
--     dropped from PRECEDENCE -- a COMMON member declared on a line that also
--     names a procedure would flip tags between runs.
--   * "declaration tags survive into the searchable field" fails if tag()
--     stops passing the new kinds through, which is what makes typing `var`
--     or `common` filter the picker to declarations.
--   * "sorted by path then line then column" fails if the sort goes.
--   * "paths are shortened against the root" fails if the prefix strip goes.
--   * "enter is bound" fails if `actions` goes back to a bare function --
--     fzf-lua normalizes it by indexing, so a function leaves the picker with
--     NO enter binding and <CR> silently does nothing (a real, reported bug).
--   * "the kind block is styled like an LSP symbol" fails if the glyph, the
--     colour or the bracket wrapper stops being read from fzf-lua's own
--     lsp.symbols config -- which is what makes a Fortran row and a
--     basedpyright row look the same.
--   * "columns line up under colour and glyphs" fails if padding is measured
--     in bytes: escape sequences and multi-byte glyphs both break it.
--   * "nested symbols are indented" fails if the depth is dropped.
--   * "a colorscheme change drops the cached styles" fails if the ColorScheme
--     autocmd goes -- rows keep the old theme's colours for the session.
--   * "dispatcher" fails if the Fortran branch is removed and the keys fall
--     back to the LSP picker -- the regression that reintroduces the original
--     complaint (definitions only, no call sites).
--
-- Run with: nvim --headless -u NONE -l tests/fortran_symbols_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_deep_eq, assert_match = _H.assert_deep_eq, _H.assert_match
local assert_nil, assert_false = _H.assert_nil, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local symbols = require("andrew.fortran.symbols")

local ROOT = "/proj"
local SEP = symbols.separator()

--- The full row the reported query used to match: path + source text together
--- do contain d-i-f-t as a subsequence, which is precisely why matching has to
--- be scoped to field 1.
local function entries_line_for_dift()
  return "[function] energy    code/physics.f90:9:20:real(8) function energy(t)"
end

--- Split an entry into its nbsp-separated fields.
---   1 the machine-readable `path:lnum:col:` that entry_to_file parses
---   2 the location as displayed
---   3 the symbol: kind block and name
---   4 the source line, on the pickers that show one
local function split(entry)
  return vim.split(entry, SEP, { plain = true })
end

--- The searchable field: the symbol.
local function fields(entry)
  return split(entry)[3]
end

--- The hidden field entry_to_file reads.
local function location(entry)
  return split(entry)[1]
end

local function rec(path, lnum, col, name, kind, text)
  return {
    path = ROOT .. "/" .. path,
    lnum = lnum,
    col = col,
    name = name,
    lname = name:lower(),
    kind = kind,
    text = text,
  }
end

-- ---------------------------------------------------------------------------

test("the separator is the character fzf-lua splits entries on", function()
  local ok, utils = pcall(require, "fzf-lua.utils")
  if ok then
    assert_eq(SEP, utils.nbsp, "read from fzf-lua so the two cannot drift:")
  else
    assert_eq(SEP, "\226\128\130", "U+2002 EN SPACE, fzf-lua's value, as the fallback:")
  end
end)

test("the searchable field holds the tag and the name, and nothing else", function()
  -- This is the whole point of the two-field layout. A path, a line number or
  -- a word from the source line leaking in here is what made a query like
  -- "dift" match `code/physics.f90` + `function` and bury the real hits.
  local searchable = fields(symbols.build_entries({
    rec("code/physics.f90", 12, 8, "Heating", "call", "  call    Heating(t) ! diffuse"),
  }, ROOT)[1])

  assert_eq(vim.trim(searchable), "[Call] Heating")
  assert_nil(searchable:find("physics", 1, true), "no path:")
  assert_nil(searchable:find("f90", 1, true), "no extension:")
  assert_nil(searchable:find("12", 1, true), "no line number:")
  assert_nil(searchable:find("diffuse", 1, true), "no source text:")
  assert_nil(searchable:find("/", 1, true), "no path separator:")

  -- The reported query, against the entry that used to match it.
  local subsequence = function(needle, haystack)
    local i = 1
    for c in needle:gmatch(".") do
      i = haystack:find(c, i, true)
      if not i then return false end
      i = i + 1
    end
    return true
  end
  assert_false(subsequence("dift", searchable:lower()),
    "'dift' must not be a subsequence of the searched field:")
  assert_true(subsequence("dift", entries_line_for_dift()),
    "...even though it still is one of the full row, which is why --nth matters:")
end)

test("field one is the machine-readable path:lnum:col:", function()
  local entry = symbols.build_entries({
    rec("code/a.f90", 12, 8, "Heating", "call", "  call    Heating(t)"),
  }, ROOT)[1]

  local path, lnum, col, rest = location(entry):match("^(.-):(%d+):(%d+):(.*)$")
  assert_eq(path, "code/a.f90", "fzf-lua parses the path off the front of this field:")
  assert_eq(lnum, "12")
  assert_eq(col, "8", "the column points at the name, so <CR> lands on it:")
  -- The trailing colon is load-bearing: entry_to_file splits this field on ":"
  -- and reads the third part, so without it the column runs into the next
  -- field and comes back as 0.
  assert_eq(rest, "", "and it ends with a colon, terminating the column:")
end)

test("the visible location leads the row, and the path only when asked", function()
  local plain = split(symbols.build_entries({
    rec("code/a.f90", 12, 8, "Heating", "call", "  call Heating(t)"),
  }, ROOT)[1])
  assert_eq(vim.trim(plain[2]), "12:8", "the document picker shows line and column alone:")
  assert_nil(plain[2]:find("a.f90", 1, true), "and no path -- every row is the same file:")

  local with_path = split(symbols.build_entries({
    rec("code/a.f90", 12, 8, "Heating", "call", "  call Heating(t)"),
  }, ROOT, nil, { show_path = true })[1])
  assert_eq(vim.trim(with_path[2]), "code/a.f90:12:8", "the workspace picker leads with the path:")
end)

test("the source line appears only on the picker that asks for one", function()
  local without = split(symbols.build_entries({
    rec("a.f90", 1, 3, "Foo", "call", "      call Foo(x)      "),
  }, ROOT)[1])
  assert_eq(#without, 3, "symbol pickers carry no source column:")

  local with = split(symbols.build_entries({
    rec("a.f90", 1, 3, "Foo", "call", "      call Foo(x)      "),
  }, ROOT, nil, { source_column = true })[1])
  assert_eq(with[4], "call Foo(x)", "and the references picker trims the one it shows:")
end)

test("the location column is padded to a common width", function()
  local entries = symbols.build_entries({
    rec("a.f90", 1, 1, "Short", "call", "call Short"),
    rec("a.f90", 200, 17, "Other", "call", "call Other"),
  }, ROOT)
  assert_eq(#split(entries[1])[2], #split(entries[2])[2], "symbol columns line up:")
  assert_match(split(entries[1])[2], "^%s+1:1$", "a short line number is right-aligned:")
end)

test("the symbol column is padded to a common width, capped", function()
  local entries = symbols.build_entries({
    rec("a.f90", 1, 1, "Short", "call", "call Short"),
    rec("a.f90", 2, 1, "Moderately_Longer_Name", "call", "call Moderately_Longer_Name"),
  }, ROOT, nil, { source_column = true })
  assert_eq(#fields(entries[1]), #fields(entries[2]), "source columns line up:")

  -- One absurd name must not push every other row off the screen: the padding
  -- is capped, so short rows stay short even next to a 70-character symbol.
  local huge = ("X"):rep(70)
  local capped = symbols.build_entries({
    rec("a.f90", 1, 1, "Short", "call", "call Short"),
    rec("a.f90", 2, 1, huge, "call", "call " .. huge),
  }, ROOT, nil, { source_column = true })
  assert_true(#fields(capped[1]) <= 48,
    "short rows stay within the cap: got " .. #fields(capped[1]))
  assert_true(#fields(capped[2]) > 48, "and the long row is not truncated, only unpadded:")
end)

test("a definition outranks a bare reference at the same position", function()
  -- `subroutine Heating(t)` is found twice: once as a definition, once by the
  -- `NAME(` scan. One row must survive, tagged as the definition.
  local entries = symbols.build_entries({
    rec("a.f90", 4, 12, "Heating", "ref", "subroutine Heating(t)"),
    rec("a.f90", 4, 12, "Heating", "subroutine", "subroutine Heating(t)"),
  }, ROOT)
  assert_eq(#entries, 1, "no duplicate row:")
  assert_match(fields(entries[1]), "%[Subroutine%]")
end)

test("a call outranks a bare reference at the same position", function()
  local entries = symbols.build_entries({
    rec("a.f90", 9, 8, "Heating", "ref", "  call Heating(t)"),
    rec("a.f90", 9, 8, "Heating", "call", "  call Heating(t)"),
  }, ROOT)
  assert_eq(#entries, 1)
  assert_match(fields(entries[1]), "%[Call%]")
end)

test("a declaration outranks a call at the same position", function()
  -- Declarations sit between definitions and call sites: a name is declared
  -- once and used many times, so the declaration is the row worth keeping.
  local entries = symbols.build_entries({
    rec("a.f90", 3, 22, "dift", "call", "COMMON/DIFFST/ dift"),
    rec("a.f90", 3, 22, "dift", "var", "COMMON/DIFFST/ dift"),
  }, ROOT)
  assert_eq(#entries, 1, "no duplicate row:")
  assert_match(fields(entries[1]), "%[Variable%]")
end)

test("declaration tags survive into the searchable field", function()
  -- Variables are why the workspace picker answers a query like `dift` at all;
  -- the tag is in the matched field so `var`, `arg` or `common` narrows to them.
  local entries = symbols.build_entries({
    rec("h.h", 1, 14, "DIFFST", "common", "COMMON/DIFFST/ dift"),
    rec("h.h", 1, 22, "dift", "var", "COMMON/DIFFST/ dift"),
    rec("a.f90", 2, 18, "nnode", "arg", "SUBROUTINE Solve(nnode)"),
  }, ROOT)
  local tags = {}
  for _, entry in ipairs(entries) do
    tags[#tags + 1] = fields(entry):gsub("%s+$", "")
  end
  table.sort(tags)
  _H.assert_deep_eq(tags, { "[Argument] nnode", "[Common] DIFFST", "[Variable] dift" })
end)

test("a variable reference ranks below everything else", function()
  -- The declaration of `dift` is also, textually, an occurrence of `dift`.
  -- One row must survive, and it must be the declaration.
  local entries = symbols.build_entries({
    rec("h.h", 1, 22, "dift", "varref", "COMMON/DIFFST/ dift"),
    rec("h.h", 1, 22, "dift", "var", "COMMON/DIFFST/ dift"),
  }, ROOT)
  assert_eq(#entries, 1, "no duplicate row:")
  assert_match(fields(entries[1]), "%[Variable%]")
end)

test("the picker binds enter to the file action", function()
  -- Reported bug: <CR> did nothing. `actions` was a bare function, and
  -- fzf-lua normalizes actions by indexing the value, so the picker ended up
  -- with no enter binding at all.
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/code", "p")
  vim.fn.writefile({ "      SUBROUTINE Step()", "      END SUBROUTINE Step" },
    root .. "/code/p.f90")

  local saved_fzf = package.loaded["fzf-lua"]
  local saved_utils = package.loaded["fzf-lua.utils"]
  local jump = function() end
  local captured
  package.loaded["fzf-lua"] = {
    fzf_exec = function(entries, opts) captured = { entries = entries, opts = opts } end,
    actions = { file_edit_or_qf = jump },
  }
  package.loaded["fzf-lua.utils"] = {
    nbsp = SEP,
    ansi_from_hl = function(_, str) return str end,
    ansi_escseq = { clear = "" },
  }

  local cwd = vim.uv.cwd()
  vim.fn.chdir(root .. "/code")
  local ok, err = pcall(function()
    symbols.references("Step")
    assert_true(vim.wait(10000, function() return captured ~= nil end), "picker never opened")
  end)
  vim.fn.chdir(cwd)
  package.loaded["fzf-lua"] = saved_fzf
  package.loaded["fzf-lua.utils"] = saved_utils
  vim.fn.delete(root, "rf")
  if not ok then
    error(err, 0)
  end

  assert_eq(type(captured.opts.actions), "table", "actions must be a table, not a function:")
  assert_eq(captured.opts.actions.enter, jump, "and enter must be bound to the file action:")
end)

--- Open a picker in a throwaway project with fzf-lua stubbed out, and hand
--- back what it would have passed to fzf.
local function capture_picker(source, open)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/code", "p")
  vim.fn.writefile(source, root .. "/code/p.f90")

  local saved_fzf = package.loaded["fzf-lua"]
  local saved_utils = package.loaded["fzf-lua.utils"]
  local captured
  package.loaded["fzf-lua"] = {
    fzf_exec = function(entries, opts) captured = { entries = entries, opts = opts } end,
    actions = { file_edit_or_qf = function() end },
  }
  package.loaded["fzf-lua.utils"] = {
    nbsp = SEP,
    ansi_from_hl = function(_, str) return str end,
    ansi_escseq = { clear = "" },
  }

  local cwd = vim.uv.cwd()
  vim.fn.chdir(root .. "/code")
  local ok, err = pcall(function()
    open()
    assert_true(vim.wait(15000, function() return captured ~= nil end), "picker never opened")
  end)
  vim.fn.chdir(cwd)
  package.loaded["fzf-lua"] = saved_fzf
  package.loaded["fzf-lua.utils"] = saved_utils
  symbols._reset_style_cache()
  vim.fn.delete(root, "rf")
  if not ok then
    error(err, 0)
  end
  return captured
end

test("the picker hides field one and matches the symbol field", function()
  local captured = capture_picker({
    "      SUBROUTINE Step(nnode)",
    "      REAL*8 dift",
    "      dift = nnode",
    "      END SUBROUTINE Step",
  }, symbols.workspace)

  assert_eq(captured.opts.fzf_opts["--with-nth"], "2..", "field one is never displayed:")
  assert_eq(captured.opts.fzf_opts["--nth"], "2", "and matching is scoped to one view field:")

  -- The two indices have to agree: --nth counts fields of the --with-nth VIEW,
  -- so "2" there must land on the symbol, which is field 3 of the entry.
  local entry = captured.entries[1]
  local view = entry:gsub("^.-" .. SEP, "", 1)
  local view_fields = vim.split(view, SEP, { plain = true })
  assert_eq(view_fields[2], split(entry)[3], "--nth 2 of the view is the symbol:")
  assert_match(view_fields[2], "%[%a+%] %a", "which is a kind block and a name:")
  assert_nil(view_fields[2]:find("p.f90", 1, true), "and carries no path to fuzzy-match:")
end)

-- LSP-style presentation --------------------------------------------------

--- Run `fn` with a stubbed fzf-lua symbol config in place, then restore.
local function with_symbol_config(cfg, fn)
  local saved_config = package.loaded["fzf-lua.config"]
  local saved_utils = package.loaded["fzf-lua.utils"]
  package.loaded["fzf-lua.config"] = { globals = { lsp = { symbols = cfg } } }
  package.loaded["fzf-lua.utils"] = {
    nbsp = SEP,
    ansi_from_hl = function(hl, str)
      return hl == "@function" and ("<" .. hl .. ">" .. str .. "</>") or str
    end,
  }
  local ok, err = pcall(fn)
  package.loaded["fzf-lua.config"] = saved_config
  package.loaded["fzf-lua.utils"] = saved_utils
  symbols._reset_style_cache()
  if not ok then
    error(err, 0)
  end
end

local STUB_CFG = {
  symbol_style = 1,
  symbol_icons = { Function = "F", Variable = "V", Method = "M" },
  symbol_hl = function(kind) return "@" .. kind:lower() end,
  symbol_fmt = function(str) return "[" .. str .. "]" end,
  child_prefix = true,
}

test("the kind block is styled like an LSP symbol", function()
  -- Glyph, colour and bracket all come out of the user's own lsp.symbols
  -- config, so a Fortran row and a basedpyright row are drawn the same way.
  with_symbol_config(STUB_CFG, function()
    local block = symbols.kind_block({ kind = "subroutine" })
    assert_eq(block.plain, "[F Subroutine]", "glyph from symbol_icons, name from Fortran:")
    assert_eq(block.styled, "[<@function>F Subroutine</>]", "colour from symbol_hl:")
    assert_eq(block.width, #"[F Subroutine]", "width is of the PLAIN text:")

    -- A kind the colorscheme paints nothing for falls back rather than going
    -- grey: the stub only colours @function.
    assert_eq(symbols.kind_block({ kind = "call" }).styled,
      "[<@function>M Call</>]", "the Method glyph, coloured via the @function fallback:")
  end)
end)

test("a colorscheme change drops the cached styles", function()
  -- The kind block is memoized per kind, and the invalidation is an autocmd
  -- rather than a key recomputed per row -- reading the colorscheme name and
  -- formatting a table address twenty thousand times cost 1.5 seconds on the
  -- workspace picker. Without the autocmd the picker keeps painting the old
  -- theme's colours for the rest of the session.
  --
  -- The config table is mutated IN PLACE rather than swapped, so nothing but
  -- the autocmd can be what refreshes the cache.
  local saved_config = package.loaded["fzf-lua.config"]
  local saved_utils = package.loaded["fzf-lua.utils"]
  local icons = { Function = "F", Variable = "V", Method = "M" }
  package.loaded["fzf-lua.utils"] = {
    nbsp = SEP,
    ansi_from_hl = function(_, str) return str end,
    ansi_escseq = { clear = "" },
  }
  package.loaded["fzf-lua.config"] = {
    globals = { lsp = { symbols = vim.tbl_extend("force", STUB_CFG, { symbol_icons = icons }) } },
  }
  symbols._reset_style_cache()

  local ok, err = pcall(function()
    assert_eq(symbols.kind_block({ kind = "subroutine" }).plain, "[F Subroutine]")
    icons.Function = "NEW"
    assert_eq(symbols.kind_block({ kind = "subroutine" }).plain, "[F Subroutine]",
      "the block stays memoized while nothing has changed:")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    assert_eq(symbols.kind_block({ kind = "subroutine" }).plain, "[NEW Subroutine]",
      "and the autocmd is what drops it:")
  end)

  package.loaded["fzf-lua.config"] = saved_config
  package.loaded["fzf-lua.utils"] = saved_utils
  symbols._reset_style_cache()
  if not ok then
    error(err, 0)
  end
end)

test("columns line up under colour and glyphs", function()
  with_symbol_config(STUB_CFG, function()
    local entries = symbols.build_entries({
      rec("a.f90", 1, 1, "x", "subroutine", "subroutine x"),
      rec("a.f90", 2, 1, "a_much_longer_name", "var", "integer :: a_much_longer_name"),
    }, ROOT, nil, { source_column = true })
    local widths = {}
    for _, entry in ipairs(entries) do
      local searchable = fields(entry)
      -- Measure what is DRAWN: strip the colour, count cells.
      widths[#widths + 1] = vim.fn.strdisplaywidth((searchable:gsub("<[@/][^>]*>", "")))
    end
    assert_eq(widths[1], widths[2], "both searchable fields occupy the same cells:")
    assert_true(entries[1]:find("<@function>", 1, true) ~= nil, "and one of them is coloured:")
  end)
end)

test("nested symbols are indented under their container", function()
  with_symbol_config(STUB_CFG, function()
    local top = rec("a.f90", 1, 12, "Solve", "subroutine", "subroutine Solve()")
    local inner = rec("a.f90", 2, 14, "n", "var", "  integer :: n")
    inner.depth = 1
    local entries = symbols.build_entries({ top, inner }, ROOT)
    assert_match(fields(entries[1]), "^%[", "the container starts at column one:")
    assert_match(fields(entries[2]), "^  %[", "its member is indented by child_prefix:")
  end)
end)

test("distinct positions on one line are kept apart", function()
  local entries = symbols.build_entries({
    rec("a.f90", 5, 7, "Energy", "ref", "  y = Energy(x) + Energy(z)"),
    rec("a.f90", 5, 20, "Energy", "ref", "  y = Energy(x) + Energy(z)"),
  }, ROOT)
  assert_eq(#entries, 2, "two call sites, two rows:")
end)

test("entries are sorted by path, then line, then column", function()
  local entries = symbols.build_entries({
    rec("z.f90", 1, 1, "C", "call", "call C"),
    rec("a.f90", 9, 5, "B", "call", "call B"),
    rec("a.f90", 9, 1, "A", "call", "call A"),
    rec("a.f90", 2, 1, "D", "call", "call D"),
  }, ROOT)
  local order = {}
  for _, entry in ipairs(entries) do
    order[#order + 1] = location(entry):match("^(.-:%d+:%d+):")
  end
  assert_deep_eq(order, { "a.f90:2:1", "a.f90:9:1", "a.f90:9:5", "z.f90:1:1" })
end)

test("paths are shortened against the project root", function()
  local entries = symbols.build_entries({ rec("code/sub/a.f90", 1, 1, "A", "call", "call A") }, ROOT)
  assert_match(location(entries[1]), "^code/sub/a%.f90:")

  -- A path outside the root is left absolute rather than mangled.
  local outside = symbols.build_entries({
    { path = "/elsewhere/b.f90", lnum = 1, col = 1, name = "B", lname = "b", kind = "call", text = "call B" },
  }, ROOT)
  assert_match(location(outside[1]), "^/elsewhere/b%.f90:")
end)

test("display text falls back to the buffer lines when a record carries none", function()
  local entries = symbols.build_entries({
    { path = ROOT .. "/a.f90", lnum = 2, col = 8, name = "Foo", lname = "foo", kind = "call" },
  }, ROOT, function()
    return { "first", "  call Foo(x)" }
  end, { source_column = true })
  assert_eq(split(entries[1])[4], "call Foo(x)")
end)

test("is_fortran covers every Fortran filetype this config uses", function()
  for _, ft in ipairs({ "fortran", "fortran_free", "fortran_fixed" }) do
    assert_true(symbols.is_fortran(ft), ft .. " must be recognised")
  end
  for _, ft in ipairs({ "lua", "python", "c", "" }) do
    assert_true(not symbols.is_fortran(ft), ft .. " must not be")
  end
end)

-- ---------------------------------------------------------------------------
-- Keymap dispatcher
-- ---------------------------------------------------------------------------

test("the symbol keys use the Fortran picker in Fortran, the LSP picker elsewhere", function()
  local calls = {}
  package.loaded["andrew.fortran.symbols"] = {
    is_fortran = symbols.is_fortran,
    document = function() calls[#calls + 1] = "fortran:document" end,
    workspace = function() calls[#calls + 1] = "fortran:workspace" end,
  }
  package.loaded["fzf-lua"] = {
    lsp_document_symbols = function() calls[#calls + 1] = "lsp:document" end,
    lsp_live_workspace_symbols = function() calls[#calls + 1] = "lsp:workspace" end,
  }
  package.loaded["andrew.fortran"] = nil
  local fortran = require("andrew.fortran")

  vim.bo.filetype = "fortran"
  fortran.symbol_picker("document")()
  fortran.symbol_picker("workspace")()

  vim.bo.filetype = "lua"
  fortran.symbol_picker("document")()
  fortran.symbol_picker("workspace")()

  assert_deep_eq(calls, {
    "fortran:document", "fortran:workspace",
    "lsp:document", "lsp:workspace",
  })

  package.loaded["andrew.fortran.symbols"] = nil
  package.loaded["fzf-lua"] = nil
  package.loaded["andrew.fortran"] = nil
end)

_H.finish()
