# Slice 6 — Tmux pane scrollback replay in restore.sh

## Parent

[`docs/prds/0013-scrollback-replay-and-per-window-history.md`](../../prds/0013-scrollback-replay-and-per-window-history.md) — PRD-13, Component 4.

## What to build

Modify the `restore.sh` codegen in the tmux RPC module so that after each pane is created, if a saved scrollback file exists for that pane, the generated script replays the scrollback content into the pane.

Pane scrollback files are already captured at `<state_dir>/tmux/<session>/win-<idx>/pane-<id>/scrollback.ansi` by the tmux adapter. This slice adds the restore-side consumption.

The approach depends on testing which tmux mechanism works correctly:

**Primary approach** — `printf`/`cat` before shell starts: modify the pane's initial command so it cats the scrollback before exec'ing the shell. This mirrors the kitty window cat-before-exec strategy from Slice 3.

**Fallback approach** — `tmux load-buffer` + `tmux paste-buffer`: load the scrollback file into a named tmux buffer, then paste it into the target pane. This approach may inject content into the shell's input buffer rather than scrollback, requiring testing.

The codegen must resolve the correct scrollback file path for each pane using the pane's ID digits (the `%` prefix is stripped in the path, matching the capture-side convention).

Add a `__trace_run "tmux.restore.pane_scrollback" '{"pane_id":"<id>"}' ...` span in the generated script for each pane replay, integrating with the existing `ksession-trace-lib.sh` infrastructure.

The replay is conditional: wrapped in `if [ -f "<path>" ]; then ... fi` so missing scrollback files are silently skipped.

## Acceptance criteria

- [ ] Generated `restore.sh` contains scrollback replay commands for panes that have saved scrollback files.
- [ ] Panes without scrollback files have no replay commands in the generated script.
- [ ] The scrollback file path uses the correct pane ID convention (digits only, no `%` prefix).
- [ ] Replay commands are wrapped in `if [ -f ... ]` guards for robustness.
- [ ] `__trace_run "tmux.restore.pane_scrollback"` spans are emitted for each replay.
- [ ] The state directory path passed to the codegen is absolute (the restore.sh may be invoked from any working directory).
- [ ] Unit test: generate `restore.sh` for a 2-pane fixture with scrollback files, assert both replay commands appear.
- [ ] Unit test: generate `restore.sh` for a pane without scrollback, assert no replay command for that pane.
- [ ] All existing tmux restore tests pass unchanged.

## Blocked by

None — can start immediately. The tmux codegen and pane scrollback capture are independent of the shell-side work in Slices 1–5.
