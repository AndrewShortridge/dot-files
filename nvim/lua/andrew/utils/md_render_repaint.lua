-- =============================================================================
-- md-render: a live preview does not flicker while its source is edited
-- =============================================================================
-- md-render draws scaled headings and images straight to the terminal, past
-- Neovim's grid. Kitty mishandles text written into the cells of a scaled
-- heading, so md-render erases every heading before each redraw and writes
-- them back after it; with `:MdRender split` open it also rebuilds the view
-- 150 ms after every edit of the source. Between the erase and the write the
-- headings are not on screen, and in v3.11.2 that gap is often long enough to
-- see. Replaying what Neovim wrote to the terminal while five words were typed
-- into a paragraph, with the completion menu coming and going, the headings
-- were off the screen for 1.1 s out of 5, up to 110 ms at a time:
--
--   * After a redraw md-render only writes the headings back where they were.
--     If the SET on screen changed -- the completion menu came to lie over
--     one, or left -- it waits for a repaint that is debounced by 90 to
--     180 ms and that every key puts off again. Until then none is on screen.
--   * What it writes is only queued for the terminal. Neovim hands it over
--     the next time it flushes the screen, after everything else the key set
--     off has run; a completion menu alone is 10 to 15 ms.
--   * A rebuild makes md-render forget where the headings were, so that its
--     next paint repaints the whole screen. Nothing writes them back until
--     that paint, about 50 ms later (90 ms in a note without images).
--   * A rebuild repaints the whole screen again (`redraw!`) to place the
--     images, also when none of them moved.
--   * Any window opening, closing or changing size anywhere -- the completion
--     menu again -- makes md-render repaint the whole screen (`:mode`), also
--     when no heading moved. A full repaint is the longest redraw there is.
--
-- Here:
--
--   * A redraw with headings on screen reaches the terminal as ONE frame,
--     together with the headings written back after it, by holding
--     synchronized output (DEC 2026) open from the start of the redraw until
--     they are back. Erased-and-not-yet-rewritten is never presented.
--   * Headings a redraw erased are written back in the next turn of the event
--     loop wherever they belong now, and flushed to the terminal at once.
--     That is queued when a key arrives, so ahead of what the key sets off.
--   * A rebuild that left every heading where it was keeps md-render's record
--     of them, and one that left every image where it was places none again.
--   * A full repaint is kept for when a heading moved on screen.
--
-- The second point is what keeps the first cheap: a held frame shows up as
-- late as its headings are. In the same replay the headings are never off
-- the screen while text is typed, and a frame is held for half a millisecond
-- as a rule and 9 ms at the longest.
--
-- Not held: redraws while a command or a prompt is being typed. The hold
-- could not be flushed away there (see `can_flush_to_terminal`), so Neovim's
-- own synchronized output is back on meanwhile and the headings go for 10 to
-- 40 ms per redraw, as they did.
--
-- A heading that a float lies over (the completion menu, say) is shown at
-- plain size until the float goes. That is md-render's, and deliberate:
-- scaled text cannot be clipped, so it is all of a heading or none.
--
-- Set up LAST of the md-render adapters: `refresh` here has to see the state
-- after md_render_tab_visibility.lua and md_render_heading_background.lua have
-- had it.
--
-- This reads md-render's internals -- the heading state and its `drawn`,
-- `last_layout`, `last_drawn`, `owes_invalidate` and `augroup` fields -- so
-- an md-render update is the likeliest thing to break it. Pinned by
-- tests/md_render_repaint_spec.lua, which reads what is written to the
-- terminal. Drop each part when md-render does the same.

local M = {}

--- What makes two heading placements the same block on screen. Not `hl`:
--- md_render_heading_background.lua renames it, and a colour needs no erase.
local HEADING_PLACEMENT_FIELDS =
  { "line", "col", "text", "width", "scale", "num", "den", "icon", "icon_col" }

--- What makes two image placements the same picture in the same cells.
local IMAGE_PLACEMENT_FIELDS = { "path", "line", "col", "rows", "cols", "animated" }

