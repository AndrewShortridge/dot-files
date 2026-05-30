# Register `<leader>m` Keymaps with Which-Key

## Problem

The `ftplugin/markdown.lua` file defines 40+ markdown-specific keymaps under the
`<leader>m` prefix (formatting, headings, folding, blockquotes, callouts,
checkbox cycling, image pasting, smart paste, spell toggle). These keymaps are
invisible in which-key popups because they lack group registrations. When a user
presses `<leader>m` in a markdown buffer, which-key shows the global "Make/Build"
label (from `which-key.lua` line 46) and lists individual mappings in a flat,
ungrouped list. There is no visual hierarchy -- a user cannot discover that
`<leader>mb` is "Toggle bold" (not "Make Build"), that `<leader>m1` through
`<leader>m6` set heading levels, or that `<leader>mq`/`<leader>mQ`/`<leader>mC`
form a "Blocks" group.

The existing `<leader>T` table keymaps already have proper which-key group
registration (lines 788-794 of `ftplugin/markdown.lua`), and vault `<leader>v`
keymaps have groups registered globally in `which-key.lua` (lines 51-57). The
`<leader>m` keymaps need the same treatment.

### Specific issues

1. **Global `<leader>m` = "Make/Build" conflicts with buffer-local "Markdown".**
   The global group label registered in `which-key.lua` (line 46) says
   "Make/Build" (for fortran-build.lua). In markdown buffers, the ftplugin
   already overrides this to "Markdown" via `buffer = 0` (line 787), but the
   subgroups within `<leader>m` are not registered.

2. **No subgroup labels.** Pressing `<leader>m` shows a flat list of ~20 normal
   mode keymaps with no logical grouping. Users see `b`, `i`, `s`, `c`,
   `1`..`6`, `f`, `u`, `l`, `q`, `Q`, `C`, `x`, `k`, `K`, `p`, `P`, `S` all at
   the same level.

3. **Visual mode keymaps invisible.** The visual mode keymaps (`<leader>mb`,
   `<leader>mi`, `<leader>ms`, `<leader>mc`, `<leader>mq`, `<leader>mQ`,
   `<leader>mC`, `<leader>mk`, `<leader>mK`, `<leader>mP`) are not registered
   with which-key at all.

## Current State

### All `<leader>m*` keymaps in `ftplugin/markdown.lua`

#### Normal mode (`map()`)

| Keymap | Description | Category |
|--------|-------------|----------|
| `<leader>mf` | Fold all (`zM`) | Folding |
| `<leader>mu` | Unfold all (`zR`) | Folding |
| `<leader>ml` | Set fold level (prompt) | Folding |
| `<leader>mx` | Cycle checkbox state | Tasks |
| `<leader>mb` | Toggle bold (`**`) | Formatting |
| `<leader>mi` | Toggle italic (`*`) | Formatting |
| `<leader>ms` | Toggle strikethrough (`~~`) | Formatting |
| `<leader>mc` | Toggle inline code (`` ` ``) | Formatting |
| `<leader>mp` | Paste clipboard image | Media |
| `<leader>m1` | Toggle heading 1 | Headings |
| `<leader>m2` | Toggle heading 2 | Headings |
| `<leader>m3` | Toggle heading 3 | Headings |
| `<leader>m4` | Toggle heading 4 | Headings |
| `<leader>m5` | Toggle heading 5 | Headings |
| `<leader>m6` | Toggle heading 6 | Headings |
| `<leader>mq` | Add blockquote level | Blocks |
| `<leader>mQ` | Remove blockquote level | Blocks |
| `<leader>mC` | Create callout (prompt) | Blocks |
| `<leader>mS` | Toggle spell check | Spell |
| `<leader>mP` | Paste clipboard as link (word) | Links |

#### Visual mode (`vmap()` / `vim.keymap.set("v", ...)` / `vim.keymap.set("x", ...)`)

| Keymap | Description | Category |
|--------|-------------|----------|
| `<leader>mb` | Toggle bold (`**`) | Formatting |
| `<leader>mi` | Toggle italic (`*`) | Formatting |
| `<leader>ms` | Toggle strikethrough (`~~`) | Formatting |
| `<leader>mc` | Toggle inline code (`` ` ``) | Formatting |
| `<leader>mq` | Add blockquote level | Blocks |
| `<leader>mQ` | Remove blockquote level | Blocks |
| `<leader>mC` | Create callout (prompt) | Blocks |
| `<leader>mk` | Create `[text](url)` link | Links |
| `<leader>mK` | Create `[[wikilink]]` | Links |
| `<leader>mP` | Paste clipboard as link | Links |

