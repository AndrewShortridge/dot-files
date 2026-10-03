# Refactor — Tier-1 Test-Harness Extraction

## Overview

Tier-1 work extracted a shared test harness for the Neovim config specs, centralizing
the duplicated assertion and runner scaffolding in `tests/spec_helper.lua`. The helper
is loaded via the script-dir `dofile()` pattern so it works under both
`nvim --headless -u NONE -l tests/<spec>.lua` (cwd anywhere) and `run_all.lua`
(cwd = config root).

## What `tests/spec_helper.lua` Exposes

- **Core runner**: `M.test(name, fn)` — `pcall`-wraps a test, records pass/fail,
  prints `PASS:` / `FAIL:` lines.
- **Core assertions** (byte-identical semantics to the originals):
  - `M.assert_eq(got, expected, msg)`
  - `M.assert_true(val, msg)`
  - `M.assert_nil(val, msg)`
  - `M.assert_false(val, msg)`
  - `M.assert_match(s, pat, msg)`
- **Canonical deep equality**:
  - `M.deep_equal(a, b)` — recursive structural equality matching the
    js2lua / task_logic / search_query canonical form.
  - `M.assert_deep_eq(got, expected, msg)` — used by `js2lua_spec` and `task_logic_spec`.
  - Note: `behavioral_upgrades`, `templates`, and `ui_helpers` intentionally keep their
    **own** `deep_equal` (`ui_helpers` uses `vim.deep_equal`) and are **not** forced onto
    the canonical version.
- **Counter accessors**: `M.get_passed()`, `M.get_failed()`, `M.get_assertions()`,
  `M.get_errors()`.
- **`M.finish(opts)`** — prints the summary and exits, with configurable formatting/exit
  so each spec's original output and exit contract is preserved:
  - `opts.style`: `plain`, `results` (default), `dashes`, `results_assertions`, `total`.
  - `opts.exit`: `os` (default), `os_guard` (batch_drain / watch_channel),
    `cquit` (test_vault_fixes).
  - The `"%d passed, %d failed"` summary line is always emitted **last**, so
    `run_all.lua`'s last-match `gmatch` wins.

## Conversion Scope

- **19 specs** converted to the shared harness and wired into `run_all.lua`.
- Per-spec summary styles preserved: `plain` (batch_drain, watch_channel),
  `dashes` (request_coalescer), `results_assertions` (search_query),
  `total` (test_vault_fixes), and `results` for the remaining specs.

## Confirmation Status

- **Verification 1 (v1):** PASS
- **Verification 2 (v2):** PASS
- **End-to-end (ee):** PASS
- **Attempts:** 1 (passed on first attempt)

## Final `run_all` Aggregate

```
nvim --headless -u NONE -l tests/run_all.lua
=> "Total: 928 passed, 0 failed across 19 spec(s)" (run_all exit 0)
```

### Aggregate vs. 928-Baseline

| Metric  | Baseline | Final | Status |
| ------- | -------- | ----- | ------ |
| Passed  | 928      | 928   | Match  |
| Failed  | 0        | 0     | Match  |
| Specs   | 19       | 19    | Match  |

The final aggregate **matches the 928 baseline exactly** — 928 passed, 0 failed
across 19 specs, `run_all` exit 0.

## Per-Spec Breakdown

| Spec                      |  Passed |
| ------------------------- | ------: |
| batch_drain_spec          |      12 |
| behavioral_upgrades_spec  |      79 |
| calendar_dates_spec       |      28 |
| embed_helpers_spec        |      13 |
| graph_traversal_spec      |      24 |
| js2lua_spec               |      59 |
| link_maintenance_spec     |      23 |
| link_utils_spec           |      34 |
| lru_cache_spec            |      28 |
| request_coalescer_spec    |      26 |
| search_query_spec         |     119 |
| structural_sharing_spec   |      36 |
| summary_tree_spec         |      31 |
| task_logic_spec           |      90 |
| templates_spec            |      26 |
| test_vault_fixes          |     181 |
| ui_helpers_spec           |      87 |
| vault_index_snapshot_spec |      20 |
| watch_channel_spec        |      12 |
| **Total**                 | **928** |

All specs PASS, with 0 failed.
