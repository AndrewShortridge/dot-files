# graph.lua Refactoring Plan

## File Stats
- **File:** `lua/andrew/vault/graph.lua`
- **Lines:** 883
- **Dead Code:** None
- **Public API:** `M.search_result_graph()`, `M.local_graph()`, `M.setup()`

## Current Structure

| Section | Lines | Purpose |
|---------|-------|---------|
| Imports & Module | 1-9 | 7 deps (engine, link_utils, notify, ui, wikilinks, config, vault_log) |
| Link Helpers | 13-21 | Resolve link assignment |
| Disambiguate Names | 27-47 | Local function for name dedup |
| Collect Forward Links | 53-138 | Buffer content parsing for `[[...]]` wikilinks (85 lines) |
| Collect Backlinks | 144-192 | Vault index lookup + ripgrep fallback |
| Display Utilities | 202-234 | `display_width()`, `truncate_display()` (UTF-8 aware) |
| Render Graph | 244-418 | ASCII two-column rendering (175 lines) with nested helpers |
| Search Result Graph | 427-552 | `M.search_result_graph()` -- connections among search results |
| Local Graph | 558-854 | `M.local_graph()` -- main interactive viewer (297 lines) with nested helpers |
| Setup | 860-881 | Command, keymap, palette registration |

## Duplicated Logic Patterns

### 1. Sort-by-Name Comparator (3x -- lines 136, 164, 190)
```lua
table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
```
**Fix:** Extract `local function sort_by_name(list)`.

### 2. Deduplication Logic (2x -- lines 124-135, 155-162)
`collect_forward_links()` uses resolved-name dedup; `collect_backlinks()` uses seen-path dedup. Different strategies but similar structure.
**Fix:** Could unify under common filter functions, but different enough to be intentional.

### 3. Filter Predicate Application (2x -- lines 597-598, 610-611)
```lua
forward_links = graph_filter.apply(forward_links, predicate)
backlinks = graph_filter.apply(backlinks, predicate)
```
Necessary in both depth branches; not true duplication.

### 4. Highlight for Resolved/Unresolved (4x -- lines 361-365, 373-377)
```lua
if entry.path then
  hl_find(row, line_str, display, "VaultGraphExistingLink")
else
  hl_find(row, line_str, display, "VaultGraphUnresolvedLink")
end
```
**Fix:** Extract `local function hl_link_entry(row, line_str, display, entry, offset)`.

### 5. Unresolved Display Prefix (2x -- lines 319, 335)
Same prefix applied to backlinks and forward links display.

## Cross-File Duplication
- `display_width()` and `truncate_display()` have potential overlap with `query/render.lua` display utilities.

## Proposed Extraction Plan

### Subsystem A: Link Collection -> `graph/collect.lua` (~140 lines)
**Functions:** `disambiguate_names()`, `collect_forward_links()`, `collect_backlinks()`, `sort_by_name()` (new)
**Rationale:** Data gathering separated from rendering/UI. Testable independently. Could be reused by timeline, tags.

### Subsystem B: Graph Rendering -> `graph/render.lua` (~175 lines)
**Functions:** `display_width()`, `truncate_display()`, `render_graph()` (with nested `add_hl`, `hl_find`, `fmt_count`)
**Rationale:** ASCII rendering logic, reusable display helpers. Dedup highlight patterns.

### Subsystem C: Search Result Graph -> `graph/search_graph.lua` (~125 lines)
**Functions:** `M.search_result_graph()`
**Rationale:** Self-contained feature for search-to-graph bridge. Called only from search/advanced.lua.

### Subsystem D: Local Graph UI (keep in main file)
**Functions:** `M.local_graph()` with nested `navigate_to`, `target_from_cursor`, `filter_self`, `filter_unresolved`
**Rationale:** Interactive UI orchestrator. Keep as main file. Could extract keymap setup if complexity grows.

## External Callers
- `init.lua` -> `graph.setup()`
- `search/advanced.lua` -> `graph.search_result_graph()`

## Implementation Order
1. Extract link collection (data logic, lowest risk)
2. Extract rendering (display + ASCII layout)
3. Extract search_result_graph (self-contained feature)
4. Dedup sort_by_name and highlight helpers within extracted modules

## Expected Result
- `graph.lua`: ~440 lines (M.local_graph orchestrator + M.setup)
- `graph/collect.lua`: ~140 lines
- `graph/render.lua`: ~175 lines
- `graph/search_graph.lua`: ~125 lines
