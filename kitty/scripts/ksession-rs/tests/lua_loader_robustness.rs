//! Step 6 robustness tests for the bundled Lua loader
//! (`assets/lua/ksession_restore.lua`).
//!
//! These tests complement `unnamed_buffer_round_trip.rs` by exercising the
//! loader's error/guard paths rather than the happy path:
//!
//!   1. `schema_guard_rejects_future_schema` — manifests with schema > 1 must
//!      be skipped entirely (no buffers materialized).
//!   2. `missing_dump_skips_buffer_no_ghost` — when a manifest references a
//!      dump file that does not exist on disk, the loader must skip cleanly
//!      and not leave a ghost unnamed buffer behind (per the
//!      `nvim_buf_delete` cleanup the loader performs before `goto continue`).
//!   3. `idempotency_blocks_resource_but_initial_load_works` — calling
//!      `load()` materializes exactly one buffer with the expected content,
//!      and the `vim.g.ksession_loaded` table is populated. (Note: nvim's
//!      `vim.g.<x>.<y> = z` does NOT mutate in place — it operates on a
//!      snapshot — so the loader's set-after-loop assignment doesn't persist
//!      a per-path key; we therefore can't directly assert idempotency at
//!      the per-manifest granularity. We instead verify the observable
//!      first-load behavior, which is what restore actually needs.)
//!
//! All tests skip cleanly when nvim is not on PATH (mirrors
//! `unnamed_buffer_round_trip.rs`).
//!
//! Note: Rust integration tests are separate compilation units, so the
//! nvim-spawning helpers are duplicated from the round-trip test by design.

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

/// Spawn a headless nvim with the loader on rtp and a unix socket. Returns
/// the child handle (caller is responsible for `kill_on_drop` already set)
/// and the socket path is the caller's job to pre-create-in-tmp and pass in.
async fn spawn_nvim_with_loader(sock: &Path) -> tokio::process::Child {
    // `set noswapfile` is critical: nvim's default `'directory'` is a
    // user-global path (~/.local/state/nvim/swap//) and the [No Name]
    // buffers the loader creates all hash to the same swap filename. When
    // four of these tests run in parallel (as cargo does by default) the
    // parallel nvim processes race for the same swap file and one loses
    // with `E303: Unable to open swap file for "[No Name]"`. We're not
    // testing swap-recovery, so disable swap outright.
    let child = tokio::process::Command::new("nvim")
        .args(["--headless", "--clean", "-u", "NORC"])
        .args(["-c", "set noswapfile"])
        .args(["-c", &rtp_cmd()])
        .args(["--listen"])
        .arg(sock)
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nvim");
    wait_for_socket(sock).await;
    child
}

// -------------------------------------------------------------------------
// TEST 1: schema guard
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn schema_guard_rejects_future_schema() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let manifest_path = tmp.path().join("win-1.json");
    let dump_path = tmp.path().join("buf.txt");

    // Write a dump so missing-file can't be the skip cause.
    std::fs::write(&dump_path, "schema-guard-content\n").expect("write dump");

    // schema=2 → loader must bail before processing buffers.
    let manifest = serde_json::json!({
        "schema": 2u32,
        "buffers": [{
            "buf_id": 1,
            "name": "x",
            "modified": true,
            "filetype": "",
            "dump_path": "buf.txt",
            "truncated": false,
            "byte_count": 21u64,
        }],
    });
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).expect("json"),
    )
    .expect("write manifest");

    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim_with_loader(&sock).await;

    let (raw, _io) = raw_connect(&sock).await;

    // Drive the loader directly (no session.vim needed for this assertion).
    let load_cmd = format!(
        "lua require('ksession_restore').load({:?})",
        manifest_path.to_string_lossy()
    );
    raw.command(&load_cmd).await.expect("loader call");

    // Tiny settle window so any (rejected) buffer creation would have
    // happened — confirms the absence is real, not a race.
    tokio::time::sleep(Duration::from_millis(100)).await;

    let bufs = raw.list_bufs().await.expect("list_bufs");
    let mut matched = 0usize;
    for buf in &bufs {
        let name = buf.get_name().await.expect("get_name");
        // bufname is the absolute path; we wrote "x" (no slash). The loader
        // would call bufadd("x") which yields a buffer whose name ends in
        // "/x" or is exactly "x" depending on cwd. Match permissively.
        if name == "x" || name.ends_with("/x") {
            matched += 1;
        }
    }
    assert_eq!(
        matched, 0,
        "schema>1 should skip processing — found {matched} buffers matching 'x'"
    );

    drop(raw);
    let _ = child.kill().await;
}

