# Agent session resume on restore

## Status

Accepted

## Context

Windows running interactive AI agent CLIs (`claude`, `pi`, `opi`, `omp`)
are captured as `Program::Raw { argv }`. Per ADR 0007's addendum, raw
TUIs restore with their argv exec'd directly on a clean PTY — no
scrollback cat-wrapper. The consequence: restoring a window that ran
`claude` just launches a fresh `claude`, and the conversation that was
live at save time is lost.

All of these agents support resuming the most recent conversation in
the current working directory via a `--continue` flag, and they key
sessions by cwd — which ksession already restores per window. The
missing piece is purely the flag.

## Decision

### Render-time argv rewrite via a rule table

At conf-render time, when a `Program::Raw` window's exe BASENAME (a
saved argv may be `/home/andrew/.local/bin/opi`) matches a row in
`AGENT_RESUME_RULES` (`src/conf/mod.rs`), the row's resume flag
(`--continue`) is appended to the emitted argv:

    launch --hold --var=ksession_id=<uuid> claude --continue

Rewriting at render time (restore side) means existing saved manifests
benefit immediately — no re-save required, and the manifest stays a
faithful record of what was actually running.

The table is a simple const slice of rules — exe basenames, resume
flag, skip-flags — so adding a new agent is one row (or one basename
appended to an existing row when the tool shares flags; `opi` and
`omp` are the same tool, `pi` is its sibling with identical session
flags).

### Skip conditions

The flag is NOT appended when the saved argv already carries any of
the rule's skip-flags, scanned across all argv elements in both the
`--flag value` and `--flag=value` forms (no full CLI grammar is
modeled — exact/prefix token matching only):

- `claude`: `-c`, `--continue`, `-r`, `--resume`, `--fork-session`,
  `--from-pr`, `-p`, `--print` — already resuming, or non-interactive.
- `pi`/`opi`/`omp`: `-c`, `--continue`, `-r`, `--resume`, `--session`,
  `--session-id`, `--fork`, `--no-session`, `-p`, `--print`. A
  `--no-session` window's session was never saved — `--continue`
  would resume an unrelated conversation, so it is left alone.

### Single choke point

The rewrite lives in the `Program::Raw` arm of `append_program_argv`,
which is the only place the conf renderer emits Raw argv — both
`patch_launch` paths (scrollback and direct; Raw always takes the
direct one per ADR 0007's addendum) funnel through it. The other Raw
argv consumers are deliberately untouched: `session/show.rs` is
display-only (it must show what was saved, not what restore will
run), and the tmux `restore.sh` codegen (`tmux_rpc`) respawns panes
inside a tmux session — a separate restore mechanism, out of scope
here; the helper can be reused there later if agents-in-tmux-panes
turn out to matter.

## Consequences

- **"Most recent in cwd" may not be the saved conversation.**
  `--continue` resumes whatever conversation is newest for that cwd;
  if the user started another conversation there after saving, restore
  picks that one up instead. Pinning the exact session would require
  capturing a session id at save time — a future, save-side feature.
- **`--no-session` windows restore fresh** by design; same for
  non-interactive (`-p`/`--print`) invocations and argvs that already
  carry an explicit resume/session flag.
- **No conversation in cwd:** these CLIs handle a `--continue` with
  nothing to continue gracefully (fresh session or a notice), and the
  launch keeps `--hold`, so a complaining exit stays visible.
- **Flag-table drift:** if an agent renames its flags, the table
  needs updating; unknown agents are simply not rewritten.
