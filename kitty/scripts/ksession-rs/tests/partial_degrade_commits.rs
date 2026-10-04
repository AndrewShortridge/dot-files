//! End-to-end: two-window save where one window degrades.
//!
//! Per ADR 0001, a save with ≥1 surviving window commits. The degraded
//! window lands in the manifest as `Program::BareShell`; the orchestrator
//! emits one `ksession: window <id>: <error>` line to stderr; the CLI exits
//! with code `2` so `ksession-save-prompt.sh` can surface a "saved with N
//! degradations" badge.
//!
//! This test drives the `ksession` binary as a subprocess so it can assert
//! end-to-end behaviour: stderr content, exit code, and on-disk artifacts.
//! A Unix-socket mock kitty server stands in for kitty (the binary talks to
//! it via `$KITTY_LISTEN_ON`); a tempdir-backed procfs (via
//! `$KSESSION_PROC_ROOT`) drives the orchestrator into the degrade path
//! deterministically.
//!
//! Window layout:
//!   - id=7, pid=4242 — no `/proc/4242/exe`, so `fg_exe = None`. The shell
//!     adapter detects on `fg_exe.is_none()` and succeeds with a default
//!     `Program::Shell`. This is the "surviving" window.
//!   - id=8, pid=4243 — `/proc/4243/exe → /usr/local/bin/weirdbin`. None of
//!     the typed adapters (nvim/tmux/less/shell) detect; RawAdapter is
//!     last and reads `/proc/4243/cmdline` — which we leave missing. Raw
//!     returns `Err(NoCmdline { pid: 4243 })`; the registry falls through
//!     to `Program::BareShell` and propagates the error up to `save`,
//!     which logs `ksession: window 8: cmdline unavailable for pid 4243`
//!     and sets `degraded_any = true`.

use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;

use tokio::process::Command;

use serde_json::{json, Value};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

// --- DCS framing helpers (copied from save_orchestration.rs) ---------------

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

fn two_window_ls_json() -> Value {
    json!([{
        "id": 1,
        "is_focused": true,
        "is_active": true,
        "tabs": [{
            "id": 1,
            "title": "demo",
            "layout": "splits",
            "is_active": true,
            "windows": [
                {
                    "id": 7,
                    "pid": 4242,
                    "title": "demo",
                    "is_active": true,
                    "foreground_processes": [],
                    "env": {},
                    "user_vars": {}
                },
                {
                    "id": 8,
                    "pid": 4243,
                    "title": "weird",
                    "is_active": false,
                    "foreground_processes": [],
                    "env": {},
                    "user_vars": {}
                }
            ]
        }]
    }])
}

const TWO_WINDOW_SKELETON: &str = "new_tab\n\
layout splits\n\
launch 'kitty-unserialize-data={\"id\": 7}' --var=ksession_idx=0 --var=ksession_win=7 /bin/bash -l\n\
launch 'kitty-unserialize-data={\"id\": 8}' --var=ksession_idx=1 --var=ksession_win=8 /bin/bash -l\n\
focus\n\
focus_tab 1\n";

