# Advanced Search Operators

## Problem Statement

The vault's search capabilities are currently limited to plain ripgrep pattern
matching via fzf-lua. While ripgrep excels at fast full-text search, it has no
understanding of vault metadata. Users cannot combine text searches with
structured filters like frontmatter fields, tags, inline fields, or date ranges
-- all of which the vault index already tracks.

### What Obsidian Search Offers

Obsidian's built-in search supports:
- **Boolean operators:** `AND`, `OR`, `-` (NOT) to combine terms
- **Field filters:** `tag:#project`, `path:Projects/`, `file:Dashboard`,
  `section:heading`, `line:exact phrase`, `content:text`
- **Property filters:** `[type:meeting]`, `[status:active]`, `[priority:1]`
- **Task filters:** `task:""`, `task-todo:""`, `task-done:""`
- **Date filters:** On `created` and `modified` fields via Obsidian properties
- **Regex support:** `/regex pattern/`
- **Grouping:** Parentheses for complex boolean expressions

### Current Limitations

1. **No boolean logic.** A search for `meeting AND urgent` cannot be expressed.
   Users must either use a regex alternation or run separate searches.
2. **No metadata filtering.** Searching for "all notes of type `meeting` with
   tag `#project/active`" requires two manual steps: first `VaultSearchType`,
   then manually scanning results for the tag.
3. **No date range queries.** Finding notes modified in the last 7 days requires
   leaving Neovim and using shell commands.
4. **No field-aware search.** There is no way to filter by inline field values
   (e.g., `status::In Progress`) from the search interface.
5. **Saved searches are text-only.** The saved search system stores raw ripgrep
   patterns and a scope, but cannot persist structured queries with metadata
   filters.

## Current Architecture

### search.lua

`search.lua` is a thin wrapper around fzf-lua's `live_grep` and `grep` APIs.
It provides four entry points:

- **`search()`** -- Live grep across all files in the vault. Calls
  `fzf.live_grep(engine.vault_fzf_opts("Vault search"))`.
- **`search_notes()`** -- Live grep restricted to `*.md` files via
  `engine.rg_base_opts()`.
- **`search_filtered()`** -- Prompts the user to select a scope (from
  `config.scopes`), then runs `live_grep` with the scope's glob pattern.
- **`search_by_type()`** -- Prompts for a note type (from `config.note_types`),
  then runs `fzf.grep` with a frontmatter regex `^type:\s+<choice>`.

Every search function delegates to fzf-lua, passing `cwd = engine.vault_path`
and ripgrep options built by `engine.rg_base_opts(glob)`. The ripgrep options
are: `--column --line-number --no-heading --color=always --smart-case --glob "*.md"`.

All search functions call `track(query, scope, search_type)` to record the
query for the saved search quick-save feature.

### saved_searches.lua

Persists saved searches as a JSON array in `.vault-searches.json` at the vault
root. Each entry has `{ name, query, scope, type }` where `type` is "grep" or
"type". Supports:
- `save(name, query, scope, search_type)` -- upsert by name
- `list()` -- fzf picker to select and execute a saved search
- `delete(name)` / `pick_delete()` -- removal
- `save_last()` / `save_interactive()` -- prompt-based creation
- `set_last_search(query, scope, search_type)` -- called by search.lua

Execution (`execute_search`) branches on `entry.type`:
- `"type"` -- runs `fzf.grep` with `^type:\s+<query>` pattern
- `""` query -- runs `fzf.live_grep` (interactive)
- Non-empty query -- runs `fzf.grep` with the stored pattern

### vault_index.lua (searchable metadata)

The unified persistent vault index stores per-file entries with the following
metadata relevant to search:

```lua
---@class VaultIndexEntry
---@field rel_path string       -- "Projects/Alpha/Dashboard.md"
---@field abs_path string       -- absolute path
---@field basename string       -- "Dashboard"
---@field basename_lower string -- "dashboard"
---@field folder string         -- "Projects/Alpha"
---@field mtime number          -- seconds since epoch
---@field size number           -- bytes
---@field ctime number|nil      -- creation time (birthtime, may be nil)
---@field frontmatter table     -- parsed YAML: { type = "meeting", status = "active", ... }
---@field aliases string[]      -- lowercased aliases
---@field tags string[]         -- all tags with parent expansion
---@field headings VaultHeading[] -- { text, slug, level, line }
---@field heading_slugs table   -- slug -> true
---@field block_ids string[]    -- without ^ prefix
---@field outlinks VaultLink[]  -- { path, display, embed }
---@field tasks VaultTask[]     -- { text, status, completed, line, tags }
---@field inline_fields table   -- { key = value, ... }
---@field day string|nil        -- "YYYY-MM-DD" from filename
```

