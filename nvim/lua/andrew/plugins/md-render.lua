-- =============================================================================
-- Markdown Rendering, second backend (md-render.nvim)
-- =============================================================================
-- On trial beside render-markdown.nvim. Unlike it, md-render never decorates
-- the buffer being edited: it builds a separate read-only buffer and shows that
-- in a float, a tab, a split, or in place of the source in the same window.
--
-- Which of the two renders a markdown file is chosen in
-- utils/markdown_renderer.lua (`:MarkdownRenderer md-render`). md-render's own
-- commands do not depend on that choice:
--
--   :MdRender            floating preview of the current buffer (toggle)
--   :MdRender tab        the same in a tab
--   :MdRender split      rendered view beside the source as written (no
--                        render-markdown, no conceal), scroll-synced
--                        (`:horizontal MdRender split` stacks them)
--   :MdRender toggle     swap this window between source and rendered view
--   :MdRender demo       every notation it supports, in one window
--
-- Float and `tab` have to be run from the SOURCE ("current buffer is not a
-- Markdown file" otherwise). On the md-render backend Normal mode shows the
-- rendered view, so `:MdRender toggle` first.
--
-- Inline images, video and Mermaid / PlantUML diagrams need the Kitty graphics
-- protocol, and inside tmux that needs `set -g allow-passthrough all`.

-- -----------------------------------------------------------------------------
-- Adapter for auto mode (`:help :MdRender-auto`), which upstream marks
-- experimental. The functions below read `w:md_render_state`, md-render's own
-- record of the in-place view in a window; it is not a documented interface.
-- Seen with v3.11.2, pinned by tests/markdown_renderer_switch_spec.lua. Drop
-- any of them when upstream covers the case itself.
-- -----------------------------------------------------------------------------

---@param window integer 0 for the current one
---@return { mode: string, source_buf: integer, render_buf: integer, source_wo?: table<string, any> }?
local function render_state_of(window)
  local render_state = vim.w[window].md_render_state
  return type(render_state) == "table" and render_state or nil
end

--- md-render goes on believing a window shows the rendered view of a source
--- after the window has moved on to a different file (`:edit`, a picker, a
--- jump). Two things follow:
---
---   * `auto_on()` finds its buffer through that state, so it switches on the
---     OLD source again and the file now in the window is never rendered. This
---     is what `:MarkdownRenderer md-render` relies on for every file opened
---     from a rendered view.
---   * The window keeps the options of a rendered view ('number',
---     'relativenumber', 'list', 'signcolumn', 'foldcolumn' and 'statuscolumn'
---     all off) for whatever file comes next, markdown or not.
---
--- Hand the window back the way `:MdRender toggle` would have.
---@param bufnr integer the buffer just entered
local function release_window_from_stale_render_state(bufnr)
  local render_state = render_state_of(0)
  if not render_state or render_state.mode ~= "render" then
    return
  end
  if bufnr == render_state.render_buf or bufnr == render_state.source_buf then
    return
  end
  for option_name, option_value in pairs(render_state.source_wo or {}) do
    vim.api.nvim_set_option_value(option_name, option_value, { win = 0 })
  end
  vim.w.md_render_state = nil
end

--- A window split off a rendered view shows the same view with the same
--- options, but without md-render's record of it, so nothing above can hand it
--- back: a file opened in the new split keeps 'nonumber' and the rest. Give
--- the new window its parent's record. Runs on WinNew, when the new window is
--- current and still shows what its parent shows.
local function inherit_render_state_from_split_parent()
  if render_state_of(0) then
    return
  end
  local parent_window = vim.fn.win_getid(vim.fn.winnr("#"))
  local parent_state = parent_window ~= 0 and render_state_of(parent_window) or nil
  if
    parent_state
    and parent_state.mode == "render"
    and vim.api.nvim_get_current_buf() == parent_state.render_buf
  then
    vim.w.md_render_state = parent_state
  end
end

--- The rendered view of a source, if a window of this tab is showing it.
---@param source_bufnr integer
---@return integer? view_bufnr
local function rendered_view_on_screen(source_bufnr)
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local render_state = render_state_of(window)
    if
      render_state
      and render_state.mode == "render"
      and render_state.source_buf == source_bufnr
      and vim.api.nvim_win_get_buf(window) == render_state.render_buf
    then
      return render_state.render_buf
    end
  end
end

--- Auto mode renders a buffer when it is switched on, and after that only on
--- InsertLeave. A buffer that is already in auto mode and is shown again later
--- (`:buffer`, a picker, <C-o>, a second split) arrives as plain source and
--- stays that way until an Insert round trip. Render it on arrival as well.
---
--- Not when md-render put the source there itself (`i` on the rendered view,
--- `:MdRender toggle`), and not while the rendered view is already on screen
--- in this tab (`:MdRender split`). A source you toggled to by hand is
--- therefore rendered again once you leave it and come back.
---@param bufnr integer the buffer just entered
local function render_revisited_auto_buffer(bufnr)
  if not vim.b[bufnr].md_render_auto then
    return
  end
  -- Read NOW, not in the scheduled callback: while md-render is swapping the
  -- source in, its state still says "render". One tick later it says "source",
  -- which is also what a revisit looks like.
  local render_state = render_state_of(0)
  if render_state and render_state.mode == "render" and render_state.source_buf == bufnr then
    return
  end
  -- Scheduled: swapping the window's buffer inside the BufEnter for it.
  vim.schedule(function()
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_get_current_buf() == bufnr
      and vim.b[bufnr].md_render_auto
      and vim.api.nvim_win_get_config(0).relative == ""
      and not vim.api.nvim_get_mode().mode:find("^[iR]")
      and not rendered_view_on_screen(bufnr)
    then
      require("md-render").preview.toggle()
    end
  end)
end

-- -----------------------------------------------------------------------------
-- Centring. md-render renders at most `g:md_render_max_width` columns (80) and
-- starts at the window's left edge, so in a wide window a rendered view is a
-- column of text against the left with the rest empty.
--
-- The margin is a 'statuscolumn' of spaces, i.e. gutter rather than text. That
-- is the one way to move the view that md-render itself accounts for: it
-- measures the window without the gutter when it wraps text, places images
-- and scales headings. Padding the text instead leaves the frontmatter block
-- behind (it is built with a fixed indent), and virtual text is not counted
-- when images are placed.
-- -----------------------------------------------------------------------------

--- md-render's default for `g:md_render_max_width`.
local DEFAULT_RENDER_WIDTH = 80

--- The widest a gutter gets: Neovim stops growing 'statuscolumn' at the widths
--- of the fold (9), sign (18) and number (20) columns combined. A window wider
--- than the rendered width plus twice this is therefore left of centre.
local MAX_GUTTER_WIDTH = 47

---@param window_width integer
---@return integer
local function rendered_width_in(window_width)
  local max_render_width = vim.g.md_render_max_width
  if type(max_render_width) ~= "number" or max_render_width < 1 then
    max_render_width = DEFAULT_RENDER_WIDTH
  end
  return math.min(window_width, math.floor(max_render_width))
end

--- Centre the rendered view in a window, if that is what the window shows.
--- Floats are left alone: md-render sizes those to their content.
---@param window integer
local function centre_rendered_view(window)
  if
    not vim.api.nvim_win_is_valid(window) or vim.api.nvim_win_get_config(window).relative ~= ""
  then
    return
  end
  if not vim.b[vim.api.nvim_win_get_buf(window)].md_render then
    return
  end
  local window_width = vim.api.nvim_win_get_width(window)
  local margin_width = math.floor((window_width - rendered_width_in(window_width)) / 2)
  local gutter = string.rep(" ", math.min(margin_width, MAX_GUTTER_WIDTH))
  if vim.wo[window].statuscolumn ~= gutter then
    vim.wo[window][0].statuscolumn = gutter
  end
end

-- -----------------------------------------------------------------------------
-- Cursor. Every swap between the rendered view and the source -- `i` `a` and
-- the other Insert keys in auto mode, leaving Insert mode again,
-- `:MdRender toggle` -- leaves the cursor in the first column, and for a
-- paragraph wrapped over several rendered lines often a line off: md-render
-- maps lines by interpolating between blocks, and has no column mapping at
-- all. utils/md_render_cursor.lua finds the place by lining up the words of
-- both buffers.
-- -----------------------------------------------------------------------------

--- Lines of the buffer being left, either side of the cursor, that are lined
--- up with the other one. That one gets twice as many, because the two do not
--- advance at the same rate: a collapsed callout is one rendered line for many
--- source lines, a long source line is many rendered ones.
local CURSOR_CONTEXT_LINES = 40

---@param bufnr integer
---@param around_line integer
---@param context_lines integer
---@return MdRenderCursorStretch
local function lines_around(bufnr, around_line, context_lines)
  local first_line = math.max(1, around_line - context_lines)
  return {
    lines = vim.api.nvim_buf_get_lines(bufnr, first_line - 1, around_line + context_lines, false),
    first_line = first_line,
  }
end

--- Put the cursor where it was in the buffer md-render just swapped out of the
--- window. Runs one tick after that buffer was left, i.e. once md-render has
--- finished its swap and placed the cursor itself, and before the `i` it feeds
--- after a swap to the source: that is scheduled too, later than this.
---@param window integer
---@param origin_bufnr integer the buffer the window was showing
---@param origin_cursor [integer, integer] its cursor at that point, (1,0)-indexed
local function carry_cursor_across_swap(window, origin_bufnr, origin_cursor)
  if not vim.api.nvim_win_is_valid(window) or not vim.api.nvim_buf_is_valid(origin_bufnr) then
    return
  end
  -- Only md-render's own swap leaves this state behind: going from one of the
  -- two to another file, or to its counterpart by hand, has no estimate to
  -- line the words up at.
  local render_state = render_state_of(window)
  local target_bufnr = vim.api.nvim_win_get_buf(window)
  if not render_state then
    return
  end
  local is_swap_to_source = render_state.mode == "source"
    and render_state.render_buf == origin_bufnr
    and render_state.source_buf == target_bufnr
  local is_swap_to_view = render_state.mode == "render"
    and render_state.source_buf == origin_bufnr
    and render_state.render_buf == target_bufnr
  if not (is_swap_to_source or is_swap_to_view) then
    return
  end

  local origin = lines_around(origin_bufnr, origin_cursor[1], CURSOR_CONTEXT_LINES)
  -- md-render's own line is close enough to centre the search on.
  local estimated_line = vim.api.nvim_win_get_cursor(window)[1]
  local target = lines_around(target_bufnr, estimated_line, 2 * CURSOR_CONTEXT_LINES)

  local target_position =
    require("andrew.utils.md_render_cursor").counterpart_position(origin, origin_cursor, target)
  if target_position then
    vim.api.nvim_win_set_cursor(window, target_position)
  end
end

-- -----------------------------------------------------------------------------
-- `:MdRender split`, three changes to upstream's:
--
--   * It opens side by side. Upstream runs a plain `:split`, i.e. one above the
--     other, and has no option for it: the direction comes from the command
--     modifiers only (`:vert MdRender split`).
--   * The source is on the left and the view on the right, whichever of the
--     two the split was opened from. Upstream puts the NEW window where
--     'splitright' says, so from a rendered view the source landed on the
--     right.
--   * The source beside the view is the markdown as written: render-markdown
--     off, 'conceallevel' 0. Otherwise the split shows the same note rendered
--     twice (on the render-markdown backend) or with its markup hidden by
--     ftplugin/markdown.lua's conceallevel = 2 (on either), and the text being
--     edited nowhere.
-- -----------------------------------------------------------------------------

--- Set on a source while render-markdown is off it for the sake of a split.
local RESTORES_RENDER_MARKDOWN_VARIABLE = "md_render_raw_restores_render_markdown"
--- Set on a window whose 'conceallevel' was zeroed for a split: what it was.
local SAVED_CONCEALLEVEL_VARIABLE = "md_render_raw_conceallevel"

--- The markdown buffer a window is about: the one it shows, or the one whose
--- rendered view it shows.
---@param window integer
---@return integer source_bufnr
local function source_of(window)
  local bufnr = vim.api.nvim_win_get_buf(window)
  local render_state = render_state_of(window)
  if render_state and render_state.mode == "render" and render_state.render_buf == bufnr then
    return render_state.source_buf
  end
  return bufnr
end

---@param bufnr integer
---@param is_enabled boolean
local function set_render_markdown(bufnr, is_enabled)
  -- set_buf() takes no buffer: it acts on the current one.
  vim.api.nvim_buf_call(bufnr, function()
    require("render-markdown").set_buf(is_enabled)
  end)
end

---@param source_bufnr integer
---@return string
local function raw_source_augroup(source_bufnr)
  return "md-render-raw-source-" .. source_bufnr
end

--- Undo `show_source_raw_beside_its_view`, unless the view is still (or again)
--- in a window.
---@param source_bufnr integer
---@param view_bufnr integer
local function decorate_source_once_its_view_is_gone(source_bufnr, view_bufnr)
  if not vim.api.nvim_buf_is_valid(source_bufnr) then
    pcall(vim.api.nvim_del_augroup_by_name, raw_source_augroup(source_bufnr))
    return
  end
  if vim.api.nvim_buf_is_valid(view_bufnr) and #vim.fn.win_findbuf(view_bufnr) > 0 then
    return
  end
  -- In auto mode the view leaves its window for every Insert and comes back.
  -- The source stays as it is until auto mode ends (:MarkdownRenderer).
  if vim.b[source_bufnr].md_render_auto then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_name, raw_source_augroup(source_bufnr))

  for _, window in ipairs(vim.fn.win_findbuf(source_bufnr)) do
    local saved_conceallevel = vim.w[window][SAVED_CONCEALLEVEL_VARIABLE]
    if saved_conceallevel then
      vim.w[window][SAVED_CONCEALLEVEL_VARIABLE] = nil
      vim.wo[window][0].conceallevel = saved_conceallevel
    end
  end
  if vim.b[source_bufnr][RESTORES_RENDER_MARKDOWN_VARIABLE] then
    vim.b[source_bufnr][RESTORES_RENDER_MARKDOWN_VARIABLE] = nil
    if require("andrew.utils.markdown_renderer").selected() == "render-markdown" then
      set_render_markdown(source_bufnr, true)
    end
  end
