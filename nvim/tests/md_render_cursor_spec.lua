-- Spec for andrew.utils.md_render_cursor: where the cursor of md-render's
-- rendered view lands in the markdown source.
--
-- WHAT THIS IS GUARDING
--
-- The rendered text is not the source text, so the mapping goes through the
-- words the two share. Each case is a way a rendered column stops meaning the
-- same thing in the source:
--
-- 1. Markup that is gone from the view (`**`, backticks, `==`) shifts every
--    column after it.
-- 2. A link's URL is in the source only, and can repeat a word of its own text.
-- 3. A paragraph is re-wrapped: its second rendered line is still the first
--    source line, far to the right.
-- 4. Source lines joined into one rendered line: the place is on a later
--    source line.
-- 5. Decoration that is in the view only (indent, icons, bullets, table
--    borders) must not be looked for in the source.
-- 6. A rendered line with nothing to line up (blank) gives no position, so the
--    caller keeps what md-render chose.
--
-- Positions are written as the text that FOLLOWS the cursor, so a failure
-- reads as "expected the cursor before `bold** text`".
--
-- Run with: nvim --headless -u NONE -l tests/md_render_cursor_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq = _H.test, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local md_render_cursor = require("andrew.utils.md_render_cursor")

-- What md-render v3.11.2 renders SOURCE_LINES as at its default 80 columns
-- (the frontmatter's "Properties" block included), kept as a fixture so the
-- spec needs neither the plugin nor a window.
local SOURCE_LINES = {
  "---",
  "title: Trial",
  "---",
  "# Renderer trial",
  "",
  "Some **bold** text, `inline code`, ==highlight== and a [link](https://example.com/link). This paragraph is long enough that it has to wrap at the rendered width so several rendered lines share one source line.",
  "",
  "A paragraph written",
  "across three source",
  "lines with *emphasis* in it.",
  "",
  "- [ ] open task with **bold**",
  "- item two",
  "",
  "| Name  | Value |",
  "| :---- | ----: |",
  "| alpha |     1 |",
}
local VIEW_LINES = {
  "  Properties",
  "  title: Trial",
  "",
  "  \u{f026b}  Renderer trial",
  "  Some bold text, inline code, highlight and a link. This paragraph is long",
  "  enough that it has to wrap at the rendered width so several rendered lines",
  "  share one source line.",
  "  ",
  "  A paragraph written across three source lines with emphasis in it.",
  "  ",
  "  \u{f0131}  open task with bold",
  "  • item two",
  "  ",
  "  │ Name  │ Value │",
  "  │───────│───────│",
  "  │ alpha │     1 │",
}

local SOURCE = { lines = SOURCE_LINES, first_line = 1 } ---@type MdRenderCursorStretch
local VIEW = { lines = VIEW_LINES, first_line = 1 } ---@type MdRenderCursorStretch

--- The text from the mapped position on in the buffer the cursor goes to, or
--- nil when there is none. The cursor is given as a line of the buffer it is
--- in and the text it sits on.
---@param origin MdRenderCursorStretch
---@param origin_line integer
---@param cursor_on string text in that line; the cursor is on its first byte
---@param target MdRenderCursorStretch
---@return string?
local function target_text_at(origin, origin_line, cursor_on, target)
  local origin_col = assert(
    origin.lines[origin_line]:find(cursor_on, 1, true),
    "fixture: no such text"
  ) - 1
  local position =
    md_render_cursor.counterpart_position(origin, { origin_line, origin_col }, target)
  return position and target.lines[position[1]]:sub(position[2] + 1)
end

---@param text string?
---@param prefix string
---@return boolean
local function starts_with(text, prefix)
  return text ~= nil and text:sub(1, #prefix) == prefix
end

--- Assert on the start of the target text only; the rest of a line is noise.
---@param origin MdRenderCursorStretch
---@param origin_line integer
---@param cursor_on string text in that line; the cursor is on its first byte
---@param target MdRenderCursorStretch
---@param expected_text string
---@param direction "rendered"|"source"  which buffer the cursor starts in, for the message
local function assert_target_text(origin, origin_line, cursor_on, target, expected_text, direction)
  local target_text = target_text_at(origin, origin_line, cursor_on, target)
  assert_eq(
    starts_with(target_text, expected_text) and expected_text or target_text,
    expected_text,
    ("cursor on %q of %s line %d lands before:"):format(cursor_on, direction, origin_line)
  )
end

--- Rendered view -> source: what `i` on the view does.
---@param view_line integer
---@param cursor_on string
---@param expected_source_text string
local function assert_lands_before(view_line, cursor_on, expected_source_text)
  assert_target_text(VIEW, view_line, cursor_on, SOURCE, expected_source_text, "rendered")
end

--- Source -> rendered view: what leaving Insert mode does.
---@param source_line integer
---@param cursor_on string
---@param expected_view_text string
local function assert_view_lands_before(source_line, cursor_on, expected_view_text)
  assert_target_text(SOURCE, source_line, cursor_on, VIEW, expected_view_text, "source")
end

---@param view_line integer
---@param cursor_on string
---@return string?
local function source_text_at(view_line, cursor_on)
  return target_text_at(VIEW, view_line, cursor_on, SOURCE)
end

test("a word after removed markup is found at its own column", function()
  assert_lands_before(5, "text,", "text, `inline")
  assert_lands_before(5, "code,", "code`, ==highlight")
end)

test("the middle of a word stays the middle of that word", function()
  assert_lands_before(5, "ghlight", "ghlight== and")
end)

test("a word inside markup lands inside the markup", function()
  assert_lands_before(5, "bold", "bold** text")
end)

test("the space between two words lands on the space, past closing markup", function()
  assert_lands_before(5, " text,", " text, `inline")
end)

test("link text is found in the brackets, not in the URL that repeats it", function()
  assert_lands_before(5, "link.", "link](https://")
end)

test("the word after a link is found past its URL", function()
  assert_lands_before(5, "This paragraph", "This paragraph is long")
  assert_lands_before(5, ". This", ". This paragraph")
end)

test("a wrapped rendered line maps into the long source line it came from", function()
  assert_lands_before(6, "enough", "enough that it has to wrap")
  assert_lands_before(7, "source line.", "source line.")
  assert_eq(
    md_render_cursor.counterpart_position(VIEW, { 7, 2 }, SOURCE)[1],
    6,
    "source line for the third rendered line of the paragraph:"
  )
end)

test("source lines joined into one rendered line map to the right source line", function()
  assert_lands_before(9, "across", "across three source")
  assert_lands_before(9, "emphasis", "emphasis* in it.")
end)

test("the end of a line lands on the last character", function()
  assert_lands_before(9, ".", ".")
end)

test("decoration that is only in the view maps to the start of the text", function()
  assert_lands_before(4, "\u{f026b}", "# Renderer trial")
  assert_lands_before(12, "• item", "- item two")
  assert_lands_before(11, "open", "open task with **bold**")
end)

test("table cells map to their cells", function()
  assert_lands_before(16, "alpha", "alpha |     1 |")
  assert_lands_before(16, "1 │", "1 |")
end)

test("frontmatter maps to its key, skipping the heading md-render adds", function()
  assert_lands_before(2, "Trial", "Trial")
  assert_eq(source_text_at(1, "Properties"), nil, "the added 'Properties' heading has no source:")
end)

test("a rendered line with no words gives no position", function()
  assert_eq(
    md_render_cursor.counterpart_position(VIEW, { 8, 0 }, SOURCE),
    nil,
    "blank rendered line:"
  )
end)

test("line numbers are those of the buffers, not of the stretches passed in", function()
  local position = assert(md_render_cursor.counterpart_position(
    { lines = { VIEW_LINES[9] }, first_line = 9 },
    { 9, (VIEW_LINES[9]:find("emphasis", 1, true)) - 1 },
    { lines = { SOURCE_LINES[8], SOURCE_LINES[9], SOURCE_LINES[10] }, first_line = 8 }
  ))
  assert_eq(position[1], 10, "source line:")
  assert_eq(position[2], (SOURCE_LINES[10]:find("emphasis", 1, true)) - 1, "source column:")
end)

-- The other direction: from the source into the rendered view.

test("source: a word after markup is found where the view shows it", function()
  assert_view_lands_before(6, "text,", "text, inline code")
  assert_view_lands_before(6, "ghlight", "ghlight and a link")
  assert_view_lands_before(12, "task", "task with bold")
end)

test("source: markup itself lands beside the word it wraps", function()
  assert_view_lands_before(6, "**bold", " bold text")
  assert_view_lands_before(6, "** text", " text, inline")
end)

test("source: a cursor in a link's URL lands at the end of the link text", function()
  assert_view_lands_before(6, "example.com", ". This paragraph")
end)

test("source: a long line maps onto the rendered line it was wrapped to", function()
  assert_view_lands_before(6, "enough", "enough that it has to wrap")
  assert_view_lands_before(6, "share one", "share one source line.")
  assert_eq(
    md_render_cursor.counterpart_position(
      SOURCE,
      { 6, (SOURCE_LINES[6]:find("share one", 1, true)) - 1 },
      VIEW
    )[1],
    7,
    "rendered line for the end of the long source line:"
  )
end)

test("source: lines the view joined map into the one rendered line", function()
  assert_view_lands_before(9, "across", "across three source lines")
  assert_view_lands_before(10, "emphasis", "emphasis in it.")
end)

test("source: table cells and frontmatter map to theirs", function()
  assert_view_lands_before(17, "alpha", "alpha │")
  assert_view_lands_before(2, "Trial", "Trial")
end)

test("source: a line with no words gives no position", function()
  assert_eq(md_render_cursor.counterpart_position(SOURCE, { 5, 0 }, VIEW), nil, "blank line:")
  assert_eq(md_render_cursor.counterpart_position(SOURCE, { 1, 0 }, VIEW), nil, "`---`:")
end)

_H.finish()
