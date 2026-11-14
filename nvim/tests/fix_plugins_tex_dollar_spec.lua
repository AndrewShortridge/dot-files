-- Spec for the inline-math `$` heuristic in utils/tex.lua.
--
-- THE BUG. in_mathzone() falls back to a regex heuristic whenever treesitter
-- cannot prove the cursor is in a latex region (markdown without the latex
-- parser reached, or a tex tree in an error state mid-typing). That heuristic
-- used to be "an ODD number of unescaped $ before the cursor => math", so a
-- single `$` anywhere in prose turned the whole rest of the line into a math
-- zone and all 61 math autosnippets fired on plain text:
--     costs $5 so **bold** and xx   ->   costs $5 so \cdotbold\cdot and \times
-- i.e. `**` and `~~`, core markdown syntax, silently rewrote themselves.
--
-- THE FIX. An odd count only counts as "inside math" when the run is actually
-- CLOSED later on the same line. Every real inline-math zone in this config is
-- created by the `mk` / `dm` autosnippets, which insert both delimiters at
-- once, so the closing `$` is always already present.
--
-- Discriminating power:
--   * Reverting to `count % 2 == 1`  -> the four prose tests fail.
--   * Requiring an EVEN count        -> the in-math tests fail.
--   * Dropping the `\$` unescaping   -> "escaped dollars" fails.
--
-- Calls the REAL M.in_mathzone against real buffers. Deliberately uses
-- filetype "markdown" with no latex parser on the runtimepath, which is exactly
-- the regex-fallback path (the treesitter paths are covered by
-- in_mathzone_memo_spec / audit_latex_texobj_spec).
--
-- Run with: nvim --headless -u NONE -l tests/fix_plugins_tex_dollar_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true, assert_false = _H.test, _H.assert_true, _H.assert_false

vim.opt.runtimepath:prepend(vim.fn.stdpath("config"))
local tex = require("andrew.utils.tex")

--- Put `line` in a fresh markdown buffer, park the cursor after the first
--- occurrence of `upto`, and return in_mathzone().
local function mathzone_after(line, upto)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_win_set_buf(0, buf)
  local col = upto and (assert(line:find(upto, 1, true)) + #upto - 1) or #line
  vim.api.nvim_win_set_cursor(0, { 1, col })
  local got = tex.in_mathzone()
  vim.api.nvim_buf_delete(buf, { force = true })
  return got
end

-- ---------------------------------------------------------------------------
-- prose: an unclosed `$` must NOT open a math zone
-- ---------------------------------------------------------------------------

test("a lone price `$` does not make the rest of the line math", function()
  assert_false(mathzone_after("costs $5 so "), "the original bug")
end)

test("a trailing `$` with nothing after it is not math", function()
  assert_false(mathzone_after("total $"))
end)

test("two prices on one line are not math either", function()
  -- Even count: this already worked, but it must keep working.
  assert_false(mathzone_after("from $5 to $9 in "))
end)

test("three prices (odd, unclosed) are not math", function()
  assert_false(mathzone_after("$1 $2 $3 and "))
end)

-- ---------------------------------------------------------------------------
-- real inline math: the closing `$` is present, so expansion must still fire
-- ---------------------------------------------------------------------------

test("inside `$...$` is math", function()
  assert_true(mathzone_after("$a  b$", "$a"), "cursor between the delimiters")
end)

test("inside `$...$` later in a prose line is math", function()
  assert_true(mathzone_after("see $x + y$ here", "$x +"))
end)

test("after the closing `$` is not math", function()
  assert_false(mathzone_after("see $x$ here"))
end)

test("the `mk` snippet's freshly inserted `$|$` is math", function()
  -- mk expands to `$$` with the cursor between the two delimiters.
  assert_true(mathzone_after("$$", "$"))
end)

-- ---------------------------------------------------------------------------
-- escaping
-- ---------------------------------------------------------------------------

test("escaped dollars are ignored on both sides of the cursor", function()
  assert_false(mathzone_after("costs \\$5 and \\$9 so "), "two escaped -> zero real")
  -- One real unclosed `$` plus an escaped one after it: still not math.
  assert_false(mathzone_after("a $b \\$c "), "the trailing \\$ must not count as the closer")
  -- One real `$` closed by a real `$`, with an escaped one in between.
  assert_true(mathzone_after("a $b \\$c d$ e", "$b"))
end)

_H.finish({ style = "results" })
