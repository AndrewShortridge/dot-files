//! Integration test: trace_span wraps restore phases (PRD-0 slice 10).
//!
//! Runs a fixture restore with `KSESSION_TRACE_DIR` set and asserts the
//! resulting trace dir contains a `nvim-<pid>.jsonl` with at least one
//! `nvim.restore.*` event.
//!
//! Skips cleanly when `nvim` is not on PATH.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use nvim_rs::{compat::tokio::Compat, create::tokio::new_path, Handler};
use tempfile::tempdir;
use tokio::io::WriteHalf;
use tokio::net::UnixStream;

#[derive(Clone)]
struct NopHandler;

#[async_trait::async_trait]
impl Handler for NopHandler {
    type Writer = Compat<WriteHalf<UnixStream>>;
}

type Nvim = nvim_rs::Neovim<Compat<WriteHalf<UnixStream>>>;
type IoHandle = tokio::task::JoinHandle<Result<(), Box<nvim_rs::error::LoopError>>>;

fn nvim_or_skip() -> bool {
    std::process::Command::new("nvim")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

async fn wait_for_socket(sock: &Path) {
    for _ in 0..80 {
        if sock.exists() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("nvim socket never appeared at {sock:?}");
}

async fn raw_connect(sock: &Path) -> (Nvim, IoHandle) {
    let (nvim, io_handle) = new_path(sock, NopHandler).await.expect("nvim-rs new_path");
    (nvim, io_handle)
}

fn rtp_cmd() -> String {
    let assets_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets");
    format!("set runtimepath^={}", assets_dir.display())
}

async fn spawn_nvim_with_trace(sock: &Path, trace_dir: &Path) -> tokio::process::Child {
    let child = tokio::process::Command::new("nvim")
        .args(["--headless", "--clean", "-u", "NORC"])
        .args(["-c", "set noswapfile"])
        .args(["-c", &rtp_cmd()])
        .args(["--listen"])
        .arg(sock)
        .env("KSESSION_TRACE_DIR", trace_dir)
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nvim");
    wait_for_socket(sock).await;
    child
}

fn find_jsonl_files(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("nvim-") && n.ends_with(".jsonl"))
                .unwrap_or(false)
        })
        .collect()
}

// -------------------------------------------------------------------------
// TEST: restore with tracing emits nvim.restore.* phase events
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn restore_emits_phase_trace_events() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let trace_dir = tmp.path().join("traces");
    std::fs::create_dir_all(&trace_dir).expect("create trace dir");

    // Create a valid manifest + dump file for the restore to process.
    let manifest_dir = tmp.path().join("session");
    std::fs::create_dir_all(&manifest_dir).expect("create session dir");

    let dump_path = manifest_dir.join("buf.txt");
    std::fs::write(&dump_path, "traced-content\n").expect("write dump");

    let manifest = serde_json::json!({
        "schema": 1u32,
        "buffers": [{
            "buf_id": 1,
            "name": "",
            "modified": true,
            "filetype": "text",
            "dump_path": "buf.txt",
            "truncated": false,
            "byte_count": 15u64,
        }],
    });
    let manifest_path = manifest_dir.join("win-1.json");
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).expect("json"),
    )
    .expect("write manifest");

    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim_with_trace(&sock, &trace_dir).await;

    let (nvim, _io) = raw_connect(&sock).await;

    // Drive the loader — this exercises the full restore path with tracing.
    let load_cmd = format!(
        "lua require('ksession_restore').load({:?})",
        manifest_path.to_string_lossy()
    );
    nvim.command(&load_cmd).await.expect("loader call");

    tokio::time::sleep(Duration::from_millis(300)).await;

    // Assert JSONL file exists.
    let jsonl_files = find_jsonl_files(&trace_dir);
    assert!(
        !jsonl_files.is_empty(),
        "expected nvim-<pid>.jsonl in {trace_dir:?} after restore, found none"
    );

    // Read all events and check for expected phase span names.
    let content = std::fs::read_to_string(&jsonl_files[0]).expect("read jsonl");
    let events: Vec<serde_json::Value> = content
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| serde_json::from_str(l).expect("parse JSONL line"))
        .collect();

    // We expect at least these phase spans:
    let expected_phases = [
        "nvim.restore.load",
        "nvim.restore.decode_manifest",
        "nvim.restore.load_modified_buffers",
        "nvim.restore.mark_loaded",
    ];

    let event_names: Vec<&str> = events.iter().filter_map(|e| e["name"].as_str()).collect();

    for phase in &expected_phases {
        assert!(
            event_names.contains(phase),
            "expected phase span '{phase}' in trace events, found: {event_names:?}"
        );
    }

    // All events should be valid chrome-trace X events.
    for (i, event) in events.iter().enumerate() {
        assert_eq!(
            event["ph"].as_str(),
            Some("X"),
            "event {i} should have ph='X'"
        );
        assert!(
            event["ts"].as_i64().is_some() || event["ts"].as_f64().is_some(),
            "event {i} should have numeric ts"
        );
        assert!(
            event["dur"].as_i64().is_some() || event["dur"].as_f64().is_some(),
            "event {i} should have numeric dur"
        );
        assert!(
            event["pid"].as_i64().is_some() || event["pid"].as_f64().is_some(),
            "event {i} should have numeric pid"
        );
    }

    drop(nvim);
    let _ = child.kill().await;
}

