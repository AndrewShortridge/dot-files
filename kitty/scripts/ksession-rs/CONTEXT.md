# ksession-rs

A Rust port of the legacy bash `ksession.sh` (retired; archived at
`~/.config/kitty/.scratch/archive/ksession.sh`) that captures the live
state of a kitty OS window — including embedded nvim editor state, less/man
file positions, shell venv/conda/oldpwd, tmux session structure, and ANSI
scrollback — into a kitty session file that restores the layout.

## Language

**Save**:
A user-initiated capture of one or more kitty OS windows into a `.conf` file
plus a sibling state directory. Invoked interactively from a kitty keybinding
via `ksession-save-prompt.sh`.

**Restore**:
Re-launching a saved session by passing its `.conf` to `kitty --detach
--session`. Reads no state outside the conf and its referenced sidecars.

**Session**:
The on-disk artifact pair `<name>.conf` + `<name>.gen-<ts_us>.state/`. The
conf is what kitty consumes; the state dir holds nvim mksession scripts,
buffer dumps, tmux `restore.sh`, scrollback, and a `manifest.json` summary.

**Sessions dir**:
The directory containing all sessions. Resolved from
`$KITTY_PROJECT_SESSIONS_DIR`, defaulting to
`$HOME/.config/kitty/sessions`. Inherited from the Bash implementation.

**Skeleton**:
The kitty-emitted `.conf` body produced by `kitten @ action save_as_session
--save-only --use-foreground-process`. Captures layout, tabs, and `launch`
lines for live windows. One skeleton per OS window — the orchestrator
concatenates multiple skeletons with a `new_os_window` separator.

**Patcher**:
The stage that consumes a skeleton and rewrites each `launch` line's argv
based on the corresponding captured program in the `SessionFile`. Correlation
uses the `--var ksession_id=<uuid>` token preserved verbatim through the
skeleton. Unrecognised tokens (e.g., `set_layout_state`) pass through
untouched.
_Avoid_: "renderer" — that's the wrapper around the patcher; the patcher
itself is patching, not generating.

**Adapter**:
A per-program capture strategy: `nvim`, `tmux`, `less`, `shell`, `raw`. Each
implements the `Adapter` trait with `detect()` + `capture()`. The `Registry`
dispatches the first matching adapter; failure degrades to the next or
ultimately to `Program::BareShell`.

**Synthetic window**:
A `model::Window` injected at capture time to represent a tab that filtered
to zero real kitty windows (every window was `is_self` or an overlay child).
Carries a reserved high `kitty_id >= SYNTHETIC_ID_FLOOR` (default
`u64::MAX - 1024`) so the patcher can distinguish it from a real window.
The §C.1 patcher emits a `launch /bin/bash -l` line for each synthetic
window so the tab survives restore.

**Gen-stamped state dir**:
The directory `<name>.gen-<ts_us>.state/` where `<ts_us>` is the
microseconds-since-epoch at save start. Allows concurrent re-saves to write
to fresh dirs without racing the previous generation. The `.conf` file
embeds absolute paths into a specific generation; a re-save replaces the
`.conf` atomically and the old generation becomes an orphan, swept on the
next save.
_Avoid_: "state dir" without qualifier — the Bash-era unqualified
`<name>.state/` directory still exists for legacy restore, and the two are
distinct.

**restore.sh**:
The shell script generated per tmux session inside the state dir
(`tmux/<sess>/restore.sh`). Encodes the full tmux session/window/pane
structure as a sequence of `new-session` / `new-window` / `split-window`
commands plus a final `attach-session` (`switch-client` when run with
`$TMUX` set, i.e. by `ksession tmux restore`). Canonical artifact for tmux
restore — the model's `Program::Tmux::windows` is a display summary, but
`restore.sh` is what kitty's `launch` line invokes at restore time.

**tmux-native session**:
A tmux session saved by `ksession tmux save` from inside a tmux client
(target resolved from `$TMUX` or `--session`), with no kitty involved. Lives
under its own root (`$KSESSION_TMUX_SESSIONS_DIR`, default
`~/.local/share/ksession/tmux-sessions`) as `<name>.json` + a gen-stamped
state dir, and is restored by running its `restore.sh` and switching the
current client. A separate namespace from kitty sessions: a tmux session
captured *inside* a kitty save is part of that kitty session, not a
tmux-native one. See [ADR 0009](docs/adr/0009-tmux-native-session-manager.md).
_Avoid_: "tmux session" alone — ambiguous between the live tmux object and
the saved artifact.

**Head file**:
The single file whose presence defines a saved session and names its live
state generation: `<name>.conf` for kitty sessions, `<name>.json`
(`TmuxSessionManifest`) for tmux-native sessions. Always written last by
`fsx::commit_session(…, ext)` — state dir fsynced, then an atomic rename.
The orphan sweep (`fsx::sweep_orphans_for(dir, ext)`) treats a gen-stamped
state dir with no head, or whose head points at a different generation, as
garbage once it is older than `fsx::SWEEP_MIN_AGE` (60 s); younger dirs
may belong to a save still in flight and wait for the next sweep. A
tmux-native re-save applies the same guard when it removes the generations
its new head superseded.

