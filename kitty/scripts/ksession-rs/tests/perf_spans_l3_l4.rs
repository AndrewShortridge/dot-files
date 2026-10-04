//! Slice 6 acceptance test: L3 (adapter) + L4 (RPC) spans.
//!
//! Runs a save with `KSESSION_TRACE_LEVEL=debug` and asserts the JSONL
//! contains the expected L3 adapter spans and L4 RPC spans. This test
//! binary sets up its own tracer at debug level (separate process from
//! the smoke test which uses info level).

use std::path::PathBuf;
use std::sync::Arc;

use ksession_rs::perf;
use ksession_rs::session::{save, SaveOpts};

use serde_json::{json, Value};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

// --- DCS framing helpers (mirrors src/kitty/rpc.rs pub(crate) helpers) ----

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
            "title": "l3l4-test",
            "layout": "splits",
            "is_active": true,
            "windows": [{
                "id": 7,
                "pid": 42,
                "title": "l3l4-test",
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
async fn debug_level_emits_l3_l4_spans() {
    // Suppress prior-test bleed-through on shared env vars.
    std::env::remove_var("KITTY_WINDOW_ID");
    std::env::remove_var("KSESSION_SCROLLBACK");

    // Trace dir for this run. Set BEFORE perf::maybe_init().
    let trace_dir = tempdir().expect("trace tmp");
    std::env::set_var("KSESSION_TRACE_DIR", trace_dir.path());
    std::env::set_var("KSESSION_TRACE_LEVEL", "debug");
    perf::maybe_init();

    // Mock kitty.
    let (sock, _guard) = spawn_mock_server(make_handler()).await;
    std::env::set_var("KITTY_LISTEN_ON", format!("unix:{}", sock.display()));

    // Run a save.
    let sessions = tempdir().expect("sessions tmp");
    let _ = save(SaveOpts {
        name: "l3l4-test".into(),
        all: true,
        scrollback: false,
        sessions_dir: sessions.path().to_path_buf(),
        ..Default::default()
    })
    .await
    .expect("save ok");

    // Read the JSONL output.
    let pid = std::process::id();
    let expected_jsonl = trace_dir.path().join(format!("rust-{pid}.jsonl"));
    assert!(
        expected_jsonl.exists(),
        "expected {} to exist",
        expected_jsonl.display()
    );

    let body = std::fs::read_to_string(&expected_jsonl).expect("read jsonl");
    assert!(!body.is_empty(), "jsonl must not be empty");

    // Collect all span names from the JSONL.
    let mut span_names: Vec<String> = Vec::new();
    let mut events: Vec<Value> = Vec::new();
    for line in body.lines() {
        if line.trim().is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            if let Some(name) = v["name"].as_str() {
                span_names.push(name.to_string());
            }
            events.push(v);
        }
    }

    // --- L3 assertions: adapter spans ---

    // At least one adapter.detect span must be present (the registry walks
    // all adapters for the one window).
    let detect_count = span_names.iter().filter(|n| *n == "adapter.detect").count();
    assert!(
        detect_count >= 1,
        "expected at least 1 adapter.detect span, got {detect_count}"
    );

    // Each adapter.detect span must carry an `adapter` arg naming the adapter.
    for ev in &events {
        if ev["name"] == "adapter.detect" {
            let adapter_arg = ev["args"]["adapter"].as_str().unwrap_or("");
            assert!(
                !adapter_arg.is_empty(),
                "adapter.detect must carry an `adapter` arg, got: {ev}"
            );
        }
    }

    // At least one adapter.capture span must be present (the matching
    // adapter captures the window).
    let capture_count = span_names
        .iter()
        .filter(|n| *n == "adapter.capture")
        .count();
    assert!(
        capture_count >= 1,
        "expected at least 1 adapter.capture span, got {capture_count}"
    );

    // --- L4 assertions: RPC spans ---

    // kitty.rpc.ls must appear at least once.
    let ls_count = span_names.iter().filter(|n| *n == "kitty.rpc.ls").count();
    assert!(
        ls_count >= 1,
        "expected at least 1 kitty.rpc.ls span, got {ls_count}"
    );

    // kitty.rpc.ls must carry bytes_out and bytes_in.
    for ev in &events {
        if ev["name"] == "kitty.rpc.ls" {
            assert!(
                ev["args"]["bytes_out"].is_string(),
                "kitty.rpc.ls must carry bytes_out arg"
            );
            assert!(
                ev["args"]["bytes_in"].is_string(),
                "kitty.rpc.ls must carry bytes_in arg"
            );
        }
    }

    // kitty.rpc.set_user_vars must appear at least once (UUID tagging).
    let suv_count = span_names
        .iter()
        .filter(|n| *n == "kitty.rpc.set_user_vars")
        .count();
    assert!(
        suv_count >= 1,
        "expected at least 1 kitty.rpc.set_user_vars span, got {suv_count}"
    );

    // fsx.commit_session must appear exactly once.
    let fsx_count = span_names
        .iter()
        .filter(|n| *n == "fsx.commit_session")
        .count();
    assert!(
        fsx_count == 1,
        "expected exactly 1 fsx.commit_session span, got {fsx_count}"
    );

    // --- L0-L2 spans must also be present (debug includes info) ---
    assert!(
        span_names.contains(&"save.total".to_string()),
        "save.total must be present at debug level"
    );
    assert!(
        span_names.contains(&"save.capture".to_string()),
        "save.capture must be present at debug level"
    );
    assert!(
        span_names.contains(&"save.capture.window".to_string()),
        "save.capture.window must be present at debug level"
    );

    // --- Slice 7: L5 spans must NOT appear at debug level ---
    let l5_span_names = [
        "kitty.rpc.write_req",
        "kitty.rpc.read_resp",
        "kitty.rpc.decode",
        "nvim.rpc.write_msgpack",
        "nvim.rpc.read_msgpack",
        "nvim.rpc.decode_msgpack",
        "tmux.subprocess.spawn",
        "tmux.subprocess.wait",
        "tmux.subprocess.decode_stdout",
    ];
    for l5_name in &l5_span_names {
        assert!(
            !span_names.contains(&l5_name.to_string()),
            "L5 span {l5_name} must NOT appear at debug level, but it was found"
        );
    }

    // Tidy shared env.
    std::env::remove_var("KSESSION_TRACE_DIR");
    std::env::remove_var("KSESSION_TRACE_LEVEL");
    std::env::remove_var("KITTY_LISTEN_ON");
}
