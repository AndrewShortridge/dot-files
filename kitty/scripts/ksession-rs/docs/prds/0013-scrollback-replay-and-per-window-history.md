# PRD-13: Scrollback replay, per-window shell history, and tmux pane scrollback

Status: ready-for-agent
Depends on: PRD-0 (`0002-observability-infrastructure.md`)
See also: ADR 0007 (`0007-scrollback-replay-and-per-window-history.md`)

## Problem Statement

ksession captures shell scrollback (ANSI) and tmux pane scrollback at
save time, but both are write-only artifacts — never restored. Command
history is not captured per-window at all. This means a restored session
loses three things:

1. **Terminal scrollback** — prior command output in shell windows is
   gone. The user can't scroll up to see what they were looking at.
2. **Per-window command history** — up-arrow recalls commands from the
   global HISTFILE, not the specific window's history. Context is lost.
3. **Tmux pane scrollback** — panes restart with empty scrollback even
   though the capture files exist on disk.

Scrollback files already exist at `<state_dir>/scrollback/win-<id>.ansi`
(captured via `kitty @ get-text --extent all --ansi`). Tmux pane
scrollback is captured to `<state_dir>/tmux/<sess>/pane-<id>/scrollback.ansi`.
Neither is consumed during restore.

## Solution

Four coordinated changes — patcher scrollback wrapping, shell adapter
history capture, a shell integration hook, and tmux restore codegen —
that together close the round-trip fidelity gap for shell windows and
tmux panes.

1. **Patcher scrollback wrapping**: The `conf/mod.rs` patcher rewrites
   `Program::Shell` launch lines to `cat` the saved scrollback file
   before exec'ing the shell. The output becomes real terminal
   scrollback. Viewport starts at the bottom (fresh prompt).

2. **Shell adapter history capture**: On save, the shell adapter copies
   the per-window history file (maintained by the shell hook) from
   `~/.cache/ksession/hist/$KITTY_WINDOW_ID` to
   `<state_dir>/history/<ksession_uuid>.hist`. On restore, the patcher
   sets `HISTFILE` to the UUID-keyed path.

3. **Shell integration hook**: A shell function
   (`scripts/ksession_shell_history.sh`) sourced from `.bashrc`/`.zshrc`
   that appends each command to
   `~/.cache/ksession/hist/$KITTY_WINDOW_ID` via `PROMPT_COMMAND` (bash)
   or `precmd` (zsh). No-ops outside kitty. Installed via
   `make install-shell-hook`.

4. **Tmux pane scrollback replay**: The `restore.sh` codegen in
   `tmux_rpc` pipes saved pane scrollback into each pane after creation,
   so prior output appears in the pane's scrollback buffer.

PRD-0's span hierarchy is extended with new spans to measure the
latency contribution of each component.

## User Stories

1. As a kitty user who saves a session with 3 shell windows and
   restores it, I want to scroll up in each restored window and see
   the terminal output that was there at save time, so that I don't
   lose context.

2. As a kitty user who presses up-arrow in a restored shell window, I
   want to see the commands I ran in *that specific window*, not
   commands from other windows or the global history, so that my
   muscle memory still works.

3. As a kitty user with a tmux session containing 4 panes, I want
   each restored pane to have its scrollback from save time, so that
   I can scroll up to see prior output in each pane.

4. As a kitty user who saves with `--no-scrollback`, I want scrollback
   replay and tmux pane replay to be skipped entirely (no `cat`, no
   pane injection), so that the flag's behavior is consistent.

5. As a kitty user whose shell integration hook is not installed, I
   want save and restore to work exactly as today — no per-window
   history, no errors — so that the feature degrades gracefully.

6. As a kitty user who saves a session for the first time (no prior
   save for this window), I want the shell hook to have been capturing
   history since the window was created, so that the first save already
   has per-window history to preserve.

7. As the maintainer, I want PRD-0 spans for `save.capture.history_copy`,
   `conf.render.scrollback_wrap`, and `tmux.restore.pane_scrollback` so
   that I can measure the latency cost of each component and set perf
   budgets.

8. As a kitty user restoring a session saved on a different machine or
   after the state dir was partially deleted, I want missing scrollback
   or history files to be silently skipped (no error, no crash), so
   that partial state is tolerated.

9. As the maintainer running the benchmark suite, I want a
   `scrollback_replay_perf_budget` test that asserts the `cat`-before-exec
   wrapping adds ≤ 5 ms to conf rendering, so that the scrollback
   feature stays within perf budget.

