# 56 - Refactor Large Monolithic Files

## Motivation

Three files in the vault plugin have grown well beyond maintainable size:

| File | Lines | Concern |
|------|------:|---------|
| `query/js2lua.lua` | 2,636 | JS-to-Lua transpiler |
| `search_filter.lua` | 1,585 | Search filter pipeline |
| `search.lua` | 1,331 | Search UI and orchestration |

**Total: 5,552 lines across 3 files.**

Additionally, several other vault files exceed 1,000 lines and may warrant future refactoring:

| File | Lines | Concern |
|------|------:|---------|
| `vault_index.lua` | 1,701 | Core indexing system |
| `query/executor.lua` | 1,300 | Query execution logic |
| `embed.lua` | 1,200 | Note/image embedding |
| `engine.lua` | 1,143 | Main vault engine |

Files approaching the threshold (800-1,000 lines):

| File | Lines | Concern |
|------|------:|---------|
| `frontmatter_editor.lua` | 983 | Frontmatter editing UI |
| `query/parser.lua` | 931 | Query language parser |
| `graph_filter.lua` | 915 | Graph filtering pipeline |
| `unlinked.lua` | 909 | Unlinked mentions |
| `graph.lua` | 883 | Graph visualization |
| `preview.lua` | 847 | Floating preview |

These are **not** in scope for this document but are flagged for future consideration.

Problems with the current state:

1. **Navigability** -- finding a specific function requires scrolling through thousands of lines of unrelated logic. Even with section headers, the sheer density of `js2lua.lua` (16 `local function` definitions plus 4 forward-declared closures) makes it hard to orient.
2. **Testability** -- internal helpers like `tokenize()`, `regex_to_lua_pattern()`, and `match_field()` cannot be tested in isolation without `require`-ing the entire monolith.
3. **Load time** -- Lua's module loader parses the entire file on first `require`. Splitting lets Neovim defer parsing of subsystems that are not yet needed.
4. **Merge conflicts** -- multiple changes to the same large file produce unnecessary conflicts.
5. **Cognitive load** -- contributors must hold the entire file's context to understand any one subsystem.

The refactor preserves all public APIs by having the parent module re-export symbols from its sub-modules. No callers change in Phase 1-2.

---

## 1. `query/js2lua.lua` (2,636 lines)

### 1a. Current Structure

The file contains a full transpiler organized into these logical sections:

| Lines | Section | Key Functions |
|-------|---------|---------------|
| 1-29 | Module header + token type constants (`TK`) | -- |
| 41-268 | **Tokenizer** | `tokenize(src)` (nested: `peek()`, `advance()`, `slash_is_division()`) |
| 280-507 | **Regex converter** | `regex_to_lua_pattern(regex_token)` |
| 517-525 | **Context factory** | `make_ctx(tokens)` |
| 531-599 | **Token navigation helpers** | `tk_peek()`, `tk_cur()`, `tk_advance()`, `tk_is()`, `skip_ws()`, `peek_significant()`, `emit()` |
| 601-605 | **Forward declarations** | `transform_expression`, `transform_statement`, `transform_block`, `transform_arrow_body` |
| 616-632 | **Token list transformer** | `transform_token_list(tokens, parent_ctx)` |
| 638-680 | **Template literal transformer** | `transform_template(token, parent_ctx)` |
| 683-727 | **Arrow function detection** | `detect_arrow(ctx)` |
| 733-756 | **Arrow function transformer** | `transform_arrow(ctx, arrow)` |
| 761-805 | **Arrow body transformer** | `transform_arrow_body(ctx)` (forward-declared closure) |
| 814-858 | **Expression extractor** | `extract_expr_from_output(ctx)` |
| 866-916 | **Ternary transformer** | `transform_ternary(ctx, cond_lua)` |
| 921-1991 | **Expression transformer** | `transform_expression(ctx)` -- the main expression driver (1,070 lines) |
| 1999-2525 | **Statement transformer** | `transform_statement(ctx)` -- statement-level dispatch |
| 2532-2543 | **Block transformer** | `transform_block(ctx, is_arrow)` (forward-declared closure) |
| 2553-2588 | **Post-processing** | `postprocess(lua)` |
| 2602-2636 | **Public API** | `M.transpile()`, `M.transpile_for_exec()` |

Dependencies: None (only `vim.trim`, `vim.inspect`, `vim.split` used from Neovim API; `vim.trim` appears 40+ times).

### 1b. Proposed Split

```
lua/andrew/vault/query/
  js2lua.lua              -- Public API (thin orchestrator + re-exports)
  js2lua/
    tokens.lua            -- TK constants
    tokenizer.lua         -- tokenize()
    regex.lua             -- regex_to_lua_pattern()
    context.lua           -- make_ctx, tk_* helpers, emit, skip_ws
    expression.lua        -- transform_expression + expression helpers
    statement.lua         -- transform_statement + transform_block
    postprocess.lua       -- postprocess()
```

**7 sub-modules** extracted from 1 monolith.

### 1c. Function Assignments

