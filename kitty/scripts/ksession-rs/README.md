# ksession-rs

A Rust binary that captures the live state of a kitty OS window — including
embedded nvim editor state, less/man file positions, shell context, tmux
session structure, and ANSI scrollback — into a kitty session file that
restores the layout.

## Requirements

- Rust toolchain (stable)
- kitty >= 0.28 (for watcher support; older versions work without the watcher)
- nvim (for session capture/restore)

## Installation

```sh
# Core binary + restore lua
make install

# Proactive nvim cache (watcher + nvim plugin)
make install-watcher install-nvim-plugin

# Everything at once
make install-all
```

## Proactive nvim session cache

The watcher eliminates the ~200 ms `:mksession!` call during save by keeping
a pre-captured session file warm in the background.

### kitty.conf setup

After `make install-watcher`, add to your `kitty.conf`:

```
watcher ksession_kitty_watcher.py
```

Restart kitty (or open a new OS window) for the watcher to load.

### How it works

1. **nvim plugin** (`ksession_nvim_dirty.lua`) emits an OSC 1337
   `SetUserVar nvim_dirty=<unix_ms>` on `BufWritePost`, `CursorHold`,
   `VimLeavePre`, and `BufEnter`.
2. **kitty watcher** (`ksession_kitty_watcher.py`) receives the user-var
   callback, debounces, and triggers `:mksession!` on the nvim instance
   into a known cache path.
3. **Rust save path** checks the cache file's mtime against the last
   `nvim_dirty` timestamp. If fresh, it reads the file (~5 ms). If stale
   or missing, it falls back to live `:mksession!` (~200 ms).

### Graceful degradation

- Older kitty (< 0.28): watcher is ignored; save falls back to live
  `:mksession!` transparently.
- Missing watcher or nvim plugin: same fallback. No errors, no warnings.
- Cache race or stale file: detected by mtime check, live call issued.

Worst case equals current behaviour. Best case breaks through the
mksession floor.

### Tuning

| Variable | Default | Description |
|----------|---------|-------------|
| `KSESSION_WATCHER_DEBOUNCE_MS` | `500` | Minimum interval between successive `:mksession!` triggers per nvim instance |

### Troubleshooting

Check `~/.cache/ksession/watcher.log` for errors. The watcher logs
debounce events, mksession invocations, and any RPC failures.

```sh
tail -f ~/.cache/ksession/watcher.log
```

## tmux session manager

`ksession tmux …` saves and restores tmux sessions from inside any tmux
client, without kitty. It reuses the same per-pane adapters (nvim, shell,
less, raw), scrollback capture and `restore.sh` codegen as the kitty path,
but keeps its own storage root and its own bindings in
`~/.config/tmux/tmux.conf`. Design: [ADR 0009](docs/adr/0009-tmux-native-session-manager.md).

### Requirements

- tmux >= 3.3: the binary only needs `display-popup` (3.2), but the shipped
  tmux.conf passes `-T` to it and sets `popup-style`, `popup-border-style`
  and `popup-border-lines rounded` (global options, no `-b` on the binds),
  all of which arrived in 3.3
- fzf >= 0.43: the pickers gate cursor restore (`load:pos(N)`) on that
  version; older fzf still works with the cursor reset to the top row
- `~/.local/bin/ksession` must be a build that has the `tmux` subcommand
  (`make install` in `scripts/ksession-rs`); the scripts and the autosave
  tick call that path, not `target/debug`
- No Nerd font needed — the pickers use plain `●` / `○` / `*`.

### CLI

The target session is `--session <name>` if given, else the session owning
the current client (from `$TMUX`). Outside tmux without `--session` every
command that needs a session fails with
`ksession: tmux: not inside tmux (set --session)` (exit 1). Jobs tmux
spawns outside a session (`status-right '#()'`, hooks) get a `$TMUX` with
session id `-1`; there the socket still selects the server, so `--all` and
`--session` work but the no-flag default does not.

