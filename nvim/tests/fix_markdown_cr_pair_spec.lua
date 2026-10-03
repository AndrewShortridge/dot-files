-- Regression spec: <CR> between an empty bracket pair on a markdown list line.
--
-- Bug (audit2 §4.3): on a list line with the cursor between a pair autopairs had
-- just inserted -- `- x (|)`, `- [ ] z [|]`, `1. y {|}` -- <CR> hit
-- list-continuation's mid-line SPLIT branch and produced
--     - x (
--     - )
-- i.e. a bogus second bullet. On a prose line the same keys correctly gave
-- autopairs' pair expansion (`foo(` / empty line / `)`).
--
-- Fix: cr_action() now checks, before any list logic, whether the cursor sits
-- directly between an opener and its matching closer for a bracket rule
-- nvim-autopairs actually has live in this buffer, and if so delegates <CR> to
-- the mapping captured by make_cr_fallback() plus a trailing <Cmd> fixup that
-- re-indents the two produced lines to the list item's CONTENT column.
--
-- Everything else must stay byte-identical, so the list-continuation cases from
-- the auditor's 28-case <CR> suite are asserted here too.
--
-- Run with: nvim --headless -u NONE -l tests/fix_markdown_cr_pair_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_deep_eq = _H.test, _H.assert_eq, _H.assert_true, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local lc = require("andrew.utils.list-continuation")

vim.o.shiftwidth = 2
vim.o.tabstop = 2
vim.o.expandtab = true
-- Normal mode clamps the cursor to the last character; the <CR> handler cares
-- about the difference between "col == #line" (continue) and "col < #line"
-- (split), so let the cursor sit one past the end like insert mode does.
vim.o.virtualedit = "onemore"

-- ---------------------------------------------------------------------------
-- nvim-autopairs stub
-- ---------------------------------------------------------------------------
-- cr_action() reads `package.loaded["nvim-autopairs"]` (never require()s it) and
-- asks it for (a) the buffer's live rule list and (b) whether autopairs_cr()
-- would really expand. Both are stubbed so the spec needs no plugin.
local AP_EXPAND = vim.api.nvim_replace_termcodes(
  "<c-g>u<CR><CMD>normal! ====<CR><up><end><CR>",
  true,
  false,
  true
)
local PLAIN_CR = "\r"

local function rule(start_pair, end_pair, extra)
  return vim.tbl_extend("force", { start_pair = start_pair, end_pair = end_pair }, extra or {})
end

--- The default rule set nvim-autopairs installs for a markdown buffer, reduced
--- to the fields cr_action() looks at.
local function default_rules()
  return {
    rule("(", ")"),
    rule("[", "]"),
    rule("{", "}"),
    rule('"', '"'),
    rule("'", "'"),
    rule("`", "`"),
    rule("```", "```"),
    rule("```.*$", "```", { is_regex = true }),
  }
end

local ap = {}
local function install_autopairs(rules, cr_result)
  ap.rules = rules
  ap.cr_result = cr_result == nil and AP_EXPAND or cr_result
  package.loaded["nvim-autopairs"] = {
    get_buf_rules = function()
      return ap.rules
    end,
    autopairs_cr = function()
      return ap.cr_result
    end,
  }
end

local function uninstall_autopairs()
  package.loaded["nvim-autopairs"] = nil
end

-- ---------------------------------------------------------------------------
-- Drivers
-- ---------------------------------------------------------------------------

local function md_buf(lines, row, col)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_win_set_cursor(0, { row, col })
  return buf
end