**`js2lua/tokens.lua`** (~20 lines)
```lua
-- Token type enum, shared by tokenizer and transform engine
local TK = {
  IDENT = "ident", NUM = "num", STR = "str", TMPL = "tmpl",
  REGEX = "regex", OP = "op", PUNCT = "punct", NL = "nl",
  WS = "ws", COMMENT = "comment", EOF = "eof",
}
return TK
```

**`js2lua/tokenizer.lua`** (~230 lines)
- `tokenize(src)` -- the full tokenizer loop
- Internal helpers (nested inside `tokenize`): `peek()`, `advance()`, `slash_is_division()`
- Returns: `{ tokenize = tokenize }`
- Requires: `tokens.lua`

**`js2lua/regex.lua`** (~230 lines)
- `regex_to_lua_pattern(regex_token)` -- JS regex to Lua pattern conversion
- Returns: `{ regex_to_lua_pattern = regex_to_lua_pattern }`
- Requires: nothing

**`js2lua/context.lua`** (~100 lines)
- `make_ctx(tokens)` -- create transform context (fields: `tokens`, `pos`, `out`, `map_vars`, `indent`)
- `tk_peek(ctx, offset)`, `tk_cur(ctx)`, `tk_advance(ctx)`, `tk_is(ctx, typ, val)`
- `skip_ws(ctx)`, `peek_significant(ctx, start_offset)`, `emit(ctx, s)`
- Returns all as module fields
- Requires: `tokens.lua`

**`js2lua/expression.lua`** (~1,375 lines)
- `transform_expression(ctx)` -- main expression driver (1,070 lines)
- `transform_token_list(tokens, parent_ctx)`
- `transform_template(token, parent_ctx)`
- `detect_arrow(ctx)`, `transform_arrow(ctx, arrow)`
- `transform_arrow_body(ctx)` (forward-declared closure)
- `extract_expr_from_output(ctx)`, `transform_ternary(ctx, cond_lua)`
- Requires: `tokens.lua`, `context.lua`, `regex.lua`
- **Note:** This module and `statement.lua` have mutual recursion. See "Circular Dependency Resolution" below.

**`js2lua/statement.lua`** (~550 lines)
- `transform_statement(ctx)` -- statement-level dispatch (handles `const`/`let`/`var`, `for`, `for-of`, `for-in`, `while`, `if/else`)
- `transform_block(ctx, is_arrow)` -- block `{...}` processing
- Requires: `tokens.lua`, `context.lua`, `expression.lua`
- **Note:** `transform_expression` calls `transform_statement` in some branches and vice versa. `transform_block` calls `transform_statement` in its loop. The circular dependency is resolved by late-binding (see below).

**`js2lua/postprocess.lua`** (~50 lines)
- `postprocess(lua)` -- post-processing fixups:
  - Compound assignment: `x += y` to `x = x + y`
  - Increment/decrement: `x++`/`--x` etc.
  - 0-based JS to 1-based Lua index conversion
  - Trailing whitespace and blank line cleanup
- Requires: nothing

### 1d. Circular Dependency Resolution

`transform_expression`, `transform_statement`, `transform_block`, and `transform_arrow_body` currently reference each other as forward-declared locals. After the split, `transform_expression` and its helpers live in `expression.lua`, while `transform_statement` and `transform_block` live in `statement.lua`. Resolution:

```lua
-- expression.lua
local M = {}
local ctx_mod = require("andrew.vault.query.js2lua.context")
-- Late-bind statement transformer to break cycle
local _transform_statement
function M.set_statement_transformer(fn) _transform_statement = fn end

M.transform_expression = function(ctx)
  -- ... uses _transform_statement where needed ...
end
return M

-- statement.lua
local M = {}
local expression = require("andrew.vault.query.js2lua.expression")
M.transform_statement = function(ctx)
  -- ... uses expression.transform_expression where needed ...
end
M.transform_block = function(ctx, is_arrow)
  -- ... uses M.transform_statement in its loop ...
end
-- Wire up the back-reference
expression.set_statement_transformer(M.transform_statement)
return M
```

This is the same pattern used in recursive-descent parsers split across files. The wiring happens at module load time, before any transpilation occurs.

### 1e. Parent Re-export Pattern

```lua
-- query/js2lua.lua (after refactor)
local M = {}

local tokenizer   = require("andrew.vault.query.js2lua.tokenizer")
local context     = require("andrew.vault.query.js2lua.context")
local expression  = require("andrew.vault.query.js2lua.expression")
local statement   = require("andrew.vault.query.js2lua.statement")
local postprocess = require("andrew.vault.query.js2lua.postprocess")

--- Transpile a DataviewJS code block into Lua code.
---@param js_code string
---@return string|nil lua_code
---@return string|nil error
function M.transpile(js_code)
  if type(js_code) ~= "string" or js_code == "" then
    return nil, "transpile: input must be a non-empty string"
  end

  local ok, result = pcall(function()
    local tokens = tokenizer.tokenize(js_code)
    local ctx = context.make_ctx(tokens)

    while ctx.pos <= #ctx.tokens and context.tk_cur(ctx).type ~= "eof" do
      statement.transform_statement(ctx)
    end

    local raw_lua = table.concat(ctx.out)
    return postprocess.postprocess(raw_lua)
  end)

  if not ok then
    return nil, "Transpile error: " .. tostring(result)
  end
  return result, nil
end

--- Convenience wrapper for execute_block().
---@param js_code string
---@return string|nil lua_code
---@return string|nil error
function M.transpile_for_exec(js_code)
  return M.transpile(js_code)
end

return M
```