10. As a kitty user, I want per-window history files in
    `~/.cache/ksession/hist/` to be cleaned up when the corresponding
    kitty window no longer exists, so that orphan files don't
    accumulate.

11. As a kitty user with large scrollback (100K+ lines), I want the
    save to still complete within the existing perf budget, and the
    restore to not visibly stall on the `cat` operation, so that large
    scrollback doesn't degrade the experience.

12. As the maintainer, I want the shell hook to support both bash and
    zsh with a single sourced file, so that there's one artifact to
    install and maintain.

## Implementation Decisions

### Component 1: Patcher scrollback wrapping (`conf/mod.rs`)

The `append_program_argv()` function for `Program::Shell` is modified.
When the window has a scrollback file and `--no-scrollback` is not set,
the launch line changes from:

    launch --cwd=/dir /bin/zsh -l

to:

    launch --cwd=/dir /bin/sh -c 'cat /path/to/scrollback.ansi 2>/dev/null; exec zsh -l'

When the shell also has venv/conda/oldpwd setup:

    launch --cwd=/dir /bin/sh -c 'cat /path/to/scrollback.ansi 2>/dev/null; source .../activate; export OLDPWD=...; exec zsh'

The scrollback `cat` is always the first command in the chain so it
writes to stdout before the shell's prompt appears.

The `2>/dev/null` suppresses errors if the scrollback file was deleted
between save and restore (graceful degradation per user story 8).

A new field `scrollback: Option<PathBuf>` is added to `Program::Shell`
(already exists on `model::Window` but needs to propagate to the
program-level rendering context).

New span: `perf_span!(Level::Debug, "conf.render.scrollback_wrap")`.

### Component 2: Per-window history — shell adapter capture

The shell adapter (`adapter/shell.rs`) gains a new capture step after
detecting the shell kind. On save:

1. Resolve source path: `~/.cache/ksession/hist/{kitty_window_id}`
2. If file exists, copy to `{state_dir}/history/{ksession_uuid}.hist`
3. Store the destination path in a new `Program::Shell` field:
   `history: Option<PathBuf>`

On restore (in the patcher), when `history` is `Some(path)`:

    launch --cwd=/dir --env HISTFILE=/path/to/uuid.hist /bin/sh -c '...; exec zsh'

The `--env` directive in kitty session files sets the environment for
the launched process.

If the source file doesn't exist (hook not installed, or window too new),
the field is `None` and no `HISTFILE` override is emitted.

New span: `perf_span!(Level::Debug, "save.capture.history_copy")`.

The history copy uses `std::fs::copy()` (not rename) so the hook's
live-write target remains intact.

### Component 3: Per-window history — shell integration hook

New file: `scripts/ksession_shell_history.sh`

The hook detects bash vs zsh at source time and installs the
appropriate mechanism:

- **Bash**: Appends to `PROMPT_COMMAND` a function that runs
  `history -a $KSESSION_HIST_FILE` (append last command to the
  per-window file).
- **Zsh**: Adds a `precmd` hook via `add-zsh-hook` that runs
  `fc -W $KSESSION_HIST_FILE` (write current history to the
  per-window file) or `print -sr -- $KSESSION_LAST_CMD` (append
  last command).

Both set `KSESSION_HIST_FILE=~/.cache/ksession/hist/$KITTY_WINDOW_ID`.

Guard: the entire hook is wrapped in `[[ -n "$KITTY_WINDOW_ID" ]] || return`
so it no-ops outside kitty.

The hook creates `~/.cache/ksession/hist/` on first run if it doesn't
exist.

### Component 4: Tmux pane scrollback replay

The `restore.sh` codegen in `tmux_rpc/mod.rs` is modified. After each
`split-window` or `send-keys` that sets up a pane, if the pane has a
saved scrollback file, the codegen emits:

```bash
# Replay scrollback for pane %N
if [ -f "/path/to/pane-N/scrollback.ansi" ]; then
    tmux load-buffer -b _ksession_sb "/path/to/pane-N/scrollback.ansi"
    tmux paste-buffer -b _ksession_sb -d -t "$SESS:$WIN.$PANE"
fi
```

Alternative approach if `load-buffer`/`paste-buffer` injects into the
shell input (testing required): fall back to:

```bash
cat /path/to/pane-N/scrollback.ansi
```

executed as the pane's first command before the shell starts (same
cat-before-exec strategy as the kitty window scrollback).

The `--no-scrollback` flag gates this: when set, no pane scrollback
replay lines are emitted.

New span (in `ksession-trace-lib.sh`): `tmux.restore.pane_scrollback`.

