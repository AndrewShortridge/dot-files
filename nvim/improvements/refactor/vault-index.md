# vault_index.lua Refactoring Plan

## Overview

`lua/andrew/vault/vault_index.lua` is the largest single file in the vault module at 1,701 lines. It serves as the unified persistent index and sole source of truth for vault metadata. While there is no dead code, the file contains several distinct subsystems that can be extracted into focused sub-modules without changing the public API or breaking the zero-internal-requires constraint.

## File Stats

- **File:** `lua/andrew/vault/vault_index.lua`
- **Lines:** 1,701
- **Dead Code:** None
- **Public API:** `M.get()`, `M.current()`, `M.parse_task_fields()`, `M.tag_matches()`, plus ~20 VaultIndex methods

## Current Structure

| Section | Lines | Purpose |
|---------|-------|---------|
| Header & Imports | 1-14 | Module setup, 5 deps (slug, cleanup, block_patterns, config, notify, log) |
| Utility Functions | 17-24, 234-620 | String stripping, frontmatter parsing, tag/heading/link/task/field extraction |
| VaultIndex Class | 30-88 | Type annotation, metatable, singleton, constructor |
| Subscriber System | 98-120 | Update listeners, notify, is_ready |
| Persistence Layer | 130-228 | Load/save index to disk, debounced persist |
| File Parsing (Single-Pass) | 622-694 | `_parse_file()` -- parse one .md file into entry |
| Directory Walking | 695-726 | `_walk()` -- recursive filesystem walk |
| Change Detection | 727-784 | `_detect_changes()` -- mtime/size diffing |
| Name/Alias Indexing | 785-903 | Full rebuild + incremental update of name/alias indexes |
| Collision Detection | 905-1112 | `_detect_collisions()`, `_notify_collisions()`, `show_collisions()` (208 lines) |
| Inlink Computation | 1113-1251 | Resolution tables, outlink processing, full + incremental inlinks rebuild |
| Build Operations | 1253-1465 | `build_sync()`, `build_async()`, `update_file()`, `remove_file()`, `update_files_batch()` |
| Public Query API | 1466-1607 | 12 query methods (resolve_name, all_tags, get_headings, etc.) |
| Collision UI | 1608-1701 | `show_collisions()` floating window display |

## Duplicated Logic Patterns

### 1. Directory Walking (2x)

Lines 695-726 (`_walk()`) and 727-784 (`_detect_changes()`) both recursively walk the filesystem with nearly identical structure:

```lua
local function walk(abs_dir, rel_dir)
  local handle = vim.uv.fs_scandir(abs_dir)
  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    -- process directory / file
  end
end
```

**Fix:** Extract a shared `_walk_with_callback(vault_path, callback)` that both use.

### 2. Name Index Rebuild vs Incremental (Lines 793-903)

Full rebuild (`_rebuild_name_index`) and incremental update (`_update_name_index_incremental`) duplicate logic for adding entries to name/alias indexes.

**Fix:** Parameterize the incremental version to handle both cases, or extract shared `_add_to_name_index(entry)` / `_remove_from_name_index(entry)` helpers.

### 3. Inlinks Full vs Incremental (Lines 1181-1251)

`_recompute_inlinks()` and `_recompute_inlinks_incremental()` share similar remove-then-rebuild-then-add phases.

**Fix:** Extract shared resolution and insertion helpers.

## Proposed Extraction Plan

### Subsystem A: File Parser --> `vault_index_parser.lua` (~387 lines)

**Functions to extract:**

- `strip_quotes()`, `strip_inline_code()`, `strip_code_blocks()`
- `split_frontmatter()`, `parse_frontmatter()`
- `add_tag_with_parents()`, `extract_tags()`
- `extract_headings()`, `extract_block_ids()`, `extract_links()`
- `parse_task_fields()` (currently exported as `M.parse_task_fields`)
- `extract_tasks()`, `extract_inline_fields()`
- `_parse_file()` body logic

**Rationale:** Pure functions with no dependencies on VaultIndex state. Only requires `slug` and `block_patterns`. This is the highest-value extraction at 387 lines.

**Constraint:** Must preserve `M.parse_task_fields` as a public export on the main module (used by `recurrence.lua`). The main module re-exports it:

```lua
-- vault_index.lua
local parser = require("andrew.vault.vault_index_parser")
M.parse_task_fields = parser.parse_task_fields
```

### Subsystem B: Inlink Computation --> `vault_index_inlinks.lua` (~139 lines)

**Functions to extract:**

- `build_resolution_tables()`
- `resolve_link_target()`
- `add_inlink()`
- `resolve_outlinks_into()`
- `_recompute_inlinks()`
- `_recompute_inlinks_incremental()`

**Rationale:** Self-contained link resolution subsystem. No external dependencies beyond the index state passed as parameters.

### Subsystem C: Collision Detection --> `vault_index_collisions.lua` (~208 lines)

**Functions to extract:**

- `_detect_collisions()`
- `_notify_collisions()`
- `show_collisions()` (floating window UI)

**Rationale:** UI and reporting code that uses `vim.api` and `vim.uv.new_timer`. Cleanly separable from core indexing logic.

### Subsystem D: Async Build --> `vault_index_build.lua` (~200 lines)

**Functions to extract:**

- `build_async()` (coroutine-based with progress reporting)
- `update_files_batch()` (batch update dispatcher)

**Rationale:** Complex async/coroutine logic isolated from core indexing. Reduces cognitive load in the main file.

### Subsystem E: Directory Walking Dedup (internal refactor, ~50 lines saved)

**Refactor:** Extract `_walk_with_callback()` used by both `_walk()` and `_detect_changes()`. This stays in the main file since it is small and tightly coupled to the build pipeline.

## Architecture Constraint

`vault_index.lua` intentionally has **zero requires of other vault modules** (only leaf utilities: `slug`, `cleanup`, `block_patterns`, `config`, `notify`, `log`) to prevent circular dependencies. All extracted sub-modules must maintain this constraint -- they may only require the same leaf utilities.

## External Callers

These call sites must continue to work without changes:

- 45+ files call `vault_index.current()` to get the singleton
- `recurrence.lua` calls `M.parse_task_fields()`
- `search_filter/match_field.lua` calls `M.tag_matches()`
- `engine.lua` calls `build_async()`, `update_files_batch()`

## Implementation Order

Each step is independently shippable and testable:

1. **Extract parser** -- biggest win, pure functions, lowest risk
2. **Extract inlinks** -- self-contained subsystem
3. **Extract collisions** -- UI code, independent
4. **Extract async build** -- complex but isolated
5. **Dedup directory walking** -- internal refactor, smallest change

## Expected Result

After all extractions:

| File | Lines | Role |
|------|-------|------|
| `vault_index.lua` | ~900-1,000 | Orchestrator: class, queries, persistence, subscribers, sync build |
| `vault_index_parser.lua` | ~387 | Single-pass file parsing, frontmatter, tags, headings, links, tasks |
| `vault_index_inlinks.lua` | ~139 | Link resolution tables, inlink computation (full + incremental) |
| `vault_index_collisions.lua` | ~208 | Name collision detection, notification, floating window UI |
| `vault_index_build.lua` | ~200 | Async build coroutine, batch update dispatcher |

Total line count stays roughly the same. The main file drops to ~60% of its current size, and each sub-module has a single clear responsibility.
