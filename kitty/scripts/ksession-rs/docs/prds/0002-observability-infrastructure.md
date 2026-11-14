# PRD-0: Observability infrastructure for ksession-rs perf work

Status: ready-for-agent

## Problem Statement

The current perf budget enforcement in `tests/perf_save_budget.rs` is a
bespoke `Instant::now()` loop with hand-rolled percentile computation,
gated `#[ignore]`. It measures one thing — total `session::save()` wall
time on mocked I/O — and produces a pass/fail assertion. It cannot
answer questions like "where in this save did time go?", "is the kitty
RPC serializing under fan-out?", or "did the change in PR #N regress p95
on adapter.nvim.capture?".

Every PRD in the planned performance batch (PRD-2 through PRD-10) needs
to validate its own win in CI, in dev loops, and ideally on the user's
real machine. Without persistent observability, each PRD reinvents
instrumentation from scratch, the numbers cited in PR descriptions are
unreproducible, and regressions go silent until someone notices a save
felt slow.

The `restore` path is even worse: there is no measurement at all, no
budget, no per-phase visibility. Restore crosses process boundaries
(ksession-rs → kitty → `restore.sh` → nvim via `ksession_restore.lua`)
so any observability layer has to span those boundaries or it doesn't
cover the latency the user actually feels.

## Solution

Ship a minimal-dep perf observability layer (`src/perf/`) that emits
chrome-trace `X` (complete) events as JSONL, controlled entirely by
`KSESSION_TRACE_DIR` and `KSESSION_TRACE_LEVEL` env vars, with three
consumption surfaces exposed via a new `ksession trace` subcommand:

1. **Chrome-trace flame graph** for one-off deep dives (drop the merged
   JSON into perfetto.dev or `chrome://tracing`).
2. **Textual tree** for the dev loop ("did this change help?" in the
   terminal, no viewer required).
3. **Histograms** (p50/p95/p99 per span name across N historical runs)
   for "improvements over time" and CI regression gates.

The same span definitions feed all three consumers. Cross-process
tracing for restore uses sidecar JSONL files in the trace dir (one per
contributor process), merged on demand by `ksession trace show`.

Three additions outside the Rust binary:

- `restore.sh` template adds ~10 LOC of bash that, when
  `$KSESSION_TRACE_DIR` is set, emits one JSONL line per tmux command
  via `printf`. No-op when env var is unset.
- `ksession_restore.lua` adds ~15 LOC of lua that wraps each restore
  step in a `trace_span(name, args, fn)` helper. No-op when
  `KSESSION_TRACE_DIR` env var is unset.
- A "ready marker" — `<trace_dir>/ready/<contributor>` — is touched at
  the end of each cross-process contributor's work, used by tree-mode
  on restore to know when to harvest. Part of the artifact contract;
  emitted whether tracing is on or not.

The existing `tests/perf_save_budget.rs` transitions onto this infra:
its `Instant::now()` loop is replaced with reading the span histogram
for `save.total` from a one-shot trace dir; the budget assertions stay
unchanged.

## User Stories

1. As a developer landing a perf PRD, I want to set
   `KSESSION_TRACE_DIR=/tmp/before/ KSESSION_TRACE_LEVEL=trace ksession
   save x` once before my change and once after, then run
   `ksession trace stats save.capture.window --against /tmp/before/`,
   so that I can paste a verifiable p50/p95 delta into the PR
   description.

2. As a developer investigating a slow save, I want to run
   `ksession save x --trace=chrome` and have `~/.cache/ksession/traces/
   <ts>-save-x/chrome.json` dropped on disk so that I can open it in
   perfetto.dev and see exactly which span took the wall time.

3. As a developer running my normal dev loop, I want to add
   `--trace=tree` to a save invocation and see an indented breakdown
   of phases / windows / adapters / RPCs on stderr, so that I do not
   need a viewer to spot-check timings.

4. As a developer running CI, I want the `cargo test --release --test
   perf_save_budget` test to fail when p50 of `save.total` exceeds the
   budget, so that a regressing PR cannot land silently.

