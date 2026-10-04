//! Step 6 regression test: full unnamed-buffer capture → restore round trip.
//!
//! Per RUST_PORT_PLAN.md:672 ("unnamed_buffer_round_trip.rs"), this exercises
//! the end-to-end flow that the per-window adapter performs at capture time
//! and the bundled Lua loader performs at restore time:
//!
//!   Phase 1 (capture):
//!     - spawn a headless nvim
//!     - create an unnamed, modified buffer with known content
//!     - drive `mksession` + `dump_modified_buffers` via `NvimConn`
//!     - write the manifest JSON sidecar with the same schema the adapter
//!       writes (`src/adapter/nvim.rs:162-168`)
//!     - append the Lua loader line to session.vim
//!       (`src/adapter/nvim.rs:178-181`)
//!
//!   Phase 2 (restore):
//!     - spawn a second headless nvim with `runtimepath^=<repo>/assets` so
//!       `require('ksession_restore')` resolves, and `-S session.vim` so
//!       the captured session sources before we connect
//!
//!   Phase 3 (assert):
//!     - locate the unnamed buffer in the restored nvim, confirm content,
//!       `&modified`, and filetype match the original
//!
//! Skipped (with an eprintln, like the integration tests in
//! `src/nvim_rpc/conn.rs`) when `nvim` isn't on PATH.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use ksession_rs::model::BufferDump;
use ksession_rs::nvim_rpc::NvimConn;
use nvim_rs::{compat::tokio::Compat, create::tokio::new_path, Handler, Value};
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

/// Open a direct nvim-rs RPC connection for driving arbitrary commands the
/// public `NvimConn` API doesn't expose. Returns the handle plus the io_handle
/// which the caller must keep alive (dropping it severs the connection — see
/// the `NvimConn` doc comment in `src/nvim_rpc/conn.rs`).
async fn raw_connect(sock: &Path) -> (Nvim, IoHandle) {
    let (nvim, io_handle) = new_path(sock, NopHandler).await.expect("nvim-rs new_path");
    (nvim, io_handle)
}

