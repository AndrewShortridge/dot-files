# 29 — Fix Snacks Image Rendering Race Condition

**Priority:** High
**Status:** Complete
**Affects:** `embed.lua` image placements, `snacks.lua` plugin config

## Summary

Inline image rendering via snacks.nvim silently fails when `env().placeholders`
caches as `nil` before the async DA3 terminal detection completes. The current
mitigation (setting `SNACKS_KITTY=1` in `snacks.lua` init) covers the
`KITTY_WINDOW_ID`/`KITTY_PID` env-var case but does not handle all failure
modes: the env var detection runs too late if another module triggers
`terminal.env()` first, there is no retry if the initial placement is created
before detection finishes, and there is no way to diagnose the exact point of
failure without manually running `:VaultEmbedDebug`.

## Root Cause Analysis

### 1. DA3 Async Terminal Detection Timing

Snacks detects the terminal type by sending a DA3 escape sequence (`\x1b[>q`)
and listening for a `TermResponse` autocmd. This is inherently asynchronous:
the response arrives after an unpredictable delay (typically 10-200ms, up to
the 1000ms timeout in `terminal.lua:283`).

The detection flow in `snacks/image/terminal.lua`:

```lua
-- terminal.lua:197-208  (sync path wraps async with vim.wait)
function M.detect(cb)
  if cb then -- async
    return M._detect(cb)
  end
  -- sync: blocks up to 1500ms
  M.detect(function() detected = true end)
  vim.wait(1500, function() return detected end, 10)
end
```

The async path (`M._detect`) sends `\x1b[>q`, sets up a `TermResponse`
autocmd, and starts a 1000ms timeout timer. The result populates
`M._terminal.terminal` (e.g. `"kitty"`).

### 2. `env()` Caches on First Call

`terminal.env()` (line 110-156) checks `M._env` and returns immediately if
already set. On first call, it reads `M._terminal` (populated by `detect()`)
and iterates `environments` to match. The critical logic:

```lua
function M.env()
  if M._env then
    return M._env   -- CACHED: never re-evaluated
  end
  if not M._terminal then
    M.detect()       -- sync detect (blocks up to 1500ms)
  end
  -- ... iterate environments, set M._env.placeholders ...
  return M._env
end
```

The `SNACKS_KITTY` env var override (line 122-124) is checked during this
iteration:

```lua
local override = os.getenv("SNACKS_" .. e.name:upper())  -- "SNACKS_KITTY"
if override then
  e.detected = override ~= "0" and override ~= "false"
```

If `SNACKS_KITTY=1` is set before the first `env()` call, the `kitty`
environment entry is force-detected, setting `placeholders = true` regardless
of whether DA3 has completed.

### 3. Race Window

The race occurs when:

1. **Snacks `init()` runs** (in `snacks.lua`): sets `vim.env.SNACKS_KITTY = "1"`.
2. **Something triggers `terminal.env()` before `init()`** — if any code
   accesses `Snacks.image.terminal.env()` or `Snacks.image.placement.state()`
   before the `init` function of lazy.nvim's plugin spec runs, `M._env` is
   cached without the `SNACKS_KITTY` override.
3. **`embed.lua` BufReadPost autocmd fires** (150ms defer): calls
   `render_embeds()` -> `init_snacks_image()` -> `PlacementMod.new()` ->
   `self:state()` -> `terminal.env().placeholders` -> returns cached `nil`.
4. **Result:** `placement.lua:551` branches to `render_fallback()` instead of
   `render_grid()`. For inline images, the fallback path creates a floating
   window which is immediately suppressed (inline images don't show fallback
   UI), so the image silently disappears.

Additional failure scenario: even when `SNACKS_KITTY=1` is correctly set, if
the image conversion is still in progress when the placement's `update()` is
first called, the placement shows nothing (the `ready()` check returns false).
The placement has an internal callback for when the image finishes loading, but
if the `env()` was already cached without placeholders, the update path will
always use the fallback renderer.

### 4. Current Mitigation (Partial)

The `init` block in `snacks.lua` (lines 12-23) sets `SNACKS_KITTY=1` if
`KITTY_WINDOW_ID` or `KITTY_PID` is present. This works for the common case
but has these gaps:

- **No retry:** If `env()` was called before `init()`, the cached value is
  never corrected.
- **No validation:** No feedback when the override fails to take effect.
- **No re-detect:** If the terminal context changes (e.g., detach/reattach
  in tmux), the cached env is stale forever.