### 1f. Import Changes

Only one external importer exists:
- `query/init.lua` (line 7) -- `require("andrew.vault.query.js2lua")` -- **no change needed** (same module path, same public API).

---

## 2. `search_filter.lua` (1,585 lines)

### 2a. Current Structure

| Lines | Section | Key Functions |
|-------|---------|---------------|
| 1-16 | Module setup, requires | -- |
| 18-57 | **AST classification** | `classify(node)` + constants `METADATA_TYPES`, `TEXT_TYPES` |
| 59-93 | **Date resolution** | `parse_entry_date(entry, field_name)` |
| 95-228 | **Field matching helpers** | `eq_ci()`, `compare_num()`, `invert_op()`, `in_num_range()`, `compare_date()`, `resolve_alias_path()`, `get_generic_field()`, `field_exists()` |
| 232-356 | **Section outlinks cache** | `maybe_invalidate_section_cache()`, `extract_line_outlinks()`, `build_file_section_map()`, `get_section_outlinks()` |
| 364-415 | **Tag filtering** | `parse_tag_filter()`, `match_tag_filter()` |
| 422-685 | **Field matching** | `match_field(node, entry, index)` -- 263 lines, the single largest function |
| 692-727 | **Has matching** | `match_has(node, entry, index)` |
| 732-991 | **Task matching** | `resolve_state_mark()`, `resolve_task_date()`, `match_task_meta_exists()`, `match_task_date()`, `match_task_priority()`, `match_task_tag()`, `match_task_repeat()`, `match_task_meta()`, `match_task()` |
| 1003-1039 | **AST splitting (text)** | `extract_text_ast(node)` |
| 1039-1075 | **AST splitting (metadata)** | `extract_metadata_ast(node)` |
| 1075-1130 | **AST splitting (public)** | `M.split_ast(ast)` |
| 1132-1277 | **Graph traversal** | `resolve_graph_center()`, `collect_reachable()`, `M.ast_contains_graph()`, `M.precompute_graph_sets()` |
| 1279-1334 | **Entry matching** | `M.match_entry(ast, entry, index, graph_sets)` |
| 1336-1361 | **Evaluation** | `M.evaluate(ast, index, graph_sets)` |
| 1363-1498 | **Ripgrep helpers** | `build_rg_args()`, `write_paths_tmpfile()`, `extract_rg_file()`, `collect_file_set()`, `run_rg_single()` |
| 1510-1583 | **Ripgrep dispatch (public)** | `M.ripgrep_in_files(text_ast, file_paths, vault_path)` |
| 1585 | Module return | `return M` |

Dependencies (top-level):
- `config` (`andrew.vault.config`)
- `date_utils` (`andrew.vault.date_utils`)
- `filter_utils` (`andrew.vault.filter_utils`)
- `link_utils` (`andrew.vault.link_utils`)
- `notify` (`andrew.vault.notify`)
- `vault_index` (`andrew.vault.vault_index`)

Lazy requires (within functions):
- `slug` (`andrew.vault.slug`) -- in `build_file_section_map()`, `get_section_outlinks()`, `match_field()`
- `engine` (`andrew.vault.engine`) -- in `build_file_section_map()`, `collect_reachable()`

vim.* API:
- `vim.trim()` -- in `build_file_section_map()`, `parse_tag_filter()`, `match_field()`
- `vim.system()` -- in `run_rg_single()`

Module-level state:
- `_section_cache` (table) -- per-file section outlinks cache
- `_section_cache_generation` (number, init -1) -- tracks vault index generation for cache invalidation
- `same_day` (function ref) -- alias for `date_utils.same_day`
- `METADATA_TYPES`, `TEXT_TYPES` (constant tables)

### 2b. Proposed Split

```
lua/andrew/vault/
  search_filter.lua              -- Orchestrator + re-exports
  search_filter/
    classify.lua                 -- AST classification
    match_helpers.lua            -- Comparison helpers, date parsing, field resolution
    match_field.lua              -- match_field(), section outlinks, tag filter
    match_has.lua                -- match_has()
    match_task.lua               -- All task-matching logic
    ast_split.lua                -- extract_text_ast, extract_metadata_ast, split_ast
    graph_traversal.lua          -- graph center, BFS reachable, graph set precomputation
    ripgrep.lua                  -- rg args, tmpfile, ripgrep_in_files
```

**8 sub-modules** extracted from 1 monolith.

### 2c. Function Assignments

