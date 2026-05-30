# 13 -- Result Grouping in Search

## Current State

The advanced search system (`search.lua`, `search_filter.lua`, `search_query.lua`) evaluates parsed ASTs against the vault index and ripgrep, producing a flat array of result entries. These entries are passed directly to `fzf.fzf_exec()` without any structural organization:

```lua
-- search.lua, line 223
fzf.fzf_exec(result.entries, fzf_opts)
```

The `resolve_query()` function (search.lua lines 95-164) returns entries in one of two forms:

1. **Metadata-only results**: sorted `rel_path` strings (e.g., `Projects/Alpha/Dashboard.md`)
2. **Text/ripgrep results**: raw ripgrep output lines (e.g., `Projects/Alpha/Dashboard.md:15:3:some matched text`)
3. **Mixed OR results**: a combination of bare rel_path strings and ripgrep lines

### How Results Flow

```
parse_query(query_string) --> AST
        |
split_ast(ast) --> { metadata_ast, text_ast, mode }
        |
resolve_query(split, idx, vault_path)
        |
        +-- metadata_only:       sorted rel_paths
        +-- text_only:            ripgrep lines
        +-- metadata_then_text:   ripgrep lines (or fallback rel_paths)
        +-- mixed_or:             union of rel_paths + ripgrep lines
        |
        v
fzf.fzf_exec(result.entries, fzf_opts)  -- flat, ungrouped
```

### What Users See

A flat list of files or grep matches with no visual separation. When searching for `type:meeting tag:project/active`, results from different projects are interleaved. When searching for text across the vault, results from Log/, Projects/, and Areas/ are mixed together. There is no way to see at a glance how results distribute across folders, types, dates, or tags.

### Related Modules

| Module | File | Relevance |
|--------|------|-----------|
| `search.lua` | `lua/andrew/vault/search.lua` | Entry point: `resolve_query()`, `execute_advanced_query()`, `search_advanced_live()` |
| `search_filter.lua` | `lua/andrew/vault/search_filter.lua` | AST evaluation, metadata matching, ripgrep dispatch |
| `search_query.lua` | `lua/andrew/vault/search_query.lua` | Tokenizer and recursive descent parser |
| `vault_index.lua` | `lua/andrew/vault/vault_index.lua` | VaultIndexEntry with folder, tags, frontmatter.type, mtime, day |
| `config.lua` | `lua/andrew/vault/config.lua` | `M.search` section, `M.dirs`, `M.note_types`, `M.scopes` |
| `engine.lua` | `lua/andrew/vault/engine.lua` | `vault_fzf_opts()`, `vault_fzf_actions()`, vault path resolution |
| `connections.lua` | `lua/andrew/vault/connections.lua` | Existing ANSI formatting pattern for fzf_exec entries (lines 494-534) |
| `tags.lua` | `lua/andrew/vault/tags.lua` | Existing `--ansi`, `--delimiter`, `--with-nth` fzf_opts pattern |
| `query/executor.lua` | `lua/andrew/vault/query/executor.lua` | `apply_group_by()` at line 1023 -- GROUP BY logic for DQL queries |

### Existing Grouping Precedent

The DQL query system already supports `GROUP BY` via `query/executor.lua:apply_group_by()` (lines 1023-1043). It groups pages into `{ key, pages[] }` buckets and renders them with section headers in code block output. The search system has no equivalent.

---

## Problem

1. **No visual structure**: Large result sets (50+ matches) are overwhelming as a flat list. Users must mentally parse file paths to understand the distribution.
2. **No grouping by metadata**: The vault index contains rich metadata (folder, type, tags, modification date) that could organize results into meaningful sections, but none of it is used for display structure.
3. **No user control**: There is no syntax or option to request grouping by a specific field. The only ordering is whatever ripgrep or `table.sort` produces.
4. **fzf supports it**: fzf 0.68 (installed) supports `--gap[=N]` and `--gap-line[=STR]` for visual separation between groups, plus `--ansi` for colored section headers. These features are unused.

---

## Goal

Add result grouping to the advanced search system so that:

1. Users can group results by **folder**, **type**, **tag**, **date** (modified/created), or any frontmatter field.
2. Group headers appear as visually distinct, non-matchable separator lines in the fzf picker.
3. Grouping can be requested via query syntax (`group:folder`) or a toggle keymap in the fzf UI.
4. The live mode (`search_advanced_live`) supports grouping with minimal performance overhead.
5. The implementation reuses the vault index metadata already available from `resolve_query()`.

---

## Proposed Changes

### 1. New Module: `search_group.lua`

Create `lua/andrew/vault/search_group.lua` -- a pure grouping/sorting utility with no UI dependencies.

```lua
--- Search result grouping for advanced vault search.
---
--- Takes flat result entries (rel_paths or ripgrep lines) and the vault index,
--- groups them by a specified field, and returns an ordered list with
--- ANSI-formatted group header lines interleaved.

local M = {}

local config = require("andrew.vault.config")
local date_utils = require("andrew.vault.date_utils")

--- ANSI escape codes (shared with connections.lua pattern).
local ANSI = {
  reset   = "\27[0m",
  dim     = "\27[2m",
  bold    = "\27[1m",
  yellow  = "\27[33m",
  green   = "\27[32m",
  blue    = "\27[34m",
  cyan    = "\27[36m",
  magenta = "\27[35m",
  underline = "\27[4m",
}

--- Sentinel prefix for group header lines.
--- Used to identify and skip headers in fzf actions.
M.HEADER_PREFIX = "\x01\x01"

--- Supported grouping modes.
M.MODES = {
  "folder",    -- group by parent folder
  "type",      -- group by frontmatter type
  "tag",       -- group by first tag (or specified tag prefix)
  "date",      -- group by modification date (YYYY-MM-DD)
  "month",     -- group by modification month (YYYY-MM)
  "created",   -- group by creation date
  "status",    -- group by frontmatter status
  "none",      -- no grouping (passthrough)
}
```

#### Core Data Structures

```lua
---@class GroupSpec
---@field mode string       one of M.MODES
---@field field? string     for "tag": prefix filter; for generic: frontmatter field name
---@field reverse? boolean  reverse group order (newest first for dates)

---@class GroupResult
---@field entries string[]      interleaved headers + entries for fzf_exec
---@field group_count number    number of distinct groups
---@field total_count number    number of actual result entries (excluding headers)
```

#### Key Functions

**`extract_file_path(entry)`** -- Extract the file path from either a bare rel_path or a ripgrep line.

```lua
--- Extract the vault-relative file path from a result entry.
---@param entry string  either "rel/path.md" or "rel/path.md:10:5:matched text"
---@return string rel_path
function M.extract_file_path(entry)
  return entry:match("^(.-):%d+:%d+:") or entry
end
```

**`resolve_group_key(entry, mode, idx)`** -- Determine which group a result belongs to.

