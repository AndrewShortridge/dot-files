# PRD-14: Tmux-native session manager (`ksession tmux …`)

Status: ready-for-agent
Depends on: PRD-2 (`0004-tmux-control-mode.md`), PRD-13 (`0013-scrollback-replay-and-per-window-history.md`)
See also: ADR 0009 (`0009-tmux-native-session-manager.md`)

## Problem Statement

ksession captures tmux sessions only as a program embedded in a kitty
window. `ksession save` begins with `kitty @ ls` and hard-fails without
a reachable kitty, so there is no way to save, list, restore or delete
a tmux session from inside a tmux client. The tmux-side bindings
(`C-a s`, `C-a S`, `C-a f`) are tmux's own `choose-tree` and a
`new-session` prompt — no persistence, no fzf, no preview, none of the
modal picker UX the kitty side already has.

Everything below session discovery in `src/adapter/tmux.rs` is pure
tmux I/O: `list_windows`/`list_panes`, per-pane adapter recursion,
`capture-pane` scrollback, `RestoreScript` → `restore.sh` codegen. The
kitty coupling is confined to (a) finding the session for a kitty
window's foreground pid, (b) where the state dir lives, and (c) the
`attach-session` tail of `restore.sh`, which is wrong from inside a
tmux client.

## Solution

A `ksession tmux` subcommand group with its own storage root, driven
from `$TMUX`, that reuses the adapter's capture engine unchanged and
ships the tmux-side UX (fzf popup picker, save prompt, autosave) that
mirrors the kitty scripts.

1. **Refactor seam**: `TmuxAdapter::capture` is split into
   kitty-context resolution and a pure `capture_session(…)` that both
   the adapter and the new `tmux_session::save` call.
2. **New module `src/tmux_session/`**: `mod.rs` (root dir, name
   validation, target resolution from `$TMUX`/`--session`, dispatch),
   `manifest.rs`, `save.rs`, `restore.rs`, `list.rs`, `show.rs`,
   `rm.rs`, `autosave.rs`. Typed `TmuxSessionError` (thiserror);
   `anyhow` only in the bin.
3. **Codegen**: the `restore.sh` tail becomes a runtime branch —
   `switch-client` when `$TMUX` is set, `attach-session` otherwise.
4. **tmux-side scripts** under `~/.config/tmux/scripts/`:
   `ksession-picker.sh` (sessions, `--panes`), `ksession-save-prompt.sh`,
   sharing `lib/frecency.sh` and `lib/modal_fsm.sh` with the kitty
   scripts.
5. **tmux.conf**: `C-a s`/`S`/`f` rebound to `display-popup` wrappers;
   popup styles; `client-detached` hook + `status-right` tick for
   autosave.

## User Stories

1. As a tmux user inside a session, I want `C-a S`, type a name, Enter
   to save the current session (windows, panes, cwds, layout,
   scrollback, nvim state), so that I can get it back after a reboot.

2. As a tmux user, I want `C-a s` to show one fzf list of running
   sessions and saved-but-not-running sessions, with a preview, so that
   Enter switches to a live one or restores a saved one.

3. As a tmux user restoring a session whose name is already live, I
   want to be switched to the live one (not a duplicate), and I want
   `--force` to rebuild it from the save, so that restore is safe to
   repeat.

4. As a tmux user, I want `d` in the picker's normal mode (after y/N)
   to kill a running session or delete a saved one, so that I can prune
   from the same UI.

5. As a tmux user, I want `C-a f` to list every window/pane on the
   server with a preview and jump to the chosen pane, replacing
   `choose-tree -Zw`.

6. As a tmux user who detaches or just keeps working, I want every
   session autosaved as `auto-<session>` on detach and at most every
   15 minutes, so that a crash loses little — without ever being
   prompted or seeing output in the status bar.

7. As a kitty user, I want `ksession save/restore/list/show/rm` and my
   existing kitty session files to behave exactly as before, so that
   the tmux feature is purely additive.

8. As a scripter, I want `ksession tmux list --porcelain` to emit a
   stable tab-separated, header-less, colour-free row per session, so
   that the picker and tests can consume it without parsing a table.