5. As a developer working on PRD-1, I want `ksession restore x
   --trace=tree` to block until all contributor processes (rust,
   per-tmux-restore.sh, per-nvim-ksession_restore.lua) have touched
   their ready markers, then print a unified tree, so that I get
   restore-side timing data with the same workflow as save.

6. As a user filing a "slow save" bug, I want `ksession trace gc` to
   keep my trace dir bounded so that the diagnostic logs do not grow
   unbounded on disk.

7. As a developer reading the source, I want every span call site to
   be obvious and grep-able (`perf::span!("name", k = v)`), so that I
   can audit what is and is not instrumented without chasing
   proc-macro magic.

8. As a developer porting an old `tracing::span!` mental model, I want
   the `perf::span!` macro to be no-op when `KSESSION_TRACE_DIR` is
   unset, so that production binaries pay nothing when tracing is off.

9. As a user with `KSESSION_TRACE_DIR` unset, I want bash
   `restore.sh` and lua `ksession_restore.lua` to skip every trace
   emission path so that restore latency is unchanged when tracing is
   off.

10. As the maintainer reading the resulting trace files months later,
    I want every span to use a stable, dotted, snake_case name like
    `save.capture.window`, `kitty.rpc.ls`, `nvim.rpc.mksession`, so
    that historical histograms remain comparable as the code evolves.

## Implementation Decisions

### Module layout

- `src/perf/` — new module.
  - `mod.rs` — public API: `span!()` macro, `Tracer`, `Span`,
    `maybe_init()`, `Level`.
  - `span.rs` — `Span` struct (`name: &'static str`, `start: Instant`,
    `pid: u32`, `tid: u64`, `span_id: u64`, `parent_id: u64`,
    `args: SmallVec<[(&'static str, String); 4]>`).
  - `tracer.rs` — `Tracer { file: Mutex<BufWriter<File>>, level: Level,
    next_id: AtomicU64 }`, stored in `static TRACER: OnceLock<Tracer>`.
  - `task_local.rs` — `tokio::task_local!` for the parent-id stack
    inside async tasks; explicit `Span::with_parent(id)` constructor
    for the `buffer_unordered(12)` fan-out boundary where each spawned
    future inherits the orchestration phase's id.

### Span call sites — L1 through L5

Instrumentation is placed at every boundary on the L1–L5 ladder.
Granularity is filtered at runtime via `KSESSION_TRACE_LEVEL`:

- `info` (default): L1–L2 active. Spans emit if their declared level
  is ≤ `info`.
- `debug`: L1–L4 active.
- `trace`: L1–L5 active.

Concrete span placement:

- **L1 phase spans** (`save.discover`, `save.tag_uuids`,
  `save.capture`, `save.sanitize`, `save.render`, `save.commit`,
  `restore.dispatch`) at the orchestration entry in
  `src/session/save.rs` and `src/session/restore.rs`. Level: `info`.
- **L2 per-window spans** (`save.capture.window`) wrapping each
  `capture_window` future at the `buffer_unordered` site. Args:
  `kitty_id`. Level: `info`. Parent id propagated explicitly via
  `Span::with_parent` to handle the spawn boundary.
- **L3 per-adapter spans** (`adapter.nvim.detect`,
  `adapter.nvim.capture`, etc.) at the `Adapter` trait dispatch in
  `src/adapter/registry.rs`. Level: `debug`.
- **L4 per-RPC spans** (`kitty.rpc.ls`, `kitty.rpc.get_text`,
  `nvim.rpc.mksession`, `nvim.rpc.buf_get_lines`, `tmux.cmd.list_panes`)
  inside each RPC client. Level: `debug`. Args include
  `bytes_out` / `bytes_in` so a histogram can correlate payload size
  with latency.
- **L5 per-socket-IO spans** (`kitty.rpc.ls.write_req`,
  `kitty.rpc.ls.read_resp`, `kitty.rpc.ls.decode`,
  `nvim.rpc.write_msgpack`, `nvim.rpc.read_msgpack`) bracketing
  individual socket reads/writes and serde steps in
  `src/kitty/rpc.rs` and `src/nvim_rpc/conn.rs`. Level: `trace`.

