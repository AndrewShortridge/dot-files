-- =============================================================================
-- md-render: nothing drawn for a view on another tab page
-- =============================================================================
-- md-render draws two things straight to the terminal, past Neovim's grid:
-- images (Kitty graphics placements) and scaled headings (OSC 66 text sizing).
-- Both are put at the screen cells of the view's window, and both are kept
-- alive by timers and redraw hooks -- a 200 ms tick while anything is
-- animated, a 500 ms one plus every redraw for headings -- whose only question
-- is whether that window still EXISTS. A window on another tab page exists. So
-- with a view open, `:tabnew` left its pictures and headings being painted
-- over the new tab several times a second (v3.11.2: 42 placements and 700
-- heading runs written in the four seconds after switching away).
--
-- Here a view draws only while its window is on the current tab page:
--
--   * Images. `put_image` and `clear_placements` of md-render.image are
--     wrapped, which covers every caller -- the animation tick, a scroll, an
--     image that finishes loading late -- without touching md-render's state.
--   * Headings. md-render.text_size has nothing per window to wrap: its
--     writers are local functions that read `state.win`. The window of a
--     heading state is therefore swapped for an invalid one while it is off
--     screen, which every one of those writers checks for first. This is the
--     part that leans on md-render's internals.
--   * TabLeave takes what is on screen off it, TabEnter puts back what belongs
--     to the tab arrived in.
--
-- Pinned by tests/md_render_tab_visibility_spec.lua, which counts what is
-- written to the terminal. Drop this file when md-render checks for the
-- current tab page itself.

local M = {}

--- Stands in for the window of a heading state while that window is on another
--- tab page.
local OFFSCREEN_WINDOW = -1

---@param window integer
---@return boolean
local function is_on_current_tabpage(window)
  return vim.api.nvim_win_is_valid(window)
    and vim.api.nvim_win_get_tabpage(window) == vim.api.nvim_get_current_tabpage()
end

-- -----------------------------------------------------------------------------
-- Images
-- -----------------------------------------------------------------------------

--- Image id -> the window md-render placed it in. Learned from `put_image`,
--- the one call that names both; md-render never reuses an id.
---@type table<integer, integer>
local window_of_image = {}

local function draw_images_only_on_current_tabpage()
  local image = require("md-render.image")
  local upstream_put_image = image.put_image
  local upstream_clear_placements = image.clear_placements

  image.put_image = function(image_id, window, ...)
    window_of_image[image_id] = window
    if is_on_current_tabpage(window) then
      return upstream_put_image(image_id, window, ...)
    end
  end

  -- Gated too, and not to save a write. Kitty reads "delete the placements of
  -- image N" (`a=d,d=a,i=N`) as "delete every placement on screen": `d=a`
  -- ignores the id. The animation tick of a view on another tab would wipe the
  -- pictures of the views on this one five times a second.
  --
  -- An image that was never placed has nothing to delete either, so an id not
  -- seen in `put_image` is dropped as well.
  image.clear_placements = function(image_id)
    local window = window_of_image[image_id]
    if window and is_on_current_tabpage(window) then
      return upstream_clear_placements(image_id)
    end
  end
end

local function remove_images_of_current_tabpage()
  local image = require("md-render.image")
  image.begin_batch()
  for image_id, window in pairs(window_of_image) do
    if not vim.api.nvim_win_is_valid(window) then
      window_of_image[image_id] = nil
    elseif is_on_current_tabpage(window) then
      image.clear_placements(image_id)
    end
  end
  image.flush_batch()
end

-- -----------------------------------------------------------------------------
-- Scaled headings
-- -----------------------------------------------------------------------------

--- Heading state -> the window it belongs to, which `state.win` only names
--- while that window is on screen.
---@type table<table, integer>
local window_of_heading_state = setmetatable({}, { __mode = "k" })

--- Set by TabLeave when headings were on screen in the tab being left.
---
--- Their cells are not Neovim's, so the redraw of a tab switch leaves any of
--- them standing where the two tabs happen to show the same text, and
--- md-render's own erase before each redraw blanks cells Neovim then sees no
--- reason to send again. `:mode` is the one thing that puts the whole screen
--- right, as md-render.text_size itself concludes.
local is_full_repaint_owed = false

---@param state table?
---@param window integer
---@return table? state
local function track_heading_state(state, window)
  if state then
    window_of_heading_state[state] = window
    if not is_on_current_tabpage(window) then
      state.win = OFFSCREEN_WINDOW
    end
  end
  return state
end

local function draw_headings_only_on_current_tabpage()
  local text_size = require("md-render.text_size")
  local upstream_attach = text_size.attach
  local upstream_refresh = text_size.refresh
  local upstream_detach = text_size.detach

  text_size.attach = function(window, content)
    return track_heading_state(upstream_attach(window, content), window)
  end

  -- `refresh` writes the window back into the state. It runs for a view on
  -- another tab whenever that view is rebuilt: an image arriving late, or its
  -- source being edited in this tab.
  text_size.refresh = function(state, window, content)
    return track_heading_state(upstream_refresh(state, window, content), window)
  end

  -- `detach` unregisters the state under `state.win`.
  text_size.detach = function(state)
    local window = state and window_of_heading_state[state]
    if window then
      state.win = window
      window_of_heading_state[state] = nil
    end
    return upstream_detach(state)
  end
end

local function hide_headings_of_current_tabpage()
  for state, window in pairs(window_of_heading_state) do
    if is_on_current_tabpage(window) then
      state.win = OFFSCREEN_WINDOW
      is_full_repaint_owed = true
    end
  end
end

local function show_headings_of_current_tabpage_only()
  for state, window in pairs(window_of_heading_state) do
    state.win = is_on_current_tabpage(window) and window or OFFSCREEN_WINDOW
  end
end

-- -----------------------------------------------------------------------------

--- Wrap md-render's two terminal-drawing modules. Call once md-render has
--- loaded: it requires them.
function M.setup()
  draw_images_only_on_current_tabpage()
  draw_headings_only_on_current_tabpage()

  local group = vim.api.nvim_create_augroup("md-render-tab-visibility", { clear = true })

  -- The tab being left is still the current one here.
  vim.api.nvim_create_autocmd("TabLeave", {
    group = group,
    callback = function()
      remove_images_of_current_tabpage()
      hide_headings_of_current_tabpage()
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      -- Scheduled: Neovim has not drawn the tab yet.
      vim.schedule(function()
        show_headings_of_current_tabpage_only()
        if is_full_repaint_owed then
          is_full_repaint_owed = false
          vim.cmd.mode()
        else
          vim.cmd.redraw()
        end
        -- md-render's own "the screen was repainted, put yourselves back".
        -- Every view answers; only those on this tab get anything drawn.
        require("md-render.display_utils").announce_repaint("tab-switch")
      end)
    end,
  })
end

return M
