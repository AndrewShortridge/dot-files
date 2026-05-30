# 19 -- Link Intelligence

## Overview

The vault plugin already has strong foundations for link management: `linkdiag.lua` provides real-time broken link diagnostics with edit-distance repair suggestions, `linkcheck.lua` scans for broken links at buffer and vault scope, `unlinked.lua` finds mentions of note names that are not wrapped in wikilinks, `autolink.lua` provides inline suggestions for linkable text, and `search_filter.lua` supports `links-to:` and `linked-from:` operators. However, several natural extensions remain unimplemented that would close the gap between these modules and create a more cohesive "link intelligence" layer.

This document proposes four sub-features:

1. **Link Repair Suggestions** -- Extend `linkdiag.lua` with vault-wide batch repair, auto-fix by confidence threshold, and moved-file detection.
2. **Backlink-Specific Search** -- Extend `links-to:` and `linked-from:` to support heading fragments (`links-to:Note#Heading`).
3. **Inverse Tag Matching** -- Extend `tag:` filter to support comma-separated include/exclude lists (`tag:project,-archived`).
4. **Unlinked Mention Auto-Linking Batch Mode** -- Extend `unlinked.lua` to support buffer-level and vault-wide batch auto-linking with a review UI.

### Motivation

- **Link Repair**: `linkdiag.lua` already computes edit-distance suggestions and shows them via `vim.ui.select` for the link under the cursor. But there is no way to fix all broken links in the vault in a single pass, no auto-fix for high-confidence matches, and no detection of files that were moved rather than deleted.
- **Heading-Scoped Backlinks**: `links-to:ProjectAlpha` finds all notes linking to ProjectAlpha, but cannot distinguish between notes that link to `[[ProjectAlpha#Goals]]` and `[[ProjectAlpha#Budget]]`. Section-level backlink queries are essential for large notes with many inbound links.
- **Inverse Tag Matching**: Searching `tag:project` returns all notes with any `project/*` tag, including `project/archived` and `project/template`. There is no way to exclude subtrees, forcing users to write verbose `tag:project AND -tag:project/archived AND -tag:project/template` queries.
- **Batch Auto-Linking**: `unlinked.lua` finds unlinked mentions and allows wrapping via `Ctrl-w` in fzf, but there is no "auto-link current buffer" workflow that scans, reviews, and batch-applies all suggestions. `autolink.lua` provides inline hints but is per-cursor/per-line only.

---

## Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **linkdiag.lua** | Real-time broken link diagnostics, edit-distance repair suggestions, `vim.ui.select` code actions, fzf picker for all broken links in buffer | `lua/andrew/vault/linkdiag.lua` |
| **linkcheck.lua** | Buffer and vault-wide broken link scanning (note, heading, block), orphan detection, URL validation | `lua/andrew/vault/linkcheck.lua` |
| **unlinked.lua** | Find unlinked mentions of current note or all vault notes via ripgrep, `Ctrl-w` to wrap in wikilinks, `Ctrl-a` to wrap all in file | `lua/andrew/vault/unlinked.lua` |
| **autolink.lua** | Real-time inline suggestions for linkable text using virtual text extmarks, accept at cursor or accept-all-on-line | `lua/andrew/vault/autolink.lua` |
| **rename.lua** | Bulk note rename with automatic link rewriting across vault | `lua/andrew/vault/rename.lua` |
| **search_filter.lua** | `links-to:NoteName` and `linked-from:NoteName` evaluated via `_inlinks` and `resolve_note_to_rel_path()` | `lua/andrew/vault/search_filter.lua` |
| **search_query.lua** | Tokenizer with `FIELD` tokens; `parse_field_value()` handles operators | `lua/andrew/vault/search_query.lua` |
| **vault_index.lua** | Outlinks stored as `{ path, display, embed }` where `path` includes `#heading` and `^blockid` suffixes; `_inlinks` computed by stripping `#` and `^` suffixes | `lua/andrew/vault/vault_index.lua` |
| **link_utils.lua** | `parse_target()` decomposes `name#heading^block\|alias`; `heading_to_slug()` for slug comparison | `lua/andrew/vault/link_utils.lua` |
| **config.lua** | `M.search.builtin_fields`, `M.autolink`, `M.wikilink_highlights` | `lua/andrew/vault/config.lua` |
| **tags.lua** | Tag search, tree picker, add/remove operations | `lua/andrew/vault/tags.lua` |

### Key Index Data Structures

**Outlinks** (per entry, stored with `#heading` and `^blockid` intact):
```lua
-- entry.outlinks[] =
{ path = "ProjectAlpha#Goals", display = "ProjectAlpha", embed = false }
{ path = "ProjectAlpha^blk-abc123", display = "ProjectAlpha", embed = false }
{ path = "ProjectAlpha", display = "ProjectAlpha", embed = false }
```

**Inlinks** (derived, `#heading`/`^blockid` stripped during `_recompute_inlinks()`):
```lua
-- self._inlinks["Projects/ProjectAlpha.md"][] =
{ path = "Meeting/2026-02-15", display = "2026-02-15", embed = false }
```

The stripping at line 1012 of `vault_index.lua`:
```lua
raw = raw:match("^([^#^]+)") or raw
```
This means heading/block information is available in `outlinks[].path` but lost in `_inlinks`. Sub-feature 2 will need to work with the raw `outlinks[].path` field directly.

---

## Sub-Feature 1: Link Repair Suggestions

### Architecture

The existing `linkdiag.lua` already has all the building blocks:
- `edit_distance()` computes Levenshtein distance between two strings
- `find_closest()` returns top-N matches within a configurable threshold
- `find_closest_headings()` finds heading slug matches against a target file
- `actions_for_diag()` builds code action entries for broken note and broken heading diagnostics
- `apply_action()` performs the buffer edit
- `fix_links_picker()` shows all broken links in a buffer via fzf

What is missing:

1. **Vault-wide batch repair** (`:VaultLinkRepairAll`): Scan the entire vault for broken links, compute repair suggestions for each, show in a review UI.
2. **Auto-fix by confidence threshold**: When `edit_distance` is below a threshold (e.g., 1 or 2) and there is exactly one candidate, apply the fix automatically without prompting.
3. **Moved-file detection**: If a broken link's basename exists elsewhere in the vault (different folder), suggest the new path as a repair candidate.

### New Module: `link_repair.lua`

A new module rather than extending `linkdiag.lua`, since batch repair has different responsibilities (reading multiple files from disk, collecting changes before applying, summary reporting). `linkdiag.lua` remains focused on real-time buffer diagnostics; `link_repair.lua` handles the batch repair workflow.

```
lua/andrew/vault/link_repair.lua  (~300 lines)
```

### Data Flow

```
:VaultLinkRepair (buffer)
  |
  v
linkdiag.validate(bufnr) -- refresh diagnostics
  |
  v
collect_repair_candidates(bufnr)
  |-- For each broken_note diagnostic:
  |     find_closest() against all vault names
  |     check_moved_file() against vault index by basename
  |     score and rank candidates
  |
  |-- For each broken_heading diagnostic:
  |     find_closest_headings() against target file
  |
  v
Show review UI (fzf-lua or vim.ui.select)
  |-- User accepts/rejects per-suggestion
  |-- "Accept all high-confidence" batch action
  |
  v
apply_repairs()
  |-- Buffer edits (sorted by position, applied bottom-up)
  |-- Re-validate buffer
```

```
:VaultLinkRepairAll (vault)
  |
  v
rg scan for all wikilinks (reuse linkcheck.check_vault() pattern)
  |
  v
For each file, validate links and collect broken ones
  |
  v
Compute repair candidates for each broken link
  |
  v
Show fzf-lua picker: "file:line [[broken]] -> suggestion (dist=N)"
  |-- Enter: apply single fix
  |-- Ctrl-a: apply all auto-fixable (dist <= auto_fix_threshold)
  |-- Ctrl-j: jump to location
  |
  v
apply_file_repairs(file_path, repairs[])
  |-- Read file, apply changes bottom-up, write file
  |-- Reload open buffers
```

### Moved-File Detection

```lua
--- Check if a broken link target exists elsewhere in the vault under a different path.
--- Returns matching entries where the basename matches but the full path differs.
---@param broken_name string the broken link target (e.g., "OldProject")
---@param index table VaultIndex instance
---@return { rel_path: string, basename: string, dist: number }[]
local function check_moved_file(broken_name, index)
  local lower = broken_name:lower()
  local basename_lower = lower:match("[^/]+$") or lower
  local candidates = {}

  for rel_path, entry in pairs(index.files) do
    if entry.basename_lower == basename_lower then
      candidates[#candidates + 1] = {
        rel_path = rel_path,
        basename = entry.basename,
        dist = 0, -- exact basename match
      }
    end
  end

  return candidates
end
```

When a broken link like `[[OldFolder/Note]]` is detected and `OldFolder/Note.md` does not exist, this function finds `NewFolder/Note.md` as a candidate. The repair action would change the link to `[[Note]]` (basename-only, since Obsidian resolves by basename) or `[[NewFolder/Note]]` (preserving path style).

### Auto-Fix Logic

```lua
--- Determine if a repair candidate is high-confidence enough for auto-fix.
---@param candidates { name: string, dist: number }[]
---@param threshold number max edit distance for auto-fix (default 1)
---@return string|nil best_match the auto-fixable candidate, or nil
local function auto_fix_candidate(candidates, threshold)
  threshold = threshold or 1
  if #candidates == 0 then return nil end
  if #candidates == 1 and candidates[1].dist <= threshold then
    return candidates[1].name
  end
  -- Multiple candidates: only auto-fix if top candidate is strictly better
  if candidates[1].dist <= threshold
    and #candidates >= 2
    and candidates[2].dist > candidates[1].dist + 1 then
    return candidates[1].name
  end
  return nil
end
```

### Pseudo-Code: Buffer Repair

```lua
function M.repair_buffer(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  linkdiag.validate(bufnr)

  local diags = vim.diagnostic.get(bufnr, { namespace = linkdiag.ns })
  if #diags == 0 then
    vim.notify("Vault: no broken links in buffer", vim.log.levels.INFO)
    return
  end

  local idx = vault_index.current()
  local all_names = linkdiag.get_all_names()
  local repairs = {}

  for _, d in ipairs(diags) do
    if d._type == "broken_note" then
      local name_candidates = linkdiag_find_closest(d._target:lower(), all_names, 5)
      local moved_candidates = idx and check_moved_file(d._target, idx) or {}
      -- Merge and deduplicate candidates
      local merged = merge_candidates(name_candidates, moved_candidates)
      local auto = auto_fix_candidate(merged, opts.auto_fix_threshold or 1)
      repairs[#repairs + 1] = {
        diag = d,
        candidates = merged,
        auto_fix = auto,
        type = "note",
      }
    elseif d._type == "broken_heading" then
      local heading_candidates = linkdiag.find_closest_headings(
        link_utils.heading_to_slug(d._heading), d._filepath, 5
      )
      local auto = #heading_candidates == 1 and heading_candidates[1].dist <= 1
        and heading_candidates[1].heading or nil
      repairs[#repairs + 1] = {
        diag = d,
        candidates = heading_candidates,
        auto_fix = auto,
        type = "heading",
      }
    end
  end

  if opts.auto_fix_all then
    -- Apply all auto-fixable repairs (bottom-up by line number)
    table.sort(repairs, function(a, b) return a.diag.lnum > b.diag.lnum end)
    local fixed = 0
    for _, r in ipairs(repairs) do
      if r.auto_fix then
        apply_repair(bufnr, r)
        fixed = fixed + 1
      end
    end
    vim.notify("Vault: auto-fixed " .. fixed .. " link(s)", vim.log.levels.INFO)
    linkdiag.validate(bufnr)
    return
  end

  -- Show fzf picker with all broken links and their candidates
  show_repair_picker(bufnr, repairs)
end
```

