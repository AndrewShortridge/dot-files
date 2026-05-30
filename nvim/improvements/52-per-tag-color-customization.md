# 52 --- Per-Tag Color Customization

## Motivation

Tag highlighting (`lua/andrew/vault/tag_highlights.lua`) currently uses
prefix-based category matching to assign colors to tags. The config section in
`lua/andrew/vault/config.lua` (lines 154-165) provides a `categories` list:

```lua
M.tag_highlights = {
  enabled = true,
  debounce_ms = 200,
  categories = {
    { prefix = "project/", highlight = "VaultTagProject" },
    { prefix = "status/", highlight = "VaultTagStatus" },
    { prefix = "type/", highlight = "VaultTagType" },
    { prefix = "person/", highlight = "VaultTagPerson" },
  },
}
```

The matching logic in `tag_highlights.lua` (the `tag_highlight()` function,
lines 57-72) iterates through categories and returns the first prefix match,
falling back to `"VaultTag"`:

```lua
local function tag_highlight(tag)
  local categories = default_categories
  local ok, config = pcall(require, "andrew.vault.config")
  if ok and config.tag_highlights and config.tag_highlights.categories then
    categories = config.tag_highlights.categories
  end

  local lower = tag:lower()
  for _, cat in ipairs(categories) do
    if lower:sub(1, #cat.prefix) == cat.prefix then
      return cat.highlight
    end
  end
  return "VaultTag"
end
```

**The problem:** There is no way to assign a specific color to an individual
tag like `#urgent` or `#important`. If a user wants `#urgent` to appear red
and `#review` to appear yellow, they must invent artificial category prefixes
(`urgent/`, `review/`) and restructure their entire tag taxonomy. Flat tags --
which are the most common kind -- are all colored identically with the default
`VaultTag` highlight group.

---

## Current State Analysis

### File: `lua/andrew/vault/tag_highlights.lua`

The file has 373 lines organized into these sections:

| Section | Lines | Description |
|---------|-------|-------------|
| Tag pattern | 18-52 | `valid_tag_start()`, `is_hex_color()`, code exclusion imports |
| Highlight groups | 44-72 | `default_categories` table, `tag_highlight()` resolver |
| Core highlight | 74-174 | `clear()`, `apply()` -- scan buffer lines and set extmarks |
| Debounced update | 179-192 | `schedule_update()` with timer |
| Toggle | 196-211 | `M.toggle()` |
| Tag navigation | 215-275 | `jump_tag()` for `]t`/`[t` motions |
| Setup | 279-371 | Autocmds, commands, keymaps, palette registration |

**Key observation:** The `tag_highlight()` function (lines 57-72) is the sole
dispatch point. Every tag passes through it to get its highlight group name.
This is the only function that needs modification to support per-tag colors.

### File: `lua/andrew/vault/config.lua`

The `tag_highlights` config table (lines 154-165) currently has three fields:
`enabled`, `debounce_ms`, and `categories`. There is no `tag_colors` field.

### File: `lua/andrew/vault/colors.lua`

The color system works as follows:

1. **Palette definitions** (lines 16-369): Three palette tables (`onedark`,
   `soft_paper_light`, `soft_paper_dark`) mapping semantic names to hex colors.
   Tag-related palette keys: `tag_default`, `tag_project`, `tag_status`,
   `tag_type`, `tag_person`, `tag_hash`.

2. **Highlight group builder** (lines 404-532): `build_hl_groups(p)` maps
   palette values to `vim.api.nvim_set_hl` attribute tables. Tag groups are
   defined at lines 416-421:
   ```lua
   VaultTag        = { fg = p.tag_default, bold = true },
   VaultTagProject = { fg = p.tag_project, bold = true },
   VaultTagStatus  = { fg = p.tag_status, bold = true },
   VaultTagType    = { fg = p.tag_type, bold = true },
   VaultTagPerson  = { fg = p.tag_person, bold = true },
   VaultTagHash    = { fg = p.tag_hash },
   ```

3. **ColorScheme autocmd** (lines 553-563): `M.setup()` re-applies all
   highlights on colorscheme change.

