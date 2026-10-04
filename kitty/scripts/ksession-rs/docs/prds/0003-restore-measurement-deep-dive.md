# PRD-1: Restore-path latency measurement deep-dive

Status: ready-for-agent
Depends on: PRD-0 (`0002-observability-infrastructure.md`)

## Problem Statement

Restore latency is unmeasured. The plan's §9/§B.1/§C.9 targets cover
save; there is no equivalent target, budget test, or instrumentation
for restore. The user feels restore as slow but we have no breakdown of
where the wall time goes — kitty's conf parser, kitty's launch-line
scheduler, per-`restore.sh` tmux replay, or per-nvim
`ksession_restore.lua` buffer reload. Any restore-side optimization PRD
drafted today is a guess.

This PRD ships no production code. It is a measurement exercise that
uses PRD-0's tracing infrastructure to produce a findings document
ranking restore-side holdups by milliseconds. PRDs 9..N (restore-side
optimizations) draft from that findings document.

## Solution

Run instrumented restores on the user's real saved sessions, varying
session shape (single window / multi-tab / heavy-tmux / heavy-nvim),
collect chrome-trace JSONL via PRD-0, and produce a findings doc:

1. **`docs/findings/restore-latency-baseline.md`** — committed artifact
   summarising the data. Includes a top-N ranked list of spans by p50
   contribution to restore wall time, per workload shape.
2. **`tests/perf_restore_baseline.rs`** — a `#[ignore]`-gated benchmark
   following the same pattern as the transitioned
   `tests/perf_save_budget.rs`, asserting the established baseline so
   future restore PRDs have a regression gate to point at.

Restore's "wall time" is defined as from `ksession restore <name>`
invocation to the last ready marker firing (see PRD-0 "Ready marker").
This includes kitty spawn, conf parse (opaque), launch-line execution
(partially opaque), per-`restore.sh` tmux command replay, and per-nvim
buffer reload.

## User Stories

1. As the maintainer drafting restore-side optimization PRDs, I want a
   ranked list of restore latency contributors so that I do not invest
   a week porting an optimization that turns out to be 3% of wall time.

2. As the maintainer reviewing a future restore PRD, I want to point
   at `tests/perf_restore_baseline.rs` and ask "does the histogram
   show the win you claimed?", so that PR review has a verifiable
   anchor.

3. As the maintainer investigating a slow restore six months from now,
   I want the findings doc to record the workload shapes that were
   measured (window count, tmux pane count, nvim buffer count), so
   that I can tell whether a current slowdown corresponds to a tested
   case or an untested one.

4. As the maintainer of this PRD's output, I want the findings doc to
   call out which contributors are *unmeasurable* (kitty internals,
   user-side terminal compositor) so that we do not draft a PRD
   targeting something we cannot fix from our side.

5. As the maintainer of PRD-3 / PRD-8 / etc., I want the baseline data
   to be runnable on demand (`cargo test --release --test
   perf_restore_baseline -- --ignored`) so that I can verify whether a
   save-side PRD inadvertently affected restore.

## Implementation Decisions

### Workload matrix

Five workload shapes captured from the user's existing sessions in
`~/.config/kitty/sessions/`:

- **W1 — Minimal**: 1 OS window, 1 tab, 1 kitty window, `Program::BareShell`.
  Floor for "spawn kitty + parse conf + launch one shell".
- **W2 — Multi-tab shell**: 1 OS window, 4 tabs, 1 kitty window each,
  all `BareShell`. Tests tab fan-out without adapter cost.
- **W3 — Heavy nvim**: 1 OS window, 1 tab, 1 kitty window running nvim
  with 8 buffers. Tests `ksession_restore.lua` cost.
- **W4 — Heavy tmux**: 1 OS window, 1 tab, 1 kitty window running tmux
  with 3 windows × 3 panes. Tests `restore.sh` serial replay cost.
- **W5 — Mixed realistic**: 2 OS windows, 3 tabs total, mix of
  nvim/tmux/shell. Closest to the user's daily workflow.

Each workload runs 30 iterations. First iteration of each batch is
warm-up and discarded; remaining 29 contribute to the histogram. All
five workloads are stored as fixture session dirs under
`tests/fixtures/restore-baseline/W{1..5}/` with their `.conf` and
gen-stamped state dir pre-built.

### What gets instrumented

PRD-0's L1–L5 ladder covers the Rust side. For restore we extend:

- **`session::restore`** — new `restore.dispatch` (L1) span wrapping
  the entire `cli::restore` handler, ending after the `Command::spawn`
  on kitty returns. Args: `name`, `conf_bytes`.
- **`restore.sweep_orphans`** (L2) — wrap the `fsx::sweep_orphans`
  call.
- **`restore.kitty_spawn`** (L2) — wrap the `Command::spawn` call;
  ends when the child process is handed off (immediately on detach;
  before `wait()` in tree-mode).
- **`tmux.cmd.<subcmd>` lines in `restore.sh`** — already instrumented
  per PRD-0's `__trace_run` helper.
- **`nvim.restore.<phase>` in `ksession_restore.lua`** — wrap each
  distinct phase of the lua restore (load_session, restore_buffers,
  restore_marks, etc.) in `trace_span`. **This is the largest new
  instrumentation surface and must enumerate phases concretely**:
  - `nvim.restore.source_session_vim`
  - `nvim.restore.load_modified_buffers`
  - `nvim.restore.restore_window_options`
  - `nvim.restore.fire_user_autocmds`

### Measurement harness

`tests/perf_restore_baseline.rs` is a `#[tokio::test]
#[ignore]`-gated benchmark structured like the transitioned
`perf_save_budget.rs`:

```rust
#[tokio::test]
#[ignore = "restore latency baseline - run manually with --ignored"]
async fn restore_baseline_w5_mixed() {
    let trace_dir = tempdir().unwrap();
    std::env::set_var("KSESSION_TRACE_DIR", trace_dir.path());
    std::env::set_var("KSESSION_TRACE_LEVEL", "trace");
    perf::maybe_init();
    for _ in 0..30 { run_restore(&fixture("W5_mixed")).await.unwrap(); }
    drop(perf::tracer_finalize());

    let report = perf::stats::summarise_all(trace_dir.path());
    report.write_markdown("docs/findings/restore-latency-baseline.md")?;
    // Assertions: baseline values plus 30% headroom.
    // Tightened later as PRDs 9..N land.
    assert!(report.span("restore.total").p50 <= BASELINE_W5_P50_MS * 130 / 100);
}
```

The 30%-headroom assertion is intentional. The baseline is **measured,
not designed** — the value of this PRD is producing the numbers, and
tightening regression budgets is downstream PRD work. The 30% slack
exists so the test does not become a tripwire that fails on natural
variance before any optimization PRD has even landed.

### What "restore is done" means

Tree-mode-on-restore blocks on ready markers (per PRD-0). For this
benchmark, "restore is done" is defined as **all expected ready
markers received within 30s**. Expected markers per workload are
computed from the fixture's `manifest.json`:

- Always 1 for the rust-side ready marker.
- One per tmux session present (counted via `Program::Tmux` entries).
- One per nvim window present (counted via `Program::Nvim` entries).
- Shell / less / raw windows do **not** contribute a ready marker —
  they have no good completion signal and are assumed instant for
  ready-marker purposes. Their actual completion time is captured via
  the kitty `launch` line bracket spans (see "Findings doc structure").

### Findings doc structure

`docs/findings/restore-latency-baseline.md` is the committed output.
Sections:

1. **Methodology** — workload matrix, iteration count, hardware /
   kitty version / nvim version / tmux version recorded at run time.
2. **Per-workload tables** — for each W1..W5, a table of (span name,
   p50_ms, p95_ms, count_per_iter, contribution_pct). Sorted by p50
   contribution desc. Top 5 highlighted.
3. **Cross-workload comparison** — which spans show up in all
   workloads (likely `restore.dispatch`, `restore.kitty_spawn`); which
   are workload-specific (`tmux.cmd.*`, `nvim.restore.*`).
4. **Unmeasurable contributors** — explicit list of latency we cannot
   instrument (kitty's internal conf parse, kitty's launch scheduler,
   terminal compositor rendering, font shaping). Plus the wall-time
   gap between `restore.kitty_spawn` end and the first downstream
   span fire — that gap is the kitty-internal cost and is reported as
   one aggregate number per workload.
5. **PRD-9..N candidates** — for each top-5 entry that *is*
   measurable, propose a candidate PRD title and rough approach. This
   section is the deliverable that unblocks restore optimization
   work.
6. **Raw data** — chrome-trace JSON files committed under
   `docs/findings/raw/restore-baseline/W{1..5}.json` for future
   inspection (kept under 1 MiB each via PRD-0's level filter — at
   `info` level the JSONL is small).

### Out of scope

- Tightening any threshold below the +30% headroom in
  `perf_restore_baseline.rs`. The baseline is a baseline.
- Instrumenting kitty itself. We do not own that code.
- Drafting any of PRDs 9..N — those are output of this PRD, not
  scope of it.
- A doctor-style "restore looks slow" diagnostic. PRD-0 makes the
  user's machine self-diagnose with `ksession restore foo
  --trace=tree`.

## Testing Decisions

This PRD's "tests" are themselves measurement tests, but they need
their own correctness verification:

- **`tests/perf_restore_baseline_fixtures.rs`** — assert that each
  fixture session under `tests/fixtures/restore-baseline/W{1..5}/`
  contains a valid `.conf` and `manifest.json` (parseable, schema=1,
  expected window count). Without this, a corrupted fixture would
  silently invalidate the baseline.
- **`tests/perf_restore_ready_marker_smoke.rs`** — run W1 (minimal)
  with tracing on; assert exactly one rust-side ready marker fires
  and tree-mode harvest completes within 5s. Catches regressions in
  the ready-marker contract itself.

### Tests intentionally not added

- Baseline-value assertions on individual span names. The findings
  doc is the artifact; the test enforces only "did total restore
  drift up by > 30%".

## Out of Scope

- Restore optimizations themselves (PRDs 9..N).
- Adding restore-side instrumentation beyond what is enumerated in
  "What gets instrumented". The L1–L5 ladder from PRD-0 covers the
  rest; if a finding shows we need deeper resolution in one phase,
  that is a follow-up.
- Cross-machine baseline normalisation. The findings doc records the
  user's hardware; comparing baselines across different machines is
  out of scope.

## Further Notes

- The +30% headroom in regression assertions is a deliberate
  one-decision parameter. If the user's restore latency drifts up by
  > 30% from baseline on the same machine, that is signal worth a
  warning. Tightening this requires understanding the natural variance
  envelope, which the findings doc itself reports (min/max/stddev
  across the 29 measurement iterations per workload).
- Cross-references:
  - PRD-0 — observability foundation; this PRD is its first consumer
    beyond the save budget transition.
  - ADR 0006 — kitty watcher; the proactive nvim cache PRD-8 will
    likely show up as the top candidate to break the
    `nvim.restore.source_session_vim` cost identified by this PRD.
  - CONTEXT.md — Span, Trace, Ready marker.
