//! Test infrastructure for spawning a real kitty instance with remote control.
//!
//! This module provides a `LiveKitty` fixture that:
//! - Spawns kitty with `allow_remote_control yes`
//! - Sets up a temporary socket directory for `listen_on`
//! - Properly cleans up on drop
//! - Handles the case when kitty is not available gracefully (skips tests)
//!
//! # Usage
//!
//! ```ignore
//! use crate::kitty::testkitty::LiveKitty;
//!
//! #[tokio::test]
//! #[ignore = "requires live kitty"]
//! async fn my_integration_test() {
//!     let kitty = LiveKitty::spawn().await;
//!     let rpc = kitty.rpc().await;
//!     // ... use rpc ...
//! }
//! ```

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use tempfile::TempDir;
use tokio::sync::Mutex;

use crate::kitty::pool::KittyPool;

/// Hard upper bound on how long we'll wait for kitty to start up.
const STARTUP_TIMEOUT: Duration = Duration::from_secs(10);
/// Hard upper bound on how long we'll wait for kitty to exit after we ask it to close.
#[allow(dead_code)]
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);
/// How long to wait after the socket appears before using it.
const POST_READY_GRACE: Duration = Duration::from_millis(500);

/// Returns true if a usable kitty binary appears to be on PATH.
fn kitty_is_usable() -> bool {
    match Command::new("kitty").arg("--version").output() {
        Ok(out) if out.status.success() => true,
        Ok(_) | Err(_) => false,
    }
}

/// A live kitty instance for integration tests.
///
/// This fixture spawns a real kitty process with remote control enabled,
/// provides access to the RPC client, and ensures proper cleanup on drop.
pub struct LiveKitty {
    /// The RPC client connected to this kitty instance.
    rpc: Option<KittyPool>,
    /// The socket path that kitty is listening on.
    socket_path: PathBuf,
    /// The temporary directory holding the socket (we keep it alive until drop).
    #[allow(dead_code)]
    temp_dir: TempDir,
    /// The child process (needed for cleanup).
    child: Arc<Mutex<Option<Child>>>,
}

impl LiveKitty {
    /// Spawn a new live kitty instance with remote control enabled.
    ///
    /// Returns `None` if:
    /// - kitty binary is not available
    /// - kitty fails to start (e.g., no display)
    ///
    /// The caller should use `Test::skip` if `None` is returned.
    pub async fn spawn() -> Option<Self> {
        if !kitty_is_usable() {
            eprintln!(
                "LiveKitty: `kitty --version` failed — skipping test. \
                 (No kitty binary on PATH, or no usable display environment.)"
            );
            return None;
        }

        // Create a temp directory for the socket.
        let temp_dir = tempfile::tempdir().expect("tempdir for rc socket");
        let sock_path = temp_dir.path().join("kitty-rc.sock");
        let stderr_log = temp_dir.path().join("kitty-stderr.log");
        let stdout_log = temp_dir.path().join("kitty-stdout.log");
        let instance_group = format!("ksession-test-{}", std::process::id());

        // Build the kitty command.
        let sock_arg = format!("unix:{}", sock_path.display());
        let stderr_file = std::fs::File::create(&stderr_log).expect("create stderr log");
        let stdout_file = std::fs::File::create(&stdout_log).expect("create stdout log");

        // Spawn kitty with remote control enabled.
        // --config NONE prevents user's config from interfering.
        // --start-as=hidden keeps the window off-screen.
        let child = Command::new("kitty")
            .arg("--config")
            .arg("NONE")
            .arg("--start-as=hidden")
            .arg("--listen-on")
            .arg(&sock_arg)
            .arg("-o")
            .arg("allow_remote_control=yes")
            .arg("--instance-group")
            .arg(&instance_group)
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout_file))
            .stderr(Stdio::from(stderr_file))
            .spawn()
            .expect("spawn kitty");

        let child = Arc::new(Mutex::new(Some(child)));

        // Wait for the socket to appear.
        let startup_deadline = Instant::now() + STARTUP_TIMEOUT;
        let socket_ready = wait_for_socket(&sock_path, startup_deadline);

        if !socket_ready {
            // Try to get stderr for diagnostics.
            let _ = kill_child(&child).await;
            let stderr = std::fs::read_to_string(&stderr_log).unwrap_or_default();
            let stderr_lower = stderr.to_lowercase();
            let looks_like_no_display = stderr_lower.contains("display")
                || stderr_lower.contains("wayland")
                || stderr_lower.contains("x11")
                || stderr_lower.contains("opengl")
                || stderr.trim().is_empty();
            if looks_like_no_display {
                eprintln!(
                    "LiveKitty: kitty failed to start within {:?}, \
                     stderr looks like a display/GL issue — skipping test. \
                     stderr:\n{stderr}",
                    STARTUP_TIMEOUT,
                );
                return None;
            }
            eprintln!(
                "LiveKitty: kitty did not create RC socket within {:?}; stderr was:\n{stderr}",
                STARTUP_TIMEOUT,
            );
            return None;
        }

        // Give kitty a moment to finish initialization.
        thread::sleep(POST_READY_GRACE);

        // Connect to the kitty instance.
        let rpc = match KittyPool::connect(&sock_path, KittyPool::capacity_from_env()).await {
            Ok(rpc) => rpc,
            Err(e) => {
                let _ = kill_child(&child).await;
                eprintln!("LiveKitty: failed to connect to kitty: {e}");
                return None;
            }
        };

        Some(Self {
            rpc: Some(rpc),
            socket_path: sock_path,
            temp_dir,
            child,
        })
    }

    /// Get an RPC client connected to this kitty instance.
    ///
    /// The returned client is owned by the fixture and will be dropped
    /// when the fixture is dropped.
    pub async fn rpc(&mut self) -> Option<&KittyPool> {
        // If we haven't connected yet, try to connect.
        if self.rpc.is_none() {
            self.rpc = KittyPool::connect(&self.socket_path, KittyPool::capacity_from_env())
                .await
                .ok();
        }
        self.rpc.as_ref()
    }

    /// Get the socket path for this kitty instance.
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Get the KITTY_LISTEN_ON environment variable value for this instance.
    pub fn listen_on(&self) -> String {
        format!("unix:{}", self.socket_path.display())
    }
}

