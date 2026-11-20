# AGENTS.md

This is a Neovim configuration repository targeting **Neovim 0.11+**. Agents should primarily work with Lua files in `lua/andrew/`.

## Project Structure

```
~/.config/nvim/
├── init.lua                         # Entry point (sets conda PATH, loads modules)
├── lazy-lock.json                   # Plugin lock file (auto-managed)
├── .stylua.toml                     # Lua formatter config
├── snippets/                        # Custom code snippets (LuaSnip)
│   └── extract-docs.lua
└── lua/andrew/
    ├── lazy.lua                     # Plugin manager setup (lazy.nvim bootstrap)
    ├── core/
    │   ├── init.lua                 # Loads options and keymaps
    │   ├── options.lua              # Neovim options (vim.opt settings)
    │   └── keymaps.lua              # Global keybindings (leader = Space)
    ├── plugins/
    │   ├── init.lua                 # Master plugin spec list
    │   ├── autopairs.lua            # Auto-close brackets (nvim-autopairs)
    │   ├── blink-cmp.lua            # Completion engine (blink.cmp)
    │   ├── codediff.lua             # Diff review tab + file history (codediff.nvim)
    │   ├── colorizer.lua            # Color code highlighting (nvim-colorizer)
    │   ├── colorscheme.lua          # OneDarkPro theme
    │   ├── comment.lua              # Commenting (Comment.nvim)
    │   ├── fortran-build.lua        # Makefile integration for Fortran
    │   ├── fzf-lua.lua              # Fuzzy finder (fzf-lua)
    │   ├── git.lua                  # <leader>g git commands (snacks.nvim fragment; the pickers are fzf-lua)
    │   ├── gitsigns.lua             # Git change indicators + <leader>gh hunks
    │   ├── indent-blankline.lua     # Indentation guides
    │   ├── incline.lua              # Window labels: icon + file name at each split's top-right (incline.nvim)
    │   ├── kitty-scrollback.lua     # Kitty scrollback viewer / copy mode (kitty-scrollback.nvim)
    │   ├── mini-diff.lua           # Diff overlay + gh/gH hunk operators (mini.diff)
    │   ├── linting.lua              # Multi-language linting (nvim-lint)
    │   ├── lualine.lua              # Status line (lualine.nvim); also shows 'showcmd' keys and "recording @q"
    │   ├── luasnip.lua              # Snippet engine (LuaSnip + friendly-snippets)
    │   ├── md-render.lua            # Second markdown renderer, on trial (md-render.nvim) + its auto-mode adapter
    │   ├── noice.lua                # Floating `:` cmdline + message box at the bottom-right (noice.nvim)
    │   ├── render-markdown.lua      # In-buffer markdown rendering
    │   ├── rustaceanvim.lua         # Enhanced Rust development
    │   ├── snacks.lua              # snacks.nvim: start screen (dashboard), vim.ui.input/select, image, toggles, scroll; picker colours via utils/snacks_look.lua
    │   ├── substitute.lua           # Motion-based replace
    │   ├── surround.lua             # Manage surrounding pairs
    │   ├── todo-comments.lua        # TODO/FIXME highlights
    │   ├── treesitter.lua           # Syntax highlighting (nvim-treesitter)
    │   ├── trouble.lua              # Diagnostics viewer (trouble.nvim)
    │   ├── ts-autotag.lua           # Auto-close markup tags (nvim-ts-autotag) -- markup filetypes only
    │   ├── type-checker.lua         # Per-language type checking
    │   ├── vim-maximizer.lua        # Maximize splits
    │   ├── vim-table-mode.lua       # Markdown table formatting
    │   ├── which-key.lua            # Keybinding hints
    │   ├── yazi.lua                 # File explorer (yazi.nvim)
    │   ├── dap/
    │   │   ├── dap.lua              # Debug Adapter Protocol (nvim-dap)
    │   │   └── dap-ui.lua           # Debug UI (nvim-dap-ui)
    │   ├── formatting/
    │   │   └── conform.lua          # Code formatter (conform.nvim)
    │   ├── lsp/
    │   │   ├── mason.lua            # LSP/tool installer (mason.nvim)
    │   │   └── lspconfig.lua        # LSP server configuration
    │   └── ui/
    │       └── devicons.lua         # File type icons
    ├── custom/
    │   └── plugins/
    │       └── terminal.lua         # Custom floating terminal (290 lines)
    ├── fortran/
    │   ├── init.lua                 # Fortran setup entry (FileType autocmd)
    │   ├── highlight.lua            # Custom syntax highlighting
    │   ├── lsp.lua                  # In-process LSP server (fortran-extras)
    │   ├── registry.lua             # The MPI/OpenMP/keyword documentation registry
    │   ├── lsp_completion.lua       # textDocument/completion + completionItem/resolve
    │   └── docs.lua                 # Custom hover documentation
    └── vault/
        ├── init.lua                 # Obsidian-like note template system
        ├── engine.lua               # Core template engine
        ├── pickers.lua              # UI selection pickers
        ├── query/                   # Query DSL for searching notes
        │   ├── init.lua
        │   ├── api.lua
        │   ├── executor.lua
        │   ├── index.lua
        │   ├── parser.lua
        │   ├── js2lua.lua
        │   ├── render.lua
        │   └── types.lua
        └── templates/               # 20+ note templates
            ├── init.lua
            ├── daily_log.lua
            ├── weekly_review.lua
            ├── task.lua
            ├── analysis.lua
            ├── meeting.lua
            ├── journal.lua
            ├── concept.lua
            ├── simulation.lua
            ├── finding.lua
            ├── literature.lua
            ├── project_dashboard.lua
            ├── area_dashboard.lua
            ├── domain_moc.lua
            ├── person.lua
            ├── asset.lua
            ├── changelog.lua
            ├── draft.lua
            ├── financial_snapshot.lua
            ├── methodology.lua
            ├── presentation.lua
            └── recurring_task.lua
```

## Load Order

The entry point `init.lua` loads modules in this exact order:

1. **Conda PATH** - Prepends `$HOME/miniconda3/bin` to PATH
2. **`andrew.core`** - Options (`vim.opt`) and global keymaps
3. **`andrew.lazy`** - Bootstraps lazy.nvim, imports `andrew.plugins` and `andrew.plugins.lsp`
4. **`andrew.custom.plugins.terminal`** - Floating terminal (loaded as regular module, not a lazy.nvim spec)
5. **`andrew.vault`** - Note template system
6. **`vim.opt.termguicolors = true`** - True color support

## Build/Lint/Test Commands

### Formatting

**Auto-format on save** is enabled for configured file types via conform.nvim. Files are formatted on `BufWritePre`:

| Filetype | Formatter | Source |
|----------|-----------|--------|
| Lua | `stylua` | Conda |
| Python | `ruff_format` | Conda |
| Fortran | `fprettify` | Conda |
| JS/TS/Vue/HTML/CSS/SCSS/JSON/YAML/Markdown | `prettier` | Conda |
| Rust | `rustfmt` | Via rustaceanvim (not conform) |

**Manual formatting:**

```vim
:lua require("conform").format()
```

### Linting

**Auto-lint** triggers on `FileType` (i.e. when a buffer is opened), `BufWritePost` and `InsertLeave`, once per event. Fortran skips `InsertLeave`: its linter is a compiler run on the file on disk, so only an open or a save can report anything new. Pinned by `tests/lint_missing_binary_spec.lua`.

**Linters by filetype:**

| Filetype | Linter | Notes |
|----------|--------|-------|
| Python | `ruff` | Conda binary with extended rules |
| JS/TS/Vue | `eslint` | Unix format output |
| C/C++ | `cppcheck` | Static analysis |
| Fortran | gfortran/ifort/ifx/mpiifx/nagfor | Configurable compiler (see below) |

**Fortran compiler linting** is configurable at runtime:

```lua
-- Set in init.lua or at runtime
vim.g.fortran_linter_compiler = "gfortran"  -- gfortran|ifort|ifx|mpiifx|nagfor|Disabled
vim.g.fortran_linter_compiler_path = nil    -- Custom compiler path (optional)
vim.g.fortran_linter_include_paths = {}     -- Include dirs (supports globs, ${workspaceFolder})
vim.g.fortran_linter_extra_args = {}        -- Additional compiler flags
```

**Linting keymaps:**

| Keymap | Action |
|--------|--------|
| `<leader>Ll` | Lint current buffer |
| `<leader>Lm` | Run ruff only (Python) |
| `<leader>Lf` | Toggle Fortran compiler |
| `<leader>LF` | Run Fortran linter (debug verbose) |
| `<leader>Lw` | Lint entire Fortran workspace |
| `<leader>LW` | Clear workspace diagnostics |
| `<leader>Lc` | Check Fortran capitalization |
| `<leader>LC` | Fix Fortran capitalization (buffer) |
| `<leader>Lt` | Toggle the capitalization check |

**Fortran commands:**

- `:FortranLinter <compiler>` - Change compiler at runtime
- `:FortranAddInclude <path>` - Add include path dynamically
- `:FortranLinterInfo` - Show current linting configuration

### LSP

**LSP servers configured (via `vim.lsp.config()` / `vim.lsp.enable()`):**

| Server | Language | Installation | Notes |
|--------|----------|--------------|-------|
| `lua_ls` | Lua | Conda | Vim API aware, Neovim runtime files |
| `pylsp` | Python | Mason | Jedi completion; pyflakes/pycodestyle/pylint disabled |
| `fortls` | Fortran | Conda | Hover signatures, workspace scanning, max 132 cols |
| `ctags_lsp` | C/C++ | Conda | C header completions for Fortran ISO_C_BINDING |
| `rust_analyzer` | Rust | rustaceanvim | Clippy on save, inlay hints, proc macros |

**LSP keybindings.** Layout matches LazyVim v16. Most are declared in
`lua/andrew/lsp_keymaps.lua` and bound buffer-locally via `LspAttach` ONLY when
an attached client advertises the matching LSP method (`has = "..."`, LazyVim's
mechanism). `gD` and `<leader>cl` are ungated. Method names are validated
against `vim.lsp.protocol._request_name_to_server_capability` by
`tests/lsp_keymaps_gated_spec.lua` -- a typo there silently unbinds a key
forever, which is a live bug in LazyVim itself (`workspace/symbols`).

