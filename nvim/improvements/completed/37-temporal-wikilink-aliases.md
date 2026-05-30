# 37 — Temporal Wikilink Aliases ([[today]], [[yesterday]], [[tomorrow]])

## Problem

Obsidian supports natural-language temporal references in wikilinks — `[[today]]` opens today's daily note, `[[yesterday]]` opens yesterday's, etc. The vault plugin has all the building blocks for this (daily log creation, date arithmetic, link resolution), but they are disconnected: `wikilinks.resolve_link()` sends every link name straight to the vault index, which can only match note names and aliases. Typing `[[today]]` either resolves to a note literally named "today.md" or creates a new file called `today.md` in the current directory — neither of which is the desired behavior.

This gap surfaces in every link-consuming module:

| Surface | What Happens Today | Desired Behavior |
|---------|-------------------|------------------|
| **Link following** (`gf`) | Creates `today.md` in current dir (note-not-found path) | Opens/creates `Log/2026-02-26.md` |
| **Preview** (`K`) | "Note not found: today" | Shows floating preview of today's daily log |
| **Embed** (`![[today]]`) | `[Note not found]` virtual text | Transclude today's daily log content |
| **Completion** (`[[tod…`) | No special handling | Could offer `today`, `tomorrow` as candidates |
| **Link diagnostics** | Reports `[[today]]` as broken | Recognizes it as a valid temporal alias |

The navigate module already has `daily_today()`, `daily_next()`, and `daily_prev()` which know how to open and auto-create daily logs. The engine module provides `today()`, `date_offset()`, `date_offset_from()`, and `parse_date()`. All the date arithmetic exists — it just needs to be wired into the link resolution pipeline.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **wikilinks.lua** | `resolve_link(link_name)` resolves via vault_index, picks closest path; `follow_link()` handles `gf`/`gx` with auto-create on miss | `lua/andrew/vault/wikilinks.lua` |
| **vault_index.lua** | `resolve_name(name)` checks `_name_index` (basenames, rel path stems) and `_alias_index`; returns abs path(s) | `lua/andrew/vault/vault_index.lua` |
| **navigate.lua** | `open_daily(date, auto_create)` opens `{vault}/{Log}/{YYYY-MM-DD}.md`; `daily_today()` auto-creates from template | `lua/andrew/vault/navigate.lua` |
| **engine.lua** | `today()`, `date_offset(days)`, `date_offset_from(date_str, days)`, `parse_date(date_str)` — all date arithmetic helpers | `lua/andrew/vault/engine.lua` |
| **config.lua** | `config.dirs.log` — the daily log directory name (e.g., `"Log"`) | `lua/andrew/vault/config.lua` |
| **preview.lua** | Uses `wikilinks.resolve_link(details.name)` for cross-file preview resolution | `lua/andrew/vault/preview.lua` |
| **embed.lua** | `resolve_embed(name, bufnr)` calls `wikilinks.resolve_link(name)` for cross-file embeds | `lua/andrew/vault/embed.lua` |
| **completion.lua** | Note name completion inside `[[…]]` — reads vault index names, no temporal awareness | `lua/andrew/vault/completion.lua` |

---

## Proposed Solution

### Design Decision: Temporal Aliases vs. Real Notes

**Decision: Vault index takes priority. Temporal aliases are a fallback.**

If the user has a real note named `today.md` in their vault, `[[today]]` resolves to that note (existing behavior preserved). Temporal alias resolution only activates when the vault index returns no matches. This is the safest approach:

1. **No surprises** — existing vaults with notes named "today" or "tomorrow" continue to work identically.
2. **Explicit opt-out** — if a user wants `[[today]]` to always mean the daily log, they simply ensure no note named `today.md` exists.
3. **Consistent with Obsidian** — Obsidian's "Daily notes" plugin similarly only intercepts temporal terms when no real note matches.

The only exception is `follow_link()`: when a temporal alias resolves to a daily log path that does not yet exist on disk, it auto-creates from template (matching `navigate.daily_today()` behavior) instead of creating a bare `today.md`.

### Architecture

The implementation adds a single resolver function — `resolve_temporal(name)` — that sits in `wikilinks.lua` between the link name extraction and the vault index lookup. The function:

1. Checks if the link name matches a known temporal alias (case-insensitive).
2. Computes the target date using `engine.today()` and `engine.date_offset()`.
3. Returns the absolute path to the daily log file for that date.

This function is called from `resolve_link()` only as a fallback after vault_index lookup fails, and is also exposed as `M.resolve_temporal` so that preview, embed, and completion modules can use it.

