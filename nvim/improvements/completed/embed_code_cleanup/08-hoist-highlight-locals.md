# Implementation Plan: Hoist Highlight Group Locals to Function Scope

## Problem

Three highlight group string constants are defined inside the note-embed `else` branch (lines 462-464), re-created on every iteration. They are pure constants that belong at function scope alongside `border_hl` and `content_hl` (lines 347-348).

## Change

### Before (lines 347-348, function scope):
```lua
local border_hl = "VaultEmbedBorder"
local content_hl = "VaultEmbedContent"
```

### Before (lines 462-464, inside loop):
```lua
local cycle_hl = "VaultEmbedCycle"
local depth_hl = "VaultEmbedDepth"
local truncated_hl = "VaultEmbedTruncated"
```

### After (lines 347-351, all at function scope):
```lua
local border_hl = "VaultEmbedBorder"
local content_hl = "VaultEmbedContent"
local cycle_hl = "VaultEmbedCycle"
local depth_hl = "VaultEmbedDepth"
local truncated_hl = "VaultEmbedTruncated"
```

Delete the former lines 462-464 entirely.

## Reference Audit

| Variable | Defined (current) | Used at | Safe to hoist? |
|---|---|---|---|
| `cycle_hl` | Line 462 | Line 467 | Yes |
| `depth_hl` | Line 463 | Line 469 | Yes |
| `truncated_hl` | Line 464 | Line 471 | Yes |

All are string constants used once each, always after definition, within the same function. No other code references these names.

## Risk

Zero. Mechanical scope change of string constants. No behavioral change.

## Files Modified

Only `lua/andrew/vault/embed.lua` -- move 3 lines from inner scope to function scope.