9. As a user outside tmux, I want `ksession tmux save x --session dev`
   to work against the default server, and `ksession tmux save x` with
   no `--session` to fail with `ksession: tmux: not inside tmux (set
   --session)`, so that the target is never guessed.

10. As the maintainer, I want the standalone path to reuse
    `capture_session`, `render_restore_sh`, `fsx::write_atomic`,
    `fsx::StateTmpdir`, `session::restore::validate_name` and the
    `session::show` tree helpers, so that there is one implementation
    of each.

11. As the maintainer, I want degraded panes (adapter failure) to still
    commit the save with exit 2 and a stderr warning (ADR 0001), so
    that a flaky nvim does not lose the rest of the session.

## Implementation Decisions

### CLI (`src/cli/tmux.rs`, `Command::Tmux { command }` mirroring `Trace`)

| Command | Flags | Behaviour |
|---|---|---|
| `tmux save <name>` | `--session <s>`, `--no-scrollback` | Capture one session into `<root>/<name>.json` + state dir. Exit 2 if any pane degraded. |
| `tmux save --auto` | `--session <s>`, `--all`, `--no-scrollback` | Name = `auto-<sanitised session_name>` (chars outside `[A-Za-z0-9._-]` → `-`). `--all` = every session on the server (`--session` ignored), degrading per session: a save that fails is reported `ksession: tmux save <name>: <error>`, the rest continue, exit 2. Empty session skipped silently. Never prompts. |
| `tmux restore <name>` | `--force` | Run saved `restore.sh` under bash with `TMUX` passed through. Live session of that name: switch/attach, exit 0, stderr note; `--force` → `KSESSION_FORCE=1` rebuild. Unknown → exit 1 `no saved tmux session '<name>'`. |
| `tmux list` | `--porcelain` | Human table sorted by name: `NAME SESSION WINDOWS PANES SAVED NVIM`; empty → `no saved tmux sessions`. Porcelain: `name\tsession_name\twindows\tpanes\tcreated_at_rfc3339`, no header. Unparseable head → `ksession: tmux list: skipping <name>: …`, row dropped. |
| `tmux show <name>` | — | `session:`, `tmux session:`, `saved:`, `state:`, `restore:` lines, then the window → pane → program tree via `session::show::render_tmux_windows` (the one helper made `pub(crate)`). |
| `tmux rm <name>` | — | Tombstone-rename then delete head + every `<name>.gen-*.state/`. Nothing matched → exit 1. |
| `tmux autosave` | `--every <dur>` (default `15m`), `--force` | If `<root>/.autosave-stamp` is younger than `--every` and no `--force` → exit 0 silently; else touch stamp, then `save --auto --all`. Never writes stdout. |

Target resolution: name validated first (`session::restore::validate_name`,
`^[A-Za-z0-9._-]+$`, before any tmux subprocess), then `--session`, else
the session owning the current client from the process's own `$TMUX`
(`tmux_rpc::parse_tmux_env` → socket path + `Option<u32>` session id,
`None` for the `-1` tmux gives `status-right '#()'` jobs and hooks) matched
against that server's `list-sessions`. `--all` enumerates the same listing
and needs no session id. All tmux subprocesses use `tmux -S <socket_path>`.

### Storage

Root: `$KSESSION_TMUX_SESSIONS_DIR` → `$XDG_DATA_HOME/ksession/tmux-sessions`
→ `~/.local/share/ksession/tmux-sessions` (`create_dir_all`).

- `<root>/<name>.json` — head file, `TmuxSessionManifest { name,
  created_at, schema: 1, tmux_version, state_dir, program:
  Program::Tmux{…} }`, pretty JSON, published last by
  `fsx::commit_session(…, "json")` (state dir fsynced, then atomic
  rename). Additive fields use `#[serde(default)]` (ADR 0003).
- `<root>/<name>.gen-<ts_us>.state/` — allocated with
  `fsx::gen_stamp_basename` inside `fsx::StateTmpdir` (Drop-cleans on
  failure). Contains `tmux/<session_name>/restore.sh`,
  `tmux/<session_name>/win-N/pane-M/scrollback.ansi`, `nvim/…` — the
  adapter's existing layout, with this dir as its `state_dir`.
