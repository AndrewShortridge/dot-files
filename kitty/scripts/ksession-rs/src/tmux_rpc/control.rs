//! Tmux control-mode (`tmux -C attach`) transport.
//!
//! Step 7.5 of the Rust port (plan §B.3.2). Replaces the per-call
//! `tmux <cmd>` subprocess fork (see [`super::TmuxCli`]) with a single
//! long-lived `tmux -C attach` pipe per tmux server. All queries
//! (`list-windows`, `display-message`, `capture-pane`, …) flow through
//! the same pipe, demuxed by tmux's server-assigned `<cmd-num>`.
//!
//! ## Adapter integration (PRD-0004 Slice 3).
//!
//! `src/adapter/tmux.rs` wires this transport into the capture path via
//! `TmuxControlCache`: when `WindowCtx::tmux_control_cache` is `Some`,
//! the adapter parses `$TMUX` from the kitty window's env to obtain
//! `(socket_path, server_pid)`, then calls `cache.get_or_spawn(...)` to
//! obtain or reuse a persistent pipe. All subsequent RPC calls
//! (`list_windows`, `list_panes`, `display_message`, `capture_pane`)
//! flow through the control-mode pipe instead of forking subprocesses.
//! If control-mode fails, the adapter falls back to `TmuxCli`.
//!
//! ## Protocol summary (see plan §B.3.2 for the canonical spec).
//!
//! After spawning `tmux -C attach -t '$<sid>'`, every command written
//! to the child's stdin produces one response block on stdout:
//!
//! ```text
//! %begin <ts> <cmd-num> <flags>
//! <command output, possibly many lines>
//! %end   <ts> <cmd-num> <flags>     (or %error)
//! ```
//!
//! `<cmd-num>` is a `u_int` allocated server-side (`cmdq_item.number`
//! in tmux source). The client never sees it until the `%begin` echoes
//! back. Per-client commands are processed FIFO on the server, so as
//! long as we serialize writes, `%begin` arrival order matches write
//! order. The demuxer pops a FIFO queue of pending senders on `%begin`,
//! binds them to the parsed cmd-num for the duration of the block, then
//! delivers the collected lines on `%end` (or an `Err` on `%error`).
//!
//! `%`-prefixed lines OUTSIDE a `%begin..%end` block are async
//! notifications. The save flow doesn't subscribe to any of them —
//! they're discarded. `%exit` is the special one: it signals the
//! pipe is closing.
//!
//! See [`super::decode_capture_c`] for the `capture-pane -C` decoder.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{ChildStdin, Command};
use tokio::sync::{oneshot, Mutex};

use super::{decode_capture_c, TmuxError, TmuxIo};

// ---------- public API ----------

/// One persistent `tmux -C attach` pipe to one tmux server. Cheap to
/// clone is NOT a goal — the caller owns one of these per
/// `(socket_path, server_pid)`. Concurrent `request()` calls are safe
/// (writes serialize on an internal mutex; reads happen on a background
/// task).
pub struct TmuxControl {
    inner: Arc<Inner>,
}

/// Result the demuxer hands back to a `request()` future. Aliased to
/// keep the in_flight / pending types from tripping clippy's
/// `type_complexity`.
type Response = Result<Vec<String>, TmuxError>;
type ResponseTx = oneshot::Sender<Response>;

struct Inner {
    /// Stdin of the `tmux -C attach` child. Held under a mutex; the lock
    /// is acquired ONLY across (push-pending-sender + write-cmd) so the
    /// FIFO order on the wire matches the FIFO order of pending
    /// senders. See plan §B.3.2 "Request atomicity invariant".
    stdin: Mutex<Option<ChildStdin>>,

    /// Senders waiting to be bound to a cmd-num. The head is the next
    /// `%begin` echo's owner.
    pending: Mutex<VecDeque<ResponseTx>>,

    /// Cmd-num → sender, populated on `%begin` and drained on
    /// `%end`/`%error`. The lifetime of an entry here is one command
    /// block. The map exists to bridge the two arrival edges — not to
    /// reorder responses (tmux serves FIFO per client).
    in_flight: Mutex<HashMap<u32, ResponseTx>>,

    /// Once the read loop exits (`%exit`, child died, stdout EOF) this
    /// holds the reason. Subsequent `request()` calls fail-fast.
    closed: Mutex<Option<String>>,
}

