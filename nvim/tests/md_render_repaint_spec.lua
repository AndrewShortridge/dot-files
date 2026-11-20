-- Spec for andrew.utils.md_render_repaint, run against the real md-render.nvim:
-- a live preview keeps its scaled headings and images on screen while the
-- source is edited.
--
-- WHAT THIS IS GUARDING
--
-- md-render draws headings and images straight to the terminal and has to
-- take them off and put them back around Neovim's own drawing. It did both
-- far more often, and for far longer, than anything needed -- which showed as
-- flicker in the preview on every edit. Each case below was measured in the
-- bytes sent to the terminal before it was a test:
--
-- 1. Every redraw took the headings off the screen until they were written
--    back, a turn of the event loop later at best. Now the two reach the
--    terminal as one frame (synchronized output held open across them).
-- 2. After a redraw the headings stayed off the screen when the set of them
--    on screen had changed (a completion menu over one), until a repaint
--    debounced by 90 ms or more.
-- 3. Any window opening or closing anywhere repainted the whole screen.
-- 4. A rebuild that moved no heading repainted the whole screen.
-- 5. A rebuild that moved no image placed every image again.
--
-- And the things the fix must not take away:
--
-- 6. Headings that DID move on screen still get their full repaint. That is
--    what clears what the old position left behind.
-- 7. So does a rebuild that moved a heading, or changed one where it stands.
-- 8. A rebuild that DID move an image still places it again.
-- 9. 'termsync' is the user's again once no heading is on screen. It is off
--    while frames are held, because Neovim's own synchronized output would
--    end the hold.
--
-- The adapter reads md-render's internals (the heading state and its `drawn`,
-- `last_layout` and `augroup` fields), so an md-render update is the likeliest
-- thing to turn this red.
--
-- There is no terminal in a `-l` run, so `nvim_ui_send` is replaced by a
-- recorder and md-render is told the terminal can do both protocols.
--
-- Run with: nvim --headless -u NONE -l tests/md_render_repaint_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/md-render.nvim")
vim.cmd("filetype on")

-- Everything md-render sends to the terminal goes through this one function.
local sent_to_terminal = {} ---@type string[]
-- Stubbed on purpose: a recorder in place of vim.api.nvim_ui_send(content: string); never restored.
---@param data string
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim_ui_send = function(data)
  sent_to_terminal[#sent_to_terminal + 1] = data
end

--- md-render erases a heading by moving to it and erasing its cells.
local HEADING_ERASE_PATTERN = "\27%[%d+;%d+H\27%[%d+X"
local SCALED_RUN = "\27]66;"
local IMAGE_PLACEMENT = "\27_Ga=p"
local SYNCHRONIZED_OUTPUT_BEGIN = "\27[?2026h"
local SYNCHRONIZED_OUTPUT_END = "\27[?2026l"

---@return string
local function sent()
  return table.concat(sent_to_terminal)
end

---@param escape_sequence string
---@return integer
local function count_sent(escape_sequence)
  local _, count = sent():gsub(vim.pesc(escape_sequence), "")
  return count
end

--- md-render keeps count of the full repaints (`:mode`) it runs.
---@return integer
local function full_repaints_run()
  return require("md-render.text_size")._stats.invalidations
end

local full_repaints_run_before = 0

local function forget_what_was_sent()
  sent_to_terminal = {}
  full_repaints_run_before = full_repaints_run()
end

--- Full repaints since `forget_what_was_sent`.
---@return integer
local function count_full_repaints()
  return full_repaints_run() - full_repaints_run_before
end

--- Whether a heading was written at its scaled size. The two headings of a
--- note here start with different letters; a scaled heading can go out in
--- several runs, and the first one starts with the first letter.
---@param first_letter string
---@return boolean
local function is_heading_written(first_letter)
  return sent():find("\27%]66;[^;]*;" .. first_letter) ~= nil
end

-- The terminal can show images...
require("md-render.image")._set_kitty_supported(true)
-- ...and scale text. That module has no such switch: it probes the terminal
-- and caches the answer, which with no UI attached is "no".
local text_size = require("md-render.text_size")
for upvalue_index = 1, math.huge do
  local upvalue_name = debug.getupvalue(text_size.supports, upvalue_index)
  if upvalue_name == nil then
    error("md-render.text_size.supports no longer caches its answer in `_supported`")
  end
  if upvalue_name == "_supported" then
    debug.setupvalue(text_size.supports, upvalue_index, true)
    break
  end
end

require("andrew.utils.md_render_repaint").setup()

---@module "md-render.preview"
local preview = require("md-render").preview

local scratch_dir = vim.fn.tempname()
vim.fn.mkdir(scratch_dir, "p")

---@param name string
---@param lines string[]
---@return string path
local function scratch_file(name, lines)
  local path = scratch_dir .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

-- A 1x1 PNG.
local png_file = assert(io.open(scratch_dir .. "/still.png", "wb"))
png_file:write(
  vim.base64.decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  )
)
png_file:close()