4. **Public getter** (line 568): `M.get(name)` returns a palette hex color by
   semantic name.

**Key observation:** `colors.lua` uses `attrs.default = true` when setting
highlights (line 546), which means user-defined highlight groups with the same
name take precedence. Dynamic highlight groups created by `tag_highlights.lua`
should NOT use `default = true` so they always apply.

### Conflict Check: `tag_colors` field

No existing field named `tag_colors` exists anywhere in the config. The name
does not collide with `categories`, `enabled`, or `debounce_ms`.

### Conflict Check: Dynamic highlight group names

The naming convention `VaultTagCustom_<tagname>` avoids collisions with all
existing `VaultTag*` groups (`VaultTag`, `VaultTagProject`, `VaultTagStatus`,
`VaultTagType`, `VaultTagPerson`, `VaultTagHash`). Tag names containing `/`
will have slashes replaced with `_` in group names (e.g., `my/special` becomes
`VaultTagCustom_my_special`).

---

## Implementation

### Overview

The implementation touches two files:

1. **`lua/andrew/vault/config.lua`** -- Add `tag_colors` table to the
   `tag_highlights` config section.
2. **`lua/andrew/vault/tag_highlights.lua`** -- Add per-tag lookup table,
   dynamic highlight group creation, and priority-based matching.

No changes to `colors.lua` are needed. Dynamic highlight groups are created
directly in `tag_highlights.lua` using `vim.api.nvim_set_hl`, which is the
same API that `colors.lua` uses. The `ColorScheme` autocmd in
`tag_highlights.lua` already triggers re-application via `apply()`, and the
new `setup_tag_colors()` function will be called from both `setup()` and
the colorscheme handler.

---

### Change 1: Config Addition (`config.lua`)

#### Code to Add

```lua
  --- Per-tag color overrides (higher priority than categories).
  --- Keys are tag names (without #), case-insensitive.
  --- Values can be:
  ---   - A string: name of an existing highlight group (e.g., "VaultTagProject")
  ---   - A table: highlight attributes passed to nvim_set_hl (e.g., { fg = "#FF4444", bold = true })
  ---   - A table with palette ref: { fg = "palette.tag_project" } resolves via colors.get()
  tag_colors = {
    -- Examples (uncomment to use):
    -- ["urgent"]    = { fg = "#FF4444", bold = true },
    -- ["important"] = { fg = "#FF8800" },
    -- ["review"]    = "VaultTagProject",  -- reuse existing group
    -- ["wip"]       = { fg = "palette.tag_status", italic = true },
  },
```

#### Insertion Point

Inside the `M.tag_highlights` table, after the `categories` field (line 164),
before the closing brace (line 165).

#### Before/After

**Before** (lines 152-165):

```lua
-- ---------------------------------------------------------------------------
-- Tag highlights
-- ---------------------------------------------------------------------------
M.tag_highlights = {
  enabled = true,
  debounce_ms = 200,
  --- Category prefix -> highlight group mapping.
  --- First match wins (put more specific prefixes first).
  categories = {
    { prefix = "project/", highlight = "VaultTagProject" },
    { prefix = "status/", highlight = "VaultTagStatus" },
    { prefix = "type/", highlight = "VaultTagType" },
    { prefix = "person/", highlight = "VaultTagPerson" },
  },
}
```

**After:**

```lua
-- ---------------------------------------------------------------------------
-- Tag highlights
-- ---------------------------------------------------------------------------
M.tag_highlights = {
  enabled = true,
  debounce_ms = 200,
  --- Category prefix -> highlight group mapping.
  --- First match wins (put more specific prefixes first).
  categories = {
    { prefix = "project/", highlight = "VaultTagProject" },
    { prefix = "status/", highlight = "VaultTagStatus" },
    { prefix = "type/", highlight = "VaultTagType" },
    { prefix = "person/", highlight = "VaultTagPerson" },
  },
  --- Per-tag color overrides (higher priority than categories).
  --- Keys are tag names (without #), case-insensitive.
  --- Values can be:
  ---   - A string: name of an existing highlight group (e.g., "VaultTagProject")
  ---   - A table: highlight attributes passed to nvim_set_hl (e.g., { fg = "#FF4444", bold = true })
  ---   - A table with palette ref: { fg = "palette.tag_project" } resolves via colors.get()
  tag_colors = {
    -- Examples (uncomment to use):
    -- ["urgent"]    = { fg = "#FF4444", bold = true },
    -- ["important"] = { fg = "#FF8800" },
    -- ["review"]    = "VaultTagProject",  -- reuse existing group
    -- ["wip"]       = { fg = "palette.tag_status", italic = true },
  },
}
```