impl TmuxControl {
    /// Spawn `tmux [-L <name>|-S <path>] -C attach [-r] -t '$<sid>'`
    /// and start the demuxer background task.
    ///
    /// `socket_path` is the tmux server socket from `$TMUX` field 0
    /// (e.g. `/tmp/tmux-1000/default`). If it lives under
    /// `<tmpdir>/tmux-<uid>/` we pass `-L <basename>` to match how the
    /// user's tmux was started; otherwise `-S <full_path>`.
    ///
    /// `tmux_version` gates the attach-flag choice. On tmux ≥ 3.2 the
    /// spawn line uses `-r` (read-only, ignore-size) so the control
    /// client doesn't shrink the session's window sizes to 80×24 —
    /// see plan §B.3.2 layout-corruption mitigation. On tmux < 3.2 or
    /// unknown the flag is omitted; this method automatically follows
    /// up with `refresh-client -C` over the pipe to mitigate (best
    /// effort — a refresh-client error does not fail `connect`, since
    /// the worst case is a session resized to 80×24 after detach, not a
    /// failed save).
    pub async fn connect(
        socket_path: &Path,
        sid: u32,
        tmux_version: Option<(u32, u32)>,
    ) -> Result<Self, TmuxError> {
        let socket_arg = socket_arg_for(socket_path);
        let supports_r = matches!(tmux_version, Some((maj, min)) if (maj, min) >= (3, 2));

        let mut cmd = Command::new("tmux");
        match &socket_arg {
            SocketArg::Name(n) => {
                cmd.args(["-L", n]);
            }
            SocketArg::Path(p) => {
                cmd.arg("-S").arg(p);
            }
        }
        cmd.arg("-C").arg("attach");
        if supports_r {
            cmd.arg("-r");
        }
        cmd.args(["-t", &format!("${sid}")]);
        cmd.stdin(Stdio::piped());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());
        // Don't leak the parent's controlling tty / process group — a
        // control-mode client should be invisible to job control.
        cmd.kill_on_drop(true);

