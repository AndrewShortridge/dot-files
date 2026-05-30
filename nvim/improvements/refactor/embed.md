# embed.lua Refactoring Plan

## File Stats
- **File:** `lua/andrew/vault/embed.lua`
- **Lines:** 1,200
- **Dead Code:** None
- **Public API:** `M.render_embeds(opts)`, `M.clear_embeds()`, `M.toggle_embeds()`, `M.debug_info()`, `M.render_embeds_buf(bufnr)`, `M.setup()`

## Current Structure

| Section | Lines | Purpose |
|---------|-------|---------|
| Imports & Init | 1-31 | 7 deps, namespace, constants, 6 global state dicts |
| Snacks Image System | 37-126 | `invalidate_snacks_env()`, `init_snacks_image()` |
| Buffer State Mgmt | 51-245 | `is_embed_active()`, `cleanup_timer()`, `gc_stale_buffers()` |
| Embed Pattern Parsing | 75-102 | `extract_embed_inner()`, `find_embed_spans()`, `get_image_name()` |
| Image Handling | 128-201 | `is_image_embed()`, `get_image_search_paths()`, `resolve_image()`, `clear_image_placements()` |
| Virtual Text & Borders | 142-172 | `embed_header()`, `embed_footer()`, `add_header_line()` |
| Core Embed Resolution | 248-456 | `resolve_embed()`, `get_embed_content()`, `format_cycle_path()`, `resolve_embed_lines()` (147-line recursive resolver) |
| Utilities | 458-468 | `silent_notify()` |
| Main Render | 472-706 | `M.render_embeds(opts)` -- 234-line orchestrator |
| Clear/Toggle | 709-725 | `M.clear_embeds()`, `M.toggle_embeds()` |
| Debug | 728-936 | `M.debug_info()` -- 208 lines of diagnostics |
| Live Sync | 938-1010 | `schedule_rerender()`, `on_index_update()`, `ensure_subscription()` |
| Render Buf | 1016-1025 | `M.render_embeds_buf()` |
| Setup | 1027-1198 | Commands, autocmds, palette |

## Duplicated Logic Patterns

### 1. Stale Buffer GC Loops (5x in gc_stale_buffers)
Five identical loops checking `vim.api.nvim_buf_is_valid(bufnr)` across different state dicts.
**Fix:** Extract `gc_dict(dict, cleanup_fn)` helper.

### 2. Embed Span Processing (2x)
`find_embed_spans()` + `extract_embed_inner()` called with same pattern in both `render_embeds` and `debug_info`.
**Note:** Intentional (render vs debug have different handlers), but could share iteration wrapper.

## Proposed Extraction Plan

### Subsystem A: Image Integration -> `embed_images.lua` (~250 lines)
**Functions:** `invalidate_snacks_env()`, `init_snacks_image()`, `is_image_embed()`, `get_image_search_paths()`, `resolve_image()`, `clear_image_placements()`, plus image placement logic from `render_embeds()` and `debug_info()`
**Rationale:** Isolates all Snacks/terminal dependency. Largest coherent subsystem. Better testability.

### Subsystem B: Content Resolution -> `embed_resolver.lua` (~200 lines)
**Functions:** `resolve_embed()`, `get_embed_content()`, `format_cycle_path()`, `resolve_embed_lines()` (the 147-line recursive resolver with cycle detection, depth limits, budget system)
**Rationale:** Pure resolution logic with no rendering. Reusable for search/preview. The complexity core of the module.

### Subsystem C: Live Sync -> `embed_sync.lua` (~150 lines)
**Functions:** `schedule_rerender()`, `on_index_update()`, `ensure_subscription()`
**Rationale:** Vault index subscription, debounced re-render scheduling, dependency tracking. Well-isolated.

### Subsystem D: Buffer State -> `embed_state.lua` (~100 lines)
**State:** `embeds_visible`, `image_placements`, `_embed_deps`, `_sync_timers`, `_image_retry_fired`, `_subscribed`
**Functions:** `is_embed_active()`, `cleanup_timer()`, `gc_stale_buffers()`
**Rationale:** Centralized state management with GC routines.

## External Callers
- `init.lua` line 212: `require("andrew.vault.embed").setup()`
- All other access via user commands (VaultEmbedRender, VaultEmbedClear, etc.)

## Implementation Order
1. Extract image integration (biggest, isolates Snacks dependency)
2. Extract resolver (pure logic, reusable)
3. Extract sync (well-isolated)
4. Extract state management (cleanup, optional)

## Expected Result
- `embed.lua`: ~500 lines (orchestrator + render + debug + setup)
- `embed_images.lua`: ~250 lines
- `embed_resolver.lua`: ~200 lines
- `embed_sync.lua`: ~150 lines
