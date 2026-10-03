-- =============================================================================
-- LSP Server and Tool Installer Configuration (mason.nvim)
-- =============================================================================
-- Configures mason for installing LSP servers and development tools.
-- Mason provides a standardized way to install and manage external tools.

-- Filetypes with a configured LSP server or mason-managed tool. Single source of
-- truth shared with lspconfig.lua; see andrew.lsp_filetypes for the rationale.
local SERVER_FILETYPES = require("andrew.lsp_filetypes")

return {
  -- =============================================================================
  -- Mason LSP Config
  -- =============================================================================
  -- Manages LSP server installation and configuration

  {
    -- Plugin: mason-lspconfig - LSP server manager integration
    -- Repository: https://github.com/mason-org/mason-lspconfig.nvim
    "mason-org/mason-lspconfig.nvim",

    -- Load only when a filetype with an actual server/tool is opened, so the
    -- installer never loads at startup nor for server-less files (markdown, etc.)
    ft = SERVER_FILETYPES,

    -- LazyVim's <leader>cm. Routed through the Mason command, whose cmd gate
    -- lives on the mason.nvim dependency below -- adding `keys` does not make
    -- the spec any less lazy, it just adds a second trigger.
    keys = {
      { "<leader>cm", "<cmd>Mason<CR>", desc = "Mason" },
    },

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

      -- mason-lspconfig v2 auto-enables EVERY installed server via
      -- vim.lsp.enable(). rust_analyzer must be excluded: rustaceanvim owns the
      -- Rust client and starts its own, so auto-enabling it here launched a
      -- second rust-analyzer alongside rustaceanvim's for every Rust buffer.
      automatic_enable = { exclude = { "rust_analyzer" } },
    },

    -- Dependencies
    dependencies = {
      -- mason: Core package manager
      {
        "mason-org/mason.nvim",

        -- The mason commands are created by mason.nvim, NOT by
        -- mason-lspconfig, so the cmd gate has to live here. With it on the
        -- parent spec, lazy.nvim ran Handler.disable (nvim_del_user_command on
        -- its own stubs) when mason-lspconfig loaded -- and if mason.nvim had
        -- already loaded first and installed the REAL commands, those got
        -- deleted instead, leaving :Mason gone and <leader>cm throwing E464.
        cmd = { "Mason", "MasonInstall", "MasonUpdate", "MasonUninstall", "MasonLog" },

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

    -- Load only for filetypes with a server/tool (matches mason-lspconfig) so the
    -- tool installer no longer drags the mason tree in at startup or for markdown.
    ft = SERVER_FILETYPES,
    cmd = { "MasonToolsInstall", "MasonToolsUpdate", "MasonToolsClean" },

    opts = {
      -- Tools to ensure are installed
      ensure_installed = {
        "prettier",     -- Code formatter (JS/TS/JSON/YAML/HTML/CSS)
        "ty",           -- Python type checker
        "ruff",         -- Python linter and formatter
        "eslint_d",     -- ESLint daemon (faster linting)
        "ctags-lsp",    -- ctags-backed completion/definitions for C/C++
        "rust_analyzer",  -- Rust language server (also a tool)
        "codelldb",     -- Debug adapter for Rust/C/C++

        -- The four below are already declared in mason-lspconfig's
        -- ensure_installed above, but that install runs asynchronously and only
        -- once mason-lspconfig itself has loaded -- i.e. when a matching buffer
        -- actually attaches. Headless seeding never attaches anything, so the
        -- Apptainer image shipped without them and `vim.lsp.enable("pylsp")`
        -- had no binary to find. Listing them here makes MasonToolsInstallSync
        -- (which IS synchronous) responsible for them instead.
        "python-lsp-server",       -- pylsp, enabled unconditionally in lspconfig.lua
        "emmet-ls",                -- emmet_ls
        "prisma-language-server",  -- prismals
        "eslint-lsp",              -- eslint
      },
    },

    dependencies = {
      -- mason: Core package manager dependency
      "mason-org/mason.nvim",
    },
  },
}
