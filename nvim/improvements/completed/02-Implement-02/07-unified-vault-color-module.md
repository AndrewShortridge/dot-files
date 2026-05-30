# Unified Vault Color Module

## Problem

Four vault highlight modules independently hardcode OneDark-derived hex color
values as fallback defaults. This creates three issues:

1. **Color duplication.** The same hex values (e.g., `#61afef` for blue,
   `#5c6370` for dim gray) appear in 4 separate files. Changing a color requires
   hunting across all of them.

2. **Theme switch does not update extmark colors properly.** Each module defines
   its highlight groups with `default = true`, which means a colorscheme that
   explicitly sets those groups (like `soft-paper.lua`) will override them. But
   when switching _back_ to OneDark, the `ColorScheme` autocmd in each module
   calls `define_highlights()` which re-applies the hardcoded OneDark values --
   always OneDark, regardless of the active colorscheme. There is no detection
   of which colorscheme is active, so switching to a third-party theme would
   still get OneDark vault colors.

3. **Hard to maintain consistent vault palette.** Adding a new vault highlight
   group requires deciding colors in isolation, with no centralized palette to
   reference. The semantic meaning of colors is implicit (why is `#56b6c2` used
   for both `VaultTagPerson` and `VaultFieldValueBool`?).

## Current State

### Module 1: `wikilink_highlights.lua`

**File:** `lua/andrew/vault/wikilink_highlights.lua`

Hardcoded `hl_groups` table (lines 18-26):

| Highlight Group | Hex Color(s) | Style | Semantic Meaning |
|-----------------|--------------|-------|------------------|
| `VaultWikiLinkValid` | fg `#61afef` | underline | Resolved wikilink |
| `VaultWikiLinkBroken` | fg `#e06c75`, sp `#e06c75` | undercurl | Unresolved wikilink |
| `VaultWikiLinkHeading` | fg `#98c379` | italic | Valid heading anchor |
| `VaultWikiLinkHeadingBroken` | fg `#d19a66`, sp `#d19a66` | undercurl | Invalid heading anchor |
| `VaultWikiLinkSelf` | fg `#c678dd` | italic | Self-reference `[[#Heading]]` |
| `VaultWikiLinkAlias` | fg `#61afef` | bold | Display alias after `\|` |
| `VaultWikiLinkBracket` | fg `#5c6370` | -- | Dim `[[` and `]]` brackets |

**ColorScheme autocmd:** Yes (line 285-288). Calls `define_highlights()` which
re-applies the hardcoded OneDark values unconditionally.

### Module 2: `tag_highlights.lua`

**File:** `lua/andrew/vault/tag_highlights.lua`

Hardcoded `hl_groups` table (lines 131-138):

| Highlight Group | Hex Color(s) | Style | Semantic Meaning |
|-----------------|--------------|-------|------------------|
| `VaultTag` | fg `#c678dd` | bold | Default tag color |
| `VaultTagProject` | fg `#61afef` | bold | `project/` prefixed tags |
| `VaultTagStatus` | fg `#98c379` | bold | `status/` prefixed tags |
| `VaultTagType` | fg `#e5c07b` | bold | `type/` prefixed tags |
| `VaultTagPerson` | fg `#56b6c2` | bold | `person/` prefixed tags |
| `VaultTagHash` | fg `#5c6370` | -- | Dim `#` character |

**ColorScheme autocmd:** Yes (lines 417-420). Same pattern -- unconditionally
re-applies OneDark values.

### Module 3: `highlights.lua` (highlight marks)

**File:** `lua/andrew/vault/highlights.lua`

Hardcoded `hl_groups` table (lines 16-19):

| Highlight Group | Hex Color(s) | Style | Semantic Meaning |
|-----------------|--------------|-------|------------------|
| `VaultHighlight` | bg `#4a3a10`, fg `#e5c07b` | -- | `==highlighted==` text |
| `VaultHighlightDelim` | fg `#5c6370` | -- | Dim `==` delimiters |

**ColorScheme autocmd:** Yes (lines 308-311). Same unconditional pattern.

### Module 4: `inline_fields.lua`

**File:** `lua/andrew/vault/inline_fields.lua`

Hardcoded `hl_groups` table (lines 16-25):

| Highlight Group | Hex Color(s) | Style | Semantic Meaning |
|-----------------|--------------|-------|------------------|
| `VaultFieldBracket` | fg `#5c6370` | -- | Dim `[` and `]` brackets |
| `VaultFieldKey` | fg `#e06c75` | bold | Field key name |
| `VaultFieldSep` | fg `#5c6370` | -- | Dim `::` separator |
| `VaultFieldValue` | fg `#98c379` | -- | Text/empty value |
| `VaultFieldValueDate` | fg `#e5c07b` | -- | Date value |
| `VaultFieldValueNumber` | fg `#d19a66` | -- | Numeric value |
| `VaultFieldValueLink` | fg `#61afef` | underline | Wikilink value |
| `VaultFieldValueBool` | fg `#56b6c2` | italic | Boolean value |

