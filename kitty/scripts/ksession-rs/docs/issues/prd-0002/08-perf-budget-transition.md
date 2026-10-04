# Slice 8 — Transition `perf_save_budget` test onto histogram infrastructure

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

The current `tests/perf_save_budget.rs` measures via a bespoke `Instant::now()` loop with hand-rolled percentile computation. Replace it with the same infrastructure the rest of the project uses: spans emit, `perf::stats::summarise` aggregates, assertions run against the resulting histogram.

The behavioural contract of the test is **unchanged**:
- Same workloads (typical: 12 windows + 2 nvim + 1 tmux; heavy: 30 windows + 6 nvim + 2 tmux × 4 panes).
- Same iteration counts.
- Same budget thresholds (p50 ≤ 200ms typical; p95 ≤ 500ms heavy).
- Same `#[ignore]` gating (run manually with `--ignored`).

The implementation changes:
- Per-iteration timing is no longer hand-rolled; the `save.total` span (Slice 1) is the timing source.
- Percentile computation is no longer in the test file; the test calls `perf::stats::summarise(trace_dir, "save.total")` (Slice 2).
- The test sets `KSESSION_TRACE_DIR` to a tempdir for each invocation, runs the workload, then aggregates.

The 100-iteration single-process loop is preserved; we don't shell out to `ksession save` repeatedly. Tests call `session::save::save()` directly with the tracer initialised.

## Acceptance criteria

- [ ] `cargo test --release --test perf_save_budget -- --ignored --nocapture` passes with the same assertions firing on the same data shape as before this slice.
- [ ] The hand-rolled percentile code is removed from the test file.
- [ ] The test file's LOC drops by at least 50% (the bespoke loop + percentile math go away).
- [ ] If a regression is intentionally introduced (e.g., a `tokio::time::sleep(Duration::from_millis(50))` inserted into `session::save::discover`), the test fails with a meaningful assertion message that names the offending span.
- [ ] The trace dir used by each test invocation is cleaned up (tempdir Drop), not left behind in `~/.cache/ksession/traces/`.
- [ ] `cargo test` (non-`#[ignore]`) passes.

## Blocked by

- Slice 2 ([`02-trace-stats-subcommand.md`](./02-trace-stats-subcommand.md)) — needs `perf::stats::summarise`.
- Slice 5 ([`05-spans-L1-L2.md`](./05-spans-L1-L2.md)) — needs `save.total` and phase spans for the assertions to be meaningful.
