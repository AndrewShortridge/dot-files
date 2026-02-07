# AGENTS.md

This is a Neovim configuration repository. Agents should primarily work with Lua files in `lua/andrew/`.

## Project Structure

```
~/.config/nvim/
├── init.lua                 # Entry point, loads lazy.lua and core/
├── lua/andrew/
│   ├── lazy.lua            # Plugin manager setup (lazy.nvim)
│   ├── core/
│   │   ├── init.lua        # Loads options and keymaps
│   │   ├── options.lua     # Neovim options (opt.* settings)
│   │   └── keymaps.lua     # Global keybindings
│   └── plugins/
│       ├── init.lua        # Plugin spec imports
│       ├── *.lua           # Individual plugin configs
│       ├── lsp/
│       │   ├── mason.lua   # LSP server installation
│       │   └── lspconfig.lua # LSP server configuration
│       ├── formatting/
│       │   └── conform.lua # Formatter setup (conform.nvim)
│       └── linting.lua     # Linter setup (nvim-lint)
```

## Build/Lint/Test Commands

### Formatting

**Auto-format on save** is enabled for configured file types. Files are formatted when saved:

- Lua → `stylua`
- Python → `ruff format`
- Rust → `rustfmt`
- JS/TS/HTML/CSS/JSON/YAML/Markdown → `prettier` (from conda env)

**Manual formatting:**

```vim
:lua require("conform").format()
```

### Linting

**Auto-lint on save** is enabled via `nvim-lint`. Runs appropriate linter per filetype.

**Manual linting:**

```vim
:lua require("lint").try_lint()  " Run all linters for current buffer
:lua require("lint").try_lint("ruff")  " Run ruff only (Python)
```

**Keymaps:**

- `<leader>ll` - Run linters for current buffer
- `<leader>lm` - Run ruff only (Python)

### LSP

**LSP servers configured:**

- `lua_ls` - For Lua/Neovim config
- `rust_analyzer` - For Rust (uses `clippy` on save)
- `pylsp` - For Python
- `fortls` - For Fortran

**Restart LSP:** `<leader>rs`

### Type Checking

For Python type checking, run mypy manually (not auto-configured):

```bash
mypy <file.py>
```

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

```lua
return {
  "author/plugin-name",
  event = "BufReadPre",  -- or lazy = false, cmd = {...}
  dependencies = { "dep1", "dep2" },
  config = function()
    -- setup code here
  end,
}
```

### Local Custom Plugins

For hand-crafted plugins stored in `lua/andrew/custom/plugins/`, use `"local"` as the first field to prevent lazy.nvim from attempting to clone from GitHub:

```lua
-- lua/andrew/custom/plugins/terminal.lua
return {
  "local",  -- NOT "user/repo" - this prevents cloning
  name = "floating-terminal",
  ft = "floating_terminal",
  init = function()
    -- initialization code
  end,
  config = function()
    -- configuration code
  end,
}
```

**Why:** lazy.nvim interprets strings matching `user/repo` pattern as GitHub repository URLs. Using `"local"` tells lazy.nvim this is a local-only plugin with no remote repository.

### Loading Local Modules vs Plugin Specs

For local Lua modules that should load after lazy.nvim initializes, require them directly in `init.lua` after `require("andrew.lazy")`:

```lua
-- init.lua
require("andrew.core")
require("andrew.lazy")
require("andrew.custom.plugins.terminal")  -- Load as regular module

vim.opt.termguicolors = true
```

**Do NOT use the `User LazyDone` autocmd pattern** for loading local modules - it can cause timing issues where plugins like nvim-treesitter run their config before all lazy plugins are loaded.

### Troubleshooting Local Plugin Issues

**Problem:** lazy.nvim attempts to clone a local plugin with `"local"` spec:

```
Failed (1)
○ floating-terminal ■ clone failed
fatal: repository '/home/ans18010/.local/share/nvim/lazy/floating-terminal' does not exist
```

**Solution:** Clean stale lazy state:
```bash
rm -rf ~/.local/share/nvim/lazy/floating-terminal*
rm -f ~/.local/share/nvim/lazy-lock.json
```