### Component 5: Perf observability

New spans added to the existing PRD-0 hierarchy:

| Span name | Level | Location | Args |
|-----------|-------|----------|------|
| `conf.render.scrollback_wrap` | Debug | conf/mod.rs | `win_id`, `scrollback_bytes` |
| `save.capture.history_copy` | Debug | adapter/shell.rs | `win_id`, `hist_bytes` |
| `tmux.restore.pane_scrollback` | Info | restore.sh (via trace-lib) | `pane_id`, `scrollback_bytes` |

These spans integrate with the existing `ksession trace show` and
`ksession trace stats` commands for chrome-trace and histogram analysis.

### Component 6: Orphan cleanup for per-window history files

The shell hook writes to `~/.cache/ksession/hist/$KITTY_WINDOW_ID`.
Over time, windows close and their history files become orphans.

Cleanup strategy: during `fsx::sweep_orphans()` (already called at save
start), also scan `~/.cache/ksession/hist/`. For each file, check if the
corresponding `KITTY_WINDOW_ID` still exists in the current
`kitty @ ls` response. If not, and the file's mtime is older than
60 seconds, delete it.

This piggybacks on the existing orphan sweep lifecycle and uses the
same 60-second age guard to avoid races with windows that just opened.

### Installation surface

New Makefile target:

```make
HIST_HOOK_DIR ?= $(PREFIX)/share/ksession

install-shell-hook: scripts/ksession_shell_history.sh
    @mkdir -p $(HIST_HOOK_DIR)
    install -Dm644 scripts/ksession_shell_history.sh $(HIST_HOOK_DIR)/ksession_shell_history.sh
    @echo "Installed shell hook to $(HIST_HOOK_DIR)/ksession_shell_history.sh"
    @echo "Add to .bashrc/.zshrc: source $(HIST_HOOK_DIR)/ksession_shell_history.sh"
```

The `install-all` target is updated to include `install-shell-hook`.

### Model changes

`Program::Shell` gains two new fields:

- `scrollback: Option<PathBuf>` — path to the saved scrollback ANSI
  file for this window (populated during save, consumed by patcher)
- `history: Option<PathBuf>` — path to the per-window history file in
  the state dir (populated during save, consumed by patcher)

Both are `#[serde(default)]` for forward/backward compatibility with
existing manifests.

### Hybrid window ID scheme

During normal operation, the shell hook writes to a path keyed by
`KITTY_WINDOW_ID` (integer, available immediately at window creation).
On save, the shell adapter copies to a path keyed by `ksession_id`
(UUID, stable across save/restore cycles). On restore, `HISTFILE`
points to the UUID-keyed copy.

This bridges the gap between "hook needs an ID before first save" and
"restore needs a stable ID across sessions".

## Testing Decisions

Tests should verify external behavior, not implementation details. A
good test for this PRD asserts that a round-tripped session produces
specific artifacts on disk and specific launch lines in the rendered
`.conf`, without coupling to internal function signatures.

Prior art: `end_to_end_save.rs`, `synthetic_window_round_trip.rs`,
`nvim_cache_hit_smoke.rs` — all use the DCS mock server pattern with
fixture JSON/skeleton pairs.

### Modules to test directly

- **Patcher scrollback wrapping** — unit test golden table:
  input `Program::Shell` with/without scrollback path, with/without
  venv, with `--no-scrollback` flag. Assert rendered launch line matches
  expected string exactly. Cover: scrollback only, scrollback + venv,
  scrollback + oldpwd, no scrollback (unchanged), `--no-scrollback`
  flag (scrollback file exists but not emitted).

- **Shell adapter history copy** — unit test: create a temp dir with a
  mock `~/.cache/ksession/hist/42` file, run the copy logic, assert the
  file appears at `<state_dir>/history/<uuid>.hist` and the source file
  still exists (copy, not move). Cover: file exists (copied), file
  missing (field is None), file empty (copied as empty).

- **Shell integration hook** — shell test (bash and zsh):
  source the hook in a subshell with a mock `KITTY_WINDOW_ID=99`,
  run 3 commands, assert `~/.cache/ksession/hist/99` contains those
  3 commands. Also test the guard: unset `KITTY_WINDOW_ID`, source the
  hook, assert no file created.

- **Tmux pane scrollback codegen** — unit test: given a `TmuxPane`
  with a scrollback path, assert the generated `restore.sh` contains
  the `load-buffer`/`paste-buffer` sequence (or `cat`-before-exec)
  for that pane. Also test: pane without scrollback (no replay line),
  `--no-scrollback` flag (no replay line even with scrollback file).

