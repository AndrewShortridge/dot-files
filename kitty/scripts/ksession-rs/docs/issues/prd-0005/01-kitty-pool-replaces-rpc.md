# Slice 1 — KittyPool replaces KittyRpc

## Parent

[`docs/prds/0005-kitty-rc-connection-pool.md`](../../prds/0005-kitty-rc-connection-pool.md) — PRD-3+4.

## What to build

Replace the single-connection `KittyRpc` (which serializes all RPC calls behind one `Mutex<Option<UnixStream>>`) with a connection-pool type `KittyPool` that manages up to `FAN_OUT_LIMIT` (12) concurrent Unix-socket connections to the kitty RC socket.

After this slice, every kitty RPC call (`ls`, `get_text`, `set_user_vars`, `ls_session`) goes through the pool. The pool hands out connections via `acquire() -> PoolGuard`, and `PoolGuard::Drop` returns the connection to the idle queue (or discards it if the call errored — per-connection poison). The existing save pipeline's behavior is unchanged; the structural improvement is that concurrent `buffer_unordered(12)` capture futures can now each hold their own connection instead of serializing at a single Mutex.

Key types:
- `KittyPool { idle: Mutex<VecDeque<UnixStream>>, socket_path: PathBuf, capacity: usize, in_use: AtomicUsize, notify: Notify }`
- `PoolGuard<'a> { pool: &'a KittyPool, stream: Option<UnixStream> }` — `None` means poisoned
- `KittyTransport` enum: `Rpc(KittyRpc)` → `Pool(Arc<KittyPool>)`. `Cli` variant unchanged.

Pool capacity defaults to `FAN_OUT_LIMIT` (12), overridable via `KSESSION_KITTY_POOL_SIZE` env var (clamped to [1, 32]).

Connections dial lazily on `acquire()` when the idle queue is empty and `in_use < capacity`. If at capacity, `acquire()` awaits a `Notify` signal from a returning `PoolGuard::Drop`.

The `call()` method (request/response exchange) moves from `KittyRpc` to `PoolGuard`. The high-level RPC methods (`ls_all_env_vars`, `get_text`, `set_user_vars`, `ls_session`) move to `KittyPool`, each internally acquiring a guard and calling through it.

Socket discovery (`discover_candidates()`, `connect_spec()`) stays in `rpc.rs` or moves to `pool.rs` — implementer's choice on file layout. The discovery logic is unchanged.

## Acceptance criteria

- [ ] `KittyRpc` struct is deleted (or reduced to an internal implementation detail of the pool).
- [ ] `KittyTransport::Rpc(KittyRpc)` is replaced with `KittyTransport::Pool(Arc<KittyPool>)`.
- [ ] `KittyTransport::Cli` variant is unchanged and fixture-driven test saves still work.
- [ ] Pool capacity defaults to `FAN_OUT_LIMIT` (12) via `const POOL_CAPACITY: usize = FAN_OUT_LIMIT;`.
- [ ] `KSESSION_KITTY_POOL_SIZE` env var overrides capacity; out-of-bounds values clamp to [1, 32] with stderr warning.
- [ ] `acquire()` dials new connections lazily when idle queue is empty and under capacity; waits on `Notify` when at capacity.
- [ ] Per-connection poison: if `call()` errors, the `PoolGuard`'s stream is `None` on Drop; nothing returns to idle. Next `acquire()` dials fresh. Other pool connections are unaffected.
- [ ] All existing `cargo test --lib --release` tests pass (539 baseline).
- [ ] All existing integration tests that use `KittyTransport::Cli` still pass.
- [ ] `ksession save <session> --trace=tree` produces output with no regression vs baseline timing (structural change, not a speed win yet — parallelization comes in slices 2+3).
- [ ] New unit tests: pool capacity contention (capacity=2, 4 concurrent acquires, assert only 2 hold simultaneously); per-connection poison (error discards conn, next acquire dials fresh); `pool_in_use` counter accuracy.
- [ ] L4 span `pool_in_use` arg appears on `kitty.rpc.*` spans when tracing is enabled at debug level.
- [ ] No new third-party crates (pool is hand-rolled with `tokio::sync::{Mutex, Notify}` and `std::sync::atomic`).

## Blocked by

None — can start immediately.