        let mut child = cmd.spawn().map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => TmuxError::NotInstalled,
            _ => TmuxError::Io(e),
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            TmuxError::Disconnected("tmux -C: failed to capture child stdin".into())
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            TmuxError::Disconnected("tmux -C: failed to capture child stdout".into())
        })?;

        // Handshake: `tmux -C attach` emits one unsolicited
        // `%begin/%end` block immediately after attach (the "client
        // attached" reply), plus zero or more notifications
        // (`%session-changed`, etc.). We must consume these BEFORE the
        // demuxer starts honoring our pending queue, otherwise the
        // first user `request()` would have its sender bound to the
        // unsolicited block and receive an empty response.
        //
        // Drive a synchronous read loop until we've observed exactly
        // one complete `%begin..%end` (or %error) pair, discarding it.
        // Then hand the BufReader off to the background demuxer.
        let mut reader = BufReader::new(stdout);
        drain_initial_block(&mut reader).await?;

        let inner = Arc::new(Inner {
            stdin: Mutex::new(Some(stdin)),
            pending: Mutex::new(VecDeque::new()),
            in_flight: Mutex::new(HashMap::new()),
            closed: Mutex::new(None),
        });

        // Spawn the read loop. It owns the child handle so that when
        // the loop exits (EOF / %exit) the reaper runs.
        let read_inner = Arc::clone(&inner);
        tokio::spawn(async move {
            let reason = read_loop(read_inner.clone(), reader).await;
            // Mark closed, drain queues with the disconnect reason.
            disconnect(&read_inner, reason).await;
            // Best-effort reap; ignore the result.
            let _ = child.wait().await;
        });

        let this = Self { inner };

        // Plan §B.3.2 "Fallback for tmux < 3.2": on tmux ≥ 3.2 the
        // `-r` attach flag aliased to `read-only,ignore-size` was the
        // primary mitigation; without `-r` (older tmux, or unknown
        // version) the control-mode client's 80×24 default would
        // become the session's persistent size after detach (the bug
        // at tmux#2594). Mitigate over the pipe by emitting
        // `refresh-client -C` sized to either the largest existing
        // client (if any) or `KSESSION_RESTORE_SIZE` (default
        // `200x60`) as a sentinel.
        //
        // Best effort: a `refresh-client` failure here is logged but
        // does not fail `connect` — the save can still proceed; the
        // user will just see the session at 80×24 next time they
        // attach. Surfacing this as a fatal error would be worse than
        // the size regression we're trying to prevent.
        if !supports_r {
            this.apply_pre_32_size_mitigation(tmux_version).await;
        }

        Ok(this)
    }

    /// Plan §B.3.2 fallback for tmux < 3.2: pick a sensible session
    /// size and `refresh-client -C` it over the pipe so the control
    /// client's 80×24 default doesn't persist as the session size after
    /// we detach (tmux#2594).
    ///
    /// `tmux_version` gates the `-C` argument format: tmux added the
    /// `WxH` separator in 2.9; versions before that use `W,H` (comma).
    /// `cmd-refresh-client.c` parses both forms only on their respective
    /// version's accepted syntax, so emitting `200x60` to a 2.6 server
    /// produces `bad command syntax: -C` and the resize never fires.
    ///
    /// When the version probe returned `None` (probe failed, output
    /// unparseable), conservatively assume the older comma syntax so
    /// the mitigation degrades to "no resize" rather than a noisy bad-
    /// syntax error in the log.
    async fn apply_pre_32_size_mitigation(&self, tmux_version: Option<(u32, u32)>) {
        // Tmux added `refresh-client -C WxH` in 2.9; earlier versions
        // accept `-C W,H` only. Default to comma (the "older, more
        // accepting on older tmux" form) when version is unknown.
        let use_x_separator = matches!(tmux_version, Some((maj, min)) if (maj, min) >= (2, 9));
        let fmt_size = |w: u32, h: u32| -> String {
            if use_x_separator {
                format!("{w}x{h}")
            } else {
                format!("{w},{h}")
            }
        };

        // First try to find another attached client and match its
        // size. `list-clients -F '#{client_width} #{client_height}'`
        // emits one line per client; pick the geometrically largest
        // (max area).
        match self
            .request("list-clients -F '#{client_width} #{client_height}'")
            .await
        {
            Ok(lines) if !lines.is_empty() => {
                let max = lines
                    .iter()
                    .filter_map(|l| {
                        let mut it = l.split_ascii_whitespace();
                        let w: u32 = it.next()?.parse().ok()?;
                        let h: u32 = it.next()?.parse().ok()?;
                        Some((w, h, (w as u64) * (h as u64)))
                    })
                    .max_by_key(|t| t.2);
                if let Some((w, h, _)) = max {
                    let cmd = format!("refresh-client -C {}", fmt_size(w, h));
                    if let Err(e) = self.request(&cmd).await {
                        eprintln!(
                            "ksession: tmux -C: refresh-client {}x{} (other-clients path) failed: {e}",
                            w, h
                        );
                    }
                    return;
                }
                // list-clients returned rows but none parsed — fall
                // through to the no-other-clients sentinel branch.
            }
            Ok(_) => {
                // No other clients attached — use the sentinel.
            }
            Err(e) => {
                eprintln!(
                    "ksession: tmux -C: list-clients (size probe) failed: {e}; \
                     falling back to KSESSION_RESTORE_SIZE sentinel"
                );
            }
        }

        // Sentinel path: KSESSION_RESTORE_SIZE (default 200x60).
        // Format is `<width>x<height>` per §1.5 — users override with
        // e.g. `export KSESSION_RESTORE_SIZE=380x100` for 4K displays.
        let (w, h) = parse_restore_size_env().unwrap_or((200, 60));
        let cmd = format!("refresh-client -C {}", fmt_size(w, h));
        if let Err(e) = self.request(&cmd).await {
            eprintln!(
                "ksession: tmux -C: refresh-client {} (sentinel path) failed: {e}",
                fmt_size(w, h)
            );
        }
    }

    /// Send `cmd\n` over the pipe and await the matching `%begin..%end`
    /// block. Returns the lines between the framing markers (trimmed of
    /// the framing). Returns `Err(TmuxError::Subprocess)` on `%error`,
    /// `Err(TmuxError::Disconnected)` if the pipe closed before the
    /// response arrived.
    pub async fn request(&self, cmd: &str) -> Result<Vec<String>, TmuxError> {
        // Fail-fast if the pipe already closed.
        if let Some(reason) = self.inner.closed.lock().await.clone() {
            return Err(TmuxError::Disconnected(reason));
        }

        let (tx, rx) = oneshot::channel();

        // Hold the stdin mutex across (push pending-sender + write
        // command). See plan §B.3.2 "Request atomicity invariant".
        {
            let mut stdin_guard = self.inner.stdin.lock().await;
            let stdin = stdin_guard
                .as_mut()
                .ok_or_else(|| TmuxError::Disconnected("tmux -C: stdin already closed".into()))?;
            self.inner.pending.lock().await.push_back(tx);
            let mut line = String::with_capacity(cmd.len() + 1);
            line.push_str(cmd);
            line.push('\n');
            if let Err(e) = stdin.write_all(line.as_bytes()).await {
                // Pop the sender we just enqueued — there's no
                // response coming. Match by ptr-identity not possible
                // with oneshot::Sender; the FIFO contract is that the
                // failed write means no response, so the next response
                // would bind to the wrong sender. Safer to drain ALL
                // pending and close the pipe.
                drop(stdin_guard);
                disconnect(&self.inner, format!("tmux -C: stdin write failed: {e}")).await;
                return Err(TmuxError::Io(e));
            }
        }

        match rx.await {
            Ok(res) => res,
            Err(_) => {
                // Sender dropped — read loop exited mid-request.
                let reason = self
                    .inner
                    .closed
                    .lock()
                    .await
                    .clone()
                    .unwrap_or_else(|| "tmux -C: receiver dropped".into());
                Err(TmuxError::Disconnected(reason))
            }
        }
    }

    /// Best-effort clean shutdown. Sends `detach-client`, then drops the
    /// stdin handle so the child sees EOF. The read loop's `%exit`
    /// handler (or the EOF path) does the rest. Safe to skip — the
    /// `Drop` impl on the spawned child uses `kill_on_drop(true)` so
    /// abandonment is also safe.
    pub async fn shutdown(self) -> Result<(), TmuxError> {
        // We don't await `%exit` here — the spawned `kill_on_drop`
        // child cleanup and the read loop's disconnect-handling do the
        // right thing once stdin is closed. Just send detach-client and
        // drop stdin.
        let _ = self.request("detach-client").await;
        // Close stdin explicitly so the child sees EOF promptly.
        let mut guard = self.inner.stdin.lock().await;
        guard.take(); // drop the ChildStdin → EOF on the child
        Ok(())
    }
}

impl Drop for TmuxControl {
    fn drop(&mut self) {
        // Drop the ChildStdin synchronously if possible. Best effort —
        // the tokio::spawn'd child has `kill_on_drop(true)` so even if
        // we can't acquire the mutex synchronously the child will be
        // reaped when its handle drops out of the read loop.
        if let Ok(mut guard) = self.inner.stdin.try_lock() {
            guard.take();
        }
    }
}

