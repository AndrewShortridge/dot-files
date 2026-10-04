//! Helper module for detecting availability of external binaries.
//!
//! Provides functions to check if required binaries (kitty, kitten, Xvfb) are
//! available on the system. Used to skip tests gracefully when binaries
//! are not available rather than failing.

pub mod tmux;

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use tempfile::tempdir;

use ksession_rs::error::KError;

/// Result of availability check for a binary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinaryAvailability {
    /// Binary is available and usable
    Available,
    /// Binary is not found on PATH
    MissingBinary,
    /// Binary exists but cannot execute (e.g., no display for kitty)
    NotUsable,
}

/// Check if kitty is usable (installed and can execute).
///
/// Returns `true` if `kitty --version` executes successfully.
/// This indicates the kitty binary is installed and can run.
pub fn kitty_is_usable() -> bool {
    matches!(check_kitty_availability(), BinaryAvailability::Available)
}

/// Get detailed availability status for kitty.
pub fn check_kitty_availability() -> BinaryAvailability {
    match Command::new("kitty").arg("--version").output() {
        Ok(out) if out.status.success() => BinaryAvailability::Available,
        Ok(_) => BinaryAvailability::NotUsable,
        Err(_) => BinaryAvailability::MissingBinary,
    }
}

/// Check if kitten (the RC client) is usable (installed and can execute).
///
/// Returns `true` if `kitten --version` executes successfully.
/// This indicates the kitten binary is installed and can run.
pub fn kitten_is_usable() -> bool {
    matches!(check_kitten_availability(), BinaryAvailability::Available)
}

/// Get detailed availability status for kitten.
pub fn check_kitten_availability() -> BinaryAvailability {
    match Command::new("kitten").arg("--version").output() {
        Ok(out) if out.status.success() => BinaryAvailability::Available,
        Ok(_) => BinaryAvailability::NotUsable,
        Err(_) => BinaryAvailability::MissingBinary,
    }
}

/// Check if Xvfb (X virtual framebuffer) is available.
///
/// Returns `true` if `Xvfb --help` or `Xvfb -version` executes successfully.
/// This is useful for headless testing scenarios.
pub fn xvfb_is_usable() -> bool {
    matches!(check_xvfb_availability(), BinaryAvailability::Available)
}

/// Get detailed availability status for Xvfb.
pub fn check_xvfb_availability() -> BinaryAvailability {
    // Try --help first (most common)
    match Command::new("Xvfb").arg("--help").output() {
        Ok(out) if out.status.success() => return BinaryAvailability::Available,
        _ => {}
    }
    // Fall back to -version
    match Command::new("Xvfb").arg("-version").output() {
        Ok(out) if out.status.success() => BinaryAvailability::Available,
        Ok(_) => BinaryAvailability::NotUsable,
        Err(_) => BinaryAvailability::MissingBinary,
    }
}

/// Check if tmux is usable (installed and can execute).
///
/// Returns `true` if `tmux -V` executes successfully.
pub fn tmux_is_usable() -> bool {
    Command::new("tmux")
        .arg("-V")
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

/// Check if both kitty and kitten are available for testing.
///
/// Convenience function that checks both binaries and returns true only if both are usable.
pub fn kitty_and_kitten_usable() -> bool {
    kitty_is_usable() && kitten_is_usable()
}

/// Skip message for when kitty is not available.
///
/// Returns a message suitable for use with `eprintln!("skip: {}")` or similar.
pub fn skip_msg_kitty() -> &'static str {
    match check_kitty_availability() {
        BinaryAvailability::Available => "kitty is available",
        BinaryAvailability::MissingBinary => "kitty not found on PATH",
        BinaryAvailability::NotUsable => "kitty found but not usable (no display?)",
    }
}

/// Skip message for when kitten is not available.
///
/// Returns a message suitable for use with `eprintln!("skip: {}")` or similar.
pub fn skip_msg_kitten() -> &'static str {
    match check_kitten_availability() {
        BinaryAvailability::Available => "kitten is available",
        BinaryAvailability::MissingBinary => "kitten not found on PATH",
        BinaryAvailability::NotUsable => "kitten found but not usable",
    }
}

