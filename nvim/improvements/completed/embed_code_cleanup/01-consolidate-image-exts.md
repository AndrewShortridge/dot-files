# Implementation Plan: Consolidate Duplicated IMAGE_EXTS and is_image Functions

## Problem

Two vault modules independently define image extension tables and image-checking functions:

| File | Table | Extensions | Checker Function |
|------|-------|-----------|------------------|
| `embed.lua:23-26` | `IMAGE_EXTS` | png, jpg, jpeg, gif, svg, webp, bmp, tiff, **heic, avif** | `is_image_embed(inner)` -- guards against `^blockref` and `#heading` |
| `export.lua:11-14` | `image_exts` | png, jpg, jpeg, gif, svg, webp, bmp, tiff | `is_image(name)` -- simple extension check on a pre-parsed name |

The export table is missing `heic` and `avif`. Any future extension additions must be made in two places, violating DRY.

## Decision: Where to Put the Shared Constant

**Chosen location: `config.lua`** under `M.embed`.

Rationale:
- Both `embed.lua` and `export.lua` already `require("andrew.vault.config")` at the top. No new dependency is introduced.
- `config.lua` is the established single source of truth for vault-wide constants (task states, note types, status values, etc.). An image extension set fits this pattern perfectly.
- `link_utils.lua` is a parsing utility module. Adding media constants there would blur its responsibility.
- A new `constants.lua` file is unnecessary for a single table -- `config.lua` already serves that role.
- Placing it under `M.embed` (rather than top-level) makes sense because image embeds are the primary consumer, and `config.embed` already holds embed-related settings.

## Exact Changes

### 1. `config.lua` -- Add `image_exts` to the embed section

**File:** `lua/andrew/vault/config.lua`

**Location:** Inside the `M.embed` table (currently lines 66-75), add `image_exts` as a new field.

Change the block at lines 66-75 from:

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
}
```

to:

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
  --- File extensions recognized as images for embed rendering and export.
  --- Used by embed.lua (inline image placement) and export.lua (markdown image conversion).
  --- Keys are lowercase extensions; values are true.
  image_exts = {
    png = true, jpg = true, jpeg = true, gif = true, svg = true,
    webp = true, bmp = true, tiff = true, heic = true, avif = true,
  },
}
```

### 2. `embed.lua` -- Remove local `IMAGE_EXTS`, reference `config.embed.image_exts`

**File:** `lua/andrew/vault/embed.lua`

**Change A:** Delete lines 22-26 (the local `IMAGE_EXTS` table and its comment):

```lua
-- DELETE these lines:
-- Image extensions: rendered inline via snacks.nvim
local IMAGE_EXTS = {
  png = true, jpg = true, jpeg = true, gif = true, svg = true,
  webp = true, bmp = true, tiff = true, heic = true, avif = true,
}
```

**Change B:** In `is_image_embed()` (currently line 59), replace the `IMAGE_EXTS` reference:

```lua
-- Before:
  return ext and IMAGE_EXTS[ext:lower()] or false

-- After:
  return ext and config.embed.image_exts[ext:lower()] or false
```

### 3. `export.lua` -- Remove local `image_exts`, reference `config.embed.image_exts`

**File:** `lua/andrew/vault/export.lua`

**Change A:** Delete the local `image_exts` table (lines 10-14).

**Change B:** Update `is_image` to reference the shared table:

```lua
local function is_image(name)
  local ext = name:match("%.(%w+)$")
  return ext and config.embed.image_exts[ext:lower()] or false
end
```

## Summary of Changes

| File | Lines Changed | Nature of Change |
|------|--------------|------------------|
| `config.lua` | ~5 lines added inside `M.embed` | Add `image_exts` field with all 10 extensions |
| `embed.lua` | ~5 lines removed, 1 line changed | Remove local `IMAGE_EXTS` table; change lookup in `is_image_embed` to `config.embed.image_exts` |
| `export.lua` | ~4 lines removed, 1 line changed | Remove local `image_exts` table; change lookup in `is_image` to `config.embed.image_exts` |

Total: ~10 lines removed, ~6 lines added (net reduction of ~4 lines).

## What Does NOT Change

- **`is_image_embed()` in embed.lua** -- The `^`/`#` guards and raw-inner-text parsing stay. Only the table reference changes.
- **`is_image()` in export.lua** -- The function signature, behavior, and call site stay. Only the table reference changes.
- **`images.lua`** -- Does not have its own extension list.
- **Treesitter query** (`queries/markdown_inline/images.scm`) -- Uses a generic pattern, not a specific extension list.
- **No new `require` statements** -- Both consumers already require `config`.

## Verification

1. Open a note containing `![[image.heic]]` and `![[image.avif]]` -- both should render as inline images.
2. Run `:VaultExport` on a note with `![[photo.heic]]` -- should produce `![photo](...)` markdown image syntax.
3. Run `:VaultExport` on a note with `![[photo.png]]` -- confirm existing behavior unchanged.
4. Confirm `![[#Heading]]` and `![[^blockid]]` are still NOT treated as images.
5. Run `:VaultEmbedRender` on a note with mixed note and image embeds -- both types render correctly.
