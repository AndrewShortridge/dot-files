//! End-to-end test for `ksession list` (PRD issue #06).
//!
//! Builds a tmp sessions dir containing three saves of varying ages plus
//! a fourth `.conf` whose sidecar manifest is missing. Drives the
//! installed binary with `KITTY_PROJECT_SESSIONS_DIR` pointing at the
//! tmpdir and asserts:
//!
//!   * exit code is 0,
//!   * three healthy rows are sorted by `created_at` descending,
//!   * the broken row appears with a `(no manifest)` marker,
//!   * every healthy row is tab-separated and includes name, ISO-8601
//!     timestamp, captured `kitty_version`, and a window-count field.
//!
//! The fixtures use the gen-stamped layout that `session::save` writes
//! today (`<name>.gen-<ts>.state/manifest.json`) so the dispatcher
//! exercises the conf-body scan that resolves a conf back to its
//! manifest sidecar.

use std::fs;
use std::path::Path;
use std::process::Command;

use tempfile::tempdir;

/// Write a minimal valid manifest for `name` with the given created-at
/// timestamp and a `windows_per_tab` slice describing tab sizes.
fn write_session(
    sessions_dir: &Path,
    name: &str,
    gen_us: u64,
    created_at_iso: &str,
    kitty_version: &str,
    windows_per_tab: &[usize],
) {
    let state_basename = format!("{name}.gen-{gen_us}.state");
    let state_dir = sessions_dir.join(&state_basename);
    fs::create_dir_all(&state_dir).unwrap();

    // Build os_windows JSON with one OS window and the requested tab shape.
    let mut tabs_json = String::new();
    for (i, &n) in windows_per_tab.iter().enumerate() {
        if i > 0 {
            tabs_json.push(',');
        }
        let mut windows = String::new();
        for w in 0..n {
            if w > 0 {
                windows.push(',');
            }
            windows.push_str(&format!(
                r#"{{"kitty_id":{w},"ksession_id":"","cwd":null,"program":{{"kind":"bare_shell"}},"scrollback":null}}"#
            ));
        }
        tabs_json.push_str(&format!(
            r#"{{"title":null,"layout":"splits","active_window_idx":0,"windows":[{windows}]}}"#
        ));
    }

    let manifest = format!(
        r#"{{
            "name": "{name}",
            "created_at": "{created_at_iso}",
            "schema": 1,
            "kitty_version": "{kitty_version}",
            "os_windows": [{{"tabs":[{tabs_json}]}}]
        }}"#
    );
    fs::write(state_dir.join("manifest.json"), manifest).unwrap();

    // Conf body just needs to embed the gen-stamped state dir basename so
    // the dispatcher's conf-body scan can locate the sidecar.
    let conf_body = format!(
        "# Description: ksession save '{name}'\n\
         launch --hold nvim -S {sd}/{state_basename}/nvim/win-0.vim\n",
        sd = sessions_dir.display(),
    );
    fs::write(sessions_dir.join(format!("{name}.conf")), conf_body).unwrap();
}

fn run_list(sessions_dir: &Path) -> std::process::Output {
    let bin = env!("CARGO_BIN_EXE_ksession");
    Command::new(bin)
        .arg("list")
        .env("KITTY_PROJECT_SESSIONS_DIR", sessions_dir)
        // Empty PATH so the binary can't accidentally find a real kitty.
        // list uses `read_no_drift`, which never spawns kitty anyway, but
        // hardening this keeps the test hermetic.
        .env("PATH", "")
        .output()
        .expect("spawn ksession binary")
}

