# 02 — Link-Specific Search Filters

## Problem

The advanced search system supports field filters for tags, types, paths, dates, priorities, and tasks, but has no way to query **link relationships** between notes. Users cannot answer questions like:

- "Which notes link to my `Project Alpha` note?" (`links-to:Project Alpha`)
- "Which notes does `Meeting 2026-02-15` link to?" (`linked-from:Meeting 2026-02-15`)
- "Find all notes that have the alias `CFD`" (`alias:CFD`)

These are fundamental navigation patterns in any linked knowledge base. Obsidian search supports `[[links to]]` and `[[linked from]]` filtering natively. The absence of these filters is the single biggest gap between this vault's search capabilities and Obsidian's.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **search_query.lua** | Tokenizer + recursive descent parser; produces AST with `field`, `has`, `task`, `text`, `regex` node types | `lua/andrew/vault/search_query.lua` |
| **search_filter.lua** | Splits AST into metadata/text trees; evaluates metadata nodes against `VaultIndexEntry`; dispatches text nodes to ripgrep | `lua/andrew/vault/search_filter.lua` |
| **search.lua** | UI layer: prompt mode, live mode (fzf_live), help float, Tab completion | `lua/andrew/vault/search.lua` |
| **vault_index.lua** | Unified persistent index; stores `outlinks` per entry, computes `_inlinks` derived index, provides `resolve_name()` and `get_inlinks()` API | `lua/andrew/vault/vault_index.lua` |
| **config.lua** | `M.search.builtin_fields` lists known field names for completion; `M.search.has_targets` lists valid `has:` targets | `lua/andrew/vault/config.lua` |

### What Already Exists in the Index

The vault index already stores everything needed for link-relationship queries:

**Outlinks** (per entry, line 561 of `vault_index.lua`):
```lua
-- entry.outlinks is an array of:
{ path = "Projects/Alpha", display = "Alpha", embed = false }
{ path = "Meeting Notes#Decisions", display = "Meeting Notes", embed = false }
{ path = "diagram.png", display = "diagram.png", embed = true }
```

The `path` field contains the raw wikilink target (before resolution), possibly including `#heading` or `^blockid` suffixes. The `embed` field distinguishes `![[...]]` from `[[...]]`.

**Inlinks** (derived, computed by `_recompute_inlinks()` at line 907):
```lua
-- self._inlinks[target_rel_path] is an array of:
{ path = "Projects/Alpha",  -- source rel_path WITHOUT .md
  display = "Alpha",        -- source basename
  embed = false }
```

**Name resolution** (`resolve_name()` at line 1323):
```lua
-- Resolves "Alpha" -> { "/vault/Projects/Alpha.md" } via:
-- 1. _name_index[lower] (basename + rel_path stem)
-- 2. _alias_index[lower] (frontmatter aliases)
```

**Aliases** (per entry, line 522-530):
```lua
-- entry.aliases is an array of lowercase strings from frontmatter:
-- aliases: [CFD, "Computational Fluid Dynamics"]
-- -> { "cfd", "computational fluid dynamics" }
```

### What Is Missing

1. **No `links-to:` field evaluator** in `search_filter.lua`. The `match_field()` function (line 211) has handlers for `type`, `tag`, `path`, `file`, `folder`, `status`, `priority`, `created`, `modified`, and `day` -- but nothing for link-relationship queries.

2. **No `linked-from:` field evaluator**. There is no way to find notes that are outlink targets of a given source note.

3. **No `alias:` field evaluator**. While `has:aliases` checks if a note has any aliases at all, there is no way to find notes with a *specific* alias value.

4. **No completion for these fields** in `search.lua`'s `_complete_advanced()` (line 462). The `builtin_fields` list at config line 329 does not include `links-to`, `linked-from`, or `alias`.

5. **No help text** for these filters in `search_help()` (line 371).

---

## Proposed Solution

### Architecture

