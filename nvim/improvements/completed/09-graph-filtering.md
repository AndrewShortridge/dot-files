# Graph Filtering

## Current State

The vault module provides a local graph view via `lua/andrew/vault/graph.lua`, opened with `<leader>vG` or `:VaultGraph`. It renders an ASCII-based split-pane display inside a floating window showing:

- **Left column**: Backlinks (notes that link to the current note, discovered via `rg`)
- **Right column**: Forward links (wikilinks extracted from the current buffer)
- **Navigation**: `<CR>` / `gf` to follow links, `q` / `<Esc>` to close

### How the graph is built

1. `local_graph()` calls `collect_forward_links()` which parses the current buffer line-by-line, extracting `[[...]]` wikilinks while skipping frontmatter, code fences, embeds, and inline fields.
2. `collect_backlinks(note_name)` runs a synchronous `rg` search for `[[note_name` across all `*.md` files in the vault.
3. Both lists are deduplicated, self-references are removed, ambiguous names are disambiguated via vault-relative paths.
4. `render_graph()` produces ASCII box-drawing output with connector lines, highlights for existing vs. broken links, and summary counts.
5. The result is displayed via `ui.create_float_display()` -- a centered floating window with `cursorline` enabled.

### Related modules

| Module | Relevance |
|--------|-----------|
| `graph.lua` | The local graph renderer -- primary target for modification |
| `tags.lua` | Collects all vault tags via `rg` (async, cached with 15s TTL) |
| `connections.lua` | Multi-signal relatedness scoring using the query index |
| `query/index.lua` | Full vault index: pages, tags, outlinks, inlinks, frontmatter, ctime/mtime |
| `frontmatter_parser.lua` | Parses YAML frontmatter from files/buffers (tags, type, dates) |
| `wikilinks.lua` | Note name resolution cache (basename + alias indexing) |
| `config.lua` | Centralized configuration (note_types, tag categories, scopes, weights) |
| `engine.lua` | Vault path, file enumeration, `json_store()` for persistence |
| `ui.lua` | Shared floating window creation (`create_float_display`, `create_float_input`) |

## Problem

The current graph view has no filtering capabilities. Every backlink and forward link is shown unconditionally. Users cannot:

1. **Filter by tag** -- show only nodes that have (or lack) specific tags like `#project/active` or `#type/simulation`.
2. **Filter by note type** -- narrow to notes with `type: meeting` or `type: analysis` in frontmatter.
3. **Filter by date range** -- show only links to notes created or modified within a time window.
4. **Filter by link depth** -- expand beyond 1-hop to see 2-hop or 3-hop connections.
5. **Exclude paths** -- hide notes from specific directories like `Log/` or `Library/`.
6. **Hide orphans, attachments, or unresolved links** -- toggle visibility of broken links.
7. **Save and reuse filter presets** -- no way to persist a useful filter configuration.

Obsidian's graph view supports all of these through a sidebar with search queries, toggle switches (tags, attachments, orphans, existing files only), groups for color-coding, and a depth slider for local graphs. The vault module needs a terminal-native equivalent.

---

## Proposed Solution

### Architecture

Add a filter layer between link collection and rendering in `graph.lua`, plus a new `graph_filter.lua` module to manage filter state, predicates, the filter UI, and preset persistence.

```
 User opens graph (<leader>vG)
        |
        v
 collect_forward_links()  +  collect_backlinks()
        |                         |
        v                         v
 +----- raw_forward_links --------raw_backlinks -----+
 |                                                    |
 |   [NEW] graph_filter.apply(raw_links, filter_state)|
 |                                                    |
 +-----> filtered_forward_links   filtered_backlinks -+
        |                         |
        v                         v
 render_graph() -> floating window with filter keybindings
```

For **depth > 1**, the collection phase itself must expand: recursively collect forward/backlinks for each discovered node up to the configured depth, building a node set and edge set. The render phase then shows all nodes within the depth radius.

The filter system operates in two modes:
- **Predicate filtering**: Each filter type produces a predicate function `fn(path) -> boolean`. Links whose target file fails any active predicate are excluded from the graph.
- **Depth expansion**: When depth > 1, the collector walks outward from the current note, applying predicates at each hop.

### Filter Types

#### 1. Tag Inclusion/Exclusion

