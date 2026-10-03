# Neovim Config Audit Report

Target: `/home/andrew-cmmg/.config/nvim` (Neovim 0.12.2, LuaJIT)
Date: 2026-06-09

---

## 1. Executive Summary

| Metric | Count |
| --- | --- |
| Total findings triaged | 52 |
| Unique findings | 51 |
| Verified candidates | 28 |
| **Confirmed defects/items** | **24** |
| Low-severity / latent (unverified) | 23 |

**Confirmed items by severity & category:**

| | High | Medium | Low | Total |
| --- | --- | --- | --- | --- |
| Type / runtime errors | 3 | 3 | 0 | 6 |
| Deprecations | 0 | 2 | 9 | 11 |
| Test / e2e errors | 1 | 3 | 1 | 5 |
| Other (tooling) | 0 | 1 | 0 | 1 |
| **Total** | **4** | **9** | **11** | **24** |

**Overall health.** The production Lua code is largely sound. There are **4 genuine, user-reachable nil-call/nil-deref bugs** that hard-error on core feature paths (graph multi-hop, embed-on-navigation, connections compute, and a startup-race in the calendar). These should be fixed first; each is a one- to few-line scope/ordering fix. The remaining type-level items are real but narrow (an export race nil-deref, a dead-code terminal job guard). The bulk of confirmed items (11) are non-fatal API **deprecations** — `nvim_buf_add_highlight`, `nvim_buf_set_option`, `jobclose` — all still functional in 0.12.2 with no scheduled removal; treat as forward-compatibility cleanup. The **test suite is partially broken**: one spec never runs (harness mismatch), and ~47 assertions in `test_vault_fixes.lua` are stale after the Phase 6 vault-index refactor.

**luals noise filtered.** Triage reviewed luals output across ~150 files and dismissed **essentially all of it as false positives** stemming from missing type definitions — primarily the repo-internal `VaultIndexEntry`/`VaultHeading`/`ProfilerCacheSpec` annotation classes and the `VaultIndex` singleton's metatable (luals cannot see through `__index` dispatch), plus plugin globals (`Snacks`, `blink.cmp.*`) and `os.date("*t")` field over-typing. Representative dismissals: `vault_index.lua` (29), `connections.lua` (~55), `embed.lua` (76), `calendar.lua` (~40), `completion.lua` (~30), `date_utils.lua` (~30) — **all dismissed except the genuine bugs below.** Only **a handful of luals findings survived triage as true positives** (the undefined-globals in `graph.lua`, `embed.lua`, `connections.lua`, `calendar.lua`, and the deprecation flags). Net: the vast majority of luals signal was filtered as type-definition noise; the genuine defects were found by manual/empirical review, several of which luals also independently flagged.

---

## 2. Type / Runtime Errors (confirmed only)

### High severity

#### H1 — `graph.lua:314` — undefined global `buf_path` breaks multi-hop graph (hard error)
- **File:line:** `lua/andrew/vault/graph.lua:314` (also read at 123, 298)
- **What's wrong:** Inside `M.local_graph()`, `buf_path` is referenced at lines 123, 298, 314 but is **never declared** as a local or parameter (grep: 3 read-sites, 0 assignments). It resolves to a nil global. The depth>1 branch calls `graph_filter.collect_at_depth_async(buf_path, ...)` with nil, which flows to `traversal.collect_at_depth_async` → `check_cache` → `filter_utils.bfs_init(idx, nil)` → `engine.vault_relative(nil)` → `engine.is_vault_path(nil)` → `vim.startswith(nil, ...)`, which **throws** `"s: expected string, got nil"`. The call at line 314 has no surrounding pcall, so `M.local_graph()` aborts with a stack trace. Reachable via a routine action: the `+` keymap (graph.lua:217-221) increments `state.depth` (up to `config.graph.max_depth = 5`) and re-invokes the function, entering the depth>1 branch. Multi-hop graph is entirely non-functional.
- **Fix:** Declare the center path at the top of `M.local_graph()`, e.g. `local buf_path = vim.api.nvim_buf_get_name(0)` (the `is_vault_buf(0)` guard at line 34 already ensures a valid vault buffer). This single fix also resolves M2 and L1 below.