| Keymap | Action | Gated on |
|--------|--------|----------|
| `gd` | Definitions (fzf-lua) | definition |
| `gr` | References (fzf-lua) | references |
| `gI` | Implementations (fzf-lua) | implementation |
| `gy` | Type definitions (fzf-lua) | typeDefinition |
| `gD` | Declaration, falling back to definitions | -- (fallback is the feature) |
| `gK` | Signature help | signatureHelp |
| `gai` / `gao` | Incoming / outgoing calls (fzf-lua) | callHierarchy |
| `]]` / `[[` / `<A-n>` / `<A-p>` | Reference jumps (Snacks.words) | documentHighlight |
| `K` | Hover docs (LSP; Fortran MPI/OpenMP docs come from fortran-extras) | hover (ungated; in lspconfig.lua) |
| `<C-k>` | Signature help (ty for Python if available) | -- (in lspconfig.lua) |
| `<leader>ca` | Code actions, fzf picker with diff preview | codeAction |
| `<leader>cA` | Source Action (`apply = true`, `only = {"source"}`) | codeAction |
| `<leader>co` | Organize Imports | the `source.organizeImports` KIND |
| `<leader>cc` / `<leader>cC` | Run / display codelens | codeLens |
| `<leader>cr` | Rename symbol | rename |
| `<leader>cR` | Rename file (`Snacks.rename`) | workspace/willRenameFiles |
| `<leader>cs` / `<leader>cS` | Document / workspace symbols (fzf) | documentSymbol, workspace/symbol |
| `<leader>ss` / `<leader>sS` | Same two pickers, LazyVim spelling | documentSymbol, workspace/symbol |
| `<leader>cl` | LSP info -- hand-rolled fzf client picker | -- |
| `<leader>D` | Buffer diagnostics (fzf-lua) | -- (in lspconfig.lua) |
| `<leader>lr` / `<leader>lh` | Restart LSP / toggle inlay hints | -- (in lspconfig.lua) |

Global (NOT LspAttach-bound, so they also cover linter diagnostics):
`<leader>cd` line diagnostics, `]d`/`[d` any severity, `]e`/`[e` errors,
`]w`/`[w` warnings (`lua/andrew/core/keymaps.lua`). `<leader>cf`/`<leader>cF`
(conform) and `<leader>cm` (Mason) live in their plugin specs.

Divergence from LazyVim: it points `<leader>cs`/`<leader>cS` at Trouble's
symbols and LSP views; here both are the fzf-lua symbol pickers, so Trouble
keeps only the `<leader>x` group and there is no Trouble LSP-references view
(`gr` covers references).

nvim 0.12's built-in `grn`/`gra`/`grx`/`grr`/`gri`/`grt` are DELETED at startup
in `lspconfig.lua` -- `gr` is bound to References, so leaving them would make
every `gr` press wait out `timeoutlen` (500ms).

**Treesitter query overrides live in `queries/`.** `queries/fortran/context.scm`
replaces nvim-treesitter-context's bundled Fortran query, which uses node names
(`do_loop`, `do_statement`) that the installed grammar does not have and so
fails to compile -- and a query that fails to compile is discarded whole, taking
all Fortran context with it. Such an override must NOT carry a `;; extends`
modeline: `get_files` treats the first runtimepath file without one as the base
and drops later bases, so a plain file replaces upstream's while `;; extends`
would append to the broken one.

**Server binaries are RESOLVED, not hardcoded.** `lspconfig.lua` looks in
mason's bin dir, then `$PATH`, then `$HOME/miniconda3/bin`, and a server whose
binary resolves nowhere is left disabled with one WARN notification instead of
being enabled and dying invisibly. That failure mode had already bitten: the
conda copy of `lua-language-server` was gone, so `lua_ls` never attached even
though mason had it installed. `ctags-lsp` is currently installed nowhere and
is therefore disabled.

**ctags_lsp serves C/C++ ONLY.** Fortran was tried and reverted on 2026-09-06:
ctags-lsp v0.11.0 scopes results to the current file (so it cannot complete C
header symbols from a Fortran buffer, the interop job it was there for), and
everything it did contribute to a Fortran buffer duplicated fortls -- both
answered `textDocument/documentSymbol` with the same names, listing every
subroutine twice in `<leader>ss`. Pinned by `tests/lsp_server_config_spec.lua`.

**fortls is configured by CLI FLAGS, not `initializationOptions`.** fortls 3.2.2
never reads initializationOptions (`langserver.py` has no reference to them), so
the `init_options` table this config used to pass was discarded wholesale --
including `enable_code_actions`, which is why fortls advertised no
`codeActionProvider` and `<leader>ca` was dead in Fortran buffers. Options now
go on the command line; per-project source/include dirs still belong in a
`.fortls` JSON file.

**Diagnostic icons:** `` (error), `` (warn), `` (hint), `` (info)

**Float windows:** 50% editor width / 30% height, min 40x8, max 120x40, rounded borders.

**Mason is an installer only, and nothing in it runs when a file opens.**
`mason.nvim` and `mason-tool-installer.nvim` load on their commands
(`:Mason`, `<leader>cm`, `:MasonToolsInstall`); `mason-lspconfig.nvim` was
removed because it parsed the whole mason registry inside the `FileType`
autocmd. What it did is now done natively:

- `init.lua` puts `mason/bin` on `$PATH` (mason's own PATH handling is `"skip"`).
- `lspconfig.lua` calls `vim.lsp.enable()` for clangd, emmet_ls, eslint,
  prismals, ruff and ty when mason has installed their binary. A server
  installed mid-session needs a restart to attach.
- On a fresh machine run `:MasonToolsInstall` once -- there is no automatic
  install. Its `ensure_installed` takes mason PACKAGE names (`rust-analyzer`,
  `lua-language-server`), not lspconfig names.

**Completion capabilities are a static copy** (`lua/andrew/lsp_capabilities.lua`)
of blink.cmp's `get_lsp_capabilities()`. Calling blink for them loaded blink.cmp
and LuaSnip before the first paint of every code buffer; both now load on
`InsertEnter`. `tests/lsp_capabilities_drift_spec.lua` fails if a blink update
changes the table -- re-copy it when that happens.

**Mason ensure_installed:** prettier, ruff, ty, eslint_d, codelldb, lua-language-server, python-lsp-server, rust-analyzer, ctags-lsp, emmet-ls, prisma-language-server, eslint-lsp

### Type Checking

Per-language type checking via terminal split (30% height):

| Keymap | Language | Command |
|--------|----------|---------|
| `<leader>ac` | Auto-dispatch | Selects by filetype |
| `<leader>aP` | Python | `ruff check` |
| `<leader>aT` | Python | `ty check` |
| `<leader>aR` | Rust | `cargo check` |
| `<leader>aL` | Lua | `lua-language-server --check` |
| `<leader>ag` | Fortran | `mpif90/gfortran -fsyntax-only` |
| `<leader>ai` | Fortran | `mpiifx -syntax-only` |
| `<leader>aC` | C/C++ | `g++/clang++ -fsyntax-only` |
| `<leader>at` | Fortran | Toggle between mpif90/mpiifx |

### Debugging (DAP)

**Supported languages:** Rust, C/C++, Fortran (all via CodeLLDB from Mason)

| Keymap | Action |
|--------|--------|
| `<leader>db` | Toggle breakpoint |
| `<leader>dB` | Conditional breakpoint |
| `<leader>dc` | Continue/start |
| `<leader>do` | Step over |
| `<leader>di` | Step into |
| `<leader>dO` | Step out |
| `<leader>dt` | Terminate |
| `<leader>dC` | Run to cursor |
| `<leader>dr` | Restart |
| `<leader>dR` | Toggle REPL |
| `<leader>du` | Toggle DAP UI |
| `<leader>de` | Evaluate expression |
| `<leader>df` | Float element |

### Fortran Build (Makefile Integration)

| Keymap | Action |
|--------|--------|
| `<leader>mb` | Make build |
| `<leader>md` | Make debug |
| `<leader>mc` | Make clean |
| `<leader>mr` | Make run |
| `<leader>ma` | Make all |
| `<leader>ml` | Re-run last Makefile |

## Complete Keymap Reference

**Leader key:** `<Space>`

| Prefix | Category | Notable Keymaps |
|--------|----------|-----------------|
| `<leader>f` | Find/Search (fzf-lua; one shared look, `utils/fzf_look.lua`) | `ff` files, `fr` recent, `fs` grep, `fc` word, `fk` keymaps, `fh` help, `ft` TODOs |
| `<leader>x` | Trouble/Diagnostics | `xw` workspace, `xd` document, `xe` errors (file), `xE` errors (workspace), `xq` quickfix, `xt` TODOs |
| `<leader>y` | Yank Path (for agent prompts) | `yf` relative path, `yp` absolute; line numbers ONLY from Visual mode, where the selection becomes `path#L10-L24` (`utils/path_reference.lua`, `tests/path_reference_spec.lua`) |
| `<leader>s` | Splits/Windows | `sv` vertical, `sh` horizontal, `se` equalize, `sx` close, `sm` maximize |
| `<leader><Tab>` | Tabs (LazyVim) | `<Tab>` new, `d` close, `o` close others, `]`/`[` next/prev, `f`/`l` first/last |
| `<leader>t` | Tabs/Terminal | `to` new, `tx` close, `tn` next, `tp` prev, `tf` buffer to tab, `tt` floating terminal |
| `<leader>g` | Git | `gg` lazygit, `gl` log, `gf` file history, `gb` blame line, `gs` status, `gS` stash, `gd`/`gD` diff, `gB`/`gY` browse, `gv` CodeDiff review tab, `gt`/`gT` CodeDiff file/repo history |
| `gh` / `gH` | mini.diff | Apply / reset a hunk range (operators); `gh` is also the hunk text object. `<leader>go` toggles the overlay |
| `<leader>gh` | Hunks | `ghs` stage, `ghu` unstage (the hunk under the cursor), `ghr` reset, `ghS` stage buffer, `ghR` reset buffer, `ghb` blame, `ghB` blame buffer, `ghd` diff, `ght` toggle inline blame |
| `<leader>c` | Code Actions | `ca` code action |
| `<leader>c` | Code | `ca` action, `cA` source, `co` organize imports, `cc`/`cC` codelens, `cr`/`cR` rename, `cd` diagnostics, `cf`/`cF` format, `cs`/`cS` Trouble, `cl` info, `cm` Mason |
| `<leader>d` | Debug | `db` breakpoint, `dc` continue, `do`/`di`/`dO` step, `dt` terminate (no longer shadowed by a diagnostic float) |
| `<leader>l` | Linting | `ll` lint, `lf` toggle Fortran, `lw` workspace, `lm` ruff |
| `<leader>a` | Type Check | `ac` dispatch, `aP` Python, `aR` Rust, `aL` Lua, `ag`/`ai` Fortran |
| `<leader>m` | Make/Build | `mb` build, `md` debug, `mc` clean, `mr` run, `ma` all, `ml` re-run |
| `<leader>r` | Rust/Refactor | `rr` runnables, `rd` debuggables, `rt` testables, `rm` expand macro, `rn` rename |
| `<leader>e` | Explorer (Yazi) | `ee` toggle, `ef` on file, `ec` close, `er` refresh |
| `<leader>v` | Vault Notes | `vn` new, `vd` daily, `vw` weekly, `vs` simulation, `va` analysis, `vt` task, `vm` meeting |
| `<leader>o` | _(unused)_ | Was OpenCode AI; keymaps removed 2026-09-06, plugin removed 2026-11-14 |
| `<leader>T` | Table Mode | `Tm` toggle markdown table mode |

**Non-leader keymaps:**

| Keymap | Action |
|--------|--------|
| `jk` | Exit insert mode (also exits terminal mode in floating terminal) |
| `<leader>nh` | Clear search highlights |
| `<leader>+` / `<leader>-` | Increment/decrement number |
| `]h` / `[h` | Next/prev git hunk |
| `]t` / `[t` | Next/prev TODO comment |
| `]d` / `[d` | Next/prev diagnostic |
| `gr` / `gD` / `gd` / `gI` / `gy` | LSP navigation |
| `K` | Hover documentation |
| `<C-k>` | Signature help |
| `<C-space>` | Treesitter incremental select |
| `gcc` / `gc` | Line/motion commenting |
| `gs` / `gss` / `gS` | Substitute motions |
| `ys` / `cs` / `ds` | Surround operations |

## Plugin Inventory

| Plugin | File | Purpose | Loading |
|--------|------|---------|---------|
| plenary.nvim | init.lua | Lua utilities | Dependency |
| vim-tmux-navigator | init.lua | Tmux/nvim navigation | Dependency |
| OneDarkPro | colorscheme.lua | Color scheme | `priority = 1000` |
| lualine.nvim | lualine.lua | Status line: project name (when the root is not the cwd), filetype icon, pretty path; also carries the `'showcmd'` keys and "recording @q" now that noice owns the message row | Config |
| noice.nvim | noice.lua | Floating `:` cmdline; messages in a box at the bottom-right | `VeryLazy` |
| incline.nvim | incline.lua | Window labels (icon, file name, `[+]`) at the top-right of every split | `VeryLazy` |
| snacks.nvim | snacks.lua | The start screen a bare `nvim` opens on (`dashboard`), `vim.ui.input` + `vim.ui.select` (picker.ui_select), the `snacks` backend of the file finder (`<leader>ff` / `<leader><space>`; `utils/file_picker.lua` picks between `fzf` and `snacks` via `vim.g.file_picker_backend`), inline images, `<leader>u` toggles | `lazy = false`, `priority = 1000` |
| which-key.nvim | which-key.lua | Keybinding hints | `VeryLazy` |
| nvim-web-devicons | ui/devicons.lua | File icons | `lazy = true` |
| blink.cmp | blink-cmp.lua | Completion | `InsertEnter, CmdlineEnter` |
| LuaSnip | luasnip.lua | Snippet engine (+ friendly-snippets) | `InsertEnter` |
| nvim-ts-autotag | ts-autotag.lua | Auto-close markup tags (dormant: `setup()` is never called) | `ft` (html, vue, jsx, tsx) |
| fzf-lua | fzf-lua.lua | Fuzzy finder | `cmd = "FzfLua"` |
| nvim-treesitter | treesitter.lua | Syntax highlighting | `BufReadPre, BufNewFile, VeryLazy` |
| nvim-autopairs | autopairs.lua | Auto-close brackets | `InsertEnter` |
| Comment.nvim | comment.lua | Commenting | `BufReadPre, BufNewFile` |
| indent-blankline.nvim | indent-blankline.lua | Indentation guides | `BufReadPre, BufNewFile` |
| todo-comments.nvim | todo-comments.lua | TODO/FIXME highlights | `BufReadPre, BufNewFile` |
| trouble.nvim | trouble.lua | Diagnostics viewer | `cmd = "Trouble"` |
| gitsigns.nvim | gitsigns.lua | Git signs + `<leader>gh` hunks | `BufReadPre, BufNewFile` |
| snacks.nvim (fragment) | git.lua | `<leader>g` git commands: fzf-lua pickers for log / history / status / stash / diff, snacks for lazygit and git browse | `keys` |
| mini.diff | mini-diff.lua | Diff overlay, `gh`/`gH` operators | `BufReadPre, BufNewFile` |
| codediff.nvim | codediff.lua | Diff review tab, file/repo history (`<leader>gv`/`gt`/`gT`); `build` fetches its diff library + watcher binary | `cmd = "CodeDiff"`, `keys` |
| vim-maximizer | vim-maximizer.lua | Maximize splits | Keys |
| substitute.nvim | substitute.lua | Motion-based replace | `BufReadPre, BufNewFile` |
| nvim-surround | surround.lua | Surrounding pairs | `BufReadPre, BufNewFile` |
| vim-table-mode | vim-table-mode.lua | Markdown tables | `ft = "markdown"` |
| render-markdown.nvim | render-markdown.lua | Styled markdown in the buffer being edited; the other backend of `:MarkdownRenderer`, and what the vault's preview floats and blink's documentation window use | `ft = "markdown"` |
| md-render.nvim | md-render.lua | Second markdown renderer, on trial: renders into a separate buffer (`:MdRender float\|tab\|split\|toggle`); the default backend of `:MarkdownRenderer` | `cmd` (`MdRender`, `MdRenderHeadingColors`, `MdRenderMath`) |
| nvim-colorizer | colorizer.lua | Color code preview | Config |
| yazi.nvim | yazi.lua | File explorer | `VeryLazy` |
| kitty-scrollback.nvim | kitty-scrollback.lua | Kitty's scrollback in an overlay nvim (copy mode). Started by Kitty, never by an ordinary nvim; the kitten path is hard-coded in `~/.config/kitty/kitty.conf` | `User KittyScrollbackLaunch`, `cmd` |
| rustaceanvim | rustaceanvim.lua | Rust IDE features | `lazy = false` |
| nvim-lspconfig | lsp/lspconfig.lua | LSP configuration | `BufReadPre, BufNewFile` |
| mason.nvim | lsp/mason.lua | Tool installer | `cmd`, `<leader>cm` |
| conform.nvim | formatting/conform.lua | Code formatting | `lazy = false` |
| nvim-lint | linting.lua | Linting | `BufReadPost, BufWritePost` |
| type-checker | type-checker.lua | Type checking (virtual) | `VeryLazy` |
| fortran-build | fortran-build.lua | Make integration (virtual) | Keys |
| nvim-dap | dap/dap.lua | Debug Adapter Protocol | `lazy = true` |
| nvim-dap-ui | dap/dap-ui.lua | Debug UI | `lazy = true` |

## Custom Modules

### Floating Terminal (`custom/plugins/terminal.lua`)

A hand-crafted floating terminal with session persistence. Loaded directly via `require()` in `init.lua` (not a lazy.nvim spec).

- **Toggle:** `<leader>tt`
- **Commands:** `:FloatingTerminal open|close|hide|toggle|restart|send`
- **Features:** 80% editor size, centered, session restoration, `jk` exits terminal mode
- **State:** Tracks `winid`, `bufnr`, `termpid`, `is_visible`

### Fortran Support (`fortran/`)

Custom Fortran development features beyond what fortls provides:

- **`init.lua`** - Sets up FileType autocmd for custom highlighting
- **`highlight.lua`** - Enhanced syntax highlighting for Fortran
- **`docs.lua`** - Legacy prose for the Fortran intrinsics (hover falls back to it)
- **`registry.lua`** - The one documentation set: MPI, the OpenMP runtime, the directives and clauses, the statement keywords. Hover, signature help, completion and `highlight.lua` all read it, so the coloured set, the hoverable set and the completable set are one set.
- **`lsp.lua` / `lsp_completion.lua`** - Fortran completion is served by the in-process `fortran-extras` LSP server, not by a blink source: context-aware (directives after the `!$OMP` sentinel, that directive's clauses after it, the registry on ordinary lines), with `textEdit` deciding what is inserted and `completionItem/resolve` keeping the documentation bodies off the wire until an item is selected. The old `blink-source.lua` was removed with it (see `tests/audit_fortran_blink_source_spec.lua`).

**Fortran-specific completion sources** (in blink-cmp.lua): `lsp > snippets > path > buffer`

### Vault Note System (`vault/`)

An Obsidian-like note template system for creating structured notes:

- **Commands:** `:VaultNew`, `:VaultDaily`
- **Keymaps:** `<leader>v` prefix (see keymap reference)
- **Templates (20+):** daily_log, weekly_review, task, analysis, meeting, journal, concept, simulation, finding, literature, project_dashboard, area_dashboard, domain_moc, person, asset, changelog, draft, financial_snapshot, methodology, presentation, recurring_task
- **Query engine:** DSL for searching/filtering vault notes (`query/` subdirectory)
- **Search exclusions:** `config.search.exclude_dirs` (default `.obsidian`, `Templates`) hides directories from search results only; they stay indexed so wikilinks and linkcheck still work. Distinct from `config.index.skip_dirs`, which drops them from the index. See `vault/search_exclude.lua`.

## Code Style Guidelines

### General Conventions

- Use **2 spaces** for indentation (enforced in `options.lua`)
- Use **descriptions** on all keymaps (`{ desc = "..." }`)
- Use **local aliases** for frequently used modules:
  ```lua
  local keymap = vim.keymap
  ```
- Assign a plain GLOBAL option value (boolean, number, string) through
  `vim.o`, not `vim.opt`. Neovim 0.13 types every `vim.opt` field as
  `vim.Option`, so lua_ls flags a plain value assigned to one
  (`assign-type-mismatch`); `vim.o` fields carry the option's real type, and
  both set the option as `:set` does. Keep `vim.opt` for a list given as a
  table and for `:append()` / `:prepend()` / `:remove()`. `core/options.lua`
  follows this. For `:setlocal`, in place of `vim.opt_local`, use `vim.bo` for
  a buffer option and `vim.wo[0][0]` for a window option, as `ftplugin/tex.lua`
  does: plain `vim.wo[win].x` writes the window's global value too.
  `ftplugin/markdown.lua`, `plugins/lualine.lua` and `init.lua` still assign
  through `vim.opt` / `vim.opt_local` (lua_ls does not flag those lines).
- Call a function Neovim 0.13 deprecated through
  `lua/andrew/utils/nvim_compat.lua` (`uri_to_buffer`, `uri_from_buffer`,
  `uri_from_file_name`, `uri_to_file_name`, `set_window_width`,
  `highlight_yanked_text`), never by
  either name directly: 0.12 has only the old name and 0.13 warns on it. Once
  0.12.5 is no longer the fallback, call the 0.13 functions and delete the
  module.
- The config's own Lua (everything outside `tests/` and `temp/`) is kept free
  of lua_ls diagnostics. Fix the annotation or the code rather than hide the
  message; a `---@diagnostic disable-next-line: <code>` is for a wrong
  annotation in a plugin or the runtime only, with a comment above it naming
  it. The deliberate replacements of plugin and Neovim functions (md-render
  adapters, `lsp_float.lua`, `ts_directive_compat.lua`) carry
  `duplicate-set-field` for that reason.
- The test files are held to a stricter bar: no lua_ls diagnostics even with
  its off-by-default `no-unknown` check, and every type written out. Every
  function with parameters has a `---@param` per parameter (`---@return` when
  it returns a value), a callback literal with parameters has `---@param`
  lines above it, and every `local x = {}` carries a `---@type`. Conventions:
  - Each spec annotates its harness: `---@type SpecHelper` above
    `local _H = dofile(...)` (`---@type SpecFixtures` for `fixtures.lua`).
    lua_ls cannot follow `dofile`; both classes live in those two files.
  - A stub assigned to a global or runtime function (`vim.system`,
    `vim.uv.fs_open`, `string.find`, ...) is typed with that function's REAL
    signature and a fake value is cast to the real return type. lua_ls merges
    whatever is assigned to such a field into its type for the whole
    workspace, so a fake return type turns into warnings in the config code.
  - A test that passes a wrong type on purpose keeps the API's annotation
    strict and marks the call: `-- Invalid on purpose: <what it checks>.` then
    `---@diagnostic disable-next-line: param-type-mismatch`.
  - Plugin types (`blink.cmp.*`, `wk.Spec`, ...) come in through a line
    `---@module "<plugin>"` in a block of its own (blank line after it):
    lazydev loads that plugin's library for the file. Directly above a
    statement it would also retype that local as the module, which is right
    only for `---@module "andrew.plugins.x"` above `local plug = dofile(...)`.
    `Snacks` and lazy.nvim's `Lazy*` classes load by name (lazydev `words` in
    `plugins/lsp/lspconfig.lua`).
  - A cast claims nothing the code has not proved: `---@cast x -nil` only
    after the `_H.assert_*` call (they raise) or the guard that established it.

### Clean Code Naming Conventions

Follow clean code principles for all identifiers:

**General Rules:**

- Use **descriptive, full words** - avoid abbreviations (`src` not `sr`, `config` not `cfg`)
- **Variables** should answer "what" - `user_name`, `is_valid`, `buffer_count`
- **Functions** should answer "what it does" or "what it returns" - `format_buffer()`, `get_client_capabilities()`
- **Booleans** should read naturally - `is_enabled`, `has_error`, `should_format`
- **Constants** in UPPER_SNAKE_CASE with descriptive names

**Variable Naming Examples:**

```lua
-- Bad
local c = require("conform")
local d = data
local fl = false
local fn = vim.fn

-- Good
local conform = require("conform")
local user_data = {}
local is_formatter_enabled = false
local function_provider = vim.fn
```

**Function Naming Examples:**

```lua
-- Bad
function run() end
function proc() end
function chk() end
function get() end

-- Good
function format_on_save() end
function process_buffer() end
function check_executable() end
function get_lsp_capabilities() end
function is_valid_buffer() end
function should_format_on_save() end
```

**Boolean Naming Examples:**

```lua
-- Bad
local active = true
local run = false
local flag = true

-- Good
local is_active = true
local should_run_linter = false
local has_diagnostics = true
local can_format = true
local is_initialized = false
```

**Constant Naming Examples:**

```lua
-- Bad
local MAX = 100
local CMD = "rustfmt"

-- Good
local MAX_BUFFER_SIZE = 100
local FORMATTER_COMMAND = "rustfmt"
local DEFAULT_INDENT_SIZE = 2
```

**Table/Module Naming:**

```lua
-- Bad
local tbl = {}
local m = require("module")

-- Good
local plugin_specs = {}
local lsp_config = require("andrew.plugins.lsp.lspconfig")
```

**Keymap Naming:**

```lua
-- Include descriptive action in desc
keymap.set("n", "<leader>ll", function()
  require("lint").try_lint()
end, { desc = "Lint: run linters for current buffer" })  -- describes WHAT it does

-- Not:
-- { desc = "Run lint" }  -- too vague
-- { desc = "ll" }  -- meaningless
```

### Clean Architecture

Organize code following Clean Architecture principles to separate concerns and keep the codebase testable and maintainable.

**Core Principles:**

- **Dependency Rule**: Inner circles (core) should not depend on outer circles (plugins/frameworks)
- **Single Responsibility**: Each module does one thing well
- **Abstraction Over Implementation**: Depend on interfaces, not concrete implementations
- **Separation of Concerns**: UI, business logic, and external services are decoupled

**Architecture Layers in Neovim Config:**

| Layer                  | Purpose                                          | Examples                                                      |
| ---------------------- | ------------------------------------------------ | ------------------------------------------------------------- |
| **Core**               | Fundamental settings, options, utility functions | `options.lua`, `keymaps.lua`, utility functions               |
| **Use Cases**          | Feature orchestration, cross-cutting concerns    | `init.lua` that loads modules                                 |
| **Interface Adapters** | Plugin configuration, LSP setup                  | `plugins/lsp/lspconfig.lua`, `plugins/formatting/conform.lua` |
| **Frameworks/Drivers** | External tools and plugins                       | lazy.nvim, conform.nvim, nvim-lint                            |

**Example: Separating Concerns**

```lua
-- Bad: Core depends on external plugins
-- lua/andrew/core/init.lua
require("andrew.core.options")
require("andrew.core.keymaps")

-- Bad: Core module directly uses plugin API
local conform = require("conform")  -- violates dependency rule
conform.setup({...})
```

```lua
-- Good: Core contains only fundamental settings
-- lua/andrew/core/options.lua
vim.o.number = true
vim.o.relativenumber = true
vim.o.tabstop = 2
vim.o.shiftwidth = 2
vim.o.expandtab = true

-- lua/andrew/core/keymaps.lua
local keymap = vim.keymap
keymap.set("i", "jk", "<ESC>", { desc = "Exit insert mode with jk" })
keymap.set("n", "<leader>nh", ":nohl<CR>", { desc = "Clear search results" })

-- Good: Plugin configurations are isolated
-- lua/andrew/plugins/formatting/conform.lua
local conform = require("conform")
conform.setup({
  format_on_save = { timeout_ms = 1000, lsp_fallback = true },
  formatters_by_ft = {
    lua = { "stylua" },
    python = { "ruff_format" },
  },
})

-- Good: Use abstractions for external tools
-- lua/andrew/plugins/linting.lua
local lint = require("lint")
local conda_ruff = vim.fn.expand("$HOME/miniconda3/bin/ruff")

if vim.fn.executable(conda_ruff) == 1 then
  lint.linters.ruff.cmd = conda_ruff
end
```

**Example: Encapsulating LSP Logic**

```lua
-- Bad: LSP config mixed with UI concerns
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function()
    vim.lsp.buf.hover()
    vim.lsp.buf.code_action()
    -- 50+ lines of mixed keymaps, diagnostics, and formatting
  end,
})

-- Good: Separated concerns with focused modules
-- lua/andrew/plugins/lsp/lspconfig.lua (interface adapter)
return {
  "neovim/nvim-lspconfig",
  dependencies = { "saghen/blink.cmp", "antosha417/nvim-lsp-file-operations" },
  config = function()
    local capabilities = require("blink.cmp").get_lsp_capabilities()
    vim.lsp.config("*", { capabilities = capabilities })
    -- Configure servers without UI logic
  end,
}

-- lua/andrew/core/keymaps.lua (UI layer uses LSP)
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("UserLspConfig", {}),
  callback = function(ev)
    local opts = { buffer = ev.buf, silent = true }
    opts.desc = "Show LSP references"
    vim.keymap.set("n", "gR", function()
      require("fzf-lua").lsp_references()
    end, opts)
  end,
})
```

**Example: Plugin Spec Pattern**

```lua
-- Bad: Monolithic plugin file with mixed responsibilities
return {
  "plugin/name",
  config = function()
    require("plugin").setup({
      -- 100+ lines of everything
      keymaps = {...},
      autocmds = {...},
      lsp = {...},
      formatting = {...},
    })
  end,
}

-- Good: Focused plugin spec per file
-- lua/andrew/plugins/lsp/lspconfig.lua
return {
  "neovim/nvim-lspconfig",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = { "saghen/blink.cmp" },
  config = function()
    -- Only LSP configuration
  end,
}

-- lua/andrew/plugins/formatting/conform.lua
return {
  "stevearc/conform.nvim",
  lazy = false,
  cmd = { "ConformInfo" },
  config = function()
    -- Only formatter setup
  end,
}
```

### Lua Style

- Use `vim.keymap.set()` for keybindings
- Always include `silent = true` and `desc` options
- Group related keymaps with consistent prefixes
- Use `vim.api.nvim_create_autocmd()` and `vim.api.nvim_create_augroup()` for autocmds
- Return tables for plugin specs (lazy.nvim format)

### Plugin Configuration Pattern

Prefer `opts` over `config` functions when possible. Use `config = function()` only when imperative logic is needed:

```lua
-- Preferred: declarative opts (enables deep merging across specs)
return {
  "author/plugin-name",
  event = "BufReadPre",
  dependencies = { "dep1", "dep2" },
  opts = {
    setting = true,
  },
}

-- When imperative logic is needed: config function
return {
  "author/plugin-name",
  event = "BufReadPre",
  dependencies = { "dep1", "dep2" },
  config = function()
    -- Complex setup with conditionals
  end,
}
```

**lazy.nvim spec properties that merge across files:** `opts`, `dependencies`, `cmd`, `event`, `ft`, `keys`. All other properties replace the parent spec.

### Local Custom Plugins

For hand-crafted plugins stored in `lua/andrew/custom/plugins/`, load them directly via `require()` in `init.lua` after lazy.nvim initializes. This is the pattern used for the floating terminal:

```lua
-- init.lua
require("andrew.core")
require("andrew.lazy")
require("andrew.custom.plugins.terminal")  -- Load as regular module
require("andrew.vault")                    -- Load vault system

vim.opt.termguicolors = true
```

**Do NOT use the `User LazyDone` autocmd pattern** for loading local modules - it can cause timing issues where plugins like nvim-treesitter run their config before all lazy plugins are loaded.

**Alternative for lazy.nvim managed local plugins:** Use the `dir` property:

```lua
return {
  dir = vim.fn.stdpath("config") .. "/lua/andrew/custom/plugins/terminal",
  name = "floating-terminal",
  config = function()
    -- setup
  end,
}
```

### Neovim 0.11+ API Patterns

This config targets Neovim 0.11+. Use the modern API patterns:

**Window/buffer options - use `vim.wo` and `vim.bo`:**

```lua
-- Bad (deprecated):
vim.api.nvim_win_set_option(winid, "number", false)
vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")

-- Good:
vim.wo[winid].number = false
vim.bo[bufnr].filetype = "markdown"
```

**Use `vim.uv` instead of `vim.loop`:**

```lua
-- Bad (deprecated):
if not vim.loop.fs_stat(path) then

-- Good:
if not vim.uv.fs_stat(path) then
```

**Use `vim.hl` instead of `vim.highlight`:**

```lua
-- Bad (deprecated):
vim.highlight.on_yank({ higroup = "IncSearch", timeout = 300 })

-- Good:
vim.hl.on_yank({ higroup = "IncSearch", timeout = 300 })
```

**Use `vim.diagnostic.jump()` instead of `goto_prev`/`goto_next`:**

```lua
-- Bad (deprecated):
vim.diagnostic.goto_prev()
vim.diagnostic.goto_next()

-- Good:
vim.diagnostic.jump({ count = -1, float = true })
vim.diagnostic.jump({ count = 1, float = true })
```

**Use `client:stop()` instead of `vim.lsp.stop_client()`:**

```lua
-- Bad (deprecated):
vim.lsp.stop_client(vim.lsp.get_clients({ name = "server_name" }))

-- Good:
for _, client in ipairs(vim.lsp.get_clients({ name = "server_name" })) do
  client:stop()
end
```

**LSP server configuration - use native `vim.lsp.config()` / `vim.lsp.enable()`:**

```lua
-- Bad (deprecated nvim-lspconfig pattern):
local lspconfig = require("lspconfig")
lspconfig.lua_ls.setup({ settings = { ... } })

-- Good (Neovim 0.11+ native API, already used in this config):
vim.lsp.config("lua_ls", {
  cmd = { "lua-language-server" },
  settings = { Lua = { runtime = { version = "LuaJIT" } } },
})
vim.lsp.enable("lua_ls")

-- Global defaults for all servers:
vim.lsp.config("*", { capabilities = capabilities })
```

**Full LSP deprecation reference:**

| Deprecated | Replacement |
|---|---|
| `vim.lsp.start_client()` | `vim.lsp.start()` |
| `vim.lsp.stop_client()` | `client:stop()` |
| `vim.lsp.get_active_clients()` | `vim.lsp.get_clients()` |
| `vim.lsp.buf_get_clients()` | `vim.lsp.get_clients({buffer=bufnr})` |
| `vim.diagnostic.goto_prev/next()` | `vim.diagnostic.jump()` |
| `vim.diagnostic.disable()` | `vim.diagnostic.enable(false)` |
| `vim.api.nvim_win_set_option()` | `vim.wo[winid].opt = val` |
| `vim.api.nvim_buf_set_option()` | `vim.bo[bufnr].opt = val` |
| `vim.loop` | `vim.uv` |
| `vim.highlight` | `vim.hl` |

**Neovim 0.11 built-in default keymaps** (no plugin needed, your custom mappings take precedence):

| Default | Action | Your Override |
|---------|--------|---------------|
| `grn` | Rename symbol | DELETED -> `<leader>cr` |
| `grr` | References | DELETED -> `gr` (fzf-lua) |
| `gri` | Implementation | DELETED -> `gI` (fzf-lua) |
| `gra` | Code actions | DELETED -> `<leader>ca` |
| `grt` | Type definition | DELETED -> `gy` (fzf-lua) |
| `grx` | Run codelens (new in 0.12) | DELETED -> `<leader>cc` |
| `gO` | Document symbols | Not overridden (available); see also `<leader>ss` |
| `Ctrl-S` | Signature help | Not overridden; `Ctrl-K` and `gK` also work |

They are deleted rather than shadowed: `gr` is itself a mapping, so any
surviving `gr*` would make `gr` wait out `timeoutlen`.

### `nvim_open_win` Options

Some options like `winblend` and `zindex` are window **options**, not window creation options. Set them after creation:

```lua
-- Bad: winblend is not a valid creation option
local opts = {
  relative = "editor",
  winblend = 10,  -- ERROR: invalid key
}
vim.api.nvim_open_win(bufnr, enter, opts)

-- Good: set after creation using vim.wo
local opts = {
  relative = "editor",
  -- only valid creation options here
}
local winid = vim.api.nvim_open_win(bufnr, enter, opts)
vim.wo[winid].winblend = 10
```

**Reference:** `:help nvim_open_win` and `:help win-options`

### Import Pattern

Use relative requires for local files:

```lua
require("andrew.core.options")
require("andrew.plugins.lsp.mason")
```

Use `vim.fn.expand()` for path resolution:

```lua
local conda_ruff = vim.fn.expand("$HOME/miniconda3/bin/ruff")
```

### Error Handling

- Use `pcall()` for operations that might fail
- Use `vim.notify()` for user feedback with appropriate log levels
- Use `vim.log.levels.ERROR`, `WARN`, `INFO`

### Conditional Setup

Check if tools exist before using them:

```lua
if vim.fn.executable(conda_ruff) == 1 then
  lint.linters.ruff.cmd = conda_ruff
end
```

### Filetype-Specific Notes

- **Python**: Uses `ruff` for linting, `ruff_format` for formatting, `pylsp` for LSP (Jedi completion), `ty` for type checking
- **Rust**: Uses `rust_analyzer` via rustaceanvim with `clippy` on save, `rustfmt` for formatting, CodeLLDB for debugging
- **Lua**: Uses `lua_ls` from conda, `stylua` for formatting
- **Fortran**: Uses `fortls` from conda, `fprettify` for formatting, multi-compiler linting (gfortran/ifort/ifx/mpiifx/nagfor), the in-process `fortran-extras` LSP server for MPI/OpenMP hover, signature help and completion, CodeLLDB for debugging
- **C/C++**: Uses `ctags_lsp` for header completions, `cppcheck` for linting, CodeLLDB for debugging
- **JS/TS/Vue**: Uses `eslint` for linting, `prettier` for formatting

## Development Workflow

1. Make changes to Lua files in `lua/andrew/`
2. Reload Neovim configuration: `:source ~/.config/nvim/init.lua`
3. Restart lazy.nvim: `:Lazy reload` (after changes to plugin specs)
4. Test formatting/linting behavior by saving files
5. Check LSP health: `:checkhealth lsp`
6. Check lazy.nvim status: `:Lazy`

## External Tools (Conda)

The config assumes tools are installed in a conda environment. `init.lua` prepends `$HOME/miniconda3/bin` to PATH.

**Conda-installed tools:**

```bash
conda install -c conda-forge \
  lua-language-server stylua \
  ruff \
  nodejs eslint \
  cppcheck \
  rust rust-src \
  gfortran fprettify fortls ctags-lsp \
  lazygit git-delta gh
```

`git-delta` installs a binary named `delta`, which fzf-lua pipes its git
previews through (`git_commits`, `git_bcommits`, `git_blame`, `git_status`,
`git_diff`, `git_stash`). It works because `init.lua` puts `~/miniconda3/bin`
first on PATH: `~/.local/bin/delta` is an unrelated desktop app's CLI that
rejects git-delta's flags, and fzf-lua only checks that some `delta` exists.

`gh` comes from conda as well, although Ubuntu ships one: snacks' issue pickers
(`<leader>gi` / `<leader>gI`) request the `stateReason` JSON field, which
Ubuntu's `gh` 2.45.0 rejects (the picker opens empty with a "GH Error").
conda-forge's 2.104.0 has it. Both read the same login.

**Snacks' own pickers wear the fzf look too** (`lua/andrew/utils/snacks_look.lua`):
the GitHub pickers and the `vim.ui.select` menus cannot be fzf-lua pickers, so
their `SnacksPicker*` / `SnacksGh*` highlight groups are redefined from the same
Telescope groups `fzf_look.lua` uses, and re-applied on `ColorScheme`. Two
things in it are workarounds, each explained at the code: the box title is
recoloured in `picker.on_show` (snacks' `SnacksPickerBoxTitle` group never
reaches the window), and the match counter is `nocombine` so the bold of the
typed query does not spread to it.

**Inside tmux, snacks.image learns the terminal's name from tmux**
(`lua/andrew/utils/snacks_tmux_terminal.lua`, set up from the snacks spec's
`config` before `setup()`, pinned by `tests/snacks_tmux_terminal_spec.lua`).
Upstream sends XTVERSION to the outer terminal through tmux passthrough, and
tmux reads Kitty's answer (`ESC P > | kitty(0.49.2) ESC \`) as key input: the
closing `ESC \` is `M-\`, which `~/.config/tmux/tmux.conf` binds to
`split-window -h`, and `>|kitty(0.49.2)` is typed into Neovim. The first
markdown buffer of a session split the pane and put that text in whatever had
focus. The name now comes from `tmux display-message -p '#{client_termtype}'`
and nothing is asked.

- NEVER send the outer terminal anything it answers from inside tmux (a query
  through passthrough, a graphics command without `q=2`): every answer ends in
  `ESC \`, so every one is that split.
- snacks still switches `allow-passthrough` to `all` on the PANE Neovim runs in
  (`tmux set -p`), the first time an image or equation is wanted. The global
  option stays `off`.
- The spec's first test fails once upstream stops sending the query; delete
  the module then.

**A bare `nvim` opens on a start screen** (the `dashboard` block of
`lua/andrew/plugins/snacks.lua`): LazyVim's dashboard -- header, a column of
single-key actions, the plugin load time -- with snacks' "NEOVIM" header.
Snacks shows it only when Neovim starts with nothing to show: any file or
directory argument, piped stdin or a non-empty first buffer skips it.
`:lua Snacks.dashboard()` reopens it.

| Key | Action | Same as |
| --- | --- | --- |
| `f` | Find File | `<leader>ff` |
| `n` | New File | `:ene` + insert mode |
| `g` | Find Text | `<leader>fs` |
| `r` | Recent Files | `<leader>fr` |
| `c` | Config | the file finder in `stdpath("config")` |
| `s` | Restore Session | `<leader>qs` |
| `l` | Lazy | `:Lazy` |
| `q` | Quit | `:qa` |

- `f` / `g` / `r` FEED the `<leader>` key rather than call a picker, so a row
  cannot drift from its key. `tests/dashboard_keys_spec.lua` fails if such a
  row names a key nothing maps -- which would otherwise be a row that silently
  does nothing. Do not switch them to `Snacks.dashboard.pick()`: it prefers
  the snacks picker whenever that is enabled, and it is, for `vim.ui.select`.
- No tabline and an empty statusline while it is up. Snacks zeroes
  `'showtabline'` and `'laststatus'` and restores them on close; lualine has
  `snacks_dashboard` in its `disabled_filetypes`, because it loads afterwards
  and sets `'laststatus'` back to 3.
- nvim-treesitter loads on `VeryLazy` as well as on the first file BECAUSE of
  this screen. Pickers preview files in scratch buffers, which fire neither
  `BufReadPre` nor `BufNewFile`, and `queries/markdown/injections.scm` needs
  the plugin's `set-lang-from-info-string!` directive: previewing a markdown
  file before any file had been opened raised "No handler for
  set-lang-from-info-string!".
- The `~` end-of-buffer markers are hidden in the dashboard's window only
  (`styles.dashboard.wo.fillchars`).

**Messages appear in a box, not on the message row** (`lua/andrew/plugins/noice.lua`).
noice's `messages` module is on, and routes of ours run before its built-in
ones: skip the kinds that only made sense on the row; send `:!command`
output, `'verbose'` traces and anything taller than 10 lines to a split; send
everything else to the `mini` view -- a bordered box above the statusline's
right end where messages stack oldest-first and each leaves after 5 s. Things
to know before touching it:

- The catch-all route is REQUIRED. noice's built-in routes list the kinds they
  show one by one and predate several (`bufwrite`, `undo`, `quickfix`,
  `shell_ret`, `progress`); those would match nothing and vanish silently.
- noice ignores the message `id` Neovim 0.12 uses to say "this replaces that".
  The one case that showed is `:w` (a `"name" ` placeholder, then the full
  line), handled by a route that drops the placeholder. Any other message that
  updates in place will stack a line per update.
- `vim.notify` is still Neovim's stock function (`notify.enabled = false`). It
  prints a message, so it lands in the box like everything else.
- With noice owning messages the row under the statusline stays empty except
  during `/` search, and Neovim no longer draws `'showcmd'` or "recording @q"
  there. `lualine.lua` shows both. The `'showcmd'` keys stay visible until the
  next command (noice never clears them); `'showcmdloc'` = `statusline` with a
  `%S` item was tried and loses the Visual selection size under lualine.
- Modelled on craftzdog's dotfiles, which use Neovim's experimental
  `vim._core.ui2` instead. ui2 was tried here: it draws its own command line,
  which doubles up with noice's popup.

**`'cursorline'` shows in the focused split only** (augroup
`focused-split-cursorline` in `lua/andrew/core/keymaps.lua`, pinned by
`tests/focused_split_cursorline_spec.lua`). Modelled on craftzdog's
`setlocal cursorline` / `setlocal nocursorline` pair on WinEnter / WinLeave,
but not a copy of it:

- Only the window's LOCAL value is written. Its GLOBAL value (per window,
  inherited by a split) is read as "does this window want a cursorline", so
  `:set nocursorline` sticks. `vim.wo[win].cursorline = x` writes both values;
  use `vim.wo[win][0]` in code that only means to change what is shown.
- Floats are skipped, and so are `nofile` / `quickfix` / `prompt` / `terminal`
  buffers: plugin panels use the line as a selection marker.
- The focused split is remembered from WinEnter, never read from the current
  window in BufWinEnter / WinNew. Those fire with a window current that an
  API call is only visiting (`nvim_win_set_buf`, `nvim_open_win` unentered).
- BufWinEnter is there because window options are remembered per buffer:
  `:buffer N` in the focused split brings along the "off" the buffer had in an
  unfocused one, with no window event fired.

**The tabline and the window labels are ported from craftzdog's dotfiles**, with
onedark's colours instead of his solarized-osaka ones. bufferline.nvim is gone.

- `lua/andrew/utils/tabline.lua` (set up from `init.lua`, pinned by
  `tests/tabline_spec.lua`) is the `'tabline'` expression: one slanted tab per
  TAB PAGE, named after the file in its focused window. Its five highlight
  groups are derived from `Normal`, `DiagnosticOk` (the green of the current
  tab) and `CursorLine` and re-derived on `ColorScheme`, which is what keeps
  them right across the `<leader>ub` light/dark toggle -- do not hardcode a
  palette there.
- `lua/andrew/plugins/incline.lua` is the label at the top-right of each split.
  It defines its own two groups, re-derived on `ColorScheme`:
  `WindowLabelFocused` is dark text on cyan (`DiagnosticHint`);
  `WindowLabelUnfocused` is bold white text on the unfocused window's own
  background (`NormalNC`, which onedark sets lighter than `Normal`), so it has
  no box. White is fixed for dark backgrounds only; the light theme uses the
  text colour.
- `'showtabline'` stays 2 (`core/options.lua`, `<leader>uA` toggles it). His is
  1, which hides the tabline until a second tab page exists.
- Deliberate differences from his tabline are listed at the top of
  `utils/tabline.lua`: dark text on the current tab, a tab keeping its name
  while a float has focus, `%` escaped in file names.

**The statusline's file section is project name, filetype icon, pretty path**
(`lua/andrew/utils/statusline_path.lua`, pinned by
`tests/statusline_path_spec.lua`), ported from craftzdog's dotfiles.

- The project name shows only while the project root is NOT the working
  directory. The path is relative to the cwd when the file is under it and to
  the project root otherwise.
- "Project root" here is `require("andrew.utils.root").project()`: the nearest
  directory holding one of `project_markers` (`.git`, `lua`, `package.json`,
  `Makefile`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `.obsidian`,
  `.zennotes`), cwd when none. It is NOT `root.get()`, the LSP-first root the
  `<leader>/` and grep pickers use; the two can differ.
- The file name's highlights are built with lualine's `create_hl`, which fills
  in the section's own colours; keep it that way rather than a bare `%#Group#`.

**The statusline shows two diagnostics counts** (`lua/andrew/plugins/lualine.lua`):
the workspace's behind a folder icon, then the current file's. Each hides
while it is zero.

- "Workspace" is every buffer Neovim holds diagnostics for, shown or not: the
  entries `<leader>xw` lists, as the file count is what `<leader>xd` lists.
  lua_ls reports on files nobody opened, so for Lua it is the project; a
  server that reports on open files only contributes the files opened so
  far. lua_ls fills its share in over the first half minute, and opening a
  file can still add to it (`core/options.lua` added 28; cause not looked
  into).
- Fortran's `<leader>Lw` results are in that count (they are ordinary
  diagnostics in their own namespace); the Fortran-only counter the
  statusline had was removed for it. A diagnostic the per-file linter also
  reports is counted twice, as `<leader>xw` lists it twice.
