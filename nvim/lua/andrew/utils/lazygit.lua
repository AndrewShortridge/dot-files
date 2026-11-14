-- =============================================================================
-- Lazygit launcher: edit files in the pane lazygit was opened from
-- =============================================================================
-- Port of craftzdog's `utils/lazygit.lua`
-- (https://github.com/craftzdog/dotfiles, dot_config/nvim/lua/craftzdog/utils).
--
-- Snacks' default integration sets lazygit's `os.editPreset = "nvim-remote"`,
-- whose edit command is `nvim --remote-tab`: pressing `e` on a file in lazygit
-- opens it in a NEW TAB of this Neovim. This module replaces that command so
-- the file lands in the window lazygit was launched from instead:
--
--   1. `open()` records the current window, then opens the lazygit float.
--   2. `e` in lazygit runs `edit_command()`, which talks back to this Neovim
--      over its RPC socket ($NVIM): quit lazygit, call `focus_origin()`, then
--      `--remote <file>` -- which edits in whatever window is current.
--
-- The two halves only work together: `edit_command()` is handed to snacks as
-- `lazygit.config.os.edit` / `editAtLine` in plugins/snacks.lua, and the
-- <leader>gg / <leader>gG keys in plugins/git.lua must go through `open()`,
-- not `Snacks.lazygit()` directly, or there is no recorded window to return to.
--
-- ONE DIFFERENCE FROM HIS: the shell syntax. lazygit runs `os.edit` through
-- $SHELL (falling back to bash). His command is written for fish
-- (`begin; if test ...; end; end`); the login shell here is bash, so this one
-- is POSIX `if [ ... ]; then ...; else ...; fi`, which bash, zsh and dash all
-- accept. It is NOT valid fish -- switch the template back if $SHELL ever is.

local M = {}

--- Window lazygit was launched from; files edited from inside it open here.
---@type integer|nil
local origin_window = nil

--- Open lazygit, remembering the focused window as the edit target.
---@param opts? table  Snacks.lazygit options, forwarded as-is (e.g. `cwd`)
---@return table  the snacks window holding the lazygit float
function M.open(opts)
  origin_window = vim.api.nvim_get_current_win()
  return Snacks.lazygit(opts)
end

--- Focus the window lazygit was launched from, so the `nvim --remote <file>`
--- that follows edits there. Called over RPC by the command built below.
--- No-op when that window is gone (closed while lazygit was open), which
--- leaves `--remote` to fall back to the current window.
function M.focus_origin()
  if origin_window and vim.api.nvim_win_is_valid(origin_window) then
    pcall(vim.api.nvim_set_current_win, origin_window)
  end
end

-- The Neovim instance that launched lazygit ($NVIM is its RPC socket).
local NVIM_SERVER = 'nvim --server "$NVIM"'

-- `<Cmd>` runs in any mode, including the terminal mode the float is in. The
-- long bracket keeps both quote styles free of escaping.
local FOCUS_ORIGIN_COMMAND = NVIM_SERVER
  .. [[ --remote-send '<Cmd>lua require("andrew.utils.lazygit").focus_origin()<CR>']]

--- Build a lazygit `os.edit` / `os.editAtLine` command. lazygit substitutes
--- `{{filename}}` (already shell-quoted) and `{{line}}`.
---@param opts? { at_line?: boolean }  also jump to `{{line}}` after opening
---@return string
function M.edit_command(opts)
  local should_jump_to_line = opts ~= nil and opts.at_line == true

  -- No $NVIM: lazygit was started from a plain shell, so just edit directly.
  local outside_neovim = should_jump_to_line and "nvim +{{line}} -- {{filename}}"
    or "nvim -- {{filename}}"

  -- Inside Neovim: quit lazygit, return to the launch window, open the file.
  local inside_neovim = {
    NVIM_SERVER .. ' --remote-send "q"',
    FOCUS_ORIGIN_COMMAND,
    NVIM_SERVER .. " --remote {{filename}}",
  }
  if should_jump_to_line then
    inside_neovim[#inside_neovim + 1] = NVIM_SERVER .. ' --remote-send ":{{line}}<CR>"'
  end

  return ('if [ -z "$NVIM" ]; then %s; else %s; fi'):format(
    outside_neovim,
    table.concat(inside_neovim, "; ")
  )
end

return M