The index also maintains derived lookup tables:
- `_name_index`: lowercase name -> [abs_paths]
- `_alias_index`: lowercase alias -> [abs_paths]
- `_inlinks`: rel_path -> inbound link entries

This metadata is immediately available in-memory (no disk I/O) and can be used
for instant structured filtering before or after text search.

### engine.lua (fzf helpers)

- `rg_base_opts(glob)` -- builds ripgrep command-line flags
- `vault_fzf_opts(prompt, extra)` -- builds fzf-lua config with `cwd`, prompt
- `vault_fzf_actions()` -- standard file open/split/vsplit/tab actions

### config.lua (relevant sections)

- `config.scopes` -- search scope definitions with key, label, glob
- `config.note_types` -- list of frontmatter `type` values
- `config.status_values`, `config.priority_values`, `config.maturity_values`
  -- canonical field value lists

### pickers.lua

Handles project/area/domain picker interactions. Not directly involved in
search but demonstrates the pattern of fzf-lua-based selection with
`fzf.fzf_exec()`.

## Proposed Solution

### Architecture Overview

Introduce a **query parser** that transforms a structured query string into an
AST, and a **filter pipeline** that evaluates the AST against vault index
entries. Text-matching terms are dispatched to ripgrep for content search;
metadata terms are evaluated in-memory against the vault index. Results from
both paths are intersected/unioned according to the boolean operators.

```
User input: "type:meeting tag:urgent modified:>7d deploy"
                    |
            +-------v--------+
            |  Query Parser  |
            |  (tokenizer +  |
            |   recursive    |
            |   descent)     |
            +-------+--------+
                    |
              Query AST:
              AND(
                field("type", "=", "meeting"),
                field("tag", "=", "urgent"),
                field("modified", ">", "7d"),
                text("deploy")
              )
                    |
            +-------v--------+
            |  Filter        |
            |  Pipeline      |
            +--+----+----+---+
               |    |    |
     +---------+    |    +----------+
     |              |               |
 +---v---+   +-----v-----+   +-----v------+
 |Metadata|   |  Date     |   |  Ripgrep   |
 |Filter  |   |  Filter   |   |  (text)    |
 |(index) |   |  (index)  |   |  search    |
 +---+----+   +-----+-----+   +-----+------+
     |              |               |
     +---------+----+----+----------+
               |         |
         +-----v---------v-----+
         |  Result Combiner    |
         |  (AND/OR/NOT logic) |
         +----------+----------+
                    |
            +-------v--------+
            |  fzf-lua       |
            |  display       |
            +----------------+
```

### Query Syntax

The query language uses a **prefix-operator** syntax for field filters and
standard boolean operators, designed to be intuitive for Obsidian users while
remaining easy to type in a search prompt:

```
# Text search (plain terms passed to ripgrep)
deploy                          # files containing "deploy"
"exact phrase"                  # quoted exact match

# Field filters (prefix:value)
type:meeting                    # frontmatter type = meeting
tag:project/active              # has tag project/active (or child)
tag:urgent                      # has tag urgent
path:Projects/                  # file path starts with Projects/
file:Dashboard                  # basename contains Dashboard
folder:Projects/Alpha           # folder is exactly Projects/Alpha
status:active                   # frontmatter OR inline field status = active
priority:1                      # frontmatter OR inline field priority = 1

# Comparison operators for field filters
priority:>3                     # priority greater than 3
priority:>=3                    # priority >= 3
priority:1..3                   # priority between 1 and 3 inclusive

# Date filters (relative or absolute)
created:>7d                     # created within last 7 days
modified:>30d                   # modified within last 30 days
created:2026-01-01..2026-02-01  # created in January 2026
modified:today                  # modified today
modified:this-week              # modified this week
day:2026-02-26                  # filename-based date

# Task filters
task:""                         # any task
task-todo:""                    # open tasks (status " ")
task-done:""                    # completed tasks (status "x")
has:tasks                       # files containing any tasks

# Existence checks
has:tags                        # files with any tags
has:aliases                     # files with aliases
has:outlinks                    # files with outgoing links

# Boolean operators
type:meeting AND tag:urgent     # both conditions
type:meeting OR type:analysis   # either condition
NOT tag:archived                # negation
-tag:archived                   # shorthand for NOT (Obsidian compatible)

# Grouping
(type:meeting OR type:analysis) AND tag:active

# Regex
/pattern/                       # regex passed to ripgrep
/^##\s+Results/                 # regex for heading

# Combined: metadata + text
type:meeting tag:urgent deploy  # implicit AND between all terms
```

