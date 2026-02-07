# Plan: Custom blink.cmp Source for Fortran Keywords

## Overview

Create a custom blink.cmp completion source that provides autocompletions for all documented Fortran keywords from `fortran-docs.json`, complete with documentation preview.

## Architecture

```
User types in Fortran buffer
         ↓
blink.cmp triggers completion
         ↓
Custom source checks: is filetype Fortran?
    ├── NO  → Return no items (source disabled)
    └── YES → Load keywords from fortran-docs.json
         ↓
Return completion items with:
  - label (keyword name)
  - kind (Function/Constant based on category)
  - documentation (from fortran-docs.json)
         ↓
blink.cmp displays in completion menu
```

---

## Implementation Steps

### Step 1: Create the Custom Source Module

**File**: `~/.config/nvim/lua/andrew/fortran/blink-source.lua`

```lua
-- Custom blink.cmp source for Fortran keywords
-- Provides completions from fortran-docs.json

local docs = require("andrew.fortran.docs")

local source = {}

-- Constructor
function source.new(opts)
  local self = setmetatable({}, { __index = source })
  self.opts = opts or {}
  return self
end

-- Only enable for Fortran filetypes
function source:enabled()
  local ft = vim.bo.filetype
  return ft == "fortran"
    or ft:match("^fortran")
    or ft == "f90"
    or ft == "f95"
end

-- Categorize keyword for completion kind
local function get_kind(keyword)
  -- Use LSP CompletionItemKind values
  -- 3 = Function, 6 = Variable, 14 = Keyword, 21 = Constant
  if keyword:match("^mpi") or keyword:match("^MPI") then
    return 3  -- Function (MPI calls)
  elseif keyword:match("^omp") or keyword:match("^OMP") then
    return 14 -- Keyword (OpenMP directives)
  else
    return 3  -- Function (default for intrinsics/subroutines)
  end
end

-- Main completion function
function source:get_completions(ctx, callback)
  local items = {}
  local keywords = docs.keywords()
  local all_docs = docs.load()

  for _, kw in ipairs(keywords) do
    local doc_text = all_docs[kw] or ""
    table.insert(items, {
      label = kw,
      kind = get_kind(kw),
      documentation = {
        kind = "markdown",
        value = doc_text,
      },
      -- Optional: add insertText if different from label
      -- insertText = kw,
    })
  end

  callback({
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = items,
  })
end

-- Optional: Lazy-load documentation (if docs are expensive to load)
-- Not needed here since docs are cached, but shown for reference
function source:resolve(item, callback)
  -- Documentation is already included, just return the item
  callback(item)
end

return source
```

---

### Step 2: Register Source in blink.cmp Configuration

**File**: `~/.config/nvim/lua/andrew/plugins/blink-cmp.lua`

Modify the `sources` section to add the custom provider:

```lua
sources = {
  default = { "lsp", "path", "snippets", "buffer", "fortran_docs" },

  -- Filetype-specific: prioritize fortran_docs for Fortran files
  per_filetype = {
    fortran = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
    ["fortran.fixed"] = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
    ["fortran.free"] = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
    f90 = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
    f95 = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
  },

  providers = {
    fortran_docs = {
      name = "FortranDocs",
      module = "andrew.fortran.blink-source",
      -- Only show after typing 2+ characters
      min_keyword_length = 2,
      -- Boost score so these appear prominently
      score_offset = 10,
      -- Optional: custom options passed to source.new()
      opts = {},
    },
  },
},
```

---

### Step 3: Add Source Label to Menu (Optional Enhancement)

In the `completion.menu.draw.columns` configuration, the source name will already show as "FortranDocs" due to the existing config:

```lua
columns = { { "kind_icon" }, { "label", "label_description", gap = 1 }, { "source_name" } },
```

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `~/.config/nvim/lua/andrew/fortran/blink-source.lua` | Create | Custom completion source |
| `~/.config/nvim/lua/andrew/plugins/blink-cmp.lua` | Modify | Register the source |

---

## Configuration Options

### Adjust Score Priority

Change `score_offset` to control where Fortran docs appear relative to other sources:
- Positive values: appear higher in list
- Negative values: appear lower
- `0`: default ordering

### Minimum Keyword Length

Adjust `min_keyword_length` to control when completions trigger:
- `1`: show immediately on first character
- `2`: require 2 characters (reduces noise)
- `3`: more conservative triggering

### Fallback Behavior

Add fallbacks if no matches found:

```lua
providers = {
  fortran_docs = {
    -- ... other options
    fallbacks = { "lsp", "buffer" },
  },
},
```

---

## Completion Item Kinds

The source uses LSP CompletionItemKind values for proper icons:

| Category | Kind Value | Icon (typical) |
|----------|------------|----------------|
| MPI functions | 3 (Function) | ƒ |
| OpenMP directives | 14 (Keyword) | 󰌆 |
| Intrinsics/Other | 3 (Function) | ƒ |

Customize in `get_kind()` function if needed.

---

## Verification Steps

1. **Check source is registered**:
   ```vim
   :BlinkCmp status
   ```
   Look for "fortran_docs" in the providers list.

2. **Test in Fortran file**:
   - Open a `.f90` file
   - Type `mpi` and wait for completion menu
   - Verify "FortranDocs" items appear with documentation

3. **Check documentation preview**:
   - Select a completion item
   - Documentation should appear in preview window

4. **Test filtering**:
   - Type `dge` - should show `dgemm`
   - Type `alloc` - should show `allocate` variants

---

## Troubleshooting

### Source not appearing

1. Check filetype: `:echo &filetype`
2. Verify source is enabled: `:lua print(require("andrew.fortran.blink-source").new():enabled())`
3. Check for errors: `:messages`

### No documentation showing

1. Verify docs load: `:lua print(require("andrew.fortran.docs").get("dgemm"))`
2. Check `auto_show` is enabled in completion.documentation config

### Items not filtering correctly

blink.cmp handles filtering automatically - don't filter in the source. If items aren't matching, check the `label` field matches the keyword.

---

## Integration with Existing Features

This source integrates with the existing Fortran customizations:

| Feature | Source | Integration |
|---------|--------|-------------|
| Hover docs (K) | `fortran-docs.json` | Same JSON file |
| Syntax highlighting | `fortran-docs.json` | Same keywords |
| Completions | `fortran-docs.json` | Same data |

Adding a new keyword to `fortran-docs.json` automatically enables:
- Hover documentation
- Syntax highlighting
- Autocompletion with docs

---

## Rollback Plan

1. Remove `fortran_docs` from `sources.default` and `sources.per_filetype`
2. Remove the `providers.fortran_docs` entry
3. Delete `~/.config/nvim/lua/andrew/fortran/blink-source.lua`

The other completion sources (LSP, snippets) will continue working.
