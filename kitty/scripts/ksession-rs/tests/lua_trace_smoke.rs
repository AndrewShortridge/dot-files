//! Smoke tests for the `trace_span` helper in `ksession_restore.lua`.
//!
//! These tests verify the cross-process tracing contract (PRD-0 slice 10):
//!
//!   1. With `KSESSION_TRACE_DIR` set, calling `trace_span("test.span",
//!      {foo="bar"}, function() end)` produces a `nvim-<pid>.jsonl` file
//!      containing one valid chrome-trace JSON line with the expected name
//!      and args.
//!   2. With `KSESSION_TRACE_DIR` unset, no file is created and the inner
//!      function runs transparently.
//!   3. With an unwritable trace dir, the restore still succeeds — errors
//!      during emit are silently swallowed.
//!
//! All tests skip cleanly when `nvim` is not on PATH.

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

/// Build the `set runtimepath^=...` command that makes
/// `require('ksession_restore')` resolvable.
fn rtp_cmd() -> String {
    let assets_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets");
    format!("set runtimepath^={}", assets_dir.display())
}

/// Spawn headless nvim with KSESSION_TRACE_DIR set (or cleared) and the
/// loader on rtp.
async fn spawn_nvim_with_trace(sock: &Path, trace_dir: Option<&Path>) -> tokio::process::Child {
    let mut cmd = tokio::process::Command::new("nvim");
    cmd.args(["--headless", "--clean", "-u", "NORC"])
        .args(["-c", "set noswapfile"])
        .args(["-c", &rtp_cmd()])
        .args(["--listen"])
        .arg(sock)
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    if let Some(dir) = trace_dir {
        cmd.env("KSESSION_TRACE_DIR", dir);
    } else {
        cmd.env_remove("KSESSION_TRACE_DIR");
    }

    let child = cmd.spawn().expect("spawn nvim");
    wait_for_socket(sock).await;
    child
}

/// Find `nvim-*.jsonl` files in a directory.
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
// TEST 1: trace_span emits JSONL when KSESSION_TRACE_DIR is set
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn trace_span_emits_jsonl_when_trace_dir_set() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let trace_dir = tmp.path().join("traces");
    std::fs::create_dir_all(&trace_dir).expect("create trace dir");

    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim_with_trace(&sock, Some(&trace_dir)).await;

    let (nvim, _io) = raw_connect(&sock).await;

    // Call trace_span directly via lua.
    let lua_cmd =
        r#"lua require('ksession_restore').trace_span('test.span', {foo='bar'}, function() end)"#;
    nvim.command(lua_cmd).await.expect("trace_span call");

    // Small settle window for I/O flush.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Assert JSONL file exists.
    let jsonl_files = find_jsonl_files(&trace_dir);
    assert!(
        !jsonl_files.is_empty(),
        "expected nvim-<pid>.jsonl in {trace_dir:?}, found none"
    );

    // Read and validate the JSONL content.
    let content = std::fs::read_to_string(&jsonl_files[0]).expect("read jsonl");
    let lines: Vec<&str> = content.lines().collect();
    assert!(
        !lines.is_empty(),
        "JSONL file is empty: {}",
        jsonl_files[0].display()
    );

    // Parse the first line as JSON and validate fields.
    let event: serde_json::Value =
        serde_json::from_str(lines[0]).expect("parse JSONL line as JSON");
    assert_eq!(
        event["name"].as_str(),
        Some("test.span"),
        "expected name='test.span', got {:?}",
        event["name"]
    );
    assert_eq!(
        event["ph"].as_str(),
        Some("X"),
        "expected ph='X', got {:?}",
        event["ph"]
    );
    assert!(
        event["ts"].as_i64().is_some() || event["ts"].as_f64().is_some(),
        "ts should be numeric"
    );
    assert!(
        event["dur"].as_i64().is_some() || event["dur"].as_f64().is_some(),
        "dur should be numeric"
    );
    assert!(
        event["pid"].as_i64().is_some() || event["pid"].as_f64().is_some(),
        "pid should be numeric"
    );
    assert_eq!(
        event["args"]["foo"].as_str(),
        Some("bar"),
        "expected args.foo='bar', got {:?}",
        event["args"]["foo"]
    );

    drop(nvim);
    let _ = child.kill().await;
}