#[async_trait]
impl TmuxIo for TmuxControl {
    async fn run(&self, args: &[&str]) -> Result<String, TmuxError> {
        let cmd = join_tmux_args(args);
        let lines = self.request(&cmd).await?;
        // Reassemble with trailing `\n` between lines and a final `\n`
        // to match the subprocess [`TmuxCli`] shape — callers like
        // `list_windows` parse via `.lines()` and treat the final line
        // independently.
        let mut s = lines.join("\n");
        if !lines.is_empty() {
            s.push('\n');
        }
        Ok(s)
    }

    async fn capture_pane_to_file(
        &self,
        pane_id: &str,
        dest: &Path,
        ansi: bool,
    ) -> Result<u64, TmuxError> {
        // Build the command line with `-C` for application-layer
        // escaping (plan §B.3.2). Note that the `-p` flag is required
        // when running through control mode just as in the subprocess
        // path — it tells tmux to print to stdout (the control pipe).
        let mut parts: Vec<String> = vec!["capture-pane".into(), "-p".into(), "-C".into()];
        if ansi {
            parts.push("-e".into());
        }
        parts.push("-S".into());
        parts.push("-".into());
        parts.push("-t".into());
        parts.push(tmux_quote(pane_id));

        let cmd = parts.join(" ");
        let lines = self.request(&cmd).await?;

        // Reassemble the escaped payload (lines were split on the
        // protocol-level `\n`s between `%begin` and `%end`). Per the
        // spec, capture-pane -C output is 7-bit printable with no
        // embedded `\n`s — protocol `\n`s = scrollback line breaks.
        let mut escaped: Vec<u8> = Vec::new();
        for (i, line) in lines.iter().enumerate() {
            if i > 0 {
                escaped.push(b'\n');
            }
            escaped.extend_from_slice(line.as_bytes());
        }
        let decoded = decode_capture_c(&escaped);
        if let Some(parent) = dest.parent() {
            tokio::fs::create_dir_all(parent).await.ok();
        }
        let mut f = tokio::fs::File::create(dest).await?;
        f.write_all(&decoded).await?;
        f.flush().await?;
        Ok(decoded.len() as u64)
    }
}

/// Blanket impl so `Arc<TmuxControl>` (returned by `TmuxControlCache`)
/// can be used directly as a `TmuxIo` without a wrapper. Delegates to
/// the inner `TmuxControl` via `Deref`.
#[async_trait]
impl TmuxIo for Arc<TmuxControl> {
    async fn run(&self, args: &[&str]) -> Result<String, TmuxError> {
        (**self).run(args).await
    }

    async fn capture_pane_to_file(
        &self,
        pane_id: &str,
        dest: &Path,
        ansi: bool,
    ) -> Result<u64, TmuxError> {
        (**self).capture_pane_to_file(pane_id, dest, ansi).await
    }
}

// ---------- socket arg ----------

#[derive(Debug, Clone, PartialEq, Eq)]
enum SocketArg {
    /// `-L <name>` — resolves to `$TMPDIR/tmux-$UID/<name>`.
    Name(String),
    /// `-S <abs path>` — absolute socket path.
    Path(PathBuf),
}

/// Choose `-L` or `-S` for `socket_path`. If the path is under
/// `<tmpdir>/tmux-<uid>/`, return `Name(basename)`. Otherwise
/// `Path(socket_path)`. The `-L` form is preferred when valid so we
/// don't double-specify the socket via two different flags.
fn socket_arg_for(socket_path: &Path) -> SocketArg {
    // The expected layout is `<tmpdir>/tmux-<uid>/<name>`. We don't
    // strictly require the tmpdir prefix to match — only that the
    // parent directory's basename starts with `tmux-`. That's a
    // sufficient heuristic for "this is a standard tmux socket
    // directory" without coupling us to `$TMPDIR` detection.
    if let (Some(parent), Some(basename)) = (socket_path.parent(), socket_path.file_name()) {
        if let Some(parent_name) = parent.file_name().and_then(|s| s.to_str()) {
            if parent_name.starts_with("tmux-") {
                if let Some(b) = basename.to_str() {
                    return SocketArg::Name(b.to_string());
                }
            }
        }
    }
    SocketArg::Path(socket_path.to_path_buf())
}

// ---------- pre-3.2 refresh-client mitigation helpers ----------

/// Parse `KSESSION_RESTORE_SIZE` (format `<width>x<height>`, e.g.
/// `200x60` or `380x100`). Returns `None` on unset, empty, or
/// unparseable values — the caller falls back to the documented
/// default (`200x60`).
///
/// Plan §1.5 / §B.3.2 "Fallback for tmux < 3.2 — No other clients
/// attached": users with 4K terminals or unusual layouts override the
/// `200x60` sentinel via the kitty `env` directive.
fn parse_restore_size_env() -> Option<(u32, u32)> {
    let raw = std::env::var("KSESSION_RESTORE_SIZE").ok()?;
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let (w, h) = raw.split_once('x')?;
    let w: u32 = w.trim().parse().ok()?;
    let h: u32 = h.trim().parse().ok()?;
    Some((w, h))
}

// ---------- command-line serialization ----------

