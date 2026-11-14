# Slice 4 — `ksession trace gc` + `ksession trace ls` lifecycle commands

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

Implement the stubbed `gc` and `ls` subcommands from Slice 1.

`ksession trace ls`:
- Lists all trace directories under `~/.cache/ksession/traces/`.
- One row per directory, sorted by mtime desc.
- Columns: timestamp (parsed from dir name), kind (save|restore), session name, file count, total size on disk.

`ksession trace gc`:
- Sorts trace dirs by mtime asc; deletes everything beyond the newest 50.
- Defaults: keep newest 50; configurable via `--keep=N`.
- Prints one line per removed dir to stderr.
- Idempotent (a second invocation is a no-op).
- Also runs the same logic automatically at the start of every traced save/restore so the dir never grows unbounded without user action. (One sweep per invocation cap is fine; we don't need real-time pruning.)

## Acceptance criteria

- [ ] `ksession trace ls` prints a table of all trace dirs with the columns above; empty cache prints headers only.
- [ ] `ksession trace gc` reduces the cache to ≤ 50 entries; running again is a no-op.
- [ ] `ksession trace gc --keep=10` reduces to ≤ 10 entries.
- [ ] Auto-sweep at trace start: starting a 51st traced invocation removes the oldest entry before the new one is registered (verified by integration test that creates 51 fake trace dirs and asserts only 50 remain after one save).
- [ ] No new third-party crates.
- [ ] `cargo test` passes.

## Blocked by

- Slice 1 ([`01-tracer-foundation.md`](./01-tracer-foundation.md)).