### Config

```lua
-- In config.lua, add:
M.link_repair = {
  -- Maximum edit distance for auto-fix (single candidate with dist <= threshold)
  auto_fix_threshold = 1,
  -- Maximum candidates to show per broken link
  max_candidates = 5,
  -- Include moved-file detection in suggestions
  detect_moved = true,
}
```

### Commands and Keybindings

| Command | Description | Keybinding |
|---------|-------------|------------|
| `:VaultLinkRepair` | Repair broken links in current buffer (interactive) | `<leader>vcr` |
| `:VaultLinkRepair!` | Repair broken links in current buffer (auto-fix only) | -- |
| `:VaultLinkRepairAll` | Repair broken links vault-wide (interactive) | `<leader>vcR` |
| `:VaultLinkRepairAll!` | Repair broken links vault-wide (auto-fix only) | -- |

### Edge Cases

1. **Multiple candidates with same distance**: Show all in picker; do not auto-fix.
2. **Broken link with heading that resolves after note fix**: If `[[Alph#Goals]]` is broken because `Alph` is not found but `Alpha` exists and has a `Goals` heading, fixing the note name should resolve both issues. The repair logic should re-validate the heading after applying the note fix.
3. **Concurrent buffer modifications**: Apply repairs bottom-up (descending line number) so that earlier edits do not shift positions of later edits.
4. **Vault-wide file writes**: Use `engine.write_file()` for non-buffer files and `vim.api.nvim_buf_set_lines()` for loaded buffers, matching the pattern in `rename.lua`.
5. **Undo integration**: Buffer repairs are normal buffer edits, so `u` undoes them. Vault-wide file writes are not undoable -- show a confirmation prompt before applying.

### Estimated Line Counts

| File | Lines | Action |
|------|-------|--------|
| `lua/andrew/vault/link_repair.lua` | ~300 | Create |
| `lua/andrew/vault/linkdiag.lua` | ~10 | Modify (expose `find_closest` and `edit_distance` as M exports) |
| `lua/andrew/vault/config.lua` | ~10 | Modify (add `M.link_repair` section) |

---

## Sub-Feature 2: Backlink-Specific Search (links-to:X#Heading)

### Architecture

Currently, `links-to:NoteName` resolves NoteName to a `rel_path`, then checks `_inlinks[rel_path]` for the source entry. The `#heading` suffix is stripped during `_recompute_inlinks()`, so heading-level granularity is lost in the inlinks table.

To support `links-to:Note#Heading`, we need to match against the raw `outlinks[].path` field, which preserves `#heading` and `^blockid` suffixes.

The approach:

1. **Parse the `#heading` fragment** from the filter value in `match_field()`.
2. **When a heading is present**, iterate the candidate entry's `outlinks[]` directly rather than using `_inlinks`.
3. **Use slug comparison** (`heading_to_slug()`) for case-insensitive heading matching.
4. **For `linked-from:Note#Heading`**, find notes linked from a specific section of the source note. This requires identifying which outlinks originate from the specified heading section -- which is NOT stored in the current outlinks structure.

### Tokenizer Changes: None

The tokenizer already handles `links-to:"Note#Heading"` correctly:
- The `#` is inside the quoted value, so it is preserved as part of the field value.
- `parse_field_value("Note#Heading")` returns `op = "=", value = "Note#Heading"`.
- For unquoted usage, `links-to:Note#Heading` is scanned as a single word (the `#` does not break word scanning), and `parse_field_value()` returns `op = "=", value = "Note#Heading"`.

### Filter Changes: `search_filter.lua`

Replace the current `links-to:` handler with heading-aware logic:

```lua
  -- ── links-to ──
  if name == "links-to" then
    if op ~= "=" then return false end
    if not index then return false end

    -- Parse heading fragment from filter value
    local target_name, target_heading = parse_link_target(filter_val)

    -- Resolve the target note name to a rel_path
    local target_rel = resolve_note_to_rel_path(target_name, index)
    if not target_rel then return false end

    if not target_heading then
      -- No heading: use existing fast inlinks path
      local inlinks = index:get_inlinks(target_rel)
      local source_stem = entry.rel_path:gsub("%.md$", "")
      for _, inlink in ipairs(inlinks) do
        if inlink.path == source_stem then
          return true
        end
      end
      return false
    end

    -- Heading specified: scan outlinks of the candidate entry
    local target_heading_slug = slug_mod.heading_to_slug(target_heading)
    local target_stem = target_rel:gsub("%.md$", "")
    for _, link in ipairs(entry.outlinks) do
      local raw = link.path or ""
      local link_name = raw:match("^([^#^]+)") or raw
      link_name = vim.trim(link_name)
      local link_heading = raw:match("#([^#^|]+)")
      if link_heading then
        local link_name_lower = link_name:lower()
        -- Check if this outlink points to our target note
        local matches_note = link_name_lower == target_name:lower()
          or link_name_lower == target_stem:lower()
          or link_name_lower == (target_stem:match("([^/]+)$") or ""):lower()
        if matches_note then
          local link_heading_slug = slug_mod.heading_to_slug(link_heading)
          if link_heading_slug == target_heading_slug then
            return true
          end
        end
      end
    end
    return false
  end
```

### Helper: Parse Link Target

```lua
--- Parse a link filter value into note name and optional heading.
--- "Note" -> "Note", nil
--- "Note#Heading" -> "Note", "Heading"
--- "#Heading" -> "", "Heading" (same-file heading reference)
---@param value string
---@return string name, string|nil heading
local function parse_link_target(value)
  local name, heading = value:match("^([^#]*)#(.+)$")
  if name then
    return name, heading
  end
  return value, nil
end
```

### linked-from:Note#Heading -- Scoped Outlink Query