**`search_filter/classify.lua`** (~40 lines)
- `classify(node)` -- AST node classification
- Constants: `METADATA_TYPES`, `TEXT_TYPES`
- Returns: `{ classify = classify, METADATA_TYPES = METADATA_TYPES, TEXT_TYPES = TEXT_TYPES }`

**`search_filter/match_helpers.lua`** (~170 lines)
- `eq_ci(a, b)`, `compare_num(lhs, op, rhs)`, `invert_op(op)`, `in_num_range(val, lo, hi)`
- `compare_date(ts, op, filter_ts, filter_val, invert)`
- `parse_entry_date(entry, field_name)`
- `resolve_alias_path(entry, alias_path)`, `get_generic_field(entry, name)`, `field_exists(name, entry)`
- Requires: `date_utils`

**`search_filter/match_field.lua`** (~455 lines)
- `match_field(node, entry, index)` -- the large field matcher (263 lines)
- Section outlinks cache: `maybe_invalidate_section_cache()`, `extract_line_outlinks()`, `build_file_section_map()`, `get_section_outlinks()`
- Tag filter: `parse_tag_filter()`, `match_tag_filter()`
- Module-level state: `_section_cache`, `_section_cache_generation`
- Requires: `match_helpers`, `link_utils`, `vault_index`, `config`, `filter_utils`, `slug` (lazy), `engine` (lazy)

**`search_filter/match_has.lua`** (~40 lines)
- `match_has(node, entry, index)`
- Requires: nothing beyond the entry/index API

**`search_filter/match_task.lua`** (~260 lines)
- `resolve_state_mark(label)`, `resolve_task_date(value, forward_looking)`
- `match_task_meta_exists()`, `match_task_date()`, `match_task_priority()`
- `match_task_tag()`, `match_task_repeat()`, `match_task_meta()`
- `match_task(node, entry)`
- Requires: `date_utils`, `config`

**`search_filter/ast_split.lua`** (~140 lines)
- `extract_text_ast(node)`, `extract_metadata_ast(node)`
- `M.split_ast(ast)` (public)
- Requires: `classify`

**`search_filter/graph_traversal.lua`** (~150 lines)
- `resolve_graph_center(center_spec, current_path, index)`
- `collect_reachable(index, center_abs, depth, direction)`
- `M.ast_contains_graph(ast)` (public)
- `M.precompute_graph_sets(ast, index, current_path)` (public)
- Requires: `config`, `engine` (lazy)

**`search_filter/ripgrep.lua`** (~220 lines)
- `build_rg_args(node, vault_path, files_from)`
- `write_paths_tmpfile(file_paths)`, `extract_rg_file(line)`, `collect_file_set(lines)`
- `run_rg_single(node, file_paths, vault_path)`
- `M.ripgrep_in_files(text_ast, file_paths, vault_path)` (public)
- Requires: `config`, `notify`

### 2d. Parent Re-export Pattern

```lua
-- search_filter.lua (after refactor)
local M = {}

local classify_mod = require("andrew.vault.search_filter.classify")
local match_field  = require("andrew.vault.search_filter.match_field")
local match_has    = require("andrew.vault.search_filter.match_has")
local match_task   = require("andrew.vault.search_filter.match_task")
local ast_split    = require("andrew.vault.search_filter.ast_split")
local graph        = require("andrew.vault.search_filter.graph_traversal")
local ripgrep      = require("andrew.vault.search_filter.ripgrep")

-- Public API (unchanged signatures)
M.split_ast             = ast_split.split_ast
M.ast_contains_graph    = graph.ast_contains_graph
M.precompute_graph_sets = graph.precompute_graph_sets
M.ripgrep_in_files      = ripgrep.ripgrep_in_files

--- Match a single entry against a metadata AST.
function M.match_entry(ast, entry, index, graph_sets)
  -- Delegates to match_field, match_has, match_task, graph
  -- (this ~50-line function stays in the orchestrator since it
  --  dispatches across all matchers)
  ...
end

--- Evaluate a metadata AST against the full vault index.
function M.evaluate(ast, index, graph_sets)
  ...
end

return M
```

### 2e. Import Changes

External importers:
- `search.lua` -- `require("andrew.vault.search_filter")` -- **no change** (same path, same API)
- `graph_filter.lua` -- `require("andrew.vault.search_filter")` -- **no change** (uses `split_ast()` and `match_entry()`)

---

## 3. `search.lua` (1,331 lines)

### 3a. Current Structure

