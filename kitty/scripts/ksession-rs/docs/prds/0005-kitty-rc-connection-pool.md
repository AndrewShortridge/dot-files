# PRD-3+4: Kitty RC connection pool with pre-spawn for parallel RPC under buffer_unordered

Status: ready-for-agent
Depends on: PRD-0 (`0002-observability-infrastructure.md`)
See also: ADR 0005 (`0005-kitty-rc-connection-pool.md`)

## Problem Statement

`src/kitty/rpc.rs` holds a single Unix-socket connection behind a
`Mutex<KittyTransport>`. Under the `buffer_unordered(12)` fan-out in
`session::save::capture` (plan §B.2), all 12 concurrent capture
futures contend for that mutex on every kitty RC call —
`get-text` for scrollback, `set-user-vars` for the ksession_id UUID
tagging, occasional `ls` re-reads. A 12-window save pays approximately
12 × 15 ms ≈ 180 ms of cumulative kitty-RPC wall time on what
should be a fully parallel workload.

Live trace data from a real 3-window workload shows the current costs:
discover phase takes 60.8 ms, of which 39.8 ms is `ls_session()`
(skeleton fetch) serialized AFTER the `ls` call completes. Capture
takes 15.4 ms serialized behind the Mutex. Total save: 82.2 ms.

The obvious fix would be in-socket multiplexing (correlation IDs +
multiple in-flight requests on one connection). Investigation
confirmed kitty's protocol does not support this — see ADR 0005 for
the protocol-level analysis. The remaining levers are **multiple
concurrent connections** and **overlapping discover-phase calls**.

## Solution

Replace the single `Mutex<KittyTransport>` with an N-way connection
pool (`KittyPool`) pre-spawned in `main()` before clap parsing,
combined with a three-way concurrent discover phase. This merges
the original PRD-3 (connection pool) and PRD-4 (pre-spawn) into a
single design.

Pool capacity is `FAN_OUT_LIMIT` (12) — matching `buffer_unordered(12)`
exactly. This means zero contention during capture for workloads up to
12 windows, since every concurrent future gets its own connection.

The pool is pre-warmed: `main()` peeks at `argv[1]` and, for the `save`
subcommand only, spawns `tokio::spawn(KittyPool::discover_and_warm(12))`
before clap parsing begins. By the time clap finishes (~3 ms), the pool
has found the socket path AND dialed all 12 connections concurrently.
Non-save subcommands skip the pre-spawn entirely.

The discover phase fires three calls concurrently via `tokio::join!`:
`ls_all_env_vars()`, `ls_session()` (skeleton), and
`fetch_running_version_stdout()`. The skeleton call was previously
serialized AFTER `ls` (costing 39.8 ms); now it overlaps. This is the
primary discover-phase win.

PRD-0's `kitty.rpc.*` L4 spans validate the win. Expected latency on
the real 3-window workload: discover drops from 60.8 ms to ~35 ms;
capture drops from 15.4 ms (serial at Mutex) to ~14 ms (parallel).
Total save: 82.2 ms to ~47 ms (43% faster). At 12 windows, capture
drops from ~120 ms serial to ~10 ms parallel.

## User Stories

1. As a kitty user with 12 windows saving simultaneously via
   `buffer_unordered`, I want the per-window `get-text` scrollback
   capture to run concurrently across windows instead of serialising
   behind a single mutex, so that wall time approaches per-call cost
   rather than sum-of-call cost.

2. As the maintainer reviewing this PRD's measurements, I want
   PRD-0's histogram to show that total save time on a 3-window
   workload drops from ~82 ms to ~47 ms (43% faster), verifiable in
   the `chrome://tracing` timeline view.

3. As a kitty user running `ksession save`, I want pool
   initialisation to overlap with clap parsing so that by the time
   `save()` runs the pool is fully ready, with zero startup cost
   visible in the save path.

4. As a kitty user running `ksession show` or `ksession list` (which
   do no RPC), I want pool pre-spawn to be skipped entirely via the
   `argv[1]` gate, so that non-save subcommands pay no pool startup.

5. As a kitty user whose kitty process restarts mid-save (unusual
   but possible), I want a stale pool connection to surface as a
   single-call error that degrades the affected window rather than
   poisoning the entire pool, so that one transient failure does not
   abort the save.

6. As the maintainer, I want the pool size to be configurable via
   `KSESSION_KITTY_POOL_SIZE` env var (default FAN_OUT_LIMIT = 12)
   so that I can bisect the win contribution and tune for the user's
   kitty version without a rebuild.

## Implementation Decisions

### Single implementation slice

This is implemented as one single slice (~300 LOC net) touching 5
files. There is no phased rollout — pool, pre-spawn, and three-way
join land together.

### Module layout

