//! Ready-marker contract for cross-process "session fully loaded" signalling.
//!
//! Each contributor process (rust, tmux restore.sh, nvim ksession_restore.lua)
//! touches `<trace_dir>/ready/<contributor>` as its final action. The file
//! content is empty; existence is the signal.
//!
//! See [Slice 11](../../../docs/issues/prd-0002/11-ready-marker.md) and the
//! "Ready marker" section of
//! [PRD-0](../../../docs/prds/0002-observability-infrastructure.md).

use std::path::Path;
use std::time::Duration;

/// Touch `<trace_dir>/ready/<contributor>`.
///
/// Creates the `ready/` subdirectory if it doesn't exist, then creates
/// (or truncates) the marker file. Gated on `KSESSION_TRACE_DIR` being
/// set — callers should check the env var before calling, or use
/// [`touch_ready_if_tracing`] which does the check internally.
///
/// Errors are silently ignored (best-effort signal — must never abort
/// the save/restore flow).
pub fn touch_ready(trace_dir: &Path, contributor: &str) {
    let ready_dir = trace_dir.join("ready");
    let _ = std::fs::create_dir_all(&ready_dir);
    let marker = ready_dir.join(contributor);
    let _ = std::fs::File::create(&marker);
}

/// Convenience wrapper: touch the ready marker only when
/// `KSESSION_TRACE_DIR` is set. No-op otherwise.
pub fn touch_ready_if_tracing(contributor: &str) {
    if let Some(dir) = std::env::var_os("KSESSION_TRACE_DIR") {
        touch_ready(std::path::Path::new(&dir), contributor);
    }
}

/// Error returned by [`wait_for_all`] when the timeout elapses before
/// the expected number of ready markers appear.
#[derive(Debug, Clone)]
pub struct ReadyTimeout {
    /// Names of contributors whose markers were NOT found.
    pub missing: Vec<String>,
    /// Names of contributors whose markers WERE found.
    pub present: Vec<String>,
    /// The timeout that elapsed.
    pub timeout: Duration,
}

impl std::fmt::Display for ReadyTimeout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "ready-marker timeout after {:.1}s: {}/{} markers present, missing: [{}]",
            self.timeout.as_secs_f64(),
            self.present.len(),
            self.present.len() + self.missing.len(),
            self.missing.join(", "),
        )
    }
}

impl std::error::Error for ReadyTimeout {}

/// Read the timeout from `KSESSION_TRACE_READY_TIMEOUT_MS`, falling back
/// to `default_ms` if unset or unparseable.
pub fn ready_timeout_from_env(default_ms: u64) -> Duration {
    std::env::var("KSESSION_TRACE_READY_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or(Duration::from_millis(default_ms))
}

/// Default ready-marker timeout in milliseconds.
pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;

/// Poll `<trace_dir>/ready/` until at least `expected` marker files
/// exist, or `timeout` elapses.
///
/// Uses a simple 50 ms poll loop (inotify is a nice-to-have, not
/// required). Returns `Ok(())` when the count is met, or
/// `Err(ReadyTimeout)` with the names of missing markers.
///
/// The caller does not need to know the expected contributor names
/// up-front — this function only counts files and reports which ones
/// are present vs. absent relative to `expected`.
pub async fn wait_for_all(
    trace_dir: &Path,
    expected: usize,
    timeout: Duration,
) -> Result<(), ReadyTimeout> {
    let ready_dir = trace_dir.join("ready");
    let deadline = tokio::time::Instant::now() + timeout;
    let poll_interval = Duration::from_millis(50);

    loop {
        // Read the ready directory and collect marker names.
        let present = list_markers(&ready_dir);
        if present.len() >= expected {
            return Ok(());
        }

        if tokio::time::Instant::now() >= deadline {
            // Timeout: report what we found vs. expected count.
            // Since we don't know the expected names, we report the count
            // deficit as synthetic "unknown-N" entries.
            let mut missing = Vec::new();
            let found = present.len();
            for i in 0..(expected - found) {
                missing.push(format!("unknown-{i}"));
            }
            return Err(ReadyTimeout {
                missing,
                present,
                timeout,
            });
        }

        tokio::time::sleep(poll_interval).await;
    }
}

/// [`wait_for_all`] wrapped in a `ready.wait` span.
///
/// This is the preferred entry point for the restore coordination path:
/// the span captures the total time spent blocking on contributor markers,
/// which directly corresponds to the user-perceived "restore latency"
/// beyond what the Rust side itself spends.
///
/// The span carries `expected` and (on completion) `found` args so the
/// trace viewer shows how many markers were awaited and how many arrived.
pub async fn wait_for_all_with_span(
    trace_dir: &Path,
    expected: usize,
    timeout: Duration,
) -> Result<(), ReadyTimeout> {
    let mut _span = crate::perf_span!(crate::perf::Level::Info, "ready.wait", expected = expected);
    let result = wait_for_all(trace_dir, expected, timeout).await;
    if let Some(s) = _span.as_mut() {
        match &result {
            Ok(()) => s.push_arg("found", format!("{expected}")),
            Err(e) => s.push_arg("found", format!("{}", e.present.len())),
        }
    }
    result
}

/// List the file names in `ready_dir`. Returns an empty vec if the
/// directory doesn't exist or can't be read.
fn list_markers(ready_dir: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(ready_dir) else {
        return Vec::new();
    };
    entries
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().map(|ft| ft.is_file()).unwrap_or(false))
        .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
        .collect()
}

