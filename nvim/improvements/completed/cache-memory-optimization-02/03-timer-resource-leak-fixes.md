# 03 — Timer & Resource Leak Fixes

## Priority: DONE
## Status: ALL FIXES IMPLEMENTED

## Problem

Investigation identified specific modules with unmanaged timers and per-buffer
state that leak memory when buffers are deleted.

### Original Leaks — Current Status

1. ~~**task_hierarchy.lua** — `_timers[bufnr]` has NO BufDelete cleanup~~ **FIXED** (lines 556-562, uses `cleanup.close_timer_in()`)
2. ~~**task_hierarchy.lua** — `_vtext_cache[bufnr]` has NO cleanup~~ **FIXED** (line 560, `_vtext_cache[ev.buf] = nil`)
3. **task_hierarchy.lua** — `_fold_state[rel_path]` grows unbounded — **MITIGATED** via `engine.register_cache()` invalidation (full reset at line 569: `_fold_state = {}`, per-file at line 576: `_fold_state[rel] = nil`), but no size cap
4. ~~**footnotes.lua** — `_fn_cache[bufnr]` has NO BufDelete cleanup~~ **FIXED** (lines 640-646, BufDelete + BufWipeout in `"VaultFootnotes"` augroup, also clears `footnotes_visible[bufnr]`)
5. ~~**link_scan.lua** — `_code_exclusion_cache[bufnr]` no BufDelete cleanup~~ **FIXED** (lines 170-172, BufDelete + BufWipeout via `M.clear_cache(ev.buf)`)
6. ~~**link_scan.lua** — `_frontmatter_cache[bufnr]` no BufDelete cleanup~~ **FIXED** (same autocmd, `M.clear_cache()` clears both caches)

### Remaining Issues — ALL FIXED

1. ~~**task_hierarchy.lua** — BufDelete handler (line 556) does NOT include `BufWipeout` event~~ **FIXED** (line 556 now has `{ "BufDelete", "BufWipeout" }`)
2. ~~**task_hierarchy.lua** — No VimLeavePre cleanup for `_timers`~~ **FIXED** (lines 564-572, iterates `_timers` with `cleanup.close_timer_in()`)
3. ~~**task_hierarchy.lua** — `_fold_state` has no size cap~~ **FIXED** (line 23, uses `lru.new(500)` — Option B from plan)
4. ~~**link_scan.lua** — BufDelete/BufWipeout autocmd has no augroup~~ **FIXED** (line 170, `"VaultLinkScan"` augroup)

### Impact

With the major leaks fixed, remaining impact is minimal:
- `_fold_state` growth is bounded by the number of unique vault files visited
  in a session (typically <100), each entry being a small table
- Missing `BufWipeout` on task_hierarchy is a minor gap since `BufDelete` fires
  in most buffer removal scenarios

## Zed Inspiration

Zed uses RAII-based cleanup via Rust's `Drop` trait across multiple patterns:

- **QueryCursorHandle** (`crates/language/src/syntax_map.rs:224`): Wraps pooled
  tree-sitter cursors; Drop (lines 1901-1908) resets cursor byte/point ranges and
  returns to `QUERY_CURSORS` pool (`crates/language/src/language.rs:94`,
  `Mutex<Vec<QueryCursor>>`) for reuse
- **IndexingEntryHandle** (`crates/semantic_index/src/indexing.rs:15-18`): Holds
  `Weak<IndexingEntrySet>`; Drop (lines 42-48) upgrades weak ref, sends
  notification via `set.tx.send_blocking()` channel, and removes entry from
  `set.entry_ids` tracking set
- **Savepoint transactions** (`crates/sqlez/src/savepoint.rs:10-28`): Callback-based
  pattern (not Drop); `with_savepoint()` executes `RELEASE` on success, `ROLLBACK TO`
  + `RELEASE` on error. Also has `with_savepoint_rollback()` (lines 33-51) which
  rolls back on `Ok(None)` as well
- **TransactionGuard** (`crates/collab/src/db.rs:292-296`): Wraps data with
  `OwnedMutexGuard<()>` to enforce single-threaded transaction access; no explicit
  Drop impl — relies on automatic Drop of `OwnedMutexGuard` to release mutex.
  Implements `Deref`/`DerefMut` for transparent data access
- **ConnectionGuard** (`crates/collab/src/rpc.rs:99`): Drop (lines 116-119)
  decrements `CONCURRENT_CONNECTIONS` atomic counter (line 94, `AtomicUsize`),
  enforcing `MAX_CONCURRENT_CONNECTIONS` limit of 512 (line 92). `try_acquire()`
  (lines 102-113) increments counter and returns `Err(())` if limit exceeded