/// Quote `s` for tmux's command parser (NOT for shell). Tmux's parser
/// treats `'…'` as a literal byte string with no internal escaping;
/// embedded apostrophes are handled with the classic `'\''` close/open
/// dance. Safe characters pass through bare.
///
/// This mirrors the shape of [`super::bash_quote`] but for tmux's
/// parser, which has different metacharacters (notably no `$` expansion
/// inside `'…'`). Reuse the same safe-byte heuristic.
fn tmux_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".to_string();
    }
    if s.bytes().all(is_tmux_safe) {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str(r"'\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

#[inline]
fn is_tmux_safe(b: u8) -> bool {
    matches!(b,
        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' |
        b'_' | b'.' | b'/' | b'-' | b'@' | b'+' | b','
    )
}

/// Serialize an `args` slice into a single tmux command line for the
/// control pipe. Each arg is tmux-quoted; args are joined by single
/// spaces.
fn join_tmux_args(args: &[&str]) -> String {
    args.iter()
        .map(|a| tmux_quote(a))
        .collect::<Vec<_>>()
        .join(" ")
}

// ---------- parser ----------

/// One protocol-relevant event extracted from a line read off the
/// control-mode pipe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ParserEvent {
    /// A `%begin <ts> <num> <flags>` framing line. Read loop should pop
    /// the head of `pending` and bind it to `num`.
    Begin { num: u32 },
    /// A non-framing line that is part of the currently-open command
    /// block's payload. Accumulate.
    Payload(String),
    /// A `%end <ts> <num> <flags>` framing line. Read loop should
    /// remove `num` from `in_flight` and deliver `Ok(accumulated)`.
    End { num: u32 },
    /// A `%error <ts> <num> <flags>` framing line. Same as End but the
    /// accumulated lines describe the failure (sent as `Err`).
    Error { num: u32 },
    /// `%exit [<reason>]` — pipe is closing. Read loop should disconnect.
    Exit { reason: Option<String> },
    /// Any other `%`-prefixed notification, OUTSIDE a command block.
    /// The save flow discards these. The reader is kept as a `String`
    /// for DEBUG logging.
    Notification(String),
    /// Outside-of-block line that does NOT start with `%`. Per plan
    /// §B.3.2 this means the connection is corrupted (or a future
    /// protocol revision changed the framing). The read loop should
    /// treat this as a parse error.
    Stray(String),
}

/// Mutable state threaded through [`process_line`].
#[derive(Debug, Default)]
pub(crate) struct ParserState {
    /// `Some(num)` while we are between `%begin <num>` and the matching
    /// `%end`/`%error`. Lines arriving in this state are payload, not
    /// notifications. Tmux guarantees that async notifications never
    /// interleave INSIDE a command block (control.c).
    open_block: Option<u32>,
}

/// Classify one decoded line (no trailing `\n`) from the control pipe.
/// Pure function over [`ParserState`] — the read loop owns side-effects.
pub(crate) fn process_line(state: &mut ParserState, line: &str) -> ParserEvent {
    // Inside an open block, lines that don't match `%end`/`%error` are
    // payload regardless of leading `%`. Per tmux's control.c, notifications
    // never appear inside a block, so a `%foo` here would be payload from
    // a command like `display-message -p '%foo'`. Match the framing
    // markers FIRST and fall through to payload if we don't recognize.
    if let Some(open_num) = state.open_block {
        // Check for terminators belonging to THIS block.
        if let Some(num) = parse_framing(line, "%end") {
            if num == open_num {
                state.open_block = None;
                return ParserEvent::End { num };
            }
            // Mismatched %end — protocol violation, but keep parsing.
            // Treat as stray to surface the bug.
            return ParserEvent::Stray(line.to_string());
        }
        if let Some(num) = parse_framing(line, "%error") {
            if num == open_num {
                state.open_block = None;
                return ParserEvent::Error { num };
            }
            return ParserEvent::Stray(line.to_string());
        }
        // Anything else inside an open block is payload.
        return ParserEvent::Payload(line.to_string());
    }

    // Outside any block. Classify framing/notification/stray.
    if let Some(num) = parse_framing(line, "%begin") {
        state.open_block = Some(num);
        return ParserEvent::Begin { num };
    }
    // `%end`/`%error` outside an open block is a protocol violation.
    if line.starts_with("%end ") || line.starts_with("%error ") {
        return ParserEvent::Stray(line.to_string());
    }
    if let Some(rest) = line.strip_prefix("%exit") {
        // `%exit` or `%exit <reason>`. The reason is everything after
        // the first space, if any.
        let reason = rest
            .strip_prefix(' ')
            .map(|s| s.to_string())
            .filter(|s| !s.is_empty());
        return ParserEvent::Exit { reason };
    }
    if line.starts_with('%') {
        return ParserEvent::Notification(line.to_string());
    }
    ParserEvent::Stray(line.to_string())
}

/// Parse `<prefix> <ts> <num> <flags>` and return `num`. Strict on the
/// prefix-+-space anchor; tolerant on the trailing flags field (tmux's
/// flags column is currently always `1` but the parser shouldn't break
/// if a future version adds more).
fn parse_framing(line: &str, prefix: &str) -> Option<u32> {
    let rest = line.strip_prefix(prefix)?;
    let rest = rest.strip_prefix(' ')?;
    let mut it = rest.split(' ');
    let _ts = it.next()?;
    let num_s = it.next()?;
    // Flags field is `it.next()` — we don't care about its value.
    num_s.parse::<u32>().ok()
}

// ---------- startup handshake ----------

/// Consume the unsolicited `%begin..%end` block that `tmux -C attach`
/// emits at connection establishment. Discards any leading
/// `%`-notifications (`%session-changed`, etc.) too.
///
/// Returns once the first complete `%begin..%end` (or `%error`) pair
/// has been observed. The reader is positioned at the start of the
/// next line, ready for the demuxer loop.
async fn drain_initial_block<R>(reader: &mut BufReader<R>) -> Result<(), TmuxError>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut state = ParserState::default();
    let mut saw_begin = false;
    // Bound this with a deadline so a misbehaving tmux can't wedge
    // connect() forever. 5s is generous — local pipe ops should
    // complete in microseconds.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(TmuxError::Disconnected(
                "tmux -C: handshake timed out waiting for initial %begin/%end".into(),
            ));
        }
        let mut buf: Vec<u8> = Vec::with_capacity(128);
        let read = tokio::time::timeout(remaining, reader.read_until(b'\n', &mut buf))
            .await
            .map_err(|_| {
                TmuxError::Disconnected(
                    "tmux -C: handshake timed out waiting for initial %begin/%end".into(),
                )
            })?;
        let n = read.map_err(TmuxError::Io)?;
        if n == 0 {
            return Err(TmuxError::Disconnected(
                "tmux -C: EOF during handshake".into(),
            ));
        }
        if buf.ends_with(b"\n") {
            buf.pop();
        }
        if buf.ends_with(b"\r") {
            buf.pop();
        }
        let line = String::from_utf8_lossy(&buf).into_owned();
        match process_line(&mut state, &line) {
            ParserEvent::Begin { .. } => {
                saw_begin = true;
            }
            ParserEvent::Payload(_) => {
                // payload of the unsolicited block — discard.
            }
            ParserEvent::End { .. } | ParserEvent::Error { .. } => {
                if saw_begin {
                    return Ok(());
                }
                // Stray terminator with no matching begin — shouldn't
                // happen at handshake time, treat as protocol error.
                return Err(TmuxError::ControlParseError(format!(
                    "unexpected terminator during handshake: {line}"
                )));
            }
            ParserEvent::Notification(_) => {
                // Pre-attach notifications are fine; keep waiting.
            }
            ParserEvent::Exit { reason } => {
                return Err(TmuxError::Disconnected(
                    reason
                        .map(|r| format!("tmux -C: %exit during handshake: {r}"))
                        .unwrap_or_else(|| "tmux -C: %exit during handshake".to_string()),
                ));
            }
            ParserEvent::Stray(s) => {
                return Err(TmuxError::ControlParseError(format!(
                    "stray line during handshake: {s}"
                )));
            }
        }
    }
}

