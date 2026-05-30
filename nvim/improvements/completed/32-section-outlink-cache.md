# Performance: Section-Level Outlink Cache

**Priority:** Medium (reduces redundant disk I/O during repeated search queries)
**Module:** `lua/andrew/vault/search_filter.lua`
**Related:** `lua/andrew/vault/vault_index.lua`, `lua/andrew/vault/link_utils.lua`, `lua/andrew/vault/graph_filter.lua`

## Summary

The `get_section_outlinks()` function in `search_filter.lua` reads a file from
disk and parses a heading section to extract wikilinks every time a
`linked-from:NoteName#Heading` filter is evaluated. The current per-evaluation
cache (`_section_outlinks_cache`) is cleared at the start of every
`evaluate()` call, so repeated searches (e.g., live/debounced search, graph
filter predicates) re-read the same files from disk. This proposal introduces a
generation-aware persistent cache that survives across `evaluate()` calls and
is invalidated only when the vault index detects file changes.

## Current Behavior

### Code Path

1. User types a search query containing `linked-from:SomeNote#SomeHeading`.
2. `search.lua` calls `search_filter.evaluate(ast, index, graph_sets)`.
3. `evaluate()` calls `clear_section_outlinks_cache()`, wiping the entire cache.
4. For **every** file in the vault index, `match_entry()` is called.
5. When the AST node is a `linked-from` field with a heading, `match_entry()`
   calls `get_section_outlinks(source_entry, heading)`.
6. `get_section_outlinks()` checks `_section_outlinks_cache[key]`. On the first
   call within this evaluate cycle, the cache is empty, so it:
   - Calls `link_utils.read_heading_section(entry.abs_path, heading)`, which
     opens the file via `io.open()`, reads all lines, scans for the heading,
     and returns the section lines.
   - Iterates the section lines extracting wikilinks via pattern matching.
   - Stores the result in `_section_outlinks_cache`.
7. Subsequent calls within the **same** `evaluate()` cycle hit the cache.
8. When the user modifies the query (live search), step 2 repeats -- the cache
   is wiped and the file is read from disk again.

### File: `lua/andrew/vault/search_filter.lua`, lines 250-310

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

### Call Site: `evaluate()`, line 1327

```lua
function M.evaluate(ast, index, graph_sets)
  clear_section_outlinks_cache()   -- <-- wipes the cache every time
  local matches = {}
  if not index or not index.files then return matches end

  for rel_path, entry in pairs(index.files) do
    if M.match_entry(ast, entry, index, graph_sets) then
      matches[rel_path] = entry
    end
  end

  return matches
end
```

### Secondary Call Site: `graph_filter.lua`, line 178

```lua
return function(abs_path)
  local entry = idx:get_entry_by_abs(abs_path)
  if not entry then return false end
  return search_filter.match_entry(meta_ast, entry, idx)
end
```

This path calls `match_entry()` directly without ever calling `evaluate()`, so
the cache is never cleared -- but it also never benefits from generation-based
invalidation. If the underlying file changes, stale results will be returned
until the module is reloaded.

## Performance Analysis

### Worst Case: Live Search with `linked-from:Note#Heading`

In live search mode, every keystroke (after debounce) triggers a new
`evaluate()` call. Each call:

1. Clears the cache.
2. Iterates all N files in the vault index.
3. For a `linked-from:SourceNote#Heading` query, calls
   `get_section_outlinks()` once per evaluate cycle (the source file is always
   the same). But the disk read happens fresh every time.

| Scenario | Disk reads per evaluate | Evaluations per search session | Total disk reads |
|----------|----------------------|-------------------------------|-----------------|
| Single query execution | 1 | 1 | 1 |
| Live search, 10 keystrokes | 1 | 10 | 10 |
| Live search, complex OR of 3 `linked-from:` with different sources | 3 | 10 | 30 |
| Graph filter predicate over 200 nodes | 1 | 200 (per node) | 1* |

*Graph filter calls `match_entry()` without clearing, so the flat cache
actually helps here, but staleness is a risk.

### Cost per Disk Read

Each `get_section_outlinks()` call:

1. `io.open()` + `f:lines()` to read entire file into memory (~0.1-0.5ms for a
   typical 200-line markdown file).