Filter links to notes that have (or lack) specific tags.

**Data source**: `frontmatter_parser.parse_file(path)` for frontmatter tags, plus inline `#tag` extraction from file content (reusing logic from `query/index.lua:_extract_tags`).

**Predicate**:
```lua
---@param include string[]|nil  tags the note MUST have (any match suffices)
---@param exclude string[]|nil  tags the note MUST NOT have
---@return fun(path: string): boolean
function M.tag_predicate(include, exclude)
  return function(path)
    local tags = get_tags_for_file(path)  -- cached
    if include and #include > 0 then
      local found = false
      for _, inc_tag in ipairs(include) do
        if tags[inc_tag] then found = true; break end
      end
      if not found then return false end
    end
    if exclude and #exclude > 0 then
      for _, exc_tag in ipairs(exclude) do
        if tags[exc_tag] then return false end
      end
    end
    return true
  end
end
```

**UI**: Tag picker (fzf-lua multi-select) with separate include/exclude modes, reusing `tags.collect_tags()`.

#### 2. Note Type Filter (Frontmatter `type` Field)

Filter by the `type` frontmatter field. Values come from `config.note_types`: `meeting`, `analysis`, `finding`, `task`, `simulation`, `literature`, `concept`, `log`, `journal`.

**Predicate**:
```lua
---@param allowed_types string[]
---@return fun(path: string): boolean
function M.type_predicate(allowed_types)
  local set = {}
  for _, t in ipairs(allowed_types) do set[t:lower()] = true end
  return function(path)
    local fm = frontmatter_parser.parse_file(path)
    local note_type = fm and fm.fields.type
    if not note_type then return true end  -- notes without type pass by default
    return set[tostring(note_type):lower()] ~= nil
  end
end
```

**UI**: Multi-select from `config.note_types` via `vim.ui.select` or fzf-lua.

#### 3. Date Range Filter (Created/Modified)

Filter to notes whose `created` or `modified` timestamp falls within a range.

**Data source**: Frontmatter `created` / `modified` fields (format `%Y-%m-%dT%H:%M:%S` per `config.frontmatter.timestamp_format`), falling back to filesystem `ctime` / `mtime` via `vim.uv.fs_stat`.

**Predicate**:
```lua
---@param field "created"|"modified"
---@param from_date string|nil  "YYYY-MM-DD" (nil = no lower bound)
---@param to_date string|nil    "YYYY-MM-DD" (nil = no upper bound)
---@return fun(path: string): boolean
function M.date_predicate(field, from_date, to_date)
  local from_ts = from_date and engine.parse_date(from_date) or nil
  local to_ts = to_date and engine.parse_date(to_date) or nil
  -- Shift to_ts to end of day
  if to_ts then to_ts = to_ts + 86400 end

  return function(path)
    local ts = get_file_timestamp(path, field)  -- from frontmatter or stat
    if not ts then return true end
    if from_ts and ts < from_ts then return false end
    if to_ts and ts >= to_ts then return false end
    return true
  end
end
```

**UI**: Two-step input -- first select the field (`created`/`modified`), then enter date range. Support shortcuts: `today`, `7d` (last 7 days), `30d`, `this-month`, `this-week`, or explicit `YYYY-MM-DD..YYYY-MM-DD` syntax.

#### 4. Link Depth

Expand the graph beyond 1-hop to show notes connected through intermediate links.

**Implementation**: This is not a predicate filter but changes the collection algorithm. At depth N, recursively collect forward links and backlinks for each newly discovered node, up to N hops from the current note.

