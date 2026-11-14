//! Plan §B.3.2 layout-corruption mitigation regression test.
//!
//! A `tmux -C attach` client is a real attached client. Tmux resizes
//! every window in the session to match the smallest attached client
//! (default tty 80×24). Per tmux#2594, the reflow persists after the
//! control-mode client detaches — so without mitigation, every save
//! would permanently shrink the user's session layout.
//!
//! The mitigation is `attach-session -r` on tmux ≥ 3.2 (read-only +
//! ignore-size). This test:
//!
//! 1. Spawns an isolated tmux server with a window resized larger than
//!    the default 80×24.
//! 2. Captures the window's `#{window_layout}` checksum string.
//! 3. Opens a `TmuxControl` against the server (which uses `-r` on
//!    tmux ≥ 3.2), runs a representative batch of save-time queries.
//! 4. Drops the control. Re-queries the layout via subprocess and
//!    asserts it matches the pre-control checksum byte-for-byte.
//!
//! Without the `-r` flag, the layout would shrink to 80×24 and the
//! checksum prefix would change — the test catches the regression.

mod helpers;

use std::time::Duration;

use helpers::tmux::{tmux_available, IsolatedTmux};
use ksession_rs::tmux_rpc::{list_panes, list_windows, tmux_version, TmuxControl};

/// `#{window_layout}` of the bootstrap window — the checksum-prefixed
/// string that changes the moment tmux reflows the panes.
fn layout(server: &IsolatedTmux) -> String {
    server.display("demo:0", "#{window_layout}")
}

#[tokio::test]
async fn layout_preserved_through_control_mode_save() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let version = tmux_version();

    // 200×60 is larger than the control-mode default 80×24 — if the
    // mitigation is absent, the post-control layout will reflow to
    // 80×24 and the checksum prefix changes.
    let server = IsolatedTmux::builder("demo").size(200, 60).spawn();
    // Make this multi-pane so the layout string has structure that
    // would visibly degrade if reflowed. Two splits → 3 panes.
    server.run(&["split-window", "-h", "-t", "demo:0"]);
    server.run(&["split-window", "-v", "-t", "demo:0"]);
    let layout_before = layout(&server);
    assert!(
        !layout_before.is_empty(),
        "tmux returned empty layout — test setup bug"
    );

    // Open the control pipe and run the queries the adapter would run
    // during a save: list-windows, list-panes for each window, and one
    // display-message per pane field (covered by list_panes).
    let ctrl = TmuxControl::connect(&server.socket_path, server.sid, version)
        .await
        .expect("TmuxControl::connect");

    let wins = list_windows(&ctrl, "demo").await.expect("list_windows");
    assert!(!wins.is_empty());
    for w in &wins {
        let panes = list_panes(&ctrl, "demo", w.idx).await.expect("list_panes");
        assert!(!panes.is_empty(), "window has no panes — test bug");
    }

    // Drop the control client. Give tmux a beat to recompute sizes if
    // the mitigation failed.
    ctrl.shutdown().await.ok();
    tokio::time::sleep(Duration::from_millis(200)).await;

    let layout_after = layout(&server);

    if matches!(version, Some(v) if v >= (3, 2)) {
        // With `-r` (tmux ≥ 3.2), the layout must be byte-identical.
        assert_eq!(
            layout_after, layout_before,
            "tmux ≥ 3.2 with -r: layout must be preserved; before={layout_before}, after={layout_after}"
        );
    } else {
        // On tmux < 3.2 the test still runs but only documents the
        // (lack of) mitigation — don't fail. Emit a notice.
        if layout_after != layout_before {
            eprintln!(
                "note: tmux <3.2 ({:?}): layout reflowed (before={layout_before}, after={layout_after}) — fallback path not yet implemented",
                version
            );
        }
    }
}
