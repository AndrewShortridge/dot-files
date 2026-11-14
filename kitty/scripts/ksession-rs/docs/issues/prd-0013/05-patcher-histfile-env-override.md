# Slice 5 — Patcher: HISTFILE env override in launch line

## Parent

[`docs/prds/0013-scrollback-replay-and-per-window-history.md`](../../prds/0013-scrollback-replay-and-per-window-history.md) — PRD-13, Component 2 (restore side).

## What to build

Modify the conf patcher so that when `Program::Shell.history` is `Some(path)`, the rendered launch line includes a `--env` directive to set `HISTFILE` for the restored shell.

The rendering changes from:

    launch --cwd=/dir /bin/sh -c 'exec zsh -l'

to:

    launch --cwd=/dir --env HISTFILE=/path/to/uuid.hist /bin/sh -c 'exec zsh -l'

Kitty's session file parser supports `--env KEY=VALUE` on launch lines, which sets the environment variable for the spawned process without affecting other windows.

When `history` is `None` (hook not installed, first save without history), no `--env HISTFILE` is emitted — the shell uses its default HISTFILE.

The `--env` directive is placed after `--cwd` and before the shell binary in the launch line, following kitty's convention of flags before positional arguments.

## Acceptance criteria

- [ ] `Program::Shell { history: Some(path), .. }` renders a launch line containing `--env HISTFILE=<path>`.
- [ ] `Program::Shell { history: None, .. }` renders no `--env HISTFILE` — identical to today.
- [ ] The HISTFILE path is properly quoted via `kq()` for paths with spaces or special characters.
- [ ] `--env` is placed before the shell binary argument in the launch line.
- [ ] Combined test: scrollback + history + venv all present — all three features compose correctly in a single launch line.
- [ ] E2e round-trip test: save a fixture with a shell window that has a history file, render the conf, assert `--env HISTFILE=` appears in the output.
- [ ] Graceful degradation test: save a fixture with no history file (hook not installed), render the conf, assert no `HISTFILE` override and no errors.
- [ ] All existing conf golden tests pass unchanged.

## Blocked by

- Slice 4 (`04-shell-adapter-history-capture.md`) — the `history` field must be populated during save.