2. Linear scan for heading match (~negligible).
3. Pattern matching for wikilinks on section lines (~negligible).

For a 500-file vault with 10 live search evaluations, the redundant reads add
up to ~1-5ms of avoidable I/O per keystroke. This is modest, but the pattern
is wasteful and scales poorly with:

- Larger files (research notes with 1000+ lines).
- Complex queries with multiple `linked-from:` clauses.
- Slower storage (network mounts, encrypted filesystems).

## Detailed Implementation

### Cache Structure

Replace the flat per-evaluation cache with a generation-aware file-level cache:

```lua
--- Section outlinks cache with vault index generation tracking.
---@type table<string, SectionOutlinksCacheEntry>
local _section_cache = {}
local _section_cache_generation = -1

---@class SectionOutlinksCacheEntry
---@field sections table<string, table[]>  heading_slug -> outlinks[]
```

The top-level key is the **file path** (`entry.rel_path`). Each file entry
contains a `sections` table mapping heading slugs to their extracted outlink
arrays. This structure means:

- A single file read populates all heading sections for that file.
- Different `linked-from:` queries referencing different headings in the same
  file share the same cached file read.

### Cache Invalidation via Vault Index Generation

The vault index increments `_generation` whenever files change (see
`VaultIndex:_notify_update()` in `vault_index.lua`, line 126). Other modules
already use this pattern for cache invalidation:

- `connections.lua` (line 33-35): compares `_index_gen` against `idx._generation`
- `calendar.lua` (line 176): compares `_deadline_cache.generation` against `idx._generation`

The section outlinks cache adopts the same pattern:

```lua
--- Invalidate cache if the vault index generation has advanced.
---@param index table VaultIndex instance
local function maybe_invalidate_section_cache(index)
  local gen = index and index._generation or 0
  if gen ~= _section_cache_generation then
    _section_cache = {}
    _section_cache_generation = gen
  end
end
```

This replaces the unconditional `clear_section_outlinks_cache()` in
`evaluate()`.

### Cache Population

On first access for a given file+heading, the function reads the file from disk
once and caches the section outlinks. However, unlike the current approach that
only caches the specific heading requested, the new implementation reads the
file once and parses **all** heading sections, so that subsequent queries for
different headings in the same file avoid re-reading.

Full-file parsing trades slightly more upfront work for eliminating redundant
reads when multiple headings of the same source file are queried.

### Memory Limit Considerations

For a typical vault:

- 500 files, average 5 headings each, average 3 outlinks per heading section.
- Per outlink: ~1 table with 1 string field = ~80 bytes.
- Per heading: ~240 bytes of outlinks + key overhead.
- Per file: ~1.2 KB of cached section data.
- Total: ~600 KB for the entire vault.

This is well within acceptable limits. The cache is bounded by the number of
files in the vault and is cleared whenever the index generation advances (any
file change). No explicit size cap is needed.

For very large vaults (5000+ files), the cache is still bounded because only
files actually queried via `linked-from:` with a heading are populated -- the
cache is lazy, not eagerly filled.

### Approach: Lazy Per-File, Eager Per-Section

To balance simplicity and performance, the chosen approach reads the full file
once (all headings) but only on first access. This means:

- `linked-from:Note#HeadingA` reads `Note.md` once, caches all sections.
- `linked-from:Note#HeadingB` in the same or later evaluation hits cache.
- A vault index generation change wipes the entire cache.

## Before/After Code

### Before: `search_filter.lua`

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
    local embed_positions = {}
    for s_pos in line:gmatch("()!%[%[") do
      embed_positions[s_pos] = true
    end
    for inner in line:gmatch("!%[%[([^%]]+)%]%]") do
      local parsed = link_utils.parse_target(inner)
      if parsed.name ~= "" then
        links[#links + 1] = {
          path = parsed.name .. (parsed.heading and "#" .. parsed.heading or "")
            .. (parsed.block_id and "^" .. parsed.block_id or ""),
        }
      end
    end
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

-- ... in evaluate():
function M.evaluate(ast, index, graph_sets)
  clear_section_outlinks_cache()
  -- ...
end
```

### After: `search_filter.lua`

```lua
-- =============================================================================
-- Section outlinks cache (generation-aware, persists across evaluate() calls)
-- =============================================================================