// -------------------------------------------------------------------------
// TEST 2: trace_span is a no-op when KSESSION_TRACE_DIR is unset
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn trace_span_noop_when_trace_dir_unset() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let trace_dir = tmp.path().join("traces");
    std::fs::create_dir_all(&trace_dir).expect("create trace dir");

    let sock = tmp.path().join("nv.sock");
    // Launch WITHOUT KSESSION_TRACE_DIR.
    let mut child = spawn_nvim_with_trace(&sock, None).await;

    let (nvim, _io) = raw_connect(&sock).await;

    // Call trace_span — should run fn transparently, no file written.
    let lua_cmd =
        r#"lua require('ksession_restore').trace_span('test.span', {foo='bar'}, function() end)"#;
    nvim.command(lua_cmd).await.expect("trace_span call");

    tokio::time::sleep(Duration::from_millis(200)).await;

    // Assert NO JSONL files created.
    let jsonl_files = find_jsonl_files(&trace_dir);
    assert!(
        jsonl_files.is_empty(),
        "expected no nvim-*.jsonl files when KSESSION_TRACE_DIR is unset, found: {jsonl_files:?}"
    );

    drop(nvim);
    let _ = child.kill().await;
}

// -------------------------------------------------------------------------
// TEST 3: trace_span runs fn and returns its value even when tracing
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn trace_span_returns_inner_value() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let trace_dir = tmp.path().join("traces");
    std::fs::create_dir_all(&trace_dir).expect("create trace dir");

    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim_with_trace(&sock, Some(&trace_dir)).await;

    let (nvim, _io) = raw_connect(&sock).await;

    // trace_span should return fn()'s return value.
    let lua_cmd = r#"lua vim.g._test_result = require('ksession_restore').trace_span('test.return', {}, function() return 42 end)"#;
    nvim.command(lua_cmd).await.expect("trace_span call");

    tokio::time::sleep(Duration::from_millis(100)).await;

    let result = nvim
        .command_output("lua print(vim.g._test_result)")
        .await
        .expect("get result");
    assert_eq!(
        result.trim(),
        "42",
        "trace_span must propagate inner fn return value"
    );

    drop(nvim);
    let _ = child.kill().await;
}

// -------------------------------------------------------------------------
// TEST 4: unwritable trace dir does not crash — errors silently swallowed
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn trace_span_survives_unwritable_trace_dir() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let trace_dir = tmp.path().join("readonly-traces");
    std::fs::create_dir_all(&trace_dir).expect("create trace dir");

    // Make the trace dir read-only so file writes fail.
    let mut perms = std::fs::metadata(&trace_dir)
        .expect("metadata")
        .permissions();
    perms.set_readonly(true);
    std::fs::set_permissions(&trace_dir, perms).expect("chmod");

    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim_with_trace(&sock, Some(&trace_dir)).await;

    let (nvim, _io) = raw_connect(&sock).await;

    // trace_span should run fn() successfully even though emit fails.
    let lua_cmd = r#"lua vim.g._test_ok = require('ksession_restore').trace_span('test.fail', {}, function() return 'survived' end)"#;
    nvim.command(lua_cmd)
        .await
        .expect("trace_span call on unwritable dir");

    tokio::time::sleep(Duration::from_millis(100)).await;

    // Verify the inner function ran and returned.
    let result = nvim
        .command_output("lua print(vim.g._test_ok)")
        .await
        .expect("get result");
    assert_eq!(
        result.trim(),
        "survived",
        "trace_span must not crash even when trace dir is unwritable"
    );

    // Restore permissions so tempdir cleanup works.
    let mut perms = std::fs::metadata(&trace_dir)
        .expect("metadata")
        .permissions();
    #[allow(clippy::permissions_set_readonly_false)]
    perms.set_readonly(false);
    std::fs::set_permissions(&trace_dir, perms).expect("restore perms");

    drop(nvim);
    let _ = child.kill().await;
}