/// Skip message for when Xvfb is not available.
///
/// Returns a message suitable for use with `eprintln!("skip: {}")` or similar.
pub fn skip_msg_xvfb() -> &'static str {
    match check_xvfb_availability() {
        BinaryAvailability::Available => "Xvfb is available",
        BinaryAvailability::MissingBinary => "Xvfb not found on PATH",
        BinaryAvailability::NotUsable => "Xvfb found but not usable",
    }
}

/// Macro to skip test if kitty is not available.
///
/// Usage:
/// ```rust
/// #[test]
/// fn my_test() {
///     skip_if_kitty_unusable!();
///     // test code...
/// }
/// ```
#[macro_export]
macro_rules! skip_if_kitty_unusable {
    () => {
        if !::tests::helpers::kitty_spawner::kitty_is_usable() {
            eprintln!(
                "kitty_spawner: `kitty --version` failed — skipping. \
                 (No kitty binary on PATH, or no usable display environment.)"
            );
            return;
        }
    };
}

/// Macro to skip test if kitten is not available.
#[macro_export]
macro_rules! skip_if_kitten_unusable {
    () => {
        if !::tests::helpers::kitty_spawner::kitten_is_usable() {
            eprintln!(
                "kitty_spawner: `kitten --version` failed — skipping. \
                 (RC client not available; can't drive shutdown.)"
            );
            return;
        }
    };
}

/// Macro to skip test if Xvfb is not available.
#[macro_export]
macro_rules! skip_if_xvfb_unusable {
    () => {
        if !::tests::helpers::kitty_spawner::xvfb_is_usable() {
            eprintln!(
                "kitty_spawner: `Xvfb --help` failed — skipping. \
                 (No Xvfb on PATH.)"
            );
            return;
        }
    };
}

/// Block (with a busy-wait sleep loop) until `sock` exists or the
/// deadline passes. Returns `true` on success.
fn wait_for_socket(sock: &Path, deadline: Instant) -> bool {
    while Instant::now() < deadline {
        if sock.exists() {
            return true;
        }
        thread::sleep(Duration::from_millis(50));
    }
    false
}

/// Poll the child for exit, up to `timeout`. Returns the
/// `ExitStatus` on clean exit or `None` if we time out.
fn wait_with_timeout(
    child: &mut std::process::Child,
    timeout: Duration,
) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            Ok(None) => {
                if Instant::now() >= deadline {
                    return None;
                }
                thread::sleep(Duration::from_millis(100));
            }
            Err(_) => return None,
        }
    }
}

/// Default timeout for waiting for kitty RC socket to appear.
const DEFAULT_SOCKET_TIMEOUT: Duration = Duration::from_secs(10);

/// Default timeout for waiting for process to exit on drop.
const DEFAULT_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);

/// Default polling interval for socket check.
const SOCKET_POLL_INTERVAL: Duration = Duration::from_millis(50);

/// Tab ID type used by kitty's RC protocol.
pub type TabId = u32;

/// Window ID type used by kitty's RC protocol.
pub type WindowId = u32;

/// A spawned Kitty process with its associated resources.
///
/// This struct holds the child process handle, socket path,
/// temp directory for cleanup, and instance group identifier.
pub struct KittySpawner {
    /// The spawned child process.
    pub child: Child,
    /// Path to the RC socket.
    pub socket_path: PathBuf,
    /// Path to the temporary directory (contains socket and logs).
    pub temp_dir: PathBuf,
    /// Instance group identifier used when spawning.
    pub instance_group: String,
    /// Tmux session names created by this spawner, cleaned up on Drop.
    pub tmux_sessions: Vec<String>,
}