#### H2 — `embed.lua:1145` — out-of-scope local `is_valid_current_buf` called as nil global
- **File:line:** `lua/andrew/vault/embed.lua:1145`
- **What's wrong:** `is_valid_current_buf` is a `local function` defined at line 1025 **inside `M.setup()`** (lines 935-1117); its only valid use is at line 1044 (still inside setup). At line 1145, inside the separate top-level `M.on_buf_enter()` (starts at 1121), the local is out of lexical scope, so the call resolves to the nonexistent global (nil) → `"attempt to call a nil value (global is_valid_current_buf)"`. Reachable: `event_dispatch.lua:90` calls `embed.on_buf_enter(ctx)` for every vault markdown buffer on `BufEnter`; the failing branch fires whenever the buffer's embed state isn't yet visible (the normal first-entry case), waits for the index, schedules NORMAL work, and that callback hits line 1145 and throws, aborting the scheduled embed render. Breaks embed rendering on the primary note-navigation path.
- **Fix:** Hoist `is_valid_current_buf` to module scope (define it as a top-level `local function` before both `M.setup` and `M.on_buf_enter`), or inline `vim.api.nvim_buf_is_valid(ctx.bufnr) and vim.api.nvim_get_current_buf() == ctx.bufnr` at line 1145.

#### H3 — `connections.lua:645` — `ensure_subscription` used before its `local function` definition (nil call)
- **File:line:** `lua/andrew/vault/connections.lua:645`
- **What's wrong:** `prepare_compute` (line 643) calls `ensure_subscription()` at line 645, but `ensure_subscription` is only defined as `local function ensure_subscription()` at line 992, with **no forward declaration**. Per Lua lexical scoping, the local is visible only from line 992 onward, so the reference at 645 resolves to the nil global → `"attempt to call a nil value (global 'ensure_subscription')"`. `prepare_compute` is the shared setup for both `M.compute` (line 717) and `M.compute_async` (line 781) — the module's core public API (invoked at 857 and 913) — so **every connection computation crashes** at line 645. The author forward-declared the analogous `_subscription` (line 100) and `unsubscribe` (line 107), confirming this omission is an unintended bug.
- **Fix:** Add `local ensure_subscription` near line 100 (alongside `_subscription`), then change line 992 from `local function ensure_subscription()` to `function ensure_subscription()` (assigning the existing upvalue). Alternatively, move the definition above `prepare_compute`.

### Medium severity

#### M1 — `graph.lua:123` — `graph_ctx.source_buf_name` set to nil, breaks "Create note" and in-graph search
- **File:line:** `lua/andrew/vault/graph.lua:123`
- **What's wrong:** Same root cause as H1: `source_buf_name = buf_path` stores nil. Consumers assume a real path — `navigate_to()` (line 139) calls `link_utils.lua_dirname(graph_ctx.source_buf_name)` when creating an unresolved note, and `lua_dirname` (link_utils.lua:461-463) does `path:match(...) or path` with no nil guard, so `nil:match(...)` raises "attempt to index a nil value" when the user picks **"Create note"**. The `s` keymap (lines 279-281) also adds `source_buf_name` to the search file set, so the center note is silently omitted from in-graph search. The graph still opens (the nil is tolerated elsewhere), so this is medium, not crash-on-open.
- **Fix:** None beyond defining `buf_path` correctly (H1 fix); once defined, `source_buf_name` carries the real absolute path.

#### M2 — `export.lua:133` — `#content_lines` on possibly-nil return from `file_cache.read`
- **File:line:** `lua/andrew/vault/export.lua:133` (assignment at 132)
- **What's wrong:** `content_lines = file_cache.read(path)` (line 132); `file_cache.read` is annotated `@return string[]|nil` and returns `nil, nil` when `vim.uv.fs_stat` fails (file_cache.lua:42) or `io.open` fails (file_cache.lua:56). Line 133 evaluates `#content_lines == 0` with **no `not content_lines` guard**, so an unreadable/deleted file (race after `wikilinks.resolve_link` at line 114) makes `#nil` raise "attempt to get length of a nil value". The sibling block_id branch at line 123 correctly guards with `if not content_lines or #content_lines == 0`; only this else/read branch is unguarded.
- **Fix:** Change line 133 to `if not content_lines or #content_lines == 0 then` (mirroring line 123).

