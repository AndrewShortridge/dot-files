//! Integration tests for `session::save` orchestration.
//!
//! Drives the full save flow against a DCS mock kitty server (mirroring the
//! pattern from `tests/end_to_end_save.rs`) and asserts:
//!
//! 1. A minimal save produces both `<name>.conf` and
//!    `<name>.gen-<gen_us>.state/manifest.json` (gen-stamped per §B.4).
//! 2. Re-saving leaves multiple `<name>.gen-*.state/` dirs on disk — the
//!    orphan sweep is age-gated (SWEEP_MIN_AGE=60s) so the older one is NOT
//!    swept during a single test run; both must coexist.
//! 3. When `get_text` returns empty, no scrollback file is written.
//!
//! `save()` calls `KittyTransport::discover_and_ls()` internally; we steer
//! discovery onto a mock via `$KITTY_LISTEN_ON`. Because that env var is
//! process-global, the three scenarios are serialised behind a single
//! `#[tokio::test]` to avoid trampling each other under the default
//! multi-threaded test runner.

use std::path::PathBuf;
use std::sync::Arc;

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

/// Spawn a Unix-socket mock kitty server. Returns the socket path and a
/// guard tempdir that must outlive the test.
async fn spawn_mock_server<F>(handler: F) -> (PathBuf, tempfile::TempDir)
where
    F: Fn(Value) -> Option<Value> + Send + Sync + 'static,
{
    let dir = tempdir().expect("tempdir");
    let sock = dir.path().join("rpc.sock");
    let listener = UnixListener::bind(&sock).expect("bind");
    let h = Arc::new(handler);
    tokio::spawn(async move {
        // Accept multiple connections — each save() call from the test
        // body opens its own KittyRpc.
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

fn one_window_ls_json() -> Value {
    json!([{
        "id": 1,
        "is_focused": true,
        "is_active": true,
        "tabs": [{
            "id": 1,
            "title": "demo",
            "layout": "splits",
            "is_active": true,
            "windows": [{
                "id": 7,
                "pid": 42,
                "title": "demo",
                "is_active": true,
                "foreground_processes": [
                    { "pid": 42, "cmdline": ["bash"] }
                ],
                "env": {},
                "user_vars": {}
            }]
        }]
    }])
}

const ONE_WINDOW_SKELETON: &str = "new_tab\n\
layout splits\n\
launch 'kitty-unserialize-data={\"id\": 7}' --var=ksession_idx=0 --var=ksession_win=7 /bin/bash -l\n\
focus\n\
focus_tab 1\n";

fn make_handler(
    get_text_response: &'static str,
) -> impl Fn(Value) -> Option<Value> + Send + Sync + 'static {
    let ls = one_window_ls_json();
    move |req| match req["cmd"].as_str() {
        Some("ls") => {
            if req["payload"]["output_format"] == "session" {
                Some(json!({ "ok": true, "data": ONE_WINDOW_SKELETON }))
            } else {
                // `ls` returns a JSON-encoded JSON string (double-decode).
                Some(json!({
                    "ok": true,
                    "data": serde_json::to_string(&ls).expect("ser ls")
                }))
            }
        }
        Some("get_text") => Some(json!({ "ok": true, "data": get_text_response })),
        Some("set_user_vars") => None,
        _ => Some(json!({ "ok": true, "data": "" })),
    }
}

/// Find every `<name>.gen-<gen_us>(_<pid>)?.state/` directory in `sessions_dir`.
/// Sorted by `gen_us` ascending so callers can reason about ordering.
fn find_gen_state_dirs(sessions_dir: &std::path::Path, name: &str) -> Vec<PathBuf> {
    let prefix = format!("{name}.gen-");
    let mut hits: Vec<(u64, PathBuf)> = Vec::new();
    for ent in std::fs::read_dir(sessions_dir).expect("read sessions_dir") {
        let ent = match ent {
            Ok(e) => e,
            Err(_) => continue,
        };
        let fname = ent.file_name();
        let s = fname.to_string_lossy();
        if !s.starts_with(&prefix) || !s.ends_with(".state") {
            continue;
        }
        // Extract gen_us between `<prefix>` and `_` or `.state`.
        let rest = &s[prefix.len()..s.len() - ".state".len()];
        let gen_str = match rest.find('_') {
            Some(i) => &rest[..i],
            None => rest,
        };
        let gen: u64 = match gen_str.parse() {
            Ok(g) => g,
            Err(_) => continue,
        };
        let path = ent.path();
        if !path.is_dir() {
            continue;
        }
        hits.push((gen, path));
    }
    hits.sort_by_key(|(g, _)| *g);
    hits.into_iter().map(|(_, p)| p).collect()
}

// --- the test --------------------------------------------------------------

#[tokio::test]
async fn save_orchestration_end_to_end() {
    // Suppress prior test bleed-through. These env vars affect resolve_targets
    // and the scrollback gate; both must be deterministic.
    std::env::remove_var("KITTY_WINDOW_ID");
    std::env::remove_var("KSESSION_SCROLLBACK");

    // -------- Scenario 1: basic save produces conf + manifest. --------
    let (sock_a, _guard_a) = spawn_mock_server(make_handler("scrollback-text\n")).await;
    std::env::set_var("KITTY_LISTEN_ON", format!("unix:{}", sock_a.display()));

    let sessions = tempdir().expect("sessions tmp");
    let _ = save(SaveOpts {
        name: "demo".into(),
        all: true,
        scrollback: true,
        sessions_dir: sessions.path().to_path_buf(),
        ..Default::default()
    })
    .await
    .expect("save ok");

    let conf = sessions.path().join("demo.conf");
    assert!(conf.exists(), "conf must exist at {}", conf.display());

    // The new §B.4 layout puts the state dir at <name>.gen-<gen_us>.state/.
    let demo_dirs = find_gen_state_dirs(sessions.path(), "demo");
    assert_eq!(
        demo_dirs.len(),
        1,
        "expected exactly one demo.gen-*.state dir, found: {demo_dirs:?}"
    );
    let demo_state = &demo_dirs[0];
    let manifest = demo_state.join("manifest.json");
    assert!(
        manifest.exists(),
        "manifest must exist at {}",
        manifest.display()
    );

    let conf_text = std::fs::read_to_string(&conf).expect("read conf");
    assert!(
        conf_text.contains("--var=ksession_id="),
        "UUID tagging must be reflected in the conf:\n{conf_text}",
    );

    let manifest_text = std::fs::read_to_string(&manifest).expect("read manifest");
    let parsed: serde_json::Value = serde_json::from_str(&manifest_text).expect("manifest parses");
    assert_eq!(parsed["name"], "demo");
    assert_eq!(parsed["schema"], 1);
    assert!(parsed["os_windows"].is_array());

    // Scrollback returned non-empty text → file must exist.
    let scrollback_file = demo_state.join("scrollback").join("win-7.ansi");
    assert!(
        scrollback_file.exists(),
        "scrollback file should be written when get_text returns non-empty text",
    );

    // -------- Scenario 2: re-saving leaves the prior gen-stamped dir intact --------
    // Two back-to-back saves produce two `.gen-*.state/` dirs. The orphan
    // sweep is age-gated by SWEEP_MIN_AGE=60s, so within a single test run
    // the older one MUST remain on disk; the conf points at the newer one.
    let _ = save(SaveOpts {
        name: "demo2".into(),
        all: true,
        scrollback: true,
        sessions_dir: sessions.path().to_path_buf(),
        ..Default::default()
    })
    .await
    .expect("save ok");

    let first = find_gen_state_dirs(sessions.path(), "demo2");
    assert_eq!(first.len(), 1, "first save should land one gen-stamped dir");
    let first_state = first[0].clone();
    // Drop a sentinel so we can confirm the first dir was NOT removed.
    let sentinel = first_state.join("SENTINEL");
    std::fs::write(&sentinel, b"keep me").expect("write sentinel");

    let _ = save(SaveOpts {
        name: "demo2".into(),
        all: true,
        scrollback: true,
        sessions_dir: sessions.path().to_path_buf(),
        ..Default::default()
    })
    .await
    .expect("second save ok");

    let after = find_gen_state_dirs(sessions.path(), "demo2");
    assert_eq!(
        after.len(),
        2,
        "both gen-stamped dirs must coexist; the orphan sweep is age-gated. \
         found: {after:?}",
    );
    assert!(
        sentinel.exists(),
        "first save's state dir must NOT be removed by the second save",
    );

    let manifest2 = after[1].join("manifest.json");
    assert!(manifest2.exists(), "newer manifest must exist");

    // No legacy `.state.tmp.<pid>` / `.state.old.<pid>` / `.conf.tmp.<pid>`
    // debris should remain after a successful save.
    let leftovers: Vec<_> = std::fs::read_dir(sessions.path())
        .expect("read sessions dir")
        .filter_map(|e| e.ok())
        .filter(|e| {
            let n = e.file_name();
            let s = n.to_string_lossy();
            s.starts_with("demo2.state.old.")
                || s.starts_with("demo2.state.tmp.")
                || s.starts_with("demo2.conf.tmp.")
        })
        .collect();
    assert!(
        leftovers.is_empty(),
        "no .old/.tmp debris should remain: {:?}",
        leftovers.iter().map(|e| e.file_name()).collect::<Vec<_>>(),
    );

    // -------- Scenario 3: empty scrollback writes no file. --------
    let (sock_c, _guard_c) = spawn_mock_server(make_handler("")).await;
    std::env::set_var("KITTY_LISTEN_ON", format!("unix:{}", sock_c.display()));

    let _ = save(SaveOpts {
        name: "demo3".into(),
        all: true,
        scrollback: true,
        sessions_dir: sessions.path().to_path_buf(),
        ..Default::default()
    })
    .await
    .expect("save ok");

    let demo3 = find_gen_state_dirs(sessions.path(), "demo3");
    assert_eq!(demo3.len(), 1, "demo3 should land one gen-stamped dir");
    let scrollback_dir = demo3[0].join("scrollback");
    if scrollback_dir.exists() {
        let entries: Vec<_> = std::fs::read_dir(&scrollback_dir)
            .expect("read scrollback dir")
            .filter_map(|e| e.ok())
            .collect();
        assert!(
            entries.is_empty(),
            "scrollback dir must be empty when get_text returns '': {:?}",
            entries.iter().map(|e| e.file_name()).collect::<Vec<_>>(),
        );
    }

    std::env::remove_var("KITTY_LISTEN_ON");
}
