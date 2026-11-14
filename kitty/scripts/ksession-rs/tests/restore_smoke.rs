//! End-to-end smoke test for `ksession restore` (PRD §05).
//!
//! Strategy: drop a stub `kitty` shell script on a tempdir-only `$PATH`
//! that appends its full argv to a tmpfile, then assert the file contains
//! the expected `kitty --detach --class kitty-project-<name> --session
//! <conf>` invocation.
//!
//! We deliberately exercise the binary end-to-end (rather than
//! `restore::run`) so the CLI plumbing (clap dispatch, env-var lookup,
//! exit code) is covered too.

use std::fs;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::Command;

use tempfile::tempdir;

/// Write a stub `kitty` to `dir` that records its argv to `argv_log`.
/// The stub returns success immediately so `Command::spawn` doesn't see
/// an early exit.
fn write_stub_kitty(dir: &Path, argv_log: &Path) {
    let p = dir.join("kitty");
    // `printf '%s\n' "$@" >> log` writes one arg per line — easy to
    // diff against expected.
    let body = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$@\" >> {log}\n",
        log = shell_quote(argv_log.to_str().expect("ascii tmp path")),
    );
    let mut f = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o755)
        .open(&p)
        .expect("open stub kitty");
    use std::io::Write;
    f.write_all(body.as_bytes()).expect("write stub");
    f.sync_all().expect("fsync stub");
}

/// Minimal POSIX shell single-quoting. Sufficient for tmpdir paths.
fn shell_quote(s: &str) -> String {
    let escaped = s.replace('\'', r"'\''");
    format!("'{escaped}'")
}