`linked-from:Note#Heading` means "find notes that are linked from the Heading section of Note." This requires knowing which outlinks originate from a specific section of the source note -- information that is **not currently stored** in the index.

**Two approaches:**

**A. Index Enhancement (preferred, higher complexity):** Store line numbers with outlinks and cross-reference with headings.

Modify `extract_links()` in `vault_index.lua` to track line numbers:
```lua
-- Currently:
links[#links + 1] = { path = path, display = vim.trim(clean_display), embed = false }

-- Enhanced:
links[#links + 1] = { path = path, display = vim.trim(clean_display), embed = false, line = line_num }
```

Then at query time, determine which heading section a given line belongs to:
```lua
--- Find which heading section a line number falls within.
---@param headings table[] entry.headings (ordered by line)
---@param line_num number
---@return string|nil heading_text
local function heading_for_line(headings, line_num)
  local current_heading = nil
  for _, h in ipairs(headings) do
    if h.line <= line_num then
      current_heading = h.text
    else
      break
    end
  end
  return current_heading
end
```

**B. Runtime Read (simpler, slower):** When `linked-from:Note#Heading` is evaluated, read the source file and extract outlinks only from the specified heading section.

Given that `linked-from:Note#Heading` is evaluated once per query (the source note is fixed), and reading a single file from disk is fast, approach B is acceptable for initial implementation. Approach A can be added later as an optimization if needed.

**Implementation with approach B:**

```lua
  -- ── linked-from ──
  if name == "linked-from" then
    if op ~= "=" then return false end
    if not index then return false end

    local source_name, source_heading = parse_link_target(filter_val)
    local source_rel = resolve_note_to_rel_path(source_name, index)
    if not source_rel then return false end

    if not source_heading then
      -- No heading: use existing inlinks path
      local inlinks = index:get_inlinks(entry.rel_path)
      local source_stem = source_rel:gsub("%.md$", "")
      for _, inlink in ipairs(inlinks) do
        if inlink.path == source_stem then
          return true
        end
      end
      return false
    end

    -- Heading specified: find outlinks within the heading section of source
    local source_entry = index.files[source_rel]
    if not source_entry then return false end

    -- Get outlinks that originate from the specified heading section
    local section_outlinks = get_section_outlinks(source_entry, source_heading, index)
    local entry_stem = entry.rel_path:gsub("%.md$", "")
    local entry_name_lower = entry.basename_lower

    for _, link in ipairs(section_outlinks) do
      local raw = link.path or ""
      local link_name = raw:match("^([^#^]+)") or raw
      link_name = vim.trim(link_name):lower()
      if link_name == entry_name_lower or link_name == entry_stem:lower() then
        return true
      end
    end
    return false
  end
```

The `get_section_outlinks()` function reads the source file (once, cached per query evaluation), extracts outlinks only from lines within the specified heading section:

```lua
--- Cache: source_rel -> heading -> outlinks[]
local _section_outlinks_cache = {}

--- Get outlinks from a specific heading section of a note.
--- Reads the file from disk and extracts links only from the heading section.
---@param entry table VaultIndexEntry
---@param heading string heading text to scope to
---@param index table VaultIndex instance
---@return table[] outlinks within the section
local function get_section_outlinks(entry, heading, index)
  local cache_key = entry.rel_path .. "#" .. heading
  if _section_outlinks_cache[cache_key] then
    return _section_outlinks_cache[cache_key]
  end

  local section_lines = link_utils.read_heading_section(entry.abs_path, heading)
  if #section_lines == 0 then
    _section_outlinks_cache[cache_key] = {}
    return {}
  end

  -- Extract wikilinks from section lines
  local links = {}
  for _, line in ipairs(section_lines) do
    for inner in line:gmatch("%[%[([^%]]+)%]%]") do
      local parsed = link_utils.parse_target(inner)
      if parsed.name ~= "" then
        links[#links + 1] = {
          path = parsed.name .. (parsed.heading and "#" .. parsed.heading or "")
            .. (parsed.block_id and "^" .. parsed.block_id or ""),
          display = parsed.alias or parsed.name,
          embed = false,
        }
      end
    end
    -- Also check for embeds
    for inner in line:gmatch("!%[%[([^%]]+)%]%]") do
      local parsed = link_utils.parse_target(inner)
      if parsed.name ~= "" then
        links[#links + 1] = {
          path = parsed.name,
          display = parsed.alias or parsed.name,
          embed = true,
        }
      end
    end
  end

  _section_outlinks_cache[cache_key] = links
  return links
end
```

The cache is cleared at the start of each `evaluate()` call to avoid stale data across queries.

### Completion Changes: `search.lua`

Update the `links-to:` and `linked-from:` completion to suggest `NoteName#Heading` when a note name has been entered:

```lua
-- After links-to:NoteName# suggest headings
if lead:match("^links%-to:.+#") then
  local note_name = lead:match("^links%-to:(.+)#")
  -- Strip quotes if present
  note_name = note_name:gsub('^"', ""):gsub('"$', "")
  local idx = vault_index.current()
  if idx then
    local abs_paths = idx:resolve_name(note_name)
    if abs_paths and #abs_paths > 0 then
      local entry = idx:get_entry_by_abs(abs_paths[1])
      if entry and entry.headings then
        local prefix = lead:match("^(links%-to:.+#)")
        for _, h in ipairs(entry.headings) do
          candidates[#candidates + 1] = prefix .. h.text
        end
      end
    end
  end
end
```

### Help Text Update

Add to the "Link Filters" section in `search_help()`:

```
Link Filters:
  links-to:NoteName          Notes linking to NoteName
  links-to:Note#Heading      Notes linking to specific heading
  linked-from:NoteName       Notes that NoteName links to
  linked-from:Note#Heading   Notes linked from a specific section
```

### Edge Cases

