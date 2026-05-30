# 57 --- Search & Filter Pipeline Performance

This document is a self-contained implementation guide. Each optimization below is unique to this document.

**Status:** Implemented

Three targeted optimizations for the search and filter pipeline, addressing
date parsing overhead, live search re-evaluation per keystroke, and ripgrep
output processing.

> **Modules affected:** `search_filter/match_field.lua`, `date_utils.lua`,
> `search/live.lua`, `search_filter/ripgrep.lua`, `vault_index_parser.lua`

---

## ~~Pre-Computed Lowercase Fields~~ → Consolidated into doc 58-parser-single-pass-optimization.md

---

## 1. Cached Date Parsing in Vault Index

### Problem Analysis

**File:** `lua/andrew/vault/date_utils.lua` (lines 43-66)

`parse_iso_datetime()` is called for every entry during date-based filtering
(`created:>2024-01`, `modified:<7d`, `task-due:today`). For a 2000-file vault
with date filters, this means 2000 date parses per query — parsing the same
frontmatter `created` and `modified` values that never change between index
rebuilds.

```lua
-- date_utils.lua:43-66
function M.parse_iso_datetime(s)
    if not s or s == "" then return nil end
    -- Pattern matching for YYYY-MM-DD[THH:MM:SS[.fff][Z|+HH:MM]]
    local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    -- ... 20+ lines of time component parsing ...
    return os.time({ year = y, month = m, day = d, hour = h, min = mi, sec = sec })
end
```

`os.time()` is a C function call that's relatively expensive compared to a
table lookup.

**Complexity:** O(N) date parses per query, each involving regex + `os.time()`

### Proposed Solution

Cache parsed timestamps on vault index entries during index build. Add
`created_ts` and `modified_ts` fields to each entry.

### Code Changes

**In `vault_index_parser.lua`, after frontmatter extraction:**

```lua
-- After parsing frontmatter, pre-compute timestamps:
local date_utils = require("andrew.vault.date_utils")

entry.created_ts = entry.frontmatter and entry.frontmatter.created
    and date_utils.parse_iso_datetime(tostring(entry.frontmatter.created))
    or nil

entry.modified_ts = entry.frontmatter and entry.frontmatter.modified
    and date_utils.parse_iso_datetime(tostring(entry.frontmatter.modified))
    or nil
```

**In `search_filter/match_field.lua`, use cached timestamps:**

```lua
-- Before:
local ts = date_utils.parse_iso_datetime(tostring(entry.frontmatter.created))

-- After:
local ts = entry.created_ts
    or date_utils.parse_iso_datetime(tostring(entry.frontmatter.created))
```

**In `filter_utils.lua`, `get_timestamp()`:**

```lua
function M.get_timestamp(entry, field)
    -- Fast path: use pre-computed timestamps
    if field == "created" and entry.created_ts then return entry.created_ts end
    if field == "modified" and entry.modified_ts then return entry.modified_ts end
    -- Fallback: parse from frontmatter
    local val = entry.frontmatter and entry.frontmatter[field]
    if val then return date_utils.parse_iso_datetime(tostring(val)) end
    return nil
end
```

### Expected Performance Improvement

- **Before:** 2000 `parse_iso_datetime()` + `os.time()` calls per date query
- **After:** 0 runtime parsing (pre-computed). Fallback path handles custom fields.

For queries combining date + text filters (common pattern), this eliminates the
most expensive part of the metadata evaluation.

### Risk Assessment