#### M3 — `calendar.lua:127` — forward-reference to local `_deadline_cache` resolves to nil global in deferred callback
- **File:line:** `lua/andrew/vault/calendar.lua:127`
- **What's wrong:** `scan_dates_from_index` (`local function`, line 119) registers a deferred callback (lines 124-129) whose body calls `_deadline_cache:invalidate()` at line 127. But `local _deadline_cache` is not declared until line 147 — **after** this function. Per Lua scoping, line 127 binds to the nil global. When the vault index later becomes ready and `wait_for_ready` fires the callback via `vim.schedule`, `nil:invalidate()` raises "attempt to index a nil value (global '_deadline_cache')". Crucially, `vault_index.lua:_check_waiters` wraps only the outer callback in pcall (line 377); the actual `:invalidate()` runs later inside `vim.schedule`, **outside** that pcall, so the error is an unhandled scheduled error visible to the user. All other references (193, 739, 743, 755, 759-760) are below line 147 and bind correctly. Gated on the startup race (calendar opened before index ready); blast radius is failed cache invalidation → stale deadline indicators plus a visible error notice.
- **Fix:** Add a forward declaration `local _deadline_cache` before line 119, and change line 147 to a plain assignment `_deadline_cache = gen_cache.gen_cache(...)`. Also change line 127 to a dot-call `_deadline_cache.invalidate()` for consistency with the rest of the file.

#### M4 — `terminal.lua:193` — `jobwait()` list compared to `0` (always false) → terminal job never killed
- **File:line:** `lua/andrew/custom/plugins/terminal.lua:193`
- **What's wrong:** `if floating_terminal.termpid and vim.fn.jobwait({ floating_terminal.termpid }, 0) == 0 then`. `vim.fn.jobwait` returns a **list** (`{-1}` running, `{-3}` invalid, `{exitcode}` done) — never the scalar `0`. In LuaJIT `table == 0` is always false, so the guarded body (line 194, `vim.fn.jobclose(...)`) is dead code. The job started by `jobstart` (line 129) is never explicitly terminated on `close()`; only window/buffer are torn down, leaking the shell process. (In practice the force buffer-delete on line 199 often SIGHUPs the child, partially mitigating.)
- **Fix:** Test the first list element: `local status = vim.fn.jobwait({ floating_terminal.termpid }, 0)[1]; if floating_terminal.termpid and status == -1 then vim.fn.jobstop(floating_terminal.termpid) end`. Or call `vim.fn.jobstop(floating_terminal.termpid)` unconditionally (no-op for a dead job). Note the body should not use `jobclose` (see D-table below).

---

## 3. Deprecations

All deprecated APIs below **still function in Neovim 0.12.2** and have **no documented removal version** (none scheduled through 0.13). These are forward-compatibility cleanups, not runtime bugs. Many of the highlight calls are `pcall`-wrapped, so they degrade gracefully even on hypothetical future removal.

| Deprecated API | Replacement | File:line(s) | Deprecated in | Removal |
| --- | --- | --- | --- | --- |
| `vim.fn.jobclose()` | `vim.fn.chanclose()` or `vim.fn.jobstop()` | `lua/andrew/custom/plugins/terminal.lua:194` | 0.10 | none (≤0.13) |
| `vim.api.nvim_buf_set_option()` | `vim.api.nvim_set_option_value("…", v, {buf=…})` or `vim.bo[buf].…` | `lua/andrew/vault/task_kanban.lua:452`, `:454` | 0.10 | none (≤0.13) |
| `vim.api.nvim_buf_add_highlight()` | `vim.hl.range(...)` or `vim.api.nvim_buf_set_extmark(buf, ns, row, col, {end_col=…, hl_group=…})` | `lua/andrew/vault/stats.lua:461`; `lua/andrew/vault/graph.lua:112`; `lua/andrew/vault/graph/search_graph.lua:112`; `lua/andrew/vault/task_hierarchy.lua:380`; `lua/andrew/vault/task_kanban.lua:459`, `:541`; `lua/andrew/vault/task_timeline.lua:279`; `lua/andrew/vault/ui.lua:204`, `:214` | 0.11 | none (≤0.13) |

Notes:
- `terminal.lua:194` `jobclose` is currently **dead code** behind the always-false guard at line 193 (see M4); when that guard is fixed, use `jobstop`/`chanclose`, not `jobclose`.
- `stats.lua:461` passes `ns = -1` (auto namespace). The extmark replacement does not support `-1`; create a real namespace once, e.g. `local ns = vim.api.nvim_create_namespace("vault_stats")`.
- The `nvim_buf_add_highlight` pattern recurs across ~11 sites repo-wide (also `vault_index_collisions.lua:181`, `:286` — see §5). A single shared helper or sweep would address all of them.

