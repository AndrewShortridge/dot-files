# Slice 7 — --no-scrollback flag gates replay

## Parent

[`docs/prds/0013-scrollback-replay-and-per-window-history.md`](../../prds/0013-scrollback-replay-and-per-window-history.md) — PRD-13, User Story 4.

## What to build

Ensure the existing `--no-scrollback` flag (which already gates scrollback capture during save) also gates scrollback replay during conf rendering and tmux restore codegen.

Today, `--no-scrollback` prevents `capture_scrollback()` from running, so `Window.scrollback` is `None` and `Program::Shell.scrollback` is `None`. The patcher and tmux codegen from Slices 3 and 6 already skip replay when the scrollback field is `None`, so the flag naturally gates replay on the save side.

However, there is an edge case: a session saved WITHOUT `--no-scrollback` (scrollback captured) could later be re-saved WITH `--no-scrollback`. The scrollback files still exist in the state dir from the prior save, but the new save should not reference them. This slice verifies that the propagation path correctly clears `Program::Shell.scrollback` to `None` when `--no-scrollback` is active, regardless of whether scrollback files exist on disk.

Similarly, the tmux restore codegen must respect the flag: when `--no-scrollback` is set on re-save, the newly generated `restore.sh` must not contain pane scrollback replay commands, even if scrollback files from a prior save exist in the state dir.

## Acceptance criteria

- [ ] Save with `--no-scrollback`: rendered `.conf` contains no `cat scrollback.ansi` commands.
- [ ] Save with `--no-scrollback`: generated `restore.sh` contains no pane scrollback replay commands.
- [ ] Save without `--no-scrollback` after a prior save with scrollback: scrollback replay appears correctly.
- [ ] Re-save with `--no-scrollback` after a prior save without the flag: scrollback replay is removed from rendered conf and restore.sh, even though scrollback files still exist on disk.
- [ ] The flag has no effect on per-window history capture or HISTFILE rendering (history is independent of scrollback).
- [ ] Test: save fixture with `--no-scrollback`, assert conf and restore.sh are free of scrollback replay.
- [ ] Test: save fixture without the flag, assert scrollback replay present; re-save with the flag, assert replay removed.

## Blocked by

- Slice 3 (`03-patcher-scrollback-wrapping.md`) — patcher scrollback wrapping must exist to gate.
- Slice 6 (`06-tmux-pane-scrollback-replay.md`) — tmux codegen replay must exist to gate.
