# Slice 2 — `ksession trace stats` histogram subcommand

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

Implement the stubbed `ksession trace stats <name-glob>` subcommand scaffolded by Slice 1.

Behaviour:

- Scans `~/.cache/ksession/traces/*/` for JSONL files, parses every line, filters events whose `name` matches the glob (supports `*` wildcards).
- For matched events, computes min, max, mean, p50, p95, p99, count. Prints a table sorted by name, one row per matching span name.
- `--against <trace-dir-or-prefix>` enables diffing: prints two columns (baseline, current) plus delta-ms and delta-% per span name. Resolves the baseline argument the same way `show <ts>` does (bare numeric prefix, `latest`, or absolute path).
- The percentile-computation function lives in `src/perf/stats.rs` as `pub fn summarise(trace_dir: &Path, name_glob: &str) -> Stats` — this is the **same function** that Slice 8's `perf_save_budget` test will call. One implementation, two consumers.

Sample output (no `--against`):

```
span name                    count    p50      p95      p99      mean     min      max
save.total                   100      19.4ms   24.0ms   32.0ms   19.4ms   13.0ms   32.0ms
save.capture.window          1200     8.2ms    12.1ms   15.4ms   8.5ms    4.1ms    18.0ms
```

Sample output (with `--against /tmp/before/`):

```
span name                    baseline    current     delta
save.total                   19.4ms      14.2ms      -5.2ms (-27%)
save.capture.window          8.2ms       6.1ms       -2.1ms (-26%)
```

## Acceptance criteria

- [ ] `ksession trace stats save.total` prints a table with the columns above for at least one row.
- [ ] `ksession trace stats 'save.*'` returns multiple rows (one per distinct span name beginning with `save.`).
- [ ] `ksession trace stats save.total --against /tmp/before/` prints baseline + current + delta columns.
- [ ] `ksession trace stats <name>` against an empty trace dir prints no rows and exits zero (not an error — just empty).
- [ ] `perf::stats::summarise` is invocable from a Rust test (covered by tests added in Slice 8).
- [ ] Unit tests: golden fixture JSONL files with known timings; assert each percentile value to ±0.5 ms.
- [ ] No new third-party crates.
- [ ] `cargo test` passes.

## Blocked by

- Slice 1 ([`01-tracer-foundation.md`](./01-tracer-foundation.md)).
