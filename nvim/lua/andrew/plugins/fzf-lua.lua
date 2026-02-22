-- =============================================================================
-- Fuzzy Finder Configuration (fzf-lua)
-- =============================================================================
-- Configures fzf-lua for fuzzy finding files, grep results, buffers, and more.
-- Uses fzf as the underlying fuzzy matching engine.

return {
  -- Plugin: fzf-lua - A modern replacement for Telescope
  -- Repository: https://github.com/ibhagwan/fzf-lua
  "ibhagwan/fzf-lua",

  -- Plugin dependencies
  dependencies = {
    "nvim-tree/nvim-web-devicons",  -- File type icons in results
    "nvim-lua/plenary.nvim",         -- Utility functions
    "folke/todo-comments.nvim",      -- TODO comment integration
  },

  -- Load plugin when FzfLua command or keys are used
  cmd = "FzfLua",

  -- =============================================================================
  -- Keybindings
  -- =============================================================================
  -- All fzf-lua commands are prefixed with <leader>f

  keys = {
    -- File operations
    {
      "<leader>ff",
      function()
        require("fzf-lua").files()
      end,
      desc = "Fuzzy find files in current directory",
    },
    {
      "<leader>fr",
      function()
        require("fzf-lua").oldfiles()
      end,
      desc = "Fuzzy find recently opened files",
    },

    -- Search operations
    {
      "<leader>fs",
      function()
        require("fzf-lua").live_grep()
      end,
      desc = "Live grep: find string in current directory",
    },
    {
      "<leader>fc",
      function()
        require("fzf-lua").grep_cword()
      end,
      desc = "Grep current word: find string under cursor",
    },

    -- Help and keymaps
    {
      "<leader>fk",
      function()
        require("fzf-lua").keymaps()
      end,
      desc = "Fuzzy find keybindings",
    },
    {
      "<leader>fh",
      function()
        require("fzf-lua").help_tags()
      end,
      desc = "Search Neovim :help tags",
    },

    -- Advanced search: grep through Neovim documentation
    {
      "<leader>fH",
      function()
        local fzf = require("fzf-lua")
        local doc_paths = vim.api.nvim_get_runtime_file("doc", true)

        fzf.live_grep({
          search_paths = doc_paths,
          prompt = "Help Grep> ",
          rg_glob = "--glob='*.txt'",
        })
      end,
      desc = "Grep Neovim :help documentation",
    },

    -- TODO comments search
    { "<leader>ft", "<cmd>TodoFzfLua<cr>", desc = "Find TODO/FIXME comments" },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Import modules
    local fzf_config = require("fzf-lua.config")
    local trouble_actions = require("trouble.sources.fzf").actions
    local fzf = require("fzf-lua")
    local actions = require("fzf-lua.actions")

    -- =============================================================================
    -- Trouble Integration
    -- =============================================================================
    -- Press Ctrl-t inside fzf-lua to open results in Trouble
    fzf_config.defaults.actions.files["ctrl-t"] = trouble_actions

    -- =============================================================================
    -- Setup fzf-lua
    -- =============================================================================
    fzf.setup({
      -- =============================================================================
      -- File Finder Configuration
      -- =============================================================================
      files = {
        -- Use fd (from conda) for finding files
        -- --type f: search files only (not directories)
        -- --hidden: include hidden files
        -- --exclude .git: ignore .git directory
        cmd = "fd --type f --hidden --exclude .git",
      },

      -- =============================================================================
      -- Grep Configuration
      -- =============================================================================
      grep = {
        -- Ripgrep options for consistent output
        rg_opts = table.concat({
          "--color=never",      -- No ANSI colors in output
          "--no-heading",       -- Don't group by file
          "--with-filename",    -- Show filename in results
          "--line-number",      -- Show line numbers
          "--column",           -- Show column numbers
          "--smart-case",       -- Case-insensitive unless uppercase in query
        }, " "),
      },

      -- =============================================================================
      -- Window Options
      -- =============================================================================
      winopts = {
        -- Window dimensions (fraction of editor)
        height = 0.85,  -- 85% of editor height
        width = 0.80,   -- 80% of editor width

        -- Preview window configuration
        preview = {
          layout = "flex",  -- Auto-adjust preview size
        },
      },

      -- =============================================================================
      -- Keybindings Inside fzf Window
      -- =============================================================================
      keymap = {
        -- Neovim side keybindings
        builtin = {
          ["<C-j>"] = "down",  -- Move to next result
          ["<C-k>"] = "up",    -- Move to previous result
        },

        -- fzf side keybindings
        fzf = {
          ["ctrl-q"] = "select-all+accept",  -- Select all and accept
        },
      },

      -- =============================================================================
      -- Default Actions
      -- =============================================================================
      actions = {
        -- Actions for file pickers
        files = {
          ["default"] = actions.file_edit,   -- Open in current window
          ["ctrl-s"] = actions.file_split,   -- Open in horizontal split
          ["ctrl-v"] = actions.file_vsplit,  -- Open in vertical split
          ["ctrl-t"] = actions.file_tabedit, -- Open in new tab
          ["ctrl-q"] = actions.file_sel_to_qf,  -- Send to quickfix list
        },

        -- Actions for buffer pickers
        buffers = {
          ["default"] = actions.buf_edit,    -- Switch to buffer
          ["ctrl-s"] = actions.buf_split,    -- Split and show buffer
          ["ctrl-v"] = actions.buf_vsplit,   -- Vsplit and show buffer
          ["ctrl-t"] = actions.buf_tabedit,  -- Show buffer in new tab
        },
      },
    })
  end,
}