```
Link resolution flow (updated):

  [[link_name]]
       │
       ▼
  vault_index:resolve_name(name)
       │
       ├─ Found? → pick_closest(paths) → done
       │
       └─ Not found?
              │
              ▼
         resolve_temporal(name)
              │
              ├─ Matches alias? → return daily log path
              │
              └─ No match? → return nil (triggers create-new-note flow)
```

### Implementation

#### New Config: `config.temporal_aliases`

**File:** `lua/andrew/vault/config.lua`

```lua
-- ---------------------------------------------------------------------------
-- Temporal wikilink aliases ([[today]], [[yesterday]], etc.)
-- ---------------------------------------------------------------------------
M.temporal_aliases = {
  enabled = true,
  --- Static aliases: name -> day offset from today.
  --- Case-insensitive matching. Keys must be lowercase.
  ---@type table<string, number>
  aliases = {
    ["today"]     = 0,
    ["yesterday"] = -1,
    ["tomorrow"]  = 1,
  },
  --- Enable relative weekday aliases like [[last monday]], [[next friday]].
  --- Adds dynamic resolution for "last <weekday>" and "next <weekday>".
  relative_weekdays = true,
}
```

#### New Function: `resolve_temporal()`

**File:** `lua/andrew/vault/wikilinks.lua`

Add immediately before the existing `resolve_link()` function (before line 59):

```lua
--- Weekday name to os.date wday number (Sunday=1 .. Saturday=7).
---@type table<string, number>
local WEEKDAYS = {
  sunday = 1, monday = 2, tuesday = 3, wednesday = 4,
  thursday = 5, friday = 6, saturday = 7,
}

--- Resolve a temporal alias to the absolute path of a daily log.
--- Returns nil if the name is not a recognized temporal alias.
--- Does NOT check whether the file exists — callers decide how to handle missing files.
---@param name string link name (e.g., "today", "last monday")
---@return string|nil abs_path to the daily log file
---@return string|nil date in YYYY-MM-DD format (for callers that need it)
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
          diff = today_wday - target_wday
          if diff <= 0 then diff = diff + 7 end
          diff = -diff
        else -- "next"
          diff = target_wday - today_wday
          if diff <= 0 then diff = diff + 7 end
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

#### Updated `resolve_link()` — Temporal Fallback

**File:** `lua/andrew/vault/wikilinks.lua`

Replace the current `resolve_link()` (lines 59-68) with:

```lua
--- Resolve a wikilink name to an absolute file path.
--- Checks the vault index first (real notes take priority), then falls back
--- to temporal alias resolution for names like "today", "yesterday", etc.
---@param link_name string
---@return string|nil abs_path
local function resolve_link(link_name)
  -- Primary: vault index lookup (real notes always win)
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local paths = idx:resolve_name(link_name)
    if paths and #paths > 0 then
      return pick_closest(paths)
    end
  end

  -- Fallback: temporal alias resolution
  local temporal_path = resolve_temporal(link_name)
  if temporal_path then
    return temporal_path
  end

  return nil
end
```

#### Updated `follow_link()` — Auto-Create Daily Logs

**File:** `lua/andrew/vault/wikilinks.lua`

The note-not-found branch in `follow_link()` (lines 192-209) already creates new notes. We need to intercept temporal aliases before that generic create path so they get proper template-based creation. Replace lines 192-209 (the `else` branch after `if path then`) with:

```lua
      else
        -- Check if this is a temporal alias that should auto-create a daily log
        local temporal_path, temporal_date = resolve_temporal(link)
        if temporal_path and temporal_date then
          -- Use navigate.open_daily() for template-based creation
          local navigate = require("andrew.vault.navigate")
          navigate.open_daily_by_date(temporal_date, true)
          return
        end

        -- Create new notes in the same directory as the current buffer (Obsidian behavior)
        local buf_dir = vim.fn.expand("%:p:h")
        local new_path
        if engine.is_vault_path(buf_dir) then
          new_path = buf_dir .. "/" .. link .. ".md"
        else
          new_path = engine.vault_path .. "/" .. link .. ".md"
        end
        local dir = vim.fn.fnamemodify(new_path, ":h")
        vim.fn.mkdir(dir, "p")
        vim.cmd("edit " .. vim.fn.fnameescape(new_path))
        -- Update vault index for the new file
        local idx = vault_index.current()
        if idx then idx:update_file(new_path) end
        vim.notify("Created: " .. link .. ".md", vim.log.levels.INFO)
      end