1. **Same-file heading references**: `links-to:#Heading` (empty note name) is not meaningful for cross-file search -- it would mean "find notes that have a self-reference `[[#Heading]]`". Not supported initially; return false.
2. **Multiple headings with same slug**: If a note has duplicate heading slugs, all occurrences match. This is consistent with `heading_to_slug()` behavior elsewhere.
3. **Heading containing `#`**: Headings like `C# Programming` have slugs `c-programming`; the `#` in the heading text is stripped by `heading_to_slug()`. Users would write `links-to:"Note#C# Programming"` and the parser would take the first `#` as the separator. This is a known limitation -- heading text after the first `#` in the filter value is the heading name. The workaround is to use the slug directly: `links-to:"Note#c-programming"` (not supported yet, but could be added).
4. **Performance**: For `links-to:Note#Heading`, iterating the candidate's outlinks (typically 5-50 per note) is fast. For `linked-from:Note#Heading`, reading one file from disk per query is acceptable since the source note is fixed.

### Estimated Line Counts

| File | Lines | Action |
|------|-------|--------|
| `lua/andrew/vault/search_filter.lua` | ~100 | Modify (update `links-to:` and `linked-from:` handlers, add `parse_link_target()`, `get_section_outlinks()`) |
| `lua/andrew/vault/search.lua` | ~30 | Modify (heading completion for `links-to:NoteName#`, help text update) |
| `lua/andrew/vault/slug.lua` | 0 | No change (already provides `heading_to_slug()`) |

---

## Sub-Feature 3: Inverse Tag Matching

### Problem

The current `tag:project` filter matches any note with a tag that starts with `project` (including `project/archived`, `project/template`, `project/active`). This is the correct hierarchical matching behavior. But there is no way to exclude specific subtrees.

Users must write:
```
tag:project AND -tag:project/archived AND -tag:project/template
```

The proposed syntax:
```
tag:project,-archived,-template
```

### Tokenizer Changes: `search_query.lua`

No tokenizer changes required. The value `project,-archived,-template` is parsed as a single field value string by `parse_field_value()`, which returns:

```lua
op = "=", value = "project,-archived,-template"
```

The comma-separated parsing happens in the filter evaluation, not the tokenizer.

### Filter Changes: `search_filter.lua`

Modify the `tag` handler in `match_field()`:

```lua
  -- ── tag ──
  if name == "tag" then
    if op ~= "=" then return false end
    -- Parse comma-separated include/exclude list
    local includes, excludes = parse_tag_filter(filter_val)
    return match_tag_filter(entry.tags, includes, excludes)
  end
```

### Helper: Parse Tag Filter

```lua
--- Parse a tag filter value into include and exclude lists.
--- "project,-archived,-template" -> { "project" }, { "archived", "template" }
--- "project" -> { "project" }, {}
--- "-archived" -> {}, { "archived" }
---@param value string comma-separated tag filter
---@return string[] includes, string[] excludes
local function parse_tag_filter(value)
  local includes = {}
  local excludes = {}

  for part in value:gmatch("[^,]+") do
    part = vim.trim(part)
    if part:sub(1, 1) == "-" then
      local tag = part:sub(2)
      if tag ~= "" then
        excludes[#excludes + 1] = tag
      end
    else
      if part ~= "" then
        includes[#includes + 1] = part
      end
    end
  end

  return includes, excludes
end
```

### Helper: Match Tag Filter

```lua
--- Match an entry's tags against include/exclude lists.
--- An entry matches if ANY include tag matches (hierarchical) AND
--- NO exclude tag matches (hierarchical).
---
--- Hierarchical matching: tag "project" matches entry tag "project/active".
--- Exclude "-archived" excludes "archived" and "archived/old".
---
---@param entry_tags string[] tags from the vault index entry
---@param includes string[] tags that must match (at least one)
---@param excludes string[] tags that must NOT match (none)
---@return boolean
local function match_tag_filter(entry_tags, includes, excludes)
  if not entry_tags or #entry_tags == 0 then return false end

  -- If no includes specified (only excludes), match all entries with tags
  local include_matched = #includes == 0

  for _, entry_tag in ipairs(entry_tags) do
    -- Check excludes first (any exclude match -> reject)
    for _, excl in ipairs(excludes) do
      if vault_index.tag_matches({ entry_tag }, excl, { case_insensitive = true }) then
        return false
      end
    end

    -- Check includes (any include match -> accept)
    if not include_matched then
      for _, incl in ipairs(includes) do
        if vault_index.tag_matches({ entry_tag }, incl, { case_insensitive = true }) then
          include_matched = true
        end
      end
    end
  end

  return include_matched
end
```

### Interaction with Existing tag_matches()

`vault_index.tag_matches(tags, pattern, opts)` already handles hierarchical matching: `tag_matches({"project/active"}, "project")` returns true. The exclude logic reuses this function, so `-project/archived` correctly excludes both `project/archived` and `project/archived/old`.

### Contextual Semantics

The exclude prefix `-` has different meaning depending on context:
- At the query level, `-tag:project` means "NOT tag:project" (negate entire tag filter).
- Inside the tag value, `tag:project,-archived` means "tag matches project hierarchy BUT NOT archived subtree."

These are complementary, not conflicting. `-tag:project,-archived` means "NOT (project excluding archived)" which would be: notes that either have no project tag at all, or have an archived project tag.

### Completion Changes: `search.lua`

When completing `tag:project,` show subtags of `project` prefixed with `-`:

```lua
-- After tag: with comma, suggest exclusions
if lead:match("^tag:.+,%-?$") then
  local base_tag = lead:match("^tag:([^,]+)")
  local prefix = lead -- keep current input as prefix
  local idx = vault_index.current()
  if idx then
    local all_tags = idx:all_tags()
    for _, t in ipairs(all_tags) do
      if t:sub(1, #base_tag + 1) == base_tag .. "/" then
        candidates[#candidates + 1] = "tag:" .. base_tag .. ",-" .. t
      end
    end
  end
end
```

### Help Text Update