- `/temp/` is in `.gitignore` FOR this count: lua_ls honours `.gitignore`, and
  the md-render.nvim clone there was 278 of the workspace's 326 warnings. A
  `.luarc.json` is not the way to exclude a directory -- lazydev.nvim warns
  on every start when it finds one.

**The markdown renderer is switchable** (`lua/andrew/utils/markdown_renderer.lua`,
set up from `init.lua`, pinned by `tests/markdown_renderer_switch_spec.lua`), the
same way the file finder is. `:MarkdownRenderer md-render` /
`:MarkdownRenderer render-markdown` switches the running session;
`vim.g.markdown_renderer` holds the choice and `DEFAULT_BACKEND` in that file is
what a session starts with: `md-render` since 2026-11-16, `render-markdown`
before. md-render.nvim is still on trial, not a replacement -- render-markdown
stays installed either way (see below); to end the trial set `DEFAULT_BACKEND`
back, delete `plugins/md-render.lua`, the `md-render` entry in the switch, and
`"md-render"` from ibl's excludes.

- `render-markdown` decorates the buffer being edited. `md-render` uses that
  plugin's auto mode (experimental upstream): outside Insert mode the window
  shows a separate read-only buffer named `<file> [render]`, and `i`/`a`/`o`
  swap the source back in. None of the buffer-local markdown keymaps exist in
  that view.
