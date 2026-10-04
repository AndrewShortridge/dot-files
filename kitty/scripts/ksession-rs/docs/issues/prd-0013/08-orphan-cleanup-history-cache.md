# Slice 8 — Orphan cleanup for per-window history cache files

## Parent

[`docs/prds/0013-scrollback-replay-and-per-window-history.md`](../../prds/0013-scrollback-replay-and-per-window-history.md) — PRD-13, Component 6.

## What to build

Extend the existing `fsx::sweep_orphans()` function to also clean up stale per-window history files from `~/.cache/ksession/hist/`.

The shell integration hook (Slice 1) writes one file per kitty window at `~/.cache/ksession/hist/$KITTY_WINDOW_ID`. When a window closes, its history file becomes an orphan. Over time these accumulate.

The cleanup strategy piggybacks on the existing orphan sweep lifecycle (called at the start of every save and restore). After sweeping gen-stamped state dirs, the function also scans `~/.cache/ksession/hist/`. For each file:

1. Parse the filename as a `KITTY_WINDOW_ID` (integer).
2. Check if that window ID exists in the current kitty `ls` response (the `ls` data is already available in the save flow from the discover phase).
3. If the window ID is NOT present and the file's mtime is older than `SWEEP_MIN_AGE` (60 seconds), delete it.

The 60-second age guard reuses the existing constant and prevents deletion of history files for windows that just opened (race between window creation and the next `kitty @ ls` snapshot).

If `~/.cache/ksession/hist/` doesn't exist (hook never installed), the sweep no-ops — no error, no directory creation.

The sweep requires the set of live window IDs. This is passed as a parameter (or resolved from the already-fetched `kitty @ ls` data) to avoid an extra RPC call.

## Acceptance criteria

- [ ] After sweep, history files for closed windows (not in `kitty @ ls`) and older than 60s are deleted.
- [ ] History files for windows that still exist in `kitty @ ls` are NOT deleted.
- [ ] History files younger than 60 seconds are NOT deleted, even if the window is gone.
- [ ] If `~/.cache/ksession/hist/` doesn't exist, the sweep does nothing (no error).
- [ ] Files that don't parse as integer window IDs are left untouched (defensive against non-ksession files).
- [ ] Errors during individual file deletion are logged and ignored (best-effort, matching existing sweep behavior).
- [ ] Unit test: populate a temp dir with files named `1`, `2`, `3`. Provide a set of live window IDs `{2}`. Assert `1` and `3` are deleted (with appropriate mtime manipulation) and `2` remains.
- [ ] Unit test: file `4` has mtime < 60s ago — assert it is NOT deleted even though window 4 is not live.
- [ ] Unit test: non-numeric filename `notes.txt` in the hist dir — assert it is not deleted.
- [ ] Existing orphan sweep tests pass unchanged.

## Blocked by

- Slice 1 (`01-shell-integration-hook.md`) — the hook must exist and write to the expected directory path so the cleanup targets the right location.
