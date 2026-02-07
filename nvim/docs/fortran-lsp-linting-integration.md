# Fortran LSP + Linting Integration Guide

This guide explains how to combine compiler-based linting (for type checking and diagnostics) with the Fortran Language Server (for code intelligence features) in Neovim.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Fortran Development in Neovim                        │
├─────────────────────────────────────┬───────────────────────────────────────┤
│         LINTING (nvim-lint)         │           LSP (fortls)                │
├─────────────────────────────────────┼───────────────────────────────────────┤
│ • Full type checking                │ • Go-to-definition                    │
│ • Rank/shape errors                 │ • Autocomplete                        │
│ • Interface mismatches              │ • Hover documentation                 │
│ • Argument type errors              │ • Find references                     │
│ • Implicit typing violations        │ • Rename symbol                       │
│ • Compiler-specific warnings        │ • Document symbols                    │
├─────────────────────────────────────┼───────────────────────────────────────┤
│ Triggers: BufWritePost, InsertLeave │ Triggers: Real-time (as you type)    │
│ Backend: gfortran, ifort, ifx       │ Backend: fortls language server       │
└─────────────────────────────────────┴───────────────────────────────────────┘
```

**Why both?**
- **fortls** provides instant code intelligence but has limited semantic analysis
- **Compiler linting** provides comprehensive type checking but only on save
- Together, they provide a complete IDE experience

---

## Step 1: Install fortls

### Option A: Via Conda (Recommended)
```bash
conda install -c conda-forge fortls
```

### Option B: Via pip
```bash
pip install fortls
```

### Option C: Via Mason (in Neovim)
Add `"fortls"` to `mason-lspconfig` ensure_installed list in `mason.lua`:

```lua
ensure_installed = {
  "lua_ls",
  "fortls",  -- Add this line
  -- ... other servers
},
```

### Verify Installation
```bash
fortls --version
```

---

## Step 2: Configure fortls in lspconfig.lua

Your current configuration is already set up. Here's what each option does:

```lua
-- Location: lua/andrew/plugins/lsp/lspconfig.lua (lines 411-454)

vim.lsp.config("fortls", {
  -- Path to fortls executable
  cmd = { vim.fn.expand("$CONDA_PREFIX/bin/fortls") },

  -- Supported file types
  filetypes = { "fortran", "fortran_fixed", "fortran_free", "f90", "f95" },

  -- How to find project root
  root_markers = { ".git", ".fortls", "code" },

  init_options = {
    -- =========================================================================
    -- Hover & Signature Help (Documentation Features)
    -- =========================================================================
    hoverSignature = true,         -- Show function signature in hover popup
    variableHover = true,          -- Show variable type/info on hover
    signatureHelp = true,          -- Enable signature help (Ctrl-K)

    -- =========================================================================
    -- Autocomplete Settings
    -- =========================================================================
    autocompleteSignature = true,  -- Include signatures in completion
    autocompleteNoPrefix = true,   -- Show completions without typing prefix
    autoTyping = true,             -- Auto-insert common patterns
    sortKeywords = true,           -- Sort keywords alphabetically

    -- =========================================================================
    -- Workspace Configuration (CRITICAL for multi-file projects)
    -- =========================================================================
    source_dirs = { "code" },      -- Directories to scan for source files
    include_dirs = { "code" },     -- Directories to search for modules

    -- =========================================================================
    -- Diagnostics (fortls provides basic diagnostics)
    -- =========================================================================
    disable_diagnostics = false,   -- Keep fortls diagnostics enabled
    enable_code_actions = true,    -- Allow fortls to suggest fixes
    max_line_length = 132,         -- Fortran free-form standard
    max_comment_line_length = 132,

    -- =========================================================================
    -- Performance
    -- =========================================================================
    notify_init = true,            -- Notify when workspace scan completes
    incremental_sync = true,       -- Sync only changed parts of files
  },
})

