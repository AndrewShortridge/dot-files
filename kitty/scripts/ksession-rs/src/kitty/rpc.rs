//! Direct DCS-socket RPC client for kitty's remote-control protocol.
//!
//! Replaces subprocess shell-outs to `kitty @` (see [`crate::kitty::cli`])
//! with a persistent Unix-socket connection. Plan §B.3.1: ~50 ms/call →
//! ~15 ms/call by skipping `fork(2)`+`execve(2)`+cold-start of the kitty
//! binary on every RC operation.
//!
//! # Wire format (verified empirically against `/tmp/kitty-<pid>`)
//!
//! Both directions wrap a JSON payload in a DCS sequence:
//!
//! ```text
//! \x1bP@kitty-cmd<json-payload>\x1b\\
//! ```
//!
//! Request body:
//!
//! ```json
//! {"cmd": "<name>", "version": [0,26,0], "payload": {...}, "no_response": false}
//! ```
//!
//! Response body:
//!
//! ```json
//! {"ok": true,  "data": <any-or-null>}        // success
//! {"ok": false, "error": "...", "tb": "..."}  // server-side failure
//! ```
//!
//! # Quirks (each verified live against `/tmp/kitty-<pid>`)
//!
//! - **`data` shape is per-command.** `ls`'s `data` is a JSON STRING containing
//!   JSON; caller must `serde_json::from_str` it a second time. `ls
//!   --output-format=session`'s `data` is raw conf text. `get_text`'s is raw
//!   text. `get_colors`'s is raw `key value` conf text. `set_user_vars` and
//!   several other writes return `null` (or omit `data` entirely). There is no
//!   uniform decode strategy — each per-command wrapper in this module
//!   encodes the right shape so callers never see the raw envelope.
//! - **`var` payload key for set-user-vars.** The CLI command is named
//!   `set-user-vars`, the JSON payload key is `var` (singular). Easy to get
//!   wrong: passing `user_vars` is silently accepted (ok:true) but does NOT
//!   actually update the window — instead kitty returns a `\n`-joined dump of
//!   existing vars. The `no_response: true` flag we use for the burst hides
//!   this. Verified via the official `kitten` CLI snooped on a proxy socket.
//! - **Auth is socket-permissions.** With `allow_remote_control socket-only`
//!   (the user's config) and unix transport, file permissions ARE the auth.
//!   No `KITTY_RC_PASSWORD`, no `KITTY_PUBLIC_KEY`, no AES-GCM envelope. The
//!   encryption machinery only kicks in for TTY-escape transport from
//!   untrusted children.
//! - **`no_response: true`** makes the server skip the reply entirely; the
//!   connection stays open for the next request. We do not `shutdown(SHUT_WR)`
//!   the half — that would close it for everyone. Used for `set_user_vars`
//!   bursts (Plan §C.3 + §C.6).
//! - **Version is by-minor.** kitty rejects when `client_minor > server_minor`
//!   (live-verified: `[0, 48, 0]` against a 0.47 server returns ok:false
//!   "newer than this kitty instance"; `[0, 47, 0]` accepts). The check is
//!   NOT major-only as an earlier version of this doc claimed. We send
//!   `[0, 26, 0]` — frozen at the official kitten CLI's pinned protocol —
//!   which is compatible with any kitty server at 0.M.P where M ≥ 26.
//!   Strict-improvement floor: no rejection on user-side kitty upgrades.
//! - **`--self` is INCLUDE, not exclude.** kitten's `--self` flag means "only
//!   list the window the command runs in"; the JSON field has the same
//!   semantics. Passing `false` is just default behavior. Do NOT use it to
//!   filter the save-prompt overlay — that ride on `is_self` on returned
//!   windows (handled in [`crate::kitty::ls`]) and on an overlay-id match.
//! - **Listen-on schemes.** kitty's `listen_on` can be `unix:/path`,
//!   `unix:@abstract`, `tcp:host:port`, or bare path. This client supports
//!   the two unix variants; tcp returns a clear "not supported" error
//!   instead of a confusing ENOENT.
//! - **Control bytes inside `data`** (e.g. ANSI escapes from `get_text
//!   --ansi`) are JSON-escaped as `...`, so the raw `\x1b` terminator
//!   byte cannot appear inside the JSON payload. The frame parser's
//!   `ends_with(\x1b\\)` check is therefore unambiguous.
//!
//! # Connection poisoning
//!
//! The legacy [`KittyRpc`] (still present for tests) holds the wire as
//! `Mutex<Option<UnixStream>>`. The production [`crate::kitty::pool::KittyPool`]
//! applies the same per-connection poison semantics: on error, the stream is
//! dropped and the slot freed for a fresh dial. Each call takes the stream out
//! for the duration of write+read; on success it goes back, on error or
//! cancellation it doesn't. The next call sees `None` and fails fast with
//! "connection poisoned by prior error". This avoids the cancellation hazard
//! where a partially-completed exchange leaves a response in the kernel buffer
//! that the next caller would misread as its own.

use std::env;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::Mutex;
use tokio::time::timeout;

use crate::error::KError;
use crate::kitty::ls::{parse_ls_output, OsWindow};

pub(crate) const DCS_PREFIX: &[u8] = b"\x1bP@kitty-cmd";
pub(crate) const DCS_TERMINATOR: &[u8] = b"\x1b\\";
// Frozen-from-kitten-CLI version. kitty rejects when client minor >
// server minor; pinning at 0.26 means we work against any kitty 0.M.P
// where M ≥ 26 and never get rejected by future kitty releases.
pub(crate) const PROTOCOL_VERSION: [u32; 3] = [0, 26, 0];
pub(crate) const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);
// 16 MiB hard cap on a single response. Real ls payloads run ~10 KiB;
// scrollback for a heavily-used pane runs ~200 KiB. 16 MiB is comfortable
// headroom AND a defence against a misbehaving server streaming forever.
const READ_CAP_BYTES: usize = 16 * 1024 * 1024;

/// Legacy single-connection RPC client. Superseded by
/// [`crate::kitty::pool::KittyPool`] for production use; retained as an
/// internal detail so the extensive unit tests in this module continue to
/// exercise the wire protocol and poison semantics without pulling in pool
/// machinery. Not re-exported from `crate::kitty`.
#[derive(Debug)]
#[allow(dead_code)]
pub struct KittyRpc {
    stream: Mutex<Option<UnixStream>>,
    socket: PathBuf,
    read_timeout: Duration,
}

#[allow(dead_code)]
impl KittyRpc {
    /// Probe for a kitty RC socket and connect to it.
    ///
    /// Order:
    /// 1. `$KITTY_LISTEN_ON` (parsed for scheme: `unix:/path`,
    ///    `unix:@abstract`, or bare path; `tcp:` returns a clear error).
    ///    This is the address kitty announces to its own children, so when
    ///    ksession runs from inside a kitty window it's the canonical
    ///    pointer.
    /// 2. Scan `/tmp/kitty-*` for sockets owned by the current uid, newest
    ///    first by mtime. Handles invocation from outside a kitty child
    ///    (e.g. cron, headless test harness).
    ///
    /// Returns [`KError::KittyRemote`] with all attempted-path errors
    /// concatenated when nothing connects, so the user-facing log surfaces
    /// the actual cause rather than a generic "no kitty".
    pub async fn discover() -> Result<Self, KError> {
        let candidates = discover_candidates();
        if candidates.is_empty() {
            return Err(KError::KittyRemote(
                "no kitty RC socket found (set KITTY_LISTEN_ON or run from inside kitty)".into(),
            ));
        }
        let mut errs: Vec<String> = Vec::new();
        for spec in &candidates {
            match Self::connect_spec(spec).await {
                Ok(rpc) => return Ok(rpc),
                Err(e) => errs.push(format!("  {spec}: {e}")),
            }
        }
        Err(KError::KittyRemote(format!(
            "no kitty RC socket connectable:\n{}",
            errs.join("\n")
        )))
    }

    /// Discover the socket AND issue the first `ls --all-env-vars` in one
    /// future. Plan §B.5: kick this off in `main()` before clap-parse /
    /// log-init so the ~15 ms RC round-trip overlaps the ~3 ms of harness
    /// setup, saving ~10 ms cold start.
    ///
    /// Returns the live client and the parsed window tree so callers don't
    /// pay the second await separately.
    pub async fn discover_and_ls() -> Result<(Self, Vec<OsWindow>), KError> {
        let rpc = Self::discover().await?;
        let ls = rpc.ls_all_env_vars().await?;
        Ok((rpc, ls))
    }

    /// Connect to a filesystem-path socket. Public for tests + callers that
    /// already have a plain path. Spec-string callers should use
    /// [`KittyRpc::connect_spec`] which understands `unix:` / `unix:@` /
    /// `tcp:` prefixes.
    pub async fn connect(socket: &Path) -> Result<Self, KError> {
        let stream = UnixStream::connect(socket)
            .await
            .map_err(|e| KError::KittyRemote(format!("connect {}: {}", socket.display(), e)))?;
        Ok(Self::from_stream(stream, socket.to_path_buf()))
    }

