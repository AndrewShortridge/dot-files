# Implementation Plan: Shared `get_basename()` Helper

## Problem

`vim.fn.fnamemodify(path, ":t:r")` appears 22 times across 14 vault modules. Verbose, hard to grep for intent, and a maintenance risk.

## Solution

### Step 1: Add `M.get_basename()` to `link_utils.lua`

**File:** `lua/andrew/vault/link_utils.lua`

Insert after the existing `M.link_name()` function (after line 69):

```lua
--- Extract the filename stem (no directory, no extension) from a path.
--- Equivalent to `vim.fn.fnamemodify(path, ":t:r")`.
--- @param path string  Absolute or relative file path
--- @return string  Filename without directory or extension (e.g. "My Note")
function M.get_basename(path)
  return vim.fn.fnamemodify(path, ":t:r")
end
```

### Step 2: Update `embed.lua` (primary target)

`embed.lua` already requires `link_utils` on line 4. No new `require` needed.

**Line 168:**
```lua
-- Before:
names[#names + 1] = vim.fn.fnamemodify(p, ":t:r")
-- After:
names[#names + 1] = link_utils.get_basename(p)
```

**Line 170:**
```lua
-- Before:
names[#names + 1] = vim.fn.fnamemodify(cycle_target, ":t:r")
-- After:
names[#names + 1] = link_utils.get_basename(cycle_target)
```

### Step 3: Follow-up -- Other Files

| File | Line(s) | Needs `require`? |
|------|---------|------------------|
| `blockid.lua` | 33 | Yes |
| `unlinked.lua` | 32, 411 | Yes |
| `engine.lua` | 546, 640, 816 | Yes |
| `autolink.lua` | 336 | Yes |
| `navigate.lua` | 19 | Yes |
| `backlinks.lua` | 11 | Yes |
| `connections.lua` | 632 | Yes |
| `export.lua` | 316 | No |
| `graph.lua` | 164 | No |
| `linkcheck.lua` | 168, 332, 435 | No |
| `linkdiag.lua` | 146, 181, 330 | No |
| `templates/daily_log.lua` | 339 | Yes |

No circular dependency risk -- `link_utils.lua` only requires `slug.lua`.

## Verification

- Grep `fnamemodify.*":t:r"` -- should return only the implementation inside `get_basename`.
- Test cycle display: embed NoteA -> NoteB -> NoteA -- should show `NoteA -> NoteB -> NoteA`.

## Files Modified (This Plan)

- `lua/andrew/vault/link_utils.lua` -- add `get_basename`
- `lua/andrew/vault/embed.lua` -- update 2 call sites
- (Follow-up: 12 more files, 20 more call sites)