| Lines | Section | Key Functions |
|-------|---------|---------------|
| 1-5 | Module setup, requires | `engine`, `config`, `cleanup`, `notify` |
| 13-21 | **Tracking helper** | `track()` |
| 23-84 | **Basic search** | `M.search()`, `M.search_notes()`, `M.search_filtered()`, `M.search_by_type()` |
| 91-94 | **Header constant** | `SEARCH_HEADER` |
| 104-199 | **Query resolution** | `resolve_query(split, idx, vault_path, graph_sets, group_mode)` |
| 201-227 | **AST evaluation** | `evaluate_advanced_ast(ast, group_mode, idx, current_path)` |
| 229-276 | **Stats helpers** | `count_unique_files()`, `count_matches()`, `format_stats()` |
| 279-305 | **Field introspection** | `get_known_fields()` |
| 308-323 | **Field collection** | `collect_field_nodes(ast)` |
| 326-364 | **Field validation** | `warn_unknown_fields(ast, idx)` |
| 367-427 | **Field value aggregation** | `aggregate_field_values(field_name)` |
| 433-555 | **Execute advanced query** | `M.execute_advanced_query(query_string, opts)` -- fzf result display |
| 556-668 | **Prompt mode** | `M.search_advanced()` -- floating input window |
| 672-763 | **Live mode** | `M.search_advanced_live()` -- fzf_live provider |
| 770-892 | **Help float** | `M.search_help()` -- syntax reference window (123 lines) |
| 901-1198 | **Completion** | `M._complete_advanced(lead)` -- 297 lines of field-specific completion |
| 1202-1259 | **Search in files** | `M.search_in_files(file_paths)` -- restricted live search |
| 1261-1329 | **Setup** | `M.setup()` -- commands, keymaps, palette |
| 1331 | Module return | `return M` |

Dependencies (top-level):
- `engine` (`andrew.vault.engine`)
- `config` (`andrew.vault.config`)
- `cleanup` (`andrew.vault.resource_cleanup`)
- `notify` (`andrew.vault.notify`)

Lazy requires (within functions):
- `saved_searches` (`andrew.vault.saved_searches`) -- in `track()`
- `search_history` (`andrew.vault.search_history`) -- in `track()`, `M.search_advanced()`, `M.setup()`
- `fzf-lua` -- in basic search, `execute_advanced_query()`, `search_advanced_live()`, `search_in_files()`
- `search_filter` (`andrew.vault.search_filter`) -- in `resolve_query()`, `evaluate_advanced_ast()`, `execute_advanced_query()`, `search_in_files()`
- `search_group` (`andrew.vault.search_group`) -- in `resolve_query()`, `count_unique_files()`, `count_matches()`, `execute_advanced_query()`, `_complete_advanced()`, `search_advanced_live()`
- `search_query` (`andrew.vault.search_query`) -- in `warn_unknown_fields()`, `execute_advanced_query()`, `search_advanced_live()`, `search_in_files()`, `_complete_advanced()`
- `vault_index` (`andrew.vault.vault_index`) -- in `aggregate_field_values()`, `execute_advanced_query()`, `search_advanced_live()`, `_complete_advanced()`, `search_in_files()`
- `ansi` (`andrew.vault.ansi`) -- in `search_advanced_live()`
- `graph` (`andrew.vault.graph`) -- in `execute_advanced_query()` (Ctrl-g action)
- `command_palette` (`andrew.vault.command_palette`) -- in `M.setup()`

Module-level state:
- `SEARCH_HEADER` (string constant) -- two-line syntax reference for fzf header
- No persistent caches (caching delegated to vault_index, search_filter, completion modules)

Exported functions (M.*):
1. `M.search()` -- live grep across entire vault
2. `M.search_notes()` -- live grep across markdown notes only
3. `M.search_filtered()` -- scoped search by folder
4. `M.search_by_type()` -- search by frontmatter type
5. `M.execute_advanced_query(query_string, opts?)` -- main advanced query execution
6. `M.search_advanced()` -- prompt-based advanced search with floating input
7. `M.search_advanced_live()` -- live advanced search via fzf_live
8. `M.search_help()` -- floating help window with syntax reference
9. `M._complete_advanced(lead)` -- completion candidate generator
10. `M.search_in_files(file_paths)` -- advanced search restricted to specific files
11. `M.setup()` -- register commands, keymaps, palette

### 3b. Proposed Split

```
lua/andrew/vault/
  search.lua                    -- Orchestrator + basic search + re-exports
  search/
    track.lua                   -- track() helper (avoids circular deps)
    advanced.lua                -- Advanced query pipeline, evaluate_advanced_ast, execute_advanced_query
    prompt.lua                  -- search_advanced() -- floating input UI
    live.lua                    -- search_advanced_live(), search_in_files()
    help.lua                    -- search_help() -- syntax reference float
    completion.lua              -- _complete_advanced() -- field/value completion
    stats.lua                   -- count_unique_files, count_matches, format_stats, field introspection
```

**7 sub-modules** extracted from 1 monolith.

### 3c. Function Assignments

**`search/track.lua`** (~10 lines)
- `track(query, scope, search_type, advanced)` -- records search in saved_searches + search_history
- Lazy-requires: `saved_searches`, `search_history`
- Called from: `M.search()`, `M.search_notes()`, `M.search_filtered()`, `M.search_by_type()`, `M.search_advanced()`