---

### Change 2: Dynamic Highlight Groups and Per-Tag Lookup (`tag_highlights.lua`)

This change adds three things:

1. A pre-computed lookup table (`tag_color_lut`) mapping lowercase tag names
   to highlight group names.
2. A `setup_tag_colors()` function that builds the lookup table and creates
   dynamic highlight groups at setup time (and on colorscheme change).
3. Modified `tag_highlight()` to check the lookup table before falling through
   to prefix category matching.

#### 2a: Add `setup_tag_colors()` and the lookup table

**Code to add** (new section after the existing "Highlight groups" section,
between lines 72 and 74):

```lua
-- ---------------------------------------------------------------------------
-- Per-tag color lookup (built at setup time, rebuilt on ColorScheme)
-- ---------------------------------------------------------------------------

--- Lowercase tag name -> highlight group name.
--- Populated by setup_tag_colors(). Empty until setup() runs.
---@type table<string, string>
local tag_color_lut = {}

--- Resolve a palette reference string like "palette.tag_project" to a hex color.
--- Returns the input unchanged if it is not a palette reference.
---@param value string
---@return string
local function resolve_palette_ref(value)
  if type(value) ~= "string" then return value end
  local key = value:match("^palette%.(.+)$")
  if not key then return value end
  local colors_ok, colors = pcall(require, "andrew.vault.colors")
  if colors_ok then
    return colors.get(key) or value
  end
  return value
end

--- Resolve palette references in a highlight attribute table.
--- Modifies the table in-place and returns it.
---@param attrs table
---@return table
local function resolve_palette_attrs(attrs)
  for _, field in ipairs({ "fg", "bg", "sp" }) do
    if attrs[field] then
      attrs[field] = resolve_palette_ref(attrs[field])
    end
  end
  return attrs
end

--- Sanitize a tag name for use in a highlight group name.
--- Replaces non-alphanumeric/non-underscore characters with underscores.
---@param tag string
---@return string
local function sanitize_hl_name(tag)
  return tag:gsub("[^a-zA-Z0-9_]", "_")
end

--- Build the per-tag color lookup table and create dynamic highlight groups.
--- Called from setup() and on ColorScheme events.
local function setup_tag_colors()
  tag_color_lut = {}

  local ok, config = pcall(require, "andrew.vault.config")
  if not ok or not config.tag_highlights or not config.tag_highlights.tag_colors then
    return
  end

  local tag_colors = config.tag_highlights.tag_colors
  for tag_name, spec in pairs(tag_colors) do
    local lower = tag_name:lower()

    if type(spec) == "string" then
      -- Direct highlight group reference (e.g., "VaultTagProject")
      tag_color_lut[lower] = spec

    elseif type(spec) == "table" then
      -- Inline color spec -- create a dynamic highlight group
      local group_name = "VaultTagCustom_" .. sanitize_hl_name(lower)
      local attrs = vim.deepcopy(spec)
      resolve_palette_attrs(attrs)
      -- Do NOT set default = true; custom colors should always apply
      vim.api.nvim_set_hl(0, group_name, attrs)
      tag_color_lut[lower] = group_name
    end
  end
end
```

#### Insertion Point

After the closing of the current "Highlight groups" section (after line 72,
the `end` of `tag_highlight()`), before the "Core highlight application"
section comment (line 74).

#### Before/After for the Insertion

**Before** (lines 70-77):

