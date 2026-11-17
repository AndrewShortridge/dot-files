-- Spec for the markdown renderer switch (andrew.utils.markdown_renderer) and
-- the md-render auto-mode adapter (andrew.plugins.md-render), run against the
-- real render-markdown.nvim and md-render.nvim.
--
-- WHAT THIS IS GUARDING
--
-- The switch itself is a table lookup. What can break is where the two plugins
-- meet, and each case below was a bug seen in a terminal before it was a test:
--
-- 1. render-markdown's decorations outliving the switch. It removes them in a
--    scheduled callback that gives up unless the buffer is still on screen, and
--    md-render takes the buffer off screen. The source then stays decorated
--    every time md-render swaps it back in for Insert mode.
-- 2. A second file opened from a rendered view never being rendered: md-render
--    resolves "the current buffer" through window state left by the first one.
-- 3. The same stale state leaving the next file -- any filetype -- without
--    'number' and the other options md-render turns off in a rendered view.
-- 4. A buffer already in auto mode arriving as plain source when shown again.
-- 5. The fix for 4 undoing md-render's own swap back to the source, which is
--    how `i` on a rendered view gets you into Insert mode.
-- 6. The rendered view sitting against the window's left edge. It is centred
--    with a gutter, which md-render empties every time its buffer is entered
--    and which has to follow the window's width.
-- 7. A window split off a rendered view having no state to release, so a file
--    opened in it kept the rendered view's options.
-- 8. The cursor arriving in the first column after a swap, in either
--    direction. Where it goes is tests/md_render_cursor_spec.lua; here it is
--    that the position is applied after md-render has placed the cursor itself.
--
-- md-render's auto mode is experimental upstream and the adapter reads an
-- undocumented window variable, so an md-render update is the likeliest thing
-- to turn this red.
--
-- Run with: nvim --headless -u NONE -l tests/markdown_renderer_switch_spec.lua

local _H =
  dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

-- What ftplugin/markdown.lua leaves behind in the real config. render-markdown
-- reads it when it loads, as the 'conceallevel' to use while NOT rendering.
vim.o.conceallevel = 2

-- `-u NONE` loads no plugins: put the two renderers on the runtimepath and run
-- render-markdown's plugin file, which is what attaches it to markdown buffers.
for _, plugin_name in ipairs({ "render-markdown.nvim", "md-render.nvim" }) do
  vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/" .. plugin_name)
end
vim.cmd("runtime! plugin/render-markdown.lua")
vim.cmd("filetype on")

-- Start on render-markdown, the way init.lua would choose it: the cases below
-- are about switching between the two, whichever DEFAULT_BACKEND names.
vim.g.markdown_renderer = "render-markdown"
local markdown_renderer = require("andrew.utils.markdown_renderer")
markdown_renderer.setup()
local md_render_spec = require("andrew.plugins.md-render")
md_render_spec.init()

local render_markdown = require("render-markdown")

local scratch_dir = vim.fn.tempname()
vim.fn.mkdir(scratch_dir, "p")

local function scratch_file(name, lines)
  local path = scratch_dir .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

local first_note =
  scratch_file("first.md", { "# First", "", "- [ ] a task", "", "> [!NOTE] Title", "> Body." })
local second_note = scratch_file("second.md", { "# Second", "", "- item" })
local lua_file = scratch_file("code.lua", { "return 1" })

--- Let scheduled callbacks run until `condition` holds.
local function settle(condition)
  return vim.wait(2000, condition, 10)
end

--- Let scheduled callbacks run when the point is that nothing should change.
local function settle_briefly()
  vim.wait(200, function()
    return false
  end, 10)
end

local function is_rendered_view(bufnr)
  return vim.b[bufnr].md_render == true
end

local function current_name()
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
end

local function render_markdown_extmark_count(bufnr)
  local namespace =
    assert(vim.api.nvim_get_namespaces()["render-markdown.nvim"], "render-markdown's namespace")
  return #vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
end

-- A `-l` run has an 80-column screen that setting 'columns' does not resize,
-- and md-render's default width is those same 80 columns. Render 40, so there
-- is a margin to measure: 20 either side.
vim.g.md_render_max_width = 40
vim.cmd.edit(vim.fn.fnameescape(first_note))
local first_bufnr = vim.api.nvim_get_current_buf()
vim.wo.number = true

--- Columns of gutter left of the text in the current window, as drawn.
local function gutter_width()
  vim.cmd.redraw()
  return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
end

local function settles_on_gutter_width(expected_width)
  return settle(function()
    return gutter_width() == expected_width
  end)
end

