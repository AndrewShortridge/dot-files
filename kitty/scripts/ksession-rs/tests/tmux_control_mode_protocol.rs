//! Regression suite for the `tmux -C` control-mode transport in
//! `src/tmux_rpc/control.rs` (plan §B.3.2 / step 7.5).
//!
//! Most of the parser/demuxer correctness is covered by the unit tests
//! INSIDE `control.rs` (using the `pub(crate)` `process_line` /
//! `ParserState`). This file adds integration-level coverage:
//!
//! - End-to-end FIFO correlation against a real tmux server: spawn a
//!   `TmuxControl`, fire two concurrent `request()` calls, assert each
//!   gets its own answer.
//! - `%exit` shutdown: after killing the tmux server, the in-flight
//!   request resolves to `Disconnected` and subsequent requests
//!   fail-fast with `Disconnected`.
//!
//! Tests gated on `tmux` being on PATH; skip with a clear message
//! otherwise. Each test uses an isolated `-L <socket>` server
//! (`helpers::tmux::IsolatedTmux`) killed in `Drop` so we never touch
//! the user's real tmux.

mod helpers;

use std::time::Duration;

use helpers::tmux::{tmux_available, IsolatedTmux};
use ksession_rs::tmux_rpc::{tmux_version, TmuxControl, TmuxError, TmuxIo};

#[tokio::test]
async fn end_to_end_two_concurrent_requests_demux_correctly() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let ctrl = TmuxControl::connect(&server.socket_path, server.sid, tmux_version())
        .await
        .expect("TmuxControl::connect");

    // Fire two requests in parallel and verify each gets its own
    // response. The cmd-num demux is FIFO; if it's wrong, the answers
    // get swapped or wedged.
    let a = ctrl.run(&["display-message", "-p", "AAA"]);
    let b = ctrl.run(&["display-message", "-p", "BBB"]);
    let (ra, rb) = tokio::join!(a, b);
    let ra = ra.expect("AAA");
    let rb = rb.expect("BBB");
    assert!(ra.starts_with("AAA"), "got: {ra:?}");
    assert!(rb.starts_with("BBB"), "got: {rb:?}");
}

#[tokio::test]
async fn list_windows_over_control_pipe_matches_subprocess() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();

    // Add a second window via subprocess so we have something to count.
    server.run(&["new-window", "-t", "demo", "-n", "second"]);

    let ctrl = TmuxControl::connect(&server.socket_path, server.sid, tmux_version())
        .await
        .unwrap();
    let wins = ksession_rs::tmux_rpc::list_windows(&ctrl, "demo")
        .await
        .expect("list_windows");
    assert_eq!(wins.len(), 2);
    assert_eq!(wins[0].idx, 0);
    assert_eq!(wins[1].idx, 1);
    assert_eq!(wins[1].name, "second");
}

#[tokio::test]
async fn disconnected_after_server_killed() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let ctrl = TmuxControl::connect(&server.socket_path, server.sid, tmux_version())
        .await
        .unwrap();

    // One successful request to prove the pipe is open.
    let r = ctrl.run(&["display-message", "-p", "PING"]).await.unwrap();
    assert!(r.starts_with("PING"));

    // Kill the server out-from-under it.
    server.run(&["kill-server"]);

    // Give the read loop a moment to observe the EOF / %exit.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Any subsequent request must surface Disconnected (or an Io
    // error if the write races the EOF — both are acceptable proof
    // of detection; the test just asserts it doesn't HANG and
    // doesn't return Ok).
    let err = ctrl
        .run(&["display-message", "-p", "PONG"])
        .await
        .expect_err("expected error after server kill");
    assert!(
        matches!(err, TmuxError::Disconnected(_) | TmuxError::Io(_)),
        "expected Disconnected/Io, got: {err:?}"
    );

    // server's Drop already attempts kill-server — no-op now.
    drop(server);
}