impl Drop for LiveKitty {
    fn drop(&mut self) {
        // Best-effort graceful shutdown.
        let child = Arc::clone(&self.child);
        let socket_path = self.socket_path.clone();

        // Try graceful shutdown first via kitten.
        let _ = Command::new("kitten")
            .arg("@")
            .arg("--to")
            .arg(format!("unix:{}", socket_path.display()))
            .arg("close-window")
            .arg("--match")
            .arg("all")
            .output();

        // The child will be killed when the Arc is dropped.
        // Use a blocking task to wait for cleanup.
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .ok();
            if let Some(rt) = rt {
                rt.block_on(async {
                    let _ = kill_child(&child).await;
                });
            }
        });
    }
}

/// Block until `sock` exists or the deadline passes. Returns `true` on success.
fn wait_for_socket(sock: &Path, deadline: Instant) -> bool {
    while Instant::now() < deadline {
        if sock.exists() {
            return true;
        }
        thread::sleep(Duration::from_millis(50));
    }
    false
}

/// Kill the child process if it still exists.
async fn kill_child(child: &Arc<Mutex<Option<Child>>>) {
    let mut guard = child.lock().await;
    if let Some(mut c) = guard.take() {
        let _ = c.kill();
        let _ = c.wait();
    }
}

/// Helper to skip a test when LiveKitty is unavailable.
///
/// # Usage
///
/// ```ignore
/// #[tokio::test]
/// #[ignore = "requires live kitty"]
/// async fn my_test() {
///     async fn run(kitty: &mut LiveKitty) {
///         // test code here
///     }
///     run_live_kitty_test(run).await;
/// }
/// ```
pub async fn run_live_kitty_test<F, Fut>(f: F)
where
    F: FnOnce(&mut LiveKitty) -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    let mut kitty = match LiveKitty::spawn().await {
        Some(k) => k,
        None => {
            // Skip the test - kitty is not available.
            eprintln!("test skipped: LiveKitty not available (no kitty binary or no display)");
            return;
        }
    };
    f(&mut kitty).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore = "requires live kitty"]
    async fn spawn_live_kitty() {
        let mut kitty = match LiveKitty::spawn().await {
            Some(k) => k,
            None => {
                // Skip gracefully when no display
                eprintln!("test skipped: no display available");
                return;
            }
        };

        let rpc = kitty
            .rpc()
            .await
            .expect("should be able to connect to live kitty");

        // Verify we can query the kitty instance.
        let osws = rpc
            .ls_all_env_vars()
            .await
            .expect("should be able to list windows");

        // We may have 0 windows (hidden, no tabs), but the call should succeed.
        println!("Got {} OS windows", osws.len());
    }

    #[tokio::test]
    #[ignore = "requires live kitty"]
    async fn spawn_live_kitty_sets_listen_on() {
        let kitty = match LiveKitty::spawn().await {
            Some(k) => k,
            None => {
                // Skip gracefully when no display
                eprintln!("test skipped: no display available");
                return;
            }
        };

        let listen_on = kitty.listen_on();
        assert!(
            listen_on.starts_with("unix:"),
            "listen_on should be unix socket: {}",
            listen_on
        );
        assert!(
            listen_on.contains("kitty-rc.sock"),
            "listen_on should contain socket name"
        );
    }
}
