//! Tmux interrogation + restore-script codegen.
//!
//! Mirrors `capture_pane_program_cmd` (ksession.sh:243-306) and
//! `capture_tmux_window` (ksession.sh:311-442) per Plan §5.4 / Appendix A.
//!
//! Two layers:
//!
//! - **RPC**: thin async wrappers over `tmux <subcommand>` subprocesses.
//!   Mirrors the bash field-per-call pattern: tmux escapes non-printable
//!   bytes in `-F` format strings, so any delimiter approach is fragile.
//!   We iterate by `#{window_index}` / `#{pane_id}` and query each field
//!   with `display-message` per Plan §5.4.
//!
//! - **Codegen**: pure function `render_restore_sh` over a
//!   [`RestoreScript`] AST that the adapter assembles. Output is the
//!   bash script the conf renderer eventually invokes as
//!   `bash <restore_sh>` (see `conf::append_program_argv` for
//!   `Program::Tmux`).
//!
//! Plan Appendix B.3.2 contemplates a `tmux -C` control-mode transport
//! (step 7.5). The interface here is shaped so that future swap is
//! drop-in — call sites take an `&impl TmuxIo` rather than calling the
//! subprocess directly. For step 7 the only impl is [`TmuxCli`].
//!
//! ## Notes for the future control-mode impl (per plan §B.3.2)
//!
//! - **Response ordering is FIFO**, not out-of-order. Tmux processes
//!   per-client commands in order (`control.c::control_read_callback` +
//!   the per-client `cmdq` in `cmd-queue.c`), so responses arrive in
//!   `<cmd-num>` order. A `HashMap<u32, oneshot::Sender<_>>` demuxer is
//!   still required, NOT for out-of-order responses but because async
//!   `%`-prefixed notifications interleave between command blocks.
//!   `<cmd-num>` is `u_int` in tmux source (`cmdq_item.number`); use
//!   `u32` to match — wrap is theoretical at `u32::MAX`.
//! - **5-minute kill (`CONTROL_MAXIMUM_AGE = 300000ms` in tmux's
//!   `control.c`).** The read loop must never block: drain the pipe into
//!   unbounded channels, or a bounded channel with a drop policy on
//!   `%output` notifications (the high-bandwidth case). Save flow does
//!   not subscribe to `%output`, but a recursive pane fan-out (§B.2) can
//!   leave ~50 in-flight responses — size the demuxer for that.
//! - **Forward-compat parser rule:** any line starting with `%` that is
//!   not `%begin`/`%end`/`%error` is an async notification — log at
//!   DEBUG and continue, never error. Tmux 3.4+ may add notifications
//!   without a protocol bump.
//! - **`capture-pane -p -C -e`** for application-layer escaping; decode
//!   via [`decode_capture_c`] before returning bytes. Scope the decoder
//!   to capture-pane responses — `display-message`/`list-windows` output
//!   legitimately contains literal `\` bytes that are not octal-escape
//!   prefixes.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use tokio::io::AsyncWriteExt;

use crate::model::Program;

pub mod cache;
pub mod control;
pub use cache::TmuxControlCache;
pub use control::TmuxControl;

// ---------- errors ----------

#[derive(Debug, thiserror::Error)]
pub enum TmuxError {
    #[error("tmux binary not on PATH")]
    NotInstalled,
    #[error("tmux {subcommand}: exit {status}: {stderr}")]
    Subprocess {
        subcommand: String,
        status: i32,
        stderr: String,
    },
    #[error("tmux subprocess io: {0}")]
    Io(#[from] std::io::Error),
    #[error("tmux subprocess timed out")]
    Timeout,
    #[error("tmux: no client attached for pid {0}")]
    NoClient(u32),
    // Control-mode (`tmux -C`) transport errors — see `control.rs`.
    /// The control-mode pipe was closed (`%exit`, child exited, stdin/stdout
    /// EOF). Any in-flight request future resolves to this; any subsequent
    /// `request()` call returns this immediately.
    #[error("tmux control-mode pipe disconnected: {0}")]
    Disconnected(String),
    /// A line on the control-mode pipe did not match the framing grammar
    /// (`%begin`/`%end`/`%error` + cmd-num matching). Contains the offending
    /// line for diagnostics.
    #[error("tmux control-mode parse error: {0}")]
    ControlParseError(String),
}

// ---------- capture-pane -C escape decoder ----------

/// Decode the application-layer escaping produced by
/// `tmux capture-pane -p -C -e` (per plan §B.3.2 "Capture-pane content
/// needs `-C` for safe in-band transport").
///
/// Tmux's `-C` flag emits captured bytes with two transformations:
///
/// - Any byte `<0x20` is rewritten as the four-character sequence
///   `\NNN`, where `NNN` is the byte value as exactly three octal
///   digits (0–7). E.g. `\033` for ESC, `\012` for LF.
/// - A literal backslash is rewritten as the two-character sequence
///   `\\` (two backslash bytes). **Note:** an earlier revision of the
///   plan claimed tmux emits `\134` for literal backslash — that is
///   wrong on tmux 3.4 (and likely all current versions); verified
///   empirically. The decoder accepts `\134` too (it's still a valid
///   `\NNN` octal sequence) so byte-fidelity round-trips through either
///   encoder; tmux's actual emission is `\\`.
///
/// The output is therefore strictly 7-bit printable (no embedded LFs or
/// framing-ambiguous sequences) inside the `%begin/%end` control-mode
/// block. We reverse the encoding here to recover the raw bytes.
///
/// Bytes other than `\` pass through unchanged. A trailing `\` with
/// fewer than three octal digits and no following `\` is preserved
/// verbatim (defensive: in practice tmux always emits a complete
/// escape, but we don't want to panic on truncated input).
///
/// **Important:** this is only valid for the contents of a `capture-pane
/// -p -C` response. Do NOT apply it to general command output
/// (`display-message`, `list-windows`, etc.) — that path is unescaped,
/// and a literal `\` in a window-layout checksum or pane title would be
/// corrupted.
#[must_use]
pub fn decode_capture_c(input: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(input.len());
    let mut i = 0;
    while i < input.len() {
        let b = input[i];
        if b != b'\\' {
            out.push(b);
            i += 1;
            continue;
        }
        // `\\` → single literal backslash. Check this BEFORE the
        // 3-digit octal path so we don't try to parse the second
        // backslash as an octal digit (it isn't, but make the
        // intent explicit).
        if i + 1 < input.len() && input[i + 1] == b'\\' {
            out.push(b'\\');
            i += 2;
            continue;
        }
        // Try to consume three octal digits.
        if i + 3 < input.len() {
            let d0 = input[i + 1];
            let d1 = input[i + 2];
            let d2 = input[i + 3];
            if is_octal_digit(d0) && is_octal_digit(d1) && is_octal_digit(d2) {
                let v = ((d0 - b'0') as u16) * 64 + ((d1 - b'0') as u16) * 8 + ((d2 - b'0') as u16);
                // Three octal digits 000..777 = 0..511, but capture-pane
                // only emits bytes 0..255; if a malformed input would
                // overflow a u8 we fall through to literal passthrough.
                if v <= 0xff {
                    out.push(v as u8);
                    i += 4;
                    continue;
                }
            }
        }
        // No valid `\\` or `\NNN` follows — preserve the backslash verbatim.
        out.push(b);
        i += 1;
    }
    out
}

#[inline]
fn is_octal_digit(b: u8) -> bool {
    matches!(b, b'0'..=b'7')
}

// ---------- tmux version probe ----------

/// Parse the output of `tmux -V` (e.g. `"tmux 3.4\n"`, `"tmux 3.2a\n"`,
/// `"tmux next-3.5\n"`) into a `(major, minor)` tuple.
///
/// Returns `None` if the prefix isn't recognized or the digits don't
/// parse. The minor component strips a trailing letter suffix
/// (`3.2a` → `(3, 2)`); leading `next-` is tolerated for the dev tag.
///
/// Used by the future control-mode impl (plan §B.3.2): on tmux ≥ 3.2
/// spawn `tmux -C attach -r -t '$<sid>'` (where `-r` aliases to
/// `read-only,ignore-size`, race-free vs. post-attach
/// `refresh-client -f ignore-size`).
#[must_use]
pub fn parse_tmux_version(raw: &str) -> Option<(u32, u32)> {
    // Common shapes: "tmux 3.4", "tmux 3.2a", "tmux next-3.5".
    let s = raw.trim();
    let rest = s.strip_prefix("tmux ")?;
    let rest = rest.strip_prefix("next-").unwrap_or(rest);
    let (major_s, minor_s) = rest.split_once('.')?;
    let major: u32 = major_s.parse().ok()?;
    // Trim trailing non-digit suffix (e.g. "2a" → "2").
    let minor_digits: String = minor_s.chars().take_while(|c| c.is_ascii_digit()).collect();
    if minor_digits.is_empty() {
        return None;
    }
    let minor: u32 = minor_digits.parse().ok()?;
    Some((major, minor))
}

/// Raw, trimmed `tmux -V` output (e.g. `tmux 3.4`). `None` when tmux is
/// not installed or the probe fails. Stamped verbatim into tmux-native
/// manifests so restore-time diagnostics can name the exact version.
#[must_use]
pub fn tmux_version_string() -> Option<String> {
    let out = std::process::Command::new("tmux")
        .arg("-V")
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Synchronous one-shot `tmux -V` probe. Returns `None` if tmux isn't
/// installed or the version string doesn't parse.
///
/// Cheap (~5 ms) and used at most once per process lifetime by the
/// control-mode impl to decide between the `-r` attach flag (tmux ≥ 3.2)
/// and the `refresh-client -f ignore-size` fallback.
#[must_use]
pub fn tmux_version() -> Option<(u32, u32)> {
    tmux_version_string().and_then(|s| parse_tmux_version(&s))
}

// ---------- $TMUX env parser ----------

/// Parsed fields from the `$TMUX` environment variable.
///
/// The tmux client sets `$TMUX=<socket_path>,<server_pid>,<session_id>`
/// in the environment of every child process. For example:
/// `/tmp/tmux-1000/default,12345,0`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxEnvInfo {
    pub socket_path: std::path::PathBuf,
    pub server_pid: u32,
    /// Numeric `$<N>` session id of the client. `None` for processes tmux
    /// itself spawns without a session in scope (`status-right #()` jobs,
    /// hooks), which see `-1` here; the socket is still the right server.
    pub session_id: Option<u32>,
}

/// Parse the `$TMUX` environment variable value.
///
/// Format: `<socket_path>,<server_pid>,<session_id>`. The socket_path
/// may contain characters that look like commas on exotic setups, but
/// in practice tmux guarantees it never does (the path comes from
/// `_PATH_TMP` + `tmux-<uid>/<name>` in tmux source). We split from
/// the RIGHT so that a hypothetical comma in the path wouldn't break
/// parsing.
///
/// Returns `None` on empty, malformed, or missing fields; only the
/// session id is lenient (see [`TmuxEnvInfo::session_id`]).
#[must_use]
pub fn parse_tmux_env(tmux_val: &str) -> Option<TmuxEnvInfo> {
    let s = tmux_val.trim();
    if s.is_empty() {
        return None;
    }
    // Split from right: last field is session_id, second-to-last is
    // server_pid, everything before is the socket_path.
    let (rest, session_id_s) = s.rsplit_once(',')?;
    let (socket_path_s, server_pid_s) = rest.rsplit_once(',')?;
    let server_pid: u32 = server_pid_s.parse().ok()?;
    if socket_path_s.is_empty() {
        return None;
    }
    Some(TmuxEnvInfo {
        socket_path: std::path::PathBuf::from(socket_path_s),
        server_pid,
        session_id: session_id_s.parse().ok(),
    })
}

// ---------- bash quoting ----------

/// Quote `s` for inclusion in a generated bash script.
///
/// Output is one of:
/// - The empty string → `''`
/// - All bytes in a permissive POSIX-safe set → returned as-is
/// - Anything else → single-quote wrapped, embedded `'` re-escaped via the
///   classic `'\''` sequence
///
/// This mirrors bash's `printf %q` for byte-clean inputs: the single-quote
/// wrap is bytewise lossless and impossible to misparse, even when the
/// value contains spaces, dollars, backticks, or other shell metacharacters.
#[must_use]
pub fn bash_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".to_string();
    }
    if s.bytes().all(is_bashq_safe) {
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
fn is_bashq_safe(b: u8) -> bool {
    // Deviation from `bash`'s `printf %q`: we deliberately EXCLUDE `:` from
    // the unquoted set even though `%q` leaves it bare. Rationale: the
    // generated restore.sh interpolates these values into tmux target-spec
    // contexts (`-t "$SESS"`, `-t "$SESS:$idx"`), and tmux uses `:` as the
    // session:window.pane separator. Leaving a value like `work:1` unquoted
    // would let `ORIG_SESS=work:1` be reparsed by tmux as
    // session=work,window=1 on every subsequent `-t "$ORIG_SESS"` use. Per
    // the audit, safer than-bash quoting is required here.
    matches!(b,
        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' |
        b'_' | b'.' | b'/' | b'-' | b'@' | b'+' | b','
    )
}

// ---------- Program -> per-pane shell command ----------

/// Translate a captured [`Program`] into the shell command we hand to
/// `tmux new-session` / `new-window` / `split-window` for the pane.
///
/// Returns `None` when no explicit command should be set (the pane just
/// runs tmux's default-shell). This matches the bash empty-`prog_cmd`
/// branch at ksession.sh:399-423.
///
/// The output is a single shell-command string suitable for the
/// `shell-command` arg of `split-window`. Per the bash version, we pass
/// it as a SINGLE argv element so the program is exec'd via the shell —
/// `tmux split-window <cmd>` accepts either a single string (sh -c) or
/// argv tokens after `--`; we use the single-string form for parity with
/// bash's `%q "$prog_cmd"`.
#[must_use]
pub fn program_to_tmux_cmd(p: &Program) -> Option<String> {
    use crate::model::ShellKind;
    let shell_bin = |s: ShellKind| -> &'static str {
        match s {
            ShellKind::Bash => "bash",
            ShellKind::Zsh => "zsh",
            ShellKind::Fish => "fish",
            ShellKind::Sh => "sh",
            ShellKind::Dash => "dash",
            ShellKind::Ash => "ash",
        }
    };

    match p {
        Program::Shell {
            shell,
            venv,
            conda,
            direnv: _,
            oldpwd,
            scrollback: _,
            history: _,
        } => {
            // Mirrors capture_pane_program_cmd's shell arm (ksession.sh:248-268):
            // - non-empty activation context → wrap in `<shell> -c '...; exec <shell>'`
            // - empty context             → return None (tmux uses default-shell)
            let mut parts: Vec<String> = Vec::new();
            if let Some(v) = venv {
                let activate = v.join("bin").join("activate");
                parts.push(format!(
                    "source {}",
                    bash_quote(&activate.display().to_string())
                ));
            } else if let Some(c) = conda {
                if c != "base" {
                    parts.push(format!("conda activate {}", bash_quote(c)));
                }
            }
            if let Some(o) = oldpwd {
                parts.push(format!(
                    "export OLDPWD={}",
                    bash_quote(&o.display().to_string())
                ));
            }
            if parts.is_empty() {
                return None;
            }
            let shell_name = shell_bin(*shell);
            let inner = format!("{}; exec {}", parts.join("; "), shell_name);
            Some(format!("{} -c {}", shell_name, bash_quote(&inner)))
        }

        Program::Nvim { session_vim, .. } => Some(format!(
            "nvim -S {}",
            bash_quote(&session_vim.display().to_string())
        )),

        // ksession.sh:281-296 — `<exe> +N% -- <file>`. We deliberately emit a
        // single literal `%` (the bash version's `%%%%` printf produces
        // `+50%%` on disk; that's a latent bug — less treats the trailing `%`
        // as garbage). Always emit `less` as the exe: the model::Program::Less
        // variant doesn't preserve the original basename (more/most/pg/man),
        // and `less` is the standard installed pager. Matches the conf
        // renderer's existing choice in src/conf/mod.rs.
        Program::Less {
            file,
            byte_offset,
            file_size,
        } => {
            let pct = if *file_size > 0 {
                (byte_offset.saturating_mul(100) / *file_size).min(99)
            } else {
                0
            };
            Some(format!(
                "less +{}% -- {}",
                pct,
                bash_quote(&file.display().to_string())
            ))
        }

        Program::Raw { argv } => {
            if argv.is_empty() {
                return None;
            }
            Some(
                argv.iter()
                    .map(|a| bash_quote(a))
                    .collect::<Vec<_>>()
                    .join(" "),
            )
        }

        // Nested tmux: ksession.sh:298-303 falls through to cmdline. We've
        // lost the pane-program's cmdline by the time we get here, so emit
        // a bare `tmux` and let the user re-attach manually. Full recursive
        // tmux-in-tmux capture is out of scope.
        Program::Tmux { .. } => Some("tmux".to_string()),

        // None means "use tmux default-shell" — bash:267 same behavior.
        Program::BareShell => None,
    }
}

