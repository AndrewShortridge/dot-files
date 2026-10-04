//! Scratch tmux server harness shared by every tmux-facing integration
//! test: the control-mode protocol/safety suites, the layout-preservation
//! regression, the perf budget benchmark, and the `ksession tmux …` CLI
//! suites.
//!
//! Each test gets its own `tmux -L <unique>` server. The server is
//! bootstrapped with `-f /dev/null` and `SHELL=/bin/bash` so the user's
//! `~/.config/tmux/tmux.conf` (`base-index 1`, hooks, default-shell…)
//! cannot leak into assertions that address `demo:0`, and it is killed in
//! `Drop` so a failing test never touches the user's real tmux.
//!
//! Every test that spawns a server starts with the skip convention:
//!
//! ```ignore
//! if !tmux_available() {
//!     eprintln!("skip: tmux not on PATH");
//!     return;
//! }
//! ```
//!
//! This is a plain early-return rather than `#[ignore]` so `cargo test`
//! stays green on tmux-less hosts while still exercising tmux where it
//! exists.
//!
//! Every integration-test binary compiles this file but uses a subset of
//! it (the control-mode suites never touch the CLI driver and vice
//! versa), so unused-item warnings are suppressed module-wide. Keep the
//! surface to items at least one test binary calls.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Availability probes
// ---------------------------------------------------------------------------

