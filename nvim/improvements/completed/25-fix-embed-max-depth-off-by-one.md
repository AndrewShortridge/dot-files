# Fix: Embed max_depth Off-By-One Error

**Severity:** Medium (config does not behave as documented)
**Module:** `lua/andrew/vault/embed.lua`
**Related:** `lua/andrew/vault/config.lua`

## Summary

Setting `config.embed.max_depth = 0` should produce "flat/no recursion" behavior
per the config comment, meaning first-level embeds display their content but
nested `![[...]]` within that content are left unresolved (shown as literal
text). Instead, `max_depth = 0` renders zero content -- the user sees only a
"max embed depth reached" indicator inside the embed box.

The root cause is an off-by-one: `render_embeds()` passes `depth = 1` for the
initial call, but the depth limit check in `resolve_embed_lines()` uses
0-indexed semantics (`depth > max_depth`). When `max_depth = 0` and `depth = 1`,
the very first call trips the depth guard and returns the limit message before
any content is resolved.

## Root Cause Analysis

### File: `lua/andrew/vault/embed.lua`

**Line 492** -- initial call passes `depth = 1`:

```lua
            local content, lines_used = resolve_embed_lines(
              details, source,
              1,              -- depth starts at 1 for first-level embeds
              visited_set,
              visited_list,
              content_budget,
              bufpath
            )
```

**Line 202-206** -- depth limit check in `resolve_embed_lines`:

```lua
  local max_depth = config.embed.max_depth or 5

  -- Depth limit check
  if depth > max_depth then
    return { "\u22ef (max embed depth reached)" }, 1
  end
```

**Line 235-241** -- "at max depth, return content without recursion" branch:

```lua
  -- If at max_depth, return content without further resolution
  if depth == max_depth then
    local used = #content
    if content_truncated then
      content[#content + 1] = "\u22ef (truncated)"
      used = used + 1
    end
    return content, used
  end
```

### Walk-through with `max_depth = 0`

1. `render_embeds()` finds an embed `![[SomeNote]]` and calls
   `resolve_embed_lines(..., depth=1, ...)`.
2. Inside `resolve_embed_lines`, `max_depth = 0`.
3. Check: `depth (1) > max_depth (0)` --> **true**.
4. Returns `{ "... (max embed depth reached)" }` immediately.
5. `render_embeds()` wraps this in header/footer borders and creates the extmark.
6. The user sees an embed box containing only the depth-limit message -- no content.

**Expected for `max_depth = 0` ("flat/no recursion"):** The first-level embed
content should be shown, but any `![[...]]` patterns inside that content should
be left as literal text (not recursively resolved).

### Walk-through with `max_depth = 1`

1. `render_embeds()` calls `resolve_embed_lines(..., depth=1, ...)`.
2. `max_depth = 1`.
3. Check: `depth (1) > max_depth (1)` --> false.
4. Check: `depth (1) == max_depth (1)` --> **true**.
5. Returns content WITHOUT recursion (flat). This is the behavior the user
   expects from `max_depth = 0`.

The entire depth ladder is shifted by one: every `max_depth` value produces the
behavior that should correspond to `max_depth - 1`.

## The Fix

Change the initial depth from `1` to `0` in the call from `render_embeds()`.

### Before (line 490-497)

```lua
            -- Recursively resolve nested embeds within the content
            local content, lines_used = resolve_embed_lines(
              details, source,
              1,              -- depth starts at 1 for first-level embeds
              visited_set,
              visited_list,
              content_budget,
              bufpath
            )
```

### After

```lua
            -- Recursively resolve nested embeds within the content
            local content, lines_used = resolve_embed_lines(
              details, source,
              0,              -- depth starts at 0 (0 = this embed itself, recursion increments)
              visited_set,
              visited_list,
              content_budget,
              bufpath
            )
```

No other changes are needed. The two guards in `resolve_embed_lines` already
use the correct logic for 0-based depth:

- `depth > max_depth` -- blocks calls that exceed the limit (now only reachable
  from recursive calls, never from the initial call when `max_depth >= 0`).
- `depth == max_depth` -- returns content flat (no further recursion). At
  `max_depth = 0`, the initial call (`depth = 0`) hits this branch, which is
  exactly "flat/no recursion."

## Expected Behavior After Fix