--- Per-file section outlinks cache.
--- Structure: { [rel_path] = { sections = { [heading_slug] = outlinks[] } } }
---@type table<string, { sections: table<string, table[]> }>
local _section_cache = {}
local _section_cache_generation = -1

--- Invalidate section cache if vault index generation has advanced.
---@param index table VaultIndex instance
local function maybe_invalidate_section_cache(index)
  local gen = index and index._generation or 0
  if gen ~= _section_cache_generation then
    _section_cache = {}
    _section_cache_generation = gen
  end
end

--- Extract outlinks from a single line of markdown.
--- Handles both embeds (![[...]]) and regular wikilinks ([[...]]).
---@param line string
---@param link_utils table
---@return table[] links
local function extract_line_outlinks(line, link_utils)
  local links = {}
  local embed_positions = {}
  for s_pos in line:gmatch("()!%[%[") do
    embed_positions[s_pos] = true
  end
  for inner in line:gmatch("!%[%[([^%]]+)%]%]") do
    local parsed = link_utils.parse_target(inner)
    if parsed.name ~= "" then
      links[#links + 1] = {
        path = parsed.name .. (parsed.heading and "#" .. parsed.heading or "")
          .. (parsed.block_id and "^" .. parsed.block_id or ""),
      }
    end
  end
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
  return links
end