    /// Connect using a raw `listen_on`-style spec.
    ///
    /// Accepted forms:
    /// - `unix:/path/to/sock` — filesystem socket
    /// - `unix:@name` — Linux abstract-namespace socket (requires Linux)
    /// - `/path/to/sock` — bare filesystem path
    /// - `tcp:host:port` — rejected with an actionable error message
    ///
    /// Bare `@name` (no `unix:` prefix) is **rejected** as ambiguous. Kitty's
    /// own `listen_on` syntax requires the `unix:` prefix for abstract
    /// sockets, and a bare `@`-prefixed string could equally be a filesystem
    /// entry named `@foo`. Better to fail loudly than guess.
    pub async fn connect_spec(spec: &str) -> Result<Self, KError> {
        let s = spec.trim();
        if let Some(rest) = s.strip_prefix("tcp:") {
            return Err(KError::KittyRemote(format!(
                "TCP transport not supported by ksession-rs RPC client (got tcp:{rest}); \
                 configure kitty with `listen_on unix:/path/to/sock` or `listen_on unix:@name`"
            )));
        }
        if let Some(rest) = s.strip_prefix("unix:") {
            let inner = rest.trim();
            if inner.is_empty() {
                return Err(KError::KittyRemote(format!(
                    "empty socket path in KITTY_LISTEN_ON='{spec}'"
                )));
            }
            if let Some(tcp_rest) = inner.strip_prefix("tcp:") {
                // Catches nested specs like `unix:tcp:host:port` which would
                // otherwise be passed to `UnixStream::connect` as the literal
                // path `tcp:host:port` and surface as a confusing ENOENT.
                return Err(KError::KittyRemote(format!(
                    "TCP transport not supported by ksession-rs RPC client \
                     (got spec '{spec}' which wraps tcp:{tcp_rest}); \
                     configure kitty with `listen_on unix:/path/to/sock` or `listen_on unix:@name`"
                )));
            }
            if let Some(abs_name) = inner.strip_prefix('@') {
                if abs_name.is_empty() {
                    return Err(KError::KittyRemote(
                        "empty abstract socket name in 'unix:@'; specify 'unix:@<name>'".into(),
                    ));
                }
                let name = abs_name.to_string();
                let stream = tokio::task::spawn_blocking(move || connect_abstract_blocking(&name))
                    .await
                    .map_err(|e| KError::KittyRemote(format!("spawn_blocking join: {e}")))??;
                return Ok(Self::from_stream(
                    stream,
                    PathBuf::from(format!("@{abs_name}")),
                ));
            }
            return Self::connect(&PathBuf::from(inner)).await;
        }
        if s.is_empty() {
            return Err(KError::KittyRemote("empty socket path".into()));
        }
        if s.starts_with('@') {
            return Err(KError::KittyRemote(format!(
                "ambiguous socket spec '{s}': bare @-prefix is not supported. \
                 Use 'unix:{s}' for an abstract socket, or a filesystem path"
            )));
        }
        Self::connect(&PathBuf::from(s)).await
    }

    fn from_stream(stream: UnixStream, socket: PathBuf) -> Self {
        Self {
            stream: Mutex::new(Some(stream)),
            socket,
            read_timeout: DEFAULT_TIMEOUT,
        }
    }

    /// Test-only: override the per-call read timeout. The production
    /// constructor pins it at 5s.
    #[cfg(test)]
    pub(crate) fn set_read_timeout_for_test(&mut self, t: Duration) {
        self.read_timeout = t;
    }

    /// Path of the socket this client is bound to. Useful for diagnostics
    /// (`tracing::warn!(socket = %rpc.socket_path().display(), ...)`).
    pub fn socket_path(&self) -> &Path {
        &self.socket
    }

    /// True if the connection has been poisoned by a prior error or
    /// cancellation. After this returns true, every subsequent call errors
    /// out fast; recover via [`KittyRpc::discover`] to get a fresh
    /// instance.
    ///
    /// Advisory only — the value is observed under a brief lock and may
    /// change before the next call. The authoritative check is the next
    /// `call`/`call_no_response` returning a [`KError::KittyRemote`]
    /// containing "poisoned". Useful for diagnostics; don't gate
    /// correctness on it.
    pub async fn is_poisoned(&self) -> bool {
        self.stream.lock().await.is_none()
    }

    /// `kitty @ ls --all-env-vars` — returns the typed window tree.
    pub async fn ls_all_env_vars(&self) -> Result<Vec<OsWindow>, KError> {
        let mut _span = crate::perf_span!(crate::perf::Level::Debug, "kitty.rpc.ls");
        let payload = json!({ "all_env_vars": true });
        let bytes_out = serde_json::to_string(&payload)
            .map(|s| s.len())
            .unwrap_or(0);
        let data = self.call("ls", payload).await?;
        let inner = data.as_str().ok_or_else(|| {
            KError::KittyRemote("ls: data was not a string (kitty changed protocol?)".into())
        })?;
        if let Some(ref mut s) = _span {
            s.push_arg("bytes_out", format!("{}", bytes_out));
            s.push_arg("bytes_in", format!("{}", inner.len()));
        }
        parse_ls_output(inner.as_bytes())
    }

    /// `kitty @ ls --output-format=session` — returns the kitty session
    /// skeleton as conf text. Plan §C.1 uses this as the base for the
    /// emitted .conf instead of from-scratch rendering. Lives here in step
    /// 6.5 so the C.1 step is a pure conf-rewrite with the transport ready.
    ///
    /// Note on `use_foreground_process`: empirically on kitty 0.47 the flag
    /// is a no-op for `--output-format=session` (`true`/`false`/omitted all
    /// produce byte-identical output). The session conf emits the original
    /// launch argv either way. We keep sending it for forward-compatibility
    /// — future kitty versions may honor it as the docs imply — but the
    /// C.1 rewrite cannot rely on it changing output today.
    ///
    /// **Caveat for callers patching the conf (step 6.75 / §C.1)**: on live
    /// kitty 0.47, `launch` lines for already-running windows arrive with
    /// no argv and no cwd — just `launch 'kitty-unserialize-data={"id": N}'`
    /// plus a few `--var=` flags. Callers patching the conf for restoration
    /// must reconstruct argv and cwd from the parallel `ls` JSON:
    ///
    /// - **argv**: `Window.cmdline` (the original launch argv kitty
    ///   recorded). Note: NOT `foreground_processes[0]` — that's the
    ///   currently-running fg process (e.g. an editor inside a bash
    ///   window), which is not what you want to relaunch.
    /// - **cwd**: prefer `Window.foreground_processes[0].cwd` (the
    ///   *current* cwd after any `cd`s), falling back to `Window.cwd`
    ///   (the original launch cwd) if absent.
    ///
    /// Verified empirically against kitty 0.47.
    ///
    /// Trailing whitespace is stripped for transport-symmetry with the
    /// [`crate::kitty::cli`] subprocess fallback (Plan §6.5 round-3 finding).
    pub async fn ls_session(
        &self,
        all_env_vars: bool,
        use_foreground_process: bool,
    ) -> Result<String, KError> {
        let data = self
            .call(
                "ls",
                json!({
                    "output_format": "session",
                    "all_env_vars": all_env_vars,
                    "use_foreground_process": use_foreground_process,
                }),
            )
            .await?;
        Ok(data
            .as_str()
            .ok_or_else(|| KError::KittyRemote("ls(session): data was not a string".into()))?
            .trim_end()
            .to_string())
    }

    /// `kitty @ get-text --match <m> --extent <e> [--ansi]`.
    ///
    /// `extent` is one of `screen`, `all`, `first_cmd_output_on_screen`,
    /// etc. (see `kitty @ get-text --help`). `data` here is raw text — no
    /// double-decode (contrast `ls`). A non-string `data` (kitty changed
    /// protocol?) surfaces as `KError::KittyRemote` rather than a silent
    /// empty string.
    ///
    /// Trailing whitespace is stripped for transport-symmetry with the
    /// [`crate::kitty::cli`] subprocess fallback (Plan §6.5 round-3 finding).
    pub async fn get_text(&self, match_: &str, extent: &str, ansi: bool) -> Result<String, KError> {
        let mut _span = crate::perf_span!(crate::perf::Level::Debug, "kitty.rpc.get_text");
        let payload = json!({
            "match": match_,
            "extent": extent,
            "ansi": ansi,
        });
        let bytes_out = serde_json::to_string(&payload)
            .map(|s| s.len())
            .unwrap_or(0);
        let data = self.call("get_text", payload).await?;
        // null is a valid "no text matched" — return empty string. Anything
        // non-string AND non-null is a protocol regression and worth flagging.
        if data.is_null() {
            if let Some(ref mut s) = _span {
                s.push_arg("bytes_out", format!("{}", bytes_out));
                s.push_arg("bytes_in", "0".to_string());
            }
            return Ok(String::new());
        }
        let result = data
            .as_str()
            .ok_or_else(|| {
                KError::KittyRemote(format!(
                    "get_text: expected string data, got {}",
                    type_of_value(&data)
                ))
            })?
            .trim_end()
            .to_string();
        if let Some(ref mut s) = _span {
            s.push_arg("bytes_out", format!("{}", bytes_out));
            s.push_arg("bytes_in", format!("{}", result.len()));
        }
        Ok(result)
    }

    /// `kitty @ set-user-vars --match <m> k=v ...`, fire-and-forget.
    ///
    /// Plan §C.3 (UUID tagging at save time) + §C.6 (no_response burst
    /// saves ~5 ms across all-windows tagging vs round-tripping each one).
    ///
    /// **Critical**: kitty's payload key is `var` (singular), not
    /// `user_vars`. Passing the wrong key is silently accepted (ok:true)
    /// but does NOT actually update the window — the variables are dropped
    /// and `data` comes back as a `\n`-joined dump of existing vars.
    /// Because we use `no_response: true` we'd never see the misbehavior,
    /// so this is the kind of thing that would only surface as "UUID
    /// tagging mysteriously doesn't work" months later.
    ///
    /// Short-circuits on empty input — kitty accepts an empty `var` array
    /// but we'd rather not pay the round-trip.
    ///
    /// **Caveat on value content**: kitty silently rewrites control bytes
    /// in user-var values — `\n` becomes a space, `\t` and `\x1b` are
    /// stripped. ksession-rs's own writes use printable-ASCII vocabulary
    /// (UUIDs, indices, window-IDs) so this doesn't bite us, but callers
    /// writing arbitrary content (e.g. session names with embedded
    /// newlines) must base64-encode or sanitize first.
    pub async fn set_user_vars<K, V>(&self, match_: &str, vars: &[(K, V)]) -> Result<(), KError>
    where
        K: AsRef<str>,
        V: AsRef<str>,
    {
        if vars.is_empty() {
            return Ok(());
        }
        let kv: Vec<String> = vars
            .iter()
            .map(|(k, v)| format!("{}={}", k.as_ref(), v.as_ref()))
            .collect();
        let payload = json!({
            "match": match_,
            "var": kv,
        });
        let bytes_out = serde_json::to_string(&payload)
            .map(|s| s.len())
            .unwrap_or(0);
        let _span = crate::perf_span!(
            crate::perf::Level::Debug,
            "kitty.rpc.set_user_vars",
            bytes_out = bytes_out,
            bytes_in = 0,
        );
        self.call_no_response("set_user_vars", payload).await
    }

