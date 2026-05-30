# 39 — Deduplicate heading_to_slug Function

## Problem

The `heading_to_slug()` function exists as two identical copies in the codebase:

1. **`link_utils.lua`** — the public, canonical version (`M.heading_to_slug(text)`) used by embed.lua, preview.lua, wikilinks.lua, completion.lua, linkdiag.lua, linkcheck.lua, export.lua, and wikilink_highlights.lua.

2. **`vault_index.lua`** — a local copy (`local function heading_to_slug(text)`) used only at line 359 during single-pass file parsing.

The `vault_index.lua` copy exists because vault_index.lua intentionally has **zero `require()` calls** to prevent circular dependency chains. Every other vault module requires vault_index, so if vault_index required link_utils (or any vault module), it would create a circular dependency.

The two implementations are character-for-character identical:

```lua
-- Both versions:
local slug = text:lower()
slug = slug:gsub("[^%w%s%-]", "")
slug = slug:gsub("%s+", "-")
slug = slug:gsub("%-+", "-")
slug = slug:gsub("^%-+", ""):gsub("%-+$", "")
return slug
```

**Risk:** If the slug algorithm is updated in one location but not the other, heading matching will silently diverge between the vault index (which powers heading lookups via `get_headings()`) and all other modules (which use `link_utils.heading_to_slug()` for navigation, preview, embed rendering, and link diagnostics). A mismatch would cause links like `[[Note#Heading]]` to resolve correctly in some contexts (e.g., `gf` navigation) but fail in others (e.g., vault index `get_headings()` lookup), producing difficult-to-diagnose bugs.

## Current State

| Component | Function | Scope | Location | Callers |
|-----------|----------|-------|----------|---------|
| `link_utils.lua` | `M.heading_to_slug(text)` | Exported (public) | Lines 73-80 | embed.lua, preview.lua, wikilinks.lua, linkdiag.lua, linkcheck.lua, export.lua, wikilink_highlights.lua, link_utils.lua itself |
| `vault_index.lua` | `heading_to_slug(text)` | Local (private) | Lines 196-203 | Line 359 (inside `extract_headings()` during file parsing) |

### Why the Duplication Exists

`vault_index.lua` has a strict zero-dependency design constraint documented at the top of the file and in the project memory. It has no `require()` calls. This prevents circular dependencies since nearly every vault module requires `vault_index`:

```
engine.lua ──require──> vault_index.lua
wikilinks.lua ──require──> vault_index.lua
linkcheck.lua ──require──> vault_index.lua
linkdiag.lua ──require──> vault_index.lua
completion.lua ──require──> vault_index.lua
tags.lua ──require──> vault_index.lua
...etc
```

If `vault_index.lua` added `require("andrew.vault.link_utils")`, it would create a circular dependency chain because `link_utils.lua` could transitively depend on modules that require `vault_index.lua`.

---

## Proposed Solution

**Option 2: Shared pure-function module** — Extract `heading_to_slug` into a tiny `lua/andrew/vault/slug.lua` module with zero requires that both `vault_index.lua` and `link_utils.lua` can safely require.

This is the cleanest approach because:

- The new module has **zero dependencies** (no requires), so `vault_index.lua` can require it without breaking its zero-dependency-on-vault-modules constraint. The only `require` added is to a leaf module with no transitive dependencies.
- The slug logic lives in exactly one place — no duplication, no divergence risk.
- All existing callers of `link_utils.heading_to_slug()` continue to work without changes (link_utils re-exports the function).
- The module is ~15 lines, self-contained, and trivially testable.

### New File: `lua/andrew/vault/slug.lua`

```lua
-- slug.lua — Pure heading-to-slug conversion.
-- Zero dependencies. Safe to require from vault_index.lua and link_utils.lua.

local M = {}

--- Convert heading text to a URL-safe slug for anchor matching.
--- Matches Obsidian's heading anchor format.
---@param text string  The heading text (without the # prefix)
---@return string
function M.heading_to_slug(text)
  return text:lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s+", "-")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end

return M
```

### Modified File: `lua/andrew/vault/vault_index.lua`

Add a require for the new slug module and remove the local duplicate.

**Add require** (after line 7, before the defaults block):

```lua
local slug = require("andrew.vault.slug")
```

**Remove** the local `heading_to_slug` function (lines 195-203):

```lua
-- DELETE:
--- Heading slug function (inline to avoid circular deps).
local function heading_to_slug(text)
  return text:lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s+", "-")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end
```

**Update the single call site** at line 359 (inside `extract_headings()`):

```lua
-- Before:
      local slug = heading_to_slug(text)

-- After:
      local hslug = slug.heading_to_slug(text)
```

Note: The local variable is renamed from `slug` to `hslug` to avoid shadowing the `slug` module require at the top of the file.

### Modified File: `lua/andrew/vault/link_utils.lua`

Replace the inline implementation with a delegation to the shared module.

**Add require** near the top of the file (after existing requires):

```lua
local slug_mod = require("andrew.vault.slug")
```

**Replace** the `M.heading_to_slug` function body (lines 73-80):

```lua
-- Before:
function M.heading_to_slug(text)
  return text:lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s+", "-")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end

-- After:
--- Convert heading text to a URL-safe slug for anchor matching.
--- Matches Obsidian's heading anchor format.
--- Delegates to slug.lua (single source of truth).
--- @param text string  The heading text (without the # prefix)
--- @return string
function M.heading_to_slug(text)
  return slug_mod.heading_to_slug(text)
end
```