```lua
  end
  return "VaultTag"
end

-- ---------------------------------------------------------------------------
-- Core highlight application
-- ---------------------------------------------------------------------------
```

**After:**

```lua
  end
  return "VaultTag"
end

-- ---------------------------------------------------------------------------
-- Per-tag color lookup (built at setup time, rebuilt on ColorScheme)
-- ---------------------------------------------------------------------------

--- Lowercase tag name -> highlight group name.
--- Populated by setup_tag_colors(). Empty until setup() runs.
---@type table<string, string>
local tag_color_lut = {}

--- Resolve a palette reference string like "palette.tag_project" to a hex color.
--- Returns the input unchanged if it is not a palette reference.
---@param value string
---@return string
local function resolve_palette_ref(value)
  if type(value) ~= "string" then return value end
  local key = value:match("^palette%.(.+)$")
  if not key then return value end
  local colors_ok, colors = pcall(require, "andrew.vault.colors")
  if colors_ok then
    return colors.get(key) or value
  end
  return value
end

--- Resolve palette references in a highlight attribute table.
--- Modifies the table in-place and returns it.
---@param attrs table
---@return table
local function resolve_palette_attrs(attrs)
  for _, field in ipairs({ "fg", "bg", "sp" }) do
    if attrs[field] then
      attrs[field] = resolve_palette_ref(attrs[field])
    end
  end
  return attrs
end

--- Sanitize a tag name for use in a highlight group name.
--- Replaces non-alphanumeric/non-underscore characters with underscores.
---@param tag string
---@return string
local function sanitize_hl_name(tag)
  return tag:gsub("[^a-zA-Z0-9_]", "_")
end

--- Build the per-tag color lookup table and create dynamic highlight groups.
--- Called from setup() and on ColorScheme events.
local function setup_tag_colors()
  tag_color_lut = {}

  local ok, config = pcall(require, "andrew.vault.config")
  if not ok or not config.tag_highlights or not config.tag_highlights.tag_colors then
    return
  end

  local tag_colors = config.tag_highlights.tag_colors
  for tag_name, spec in pairs(tag_colors) do
    local lower = tag_name:lower()

    if type(spec) == "string" then
      -- Direct highlight group reference (e.g., "VaultTagProject")
      tag_color_lut[lower] = spec

    elseif type(spec) == "table" then
      -- Inline color spec -- create a dynamic highlight group
      local group_name = "VaultTagCustom_" .. sanitize_hl_name(lower)
      local attrs = vim.deepcopy(spec)
      resolve_palette_attrs(attrs)
      -- Do NOT set default = true; custom colors should always apply
      vim.api.nvim_set_hl(0, group_name, attrs)
      tag_color_lut[lower] = group_name
    end
  end
end

-- ---------------------------------------------------------------------------
-- Core highlight application
-- ---------------------------------------------------------------------------
```

#### 2b: Modify `tag_highlight()` to check per-tag lookup first

The `tag_highlight()` function (lines 57-72) needs a two-line addition at the
top of the function body, after the `local lower = tag:lower()` line.

**Before** (lines 57-72):

```lua
local function tag_highlight(tag)
  local categories = default_categories
  -- Allow config override if available
  local ok, config = pcall(require, "andrew.vault.config")
  if ok and config.tag_highlights and config.tag_highlights.categories then
    categories = config.tag_highlights.categories
  end

  local lower = tag:lower()
  for _, cat in ipairs(categories) do
    if lower:sub(1, #cat.prefix) == cat.prefix then
      return cat.highlight
    end
  end
  return "VaultTag"
end
```

**After:**

```lua
local function tag_highlight(tag)
  local lower = tag:lower()

  -- Priority 1: exact per-tag color match (O(1) lookup)
  local custom = tag_color_lut[lower]
  if custom then return custom end

  -- Priority 2: prefix-based category match
  local categories = default_categories
  local ok, config = pcall(require, "andrew.vault.config")
  if ok and config.tag_highlights and config.tag_highlights.categories then
    categories = config.tag_highlights.categories
  end

  for _, cat in ipairs(categories) do
    if lower:sub(1, #cat.prefix) == cat.prefix then
      return cat.highlight
    end
  end

  -- Priority 3: default tag highlight
  return "VaultTag"
end
```

