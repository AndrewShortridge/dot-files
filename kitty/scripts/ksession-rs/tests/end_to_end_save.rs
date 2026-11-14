//! End-to-end integration test exercising the full save-side pipeline:
//!
//!     KittyTransport::ls_session  ->  conf::render  ->  fsx::write_atomic
//!
//! Each individual stage is covered by its own unit / golden tests
//! (`src/kitty/rpc.rs`, `tests/conf_golden.rs`, `src/fsx/mod.rs`).
//! This test wires them together to lock the contract that the bytes
//! produced by an end-to-end save run match the checked-in golden — i.e.
//! that no intermediate stage silently mutates the data in transit.
//!
//! Approach: full RPC mock. We stand up a Unix-socket server speaking
//! the kitty DCS-cmd framing protocol (`\x1bP@kitty-cmd <json> \x1b\\`)
//! and serve the `two_tabs.skel` fixture as the `kitty @ ls
//! --output-format=session` response body. `KittyTransport::Rpc` then
//! drives it through the real `KittyRpc::ls_session` code path.
//!
//! The DCS framing helper `encode_frame` in `src/kitty/rpc.rs` is
//! `pub(crate)`, so we inline a small encoder here (the protocol is
//! a fixed prefix + body + terminator; mirrors `src/kitty/mod.rs`'s
//! own copy in its test module).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use ksession_rs::conf::render;
use ksession_rs::fsx::write_atomic;
use ksession_rs::kitty::{KittyRpc, KittyTransport};
use ksession_rs::model::{OsWindow, Program, SessionFile, ShellKind, Tab, Window};

use chrono::{DateTime, TimeZone, Utc};
use pretty_assertions::assert_eq;
use serde_json::{json, Value};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tokio::sync::oneshot;

// --- DCS framing (mirror of src/kitty/rpc.rs pub(crate) helpers) ------------

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

/// Spawn a Unix-socket mock kitty server. `handler` receives each parsed
/// request JSON and returns the response body (or `None` for no_response
/// frames, though this test only issues request/response ones).
async fn spawn_mock_server<F>(handler: F) -> (PathBuf, tempfile::TempDir, oneshot::Receiver<()>)
where
    F: Fn(Value) -> Option<Value> + Send + Sync + 'static,
{
    let dir = tempdir().expect("tempdir");
    let sock = dir.path().join("rpc.sock");
    let listener = UnixListener::bind(&sock).expect("bind");
    let (done_tx, done_rx) = oneshot::channel();
    let h = Arc::new(handler);
    tokio::spawn(async move {
        let (mut stream, _) = match listener.accept().await {
            Ok(p) => p,
            Err(_) => {
                let _ = done_tx.send(());
                return;
            }
        };
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
                let json_bytes = &frame[DCS_PREFIX.len()..frame.len() - DCS_TERMINATOR.len()];
                let req: Value = serde_json::from_slice(json_bytes).expect("req parses");
                if let Some(resp_json) = h(req) {
                    let resp_bytes = serde_json::to_vec(&resp_json).expect("ser");
                    let _ = stream.write_all(&encode_frame(&resp_bytes)).await;
                    let _ = stream.flush().await;
                }
            }
        }
        let _ = done_tx.send(());
    });
    (sock, dir, done_rx)
}

// --- fixture helpers --------------------------------------------------------

fn fixture_ts() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 5, 22, 12, 0, 0).unwrap()
}

fn manifest_dir() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

/// SessionFile mirroring `conf_golden::two_tabs_session()`. Duplicated here
/// rather than imported because integration tests are independent
/// compilation units and the helper isn't part of the library's public API.
fn two_tabs_session() -> SessionFile {
    SessionFile {
        name: "two_tabs".to_string(),
        created_at: fixture_ts(),
        schema: 1,
        kitty_version: String::new(),
        os_windows: vec![OsWindow {
            tabs: vec![
                Tab {
                    title: Some("editors".into()),
                    layout: "splits".into(),
                    active_window_idx: 1,
                    windows: vec![
                        Window {
                            kitty_id: 1,
                            ksession_id: "uid-1".into(),
                            cwd: Some(PathBuf::from("/home/u/proj")),
                            program: Program::BareShell,
                            scrollback: None,
                        },
                        Window {
                            kitty_id: 2,
                            ksession_id: "uid-2".into(),
                            cwd: Some(PathBuf::from("/var/log")),
                            program: Program::Nvim {
                                session_vim: PathBuf::from("/tmp/session.vim"),
                                manifest: None,
                                truncated_buffers: 0,
                            },
                            scrollback: None,
                        },
                    ],
                },
                Tab {
                    title: None,
                    layout: "stack".into(),
                    active_window_idx: 0,
                    windows: vec![Window {
                        kitty_id: 3,
                        ksession_id: "uid-3".into(),
                        cwd: Some(PathBuf::from("/home/u")),
                        program: Program::Shell {
                            shell: ShellKind::Zsh,
                            venv: Some(PathBuf::from("/home/u/.venv")),
                            conda: None,
                            direnv: None,
                            oldpwd: None,
                            scrollback: None,
                            history: None,
                        },
                        scrollback: None,
                    }],
                },
            ],
        }],
    }
}