---

## 4. Test / End-to-End Failures

### T1 (medium) — `structural_sharing_spec.lua` is a harness mismatch; it never runs
- **File:line:** `tests/structural_sharing_spec.lua:58`
- **Root cause:** The spec is busted-style (top-level `describe`/`it`, `assert.is_true`/`same`/`has_error`/`equals`/`near`). The repo has **no busted/plenary runner**, and `nvim --headless -u NONE -l tests/structural_sharing_spec.lua` aborts immediately: `E5113: …:58: attempt to call global 'describe' (a nil value)`. This is the **only** spec relying on external globals — the 6 sibling specs (`lru_cache`, `batch_drain`, `watch_channel`, `request_coalescer`, `vault_index_snapshot`, `summary_tree`) plus `test_vault_fixes` are self-contained (local `test(name, fn)` runner + `assert_*` helpers, a `-- Run with: nvim --headless -u NONE -l …` header, and a pass/fail summary with `os.exit`).
- **Impact (coverage gap):** It is **not** a stale-API problem — every symbol the spec references exists in `structural_sharing.lua` (`arrays_equal`, `dicts_equal`, `struct_arrays_equal`, `share_unchanged`, `new_intern_store`, `intern_array`, `intern_store_stats`, `share_stats`, `freeze`). But the module is used in production (`vault_index.lua:218`, `vault_index_build.lua:12`, `init.lua:1288`) yet has **zero runnable coverage** because this spec is effectively dead.
- **Fix (preferred):** Convert to the self-contained style of the siblings — replace busted globals with the local `test()` runner and `assert_eq/assert_true/assert_nil` helpers (`assert.is_true(x)`→`assert_true(x)`, `assert.is_false(x)`→`assert_true(not x)`, `assert.same(a,b)`→deep-equal helper, `assert.equals`/`assert.near`→numeric checks, `assert.has_error(fn)`→`assert_true(not pcall(fn))`), add the run header and a final summary + `os.exit(failed>0 and 1 or 0)`. Alternative (lower effort): wire up plenary/busted (`PlenaryBustedFile`) — but the project has no such dependency configured, so conversion is the safer fix and restores real coverage.

### T2 (high) — `test_vault_fixes.lua` functional tests fail: harness never initializes the `vault_index` singleton (Phase 6 refactor)
- **File:line:** `tests/test_vault_fixes.lua:814` (Sections 14-16) and ~1996+ (Section 40, temporal)
- **Reproduced:** `nvim --headless -u NONE -l tests/test_vault_fixes.lua` → **134 passed, 47 failed, 181 total**. The functional index/executor/temporal sections fail with "…should be indexed/resolve (got falsy)".
- **Root cause:** After Phase 6, `query/index.lua:37` `build_from_vault_index()` reads `vault_index.current()` and only populates pages when `vi:is_ready()` (lines 43-53). The test calls `Index.new(tmp_vault):build_sync()` but **never** calls `vault_index.get(tmp_vault)`, so `current()` returns nil (`vault_index.lua:168` returns `M._instance`, nil until `get()`), `self.pages` stays empty (no error), and `get_page()` returns nil. The same gate breaks temporal: `wikilinks.lua` `resolve_link` returns early at lines 175-177 with "vault index not initialized" **before** reaching `resolve_temporal()` at line 183 when `current()==nil`. The test's own comment at line 1986 encodes the obsolete assumption ("resolve_link falls back to resolve_temporal when vault_index.current() is nil"), which Phase 6 removed. The tests predate the refactor.
- **Fix:** In the test setup, build the singleton before the functional sections: `local vault_index = require('andrew.vault.vault_index'); local vi = vault_index.get(tmp_vault); vi:build_sync()`. Caveat: a direct `vi:build_sync()` currently errors at `vault_index.lua:1292` ("table index is nil") during `_rebuild_name_index` in the isolated `-u NONE` setup (see §5 L4) — investigate/guard that path, or drive the build via the supported init flow. Minimal stop-gap for temporal tests: set `vault_index.get(vault)._ready = true`.