- **Silent failure:** Inline image placements that fail due to
  `placeholders=nil` return immediately from `M:error()` (line 112-115 in
  placement.lua: `if self.opts.inline then return end`), producing no error
  message.

## Detailed Fix

### Fix 1: Move env var detection earlier — before any Snacks code can run

Instead of relying on the lazy.nvim `init` block (which runs after the plugin
is loaded), set the env var at the very top of the plugin spec file so it
executes at Lua parse time. Additionally, add a `VeryLazy` autocmd that
invalidates any premature cache.

**File:** `lua/andrew/plugins/snacks.lua`

Before:

```lua
return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,

  init = function()
    -- Ensure Kitty terminal is detected for inline image placeholders.
    -- Snacks detects Kitty via async DA3 response, but env() caches on
    -- first call. If cached before the response arrives, placeholders is
    -- nil and inline rendering silently falls back to floating windows.
    -- Setting SNACKS_KITTY forces immediate detection.
    if not os.getenv("SNACKS_KITTY") then
      if os.getenv("KITTY_WINDOW_ID") or os.getenv("KITTY_PID") then
        vim.env.SNACKS_KITTY = "1"
      end
    end
  end,
  -- ...
}
```

After:

```lua
-- Set SNACKS_KITTY before ANY Snacks code loads.
-- This must happen at parse time (not in init/config) because Snacks modules
-- may be accessed by other plugins during startup, triggering env() caching
-- before init() runs. The env var causes snacks terminal.env() to force-detect
-- Kitty regardless of DA3 async state.
if not os.getenv("SNACKS_KITTY") then
  if os.getenv("KITTY_WINDOW_ID") or os.getenv("KITTY_PID") then
    vim.env.SNACKS_KITTY = "1"
  end
end

return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,

  init = function()
    -- Safety net: if env() was somehow cached before the env var was set,
    -- invalidate the cache so the next access re-evaluates. This handles
    -- edge cases where another plugin's init() accessed Snacks.image before
    -- this spec was parsed.
    if vim.env.SNACKS_KITTY == "1"
      and Snacks
      and Snacks.image
      and Snacks.image.terminal
    then
      local term = Snacks.image.terminal
      if term._env and not term._env.placeholders then
        -- Cache was poisoned — clear it so next env() call picks up SNACKS_KITTY
        term._env = nil
      end
    end
  end,
  -- ...
}
```

### Fix 2: Add retry logic to embed.lua image placement

When a placement is created but `env().placeholders` is still nil/false,
schedule a deferred retry that waits for DA3 detection to complete and then
re-renders.

**File:** `lua/andrew/vault/embed.lua`

Before (inside `render_embeds`, after the image placement loop, around line
543):

```lua
  _embed_deps[bufnr] = deps
  embeds_visible[bufnr] = true

  -- Show render summary (helps diagnose image issues) — skip in silent mode
  if not opts.silent then
    -- ...
  end
```

After — add a retry check before the summary:

```lua
  _embed_deps[bufnr] = deps
  embeds_visible[bufnr] = true

  -- Retry image rendering if placeholders were not available during initial render.
  -- DA3 detection may still be in flight; once it completes, env().placeholders
  -- may become true. Re-render once after a delay to pick up the corrected state.
  if stats.images == 0 and stats.errors > 0 and PlacementMod then
    local ok_env, env = pcall(function() return Snacks.image.terminal.env() end)
    if ok_env and env and not env.placeholders then
      -- Schedule a single retry after DA3 detection timeout (1200ms).
      -- The detect() callback will have fired by then and env cache will be
      -- populated (or timed out). Invalidate env cache before retry.
      vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if not embeds_visible[bufnr] then return end
        -- Invalidate env cache so it re-evaluates with DA3 result
        local term = Snacks.image.terminal
        if term._env and not term._env.placeholders then
          term._env = nil
        end
        -- Check again after invalidation
        local ok2, env2 = pcall(function() return Snacks.image.terminal.env() end)
        if ok2 and env2 and env2.placeholders then
          M.render_embeds({ silent = true })
        end
      end, 1200)
    end
  end

  -- Show render summary (helps diagnose image issues) — skip in silent mode
  if not opts.silent then
    -- ...
  end
```

### Fix 3: Enhance `debug_info()` with terminal detection state

Add explicit reporting of the detection state and cache validity to
`:VaultEmbedDebug` so the user can diagnose whether the race condition is
occurring.

