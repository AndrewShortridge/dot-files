-- =============================================================================
-- md-render: a scaled heading sits on its window's background
-- =============================================================================
-- md-render draws a scaled heading straight to the terminal, as a block of
-- cells in colours it has to state itself: nothing of Neovim's shows through.
-- The foreground is the heading group's. For the background, a heading group
-- that has none gets NormalFloat's, whatever window the view is in
-- (`sgr_for` in md-render.text_size). That is right in the `:MdRender` float
-- and wrong everywhere else: in place, in a split or in a tab the window is
-- painted with Normal, or with NormalNC while another window has the focus.
-- Under onedark the three differ (#17191d, #1e222a, #282c34), so every heading
-- sat in a box darker than the page around it.
--
-- md-render derives a run's colours from a highlight group NAMED in the
-- heading's placement, and uses that group's background when it has one. So
-- each placement is pointed at a copy of its heading group that carries the
-- background of the window it is in, and pointed again when that changes:
-- the focus moves, or the colourscheme does.
--
-- Not followed: a window with its own 'winhighlight' for Normal.
--
-- Pinned by tests/md_render_heading_background_spec.lua. Drop this file when
-- md-render takes the background from the window.

local M = {}

--- Heading state of md-render.text_size -> the window it draws in. Not read
--- from `state.win`, which md_render_tab_visibility.lua swaps out.
---@type table<table, integer>
local window_of_heading_state = setmetatable({}, { __mode = "k" })

--- Placement -> the heading group md-render gave it.
---@type table<table, string>
local heading_group_of = setmetatable({}, { __mode = "k" })

---@param group_name string
---@return integer?
local function background_of(group_name)
  return vim.api.nvim_get_hl(0, { name = group_name, link = false }).bg
end

--- The group Neovim paints a window's background with.
---@param window integer
---@return string? group_name nil for a float, where md-render's own choice is the right one
local function background_group_of(window)
  if
    not vim.api.nvim_win_is_valid(window) or vim.api.nvim_win_get_config(window).relative ~= ""
  then
    return nil
  end
  if window ~= vim.api.nvim_get_current_win() and background_of("NormalNC") then
    return "NormalNC"
  end
  return "Normal"
end

--- A copy of a heading group with a window background under it.
---@param heading_group string
---@param background_group string
---@return string group_name the heading group itself when there is nothing to add
local function heading_group_on(heading_group, background_group)
  local heading = vim.api.nvim_get_hl(0, { name = heading_group, link = false })
  local background = background_of(background_group)
  -- A colourscheme that gives headings a background of their own keeps it; a
  -- transparent one has none to give.
  if heading.bg or not background then
    return heading_group
  end
  local group_name = heading_group .. "On" .. background_group
  -- Only what md-render reads from it.
  vim.api.nvim_set_hl(0, group_name, {
    fg = heading.fg,
    bg = background,
    bold = heading.bold,
    italic = heading.italic,
  })
  return group_name
end

---@param state table
local function use_window_background(state)
  local window = window_of_heading_state[state]
  local background_group = window and background_group_of(window)
  if not background_group then
    return
  end
  for _, placement in ipairs(state.placements or {}) do
    heading_group_of[placement] = heading_group_of[placement] or placement.hl
    placement.hl = heading_group_on(heading_group_of[placement], background_group)
  end
end

--- Point every view's headings at their groups again, made anew. Also for a
--- caller that changed the heading groups (md_render_heading_colors.lua).
---
--- Nothing is drawn here: md-render writes its headings again every time
--- Neovim settles, with whatever group the placements name by then.
function M.refresh()
  for state in pairs(window_of_heading_state) do
    use_window_background(state)
  end
  -- md-render caches the colours of a group by its name, and the groups made
  -- above may have been made again in other colours.
  require("md-render.text_size").reset_sgr_cache()
end

---@param state table?
---@param window integer
---@return table? state
local function track_heading_state(state, window)
  if state then
    window_of_heading_state[state] = window
    use_window_background(state)
  end
  return state
end

--- Wrap md-render's heading painter. Call once md-render has loaded.
function M.setup()
  local text_size = require("md-render.text_size")
  local upstream_attach = text_size.attach
  local upstream_refresh = text_size.refresh

  -- Both only queue a paint, so the placements are pointed at their groups
  -- before the first one goes out.
  text_size.attach = function(window, content)
    return track_heading_state(upstream_attach(window, content), window)
  end
  text_size.refresh = function(state, window, content)
    return track_heading_state(upstream_refresh(state, window, content), window)
  end

  local group = vim.api.nvim_create_augroup("md-render-heading-background", { clear = true })

  -- The focus moved: every window but the one entered is NormalNC now.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = M.refresh,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      -- Scheduled: anything else that sets colours on this event goes first.
      vim.schedule(M.refresh)
    end,
  })
end

return M