- `<root>/.autosave-stamp` — empty file; mtime is the throttle, touched
  when a sweep starts.
- Orphan sweep on every save: `fsx::sweep_orphans_for(root, "json")`
  removes state dirs older than `fsx::SWEEP_MIN_AGE` (60 s) whose head is
  missing or points elsewhere. The existing `sweep_orphans(dir)` becomes
  `sweep_orphans_for(dir, "conf")` for the kitty path, and
  `commit_session` takes the same head-extension parameter.
- Superseded generations: after publishing, a save deletes the other
  `<name>.gen-*.state/` dirs under the same age guard — anything younger
  than 60 s may be a concurrent save (hook + status tick) still writing,
  and is left for the next sweep.

### Refactor seam (`src/adapter/tmux.rs`)

```rust
pub(crate) fn capture_session(
    io: &dyn TmuxIo, session: &SessionRef, state_dir: &Path,
    registry: &Registry, proc_root: &Path, scrollback: bool,
) -> Result<CapturedTmuxSession, TmuxCaptureError>
```

Walks windows/panes, recurses through the registry via the existing
synthetic pane ctx, captures scrollback, builds `RestoreScript`,
renders `restore.sh`, returns the `Program::Tmux` payload and the
degraded-pane count. `TmuxAdapter::capture` keeps only the
kitty-context half (session for fg pid, `TMUX` env sources, degrade to
`Program::Raw`). `state_dir_is_inside_tmux` is untouched.

### Codegen (`tmux_rpc::render_restore_sh`, `templates/tmux_restore_header.sh`)

Every `exec tmux attach-session -t "=$SESS"` becomes:

```sh
if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "=$SESS"; else exec tmux attach-session -t "=$SESS"; fi
```

Kitty restores run in a fresh window (`TMUX` unset) → unchanged.

### Exit codes and diagnostics

`0` ok, `1` fatal (`TmuxSessionError`, typed — tmux failures keep
`TmuxError` via `Tmux(#[from] TmuxError)` — printed by the bin as
`ksession: tmux: <message>`), `2` saved-but-degraded (ADR 0001: a pane
degraded, or one session of a `--auto --all` / `autosave` sweep failed).
Per-item warnings name the command and item: `ksession: tmux save
<name>: pane degraded: …`, `ksession: tmux save <name>: <error>`,
`ksession: tmux list: skipping <name>: …`. Perf spans via `perf::span!`
at the same levels as `adapter/tmux.rs`.

### Picker UX (`~/.config/tmux/scripts/`)

- Libs from `${KSESSION_SCRIPT_LIB:-$HOME/.config/kitty/scripts/lib}`
  (`frecency.sh`, `modal_fsm.sh`); binary
  `${KSESSION_IMPL:-$HOME/.local/bin/ksession}` validated as in
  `ksession-save-prompt.sh`.
- `ksession-picker.sh`: rows = running sessions (`●` green,
  `<name> · <N> windows · attached|detached`, current marked `*`
  magenta and sorted last) + saved sessions from `list --porcelain`
  not currently running (`○` blue, `<name> · [session ·] <N> windows ·
  <P> panes`). Frecency-sorted with namespaced keys (`running:<session>`,
  `saved:<name>`) from one `frecency_dump` per run. Same insert/normal
  FSM and fzf flags as kitty's `session-picker.sh` with
  `--height=100%`; the modal driver is a copy kept in sync by comment,
  not a shared lib. Preview: running → `tmux capture-pane -ep -t
  '=<sess>'`; saved → `ksession tmux show <name>`, stderr to
  `$KSESSION_TMUX_LOG`. Enter: running → `switch-client`; saved →
  `ksession tmux restore`; a failed dispatch is shown and the popup
  stays open. `d` (y/N): running → `kill-session`; saved → `ksession
  tmux rm`; refused on the current session (killing it would detach the
  client) and on failure the row is kept, the error printed and Enter
  awaited. Blank/malformed porcelain lines are skipped. Esc/Ctrl-C →
  exit 0.
