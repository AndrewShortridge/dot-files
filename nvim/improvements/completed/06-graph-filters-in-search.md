# Graph Filters Integrated into Search

## Current State

The vault plugin has two parallel filtering systems that operate independently:

### 1. Graph Filter System (`graph_filter.lua`)

The graph filter system provides local graph filtering via `GraphFilterState` --
a structured filter state object with dedicated predicates for tags, note types,
date ranges, path prefixes, depth, and toggle booleans. It is tightly coupled to
the graph view UI (`graph.lua`), which renders an ASCII split-pane display of
backlinks and forward links in a floating window.

**Key entry points:**
- `graph_filter.build_predicate(state)` (line 250) -- composes individual
  predicates into a single `fun(path: string|nil): boolean`
- `graph_filter.collect_at_depth(center_path, depth, predicate)` (line 338) --
  BFS graph traversal through the vault index, applying predicates at each hop
- `graph_filter.apply(links, predicate)` (line 286) -- post-filters a link list

**Filter capabilities unique to graph_filter:**
- Multi-hop depth traversal via BFS over vault index outlinks/inlinks
- `show_orphans`, `show_unresolved`, `existing_only` toggle booleans
- Filter presets with JSON persistence (`.vault-graph-presets.json`)
- Interactive filter UI panel with numbered category sub-pickers

### 2. Search Filter System (`search_filter.lua` + `search_query.lua`)

The advanced search system parses textual queries into an AST via a tokenizer
and recursive descent parser, then evaluates the AST in a two-phase pipeline:
metadata filtering against the vault index, followed by ripgrep-based content
search. It supports boolean logic (AND/OR/NOT), field filters, `has:` checks,
task filters, regex, and quoted phrases.

**Key entry points:**
- `search_query.parse_query(query_string)` -- tokenize + parse into AST
- `search_filter.split_ast(ast)` -- separate metadata and text portions
- `search_filter.match_entry(ast, entry, index)` (line 633) -- evaluate
  metadata AST against a single VaultIndexEntry
- `search_filter.evaluate(ast, index)` (line 685) -- evaluate against all files
- `search_filter.ripgrep_in_files(text_ast, file_paths, vault_path)` (line 835)
  -- boolean-aware ripgrep dispatch
- `resolve_query(split, idx, vault_path)` in `search.lua` (line 95) -- shared
  evaluation helper for prompt and live modes

**Filter capabilities unique to search_filter:**
- Free-text content search via ripgrep
- Regex patterns (`/pattern/`)
- Boolean operator trees with proper precedence
- `has:` existence checks (tags, aliases, tasks, outlinks, inlinks, frontmatter)
- Task variant filters (`task:`, `task-todo:`, `task-done:`)
- Generic field evaluation (frontmatter + inline fields + field aliases)
- Numeric comparisons and ranges (`priority:>3`, `priority:1..3`)

### The Gap

These two systems share significant conceptual overlap -- both filter vault
files by metadata (tags, types, dates, paths) -- but they cannot interoperate:

1. **No way to run a graph traversal from search.** A user searching for
   `tag:active modified:<7d` cannot also say "show me notes within 2 hops of
   the current note that match these criteria."

2. **No way to use search operators in graph filters.** The graph filter UI
   only supports its fixed set of predicate categories. There is no way to
   express `has:tasks AND tag:urgent` or `priority:>3 OR status:"In Progress"`
   from the graph view.

3. **No way to pipe search results into a graph.** After running an advanced
   search, there is no option to visualize the result set as a graph (showing
   how matched notes connect to each other).

4. **Duplicated filter logic.** Both systems implement tag matching, type
   filtering, date comparison, and path filtering independently.
   `graph_filter.lua` uses its own `get_tags_for_file()` (line 60),
   `type_predicate()` (line 132), `date_predicate()` (line 162), and
   `path_predicate()` (line 219). Meanwhile `search_filter.lua` implements
   `match_field()` (line 211) with its own tag, type, date, path, and folder
   matching. The date resolution is shared via `date_utils.lua`, but the
   filtering logic itself is separate.

5. **Graph traversal is inaccessible to search.** The BFS algorithm in
   `collect_at_depth()` (line 338 of `graph_filter.lua`) traverses the vault
   index graph, but its results are only consumable by the graph view. Search
   cannot use link-distance as a filter criterion.

---

## Proposed Solution

### Design Overview

Introduce a `graph:` filter operator in the advanced search query language that
triggers graph traversal as a metadata filter, and add a "search to graph"
pipeline that takes search results and feeds them into a graph visualization.
Additionally, refactor the shared filtering logic so both systems delegate to a
common predicate library.

The integration operates at three levels:

1. **Search-side: `graph:` operator** -- A new AST node type that embeds a
   graph traversal constraint inside a search query. Example:
   `graph:depth=2 tag:active` means "notes within 2 link-hops of the current
   note that have tag `active`."

2. **Graph-side: search expression filter** -- Allow the graph filter UI to
   accept a search query string as an additional filter predicate, evaluated via
   `search_filter.match_entry()` against each candidate node.

3. **Result bridging** -- Pipe search results into a graph view, and pipe graph
   nodes into the search results picker.

### Architecture