**Implicit AND:** When terms are separated by spaces without an explicit
operator, they are combined with AND. This matches Obsidian's behavior and
user expectations.

### Query Grammar (EBNF)

```ebnf
query          = or_expr ;
or_expr        = and_expr { "OR" and_expr } ;
and_expr       = not_expr { ("AND" | implicit_and) not_expr } ;
not_expr       = ("NOT" | "-") not_expr | primary_expr ;
primary_expr   = field_filter | text_term | regex_term
               | has_filter | task_filter | "(" or_expr ")" ;

field_filter   = field_name ":" field_value ;
field_name     = "type" | "tag" | "path" | "file" | "folder" | "status"
               | "created" | "modified" | "day" | "priority"
               | identifier ;            (* extensible: any frontmatter/inline key *)
field_value    = comparison_value | range_value | bare_value ;
comparison_value = (">" | ">=" | "<" | "<=") value ;
range_value    = value ".." value ;
bare_value     = quoted_string | unquoted_token ;

has_filter     = "has" ":" has_target ;
has_target     = "tags" | "aliases" | "tasks" | "outlinks" | "inlinks"
               | "frontmatter" | identifier ;

task_filter    = ("task" | "task-todo" | "task-done") ":" quoted_string ;

text_term      = quoted_string | unquoted_word ;
regex_term     = "/" regex_body "/" ;

quoted_string  = '"' { any_char } '"' ;
unquoted_word  = { non_whitespace - special_char } ;
identifier     = letter { letter | digit | "-" | "_" } ;
```

### Implementation Steps

#### Step 1: Create the Search Query Module

**New file: `lua/andrew/vault/search_query.lua`**

This module contains the tokenizer, parser, and AST types for the search query
language. It is deliberately kept separate from the DQL parser in
`query/parser.lua` because the search query language has fundamentally different
semantics (file-level filtering vs. dataview table queries).

```lua
local M = {}

-- Token types
M.TK = {
  TEXT = "TEXT",         -- plain text term
  QUOTED = "QUOTED",    -- "quoted string"
  REGEX = "REGEX",      -- /regex/
  FIELD = "FIELD",      -- field_name:value
  AND = "AND",
  OR = "OR",
  NOT = "NOT",
  MINUS = "MINUS",      -- - prefix (NOT shorthand)
  LPAREN = "LPAREN",
  RPAREN = "RPAREN",
  HAS = "HAS",          -- has:target
  TASK = "TASK",         -- task:"", task-todo:"", task-done:""
  EOF = "EOF",
}

-- AST node types
-- { type = "and", left = node, right = node }
-- { type = "or", left = node, right = node }
-- { type = "not", operand = node }
-- { type = "text", value = string, quoted = bool }
-- { type = "regex", pattern = string }
-- { type = "field", name = string, op = string, value = any, value2 = any }
-- { type = "has", target = string }
-- { type = "task", variant = "any"|"todo"|"done", pattern = string }

--- Tokenize a search query string.
---@param input string
---@return table[] tokens
function M.tokenize(input) ... end

--- Parse tokens into an AST.
---@param tokens table[]
---@return table|nil ast, string|nil error
function M.parse(tokens) ... end

--- Convenience: tokenize + parse in one call.
---@param query_string string
---@return table|nil ast, string|nil error
function M.parse_query(query_string) ... end

return M
```

Key design points for the tokenizer:
- Recognize `field:value` as a single FIELD token by checking if an unquoted
  word contains `:` and the prefix matches known field names or follows the
  identifier pattern.
- Handle `-` prefix as NOT shorthand only when it appears at the start of a
  term (not inside a word or as a hyphenated field name).
- Support `>`, `>=`, `<`, `<=` inside field values for comparison operators.
- Support `..` inside field values for range expressions.
- Pass through unrecognized terms as TEXT tokens for ripgrep.

Key design points for the parser:
- Implement implicit AND: when two primary expressions appear adjacent without
  an explicit operator, insert AND between them.
- Operator precedence: NOT > AND > OR (standard boolean precedence).
- Produce a clean AST that the filter pipeline can traverse.

#### Step 2: Create the Filter Pipeline