```
Tag Filters:
  tag:project                 Notes with project or project/* tags
  tag:project,-archived       Exclude archived subtree
  tag:project,-archived,-old  Multiple exclusions
```

### Edge Cases

1. **Exclude without include**: `tag:-archived` means "all notes with tags, excluding those with archived tags." The `#includes == 0` check handles this.
2. **Empty parts**: `tag:project,,,-archived` -- empty parts between commas are skipped by `vim.trim()` check.
3. **Overlapping include/exclude**: `tag:project,-project` -- includes project but excludes project. The exclude takes priority (checked per-tag first), so this returns false for any entry with a project tag.
4. **Backward compatibility**: Existing `tag:project` queries (no commas) continue to work identically since `parse_tag_filter("project")` returns `{ "project" }, {}`.

### Estimated Line Counts

| File | Lines | Action |
|------|-------|--------|
| `lua/andrew/vault/search_filter.lua` | ~60 | Modify (replace `tag` handler, add `parse_tag_filter()`, `match_tag_filter()`) |
| `lua/andrew/vault/search.lua` | ~20 | Modify (completion for exclusion syntax, help text) |

---

## Sub-Feature 4: Unlinked Mention Auto-Linking Batch Mode

### Architecture

The existing `unlinked.lua` has all the primitives:
- `all_note_names()` collects all vault names and aliases
- `build_rg_pattern()` creates PCRE2 alternation patterns
- `rg_search()` runs ripgrep with word boundary matching
- `filter_results()` applies Lua post-filters (frontmatter, code blocks, headings, existing links, URLs)
- `wrap_in_wikilink()` performs the buffer/file edit with smart `[[name]]` vs `[[target|display]]` selection

What is missing:

1. **Buffer-scoped batch mode**: Scan the current buffer (in-memory, no ripgrep needed), show all matches in a review UI, and bulk-apply.
2. **Vault-wide batch mode with review**: The existing `vault_unlinked_mentions()` shows results in fzf but applies one at a time. A batch mode would allow "accept all" after review.
3. **Buffer-local scanning without ripgrep**: For the current buffer, use in-memory matching (like `autolink.lua` does) instead of ripgrep for instant results.

### New Functions in `unlinked.lua`

No new module needed. Extend `unlinked.lua` with batch operations.

### Data Flow: Buffer Batch Mode

```
:VaultAutoLink (buffer)
  |
  v
ensure autolink index is current
  |
  v
scan_buffer_mentions(bufnr)
  |-- Read buffer lines
  |-- For each line, check multi-word names (longest first), then single-word names
  |-- Apply exclusion filters: frontmatter, code blocks, headings, existing links, URLs
  |-- Return match[] = { row, start_col, end_col, text, note_name }
  |
  v
Show fzf-lua picker: "L42:15  'Finite Element' -> [[Finite Element Method]]"
  |-- Enter: jump to location
  |-- Ctrl-w: wrap selected matches in wikilinks
  |-- Ctrl-a: wrap ALL matches
  |-- Ctrl-d: dismiss (skip) selected matches
  |
  v
apply_batch_wraps(bufnr, accepted_matches[])
  |-- Sort by position descending (bottom-up, right-to-left)
  |-- For each match, replace text with [[...]] or [[target|display]]
```

### Pseudo-Code: Buffer Scan

```lua
--- Scan the current buffer for unlinked mentions of vault note names.
--- Uses in-memory matching (no ripgrep) for instant results.
---@param bufnr number
---@return { row: number, start_col: number, end_col: number, text: string, note_name: string, canonical: string }[]
local function scan_buffer_mentions(bufnr)
  ensure_index()

  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then return {} end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local is_in_code = autolink_build_code_exclusion(bufnr)
  local fm_start, fm_end = get_frontmatter_range(bufnr)
  local self_name = link_utils.get_basename(fname):lower()

  local matches = {}

  for i, line in ipairs(lines) do
    local row = i - 1 -- 0-indexed

    -- Skip frontmatter
    if fm_start and fm_end and row >= fm_start and row <= fm_end then
      goto next_line
    end

    -- Skip heading lines
    if line:match("^#+ ") then goto next_line end

    if #line == 0 then goto next_line end

    local lower_line = line:lower()
    local link_ranges = get_link_ranges(line)
    local matched_positions = {}

    -- Phase 1: Multi-word names (longest first)
    for _, entry in ipairs(multi_word_names) do
      local search_start = 1
      while true do
        local s, e = lower_line:find(entry.lower, search_start, true)
        if not s then break end

        if has_word_boundaries(line, s, e)
          and not overlaps_range(s - 1, e, link_ranges)
          and not is_in_code(row, s - 1)
          and not is_position_taken(matched_positions, s - 1, e)
          and entry.lower ~= self_name
        then
          matches[#matches + 1] = {
            row = row,
            start_col = s - 1,
            end_col = e,
            text = line:sub(s, e),
            note_name = entry.lower,
            canonical = entry.original,
          }
          mark_position(matched_positions, s - 1, e)
        end

        search_start = e + 1
      end
    end

    -- Phase 2: Single-word names (same as autolink.lua pattern)
    -- ... (same word-splitting and hash-lookup logic)

    ::next_line::
  end

  return matches
end
```

### Sharing Code with `autolink.lua`

Both `autolink.lua` and the batch auto-link feature need:
- `build_code_exclusion(bufnr)`
- `get_frontmatter_range(bufnr)`
- `get_link_ranges(line)`
- `has_word_boundaries(line, start_pos, end_pos)`
- Name index management (multi-word sorted, single-word hash)

To avoid duplication, extract shared utilities into either:
- A shared helper file `lua/andrew/vault/link_scan.lua` (~150 lines), or
- Export the relevant functions from `autolink.lua` as `M._` prefixed internals (already partially done: `autolink.lua` does not export these currently).

The cleanest approach is to add a `link_scan.lua` module with shared scanning primitives, then have both `autolink.lua` and `unlinked.lua` require it.

