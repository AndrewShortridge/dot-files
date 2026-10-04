# Slice 1 — Shell integration hook script + Makefile install

## Parent

[`docs/prds/0013-scrollback-replay-and-per-window-history.md`](../../prds/0013-scrollback-replay-and-per-window-history.md) — PRD-13, Component 3.

## What to build

A standalone shell script (`scripts/ksession_shell_history.sh`) that users source from their `.bashrc`/`.zshrc` to enable per-window command history capture. The script detects whether it's running under bash or zsh and installs the appropriate hook:

- **Bash**: Appends a function to `PROMPT_COMMAND` that runs `history -a $KSESSION_HIST_FILE` after each command.
- **Zsh**: Registers a `precmd` hook (via `add-zsh-hook` if available, fallback to `precmd_functions` array) that appends the last command to `$KSESSION_HIST_FILE`.

Both paths set `KSESSION_HIST_FILE=~/.cache/ksession/hist/$KITTY_WINDOW_ID`.

The entire hook is guarded by `[[ -n "$KITTY_WINDOW_ID" ]] || return` so it no-ops outside kitty terminals.

The hook creates `~/.cache/ksession/hist/` on first invocation if the directory doesn't exist.

A Makefile `install-shell-hook` target copies the script to `$(PREFIX)/share/ksession/ksession_shell_history.sh` and prints a message telling the user to source it. The `install-all` target is updated to include `install-shell-hook`.

No Rust code changes in this slice.

## Acceptance criteria

- [ ] `scripts/ksession_shell_history.sh` exists and is valid shell (passes `shellcheck`).
- [ ] Sourcing in bash with `KITTY_WINDOW_ID=99` and running 3 commands creates `~/.cache/ksession/hist/99` containing those 3 commands.
- [ ] Sourcing in zsh with `KITTY_WINDOW_ID=99` and running 3 commands creates `~/.cache/ksession/hist/99` containing those 3 commands.
- [ ] Sourcing without `KITTY_WINDOW_ID` set creates no files and produces no errors.
- [ ] `~/.cache/ksession/hist/` directory is created automatically on first command if absent.
- [ ] `make install-shell-hook` copies the file to `$(PREFIX)/share/ksession/` and prints sourcing instructions.
- [ ] `make install-all` includes the new target.
- [ ] `make uninstall-shell-hook` removes the installed file.
- [ ] Hook does not modify the user's existing `HISTFILE` — it writes to a separate per-window file.
- [ ] Hook function name is namespaced (e.g., `__ksession_hist_append`) to avoid colliding with user functions.

## Blocked by

None — can start immediately.