```lua
---@param center_path string  absolute path of the current note
---@param depth number         max hops from center (1 = current behavior)
---@param predicate fun(path: string): boolean  combined filter predicate
---@return table nodes         set of {name, path, depth_level}
---@return table edges         list of {from_path, to_path, direction}
function M.collect_at_depth(center_path, depth, predicate)
  local nodes = {}    -- path -> {name, path, depth}
  local edges = {}
  local queue = { {path = center_path, depth = 0} }
  local visited = { [center_path] = true }

  while #queue > 0 do
    local current = table.remove(queue, 1)
    if current.depth >= depth then goto continue end

    local forward = collect_forward_links_for(current.path)
    local back = collect_backlinks_for(current.path)

    for _, link in ipairs(forward) do
      if link.path and predicate(link.path) then
        edges[#edges + 1] = {from = current.path, to = link.path}
        if not visited[link.path] then
          visited[link.path] = true
          nodes[link.path] = {name = link.name, path = link.path, depth = current.depth + 1}
          table.insert(queue, {path = link.path, depth = current.depth + 1})
        end
      end
    end
    for _, link in ipairs(back) do
      if link.path and predicate(link.path) then
        edges[#edges + 1] = {from = link.path, to = current.path}
        if not visited[link.path] then
          visited[link.path] = true
          nodes[link.path] = {name = link.name, path = link.path, depth = current.depth + 1}
          table.insert(queue, {path = link.path, depth = current.depth + 1})
        end
      end
    end
    ::continue::
  end
  return nodes, edges
end
```

**Performance**: At depth > 2, the number of nodes can explode. Mitigations:
- Hard cap of `max_nodes` (default 50) -- stop BFS when reached.
- Async collection with progress indicator for depth > 1.
- Reuse the query index (`query/index.lua`) for outlinks/inlinks instead of re-running `rg` per node.

**UI**: Depth selector via `vim.ui.select({1, 2, 3}, ...)` or a single-key cycle (`+`/`-` to increment/decrement).

#### 5. Path Inclusion/Exclusion

Filter by vault-relative directory path.

**Predicate**:
```lua
---@param include_paths string[]|nil  directory prefixes to include
---@param exclude_paths string[]|nil  directory prefixes to exclude
---@return fun(path: string): boolean
function M.path_predicate(include_paths, exclude_paths)
  return function(abs_path)
    local rel = engine.vault_relative(abs_path)
    if not rel then return false end
    if include_paths and #include_paths > 0 then
      local found = false
      for _, prefix in ipairs(include_paths) do
        if rel:sub(1, #prefix) == prefix then found = true; break end
      end
      if not found then return false end
    end
    if exclude_paths and #exclude_paths > 0 then
      for _, prefix in ipairs(exclude_paths) do
        if rel:sub(1, #prefix) == prefix then return false end
      end
    end
    return true
  end
end
```

**UI**: Select from `config.scopes` (Projects, Areas, Log, Domains, etc.) or type a custom path prefix.

#### 6. Toggle Filters

Simple boolean toggles matching Obsidian's graph sidebar:

| Toggle | Default | Description |
|--------|---------|-------------|
| `show_orphans` | `true` | Show notes with no other connections in the graph |
| `show_unresolved` | `true` | Show links whose target file does not exist |
| `existing_only` | `false` | When true, hide all unresolved link targets |

These are simple post-collection filters applied to the link lists before rendering.

### UI Design

The filter UI uses a two-part approach: an inline status bar in the graph float showing active filters, and a filter configuration popup triggered by a keymap.

#### Status Bar (Always Visible)

Rendered as the last line(s) of the graph float, below the summary line:

```
  3 backlinks               │  5 forward links
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Filters: #project/active  type:meeting  depth:2  modified:7d
  [f] filter  [+/-] depth  [r] reset  [p] presets  [?] help
```

The status bar uses `VaultGraphCount` for the filter summary and `VaultGraphDivider` for the keybinding hints.

#### Filter Configuration Popup

Pressing `f` in the graph float opens a secondary float (via `ui.create_float_display`) listing all filter categories. The user navigates with j/k and presses `<CR>` to configure each one:

```
 ┌──────────── Graph Filters ────────────┐
 │                                        │
 │  [1] Tags: #project/active             │
 │  [2] Type: (none)                      │
 │  [3] Date: modified > 7d ago           │
 │  [4] Depth: 1                          │
 │  [5] Paths: -Log/ -Library/            │
 │  [6] Toggles: orphans=on unresolved=on │
 │                                        │
 │  [r] Reset all   [a] Apply   [q] Close │
 └────────────────────────────────────────┘
```

Selecting a filter category opens the appropriate sub-picker:
- **Tags**: fzf-lua multi-select (reusing `tags.collect_tags()`), with `<Tab>` to toggle include and `<S-Tab>` for exclude.
- **Type**: fzf-lua multi-select from `config.note_types`.
- **Date**: `ui.create_float_input` prompting for range (e.g., `7d`, `2026-01-01..2026-02-25`, `this-month`).
- **Depth**: Inline increment/decrement or direct number input.
- **Paths**: fzf-lua multi-select from `config.scopes` labels, plus custom input.
- **Toggles**: Direct toggle on `<CR>`, cycling the boolean value.