- `src/kitty/pool.rs` — new file.
  - `KittyPool { idle: Mutex<VecDeque<KittyConn>>, capacity: u32,
    listen_on: PathBuf, password: Option<String>, in_use: AtomicU32 }`.
  - `KittyConn { stream: UnixStream, /* per-connection auth state */ }`
    moved here from `rpc.rs`.
  - `pool.acquire() -> PoolGuard<'_>` — pops idle, or dials new if
    `in_use < capacity`, or waits on a `Notify` if at capacity.
  - `Drop` on `PoolGuard` returns the conn to `idle` (or discards
    it if the call errored — see per-connection poison below).
- `src/kitty/rpc.rs` — `KittyRpc` (single connection,
  `Mutex<Option<UnixStream>>`) is **deleted**. `KittyTransport::Rpc(KittyRpc)`
  becomes `KittyTransport::Pool(Arc<KittyPool>)`. The `Cli` variant
  stays for fixture-driven saves.
- `src/session/save.rs` — `SharedCtx.kitty: Arc<KittyPool>` instead of
  `Arc<Mutex<KittyTransport>>`. Initialised from the pre-spawned pool.
- `src/main.rs` — pre-spawn lifecycle (see below).

### Pool capacity and contention

Pool capacity is tied to the fan-out constant:

```rust
const POOL_CAPACITY: usize = FAN_OUT_LIMIT; // 12
```

Under `buffer_unordered(12)`, at most 12 futures contend; 12
connections give zero-contention parallelism. Every concurrent capture
future gets its own connection with no waiting.

`KSESSION_KITTY_POOL_SIZE` env var overrides the default. Bounds: [1,
32]. Out-of-bounds values clamp with a one-line stderr warning.

### Pre-spawn lifecycle in main()

`main()` peeks at `argv[1]` before clap parsing. For the `save`
subcommand only:

```rust
let pool_handle = if std::env::args().nth(1).as_deref() == Some("save") {
    Some(tokio::spawn(KittyPool::discover_and_warm(12)))
} else {
    None
};
// clap parsing happens here (~3 ms, overlaps with pre-warm)
// ...
// pool_handle is threaded to cli::save which awaits it
```

`discover_and_warm(capacity)` finds the socket path AND dials all 12
connections concurrently. By the time `save()` runs, the pool is fully
ready. Non-save subcommands (`show`, `list`, etc.) skip the pre-spawn
entirely: no pool startup, no socket discovery, no wasted connections.

The `JoinHandle` is threaded through to `cli::save` which `.await`s
it to get the warmed `KittyPool`.

### Three-way concurrent discover phase

The discover phase fires three calls concurrently via `tokio::join!`:

```rust
let (env_vars, skeleton, version) = tokio::join!(
    ls_all_env_vars(),
    ls_session(),              // skeleton fetch
    fetch_running_version_stdout(),
);
```

Previously, `ls_session()` (skeleton) was serialized AFTER the `ls`
call completed, costing 39.8 ms of serial wait. Now all three overlap.
This is the primary discover-phase win, dropping discover from 60.8 ms
to ~35 ms.

### Per-connection poison, not pool-wide

If `call()` errors, the `PoolGuard`'s stream is dropped (set to
`None`). On `Drop`, nothing returns to the idle queue — the poisoned
connection is silently discarded. The next `acquire()` dials a fresh
connection. One bad connection does not affect other windows' captures.

This is strictly per-connection: a broken stream in one `PoolGuard`
has no effect on other guards or on the pool's idle queue.

### Connection lifecycle

- **Dialing**: `UnixStream::connect(listen_on)`, then send the
  password handshake if `remote_control_password` is configured (per
  ADR 0005 / `remote_control.py` ref: each command carries the
  password; there is no session handshake state per connection).
- **Pre-warm**: all 12 connections are dialed concurrently during
  `discover_and_warm()`, overlapping with clap parsing.
- **Per-RPC**: `write_request(socket, cmd)` -> `read_response(socket)`.
  Same wire format as today.
- **Reuse**: on `PoolGuard::Drop`, the conn returns to the idle
  queue (unless poisoned by error).
- **Error path**: if the RPC errored with `KError::KittyIo(...)` or
  `KError::KittyRemote(...)`, the conn is **discarded** (not
  returned to idle). The next `acquire()` dials a fresh conn.
- **Shutdown**: on `KittyPool::Drop`, drain idle queue, close each
  conn. In-use guards continue to own their conn and close on their
  own Drop.

### Auth and password

If kitty is configured with `remote_control_password`, the password
field is sent inside the JSON command envelope on **every** request
(per ADR 0005 — there is no session-state cache on the kitty side
for this field; `password_authorizer` uses an LRU 256 to dedupe
checks). So pool connection setup pays nothing extra; each call sends
the password just like today.