--- Run cr_action() with a recording fallback. Returns
---   handled  -- true when cr_action did the edit itself (returned "")
---   fed      -- everything the returned delegate pushed into the typeahead
---   called   -- whether the captured autopairs fallback was invoked
local function cr(lines, row, col)
  md_buf(lines, row, col)
  local called = false
  local fallback = function()
    called = true
  end
  local result = lc.cr_action(fallback)
  local fed = {}
  if type(result) == "function" then
    local real = vim.api.nvim_feedkeys
    vim.api.nvim_feedkeys = function(keys, mode, escape)
      fed[#fed + 1] = keys
      return nil, mode, escape
    end
    local ok, err = pcall(result)
    vim.api.nvim_feedkeys = real
    assert(ok, err)
  end
  return {
    handled = result == "",
    -- A delegate is a NEW closure wrapping the fallback; returning the fallback
    -- object itself is the plain "not my line" fall-through.
    delegated = type(result) == "function" and result ~= fallback,
    fell_through = result == fallback,
    fallback_called = called,
    fed = table.concat(fed),
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
    cursor = vim.api.nvim_win_get_cursor(0),
  }
end

--- The list-continuation result as `line|line|line`, for the byte-identical
--- regression cases (cr_action does those edits itself and returns "").
local function cr_text(lines, row, col)
  local r = cr(lines, row, col)
  assert_true(r.handled, "expected cr_action to handle this line itself")
  return table.concat(r.lines, "|")
end

-- ---------------------------------------------------------------------------
-- 1. The fix: pair expansion wins on a list line
-- ---------------------------------------------------------------------------

install_autopairs(default_rules())

test("`- x (|)` delegates to the autopairs fallback instead of splitting", function()
  local r = cr({ "- x ()" }, 1, 5)
  assert_true(r.delegated, "cr_action should return a delegate")
  assert_true(r.fallback_called, "the captured autopairs fallback must run")
  -- The buffer is untouched by cr_action itself: autopairs' keys do the edit.
  assert_deep_eq(r.lines, { "- x ()" })
end)

test("the queued fixup re-indents to the list item's content column", function()
  -- `- x ` -> content column 2
  local r = cr({ "- x ()" }, 1, 5)
  assert_true(r.fed:find('_indent_pair_expansion("  ", ")")', 1, true) ~= nil, r.fed)
end)

test("content column is per-marker: ordered, task, nested, bare item", function()
  local function prefix_of(lines, row, col)
    local fed = cr(lines, row, col).fed
    return fed:match('_indent_pair_expansion%("([^"]*)"')
  end
  assert_eq(prefix_of({ "1. y {}" }, 1, 6), "   ", "`1. ` -> 3")
  assert_eq(prefix_of({ "- [ ] z []" }, 1, 9), "      ", "`- [ ] ` -> 6")
  assert_eq(prefix_of({ "  - a ()" }, 1, 7), "    ", "`  - ` -> 4")
  assert_eq(prefix_of({ "- ()" }, 1, 3), "  ", "bare `- ` item -> 2")
  assert_eq(prefix_of({ "> q ()" }, 1, 5), "> ", "blockquote keeps its marker")
  assert_eq(prefix_of({ "> - b ()" }, 1, 7), ">   ", "bullet in a quote keeps `> ` + bullet width")
end)

test("a tab-indented item keeps the tab and pads only the marker", function()
  local fed = cr({ "\t- a ()" }, 1, 6).fed
  -- string.format("%q") renders a tab as the escape `\9`, so build the needle
  -- the same way the handler does instead of hand-writing the escape.
  local needle = "_indent_pair_expansion(" .. string.format("%q", "\t  ")
  assert_true(fed:find(needle, 1, true) ~= nil, fed)
end)

test("all three bracket pairs delegate", function()
  assert_true(cr({ "- x ()" }, 1, 5).delegated, "()")
  assert_true(cr({ "- x []" }, 1, 5).delegated, "[]")
  assert_true(cr({ "- x {}" }, 1, 5).delegated, "{}")
end)

test("quotes and backticks are NOT delegated (prose typing / endwise rules)", function()
  assert_eq(cr_text({ '- x ""' }, 1, 5), '- x "|- "')
  assert_eq(cr_text({ "- x ''" }, 1, 5), "- x '|- '")
  assert_eq(cr_text({ "- x ``" }, 1, 5), "- x `|- `")
end)

test("a bracket that is not empty (`(a|)`, `(|a)`) still uses the list logic", function()
  assert_eq(cr_text({ "- x (a)" }, 1, 6), "- x (a|- )")
  assert_eq(cr_text({ "- x (a)" }, 1, 5), "- x (|- a)")
end)

test("mismatched brackets are not a pair", function()
  assert_eq(cr_text({ "- x (]" }, 1, 5), "- x (|- ]")
  assert_eq(cr_text({ "- x [)" }, 1, 5), "- x [|- )")
end)

test("an opener at the end of the line is not a pair", function()
  assert_eq(cr_text({ "- x (" }, 1, 5), "- x (|- ")
end)

test("a closer with no opener in front of it is not a pair", function()
  assert_eq(cr_text({ "- )x" }, 1, 2), "- |- )x")
end)

test("the pair check runs before the split AND before the empty-bullet branch", function()
  -- `- ()` has non-empty content ("()"), so it must delegate, not be emptied.
  local r = cr({ "- ()" }, 1, 3)
  assert_true(r.delegated)
  assert_deep_eq(r.lines, { "- ()" })
end)

-- ---------------------------------------------------------------------------
-- 2. Gates: no autopairs, no delegation
-- ---------------------------------------------------------------------------

test("autopairs not loaded -> the old list behaviour", function()
  uninstall_autopairs()
  assert_eq(cr_text({ "- x ()" }, 1, 5), "- x (|- )")
  install_autopairs(default_rules())
end)

test("autopairs attached but the bracket rule was removed -> no delegation", function()
  install_autopairs({ rule('"', '"'), rule("`", "`") })
  assert_eq(cr_text({ "- x ()" }, 1, 5), "- x (|- )")
  install_autopairs(default_rules())
end)

test("a regex rule with the same start_pair does not count", function()
  install_autopairs({ rule("(", ")", { is_regex = true }) })
  assert_eq(cr_text({ "- x ()" }, 1, 5), "- x (|- )")
  install_autopairs(default_rules())
end)

test("autopairs_cr() declining (disabled buffer / can_cr veto) -> no delegation", function()
  install_autopairs(default_rules(), PLAIN_CR)
  assert_eq(cr_text({ "- x ()" }, 1, 5), "- x (|- )")
  install_autopairs(default_rules())
end)

test("list continuation toggled off -> plain fallback, no fixup", function()
  md_buf({ "- x ()" }, 1, 5)
  vim.b.list_continuation_enabled = false
  local fb = function() end
  assert_eq(lc.cr_action(fb), fb, "cr_action must return the fallback untouched")
  vim.b.list_continuation_enabled = nil
end)

-- ---------------------------------------------------------------------------
-- 3. _indent_pair_expansion()
-- ---------------------------------------------------------------------------

--- Put the buffer in the exact shape autopairs' expansion leaves behind, with
--- the cursor on the blank middle line, then run the fixup.
local function run_fixup(lines, row, prefix, closer)
  md_buf(lines, row, 0)
  -- The fixup arrives as a <Cmd> key in insert mode. `:startinsert` does not
  -- take effect until the main loop runs, so fake the mode read instead.
  local real_get_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function()
    return { mode = "i", blocking = false }
  end
  local ok, err = pcall(lc._indent_pair_expansion, prefix, closer)
  vim.api.nvim_get_mode = real_get_mode
  assert(ok, err)
  return { vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.api.nvim_win_get_cursor(0) }
end

test("the fixup indents the blank middle line and the closer line", function()
  local got = run_fixup({ "- x (", "", ")" }, 2, "  ", ")")
  assert_deep_eq(got[1], { "- x (", "  ", "  )" })
  assert_deep_eq(got[2], { 2, 2 })
end)

test("the fixup carries text that was after the cursor along", function()
  local got = run_fixup({ "- x (", "", ") tail" }, 2, "  ", ")")
  assert_deep_eq(got[1], { "- x (", "  ", "  ) tail" })
end)

test("`[[|]]` on a list line: the `]]` line is indented too", function()
  -- The matched rule is the single-char `[`/`]` one, but the line below holds
  -- `]]` because the wikilink pair is two characters wide.
  local got = run_fixup({ "- [[", "", "]]" }, 2, "  ", "]")
  assert_deep_eq(got[1], { "- [[", "  ", "  ]]" })
end)

test("the fixup bails out when the expansion is not the expected shape", function()
  -- Middle line is not blank (a custom map_cr_func produced something else).
  local got = run_fixup({ "- x (", "junk", ")" }, 2, "  ", ")")
  assert_deep_eq(got[1], { "- x (", "junk", ")" })
  -- No line below at all.
  local got2 = run_fixup({ "- x (", "" }, 2, "  ", ")")
  assert_deep_eq(got2[1], { "- x (", "" })
  -- Line below is not the closer.
  local got3 = run_fixup({ "- x (", "", "other" }, 2, "  ", ")")
  assert_deep_eq(got3[1], { "- x (", "", "other" })
end)

test("the fixup is a no-op outside insert mode", function()
  md_buf({ "- x (", "", ")" }, 2, 0)
  lc._indent_pair_expansion("  ", ")")
  assert_deep_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "- x (", "", ")" })