--- Let timers and scheduled callbacks run until `condition` holds.
---@param condition fun(): boolean
---@param timeout_ms? integer
---@return boolean
local function settle(condition, timeout_ms)
  return vim.wait(timeout_ms or 3000, condition, 5)
end

--- Let them run when the point is what has or has not happened by then.
---@param milliseconds integer
local function let_run(milliseconds)
  vim.wait(milliseconds, function()
    return false
  end, 5)
end

--- Longer than every debounce md-render has between a rebuild and its last
--- write: 90 to 180 ms for the headings, 50 ms for the images.
local PAST_EVERY_DEBOUNCE_MS = 500

---@class RepaintSpecView
---@field source_bufnr integer
---@field view_bufnr integer
---@field window integer

--- Show a note as its rendered view, in place of the source.
---@param path string
---@return RepaintSpecView
local function open_rendered(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local source_bufnr = vim.api.nvim_get_current_buf()
  preview.toggle()
  assert(vim.b.md_render, "the window shows the rendered view")
  return {
    source_bufnr = source_bufnr,
    view_bufnr = vim.api.nvim_get_current_buf(),
    window = vim.api.nvim_get_current_win(),
  }
end

--- Change the source the way typing does, and wait until md-render has
--- rebuilt the view, Neovim has redrawn, and md-render has finished
--- everything it does after that.
---@param view RepaintSpecView
---@param edit fun(source_bufnr: integer)
local function edit_source_and_let_the_view_settle(view, edit)
  local view_tick = vim.api.nvim_buf_get_changedtick(view.view_bufnr)
  forget_what_was_sent()
  edit(view.source_bufnr)
  -- TextChanged comes from the main loop, which a `-l` run does not have.
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = view.source_bufnr })
  assert_true(
    settle(function()
      return vim.api.nvim_buf_get_changedtick(view.view_bufnr) ~= view_tick
    end),
    "the view was rebuilt:"
  )
  -- So does the redraw that follows a change to a buffer on screen.
  vim.cmd.redraw()
  let_run(PAST_EVERY_DEBOUNCE_MS)
end

-- -----------------------------------------------------------------------------
-- Headings
-- -----------------------------------------------------------------------------

local headings_view = open_rendered(scratch_file("headings.md", {
  "# Alpha",
  "",
  "Body text of the note.",
  "",
  "## Beta",
  "",
  "Closing text.",
}))

test("both headings of the view are written at their scaled size", function()
  assert_true(
    settle(function()
      return is_heading_written("A") and is_heading_written("B")
    end),
    "scaled runs for `Alpha` and `Beta` were sent:"
  )
  let_run(PAST_EVERY_DEBOUNCE_MS)
end)

test("a redraw reaches the terminal as one frame with its headings", function()
  assert_eq(vim.o.termsync, false, "'termsync' while headings are on screen:")

  forget_what_was_sent()
  vim.cmd.redraw()
  assert_true(
    settle(function()
      return sent():find(SYNCHRONIZED_OUTPUT_END, 1, true) ~= nil
    end, 200),
    "the frame was let go:"
  )

  local frame = sent()
  local hold_begins = frame:find(SYNCHRONIZED_OUTPUT_BEGIN, 1, true)
  local headings_erased = frame:find(HEADING_ERASE_PATTERN)
  local headings_written = frame:find(SCALED_RUN, 1, true)
  local hold_ends = frame:find(SYNCHRONIZED_OUTPUT_END, 1, true)
  assert_true(hold_begins ~= nil, "the frame was held:")
  assert_true(headings_erased ~= nil, "the redraw took the headings off the screen:")
  assert_true(headings_written ~= nil, "the headings were written back:")
  assert_true(
    hold_begins < headings_erased
      and headings_erased < headings_written
      and headings_written < hold_ends,
    "in the order hold, erase, write back, let go:"
  )
end)

