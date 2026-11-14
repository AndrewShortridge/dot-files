# Slice 4 — Shell adapter: per-window history capture

## Parent

[`docs/prds/0013-scrollback-replay-and-per-window-history.md`](../../prds/0013-scrollback-replay-and-per-window-history.md) — PRD-13, Component 2 (save side).

## What to build

Extend the shell adapter's `capture()` method to copy the per-window history file from the hook's live-write location to the session state directory.

After detecting the shell kind and environment (venv, conda, etc.), the adapter:

1. Resolves the source path: `~/.cache/ksession/hist/{kitty_window_id}` where `kitty_window_id` is `ctx.kitty_window.id`.
2. If the source file exists, copies it (via `std::fs::copy()`, not rename) to `{state_dir}/history/{ksession_uuid}.hist`, creating the `history/` subdirectory if needed.
3. Sets `Program::Shell.history` to `Some(destination_path)`.
4. If the source file doesn't exist (hook not installed, or window too new), sets `history` to `None`.

The copy uses `std::fs::copy()` so the hook's live-write target remains intact for continued capture.

Add a `perf_span!(Level::Debug, "save.capture.history_copy")` span around the copy operation, with args `win_id` and `hist_bytes` (file size copied).

## Acceptance criteria

- [ ] When `~/.cache/ksession/hist/<kitty_window_id>` exists, it is copied to `<state_dir>/history/<ksession_uuid>.hist`.
- [ ] The source file still exists after the copy (not moved).
- [ ] `Program::Shell.history` is `Some(destination_path)` after a successful copy.
- [ ] When the source file doesn't exist, `history` is `None` — no error, no warning.
- [ ] When the source file is empty (0 bytes), it is still copied (empty history is valid).
- [ ] The `history/` subdirectory is created inside `state_dir` if it doesn't exist.
- [ ] `save.capture.history_copy` span emits when tracing is active and the source file exists.
- [ ] Unit test: create a temp dir with a mock history file, run the copy logic, assert the file appears at the correct destination and the source still exists.
- [ ] Unit test: source file missing — assert `history` is `None`, no error.
- [ ] All existing shell adapter tests pass unchanged.

## Blocked by

- Slice 2 (`02-model-scrollback-history-fields.md`) — the `history` field must exist on `Program::Shell`.