On "Apply" or closing the filter popup, the graph re-renders with the updated filters. The graph float is replaced (close old, open new) with the filtered data.

### Implementation Details

#### New Module: `lua/andrew/vault/graph_filter.lua`

This module owns all filter logic, state management, and the filter UI.

```lua
local M = {}

-- -----------------------------------------------------------------------
-- Filter state
-- -----------------------------------------------------------------------

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

--- Default filter state (no filters active, depth 1).
---@return GraphFilterState
function M.default_state()
  return {
    tags_include = {},
    tags_exclude = {},
    note_types = {},
    date_field = nil,
    date_from = nil,
    date_to = nil,
    depth = 1,
    paths_include = {},
    paths_exclude = {},
    show_orphans = true,
    show_unresolved = true,
    existing_only = false,
  }
end

--- The active filter state for the current graph session.
--- Persists across re-renders within a single graph open; resets when
--- the graph float is closed.
---@type GraphFilterState
M.state = M.default_state()

-- -----------------------------------------------------------------------
-- Predicate composition
-- -----------------------------------------------------------------------

--- Build a combined predicate from the current filter state.
--- Returns a function that takes an absolute file path and returns
--- true if the note should appear in the graph.
---@param state GraphFilterState
---@return fun(path: string|nil): boolean
function M.build_predicate(state)
  local predicates = {}

  if #state.tags_include > 0 or #state.tags_exclude > 0 then
    predicates[#predicates + 1] = M.tag_predicate(state.tags_include, state.tags_exclude)
  end
  if #state.note_types > 0 then
    predicates[#predicates + 1] = M.type_predicate(state.note_types)
  end
  if state.date_field and (state.date_from or state.date_to) then
    predicates[#predicates + 1] = M.date_predicate(state.date_field, state.date_from, state.date_to)
  end
  if #state.paths_include > 0 or #state.paths_exclude > 0 then
    predicates[#predicates + 1] = M.path_predicate(state.paths_include, state.paths_exclude)
  end
  if state.existing_only then
    predicates[#predicates + 1] = function(path) return path ~= nil end
  end

  return function(path)
    if not path then return not state.existing_only end
    for _, pred in ipairs(predicates) do
      if not pred(path) then return false end
    end
    return true
  end
end

-- -----------------------------------------------------------------------
-- Tag data access (cached)
-- -----------------------------------------------------------------------

local _file_tag_cache = {}  -- abs_path -> {tag_set, timestamp}
local FILE_TAG_TTL = 30     -- seconds

--- Get the tag set for a file (cached).
---@param abs_path string
---@return table<string, true>
function M.get_tags_for_file(abs_path)
  local now = vim.uv.now() / 1000
  local cached = _file_tag_cache[abs_path]
  if cached and (now - cached.ts) < FILE_TAG_TTL then
    return cached.tags
  end

  local tags = {}
  -- Try the query index first (already has parsed tags)
  local ok, index_mod = pcall(require, "andrew.vault.query.index")
  if ok then
    local engine = require("andrew.vault.engine")
    local Index = index_mod.Index
    -- Use a shared singleton index (built by connections.lua or query module)
    -- Fall back to frontmatter parsing if index unavailable
  end

  -- Fallback: parse frontmatter + scan inline tags
  local fm_parser = require("andrew.vault.frontmatter_parser")
  local fm = fm_parser.parse_file(abs_path)
  if fm and fm.fields.tags then
    local fm_tags = fm.fields.tags
    if type(fm_tags) == "table" then
      for _, t in ipairs(fm_tags) do tags[tostring(t)] = true end
    elseif type(fm_tags) == "string" then
      tags[fm_tags] = true
    end
  end

  _file_tag_cache[abs_path] = { tags = tags, ts = now }
  return tags
end

-- -----------------------------------------------------------------------
-- Filter application
-- -----------------------------------------------------------------------

--- Apply filter state to a list of link entries.
---@param links {name: string, path: string|nil}[]
---@param predicate fun(path: string|nil): boolean
---@return {name: string, path: string|nil}[]
function M.apply(links, predicate)
  local filtered = {}
  for _, entry in ipairs(links) do
    if predicate(entry.path) then
      filtered[#filtered + 1] = entry
    end
  end
  return filtered
end

-- -----------------------------------------------------------------------
-- Status line formatting
-- -----------------------------------------------------------------------

--- Format active filters as a compact status string for display.
---@param state GraphFilterState
---@return string
function M.format_status(state)
  local parts = {}
  if #state.tags_include > 0 then
    parts[#parts + 1] = "#" .. table.concat(state.tags_include, " #")
  end
  if #state.tags_exclude > 0 then
    parts[#parts + 1] = "-#" .. table.concat(state.tags_exclude, " -#")
  end
  if #state.note_types > 0 then
    parts[#parts + 1] = "type:" .. table.concat(state.note_types, ",")
  end
  if state.date_field then
    local range = state.date_from or "*"
    range = range .. ".." .. (state.date_to or "*")
    parts[#parts + 1] = state.date_field .. ":" .. range
  end
  if state.depth > 1 then
    parts[#parts + 1] = "depth:" .. state.depth
  end
  if #state.paths_exclude > 0 then
    parts[#parts + 1] = "-" .. table.concat(state.paths_exclude, " -")
  end
  if state.existing_only then
    parts[#parts + 1] = "existing-only"
  end
  if #parts == 0 then return "(no filters)" end
  return table.concat(parts, "  ")
end

-- -----------------------------------------------------------------------
-- Preset persistence
-- -----------------------------------------------------------------------

local _store = nil

--- Get the JSON store for filter presets (lazy-initialized).
---@return table store with .load() and .save() methods
function M.preset_store()
  if not _store then
    local engine = require("andrew.vault.engine")
    _store = engine.json_store(".vault-graph-presets.json", { presets = {} })
  end
  return _store
end

--- Save the current filter state as a named preset.
---@param name string
---@param state GraphFilterState
function M.save_preset(name, state)
  local store = M.preset_store()
  local data = store.load()
  data.presets = data.presets or {}
  -- Store a serializable copy (no functions)
  data.presets[name] = vim.deepcopy(state)
  store.save(data)
end

--- Load a named preset, returning the filter state.
---@param name string
---@return GraphFilterState|nil
function M.load_preset(name)
  local store = M.preset_store()
  local data = store.load()
  local preset = data.presets and data.presets[name]
  if not preset then return nil end
  -- Merge with defaults to handle any missing fields from older presets
  return vim.tbl_deep_extend("keep", preset, M.default_state())
end

--- List all saved preset names.
---@return string[]
function M.list_presets()
  local store = M.preset_store()
  local data = store.load()
  local names = {}
  for name in pairs(data.presets or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- Delete a named preset.
---@param name string
function M.delete_preset(name)
  local store = M.preset_store()
  local data = store.load()
  if data.presets then
    data.presets[name] = nil
  end
  store.save(data)
end

return M
```