Then restart Neovim.

### Neovim API Common Mistakes

**`nvim_open_win` options:** Some options like `winblend` and `zindex` are window **options**, not window creation options. Use `nvim_open_win` for creation, then `nvim_win_set_option` for these:

```lua
-- Bad: winblend is not a valid creation option
local opts = {
  relative = "editor",
  winblend = 10,  -- ERROR: invalid key
  zindex = 50,    -- ERROR: invalid key
}
vim.api.nvim_open_win(bufnr, enter, opts)

-- Good: set after creation
local opts = {
  relative = "editor",
  -- only valid creation options here
}
vim.api.nvim_open_win(bufnr, enter, opts)
vim.api.nvim_win_set_option(winid, "winblend", 10)
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

- **Python**: Uses `ruff` for linting, `ruff format` for formatting, `pylsp` for LSP
- **Rust**: Uses `rust_analyzer` with `clippy` on save, `rustfmt` for formatting
- **Lua**: Uses `lua_ls` from conda, `stylua` for formatting
- **Fortran**: Uses `fortls` from conda

## Development Workflow

1. Make changes to Lua files in `lua/andrew/`
2. Reload Neovim configuration: `:source ~/.config/nvim/init.lua`
3. Restart lazy.nvim: `:Lazy reload` (after changes to plugin specs)
4. Test formatting/linting behavior by saving files

## External Tools (Conda)

The config assumes these tools are installed in a conda environment:

```bash
# Conda packages needed
conda install -c conda-forge \
  lua-language-server stylua \
  ruff flake8 pylint mypy \
  nodejs eslint \
  cppcheck \
  rust rust-src \
  lfortran gfortran
```

Ensure `$HOME/miniconda3/bin` is in PATH when running Neovim.

## OpenCode Best Practices

### Planning Before Building

- Use **Plan mode** (Tab key) for analyzing code and reviewing suggestions before making changes
- Plan mode disables file edits and bash commands by default, set to `ask`
- Switch back to **Build mode** (Tab key) when ready to implement changes

### Undo/Redo

- Use `/undo` to revert changes if they don't match expectations
- Run `/undo` multiple times to undo multiple changes
- Use `/redo` to reapply changes after undoing

### Providing Context

- Use `@` syntax to reference specific files when asking for changes:
  ```
  How is LSP configured in @lua/andrew/plugins/lsp/lspconfig.lua
  ```
- Provide enough detail so the agent understands the task
- Talk to the agent like you're talking to a junior developer on your team

### Complex Tasks

- Use `todowrite` to track progress during multi-step tasks
- Break down complex operations into smaller, manageable steps
- Mark tasks complete immediately after finishing

### Subagents

- Use `@explore` for quickly finding files by patterns or searching code
- Use `@general` for complex research questions requiring multiple steps
- Agents can invoke subagents automatically for specialized tasks

### Neovim Help Research

- ALWAYS spawn a subagent to investigate Neovim `:help` during planning/research phase
- Search `:help` for any Neovim configuration options, functions, or APIs being used
- Example subagent invocation:
  ```
  @general research the vim.keymap.set() function and its options via :help
  ```
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
- When researching plugin APIs, spawn a subagent to explore:
  ```
  @general research conform.nvim setup options in ~/.local/share/nvim/lazy/conform.nvim/doc/
  ```
- Always check the plugin's `README.md` and `:help` documentation before implementing configurations

### Tool Usage Patterns

- **Always read a file before editing it** - the edit tool requires prior context
- **Batch related operations** when possible for efficiency
- Use `glob` to find files before using `ripgrep` or `read`
- Use `ripgrep` (`rg`) for content search before reading specific files

### Asking Questions

- Use the `question` tool to gather user preferences when requirements are unclear
- Offer choices to the user about implementation direction
- Ask for clarification when instructions are ambiguous

### AGENTS.md

- Use `opencode.json` with `instructions` field to reference external guideline files
- Modularize rules by referencing external files (e.g., `@docs/guidelines.md`)
