-- =============================================================================
-- Theme Cycle
-- =============================================================================
-- Cycles between: OneDark → Soft Paper Light → Soft Paper Dark → OneDark
-- Preserves and restores the original OneDark state when cycling back.

local M = {}

-- Cycle order: the first entry is the "home" theme (restored from saved state).
-- Entries 2+ are the soft-paper variants.
local CYCLE = { "onedark", "soft-paper-light", "soft-paper-dark" }

--- Saved state from before we left the home theme.
---@type { name: string, background: string }|nil
local saved_state = nil

--- Current index in CYCLE (1 = home, 2 = SP light, 3 = SP dark).
local cycle_idx = 1

--- Get the current position in the cycle based on vim.g.colors_name.
---@return number
local function detect_index()
  local name = vim.g.colors_name or ""
  for i, entry in ipairs(CYCLE) do
    if name == entry then
      return i
    end
  end
  return 1 -- default to home
end

--- Update lualine to match the active theme.
---@param sp_palette table|nil soft-paper palette, or nil to restore original
---@param variant? "light"|"dark" soft-paper variant
local function update_lualine(sp_palette, variant)
  local ok, lualine = pcall(require, "lualine")
  if not ok then return end

  if sp_palette then
    local sp = require("andrew.themes.soft-paper")
    lualine.setup({ options = { theme = sp.lualine_theme(sp_palette, variant) } })
  else
    -- Restore original lualine: use "auto" and let it re-derive from colorscheme
    lualine.setup({ options = { theme = "auto" } })
    vim.defer_fn(function()
      local lok, lmod = pcall(require, "lualine")
      if lok then
        lmod.setup({ options = { theme = "auto" } })
      end
    end, 50)
  end

  vim.cmd("redrawstatus")
end

--- Activate a soft-paper variant.
---@param variant "light"|"dark"
local function activate_soft_paper(variant)
  -- Save home state on first departure
  if not saved_state then
    saved_state = {
      name = vim.g.colors_name or "onedark",
      background = vim.o.background,
    }
  end

  vim.cmd("colorscheme soft-paper-" .. variant)

  local sp = require("andrew.themes.soft-paper")
  update_lualine(sp.active_palette, variant)
end

--- Restore the original (home) colorscheme.
local function restore_home()
  if saved_state then
    vim.o.background = saved_state.background
    vim.cmd("colorscheme " .. saved_state.name)
    saved_state = nil
  else
    vim.o.background = "dark"
    vim.cmd("colorscheme onedark")
  end

  update_lualine(nil)
end

--- Cycle to the next theme in the rotation.
function M.cycle()
  cycle_idx = detect_index()
  cycle_idx = (cycle_idx % #CYCLE) + 1

  local target = CYCLE[cycle_idx]

  if target == "soft-paper-light" then
    activate_soft_paper("light")
    vim.notify("Theme: Soft Paper Light", vim.log.levels.INFO)
  elseif target == "soft-paper-dark" then
    activate_soft_paper("dark")
    vim.notify("Theme: Soft Paper Dark", vim.log.levels.INFO)
  else
    restore_home()
    vim.notify("Theme: " .. (vim.g.colors_name or "onedark"), vim.log.levels.INFO)
  end
end

-- =============================================================================
-- Setup: register commands and keybindings
-- =============================================================================

function M.setup()
  vim.api.nvim_create_user_command("ThemeCycle", function()
    M.cycle()
  end, { desc = "Cycle: OneDark → SP Light → SP Dark → OneDark" })

  vim.api.nvim_create_user_command("SoftPaperLight", function()
    activate_soft_paper("light")
    cycle_idx = 2
    vim.notify("Theme: Soft Paper Light", vim.log.levels.INFO)
  end, { desc = "Activate soft-paper light" })

  vim.api.nvim_create_user_command("SoftPaperDark", function()
    activate_soft_paper("dark")
    cycle_idx = 3
    vim.notify("Theme: Soft Paper Dark", vim.log.levels.INFO)
  end, { desc = "Activate soft-paper dark" })

  vim.keymap.set("n", "<leader>tp", function()
    M.cycle()
  end, { desc = "Cycle theme: OneDark → SP Light → SP Dark", silent = true })
end

return M
