//! Integration test for Slice 11 — ready marker contract.
//!
//! Verifies that:
//! - `touch_ready` creates the marker file at the correct path.
//! - `wait_for_all` returns Ok when all expected markers arrive.
//! - `wait_for_all` returns Err(ReadyTimeout) when not enough markers
//!   arrive within the timeout window.
//! - The rendered restore.sh contains the ready marker line before
//!   the attach-session line.
//!
//! The Rust-side ready marker in `cli::save` is tested indirectly: the
//! unit tests in `src/perf/ready.rs` verify `touch_ready_if_tracing`,
//! and this test exercises the full `wait_for_all` lifecycle with
//! realistic contributor names.

use std::time::Duration;
use tempfile::tempdir;

use ksession_rs::perf::ready::{
    ready_timeout_from_env, touch_ready, wait_for_all, DEFAULT_TIMEOUT_MS,
};

/// Full lifecycle: three contributors touch markers with stagger,
/// `wait_for_all` returns Ok.
#[tokio::test]
async fn ready_marker_full_lifecycle() {
    let dir = tempdir().unwrap();
    let trace_dir = dir.path().to_path_buf();

    // Simulate the three contributor types with realistic names.
    let td = trace_dir.clone();
    tokio::spawn(async move {
        // Rust side (immediate).
        touch_ready(&td, "rust");
        // Tmux side (small delay).
        tokio::time::sleep(Duration::from_millis(30)).await;
        touch_ready(&td, "tmux-dev");
        // Nvim side (more delay).
        tokio::time::sleep(Duration::from_millis(30)).await;
        touch_ready(&td, "nvim-12345");
    });

    let result = wait_for_all(&trace_dir, 3, Duration::from_secs(5)).await;
    assert!(result.is_ok(), "wait_for_all should succeed: {result:?}");

    // Verify the files actually exist on disk.
    assert!(trace_dir.join("ready/rust").exists());
    assert!(trace_dir.join("ready/tmux-dev").exists());
    assert!(trace_dir.join("ready/nvim-12345").exists());
}

/// Timeout path: only 1 of 3 markers arrives.
#[tokio::test]
async fn ready_marker_timeout_reports_missing() {
    let dir = tempdir().unwrap();
    let trace_dir = dir.path().to_path_buf();

    touch_ready(&trace_dir, "rust");
    // tmux-main and nvim-999 never arrive.

    let result = wait_for_all(&trace_dir, 3, Duration::from_millis(150)).await;
    assert!(result.is_err(), "should timeout");

    let err = result.unwrap_err();
    assert_eq!(err.present.len(), 1);
    assert_eq!(err.missing.len(), 2);
    assert!(err.present.contains(&"rust".to_string()));
}

/// The env-based timeout override works.
#[test]
fn ready_timeout_from_env_override() {
    // Default path.
    std::env::remove_var("KSESSION_TRACE_READY_TIMEOUT_MS");
    let d = ready_timeout_from_env(DEFAULT_TIMEOUT_MS);
    assert_eq!(d, Duration::from_millis(30_000));

    // Override path.
    std::env::set_var("KSESSION_TRACE_READY_TIMEOUT_MS", "5000");
    let d = ready_timeout_from_env(DEFAULT_TIMEOUT_MS);
    assert_eq!(d, Duration::from_millis(5_000));

    // Cleanup.
    std::env::remove_var("KSESSION_TRACE_READY_TIMEOUT_MS");
}

/// The restore.sh template contains the ready marker line in the
/// correct position (before attach-session).
#[test]
fn restore_sh_contains_ready_marker() {
    use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

    let rs = RestoreScript {
        session: "test-sess".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: "".to_string(),
            active: true,
            panes: vec![RestorePane {
                uid: "0".to_string(),
                idx: 0,
                cwd: "/tmp".to_string(),
                cmd: None,
                scrollback_path: None,
            }],
            active_pane_idx: Some(0),
        }],
        active_pane: Some((0, 0)),
    };

    let script = render_restore_sh(&rs);

    // The ready marker line must exist.
    assert!(
        script.contains("touch \"$KSESSION_TRACE_DIR/ready/tmux-$SESS\""),
        "ready marker touch missing from restore.sh:\n{script}"
    );

    // It must come before the final attach-session (the exec line at
    // the end of the script, not the early-bail attach in the
    // "session already exists" guard).
    let marker_pos = script
        .find("touch \"$KSESSION_TRACE_DIR/ready/tmux-$SESS\"")
        .unwrap();
    let attach_pos = script
        .rfind("exec tmux attach-session -t \"=$SESS\"")
        .expect("final attach-session line missing");
    assert!(
        marker_pos < attach_pos,
        "ready marker must precede final attach-session"
    );

    // It must be gated on KSESSION_TRACE_DIR.
    assert!(
        script.contains("[ -n \"${KSESSION_TRACE_DIR-}\" ]"),
        "ready marker must be gated on KSESSION_TRACE_DIR"
    );
}
