# 24 -- Fix "last <weekday>" Temporal Alias Off-by-One on Same Weekday

## Severity

**Medium** -- Behavioral bug. `[[last monday]]` typed on a Monday resolves to
today (the current Monday) instead of the previous Monday (7 days ago). The
symmetric bug exists for `[[next monday]]` on a Monday: it resolves to today
instead of next week's Monday.

## Summary

The `resolve_temporal()` function in `wikilinks.lua` computes the day offset
for "last <weekday>" and "next <weekday>" links. The current logic uses a
strict inequality (`<= 0` / `<= 0`) when deciding whether to wrap to the
previous or next week. This means that when today IS the target weekday, the
difference is 0, the wrap condition is met, and the result lands on today
rather than going back (or forward) a full 7 days.

Obsidian behavior: "last X" should ALWAYS resolve to the most recent past
occurrence of weekday X. If today is X, "last X" means 7 days ago. Similarly,
"next X" should ALWAYS resolve to the upcoming future occurrence of weekday X.
If today is X, "next X" means 7 days from now.

## Root Cause Analysis

### File

`/home/andrew-cmmg/.config/nvim/lua/andrew/vault/wikilinks.lua`

### Relevant Code (lines 86-139)

```lua
--- Weekday name to os.date wday number (Sunday=1 .. Saturday=7).
---@type table<string, number>
local WEEKDAYS = {
  sunday = 1, monday = 2, tuesday = 3, wednesday = 4,
  thursday = 5, friday = 6, saturday = 7,
}

local function resolve_temporal(name)
  local cfg = config.temporal_aliases
  if not cfg or not cfg.enabled then
    return nil, nil
  end

  local lower = name:lower():gsub("^%s+", ""):gsub("%s+$", "")

  -- 1) Check static aliases (today, yesterday, tomorrow)
  local offset = cfg.aliases[lower]
  if offset then
    local date = engine.date_offset(offset)
    local path = engine.vault_path .. "/" .. config.dirs.log .. "/" .. date .. ".md"
    return path, date
  end

  -- 2) Check relative weekday aliases (last monday, next friday)
  if cfg.relative_weekdays then
    local direction, weekday_name = lower:match("^(last)%s+(%a+)$")
    if not direction then
      direction, weekday_name = lower:match("^(next)%s+(%a+)$")
    end
    if direction and weekday_name then
      local target_wday = WEEKDAYS[weekday_name]
      if target_wday then
        local today_ts = os.time()
        local today_wday = tonumber(os.date("%w", today_ts)) + 1 -- os.date %w is 0-indexed
        local diff
        if direction == "last" then
          diff = today_wday - target_wday        -- LINE 126
          if diff <= 0 then diff = diff + 7 end  -- LINE 127  <-- BUG
          diff = -diff                            -- LINE 128
        else -- "next"
          diff = target_wday - today_wday        -- LINE 130
          if diff <= 0 then diff = diff + 7 end  -- LINE 131  <-- BUG
        end
        local date = engine.date_offset(diff)
        local path = engine.vault_path .. "/" .. config.dirs.log .. "/" .. date .. ".md"
        return path, date
      end
    end
  end

  return nil, nil
end
```

### The Off-by-One

The `WEEKDAYS` table maps Sunday=1 through Saturday=7, matching `os.date("%w")+1`.

For "last":
- `diff = today_wday - target_wday`
- When today IS the target weekday, `diff = 0`.
- The guard `if diff <= 0` triggers, adding 7, making `diff = 7`.
- Then `diff = -diff` makes it `-7`... wait, actually that IS 7 days ago.

Let me re-trace more carefully. `os.date("%w")` returns 0 for Sunday, 1 for
Monday, ..., 6 for Saturday. Adding 1 gives Sunday=1 through Saturday=7. This
matches the `WEEKDAYS` table.

**Example: Today is Monday (wday=2), target is Monday (wday=2), direction="last":**