- Exactly one is on per buffer, and a buffer is switched when it is current.
  The vault's preview floats and blink's documentation window call
  render-markdown directly and stay on it under either choice.
- The old backend comes off one tick BEFORE the new one goes on.
  render-markdown clears its decorations in a scheduled callback that gives up
  once the buffer is off screen, which is where md-render puts it.
- `plugins/md-render.lua` carries an adapter for three gaps in auto mode, all
  read from the undocumented `w:md_render_state`: a window that moved on to
  another file is released (otherwise the next file is never rendered and keeps
  the rendered view's `nonumber` etc.), a window split off a rendered view
  inherits the state so the same release works there, and a buffer already in
  auto mode is rendered again when it is shown again. Drop each when upstream
  covers it.
- Rendered views in a normal window (in place, `split`, `tab`; not the float)
  are centred by the same file with a `'statuscolumn'` of spaces. Gutter, not
  text, because md-render subtracts the gutter wherever it measures the window
  (wrapping, images, scaled headings), while its frontmatter block ignores the
  content indent and its image placement ignores virtual text. Neovim caps a
  gutter at 47 columns, so with the default 80-column render a window wider
  than 174 sits left of centre; `vim.g.md_render_max_width` is the knob.
  md-render empties `'statuscolumn'` in its own BufEnter, hence the
  `vim.schedule` there, and re-wraps on WinResized, hence none there.
- Every swap between a rendered view and its source keeps the cursor on the
  same text, both ways: `i`, `a` and the other Insert keys in auto mode,
  leaving Insert mode again, `:MdRender toggle`. md-render itself leaves it in
  the first column, and for a wrapped paragraph often a line off.
  `lua/andrew/utils/md_render_cursor.lua` finds the place by diffing the words
  of both buffers around the cursor, with no notion of which side is which
  (pinned by `tests/md_render_cursor_spec.lua`); `plugins/md-render.lua`
  applies it one tick after the swapped-out buffer is left, which is after
  md-render's own cursor placement and before the `i` it feeds.
- The callout-fold pass in `plugins/render-markdown.lua` skips Insert mode.
  Under auto mode the source enters the window as Insert begins, and that
  pass's `normal! zE` moved an end-of-line cursor one character left, so `A`
  typed before the last character.
- `:MdRender split` is VERTICAL here. Upstream runs a plain `:split` and has no
  option for it, so `plugins/md-render.lua` wraps `preview.split` in the
  spec's `config` to add `vertical` when the command gave no placement.
  `:horizontal MdRender split` is the stacked one; `:tab`, `:topleft` and
  `:botright` still work. The same wrapper puts the SOURCE on the left (on top
  when stacked) and the view on the right, from either: upstream opens the new
  window where `'splitright'` says, so from a rendered view the source landed
  on the right. It passes `aboveleft` / `belowright` itself and does not read
  those options; an explicit `:topleft` / `:botright` wins.
- The source beside a `:MdRender split` view is the markdown AS WRITTEN:
  render-markdown is switched off in that buffer and `'conceallevel'` is 0 in
  its windows (`ftplugin/markdown.lua` sets 2, which alone hides `**`,
  backticks and link URLs). Both come back when the view has left its last
  window -- the split closed, or toggled to the source. On the md-render
  backend the view leaves for every Insert, so there the source stays as
  written until `:MarkdownRenderer` switches away. The `'conceallevel'` write
  is scheduled on purpose: render-markdown comes off in a scheduled callback
  that ends by writing its own not-rendering value to every window.
- `preview.auto_off` is wrapped as well. A source window that `split` opened
  from a rendered view keeps that view's `w:md_render_state` (which is what
  stops auto mode turning it into a second view on InsertLeave); upstream's
  `auto_off` took that to mean the window showed the view and toggled it,
  leaving the source in a window with the view's `nonumber` and winbar.
