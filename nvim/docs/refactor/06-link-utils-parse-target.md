# Feature 06: Create `link_utils` Module + `parse_target()`

## Dependencies
- **None** — new shared module.
- **Depended on by:** Feature 07 (heading_to_slug), Feature 08 (wikilink-under-cursor), Feature 09 (read_heading_section / read_block_content), Feature 10 (resolve_link consolidation)

## Problem
The parsing of wikilink inner content `name#heading^block-id|alias` is implemented 5+ times:
- `embed.lua:147-172` (`parse_embed_target`) — nested match cascade for name/heading/block_id
- `export.lua:179-204` (`parse_target`) — identical structure
- `wikilinks.lua:148-164` (inside `get_wikilink_details_under_cursor`) — same parse inline
- `linkcheck.lua:93-115` (`extract_links`) — same `gsub("\\|","|")` + `match("^([^|]+)")` + heading split
- `linkcheck.lua:229-241` (inline in `check_vault`) — copy of the same parsing
- `linkdiag.lua:194-209` (`parse_wikilink`) — same logic as a named function
- `graph.lua:127` — partial version (name-only extraction)

Also, the `\\|` pipe escape normalization (`inner:gsub("\\|", "|")`) appears 6+ times across wikilinks.lua, linkcheck.lua, linkdiag.lua, graph.lua, export.lua.

## Files to Modify
1. **CREATE** `lua/andrew/vault/link_utils.lua` — New shared module
2. `lua/andrew/vault/embed.lua` — Import and use `link_utils.parse_target`
3. `lua/andrew/vault/export.lua` — Import and use `link_utils.parse_target`
4. `lua/andrew/vault/wikilinks.lua` — Import and use in `get_wikilink_details_under_cursor`
5. `lua/andrew/vault/linkcheck.lua` — Import and use (2 call sites)
6. `lua/andrew/vault/linkdiag.lua` — Import and use, delete local `parse_wikilink`
7. `lua/andrew/vault/graph.lua` — Import and use for name extraction

## Implementation Steps

### Step 1: Create `lua/andrew/vault/link_utils.lua`

```lua
local M = {}

--- Parse the inner content of a wikilink [[inner]].
--- Handles: name, name#heading, name^block, name#heading^block, name|alias, and combinations.
--- Normalizes escaped pipes (\\|).
--- @param inner string  The text between [[ and ]]
--- @return { name: string, heading: string|nil, block_id: string|nil, alias: string|nil }
function M.parse_target(inner)
  -- Normalize escaped pipes
  inner = inner:gsub("\\|", "\0PIPE\0")

  -- Extract alias (after |)
  local target_part, alias = inner:match("^(.+)|(.+)$")
  if not target_part then
    target_part = inner
  end

  -- Restore pipes in alias
  if alias then alias = alias:gsub("\0PIPE\0", "|") end
  target_part = target_part:gsub("\0PIPE\0", "|")

  -- Parse name#heading^block_id
  local name, heading, block_id

  -- Try all combinations
  local n, h, b = target_part:match("^([^#%^]+)#([^%^]+)%^(.+)$")
  if n then
    name, heading, block_id = n, h, b
  else
    n, b = target_part:match("^([^#%^]+)%^(.+)$")
    if n then
      name, block_id = n, b
    else
      n, h = target_part:match("^([^#%^]+)#(.+)$")
      if n then
        name, heading = n, h
      else
        name = target_part
      end
    end
  end

  return {
    name = vim.trim(name or ""),
    heading = heading and vim.trim(heading) or nil,
    block_id = block_id and vim.trim(block_id) or nil,
    alias = alias and vim.trim(alias) or nil,
  }
end

--- Extract just the note name from wikilink inner content.
--- Strips heading, block_id, and alias components.
--- @param inner string
--- @return string
function M.link_name(inner)
  return M.parse_target(inner).name
end

return M
```

### Step 2: Update embed.lua

Delete `parse_embed_target` (lines 147-172). Replace calls with:
```lua
local link_utils = require("andrew.vault.link_utils")
-- ...
local parsed = link_utils.parse_target(target)
local name = parsed.name
local heading = parsed.heading
local block_id = parsed.block_id
```

### Step 3: Update export.lua

Delete `parse_target` (lines 179-204). Replace calls with:
```lua
local link_utils = require("andrew.vault.link_utils")
local parsed = link_utils.parse_target(inner)
```

### Step 4: Update wikilinks.lua

In `get_wikilink_details_under_cursor` (lines 125-174), replace the inline parsing at lines 148-164 with a call to `link_utils.parse_target(inner)`. The function already returns a table with `name`, `heading`, `block_id`, `alias` — map the parse_target result directly.

### Step 5: Update linkcheck.lua

- Delete inline parsing in `extract_links` (lines 93-115) — replace the inner parse with `link_utils.parse_target(inner)`
- Delete inline parsing in `check_vault` (lines 229-241) — same replacement
- Remove all `inner:gsub("\\|", "|")` calls (handled by parse_target)

### Step 6: Update linkdiag.lua

Delete local `parse_wikilink` (lines 194-209). Replace calls with `link_utils.parse_target(inner)`.

### Step 7: Update graph.lua

Replace line 127 `local name = inner:match("^([^|#%^]+)") or inner` with:
```lua
local name = link_utils.link_name(inner)
```
Also remove the `inner:gsub("\\|", "|")` at line 124.

## Testing
- `gf` on a wikilink `[[Note#Heading]]` — follows to correct heading
- `gf` on `[[Note^block-id]]` — follows to correct block
- `gf` on `[[Note|Display Name]]` — follows to Note
- `VaultLinkCheck` — detects broken links with headings and blocks
- `VaultLinkDiag` — diagnostics show correct link targets
- `VaultEmbedRender` on `![[Note#Section]]` — renders correct section
- `VaultExport` with embeds — preprocesses correctly
- `VaultGraph` — forward links extracted correctly

## Estimated Impact
- **Lines removed:** ~100
- **Lines added:** ~45
- **Net reduction:** ~55 lines
- **Eliminates:** 6+ copies of pipe normalization, 5+ copies of target parsing
