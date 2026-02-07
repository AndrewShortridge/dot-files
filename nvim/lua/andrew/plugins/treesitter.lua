-- =============================================================================
-- Syntax Highlighting and Parsing (nvim-treesitter)
-- =============================================================================
-- Configures tree-sitter for syntax highlighting, text objects, and indentation.
-- Tree-sitter provides more accurate syntax highlighting than built-in methods.

return {
  -- Plugin: nvim-treesitter - Tree-sitter integration for Neovim
  -- Repository: https://github.com/nvim-treesitter/nvim-treesitter
  "nvim-treesitter/nvim-treesitter",

  -- Events: Load when opening files for syntax highlighting
  event = { "BufReadPre", "BufNewFile" },

  -- Build command: Run after installation to parse and generate syntax files
  build = ":TSUpdate",

  -- Dependencies
  dependencies = {
    -- Auto-close HTML/XML tags
    "windwp/nvim-ts-autotag",
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Safely require treesitter module (handles install order)
    local status_ok, treesitter = pcall(require, "nvim-treesitter.configs")
    if not status_ok then
      vim.notify("nvim-treesitter not installed yet, skipping setup", vim.log.levels.WARN)
      return
    end

    -- Configure treesitter
    treesitter.setup({
      -- =============================================================================
      -- Syntax Highlighting
      -- =============================================================================
      highlight = {
        enable = true,  -- Enable syntax highlighting
      },

      -- =============================================================================
      -- Indentation
      -- =============================================================================
      -- Enable tree-sitter based indentation
      indent = { enable = true },

      -- =============================================================================
      -- Languages to Parse
      -- =============================================================================
      -- These languages will have syntax parsers installed and maintained
      ensure_installed = {
        -- Data formats
        "json",
        "yaml",
        "markdown",
        "markdown_inline",

        -- Web development
        "javascript",
        "typescript",
        "tsx",
        "html",
        "css",
        "vue",

        -- Shell and configuration
        "bash",
        "dockerfile",
        "gitignore",

        -- Programming languages
        "lua",
        "vim",
        "rust",
        "c",

        -- Neovim-specific
        "query",      -- Tree-sitter query language
        "vimdoc",     -- Vim help file syntax
      },

      -- =============================================================================
      -- Incremental Selection
      -- =============================================================================
      -- Enable selection of syntax nodes with keybindings
      incremental_selection = {
        enable = true,

        -- Keybindings for selection navigation
        keymaps = {
          init_selection = "<C-space>",    -- Start selection
          node_incremental = "<C-space>",  -- Select next node
          scope_incremental = false,       -- Disable scope selection
          node_decremental = "<bs>",       -- Select previous node (backspace)
        },
      },
    })
  end,
}