#### Table keymaps (already registered with which-key)

| Keymap | Description |
|--------|-------------|
| `<leader>Tc` | Create table (interactive) |
| `<leader>Tir` | Insert table row below |
| `<leader>Tdt` | Delete entire table |
| `<leader>Tm` | Toggle table mode (vim-table-mode) |

### Existing which-key registration in `ftplugin/markdown.lua` (lines 784-803)

The file already has a partial which-key registration block:

```lua
local ok, wk = pcall(require, "which-key")
if ok then
  wk.add({
    { "<leader>m", group = "Markdown", buffer = 0 },
    { "<leader>Tc", desc = "Create table (interactive)", buffer = 0 },
    { "<leader>T", group = "Table", buffer = 0 },
    { "<leader>Ti", group = "Insert", buffer = 0 },
    { "<leader>Td", group = "Delete", buffer = 0 },
    { "<leader>Tir", desc = "Insert row below", buffer = 0 },
    { "<leader>Tdt", desc = "Delete entire table", buffer = 0 },
    { "]s", desc = "Next misspelling", buffer = 0 },
    { "[s", desc = "Prev misspelling", buffer = 0 },
    { "z=", desc = "Spell suggestions", buffer = 0 },
    { "zg", desc = "Add word to spellfile", buffer = 0 },
    { "zw", desc = "Mark word as bad", buffer = 0 },
    { "zug", desc = "Undo add to spellfile", buffer = 0 },
  })
end
```

This overrides the global "Make/Build" label with "Markdown" and registers table
and spell keymaps, but has **zero subgroup registrations** for the `<leader>m*`
keymaps themselves.

### How vault `<leader>v*` keymaps are registered

Vault keymaps use **global** group registration in `which-key.lua` (lines 51-57):

```lua
{ "<leader>v", group = "Vault" },
{ "<leader>vt", group = "Templates" },
{ "<leader>vf", group = "Find" },
{ "<leader>vq", group = "Query" },
{ "<leader>ve", group = "Edit" },
{ "<leader>vx", group = "Tasks" },
{ "<leader>vc", group = "Check" },
```

These are global because vault keymaps themselves are global (not buffer-local).
The markdown keymaps are buffer-local (ftplugin), so their which-key groups must
also be buffer-local (`buffer = 0`).

### Conflict: `<leader>m` global vs buffer-local

- **Global (which-key.lua:46):** `{ "<leader>m", group = "Make/Build" }` --
  used by `fortran-build.lua` for `<leader>mb`, `<leader>md`, `<leader>mc`,
  `<leader>mr`, `<leader>ma`, `<leader>ml`.
- **Buffer-local (ftplugin/markdown.lua:787):** `{ "<leader>m", group = "Markdown", buffer = 0 }`
  -- already correctly overrides in markdown buffers.