// -------------------------------------------------------------------------
// TEST: restore without tracing does not create any JSONL files
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn restore_no_trace_when_env_unset() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let trace_dir = tmp.path().join("traces");
    std::fs::create_dir_all(&trace_dir).expect("create trace dir");

    let manifest_dir = tmp.path().join("session");
    std::fs::create_dir_all(&manifest_dir).expect("create session dir");

    let dump_path = manifest_dir.join("buf.txt");
    std::fs::write(&dump_path, "no-trace-content\n").expect("write dump");

    let manifest = serde_json::json!({
        "schema": 1u32,
        "buffers": [{
            "buf_id": 1,
            "name": "",
            "modified": true,
            "filetype": "",
            "dump_path": "buf.txt",
            "truncated": false,
            "byte_count": 17u64,
        }],
    });
    let manifest_path = manifest_dir.join("win-1.json");
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).expect("json"),
    )
    .expect("write manifest");

    let sock = tmp.path().join("nv.sock");
    // Spawn WITHOUT trace dir.
    let mut child = tokio::process::Command::new("nvim")
        .args(["--headless", "--clean", "-u", "NORC"])
        .args(["-c", "set noswapfile"])
        .args(["-c", &rtp_cmd()])
        .args(["--listen"])
        .arg(&sock)
        .env_remove("KSESSION_TRACE_DIR")
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nvim");
    wait_for_socket(&sock).await;

    let (nvim, _io) = raw_connect(&sock).await;

    let load_cmd = format!(
        "lua require('ksession_restore').load({:?})",
        manifest_path.to_string_lossy()
    );
    nvim.command(&load_cmd).await.expect("loader call");

    tokio::time::sleep(Duration::from_millis(200)).await;

    // No JSONL files should exist.
    let jsonl_files = find_jsonl_files(&trace_dir);
    assert!(
        jsonl_files.is_empty(),
        "expected no nvim-*.jsonl when KSESSION_TRACE_DIR is unset, found: {jsonl_files:?}"
    );

    // Verify the restore itself still worked.
    let bufs = nvim.list_bufs().await.expect("list_bufs");
    let expected: Vec<String> = vec!["no-trace-content".to_string()];
    let mut found = false;
    for buf in &bufs {
        let lines = buf.get_lines(0, -1, false).await.expect("get_lines");
        if lines == expected {
            found = true;
            break;
        }
    }
    assert!(found, "restore should still work when tracing is off");

    drop(nvim);
    let _ = child.kill().await;
}