/// `true` when `tmux -V` succeeds on PATH.
pub fn tmux_available() -> bool {
    Command::new("tmux")
        .arg("-V")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Process-unique `-L` socket label. The pid separates concurrently
/// running test binaries; the counter separates tests inside one binary.
fn unique_socket() -> String {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    format!("ksession-test-{}-{n}", std::process::id())
}

// ---------------------------------------------------------------------------
// Isolated server
// ---------------------------------------------------------------------------

/// Builder for [`IsolatedTmux`]: bootstrap session name plus the optional
/// `-x/-y` geometry and `-c` cwd of its first pane.
pub struct IsolatedTmuxBuilder {
    session: String,
    size: Option<(u32, u32)>,
    cwd: Option<PathBuf>,
}

impl IsolatedTmuxBuilder {
    /// Explicit `-x <w> -y <h>` so the detached bootstrap client has a
    /// non-default PTY size (the control-mode default is 80×24; a bigger
    /// window makes layout-reflow regressions visible).
    pub fn size(mut self, width: u32, height: u32) -> Self {
        self.size = Some((width, height));
        self
    }

    /// `-c <dir>` for the bootstrap pane, so its `#{pane_current_path}` is
    /// deterministic instead of inheriting the test process's cwd.
    pub fn cwd(mut self, dir: &Path) -> Self {
        self.cwd = Some(dir.to_path_buf());
        self
    }

    /// Start the server and resolve its identity (`socket_path`, server
    /// pid, bootstrap session id).
    pub fn spawn(self) -> IsolatedTmux {
        let socket_name = unique_socket();
        let mut boot = Command::new("tmux");
        boot.args([
            "-f",
            "/dev/null",
            "-L",
            &socket_name,
            "new-session",
            "-d",
            "-s",
            &self.session,
        ]);
        if let Some((w, h)) = self.size {
            boot.args(["-x", &w.to_string(), "-y", &h.to_string()]);
        }
        if let Some(dir) = &self.cwd {
            boot.arg("-c").arg(dir);
        }
        // The server inherits `$SHELL` from the client that starts it and
        // derives `default-shell` from it; pin bash so pane programs are
        // predictable regardless of the developer's login shell.
        boot.env("SHELL", "/bin/bash");
        let status = boot.status().expect("spawn tmux new-session");
        assert!(status.success(), "tmux -L {socket_name} new-session failed");

        let by_label = |args: &[&str]| -> String {
            let out = Command::new("tmux")
                .args(["-L", &socket_name])
                .args(args)
                .output()
                .expect("spawn tmux");
            assert!(
                out.status.success(),
                "tmux -L {socket_name} {args:?} failed: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        };
        let socket_path = PathBuf::from(by_label(&["display-message", "-p", "#{socket_path}"]));
        let server_pid: u32 = by_label(&["display-message", "-p", "#{pid}"])
            .parse()
            .expect("parse tmux server pid");

        let mut server = IsolatedTmux {
            socket_name,
            socket_path,
            server_pid,
            session: self.session,
            sid: 0,
        };
        let sid = server.session_id_of(&server.session);
        server.sid = sid;
        server
    }
}

/// A private tmux server with an auto-kill `Drop`.
///
/// `socket_path` is the absolute `<tmpdir>/tmux-<uid>/<label>` path tmux
/// resolved for the label — the same shape production code parses out of
/// `$TMUX`, so it can be handed straight to `TmuxControl::connect` or
/// embedded in [`IsolatedTmux::tmux_env`].
pub struct IsolatedTmux {
    /// `-L` label the server was started with.
    pub socket_name: String,
    /// Absolute socket path (e.g. `/tmp/tmux-1000/ksession-test-…`).
    pub socket_path: PathBuf,
    /// Pid of the tmux server process (`#{pid}`), the middle `$TMUX` field.
    pub server_pid: u32,
    /// Name of the bootstrap session.
    pub session: String,
    /// Numeric id of the bootstrap session (`$N` → `N`).
    pub sid: u32,
}

impl IsolatedTmux {
    /// One detached session named `demo`, default geometry.
    ///
    /// Deliberately no `Default` impl: constructing one spawns a server.
    #[allow(clippy::new_without_default)]
    pub fn new() -> Self {
        Self::builder("demo").spawn()
    }

    /// Start configuring a server whose bootstrap session is `session`.
    pub fn builder(session: &str) -> IsolatedTmuxBuilder {
        IsolatedTmuxBuilder {
            session: session.to_string(),
            size: None,
            cwd: None,
        }
    }

    /// `tmux -S <socket_path>` with no further arguments.
    fn cmd(&self) -> Command {
        let mut cmd = Command::new("tmux");
        cmd.arg("-S").arg(&self.socket_path);
        cmd.stdin(Stdio::null());
        cmd
    }

    /// Run a tmux command against this server and return trimmed stdout.
    /// Panics with tmux's stderr when the command fails — every caller is
    /// test setup or an assertion probe, where a failure is a test bug.
    pub fn run(&self, args: &[&str]) -> String {
        match self.try_run(args) {
            Ok(stdout) => stdout,
            Err(stderr) => panic!(
                "tmux -S {} {args:?} failed: {stderr}",
                self.socket_path.display()
            ),
        }
    }

    /// Like [`run`](Self::run) but surfaces failure as `Err(stderr)` for
    /// commands whose non-zero exit is the information (e.g. `has-session`).
    pub fn try_run(&self, args: &[&str]) -> Result<String, String> {
        let out = self.cmd().args(args).output().expect("spawn tmux");
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
        }
    }

    /// `display-message -p -t <target> <format>`.
    pub fn display(&self, target: &str, format: &str) -> String {
        self.run(&["display-message", "-p", "-t", target, format])
    }

    /// Numeric `#{session_id}` of a live session (`$N` → `N`).
    pub fn session_id_of(&self, session: &str) -> u32 {
        let raw = self.display(session, "#{session_id}");
        raw.trim_start_matches('$')
            .parse()
            .unwrap_or_else(|e| panic!("parse session id from {raw:?}: {e}"))
    }

    /// `true` when `has-session -t =<session>` succeeds (exact-name match).
    pub fn has_session(&self, session: &str) -> bool {
        self.try_run(&["has-session", "-t", &format!("={session}")])
            .is_ok()
    }

    /// `<socket_path>,<server_pid>,<sid>` — the `$TMUX` value a client
    /// attached to the bootstrap session would see. Export it on a
    /// subprocess to run it "as if inside" this server.
    pub fn tmux_env(&self) -> String {
        self.tmux_env_for_sid(self.sid)
    }

    /// [`tmux_env`](Self::tmux_env) for a different live session, e.g. an
    /// anchor session that keeps the server alive while the session under
    /// test is killed and rebuilt.
    pub fn tmux_env_for(&self, session: &str) -> String {
        self.tmux_env_for_sid(self.session_id_of(session))
    }

    fn tmux_env_for_sid(&self, sid: u32) -> String {
        format!("{},{},{sid}", self.socket_path.display(), self.server_pid)
    }

    /// Block until `capture-pane -p -t <target>` contains `needle` or
    /// `timeout` elapses (panics on timeout). Used after `send-keys` so a
    /// save observes the seeded scrollback instead of racing the shell.
    pub fn wait_for_pane_text(&self, target: &str, needle: &str, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        loop {
            let screen = self.run(&["capture-pane", "-p", "-t", target]);
            if screen.contains(needle) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {needle:?} in pane {target}; last screen:\n{screen}"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

impl Drop for IsolatedTmux {
    fn drop(&mut self) {
        let _ = self.cmd().arg("kill-server").status();
    }
}

// ---------------------------------------------------------------------------
// `ksession tmux …` binary driver
// ---------------------------------------------------------------------------

/// One configured way of invoking the built `ksession tmux …` binary:
/// a private sessions root and, optionally, a `$TMUX` value that makes the
/// binary believe it runs inside a scratch server.
///
/// The inherited environment is scrubbed of everything that could make
/// the binary behave differently on a developer box (`TMUX` from the
/// developer's own tmux, `KSESSION_SCROLLBACK`, kitty RC variables).
pub struct Ksession {
    root: PathBuf,
    tmux_env: Option<String>,
}

impl Ksession {
    /// Drive the binary with `KSESSION_TMUX_SESSIONS_DIR=<root>` and no
    /// `$TMUX` — i.e. "outside tmux" unless [`inside`](Self::inside) is
    /// chained.
    pub fn at(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
            tmux_env: None,
        }
    }

    /// Export `TMUX=<value>` (see [`IsolatedTmux::tmux_env`]).
    pub fn inside(mut self, tmux_env: String) -> Self {
        self.tmux_env = Some(tmux_env);
        self
    }

    /// Run `ksession tmux <args…>` to completion and return its output.
    pub fn run(&self, args: &[&str]) -> Output {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_ksession"));
        cmd.arg("tmux").args(args);
        cmd.env("KSESSION_TMUX_SESSIONS_DIR", &self.root);
        cmd.env_remove("TMUX");
        cmd.env_remove("KSESSION_SCROLLBACK");
        cmd.env_remove("KSESSION_TRACE_DIR");
        cmd.env_remove("KITTY_WINDOW_ID");
        cmd.env_remove("KITTY_LISTEN_ON");
        if let Some(env) = &self.tmux_env {
            cmd.env("TMUX", env);
        }
        cmd.stdin(Stdio::null());
        cmd.output().expect("spawn ksession")
    }
}

/// Lossy UTF-8 view of a process's stdout.
pub fn stdout_str(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// Lossy UTF-8 view of a process's stderr.
pub fn stderr_str(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

/// Assert a `save`-family command committed its result: exit 0, or exit 2
/// for "saved but degraded" (ADR 0001). Anything else fails with stderr.
pub fn assert_saved(out: &Output, what: &str) {
    assert!(
        matches!(out.status.code(), Some(0) | Some(2)),
        "{what}: expected exit 0/2, got {:?}\nstderr:\n{}",
        out.status.code(),
        stderr_str(out)
    );
}

/// Assert exit 0, failing with stderr otherwise.
pub fn assert_ok(out: &Output, what: &str) {
    assert!(
        out.status.success(),
        "{what}: expected exit 0, got {:?}\nstderr:\n{}",
        out.status.code(),
        stderr_str(out)
    );
}

/// Assert a fatal exit (code 1) whose stderr mentions `needle`.
pub fn assert_fatal(out: &Output, needle: &str, what: &str) {
    let stderr = stderr_str(out);
    assert_eq!(
        out.status.code(),
        Some(1),
        "{what}: expected exit 1\nstdout:\n{}\nstderr:\n{stderr}",
        stdout_str(out)
    );
    assert!(
        stderr.contains(needle),
        "{what}: stderr should mention {needle:?}, got:\n{stderr}"
    );
}

// ---------------------------------------------------------------------------
// Storage-layout inspection (`<root>/<name>.json` + `<root>/<name>.gen-*.state/`)
// ---------------------------------------------------------------------------

/// `<root>/<name>.json` — the head file whose presence defines a saved
/// tmux session.
pub fn head_path(root: &Path, name: &str) -> PathBuf {
    root.join(format!("{name}.json"))
}

/// Parse `<root>/<name>.json` as untyped JSON. Tests assert on the
/// serialised shape (the on-disk contract) rather than on lib types.
fn read_manifest(root: &Path, name: &str) -> serde_json::Value {
    let path = head_path(root, name);
    let bytes =
        std::fs::read(&path).unwrap_or_else(|e| panic!("read manifest {}: {e}", path.display()));
    serde_json::from_slice(&bytes)
        .unwrap_or_else(|e| panic!("parse manifest {}: {e}", path.display()))
}

/// Every `<root>/<name>.gen-*.state` directory, sorted by path.
pub fn state_dirs(root: &Path, name: &str) -> Vec<PathBuf> {
    let prefix = format!("{name}.gen-");
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(root)
        .expect("read sessions root")
        .filter_map(Result::ok)
        .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with(&prefix) && n.ends_with(".state"))
                .unwrap_or(false)
        })
        .collect();
    dirs.sort();
    dirs
}

/// Recursively collect every file named `file_name` under `dir`.
pub fn find_files_named(dir: &Path, file_name: &str) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for entry in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.file_name().and_then(|n| n.to_str()) == Some(file_name) {
                found.push(p);
            }
        }
    }
    found.sort();
    found
}

