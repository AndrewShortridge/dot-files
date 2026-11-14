//! End-to-end synthetic-window round trip (plan §5.7 / §C.1).
//!
//! Acceptance test for issue #03 of the v1 finish-line PRD:
//!
//! 1. Capture a kitty OS window with one empty tab (every kitty window
//!    filtered out as `is_self` or an overlay child). The manifest must
//!    contain a [`Window`] with `kitty_id >= SYNTHETIC_ID_FLOOR`, and the
//!    rendered `.conf` must inject a `launch /bin/bash -l` line into that
//!    tab.
//! 2. Multi-empty-tab case: one OS window with two empty tabs must produce
//!    two distinct synthetic windows (not one collapsed entry), each with
//!    its own `launch /bin/bash -l` line.
//!
//! Drives the full `session::save` pipeline against a DCS mock kitty server
//! (mirroring `tests/save_orchestration.rs`). The mock returns an `ls` JSON
//! whose tabs contain only overlay windows so the orchestrator's
//! `filter_windows` reduces every tab to empty.
//!
//! The two scenarios share `$KITTY_LISTEN_ON` (process-global), so they're
//! sequenced inside a single `#[tokio::test]` to avoid races under the
//! multi-threaded test runner.

use std::path::PathBuf;
use std::sync::Arc;

use ksession_rs::model::SYNTHETIC_ID_FLOOR;
use ksession_rs::session::{save, SaveOpts};

use serde_json::{json, Value};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tokio::sync::oneshot;

// --- DCS framing helpers ---------------------------------------------------

const DCS_PREFIX: &[u8] = b"\x1bP@kitty-cmd";
const DCS_TERMINATOR: &[u8] = b"\x1b\\";

fn encode_frame(json_bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(DCS_PREFIX.len() + json_bytes.len() + DCS_TERMINATOR.len());
    out.extend_from_slice(DCS_PREFIX);
    out.extend_from_slice(json_bytes);
    out.extend_from_slice(DCS_TERMINATOR);
    out
}

fn find_terminator(buf: &[u8]) -> Option<usize> {
    buf.windows(DCS_TERMINATOR.len())
        .position(|w| w == DCS_TERMINATOR)
}

async fn spawn_mock_server<F>(handler: F) -> (PathBuf, tempfile::TempDir)
where
    F: Fn(Value) -> Option<Value> + Send + Sync + 'static,
{
    let dir = tempdir().expect("tempdir");
    let sock = dir.path().join("rpc.sock");
    let listener = UnixListener::bind(&sock).expect("bind");
    let h = Arc::new(handler);
    tokio::spawn(async move {
        loop {
            let (mut stream, _) = match listener.accept().await {
                Ok(p) => p,
                Err(_) => return,
            };
            let h2 = h.clone();
            let (done_tx, _done_rx) = oneshot::channel::<()>();
            tokio::spawn(async move {
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
                        let json_bytes =
                            &frame[DCS_PREFIX.len()..frame.len() - DCS_TERMINATOR.len()];
                        let req: Value = serde_json::from_slice(json_bytes).expect("req parses");
                        if let Some(resp_json) = h2(req) {
                            let resp_bytes = serde_json::to_vec(&resp_json).expect("ser");
                            let _ = stream.write_all(&encode_frame(&resp_bytes)).await;
                            let _ = stream.flush().await;
                        }
                    }
                }
                let _ = done_tx.send(());
            });
        }
    });
    (sock, dir)
}

// --- canned fixtures -------------------------------------------------------

