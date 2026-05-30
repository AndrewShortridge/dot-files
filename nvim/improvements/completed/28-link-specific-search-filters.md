# 28 -- Link-Specific Search Filters

**Priority:** High (core navigation capability)
**Status:** Implemented (documenting current state for reference)
**Original Design:** `improvements/completed/02-link-specific-search-filters.md`

## Summary

Three metadata search operators -- `links-to:`, `linked-from:`, and `alias:` -- allow users to query link relationships and alias metadata directly from the advanced search prompt. These operators are evaluated entirely against the in-memory vault index (no ripgrep involvement) and support heading-qualified targets (e.g., `links-to:Note#Heading`) for fine-grained link scoping.

### Query Examples

```
links-to:Dashboard               Notes that link TO "Dashboard"
links-to:"Project Alpha"         Quoted name with spaces
links-to:Note#Decisions          Notes linking to the #Decisions heading of Note
linked-from:Dashboard            Notes that Dashboard links TO
linked-from:Meeting#Action-Items Notes linked from a specific section
alias:CFD                        Notes with "CFD" as a frontmatter alias
links-to:Alpha AND tag:active    Combine with other metadata filters
links-to:Alpha deploy            Combine with text search (metadata-then-text pipeline)
-links-to:Archive                Negation: notes NOT linking to Archive
```

---

## Current State Analysis

### Files Involved

| File | Role |
|------|------|
| `lua/andrew/vault/search_query.lua` | Tokenizer and recursive descent parser. No changes needed -- field tokenization already handles hyphenated names (`links-to`, `linked-from`) via the identifier pattern `^[a-z][a-z0-9_-]*$` at line 178. Quoted values (`"Project Alpha"`) handled by quote-stripping at lines 124-126. |
| `lua/andrew/vault/search_filter.lua` | Filter evaluation. Contains `resolve_note_to_rel_path()`, `parse_link_target()`, `get_section_outlinks()`, and the `links-to` / `linked-from` / `alias` branches inside `match_field()`. |
| `lua/andrew/vault/search.lua` | UI layer. Contains Tab completion for all three operators plus heading completion after `#`, and help text in `search_help()`. |
| `lua/andrew/vault/config.lua` | `M.search.builtin_fields` includes `"links-to"`, `"linked-from"`, `"alias"`. |
| `lua/andrew/vault/vault_index.lua` | Provides `outlinks`, `_inlinks`, `resolve_name()`, `get_inlinks()`. No changes needed. |

### Vault Index Data Structures

**Outlinks** (per entry, stored in `entry.outlinks`):
```lua
-- Array of link objects extracted by extract_links() during indexing
{ path = "Projects/Alpha", display = "Alpha", embed = false }
{ path = "Meeting Notes#Decisions", display = "Meeting Notes", embed = false }
{ path = "diagram.png", display = "diagram.png", embed = true }
```

The `path` field is the raw wikilink target (before resolution), possibly including `#heading` or `^blockid` suffixes. The `embed` field distinguishes `![[...]]` from `[[...]]`.

**Inlinks** (derived, computed by `_recompute_inlinks()` in vault_index.lua):
```lua
-- self._inlinks[target_rel_path] is an array of:
{ path = "Projects/Alpha",  -- source rel_path WITHOUT .md extension
  display = "Alpha",        -- source basename
  embed = false }
```

Inlinks strip heading/blockid anchors during resolution (line 1015: `raw = raw:match("^([^#^]+)") or raw`), so the inlinks table records only note-level relationships. Heading-qualified queries must use a different path (section outlink scanning).

**Name resolution** (`resolve_name()` at vault_index.lua line 1403):
```lua
-- Resolves "Alpha" -> { "/vault/Projects/Alpha.md" } via:
-- 1. _name_index[lower] (basename match)
-- 2. _alias_index[lower] (frontmatter alias match)
```