**`search/stats.lua`** (~210 lines)
- `count_unique_files(entries, group_mode)`
- `count_matches(entries, group_mode)`
- `format_stats(entries, group_mode, elapsed_ms)`
- `get_known_fields()`
- `collect_field_nodes(ast)`
- `warn_unknown_fields(ast, idx)`
- `aggregate_field_values(field_name)`
- Requires: `config`, `search_group` (lazy), `search_query` (lazy), `vault_index` (lazy)

**`search/advanced.lua`** (~280 lines)
- `SEARCH_HEADER` constant
- `resolve_query(split, idx, vault_path, graph_sets, group_mode)` -- shared pipeline
- `evaluate_advanced_ast(ast, group_mode, idx, current_path)` -- shared pipeline
- `M.execute_advanced_query(query_string, opts)` -- fzf result display
- Requires: `engine`, `config`, `notify`, `search_filter` (lazy), `search_query` (lazy), `vault_index` (lazy), `fzf-lua` (lazy), `search_group` (lazy), `graph` (lazy), `track`, `stats`

**`search/prompt.lua`** (~120 lines)
- `M.search_advanced()` -- floating input with keymaps, tab completion, history
- Keymaps: Enter (submit), Esc/q (close), Ctrl-/ (help), Ctrl-r (history)
- Requires: `cleanup`, `search_history` (lazy), `advanced` (for `execute_advanced_query`), `help` (for `search_help`), `completion` (for `_complete_advanced`), `track`

**`search/live.lua`** (~150 lines)
- `M.search_advanced_live()` -- fzf_live provider with debounce
- `M.search_in_files(file_paths)` -- restricted live search for graph integration
- Requires: `engine`, `config`, `search_filter` (lazy), `search_query` (lazy), `vault_index` (lazy), `fzf-lua` (lazy), `search_group` (lazy), `ansi` (lazy), `advanced` (for `SEARCH_HEADER`, `evaluate_advanced_ast`), `stats`

**`search/help.lua`** (~130 lines)
- `M.search_help()` -- floating window with 100+ lines of syntax reference text
- Documents: text search, field filters, date filters, task filters, link filters, has:, graph:, boolean operators, result grouping
- Keymaps: q / Esc to close
- Requires: `cleanup`

**`search/completion.lua`** (~300 lines)
- `M._complete_advanced(lead)` -- field/value completion candidates
- Handles: field names, boolean operators, graph: params, group: modes, has: targets, type:, status:, tag:, links-to:/linked-from: note names, heading completions, alias:, task-state:, task-priority:, date shortcuts, generic field value aggregation
- Requires: `config`, `vault_index` (lazy), `search_group` (lazy), `stats` (for `get_known_fields`, `aggregate_field_values`)

### 3d. Handling `track()` and Cross-references

`track()` is a small utility called by `search_advanced()`, `search_advanced_live()`, and the basic search functions. It lazy-requires `saved_searches` and `search_history` to avoid circular dependencies.

Extract to a tiny shared module to avoid circular require (parent requires sub-module, sub-module requires parent):

```lua
-- search/track.lua (10 lines)
local M = {}
function M.track(query, scope, search_type, advanced)
  require("andrew.vault.saved_searches").set_last_search(query, scope, search_type, advanced)
  local q = query and vim.trim(query) or ""
  if q ~= "" then
    require("andrew.vault.search_history").record(q, advanced and "advanced" or search_type)
  end
end
return M
```

Then both the parent and sub-modules require `search/track` without cycles.

Similarly, `SEARCH_HEADER` is needed by both `advanced.lua` (for execute_advanced_query) and `live.lua` (for fzf_live header). It lives in `advanced.lua` and `live.lua` requires it.

`get_known_fields()` and `aggregate_field_values()` are used by both `stats.lua` and `completion.lua`. They live in `stats.lua`, `completion.lua` requires them.

### 3e. Parent Re-export Pattern

```lua
-- search.lua (after refactor)
local engine  = require("andrew.vault.engine")
local config  = require("andrew.vault.config")
local track   = require("andrew.vault.search.track")

local M = {}

-- Basic search (stays here -- small, no reason to extract)
function M.search()
  track.track("", "all", "grep")
  require("fzf-lua").live_grep(engine.vault_fzf_opts("Vault search"))
end

function M.search_notes() ... end
function M.search_filtered() ... end
function M.search_by_type() ... end

-- Re-exports from sub-modules
local advanced   = require("andrew.vault.search.advanced")
local prompt     = require("andrew.vault.search.prompt")
local live       = require("andrew.vault.search.live")
local help       = require("andrew.vault.search.help")
local completion = require("andrew.vault.search.completion")

M.execute_advanced_query = advanced.execute_advanced_query
M.search_advanced        = prompt.search_advanced
M.search_advanced_live   = live.search_advanced_live
M.search_in_files        = live.search_in_files
M.search_help            = help.search_help
M._complete_advanced     = completion._complete_advanced

function M.setup()
  -- All commands, keymaps, palette registrations (stays here)
  ...
end

return M
```

### 3f. Import Changes