- A rendered view draws to the terminal only while its window is on the
  current tab page (`lua/andrew/utils/md_render_tab_visibility.lua`, set up
  from the spec's `config`, pinned by `tests/md_render_tab_visibility_spec.lua`).
  md-render's images and scaled headings bypass Neovim's grid and are
  re-written by timers that only ask whether the window exists, so after
  `:tabnew` they were painted over the new tab. Images are gated by wrapping
  `put_image` / `clear_placements`; headings by swapping `state.win` of
  md-render.text_size for an invalid window while off screen, which is the
  fragile part. TabLeave clears the placements, TabEnter runs `:mode` (when
  headings were on screen) and fires md-render's `MdRenderRepaint`. Drop the
  file when upstream checks the tab page itself.
- A heading md-render draws LARGER has no level icon
  (`lua/andrew/utils/md_render_headings.lua`, set up from the spec's `config`,
  pinned by `tests/md_render_headings_spec.lua`). md-render prefixes every
  heading with an nf-md-format_header glyph -- the same ones render-markdown
  uses -- and has no option for it; in Kitty >= 0.40 it also scales the text
  (2x for `#` down to 1.17x for `######`, `:help md-render-text-size`), so the
  level was shown twice. `markdown.render` is wrapped and the icon taken off
  the line it returns, highlight and link ranges moved back with it. The icon
  STAYS where md-render will not scale (`text_size.spec_for(level)` is nil:
  inside tmux, another terminal, `:MdRender textsize off`), because there it
  is the only level marker. Scaling cannot work inside tmux: md-render refuses
  `TERM_PROGRAM=tmux`, which does not forward OSC 66.
- A scaled heading is drawn on the background of the WINDOW it is in
  (`lua/andrew/utils/md_render_heading_background.lua`, set up from the spec's
  `config`, pinned by `tests/md_render_heading_background_spec.lua`). md-render
  has to state a background for a scaled run and, for a heading group without
  one, states `NormalFloat`'s in every window; onedark's `NormalFloat`,
  `Normal` and `NormalNC` are three colours, so each heading sat in a darker
  box. The placements of a view are pointed at copies of their heading group
  (`MdRenderH1OnNormal`, `...OnNormalNC`) that carry the window's background,
  re-pointed on WinEnter and ColorScheme. Floats are left alone, and so is a
  heading group with a background of its own. Known remainder: a scaled block
  is one colour over two rows, so the heading under the cursor shows the page
  colour inside the `'cursorline'` band on its first row.
- Heading colours in a rendered view: levels 1-3 a colour each, levels 4-6
  level 4's (`lua/andrew/utils/md_render_heading_colors.lua`, set up from the
  spec's `config`, pinned by `tests/md_render_heading_colors_spec.lua`). It
  defines `MdRenderH1..6` itself, copied from the colourscheme's
  `@markup.heading.<level>.markdown` with 5 and 6 reading 4's, so nothing is
  hardcoded and both schemes of the `<leader>ub` toggle work. Set without
  `default`, so md-render's own (`default = true`, before every render) never
  replace them, and set again on ColorScheme, which md-render does not do --
  headings used to lose their colour on a theme toggle until the next render.
  ONLY md-render's views: the markdown source and render-markdown still show
  six colours. To change those too, move the rule into the colourschemes
  (`plugins/colorscheme.lua`, `themes/soft-paper.lua`).
- Under onedark (the dark scheme) levels 2 and 3 take another colour of
  onedarkpro's palette instead of its orange and yellow: blue and purple,
  `DEFAULT_ONEDARK_COLOR_OF_LEVEL` in the same file. `:MdRenderHeadingColors
  <level 2> <level 3>` (red, orange, yellow, green, cyan, blue, purple, white;
  tab-completes) changes them for the running session with a preview open, and
  without arguments says which are in use. The colours are read by name from
  `onedarkpro.helpers.get_colors()`, and only while `g:colors_name` is
  `onedark`, so the light scheme keeps its own. The command is in the spec's
  `cmd`, so it loads md-render when used first.
- A split's view does not flicker while its source is typed into
  (`lua/andrew/utils/md_render_repaint.lua`, set up LAST from the spec's
  `config`, pinned by `tests/md_render_repaint_spec.lua`). md-render erases
  every scaled heading before each redraw and writes it back after, and the
  gap showed: replaying the bytes Neovim sent while five words were typed, the
  headings were off screen 1.1 s out of 5, up to 110 ms at a time; now never
  while text is typed. Five parts, each explained at the code:
  - a redraw with headings on screen is held in ONE terminal frame with the
    headings written back after it: synchronized output (`CSI ? 2026 h`) goes
    out at the start of the redraw and its end after the write-back. A held
    frame is late by as long as that takes (0.5 ms as a rule, 9 ms at worst);
  - headings a redraw erased are written back in the next event-loop turn
    wherever they belong now (md-render waited for a debounced repaint when
    the set on screen changed, e.g. the completion menu over one), queued
    from `vim.on_key` so it runs ahead of what the key sets off, and flushed
    with `nvim__redraw({ cursor = true })`;
  - a rebuild that moved no heading keeps md-render's `last_layout`, so no
    full repaint follows it;
  - a rebuild that moved no image skips the image module's `redraw!`;
  - the `:mode` md-render owes itself after any window opens or closes is
    dropped unless a heading moved on screen, or the view jumped to a part of
    the note with other headings (`G`). The second matters because md-render
    erases a heading's cells in whatever colours the terminal was last told
    to use, and Neovim re-sends only cells that differ in its own grid: a
    heading that left by a jump used to leave a block of statusline colour
    behind. "Clean" is recorded after a FULL repaint only, not after every
    paint.

  `'termsync'` is turned OFF while frames are held and put back afterwards
  (no heading on this tab page, or a command being typed): Neovim's own
  synchronized output ends at the end of its flush, which would end the hold
  with the headings still erased. Redraws while a command or prompt is typed
  are NOT held -- the only flush that causes no redraw places the cursor in a
  window -- so there the headings still blink for 10 to 40 ms per redraw.

  NEVER flush there with anything that can cause a redraw. A redraw erases
  the headings, they are written back and flushed, and it loops at full
  speed: `:redrawtabline` did exactly that once a second tab page was open
  (cause not established). The module tracks md-render's heading states by
  wrapping `text_size.attach` / `refresh` / `detach` and uses their `drawn` /
  `last_layout` / `last_drawn` / `owes_invalidate` / `augroup` fields. Not
  fixed, and md-render's by design: a heading under a float (the completion
  menu) is shown at plain size until the float goes, because scaled text
  cannot be clipped.
