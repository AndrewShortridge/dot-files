//! Safety and correctness integration tests for `TmuxControl`
//! (`src/tmux_rpc/control.rs`).
//!
//! Validates four invariants:
//!
//! 1. **Drop does not kill server** (User Story 3): disconnecting the
//!    control-mode client must leave the tmux server and session intact.
//! 2. **Disconnect degrades gracefully** (User Story 4): when the tmux
//!    server dies mid-connection, `request()` returns
//!    `Err(TmuxError::Disconnected)` — never panics.
//! 3. **Concurrent requests serialize correctly**: 12 parallel
//!    `request()` calls all receive the correct demuxed response.
//! 4. **Large capture-pane payload**: a ~64 KiB scrollback round-trips
//!    through the `%begin/%end` frame and the `decode_capture_c` decoder.
//!
//! All tests are gated on `tmux` being on PATH; they skip with a clear
//! message otherwise. Each test spawns an isolated `-L <socket>` server
//! (`helpers::tmux::IsolatedTmux`) killed in `Drop` so we never touch the
//! user's real tmux. Sessions are created with explicit geometry (-x/-y)
//! so the PTY has non-zero dimensions in a headless environment.

mod helpers;

use std::time::Duration;

use helpers::tmux::{tmux_available, IsolatedTmux};
use ksession_rs::tmux_rpc::{tmux_version, TmuxControl, TmuxError, TmuxIo};

/// Server with one session named `test` at 200×50.
fn isolated_test_server() -> IsolatedTmux {
    IsolatedTmux::builder("test").size(200, 50).spawn()
}

// ---------- Test 1: Drop does not kill server ----------

/// User Story 3: "never kill or detach my live tmux session on save
/// completion". After a TmuxControl connects and is dropped (or shut
/// down), the tmux server and the session it was attached to must
/// remain alive and intact.
#[tokio::test]
async fn tmux_control_drop_does_not_kill_server() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = isolated_test_server();

    // Connect and verify the pipe works.
    let ctrl = TmuxControl::connect(&server.socket_path, server.sid, tmux_version())
        .await
        .expect("TmuxControl::connect");

    let resp = ctrl
        .run(&["list-windows", "-t", "test", "-F", "#{window_index}"])
        .await
        .expect("list-windows should succeed while connected");
    assert!(
        !resp.trim().is_empty(),
        "expected at least one window index in response"
    );

    // Shut down the control client cleanly.
    ctrl.shutdown().await.expect("shutdown");

    // Give the tmux server a moment to process the detach.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Assert the tmux server is STILL alive and the session is intact.
    let sessions = server.try_run(&["list-sessions"]).unwrap_or_else(|stderr| {
        panic!(
            "tmux server should still be alive after TmuxControl shutdown, \
                 but list-sessions failed with: {stderr}"
        )
    });
    assert!(
        sessions.contains("test"),
        "session 'test' should still exist after TmuxControl shutdown, \
         got sessions: {sessions}"
    );

    // Clean up: server.drop() kills the tmux server.
}

// ---------- Test 2: Disconnect degrades gracefully ----------

/// User Story 4: graceful degradation when the tmux server dies
/// mid-connection. After killing the server, subsequent `request()`
/// calls should return `Err(TmuxError::Disconnected)` (or `Io`) —
/// never panic.
#[tokio::test]
async fn tmux_control_disconnect_degrades() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = isolated_test_server();

    let ctrl = TmuxControl::connect(&server.socket_path, server.sid, tmux_version())
        .await
        .expect("TmuxControl::connect");

    // Verify a request works before we kill the server.
    let resp = ctrl
        .run(&["display-message", "-p", "ALIVE"])
        .await
        .expect("request should work before server kill");
    assert!(resp.starts_with("ALIVE"), "got: {resp:?}");

    // Kill the tmux server out from under us.
    server.run(&["kill-server"]);

    // Give the read loop a moment to observe the EOF / %exit.
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Subsequent request should error, NOT panic.
    let err = ctrl
        .run(&["display-message", "-p", "DEAD"])
        .await
        .expect_err("expected error after server kill");

    // Accept either Disconnected or Io — both indicate the pipe
    // detected the failure. The key invariant is no panic.
    assert!(
        matches!(err, TmuxError::Disconnected(_) | TmuxError::Io(_)),
        "expected Disconnected or Io error, got: {err:?}"
    );

    // Prevent double kill-server in Drop (already dead).
    drop(server);
}

// ---------- Test 3: Concurrent requests ----------

