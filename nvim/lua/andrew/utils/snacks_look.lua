-- =============================================================================
-- Snacks Picker Look: the fzf-lua look, on the pickers snacks still owns
-- =============================================================================
-- Every fzf-lua picker shares one look (andrew/utils/fzf_look.lua): the snacks
-- picker's layout, coloured like fzf-lua's `telescope` profile. A few pickers
-- are snacks' own and cannot be fzf-lua ones -- the GitHub issue / pull-request
-- pickers on <leader>gi / gI / gp / gP, and the vim.ui.select menus. Their
-- layout is already the one the fzf look copies; this gives them its colours
-- and, where there is a preview, its paging keys.
--
-- Snacks colours every picker through one small set of highlight groups, so
-- the colours apply to all of its pickers at once. Snacks defines those groups
-- with `default = true`, which is what lets the definitions here win.
--
-- Deliberately free of any `require("fzf-lua")`: snacks loads at startup and
-- fzf-lua on first use.

local M = {}

--- `group`, unless the colourscheme leaves it undefined: then `fallback`.
--- The same test fzf-lua's telescope profile applies to each of its groups,
--- with the group fzf-lua itself falls back to in that case, so the two sets
--- of pickers still agree under a colourscheme without Telescope support.
---@param group string
---@param fallback string
---@return string
local function group_or(group, fallback)
  local is_defined = next(vim.api.nvim_get_hl(0, { name = group, link = false })) ~= nil
  return is_defined and group or fallback
end

--- One colour of a group, links followed.
---@param group string
---@param attribute "fg"|"bg"
---@return integer?
local function colour_of(group, attribute)
  return vim.api.nvim_get_hl(0, { name = group, link = false })[attribute]
end

--- (Re)define snacks' picker groups from the Telescope groups the fzf look
--- uses. The right-hand sides mirror fzf-lua's profiles/telescope.lua.
function M.apply_colours()
  local set_hl = vim.api.nvim_set_hl
  local normal = group_or("TelescopeNormal", "Normal")
  local border = group_or("TelescopeBorder", "Normal")
  local title = group_or("TelescopePromptTitle", normal)
  local preview_title = group_or("TelescopePreviewTitle", title)
  local selection = group_or("TelescopeSelection", "CursorLine")

  -- Every picker window (input, list, preview, the boxes around them) links
  -- to these three unless told otherwise.
  set_hl(0, "SnacksPicker", { link = normal })
  set_hl(0, "SnacksPickerBorder", { link = border })
  set_hl(0, "SnacksPickerTitle", { link = title })
  set_hl(0, "SnacksPickerPreviewTitle", { link = preview_title })

  -- The GitHub pickers hand the preview window their own window options
  -- while an issue or pull request is shown in it, and these are the groups
  -- those options name for a float. (`SnacksGhNormal`, for an issue opened in
  -- an ordinary window, is left alone.)
  set_hl(0, "SnacksGhNormalFloat", { link = normal })
  set_hl(0, "SnacksGhBorder", { link = border })
  set_hl(0, "SnacksGhTitle", { link = preview_title })

  set_hl(0, "SnacksPickerMatch", { link = group_or("TelescopeMatching", "Special") })
  -- fzf takes single colours out of these groups rather than the whole group;
  -- so do these. The selected row gets the background only: as a CursorLine
  -- group, a foreground would repaint every icon and label on the row.
  set_hl(0, "SnacksPickerListCursorLine", { bg = colour_of(selection, "bg") })
  set_hl(0, "SnacksPickerPreviewCursorLine", { bg = colour_of(selection, "bg") })
  -- The prompt icon is drawn in the input window's status column, whose own
  -- background (LineNr's) shows through a group that sets none.
  set_hl(0, "SnacksPickerPrompt", {
    fg = colour_of(group_or("TelescopePromptPrefix", "Special"), "fg"),
    bg = colour_of(normal, "bg"),
    bold = true,
  })
  -- fzf prints the typed query in bold, and the match counter beside it not.
  -- The counter sits in the same window, so it has to opt out of the bold
  -- (`nocombine`) and then name its background itself.
  local prompt_normal = group_or("TelescopePromptNormal", normal)
  set_hl(0, "SnacksPickerInput", {
    fg = colour_of(prompt_normal, "fg"),
    bg = colour_of(prompt_normal, "bg"),
    bold = true,
  })
  set_hl(0, "SnacksPickerTotals", {
    fg = colour_of(group_or("TelescopeMultiSelection", "NonText"), "fg"),
    bg = colour_of(prompt_normal, "bg"),
    nocombine = true,
  })
end

--- Apply the colours now and again after every colourscheme change, which
--- clears them along with everything else.
function M.setup()
  M.apply_colours()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("AndrewSnacksPickerLook", { clear = true }),
    callback = M.apply_colours,
    desc = "Snacks pickers: re-apply the fzf look's colours",
  })
end

--- `picker.on_show` hook: colour the title on a picker's boxes.
---
--- A highlight group alone cannot do it. The group snacks intends for the
--- title, SnacksPickerBoxTitle, never reaches the window: a box window's own
--- default (`FloatTitle:SnacksTitle`, shared by every snacks float) is merged
--- in after it and wins, so the mapping is corrected on the windows instead.
---
--- on_show rather than `layout.config`, which would also survive a layout
--- change while the picker is open: vim.ui.select passes a `layout.config` of
--- its own, which would replace this one on every select menu.
---@param picker table snacks.Picker
function M.style_box_titles(picker)
  for _, box_window in pairs(picker.layout.box_wins) do
    if box_window:valid() then
      local window = box_window.win
      local winhighlight =
        vim.wo[window].winhighlight:gsub("FloatTitle:[^,]+", "FloatTitle:SnacksPickerTitle")
      vim.api.nvim_set_option_value("winhighlight", winhighlight, { win = window, scope = "local" })
      -- Snacks re-applies a window's options from this table when it updates.
      box_window.opts.wo.winhighlight = winhighlight
    end
  end
end

--- Scroll a picker's preview by one page.
---@param page_key string the normal-mode key that pages, e.g. "<C-f>"
---@return fun(picker: table)
local function page_preview(page_key)
  local keys = vim.keycode(page_key)
  return function(picker)
    local preview_window = picker.preview and picker.preview.win
    if preview_window and preview_window:valid() then
      vim.api.nvim_win_call(preview_window.win, function()
        vim.cmd("normal! " .. keys)
      end)
    end
  end
end

--- Source options that put the fzf look's preview paging on <C-d> / <C-u>,
--- for a snacks picker that has a preview. Snacks' own binding for the two
--- keys scrolls the LIST by half a page; that stays on the pickers without a
--- preview, where there is nothing else for the keys to do.
---@return table
function M.preview_paging_opts()
  return {
    actions = {
      preview_page_down = page_preview("<C-f>"),
      preview_page_up = page_preview("<C-b>"),
    },
    win = {
      input = {
        keys = {
          ["<c-d>"] = { "preview_page_down", mode = { "i", "n" } },
          ["<c-u>"] = { "preview_page_up", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<c-d>"] = "preview_page_down",
          ["<c-u>"] = "preview_page_up",
        },
      },
    },
  }
end

return M