// --- the test ---------------------------------------------------------------

#[tokio::test]
async fn end_to_end_save_two_tabs() {
    // 1. Load the canned skeleton fixture that the mock kitty will serve.
    let skel_path = manifest_dir()
        .join("tests")
        .join("fixtures")
        .join("kitty-session")
        .join("two_tabs.skel");
    let canned_skeleton = std::fs::read_to_string(&skel_path)
        .unwrap_or_else(|e| panic!("read {}: {e}", skel_path.display()));

    // 2. Stand up the mock kitty server. It validates that ls_session
    //    actually requested the session output format and the
    //    all_env_vars / self foreground flags forwarded correctly.
    let served = canned_skeleton.clone();
    let (sock, _dir, _done) = spawn_mock_server(move |req| {
        assert_eq!(req["cmd"], "ls", "transport must issue an `ls` command");
        assert_eq!(
            req["payload"]["output_format"], "session",
            "ls_session must request output_format=session",
        );
        assert_eq!(
            req["payload"]["all_env_vars"], true,
            "all_env_vars flag must propagate",
        );
        // `self` field was removed (see ls_session_payload_has_no_self_field
        // in rpc.rs); the foreground-process flag rides in via
        // `self_window`-style flags. We only assert it's *not* the legacy
        // `self: false` mis-name.
        assert!(
            req["payload"].get("self").is_none(),
            "stale `self` field must not appear"
        );
        Some(json!({ "ok": true, "data": served.clone() }))
    })
    .await;

    let rpc = KittyRpc::connect(&sock).await.expect("connect to mock");
    let transport = KittyTransport::Rpc(std::sync::Arc::new(rpc));

    // 3. Drive the full ls_session code path. The skeleton comes back
    //    trimmed of trailing whitespace per the documented contract
    //    (rpc.rs:ls_session strips the trailing newline kitty emits).
    let skeleton = transport
        .ls_session(true, true)
        .await
        .expect("ls_session must succeed against mock");
    // The fixture file ends in a newline; the transport strips it.
    assert_eq!(
        skeleton,
        canned_skeleton.trim_end(),
        "skeleton round-trip must match canned fixture minus trailing ws",
    );

    // 4. Render against a SessionFile whose kitty_ids match the skeleton.
    let session = two_tabs_session();
    let rendered = render(&skeleton, &session).expect("render must succeed");

    // 5. Write to disk via the project's atomic-write helper. Use a
    //    tempdir so the test never touches the repo.
    let out_dir = tempdir().expect("output tempdir");
    let out_path = out_dir.path().join("session.conf");
    write_atomic(&out_path, rendered.as_bytes()).expect("write_atomic must succeed");
    assert!(
        out_path.exists(),
        "write_atomic must produce the target file"
    );

    // 6. Read back and compare against the existing golden.
    let on_disk = std::fs::read_to_string(&out_path).expect("read written conf");
    let golden_path = manifest_dir()
        .join("tests")
        .join("golden")
        .join("conf")
        .join("two_tabs.conf");
    let golden = std::fs::read_to_string(&golden_path)
        .unwrap_or_else(|e| panic!("read golden {}: {e}", golden_path.display()));
    // The golden was generated by feeding `render` a skeleton with the
    // raw on-disk trailing newline (`conf_golden::golden_two_tabs` reads
    // the .skel verbatim). The production transport path strips trailing
    // whitespace from the kitty response (see KittyRpc::ls_session), so
    // the end-to-end output is identical *modulo* that final newline.
    // Compare the trim_end()'d forms so the test asserts byte-equality
    // of the meaningful content while documenting the trailing-ws
    // contract delta.
    assert_eq!(
        on_disk.trim_end(),
        golden.trim_end(),
        "end-to-end pipeline output must match the conf_golden two_tabs fixture",
    );

    // 7. Plan §C.1 regression: the intra-process reattach marker must
    //    never survive into the emitted conf. Even though conf_golden
    //    already asserts this, repeat it here as the post-disk check
    //    so the regression is caught at the final boundary too.
    assert!(
        !on_disk.contains("kitty-unserialize-data"),
        "kitty-unserialize-data token leaked into final on-disk conf:\n{on_disk}",
    );

    // 8. Validate the UUID-tagging path: every matched window in the
    //    session must contribute a `--var=ksession_id=` token.
    assert!(
        on_disk.contains("--var=ksession_id="),
        "no `--var=ksession_id=` emitted — UUID tagging path is broken:\n{on_disk}",
    );
}
