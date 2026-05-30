# 44 --- Extract Magic Numbers to Config Constants

## Motivation

Several vault modules contain hardcoded numeric literals ("magic numbers") that
control behavior such as debounce intervals, extmark priorities, border widths,
scroll amounts, and retry delays. When these values are scattered across
individual module files, they are:

1. **Hard to discover** -- a user wanting to tweak embed border width or
   highlight debounce timing has no single place to look.
2. **Inconsistent** -- four highlight modules each define their own
   `local DEBOUNCE_MS` that duplicates (and could drift from) the value already
   present in `config.lua`.
3. **Not overridable** -- values hardcoded as `local` constants cannot be
   changed at runtime without editing the source file.

Centralizing these into `config.lua` makes the system self-documenting and
allows all behavior tuning from a single file.

---

## Current State Analysis

### What is already in config.lua

The following values are already defined in `config.lua` and referenced
correctly by their respective modules:

| Config path | Value | Used by |
|-------------|-------|---------|
| `config.preview.max_lines` | 25 | `preview.lua` line 364 |
| `config.preview.max_width` | 80 | `preview.lua` line 363 |
| `config.preview.history_max` | 20 | `preview.lua` line 639 (reads config at runtime) |
| `config.embed.max_lines` | 20 | `embed.lua` line 259 |
| `config.embed.max_depth` | 5 | `embed.lua` line 300 |
| `config.embed.max_total_lines` | 150 | `embed.lua` line 498 |
| `config.embed.sync.debounce_ms` | 300 | `embed.lua` (sync subsystem) |
| `config.embed.sync.self_debounce_ms` | 500 | `embed.lua` (sync subsystem) |
| `config.index.batch_size` | 20 | `vault_index.lua` via `configure()` |
| `config.index.persist_debounce_ms` | 5000 | `vault_index.lua` via `configure()` |
| `config.index.progress_threshold` | 50 | `vault_index.lua` via `configure()` |
| `config.wikilink_highlights.debounce_ms` | 150 | **NOT used** (see below) |
| `config.tag_highlights.debounce_ms` | 200 | **NOT used** (see below) |
| `config.inline_fields.debounce_ms` | 200 | **NOT used** (see below) |
| `config.highlight_marks.debounce_ms` | 200 | **NOT used** (see below) |

### What is NOT in config.lua (magic numbers to extract)

| File | Line | Current code | Value | Purpose |
|------|------|-------------|-------|---------|
| `wikilink_highlights.lua` | 13 | `local DEBOUNCE_MS = 150` | 150 | Debounce for wikilink highlight refresh |
| `tag_highlights.lua` | 12 | `local DEBOUNCE_MS = 200` | 200 | Debounce for tag highlight refresh |
| `inline_fields.lua` | 12 | `local DEBOUNCE_MS = 200` | 200 | Debounce for inline field highlight refresh |
| `highlights.lua` | 12 | `local DEBOUNCE_MS = 200` | 200 | Debounce for `==highlight==` mark refresh |
| `preview.lua` | 43 | `max_size = 20,` | 20 | Preview history stack max size |
| `preview.lua` | 369 | `width = math.min(math.max(width, 20), max_width)` | 20 | Preview float minimum width |
| `preview.lua` | 681 | `local scroll_amount = 3` | 3 | Preview scroll step (lines per C-j/C-k) |
| `preview.lua` | 552 | `scroll_preview(3)` | 3 | Preview scroll step in focused mode |
| `preview.lua` | 750 | `math.floor(editor_width * 0.8)` | 0.8 | Edit float width ratio |
| `preview.lua` | 751 | `math.floor(editor_height * 0.6)` | 0.6 | Edit float height ratio |
| `embed.lua` | 148 | `math.max(4, 50 - prefix_w - ...)` | 50 | Embed border total width |
| `embed.lua` | 155 | `string.rep("─", 50)` | 50 | Embed footer border width |
| `embed.lua` | 671 | `end, 1200)` | 1200 | Image retry delay (ms) for DA3 detection |
| `blockid.lua` | 57 | `"blk-" .. random_id(6)` | 6 | Block ID random suffix length |
| `blockid.lua` | 56 | `for _ = 1, 100 do` | 100 | Max collision retries for block ID |

**Note:** The extmark `priority` values (200, 195, 190, 185, 180) form a
deliberate layering system (wikilinks on top, then highlights, tags, inline
fields, autolinks). These are better left as local constants with comments
explaining the layering, rather than put in config -- users changing one
priority without understanding the ordering would break the visual layering.
They are excluded from this improvement.

---

## Implementation

### Target Files