// ---------- read loop ----------

/// Drive the demuxer until the pipe closes. Returns a human-readable
/// reason for the close (used to populate `Inner::closed` and to error
/// in-flight requests).
async fn read_loop<R>(inner: Arc<Inner>, mut reader: BufReader<R>) -> String
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut state = ParserState::default();
    // Accumulator for the currently-open block's payload lines.
    let mut acc: Vec<String> = Vec::new();
    // Track which num the accumulator belongs to, for the in_flight
    // lookup on End/Error.
    let mut acc_num: Option<u32> = None;

    loop {
        let mut buf: Vec<u8> = Vec::with_capacity(256);
        match reader.read_until(b'\n', &mut buf).await {
            Ok(0) => {
                return "tmux -C: stdout EOF".to_string();
            }
            Ok(_) => {}
            Err(e) => return format!("tmux -C: stdout read error: {e}"),
        }
        // Strip trailing \n (and optional \r) before parsing.
        if buf.ends_with(b"\n") {
            buf.pop();
        }
        if buf.ends_with(b"\r") {
            buf.pop();
        }
        // Decode lossily — control-mode lines are 7-bit ASCII for the
        // framing tokens, and capture-pane `-C` payloads are ASCII by
        // construction. Other commands' output (`display-message`,
        // `list-windows`) is whatever locale tmux is in; lossy decode
        // preserves all printable bytes and replaces invalid sequences
        // with U+FFFD — acceptable for query output.
        let line = String::from_utf8_lossy(&buf).into_owned();

        match process_line(&mut state, &line) {
            ParserEvent::Begin { num } => {
                // Pop the head of `pending` and bind to `num`.
                let tx_opt = inner.pending.lock().await.pop_front();
                match tx_opt {
                    Some(tx) => {
                        inner.in_flight.lock().await.insert(num, tx);
                        acc.clear();
                        acc_num = Some(num);
                    }
                    None => {
                        // %begin with no waiting sender — protocol bug
                        // or a stale block (shouldn't happen in
                        // practice). Discard the payload of this block;
                        // ParserState already opened it.
                        acc.clear();
                        acc_num = None;
                    }
                }
            }
            ParserEvent::Payload(s) => {
                if acc_num.is_some() {
                    acc.push(s);
                }
                // else: spurious %begin had no sender; drop payload.
            }
            ParserEvent::End { num } => {
                let tx_opt = inner.in_flight.lock().await.remove(&num);
                if let Some(tx) = tx_opt {
                    let _ = tx.send(Ok(std::mem::take(&mut acc)));
                }
                acc_num = None;
            }
            ParserEvent::Error { num } => {
                let tx_opt = inner.in_flight.lock().await.remove(&num);
                if let Some(tx) = tx_opt {
                    let stderr = std::mem::take(&mut acc).join("\n");
                    let _ = tx.send(Err(TmuxError::Subprocess {
                        subcommand: "control".to_string(),
                        status: 1,
                        stderr,
                    }));
                }
                acc_num = None;
            }
            ParserEvent::Exit { reason } => {
                return reason
                    .map(|r| format!("tmux -C: %exit {r}"))
                    .unwrap_or_else(|| "tmux -C: %exit".to_string());
            }
            ParserEvent::Notification(_n) => {
                // Discard. Forward-compat rule: never error on an
                // unknown `%`-line. If a future feature subscribes,
                // route through a bounded mpsc per plan §B.3.2.
            }
            ParserEvent::Stray(s) => {
                // Outside-block non-%-prefixed line, or a misplaced
                // %end/%error. Plan §B.3.2 says treat as connection
                // corruption — close the pipe.
                return format!("tmux -C: stray line outside block: {s:?}");
            }
        }
    }
}