#[test]
fn list_sorts_by_created_at_desc_and_renders_tab_aligned_rows() {
    let dir = tempdir().unwrap();
    let sessions_dir = dir.path();

    // Three healthy saves at varying ages (oldest first).
    write_session(
        sessions_dir,
        "alpha",
        1_700_000_000_000_000,
        "2026-01-01T00:00:00Z",
        "kitty 0.42.0",
        &[2],
    );
    write_session(
        sessions_dir,
        "beta",
        1_700_000_001_000_000,
        "2026-03-15T12:30:00Z",
        "kitty 0.42.1",
        &[1, 1, 1],
    );
    write_session(
        sessions_dir,
        "gamma",
        1_700_000_002_000_000,
        "2026-05-22T08:00:00Z",
        "kitty 0.43.0",
        &[1],
    );

    let out = run_list(sessions_dir);
    assert!(
        out.status.success(),
        "list must exit 0: stderr={}, stdout={}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout),
    );

    let stdout = String::from_utf8(out.stdout).unwrap();
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines.len(), 3, "expected 3 rows, got:\n{stdout}");

    // Descending by created_at: gamma (May) > beta (Mar) > alpha (Jan).
    assert!(
        lines[0].starts_with("gamma\t"),
        "row 0 should be gamma, got: {}",
        lines[0]
    );
    assert!(
        lines[1].starts_with("beta\t"),
        "row 1 should be beta, got: {}",
        lines[1]
    );
    assert!(
        lines[2].starts_with("alpha\t"),
        "row 2 should be alpha, got: {}",
        lines[2]
    );

    // Each row has 4 tab-separated columns:
    //   name<TAB>created_at<TAB>kitty_version<TAB>window_count
    for line in &lines {
        let cols: Vec<&str> = line.split('\t').collect();
        assert_eq!(
            cols.len(),
            4,
            "expected 4 tab-separated columns, got {} in: {line}",
            cols.len()
        );
    }

    // Spot-check field contents on the newest row.
    let gamma_cols: Vec<&str> = lines[0].split('\t').collect();
    assert_eq!(gamma_cols[0], "gamma");
    assert_eq!(gamma_cols[1], "2026-05-22T08:00:00Z");
    assert_eq!(gamma_cols[2], "kitty 0.43.0");
    assert_eq!(gamma_cols[3], "1 window(s)");

    // beta has three tabs of one window each → 3 windows total.
    let beta_cols: Vec<&str> = lines[1].split('\t').collect();
    assert_eq!(beta_cols[3], "3 window(s)");

    // alpha has one tab of two windows → 2 windows total.
    let alpha_cols: Vec<&str> = lines[2].split('\t').collect();
    assert_eq!(alpha_cols[3], "2 window(s)");
}

#[test]
fn list_empty_sessions_dir_exits_zero_with_no_output() {
    let dir = tempdir().unwrap();
    let out = run_list(dir.path());
    assert!(out.status.success(), "empty list must exit 0");
    assert!(
        out.stdout.is_empty(),
        "empty list must print nothing, got: {}",
        String::from_utf8_lossy(&out.stdout)
    );
}

#[test]
fn list_missing_sessions_dir_exits_zero() {
    // Point KITTY_PROJECT_SESSIONS_DIR at a path that doesn't exist;
    // list must treat absent-dir as "no sessions" and exit 0, not error.
    let dir = tempdir().unwrap();
    let missing = dir.path().join("does-not-exist");
    let out = run_list(&missing);
    assert!(
        out.status.success(),
        "missing dir must exit 0, got stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(out.stdout.is_empty());
}

#[test]
fn list_includes_broken_manifest_row_with_marker() {
    let dir = tempdir().unwrap();
    let sessions_dir = dir.path();

    // One healthy save.
    write_session(
        sessions_dir,
        "good",
        1_700_000_000_000_000,
        "2026-05-22T08:00:00Z",
        "kitty 0.43.0",
        &[1],
    );

    // One conf with no sidecar at all.
    fs::write(
        sessions_dir.join("orphan.conf"),
        "# Description: orphan conf with no manifest\n",
    )
    .unwrap();

    // One conf whose manifest exists but is unparseable JSON.
    let busted_state = sessions_dir.join("busted.gen-1700000000000001.state");
    fs::create_dir_all(&busted_state).unwrap();
    fs::write(busted_state.join("manifest.json"), "{not valid json").unwrap();
    fs::write(
        sessions_dir.join("busted.conf"),
        "# Description: busted save\n\
         launch --hold nvim -S busted.gen-1700000000000001.state/foo\n",
    )
    .unwrap();

    let out = run_list(sessions_dir);
    assert!(
        out.status.success(),
        "broken sidecar must not abort: stderr={}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8(out.stdout).unwrap();
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(
        lines.len(),
        3,
        "expected 3 rows (1 healthy + 2 broken), got:\n{stdout}"
    );

    // Healthy row appears first (sort puts None-created_at last).
    assert!(lines[0].starts_with("good\t"), "got: {}", lines[0]);
    assert!(!lines[0].contains("(no manifest)"));

    // Both broken rows carry the `(no manifest)` marker.
    let broken_lines: Vec<&str> = lines[1..].to_vec();
    let names: Vec<&str> = broken_lines
        .iter()
        .map(|l| l.split('\t').next().unwrap())
        .collect();
    assert!(names.contains(&"orphan"), "missing orphan in {names:?}");
    assert!(names.contains(&"busted"), "missing busted in {names:?}");
    for line in &broken_lines {
        assert!(
            line.contains("(no manifest)"),
            "broken row missing marker: {line}"
        );
    }
}