L6 (per-syscall) is **not** in this PRD's scope. The `fsx.commit_session`
span at L4 covers state-dir write+fsync+rename adequately; if a future
investigation needs syscall-level data the spans can be added then.

### `perf::span!` macro

```rust
// No-op when TRACER is uninit. Otherwise constructs a Span guard that
// drops at the end of the enclosing block.
let _s = perf::span!(Level::Info, "save.capture.window", kitty_id = id);
```

The macro expands to:

```rust
let _s = match perf::Tracer::current() {
    Some(t) if Level::Info <= t.level() => Some(perf::Span::new(
        "save.capture.window", &[("kitty_id", format!("{}", id))]
    )),
    _ => None,
};
```

Tested cost when disabled: one atomic load on `OnceLock::get()`. The
expanded `match` is dead-code-eliminated at the level check when the
Tracer is `None`.

### Output format — chrome-trace `X` events as JSONL

Each emitted line is one chrome-trace complete event:

```json
{"name":"save.capture.window","ph":"X","ts":1700000000000123,
 "dur":18342,"pid":12345,"tid":12345,"args":{"kitty_id":42}}
```

`ts` and `dur` are microseconds. `pid`/`tid` are real OS values to make
concurrent spans visible on separate lanes in perfetto. `args` carry
the call-site key=value attributes.

JSONL is chosen (one event per line) over a single JSON object because:
(a) appending is atomic and lock-free at the kernel-level on Linux
write(2) for lines under `PIPE_BUF`; (b) crashed processes leave a
truncated-but-parseable suffix line at worst, not a syntactically-broken
top-level array; (c) bash and lua emit one `printf`/`io.write` per span
trivially.

**Flush policy.** The `Tracer` lives in `static TRACER: OnceLock<Tracer>`;
statics' inner values are never dropped at process exit, so any
`BufWriter` buffered content would silently vanish. The implementation
flushes after every `write_all` call (per-line flush). The
`Mutex<BufWriter<File>>` shape is preserved for a future slice that adds
explicit `tracer_finalize()` with batched-then-fsync semantics, but the
default is correctness via flush-per-line. This also preserves the
kernel-level atomicity guarantee in (a) above — buffered writes that
never reach `write(2)` can't be atomic.

### Cross-process tracing

- **Rust side** writes to `<trace_dir>/rust-<pid>.jsonl`.
- **Bash `restore.sh`** template emits to
  `<trace_dir>/tmux-<sess>.jsonl` via a `__trace_run` helper:

  ```bash
  __trace_run() {  # name, args_json, cmd...
      [ -z "${KSESSION_TRACE_DIR-}" ] && { shift 2; "$@"; return $?; }
      local n=$1 a=$2; shift 2
      local t0=${EPOCHREALTIME/./}  # bash 5+: us-precision wall clock
      "$@"; local rc=$?
      printf '{"name":"%s","ph":"X","ts":%d,"dur":%d,"pid":%d,"tid":%d,"args":%s}\n' \
          "$n" "$t0" "$(( ${EPOCHREALTIME/./} - t0 ))" "$$" "$$" "${a:-{}}" \
          >> "$KSESSION_TRACE_DIR/tmux-$SESS.jsonl"
      return $rc
  }
  ```

  Every `tmux <subcmd>` line in the generated `restore.sh` wraps in
  `__trace_run "tmux.<subcmd>" '{}' tmux <subcmd> …`. Bash ≥ 5.0
  required for `EPOCHREALTIME` (no fork per call). Adopt the env-var
  test as the very first line of every emission helper so the
  trace-off path stays at one variable test per call (sub-microsecond).

- **Lua `ksession_restore.lua`** emits to
  `<trace_dir>/nvim-<pid>.jsonl` via `vim.uv.hrtime()` (no syscall on
  Linux) and `vim.json.encode`. No new lua deps.

### Ready marker

Each contributor process touches `<trace_dir>/ready/<contributor>` as
its final action:

- `restore.sh`: line immediately before `attach-session`, regardless of
  whether tracing is enabled (it is part of the artifact contract).
- `ksession_restore.lua`: in the final `VimEnter` autocmd in the
  chain, after the last buffer load.