#[tokio::test(flavor = "multi_thread")]
async fn unnamed_buffer_round_trip() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let tmp = tempdir().expect("tempdir");
    let state_dir = tmp.path().join("state");
    let dumps_dir = state_dir.join("nvim").join("win-1.dumps");
    let session_vim_path = state_dir.join("nvim").join("win-1.vim");
    let manifest_path = state_dir.join("nvim").join("win-1.json");
    std::fs::create_dir_all(session_vim_path.parent().unwrap()).unwrap();

    // -------- PHASE 1: capture --------

    let sock1 = tmp.path().join("nv1.sock");
    let mut child1 = tokio::process::Command::new("nvim")
        .args(["--headless", "--clean", "-u", "NORC", "--listen"])
        .arg(&sock1)
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nvim 1");
    wait_for_socket(&sock1).await;

    let conn = NvimConn::connect(&sock1)
        .await
        .expect("NvimConn::connect 1");

    // NvimConn::nvim is pub(crate), so from an integration test we open a
    // parallel raw nvim-rs connection to drive setup commands. Both share the
    // same underlying nvim — that's fine, RPC is request/response.
    let (raw, _raw_io) = raw_connect(&sock1).await;

    // Create an unnamed, modified buffer with unicode + a blank line. `enew`
    // ensures we're on a fresh unnamed buffer (some nvim versions reuse the
    // startup scratch buffer, which would also be unnamed but it's not
    // guaranteed across versions).
    raw.command("enew").await.expect("enew");
    raw.command("call setline(1, ['hello', 'world ☃', ''])")
        .await
        .expect("setline");
    raw.command("setlocal modified")
        .await
        .expect("set modified");

    // Sanity check: confirm we set up an unnamed, modified buffer with the
    // expected content before dumping. If this fails the rest of the test is
    // meaningless.
    let pre_name = raw
        .command_output("echo bufname('%')")
        .await
        .expect("bufname");
    assert_eq!(
        pre_name, "",
        "expected unnamed buffer pre-dump, got {pre_name:?}"
    );
    let pre_modified = raw
        .command_output("echo &modified")
        .await
        .expect("echo modified");
    assert_eq!(pre_modified, "1", "expected modified=1 pre-dump");

    // mksession + buffer dump via the public NvimConn API — these are the
    // pieces under test.
    conn.mksession(&session_vim_path).await.expect("mksession");
    let dumps = conn
        .dump_modified_buffers(&dumps_dir)
        .await
        .expect("dump_modified_buffers");
    assert!(
        !dumps.is_empty(),
        "expected at least one modified buffer dump"
    );

    // Pick the unnamed dump (the one whose `name` is empty). The dumps Vec
    // may contain other buffers in some nvim versions (e.g. a [No Name]
    // shown in :ls but not the one we just `enew`'d into); be precise.
    let unnamed: &BufferDump = dumps
        .iter()
        .find(|d| d.name.is_empty())
        .expect("expected an unnamed modified buffer in dumps");
    let manifest_dir = manifest_path.parent().expect("manifest has parent");
    let body = std::fs::read_to_string(manifest_dir.join(&unnamed.dump_path)).expect("read dump");
    assert_eq!(
        body, "hello\nworld ☃\n\n",
        "captured content should match what setline wrote"
    );

    // Write manifest exactly matching `src/adapter/nvim.rs:162-168`.
    let manifest_value = serde_json::json!({
        "schema": 1u32,
        "buffers": &dumps,
    });
    std::fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest_value).expect("json"),
    )
    .expect("write manifest");

    // Append the Lua loader line per `src/adapter/nvim.rs:178-181`.
    let mut session_vim_contents = std::fs::read_to_string(&session_vim_path).expect("read sess");
    if !session_vim_contents.ends_with('\n') {
        session_vim_contents.push('\n');
    }
    session_vim_contents.push_str(&format!(
        "\n\" ---- ksession buffer restore ----\nlua require('ksession_restore').load('{}')\n",
        manifest_path.display()
    ));
    std::fs::write(&session_vim_path, &session_vim_contents).expect("write sess");

    // Tear down the first nvim cleanly. Drop conn first so its io_handle
    // releases, then kill the child.
    drop(conn);
    drop(raw);
    let _ = child1.kill().await;

    // -------- PHASE 2: restore --------

    let assets_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets");
    // The loader is required as `require('ksession_restore')`, so it needs
    // to be discoverable on Lua's package.path via runtimepath. Lua files
    // live under <rtp>/lua/, which matches our assets/lua/ layout.
    let rtp_cmd = format!("set runtimepath^={}", assets_dir.display());

    let sock2 = tmp.path().join("nv2.sock");
    let mut child2 = tokio::process::Command::new("nvim")
        .args(["--headless", "--clean", "-u", "NORC"])
        .args(["-c", &rtp_cmd])
        .args(["-S"])
        .arg(&session_vim_path)
        .args(["--listen"])
        .arg(&sock2)
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nvim 2");
    wait_for_socket(&sock2).await;

    // Give the `-S` sourcing + Lua loader a moment to finish before we probe.
    // mksession sourcing is synchronous, but the loader does buffer creation;
    // a small wait avoids races on slow CI.
    tokio::time::sleep(Duration::from_millis(150)).await;

    let (raw2, _raw2_io) = raw_connect(&sock2).await;

    // -------- PHASE 3: assert --------

    // Walk buffers, find one whose name is empty (unnamed) and whose lines
    // match what we set. Both nvim versions and session.vim recipes are
    // chatty — there may be transient unnamed buffers; we need the one
    // that's *also* modified with our content.
    let bufs = raw2.list_bufs().await.expect("list_bufs");
    let mut found = None;
    for buf in &bufs {
        let name = buf.get_name().await.expect("get_name");
        if !name.is_empty() {
            continue;
        }
        let lines = buf.get_lines(0, -1, false).await.expect("get_lines");
        if lines == vec!["hello".to_string(), "world ☃".to_string(), "".to_string()] {
            let buf_val = buf.get_value().clone();
            let opts = vec![(Value::from("buf"), buf_val)];
            let modified = raw2
                .get_option_value("modified", opts.clone())
                .await
                .expect("get modified");
            let filetype = raw2
                .get_option_value("filetype", opts)
                .await
                .expect("get filetype");
            found = Some((modified, filetype, lines));
            break;
        }
    }

    let (modified, filetype, lines) = found.unwrap_or_else(|| {
        // Diagnostic dump so failures are debuggable.
        panic!(
            "no unnamed buffer with expected content found. session.vim:\n---\n{}\n---",
            session_vim_contents
        )
    });

    assert!(
        matches!(modified, Value::Boolean(true)),
        "restored unnamed buffer should be &modified, got {modified:?}"
    );
    // No filetype was set at capture time (we never wrote it to disk under
    // any name, and we didn't `setfiletype`), so it should be empty. Some
    // nvim versions return `""` as a Value::String; tolerate both forms.
    let ft = filetype.as_str().unwrap_or("");
    assert_eq!(ft, "", "expected empty filetype, got {filetype:?}");
    assert_eq!(
        lines,
        vec!["hello".to_string(), "world ☃".to_string(), "".to_string()]
    );

    drop(raw2);
    let _ = child2.kill().await;
}