// ---------------------------------------------------------------------------
// Per-component restore spans (Issue #10)
// ---------------------------------------------------------------------------
//
// These spans bracket the per-component phases of the restore lifecycle.
// Some are emitted by the Rust orchestrator (kitty.launch, ready.wait);
// others are emitted by the external contributor processes (nvim, tmux)
// that call back into the Rust tracer via the same JSONL file format.
//
// The helper functions below provide a uniform API for creating these spans
// from both the binary's coordination logic and from integration tests that
// simulate the restore path.

/// Create an `nvim.spawn` span guard. Measures time from nvim process
/// spawn (via kitty launch line) to the nvim RPC socket becoming reachable.
///
/// Callers should hold the returned guard across the spawn + socket-ready
/// poll, then drop it when the socket is confirmed live.
#[must_use]
pub fn span_nvim_spawn(window_id: u64) -> Option<super::Span> {
    match crate::perf::Tracer::current() {
        Some(t) if crate::perf::Level::Info <= t.level() => {
            let args: &[(&'static str, String)] = &[("window_id", format!("{window_id}"))];
            Some(super::Span::new("nvim.spawn", args))
        }
        _ => None,
    }
}

/// Create an `nvim.source_session` span guard. Measures time for nvim to
/// source its mksession script (the `-S <file>.vim` flag from the kitty
/// launch line) and signal readiness via a ready marker.
///
/// Callers should hold the returned guard from the point nvim's socket is
/// live to the point the nvim ready marker appears.
#[must_use]
pub fn span_nvim_source_session(window_id: u64) -> Option<super::Span> {
    match crate::perf::Tracer::current() {
        Some(t) if crate::perf::Level::Info <= t.level() => {
            let args: &[(&'static str, String)] = &[("window_id", format!("{window_id}"))];
            Some(super::Span::new("nvim.source_session", args))
        }
        _ => None,
    }
}

/// Create a `tmux.spawn` span guard. Measures time to launch `tmux
/// new-session` from the restore.sh script invoked by the kitty launch
/// line.
///
/// Callers should hold the returned guard across the tmux new-session
/// command execution.
#[must_use]
pub fn span_tmux_spawn(session_name: &str) -> Option<super::Span> {
    match crate::perf::Tracer::current() {
        Some(t) if crate::perf::Level::Info <= t.level() => {
            let args: &[(&'static str, String)] = &[("session", session_name.to_string())];
            Some(super::Span::new("tmux.spawn", args))
        }
        _ => None,
    }
}

/// Create a `tmux.restore` span guard. Measures time to execute
/// restore.sh and recreate the full tmux session structure (windows,
/// panes, layouts, select-pane).
///
/// Callers should hold the returned guard from restore.sh invocation
/// start to its successful exit (or ready-marker touch).
#[must_use]
pub fn span_tmux_restore(session_name: &str) -> Option<super::Span> {
    match crate::perf::Tracer::current() {
        Some(t) if crate::perf::Level::Info <= t.level() => {
            let args: &[(&'static str, String)] = &[("session", session_name.to_string())];
            Some(super::Span::new("tmux.restore", args))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn touch_ready_creates_marker_file() {
        let dir = tempdir().unwrap();
        touch_ready(dir.path(), "rust");
        let marker = dir.path().join("ready").join("rust");
        assert!(
            marker.exists(),
            "marker file should exist after touch_ready"
        );
    }

    #[test]
    fn touch_ready_creates_subdirectory() {
        let dir = tempdir().unwrap();
        let trace = dir.path().join("nested").join("trace");
        // The parent doesn't exist yet — touch_ready should create it.
        touch_ready(&trace, "test-contributor");
        assert!(trace.join("ready").join("test-contributor").exists());
    }

    #[test]
    fn list_markers_returns_empty_for_missing_dir() {
        let dir = tempdir().unwrap();
        let markers = list_markers(&dir.path().join("nonexistent"));
        assert!(markers.is_empty());
    }

    #[test]
    fn list_markers_returns_file_names() {
        let dir = tempdir().unwrap();
        let ready = dir.path().join("ready");
        std::fs::create_dir_all(&ready).unwrap();
        std::fs::File::create(ready.join("rust")).unwrap();
        std::fs::File::create(ready.join("tmux-main")).unwrap();
        std::fs::File::create(ready.join("nvim-1234")).unwrap();

        let mut markers = list_markers(&ready);
        markers.sort();
        assert_eq!(markers, vec!["nvim-1234", "rust", "tmux-main"]);
    }

    #[tokio::test]
    async fn wait_for_all_returns_ok_when_markers_appear() {
        let dir = tempdir().unwrap();
        let trace_dir = dir.path().to_path_buf();
        let ready = trace_dir.join("ready");
        std::fs::create_dir_all(&ready).unwrap();

        // Spawn a task that touches 3 markers with staggered sleeps.
        let td = trace_dir.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            touch_ready(&td, "rust");
            tokio::time::sleep(Duration::from_millis(50)).await;
            touch_ready(&td, "tmux-main");
            tokio::time::sleep(Duration::from_millis(50)).await;
            touch_ready(&td, "nvim-42");
        });

        let result = wait_for_all(&trace_dir, 3, Duration::from_secs(5)).await;
        assert!(result.is_ok(), "wait_for_all should succeed: {result:?}");
    }

    #[tokio::test]
    async fn wait_for_all_returns_timeout_with_missing_names() {
        let dir = tempdir().unwrap();
        let trace_dir = dir.path().to_path_buf();

        // Touch only 1 of 3 expected markers.
        touch_ready(&trace_dir, "rust");

        let result = wait_for_all(&trace_dir, 3, Duration::from_millis(100)).await;
        assert!(result.is_err(), "should timeout with only 1 of 3 markers");

        let err = result.unwrap_err();
        assert_eq!(err.present.len(), 1, "1 marker should be present");
        assert_eq!(err.missing.len(), 2, "2 markers should be missing");
        assert!(
            err.present.contains(&"rust".to_string()),
            "rust should be in present list"
        );
    }

    #[tokio::test]
    async fn wait_for_all_returns_ok_immediately_when_already_met() {
        let dir = tempdir().unwrap();
        let trace_dir = dir.path().to_path_buf();

        // Pre-create all markers.
        touch_ready(&trace_dir, "rust");
        touch_ready(&trace_dir, "tmux-dev");
        touch_ready(&trace_dir, "nvim-99");

        let start = std::time::Instant::now();
        let result = wait_for_all(&trace_dir, 3, Duration::from_secs(5)).await;
        let elapsed = start.elapsed();

        assert!(result.is_ok());
        // Should return almost immediately (well under 1 second).
        assert!(
            elapsed < Duration::from_secs(1),
            "should return immediately when markers already present, took {elapsed:?}"
        );
    }

    #[test]
    fn ready_timeout_display_includes_details() {
        let err = ReadyTimeout {
            missing: vec!["tmux-main".into(), "nvim-42".into()],
            present: vec!["rust".into()],
            timeout: Duration::from_secs(30),
        };
        let msg = err.to_string();
        assert!(msg.contains("30.0s"), "should show timeout: {msg}");
        assert!(msg.contains("1/3"), "should show count: {msg}");
        assert!(msg.contains("tmux-main"), "should list missing: {msg}");
        assert!(msg.contains("nvim-42"), "should list missing: {msg}");
    }
}