All three new filters are **metadata-only** -- they are evaluated entirely against the vault index with no ripgrep involvement. This means:

- They are classified as `METADATA_TYPES` by `classify()` in `search_filter.lua`
- They participate in the existing `split_ast()` pipeline without modification
- They benefit from the same optimization: metadata filters narrow the file set *before* ripgrep runs

The implementation touches four files:

```
search_filter.lua  -- Add match_field handlers for links-to, linked-from, alias
config.lua         -- Add new fields to builtin_fields list
search.lua         -- Add completion + help text
search_query.lua   -- No changes needed (field:value syntax already supports these)
```

The parser requires **zero changes**. The tokenizer already handles `links-to:NoteName` correctly:
- `links-to` passes the identifier check at line 112 (`^[a-z][a-z0-9_-]*$` -- hyphens are allowed)
- The colon splits field name from value
- `parse_field_value()` returns `op = "=", value = "NoteName"`
- Quoted values like `links-to:"Project Alpha"` are handled by the tokenizer's quote-stripping at line 92-94

### Semantics

**`links-to:NoteName`** -- "Find notes whose outlinks point to NoteName"

A note matches if any of its `entry.outlinks` resolve to the target note. Resolution uses the same logic as `_recompute_inlinks()`: raw link path is matched against basenames, rel_path stems, and aliases (case-insensitive). This gives the same results as the inlinks displayed in the graph view.

Alternatively, we can look up the target note's `rel_path` via `resolve_name()` and then check `_inlinks[target_rel_path]` for the source file -- this is the inverse approach and is O(1) per note rather than iterating outlinks.

**`linked-from:NoteName`** -- "Find notes that NoteName links to"

A note matches if NoteName's outlinks resolve to this note. We resolve NoteName to its entry, iterate its `outlinks`, resolve each outlink target, and check if the current note is among them.

**`alias:SomeName`** -- "Find notes that have SomeName as a frontmatter alias"

A note matches if `SomeName` (case-insensitive) appears in `entry.aliases`. This is simpler than `links-to`/`linked-from` since no link resolution is needed.

---

## Step-by-Step Implementation Plan

### Step 1: Add Link Resolution Helper to `search_filter.lua`

Both `links-to:` and `linked-from:` need to resolve a note name to a `rel_path`. Add a helper that wraps `vault_index.resolve_name()` and converts the result to a `rel_path`.

**File:** `lua/andrew/vault/search_filter.lua`
**Location:** After the existing `field_exists()` function (line 205), before `match_field()` (line 211)

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
    -- Convert first match to rel_path
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

### Step 2: Add `links-to:` Handler in `match_field()`

**File:** `lua/andrew/vault/search_filter.lua`
**Location:** Inside `match_field()`, after the `folder` handler (line 258) and before `status` (line 262). The function needs an additional `index` parameter.

First, update `match_field` to accept the index as a third parameter:

```lua
--- Match a field AST node against an entry.
---@param node table field AST node { name, op, value, value2 }
---@param entry table VaultIndexEntry
---@param index table|nil VaultIndex instance (needed for links-to/linked-from)
---@return boolean
local function match_field(node, entry, index)
```

Then add the handler block:

```lua
  -- ── links-to ──
  if name == "links-to" then
    if op ~= "=" then return false end
    if not index then return false end

    -- Resolve the target note name to a rel_path
    local target_rel = resolve_note_to_rel_path(filter_val, index)
    if not target_rel then return false end

    -- Check if the current entry is in the target's inlinks
    local inlinks = index:get_inlinks(target_rel)
    local source_stem = entry.rel_path:gsub("%.md$", "")
    for _, inlink in ipairs(inlinks) do
      if inlink.path == source_stem then
        return true
      end
    end
    return false
  end
```

This uses the pre-computed `_inlinks` table for O(k) lookup where k is the number of inlinks to the target, rather than iterating all outlinks of the source entry and resolving each one.

