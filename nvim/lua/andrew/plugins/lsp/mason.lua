-- =============================================================================
-- LSP Server and Tool Installer Configuration (mason.nvim)
-- =============================================================================
-- Configures mason for installing LSP servers and development tools.
-- Mason provides a standardized way to install and manage external tools.

return {
  -- =============================================================================
  -- Mason LSP Config
  -- =============================================================================
  -- Manages LSP server installation and configuration

  {
    -- Plugin: mason-lspconfig - LSP server manager integration
    -- Repository: https://github.com/williamboman/mason-lspconfig.nvim
    "williamboman/mason-lspconfig.nvim",

    -- Configuration options
    opts = {
      -- LSP servers to ensure are installed
      ensure_installed = {
        "lua_ls",       -- Lua language server
        "emmet_ls",     -- HTML/CSS completion (Emmet)
        "prismals",     -- Prisma schema language server
        "pylsp",        -- Python LSP
        "eslint",       -- JavaScript/TypeScript linter
        "rust_analyzer",  -- Rust language server
      },

      -- Automatically install servers that aren't present
      automatic_installation = true,
    },

    -- Dependencies
    dependencies = {
      -- mason: Core package manager
      {
        "williamboman/mason.nvim",
        opts = {
          -- UI configuration for mason status display
          ui = {
            icons = {
              package_installed = "✓",    -- Shown for installed packages
              package_pending = "➜",      -- Shown for installing packages
              package_uninstalled = "✗",  -- Shown for uninstalled packages
            },
          },
        },
      },

      -- nvim-lspconfig: Required for LSP server configuration
      "neovim/nvim-lspconfig",
    },
  },

  -- =============================================================================
  -- Mason Tool Installer
  -- =============================================================================
  -- Installs development tools that aren't LSP servers

  {
    -- Plugin: mason-tool-installer - Auto-install development tools
    -- Repository: https://github.com/WhoIsSethDaniel/mason-tool-installer.nvim
    "WhoIsSethDaniel/mason-tool-installer.nvim",

    opts = {
      -- Tools to ensure are installed
      ensure_installed = {
        "prettier",     -- Code formatter (JS/TS/JSON/YAML/HTML/CSS)
        "ty",           -- Python type checker
        "ruff",         -- Python linter and formatter
        "eslint_d",     -- ESLint daemon (faster linting)
        "rust_analyzer",  -- Rust language server (also a tool)
        "codelldb",     -- Debug adapter for Rust/C/C++
      },
    },

    dependencies = {
      -- mason: Core package manager dependency
      "williamboman/mason.nvim",
    },
  },
}