---@param previous_placements table[]
---@param placements table[]
---@param field_names string[]
---@return boolean
local function are_placements_unchanged(previous_placements, placements, field_names)
  if #previous_placements ~= #placements then
    return false
  end
  for index, placement in ipairs(placements) do
    local previous_placement = previous_placements[index]
    for _, field_name in ipairs(field_names) do
      if placement[field_name] ~= previous_placement[field_name] then
        return false
      end
    end
  end
  return true
end

-- -----------------------------------------------------------------------------
-- A rebuild that moved nothing
-- -----------------------------------------------------------------------------

--- md-render forgets the layout it drew on every rebuild, so that its next
--- paint clears the whole screen first: "old blocks may sit where the new
--- layout has none". Keep the layout when the rebuild left every block where
--- it was -- an edit to body text, which is most of them.
local function keep_heading_layout_across_rebuild()
  local text_size = require("md-render.text_size")
  local upstream_refresh = text_size.refresh

  -- md-render's `refresh`, replaced on purpose: what this changes is the
  -- "Here:" list at the top of the file.
  ---@diagnostic disable-next-line: duplicate-set-field
  text_size.refresh = function(state, window, content)
    local previous_placements = state and state.placements
    local previous_layout = state and state.last_layout
    local refreshed_state = upstream_refresh(state, window, content)
    -- Not when it attached anew or detached: nothing was on screen, or is.
    local is_same_view = refreshed_state ~= nil and refreshed_state == state
    if
      is_same_view
      and previous_placements
      and are_placements_unchanged(
        previous_placements,
        refreshed_state.placements,
        HEADING_PLACEMENT_FIELDS
      )
    then
      refreshed_state.last_layout = previous_layout
    end
    return refreshed_state
  end
end

--- Whether every image of a rebuilt content is already in the terminal, in the
--- cells it is wanted in.
---@param state table md-render's image state
---@param content table the rebuilt content
---@return boolean
local function are_images_in_place(state, content)
  local placements = content.image_placements
  if not placements or #placements == 0 or not state.placements then
    return false
  end
  for _, placement in ipairs(placements) do
    local is_transmitted = placement.path
      and (state.image_ids[placement.path] or state.anims[placement.path])
    if not is_transmitted then
      return false
    end
  end
  return are_placements_unchanged(state.placements, placements, IMAGE_PLACEMENT_FIELDS)
end

local function keep_images_across_rebuild()
  local display_utils = require("md-render.display_utils")
  local upstream_update_images = display_utils.update_images

  -- md-render's `update_images`, replaced on purpose: what this changes is
  -- the "Here:" list at the top of the file.
  ---@diagnostic disable-next-line: duplicate-set-field
  display_utils.update_images = function(state, window, content)
    if
      not state
      or type(state.schedule_redraw) ~= "function"
      or not are_images_in_place(state, content)
    then
      return upstream_update_images(state, window, content)
    end
    -- The rest of the update still has to run: it hands the new placements to
    -- the state and blanks the placeholder text the rebuild wrote under each
    -- image. Only the redraw it ends with is left out.
    local schedule_redraw = state.schedule_redraw
    state.schedule_redraw = function() end
    local is_updated, updated_state = pcall(upstream_update_images, state, window, content)
    state.schedule_redraw = schedule_redraw
    if not is_updated then
      error(updated_state, 0)
    end
    return updated_state
  end
end

-- -----------------------------------------------------------------------------
-- A full repaint only for headings that moved
-- -----------------------------------------------------------------------------

--- Where each heading of a layout is. md-render identifies a layout by a
--- string of `row:col:line` for every heading on screen, joined by `;`.
---@param layout string? md-render's `state.last_layout`
---@return table<string, string>? position_of_line nil when it does not read that way
local function heading_positions(layout)
  if type(layout) ~= "string" then
    return nil
  end
  local position_of_line = {}
  for entry in vim.gsplit(layout, ";", { plain = true }) do
    if entry ~= "" then
      local row, col, line = entry:match("^(%d+):(%d+):(%d+)$")
      if not row then
        return nil
      end
      position_of_line[line] = row .. ":" .. col
    end
  end
  return position_of_line
end