```lua
--- Resolve the group key for a single result entry.
---@param rel_path string    vault-relative path
---@param mode string        grouping mode
---@param idx VaultIndex     vault index instance
---@param spec? GroupSpec    additional options
---@return string key        group key (used for sorting/bucketing)
---@return string label      human-readable group label
function M.resolve_group_key(rel_path, mode, idx, spec)
  local file_entry = idx.files[rel_path]

  if mode == "folder" then
    local folder = file_entry and file_entry.folder or rel_path:match("^(.+)/[^/]+$") or ""
    if folder == "" then folder = "(root)" end
    return folder, folder
  end

  if mode == "type" then
    local t = file_entry and file_entry.frontmatter and file_entry.frontmatter.type
    if not t or t == "" then return "\xff(no type)", "(no type)" end
    return t:lower(), t
  end

  if mode == "tag" then
    if not file_entry or not file_entry.tags or #file_entry.tags == 0 then
      return "\xff(untagged)", "(untagged)"
    end
    local prefix = spec and spec.field
    if prefix then
      -- Find the first tag matching the prefix
      for _, tag in ipairs(file_entry.tags) do
        if tag:sub(1, #prefix) == prefix then
          return tag, tag
        end
      end
      return "\xff(no " .. prefix .. " tag)", "(no " .. prefix .. " tag)"
    end
    -- Use the first tag as the group key
    local first = file_entry.tags[1]
    -- Use the top-level prefix for grouping (e.g., "project" from "project/active")
    local top = first:match("^([^/]+)") or first
    return top, top
  end

  if mode == "date" or mode == "month" then
    local ts = file_entry and file_entry.mtime
    if not ts then return "\xff(unknown date)", "(unknown date)" end
    if mode == "date" then
      local d = os.date("%Y-%m-%d", ts)
      return d, d
    else
      local m = os.date("%Y-%m", ts)
      return m, os.date("%B %Y", ts)
    end
  end

  if mode == "created" then
    local ts
    if file_entry then
      ts = file_entry.ctime or file_entry.mtime
      if file_entry.frontmatter and file_entry.frontmatter.created then
        ts = date_utils.parse_iso_datetime(file_entry.frontmatter.created) or ts
      end
    end
    if not ts then return "\xff(unknown)", "(unknown)" end
    local d = os.date("%Y-%m-%d", ts)
    return d, d
  end

  if mode == "status" then
    local s = file_entry and (
      (file_entry.frontmatter and file_entry.frontmatter.status)
      or (file_entry.inline_fields and file_entry.inline_fields.status)
    )
    if not s or s == "" then return "\xff(no status)", "(no status)" end
    return s:lower(), s
  end

  -- Generic: try frontmatter field
  if file_entry and file_entry.frontmatter and file_entry.frontmatter[mode] then
    local v = tostring(file_entry.frontmatter[mode])
    return v:lower(), v
  end

  return "\xff(unknown)", "(unknown)"
end
```

**`group_entries(entries, mode, idx, spec)`** -- The main grouping function.

```lua
--- Group flat result entries by the specified mode.
---
--- Returns a GroupResult with interleaved ANSI-formatted header lines
--- and original entry lines, ready for fzf_exec.
---
---@param entries string[]    flat result entries from resolve_query()
---@param mode string         grouping mode (one of M.MODES)
---@param idx VaultIndex      vault index instance
---@param spec? GroupSpec     additional grouping options
---@return GroupResult
function M.group_entries(entries, mode, idx, spec)
  spec = spec or {}

  if mode == "none" or not mode then
    return { entries = entries, group_count = 0, total_count = #entries }
  end

  -- Phase 1: Bucket entries by group key
  local buckets = {}      -- key -> { label, entries[] }
  local key_order = {}    -- insertion-ordered keys
  local key_seen = {}

  for _, entry in ipairs(entries) do
    local rel_path = M.extract_file_path(entry)
    local key, label = M.resolve_group_key(rel_path, mode, idx, spec)

    if not key_seen[key] then
      key_seen[key] = true
      key_order[#key_order + 1] = key
      buckets[key] = { label = label, entries = {} }
    end
    local bucket = buckets[key]
    bucket.entries[#bucket.entries + 1] = entry
  end

  -- Phase 2: Sort groups
  if mode == "date" or mode == "month" or mode == "created" then
    -- Date modes: sort newest first by default
    local reverse = spec.reverse ~= false  -- default true for dates
    table.sort(key_order, function(a, b)
      if reverse then return a > b else return a < b end
    end)
  else
    -- Alphabetical, but push "\xff..." sentinel keys to the end
    table.sort(key_order, function(a, b)
      local a_sentinel = a:sub(1, 1) == "\xff"
      local b_sentinel = b:sub(1, 1) == "\xff"
      if a_sentinel ~= b_sentinel then return b_sentinel end
      return a < b
    end)
  end

  -- Phase 3: Interleave headers and entries
  local result = {}
  local group_count = #key_order

  for i, key in ipairs(key_order) do
    local bucket = buckets[key]
    local count = #bucket.entries
    local header = string.format(
      "%s%s%s%s  %s(%d)%s",
      M.HEADER_PREFIX,
      ANSI.bold, ANSI.blue, bucket.label,
      ANSI.dim, count, ANSI.reset
    )
    result[#result + 1] = header

    for _, entry in ipairs(bucket.entries) do
      result[#result + 1] = entry
    end
  end

  return {
    entries = result,
    group_count = group_count,
    total_count = #entries,
  }
end
```

