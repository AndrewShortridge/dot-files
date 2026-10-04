# PRD-4: Pre-spawn `kitty @ ls` during `main()` startup

Status: merged-into-0005
Depends on: PRD-0 (`0002-observability-infrastructure.md`)

> **Merged into PRD-3** (`docs/prds/0005-kitty-rc-connection-pool.md`).
> PRD-4's pre-spawn requires a second socket connection to fire the skeleton call concurrently with `kitty @ ls`, which is exactly what PRD-3's connection pool provides. Rather than building a single-connection pre-spawn here and then rebuilding it for the pool, both scopes are combined: the pool is pre-spawned in `main()` via `discover_and_warm()`, and the three-way `tokio::join!` that parallelizes ls + skeleton + version is documented in PRD-3's updated design. ADR 0005 (connection pool rationale) covers both the pooling and the pre-spawn decisions.

---

*The content below is preserved as historical context. This PRD is no longer independently implementable.*

## Problem Statement

Plan §B.5 calls out a small but real win: kick off the `kitty @ ls`
request (or its direct DCS-socket equivalent) at the earliest possible
moment in `main()`, before CLI argument parsing and pre-save setup, so
its ~5–15 ms of socket round-trip latency overlaps with our own
initialisation rather than serialising in front of `session::save`'s
discover phase. The plan estimated ~10 ms win on the typical save.

The optimisation is straightforward; what it has been blocked on is
verification. Without PRD-0's histograms, we cannot tell whether the
~10 ms is real on the user's machine or noise dominated by other
variance. PRD-0 makes the win visible.

## Solution

Spawn the kitty RPC `ls` call in a fire-and-forget tokio task at the
top of `main()`, immediately after the global tracer is initialised
(so the span shows up in traces). Store the resulting
`JoinHandle<Result<Ls>>` in a thread-local or pass it through to
`cli::save`. Inside `session::save::discover`, instead of issuing the
`ls` call there, `await` the pre-existing JoinHandle. If the handle
was never claimed (subcommand was `list`/`show`/`rm`/`restore`),
abort the task on shutdown.

PRD-0's `save.discover` L1 span should show a drop of ~5–15 ms p50
when measured before and after.

## User Stories

1. As a kitty user invoking `ksession save foo`, I want the kitty
   RPC `ls` call to start before clap finishes parsing argv, so that
   its ~10 ms wall time overlaps with our setup.

2. As the maintainer verifying this PRD's win, I want PRD-0's
   `save.discover` p50 histogram to drop measurably between before
   and after, so that I can paste a verifiable delta into the PR.

3. As a kitty user invoking `ksession list` or `ksession show <name>`
   (which do no RPC), I want the pre-spawned `ls` task to be cleanly
   cancelled / not block process exit, so that read-only subcommands
   stay fast.

4. As a kitty user with no `listen_on` set (kitty RC misconfigured),
   I want the pre-spawned `ls` to surface its error at the normal
   point (inside `session::save::discover`) with the same error
   message users see today, so that diagnostics don't regress.

## Implementation Decisions

### Where the pre-spawn lives

`src/bin/ksession.rs` `fn main()` runs the following in order:

1. `perf::maybe_init()` (PRD-0).
2. Inspect `argv[1]` directly (raw, before clap) to decide whether to
   pre-spawn. Only pre-spawn when `argv[1] == "save"`. Other
   subcommands skip the pre-spawn entirely.
3. If pre-spawning: `let ls_handle = tokio::spawn(async move {
     KittyPool::for_default_listen_on().acquire().await.ls().await
   });` Store on a `OnceLock<JoinHandle<...>>` or pass through as a
   constructor arg to `cli::save`.
4. Continue with normal clap parsing, dispatch, etc.

The cheap `argv[1]` peek (no clap dependency) avoids paying the
pre-spawn cost on read-only paths. Done with `std::env::args_os().nth(1)`
which is sub-microsecond.

### Joining

`session::save::discover` is rewritten:

```rust
pub async fn discover(ctx: &SharedCtx, ls_handle: Option<JoinHandle<Result<Ls>>>) -> Result<Ls> {
    let _s = perf::span!(Level::Info, "save.discover");
    match ls_handle {
        Some(h) => {
            let _s = perf::span!(Level::Debug, "save.discover.await_prespawn");
            h.await.map_err(KError::from)?
        }
        None => {
            let _s = perf::span!(Level::Debug, "save.discover.live");
            ctx.kitty.ls().await
        }
    }
}
```

The `await_prespawn` vs `live` span distinction lets the histogram
show whether the pre-spawn actually arrived before the await point.
If `await_prespawn` p50 is ~0 ms, the optimisation worked; if it's
close to `live`'s old p50, the pre-spawn isn't starting early enough
and the PRD's design has a bug.

### Cancellation on read-only paths

A `Drop` guard on the `OnceLock<JoinHandle<...>>` aborts the task on
process exit. Aborting an in-flight kitty RPC is safe — kitty's
server side just sees the connection close and discards the
half-issued request.

### Configuration discovery before clap

The pre-spawn needs to know `listen_on` to dial. Resolution order:

1. `KITTY_LISTEN_ON` env var (kitty auto-exports it for child
   processes — present in every normal invocation from a kitty
   keybind).
2. `$XDG_RUNTIME_DIR/kitty.sock` (kitty's default `listen_on` value
   when configured to a path).
3. `$HOME/.config/kitty/kitty.sock` (a less-common configured path).
4. None — pre-spawn skips with a `trace!` log, save falls back to
   `live` path.

Resolution is sub-millisecond.

### Out of scope

- Pre-spawning anything other than `ls` (e.g., `kitty --version`).
  Version is already parallelised inside `discover` and is short.
- Pre-spawning across non-save subcommands. The `argv[1]` check
  scopes the optimisation to its only beneficiary.
- Eliminating the pre-spawn fallback path. If the env var is unset
  the live path runs; we do not error.

## Testing Decisions

### Modules to test directly

- **argv peek logic** — unit test: `should_prespawn(&["ksession",
  "save", "foo"])` returns true; `should_prespawn(&["ksession",
  "list"])` returns false; `should_prespawn(&["ksession"])` (no
  subcommand) returns false.

### End-to-end tests to add

- **`prespawn_overlap_smoke.rs`** — set `KSESSION_TRACE_DIR`, run
  `ksession save foo` against the test kitty, assert
  `save.discover.await_prespawn` span appears in the trace and its
  `dur` is less than the historical `save.discover.live` value (which
  the test computes by also running with pre-spawn disabled via env
  override).
- **`prespawn_cancellation.rs`** — run `ksession list`, assert the
  pre-spawn JoinHandle was created and aborted (visible in trace as
  a `save.prespawn.aborted` event), assert process exits cleanly
  within 50 ms.
- **`prespawn_no_listen_on.rs`** — unset `KITTY_LISTEN_ON`, run a
  save, assert pre-spawn fell back to the live path and the save
  still succeeded with the same exit code.

## Out of Scope

- A `--no-prespawn` user-visible flag. The env var
  `KSESSION_PRESPAWN=0` is sufficient for the bisect use case
  (consistent with other env-var knobs).
- Pre-spawning `set-user-vars` for ksession_id UUID tagging. That
  call depends on the `ls` result (we tag the windows we just
  discovered); cannot be parallelised this way.

## Further Notes

- The win is small but free: ~10 ms with ~5 LOC of substantive code
  changes plus the span instrumentation. The reason it's worth a
  PRD rather than a drive-by commit is that PRD-0 needs to validate
  it, and the `await_prespawn` vs `live` span distinction is part of
  that validation.
- Cross-references:
  - Plan §B.5 — original "DO" item.
  - PRD-0 — `save.discover.*` span placement.
  - PRD-3 — `KittyPool` is the substrate the pre-spawn dials into.