**ColorScheme autocmd:** Yes (lines 769-772). Same unconditional pattern.

### Additional modules with hardcoded colors (out of scope but noted)

These modules also hardcode colors and would benefit from the color module in a
future pass:

- **`embed.lua`** (lines 601-604): `VaultEmbedContent` (`#8888aa`),
  `VaultEmbedBorder` (`#555577`), `VaultEmbedCycle` (`#e06060`),
  `VaultEmbedDepth` (`#c0a040`). Not defined in soft-paper.lua at all.
- **`calendar.lua`** (lines 13-29): 8 `VaultCalendar*` groups using Catppuccin
  Mocha colors. Not defined in soft-paper.lua.
- **`graph.lua`** (lines 23-25): `VaultGraphExistingLink` (`#3b82f6`),
  `VaultGraphUnresolvedLink` (`#ef4444`). Not defined in soft-paper.lua.

### How `soft-paper.lua` defines vault highlights

**File:** `lua/andrew/themes/soft-paper.lua`

The `build_highlights()` function (starting line 130) returns a table that
includes vault-specific groups (lines 574-601). These use the soft-paper palette
`c.*` variables rather than raw hex. Both light and dark variants are covered
via the single palette-parameterized function.

Soft-paper defines these vault groups:

**Wikilinks:**
- `VaultWikiLinkValid` = `{ fg = c.accent }` (no underline -- intentional difference from OneDark)
- `VaultWikiLinkBroken` = `{ fg = c.red, undercurl = true, sp = c.red }`
- `VaultWikiLinkHeading` = `{ fg = c.green, italic = true }`
- `VaultWikiLinkHeadingBroken` = `{ fg = c.peach, undercurl = true, sp = c.peach }`
- `VaultWikiLinkSelf` = `{ fg = c.lavender, italic = true }`
- `VaultWikiLinkAlias` = `{ fg = c.accent, bold = true }`
- `VaultWikiLinkBracket` = `{ fg = c.surface2 }`

**Tags:**
- `VaultTag` = `{ fg = c.lavender, bold = true }`
- `VaultTagProject` = `{ fg = c.accent, bold = true }`
- `VaultTagStatus` = `{ fg = c.green, bold = true }`
- `VaultTagType` = `{ fg = c.yellow, bold = true }`
- `VaultTagPerson` = `{ fg = c.teal, bold = true }`
- `VaultTagHash` = `{ fg = c.surface2 }`

**Inline fields:**
- `VaultFieldBracket` = `{ fg = c.surface2 }`
- `VaultFieldKey` = `{ fg = c.red, bold = true }`
- `VaultFieldSep` = `{ fg = c.surface2 }`
- `VaultFieldValue` = `{ fg = c.green }`
- `VaultFieldValueDate` = `{ fg = c.teal }`
- `VaultFieldValueNumber` = `{ fg = c.peach }`
- `VaultFieldValueLink` = `{ fg = c.accent, underline = true }`
- `VaultFieldValueBool` = `{ fg = c.sky, italic = true }`

**Highlight marks:**
- `VaultHighlight` = `{ bg = c.search_active_bg, fg = c.fg }`
- `VaultHighlightDelim` = `{ fg = c.surface2 }`
- `RenderMarkdownInlineHighlight` = `{ bg = c.search_active_bg, fg = c.fg }`

**Key observation:** soft-paper.lua sets these groups WITHOUT `default = true`
(they are applied forcefully via `nvim_set_hl(0, group, attrs)` in
`M.load()`). When the vault modules then fire their `ColorScheme` autocmd and
call `define_highlights()` with `default = true`, the vault modules' defaults
do NOT override the soft-paper values. This is why the current system
_partially_ works -- but only in the soft-paper-first direction. The reverse
(switching from soft-paper back to OneDark) is where the problem lies, because
the vault modules' `define_highlights()` always applies OneDark colors with
`default = true`, and `hi clear` from the colorscheme switch removes the
soft-paper overrides.

### How `colorscheme.lua` interacts

**File:** `lua/andrew/plugins/colorscheme.lua`

OneDarkPro setup (lines 35-53) defines custom `highlights` that include
`RenderMarkdownInlineHighlight` (bg `#4a3a10`, fg `#e5c07b`) matching the
vault highlight marks module. However, it does NOT define any `Vault*` groups.
The vault modules handle their own highlight definitions.

