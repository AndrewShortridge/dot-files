-- Spec for andrew.utils.md_render_headings, run against the real
-- md-render.nvim: a heading that md-render draws larger has no level icon.
--
-- WHAT THIS IS GUARDING
--
-- md-render has no option for the icon, so it is taken off the line
-- `markdown.render` returns. That line comes with byte ranges into it, and the
-- function returns more than the line. The ways this goes wrong:
--
-- 1. The icon is still there, or the heading text lost its first characters.
-- 2. The ranges were not moved with the text: bold, inline code and link
--    colours land a few characters to the right of the words they belong to,
--    and a link is clickable beside its text.
-- 3. The icon is gone where nothing replaces it. In a terminal that cannot
--    scale text the icon is the only thing that tells `#` from `###`.
-- 4. The wrapper drops return values. The later ones carry a callout's type
--    and fold state, on lines that are not headings at all.
-- 5. In the rendered view itself the icon is back: it is drawn twice, by
--    Neovim in the buffer and by md-render straight to the terminal, next to
--    the scaled text.
--
-- There is no terminal in a `-l` run, so `nvim_ui_send` is replaced by a
-- recorder and md-render is told whether the terminal can scale text.
--
-- Run with: nvim --headless -u NONE -l tests/md_render_headings_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/md-render.nvim")
vim.cmd("filetype on")

-- Everything md-render sends to the terminal goes through this one function.
local sent_to_terminal = {} ---@type string[]
---@param content string
local function record_ui_send(content)
  sent_to_terminal[#sent_to_terminal + 1] = content
end
vim.api.nvim_ui_send = record_ui_send

local markdown = require("md-render.markdown")
local text_size = require("md-render.text_size")

--- md-render probes the terminal once and caches the answer, which with no UI
--- attached is "no". There is no switch for it.
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

-- md-render's own renderer, kept to compare against.
local upstream_render = markdown.render
require("andrew.utils.md_render_headings").setup()

set_terminal_can_scale_text(true)

test("a heading that is drawn larger is its text alone, at every level", function()
  for level = 1, 6 do
    local rendered_text = markdown.render(("#"):rep(level) .. " Title of the section")
    assert_eq(rendered_text, "Title of the section", ("level %d heading:"):format(level))
  end
end)

test("highlights and links of a heading still cover the words they belong to", function()
  local source_line = "## A **bold** word, `code` and a [link](https://example.com)"
  local upstream_text, upstream_highlights, upstream_links = upstream_render(source_line)
  local rendered_text, highlights, links = markdown.render(source_line)
  local icon_pattern = "^" .. vim.pesc(markdown.heading_icon_prefix(2))

  assert_eq(rendered_text, "A bold word, code and a link", "rendered heading:")
  -- The heading's own highlight, bold, and inline code at the least.
  assert_true(#highlights >= 3, "the line has inline highlights to check:")
  assert_eq(#highlights, #upstream_highlights, "number of highlights:")
  for index, highlight in ipairs(highlights) do
    local upstream_highlight = upstream_highlights[index]
    local expected_text = upstream_text
      :sub(upstream_highlight.col + 1, upstream_highlight.end_col)
      :gsub(icon_pattern, "")
    assert_eq(
      rendered_text:sub(highlight.col + 1, highlight.end_col),
      expected_text,
      ("text under highlight %d (%s):"):format(index, tostring(highlight.hl))
    )
  end

  assert_eq(#links, 1, "number of links:")
  assert_eq(#upstream_links, 1, "number of links upstream:")
  assert_eq(
    rendered_text:sub(links[1].col_start + 1, links[1].col_end),
    "link",
    "text under the link:"
  )
end)

test("lines that are not headings come back exactly as md-render made them", function()
  for _, source_line in ipairs({
    "Plain **bold** text with a [link](https://example.com).",
    "- [ ] a task",
    "> a quote",
    "> [!NOTE]- A folded callout",
  }) do
    local upstream_results = vim.F.pack_len(upstream_render(source_line))
    local results = vim.F.pack_len(markdown.render(source_line))
    assert_eq(
      results.n,
      upstream_results.n,
      ("number of return values for %q:"):format(source_line)
    )
    assert_true(
      vim.deep_equal(results, upstream_results),
      ("return values for %q are md-render's:"):format(source_line)
    )
  end
end)

test("where the terminal cannot scale text the icon stays", function()
  set_terminal_can_scale_text(false)
  local source_line = "### Title of the section"
  local rendered_text = markdown.render(source_line)
  assert_eq(rendered_text, (upstream_render(source_line)), "level 3 heading:")
  assert_true(
    vim.startswith(rendered_text, markdown.heading_icon_prefix(3)),
    "which starts with the level icon:"
  )
  set_terminal_can_scale_text(true)
end)

test("the rendered view shows the heading scaled and without its icon", function()
  local note = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "# Title of the note", "", "Some text.", "", "### A deeper section" }, note)
  vim.cmd.edit(vim.fn.fnameescape(note))
  require("md-render").preview.toggle()
  assert_true(vim.b.md_render, "the window shows the rendered view:")

  local view_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert_eq(vim.trim(view_lines[1]), "Title of the note", "first line of the view:")
  assert_true(
    vim.tbl_contains(vim.tbl_map(vim.trim, view_lines), "A deeper section"),
    "the level 3 heading is in the view as its text alone:"
  )

  local is_heading_scaled = vim.wait(3000, function()
    return table.concat(sent_to_terminal):find("\27]66;[^;]*;Title of the note") ~= nil
  end, 20)
  assert_true(is_heading_scaled, "the heading text was sent to the terminal as a scaled run:")

  local sent = table.concat(sent_to_terminal)
  for level = 1, 6 do
    assert_eq(
      sent:find(markdown.heading_icon(level), 1, true),
      nil,
      ("level %d icon in what was sent to the terminal:"):format(level)
    )
  end
  vim.fn.delete(note)
end)

_H.finish()