/// Validates that concurrent `request()` calls serialize correctly on
/// the stdin mutex and the demuxer routes responses to the correct
/// senders. 12 tasks each send `list-windows` and all should get the
/// same correct answer.
#[tokio::test]
async fn tmux_control_concurrent_requests() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = isolated_test_server();

    // Add two more windows so there are 3 total.
    for name in &["second", "third"] {
        server.run(&["new-window", "-t", "test", "-n", name]);
    }

    let ctrl = TmuxControl::connect(&server.socket_path, server.sid, tmux_version())
        .await
        .expect("TmuxControl::connect");

    // Share the control handle across tasks via Arc. TmuxControl is
    // not Clone, so wrap in Arc.
    let ctrl = std::sync::Arc::new(ctrl);

    let mut handles = Vec::new();
    for _ in 0..12 {
        let c = std::sync::Arc::clone(&ctrl);
        handles.push(tokio::spawn(async move {
            c.run(&["list-windows", "-t", "test", "-F", "#{window_index}"])
                .await
        }));
    }

    let mut results = Vec::new();
    for h in handles {
        let res = h.await.expect("task should not panic");
        results.push(res);
    }

    // All 12 should be Ok with the same content.
    let expected = results[0]
        .as_ref()
        .expect("first result should be Ok")
        .clone();

    // Verify the expected content lists 3 windows.
    let lines: Vec<&str> = expected.lines().filter(|l| !l.is_empty()).collect();
    assert_eq!(lines.len(), 3, "expected 3 window indices, got: {lines:?}");

    for (i, res) in results.iter().enumerate() {
        let val = res
            .as_ref()
            .unwrap_or_else(|e| panic!("task {i} should be Ok, got: {e:?}"));
        assert_eq!(*val, expected, "task {i} response differs from task 0");
    }
}

// ---------- Test 4: Large capture-pane payload ----------

/// Validates that the `%begin/%end` frame can carry large payloads
/// (~64 KiB) and that the `decode_capture_c` decoder works correctly
/// through control mode's `capture_pane_to_file`.
#[tokio::test]
async fn tmux_control_large_capture_pane() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    // We need a large history-limit, but `set-option -g` only applies
    // to panes created AFTER the option is set. Strategy: start the
    // server with a detached session (explicit geometry so the PTY
    // has non-zero columns), raise the history-limit, then create a
    // NEW window running `seq` directly as its command — this avoids
    // send-keys timing issues in a headless environment.
    let server = isolated_test_server();

    // Raise history-limit globally BEFORE creating the working pane.
    server.run(&["set-option", "-g", "history-limit", "50000"]);

    // Create a new window running `seq` directly as its command.
    // The `sleep 60` keeps the pane alive after seq finishes so we
    // can capture its scrollback before tmux destroys the pane.
    server.run(&[
        "new-window",
        "-t",
        "test",
        "-n",
        "bigbuf",
        "seq 1 10000; sleep 60",
    ]);

    // Get the pane ID of the bigbuf window.
    let pane_id = server
        .run(&["list-panes", "-t", "test:bigbuf", "-F", "#{pane_id}"])
        .lines()
        .next()
        .expect("at least one pane in bigbuf")
        .trim()
        .to_string();

    // Wait for `seq` to finish (pane command transitions from `seq`
    // to `sleep`). Max 10s.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let cmd = server.display(&pane_id, "#{pane_current_command}");
        // `seq` has finished when the pane command is `sleep` (the
        // trailing `sleep 60` in the window command).
        if cmd == "sleep" {
            break;
        }
        if std::time::Instant::now() > deadline {
            panic!("timed out waiting for seq to finish; last pane cmd: {cmd}");
        }
    }

    // Connect TmuxControl.
    let ctrl = TmuxControl::connect(&server.socket_path, server.sid, tmux_version())
        .await
        .expect("TmuxControl::connect");

    // Capture to a temp file.
    let tmp_dir = tempfile::tempdir().expect("create tempdir");
    let dest = tmp_dir.path().join("scrollback.txt");

    let bytes_written = ctrl
        .capture_pane_to_file(&pane_id, &dest, false)
        .await
        .expect("capture_pane_to_file");

    // Read the file and validate.
    let content = std::fs::read_to_string(&dest).expect("read captured file");

    assert!(
        bytes_written > 10_000,
        "expected >10KB captured, got {bytes_written} bytes"
    );
    assert!(!content.is_empty(), "captured file should not be empty");

    // Verify the decoded content contains expected sequences from `seq`.
    assert!(
        content.contains("1000"),
        "captured content should contain '1000'"
    );
    assert!(
        content.contains("5000"),
        "captured content should contain '5000'"
    );
    // 9000 should be in scrollback even if the shell prompt overwrote
    // the bottom visible line.
    assert!(
        content.contains("9000"),
        "captured content should contain '9000'"
    );

    // Clean up: drop the control pipe first, then let `server`'s Drop
    // kill the server once the pipe has had a moment to close.
    drop(ctrl);
    tokio::time::sleep(Duration::from_millis(100)).await;
}
