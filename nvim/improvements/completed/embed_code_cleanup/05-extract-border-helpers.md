# Implementation Plan: Consolidate Border/Header Construction in embed.lua

## Problem

Four border line variants built with raw `string.rep` calls:

| Line | Purpose | Trailing dashes | Highlight |
|------|---------|----------------|-----------|
| 421-423 | Total line limit | 20 | `VaultEmbedTruncated` |
| 454-456 | Normal header | 40 | `border_hl` |
| 478 | Footer | 50 (full line) | `border_hl` |
| 489 | Not found | 20 | `border_hl` |

## Solution: Two Helper Functions

Place after `is_image_embed` (around line 60):

### `embed_header(inner, suffix)`

```lua
--- Build an embed header border line.
--- Example: "── ![[NoteName]] (not found) ─────────────────────"
---@param inner string  the text from between ![[  and ]]
---@param suffix string|nil  optional annotation like "(not found)" or "(total line limit)"
---@return string
local function embed_header(inner, suffix)
  local label = " ![[" .. inner .. "]]"
  if suffix then
    label = label .. " " .. suffix
  end
  label = label .. " "
  local prefix_w = 2
  local tail_w = math.max(4, 50 - prefix_w - vim.fn.strdisplaywidth(label))
  return string.rep("─", prefix_w) .. label .. string.rep("─", tail_w)
end
```

### `embed_footer()`

```lua
--- Build an embed footer border line.
---@return string
local function embed_footer()
  return string.rep("─", 50)
end
```

## Before/After for Each Call Site

### Site 1: Total line limit (lines 420-424)

```lua
-- Before:
{ string.rep("─", 2) .. " ![[" .. inner .. "]] (total line limit) " .. string.rep("─", 20), "VaultEmbedTruncated" }

-- After:
{ embed_header(inner, "(total line limit)"), "VaultEmbedTruncated" }
```

### Site 2: Normal header (lines 454-459)

```lua
-- Before:
local header_text = string.rep("─", 2) .. " ![[" .. inner .. "]] " .. string.rep("─", 40)
virt_lines[#virt_lines + 1] = { { header_text, border_hl } }

-- After:
virt_lines[#virt_lines + 1] = { { embed_header(inner), border_hl } }
```

### Site 3: Footer (lines 478-479)

```lua
-- Before:
local footer_text = string.rep("─", 50)
virt_lines[#virt_lines + 1] = { { footer_text, border_hl } }

-- After:
virt_lines[#virt_lines + 1] = { { embed_footer(), border_hl } }
```

### Site 4: Not found (lines 488-490)

```lua
-- Before:
{ string.rep("─", 2) .. " ![[" .. inner .. "]] (not found) " .. string.rep("─", 20), border_hl }

-- After:
{ embed_header(inner, "(not found)"), border_hl }
```

## Visual Width Improvement

Current code produces inconsistent total widths (48-56 chars depending on variant). The new helper targets a consistent 50-char width by adjusting tail dashes based on label length via `vim.fn.strdisplaywidth`.

## Files Modified

Only `lua/andrew/vault/embed.lua` -- add 2 helpers, update 4 call sites.
