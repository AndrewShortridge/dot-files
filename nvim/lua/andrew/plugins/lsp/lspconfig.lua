-- =============================================================================
-- Language Server Protocol Configuration
-- =============================================================================
-- Configures LSP servers, diagnostics, and LSP-related keybindings.
-- This module provides code intelligence features: completion, go-to-definition,
-- hover documentation, diagnostics, and code actions.

return {
  -- Plugin: nvim-lspconfig - LSP configuration utilities for Neovim
  -- Repository: https://github.com/neovim/nvim-lspconfig
  "neovim/nvim-lspconfig",

  -- Events: Load plugin when opening any file
  -- This ensures LSP servers are ready when editing files
  event = { "BufReadPre", "BufNewFile" },

  -- =============================================================================
  -- Plugin Dependencies
  -- =============================================================================
  dependencies = {
    -- blink.cmp: Provides LSP capabilities for completion
    "saghen/blink.cmp",

    -- File operations: Rename/move files with LSP awareness
    { "antosha417/nvim-lsp-file-operations", config = true },

    -- Neovim Lua development: Improves Lua LSP understanding of vim API
    { "folke/neodev.nvim", opts = {} },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Store original floating preview function before wrapping
    local _orig_open_floating_preview = vim.lsp.util.open_floating_preview

    -- =============================================================================
    -- Utility Functions
    -- =============================================================================

    -- Clamps a numeric value between minimum and maximum bounds
    -- @param n (number): The value to clamp
    -- @param lo (number): Minimum allowed value
    -- @param hi (number): Maximum allowed value
    -- @returns (number): The clamped value
    local function clamp(n, lo, hi)
      if n < lo then
        return lo
      end
      if n > hi then
        return hi
      end
      return n
    end

    -- =============================================================================
    -- LSP Float Window Sizing Configuration
    -- =============================================================================
    -- Defines target sizes for LSP hover/signature help float windows

    local LSP_FLOAT_SIZE = {
      -- Size as fraction of editor dimensions
      width_frac = 0.50,   -- 50% of editor width
      height_frac = 0.30,  -- 30% of editor height

      -- Hard limits to prevent absurdly large/small windows
      min_width = 40,      -- Minimum width in columns
      min_height = 8,      -- Minimum height in lines
      max_width = 120,     -- Maximum width in columns
      max_height = 40,     -- Maximum height in lines
    }

    -- =============================================================================
    -- Float Window Size Enforcement
    -- =============================================================================
    -- Some LSP clients ignore max_width/max_height options.
    -- This function enforces size constraints after window creation.

    -- @param winid (number): The window ID to configure
    local function enforce_float_size(winid)
      -- Validate window exists
      if not (winid and vim.api.nvim_win_is_valid(winid)) then
        return
      end

      -- Get current window configuration
      local cfg = vim.api.nvim_win_get_config(winid)

      -- Only apply to floating windows (those with relative positioning)
      if not (cfg and cfg.relative and cfg.relative ~= "") then
        return
      end

      -- Calculate target dimensions based on editor size
      local editor_w = vim.o.columns
      local editor_h = vim.o.lines

      local target_w = math.floor(editor_w * LSP_FLOAT_SIZE.width_frac)
      local target_h = math.floor(editor_h * LSP_FLOAT_SIZE.height_frac)

      -- Apply min/max constraints
      target_w = clamp(target_w, LSP_FLOAT_SIZE.min_width, LSP_FLOAT_SIZE.max_width)
      target_h = clamp(target_h, LSP_FLOAT_SIZE.min_height, LSP_FLOAT_SIZE.max_height)

      -- Apply new dimensions to window config
      local new_cfg = vim.deepcopy(cfg)
      new_cfg.width = target_w
      new_cfg.height = target_h
      pcall(vim.api.nvim_win_set_config, winid, new_cfg)
    end

    -- =============================================================================
    -- Custom Floating Preview Wrapper
    -- =============================================================================
    -- Wraps vim.lsp.util.open_floating_preview to customize:
    -- - Border style (rounded)
    -- - Title text based on popup kind
    -- - Line numbers in float windows
    -- - Enforced sizing

    vim.lsp.util.open_floating_preview = function(contents, syntax, opts, ...)
      -- Default options
      opts = opts or {}

      -- Use rounded borders for all LSP floats
      opts.border = opts.border or "rounded"

      -- Set dynamic title based on popup purpose
      -- Titles help distinguish hover docs from signature help
      local kind = vim.b.lsp_popup_kind
      if kind == "signature" then
        opts.title = opts.title or "TY Function Parameter Popup"
      elseif kind == "hover" then
        opts.title = opts.title or "PY-LSP Function Documentation Preview"
      else
        opts.title = opts.title or "LSP Preview"
      end
      opts.title_pos = opts.title_pos or "left"

      -- Call original function to create the float
      local bufnr, winid = _orig_open_floating_preview(contents, syntax, opts, ...)

      -- Apply additional options to the created window
      if winid and vim.api.nvim_win_is_valid(winid) then
        -- Enable line numbers in float windows
        vim.wo[winid].number = true
        vim.wo[winid].relativenumber = true

        -- Enforce size constraints
        enforce_float_size(winid)
      end

      return bufnr, winid
    end

    -- =============================================================================
    -- LSP Capabilities Configuration
    -- =============================================================================
    -- On Neovim 0.11+, blink.cmp integration is mostly automatic.
    -- We still call get_lsp_capabilities() to ensure full feature support.

    -- Get base capabilities from Neovim
    local capabilities = vim.lsp.protocol.make_client_capabilities()

    -- Safely get blink.cmp capabilities and merge
    local ok, blink = pcall(require, "blink.cmp")
    if ok and blink.get_lsp_capabilities then
      local blink_caps = blink.get_lsp_capabilities()
      if type(blink_caps) == "table" then
        capabilities = vim.tbl_deep_extend("force", capabilities, blink_caps)
      end
    end

    -- Set default capabilities for all LSP servers
    vim.lsp.config("*", {
      capabilities = capabilities,
    })

    -- =============================================================================
    -- LSP Keybindings
    -- =============================================================================
    -- Define buffer-local keybindings when LSP attaches to a buffer

    local keymap = vim.keymap

    -- Create autocmd group for LSP configuration
    vim.api.nvim_create_autocmd("LspAttach", {
      group = vim.api.nvim_create_augroup("UserLspConfig", {}),
      callback = function(ev)
        -- Get the LSP client that attached
        local client = vim.lsp.get_client_by_id(ev.data.client_id)

        -- =============================================================================
        -- Python-specific Configuration
        -- =============================================================================
        -- Disable hover provider for non-pylsp LSPs in Python buffers
        -- This prevents duplicate hover popups from multiple LSP servers
        if client and vim.bo[ev.buf].filetype == "python" and client.name ~= "pylsp" then
          client.server_capabilities.hoverProvider = false
        end

        -- Default options for LSP keybindings
        local opts = { buffer = ev.buf, silent = true }

        -- =============================================================================
        -- Navigation Keybindings
        -- =============================================================================

        -- Go to references (uses fzf-lua for fuzzy results)
        opts.desc = "Show LSP references"
        keymap.set("n", "gR", function()
          require("fzf-lua").lsp_references()
        end, opts)

        -- Go to declaration (falls back to definition if not supported)
        opts.desc = "Go to declaration"
        keymap.set("n", "gD", function()
          -- Check if any attached client supports declaration
          local clients = vim.lsp.get_clients({ bufnr = 0 })
          for _, client in ipairs(clients) do
            if client.supports_method("textDocument/declaration") then
              vim.lsp.buf.declaration()
              return
            end
          end
          -- Fallback to definition (for LSPs like fortls that don't support declaration)
          require("fzf-lua").lsp_definitions()
        end, opts)

        -- Go to definition (uses fzf-lua for fuzzy results)
        opts.desc = "Go to definitions"
        keymap.set("n", "gd", function()
          require("fzf-lua").lsp_definitions()
        end, opts)

        -- Go to implementations (uses fzf-lua for fuzzy results)
        opts.desc = "Show implementations"
        keymap.set("n", "gi", function()
          require("fzf-lua").lsp_implementations()
        end, opts)

        -- Go to type definitions (uses fzf-lua for fuzzy results)
        opts.desc = "Show type definitions"
        keymap.set("n", "gt", function()
          require("fzf-lua").lsp_typedefs()
        end, opts)

        -- =============================================================================
        -- Code Action Keybindings
        -- =============================================================================

        -- Show and apply code actions (normal and visual mode)
        opts.desc = "See available code actions"
        keymap.set({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, opts)

        -- Rename symbol under cursor
        opts.desc = "Smart rename"
        keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)

        -- =============================================================================
        -- Diagnostic Keybindings
        -- =============================================================================

        -- Show all diagnostics in current buffer (fzf-lua)
        opts.desc = "Show buffer diagnostics"
        keymap.set("n", "<leader>D", function()
          require("fzf-lua").diagnostics_document()
        end, opts)

        -- Show diagnostics for current line (in floating window)
        opts.desc = "Show line diagnostics"
        keymap.set("n", "<leader>d", vim.diagnostic.open_float, opts)

        -- Navigate to previous diagnostic
        opts.desc = "Go to previous diagnostic"
        keymap.set("n", "[d", vim.diagnostic.goto_prev, opts)

        -- Navigate to next diagnostic
        opts.desc = "Go to next diagnostic"
        keymap.set("n", "]d", vim.diagnostic.goto_next, opts)

        -- =============================================================================
        -- Documentation Keybindings
        -- =============================================================================

        -- Show hover documentation (K key)
        -- For Fortran files, check custom docs first before falling back to LSP
        opts.desc = "Show documentation under cursor"
        keymap.set("n", "K", function()
          vim.b.lsp_popup_kind = "hover"

          -- Check for Fortran custom documentation
          local ft = vim.bo.filetype
          if ft == "fortran" or ft:match("^fortran") or ft == "f90" or ft == "f95" then
            local ok, fortran_docs = pcall(require, "andrew.fortran.docs")
            if ok then
              local word = vim.fn.expand("<cword>")
              local custom_doc = fortran_docs.get(word)
              if custom_doc then
                vim.lsp.util.open_floating_preview(
                  vim.split(custom_doc, "\n"),
                  "markdown",
                  { border = "rounded", focus = false }
                )
                return
              end
            end
          end

          -- Fall back to LSP hover
          vim.lsp.buf.hover()
        end, opts)

        -- Show signature help (Ctrl-k in normal and insert mode)
        -- Uses ty LSP for Python when available, falls back to default
        opts.desc = "Show signature help (ty only for Python)"
        keymap.set({ "n", "i" }, "<C-k>", function()
          local bufnr = vim.api.nvim_get_current_buf()

          -- For Python files, try to use ty LSP for signature help
          if vim.bo[bufnr].filetype == "python" then
            local clients = vim.lsp.get_clients({ bufnr = bufnr })
            local ty_client
            for _, c in ipairs(clients) do
              if c.name == "ty" then
                ty_client = c
                break
              end
            end

            -- Use ty if available
            if ty_client then
              vim.b.lsp_popup_kind = "signature"
              local params =
                vim.lsp.util.make_position_params(0, ty_client.offset_encoding or "utf-16")
              ty_client.request("textDocument/signatureHelp", params, function(err, result, ctx, _)
                if err then
                  vim.notify(
                    err.message or tostring(err),
                    vim.log.levels.ERROR,
                    { title = "LSP Signature Popup" }
                  )
                  return
                end
                vim.lsp.handlers["textDocument/signatureHelp"](err, result, ctx, _)
              end, bufnr)
              return
            end
          end

          -- Fallback: use default LSP signature help
          vim.b.lsp_popup_kind = "signature"
          vim.lsp.buf.signature_help()
        end, opts)

        -- =============================================================================
        -- LSP Management
        -- =============================================================================

        -- Restart LSP server
        opts.desc = "Restart LSP"
        keymap.set("n", "<leader>rs", "<cmd>LspRestart<CR>", opts)
      end,
    })

    -- =============================================================================
    -- Diagnostic Icons Configuration
    -- =============================================================================
    -- Define icons displayed in sign column for diagnostic severities

    local diagnostic_icons = {
      Error = "",   -- Red X for errors
      Warn = "",   -- Yellow triangle for warnings
      Hint = "",   -- Lightbulb for hints
      Info = "",   -- Blue circle for information
    }

    -- Configure diagnostic display
    vim.diagnostic.config({
      -- Sign column icons
      signs = {
        text = {
          [vim.diagnostic.severity.ERROR] = diagnostic_icons.Error,
          [vim.diagnostic.severity.WARN] = diagnostic_icons.Warn,
          [vim.diagnostic.severity.HINT] = diagnostic_icons.Hint,
          [vim.diagnostic.severity.INFO] = diagnostic_icons.Info,
        },
      },

      -- Show inline diagnostic messages
      virtual_text = true,

      -- Underline erroneous code
      underline = true,

      -- Don't update diagnostics while in insert mode (performance)
      update_in_insert = false,

      -- Sort diagnostics by severity (errors first)
      severity_sort = true,
    })

    -- =============================================================================
    -- LSP Server Configurations
    -- =============================================================================

    -- =============================================================================
    -- Lua Language Server (lua_ls)
    -- =============================================================================
    -- Used for Neovim configuration and Lua development
    -- Installed via conda: conda install -c conda-forge lua-language-server

    local lua_ls_cmd = {
      vim.fn.expand("$HOME/miniconda3/bin/lua-language-server"),
    }

    vim.lsp.config("lua_ls", {
      cmd = lua_ls_cmd,
      settings = {
        Lua = {
          -- Use LuaJIT runtime (Neovim's Lua runtime)
          runtime = { version = "LuaJIT" },

          -- Recognize 'vim' as a global variable
          diagnostics = {
            globals = { "vim" },
          },

          -- Configure workspace library paths
          workspace = {
            checkThirdParty = false,  -- Don't prompt about third party libraries
            library = vim.api.nvim_get_runtime_file("", true),  -- Load Neovim runtime files
          },

          -- Disable telemetry (privacy)
          telemetry = { enable = false },
        },
      },
    })

    -- =============================================================================
    -- Fortran Language Server (fortls)
    -- =============================================================================
    -- LSP for Fortran development
    -- Installed via conda: conda install -c conda-forge fortls
    -- Configured for workspace-wide diagnostics and completions

    -- Use absolute path to avoid issues when CONDA_PREFIX is not set
    local fortls_cmd = { vim.fn.expand("$HOME/miniconda3/bin/fortls") }

    vim.lsp.config("fortls", {
      cmd = fortls_cmd,
      capabilities = capabilities,
      -- Supported Fortran file types
      filetypes = { "fortran", "fortran_fixed", "fortran_free", "f90", "f95" },
      -- Root directory detection: look for .git, .fortls, or code/ directory
      -- Note: Makefile is inside code/, so we don't use it as a root marker
      root_markers = { ".git", ".fortls", "code" },
      init_options = {
        -- Hover and signature features (snake_case per fortls docs)
        hover_signature = true,        -- Show function signatures in hover

        -- Autocomplete settings (snake_case per fortls docs)
        autocomplete_no_prefix = true, -- Don't require prefix for autocomplete
        autocomplete_no_snippets = false, -- Use snippets with placeholders
        use_signature_help = true,     -- Use signature help for subroutines/functions
        lowercase_intrinsics = false,  -- Keep intrinsics uppercase

        -- Workspace scanning: configured per-project via .fortls file
        -- Create a .fortls JSON file in your project root to specify source_dirs/include_dirs
        -- Example .fortls: { "source_dirs": ["code"], "include_dirs": ["code"] }

        -- Preprocessor settings for .h include files
        pp_suffixes = { ".h" },        -- Treat .h files as preprocessor includes
        pp_defs = {},                  -- Preprocessor definitions (add if needed)

        -- Diagnostics settings
        disable_diagnostics = false,   -- Enable diagnostics
        enable_code_actions = true,    -- Enable code actions
        max_line_length = 132,         -- Standard Fortran free-form line length
        max_comment_line_length = 132, -- Comment line length limit

        -- Notify when workspace scan is complete
        notify_init = true,
        -- Use incremental sync for better performance
        incremental_sync = true,
      },
    })

    -- =============================================================================
    -- Pyright (Python LSP)
    -- =============================================================================
    -- Alternative Python LSP (currently disabled, pylsp is used instead)

    vim.lsp.config("pyright", {
      cmd = { vim.fn.expand("$HOME/miniconda3/bin/pyright-langserver"), "--stdio" },
      filetypes = { "python" },
      settings = {
        python = {
          analysis = {
            -- Only analyze open files (faster, less disk I/O)
            diagnosticMode = "openFilesOnly",

            -- Disable automatic path detection
            autoSearchPaths = false,

            -- Use library code for type information
            useLibraryCodeForTypes = true,
          },
        },
      },
    })

    -- =============================================================================
    -- Python LSP Server (pylsp)
    -- =============================================================================
    -- Python Language Server with Jedi-based completion
    -- Configured to avoid conflicts with Ruff linter

    vim.lsp.config("pylsp", {
      filetypes = { "python" },
      settings = {
        pylsp = {
          -- Disable linters (Ruff handles linting)
          plugins = {
            pyflakes = { enabled = false },
            pycodestyle = { enabled = false },
            pylint = { enabled = false },
            mccabe = { enabled = false },

            -- Enable completion features
            jedi_completion = { enabled = true },
            jedi_hover = { enabled = true },
            jedi_references = { enabled = true },
            jedi_signature_help = { enabled = true },

            -- Disable formatters (Ruff handles formatting)
            autopep8 = { enabled = false },
            yapf = { enabled = false },
            black = { enabled = false },
            isort = { enabled = false },
          },
        },
      },
    })

    -- =============================================================================
    -- Ctags LSP (for C header completions in Fortran)
    -- =============================================================================
    -- Provides completions from C header files for Fortran ISO_C_BINDING interop
    -- Install: go install github.com/netmute/ctags-lsp@latest
    -- Requires: universal-ctags (conda install -c conda-forge universal-ctags)

    vim.lsp.config("ctags_lsp", {
      cmd = { vim.fn.expand("$HOME/miniconda3/bin/ctags-lsp"), "--ctags-bin", vim.fn.expand("$HOME/miniconda3/bin/ctags") },
      capabilities = capabilities,
      filetypes = { "c", "cpp" },
      root_markers = { ".git", ".fortls", "code", "tags" },
    })

    -- =============================================================================
    -- Enable LSP Servers
    -- =============================================================================
    -- Activate the configured LSP servers for appropriate file types

    vim.lsp.enable("lua_ls")       -- Lua development
    vim.lsp.enable("fortls")       -- Fortran development
    vim.lsp.enable("pylsp")        -- Python development
    vim.lsp.enable("ctags_lsp")    -- C header completions via ctags
    -- Note: rust_analyzer is handled by rustaceanvim plugin

    -- =============================================================================
    -- Ctags LSP Commands
    -- =============================================================================
    vim.api.nvim_create_user_command("CtagsLspRestart", function()
      vim.lsp.stop_client(vim.lsp.get_clients({ name = "ctags_lsp" }))
      vim.defer_fn(function()
        vim.cmd("edit")  -- Reopen buffer to trigger LSP attach
        vim.notify("Ctags LSP restarted", vim.log.levels.INFO)
      end, 100)
    end, { desc = "Restart ctags LSP server" })

    vim.api.nvim_create_user_command("CtagsLspInfo", function()
      local clients = vim.lsp.get_clients({ name = "ctags_lsp" })
      if #clients > 0 then
        local client = clients[1]
        vim.notify(string.format(
          "Ctags LSP active\nRoot: %s\nPID: %s",
          client.config.root_dir or "unknown",
          client.rpc and client.rpc.pid or "unknown"
        ), vim.log.levels.INFO)
      else
        vim.notify("Ctags LSP not running", vim.log.levels.WARN)
      end
    end, { desc = "Show ctags LSP info" })

    -- Initialize Fortran custom syntax highlighting
    require("andrew.fortran").setup()

  end,
}
