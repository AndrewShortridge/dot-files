-- =============================================================================
-- File Explorer Integration (yazi.nvim)
-- =============================================================================
-- Configures yazi as a terminal-based file explorer within Neovim.
-- Yazi provides fast file navigation with preview capabilities.

return {
  -- Plugin: yazi.nvim - Neovim integration for Yazi file manager
  -- Repository: https://github.com/mikavilpas/yazi.nvim
  "mikavilpas/yazi.nvim",

  -- Load lazily (on demand)
  event = "VeryLazy",

  -- Upstream ships a git submodule (yazi-plugin/yazi-plugins) used only for
  -- developing the Yazi-side plugin. A recursive checkout of a freshly added
  -- submodule fails under lazy.nvim ("could not reset submodule index") and
  -- leaves the checkout dirty, so skip submodules; nothing at runtime needs it.
  submodules = false,

  -- Dependencies
  dependencies = {
    "nvim-lua/plenary.nvim",      -- Utility functions
    "nvim-tree/nvim-web-devicons", -- File type icons
  },

  -- Initialize before config (disable netrw)
  init = function()
    vim.g.loaded_netrw = 1
    vim.g.loaded_netrwPlugin = 1

    -- With netrw suppressed above, the FileExplorer augroup netrw normally
    -- creates never exists. yazi.nvim's hijack_netrw then runs
    -- `silent! autocmd! FileExplorer *`, which raises E216 (no such group) --
    -- `silent!` hides the message but still poisons v:errmsg for the whole
    -- session. Pre-declaring the (empty) group makes that command a no-op.
    vim.api.nvim_create_augroup("FileExplorer", { clear = false })
  end,

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    local yazi = require("yazi")

    -- =============================================================================
    -- fzf-lua Integration for Grep
    -- =============================================================================
    -- Allows grepping within Yazi using fzf-lua

    -- Grep in selected directory using fzf-lua
    local function fzf_live_grep_in_dir(dir)
      local ok, fzf = pcall(require, "fzf-lua")
      if not ok then
        vim.notify("yazi.nvim: fzf-lua not found (install ibhagwan/fzf-lua)", vim.log.levels.ERROR)
        return
      end

      fzf.live_grep({
        cwd = dir,
        prompt = "Yazi Grep> ",
      })
    end

    -- Grep in selected files using fzf-lua
    local function fzf_live_grep_in_files(files)
      local ok, fzf = pcall(require, "fzf-lua")
      if not ok then
        vim.notify("yazi.nvim: fzf-lua not found (install ibhagwan/fzf-lua)", vim.log.levels.ERROR)
        return
      end

      fzf.live_grep({
        search_paths = files,
        prompt = "Yazi Grep (selected)> ",
      })
    end

    -- =============================================================================
    -- Yazi Setup
    -- =============================================================================
    yazi.setup({
      -- Allow opening directories directly
      open_for_directories = true,

      -- Open file function: edit selected file
      open_file_function = function(chosen_file, _config, _state)
        vim.cmd("edit " .. vim.fn.fnameescape(chosen_file))
      end,

      -- Window appearance
      floating_window_scaling_factor = 0.90,  -- 90% of editor size
      yazi_floating_window_border = "rounded",
      yazi_floating_window_winblend = 0,      -- No transparency

      -- Keymaps inside Yazi
      keymaps = {
        show_help = "<f1>",
        grep_in_directory = "<c-s>",
      },

      -- fzf-lua integrations for grep
      integrations = {
        grep_in_directory = function(dir)
          fzf_live_grep_in_dir(dir)
        end,
        grep_in_selected_files = function(selected_files)
          fzf_live_grep_in_files(selected_files)
        end,
      },
    })

    -- =============================================================================
    -- Line Numbers in Yazi Preview
    -- =============================================================================
    -- Enable line numbers in Yazi preview windows

    local YAZI_NUMBERS_DEBUG = false
    local function debug(msg)
      if YAZI_NUMBERS_DEBUG then
        vim.schedule(function()
          vim.notify(msg, vim.log.levels.INFO, { title = "yazi.nvim numbers" })
        end)
      end
    end

    local function apply_yazi_window_numbers()
      -- Check if Yazi is open
      local yazi_open = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].filetype == "yazi" then
          yazi_open = true
          break
        end
      end
      if not yazi_open then
        return
      end

      -- Apply line numbers to non-Yazi windows (preview panes)
      local applied = 0
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype ~= "yazi" then
            vim.wo[win].number = true
            vim.wo[win].relativenumber = true
            applied = applied + 1
          end
        end
      end
      debug("applied number/relativenumber to " .. applied .. " window(s)")
    end

    -- Apply on window events
    vim.api.nvim_create_autocmd({ "WinNew", "WinEnter", "BufEnter", "CursorMoved" }, {
      group = vim.api.nvim_create_augroup("AndrewYaziPreviewNumbers", { clear = true }),
      callback = function()
        vim.defer_fn(apply_yazi_window_numbers, 80)
      end,
    })

    -- =============================================================================
    -- Keybindings
    -- =============================================================================
    local keymap = vim.keymap

    -- Open Yazi file explorer
    keymap.set("n", "<leader>ee", function()
      yazi.yazi()
    end, { desc = "Toggle file explorer (Yazi)" })

    -- Open Yazi on current file's directory
    keymap.set("n", "<leader>ef", function()
      yazi.yazi({ path = vim.fn.expand("%:p") })
    end, { desc = "Open file explorer on current file (Yazi)" })

    -- Close Yazi window. A bare `:close` raises E444 (plus a traceback) when
    -- there is only one window, so close the yazi window explicitly when one is
    -- open and refuse to close the last window otherwise.
    keymap.set("n", "<leader>ec", function()
      local wins = vim.api.nvim_tabpage_list_wins(0)
      for _, w in ipairs(wins) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].filetype == "yazi" then
          pcall(vim.api.nvim_win_close, w, true)
          return
        end
      end
      if #wins < 2 then
        vim.notify("No explorer window to close", vim.log.levels.WARN)
        return
      end
      pcall(vim.cmd, "close")
    end, { desc = "Close explorer window (Yazi)" })

    -- Refresh Yazi
    keymap.set("n", "<leader>er", function()
      yazi.yazi()
    end, { desc = "Refresh explorer (Yazi)" })
  end,
}