-- Enable the server
vim.lsp.enable("fortls")
```

---

## Step 3: Configure Project-Level Settings (.fortls file)

Create a `.fortls` file in your project root for project-specific settings:

```json
{
  "source_dirs": ["code", "src", "lib"],
  "include_dirs": ["code", "include", "modules"],
  "excl_paths": ["build", "test/fixtures"],
  "excl_suffixes": [".mod", ".o", ".a"],
  "pp_defs": {
    "DEBUG": "",
    "USE_MPI": ""
  },
  "incl_fixed": ["*.f", "*.F", "*.for"],
  "incl_free": ["*.f90", "*.F90", "*.f95", "*.f03", "*.f08"]
}
```

### Configuration Options Reference

| Option | Type | Description |
|--------|------|-------------|
| `source_dirs` | string[] | Directories containing source files to index |
| `include_dirs` | string[] | Directories to search for `USE` and `INCLUDE` |
| `excl_paths` | string[] | Paths to exclude from indexing |
| `excl_suffixes` | string[] | File extensions to exclude |
| `pp_defs` | object | Preprocessor definitions (for `#ifdef` blocks) |
| `incl_fixed` | string[] | Glob patterns for fixed-form files |
| `incl_free` | string[] | Glob patterns for free-form files |

---

## Step 4: Configure Compiler Linting (linting.lua)

Your linting configuration handles type checking. Here's the key integration:

```lua
-- Location: lua/andrew/plugins/linting.lua

-- Linters run on these events (complement LSP's real-time feedback)
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "InsertLeave" }, {
  group = vim.api.nvim_create_augroup("FortranLinting", { clear = true }),
  callback = function()
    local ft = vim.bo.filetype
    if ft == "fortran" or ft == "fortran_free" or ft == "fortran_fixed" then
      -- Update include paths based on project structure
      update_fortran_linter_args()
    end
    require("lint").try_lint()
  end,
})
```

### How Diagnostics Merge

Both fortls and the compiler linter push diagnostics to `vim.diagnostic`. Neovim automatically merges them:

```
┌─────────────────────────────────────────────────────────────────┐
│                     vim.diagnostic system                        │
├─────────────────────────────────────────────────────────────────┤
│  fortls diagnostics (namespace: vim.lsp.diagnostic)             │
│  • Duplicate variables                                          │
│  • Unknown modules                                               │
│  • Scope errors                                                  │
├─────────────────────────────────────────────────────────────────┤
│  gfortran diagnostics (namespace: vim.diagnostic from nvim-lint)│
│  • Type mismatches                                               │
│  • Rank errors                                                   │
│  • Interface violations                                          │
│  • All compiler warnings/errors                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Step 5: Keybindings Reference

Your LSP keybindings (from `lspconfig.lua`) work with fortls:

| Keybinding | Action | Provider |
|------------|--------|----------|
| `gd` | Go to definition | fortls |
| `gD` | Go to declaration (falls back to definition) | fortls |
| `gR` | Show references | fortls |
| `gi` | Show implementations | fortls |
| `gt` | Show type definitions | fortls |
| `K` | Hover documentation | fortls |
| `<C-k>` | Signature help | fortls |
| `<leader>rn` | Rename symbol | fortls |
| `<leader>ca` | Code actions | fortls |
| `<leader>d` | Line diagnostics | Both (merged) |
| `<leader>D` | Buffer diagnostics | Both (merged) |
| `[d` / `]d` | Navigate diagnostics | Both (merged) |
| `<leader>ll` | Manual lint | Compiler |
| `<leader>lf` | Toggle Fortran linter | Compiler |
| `<leader>lw` | Lint workspace | Compiler |

---

## Step 6: Verify the Integration

### Check fortls is Running
```vim
:LspInfo
```

You should see:
```
Client: fortls (id: X)
  filetypes:       fortran, fortran_fixed, fortran_free
  root directory:  /path/to/your/project
  cmd:             /path/to/fortls