**New file: `lua/andrew/vault/search_filter.lua`**

This module evaluates a search query AST against vault index entries and
ripgrep results, producing a filtered set of file paths.

```lua
local M = {}

--- Evaluate a search AST against the vault index.
--- Returns a set of rel_paths that match the metadata portions of the query.
---@param ast table  parsed query AST
---@param index VaultIndex  the vault index instance
---@return table<string, boolean>  matching rel_paths
---@return table  text_terms: list of text/regex terms for ripgrep
function M.evaluate(ast, index) ... end

--- Split an AST into metadata filters and text search terms.
--- Metadata filters can be evaluated entirely from the index.
--- Text terms must be passed to ripgrep for content search.
---@param ast table
---@return table metadata_ast, table[] text_nodes
function M.split_ast(ast) ... end

--- Evaluate a metadata-only AST against a single VaultIndexEntry.
---@param ast table metadata AST node
---@param entry VaultIndexEntry
---@return boolean matches
function M.match_entry(ast, entry) ... end

return M
```

**Filter evaluation strategy:**

1. **AST splitting:** Walk the AST and classify each leaf node as either
   "metadata" (evaluable from the index) or "text" (requires ripgrep). Field
   filters, has-filters, and task-filters are metadata. Text terms and regex
   terms are text.

2. **Metadata filtering:** For metadata-only queries, iterate
   `vault_index.files` and test each entry against the metadata AST. This is
   O(N) where N is the number of files, but very fast since all data is
   in-memory with no I/O.

3. **Text filtering:** Collect text/regex terms and build a ripgrep command
   that searches for all of them. If there are multiple text terms connected
   by AND, run ripgrep once per term and intersect the result sets. If
   connected by OR, run ripgrep once with alternation.

4. **Result combination:** Intersect metadata matches with text matches
   according to the top-level boolean structure. The combiner respects the
   full AND/OR/NOT tree.

**Field filter evaluation rules:**

| Field       | Source in VaultIndexEntry     | Matching Logic                     |
|-------------|-----------------------------|------------------------------------|
| `type`      | `frontmatter.type`          | Exact string match (case-insensitive) |
| `tag`       | `tags[]`                    | Prefix match (tag or tag/child)    |
| `path`      | `rel_path`                  | Prefix match                       |
| `file`      | `basename`                  | Substring match (case-insensitive) |
| `folder`    | `folder`                    | Exact or prefix match              |
| `status`    | `frontmatter.status` OR `inline_fields.status` | Exact (case-insensitive) |
| `created`   | `ctime`                     | Date comparison                    |
| `modified`  | `mtime`                     | Date comparison                    |
| `day`       | `day`                       | Date match or range                |
| `priority`  | `frontmatter.priority` OR `inline_fields.priority` | Numeric comparison |
| `has`       | Various                     | Existence check (non-empty)        |
| Other       | `frontmatter[key]` OR `inline_fields[key]` | Exact or substring match |

**Date value parsing:**

Relative date expressions are resolved at query evaluation time:

| Expression      | Meaning                                    |
|-----------------|--------------------------------------------|
| `today`         | Start of today (00:00:00)                  |
| `yesterday`     | Start of yesterday                         |
| `7d` / `>7d`    | Within last 7 days                         |
| `30d`           | Within last 30 days                        |
| `this-week`     | Since start of current ISO week            |
| `this-month`    | Since start of current month               |
| `2026-01-15`    | Exact date                                 |
| `2026-01..2026-02` | Range: January through February         |

These reuse the date shortcut infrastructure already in `config.graph.date_shortcuts`.

#### Step 3: Create the Advanced Search UI

**Modified file: `lua/andrew/vault/search.lua`**

Add a new `search_advanced()` entry point that provides the advanced search
experience. The existing `search()`, `search_notes()`, etc. remain unchanged
for users who prefer plain ripgrep search.