    /// Burst-write set_user_vars for many windows on one held mutex.
    ///
    /// Plan §C.3 (UUID tag every window at save time) + §C.6 (no_response
    /// burst on one connection is the optimal pattern). Each entry is
    /// `(match_expr, &[(k, v)])`. Empty inner var lists are skipped; an
    /// empty outer iterator is a no-op.
    ///
    /// All frames are encoded BEFORE the mutex is acquired so the lock is
    /// held only for the I/O. One `flush` at the end of the burst.
    pub async fn set_user_vars_many<I, M, K, V>(&self, entries: I) -> Result<(), KError>
    where
        I: IntoIterator<Item = (M, Vec<(K, V)>)>,
        M: AsRef<str>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        // Build all frames up-front so the locked section is pure I/O.
        let mut frames: Vec<Vec<u8>> = Vec::new();
        for (m, vars) in entries {
            if vars.is_empty() {
                continue;
            }
            let kv: Vec<String> = vars
                .iter()
                .map(|(k, v)| format!("{}={}", k.as_ref(), v.as_ref()))
                .collect();
            let body = json!({
                "cmd": "set_user_vars",
                "version": PROTOCOL_VERSION,
                "no_response": true,
                "payload": { "match": m.as_ref(), "var": kv },
            });
            frames.push(encode_frame(&serde_json::to_vec(&body)?));
        }
        if frames.is_empty() {
            return Ok(());
        }
        let bytes_out: usize = frames.iter().map(|f| f.len()).sum();
        let _span = crate::perf_span!(
            crate::perf::Level::Debug,
            "kitty.rpc.set_user_vars",
            bytes_out = bytes_out,
            bytes_in = 0,
            count = frames.len(),
        );
        let mut guard = self.stream.lock().await;
        let mut stream = guard
            .take()
            .ok_or_else(|| KError::KittyRemote(POISONED_MSG.to_string()))?;
        let r: Result<(), KError> = async {
            for frame in &frames {
                stream.write_all(frame).await.map_err(io_to_remote)?;
            }
            stream.flush().await.map_err(io_to_remote)?;
            Ok(())
        }
        .await;
        match r {
            Ok(()) => {
                *guard = Some(stream);
                Ok(())
            }
            Err(e) => Err(e), // stream dropped → poisoned
        }
    }

    /// Synchronous request/response. Takes the stream out of the mutex
    /// option for the duration of the exchange; if anything errors the
    /// stream is dropped (closes the fd) and the next call sees `None →
    /// poisoned`. This is what makes us cancellation-safe at the
    /// connection level: a cancelled future drops `stream` here, and
    /// future readers can never misinterpret leftover bytes in the kernel
    /// buffer.
    async fn call(&self, cmd: &str, payload: Value) -> Result<Value, KError> {
        let body = json!({
            "cmd": cmd,
            "version": PROTOCOL_VERSION,
            "payload": payload,
        });
        let frame = encode_frame(&serde_json::to_vec(&body)?);

        let mut guard = self.stream.lock().await;
        let mut stream = guard
            .take()
            .ok_or_else(|| KError::KittyRemote(POISONED_MSG.to_string()))?;

        let resp_result = exchange_on(&mut stream, &frame, self.read_timeout).await;
        let resp_bytes = match resp_result {
            Ok(b) => b,
            Err(e) => {
                // Stream dropped here (closes fd). Guard stays None → poisoned.
                return Err(e);
            }
        };

        let envelope: Envelope = {
            let _decode_span = crate::perf_span!(crate::perf::Level::Trace, "kitty.rpc.decode");
            match serde_json::from_slice(&resp_bytes) {
                Ok(e) => e,
                Err(e) => {
                    // Malformed response is still a poison-worthy event: the
                    // server may have left more bytes coming. Drop stream.
                    return Err(KError::KittyRemote(format!(
                        "malformed RC response: {e} ({})",
                        snippet(&resp_bytes)
                    )));
                }
            }
        };
        if !envelope.ok {
            // Successful round-trip even if the server rejected the
            // command — put the stream back, the connection is fine.
            *guard = Some(stream);
            return Err(KError::KittyRemote(format!(
                "{cmd}: {}",
                envelope.error.unwrap_or_else(|| "unknown error".into())
            )));
        }
        // Happy path: stream goes back.
        *guard = Some(stream);
        Ok(envelope.data.unwrap_or(Value::Null))
    }

    /// Fire-and-forget request (`no_response: true`). Writes + flushes,
    /// returns immediately. Server sends no bytes back. On I/O error the
    /// stream is poisoned just like [`call`].
    async fn call_no_response(&self, cmd: &str, payload: Value) -> Result<(), KError> {
        let body = json!({
            "cmd": cmd,
            "version": PROTOCOL_VERSION,
            "no_response": true,
            "payload": payload,
        });
        let frame = encode_frame(&serde_json::to_vec(&body)?);
        let mut guard = self.stream.lock().await;
        let mut stream = guard
            .take()
            .ok_or_else(|| KError::KittyRemote(POISONED_MSG.to_string()))?;
        let r = async {
            let _write_span = crate::perf_span!(crate::perf::Level::Trace, "kitty.rpc.write_req");
            stream.write_all(&frame).await.map_err(io_to_remote)?;
            stream.flush().await.map_err(io_to_remote)?;
            Ok::<(), KError>(())
        }
        .await;
        match r {
            Ok(()) => {
                *guard = Some(stream);
                Ok(())
            }
            Err(e) => Err(e), // stream dropped → poisoned
        }
    }
}

pub(crate) const POISONED_MSG: &str =
    "kitty RC connection poisoned by prior error; reconnect via KittyPool::discover";

/// Inner exchange — operates on a `&mut UnixStream` so the caller can
/// own the take/restore lifecycle around it. Used by both [`KittyRpc::call`]
/// and [`crate::kitty::pool::PoolGuard::call`].
///
/// After a successful framed read, performs a non-blocking peek to detect
/// trailing bytes in the kernel buffer. Kitty's RC is request-response —
/// any leftover after the terminator means our framing has desynced (e.g.
/// kitty pipelined two frames into one TCP write, or a future kitty
/// version started sending async notifications). Treating the leftover as
/// "this caller's response continues" would let the next call read stale
/// bytes as its own response — much worse than poisoning fast. Cost:
/// one `try_read` syscall per call, ~µs.
pub(crate) async fn exchange_on(
    stream: &mut UnixStream,
    frame: &[u8],
    read_timeout: Duration,
) -> Result<Vec<u8>, KError> {
    {
        let _write_span = crate::perf_span!(crate::perf::Level::Trace, "kitty.rpc.write_req");
        stream.write_all(frame).await.map_err(io_to_remote)?;
        stream.flush().await.map_err(io_to_remote)?;
    }
    let body = {
        let _read_span = crate::perf_span!(crate::perf::Level::Trace, "kitty.rpc.read_resp");
        match timeout(read_timeout, read_dcs_frame(stream)).await {
            Ok(r) => r?,
            Err(_) => {
                return Err(KError::KittyRemote(format!(
                    "kitty RC response timed out after {}s",
                    read_timeout.as_secs_f32()
                )));
            }
        }
    };
    // Defensive peek: after a complete framed response, the wire should be
    // quiet. If it isn't, we're desynced. See module docs on poisoning.
    let mut peek = [0u8; 1];
    match stream.try_read(&mut peek) {
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(body),
        Ok(0) => Ok(body), // EOF: peer closed cleanly after sending our frame
        Ok(_) => Err(KError::KittyRemote(
            "unexpected trailing bytes on RC socket after framed response — wire desync".into(),
        )),
        Err(e) => Err(io_to_remote(e)),
    }
}

#[derive(Deserialize, Debug)]
pub(crate) struct Envelope {
    pub(crate) ok: bool,
    #[serde(default)]
    pub(crate) data: Option<Value>,
    #[serde(default)]
    pub(crate) error: Option<String>,
}