- `ksession-picker.sh --panes`: rows from `tmux list-panes -a -F`,
  preview `capture-pane -ep -t <pane_id>`, Enter → `switch-client` +
  `select-window` + `select-pane`; `d` is a no-op.
- `ksession-save-prompt.sh`: fzf `--print-query` over
  `list --porcelain` names, same validation and overwrite confirm as
  the kitty prompt, default query = current session name, Tab completes
  the highlighted name (no-op when nothing is highlighted), dispatch
  `ksession tmux save "$name"`, `✔ saved.` / `✘ save failed.`,
  auto-close 2 s (exit 2 holds the popup open).
- tmux.conf: `bind s`/`S`/`f` → `display-popup -E -w … -h … -T ' … '`
  around the scripts; `popup-style "bg=$BG,fg=$FG"`,
  `popup-border-style "fg=$SURFACE"`, `popup-border-lines rounded`
  (global options — the binds pass no `-b`); `%hidden MAGENTA` documents
  the ANSI-5 colour the scripts emit, which they take from the
  terminal's palette rather than this variable; `set-hook -g
  client-detached 'run-shell -b "… autosave --force"'`;
  `status-right '#(… autosave >/dev/null 2>&1)'` (visually empty;
  commented) is the periodic timer since `status-right` is re-evaluated
  every `status-interval 2`. Both call `~/.local/bin/ksession`, so
  `make install` is a landing prerequisite (noted in the tmux.conf
  comment); until then each tick is a failing no-op.

## Testing Decisions

Tests assert external behaviour — files on disk, stdout/stderr, exit
codes, and the live tmux server's state after restore — by spawning
`env!("CARGO_BIN_EXE_ksession")` with `KSESSION_TMUX_SESSIONS_DIR` set
to a `tempdir()` and `TMUX=<socket>,<pid>,<sid>` pointing at a scratch
server. The per-file `IsolatedTmux`/`unique_socket`/`tmux_available`
pattern is factored once into `tests/helpers/tmux.rs` and the four
existing copies migrate to it; it exposes `tmux_env()`.

### Modules to test directly

- **`tmux_session::manifest`** — `head_path`, `write` then `read`
  round-trip, `read` of a missing head → `NotFound`, `list_names`
  sorted and ignoring non-`.json` entries.
- **`tmux_session::mod`** — `validate_name` accept/reject table;
  auto-name sanitising (`my session!` → `auto-my-session-`); root
  resolution precedence (`KSESSION_TMUX_SESSIONS_DIR` > `XDG_DATA_HOME`
  > `HOME`).
- **`tmux_session::list`** — porcelain row format byte-exact; human
  table header and empty-root message.
- **`tmux_session::autosave`** — stamp younger than `--every` → no
  save; older → save + stamp touched; `--force` bypasses; stdout empty.
- **`tmux_rpc`** — existing attach-line assertions updated to the
  `if [ -n "${TMUX:-}" ] …` tail; `parse_tmux_env` maps a `-1` session
  id to `None`.
- **`adapter::tmux::capture_session`** — with a stub `TmuxIo`:
  `scrollback=false` never calls `capture_pane_to_file`; an empty capture
  removes the sidecar.
- **`fsx::sweep_orphans_for` / `fsx::commit_session`** — `"json"` head
  ext sweeps state dirs with no head and publishes the manifest bytes;
  `"conf"` behaviour identical to the old `sweep_orphans` /
  `commit_session`.

### End-to-end tests to add

- **`tests/tmux_cli_save_restore.rs`** — build a 2-window / 3-pane
  session with distinct cwds and a layout on a scratch server; `tmux
  save`; assert head JSON, `restore.sh`, scrollback files;
  `kill-session`; `tmux restore --session`; assert windows/panes/cwds/
  layout match; restore again without `--force` switches/attaches to
  the live one; `--force` rebuilds.
- **`tests/tmux_cli_list_show_rm.rs`** — porcelain format, human
  table, `show` tree and header lines, `rm` tombstone + state-dir
  removal, orphan sweep on the next save.
- **`tests/tmux_cli_autosave.rs`** — auto naming/sanitising, `--all`,
  throttle stamp honoured, `--force` bypass, stdout empty; a re-save
  removes the superseded generation only once it is older than 60 s
  (the first state dir's mtime is backdated to prove the deletion);
  with two sessions, one killed between the listing and the save, the
  other is still saved and the exit code is 2.
- **`tests/tmux_cli_errors.rs`** — no `TMUX` and no `--session` → exit
  1 with the exact message; bad names (rejected before any tmux call);
  unknown session; exit codes.
- **`~/.config/tmux/scripts/tests/`** — bash smoke tests driving the
  picker and save prompt against a scratch server with a stub
  `KSESSION_IMPL` that records argv (pattern: `kitty/scripts/tests/*`):
  sessions mode including the running-row Enter path, deleting the last
  row exits 0, `d` on the current session is refused, a failed kill/rm
  keeps the row, `--panes` rows and Enter dispatch, pane `d` no-op.

All guard with the tmux-available early-return convention.

### Existing tests that must keep passing

- `tmux_control_mode_protocol.rs`, `tmux_control_safety.rs`,
  `tmux_layout_preserved_on_save.rs`, `perf_tmux_control_budget.rs`
  (migrated to the shared helper, behaviour unchanged).
- Every `tmux_*.rs` kitty-path test — `capture_session` extraction is
  behaviour-preserving.
- `tmux_rpc` unit tests (attach-line assertions updated, nothing else).
- `conf_golden.rs` and the `restore-baseline` fixtures — kitty conf
  rendering is untouched.
- `session::rm` / orphan-sweep tests — `sweep_orphans_for(dir, "conf")`
  is the old function.

### Tests intentionally not added

- No real-kitty round-trip for the tmux path — it has no kitty leg.
- No perf-budget benchmark for `tmux save`; it is the adapter's
  existing capture under `perf::span!`, already budgeted by
  `perf_tmux_control_budget.rs`.
- No test of `display-popup` rendering or tmux.conf parsing — the
  bindings are exercised only via the script smoke tests' recorded
  argv.
- No cross-server `--session` test (tmux `-L`/`-S` selection is
  tmux's contract, not ours).

## Out of Scope

- Any change to kitty-driven `ksession save/restore/list/show/rm`
  behaviour or the `~/.config/kitty/sessions` layout.
- TPM / plugin packaging; the scripts are plain files under
  `~/.config/tmux/scripts/`.
- A unified picker showing kitty and tmux saves together.
- Restoring into a *different* server than the one `$TMUX`/`--session`
  names, or migrating saves between machines.
- Agent-resume argv rewriting (ADR 0008) inside tmux panes — the
  `restore.sh` codegen is unchanged apart from the tail.
- New crates.

## Further Notes

- ADR 0009 records the rationale for `$TMUX` resolution, the separate
  storage root, the single `capture_session` engine, the runtime
  attach/switch branch, the stamp-throttled autosave and the 60 s
  guard on superseded generations.
- `KSESSION_FORCE` already exists in the `restore.sh` header; `--force`
  simply sets it.
- The picker's `*` current-session marker is magenta and the saved
  bullet blue: the scripts emit raw ANSI-16 codes (5 and 4), which the
  terminal maps onto the One Dark palette. tmux.conf's `%hidden
  MAGENTA` only documents that mapping; nothing reads it.
- Cross-references:
  - `src/adapter/tmux.rs` — `capture_session` seam,
    `state_dir_is_inside_tmux`.
  - `src/tmux_rpc/mod.rs` — `parse_tmux_env` (`TmuxEnvInfo.session_id:
    Option<u32>`), `render_restore_sh`.
  - `src/fsx/mod.rs` — `gen_stamp_basename`, `StateTmpdir`,
    `commit_session` and `sweep_orphans_for` (head-extension parameter),
    `SWEEP_MIN_AGE`.
  - `src/session/show.rs` — `render_tmux_windows` made `pub(crate)`.
  - `src/session/restore.rs` — `validate_name`.
  - `~/.config/tmux/tmux.conf` — bindings, popup styles, autosave hook
    and status tick (with the `make install` note).
  - CONTEXT.md — tmux-native session, head file, autosave stamp,
    capture_session.