impl KittySpawner {
    /// Spawn a new Kitty instance with remote control enabled.
    ///
    /// This function:
    /// 1. Checks if kitty and kitten are available
    /// 2. Creates a temp directory for the socket
    /// 3. Spawns kitty with `--config NONE --start-as=hidden --listen-on`
    /// 4. Waits for the RC socket to appear
    ///
    /// # Arguments
    /// * `timeout` - Maximum time to wait for socket (default 10 seconds)
    /// * `session_file` - Optional path to a session file to load
    ///
    /// # Returns
    /// * `Ok(KittySpawner)` on success with the spawned process handle
    /// * `Err(KError)` if kitty/kitten unavailable or spawn fails
    pub fn spawn(timeout: Duration, session_file: Option<&Path>) -> Result<KittySpawner, KError> {
        // First check availability
        if !kitty_is_usable() {
            return Err(KError::KittyRemote("kitty not usable".into()));
        }
        if !kitten_is_usable() {
            return Err(KError::KittyRemote("kitten not usable".into()));
        }

        // Create temp directory for socket and logs
        let tmp = tempdir().map_err(|e| KError::Io(e))?;
        let sock = tmp.path().join("kitty-rc.sock");
        let stderr_log = tmp.path().join("kitty-stderr.log");
        let stdout_log = tmp.path().join("kitty-stdout.log");
        let instance_group = format!("ksession-bench-{}", std::process::id());

        // Build the kitty command
        let mut cmd = Command::new("kitty");
        cmd.arg("--config").arg("NONE");
        cmd.arg("--start-as=hidden");
        cmd.arg("--listen-on")
            .arg(format!("unix:{}", sock.display()));
        cmd.arg("-o").arg("allow_remote_control=yes");
        cmd.arg("--instance-group").arg(&instance_group);

        // Add session file if provided
        if let Some(session) = session_file {
            cmd.arg("--session").arg(session);
        }

        cmd.stdin(Stdio::null());

        // Set up log files
        let stderr_file = std::fs::File::create(&stderr_log).map_err(|e| KError::Io(e))?;
        let stdout_file = std::fs::File::create(&stdout_log).map_err(|e| KError::Io(e))?;
        cmd.stdout(Stdio::from(stdout_file));
        cmd.stderr(Stdio::from(stderr_file));

        // Spawn the process
        let mut child = cmd.spawn().map_err(|e| KError::Io(e))?;

        // Helper to make sure we never leak the child if an assert fires.
        struct Guard<'a>(&'a mut std::process::Child);
        impl<'a> Drop for Guard<'a> {
            fn drop(&mut self) {
                // Best-effort kill; ignore errors (likely already exited).
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }

        // Wait for socket to appear
        let deadline = Instant::now() + timeout;
        let socket_ready = wait_for_socket(&sock, deadline);

        if !socket_ready {
            // Kitty failed to start — most often "no display" on a CI runner.
            // Read whatever it managed to write to stderr so the failure is actionable.
            let _ = Guard(&mut child); // drop kills it
            let stderr = std::fs::read_to_string(&stderr_log).unwrap_or_default();
            // Distinguish "no display" (skip) from "kitty bug" (fail).
            let stderr_lower = stderr.to_lowercase();
            let looks_like_no_display = stderr_lower.contains("display")
                || stderr_lower.contains("wayland")
                || stderr_lower.contains("x11")
                || stderr_lower.contains("opengl")
                || stderr.trim().is_empty();
            if looks_like_no_display {
                return Err(KError::KittyRemote(format!(
                    "kitty failed to start - looks like display issue: {}",
                    stderr
                )));
            }
            return Err(KError::KittyRemote(format!(
                "kitty did not create RC socket within {:?}",
                timeout
            )));
        }

        // Give the loader a beat past the socket-bind point so any
        // post-bind session parse errors get flushed to stderr
        thread::sleep(Duration::from_millis(50));

        // Check for fatal parse errors in stderr - be lenient with warnings
        let stderr = std::fs::read_to_string(&stderr_log).unwrap_or_default();
        let stderr_lower = stderr.to_lowercase();
        // Only fail on actual fatal errors, not warnings that mention 'error'
        let fatal_error_markers = ["panic", "failed to initialize", "fatal"];
        let has_fatal_error = fatal_error_markers.iter().any(|m| stderr_lower.contains(m));