| Command | Flags | Effect |
|---|---|---|
| `ksession tmux save <name>` | `--session <s>`, `--no-scrollback` | Capture the session to `<name>.json` + a state dir. Exit 2 if any pane degraded. |
| `ksession tmux save --auto` | `--session <s>`, `--all`, `--no-scrollback` | Save as `auto-<session>` (invalid chars → `-`); never prompts; a session with no windows is skipped silently. `--all` enumerates the server (`--session` is ignored) and degrades per session: a session that fails to save (e.g. killed between the listing and the capture) is reported as `ksession: tmux save <name>: <error>`, the rest are still saved, and the exit code is 2. |
| `ksession tmux restore <name>` | `--force` | Run the saved `restore.sh`. Inside tmux the current client is switched to it; outside, the terminal attaches. If a live session of that name exists it is switched/attached to instead; `--force` kills and rebuilds it. |
| `ksession tmux list` | `--porcelain` | Table `NAME SESSION WINDOWS PANES SAVED NVIM`, sorted by name (`no saved tmux sessions` when empty). `--porcelain`: `name\tsession_name\twindows\tpanes\tcreated_at_rfc3339` per line (UTC, seconds, e.g. `2026-10-03T12:00:00Z`), no header, no colour. A head that fails to parse is skipped with `ksession: tmux list: skipping <name>: …` on stderr. |
| `ksession tmux show <name>` | — | Header (`session:`, `tmux session:`, `saved:`, `state:`, `restore:`) then the window → pane → program tree. |
| `ksession tmux rm <name>` | — | Delete the head file and every state dir for that name. |
| `ksession tmux autosave` | `--every <duration>` (default `15m`), `--force` | `save --auto --all`, skipped when the stamp is younger than `--every` unless `--force`. Writes nothing to stdout. |

`<name>` must match `^[A-Za-z0-9._-]+$`. `--every` accepts `<N>s`, `<N>m`,
`<N>h`, or a bare `<N>` meaning seconds (`90s`, `15m`, `1h`, `900`); zero
and other suffixes are rejected.

### Storage

```
$KSESSION_TMUX_SESSIONS_DIR/            # default ~/.local/share/ksession/tmux-sessions
├── <name>.json                         # head file: manifest (schema 1, tmux version, Program::Tmux)
├── <name>.gen-<ts_us>.state/           # the generation the head points at
│   ├── tmux/<session>/restore.sh
│   ├── tmux/<session>/win-N/pane-M/scrollback.ansi
│   └── nvim/…                          # per-pane adapter state
└── .autosave-stamp                     # mtime = start of the last autosave sweep
```

The head file is written last and atomically (state dir fsynced first, via
`fsx::commit_session`); its presence defines the session. Each save
allocates a fresh gen-stamped state dir, and once the new head is published
the generations it superseded are removed — except any younger than 60 s
(`fsx::SWEEP_MIN_AGE`), which may belong to a save still in flight (the
`client-detached` hook and the status tick can overlap) and are left for the
orphan sweep that runs at the start of every save. So a name normally has
one state dir, briefly two. Kitty sessions in `~/.config/kitty/sessions`
are a separate namespace and never appear here.

### Environment

| Variable | Default | Used by |
|---|---|---|
| `KSESSION_TMUX_SESSIONS_DIR` | `$XDG_DATA_HOME/ksession/tmux-sessions`, else `~/.local/share/ksession/tmux-sessions` | binary, scripts |
| `KSESSION_IMPL` | `~/.local/bin/ksession` | scripts — path to the binary (bare shell names and non-executables are rejected) |
| `KSESSION_SCRIPT_LIB` | `~/.config/kitty/scripts/lib` | scripts — where `frecency.sh` and `modal_fsm.sh` are sourced from |
| `TMUX` | set by tmux | binary — `<socket>,<server_pid>,<session_id>`; selects the server and the default session (`-1`, as tmux gives `#()` jobs and hooks, means no default session) |
| `KSESSION_TMUX_LOG` | `~/.cache/ksession.log` | scripts — diagnostics (picker dispatches, delete results) and `ksession`/tmux stderr from the picker, the save prompt and their preview panes |
| `FRECENCY_STORE` | `~/.cache/ksession-tmux-frecency.json` | scripts — picker frecency store; keys are `running:<tmux session>` and `saved:<name>` so a running session and a same-named save never share a score |
| `KSESSION_PICKER_NO_CONFIRM` | unset | scripts — `1` skips the y/N confirm on `d` (tests) |

### tmux.conf bindings

Prefix is `C-a`. Scripts live in `~/.config/tmux/scripts/` (shared helpers in
`lib/ksession-tmux-common.sh`) and run inside `display-popup`;
`FZF_DEFAULT_OPTS` is cleared there so the layouts below are deterministic.