The function signature and return type are unchanged, so all existing callers (`embed.lua`, `preview.lua`, `wikilinks.lua`, `linkdiag.lua`, `linkcheck.lua`, `export.lua`, `wikilink_highlights.lua`, and `link_utils.lua` itself) continue to work without modification.

---

## File Changes

| File | Change | Lines Removed | Lines Added | Net |
|------|--------|:------------:|:-----------:|:---:|
| `lua/andrew/vault/slug.lua` | **New file** — shared heading_to_slug with zero dependencies | 0 | 15 | +15 |
| `lua/andrew/vault/vault_index.lua` | Remove local `heading_to_slug`; add `require("andrew.vault.slug")`; rename local var to avoid shadow | 9 | 2 | -7 |
| `lua/andrew/vault/link_utils.lua` | Add `require("andrew.vault.slug")`; delegate `M.heading_to_slug` to slug module | 7 | 7 | 0 |
| **Total** | | **16** | **24** | **+8** |

---

## Dependencies

| Module | Direction | Relationship |
|--------|-----------|-------------|
| `slug.lua` | **New leaf module** | Zero requires. No dependencies on any vault module. |
| `vault_index.lua` | Requires `slug.lua` | Safe: slug.lua is a leaf with no transitive deps. vault_index.lua's constraint is zero requires *of vault modules that could create cycles*. slug.lua cannot create a cycle because it requires nothing. |
| `link_utils.lua` | Requires `slug.lua` | Safe: link_utils.lua already has requires; slug.lua is a pure leaf. |
| All callers of `link_utils.heading_to_slug()` | **Unchanged** | embed.lua, preview.lua, wikilinks.lua, linkdiag.lua, linkcheck.lua, export.lua, wikilink_highlights.lua, completion.lua — none require changes. |

### Dependency Graph (after change)

```
slug.lua  (zero requires — leaf node)
  ^
  |
  +--- vault_index.lua  (adds single require: slug.lua)
  |
  +--- link_utils.lua  (adds single require: slug.lua)
         ^
         |
         +--- embed.lua, preview.lua, wikilinks.lua, linkdiag.lua,
              linkcheck.lua, export.lua, wikilink_highlights.lua, completion.lua
              (all unchanged — still call link_utils.heading_to_slug)
```

No circular dependencies are introduced. The `slug.lua` module is strictly a leaf in the dependency graph.

---

## Testing Plan

### 1. Verify slug module loads independently

```vim
:lua print(require("andrew.vault.slug").heading_to_slug("Hello World!"))
```

**Expected:** `hello-world`

### 2. Verify link_utils delegation works

```vim
:lua print(require("andrew.vault.link_utils").heading_to_slug("Hello World!"))
```

**Expected:** `hello-world` (identical to direct slug module call)

### 3. Verify vault index uses shared slug

```vim
:VaultIndexRebuild
:VaultIndexStatus
```

**Expected:** Index rebuilds successfully with no errors. Status shows ready.

Then verify heading lookups work:

```vim
:lua local idx = require("andrew.vault.vault_index").current(); local h = idx:get_headings(vim.api.nvim_buf_get_name(0)); print(vim.inspect(h))
```

**Expected:** Returns a slug set matching the headings in the current file.

### 4. Verify all downstream callers still work

| Feature | Test Action | Expected Outcome |
|---------|------------|------------------|
| **Preview (K)** | Place cursor on `[[Note#Heading]]`, press `K` | Float shows correct heading section |
| **Navigation (gf)** | Place cursor on `[[Note#Heading]]`, press `gf` | Jumps to correct heading in target note |
| **Embed render** | Open file with `![[Note#Heading]]`, run `:VaultEmbedRender` | Heading section rendered as virtual text |
| **Link check** | Run `:VaultLinkCheck` on a file with heading links | Valid headings pass, broken headings flagged |
| **Link diagnostics** | Open file with `[[Note#BadHeading]]` | Diagnostic underline appears on broken heading anchor |
| **Export** | Run `:VaultExport html` on file with heading links | Heading anchors in exported HTML are correct |
| **Completion** | Type `[[Note#` in insert mode | Heading completions appear |

### 5. Verify slug consistency between modules

```vim
:lua local s = require("andrew.vault.slug"); local lu = require("andrew.vault.link_utils"); local cases = {"Hello World!", "café au Lait", "heading--with---dashes", "  leading trailing  ", "Special!@#$%^&*() Chars"}; for _, c in ipairs(cases) do assert(s.heading_to_slug(c) == lu.heading_to_slug(c), "Mismatch for: " .. c) end; print("All slug consistency checks passed")
```

**Expected:** `All slug consistency checks passed`

### 6. Verify no circular dependency

```vim
:lua package.loaded["andrew.vault.slug"] = nil; package.loaded["andrew.vault.vault_index"] = nil; require("andrew.vault.vault_index"); print("No circular dependency")
```

**Expected:** `No circular dependency` (no stack overflow or require-loop error)

### 7. Edge cases for slug function

```vim
:lua local s = require("andrew.vault.slug").heading_to_slug
:lua assert(s("") == "", "empty string")
:lua assert(s("---") == "", "only dashes")
:lua assert(s("Hello") == "hello", "simple word")
:lua assert(s("Two  Spaces") == "two-spaces", "multiple spaces collapse")
:lua assert(s("a-b--c---d") == "a-b-c-d", "multiple dashes collapse")
:lua assert(s("-leading") == "leading", "leading dash stripped")
:lua assert(s("trailing-") == "trailing", "trailing dash stripped")
:lua print("All edge case tests passed")
```

**Expected:** `All edge case tests passed`