// ---------------------------------------------------------------------------
// Manifest field accessors (serde shape of `TmuxSessionManifest`)
// ---------------------------------------------------------------------------

/// Typed view over the manifest JSON fields the CLI tests assert on.
pub struct ManifestView(pub serde_json::Value);

impl ManifestView {
    pub fn load(root: &Path, name: &str) -> Self {
        Self(read_manifest(root, name))
    }

    fn field(&self, key: &str) -> &serde_json::Value {
        self.0
            .get(key)
            .unwrap_or_else(|| panic!("manifest missing field {key:?}: {}", self.0))
    }

    fn program_field(&self, key: &str) -> &serde_json::Value {
        self.field("program")
            .get(key)
            .unwrap_or_else(|| panic!("manifest.program missing field {key:?}: {}", self.0))
    }

    pub fn name(&self) -> &str {
        self.field("name")
            .as_str()
            .expect("manifest.name is a string")
    }

    pub fn schema(&self) -> u64 {
        self.field("schema")
            .as_u64()
            .expect("manifest.schema is an integer")
    }

    pub fn tmux_version(&self) -> &str {
        self.field("tmux_version")
            .as_str()
            .expect("manifest.tmux_version is a string")
    }

    pub fn created_at(&self) -> chrono::DateTime<chrono::Utc> {
        let raw = self
            .field("created_at")
            .as_str()
            .expect("manifest.created_at is a string");
        chrono::DateTime::parse_from_rfc3339(raw)
            .unwrap_or_else(|e| panic!("manifest.created_at {raw:?} is not RFC 3339: {e}"))
            .with_timezone(&chrono::Utc)
    }

