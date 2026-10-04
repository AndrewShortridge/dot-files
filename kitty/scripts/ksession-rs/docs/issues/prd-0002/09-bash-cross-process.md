# Slice 9 — Bash cross-process tracing for `restore.sh`

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

Extend the trace stream to bash. After this slice, a restore that exercises a `restore.sh` (i.e., any session with a tmux pane) produces a `<trace_dir>/tmux-<sess>.jsonl` containing one chrome-trace event per tmux command in the generated restore script.

Components:

- **`scripts/ksession-trace-lib.sh`** (new): shared bash library defining `__trace_run name args_json cmd...` and `__trace_emit name dur_us args_json`. Sourced by `restore.sh` (this slice) and later by `ksession-save-prompt.sh` (PRD-10).
  - First line of every helper tests `[ -z "${KSESSION_TRACE_DIR-}" ]`; if unset, the helper degenerates to running the command without tracing. Cost when off: one variable test (sub-microsecond).
  - Timestamping uses `${EPOCHREALTIME/./}` — bash ≥ 5.0 required for microsecond precision without forking. Falls back to no-op with a one-line stderr warning if bash version is too old.
- **`restore.sh` template** (in `src/tmux_rpc/restore_template.rs` or equivalent): every generated `tmux <subcmd>` line is wrapped with `__trace_run "tmux.<subcmd>" '{}'`.
  - The generated script begins with: `source "$(dirname "$0")/../../../ksession-trace-lib.sh"` (path resolution from the state dir; verify with a test).
  - The library is **shipped alongside the binary** via the Makefile (`install` target copies `scripts/ksession-trace-lib.sh` to `~/.local/share/ksession/`).

The JSONL line format matches the Rust side exactly (chrome-trace `X` event, one per line, `pid`/`tid` from `$$`). Cross-process merging at `ksession trace show` time concatenates all the JSONL files in the trace dir — no merging code changes needed.

## Acceptance criteria

- [ ] A new test `tests/bash_trace_smoke.sh` (or `.rs` invoking bash): with `KSESSION_TRACE_DIR=/tmp/t`, source `ksession-trace-lib.sh`, run `__trace_run 'tmux.fake' '{"x":1}' true`, assert `/tmp/t/tmux-*.jsonl` exists with one valid chrome-trace JSON line.
- [ ] Same test with `KSESSION_TRACE_DIR` unset: assert no file is created.
- [ ] An end-to-end test `tests/bash_trace_restore_integration.rs`: run a fixture restore with a tmux pane and `KSESSION_TRACE_DIR` set; assert the resulting trace dir contains a `tmux-<sess>.jsonl` with at least one event per tmux command in the generated script.
- [ ] Bash version detection: if `bash --version` returns < 5.0, the helper writes one stderr warning and emits no events. Restore still succeeds.
- [ ] `ksession trace show <ts> --format=chrome` (Slice 1) merges the bash-side JSONL alongside the rust-side and the resulting JSON loads in perfetto without errors.
- [ ] No new third-party crates.

## Blocked by

- Slice 1 ([`01-tracer-foundation.md`](./01-tracer-foundation.md)) — needs the JSONL format and trace-dir layout.