### Step 3: Add `linked-from:` Handler in `match_field()`

**File:** `lua/andrew/vault/search_filter.lua`
**Location:** Immediately after the `links-to` handler

```lua
  -- ── linked-from ──
  if name == "linked-from" then
    if op ~= "=" then return false end
    if not index then return false end

    -- Resolve the source note name to a rel_path
    local source_rel = resolve_note_to_rel_path(filter_val, index)
    if not source_rel then return false end

    -- Get the source note's outlinks and check if any resolve to this entry
    local source_entry = index.files[source_rel]
    if not source_entry or not source_entry.outlinks then return false end

    -- Check if the current entry is in the source note's inlinks' targets
    -- More efficient: check _inlinks of *this* entry for the source
    local inlinks = index:get_inlinks(entry.rel_path)
    local source_stem = source_rel:gsub("%.md$", "")
    for _, inlink in ipairs(inlinks) do
      if inlink.path == source_stem then
        return true
      end
    end
    return false
  end
```

Note: Both `links-to:X` (find notes linking to X) and `linked-from:X` (find notes that X links to) use the `_inlinks` table but from opposite perspectives:

- `links-to:X` checks `_inlinks[X_rel_path]` for the current entry as source
- `linked-from:X` checks `_inlinks[current_entry_rel_path]` for X as source

### Step 4: Add `alias:` Handler in `match_field()`

**File:** `lua/andrew/vault/search_filter.lua`
**Location:** Immediately after the `linked-from` handler

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

Aliases are already stored as lowercase strings in the index (line 526: `aliases[#aliases + 1] = tostring(a):lower()`), so the comparison is straightforward.

### Step 5: Thread `index` Through to `match_field()`

Currently `match_field()` is called from `M.match_entry()` at line 654 without an index parameter:

```lua
  if t == "field" then
    return match_field(ast, entry)
  end
```

`M.match_entry()` already receives an `index` parameter (line 633: `function M.match_entry(ast, entry, index)`), so the change is trivial:

**File:** `lua/andrew/vault/search_filter.lua`
**Location:** Line 654

```lua
  if t == "field" then
    return match_field(ast, entry, index)
  end
```

### Step 6: Update `config.lua` -- Add New Fields to `builtin_fields`

**File:** `lua/andrew/vault/config.lua`
**Location:** Line 329-331, the `builtin_fields` array

```lua
  builtin_fields = {
    "type", "tag", "path", "file", "folder", "status",
    "created", "modified", "day", "priority",
    "links-to", "linked-from", "alias",
  },
```

### Step 7: Add Tab Completion for New Fields in `search.lua`

**File:** `lua/andrew/vault/search.lua`
**Location:** Inside `M._complete_advanced()` (line 462), add completion for `links-to:`, `linked-from:`, and `alias:` values.

After the existing `tag:` completion block (line 530-543), add:

```lua
  -- After links-to: suggest note names from index
  if lead:match("^links%-to:") then
    local prefix = "links-to:"
    local rest = lead:sub(#prefix + 1):lower()
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if idx then
      for _, entry in pairs(idx.files) do
        local name = entry.basename
        if name:lower():sub(1, #rest) == rest then
          -- Quote names with spaces
          if name:find(" ") then
            candidates[#candidates + 1] = prefix .. '"' .. name .. '"'
          else
            candidates[#candidates + 1] = prefix .. name
          end
        end
      end
    end
  end

  -- After linked-from: suggest note names from index
  if lead:match("^linked%-from:") then
    local prefix = "linked-from:"
    local rest = lead:sub(#prefix + 1):lower()
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if idx then
      for _, entry in pairs(idx.files) do
        local name = entry.basename
        if name:lower():sub(1, #rest) == rest then
          if name:find(" ") then
            candidates[#candidates + 1] = prefix .. '"' .. name .. '"'
          else
            candidates[#candidates + 1] = prefix .. name
          end
        end
      end
    end
  end

  -- After alias: suggest known aliases from index
  if lead:match("^alias:") then
    local prefix = "alias:"
    local rest = lead:sub(#prefix + 1):lower()
    local vault_index = require("andrew.vault.vault_index")
    local idx = vault_index.current()
    if idx then
      local seen = {}
      for _, entry in pairs(idx.files) do
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
```