```

#### New Navigate Helper: `open_daily_by_date()`

**File:** `lua/andrew/vault/navigate.lua`

The existing `open_daily(date, auto_create)` is a local function. We need to expose a public version for wikilinks.lua to call. Add after the existing `daily_today()` (after line 132):

```lua
--- Open a daily log by explicit date string, with optional auto-creation.
--- Public wrapper around open_daily() for use by other modules (e.g., temporal aliases).
---@param date string YYYY-MM-DD
---@param auto_create? boolean
function M.open_daily_by_date(date, auto_create)
  open_daily(date, auto_create)
end
```

#### Expose `resolve_temporal` for Other Modules

**File:** `lua/andrew/vault/wikilinks.lua`

Update the public API exports at the bottom of the file (lines 385-388):

```lua
-- Expose for use by other vault modules (embed, preview, etc.)
M.resolve_link = resolve_link
M.resolve_temporal = resolve_temporal
M.find_block_in_file = find_block_in_file
```

---

## Configuration

**File:** `lua/andrew/vault/config.lua`

Insert after the `autosave` section (after line 153):

```lua
-- ---------------------------------------------------------------------------
-- Temporal wikilink aliases ([[today]], [[yesterday]], etc.)
-- ---------------------------------------------------------------------------
M.temporal_aliases = {
  enabled = true,
  --- Static aliases: name -> day offset from today.
  --- Case-insensitive matching. Keys must be lowercase.
  ---@type table<string, number>
  aliases = {
    ["today"]     = 0,
    ["yesterday"] = -1,
    ["tomorrow"]  = 1,
  },
  --- Enable relative weekday aliases like [[last monday]], [[next friday]].
  --- Adds dynamic resolution for "last <weekday>" and "next <weekday>".
  relative_weekdays = true,
}
```

**Customization examples:**

```lua
-- Add custom offsets:
config.temporal_aliases.aliases["last week"] = -7
config.temporal_aliases.aliases["next week"] = 7

-- Disable relative weekday parsing (keep only static aliases):
config.temporal_aliases.relative_weekdays = false

