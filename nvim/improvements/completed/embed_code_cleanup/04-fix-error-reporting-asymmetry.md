# Implementation Plan: Fix Error Reporting Asymmetry Between Image and Note Embeds

## Problem

| Error Scenario | Image Embed | Note Embed |
|---|---|---|
| File not found | `vim.notify()` (WARN) | Virtual text only, neutral highlight |
| Heading/block not found | N/A | Virtual text, content highlight (not visually distinct) |
| Nested note not found | N/A | Silent `[Not found: ...]` in content highlight |

Image failures are invisible without notification. Note failures are already visible as virtual text but use neutral highlighting that doesn't stand out.

## Design Decision

1. **Keep** virtual text for note errors (superior UX -- in-place, contextual)
2. **Add** a distinct error highlight group so note-not-found stands out visually
3. **Do NOT add** per-error `vim.notify()` for notes (the summary already reports `N error(s)`)
4. **Count** nested errors in `stats.errors` for the summary

## Changes

### Change 1: Add `VaultEmbedError` highlight group

**File:** `lua/andrew/vault/colors.lua`

Add `embed_error` to each palette (reuse cycle red):
```lua
embed_error = "#e06060",   -- default palette
embed_error = "#BA7184",   -- kanagawa palette
embed_error = "#E78284",   -- catppuccin palette
```

Add highlight definition (after line 279):
```lua
VaultEmbedError = { italic = true, fg = p.embed_error },
```

### Change 2: Use error highlight for top-level not-found (line 489)

**Before:**
```lua
{ string.rep("─", 2) .. " ![[" .. inner .. "]] (not found) " .. string.rep("─", 20), border_hl },
```

**After:**
```lua
{ string.rep("─", 2) .. " ![[" .. inner .. "]] (not found) " .. string.rep("─", 20), "VaultEmbedError" },
```

### Change 3: Use error highlight for nested error content lines (lines 465-474)

**Before:**
```lua
for _, cl in ipairs(content) do
  if cl:find("^↻ cycle:") then
    virt_lines[#virt_lines + 1] = { { "  " .. cl, cycle_hl } }
  elseif cl:find("^⋯ %(max embed depth") then
    virt_lines[#virt_lines + 1] = { { "  " .. cl, depth_hl } }
  elseif cl:find("^⋯ %(total line limit") or cl:find("^⋯ %(truncated") then
    virt_lines[#virt_lines + 1] = { { "  " .. cl, truncated_hl } }
  else
    virt_lines[#virt_lines + 1] = { { "  " .. cl, content_hl } }
  end
end
```

**After:**
```lua
local error_hl = "VaultEmbedError"
for _, cl in ipairs(content) do
  if cl:find("^↻ cycle:") then
    virt_lines[#virt_lines + 1] = { { "  " .. cl, cycle_hl } }
  elseif cl:find("^⋯ %(max embed depth") then
    virt_lines[#virt_lines + 1] = { { "  " .. cl, depth_hl } }
  elseif cl:find("^⋯ %(total line limit") or cl:find("^⋯ %(truncated") then
    virt_lines[#virt_lines + 1] = { { "  " .. cl, truncated_hl } }
  elseif cl:find("^%[.+ not found:") or cl:find("^%[Could not read file%]") then
    virt_lines[#virt_lines + 1] = { { "  " .. cl, error_hl } }
  else
    virt_lines[#virt_lines + 1] = { { "  " .. cl, content_hl } }
  end
end
```

The pattern `^%[.+ not found:` matches:
- `[Block not found: ^...]` (line 123)
- `[Heading not found: #...]` (line 126)
- `[Not found: ...]` (line 298)

### Change 4: Count nested errors in stats (after line 452)

After the `resolve_embed_lines` call, before building virtual lines:

```lua
for _, cl in ipairs(content) do
  if cl:find("^%[.+ not found:") or cl:find("^%[Could not read file%]") then
    stats.errors = stats.errors + 1
  end
end
```

## Files Modified

| File | Changes |
|------|---------|
| `colors.lua` | Add `embed_error` palette entries + `VaultEmbedError` highlight |
| `embed.lua` | Error highlight for not-found (line 489), error detection in content loop (lines 465-474), nested error counting (after line 452) |

~10 lines of new/changed code across 2 files.
