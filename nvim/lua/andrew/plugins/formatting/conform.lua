-- =============================================================================
-- Code Formatter Configuration (conform.nvim)
-- =============================================================================
-- Configures conform.nvim for automatic and manual code formatting.
-- Formatters are applied on save for supported file types.

return {
  -- Plugin: conform.nvim - Flexible formatter plugin for Neovim
  -- Repository: https://github.com/stevearc/conform.nvim
  "stevearc/conform.nvim",

  -- Load eagerly for BufWritePre autocmd availability
  lazy = false,

  -- Expose ConformInfo command for debugging
  cmd = { "ConformInfo" },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load conform module
    local conform = require("conform")

    -- Resolve Prettier from active conda environment
    -- This ensures we use the conda-installed version
    local conda_prettier = vim.fn.expand("$CONDA_PREFIX/bin/prettier")

    -- Resolve fprettify from conda environment for Fortran formatting
    local conda_fprettify = vim.fn.expand("$CONDA_PREFIX/bin/fprettify")

    -- Configure conform with formatters and options
    conform.setup({
      -- =============================================================================
      -- Auto-format on Save
      -- =============================================================================
      format_on_save = {
        -- Timeout for formatting (1 second)
        timeout_ms = 1000,

        -- Fallback to LSP formatting if no formatter available
        lsp_fallback = true,
      },

      -- =============================================================================
      -- Formatter Definitions
      -- =============================================================================
      -- Each formatter specifies the command and arguments for formatting

      formatters = {
        -- stylua: Lua formatter (from conda)
        stylua = {
          command = "stylua",
          args = {
            "--search-parent-directories",  -- Look for stylua.toml config
            "--stdin-filepath",             -- Read file path from stdin
            "$FILENAME",                    -- Pass filename as argument
            "-",                             -- Read from stdin
          },
          stdin = true,  -- Accept input via stdin
        },

        -- ruff format: Python formatter (from conda)
        ruff_format = {
          command = "ruff",
          args = {
            "format",              -- Run formatter
            "--stdin-filename", "$FILENAME",
            "-",                   -- Read from stdin
          },
          stdin = true,
        },

        -- prettier: JavaScript/TypeScript/JSON/YAML/etc formatter
        prettier = {
          command = conda_prettier,
          args = { "--stdin-filepath", "$FILENAME" },
          stdin = true,
        },

        -- fprettify: Fortran formatter (from conda)
        fprettify = {
          command = conda_fprettify,
          args = { "--indent=2", "--whitespace=2", "-" },
          stdin = true,
        },
      },

      -- =============================================================================
      -- Formatter Mapping by File Type
      -- =============================================================================
      -- Maps file types to their appropriate formatters

      formatters_by_ft = {
        -- Lua files use stylua
        lua = { "stylua" },

        -- Note: Rust formatting is handled by rustaceanvim/rust-analyzer

        -- Python files use ruff format
        python = { "ruff_format" },

        -- JavaScript/TypeScript files use prettier
        javascript = { "prettier" },
        javascriptreact = { "prettier" },
        typescript = { "prettier" },
        typescriptreact = { "prettier" },

        -- Vue, CSS, HTML use prettier
        vue = { "prettier" },
        css = { "prettier" },
        scss = { "prettier" },
        html = { "prettier" },

        -- Configuration files use prettier
        json = { "prettier" },
        yaml = { "prettier" },
        markdown = { "prettier" },

        -- Fortran files use fprettify
        fortran = { "fprettify" },
      },
    })

    -- =============================================================================
    -- Format on Save Autocmd
    -- =============================================================================
    -- Automatically format buffers when saving supported file types

    vim.api.nvim_create_autocmd("BufWritePre", {
      -- Group autocmds for easy management
      group = vim.api.nvim_create_augroup("ConformFormat", {}),

      -- File patterns to format on save
      -- Note: Rust (*.rs) is handled by rustaceanvim/rust-analyzer
      pattern = {
        "*.lua",
        "*.py",
        "*.js",
        "*.ts",
        "*.tsx",
        "*.jsx",
        "*.json",
        "*.css",
        "*.scss",
        "*.html",
        "*.yaml",
        "*.yml",
        "*.md",
        -- Fortran files
        "*.f90",
        "*.f95",
        "*.f03",
        "*.f08",
        "*.F90",
      },

      -- Format the buffer on write
      callback = function(args)
        conform.format({
          bufnr = args.buf,
          async = true,       -- Format asynchronously to avoid blocking
          lsp_fallback = true,  -- Fallback to LSP if no formatter
        })
      end,
    })
  end,
}
