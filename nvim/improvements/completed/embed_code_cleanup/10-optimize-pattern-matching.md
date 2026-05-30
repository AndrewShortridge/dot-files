# Implementation Plan: Optimize Triple Pattern Scan in `resolve_embed_lines()`

## Problem

For each content line, three separate pattern operations run on the same string:

1. **Line 251**: `cline:find("!%[%[.-%]%]")` -- existence check (result discarded)
2. **Line 257**: `cline:gsub("!%[%[.-%]%]", "")` -- strip embeds to check for other text (allocates new string)
3. **Line 272**: `cline:find("!%[%[.-%]%]", start)` -- find positions in loop

## Solution: Single-Pass Span Collection

Collect all `(s, e)` pairs in one loop, then determine "purely embeds" by checking if characters outside spans are all whitespace. Eliminates the existence-only check and the `gsub` allocation.

### Before (lines 244-306)

```lua
local has_embed = cline:find("!%[%[.-%]%]")             -- SCAN 1
if not has_embed then
  -- add as-is
else
  local test_line = cline:gsub("!%[%[.-%]%]", "")       -- SCAN 2
  if vim.trim(test_line) ~= "" then
    -- add as-is (mixed text+embed)
  else
    local start = 1
    while true do
      local s, e = cline:find("!%[%[.-%]%]", start)     -- SCAN 3
      if not s then break end
      -- resolve embed...
      start = e + 1
    end
  end
end
```

### After

```lua
-- Single pass: collect all embed spans
local spans
do
  local pos = 1
  while true do
    local s, e = cline:find(EMBED_PAT, pos)
    if not s then break end
    if not spans then spans = {} end
    spans[#spans + 1] = s
    spans[#spans + 1] = e
    pos = e + 1
  end
end

if not spans then
  -- No embeds: add as-is
  resolved[#resolved + 1] = cline
  if remaining then remaining = remaining - 1 end
else
  -- Check if line is purely embed(s) + whitespace
  local purely_embeds = true
  local check_from = 1
  for k = 1, #spans, 2 do
    local s, e = spans[k], spans[k + 1]
    if s > check_from then
      local gap = cline:sub(check_from, s - 1)
      if gap:find("%S") then
        purely_embeds = false
        break
      end
    end
    check_from = e + 1
  end
  if purely_embeds and check_from <= #cline then
    if cline:sub(check_from):find("%S") then
      purely_embeds = false
    end
  end

  if not purely_embeds then
    -- Mixed text+embed: add as-is
    resolved[#resolved + 1] = cline
    if remaining then remaining = remaining - 1 end
  else
    -- Resolve each embed using collected spans
    for k = 1, #spans, 2 do
      if remaining and remaining <= 0 then
        resolved[#resolved + 1] = "⋯ (total line limit reached)"
        break
      end
      local s, e = spans[k], spans[k + 1]
      local inner_text = vim.trim(cline:sub(s + 3, e - 2))
      -- ... existing resolve logic unchanged ...
    end
  end
end
```

## Edge Cases Verified

| Case | Behavior |
|------|----------|
| No embeds | `spans` is nil, line added as-is (1 find call, same as before) |
| `![[Note]]` alone | Gap check finds no non-whitespace, resolves |
| `  ![[Note]]  ` | Whitespace gaps pass check, resolves |
| `See ![[Note]] here` | Gap `"See "` has `%S`, added as-is |
| `![[A]] ![[B]]` | Space between is whitespace-only, both resolve |
| `![[A]] and ![[B]]` | Gap `" and "` has `%S`, added as-is |
| Budget exhaustion | Check before each span in `for k` loop |

## Performance

| Aspect | Before | After |
|--------|--------|-------|
| No-embed lines | 1 `find` | 1 `find` (identical) |
| Embed lines | 1 `find` + 1 `gsub` (alloc) + N `find` | N `find` + gap checks (no alloc) |

Eliminates `gsub` string allocation on every embed-containing line.

## Files Modified

Only `lua/andrew/vault/embed.lua` -- replace lines 251-305 in `resolve_embed_lines()`.
