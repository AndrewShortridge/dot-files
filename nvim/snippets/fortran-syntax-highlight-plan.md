# Plan: Lua-Based Dynamic Syntax Highlighting for Fortran Keywords

## Overview

Extend the existing `andrew.fortran.docs` module to provide syntax highlighting for all documented keywords, reading dynamically from `fortran-docs.json`.

## Architecture

```
Neovim opens Fortran file
         ↓
FileType autocmd triggers
         ↓
Lua loads keywords from fortran-docs.json (cached)
         ↓
Creates syntax match rules for each keyword
         ↓
Links matches to highlight groups
         ↓
Keywords are highlighted in buffer
```

---

## Implementation Steps

### Step 1: Extend the Docs Module with Keyword List

**File**: `~/.config/nvim/lua/andrew/fortran/docs.lua`

Add a function to return all keyword names (not the full documentation):

```lua
-- Get list of all documented keywords
function M.keywords()
  local docs = M.load()
  local keys = {}
  for k, _ in pairs(docs) do
    table.insert(keys, k)
  end
  return keys
end
```

---

### Step 2: Create Syntax Highlighting Module

**File**: `~/.config/nvim/lua/andrew/fortran/highlight.lua`

```lua
local M = {}

local docs = require("andrew.fortran.docs")

-- Define highlight groups for different keyword categories
-- Customize colors/links as desired
function M.setup_highlights()
  -- Link to existing highlight groups or define custom ones
  vim.api.nvim_set_hl(0, "FortranCustomKeyword", { link = "Function" })
  vim.api.nvim_set_hl(0, "FortranMPIKeyword", { link = "Constant" })
  vim.api.nvim_set_hl(0, "FortranOMPKeyword", { link = "PreProc" })
end

-- Categorize a keyword based on its name
local function categorize(keyword)
  if keyword:match("^mpi") or keyword:match("^MPI") then
    return "FortranMPIKeyword"
  elseif keyword:match("^omp") or keyword:match("^OMP") then
    return "FortranOMPKeyword"
  else
    return "FortranCustomKeyword"
  end
end

-- Apply syntax matches for all documented keywords
function M.apply(bufnr)
  bufnr = bufnr or 0
  local keywords = docs.keywords()

  for _, kw in ipairs(keywords) do
    local group = categorize(kw)
    -- Use \< and \> for word boundaries
    -- Case insensitive with \c
    local pattern = string.format("\\c\\<%s\\>", vim.fn.escape(kw, "\\"))
    vim.cmd(string.format(
      "syntax match %s /%s/ containedin=ALL",
      group, pattern
    ))
  end
end

return M
```

---

### Step 3: Create Autocmd to Apply Highlighting

**File**: `~/.config/nvim/lua/andrew/fortran/init.lua`

```lua
local M = {}

function M.setup()
  local highlight = require("andrew.fortran.highlight")

  -- Setup highlight groups once
  highlight.setup_highlights()

  -- Apply syntax matches when opening Fortran files
  vim.api.nvim_create_autocmd("FileType", {
    pattern = { "fortran", "fortran_fixed", "fortran_free", "f90", "f95" },
    group = vim.api.nvim_create_augroup("FortranCustomHighlight", { clear = true }),
    callback = function(ev)
      -- Defer slightly to ensure syntax is loaded first
      vim.defer_fn(function()
        highlight.apply(ev.buf)
      end, 10)
    end,
  })
end

return M
```

---

### Step 4: Initialize the Module

**Option A**: Add to existing plugin file

Add to `~/.config/nvim/lua/andrew/plugins/lsp/lspconfig.lua` at the end of the config function:

```lua
-- Initialize Fortran custom highlighting
require("andrew.fortran").setup()
```

**Option B**: Create standalone plugin file

**File**: `~/.config/nvim/lua/andrew/plugins/fortran-syntax.lua`

```lua
return {
  -- Virtual plugin for Fortran custom syntax
  dir = vim.fn.stdpath("config"),
  name = "fortran-custom-syntax",
  ft = { "fortran", "fortran_fixed", "fortran_free", "f90", "f95" },
  config = function()
    require("andrew.fortran").setup()
  end,
}
```

Then add to your plugins init.lua.

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `~/.config/nvim/lua/andrew/fortran/docs.lua` | Modify | Add `keywords()` function |
| `~/.config/nvim/lua/andrew/fortran/highlight.lua` | Create | Syntax matching logic |
| `~/.config/nvim/lua/andrew/fortran/init.lua` | Create | Module setup and autocmd |
| `~/.config/nvim/lua/andrew/plugins/lsp/lspconfig.lua` | Modify | Initialize the module (Option A) |

---

## Customization Options

### Custom Colors

In `highlight.lua`, define your own colors instead of linking:

```lua
vim.api.nvim_set_hl(0, "FortranMPIKeyword", {
  fg = "#61afef",  -- blue
  bold = true
})
```

### Additional Categories

Add more pattern matching in `categorize()`:

```lua
if keyword:match("^dgemm") or keyword:match("^blas") then
  return "FortranBLASKeyword"
elseif keyword:match("^lapack") then
  return "FortranLAPACKKeyword"
end
```

---

## Verification Steps

1. **Check keywords are loaded**:
   ```vim
   :lua print(vim.inspect(require("andrew.fortran.docs").keywords()))
   ```

2. **Check highlight groups exist**:
   ```vim
   :highlight FortranCustomKeyword
   :highlight FortranMPIKeyword
   ```

3. **Test in Fortran file**:
   - Open a `.f90` file
   - Type a documented keyword (e.g., `bindc`, `mpi_send`)
   - Verify it's highlighted

4. **Check applied syntax rules**:
   ```vim
   :syntax list FortranCustomKeyword
   ```

---

## Rollback Plan

Delete the new files and remove the `require("andrew.fortran").setup()` line:

```bash
rm ~/.config/nvim/lua/andrew/fortran/highlight.lua
rm ~/.config/nvim/lua/andrew/fortran/init.lua
```