**Aliases** (per entry, stored in `entry.aliases`):
```lua
-- Array of lowercase strings from frontmatter:
-- aliases: [CFD, "Computational Fluid Dynamics"]
-- -> { "cfd", "computational fluid dynamics" }
```

---

## Detailed Implementation

### 1. Tokenizer (search_query.lua) -- No Changes Required

The tokenizer already handles all three field prefixes correctly. When it encounters `links-to:NoteName`:

1. The word `links-to:NoteName` is read as a single unquoted word (lines 273-286).
2. It contains a colon, so `parse_field_token()` is called (line 298).
3. `name = "links-to"` passes the identifier check `^[a-z][a-z0-9_-]*$` (line 178) since hyphens are allowed.
4. `raw_value = "NoteName"` is extracted after the colon.
5. `parse_field_value("NoteName")` returns `op = "=", value = "NoteName"` (line 106).
6. A `TK.FIELD` token is produced with `{ name = "links-to", op = "=", value = "NoteName" }`.

For quoted values like `links-to:"Project Alpha"`:
- The tokenizer detects the opening quote inside a word (line 278) and consumes through the closing quote.
- `parse_field_token()` strips surrounding quotes (lines 124-126).
- The FIELD token has `value = "Project Alpha"`.

For heading-qualified values like `links-to:Note#Heading`:
- `Note#Heading` does not contain a `//` prefix, so URL detection does not trigger.
- `parse_field_value("Note#Heading")` returns `op = "=", value = "Note#Heading"` since `#` is not an operator character.
- The `#` splitting happens later in `match_field()` via `parse_link_target()`.

### 2. Parser (search_query.lua) -- No Changes Required

The parser produces a standard `field` AST node:
```lua
{
  type   = "field",
  name   = "links-to",
  op     = "=",
  value  = "Note#Heading",
  value2 = nil,
}
```

This node is classified as `METADATA_TYPES["field"] = true` by the filter pipeline, so it participates in the metadata-only evaluation path.

### 3. Filter Evaluation (search_filter.lua)