fn make_handler() -> impl Fn(Value) -> Option<Value> + Send + Sync + 'static {
    let ls = two_window_ls_json();
    move |req| match req["cmd"].as_str() {
        Some("ls") => {
            if req["payload"]["output_format"] == "session" {
                Some(json!({ "ok": true, "data": TWO_WINDOW_SKELETON }))
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

/// Build a tempdir-backed procfs that:
///   - has no entry for pid 4242 (forces `fg_exe = None` → ShellAdapter wins)
///   - has `/<root>/4243/exe → /usr/local/bin/weirdbin` but NO `cmdline`
///     file (forces RawAdapter into `NoCmdline { pid: 4243 }`)
fn build_fake_proc(root: &Path) {
    let p4243 = root.join("4243");
    std::fs::create_dir_all(&p4243).expect("mk 4243");
    symlink("/usr/local/bin/weirdbin", p4243.join("exe")).expect("exe symlink");
    // Intentionally no cmdline file.
}

fn find_gen_state_dirs(sessions_dir: &Path, name: &str) -> Vec<PathBuf> {
    let prefix = format!("{name}.gen-");
    let mut hits: Vec<PathBuf> = Vec::new();
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
        let path = ent.path();
        if path.is_dir() {
            hits.push(path);
        }
    }
    hits
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn partial_degrade_commits_and_exits_two() {
    // Spin up the mock kitty server first so the subprocess can dial in.
    let (sock, _server_guard) = spawn_mock_server(make_handler()).await;

    // Fake /proc.
    let proc_root = tempdir().expect("proc tmp");
    build_fake_proc(proc_root.path());

    // Sessions dir for the subprocess to write into.
    let sessions = tempdir().expect("sessions tmp");

    // Locate the built binary via the cargo-set env var.
    let bin = env!("CARGO_BIN_EXE_ksession");

    // Run the subprocess with all env vars scoped to it (no process-global
    // env mutation that could trample sibling tests).
    let out = Command::new(bin)
        .arg("save")
        .arg("demo")
        .arg("--all")
        .env("KITTY_LISTEN_ON", format!("unix:{}", sock.display()))
        .env("KSESSION_PROC_ROOT", proc_root.path())
        .env("KITTY_PROJECT_SESSIONS_DIR", sessions.path())
        .env_remove("KITTY_WINDOW_ID")
        .env_remove("KSESSION_SCROLLBACK")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .expect("spawn ksession");

    let stderr = String::from_utf8_lossy(&out.stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);

    // 1) Exit code 2: degraded but committed (ADR 0001).
    assert_eq!(
        out.status.code(),
        Some(2),
        "expected exit code 2 for degraded save; got status={:?}\n--- stderr ---\n{stderr}\n--- stdout ---\n{stdout}",
        out.status,
    );

    // 2) Exactly one `ksession: window <id>:` line (for window 8). Other
    //    eprintln noise (orphan sweep, etc.) is permitted but must not
    //    contain the per-window degradation prefix more than once.
    let degrade_lines: Vec<&str> = stderr
        .lines()
        .filter(|l| l.starts_with("ksession: window "))
        .collect();
    assert_eq!(
        degrade_lines.len(),
        1,
        "expected exactly one `ksession: window <id>:` line; got {:?}\n--- full stderr ---\n{stderr}",
        degrade_lines,
    );
    assert!(
        degrade_lines[0].starts_with("ksession: window 8:"),
        "degradation must reference the failing window (id=8), got: {:?}",
        degrade_lines[0],
    );

    // 3) The `.conf` was written.
    let conf = sessions.path().join("demo.conf");
    assert!(
        conf.exists(),
        "conf must be committed even when one window degraded: {}",
        conf.display(),
    );

    // 4) The manifest persists the degraded window as `Program::BareShell`.
    let gen_dirs = find_gen_state_dirs(sessions.path(), "demo");
    assert_eq!(
        gen_dirs.len(),
        1,
        "exactly one gen-stamped state dir for demo: {gen_dirs:?}",
    );
    let manifest_path = gen_dirs[0].join("manifest.json");
    let manifest_text = std::fs::read_to_string(&manifest_path).expect("read manifest");
    let manifest: Value = serde_json::from_str(&manifest_text).expect("parse manifest");

    let windows = manifest["os_windows"][0]["tabs"][0]["windows"]
        .as_array()
        .expect("windows array");
    assert_eq!(windows.len(), 2, "both windows persisted: {windows:?}");

    // Find the window with kitty_id=8 — it must be Program::BareShell.
    let degraded = windows
        .iter()
        .find(|w| w["kitty_id"] == 8)
        .expect("kitty_id=8 present in manifest");
    assert_eq!(
        degraded["program"]["kind"], "bare_shell",
        "degraded window 8 must serialise as Program::BareShell, got: {}",
        degraded["program"],
    );

    // The surviving window (kitty_id=7) must NOT be BareShell.
    let surviving = windows
        .iter()
        .find(|w| w["kitty_id"] == 7)
        .expect("kitty_id=7 present in manifest");
    assert_ne!(
        surviving["program"]["kind"], "bare_shell",
        "surviving window 7 should have been captured by ShellAdapter, got: {}",
        surviving["program"],
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn all_healthy_save_exits_zero_with_no_degrade_lines() {
    // Same setup but BOTH windows take the ShellAdapter path: no entries
    // in fake /proc → both resolve to `fg_exe = None` → both succeed.
    let (sock, _server_guard) = spawn_mock_server(make_handler()).await;
    let proc_root = tempdir().expect("proc tmp");
    // No /proc entries at all → fg_exe = None for both windows.
    let sessions = tempdir().expect("sessions tmp");
    let bin = env!("CARGO_BIN_EXE_ksession");

    let out = Command::new(bin)
        .arg("save")
        .arg("healthy")
        .arg("--all")
        .env("KITTY_LISTEN_ON", format!("unix:{}", sock.display()))
        .env("KSESSION_PROC_ROOT", proc_root.path())
        .env("KITTY_PROJECT_SESSIONS_DIR", sessions.path())
        .env_remove("KITTY_WINDOW_ID")
        .env_remove("KSESSION_SCROLLBACK")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .expect("spawn ksession");

    let stderr = String::from_utf8_lossy(&out.stderr);

    assert_eq!(
        out.status.code(),
        Some(0),
        "all-healthy save must exit 0; status={:?}\nstderr:\n{stderr}",
        out.status,
    );
    assert!(
        !stderr.lines().any(|l| l.starts_with("ksession: window ")),
        "no per-window degrade lines expected on healthy save; got:\n{stderr}",
    );
}
