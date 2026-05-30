# graph_filter.lua Refactoring Plan

## File Stats
- **File:** `lua/andrew/vault/graph_filter.lua`
- **Lines:** 915
- **Dead Code:** None
- **Public API:** 21 exported functions (predicates, composition, presets, UI, traversal)

## Current Structure

| Section | Lines | Purpose |
|---------|-------|---------|
| Prologue + State | 1-51 | GraphFilterState class, `default_state()`, `M.state` |
| Predicate Functions | 53-177 | 5 factories: `tag_predicate`, `type_predicate`, `date_predicate`, `path_predicate`, `search_expr_predicate` |
| Predicate Composition | 179-218 | `build_predicate(state)` |
| Filter Application | 220-236 | `apply(links, predicate)` |
| Multi-hop Collection | 238-362 | `collect_at_depth(center_path, depth, predicate)` — BFS traversal |
| Status Formatting | 364-407 | `format_status(state)` |
| Preset Persistence | 409-469 | `preset_store()`, `save_preset()`, `load_preset()`, `list_presets()`, `delete_preset()` |
| Date Range Parsing | 471-517 | `parse_date_range(input)` |
| Filter UI Layer | 519-756 | `open_sub_filter()` (209 lines, 8 categories), format helpers |
| Preset Picker & Save | 758-823 | `open_preset_picker()`, `save_preset_prompt()` |
| Help Display | 825-913 | `show_help()` |

## Duplicated Logic Patterns

### 1. Include/Exclude Pattern (3x — tag_predicate, path_predicate, + search_filter)
Lines 63-72, 122-136: Identical include/exclude loop structure.
**Fix:** Extract `matches_include_exclude(items, include_list, exclude_list)` to `filter_utils.lua`.

### 2. FZF Multi-Select Pattern (5x in open_sub_filter)
Lines 558-568, 579-589, 661-687: All follow same `fzf.fzf_exec(items, { prompt, multi, actions })` pattern.
**Fix:** Extract `open_fzf_multi_select(items, prompt, on_select)`.

### 3. Lazy Require Duplication (4x)
Lines 146-148, 252-254: Same modules (`search_query`, `search_filter`, `vault_index`) required in multiple functions.
**Fix:** Hoist to module top-level or extract shared lazy-require pattern.

### 4. Floating Input Pattern (2x — lines 614-636, 691-711)
Date range input and search expression input both use `ui.create_float_input()` with similar structure.
**Fix:** Extract `open_text_input(title, width, validator, on_submit)`.

### 5. Config Reloading (3x — lines 32, 203, 254)
Repeated `local config = require("andrew.vault.config")`.
**Fix:** Hoist to module top-level.

## Proposed Extraction Plan

### Subsystem A: Presets → `graph_filter/presets.lua` (~60 lines)
**Functions:** `preset_store()`, `save_preset()`, `load_preset()`, `list_presets()`, `delete_preset()`, `_store` state
**Rationale:** Clean separation, self-contained with `engine.json_store` dependency only.

### Subsystem B: UI Categories → `graph_filter/sub_filters.lua` (~230 lines)
**Functions:** `open_sub_filter()` (the 209-line monster handling 8 categories), `format_date_filter()`, `format_toggles()`
**Rationale:** Breaks up the largest function. Each category could become a dispatch table entry.

### Subsystem C: Multi-hop Traversal → `graph_filter/traversal.lua` (~120 lines)
**Functions:** `collect_at_depth()` — BFS algorithm with filter predicate
**Rationale:** Pure algorithm, no UI. Could be reused by graph analysis tools.

### Subsystem D: Help Display → `graph_filter/help.lua` (~90 lines)
**Functions:** `show_help()` — mostly static text
**Rationale:** Large block of help text, rarely changes.

### Subsystem E: Date Range Parsing → move to `date_utils.lua` (~38 lines)
**Functions:** `parse_date_range(input)`
**Rationale:** Shared utility. Reduces graph_filter by 38 lines.

## Cross-File Duplication
- Include/exclude filtering logic exists in both `graph_filter.lua` and `search_filter`. Extract to `filter_utils.lua`.

## External Callers
- Only `graph.lua` imports `graph_filter` (lines 559-823)
- Accesses: `state`, `build_predicate`, `apply`, `collect_at_depth`, `format_status`, `default_state`, `open_filter_ui`, `open_preset_picker`, `save_preset_prompt`, `show_help`

## Implementation Order
1. Extract presets (lowest risk, clean separation)
2. Dedup include/exclude → filter_utils.lua
3. Extract sub_filters (biggest function, highest impact)
4. Extract traversal (pure algorithm)
5. Move date_range_parsing to date_utils (optional)

## Expected Result
- `graph_filter.lua`: ~400 lines (state, predicates, composition, apply, format_status, open_filter_ui orchestrator)
- `graph_filter/presets.lua`: ~60 lines
- `graph_filter/sub_filters.lua`: ~230 lines
- `graph_filter/traversal.lua`: ~120 lines
- `graph_filter/help.lua`: ~90 lines