#### Modifications to `lua/andrew/vault/graph.lua`

The main changes to `graph.lua`:

1. **Import `graph_filter`** at the top.
2. **Replace direct link collection** with filter-aware collection:
   - At depth 1: apply predicates to existing `collect_forward_links()` / `collect_backlinks()` results.
   - At depth > 1: use `graph_filter.collect_at_depth()` with the query index.
3. **Add filter status bar** to the rendered output (appended after summary line).
4. **Add keybindings** to the graph float buffer for filter interaction.
5. **Add re-render function** that closes and re-opens the graph with updated filter state.

Key changes in `local_graph()`:

```lua
function M.local_graph()
  local graph_filter = require("andrew.vault.graph_filter")
  -- ... existing validation ...

  define_highlights()

  local state = graph_filter.state
  local predicate = graph_filter.build_predicate(state)

  local forward_links, backlinks
  if state.depth <= 1 then
    forward_links = collect_forward_links()
    backlinks = collect_backlinks(note_name)
    -- Apply filters
    forward_links = graph_filter.apply(forward_links, predicate)
    backlinks = graph_filter.apply(backlinks, predicate)
  else
    -- Multi-hop collection
    local nodes, edges = graph_filter.collect_at_depth(buf_path, state.depth, predicate)
    forward_links, backlinks = partition_by_direction(nodes, edges, buf_path)
  end

  -- ... existing self-filter, disambiguate, render ...

  -- Append filter status bar to rendered_lines
  local status = graph_filter.format_status(state)
  rendered_lines[#rendered_lines + 1] = ""
  rendered_lines[#rendered_lines + 1] = "  Filters: " .. status
  rendered_lines[#rendered_lines + 1] = "  [f] filter  [+/-] depth  [r] reset  [p] presets  [?] help"

  -- ... existing float creation and highlight application ...

  -- New keymaps in the graph buffer
  vim.keymap.set("n", "f", function()
    graph_filter.open_filter_ui(function()
      float.close()
      M.local_graph()  -- re-render with new filters
    end)
  end, { buffer = buf, nowait = true, silent = true, desc = "Open filter panel" })

  vim.keymap.set("n", "+", function()
    state.depth = math.min(state.depth + 1, 5)
    float.close()
    M.local_graph()
  end, { buffer = buf, nowait = true, silent = true, desc = "Increase depth" })

  vim.keymap.set("n", "-", function()
    state.depth = math.max(state.depth - 1, 1)
    float.close()
    M.local_graph()
  end, { buffer = buf, nowait = true, silent = true, desc = "Decrease depth" })

  vim.keymap.set("n", "r", function()
    graph_filter.state = graph_filter.default_state()
    float.close()
    M.local_graph()
  end, { buffer = buf, nowait = true, silent = true, desc = "Reset filters" })

  vim.keymap.set("n", "p", function()
    graph_filter.open_preset_picker(function()
      float.close()
      M.local_graph()
    end)
  end, { buffer = buf, nowait = true, silent = true, desc = "Load preset" })

  vim.keymap.set("n", "?", function()
    -- Show help float with all graph keybindings
    graph_filter.show_help()
  end, { buffer = buf, nowait = true, silent = true, desc = "Show help" })
end
```