/// One OS window, `n_empty_tabs` tabs, each containing only an overlay
/// child window (filtered out by `save::filter_windows`). The skeleton
/// served by `ls --output-format=session` has matching `new_tab` boundaries
/// but no launch lines per tab — mirrors what kitty emits when every window
/// in a tab is an overlay (the overlay's launch line is not material to
/// this test; what matters is that the patcher emits one
/// `launch /bin/bash -l` per empty tab).
fn ls_json_with_empty_tabs(n_empty_tabs: usize) -> Value {
    let mut tabs = Vec::with_capacity(n_empty_tabs);
    for i in 0..n_empty_tabs {
        let tab_id = (i as u32) + 1;
        // Window with overlay_parent set → filtered out.
        tabs.push(json!({
            "id": tab_id,
            "title": "",
            "layout": "splits",
            "is_active": i == 0,
            "windows": [{
                "id": 100u64 + i as u64,
                "pid": 1000u32 + i as u32,
                "title": "",
                "is_active": true,
                "overlay_parent": 1u64, // forces filter_windows() to drop
                "foreground_processes": [],
                "env": {},
                "user_vars": {}
            }]
        }));
    }
    json!([{
        "id": 1,
        "is_focused": true,
        "is_active": true,
        "tabs": tabs,
    }])
}

/// Skeleton with `n_empty_tabs` `new_tab` blocks and no launch lines. This
/// is the realistic shape when every window in every tab is an overlay
/// that kitty filtered upstream — but even if kitty emitted overlay
/// launches in production, the synthetic-window injection happens
/// independently of which launches the skeleton carries.
fn skeleton_with_empty_tabs(n_empty_tabs: usize) -> String {
    let mut s = String::new();
    for _ in 0..n_empty_tabs {
        s.push_str("new_tab\nlayout splits\n\n");
    }
    s.push_str("focus_tab 0\n");
    s
}

fn make_handler(n_empty_tabs: usize) -> impl Fn(Value) -> Option<Value> + Send + Sync + 'static {
    let ls = ls_json_with_empty_tabs(n_empty_tabs);
    let skel = skeleton_with_empty_tabs(n_empty_tabs);
    move |req| match req["cmd"].as_str() {
        Some("ls") => {
            if req["payload"]["output_format"] == "session" {
                Some(json!({ "ok": true, "data": skel.clone() }))
            } else {
                Some(json!({
                    "ok": true,
                    "data": serde_json::to_string(&ls).expect("ser ls"),
                }))
            }
        }
        Some("get_text") => Some(json!({ "ok": true, "data": "" })),
        Some("set_user_vars") => None,
        _ => Some(json!({ "ok": true, "data": "" })),
    }
}

fn find_gen_state_dir(sessions_dir: &std::path::Path, name: &str) -> PathBuf {
    let prefix = format!("{name}.gen-");
    for ent in std::fs::read_dir(sessions_dir).expect("read sessions_dir") {
        let ent = match ent {
            Ok(e) => e,
            Err(_) => continue,
        };
        let s = ent.file_name().to_string_lossy().into_owned();
        if s.starts_with(&prefix) && s.ends_with(".state") {
            return ent.path();
        }
    }
    panic!(
        "no gen-stamped state dir found for {name} in {}",
        sessions_dir.display()
    );
}

// --- the test --------------------------------------------------------------

