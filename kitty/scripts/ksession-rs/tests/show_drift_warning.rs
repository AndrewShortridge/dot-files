//! Integration test for `ksession show` kitty-version drift surfacing
//! (PRD §01, ADR 0002).
//!
//! Sets up a `<sessions_dir>/<name>.state/manifest.json` whose
//! `kitty_version` differs from a stubbed `kitty --version` on `PATH`,
//! runs the binary, asserts:
//!
//!   * stderr contains exactly one drift-warning line.
//!   * stdout contains the normal show render (so the warning didn't
//!     replace the rendering, only preceded it).
//!   * the same manifest with a *matching* `kitty_version` produces no
//!     warning.
//!   * a manifest with empty `kitty_version` (older artifact) also
//!     suppresses the warning.

use std::fs;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::Command;

use tempfile::tempdir;

fn write_stub_kitty(dir: &Path, version_stdout: &str) {
    let p = dir.join("kitty");
    let body = format!(
        "#!/bin/sh\ncase \"$1\" in --version) printf '%s' '{version_stdout}';; *) exit 1;; esac\n",
        version_stdout = version_stdout
    );
    let mut f = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o755)
        .open(&p)
        .unwrap();
    use std::io::Write;
    f.write_all(body.as_bytes()).unwrap();
    f.sync_all().unwrap();
}

fn write_manifest(state_dir: &Path, kitty_version: &str) {
    fs::create_dir_all(state_dir).unwrap();
    let body = format!(
        r#"{{
            "name": "demo",
            "created_at": "2026-05-22T12:00:00Z",
            "schema": 1,
            "kitty_version": "{kv}",
            "os_windows": []
        }}"#,
        kv = kitty_version
    );
    fs::write(state_dir.join("manifest.json"), body).unwrap();
}

fn run_show(sessions_dir: &Path, stub_kitty_dir: &Path) -> std::process::Output {
    let bin = env!("CARGO_BIN_EXE_ksession");
    Command::new(bin)
        .args(["show", "demo"])
        .env("KITTY_PROJECT_SESSIONS_DIR", sessions_dir)
        .env("PATH", stub_kitty_dir)
        .output()
        .expect("spawn ksession binary")
}

#[test]
fn drift_warning_emitted_once_when_versions_differ() {
    let sessions_dir = tempdir().unwrap();
    let stub_dir = tempdir().unwrap();
    write_stub_kitty(stub_dir.path(), "kitty 0.43.0");
    write_manifest(&sessions_dir.path().join("demo.state"), "kitty 0.42.0");

    let out = run_show(sessions_dir.path(), stub_dir.path());
    assert!(
        out.status.success(),
        "show must exit 0 even on drift: stderr={}, stdout={}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout),
    );

    let stderr = String::from_utf8_lossy(&out.stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);

    let warning_lines: Vec<&str> = stderr.lines().filter(|l| l.contains("warning")).collect();
    assert_eq!(
        warning_lines.len(),
        1,
        "expected exactly one drift-warning line, got stderr:\n{stderr}",
    );
    let line = warning_lines[0];
    assert!(line.contains("kitty 0.42.0"), "missing captured: {line}");
    assert!(line.contains("kitty 0.43.0"), "missing running: {line}");

    // The normal render should still appear on stdout.
    assert!(
        stdout.contains("demo  (created"),
        "show render missing from stdout:\n{stdout}",
    );
}

#[test]
fn no_warning_when_versions_match() {
    let sessions_dir = tempdir().unwrap();
    let stub_dir = tempdir().unwrap();
    write_stub_kitty(stub_dir.path(), "kitty 0.42.5");
    write_manifest(&sessions_dir.path().join("demo.state"), "kitty 0.42.0");

    let out = run_show(sessions_dir.path(), stub_dir.path());
    assert!(out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !stderr.contains("warning"),
        "no warning expected for patch-only diff, got:\n{stderr}",
    );
}

#[test]
fn no_warning_when_captured_kitty_version_empty() {
    let sessions_dir = tempdir().unwrap();
    let stub_dir = tempdir().unwrap();
    write_stub_kitty(stub_dir.path(), "kitty 0.43.0");
    write_manifest(&sessions_dir.path().join("demo.state"), "");

    let out = run_show(sessions_dir.path(), stub_dir.path());
    assert!(out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !stderr.contains("warning"),
        "no warning expected for empty captured version, got:\n{stderr}",
    );
}

#[test]
fn schema_bump_beyond_current_errors_out() {
    let sessions_dir = tempdir().unwrap();
    let stub_dir = tempdir().unwrap();
    write_stub_kitty(stub_dir.path(), "kitty 0.42.0");
    let state_dir = sessions_dir.path().join("demo.state");
    fs::create_dir_all(&state_dir).unwrap();
    let body = r#"{
        "name": "demo",
        "created_at": "2026-05-22T12:00:00Z",
        "schema": 99,
        "kitty_version": "kitty 0.42.0",
        "os_windows": []
    }"#;
    fs::write(state_dir.join("manifest.json"), body).unwrap();

    let out = run_show(sessions_dir.path(), stub_dir.path());
    assert!(!out.status.success(), "schema 99 must fail show");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("schema 99") || stderr.contains("schema") || stderr.contains("supported"),
        "stderr must mention schema mismatch, got:\n{stderr}",
    );
}