#### Multi-Hop Collection Using the Query Index

For depth > 1, avoid running `rg` per node (which would be O(N) shell processes). Instead, leverage the `query/index.lua` index which already has pre-computed outlinks and inlinks for every page:

```lua
--- Collect nodes at depth N from center using the query index.
--- Falls back to rg-based collection at depth 1 for single-hop performance.
---@param center_path string  absolute path
---@param depth number
---@param predicate fun(path: string|nil): boolean
---@return {name: string, path: string}[] forward_like, {name: string, path: string}[] backlink_like
function M.collect_at_depth(center_path, depth, predicate)
  local Index = require("andrew.vault.query.index").Index
  local engine = require("andrew.vault.engine")

  local index = Index.new(engine.vault_path):build_sync()
  local center_rel = engine.vault_relative(center_path)
  local center_page = index:get_page(center_rel)
  if not center_page then return {}, {} end

  local visited = { [center_rel] = true }
  local forward_like = {}  -- edges going out from center
  local backlink_like = {} -- edges coming in to center
  local queue = { { rel = center_rel, d = 0 } }
  local max_nodes = 50  -- safety cap

  while #queue > 0 and (#forward_like + #backlink_like) < max_nodes do
    local current = table.remove(queue, 1)
    if current.d >= depth then goto skip end

    local page = index:get_page(current.rel)
    if not page then goto skip end

    -- Outlinks
    for _, link in ipairs(page.file.outlinks) do
      local target_rel = resolve_link_in_index(index, link)
      if target_rel and not visited[target_rel] then
        local abs = engine.vault_path .. "/" .. target_rel
        if predicate(abs) then
          visited[target_rel] = true
          local name = target_rel:match("([^/]+)%.md$") or target_rel
          forward_like[#forward_like + 1] = { name = name, path = abs }
          table.insert(queue, { rel = target_rel, d = current.d + 1 })
        end
      end
    end

    -- Inlinks
    for _, link in ipairs(page.file.inlinks) do
      local source_rel = link.path .. ".md"
      if not visited[source_rel] then
        local abs = engine.vault_path .. "/" .. source_rel
        if predicate(abs) then
          visited[source_rel] = true
          local name = source_rel:match("([^/]+)%.md$") or source_rel
          backlink_like[#backlink_like + 1] = { name = name, path = abs }
          table.insert(queue, { rel = source_rel, d = current.d + 1 })
        end
      end
    end

    ::skip::
  end

  return forward_like, backlink_like
end
```