**How it works:**

- `tag_color_lut` is a flat table keyed by lowercase tag name. Lua table
  lookup is O(1) (hash table), so there is no performance cost regardless of
  how many per-tag colors are configured.
- The lookup happens BEFORE the category prefix loop, establishing the
  priority order: exact tag match > prefix category match > default.
- The `lower` variable computation is moved above both checks since both need
  it.

#### 2c: Call `setup_tag_colors()` from `setup()` and on ColorScheme

The `setup()` function (lines 281-371) needs two additions:

1. Call `setup_tag_colors()` at the beginning of `setup()` to build the
   initial lookup table.
2. Call `setup_tag_colors()` inside the `ColorScheme` autocmd callback so
   palette references are re-resolved when the theme changes.

**Before** (lines 281-298, the beginning of `setup()`):

```lua
function M.setup()
  local palette = require("andrew.vault.command_palette")
  local group = vim.api.nvim_create_augroup("VaultTagHL", { clear = true })

  -- Apply on buffer enter and after writes
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            apply(ev.buf)
          end
        end, 30)
      end
    end,
  })
```

**After:**

```lua
function M.setup()
  local palette = require("andrew.vault.command_palette")
  local group = vim.api.nvim_create_augroup("VaultTagHL", { clear = true })

  -- Build per-tag color lookup table and create dynamic highlight groups
  setup_tag_colors()

  -- Rebuild per-tag colors when colorscheme changes (palette refs need re-resolution)
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      setup_tag_colors()
    end,
    desc = "Vault: rebuild per-tag color highlight groups",
  })

  -- Apply on buffer enter and after writes
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            apply(ev.buf)
          end
        end, 30)
      end
    end,
  })
```

---

## Complete `tag_highlight()` and Lookup After All Changes

For reference, the complete modified matching logic:

```lua
-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

--- Category prefix -> highlight group mapping.
--- Order matters: first match wins (most specific prefix first).
local default_categories = {
  { prefix = "project/", highlight = "VaultTagProject" },
  { prefix = "status/", highlight = "VaultTagStatus" },
  { prefix = "type/", highlight = "VaultTagType" },
  { prefix = "person/", highlight = "VaultTagPerson" },
}

--- Determine the highlight group for a tag based on per-tag colors, then
--- category prefix, then default.
---@param tag string the tag text (without #)
---@return string highlight_group
local function tag_highlight(tag)
  local lower = tag:lower()

  -- Priority 1: exact per-tag color match (O(1) lookup)
  local custom = tag_color_lut[lower]
  if custom then return custom end

  -- Priority 2: prefix-based category match
  local categories = default_categories
  local ok, config = pcall(require, "andrew.vault.config")
  if ok and config.tag_highlights and config.tag_highlights.categories then
    categories = config.tag_highlights.categories
  end

  for _, cat in ipairs(categories) do
    if lower:sub(1, #cat.prefix) == cat.prefix then
      return cat.highlight
    end
  end

  -- Priority 3: default tag highlight
  return "VaultTag"
end

-- ---------------------------------------------------------------------------
-- Per-tag color lookup (built at setup time, rebuilt on ColorScheme)
-- ---------------------------------------------------------------------------

--- Lowercase tag name -> highlight group name.
--- Populated by setup_tag_colors(). Empty until setup() runs.
---@type table<string, string>
local tag_color_lut = {}

--- Resolve a palette reference string like "palette.tag_project" to a hex color.
--- Returns the input unchanged if it is not a palette reference.
---@param value string
---@return string
local function resolve_palette_ref(value)
  if type(value) ~= "string" then return value end
  local key = value:match("^palette%.(.+)$")
  if not key then return value end
  local colors_ok, colors = pcall(require, "andrew.vault.colors")
  if colors_ok then
    return colors.get(key) or value
  end
  return value
end

--- Resolve palette references in a highlight attribute table.
--- Modifies the table in-place and returns it.
---@param attrs table
---@return table
local function resolve_palette_attrs(attrs)
  for _, field in ipairs({ "fg", "bg", "sp" }) do
    if attrs[field] then
      attrs[field] = resolve_palette_ref(attrs[field])
    end
  end
  return attrs
end

--- Sanitize a tag name for use in a highlight group name.
--- Replaces non-alphanumeric/non-underscore characters with underscores.
---@param tag string
---@return string
local function sanitize_hl_name(tag)
  return tag:gsub("[^a-zA-Z0-9_]", "_")
end

--- Build the per-tag color lookup table and create dynamic highlight groups.
--- Called from setup() and on ColorScheme events.
local function setup_tag_colors()
  tag_color_lut = {}

  local ok, config = pcall(require, "andrew.vault.config")
  if not ok or not config.tag_highlights or not config.tag_highlights.tag_colors then
    return
  end

  local tag_colors = config.tag_highlights.tag_colors
  for tag_name, spec in pairs(tag_colors) do
    local lower = tag_name:lower()

    if type(spec) == "string" then
      -- Direct highlight group reference (e.g., "VaultTagProject")
      tag_color_lut[lower] = spec

    elseif type(spec) == "table" then
      -- Inline color spec -- create a dynamic highlight group
      local group_name = "VaultTagCustom_" .. sanitize_hl_name(lower)
      local attrs = vim.deepcopy(spec)
      resolve_palette_attrs(attrs)
      -- Do NOT set default = true; custom colors should always apply
      vim.api.nvim_set_hl(0, group_name, attrs)
      tag_color_lut[lower] = group_name
    end
  end
end
```