All config additions go into **`lua/andrew/vault/config.lua`**. Each consuming
module gets a one-line change replacing its hardcoded constant with a config
reference.

---

### Group 1: Highlight Debounce Constants (4 modules)

All four highlight modules define `local DEBOUNCE_MS = N` but never read from
their corresponding `config.*` section, which already has a `debounce_ms` field.

#### File: `lua/andrew/vault/wikilink_highlights.lua`

**Before** (line 13):

```lua
local DEBOUNCE_MS = 150
```

**After:**

```lua
local config = require("andrew.vault.config")
```

(Add at top of file, alongside existing requires.)

Then on line 198 where `DEBOUNCE_MS` is used:

**Before:**

```lua
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
```

**After:**

```lua
  timer:start(config.wikilink_highlights.debounce_ms, 0, vim.schedule_wrap(function()
```

Remove the `local DEBOUNCE_MS = 150` line entirely.

#### File: `lua/andrew/vault/tag_highlights.lua`

**Before** (line 12):

```lua
local DEBOUNCE_MS = 200
```

**After:**

Replace usage on line 187:

```lua
  timer:start(config.tag_highlights.debounce_ms, 0, vim.schedule_wrap(function()
```

Add `local config = require("andrew.vault.config")` at top. Remove
`local DEBOUNCE_MS = 200`.

#### File: `lua/andrew/vault/inline_fields.lua`

**Before** (line 12):

```lua
local DEBOUNCE_MS = 200
```

**After:**

Replace usage on line 440:

```lua
  timer:start(config.inline_fields.debounce_ms, 0, vim.schedule_wrap(function()
```

Add `local config = require("andrew.vault.config")` at top if not already
present. Remove `local DEBOUNCE_MS = 200`.

#### File: `lua/andrew/vault/highlights.lua`

**Before** (line 12):

```lua
local DEBOUNCE_MS = 200
```

**After:**

Replace usage on line 103:

```lua
  timer:start(config.highlight_marks.debounce_ms, 0, vim.schedule_wrap(function()
```

Add `local config = require("andrew.vault.config")` at top if not already
present. Remove `local DEBOUNCE_MS = 200`.

**No config.lua changes needed** -- all four `debounce_ms` fields already exist
in their respective config sections with the correct default values.

---

### Group 2: Preview History `max_size` (already partly done)

The `history.max_size` in `preview.lua` is initialized to `20` on line 43 but
is overwritten from config on line 639 (`history.max_size = config.preview.history_max or 20`).
The issue is that the struct initialization on line 43 still carries a hardcoded
default that could diverge from the config default.

#### File: `lua/andrew/vault/preview.lua`

**Before** (lines 40-44):

```lua
local history = {
  entries = {},
  cursor = 0,
  max_size = 20,
}
```

**After:**

```lua
local history = {
  entries = {},
  cursor = 0,
  max_size = config.preview.history_max,
}
```

This is safe because `config` is already required at the top of `preview.lua`
(line 2: `local config = require("andrew.vault.config")`), and the struct is
initialized at module load time when config is already available.

Also remove the fallback on line 639 since the struct already uses the config
value:

**Before** (line 639):

```lua
  history.max_size = config.preview.history_max or 20
```

**After:**

```lua
  history.max_size = config.preview.history_max
```

---

### Group 3: Preview Scroll Amount

The scroll step for `<C-j>`/`<C-k>` is hardcoded as `3` in two places: line
681 (parent buffer scroll) and lines 552/556 (focused mode scroll).

#### Config Addition

**File: `lua/andrew/vault/config.lua`**

Add `scroll_lines` to the `M.preview` section:

**Before** (lines 58-70):

```lua
M.preview = {
  max_lines = 25,
  max_width = 80,
  -- History navigation within the preview float.
  -- Tracks previously-viewed targets for <C-o>/<C-i> navigation.
  history_max = 20,
  -- Allow following wikilinks inside the preview float (gf/K in float).
  nested_preview = true,
  -- Breadcrumb title style: "full" (vault-relative path), "short" (note name only), "none" (legacy title).
  breadcrumb_style = "full",
  -- Separator character between breadcrumb segments.
  breadcrumb_separator = " \u{203A} ",
}
```

**After:**

```lua
M.preview = {
  max_lines = 25,
  max_width = 80,
  min_width = 20,
  -- Lines to scroll per <C-j>/<C-k> keypress in the preview float.
  scroll_lines = 3,
  -- History navigation within the preview float.
  -- Tracks previously-viewed targets for <C-o>/<C-i> navigation.
  history_max = 20,
  -- Allow following wikilinks inside the preview float (gf/K in float).
  nested_preview = true,
  -- Breadcrumb title style: "full" (vault-relative path), "short" (note name only), "none" (legacy title).
  breadcrumb_style = "full",
  -- Separator character between breadcrumb segments.
  breadcrumb_separator = " \u{203A} ",
  -- Edit float size (fraction of editor dimensions).
  edit_width_ratio = 0.8,
  edit_height_ratio = 0.6,
}
```

