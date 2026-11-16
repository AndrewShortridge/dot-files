-- Spec for andrew.utils.md_render_math, run against the real md-render.nvim
-- with stand-ins for the three modules it uses: the TeX maker, the Kitty
-- placeholder cells and the Unicode text.
--
-- WHAT THIS IS GUARDING
--
-- The adapter puts LaTeX pictures (Kitty Unicode-placeholder cells) or
-- Unicode text into md-render's view in place of raw TeX, by wrapping six of
-- md-render's functions. The ways this goes wrong:
--
-- 1. A picture lands in the wrong bytes, or a highlight or link after it does:
--    the placeholder text has a different byte length from what md-render
--    measured, and everything after it on the line has to move.
-- 2. Another highlight's foreground wins over a picture's cells. The
--    foreground IS the image id, so the picture is gone or another one shows.
-- 3. Something that is not math (prices, code, escaped dollars, frontmatter,
--    code blocks) is touched, or TeX that failed to compile no longer shows as
--    md-render shows it today.
-- 4. Line numbers drift: the view's `source_line_map` must keep one entry per
--    view line, in order, or scroll sync and toggling land elsewhere.
-- 5. Pictures are asked for while typing (a pdftex run per pause), asked for
--    over and over (a rebuild loop), never shown once made, asked for in an
--    order that keeps the screen waiting for the rest of the note, or views
--    are rebuilt that had nothing to gain.
-- 6. With `vim.g.md_render_math = "off"` the view is not exactly md-render's.
-- 7. A build costs what it should not: a rescan per line after an unclosed
--    `$$`, the text form made again for every build.
-- 8. Something md-render shows is not shown: a ```math fence rewritten, or a
--    `$$` block drawn, where md-render then reads no block (generated notes
--    check this against md-render alone).
-- 9. Prose typeset: a `$` pair taken that md-render, pairing after its link,
--    emphasis and comment passes, does not make (`$5 and see **$x$**`;
--    generated lines check every pair against md-render's math pass).
--
-- The stand-ins follow Contract v2 (the adapter's header): `tex.lookup`
-- answers from a table the test fills (a picture, false or nil), for every
-- look or for one cell size only, and `false` for unbalanced braces as the
-- real module does; `tex.request` records and lets the test settle it;
-- `kitty.cells(picture, box, foreground)` returns rows of `▓` -- one cell,
-- three bytes, so byte-offset slips show -- shared, under one highlight group
-- per picture, box and colour, or `nil, "missing"` for a file the test says
-- is gone; `kitty.mark` records; `text` wraps the TeX in `«»`. No terminal in
-- a `-l` run: `nvim_ui_send` records, md-render is told the terminal can show
-- images and scale text.
--
-- Run with: nvim --headless -u NONE -l tests/md_render_math_spec.lua

local _H =
  dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

-- md-render runs `redraw!`; with print() output in the message area that has
-- crashed a headless Neovim. Results go straight to stdout.
_G.print = function(...)
  local parts = {}
  for index = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(index, ...)))
  end
  io.stdout:write(table.concat(parts, "\t") .. "\n")
end

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/md-render.nvim")
vim.cmd("filetype on")
-- The screen stays at its headless 80x24: resizing it in a `-l` run and then
-- splitting windows corrupted Neovim's heap here (abort in grid_alloc on the
-- next `redraw!`, seen with 0.12.5).
vim.o.swapfile = false
vim.o.termguicolors = true

local sent_to_terminal = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_ui_send = function(data)
  sent_to_terminal[#sent_to_terminal + 1] = data
end

require("md-render.image")._set_kitty_supported(true)
local text_size = require("md-render.text_size")

--- md-render probes the terminal once for text sizing and caches the answer.
---@param can_scale boolean
local function set_terminal_can_scale_text(can_scale)
  for upvalue_index = 1, math.huge do
    local upvalue_name = debug.getupvalue(text_size.supports, upvalue_index)
    if upvalue_name == nil then
      error("md-render.text_size.supports no longer caches its answer in `_supported`")
    end
    if upvalue_name == "_supported" then
      debug.setupvalue(text_size.supports, upvalue_index, can_scale)
      return
    end
  end
end
set_terminal_can_scale_text(true)

-- -----------------------------------------------------------------------------
-- Stand-ins for the sibling modules
-- -----------------------------------------------------------------------------

local STAND_IN = "▓"

-- Answers per equation; `look_answers["<cell_width>x<cell_height>"]` holds
-- answers for one look only, as the real module keys pictures by look.
local fake_tex = {
  answers = {},
  look_answers = {},
  failures = {},
  lookups = {},
  requests = {},
  forgotten = {},
  retries = 0,
  is_available_answer = true,
}

---@param tex string
---@return boolean
local function has_balanced_braces(tex)
  local depth = 0
  for brace in tex:gsub("\\[{}]", ""):gmatch("[{}]") do
    depth = depth + (brace == "{" and 1 or -1)
    if depth < 0 then
      return false
    end
  end
  return depth == 0
end

---@param look table
---@return table answers for exactly this look
local function answers_of_look(look)
  local key = look.cell_width .. "x" .. look.cell_height
  fake_tex.look_answers[key] = fake_tex.look_answers[key] or {}
  return fake_tex.look_answers[key]
end

function fake_tex.setup() end
function fake_tex.is_available()
  return fake_tex.is_available_answer
end
function fake_tex.lookup(equation, look)
  fake_tex.lookups[#fake_tex.lookups + 1] =
    { kind = equation.kind, tex = equation.tex, look = look }
  -- As the real module: unbalanced braces never reach TeX.
  if not has_balanced_braces(equation.tex) then
    return false
  end
  local key = equation.kind .. "\0" .. equation.tex
  local for_look = answers_of_look(look)[key]
  if for_look ~= nil then
    return for_look
  end
  return fake_tex.answers[key]
end
function fake_tex.request(equations, look, on_settled)
  fake_tex.requests[#fake_tex.requests + 1] =
    { equations = vim.deepcopy(equations), look = look, on_settled = on_settled }
end
function fake_tex.failure_of(equation)
  if not has_balanced_braces(equation.tex) then
    return "unbalanced braces"
  end
  return fake_tex.failures[equation.kind .. "\0" .. equation.tex]
end
function fake_tex.forget(equation, look)
  local key = equation.kind .. "\0" .. equation.tex
  fake_tex.forgotten[#fake_tex.forgotten + 1] = equation.tex
  fake_tex.answers[key] = nil
  answers_of_look(look)[key] = nil
end
function fake_tex.retry()
  fake_tex.retries = fake_tex.retries + 1
end
function fake_tex.status()
  return {
    is_available = fake_tex.is_available_answer,
    reason = not fake_tex.is_available_answer and "pdftex not found" or nil,
    pdftex = "/fake/pdftex",
    cache_directory = "/fake/cache",
  }
end

local fake_kitty = {
  MAX_CELLS = 297,
  supported = true,
  cell_width = 11,
  cell_height = 25,
  calls = {},
  marks = {},
  missing = {},
}
function fake_kitty.setup() end
function fake_kitty.is_supported()
  if fake_kitty.supported then
    return true
  end
  return false, "TERM is not xterm-kitty"
end
function fake_kitty.cell_size()
  if not fake_kitty.cell_width then
    return nil
  end
  return fake_kitty.cell_width, fake_kitty.cell_height
end

--- Group of a stand-in picture -> its foreground.
local picture_foreground = {}

--- As the real module: one image, so one group, per picture, box and colour,
--- and the rows handed out are shared (callers must not change them).
local images = {}

---@param picture table
---@param box? { columns: integer, rows: integer }
---@param foreground string
---@return string
local function image_key(picture, box, foreground)
  local columns = box and box.columns or picture.columns
  local row_count = box and box.rows or picture.rows
  return ("%s %dx%d %s"):format(picture.path, columns, row_count, foreground)
end

function fake_kitty.cells(picture, box, foreground)
  assert(type(foreground) == "string" and foreground:find("^%x%x%x%x%x%x$"), "a foreground")
  fake_kitty.calls[#fake_kitty.calls + 1] =
    { picture = picture, box = box, foreground = foreground }
  if fake_kitty.missing[picture.path] then
    return nil, "missing"
  end
  local columns = box and box.columns or picture.columns
  local row_count = box and box.rows or picture.rows
  if columns > fake_kitty.MAX_CELLS or row_count > fake_kitty.MAX_CELLS then
    return nil, "box"
  end
  local key = image_key(picture, box, foreground)
  local image = images[key]
  if not image then
    images[#images + 1] = key
    local group = "MathSpecPicture" .. #images
    picture_foreground[group] = 0x200000 + #images
    vim.api.nvim_set_hl(0, group, { fg = picture_foreground[group], sp = 1, nocombine = true })
    local rows = {}
    for _ = 1, row_count do
      rows[#rows + 1] = string.rep(STAND_IN, columns)
    end
    image = { rows = rows, group = group, copy = vim.deepcopy(rows) }
    images[key] = image
  end
  assert(vim.deep_equal(image.rows, image.copy), "shared rows were changed by the caller")
  return image.rows, image.group
end

--- The group the stand-in gave a picture shown unboxed in Special's colour.
---@param picture table
---@return string?
local function group_of_picture(picture)
  local image = images[image_key(picture, nil, "3366CC")]
  return image and image.group
end
function fake_kitty.mark(owner, groups)
  fake_kitty.marks[#fake_kitty.marks + 1] = { owner = owner, groups = vim.deepcopy(groups) }
end

local fake_text = { inline_calls = 0, display_calls = 0 }
function fake_text.inline(tex)
  fake_text.inline_calls = fake_text.inline_calls + 1
  return "«" .. tex .. "»"
end
function fake_text.display(tex)
  fake_text.display_calls = fake_text.display_calls + 1
  local rows = {}
  for row in (tex .. "\n"):gmatch("([^\n]*)\n") do
    rows[#rows + 1] = "«" .. row .. "»"
  end
  return rows
end

package.loaded["andrew.utils.md_render_math_tex"] = fake_tex
package.loaded["andrew.utils.md_render_math_kitty"] = fake_kitty
package.loaded["andrew.utils.md_render_math_text"] = fake_text

local picture_count = 0
---@param columns integer
---@param rows? integer
---@param scale? number
local function new_picture(columns, rows, scale)
  picture_count = picture_count + 1
  return {
    path = ("/fake/picture-%d.png"):format(picture_count),
    columns = columns,
    rows = rows or 1,
    scale = scale or 1,
  }
end

---@param kind string
---@param tex string
---@param answer table|false|nil
local function answer(kind, tex, answer_value)
  fake_tex.answers[kind .. "\0" .. tex] = answer_value
end

local function forget_calls()
  fake_tex.lookups, fake_tex.requests, fake_tex.forgotten = {}, {}, {}
  fake_kitty.calls, fake_kitty.marks = {}, {}
end

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

local preview = require("md-render").preview
local MAX_WIDTH = 60

---@param lines string[]
---@return table content
local function build(lines)
  return preview.build_content(lines, { max_width = MAX_WIDTH })
end

--- A build under `vim.g.md_render_math = setting`.
---@param setting "off"|"text"
---@param lines string[]
---@return table content
local function build_as(setting, lines)
  vim.g.md_render_math = setting
  local content = build(lines)
  vim.g.md_render_math = nil
  return content
end

--- Highlight groups of a view line (1-based), in the content.
---@param content table
---@param line_number integer
---@return table[]
local function groups_on(content, line_number)
  local groups = {}
  for _, entry in ipairs(content.highlights) do
    if entry.line == line_number - 1 then
      vim.list_extend(groups, entry.groups)
    end
  end
  return groups
end

---@param content table
---@param needle string plain text
---@return integer? line_number
---@return string? line
local function find_line(content, needle)
  for line_number, line in ipairs(content.lines) do
    if line:find(needle, 1, true) then
      return line_number, line
    end
  end
end

---@param groups table[]
---@param name string
---@return table[]
local function groups_named(groups, name)
  return vim.tbl_filter(function(group)
    return group.hl == name
  end, groups)
end

--- What a group covers on its line.
local function covered(line, group)
  local end_col = group.end_col == -1 and #line or group.end_col
  return line:sub(group.col + 1, end_col)
end

local function picture_groups_on(content, line_number)
  return vim.tbl_filter(function(group)
    return group.hl:find("^MathSpecPicture") ~= nil
  end, groups_on(content, line_number))
end

--- Content reduced to what the view shows, for comparing two builds.
local function view_of(content)
  return {
    lines = content.lines,
    highlights = content.highlights,
    links = content.link_metadata,
    source_line_map = content.source_line_map,
    anchors = content.heading_anchors,
    text_placements = content.text_placements,
  }
end

---@param content table
local function assert_line_map_whole(content, label)
  assert_eq(#content.source_line_map, #content.lines, label .. ": one source line per view line")
  for index = 2, #content.source_line_map do
    assert_true(
      content.source_line_map[index] >= content.source_line_map[index - 1],
      ("%s: source_line_map goes back at view line %d"):format(label, index)
    )
  end
end

local function settle(milliseconds)
  vim.wait(milliseconds or 50, function()
    return false
  end, 10)
end

-- Colours that would break a picture if they won over its cells.
vim.cmd([[
  hi Normal guifg=#abb2bf guibg=#282c34
  hi Special guifg=#3366cc
  hi Bold gui=bold guifg=#ff00ff
  hi Underlined gui=underline guifg=#00ffff
  hi CursorLine guibg=#2c323c
]])

-- -----------------------------------------------------------------------------
-- md-render alone, with the other adapters, before this one is set up
-- -----------------------------------------------------------------------------

--- md-render's own markdown.render, before any module wraps it: its math
--- pass is one of its upvalues.
local md_render_own_render = require("md-render.markdown").render

require("andrew.utils.md_render_tab_visibility").setup()
require("andrew.utils.md_render_headings").setup()
require("andrew.utils.md_render_heading_colors").setup()
require("andrew.utils.md_render_heading_background").setup()

local MIXED_NOTE = {
  "---",
  "title: costs $5 and $x$",
  "---",
  "# Note with $\\alpha$",
  "",
  "Text $a_1$ and $b$ and **bold** and [link](https://example.com) here.",
  "",
  "- Item $c$ in a list",
  "  $$",
  "  d = e",
  "  $$",
  "",
  "$$",
  "f",
  "$$",
  "",
  "> [!note] Callout $g$",
  "> $$",
  "> h",
  "> $$",
  "",
  "| A | B |",
  "|---|---|",
  "| x | $i$ |",
  "",
  "```math",
  "j",
  "```",
  "",
  "```lua",
  "local s = '$k$'",
  "$$",
  "```",
  "",
  "It costs $5 and then $10; `$l$` in code; an escaped \\$ sign.",
  "Last $$m=n$$ line.",
}
local NON_MATH_NOTE = {
  "---",
  "price: $5 and $x$",
  "---",
  "It costs $5 and then $10; `$x$` in code; an escaped \\$ sign.",
  "",
  "```lua",
  "local s = '$y$'",
  "$$",
  "z",
  "$$",
  "```",
  "",
  "    $indented code$",
}
local md_render_alone = {
  mixed = vim.deepcopy(view_of(build(MIXED_NOTE))),
  non_math = vim.deepcopy(view_of(build(NON_MATH_NOTE))),
}

local math_adapter = require("andrew.utils.md_render_math")
math_adapter.setup()
-- Last, as in plugins/md-render.lua.
require("andrew.utils.md_render_repaint").setup()

-- -----------------------------------------------------------------------------
-- Where pictures go
-- -----------------------------------------------------------------------------