#### Filter UI Implementation

The filter configuration popup (`open_filter_ui`) renders a menu in a floating window:

```lua
--- Open the filter configuration popup.
---@param on_apply fun()  callback when filters are applied (triggers graph re-render)
function M.open_filter_ui(on_apply)
  local ui = require("andrew.vault.ui")
  local state = M.state

  local function render_menu()
    local lines = {
      "  [1] Tags include: " .. (#state.tags_include > 0 and ("#" .. table.concat(state.tags_include, " #")) or "(none)"),
      "  [2] Tags exclude: " .. (#state.tags_exclude > 0 and ("#" .. table.concat(state.tags_exclude, " #")) or "(none)"),
      "  [3] Note type:    " .. (#state.note_types > 0 and table.concat(state.note_types, ", ") or "(none)"),
      "  [4] Date range:   " .. format_date_filter(state),
      "  [5] Depth:        " .. state.depth,
      "  [6] Path exclude: " .. (#state.paths_exclude > 0 and table.concat(state.paths_exclude, ", ") or "(none)"),
      "  [7] Toggles:      " .. format_toggles(state),
      "",
      "  [r] Reset all   [a] Apply & close   [q] Cancel",
    }
    return lines
  end

  local float = ui.create_float_display({
    title = "Graph Filters",
    lines = render_menu(),
    width = 60,
    height = 11,
    cursor_line = true,
  })

  -- Number keys open sub-pickers
  for i = 1, 7 do
    vim.keymap.set("n", tostring(i), function()
      float.close()
      open_sub_filter(i, state, function()
        -- Re-open filter UI after sub-picker completes
        M.open_filter_ui(on_apply)
      end)
    end, { buffer = float.buf, nowait = true, silent = true })
  end

  vim.keymap.set("n", "a", function()
    float.close()
    on_apply()
  end, { buffer = float.buf, nowait = true, silent = true })

  vim.keymap.set("n", "r", function()
    M.state = M.default_state()
    state = M.state
    -- Re-render menu in place
    vim.bo[float.buf].modifiable = true
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, render_menu())
    vim.bo[float.buf].modifiable = false
  end, { buffer = float.buf, nowait = true, silent = true })
end
```

### Key Bindings

#### In the graph float (`<leader>vG` window)

| Key | Action | Description |
|-----|--------|-------------|
| `f` | Open filter panel | Opens the filter configuration popup |
| `+` | Increase depth | Increment link depth and re-render |
| `-` | Decrease depth | Decrement link depth and re-render |
| `r` | Reset filters | Clear all filters, reset depth to 1 |
| `p` | Presets | Open preset picker (load/save/delete) |
| `P` | Save preset | Save current filter state as a named preset |
| `?` | Help | Show keybinding reference |
| `<CR>` | Follow link | Navigate to note under cursor (existing) |
| `gf` | Follow link | Same as `<CR>` (existing) |
| `q` | Close | Close the graph float (existing) |
| `<Esc>` | Close | Close the graph float (existing) |

#### In the filter configuration popup

| Key | Action |
|-----|--------|
| `1`-`7` | Open sub-filter for that category |
| `a` | Apply filters and close (re-renders graph) |
| `r` | Reset all filters to defaults |
| `q` / `<Esc>` | Cancel and close without applying |

### Configuration

Add to `lua/andrew/vault/config.lua`:

```lua
-- ---------------------------------------------------------------------------
-- Graph view
-- ---------------------------------------------------------------------------
M.graph = {
  max_depth = 5,          -- maximum allowed link depth
  max_nodes = 50,         -- safety cap for multi-hop collection
  default_depth = 1,      -- initial depth when opening graph
  show_filter_bar = true, -- show the filter status + keybinding hints

  -- Default toggle states
  show_orphans = true,
  show_unresolved = true,
  existing_only = false,

  -- Date range shortcuts recognized by the date filter input
  date_shortcuts = {
    ["today"]      = { offset_days = 0 },
    ["7d"]         = { offset_days = -7 },
    ["30d"]        = { offset_days = -30 },
    ["90d"]        = { offset_days = -90 },
    ["this-week"]  = "week",   -- resolved at runtime via engine.date_offset
    ["this-month"] = "month",
  },
}
```

