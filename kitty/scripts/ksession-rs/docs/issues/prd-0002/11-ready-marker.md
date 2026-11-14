# Slice 11 — Ready marker contract across rust / bash / lua

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

Establish the "session is fully loaded" signal across every contributor process so tree-mode-on-restore can know when to stop waiting and print the unified tree.

The contract: each contributor process touches a file at `<trace_dir>/ready/<contributor>` as the last action of its restore-side work. The file content is empty; existence is the signal.

Contributor naming:
- Rust side on save: `<trace_dir>/ready/rust` (touched at `cli::save` exit, after the success line emits).
- Each `restore.sh` (one per tmux session): `<trace_dir>/ready/tmux-<sess>`. Touched immediately **before** `attach-session` (because attach blocks indefinitely; touching it after would never fire).
- Each `ksession_restore.lua` invocation (one per nvim window): `<trace_dir>/ready/nvim-<pid>`. Touched from the final `VimEnter` autocmd in the chain, after the last buffer is loaded.

**Crucially**: the markers are touched whether tracing is enabled or not. They are part of the artifact contract, not a tracing-only feature. This lets future tooling (shell-prompt "session loaded" feedback) reuse the same signal.

Also delivered in this slice:

- A `perf::ready::wait_for_all(trace_dir, expected_count, timeout)` helper in Rust. Polls `<trace_dir>/ready/` (using `inotify` if available, falling back to a 50ms-interval poll). Returns when count reached or timeout. Used by Slice 12's tree-mode-on-restore.
- `expected_count` is derived from the saved manifest: 1 (rust) + tmux session count + nvim window count.
- Timeout default: 30 seconds. Overridable via `KSESSION_TRACE_READY_TIMEOUT_MS` env var.

## Acceptance criteria

- [ ] After a save, `<trace_dir>/ready/rust` exists (when tracing is enabled). When tracing is disabled, the marker is still touched at the conventional location `~/.cache/ksession/last-save-ready` so future tooling can pick it up regardless of tracing state.
- [ ] After a tmux-pane restore, `<trace_dir>/ready/tmux-<sess>` exists.
- [ ] After an nvim-window restore, `<trace_dir>/ready/nvim-<pid>` exists.
- [ ] `perf::ready::wait_for_all` returns Ok immediately when the count of files in `<trace_dir>/ready/` equals `expected_count`.
- [ ] `perf::ready::wait_for_all` returns `Err(Timeout)` when the timeout elapses with insufficient markers, and the error includes the names of missing markers.
- [ ] Unit test: create a tempdir, spawn a tokio task that touches three markers with staggered sleeps, assert `wait_for_all(dir, 3, 5s)` returns Ok within the right window.
- [ ] Integration test: run a fixture restore with one tmux session + one nvim window, assert all three markers fire within 30s, assert `wait_for_all` returns Ok.
- [ ] The markers are touched even when `KSESSION_TRACE_DIR` is **unset** — at the conventional locations described above. This is the artifact-contract aspect of the slice.

## Blocked by

- Slice 9 ([`09-bash-cross-process.md`](./09-bash-cross-process.md)) — bash side touches its marker.
- Slice 10 ([`10-lua-cross-process.md`](./10-lua-cross-process.md)) — lua side touches its marker.