- LaTeX math is typeset in the view (`lua/andrew/utils/md_render_math.lua`,
  set up from the spec's `config` before `md_render_repaint`; pinned by
  `tests/md_render_math_spec.lua`). md-render itself only colours the raw TeX,
  and mangles it on the way (`\mathbf{v}_i` comes out as `\mathbf{v}i`).
  Inline `$..$`, `$$..$$` on one line, `$$` blocks (also in list items and
  callouts) and ```` ```math ```` fences become pictures. Four modules, each
  with its own spec and a header that is its design document:
  - `md_render_math.lua` -- the only one that touches md-render. It takes the
    TeX from the SOURCE line before md-render parses it and splices the
    result into what `markdown.render` returns, so md-render wraps, sizes
    table columns and prefixes callouts with the true width. Every upstream
    function it wraps and every private field it reads is cited at the top
    of the file.
  - `md_render_math_tex.lua` -- TeX to a colour-free MASK (8-bit grey PNG,
    the cell box exactly): `pdftex` on a format precompiled from a template
    inside the module, then `mutool draw` in parallel. An inline picture is
    one text row high with its baseline on the terminal font's
    (JetBrainsMono's metrics are constants there). TeX runs note content, so
    it is sandboxed: `-no-shell-escape`, `openin_any=p`, `openout_any=p`,
    every `MKTEX*=0`, a 2 s limit per run, a cap on what it may print.
    Definitions never carry from one equation to another; the user's own go
    in the file `vim.g.md_render_math_preamble` names (part of the format).
  - `md_render_math_kitty.lua` -- a picture is TEXT: Kitty Unicode-placeholder
    cells (`U+10EEEE` + row, column and id diacritics) in a highlight whose
    foreground names the image, the mechanism snacks uses for math in the
    source buffer. It is part of Neovim's grid, so nothing is placed again on
    scroll, in floats or on other tab pages. The mask is tinted with the
    colour of `MdRenderMath` in memory and sent as bytes (`t=d`), so ssh
    works and a colour scheme change needs no TeX.
  - `md_render_math_text.lua` -- pure-Lua TeX to Unicode text, the fallback.

  Things to know before touching it:
  - `vim.g.md_render_math`: `"picture"` (default), `"text"`, `"off"` (exactly
    md-render alone); read at every build. `:MdRenderMath status` says which
    mode is in effect and why, `errors` lists the equations that failed with
    TeX's message (quickfix), `retry` forgets failures and re-reads the
    preamble, `yank` copies the TeX under the cursor in a view.
  - Text instead of a picture: while the picture is being made, in a heading
    md-render scales, outside Kitty, inside tmux unless `allow-passthrough`
    is on (it is not set in `~/.config/tmux`; nothing here changes it),
    without `pdftex` / `mutool` (Ubuntu: `texlive-binaries` with `amsmath` /
    `mathtools`, `mupdf-tools`), for an inline equation shrunk below 0.6 or
    wider than its line, a block below 0.5, a box beyond 297 cells, and a
    mask file that is missing twice in a row. TeX that fails to compile is
    left as md-render shows it.
  - Speed is the point of most of what looks odd in those files; measure
    before simplifying. A pdftex with its format loaded WAITS on a FIFO
    between batches (one new equation: ~18 ms instead of ~55; 38 MB while it
    waits, stopped after 2 minutes without use). Equations near the window
    are requested first when more than 40 are missing. Nothing is requested
    in Insert mode, and leaving it requests without a rebuild. A settle
    rebuilds only the views that asked. The text fallback is memoised.
  - Everything is bounded and released: pictures no view shows are deleted
    from the terminal 300 ms after the redraw that dropped them (256 kept
    for going back; one never seen shown is kept 30 s), all of them on exit;
    image ids and their highlight groups are REUSED -- Neovim has 19,999
    highlight groups and never frees one, and at the limit every plugin's
    `nvim_set_hl` fails. Closing a split's window releases nothing: md-render
    keeps the view's buffer. The cache (`stdpath("cache")/md-render-math`:
    `masks/`, `run/`, a 19 MB format) is pruned to 32 MB once a session, off
    the main thread. Without `setpriv` (util-linux) there is no waiting
    pdftex: a `kill -9` of Neovim could not end it.
  - Quitting must never wait on TeX: nothing in the tex module may block in
    `open()` on the FIFO (that hung `:qa` once), and nothing is spawned once
    `VimLeavePre` has run. `tests/md_render_math_tex_spec.lua` quits child
    Neovims mid-batch to pin it.
  - The picture highlight must be the top one on its cells and have
    `spell = false`: any other foreground is another image id, and an
    underline colour is another placement id, so Kitty draws nothing. The
    adapter re-applies them itself at priority 10000 after md-render's
    `apply_content_to_buffer`; do not route them through
    `content.highlights`.
  - When in doubt the adapter ABSTAINS: the line or block is shown exactly as
    md-render alone shows it. Prose typeset as an equation is the one
    outcome that is never acceptable; a missing picture is. Two rules:
    - TeX on a `$$` delimiter line (`$$ a = b`, `c $$`, `$$ (1)`) is not a
      block (md-render's rule; where it joins such lines into one paragraph
      they are typeset as a one-line `$$tex$$`), and below such a line no
      more plain blocks are drawn in that note rather than guess which `$$`
      opens. `:MdRenderMath errors` and `status` name the line. Rewriting
      those lines was built and taken out again: to never lose content it
      needed a second model of md-render's lists, quotes and fences. Use
      `\tag{1}` in a block.
    - Which `$` pair is md-render's decision, made AFTER its link and
      emphasis passes. On a line those passes can change (a link, a
      wikilink, a `%%` comment, an HTML tag, emphasis right next to a `$`)
      the adapter asks md-render itself, by watching its
      `process_inline_math` (an upvalue of `markdown.render`); if that
      cannot be installed such lines are left to md-render.
  - Limits: a table wider than the view cuts a picture mid-cell
    (`markdown_table.lua:186`); math in a scaled heading is text; `\(..\)`,
    `\[..\]` and a bare `\begin{align}` are not math (Obsidian's rule);
    Kitty evicting images past its 320 MB quota is not noticed; `winblend`
    on a view blanks its pictures; the placeholder cells, not the TeX, are
    what a yank from the view gets (`:MdRenderMath yank`).
  - Seen only in a headless Kitty: the screenshots that checked this came
    from Kitty 0.49.2's own terminal core and font renderer driven without a
    window, not from the real screen.
- `:MdRender` (float, `tab`, `split`, `toggle`, `demo`) does not depend on the
  backend, but float and `tab` must be run from the source buffer. Its images
  and diagrams need the Kitty graphics protocol, and inside tmux
  `set -g allow-passthrough all`, which is currently `off`.

**fzf-lua's git pickers are adapted in three places**, all under `lua/andrew/utils/`:

- `fzf_git_preview.lua` -- runs each picker's preview command in fzf-lua's
  Neovim preview window (a terminal buffer) instead of letting fzf print it in
  its own. That is what gives them the same two boxes as the file pickers.
  Enabled per picker in `fzf_look.lua`.
- `fzf_look.lua` also moves the `<C-d>` action of `git_commits` and `git_diff`
  to `<A-d>`: `<C-d>` pages the preview everywhere, and with a Neovim-window
  preview that mapping wins.
- `fzf_git_hunks.lua` -- replaces `git_hunks`' row parser, which upstream
  raises on a hunk header without a count (`@@ -1 +1,2 @@`) and so empties the
  whole picker. Pinned by `tests/fzf_git_hunks_spec.lua`; drop it when
  upstream's `make_entry.git_hunk` handles that header.

**Mason-installed tools** (installed by `:MasonToolsInstall`, not automatically):
prettier, ruff, ty, eslint_d, codelldb, lua-language-server, python-lsp-server, rust-analyzer, ctags-lsp, emmet-ls, prisma-language-server, eslint-lsp

**Tool path resolution:**
- LSP servers: `$HOME/miniconda3/bin/` (lua_ls, fortls, ctags-lsp)
- Formatters: `$CONDA_PREFIX/bin/` (prettier, fprettify, ruff)
- Linters: `$HOME/miniconda3/bin/` (ruff, eslint)

## Known Deprecations in This Config

All previously known deprecations have been resolved. Last audited: 2026-02-25.

No deprecated patterns remain in the codebase.

## Agent Best Practices

### Planning Before Building

- Use **Plan mode** for analyzing code and reviewing suggestions before making changes
- Plan mode disables file edits and bash commands by default, set to `ask`
- Switch back to **Build mode** when ready to implement changes

### Providing Context

- Use `@` syntax to reference specific files when asking for changes:
  ```
  How is LSP configured in @lua/andrew/plugins/lsp/lspconfig.lua
  ```
- Provide enough detail so the agent understands the task
- Talk to the agent like you're talking to a junior developer on your team

### Neovim Help Research

- ALWAYS spawn a subagent to investigate Neovim `:help` during planning/research phase
- Search `:help` for any Neovim configuration options, functions, or APIs being used
- Use findings from Neovim help to inform implementation choices
- Reference help tags directly in code comments when applicable (e.g., `:help vim.keymap.set`)

### Plugin Documentation Research

- When working with installed plugins, reference their documentation in `~/.local/share/nvim/lazy/`
- Typical plugin structure:
  ```
  ~/.local/share/nvim/lazy/<plugin-name>/
  ├── lua/           # Plugin Lua modules
  ├── doc/           # Plugin :help documentation (tag files)
  ├── plugin/        # Vim script loaded at startup
  └── README.md      # Plugin documentation
  ```
- Common plugins in this config:
  | Plugin | Purpose | Docs Location |
  |--------|---------|---------------|
  | `lazy.nvim` | Plugin manager | `~/.local/share/nvim/lazy/lazy.nvim/doc/` |
  | `nvim-lspconfig` | LSP configuration | `~/.local/share/nvim/lazy/nvim-lspconfig/doc/` |
  | `conform.nvim` | Formatter setup | `~/.local/share/nvim/lazy/conform.nvim/doc/` |
  | `nvim-lint` | Linter setup | `~/.local/share/nvim/lazy/nvim-lint/doc/` |
  | `blink.cmp` | Completion | `~/.local/share/nvim/lazy/blink.cmp/doc/` |
  | `gitsigns.nvim` | Git signs | `~/.local/share/nvim/lazy/gitsigns.nvim/doc/` |
  | `todo-comments.nvim` | TODO highlights | `~/.local/share/nvim/lazy/todo-comments.nvim/doc/` |
  | `fzf-lua` | Fuzzy finder | `~/.local/share/nvim/lazy/fzf-lua/doc/` |
  | `trouble.nvim` | Diagnostics | `~/.local/share/nvim/lazy/trouble.nvim/doc/` |
  | `lualine.nvim` | Statusline | `~/.local/share/nvim/lazy/lualine.nvim/doc/` |
  | `mason.nvim` | LSP installer | `~/.local/share/nvim/lazy/mason.nvim/doc/` |
  | `rustaceanvim` | Rust IDE | `~/.local/share/nvim/lazy/rustaceanvim/doc/` |
  | `nvim-dap` | Debugging | `~/.local/share/nvim/lazy/nvim-dap/doc/` |
  | `yazi.nvim` | File explorer | `~/.local/share/nvim/lazy/yazi.nvim/doc/` |
- Always check the plugin's `README.md` and `:help` documentation before implementing configurations

### Tool Usage Patterns

- **Always read a file before editing it** - the edit tool requires prior context
- **Batch related operations** when possible for efficiency
- Use `glob` to find files before using `ripgrep` or `read`
- Use `ripgrep` (`rg`) for content search before reading specific files