```lua
--- Advanced search with boolean operators, field filters, and date ranges.
--- Uses a two-phase approach:
---   Phase 1: Parse query, evaluate metadata filters against vault index
---   Phase 2: Run ripgrep text search on the filtered file set
---   Phase 3: Display combined results in fzf-lua
function M.search_advanced()
  local search_query = require("andrew.vault.search_query")
  local search_filter = require("andrew.vault.search_filter")
  local vault_index = require("andrew.vault.vault_index")

  -- Get user input
  local query_string = nil
  engine.run(function()
    query_string = engine.input({ prompt = "Advanced search: " })
  end)
  if not query_string or query_string == "" then return end

  -- Parse the query
  local ast, parse_err = search_query.parse_query(query_string)
  if not ast then
    vim.notify("Search parse error: " .. (parse_err or "unknown"), vim.log.levels.ERROR)
    return
  end

  -- Split into metadata and text portions
  local metadata_ast, text_nodes = search_filter.split_ast(ast)

  -- Phase 1: Metadata filtering
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    vim.notify("Vault index not ready", vim.log.levels.WARN)
    return
  end

  local metadata_matches = nil
  if metadata_ast then
    metadata_matches = {}
    for rel_path, entry in pairs(idx.files) do
      if search_filter.match_entry(metadata_ast, entry) then
        metadata_matches[rel_path] = true
      end
    end
  end

  -- Phase 2: Text search via ripgrep
  if #text_nodes > 0 then
    -- Build ripgrep args with --files-from to restrict to metadata matches
    -- OR use fzf-lua grep with custom post-filtering
    ...
  end

  -- Phase 3: Display results
  ...
end
```

**Two UI modes for the advanced search:**

1. **Prompt mode** (`:VaultSearchAdvanced`): User types the full query in a
   `vim.ui.input` prompt, results appear in fzf-lua. Best for pre-composed
   queries.

2. **Live mode** (`:VaultSearchAdvancedLive`): User types in fzf-lua's input
   bar. The query is re-parsed on each keystroke (debounced). Metadata filters
   are applied instantly; text terms trigger ripgrep. This provides real-time
   feedback as the user builds their query.

**Implementation of live mode with fzf-lua:**

fzf-lua's `fzf_exec()` accepts a function that yields results. The live mode
works by:
1. Using `fzf_live()` (or the `__call` reload pattern) with a custom provider
   function that receives the current query string.
2. On each query change, the provider parses the query, evaluates metadata
   filters, and if text terms are present, shells out to ripgrep with
   `--files-from` (stdin) to restrict the search to metadata-matched files.
3. Results are streamed back to fzf for display.

```lua
function M.search_advanced_live()
  local fzf = require("fzf-lua")
  local search_query = require("andrew.vault.search_query")
  local search_filter = require("andrew.vault.search_filter")

  fzf.fzf_live(function(query_string)
    if not query_string or query_string == "" then
      return {}
    end

    local ast, err = search_query.parse_query(query_string)
    if not ast then return {} end

    local metadata_ast, text_nodes = search_filter.split_ast(ast)
    local idx = require("andrew.vault.vault_index").current()
    if not idx then return {} end

    -- Get metadata-matched files
    local matches = {}
    if metadata_ast then
      for rel_path, entry in pairs(idx.files) do
        if search_filter.match_entry(metadata_ast, entry) then
          matches[#matches + 1] = entry
        end
      end
    else
      -- No metadata filters: all files are candidates
      for _, entry in pairs(idx.files) do
        matches[#matches + 1] = entry
      end
    end

    -- If no text terms, return file list directly
    if #text_nodes == 0 then
      local results = {}
      for _, entry in ipairs(matches) do
        results[#results + 1] = entry.rel_path
      end
      return results
    end

    -- Text terms present: run ripgrep restricted to matched files
    return search_filter.ripgrep_in_files(text_nodes, matches, engine.vault_path)
  end, engine.vault_fzf_opts("Advanced search", {
    exec_empty_query = false,
    previewer = "builtin",
    actions = engine.vault_fzf_actions(),
  }))
end
```

#### Step 4: Integrate with Saved Searches

**Modified file: `lua/andrew/vault/saved_searches.lua`**

Extend the saved search schema to support the new query type:

```lua
-- Current entry: { name, query, scope, type }
-- Extended entry: { name, query, scope, type, advanced = true|nil }
```

When `entry.advanced == true`, `execute_search` dispatches to the advanced
search pipeline instead of plain ripgrep:

```lua
local function execute_search(entry)
  if entry.advanced then
    local search = require("andrew.vault.search")
    search.execute_advanced_query(entry.query)
    return
  end
  -- ... existing ripgrep-based execution ...
end
```

The `save_interactive` flow gains a new "advanced" search type option, and
`save_last` records whether the last search was advanced.

#### Step 5: Add Completion and Help

**Modified file: `lua/andrew/vault/search.lua`**

Add a completion source for the advanced search prompt that suggests:
- Field names: `type:`, `tag:`, `path:`, `file:`, `folder:`, `status:`,
  `created:`, `modified:`, `day:`, `priority:`, `has:`, `task:`