end

--- Show a source as written for as long as its rendered view is in a window,
--- and as it was before once the view has left the last one (the split was
--- closed, or toggled to the source).
---@param source_bufnr integer
local function show_source_raw_beside_its_view(source_bufnr)
  local view_bufnr = rendered_view_on_screen(source_bufnr)
  -- No view: md-render refused the split (not a markdown buffer).
  if not view_bufnr then
    return
  end

  if require("render-markdown").get(source_bufnr) then
    vim.b[source_bufnr][RESTORES_RENDER_MARKDOWN_VARIABLE] = true
    set_render_markdown(source_bufnr, false)
  end
  -- Scheduled: render-markdown comes off in a scheduled callback of its own,
  -- which ends by writing the 'conceallevel' it uses when not rendering to
  -- every window of the buffer. This runs after that, so it reads the value to
  -- go back to and is not overwritten.
  vim.schedule(function()
    for _, window in ipairs(vim.fn.win_findbuf(source_bufnr)) do
      local conceallevel = vim.wo[window].conceallevel
      if conceallevel ~= 0 then
        vim.w[window][SAVED_CONCEALLEVEL_VARIABLE] = conceallevel
        vim.wo[window][0].conceallevel = 0
      end
    end
  end)

  -- BufWinLeave does not fire while another window still shows the view.
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = vim.api.nvim_create_augroup(raw_source_augroup(source_bufnr), { clear = true }),
    buffer = view_bufnr,
    callback = function()
      -- Scheduled: the window is still being closed or swapped.
      vim.schedule(function()
        decorate_source_once_its_view_is_gone(source_bufnr, view_bufnr)
      end)
    end,
  })