External importers and what they call:
- `init.lua` -- `require("andrew.vault.search").setup()` -- **no change**
- `graph.lua` -- `require("andrew.vault.search").search_in_files(paths)` -- **no change**
- `saved_searches.lua` -- `require("andrew.vault.search").execute_advanced_query(...)` -- **no change**
- `search_history.lua` -- `require("andrew.vault.search").execute_advanced_query(...)` -- **no change**

All callers access via `require("andrew.vault.search").<fn>`, so the re-export pattern is fully transparent.

---

## 4. Migration Strategy

### Phase 1: Extract Sub-modules (non-breaking)

For each file, create the new sub-module files with the extracted functions. The parent module continues to hold all the original code. Sub-modules are created but not yet wired in. This phase is purely additive.

**Verification:** `require("andrew.vault.search_filter.ripgrep")` loads without error; existing tests pass unchanged.

**Note:** None of the proposed sub-module directories currently exist (`search_filter/`, `search/`, `query/js2lua/`). They must be created as part of this phase.

### Phase 2: Wire Parent to Delegate

Replace the function bodies in the parent with delegations to sub-modules. The parent `require`s its children and re-exports their public functions.

**Key constraint:** Do this one parent at a time. After each parent is rewired, run the full test suite before proceeding.

Recommended order (lowest risk first):
1. `search_filter.lua` -- most self-contained, clearest section boundaries
2. `search.lua` -- UI code is inherently harder to test but has clear module boundaries
3. `query/js2lua.lua` -- mutual recursion adds complexity; do last

### Phase 3: Update Direct Sub-module Imports (optional)

If any module already imports a sub-module directly (e.g., `graph_filter.lua` calling `search_filter.evaluate()`), consider whether it should instead import the specific sub-module. This is optional since the parent re-export is stable, but can improve load-time performance.

### Phase 4: Remove Dead Code from Parent

Once all delegations are confirmed working, remove the now-dead local functions from the parent files. The parent should contain only `require` statements, re-export assignments, and any thin orchestration logic that genuinely spans sub-modules.

---

## 5. Testing Approach

### 5a. Behavioral Equivalence

The refactor must be invisible to callers. Verification strategy:

1. **Existing integration tests** -- Run the full vault test suite after each phase. Any test failures indicate a broken re-export or missing dependency.

2. **Manual smoke tests per file:**

   For `js2lua.lua`:
   - Open a vault note with a `dataviewjs` code block
   - `:VaultQueryRender` should produce identical output before and after

   For `search_filter.lua`:
   - Run an advanced search with metadata filters: `type:meeting tag:project created:>30d`
   - Run a mixed search: `type:meeting deploy`
   - Run a task search: `task-due:<7d task-priority:<=2`
   - Run a graph search: `graph:depth=2 tag:active`
   - Verify identical results before and after

   For `search.lua`:
   - `:VaultSearch` -- basic live grep
   - `:VaultSearchAdvanced` -- prompt mode with tab completion, Ctrl-/ help, Ctrl-r history
   - `:VaultSearchAdvancedLive` -- live mode with debounce
   - `:VaultSearchHelp` -- help float opens/closes
   - Graph-to-search bridge (`s` key in graph view)
   - Saved search dispatch

3. **API surface snapshot** -- Before refactoring, capture the output of:
   ```lua
   local m = require("andrew.vault.search_filter")
   local keys = {}
   for k in pairs(m) do keys[#keys+1] = k end
   table.sort(keys)
   print(vim.inspect(keys))
   ```
   After refactoring, the same script must produce identical output.

### 5b. New Unit Test Opportunities

Post-refactor, individual sub-modules can be tested in isolation:

```lua
-- Test tokenizer independently
local tokenizer = require("andrew.vault.query.js2lua.tokenizer")
local tokens = tokenizer.tokenize("let x = 1 + 2;")
assert(tokens[1].type == "ident" and tokens[1].value == "let")

-- Test match_field independently
local match_field = require("andrew.vault.search_filter.match_field")
local entry = { frontmatter = { type = "meeting" }, tags = { "project" } }
local node = { type = "field", name = "type", op = "=", value = "meeting" }
assert(match_field.match_field(node, entry, nil) == true)

-- Test completion independently
local completion = require("andrew.vault.search.completion")
local candidates = completion._complete_advanced("typ")
assert(vim.tbl_contains(candidates, "type:"))
```

---

## 6. Risk Assessment

### High Risk

| Risk | Mitigation |
|------|------------|
| **Mutual recursion in js2lua** (`transform_expression` <-> `transform_statement` <-> `transform_block`) | Use setter-based late binding as described in section 1d. Test with complex JS snippets that exercise both directions. Note: `transform_block` also participates in the cycle (calls `transform_statement` in its loop). |
| **Module-level state in search_filter** (`_section_cache`, `_section_cache_generation`) | State must live in exactly one sub-module (`match_field.lua`). Ensure no other module duplicates or shadows it. |
| **Lazy require timing** (`search.lua` sub-modules lazy-require `fzf-lua`, `vault_index`, etc.) | Preserve existing lazy-require patterns verbatim. Do not convert lazy requires to top-level requires. |