/// Mark the pipe closed and drain pending+in_flight senders with the
/// reason. Idempotent.
async fn disconnect(inner: &Arc<Inner>, reason: String) {
    {
        let mut closed = inner.closed.lock().await;
        if closed.is_some() {
            return;
        }
        *closed = Some(reason.clone());
    }
    // Drop stdin so future writers fail-fast.
    {
        let mut g = inner.stdin.lock().await;
        g.take();
    }
    // Drain pending (never bound to a num).
    let mut pending = inner.pending.lock().await;
    while let Some(tx) = pending.pop_front() {
        let _ = tx.send(Err(TmuxError::Disconnected(reason.clone())));
    }
    drop(pending);
    // Drain in_flight (already bound, mid-block).
    let mut in_flight = inner.in_flight.lock().await;
    let drained: Vec<_> = in_flight.drain().collect();
    drop(in_flight);
    for (_num, tx) in drained {
        let _ = tx.send(Err(TmuxError::Disconnected(reason.clone())));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---------- tmux_quote ----------

    #[test]
    fn tmux_quote_passthrough() {
        assert_eq!(tmux_quote("list-windows"), "list-windows");
        assert_eq!(tmux_quote("%17"), "'%17'"); // `%` is not safe → quoted
        assert_eq!(tmux_quote(""), "''");
    }

    #[test]
    fn tmux_quote_embedded_apostrophe() {
        assert_eq!(tmux_quote("it's"), r#"'it'\''s'"#);
    }

    #[test]
    fn tmux_quote_session_target_quoted() {
        // `$2` (session-id target syntax) contains `$` which isn't in
        // our safe set, so it gets quoted. Tmux's parser treats single
        // quotes as a literal byte string — `$` does NOT expand inside,
        // so `'$2'` is fine.
        assert_eq!(tmux_quote("$2"), "'$2'");
    }

    // ---------- join_tmux_args ----------

    #[test]
    fn join_tmux_args_simple() {
        assert_eq!(
            join_tmux_args(&["list-windows", "-t", "demo", "-F", "#{window_index}"]),
            "list-windows -t demo -F '#{window_index}'"
        );
    }

    // ---------- socket_arg_for ----------

    #[test]
    fn socket_arg_default_socket() {
        assert_eq!(
            socket_arg_for(Path::new("/tmp/tmux-1000/default")),
            SocketArg::Name("default".to_string())
        );
    }

    #[test]
    fn socket_arg_custom_name() {
        assert_eq!(
            socket_arg_for(Path::new("/run/user/1000/tmux-1000/work")),
            SocketArg::Name("work".to_string())
        );
    }

    #[test]
    fn socket_arg_nonstandard_path() {
        assert_eq!(
            socket_arg_for(Path::new("/var/lib/my-app/tmux.sock")),
            SocketArg::Path(PathBuf::from("/var/lib/my-app/tmux.sock"))
        );
    }

    // ---------- parser unit tests ----------

    fn run_parser(lines: &[&str]) -> Vec<ParserEvent> {
        let mut state = ParserState::default();
        lines.iter().map(|l| process_line(&mut state, l)).collect()
    }

    #[test]
    fn parser_simple_block() {
        let evs = run_parser(&["%begin 100 1 1", "foo", "bar", "%end 100 1 1"]);
        assert_eq!(
            evs,
            vec![
                ParserEvent::Begin { num: 1 },
                ParserEvent::Payload("foo".into()),
                ParserEvent::Payload("bar".into()),
                ParserEvent::End { num: 1 },
            ]
        );
    }

    #[test]
    fn parser_error_block() {
        let evs = run_parser(&["%begin 100 5 1", "unknown command", "%error 100 5 1"]);
        assert_eq!(
            evs,
            vec![
                ParserEvent::Begin { num: 5 },
                ParserEvent::Payload("unknown command".into()),
                ParserEvent::Error { num: 5 },
            ]
        );
    }

    #[test]
    fn parser_notifications_between_blocks() {
        // Per plan §B.3.2, notifications interleave BETWEEN command
        // blocks but never inside one. Verify both that an outside
        // notification is classified as Notification, and that the
        // parser is ready for the next block immediately after.
        let evs = run_parser(&[
            "%begin 100 1 1",
            "ok",
            "%end 100 1 1",
            "%window-add @5",
            "%layout-change",
            "%begin 101 2 1",
            "second",
            "%end 101 2 1",
        ]);
        assert_eq!(
            evs,
            vec![
                ParserEvent::Begin { num: 1 },
                ParserEvent::Payload("ok".into()),
                ParserEvent::End { num: 1 },
                ParserEvent::Notification("%window-add @5".into()),
                ParserEvent::Notification("%layout-change".into()),
                ParserEvent::Begin { num: 2 },
                ParserEvent::Payload("second".into()),
                ParserEvent::End { num: 2 },
            ]
        );
    }

    #[test]
    fn parser_unknown_notification_is_silently_classified() {
        // Forward-compat: a notification tmux 3.5+ may add must NOT
        // break the parser. It's classified as Notification (read loop
        // discards) — the test asserts no Stray classification.
        let evs = run_parser(&[
            "%begin 100 1 1",
            "%end 100 1 1",
            "%future-notification-tmux-3-5 foo bar",
            "%hypothetical with multiple spaces",
        ]);
        assert_eq!(evs[0], ParserEvent::Begin { num: 1 });
        assert_eq!(evs[1], ParserEvent::End { num: 1 });
        assert!(matches!(evs[2], ParserEvent::Notification(_)));
        assert!(matches!(evs[3], ParserEvent::Notification(_)));
    }

    #[test]
    fn parser_payload_starting_with_percent_inside_block() {
        // A line like `%foo` appearing INSIDE an open block is payload,
        // NOT a notification — tmux's control.c never emits
        // notifications between %begin and %end. So a `display-message
        // -p '%foo'` response should round-trip cleanly.
        let evs = run_parser(&["%begin 100 1 1", "%foo", "%end 100 1 1"]);
        assert_eq!(
            evs,
            vec![
                ParserEvent::Begin { num: 1 },
                ParserEvent::Payload("%foo".into()),
                ParserEvent::End { num: 1 },
            ]
        );
    }

    #[test]
    fn parser_exit_with_reason() {
        let evs = run_parser(&["%exit shutting down"]);
        assert_eq!(
            evs,
            vec![ParserEvent::Exit {
                reason: Some("shutting down".into()),
            }]
        );
    }

    #[test]
    fn parser_exit_without_reason() {
        let evs = run_parser(&["%exit"]);
        assert_eq!(evs, vec![ParserEvent::Exit { reason: None }]);
    }

    #[test]
    fn parser_stray_outside_block_is_classified() {
        let evs = run_parser(&["garbage on the wire"]);
        assert!(matches!(evs[0], ParserEvent::Stray(_)));
    }

    #[test]
    fn parser_misplaced_end_outside_block() {
        let evs = run_parser(&["%end 100 1 1"]);
        assert!(matches!(evs[0], ParserEvent::Stray(_)));
    }

    #[test]
    fn parser_block_with_flags_field_variation() {
        // The flags field is currently always `1` but the parser must
        // tolerate any value.
        let evs = run_parser(&["%begin 100 1 42", "ok", "%end 100 1 99"]);
        assert_eq!(
            evs,
            vec![
                ParserEvent::Begin { num: 1 },
                ParserEvent::Payload("ok".into()),
                ParserEvent::End { num: 1 },
            ]
        );
    }

    // ---------- KSESSION_RESTORE_SIZE parser ----------
    //
    // env::set_var is process-global; serialise the parser tests behind a
    // single mutex so concurrent cargo runners don't race the var.

    use std::sync::Mutex;
    static RESTORE_SIZE_ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn restore_size_env_parses_default_shape() {
        let _g = RESTORE_SIZE_ENV_LOCK.lock().unwrap();
        let saved = std::env::var_os("KSESSION_RESTORE_SIZE");

        std::env::remove_var("KSESSION_RESTORE_SIZE");
        assert_eq!(parse_restore_size_env(), None, "unset → None");

        std::env::set_var("KSESSION_RESTORE_SIZE", "");
        assert_eq!(parse_restore_size_env(), None, "empty → None");

        std::env::set_var("KSESSION_RESTORE_SIZE", "200x60");
        assert_eq!(parse_restore_size_env(), Some((200, 60)));

        std::env::set_var("KSESSION_RESTORE_SIZE", "380x100");
        assert_eq!(parse_restore_size_env(), Some((380, 100)));

        // Whitespace around either side is tolerated.
        std::env::set_var("KSESSION_RESTORE_SIZE", " 120 x 40 ");
        assert_eq!(parse_restore_size_env(), Some((120, 40)));

        // Malformed inputs (no `x`, non-numeric, comma separator instead of
        // `x`) yield None — the caller falls back to the documented 200x60.
        std::env::set_var("KSESSION_RESTORE_SIZE", "200,60");
        assert_eq!(parse_restore_size_env(), None, "comma separator → None");

        std::env::set_var("KSESSION_RESTORE_SIZE", "huge");
        assert_eq!(parse_restore_size_env(), None, "non-numeric → None");

        std::env::set_var("KSESSION_RESTORE_SIZE", "200x");
        assert_eq!(parse_restore_size_env(), None, "missing height → None");

        match saved {
            Some(v) => std::env::set_var("KSESSION_RESTORE_SIZE", v),
            None => std::env::remove_var("KSESSION_RESTORE_SIZE"),
        }
    }
}