#[tokio::test]
async fn synthetic_window_round_trip() {
    std::env::remove_var("KITTY_WINDOW_ID");
    std::env::remove_var("KSESSION_SCROLLBACK");

    // ---------- Scenario 1: one OS window, one empty tab ----------
    let (sock_a, _guard_a) = spawn_mock_server(make_handler(1)).await;
    std::env::set_var("KITTY_LISTEN_ON", format!("unix:{}", sock_a.display()));

    let sessions = tempdir().expect("sessions tmp");
    save(SaveOpts {
        name: "one_empty".into(),
        all: true,
        scrollback: false,
        sessions_dir: sessions.path().to_path_buf(),
        ..Default::default()
    })
    .await
    .expect("save ok");

    let state_dir = find_gen_state_dir(sessions.path(), "one_empty");
    let manifest_text =
        std::fs::read_to_string(state_dir.join("manifest.json")).expect("read manifest");
    let manifest: serde_json::Value =
        serde_json::from_str(&manifest_text).expect("manifest parses");

    // Acceptance: manifest contains a window with kitty_id >= SYNTHETIC_ID_FLOOR.
    let tabs = &manifest["os_windows"][0]["tabs"];
    assert_eq!(tabs.as_array().map(Vec::len), Some(1), "one tab expected");
    let windows = &tabs[0]["windows"];
    assert_eq!(
        windows.as_array().map(Vec::len),
        Some(1),
        "the empty tab gets exactly one synthetic window: {manifest_text}"
    );
    let kid = windows[0]["kitty_id"].as_u64().expect("kitty_id is u64");
    assert!(
        kid >= SYNTHETIC_ID_FLOOR,
        "synthetic window kitty_id={kid} must be >= SYNTHETIC_ID_FLOOR={SYNTHETIC_ID_FLOOR}"
    );
    assert_eq!(
        windows[0]["program"]["kind"], "bare_shell",
        "synthetic placeholder must be BareShell"
    );

    // Acceptance: rendered conf injects `launch /bin/bash -l` into that tab.
    let conf_text =
        std::fs::read_to_string(sessions.path().join("one_empty.conf")).expect("read conf");
    let launch_count = conf_text.matches("/bin/bash -l").count();
    assert_eq!(
        launch_count, 1,
        "exactly one synthetic launch line expected; conf was:\n{conf_text}"
    );
    assert!(
        conf_text.contains("launch") && conf_text.contains("/bin/bash -l"),
        "synthetic launch line missing from conf:\n{conf_text}"
    );

    // ---------- Scenario 2: one OS window, two empty tabs ----------
    let (sock_b, _guard_b) = spawn_mock_server(make_handler(2)).await;
    std::env::set_var("KITTY_LISTEN_ON", format!("unix:{}", sock_b.display()));

    save(SaveOpts {
        name: "two_empty".into(),
        all: true,
        scrollback: false,
        sessions_dir: sessions.path().to_path_buf(),
        ..Default::default()
    })
    .await
    .expect("save ok");

    let state_dir2 = find_gen_state_dir(sessions.path(), "two_empty");
    let manifest_text2 =
        std::fs::read_to_string(state_dir2.join("manifest.json")).expect("read manifest");
    let manifest2: serde_json::Value =
        serde_json::from_str(&manifest_text2).expect("manifest parses");

    let tabs2 = &manifest2["os_windows"][0]["tabs"];
    assert_eq!(
        tabs2.as_array().map(Vec::len),
        Some(2),
        "two tabs expected: {manifest_text2}"
    );

    // Each tab must have exactly one synthetic window, and the two IDs must
    // differ — the regression this catches is the pre-issue-03 behaviour
    // where multiple empty tabs collapsed onto a single synthetic entry.
    let kid_a = tabs2[0]["windows"][0]["kitty_id"]
        .as_u64()
        .expect("tab 0 kitty_id is u64");
    let kid_b = tabs2[1]["windows"][0]["kitty_id"]
        .as_u64()
        .expect("tab 1 kitty_id is u64");
    assert_eq!(
        tabs2[0]["windows"].as_array().map(Vec::len),
        Some(1),
        "tab 0 has exactly one synthetic window"
    );
    assert_eq!(
        tabs2[1]["windows"].as_array().map(Vec::len),
        Some(1),
        "tab 1 has exactly one synthetic window"
    );
    assert!(
        kid_a >= SYNTHETIC_ID_FLOOR && kid_b >= SYNTHETIC_ID_FLOOR,
        "both synthetic ids must be >= SYNTHETIC_ID_FLOOR: {kid_a}, {kid_b}"
    );
    assert_ne!(
        kid_a, kid_b,
        "two empty tabs must produce two distinct synthetic IDs, not collapse to one"
    );

    // Conf: one launch line per empty tab.
    let conf2 = std::fs::read_to_string(sessions.path().join("two_empty.conf")).expect("read conf");
    let launch_count2 = conf2.matches("/bin/bash -l").count();
    assert_eq!(
        launch_count2, 2,
        "exactly two synthetic launch lines expected; conf was:\n{conf2}"
    );

    std::env::remove_var("KITTY_LISTEN_ON");
}
