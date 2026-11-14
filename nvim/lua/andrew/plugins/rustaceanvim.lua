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

  -- Version constraint: Use latest v9.x
  -- (bumped from ^6: v6.9.7 calls the deprecated vim.lsp.get_buffers_by_client_id
  --  on rust-analyzer init; fixed in v7.0.0+. v9 requires nvim >= 0.12, which we have.
  --  No config-schema breaking changes across v7/v8/v9 affect this setup.)
  version = "^9",

  -- Lazy-load on rust filetype. The plugin is purely filetype-driven (it acts on
  -- rust buffers via vim.g.rustaceanvim), so there is no reason to load it — or its
  -- nvim-dap dependency — at startup for non-rust filetypes. `ft` implies lazy.
  ft = { "rust" },

  -- Dependencies
  dependencies = {
    "mfussenegger/nvim-dap",
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  -- Set vim.g.rustaceanvim at startup via `init` (runs WITHOUT loading the plugin),
  -- because rustaceanvim reads this global as it loads on the first rust buffer.
  -- (Using `config` would set it only after load has already begun — too late.)
  init = function()
    -- =============================================================================
    -- CodeLLDB Debug Adapter Setup (via Mason)
    -- =============================================================================
    -- NOTE: the adapter table is built inline rather than via
    -- require("rustaceanvim.config").get_codelldb_adapter — `init` runs at startup
    -- before the lazy-gated plugin is on the runtimepath, so requiring it would
    -- fail. This table is byte-identical to that helper's return value.

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
      -- Mirrors rustaceanvim.config.get_codelldb_adapter(codelldb_path, liblldb_path)
      dap_adapter = {
        type = "server",
        port = "${port}",
        host = "127.0.0.1",
        executable = {
          command = codelldb_path,
          args = { "--liblldb", liblldb_path, "--port", "${port}" },
        },
      }
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