// -------------------------------------------------------------------------
// TEST 2: missing dump skips buffer, no ghost
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn missing_dump_skips_buffer_no_ghost() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let manifest_path = tmp.path().join("win-1.json");
    // Note: NO dump files written to disk.

    let manifest = serde_json::json!({
        "schema": 1u32,
        "buffers": [
            {
                "buf_id": 1,
                "name": "named-buffer-xyz",
                "modified": true,
                "filetype": "",
                "dump_path": "missing-named.txt",
                "truncated": false,
                "byte_count": 0u64,
            },
            {
                "buf_id": 2,
                "name": "",
                "modified": true,
                "filetype": "",
                "dump_path": "missing-unnamed.txt",
                "truncated": false,
                "byte_count": 0u64,
            },
        ],
    });
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).expect("json"),
    )
    .expect("write manifest");

    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim_with_loader(&sock).await;

    let (raw, _io) = raw_connect(&sock).await;

    let load_cmd = format!(
        "lua require('ksession_restore').load({:?})",
        manifest_path.to_string_lossy()
    );
    raw.command(&load_cmd).await.expect("loader call");

    tokio::time::sleep(Duration::from_millis(100)).await;

    // Scan all buffers. We must NOT find a "ghost" unnamed buffer that is
    // listed AND empty — that would indicate `nvim_create_buf(true,false)`
    // was called and then never cleaned up after the missing-file skip.
    //
    // Caveat: nvim startup may itself create a single anonymous scratch
    // buffer (buffer 1, listed, empty). We exclude that one — the loader's
    // ghost would be in ADDITION to it, so we still detect leaks.
    let bufs = raw.list_bufs().await.expect("list_bufs");
    let mut ghost_unnamed = 0usize;
    let mut startup_unnamed_seen = false;
    for buf in &bufs {
        let name = buf.get_name().await.expect("get_name");
        if !name.is_empty() {
            continue;
        }
        let lines = buf.get_lines(0, -1, false).await.expect("get_lines");
        let is_empty = lines.is_empty() || (lines.len() == 1 && lines[0].is_empty());
        if !is_empty {
            continue;
        }
        // Empty unnamed buffer — tolerate at most one (the startup scratch).
        if !startup_unnamed_seen {
            startup_unnamed_seen = true;
        } else {
            ghost_unnamed += 1;
        }
    }
    assert_eq!(
        ghost_unnamed, 0,
        "missing-dump path should not leave a ghost unnamed buffer behind"
    );

    drop(raw);
    let _ = child.kill().await;
}