| `max_depth` | Behavior |
|-------------|----------|
| 0 | First-level embeds show their content. Nested `![[...]]` inside that content are left as literal text. No recursion. |
| 1 | First-level embeds show content. Nested embeds within are also resolved (their content is shown), but any third-level embeds inside those are left as literal text. |
| 2 | Three levels of content displayed (the embed, one nested level, one more nested level). Fourth-level embeds are not resolved. |
| 5 (default) | Six levels of content (depth 0 through 5). Seventh-level embeds show the depth-limit message. |

### Depth trace for `max_depth = 0` (after fix)

1. `render_embeds()` calls `resolve_embed_lines(..., depth=0, ...)`.
2. `depth (0) > max_depth (0)` --> false. (Continues.)
3. Content is fetched via `get_embed_content()`.
4. `depth (0) == max_depth (0)` --> true. Returns content as-is (flat, no
   recursion into nested embeds). Correct.

### Depth trace for `max_depth = 1` (after fix)

1. `render_embeds()` calls `resolve_embed_lines(..., depth=0, ...)`.
2. `depth (0) > max_depth (1)` --> false.
3. `depth (0) == max_depth (1)` --> false.
4. Content is fetched, scanned for nested `![[...]]`.
5. For each nested embed, calls `resolve_embed_lines(..., depth=1, ...)`.
6. `depth (1) > max_depth (1)` --> false.
7. `depth (1) == max_depth (1)` --> true. Returns nested content flat. Correct.

### Depth trace for `max_depth = 2` (after fix)

1. Initial call: `depth=0`. Neither guard triggers. Scans for nested embeds.
2. First recursion: `depth=1`. Neither guard triggers. Scans for nested embeds.
3. Second recursion: `depth=2`. `depth == max_depth` --> true. Returns flat.
4. Third recursion would be `depth=3`. `depth > max_depth` --> true. Returns
   "max embed depth reached." (Only reachable if the `depth == max_depth` branch
   has a logic error, serves as safety net.)

## Test Cases

### Test 1: max_depth = 0 shows content without recursion

Setup:
- NoteA.md contains `![[NoteB]]`
- NoteB.md contains `Some content` and `![[NoteC]]`
- NoteC.md contains `Nested content`

With `max_depth = 0`, opening NoteA should show:
```
── ![[NoteB]] ──────────────────────
  Some content
  ![[NoteC]]
──────────────────────────────────
```

NoteC's content should NOT be inlined -- the `![[NoteC]]` line appears as
literal text.

### Test 2: max_depth = 0 does NOT show "max embed depth reached"

With the same setup as Test 1, the embed box for `![[NoteB]]` should contain
the actual note content, not the `... (max embed depth reached)` indicator.

### Test 3: max_depth = 1 resolves one level of nesting

With the same setup, `max_depth = 1` should show:
```
── ![[NoteB]] ──────────────────────
  Some content
  Nested content
──────────────────────────────────
```

NoteC's content (`Nested content`) is inlined because one level of recursion is
allowed.

### Test 4: max_depth = 5 (default) behavior is unchanged

The default value of 5 allows depth 0 through 5, which is 6 levels of
resolution. Previously it allowed depth 1 through 5, which was 5 levels. In
practice, most vaults never nest embeds 5+ levels deep, so this is unlikely to
produce a visible difference. If strict backward compatibility at the default
is required, change the default from `5` to `4` in config.lua.

### Test 5: Cycle detection still works

Setup:
- NoteA.md contains `![[NoteB]]`
- NoteB.md contains `![[NoteA]]`

With `max_depth >= 1`, opening NoteA should show the cycle indicator
`↻ cycle: NoteA → NoteB → NoteA` rather than infinite recursion.

### Test 6: Image embeds unaffected

Image embeds (`![[photo.png]]`) are handled by a separate code path in
`render_embeds()` (the `is_image_embed` branch) and never enter
`resolve_embed_lines()`. No change in behavior.

## Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/embed.lua` (line 492) | Change initial `depth` argument from `1` to `0` |

## Backward Compatibility Note

The default `max_depth = 5` will now allow one additional level of nesting
(depth 0-5 = 6 levels instead of the previous depth 1-5 = 5 levels). This is
unlikely to be noticeable in practice. If exact backward compatibility at the
default value is desired, change the default in `config.lua` from `5` to `4`:

```lua
  max_depth = 4,  -- max nesting depth for recursive transclusion (0 = flat/no recursion)
```

However, this is optional. The semantic fix (making `0` mean "flat") is more
important than preserving the exact recursion count at the default value.