### Step 8: Update Help Float in `search.lua`

**File:** `lua/andrew/vault/search.lua`
**Location:** Inside `M.search_help()` (line 371), add a new "Link Filters:" section after the "Field Filters:" section (after line 391).

Insert after the line `"  priority:1..3            Numeric range",` (line 391) and before `""` (line 392):

```lua
    "",
    "Link Filters:",
    "  links-to:NoteName        Notes linking to NoteName",
    "  links-to:\"Project Alpha\" Quote names with spaces",
    "  linked-from:NoteName     Notes that NoteName links to",
    "  alias:CFD                Notes with specific alias",
```

Also update the compact `SEARCH_HEADER` (line 84-87) to mention link filters:

```lua
local SEARCH_HEADER = table.concat({
  "field:value  tag:x  path:P/  has:tags  links-to:N  created:>7d",
  "AND  OR  NOT  -excluded  (a OR b) AND c   |  Ctrl-/ full help",
}, "\n")
```

### Step 9: Update Footer Hint in Prompt Mode

**File:** `lua/andrew/vault/search.lua`
**Location:** Line 248-251, the prompt window footer

```lua
    footer = {
      { " field:value tag:x has:tags links-to:N created:>7d AND OR NOT | ", "Comment" },
      { "Ctrl-/", "Special" },
      { " help ", "Comment" },
    },
```

---

## Edge Cases and Considerations

### 1. Note Names with Spaces

A query like `links-to:Project Alpha` would be parsed as two tokens: `links-to:Project` (FIELD) and `Alpha` (TEXT). The user must quote it: `links-to:"Project Alpha"`. This is already handled by the tokenizer -- the inline quote detection at lines 193-199 captures `field:"quoted value"` as a single word, and the quote-stripping at lines 92-94 removes the surrounding quotes before creating the FIELD token.

### 2. Note Names with Special Characters

Note names containing parentheses, dots, or other characters that might confuse the tokenizer should be quoted. The field value accepts any characters between quotes. The `parse_field_value()` function (line 60) might misinterpret `..` inside an unquoted value as a range operator. Users should quote note names containing `..`: `links-to:"Note..v2"`.

### 3. Ambiguous Name Resolution

`resolve_note_to_rel_path()` uses `resolve_name()` which returns an array (multiple notes may share a basename). The implementation takes the first match. This mirrors how `_recompute_inlinks()` behaves -- it resolves using the same priority order: path > basename > alias, and the first match wins when there are collisions. The `_detect_collisions()` mechanism already warns users about ambiguous names.

### 4. Self-Links

A note that links to itself (e.g., `[[Current Note]]` inside `Current Note.md`) will not appear in `_inlinks` because `_recompute_inlinks()` explicitly skips self-links at line 947: `if target and target.rel_path ~= source_entry.rel_path then`. This means `links-to:CurrentNote` run from within `CurrentNote` will not show `CurrentNote` in results, which is the expected behavior.

### 5. Embed Links

The outlinks array includes both regular wikilinks (`embed = false`) and embed transclusions (`embed = true`). The `_inlinks` computation does not distinguish between them. This means `links-to:NoteName` will match notes that transclude NoteName via `![[NoteName]]` as well as those that link via `[[NoteName]]`. This is the correct behavior -- an embed is a stronger link relationship than a regular link.

### 6. Heading and Block References

Outlinks like `[[Note#Heading]]` or `[[Note^blockid]]` are stored with the full path including the anchor. The `_recompute_inlinks()` function strips these at line 935: `raw = raw:match("^([^#^]+)") or raw`. So `links-to:Note` will match whether the source linked to `[[Note]]`, `[[Note#Heading]]`, or `[[Note^blockid]]`.