/// Block until `path` exists or `attempts * 50ms` elapses. The stub
/// spawns asynchronously, so we need a tiny polling wait to avoid races.
fn wait_for_file(path: &Path, attempts: u32) -> bool {
    for _ in 0..attempts {
        if path.exists() {
            // Give the stub another moment to finish writing — the file
            // may exist but be empty.
            if fs::metadata(path).map(|m| m.len() > 0).unwrap_or(false) {
                return true;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    false
}

fn run_restore(name: &str, sessions_dir: &Path, stub_dir: &Path) -> std::process::Output {
    let bin = env!("CARGO_BIN_EXE_ksession");
    Command::new(bin)
        .args(["restore", name])
        .env("KITTY_PROJECT_SESSIONS_DIR", sessions_dir)
        .env("PATH", stub_dir)
        .output()
        .expect("spawn ksession binary")
}

#[test]
fn restore_spawns_kitty_with_expected_argv() {
    let sessions_dir = tempdir().expect("sessions tempdir");
    let stub_dir = tempdir().expect("stub tempdir");
    let log_dir = tempdir().expect("log tempdir");
    let argv_log = log_dir.path().join("argv.log");

    write_stub_kitty(stub_dir.path(), &argv_log);

    // Materialise the .conf the restore is supposed to launch.
    let conf_path = sessions_dir.path().join("demo.conf");
    fs::write(&conf_path, "# minimal conf\n").expect("write conf");

    let out = run_restore("demo", sessions_dir.path(), stub_dir.path());
    assert!(
        out.status.success(),
        "restore must exit 0: status={:?}, stdout={}, stderr={}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );

    assert!(
        wait_for_file(&argv_log, 40),
        "stub kitty never wrote argv log at {}",
        argv_log.display(),
    );

    let argv: Vec<String> = fs::read_to_string(&argv_log)
        .expect("read argv log")
        .lines()
        .map(|s| s.to_string())
        .collect();

    assert_eq!(
        argv,
        vec![
            "--detach".to_string(),
            "--class".to_string(),
            "kitty-project-demo".to_string(),
            "--session".to_string(),
            conf_path.display().to_string(),
        ],
        "stub kitty argv differs from expected"
    );
}

#[test]
fn restore_rejects_invalid_name_before_any_filesystem_work() {
    let sessions_dir = tempdir().expect("sessions tempdir");
    let stub_dir = tempdir().expect("stub tempdir");
    let log_dir = tempdir().expect("log tempdir");
    let argv_log = log_dir.path().join("argv.log");
    write_stub_kitty(stub_dir.path(), &argv_log);

    let out = run_restore("../etc", sessions_dir.path(), stub_dir.path());
    assert!(
        !out.status.success(),
        "invalid name must fail: stderr={}",
        String::from_utf8_lossy(&out.stderr),
    );
    assert!(
        !argv_log.exists(),
        "kitty must NOT have been spawned for a rejected name",
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("invalid session name"),
        "stderr should mention invalid name, got:\n{stderr}",
    );
}

#[test]
fn restore_returns_not_found_for_missing_conf() {
    let sessions_dir = tempdir().expect("sessions tempdir");
    let stub_dir = tempdir().expect("stub tempdir");
    let log_dir = tempdir().expect("log tempdir");
    let argv_log = log_dir.path().join("argv.log");
    write_stub_kitty(stub_dir.path(), &argv_log);

    let out = run_restore("ghost", sessions_dir.path(), stub_dir.path());
    assert!(!out.status.success(), "missing conf must fail");
    assert!(
        !argv_log.exists(),
        "kitty must NOT have been spawned when conf is missing",
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("not found") || stderr.contains("ghost.conf"),
        "stderr should mention not-found, got:\n{stderr}",
    );
}

#[test]
fn restore_emits_drift_warning_when_manifest_version_differs() {
    let sessions_dir = tempdir().expect("sessions tempdir");
    let stub_dir = tempdir().expect("stub tempdir");
    let log_dir = tempdir().expect("log tempdir");
    let argv_log = log_dir.path().join("argv.log");

    // Stub kitty serves *two* purposes: respond to `--version` and log
    // a normal restore invocation. Tell stub to print version then exit
    // when arg1 is `--version`; otherwise log argv and exit 0.
    let stub_body = format!(
        "#!/bin/sh\nif [ \"$1\" = '--version' ]; then printf '%s' 'kitty 0.43.0'; exit 0; fi\nprintf '%s\\n' \"$@\" >> {log}\n",
        log = shell_quote(argv_log.to_str().unwrap()),
    );
    let stub_path = stub_dir.path().join("kitty");
    {
        let mut f = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o755)
            .open(&stub_path)
            .unwrap();
        use std::io::Write;
        f.write_all(stub_body.as_bytes()).unwrap();
        f.sync_all().unwrap();
    }

    let conf = sessions_dir.path().join("demo.conf");
    fs::write(&conf, "# minimal conf\n").unwrap();

    // Manifest with a *different* major.minor.
    let state_dir = sessions_dir.path().join("demo.state");
    fs::create_dir_all(&state_dir).unwrap();
    let manifest_body = r#"{
        "name": "demo",
        "created_at": "2026-05-22T12:00:00Z",
        "schema": 1,
        "kitty_version": "kitty 0.42.0",
        "os_windows": []
    }"#;
    fs::write(state_dir.join("manifest.json"), manifest_body).unwrap();

    let out = run_restore("demo", sessions_dir.path(), stub_dir.path());
    let stderr = String::from_utf8_lossy(&out.stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "restore must exit 0 even on drift: status={:?}, stderr={stderr}, stdout={stdout}",
        out.status,
    );
    let warning_lines: Vec<&str> = stderr.lines().filter(|l| l.contains("warning")).collect();
    assert_eq!(
        warning_lines.len(),
        1,
        "expected exactly one drift-warning line on stderr, got:\n{stderr}",
    );
    let line = warning_lines[0];
    assert!(line.contains("kitty 0.42.0"), "missing captured: {line}");
    assert!(line.contains("kitty 0.43.0"), "missing running: {line}");
}

#[test]
fn restore_suppresses_drift_warning_when_versions_match() {
    let sessions_dir = tempdir().expect("sessions tempdir");
    let stub_dir = tempdir().expect("stub tempdir");
    let log_dir = tempdir().expect("log tempdir");
    let argv_log = log_dir.path().join("argv.log");

    let stub_body = format!(
        "#!/bin/sh\nif [ \"$1\" = '--version' ]; then printf '%s' 'kitty 0.42.5'; exit 0; fi\nprintf '%s\\n' \"$@\" >> {log}\n",
        log = shell_quote(argv_log.to_str().unwrap()),
    );
    let stub_path = stub_dir.path().join("kitty");
    {
        let mut f = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o755)
            .open(&stub_path)
            .unwrap();
        use std::io::Write;
        f.write_all(stub_body.as_bytes()).unwrap();
        f.sync_all().unwrap();
    }

    let conf = sessions_dir.path().join("demo.conf");
    fs::write(&conf, "# minimal conf\n").unwrap();

    let state_dir = sessions_dir.path().join("demo.state");
    fs::create_dir_all(&state_dir).unwrap();
    let manifest_body = r#"{
        "name": "demo",
        "created_at": "2026-05-22T12:00:00Z",
        "schema": 1,
        "kitty_version": "kitty 0.42.0",
        "os_windows": []
    }"#;
    fs::write(state_dir.join("manifest.json"), manifest_body).unwrap();

    let out = run_restore("demo", sessions_dir.path(), stub_dir.path());
    assert!(out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !stderr.contains("warning"),
        "no warning expected when major.minor match, got:\n{stderr}",
    );
}