#### File: `lua/andrew/vault/preview.lua`

**Before** (line 369):

```lua
  width = math.min(math.max(width, 20), max_width)
```

**After:**

```lua
  width = math.min(math.max(width, config.preview.min_width), max_width)
```

**Before** (lines 550-557, focused mode scroll):

```lua
  vim.keymap.set("n", "<C-j>", function()
    scroll_preview(3)
  end, vim.tbl_extend("force", opts, { desc = "Scroll preview down" }))

  vim.keymap.set("n", "<C-k>", function()
    scroll_preview(-3)
  end, vim.tbl_extend("force", opts, { desc = "Scroll preview up" }))
```

**After:**

```lua
  vim.keymap.set("n", "<C-j>", function()
    scroll_preview(config.preview.scroll_lines)
  end, vim.tbl_extend("force", opts, { desc = "Scroll preview down" }))

  vim.keymap.set("n", "<C-k>", function()
    scroll_preview(-config.preview.scroll_lines)
  end, vim.tbl_extend("force", opts, { desc = "Scroll preview up" }))
```

**Before** (lines 680-687, parent buffer scroll):

```lua
  local scroll_amount = 3
  vim.keymap.set("n", "<C-j>", function()
    scroll_preview(scroll_amount)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview down" })
  vim.keymap.set("n", "<C-k>", function()
    scroll_preview(-scroll_amount)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview up" })
```

**After:**

```lua
  vim.keymap.set("n", "<C-j>", function()
    scroll_preview(config.preview.scroll_lines)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview down" })
  vim.keymap.set("n", "<C-k>", function()
    scroll_preview(-config.preview.scroll_lines)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview up" })
```

Remove the `local scroll_amount = 3` line.

---

### Group 4: Edit Float Dimensions

The `edit_link()` function in `preview.lua` uses hardcoded `0.8` and `0.6`
ratios for the edit float size.

#### File: `lua/andrew/vault/preview.lua`

**Before** (lines 750-751):

```lua
  local width = math.floor(editor_width * 0.8)
  local height = math.floor(editor_height * 0.6)
```

**After:**

```lua
  local width = math.floor(editor_width * config.preview.edit_width_ratio)
  local height = math.floor(editor_height * config.preview.edit_height_ratio)
```

The config entries were added in Group 3 above (`edit_width_ratio = 0.8`,
`edit_height_ratio = 0.6`).

---

### Group 5: Embed Border Width

The embed header/footer use a hardcoded width of `50` characters for the border
line.

#### Config Addition

**File: `lua/andrew/vault/config.lua`**

Add `border_width` to the `M.embed` section:

**Before** (lines 75-91):

```lua
M.embed = {
  max_lines = 20,
  max_depth = 5,
  max_total_lines = 150,
  sync = {
    enabled = true,
    debounce_ms = 300,
    self_debounce_ms = 500,
  },
  image_exts = {
    png = true, jpg = true, jpeg = true, gif = true, svg = true,
    webp = true, bmp = true, tiff = true, heic = true, avif = true,
  },
}
```

**After:**

```lua
M.embed = {
  max_lines = 20,
  max_depth = 5,
  max_total_lines = 150,
  -- Total character width of embed header/footer border lines.
  border_width = 50,
  -- Delay (ms) before retrying image rendering after DA3 terminal detection.
  image_retry_delay_ms = 1200,
  sync = {
    enabled = true,
    debounce_ms = 300,
    self_debounce_ms = 500,
  },
  image_exts = {
    png = true, jpg = true, jpeg = true, gif = true, svg = true,
    webp = true, bmp = true, tiff = true, heic = true, avif = true,
  },
}
```

#### File: `lua/andrew/vault/embed.lua`

**Before** (lines 141-155):

```lua
local function embed_header(inner, suffix)
  local label = " ![[" .. inner .. "]]"
  if suffix then
    label = label .. " " .. suffix
  end
  label = label .. " "
  local prefix_w = 2
  local tail_w = math.max(4, 50 - prefix_w - vim.fn.strdisplaywidth(label))
  return string.rep("─", prefix_w) .. label .. string.rep("─", tail_w)
end

local function embed_footer()
  return string.rep("─", 50)
end
```

**After:**