--- Read a file once and build a per-heading-section outlinks map.
--- Parses all headings in a single pass.
---@param abs_path string
---@return table<string, table[]> sections: heading_slug -> outlinks[]
local function build_file_section_map(abs_path)
  local slug_mod = require("andrew.vault.slug")
  local link_utils = require("andrew.vault.link_utils")

  local f = io.open(abs_path, "r")
  if not f then return {} end

  local sections = {}
  local current_slug = nil   -- nil = preamble (before first heading)
  local current_links = {}

  for line in f:lines() do
    local level_str, text = line:match("^(#+)%s+(.*)")
    if level_str then
      -- Flush previous section
      if current_slug then
        sections[current_slug] = current_links
      end
      current_slug = slug_mod.heading_to_slug(vim.trim(text))
      current_links = {}
    end
    -- Always extract links from the current line (including heading line itself)
    if current_slug then
      local line_links = extract_line_outlinks(line, link_utils)
      for _, lnk in ipairs(line_links) do
        current_links[#current_links + 1] = lnk
      end
    end
  end
  -- Flush final section
  if current_slug then
    sections[current_slug] = current_links
  end

  f:close()
  return sections
end

--- Get outlinks from a specific heading section of a note.
--- Uses generation-aware cache to avoid redundant disk reads.
---@param entry table VaultIndexEntry
---@param heading string heading text to scope to
---@param index table|nil VaultIndex instance (for generation tracking)
---@return table[] outlinks within the section
local function get_section_outlinks(entry, heading, index)
  -- Invalidate if generation advanced
  if index then
    maybe_invalidate_section_cache(index)
  end

  local rel = entry.rel_path

  -- Populate file cache on first access
  if not _section_cache[rel] then
    _section_cache[rel] = {
      sections = build_file_section_map(entry.abs_path),
    }
  end

  local slug_mod = require("andrew.vault.slug")
  local heading_slug = slug_mod.heading_to_slug(heading)
  return _section_cache[rel].sections[heading_slug] or {}
end

-- ... in evaluate():
function M.evaluate(ast, index, graph_sets)
  -- Generation-aware invalidation replaces unconditional clear
  maybe_invalidate_section_cache(index)
  local matches = {}
  if not index or not index.files then return matches end

  for rel_path, entry in pairs(index.files) do
    if M.match_entry(ast, entry, index, graph_sets) then
      matches[rel_path] = entry
    end
  end

  return matches
end
```

### Changes to `match_entry` Call Sites

The `linked-from:` handler must pass `index` to `get_section_outlinks()`:

```lua
-- Before (line 504):
local section_outlinks = get_section_outlinks(source_entry, source_heading)

-- After:
local section_outlinks = get_section_outlinks(source_entry, source_heading, index)
```

This ensures that even when `match_entry()` is called directly from
`graph_filter.lua` (without going through `evaluate()`), the generation-based
invalidation still fires.

## Behavioral Differences

### Heading Section Scoping

The current implementation uses `link_utils.read_heading_section()`, which
returns lines from a heading through the next same-or-higher-level heading.
This means a `## SubHeading` section ends at the next `##` or `#` heading.

The new `build_file_section_map()` implementation uses a simpler model: each
heading's section extends from its line to the next heading of **any** level.
This differs in one case:

- A `## Parent` heading followed by `### Child` followed by `## Sibling`:
  - **Current:** `read_heading_section("Parent")` returns lines from `## Parent`
    through `### Child` (stops at `## Sibling` which is same level).
  - **New (flat sections):** `## Parent` section ends at `### Child` (next
    heading of any level).

To preserve the current behavior exactly, `build_file_section_map()` must
track heading levels and accumulate links into all ancestor sections:

```lua
local function build_file_section_map(abs_path)
  local slug_mod = require("andrew.vault.slug")
  local link_utils = require("andrew.vault.link_utils")

  local f = io.open(abs_path, "r")
  if not f then return {} end

  local sections = {}
  -- Stack of { slug, level } for ancestor headings
  local heading_stack = {}

  for line in f:lines() do
    local level_str, text = line:match("^(#+)%s+(.*)")
    if level_str then
      local level = #level_str
      local heading_slug = slug_mod.heading_to_slug(vim.trim(text))

      -- Pop headings from stack that are same or deeper level
      while #heading_stack > 0
        and heading_stack[#heading_stack].level >= level do
        table.remove(heading_stack)
      end

      -- Initialize section for this heading
      if not sections[heading_slug] then
        sections[heading_slug] = {}
      end

      -- Push this heading onto the stack
      heading_stack[#heading_stack + 1] = {
        slug = heading_slug,
        level = level,
      }
    end

    -- Extract links and add to all active ancestor sections
    if #heading_stack > 0 then
      local line_links = extract_line_outlinks(line, link_utils)
      for _, lnk in ipairs(line_links) do
        for _, ancestor in ipairs(heading_stack) do
          if not sections[ancestor.slug] then
            sections[ancestor.slug] = {}
          end
          local sec = sections[ancestor.slug]
          sec[#sec + 1] = lnk
        end
      end
    end
  end

  f:close()
  return sections
end
```

This version ensures that querying a parent heading returns outlinks from both
the parent and all its child sections, matching the behavior of
`link_utils.read_heading_section()`.

### Duplicate Heading Slugs

If a file has two headings with the same slug (e.g., two `## Notes` sections),
the stack-based approach will merge their outlinks into the same slug key. The
current `read_heading_section()` returns only the first matching heading. This
is a minor semantic difference; in practice, duplicate heading slugs are rare
and the merged result is arguably more useful for search.

If exact first-match semantics are required, an additional `_seen_slugs` set
can skip re-initialization of already-populated slugs.

## Performance Benchmarks (Expected)

### Test Setup

- Vault: 500 markdown files, average 200 lines each.
- Query: `linked-from:ProjectNote#Requirements` (single source file).
- Live search: 10 evaluate cycles (simulating 10 keystrokes).

### Before

| Metric | Value |
|--------|-------|
| Disk reads per evaluate | 1 |
| Evaluate cycles | 10 |
| Total disk reads | 10 |
| Time per disk read | ~0.3ms |
| Total I/O overhead | ~3ms |

### After

| Metric | Value |
|--------|-------|
| Disk reads total (across all evaluates) | 1 |
| Cache hits | 9 |
| Total I/O overhead | ~0.3ms |
| Improvement | ~90% reduction |

### Complex Query: Three `linked-from:` Sources

Query: `linked-from:A#H1 OR linked-from:B#H2 OR linked-from:C#H3`

| Metric | Before | After |
|--------|--------|-------|
| Disk reads per evaluate | 3 | 0 (after first) |
| Total across 10 evaluates | 30 | 3 |
| Time saved | -- | ~8.1ms |

### Graph Filter Predicate (200 Nodes)

The graph filter calls `match_entry()` directly for each visible node:

| Metric | Before | After |
|--------|--------|-------|
| Disk reads (old flat cache, no invalidation) | 1 (stale risk) | 1 (generation-safe) |
| Staleness risk | Yes | No |

## Test Cases

### 1. Cache Hit Within Single Evaluate

```lua
-- Setup: file "source.md" with heading "## Links" containing [[Target]]
-- Query: linked-from:source#Links
-- Action: Run evaluate() once
-- Expected: get_section_outlinks() reads disk once, returns cached on re-entry
--           (same behavior as before, but verifies no regression)
```

### 2. Cache Persists Across Evaluate Calls (No Index Change)

```lua
-- Setup: same as above
-- Action: Run evaluate() twice without index generation change
-- Expected:
--   First evaluate: 1 disk read (cache miss)
--   Second evaluate: 0 disk reads (cache hit, generation unchanged)
-- Verify: mock io.open to count calls; should be 1 total
```

### 3. Cache Invalidation on Index Generation Change

```lua
-- Setup: same as above
-- Action:
--   1. Run evaluate() -> cache populated
--   2. Trigger index._generation increment (simulate file change)
--   3. Run evaluate() again
-- Expected: cache is wiped, file re-read from disk
-- Verify: io.open called twice total (once per evaluate)
```

### 4. Multiple Headings in Same File

```lua
-- Setup: "source.md" with "## Alpha" containing [[A]] and "## Beta" containing [[B]]
-- Action: Query linked-from:source#Alpha, then linked-from:source#Beta
-- Expected: single disk read populates both heading sections
-- Verify: io.open called once; both queries return correct links
```

### 5. Parent Heading Includes Child Section Links

```lua
-- Setup: "source.md" with:
--   ## Parent       (contains [[P]])
--   ### Child       (contains [[C]])
--   ## Sibling      (contains [[S]])
-- Action: Query linked-from:source#Parent
-- Expected: returns outlinks [[P]] and [[C]] (not [[S]])
-- Verify: matches current read_heading_section() behavior
```

### 6. Graph Filter Path (No evaluate() Call)

```lua
-- Setup: graph_filter.lua calls match_entry() directly
-- Action:
--   1. Call match_entry() with linked-from:source#Heading -> cache populated
--   2. Increment index._generation
--   3. Call match_entry() again
-- Expected: second call detects generation change, re-reads file
-- Verify: no stale data returned after file modification
```

### 7. Nonexistent File / Heading

```lua
-- Setup: entry.abs_path points to a file that does not exist
-- Action: get_section_outlinks(entry, "Missing")
-- Expected: returns empty table, caches the empty result
-- Verify: no error thrown, empty table cached under rel_path
```

### 8. Empty File

```lua
-- Setup: entry.abs_path points to a zero-byte file
-- Action: get_section_outlinks(entry, "Anything")
-- Expected: returns empty table
```

## Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/search_filter.lua` | Replace `_section_outlinks_cache` with generation-aware `_section_cache`. Rewrite `get_section_outlinks()` to use `build_file_section_map()`. Add `maybe_invalidate_section_cache()`. Update `evaluate()` to call `maybe_invalidate_section_cache()` instead of `clear_section_outlinks_cache()`. Add `index` parameter to `get_section_outlinks()` call in `linked-from:` handler. Extract `extract_line_outlinks()` helper. |

No other files require modification. The change is internal to `search_filter.lua`.

## Migration / Compatibility

- No external API changes. `evaluate()` and `match_entry()` signatures are
  unchanged.
- The `get_section_outlinks()` function gains an optional `index` parameter.
  Passing `nil` disables generation tracking (cache never auto-invalidates),
  which is acceptable for one-shot calls but not recommended.
- The `clear_section_outlinks_cache()` function can be removed or kept as a
  public API for manual cache clearing if needed for testing.

## Risks

- **Heading scope semantics:** The stack-based `build_file_section_map()` must
  faithfully reproduce `read_heading_section()` behavior for parent headings
  that include child sections. The implementation section above addresses this
  with the heading stack approach.
- **Duplicate heading slugs:** Files with duplicate heading slugs will have
  merged outlinks. This is a minor semantic change. Document as known behavior
  or add first-match guard.
- **Memory:** The cache grows proportionally to the number of distinct source
  files queried. For typical usage (1-3 source files per `linked-from:` query),
  memory impact is negligible. The entire cache is cleared on any index
  generation change.
