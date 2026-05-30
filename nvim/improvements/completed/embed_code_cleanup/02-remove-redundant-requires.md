# Implementation Plan: Remove Redundant `require("andrew.vault.config")` Calls

## Problem

`embed.lua` requires config at module level (line 3): `local config = require("andrew.vault.config")`. Two locations inside function bodies redundantly re-require the same module into a differently-named local variable `cfg`. These should use the existing module-level `config`.

## Why There Is No Valid Hot-Reload Reason

1. `config.lua` returns a plain table `M`. Lua's `require()` caches this table -- every call returns the **same table reference**.
2. No code anywhere clears or replaces `package.loaded["andrew.vault.config"]`.
3. The rest of embed.lua already uses the module-level `config` variable in 8+ locations.

## Change 1: `on_index_update` function (lines 763-769)

**Before:**
```lua
local function on_index_update(generation, context)
  local cfg = require("andrew.vault.config")
  if not cfg.embed.sync or not cfg.embed.sync.enabled then
    return
  end

  local debounce_ms = (cfg.embed.sync and cfg.embed.sync.debounce_ms) or 300
```

**After:**
```lua
local function on_index_update(generation, context)
  if not config.embed.sync or not config.embed.sync.enabled then
    return
  end

  local debounce_ms = (config.embed.sync and config.embed.sync.debounce_ms) or 300
```

## Change 2: TextChanged/InsertLeave autocmd callback (lines 910-921)

**Before:**
```lua
    callback = function(ev)
      local cfg = require("andrew.vault.config")
      if not cfg.embed.sync or not cfg.embed.sync.enabled then return end
      ...
        local delay = (cfg.embed.sync and cfg.embed.sync.self_debounce_ms) or 500
```

**After:**
```lua
    callback = function(ev)
      if not config.embed.sync or not config.embed.sync.enabled then return end
      ...
        local delay = (config.embed.sync and config.embed.sync.self_debounce_ms) or 500
```

## Complete Checklist

| Line | Before | After |
|------|--------|-------|
| 764 | `local cfg = require("andrew.vault.config")` | (delete entire line) |
| 765 | `cfg.embed.sync` (x2) | `config.embed.sync` (x2) |
| 769 | `cfg.embed.sync` (x2) | `config.embed.sync` (x2) |
| 911 | `local cfg = require("andrew.vault.config")` | (delete entire line) |
| 912 | `cfg.embed.sync` (x2) | `config.embed.sync` (x2) |
| 921 | `cfg.embed.sync` (x2) | `config.embed.sync` (x2) |

**Total: 2 lines deleted, 4 lines edited (8 `cfg` references become `config`).**

## Lines NOT Changed

Lines 549-556 also use `local cfg = Snacks.image.config` -- this is completely unrelated and must remain.

## Note

`engine.lua` has the same pattern at lines 536 and 540. Out of scope for this plan but could be a follow-up.
