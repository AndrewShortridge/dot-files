# Slice 1 — Tracer foundation: Span + Tracer + first call site + chrome consumer

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

The end-to-end tracer-bullet skeleton for the entire observability layer. After this slice, a developer can run `KSESSION_TRACE_DIR=/tmp/t ksession save x`, find a JSONL file in `/tmp/t/`, and visualise it in `chrome://tracing` or perfetto.dev.

Specifically:

- A new `src/perf/` module containing `Span`, `Tracer`, `Level`, the `perf::span!` declarative macro, and `perf::maybe_init()`. Activation is via the `KSESSION_TRACE_DIR` env var; absence means the macro expands to a no-op guarded by a single `OnceLock::get()` atomic load. Level filtering uses `KSESSION_TRACE_LEVEL` (default `info`).
- One initial span call site: `save.total` wrapping the entire `session::save()` orchestration entry. (Other call sites land in later slices — this one exists so Slice 1 has something to demo.)
- A new `src/cli/trace.rs` module wired into the existing clap dispatcher, with `show`, `stats`, `gc`, and `ls` subcommands **scaffolded as stubs** that exit with `"not yet implemented (slice N)"`. Only `show --format=chrome` is implemented in this slice (Slices 2/3/4 fill in the rest). Stubbing them now means later slices each touch one function in isolation.
- Wire format: one chrome-trace `X` event per line of JSONL. `ts` and `dur` in microseconds; `pid`/`tid` are real OS values; `name`, `args`, `parent_id` populated.
- Storage: `~/.cache/ksession/traces/<rfc3339-ts>-<save|restore>-<name>/rust-<pid>.jsonl`.

## Acceptance criteria

- [ ] `KSESSION_TRACE_DIR=/tmp/t ksession save <fixture>` writes a non-empty `rust-<pid>.jsonl` containing at least one `{"name":"save.total","ph":"X",...}` line with positive `dur`.
- [ ] Running `ksession save <fixture>` with `KSESSION_TRACE_DIR` unset creates **no** files under `~/.cache/ksession/traces/` and behaviour is byte-identical to today (smoke-tested via diffing the produced `.conf` + manifest).
- [ ] `ksession trace show /tmp/t --format=chrome > /tmp/t.json` produces a JSON document of the shape `{"traceEvents":[…]}` that perfetto.dev consumes without error.
- [ ] `ksession trace {stats,gc,ls}` invocations print a one-line `"not yet implemented (slice N)"` message and exit non-zero; this is intentional scaffolding.
- [ ] A new integration test `tests/perf_observability_smoke.rs` asserts the `KSESSION_TRACE_DIR`-set path produces JSONL with the expected event.
- [ ] A new integration test `tests/perf_off_is_zero_cost.rs` asserts the unset path writes nothing.
- [ ] No new third-party crates added to `Cargo.toml` (per ADR 0004).
- [ ] `perf::span!` cost when the tracer is uninitialised is one atomic load on `OnceLock::get()` — verified via reading the generated code, not a microbenchmark.
- [ ] `cargo test` (excluding `#[ignore]` tests) passes.

## Blocked by

None — can start immediately.
