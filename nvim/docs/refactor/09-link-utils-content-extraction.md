# Feature 09: `link_utils.read_heading_section()` / `link_utils.read_block_content()`

## Dependencies
- **Feature 06** (link_utils module must exist)
- **Feature 02** (engine.read_file_lines) — uses file reading utility
- **Depended on by:** Nothing directly

## Problem
Two content extraction functions are duplicated line-for-line between embed.lua and export.lua:

### 9a: `read_heading_section` — 2 identical copies
- `embed.lua:55-92` — reads a file, finds a heading by text match, captures lines until a same-or-higher-level heading
- `export.lua:93-131` — structurally identical, only error message differs (`"[Heading not found..."` vs `"*[Heading not found...*"`)

### 9b: `read_block_content` — 2 identical copies
- `embed.lua:98-138` — reads a file, splits into paragraphs, finds paragraph containing `^block-id`, strips block-id from output
- `export.lua:137-174` — structurally identical, only error message differs

## Files to Modify
1. `lua/andrew/vault/link_utils.lua` — Add both functions
2. `lua/andrew/vault/embed.lua` — Delete local versions, import from link_utils
3. `lua/andrew/vault/export.lua` — Delete local versions, import from link_utils

## Implementation Steps

### Step 1: Add `read_heading_section` to link_utils.lua

```lua
--- Read lines under a specific heading from a markdown file.
--- Returns lines from the heading through the next same-or-higher-level heading (exclusive).
--- @param path string  Absolute file path
--- @param heading string  Heading text to match (without # prefix)
--- @return string[]  Lines including the heading line itself
function M.read_heading_section(path, heading)
  local f = io.open(path, "r")
  if not f then return {} end

  local lines = {}
  local capturing = false
  local target_level = nil

  for line in f:lines() do
    if capturing then
      local level_str = line:match("^(#+)%s+")
      if level_str and #level_str <= target_level then
        break
      end
      lines[#lines + 1] = line
    else
      local level_str, text = line:match("^(#+)%s+(.*)")
      if text and vim.trim(text) == heading then
        target_level = #level_str
        capturing = true
        lines[#lines + 1] = line
      end
    end
  end

  f:close()

  -- Remove trailing blank lines
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end

  return lines
end
```

### Step 2: Add `read_block_content` to link_utils.lua

```lua
--- Read the paragraph containing a block reference (^block-id) from a file.
--- Returns the paragraph lines with the block-id marker stripped.
--- @param path string  Absolute file path
--- @param block_id string  Block ID (without ^ prefix)
--- @return string[]  Paragraph lines
function M.read_block_content(path, block_id)
  local f = io.open(path, "r")
  if not f then return {} end

  -- Collect paragraphs (separated by blank lines)
  local paragraphs = {}
  local current = {}
  for line in f:lines() do
    if line:match("^%s*$") then
      if #current > 0 then
        paragraphs[#paragraphs + 1] = current
        current = {}
      end
    else
      current[#current + 1] = line
    end
  end
  if #current > 0 then
    paragraphs[#paragraphs + 1] = current
  end
  f:close()

  -- Find paragraph containing the block reference
  local escaped = vim.pesc(block_id)
  for _, para in ipairs(paragraphs) do
    for _, line in ipairs(para) do
      if line:match("%^" .. escaped .. "%s*$") then
        -- Strip the block-id from the matching line
        local result = {}
        for _, l in ipairs(para) do
          result[#result + 1] = l:gsub("%s*%^" .. escaped .. "%s*$", "")
        end
        return result
      end
    end
  end

  return {}
end
```

### Step 3: Update embed.lua

Delete `read_heading_section` (lines 55-92) and `read_block_content` (lines 98-138).

```lua
local link_utils = require("andrew.vault.link_utils")

-- In render_embed or wherever these were called:
local section_lines = link_utils.read_heading_section(path, heading)
if #section_lines == 0 then
  -- embed-specific error handling
  lines = { "[Heading not found: #" .. heading .. "]" }
end

local block_lines = link_utils.read_block_content(path, block_id)
if #block_lines == 0 then
  lines = { "[Block not found: ^" .. block_id .. "]" }
end
```

Note: embed.lua returns styled error messages like `"[Could not read file]"` — keep the error wrapping in embed.lua, just use the empty-return check.

### Step 4: Update export.lua

Delete `read_heading_section` (lines 93-131) and `read_block_content` (lines 137-174).

```lua
local link_utils = require("andrew.vault.link_utils")

-- In the export preprocessor:
local section_lines = link_utils.read_heading_section(path, heading)
if #section_lines == 0 then
  return "*[Heading not found: #" .. heading .. "]*"
end

local block_lines = link_utils.read_block_content(path, block_id)
if #block_lines == 0 then
  return "*[Block not found: ^" .. block_id .. "]*"
end
```

Note: export.lua wraps error messages in `*italic*` markdown — keep that wrapping at the call site.

## Testing
- `VaultEmbedRender` on `![[Note#Heading]]` — verify heading section renders with correct lines
- `VaultEmbedRender` on `![[Note^block-id]]` — verify block content renders
- `VaultEmbedRender` on `![[Note#NonExistent]]` — verify error message appears
- `VaultExport` a file containing `![[Note#Section]]` — verify section inlined in export
- `VaultExport` a file containing `![[Note^blk-123]]` — verify block inlined in export
- Edge case: heading with sub-headings — verify only the section (not sibling sections) is captured
- Edge case: block-id on last line of file — verify paragraph captured correctly

## Estimated Impact
- **Lines removed:** ~70
- **Lines added:** ~50
- **Net reduction:** ~20 lines (the functions are moved, not eliminated, so savings come from removing the duplicate)
