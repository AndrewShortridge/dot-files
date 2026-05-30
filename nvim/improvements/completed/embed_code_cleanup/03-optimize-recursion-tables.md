# Implementation Plan: Optimize Table Copying in `resolve_embed_lines()` Recursion

## Problem

Lines 233-234 in `resolve_embed_lines()` create full shallow copies of both `visited_set` and `visited_list` on every recursive call:

```lua
local new_visited_set = vim.tbl_extend("keep", {}, visited_set)
local new_visited_list = { unpack(visited_list) }
```

With `max_depth=5` and multiple embeds per level, this creates unnecessary GC pressure. Since all sibling embeds are processed **sequentially** (no concurrency), a push-before/pop-after stack pattern is safe.

## Solution: In-Place Stack Pattern

### Replace Copy with Push (Lines 232-238)

**Before:**
```lua
-- Update visited tracking for recursion
local new_visited_set = vim.tbl_extend("keep", {}, visited_set)
local new_visited_list = { unpack(visited_list) }
if target_path then
  new_visited_set[target_path] = true
  new_visited_list[#new_visited_list + 1] = target_path
end
```

**After:**
```lua
-- Push target onto visited stack for cycle detection during recursion.
-- Popped after the content loop below (stack pattern avoids table copies).
local pushed = false
if target_path then
  visited_set[target_path] = true
  visited_list[#visited_list + 1] = target_path
  pushed = true
end
```

### Update Recursive Call (Lines 288-292)

Change `new_visited_set, new_visited_list` to `visited_set, visited_list`:

```lua
local inner_lines, inner_used = resolve_embed_lines(
  inner_details, inner_source,
  depth + 1, visited_set, visited_list, bufnr,
  remaining
)
```

### Add Pop After Content Loop (After Line 307)

After the `for _, cline in ipairs(content) do` loop:

```lua
-- Pop target from visited stack (restore state for caller/siblings)
if pushed then
  visited_set[target_path] = nil
  visited_list[#visited_list] = nil
end
```

## Why Sibling Isolation Is Preserved

All sibling embeds are processed sequentially in the `while true` loop (lines 265-304). Sibling A pushes, recurses, pops before sibling B runs. B never sees A's entries.

## Edge Cases

1. **Error mid-recursion**: Error propagates up the entire call stack, aborting the render. The tables are local to each top-level embed invocation, so corruption has no lasting effect.
2. **`target_path` is nil**: `pushed` flag is false -- no push, no pop.
3. **Duplicate path in chain**: Impossible -- cycle detection (line 212) returns early before the push.
4. **`visited_list` pop via nil**: Setting `visited_list[#visited_list] = nil` correctly shrinks the sequence.
5. **Same-line siblings** (`![[B]]![[C]]`): B pushes/pops, then C pushes/pops. Neither sees the other.

## Performance Impact

- **Eliminated**: O(d) table copy per call for both structures, O(d) allocations per call
- **Added**: O(1) push/pop per call, one boolean local
- **Net**: Reduces per-call overhead from O(d) to O(1)

## No Changes to Callers

`render_embeds()` creates fresh tables per top-level embed (lines 434-435). The function signature is unchanged.

## Files Modified

Only `lua/andrew/vault/embed.lua` -- lines 232-238 (replace), line 290 (rename), after line 307 (insert pop).