### Shared hex values across modules (duplication evidence)

| Hex Value | OneDark Name | Used In |
|-----------|-------------|---------|
| `#61afef` | Blue | wikilink_highlights (Valid, Alias), tag_highlights (Project), inline_fields (ValueLink) |
| `#e06c75` | Red | wikilink_highlights (Broken), inline_fields (Key) |
| `#98c379` | Green | wikilink_highlights (Heading), tag_highlights (Status), inline_fields (Value) |
| `#e5c07b` | Yellow | tag_highlights (Type), highlights (Highlight fg), inline_fields (ValueDate) |
| `#d19a66` | Orange | wikilink_highlights (HeadingBroken), inline_fields (ValueNumber) |
| `#c678dd` | Purple | wikilink_highlights (Self), tag_highlights (Tag) |
| `#56b6c2` | Cyan | tag_highlights (Person), inline_fields (ValueBool) |
| `#5c6370` | Gray | wikilink_highlights (Bracket), tag_highlights (Hash), highlights (Delim), inline_fields (Bracket, Sep) |
| `#4a3a10` | Dark Yellow bg | highlights (Highlight bg) |

Total: 9 unique hex values, referenced 20 times across 4 modules.

## Solution

Create `lua/andrew/vault/colors.lua` as the single source of truth for all
vault highlight colors. This module:

1. Detects the active colorscheme.
2. Exports a palette of semantic color names mapped to the appropriate hex
   values for that colorscheme.
3. Defines all `Vault*` highlight groups in one place.
4. Re-exports on `ColorScheme` events with the correct palette for the new
   scheme.
5. All 4 highlight modules (plus future ones) import from `colors.lua` instead
   of hardcoding hex values.

### Design principles

- **No circular dependencies.** `colors.lua` requires nothing from the vault
  module tree. It only uses `vim.api` and `vim.g`.
- **Semantic names.** Colors are named by purpose (`link_valid`, `tag_project`)
  not by raw color (`blue`, `green`).
- **Style separation.** The color module exports colors (hex strings). The
  highlight definition includes both color and style (bold, italic, underline).
  Styles are kept with the highlight definition, not the palette, because
  styles are consistent across themes.
- **Backward compatible.** Soft-paper.lua can continue to define its own
  `Vault*` groups directly. The color module uses `default = true`, so
  colorschemes that set these groups explicitly still take precedence.
- **Extensible.** Adding a new vault highlight group means adding one entry to
  the palette tables and one entry to the highlight definitions -- all in one
  file.

## Implementation Steps

### Step 1: Define the color module API

Create `lua/andrew/vault/colors.lua` with this structure:

```lua
--- Centralized color palette and highlight definitions for all vault modules.
--- Single source of truth. No requires from the vault module tree.
local M = {}

--- The currently active palette (set by detect_scheme + define_highlights).
---@type table<string, string>
M.palette = {}

-- ---------------------------------------------------------------------------
-- Palette definitions per colorscheme family
-- ---------------------------------------------------------------------------

--- OneDark palette (default).
--- Source: hardcoded values extracted from wikilink_highlights, tag_highlights,
---         highlights, and inline_fields modules.
local onedark = {
  -- Base colors (OneDark Pro palette)
  blue       = "#61afef",
  red        = "#e06c75",
  green      = "#98c379",
  yellow     = "#e5c07b",
  orange     = "#d19a66",
  purple     = "#c678dd",
  cyan       = "#56b6c2",
  gray       = "#5c6370",
  dark_yellow_bg = "#4a3a10",

  -- Semantic aliases (derived from base)
  link_valid           = "#61afef",
  link_broken          = "#e06c75",
  link_heading         = "#98c379",
  link_heading_broken  = "#d19a66",
  link_self            = "#c678dd",
  link_alias           = "#61afef",
  link_bracket         = "#5c6370",

  tag_default          = "#c678dd",
  tag_project          = "#61afef",
  tag_status           = "#98c379",
  tag_type             = "#e5c07b",
  tag_person           = "#56b6c2",
  tag_hash             = "#5c6370",

  field_bracket        = "#5c6370",
  field_key            = "#e06c75",
  field_sep            = "#5c6370",
  field_value          = "#98c379",
  field_value_date     = "#e5c07b",
  field_value_number   = "#d19a66",
  field_value_link     = "#61afef",
  field_value_bool     = "#56b6c2",

  highlight_bg         = "#4a3a10",
  highlight_fg         = "#e5c07b",
  highlight_delim      = "#5c6370",
}

--- Soft Paper Light palette.
--- Source: lua/andrew/themes/soft-paper.lua, M.palettes.light
local soft_paper_light = {
  link_valid           = "#1A7DA4",  -- c.accent
  link_broken          = "#BA7184",  -- c.red
  link_heading         = "#5BA57B",  -- c.green
  link_heading_broken  = "#DD7F67",  -- c.peach
  link_self            = "#9A85AE",  -- c.lavender
  link_alias           = "#1A7DA4",  -- c.accent
  link_bracket         = "#CAC1B9",  -- c.surface2

  tag_default          = "#9A85AE",  -- c.lavender
  tag_project          = "#1A7DA4",  -- c.accent
  tag_status           = "#5BA57B",  -- c.green
  tag_type             = "#D19548",  -- c.yellow
  tag_person           = "#669EA6",  -- c.teal
  tag_hash             = "#CAC1B9",  -- c.surface2

  field_bracket        = "#CAC1B9",  -- c.surface2
  field_key            = "#BA7184",  -- c.red
  field_sep            = "#CAC1B9",  -- c.surface2
  field_value          = "#5BA57B",  -- c.green
  field_value_date     = "#669EA6",  -- c.teal
  field_value_number   = "#DD7F67",  -- c.peach
  field_value_link     = "#1A7DA4",  -- c.accent
  field_value_bool     = "#286983",  -- c.sky

  highlight_bg         = "#E2C6A1",  -- c.search_active_bg
  highlight_fg         = "#575279",  -- c.fg
  highlight_delim      = "#CAC1B9",  -- c.surface2
}

--- Soft Paper Dark palette.
--- Source: lua/andrew/themes/soft-paper.lua, M.palettes.dark
local soft_paper_dark = {
  link_valid           = "#11B7C5",  -- c.accent
  link_broken          = "#E78284",  -- c.red
  link_heading         = "#67C48F",  -- c.green
  link_heading_broken  = "#EF9F76",  -- c.peach
  link_self            = "#BB93D6",  -- c.lavender
  link_alias           = "#11B7C5",  -- c.accent
  link_bracket         = "#62677E",  -- c.surface2

  tag_default          = "#BB93D6",  -- c.lavender
  tag_project          = "#11B7C5",  -- c.accent
  tag_status           = "#67C48F",  -- c.green
  tag_type             = "#C9BE3E",  -- c.yellow
  tag_person           = "#11B7C5",  -- c.teal
  tag_hash             = "#62677E",  -- c.surface2

  field_bracket        = "#62677E",  -- c.surface2
  field_key            = "#E78284",  -- c.red
  field_sep            = "#62677E",  -- c.surface2
  field_value          = "#67C48F",  -- c.green
  field_value_date     = "#11B7C5",  -- c.teal
  field_value_number   = "#EF9F76",  -- c.peach
  field_value_link     = "#11B7C5",  -- c.accent
  field_value_bool     = "#99D1DB",  -- c.sky

  highlight_bg         = "#6D6B43",  -- c.search_active_bg
  highlight_fg         = "#C6CEEF",  -- c.fg
  highlight_delim      = "#62677E",  -- c.surface2
}

--- Registry: colorscheme name pattern -> palette.
--- Checked in order; first match wins. Falls back to onedark.
local scheme_palettes = {
  { pattern = "^soft%-paper%-light$", palette = soft_paper_light },
  { pattern = "^soft%-paper%-dark$",  palette = soft_paper_dark },
  { pattern = "^soft%-paper",         palette = soft_paper_light },
  -- Default: OneDark covers onedark, onedark_vivid, onedark_dark, etc.
  { pattern = ".",                    palette = onedark },
}
```

### Step 2: Colorscheme detection and palette selection

```lua
--- Detect the active colorscheme and return the appropriate palette.
---@return table<string, string>
function M.detect_palette()
  local name = vim.g.colors_name or ""
  for _, entry in ipairs(scheme_palettes) do
    if name:match(entry.pattern) then
      return entry.palette
    end
  end
  return onedark
end
```

### Step 3: Centralized highlight group definitions

Move all `Vault*` highlight group definitions into `colors.lua`. The highlight
groups encode both the palette color AND the style attributes:

```lua
--- Build highlight group definitions from a palette.
--- Returns a table: group_name -> { fg, bg, sp, bold, italic, underline, undercurl }
---@param p table<string, string> palette
---@return table<string, table>
local function build_hl_groups(p)
  return {
    -- Wikilinks
    VaultWikiLinkValid         = { fg = p.link_valid, underline = true },
    VaultWikiLinkBroken        = { fg = p.link_broken, undercurl = true, sp = p.link_broken },
    VaultWikiLinkHeading       = { fg = p.link_heading, italic = true },
    VaultWikiLinkHeadingBroken = { fg = p.link_heading_broken, undercurl = true, sp = p.link_heading_broken },
    VaultWikiLinkSelf          = { fg = p.link_self, italic = true },
    VaultWikiLinkAlias         = { fg = p.link_alias, bold = true },
    VaultWikiLinkBracket       = { fg = p.link_bracket },

    -- Tags
    VaultTag                   = { fg = p.tag_default, bold = true },
    VaultTagProject            = { fg = p.tag_project, bold = true },
    VaultTagStatus             = { fg = p.tag_status, bold = true },
    VaultTagType               = { fg = p.tag_type, bold = true },
    VaultTagPerson             = { fg = p.tag_person, bold = true },
    VaultTagHash               = { fg = p.tag_hash },

    -- Inline fields
    VaultFieldBracket          = { fg = p.field_bracket },
    VaultFieldKey              = { fg = p.field_key, bold = true },
    VaultFieldSep              = { fg = p.field_sep },
    VaultFieldValue            = { fg = p.field_value },
    VaultFieldValueDate        = { fg = p.field_value_date },
    VaultFieldValueNumber      = { fg = p.field_value_number },
    VaultFieldValueLink        = { fg = p.field_value_link, underline = true },
    VaultFieldValueBool        = { fg = p.field_value_bool, italic = true },

    -- Highlight marks (==text==)
    VaultHighlight             = { bg = p.highlight_bg, fg = p.highlight_fg },
    VaultHighlightDelim        = { fg = p.highlight_delim },
  }
end
```

### Step 4: Define highlight groups and expose palette

```lua
--- (Re-)define all Vault highlight groups based on the active colorscheme.
--- Called at setup time and on every ColorScheme event.
function M.define_highlights()
  local p = M.detect_palette()
  M.palette = p

  local groups = build_hl_groups(p)
  for group, attrs in pairs(groups) do
    attrs.default = true
    vim.api.nvim_set_hl(0, group, attrs)
  end
end

--- Setup: define highlights now and register ColorScheme autocmd.
--- Call this once from the vault initialization path (e.g., engine.lua setup).
function M.setup()
  M.define_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("VaultColors", { clear = true }),
    callback = function()
      M.define_highlights()
    end,
    desc = "Vault: re-apply highlight groups for new colorscheme",
  })
end

--- Get a specific palette color by semantic name.
--- Useful for modules that need raw hex values (e.g., for virtual text).
---@param name string semantic color name (e.g., "link_valid")
---@return string hex color value
function M.get(name)
  if not M.palette or not M.palette[name] then
    -- Ensure palette is loaded
    M.palette = M.detect_palette()
  end
  return M.palette[name]
end

return M
```

### Step 5: Refactor `wikilink_highlights.lua`

Remove the local `hl_groups` table and `define_highlights()` function. Remove
the `ColorScheme` autocmd (now handled centrally).

**Before (lines 18-34):**
```lua
local hl_groups = {
  VaultWikiLinkValid = { fg = "#61afef", underline = true },
  VaultWikiLinkBroken = { fg = "#e06c75", undercurl = true, sp = "#e06c75" },
  -- ... 5 more entries
}

local function define_highlights()
  for group, attrs in pairs(hl_groups) do
    attrs.default = true
    vim.api.nvim_set_hl(0, group, attrs)
  end
end
```

**After:**
```lua
-- (no hl_groups table)
-- (no define_highlights function)
```

**In `setup()` -- before (lines 252-288):**
```lua
function M.setup()
  define_highlights()
  local group = vim.api.nvim_create_augroup("VaultWikilinkHL", { clear = true })
  -- ...
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_highlights,
  })
  -- ...
end
```

**After:**
```lua
function M.setup()
  -- Highlight groups now defined by vault/colors.lua (no local define_highlights)
  local group = vim.api.nvim_create_augroup("VaultWikilinkHL", { clear = true })
  -- ...
  -- REMOVE the ColorScheme autocmd (handled by colors.lua)
  -- ...
end
```

### Step 6: Refactor `tag_highlights.lua`

Same pattern: remove local `hl_groups`, `define_highlights()`, and the
`ColorScheme` autocmd.

**Remove (lines 131-145):**
```lua
local hl_groups = {
  VaultTag = { fg = "#c678dd", bold = true },
  -- ... 5 more entries
}

local function define_highlights()
  for group, attrs in pairs(hl_groups) do
    attrs.default = true
    vim.api.nvim_set_hl(0, group, attrs)
  end
end
```

**Remove from `setup()` (lines 417-420):**
```lua
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = define_highlights,
})
```

**Remove (line 386):**
```lua
define_highlights()
```

### Step 7: Refactor `highlights.lua`

Same pattern.