### T3 (medium) — `test_vault_fixes.lua` premise correction: modules DO load; failures are stale assertions
- **File:** `tests/test_vault_fixes.lua`
- **What's wrong:** A prior claim that "modules never load under `-u NONE`" is **refuted**. Under `-u NONE -l`, `package.path` includes the script's cwd (config root), so `require('andrew.vault.vault_index')` and `require('andrew.vault.query.index')` both return tables; the `parse_task_fields` (Section 13), `_parse_scalar` (Section 14), and inline-field/regex tests all PASS. The 47 failures split into two well-defined buckets: (a) functional tests needing the singleton (T2 above), and (b) brittle source-pattern string-match assertions against refactored code (see §5 L2).
- **Fix:** Do **not** touch `package.path`. (1) Initialize the singleton for functional tests (T2). (2) Update or delete the brittle `src:match(<exact code string>)` assertions that target code shapes refactored away.

### T4 (other/medium) — No CI / Makefile / aggregate test runner
- **File:** `/home/andrew-cmmg/.config/nvim`
- **What's wrong (confirmed):** No `Makefile`, no `.github/` workflows, no test-runner script (the only shell script is `scripts/generate-header-tags.sh`, unrelated). `AGENTS.md`'s "Build/Lint/Test Commands" documents only formatting/linting (stylua/ruff/etc.) with **no test invocation**. Each spec must be run manually one-by-one; there is no aggregate runner and no automated gate, so contributors easily miss regressions.
- **Fix:** Add `tests/run_all.lua` (or a Makefile `test` target / shell script) that loads and runs every `*_spec.lua`, aggregates pass/fail counts, and exits non-zero on failure — enabling a single command and a future CI hook.

### T5 (low) — `vault_index_snapshot_spec.lua` tests a divergent mock, not the real module
- **File:line:** `tests/vault_index_snapshot_spec.lua:113`
- **What's wrong:** The spec does **not** `require('andrew.vault.vault_index')`; it defines a local `VaultIndex` mock (lines 39-143) that "replicates the core algorithms." The mock has drifted: its `_apply_staged(staged, deleted, changed_rel_paths)` takes 3 params, while the real `M.VaultIndex:_apply_staged(staged, deleted, old_entries, changed_rel_paths, is_cold_start)` (`vault_index.lua:648`) takes 5 and contains summary-tree updates and derived-index rebuilds the mock omits. The 19 assertions pass but validate a copy that can silently diverge from production — false confidence about the most safety-critical part of the index (atomic apply, file_count accounting, generation invalidation). No runtime defect (the mock is internally consistent); a test-quality concern.
- **Fix:** Drive the test against the real module (construct a real `VaultIndex` with `config.index.use_snapshots` and call the actual `snapshot()`/`_apply_staged`), or add a guard that fails when the real signature/param-count drifts from the mock.

### Suite status (verified)
- All six self-contained specs **PASS, no errors**: `batch_drain_spec` (12/0), `lru_cache_spec` (28/0), `request_coalescer_spec` (26/0), `summary_tree_spec` (31/0), `vault_index_snapshot_spec` (19/0), `watch_channel_spec` (12/0).
- **Coverage gaps** (no runnable self-contained spec): `structural_sharing.lua` (production code, dead spec — T1); wikilink resolution + `link_utils.heading_to_slug` (core to navigation, pure and trivially testable); `embed.lua` classification helpers (`is_image_embed`, slug heading matching); `calendar.lua`/`tasks.lua` date bucketing + per-day dedup logic.

---

## 5. Low-Severity / Latent Items (brief)

