# PRD-7: mimalloc as global allocator

Status: ready-for-agent
Depends on: PRD-0 (`0002-observability-infrastructure.md`)

## Problem Statement

ksession-rs uses the system allocator (glibc malloc on Linux). Plan
§B.5 evaluated alternatives and tagged mimalloc "MAYBE" with a
~0.5–1.5 ms estimated win, citing better small-allocation throughput
than glibc malloc and minimal dep cost (one crate, two lines of
code).

The "MAYBE" status was because the win could not be verified without
real measurements, which now exist via PRD-0. This PRD lands mimalloc
behind a one-PRD validation cycle: if PRD-0 histograms show a
measurable improvement on `save.total` p50, the change ships; if not,
it reverts.

## Solution

Add `mimalloc` as a dependency, set it as the global allocator, run
PRD-0's perf budget test before and after, decide based on the data.

```toml
[dependencies]
mimalloc = { version = "0.1", default-features = false }
```

```rust
// src/bin/ksession.rs
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;
```

`default-features = false` disables the bundled `secure` allocator
variant (a hardened mode with extra integrity checks that adds
overhead we don't want for a perf-targeted change).

## User Stories

1. As the maintainer, I want to verify that mimalloc actually wins on
   this workload before committing to a dep, so that the binary
   doesn't carry a crate that pays nothing.

2. As a kitty user, I want a measurable (even if small) reduction in
   save latency without introducing fragility, so that the
   incremental wins compound across the PRD batch.

3. As the maintainer reviewing the PR, I want a histogram diff
   (`ksession trace stats save.total --against <baseline>`) attached
   to the PR description, so that the win is paste-able and
   reproducible.

## Implementation Decisions

### Validation gate

Before merging:

1. Run `cargo test --release --test perf_save_budget -- --ignored
   --nocapture` on `main`. Save the resulting trace dir as
   `/tmp/before/`.
2. Apply the mimalloc patch; rebuild release.
3. Run the same test. Save trace dir as `/tmp/after/`.
4. Run `ksession trace stats save.total --against /tmp/before/` against
   `/tmp/after/`. Paste output into PR description.

**Merge condition:** `save.total` p50 delta is at least
**-0.5 ms** (the bottom of the plan's estimate). If the delta is
inside [-0.5 ms, +0.5 ms] or positive, the PR is closed without
merging — the dep is not paying for itself.

### What gets configured

- `default-features = false` on the mimalloc crate (disables secure
  mode and bundled-libc shims).
- No feature flags for "use mimalloc or not". The binary either uses
  it or doesn't; users don't get a runtime toggle.

### Binary size impact

mimalloc adds ~150 KiB to release binary size (verified from upstream
benchmarks; will be measured for real on this binary as part of the
validation gate and noted in the PR description). The release profile
already has `lto = "fat"` and `strip = "debuginfo"`, so dead-code
elimination removes anything we don't call.

### Out of scope

- `jemalloc`. Plan §B.5 evaluated it and tagged "SKIP" (likely
  negative on this workload). Not revisited.
- `mimalloc` v2. The v1 crate is mature and the v2 release adds
  features (heap profiling) we don't need.
- Custom allocator per subsystem (e.g., bump allocator for the
  per-save arena). Premature.

## Testing Decisions

The validation gate above is the test. No new unit tests; the
existing test suite continues to pass with mimalloc installed (any
test that relies on allocator-specific behaviour is already broken
and would not have passed under any sane allocator change).

### End-to-end tests to add

- **`tests/perf_save_budget_with_mimalloc.rs`** — this is
  `perf_save_budget.rs` itself; no new file. The transition was
  documented in PRD-0. After mimalloc lands, the existing test
  reflects the new allocator's performance automatically.

## Out of Scope

- Bisecting the win contribution across PRD batch. mimalloc lands or
  doesn't; the histogram diff is the deliverable.
- Documenting mimalloc anywhere user-facing. It's an internal dep.

## Further Notes

- This is the smallest PRD in the batch (~5 lines of substantive
  code). Its existence is justified by the validation gate, not the
  code change.
- Cross-references:
  - Plan §B.5 — "MAYBE" verdict.
  - PRD-0 — `save.total` p50 is the merge gate.
  - PRD-3, PRD-2, PRD-5 — likely land before this PRD; the baseline
    histogram for mimalloc validation should be after those.
