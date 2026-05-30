# engine.lua Refactoring Plan — COMPLETED

## Final State

| File | Lines | Contents |
|------|-------|----------|
| `engine.lua` | ~575 | Cache, vault mgmt, coroutines, dates, utils, enumeration, name cache, init, re-exports |
| `engine_templates.lua` | ~225 | Template substitution, Obsidian format maps, variable registry |
| `engine_watcher.lua` | ~240 | Filesystem watcher, platform-specific logic, event handling |
| `engine_file_io.lua` | ~173 | File read/write, directory creation, JSON store |

## Completed Steps

### 1. Dead Code Analysis

- **`M.render()`**: Investigated — NOT dead code. Has 14 active callers across template modules. Retained as alias for `M.substitute()`.
- **`M.unregister_var()`**: Was never implemented in actual code (only in spec docs). Nothing to remove.

### 2. Extract Templates → `engine_templates.lua` ✓

Extracted: `substitute()`, `obsidian_to_strftime()`, `format_obsidian()`, `register_var()`, `OBSIDIAN_FORMAT_MAP`, `OBSIDIAN_UNPADDED`, `BUILTIN_VARS`.

### 3. Extract Filesystem Watcher → `engine_watcher.lua` ✓

Extracted: `start_fs_watcher()`, `stop_fs_watcher()`, `watcher_status()`, platform-specific helpers.

### 4. Extract File I/O → `engine_file_io.lua` ✓

Extracted: `ensure_dir()`, `json_store()`, `read_file()`, `read_file_lines()`, `write_file()`, `append_file()`, `write_note()`. Re-exported on `M` table for backward compatibility.

### 5. Dedup Patterns ✓

- **File open errors**: Extracted `open_file(path, mode)` helper in `engine_file_io.lua`. All 7 `io.open()` call sites now go through the single helper.
- **Coroutine UI wrappers**: Extracted `wrap_ui(ui_fn)` factory in `engine.lua`. `M.input` and `M.select` are now generated from the factory, eliminating ~20 lines of duplicated coroutine/schedule/resume logic.
- **Date formatting**: Extracted `format_date_with_day(prefix_fmt, ts)` helper. Used by `M.today_long()`, `M.today_weekday()`, and `M.format_weekday()`.
