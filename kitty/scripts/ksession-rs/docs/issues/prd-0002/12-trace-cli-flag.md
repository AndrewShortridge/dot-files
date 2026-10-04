# Slice 12 — `--trace={chrome,tree,off}` CLI flag on save / restore

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

The user-facing capstone. Before this slice, tracing is enabled by setting `KSESSION_TRACE_DIR` manually; that's fine for dev loops but clunky for daily use. Add a `--trace=<format>` flag to `ksession save` and `ksession restore` that resolves the trace dir automatically and dispatches output to the requested consumer.

Behaviour:

- `--trace=off` (default): unchanged behaviour. No tracing.
- `--trace=chrome`: sets `KSESSION_TRACE_DIR=~/.cache/ksession/traces/<rfc3339-ts>-<save|restore>-<name>/` and `KSESSION_TRACE_LEVEL=trace`. Runs the operation. On completion, runs the equivalent of `ksession trace show <ts> --format=chrome` and writes the merged JSON to `<trace_dir>/chrome.json`. Prints the file path to stderr at exit.
- `--trace=tree`: same env-var setup as `chrome`. After completion, runs `ksession trace show <ts> --format=tree` and prints to stderr.

For `restore --trace=tree` specifically: the Rust binary normally detaches via `kitty --detach`. In tree mode it cannot — there's no terminal to print to once it detaches. So `--trace=tree` on restore:
- Calls `kitty --session <conf>` **without** `--detach`.
- Blocks via `perf::ready::wait_for_all` (Slice 11) until the expected number of ready markers fire.
- Once unblocked, harvests the JSONL files, renders the tree, prints to stderr.
- Exits.

For `restore --trace=chrome`: same as today (detach), but ksession-rs writes the merged chrome.json to the trace dir as a final action via a small fire-and-forget process. The user opens it whenever they want.

`--trace=tree` also implicitly sets `KSESSION_TRACE_LEVEL` to whatever value the env had — letting `KSESSION_TRACE_LEVEL=debug ksession save x --trace=tree` produce a debug-level tree without re-typing the env var.

## Acceptance criteria

- [ ] `ksession save <fixture> --trace=tree` prints an indented span tree to stderr and exits zero.
- [ ] `ksession save <fixture> --trace=chrome` writes `<trace_dir>/chrome.json` (loadable by perfetto.dev) and prints the path to stderr.
- [ ] `ksession save <fixture>` (no flag) is byte-identical in output / artifacts / exit code to today.
- [ ] `ksession restore <fixture> --trace=tree` blocks until all ready markers fire (within 30s timeout) and prints the unified tree to stderr.
- [ ] `ksession restore <fixture> --trace=tree --timeout=5s` (or env var `KSESSION_TRACE_READY_TIMEOUT_MS=5000`) respects the timeout; if a marker doesn't fire, it prints what was collected plus a "missing markers: nvim-1234" warning.
- [ ] `ksession restore <fixture> --trace=chrome` returns immediately (detach) and a `chrome.json` appears in the trace dir within a few seconds.
- [ ] `--trace=off` is the default; specifying no flag is equivalent.
- [ ] Setting `KSESSION_TRACE_DIR` manually while also passing `--trace=tree` warns but respects the user's env var (theirs wins, the flag adjusts level/output mode only).
- [ ] All earlier slices' integration tests continue to pass; this slice is purely additive on the CLI surface.

## Blocked by

- Slice 3 ([`03-trace-show-tree.md`](./03-trace-show-tree.md)) — needs tree formatter.
- Slice 11 ([`11-ready-marker.md`](./11-ready-marker.md)) — needs `wait_for_all`.