### 7. Comparison Operators

Only the `=` operator is meaningful for `links-to:`, `linked-from:`, and `alias:`. Queries like `links-to:>SomeName` would return `false` immediately. This matches the behavior of other non-numeric fields like `type:` and `tag:`.

### 8. Empty Value (Existence Check)

`links-to:` with empty value (just `links-to:`) would trigger the `field_exists()` check at line 218-219. We need to add a handler for this case in `field_exists()`. For `links-to:` it would mean "has any outlinks" (equivalent to `has:outlinks`). For `linked-from:` it would mean "has any inlinks" (equivalent to `has:inlinks`). For `alias:` it would mean "has any aliases" (equivalent to `has:aliases`).

Add to `field_exists()` (line 182):

```lua
  elseif name == "links-to" then
    return entry.outlinks ~= nil and #entry.outlinks > 0
  elseif name == "linked-from" then
    -- Entry has inlinks = some note links to this entry
    -- Need index for proper check; fall through to generic handling
    return entry.outlinks ~= nil and #entry.outlinks > 0
  elseif name == "alias" then
    return entry.aliases ~= nil and #entry.aliases > 0
```

However, the `links-to:` existence check is slightly misleading -- having outlinks does not mean the same thing as being linked to. For clarity, it is better to keep `links-to:` and `linked-from:` without empty-value semantics and let users use `has:outlinks` / `has:inlinks` instead. The simplest approach: do not add these to `field_exists()` and let the existing `field_exists` fallback to generic handling (which will check `entry["links-to"]` -- nil, so it returns false). This means `links-to:` alone is effectively a no-match, which is acceptable since the semantics are unclear.

For `alias:`, the existence semantics are clear ("has any alias"), so we should add it:

```lua
  elseif name == "alias" then
    return entry.aliases ~= nil and #entry.aliases > 0
```

### 9. Negation

`-links-to:NoteName` ("find notes that do NOT link to NoteName") works automatically through the existing NOT handler in the parser and `M.match_entry()`. The AST wraps the field node in a `{ type = "not", operand = ... }` node, and `match_entry()` at line 650 returns `not M.match_entry(ast.operand, entry, index)`.

### 10. Performance

For a vault with N notes where note X has K inlinks:

- `links-to:X` resolves X once (O(N) worst case for name resolution, O(1) amortized via `_name_index`), then for each candidate entry checks `_inlinks[X]` for the candidate's stem. The inlinks array for X has K entries, so each check is O(K). Total: O(N * K) in the worst case. For typical vaults (N=1000, K=20), this is fast.

- `linked-from:X` resolves X once, then for each candidate entry checks `_inlinks[candidate]` for X's stem. Each check iterates the candidate's inlink list. Total: O(N * avg_inlinks). Similar performance profile.

- `alias:Name` is O(N * avg_aliases), where avg_aliases is typically 1-2. Very fast.

None of these require disk I/O or external process spawning -- they operate entirely on the in-memory vault index.

---

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `lua/andrew/vault/search_filter.lua` | **Modify** | Add `resolve_note_to_rel_path()` helper; add `links-to`, `linked-from`, `alias` handlers in `match_field()`; thread `index` to `match_field()` call; add `alias` to `field_exists()` |
| `lua/andrew/vault/config.lua` | **Modify** | Add `"links-to"`, `"linked-from"`, `"alias"` to `builtin_fields` array (line 329) |
| `lua/andrew/vault/search.lua` | **Modify** | Add Tab completion for `links-to:`, `linked-from:`, `alias:` values; add "Link Filters" section to help float; update `SEARCH_HEADER` and prompt footer |
| `lua/andrew/vault/search_query.lua` | **No change** | Field tokenization already handles hyphenated names and quoted values |
| `lua/andrew/vault/vault_index.lua` | **No change** | `outlinks`, `_inlinks`, `resolve_name()`, `get_inlinks()` already provide everything needed |