test("a buffer on render-markdown is decorated by it, with md-render not loaded", function()
  assert_true(
    settle(function()
      return vim.b[first_bufnr].markdown_renderer == "render-markdown"
        and render_markdown_extmark_count(first_bufnr) > 0
    end),
    "render-markdown decorated the buffer:"
  )
  assert_true(render_markdown.get(first_bufnr), "render-markdown is on in the buffer:")
  assert_eq(package.loaded["md-render"], nil, "md-render stays unloaded until it is chosen:")
end)

test("switching to md-render shows its view and clears render-markdown from the source", function()
  markdown_renderer.use("md-render")
  assert_true(
    settle(function()
      return is_rendered_view(vim.api.nvim_get_current_buf())
    end),
    "the window shows md-render's rendered view:"
  )
  assert_eq(current_name(), "first.md [render]", "it is the view of the file that was open:")
  assert_eq(render_markdown.get(first_bufnr), false, "render-markdown is off in the source:")
  assert_eq(
    render_markdown_extmark_count(first_bufnr),
    0,
    "decorations render-markdown left on the source:"
  )
end)

test("md-render swapping the source back in is left alone", function()
  -- What `i` on the rendered view does before it starts Insert mode.
  require("md-render").preview.toggle()
  assert_eq(vim.api.nvim_get_current_buf(), first_bufnr, "md-render put the source in the window:")
  settle_briefly()
  assert_eq(vim.api.nvim_get_current_buf(), first_bufnr, "and it is still there a moment later:")
  require("md-render").preview.toggle()
  assert_true(is_rendered_view(vim.api.nvim_get_current_buf()), "back on the rendered view:")
end)