### Vault-Wide Batch Mode

```lua
--- Scan entire vault for unlinked mentions and present in batch review UI.
function M.autolink_vault()
  -- Reuse existing vault_unlinked_mentions() logic with batch apply support
  local all_names = all_note_names()
  -- ... (same batched ripgrep pattern as existing vault_unlinked_mentions)

  -- After collecting all results, present in fzf with batch actions:
  fzf.fzf_exec(entries, {
    prompt = "Auto-link vault (" .. #all_results .. " mentions)> ",
    fzf_opts = { ["--multi"] = "" },
    actions = {
      ["default"] = jump_to_location,
      ["ctrl-w"] = wrap_selected,
      ["ctrl-a"] = function()
        -- Wrap ALL results, sorted by file then line (descending)
        local by_file = group_by_file(all_results)
        local total_wrapped = 0
        for file, file_matches in pairs(by_file) do
          table.sort(file_matches, function(a, b) return a.line > b.line end)
          for _, r in ipairs(file_matches) do
            if wrap_in_wikilink(r.file, r.line, r.match, r.match) then
              total_wrapped = total_wrapped + 1
            end
          end
        end
        vim.notify("Vault: wrapped " .. total_wrapped .. " mention(s)", vim.log.levels.INFO)
      end,
    },
  })
end
```

### Review Buffer Mode (Alternative UI)

For users who want a more deliberate review workflow, offer a scratch buffer showing all proposed changes with accept/reject per line:

```
# Vault Auto-Link Review
# [a] Accept  [x] Reject  [A] Accept All  [q] Quit

Meeting/2026-02-15.md:42
  Before: discussed the Finite Element Method results
  After:  discussed the [[Finite Element Method]] results
  Status: [pending]

Projects/Alpha.md:18
  Before: see the CFD analysis for details
  After:  see the [[Computational Fluid Dynamics|CFD]] analysis for details
  Status: [pending]
```

This is a "nice-to-have" extension; the fzf-based workflow should be the primary interface.

### Config

```lua
-- In config.lua, extend M.autolink:
M.autolink = {
  enabled = false,
  debounce_ms = 300,
  min_name_length = 3,
  exclude_names = {},
  -- Batch mode settings
  batch = {
    -- Skip matches where the matched text case differs significantly from note name
    -- (reduces false positives like "set" matching note "SET")
    case_sensitive_single_word = false,
    -- Minimum word count for vault-wide scan (reduces noise from common words)
    min_words_vault = 1,
  },
}
```

### Commands and Keybindings

| Command | Description | Keybinding |
|---------|-------------|------------|
| `:VaultAutoLink` | Auto-link unlinked mentions in current buffer | `<leader>vaB` |
| `:VaultAutoLinkAll` | Auto-link unlinked mentions vault-wide | `<leader>vaV` |

### Edge Cases

1. **Overlapping matches**: "Finite Element Method" and "Finite Element" -- longest-first matching prevents double-wrapping. After wrapping "Finite Element Method", the shorter match is skipped because its position overlaps.
2. **Already-linked text**: `is_inside_wikilink()` and `get_link_ranges()` prevent wrapping text that is already inside `[[...]]`.
3. **Code blocks**: Both treesitter-based (autolink) and regex-based (unlinked) code block detection prevent linking inside fenced code.
4. **Frontmatter**: YAML frontmatter lines are excluded.
5. **URLs**: Text inside URLs is excluded (e.g., `https://example.com/FiniteElement` should not be linked).
6. **Bottom-up application**: When applying multiple wraps in the same buffer/file, process from the end of the file backward so that earlier edits do not shift the positions of later edits.
7. **Self-mentions**: A note should not suggest linking its own name within itself.
8. **Multi-word alias matching**: If note "Computational Fluid Dynamics" has alias "CFD", both the full name and "CFD" are matched. When wrapping "CFD", the link becomes `[[Computational Fluid Dynamics|CFD]]` if the alias case differs from the note basename.

### Estimated Line Counts

| File | Lines | Action |
|------|-------|--------|
| `lua/andrew/vault/link_scan.lua` | ~150 | Create (shared scanning primitives) |
| `lua/andrew/vault/unlinked.lua` | ~150 | Modify (add `autolink_buffer()`, `autolink_vault()`, new commands/keybindings) |
| `lua/andrew/vault/autolink.lua` | ~-50 | Modify (import shared code from `link_scan.lua`, reduce duplication) |
| `lua/andrew/vault/config.lua` | ~10 | Modify (add `M.autolink.batch` section) |

---

## Integration Points

### Cross-Module Dependencies

```
link_repair.lua
  requires: linkdiag.lua (edit_distance, find_closest, find_closest_headings)
  requires: vault_index.lua (name resolution, basename lookup)
  requires: link_utils.lua (parse_target, heading_to_slug)
  requires: engine.lua (vault_path, read/write file, fzf helpers)

search_filter.lua
  requires: link_utils.lua (heading_to_slug, read_heading_section, parse_target)
  requires: slug.lua (heading_to_slug)
  uses: vault_index outlinks[].path for heading-scoped matching
  uses: vault_index _inlinks for non-heading matching (existing)

link_scan.lua
  requires: engine.lua (vault_path, is_vault_path)
  requires: link_utils.lua (get_basename)
  requires: vault_index.lua (name cache, generation tracking)
  used by: autolink.lua, unlinked.lua

unlinked.lua
  requires: link_scan.lua (shared scanning, exclusion detection)
  requires: engine.lua (fzf helpers)
  requires: wikilinks.lua (resolve_link for smart wrapping)
```

### Vault Index Impact

- **No schema changes** required for sub-features 1, 3, 4.
- **Sub-feature 2** optionally benefits from adding `line` to outlink entries, but this can be deferred. The initial implementation reads files from disk for `linked-from:Note#Heading`.
- All sub-features are read-only consumers of the vault index. No new index fields are written.

### Event Flow