**Remove (lines 16-26):**
```lua
local hl_groups = {
  VaultHighlight = { bg = "#4a3a10", fg = "#e5c07b" },
  VaultHighlightDelim = { fg = "#5c6370" },
}

local function define_highlights()
  for group, attrs in pairs(hl_groups) do
    attrs.default = true
    vim.api.nvim_set_hl(0, group, attrs)
  end
end
```

**Remove from `setup()` (lines 308-311):**
```lua
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = define_highlights,
})
```

**Remove (line 280):**
```lua
define_highlights()
```

### Step 8: Refactor `inline_fields.lua`

Same pattern.

**Remove (lines 16-32):**
```lua
local hl_groups = {
  VaultFieldBracket = { fg = "#5c6370" },
  -- ... 7 more entries
}

local function define_highlights()
  for group, attrs in pairs(hl_groups) do
    attrs.default = true
    vim.api.nvim_set_hl(0, group, attrs)
  end
end
```

**Remove from `setup()` (lines 769-772):**
```lua
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = define_highlights,
})
```

**Remove (line 738):**
```lua
define_highlights()
```

### Step 9: Initialize colors.lua from the vault setup path

In `engine.lua` (or wherever the vault modules are initialized), add an early
call to `require("andrew.vault.colors").setup()` BEFORE the individual
highlight modules are set up. This ensures the `Vault*` groups exist before any
extmarks reference them.

```lua
-- In engine.lua setup() or equivalent initialization:
require("andrew.vault.colors").setup()
-- Then the existing module setups:
require("andrew.vault.wikilink_highlights").setup()
require("andrew.vault.tag_highlights").setup()
require("andrew.vault.highlights").setup()
require("andrew.vault.inline_fields").setup()
```

### Step 10: Ensure soft-paper.lua still works

Soft-paper.lua defines `Vault*` groups WITHOUT `default = true` in its
`M.load()` function. The colors module defines groups WITH `default = true`.

When soft-paper loads:
1. `hi clear` removes all existing groups.
2. soft-paper's `M.load()` sets `Vault*` groups forcefully (no `default`).
3. The `ColorScheme` event fires.
4. `colors.lua` detects `vim.g.colors_name == "soft-paper-light"` (or dark).
5. `colors.lua` calls `nvim_set_hl()` with `default = true` and the
   soft-paper palette colors.
6. Because `default = true` does not override existing explicit definitions,
   the soft-paper values from step 2 remain intact.

**Result:** Soft-paper vault colors work exactly as before.

When switching from soft-paper back to OneDark:
1. OneDarkPro's setup calls `hi clear`, removing all soft-paper groups.
2. OneDarkPro applies its own groups (does NOT define any `Vault*` groups).
3. The `ColorScheme` event fires.
4. `colors.lua` detects `vim.g.colors_name` matches `onedark*`.
5. `colors.lua` applies OneDark-derived vault colors with `default = true`.
6. Since `hi clear` removed the soft-paper definitions, `default = true`
   succeeds and the OneDark vault colors are applied.

**Result:** Theme switching works correctly in both directions.

### Optional Step 11: Add palette override via `config.lua`

Allow users to override individual palette entries via `config.lua`:

```lua
-- In config.lua:
M.colors = {
  -- Override specific semantic colors (takes precedence over detected scheme)
  overrides = {
    -- link_valid = "#ff0000",  -- example: make valid links red
  },
}
```

```lua
-- In colors.lua, in detect_palette():
function M.detect_palette()
  local name = vim.g.colors_name or ""
  local base = onedark
  for _, entry in ipairs(scheme_palettes) do
    if name:match(entry.pattern) then
      base = entry.palette
      break
    end
  end

  -- Apply config overrides
  local ok, config = pcall(require, "andrew.vault.config")
  if ok and config.colors and config.colors.overrides then
    -- Shallow copy base palette, then merge overrides
    local merged = vim.tbl_extend("keep", config.colors.overrides, base)
    return merged
  end

  return base
end
```

## Color Mapping Table

Complete mapping of semantic names to hex values across all three palettes:

### Wikilink Colors

| Semantic Name | OneDark | Soft Paper Light | Soft Paper Dark |
|---------------|---------|------------------|-----------------|
| `link_valid` | `#61afef` | `#1A7DA4` | `#11B7C5` |
| `link_broken` | `#e06c75` | `#BA7184` | `#E78284` |
| `link_heading` | `#98c379` | `#5BA57B` | `#67C48F` |
| `link_heading_broken` | `#d19a66` | `#DD7F67` | `#EF9F76` |
| `link_self` | `#c678dd` | `#9A85AE` | `#BB93D6` |
| `link_alias` | `#61afef` | `#1A7DA4` | `#11B7C5` |
| `link_bracket` | `#5c6370` | `#CAC1B9` | `#62677E` |