- **Orphan history cleanup** — unit test: populate
  `~/.cache/ksession/hist/` with files for window IDs 1, 2, 3. Mock
  `kitty @ ls` returning only window 2. Assert files for 1 and 3 are
  deleted (respecting the 60s age guard).

### End-to-end tests to add

- **`shell_scrollback_round_trip.rs`** — fixture with a shell window
  and a saved scrollback file. Run save + render. Assert the `.conf`
  launch line contains `cat /path/to/scrollback.ansi 2>/dev/null; exec`.

- **`shell_history_round_trip.rs`** — fixture with a shell window and
  a mock per-window history file. Run save. Assert
  `<state_dir>/history/<uuid>.hist` exists. Assert the rendered `.conf`
  contains `--env HISTFILE=/path/to/uuid.hist`.

- **`shell_no_scrollback_flag.rs`** — same fixture but save with
  `--no-scrollback`. Assert the `.conf` launch line does NOT contain
  `cat`. Assert no scrollback file in state dir.

- **`tmux_pane_scrollback_restore.rs`** — fixture with a tmux session
  containing 2 panes with scrollback files. Assert the generated
  `restore.sh` contains replay commands for both panes.

- **`shell_hook_not_installed.rs`** — fixture with a shell window but
  no per-window history file in `~/.cache/ksession/hist/`. Assert save
  completes successfully, `Program::Shell.history` is `None`, rendered
  `.conf` has no `HISTFILE` override.

### Perf budget tests

- **`scrollback_wrap_perf_budget.rs`** — `#[ignore]` benchmark. Render
  a `.conf` with 12 shell windows each having a 50 KiB scrollback
  file path. Assert `conf.render` p50 increase over baseline (no
  scrollback) is ≤ 5 ms. The wrapping itself is string manipulation;
  the budget validates we're not accidentally reading file contents
  during rendering.

- **`history_copy_perf_budget.rs`** — `#[ignore]` benchmark. Copy 12
  history files (each ~10 KiB) during save. Assert
  `save.capture.history_copy` cumulative p50 ≤ 10 ms. The copy is a
  single `fs::copy()` per window; the budget validates filesystem
  overhead stays bounded.

- **`tmux_pane_scrollback_perf.rs`** — `#[ignore]` benchmark. Generate
  `restore.sh` for a 3-window × 3-pane tmux session with scrollback.
  Assert codegen time p50 increase is ≤ 2 ms (codegen just emits
  shell lines; no file I/O).

## Out of Scope

- **Scroll position restoration**: The viewport always starts at the
  bottom after scrollback replay. Restoring exact scroll position would
  require `kitty @ scroll-window` with a computed line count, adding
  timing sensitivity between `cat` completion and the scroll command
  for marginal benefit.

- **Non-bash/zsh shells**: The shell integration hook targets bash and
  zsh only. Fish, nushell, and others are out of scope. The hook no-ops
  for unrecognised shells.

- **History deduplication or merging**: Per-window history is strictly
  isolated. No merge with global HISTFILE, no dedup across windows.

- **Scrollback compression**: Scrollback files are stored as raw ANSI.
  Compression would add latency on the restore `cat` path for marginal
  disk savings.

- **Interactive scrollback search**: No viewer or search UI for saved
  scrollback. The file is `cat`'d into the terminal; the user scrolls
  with kitty's native scrollback.

## Further Notes

- ADR 0007 documents the design rationale for cat-before-exec and
  the hybrid ID scheme.
- The `--no-scrollback` flag (already exists, gates capture) is extended
  to also gate replay. One flag controls both directions.
- Scrollback files can be large (100K+ lines → multi-MB). The `cat`
  command streams through the PTY; it doesn't buffer the entire file.
  Terminal emulators process ANSI incrementally, so memory usage scales
  with visible viewport, not file size.
- The shell hook follows the install pattern established by PRD-8:
  Makefile target + user sources in rc file. The `install-all` target
  is updated.
- Cross-references:
  - ADR 0007 — design decision rationale for scrollback replay and
    hybrid ID scheme.
  - PRD-0 — new spans integrate with existing hierarchy at L3/L3.5.
  - `conf/mod.rs` — patcher logic for `Program::Shell` launch lines.
  - `adapter/shell.rs` — shell detection and capture.
  - `tmux_rpc/mod.rs` — `restore.sh` codegen.
  - `fsx/mod.rs` — orphan sweep (extended for history cleanup).