- Rust on save: at `cli::save` exit, after the save line emits.

The marker is touched whether tracing is on or off so future tooling
(shell-prompt "session loaded" feedback, etc.) can reuse the signal.

`ksession restore --trace=tree` blocks on a counted set of expected
markers (from the manifest: count of tmux sessions + count of nvim
windows + always 1 for rust), with a default 30s timeout overridable
via `KSESSION_TRACE_READY_TIMEOUT_MS`. After all markers fire or
timeout, the JSONL bundle is harvested, merged, and rendered.

### `ksession trace` subcommand

```
ksession trace show <ts> [--format=chrome|tree|json]   # default: tree
ksession trace stats <name-glob> [--against <ts>]      # p50/p95/p99
ksession trace gc                                       # prune > 50 invocations
ksession trace ls                                       # list invocations
```

`<ts>` resolves to a unique trace dir under
`~/.cache/ksession/traces/`. Bare numeric prefix matches the most
recent dir with that prefix; `latest` resolves to the most recent dir
for the current `$USER`. Output of `show --format=chrome` is the
merged chrome-trace `traceEvents` array wrapped in `{"traceEvents":[…]}`,
written to stdout (pipe to a file or `xclip`); perfetto.dev consumes
directly.

`stats` aggregates all JSONL files matching the dir glob, filters by
span name (supports `*`), and computes the percentiles. `--against`
diffs two invocations and prints both numbers side by side with
delta-ms and delta-% per span name.

### `perf_save_budget` transition

The existing test transitions to:

```rust
#[tokio::test]
#[ignore = "performance benchmark - run manually with --ignored"]
async fn typical_workload_budget() {
    let trace_dir = tempdir().unwrap();
    std::env::set_var("KSESSION_TRACE_DIR", trace_dir.path());
    std::env::set_var("KSESSION_TRACE_LEVEL", "info");
    perf::maybe_init();
    for _ in 0..100 { run_save(&typical_fixture()).await.unwrap(); }
    drop(perf::tracer_finalize());

    let stats = perf::stats::summarise(trace_dir.path(), "save.total");
    assert!(stats.p50 <= 200, "p50 {}ms exceeds target 200ms", stats.p50);
}
```

The budget thresholds (200ms p50 typical, 500ms p95 heavy) stay
unchanged. The percentile-computation code moves into
`perf::stats::summarise` and is shared with the `ksession trace stats`
subcommand — one implementation, two consumers.

### Span naming convention

- Dotted, snake_case, hierarchical: `<area>.<subsystem>.<operation>`.
- Areas: `save`, `restore`, `adapter`, `kitty`, `nvim`, `tmux`, `fsx`,
  `proc`, `prompt`, `trace`.
- Per-instance variants (e.g., per-window, per-buffer) carry the
  identifier as an *arg*, not a baked-in span name. So `kitty_id=42`
  in args, not `save.capture.window.42` in the name. This is what
  makes histograms aggregate cleanly.

### Out of scope

- L6 per-syscall instrumentation. The state-dir commit (`fsx.commit_session`)
  is one L4 span, not three L6 spans.
- A Prometheus-style live metrics exporter. PRD-0 produces files on
  disk; a future PRD can layer a counters daemon if the use case
  ever materialises.
- The `tracing` crate. ADR 0004 records why.
- OpenTelemetry / W3C trace context propagation. The trace_id is a
  local convention (the trace dir path), not an inter-system header.
- Sampling. Every span emits when its level is active; no
  reservoir / probability sampler. The level filter is sufficient
  granularity for a single-user tool.

## Testing Decisions

A good test exercises the external behaviour: the on-disk JSONL shape,
the rendered tree output, the stats output, and the no-op-when-off
guarantee. Internal types like `Span`'s Drop ordering get tested
through the JSONL output, not by introspecting `Drop` directly.

### Modules to test directly

- **`perf::span!` macro** — golden table of `(env_set, level, span_level,
  expected_emit)` covering: off, info+info, info+debug (filtered out),
  trace+trace. Verifies the runtime gate.
