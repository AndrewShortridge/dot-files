# PRD-5: `ProcCache` memoization of `/proc/<pid>/...` reads within one save

Status: ready-for-agent
Depends on: PRD-0 (`0002-observability-infrastructure.md`)

## Problem Statement

Several adapters and orchestration phases independently read the same
`/proc/<pid>/...` files. A single nvim window's capture may read
`/proc/<fg_pid>/exe`, `/proc/<fg_pid>/cmdline`, `/proc/<fg_pid>/cwd`,
and `/proc/<fg_pid>/environ`; later, `session::save::resolve_target_program`
re-walks descendants and re-reads the same files. Plan §B.4 calls this
out as a "DO" with ~5–10 ms estimated win on the typical 12-window
workload — the win compounds because every adapter's `detect()` is
also called on every window.

The OSC 1337 shell hook (plan §C.2, already shipped) reduces the
problem for shell windows by caching shell state in kitty's user-vars
dict, but `/proc` reads remain for non-shell programs (nvim, tmux,
less, raw) and for the orchestrator's descendant-walk
(`session::save::resolve_target_program`).

## Solution

Implement `proc::ProcCache` — a per-save memoization layer that
deduplicates reads by `(pid, field)`. Threaded through `SharedCtx`,
accessed by every adapter via `ctx.proc.read(pid, ProcField::Cmdline)`
instead of `proc::cmdline(pid)`. Backing storage is an
`Arc<DashMap<(u32, ProcField), Result<Arc<[u8]>, Arc<KError>>>>`; first
read populates, subsequent reads return cached bytes.

PRD-0's spans validate the win: `proc.read{pid,field}` L4 spans appear
once per unique `(pid, field)` tuple per save instead of many times.
Histogram for cumulative `proc.read.*` p50 drops measurably.

## User Stories

1. As a kitty user with 12 windows, I want each window's `/proc/<pid>/exe`
   read to happen at most once across the save (not once per
   adapter's `detect()` call × N adapters), so that adapter dispatch
   does not pay redundant syscalls.

2. As the maintainer reviewing this PRD, I want PRD-0's `proc.read.*`
   cumulative-count metric per save to show a measurable reduction
   (target: 50–70% fewer reads), so that the optimisation's mechanism
   is verifiable.

3. As a kitty user whose `/proc/<pid>/...` read fails (process exited
   between detection and capture), I want the cached error to surface
   consistently across all subsequent callers in the same save, so
   that one adapter doesn't see "exited" while another races and
   sees garbage.

4. As the maintainer, I want the cache to be **per-save** (not
   process-global), so that two consecutive `ksession save` runs in
   the same process (if that ever happens, e.g., in tests) don't
   cross-contaminate.

## Implementation Decisions

### Module layout

- `src/proc/cache.rs` — new file.
  - `ProcField` enum: `Cmdline`, `Exe`, `Environ`, `Cwd`, `Stat`,
    `Status`, `Children(taskid_or_self)`. One variant per discrete
    file we read.
  - `ProcCache { entries: DashMap<(u32, ProcField), Result<Arc<[u8]>,
    Arc<KError>>>, proc_root: PathBuf }`.
  - `pub async fn read(&self, pid: u32, field: ProcField) -> Result<Arc<[u8]>, Arc<KError>>`.
- `src/proc/mod.rs` — existing helpers (`cmdline`, `exe`, etc.)
  retained as free functions but rewritten to take `&ProcCache`. The
  bare functions without a cache stay available for paths that don't
  have a SharedCtx (tests, doctor-style probes).
- `src/session/save.rs` — `SharedCtx.proc: Arc<ProcCache>` initialised
  at save start.
- Every adapter's `detect()` and `capture()` takes `&ProcCache` (via
  `WindowCtx`) and calls `ctx.proc.read(...)` instead of bare
  `proc::cmdline(pid)`.

### Cache key and value

- Key: `(u32 pid, ProcField field)`. PIDs may be reused across
  generations but never within a single save (PIDs are stable for the
  lifetime of a save invocation — the OS will not reassign a PID we
  just resolved).
- Value: `Result<Arc<[u8]>, Arc<KError>>`. Wrapping in `Arc` lets
  multiple callers share the same bytes without re-cloning. Errors
  are cached identically — repeated reads of an already-gone process
  see the cached error.

### Concurrent access

`DashMap` over `HashMap<Mutex<...>>` to avoid contention under
`buffer_unordered(12)`. `read()` follows the get-or-insert pattern:

```rust
pub async fn read(&self, pid: u32, field: ProcField) -> Result<Arc<[u8]>, Arc<KError>> {
    let _s = perf::span!(Level::Debug, "proc.read", pid = pid, field = ?field);
    if let Some(entry) = self.entries.get(&(pid, field)) {
        return entry.clone();
    }
    let _s = perf::span!(Level::Trace, "proc.read.miss");
    let bytes = read_proc_file(&self.proc_root, pid, field).await
        .map(Arc::from)
        .map_err(Arc::new);
    self.entries.insert((pid, field), bytes.clone());
    bytes
}
```

The hit-path L4 span has no inner L5 span; the miss-path adds a
`proc.read.miss` L5 span so histograms distinguish cache-hit cost
(near-zero) from miss cost (one read syscall plus parsing).

A small race exists: two concurrent callers can both insert the same
entry. Both produce the same answer (idempotent reads of `/proc`), so
the second insert silently overwrites with identical bytes — no
correctness issue, marginal redundant syscall in the race window.

### Lifecycle

- Created at save start in `cli::save`, dropped at save end.
- Never persisted across saves.
- Test code constructs a `ProcCache::with_proc_root(&Path)` for
  fixture-filesystem tests (consistent with existing `proc::*` helpers
  that accept a `proc_root` per plan §5.2).

### Span instrumentation

- L4: `proc.read` per call with `pid`, `field` args. Cumulative count
  per save is the regression-tracking metric.
- L5: `proc.read.miss` when bytes are actually read from `/proc`.

### Out of scope

- Cross-save persistence. The OSC 1337 user-vars approach (plan §C.2)
  is the right primitive for cross-save state caching; `/proc` reads
  are ephemeral by nature.
- Cache invalidation. Within a save, `/proc` reads are atomic snapshots
  and don't need invalidation. Across saves, the cache is rebuilt.
- Caching `/proc/<pid>/task/<tid>/children` walks beyond the leaf
  file. The descendant-walk algorithm in `proc::descendants` is
  already efficient (plan §5.2); we cache the leaf reads it issues,
  not its traversal output.
- Inotify-driven invalidation. Overkill for a within-save cache.

## Testing Decisions

A good test verifies the dedup behaviour and the cached-error
semantics without poking the live `/proc`.

### Modules to test directly

- **`ProcCache::read` dedup** — fixture proc_root with one
  `<pid>/cmdline` file; call `read(pid, Cmdline)` twice from two
  concurrent tokio tasks; assert the underlying file read happens
  exactly once (instrument via a side-channel counter or via the
  `proc.read.miss` span count).
- **`ProcCache::read` error cached** — fixture proc_root with no
  `<pid>/cmdline` (file missing); call `read` three times; assert
  three identical `KError::ProcRead` results and that the disk read
  happened exactly once.
- **Different fields per same pid don't collide** — populate
  `<pid>/cmdline` and `<pid>/exe`; assert two separate cache entries.

### End-to-end tests to add

- **`proc_cache_save_dedup.rs`** — set `KSESSION_TRACE_DIR`, run a
  save with a multi-window fixture, parse the JSONL trace, assert
  cumulative `proc.read` count is bounded by `unique_pids ×
  unique_fields` (not `total_adapter_calls × fields`).
- **`proc_cache_perf_budget.rs`** — `#[ignore]` benchmark, 30 iters
  of the typical workload, assert cumulative `proc.read` cost
  contributes ≤ 5 ms per save at p50.

### Existing tests that must keep passing

- All `proc::*` direct-function unit tests (the bare helpers still
  exist for the fixture-filesystem test pattern).

## Out of Scope

- Caching `kitty @ ls` output. That's the kitty-RC layer; `ProcCache`
  is `/proc` only.
- Memoising filesystem ops beyond `/proc` (e.g., `~/.config/kitty/`
  reads). Different access patterns; not the same dedup win.

## Further Notes

- Plan §B.4 estimates ~5–10 ms, "smaller after C.2". With the OSC
  1337 hook already shipping, the saved cost is concentrated on
  non-shell windows (nvim/tmux/less/raw). The PRD-0 histogram will
  show whether the win materialises on the user's actual workload.
- Cross-references:
  - Plan §B.4 — original "DO".
  - Plan §C.2 — OSC 1337 hook (the complementary optimisation that
    reduced this PRD's expected win).
  - PRD-0 — `proc.read.*` L4/L5 spans.