test("headings a redraw erased come back at once when one of them is now covered", function()
  -- A float, somewhere it covers nothing. md-render repaints for a new window.
  local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor",
    row = 20,
    col = 60,
    width = 6,
    height = 1,
  })
  let_run(PAST_EVERY_DEBOUNCE_MS)

  -- Moved over `Beta`, which no event tells md-render about: this is the
  -- completion menu following the cursor.
  local beta_line ---@type integer?
  for line_number, text in
    ipairs(vim.api.nvim_buf_get_lines(headings_view.view_bufnr, 0, -1, false))
  do
    if text:find("Beta", 1, true) then
      beta_line = line_number
    end
  end
  -- headings.md has a `## Beta` line, so the loop found it; a nil here would
  -- crash the arithmetic below anyway.
  ---@cast beta_line -nil
  local beta_text_column = vim.api
    .nvim_buf_get_lines(headings_view.view_bufnr, beta_line - 1, beta_line, false)[1]
    :find("Beta", 1, true)
  -- The line was picked above for containing "Beta".
  ---@cast beta_text_column -nil
  local beta_position = vim.fn.screenpos(headings_view.window, beta_line, beta_text_column)
  vim.api.nvim_win_set_config(float, {
    relative = "editor",
    row = beta_position.row - 1,
    col = beta_position.col - 1,
  })

  forget_what_was_sent()
  vim.cmd.redraw()
  local is_erased_by_redraw = sent():find(HEADING_ERASE_PATTERN) ~= nil
  -- md-render alone waits for a repaint it debounces by 90 ms at the least.
  local is_alpha_back = settle(function()
    return is_heading_written("A")
  end, 50)
  local is_beta_back = is_heading_written("B")

  -- Before any assertion, so that a failure here leaves no float behind.
  vim.api.nvim_win_close(float, true)
  let_run(PAST_EVERY_DEBOUNCE_MS)

  assert_true(is_erased_by_redraw, "the redraw took the headings off the screen:")
  assert_true(is_alpha_back, "`Alpha`, which nothing covers, is back within 50 ms:")
  assert_eq(is_beta_back, false, "`Beta`, under the float, written at scaled size:")
end)

test("a window opening and closing elsewhere does not repaint the whole screen", function()
  forget_what_was_sent()
  local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor",
    row = 20,
    col = 60,
    width = 6,
    height = 1,
  })
  let_run(PAST_EVERY_DEBOUNCE_MS)
  vim.api.nvim_win_close(float, true)
  let_run(PAST_EVERY_DEBOUNCE_MS)
  assert_eq(count_full_repaints(), 0, "full repaints for a float that touched no heading:")
end)

test("headings that moved on screen still get a full repaint", function()
  ---@param scroll_key string
  local function scroll_the_view(scroll_key)
    vim.api.nvim_win_call(headings_view.window, function()
      vim.cmd.normal({ args = { scroll_key }, bang = true })
    end)
    -- WinScrolled comes from the main loop, which a `-l` run does not have.
    vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(headings_view.window) })
    let_run(PAST_EVERY_DEBOUNCE_MS)
  end

  forget_what_was_sent()
  scroll_the_view(vim.keycode("<C-e>"))
  local full_repaints_after_scroll = count_full_repaints()
  -- Back before the assertion, so that a failure leaves the view as it was.
  scroll_the_view(vim.keycode("<C-y>"))
  assert_true(full_repaints_after_scroll > 0, "a full repaint after the view scrolled by a line:")
end)

test("a rebuild that moved no heading does not repaint the whole screen", function()
  ---@param source_bufnr integer
  edit_source_and_let_the_view_settle(headings_view, function(source_bufnr)
    vim.api.nvim_buf_set_lines(source_bufnr, 2, 3, false, { "Body text of the note, edited." })
  end)
  assert_eq(count_full_repaints(), 0, "full repaints after an edit to body text:")
  assert_true(is_heading_written("A"), "the headings were written again all the same:")
end)