**Autosave stamp**:
The empty file `<tmux root>/.autosave-stamp` whose mtime throttles
`ksession tmux autosave`: when it is younger than `--every` (default 15 m)
and `--force` is absent, `autosave` exits 0 without saving. It is touched
when a sweep *starts*, so a slow sweep is never doubled by the next tick
and a failed one waits a full interval. Lets tmux.conf call `autosave`
from `status-right` on every `status-interval` tick cheaply — that tick is
the periodic timer — while the `client-detached` hook passes `--force`.
A sweep saves each session independently: one that fails is logged
(`ksession: tmux save <name>: …`) and the rest proceed, exit 2.

**capture_session**:
The pure, kitty-free core of the tmux adapter
(`adapter::tmux::capture_session`): given a tmux I/O handle, a session
ref, a state dir, the adapter registry and a proc root, it walks
windows → panes, recurses into each pane through the registry, captures
scrollback, renders `restore.sh`, and returns the `Program::Tmux` payload
plus a degraded-pane count. Both `TmuxAdapter::capture` (kitty path) and
`tmux_session::save` call it; it is the only implementation of "live tmux
session → files".
_Avoid_: "tmux adapter" when you mean this function — the adapter is the
kitty-context wrapper around it.

**Degraded window**:
A window whose adapter failed to capture and fell through to
`Program::BareShell`. The save still commits; degradations are surfaced via
stderr and a non-zero exit code (see [ADR 0001](docs/adr/0001-partial-capture-degrades-instead-of-aborting.md)).
_Avoid_: "failed window" — the window itself didn't fail, the save of its
program state did.

**Span**:
A timed scope in the perf observability layer carrying a name, start
instant, duration, parent id, and key=value args. Drops emit one
chrome-trace JSONL line per span. Span boundaries are placed at the L1–L5
ladder (phase / per-window / per-adapter / per-RPC / per-socket-IO) defined
in PRD-0. See [ADR 0004](docs/adr/0004-custom-span-tracer.md) for why this
is a hand-rolled type rather than `tracing::Span`.
_Avoid_: "event", "log entry" — events are point-in-time, spans are scoped.

**Trace**:
The collection of JSONL files produced by one save or restore invocation,
keyed by `~/.cache/ksession/traces/<rfc3339-ts>-<save|restore>-<name>/`.
Contains one JSONL file per contributing process (`rust-<pid>.jsonl`,
`tmux-<sess>.jsonl`, `nvim-<pid>.jsonl`). Merged on demand by
`ksession trace show` into a chrome-trace JSON or textual tree.
_Avoid_: "log", "profile" — a trace is the cross-process JSONL bundle, not
a single file or a sampled profile.

**Ready marker**:
File path inside a trace directory (`<trace_dir>/ready/<contributor>`)
touched by `restore.sh` immediately before `attach-session` and by the
final `VimEnter` autocmd in `ksession_restore.lua`. Used by
tree-mode-on-restore to know when all contributors have finished so the
JSONL bundle can be harvested and the tree printed. Part of the artifact
contract — emitted whether tracing is enabled or not.

**Kitty watcher**:
A Python module attached via the `watcher` option in `kitty.conf` or
`launch --watcher <path>`. Receives in-process kitty event callbacks
(`on_set_user_var`, `on_cmd_startstop`, `on_focus_change`, …) on the kitty
UI thread. Used by PRD-8 to react to nvim's OSC 1337 `nvim_dirty` user-var
emissions and trigger `:mksession!` proactively so the save path reads a
pre-captured session file. Requires kitty ≥ 0.28. See
[ADR 0006](docs/adr/0006-reopen-nvim-watcher-via-kitty-launch-watcher.md).
_Avoid_: "kitten", "daemon" — a kitten is a one-shot overlay program; a
watcher is an event hook module. They are distinct kitty primitives.

## Example dialogue

> **Me:** I hit save on a 4-tab kitty window, one tab has only an overlay
> child, what ends up on disk?
>
> **Future contributor:** The overlay child gets filtered (Phase 0.75), so
> the tab is empty. The orchestrator injects a synthetic window with
> `kitty_id = u64::MAX`, the patcher sees it lacks a skeleton `launch` line
> and emits `launch /bin/bash -l` for it. All four tabs survive restore.
> The `.conf` lives at `<name>.conf`, the state dir at
> `<name>.gen-1700000000000000.state/`.
>
> **Me:** And if the nvim in tab 2 had timed out during capture?
>
> **Future contributor:** That window is degraded — `Program::BareShell` in
> the manifest, stderr warns, save still commits, exit code 2. The user
> sees the warning in the save-prompt overlay and decides whether to
> re-run.