end

--- A window that `split` opened on the SOURCE from a rendered view carries that
--- view's state (inherit_render_state_from_split_parent, on the `:split`
--- inside it). That is what keeps auto mode from turning the source beside the
--- view into a second view on every InsertLeave, but upstream's `auto_off`
--- reads it as "this window shows the view" and toggles: the source window
--- turned into a view with the source's buffer forced back into it.
local function release_source_window_from_render_state()
  local render_state = render_state_of(0)
  if
    render_state
    and render_state.mode == "render"
    and vim.api.nvim_get_current_buf() == render_state.source_buf
  then
    vim.w.md_render_state = nil
  end
end

--- Wrap two of md-render's functions. Covers the commands, the `<Plug>`
--- mappings and direct Lua calls alike, since all of them look the function up
--- in `preview` when they run.
local function adapt_preview()
  local preview = require("md-render").preview
  local upstream_split = preview.split
  local upstream_auto_off = preview.auto_off

  ---@param opts? { mods?: vim.api.keyset.cmd_mods, max_width?: integer }
  preview.split = function(opts)
    opts = opts or {}
    local window = vim.api.nvim_get_current_win()
    local source_bufnr = source_of(window)
    -- From a rendered view the new window is the one that shows the source.
    local is_new_window_the_source = source_bufnr ~= vim.api.nvim_win_get_buf(window)

    -- Vertical unless the caller placed it: `:horizontal MdRender split` is the
    -- stacked one, `:tab MdRender split` a tab.
    local mods = vim.deepcopy(opts.mods or {})
    local is_in_new_tab = mods.tab ~= nil and mods.tab >= 0
    if not (mods.vertical or mods.horizontal or is_in_new_tab) then
      mods.vertical = true
    end
    -- Source first (left, or on top when stacked), view second, unless the
    -- caller chose a side (`:topleft`, `:botright`, ...). Said outright rather
    -- than left to 'splitright' / 'splitbelow'.
    if not is_in_new_tab and (mods.split == nil or mods.split == "") then
      mods.split = is_new_window_the_source and "aboveleft" or "belowright"
    end

    upstream_split(vim.tbl_extend("force", opts, { mods = mods }))
    show_source_raw_beside_its_view(source_bufnr)
  end

  preview.auto_off = function()
    release_source_window_from_render_state()
    return upstream_auto_off()
  end
