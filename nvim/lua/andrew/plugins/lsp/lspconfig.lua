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

  -- Load only for filetypes that have a configured/native LSP server. No client
  -- attaches to markdown/text, so those buffers must not pull lspconfig in.
  -- (ft, NOT event — lazy.nvim ORs the two, so keeping event yields zero savings.)
  ft = require("andrew.lsp_filetypes"),

  -- =============================================================================
  -- Plugin Dependencies
  -- =============================================================================
  dependencies = {
    -- blink.cmp: Provides LSP capabilities for completion
    "saghen/blink.cmp",

    -- File operations: Rename/move files with LSP awareness
    { "antosha417/nvim-lsp-file-operations", config = true },

    -- Neovim Lua development: Faster LuaLS setup with lazy workspace libraries
    {
      "folke/lazydev.nvim",
      ft = "lua",
      opts = {
        library = {
          -- Load luvit types when vim.uv is referenced
          { path = "${3rd}/luv/library", words = { "vim%.uv" } },
        },
      },
    },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- =============================================================================
    -- LSP Float Presentation
    -- =============================================================================
    -- Border, title, line numbers, wrap and the size CAP all live in
    -- andrew.lsp_float. They used to be ~75 lines of local functions right here,
    -- inside this `config` closure, which meant no spec could reach them and two
    -- visible defects (floats SET to a fixed size instead of capped; every float
    -- titled "PY-LSP ...") survived unnoticed. The module is at the
    -- andrew.lsp_float level, NOT under plugins/, because lazy.lua imports every
    -- file under andrew/plugins/lsp as a plugin spec.
    require("andrew.lsp_float").setup()

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

    -- nvim-lsp-file-operations advertises workspace.fileOperations, which is
    -- what <leader>cR (Rename File) is gated on. It installs itself by patching
    -- `lspconfig.util.default_config` -- a path this config never takes, since
    -- servers are configured with vim.lsp.config("*") below. Loading the plugin
    -- is therefore NOT enough: without this merge every fileOperations flag
    -- stays false and the keymap can never bind, in any buffer, in any
    -- language. Verified by an empirical keymap diff, 2026-09-06.
    local ok_fo, file_ops = pcall(require, "lsp-file-operations")
    if ok_fo and type(file_ops.default_capabilities) == "function" then
      capabilities = vim.tbl_deep_extend("force", capabilities, file_ops.default_capabilities())
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
    -- =============================================================================
    -- Neovim's built-in LSP keymaps (nvim 0.12 defaults)
    -- =============================================================================
    -- 0.12 sets grn/gra/grx/grr/gri/grt and gO unconditionally at startup, NOT
    -- on LspAttach (runtime lua/vim/_core/defaults.lua:203-235). We bind `gr`
    -- itself to References, so leaving the gr* defaults in place would make
    -- every `gr` press wait out timeoutlen (500ms here) to see whether an n/a/
    -- x/r/i/t follows. Every one of them has a replacement in the gated key
    -- list (gr, <leader>cr, <leader>ca, <leader>cc, gI, gy), so they go.
    -- gO (document symbols) and <C-S> (signature help) do not collide and stay.
    for _, lhs in ipairs({ "grn", "gra", "grx", "grr", "gri", "grt" }) do
      pcall(vim.keymap.del, "n", lhs)
    end
    pcall(vim.keymap.del, "x", "gra")

    -- Create autocmd group for LSP configuration
    vim.api.nvim_create_autocmd("LspAttach", {
      group = vim.api.nvim_create_augroup("UserLspConfig", {}),
      callback = function(ev)
        -- Get the LSP client that attached
        local client = vim.lsp.get_client_by_id(ev.data.client_id)

        -- =============================================================================
        -- Python-specific Configuration
        -- =============================================================================
        -- In a PYTHON buffer only, delete hoverProvider from every client that
        -- is not pylsp, so exactly one server answers K and there is no
        -- multi-client float.
        --
        -- Be clear about the cost: this is why basedpyright is unusable for
        -- documentation in this config. basedpyright attaches, indexes, and
        -- produces the best hover text of any server here (typed signature,
        -- rendered docstring, parameter table) -- and then this line deletes
        -- its hoverProvider, so K never reaches it. Capturing basedpyright's
        -- hover on 2026-09-13 required restoring the capability at runtime
        -- first. Neovim 0.12 already concatenates multi-client hovers under a
        -- `# <client>` heading per server, which is the correct cost of two
        -- good answers; silently deleting a provider is not.
        --
        -- It is scoped to `filetype == "python"` deliberately and must STAY
        -- scoped there. The Fortran servers (fortls + the in-process
        -- fortran-extras) must never be subjected to it: the Fortran design
        -- resolves the same overlap by having fortran-extras RETURN NULL
        -- wherever fortls would answer, which is decided per request rather
        -- than by amputating a capability for the whole session.
        if client and vim.bo[ev.buf].filetype == "python" and client.name ~= "pylsp" then
          client.server_capabilities.hoverProvider = false
        end

        -- =============================================================================
        -- Capability-gated keymaps (LazyVim layout)
        -- =============================================================================
        -- Navigation, code actions, codelens, rename, symbols, call hierarchy
        -- and reference jumps all live in andrew.lsp_keymaps, where each key
        -- carries the LSP method it needs and is only bound when an attached
        -- client advertises it. LspAttach fires once per client, so a second
        -- server attaching adds whatever its capabilities unlock.
        require("andrew.lsp_keymaps").on_attach(ev.buf)

        -- Default options for the buffer-local keymaps kept below
        local opts = { buffer = ev.buf, silent = true }

        -- =============================================================================
        -- Diagnostic Keybindings
        -- =============================================================================
        -- <leader>cd and the ]d/[d/]e/[e/]w/[w motions are global and live in
        -- core/keymaps.lua (LazyVim keeps them in config/keymaps.lua too) --
        -- vim.diagnostic works without an LSP client, so gating them on
        -- LspAttach only made them unavailable where they still do something.

        -- Show all diagnostics in current buffer (fzf-lua). No LazyVim
        -- counterpart -- it routes buffer diagnostics through Trouble instead.
        opts.desc = "Show buffer diagnostics"
        keymap.set("n", "<leader>D", function()
          require("fzf-lua").diagnostics_document()
        end, opts)

        -- Open the rule documentation for the diagnostic under the cursor.
        --
        -- Servers that bother to publish a `codeDescription.href` (basedpyright
        -- sends one on EVERY item -- the exact anchor for the rule, e.g.
        -- .../configuration/config-files/#reportUnusedImport) hand Neovim a
        -- link it otherwise never surfaces: virtual text drops it, and even
        -- with the `format` below the float can only print it as inert text.
        -- This is the key that actually follows it.
        opts.desc = "Open diagnostic docs"
        keymap.set("n", "<leader>cH", function()
          local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
          for _, d in ipairs(vim.diagnostic.get(0, { lnum = lnum })) do
            local href = vim.tbl_get(d, "user_data", "lsp", "codeDescription", "href")
            if href then
              vim.ui.open(href)
              return
            end
          end
          vim.notify("No diagnostic documentation here", vim.log.levels.INFO)
        end, opts)

        -- =============================================================================
        -- Documentation Keybindings
        -- =============================================================================

        -- Show hover documentation (K key)
        --
        -- Plain vim.lsp.buf.hover() for EVERY filetype, Fortran included. The
        -- Fortran branch that used to live here read snippets/fortran-docs.json
        -- itself and opened its own float; the fortran-extras server now answers
        -- textDocument/hover from the same registry (andrew.fortran.lsp_hover),
        -- so nvim's own hover carries the whole feature -- and with it four
        -- things the hand-rolled float could not have:
        --
        --   * focus_id (buf.lua:79). The old float was opened `focus = false`
        --     with no id, so a 150-line intrinsic doc was shown in ~18 rows with
        --     no way to enter or scroll it. Pressing K twice now moves INTO the
        --     float.
        --   * the hover range highlight (buf.lua:167-178), which the custom path
        --     never had because it never had a range to highlight.
        --   * the correct "No information available" message instead of an error
        --     notification when no client answers.
        --   * the answer rule as a testable function rather than a keymap
        --     closure: tests/fortran_lsp_hover_spec.lua. That rule is also what
        --     fixes the JSON shadowing bug -- K on the user's own variable named
        --     `dp`, `mat` or `count` used to show a snippet's documentation,
        --     because those are keys in fortran-docs.json.
        --
        -- The `omp.best_key` + `andrew.fortran.docs` requires that used to be
        -- here are gone with it; directive lines are answered by
        -- registry.directive() inside the server.
        opts.desc = "Show documentation under cursor"
        keymap.set("n", "K", function()
          vim.b.lsp_popup_kind = "hover"
          vim.lsp.buf.hover()
        end, opts)

        -- Show signature help (Ctrl-k in INSERT mode only).
        -- Uses ty LSP for Python when available, falls back to default.
        -- gK is the same thing under LazyVim's spelling and is bound (gated on
        -- signatureHelp) in andrew.lsp_keymaps; this one stays ungated because it
        -- also carries the Python/ty branch.
        --
        -- Normal mode is deliberately NOT bound: a buffer-local n_<C-k> shadowed
        -- vim-tmux-navigator's global <C-k> (move to the window/pane above) in
        -- every LSP buffer, and normal-mode signature help is already covered by
        -- gK and <C-S>.
        --
        -- KEY OWNERSHIP: blink.cmp also wants insert-mode <C-k> (its `default`
        -- preset maps it to show_signature, and this config used to map it to
        -- scroll_documentation_up). blink applies its buffer-local maps on
        -- InsertEnter, i.e. AFTER LspAttach, so it silently won and this map was
        -- dead. plugins/blink-cmp.lua now sets `["<C-k>"] = false` to leave the
        -- key to us; blink's documentation scrolling is on <C-b>/<C-j> there.
        opts.desc = "Show signature help (ty only for Python)"
        keymap.set("i", "<C-k>", function()
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
              -- Neovim 0.11+ vim.lsp.buf.signature_help handles the full round-trip
              vim.lsp.buf.signature_help()
              return
            end
          end

          -- Fallback: use default LSP signature help
          vim.b.lsp_popup_kind = "signature"
          vim.lsp.buf.signature_help()
        end, opts)

        -- =============================================================================
        -- LSP Group (<leader>l)
        -- =============================================================================
        -- Symbols moved to <leader>ss / <leader>sS (aliased at <leader>cs /
        -- <leader>cS) and LSP info to <leader>cl, all in andrew.lsp_keymaps.
        -- The old Trouble LSP views are gone -- both symbol keys use the
        -- fzf-lua pickers now; Trouble still owns <leader>x. What is left here
        -- has no LazyVim counterpart to match.

        -- Restart LSP server (native :lsp command, nvim 0.12+)
        opts.desc = "Restart LSP"
        keymap.set("n", "<leader>lr", "<cmd>lsp restart<CR>", opts)

        -- Toggle inlay hints (buffer-local).
        -- NOTE this duplicates <leader>uh (Snacks.toggle.inlay_hints, which is
        -- the LazyVim spelling) -- kept because it was here first.
        opts.desc = "Toggle inlay hints"
        keymap.set("n", "<leader>lh", function()
          vim.lsp.inlay_hint.enable(
            not vim.lsp.inlay_hint.is_enabled({ bufnr = ev.buf }),
            { bufnr = ev.buf }
          )
        end, opts)
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

      -- Show inline diagnostic messages.
      --
      -- The suffix exists because virtual text drops the rule name. A
      -- basedpyright warning reads "Import \"json\" is not accessed" inline,
      -- with `code = "reportUnusedImport"` sitting unused in the item -- and
      -- the code is the half you need to silence, configure or look the rule
      -- up. open_float already appends " [code]" by default (vim/diagnostic.lua,
      -- inside M.open_float); this gives virtual text the same.
      virtual_text = {
        suffix = function(d)
          return d.code and (" [" .. tostring(d.code) .. "]") or ""
        end,
      },

      -- The diagnostic float additionally shows which server said it, and the
      -- rule's documentation URL when the server published one. `format` is the
      -- only hook that can reach `codeDescription.href`: nvim parks it under
      -- user_data.lsp and renders it nowhere. <leader>cH (LspAttach block
      -- above) opens the same href.
      float = {
        source = true,
        format = function(d)
          local href = vim.tbl_get(d, "user_data", "lsp", "codeDescription", "href")
          return href and (d.message .. "\n" .. href) or d.message
        end,
      },

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
    -- Server binary resolution
    -- =============================================================================
    -- Server commands used to be hardcoded to $HOME/miniconda3/bin. That path is
    -- not stable: lua-language-server had already vanished from the conda env,
    -- so lua_ls silently never attached -- nvim spawns the missing binary, the
    -- client dies, and nothing is reported unless you read :LspLog. Mason had
    -- the very same server installed the whole time.
    --
    -- Resolve instead, mason first (it is what ensure_installed actually
    -- populates), then $PATH, then the old conda location as a last resort.
    -- Servers whose binary resolves nowhere are NOT enabled, and say so once,
    -- rather than failing invisibly.
    local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/"

    ---@param candidates string[]
    ---@return string|nil
    local function first_executable(candidates)
      for _, path in ipairs(candidates) do
        if path and path ~= "" and vim.fn.executable(path) == 1 then
          return path
        end
      end
      return nil
    end

    --- Candidate list for a server binary: mason, then PATH, then conda.
    ---@param name string
    ---@return string|nil
    local function resolve_bin(name)
      return first_executable({
        mason_bin .. name,
        vim.fn.exepath(name),
        vim.fn.expand("$HOME/miniconda3/bin/" .. name),
      })
    end

    -- =============================================================================
    -- Lua Language Server (lua_ls)
    -- =============================================================================
    -- Used for Neovim configuration and Lua development.
    -- Provided by mason (`lua_ls` is in mason.lua's ensure_installed).

    local lua_ls_bin = resolve_bin("lua-language-server")

    vim.lsp.config("lua_ls", {
      -- nil leaves lspconfig's own default cmd in place; the enable guard
      -- below stops us starting a server we could not find.
      cmd = lua_ls_bin and { lua_ls_bin } or nil,
      settings = {
        Lua = {
          -- Use LuaJIT runtime (Neovim's Lua runtime)
          runtime = { version = "LuaJIT" },

          -- Recognize 'vim' as a global variable
          diagnostics = {
            globals = { "vim" },
          },

          -- Configure workspace library paths.
          --
          -- `library` is deliberately NOT set here. It used to be
          -- vim.api.nvim_get_runtime_file("", true), which handed lua_ls every
          -- runtime directory to index (~4586 files) -- hover returned
          -- "Workspace loading" for roughly 30 seconds after opening any Lua
          -- buffer. lazydev.nvim (a dependency of this spec, configured with
          -- `opts` above so its setup actually runs) supplies the same
          -- libraries lazily, only for the modules a file really references.
          workspace = {
            checkThirdParty = false,  -- Don't prompt about third party libraries
          },

          -- Inlay hints. lua_ls emits none unless this is set, which made
          -- <leader>uh a no-op in Lua buffers -- rust_analyzer was the only
          -- server in this config actually producing hints. Values match
          -- LazyVim's lua_ls extra; hints stay OFF until the toggle turns
          -- them on (nothing calls vim.lsp.inlay_hint.enable at startup).
          hint = {
            enable = true,
            setType = false,
            paramType = true,
            paramName = "Disable",
            semicolon = "Disable",
            arrayIndex = "Disable",
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

    -- fortls IGNORES initializationOptions entirely (fortls 3.2.2:
    -- langserver.py never reads them -- every option below used to sit in an
    -- init_options table and was silently discarded, including
    -- enable_code_actions, which is why the server advertised no
    -- codeActionProvider and <leader>ca was a dead key in Fortran buffers).
    -- It is configured by CLI flags and by a per-project .fortls JSON file, so
    -- the options move onto the command line.
    --
    -- Only non-default values need a flag: the store_true flags cannot express
    -- "false", so autocomplete_no_snippets / disable_diagnostics (both false)
    -- and pp_defs ({}) are simply omitted -- omitting them IS setting them
    -- false. lowercase_intrinsics used to be omitted for the same reason and is
    -- now passed deliberately; see below.
    local fortls_bin = resolve_bin("fortls")

    local fortls_cmd = {
      fortls_bin or "fortls",
      -- MUST come first and MUST stay: fortls 3.2.2's serve_initialize() calls
      -- _update_version_pypi(), a BLOCKING urlopen to pypi.org, before
      -- workspace_init. On a machine that cannot reach pypi (offline, proxied,
      -- firewalled) that call never completes, so `initialize` never returns
      -- and the client sits in (pending) forever -- no completions, no hover,
      -- no diagnostics. It also stops fortls installing new versions of itself.
      "--disable_autoupdate",
      "--hover_signature",              -- Show function signatures in hover
      "--autocomplete_no_prefix",       -- Don't filter completions by prefix
      "--use_signature_help",           -- Signature help for subroutines/functions
      "--enable_code_actions",          -- Advertise codeActionProvider (experimental upstream)
      "--incremental_sync",             -- Incremental document sync
      "--notify_init",                  -- Notify when the workspace scan completes
      "--max_line_length", "132",       -- Standard Fortran free-form line length
      "--max_comment_line_length", "132",
      "--pp_suffixes", ".h",            -- Treat .h as preprocessor includes
      -- Not cosmetic: it is completion-list dedupe. With
      -- --autocomplete_no_prefix above, fortls returns ALL 49 intrinsics on
      -- every completion request regardless of what has been typed, and it
      -- returns them in BOTH cases -- `size` and `SIZE` are two separate items.
      -- blink.cmp concatenates the item lists of every attached client with no
      -- dedupe at all (blink.cmp sources/lsp/init.lua), so those pairs both
      -- survive into the menu and the user picks between two identical entries
      -- 49 times. Lowercasing collapses each pair to one.
      "--lowercase_intrinsics",
    }

    -- Point fortls at whatever supplies mpif.h. This project includes it in
    -- 229 files and it ships with the MPI installation, so without this the
    -- server resolves none of it.
    --
    -- Done as a CLI flag rather than a .fortls file on purpose: fortls 3.2.2
    -- does expose `--include_dirs`, and a .fortls would mean writing config
    -- into the user's research tree, which this repo has no business doing.
    -- Keep expectations low -- the earlier capability audit found
    -- `--incl_suffixes .h` resolved only 4 of 192 names -- but mpif.h is a
    -- flat list of PARAMETERs, which is the shape fortls handles best.
    do
      local ok_mpi, mpi = pcall(require, "andrew.fortran.mpi")
      if ok_mpi then
        local dirs = mpi.include_dirs()
        if #dirs > 0 then
          table.insert(fortls_cmd, "--include_dirs")
          for _, d in ipairs(dirs) do
            table.insert(fortls_cmd, d)
          end
        end
      end
    end

    vim.lsp.config("fortls", {
      cmd = fortls_cmd,
      capabilities = capabilities,
      -- Supported Fortran file types
      filetypes = { "fortran", "fortran_fixed", "fortran_free", "f90", "f95" },
      -- Root directory detection: look for .git, .fortls, or code/ directory
      -- Note: Makefile is inside code/, so we don't use it as a root marker
      root_markers = { ".git", ".fortls", "code" },
      -- Workspace scanning stays per-project: create a .fortls JSON file in the
      -- project root for source_dirs/include_dirs, e.g.
      --   { "source_dirs": ["code"], "include_dirs": ["code"] }
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
    -- Ctags LSP
    -- =============================================================================
    -- universal-ctags wrapped in an LSP: completion, go-to-definition and
    -- document symbols from a flat ctags index. No types, no diagnostics, and
    -- (see the filetypes note below) no cross-file results.
    -- Install: :MasonInstall ctags-lsp   (prebuilt release binary, no Go needed)
    -- Requires: universal-ctags (conda install -c conda-forge universal-ctags)

    local ctags_lsp_bin = resolve_bin("ctags-lsp")

    local ctags_bin = resolve_bin("ctags")


    vim.lsp.config("ctags_lsp", {
      -- Resolved rather than hardcoded: mason installs it to
      -- ~/.local/share/nvim/mason/bin/ctags-lsp, which is where it is on this
      -- machine, but the guard below still leaves the server disabled rather
      -- than spawning a missing binary on every C/C++ buffer elsewhere.
      cmd = ctags_lsp_bin
          and { ctags_lsp_bin, "--ctags-bin", ctags_bin or "ctags" }
          or nil,
      capabilities = capabilities,
      -- C/C++ ONLY. Do not add Fortran here.
      --
      -- Fortran was tried on 2026-09-06 and reverted the same day. Two measured
      -- reasons, both against ctags-lsp v0.11.0:
      --
      -- 1. It cannot do the job the old comment on this block claimed ("C header
      --    completions for Fortran ISO_C_BINDING interop"). It scopes results to
      --    tags from the CURRENT FILE. On a project holding code/mylib.h +
      --    code/interop.f90 with a tags file covering both, completing "inter"
      --    inside interop.f90 returns `interop` (defined in that file) while
      --    completing "my_" returns NOTHING, though my_compute_total is in that
      --    same tags file. workspace/symbol returns 0 in every configuration
      --    tried, with and without --tagfile. Cross-file results are not a
      --    feature of this server.
      --
      -- 2. Everything it DID contribute to a Fortran buffer duplicated fortls.
      --    Both answered textDocument/documentSymbol with the same three names,
      --    so <leader>ss / <leader>cs listed every subroutine TWICE, and it
      --    added a duplicate completion item on top of fortls's own.
      --
      -- For real interop completion, open the C headers in their own buffers
      -- (where this server does work), or use clangd with a compile database.
      filetypes = { "c", "cpp" },
      root_markers = { ".git", ".fortls", "code", "tags" },
    })

    -- =============================================================================
    -- Enable LSP Servers
    -- =============================================================================
    -- Activate the configured LSP servers for appropriate file types

    -- Servers with an explicit cmd are only enabled when that binary actually
    -- resolved. Enabling one that did not is the failure mode this replaces:
    -- nvim spawns it, the client dies immediately, and the only trace is
    -- :LspLog. pylsp has no explicit cmd, so lspconfig resolves it from $PATH
    -- (mason prepends its bin dir) and it needs no guard.
    local missing = {}

    ---@param server string
    ---@param bin string|nil
    ---@param label string
    local function enable_if(server, bin, label)
      if bin then
        vim.lsp.enable(server)
      else
        missing[#missing + 1] = label
      end
    end

    enable_if("lua_ls", lua_ls_bin, "lua-language-server (:MasonInstall lua-language-server)")
    -- fortls has an explicit cmd (the flag list above), so it belongs under the
    -- same guard as lua_ls/ctags_lsp. It used to be enabled unconditionally,
    -- which is precisely the invisible failure this block exists to stop: with
    -- no fortls installed nvim spawned "fortls", the client died, and every
    -- Fortran buffer opened with no diagnostics and no explanation.
    enable_if("fortls", fortls_bin, "fortls (conda install -c conda-forge fortls)")
    vim.lsp.enable("pylsp")        -- Python development (resolved from $PATH)
    enable_if("ctags_lsp", ctags_lsp_bin, "ctags-lsp (go install github.com/netmute/ctags-lsp@latest)")
    -- Note: rust_analyzer is handled by rustaceanvim plugin

    if #missing > 0 then
      vim.schedule(function()
        vim.notify(
          "LSP: server binary not found, left disabled:\n  " .. table.concat(missing, "\n  "),
          vim.log.levels.WARN
        )
      end)
    end

    -- =============================================================================
    -- Ctags LSP Commands
    -- =============================================================================
    vim.api.nvim_create_user_command("CtagsLspRestart", function()
      for _, client in ipairs(vim.lsp.get_clients({ name = "ctags_lsp" })) do
        client:stop()
      end
      vim.defer_fn(function()
        vim.cmd("edit")  -- Reopen buffer to trigger LSP attach
        vim.notify("Ctags LSP restarted", vim.log.levels.INFO)
      end, 100)
    end, { desc = "Restart ctags LSP server" })

    vim.api.nvim_create_user_command("CtagsLspInfo", function()
      local clients = vim.lsp.get_clients({ name = "ctags_lsp" })
      if #clients > 0 then
        local client = clients[1]
        -- NOT the OS pid: vim.lsp.rpc.PublicClient exposes only
        -- request/notify/is_closing/terminate on nvim 0.12.5 (runtime
        -- lua/vim/lsp/rpc.lua:515-528), so the old `client.rpc.pid` was always
        -- nil and this command could ONLY ever print "PID: unknown". Report the
        -- two facts that are actually observable instead.
        local closing = client.rpc and client.rpc.is_closing and client.rpc.is_closing()
        vim.notify(string.format(
          "Ctags LSP active\nRoot: %s\nClient id: %d\nRPC: %s",
          client.config.root_dir or "unknown",
          client.id,
          closing and "closing" or "open"
        ), vim.log.levels.INFO)
      else
        vim.notify("Ctags LSP not running", vim.log.levels.WARN)
      end
    end, { desc = "Show ctags LSP info" })

    -- Initialize Fortran custom syntax highlighting
    require("andrew.fortran").setup()

  end,
}
