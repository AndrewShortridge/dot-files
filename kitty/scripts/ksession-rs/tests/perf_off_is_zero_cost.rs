//! PRD-0 / Slice-1 "off is zero-cost" assertion.
//!
//! When `KSESSION_TRACE_DIR` is unset, `perf::maybe_init()` leaves the
//! `Tracer` `OnceLock` empty, every `span!` call site short-circuits to
//! `None`, no JSONL file is created anywhere, and the save is
//! byte-identical to a run without the perf module wired in.
//!
//! Each integration test compiles to its own binary, so the global
//! `OnceLock` is fresh for this run — there is no risk of a sibling test
//! file leaving a Tracer installed.

use std::path::PathBuf;
use std::sync::Arc;

use ksession_rs::perf;
use ksession_rs::session::{save, SaveOpts};

use serde_json::{json, Value};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

// --- DCS framing (mirrors src/kitty/rpc.rs pub(crate) helpers) -----------

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
            });
        }
    });
    (sock, dir)
}

fn one_window_ls_json() -> Value {
    json!([{
        "id": 1,
        "is_focused": true,
        "is_active": true,
        "tabs": [{
            "id": 1,
            "title": "perf-off",
            "layout": "splits",
            "is_active": true,
            "windows": [{
                "id": 7,
                "pid": 42,
                "title": "perf-off",
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

fn make_handler() -> impl Fn(Value) -> Option<Value> + Send + Sync + 'static {
    let ls = one_window_ls_json();
    move |req| match req["cmd"].as_str() {
        Some("ls") => {
            if req["payload"]["output_format"] == "session" {
                Some(json!({ "ok": true, "data": ONE_WINDOW_SKELETON }))
            } else {
                Some(json!({
                    "ok": true,
                    "data": serde_json::to_string(&ls).expect("ser ls")
                }))
            }
        }
        Some("get_text") => Some(json!({ "ok": true, "data": "" })),
        Some("set_user_vars") => None,
        _ => Some(json!({ "ok": true, "data": "" })),
    }
}

#[tokio::test]
async fn save_with_trace_dir_unset_writes_no_jsonl_anywhere() {
    // Force the env var off for this run. Other test binaries don't
    // share state, but a prior test invocation in the same shell can
    // leak the var.
    std::env::remove_var("KSESSION_TRACE_DIR");
    std::env::remove_var("KSESSION_TRACE_LEVEL");
    std::env::remove_var("KITTY_WINDOW_ID");
    std::env::remove_var("KSESSION_SCROLLBACK");

    // Steer `~/.cache/ksession/traces/` and the sessions dir into a
    // tempdir so the assertion is robust against a developer who
    // happens to have a real trace dir on disk.
    let home = tempdir().expect("home tmp");
    let prev_home = std::env::var_os("HOME");
    std::env::set_var("HOME", home.path());

    // Calling `maybe_init` is the production path. With KSESSION_TRACE_DIR
    // unset it must early-return and leave the OnceLock empty.
    perf::maybe_init();
    assert!(
        perf::Tracer::current().is_none(),
        "tracer must NOT be installed when KSESSION_TRACE_DIR is unset"
    );

    // Drive a real save through mock kitty.
    let (sock, _guard) = spawn_mock_server(make_handler()).await;
    std::env::set_var("KITTY_LISTEN_ON", format!("unix:{}", sock.display()));

    let sessions = tempdir().expect("sessions tmp");
    let _ = save(SaveOpts {
        name: "perf-off".into(),
        all: true,
        scrollback: false,
        sessions_dir: sessions.path().to_path_buf(),
        ..Default::default()
    })
    .await
    .expect("save ok");

    // Assert: no JSONL anywhere under the simulated HOME.
    let traces_dir = home.path().join(".cache").join("ksession").join("traces");
    assert!(
        !traces_dir.exists() || count_jsonl(&traces_dir) == 0,
        "no jsonl files should be created under {} when trace dir is unset",
        traces_dir.display()
    );

    // The tracer remains uninstalled.
    assert!(
        perf::Tracer::current().is_none(),
        "tracer must remain uninstalled after a save with trace dir unset"
    );

    // Restore HOME for any sibling tests in this binary.
    match prev_home {
        Some(v) => std::env::set_var("HOME", v),
        None => std::env::remove_var("HOME"),
    }
    std::env::remove_var("KITTY_LISTEN_ON");
}

/// Recursively count `*.jsonl` files under `root`. Returns 0 if `root`
/// doesn't exist.
fn count_jsonl(root: &std::path::Path) -> usize {
    let mut count = 0usize;
    let Ok(entries) = std::fs::read_dir(root) else {
        return 0;
    };
    for ent in entries.flatten() {
        let p = ent.path();
        if p.is_dir() {
            count += count_jsonl(&p);
        } else if p.extension().and_then(|s| s.to_str()) == Some("jsonl") {
            count += 1;
        }
    }
    count
}
