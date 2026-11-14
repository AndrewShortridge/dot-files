# PRD-2: Tmux interrogation via persistent control-mode pipe

Status: ready-for-agent
Depends on: PRD-0 (`0002-observability-infrastructure.md`)

## Problem Statement

The tmux adapter at `src/tmux_rpc/` currently issues every tmux query
as a separate `Command::new("tmux").args(["display-message", "-p",
…])` subprocess invocation. Plan §5.4 documents ≥25 such per-window
queries (`list-clients`, `list-windows`, `list-panes`, multiple
`display-message` field reads per pane, `capture-pane`, etc.). On a
2-tmux-server × 4-pane workload, the fork+exec cost dominates: ~50 ms
× N panes × M fields ≈ 200–600 ms of pure subprocess overhead per
save, all of it serial because `Command::spawn` blocks on `wait()`.

Plan §B.3.2 specifies the replacement: one `tmux -C attach -r -t
'$<sid>'` control-mode pipe per (socket_path, server_pid) tuple,
spawned on first need and cached for the lifetime of the save. All
subsequent commands ride that pipe — one fork+exec per tmux server
total, not per query. The plan estimated ~210 ms win on the heavy
workload and deferred this to v1.1+ per PRD 0001.

This PRD lands §B.3.2 in full and validates the win against PRD-0
histograms.

## Solution

Implement `src/tmux_rpc/control.rs` per plan §B.3.2:

1. `TmuxControl::spawn(socket_path, server_pid)` — fork+execs `tmux
   -C attach -r -t '$<sid>'`, hooks up a tokio task that reads
   `%begin/%end` framed responses and dispatches to per-request
   oneshot channels.
2. `TmuxControl::request(cmd: &str) -> Result<Vec<String>, KError>` —
   sends a single command, awaits the response, returns parsed lines.
3. A `Mutex<HashMap<(PathBuf, u32), Arc<TmuxControl>>>` cache living on
   `SharedCtx` (per plan §B.3.2 input contract). First lookup spawns;
   subsequent lookups return the cached `Arc`.
4. Every per-pane / per-window query in `adapter::tmux::capture` is
   rewritten to call `TmuxControl::request(...)` instead of
   `Command::new("tmux")...`.
5. `capture-pane -p -C -e` reads stay subprocess-based (plan §B.3.2:
   capture-pane raw output is too large for control-mode framing
   without `-C`; the `-C` flag uses tmux's escape mechanism inside
   the begin/end frame, decoded client-side).
6. Shutdown is driven by Drop on `TmuxControl` — sends `kill-server`?
   No — closes stdin, lets tmux detach gracefully; the underlying
   tmux server is **never** killed by Drop (would lose the user's
   live tmux session).

PRD-0's `tmux.cmd.*` L4 spans wrap each `TmuxControl::request` call.
The success criterion is histogram-verifiable: heavy-workload
cumulative `tmux.cmd.*` p95 wall time drops from ~250 ms to under
~50 ms.

## User Stories

1. As a kitty user saving a session with 2 tmux servers × 4 panes
   each, I want the tmux portion of save wall time to drop from
   ~250 ms p95 to under 50 ms p95, so that the heavy-workload p95
   target of ~350 ms (plan §C.9) is actually reachable.

2. As the maintainer running `cargo test --release --test
   perf_save_budget -- --ignored` after this PRD lands, I want
   `tmux.cmd.*` cumulative latency to validate the win in the
   histogram, so that the PR description can cite a verifiable delta.

3. As a kitty user, I want the control-mode pipe to **never** kill or
   detach my live tmux session on save completion, so that I can keep
   working in tmux during/after a save.

4. As a kitty user whose tmux server hits the `CONTROL_MAXIMUM_AGE`
   5-minute output staleness timeout, I want the save to gracefully
   re-spawn the pipe rather than hanging the whole save, so that a
   rare edge case does not stall my workflow.

5. As the maintainer, I want the test suite to cover the
   `%begin/%end` framing edge cases (octal-decoded bytes, large
   capture-pane output, concurrent requests on one pipe, server
   disappearing mid-save), so that the control-mode parser doesn't
   regress silently.

## Implementation Decisions

### Module layout