- **Memory:** Two numbers per entry. For 2000 entries: 32KB — negligible.
- **Serialization:** Timestamps can be excluded from persisted index and
  recomputed on load (they're derivable from frontmatter).
- **Dynamic dates:** `task-due:today` still evaluates against the pre-computed
  timestamp, but `today` is resolved at query time. This is correct.

---

## 2. Incremental Live Search Filtering

### Problem Analysis

**File:** `lua/andrew/vault/search/live.lua` (lines 31-50)

The live search provider re-evaluates the **entire vault index** on every
keystroke (debounced). When the user types `task-due:>7` then adds `d` to make
`task-due:>7d`, the full metadata evaluation runs again from scratch even though
the result set can only shrink (the new query is more restrictive).

```lua
-- live.lua:31-50 (simplified)
local function fzf_live_provider(query)
    local ast = search_query.parse(query)
    local split = search_filter.split_ast(ast)
    -- Re-evaluates ALL files against metadata AST
    local file_set = search_filter.evaluate(split.metadata_ast, idx, graph_sets)
    -- Then runs ripgrep on the text AST against file_set
    return search_filter.ripgrep_in_files(split.text_ast, file_set)
end
```

**Complexity:** O(N * C) per keystroke where N = files, C = filter complexity.
For a 2000-file vault with 3 metadata filters: ~6000 evaluations per keystroke.

### Proposed Solution

Cache the previous query's result set and AST. When the new query is a strict
superset of the previous (i.e., the previous AST is a subtree of the new AST),
filter incrementally against the cached result set instead of the full index.

### Code Changes

```lua
-- In live.lua, add query result caching:
local _prev_query = nil
local _prev_meta_ast = nil
local _prev_file_set = nil

local function fzf_live_provider(query)
    local ast = search_query.parse(query)
    local split = search_filter.split_ast(ast)

    local file_set
    -- Check if we can filter incrementally
    if _prev_file_set
        and _prev_query
        and query:sub(1, #_prev_query) == _prev_query  -- prefix match
        and search_filter.is_ast_superset(split.metadata_ast, _prev_meta_ast)
    then
        -- Incremental: filter the previous result set (smaller input)
        file_set = search_filter.evaluate(split.metadata_ast, idx, nil, _prev_file_set)
    else
        -- Full evaluation
        file_set = search_filter.evaluate(split.metadata_ast, idx, graph_sets)
    end

    _prev_query = query
    _prev_meta_ast = split.metadata_ast
    _prev_file_set = file_set

    return search_filter.ripgrep_in_files(split.text_ast, file_set)
end
```

**New helper in `search_filter.lua`:**

```lua
--- Check if new_ast is strictly more restrictive than old_ast.
--- Simple heuristic: returns true if old_ast text is a prefix of new_ast text
--- and no operators were removed.
function M.is_ast_superset(new_ast, old_ast)
    if not old_ast or not new_ast then return false end
    -- Conservative: only allow AND trees where new has all old nodes plus more
    if new_ast.type ~= "and" or old_ast.type ~= "and" then return false end
    -- Check all old children exist in new
    -- ... (structural AST comparison) ...
end
```

**Modified `evaluate()` to accept optional `restrict_to` set:**

```lua
function M.evaluate(ast, idx, graph_sets, restrict_to)
    local files = restrict_to or idx.files
    local result = {}
    for rel_path, entry in pairs(files) do
        if match_entry(ast, entry, idx, graph_sets) then
            result[rel_path] = entry
        end
    end
    return result
end
```

### Expected Performance Improvement

For typing a 10-character query like `task-due:>7d`:

- **Before:** 10 keystrokes * 2000 files = 20,000 evaluations
- **After:** 1st keystroke: 2000 evals. Subsequent 9 keystrokes: filter against
  progressively smaller result sets. Typical: ~5000 total evaluations (~4x faster).

The improvement is most pronounced for restrictive queries that quickly narrow
the result set.

### Risk Assessment

- **Correctness:** The `is_ast_superset` check must be conservative. False
  negatives (falling back to full eval) are safe. False positives would produce
  incorrect results. Start with simple prefix matching and expand.
- **Cache invalidation:** Clear cache when index generation changes or query
  is cleared. The `_prev_query` prefix check handles backspace (cache miss,
  full re-eval).
- **Memory:** One copy of the previous result set. For 2000 files: ~80KB.
- **OR queries:** Incremental filtering only works for AND queries (adding
  terms narrows results). OR queries always trigger full re-eval.

---

## 3. Optimized Ripgrep Output Processing

### Problem Analysis

**File:** `lua/andrew/vault/search_filter/ripgrep.lua` (lines 72-74, 171-184)

Two issues in the ripgrep output processing pipeline:

**4a. File extraction regex recompilation:**
`extract_rg_file()` (line 72) uses `line:match("^(.-):%d+:%d+:")` for every
line in ripgrep results. Lua recompiles the pattern on each call.

**4b. AND result deduplication:**
The AND operator (lines 171-184) deduplicates by storing full output lines as
hash keys, which wastes memory for long lines.

### Proposed Solution

**4a.** Replace regex-based file extraction with faster `string.find()`:

```lua
-- Before:
local function extract_rg_file(line)
    return line:match("^(.-):%d+:%d+:")
end

-- After:
local function extract_rg_file(line)
    local p1 = line:find(":", 1, true)
    if not p1 then return nil end
    local p2 = line:find(":", p1 + 1, true)
    if not p2 then return nil end
    local p3 = line:find(":", p2 + 1, true)
    if not p3 then return nil end
    return line:sub(1, p1 - 1)
end
```

**4b.** Deduplicate by file path instead of full line:

```lua
-- Before (AND case):
for _, line in ipairs(left_results) do
    if common[extract_rg_file(line)] then
        if not seen[line] then
            seen[line] = true
            result[#result + 1] = line
        end
    end
end

-- After:
local file_seen = {}
for _, line in ipairs(left_results) do
    local file = extract_rg_file(line)
    if common[file] then
        if not file_seen[file] then
            file_seen[file] = true
        end
        result[#result + 1] = line
    end
end
```

### Expected Performance Improvement

- **4a:** ~2x faster file extraction (plain find vs regex) for large result sets
- **4b:** Reduced memory: hash keys are file paths (~50 bytes) instead of full
  lines (~200 bytes). For 1000 results: ~150KB saved.

### Risk Assessment

- **4a:** The plain-find approach assumes ripgrep output format `file:line:col:`.
  This is the default `--vimgrep` format and is stable.
- **4b:** Changing from line-level to file-level dedup means duplicate lines from
  the same file are preserved. This matches the expected behavior (show all
  matches, not just first per file).

---

## Implementation Order

| Priority | Optimization | Effort | Impact | Risk |
|----------|-------------|--------|--------|------|
| 1 | Cached date parsing (#1) | Low | High | Low |
| 2 | Ripgrep output processing (#3) | Low | Medium | Low |
| 3 | Incremental live search (#2) | High | High | Medium |

#1 is a simple addition to the parser with immediate benefits across all
date-based search queries. #3 is straightforward cleanup. #2 is the most
complex but delivers the biggest UX improvement for live search.

---

## Testing Strategy

### Cached Date Parsing (#1)
1. Run `created:>2024-01` search. Verify results match before/after.
2. Modify a file's frontmatter date. Rebuild index. Verify new date is used.

### Incremental Live Search (#2)
1. Open live search. Type `task-due:>7d` one character at a time.
2. Verify results narrow correctly with each keystroke.
3. Backspace to `task-due:>7`. Verify full re-eval produces correct results.
4. Type an OR query. Verify full re-eval on every keystroke (no incremental).

### Ripgrep Processing (#3)
1. Run a search with 1000+ results. Verify output is identical before/after.
2. Run an AND query (`term1 AND term2`). Verify correct intersection.

---

## Related Documents

- Pre-computed lowercase fields (originally optimization #1 in this document)
  have been consolidated into doc 58-parser-single-pass-optimization.md as
  optimization #3, since they are parser-level precomputations.
- Doc 55-search-filter-precomputation covers FilterContext-level precomputation
  (complementary to the cached date parsing in #1 here).
