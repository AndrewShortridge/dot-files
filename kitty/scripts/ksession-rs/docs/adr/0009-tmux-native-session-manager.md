# Tmux-native session manager

## Status

Accepted

## Context

ksession already captures tmux sessions — but only as a program running
inside a kitty window. The tmux adapter (`src/adapter/tmux.rs`) finds
the session owning a kitty window's foreground process, walks its
windows and panes through the adapter registry, captures scrollback,
and renders a `restore.sh` into the kitty session's state dir. The
entry point is `ksession save`, which starts by snapshotting kitty via
`kitty @ ls` and hard-fails without a reachable kitty.

There was no way to save or restore a tmux session from *inside* a tmux
client: the existing `C-a s` / `C-a S` / `C-a f` bindings were tmux's
own `choose-tree` and a `new-session` prompt. Everything the adapter
does after session discovery is pure tmux subprocess/control-mode I/O
with no kitty dependency, so the capture engine is reusable; only the
orchestration (which session, where to put the files, how to come back
to it) is kitty-shaped.

Constraints: the kitty-driven `save/restore/list/show/rm` behaviour and
on-disk layout must not change; the existing `tmux_*` tests must stay
green; no new crates; the standalone path must honour ADR 0001
(degrade, don't abort) and the existing stderr / perf-span conventions.

## Decision

### Resolve the target from `$TMUX`, not from kitty

`ksession tmux …` reads the process's own `$TMUX` env var
(`<socket_path>,<server_pid>,<session_id>`, parsed by
`tmux_rpc::parse_tmux_env`; the session id is `-1` — `None` — when tmux
spawned the job outside a session, as it does for `status-right '#()'`
and hooks) and resolves the session name from that server's
`list-sessions`. `--session <name>` overrides the session (and is the
only way to run outside a tmux client); `--all` enumerates the server
and needs no session id. Every tmux subprocess targets that socket with
`-S`.

The kitty path has to go through `find_session_for_client_pid` because
the save doesn't know a priori which tmux session a given kitty
window's foreground process is attached to. Inside tmux the caller *is*
that client, so `$TMUX` is both simpler and exact. Not inside tmux and
no `--session` is a fatal error (`ksession: tmux: not inside tmux (set
--session)`, exit 1) rather than a guess.

### Separate storage root

Saved tmux sessions live under
`$KSESSION_TMUX_SESSIONS_DIR` → `$XDG_DATA_HOME/ksession/tmux-sessions`
→ `~/.local/share/ksession/tmux-sessions`, not in kitty's
`~/.config/kitty/sessions`. Each session is a `<name>.json` head file
(a `TmuxSessionManifest` carrying the `Program::Tmux` payload, schema
1) plus a `<name>.gen-<ts_us>.state/` directory laid out exactly as the
adapter already lays out its `tmux/<sess>/…` subtree.

Why not reuse `<name>.conf` + `SessionFile`: a kitty session file's
root is an OS-window/tab/window tree that kitty consumes; a tmux
session has one top-level thing (the session) and nothing for kitty to
read. Wrapping it in a fake 1×1×1 tree would round-trip, but `list`,
`show` and the kitty picker key discovery on `*.conf` and would start
showing tmux saves as kitty sessions. Keeping the roots apart means no
`.conf` coupling and no orphan-sweep interplay — the sweep and the
publish step are generalised to take the head-file extension
(`fsx::sweep_orphans_for`, `fsx::commit_session`) instead of being
copied, so the tmux head gets the same fsync-then-rename guarantee as
the kitty conf.

A re-save removes the generations its new head superseded right after
publishing, but only those older than `fsx::SWEEP_MIN_AGE` (60 s). A
younger sibling may be a save still in flight — the `client-detached`
hook and the status tick can save the same `auto-<session>` at once —
and deleting it would publish a head whose state dir is gone. Young
leftovers are reclaimed by the orphan sweep at the start of the next
save, which applies the same age guard.

### One capture engine: `capture_session`

`TmuxAdapter::capture` is split into kitty-context resolution (find
session for fg pid, `TMUX` env sources, degrade decisions) and a pure
`capture_session(io, session, state_dir, registry, proc_root,
scrollback)` that walks windows/panes, recurses through the registry
via the existing synthetic pane ctx, captures scrollback, renders
`restore.sh`, and returns the `Program::Tmux` payload plus a degraded
pane count. Both the kitty adapter and `tmux_session::save` call it.
There is exactly one implementation of "turn a live tmux session into
files".

`tmux_session::save` hands `capture_session` the subprocess transport
(`TmuxCli::at_socket`), never the control-mode pipe the kitty adapter
prefers. A control-mode attach is a tmux client, and its detach fires
`client-detached` — the hook that the shipped tmux.conf points at
`ksession tmux autosave --force`. With the pipe, every autosave
re-triggered itself on detach (measured: ~2,700 state dirs in one
minute before the loop was found). Subprocess I/O creates no client, so
a save is invisible to hooks; `tests/tmux_cli_save_restore.rs`
(`save_never_attaches_a_client_so_detach_hooks_stay_quiet`) pins it.
The per-field fork cost is irrelevant at tmux-session scale.

### Runtime `$TMUX` branch in `restore.sh`

`restore.sh` used to end in `exec tmux attach-session -t "=$SESS"`,
which is right from a fresh kitty window and wrong from inside a tmux
client (nested attach). Rather than render two script variants, the
codegen emits one tail:

    if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t "=$SESS";
    else exec tmux attach-session -t "=$SESS"; fi

The kitty path runs the script in a fresh window where `TMUX` is unset,
so its behaviour is unchanged; `ksession tmux restore` runs it with
`TMUX` passed through and the current client is switched. The existing
`KSESSION_FORCE` semantics carry over: a live session of the same name
is switched/attached to unless `--force` rebuilds it.

### Autosave: hook + status tick, throttled by a stamp

`ksession tmux autosave` wraps `save --auto --all` (names
`auto-<sanitised session>`, empty sessions skipped, never prompts)
behind an mtime check on `<root>/.autosave-stamp`: younger than
`--every` (default 15m) and no `--force` → exit 0 silently. tmux.conf
fires it from a `client-detached` hook (`--force`) and from
`status-right '#(… autosave …)'`; that tick is the periodic timer,
because tmux re-evaluates `status-right` every `status-interval` (2 s)
for each attached client regardless of `status-right-length 0`. The
stamp lives in the binary so the tmux side stays a one-liner and the
tick is cheap when nothing is due; it is touched *before* the sweep so
the next tick cannot double a slow sweep. The command never writes to
stdout because its stdout *is* the status line, and its startup banner
is logged at debug level so a tick leaves no trace in the log file.

A sweep degrades per session (ADR 0001): a session that disappears
between `list-sessions` and its capture — a real race on a 2 s timer —
is reported as `ksession: tmux save <name>: …`, the remaining sessions
are still saved, and the exit code is 2.

Both tmux.conf call sites use `~/.local/bin/ksession`; `make install`
is part of landing this, since an older binary there turns every tick
into a failing (if silent) process.

### Picker and save prompt port the kitty scripts

`~/.config/tmux/scripts/ksession-picker.sh` and
`ksession-save-prompt.sh` reuse `lib/frecency.sh` and
`lib/modal_fsm.sh` from the kitty scripts dir (`$KSESSION_SCRIPT_LIB`)
and the same fzf invocations, swapping the four kitty call sites
(`kitty @ ls`, `focus-window`, `close-os-window`, `get-text`) for
`list-sessions`, `switch-client`, `kill-session`, `capture-pane`. They
run inside `tmux display-popup`. Two tmux-specific rules: `d` refuses
the current session, because `kill-session` on the popup's own session
would detach the client under the default `detach-on-destroy`; and a
failed kill/rm keeps the row and shows the error rather than silently
dropping it. Frecency keys are namespaced (`running:<session>`,
`saved:<name>`) so a running session and a save of a different session
that happen to share a name do not share a score.

## Consequences

- **Kitty path untouched.** The adapter's kitty-context half, the
  `.conf` layout, `session::*` and the kitty scripts are unchanged; the
  only shared-code changes are the `capture_session` extraction, the
  `restore.sh` tail, the head-extension parameter on
  `fsx::sweep_orphans_for` / `fsx::commit_session`, and
  `TmuxEnvInfo.session_id` becoming `Option<u32>`.
- **Two session namespaces.** A kitty session named `work` and a tmux
  session named `work` are unrelated files in different roots. The tmux
  picker lists only tmux saves; the kitty picker lists only kitty
  saves. A tmux session captured as part of a kitty save is not visible
  to `ksession tmux list`.
- **`$TMUX` is trusted.** A stale or forged `TMUX` value produces a
  tmux error, surfaced on stderr as `ksession: tmux: <tmux's own
  message>` (e.g. `session $3 from $TMUX no longer exists`) with exit
  1 — no fallback to `list-clients` heuristics.
- **Switch, not attach, inside tmux.** `restore` from a tmux client
  replaces the client's session; the previous session keeps running
  detached. From outside tmux (with `--session`) it attaches the
  calling terminal, as the kitty path does.
- **Autosave churn.** Every detach and every 15 minutes rewrites every
  `auto-*` head and allocates a fresh gen-stamped state dir per
  session; the superseded generation is removed at publish time if it
  is older than 60 s, otherwise by the next save's orphan sweep, so the
  disk cost is one live generation per name, briefly two. Disable by
  removing the hook and the `status-right` tick from tmux.conf.
- **Nested tmux still degrades.** `state_dir_is_inside_tmux` is
  unchanged: a tmux pane running another tmux is captured as
  `Program::Raw { argv: ["tmux"] }`.
