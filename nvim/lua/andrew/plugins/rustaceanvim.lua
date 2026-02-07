-- =============================================================================
-- Rust Development Plugin (rustaceanvim)
-- =============================================================================
-- Comprehensive Rust development plugin that provides enhanced LSP support,
-- debugging integration, and Rust-specific commands.
-- Repository: https://github.com/mrcjkb/rustaceanvim

return {
  -- Plugin: rustaceanvim - Supercharge your Rust experience
  -- Repository: https://github.com/mrcjkb/rustaceanvim
  "mrcjkb/rustaceanvim",

  -- Version constraint: Use latest v6.x
  version = "^6",

  -- This plugin is already lazy-loaded by filetype
  lazy = false,

  -- Dependencies
  dependencies = {
    "mfussenegger/nvim-dap",
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- =============================================================================
    -- CodeLLDB Debug Adapter Setup (via Mason)
    -- =============================================================================
    local cfg = require("rustaceanvim.config")

    -- Mason installs packages to ~/.local/share/nvim/mason/packages/
    local mason_path = vim.fn.stdpath("data") .. "/mason/packages/codelldb"
    local extension_path = mason_path .. "/extension/"
    local codelldb_path = extension_path .. "adapter/codelldb"
    -- Use .so for Linux, .dylib for macOS
    local liblldb_path = extension_path .. "lldb/lib/liblldb.so"

    -- Default DAP config (no adapter if codelldb not installed)
    local dap_adapter = nil

    -- Configure codelldb adapter if installed
    if vim.fn.executable(codelldb_path) == 1 then
      dap_adapter = cfg.get_codelldb_adapter(codelldb_path, liblldb_path)
    end

    vim.g.rustaceanvim = {
      -- =============================================================================
      -- LSP Server Settings
      -- =============================================================================
      server = {
        -- Capabilities are inherited from default LSP config
        on_attach = function(_client, bufnr)
          -- =============================================================================
          -- Rust-specific Keybindings
          -- =============================================================================
          local opts = { buffer = bufnr, silent = true }

          -- Code actions (grouped by category)
          opts.desc = "Rust code actions"
          vim.keymap.set("n", "<leader>ca", function()
            vim.cmd.RustLsp("codeAction")
          end, opts)

          -- Enhanced hover with actions
          opts.desc = "Rust hover actions"
          vim.keymap.set("n", "K", function()
            vim.cmd.RustLsp({ "hover", "actions" })
          end, opts)

          -- Runnables (run main, examples, etc.)
          opts.desc = "Rust runnables"
          vim.keymap.set("n", "<leader>rr", function()
            vim.cmd.RustLsp("runnables")
          end, opts)

          -- Debuggables (debug with DAP)
          opts.desc = "Rust debuggables"
          vim.keymap.set("n", "<leader>rd", function()
            vim.cmd.RustLsp("debuggables")
          end, opts)

          -- Testables (run tests)
          opts.desc = "Rust testables"
          vim.keymap.set("n", "<leader>rt", function()
            vim.cmd.RustLsp("testables")
          end, opts)

          -- Expand macro recursively
          opts.desc = "Expand macro"
          vim.keymap.set("n", "<leader>rm", function()
            vim.cmd.RustLsp("expandMacro")
          end, opts)

          -- Open Cargo.toml
          opts.desc = "Open Cargo.toml"
          vim.keymap.set("n", "<leader>rc", function()
            vim.cmd.RustLsp("openCargo")
          end, opts)

          -- Parent module
          opts.desc = "Go to parent module"
          vim.keymap.set("n", "<leader>rp", function()
            vim.cmd.RustLsp("parentModule")
          end, opts)

          -- Join lines (Rust-aware)
          opts.desc = "Join lines"
          vim.keymap.set("n", "J", function()
            vim.cmd.RustLsp("joinLines")
          end, opts)

          -- Explain error
          opts.desc = "Explain error"
          vim.keymap.set("n", "<leader>re", function()
            vim.cmd.RustLsp("explainError")
          end, opts)

          -- Render diagnostics
          opts.desc = "Render diagnostics"
          vim.keymap.set("n", "<leader>rD", function()
            vim.cmd.RustLsp("renderDiagnostic")
          end, opts)

          -- Debugger testables
          opts.desc = "Debugger testables"
          vim.keymap.set("n", "<leader>dt", function()
            vim.cmd.RustLsp("testables")
          end, opts)
        end,

        -- Default rust-analyzer settings
        default_settings = {
          ["rust-analyzer"] = {
            -- Enable all cargo features
            cargo = {
              allFeatures = true,
            },

            -- Run clippy on save for additional linting
            checkOnSave = true,
            check = {
              command = "clippy",
            },

            -- Inlay hints configuration
            inlayHints = {
              -- Show type hints for bindings
              bindingModeHints = { enable = true },
              -- Show closure return type hints
              closureReturnTypeHints = { enable = "always" },
              -- Show lifetime elision hints
              lifetimeElisionHints = { enable = "always" },
            },

            -- Proc macro support
            procMacro = {
              enable = true,
            },
          },
        },
      },

      -- =============================================================================
      -- DAP (Debugging) Configuration
      -- =============================================================================
      dap = {
        -- Use CodeLLDB adapter from Mason (if installed)
        adapter = dap_adapter,
      },
    }
  end,
}