**Note on declaration order:** In the actual implementation, `tag_color_lut`
and `setup_tag_colors()` must be declared BEFORE `tag_highlight()` since
`tag_highlight()` references `tag_color_lut`. The "Complete" listing above
shows the logical grouping; in the actual file, move the per-tag lookup
section above the `tag_highlight()` function, or declare `local tag_color_lut
= {}` at the module top level (after line 12) and keep `setup_tag_colors()`
after `tag_highlight()`. The simplest approach is to declare the variable
early:

```lua
-- After line 12 (local DEBOUNCE_MS = 200):
---@type table<string, string>
local tag_color_lut = {}
```

Then the rest of the per-tag section (`resolve_palette_ref`,
`resolve_palette_attrs`, `sanitize_hl_name`, `setup_tag_colors`) can go after
`tag_highlight()` without any forward-reference issues, since `tag_color_lut`
is already in scope.

---

## Testing Instructions

### 1. Basic Per-Tag Color (Inline Hex)

1. Add a per-tag color to `config.lua`:
   ```lua
   tag_colors = {
     ["urgent"] = { fg = "#FF4444", bold = true },
   },
   ```
2. Restart Neovim (or source the config and run `:VaultTagHLRefresh`).
3. Open a vault markdown file containing `#urgent` on a body line.
4. Verify the tag text "urgent" renders in red (`#FF4444`) with bold.
5. Verify the `#` character still uses `VaultTagHash` (dim gray).
6. Inspect the highlight group:
   ```
   :echo synIDattr(synIDtrans(synID(line('.'), col('.'), 1)), 'fg#')
   ```
   Or use `:Inspect` on the tag text and confirm it shows
   `VaultTagCustom_urgent`.

### 2. Highlight Group Reference

1. Add:
   ```lua
   tag_colors = {
     ["review"] = "VaultTagProject",
   },
   ```
2. Open a file with `#review`. The tag should appear in the same color as
   `#project/anything` tags (blue in OneDark, accent in Soft Paper).
3. Confirm `#review` does NOT match the `VaultTag` default (purple).

### 3. Palette Reference

1. Add:
   ```lua
   tag_colors = {
     ["wip"] = { fg = "palette.tag_status", italic = true },
   },
   ```
2. Open a file with `#wip`. The tag should appear in the tag_status color
   (green in OneDark) with italic style.
3. Switch colorscheme (`:colorscheme soft-paper-light`). The `#wip` tag
   should update to the Soft Paper Light tag_status color (`#5BA57B`).