-- Disable entirely (all temporal names resolve via vault index only):
config.temporal_aliases.enabled = false
```

---

## File Changes

| File | Change |
|------|--------|
| `lua/andrew/vault/config.lua` | Add `M.temporal_aliases` config section |
| `lua/andrew/vault/wikilinks.lua` | Add `resolve_temporal()` function; update `resolve_link()` with temporal fallback; update `follow_link()` note-not-found branch to auto-create daily logs for temporal aliases; export `resolve_temporal` |
| `lua/andrew/vault/navigate.lua` | Add `M.open_daily_by_date(date, auto_create)` public wrapper |

No changes needed to `preview.lua`, `embed.lua`, or `linkcheck.lua` — they all call `wikilinks.resolve_link()`, which now handles temporal aliases transparently. The resolution happens at the `resolve_link` level, so all downstream consumers benefit automatically.

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `today()`, `date_offset(days)`, `vault_path` for date arithmetic and path construction | Yes (unchanged) |
| `config.lua` | `config.temporal_aliases` for alias map and feature toggle; `config.dirs.log` for daily log directory | Yes (new config section) |
| `vault_index.lua` | Primary resolution path (unchanged); temporal is fallback only | Yes (unchanged) |
| `navigate.lua` | `open_daily_by_date()` for template-based daily log creation in `follow_link()` | Yes (new public wrapper) |
| `link_utils.lua` | `parse_target()` for wikilink parsing (unchanged) | Yes (unchanged) |
| `preview.lua` | Calls `wikilinks.resolve_link()` — benefits automatically, no changes | No changes needed |
| `embed.lua` | Calls `wikilinks.resolve_link()` via `resolve_embed()` — benefits automatically, no changes | No changes needed |

---

## Testing Plan

### Manual Verification

#### 1. Basic temporal aliases (gf)

Open any vault markdown file and add these links:

```markdown
- Link to today: [[today]]
- Link to yesterday: [[yesterday]]
- Link to tomorrow: [[tomorrow]]
```

Place cursor on each link and press `gf`.

**Expected:**
- `[[today]]` opens `Log/2026-02-26.md` (auto-creates from template if missing)
- `[[yesterday]]` opens `Log/2026-02-25.md`
- `[[tomorrow]]` opens `Log/2026-02-27.md`

#### 2. Relative weekday aliases (gf)

```markdown
- [[last monday]]
- [[next friday]]
- [[last sunday]]
```

**Expected:** Each opens the correct daily log based on day-of-week arithmetic.

#### 3. Preview (K key)

Place cursor on `[[today]]` and press `K`.

**Expected:** Floating preview shows the content of today's daily log. If the daily log exists, its content is displayed. If it does not exist, the preview shows "Note not found" (same as any non-existent note — the preview module does not auto-create).

#### 4. Embed rendering

```markdown
![[today]]
![[yesterday#Some Heading]]
```

**Expected:** `![[today]]` transcludes the full content of today's daily log as virtual text. `![[yesterday#Some Heading]]` transcludes only the specified heading section from yesterday's log.

#### 5. Real note takes priority

Create a file named `today.md` in the vault root (not in Log/):

```markdown
# Today
This is a real note called today.
```

Now place cursor on `[[today]]` and press `gf`.

**Expected:** Opens the real `today.md` file (vault index match takes priority). Delete `today.md` and try again — now it resolves to `Log/2026-02-26.md`.

#### 6. Case insensitivity

```markdown
[[Today]]
[[YESTERDAY]]
[[Last Monday]]
[[NEXT FRIDAY]]
```

**Expected:** All resolve correctly (lowercase normalization in `resolve_temporal()`).

#### 7. Feature toggle

```vim
:lua require("andrew.vault.config").temporal_aliases.enabled = false
```

Now `[[today]]` should fall through to the create-new-note path (creating `today.md`). Re-enable:

```vim
:lua require("andrew.vault.config").temporal_aliases.enabled = true
```

#### 8. Auto-creation from template

Delete today's daily log if it exists:

```vim
:!rm -f {vault_path}/Log/2026-02-26.md
```

Press `gf` on `[[today]]`. Verify:
- The file is created at `Log/2026-02-26.md`
- It uses the daily log template (same as `:VaultDailyToday` / `navigate.daily_today()`)
- It is NOT created as a bare `today.md` in the current directory

#### 9. Link diagnostics

Run `:VaultLinkCheck` on a buffer containing `[[today]]`.

**Expected:** `[[today]]` is NOT reported as a broken link (because `resolve_link()` returns a path for it, even if the file does not exist on disk). If the daily log file does not exist, the link diagnostic should still pass — temporal aliases are always "valid" from a resolution standpoint. The linkcheck module calls `link_exists()` which may need a separate consideration; if it uses a different path than `resolve_link()`, temporal aliases may still show as broken in diagnostics. This is acceptable for the initial implementation — linkcheck integration can be a follow-up.

### Performance Verification

The temporal resolution adds at most two string operations (lowercase + table lookup) to the not-found path. No I/O, no regex, no vault scanning. Measure with:

```vim
:lua local s = vim.uv.hrtime(); for i = 1, 10000 do require("andrew.vault.wikilinks").resolve_link("today") end; print(("%.1f ms per 10k"):format((vim.uv.hrtime() - s) / 1e6))
```

**Target:** < 10ms for 10,000 resolutions (the vault index lookup dominates).

### Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| `[[today]]` with real `today.md` in vault | Real note wins (vault index match) |
| `[[today]]` with no daily log on disk | `resolve_link()` returns the path; `follow_link()` auto-creates from template |
| `[[today]]` in embed (`![[today]]`) | Transcludes daily log content; shows `[Note not found]` if file missing |
| `[[today]]` in preview (`K`) | Shows daily log content; shows "Note not found" if file missing |
| `[[Today]]` / `[[TODAY]]` | Case-insensitive match; resolves correctly |
| `[[last monday]]` when today IS Monday | Goes back 7 days (previous Monday, not today) |
| `[[next monday]]` when today IS Monday | Goes forward 7 days (next Monday, not today) |
| `[[last sometypo]]` | No weekday match; falls through to vault index (nil) |
| Temporal aliases disabled in config | All temporal names resolve via vault index only; no fallback |
| Vault index not ready yet | `resolve_link()` skips index lookup, falls directly to temporal; temporal alias still works |
| `[[today#Morning]]` (temporal + heading) | `resolve_link("today")` returns daily log path; `follow_link()` then jumps to heading |
| `[[today^blk-abc]]` (temporal + block ref) | `resolve_link("today")` returns daily log path; `follow_link()` then jumps to block |
| Empty `config.temporal_aliases.aliases` table | Only relative weekdays are checked (if enabled) |
| `config.dirs.log` changed | Path construction uses `config.dirs.log` dynamically; no hardcoded "Log" |