```
                    User Query: "graph:depth=2 tag:active deploy"
                                    |
                        +-----------v-----------+
                        |   search_query.lua    |
                        |   tokenize + parse    |
                        +-----------+-----------+
                                    |
                            Query AST:
                            AND(
                              graph(depth=2, center=current),
                              field("tag", "=", "active"),
                              text("deploy")
                            )
                                    |
                        +-----------v-----------+
                        |  search_filter.lua    |
                        |  split_ast()          |
                        +-----------+-----------+
                                    |
              +---------------------+---------------------+
              |                     |                     |
    +---------v--------+  +---------v--------+  +---------v--------+
    | graph traversal  |  | metadata filter  |  | ripgrep text     |
    | (vault index BFS)|  | (vault index)    |  | search           |
    +--------+---------+  +--------+---------+  +--------+---------+
              |                     |                     |
              +------> intersect <--+-------> intersect <-+
                           |
                  +--------v--------+
                  | fzf-lua display |
                  | (or graph view) |
                  +-----------------+
```

### Proposed Changes

#### 1. New AST Node Type: `graph`

**File: `lua/andrew/vault/search_query.lua`**

Add a `GRAPH` token type and a `graph` AST node that the tokenizer recognizes
when it encounters `graph:` as a field prefix.

```lua
-- New token type
M.TK.GRAPH = "GRAPH"

-- AST node:
-- { type = "graph", center = "current"|string, depth = number,
--   direction = "both"|"forward"|"backward" }
```

The tokenizer already handles `field:value` syntax via `parse_field_token()`
(line 81). The `graph:` prefix would be intercepted before the generic field
parsing:

```lua
-- In parse_field_token(), before the identifier check:
if name == "graph" then
  local params = parse_graph_params(raw_value)
  return token(TK.GRAPH, params, pos)
end
```

**Graph parameter syntax:**

```
graph:depth=2                    -- 2 hops from current note, both directions
graph:depth=3,dir=forward        -- 3 hops, outlinks only
graph:depth=2,dir=backward       -- 2 hops, inlinks only
graph:depth=2,center=Dashboard   -- 2 hops from a named note (not current)
graph:neighbors                  -- shorthand for depth=1 (direct connections)
graph:extended                   -- shorthand for depth=2
```

Parameters are comma-separated `key=value` pairs. Recognized keys:
- `depth` (number, default 1): maximum link hops
- `dir` / `direction` (`both`|`forward`|`backward`, default `both`)
- `center` (string, default `current`): the note to traverse from

The parser routes `GRAPH` tokens through `parse_primary`:

```lua
if tok.type == TK.GRAPH then
  P:advance()
  return {
    type = "graph",
    depth = tok.value.depth or 1,
    direction = tok.value.direction or "both",
    center = tok.value.center or "current",
  }
end
```

#### 2. Graph Traversal as a Metadata Filter

**File: `lua/andrew/vault/search_filter.lua`**

Extend the `METADATA_TYPES` table (line 20) to include the new `graph` type:

```lua
local METADATA_TYPES = {
  field = true,
  has = true,
  task = true,
  graph = true,  -- NEW
}
```

Add a new `match_graph()` function and integrate it into `match_entry()`.
However, graph traversal is fundamentally different from per-entry predicates --
it produces a **set of reachable nodes** rather than testing a single entry.
This requires a pre-computation step.

**Strategy: Pre-compute the reachable set, then use set membership as the
predicate.**

Add a new function `precompute_graph_sets()` that walks the AST looking for
`graph` nodes, resolves each one into a set of reachable `rel_path` values,
and returns a lookup table:

```lua
--- Pre-compute graph traversal results for all graph: nodes in an AST.
--- Returns a table mapping graph node identity to a set of reachable rel_paths.
---@param ast table parsed AST
---@param index VaultIndex
---@param current_path string|nil absolute path of current buffer
---@return table<string, table<string, boolean>> graph_id -> {rel_path -> true}
function M.precompute_graph_sets(ast, index, current_path)
  local sets = {}

  local function walk(node)
    if not node then return end
    if node.type == "graph" then
      local graph_id = string.format("graph_%s_%d_%s",
        node.center, node.depth, node.direction)
      if not sets[graph_id] then
        local center_abs = resolve_graph_center(node.center, current_path, index)
        if center_abs then
          local reachable = collect_reachable(index, center_abs, node.depth, node.direction)
          sets[graph_id] = reachable
        else
          sets[graph_id] = {}
        end
      end
      node._graph_id = graph_id  -- annotate for match_entry
      return
    end
    if node.type == "and" or node.type == "or" then
      walk(node.left)
      walk(node.right)
    elseif node.type == "not" then
      walk(node.operand)
    end
  end

  walk(ast)
  return sets
end
```

The `collect_reachable()` helper reuses the BFS logic from
`graph_filter.collect_at_depth()` but extracts it into a shared utility that
returns a set of `rel_path` values rather than the forward/backlink partition:

```lua
--- Collect all notes reachable within N hops from a center note.
---@param index VaultIndex
---@param center_abs string absolute path of center note
---@param depth number max hops
---@param direction "both"|"forward"|"backward"
---@return table<string, boolean> reachable rel_paths (including center)
local function collect_reachable(index, center_abs, depth, direction)
  local engine = require("andrew.vault.engine")
  local config = require("andrew.vault.config")
  local max_nodes = config.graph.max_nodes

  local center_rel = engine.vault_relative(center_abs)
  if not center_rel then return {} end

  local center_entry = index:get_entry(center_rel)
  if not center_entry then return {} end

  local reachable = { [center_rel] = true }
  local queue = { { rel = center_rel, d = 0 } }

  while #queue > 0 and vim.tbl_count(reachable) < max_nodes do
    local current = table.remove(queue, 1)
    if current.d >= depth then goto skip end

    local entry = index:get_entry(current.rel)
    if not entry then goto skip end

    -- Outlinks (forward direction)
    if direction == "both" or direction == "forward" then
      for _, link in ipairs(entry.outlinks) do
        local target_rel = resolve_in_index(index, link.path or "")
        if target_rel and not reachable[target_rel] then
          reachable[target_rel] = true
          table.insert(queue, { rel = target_rel, d = current.d + 1 })
        end
      end
    end

    -- Inlinks (backward direction)
    if direction == "both" or direction == "backward" then
      local inlinks = index:get_inlinks(current.rel)
      for _, link in ipairs(inlinks) do
        local source_rel = link.path .. ".md"
        if not reachable[source_rel] then
          local source_entry = index:get_entry(source_rel)
          if source_entry then
            reachable[source_rel] = true
            table.insert(queue, { rel = source_rel, d = current.d + 1 })
          end
        end
      end
    end

    ::skip::
  end

  return reachable
end
```

Then `match_entry()` (line 633) gains a `graph_sets` parameter:

```lua
---@param ast table|nil metadata AST node
---@param entry table VaultIndexEntry
---@param index table|nil VaultIndex instance
---@param graph_sets table|nil pre-computed graph reachable sets
---@return boolean
function M.match_entry(ast, entry, index, graph_sets)
  -- ... existing logic ...

  if t == "graph" then
    if not graph_sets or not ast._graph_id then return true end
    local set = graph_sets[ast._graph_id]
    return set ~= nil and set[entry.rel_path] == true
  end

  -- ... propagate graph_sets in recursive calls ...
end
```

**The `evaluate()` function** (line 685) also needs the `graph_sets` parameter:

```lua
function M.evaluate(ast, index, graph_sets)
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

#### 3. Integrate into Search Evaluation

**File: `lua/andrew/vault/search.lua`**

Modify `resolve_query()` (line 95) to detect `graph` nodes in the AST,
pre-compute the reachable sets, and pass them through the filter pipeline:

```lua
local function resolve_query(split, idx, vault_path)
  local search_filter = require("andrew.vault.search_filter")

  -- Pre-compute graph traversal sets if the AST contains graph: nodes
  local graph_sets = nil
  local current_path = vim.api.nvim_buf_get_name(0)
  if ast_contains_graph(split.metadata_ast) then
    graph_sets = search_filter.precompute_graph_sets(
      split.metadata_ast, idx, current_path)
  end

  if split.mode == "metadata_only" then
    local matches = search_filter.evaluate(split.metadata_ast, idx, graph_sets)
    -- ... rest unchanged ...
  end

  if split.mode == "metadata_then_text" then
    local matches = search_filter.evaluate(split.metadata_ast, idx, graph_sets)
    -- ... rest unchanged ...
  end

  -- ... other modes similarly updated ...
end
```

A small helper detects graph nodes anywhere in an AST:

```lua
--- Check if an AST contains any graph: nodes.
---@param ast table|nil
---@return boolean
local function ast_contains_graph(ast)
  if not ast then return false end
  if ast.type == "graph" then return true end
  if ast.type == "and" or ast.type == "or" then
    return ast_contains_graph(ast.left) or ast_contains_graph(ast.right)
  end
  if ast.type == "not" then
    return ast_contains_graph(ast.operand)
  end
  return false