**`is_header(line)`** -- Check if an fzf entry is a group header (used by actions to skip).

```lua
--- Check if a selected fzf line is a group header (non-file entry).
---@param line string
---@return boolean
function M.is_header(line)
  return line:sub(1, #M.HEADER_PREFIX) == M.HEADER_PREFIX
end
```

### 2. Query Syntax Extension

Add a `group:` prefix to the search query tokenizer. This is a display directive, not a filter, so it is extracted before AST evaluation and does not participate in the boolean tree.

#### Changes to `search_query.lua`

Add a new token type and parsing rule:

```lua
-- search_query.lua, new token type (add to M.TK table, line 14)
M.TK.GROUP = "GROUP"

-- In tokenize(), within the field detection block (around line 211):
-- Before the generic field check, detect group:value
if name == "group" then
  return token(TK.GROUP, raw_value:lower(), pos)
end
```

The parser must extract `GROUP` tokens before building the AST. They are directives, not predicates:

```lua
-- search_query.lua, new function
--- Extract group: directives from a token list.
--- Removes GROUP tokens in-place and returns the group mode.
---@param tokens table[] token list
---@return string|nil group_mode
function M.extract_group(tokens)
  local mode = nil
  local filtered = {}
  for _, tok in ipairs(tokens) do
    if tok.type == TK.GROUP then
      mode = tok.value
    else
      filtered[#filtered + 1] = tok
    end
  end
  -- Replace tokens in-place
  for i = 1, math.max(#tokens, #filtered) do
    tokens[i] = filtered[i]
  end
  return mode
end
```

Update `parse_query()` to return the group mode alongside the AST:

```lua
--- Convenience wrapper: tokenize and parse a query string in one call.
---@param query_string string
---@return table|nil ast, string|nil error, string|nil group_mode
function M.parse_query(query_string)
  if type(query_string) ~= "string" or query_string:match("^%s*$") then
    return nil, "Empty query"
  end
  local tokens, tok_err = M.tokenize(query_string)
  if not tokens then return nil, tok_err end
  local group_mode = M.extract_group(tokens)
  local ast, parse_err = M.parse(tokens)
  return ast, parse_err, group_mode
end
```

#### Syntax Examples

```
type:meeting group:folder           -- meetings grouped by folder
tag:project/active group:type       -- active project notes grouped by type
modified:last-7d group:date         -- recent notes grouped by modification date
deploy group:month                  -- text search grouped by month
tag:status group:status             -- notes by status tag, grouped by status field
priority:>3 group:tag               -- high priority grouped by top-level tag
```

### 3. Integration into `search.lua`

#### Changes to `resolve_query()`

The `resolve_query()` function (lines 95-164) gains a `group_mode` parameter. After computing entries, it applies grouping if requested:

```lua
--- Evaluate a split AST against the vault index and ripgrep, returning display entries.
---@param split table from search_filter.split_ast()
---@param idx table VaultIndex instance
---@param vault_path string
---@param group_mode? string  optional grouping mode from group: directive
---@return table { entries, needs_previewer, metadata_fallback?, group_count? }
local function resolve_query(split, idx, vault_path, group_mode)
  local search_filter = require("andrew.vault.search_filter")

  -- ... existing mode dispatch (unchanged) ...
  -- After computing the base result:

  -- Apply grouping if requested
  if group_mode and group_mode ~= "none" then
    local search_group = require("andrew.vault.search_group")
    local grouped = search_group.group_entries(result.entries, group_mode, idx)
    result.entries = grouped.entries
    result.group_count = grouped.group_count
  end

  return result
end
```

#### Changes to `execute_advanced_query()`

Update to thread `group_mode` through parsing and into fzf options:

```lua
function M.execute_advanced_query(query_string, opts)
  opts = opts or {}
  local search_query = require("andrew.vault.search_query")
  local search_filter = require("andrew.vault.search_filter")
  local vault_index = require("andrew.vault.vault_index")
  local fzf = require("fzf-lua")

  -- parse_query now returns group_mode as third value
  local ast, err, group_mode = search_query.parse_query(query_string)
  if not ast then
    if not opts.silent then
      vim.notify("Search parse error: " .. (err or "unknown"), vim.log.levels.ERROR)
    end
    return
  end

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    -- ... existing fallback (unchanged) ...
    return
  end

  local split = search_filter.split_ast(ast)
  local result = resolve_query(split, idx, engine.vault_path, group_mode)

  if #result.entries == 0 then
    if not opts.silent then
      vim.notify("Advanced search: no matches", vim.log.levels.INFO)
    end
    return
  end

  -- ... existing metadata_fallback notification ...

  local actions = engine.vault_fzf_actions()
  actions["ctrl-/"] = { fn = function() M.search_help() end, reload = false }

  -- Wrap default action to skip group headers
  if group_mode then
    local search_group = require("andrew.vault.search_group")
    local orig_default = actions["default"]
    actions["default"] = function(selected, fzf_opts_inner)
      if selected then
        local filtered = {}
        for _, line in ipairs(selected) do
          if not search_group.is_header(line) then
            filtered[#filtered + 1] = line
          end
        end
        if #filtered > 0 then
          orig_default(filtered, fzf_opts_inner)
        end
      end
    end
  end

  local fzf_opts = vim.tbl_extend("force",
    engine.vault_fzf_opts("Advanced search"),
    {
      actions = actions,
      fzf_opts = {
        ["--header"] = SEARCH_HEADER,
        ["--ansi"] = "",
      },
    }
  )

  -- When grouped, disable fzf sorting to preserve group order
  if group_mode then
    fzf_opts.fzf_opts["--no-sort"] = ""
  end

  if result.needs_previewer then
    fzf_opts.previewer = "builtin"
  end

  fzf.fzf_exec(result.entries, fzf_opts)
end
```

#### Changes to `search_advanced_live()`

The live mode provider re-evaluates on each keystroke. Grouping is extracted once from the query and applied to each result set:

```lua
function M.search_advanced_live()
  local search_query = require("andrew.vault.search_query")
  local search_filter = require("andrew.vault.search_filter")
  local search_group = require("andrew.vault.search_group")
  local vault_index = require("andrew.vault.vault_index")
  local fzf = require("fzf-lua")

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    vim.notify("Vault index not ready for advanced live search.", vim.log.levels.WARN)
    return
  end

  local debounce = config.search and config.search.live_debounce_ms or 150
  local last_live_query = ""

  fzf.fzf_live(function(args)
    local query_string = type(args) == "table" and args[1] or args
    if type(query_string) ~= "string" or query_string == "" then return {} end
    last_live_query = query_string

    local ast, _, group_mode = search_query.parse_query(query_string)
    if not ast then return {} end

    local split = search_filter.split_ast(ast)
    local result = resolve_query(split, idx, engine.vault_path, group_mode)
    return result.entries
  end, vim.tbl_extend("force",
    engine.vault_fzf_opts("Advanced live search"),
    {
      actions = {
        ["default"] = function(selected, fzf_opts)
          if last_live_query ~= "" then
            track(last_live_query, "all", "advanced", true)
          end
          -- Filter out header lines before opening
          if selected then
            local filtered = {}
            for _, line in ipairs(selected) do
              if not search_group.is_header(line) then
                filtered[#filtered + 1] = line
              end
            end
            if #filtered > 0 then
              require("fzf-lua").actions.file_edit(filtered, fzf_opts)
            end
          end
        end,
        ["ctrl-/"] = { fn = function() M.search_help() end, reload = false },
        ["ctrl-s"] = require("fzf-lua").actions.file_split,
        ["ctrl-v"] = require("fzf-lua").actions.file_vsplit,
        ["ctrl-t"] = require("fzf-lua").actions.file_tabedit,
      },
      fzf_opts = {
        ["--header"] = SEARCH_HEADER,
        ["--ansi"] = "",
        ["--no-sort"] = "",  -- preserve group order when grouping is active
      },
      previewer = "builtin",
      exec_empty_query = false,
      query_delay = debounce,
    }
  ))
end
```