```lua
local function embed_header(inner, suffix)
  local label = " ![[" .. inner .. "]]"
  if suffix then
    label = label .. " " .. suffix
  end
  label = label .. " "
  local border_w = config.embed.border_width
  local prefix_w = 2
  local tail_w = math.max(4, border_w - prefix_w - vim.fn.strdisplaywidth(label))
  return string.rep("─", prefix_w) .. label .. string.rep("─", tail_w)
end

local function embed_footer()
  return string.rep("─", config.embed.border_width)
end
```

---

### Group 6: Embed Image Retry Delay

The DA3 detection retry uses a hardcoded 1200ms delay.

#### File: `lua/andrew/vault/embed.lua`

**Before** (line 671):

```lua
      end, 1200)
```

**After:**

```lua
      end, config.embed.image_retry_delay_ms)
```

The config entry was added in Group 5 above (`image_retry_delay_ms = 1200`).

---

### Group 7: Block ID Constants

The `blockid.lua` module has two hardcoded values: the random suffix length (6)
and the max collision retries (100).

#### Config Addition

**File: `lua/andrew/vault/config.lua`**

Add a new `M.blockid` section after the embed section:

```lua
-- ---------------------------------------------------------------------------
-- Block ID generation
-- ---------------------------------------------------------------------------
M.blockid = {
  -- Length of the random alphanumeric suffix (e.g., 6 produces "blk-a1b2c3").
  suffix_length = 6,
  -- Maximum collision retry attempts before falling back to timestamp-based ID.
  max_retries = 100,
}
```

#### File: `lua/andrew/vault/blockid.lua`

Add config require at top:

```lua
local config = require("andrew.vault.config")
```

**Before** (lines 56-57):

```lua
  for _ = 1, 100 do
    local id = "blk-" .. random_id(6)
```

**After:**

```lua
  for _ = 1, config.blockid.max_retries do
    local id = "blk-" .. random_id(config.blockid.suffix_length)
```

---

## Summary Table

All magic numbers identified, their current locations, and the config path
they should reference:

| Module | Line | Current Value | Config Path | Already in config? |
|--------|------|---------------|-------------|-------------------|
| `wikilink_highlights.lua` | 13 | `DEBOUNCE_MS = 150` | `config.wikilink_highlights.debounce_ms` | Yes (unused) |
| `tag_highlights.lua` | 12 | `DEBOUNCE_MS = 200` | `config.tag_highlights.debounce_ms` | Yes (unused) |
| `inline_fields.lua` | 12 | `DEBOUNCE_MS = 200` | `config.inline_fields.debounce_ms` | Yes (unused) |
| `highlights.lua` | 12 | `DEBOUNCE_MS = 200` | `config.highlight_marks.debounce_ms` | Yes (unused) |
| `preview.lua` | 43 | `max_size = 20` | `config.preview.history_max` | Yes (partially used) |
| `preview.lua` | 369 | `20` (min width) | `config.preview.min_width` | **No -- add** |
| `preview.lua` | 681 | `scroll_amount = 3` | `config.preview.scroll_lines` | **No -- add** |
| `preview.lua` | 552 | `3` (focused scroll) | `config.preview.scroll_lines` | **No -- add** |
| `preview.lua` | 750 | `0.8` (edit width) | `config.preview.edit_width_ratio` | **No -- add** |
| `preview.lua` | 751 | `0.6` (edit height) | `config.preview.edit_height_ratio` | **No -- add** |
| `embed.lua` | 148 | `50` (border width) | `config.embed.border_width` | **No -- add** |
| `embed.lua` | 155 | `50` (footer width) | `config.embed.border_width` | **No -- add** |
| `embed.lua` | 671 | `1200` (retry delay) | `config.embed.image_retry_delay_ms` | **No -- add** |
| `blockid.lua` | 57 | `6` (ID length) | `config.blockid.suffix_length` | **No -- add** |
| `blockid.lua` | 56 | `100` (max retries) | `config.blockid.max_retries` | **No -- add** |

---

## Testing Instructions

### 1. Highlight Debounce (4 modules)

1. Open a markdown file in the vault with wikilinks, tags, inline fields, and
   `==highlight==` marks.
2. Verify all four highlight types still render correctly (visual inspection).
3. Type new content and observe the debounce delay -- highlights should appear
   after the configured delay, not instantly.
4. Change `config.wikilink_highlights.debounce_ms` to `1000` temporarily.
   Edit a wikilink and confirm the highlight refresh is visibly slower (~1s).
5. Restore the original value.

### 2. Preview History