- **Connection** (`crates/sqlez/src/connection.rs:12-17`): Wraps raw `*mut sqlite3`
  with `persistent` flag and `RefCell<bool>` write lock; Drop (lines 253-257) calls
  `sqlite3_close()` to prevent handle leaks

In Lua, the equivalent is consistent BufDelete/BufWipeout autocmd cleanup,
which the vault now does well across all major modules.

## Implementation — COMPLETE

All fixes have been implemented:

- **Fix 1**: `{ "BufDelete", "BufWipeout" }` at line 556 of task_hierarchy.lua
- **Fix 2**: VimLeavePre handler at lines 564-572 of task_hierarchy.lua
- **Fix 3**: `_fold_state = lru.new(500)` at line 23 of task_hierarchy.lua (Option B)
- **Fix 4**: `"VaultLinkScan"` augroup at line 170 of link_scan.lua

### Deduplication — COMPLETE

- **cleanup.on_buf_delete()** added to `resource_cleanup.lua` — centralises `{ "BufDelete", "BufWipeout" }` event pair so modules never accidentally omit `BufWipeout`
- 8 modules migrated: callout_folds, frontmatter_parser, link_scan, autolink, autosave, embed, task_hierarchy, highlight_coordinator (setup_buf_cleanup)
- **build_display()** extracted in `task_hierarchy.lua` — eliminates ~25 lines of duplicated display-building logic between initial render and refresh()

## Audit Checklist

Current state of per-buffer cleanup across all vault modules:

| Module | State | BufDelete | BufWipeout | VimLeavePre |
|--------|-------|-----------|------------|-------------|
| highlight_coordinator.lua | `_timers[bufnr]` (line 159) | YES (line 269) | YES (line 269) | - |
| autosave.lua | `_timers[bufnr]` (line 19) | YES (line 206) | YES (line 206) | - (cleanup via `remove_autocmds()` lines 141-151) |
| embed.lua / embed_state.lua | 7 dicts by bufnr (lines 13-21) | YES (line 783) | YES (line 783) | YES (lines 790-798, iterates all tracked buffers) |
| highlights.lua | `_nav_cache[bufnr]` (line 12) | YES (via `hl_coord.setup_buf_cleanup` line 226) | YES (via `hl_coord.setup_buf_cleanup`) | - |
| tag_highlights.lua | `_nav_cache[bufnr]` (line 12) | YES (via `hl_coord.setup_buf_cleanup` line 289) | YES (via `hl_coord.setup_buf_cleanup`) | - |
| task_hierarchy.lua | `_timers`, `_vtext_cache`, `_fold_state` (LRU) | YES (line 556) | YES (line 556) | YES (lines 564-572) |
| footnotes.lua | `_fn_cache`, `footnotes_visible` (lines 19-20) | YES (line 640) | YES (line 640) | - |
| link_scan.lua | 2 caches by bufnr (lines 10-11) | YES (line 170) | YES (line 170) | - |

### Augroup Summary

| Module | Augroup | Notes |
|--------|---------|-------|
| highlight_coordinator.lua | `"VaultHighlightCoordinator"` (line 210) | All autocmds in augroup |
| autosave.lua | `"VaultAutoSave"` (line 110) | Separate `"VaultAutoSaveCleanup"` augroup (intentional — persists across enable/disable) |
| callout_folds.lua | `"VaultCalloutFoldCleanup"` | BufDelete/BufWipeout in named augroup |
| autolink.lua | `"VaultAutoLink"` (line 345) | BufDelete/BufWipeout in augroup |
| embed.lua | `"VaultEmbed"` (line 692) | All autocmds in augroup |
| highlights.lua | `"VaultHighlightHL"` (line 224) | Cleanup via hl_coord |
| tag_highlights.lua | `"VaultTagHL"` (line 287) | Cleanup via hl_coord, own augroup |
| task_hierarchy.lua | `"VaultTaskHierarchy"` (line 531) | All autocmds in augroup |
| footnotes.lua | `"VaultFootnotes"` (line 637) | Also `"VaultFootnotePreviewClose"` (line 550) |
| link_scan.lua | `"VaultLinkScan"` (line 170) | BufDelete/BufWipeout in named augroup |

## Testing

1. Open a markdown buffer with tasks, close it, verify `_timers` is empty
2. Open 20 buffers with footnotes, close all, run `:VaultCacheStats` to verify
   `_fn_cache` is empty
3. Run `:lua print(vim.inspect(vim.uv.timer_get_due_in))` or equivalent to
   verify no orphaned timers exist after closing all markdown buffers