**Performance note for live mode**: The grouping step iterates all entries once to bucket them, then concatenates. For 500 results with 10 groups, this adds ~1ms. Well within the 200ms performance budget documented in `advanced_search/08-ui-integration.md`.

### 4. Configuration

Add grouping defaults to `config.lua`:

```lua
-- config.lua, inside M.search (after line 342)

-- Result grouping
grouping = {
  -- Default group mode when no group: directive is specified.
  -- Set to "none" to disable grouping by default.
  -- Set to "folder" to always group by folder, etc.
  default_mode = "none",

  -- Header format: "ansi" uses colored bold text, "plain" uses simple text.
  header_style = "ansi",

  -- Sort groups alphabetically or by count (most results first).
  -- "alpha" or "count"
  group_sort = "alpha",

  -- For date/month grouping: show newest first by default.
  date_newest_first = true,

  -- Maximum number of groups to display.
  -- Groups beyond this limit are collapsed into "(N more groups...)".
  max_groups = 50,

  -- Tag grouping: use top-level prefix ("project" from "project/active")
  -- or full tag path. "prefix" or "full".
  tag_level = "prefix",
},
```

### 5. Completion Updates

Add `group:` to the completion candidates in `_complete_advanced()` (search.lua lines 462-546):

```lua
-- After the "has:" completion block (around line 504)

-- After group: suggest grouping modes
if lead:match("^group:") then
  local prefix = "group:"
  local rest = lead:sub(#prefix + 1)
  local search_group = require("andrew.vault.search_group")
  for _, mode in ipairs(search_group.MODES) do
    if mode:sub(1, #rest) == rest then
      candidates[#candidates + 1] = prefix .. mode
    end
  end
end
```

Also add `"group"` to the special prefix list (around line 480):

```lua
for _, prefix in ipairs({ "has:", "task:", "task-todo:", "task-done:", "group:" }) do
```

### 6. Search Help Updates

Add grouping to the search help float (search.lua `search_help()`, around line 417):

```lua
-- Add after the "Boolean Operators" section:
"",
"Grouping:",
"  group:folder             Group by parent folder",
"  group:type               Group by frontmatter type",
"  group:tag                Group by top-level tag",
"  group:date               Group by modification date",
"  group:month              Group by modification month",
"  group:created            Group by creation date",
"  group:status             Group by status field",
```

---

## Implementation Plan

### Phase 1: Core Grouping Module

1. Create `lua/andrew/vault/search_group.lua` with:
   - `HEADER_PREFIX` sentinel constant
   - `MODES` list
   - `extract_file_path()` helper
   - `resolve_group_key()` for each mode
   - `group_entries()` main function
   - `is_header()` predicate

2. Write unit tests verifying:
   - Each group mode produces correct keys
   - Sentinel keys sort to end
   - Date modes default to newest-first
   - Header lines contain the sentinel prefix
   - `is_header()` correctly identifies headers

### Phase 2: Query Syntax

3. Add `GROUP` token type to `search_query.lua`:
   - New `TK.GROUP` constant
   - Detection in `parse_field_token()` (return GROUP token when name is "group")
   - `extract_group()` to strip GROUP tokens before parsing
   - Update `parse_query()` to return `(ast, error, group_mode)` triple

4. Verify existing tests still pass (GROUP tokens are removed before AST construction, so no existing behavior changes).

### Phase 3: Prompt Mode Integration

5. Update `resolve_query()` in `search.lua`:
   - Add `group_mode` parameter
   - Call `search_group.group_entries()` when group_mode is set

6. Update `execute_advanced_query()` in `search.lua`:
   - Thread `group_mode` from `parse_query()` through to `resolve_query()`
   - Add `--ansi` and `--no-sort` to fzf_opts when grouped
   - Wrap default action to filter out header lines via `is_header()`