**File:** `lua/andrew/vault/embed.lua`

Add inside the `debug_info()` function, after the existing env var section
(around line 621):

Before:

```lua
  -- Environment variables
  info[#info + 1] = "  SNACKS_KITTY: " .. tostring(os.getenv("SNACKS_KITTY") or "unset")
  info[#info + 1] = "  KITTY_WINDOW_ID: " .. tostring(os.getenv("KITTY_WINDOW_ID") or "unset")
  info[#info + 1] = "  KITTY_PID: " .. tostring(os.getenv("KITTY_PID") or "unset")
  info[#info + 1] = "  TERM: " .. tostring(os.getenv("TERM") or "unset")
```

After:

```lua
  -- Environment variables
  info[#info + 1] = "  SNACKS_KITTY: " .. tostring(os.getenv("SNACKS_KITTY") or "unset")
  info[#info + 1] = "  KITTY_WINDOW_ID: " .. tostring(os.getenv("KITTY_WINDOW_ID") or "unset")
  info[#info + 1] = "  KITTY_PID: " .. tostring(os.getenv("KITTY_PID") or "unset")
  info[#info + 1] = "  TERM: " .. tostring(os.getenv("TERM") or "unset")

  -- Terminal detection state (race condition diagnosis)
  if Snacks and Snacks.image and Snacks.image.terminal then
    local term = Snacks.image.terminal
    info[#info + 1] = ""
    info[#info + 1] = "  --- Terminal detection state ---"
    info[#info + 1] = "  _env cached: " .. tostring(term._env ~= nil)
    if term._env then
      info[#info + 1] = "  _env.name: " .. tostring(term._env.name)
      info[#info + 1] = "  _env.supported: " .. tostring(term._env.supported)
      info[#info + 1] = "  _env.placeholders: " .. tostring(term._env.placeholders)
    end
    info[#info + 1] = "  _terminal cached: " .. tostring(term._terminal ~= nil)
    if term._terminal then
      info[#info + 1] = "  _terminal.terminal: " .. tostring(term._terminal.terminal)
      info[#info + 1] = "  _terminal.version: " .. tostring(term._terminal.version)
      local pending = term._terminal.pending
      info[#info + 1] = "  _terminal.pending: " .. (pending and (#pending .. " callbacks") or "nil (detection complete)")
    end
    -- Check for poisoned cache: SNACKS_KITTY is set but placeholders is nil/false
    if vim.env.SNACKS_KITTY == "1" and term._env and not term._env.placeholders then
      info[#info + 1] = "  *** RACE DETECTED: SNACKS_KITTY=1 but placeholders=" .. tostring(term._env.placeholders)
      info[#info + 1] = "  *** env() was cached before SNACKS_KITTY was set or before DA3 completed"
      info[#info + 1] = "  *** Run :VaultImageRetry to invalidate cache and re-render"
    end
  end
```

### Fix 4: Add `:VaultImageRetry` command

A manual command that invalidates the snacks terminal env cache and re-renders
embeds. Useful for diagnosing and recovering from the race condition.

**File:** `lua/andrew/vault/embed.lua`

Add inside `M.setup()`, after the existing command definitions:

```lua
  vim.api.nvim_create_user_command("VaultImageRetry", function()
    -- Invalidate snacks terminal env cache
    if Snacks and Snacks.image and Snacks.image.terminal then
      local term = Snacks.image.terminal
      local old_placeholders = term._env and term._env.placeholders
      term._env = nil
      -- Force synchronous re-detect (blocks up to 1500ms)
      local ok, env = pcall(function() return term.env() end)
      if ok and env then
        vim.notify(
          "Vault: terminal re-detected:"
          .. " name=" .. tostring(env.name)
          .. " placeholders=" .. tostring(env.placeholders)
          .. " (was " .. tostring(old_placeholders) .. ")",
          vim.log.levels.INFO
        )
      end
    end
    -- Re-render embeds with fresh env state
    M.render_embeds()
  end, { desc = "Vault: invalidate terminal cache and re-render images" })
```

### Fix 5: Add `on_update` callback for deferred image readiness

When a placement is created before the image has finished converting, the
placement internally waits for the image to be ready. However, for inline
images, the fallback when `placeholders` is nil is to do nothing. Use the
`on_update` callback in placement opts to detect when the image becomes ready
and verify the rendering path is correct.

**File:** `lua/andrew/vault/embed.lua`