// ---------- RPC: tmux subprocess wrappers ----------

const TMUX_DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);

/// Trait masking the tmux transport so unit tests can stub responses
/// without spawning a real tmux server, and so step 7.5's
/// `tmux -C`-control-mode swap is mechanical.
#[async_trait::async_trait]
pub trait TmuxIo: Sync {
    async fn run(&self, args: &[&str]) -> Result<String, TmuxError>;
    async fn capture_pane_to_file(
        &self,
        pane_id: &str,
        dest: &Path,
        ansi: bool,
    ) -> Result<u64, TmuxError>;
}

/// Subprocess-based [`TmuxIo`] — one `tmux ...` fork per call. The
/// persistent alternative is [`TmuxControl`] (single `tmux -C` pipe).
///
/// With no socket configured the `tmux` binary picks the server itself
/// (`$TMUX` when inside tmux, else the default socket). [`TmuxCli::at_socket`]
/// pins every call to one server via `-S <path>`, which is what the
/// tmux-native session manager needs when it is told to target a session
/// by name rather than the one it is running inside.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TmuxCli {
    socket_path: Option<PathBuf>,
}

impl TmuxCli {
    /// A transport that addresses the server listening on `socket_path`.
    #[must_use]
    pub fn at_socket(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: Some(socket_path.into()),
        }
    }

    /// Quick `tmux -V` probe so adapters can degrade cleanly when tmux is
    /// absent rather than surfacing the lower-level `NotInstalled` error.
    /// Synchronous, ~5ms.
    pub fn is_installed() -> bool {
        std::process::Command::new("tmux")
            .arg("-V")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    /// `tmux [-S <socket>]` with stdio wired for a captured one-shot call.
    fn command(&self) -> tokio::process::Command {
        let mut cmd = tokio::process::Command::new("tmux");
        if let Some(socket) = &self.socket_path {
            cmd.arg("-S").arg(socket);
        }
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());
        cmd
    }
}

#[async_trait::async_trait]
impl TmuxIo for TmuxCli {
    async fn run(&self, args: &[&str]) -> Result<String, TmuxError> {
        let subcmd = args.first().copied().unwrap_or("unknown");
        let _span = crate::perf_span!(crate::perf::Level::Debug, "tmux.cmd", cmd = subcmd,);
        let mut cmd = self.command();
        cmd.args(args);

        let output = {
            // L5: spawn + wait are combined inside `cmd.output()` which
            // does fork+exec+wait in one future. We bracket the entire
            // thing as spawn (the dominant cost is the subprocess lifetime).
            let _spawn_span = crate::perf_span!(crate::perf::Level::Trace, "tmux.subprocess.spawn");
            let result = tokio::time::timeout(TMUX_DEFAULT_TIMEOUT, cmd.output())
                .await
                .map_err(|_| TmuxError::Timeout)?;
            result.map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => TmuxError::NotInstalled,
                _ => TmuxError::Io(e),
            })?
        };

        if !output.status.success() {
            return Err(TmuxError::Subprocess {
                subcommand: args.first().map(|s| (*s).to_string()).unwrap_or_default(),
                status: output.status.code().unwrap_or(-1),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            });
        }
        let result = {
            let _decode_span =
                crate::perf_span!(crate::perf::Level::Trace, "tmux.subprocess.decode_stdout");
            String::from_utf8_lossy(&output.stdout).into_owned()
        };
        Ok(result)
    }

    async fn capture_pane_to_file(
        &self,
        pane_id: &str,
        dest: &Path,
        ansi: bool,
    ) -> Result<u64, TmuxError> {
        // `tmux capture-pane -p -C -e -S - -t <pane>` writes the full
        // scrollback to stdout. The `-C` flag requests application-layer
        // escaping (`\NNN` octal for bytes < 0x20, `\134` for literal
        // backslash) — required by plan §B.3.2 so capture-pane payloads
        // can be safely transported inside `%begin/%end` blocks in the
        // future control-mode impl. We apply the same flag here in the
        // subprocess path for byte-identical output between the two
        // transports; we decode in-process via [`decode_capture_c`]
        // before writing to disk so the on-disk sidecar is the raw
        // scrollback (the consumer is a human eyeballing `less`).
        //
        // We buffer the (escaped) child stdout in memory before decoding
        // because the decoder is byte-for-byte; the typical pane is
        // small (≤ a few hundred KB) and the worst-case scrollback is
        // bounded by tmux's `history-limit` (default 2000 lines).
        let mut cmd = self.command();
        cmd.arg("capture-pane").arg("-p").arg("-C");
        if ansi {
            cmd.arg("-e");
        }
        cmd.args(["-S", "-", "-t", pane_id]);

        let child = {
            let _spawn_span = crate::perf_span!(crate::perf::Level::Trace, "tmux.subprocess.spawn");
            cmd.spawn().map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => TmuxError::NotInstalled,
                _ => TmuxError::Io(e),
            })?
        };

        let output = {
            let _wait_span = crate::perf_span!(crate::perf::Level::Trace, "tmux.subprocess.wait");
            tokio::time::timeout(TMUX_DEFAULT_TIMEOUT, child.wait_with_output())
                .await
                .map_err(|_| TmuxError::Timeout)??
        };
        if !output.status.success() {
            return Err(TmuxError::Subprocess {
                subcommand: "capture-pane".to_string(),
                status: output.status.code().unwrap_or(-1),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            });
        }

        let decoded = {
            let _decode_span =
                crate::perf_span!(crate::perf::Level::Trace, "tmux.subprocess.decode_stdout");
            decode_capture_c(&output.stdout)
        };
        if let Some(parent) = dest.parent() {
            tokio::fs::create_dir_all(parent).await.ok();
        }
        let mut file = tokio::fs::File::create(dest).await?;
        file.write_all(&decoded).await?;
        file.flush().await?;

        Ok(decoded.len() as u64)
    }
}