end

return {
  "delphinus/md-render.nvim",
  version = "*",
  -- `MdRenderMath` is ours (utils/md_render_math.lua makes it in `setup`):
  -- named here so that `:MdRenderMath status` works before the first :MdRender.
  cmd = { "MdRender", "MdRenderHeadingColors", "MdRenderMath" },
  dependencies = { "nvim-tree/nvim-web-devicons" },

  -- md-render needs no setup(); this only runs once the plugin has loaded.
  config = function()
    adapt_preview()
    require("andrew.utils.md_render_tab_visibility").setup()
    require("andrew.utils.md_render_headings").setup()
    require("andrew.utils.md_render_heading_colors").setup()
    require("andrew.utils.md_render_heading_background").setup()
    require("andrew.utils.md_render_math").setup()
    -- Last: it wraps what the ones above have wrapped.
    require("andrew.utils.md_render_repaint").setup()
  end,

  -- `init`, not `config`: the autocmds have to exist before the plugin loads on
  -- its first :MdRender. Until then they cost a few variable lookups per event.
  init = function()
    local adapter_group = vim.api.nvim_create_augroup("md-render-adapter", { clear = true })

    vim.api.nvim_create_autocmd("BufEnter", {
      group = adapter_group,
      callback = function(event)
        release_window_from_stale_render_state(event.buf)
        render_revisited_auto_buffer(event.buf)
        if vim.b[event.buf].md_render then
          -- Scheduled: md-render empties 'statuscolumn' in its own BufEnter for
          -- this buffer, which runs after this one.
          local window = vim.api.nvim_get_current_win()
          vim.schedule(function()
            centre_rendered_view(window)
          end)
        end
      end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
      group = adapter_group,
      callback = function(event)
        local window = vim.api.nvim_get_current_win()
        -- Either side of a swap: a rendered view or a markdown buffer. Whether
        -- it was a swap is only known once it is over.
        local is_swappable = vim.b[event.buf].md_render or vim.bo[event.buf].filetype == "markdown"
        if is_swappable and vim.api.nvim_win_get_buf(window) == event.buf then
          -- The cursor is read now, while it is still this buffer's.
          local origin_cursor = vim.api.nvim_win_get_cursor(window)
          vim.schedule(function()
            carry_cursor_across_swap(window, event.buf, origin_cursor)
          end)
        end
      end,
    })

    vim.api.nvim_create_autocmd("WinNew", {
      group = adapter_group,
      callback = function()
        inherit_render_state_from_split_parent()
        -- A split of a rendered view fires no BufEnter: same buffer.
        local window = vim.api.nvim_get_current_win()
        vim.schedule(function()
          centre_rendered_view(window)
        end)
      end,
    })

    -- NOT scheduled: md-render re-wraps on WinResized too, measuring the window
    -- without its gutter. This autocmd is older than that one and so runs
    -- first, which is what lets md-render measure with the new margin.
    vim.api.nvim_create_autocmd("WinResized", {
      group = adapter_group,
      callback = function()
        for _, window in ipairs(vim.v.event.windows or {}) do
          centre_rendered_view(window)
        end
      end,
    })
  end,
}