    pub fn state_dir(&self) -> PathBuf {
        PathBuf::from(
            self.field("state_dir")
                .as_str()
                .expect("manifest.state_dir is a string"),
        )
    }

    /// `program.kind` — the serde tag of `Program`; `"tmux"` for every
    /// tmux-native manifest.
    pub fn program_kind(&self) -> &str {
        self.program_field("kind")
            .as_str()
            .expect("manifest.program.kind is a string")
    }

    pub fn session_name(&self) -> &str {
        self.program_field("session_name")
            .as_str()
            .expect("manifest.program.session_name is a string")
    }

    pub fn restore_sh(&self) -> PathBuf {
        PathBuf::from(
            self.program_field("restore_sh")
                .as_str()
                .expect("manifest.program.restore_sh is a string"),
        )
    }

    pub fn windows(&self) -> &[serde_json::Value] {
        self.program_field("windows")
            .as_array()
            .expect("manifest.program.windows is an array")
    }

    pub fn window_count(&self) -> usize {
        self.windows().len()
    }

    pub fn pane_count(&self) -> usize {
        self.windows().iter().map(|w| panes_of(w).len()).sum()
    }

    /// `layout` string of window `idx` (the tmux window index, not the
    /// position in the array).
    pub fn window_layout(&self, idx: u64) -> &str {
        self.windows()
            .iter()
            .find(|w| w.get("idx").and_then(|v| v.as_u64()) == Some(idx))
            .unwrap_or_else(|| panic!("no window with idx {idx} in {}", self.0))
            .get("layout")
            .and_then(|v| v.as_str())
            .expect("window.layout is a string")
    }

    /// Every pane's `cwd`, sorted. Panes without a cwd are skipped.
    pub fn pane_cwds(&self) -> Vec<String> {
        let mut cwds: Vec<String> = self
            .windows()
            .iter()
            .flat_map(|w| panes_of(w).iter())
            .filter_map(|p| p.get("cwd").and_then(|v| v.as_str()).map(str::to_string))
            .collect();
        cwds.sort();
        cwds
    }
}

fn panes_of(window: &serde_json::Value) -> &[serde_json::Value] {
    window
        .get("panes")
        .and_then(|v| v.as_array())
        .map(Vec::as_slice)
        .unwrap_or(&[])
}