--- Whether a heading is somewhere else on screen than it was. One that
--- appeared or went is not: it went because something was drawn over it or it
--- left the window, and was erased before that. A layout md-render had
--- forgotten (nil) is its own way of asking for a full repaint, and one that
--- cannot be read is taken the same way.
---@param previous_layout string?
---@param layout string?
---@return boolean
local function has_a_heading_moved(previous_layout, layout)
  local previous_position_of_line = heading_positions(previous_layout)
  local position_of_line = heading_positions(layout)
  if not previous_position_of_line or not position_of_line then
    return true
  end
  for line, position in pairs(position_of_line) do
    local previous_position = previous_position_of_line[line]
    if previous_position and previous_position ~= position then
      return true
    end
  end
  return false
end

--- Heading state of md-render.text_size -> the window it draws in. Not read
--- from `state.win`, which md_render_tab_visibility.lua swaps for an invalid
--- window while the view is on another tab page.
---@type table<table, integer>
local window_of_heading_state = setmetatable({}, { __mode = "k" })

--- Which part of its buffer a window shows, and where on screen.
---@param window integer?
---@return string?
local function view_of(window)
  if not window or not vim.api.nvim_win_is_valid(window) then
    return nil
  end
  local info = vim.fn.getwininfo(window)[1]
  return table.concat(
    { info.topline, info.leftcol, info.winrow, info.wincol, info.width, info.height },
    ":"
  )
end

--- Heading state -> the layout it had when the screen was last known to hold
--- nothing of an older one: after md-render's first paint in a window, and
--- after each full repaint. NOT after every paint: the one that writes the
--- headings back after a redraw (`write_headings_now`) clears nothing, and
--- comes before the paint that carries the debt.
---@type table<table, string?>
local clean_layout_of = setmetatable({}, { __mode = "k" })

--- Heading state -> `view_of` its window at that same moment.
---@type table<table, string?>
local clean_view_of = setmetatable({}, { __mode = "k" })

--- md-render runs a full repaint (`:mode`) before a paint when the headings
--- are not where it last drew them, or when one is "owed". One is owed after
--- any window anywhere opened, closed, scrolled or changed size, because the
--- write md-render does then clears nothing. Honour the debt only if there
--- can be something for the repaint to clear: a heading has moved since the
--- screen was last clean, or the set of headings changed while the window
--- came to show another part of its buffer.
---
--- The second is a jump that takes every heading off the screen at once (`G`).
--- md-render erases a heading's cells with whatever colours the terminal was
--- last told to use (text_size.lua:1055, no SGR before the `CSI X`), and
--- Neovim then sends only the cells that differ in ITS grid -- where the
--- heading's cells beyond its plain-size text are blank before and after. So
--- they kept the colour of the erase, the statusline's as a rule, until the
--- next full repaint. A heading that goes because a float covers it does not
--- change the view, and stays cheap.
local function repaint_fully_only_for_moved_headings()
  local text_size = require("md-render.text_size")
  local upstream_paint = text_size.paint

  -- md-render's `paint`, replaced on purpose: what this changes is the
  -- "Here:" list at the top of the file.
  ---@diagnostic disable-next-line: duplicate-set-field
  text_size.paint = function(state)
    local view = state and view_of(window_of_heading_state[state])
    if state and state.owes_invalidate then
      local has_scrolled_to_other_headings = view ~= clean_view_of[state]
        and state.last_layout ~= clean_layout_of[state]
      local is_debt_empty = not has_scrolled_to_other_headings
        and not has_a_heading_moved(clean_layout_of[state], state.last_layout)
      if is_debt_empty then
        state.owes_invalidate = false
      end
    end
    -- md-render counts its full repaints; without the counter every paint
    -- is taken for one, which only costs the jump rule above.
    local statistics = text_size._stats
    local full_repaints_before = statistics and statistics.invalidations
    upstream_paint(state)
    if not state then
      return
    end
    local has_repainted_fully = not statistics or statistics.invalidations ~= full_repaints_before
    if has_repainted_fully or clean_layout_of[state] == nil then
      clean_layout_of[state] = state.last_layout
      clean_view_of[state] = view
    end
  end
end

-- -----------------------------------------------------------------------------
-- Headings across a redraw
-- -----------------------------------------------------------------------------

---@return boolean
local function has_headings_on_this_tabpage()
  local tabpage = vim.api.nvim_get_current_tabpage()
  for _, window in pairs(window_of_heading_state) do
    if vim.api.nvim_win_is_valid(window) and vim.api.nvim_win_get_tabpage(window) == tabpage then
      return true
    end
  end
  return false