### Phase 4: Live Mode Integration

7. Update `search_advanced_live()` in `search.lua`:
   - Extract `group_mode` from parsed query in the provider function
   - Pass through to `resolve_query()`
   - Filter headers in the default action

### Phase 5: Completion and Help

8. Update `_complete_advanced()`:
   - Add `group:` prefix to special prefixes
   - Add mode-specific completions after `group:`

9. Update `search_help()`:
   - Add grouping section to the help float

### Phase 6: Configuration

10. Add `M.search.grouping` to `config.lua`
11. Wire `config.search.grouping.default_mode` into `resolve_query()` as fallback when no `group:` directive is present but default is non-"none"

---

## Edge Cases and Considerations

### Header Lines Must Not Be Selectable as Files

When a user presses Enter on a group header, the action should be a no-op or skip to the next actual entry. The `is_header()` check in the wrapped default action handles this. For multi-select (`ctrl-q`), all headers must be filtered out of the selection set.

The sentinel prefix (`\x01\x01`) is chosen because:
- It is not a valid start for any file path
- It will not match any fzf query the user types
- It sorts before any real content

### Ripgrep Lines vs. Bare Paths

`extract_file_path()` must handle both formats. The regex `^(.-):%d+:%d+:` extracts the file path from ripgrep output. For bare paths (metadata-only results), it returns the path unchanged. **Important**: ripgrep lines already include the matched text -- grouping should not strip or alter that.

### Index Readiness

If the vault index is not ready when grouping is requested, `resolve_group_key()` falls back to path-based extraction (parsing folder from the rel_path string). This ensures grouping by folder always works even without the index. Type, tag, date, and status grouping require the index and will produce `(unknown)` fallback groups.

### Performance

- **Metadata-only (500 results)**: grouping adds ~1ms (one pass to bucket, one pass to interleave)
- **Ripgrep results (2000 lines)**: grouping adds ~3ms (path extraction regex is the bottleneck)
- **Live mode**: grouping is inside the provider function, called on each debounced keystroke. The 1-3ms overhead is negligible against the 150ms debounce and ripgrep execution time.

### `--no-sort` Trade-off

When grouping is active, `--no-sort` is required to preserve group order. This means fzf's fuzzy matching will still highlight matches, but the result order will be by group rather than by match quality. This is the expected behavior: the user explicitly asked for grouped display.

When no `group:` directive is present and `default_mode` is "none", `--no-sort` is not set, preserving normal fzf behavior.

### Multi-Value Fields (Tags)

A note can have multiple tags. For `group:tag`, each note appears in **one** group only (determined by its first tag or the first tag matching a prefix). Duplicating entries across multiple groups would be confusing and inflate counts. This differs from the DQL `GROUP BY` which flattens lists -- the search grouping is for display, not aggregation.

### Group Header Format

Headers are formatted as:

```
[sentinel]  [ANSI bold+blue]GroupLabel  [ANSI dim](count)[ANSI reset]
```

For example:
```
Projects/Alpha  (12)
Log  (8)
Areas/Research  (5)
(root)  (2)
```

The sentinel prefix is invisible (control characters) and consumed by `is_header()`. The ANSI codes require `--ansi` in fzf_opts (already set by the connections.lua pattern).

### Previewer Compatibility

Group header lines do not correspond to files, so the built-in previewer will show nothing or an error when the cursor is on a header. This is acceptable: users will navigate to actual entries for preview. If needed in the future, a custom previewer could detect headers and show group metadata instead.

### Saved Searches

The `group:` directive is part of the query string stored by `saved_searches.lua`. When a saved search is executed via `execute_advanced_query()`, the group mode is automatically extracted and applied. No changes needed to saved_searches.lua.

### Interaction with `metadata_fallback`

When `resolve_query()` falls back to metadata matches (text filter returned 0 results), the entries are bare rel_paths. Grouping works identically on these.

---

## Testing Strategy

### Unit Tests (search_group.lua)

