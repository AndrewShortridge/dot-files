# Improvement Dependency Graph (03–15)

## Visual Dependency Graph

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 1                              │
                    │           Independent Features (no hard deps)           │
                    │                                                         │
                    │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
                    │  │ #10 Advanced │  │ #12 Carry-   │  │ #15 External │  │
                    │  │ Search Ops   │  │ Forward Logs │  │ URL Valid.   │  │
                    │  │   [Large]    │  │   [Medium]   │  │   [Medium]   │  │
                    │  └──────────────┘  └──────────────┘  └──────┬───────┘  │
                    └─────────────────────────────────────────────┼──────────┘
                                                                  │
                                  optional: vault_index.lua ──────┘
                                  external_urls field

                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 2                              │
                    │        Core Index Enhancements (vault_index.lua)        │
                    │        Implement sequentially to avoid conflicts        │
                    │                                                         │
                    │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
                    │  │ #3 Live      │  │ #4 Heading/  │  │ #5 Tag       │  │
                    │  │ Embed Sync   │  │ Block Compl. │  │ Hierarchy    │  │
                    │  │   [Medium]   │  │   [Medium]   │  │   [Medium]   │  │
                    │  └──────┬───────┘  └──────────────┘  └──────────────┘  │
                    │         │                                               │
                    │  _notify_update()                                       │
                    │  signature change                                       │
                    └─────────────────────────────────────────────────────────┘
                              │
                              │  #3's subscriber pattern enables future
                              │  reactive features
                              ▼
                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 3                              │
                    │              Documentation (do last)                    │
                    │                                                         │
                    │  ┌──────────────────────────────────────────────────┐   │
                    │  │ #14 Vault Architecture Doc                      │   │
                    │  │ Must reflect final state of all other changes   │   │
                    │  │   [Small — documentation only]                  │   │
                    │  └──────────────────────────────────────────────────┘   │
                    └─────────────────────────────────────────────────────────┘
```

---

## Shared File Conflict Matrix

| Shared File | #3 | #4 | #5 | #10 | #12 | #14 | #15 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `lua/andrew/vault/vault_index.lua` | **W** | **W** | **W** | | | | W† |
| `lua/andrew/vault/config.lua` | W | | W | W | W | | W |
| `lua/andrew/vault/engine.lua` | | | | W | | | W |
| `lua/andrew/vault/embed.lua` | W | | | | | | |
| `lua/andrew/vault/completion.lua` | | W | | | | | |
| `lua/andrew/vault/tags.lua` | | | W | | | | |
| `lua/andrew/vault/search.lua` | | | | W | | | |
| `lua/andrew/vault/saved_searches.lua` | | | | W | | | |
| `lua/andrew/vault/calendar.lua` | | | | | W | | |
| `lua/andrew/vault/templates/daily_log.lua` | | | | | W | | |
| `lua/andrew/vault/navigate.lua` | | | | | W | | |
| `lua/andrew/vault/linkdiag.lua` | | | | | | | W |
| `lua/andrew/vault/linkcheck.lua` | | W | | | | | W |

**W** = writes/modifies, **bold** = high-conflict potential (multiple writers), †optional follow-up

### New Files Created

| Improvement | New Module |
|---|---|
| #5 | `lua/andrew/vault/tag_tree.lua` |
| #10 | `lua/andrew/vault/search_query.lua` |
| #10 | `lua/andrew/vault/search_filter.lua` |
| #15 | `lua/andrew/vault/url_validate.lua` |

---

## Per-Improvement Detail

### #3 — Live Embed Sync `[Medium]`
- **Creates:** Nothing new
- **Modifies:** `embed.lua`, `vault_index.lua`, `config.lua`
- **Hard deps:** None
- **Soft deps:** None
- **Key change:** Extends `_notify_update()` to pass changed file paths; adds subscriber pattern to `embed.lua` with dependency tracking and per-buffer debounce
- **Risk:** Medium (vault_index API change affects all `_notify_update()` call sites)

### #4 — Heading/Block Anchor Completion `[Medium]`
- **Creates:** Nothing new
- **Modifies:** `completion.lua`, `vault_index.lua`, `linkcheck.lua`
- **Hard deps:** None
- **Soft deps:** Coordinate with #3 on `vault_index.lua` (non-overlapping edits)
- **Key change:** `extract_block_ids()` returns `{ id, text, line }[]` instead of `string[]`; heading/block completion uses index instead of file I/O
- **Risk:** Low-Medium (block_ids schema change requires `linkcheck.lua` update)

### #5 — Tag Hierarchy Visualization `[Medium]`
- **Creates:** `lua/andrew/vault/tag_tree.lua`
- **Modifies:** `vault_index.lua`, `tags.lua`, `config.lua`
- **Hard deps:** None
- **Soft deps:** Coordinate with #3, #4 on `vault_index.lua` (non-overlapping edits)
- **Key change:** Adds `tags_with_counts()` and `files_for_tag()` to vault_index; fzf-lua tree picker with collapsible hierarchy
- **Risk:** Low

### #10 — Advanced Search Operators `[Large]`
- **Creates:** `search_query.lua`, `search_filter.lua`
- **Modifies:** `search.lua`, `saved_searches.lua`, `config.lua`, `engine.lua`
- **Hard deps:** None
- **Soft deps:** None (reads vault_index but doesn't modify it)
- **Key change:** Query parser (tokenizer + recursive descent) with boolean ops, field filters, date ranges; hybrid ripgrep + index filter pipeline
- **Risk:** Medium (query grammar complexity, performance on large vaults)

### #12 — Carry-Forward for Daily Logs `[Medium]`
- **Creates:** Nothing new
- **Modifies:** `calendar.lua`, `templates/daily_log.lua`, `config.lua`, `navigate.lua`
- **Hard deps:** None
- **Soft deps:** None (no shared files with other improvements except `config.lua`)
- **Key change:** Unify calendar's inline template with `daily_log.generate()`; multi-day lookback with dedup
- **Risk:** Low (calendar template unification is the main risk)

### #14 — Vault Architecture Doc `[Small]`
- **Creates:** Architecture documentation (the deliverable IS the doc)
- **Modifies:** No code files
- **Hard deps:** Should be done AFTER all others (documents final state)
- **Soft deps:** Every other improvement (#3, #4, #5, #10, #12, #15) adds modules or changes APIs
- **Key change:** Unified module inventory, dependency maps, data flow diagrams, init lifecycle
- **Risk:** Very Low (documentation only)

### #15 — External URL Validation `[Medium]`
- **Creates:** `lua/andrew/vault/url_validate.lua`
- **Modifies:** `linkdiag.lua`, `linkcheck.lua`, `config.lua`, `engine.lua`, optionally `vault_index.lua`
- **Hard deps:** None
- **Soft deps:** Coordinate with #4 on `linkcheck.lua` (non-overlapping edits)
- **Key change:** Async HTTP validation via curl, persistent TTL cache, rate limiting, HEAD→GET fallback
- **Risk:** Medium (network I/O reliability, rate limiting tuning)

---

## Recommended Implementation Order

```
Phase 1 ─ Independent Features (no shared file conflicts between them)
  1. #10  Advanced Search Operators       [Large]    — self-contained new modules
  2. #12  Carry-Forward for Daily Logs    [Medium]   — isolated to calendar/template system
  3. #15  External URL Validation          [Medium]   — isolated to linkdiag/linkcheck