---

## Testing Plan

### Manual Verification

**1. Basic `links-to:` filter:**

- Create (or identify) note `Alpha` that is linked to from notes `B`, `C`, `D`.
- Run `:VaultSearchAdvanced` and enter `links-to:Alpha`.
- Verify results contain `B`, `C`, `D` and do not contain `Alpha` itself.
- Verify notes that do not link to Alpha are excluded.

**2. Basic `linked-from:` filter:**

- Note `Alpha` contains `[[B]]`, `[[C]]`, `[[D]]` wikilinks.
- Run `linked-from:Alpha`.
- Verify results contain `B`, `C`, `D` (the notes that Alpha links TO).
- Verify Alpha itself is not in the results.

**3. Basic `alias:` filter:**

- Note `Computational Fluid Dynamics` has `aliases: [CFD]` in frontmatter.
- Run `alias:cfd`.
- Verify `Computational Fluid Dynamics` appears in results.
- Verify case-insensitivity: `alias:CFD` and `alias:Cfd` produce the same result.

**4. Quoted note names with spaces:**

- Note `Project Alpha` exists and is linked to from other notes.
- Run `links-to:"Project Alpha"`.
- Verify correct results.
- Run `links-to:Project` (without quotes). Verify it matches a note named `Project` (if one exists), not `Project Alpha`.

**5. Combination with other filters:**

- Run `links-to:Alpha AND tag:active`. Verify results are the intersection.
- Run `links-to:Alpha OR type:meeting`. Verify results are the union.
- Run `-links-to:Alpha type:meeting`. Verify negation works (meetings that do NOT link to Alpha).

**6. Combination with text search:**

- Run `links-to:Alpha deploy`. Verify results are notes linking to Alpha AND containing "deploy".
- This exercises the `metadata_then_text` mode: metadata narrows first, then ripgrep searches within matches.

**7. Live mode:**

- Run `:VaultSearchAdvancedLive` and type `links-to:Alpha`.
- Verify results update live as you type.
- Verify performance is acceptable (no visible lag).

**8. Tab completion:**

- In the advanced search prompt, type `links-t` and press Tab. Verify `links-to:` is completed.
- Type `links-to:Al` and press Tab. Verify note names starting with "Al" are suggested.
- Type `alias:` and press Tab. Verify known aliases are suggested.

**9. Help float:**

- Run `:VaultSearchHelp` or press Ctrl-/ in the search prompt.
- Verify the "Link Filters" section is present and shows correct syntax examples.

**10. Edge cases:**

| Case | Query | Expected Behavior |
|------|-------|-------------------|
| Non-existent target | `links-to:NoSuchNote` | Zero results (resolve returns nil, all entries return false) |
| Self-link | `links-to:CurrentNote` from CurrentNote | CurrentNote not in results (self-links excluded from inlinks) |
| Embed link | Note has `![[Target]]` | `links-to:Target` includes that note |
| Heading ref link | Note has `[[Target#Heading]]` | `links-to:Target` includes that note |
| Block ref link | Note has `[[Target^blockid]]` | `links-to:Target` includes that note |
| Name with dots | `links-to:"v2..beta"` | Quotes prevent range operator interpretation |
| Empty value | `links-to:` | Returns false for all entries (no existence semantics) |
| `alias:` empty | `alias:` | Returns notes that have any alias (existence check) |
| Index not ready | Any link filter | Falls back to text search with warning (existing behavior in `search.lua` lines 186-195) |

### Performance Verification

- On a vault with 500+ notes, run `links-to:` for a well-connected note (20+ inlinks).
- Verify the live mode provider returns results within the configured `live_debounce_ms` (150ms default).
- Run `:VaultIndexStatus` to confirm the index is loaded before testing.