- **`perf::stats::summarise`** — fixture JSONL with known timings,
  assert p50/p95/p99/mean/min/max. Pure function over file path.
- **`perf::tracer::write`** — concurrent emit from 12 tokio tasks;
  assert all 12 lines appear, each is valid JSON, no interleaving
  (lines stay atomic).
- **bash `__trace_run` helper** — shell test under `bash 5`: with
  `KSESSION_TRACE_DIR=/tmp/x`, run a stub command, assert one JSONL
  line in the file with the expected name and a positive `dur`. With
  `KSESSION_TRACE_DIR` unset, assert nothing written.
- **lua `trace_span` helper** — nvim headless test: same shape as the
  bash test.

### End-to-end tests to add

- **`perf_observability_smoke.rs`** — set `KSESSION_TRACE_DIR` to a
  tempdir; run one mocked save; assert `rust-<pid>.jsonl` exists,
  contains one `save.total` event with positive `dur`, and at least
  one `save.capture.window` event per fixture window.
- **`perf_off_is_zero_cost.rs`** — without `KSESSION_TRACE_DIR`, assert
  no files are created in `~/.cache/ksession/traces/` after a save,
  and the tracer init path's atomic-load instrumentation reports zero
  syscalls.
- **`perf_cross_process_restore.rs`** — set `KSESSION_TRACE_DIR`, run
  `ksession restore --trace=chrome` against a fixture session with
  one tmux pane and one nvim window, assert all three JSONL files
  appear, all three ready markers fire within 30s, and
  `ksession trace show --format=chrome` produces valid chrome-trace
  JSON with events from all three contributors.
- **`perf_save_budget.rs`** (transition) — assertions unchanged;
  measurement source moves to span histogram. Stays `#[ignore]`.

### Tests intentionally not added

- Span-on-panic semantics. Drop runs during unwind; we accept that
  spans interrupted by a panic emit with a partial `dur` measured at
  the unwind point. No special handling.
- Histogram correctness under contention. The single `Mutex<BufWriter>`
  serialises writes; correctness is by construction.

## Out of Scope

- Drafting PRD-1 through PRD-10. This PRD lands the foundation only.
- Migrating any existing logging (`tracing::warn!`, `eprintln!`) onto
  the perf layer. Logging and perf are separate concerns; perf spans
  carry no level / no message field. Logging stays where it is.
- Optimising the perf layer itself. The minimal-dep custom Span is
  designed to be cheap enough that no PRD targets it; if it ever
  becomes the bottleneck, that's a future investigation.
- Removing `tracing` from `Cargo.toml` if it is currently a transitive
  dep of any other crate. The perf layer is additive — it does not
  forbid `tracing` from existing elsewhere, only declines to use it
  directly.
- A `ksession doctor` subcommand that checks for tracing-related
  misconfiguration (e.g., bash < 5.0). The error path on bash 4 falls
  back to no-op trace emission with a one-line stderr warning when
  `KSESSION_TRACE_DIR` is set.

## Further Notes

- The choice of chrome-trace `X` events (rather than separate `B`
  begin / `E` end events) keeps the JSONL format atomic per span — one
  line, one event. Concurrent spans on separate threads remain
  distinguishable via `pid`/`tid`.
- The `parent_id` field is recorded but **not** part of the
  chrome-trace event spec — chrome trace infers parent-child purely
  from `ts`/`dur` overlap on the same `tid`. `parent_id` is included
  in the JSONL line so future custom tooling (e.g., a more aggressive
  textual tree renderer) can reconstruct the call graph across
  spawned tasks.
- Cross-references:
  - ADR 0004 — why `perf::Span` is hand-rolled not `tracing::Span`.
  - ADR 0005 — kitty RC connection pool (separate PRD, but its
    `kitty.rpc.*` spans are L4 instrumentation defined here).
  - ADR 0006 — kitty watcher (separate PRD, but its watcher-side
    instrumentation should emit JSONL into the same trace dir).
  - CONTEXT.md — Span, Trace, Ready marker, Kitty watcher.
  - RUST_PORT_PLAN.md §B.6 "Measurement methodology" — superseded.
    This PRD is the measurement methodology.