### Medium Risk

| Risk | Mitigation |
|------|------------|
| **`track()` circular dependency** | Extract to `search/track.lua` as described in 3d. |
| **`SEARCH_HEADER` shared constant** | Define in `search/advanced.lua`, import from `search/live.lua`. |
| **`get_known_fields()` and `aggregate_field_values()` used by both `stats.lua` and `completion.lua`** | Live in `stats.lua`, `completion.lua` requires them. |
| **`same_day` reference in search_filter** (used in `match_field` and `match_task`) | `same_day` is `date_utils.same_day`; both sub-modules require `date_utils` independently. Verify there is no module-local alias that would be lost. |
| **`notify` dependency** | Both `search_filter.lua` and `search.lua` require `andrew.vault.notify` at top level. Sub-modules that need notifications must carry their own require. |

### Low Risk

| Risk | Mitigation |
|------|------------|
| **Lua module cache** | `require()` caches by module path. New paths (`search_filter.ripgrep`) get their own cache entries. No conflict. |
| **Load order** | Lua modules are loaded on first `require`. Sub-modules loaded when parent loads. No change in observable behavior. |
| **File count increase** | 3 files become 3 + 22 = 25 files. Directory structure keeps related code together. |

---

## 7. New Directory Layout Summary

```
lua/andrew/vault/
  search.lua                          -- 80 lines (basic search + re-exports + setup)
  search/
    track.lua                         -- 10 lines
    advanced.lua                      -- 280 lines
    prompt.lua                        -- 120 lines
    live.lua                          -- 150 lines
    help.lua                          -- 130 lines
    completion.lua                    -- 300 lines
    stats.lua                         -- 210 lines

  search_filter.lua                   -- 80 lines (orchestrator + match_entry + evaluate)
  search_filter/
    classify.lua                      -- 40 lines
    match_helpers.lua                 -- 170 lines
    match_field.lua                   -- 455 lines
    match_has.lua                     -- 40 lines
    match_task.lua                    -- 260 lines
    ast_split.lua                     -- 140 lines
    graph_traversal.lua               -- 150 lines
    ripgrep.lua                       -- 220 lines

  query/
    js2lua.lua                        -- 40 lines (public API orchestrator)
    js2lua/
      tokens.lua                      -- 20 lines
      tokenizer.lua                   -- 230 lines
      regex.lua                       -- 230 lines
      context.lua                     -- 100 lines
      expression.lua                  -- 1,375 lines
      statement.lua                   -- 545 lines
      postprocess.lua                 -- 50 lines
```

Total: same ~5,550 lines, distributed across 25 files instead of 3. The largest single file drops from 2,636 lines (`js2lua.lua`) to ~1,375 lines (`expression.lua`), which could be further split in a future pass if needed (e.g., separating method call transforms from operator transforms).

---

## 8. Implementation Order

| Step | File | Action | Est. LOC moved |
|------|------|--------|---------------:|
| 1 | `search_filter/classify.lua` | Extract, wire | 40 |
| 2 | `search_filter/match_helpers.lua` | Extract, wire | 170 |
| 3 | `search_filter/match_has.lua` | Extract, wire | 40 |
| 4 | `search_filter/match_task.lua` | Extract, wire | 260 |
| 5 | `search_filter/match_field.lua` | Extract (depends on match_helpers), wire | 455 |
| 6 | `search_filter/ast_split.lua` | Extract (depends on classify), wire | 140 |
| 7 | `search_filter/graph_traversal.lua` | Extract, wire | 150 |
| 8 | `search_filter/ripgrep.lua` | Extract, wire | 220 |
| 9 | `search_filter.lua` | Slim to orchestrator | -- |
| 10 | `search/track.lua` | Extract | 10 |
| 11 | `search/stats.lua` | Extract | 210 |
| 12 | `search/help.lua` | Extract | 130 |
| 13 | `search/completion.lua` | Extract (depends on stats) | 300 |
| 14 | `search/advanced.lua` | Extract (depends on stats) | 280 |
| 15 | `search/prompt.lua` | Extract (depends on advanced, help, completion) | 120 |
| 16 | `search/live.lua` | Extract (depends on advanced, stats) | 150 |
| 17 | `search.lua` | Slim to orchestrator | -- |
| 18 | `js2lua/tokens.lua` | Extract | 20 |
| 19 | `js2lua/context.lua` | Extract (depends on tokens) | 100 |
| 20 | `js2lua/regex.lua` | Extract | 230 |
| 21 | `js2lua/tokenizer.lua` | Extract (depends on tokens) | 230 |
| 22 | `js2lua/postprocess.lua` | Extract | 50 |
| 23 | `js2lua/expression.lua` | Extract (depends on tokens, context, regex) | 1,375 |
| 24 | `js2lua/statement.lua` | Extract (depends on tokens, context, expression) + wire mutual recursion | 545 |
| 25 | `js2lua.lua` | Slim to orchestrator | -- |

**Run full smoke tests after steps 9, 17, and 25.**