- Known tag values (from vault index) after `tag:`
- Known frontmatter `type` values after `type:`
- Known status values after `status:`
- Date shortcuts after `created:` or `modified:`
- Operators: `AND`, `OR`, `NOT`

This uses `vim.ui.input`'s optional `completion` parameter (if available via
dressing.nvim or similar), or a dedicated floating completion popup.

Add `:VaultSearchHelp` command that displays a floating window with the query
syntax reference.

#### Step 6: Configuration

**Modified file: `lua/andrew/vault/config.lua`**

```lua
-- ---------------------------------------------------------------------------
-- Advanced search
-- ---------------------------------------------------------------------------
M.search = {
  -- Debounce interval (ms) for live advanced search re-evaluation.
  live_debounce_ms = 150,

  -- Maximum number of files to pass to ripgrep via --files-from.
  -- If metadata filtering produces more matches than this, fall back
  -- to full vault ripgrep with post-filtering.
  max_files_from = 500,

  -- Known field names shown in completion (auto-extended from vault index).
  builtin_fields = {
    "type", "tag", "path", "file", "folder", "status",
    "created", "modified", "day", "priority",
  },

  -- Custom field aliases: maps user-friendly names to index field paths.
  -- e.g., { area = "frontmatter.area" }
  field_aliases = {},
}
```

### Key Design Decisions

**1. Separate query language from DQL**

The search query language is intentionally distinct from the Dataview Query
Language (DQL) parsed by `query/parser.lua`. DQL is a SQL-like language for
table/list/task rendering in code blocks. The search query language is
optimized for quick interactive filtering: terser syntax, implicit AND,
prefix-operator field filters. Trying to unify them would compromise both.

**2. Hybrid ripgrep + index approach**

Pure in-memory search (reading all file contents into the index) would be
prohibitively expensive for content search. Pure ripgrep cannot evaluate
metadata filters. The hybrid approach uses each tool for what it does best:
the vault index for instant metadata filtering, ripgrep for fast content
search. The `--files-from` flag restricts ripgrep to only the metadata-matched
files, providing significant speedup when metadata filters are selective.

**3. Implicit AND semantics**

Obsidian uses implicit AND between terms (space-separated terms must all
match). This is the most intuitive behavior: `type:meeting deploy` means "notes
of type meeting that contain deploy". Explicit `AND`/`OR` operators are
available for when the user needs different behavior.

**4. Case-insensitive matching by default**

Field value comparisons are case-insensitive by default (matching ripgrep's
`--smart-case` behavior). Tag matching is always case-insensitive since tags
are stored lowercased in the index. Text terms inherit ripgrep's smart-case
(case-insensitive unless the query contains uppercase).

**5. Graceful degradation**

If the vault index is not yet ready (cold start, still building), the advanced
search falls back to plain ripgrep search with a notification. Metadata filters
are silently ignored in this case, but text search still works. Once the index
is ready, subsequent searches use the full pipeline.

**6. Query string in saved searches**

Advanced queries are stored as the raw query string (not the AST). This keeps
the JSON format human-readable and forward-compatible -- if the query syntax
evolves, old saved queries are re-parsed with the current parser.

### Edge Cases

**Malformed queries:**
- Unmatched parentheses: parser returns an error, displayed to the user
- Unmatched quotes: parser returns an error
- Unknown field name (e.g., `foo:bar`): treated as a generic field filter that
  checks both `frontmatter.foo` and `inline_fields.foo`. If neither exists on
  a file, the filter evaluates to false for that file.
- Empty field value (e.g., `type:`): matches files where the field exists but
  is empty, or interprets as "has this field" (TBD -- prefer "has this field")

**Missing metadata fields:**
- If a file has no `type` in its frontmatter, `type:meeting` does not match it.
  This is the expected behavior.
- If a file has no inline fields, any inline field filter does not match.
- The `has:` filter explicitly checks for presence/non-emptiness.

**Large vaults (1000+ files):**
- Metadata filtering is O(N) iteration over in-memory data. For 1000 files,
  this takes < 5ms.
- When metadata filters are not selective (e.g., only text terms), all files
  pass to ripgrep, which handles large file sets efficiently.
- When metadata filters produce > `config.search.max_files_from` matches,
  skip `--files-from` and let ripgrep search the full vault, then post-filter
  results against the metadata set. This avoids hitting shell argument limits
  and is faster than writing thousands of paths.

