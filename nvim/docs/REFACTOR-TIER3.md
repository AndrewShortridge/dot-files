# Refactor Tier-3 — Test Fixtures Extraction

## Goal

Extract the duplicated temp-vault scaffolding scattered across vault specs into a
single shared `tests/fixtures.lua` module, without changing any test behavior or
moving the suite total off its **928-test baseline**.

## What `tests/fixtures.lua` provides

A small, dependency-light module of **test-DATA builders** (temp-vault
scaffolding), kept deliberately separate from `tests/spec_helper.lua` (which owns
the `test()` / `assert_*` harness). It is loaded with the script-dir `dofile`
pattern so it works under both `nvim --headless -u NONE -l tests/<spec>.lua`
(any cwd) and `run_all.lua` (cwd = config root):

```lua
local _F = dofile((debug.getinfo(1,"S").source:gsub("^@",""):match("^(.*)[/\\]") or ".") .. "/fixtures.lua")
```

Builders:

- **`write_file(path, content)`** — write a string to an absolute path. Parent
  directory must already exist. Byte-identical to the prior local helpers in
  `graph_traversal_spec.lua` and `link_maintenance_spec.lua`.
- **`make_tmp_dir()`** — fresh temp directory (`vim.fn.tempname()` + `mkdir -p`).
  Mirrors the prior `link_maintenance_spec.make_tmp_dir`.
- **`make_temp_vault(files, opts)`** — create a temp vault dir and write
  `files` (relative name -> string content). Auto-creates parent dirs for nested
  names (e.g. `sub/Note.md`), making it a strict superset of both prior call
  patterns. Returns the absolute temp-vault path. It does **not** build a vault
  index or set `engine.vault_path` — callers own that, since the index handle and
  engine state are used differently per spec.

## Specs converted

The temp-vault file-writing helpers in these specs were replaced by the shared
builders:

- `graph_traversal_spec.lua` — local `write_file` → `fixtures.write_file`.
- `link_maintenance_spec.lua` — local `make_tmp_dir` / `write_file` →
  `fixtures.make_tmp_dir` / `fixtures.write_file`.

## Intentionally left alone

`fixtures.lua` deliberately does **not** provide a synthetic
"index / entry" builder. The three specs that build in-memory indexes/entries use
structurally different, non-reconcilable shapes, so they keep their own local
builders:

- `search_query_spec.lua` — `make_entry`
- `graph_traversal_spec.lua` — `stub_idx` / `make_resolver_stub`
- `behavioral_upgrades_spec.lua` — `make_mock_index`

`fixtures.lua` is **not** a `*_spec.lua` file, so `run_all.lua` does not auto-run
it; the suite stays at **19 specs**.

## Confirmation status

| Check | Result |
| --- | --- |
| Attempts | **1** (first pass) |
| Verbatim-pass v1 | PASS |
| Verbatim-pass v2 | PASS |
| Edge/error pass | PASS |
| Suite run | 928 passed, 0 failed, 19 specs |
| Per-spec run | 928 passed, 0 failed, 19 specs |

## Final `run_all` aggregate vs 928-baseline

**928 passed, 0 failed across 19 specs — EXACT baseline match.** Every per-spec
count matches the baseline exactly:

| Spec | Tests |
| --- | --- |
| batch_drain_spec | 12 |
| behavioral_upgrades_spec | 79 |
| calendar_dates_spec | 28 |
| embed_helpers_spec | 13 |
| graph_traversal_spec | 24 |
| js2lua_spec | 59 |
| link_maintenance_spec | 23 |
| link_utils_spec | 34 |
| lru_cache_spec | 28 |
| request_coalescer_spec | 26 |
| search_query_spec | 119 |
| structural_sharing_spec | 36 |
| summary_tree_spec | 31 |
| task_logic_spec | 90 |
| templates_spec | 26 |
| test_vault_fixes | 181 |
| ui_helpers_spec | 87 |
| vault_index_snapshot_spec | 20 |
| watch_channel_spec | 12 |
| **Total** | **928** |
