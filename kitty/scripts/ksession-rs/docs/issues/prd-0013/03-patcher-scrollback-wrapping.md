# Slice 3 — Patcher: cat-before-exec scrollback wrapping

## Parent

[`docs/prds/0013-scrollback-replay-and-per-window-history.md`](../../prds/0013-scrollback-replay-and-per-window-history.md) — PRD-13, Component 1.

## What to build

Modify `append_program_argv()` in the conf patcher so that when `Program::Shell.scrollback` is `Some(path)`, the launch line wraps the shell invocation with `cat` to replay scrollback before the shell starts.

The rendering changes from:

    launch --cwd=/dir /bin/zsh -l

to:

    launch --cwd=/dir /bin/sh -c 'cat /path/to/scrollback.ansi 2>/dev/null; exec zsh -l'

When pre-commands exist (venv, conda, oldpwd), scrollback `cat` is prepended:

    launch --cwd=/dir /bin/sh -c 'cat /path/to/scrollback.ansi 2>/dev/null; source .../activate; export OLDPWD=...; exec zsh'

The `2>/dev/null` ensures missing scrollback files (deleted between save and restore) are silently ignored.

When `scrollback` is `None`, rendering is unchanged from today.

Today, the patcher already uses a `-c` flag with an `exec` wrapper when pre-commands are present. This slice extends that pattern: when scrollback is `Some`, the `-c` flag is always used (even without pre-commands), and `cat` is the first command in the chain.

Add a `perf_span!(Level::Debug, "conf.render.scrollback_wrap")` span around the scrollback-specific rendering logic, with args `win_id` and `scrollback_bytes` (file size, or 0 if the path doesn't exist at render time).

## Acceptance criteria

- [ ] `Program::Shell { scrollback: Some(path), .. }` renders a launch line containing `cat <path> 2>/dev/null; exec <shell>`.
- [ ] `Program::Shell { scrollback: None, .. }` renders identically to today (no `cat`, no change).
- [ ] Scrollback + venv: `cat` comes before `source .../activate` in the `-c` argument.
- [ ] Scrollback + oldpwd: `cat` comes before `export OLDPWD=...` in the `-c` argument.
- [ ] Scrollback + venv + oldpwd: all three pre-commands chain correctly before `exec`.
- [ ] The scrollback path is properly quoted via `kq()` for paths with spaces or special characters.
- [ ] Golden test: a table of `(Program::Shell input, expected launch line string)` covering all combinations.
- [ ] `conf.render.scrollback_wrap` span emits when tracing is active and scrollback is `Some`.
- [ ] All existing conf golden tests pass unchanged (they use `scrollback: None`).

## Blocked by

- Slice 2 (`02-model-scrollback-history-fields.md`) — the `scrollback` field must exist on `Program::Shell`.
