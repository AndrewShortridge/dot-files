# Reopen §C.5 SKIP: proactive nvim mksession via kitty `launch --watcher`

RUST_PORT_PLAN.md §C.5 evaluated a "watcher / kitten daemon" that would
run `:mksession!` ahead of save so the save path reads a cached file at
~0 ms instead of paying the ~200 ms mksession floor. §C.5 rejected the
idea on a single basis — "+300 Python LOC" for the daemon scaffolding,
plus race-condition risk on the cache file. The ~125 ms p50 target in
§C.9 explicitly preserves the mksession floor.

PRD-8 reopens this decision. The investigation behind PRD-3 surfaced
kitty's `launch --watcher` framework
([launch docs](https://sw.kovidgoyal.net/kitty/launch/#watching-launched-windows),
kitty ≥ 0.28): a Python module attached globally via `watcher` in
`kitty.conf` that receives in-process callbacks for `on_set_user_var`,
`on_cmd_startstop`, `on_focus_change`, and related events on the kitty
UI thread. The framework eliminates the daemon-loop scaffolding that
drove §C.5's "300 LOC" estimate — we write callback functions, not a
process. Revised cost: ~50 LOC Python (watcher) + ~15 LOC lua (nvim
autocmd emits OSC 1337 `SetUserVar nvim_dirty=<ts>` on `BufWritePost` /
`CursorHold` / `VimLeavePre`) + ~30 LOC Rust (cache-read with mtime
freshness check + live-mksession fallback).

The §C.5 cache-race concern still exists but is bounded: the watcher
debounces and serialises per nvim instance, mtime-staleness checks gate
cache use, and any cache miss falls back to live `:mksession!`. Worst
case equals the current behaviour. Best case (cache hit) drops save's
nvim contribution to a single file read. The revised PRD-8 target is
sub-80 ms p50 typical save, breaking through the §C.9 floor that
§C.5's rejection preserved.