#### 3a. Helper: `resolve_note_to_rel_path()`

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` (lines 201-234)

Resolves a human-readable note name to a vault-relative path using the index. Used by both `links-to:` and `linked-from:`.

```lua
--- Resolve a note name to its rel_path via the vault index.
--- Tries resolve_name() first (basename + alias), then falls back to
--- direct rel_path lookup (for path-style values like "Projects/Alpha").
---@param name string note name or path to resolve
---@param index table VaultIndex instance
---@return string|nil rel_path of the resolved note, or nil
local function resolve_note_to_rel_path(name, index)
  if not index or not name or name == "" then return nil end

  -- Try resolve_name (handles basenames and aliases)
  local abs_paths = index:resolve_name(name)
  if abs_paths and #abs_paths > 0 then
    local prefix = index.vault_path .. "/"
    local abs = abs_paths[1]
    if abs:sub(1, #prefix) == prefix then
      return abs:sub(#prefix + 1)
    end
  end

  -- Fallback: try as a direct rel_path (with or without .md)
  local rel = name
  if not rel:match("%.md$") then
    rel = rel .. ".md"
  end
  if index.files[rel] then return rel end

  -- Case-insensitive rel_path search
  local lower = rel:lower()
  for rp in pairs(index.files) do
    if rp:lower() == lower then return rp end
  end

  return nil
end
```

Resolution priority:
1. `_name_index` (basename match, O(1) via hash)
2. `_alias_index` (alias match, O(1) via hash)
3. Direct `rel_path` lookup (exact, then `.md` appended)
4. Case-insensitive `rel_path` scan (O(N) fallback)

#### 3b. Helper: `parse_link_target()`

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` (lines 236-248)

Splits a link filter value into a note name and optional heading.

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

#### 3c. Helper: `get_section_outlinks()`

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` (lines 258-310)

When a heading is specified (e.g., `links-to:Note#Decisions`), the filter needs to check whether the candidate note's outlinks specifically target `Note#Decisions`. Since the index stores outlinks at the note level (not per-heading), this function reads the source file from disk and extracts links only from the specified heading section.

```lua
--- Cache: source_rel -> heading -> outlinks[] (cleared per evaluate() call)
local _section_outlinks_cache = {}

--- Clear the section outlinks cache (call at start of evaluate()).
local function clear_section_outlinks_cache()
  _section_outlinks_cache = {}
end

--- Get outlinks from a specific heading section of a note.
--- Reads the file from disk and extracts links only from the heading section.
---@param entry table VaultIndexEntry
---@param heading string heading text to scope to
---@return table[] outlinks within the section
local function get_section_outlinks(entry, heading)
  local cache_key = entry.rel_path .. "#" .. heading
  if _section_outlinks_cache[cache_key] then
    return _section_outlinks_cache[cache_key]
  end

  local link_utils = require("andrew.vault.link_utils")
  local section_lines = link_utils.read_heading_section(entry.abs_path, heading)
  if #section_lines == 0 then
    _section_outlinks_cache[cache_key] = {}
    return {}
  end

  local links = {}
  for _, line in ipairs(section_lines) do
    -- Track embed positions to avoid double-matching with wikilink pass
    local embed_positions = {}
    for s_pos in line:gmatch("()!%[%[") do
      embed_positions[s_pos] = true
    end

    -- Check for embeds
    for inner in line:gmatch("!%[%[([^%]]+)%]%]") do
      local parsed = link_utils.parse_target(inner)
      if parsed.name ~= "" then
        links[#links + 1] = {
          path = parsed.name .. (parsed.heading and "#" .. parsed.heading or "")
            .. (parsed.block_id and "^" .. parsed.block_id or ""),
        }
      end
    end
    -- Regular wikilinks (skip ones preceded by ! which are embeds)
    for s_pos, inner in line:gmatch("()%[%[([^%]]+)%]%]") do
      if not embed_positions[s_pos - 1] then
        local parsed = link_utils.parse_target(inner)
        if parsed.name ~= "" then
          links[#links + 1] = {
            path = parsed.name .. (parsed.heading and "#" .. parsed.heading or "")
              .. (parsed.block_id and "^" .. parsed.block_id or ""),
          }
        end
      end
    end
  end

  _section_outlinks_cache[cache_key] = links
  return links
end
```

Key design decisions:
- Results are cached per `evaluate()` call (`_section_outlinks_cache` is cleared at the start of each `evaluate()`).
- Uses `link_utils.read_heading_section()` and `link_utils.parse_target()` for consistent link parsing with the rest of the vault.
- Handles both embeds (`![[...]]`) and regular wikilinks (`[[...]]`).
- Deduplicates embed vs. wikilink matches via `embed_positions` tracking.

#### 3d. `match_field()` -- `links-to:` Handler

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` (lines 427-475)

The `links-to:NoteName` handler checks whether the current entry contains an outlink to the target note. When no heading is specified, it uses the pre-computed `_inlinks` table for O(K) lookup. When a heading is specified, it scans the entry's outlinks for heading-qualified matches.

```lua
  -- ── links-to ──
  if name == "links-to" then
    if op ~= "=" then return false end
    if not index then return false end

    local target_name, target_heading = parse_link_target(filter_val)

    -- Empty note name with heading (e.g., "#Heading") is not meaningful for cross-file search
    if target_name == "" then return false end

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
    local slug_mod = require("andrew.vault.slug")
    local target_heading_slug = slug_mod.heading_to_slug(target_heading)
    local target_stem = target_rel:gsub("%.md$", "")

    for _, link in ipairs(entry.outlinks or {}) do
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

**Two code paths:**

1. **Without heading** (`links-to:NoteName`): Resolves NoteName to `target_rel`, looks up `_inlinks[target_rel]`, checks if the current entry's stem is among the inlink sources. This is O(K) where K is the number of inlinks to the target note.

2. **With heading** (`links-to:Note#Heading`): Iterates the current entry's outlinks, checking each for a match against both the target note name AND the target heading (using slug comparison via `heading_to_slug()` for case-insensitive, normalized matching). This is O(L) where L is the number of outlinks in the current entry.

#### 3e. `match_field()` -- `linked-from:` Handler

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` (lines 477-517)

The `linked-from:NoteName` handler checks whether the source note contains an outlink to the current entry. Semantically: "find notes that NoteName links to."

```lua
  -- ── linked-from ──
  if name == "linked-from" then
    if op ~= "=" then return false end
    if not index then return false end

    local source_name, source_heading = parse_link_target(filter_val)
    if source_name == "" then return false end

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

    local section_outlinks = get_section_outlinks(source_entry, source_heading)
    local entry_stem = entry.rel_path:gsub("%.md$", "")
    local entry_basename_lower = entry.basename_lower or entry.basename:lower()

    for _, link in ipairs(section_outlinks) do
      local raw = link.path or ""
      local link_name = raw:match("^([^#^]+)") or raw
      link_name = vim.trim(link_name):lower()
      if link_name == entry_basename_lower or link_name == entry_stem:lower() then
        return true
      end
    end
    return false
  end
```

**Two code paths:**

1. **Without heading** (`linked-from:NoteName`): Resolves NoteName to `source_rel`, looks up `_inlinks[entry.rel_path]`, checks if the source note's stem is among the inlink sources. O(K) per candidate entry.

2. **With heading** (`linked-from:Note#Section`): Resolves the source note, reads the specific heading section from disk via `get_section_outlinks()`, and checks whether any of the section's outlinks resolve to the current entry. The section outlinks are cached per evaluate() call to avoid repeated disk reads.

#### 3f. `match_field()` -- `alias:` Handler

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` (lines 519-530)

```lua
  -- ── alias ──
  if name == "alias" then
    if op ~= "=" then return false end
    if not entry.aliases or #entry.aliases == 0 then return false end
    local lower_val = filter_val:lower()
    for _, a in ipairs(entry.aliases) do
      if a == lower_val then
        return true
      end
    end
    return false
  end
```

Aliases are stored as lowercase strings in the index, so the comparison lowercases the filter value and does direct equality. O(A) per entry where A is the alias count (typically 1-2).

#### 3g. `field_exists()` -- Alias Existence Check

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` (lines 194-196)

When a user types `alias:` with no value, the `field_exists()` handler provides existence semantics:

```lua
  elseif name == "alias" then
    return entry.aliases ~= nil and #entry.aliases > 0
```

For `links-to:` and `linked-from:` with no value, existence semantics are ambiguous (does "links-to exists" mean "has outlinks"?), so these fall through to the generic handler which returns false. Users should use `has:outlinks` / `has:inlinks` instead.

#### 3h. `match_field()` Receives `index` Parameter

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` (line 376)

The function signature includes `index`:
```lua
local function match_field(node, entry, index)
```

And `match_entry()` passes it through (line 1288):
```lua
  if t == "field" then
    return match_field(ast, entry, index)
  end
```

#### 3i. `evaluate()` Clears Section Outlinks Cache

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` (line 1328)

```lua
function M.evaluate(ast, index, graph_sets)
  clear_section_outlinks_cache()
  -- ...
end
```

The section outlinks cache is cleared at the start of each `evaluate()` call. This ensures heading-qualified queries do not use stale data across separate search invocations, while still benefiting from caching within a single evaluation pass (where the same heading section may be read for multiple candidate entries).

### 4. Config (config.lua)

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/config.lua` (lines 395-399)

```lua
  builtin_fields = {
    "type", "tag", "path", "file", "folder", "status",
    "created", "modified", "day", "priority",
    "links-to", "linked-from", "alias",
  },
```

These names appear in Tab completion when the user starts typing a field prefix in the search prompt.

### 5. Completion Support (search.lua)

#### 5a. Note Name Completion for `links-to:` and `linked-from:`

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search.lua` (lines 1034-1053)

```lua
  -- After links-to: or linked-from: suggest note names from index
  for _, link_prefix in ipairs({ "links-to:", "linked-from:" }) do
    local pat = "^" .. link_prefix:gsub("%-", "%%-")
    if lead:match(pat) then
      local rest = lead:sub(#link_prefix + 1):lower()
      local idx = vault_index.current()
      if idx and idx:is_ready() then
        for _, entry in pairs(idx.files) do
          local name = entry.basename
          if name:lower():sub(1, #rest) == rest then
            if name:find(" ") then
              candidates[#candidates + 1] = link_prefix .. '"' .. name .. '"'
            else
              candidates[#candidates + 1] = link_prefix .. name
            end
          end
        end
      end
    end
  end
```

Note names containing spaces are automatically quoted.

#### 5b. Heading Completion After `#`

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search.lua` (lines 1055-1078)

```lua
  -- After links-to:NoteName# or linked-from:NoteName# suggest headings
  for _, link_prefix in ipairs({ "links-to:", "linked-from:" }) do
    local pat = "^" .. link_prefix:gsub("%-", "%%-") .. ".+#"
    if lead:match(pat) then
      local note_name = lead:match("^" .. link_prefix:gsub("%-", "%%-") .. "(.+)#")
      if note_name then
        -- Strip quotes if present
        note_name = note_name:gsub('^"', ""):gsub('"$', "")
        local idx = vault_index.current()
        if idx and idx:is_ready() then
          local abs_paths = idx:resolve_name(note_name)
          if abs_paths and #abs_paths > 0 then
            local heading_entry = idx:get_entry_by_abs(abs_paths[1])
            if heading_entry and heading_entry.headings then
              local prefix_str = lead:match("^(.-#)")
              for _, h in ipairs(heading_entry.headings) do
                candidates[#candidates + 1] = prefix_str .. h.text
              end
            end
          end
        end
      end
    end
  end
```

When the user types `links-to:NoteName#`, Tab completion resolves NoteName via the index and offers all headings from that note as completion candidates.

#### 5c. Alias Completion

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search.lua` (lines 1080-1102)

```lua
  -- After alias: suggest known aliases from index
  if lead:match("^alias:") then
    local prefix = "alias:"
    local rest = lead:sub(#prefix + 1):lower()
    local idx = vault_index.current()
    if idx and idx:is_ready() then
      local seen = {}
      for _, entry in pairs(idx.files) do
        if entry.aliases then
          for _, a in ipairs(entry.aliases) do
            if not seen[a] and a:sub(1, #rest) == rest then
              seen[a] = true
              if a:find(" ") then
                candidates[#candidates + 1] = prefix .. '"' .. a .. '"'
              else
                candidates[#candidates + 1] = prefix .. a
              end
            end
          end
        end
      end
    end
  end
```

Deduplicates aliases via a `seen` set (multiple notes may share an alias if there are collisions).

### 6. Help Text (search.lua)

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search.lua` (lines 826-832)

The "Link Filters" section in `search_help()`:

```lua
    "Link Filters:",
    "  links-to:NoteName        Notes linking to NoteName",
    "  links-to:Note#Heading    Notes linking to specific heading",
    '  links-to:"Project Alpha" Quote names with spaces',
    "  linked-from:NoteName     Notes that NoteName links to",
    "  linked-from:Note#Heading Notes linked from a section",
    "  alias:CFD                Notes with specific alias",
```

---

## Before/After Code for Each Modified Function

### `match_field()` -- Signature Change

**Before** (original, no index parameter):
```lua
local function match_field(node, entry)
  local name = node.name
  -- ...field handlers that don't need index...
end
```

**After** (with index parameter, plus new handlers):
```lua
--- Match a field AST node against an entry.
---@param node table field AST node { name, op, value, value2 }
---@param entry table VaultIndexEntry
---@param index table|nil VaultIndex instance (needed for links-to/linked-from)
---@return boolean
local function match_field(node, entry, index)
  local name = node.name
  local op = node.op
  local filter_val = node.value
  local filter_val2 = node.value2
  -- ...existing handlers for type, tag, path, file, folder...

  -- ── links-to ──
  if name == "links-to" then
    -- [full handler as shown in section 3d above]
  end

  -- ── linked-from ──
  if name == "linked-from" then
    -- [full handler as shown in section 3e above]
  end

  -- ── alias ──
  if name == "alias" then
    -- [full handler as shown in section 3f above]
  end

  -- ...existing handlers for status, priority, created, modified, day...
end
```

### `match_entry()` -- Threading Index to `match_field()`

**Before:**
```lua
  if t == "field" then
    return match_field(ast, entry)
  end
```

**After:**
```lua
  if t == "field" then
    return match_field(ast, entry, index)
  end
```

### `field_exists()` -- Alias Existence

**Before** (no alias case):
```lua
  elseif name == "day" then
    return entry.day ~= nil
  else
    return get_generic_field(entry, name) ~= nil
  end
```

**After:**
```lua
  elseif name == "day" then
    return entry.day ~= nil
  elseif name == "alias" then
    return entry.aliases ~= nil and #entry.aliases > 0
  else
    return get_generic_field(entry, name) ~= nil
  end
```

### `config.lua` -- `builtin_fields`

**Before:**
```lua
  builtin_fields = {
    "type", "tag", "path", "file", "folder", "status",
    "created", "modified", "day", "priority",
  },
```

**After:**
```lua
  builtin_fields = {
    "type", "tag", "path", "file", "folder", "status",
    "created", "modified", "day", "priority",
    "links-to", "linked-from", "alias",
  },
```

### `evaluate()` -- Cache Clearing

**Before:**
```lua
function M.evaluate(ast, index, graph_sets)
  local matches = {}
  -- ...
end
```

**After:**
```lua
function M.evaluate(ast, index, graph_sets)
  clear_section_outlinks_cache()
  local matches = {}
  -- ...
end
```

---

## Test Cases

### Basic Functionality

| # | Query | Setup | Expected Result |
|---|-------|-------|-----------------|
| 1 | `links-to:Alpha` | Notes B, C, D contain `[[Alpha]]` | B, C, D appear in results; Alpha does not |
| 2 | `linked-from:Alpha` | Alpha contains `[[B]]`, `[[C]]` | B, C appear in results; Alpha does not |
| 3 | `alias:cfd` | Note "Computational Fluid Dynamics" has `aliases: [CFD]` | That note appears in results |
| 4 | `alias:CFD` | Same as above | Same result (case-insensitive) |

### Heading-Qualified Links

| # | Query | Setup | Expected Result |
|---|-------|-------|-----------------|
| 5 | `links-to:Meeting#Decisions` | Note A has `[[Meeting#Decisions]]`, Note B has `[[Meeting#Summary]]` | Only A appears |
| 6 | `links-to:Meeting#decisions` | Same as above | A appears (slug comparison is case-insensitive) |
| 7 | `linked-from:Meeting#Actions` | Meeting's "Actions" section contains `[[TaskA]]`, `[[TaskB]]` | TaskA, TaskB appear |
| 8 | `links-to:Meeting` (no heading) | Notes A,B link to Meeting with different headings | Both A and B appear (heading stripped in _inlinks) |

### Quoted Names

| # | Query | Setup | Expected Result |
|---|-------|-------|-----------------|
| 9 | `links-to:"Project Alpha"` | Notes link to `[[Project Alpha]]` | Those notes appear |
| 10 | `links-to:Project` (no quotes) | Note named "Project" exists, separate from "Project Alpha" | Only notes linking to "Project" appear |
| 11 | `linked-from:"Meeting 2026-02-15"` | That meeting links to several notes | Those notes appear |

### Boolean Combinations

| # | Query | Setup | Expected Result |
|---|-------|-------|-----------------|
| 12 | `links-to:Alpha AND tag:active` | Various notes | Intersection of both conditions |
| 13 | `links-to:Alpha OR type:meeting` | Various notes | Union of both conditions |
| 14 | `-links-to:Archive` | Various notes | Notes that do NOT link to Archive |
| 15 | `links-to:Alpha deploy` | Various notes | Notes linking to Alpha AND containing "deploy" (metadata-then-text pipeline) |

### Edge Cases

| # | Query | Setup | Expected Result |
|---|-------|-------|-----------------|
| 16 | `links-to:NoSuchNote` | Note does not exist | Zero results |
| 17 | `links-to:CurrentNote` from within CurrentNote | Self-link exists | CurrentNote not in results (self-links excluded from _inlinks) |
| 18 | `links-to:Target` | Note has `![[Target]]` (embed) | That note appears (embeds are links) |
| 19 | `links-to:Target` | Note has `[[Target#Heading]]` | That note appears (headings stripped in _inlinks) |
| 20 | `links-to:Target` | Note has `[[Target^blockid]]` | That note appears (block refs stripped in _inlinks) |
| 21 | `links-to:"v2..beta"` | Name contains `..` | Quotes prevent range operator interpretation |
| 22 | `links-to:` (empty value) | Any vault | Returns false for all entries (no existence semantics) |
| 23 | `alias:` (empty value) | Notes with aliases | Returns notes with any alias (existence check) |
| 24 | `links-to:>Alpha` | Any vault | Returns false (only `=` operator supported) |

### Completion

| # | Input | Expected Completion |
|---|-------|-------------------|
| 25 | `links-t` + Tab | `links-to:` |
| 26 | `links-to:Al` + Tab | Note names starting with "Al" |
| 27 | `links-to:Meeting#` + Tab | Headings from the "Meeting" note |
| 28 | `linked-from:Da` + Tab | Note names starting with "Da" |
| 29 | `alias:` + Tab | All known aliases from the index |
| 30 | `alias:cf` + Tab | Aliases starting with "cf" |

### Performance

| # | Scenario | Expected Behavior |
|---|----------|-------------------|
| 31 | `links-to:HubNote` where HubNote has 50+ inlinks | Results within `live_debounce_ms` (150ms) |
| 32 | `linked-from:Meeting#Actions` first query (cold cache) | Disk read for section, then cached |
| 33 | `linked-from:Meeting#Actions` repeated in same evaluate() | Uses `_section_outlinks_cache`, no disk read |
| 34 | Vault with 1000+ notes, `alias:X` | O(N) scan over entries, fast in practice |

---

## Files Modified

| File | Changes |
|------|---------|
| `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_filter.lua` | Added `resolve_note_to_rel_path()`, `parse_link_target()`, `_section_outlinks_cache`, `clear_section_outlinks_cache()`, `get_section_outlinks()` helpers. Added `links-to`, `linked-from`, `alias` branches in `match_field()`. Added `alias` to `field_exists()`. Added `index` parameter to `match_field()` signature and call site. Added `clear_section_outlinks_cache()` call in `evaluate()`. |
| `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/config.lua` | Added `"links-to"`, `"linked-from"`, `"alias"` to `builtin_fields` array. |
| `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search.lua` | Added Tab completion for `links-to:`, `linked-from:`, `alias:` values. Added heading completion after `#` for `links-to:` and `linked-from:`. Added "Link Filters" section to `search_help()`. |
| `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/search_query.lua` | No changes required. |
| `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/vault_index.lua` | No changes required. |