### Tag Colors

| Semantic Name | OneDark | Soft Paper Light | Soft Paper Dark |
|---------------|---------|------------------|-----------------|
| `tag_default` | `#c678dd` | `#9A85AE` | `#BB93D6` |
| `tag_project` | `#61afef` | `#1A7DA4` | `#11B7C5` |
| `tag_status` | `#98c379` | `#5BA57B` | `#67C48F` |
| `tag_type` | `#e5c07b` | `#D19548` | `#C9BE3E` |
| `tag_person` | `#56b6c2` | `#669EA6` | `#11B7C5` |
| `tag_hash` | `#5c6370` | `#CAC1B9` | `#62677E` |

### Inline Field Colors

| Semantic Name | OneDark | Soft Paper Light | Soft Paper Dark |
|---------------|---------|------------------|-----------------|
| `field_bracket` | `#5c6370` | `#CAC1B9` | `#62677E` |
| `field_key` | `#e06c75` | `#BA7184` | `#E78284` |
| `field_sep` | `#5c6370` | `#CAC1B9` | `#62677E` |
| `field_value` | `#98c379` | `#5BA57B` | `#67C48F` |
| `field_value_date` | `#e5c07b` | `#669EA6` | `#11B7C5` |
| `field_value_number` | `#d19a66` | `#DD7F67` | `#EF9F76` |
| `field_value_link` | `#61afef` | `#1A7DA4` | `#11B7C5` |
| `field_value_bool` | `#56b6c2` | `#286983` | `#99D1DB` |

### Highlight Mark Colors

| Semantic Name | OneDark | Soft Paper Light | Soft Paper Dark |
|---------------|---------|------------------|-----------------|
| `highlight_bg` | `#4a3a10` | `#E2C6A1` | `#6D6B43` |
| `highlight_fg` | `#e5c07b` | `#575279` | `#C6CEEF` |
| `highlight_delim` | `#5c6370` | `#CAC1B9` | `#62677E` |

### Style Attributes (consistent across all themes)

| Highlight Group | Attributes |
|-----------------|------------|
| `VaultWikiLinkValid` | underline |
| `VaultWikiLinkBroken` | undercurl, sp = fg |
| `VaultWikiLinkHeading` | italic |
| `VaultWikiLinkHeadingBroken` | undercurl, sp = fg |
| `VaultWikiLinkSelf` | italic |
| `VaultWikiLinkAlias` | bold |
| `VaultWikiLinkBracket` | -- |
| `VaultTag` | bold |
| `VaultTagProject` | bold |
| `VaultTagStatus` | bold |
| `VaultTagType` | bold |
| `VaultTagPerson` | bold |
| `VaultTagHash` | -- |
| `VaultFieldBracket` | -- |
| `VaultFieldKey` | bold |
| `VaultFieldSep` | -- |
| `VaultFieldValue` | -- |
| `VaultFieldValueDate` | -- |
| `VaultFieldValueNumber` | -- |
| `VaultFieldValueLink` | underline |
| `VaultFieldValueBool` | italic |
| `VaultHighlight` | -- |
| `VaultHighlightDelim` | -- |

**Note on soft-paper discrepancy:** Soft-paper's `VaultWikiLinkValid` does NOT
have `underline = true`, while the OneDark version does. The unified module
should preserve this difference by allowing style overrides per-scheme, or by
accepting the unified style (underline) for all schemes. **Recommendation:**
Use the unified style attributes table above, which includes `underline` for
`VaultWikiLinkValid`. If soft-paper specifically wants to suppress underline, it
can still override the group directly in its `build_highlights()` function since
those are set without `default = true`.

## Files to Create

### `lua/andrew/vault/colors.lua`

Single new file (~120-150 lines). Contains:
- Three palette tables (OneDark, Soft Paper Light, Soft Paper Dark)
- `scheme_palettes` registry for pattern-based detection
- `detect_palette()` function
- `build_hl_groups(palette)` function
- `define_highlights()` function
- `setup()` function (defines + registers autocmd)
- `get(name)` accessor for raw palette values
- `M.palette` export for direct table access

## Files to Modify

### `lua/andrew/vault/wikilink_highlights.lua`

- Remove `hl_groups` table (lines 18-26)
- Remove `define_highlights()` function (lines 28-34)
- Remove `define_highlights()` call in `setup()` (line 253)
- Remove `ColorScheme` autocmd in `setup()` (lines 285-288)

### `lua/andrew/vault/tag_highlights.lua`

- Remove `hl_groups` table (lines 131-138)
- Remove `define_highlights()` function (lines 140-145)
- Remove `define_highlights()` call in `setup()` (line 386)
- Remove `ColorScheme` autocmd in `setup()` (lines 417-420)