- `src/tmux_rpc/control.rs` — new file.
  - `TmuxControl { stdin: Mutex<ChildStdin>, pending: Mutex<HashMap<u64,
    oneshot::Sender<Result<Vec<String>>>>>, next_id: AtomicU64,
    _reader_handle: JoinHandle<()> }`.
  - Reader task: parses `%begin <ts> <num> <flags>`, accumulates
    payload lines, fires the matching oneshot on `%end <ts> <num> <flags>`.
  - `%error` frames resolve the oneshot with `Err`.
- `src/tmux_rpc/mod.rs` — add `control` submodule; existing
  per-command helpers (`list_panes`, `display_message`, etc.) are
  rewritten to take `&TmuxControl` and call `.request(...)`.
- `src/session/save.rs` — `SharedCtx.tmux_servers:
  Arc<Mutex<HashMap<(PathBuf, u32), Arc<TmuxControl>>>>` initialised
  empty at save start.
- `src/adapter/tmux.rs` — `capture()` calls
  `get_or_spawn_control(socket_path, server_pid)` on first per-server
  query, threading the `Arc<TmuxControl>` through the rest of capture.

### Framing parser

Per plan §B.3.2 + tmux source. State machine:

```
Idle → %begin → Collecting(num, lines=vec![]) → line → Collecting(num, lines.push) 
              → %end (matches num) → resolve(num, Ok(lines)) → Idle
              → %error → resolve(num, Err) → Idle
              → %output / %session-changed / other notifications → drop (not subscribed)
              → %exit → cancel all pending, return reader task
```

Numbers (`num` token after `%begin`) identify which request; we issue
a monotonic counter per `request()` call and use it as the lookup key
in `pending`. The reader task holds no command-context — it's purely a
demuxer.

### Concurrent requests on one pipe

`TmuxControl::request` takes `&self`, holds the `stdin` Mutex only
across the write (~µs), then awaits its oneshot. Multiple tokio tasks
calling `.request` simultaneously serialize on the stdin write but
not on the response wait. Tmux processes commands sequentially anyway
(single-threaded server), so this is the right shape: minimize
stdin-mutex contention, parallelize the await.

### capture-pane handling

`capture-pane -p -C -e -t <pane>` payload can be large (multiple KiB
per pane, with octal-escaped non-printable bytes). It rides
control-mode like any other command — the `%begin/%end` frame can
carry arbitrarily many payload lines. Client-side, the reader
collects all lines between `%begin` and `%end`; the
`tmux_rpc::decode_octal` helper (plan §5.4) processes `\NNN` / `\134`
sequences.

### Output-age timeout

Tmux's `CONTROL_MAXIMUM_AGE` is 300000 ms (5 min). If a control-mode
client doesn't read fast enough, tmux disconnects. Since the reader
task runs in tokio and reads continuously into `Vec<String>`
accumulators, hitting the timeout requires a save to stall for 5
minutes — which means something else is wrong. Behaviour on
disconnect: reader sees `%exit` (or EOF), cancels all pending
oneshots with `Err(KError::TmuxControlDisconnected)`,
`adapter::tmux::capture` degrades the window to `Program::Raw {
argv: vec!["tmux".into()] }` and warn-logs. No retry; the next save
respawns from scratch.

### Lifecycle

- `TmuxControl::spawn` is called lazily via `get_or_spawn_control`
  from `adapter::tmux::capture`. First tmux window per save pays the
  ~50 ms fork+exec; subsequent windows on the same server pay ~1 ms
  per query.
- On save completion, `SharedCtx.tmux_servers` is dropped. Each
  `Arc<TmuxControl>`'s Drop sends `detach\n` to stdin, then closes
  stdin. The control-mode connection terminates; the underlying tmux
  server keeps running with the user's live session intact.
- `Drop` must **never** issue `kill-server` or `kill-session`.

### Span instrumentation

PRD-0's L4 wrapper on every `TmuxControl::request` call:

```rust
pub async fn request(&self, cmd: &str) -> Result<Vec<String>> {
    let _s = perf::span!(Level::Debug, "tmux.cmd", cmd = cmd);
    // ...
}
```

Args carry the command verb for histogram aggregation by subcommand
(`tmux.cmd` with `cmd="list-panes"` aggregates separately from
`cmd="display-message"`).

### Out of scope