test("the cursor is carried across a swap, both ways", function()
  local view_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for view_line, text in ipairs(view_lines) do
    local task_column = text:find("task", 1, true)
    if task_column then
      vim.api.nvim_win_set_cursor(0, { view_line, task_column - 1 })
    end
  end
  -- What `i` on the rendered view does before it starts Insert mode.
  require("md-render").preview.toggle()
  assert_true(
    settle(function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      return cursor[1] == 3 and cursor[2] == #"- [ ] a "
    end),
    "into the source, cursor on `task` in `- [ ] a task`, line 3:"
  )

  -- What leaving Insert mode does, 50 ms later.
  vim.api.nvim_win_set_cursor(0, { 6, #"> " })
  require("md-render").preview.toggle()
  assert_true(
    settle(function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      return is_rendered_view(vim.api.nvim_get_current_buf())
        and vim.api.nvim_get_current_line():sub(cursor[2] + 1, cursor[2] + #"Body.") == "Body."
    end),
    "into the view, cursor on `Body.` from source line 6:"
  )
end)

test("the rendered view is centred, and stays centred", function()
  assert_true(settles_on_gutter_width(20), "40 columns rendered in an 80-column window, margin:")

  -- md-render empties the gutter each time its buffer is entered.
  vim.cmd.new()
  vim.cmd.close()
  assert_true(is_rendered_view(vim.api.nvim_get_current_buf()), "back in the window with the view:")
  assert_true(settles_on_gutter_width(20), "margin after leaving the view and coming back:")

  -- A split of the view: no BufEnter (same buffer), so this is the WinNew path.
  -- Following a later resize is WinResized, which a `-l` run never fires (it
  -- comes from the main loop); that one was checked in a terminal.
  vim.cmd.vsplit()
  vim.cmd("vertical resize 60")
  assert_true(settles_on_gutter_width(10), "margin in a split of the view, 60 columns wide:")
  vim.cmd.close()
end)

test("a markdown file opened from a rendered view is rendered too", function()
  vim.cmd.edit(vim.fn.fnameescape(second_note))
  assert_true(
    settle(function()
      return is_rendered_view(vim.api.nvim_get_current_buf())
    end),
    "the second file is rendered:"
  )
  assert_eq(
    current_name(),
    "second.md [render]",
    "and it is the second file's view, not the first's:"
  )
end)

test("a file opened from a rendered view gets the window's own options back", function()
  assert_eq(vim.wo.number, false, "precondition, md-render turns 'number' off in a rendered view:")
  vim.cmd.edit(vim.fn.fnameescape(lua_file))
  assert_eq(vim.wo.number, true, "'number' in the file opened next:")
  assert_eq(gutter_width(), vim.wo.numberwidth, "its gutter is the number column, not the margin:")
end)

test("a buffer already on md-render is rendered again when it is shown again", function()
  vim.cmd.buffer(first_bufnr)
  assert_true(
    settle(function()
      return is_rendered_view(vim.api.nvim_get_current_buf())
    end),
    "revisiting the first file shows its rendered view:"
  )
  assert_eq(current_name(), "first.md [render]", "it is the first file's view:")
end)

test("a file opened in a window split off a rendered view gets the options back too", function()
  vim.cmd.vsplit()
  vim.cmd.edit(vim.fn.fnameescape(lua_file))
  assert_eq(vim.wo.number, true, "'number' in the file opened in the split:")
  vim.cmd.close()
  assert_true(is_rendered_view(vim.api.nvim_get_current_buf()), "the rendered view is still there:")
end)

test("switching back puts the source in the window, decorated by render-markdown", function()
  markdown_renderer.use("render-markdown")
  assert_eq(vim.api.nvim_get_current_buf(), first_bufnr, "the window shows the source again:")
  assert_eq(vim.b[first_bufnr].md_render_auto, nil, "md-render's auto mode is off in it:")
  assert_true(
    settle(function()
      return render_markdown.get(first_bufnr) and render_markdown_extmark_count(first_bufnr) > 0
    end),
    "render-markdown decorates it again:"
  )
  settle_briefly()
  assert_eq(
    vim.api.nvim_get_current_buf(),
    first_bufnr,
    "and md-render does not take the window back:"
  )
end)

-- What lazy.nvim does when md-render loads: its plugin file, then the spec's
-- `config`. Down here because `config` loads the plugin, and the first test is
-- that nothing has.
vim.cmd("runtime plugin/md-render.lua")
md_render_spec.config()

test(":MdRender split is side by side unless the command says otherwise", function()
  local source_window = vim.api.nvim_get_current_win()
  local function close_split()
    vim.api.nvim_set_current_win(source_window)
    vim.cmd.only()
  end

  vim.cmd("MdRender split")
  assert_eq(#vim.api.nvim_tabpage_list_wins(0), 2, "windows after `:MdRender split`:")
  assert_eq(vim.fn.winlayout()[1], "row", "layout of source and view:")
  close_split()

  vim.cmd("horizontal MdRender split")
  assert_eq(vim.fn.winlayout()[1], "col", "layout after `:horizontal MdRender split`:")
  close_split()
end)

test("a split has the source on the left and the view on the right, from either", function()
  local function column_of(window)
    return vim.fn.win_screenpos(window)[2]
  end
  ---@return integer source_window, integer view_window
  local function split_windows()
    local source_window, view_window
    for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if is_rendered_view(vim.api.nvim_win_get_buf(window)) then
        view_window = window
      else
        source_window = window
      end
    end
    return source_window, view_window
  end

  -- From the source, with the option that would put the new window (the view)
  -- on the left.
  vim.o.splitright = false
  vim.cmd("MdRender split")
  local source_window, view_window = split_windows()
  assert_true(
    column_of(source_window) < column_of(view_window),
    "opened from the source, the source is left of the view:"
  )
  -- render-markdown comes off the source a tick later, and only while the
  -- source is still on screen: let it, before closing the source's window.
  settle(function()
    return render_markdown_extmark_count(first_bufnr) == 0
  end)
  vim.api.nvim_set_current_win(view_window)
  vim.cmd.only()

  -- From the view, with the option that would put the new window (the source)
  -- on the right.
  vim.o.splitright = true
  vim.cmd("MdRender split")
  source_window, view_window = split_windows()
  assert_true(
    column_of(source_window) < column_of(view_window),
    "opened from the view, the source is left of the view:"
  )

  -- Back to one window showing the source, as the tests around this one expect.
  vim.api.nvim_set_current_win(view_window)
  vim.cmd.only()
  vim.cmd("MdRender toggle")
  assert_eq(vim.api.nvim_get_current_buf(), first_bufnr, "the window shows the source again:")
end)

test("the source beside a split view is as written, and as before once the view is gone", function()
  local source_window = vim.api.nvim_get_current_win()
  vim.cmd("MdRender split")
  assert_true(
    settle(function()
      return not render_markdown.get(first_bufnr)
        and render_markdown_extmark_count(first_bufnr) == 0
        and vim.wo[source_window].conceallevel == 0
    end),
    "render-markdown off and nothing concealed in the source while the split is open:"
  )

  vim.api.nvim_set_current_win(source_window)
  vim.cmd.only()
  assert_true(
    settle(function()
      return render_markdown.get(first_bufnr)
        and render_markdown_extmark_count(first_bufnr) > 0
        and vim.wo[source_window].conceallevel == 3
    end),
    "render-markdown decorates the source again after the split is closed:"
  )
end)

vim.fn.delete(scratch_dir, "rf")
_H.finish()