```
diff = today_wday - target_wday = 2 - 2 = 0
if diff <= 0 then diff = diff + 7 end   -->  0 <= 0 is TRUE  --> diff = 7
diff = -diff                             -->  diff = -7
engine.date_offset(-7) = 7 days ago (previous Monday)  ✓ CORRECT
```

Wait -- that seems correct. Let me re-check more carefully with a different
scenario to see if the bug actually manifests differently.

**Example: Today is Monday (wday=2), target is Sunday (wday=1), direction="last":**

```
diff = 2 - 1 = 1
if diff <= 0: FALSE
diff = -1  -->  yesterday (Sunday)  ✓ CORRECT
```

**Example: Today is Monday (wday=2), target is Tuesday (wday=3), direction="last":**

```
diff = 2 - 3 = -1
if diff <= 0: TRUE  --> diff = -1 + 7 = 6
diff = -6  -->  6 days ago (Tuesday last week)  ✓ CORRECT
```

Hmm, the "last" direction actually handles the same-weekday case correctly
with the current code. Let me check "next":

**Example: Today is Monday (wday=2), target is Monday (wday=2), direction="next":**

```
diff = target_wday - today_wday = 2 - 2 = 0
if diff <= 0: TRUE  --> diff = 0 + 7 = 7
engine.date_offset(7) = 7 days from now (next Monday)  ✓ CORRECT
```

Both directions handle the same-weekday case correctly with `<= 0`. The wrap
adds 7 when diff is 0, which gives the correct "last week" / "next week"
result.

---

### Re-examining: Where Does the Bug Actually Live?

The code above is actually correct for the same-weekday case. Let me check if
there is a different code path or if the `os.date("%w")` return value is
being handled incorrectly.

The potential issue is subtle and depends on how Lua's `os.date("%w")`
interacts with the `+1` adjustment:

- `os.date("%w")` returns a **string** (`"0"` through `"6"`)
- `tonumber(os.date("%w", today_ts)) + 1` converts it properly

Actually, after careful analysis, the current code handles all cases correctly
with `<= 0`:

| Today    | Target   | Direction | diff (raw) | <= 0? | Adjusted | Final offset | Result        |
|----------|----------|-----------|-----------|-------|----------|-------------|---------------|
| Mon (2)  | Mon (2)  | last      | 0         | yes   | 7        | -7          | Last Mon      |
| Mon (2)  | Mon (2)  | next      | 0         | yes   | 7        | +7          | Next Mon      |
| Mon (2)  | Sun (1)  | last      | 1         | no    | 1        | -1          | Yesterday     |
| Mon (2)  | Tue (3)  | last      | -1        | yes   | 6        | -6          | Last Tue      |
| Mon (2)  | Sun (1)  | next      | -1        | yes   | 6        | +6          | Next Sun      |
| Mon (2)  | Tue (3)  | next      | 1         | no    | 1        | +1          | Tomorrow      |

**HOWEVER** -- there is a real off-by-one if the condition were `< 0` instead
of `<= 0`. If someone changes the guard to `< 0` (strict less-than), then
diff=0 would NOT wrap, giving offset 0 for "last" (today) and offset 0 for
"next" (today). This is the bug pattern described in the issue.

Let me verify by checking if there's a **different version** of this code,
or if the condition truly is `<= 0` in the current file.

Looking back at the actual file content (lines 126-131):

```lua
if direction == "last" then
  diff = today_wday - target_wday
  if diff <= 0 then diff = diff + 7 end
  diff = -diff
else -- "next"
  diff = target_wday - today_wday
  if diff <= 0 then diff = diff + 7 end
end
```

The condition IS `<= 0`. So when diff is exactly 0 (same weekday), the
wrap triggers and adds 7. This means:

- `[[last monday]]` on Monday -> -7 (last week's Monday) -- **CORRECT**
- `[[next monday]]` on Monday -> +7 (next week's Monday) -- **CORRECT**

## Revised Conclusion

After thorough analysis, **the current code is actually correct**. The `<= 0`
guard (not `< 0`) properly handles the same-weekday edge case by wrapping
to the previous/next week.

If the user is experiencing `[[last monday]]` resolving to today on a Monday,
the bug may instead be in one of these areas:

### Possible Alternative Root Causes

1. **Vault index returning a match first.** The `resolve_link()` function
   (line 173-196) checks the vault index BEFORE falling back to temporal
   resolution. If there is a note named "last monday" or with an alias
   matching "last monday" in the vault index, it would be returned instead
   of the temporal resolution. However, this is unlikely for "last monday".

2. **Static alias shadowing.** The static aliases check (`cfg.aliases[lower]`)
   runs before the weekday check. If someone added `["last monday"] = 0` to
   `config.temporal_aliases.aliases`, that would resolve to today. The default
   config does not include this, but it is worth checking.

3. **`os.date` returning unexpected values.** If `os.time()` returns a
   timestamp near midnight and the timezone offset causes `os.date` to
   report a different weekday than expected, the calculation could be off.
   This would be a timezone/DST edge case rather than a logic bug.

4. **The `<= 0` was recently changed to `< 0`.** If a previous edit
   introduced `< 0` and was then fixed back to `<= 0`, the user may have
   an outdated version loaded. Running `:lua print(vim.inspect(require("andrew.vault.wikilinks")))` after a fresh restart would confirm.

## Preventive Fix: Add Explicit Guard

Even though the current code is correct, the logic is non-obvious and the
`<= 0` vs `< 0` distinction is the entire difference between correct and
buggy behavior. A clearer implementation would make the intent explicit:

### Before (current -- correct but fragile)

```lua
if direction == "last" then
  diff = today_wday - target_wday
  if diff <= 0 then diff = diff + 7 end
  diff = -diff
else -- "next"
  diff = target_wday - today_wday
  if diff <= 0 then diff = diff + 7 end
end
```

### After (explicit same-day handling, self-documenting)

```lua
if direction == "last" then
  diff = today_wday - target_wday
  -- When diff is 0 (same weekday), "last X" means the previous week's X,
  -- not today. The <= 0 guard handles both same-day (0) and wrap-around
  -- (negative) cases by adding 7.
  if diff <= 0 then diff = diff + 7 end
  diff = -diff
else -- "next"
  diff = target_wday - today_wday
  -- When diff is 0 (same weekday), "next X" means next week's X,
  -- not today. The <= 0 guard handles both same-day (0) and wrap-around
  -- (negative) cases by adding 7.
  if diff <= 0 then diff = diff + 7 end
end
```

The only change is adding explanatory comments. If a future editor sees
`<= 0` and "simplifies" it to `< 0`, the comment will stop them.

### If the Code Actually Uses `< 0` (Bug Scenario)

If the file on disk actually has `< 0` (strict less-than) instead of `<= 0`,
the fix is to change both guards:

```lua
-- WRONG: < 0 means same-weekday gives diff=0, not wrapped, resolves to today
if diff < 0 then diff = diff + 7 end

-- CORRECT: <= 0 wraps same-weekday to previous/next week
if diff <= 0 then diff = diff + 7 end
```

## Test Cases

### "last <weekday>" -- should always resolve to the most recent PAST occurrence

| Today (wday) | Link            | Expected Offset | Expected Date (from Mon 2026-03-02) |
|-------------|-----------------|----------------|--------------------------------------|
| Mon (2)     | `[[last monday]]`    | -7  | 2026-02-23 (previous Monday) |
| Mon (2)     | `[[last tuesday]]`   | -6  | 2026-02-24 |
| Mon (2)     | `[[last wednesday]]` | -5  | 2026-02-25 |
| Mon (2)     | `[[last thursday]]`  | -4  | 2026-02-26 |
| Mon (2)     | `[[last friday]]`    | -3  | 2026-02-27 |
| Mon (2)     | `[[last saturday]]`  | -2  | 2026-02-28 |
| Mon (2)     | `[[last sunday]]`    | -1  | 2026-03-01 |

### "next <weekday>" -- should always resolve to the upcoming FUTURE occurrence

| Today (wday) | Link            | Expected Offset | Expected Date (from Mon 2026-03-02) |
|-------------|-----------------|----------------|--------------------------------------|
| Mon (2)     | `[[next monday]]`    | +7  | 2026-03-09 (next Monday) |
| Mon (2)     | `[[next tuesday]]`   | +1  | 2026-03-03 |
| Mon (2)     | `[[next wednesday]]` | +2  | 2026-03-04 |
| Mon (2)     | `[[next thursday]]`  | +3  | 2026-03-05 |
| Mon (2)     | `[[next friday]]`    | +4  | 2026-03-06 |
| Mon (2)     | `[[next saturday]]`  | +5  | 2026-03-07 |
| Mon (2)     | `[[next sunday]]`    | +6  | 2026-03-08 |

### Same-weekday verification across all days

Each row tests "last X" where X is the same as today. All should give -7.

| Today    | wday | Link             | diff raw | <= 0? | Adjusted | Final |
|----------|------|------------------|----------|-------|----------|-------|
| Sunday   | 1    | `[[last sunday]]`    | 0    | yes   | 7        | -7    |
| Monday   | 2    | `[[last monday]]`    | 0    | yes   | 7        | -7    |
| Tuesday  | 3    | `[[last tuesday]]`   | 0    | yes   | 7        | -7    |
| Wednesday| 4    | `[[last wednesday]]` | 0    | yes   | 7        | -7    |
| Thursday | 5    | `[[last thursday]]`  | 0    | yes   | 7        | -7    |
| Friday   | 6    | `[[last friday]]`    | 0    | yes   | 7        | -7    |
| Saturday | 7    | `[[last saturday]]`  | 0    | yes   | 7        | -7    |

Each row tests "next X" where X is the same as today. All should give +7.

| Today    | wday | Link             | diff raw | <= 0? | Adjusted | Final |
|----------|------|------------------|----------|-------|----------|-------|
| Sunday   | 1    | `[[next sunday]]`    | 0    | yes   | 7        | +7    |
| Monday   | 2    | `[[next monday]]`    | 0    | yes   | 7        | +7    |
| Tuesday  | 3    | `[[next tuesday]]`   | 0    | yes   | 7        | +7    |
| Wednesday| 4    | `[[next wednesday]]` | 0    | yes   | 7        | +7    |
| Thursday | 5    | `[[next thursday]]`  | 0    | yes   | 7        | +7    |
| Friday   | 6    | `[[next friday]]`    | 0    | yes   | 7        | +7    |
| Saturday | 7    | `[[next saturday]]`  | 0    | yes   | 7        | +7    |

### Manual verification command

Run this in Neovim's command line to verify the resolution for any link:

```vim
:lua local w = require("andrew.vault.wikilinks"); local p, d = w.resolve_temporal("last monday"); print(d)
```

## Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/wikilinks.lua` | Add explanatory comments to `resolve_temporal()` around the `<= 0` guards (lines 127, 131) to document the same-weekday behavior and prevent regression |

## Diagnostic Checklist

If the bug is observed despite the code reading `<= 0`:

1. **Restart Neovim** -- ensure no stale module is cached via `package.loaded`.
2. **Check for config override** -- run `:lua print(vim.inspect(require("andrew.vault.config").temporal_aliases))` and verify no static alias shadows the weekday pattern.
3. **Check vault index** -- run `:lua local idx = require("andrew.vault.vault_index").current(); print(vim.inspect(idx:resolve_name("last monday")))` to see if a note matches.
4. **Verify weekday calculation** -- run `:lua print(os.date("%A"), tonumber(os.date("%w")) + 1)` to confirm today's weekday number.
5. **Check DST/timezone** -- if near midnight, `os.time()` and `os.date()` might disagree on the current day depending on locale settings.
