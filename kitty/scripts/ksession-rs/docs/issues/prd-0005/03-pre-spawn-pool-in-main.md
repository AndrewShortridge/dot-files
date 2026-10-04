# Slice 3 — Pre-spawn pool in main() before clap parsing

## Parent

[`docs/prds/0005-kitty-rc-connection-pool.md`](../../prds/0005-kitty-rc-connection-pool.md) — PRD-3+4.

## What to build

Move pool creation from inside `session::save()` to `main()`, before clap parsing, so that socket discovery and connection pre-warming overlap with the ~3ms of clap startup. The pool is fully ready by the time `save()` runs.

The implementation:
1. `main()` peeks at `argv[1]` (raw, before clap) via `std::env::args().nth(1)`.
2. If `argv[1] == "save"`: spawn `tokio::spawn(KittyPool::discover_and_warm(capacity))` which finds the socket path AND dials all 12 connections concurrently.
3. If not `save` (e.g., `list`, `show`, `rm`, `trace`): skip the pre-spawn entirely. Non-save subcommands pay zero pool startup.
4. Clap parsing proceeds normally (~3ms), overlapping with the pre-warm task.
5. The `JoinHandle<Result<KittyPool>>` is threaded through to `cli::save` which `.await`s it.
6. If pre-spawn fails (no kitty socket found), the error surfaces at the same point as today's `KittyRpc::discover()` error — same error message, same diagnostics.
7. If the subcommand turns out not to be `save` after clap parses (e.g., `save` was an argument to another subcommand, not the subcommand itself — unlikely but possible), the `JoinHandle` is dropped, aborting the pre-warm task cleanly.

`discover_and_warm(capacity)` is a new method on `KittyPool` that:
- Runs `discover_candidates()` to find the socket path (same logic as today)
- Dials `capacity` connections concurrently via `futures::join_all` of `UnixStream::connect`
- Returns the pool with all connections in the idle queue, ready for immediate `acquire()`

## Acceptance criteria

- [ ] `ksession save <session>` pre-spawns the pool before clap parsing. Verifiable: add a `perf_span!` around the pre-spawn await in `save()` — a `save.discover.await_prespawn` span with ~0ms duration means the pool was ready before save ran.
- [ ] `ksession list`, `ksession show <name>`, `ksession rm <name>`, `ksession trace ls` do NOT trigger any pool creation or socket discovery. Verifiable: run these with `KSESSION_TRACE_DIR` set and confirm no `kitty.rpc.*` spans appear.
- [ ] `--trace=tree` shows `save.discover` dropping by ~5ms compared to the post-Slice-2 baseline (the pool discovery + dial latency that previously ran inside discover is now overlapped with clap parsing).
- [ ] With `KITTY_LISTEN_ON` unset (no kitty socket), the pre-spawn fails gracefully and the error surfaces inside `session::save` with the same "no kitty RC socket found" message as today.
- [ ] Cancellation: if the binary exits before `save()` awaits the handle (e.g., clap parse error, `--help`), the pre-spawn task is aborted cleanly with no resource leak.
- [ ] `discover_and_warm(12)` dials all 12 connections concurrently (not sequentially). Verifiable via trace spans or by asserting wall time of pre-warm is ~1ms (one concurrent dial) not ~6ms (12 sequential dials).
- [ ] All existing tests pass.

## Blocked by

- Slice 1 ([`01-kitty-pool-replaces-rpc.md`](./01-kitty-pool-replaces-rpc.md)) — needs the pool type to exist.