1. Open a preview with `K` on a wikilink.
2. Follow links inside the preview with `<CR>` then `gf` to build up history.
3. Verify `<C-o>`/`<C-i>` navigate history correctly.
4. Confirm history does not grow past `config.preview.history_max` entries.
5. Temporarily set `history_max = 3` and verify that after 4 navigations, the
   oldest entry is dropped.

### 3. Preview Scroll

1. Open a preview on a note with content taller than the float.
2. Press `<C-j>` -- should scroll down by 3 lines (default).
3. Press `<C-k>` -- should scroll up by 3 lines.
4. Enter focused mode (`<CR>`) and verify `<C-j>`/`<C-k>` still scroll by 3.
5. Change `config.preview.scroll_lines` to `1` and verify single-line scroll.

### 4. Preview Min Width

1. Preview a note with very short content (e.g., a note containing just "Hi").
2. Verify the float is at least 20 columns wide (default `min_width`).
3. Change `config.preview.min_width` to `40` and preview again -- float should
   be at least 40 columns wide.

### 5. Edit Float Dimensions

1. Press `<leader>vE` on a wikilink to open the edit float.
2. Verify the float occupies approximately 80% width and 60% height of the
   editor.
3. Change `config.preview.edit_width_ratio` to `0.5` and reopen -- float
   should be noticeably narrower (50% of editor width).

### 6. Embed Borders

1. Open a file with `![[NoteEmbed]]` and run `:VaultEmbedRender`.
2. Verify the header and footer border lines are approximately 50 characters
   wide.
3. Change `config.embed.border_width` to `80` and re-render -- borders should
   be wider.
4. Verify the header label (`── ![[NoteName]] ────...`) still fills correctly
   with the new width.

### 7. Embed Image Retry

1. This is a timing-sensitive test -- primarily verify no regressions.
2. Open a file with `![[image.png]]` embeds and confirm images render.
3. Check `:VaultEmbedDebug` output to verify the retry mechanism still
   functions.

### 8. Block ID

1. Place cursor on a non-empty line and run `:VaultBlockId`.
2. Verify the generated ID has format `^blk-XXXXXX` (6 random characters).
3. Change `config.blockid.suffix_length` to `10` and generate another ID --
   should produce `^blk-XXXXXXXXXX` (10 characters).

---

## Post-Implementation Cleanup

After implementing all groups:

1. **Verify no remaining hardcoded duplicates.** Run:
   ```
   rg 'local DEBOUNCE_MS' lua/andrew/vault/
   ```
   Should return zero results.

2. **Verify config references.** Run:
   ```
   rg 'config\.(wikilink_highlights|tag_highlights|inline_fields|highlight_marks)\.debounce_ms' lua/andrew/vault/
   ```
   Should show four results, one per highlight module.

3. **Update MEMORY.md** with the new config paths:
   - `config.preview.scroll_lines`, `config.preview.min_width`,
     `config.preview.edit_width_ratio`, `config.preview.edit_height_ratio`
   - `config.embed.border_width`, `config.embed.image_retry_delay_ms`
   - `config.blockid.suffix_length`, `config.blockid.max_retries`

---

## Summary of Changes

| File | Lines Changed | Description |
|------|---------------|-------------|
| `lua/andrew/vault/config.lua` | ~12 added | New entries: `preview.{min_width, scroll_lines, edit_width_ratio, edit_height_ratio}`, `embed.{border_width, image_retry_delay_ms}`, `blockid.{suffix_length, max_retries}` |
| `lua/andrew/vault/wikilink_highlights.lua` | ~2 | Replace `local DEBOUNCE_MS = 150` with `config.wikilink_highlights.debounce_ms` reference |
| `lua/andrew/vault/tag_highlights.lua` | ~2 | Replace `local DEBOUNCE_MS = 200` with `config.tag_highlights.debounce_ms` reference |
| `lua/andrew/vault/inline_fields.lua` | ~2 | Replace `local DEBOUNCE_MS = 200` with `config.inline_fields.debounce_ms` reference |
| `lua/andrew/vault/highlights.lua` | ~2 | Replace `local DEBOUNCE_MS = 200` with `config.highlight_marks.debounce_ms` reference |
| `lua/andrew/vault/preview.lua` | ~10 | Replace hardcoded `20`, `3`, `0.8`, `0.6` with config references |
| `lua/andrew/vault/embed.lua` | ~4 | Replace hardcoded `50` (border) and `1200` (retry) with config references |
| `lua/andrew/vault/blockid.lua` | ~3 | Replace hardcoded `6` and `100` with config references; add config require |

No new files. No new dependencies. All changes are backwards-compatible -- the
config defaults match the current hardcoded values exactly.