        if has_fatal_error {
            // Try graceful shutdown first
            let socket_spec = format!("unix:{}", sock.display());
            let _ = Command::new("kitten")
                .args(["@", "--to", &socket_spec, "close-window", "--match", "all"])
                .output();
            let _ = wait_with_timeout(&mut child, Duration::from_secs(2));
            let _ = Guard(&mut child);
            return Err(KError::KittyRemote(format!(
                "kitty startup had fatal errors in stderr: {}",
                stderr
            )));
        }

        Ok(KittySpawner {
            child,
            socket_path: sock,
            #[allow(deprecated)]
            temp_dir: tmp.into_path(),
            instance_group,
            tmux_sessions: Vec::new(),
        })
    }

    /// Spawn a new Kitty instance with default timeout (10 seconds).
    ///
    /// # Arguments
    /// * `session_file` - Optional path to a session file to load
    pub fn spawn_default(session_file: Option<&Path>) -> Result<KittySpawner, KError> {
        Self::spawn(DEFAULT_SOCKET_TIMEOUT, session_file)
    }

    /// Wait for the child process to exit.
    ///
    /// # Arguments
    /// * `timeout` - Maximum time to wait for exit
    ///
    /// # Returns
    /// * `Some(ExitStatus)` if the process exits within timeout
    /// * `None` if timeout expires
    pub fn wait_with_timeout(&mut self, timeout: Duration) -> Option<std::process::ExitStatus> {
        let deadline = Instant::now() + timeout;
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) => return Some(status),
                Ok(None) => {
                    if Instant::now() >= deadline {
                        return None;
                    }
                    thread::sleep(Duration::from_millis(100));
                }
                Err(_) => return None,
            }
        }
    }

    /// Get the socket spec string for connecting to this kitty instance.
    ///
    /// This can be used with the KittyRpc client or kitten CLI.
    pub fn socket_spec(&self) -> String {
        format!("unix:{}", self.socket_path.display())
    }

    /// Create a new tab in the kitty instance.
    ///
    /// # Arguments
    /// * `title` - Optional title for the new tab
    ///
    /// # Returns
    /// * `Ok(TabId)` with the ID of the created tab
    /// * `Err(KError)` if the command fails
    pub fn create_tab(&self, title: Option<&str>) -> Result<TabId, KError> {
        let socket_spec = self.socket_spec();

        let mut args = vec!["@", "--to", &socket_spec, "launch", "--type", "tab"];
        if let Some(t) = title {
            args.push("--title");
            args.push(t);
        }

        let output = Command::new("kitten")
            .args(&args)
            .output()
            .map_err(|e| KError::KittyRemote(format!("failed to spawn kitten: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KError::KittyRemote(format!(
                "launch --type tab failed: {}",
                stderr
            )));
        }

        // Parse the output to get the window ID
        // The output format is "Launched window: id=X"
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if let Some(id_str) = line.strip_prefix("Launched window: id=") {
                return id_str
                    .parse()
                    .map_err(|e| KError::KittyRemote(format!("failed to parse window id: {}", e)));
            }
        }

        // If we can't parse, return a default (usually 1 for first window in new tab)
        Ok(1)
    }

    /// Create a new window in the specified tab.
    ///
    /// # Arguments
    /// * `tab` - The tab ID to create the window in
    /// * `layout` - The layout type (e.g., "horizontal", "vertical", "split", "fat")
    ///          Note: layout is ignored in newer kitten versions, kept for API compatibility.
    ///
    /// # Returns
    /// * `Ok(WindowId)` with the ID of the created window
    /// * `Err(KError)` if the command fails
    #[allow(unused_variables)]
    pub fn create_window(&self, tab: TabId, layout: &str) -> Result<WindowId, KError> {
        let socket_spec = self.socket_spec();
        let tab_str = tab.to_string();

        // Note: newer kitten versions don't support --layout, so we just ignore it
        let output = Command::new("kitten")
            .args([
                "@",
                "--to",
                &socket_spec,
                "launch",
                "--match",
                &format!("id:{}", tab_str),
            ])
            .output()
            .map_err(|e| KError::KittyRemote(format!("failed to spawn kitten: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KError::KittyRemote(format!("launch failed: {}", stderr)));
        }

        // Parse the output to get the window ID
        // The output format is "Launched window: id=Y"
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if let Some(id_str) = line.strip_prefix("Launched window: id=") {
                return id_str
                    .parse()
                    .map_err(|e| KError::KittyRemote(format!("failed to parse window id: {}", e)));
            }
        }

        // If we can't parse, return a default (usually 1 for first window)
        Ok(1)
    }

    // ---- tmux session management ----

    /// Create a new detached tmux session.
    ///
    /// Runs `tmux new-session -d -s <name>` via `std::process::Command`
    /// (NOT through kitty RC). The session name is tracked for cleanup
    /// in [`Drop`].
    ///
    /// # Arguments
    /// * `session_name` - Name for the new tmux session
    pub fn create_tmux_session(&mut self, session_name: &str) -> Result<(), KError> {
        let output = Command::new("tmux")
            .args(["new-session", "-d", "-s", session_name])
            .output()
            .map_err(|e| KError::KittyRemote(format!("failed to spawn tmux: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KError::KittyRemote(format!(
                "tmux new-session -d -s {} failed: {}",
                session_name, stderr
            )));
        }

        self.tmux_sessions.push(session_name.to_string());
        Ok(())
    }

    /// Create a new window in an existing tmux session.
    ///
    /// Runs `tmux new-window -t <session> -n <name>`.
    ///
    /// # Arguments
    /// * `session_name` - The tmux session to add the window to
    /// * `window_name` - Name for the new window
    pub fn create_tmux_window(&self, session_name: &str, window_name: &str) -> Result<(), KError> {
        let output = Command::new("tmux")
            .args(["new-window", "-t", session_name, "-n", window_name])
            .output()
            .map_err(|e| KError::KittyRemote(format!("failed to spawn tmux: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KError::KittyRemote(format!(
                "tmux new-window -t {} -n {} failed: {}",
                session_name, window_name, stderr
            )));
        }

        Ok(())
    }

    /// Create a split pane in a tmux window.
    ///
    /// Runs `tmux split-window -t <session>:<window>` with `-v` (vertical)
    /// or `-h` (horizontal).
    ///
    /// # Arguments
    /// * `session_name` - The tmux session containing the target window
    /// * `window_index` - Index of the window to split
    /// * `vertical` - If true, split vertically (`-v`); if false, horizontally (`-h`)
    pub fn create_tmux_pane(
        &self,
        session_name: &str,
        window_index: u32,
        vertical: bool,
    ) -> Result<(), KError> {
        let target = format!("{}:{}", session_name, window_index);
        let split_flag = if vertical { "-v" } else { "-h" };

        let output = Command::new("tmux")
            .args(["split-window", split_flag, "-t", &target])
            .output()
            .map_err(|e| KError::KittyRemote(format!("failed to spawn tmux: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KError::KittyRemote(format!(
                "tmux split-window {} -t {} failed: {}",
                split_flag, target, stderr
            )));
        }

        Ok(())
    }

    /// Attach a tmux session inside a kitty window by sending keystrokes.
    ///
    /// Uses `kitten @ send-text` to type `tmux attach -t <session>\r` into
    /// the kitty window identified by `tab_id`.
    ///
    /// # Arguments
    /// * `tab_id` - The kitty tab ID whose active window receives the text
    /// * `session_name` - The tmux session name to attach
    pub fn attach_tmux_in_kitty_window(
        &self,
        tab_id: TabId,
        session_name: &str,
    ) -> Result<(), KError> {
        let socket_spec = self.socket_spec();
        let text = format!("tmux attach -t {}\r", session_name);
        let tab_match = format!("id:{}", tab_id);

        let output = Command::new("kitten")
            .args([
                "@",
                "--to",
                &socket_spec,
                "send-text",
                "--match",
                &tab_match,
                &text,
            ])
            .output()
            .map_err(|e| KError::KittyRemote(format!("failed to spawn kitten: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KError::KittyRemote(format!(
                "kitten @ send-text failed: {}",
                stderr
            )));
        }

        Ok(())
    }

    /// Kill all tracked tmux sessions.
    ///
    /// Runs `tmux kill-session -t <name>` for each session created by
    /// [`create_tmux_session`]. Errors are logged to stderr but do not
    /// propagate (best-effort cleanup).
    pub fn cleanup_tmux_sessions(&mut self) {
        for name in self.tmux_sessions.drain(..) {
            let result = Command::new("tmux")
                .args(["kill-session", "-t", &name])
                .output();
            if let Err(e) = result {
                eprintln!("kitty_spawner: failed to kill tmux session {}: {}", name, e);
            }
        }
    }

    /// Create a new window with a shell in the specified tab.
    ///
    /// This is a convenience method that creates a window running a shell.
    ///
    /// # Arguments
    /// * `tab` - The tab ID to create the window in
    /// * `directory` - Optional working directory for the shell
    ///
    /// # Returns
    /// * `Ok(WindowId)` with the ID of the created window
    /// * `Err(KError)` if the command fails
    pub fn create_shell_window(
        &self,
        tab: TabId,
        directory: Option<&Path>,
    ) -> Result<WindowId, KError> {
        let socket_spec = self.socket_spec();
        let tab_str = tab.to_string();
        let match_expr = format!("id:{}", tab_str);

        let mut args = vec!["@", "--to", &socket_spec, "launch", "--match", &match_expr];

        if let Some(dir) = directory {
            args.push("--directory");
            args.push(dir.to_str().unwrap_or("."));
        }

        let output = Command::new("kitten")
            .args(&args)
            .output()
            .map_err(|e| KError::KittyRemote(format!("failed to spawn kitten: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KError::KittyRemote(format!(
                "launch shell failed: {}",
                stderr
            )));
        }

        // Parse the output to get the window ID
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if let Some(id_str) = line.strip_prefix("Launched window: id=") {
                return id_str
                    .parse()
                    .map_err(|e| KError::KittyRemote(format!("failed to parse window id: {}", e)));
            }
        }

        Ok(1)
    }

    // ── nvim launch helpers ────────────────────────────────────────────

    /// Send text to a specific kitty window via `kitten @ send-text`.
    ///
    /// # Arguments
    /// * `window_id` - The kitty window ID to target
    /// * `text` - The text to send (will be sent as-is)
    fn send_text(&self, window_id: WindowId, text: &str) -> Result<(), KError> {
        let socket_spec = self.socket_spec();
        let match_arg = format!("id:{}", window_id);

        let output = Command::new("kitten")
            .args([
                "@",
                "--to",
                &socket_spec,
                "send-text",
                "--match",
                &match_arg,
                text,
            ])
            .output()
            .map_err(|e| KError::KittyRemote(format!("failed to spawn kitten send-text: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KError::KittyRemote(format!("send-text failed: {}", stderr)));
        }

        Ok(())
    }

    /// Send an nvim ex-command to a kitty window running nvim.
    ///
    /// Sends `:<command>\r` (colon + command + Enter) and waits a brief
    /// period for nvim to process the command.
    ///
    /// # Arguments
    /// * `window_id` - The kitty window ID where nvim is running
    /// * `cmd` - The ex-command to execute (without leading colon)
    /// * `settle_ms` - Milliseconds to wait after sending the command
    fn send_nvim_cmd(&self, window_id: WindowId, cmd: &str, settle_ms: u64) -> Result<(), KError> {
        // Ensure we're in normal mode first by sending Escape
        self.send_text(window_id, "\x1b")?;
        thread::sleep(Duration::from_millis(50));

        // Send the ex-command
        let full_cmd = format!(":{}\r", cmd);
        self.send_text(window_id, &full_cmd)?;

        if settle_ms > 0 {
            thread::sleep(Duration::from_millis(settle_ms));
        }

        Ok(())
    }

    /// Launch nvim in a kitty window with specific files open.
    ///
    /// Creates a new window in the specified tab running `nvim` with
    /// the given files. Waits for nvim to start before returning.
    ///
    /// # Arguments
    /// * `tab_id` - The kitty tab to launch nvim in
    /// * `files` - Slice of file paths to open in nvim
    ///
    /// # Returns
    /// * `Ok(WindowId)` - The kitty window ID where nvim is running
    /// * `Err(KError)` if the launch fails
    pub fn launch_nvim(&self, tab_id: TabId, files: &[&str]) -> Result<WindowId, KError> {
        let socket_spec = self.socket_spec();
        let tab_str = tab_id.to_string();

        // Build the nvim command with all files
        let mut args = vec![
            "@",
            "--to",
            &socket_spec,
            "launch",
            "--type=window",
            "--tab-id",
            &tab_str,
            "nvim",
            "--headless",
            "--clean",
        ];
        for f in files {
            args.push(f);
        }

        let output = Command::new("kitten")
            .args(&args)
            .output()
            .map_err(|e| KError::KittyRemote(format!("failed to launch nvim: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KError::KittyRemote(format!(
                "launch nvim failed: {}",
                stderr
            )));
        }

        // Parse the window ID from output
        let stdout = String::from_utf8_lossy(&output.stdout);
        let window_id = Self::parse_window_id(&stdout);

        // Wait for nvim to start up
        thread::sleep(Duration::from_millis(800));

        Ok(window_id)
    }

    /// Launch nvim and create dirty (modified, unsaved) buffer state.
    ///
    /// Opens files in nvim then inserts text modifications into each
    /// buffer so they show as modified/unsaved.
    ///
    /// # Arguments
    /// * `tab_id` - The kitty tab to launch nvim in
    /// * `files` - Slice of file paths to open and modify
    ///
    /// # Returns
    /// * `Ok(WindowId)` - The kitty window ID where nvim is running
    /// * `Err(KError)` if the launch or modification fails
    pub fn launch_nvim_dirty(&self, tab_id: TabId, files: &[&str]) -> Result<WindowId, KError> {
        let window_id = self.launch_nvim(tab_id, files)?;

        // For each file, switch to its buffer and insert text to make it dirty
        for (i, file) in files.iter().enumerate() {
            // Edit the file (first file is already open)
            if i > 0 {
                self.send_nvim_cmd(window_id, &format!("edit {}", file), 200)?;
            }

            // Enter insert mode and type some text to dirty the buffer
            self.send_text(window_id, "i")?;
            thread::sleep(Duration::from_millis(50));
            self.send_text(window_id, &format!("-- dirty buffer {} --", i))?;
            thread::sleep(Duration::from_millis(50));

            // Return to normal mode
            self.send_text(window_id, "\x1b")?;
            thread::sleep(Duration::from_millis(100));
        }

        Ok(window_id)
    }

    /// Launch nvim with multiple nvim tab pages.
    ///
    /// Opens the first file normally, then creates additional nvim tabs
    /// (`:tabnew <file>`) for each remaining file.
    ///
    /// # Arguments
    /// * `tab_id` - The kitty tab to launch nvim in
    /// * `files` - Slice of file paths; first opens normally, rest get `:tabnew`
    ///
    /// # Returns
    /// * `Ok(WindowId)` - The kitty window ID where nvim is running
    /// * `Err(KError)` if the launch fails
    pub fn launch_nvim_multi_tab(&self, tab_id: TabId, files: &[&str]) -> Result<WindowId, KError> {
        // Launch nvim with just the first file (or no files)
        let first_file = files.first().copied().unwrap_or("");
        let initial_files = if first_file.is_empty() {
            &[] as &[&str]
        } else {
            &files[..1]
        };
        let window_id = self.launch_nvim(tab_id, initial_files)?;

        // Create nvim tabs for remaining files
        for file in files.iter().skip(1) {
            self.send_nvim_cmd(window_id, &format!("tabnew {}", file), 200)?;
        }

        Ok(window_id)
    }

    /// Launch nvim with split windows.
    ///
    /// Opens the first file normally, then creates alternating vertical
    /// and horizontal splits for each remaining file.
    ///
    /// # Arguments
    /// * `tab_id` - The kitty tab to launch nvim in
    /// * `files` - Slice of file paths; first opens normally, rest get `:vsplit`/`:split`
    ///
    /// # Returns
    /// * `Ok(WindowId)` - The kitty window ID where nvim is running
    /// * `Err(KError)` if the launch fails
    pub fn launch_nvim_splits(&self, tab_id: TabId, files: &[&str]) -> Result<WindowId, KError> {
        // Launch nvim with just the first file (or no files)
        let first_file = files.first().copied().unwrap_or("");
        let initial_files = if first_file.is_empty() {
            &[] as &[&str]
        } else {
            &files[..1]
        };
        let window_id = self.launch_nvim(tab_id, initial_files)?;

        // Create splits for remaining files, alternating vsplit and split
        for (i, file) in files.iter().skip(1).enumerate() {
            let split_cmd = if i % 2 == 0 { "vsplit" } else { "split" };
            self.send_nvim_cmd(window_id, &format!("{} {}", split_cmd, file), 200)?;
        }

        Ok(window_id)
    }

    /// Parse a window ID from kitten launch output.
    ///
    /// Looks for a line starting with a numeric ID or the format
    /// `Launched window: id=<N>`. Falls back to 1 if unparseable.
    fn parse_window_id(stdout: &str) -> WindowId {
        // Try "Launched window: id=N" format first
        for line in stdout.lines() {
            if let Some(id_str) = line.strip_prefix("Launched window: id=") {
                if let Ok(id) = id_str.trim().parse::<WindowId>() {
                    return id;
                }
            }
        }
        // Try bare numeric output (kitten @ launch often just returns the window ID)
        if let Ok(id) = stdout.trim().parse::<WindowId>() {
            return id;
        }
        // Fallback
        1
    }
}