// ---------- High-level queries ----------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientMeta {
    pub pid: u32,
    pub session: String,
    /// Numeric component of tmux's `#{session_id}` (the `N` from `$<N>`).
    /// Default `0` when the field isn't present (older parsers / stub
    /// fixtures); callers should treat `0` as "unknown" for diagnostics.
    pub session_id: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowMeta {
    pub idx: u32,
    pub name: String,
    /// `true` when the window option `automatic-rename` is off
    /// (`#{automatic-rename}` expands to `0`), i.e. the name was set
    /// explicitly (`rename-window`, `new-window -n`) rather than derived
    /// by tmux from `automatic-rename-format`.
    pub renamed: bool,
    pub layout: String,
    pub active: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneMeta {
    /// Tmux pane id (e.g. `%17`) verbatim.
    pub id: String,
    pub idx: u32,
    pub pid: u32,
    pub cwd: String,
    pub current_command: String,
    pub active: bool,
}

/// Parse `tmux list-clients -F '#{client_pid} #{session_id} #{session_name}'`
/// output into one [`ClientMeta`] per line. Session name is the remainder
/// of the line after the second space — preserves embedded spaces.
///
/// `#{session_id}` is tmux's `$<N>` server-side id (e.g. `$3`); we strip
/// the leading `$` and parse the digits. Lines that lack the id field
/// (older formats / older tmux) are tolerated by treating the second
/// token as a session name iff it does not parse as `$<digits>`.
fn parse_list_clients(raw: &str) -> Vec<ClientMeta> {
    let mut out = Vec::new();
    for line in raw.lines() {
        let line = line.trim_end();
        if line.is_empty() {
            continue;
        }
        // Try the 3-field shape first: pid sid name. Fall back to the
        // legacy 2-field shape (pid name) when the second token isn't a
        // `$<digits>` session id — preserves backwards compatibility
        // with stub fixtures and any caller that passes the old format.
        let mut tokens = line.splitn(3, ' ');
        let Some(pid_s) = tokens.next() else {
            continue;
        };
        let Some(second) = tokens.next() else {
            continue;
        };
        let Ok(pid) = pid_s.parse::<u32>() else {
            continue;
        };
        let (session_id, session) =
            match second.strip_prefix('$').and_then(|d| d.parse::<u32>().ok()) {
                Some(id) => {
                    let Some(name) = tokens.next() else {
                        continue;
                    };
                    (id, name.to_string())
                }
                None => {
                    // Legacy 2-token form: `<pid> <name...>`. The
                    // splitn(3) above leaves the rest in `tokens` — re-join
                    // `second` with whatever remained so embedded spaces
                    // survive.
                    let rest: String = tokens.collect::<Vec<_>>().join(" ");
                    let name = if rest.is_empty() {
                        second.to_string()
                    } else {
                        format!("{second} {rest}")
                    };
                    (0, name)
                }
            };
        out.push(ClientMeta {
            pid,
            session,
            session_id,
        });
    }
    out
}

/// Return the session name + numeric session id the given client pid is
/// attached to, if any.
///
/// Mirrors ksession.sh:321-323 (the awk `'$1==p {print $2; exit}'` step),
/// plus the §4 model addition of the server-side `$<N>` session id.
pub async fn find_session_for_client_pid<T: TmuxIo + ?Sized>(
    tmux: &T,
    client_pid: u32,
) -> Result<(String, u32), TmuxError> {
    let raw = tmux
        .run(&[
            "list-clients",
            "-F",
            "#{client_pid} #{session_id} #{session_name}",
        ])
        .await?;
    parse_list_clients(&raw)
        .into_iter()
        .find(|c| c.pid == client_pid)
        .map(|c| (c.session, c.session_id))
        .ok_or(TmuxError::NoClient(client_pid))
}

/// List the windows in `session`, field-per-call (Plan §5.4): `list-windows`
/// for the indices, then `display-message` for name/automatic-rename/layout/active.
pub async fn list_windows<T: TmuxIo + ?Sized>(
    tmux: &T,
    session: &str,
) -> Result<Vec<WindowMeta>, TmuxError> {
    let raw = tmux
        .run(&["list-windows", "-t", session, "-F", "#{window_index}"])
        .await?;
    let mut out = Vec::new();
    for line in raw.lines() {
        let line = line.trim_end();
        if line.is_empty() {
            continue;
        }
        let Ok(idx) = line.parse::<u32>() else {
            continue;
        };
        let target = format!("{session}:{idx}");
        let name = display_message(tmux, &target, "#{window_name}").await?;
        let auto_rename = display_message(tmux, &target, "#{automatic-rename}").await?;
        let layout = display_message(tmux, &target, "#{window_layout}").await?;
        let active_s = display_message(tmux, &target, "#{window_active}").await?;
        out.push(WindowMeta {
            idx,
            name,
            renamed: auto_rename.trim() == "0",
            layout,
            active: active_s.trim() == "1",
        });
    }
    Ok(out)
}

/// List the panes in `session:win_idx`, field-per-call.
pub async fn list_panes<T: TmuxIo + ?Sized>(
    tmux: &T,
    session: &str,
    win_idx: u32,
) -> Result<Vec<PaneMeta>, TmuxError> {
    let raw = tmux
        .run(&[
            "list-panes",
            "-t",
            &format!("{session}:{win_idx}"),
            "-F",
            "#{pane_id}",
        ])
        .await?;
    let mut out = Vec::new();
    for line in raw.lines() {
        let line = line.trim_end();
        if line.is_empty() {
            continue;
        }
        let id = line.to_string();
        let idx_s = display_message(tmux, &id, "#{pane_index}").await?;
        let pid_s = display_message(tmux, &id, "#{pane_pid}").await?;
        let cwd = display_message(tmux, &id, "#{pane_current_path}").await?;
        let cmd = display_message(tmux, &id, "#{pane_current_command}").await?;
        let active_s = display_message(tmux, &id, "#{pane_active}").await?;
        let Ok(idx) = idx_s.trim().parse::<u32>() else {
            continue;
        };
        let Ok(pid) = pid_s.trim().parse::<u32>() else {
            continue;
        };
        out.push(PaneMeta {
            id,
            idx,
            pid,
            cwd,
            current_command: cmd,
            active: active_s.trim() == "1",
        });
    }
    Ok(out)
}

/// Single field query. Strips the kernel-emitted trailing newline; internal
/// whitespace is preserved.
pub async fn display_message<T: TmuxIo + ?Sized>(
    tmux: &T,
    target: &str,
    fmt: &str,
) -> Result<String, TmuxError> {
    let raw = tmux
        .run(&["display-message", "-p", "-t", target, fmt])
        .await?;
    let mut s = raw;
    if s.ends_with('\n') {
        s.pop();
        if s.ends_with('\r') {
            s.pop();
        }
    }
    Ok(s)
}

// ---------- Restore script codegen ----------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreScript {
    pub session: String,
    pub windows: Vec<RestoreWindow>,
    /// `Some((win_idx, pane_idx))` when a pane was active at capture time.
    pub active_pane: Option<(u32, u32)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreWindow {
    pub idx: u32,
    /// Rendered as `new-session`/`new-window -n <name>`, which also turns
    /// the window's `automatic-rename` off. Empty omits `-n` so tmux names
    /// the restored window from `automatic-rename-format` and keeps it
    /// tracking; the adapter leaves it empty unless the window was renamed.
    pub name: String,
    pub layout: String,
    pub active: bool,
    pub panes: Vec<RestorePane>,
    /// Bug 9/17: per-window active pane index. `Some(idx)` triggers a
    /// `tmux select-pane -t "$SESS:<win_idx>.<idx>"` emission for THIS
    /// window — restoring focus inside every window, not just the
    /// session-active one (which is the Bash overwrite bug at
    /// ksession.sh:381-382). `None` skips the emission for windows
    /// whose active pane couldn't be determined.
    pub active_pane_idx: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestorePane {
    /// Tmux's `%N` id with the leading `%` stripped, for sidecar filenames.
    pub uid: String,
    pub idx: u32,
    pub cwd: String,
    /// `Some(...)` means an explicit shell-command arg; `None` means use
    /// tmux's default-shell (bash:399-423 empty-prog_cmd branch).
    pub cmd: Option<String>,
    /// When `Some`, the generated pane command is wrapped so the saved
    /// scrollback file is cat'd into the terminal before exec-ing the
    /// shell/command. The wrapper guards on file existence so a missing
    /// file is silently skipped.
    pub scrollback_path: Option<PathBuf>,
}

/// Static block every generated restore.sh shares, placed right after the
/// per-session `SESS` assignments: trace-lib sourcing (no-op unless
/// `KSESSION_TRACE_DIR` is set; `KSESSION_TRACE_LIB` overrides the
/// Makefile-installed path) and the live-session guard (`=$SESS` exact
/// match, `KSESSION_FORCE=1` to rebuild instead).
///
/// Embedded via `include_str!` so the bytes are guaranteed verbatim — no
/// `format!` interpolation can perturb the `$SESS` quoting.
pub const RESTORE_SH_HEADER: &str = include_str!("../templates/tmux_restore_header.sh");

/// Final hop of every restore path. A nested `attach-session` is refused
/// from inside a tmux client, so when `$TMUX` is set the script switches
/// the calling client instead; outside tmux (kitty launches restore.sh in
/// a fresh window) it attaches. Plain `exec`, never `__trace_run`: a shell
/// function cannot be exec'd, and tracing a blocking attach is meaningless.
pub const RESTORE_SH_ATTACH: &str = "if [ -n \"${TMUX:-}\" ]; then exec tmux switch-client -t \"=$SESS\"; else exec tmux attach-session -t \"=$SESS\"; fi";

/// Render a [`RestoreScript`] as a self-contained bash script.
///
/// Mirrors the bash heredoc emit in `capture_tmux_window`
/// (ksession.sh:335-438) byte-for-byte modulo the latent `%%%%` bug noted
/// in [`program_to_tmux_cmd`].
///
/// When `KSESSION_TRACE_DIR` is set at restore time, each `tmux <subcmd>`
/// call is wrapped in `__trace_run "tmux.<subcmd>" '{}' tmux <subcmd> …`
/// via the trace library sourced by [`RESTORE_SH_HEADER`].
#[must_use]
pub fn render_restore_sh(rs: &RestoreScript) -> String {
    let mut out = String::with_capacity(1024);
    let sess = &rs.session;

    out.push_str("#!/bin/bash\n");
    let _ = writeln!(
        out,
        "# Auto-generated by ksession. Recreates tmux session '{sess}'."
    );
    out.push_str("set -euo pipefail\n");
    let _ = writeln!(out, "ORIG_SESS={}", bash_quote(sess));
    out.push_str("SESS=\"$ORIG_SESS\"\n");
    // Export the session name for the trace-lib JSONL filename.
    out.push_str("KSESSION_TRACE_SESS=\"$SESS\"\n");
    out.push('\n');
    out.push_str(RESTORE_SH_HEADER);

    // Empty-capture guard: if we have no windows, there's nothing to rebuild.
    // Bail loudly instead of killing the (non-existent) session and trying
    // to attach to a ghost — tmux would exit nonzero on the attach. The
    // live-session attach path above still applies for users who run
    // restore.sh expecting an attach to the named session.
    if rs.windows.is_empty() {
        let _ = writeln!(
            out,
            "echo \"ksession: no captured tmux windows for session $SESS\" >&2"
        );
        out.push_str("exit 1\n");
        return out;
    }

    out.push_str("# Restore path: ensure no stale session of this name exists.\n");
    out.push_str("if tmux has-session -t \"=$SESS\" 2>/dev/null; then\n");
    out.push_str("  __trace_run \"tmux.kill-session\" '{}' tmux kill-session -t \"=$SESS\"\n");
    out.push_str("fi\n\n");

    // Build a tmux command line as a token vector so we can omit
    // `-n <name>` / `-c <cwd>` cleanly when those fields are empty
    // (Bug 3, Bug 4: tmux 3.4 accepts -n '' / -c '' but the result is
    // non-deterministic — omission is what we want).
    fn emit_new_session(out: &mut String, name: &str, cwd: &str, cmd: Option<&str>) {
        let mut toks: Vec<String> = vec![
            "__trace_run".into(),
            "\"tmux.new-session\"".into(),
            "'{}'".into(),
            "tmux".into(),
            "new-session".into(),
            "-d".into(),
            "-s".into(),
            "\"$SESS\"".into(),
        ];
        if !name.is_empty() {
            toks.push("-n".into());
            toks.push(bash_quote(name));
        }
        if !cwd.is_empty() {
            toks.push("-c".into());
            toks.push(bash_quote(cwd));
        }
        if let Some(c) = cmd {
            toks.push(bash_quote(c));
        }
        out.push_str(&toks.join(" "));
        out.push('\n');
    }
    fn emit_new_window(out: &mut String, win_idx: u32, name: &str, cwd: &str, cmd: Option<&str>) {
        let mut toks: Vec<String> = vec![
            "__trace_run".into(),
            "\"tmux.new-window\"".into(),
            "'{}'".into(),
            "tmux".into(),
            "new-window".into(),
            "-t".into(),
            format!("\"$SESS:{win_idx}\""),
        ];
        if !name.is_empty() {
            toks.push("-n".into());
            toks.push(bash_quote(name));
        }
        if !cwd.is_empty() {
            toks.push("-c".into());
            toks.push(bash_quote(cwd));
        }
        if let Some(c) = cmd {
            toks.push(bash_quote(c));
        }
        out.push_str(&toks.join(" "));
        out.push('\n');
    }
    fn emit_split_window(out: &mut String, win_idx: u32, cwd: &str, cmd: Option<&str>) {
        let mut toks: Vec<String> = vec![
            "__trace_run".into(),
            "\"tmux.split-window\"".into(),
            "'{}'".into(),
            "tmux".into(),
            "split-window".into(),
            "-t".into(),
            format!("\"$SESS:{win_idx}\""),
        ];
        if !cwd.is_empty() {
            toks.push("-c".into());
            toks.push(bash_quote(cwd));
        }
        if let Some(c) = cmd {
            toks.push(bash_quote(c));
        }
        out.push_str(&toks.join(" "));
        out.push('\n');
    }

    // Slice 6: scrollback replay. When a pane has a saved scrollback
    // file, wrap its command in a `/bin/sh -c` that cats the scrollback
    // before exec-ing the original command (or $SHELL for bare-shell
    // panes). The file-existence guard (`if [ -f ... ]`) ensures
    // missing files are silently skipped.
    fn scrollback_wrapped_cmd(pane: &RestorePane) -> Option<String> {
        match &pane.scrollback_path {
            None => pane.cmd.clone(),
            Some(path) => {
                let quoted_path = bash_quote(&path.display().to_string());
                let exec_part = match &pane.cmd {
                    None => "exec \"$SHELL\"".to_string(),
                    Some(c) => format!("exec {c}"),
                };
                Some(format!(
                    "/bin/sh -c 'if [ -f {quoted_path} ]; then cat {quoted_path} 2>/dev/null; fi; {exec_part}'"
                ))
            }
        }
    }

    let mut first_window = true;
    for w in &rs.windows {
        let mut first_pane = true;
        for p in &w.panes {
            let effective_cmd = scrollback_wrapped_cmd(p);
            if first_window && first_pane {
                emit_new_session(&mut out, &w.name, &p.cwd, effective_cmd.as_deref());
                // Bug 16: mitigate base-index drift. The bootstrap window
                // landed at the server's `base-index` (0 or 1); move it to
                // the captured first-window index so subsequent
                // `-t "=$SESS:<idx>"` references resolve under either
                // base-index config.
                //
                // Plan §5.4 "move-window base-index 0 edge case": the naive
                // unconditional `move-window` fails in three different ways
                // depending on the relationship between the captured first
                // index and the restore-time `base-index`:
                //
                //   captured == base  → tmux returns "same index: N" (non-fatal
                //                        but spammy); skip the move entirely.
                //   captured >  base  → straightforward relocation; trailing
                //                        `|| true` defensively swallows any
                //                        unexpected error so the body
                //                        continues.
                //   captured <  base  → destination is below the restore-time
                //                        base-index; tmux rejects with
                //                        "index out of range". Without the
                //                        guard, `set -e` would abort the
                //                        entire restore. We skip the move and
                //                        accept the displacement.
                //
                // The TMUX_BASE_INDEX show-options chain resolves the
                // per-session value (falling back to the global, then to 0
                // for a server with no override). `show-options -v` returns
                // exit=0 with empty stdout when no override exists, so the
                // `${TMUX_BASE_INDEX:-0}` parameter expansion at the end is
                // the load-bearing fallback to the documented default.
                //
                // Note: this block runs the FIRST time we emit the bootstrap
                // (`first_window && first_pane`) — it cannot be hoisted out
                // of the loop without re-walking `rs.windows`.
                let _ = writeln!(
                    out,
                    "TMUX_BASE_INDEX=$(tmux show-options -v -t \"=$SESS\" base-index 2>/dev/null \\\n\
                    \x20                  || tmux show-options -gv base-index 2>/dev/null \\\n\
                    \x20                  || echo 0)"
                );
                out.push_str("TMUX_BASE_INDEX=${TMUX_BASE_INDEX:-0}\n");
                let _ = writeln!(
                    out,
                    "if [[ \"{}\" -gt \"$TMUX_BASE_INDEX\" ]]; then\n  \
                     tmux move-window -s \"=$SESS:\" -t \"=$SESS:{}\" 2>/dev/null || true\n\
                     fi",
                    w.idx, w.idx
                );
            } else if first_pane {
                emit_new_window(&mut out, w.idx, &w.name, &p.cwd, effective_cmd.as_deref());
            } else {
                emit_split_window(&mut out, w.idx, &p.cwd, effective_cmd.as_deref());
            }
            first_pane = false;
        }
        if !w.layout.is_empty() {
            let _ = writeln!(
                out,
                "__trace_run \"tmux.select-layout\" '{{}}' tmux select-layout -t \"$SESS:{}\" {}",
                w.idx,
                bash_quote(&w.layout)
            );
        }
        // Bug 9/17: per-window select-pane. Emit one line per window that
        // recorded an active pane — at restore time this restores focus
        // inside EVERY window, not just the session-active one. The Bash
        // version (ksession.sh:381-382) overwrites a single global
        // `active_pane` each iteration, so only the last assignment
        // survived. Emitting per-window here, immediately after this
        // window's `select-layout` (or in its place when layout is
        // empty), keeps the focus restoration co-located with the
        // window's geometry setup.
        if let Some(pane_idx) = w.active_pane_idx {
            // `=` exact-match prefix per plan §5.4 Bug 3: tmux's
            // `cmd-find.c` resolves session/window tokens via start-of-name
            // prefix matching, so `-t "$SESS:0.1"` could spuriously address
            // a different session if `$SESS` was a prefix of a live one.
            // Force exact-name match.
            let _ = writeln!(
                out,
                "__trace_run \"tmux.select-pane\" '{{}}' tmux select-pane -t \"=$SESS:{}.{pane_idx}\"",
                w.idx
            );
        }
        first_window = false;
    }

    out.push('\n');
    // Bug 9/17: the session-level `select-pane` is gone — per-window
    // emissions above handle every window's active pane. The trailer
    // just selects which window to land in (derived from `active_pane`'s
    // window index, or the `RestoreWindow.active` flag as a fallback)
    // before the attach.
    let active_win_idx = rs
        .active_pane
        .map(|(w, _)| w)
        .or_else(|| rs.windows.iter().find(|w| w.active).map(|w| w.idx));
    if let Some(win_idx) = active_win_idx {
        // `=` exact-match prefix per plan §5.4 Bug 3.
        let _ = writeln!(
            out,
            "__trace_run \"tmux.select-window\" '{{}}' tmux select-window -t \"=$SESS:{win_idx}\""
        );
    }
    // Slice 11: ready marker. Touched BEFORE the attach/switch because
    // attach blocks indefinitely. Gated on KSESSION_TRACE_DIR.
    out.push_str("[ -n \"${KSESSION_TRACE_DIR-}\" ] && mkdir -p \"$KSESSION_TRACE_DIR/ready\" && touch \"$KSESSION_TRACE_DIR/ready/tmux-$SESS\"\n");
    out.push_str(RESTORE_SH_ATTACH);
    out.push('\n');

    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use std::path::PathBuf;

    // ---------- decode_capture_c ----------

    /// Helper: encode `raw` the way `tmux capture-pane -p -C` would, so we
    /// can write round-trip tests without spawning tmux. Mirrors
    /// `control_write_output` in tmux's `control.c`.
    fn encode_capture_c(raw: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(raw.len());
        for &b in raw {
            if b == b'\\' {
                out.extend_from_slice(b"\\134");
            } else if b < 0x20 {
                out.push(b'\\');
                out.push(b'0' + (b >> 6));
                out.push(b'0' + ((b >> 3) & 0o7));
                out.push(b'0' + (b & 0o7));
            } else {
                out.push(b);
            }
        }
        out
    }

    #[test]
    fn decode_capture_c_passthrough_printable_ascii() {
        let s = b"hello world 0123 ~ ABC";
        assert_eq!(decode_capture_c(s), s.to_vec());
    }

    #[test]
    fn decode_capture_c_octal_low_bytes() {
        // ESC 0x1b → \033, LF 0x0a → \012, NUL 0x00 → \000.
        assert_eq!(decode_capture_c(b"\\033"), vec![0x1b]);
        assert_eq!(decode_capture_c(b"\\012"), vec![0x0a]);
        assert_eq!(decode_capture_c(b"\\000"), vec![0x00]);
        assert_eq!(decode_capture_c(b"\\037"), vec![0x1f]);
    }

    #[test]
    fn decode_capture_c_literal_backslash() {
        // Per the plan §B.3.2 correction: tmux 3.4 emits `\\` (two
        // backslash bytes) for a literal `\`, NOT `\134`. The decoder
        // accepts both forms — `\134` is still a valid octal escape, so
        // round-trips through the test-helper encoder (which emits
        // `\134`) work, AND round-trips through real tmux (`\\`) work.
        assert_eq!(decode_capture_c(b"\\\\"), vec![b'\\']);
        assert_eq!(decode_capture_c(b"a\\\\b"), b"a\\b".to_vec());
        // Backward-compat with the `\134` form.
        assert_eq!(decode_capture_c(b"\\134"), vec![b'\\']);
        assert_eq!(decode_capture_c(b"a\\134b"), b"a\\b".to_vec());
    }

    #[test]
    fn decode_capture_c_double_backslash_then_octal() {
        // Adjacent escapes must each decode independently. Encodes for
        // the byte sequence `\` then ESC.
        assert_eq!(decode_capture_c(b"\\\\\\033"), vec![b'\\', 0x1b]);
        // ESC then `\`.
        assert_eq!(decode_capture_c(b"\\033\\\\"), vec![0x1b, b'\\']);
    }

    #[test]
    fn decode_capture_c_high_bytes_passthrough() {
        // capture-pane -C only escapes bytes < 0x20 and `\`. 0x7f, 0x80,
        // 0xff arrive as raw bytes.
        let raw = vec![0x7e, 0x7f, 0x80, 0xff];
        assert_eq!(decode_capture_c(&raw), raw);
    }

    #[test]
    fn decode_capture_c_truncated_trailing_backslash() {
        // Defensive: a stray trailing `\` with no octal digits must not
        // panic or eat the byte; preserve it verbatim.
        assert_eq!(decode_capture_c(b"abc\\"), b"abc\\".to_vec());
        assert_eq!(decode_capture_c(b"abc\\1"), b"abc\\1".to_vec());
        assert_eq!(decode_capture_c(b"abc\\12"), b"abc\\12".to_vec());
        // `\\89` is not valid octal (8, 9 are out of range) — preserve.
        assert_eq!(decode_capture_c(b"\\189"), b"\\189".to_vec());
    }

    #[test]
    fn decode_capture_c_ansi_sgr_sequence_roundtrip() {
        // Representative scrollback fragment with an SGR red sequence.
        let raw = b"hi \x1b[31mred\x1b[0m bye\n";
        let encoded = encode_capture_c(raw);
        // Sanity check: encoded must be 7-bit printable.
        for &b in &encoded {
            assert!(
                (0x20..0x7f).contains(&b),
                "encoded byte {b:#x} is outside printable range — encoder bug"
            );
        }
        assert_eq!(decode_capture_c(&encoded), raw.to_vec());
    }

    #[test]
    fn decode_capture_c_roundtrip_full_byte_range() {
        // Every byte 0x00..=0xff must round-trip through encode → decode.
        let raw: Vec<u8> = (0..=0xff).collect();
        let encoded = encode_capture_c(&raw);
        assert_eq!(decode_capture_c(&encoded), raw);
    }

    #[test]
    fn decode_capture_c_specific_byte_pins() {
        // Spec pins: 0x00, 0x1f, 0x20, 0x5c (backslash), 0x7e, 0xff.
        let bytes: Vec<u8> = vec![0x00, 0x1f, 0x20, 0x5c, 0x7e, 0xff];
        let encoded = encode_capture_c(&bytes);
        assert_eq!(decode_capture_c(&encoded), bytes);
    }

    // ---------- parse_tmux_version ----------

    #[test]
    fn parse_version_typical() {
        assert_eq!(parse_tmux_version("tmux 3.4\n"), Some((3, 4)));
        assert_eq!(parse_tmux_version("tmux 3.4"), Some((3, 4)));
        assert_eq!(parse_tmux_version("tmux 2.9"), Some((2, 9)));
    }

    #[test]
    fn parse_version_letter_suffix() {
        // OpenBSD-style 3.2a → (3, 2). 3.3a likewise.
        assert_eq!(parse_tmux_version("tmux 3.2a\n"), Some((3, 2)));
        assert_eq!(parse_tmux_version("tmux 3.3a"), Some((3, 3)));
    }

    #[test]
    fn parse_version_next_prefix() {
        assert_eq!(parse_tmux_version("tmux next-3.5\n"), Some((3, 5)));
    }

    #[test]
    fn parse_version_bad_input_is_none() {
        assert_eq!(parse_tmux_version(""), None);
        assert_eq!(parse_tmux_version("garbage"), None);
        assert_eq!(parse_tmux_version("tmux"), None);
        assert_eq!(parse_tmux_version("tmux 3"), None);
        assert_eq!(parse_tmux_version("tmux a.b"), None);
    }

    #[test]
    fn parse_version_at_3_2_boundary() {
        // Plan §B.3.2: tmux ≥ 3.2 supports `attach-session -r`. Pin the
        // comparison.
        let v = parse_tmux_version("tmux 3.2").unwrap();
        assert!(v >= (3, 2));
        let v = parse_tmux_version("tmux 3.1").unwrap();
        assert!(v < (3, 2));
        let v = parse_tmux_version("tmux 3.2a").unwrap();
        assert!(v >= (3, 2));
    }

    // ---------- bash_quote ----------

    #[test]
    fn bashq_empty() {
        assert_eq!(bash_quote(""), "''");
    }

    #[test]
    fn bashq_passthrough_safe() {
        assert_eq!(bash_quote("foo"), "foo");
        assert_eq!(bash_quote("foo_bar.baz/Qux-123"), "foo_bar.baz/Qux-123");
        // Representative value exercising `@`/`+`/`,`/`-`. `:` was removed
        // from the allowlist (see `is_bashq_safe`) so `user@host,path+x-y`
        // is the new spirit-of-the-test value: all safe-set bytes, no `:`.
        assert_eq!(bash_quote("user@host,path+x-y"), "user@host,path+x-y");
    }

    #[test]
    fn bashq_quotes_colon() {
        // Pin: `:` is tmux's target-syntax separator. Leaving `work:1`
        // unquoted in the restore.sh lets tmux reparse `ORIG_SESS=work:1`
        // as session=work,window=1. Quoting fixes that.
        assert_eq!(bash_quote("work:1"), "'work:1'");
        assert_eq!(bash_quote(":"), "':'");
        assert_eq!(bash_quote("a:b:c"), "'a:b:c'");
    }

    #[test]
    fn bashq_quotes_tab_and_newline_byte_fidelity() {
        // Deviation from `printf %q`'s `$'...'` ANSI-C quoting: we wrap in
        // single quotes and preserve the raw byte. Still valid bash (a
        // single-quoted string accepts any byte including tab/newline
        // literally), just a different encoding. Byte-exact assert.
        assert_eq!(bash_quote("a\tb"), "'a\tb'");
        assert_eq!(bash_quote("a\nb"), "'a\nb'");
    }

    #[test]
    fn bashq_unicode_byte_fidelity() {
        // Stronger than `bashq_unicode_value`: assert byte-exact wrap.
        assert_eq!(bash_quote("löve"), "'löve'");
    }

    #[test]
    fn bashq_quotes_spaces_and_metachars() {
        assert_eq!(bash_quote("hello world"), "'hello world'");
        assert_eq!(bash_quote("a$b`c"), "'a$b`c'");
        assert_eq!(bash_quote("with;semi"), "'with;semi'");
        assert_eq!(bash_quote("\"double\""), "'\"double\"'");
    }

    #[test]
    fn bashq_escapes_embedded_single_quote() {
        assert_eq!(bash_quote("it's"), r#"'it'\''s'"#);
        assert_eq!(bash_quote("'"), r#"''\'''"#);
        assert_eq!(bash_quote("a'b'c"), r#"'a'\''b'\''c'"#);
    }

    #[test]
    fn bashq_unicode_value() {
        let out = bash_quote("löve");
        assert!(out.starts_with('\''), "expected single-quoted: {out}");
        assert!(out.ends_with('\''), "expected single-quoted: {out}");
        assert!(out.contains("löve"));
    }

    #[test]
    fn bashq_no_double_wrap() {
        let out = bash_quote("safe");
        assert_eq!(out.matches('\'').count(), 0);
        let out = bash_quote("not safe");
        assert_eq!(out.matches('\'').count(), 2);
    }

    // ---------- program_to_tmux_cmd ----------

    use crate::model::{Program, ShellKind};

    #[test]
    fn ptc_bare_shell_is_none() {
        assert_eq!(program_to_tmux_cmd(&Program::BareShell), None);
    }

    #[test]
    fn ptc_shell_no_activation_is_none() {
        let p = Program::Shell {
            shell: ShellKind::Bash,
            venv: None,
            conda: None,
            direnv: None,
            oldpwd: None,
            scrollback: None,
            history: None,
        };
        assert_eq!(program_to_tmux_cmd(&p), None);
    }

    #[test]
    fn ptc_shell_with_venv_wraps_in_minus_c() {
        let p = Program::Shell {
            shell: ShellKind::Bash,
            venv: Some(PathBuf::from("/home/u/.venv")),
            conda: None,
            direnv: None,
            oldpwd: None,
            scrollback: None,
            history: None,
        };
        let out = program_to_tmux_cmd(&p).expect("venv → Some");
        assert!(out.starts_with("bash -c "), "got: {out}");
        assert!(out.contains("source /home/u/.venv/bin/activate"));
        assert!(out.contains("exec bash"));
    }

    #[test]
    fn ptc_shell_with_zsh_uses_zsh_binary() {
        let p = Program::Shell {
            shell: ShellKind::Zsh,
            venv: Some(PathBuf::from("/v")),
            conda: None,
            direnv: None,
            oldpwd: None,
            scrollback: None,
            history: None,
        };
        let out = program_to_tmux_cmd(&p).unwrap();
        assert!(out.starts_with("zsh -c "), "got: {out}");
        assert!(out.contains("exec zsh"));
    }

    #[test]
    fn ptc_shell_conda_base_is_skipped() {
        let p = Program::Shell {
            shell: ShellKind::Bash,
            venv: None,
            conda: Some("base".to_string()),
            direnv: None,
            oldpwd: None,
            scrollback: None,
            history: None,
        };
        assert_eq!(program_to_tmux_cmd(&p), None);
    }

    #[test]
    fn ptc_shell_conda_named_emits_activate() {
        let p = Program::Shell {
            shell: ShellKind::Bash,
            venv: None,
            conda: Some("data-sci".to_string()),
            direnv: None,
            oldpwd: None,
            scrollback: None,
            history: None,
        };
        let out = program_to_tmux_cmd(&p).unwrap();
        assert!(out.contains("conda activate data-sci"), "got: {out}");
    }

    #[test]
    fn ptc_shell_venv_wins_over_conda() {
        let p = Program::Shell {
            shell: ShellKind::Bash,
            venv: Some(PathBuf::from("/v")),
            conda: Some("named".to_string()),
            direnv: None,
            oldpwd: None,
            scrollback: None,
            history: None,
        };
        let out = program_to_tmux_cmd(&p).unwrap();
        assert!(out.contains("source /v/bin/activate"));
        assert!(!out.contains("conda activate"));
    }

    #[test]
    fn ptc_shell_oldpwd_only() {
        let p = Program::Shell {
            shell: ShellKind::Bash,
            venv: None,
            conda: None,
            direnv: None,
            oldpwd: Some(PathBuf::from("/prev/dir")),
            scrollback: None,
            history: None,
        };
        let out = program_to_tmux_cmd(&p).unwrap();
        assert!(out.contains("export OLDPWD=/prev/dir"), "got: {out}");
        assert!(out.contains("exec bash"));
    }

    #[test]
    fn ptc_nvim_emits_minus_s() {
        let p = Program::Nvim {
            session_vim: PathBuf::from("/state/nvim/win-7.vim"),
            manifest: None,
            truncated_buffers: 0,
        };
        assert_eq!(
            program_to_tmux_cmd(&p),
            Some("nvim -S /state/nvim/win-7.vim".to_string())
        );
    }

    #[test]
    fn ptc_nvim_path_with_space_is_quoted() {
        let p = Program::Nvim {
            session_vim: PathBuf::from("/state with space/x.vim"),
            manifest: None,
            truncated_buffers: 0,
        };
        assert_eq!(
            program_to_tmux_cmd(&p),
            Some("nvim -S '/state with space/x.vim'".to_string())
        );
    }

    #[test]
    fn ptc_less_clamps_at_99() {
        let p = Program::Less {
            file: PathBuf::from("/log/file"),
            byte_offset: 1_000_000,
            file_size: 100,
        };
        let out = program_to_tmux_cmd(&p).unwrap();
        assert_eq!(out, "less +99% -- /log/file");
    }

    #[test]
    fn ptc_less_size_zero_yields_zero_percent() {
        let p = Program::Less {
            file: PathBuf::from("/empty"),
            byte_offset: 5,
            file_size: 0,
        };
        let out = program_to_tmux_cmd(&p).unwrap();
        assert_eq!(out, "less +0% -- /empty");
    }

    #[test]
    fn ptc_less_emits_single_percent_not_double() {
        // The bash version's `%%%%` printf produces `+50%%` on disk — less
        // interprets the trailing `%` as a syntax error. Anchor that the
        // Rust port writes ONE `%`.
        let p = Program::Less {
            file: PathBuf::from("/f"),
            byte_offset: 5,
            file_size: 10,
        };
        let out = program_to_tmux_cmd(&p).unwrap();
        assert!(out.contains("+50%"), "expected single %, got: {out}");
        assert!(!out.contains("%%"), "double % regressed: {out}");
    }

    #[test]
    fn ptc_raw_joins_with_quoting() {
        let p = Program::Raw {
            argv: vec!["btop".to_string(), "--utf-force".to_string()],
        };
        assert_eq!(
            program_to_tmux_cmd(&p),
            Some("btop --utf-force".to_string())
        );
    }

    #[test]
    fn ptc_raw_argv_quoted_for_spaces() {
        let p = Program::Raw {
            argv: vec!["vi".to_string(), "my file".to_string()],
        };
        assert_eq!(program_to_tmux_cmd(&p), Some("vi 'my file'".to_string()));
    }

    #[test]
    fn ptc_raw_empty_argv_is_none() {
        let p = Program::Raw { argv: Vec::new() };
        assert_eq!(program_to_tmux_cmd(&p), None);
    }

    #[test]
    fn ptc_tmux_nested_yields_bare_tmux() {
        let p = Program::Tmux {
            session_name: "work".into(),
            restore_sh: PathBuf::from("/tmp/r.sh"),
            windows: Vec::new(),
            session_id: 0,
            active_window_idx: None,
        };
        assert_eq!(program_to_tmux_cmd(&p), Some("tmux".into()));
    }

    // ---------- parse_list_clients ----------

    #[test]
    fn parse_clients_typical() {
        // The §4 wire format is `<pid> $<sid> <name>`; parse it loss-free.
        let raw = "1234 $3 main\n5678 $5 work\n";
        assert_eq!(
            parse_list_clients(raw),
            vec![
                ClientMeta {
                    pid: 1234,
                    session: "main".into(),
                    session_id: 3,
                },
                ClientMeta {
                    pid: 5678,
                    session: "work".into(),
                    session_id: 5,
                }
            ]
        );
    }

    #[test]
    fn parse_clients_session_with_spaces() {
        let raw = "9999 $7 my project\n";
        assert_eq!(
            parse_list_clients(raw),
            vec![ClientMeta {
                pid: 9999,
                session: "my project".into(),
                session_id: 7,
            }]
        );
    }

    #[test]
    fn parse_clients_legacy_two_token_form() {
        // Backwards compatibility: a 2-token line (legacy callers / older
        // stub fixtures) still parses, with session_id defaulting to 0.
        let raw = "42 ok\n7 also-ok\n";
        assert_eq!(
            parse_list_clients(raw),
            vec![
                ClientMeta {
                    pid: 42,
                    session: "ok".into(),
                    session_id: 0,
                },
                ClientMeta {
                    pid: 7,
                    session: "also-ok".into(),
                    session_id: 0,
                }
            ]
        );
    }

    #[test]
    fn parse_clients_skips_blank_and_malformed() {
        let raw = "\n42 $1 ok\nnotanint $2 sess\n7 $3 also-ok\n";
        assert_eq!(
            parse_list_clients(raw),
            vec![
                ClientMeta {
                    pid: 42,
                    session: "ok".into(),
                    session_id: 1,
                },
                ClientMeta {
                    pid: 7,
                    session: "also-ok".into(),
                    session_id: 3,
                }
            ]
        );
    }

    #[test]
    fn parse_clients_empty_input() {
        assert!(parse_list_clients("").is_empty());
        assert!(parse_list_clients("\n\n").is_empty());
    }

    // ---------- find_session_for_client_pid (stub TmuxIo) ----------

    #[derive(Default)]
    struct StubTmux {
        list_clients: String,
    }

    #[async_trait::async_trait]
    impl TmuxIo for StubTmux {
        async fn run(&self, args: &[&str]) -> Result<String, TmuxError> {
            if args.first() == Some(&"list-clients") {
                Ok(self.list_clients.clone())
            } else {
                Err(TmuxError::Subprocess {
                    subcommand: args.first().map(|s| (*s).into()).unwrap_or_default(),
                    status: 1,
                    stderr: "stub: unrouted".into(),
                })
            }
        }

        async fn capture_pane_to_file(
            &self,
            _pane_id: &str,
            _dest: &Path,
            _ansi: bool,
        ) -> Result<u64, TmuxError> {
            Err(TmuxError::Subprocess {
                subcommand: "capture-pane".into(),
                status: 1,
                stderr: "stub: unrouted".into(),
            })
        }
    }

    #[tokio::test]
    async fn find_session_hits() {
        let stub = StubTmux {
            list_clients: "100 $1 work\n200 $2 main\n".into(),
        };
        let (s, sid) = find_session_for_client_pid(&stub, 200).await.unwrap();
        assert_eq!(s, "main");
        assert_eq!(sid, 2);
    }

    #[tokio::test]
    async fn find_session_misses_returns_no_client() {
        let stub = StubTmux {
            list_clients: "100 $1 work\n".into(),
        };
        let err = find_session_for_client_pid(&stub, 999).await.unwrap_err();
        assert!(matches!(err, TmuxError::NoClient(999)));
    }

    // ---------- list_panes / display_message (routed stub) ----------
    //
    // A smarter stub than `StubTmux` — routes by the full `args` vec so a
    // test can stage different return values for `pane_pid` of `%1`, `%2`,
    // and `%3` simultaneously.

    #[derive(Default)]
    struct RoutedTmux {
        responses: std::collections::HashMap<Vec<String>, String>,
    }

    impl RoutedTmux {
        fn set(&mut self, args: &[&str], resp: &str) {
            self.responses
                .insert(args.iter().map(|s| (*s).to_string()).collect(), resp.into());
        }
    }

    #[async_trait::async_trait]
    impl TmuxIo for RoutedTmux {
        async fn run(&self, args: &[&str]) -> Result<String, TmuxError> {
            let key: Vec<String> = args.iter().map(|s| (*s).to_string()).collect();
            self.responses
                .get(&key)
                .cloned()
                .ok_or_else(|| TmuxError::Subprocess {
                    subcommand: args.first().map(|s| (*s).to_string()).unwrap_or_default(),
                    status: 1,
                    stderr: format!("routed: unrouted args: {args:?}"),
                })
        }

        async fn capture_pane_to_file(
            &self,
            _pane_id: &str,
            _dest: &Path,
            _ansi: bool,
        ) -> Result<u64, TmuxError> {
            Err(TmuxError::Subprocess {
                subcommand: "capture-pane".into(),
                status: 1,
                stderr: "routed: unrouted".into(),
            })
        }
    }

    #[tokio::test]
    async fn list_panes_skips_garbage_pid_and_keeps_others() {
        // `display-message` for `pane_pid` returns unparseable `"abc"` for
        // `%2`; valid integers for `%1` and `%3`. `list_panes` must skip the
        // bad pane (the `Ok(pid) = pid_s.trim().parse::<u32>()` guard) but
        // return the others.
        let mut stub = RoutedTmux::default();
        // list-panes -> three pane ids
        stub.set(
            &["list-panes", "-t", "demo:0", "-F", "#{pane_id}"],
            "%1\n%2\n%3\n",
        );
        // Per-pane field queries (display-message adds a trailing \n which
        // display_message strips).
        for (id, idx, pid_s) in [
            ("%1", "0", "111\n"),
            ("%2", "1", "abc\n"),
            ("%3", "2", "333\n"),
        ] {
            stub.set(
                &["display-message", "-p", "-t", id, "#{pane_index}"],
                &format!("{idx}\n"),
            );
            stub.set(&["display-message", "-p", "-t", id, "#{pane_pid}"], pid_s);
            stub.set(
                &["display-message", "-p", "-t", id, "#{pane_current_path}"],
                "/cwd\n",
            );
            stub.set(
                &["display-message", "-p", "-t", id, "#{pane_current_command}"],
                "bash\n",
            );
            stub.set(
                &["display-message", "-p", "-t", id, "#{pane_active}"],
                "0\n",
            );
        }

        let panes = list_panes(&stub, "demo", 0).await.unwrap();
        let ids: Vec<&str> = panes.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, vec!["%1", "%3"], "garbage-pid pane %2 must be skipped");
        assert_eq!(panes[0].pid, 111);
        assert_eq!(panes[1].pid, 333);
    }

    #[tokio::test]
    async fn display_message_strips_exactly_one_trailing_newline() {
        // Audit pin: only one trailing newline is stripped. Input "hello\n\n"
        // must yield "hello\n", preserving the inner literal newline.
        let mut stub = RoutedTmux::default();
        stub.set(
            &["display-message", "-p", "-t", "demo:0", "#{any}"],
            "hello\n\n",
        );
        let got = display_message(&stub, "demo:0", "#{any}").await.unwrap();
        assert_eq!(got, "hello\n");
    }

    // ---------- render_restore_sh ----------

    fn mk_script_single() -> RestoreScript {
        RestoreScript {
            session: "demo".to_string(),
            windows: vec![RestoreWindow {
                idx: 0,
                name: "main".to_string(),
                layout: "abcd,80x24,0,0,0".to_string(),
                active: true,
                panes: vec![RestorePane {
                    uid: "1".to_string(),
                    idx: 0,
                    cwd: "/home/u".to_string(),
                    cmd: None,
                    scrollback_path: None,
                }],
                active_pane_idx: Some(0),
            }],
            active_pane: Some((0, 0)),
        }
    }

    #[test]
    fn render_emits_shebang_and_strict_mode() {
        let out = render_restore_sh(&mk_script_single());
        assert!(out.starts_with("#!/bin/bash\n"), "got:\n{out}");
        assert!(out.contains("set -euo pipefail\n"));
    }

    #[test]
    fn render_quotes_session_name() {
        let mut rs = mk_script_single();
        rs.session = "my session".to_string();
        let out = render_restore_sh(&rs);
        assert!(out.contains("ORIG_SESS='my session'"), "got:\n{out}");
    }

    #[test]
    fn render_handles_ksession_force_guard() {
        let out = render_restore_sh(&mk_script_single());
        assert!(out.contains("KSESSION_FORCE"), "missing guard: {out}");
        assert!(out.contains("has-session -t \"=$SESS\""));
        assert!(out.contains("exec tmux attach-session -t \"=$SESS\""));
    }

    #[test]
    fn render_ready_marker_before_attach() {
        let out = render_restore_sh(&mk_script_single());
        // The ready marker line must appear BEFORE the attach-session line.
        let marker_pos = out
            .find("touch \"$KSESSION_TRACE_DIR/ready/tmux-$SESS\"")
            .expect("ready marker line missing from restore.sh");
        // rfind: the same `exec tmux attach-session` text also appears in the
        // live-session early-attach path above; we want the final attach.
        let attach_pos = out
            .rfind("exec tmux attach-session -t \"=$SESS\"")
            .expect("attach-session line missing from restore.sh");
        assert!(
            marker_pos < attach_pos,
            "ready marker must come before attach-session:\n{out}"
        );
        // Gate on KSESSION_TRACE_DIR.
        assert!(
            out.contains(
                "[ -n \"${KSESSION_TRACE_DIR-}\" ] && mkdir -p \"$KSESSION_TRACE_DIR/ready\""
            ),
            "ready marker must be gated on KSESSION_TRACE_DIR:\n{out}"
        );
    }

    #[test]
    fn render_first_pane_first_window_uses_new_session() {
        let out = render_restore_sh(&mk_script_single());
        assert!(
            out.contains("tmux new-session -d -s \"$SESS\" -n main -c /home/u"),
            "first pane/window must be new-session, got:\n{out}"
        );
        assert!(!out.contains("tmux new-window "));
        assert!(!out.contains("tmux split-window "));
    }

    #[test]
    fn render_subsequent_windows_use_new_window() {
        let rs = RestoreScript {
            session: "s".to_string(),
            windows: vec![
                RestoreWindow {
                    idx: 0,
                    name: "w0".to_string(),
                    layout: String::new(),
                    active: false,
                    panes: vec![RestorePane {
                        uid: "1".into(),
                        idx: 0,
                        cwd: "/".into(),
                        cmd: None,
                        scrollback_path: None,
                    }],
                    active_pane_idx: None,
                },
                RestoreWindow {
                    idx: 1,
                    name: "w1".to_string(),
                    layout: String::new(),
                    active: false,
                    panes: vec![RestorePane {
                        uid: "2".into(),
                        idx: 0,
                        cwd: "/".into(),
                        cmd: None,
                        scrollback_path: None,
                    }],
                    active_pane_idx: None,
                },
            ],
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        assert_eq!(out.matches("tmux new-session ").count(), 1);
        assert_eq!(out.matches("tmux new-window ").count(), 1);
        assert!(out.contains("tmux new-window -t \"$SESS:1\" -n w1 -c /"));
    }

    #[test]
    fn render_extra_panes_use_split_window() {
        let rs = RestoreScript {
            session: "s".to_string(),
            windows: vec![RestoreWindow {
                idx: 0,
                name: "w".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![
                    RestorePane {
                        uid: "1".into(),
                        idx: 0,
                        cwd: "/a".into(),
                        cmd: None,
                        scrollback_path: None,
                    },
                    RestorePane {
                        uid: "2".into(),
                        idx: 1,
                        cwd: "/b".into(),
                        cmd: None,
                        scrollback_path: None,
                    },
                    RestorePane {
                        uid: "3".into(),
                        idx: 2,
                        cwd: "/c".into(),
                        cmd: None,
                        scrollback_path: None,
                    },
                ],
                active_pane_idx: None,
            }],
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        assert_eq!(out.matches("tmux new-session ").count(), 1);
        assert_eq!(out.matches("tmux split-window ").count(), 2);
        assert!(out.contains("tmux split-window -t \"$SESS:0\" -c /b"));
        assert!(out.contains("tmux split-window -t \"$SESS:0\" -c /c"));
    }

    #[test]
    fn render_includes_pane_cmd_when_present() {
        let rs = RestoreScript {
            session: "s".to_string(),
            windows: vec![RestoreWindow {
                idx: 0,
                name: "w".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![RestorePane {
                    uid: "1".into(),
                    idx: 0,
                    cwd: "/a".into(),
                    cmd: Some("nvim -S /tmp/foo.vim".to_string()),
                    scrollback_path: None,
                }],
                active_pane_idx: None,
            }],
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        assert!(
            out.contains("tmux new-session -d -s \"$SESS\" -n w -c /a 'nvim -S /tmp/foo.vim'"),
            "got:\n{out}"
        );
    }

    #[test]
    fn render_emits_select_layout_when_layout_nonempty() {
        // tmux layout strings consist of alphanumerics + `,` + `x` — all in
        // the bash_quote "safe" set — so they pass through without quotes.
        // Bash's printf %q would also leave them unquoted.
        let out = render_restore_sh(&mk_script_single());
        assert!(
            out.contains("tmux select-layout -t \"$SESS:0\" abcd,80x24,0,0,0"),
            "got:\n{out}"
        );
    }

    #[test]
    fn render_select_layout_quotes_unsafe_layout_string() {
        // Real tmux layouts contain checksum prefixes that may include any
        // bytes — pin the quoting path for a layout containing a space.
        let mut rs = mk_script_single();
        rs.windows[0].layout = "weird layout".to_string();
        let out = render_restore_sh(&rs);
        assert!(
            out.contains("tmux select-layout -t \"$SESS:0\" 'weird layout'"),
            "got:\n{out}"
        );
    }

    #[test]
    fn render_skips_select_layout_when_empty() {
        let mut rs = mk_script_single();
        rs.windows[0].layout = String::new();
        let out = render_restore_sh(&rs);
        assert!(!out.contains("select-layout"), "got:\n{out}");
    }

    #[test]
    fn render_emits_select_focus_when_active_pane_set() {
        // Bug 9/17: select-pane is now emitted per-window (immediately
        // after each window's select-layout) rather than once globally
        // at the trailer. select-window still appears once, naming the
        // session-active window.
        let out = render_restore_sh(&mk_script_single());
        // Plan §5.4 Bug 3: `=` exact-match prefix on select-window /
        // select-pane (and the other resolution-time targets) prevents
        // tmux's start-of-name prefix matching from addressing a different
        // session with a common prefix.
        assert!(out.contains("tmux select-window -t \"=$SESS:0\""));
        assert!(out.contains("tmux select-pane -t \"=$SESS:0.0\""));
    }

    #[test]
    fn render_omits_select_focus_when_active_pane_none() {
        // Bug 9/17: per-window select-pane is gated on
        // `RestoreWindow.active_pane_idx`, not `RestoreScript.active_pane`.
        // Clear BOTH to test the all-None path. select-window is gated
        // on either the session-active tuple or the `RestoreWindow.active`
        // flag — drop `active` too so neither path emits one.
        let mut rs = mk_script_single();
        rs.active_pane = None;
        rs.windows[0].active_pane_idx = None;
        rs.windows[0].active = false;
        let out = render_restore_sh(&rs);
        assert!(!out.contains("select-window"), "got:\n{out}");
        assert!(!out.contains("select-pane"), "got:\n{out}");
    }

    #[test]
    fn render_final_line_switches_inside_tmux_else_attaches() {
        let out = render_restore_sh(&mk_script_single());
        assert!(
            out.trim_end().ends_with(RESTORE_SH_ATTACH),
            "got tail:\n{}",
            &out[out.len().saturating_sub(200)..]
        );
        assert!(out.contains("exec tmux switch-client -t \"=$SESS\""));
        assert!(out.contains("exec tmux attach-session -t \"=$SESS\""));
        // The runtime branch must key on `$TMUX`, with a `set -u`-safe default.
        assert!(RESTORE_SH_ATTACH.starts_with("if [ -n \"${TMUX:-}\" ]; then"));
    }

    #[test]
    fn live_session_guard_in_header_uses_the_same_attach_line() {
        // The template is the single source for the guard block; its
        // attach branch must stay byte-identical to the tail the renderer
        // emits, otherwise the two paths could drift apart silently.
        assert!(RESTORE_SH_HEADER.contains(RESTORE_SH_ATTACH));
        assert!(RESTORE_SH_HEADER.contains("has-session -t \"=$SESS\""));
        assert!(RESTORE_SH_HEADER.contains("KSESSION_FORCE"));
        // The header is a mid-script fragment: it must not re-declare the
        // interpreter or strict mode the renderer already emitted.
        assert!(!RESTORE_SH_HEADER.contains("#!/bin/bash"));
        assert!(!RESTORE_SH_HEADER.contains("set -euo pipefail"));
    }

    #[test]
    fn render_window_name_with_spaces_is_quoted() {
        let mut rs = mk_script_single();
        rs.windows[0].name = "my window".to_string();
        let out = render_restore_sh(&rs);
        assert!(out.contains("-n 'my window'"), "got:\n{out}");
    }

    #[test]
    fn render_cwd_with_spaces_is_quoted() {
        let mut rs = mk_script_single();
        rs.windows[0].panes[0].cwd = "/path with space".to_string();
        let out = render_restore_sh(&rs);
        assert!(out.contains("-c '/path with space'"), "got:\n{out}");
    }

    #[test]
    fn render_select_layout_with_embedded_quote() {
        // bash_quote escapes embedded `'` via the classic `'\''` sequence.
        let mut rs = mk_script_single();
        rs.windows[0].layout = "a'b,80x24".to_string();
        let out = render_restore_sh(&rs);
        let needle = "tmux select-layout -t \"$SESS:0\" 'a'\\''b,80x24'";
        assert!(out.contains(needle), "expected {needle:?} in:\n{out}");
    }

    #[test]
    fn render_session_name_with_colon_is_quoted() {
        // Integration-level pin for the bash_quote fix: a session name
        // containing `:` must appear single-quoted in ORIG_SESS so tmux
        // doesn't reparse it as session:window.
        let mut rs = mk_script_single();
        rs.session = "work:1".to_string();
        let out = render_restore_sh(&rs);
        assert!(out.contains("ORIG_SESS='work:1'"), "got:\n{out}");
    }

    #[test]
    fn render_session_name_with_tab_preserves_byte() {
        // Single-quote wrap preserves the raw tab byte verbatim (vs `%q`'s
        // `$'...'` ANSI-C quoting). Both are valid bash.
        let mut rs = mk_script_single();
        rs.session = "tab\there".to_string();
        let out = render_restore_sh(&rs);
        assert!(out.contains("ORIG_SESS='tab\there'"), "got:\n{out:?}");
    }

    #[test]
    fn render_pane_cwd_with_unicode_preserved() {
        let mut rs = mk_script_single();
        rs.windows[0].panes[0].cwd = "/home/löve".to_string();
        let out = render_restore_sh(&rs);
        assert!(out.contains("-c '/home/löve'"), "got:\n{out}");
    }

    #[test]
    fn render_empty_windows_emits_safe_script() {
        // Empty-capture: don't kill-session or attach to a ghost. Bail loudly.
        let rs = RestoreScript {
            session: "ghost".to_string(),
            windows: Vec::new(),
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        assert!(
            !out.contains("tmux kill-session"),
            "must not kill-session on empty capture:\n{out}"
        );
        assert!(
            !out.contains("tmux new-session"),
            "must not new-session on empty capture:\n{out}"
        );
        assert!(
            out.contains("ksession: no captured tmux windows for session $SESS"),
            "expected bail message:\n{out}"
        );
        assert!(out.contains("exit 1\n"), "must exit nonzero:\n{out}");
    }

    #[test]
    fn render_empty_windows_still_has_force_guard() {
        // The live-session attach path is still useful even when the
        // captured layout is empty — the user may run restore.sh expecting
        // an attach to the named session.
        let rs = RestoreScript {
            session: "ghost".to_string(),
            windows: Vec::new(),
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        assert!(
            out.contains("KSESSION_FORCE"),
            "force guard missing:\n{out}"
        );
        assert!(
            out.contains("exec tmux attach-session -t \"=$SESS\""),
            "live-session attach path missing:\n{out}"
        );
    }

    // ---------- trace lib sourcing ----------

    #[test]
    fn render_sources_trace_lib() {
        let out = render_restore_sh(&mk_script_single());
        assert!(
            out.contains("KSESSION_TRACE_LIB="),
            "trace lib env var must be set:\n{out}"
        );
        assert!(
            out.contains("source \"$KSESSION_TRACE_LIB\""),
            "trace lib must be sourced:\n{out}"
        );
        // Stub fallback when trace lib is not installed.
        assert!(
            out.contains("__trace_run() { shift 2; \"$@\"; }"),
            "stub fallback must be defined:\n{out}"
        );
    }

    #[test]
    fn render_wraps_tmux_commands_in_trace_run() {
        let out = render_restore_sh(&mk_script_single());
        // Each tmux command should be wrapped with __trace_run.
        assert!(
            out.contains("__trace_run \"tmux.new-session\" '{}' tmux new-session"),
            "new-session not wrapped:\n{out}"
        );
        assert!(
            out.contains("__trace_run \"tmux.select-layout\" '{}' tmux select-layout"),
            "select-layout not wrapped:\n{out}"
        );
        assert!(
            out.contains("__trace_run \"tmux.select-pane\" '{}' tmux select-pane"),
            "select-pane not wrapped:\n{out}"
        );
        assert!(
            out.contains("__trace_run \"tmux.select-window\" '{}' tmux select-window"),
            "select-window not wrapped:\n{out}"
        );
        // attach-session is deliberately NOT wrapped: it's the final `exec`,
        // and `exec` cannot run the `__trace_run` shell function (it needs an
        // external binary). Tracing a blocking attach is meaningless anyway.
        assert!(
            !out.contains("exec __trace_run"),
            "attach must be a plain exec, not exec __trace_run:\n{out}"
        );
    }

    #[test]
    fn render_sets_trace_sess_var() {
        let out = render_restore_sh(&mk_script_single());
        assert!(
            out.contains("KSESSION_TRACE_SESS=\"$SESS\""),
            "KSESSION_TRACE_SESS must be set for JSONL filename:\n{out}"
        );
    }

    // ---------- scrollback replay (Slice 6) ----------

    #[test]
    fn render_scrollback_wraps_bare_shell_pane() {
        // When scrollback_path is Some and cmd is None (bare shell), the
        // emitted command wraps in `/bin/sh -c` with a cat-before-exec
        // pattern using `exec "$SHELL"`.
        let rs = RestoreScript {
            session: "s".to_string(),
            windows: vec![RestoreWindow {
                idx: 0,
                name: "w".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![RestorePane {
                    uid: "1".into(),
                    idx: 0,
                    cwd: "/home/u".into(),
                    cmd: None,
                    scrollback_path: Some(PathBuf::from(
                        "/tmp/state/tmux/sess/win-0/pane-1/scrollback.ansi",
                    )),
                }],
                active_pane_idx: None,
            }],
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        assert!(
            out.contains("if [ -f /tmp/state/tmux/sess/win-0/pane-1/scrollback.ansi ]"),
            "expected file-existence guard for scrollback:\n{out}"
        );
        assert!(
            out.contains("cat /tmp/state/tmux/sess/win-0/pane-1/scrollback.ansi 2>/dev/null"),
            "expected cat of scrollback file:\n{out}"
        );
        assert!(
            out.contains("exec \"$SHELL\""),
            "bare-shell pane should exec $SHELL:\n{out}"
        );
    }

    #[test]
    fn render_scrollback_wraps_command_pane() {
        // When scrollback_path is Some and cmd is Some, the emitted
        // command wraps the original command in exec.
        let rs = RestoreScript {
            session: "s".to_string(),
            windows: vec![RestoreWindow {
                idx: 0,
                name: "w".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![RestorePane {
                    uid: "1".into(),
                    idx: 0,
                    cwd: "/a".into(),
                    cmd: Some("nvim -S /tmp/s.vim".into()),
                    scrollback_path: Some(PathBuf::from("/tmp/sb/pane-1/scrollback.ansi")),
                }],
                active_pane_idx: None,
            }],
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        assert!(
            out.contains("if [ -f /tmp/sb/pane-1/scrollback.ansi ]"),
            "expected file-existence guard:\n{out}"
        );
        assert!(
            out.contains("cat /tmp/sb/pane-1/scrollback.ansi 2>/dev/null"),
            "expected cat of scrollback:\n{out}"
        );
        assert!(
            out.contains("exec nvim -S /tmp/s.vim"),
            "command pane should exec the original command:\n{out}"
        );
        // Must NOT contain exec "$SHELL" — we have a real command.
        assert!(
            !out.contains("exec \"$SHELL\""),
            "command pane must not exec $SHELL:\n{out}"
        );
    }

    #[test]
    fn render_scrollback_two_panes_both_wrapped() {
        // Two-pane window where both panes have scrollback paths: both
        // should emit cat commands.
        let rs = RestoreScript {
            session: "s".to_string(),
            windows: vec![RestoreWindow {
                idx: 0,
                name: "w".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![
                    RestorePane {
                        uid: "1".into(),
                        idx: 0,
                        cwd: "/a".into(),
                        cmd: None,
                        scrollback_path: Some(PathBuf::from("/tmp/sb/pane-1/scrollback.ansi")),
                    },
                    RestorePane {
                        uid: "2".into(),
                        idx: 1,
                        cwd: "/b".into(),
                        cmd: Some("htop".into()),
                        scrollback_path: Some(PathBuf::from("/tmp/sb/pane-2/scrollback.ansi")),
                    },
                ],
                active_pane_idx: None,
            }],
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        assert!(
            out.contains("cat /tmp/sb/pane-1/scrollback.ansi 2>/dev/null"),
            "first pane scrollback missing:\n{out}"
        );
        assert!(
            out.contains("cat /tmp/sb/pane-2/scrollback.ansi 2>/dev/null"),
            "second pane scrollback missing:\n{out}"
        );
        // Both panes should be wrapped in /bin/sh -c
        assert_eq!(
            out.matches("/bin/sh").count(),
            2,
            "expected two /bin/sh -c wrappers:\n{out}"
        );
    }

    #[test]
    fn render_no_scrollback_when_path_is_none() {
        // When scrollback_path is None, no cat/scrollback commands should
        // appear in the output for that pane.
        let rs = RestoreScript {
            session: "s".to_string(),
            windows: vec![RestoreWindow {
                idx: 0,
                name: "w".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![RestorePane {
                    uid: "1".into(),
                    idx: 0,
                    cwd: "/a".into(),
                    cmd: None,
                    scrollback_path: None,
                }],
                active_pane_idx: None,
            }],
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        assert!(
            !out.contains("scrollback"),
            "no scrollback references expected when path is None:\n{out}"
        );
        assert!(
            !out.contains("/bin/sh -c"),
            "no /bin/sh wrapper expected when path is None:\n{out}"
        );
    }

    #[test]
    fn render_no_scrollback_mixed_panes_only_some_get_replay() {
        // PRD-0013 Slice 7 Test 3: in a two-pane window, only the pane with
        // scrollback_path: Some should get the /bin/sh -c cat wrapper. The
        // pane with scrollback_path: None should have no scrollback commands.
        // This is the "re-save with --no-scrollback" case for tmux panes:
        // panes that didn't capture scrollback render without replay.
        let rs = RestoreScript {
            session: "s".to_string(),
            windows: vec![RestoreWindow {
                idx: 0,
                name: "w".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![
                    RestorePane {
                        uid: "1".into(),
                        idx: 0,
                        cwd: "/a".into(),
                        cmd: Some("htop".into()),
                        scrollback_path: Some(PathBuf::from("/tmp/sb/pane-1/scrollback.ansi")),
                    },
                    RestorePane {
                        uid: "2".into(),
                        idx: 1,
                        cwd: "/b".into(),
                        cmd: Some("btop".into()),
                        scrollback_path: None,
                    },
                ],
                active_pane_idx: None,
            }],
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        // Pane 1 (Some): gets scrollback replay.
        assert!(
            out.contains("cat /tmp/sb/pane-1/scrollback.ansi 2>/dev/null"),
            "pane with scrollback_path: Some must get cat:\n{out}"
        );
        // Only one /bin/sh wrapper (for the pane that HAS scrollback).
        assert_eq!(
            out.matches("/bin/sh").count(),
            1,
            "only the scrollback pane should be wrapped in /bin/sh -c:\n{out}"
        );
        // Pane 2 (None): appears as a bare command, NOT wrapped.
        assert!(out.contains("btop"), "pane 2 command must appear:\n{out}");
        // Pane 2 must NOT have any scrollback-related content.
        // Split the output at the first split-window to isolate pane 2's line.
        let split_pos = out.find("split-window").expect("split-window must exist");
        let pane2_section = &out[split_pos..];
        assert!(
            !pane2_section.contains("scrollback"),
            "pane 2 (None) must not reference scrollback:\n{pane2_section}"
        );
    }

    #[test]
    fn render_scrollback_path_with_spaces_is_quoted() {
        // Paths with spaces must be properly quoted in the generated script.
        let rs = RestoreScript {
            session: "s".to_string(),
            windows: vec![RestoreWindow {
                idx: 0,
                name: "w".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![RestorePane {
                    uid: "1".into(),
                    idx: 0,
                    cwd: "/a".into(),
                    cmd: None,
                    scrollback_path: Some(PathBuf::from("/tmp/my state/pane 1/scrollback.ansi")),
                }],
                active_pane_idx: None,
            }],
            active_pane: None,
        };
        let out = render_restore_sh(&rs);
        // bash_quote wraps paths with spaces in single quotes.
        assert!(
            out.contains("'/tmp/my state/pane 1/scrollback.ansi'"),
            "scrollback path with spaces must be quoted:\n{out}"
        );
    }

    // ---------- integration: real tmux (gated on availability) ----------
    //
    // These tests need a real tmux on PATH and an isolated `-L socketName`
    // so we never touch the user's live tmux server. Killed on drop. The
    // fixture is `pub(crate)` so other lib test modules (`tmux_session`)
    // reuse it instead of growing their own copy.

    fn unique_socket() -> String {
        // Per-test atomic counter so cargo's parallel runner can't collide
        // on socket names when tests fire in the same nanosecond.
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        format!(
            "ksession-test-{}-{}-{n}",
            std::process::id(),
            uuid::Uuid::new_v4()
        )
    }

    pub(crate) struct IsolatedTmux {
        socket: String,
    }

    impl IsolatedTmux {
        pub(crate) async fn new() -> Self {
            let socket = unique_socket();
            let status = tokio::process::Command::new("tmux")
                // `-f /dev/null`: the user's tmux.conf may set base-index 1,
                // which would break every `demo:0` reference below.
                .args([
                    "-L",
                    &socket,
                    "-f",
                    "/dev/null",
                    "new-session",
                    "-d",
                    "-s",
                    "demo",
                ])
                .status()
                .await
                .expect("tmux new-session");
            assert!(status.success(), "tmux new-session failed");
            Self { socket }
        }

        pub(crate) async fn raw(&self, args: &[&str]) -> std::process::Output {
            let mut full = vec!["-L", self.socket.as_str()];
            full.extend_from_slice(args);
            tokio::process::Command::new("tmux")
                .args(&full)
                .output()
                .await
                .expect("tmux subprocess")
        }

        /// Absolute socket path tmux resolved for the `-L` label — what a
        /// `$TMUX`-derived target carries.
        pub(crate) async fn socket_path(&self) -> PathBuf {
            let out = self.raw(&["display-message", "-p", "#{socket_path}"]).await;
            assert!(out.status.success(), "display-message socket_path failed");
            PathBuf::from(String::from_utf8_lossy(&out.stdout).trim())
        }

        /// Numeric `$<N>` id of the bootstrap `demo` session.
        pub(crate) async fn demo_session_id(&self) -> u32 {
            let out = self
                .raw(&["display-message", "-p", "-t", "demo", "#{session_id}"])
                .await;
            assert!(out.status.success(), "display-message session_id failed");
            String::from_utf8_lossy(&out.stdout)
                .trim()
                .trim_start_matches('$')
                .parse()
                .expect("parse session id")
        }

        fn io(&self) -> IsolatedIo {
            IsolatedIo {
                socket: self.socket.clone(),
            }
        }
    }

    impl Drop for IsolatedTmux {
        fn drop(&mut self) {
            let _ = std::process::Command::new("tmux")
                .args(["-L", &self.socket, "kill-server"])
                .status();
        }
    }

    struct IsolatedIo {
        socket: String,
    }

    #[async_trait::async_trait]
    impl TmuxIo for IsolatedIo {
        async fn run(&self, args: &[&str]) -> Result<String, TmuxError> {
            let mut full = vec!["-L", self.socket.as_str()];
            full.extend_from_slice(args);
            let out = tokio::process::Command::new("tmux")
                .args(&full)
                .output()
                .await
                .map_err(TmuxError::Io)?;
            if !out.status.success() {
                return Err(TmuxError::Subprocess {
                    subcommand: args.first().map(|s| (*s).into()).unwrap_or_default(),
                    status: out.status.code().unwrap_or(-1),
                    stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
                });
            }
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        }

        async fn capture_pane_to_file(
            &self,
            pane_id: &str,
            dest: &Path,
            ansi: bool,
        ) -> Result<u64, TmuxError> {
            let mut args = vec![
                "-L".to_string(),
                self.socket.clone(),
                "capture-pane".into(),
                "-p".into(),
                "-C".into(),
            ];
            if ansi {
                args.push("-e".into());
            }
            args.extend(["-S".into(), "-".into(), "-t".into(), pane_id.to_string()]);
            let out = tokio::process::Command::new("tmux")
                .args(&args)
                .output()
                .await
                .map_err(TmuxError::Io)?;
            if !out.status.success() {
                return Err(TmuxError::Subprocess {
                    subcommand: "capture-pane".into(),
                    status: out.status.code().unwrap_or(-1),
                    stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
                });
            }
            let decoded = decode_capture_c(&out.stdout);
            if let Some(p) = dest.parent() {
                tokio::fs::create_dir_all(p).await.ok();
            }
            tokio::fs::write(dest, &decoded).await?;
            Ok(decoded.len() as u64)
        }
    }

    pub(crate) fn tmux_available() -> bool {
        TmuxCli::is_installed()
    }

    #[tokio::test]
    async fn integration_list_windows_one_window() {
        if !tmux_available() {
            eprintln!("skip: tmux not on PATH");
            return;
        }
        let tx = IsolatedTmux::new().await;
        let io = tx.io();
        let wins = list_windows(&io, "demo").await.unwrap();
        assert_eq!(wins.len(), 1);
        assert_eq!(wins[0].idx, 0);
        assert!(wins[0].active);
    }

    #[tokio::test]
    async fn integration_list_windows_after_new_window() {
        if !tmux_available() {
            eprintln!("skip: tmux not on PATH");
            return;
        }
        let tx = IsolatedTmux::new().await;
        let out = tx.raw(&["new-window", "-t", "demo", "-n", "second"]).await;
        assert!(out.status.success(), "new-window failed: {out:?}");
        let io = tx.io();
        let wins = list_windows(&io, "demo").await.unwrap();
        assert_eq!(wins.len(), 2);
        assert_eq!(wins[0].idx, 0);
        assert_eq!(wins[1].idx, 1);
        assert_eq!(wins[1].name, "second");
    }

    #[tokio::test]
    async fn integration_list_panes_after_split() {
        if !tmux_available() {
            eprintln!("skip: tmux not on PATH");
            return;
        }
        let tx = IsolatedTmux::new().await;
        let out = tx.raw(&["split-window", "-t", "demo:0"]).await;
        assert!(out.status.success(), "split-window failed");
        let io = tx.io();
        let panes = list_panes(&io, "demo", 0).await.unwrap();
        assert_eq!(panes.len(), 2);
        assert_eq!(panes[0].idx, 0);
        assert_eq!(panes[1].idx, 1);
        assert!(panes[0].pid > 0);
        assert!(panes[1].pid > 0);
        assert!(panes[0].id.starts_with('%'));
        assert!(panes[1].id.starts_with('%'));
    }

    #[tokio::test]
    async fn integration_find_session_for_client_returns_no_client_when_unattached() {
        // We never attach a real client in tests (would block); list-clients
        // therefore returns empty and the lookup is NoClient.
        if !tmux_available() {
            eprintln!("skip: tmux not on PATH");
            return;
        }
        let tx = IsolatedTmux::new().await;
        let io = tx.io();
        let err = find_session_for_client_pid(&io, 1).await.unwrap_err();
        assert!(matches!(err, TmuxError::NoClient(1)), "got: {err:?}");
    }

    // ---------- parse_tmux_env ----------

    #[test]
    fn parse_tmux_env_typical() {
        let info = parse_tmux_env("/tmp/tmux-1000/default,12345,0").unwrap();
        assert_eq!(info.socket_path, PathBuf::from("/tmp/tmux-1000/default"));
        assert_eq!(info.server_pid, 12345);
        assert_eq!(info.session_id, Some(0));
    }

    #[test]
    fn parse_tmux_env_custom_socket() {
        let info = parse_tmux_env("/run/user/1000/tmux-1000/work,9999,3").unwrap();
        assert_eq!(
            info.socket_path,
            PathBuf::from("/run/user/1000/tmux-1000/work")
        );
        assert_eq!(info.server_pid, 9999);
        assert_eq!(info.session_id, Some(3));
    }

    #[test]
    fn parse_tmux_env_empty_is_none() {
        assert!(parse_tmux_env("").is_none());
        assert!(parse_tmux_env("  ").is_none());
    }

    #[test]
    fn parse_tmux_env_missing_fields_is_none() {
        // Only one comma -> can't split into 3 fields.
        assert!(parse_tmux_env("/tmp/tmux-1000/default,12345").is_none());
        // No commas at all.
        assert!(parse_tmux_env("/tmp/tmux-1000/default").is_none());
    }

    #[test]
    fn parse_tmux_env_non_numeric_pid_is_none() {
        assert!(parse_tmux_env("/tmp/tmux-1000/default,abc,0").is_none());
    }

    #[test]
    fn parse_tmux_env_tolerates_jobs_without_session() {
        // `status-right #()` jobs and hooks run with session id -1: the
        // server is still addressable, only the session is unknown.
        let info = parse_tmux_env("/tmp/tmux-1000/default,12345,-1\n").unwrap();
        assert_eq!(info.socket_path, PathBuf::from("/tmp/tmux-1000/default"));
        assert_eq!(info.server_pid, 12345);
        assert_eq!(info.session_id, None);
        assert_eq!(
            parse_tmux_env("/tmp/tmux-1000/default,12345,xyz")
                .unwrap()
                .session_id,
            None
        );
    }

    #[test]
    fn parse_tmux_env_empty_socket_is_none() {
        assert!(parse_tmux_env(",12345,0").is_none());
    }
}
