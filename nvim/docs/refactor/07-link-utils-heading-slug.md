# Feature 07: `link_utils.heading_to_slug()`

## Dependencies
- **Feature 06** (link_utils module must exist first)
- **Depended on by:** Feature 09 (read_heading_section uses heading matching)

## Problem
The heading-to-slug conversion is implemented 5 times across 4 files, with one version being **subtly different** (a bug):

**Canonical version (4 copies match):**
```lua
text:lower():gsub("[^%w%s%-]", ""):gsub("%s", "-"):gsub("^%-+", ""):gsub("%-+$", "")
```
- `wikilinks.lua:298-302` (inline, also repeated at 306-310 and 383-387 — 3 inline copies!)
- `linkcheck.lua:60-66` (`heading_to_slug`)
- `linkdiag.lua:17-23` (`heading_to_slug`)
- `export.lua:27-33` (`heading_to_anchor`)

**Divergent version (BUG):**
```lua
text:lower():gsub("[^%w%s%-]", ""):gsub("%s+", "-"):gsub("%-+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
```
- `backlinks.lua:46-53` — has TWO extra transformations:
  1. Uses `%s+` (one-or-more whitespace) instead of `%s` (single whitespace)
  2. Adds `:gsub("%-+", "-")` (collapse consecutive hyphens)

This means `backlinks.lua` produces **different slugs** for headings with multiple spaces. For example:
- Heading: `"Hello  World"` (two spaces)
- Canonical: `"hello--world"` (two hyphens)
- backlinks.lua: `"hello-world"` (one hyphen, due to hyphen collapse)

This could cause heading anchor navigation from backlinks to fail for certain headings.

## Files to Modify
1. `lua/andrew/vault/link_utils.lua` — Add `M.heading_to_slug(text)` (created in Feature 06)
2. `lua/andrew/vault/wikilinks.lua` — Replace 3 inline copies (lines ~298-302, ~306-310, ~383-387)
3. `lua/andrew/vault/linkcheck.lua` — Delete local `heading_to_slug` (lines 60-66)
4. `lua/andrew/vault/linkdiag.lua` — Delete local `heading_to_slug` (lines 17-23)
5. `lua/andrew/vault/export.lua` — Delete local `heading_to_anchor` (lines 27-33)
6. `lua/andrew/vault/backlinks.lua` — Delete local `heading_slug` (lines 46-53), fix the bug

## Implementation Steps

### Step 1: Add to link_utils.lua

```lua
--- Convert a markdown heading to a URL-safe slug/anchor.
--- Matches Obsidian's heading anchor format.
--- @param text string  The heading text (without the # prefix)
--- @return string
function M.heading_to_slug(text)
  return text:lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s+", "-")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end
```

**Decision:** I recommend adopting the `backlinks.lua` version as canonical since it handles edge cases better:
- `%s+` collapses multiple whitespace into a single hyphen (more robust)
- `%-+` collapses consecutive hyphens (produces cleaner slugs)
- This matches how most markdown processors (GitHub, Obsidian) generate heading anchors

This means the other 4 copies had a minor bug for multi-space headings, not backlinks.lua. The backlinks version is the more correct one.

### Step 2: Update all consumers

**wikilinks.lua:** Replace the 3 inline slug computations:
```lua
-- Before (lines 298-302, repeated):
local heading_slug = details.heading:lower()
  :gsub("[^%w%s%-]", "")
  :gsub("%s", "-")
  :gsub("^%-+", "")
  :gsub("%-+$", "")

-- After:
local heading_slug = link_utils.heading_to_slug(details.heading)
```

**linkcheck.lua:** Delete lines 60-66. Replace all `heading_to_slug(text)` calls with `link_utils.heading_to_slug(text)`.

**linkdiag.lua:** Delete lines 17-23. Replace all `heading_to_slug(text)` calls with `link_utils.heading_to_slug(text)`.

**export.lua:** Delete `heading_to_anchor` (lines 27-33). Replace calls with `link_utils.heading_to_slug(text)`.

**backlinks.lua:** Delete `heading_slug` (lines 46-53). Replace calls with `link_utils.heading_to_slug(text)`.

### Step 3: Add require to each file
```lua
local link_utils = require("andrew.vault.link_utils")
```
If Feature 06 was already implemented, this require already exists.

## Testing
- Navigate to a heading anchor via `gf` on `[[Note#Multi  Spaced  Heading]]`
- `VaultLinkCheck` on a file with heading links — verify no false broken links
- `VaultLinkDiag` — verify heading diagnostics match actual headings
- `VaultBacklinks` on a note with heading references — verify they resolve
- `VaultExport` — verify heading anchors in exported HTML/PDF

## Estimated Impact
- **Lines removed:** ~30
- **Lines added:** ~8
- **Net reduction:** ~22 lines
- **Fixes:** Heading slug inconsistency between backlinks and all other modules
