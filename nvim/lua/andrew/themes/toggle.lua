-- =============================================================================
-- Light / Dark Theme Switching
-- =============================================================================
-- Dark  = onedark  (OneDarkPro's Atom One Dark, configured in plugins/colorscheme.lua)
-- Light = soft-paper-light
--
-- Replaces the old three-way cycler (<leader>ut / :ThemeCycle), which rotated
-- onedark -> soft-paper-light -> soft-paper-dark. The dark/light pair is now
-- driven by <leader>ub, registered as a Snacks.toggle in plugins/snacks.lua so
-- it picks up which-key's enabled/disabled icon like every other UI toggle.
--
-- TWO THINGS THAT MUST NOT REGRESS
--
-- 1. Switching goes through `:colorscheme`, never soft-paper's `load()` directly.
--    Only the real command fires the ColorScheme event, and vault/colors.lua
--    (augroup VaultColors) listens for it to re-derive ~120 Vault* highlight
--    groups from vim.g.colors_name. Calling load() straight would leave every
--    Vault highlight on the previous palette. plugins/render-markdown.lua hangs
--    off the same event.
--
-- 2. The light scheme must keep the name "soft-paper-light". vault/colors.lua
--    selects its palette by pattern-matching that exact name; anything else
--    falls through to its catch-all and picks the dark OneDark palette on a
--    paper background.
--
-- Lualine is re-themed on every switch. The old cycler restored `theme = "auto"`
-- when returning to onedark, silently discarding the hand-tuned statusline
-- palette; it is now restored properly from andrew.themes.lualine_theme.

local M = {}

--- Re-theme lualine and repaint the statusline.
---@param theme table|string lualine theme table, or a theme name
local function apply_lualine(theme)
  local ok, lualine = pcall(require, "lualine")
  if not ok then
    return
  end
  lualine.setup({ options = { theme = theme } })
  vim.cmd("redrawstatus")
end

--- Activate a soft-paper variant.
---@param variant "light"|"dark"
function M.activate_soft_paper(variant)
  -- soft-paper.load() sets vim.o.background itself; go through :colorscheme so
  -- the ColorScheme event fires (see note 1 above).
  vim.cmd.colorscheme("soft-paper-" .. variant)

  local sp = require("andrew.themes.soft-paper")
  apply_lualine(sp.lualine_theme(sp.active_palette, variant))
end

--- Activate the dark theme (OneDarkPro's Atom One Dark).
function M.activate_onedark()
  vim.o.background = "dark"

  -- Clear UNCONDITIONALLY, and note why the usual guard is wrong here.
  --
  -- Setting 'background' above resets vim.g.colors_name to nil. Every
  -- `if vim.g.colors_name then hi clear end` guard -- the conventional
  -- colorscheme idiom, and the one in onedarkpro's own output
  -- (onedarkpro/lib/compile.lua:112) -- is therefore already disarmed by the
  -- time it runs. Nothing cleared, and 248 highlight groups kept their
  -- soft-paper values on returning to dark.
  --
  -- The visible symptom was the gutter. gitsigns rebuilds its ~49 groups on
  -- ColorScheme but skips any that is "already defined"
  -- (gitsigns/highlight.lua:302), so the stale light ones were never
  -- re-derived -- all the GitSignsStaged* especially. GitSignsAdd/Change/
  -- Delete looked right only because soft-paper redefines those four by hand
  -- (soft-paper.lua:391-394). BufferLine*, Snacks*, Fzf* and Ibl* were
  -- stranded the same way.
  vim.cmd("highlight clear")
  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end

  vim.cmd.colorscheme("onedark")
  apply_lualine(require("andrew.themes.lualine_theme").theme)
end

--- Is a dark background currently active?
--- Both onedark and soft-paper-dark report true; only soft-paper-light is light.
---@return boolean
function M.is_dark()
  return vim.o.background == "dark"
end

--- Switch between the dark and light themes.
---@param dark boolean true for onedark, false for soft-paper-light
function M.set_dark(dark)
  if dark then
    M.activate_onedark()
  else
    M.activate_soft_paper("light")
  end
end

-- =============================================================================
-- Setup: register commands
-- =============================================================================

function M.setup()
  vim.api.nvim_create_user_command("SoftPaperLight", function()
    M.activate_soft_paper("light")
  end, { desc = "Activate soft-paper light" })

  vim.api.nvim_create_user_command("SoftPaperDark", function()
    M.activate_soft_paper("dark")
  end, { desc = "Activate soft-paper dark" })
end

return M
