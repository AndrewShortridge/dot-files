# 21: Fix Relative Duration Date Range Handling in `..` Operator

**Severity:** Medium (incorrect results / empty result sets for common queries)
**Affects:** `search_filter.lua` lines 572-575, 611-614, 784-788
**Fields:** `modified:`, `created:`, `day:`, `task-due:`, `task-scheduled:`, `task-completion:`

---

## Summary

Date range queries using relative durations (e.g., `modified:7d..30d`) produce
empty result sets because `resolve_date()` maps smaller `Nd` values to more
recent (larger) timestamps. The `..` operator assumes `value..value2` is in
chronological low-to-high order, but with relative durations the natural
user-facing order is reversed: `7d` (7 days ago, recent) resolves to a HIGHER
timestamp than `30d` (30 days ago, older). The resulting range
`entry_ts >= recent AND entry_ts < older` is impossible to satisfy.

Additionally, the `+86400` exclusive-upper-bound adjustment applied at lines
575, 614, and 788 is correct for both absolute dates and relative durations
when the range is properly ordered, but becomes a confusing red herring when
debugging the empty-range issue. This document clarifies both concerns.

---

## Root Cause Analysis

### How relative durations resolve

In `date_utils.lua` lines 76-81, `resolve_date("Nd")` returns
`start_of_day(today - N)`:

```lua
-- date_utils.lua:76-81
local n = lower:match("^(%d+)d$")
if n then
  local t = os.date("*t")
  t.day = t.day - tonumber(n)
  return M.start_of_day(t)
end
```

Key property: **smaller N = more recent = larger timestamp**.

- `resolve_date("7d")`  -> midnight 7 days ago  (e.g., 2026-02-23 00:00:00)
- `resolve_date("30d")` -> midnight 30 days ago (e.g., 2026-01-31 00:00:00)

### The `..` operator in search_filter.lua

For `modified:` / `created:` (lines 572-575):

```lua
-- search_filter.lua:570-575
local filter_ts = date_utils.resolve_date(filter_val)     -- value before ..
if not filter_ts then return false end
if op == ".." then
  local filter_ts2 = date_utils.resolve_date(filter_val2) -- value after ..
  if not filter_ts2 then return false end
  return entry_ts >= filter_ts and entry_ts < filter_ts2 + 86400
end
```

For `day:` (lines 611-614):

```lua
-- search_filter.lua:611-614
if op == ".." then
  local filter_ts2 = date_utils.resolve_date(filter_val2)
  if not filter_ts2 then return false end
  return filter_ts <= entry_ts and entry_ts < filter_ts2 + 86400
end
```

For task dates (lines 784-788):

```lua
-- search_filter.lua:784-788
if op == ".." then
  local lo = resolve_task_date(value, forward_looking)
  local hi = resolve_task_date(value2, forward_looking)
  if lo and hi then
    if task_ts >= lo and task_ts < hi + 86400 then return true end
  end
  goto next_task
end
```

### Bug trace: `modified:7d..30d`

The parser (`search_query.lua:102-104`) splits `7d..30d` into:
- `filter_val = "7d"`, `filter_val2 = "30d"`, `op = ".."`

At runtime:
1. `filter_ts = resolve_date("7d")` = midnight Feb 23 (recent, LARGE timestamp)
2. `filter_ts2 = resolve_date("30d")` = midnight Jan 31 (old, SMALL timestamp)
3. Check: `entry_ts >= midnight_Feb_23 AND entry_ts < midnight_Jan_31 + 86400`
4. Simplified: `entry_ts >= Feb_23 AND entry_ts < Feb_1`

**This is impossible.** No timestamp can be both >= Feb 23 AND < Feb 1. The query
silently returns zero results.

### Why `+86400` is NOT double-applied

The `+86400` on the upper bound converts a midnight timestamp to "start of the
next day," creating an exclusive upper bound that includes the entire endpoint
day. This is correct for both absolute dates and relative durations:

| Upper bound value | `resolve_date()` returns | After `+86400` | Meaning |
|---|---|---|---|
| `2026-02-23` | midnight Feb 23 | midnight Feb 24 | Include all of Feb 23 |
| `7d` (today=Mar 2) | midnight Feb 23 | midnight Feb 24 | Include all of Feb 23 |

Without `+86400`, files modified at (say) 3 PM on Feb 23 would be excluded by
`entry_ts < midnight_Feb_23`, which is wrong. The adjustment is applied exactly
once, in the correct location. The issue is purely about range ordering.

### The real problem: range direction is not normalized

For absolute dates, the user naturally writes `modified:2026-01-31..2026-02-23`
(chronological order). But for relative durations, the natural phrasing is
`modified:7d..30d` (smaller-to-larger N), which maps to reverse chronological
order (recent-to-old). The code does not detect or normalize this.

---

## The Fix

Normalize the range bounds after resolution so that `lo <= hi` regardless of
whether the inputs are absolute dates, relative durations, or a mix. This
applies to all three locations: `modified`/`created`, `day`, and task dates.

### Before (search_filter.lua lines 572-575, modified/created handler)

```lua
if op == ".." then
  local filter_ts2 = date_utils.resolve_date(filter_val2)
  if not filter_ts2 then return false end
  return entry_ts >= filter_ts and entry_ts < filter_ts2 + 86400
end
```

### After (search_filter.lua lines 572-575, modified/created handler)

```lua
if op == ".." then
  local filter_ts2 = date_utils.resolve_date(filter_val2)
  if not filter_ts2 then return false end
  local lo, hi = filter_ts, filter_ts2
  if lo > hi then lo, hi = hi, lo end
  return entry_ts >= lo and entry_ts < hi + 86400
end
```

### Before (search_filter.lua lines 611-614, day handler)

```lua
if op == ".." then
  local filter_ts2 = date_utils.resolve_date(filter_val2)
  if not filter_ts2 then return false end
  return filter_ts <= entry_ts and entry_ts < filter_ts2 + 86400
end
```

### After (search_filter.lua lines 611-614, day handler)

```lua
if op == ".." then
  local filter_ts2 = date_utils.resolve_date(filter_val2)
  if not filter_ts2 then return false end
  local lo, hi = filter_ts, filter_ts2
  if lo > hi then lo, hi = hi, lo end
  return lo <= entry_ts and entry_ts < hi + 86400
end
```

### Before (search_filter.lua lines 784-788, task date handler)

```lua
if op == ".." then
  local lo = resolve_task_date(value, forward_looking)
  local hi = resolve_task_date(value2, forward_looking)
  if lo and hi then
    if task_ts >= lo and task_ts < hi + 86400 then return true end
  end
  goto next_task
end
```

### After (search_filter.lua lines 784-788, task date handler)

```lua
if op == ".." then
  local lo = resolve_task_date(value, forward_looking)
  local hi = resolve_task_date(value2, forward_looking)
  if lo and hi then
    if lo > hi then lo, hi = hi, lo end
    if task_ts >= lo and task_ts < hi + 86400 then return true end
  end
  goto next_task
end
```

---

## Test Cases

### 1. Relative duration range, natural order (the bug)

Query: `modified:7d..30d` (today = 2026-03-02)

- `7d` = midnight Feb 23, `30d` = midnight Jan 31
- After normalization: lo = Jan 31, hi = Feb 23
- Range: [Jan 31 00:00, Feb 24 00:00)

| Entry mtime | Expected | Before fix | After fix |
|---|---|---|---|
| Feb 15 14:00 | match | no match (empty range) | match |
| Feb 23 23:59 | match | no match (empty range) | match |
| Feb 24 00:01 | no match | no match | no match |
| Jan 30 23:59 | no match | no match | no match |
| Jan 31 00:00 | match | no match (empty range) | match |

### 2. Relative duration range, reversed order (already correct)

Query: `modified:30d..7d`

- `30d` = Jan 31, `7d` = Feb 23
- Already in correct order (lo < hi), swap is a no-op
- Behavior unchanged.