test(
  "inline in a paragraph: the picture's cells in place of the TeX, later highlights and links moved",
  function()
    forget_calls()
    answer("inline", "p_1^2", new_picture(3))
    local content = build({ "Before $p_1^2$ and **bold** then [link](https://example.com) end." })
    local line = content.lines[1]
    assert_eq(line, "  Before " .. STAND_IN:rep(3) .. " and bold then link end.", "view line:")
    local picture_groups = picture_groups_on(content, 1)
    assert_eq(#picture_groups, 1, "one picture highlight:")
    assert_eq(
      covered(line, picture_groups[1]),
      STAND_IN:rep(3),
      "picture highlight covers exactly its cells:"
    )
    assert_eq(
      covered(line, groups_named(groups_on(content, 1), "Bold")[1]),
      "bold",
      "bold after it:"
    )
    local link = content.link_metadata[1]
    assert_eq(line:sub(link.col_start + 1, link.col_end), "link", "link after it:")
    assert_eq(
      #groups_named(groups_on(content, 1), "MdRenderMath"),
      0,
      "no MdRenderMath over a picture:"
    )
  end
)

test("inline in a list item", function()
  answer("inline", "q", new_picture(2))
  local content = build({ "- Item with $q$ here" })
  local line = content.lines[1]
  assert_eq(line, "  • Item with " .. STAND_IN:rep(2) .. " here", "view line:")
  assert_eq(covered(line, picture_groups_on(content, 1)[1]), STAND_IN:rep(2), "picture bytes:")
  assert_eq(
    covered(line, groups_named(groups_on(content, 1), "Special")[1]),
    "• ",
    "list marker keeps its colour:"
  )
end)

test("inline in a callout, title and body", function()
  answer("inline", "r_t", new_picture(3))
  answer("inline", "r_b", new_picture(4))
  local content = build({ "> [!note] Title $r_t$", "> Body $r_b$ text." })
  local title_number, title = find_line(content, "Title")
  local body_number, body = find_line(content, "Body")
  assert_true(
    title and title:find("Title " .. STAND_IN:rep(3), 1, true),
    "title: " .. tostring(title)
  )
  assert_true(
    body and body:find("│ Body " .. STAND_IN:rep(4) .. " text.", 1, true),
    "body: " .. tostring(body)
  )
  assert_eq(
    covered(title, picture_groups_on(content, title_number)[1]),
    STAND_IN:rep(3),
    "title picture bytes:"
  )
  assert_eq(
    covered(body, picture_groups_on(content, body_number)[1]),
    STAND_IN:rep(4),
    "body picture bytes:"
  )
end)

test("inline in a table cell: the column is as wide as the picture", function()
  answer("inline", "s_{cell}", new_picture(8))
  local content = build({ "| A | B |", "|---|---|", "| x | $s_{cell}$ |" })
  local row_number, row = find_line(content, STAND_IN)
  assert_true(row ~= nil, "a table row holds the picture")
  assert_eq(
    covered(row, picture_groups_on(content, row_number)[1]),
    STAND_IN:rep(8),
    "picture bytes:"
  )
  assert_eq(
    vim.api.nvim_strwidth(row),
    vim.api.nvim_strwidth(content.lines[1]),
    "the row is as wide as the header (columns sized by display width):"
  )
end)

test("inline in a heading md-render does not scale; anchor made from the TeX", function()
  set_terminal_can_scale_text(false)
  answer("inline", "E=mc^2", new_picture(6))
  local source = { "## Energy $E=mc^2$ here" }
  local content = build(source)
  local plain = build_as("off", source)
  set_terminal_can_scale_text(true)
  local line = content.lines[1]
  assert_true(line:find("Energy " .. STAND_IN:rep(6) .. " here", 1, true), "heading line: " .. line)
  assert_eq(covered(line, picture_groups_on(content, 1)[1]), STAND_IN:rep(6), "picture bytes:")
  local heading_colour = groups_named(groups_on(content, 1), "MdRenderH2")[1]
  assert_true(
    covered(line, heading_colour):find(STAND_IN:rep(6), 1, true) ~= nil,
    "heading colour still over the line, picture included"
  )
  assert_true(
    vim.deep_equal(content.heading_anchors, plain.heading_anchors),
    "anchors as md-render makes them:"
  )
  assert_true(next(content.heading_anchors) ~= nil, "there is an anchor")
end)

test(
  "a wrapped callout title or heading: every picture highlight covers exactly its cells",
  function()
    -- md-render's wrap turns the two spaces behind the icon into one and
    -- places the first row's highlights as if they were still there.
    answer("inline", "wrap_a", new_picture(3))
    answer("inline", "wrap_b", new_picture(3))
    local long = " and then some more words so that the line has to wrap at the width"
    local sources = {
      { "> [!note] Derive $wrap_a$ and $wrap_b$" .. long, "> body" },
      { "> [!note]- Derive $wrap_a$ and $wrap_b$" .. long, "> body" },
      { "> > [!tip] Derive $wrap_a$ and $wrap_b$" .. long },
      { "> [!note] The same $wrap_a$ $wrap_a$ twice" .. long },
      { "# Derive $wrap_a$ and $wrap_b$" .. long },
      { "#### Derive $wrap_a$ and $wrap_b$" .. long },
      -- md-render wraps a footnote itself, by the same rule (`a * b * c`
      -- leaves two spaces where each `*` was).
      { "Text[^1].", "", "[^1]: a * b * c $wrap_a$ and $wrap_b$" .. long },
    }
    set_terminal_can_scale_text(false)
    local is_checked, failure = pcall(function()
      for _, source in ipairs(sources) do
        local content = build(source)
        local pictures, placed = 0, {}
        for line_number, line in ipairs(content.lines) do
          for _, group in ipairs(picture_groups_on(content, line_number)) do
            pictures = pictures + 1
            local label = ("%s: row %d, byte %d:"):format(source[1], line_number, group.col)
            assert_eq(covered(line, group), STAND_IN:rep(3), label)
            -- Each on its own cells, the same picture twice too.
            assert_true(not placed[line_number .. ":" .. group.col], label .. " one picture")
            placed[line_number .. ":" .. group.col] = true
          end
        end
        assert_eq(pictures, 2, source[1] .. ": pictures:")
        local _, first_row = find_line(content, STAND_IN)
        assert_true(not first_row:find("width", 1, true), source[1] .. ": wrapped")
      end
    end)
    set_terminal_can_scale_text(true)
    assert_true(is_checked, failure)
  end
)

test("several equations on one line, two of them adjacent", function()
  answer("inline", "t_1", new_picture(1))
  answer("inline", "t_2", new_picture(2))
  answer("inline", "t_3", new_picture(3))
  answer("inline", "t_4", new_picture(4))
  local content = build({ "A $t_1$ B $t_2$ C $t_3$$t_4$ end" })
  local line = content.lines[1]
  assert_eq(line, "  A ▓ B ▓▓ C ▓▓▓▓▓▓▓ end", "view line:")
  local groups = picture_groups_on(content, 1)
  table.sort(groups, function(a, b)
    return a.col < b.col
  end)
  assert_eq(#groups, 4, "four picture highlights:")
  for index, group in ipairs(groups) do
    assert_eq(
      covered(line, group),
      STAND_IN:rep(index),
      ("equation %d covers its own cells:"):format(index)
    )
  end
  assert_true(groups[3].hl ~= groups[4].hl, "adjacent pictures keep their own groups")
end)

test("the same equation twice: two runs, one picture, asked for once", function()
  forget_calls()
  answer("inline", "u_{same}", new_picture(3))
  local content = build({ "$u_{same}$ and $u_{same}$" })
  local groups = picture_groups_on(content, 1)
  assert_eq(#groups, 2, "two runs:")
  assert_eq(groups[1].hl, groups[2].hl, "same picture group:")
  forget_calls()
  build({ "$u_{pending}$ and $u_{pending}$" })
  assert_eq(#fake_tex.requests, 1, "one request:")
  assert_eq(#fake_tex.requests[1].equations, 1, "for one equation:")
end)

test("$$tex$$ on one line: an inline picture in display style", function()
  forget_calls()
  answer("inline", "\\displaystyle v=w", new_picture(5))
  local content = build({ "Inline block $$ v=w $$ here." })
  assert_eq(content.lines[1], "  Inline block " .. STAND_IN:rep(5) .. " here.", "view line:")
  assert_eq(fake_tex.lookups[1].kind, "inline", "asked as inline:")
  assert_eq(fake_tex.lookups[1].tex, "\\displaystyle v=w", "in display style:")
end)

test(
  "a $$ block: picture rows centred like md-render's images, picture highlight only over the picture",
  function()
    answer("display", "\\frac{a}{b}", new_picture(10, 2))
    local content = build({ "Para.", "", "$$", "\\frac{a}{b}", "$$", "", "After." })
    local first = find_line(content, STAND_IN)
    local column = math.floor((MAX_WIDTH - 10) / 2)
    for offset = 0, 1 do
      local line = content.lines[first + offset]
      assert_eq(line, string.rep(" ", column) .. STAND_IN:rep(10), "row " .. offset .. ":")
      local groups = groups_on(content, first + offset)
      assert_eq(#groups, 1, "one highlight on the row:")
      assert_eq(covered(line, groups[1]), STAND_IN:rep(10), "over the picture only:")
      assert_eq(content.source_line_map[first + offset], 4, "row stands for the TeX line:")
    end
    assert_eq(vim.trim(content.lines[first + 2]), "", "nothing else of the block:")
    assert_eq(content.source_line_map[find_line(content, "After.")], 7, "line after the block:")
    assert_line_map_whole(content, "block")
  end
)

test("a block's TeX is read from the source, lines joined by newlines", function()
  forget_calls()
  build({ "$$", "\\begin{aligned}", "a_i &= b \\\\", "c &= d", "\\end{aligned}", "$$" })
  assert_eq(fake_tex.lookups[1].kind, "display", "display:")
  assert_eq(
    fake_tex.lookups[1].tex,
    "\\begin{aligned}\na_i &= b \\\\\nc &= d\n\\end{aligned}",
    "TeX verbatim:"
  )
end)

test("a block inside a list item keeps the item's indent", function()
  answer("display", "x+y", new_picture(4, 1))
  local content = build({ "- Item", "  $$", "  x+y", "  $$", "- Next" })
  local number, line = find_line(content, STAND_IN)
  assert_true(vim.startswith(line, "    "), "indented under the item: " .. line)
  assert_eq(covered(line, groups_on(content, number)[1]), STAND_IN:rep(4), "picture bytes:")
  assert_true(find_line(content, "Next") ~= nil, "the list goes on")
end)

test("a block inside a callout: rows carry the bar and the callout colours", function()
  answer("display", "\\dot{\\psi}", new_picture(6, 2))
  local content = build({ "> [!note] T", "> $$", "> \\dot{\\psi}", "> $$", "", "After." })
  local number, line = find_line(content, STAND_IN)
  assert_true(vim.startswith(line, "  │ "), "starts with the bar: " .. line)
  assert_true(content.lines[number + 1]:find(STAND_IN:rep(6), 1, true) ~= nil, "second row")
  assert_true(not content.lines[number + 2]:find("psi", 1, true), "TeX not shown")
  local groups = groups_on(content, number)
  local bar = groups_named(groups, "MdRenderAlertNote")[1]
  assert_eq(covered(line, bar), "│ ", "bar colour:")
  assert_true(#groups_named(groups, "MdRenderAlertNoteBg") == 1, "callout background")
  assert_eq(covered(line, picture_groups_on(content, number)[1]), STAND_IN:rep(6), "picture bytes:")
  assert_line_map_whole(content, "callout block")
end)

test("a ```math fence becomes a picture block, line numbers kept", function()
  forget_calls()
  answer("display", "\\sum_i i", new_picture(5, 2))
  local content = build({ "Before.", "", "```math", "\\sum_i i", "```", "", "After." })
  local number = find_line(content, STAND_IN)
  assert_true(number ~= nil, "picture rows")
  assert_eq(content.source_line_map[number], 4, "rows stand for the TeX line:")
  assert_eq(content.source_line_map[find_line(content, "After.")], 7, "line after:")
  assert_true(
    find_line(content, "```") == nil and find_line(content, "\\sum") == nil,
    "no fence or TeX left"
  )
end)

test("dollars that are not math, frontmatter, code blocks: untouched", function()
  forget_calls()
  local content = build(NON_MATH_NOTE)
  assert_true(
    vim.deep_equal(view_of(content), md_render_alone.non_math),
    "view as md-render alone makes it"
  )
  assert_eq(#fake_tex.lookups, 0, "nothing looked up:")
end)

test("source_line_map: one entry per view line, never going back", function()
  answer("display", "f", new_picture(3, 3))
  answer("display", "d = e", new_picture(3, 2))
  answer("display", "h", new_picture(3, 2))
  answer("display", "j", new_picture(3, 4))
  local content = build(MIXED_NOTE)
  assert_line_map_whole(content, "mixed note")
  assert_eq(
    content.source_line_map[find_line(content, "Last ")],
    #MIXED_NOTE,
    "last line still names its source line:"
  )
end)

test("a block wider than the view is drawn into a smaller box", function()
  forget_calls()
  local wide = new_picture(100, 4)
  answer("display", "wide", wide)
  local content = build({ "$$", "wide", "$$" })
  local call = fake_kitty.calls[#fake_kitty.calls]
  assert_eq(call.picture, wide, "the picture:")
  assert_eq(call.box and call.box.columns, MAX_WIDTH - 2, "box width = the line's:")
  assert_eq(
    call.box and call.box.rows,
    math.ceil(4 * (MAX_WIDTH - 2) / 100),
    "rows kept in proportion:"
  )
  local number = find_line(content, STAND_IN)
  assert_eq(vim.api.nvim_strwidth(content.lines[number]), MAX_WIDTH, "fits the view:")
end)

test("an inline picture is never drawn into a box; too wide or too small is text", function()
  forget_calls()
  answer("inline", "too_wide", new_picture(MAX_WIDTH + 5))
  answer("inline", "too_small", new_picture(4, 1, 0.5))
  answer("inline", "just_legible", new_picture(4, 1, 0.6))
  local content = build({ "A $too_wide$ B $too_small$ C $just_legible$" })
  local text = table.concat(content.lines, "\n")
  assert_true(text:find("«too_wide»", 1, true) ~= nil, "too wide: text")
  assert_true(text:find("«too_small»", 1, true) ~= nil, "below 0.6: text")
  assert_true(text:find(STAND_IN:rep(4), 1, true) ~= nil, "0.6: picture")
  for _, call in ipairs(fake_kitty.calls) do
    assert_eq(call.box, nil, "no box for inline:")
  end
end)

-- -----------------------------------------------------------------------------
-- Text, and TeX left alone
-- -----------------------------------------------------------------------------

test("a picture not made yet shows as text under MdRenderMath, inline and block", function()
  local content = build({ "Wait $pend_1$ here.", "", "$$", "pend_2", "$$" })
  local line_number, line = find_line(content, "«pend_1»")
  assert_true(line ~= nil, "inline text")
  assert_eq(
    covered(line, groups_named(groups_on(content, line_number), "MdRenderMath")[1]),
    "«pend_1»",
    "highlight:"
  )
  local block_number, block = find_line(content, "«pend_2»")
  assert_true(block ~= nil, "block text")
  assert_eq(covered(block, groups_on(content, block_number)[1]), "«pend_2»", "block highlight:")
  assert_true(
    block:find("^%s+«") ~= nil and #block:match("^%s*") > 2,
    "block text is centred: " .. block
  )
end)

test("a heading md-render scales gets text and nothing is looked up for it", function()
  forget_calls()
  local content = build({ "# Title $scaled$ end" })
  assert_true(find_line(content, "Title «scaled» end") ~= nil, "text in the heading")
  assert_eq(#fake_tex.lookups, 0, "no lookup:")
  assert_eq(
    content.text_placements[1] and content.text_placements[1].text,
    "Title «scaled» end",
    "scaled run text:"
  )
end)

test("where pictures are impossible, text: no Kitty, no TeX, no cell size", function()
  answer("inline", "impossible", new_picture(3))
  local cases = {
    function()
      fake_kitty.supported = false
    end,
    function()
      fake_tex.is_available_answer = false
    end,
    function()
      fake_kitty.cell_width = nil
    end,
  }
  for index, make_impossible in ipairs(cases) do
    forget_calls()
    make_impossible()
    local content = build({ "Here $impossible$." })
    fake_kitty.supported, fake_tex.is_available_answer, fake_kitty.cell_width = true, true, 11
    assert_eq(content.lines[1], "  Here «impossible».", ("case %d view line:"):format(index))
    assert_eq(#fake_tex.lookups, 0, ("case %d no lookup:"):format(index))
    assert_eq(#fake_tex.requests, 0, ("case %d no request:"):format(index))
  end
end)

test('vim.g.md_render_math = "text": text everywhere, nothing asked', function()
  forget_calls()
  answer("inline", "texted", new_picture(3))
  local content = build_as("text", { "Here $texted$.", "", "```math", "fenced", "```" })
  assert_eq(content.lines[1], "  Here «texted».", "inline:")
  assert_true(find_line(content, "«fenced»") ~= nil, "fence as text")
  assert_eq(#fake_tex.lookups + #fake_tex.requests, 0, "no lookup or request:")
end)

test("TeX that failed is shown as md-render shows it today", function()
  local source = {
    "Inline $failed_1$ here and $$failed_2$$.",
    "",
    "$$",
    "failed_3",
    "$$",
    "",
    "> $$",
    "> failed_4",
    "> $$",
    "",
    "```math",
    "failed_5",
    "```",
  }
  for _, tex in ipairs({ "failed_1", "\\displaystyle failed_2" }) do
    answer("inline", tex, false)
  end
  for _, tex in ipairs({ "failed_3", "failed_4", "failed_5" }) do
    answer("display", tex, false)
  end
  forget_calls()
  local content = build(source)
  local plain = build_as("off", source)
  assert_true(vim.deep_equal(view_of(content), view_of(plain)), "same view as without the adapter")
  assert_eq(#fake_tex.requests, 0, "nothing requested:")
end)

test(
  'vim.g.md_render_math = "off": the view is md-render\'s, line for line with highlights',
  function()
    forget_calls()
    local content = build_as("off", MIXED_NOTE)
    assert_true(vim.deep_equal(view_of(content), md_render_alone.mixed), "content identical")
    assert_eq(#fake_tex.lookups + #fake_tex.requests, 0, "nothing looked up or requested:")
  end
)

--- The view lines md-render shows after a given line, without the adapter.
---@param source string[]
---@param after string plain text of the last line before the tail
---@return string[]
local function tail_without_adapter(source, after)
  local plain = build_as("off", source)
  local from = assert(find_line(plain, after), "line before the tail")
  -- A quoted block's closing `│ $$` is md-render's too: not part of the tail.
  if vim.trim(plain.lines[from + 1] or "") == "│ $$" then
    from = from + 1
  end
  return vim.list_slice(plain.lines, from + 1)
end

test("a block at the end of the note keeps the footnotes after it (plain block)", function()
  answer("display", "E = mc^2_{end}", new_picture(8, 2))
  local source =
    { "Text with a note[^1].", "", "[^1]: The footnote body.", "", "$$", "E = mc^2_{end}", "$$" }
  local content = build(source)
  local tail = tail_without_adapter(source, "E = mc^2_{end}")
  assert_true(#tail > 0 and find_line(content, "The footnote body.") ~= nil, "footnote shown")
  assert_true(
    vim.deep_equal(vim.list_slice(content.lines, #content.lines - #tail + 1), tail),
    "the footnote section as md-render makes it"
  )
  assert_line_map_whole(content, "footnotes")
end)

test("a block at the end of the note keeps the footnotes after it (callout block)", function()
  answer("display", "fn_cd", new_picture(4, 2))
  local source =
    { "Text[^1].", "", "[^1]: Body of the note.", "", "> [!note] T", "> $$", "> fn_cd", "> $$" }
  local content = build(source)
  local tail = tail_without_adapter(source, "fn_cd")
  assert_true(find_line(content, STAND_IN:rep(4)) ~= nil, "picture shown")
  assert_true(#tail > 0 and find_line(content, "Body of the note.") ~= nil, "footnote shown")
  assert_true(
    vim.deep_equal(vim.list_slice(content.lines, #content.lines - #tail + 1), tail),
    "the footnote section as md-render makes it"
  )
  assert_true(find_line(content, "fn_cd") == nil, "no TeX left of the block")
end)

test("$x$ inside a bare URL or autolink: the line as md-render makes it, nothing asked", function()
  forget_calls()
  answer("inline", "url_shown", new_picture(3))
  local source = {
    "See https://example.com/q?a=$url_x$&b=1 now",
    "",
    "See <https://example.com/$url_y$/y> now",
    "",
    "And https://example.com/q?c=$url_shown$&d=2 too",
  }
  local content = build(source)
  local plain = build_as("off", source)
  assert_true(vim.deep_equal(view_of(content), view_of(plain)), "same view as without the adapter")
  for _, link in ipairs(content.link_metadata) do
    assert_true(not link.url:find("\194\160", 1, true), "no filler in " .. link.url)
  end
  assert_eq(#fake_tex.requests, 0, "nothing requested:")
end)

test("a line given back to md-render asks for no pictures (real U+00A0, %%comment%%)", function()
  forget_calls()
  local source =
    { "nbsp adjacent\194\160$given_x$ end", "", "comment %% $given_y$ %% then $given_z$" }
  local content = build(source)
  local plain = build_as("off", source)
  assert_true(vim.deep_equal(view_of(content), view_of(plain)), "same view as without the adapter")
  assert_eq(#fake_tex.requests, 0, "nothing requested:")
end)

test("TeX and its text are not spell-checked: an extmark with spell = false over each", function()
  answer("inline", "spell_failed", false)
  local content =
    build({ "Pending $spell_pending$ and failed $spell_failed$.", "", "$$", "spell_block", "$$" })
  local buffer = vim.api.nvim_create_buf(false, true)
  local namespace = vim.api.nvim_create_namespace("md_render_math_spec_spell")
  require("md-render.display_utils").apply_content_to_buffer(buffer, namespace, content)
  local marks = vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
  local math_ranges = 0
  for _, entry in ipairs(content.highlights) do
    for _, group in ipairs(entry.groups) do
      if group.hl == "MdRenderMath" then
        math_ranges = math_ranges + 1
        local line_text = content.lines[entry.line + 1]
        local end_col = group.end_col == -1 and #line_text or group.end_col
        local is_unchecked = vim.iter(marks):any(function(mark)
          return mark[2] == entry.line
            and mark[3] == group.col
            and mark[4].end_col == end_col
            and mark[4].spell == false
            and mark[4].hl_group == nil
        end)
        assert_true(is_unchecked, ("spell off over %q"):format(covered(line_text, group)))
      end
    end
  end
  assert_eq(math_ranges, 3, "math ranges (text, raw TeX, block text):")
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

-- -----------------------------------------------------------------------------
-- Requests
-- -----------------------------------------------------------------------------

--- Builds per view: md-render passes a view's `opts` to every build of it.
local builds_of = setmetatable({}, { __mode = "k" })
local counted_build_content = preview.build_content
preview.build_content = function(lines, opts)
  if opts then
    builds_of[opts] = (builds_of[opts] or 0) + 1
  end
  return counted_build_content(lines, opts)
end

---@param view_bufnr integer
---@return integer
local function builds_of_view(view_bufnr)
  return builds_of[preview._sessions[view_bufnr].opts] or 0
end

local function open_note(lines)
  vim.cmd("silent! only")
  local note = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, note)
  vim.cmd.edit(vim.fn.fnameescape(note))
  return note, vim.api.nvim_get_current_buf()
end

local function close_everything(note)
  vim.cmd("silent! only")
  vim.cmd("silent! enew!")
  vim.cmd("silent! %bwipeout!")
  vim.fn.delete(note)
end

--- Give the source of a view new lines and rebuild the view.
---@param session table
---@param source_bufnr integer
---@param lines string[]
local function rebuild_with(session, source_bufnr, lines)
  vim.api.nvim_buf_set_lines(source_bufnr, 0, -1, false, lines)
  session:refresh_source()
  session:rebuild()
end

local function view_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

---@param request table
---@return string
local function texs_of(request)
  return table.concat(
    vim.tbl_map(function(equation)
      return equation.tex
    end, request.equations),
    " "
  )
end

test("one request per build, in document order; the look is the cell size only", function()
  forget_calls()
  local source = {
    "A $req_1$ and $req_2$.",
    "",
    "$$",
    "req_3",
    "$$",
    "",
    "```math",
    "req_4",
    "```",
    "",
    "$req_5$",
  }
  build(source)
  assert_eq(#fake_tex.requests, 1, "one request:")
  local request = fake_tex.requests[1]
  assert_eq(texs_of(request), "req_1 req_2 req_3 req_4 req_5", "in document order:")
  assert_true(
    vim.deep_equal(request.look, { cell_width = 11, cell_height = 25 }),
    "no colour in the look: " .. vim.inspect(request.look)
  )
  -- Asked for already and not settled: not again.
  build(source)
  assert_eq(#fake_tex.requests, 1, "in flight, not asked again:")
end)

test("the colour goes to kitty.cells: MdRenderMath's, else Normal's; never to TeX", function()
  forget_calls()
  answer("inline", "colour_1", new_picture(2))
  build({ "$colour_1$" })
  assert_eq(
    fake_kitty.calls[#fake_kitty.calls].foreground,
    "3366CC",
    "through its link to Special:"
  )
  vim.api.nvim_set_hl(0, "MathSpecNoColour", { bold = true })
  vim.api.nvim_set_hl(0, "MdRenderMath", { link = "MathSpecNoColour" })
  build({ "$colour_1$" })
  vim.api.nvim_set_hl(0, "MdRenderMath", { link = "Special" })
  assert_eq(fake_kitty.calls[#fake_kitty.calls].foreground, "ABB2BF", "Normal's foreground:")
  -- Cleared by a colour scheme: md-render's groups are defined again first.
  vim.cmd("hi clear MdRenderMath")
  build({ "$colour_1$" })
  assert_eq(fake_kitty.calls[#fake_kitty.calls].foreground, "3366CC", "Special's colour again:")
  assert_eq(#fake_tex.requests, 0, "nothing for TeX to make:")
end)

test("failed TeX and pictures that exist are not requested", function()
  forget_calls()
  answer("inline", "no_req_failed", false)
  answer("inline", "no_req_made", new_picture(2))
  build({ "$no_req_failed$ and $no_req_made$" })
  assert_eq(#fake_tex.requests, 0, "no request:")
end)

---@param request table
---@return integer[] the numbers in the TeX `<name>_<number>`
local function numbers_of(request)
  return vim.tbl_map(function(equation)
    return tonumber(equation.tex:match("_(%d+)$"))
  end, request.equations)
end

---@param from integer
---@param to integer
---@param except? { from: integer, to: integer }
---@return integer[]
local function numbers(from, to, except)
  local list = {}
  for number = from, to do
    if not (except and number >= except.from and number <= except.to) then
      list[#list + 1] = number
    end
  end
  return list
end

---@param name string
---@param count integer
---@return string[] as many list items, each with the equation `<name>_<number>`
local function numbered_items(name, count)
  local source = {}
  for index = 1, count do
    source[index] = ("- Item $%s_%d$ here"):format(name, index)
  end
  return source
end

test(
  "more than 40 missing: what is on screen and a screen around it first, then the rest",
  function()
    forget_calls()
    local note, source_bufnr = open_note(numbered_items("vf", 120))
    -- A first build: no window shows the view yet, the source window does.
    local last = vim.fn.line("w$")
    preview.toggle()
    local view_bufnr = vim.api.nvim_get_current_buf()
    assert_eq(#fake_tex.requests, 2, "two requests:")
    local near_last = last + (last - vim.fn.line("w0") + 1)
    assert_true(
      vim.deep_equal(numbers_of(fake_tex.requests[1]), numbers(1, near_last)),
      "near the source window first, in order: " .. vim.inspect(numbers_of(fake_tex.requests[1]))
    )
    assert_true(
      vim.deep_equal(numbers_of(fake_tex.requests[2]), numbers(near_last + 1, 120)),
      "then the rest, in order"
    )

    -- A view scrolled to the middle: its own lines, through its source_line_map.
    vim.api.nvim_win_set_cursor(0, { 70, 0 })
    vim.cmd("normal! zt")
    local session = preview._sessions[view_bufnr]
    local map = session.content.source_line_map
    local first_shown, last_shown = map[vim.fn.line("w0")], map[vim.fn.line("w$")]
    local margin = last_shown - first_shown + 1
    local near =
      { from = math.max(1, first_shown - margin), to = math.min(120, last_shown + margin) }
    forget_calls()
    rebuild_with(session, source_bufnr, numbered_items("vf2", 120))
    assert_eq(#fake_tex.requests, 2, "two requests:")
    assert_true(
      vim.deep_equal(numbers_of(fake_tex.requests[1]), numbers(near.from, near.to)),
      ("lines %d-%d first: %s"):format(
        near.from,
        near.to,
        vim.inspect(numbers_of(fake_tex.requests[1]))
      )
    )
    assert_true(
      vim.deep_equal(numbers_of(fake_tex.requests[2]), numbers(1, 120, near)),
      "then the rest, in order"
    )
    close_everything(note)
  end
)

test("settled: only the views that wait for it are rebuilt, once; then no loop", function()
  forget_calls()
  local note = open_note({ "$loop_1$ $loop_2$", "", "$$", "loop_3", "$$" })
  preview.toggle()
  local view_a = vim.api.nvim_get_current_buf()
  vim.cmd("new")
  local other_note = vim.fn.tempname() .. ".md"
  -- Waiting too, for another equation: not rebuilt when this one settles.
  vim.fn.writefile({ "Another $loop_other$ here.", "", "It costs $5 and $10." }, other_note)
  vim.cmd.edit(vim.fn.fnameescape(other_note))
  preview.toggle()
  local view_b = vim.api.nvim_get_current_buf()
  assert_true(#vim.fn.win_findbuf(view_a) == 1 and #vim.fn.win_findbuf(view_b) == 1, "both shown")
  assert_eq(#fake_tex.requests, 2, "one request per view:")
  local request = fake_tex.requests[1]
  assert_eq(texs_of(request), "loop_1 loop_2 loop_3", "the first view's:")
  answer("inline", "loop_1", new_picture(2))
  answer("inline", "loop_2", false)
  -- loop_3 stays without a picture although it settled: a broken maker.
  local builds_a, builds_b = builds_of_view(view_a), builds_of_view(view_b)
  request.on_settled()
  settle(50)
  assert_eq(builds_of_view(view_a) - builds_a, 1, "the view waiting for them, once:")
  assert_eq(builds_of_view(view_b) - builds_b, 0, "the other view not at all:")
  assert_true(view_text(view_a):find(STAND_IN:rep(2), 1, true) ~= nil, "the picture is shown")
  assert_true(
    view_text(view_a):find("«loop_3»", 1, true) ~= nil,
    "the one without a picture is text"
  )
  assert_eq(#fake_tex.requests, 2, "the rebuild asks for nothing:")
  preview._sessions[view_a]:rebuild()
  settle(50)
  assert_eq(#fake_tex.requests, 2, "nor does the next one:")
  assert_eq(builds_of_view(view_a) - builds_a, 2, "and nothing rebuilds by itself:")
  close_everything(note)
  vim.fn.delete(other_note)
end)

test("two requests settling in the same tick: one rebuild of the view", function()
  forget_calls()
  local note, source_bufnr = open_note({ "$tick_1$" })
  preview.toggle()
  local view_bufnr = vim.api.nvim_get_current_buf()
  local session = preview._sessions[view_bufnr]
  rebuild_with(session, source_bufnr, { "$tick_1$ $tick_2$" })
  assert_eq(#fake_tex.requests, 2, "two requests:")
  local before = builds_of_view(view_bufnr)
  fake_tex.requests[1].on_settled()
  fake_tex.requests[2].on_settled()
  settle(50)
  assert_eq(builds_of_view(view_bufnr) - before, 1, "one rebuild:")
  close_everything(note)
end)

test(":MdRenderMath retry: what settled without a picture is asked for again", function()
  forget_calls()
  build({ "$stuck_1$" })
  fake_tex.requests[1].on_settled()
  settle(50)
  forget_calls()
  build({ "$stuck_1$" })
  assert_eq(#fake_tex.requests, 0, "settled without a picture: not asked again:")
  local retries = fake_tex.retries
  vim.cmd("MdRenderMath retry")
  assert_eq(fake_tex.retries - retries, 1, "tex.retry():")
  build({ "$stuck_1$" })
  assert_eq(#fake_tex.requests, 1, "asked again:")
  settle(50)
end)

test("a picture whose file is gone is made again, once", function()
  forget_calls()
  local picture = new_picture(3)
  answer("inline", "gone_1", picture)
  fake_kitty.missing[picture.path] = true
  local source = { "Gone $gone_1$ here." }
  assert_eq(build(source).lines[1], "  Gone «gone_1» here.", "text meanwhile:")
  assert_eq(table.concat(fake_tex.forgotten, " "), "gone_1", "tex.forget:")
  assert_eq(#fake_tex.requests == 1 and texs_of(fake_tex.requests[1]), "gone_1", "asked for again:")
  -- Made again and still unreadable: text, and not asked for again.
  answer("inline", "gone_1", picture)
  fake_tex.requests[1].on_settled()
  settle(50)
  forget_calls()
  assert_eq(build(source).lines[1], "  Gone «gone_1» here.", "text:")
  assert_eq(#fake_tex.requests, 0, "no third time:")
  -- Readable again.
  fake_kitty.missing[picture.path] = nil
  answer("inline", "gone_1", picture)
  assert_eq(build(source).lines[1], "  Gone " .. STAND_IN:rep(3) .. " here.", "picture:")
end)

-- -----------------------------------------------------------------------------
-- In real views
-- -----------------------------------------------------------------------------

--- The mode Neovim reports while a test pretends one; nil: its own.
---@type string?
local reported_mode
local get_mode = vim.api.nvim_get_mode
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_get_mode = function()
  if reported_mode then
    return { mode = reported_mode, blocking = false }
  end
  return get_mode()
end

test(
  "no request in Insert mode; on leaving it the owed pictures are asked for, no rebuild",
  function()
    forget_calls()
    local note = open_note({ "Typing $insert_tex$ now." })
    reported_mode = "i"
    preview.toggle()
    local view_bufnr = vim.api.nvim_get_current_buf()
    assert_true(view_text(view_bufnr):find("«insert_tex»", 1, true) ~= nil, "text while typing")
    assert_eq(#fake_tex.requests, 0, "nothing requested in Insert mode:")
    vim.api.nvim_exec_autocmds("ModeChanged", { pattern = "n:i" })
    settle(50)
    assert_eq(#fake_tex.requests, 0, "still nothing while Insert mode lasts:")
    reported_mode = nil
    local builds = builds_of_view(view_bufnr)
    vim.api.nvim_exec_autocmds("ModeChanged", { pattern = "i:n" })
    settle(50)
    assert_eq(#fake_tex.requests, 1, "asked for on leaving Insert mode:")
    assert_eq(texs_of(fake_tex.requests[1]), "insert_tex", "the owed equation:")
    assert_eq(builds_of_view(view_bufnr) - builds, 0, "without a rebuild:")
    vim.api.nvim_exec_autocmds("ModeChanged", { pattern = "n:v" })
    settle(50)
    assert_eq(#fake_tex.requests, 1, "nothing owed after that:")
    -- And the picture arrives.
    answer("inline", "insert_tex", new_picture(3))
    fake_tex.requests[1].on_settled()
    vim.wait(500, function()
      return view_text(view_bufnr):find(STAND_IN, 1, true) ~= nil
    end, 10)
    assert_true(view_text(view_bufnr):find(STAND_IN:rep(3), 1, true) ~= nil, "picture in the view")
    close_everything(note)
  end
)

test(
  "leaving Insert mode with md-render's rebuild pending: that rebuild asks, not the old text",
  function()
    forget_calls()
    local note = open_note({ "Typing $half_typed$ now." })
    reported_mode = "i"
    preview.toggle()
    reported_mode = nil
    local session = preview._sessions[vim.api.nvim_get_current_buf()]
    local timer = assert(vim.uv.new_timer())
    session._debounce_timer = timer
    vim.api.nvim_exec_autocmds("ModeChanged", { pattern = "i:n" })
    settle(50)
    session._debounce_timer = nil
    timer:close()
    assert_eq(#fake_tex.requests, 0, "nothing asked on leaving Insert mode:")
    session:rebuild()
    assert_eq(#fake_tex.requests, 1, "md-render's rebuild asks:")
    close_everything(note)
  end
)

test(
  "one Normal command from Insert mode is Insert mode; a Normal build pays what is owed",
  function()
    forget_calls()
    local note, source_bufnr = open_note({ "Typing $ow_a$ now." })
    reported_mode = "niI"
    preview.toggle()
    local session = preview._sessions[vim.api.nvim_get_current_buf()]
    assert_eq(#fake_tex.requests, 0, "<C-o> from Insert mode (niI): nothing requested:")
    -- md-render rebuilds after the edit in Normal mode: that build asks for
    -- what the note holds now, and nothing is owed any more.
    reported_mode = "n"
    rebuild_with(session, source_bufnr, { "Typed $ow_b$ now." })
    assert_eq(#fake_tex.requests, 1, "the Normal-mode build asks:")
    assert_eq(texs_of(fake_tex.requests[1]), "ow_b", "for the note as it is:")
    vim.api.nvim_exec_autocmds("ModeChanged", { pattern = "i:n" })
    settle(50)
    assert_eq(#fake_tex.requests, 1, "nothing owed on leaving Insert mode:")
    reported_mode = nil
    close_everything(note)
  end
)

test("an equation settled without a picture is asked for again in a new look", function()
  forget_calls()
  local note = open_note({ "Look $look_key$ here." })
  preview.toggle()
  local view_bufnr = vim.api.nvim_get_current_buf()
  assert_eq(#fake_tex.requests, 1, "asked for:")
  fake_tex.requests[1].on_settled()
  settle(50)
  preview._sessions[view_bufnr]:rebuild()
  assert_eq(#fake_tex.requests, 1, "settled: not asked again in the same look:")
  fake_kitty.cell_width = 12
  vim.api.nvim_exec_autocmds("VimResized", {})
  settle(50)
  assert_eq(#fake_tex.requests, 2, "a new cell size: asked again:")
  local look = fake_tex.requests[2].look
  assert_eq(look.cell_width, 12, "in the new look:")
  answers_of_look(look)["inline\0look_key"] = new_picture(2)
  fake_tex.requests[2].on_settled()
  settle(50)
  assert_true(view_text(view_bufnr):find(STAND_IN:rep(2), 1, true) ~= nil, "its picture shown")
  fake_kitty.cell_width = 11
  vim.api.nvim_exec_autocmds("VimResized", {})
  settle(50)
  close_everything(note)
end)

test("a hidden view waiting for pictures is marked for a rebuild, others are not", function()
  forget_calls()
  local other_note = open_note({ "Nothing to wait for." })
  preview.toggle()
  local other_session = preview._sessions[vim.api.nvim_get_current_buf()]
  preview.toggle()
  local note = open_note({ "Hidden $hidden_tex$ view." })
  preview.toggle()
  local view_bufnr = vim.api.nvim_get_current_buf()
  preview.toggle()
  assert_eq(#vim.fn.win_findbuf(view_bufnr), 0, "view hidden:")
  local session = preview._sessions[view_bufnr]
  session.dirty, other_session.dirty = false, false
  answer("inline", "hidden_tex", new_picture(2))
  fake_tex.requests[1].on_settled()
  settle(50)
  assert_true(session.dirty, "marked dirty")
  assert_true(not other_session.dirty, "a view waiting for nothing is not")
  preview.toggle()
  assert_true(
    view_text(vim.api.nvim_get_current_buf()):find(STAND_IN:rep(2), 1, true) ~= nil,
    "picture when shown again"
  )
  close_everything(note)
  vim.fn.delete(other_note)
end)

test(
  "ColorScheme: a rebuild only when the picture colour changed, no TeX; none in text or off",
  function()
    forget_calls()
    answer("inline", "scheme_1", new_picture(2))
    local note = open_note({ "Colour $scheme_1$ here." })
    preview.toggle()
    local view_bufnr = vim.api.nvim_get_current_buf()
    local before = builds_of_view(view_bufnr)
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    settle(50)
    assert_eq(builds_of_view(view_bufnr) - before, 0, "same colour, no rebuild:")
    vim.cmd("hi Special guifg=#ff8800")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    settle(50)
    assert_eq(builds_of_view(view_bufnr) - before, 1, "new colour, one rebuild:")
    assert_eq(fake_kitty.calls[#fake_kitty.calls].foreground, "FF8800", "in the new colour:")
    assert_eq(#fake_tex.requests, 0, "no TeX:")
    vim.cmd("hi Special guifg=#3366cc")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    settle(50)
    -- The colour set by a `ColorScheme` autocmd made after the adapter's
    -- (a plugin loaded later): seen.
    local later = vim.api.nvim_create_autocmd("ColorScheme", {
      callback = function()
        vim.cmd("hi Special guifg=#00aa00")
      end,
    })
    before = builds_of_view(view_bufnr)
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    settle(50)
    vim.api.nvim_del_autocmd(later)
    local rebuilds = builds_of_view(view_bufnr) - before
    local foreground = fake_kitty.calls[#fake_kitty.calls].foreground
    vim.cmd("hi Special guifg=#3366cc")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    settle(50)
    assert_eq(rebuilds, 1, "colour set by a later autocmd, a rebuild:")
    assert_eq(foreground, "00AA00", "in that colour:")
    for _, setting in ipairs({ "text", "off" }) do
      vim.g.md_render_math = setting
      preview.rebuild_visible()
      before = builds_of_view(view_bufnr)
      vim.cmd("hi Special guifg=#ff8800")
      vim.api.nvim_exec_autocmds("ColorScheme", {})
      settle(50)
      vim.cmd("hi Special guifg=#3366cc")
      assert_eq(builds_of_view(view_bufnr) - before, 0, setting .. ", no rebuild:")
    end
    vim.g.md_render_math = nil
    close_everything(note)
  end
)

test(
  "termguicolors, a terminal that can show pictures now, a new cell size: views rebuilt",
  function()
    forget_calls()
    answer("inline", "env_1", new_picture(2))
    -- A hidden view: every full refresh marks it for a rebuild.
    local hidden_note = open_note({ "Hidden, no math." })
    preview.toggle()
    local hidden_session = preview._sessions[vim.api.nvim_get_current_buf()]
    preview.toggle()
    local note = open_note({ "Environment $env_1$ here." })
    preview.toggle()
    local view_bufnr = vim.api.nvim_get_current_buf()
    local function rebuilds_after(change)
      local before = builds_of_view(view_bufnr)
      hidden_session.dirty = false
      change()
      settle(50)
      local rebuilds = builds_of_view(view_bufnr) - before
      assert_eq(hidden_session.dirty, rebuilds > 0, "the hidden view marked with it:")
      return rebuilds
    end
    assert_eq(
      rebuilds_after(function()
        vim.o.termguicolors = false
      end),
      1,
      "termguicolors off:"
    )
    assert_eq(
      rebuilds_after(function()
        vim.o.termguicolors = true
      end),
      1,
      "termguicolors on:"
    )
    assert_eq(
      rebuilds_after(function()
        vim.api.nvim_exec_autocmds("User", { pattern = "MdRenderMathTerminal" })
      end),
      1,
      "User MdRenderMathTerminal:"
    )
    assert_eq(
      rebuilds_after(function()
        vim.api.nvim_exec_autocmds("VimResized", {})
      end),
      0,
      "a resize, same cell size:"
    )
    assert_eq(
      rebuilds_after(function()
        fake_kitty.cell_width = 12
        vim.api.nvim_exec_autocmds("VimResized", {})
      end),
      1,
      "a resize with a new cell size:"
    )
    fake_kitty.cell_width = 11
    preview.rebuild_visible()
    vim.g.md_render_math = "off"
    assert_eq(
      rebuilds_after(function()
        vim.o.termguicolors = false
        vim.o.termguicolors = true
        vim.api.nvim_exec_autocmds("User", { pattern = "MdRenderMathTerminal" })
      end),
      0,
      '"off":'
    )
    vim.g.md_render_math = nil
    close_everything(note)
    vim.fn.delete(hidden_note)
  end
)

test("toggle, source edited, toggle again: the view follows the source", function()
  forget_calls()
  answer("inline", "tog_1", new_picture(2))
  local note, source_bufnr = open_note({ "Toggle $tog_1$ text." })
  preview.toggle()
  local view_bufnr = vim.api.nvim_get_current_buf()
  assert_true(
    view_text(view_bufnr):find("Toggle " .. STAND_IN:rep(2) .. " text.", 1, true) ~= nil,
    "picture shown"
  )
  preview.toggle()
  vim.api.nvim_buf_set_lines(
    source_bufnr,
    0,
    -1,
    false,
    { "Toggle $tog_2$ text.", "", "$$", "tog_3", "$$" }
  )
  preview.toggle()
  view_bufnr = vim.api.nvim_get_current_buf()
  assert_true(view_text(view_bufnr):find("«tog_2»", 1, true) ~= nil, "new equation as text")
  assert_eq(#fake_tex.requests, 1, "asked for:")
  answer("inline", "tog_2", new_picture(4))
  answer("display", "tog_3", new_picture(5, 2))
  fake_tex.requests[1].on_settled()
  vim.wait(500, function()
    return view_text(view_bufnr):find(STAND_IN:rep(4), 1, true) ~= nil
  end, 10)
  local lines = vim.api.nvim_buf_get_lines(view_bufnr, 0, -1, false)
  assert_true(
    lines[1]:find("Toggle " .. STAND_IN:rep(4) .. " text.", 1, true) ~= nil,
    "inline picture: " .. lines[1]
  )
  assert_true(view_text(view_bufnr):find(STAND_IN:rep(5), 1, true) ~= nil, "block picture")
  close_everything(note)
end)

test("split with a source edit in between", function()
  forget_calls()
  answer("inline", "split_1", new_picture(2))
  local note, source_bufnr = open_note({ "Split $split_1$ text.", "", "Second." })
  preview.split({ mods = { vertical = true } })
  local view_window
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.b[vim.api.nvim_win_get_buf(window)].md_render then
      view_window = window
    end
  end
  assert_true(view_window ~= nil, "a view window")
  local view_bufnr = vim.api.nvim_win_get_buf(view_window)
  assert_true(view_text(view_bufnr):find(STAND_IN:rep(2), 1, true) ~= nil, "picture in the split")
  vim.api.nvim_buf_set_lines(source_bufnr, 2, 3, false, { "Second with $split_2$." })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = source_bufnr })
  vim.wait(1000, function()
    return view_text(view_bufnr):find("«split_2»", 1, true) ~= nil
  end, 10)
  assert_true(view_text(view_bufnr):find("«split_2»", 1, true) ~= nil, "edit shown as text")
  assert_eq(#fake_tex.requests, 1, "asked for:")
  answer("inline", "split_2", new_picture(3))
  fake_tex.requests[1].on_settled()
  vim.wait(500, function()
    return view_text(view_bufnr):find("with " .. STAND_IN:rep(3), 1, true) ~= nil
  end, 10)
  assert_true(
    view_text(view_bufnr):find("with " .. STAND_IN:rep(3), 1, true) ~= nil,
    "then the picture"
  )
  close_everything(note)
end)

-- -----------------------------------------------------------------------------
-- The picture's colour wins on screen
-- -----------------------------------------------------------------------------

--- The extmarks of stand-in pictures in a buffer, whatever their namespace.
---@param bufnr integer
---@return table[] marks with details
local function picture_marks(bufnr)
  local marks = {}
  for _, namespace in pairs(vim.api.nvim_get_namespaces()) do
    for _, mark in
      ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true }))
    do
      if mark[4].hl_group and mark[4].hl_group:find("^MathSpecPicture") then
        marks[#marks + 1] = mark
      end
    end
  end
  return marks
end

test("picture extmarks: one per picture, priority above md-render's, no spell", function()
  answer("inline", "mark_1", new_picture(2))
  local note = open_note({ "[Link $mark_1$ text](https://example.com)" })
  preview.toggle()
  local view_bufnr = vim.api.nvim_get_current_buf()
  local marks = picture_marks(view_bufnr)
  assert_eq(#marks, 1, "one extmark:")
  assert_eq(marks[1][4].priority, math_adapter.PICTURE_HIGHLIGHT_PRIORITY, "priority:")
  assert_true(math_adapter.PICTURE_HIGHLIGHT_PRIORITY > 4200, "above md-render's highest (4200)")
  assert_eq(marks[1][4].spell, false, "spell off:")
  close_everything(note)
end)

test(
  "on screen the picture's colour is the cell's, in every container and on the cursor line",
  function()
    set_terminal_can_scale_text(false)
    local containers = {
      paragraph = { tex = "grid_p", columns = 3 },
      bold = { tex = "grid_b", columns = 2 },
      link = { tex = "grid_l", columns = 4 },
      list = { tex = "grid_i", columns = 3 },
      callout_title = { tex = "grid_ct", columns = 2 },
      callout = { tex = "grid_c", columns = 5 },
      table = { tex = "grid_t", columns = 4 },
      heading = { tex = "grid_h", columns = 3 },
      block = { tex = "grid_d", columns = 6, rows = 2, kind = "display" },
      callout_block = { tex = "grid_cd", columns = 4, rows = 2, kind = "display" },
    }
    local picture_of_container, group_of = {}, {}
    for name, container in pairs(containers) do
      local picture = new_picture(container.columns, container.rows)
      answer(container.kind or "inline", container.tex, picture)
      picture_of_container[name] = picture
    end
    local note = open_note({
      "## Heading $grid_h$ here",
      "",
      -- A link that starts with its equation: md-render's link colour starts
      -- in the same byte, twice (a highlight and the link's own extmark).
      "Paragraph $grid_p$ and **bold $grid_b$** and [$grid_l$ link](https://example.com).",
      "",
      "- Item $grid_i$",
      "",
      "> [!note] Title $grid_ct$",
      "> Body $grid_c$ text",
      "> $$",
      "> grid_cd",
      "> $$",
      "",
      "| A | B |",
      "|---|---|",
      "| x | $grid_t$ |",
      "",
      "$$",
      "grid_d",
      "$$",
    })
    preview.toggle()
    local window = vim.api.nvim_get_current_win()
    local view_bufnr = vim.api.nvim_get_current_buf()
    for name, picture in pairs(picture_of_container) do
      group_of[name] = assert(group_of_picture(picture), name .. ": a group")
    end
    vim.wo[window].cursorline = true
    vim.wo[window].spell = true
    local checked = 0
    for name, group in pairs(group_of) do
      -- The picture's first cell: where the extmark of its group starts.
      local found
      for _, mark in ipairs(picture_marks(view_bufnr)) do
        if not found and mark[4].hl_group == group then
          found = { line_number = mark[2] + 1, byte = mark[3] }
        end
      end
      assert_true(found ~= nil, name .. ": picture in the view")
      for _, on_cursor_line in ipairs({ false, true }) do
        vim.api.nvim_win_set_cursor(window, { on_cursor_line and found.line_number or 1, 0 })
        if not on_cursor_line and found.line_number == 1 then
          vim.api.nvim_win_set_cursor(window, { 2, 0 })
        end
        vim.cmd("redraw!")
        local position = vim.fn.screenpos(window, found.line_number, found.byte + 1)
        vim.cmd("redraw!")
        local cell = vim.api.nvim__inspect_cell(1, position.row - 1, position.col - 1)
        assert_eq(cell[1]:sub(1, #STAND_IN), STAND_IN, name .. ": the cell is the picture's:")
        assert_eq(
          cell[2].foreground,
          picture_foreground[group],
          ("%s%s: foreground of the cell:"):format(
            name,
            on_cursor_line and " on the cursor line" or ""
          )
        )
        checked = checked + 1
      end
    end
    assert_eq(checked, 20, "cells checked:")
    set_terminal_can_scale_text(true)
    close_everything(note)
  end
)

-- -----------------------------------------------------------------------------
-- What md_render_math_kitty is told; "off" adds nothing
-- -----------------------------------------------------------------------------

---@param owner integer
---@return table? groups of the last mark of `owner`
local function last_mark_of(owner)
  for index = #fake_kitty.marks, 1, -1 do
    if fake_kitty.marks[index].owner == owner then
      return fake_kitty.marks[index].groups
    end
  end
end

---@param owner integer
---@return integer
local function marks_of(owner)
  return #vim.tbl_filter(function(mark)
    return mark.owner == owner
  end, fake_kitty.marks)
end

test("kitty.mark on every apply: the pictures a view shows, none, and once under off", function()
  forget_calls()
  local picture = new_picture(2)
  answer("inline", "mark_a", picture)
  local note, source_bufnr = open_note({ "Mark $mark_a$ here." })
  preview.toggle()
  local view_bufnr = vim.api.nvim_get_current_buf()
  local session = preview._sessions[view_bufnr]
  local group = assert(group_of_picture(picture))
  assert_true(vim.deep_equal(last_mark_of(view_bufnr), { [group] = true }), "the picture shown")
  rebuild_with(session, source_bufnr, { "No math now." })
  assert_true(vim.deep_equal(last_mark_of(view_bufnr), {}), "none shown")
  rebuild_with(session, source_bufnr, { "Mark $mark_a$ here." })
  vim.g.md_render_math = "off"
  local before = marks_of(view_bufnr)
  session:rebuild()
  assert_eq(marks_of(view_bufnr) - before, 1, "off: told once")
  assert_true(vim.deep_equal(last_mark_of(view_bufnr), {}), "that it shows none")
  session:rebuild()
  assert_eq(marks_of(view_bufnr) - before, 1, "and not again:")
  vim.g.md_render_math = nil
  close_everything(note)
end)

test('"off": no extmark of the adapter\'s and no mark', function()
  forget_calls()
  vim.g.md_render_math = "off"
  local content = build(MIXED_NOTE)
  local buffer = vim.api.nvim_create_buf(false, true)
  local namespace = vim.api.nvim_create_namespace("md_render_math_spec_off")
  require("md-render.display_utils").apply_content_to_buffer(buffer, namespace, content)
  vim.g.md_render_math = nil
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })) do
    assert_true(
      mark[4].spell ~= false and mark[4].priority ~= math_adapter.PICTURE_HIGHLIGHT_PRIORITY,
      "md-render's extmark only: " .. vim.inspect(mark[4])
    )
  end
  assert_eq(#fake_kitty.marks, 0, "no kitty.mark:")
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

-- -----------------------------------------------------------------------------
-- What a build costs
-- -----------------------------------------------------------------------------

test("an unclosed $$: the search for its end is made once, not once per line", function()
  ---@param paragraph_count integer
  ---@return string[]
  local function note_of(paragraph_count)
    local lines = { "Typing a block:", "", "$$", "\\frac{a}{b}" }
    -- Paragraphs, not one paragraph: md-render joins consecutive lines.
    for index = 1, paragraph_count do
      vim.list_extend(lines, { ("Paragraph %d of prose."):format(index), "" })
    end
    return lines
  end
  local lines = note_of(1000)
  local read_before = math_adapter._lines_read_for_blocks()
  build(lines)
  local lines_read = math_adapter._lines_read_for_blocks() - read_before
  assert_true(
    lines_read >= #lines and lines_read <= 2 * #lines,
    ("%d lines read for blocks in a %d-line note"):format(lines_read, #lines)
  )
  -- However the lines are read: four times the note, about four times the
  -- time (a search per line is sixteen times).
  local function fastest_build(note)
    local fastest = math.huge
    for _ = 1, 3 do
      local start = vim.uv.hrtime()
      build(note)
      fastest = math.min(fastest, vim.uv.hrtime() - start)
    end
    return fastest
  end
  local small, large = note_of(1000), note_of(4000)
  fastest_build(small)
  local ratio = fastest_build(large) / fastest_build(small)
  assert_true(ratio < 8, ("4x the note took %.1fx the time"):format(ratio))
end)

test("the text form of an equation is made once, not once per build", function()
  local source = { "Memo $memo_inline$ here.", "", "$$", "memo_display", "$$" }
  local inline_calls, display_calls = fake_text.inline_calls, fake_text.display_calls
  vim.g.md_render_math = "text"
  build(source)
  build(source)
  vim.g.md_render_math = nil
  assert_eq(fake_text.inline_calls - inline_calls, 1, "text.inline:")
  assert_eq(fake_text.display_calls - display_calls, 1, "text.display:")
end)

test("the text memo is bounded: kept while in use, made again once two generations pass", function()
  local made = 0
  local upstream_inline = fake_text.inline
  fake_text.inline = function(tex)
    if tex == "memo_keep" then
      made = made + 1
    end
    return upstream_inline(tex)
  end
  local batch = 0
  ---@param count integer distinct equations never built before
  local function build_distinct(count)
    batch = batch + 1
    local line = {}
    for index = 1, count do
      line[#line + 1] = ("$mb%d_%d$"):format(batch, index)
    end
    build({ table.concat(line, " ") })
  end
  vim.g.md_render_math = "text"
  build({ "Keep $memo_keep$." })
  -- 2048 more fill a generation whatever the memo held: memo_keep is older.
  build_distinct(2048)
  build({ "Keep $memo_keep$." })
  local made_while_kept = made
  -- Found in the older generation, it went to the newer one: one more
  -- generation later it is still there.
  build_distinct(2048)
  build({ "Keep $memo_keep$." })
  local made_after_promotion = made
  build_distinct(2 * 2048 + 1)
  build({ "Keep $memo_keep$." })
  vim.g.md_render_math = nil
  fake_text.inline = upstream_inline
  assert_eq(made_while_kept, 1, "one generation later, still kept:")
  assert_eq(made_after_promotion, 1, "used in the older generation, kept one more:")
  assert_eq(made, 2, "two generations without it, made again:")
end)

-- -----------------------------------------------------------------------------
-- Delimiters
-- -----------------------------------------------------------------------------

test("a closing $ before a digit does not close, and md-render is told so", function()
  forget_calls()
  answer("inline", "x_d", new_picture(1))
  answer("inline", "a_d", new_picture(1))
  answer("inline", "b_d", new_picture(1))
  local prices = { "$5 and $10", "$20,000 and $30,000", "Escaped \\$5 here" }
  local source = {
    "It is US$3 or US$4.",
    "",
    "$x_d$ costs $3",
    "",
    "$a_d$$b_d$",
    "",
    "Zero $z_d$0 and nine $n_d$9 are not math either.",
  }
  for _, line in ipairs(prices) do
    vim.list_extend(source, { "", line })
  end
  local content = build(source)
  local plain = build_as("off", source)
  local number, line = find_line(content, "It is US")
  assert_eq(line, "  It is US$3 or US$4.", "currency left as written:")
  assert_eq(#groups_named(groups_on(content, number), "MdRenderMath"), 0, "and not math:")
  assert_true(find_line(content, "Zero $z_d$0 and nine $n_d$9") ~= nil, "0 and 9 both refuse")
  assert_true(find_line(content, STAND_IN .. " costs $3") ~= nil, "$x$ costs $3")
  assert_true(find_line(content, STAND_IN .. STAND_IN) ~= nil, "$a$$b$: two pictures")
  for _, price in ipairs(prices) do
    local needle = price:gsub("\\", ""):sub(1, 6)
    assert_eq(
      content.lines[find_line(content, needle)],
      plain.lines[find_line(plain, needle)],
      price .. ": as md-render shows it:"
    )
  end
  local looked_up = vim.tbl_map(function(lookup)
    return lookup.tex
  end, fake_tex.lookups)
  table.sort(looked_up)
  assert_eq(table.concat(looked_up, " "), "a_d b_d x_d", "only these are math:")
end)

-- md-render's rule as this adapter duplicated it before pandoc's digit rule,
-- character by character: kept here only to prove the scanner that replaced
-- it. `refuses_digit` adds the digit rule at the one place it applies.
local OLD_ESCAPABLE_CHARS = [[!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~]]
local function old_inline_math_spans(text, refuses_digit)
  local without_code = {}
  local position = 1
  while position <= #text do
    local char = text:sub(position, position)
    local close = char == "`" and text:find("`", position + 1, true)
    if close then
      without_code[#without_code + 1] = string.rep("\1", close - position + 1)
      position = close + 1
    else
      without_code[#without_code + 1] = char
      position = position + 1
    end
  end
  local unescaped = table.concat(without_code)
  local masked = {}
  position = 1
  while position <= #unescaped do
    local char = unescaped:sub(position, position)
    local next_char = unescaped:sub(position + 1, position + 1)
    if char == "\\" and next_char ~= "" and OLD_ESCAPABLE_CHARS:find(next_char, 1, true) then
      masked[#masked + 1] = "\1\1"
      position = position + 2
    else
      masked[#masked + 1] = char
      position = position + 1
    end
  end
  local scanned = table.concat(masked)
  local spans = {}
  position = 1
  while position <= #scanned do
    local char = scanned:sub(position, position)
    if char == "`" then
      break
    end
    if char == "$" and scanned:sub(position + 1, position + 1) == "$" then
      local close = scanned:find("$$", position + 2, true)
      local tex = close and text:sub(position + 2, close - 1)
      if tex and tex:find("%S") then
        spans[#spans + 1] =
          { first = position, last = close + 1, tex = vim.trim(tex), is_display = true }
        position = close + 2
      else
        position = position + 1
      end
    elseif char == "$" then
      local close = scanned:find("$", position + 1, true)
      local tex = close and close > position + 1 and text:sub(position + 1, close - 1)
      local is_refused = refuses_digit and close and scanned:sub(close + 1, close + 1):find("%d")
      if tex and not tex:find("^%s") and not tex:find("%s$") and not is_refused then
        spans[#spans + 1] = { first = position, last = close, tex = tex, is_display = false }
        position = close + 1
      else
        position = position + 1
      end
    else
      position = position + 1
    end
  end
  return spans
end

test("the span scanner pairs as the old one did, and md-render pairs exactly that", function()
  local spans_of = math_adapter._inline_math_spans
  local function same(a, b, compare_positions)
    if #a ~= #b then
      return false
    end
    for index, span in ipairs(a) do
      local other = b[index]
      if span.tex ~= other.tex or span.is_display ~= other.is_display then
        return false
      end
      if compare_positions and (span.first ~= other.first or span.last ~= other.last) then
        return false
      end
    end
    return true
  end
  local function check(line)
    local spans, escapes = spans_of(line)
    if #spans == 0 and not escapes then
      -- Nothing taken: the line is md-render's, as written.
      return
    end
    local old = old_inline_math_spans(line, true)
    if not same(spans, old, true) then
      error("pairs differently from the old scanner: " .. vim.inspect(line))
    end
    local md_render_text = line
    if escapes then
      local pieces, from = {}, 1
      for _, at in ipairs(escapes) do
        pieces[#pieces + 1] = line:sub(from, at - 1) .. "\\"
        from = at
      end
      pieces[#pieces + 1] = line:sub(from)
      md_render_text = table.concat(pieces)
    end
    if not same(spans, old_inline_math_spans(md_render_text, false), false) then
      error("md-render would pair otherwise: " .. vim.inspect(md_render_text))
    end
  end
  for _, line in ipairs({
    "It is US$3 or US$4.",
    "$5 and $10",
    "$20,000 and $30,000",
    "\\$5",
    "$x$ costs $3",
    "$a$$b$",
    "$a $3 or US$4",
    "$$3 or US$4",
    "`$x$` and $y$1 and $$z$$2",
  }) do
    check(line)
  end
  local alphabet =
    { "$", "$", "$", "$", "`", "\\", " ", "a", "x", "_", "{", "}", "1", "2", "9", "é", "*", "[" }
  math.randomseed(20261115)
  for _ = 1, 20000 do
    local parts = {}
    for index = 1, math.random(0, 20) do
      parts[index] = alphabet[math.random(#alphabet)]
    end
    check(table.concat(parts))
  end
end)

--- Bytes of the `$` of `line` md-render's math pass can be given: none in
--- a code span or escaped (markdown.lua:62, 138), nor one of `escapes`.
---@param line string
---@param escapes integer[]?
---@return integer[]
local function dollars_md_render_keeps(line, escapes)
  local masked = line:gsub("`[^`]*`", function(code)
    return ("\1"):rep(#code)
  end)
  masked = masked:gsub("\\[!-/:-@[-`{-~]", "\1\1")
  local is_escaped, dollars = {}, {}
  for _, at in ipairs(escapes or {}) do
    is_escaped[at] = true
  end
  for at in masked:gmatch("()%$") do
    if not is_escaped[at] then
      dollars[#dollars + 1] = at
    end
  end
  return dollars
end

--- Words of generated lines: prices and other stray dollars, escaped
--- dollars, code, adjacent equations, and equations inside, half inside or
--- next to every markup md-render takes away before it pairs.
local LINE_WORDS = {
  "see",
  "and",
  "costs",
  "$5",
  "US$3",
  "$",
  "$20,000",
  "5$",
  "\\$",
  "\\$5",
  "`$a$`",
  "`code`",
  "`",
  "$x_1$",
  "$Q$",
  "$a+b$",
  "$Q$$R$",
  "$Q$,",
  "($Q$)",
  "$$y$$",
  "$$ y $$",
  "$a*b*c$",
  "$x^*$",
  "**$Q$**",
  "*$Q$*",
  "_$Q$_",
  "==$Q$==",
  "~~$Q$~~",
  "%%$Q$%%",
  "[$Q$](u)",
  "[[T|$Q$]]",
  "<b>$Q$</b>",
  "**$Q",
  "R$**",
  "*$Q",
  "R$*",
  "==$Q",
  "R$==",
  "[[T|$Q",
  "R$]]",
  "[$Q",
  "R$](u)",
  "<b>$Q",
  "R$</b>",
  "**b**",
  "*i*",
  "_u_",
  "==h==",
  "~~s~~",
  "[a](u)",
  "[[T]]",
  "[[T|a]]",
  "**",
  "*",
  "_",
  "==",
  "~~",
  "[",
  "]",
  "%%",
  "%% note %%",
  "<i>",
  "</i>",
  "<!-- c -->",
  "https://e.com/$x$",
}

test("each line is md-render's as written, or the adapter pairs the `$` md-render pairs", function()
  -- md-render's math pass, watched: what its other inline passes left it,
  -- and the TeX of each pair it took there.
  local pass_index, pass
  for index = 1, math.huge do
    local name, value = debug.getupvalue(md_render_own_render, index)
    assert_true(name ~= nil, "md-render's render has its math pass")
    if name == "process_inline_math" then
      pass_index, pass = index, value
      break
    end
  end
  local given, taken
  debug.setupvalue(md_render_own_render, pass_index, function(text, group, highlights, links)
    local before = #highlights
    local processed = pass(text, group, highlights, links)
    given, taken = text, {}
    for index = before + 1, #highlights do
      taken[#taken + 1] = processed:sub(highlights[index].col + 1, highlights[index].end_col)
    end
    return processed
  end)
  --- `line` with a backslash before each `$` of `escapes`, and each `$` of
  --- `dollars` the result of `mark` for its number, or itself.
  local function line_for_md_render(line, escapes, dollars, mark)
    local is_escaped, number_of, pieces, from = {}, {}, {}, 1
    for _, at in ipairs(escapes or {}) do
      is_escaped[at] = true
    end
    for number, at in ipairs(dollars) do
      number_of[at] = number
    end
    for at in line:gmatch("()%$") do
      pieces[#pieces + 1] = line:sub(from, at - 1)
      if is_escaped[at] then
        pieces[#pieces + 1] = "\\$"
      else
        pieces[#pieces + 1] = number_of[at] and mark and mark(number_of[at]) or "$"
      end
      from = at + 1
    end
    pieces[#pieces + 1] = line:sub(from)
    return table.concat(pieces)
  end
  --- md-render's pairs of `line` with a backslash before each of `escapes`,
  --- as bytes of `line`; nil where which `$` its math pass is given is not
  --- told by marks (U+F0000 on) in their place.
  local function md_render_pairs(line, escapes)
    local dollars = dollars_md_render_keeps(line, escapes)
    md_render_own_render(line_for_md_render(line, escapes, dollars))
    local given_text, taken_texs, given_dollars, given_count = given, taken, {}, 0
    for at in given_text:gmatch("()%$") do
      given_count = given_count + 1
      given_dollars[at] = given_count
    end
    if given_count ~= #dollars then
      md_render_own_render(line_for_md_render(line, escapes, dollars, function(number)
        return "\243\176" .. string.char(0x80 + math.floor(number / 64), 0x80 + number % 64)
      end))
      local kept = {}
      for high, low in given:gmatch("\243\176([\128-\191])([\128-\191])") do
        kept[#kept + 1] = dollars[(high:byte() - 0x80) * 64 + low:byte() - 0x80]
        if not kept[#kept] or (kept[#kept - 1] or 0) >= kept[#kept] then
          return nil
        end
      end
      if #kept ~= given_count or given:find("$", 1, true) then
        return nil
      end
      dollars = kept
    end
    -- TeX holds no `$`: a pair is the first `$` on from the last closing
    -- that its TeX and a `$` follow.
    local made, search_from = {}, 1
    for _, tex in ipairs(taken_texs) do
      local opening = given_text:find("$" .. tex .. "$", search_from, true)
      local closing = opening + #tex + 1
      made[#made + 1] = {
        first = dollars[given_dollars[opening]],
        last = dollars[given_dollars[closing]],
        tex = tex,
      }
      search_from = closing + 1
    end
    return made
  end

  local spans_of = math_adapter._inline_math_spans
  local line_count, alike_left, left_for_comments, behind_markup = 20000, 0, 0, 0
  math.randomseed(20261116)
  for _ = 1, line_count do
    local words = {}
    for index = 1, math.random(1, 9) do
      words[index] = LINE_WORDS[math.random(#LINE_WORDS)]
    end
    local line = table.concat(words, math.random() < 0.15 and "" or " ")
    local spans, escapes = spans_of(line)
    local made = md_render_pairs(line, escapes)
    if #spans == 0 and not escapes then
      -- Left to md-render. Count those the scan of the line as written
      -- pairs as md-render does: each a picture not shown. Where md-render
      -- takes a comment away, the TeX in it may be another (`%% $x$ %%`).
      local written = old_inline_math_spans(line, true)
      local is_alike = made ~= nil and #made > 0 and #written == #made
      for index, span in ipairs(written) do
        is_alike = is_alike
          and not span.is_display
          and made[index].first == span.first
          and made[index].last == span.last
      end
      if is_alike and (line:find("%%", 1, true) or line:find("<!--", 1, true)) then
        left_for_comments = left_for_comments + 1
      elseif is_alike then
        alike_left = alike_left + 1
      end
    else
      local label = vim.inspect(line)
      assert_true(made ~= nil, label .. ": md-render's math pass is given other `$`")
      if line:find("[%*_=~%[|>]%$") then
        behind_markup = behind_markup + 1
      end
      local closing_of, inner_of, inline_count = {}, {}, 0
      for _, span in ipairs(spans) do
        if span.is_display then
          -- `$$tex$$`: md-render may take `$tex$` from its second `$`.
          inner_of[span.first + 1] = span.last - 1
        else
          closing_of[span.first], inline_count = span.last, inline_count + 1
        end
      end
      for _, pair in ipairs(made) do
        if closing_of[pair.first] == pair.last then
          inline_count = inline_count - 1
          local tex = line:sub(pair.first + 1, pair.last - 1)
          -- Markup in the TeX is md-render's to style; the picture is TeX's.
          if not tex:find("[%*_=~%[%]<>|\\`]") then
            assert_eq(pair.tex, tex, label .. ": md-render's TeX:")
          end
        else
          assert_eq(inner_of[pair.first], pair.last, label .. ": md-render pairs otherwise:")
        end
      end
      assert_eq(inline_count, 0, label .. ": pairs md-render does not make:")
    end
  end
  debug.setupvalue(md_render_own_render, pass_index, pass)
  assert_eq(alike_left, 0, "lines left to md-render that it pairs as written:")
  assert_true(left_for_comments < line_count / 50, "left for comments: " .. left_for_comments)
  assert_true(behind_markup > 1000, "lines with equations behind markup taken: " .. behind_markup)
end)

-- -----------------------------------------------------------------------------
-- Sizing
-- -----------------------------------------------------------------------------

test("a display picture that would shrink below half its size is text", function()
  forget_calls()
  answer("display", "floor_wide", new_picture(130, 2))
  local content = build({ "$$", "floor_wide", "$$" })
  assert_true(find_line(content, "«floor_wide»") ~= nil, "text")
  assert_true(find_line(content, STAND_IN) == nil, "no picture")
end)

test("display text wider than the line is wrapped by md-render, line numbers kept", function()
  local words = {}
  for index = 1, 30 do
    words[index] = "w" .. index
  end
  local content =
    build_as("text", { "Before.", "", "$$", table.concat(words, " "), "$$", "", "After." })
  local rows = {}
  for number, line in ipairs(content.lines) do
    assert_true(vim.api.nvim_strwidth(line) <= MAX_WIDTH, "within the view: " .. line)
    if line:find("w%d") then
      rows[#rows + 1] = number
      assert_eq(#groups_named(groups_on(content, number), "MdRenderMath"), 1, "text highlight:")
      assert_eq(content.source_line_map[number], 4, "rows stand for the TeX line:")
    end
  end
  assert_true(#rows > 1, "wrapped over " .. #rows .. " rows")
  assert_true(content.lines[rows[1]]:find("«w1 ", 1, true) ~= nil, "from the start")
  assert_true(content.lines[rows[#rows]]:find("w30»", 1, true) ~= nil, "to the end")
  assert_eq(content.source_line_map[find_line(content, "After.")], 7, "the line after:")
  assert_line_map_whole(content, "wrapped")
end)

-- -----------------------------------------------------------------------------
-- :MdRenderMath and equation_at
-- -----------------------------------------------------------------------------

--- `equation_at` where a view shows `needle`, `offset` bytes into it.
---@param view_bufnr integer
---@param needle string plain text
---@param offset? integer
---@return string?
local function equation_at_text(view_bufnr, needle, offset)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(view_bufnr, 0, -1, false)) do
    local byte = line:find(needle, 1, true)
    if byte then
      return math_adapter.equation_at(view_bufnr, index - 1, byte - 1 + (offset or 0))
    end
  end
  error("not in the view: " .. needle)
end

--- The quickfix list `:MdRenderMath errors` makes.
---@return table[]
local function listed_errors()
  vim.fn.setqflist({}, "r", { items = {} })
  vim.cmd("MdRenderMath errors")
  vim.cmd("cclose")
  return vim.fn.getqflist()
end

test(
  "equation_at and :MdRenderMath yank: the TeX of the picture or text under the cursor",
  function()
    forget_calls()
    answer("inline", "at_p", new_picture(3))
    answer("display", "at_d", new_picture(4, 2))
    local note = open_note({
      "Picture $at_p$ and text $at_t$ here.",
      "",
      "$$",
      "at_d",
      "$$",
      "",
      "$$",
      "at_dt",
      "$$",
      "",
      "Prose only.",
    })
    preview.toggle()
    local view_bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(view_bufnr, 0, -1, false)
    assert_eq(equation_at_text(view_bufnr, STAND_IN:rep(3), 3), "at_p", "inline picture:")
    assert_eq(equation_at_text(view_bufnr, "«at_t»", 3), "at_t", "inline text:")
    assert_eq(equation_at_text(view_bufnr, STAND_IN:rep(4)), "at_d", "display picture:")
    assert_eq(equation_at_text(view_bufnr, "«at_dt»"), "at_dt", "display text:")
    assert_eq(equation_at_text(view_bufnr, "Prose"), nil, "prose:")
    for index, line in ipairs(lines) do
      local byte = line:find(STAND_IN:rep(3), 1, true)
      if byte and not line:find(STAND_IN:rep(4), 1, true) then
        vim.api.nvim_win_set_cursor(0, { index, byte - 1 })
      end
    end
    vim.fn.setreg('"', "")
    vim.cmd("MdRenderMath yank")
    assert_eq(vim.fn.getreg('"'), "at_p", "yanked:")
    close_everything(note)
  end
)

test(
  ":MdRenderMath errors: the note's failed equations with TeX's message, as a quickfix list",
  function()
    forget_calls()
    answer("inline", "err_inline", false)
    answer("inline", "err_second", false)
    answer("display", "err_block", false)
    answer("display", "err_fence", false)
    fake_tex.failures["inline\0err_inline"] = "Undefined control sequence."
    fake_tex.failures["display\0err_block"] = "Missing $ inserted."
    local note, source_bufnr = open_note({
      "Line one.",
      "Bad $err_inline$ here, and $err_second$.",
      "",
      "$$",
      "err_block",
      "$$",
      "",
      "```math",
      "err_fence",
      "```",
    })
    -- As listed: in line order, those of one line as met (a failed fence is
    -- noted before everything else).
    local function listed()
      return vim.tbl_map(function(item)
        return ("%d %d %s"):format(item.bufnr, item.lnum, item.text)
      end, listed_errors())
    end
    preview.toggle()
    local expected = {
      ("%d 2 Undefined control sequence.  |  err_inline"):format(source_bufnr),
      ("%d 2 did not compile  |  err_second"):format(source_bufnr),
      ("%d 5 Missing $ inserted.  |  err_block"):format(source_bufnr),
      ("%d 9 did not compile  |  err_fence"):format(source_bufnr),
    }
    assert_eq(vim.inspect(listed()), vim.inspect(expected), "from the view:")
    preview.toggle()
    assert_eq(vim.api.nvim_get_current_buf(), source_bufnr, "back in the source")
    assert_eq(vim.inspect(listed()), vim.inspect(expected), "from the source:")
    close_everything(note)
  end
)

test(":MdRenderMath status: the mode and why not pictures; completion", function()
  local echoed
  local echo = vim.api.nvim_echo
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_echo = function(chunks)
    echoed = chunks[1][1]
  end
  local function status()
    vim.cmd("MdRenderMath status")
    return echoed:match("^[^\n]*")
  end
  local results = { status() }
  fake_kitty.supported = false
  results[2] = status()
  fake_kitty.supported, fake_tex.is_available_answer = true, false
  results[3] = status()
  fake_tex.is_available_answer = true
  vim.g.md_render_math = "off"
  results[4] = status()
  vim.g.md_render_math = nil
  vim.api.nvim_echo = echo
  assert_eq(results[1], "md-render math: pictures", "pictures:")
  assert_eq(results[2], "md-render math: text (terminal: TERM is not xterm-kitty)", "terminal:")
  assert_eq(results[3], "md-render math: text (TeX: pdftex not found)", "TeX:")
  assert_eq(results[4], 'md-render math: off (vim.g.md_render_math = "off")', "off:")
  assert_eq(
    table.concat(vim.fn.getcompletion("MdRenderMath ", "cmdline"), " "),
    "status errors retry yank",
    "completion:"
  )
  assert_eq(table.concat(vim.fn.getcompletion("MdRenderMath r", "cmdline"), " "), "retry", "lead:")
end)

-- -----------------------------------------------------------------------------
-- Nothing md-render shows is lost
-- -----------------------------------------------------------------------------

--- The same lines built by md-render alone and in text mode.
---@param lines string[]
---@return table alone
---@return table ours
local function alone_and_text(lines)
  return build_as("off", lines), build_as("text", lines)
end

--- Tokens (`W1q`, `aaa`, ...) on a content's lines -> the first line showing each.
---@param content table
---@param pattern string
---@return table<string, string>
local function tokens_shown(content, pattern)
  local shown = {}
  for _, line in ipairs(content.lines) do
    for token in line:gmatch(pattern) do
      shown[token] = shown[token] or line
    end
  end
  return shown
end

---@return string[] tokens md-render alone shows that this module does not
local function lost_tokens(alone, ours, pattern)
  local shown, lost = tokens_shown(ours, pattern), {}
  for token in pairs(tokens_shown(alone, pattern)) do
    if not shown[token] then
      lost[#lost + 1] = token
    end
  end
  table.sort(lost)
  return lost
end

test("a $$ line with TeX on it is md-render's: no block, nothing lost", function()
  local cases = {
    { "Para:", "", "$$ aaa", "xxx", "bbb $$", "", "after" },
    { "Para:", "", "$$", "xxx", "$$ (1)", "", "after" },
    { "Para:", "", "$$ ", "xxx", "$$ ", "", "after" },
    { "> [!note] T", "> $$ aaa", "> xxx", "> bbb $$", "", "after" },
  }
  for _, case in ipairs(cases) do
    local alone, ours = alone_and_text(case)
    local label = table.concat(case, " | ")
    assert_eq(table.concat(lost_tokens(alone, ours, "%l%l%l+"), " "), "", label .. ": lost:")
    forget_calls()
    build(case)
    assert_eq(#vim.tbl_filter(function(lookup)
      return lookup.kind == "display"
    end, fake_tex.lookups), 0, label .. ": no block:")
  end
end)

test("$$ blocks where md-render reads them: at the item's column, tabs to stops of 4", function()
  -- One column past the inner item's content: prose md-render joins into the
  -- item, so the block runs on to the `$$` at column 0.
  local deep = { "$$", "aaa", "- bbb", "  - ccc", "      $$", "      ddd", "$$", "after" }
  local alone, ours = alone_and_text(deep)
  assert_eq(table.concat(lost_tokens(alone, ours, "%l%l%l+"), " "), "", "too deep: lost:")
  -- A tab is 4 columns: the inner item's content column.
  local tabbed = { "- a", "  - b", "\t$$", "\taaa", "\t$$", "after" }
  alone, ours = alone_and_text(tabbed)
  assert_true(find_line(alone, "aaa") ~= nil, "md-render reads a block")
  assert_true(find_line(ours, "«aaa»") ~= nil, "tab: the block is math")
  -- `> $$` needs one `>` and at most one space: `>  $$` is prose to md-render.
  local quoted = { ">  $$", ">  aaa", ">  $$", "> after" }
  alone, ours = alone_and_text(quoted)
  assert_eq(table.concat(lost_tokens(alone, ours, "%l%l%l+"), " "), "", "quote markers: lost:")
  -- Five spaces or more after a list marker: the content column is the one
  -- right after the marker and its space.
  local five_spaces = { "-     aaa", "  $$", "  bbb", "  $$", "after" }
  alone, ours = alone_and_text(five_spaces)
  assert_true(find_line(alone, "bbb") ~= nil, "five spaces: md-render reads a block")
  assert_true(find_line(ours, "«bbb»") ~= nil, "five spaces: the block is math")
  -- A tab after spaces goes to the next stop: `  \t` is 4 columns, not 6.
  local tab_after_spaces = { "- a", "  - b", "  \t$$", "  \tccc", "  \t$$", "after" }
  alone, ours = alone_and_text(tab_after_spaces)
  assert_true(find_line(alone, "ccc") ~= nil, "tab after spaces: md-render reads a block")
  assert_true(find_line(ours, "«ccc»") ~= nil, "tab after spaces: the block is math")
end)

test("quoted and plain blocks pair as md-render reads them", function()
  -- 1. The quote ends before its block closes: that block is unclosed, and
  -- the next quote's block is a block of its own.
  local ended = { "> $$", "> aaa", "", "para", "", "> $$", "> bbb", "> $$" }
  local alone, ours = alone_and_text(ended)
  assert_eq(table.concat(lost_tokens(alone, ours, "%l%l%l+"), " "), "", "quote ended: lost:")
  local function count_of(content, needle)
    local count = 0
    for _, line in ipairs(content.lines) do
      count = count + select(2, line:gsub(needle, ""))
    end
    return count
  end
  assert_eq(count_of(ours, "para"), count_of(alone, "para"), "quote ended: `para` shown:")
  assert_true(find_line(ours, "«bbb»") ~= nil, "the next quote's block is math")
  -- 2. `> $$` lines in a quoted code fence are code.
  local fenced = { "> ```", "> $$", "> aaa", "> $$", "> ```", "", "after" }
  alone, ours = alone_and_text(fenced)
  assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "quoted fence:")
  -- 3. A TeX line of a plain block that starts with `>` keeps it.
  forget_calls()
  build({ "$$", "f(x)", "> 0", "$$" })
  local texs = {}
  for _, lookup in ipairs(fake_tex.lookups) do
    texs[#texs + 1] = lookup.kind .. ": " .. lookup.tex
  end
  assert_eq(table.concat(texs, " | "), "display: f(x)\n> 0", "plain block, `> 0`:")
  -- ... and a quoted block's lines lose only its own markers.
  forget_calls()
  build({ "> $$", "> f(x)", "> > 0", "> $$" })
  texs = {}
  for _, lookup in ipairs(fake_tex.lookups) do
    texs[#texs + 1] = lookup.kind .. ": " .. lookup.tex
  end
  assert_eq(table.concat(texs, " | "), "display: f(x)\n> 0", "quoted block, `> > 0`:")
  -- 4. A fence line inside a quoted block is TeX: it opens no fence that
  -- would hide the closing `> $$`.
  _, ours = alone_and_text({ "> $$", "> ~~~", "> aaa", "> $$", "", "after" })
  assert_true(
    find_line(ours, "«~~~»") ~= nil,
    "a fence line in a quoted block: the block is math"
  )
end)

--- How many times each token is shown.
---@param content table
---@param pattern string
---@return table<string, integer>
local function token_counts(content, pattern)
  local counts = {}
  for _, line in ipairs(content.lines) do
    for token in line:gmatch(pattern) do
      counts[token] = (counts[token] or 0) + 1
    end
  end
  return counts
end

--- The display TeX a build of `lines` looks up, in order.
---@param lines string[]
---@return string[]
local function display_lookups(lines)
  forget_calls()
  build(lines)
  local texs = {}
  for _, lookup in ipairs(fake_tex.lookups) do
    if lookup.kind == "display" then
      texs[#texs + 1] = lookup.tex
    end
  end
  return texs
end

test(
  "only md-render's own `> $$` row opens a quoted block: not code, a paragraph or a gap",
  function()
    -- Code showing a callout with a block: code, as md-render shows it.
    local code = {
      {
        "Example:",
        "",
        "```markdown",
        "> [!note] Title",
        "> $$",
        "> aaa",
        "> $$",
        "```",
        "",
        "end",
      },
      { "Example:", "", "    > [!note] Title", "    > $$", "    > aaa", "    > $$", "", "end" },
    }
    for _, note in ipairs(code) do
      local alone, ours = alone_and_text(note)
      assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), note[3] .. ": the code:")
      assert_eq(#display_lookups(note), 0, note[3] .. ": no block:")
    end
    -- Five spaces, or past a list item's content: one paragraph to md-render.
    local paragraphs = {
      { "Before.", "", "     > $$", "     > aaa", "     > $$", "     rest of the paragraph" },
      { "- item", "", "      > $$", "      > aaa", "      > $$", "      rest of the paragraph" },
    }
    for _, note in ipairs(paragraphs) do
      local alone, ours = alone_and_text(note)
      assert_eq(table.concat(lost_tokens(alone, ours, "%l%l%l+"), " "), "", note[1] .. ": lost:")
    end
    -- md-render's blank row after a table or a rule carries the next line.
    for _, before in ipairs({ { "| a | b |", "|---|---|", "| 1 | 2 |" }, { "---" } }) do
      local note = vim.list_extend(vim.list_slice(before), { "> $$", "> aaa", "> $$", "> end" })
      local _, ours = alone_and_text(note)
      assert_eq(token_counts(ours, "aaa").aaa, 1, before[1] .. ": the block shown once:")
      assert_true(find_line(ours, "«aaa»") ~= nil, before[1] .. ": as math")
    end
  end
)

test(
  "a TeX line starting with `|` (a ket, a norm): the block once, or as md-render shows it",
  function()
    local kets = {
      "Before.",
      "",
      "$$",
      "\\begin{aligned}",
      "|\\psi\\rangle &= \\alpha |0\\rangle \\\\",
      "|\\phi\\rangle &= \\gamma |0\\rangle",
      "\\end{aligned}",
      "$$",
      "",
      "After.",
    }
    local _, ours = alone_and_text(kets)
    assert_eq(token_counts(ours, "psi").psi, 1, "a `|` line inside: shown once:")
    assert_eq(token_counts(ours, "phi").phi, 1, "and the next:")
    assert_eq(
      display_lookups(kets)[1],
      table.concat(vim.list_slice(kets, 4, 7), "\n"),
      "the whole block is its TeX:"
    )
    -- md-render's first row of the block is a table row: the block is its.
    local first = { "Before.", "", "$$", "|x| = 1", "y", "$$", "", "After." }
    local alone
    alone, ours = alone_and_text(first)
    assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "a `|` line first:")
  end
)

test("after a closing `$$ (1)`, `$$ ` or `tex $$`, no block is drawn: prose stays prose", function()
  for _, closing in ipairs({ "$$ (1)", "$$ ", "+ c $$" }) do
    for _, prefix in ipairs({ "", "> " }) do
      local note = {}
      for _, line in ipairs({ "$$", "a = b", closing, "", "Prose aaa here.", "" }) do
        note[#note + 1] = (line == "" and prefix ~= "") and ">" or (prefix .. line)
      end
      vim.list_extend(note, { prefix .. "$$", prefix .. "c = d", prefix .. "$$", "", "End bbb." })
      local label = ("%q"):format(prefix .. closing)
      local alone, ours = alone_and_text(note)
      assert_eq(
        vim.inspect(ours.lines),
        vim.inspect(alone.lines),
        label .. ": as md-render shows it:"
      )
      assert_eq(#display_lookups(note), 0, label .. ": no block:")
    end
  end
  -- `$$ tex` closed by `tex $$`: md-render's paragraph; the blocks after it
  -- are drawn.
  local _, ours =
    alone_and_text({ "$$ a = b", "+ c $$", "", "Prose aaa.", "", "$$", "c = d", "$$" })
  assert_true(find_line(ours, "«c = d»") ~= nil, "a proper block after it is math")
  -- Nor is a ```math fence after it rewritten: md-render's block may be open.
  local fence_after =
    { "$$", "a = b", "$$ (1)", "", "Prose.", "", "```math", "c = d", "```", "", "end" }
  local alone
  alone, ours = alone_and_text(fence_after)
  assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "a fence after it:")
end)

test(
  "`$$ tex`, then a `$$`: md-render's block from there is not drawn; after a blank it is",
  function()
    -- md-render reads no delimiter in `$$ a = b` and opens a block at the
    -- `$$` the writer closed with: the prose below is inside it.
    local note = { "$$ a = b", "$$", "Prose aaa here.", "", "$$", "c = d", "$$", "", "End bbb." }
    local alone, ours = alone_and_text(note)
    assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "as md-render shows it:")
    assert_eq(#display_lookups(note), 0, "nothing drawn:")
    -- A blank line ends the paragraph `$$ a = b` began: the `$$` lines after
    -- it pair as written.
    assert_eq(
      table.concat(
        display_lookups({ "$$ a = b", "", "Prose aaa.", "", "$$", "c = d", "$$" }),
        " | "
      ),
      "c = d",
      "after a blank line, the block is drawn:"
    )
  end
)

test(
  "a `$$` one to three columns past its item's content is joined into it: nothing drawn",
  function()
    for _, note in ipairs({
      { "- item", "   $$", "   aaa", "$$", "", "Prose bbb.", "", "$$", "ccc", "$$" },
      { "- item", "   $$", "   aaa", "   $$", "$$", "", "Prose bbb.", "", "$$", "ccc", "$$" },
    }) do
      local label = table.concat(note, " | ")
      local alone, ours = alone_and_text(note)
      assert_eq(table.concat(lost_tokens(alone, ours, "%l%l%l+"), " "), "", label .. ": lost:")
      assert_true(find_line(ours, "«Prose") == nil, label .. ": prose stays prose")
      assert_eq(#display_lookups(note), 0, label .. ": nothing drawn:")
    end
  end
)

test("a `$` behind markup md-render takes away first pairs as md-render pairs it", function()
  -- md-render pairs after its emphasis pass: `$5 and see $Q4Z$ b`.
  local costs = { "Costs $5 and see **$Q4Z$** b" }
  local alone, ours = alone_and_text(costs)
  assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "as md-render shows it:")
  forget_calls()
  build(costs)
  assert_eq(#fake_tex.lookups, 0, "nothing looked up:")
  -- Where it pairs as written, behind markup or with markup-like TeX, the
  -- equations are drawn.
  forget_calls()
  build({
    "See **$q_4$** and [[N|$r_5$]] and ==$s_6$== here.",
    "",
    "where (blue) *constant* $= p_1 V_1 = p_2 V_2$.",
  })
  local texs = vim.tbl_map(function(lookup)
    return lookup.tex
  end, fake_tex.lookups)
  table.sort(texs)
  assert_eq(table.concat(texs, " | "), "= p_1 V_1 = p_2 V_2 | q_4 | r_5 | s_6", "drawn:")
end)

test(":MdRenderMath errors and status name the `$$` line from which blocks are left", function()
  local echoed
  local echo = vim.api.nvim_echo
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_echo = function(chunks)
    echoed = chunks[1][1]
  end
  local message = "TeX on a `$$` line: the blocks below it are left to md-render"
  local note, source_bufnr = open_note({
    "Line one.",
    "",
    "$$",
    "a = b",
    "$$",
    "",
    "$$ c = d",
    "$$",
    "Prose.",
    "",
    "$$",
    "e = f",
    "$$",
  })
  preview.toggle()
  local items = vim.tbl_map(function(item)
    return ("%d %d %s"):format(item.bufnr, item.lnum, item.text)
  end, listed_errors())
  assert_eq(
    vim.inspect(items),
    vim.inspect({ ("%d 8 %s"):format(source_bufnr, message) }),
    "errors:"
  )
  vim.cmd("MdRenderMath status")
  assert_true(echoed:find("\n  line 8: " .. message, 1, true) ~= nil, "status: " .. echoed)
  close_everything(note)
  -- Nothing left: neither lists a line.
  note = open_note({ "$$", "a = b", "$$" })
  preview.toggle()
  assert_eq(#listed_errors(), 0, "errors of a note without such a line:")
  vim.cmd("MdRenderMath status")
  vim.api.nvim_echo = echo
  assert_true(not echoed:find("line %d+: TeX on"), "status of it: " .. echoed)
  close_everything(note)
end)

test("a TeX comment in an equation over two source lines ends at its line", function()
  local cases = {
    {
      { "Value $$ a = b % the first term", "+c $$ end." },
      "\\displaystyle a = b % the first term\n+c",
    },
    { { "Value $a = b % first", "c + d$ end." }, "a = b % first\nc + d" },
    { { "Value $a = b \\\\% first", "c + d$ end." }, "a = b \\\\% first\nc + d" },
    -- An escaped `%` is no comment: the paragraph's line, as written.
    { { "Value $a \\% b", "c + d$ end." }, "a \\% b c + d" },
  }
  for _, case in ipairs(cases) do
    forget_calls()
    build(case[1])
    assert_eq(#fake_tex.lookups, 1, case[1][1] .. ": one lookup:")
    assert_eq(fake_tex.lookups[1].tex, case[2], case[1][1] .. ":")
  end
end)

test(
  "quoted blocks: delimiters of one depth, rows of md-render's quote; fences pair as rewritten",
  function()
    local as_written = {
      { ">> $$", "> aaa", ">> $$", "", "after" },
      { ">> $$", "> [!note] T", "> $$", "> aaa", "", "after" },
      { "> $$", "    > aaa", "> $$", "", "after" },
      { "- item", "  > $$", "      > aaa", "  > $$", "", "after" },
      { "- item", "  > $$", "  > aaa", "> $$", "", "after" },
      { "> $$", "> aaa", ">> $$", "> bbb", "> $$", "", "after" },
    }
    for _, note in ipairs(as_written) do
      local alone, ours = alone_and_text(note)
      assert_eq(
        vim.inspect(ours.lines),
        vim.inspect(alone.lines),
        table.concat(note, " | ") .. ": as md-render shows it:"
      )
    end
    -- A `> $$` written before a ```math fence or after it pairs with none of
    -- its lines: the prose between stays prose.
    local stray_before =
      { "> [!note] T", "> $$", "> Some prose aaa.", "> ```math", "> Q = b", "> ```", "", "end" }
    assert_eq(table.concat(display_lookups(stray_before), " | "), "Q = b | Q = b", "stray before:")
    local stray_after =
      { "> ```math", "> Q = b", "> ```", "> Some prose aaa.", "> $$", "> ccc", "> $$" }
    assert_eq(
      table.concat(display_lookups(stray_after), " | "),
      "Q = b | Q = b | ccc",
      "stray after:"
    )
    -- A fence whose lines md-render does not read as one quote, or closed
    -- by a line of another depth (code to md-render): code.
    for _, note in ipairs({
      { ">> ```math", "> aaa", ">> ```", "", "end" },
      { "> ```math", "    > aaa", "> ```", "", "end" },
      { "> ```math", "> aaa", "> > ```", "> bbb", "", "end" },
      { "> ```", "> > ```", "> $$", "> aaa", "> $$", "> ```", "", "end" },
    }) do
      local alone, ours = alone_and_text(note)
      assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), note[3] .. ": the code:")
    end
    -- A fence of an inner quote ends with it: the block after it is math.
    local _, ours = alone_and_text({ ">> ```", "> $$", "> aaa", "> $$", "", "end" })
    assert_true(
      find_line(ours, "«aaa»") ~= nil,
      "after an inner quote's fence: the block is math"
    )
  end
)

test("```math fences md-render would read otherwise once rewritten: left as code", function()
  -- A fence line inside: rewritten, it would open a fence that swallows the
  -- closing `$$` (md-render's earlier passes leave fenced lines whole).
  local inner_fence = {
    "- aaa",
    "  ```math",
    "    bbb",
    "      ```",
    "",
    "- ccc",
    "  ```math",
    "  ddd",
    "  ``` ",
    "",
    "Text[^n] eee",
    "",
    "[^n]: fff",
    "    ggg",
    "    $$  ",
    "    hhh",
    "",
  }
  local alone, ours = alone_and_text(inner_fence)
  assert_eq(table.concat(lost_tokens(alone, ours, "%l%l%l+"), " "), "", "inner fence: lost:")
  -- A quoted line does not close an unquoted fence: all of it is code.
  local quoted_closing = { "```math", "aaa", "> ```", "bbb", "```", "after" }
  alone, ours = alone_and_text(quoted_closing)
  assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "quoted closing line:")
  -- A quoted fence ends with its quote: the block after it is math.
  local quote_ended = { "> ```", "> x", "", "$$", "aaa", "$$" }
  _, ours = alone_and_text(quote_ended)
  assert_true(find_line(ours, "«aaa»") ~= nil, "after a quoted fence: the block is math")
  -- One column past its item: rewritten, the `$$` lines would be prose.
  local too_deep = { "1. item", "    ```math", "    aaa", "    ```", "", "after" }
  alone, ours = alone_and_text(too_deep)
  assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "past the item's column:")
  -- In a `:::note` md-render reads no block.
  local in_note = { ":::note", "```math", "aaa", "```", ":::", "after" }
  alone, ours = alone_and_text(in_note)
  assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "in a note:")
  -- In a `$$` block md-render reads no fence: the block ends at its `$$`.
  local fence_in_block = { "$$", "aaa", "~~~", "$$", "", "after" }
  _, ours = alone_and_text(fence_in_block)
  assert_true(find_line(ours, "«aaa»") ~= nil, "a fence line in a block: the block is math")
  -- A `$$` line inside would end the block md-render reads at it.
  local delimiter_inside = { "```math", "aaa", "$$", "bbb", "```", "", "after" }
  alone, ours = alone_and_text(delimiter_inside)
  assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "a `$$` line inside:")
  -- In a `<details>` md-render may show a code block where it hides a block.
  local in_details = { "<details>", "```math", "aaa", "```" }
  alone, ours = alone_and_text(in_details)
  assert_eq(vim.inspect(ours.lines), vim.inspect(alone.lines), "in a <details>:")
end)

--- A note of containers md-render reads `$$` lines in differently, each
--- holding a block in one of the forms people write: tokens `W<n>q` for
--- words, `T<n>q` for TeX, `C<n>q` for anything in a code fence.
---@return string[]
local function generated_note()
  local lines, token_count, is_in_code = {}, 0, false
  local function pick(list)
    return list[math.random(#list)]
  end
  local function token(kind)
    token_count = token_count + 1
    return (is_in_code and "C" or kind) .. token_count .. "q"
  end
  local function add(text)
    lines[#lines + 1] = text
  end
  local function prose()
    local word = token("W")
    if math.random(8) <= 5 then
      return word .. pick({ "", " and $x^2$", " costs US$3 or US$4", " `a$b$c`", " $$y$$" })
    end
    -- An equation inside markup md-render takes away before it pairs, with
    -- a stray price before or after it.
    local equation = pick({
      "**%s**",
      "*%s*",
      "_%s_",
      "==%s==",
      "~~%s~~",
      "[%s](u)",
      "[[N|%s]]",
      "%%%%%s%%%%",
      "<b>%s</b>",
      "(%s)",
    }):format("$" .. token("T") .. "$")
    return word
      .. pick({ " ", " costs $5 and ", " $5 ", " US$3 " })
      .. equation
      .. pick({ "", " or $4", " $", " " .. token("W") })
  end
  local function block(first, rest)
    add(first .. pick({ "$$", "$$", "$$", "$$ ", " $$", "$$\t", "$$  " }))
    for _ = 1, math.random(0, 2) do
      -- A TeX line may start with `>` (`> 0`) or `|` (a ket, a norm).
      add(rest .. pick({ "", "", "> ", "|" }) .. token("T") .. pick({ "", " + 1", " \\\\" }))
    end
    -- `$$ (1)` and `tex $$`: the writer closes, md-render does not.
    add(rest .. pick({ "$$", "$$", "$$", "$$ ", " $$", "$$  ", "$$ (1)", token("T") .. " $$" }))
  end
  local function body(first, rest)
    local choice = math.random(6)
    if choice <= 3 then
      block(first, rest)
    elseif choice == 4 then
      add(first .. "```math")
      add(rest .. token("T"))
      add(rest .. pick({ "```", "``` ", "  ```", "````" }))
    else
      add(first .. prose())
      block(rest, rest)
    end
  end
  --- Lines of one of `shapes`, each `T` or `W` at a line's end a token.
  local function add_shape(shapes)
    for _, line in ipairs(pick(shapes)) do
      add((line:gsub("[TW]$", token)))
    end
  end
  local containers = {
    function()
      body("", "")
    end,
    function()
      add(prose())
      body("", "")
    end,
    function()
      add("- " .. prose())
      body(pick({ "  ", "    ", "\t", "" }), pick({ "  ", "    ", "\t", "" }))
    end,
    function()
      add("1. " .. prose())
      local indent = pick({ "   ", "    ", "  " })
      body(indent, indent)
    end,
    function()
      add("- " .. prose())
      add("  - " .. prose())
      local indent = pick({ "    ", "  ", "      " })
      body(indent, indent)
    end,
    function()
      local prefix = pick({ "> ", ">", "> > ", ">  " })
      if math.random(2) == 1 then
        add(prefix .. prose())
      end
      body(prefix, prefix)
      add(prefix .. prose())
    end,
    function()
      add("> [!note] " .. prose())
      body("> ", "> ")
    end,
    function()
      -- A title long enough to wrap, with pictures on its first row.
      add(
        ("> [!%s]%s %s with $x^2$ and $z_1$ and %s and %s more words until it wraps"):format(
          pick({ "note", "tip" }),
          pick({ "", "-", "+" }),
          token("W"),
          token("W"),
          token("W")
        )
      )
      body("> ", "> ")
    end,
    function()
      add(
        ("%s %s with $x^2$ and words %s until it wraps %s"):format(
          pick({ "#", "####" }),
          token("W"),
          token("W"),
          token("W")
        )
      )
    end,
    function()
      add("- " .. prose())
      body("  > ", "  > ")
    end,
    function()
      -- A quote that ends before its block closes; the next quote's block.
      add("> $$")
      add("> " .. token("T"))
      add("")
      add(prose())
      add("")
      add("> $$")
      add("> " .. token("T"))
      add("> $$")
    end,
    function()
      -- `> $$` lines of other depths, and lines that are no quote row.
      add_shape({
        { ">> $$", "> T", ">> $$" },
        { "> $$", "> T", ">> $$", "> T", "> $$" },
        { "> $$", "> > T", "> $$" },
        { "> $$", "    > T", "> $$" },
        { "- W", "  > $$", "      > T", "  > $$" },
        { "- W", "  > $$", "  > T", "> $$" },
        { "| a | b |", "|---|---|", "| 1 | 2 |", "> $$", "> T", "> $$" },
      })
    end,
    function()
      -- A stray `> $$` before or after a quoted ```math fence.
      add_shape({
        { "> [!note] W", "> $$", "> W", "> ```math", "> T", "> ```" },
        { "> ```math", "> T", "> ```", "> W", "> $$", "> T", "> $$" },
      })
    end,
    function()
      -- `> $$` lines in a quoted code fence are code.
      add("> ```")
      is_in_code = true
      add("> $$")
      add("> " .. token("C"))
      add("> $$")
      is_in_code = false
      add("> ```")
    end,
    function()
      -- Code showing a callout with a block, and a paragraph that looks
      -- like one (five spaces: one paragraph, its `$$ > ... > $$` math).
      local choice = math.random(3)
      if choice == 1 then
        add("```markdown")
        is_in_code = true
        add("> [!note] " .. token("C"))
        add("> $$")
        add("> " .. token("C"))
        add("> $$")
        is_in_code = false
        add("```")
      else
        add(prose())
        if choice == 2 then
          add("")
        end
        is_in_code = choice == 2
        local indent = choice == 2 and "    " or "     "
        add(indent .. "> $$")
        add(indent .. "> " .. token("T"))
        add(indent .. "> $$")
        is_in_code = false
      end
    end,
    function()
      -- A TeX comment in an equation over two source lines.
      add(token("W") .. " is $a % " .. token("T"))
      add(token("T") .. " + b$ " .. token("W"))
    end,
    function()
      add(pick({ ":::note", ":::message", ":::note Title" }))
      body("", "")
      add(":::")
    end,
    function()
      add(prose())
      add("")
      body("    ", "    ")
    end,
    function()
      local label = token("F")
      add("Text[^" .. label .. "] " .. prose())
      add("")
      add("[^" .. label .. "]: " .. prose())
      body("    ", "    ")
    end,
    function()
      add("| a | b |")
      add("|---|---|")
      add("| $$ " .. token("T") .. " | " .. token("W") .. " |")
    end,
    function()
      -- Tildes: no backtick fence of the block inside can close it.
      add(pick({ "~~~~", "~~~~lua" }))
      is_in_code = true
      body("", "")
      is_in_code = false
      add("~~~~")
    end,
  }
  for _ = 1, math.random(2, 6) do
    pick(containers)()
    add(pick({ "", "", prose() }))
    add("")
  end
  if math.random(4) == 1 then
    for index, line in ipairs(lines) do
      lines[index] = line .. "\r"
    end
  end
  return lines
end

--- A block's TeX as a writer reads it: the lines between the delimiter
--- lines (`$$` or a fence, quote markers and indent aside) above and below
--- the line of its first token, each without as many quote markers as the
--- opening has and without its indent. Independent of the adapter's pairing.
---@param note string[]
---@param tex string
---@return string?
local function written_block_tex(note, tex)
  local token = tex:match("T%d+q")
  local token_line
  for index, line in ipairs(note) do
    if token and line:find(token, 1, true) then
      token_line = index
    end
  end
  if not token_line then
    return nil
  end
  local function is_delimiter(index)
    local text = note[index]:gsub("^[%s>]*", "")
    return text:find("^%$%$") or text:find("^[`~][`~][`~]")
  end
  local opening, closing = token_line - 1, token_line + 1
  while opening > 1 and not is_delimiter(opening) do
    opening = opening - 1
  end
  while closing < #note and not is_delimiter(closing) do
    closing = closing + 1
  end
  local markers = select(2, (note[opening]:match("^%s*>[>%s]*") or ""):gsub(">", ""))
  local tex_lines = {}
  for index = opening + 1, closing - 1 do
    local line = note[index]
    for _ = 1, markers do
      line = line:gsub("^%s*>%s?", "", 1)
    end
    tex_lines[#tex_lines + 1] = (line:gsub("^%s+", ""))
  end
  return table.concat(tex_lines, "\n")
end

--- Every `$...$` and `$$...$$` a simple scan finds in the texts md-render
--- renders, whatever pairs md-render makes: inline TeX can only be one.
---@param texts string[]
---@return table<string, true>
local function written_inline_texs(texts)
  local candidates = {}
  for _, text in ipairs(texts) do
    for position in text:gmatch("()%$") do
      local close = text:find("$", position + 1, true)
      if close then
        candidates[text:sub(position + 1, close - 1)] = true
      end
      close = text:sub(position + 1, position + 1) == "$" and text:find("$$", position + 2, true)
      if close then
        candidates["\\displaystyle " .. vim.trim(text:sub(position + 2, close - 1))] = true
      end
    end
  end
  return candidates
end

--- Pictures by kind and width, shared by the notes: few highlight groups.
local picture_pool = {}

--- A build of `note` in which every equation has a picture: the content,
--- the equations looked up, and the texts md-render rendered.
---@param note string[]
---@param width integer
---@return table content
---@return { kind: string, tex: string }[] lookups
---@return string[] rendered
local function built_with_pictures(note, width)
  local lookup, markdown = fake_tex.lookup, require("md-render.markdown")
  local render = markdown.render
  local looked_up, rendered = {}, {}
  fake_tex.lookup = function(equation)
    looked_up[#looked_up + 1] = { kind = equation.kind, tex = equation.tex }
    local is_inline = equation.kind == "inline"
    local columns = (is_inline and 2 or 4) + #equation.tex % 3
    local key = equation.kind .. columns
    picture_pool[key] = picture_pool[key] or new_picture(columns, is_inline and 1 or 2)
    return picture_pool[key]
  end
  markdown.render = function(text, ...)
    rendered[#rendered + 1] = text
    return render(text, ...)
  end
  local is_built, content = pcall(preview.build_content, note, { max_width = width })
  fake_tex.lookup, markdown.render = lookup, render
  if not is_built then
    error(content, 0)
  end
  return content, looked_up, rendered
end

--- Each picture highlight whose bytes are not exactly a row of its cells.
---@param content table
---@return string[]
local function misplaced_pictures(content)
  local cells_of_group = {}
  for _, key in ipairs(images) do
    cells_of_group[images[key].group] = images[key].rows[1]
  end
  local misplaced = {}
  for line_number, line in ipairs(content.lines) do
    for _, group in ipairs(picture_groups_on(content, line_number)) do
      if covered(line, group) ~= cells_of_group[group.hl] then
        misplaced[#misplaced + 1] = ("row %d [%d,%d)"):format(line_number, group.col, group.end_col)
      end
    end
  end
  return misplaced
end

-- 300 notes here; 50000 more were run outside the spec while writing this
-- (`MD_RENDER_MATH_SEED` and `MD_RENDER_MATH_NOTES` set; see the report).
local GENERATED_NOTE_SEED = tonumber(vim.env.MD_RENDER_MATH_SEED) or 20261116
local GENERATED_NOTE_COUNT = tonumber(vim.env.MD_RENDER_MATH_NOTES) or 300

test(
  ("generated notes (seed %d, %d): shown as md-render shows them, once, as written"):format(
    GENERATED_NOTE_SEED,
    GENERATED_NOTE_COUNT
  ),
  function()
    math.randomseed(GENERATED_NOTE_SEED)
    for note_index = 1, GENERATED_NOTE_COUNT do
      local note = generated_note()
      local alone, ours = alone_and_text(note)
      local label = ("note %d (%s)"):format(note_index, table.concat(note, " | "))
      assert_eq(
        table.concat(lost_tokens(alone, ours, "[WTC]%d+q"), " "),
        "",
        label .. ": lost words, TeX and code:"
      )
      local shown_alone, twice = token_counts(alone, "[WTC]%d+q"), {}
      for token, count in pairs(token_counts(ours, "[WTC]%d+q")) do
        if count > (shown_alone[token] or 0) then
          twice[#twice + 1] = token
        end
      end
      table.sort(twice)
      assert_eq(table.concat(twice, " "), "", label .. ": shown more often than md-render shows:")
      -- The only lines ever rewritten: a ```math fence's, into `$$`.
      local rewritten = math_adapter._blocks_as_md_render_reads_them(note, 0)
      for index, line in ipairs(note) do
        if rewritten[index] ~= line then
          assert_true(
            line:find("^[%s>]*[`~][`~][`~]") and rewritten[index]:find("^[%s>]*%$%$$"),
            ("%s: line %d rewritten: %q -> %q"):format(label, index, line, rewritten[index])
          )
        end
      end
      -- With pictures, at a width that wraps more: each where its cells are,
      -- and every equation's TeX as written.
      local content, lookups, rendered = built_with_pictures(note, 40)
      assert_eq(table.concat(misplaced_pictures(content), " "), "", label .. ": misplaced:")
      local inline_texs = written_inline_texs(rendered)
      for _, lookup in ipairs(lookups) do
        if lookup.kind == "display" then
          -- Inline, md-render's own `$` pairs decide (a paragraph may pair
          -- `$$ W1q $$`); a block is the writer's.
          assert_true(
            not lookup.tex:find("[WC]%d+q"),
            ("%s: block TeX holds prose or code: %q"):format(label, lookup.tex)
          )
          local written = written_block_tex(note, lookup.tex)
          assert_true(
            written == nil or written == lookup.tex,
            ("%s: block TeX %q, written %q"):format(label, lookup.tex, written)
          )
        else
          assert_true(
            inline_texs[lookup.tex:gsub("\n", " ")],
            ("%s: inline TeX %q not written so"):format(label, lookup.tex)
          )
        end
      end
    end
  end
)

test("links on a line with escaped dollars: every text field as md-render makes it", function()
  local cases = {
    "[t](http://x.y/US$3_or_US$4) US$3 or US$4",
    "http://x.y/a$3b$4 tail",
    "<http://x.y/a$3b$4> tail",
    "[[Note$3 and$4]] tail",
    "See [[Budget $300 vs $400|the budget]] and more.",
  }
  --- The text fields of each link (its columns follow the line, which
  --- differs where md-render took a price for math).
  local function text_fields(content)
    return vim.tbl_map(function(link)
      local fields = {}
      for name, value in pairs(link) do
        if type(value) == "string" then
          fields[name] = value
        end
      end
      return fields
    end, content.link_metadata or {})
  end
  for _, case in ipairs(cases) do
    local alone, ours = alone_and_text({ case })
    assert_true(#(ours.link_metadata or {}) > 0, case .. ": a link")
    assert_eq(
      vim.inspect(text_fields(ours)),
      vim.inspect(text_fields(alone)),
      case .. ": its links:"
    )
    assert_true(
      not table.concat(ours.lines):find("\239\128\164", 1, true),
      case .. ": no placeholder"
    )
  end
end)

test("a callout title is md-render's: dollars in it are not escaped", function()
  local source = { "> [!note] Budget US$3 or US$4", "> Body $3 and $4." }
  local alone, ours = alone_and_text(source)
  assert_eq(ours.lines[1], alone.lines[1], "the title:")
  assert_true(not ours.lines[1]:find("\\", 1, true), "no backslash shown")
end)

test("equation_at: the equation under the cursor, not one whose text contains it", function()
  forget_calls()
  local upstream_inline = fake_text.inline
  -- As the real text module: `x^2` shows as `x²`, which contains `x`.
  fake_text.inline = function(tex)
    return (tex:gsub("%^2", "²"))
  end
  local note = open_note({
    "First $qq^2$ and then $qq$ alone.",
    "",
    "Both $aa$ and $aa + bb$ and $bb$ here.",
    "",
    "A paragraph with $pp$ in it",
    "joined to $pp + rr$ on its next line.",
    "",
    "| A | B |",
    "|---|---|",
    "| $tt^2$ | $tt$ |",
  })
  vim.g.md_render_math = "text"
  preview.toggle()
  local view_bufnr = vim.api.nvim_get_current_buf()
  assert_eq(equation_at_text(view_bufnr, "qq²", 0), "qq^2", "x²:")
  assert_eq(equation_at_text(view_bufnr, "then qq", 5), "qq", "x after x²:")
  assert_eq(equation_at_text(view_bufnr, "Both aa", 5), "aa", "a:")
  assert_eq(equation_at_text(view_bufnr, "aa + bb", 0), "aa + bb", "a + b, on its a:")
  assert_eq(equation_at_text(view_bufnr, "aa + bb", 5), "aa + bb", "a + b, on its b:")
  assert_eq(equation_at_text(view_bufnr, "and bb here", 4), "bb", "b after a + b:")
  assert_eq(equation_at_text(view_bufnr, "with pp", 5), "pp", "p in a joined paragraph:")
  assert_eq(equation_at_text(view_bufnr, "pp + rr", 5), "pp + rr", "p + r on the joined line:")
  assert_eq(equation_at_text(view_bufnr, "and then", 0), nil, "prose:")
  -- A table cell: md-render's rows do not tell which equation is where.
  local table_cell
  for index, line in ipairs(vim.api.nvim_buf_get_lines(view_bufnr, 0, -1, false)) do
    local square = line:find("tt²", 1, true)
    if square then
      local alone = assert(line:find("tt", square + #"tt²", true), "the second cell")
      table_cell = math_adapter.equation_at(view_bufnr, index - 1, alone - 1)
    end
  end
  assert_eq(table_cell, "tt", "in a table:")
  vim.g.md_render_math = nil
  fake_text.inline = upstream_inline
  close_everything(note)
end)

test("pictures first for what any window on the view shows", function()
  forget_calls()
  local note, source_bufnr = open_note(numbered_items("vw", 200))
  preview.toggle()
  local view_bufnr = vim.api.nvim_get_current_buf()
  local session = preview._sessions[view_bufnr]
  vim.cmd("split")
  vim.api.nvim_win_set_cursor(0, { 160, 0 })
  vim.cmd("normal! zt")
  vim.cmd("wincmd p")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  forget_calls()
  rebuild_with(session, source_bufnr, numbered_items("vw2", 200))
  local first = {}
  for _, number in ipairs(numbers_of(fake_tex.requests[1])) do
    first[number] = true
  end
  assert_true(first[1], "the top window's lines are in the first request")
  assert_true(first[165], "and the lower window's")
  assert_true(not first[80], "but not those between: the second request has them")
  close_everything(note)
end)

test("a view that fails to rebuild: the others are rebuilt, one message", function()
  forget_calls()
  answer("inline", "fail_a", new_picture(2))
  answer("inline", "fail_b", new_picture(2))
  local other_note = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "Other $fail_b$ view." }, other_note)
  local note = open_note({ "Failing $fail_a$ view." })
  preview.toggle()
  local failing_session = preview._sessions[vim.api.nvim_get_current_buf()]
  vim.cmd("vsplit " .. vim.fn.fnameescape(other_note))
  preview.toggle()
  local other_view = vim.api.nvim_get_current_buf()
  failing_session.rebuild = function()
    error("broken view")
  end
  local notify, messages = vim.notify, {}
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  local builds = builds_of_view(other_view)
  vim.cmd("hi Special guifg=#ff8800")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  settle(50)
  vim.cmd("hi Special guifg=#3366cc")
  vim.notify = notify
  failing_session.rebuild = nil
  assert_eq(builds_of_view(other_view) - builds, 1, "the other view rebuilt:")
  assert_eq(#messages, 1, "one message:")
  assert_true(messages[1]:find("broken view", 1, true) ~= nil, "naming the failure")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  settle(50)
  close_everything(note)
  vim.fn.delete(other_note)
end)

test(":MdRenderMath errors after the source changed under a hidden view: today's lines", function()
  forget_calls()
  answer("inline", "stale_bad", false)
  local note, source_bufnr = open_note({ "Bad $stale_bad$ here." })
  preview.toggle()
  preview.toggle()
  assert_eq(vim.api.nvim_get_current_buf(), source_bufnr, "back in the source")
  vim.api.nvim_buf_set_lines(source_bufnr, 0, 0, false, { "New first line.", "" })
  local items = listed_errors()
  assert_eq(#items, 1, "one error:")
  assert_eq(items[1].lnum, 3, "on the line it is on now:")
  close_everything(note)
end)

_H.finish()