end
```

#### 4. Graph Filter UI: Accept Search Expression

**File: `lua/andrew/vault/graph_filter.lua`**

Add an optional `search_expr` field to `GraphFilterState` (line 12):

```lua
---@class GraphFilterState
---@field tags_include string[]
---@field tags_exclude string[]
---@field note_types string[]
---@field date_field "created"|"modified"|nil
---@field date_from string|nil
---@field date_to string|nil
---@field depth number
---@field paths_include string[]
---@field paths_exclude string[]
---@field show_orphans boolean
---@field show_unresolved boolean
---@field existing_only boolean
---@field search_expr string|nil          -- NEW: advanced search expression
```

Add a new predicate builder that compiles the search expression into a
predicate function usable by `build_predicate()`:

```lua
--- Build a predicate from an advanced search expression string.
--- Evaluates the parsed AST's metadata portion against each candidate note.
---@param expr string search expression (e.g., "has:tasks AND tag:urgent")
---@return fun(path: string): boolean|nil predicate, or nil on parse error
function M.search_expr_predicate(expr)
  local search_query = require("andrew.vault.search_query")
  local search_filter = require("andrew.vault.search_filter")
  local vault_index = require("andrew.vault.vault_index")

  local ast, err = search_query.parse_query(expr)
  if not ast then return nil end

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return nil end

  -- Only use the metadata portion (graph predicates don't use text search)
  local split = search_filter.split_ast(ast)
  local meta_ast = split.metadata_ast
  if not meta_ast then
    -- Pure text query: can't be used as a graph predicate
    return nil
  end

  return function(abs_path)
    local entry = idx:get_entry_by_abs(abs_path)
    if not entry then return false end
    return search_filter.match_entry(meta_ast, entry, idx)
  end
end
```

Integrate into `build_predicate()` (line 250):

```lua
function M.build_predicate(state)
  local predicates = {}

  -- ... existing predicates ...

  -- NEW: search expression predicate
  if state.search_expr and state.search_expr ~= "" then
    local expr_pred = M.search_expr_predicate(state.search_expr)
    if expr_pred then
      predicates[#predicates + 1] = expr_pred
    end
  end

  return function(path)
    -- ... unchanged ...
  end
end
```

Add a new sub-filter category (category 8) for the search expression in the
filter UI. The `open_filter_ui()` function (line 823) gains an eighth row:

```lua
local function render_menu()
  return {
    "  [1] Tags include: " .. ...,
    "  [2] Tags exclude: " .. ...,
    "  [3] Note type:    " .. ...,
    "  [4] Date range:   " .. ...,
    "  [5] Depth:        " .. state.depth,
    "  [6] Path exclude: " .. ...,
    "  [7] Toggles:      " .. ...,
    "  [8] Search expr:  " .. (state.search_expr or "(none)"),  -- NEW
    "",
    "  [r] Reset all   [a] Apply & close   [q] Cancel",
  }
end
```

Category 8 opens a float input where the user types an advanced search
expression:

```lua
elseif category == 8 then
  -- Search expression
  local ui = require("andrew.vault.ui")
  local float = ui.create_float_input({
    title = "Search expression (e.g., has:tasks AND tag:urgent)",
    width = 70,
    on_submit = function(lines)
      local input = lines[1] or ""
      if input == "" then
        state.search_expr = nil
      else
        -- Validate the expression parses correctly
        local search_query = require("andrew.vault.search_query")
        local ast, err = search_query.parse_query(input)
        if ast then
          state.search_expr = input
        else
          vim.notify("Invalid search expression: " .. (err or "unknown"),
            vim.log.levels.WARN)
        end
      end
      on_done()
    end,
    submit_modes = { "n", "i" },
  })
end
```

#### 5. Search Results to Graph Bridge

**File: `lua/andrew/vault/search.lua`**

Add a new action in the advanced search fzf picker that takes the current
result set and opens a graph view centered on those files.

In `execute_advanced_query()` (line 170), extend the fzf actions:

```lua
actions["ctrl-g"] = {
  fn = function(selected, opts)
    -- Collect all result file paths
    local file_set = collect_result_files(result.entries)
    -- Open a graph view restricted to this file set
    require("andrew.vault.graph").search_result_graph(file_set, query_string)
  end,
  reload = false,
}
```

**File: `lua/andrew/vault/graph.lua`**

Add a new entry point `search_result_graph(file_set, query_label)` that renders
a graph showing how the given files connect to each other:

```lua
--- Render a graph of connections between a set of search result files.
---@param file_set table<string, boolean> abs_path -> true
---@param query_label string display label for the graph title
function M.search_result_graph(file_set, query_label)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    vim.notify("Vault index not ready", vim.log.levels.WARN)
    return
  end

  -- Build adjacency within the file set
  local forward_links = {}  -- entries with outlinks pointing to other files in set
  local backlinks = {}      -- entries with inlinks from other files in set

  for abs_path in pairs(file_set) do
    local entry = idx:get_entry_by_abs(abs_path)
    if entry then
      for _, link in ipairs(entry.outlinks) do
        local target_rel = resolve_in_index(idx, link.path or "")
        if target_rel then
          local target = idx:get_entry(target_rel)
          if target and file_set[target.abs_path] then
            -- This is an internal edge within the result set
            forward_links[#forward_links + 1] = {
              from = entry.basename,
              from_path = abs_path,
              to = target.basename,
              to_path = target.abs_path,
            }
          end
        end
      end
    end
  end

  -- Render as a connection list or adjacency display
  -- ... (uses a simplified version of render_graph or a new renderer) ...
end
```

This is a more complex UI challenge -- the current ASCII renderer is designed
for a center-node-with-two-columns layout. For a result set graph, a simpler
approach is a **connection list** showing edges between matched files:

```
 ┌──── Search Result Graph: tag:active deploy ────┐
 │                                                 │
 │  Dashboard ──── Project Alpha                   │
 │  Dashboard ──── Weekly Review                   │
 │  Project Alpha ──── Sprint Plan                 │
 │  Sprint Plan ──── Weekly Review                 │
 │                                                 │
 │  4 connections among 4 notes                    │
 └─────────────────────────────────────────────────┘
```

#### 6. Graph Nodes to Search Bridge

**File: `lua/andrew/vault/graph.lua`**

Add a keymap `s` in the graph float that opens advanced search pre-filtered to
the currently visible graph nodes:

```lua
-- s: search within graph nodes
vim.keymap.set("n", "s", function()
  -- Collect all file paths visible in the current graph
  local paths = {}
  for _, entry in pairs(graph_ctx.line_to_note) do
    if entry.backlink then paths[#paths + 1] = entry.backlink end
    if entry.forward then paths[#paths + 1] = entry.forward end
  end
  paths[#paths + 1] = graph_ctx.source_buf_name  -- include center note

  -- Open advanced search restricted to these files
  float.close()
  require("andrew.vault.search").search_in_files(paths)
end, { buffer = buf, nowait = true, silent = true, desc = "Search within graph nodes" })
```

**File: `lua/andrew/vault/search.lua`**

Add a new `search_in_files(file_paths)` function that runs fzf_live restricted
to a given file set:

```lua
--- Run advanced live search restricted to a specific set of files.
---@param file_paths string[] absolute file paths to search within
function M.search_in_files(file_paths)
  if #file_paths == 0 then
    vim.notify("No files to search", vim.log.levels.INFO)
    return
  end

  local fzf = require("fzf-lua")
  local search_filter = require("andrew.vault.search_filter")
  local search_query = require("andrew.vault.search_query")
  local vault_index = require("andrew.vault.vault_index")

  local idx = vault_index.current()
  local file_set = {}
  for _, p in ipairs(file_paths) do file_set[p] = true end

  fzf.fzf_live(function(args)
    local query_string = type(args) == "table" and args[1] or args
    if type(query_string) ~= "string" or query_string == "" then return {} end

    local ast = search_query.parse_query(query_string)
    if not ast then return {} end

    local split = search_filter.split_ast(ast)

    -- Restrict to the given file set
    local candidate_paths = file_paths
    if split.metadata_ast and idx and idx:is_ready() then
      local matches = search_filter.evaluate(split.metadata_ast, idx)
      candidate_paths = {}
      for _, entry in pairs(matches) do
        if file_set[entry.abs_path] then
          candidate_paths[#candidate_paths + 1] = entry.abs_path
        end
      end
    end

    if split.text_ast then
      return search_filter.ripgrep_in_files(
        split.text_ast, candidate_paths, engine.vault_path)
    end

    -- Metadata-only: return file paths
    local entries = {}
    for _, p in ipairs(candidate_paths) do
      local rel = engine.vault_relative(p)
      if rel then entries[#entries + 1] = rel end
    end
    table.sort(entries)
    return entries
  end, vim.tbl_extend("force",
    engine.vault_fzf_opts("Search in graph nodes"),
    {
      previewer = "builtin",
      exec_empty_query = false,
      query_delay = config.search.live_debounce_ms,
    }
  ))
end
```

#### 7. Refactor Shared Predicate Logic

**New file: `lua/andrew/vault/filter_utils.lua`**

Extract the common predicate functions that both `graph_filter.lua` and
`search_filter.lua` implement into a shared utility module. This reduces
duplication and ensures consistent behavior.

```lua
--- Shared filter utilities for graph and search filtering.
local M = {}

local date_utils = require("andrew.vault.date_utils")
local vault_index = require("andrew.vault.vault_index")

--- Get tags for a file from the vault index.
---@param abs_path string
---@return table<string, boolean> tag_set
function M.get_tags(abs_path)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return {} end
  local entry = idx:get_entry_by_abs(abs_path)
  if not entry or not entry.tags then return {} end
  local set = {}
  for _, t in ipairs(entry.tags) do set[t] = true end
  return set
end

--- Get a file timestamp (created or modified).
---@param abs_path string
---@param field "created"|"modified"
---@return number|nil
function M.get_timestamp(abs_path, field)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return nil end
  local entry = idx:get_entry_by_abs(abs_path)
  if not entry then return nil end

  if entry.frontmatter and entry.frontmatter[field] then
    local ts = date_utils.parse_iso_datetime(tostring(entry.frontmatter[field]), 12)
    if ts then return ts end
  end

  if field == "modified" and entry.mtime then return entry.mtime end
  if field == "created" then
    return entry.ctime or entry.mtime
  end

  return nil
end

--- Get the frontmatter type for a file.
---@param abs_path string
---@return string|nil
function M.get_type(abs_path)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return nil end
  local entry = idx:get_entry_by_abs(abs_path)
  if not entry or not entry.frontmatter then return nil end
  return entry.frontmatter.type
end

return M
```

`graph_filter.lua` can then delegate to `filter_utils` instead of maintaining
its own `_file_tag_cache` and `_get_file_timestamp()`:

```lua
-- In graph_filter.lua, replace get_tags_for_file:
function M.get_tags_for_file(abs_path)
  return require("andrew.vault.filter_utils").get_tags(abs_path)
end
```

This is a cleanup improvement, not strictly required for the integration, but
reduces maintenance burden and ensures tag matching behaves identically in both
systems.

#### 8. Configuration

**File: `lua/andrew/vault/config.lua`**

Add graph-search integration settings:

```lua
M.graph = {
  -- ... existing settings ...

  -- Search integration
  search_expr_enabled = true,   -- enable search expression filter in graph UI
  search_to_graph = true,       -- enable Ctrl-g "view as graph" in search results
  graph_to_search = true,       -- enable 's' "search in nodes" from graph view
}

M.search = {
  -- ... existing settings ...

  -- Graph integration
  graph_operator = true,        -- enable graph: operator in search queries
  graph_max_depth = 5,          -- max depth for graph: operator (safety limit)
}
```

#### 9. Completion and Help Updates

**File: `lua/andrew/vault/search.lua`**

Extend `_complete_advanced()` (line 462) to suggest `graph:` and its parameters:

```lua
-- In _complete_advanced():

-- graph: operator completion
if lead:match("^graph:") then
  local prefix = "graph:"
  local rest = lead:sub(#prefix + 1)
  local graph_completions = {
    "depth=1", "depth=2", "depth=3",
    "dir=forward", "dir=backward", "dir=both",
    "neighbors", "extended",
  }
  for _, c in ipairs(graph_completions) do
    if c:sub(1, #rest) == rest then
      candidates[#candidates + 1] = prefix .. c
    end
  end
elseif "graph:":sub(1, #lead) == lead then
  candidates[#candidates + 1] = "graph:"
end
```

Extend `search_help()` (line 371) with graph operator documentation:

```lua
-- Add to the help lines:
"",
"Graph Traversal:",
"  graph:depth=2               Notes within 2 hops of current note",
"  graph:depth=3,dir=forward   3 hops, outlinks only",
"  graph:depth=2,dir=backward  2 hops, inlinks only",
"  graph:neighbors             Shorthand for depth=1",
"  graph:extended              Shorthand for depth=2",
"  graph:depth=2 tag:active    Combine with other filters",
```

Update the `SEARCH_HEADER` compact hint (line 84) to include `graph:`:

```lua
local SEARCH_HEADER = table.concat({
  "field:value  tag:x  path:P/  has:tags  created:>7d  graph:depth=2",
  "AND  OR  NOT  -excluded  (a OR b) AND c   |  Ctrl-/ full help  Ctrl-g graph",
}, "\n")
```

Also update graph help (`graph_filter.show_help()`, line 927) to include the
search expression and search bridge keybindings:

```lua
-- Add to graph help lines:
"",
"  Search Integration:",
"    s            Search within visible graph nodes",
"    8            Set search expression filter (in filter panel)",
```

---

## Step-by-Step Implementation Plan

### Phase 1: Shared Filter Utilities (Low Risk)

1. Create `lua/andrew/vault/filter_utils.lua` with shared `get_tags()`,
   `get_timestamp()`, `get_type()` functions.
2. Update `graph_filter.lua` to delegate to `filter_utils` where possible.
   Keep backward compatibility by leaving the public API unchanged.
3. Test: Verify graph filtering still works identically after the refactor.

### Phase 2: Search Expression in Graph Filter (Medium Risk)

4. Add `search_expr` field to `GraphFilterState` in `graph_filter.lua`.
5. Add `search_expr_predicate()` function to `graph_filter.lua`.
6. Integrate into `build_predicate()`.
7. Add category 8 ("Search expr") to the filter UI menu.
8. Add the sub-filter input handler in `open_sub_filter()`.
9. Update `format_status()` to display the active search expression.
10. Update `default_state()` to include `search_expr = nil`.
11. Test: Open graph, press `f`, set a search expression, verify nodes are
    filtered accordingly.

### Phase 3: `graph:` Operator in Search (Higher Risk)

12. Add `TK.GRAPH` to `search_query.lua` token types.
13. Add `parse_graph_params()` helper to parse `depth=N,dir=X` syntax.
14. Modify `parse_field_token()` to intercept `graph:` prefix before generic
    field parsing.
15. Add the `graph` case to `parse_primary()` in the parser.
16. Add `graph = true` to `METADATA_TYPES` in `search_filter.lua`.
17. Implement `collect_reachable()` in `search_filter.lua` (extracting BFS
    logic from `graph_filter.collect_at_depth()`).
18. Implement `precompute_graph_sets()` in `search_filter.lua`.
19. Add `graph_sets` parameter to `match_entry()` and `evaluate()`.
20. Update `resolve_query()` in `search.lua` to call
    `precompute_graph_sets()` when graph nodes are detected.
21. Update `search_advanced_live()` to pass `current_path` through.
22. Add completion entries for `graph:` in `_complete_advanced()`.
23. Update `search_help()` with graph operator documentation.
24. Test: Run queries like `graph:depth=2 tag:active` and verify results are
    within 2 hops of the current note and have the `active` tag.

### Phase 4: Bidirectional Bridges (Medium Risk)

25. Add `Ctrl-g` action to `execute_advanced_query()` in `search.lua` that
    collects result file paths and opens `search_result_graph()`.
26. Implement `search_result_graph()` in `graph.lua` -- a simplified graph
    renderer showing edges between result files.
27. Add `s` keymap to the graph float in `local_graph()` that collects visible
    node paths and opens `search_in_files()`.
28. Implement `search_in_files(file_paths)` in `search.lua`.
29. Update the search header hint to show `Ctrl-g` for graph view.
30. Update graph help to show `s` for search within nodes.
31. Test: Run a search, press `Ctrl-g`, verify graph shows connections.
    Open a graph, press `s`, verify search is restricted to visible nodes.

### Phase 5: Configuration and Polish

32. Add configuration keys to `config.lua` for enabling/disabling integration
    features.
33. Guard all new functionality behind config checks.
34. Update MEMORY.md with new module relationships and integration points.
35. Final integration testing across all paths.

---

## Edge Cases and Considerations

### Graph Traversal Performance

The `graph:` operator triggers a BFS traversal of the vault index. At depth 3+,
this can visit hundreds of nodes. Mitigations:

- **Max nodes cap**: Reuse `config.graph.max_nodes` (default 50) as the BFS
  termination condition. Document that `graph:depth=5` may not reach all nodes
  in a highly connected vault.
- **Pre-computation is per-query**: The BFS runs once per unique `graph:` node
  in the AST, not per-entry. For a query like `graph:depth=2 tag:active`, the
  BFS runs once to produce a reachable set, then membership testing is O(1) per
  entry.
- **Live mode concern**: In `search_advanced_live()`, the query is re-evaluated
  on every keystroke (debounced). If the user types `graph:depth=3` while
  editing, the BFS re-runs on each change. The debounce
  (`config.search.live_debounce_ms`, default 150ms) provides some protection,
  but consider caching the last graph result keyed on `(center_path, depth,
  direction)` and invalidating only when the current buffer changes.

### Current Buffer as Graph Center

The `graph:` operator defaults to `center=current`, which is the buffer that
was active when the search was invoked. In live mode, the "current" buffer is
the fzf input buffer, not the user's note buffer. The implementation must
capture the original buffer path before entering fzf:

```lua
-- In search_advanced_live(), capture before fzf opens:
local source_path = vim.api.nvim_buf_get_name(0)

-- Pass to resolve_query:
local graph_sets = search_filter.precompute_graph_sets(
  split.metadata_ast, idx, source_path)
```

### Named Center Note

`graph:center=Dashboard` requires resolving the note name to an absolute path.
Use the existing `wikilinks.resolve_link()` function, which handles
case-insensitive name matching and alias resolution:

```lua
local function resolve_graph_center(center_spec, current_path, index)
  if center_spec == "current" or center_spec == nil then
    return current_path
  end
  -- Resolve as a note name
  local wikilinks = require("andrew.vault.wikilinks")
  return wikilinks.resolve_link(center_spec)
end
```

### Interaction with NOT Operator

`NOT graph:depth=2` should match notes that are **not** within 2 hops of the
current note. This is handled naturally by the existing `match_entry()` NOT
logic: `not match_entry(ast.operand, entry, index, graph_sets)`. The reachable
set is pre-computed, and membership is negated.

However, `NOT graph:depth=2 tag:active` (parsed as `NOT (graph:depth=2) AND
tag:active`) means "notes that are not within 2 hops AND have tag active."
This is correct but potentially surprising. Users who want "notes within 2 hops
that do not have tag active" should write `graph:depth=2 NOT tag:active` or
`graph:depth=2 -tag:active`.

### Search Expression in Graph: Text Terms

If a user enters a search expression with text terms in the graph filter UI
(e.g., `deploy AND tag:active`), the text portion cannot be evaluated as a
node predicate because graph filtering operates on file paths, not file
contents. Two options:

1. **Reject text terms**: Validate the expression and warn the user that only
   metadata filters are supported in graph filter expressions. This is the
   simpler and more predictable approach.

2. **Shell out to ripgrep**: For each candidate node, check if the file
   contains the text term by running a quick `rg -l -F "deploy" <path>`.
   This is expensive and defeats the purpose of the graph's fast predicate
   system.

**Recommendation**: Option 1. Validate in `search_expr_predicate()`:

```lua
function M.search_expr_predicate(expr)
  -- ... parse ...
  local split = search_filter.split_ast(ast)
  if split.text_ast then
    vim.notify("Graph filter: text search terms are not supported in " ..
      "search expressions. Use metadata filters only (tag:, type:, has:, etc.)",
      vim.log.levels.WARN)
    return nil
  end
  -- ... proceed with metadata_ast only ...
end
```

### Graph Preset Serialization

The `search_expr` field is a plain string, so it serializes to JSON naturally
via `vim.deepcopy()` in `save_preset()` (line 508). No changes needed for
preset persistence.

### Empty Results

- `graph:depth=2` with no other filters on an isolated note (no links):
  returns only the current note itself. Combined with other filters, this may
  produce zero results.
- `graph:depth=0` is a valid but degenerate case: only the center note. The
  implementation should handle `depth=0` gracefully (return only center).
- If the vault index is not ready, the `graph:` operator should degrade
  gracefully. Since `precompute_graph_sets()` checks `idx:is_ready()`, it
  returns an empty set, effectively making the graph filter match nothing. A
  warning notification should inform the user.

### AST Classification

The `graph` node is classified as a `METADATA_TYPE` because it can be
evaluated entirely from the vault index (no ripgrep needed). This means:

- In a query like `graph:depth=2 tag:active`, both `graph` and `tag` are
  metadata. `split_ast()` produces `mode = "metadata_only"`, and the entire
  query is evaluated in-memory.
- In a query like `graph:depth=2 deploy`, `graph` is metadata and `deploy` is
  text. `split_ast()` produces `mode = "metadata_then_text"`. The graph
  reachable set is intersected with files containing "deploy."
- In a query like `graph:depth=2 OR tag:active`, both sides are metadata.
  `split_ast()` produces `mode = "metadata_only"` with an OR tree.

### Backward Compatibility

All changes are additive:

- `graph:` is a new token type. Existing queries without `graph:` are
  unaffected by the tokenizer change.
- `graph_sets` defaults to `nil` in `match_entry()` and `evaluate()`, which
  means existing callers (including graph_filter's own `search_expr_predicate`)
  work without modification.
- `search_expr` defaults to `nil` in `GraphFilterState`, so existing presets
  deserialize correctly via `vim.tbl_deep_extend("keep", preset, default)`.
- The `s` and `Ctrl-g` keybindings are new additions that don't conflict with
  existing keymaps.

---

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `lua/andrew/vault/filter_utils.lua` | **Create** | Shared filter utility functions (tags, timestamps, types) |
| `lua/andrew/vault/search_query.lua` | **Modify** | Add `TK.GRAPH` token, `parse_graph_params()`, intercept in `parse_field_token()` and `parse_primary()` |
| `lua/andrew/vault/search_filter.lua` | **Modify** | Add `graph` to `METADATA_TYPES`, implement `precompute_graph_sets()`, `collect_reachable()`, add `graph_sets` param to `match_entry()` and `evaluate()` |
| `lua/andrew/vault/search.lua` | **Modify** | Update `resolve_query()` for graph sets, add `search_in_files()`, add `Ctrl-g` action, update completion and help |
| `lua/andrew/vault/graph_filter.lua` | **Modify** | Add `search_expr` to state, `search_expr_predicate()`, category 8 in filter UI, update `format_status()` and `default_state()` |
| `lua/andrew/vault/graph.lua` | **Modify** | Add `search_result_graph()`, add `s` keymap for search-in-nodes, update help hints |
| `lua/andrew/vault/config.lua` | **Modify** | Add integration config keys under `M.graph` and `M.search` |

---

## Testing Strategy

### Unit Tests

1. **`parse_graph_params()` parsing**
   - `"depth=2"` -> `{ depth = 2, direction = "both", center = "current" }`
   - `"depth=3,dir=forward"` -> `{ depth = 3, direction = "forward", center = "current" }`
   - `"neighbors"` -> `{ depth = 1, direction = "both", center = "current" }`
   - `"extended"` -> `{ depth = 2, direction = "both", center = "current" }`
   - `"depth=2,center=Dashboard"` -> `{ depth = 2, direction = "both", center = "Dashboard" }`
   - Invalid: `"depth=abc"` -> default depth 1

2. **Tokenizer: graph token recognition**
   - `"graph:depth=2"` -> `[GRAPH({depth=2, ...})]`
   - `"graph:depth=2 tag:active"` -> `[GRAPH(...), FIELD("tag","active")]`
   - `"graphite"` -> `[TEXT("graphite")]` (not confused with graph:)

3. **Parser: graph AST nodes**
   - `"graph:depth=2"` -> `{ type = "graph", depth = 2, ... }`
   - `"graph:depth=2 tag:active"` -> `{ type = "and", left = graph(...), right = field(...) }`
   - `"NOT graph:depth=2"` -> `{ type = "not", operand = graph(...) }`

4. **`collect_reachable()` correctness**
   - Set up a vault index with chain A -> B -> C -> D:
     - depth=1 from A: {A, B}
     - depth=2 from A: {A, B, C}
     - depth=3 from A: {A, B, C, D}
   - Direction filtering: `forward` from A at depth=2: {A, B, C} (outlinks only)
   - Direction filtering: `backward` from C at depth=1: {C, B} (inlinks only)
   - Max nodes cap: set cap to 3, depth=5 on highly connected graph, verify
     result size <= 3

5. **`precompute_graph_sets()` annotation**
   - Verify `_graph_id` is set on graph AST nodes
   - Verify the returned sets map contains the correct reachable paths
   - Verify multiple graph nodes in one query get separate sets

6. **`match_entry()` with graph sets**
   - Entry in reachable set: returns true
   - Entry not in reachable set: returns false
   - No graph sets (nil): returns true (pass-through)

7. **`search_expr_predicate()` in graph_filter**
   - Valid metadata expression `"tag:active"`: returns a working predicate
   - Expression with text terms `"deploy"`: returns nil with warning
   - Invalid expression `"AND AND"`: returns nil
   - Empty expression: returns nil

### Integration Tests (Manual)

8. **Search with graph operator**
   - Open a note with known connections
   - Run `:VaultSearchAdvanced` with `graph:depth=2`
   - Verify results are within 2 hops
   - Run `graph:depth=2 tag:active` -- verify intersection

9. **Search with graph operator in live mode**
   - Run `:VaultSearchAdvancedLive`
   - Type `graph:depth=1` -- verify results update to direct neighbors
   - Add ` tag:meeting` -- verify results narrow to tagged neighbors

10. **Graph filter with search expression**
    - Open `:VaultGraph`
    - Press `f`, then `8`
    - Type `has:tasks AND tag:urgent`
    - Verify graph shows only nodes matching the expression

11. **Search to graph bridge (Ctrl-g)**
    - Run an advanced search producing multiple results
    - Press `Ctrl-g`
    - Verify a graph view opens showing connections between result files

12. **Graph to search bridge (s)**
    - Open `:VaultGraph` on a note with several connections
    - Press `s`
    - Verify a search interface opens restricted to visible graph nodes
    - Type a search term, verify results come only from those files

13. **Saved search with graph operator**
    - Run `graph:depth=2 tag:active`, save as "Active neighbors"
    - Load from `:VaultSearchList`
    - Verify it re-executes correctly (using current note as center)

14. **Edge case: isolated note**
    - Open a note with no links
    - Run `graph:depth=3`
    - Verify only the current note appears (or empty if combined with other
      filters that exclude it)

15. **Edge case: vault index not ready**
    - Simulate cold start (index not built)
    - Run `graph:depth=2 tag:active`
    - Verify graceful degradation with notification

### Performance Benchmarks

16. **BFS traversal speed**: On a 500-file vault, measure
    `collect_reachable()` at depth=3. Target: < 50ms (pure in-memory BFS over
    the vault index, no I/O).

17. **Live mode with graph operator**: Measure time from keystroke to result
    display for `graph:depth=2 tag:active`. Target: < 300ms including BFS +
    metadata filter + fzf rendering.

18. **Graph filter with search expression**: Measure predicate evaluation
    overhead per node when `search_expr` is set. Target: < 1ms per node
    (since it's an in-memory AST evaluation).
