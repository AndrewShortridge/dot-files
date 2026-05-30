# Implementation Plan: Fix Remaining LOW Priority Issues

## Issue 11: Unnecessary intermediate variable (line 287) -- FIX

**Before:**
```lua
if inner_path then
  local inner_source = inner_path
  local inner_lines, inner_used = resolve_embed_lines(
    inner_details, inner_source, ...)
```

**After:**
```lua
if inner_path then
  local inner_lines, inner_used = resolve_embed_lines(
    inner_details, inner_path, ...)
```

Delete `local inner_source = inner_path`, pass `inner_path` directly.

---

## Issue 12: Image name extraction duplicated (lines 372, 662) -- LEAVE AS-IS

`inner:match("^([^|]+)") or inner` appears in `render_embeds()` and `debug_info()`.

**Reasoning:** Single-line pattern match, not complex logic. Extracting adds a function call and name for minimal benefit. The two call sites are in different functions with different purposes. A grep for `^([^|]+)` finds both instantly.

---

## Issue 13: Embed inner text extraction duplicated (lines 275, 366, 658) -- FIX

`vim.trim(line:sub(s + 3, e - 2))` has magic numbers encoding `![[`/`]]` delimiter lengths.

**Add helper near top of file (around line 27):**
```lua
--- Extract the inner text from an embed match span.
--- Strips the `![[` prefix and `]]` suffix, then trims whitespace.
---@param line string
---@param s number start position of the match
---@param e number end position of the match
---@return string
local function extract_embed_inner(line, s, e)
  return vim.trim(line:sub(s + 3, e - 2))
end
```

**Update 3 call sites:**

Line 275 in `resolve_embed_lines()`:
```lua
-- Before:
local inner_text = vim.trim(cline:sub(s + 3, e - 2))
-- After:
local inner_text = extract_embed_inner(cline, s, e)
```

Line 366 in `render_embeds()`:
```lua
-- Before:
local inner = vim.trim(line:sub(s + 3, e - 2))
-- After:
local inner = extract_embed_inner(line, s, e)
```

Line 658 in `debug_info()`:
```lua
-- Before:
local inner = vim.trim(line:sub(s + 3, e - 2))
-- After:
local inner = extract_embed_inner(line, s, e)
```

---

## Issue 14: init_snacks_image() return capture inconsistent (line 647) -- FIX

**Before:**
```lua
local PlacementMod = init_snacks_image()
```

**After:**
```lua
local PlacementMod, _ = init_snacks_image()
```

Explicit `_` discard communicates that the second return is intentionally ignored.

---

## Issue 15: Cleanup pcalls silently swallow errors (lines 94, 596, 937-940) -- LEAVE AS-IS

**Reasoning:**
1. All are in cleanup or diagnostic code where errors are expected and harmless.
2. Logging would create noise during normal buffer lifecycle events.
3. The `pcall` pattern is idiomatic Lua for "best-effort cleanup."

---

## Summary

| Issue | Action | Change Size |
|-------|--------|-------------|
| 11: Unnecessary intermediate | Fix | 1 line deleted, 1 changed |
| 12: Image name extraction | Leave as-is | 0 |
| 13: Embed inner text extraction | Fix | 1 helper added, 3 sites updated |
| 14: Return capture inconsistent | Fix | 1 line changed |
| 15: Cleanup pcalls | Leave as-is | 0 |

## Files Modified

Only `lua/andrew/vault/embed.lua`.
