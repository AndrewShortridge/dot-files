# Scrollback replay and per-window shell history

## Status

Accepted

## Context

ksession captures scrollback (ANSI) and command history during save but
does not restore either on session reload. Scrollback files exist at
`<state_dir>/scrollback/win-<id>.ansi`; they are write-only artifacts
today. Shell command history is not captured per-window at all — only the
global HISTFILE exists.

The goal is full round-trip fidelity for shell windows: prior terminal
output is visible when scrolling up, and up-arrow recalls the commands
from that specific window.

## Decision

### Scrollback: cat-before-exec in the launch command

The patcher rewrites `Program::Shell` launch lines from:

    launch --cwd=/some/dir zsh -l

to:

    launch --cwd=/some/dir /bin/sh -c 'cat /path/to/scrollback.ansi 2>/dev/null; exec zsh -l'

`cat` output goes to the terminal's scrollback buffer before the shell
starts. The viewport lands at the bottom (fresh prompt visible) — no
scroll position restoration attempted.

**Why not `kitty @ send-text`?** That sends through the shell's input
buffer — the shell tries to execute the ANSI as commands. Writing to
stdout before the shell starts is the only clean path.

**Why not a kitty API?** Kitty has no `inject-scrollback` RPC. The
`get-text` command extracts scrollback; there is no inverse.

### Raw programs are excluded (addendum 2026-06-09)

The cat-before-exec wrapper applies to shells (and shell-like restores
where the replayed ANSI lands as inert prior output). `Program::Raw`
windows — interactive TUI agents such as `pi`, `omp`, `claude` — are
excluded: their launch line execs the captured argv directly, with no
`/bin/sh -c 'cat …; exec …'` wrapper.

Rationale: a raw TUI must start on a clean PTY. Catting the raw-ANSI
transcript into the PTY before exec visually replays the entire prior
session (it reads as a rerun of the agent's transcript) and can leave
the terminal in a dirty mode (alternate screen, mouse reporting, …)
that the freshly exec'd program does not expect.

Scrollback CAPTURE for raw windows is unchanged — the `.ansi` file is
still written at save time as a write-only artifact; only the conf
rendering skips the replay.

### Per-window history: shell integration hook with hybrid ID

**Capture (continuous):** A shell integration hook
(`PROMPT_COMMAND`/`precmd`) appends each command to
`~/.cache/ksession/hist/$KITTY_WINDOW_ID`. The hook no-ops outside kitty
(`$KITTY_WINDOW_ID` unset). Installed via `make install-shell-hook`,
user sources in `.bashrc`/`.zshrc`.

**Capture (on save):** The shell adapter copies
`~/.cache/ksession/hist/$KITTY_WINDOW_ID` to
`<state_dir>/history/<ksession_uuid>.hist`, keyed by the window's stable
UUID.

**Restore:** The patcher sets `HISTFILE=<state_dir>/history/<uuid>.hist`
in the launch environment. The shell reads only that window's history.
Strict isolation — no merge with global history.

**Why hybrid IDs?** `KITTY_WINDOW_ID` is available immediately (no save
required) so the hook can start capturing from window creation.
`ksession_id` (UUID) is stable across save/restore cycles so the history
file can be found after restore. The save-time rename bridges the two.

### Tmux pane scrollback: replay in restore.sh

The tmux `restore.sh` codegen pipes saved pane scrollback into each pane
after creation. The pane's shell sees the content as prior output in its
scrollback buffer.

## Consequences

- **New install target:** `make install-shell-hook` + user must source
  the hook in their rc file. Follows the precedent of PRD-8's
  `make install-nvim-plugin`.
- **Disk usage:** Per-window history files accumulate in
  `~/.cache/ksession/hist/`. Orphan cleanup needed (sweep files for
  `KITTY_WINDOW_ID`s that no longer exist).
- **Scrollback size:** Large scrollback files increase session size and
  restore time. The `--no-scrollback` flag already gates capture.
- **No scroll position restoration:** The viewport always starts at the
  bottom. Restoring scroll position would require `kitty @ scroll-window`
  with a line count, adding timing sensitivity for marginal benefit.