### 3. Absolute date range (regression check)

Query: `modified:2026-01-31..2026-02-23`

- Already in correct order. Swap is a no-op.
- Behavior unchanged.

### 4. Day field with relative range

Query: `day:7d..30d` (today = 2026-03-02)

| Entry day | Expected | Before fix | After fix |
|---|---|---|---|
| 2026-02-23 | match | no match | match |
| 2026-02-15 | match | no match | match |
| 2026-01-31 | match | no match | match |
| 2026-01-30 | no match | no match | no match |
| 2026-02-24 | no match | no match | no match |

### 5. Task due date with relative range (forward-looking)

Query: `task-due:7d..30d` (forward-looking: 7d = 7 days FROM NOW)

- `7d` = midnight Mar 9, `30d` = midnight Apr 1
- Already in correct order (7d < 30d for forward-looking). No swap.
- Behavior unchanged.

### 6. Task completion with relative range (backward-looking)

Query: `task-completion:7d..30d` (backward-looking: same as modified)

- `7d` = midnight Feb 23, `30d` = midnight Jan 31
- After normalization: lo = Jan 31, hi = Feb 23
- Same fix as modified/created.

### 7. Mixed absolute and relative

Query: `modified:2026-01-15..7d`

- `2026-01-15` = midnight Jan 15, `7d` = midnight Feb 23
- Already in correct order. No swap needed.
- Behavior unchanged.

Query: `modified:7d..2026-01-15`

- `7d` = midnight Feb 23, `2026-01-15` = midnight Jan 15
- After normalization: lo = Jan 15, hi = Feb 23
- Now works correctly (before fix: empty range).

---

## Edge Cases to Consider

1. **Equal bounds:** `modified:7d..7d` -> lo == hi, swap is no-op. Range is
   `[midnight, midnight + 86400)` = exactly one day. Correct.

2. **Zero-day duration:** `modified:0d..7d` -> `0d` = today midnight, `7d` =
   7 days ago midnight. After swap: lo = 7d ago, hi = today. Range is
   `[7d ago midnight, tomorrow midnight)`. Correct.

3. **Single-day relative:** `modified:1d..0d` -> `1d` = yesterday midnight,
   `0d` = today midnight. Already in order. Range is
   `[yesterday midnight, tomorrow midnight)` = yesterday + today. Correct.

4. **Forward-looking task dates:** `task-due:7d..30d` resolves 7d to
   `today + 7` and 30d to `today + 30`. `today + 7 < today + 30`, so already
   in correct order. Swap is a no-op. No regression.

5. **Backward-looking task dates:** `task-completion:7d..30d` resolves via
   `date_utils.resolve_date`, same as modified. 7d > 30d, so swap applies.
   Correct.

6. **Keywords in ranges:** `modified:last-week..this-week` -> `resolve_date`
   for range keywords returns start of range (e.g., Monday). `last-week` start
   < `this-week` start. Already in order. No swap.

7. **DST transitions:** `start_of_day()` uses local time via `os.time`. The
   swap logic compares resolved timestamps, so DST transitions that change the
   day length do not affect correctness of the lo/hi comparison.

---

## Files Modified

| File | Lines | Change |
|---|---|---|
| `lua/andrew/vault/search_filter.lua` | 572-575 | Add lo/hi normalization for modified/created `..` range |
| `lua/andrew/vault/search_filter.lua` | 611-614 | Add lo/hi normalization for day `..` range |
| `lua/andrew/vault/search_filter.lua` | 784-788 | Add lo/hi normalization for task date `..` range |

Total: 1 file, 3 locations, ~3 lines added per location (9 lines total).

---

## Notes

- The `+86400` exclusive upper bound adjustment is correct and should NOT be
  removed. It ensures the entire endpoint day is included in the range. Without
  it, entries from later in the day would be incorrectly excluded.
- The fix is purely additive (a swap guard) and does not change behavior for
  queries that are already in chronological order.
- No changes needed to `date_utils.lua`, `search_query.lua`, or any other file.