### `lua/andrew/vault/highlights.lua`

- Remove `hl_groups` table (lines 16-19)
- Remove `define_highlights()` function (lines 21-26)
- Remove `define_highlights()` call in `setup()` (line 280)
- Remove `ColorScheme` autocmd in `setup()` (lines 308-311)

### `lua/andrew/vault/inline_fields.lua`

- Remove `hl_groups` table (lines 16-25)
- Remove `define_highlights()` function (lines 27-32)
- Remove `define_highlights()` call in `setup()` (line 738)
- Remove `ColorScheme` autocmd in `setup()` (lines 769-772)

### `lua/andrew/vault/engine.lua` (or equivalent init path)

- Add `require("andrew.vault.colors").setup()` early in the initialization
  sequence, before the highlight modules are set up.

### `lua/andrew/themes/soft-paper.lua` (no changes required)

Soft-paper.lua continues to define `Vault*` groups in its `build_highlights()`
function. Since those are applied without `default = true`, they override the
colors module's defaults. No code changes needed. However, the vault highlight
definitions in soft-paper.lua are now technically redundant with the colors
module (the colors module provides the same values for the soft-paper palettes).
A future cleanup could remove the `Vault*` entries from soft-paper.lua entirely,
relying solely on the colors module's soft-paper palette detection. This is
optional and can be deferred.

## Testing

### Theme switching verification

1. **Start with OneDark (default):**
   - Open a vault markdown file.
   - Verify wikilink colors: valid links are blue (`#61afef`) with underline.
   - Verify tag colors: `#project/foo` is blue, `#status/bar` is green.
   - Verify inline field colors: keys are red, values are green, dates are
     yellow.
   - Verify `==highlight==` marks have dark yellow background.

2. **Switch to soft-paper-light:**
   - Run `:lua require("andrew.themes.soft-paper").load("light")`
   - Verify wikilink colors change to sapphire (`#1A7DA4`).
   - Verify tag hash `#` becomes warm gray (`#CAC1B9`), not dark gray.
   - Verify `==highlight==` background changes to warm golden.
   - Verify all 22 `Vault*` groups updated (spot-check 3-4 from each module).

3. **Switch to soft-paper-dark:**
   - Run `:lua require("andrew.themes.soft-paper").load("dark")`
   - Verify wikilink colors change to teal (`#11B7C5`).
   - Verify highlight background is dark olive (`#6D6B43`).

4. **Switch back to OneDark:**
   - Run `:colorscheme onedark`
   - Verify vault colors revert to original OneDark values.
   - This is the critical test -- previously this direction was broken because
     the vault modules always applied OneDark colors regardless of detection.

5. **Inspect highlight groups:**
   - After each switch, run `:hi VaultWikiLinkValid` and verify the fg value
     matches the expected palette.
   - Run `:hi VaultTag`, `:hi VaultFieldKey`, `:hi VaultHighlight` similarly.

6. **Verify extmarks update:**
   - After switching themes, check that existing wikilink, tag, field, and
     highlight extmarks in open buffers reflect the new colors.
   - The extmarks reference highlight group names (not raw colors), so they
     should update automatically when the groups are redefined.

7. **Cold start verification:**
   - Close Neovim. Edit `colorscheme.lua` to load soft-paper instead of
     OneDark. Restart Neovim. Open a vault file.
   - Verify vault highlights use soft-paper colors from the start (no flash
     of OneDark colors).

### Regression checks

- `:VaultWikilinkHLToggle` still works (toggle on/off).
- `:VaultTagHLRefresh` still refreshes tags with correct colors.
- `:VaultFieldList` still lists fields correctly.
- `]t` / `[t` tag navigation still works.
- `]h` / `[h` highlight navigation still works.
- `]f` / `[f` field navigation still works.
- Insert-mode `<C-x><C-f>` field completion still works.

### Verify no circular dependencies

Run from Neovim command line:
```vim
:lua require("andrew.vault.colors")
```

This should succeed with no errors. The colors module has no vault-internal
requires.

## Future Work

After this module is in place, the same pattern can be extended to:

- **`embed.lua`**: Add `embed_content`, `embed_border`, `embed_cycle`,
  `embed_depth` to the palette. Add corresponding entries to soft-paper.lua.
- **`calendar.lua`**: Add `calendar_header`, `calendar_today`, etc. to the
  palette. Currently uses Catppuccin Mocha colors that don't match either
  OneDark or soft-paper.
- **`graph.lua`**: Add `graph_existing`, `graph_unresolved` to the palette.

These are lower priority since they affect fewer users and have less visual
impact than the four core highlight modules.