Phase 2 ─ Index Enhancements (all touch vault_index.lua — do sequentially)
  4. #3   Live Embed Sync                 [Medium]   — _notify_update() API change first
  5. #4   Heading/Block Anchor Completion  [Medium]   — block_ids schema change
  6. #5   Tag Hierarchy Visualization      [Medium]   — additive new methods

Phase 3 ─ Documentation (reflects final state)
  7. #14  Vault Architecture Doc           [Small]    — must come last
```

### Rationale

1. **Phase 1 first** — #10, #12, #15 are fully independent of each other and don't touch `vault_index.lua`. All three can be implemented in parallel if desired.
2. **Phase 2 sequential** — #3, #4, #5 all modify `vault_index.lua`. Changes are non-overlapping (different functions/methods) but sequential implementation avoids merge pain. #3 first because its `_notify_update()` signature change is the most foundational.
3. **#14 last** — The architecture doc must document the final state including all new modules (`tag_tree.lua`, `search_query.lua`, `search_filter.lua`, `url_validate.lua`) and API changes.

---

## Conflict Resolution Notes

### `vault_index.lua` (4 improvements touch this)
Each improvement modifies different functions/methods — non-overlapping but dense:
- **#3:** `_notify_update()` signature + all call sites (`update_file`, `remove_file`, `update_files_batch`, `build_sync`, `build_async`)
- **#4:** `extract_block_ids()` return type + `_parse_file()` + `get_block_ids()`
- **#5:** New methods `tags_with_counts()` + `files_for_tag()`
- **#15:** (optional) New field `external_urls` + `extract_external_urls()`

### `config.lua` (5 improvements touch this)
Each adds a new top-level section with unique keys — append-only, no conflicts:
```lua
M.embed.sync = { ... }       -- #3
M.tag_tree = { ... }         -- #5
M.search = { ... }           -- #10
M.carry_forward = { ... }    -- #12
M.url_validation = { ... }   -- #15
```

### `engine.lua` (#10 + #15)
- **#10:** Adds optional ripgrep `--files-from` helper
- **#15:** Adds URL cache load/persist lifecycle hooks
- Non-overlapping sections, safe to implement in either order.

### `linkcheck.lua` (#4 + #15)
- **#4:** Updates consumers of `block_ids` to handle new structured format
- **#15:** Adds `check_urls_buffer()` and `check_urls_vault()` functions
- Non-overlapping, but implement #4 first if doing sequentially.

---

## Parallel Implementation Guide

If multiple developers are working simultaneously:

```
Developer A                    Developer B                    Developer C
─────────────                  ─────────────                  ─────────────
#10 Search Operators           #12 Carry-Forward              #15 URL Validation
  (search.lua, search_*.lua)     (calendar.lua, daily_log)     (linkdiag, url_validate)
         │                              │                              │
         ▼                              ▼                              ▼
      ── sync ── merge config.lua additions ── sync ──
         │
         ▼
#3 Live Embed Sync ──► #4 Heading Completion ──► #5 Tag Hierarchy
  (vault_index.lua      (vault_index.lua          (vault_index.lua
   _notify_update)       block_ids schema)         new methods)
         │                                              │
         ▼                                              ▼
      ── sync ── merge vault_index.lua changes ── sync ──
                              │
                              ▼
                    #14 Architecture Doc
```