impl Drop for KittySpawner {
    fn drop(&mut self) {
        // Clean up any tmux sessions we created before shutting down kitty.
        self.cleanup_tmux_sessions();

        // Ask kitty to close. `close-window --match all` is the gentlest
        // shutdown that doesn't require platform-specific signal handling.
        let socket_spec = format!("unix:{}", self.socket_path.display());
        let _close = Command::new("kitten")
            .arg("@")
            .arg("--to")
            .arg(&socket_spec)
            .arg("close-window")
            .arg("--match")
            .arg("all")
            .output();

        // If the close command itself fails we still want to clean up.
        let status = wait_with_timeout(&mut self.child, DEFAULT_SHUTDOWN_TIMEOUT);

        if status.is_none() {
            // Force-kill so we don't leak processes.
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        // Temp directory will be cleaned up automatically when dropped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_kitty_check_returns_bool() {
        // Just verify the function returns a bool without panicking
        let _ = kitty_is_usable();
    }

    #[test]
    fn test_kitten_check_returns_bool() {
        let _ = kitten_is_usable();
    }

    #[test]
    fn test_xvfb_check_returns_bool() {
        let _ = xvfb_is_usable();
    }

    #[test]
    fn test_availability_enum_values() {
        // Verify enum variants exist and are accessible
        let _ = BinaryAvailability::Available;
        let _ = BinaryAvailability::MissingBinary;
        let _ = BinaryAvailability::NotUsable;
    }

    #[test]
    fn test_kitty_and_kitten_usable() {
        // Just verify the function returns a bool without panicking
        let _ = kitty_and_kitten_usable();
    }

    #[test]
    fn test_skip_messages() {
        // Just verify the functions return strings without panicking
        let _ = skip_msg_kitty();
        let _ = skip_msg_kitten();
        let _ = skip_msg_xvfb();
    }
}