| Key | Script | Action |
|---|---|---|
| `C-a s` | `ksession-picker.sh` | Sessions: running (`●`, `<name> · N windows · attached\|detached`, current marked `*` and sorted last) and saved-but-not-running (`○`, `<name> · [session ·] N windows · P panes`; the tmux session name is shown only when it differs from the save name), frecency-sorted. Preview: live screen (`capture-pane -ep`) or `ksession tmux show`, with stderr sent to `KSESSION_TMUX_LOG`. Enter switches to a live session or restores a saved one; a failed dispatch is shown and the popup stays open. |
| `C-a S` | `ksession-save-prompt.sh` | Save the current session. Query is pre-filled with the session name; Enter saves the name as typed, Tab completes from the highlighted saved name (no-op when nothing is highlighted), an empty query takes the highlighted row. Overwrite asks y/N. `✔ saved.` / `✘ save failed.`; exit 2 (degraded) holds the popup open. |
| `C-a f` | `ksession-picker.sh --panes` | Every window/pane on the server (`[sess:win.pane]  name · command · ~/path`) with a live preview; Enter switches to its session, window and pane. `d` is a no-op on pane rows. |

Picker keys (same modal FSM as the kitty picker, `lib/modal_fsm.sh`):

| Key | Mode | Action |
|---|---|---|
| `enter` | insert / normal | Open the selected row |
| `esc` | insert | Switch to normal mode |
| `esc`, `q` | normal | Quit |
| `i` | normal | Back to insert (type to filter) |
| `j` / `k` | normal | Down / up |
| `g` / `G` | normal | First / last |
| `ctrl-d` / `ctrl-u` | normal | Half page down / up |
| `d` | normal | Delete after y/N: `tmux kill-session` a running session or `ksession tmux rm` a saved one, then drop the row. Refused on the current session (`*`) — killing it would detach the client — with a message and an Enter prompt, row kept. A failed kill/rm likewise prints `delete '<name>' failed (rc=N), see <log>`, waits for Enter and keeps the row. No-op on pane rows. |
| `ctrl-c` | insert / normal | Quit |

### Autosave

`tmux.conf` runs `ksession tmux autosave --force` from a `client-detached`
hook and `ksession tmux autosave` from `status-right`. The status tick *is*
the periodic timer: tmux re-evaluates `status-right` every `status-interval`
(2 s), so its `#()` job runs every 2 s on each attached client even though
`status-right-length 0` keeps the bar empty. The tick exits immediately
while `.autosave-stamp` is younger than 15 minutes, so in steady state each
tick is one short-lived process and a stat. When a sweep is due the stamp
is touched first (a slow sweep is never doubled by the next tick, and a
failed one waits a full interval), then every session on the server is
saved as `auto-<session>`; a session that fails is logged and skipped
(exit 2) without aborting the others. Nothing is printed to stdout, so
`status-right` stays empty.

Both call `~/.local/bin/ksession`. Until `make install` has put a build
with the `tmux` subcommand there, every tick spawns a process that exits
2 with `unrecognized subcommand` — a silent no-op from the bar's point of
view. The binary's startup banner is logged at debug level so a tick does
not append to `~/.cache/ksession/ksession.log`.

To disable: remove the `set-hook -g client-detached …` line and the
`status-right '#(… autosave …)'` line from `~/.config/tmux/tmux.conf`.
To change the interval, pass `--every <duration>` in the `status-right`
command.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | OK (including `autosave` throttled and `restore` of an already-live session) |
| `1` | Fatal: not inside tmux, invalid name, unknown session, tmux error |
| `2` | Saved, but degraded (ADR 0001): a pane fell back to a weaker adapter, or — with `--auto --all` / `autosave` — one session failed to save; everything else is usable |

Fatal errors go to stderr as `ksession: tmux: <message>`, e.g.
`ksession: tmux: no saved tmux session 'foo'`; a tmux failure carries
tmux's own stderr text (`ksession: tmux: can't find session: dev`).
Non-fatal warnings name the command and item:
`ksession: tmux save <name>: pane degraded: …`,
`ksession: tmux save <name>: <error>`,
`ksession: tmux list: skipping <name>: …`.

## Uninstall

```sh
make uninstall-all
```