// -------------------------------------------------------------------------
// TEST 3: idempotency guard
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn idempotency_blocks_resource_but_initial_load_works() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let manifest_path = tmp.path().join("win-1.json");
    let dump_rel = "buf.txt";
    let dump_abs = tmp.path().join(dump_rel);

    // The body has a UTF-8 char so identical-but-coincidental empty-line
    // matches from startup buffers can't pass the content assertion.
    std::fs::write(&dump_abs, "alpha\nbeta-☃\n").expect("write dump");

    let manifest = serde_json::json!({
        "schema": 1u32,
        "buffers": [{
            "buf_id": 1,
            "name": "",
            "modified": true,
            "filetype": "",
            "dump_path": dump_rel,
            "truncated": false,
            "byte_count": 13u64,
        }],
    });
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).expect("json"),
    )
    .expect("write manifest");

    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim_with_loader(&sock).await;

    let (raw, _io) = raw_connect(&sock).await;

    let load_cmd = format!(
        "lua require('ksession_restore').load({:?})",
        manifest_path.to_string_lossy()
    );

    // First call: should materialize one unnamed buffer with our content.
    raw.command(&load_cmd).await.expect("loader call 1");
    tokio::time::sleep(Duration::from_millis(100)).await;

    let expected: Vec<String> = vec!["alpha".to_string(), "beta-☃".to_string()];

    let bufs = raw.list_bufs().await.expect("list_bufs");
    let mut hits = 0usize;
    for buf in &bufs {
        let name = buf.get_name().await.expect("get_name");
        if !name.is_empty() {
            continue;
        }
        let lines = buf.get_lines(0, -1, false).await.expect("get_lines");
        if lines == expected {
            hits += 1;
        }
    }
    assert_eq!(
        hits, 1,
        "expected exactly one unnamed buffer with content {expected:?} after initial load, got {hits}"
    );

    // Second call on the SAME json_path: must short-circuit via the
    // vim.g.ksession_loaded guard. No new unnamed buffer should appear.
    raw.command(&load_cmd).await.expect("loader call 2");
    tokio::time::sleep(Duration::from_millis(100)).await;

    let bufs2 = raw.list_bufs().await.expect("list_bufs after 2nd load");
    let mut hits2 = 0usize;
    for buf in &bufs2 {
        let name = buf.get_name().await.expect("get_name");
        if !name.is_empty() {
            continue;
        }
        let lines = buf.get_lines(0, -1, false).await.expect("get_lines");
        if lines == expected {
            hits2 += 1;
        }
    }
    assert_eq!(
        hits2, 1,
        "second load() call must be idempotent; expected 1 matching buffer, got {hits2}"
    );

    drop(raw);
    let _ = child.kill().await;
}

// -------------------------------------------------------------------------
// TEST 4: nil dump_path in manifest must not crash the loader
// -------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn nil_dump_path_skips_buffer_without_crashing() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let manifest_path = tmp.path().join("win-1.json");

    // Second entry has a valid dump file — proves the loader CONTINUES past
    // the nil-entry rather than aborting.
    let valid_rel = "valid.txt";
    let valid_abs = tmp.path().join(valid_rel);
    std::fs::write(&valid_abs, "valid-line-☃\n").expect("write valid dump");

    let manifest = serde_json::json!({
        "schema": 1u32,
        "buffers": [
            {
                "buf_id": 1,
                "name": "",
                "modified": true,
                "filetype": "",
                "dump_path": serde_json::Value::Null,
                "truncated": false,
                "byte_count": 0u64,
            },
            {
                "buf_id": 2,
                "name": "",
                "modified": true,
                "filetype": "",
                "dump_path": valid_rel,
                "truncated": false,
                "byte_count": 14u64,
            },
        ],
    });
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).expect("json"),
    )
    .expect("write manifest");

    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim_with_loader(&sock).await;

    let (raw, _io) = raw_connect(&sock).await;

    let load_cmd = format!(
        "lua require('ksession_restore').load({:?})",
        manifest_path.to_string_lossy()
    );

    // If the loader crashed on the nil concat, this call would error out
    // (the lua chunk would raise "attempt to concatenate a nil value").
    raw.command(&load_cmd)
        .await
        .expect("loader call must not crash on nil dump_path");

    tokio::time::sleep(Duration::from_millis(100)).await;

    // Primary crash-detection: nvim still alive and answering RPC.
    let bufs = raw
        .list_bufs()
        .await
        .expect("list_bufs after nil-dump_path load");

    // Bonus: the second (valid) entry should have materialized — proves the
    // loader resumed past the skipped nil entry rather than bailing.
    let expected: Vec<String> = vec!["valid-line-☃".to_string()];
    let mut hits = 0usize;
    for buf in &bufs {
        let name = buf.get_name().await.expect("get_name");
        if !name.is_empty() {
            continue;
        }
        let lines = buf.get_lines(0, -1, false).await.expect("get_lines");
        if lines == expected {
            hits += 1;
        }
    }
    assert_eq!(
        hits, 1,
        "expected the valid second entry to load after the nil-entry skip; got {hits}"
    );

    drop(raw);
    let _ = child.kill().await;
}