- `link_repair.lua` hooks into `linkdiag.validate()` output (diagnostic namespace).
- `search_filter.lua` changes are transparent to `search.lua` (same `match_field()` interface).
- `link_scan.lua` responds to `VaultCacheInvalidate` user event for index freshness.
- Buffer auto-link hooks into `BufWritePost` for automatic re-scan after saves.

---

## Files to Create/Modify Summary

| File | Action | Sub-feature | Est. Lines |
|------|--------|-------------|------------|
| `lua/andrew/vault/link_repair.lua` | **Create** | 1 | ~300 |
| `lua/andrew/vault/link_scan.lua` | **Create** | 4 | ~150 |
| `lua/andrew/vault/linkdiag.lua` | **Modify** | 1 | ~10 (export internals) |
| `lua/andrew/vault/search_filter.lua` | **Modify** | 2, 3 | ~160 |
| `lua/andrew/vault/search.lua` | **Modify** | 2, 3 | ~50 |
| `lua/andrew/vault/unlinked.lua` | **Modify** | 4 | ~150 |
| `lua/andrew/vault/autolink.lua` | **Modify** | 4 | ~-50 (dedup) |
| `lua/andrew/vault/config.lua` | **Modify** | 1, 4 | ~20 |

**Total new code**: ~450 lines (2 new files)
**Total modified code**: ~340 net lines across 6 existing files

---

## Implementation Order

Recommended implementation sequence based on dependencies and complexity:

1. **Sub-feature 3: Inverse Tag Matching** (~80 lines total)
   - Smallest change, self-contained in `search_filter.lua` + `search.lua`
   - No new modules
   - Immediately useful for day-to-day search

2. **Sub-feature 2: Backlink-Specific Search** (~130 lines total)
   - Extends existing `links-to:` / `linked-from:` handlers
   - `parse_link_target()` helper is reusable
   - `get_section_outlinks()` is the main new complexity

3. **Sub-feature 1: Link Repair** (~310 lines total)
   - New module `link_repair.lua` with batch workflow
   - Depends on `linkdiag.lua` internals (expose a few functions)
   - Vault-wide mode is the most complex part

4. **Sub-feature 4: Batch Auto-Linking** (~300 lines total)
   - New shared module `link_scan.lua` + extensions to `unlinked.lua`
   - Touches `autolink.lua` for deduplication
   - Largest refactoring scope

---

## Testing Plan

### Sub-Feature 1: Link Repair

| Test | Steps | Expected |
|------|-------|----------|
| Buffer repair (interactive) | Create `[[Alph]]` in a note where `Alpha` exists. Run `:VaultLinkRepair`. | Picker shows `Alpha (dist=1)`. Selecting it replaces `[[Alph]]` with `[[Alpha]]`. |
| Auto-fix | Create `[[Alphha]]` (dist=2, above threshold) and `[[Alph]]` (dist=1). Run `:VaultLinkRepair!`. | Only `[[Alph]]` is auto-fixed. `[[Alphha]]` remains broken. |
| Heading repair | Create `[[Alpha#Gols]]` where `Alpha` has heading `Goals`. Run `:VaultLinkRepair`. | Suggests `#Goals (dist=1)`. |
| Moved file | Rename `Projects/Note.md` to `Archive/Note.md`. Keep `[[Projects/Note]]` link. Run `:VaultLinkRepair`. | Suggests `Note` (basename match, dist=0). |
| Vault-wide | Introduce 3 broken links across 2 files. Run `:VaultLinkRepairAll`. | All 3 shown in fzf. `Ctrl-a` fixes all auto-fixable ones. |

### Sub-Feature 2: Heading-Scoped Backlinks

| Test | Steps | Expected |
|------|-------|----------|
| Basic heading filter | Note A has `[[B#Goals]]`, Note C has `[[B#Budget]]`. Run `links-to:B#Goals`. | Only Note A in results. |
| Case insensitive | `links-to:B#goals` (lowercase). | Same result as `links-to:B#Goals`. |
| No heading (backward compat) | `links-to:B` with no heading. | Both A and C in results (existing behavior). |
| linked-from with heading | Note B has `# Goals` section with `[[D]]` and `[[E]]`. Run `linked-from:B#Goals`. | D and E in results, but not notes linked from other sections of B. |
| Completion | Type `links-to:B#` and press Tab. | Headings of note B suggested. |

### Sub-Feature 3: Inverse Tags

| Test | Steps | Expected |
|------|-------|----------|
| Basic exclusion | `tag:project,-archived` | Notes with `project/*` tags except those with `project/archived` or `project/archived/*`. |
| Multiple exclusions | `tag:project,-archived,-template` | Excludes both subtrees. |
| Exclude only | `tag:-archived` | All notes with tags, excluding those with `archived` tags. |
| Backward compat | `tag:project` (no commas) | Same behavior as before. |
| Overlapping | `tag:project,-project` | Returns false for all entries (exclude overrides include). |

### Sub-Feature 4: Batch Auto-Linking

| Test | Steps | Expected |
|------|-------|----------|
| Buffer scan | Open a note mentioning "Finite Element Method" (unwrapped). Run `:VaultAutoLink`. | Picker shows the mention with proposed link. |
| Accept single | Select one mention, press `Ctrl-w`. | Text wrapped in `[[Finite Element Method]]`. |
| Accept all | Press `Ctrl-a` in picker. | All mentions wrapped. |
| Skip code blocks | Mention inside `` `code` `` or fenced code. | Not included in suggestions. |
| Skip frontmatter | Mention in YAML frontmatter. | Not included. |
| Skip existing links | `[[Finite Element Method]]` already linked. | Not suggested again. |
| Alias wrapping | Note "CFD Simulation" has alias "CFD". Buffer text "CFD". | Wrapped as `[[CFD Simulation\|CFD]]`. |
| Vault-wide | Run `:VaultAutoLinkAll`. | All vault mentions shown. `Ctrl-a` wraps all. |
