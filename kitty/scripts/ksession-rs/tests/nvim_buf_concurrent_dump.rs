//! PRD-0008 Slice 2: correctness test for concurrent buffer dumps.
//!
//! Spawns a headless nvim with 4 modified buffers of different sizes,
//! runs dump_modified_buffers under the default fan-out, and asserts
//! all BufferDump results are correct regardless of completion order.
//! Also verifies that FAN_OUT=1 (serial fallback) produces identical
//! results.
//!
//! Skipped (with an eprintln) when `nvim` isn't on PATH.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use ksession_rs::nvim_rpc::NvimConn;
use nvim_rs::{compat::tokio::Compat, create::tokio::new_path, Handler};
use tempfile::tempdir;
use tokio::io::WriteHalf;
use tokio::net::UnixStream;

/// nvim-rs requires a notification handler even when we never receive any.
/// Mirrors `NopHandler` in `src/nvim_rpc/conn.rs`.
#[derive(Clone)]
struct NopHandler;

#[async_trait::async_trait]
impl Handler for NopHandler {
    type Writer = Compat<WriteHalf<UnixStream>>;
}

fn nvim_or_skip() -> bool {
    std::process::Command::new("nvim")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

async fn spawn_nvim(sock: &Path) -> tokio::process::Child {
    let child = tokio::process::Command::new("nvim")
        .args(["--headless", "--clean", "-u", "NORC", "--listen"])
        .arg(sock)
        .args(["-c", "set noswapfile"])
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nvim");
    for _ in 0..80 {
        if sock.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(sock.exists(), "nvim socket never appeared at {sock:?}");
    child
}

#[tokio::test(flavor = "multi_thread")]
async fn concurrent_dump_four_buffers_correct() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().unwrap();
    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim(&sock).await;

    // Setup via raw nvim-rs connection (NvimConn::nvim is pub(crate), so
    // integration tests use a parallel raw connection for setup commands).
    let (nvim, _io) = new_path(&sock, NopHandler).await.unwrap();

    // Buffer 1 (initial scratch buffer): 3 lines
    nvim.command("call setline(1, ['alpha', 'beta', 'gamma'])")
        .await
        .unwrap();
    nvim.command("set modified").await.unwrap();

    // Buffer 2: 1 line
    nvim.command("enew").await.unwrap();
    nvim.command("call setline(1, ['single line'])")
        .await
        .unwrap();
    nvim.command("set modified").await.unwrap();

    // Buffer 3: 5 lines
    nvim.command("enew").await.unwrap();
    nvim.command("call setline(1, ['one', 'two', 'three', 'four', 'five'])")
        .await
        .unwrap();
    nvim.command("set modified").await.unwrap();

    // Buffer 4: empty but modified
    nvim.command("enew").await.unwrap();
    nvim.command("set modified").await.unwrap();

    // Dump via NvimConn (the public API under test)
    let conn = NvimConn::connect(&sock).await.unwrap();
    let dumps_dir = tmp.path().join("dumps");
    let dumps = conn.dump_modified_buffers(&dumps_dir).await.unwrap();

    // Should have 4 modified buffers
    assert_eq!(
        dumps.len(),
        4,
        "expected 4 dumps, got {}: {:?}",
        dumps.len(),
        dumps
    );

    // All should be marked modified
    for d in &dumps {
        assert!(d.modified, "expected modified=true for buf {}", d.buf_id);
    }

    // All dump files should exist on disk
    let manifest_dir = dumps_dir.parent().unwrap();
    for d in &dumps {
        assert!(
            d.dump_path.is_relative(),
            "dump_path must be relative: {:?}",
            d.dump_path
        );
        let abs = manifest_dir.join(&d.dump_path);
        assert!(abs.exists(), "dump file missing at {:?}", abs);
    }

    // Verify content of all buffers. We can't predict buf_ids or
    // completion order, so collect and sort by content.
    let mut contents: Vec<String> = dumps
        .iter()
        .map(|d| {
            let abs = manifest_dir.join(&d.dump_path);
            std::fs::read_to_string(&abs).unwrap()
        })
        .collect();
    contents.sort();

    let mut expected = vec![
        "alpha\nbeta\ngamma\n".to_string(),
        "single line\n".to_string(),
        "one\ntwo\nthree\nfour\nfive\n".to_string(),
        "\n".to_string(), // empty but modified buffer has one empty default line
    ];
    expected.sort();

    assert_eq!(contents, expected, "buffer contents don't match");

    // ---- Verify FAN_OUT=1 (serial fallback) produces identical results ----

    // SAFETY: this test is single-threaded within this test function body.
    // The env var is set/unset around a single await point with no other
    // concurrent test reading it.
    unsafe {
        std::env::set_var("KSESSION_NVIM_BUF_FAN_OUT", "1");
    }
    let dumps_dir_serial = tmp.path().join("dumps-serial");
    let dumps_serial = conn.dump_modified_buffers(&dumps_dir_serial).await.unwrap();
    unsafe {
        std::env::remove_var("KSESSION_NVIM_BUF_FAN_OUT");
    }

    assert_eq!(
        dumps_serial.len(),
        dumps.len(),
        "serial and concurrent should produce same count"
    );

    let serial_manifest_dir = dumps_dir_serial.parent().unwrap();
    let mut serial_contents: Vec<String> = dumps_serial
        .iter()
        .map(|d| {
            let abs = serial_manifest_dir.join(&d.dump_path);
            std::fs::read_to_string(&abs).unwrap()
        })
        .collect();
    serial_contents.sort();
    assert_eq!(
        serial_contents, expected,
        "serial dump contents don't match"
    );

    drop(conn);
    drop(nvim);
    let _ = child.kill().await;
}