### Span instrumentation

PRD-0 L4 spans wrap each RPC. L5 spans inside `KittyConn::write_request`
and `::read_response` split each RPC into wire-out / wire-in / decode:

```rust
async fn ls(&self) -> Result<Ls> {
    let _s4 = perf::span!(Level::Debug, "kitty.rpc.ls",
                          bytes_out = self.estimate(), pool_in_use = self.pool.in_use());
    let mut conn = self.pool.acquire().await;
    {
        let _s5 = perf::span!(Level::Trace, "kitty.rpc.ls.write_req");
        conn.write_request(...).await?;
    }
    {
        let _s5 = perf::span!(Level::Trace, "kitty.rpc.ls.read_resp");
        let bytes = conn.read_response().await?;
        let _s5d = perf::span!(Level::Trace, "kitty.rpc.ls.decode_json");
        serde_json::from_slice(&bytes)
    }
}
```

The `pool_in_use` arg on the L4 span lets `ksession trace stats`
correlate latency with pool contention — if `pool_in_use` was >=
capacity when a span fired, that span waited in `acquire()`.

## Testing Decisions

A good test exercises the pool's capacity / lifecycle behaviour,
per-connection poison semantics, and the concurrent-call shape. The
single-call correctness of `KittyTransport` methods is already covered
by existing tests; those keep passing. All tests land in the single
implementation slice.

### Modules to test directly

- **`KittyPool::acquire` capacity** — unit test: capacity=2, spawn 4
  futures each calling `acquire().await`, assert only 2 hold the
  guard simultaneously, the other 2 wait. Use a `tokio::time::sleep`
  inside the guard's scope to make the contention observable.
- **`PoolGuard` per-connection poison** — unit test: simulate an
  error on a conn's RPC (via a mock `KittyConn` trait if needed),
  assert the conn is dropped not returned to idle, next `acquire()`
  dials a fresh one. Verify other pool connections are unaffected.
- **`discover_and_warm` pre-spawn** — unit test: verify that
  `discover_and_warm(12)` returns a pool with 12 ready connections
  and a resolved socket path.

### End-to-end tests to add

- **`kitty_pool_concurrent_ls.rs`** — spawn a real kitty (via the
  existing `kitty::testkitty::TestKitty` harness, per
  `src/kitty/testkitty.rs`), issue 12 concurrent `ls` calls from 12
  tokio tasks, assert all 12 succeed and return identical results.
- **`kitty_pool_perf_budget.rs`** — `#[ignore]` benchmark, 30 iters
  of typical workload (12 windows), assert cumulative `kitty.rpc.*`
  p95 <= 80 ms (target: parallelism brings the cumulative wall time
  down from ~180 ms serial to ~30-50 ms parallel; +60% headroom).
- **`kitty_pool_disconnect_recovery.rs`** — start a save, mid-save
  kill kitty's RC listener (simulate by closing the test kitty's
  listen socket), assert next RPC errors cleanly, affected window
  degrades via per-connection poison, save continues with remaining
  windows.

### Existing tests that must keep passing

All existing `kitty/*` and adapter integration tests. `KittyRpc` is
deleted and replaced by `KittyPool`; the `KittyTransport::Cli` variant
is unchanged and continues to serve fixture-driven test saves.

## Out of Scope

- Pooling for the legacy bash path. The legacy `ksession.sh` still
  exists for non-Rust callers; its `kitty @ ls` subprocess invocations
  are independent of this work.
- Multiple kitty servers. The pool is keyed to a single `listen_on`;
  multi-kitty-instance support is not a v1 goal.
- TLS or auth beyond `remote_control_password`. Kitty's RC has no
  TLS surface.
- Sharing the pool across save and restore. Restore is a separate
  process invocation; the pool lifecycle is per-invocation.
- Falling back to spawning `kitty @ ls` as a subprocess if `listen_on`
  is unset. The existing `KittyTransport` already implements the
  direct-DCS path per plan §B.3.1; this PRD is purely a pooling
  layer on top.

## Further Notes

- ADR 0005 records the protocol investigation that drove this design
  shape (connection pool, not in-socket multiplex).
- PRD-4 (pre-spawn) is merged into this PRD. There is no separate
  PRD-4 — the pool and pre-spawn are a single design.
- The 12-connection default matches `FAN_OUT_LIMIT` exactly. The
  `KSESSION_KITTY_POOL_SIZE` env var supports tuning if needed.
- Cross-references:
  - ADR 0005 — protocol-level analysis.
  - Plan §B.3.1 — direct DCS socket client (substrate this PRD pools).
  - Plan §B.2 — flat fan-out via buffer_unordered(12) (the workload
    this PRD parallelises against).
  - PRD-0 — `kitty.rpc.*` and `pool_in_use` span instrumentation.