test("a rebuild that moved a heading still repaints the whole screen", function()
  ---@param source_bufnr integer
  edit_source_and_let_the_view_settle(headings_view, function(source_bufnr)
    -- Above `## Beta`, which moves down by two lines.
    vim.api.nvim_buf_set_lines(source_bufnr, 3, 3, false, { "", "A paragraph more." })
  end)
  assert_true(count_full_repaints() > 0, "a full repaint after `Beta` moved:")
end)

test("a rebuild that changed a heading where it stands still repaints the whole screen", function()
  ---@param source_bufnr integer
  edit_source_and_let_the_view_settle(headings_view, function(source_bufnr)
    vim.api.nvim_buf_set_lines(source_bufnr, 0, 1, false, { "# Alphabet" })
  end)
  assert_true(count_full_repaints() > 0, "a full repaint after `Alpha` became `Alphabet`:")
end)

-- -----------------------------------------------------------------------------
-- Images
-- -----------------------------------------------------------------------------

-- Back to the source, then on to a note with a picture in it.
preview.toggle()

test("'termsync' is the user's again once no heading is on screen", function()
  assert_eq(vim.b.md_render, nil, "the window shows the source:")
  assert_eq(vim.o.termsync, true, "'termsync' with no rendered view open:")
end)

-- A note whose two headings are never on screen together.
local far_apart_lines = { "# Delta", "" }
for line_number = 1, 3 * vim.o.lines do
  -- A paragraph each: adjacent lines would be joined into one.
  vim.list_extend(far_apart_lines, { ("Body line %d."):format(line_number), "" })
end
vim.list_extend(far_apart_lines, { "## Epsilon", "", "Closing text." })
local far_apart_view = open_rendered(scratch_file("far_apart.md", far_apart_lines))

test("a jump that takes every heading off the screen still gets a full repaint", function()
  assert_true(
    settle(function()
      return is_heading_written("D")
    end),
    "`Delta` was written at its scaled size:"
  )
  let_run(PAST_EVERY_DEBOUNCE_MS)

  forget_what_was_sent()
  vim.api.nvim_win_call(far_apart_view.window, function()
    vim.cmd.normal({ args = { "G" }, bang = true })
  end)
  -- WinScrolled comes from the main loop, which a `-l` run does not have.
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(far_apart_view.window) })
  vim.cmd.redraw()
  let_run(PAST_EVERY_DEBOUNCE_MS)

  -- No heading moved: one went and another came. The cells `Delta` was
  -- erased from are cleared by nothing but a full repaint.
  assert_true(is_heading_written("E"), "`Epsilon` is on screen now:")
  assert_eq(is_heading_written("D"), false, "`Delta` written after the jump:")
  assert_true(count_full_repaints() > 0, "a full repaint after the jump:")
end)

preview.toggle()

local image_view = open_rendered(scratch_file("image.md", {
  "# Gamma",
  "",
  "Text above the picture.",
  "",
  "![still](still.png)",
  "",
  "Text below the picture.",
}))

test("the picture of the view is placed", function()
  assert_true(
    settle(function()
      return count_sent(IMAGE_PLACEMENT) > 0
    end),
    "an image placement was sent:"
  )
  let_run(PAST_EVERY_DEBOUNCE_MS)
end)

test("a rebuild that moved no image does not place it again", function()
  ---@param source_bufnr integer
  edit_source_and_let_the_view_settle(image_view, function(source_bufnr)
    vim.api.nvim_buf_set_lines(source_bufnr, 6, 7, false, { "Text below the picture, edited." })
  end)
  assert_eq(count_sent(IMAGE_PLACEMENT), 0, "image placements after an edit to body text:")
end)

test("a rebuild that moved an image places it again", function()
  ---@param source_bufnr integer
  edit_source_and_let_the_view_settle(image_view, function(source_bufnr)
    -- Above the picture, which moves down by two lines.
    vim.api.nvim_buf_set_lines(source_bufnr, 3, 3, false, { "", "A paragraph more." })
  end)
  assert_true(count_sent(IMAGE_PLACEMENT) > 0, "an image placement after the picture moved:")
end)

vim.fn.delete(scratch_dir, "rf")
_H.finish()
