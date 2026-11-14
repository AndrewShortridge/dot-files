# Slice 9 — Perf budget benchmarks

## Parent

[`docs/prds/0013-scrollback-replay-and-per-window-history.md`](../../prds/0013-scrollback-replay-and-per-window-history.md) — PRD-13, Perf budget tests.

## What to build

Three `#[ignore]` benchmark tests that validate the new PRD-13 components stay within their perf budgets. These follow the existing `perf_*.rs` naming convention and use the span-based measurement pattern established by PRD-0.

### Benchmark 1: `perf_scrollback_wrap_budget.rs`

Render a `.conf` with 12 shell windows, each having a `Program::Shell.scrollback` pointing to a 50 KiB file path. Measure the `conf.render` span p50 with and without scrollback fields populated. Assert the delta is ≤ 5 ms.

The budget validates that scrollback wrapping is pure string manipulation (inserting a `cat` command into the launch line) and doesn't accidentally read file contents during rendering.

### Benchmark 2: `perf_history_copy_budget.rs`

Create 12 mock history files (each ~10 KiB) in a temp `~/.cache/ksession/hist/` directory. Run the shell adapter's history copy logic for 12 windows. Measure cumulative `save.capture.history_copy` span p50. Assert ≤ 10 ms.

The budget validates that `std::fs::copy()` overhead stays bounded for typical workloads.

### Benchmark 3: `perf_tmux_scrollback_codegen_budget.rs`

Generate `restore.sh` for a 3-window × 3-pane tmux session with scrollback files. Measure codegen time p50 with and without scrollback replay lines. Assert the delta is ≤ 2 ms.

The budget validates that the codegen addition is pure string emission with no file I/O.

All three benchmarks run 30 iterations (first discarded) to establish stable p50 values. They are marked `#[ignore]` so they don't run in the default `cargo test` pass — invoked explicitly via `cargo test -- --ignored` or the Makefile's `bench` target.

## Acceptance criteria

- [ ] `perf_scrollback_wrap_budget.rs` exists, is `#[ignore]`, measures conf rendering with/without scrollback, asserts delta ≤ 5 ms.
- [ ] `perf_history_copy_budget.rs` exists, is `#[ignore]`, measures 12-file copy, asserts cumulative p50 ≤ 10 ms.
- [ ] `perf_tmux_scrollback_codegen_budget.rs` exists, is `#[ignore]`, measures restore.sh codegen with/without pane replay, asserts delta ≤ 2 ms.
- [ ] Each benchmark runs 30 iterations with the first discarded.
- [ ] Benchmarks use `KSESSION_TRACE_DIR` to collect span data and read back p50 via the existing stats infrastructure.
- [ ] All three pass on the development machine under typical load.
- [ ] `cargo test` (without `--ignored`) does not run these benchmarks.
- [ ] Test file names follow the `perf_*.rs` naming convention established in the project.

## Blocked by

- Slice 3 (`03-patcher-scrollback-wrapping.md`) — scrollback wrapping must exist to benchmark.
- Slice 4 (`04-shell-adapter-history-capture.md`) — history copy must exist to benchmark.
- Slice 6 (`06-tmux-pane-scrollback-replay.md`) — tmux codegen replay must exist to benchmark.