**Date edge cases:**
- `ctime` may be nil on Linux (ext4 does not have true creation time). When
  `ctime` is nil, `created:` filters fall back to `mtime`.
- Files without a YYYY-MM-DD filename pattern have `day = nil`. The `day:`
  filter does not match these files.
- Timezone handling: all dates use local time (matching `os.date` and
  `os.time` behavior).

**Interaction with scopes:**
- Advanced search applies across the entire vault by default. To restrict to a
  scope, users can use `path:Projects/` or `folder:Log/`. Future enhancement:
  allow combining scope selection with advanced search.

**Boolean operator edge cases:**
- `NOT` without an operand: parser error
- Double negation (`NOT NOT term`): allowed, collapses during evaluation
- Mixed implicit AND and explicit OR: explicit operators bind as expected
  (`a b OR c` = `a AND (b OR c)` -- NO, this would be ambiguous). Resolution:
  implicit AND has the same precedence as explicit AND, so `a b OR c` parses
  as `(a AND b) OR c`. This matches Obsidian's behavior.

**Regex in field values:**
- Not supported in v1. Field values are literal strings. Regex is only
  supported as a standalone `/pattern/` term for content search.

## Files Modified

### New Files

1. **`lua/andrew/vault/search_query.lua`**
   - Tokenizer for the search query language
   - Recursive descent parser producing AST nodes
   - Query string normalization and validation
   - Exported types: AST node type definitions

2. **`lua/andrew/vault/search_filter.lua`**
   - AST evaluator: `split_ast()`, `match_entry()`, `evaluate()`
   - Field filter evaluation: type, tag, path, folder, date, generic
   - Date value parser (relative and absolute)
   - Ripgrep integration: `ripgrep_in_files()` for restricted text search
   - Result set combiners: AND, OR, NOT over file path sets

### Modified Files

3. **`lua/andrew/vault/search.lua`**
   - Add `search_advanced()` (prompt mode)
   - Add `search_advanced_live()` (live fzf-lua mode)
   - Add `execute_advanced_query(query_string)` for saved search integration
   - Add `:VaultSearchAdvanced` and `:VaultSearchAdvancedLive` commands
   - Add `<leader>vfa` keymap for advanced search
   - Add `:VaultSearchHelp` command

4. **`lua/andrew/vault/saved_searches.lua`**
   - Extend entry schema with `advanced` field
   - Update `execute_search()` to dispatch advanced queries
   - Update `save_interactive()` to offer "advanced" search type
   - Update `set_last_search()` to accept advanced flag

5. **`lua/andrew/vault/config.lua`**
   - Add `M.search` configuration section with `live_debounce_ms`,
     `max_files_from`, `builtin_fields`, `field_aliases`

6. **`lua/andrew/vault/engine.lua`**
   - No structural changes required. The `rg_base_opts()` and
     `vault_fzf_opts()` helpers are reused as-is. May add a helper to build
     ripgrep commands with `--files-from` support.

### Unchanged Files (benefit indirectly)

- **`vault_index.lua`** -- No changes needed. The search filter reads from the
  existing index entries. The rich metadata (frontmatter, tags, inline_fields,
  tasks, mtime, ctime, day) is already available.
- **`query/parser.lua`** -- Separate query language, no changes.
- **`pickers.lua`** -- No changes.
- **`frontmatter.lua`** -- No changes (handles BufWritePre timestamp updates).
- **`inline_fields.lua`** -- No changes (handles highlighting/parsing).

## Testing Plan

### Unit Tests

**1. Tokenizer correctness (`search_query.lua`)**
- Plain text: `"deploy"` -> `[TEXT("deploy")]`
- Quoted text: `'"exact phrase"'` -> `[QUOTED("exact phrase")]`
- Field filter: `"type:meeting"` -> `[FIELD("type", "meeting")]`
- Comparison: `"priority:>3"` -> `[FIELD("priority", ">", "3")]`
- Range: `"created:2026-01..2026-02"` -> `[FIELD("created", "..", "2026-01", "2026-02")]`
- Boolean: `"a AND b"` -> `[TEXT("a"), AND, TEXT("b")]`
- NOT shorthand: `"-tag:archived"` -> `[MINUS, FIELD("tag", "archived")]`
- Regex: `"/^## Results/"` -> `[REGEX("^## Results")]`
- Mixed: `"type:meeting deploy"` -> `[FIELD("type","meeting"), TEXT("deploy")]`
- Edge: empty string -> `[EOF]`
- Edge: unclosed quote -> error