end)

-- ---------------------------------------------------------------------------
-- 4. Byte-identical regression: the auditor's list-continuation <CR> cases
-- ---------------------------------------------------------------------------

test("list continuation at end of line is unchanged", function()
  assert_eq(cr_text({ "- item" }, 1, 6), "- item|- ")
  assert_eq(cr_text({ "1. item" }, 1, 7), "1. item|2. ")
  assert_eq(cr_text({ "- [ ] task" }, 1, 10), "- [ ] task|- [ ] ")
  assert_eq(cr_text({ "- [x] done" }, 1, 10), "- [x] done|- [ ] ")
  assert_eq(cr_text({ "> quote" }, 1, 7), "> quote|> ")
  assert_eq(cr_text({ "* star" }, 1, 6), "* star|* ")
  assert_eq(cr_text({ "+ plus" }, 1, 6), "+ plus|+ ")
  assert_eq(cr_text({ "3) paren" }, 1, 8), "3) paren|4) ")
  assert_eq(cr_text({ "> - b" }, 1, 5), "> - b|> - ")
  assert_eq(cr_text({ "> > deep" }, 1, 8), "> > deep|> > ")
  assert_eq(cr_text({ "- top", "  - sub" }, 2, 7), "- top|  - sub|  - ")
  assert_eq(cr_text({ "  - deep" }, 1, 8), "  - deep|  - ")
end)

test("empty bullets are still removed / de-indented", function()
  assert_eq(cr_text({ "- " }, 1, 2), "")
  assert_eq(cr_text({ "1. " }, 1, 3), "")
  assert_eq(cr_text({ "- [ ] " }, 1, 6), "")
  assert_eq(cr_text({ "> " }, 1, 2), "")
  assert_eq(cr_text({ "> - " }, 1, 4), "> ")
  assert_eq(cr_text({ "- item", "  - " }, 2, 4), "- item|- ")
end)

test("the mid-line split is still a split", function()
  assert_eq(cr_text({ "- ab" }, 1, 3), "- a|- b")
  assert_eq(cr_text({ "- alphbeta" }, 1, 6), "- alph|- beta")
end)

test("a prose line still falls through to the fallback", function()
  local r = cr({ "plain text" }, 1, 10)
  assert_true(r.fell_through, "prose must return the fallback object itself")
  local p = cr({ "foo()" }, 1, 4)
  assert_true(p.fell_through, "prose `foo(|)` is autopairs' business, not ours")
end)

_H.finish()