In the `render_embeds` function, modify the placement creation (around line
427):

Before:

```lua
          local ok, placement = pcall(PlacementMod.new, bufnr, src, merge({}, snacks_doc_cfg, {
            pos = { i, s - 1 },
            range = { i, s - 1, i, e },
            inline = true,
            conceal = false,
            type = "image",
          }))
```

After:

```lua
          local placement_bufnr = bufnr  -- capture for closure
          local ok, placement = pcall(PlacementMod.new, bufnr, src, merge({}, snacks_doc_cfg, {
            pos = { i, s - 1 },
            range = { i, s - 1, i, e },
            inline = true,
            conceal = false,
            type = "image",
            on_update = function(p)
              -- If env cache was poisoned (placeholders was nil when placement
              -- was created, but DA3 detection has since completed), the
              -- placement's update() will use render_fallback which is a no-op
              -- for inline images. Detect this and schedule a full re-render.
              if not p.closed and embeds_visible[placement_bufnr] then
                local ok_e, env = pcall(function() return Snacks.image.terminal.env() end)
                if ok_e and env and not env.placeholders then
                  -- Still no placeholders — check if SNACKS_KITTY should fix it
                  if vim.env.SNACKS_KITTY == "1" then
                    Snacks.image.terminal._env = nil
                    vim.schedule(function()
                      if embeds_visible[placement_bufnr] then
                        M.render_embeds({ silent = true })
                      end
                    end)
                  end
                end
              end
            end,
          }))
```

## Files Modified

| File | Change |
|------|--------|
| `lua/andrew/plugins/snacks.lua` | Move SNACKS_KITTY detection to parse time; add init() cache invalidation |
| `lua/andrew/vault/embed.lua` | Add retry logic after render; enhance debug_info(); add `:VaultImageRetry`; add `on_update` callback |

## Test Plan

### 1. Verify env var is set before Snacks loads

```vim
" Check that SNACKS_KITTY is set (should be "1" in Kitty terminal)
:echo $SNACKS_KITTY
```

### 2. Verify placeholders are detected correctly

```vim
:VaultEmbedDebug
" Look for:
"   terminal.env.placeholders: true
"   _env cached: true
"   _env.placeholders: true
" If you see the "RACE DETECTED" warning, the fix is not working.
```

### 3. Test image rendering in a vault note

1. Open a vault markdown file that contains `![[some-image.png]]`.
2. Embeds should auto-render after 150ms.
3. The image should appear inline (as a Kitty Unicode placeholder grid, not a
   floating window).
4. Run `:VaultEmbedDebug` and verify `stats.images > 0` and
   `stats.errors == 0`.

### 4. Simulate the race condition

```lua
-- In a scratch buffer, before opening any vault file:
-- Manually poison the env cache
Snacks.image.terminal._env = { name = "", env = {} }
-- Now open a vault file with an image embed
-- The retry logic should detect placeholders=nil, wait 1200ms,
-- invalidate the cache, and re-render successfully.
```

### 5. Test `:VaultImageRetry`

```vim
" Manually invalidate and recover:
:VaultImageRetry
" Should show notification with terminal name and placeholders=true
" Image embeds should re-render correctly
```

### 6. Test in non-Kitty terminal

In a terminal that does NOT support Kitty graphics protocol (e.g., plain
xterm), verify that:

- `SNACKS_KITTY` is NOT set (no false positive).
- Images fall back to the float renderer (or show nothing inline).
- No error spam from the retry logic.

### 7. Verify no performance regression

1. Open a vault file with 10+ image embeds.
2. Measure render time (`:VaultEmbedRender` should complete in <500ms).
3. The retry timer (1200ms) should only fire once per render cycle, not per
   image.

## Implementation Notes

- The `_env` cache invalidation directly accesses snacks internals
  (`Snacks.image.terminal._env`). This is fragile if snacks changes its
  internal structure. Pin to a known snacks version or check for the field's
  existence before accessing.
- The 1200ms retry delay is chosen to be slightly longer than snacks' 1000ms
  DA3 detection timeout, ensuring the detection has either succeeded or timed
  out by the time we retry.
- The `on_update` callback approach (Fix 5) is aggressive and may cause
  multiple re-renders in edge cases. Consider adding a per-buffer flag to
  limit the retry to once per render cycle.
- Fix 1 (parse-time env var) is the most important change and should be
  implemented first. Fixes 2-5 are defensive layers.
