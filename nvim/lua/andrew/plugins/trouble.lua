-- =============================================================================
-- Diagnostics and Quickfix Viewer (trouble.nvim)
-- =============================================================================
-- Configures trouble for viewing diagnostics, todo comments, and quickfix lists.
-- Provides a structured view of issues in your code.

return {
  -- Plugin: trouble.nvim - A pretty list for showing diagnostics
  -- Repository: https://github.com/folke/trouble.nvim
  "folke/trouble.nvim",

  -- Dependencies
  dependencies = {
    "nvim-tree/nvim-web-devicons",  -- Icons in diagnostic list
    "folke/todo-comments.nvim",      -- TODO comment integration
  },

  -- =============================================================================
  -- Plugin Options
  -- =============================================================================
  opts = {
    -- Focus the trouble window when opening
    focus = true,

    -- Custom modes for trouble views
    modes = {
      -- Preview mode: shows diagnostics in a floating window
      preview_float = {
        mode = "diagnostics",
        preview = {
          type = "float",
          relative = "editor",
          border = "rounded",
          title = "Trouble Errors/Diagnostics Preview",
          title_pos = "left",
          position = { 0, 0 },
          size = { width = 1.0, height = 0.625 },
          zindex = 200,
        },
      },
    },
  },

  -- Load when Trouble command is used
  cmd = "Trouble",

  -- =============================================================================
  -- Keybindings
  -- =============================================================================
  -- All trouble commands are prefixed with <leader>x

  keys = {
    -- Workspace diagnostics (all files)
    {
      "<leader>xw",
      "<cmd>Trouble preview_float toggle<CR>",
      desc = "Open trouble: workspace diagnostics (floating preview)",
    },

    -- Document diagnostics (current file only)
    {
      "<leader>xd",
      "<cmd>Trouble preview_float toggle filter.buf=0<CR>",
      desc = "Open trouble: current file diagnostics",
    },

    -- Errors only (current file)
    {
      "<leader>xe",
      "<cmd>Trouble preview_float toggle filter.buf=0 filter.severity=vim.diagnostic.severity.ERROR<CR>",
      desc = "Trouble: errors only in current file",
    },

    -- Errors only (workspace)
    {
      "<leader>xE",
      "<cmd>Trouble preview_float toggle filter.severity=vim.diagnostic.severity.ERROR<CR>",
      desc = "Trouble: errors only in workspace",
    },

    -- Quickfix list toggle
    { "<leader>xq", "<cmd>Trouble quickfix toggle<CR>", desc = "Open quickfix list" },

    -- Location list toggle
    { "<leader>xl", "<cmd>Trouble loclist toggle<CR>", desc = "Open location list" },

    -- TODO comments viewer
    { "<leader>xt", "<cmd>Trouble todo toggle<CR>", desc = "Open TODO comments" },

    -- fzf-lua integration
    { "<leader>xf", "<cmd>Trouble fzf toggle<CR>", desc = "Open fzf-lua results in Trouble" },
    {
      "<leader>xF",
      "<cmd>Trouble fzf_files toggle<CR>",
      desc = "Open fzf-lua file results in Trouble",
    },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function(_, opts)
    -- Initialize trouble with options
    require("trouble").setup(opts)

    -- =============================================================================
    -- Line Numbers in Preview Floats
    -- =============================================================================
    -- Ensure Trouble preview windows have relative line numbers

    -- @returns nil
    local function apply_to_trouble_preview_floats()
      -- Check if Trouble is open in any window
      local trouble_open = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].filetype == "trouble" then
          trouble_open = true
          break
        end
      end
      if not trouble_open then
        return
      end

      -- Apply line numbers to all floating windows that aren't Trouble itself
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
          local cfg = vim.api.nvim_win_get_config(win)

          -- Check if this is a floating window
          if cfg and cfg.relative and cfg.relative ~= "" then
            local buf = vim.api.nvim_win_get_buf(win)
            -- Apply to preview windows (not the Trouble list itself)
            if vim.bo[buf].filetype ~= "trouble" then
              vim.wo[win].number = true
              vim.wo[win].relativenumber = true
            end
          end
        end
      end
    end

    -- =============================================================================
    -- Autocommand for Window Events
    -- =============================================================================
    -- Apply line numbers when windows are created or entered

    vim.api.nvim_create_autocmd({ "WinNew", "WinEnter", "CursorMoved" }, {
      group = vim.api.nvim_create_augroup("AndrewTroublePreview", { clear = true }),
      callback = function()
        -- Defer slightly so newly-created preview windows exist
        vim.defer_fn(apply_to_trouble_preview_floats, 30)
      end,
    })
  end,
}
