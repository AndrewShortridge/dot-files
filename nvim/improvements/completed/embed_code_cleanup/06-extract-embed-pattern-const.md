# Implementation Plan: Extract Embed Pattern to Module-Level Constant

## Problem

The pattern `!%[%[.-%]%]` appears 5 times in embed.lua as a hardcoded string.

## Solution

Add a module-level constant after `IMAGE_EXTS` (around line 28):

```lua
-- Lua pattern matching ![[...]] embed syntax
local EMBED_PAT = "!%[%[.-%]%]"
```

## Changes

### Line 251 -- resolve_embed_lines, existence check
```lua
-- Before:
local has_embed = cline:find("!%[%[.-%]%]")
-- After:
local has_embed = cline:find(EMBED_PAT)
```

### Line 257 -- resolve_embed_lines, gsub strip
```lua
-- Before:
local test_line = cline:gsub("!%[%[.-%]%]", "")
-- After:
local test_line = cline:gsub(EMBED_PAT, "")
```

### Line 272 -- resolve_embed_lines, nested loop
```lua
-- Before:
local s, e = cline:find("!%[%[.-%]%]", start)
-- After:
local s, e = cline:find(EMBED_PAT, start)
```

### Line 361 -- render_embeds, main loop
```lua
-- Before:
local s, e = line:find("!%[%[.-%]%]", start)
-- After:
local s, e = line:find(EMBED_PAT, start)
```

### Line 655 -- debug_info, scanning loop
```lua
-- Before:
local s, e = line:find("!%[%[.-%]%]", start)
-- After:
local s, e = line:find(EMBED_PAT, start)
```

## export.lua -- Not Changed

The pattern in `export.lua:282` is `"!%[%[(.-)%]%]"` (with a capture group) -- a semantically different pattern. Not worth sharing.

## Risk

Minimal. Pure mechanical substitution of identical string literals with a local constant. No behavioral change.

## Files Modified

Only `lua/andrew/vault/embed.lua` -- 1 constant added, 5 pattern occurrences replaced.
