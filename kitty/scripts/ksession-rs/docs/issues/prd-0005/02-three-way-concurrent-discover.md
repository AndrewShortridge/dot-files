# Slice 2 — Three-way concurrent discover phase

## Parent

[`docs/prds/0005-kitty-rc-connection-pool.md`](../../prds/0005-kitty-rc-connection-pool.md) — PRD-3+4.

## What to build

Restructure the save discover phase to fire `ls_all_env_vars()`, `ls_session()` (skeleton), and `fetch_running_version_stdout()` concurrently via `tokio::join!` instead of the current sequential flow where the skeleton call waits until after `ls` completes.

Today's discover phase (from live trace data):
```
tokio::join!(version, ls)     →  18.6ms (overlapped)
resolve_targets(ls)            →  ~0ms
skeleton = ls_session().await  →  39.8ms (SERIAL, blocked on ls completing)
                          Total:  ~60ms
```

After this slice:
```
tokio::join!(version, ls, skeleton)  →  ~40ms (all three overlap)
resolve_targets(ls)                   →  ~0ms
                                Total:  ~40ms
```

The skeleton fetch is independent of the `ls` result — it's a separate `kitty @ ls --output-format=session` RPC that needs a socket connection but not the window-tree data. With the pool from Slice 1, `ls` and `skeleton` each acquire their own connection from the pool and run concurrently.

The `resolve_targets(&ls)` call stays sequential after the join (it needs the `ls` result). Orphan sweep and state-dir mkdir stay where they are (cheap, <1ms).

## Acceptance criteria

- [ ] The discover phase fires `ls_all_env_vars()`, `ls_session()`, and `fetch_running_version_stdout()` via a single `tokio::join!` call.
- [ ] `resolve_targets()` runs after the join (it depends on the `ls` result).
- [ ] `--trace=tree` shows `save.discover` dropping from ~60ms to ~40ms on the user's 3-window workload (the skeleton call no longer serializes after ls).
- [ ] `ksession trace stats save.discover --against /tmp/before` shows a measurable delta (target: ~20ms reduction).
- [ ] The `from_ls` / `from_skeleton` fixture paths still work (fixture mode skips the concurrent RPC path and reads from files, same as today).
- [ ] All existing tests pass.
- [ ] No new files — this is a restructure of existing code in the save orchestration.

## Blocked by

- Slice 1 ([`01-kitty-pool-replaces-rpc.md`](./01-kitty-pool-replaces-rpc.md)) — needs the pool to provide concurrent connections for ls + skeleton.
