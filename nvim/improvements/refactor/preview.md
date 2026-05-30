# preview.lua Refactoring Plan

## File Stats
- **File:** `lua/andrew/vault/preview.lua`
- **Lines:** 847
- **Dead Code:** None
- **Public API:** `M.preview()`, `M.edit_link()`, `M.setup()`

## Current Structure

| Section | Lines | Purpose |
|---------|-------|---------|
| Dependencies | 1-9 | 7 requires (engine, config, link_utils, wikilinks, ui, cleanup, notify, vault_log) |
| Terminal Keycodes | 12-14 | Pre-computed ctrl_e, ctrl_y |
| Data Structures | 16-46 | PreviewTarget class, `state` table, `history` table |
| History Management | 48-104 | `push_history()`, `pop_back()`, `pop_forward()`, `clear_history()`, `history_position()` |
| Target Resolution | 106-167 | `resolve_target()`, `resolve_target_in_preview()` |
| Breadcrumb Formatting | 169-333 | `vault_relative_segments()`, `format_breadcrumb()`, `truncate_breadcrumb()` (165 lines) |
| Float Helpers | 335-386 | `is_active()`, `scroll_preview()`, `compute_float_dims()`, `setup_markdown_rendering()` |
| Forward Declarations | 388-391 | `close_preview`, `focus_preview`, `unfocus_preview` |
| Float Content & Navigation | 393-570 | `update_float_title()`, `replace_float_content()`, `navigate_in_preview()`, `unfocus_preview()`, `setup_history_keymaps()`, `focus_preview()`, `setup_nested_keymaps()` |
| Close/Cleanup | 572-610 | `close_preview()` |
| Public API | 613-845 | `M.preview()` (118 lines), `M.edit_link()` (82 lines), `M.setup()` (25 lines) |

## Duplicated Logic Patterns

### 1. Breadcrumb Separator (2x -- lines 220, 286)
```lua
local sep = config.preview.breadcrumb_separator or " \u{203A} "
```
**Fix:** Extract as module-level constant.

### 2. Scroll Keymap Setup (2x -- lines 555-561, 687-692)
Identical C-j/C-k scroll keymaps in both `focus_preview()` and `M.preview()`.
**Fix:** Extract `setup_scroll_keymaps(buf)`.

### 3. Wikilink Lookup + Notification (2x -- lines 625-634, 739-750)
Both `M.preview()` and `M.edit_link()` do:
```lua
local details = link_utils.get_wikilink_under_cursor()
if not details then ... end
local path = wikilinks.resolve_link(details.name)
if not path then ... end
```
**Fix:** Extract `resolve_wikilink_under_cursor()`.

### 4. Float Window Creation (2x -- lines 661-683, 765-781)
Both preview and edit floats call `nvim_open_win()` with similar config, set filetype, setup highlights.
**Fix:** Extract `create_markdown_float(lines, opts)` factory.

### 5. Save-and-Close Pattern (2x -- lines 784-801, 810-814)
`M.edit_link()` has save logic split between `save_and_close()` function and WinClosed autocmd handler.
**Fix:** Unify into single save helper.

## Proposed Extraction Plan

### Subsystem A: History -- `preview/history.lua` (~60 lines)
**Functions:** History state + `push_history()`, `pop_back()`, `pop_forward()`, `clear_history()`, `history_position()`
**Rationale:** Fully self-contained. Only depends on `config.preview.history_max`. Reusable for other float navigation features.

### Subsystem B: Target Resolution -- `preview/target.lua` (~50 lines)
**Functions:** PreviewTarget class + `resolve_target()`, `resolve_target_in_preview()`, `resolve_wikilink_under_cursor()` (new)
**Rationale:** Core business logic. Independently testable. Used by M.preview() and navigate_in_preview().

### Subsystem C: Breadcrumb Formatting -- `preview/breadcrumb.lua` (~160 lines)
**Functions:** `vault_relative_segments()`, `format_breadcrumb()`, `truncate_breadcrumb()`
**Rationale:** 165 lines of pure formatting. Reusable for other float titles. Eliminates separator duplication.

### Subsystem D: Edit Float -- `preview/edit_float.lua` (~82 lines)
**Functions:** `M.edit_link()` + `save_and_close` helper
**Rationale:** Self-contained feature distinct from preview mode.

### Subsystem E: Float Rendering (optional, keep in main file)
**Functions:** state table, `is_active()`, `compute_float_dims()`, `setup_markdown_rendering()`, `update_float_title()`, `replace_float_content()`
**Rationale:** Tightly coupled to M.preview(). Extract only if needed for alternate UI.

## Forward Declaration Constraint
`close_preview`, `focus_preview`, `unfocus_preview` are forward-declared for mutual reference. Extraction of keymapping/navigation subsystem requires resolving this cycle.

## External Callers
- `init.lua:203` -- `preview.setup()`
- K keymap -- `M.preview()`
- `<leader>vE` keymap -- `M.edit_link()`
- `footnotes.lua` does NOT import preview; instead preview calls footnotes (one-way dep)

## Implementation Order
1. Extract history (zero deps, trivial)
2. Extract breadcrumb (pure formatting, high LOC)
3. Extract target resolution (core logic)
4. Extract edit_float (independent feature)
5. Dedup scroll keymaps, wikilink lookup, float creation within remaining code

## Expected Result
- `preview.lua`: ~495 lines (M.preview orchestrator + float helpers + navigation + M.setup)
- `preview/history.lua`: ~60 lines
- `preview/breadcrumb.lua`: ~160 lines
- `preview/target.lua`: ~50 lines
- `preview/edit_float.lua`: ~82 lines