### File Changes

| File | Action | Description |
|------|--------|-------------|
| `lua/andrew/vault/graph_filter.lua` | **Create** | New module: filter state, predicates, UI, presets, multi-hop collection |
| `lua/andrew/vault/graph.lua` | **Modify** | Integrate filter layer into `local_graph()`, add keybindings, append status bar |
| `lua/andrew/vault/config.lua` | **Modify** | Add `M.graph` configuration section |
| `lua/andrew/vault/init.lua` | **No change** | `graph.lua` already loaded via `require("andrew.vault.graph").setup()` |
| `lua/andrew/vault/ui.lua` | **No change** | Existing `create_float_display` and `create_float_input` are sufficient |
| `lua/andrew/vault/engine.lua` | **No change** | `json_store`, `parse_date`, `vault_relative` already available |

### Dependencies

No new external dependencies are required. All functionality uses existing infrastructure:

- **ripgrep** (`rg`): Already used by `tags.lua` and `graph.lua` for backlink searches
- **fzf-lua**: Already used throughout the vault module for pickers
- **query/index.lua**: Already built and used by `connections.lua`; provides pre-computed outlinks/inlinks for multi-hop traversal
- **frontmatter_parser.lua**: Already available for reading tags/type/dates from files
- **engine.json_store()**: Already used by `frecency.lua`, `pins.lua`, `callout_folds.lua` for persistence

### Testing Plan

#### Unit-level verification

1. **Predicate correctness**:
   - Create test notes with known tags, types, dates, and paths.
   - Verify `tag_predicate` includes/excludes correctly with single and multiple tags, nested tags (`project/active`), and empty lists.
   - Verify `type_predicate` handles case-insensitive matching and notes without a `type` field.
   - Verify `date_predicate` handles `created`/`modified` fields, missing timestamps, boundary dates.
   - Verify `path_predicate` handles prefix matching, multiple paths, overlapping include/exclude.

2. **Predicate composition**:
   - Verify `build_predicate` correctly ANDs all active predicates.
   - Verify that empty filter state produces a pass-all predicate.

3. **Multi-hop collection**:
   - Set up a chain: A -> B -> C -> D.
   - Verify depth=1 from A yields {B}, depth=2 yields {B, C}, depth=3 yields {B, C, D}.
   - Verify the `max_nodes` cap prevents runaway expansion.
   - Verify predicates are applied at each hop (a filtered-out node at hop 2 does not contribute its links to hop 3).

#### Integration testing (manual)

4. **Filter UI workflow**:
   - Open graph on a note with varied connections.
   - Press `f` to open filter panel; verify all categories display correctly.
   - Set a tag include filter; verify the graph re-renders with fewer nodes.
   - Increase depth to 2; verify new nodes appear.
   - Reset with `r`; verify all filters cleared.

5. **Preset persistence**:
   - Save a filter preset with `P`, enter a name.
   - Close and reopen the graph.
   - Load the preset with `p`; verify filters restored correctly.
   - Verify the `.vault-graph-presets.json` file exists in the vault root.
   - Delete the preset; verify it no longer appears in the picker.

6. **Edge cases**:
   - Open graph on a note with zero links; verify "(no connections)" still shows.
   - Apply a filter that excludes all links; verify graceful empty state.
   - Open graph on a note outside the vault; verify the existing warning message.
   - Test with a large vault (1000+ notes) at depth 2; verify the `max_nodes` cap triggers and performance is acceptable (< 2 seconds).

7. **Status bar**:
   - Verify the filter status line updates after each filter change.
   - Verify keybinding hints are visible and accurate.
   - Verify `config.graph.show_filter_bar = false` suppresses the status bar.

#### Performance benchmarks

8. **Depth 1 with filters**: Should add negligible overhead (< 50ms) since it just filters the existing link lists.
9. **Depth 2 with index**: Should complete within 500ms on a 500-note vault (index build is the bottleneck; reuse cached index from `connections.lua` when available).
10. **Depth 3**: Should respect `max_nodes` and return within 1 second on a 1000-note vault.