- **L1 — `graph.lua:298`** (type, latent): self-reference filter `entry.path ~= buf_path` compares against nil, so the current note is only excluded by the name check; notes sharing the center path but differing in display name aren't stripped. Resolved by the H1 fix.
- **L2 — `test_vault_fixes.lua:437` et al.** (test, stale): many `src:match(<exact code string>)` assertions fail due to refactor drift, not regressions. Verified examples: Section 8 `completion uses while true do` (parser moved out); Section 9 `build_generation` (replaced by generation tracking, `completion_base.lua:181`); Section 10 frontmatter `math.min(...)` literal (behavior correct at `frontmatter.lua:19-21`); Section 11 `contains_value` (moved to a `values` module); Section 39 stats `M.setup` (now lazy via `init.lua:282-286`); `callout_folds` (moved to `event_dispatch.lua`/`callout_folds.lua`); collisions (moved to `vault_index_collisions.lua`); autolink/engine `schedule_update`. Feature present in every case — update or delete the brittle assertions.
- **L3 — `char_bag.lua:11`** (type, latent): bits at positions ≥32 (digits 6-9 → 2^32..2^35, `-_./#@` → 2^36..2^41) wrap under LuaJIT's 32-bit `bit.*` ops (`bit.tobit(2^36)==0`), aliasing to low bits (e.g. `'6'`→bit 0 same as `'a'`). The header comment's "52-bit mantissa" claim is wrong. Final results stay correct (query and candidate encode identically), but the `is_superset()` pre-filter loses discrimination → false positives, partially defeating the optimization.
- **L4 — `vault_index.lua:1292`** (other, observed): `vault_index.get(tmp):build_sync()` raised "table index is nil" during `_rebuild_name_index` in an isolated `-u NONE` run (after indexing 1 file). Not exercised by the failing tests (they go through `query.index`, which no-ops on a nil/not-ready singleton). May be a genuine latent nil-key-as-table-index bug or an artifact of the minimal setup — not fully isolated; medium confidence.
- **L5 — `themes/soft-paper.lua:151`** (type, cosmetic): the `dark` palette lacks `gutter_fg`/`gutter_cur_fg`/`gutter_cur_bg` (defined only in `light`, lines 36-38). Under `M.load('dark')`, `CursorLineNr`/`LineNr`/`LineNrAbove`/`LineNrBelow` get only `bold`, no fg. `nvim_set_hl` tolerates absent keys (no crash), but the line-number gutter loses its intended foreground in dark mode.
- **L6 — `vault_index_collisions.lua:181`, `:286`** (deprecation): two more `nvim_buf_add_highlight` sites (same family as §3); functional in 0.12.2, no removal.

---

## 6. Recommended Fix Order (highest impact first)

1. **H3 — `connections.lua:645`** — forward-declare `ensure_subscription`. *Entire connections public API crashes on every compute.* One-line fix.
2. **H1 + M1 + L1 — `graph.lua`** — declare `local buf_path = vim.api.nvim_buf_get_name(0)` at the top of `M.local_graph()`. *Fixes the multi-hop hard error (H1), the "Create note" crash (M1), and the self-reference filter (L1) in one change.*
3. **H2 — `embed.lua:1145`** — hoist `is_valid_current_buf` to module scope (or inline the 2-line check). *Restores embed rendering on the primary note-navigation path.*
4. **T2 — `test_vault_fixes.lua` setup** — initialize the `vault_index` singleton (`vault_index.get(tmp_vault):build_sync()`) for the functional sections; investigate/guard `vault_index.lua:1292` (L4) along the way. *Unblocks the 47 functional/temporal test failures.*
5. **M3 — `calendar.lua:127`** — forward-declare `_deadline_cache`, make line 147 a plain assignment, dot-call `invalidate`. *Removes a startup-race unhandled error.*
6. **M2 — `export.lua:133`** — add the `not content_lines` guard. *Removes a nil-deref on the unreadable-file race.*
7. **M4 — `terminal.lua:193-194`** — fix the `jobwait()[1] == -1` guard and use `jobstop`/`chanclose`. *Stops the shell-process leak and removes the deprecated `jobclose`.*
8. **T1 / T5 — test harness** — convert `structural_sharing_spec.lua` to the self-contained style (restores real coverage); point `vault_index_snapshot_spec.lua` at the real module or add a signature-drift guard.
9. **T4 — add `tests/run_all.lua`** (or Makefile `test` target) + a CI hook so the suite runs as one gated command.
10. **Deprecation sweep (§3 + L6)** — replace the ~11 `nvim_buf_add_highlight` sites with `nvim_buf_set_extmark`/`vim.hl.range`, the two `nvim_buf_set_option` sites with `nvim_set_option_value`/`vim.bo`, and clean up `jobclose`. *Non-urgent; batch as a single forward-compat PR (consider a shared highlight helper).*
11. **L3 / L5 — latent items** — fix `char_bag.lua` (use a non-bitop encoding or cap at 31 bits) and add the missing `dark`-palette gutter keys in `soft-paper.lua`. *Low priority; correctness/cosmetic.*
12. **Coverage** — add self-contained specs for `structural_sharing`, `link_utils.heading_to_slug`/wikilink resolution, `embed` classification helpers, and `calendar`/`tasks` date logic.
