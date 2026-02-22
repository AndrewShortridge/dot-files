# AGENTS.md

This is a Neovim configuration repository targeting **Neovim 0.11+**. Agents should primarily work with Lua files in `lua/andrew/`.

## Project Structure

```
~/.config/nvim/
├── init.lua                         # Entry point (sets conda PATH, loads modules)
├── lazy-lock.json                   # Plugin lock file (auto-managed)
├── .stylua.toml                     # Lua formatter config
├── snippets/                        # Custom code snippets (LuaSnip)
│   ├── extract-docs.lua
│   └── test-hover.lua
└── lua/andrew/
    ├── lazy.lua                     # Plugin manager setup (lazy.nvim bootstrap)
    ├── core/
    │   ├── init.lua                 # Loads options and keymaps
    │   ├── options.lua              # Neovim options (vim.opt settings)
    │   └── keymaps.lua              # Global keybindings (leader = Space)
    ├── plugins/
    │   ├── init.lua                 # Master plugin spec list
    │   ├── autopairs.lua            # Auto-close brackets (nvim-autopairs)
    │   ├── blink-cmp.lua            # Completion engine (blink.cmp + LuaSnip)
    │   ├── bufferline.lua           # Tab bar (bufferline.nvim)
    │   ├── colorizer.lua            # Color code highlighting (nvim-colorizer)
    │   ├── colorscheme.lua          # OneDarkPro theme
    │   ├── comment.lua              # Commenting (Comment.nvim)
    │   ├── dressing.lua             # Improved UI dialogs (dressing.nvim)
    │   ├── fortran-build.lua        # Makefile integration for Fortran
    │   ├── fzf-lua.lua              # Fuzzy finder (fzf-lua)
    │   ├── gitsigns.lua             # Git change indicators (gitsigns.nvim)
    │   ├── indent-blankline.lua     # Indentation guides
    │   ├── linting.lua              # Multi-language linting (nvim-lint)
    │   ├── lualine.lua              # Status line (lualine.nvim)
    │   ├── opencode.lua             # AI coding assistant (opencode.nvim)
    │   ├── render-markdown.lua      # In-buffer markdown rendering
    │   ├── rustaceanvim.lua         # Enhanced Rust development
    │   ├── substitute.lua           # Motion-based replace
    │   ├── surround.lua             # Manage surrounding pairs
    │   ├── todo-comments.lua        # TODO/FIXME highlights
    │   ├── treesitter.lua           # Syntax highlighting (nvim-treesitter)
    │   ├── trouble.lua              # Diagnostics viewer (trouble.nvim)
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
    │   ├── blink-source.lua         # Completion source for blink.cmp
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

**Auto-lint** triggers on `BufReadPost`, `BufWritePost`, `InsertLeave`, and `FileType` events.

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
| `<leader>ll` | Lint current buffer |
| `<leader>lm` | Run ruff only (Python) |
| `<leader>lf` | Toggle Fortran compiler |
| `<leader>lF` | Run Fortran linter (debug verbose) |
| `<leader>lw` | Lint entire Fortran workspace |
| `<leader>lW` | Clear workspace diagnostics |

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

**LSP keybindings** (buffer-local via `LspAttach`):

| Keymap | Action |
|--------|--------|
| `gR` | References (fzf-lua) |
| `gD` | Declaration |
| `gd` | Definitions (fzf-lua) |
| `gi` | Implementations (fzf-lua) |
| `gt` | Type definitions (fzf-lua) |
| `K` | Hover docs (custom Fortran docs first, then LSP) |
| `<C-k>` | Signature help (ty for Python if available) |
| `<leader>ca` | Code actions (normal + visual) |
| `<leader>rn` | Rename symbol |
| `<leader>D` | Buffer diagnostics (fzf-lua) |
| `<leader>d` | Line diagnostics (float) |
| `[d` / `]d` | Previous/next diagnostic |
| `<leader>rs` | Restart LSP |

**Diagnostic icons:** `` (error), `` (warn), `` (hint), `` (info)

**Float windows:** 50% editor width / 30% height, min 40x8, max 120x40, rounded borders.

**Mason ensure_installed (LSP):** lua_ls, emmet_ls, prismals, pylsp, eslint, rust_analyzer
**Mason ensure_installed (tools):** prettier, ty, ruff, eslint_d, rust_analyzer, codelldb

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
| `<leader>f` | Find/Search (fzf-lua) | `ff` files, `fr` recent, `fs` grep, `fc` word, `fk` keymaps, `fh` help, `ft` TODOs |
| `<leader>x` | Trouble/Diagnostics | `xw` workspace, `xd` document, `xe` errors (file), `xE` errors (workspace), `xq` quickfix, `xt` TODOs |
| `<leader>s` | Splits/Windows | `sv` vertical, `sh` horizontal, `se` equalize, `sx` close, `sm` maximize |
| `<leader>t` | Tabs/Terminal | `to` new, `tx` close, `tn` next, `tp` prev, `tf` buffer to tab, `tt` floating terminal |
| `<leader>h` | Git Hunks | `hs` stage, `hr` reset, `hS` stage buffer, `hR` reset buffer, `hb` blame, `hd` diff |
| `<leader>c` | Code Actions | `ca` code action |
| `<leader>d` | Debug/Diagnostics | `db` breakpoint, `dc` continue, `do`/`di`/`dO` step, `dt` terminate |
| `<leader>l` | Linting | `ll` lint, `lf` toggle Fortran, `lw` workspace, `lm` ruff |
| `<leader>a` | Type Check | `ac` dispatch, `aP` Python, `aR` Rust, `aL` Lua, `ag`/`ai` Fortran |
| `<leader>m` | Make/Build | `mb` build, `md` debug, `mc` clean, `mr` run, `ma` all, `ml` re-run |
| `<leader>r` | Rust/Refactor | `rr` runnables, `rd` debuggables, `rt` testables, `rm` expand macro, `rn` rename |
| `<leader>e` | Explorer (Yazi) | `ee` toggle, `ef` on file, `ec` close, `er` refresh |
| `<leader>v` | Vault Notes | `vn` new, `vd` daily, `vw` weekly, `vs` simulation, `va` analysis, `vt` task, `vm` meeting |
| `<leader>o` | OpenCode AI | `ot` toggle, `oa` ask, `oe` explain, `on` new session |
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
| `gR` / `gD` / `gd` / `gi` / `gt` | LSP navigation |
| `K` | Hover documentation |
| `<C-k>` | Signature help |
| `<C-space>` | Treesitter incremental select |
| `gcc` / `gc` | Line/motion commenting |
| `s` / `ss` / `S` | Substitute motions |
| `ys` / `cs` / `ds` | Surround operations |

## Plugin Inventory

| Plugin | File | Purpose | Loading |
|--------|------|---------|---------|
| plenary.nvim | init.lua | Lua utilities | Dependency |
| vim-tmux-navigator | init.lua | Tmux/nvim navigation | Dependency |
| OneDarkPro | colorscheme.lua | Color scheme | `priority = 1000` |
| lualine.nvim | lualine.lua | Status line | Config |
| bufferline.nvim | bufferline.lua | Tab bar | Config |
| dressing.nvim | dressing.lua | Improved UI dialogs | `VeryLazy` |
| which-key.nvim | which-key.lua | Keybinding hints | `VeryLazy` |
| nvim-web-devicons | ui/devicons.lua | File icons | `lazy = true` |
| blink.cmp | blink-cmp.lua | Completion (+ LuaSnip) | `InsertEnter` |
| fzf-lua | fzf-lua.lua | Fuzzy finder | `cmd = "FzfLua"` |
| nvim-treesitter | treesitter.lua | Syntax highlighting | `BufReadPre, BufNewFile` |
| nvim-autopairs | autopairs.lua | Auto-close brackets | `InsertEnter` |
| Comment.nvim | comment.lua | Commenting | `BufReadPre, BufNewFile` |
| indent-blankline.nvim | indent-blankline.lua | Indentation guides | `BufReadPre, BufNewFile` |
| todo-comments.nvim | todo-comments.lua | TODO/FIXME highlights | `BufReadPre, BufNewFile` |
| trouble.nvim | trouble.lua | Diagnostics viewer | `cmd = "Trouble"` |
| gitsigns.nvim | gitsigns.lua | Git signs | `BufReadPre, BufNewFile` |
| vim-maximizer | vim-maximizer.lua | Maximize splits | Keys |
| substitute.nvim | substitute.lua | Motion-based replace | `BufReadPre, BufNewFile` |
| nvim-surround | surround.lua | Surrounding pairs | `BufReadPre, BufNewFile` |
| vim-table-mode | vim-table-mode.lua | Markdown tables | `ft = "markdown"` |
| render-markdown.nvim | render-markdown.lua | Styled markdown | `ft = "markdown"` |
| nvim-colorizer | colorizer.lua | Color code preview | Config |
| yazi.nvim | yazi.lua | File explorer | `VeryLazy` |
| opencode.nvim | opencode.lua | AI assistant | Config |
| rustaceanvim | rustaceanvim.lua | Rust IDE features | `lazy = false` |
| nvim-lspconfig | lsp/lspconfig.lua | LSP configuration | `BufReadPre, BufNewFile` |
| mason.nvim | lsp/mason.lua | Tool installer | Config |
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
- **`docs.lua`** - Custom hover documentation for Fortran intrinsics
- **`blink-source.lua`** - Completion source providing Fortran intrinsic completions to blink.cmp (min 2 chars, score offset +10)

**Fortran-specific completion sources** (in blink-cmp.lua): `fortran_docs > lsp > snippets > path > buffer`

### Vault Note System (`vault/`)

An Obsidian-like note template system for creating structured notes:

- **Commands:** `:VaultNew`, `:VaultDaily`
- **Keymaps:** `<leader>v` prefix (see keymap reference)
- **Templates (20+):** daily_log, weekly_review, task, analysis, meeting, journal, concept, simulation, finding, literature, project_dashboard, area_dashboard, domain_moc, person, asset, changelog, draft, financial_snapshot, methodology, presentation, recurring_task
- **Query engine:** DSL for searching/filtering vault notes (`query/` subdirectory)

## Code Style Guidelines

### General Conventions

- Use **2 spaces** for indentation (enforced in `options.lua`)
- Use **descriptions** on all keymaps (`{ desc = "..." }`)
- Use **local aliases** for frequently used modules:
  ```lua
  local keymap = vim.keymap
  local opt = vim.opt
  ```

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
local opt = vim.opt
opt.number = true
opt.relativenumber = true
opt.tabstop = 2
opt.shiftwidth = 2
opt.expandtab = true

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
| `grn` | Rename symbol | `<leader>rn` |
| `grr` | References | `gR` (fzf-lua) |
| `gri` | Implementation | `gi` (fzf-lua) |
| `gra` | Code actions | `<leader>ca` |
| `gO` | Document symbols | Not overridden (available) |
| `Ctrl-S` | Signature help | `Ctrl-K` |

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
- **Fortran**: Uses `fortls` from conda, `fprettify` for formatting, multi-compiler linting (gfortran/ifort/ifx/mpiifx/nagfor), custom hover docs, custom blink.cmp source, CodeLLDB for debugging
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
  gfortran fprettify fortls ctags-lsp
```