### 4. Priority Order

1. Configure both a per-tag color AND a matching category prefix:
   ```lua
   categories = {
     { prefix = "status/", highlight = "VaultTagStatus" },
   },
   tag_colors = {
     ["status/blocked"] = { fg = "#FF0000", bold = true, undercurl = true },
   },
   ```
2. Open a file with `#status/blocked` and `#status/active`.
3. `#status/blocked` should be red with undercurl (per-tag match wins).
4. `#status/active` should be green/status-colored (category prefix match).

### 5. Case Insensitivity

1. Configure `["urgent"] = { fg = "#FF4444" }`.
2. In a markdown file, write `#Urgent`, `#URGENT`, `#urgent`.
3. All three should render with the same red color.

### 6. Colorscheme Change

1. Configure a tag with palette references.
2. Open a vault file. Note the tag color.
3. Run `:colorscheme soft-paper-dark` (or any other supported scheme).
4. Verify the tag color updates to the new palette's values.
5. Verify tags with hardcoded hex colors (e.g., `#FF4444`) remain unchanged
   after the colorscheme switch.

### 7. Empty Config (No Regression)

1. Leave `tag_colors` as an empty table (the default).
2. Verify all existing category-based and default tag highlighting works
   exactly as before.
3. Verify `setup_tag_colors()` returns immediately without errors.

---

## Example Configurations

### Research Vault

```lua
tag_colors = {
  ["urgent"]      = { fg = "#FF4444", bold = true },
  ["important"]   = { fg = "#FF8800", bold = true },
  ["review"]      = { fg = "#E5C07B", italic = true },
  ["archived"]    = { fg = "#5C6370", italic = true },   -- dim gray
  ["hypothesis"]  = { fg = "#C678DD" },                   -- purple
  ["confirmed"]   = { fg = "#98C379", bold = true },      -- green
  ["refuted"]     = { fg = "#E06C75", strikethrough = true },
},
```

### GTD Workflow

```lua
tag_colors = {
  ["next"]        = { fg = "#FF4444", bold = true },      -- high visibility
  ["waiting"]     = { fg = "#E5C07B", italic = true },    -- yellow/pending
  ["someday"]     = { fg = "#5C6370" },                   -- dimmed
  ["delegated"]   = { fg = "#56B6C2", italic = true },    -- teal
  ["blocked"]     = { fg = "#E06C75", undercurl = true, sp = "#E06C75" },
},
```

### Theme-Aware with Palette References

```lua
tag_colors = {
  ["urgent"]    = { fg = "palette.link_broken", bold = true },   -- red in all themes
  ["done"]      = { fg = "palette.tag_status", italic = true },  -- green in all themes
  ["review"]    = "VaultTagType",                                 -- reuse type color
},
```

---

## Post-Implementation Cleanup

After implementing these changes, update the memory file
(`~/.claude/projects/-home-andrew-cmmg--config-nvim/memory/MEMORY.md`) to add
a note under the "Key Vault Modules" or a new section:

```
## Per-Tag Colors
- tag_highlights.lua supports `tag_colors` config for exact tag -> color mapping
- Priority: exact tag match (tag_colors) > prefix category > VaultTag default
- Dynamic highlight groups: VaultTagCustom_<sanitized_name>
- Palette references: { fg = "palette.<key>" } resolved via colors.get()
- Rebuilt on ColorScheme change (palette refs re-resolved)
```

---

## Summary of Changes

| File | Lines Added | Lines Modified | Description |
|------|-------------|----------------|-------------|
| `lua/andrew/vault/config.lua` | ~12 | 0 | New `tag_colors` field with doc comments and commented examples |
| `lua/andrew/vault/tag_highlights.lua` | ~75 | ~10 | Per-tag lookup table, `setup_tag_colors()`, modified `tag_highlight()` priority chain, ColorScheme autocmd |

No changes to `lua/andrew/vault/colors.lua`. No new files. No new
dependencies. The feature is fully backward-compatible: an empty `tag_colors`
table (the default) produces identical behavior to the current implementation.