**2. Parser correctness (`search_query.lua`)**
- Single text term -> `{ type = "text", value = "deploy" }`
- Implicit AND: `"a b"` -> `{ type = "and", left = text("a"), right = text("b") }`
- Explicit OR: `"a OR b"` -> `{ type = "or", ... }`
- Precedence: `"a b OR c"` -> `{ type = "or", left = and(a,b), right = c }`
  -- Wait: actually `"a b OR c"` with implicit AND same precedence as explicit
  AND should be `(a AND b) OR c`. Verify.
- NOT: `"NOT a"` -> `{ type = "not", operand = text("a") }`
- Minus: `"-tag:x"` -> `{ type = "not", operand = field("tag","x") }`
- Grouping: `"(a OR b) AND c"` -> correct tree
- Complex: `"type:meeting tag:urgent NOT tag:archived deploy"` -> correct tree

**3. Filter evaluation (`search_filter.lua`)**
- Create mock VaultIndexEntry tables with known metadata
- Test each field filter type against matching and non-matching entries:
  - `type:meeting` matches `{ frontmatter = { type = "meeting" } }`
  - `type:meeting` does NOT match `{ frontmatter = { type = "analysis" } }`
  - `tag:project/active` matches entry with tags containing "project/active"
  - `tag:project` matches entry with tags "project" or "project/active"
  - `path:Projects/` matches entry with rel_path "Projects/Alpha/note.md"
  - `file:Dashboard` matches entry with basename "Dashboard"
  - `created:>7d` matches entry with ctime within last 7 days
  - `has:tags` matches entry with non-empty tags array
  - `has:tags` does NOT match entry with empty tags array
- Test AND/OR/NOT combiners
- Test case-insensitivity

**4. AST splitting (`search_filter.lua`)**
- Pure metadata query: all nodes are metadata -> text_nodes is empty
- Pure text query: all nodes are text -> metadata_ast is nil
- Mixed query: correct split with AND connector preserved
- Nested boolean: correct classification at every level

**5. Date parsing (`search_filter.lua`)**
- `"today"` resolves to start of current day
- `"7d"` resolves to 7 days ago
- `"2026-01-15"` resolves to that date
- `"2026-01..2026-02"` resolves to range
- `"this-week"` resolves to Monday of current week
- Invalid date string: returns nil, handled gracefully

### Integration Tests (in Neovim)

**6. End-to-end: metadata-only search**
- Run `:VaultSearchAdvanced` with query `type:meeting`
- Verify results contain only files with `type: meeting` in frontmatter
- Compare against `:VaultSearchType` with "meeting" selection

**7. End-to-end: text-only search**
- Run advanced search with plain text `"deploy"`
- Verify results match `:VaultSearch` with the same term

**8. End-to-end: combined search**
- Run advanced search with `type:meeting deploy`
- Verify results are the intersection of type=meeting files and files
  containing "deploy"

**9. End-to-end: boolean operators**
- `type:meeting OR type:analysis` -> union of both types
- `tag:project NOT tag:archived` -> project-tagged files without archived tag
- `(type:meeting OR type:analysis) AND tag:urgent` -> correct intersection

**10. End-to-end: date filters**
- `modified:>7d` -> only recently modified files
- Verify against known file modification times

**11. End-to-end: saved advanced search**
- Create an advanced search, save it via `:VaultSearchSave`
- Load from `:VaultSearchList`, verify it executes correctly
- Verify the `.vault-searches.json` contains `"advanced": true`

**12. Graceful degradation**
- Temporarily make vault index unavailable (set `_ready = false`)
- Run advanced search: should fall back to plain ripgrep with notification
- Restore index: next search should use full pipeline

**13. Parse error handling**
- Enter malformed query: `"type:meeting AND AND"` -> error notification
- Enter unclosed parens: `"(a OR b"` -> error notification
- Verify no crash, user can retry

### Performance Benchmarks

**14. Metadata filter speed**
- On a 500-file vault, measure time for `match_entry` across all files with
  a multi-condition query (`type:meeting AND tag:active AND modified:>30d`).
  Target: < 10ms.

**15. Live search responsiveness**
- In live mode, measure time from keystroke to result display for a query
  that combines metadata and text search. Target: < 300ms perceived latency
  (including ripgrep execution and fzf rendering).

**16. Tokenizer/parser speed**
- Parse a complex query string 1000 times. Target: < 50ms total (confirming
  negligible overhead per parse).