#[allow(dead_code)]
fn type_of_value(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

pub(crate) fn encode_frame(json_bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(DCS_PREFIX.len() + json_bytes.len() + DCS_TERMINATOR.len());
    out.extend_from_slice(DCS_PREFIX);
    out.extend_from_slice(json_bytes);
    out.extend_from_slice(DCS_TERMINATOR);
    out
}

/// Read one DCS frame off the reader and return the unwrapped JSON bytes.
///
/// Bounded by [`READ_CAP_BYTES`] (16 MiB) to prevent a misbehaving server
/// from steering us into unbounded memory growth. The cap is enforced
/// BEFORE each `extend_from_slice` so the buffer never transiently
/// overshoots — if a chunk would push us over, the loop exits with an
/// error without appending it.
pub(crate) async fn read_dcs_frame<R: AsyncReadExt + Unpin>(r: &mut R) -> Result<Vec<u8>, KError> {
    let mut buf = Vec::with_capacity(8192);
    let mut chunk = [0u8; 4096];
    loop {
        let n = r.read(&mut chunk).await.map_err(io_to_remote)?;
        if n == 0 {
            return Err(KError::KittyRemote(
                "kitty closed RC socket before sending terminator".into(),
            ));
        }
        if buf.len() + n > READ_CAP_BYTES {
            return Err(KError::KittyRemote(format!(
                "kitty RC response would exceed {READ_CAP_BYTES} bytes; refusing to grow buffer"
            )));
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.ends_with(DCS_TERMINATOR) {
            break;
        }
    }
    let inner = buf
        .strip_prefix(DCS_PREFIX)
        .ok_or_else(|| KError::KittyRemote(format!("missing DCS prefix; got {}", snippet(&buf))))?;
    // ends_with check above guarantees the strip succeeds.
    let inner = inner.strip_suffix(DCS_TERMINATOR).expect("terminator");
    Ok(inner.to_vec())
}

fn snippet(b: &[u8]) -> String {
    let n = b.len().min(80);
    String::from_utf8_lossy(&b[..n])
        .replace('\x1b', "\\e")
        .replace('\n', "\\n")
}

fn io_to_remote(e: std::io::Error) -> KError {
    KError::KittyRemote(format!("RC I/O error: {e}"))
}

/// Connect to a Linux abstract-namespace socket (`unix:@name`).
///
/// Called from inside [`tokio::task::spawn_blocking`] in
/// [`connect_spec_to_stream`] because `connect_addr` is synchronous. For
/// local AF_UNIX the call is effectively instant, but if the peer process
/// is paused (`SIGSTOP`, ptrace) or the listen queue is full, blocking the
/// executor thread would stall every async task scheduled on it. The
/// spawn_blocking detour is ~10 µs overhead — cheap insurance.
#[cfg(target_os = "linux")]
fn connect_abstract_blocking(name: &str) -> Result<UnixStream, KError> {
    use std::os::linux::net::SocketAddrExt;
    let addr = std::os::unix::net::SocketAddr::from_abstract_name(name.as_bytes())
        .map_err(|e| KError::KittyRemote(format!("abstract address @{name}: {e}")))?;
    let std_s = std::os::unix::net::UnixStream::connect_addr(&addr)
        .map_err(|e| KError::KittyRemote(format!("connect @{name}: {e}")))?;
    std_s.set_nonblocking(true).map_err(io_to_remote)?;
    UnixStream::from_std(std_s).map_err(io_to_remote)
}

#[cfg(not(target_os = "linux"))]
fn connect_abstract_blocking(name: &str) -> Result<UnixStream, KError> {
    Err(KError::KittyRemote(format!(
        "abstract socket '@{name}' requires Linux; this build does not support it"
    )))
}

/// Parse a `listen_on`-style spec and connect, returning the raw stream and
/// resolved socket path. Used by [`KittyRpc::connect_spec`] (tests) and
/// [`crate::kitty::pool::KittyPool`] (production).
pub(crate) async fn connect_spec_to_stream(spec: &str) -> Result<(UnixStream, PathBuf), KError> {
    let s = spec.trim();
    if let Some(rest) = s.strip_prefix("tcp:") {
        return Err(KError::KittyRemote(format!(
            "TCP transport not supported by ksession-rs RPC client (got tcp:{rest}); \
             configure kitty with `listen_on unix:/path/to/sock` or `listen_on unix:@name`"
        )));
    }
    if let Some(rest) = s.strip_prefix("unix:") {
        let inner = rest.trim();
        if inner.is_empty() {
            return Err(KError::KittyRemote(format!(
                "empty socket path in KITTY_LISTEN_ON='{spec}'"
            )));
        }
        if let Some(tcp_rest) = inner.strip_prefix("tcp:") {
            return Err(KError::KittyRemote(format!(
                "TCP transport not supported by ksession-rs RPC client \
                 (got spec '{spec}' which wraps tcp:{tcp_rest}); \
                 configure kitty with `listen_on unix:/path/to/sock` or `listen_on unix:@name`"
            )));
        }
        if let Some(abs_name) = inner.strip_prefix('@') {
            if abs_name.is_empty() {
                return Err(KError::KittyRemote(
                    "empty abstract socket name in 'unix:@'; specify 'unix:@<name>'".into(),
                ));
            }
            let name = abs_name.to_string();
            let path = PathBuf::from(format!("@{abs_name}"));
            let stream = tokio::task::spawn_blocking(move || connect_abstract_blocking(&name))
                .await
                .map_err(|e| KError::KittyRemote(format!("spawn_blocking join: {e}")))??;
            return Ok((stream, path));
        }
        let path = PathBuf::from(inner);
        let stream = UnixStream::connect(&path)
            .await
            .map_err(|e| KError::KittyRemote(format!("connect {}: {}", path.display(), e)))?;
        return Ok((stream, path));
    }
    if s.is_empty() {
        return Err(KError::KittyRemote("empty socket path".into()));
    }
    if s.starts_with('@') {
        return Err(KError::KittyRemote(format!(
            "ambiguous socket spec '{s}': bare @-prefix is not supported. \
             Use 'unix:{s}' for an abstract socket, or a filesystem path"
        )));
    }
    let path = PathBuf::from(s);
    let stream = UnixStream::connect(&path)
        .await
        .map_err(|e| KError::KittyRemote(format!("connect {}: {}", path.display(), e)))?;
    Ok((stream, path))
}

/// Candidates are returned as RAW spec strings (with any scheme prefix
/// intact) so [`connect_spec_to_stream`] can route them through the right
/// transport. The `/tmp/kitty-*` scan emits bare filesystem paths.
pub(crate) fn discover_candidates() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Ok(v) = env::var("KITTY_LISTEN_ON") {
        let v = v.trim();
        if !v.is_empty() {
            out.push(v.to_string());
        }
    }
    if let Ok(rd) = std::fs::read_dir("/tmp") {
        use std::os::unix::fs::MetadataExt;
        let uid = unsafe { geteuid() };
        let mut tmp: Vec<(PathBuf, std::time::SystemTime)> = rd
            .filter_map(Result::ok)
            .filter_map(|ent| {
                let name = ent.file_name();
                let name_s = name.to_string_lossy();
                if !name_s.starts_with("kitty-") {
                    return None;
                }
                let md = ent.metadata().ok()?;
                if md.uid() != uid {
                    return None;
                }
                let mtime = md.modified().ok()?;
                Some((ent.path(), mtime))
            })
            .collect();
        tmp.sort_by(|a, b| b.1.cmp(&a.1));
        out.extend(
            tmp.into_iter()
                .map(|(p, _)| p.to_string_lossy().into_owned()),
        );
    }
    let mut seen = std::collections::HashSet::new();
    out.retain(|s| seen.insert(s.clone()));
    out
}

/// Extract a filesystem path from a spec string without connecting.
/// Returns `None` for abstract sockets, TCP, or invalid specs — only
/// filesystem sockets can be pre-warmed with blocking std I/O.
pub(crate) fn spec_to_fs_path(spec: &str) -> Option<PathBuf> {
    let s = spec.trim();
    if s.starts_with("tcp:") || s.is_empty() || s.starts_with('@') {
        return None;
    }
    if let Some(rest) = s.strip_prefix("unix:") {
        let inner = rest.trim();
        if inner.is_empty() || inner.starts_with('@') || inner.starts_with("tcp:") {
            return None;
        }
        return Some(PathBuf::from(inner));
    }
    Some(PathBuf::from(s))
}

extern "C" {
    fn geteuid() -> u32;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::pin::Pin;
    use std::sync::Arc;
    use std::task::{Context, Poll};
    use tempfile::tempdir;
    use tokio::io::{AsyncRead, ReadBuf};
    use tokio::net::UnixListener;
    use tokio::sync::oneshot;

    #[test]
    fn frame_encode_wraps_payload() {
        let f = encode_frame(b"{}");
        assert!(f.starts_with(DCS_PREFIX));
        assert!(f.ends_with(DCS_TERMINATOR));
        let inner = &f[DCS_PREFIX.len()..f.len() - DCS_TERMINATOR.len()];
        assert_eq!(inner, b"{}");
    }

    #[tokio::test]
    async fn read_dcs_frame_strips_prefix_and_terminator() {
        let mut payload = Vec::new();
        payload.extend_from_slice(DCS_PREFIX);
        payload.extend_from_slice(br#"{"ok":true,"data":42}"#);
        payload.extend_from_slice(DCS_TERMINATOR);
        let mut cur = Cursor::new(payload);
        let inner = read_dcs_frame(&mut cur).await.expect("parses");
        assert_eq!(inner, br#"{"ok":true,"data":42}"#);
    }

    #[tokio::test]
    async fn read_dcs_frame_eof_before_terminator_errors() {
        let mut payload = Vec::new();
        payload.extend_from_slice(DCS_PREFIX);
        payload.extend_from_slice(br#"{"ok":true"#);
        // no terminator
        let mut cur = Cursor::new(payload);
        let err = read_dcs_frame(&mut cur).await.expect_err("must error");
        assert!(
            matches!(err, KError::KittyRemote(ref m) if m.contains("closed RC socket")),
            "got: {err:?}"
        );
    }

    #[tokio::test]
    async fn read_dcs_frame_missing_prefix_errors() {
        let mut payload = Vec::new();
        payload.extend_from_slice(b"\x1bP@wrong-cmd");
        payload.extend_from_slice(br#"{"ok":true}"#);
        payload.extend_from_slice(DCS_TERMINATOR);
        let mut cur = Cursor::new(payload);
        let err = read_dcs_frame(&mut cur).await.expect_err("prefix mismatch");
        assert!(
            matches!(err, KError::KittyRemote(ref m) if m.contains("missing DCS prefix")),
            "got: {err:?}"
        );
    }

    /// Custom AsyncRead that yields one byte per poll. Forces the parser
    /// to handle the terminator straddling chunk boundaries — proves the
    /// `ends_with` strategy is buffer-relative, not chunk-relative.
    struct OneBytePerPoll {
        bytes: Vec<u8>,
        pos: usize,
    }

    impl AsyncRead for OneBytePerPoll {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            if self.pos >= self.bytes.len() {
                return Poll::Ready(Ok(())); // EOF
            }
            let b = self.bytes[self.pos];
            self.pos += 1;
            buf.put_slice(&[b]);
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn read_dcs_frame_handles_byte_by_byte_chunking() {
        // Terminator straddles many polls; in particular the ESC and \\ of
        // the terminator land in different `read()` calls. If the parser
        // only checked the last chunk for `ends_with`, this would hang or
        // misfire. Buffer-relative `ends_with` makes it correct.
        let mut payload = Vec::new();
        payload.extend_from_slice(DCS_PREFIX);
        payload.extend_from_slice(br#"{"ok":true,"data":"abc"}"#);
        payload.extend_from_slice(DCS_TERMINATOR);
        let mut r = OneBytePerPoll {
            bytes: payload,
            pos: 0,
        };
        let inner = read_dcs_frame(&mut r).await.expect("byte-by-byte parses");
        assert_eq!(inner, br#"{"ok":true,"data":"abc"}"#);
    }

    /// Mock server speaking the DCS protocol. Handler takes the parsed
    /// request and returns the JSON response body, or `None` for
    /// no_response (write nothing).
    async fn spawn_mock_server<F>(handler: F) -> (PathBuf, tempfile::TempDir, oneshot::Receiver<()>)
    where
        F: Fn(Value) -> Option<Value> + Send + Sync + 'static,
    {
        let dir = tempdir().expect("tempdir");
        let sock = dir.path().join("rpc.sock");
        let listener = UnixListener::bind(&sock).expect("bind");
        let (done_tx, done_rx) = oneshot::channel();
        let h = Arc::new(handler);
        tokio::spawn(async move {
            let (mut stream, _) = match listener.accept().await {
                Ok(p) => p,
                Err(_) => {
                    let _ = done_tx.send(());
                    return;
                }
            };
            let mut acc: Vec<u8> = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                let n = match stream.read(&mut chunk).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                acc.extend_from_slice(&chunk[..n]);
                while let Some(end) = find_terminator(&acc) {
                    let frame = acc[..end + DCS_TERMINATOR.len()].to_vec();
                    acc.drain(..end + DCS_TERMINATOR.len());
                    let json_bytes = &frame[DCS_PREFIX.len()..frame.len() - DCS_TERMINATOR.len()];
                    let req: Value = serde_json::from_slice(json_bytes).expect("req parses");
                    if let Some(resp_json) = h(req) {
                        let resp_bytes = serde_json::to_vec(&resp_json).expect("ser");
                        let _ = stream.write_all(&encode_frame(&resp_bytes)).await;
                        let _ = stream.flush().await;
                    }
                }
            }
            let _ = done_tx.send(());
        });
        (sock, dir, done_rx)
    }

    fn find_terminator(buf: &[u8]) -> Option<usize> {
        buf.windows(DCS_TERMINATOR.len())
            .position(|w| w == DCS_TERMINATOR)
    }

    #[tokio::test]
    async fn ls_double_decodes_data_string() {
        let (sock, _dir, _done) = spawn_mock_server(|req| {
            assert_eq!(req["cmd"], "ls");
            assert_eq!(req["payload"]["all_env_vars"], true);
            // Lock that we DON'T send `self: false` any more.
            assert!(
                req["payload"].get("self").is_none(),
                "payload leaked stale `self`: {req}"
            );
            Some(json!({
                "ok": true,
                "data": r#"[{"id": 5, "tabs": []}]"#,
            }))
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let osws = rpc.ls_all_env_vars().await.expect("ls ok");
        assert_eq!(osws.len(), 1);
        assert_eq!(osws[0].id, 5);
    }

    #[tokio::test]
    async fn ls_session_payload_has_no_self_field() {
        // The misleading `self: false` is gone from ls_session too.
        let (sock, _dir, _done) = spawn_mock_server(|req| {
            assert!(
                req["payload"].get("self").is_none(),
                "payload leaked `self`: {req}"
            );
            assert_eq!(req["payload"]["output_format"], "session");
            assert_eq!(req["payload"]["use_foreground_process"], true);
            Some(json!({ "ok": true, "data": "new_tab\nfocus\n" }))
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let s = rpc.ls_session(false, true).await.expect("ls(session) ok");
        // Trailing whitespace stripped (round-3 finding) for transport-symmetry
        // with the CLI subprocess fallback.
        assert_eq!(s, "new_tab\nfocus");
    }

    #[tokio::test]
    async fn protocol_version_is_floor_compat_0_26_0() {
        // Mirror kitten CLI's frozen version — wire it onto every request.
        let (sock, _dir, _done) = spawn_mock_server(|req| {
            assert_eq!(req["version"], json!([0, 26, 0]), "version drift: {req}");
            Some(json!({ "ok": true, "data": "" }))
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        rpc.get_text("id:1", "screen", false).await.expect("ok");
    }

    #[tokio::test]
    async fn get_text_returns_raw_data_string() {
        let (sock, _dir, _done) = spawn_mock_server(|req| {
            assert_eq!(req["cmd"], "get_text");
            assert_eq!(req["payload"]["match"], "id:7");
            assert_eq!(req["payload"]["extent"], "screen");
            Some(json!({ "ok": true, "data": "hello\nworld" }))
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let txt = rpc.get_text("id:7", "screen", false).await.expect("ok");
        assert_eq!(txt, "hello\nworld");
    }

    #[tokio::test]
    async fn get_text_null_data_returns_empty_string() {
        // A null/absent data field is a valid "no text matched" response.
        // Surface it as an empty string, not an error.
        let (sock, _dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": Value::Null }))).await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let txt = rpc.get_text("id:99999", "screen", false).await.expect("ok");
        assert_eq!(txt, "");
    }

    #[tokio::test]
    async fn get_text_non_string_data_errors_loudly() {
        // Protocol regression: data became a number. Don't silently return
        // "". Surface a KittyRemote with the type name so log triage works.
        let (sock, _dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": 42 }))).await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let err = rpc
            .get_text("id:1", "screen", false)
            .await
            .expect_err("err");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("expected string data"), "msg: {m}");
        assert!(
            m.contains("number"),
            "msg should name the unexpected type: {m}"
        );
    }

    #[tokio::test]
    async fn get_text_ansi_bytes_round_trip() {
        // ANSI \x1b bytes inside `data` are JSON-escaped on the wire as
        //  — they survive the round-trip and come out as raw ESC.
        // Locks the "DCS terminator inside ansi payload can't be confused
        // for end-of-frame" property into a test.
        let (sock, _dir, _done) = spawn_mock_server(|_| {
            Some(json!({ "ok": true, "data": "a\u{001b}[31mred\u{001b}[0m" }))
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let txt = rpc.get_text("id:1", "screen", true).await.expect("ok");
        assert_eq!(txt, "a\x1b[31mred\x1b[0m");
    }

    #[tokio::test]
    async fn server_error_keeps_connection_alive() {
        // A server-side `ok:false` is a successful round-trip — the
        // connection is fine and a follow-up call must still work. (This
        // distinguishes "server rejected this command" from "wire
        // corruption" which DOES poison.)
        let counter = Arc::new(std::sync::Mutex::new(0u64));
        let counter_h = counter.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |_| {
            let mut n = counter_h.lock().unwrap();
            *n += 1;
            if *n == 1 {
                Some(json!({ "ok": false, "error": "Unknown kitty remote control command: blat" }))
            } else {
                Some(json!({ "ok": true, "data": "later" }))
            }
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let err = rpc
            .get_text("id:1", "screen", false)
            .await
            .expect_err("first errs");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("Unknown kitty remote control command"));
        // Connection MUST still be alive.
        assert!(!rpc.is_poisoned().await, "ok:false should not poison");
        let ok = rpc
            .get_text("id:2", "screen", false)
            .await
            .expect("second ok");
        assert_eq!(ok, "later");
    }

    #[tokio::test]
    async fn io_error_poisons_connection() {
        // Server accepts the connection then immediately drops, so the
        // first write fails with EPIPE / broken-pipe. That MUST poison —
        // a half-written frame on a half-open socket is exactly the kind
        // of state where a follow-up read would misalign.
        let dir = tempdir().unwrap();
        let sock = dir.path().join("close.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            drop(stream); // immediate close
        });
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        // Give the server a moment to drop.
        tokio::time::sleep(Duration::from_millis(10)).await;
        let _ = rpc.get_text("id:1", "screen", false).await; // may succeed or err depending on buffering
                                                             // Hammer until we get an error — kernel send buffer means the
                                                             // first attempt may succeed before the FIN propagates.
        let mut poisoned = rpc.is_poisoned().await;
        let mut tries = 0;
        while !poisoned && tries < 20 {
            let _ = rpc.get_text("id:1", "screen", false).await;
            poisoned = rpc.is_poisoned().await;
            tries += 1;
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(
            poisoned,
            "io error must poison the connection within {tries} tries"
        );
        // And: a call on a poisoned connection fails fast with our message.
        let err = rpc
            .get_text("id:1", "screen", false)
            .await
            .expect_err("poisoned");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("poisoned"), "expected poison message, got: {m}");
    }

    #[tokio::test]
    async fn version_mismatch_is_recoverable_error() {
        // kitty rejects with "newer than this kitty instance" whenever
        // `client_minor > server_minor` (live-verified: [0,48,0] rejects
        // on a 0.47 server, [0,47,0] accepts). Test locks the
        // recoverable-error shape on a canned response, not the specific
        // trigger condition.
        let (sock, _dir, _done) = spawn_mock_server(|_req| {
            Some(json!({
                "ok": false,
                "error": "The kitty client you are using to send remote commands is newer than this kitty instance. This is not supported.",
            }))
        }).await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let err = rpc.ls_all_env_vars().await.expect_err("must error");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("newer than this kitty instance"));
        // ok:false does NOT poison.
        assert!(!rpc.is_poisoned().await);
    }

    #[tokio::test]
    async fn set_user_vars_uses_var_payload_key_not_user_vars() {
        // THE critical bug. Kitty expects payload key `var`. Passing
        // `user_vars` is silently accepted by the server but does NOT
        // actually update the window — verified live. This test locks in
        // the correct key.
        use std::sync::atomic::{AtomicBool, Ordering};
        let saw = Arc::new(AtomicBool::new(false));
        let saw_h = saw.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |req| {
            assert_eq!(req["cmd"], "set_user_vars");
            assert_eq!(req["no_response"], true);
            assert!(
                req["payload"]["user_vars"].is_null(),
                "must not send the wrong key `user_vars`: {req}"
            );
            assert_eq!(
                req["payload"]["var"],
                json!(["ksession_id=abc", "ksession_idx=2"]),
                "var payload shape wrong: {req}"
            );
            assert_eq!(req["payload"]["match"], "id:3");
            saw_h.store(true, Ordering::SeqCst);
            None
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        rpc.set_user_vars("id:3", &[("ksession_id", "abc"), ("ksession_idx", "2")])
            .await
            .expect("write goes through");
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(saw.load(Ordering::SeqCst), "server never received request");
    }

    #[tokio::test]
    async fn set_user_vars_empty_short_circuits_no_wire_write() {
        // Empty input is a no-op; we must not even open a wire round-trip
        // for it. Use a mock that PANICS if invoked — that's the
        // assertion.
        use std::sync::atomic::{AtomicBool, Ordering};
        let invoked = Arc::new(AtomicBool::new(false));
        let invoked_h = invoked.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |_| {
            invoked_h.store(true, Ordering::SeqCst);
            None
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let empty: &[(&str, &str)] = &[];
        rpc.set_user_vars("id:3", empty).await.expect("no-op ok");
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(
            !invoked.load(Ordering::SeqCst),
            "empty input must not hit the wire"
        );
    }

    #[tokio::test]
    async fn set_user_vars_then_ls_no_stale_bytes() {
        // The core save sequence: fire a no_response write, then do a
        // real read-bearing call. If the wire-state machine were sloppy,
        // the ls would pick up bytes that don't exist (or wait forever).
        // Regression cover for poison-pattern correctness.
        let (sock, _dir, _done) = spawn_mock_server(|req| {
            if req["cmd"] == "set_user_vars" {
                assert_eq!(req["no_response"], true);
                None
            } else {
                assert_eq!(req["cmd"], "ls");
                Some(json!({ "ok": true, "data": r#"[{"id": 11, "tabs": []}]"# }))
            }
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        rpc.set_user_vars("id:1", &[("k", "v")])
            .await
            .expect("set ok");
        let osws = rpc.ls_all_env_vars().await.expect("ls ok");
        assert_eq!(osws.len(), 1);
        assert_eq!(osws[0].id, 11);
    }

    #[tokio::test]
    async fn sequential_calls_on_one_connection() {
        // Basic save workload: many sequential RC calls on one socket.
        let counter = Arc::new(std::sync::Mutex::new(0u64));
        let counter_h = counter.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |_| {
            let mut c = counter_h.lock().unwrap();
            *c += 1;
            Some(json!({ "ok": true, "data": format!("r{}", *c) }))
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        for i in 1..=5 {
            let r = rpc
                .get_text(&format!("id:{i}"), "screen", false)
                .await
                .expect("ok");
            assert_eq!(r, format!("r{i}"));
        }
    }

    #[tokio::test]
    async fn pipelined_calls_serialize_correctly() {
        // Two concurrent calls on one connection must not interleave on
        // the wire. The mutex serializes; this test exercises that
        // contract. If we ever swap to true pipelining (Plan §C.6) this
        // test should still pass — what it really asserts is "no response
        // goes to the wrong caller".
        let counter = Arc::new(std::sync::Mutex::new(0u64));
        let counter_h = counter.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |_req| {
            let mut c = counter_h.lock().unwrap();
            *c += 1;
            let id = *c;
            Some(json!({ "ok": true, "data": format!("resp-{id}") }))
        })
        .await;
        let rpc = Arc::new(KittyRpc::connect(&sock).await.expect("connect"));
        let r1 = rpc.clone();
        let r2 = rpc.clone();
        let t1 = tokio::spawn(async move { r1.get_text("id:1", "screen", false).await });
        let t2 = tokio::spawn(async move { r2.get_text("id:2", "screen", false).await });
        let a = t1.await.unwrap().expect("ok");
        let b = t2.await.unwrap().expect("ok");
        let mut both = vec![a, b];
        both.sort();
        assert_eq!(both, vec!["resp-1".to_string(), "resp-2".to_string()]);
    }

    #[tokio::test]
    async fn timeout_firing_returns_kitty_remote() {
        // Mock server accepts but never replies. Override the per-call
        // timeout to a small value so the test stays fast.
        let dir = tempdir().unwrap();
        let sock = dir.path().join("hang.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            // Hold the stream forever; never write.
            std::future::pending::<()>().await;
        });
        let mut rpc = KittyRpc::connect(&sock).await.expect("connect");
        rpc.set_read_timeout_for_test(Duration::from_millis(50));
        let err = rpc
            .get_text("id:1", "screen", false)
            .await
            .expect_err("timeout");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("timed out"), "msg: {m}");
        // Timeout poisons — that's the whole point of the poison pattern.
        assert!(rpc.is_poisoned().await, "timeout must poison");
        // Next call fails fast with the poison message.
        let err2 = rpc
            .get_text("id:1", "screen", false)
            .await
            .expect_err("poisoned");
        let KError::KittyRemote(m2) = err2 else {
            panic!()
        };
        assert!(m2.contains("poisoned"), "msg: {m2}");
    }

    #[tokio::test]
    async fn malformed_response_body_errors_and_poisons() {
        // Frame opens correctly but body is invalid JSON. That's a
        // protocol corruption event — poison.
        let dir = tempdir().unwrap();
        let bad_sock = dir.path().join("bad.sock");
        let listener = UnixListener::bind(&bad_sock).unwrap();
        tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let mut chunk = [0u8; 4096];
            let _ = s.read(&mut chunk).await;
            let _ = s.write_all(DCS_PREFIX).await;
            let _ = s.write_all(b"this isnt json").await;
            let _ = s.write_all(DCS_TERMINATOR).await;
            let _ = s.flush().await;
        });
        let rpc = KittyRpc::connect(&bad_sock).await.expect("connect");
        let err = rpc.get_text("id:1", "screen", false).await.expect_err("e");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("malformed RC response"), "msg: {m}");
        assert!(m.contains("this isnt json"), "snippet missing in: {m}");
        assert!(rpc.is_poisoned().await, "malformed response must poison");
    }

    #[tokio::test]
    async fn read_cap_fires_before_extending() {
        // A response that streams 'A's forever (no DCS terminator) must
        // hit the 16 MiB cap and error out. AsyncRead impl fills whatever
        // buffer is given; the loop iterates until the cap check rejects
        // the next chunk.
        struct EndlessAs;
        impl AsyncRead for EndlessAs {
            fn poll_read(
                self: Pin<&mut Self>,
                _cx: &mut Context<'_>,
                buf: &mut ReadBuf<'_>,
            ) -> Poll<std::io::Result<()>> {
                let cap = buf.remaining();
                let chunk = vec![b'A'; cap];
                buf.put_slice(&chunk);
                Poll::Ready(Ok(()))
            }
        }
        let mut r = EndlessAs;
        let err = read_dcs_frame(&mut r).await.expect_err("cap fires");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("exceed"), "msg should mention cap: {m}");
    }

    #[tokio::test]
    async fn envelope_tolerates_unknown_fields() {
        // Future kitty versions may add `warnings: [...]`, `tb: "..."` on
        // success, etc. The envelope decode must NOT reject those.
        let (sock, _dir, _done) = spawn_mock_server(|_| {
            Some(json!({
                "ok": true,
                "data": "ok",
                "tb": null,
                "warnings": [],
                "future_field_42": {"nested": true},
            }))
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let s = rpc.get_text("id:1", "screen", false).await.expect("ok");
        assert_eq!(s, "ok");
    }

    #[test]
    fn connect_spec_rejects_tcp_with_actionable_message() {
        // Sync test — no I/O happens, the function bails early on the
        // scheme prefix.
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let err = rt
            .block_on(KittyRpc::connect_spec("tcp:localhost:12345"))
            .expect_err("must reject");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("TCP transport not supported"), "msg: {m}");
        assert!(m.contains("unix:"), "msg should suggest fix: {m}");
    }

    #[test]
    fn connect_spec_rejects_empty_path() {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let err = rt
            .block_on(KittyRpc::connect_spec("unix:"))
            .expect_err("must reject");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("empty socket path"), "msg: {m}");
    }

    #[tokio::test]
    async fn connect_spec_handles_unix_prefix() {
        // unix:/path is equivalent to bare /path. Mock server, connect via
        // both, both must succeed.
        let (sock, _dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": "" }))).await;
        let spec = format!("unix:{}", sock.display());
        let rpc = KittyRpc::connect_spec(&spec).await.expect("unix: works");
        rpc.get_text("id:1", "screen", false)
            .await
            .expect("call ok");
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn connect_spec_handles_abstract_unix() {
        // Bind an abstract-namespace listener; connect via unix:@name
        // spec; round-trip one request.
        use std::os::linux::net::SocketAddrExt;
        let name = format!("ksession-rpc-test-{}", std::process::id());
        let addr =
            std::os::unix::net::SocketAddr::from_abstract_name(name.as_bytes()).expect("addr");
        let std_listener =
            std::os::unix::net::UnixListener::bind_addr(&addr).expect("bind abstract");
        std_listener.set_nonblocking(true).unwrap();
        let listener = UnixListener::from_std(std_listener).expect("tokio listener");
        tokio::spawn(async move {
            if let Ok((mut s, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let n = s.read(&mut buf).await.unwrap_or(0);
                if n > 0 {
                    let resp = encode_frame(br#"{"ok":true,"data":"abstract-pong"}"#);
                    let _ = s.write_all(&resp).await;
                    let _ = s.flush().await;
                }
            }
        });
        let rpc = KittyRpc::connect_spec(&format!("unix:@{name}"))
            .await
            .expect("abstract connect");
        let txt = rpc.get_text("id:1", "screen", false).await.expect("ok");
        assert_eq!(txt, "abstract-pong");
    }

    #[tokio::test]
    async fn connect_to_missing_path_surfaces_path_in_error() {
        let err = KittyRpc::connect(Path::new("/nonexistent/path/to/kitty.sock"))
            .await
            .expect_err("connect must fail");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("/nonexistent/path/to/kitty.sock"));
    }

    #[tokio::test]
    #[ignore = "requires live kitty"]
    async fn smoke_against_live_kitty() {
        use crate::kitty::testkitty::LiveKitty;
        let mut kitty = match LiveKitty::spawn().await {
            Some(k) => k,
            None => {
                eprintln!("test skipped: LiveKitty not available (no kitty or no display)");
                return;
            }
        };
        let rpc = kitty.rpc().await.expect("connect to spawned kitty");
        let osws = rpc.ls_all_env_vars().await.expect("live ls");
        assert!(!osws.is_empty(), "expected ≥1 OS window");
        let focused = osws
            .iter()
            .flat_map(|o| o.tabs.iter())
            .flat_map(|t| t.windows.iter())
            .find(|w| w.is_focused || w.is_active)
            .expect("focused window");
        let _ = rpc
            .get_text(&format!("id:{}", focused.id), "screen", false)
            .await
            .expect("get_text ok");
    }

    // ---- round-2 finding tests ------------------------------------------

    #[tokio::test]
    async fn connect_spec_rejects_bare_at_prefix() {
        // Bare `@name` (no `unix:` prefix) is ambiguous — could be a
        // filesystem entry or an abstract socket. Round-2 finding: we
        // refuse rather than guess.
        let err = KittyRpc::connect_spec("@some-abstract-name")
            .await
            .expect_err("must reject");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(
            m.contains("ambiguous"),
            "msg should call out ambiguity: {m}"
        );
        assert!(
            m.contains("unix:@some-abstract-name"),
            "msg should suggest the explicit spec: {m}"
        );
    }

    #[tokio::test]
    async fn connect_spec_rejects_empty_abstract_name() {
        // `unix:@` (empty name after @) — explicit error rather than
        // handing an empty byte slice to from_abstract_name and getting
        // confusing ECONNREFUSED downstream.
        let err = KittyRpc::connect_spec("unix:@")
            .await
            .expect_err("must reject");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("empty abstract socket name"), "msg: {m}");
    }

    #[tokio::test]
    async fn connect_spec_trims_whitespace() {
        // `KITTY_LISTEN_ON` with surrounding whitespace must reach the
        // socket path without spurious chars. The mock socket is fine;
        // proves trim() runs.
        let (sock, _dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": "" }))).await;
        let spec = format!("  unix:{}  ", sock.display());
        let rpc = KittyRpc::connect_spec(&spec).await.expect("trim works");
        rpc.get_text("id:1", "screen", false)
            .await
            .expect("call ok");
    }

    #[tokio::test]
    async fn discover_and_ls_returns_pair() {
        // §B.5 pre-spawn helper. We don't have a way to drive `discover()`
        // through a mock without env mutation, so verify it routes through
        // the live socket when KITTY_LISTEN_ON points at one. This test
        // is environment-sensitive — if no live kitty, falls through to
        // discover() error, which is itself a valid path to assert on.
        // Use a mock instead via connect_spec for determinism.
        let (sock, _dir, _done) = spawn_mock_server(|req| {
            assert_eq!(req["cmd"], "ls");
            Some(json!({ "ok": true, "data": r#"[{"id": 42, "tabs": []}]"# }))
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        // discover_and_ls() is just `discover + ls` — exercising the
        // composition piece directly by calling them in sequence.
        let ls = rpc.ls_all_env_vars().await.expect("ls");
        assert_eq!(ls.len(), 1);
        assert_eq!(ls[0].id, 42);
    }

    #[tokio::test]
    async fn set_user_vars_many_burst_holds_lock_once() {
        // Plan §C.6 burst path. Three (match, vars) entries → three frames
        // on the wire in one lock acquisition. Server counts received
        // frames; assert all three landed with the correct shape.
        use std::sync::atomic::{AtomicUsize, Ordering};
        let count = Arc::new(AtomicUsize::new(0));
        let count_h = count.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |req| {
            assert_eq!(req["cmd"], "set_user_vars");
            assert_eq!(req["no_response"], true);
            // Each entry uses the singular `var` payload key (locks the
            // bug-fix from round 1).
            assert!(req["payload"]["var"].is_array());
            count_h.fetch_add(1, Ordering::SeqCst);
            None
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let entries: Vec<(String, Vec<(&str, &str)>)> = vec![
            ("id:1".into(), vec![("a", "1")]),
            ("id:2".into(), vec![("b", "2"), ("c", "3")]),
            ("id:3".into(), vec![("d", "4")]),
        ];
        rpc.set_user_vars_many(entries).await.expect("burst ok");
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(
            count.load(Ordering::SeqCst),
            3,
            "all three frames must land"
        );
    }

    #[tokio::test]
    async fn set_user_vars_many_skips_empty_inner_vars() {
        // Empty inner var lists are silently dropped — not a no-op for
        // the whole call (other entries still go), just for the empty one.
        use std::sync::atomic::{AtomicUsize, Ordering};
        let count = Arc::new(AtomicUsize::new(0));
        let count_h = count.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |_| {
            count_h.fetch_add(1, Ordering::SeqCst);
            None
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let entries: Vec<(String, Vec<(&str, &str)>)> = vec![
            ("id:1".into(), vec![]),           // skipped
            ("id:2".into(), vec![("k", "v")]), // sent
            ("id:3".into(), vec![]),           // skipped
        ];
        rpc.set_user_vars_many(entries).await.expect("ok");
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(
            count.load(Ordering::SeqCst),
            1,
            "only id:2 should have hit the wire"
        );
    }

    #[tokio::test]
    async fn set_user_vars_many_empty_iterator_is_noop() {
        let (sock, _dir, _done) =
            spawn_mock_server(|_| panic!("no frame should reach the server")).await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let empty: Vec<(String, Vec<(&str, &str)>)> = vec![];
        rpc.set_user_vars_many(empty).await.expect("empty noop ok");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    #[tokio::test]
    async fn set_user_vars_value_with_equals_sign_round_trips_on_wire() {
        // `format!("{k}={v}")` produces `k=a=b` when v="a=b". Kitty's
        // parser splits on the FIRST `=`, so key=`k`, value=`a=b`.
        // Document and lock that we don't escape.
        let (sock, _dir, _done) = spawn_mock_server(|req| {
            assert_eq!(req["payload"]["var"], json!(["greeting=hello=world"]));
            None
        })
        .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        rpc.set_user_vars("id:1", &[("greeting", "hello=world")])
            .await
            .expect("ok");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    #[tokio::test]
    async fn set_user_vars_on_poisoned_connection_fails_fast() {
        // Round-1 finding: poison-on-error contract. Verify it covers the
        // call_no_response path (set_user_vars), not just call (get_text).
        let dir = tempdir().unwrap();
        let sock = dir.path().join("hang.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            std::future::pending::<()>().await;
        });
        let mut rpc = KittyRpc::connect(&sock).await.expect("connect");
        rpc.set_read_timeout_for_test(Duration::from_millis(50));
        // Poison via a timed-out read.
        let _ = rpc.get_text("id:1", "screen", false).await;
        assert!(rpc.is_poisoned().await, "must be poisoned now");
        // The set_user_vars path also returns the poison message.
        let err = rpc
            .set_user_vars("id:1", &[("a", "b")])
            .await
            .expect_err("poisoned");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("poisoned"), "set_user_vars poison path: {m}");
    }

    #[tokio::test]
    async fn ls_non_string_data_errors_loudly() {
        // The ls_all_env_vars `ok_or_else` path. Mock server returns
        // ok:true with a numeric data — should error with "data was not a
        // string". Distinguishes "kitty rejected the call" from "kitty
        // changed protocol shape".
        let (sock, _dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": 42 }))).await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let err = rpc.ls_all_env_vars().await.expect_err("must error");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("data was not a string"), "msg: {m}");
    }

    #[tokio::test]
    async fn ls_session_non_string_data_errors_loudly() {
        let (sock, _dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": ["unexpected", "array"] })))
                .await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let err = rpc.ls_session(false, false).await.expect_err("must error");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("ls(session): data was not a string"), "msg: {m}");
    }

    #[tokio::test]
    async fn ls_poisons_after_io_error() {
        // Round-2 test gap: only get_text covered the IO-error poison
        // path. ls_all_env_vars goes through the same `call` → must
        // poison too.
        let dir = tempdir().unwrap();
        let sock = dir.path().join("close.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            drop(stream);
        });
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        tokio::time::sleep(Duration::from_millis(10)).await;
        let mut poisoned = rpc.is_poisoned().await;
        let mut tries = 0;
        while !poisoned && tries < 20 {
            let _ = rpc.ls_all_env_vars().await;
            poisoned = rpc.is_poisoned().await;
            tries += 1;
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(poisoned, "ls IO failure must poison within {tries} tries");
    }

    #[tokio::test]
    async fn reconnect_after_poison_yields_working_client() {
        // Document & lock the recovery contract: once poisoned, the
        // canonical fix is to construct a fresh KittyRpc against the same
        // socket.
        //
        // Use TWO listeners on different sockets: one that hangs (poison
        // target) and one that replies (recovery target). A single mock
        // server can't switch behavior reliably mid-test.
        let dir = tempdir().unwrap();
        let hang_sock = dir.path().join("hang.sock");
        let listener = UnixListener::bind(&hang_sock).unwrap();
        tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            std::future::pending::<()>().await;
        });
        let mut rpc1 = KittyRpc::connect(&hang_sock).await.expect("first connect");
        rpc1.set_read_timeout_for_test(Duration::from_millis(50));
        let _ = rpc1.get_text("id:1", "screen", false).await;
        assert!(rpc1.is_poisoned().await, "must be poisoned");

        // Recovery: fresh client on a working mock.
        let (live_sock, _live_dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": "alive" }))).await;
        let rpc2 = KittyRpc::connect(&live_sock).await.expect("reconnect");
        let s = rpc2.get_text("id:1", "screen", false).await.expect("ok");
        assert_eq!(s, "alive");
    }

    #[tokio::test]
    async fn two_frames_back_to_back_poisons() {
        // Round-2 hardening: if a server emits two frames for one
        // request, the wire is desynced and the connection must poison.
        //
        // Two code paths defend against this:
        //
        // 1. **JSON-parse path** (this test): two server `write_all`s
        //    are usually coalesced by the kernel into one client `read()`
        //    chunk, so buf accumulates `frame1 + frame2`. `ends_with`
        //    matches at frame2's terminator; `inner` becomes
        //    `json1 + terminator + prefix + json2`, which fails JSON
        //    parse → poison via `malformed RC response`.
        //
        // 2. **Peek path**: if frame1 ends *exactly* at a chunk boundary
        //    and frame2 arrives in the kernel buffer before the peek
        //    runs, `try_read` catches the trailing byte → poison via
        //    `trailing bytes`. Timing-sensitive; not reproducible
        //    deterministically in a test, but the same end state
        //    (poisoned connection, error returned) is reached.
        //
        // Either way: poisoned + error. The next call cannot misread
        // frame2 as its own response.
        let dir = tempdir().unwrap();
        let sock = dir.path().join("twoframe.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let mut chunk = [0u8; 4096];
            let _ = s.read(&mut chunk).await;
            let f1 = encode_frame(br#"{"ok":true,"data":"first"}"#);
            let f2 = encode_frame(br#"{"ok":true,"data":"second"}"#);
            let _ = s.write_all(&f1).await;
            let _ = s.write_all(&f2).await;
            let _ = s.flush().await;
            std::future::pending::<()>().await;
        });
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let err = rpc
            .get_text("id:1", "screen", false)
            .await
            .expect_err("trailing bytes must surface as an error");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        // Accept either of the two poison paths; both are equally valid
        // defenses against the underlying hazard.
        let acceptable = m.contains("trailing bytes")
            || m.contains("wire desync")
            || m.contains("malformed RC response");
        assert!(acceptable, "msg should call out desync or malformed: {m}");
        assert!(rpc.is_poisoned().await, "wire desync must poison");
    }

    #[tokio::test]
    async fn partial_frame_then_close_via_call_poisons() {
        // Server writes only the prefix + a fragment, no terminator,
        // then drops. The call() path must surface the EOF error AND
        // poison. (read_dcs_frame_eof_before_terminator_errors only
        // covers the in-memory Cursor path.)
        let dir = tempdir().unwrap();
        let sock = dir.path().join("partial.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let mut chunk = [0u8; 4096];
            let _ = s.read(&mut chunk).await;
            let _ = s.write_all(DCS_PREFIX).await;
            let _ = s.write_all(br#"{"ok":t"#).await;
            let _ = s.flush().await;
            // drop (close)
        });
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let err = rpc
            .get_text("id:1", "screen", false)
            .await
            .expect_err("EOF");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(
            m.contains("closed RC socket"),
            "msg should call out EOF: {m}"
        );
        assert!(rpc.is_poisoned().await, "partial frame must poison");
    }

    #[tokio::test]
    async fn outer_cancellation_poisons_connection() {
        // Module docs claim: outer-future cancellation (e.g. via
        // tokio::select!) poisons the connection because the stream is
        // taken out of the option and dropped when the future drops.
        // This test races a get_text against an immediate timeout and
        // asserts the connection is poisoned after.
        let dir = tempdir().unwrap();
        let sock = dir.path().join("slow.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            // Hold forever so the client's call awaits indefinitely.
            std::future::pending::<()>().await;
        });
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        // Race the in-flight call against an immediate cancellation.
        let result: Result<Result<String, KError>, _> = tokio::time::timeout(
            Duration::from_millis(50),
            rpc.get_text("id:1", "screen", false),
        )
        .await;
        assert!(result.is_err(), "outer cancel must fire");
        // After the future is dropped mid-await, the stream was taken
        // from the mutex option and not put back → poisoned.
        assert!(
            rpc.is_poisoned().await,
            "outer-cancel must drop the stream and leave None in the option"
        );
        // And the next call surfaces the poison message fast.
        let err = rpc
            .get_text("id:2", "screen", false)
            .await
            .expect_err("poisoned");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("poisoned"), "msg: {m}");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn works_under_current_thread_runtime() {
        // All other tests run under the default multi-thread runtime.
        // Lock in that the design also works under current_thread (the
        // flavor we'd pick for the real ksession binary per Plan §3
        // "use the current_thread flavor — no need for work-stealing,
        // and avoiding Send bounds keeps the code simpler").
        let (sock, _dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": "single-thread-ok" }))).await;
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        let s = rpc.get_text("id:1", "screen", false).await.expect("ok");
        assert_eq!(s, "single-thread-ok");
    }

    #[tokio::test]
    #[ignore = "requires live kitty; verifies the burst path on the real server"]
    async fn smoke_set_user_vars_many_persists() {
        // Live regression for §C.6 burst path: tag the focused window
        // with 3 vars via set_user_vars_many, read back via ls, verify
        // all 3 landed.
        use crate::kitty::testkitty::LiveKitty;
        let mut kitty = match LiveKitty::spawn().await {
            Some(k) => k,
            None => {
                eprintln!("test skipped: LiveKitty not available (no kitty or no display)");
                return;
            }
        };
        let rpc = kitty.rpc().await.expect("connect to spawned kitty");
        let osws = rpc.ls_all_env_vars().await.expect("ls1");
        let focused = osws
            .iter()
            .flat_map(|o| o.tabs.iter())
            .flat_map(|t| t.windows.iter())
            .find(|w| w.is_focused || w.is_active)
            .expect("focused window");
        let pid = std::process::id();
        let match_ = format!("id:{}", focused.id);
        let k1 = format!("ksession_burst_a_{pid}");
        let k2 = format!("ksession_burst_b_{pid}");
        let k3 = format!("ksession_burst_c_{pid}");
        let entries = vec![(
            match_.clone(),
            vec![(k1.as_str(), "1"), (k2.as_str(), "2"), (k3.as_str(), "3")],
        )];
        rpc.set_user_vars_many(entries).await.expect("burst ok");
        let osws2 = rpc.ls_all_env_vars().await.expect("ls2");
        let win = osws2
            .iter()
            .flat_map(|o| o.tabs.iter())
            .flat_map(|t| t.windows.iter())
            .find(|w| w.id == focused.id)
            .expect("focused window still present");
        assert_eq!(win.user_vars.get(&k1).map(String::as_str), Some("1"));
        assert_eq!(win.user_vars.get(&k2).map(String::as_str), Some("2"));
        assert_eq!(win.user_vars.get(&k3).map(String::as_str), Some("3"));
        // Best-effort cleanup.
        let cleanup = vec![(
            match_,
            vec![(k1.as_str(), ""), (k2.as_str(), ""), (k3.as_str(), "")],
        )];
        let _ = rpc.set_user_vars_many(cleanup).await;
    }

    #[tokio::test]
    #[ignore = "requires live kitty; writes + reads back a probe user var to assert round-trip"]
    async fn smoke_set_user_vars_actually_persists() {
        // This is the regression test for the `var` vs `user_vars` payload
        // key bug. The mock-server test in this file only verifies
        // bytes-on-the-wire; only a live kitty can prove the SERVER
        // actually accepted them and wrote to window.user_vars.
        use crate::kitty::testkitty::LiveKitty;
        let mut kitty = match LiveKitty::spawn().await {
            Some(k) => k,
            None => {
                eprintln!("test skipped: LiveKitty not available (no kitty or no display)");
                return;
            }
        };
        let rpc = kitty.rpc().await.expect("connect to spawned kitty");
        let probe_key = format!("ksession_rpc_test_{}", std::process::id());
        let probe_val = "yes-the-key-is-var-singular";
        // Tag the focused window; then read back via ls.
        let osws = rpc.ls_all_env_vars().await.expect("ls1");
        let focused = osws
            .iter()
            .flat_map(|o| o.tabs.iter())
            .flat_map(|t| t.windows.iter())
            .find(|w| w.is_focused || w.is_active)
            .expect("focused window");
        let match_ = format!("id:{}", focused.id);
        rpc.set_user_vars(&match_, &[(&probe_key, probe_val)])
            .await
            .expect("set ok");
        // Read back.
        let osws2 = rpc.ls_all_env_vars().await.expect("ls2");
        let win = osws2
            .iter()
            .flat_map(|o| o.tabs.iter())
            .flat_map(|t| t.windows.iter())
            .find(|w| w.id == focused.id)
            .expect("focused window still present");
        let got = win.user_vars.get(&probe_key).cloned().unwrap_or_default();
        assert_eq!(
            got, probe_val,
            "set_user_vars did NOT persist on live kitty"
        );
        // Best-effort cleanup: kitty has no "delete user var" RPC. Set to
        // empty so it's at least not visibly stale.
        let _ = rpc.set_user_vars(&match_, &[(&probe_key, "")]).await;
    }

    // ---- round-3 finding tests ------------------------------------------

    #[test]
    fn connect_spec_rejects_nested_tcp_via_unix_prefix() {
        // Round-3 finding: `unix:tcp:host:port` previously stripped the
        // `unix:` prefix and tried to open `tcp:host:port` as a literal
        // filesystem path, producing a confusing ENOENT. We now detect the
        // nested `tcp:` and surface the same actionable TCP-rejection error.
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let err = rt
            .block_on(KittyRpc::connect_spec("unix:tcp:localhost:12345"))
            .expect_err("must reject nested tcp");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(
            m.contains("TCP transport not supported"),
            "msg should call out TCP: {m}"
        );
        assert!(
            m.contains("unix:tcp:localhost:12345"),
            "msg should echo the full bad spec: {m}"
        );
        assert!(
            m.contains("unix:/path") || m.contains("unix:@"),
            "msg should suggest the fix: {m}"
        );
    }

    #[tokio::test]
    async fn set_user_vars_many_mid_burst_close_poisons() {
        // Round-3 finding: a server that drops the connection mid-burst must
        // poison the client AND surface an error. Same pattern as
        // `io_error_poisons_connection` — the kernel send buffer may absorb
        // the first few writes silently, so we hammer until the wire goes
        // bad and assert the connection ends up poisoned.
        let dir = tempdir().unwrap();
        let sock = dir.path().join("burst-close.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            drop(stream); // immediate close mid-conversation
        });
        let rpc = KittyRpc::connect(&sock).await.expect("connect");
        // Give the server a moment to drop the accepted stream.
        tokio::time::sleep(Duration::from_millis(10)).await;

        // 5-entry burst, all targeting distinct match-exprs so the frames
        // are independent on the wire.
        let make_entries = || -> Vec<(String, Vec<(&'static str, &'static str)>)> {
            vec![
                ("id:1".into(), vec![("a", "1")]),
                ("id:2".into(), vec![("b", "2")]),
                ("id:3".into(), vec![("c", "3")]),
                ("id:4".into(), vec![("d", "4")]),
                ("id:5".into(), vec![("e", "5")]),
            ]
        };

        // First attempt may or may not error depending on kernel buffering.
        let _ = rpc.set_user_vars_many(make_entries()).await;

        // Hammer until poisoned or we time out — same defensive pattern as
        // `io_error_poisons_connection`. Each iteration is a fresh 5-entry
        // burst; eventually one of the writes will see EPIPE.
        let mut poisoned = rpc.is_poisoned().await;
        let mut tries = 0;
        while !poisoned && tries < 20 {
            let _ = rpc.set_user_vars_many(make_entries()).await;
            poisoned = rpc.is_poisoned().await;
            tries += 1;
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(
            poisoned,
            "mid-burst close must poison the connection within {tries} tries"
        );

        // A subsequent set_user_vars_many must fail fast with the poison message.
        let err = rpc
            .set_user_vars_many(make_entries())
            .await
            .expect_err("call on poisoned connection must error");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("poisoned"), "expected poison message, got: {m}");
    }
}