```lua
-- test: extract_file_path handles both formats
assert(M.extract_file_path("Projects/A.md") == "Projects/A.md")
assert(M.extract_file_path("Projects/A.md:10:5:text") == "Projects/A.md")

-- test: resolve_group_key folder mode
-- (with mock index entry where folder = "Projects/Alpha")
assert(key == "Projects/Alpha")

-- test: resolve_group_key type mode with missing type
assert(key == "\xff(no type)" and label == "(no type)")

-- test: group_entries produces correct structure
local result = M.group_entries(entries, "folder", idx)
assert(result.group_count == 3)
assert(result.total_count == 10)
-- First entry should be a header
assert(M.is_header(result.entries[1]))
-- Second entry should be a real result
assert(not M.is_header(result.entries[2]))

-- test: date grouping sorts newest first
local result = M.group_entries(entries, "date", idx)
-- First header should be the most recent date
assert(result.entries[1]:find("2026%-02%-27"))

-- test: none mode returns entries unchanged
local result = M.group_entries(entries, "none", idx)
assert(result.entries == entries)

-- test: is_header sentinel detection
assert(M.is_header("\x01\x01bold header text"))
assert(not M.is_header("Projects/A.md:10:5:text"))
assert(not M.is_header("Projects/A.md"))
```

### Unit Tests (search_query.lua -- GROUP token)

```lua
-- test: group: tokenizes as GROUP
local tokens = M.tokenize("type:meeting group:folder")
assert(tokens[1].type == "FIELD")
assert(tokens[2].type == "GROUP")
assert(tokens[2].value == "folder")

-- test: extract_group removes GROUP tokens
local tokens = M.tokenize("type:meeting group:folder deploy")
local mode = M.extract_group(tokens)
assert(mode == "folder")
-- tokens should now have FIELD, TEXT, EOF (no GROUP)
assert(#tokens == 3)

-- test: parse_query returns group_mode
local ast, err, gm = M.parse_query("type:meeting group:folder")
assert(ast)
assert(gm == "folder")
-- AST should only contain type:meeting, not group:folder
assert(ast.type == "field")
assert(ast.name == "type")
```

### Integration Tests (search.lua)

Manual testing in Neovim:

1. `:VaultSearchAdvanced` with query `type:meeting group:folder`
   - Verify results are grouped by folder with headers
   - Verify pressing Enter on a header does nothing
   - Verify pressing Enter on a result opens the file

2. `:VaultSearchAdvancedLive` with query `deploy group:type`
   - Verify live updating works with grouping
   - Verify groups update as the query changes
   - Verify removing `group:type` returns to flat display

3. Test each group mode:
   - `group:folder` -- headers should be folder paths
   - `group:type` -- headers should be frontmatter type values
   - `group:tag` -- headers should be top-level tag prefixes
   - `group:date` -- headers should be YYYY-MM-DD, newest first
   - `group:month` -- headers should be "Month Year", newest first
   - `group:status` -- headers should be status values
   - `group:none` -- no headers, flat list

4. Edge cases:
   - Query with only `group:folder` (no filters) -- should show all files grouped
   - Query returning 0 results with group: -- "no matches" notification, no crash
   - Empty vault index -- graceful fallback
   - Saved search with group: -- verify it persists and replays correctly

### Completion Tests

1. Type `group:` in the advanced search prompt and press Tab
   - Should show: folder, type, tag, date, month, created, status, none

2. Type `group:f` and press Tab
   - Should complete to `group:folder`

---

## File Summary

| File | Action | Description |
|------|--------|-------------|
| `lua/andrew/vault/search_group.lua` | **Create** | Grouping module: bucketing, headers, ANSI formatting |
| `lua/andrew/vault/search_query.lua` | **Modify** | Add GROUP token type, `extract_group()`, update `parse_query()` return |
| `lua/andrew/vault/search.lua` | **Modify** | Thread group_mode through resolve_query, wrap fzf actions, update completions and help |
| `lua/andrew/vault/config.lua` | **Modify** | Add `M.search.grouping` configuration section |