end

--- Whether Neovim can be made to hand its output to the terminal right now.
--- Not while a command or a prompt is being typed: the cursor is not in a
--- window then, and the one request that flushes would put it in one.
---@return boolean
local function can_flush_to_terminal()
  return not vim.api.nvim_get_mode().mode:find("^[cr!]")
end

--- DEC private mode 2026: from BEGIN to END the terminal takes everything in
--- and presents nothing. It does not nest -- the first END ends it.
local SYNCHRONIZED_OUTPUT_BEGIN = "\27[?2026h"
local SYNCHRONIZED_OUTPUT_END = "\27[?2026l"

--- 'termsync' as it was before it was turned off here; nil while it is as the
--- user set it.
---@type boolean?
local termsync_to_restore

--- Neovim wraps every frame it flushes in synchronized output of its own
--- ('termsync'). Its END would end a hold as well, with the headings still
--- erased. So for as long as frames can be held for headings, Neovim's is off
--- and the hold stands in for it; the rest of the time Neovim's is as it was.
local function take_or_return_synchronized_output()
  local can_hold_frames = has_headings_on_this_tabpage() and can_flush_to_terminal()
  if can_hold_frames and termsync_to_restore == nil then
    termsync_to_restore = vim.o.termsync
    vim.o.termsync = false
  elseif not can_hold_frames and termsync_to_restore ~= nil then
    vim.o.termsync = termsync_to_restore
    termsync_to_restore = nil
  end
end

local function track_heading_states()
  local text_size = require("md-render.text_size")
  local upstream_attach = text_size.attach
  local upstream_refresh = text_size.refresh
  local upstream_detach = text_size.detach

  ---@param state table?
  ---@param window integer
  ---@return table? state
  local function track(state, window)
    if state then
      window_of_heading_state[state] = window
    end
    take_or_return_synchronized_output()
    return state
  end

  -- md-render's `attach`, `refresh` and `detach`, wrapped to track its
  -- heading states; the fields read are named at the top of the file.
  ---@diagnostic disable-next-line: duplicate-set-field
  text_size.attach = function(window, content)
    return track(upstream_attach(window, content), window)
  end
  -- `refresh` attaches when there was no state, and detaches when the rebuilt
  -- content has no heading left.
  ---@diagnostic disable-next-line: duplicate-set-field
  text_size.refresh = function(state, window, content)
    local refreshed_state = upstream_refresh(state, window, content)
    if state and refreshed_state ~= state then
      window_of_heading_state[state] = nil
    end
    return track(refreshed_state, window)
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  text_size.detach = function(state)
    if state then
      window_of_heading_state[state] = nil
    end
    take_or_return_synchronized_output()
    return upstream_detach(state)
  end
end

--- Write the headings of a view where they belong now, without repainting the
--- screen. What md-render does itself when a window scrolls (its
--- `restore_runs_now`), done through the event it answers that way: "the
--- screen was repainted, put yourselves back". Fired at this view's group
--- alone, so no image is placed again for it.
---@param state table
local function write_headings_now(state)
  local previous_layout = state.last_layout
  local was_repaint_owed = state.owes_invalidate
  local had_headings_on_screen = (state.last_drawn or 0) > 0
  local clean_layout = clean_layout_of[state]

  local is_written = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = require("md-render.display_utils").REPAINT_EVENT,
    group = state.augroup,
    modeline = false,
    data = { source = "md_render_repaint" },
  })
  if not is_written then
    return
  end

  -- That went through md-render's paint, which took it for a write onto a
  -- freshly repainted screen and dropped what it knew. Put it back: a heading
  -- that moved may have left something behind, which only the full repaint
  -- md-render has queued will clear, and only if it is told one is owed.
  state.owes_invalidate = was_repaint_owed
    or (had_headings_on_screen and has_a_heading_moved(previous_layout, state.last_layout))
  -- Nothing was cleared, so nothing more is known to be clean than before --
  -- and nothing at all where md-render had forgotten the layout.
  clean_layout_of[state] = previous_layout ~= nil and clean_layout or nil
end

