-- =============================================================================
-- LSP Server and Tool Installer Configuration (mason.nvim)
-- =============================================================================
-- Mason is an INSTALLER and nothing else in this config. Nothing here runs when
-- a file is opened: both plugins load only when one of their commands is used.
--
--   * Servers are enabled natively by vim.lsp.enable() in lspconfig.lua.
--     mason-lspconfig.nvim used to do that for every installed package, and to
--     find out which packages were installed it parsed the whole mason registry
--     inside the FileType autocmd -- 16-31 ms before the first paint of every
--     code buffer. It is gone.
--   * mason's bin directory is put on $PATH by init.lua, so installed tools
--     resolve without mason.nvim being loaded.
--
-- On a fresh machine, run :MasonToolsInstall once. (The Apptainer image does the
-- same with MasonToolsInstallSync; see container/nvim.def.)

return {
  -- =============================================================================
  -- Mason
  -- =============================================================================
  {
    -- Plugin: mason.nvim - package manager for LSP servers, linters, formatters
    -- Repository: https://github.com/mason-org/mason.nvim
    "mason-org/mason.nvim",

    cmd = { "Mason", "MasonInstall", "MasonUpdate", "MasonUninstall", "MasonLog" },

    -- LazyVim's <leader>cm.
    keys = {
      { "<leader>cm", "<cmd>Mason<CR>", desc = "Mason" },
    },

    opts = {
      -- init.lua owns the $PATH entry (see the header). "skip" stops mason from
      -- prepending a second copy of it whenever :Mason is opened.
      PATH = "skip",

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

  -- =============================================================================
  -- Mason Tool Installer
  -- =============================================================================
  -- Declares which mason packages this config expects, and installs the missing
  -- ones on :MasonToolsInstall.

  {
    -- Plugin: mason-tool-installer - install a declared list of mason packages
    -- Repository: https://github.com/WhoIsSethDaniel/mason-tool-installer.nvim
    "WhoIsSethDaniel/mason-tool-installer.nvim",

    cmd = {
      "MasonToolsInstall",
      "MasonToolsInstallSync",
      "MasonToolsUpdate",
      "MasonToolsUpdateSync",
      "MasonToolsClean",
    },

    opts = {
      -- Command-only: checking the list means loading the mason registry, which
      -- is the cost this file exists to keep off the startup path.
      run_on_start = false,

      -- MASON PACKAGE names, not lspconfig server names. The two differ
      -- (rust-analyzer vs rust_analyzer, lua-language-server vs lua_ls) and
      -- only mason-lspconfig could translate; without it an lspconfig name here
      -- is an unknown package.
      ensure_installed = {
        -- Tools
        "prettier",     -- Code formatter (JS/TS/JSON/YAML/HTML/CSS)
        "ruff",         -- Python linter and formatter (also the `ruff` LSP server)
        "ty",           -- Python type checker (also the `ty` LSP server)
        "eslint_d",     -- ESLint daemon (faster linting)
        "codelldb",     -- Debug adapter for Rust/C/C++

        -- LSP servers (enabled in lspconfig.lua; rust-analyzer by rustaceanvim)
        "lua-language-server",     -- lua_ls
        "python-lsp-server",       -- pylsp
        "rust-analyzer",           -- rust_analyzer
        "ctags-lsp",               -- ctags_lsp (C/C++)
        "emmet-ls",                -- emmet_ls
        "prisma-language-server",  -- prismals
        "eslint-lsp",              -- eslint
      },
    },

    dependencies = {
      "mason-org/mason.nvim",
    },
  },
}