The fortran-build keymaps (`<leader>mb` = "Make Build", `<leader>mc` = "Make
Clean", `<leader>ml` = "Make Last") collide with markdown keymaps (`<leader>mb`
= "Toggle bold", `<leader>mc` = "Toggle inline code", `<leader>ml` = "Set fold
level"). This is harmless because:

1. Fortran-build keymaps are global but fortran-build.lua only activates for
   fortran files (lazy-loaded via `ft = { "fortran" }`).
2. The markdown ftplugin keymaps use `buffer = true`, so they take precedence in
   markdown buffers.
3. Which-key `buffer = 0` ensures the "Markdown" label overrides "Make/Build" in
   markdown buffers.

No conflict resolution is needed.

## Solution

Expand the existing `wk.add()` call in `ftplugin/markdown.lua` to register
logical subgroups with icons for all `<leader>m*` keymaps. Use `buffer = 0` for
all entries (current-buffer-only, matching the existing pattern).

### Proposed subgroup hierarchy

```
<leader>m          Markdown (already registered)
  Formatting:      <leader>mb, mi, ms, mc  (bold, italic, strike, code)
  Headings:        <leader>m1..m6          (heading levels)
  Folding:         <leader>mf, mu, ml      (fold all, unfold, set level)
  Blocks:          <leader>mq, mQ, mC      (blockquote add/remove, callout)
  Links:           <leader>mk, mK, mP      (md link, wikilink, smart paste)
  Tasks:           <leader>mx              (checkbox cycle)
  Media:           <leader>mp              (paste image)
  Spell:           <leader>mS              (toggle spell)
```

Since which-key v3 does not support "virtual" subgroups for arbitrary keymap
groupings (groups require a shared prefix), and our keymaps share the
`<leader>m` prefix but differ at the second character, we cannot create nested
subgroups like `<leader>mf.` (formatting) without changing the keymap structure.

Instead, we register **individual keymap descriptions with icons** to aid
discoverability, and add section-style `desc` overrides that make the popup
self-documenting. The keymaps already have `desc` set in their `vim.keymap.set`
calls, so which-key already shows those descriptions. The missing piece is
**visual grouping cues** via icons.

### Approach: Icon-prefixed descriptions + proxy group entries

Which-key v3 `add()` supports `icon` per entry. We use category icons so that
keymaps with the same function cluster visually in the popup:

- Formatting keymaps: pencil icon
- Heading keymaps: hash icon
- Folding keymaps: fold icon
- Block keymaps: quote icon
- Link keymaps: link icon

We also register visual-mode groups so `<leader>m` in visual mode shows the
available visual keymaps.

## Implementation

### Changes to `ftplugin/markdown.lua`

Replace the existing `wk.add()` block (lines 784-803) with the expanded version
below.

```lua
-- =============================================================================
-- Which-Key: Register <leader>m subgroups for markdown buffers
-- =============================================================================

local ok, wk = pcall(require, "which-key")
if ok then
  wk.add({
    -- Override global "Make/Build" label in markdown buffers
    { "<leader>m", group = "Markdown", icon = { icon = "", color = "blue" }, buffer = 0 },

    -- ── Formatting ──────────────────────────────────────────────────────
    { "<leader>mb", desc = "Toggle bold",          icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { "<leader>mi", desc = "Toggle italic",        icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { "<leader>ms", desc = "Toggle strikethrough", icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { "<leader>mc", desc = "Toggle inline code",   icon = { icon = "", color = "yellow" }, buffer = 0 },

    -- ── Headings ────────────────────────────────────────────────────────
    { "<leader>m1", desc = "Heading 1", icon = { icon = "󰉫", color = "purple" }, buffer = 0 },
    { "<leader>m2", desc = "Heading 2", icon = { icon = "󰉬", color = "purple" }, buffer = 0 },
    { "<leader>m3", desc = "Heading 3", icon = { icon = "󰉭", color = "purple" }, buffer = 0 },
    { "<leader>m4", desc = "Heading 4", icon = { icon = "󰉮", color = "purple" }, buffer = 0 },
    { "<leader>m5", desc = "Heading 5", icon = { icon = "󰉯", color = "purple" }, buffer = 0 },
    { "<leader>m6", desc = "Heading 6", icon = { icon = "󰉰", color = "purple" }, buffer = 0 },

    -- ── Folding ─────────────────────────────────────────────────────────
    { "<leader>mf", desc = "Fold all",       icon = { icon = "", color = "cyan" }, buffer = 0 },
    { "<leader>mu", desc = "Unfold all",     icon = { icon = "", color = "cyan" }, buffer = 0 },
    { "<leader>ml", desc = "Set fold level", icon = { icon = "", color = "cyan" }, buffer = 0 },

    -- ── Blocks (blockquote / callout) ───────────────────────────────────
    { "<leader>mq", desc = "Add blockquote level",    icon = { icon = "", color = "green" }, buffer = 0 },
    { "<leader>mQ", desc = "Remove blockquote level", icon = { icon = "", color = "green" }, buffer = 0 },
    { "<leader>mC", desc = "Create callout",          icon = { icon = "", color = "green" }, buffer = 0 },

    -- ── Links ───────────────────────────────────────────────────────────
    { "<leader>mP", desc = "Paste clipboard as link", icon = { icon = "", color = "orange" }, buffer = 0 },

    -- ── Tasks ───────────────────────────────────────────────────────────
    { "<leader>mx", desc = "Cycle checkbox", icon = { icon = "", color = "red" }, buffer = 0 },

    -- ── Media ───────────────────────────────────────────────────────────
    { "<leader>mp", desc = "Paste clipboard image", icon = { icon = "", color = "azure" }, buffer = 0 },

    -- ── Spell ───────────────────────────────────────────────────────────
    { "<leader>mS", desc = "Toggle spell check", icon = { icon = "󰓆", color = "grey" }, buffer = 0 },

    -- ── Visual mode: same prefix ────────────────────────────────────────
    { mode = "v", "<leader>m", group = "Markdown", icon = { icon = "", color = "blue" }, buffer = 0 },

    { mode = "v", "<leader>mb", desc = "Toggle bold",          icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { mode = "v", "<leader>mi", desc = "Toggle italic",        icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { mode = "v", "<leader>ms", desc = "Toggle strikethrough", icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
    { mode = "v", "<leader>mc", desc = "Toggle inline code",   icon = { icon = "", color = "yellow" }, buffer = 0 },
    { mode = "v", "<leader>mq", desc = "Add blockquote level",    icon = { icon = "", color = "green" }, buffer = 0 },
    { mode = "v", "<leader>mQ", desc = "Remove blockquote level", icon = { icon = "", color = "green" }, buffer = 0 },
    { mode = "v", "<leader>mC", desc = "Create callout",          icon = { icon = "", color = "green" }, buffer = 0 },
    { mode = "v", "<leader>mk", desc = "Create [text](url) link", icon = { icon = "", color = "orange" }, buffer = 0 },
    { mode = "v", "<leader>mK", desc = "Create [[wikilink]]",     icon = { icon = "", color = "orange" }, buffer = 0 },

    -- Visual "x" mode (select mode) for smart paste
    { mode = "x", "<leader>mP", desc = "Paste clipboard as link", icon = { icon = "", color = "orange" }, buffer = 0 },

    -- ── Table operations (already registered, kept for completeness) ────
    { "<leader>T",   group = "Table", buffer = 0 },
    { "<leader>Tc",  desc = "Create table (interactive)", buffer = 0 },
    { "<leader>Ti",  group = "Insert", buffer = 0 },
    { "<leader>Td",  group = "Delete", buffer = 0 },
    { "<leader>Tir", desc = "Insert row below",   buffer = 0 },
    { "<leader>Tdt", desc = "Delete entire table", buffer = 0 },

    -- ── Spell motions (built-in, listed for discoverability) ────────────
    { "]s",  desc = "Next misspelling",     buffer = 0 },
    { "[s",  desc = "Prev misspelling",     buffer = 0 },
    { "z=",  desc = "Spell suggestions",    buffer = 0 },
    { "zg",  desc = "Add word to spellfile", buffer = 0 },
    { "zw",  desc = "Mark word as bad",     buffer = 0 },
    { "zug", desc = "Undo add to spellfile", buffer = 0 },

    -- ── Heading navigation (bracket motions) ────────────────────────────
    { "]h", desc = "Next heading",     buffer = 0 },
    { "[h", desc = "Previous heading", buffer = 0 },
  })
end
```

### No changes to other files

- **`lua/andrew/plugins/which-key.lua`** -- No changes needed. The global
  `<leader>m` = "Make/Build" remains correct for non-markdown buffers. The
  buffer-local override in `ftplugin/markdown.lua` already takes precedence.

- **`lua/andrew/vault/init.lua`** -- No changes needed. Vault keymaps use a
  different prefix (`<leader>v`) and are already registered globally.

## Implementation Steps

### Step 1: Replace the `wk.add()` block in `ftplugin/markdown.lua`

**File:** `/home/andrew-cmmg/.config/nvim/ftplugin/markdown.lua`

**Location:** Lines 780-803 (the existing which-key section at the end of file)

**Action:** Replace the existing `wk.add()` call with the expanded version shown
above. The replacement:

1. Keeps the `{ "<leader>m", group = "Markdown", buffer = 0 }` override (already
   present on line 787).
2. Adds `icon` entries for every `<leader>m*` normal-mode keymap, categorized by
   color so related keymaps cluster visually.
3. Adds visual-mode (`mode = "v"`) entries for every visual `<leader>m*` keymap.
4. Adds `mode = "x"` for the select-mode smart paste keymap.
5. Adds `]h` / `[h` heading navigation descriptions.
6. Retains all existing table and spell registrations unchanged.

### Step 2: Verify no duplicate `desc` values

The `desc` strings in `wk.add()` entries will override the `desc` strings
already set in `vim.keymap.set()` calls. Ensure they match. In the implementation
above, all `desc` values are identical to those in the keymap definitions, so
there is no discrepancy.

If you want to keep a single source of truth for descriptions, you can omit
`desc` from the `wk.add()` entries and only provide `icon`. Which-key will fall
back to the `desc` from `vim.keymap.set()`:

```lua
-- Alternative: icon-only registration (desc comes from vim.keymap.set)
{ "<leader>mb", icon = { icon = "󰉿", color = "yellow" }, buffer = 0 },
```

This is a matter of preference. Including `desc` explicitly in `wk.add()` makes
the which-key block self-documenting and serves as a keymap reference, but it
means descriptions must be updated in two places if they change.

### Step 3: Handle the `mode = "v"` vs `mode = "x"` distinction

The ftplugin uses two different visual mode setups:

- **`vmap()` helper (line 165):** Uses `vim.keymap.set("v", ...)` -- both visual
  and select modes. Which-key entries should use `mode = "v"`.
- **Smart paste `<leader>mP` (line 734):** Uses `vim.keymap.set("x", ...)` --
  visual mode only (not select). Which-key entry should use `mode = "x"`.

The implementation above uses the correct mode for each.

## Files to Modify

| File | Change |
|------|--------|
| `ftplugin/markdown.lua` | Replace `wk.add()` block (lines 780-803) with expanded version including all `<leader>m*` subgroup registrations, icons, and visual-mode entries |

No other files require modification.

## Testing

### 1. Verify normal mode popup

1. Open any markdown file in the vault.
2. Press `<leader>m` and wait for the which-key popup.
3. Confirm:
   - Top-level label shows "Markdown" (not "Make/Build").
   - Each keymap shows its icon and description.
   - Icons group related keymaps visually (all formatting keymaps share the
     pencil icon, all heading keymaps share the hash icon, etc.).
   - All 20 normal-mode keymaps are listed.

### 2. Verify visual mode popup

1. Open a markdown file and visually select some text (`v` + motion).
2. Press `<leader>m` and wait for the which-key popup.
3. Confirm:
   - Top-level label shows "Markdown".
   - The 10 visual-mode keymaps are listed (bold, italic, strikethrough, code,
     blockquote add/remove, callout, md link, wikilink, smart paste).

### 3. Verify non-markdown buffers are unaffected

1. Open a Lua or Fortran file.
2. Press `<leader>m`.
3. Confirm the popup shows "Make/Build" (not "Markdown") and lists the
   fortran-build keymaps (if applicable) or generic keymaps.

### 4. Verify no startup errors

1. Restart Neovim with `nvim --startuptime /tmp/startup.log`.
2. Open a markdown file.
3. Check `:messages` for any which-key errors.
4. Check that the `pcall(require, "which-key")` guard still works if which-key
   is not installed.

### 5. Spot-check icon rendering

1. Ensure the terminal supports Nerd Font icons (Kitty + a Nerd Font).
2. Verify that icons like `󰉿`, ``, ``, ``, ``, ``, `󰓆`
   render correctly in the which-key popup.
3. If icons don't render, the `icon` entries can be removed without affecting
   functionality -- which-key will just show plain text descriptions.

## Notes

- **Which-key v3 API:** This implementation uses the `wk.add()` API (not the
  deprecated `wk.register()`). The `add()` function accepts a list of keymap
  specs as its argument. Each spec is a table with positional key `[1]` for the
  keymap string, plus named fields `group`, `desc`, `icon`, `buffer`, `mode`.

- **`buffer = 0`:** Means "current buffer only." Since this runs in
  `ftplugin/markdown.lua`, it executes each time a markdown buffer is opened,
  registering the which-key entries for that specific buffer. This is the correct
  pattern for filetype-specific keymaps.

- **Icon colors:** Which-key v3 supports a fixed set of highlight-group-based
  colors: `azure`, `blue`, `cyan`, `green`, `grey`, `orange`, `purple`, `red`,
  `yellow`. The color choice above is arbitrary and can be adjusted to taste.

- **Future improvement:** If the keymap set grows further, consider refactoring
  to a dedicated `lua/andrew/utils/md-which-key.lua` module that both defines
  keymaps and registers them with which-key in a single table, eliminating the
  dual-maintenance issue.