- Subscribing to `%output` notifications. Save doesn't need pane
  output streamed; capture-pane is one-shot.
- Long-lived control connections that outlive a single save. The
  cache is per-save; reusing across saves would require lifecycle
  plumbing not justified by latency.
- Falling back to subprocess mode on control-mode failure. The
  degrade-to-`Program::Raw` path per ADR 0001 is the correct
  behaviour.
- Tmux < 2.6 compatibility. Control-mode framing changed in 2.6;
  older versions are out of scope per plan §1.

## Testing Decisions

A good test exercises the wire protocol shape and the degrade-on-error
behaviour. Internal struct fields stay private; tests interact via the
public `TmuxControl` API.

### Modules to test directly

- **`tmux_rpc::control::parse_frame`** — golden table of `(input_lines,
  expected_event)` covering: complete `%begin/payload/%end` frame,
  `%begin/%end` with no payload, `%error` frame, `%output` notification
  (must be dropped), `%exit`, malformed input (extra whitespace,
  missing num token). Pure parser test, no tokio.
- **`tmux_rpc::decode_octal`** — golden table covering `\134` (backslash),
  `\NNN` (printable), `\NNN` followed by non-octal char.

### End-to-end tests to add

- **`tmux_control_concurrent_requests.rs`** — spawn a real tmux
  server, issue 12 concurrent `list-panes` requests from 12 tokio
  tasks, assert all 12 return the same correct result and the reader
  task did not panic.
- **`tmux_control_large_capture.rs`** — capture-pane a 64 KiB
  scrollback, assert the full octal-decoded payload round-trips
  byte-for-byte.
- **`tmux_control_disconnect_degrades.rs`** — spawn a real tmux server,
  start a save, `kill -9` the tmux server mid-save, assert
  `adapter::tmux::capture` returns `AdapterError::TmuxControlDisconnected`
  and the window degrades to `Program::Raw` rather than crashing the
  save.
- **`tmux_control_drop_does_not_kill_server.rs`** — spawn a real tmux
  server, run a complete save, drop the `Arc<TmuxControl>`, assert the
  tmux server is still alive and the user's pre-existing session is
  intact.
- **`tmux_control_perf_budget.rs`** — `#[ignore]` benchmark, 30 iters
  of the heavy workload (2 servers × 4 panes), assert cumulative
  `tmux.cmd.*` p95 ≤ 50 ms.

### Existing tests that must keep passing

All `tests/tmux_*.rs` tests already in the suite (29 of them per the
directory listing). The behavioural contract of `adapter::tmux` does
not change; only its RPC transport.

### Tests intentionally not added

- Mocking the tmux server. Integration against the real binary is
  cheap and catches framing quirks (especially around %output and
  notification interleaving) that a mock would not.

## Out of Scope

- Eliminating the one remaining `capture-pane` subprocess
  invocation. Control-mode `capture-pane` is supported per §B.3.2;
  this PRD does that. There is no separate subprocess path left.
- Tmux command pipelining beyond what control mode naturally
  provides. The reader-task demuxer already supports concurrent
  requests; no further protocol changes needed.
- Tmux session collision handling on restore. That is in plan §5.4
  "Restore-time collision policy (KSESSION_FORCE)" and was already
  shipped.

## Further Notes

- This PRD reverses the explicit deferral in PRD 0001 "Out of Scope":
  "The §B.3.2 tmux control-mode transport (step 7.5). The
  field-per-call subprocess path stays in v1; control mode is a perf
  optimisation for v1.1+." PRD-0 + PRD-1 establish the measurement
  apparatus; this PRD then realises the deferred win.
- The plan's input contract for `adapter::tmux::capture` already
  threads `tmux_servers: &Mutex<HashMap<(PathBuf, u32),
  Arc<TmuxControl>>>` through `WindowCtx` (plan §C.10 "Step 7 ↔ Step
  8 input contract"). The shape is pre-designed; this PRD fills in
  the type that has been a `(...)` placeholder.
- Cross-references:
  - Plan §5.4 "tmux specifics" — canonical scope of in-control-mode
    behaviour.
  - Plan §B.3.2 — design.
  - PRD-0 — `tmux.cmd.*` L4 spans.
  - CONTEXT.md — Span, Trace.