```

### Check Linting is Working
```vim
:lua print(vim.inspect(require("lint").linters_by_ft.fortran))
```

Should output:
```lua
{ "gfortran" }  -- or "mpiifx" depending on your toggle
```

### Test Each Feature

1. **Autocomplete**: Type `CALL ` and wait for suggestions
2. **Hover**: Press `K` on a function name
3. **Go-to-definition**: Press `gd` on a subroutine call
4. **Find references**: Press `gR` on a variable
5. **Rename**: Press `<leader>rn` on a variable name
6. **Type checking**: Save file and check for compiler diagnostics

---

## Step 7: Troubleshooting

### fortls Not Starting

1. Check executable path:
   ```vim
   :lua print(vim.fn.executable(vim.fn.expand("$CONDA_PREFIX/bin/fortls")))
   ```
   Should print `1`.

2. Check LSP logs:
   ```vim
   :lua vim.cmd('e ' .. vim.lsp.get_log_path())
   ```

3. Manually test fortls:
   ```bash
   fortls --help
   ```

### No Completions Appearing

1. Verify `source_dirs` includes your code directory
2. Check if fortls indexed your files:
   ```vim
   :LspLog
   ```
   Look for "Indexing complete" message.

3. Ensure files are saved (fortls indexes from disk)

### Diagnostics Not Showing

**For fortls diagnostics:**
- Check `disable_diagnostics` is `false`

**For compiler diagnostics:**
- Check compiler is installed: `which gfortran`
- Run manual lint: `<leader>ll`
- Debug with: `<leader>lF`

### Duplicate Diagnostics

If you see duplicate errors from both fortls and the compiler:

```lua
-- Option 1: Disable fortls diagnostics (rely on compiler only)
init_options = {
  disable_diagnostics = true,
  -- ... other options
}

-- Option 2: Keep both (they catch different things)
-- This is the recommended approach
```

---

## Step 8: Advanced Configuration

### Custom Hover Handler for Fortran

Add Fortran-specific hover title:

```lua
-- In lspconfig.lua, inside the LspAttach callback:
if vim.bo[ev.buf].filetype:match("^fortran") then
  opts.desc = "Show Fortran documentation"
  keymap.set("n", "K", function()
    vim.b.lsp_popup_kind = "hover"
    vim.b.lsp_popup_title = "Fortran Documentation"
    vim.lsp.buf.hover()
  end, opts)
end
```

### Disable LSP Diagnostics for Fortran (Use Only Compiler)

If you prefer compiler-only diagnostics:

```lua
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if client and client.name == "fortls" then
      -- Disable fortls diagnostics, keep other features
      client.server_capabilities.diagnosticProvider = nil
    end
  end,
})
```

### Per-Project Compiler Selection

Read compiler from `.fortls` file:

```lua
local function get_project_compiler()
  local fortls_file = vim.fn.findfile(".fortls", ".;")
  if fortls_file ~= "" then
    local content = vim.fn.readfile(fortls_file)
    local ok, config = pcall(vim.json.decode, table.concat(content, "\n"))
    if ok and config.linter then
      return config.linter  -- e.g., "gfortran" or "ifort"
    end
  end
  return "gfortran"  -- default
end
```

---

## Summary: How Features Map to Components

| Feature | Component | File |
|---------|-----------|------|
| Go-to-definition | fortls (LSP) | lspconfig.lua |
| Autocomplete | fortls (LSP) | lspconfig.lua |
| Hover documentation | fortls (LSP) | lspconfig.lua |
| Find references | fortls (LSP) | lspconfig.lua |
| Rename symbol | fortls (LSP) | lspconfig.lua |
| Signature help | fortls (LSP) | lspconfig.lua |
| Type checking | gfortran/ifort (Linter) | linting.lua |
| Compiler warnings | gfortran/ifort (Linter) | linting.lua |
| Interface errors | gfortran/ifort (Linter) | linting.lua |
| Duplicate variables | fortls (LSP) | lspconfig.lua |
| Unknown modules | Both | Both |

---

## Files Modified

| File | Purpose |
|------|---------|
| `lua/andrew/plugins/lsp/lspconfig.lua` | fortls configuration, keybindings |
| `lua/andrew/plugins/lsp/mason.lua` | Optional: auto-install fortls |
| `lua/andrew/plugins/linting.lua` | Compiler-based linting |
| `.fortls` (project root) | Project-specific fortls settings |

---

## Quick Start Checklist

- [ ] fortls installed (`conda install -c conda-forge fortls`)
- [ ] fortls configured in `lspconfig.lua` (already done)
- [ ] fortls enabled with `vim.lsp.enable("fortls")` (already done)
- [ ] `.fortls` file created in project root with `source_dirs`
- [ ] Compiler (gfortran/ifort) installed for linting
- [ ] Linting configured in `linting.lua` (already done)
- [ ] Test: Open Fortran file, check `:LspInfo` shows fortls attached
- [ ] Test: Press `gd` on a subroutine call to verify go-to-definition
- [ ] Test: Save file and verify compiler diagnostics appear