**Mason-installed tools** (auto-installed via mason-tool-installer):
prettier, ty, ruff, eslint_d, rust_analyzer, codelldb, lua_ls, emmet_ls, prismals, pylsp, eslint

**Tool path resolution:**
- LSP servers: `$HOME/miniconda3/bin/` (lua_ls, fortls, ctags-lsp)
- Formatters: `$CONDA_PREFIX/bin/` (prettier, fprettify, ruff)
- Linters: `$HOME/miniconda3/bin/` (ruff, eslint)

## Known Deprecations in This Config

These deprecated patterns exist in the codebase and should be updated when touched:

| File | Lines | Issue | Fix |
|---|---|---|---|
| `custom/plugins/terminal.lua` | 143-153 | `nvim_win_set_option()` | Use `vim.wo[winid]` |
| `lazy.lua` | 16 | `vim.loop` | Use `vim.uv` |
| `core/keymaps.lua` | 71 | `vim.highlight` | Use `vim.hl` |
| `plugins/lsp/lspconfig.lua` | 277, 281 | `vim.diagnostic.goto_prev/next()` | Use `vim.diagnostic.jump()` |
| `plugins/lsp/lspconfig.lua` | 577 | `vim.lsp.stop_client()` | Use `client:stop()` |
| `plugins/lsp/mason.lua` | - | `williamboman/mason.nvim` | Update to `mason-org/mason.nvim` |
| `plugins/lsp/mason.lua` | - | `williamboman/mason-lspconfig.nvim` | Update to `mason-org/mason-lspconfig.nvim` |
| `plugins/lsp/lspconfig.lua` | - | `folke/neodev.nvim` dependency | Replace with `folke/lazydev.nvim` |

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