--- Put back the headings a redraw erased and nothing has written since.
---
--- md-render's own answer after a redraw only writes them where they were. If
--- the set on screen changed, it waits for its debounced repaint instead.
---@return boolean is_anything_written
local function write_erased_headings_back()
  local is_anything_written = false
  for state in pairs(window_of_heading_state) do
    -- `drawn` is what md-render wrote last, and nil from its erase onwards.
    -- An invalid window: the view is on another tab page. No group: detached.
    if state.drawn == nil and state.augroup and vim.api.nvim_win_is_valid(state.win) then
      write_headings_now(state)
      is_anything_written = true
    end
  end
  return is_anything_written
end

--- Hand what was written to the terminal now. Neovim does that the next time
--- it flushes the screen, which is after everything else that is queued has
--- run.
---
--- The flush must not lead to a redraw: a redraw erases the headings, which
--- are then written back and flushed again, for ever. `:redraw` is one.
--- `:redrawtabline` only evaluates 'tabline' and flushes, and still did it:
--- with a second tab page open the headings were erased and rewritten some
--- four thousand times a second (why was not established). Placing the
--- cursor did not, with one tab page or two; `nvim__redraw` is how noice and
--- snacks ask for it.
local function flush_to_terminal()
  if can_flush_to_terminal() then
    pcall(vim.api.nvim__redraw, { cursor = true })
  end
end

-- -----------------------------------------------------------------------------
-- A redraw and its headings as one frame
-- -----------------------------------------------------------------------------

--- Whether BEGIN has gone out and END has not.
local is_frame_held = false

--- At the start of a redraw: keep it from the screen until `release_frame`.
local function hold_frame()
  local can_hold_frames = termsync_to_restore ~= nil
    and has_headings_on_this_tabpage()
    and can_flush_to_terminal()
  if can_hold_frames and not is_frame_held then
    is_frame_held = true
    vim.api.nvim_ui_send(SYNCHRONIZED_OUTPUT_BEGIN)
  end
end

---@return boolean was_frame_held
local function release_frame()
  if not is_frame_held then
    return false
  end
  is_frame_held = false
  vim.api.nvim_ui_send(SYNCHRONIZED_OUTPUT_END)
  return true
end

local function write_headings_back_after_every_redraw()
  local is_queued = false
  local function queue_finishing_the_frame()
    if is_queued then
      return
    end
    is_queued = true
    vim.schedule(function()
      is_queued = false
      -- Whatever happens to the headings, a held frame is let go.
      local is_done, is_anything_written = pcall(write_erased_headings_back)
      local was_frame_held = release_frame()
      take_or_return_synchronized_output()
      if was_frame_held or (is_done and is_anything_written) then
        flush_to_terminal()
      end
    end)
  end

  vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("md-render-repaint"), {
    -- Queued here as well as at the end: a redraw that is cut short has no end.
    on_start = function()
      hold_frame()
      queue_finishing_the_frame()
    end,
    -- The headings go out after the redraw has reached the terminal: they
    -- would be written over if they went out with it.
    on_end = queue_finishing_the_frame,
  })

  -- A key is seen here before anything acts on it, so this is queued ahead of
  -- whatever the key sets off and still runs after the redraw for the key.
  vim.on_key(queue_finishing_the_frame, vim.api.nvim_create_namespace("md-render-repaint-key"))

  local group = vim.api.nvim_create_augroup("md-render-repaint", { clear = true })

  -- Entering and leaving the command line, and arriving on a tab page, change
  -- whether frames can be held before any redraw says so.
  vim.api.nvim_create_autocmd({ "ModeChanged", "TabEnter" }, {
    group = group,
    callback = take_or_return_synchronized_output,
  })

  -- The terminal would sit on whatever comes next until it gives up waiting.
  vim.api.nvim_create_autocmd({ "VimLeavePre", "VimSuspend" }, {
    group = group,
    callback = function()
      -- Not `callback = release_frame`: a callback that returns true is removed.
      release_frame()
    end,
  })
end

--- Wrap md-render's terminal-drawing modules. Call once md-render has loaded,
--- after the other md-render adapters.
function M.setup()
  track_heading_states()
  keep_heading_layout_across_rebuild()
  keep_images_across_rebuild()
  repaint_fully_only_for_moved_headings()
  write_headings_back_after_every_redraw()
end

return M
