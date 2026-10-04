//! Integration test: bash cross-process tracing for restore.sh
//!
//! Validates that the generated restore.sh sources `ksession-trace-lib.sh`
//! and, when `KSESSION_TRACE_DIR` is set, each `tmux` call emits a JSONL
//! trace event into `<trace_dir>/tmux-<sess>.jsonl`.
//!
//! The test does NOT spawn a real tmux server — it exercises the generated
//! script's trace-lib integration by:
//! 1. Rendering a RestoreScript via `render_restore_sh`.
//! 2. Verifying the generated script contains `__trace_run` wrappers.
//! 3. Running a standalone bash snippet that sources the trace lib and
//!    exercises `__trace_run`, verifying JSONL output.

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};
use std::io::Read;
use tempfile::TempDir;

/// Helper: build a two-window, three-pane RestoreScript.
fn fixture_restore_script() -> RestoreScript {
    RestoreScript {
        session: "integ-test".to_string(),
        windows: vec![
            RestoreWindow {
                idx: 0,
                name: "editor".to_string(),
                layout: "abcd,80x24,0,0,0".to_string(),
                active: true,
                panes: vec![
                    RestorePane {
                        uid: "1".into(),
                        idx: 0,
                        cwd: "/home/u/project".into(),
                        cmd: Some("nvim -S /tmp/s.vim".into()),
                        scrollback_path: None,
                    },
                    RestorePane {
                        uid: "2".into(),
                        idx: 1,
                        cwd: "/home/u/project".into(),
                        cmd: None,
                        scrollback_path: None,
                    },
                ],
                active_pane_idx: Some(0),
            },
            RestoreWindow {
                idx: 1,
                name: "shell".to_string(),
                layout: "ef01,80x24,0,0,1".to_string(),
                active: false,
                panes: vec![RestorePane {
                    uid: "3".into(),
                    idx: 0,
                    cwd: "/tmp".into(),
                    cmd: None,
                    scrollback_path: None,
                }],
                active_pane_idx: Some(0),
            },
        ],
        active_pane: Some((0, 0)),
    }
}

#[test]
fn generated_script_contains_trace_wrappers() {
    let script = render_restore_sh(&fixture_restore_script());

    // Source line present.
    assert!(
        script.contains("source \"$KSESSION_TRACE_LIB\""),
        "trace lib not sourced:\n{script}"
    );

    // Count __trace_run invocations. Expected:
    //   1 new-session, 1 split-window, 1 new-window = 3 pane creation calls
    //   2 select-layout (one per window)
    //   2 select-pane (one per window with active_pane_idx)
    //   1 select-window (session-level)
    //   1 kill-session (in the stale-session guard)
    //   1 attach-session (final exec)
    //   = 11 total
    let count = script.matches("__trace_run").count();
    // The stub fallback definition also contains __trace_run, so subtract 1.
    let trace_call_count = count - 1;
    assert!(
        trace_call_count >= 8,
        "expected at least 8 __trace_run calls in generated script, got {trace_call_count}:\n{script}"
    );
}

#[test]
fn generated_script_sets_trace_sess() {
    let script = render_restore_sh(&fixture_restore_script());
    assert!(
        script.contains("KSESSION_TRACE_SESS=\"$SESS\""),
        "KSESSION_TRACE_SESS not set:\n{script}"
    );
}

#[test]
fn trace_lib_smoke_via_bash() {
    // Run a bash snippet that sources the trace lib and exercises
    // __trace_run, then verify the JSONL output.
    let trace_dir = TempDir::new().expect("tempdir");
    let trace_lib = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("scripts")
        .join("ksession-trace-lib.sh");

    let script = format!(
        r#"#!/bin/bash
set -euo pipefail
export KSESSION_TRACE_DIR="{trace_dir}"
export KSESSION_TRACE_SESS="integ"
source "{trace_lib}"
__trace_run "tmux.new-session" '{{"session":"demo"}}' true
__trace_run "tmux.select-layout" '{{}}' true
__trace_run "tmux.select-pane" '{{}}' true
"#,
        trace_dir = trace_dir.path().display(),
        trace_lib = trace_lib.display(),
    );

    let output = std::process::Command::new("bash")
        .arg("-c")
        .arg(&script)
        .output()
        .expect("bash execution");
    assert!(
        output.status.success(),
        "bash failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let jsonl_path = trace_dir.path().join("tmux-integ.jsonl");
    assert!(
        jsonl_path.exists(),
        "JSONL file not created at {}",
        jsonl_path.display()
    );

    let mut contents = String::new();
    std::fs::File::open(&jsonl_path)
        .expect("open jsonl")
        .read_to_string(&mut contents)
        .expect("read jsonl");

    let lines: Vec<&str> = contents.lines().collect();
    assert_eq!(
        lines.len(),
        3,
        "expected 3 trace events, got {}:\n{contents}",
        lines.len()
    );

    // Validate each line is valid JSON with expected fields.
    for (i, line) in lines.iter().enumerate() {
        let v: serde_json::Value = serde_json::from_str(line)
            .unwrap_or_else(|e| panic!("line {i} not valid JSON: {e}: {line}"));
        assert_eq!(v["ph"], "X", "line {i}: ph must be X");
        assert!(v["ts"].is_number(), "line {i}: ts must be numeric");
        assert!(v["dur"].is_number(), "line {i}: dur must be numeric");
        assert!(v["pid"].is_number(), "line {i}: pid must be numeric");
    }

    // Verify first event name.
    let first: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
    assert_eq!(first["name"], "tmux.new-session");
    assert_eq!(first["args"]["session"], "demo");
}

#[test]
fn trace_lib_noop_when_env_unset() {
    // With KSESSION_TRACE_DIR unset, no files should be created.
    let trace_dir = TempDir::new().expect("tempdir");
    let trace_lib = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("scripts")
        .join("ksession-trace-lib.sh");

    let script = format!(
        r#"#!/bin/bash
set -euo pipefail
unset KSESSION_TRACE_DIR
export KSESSION_TRACE_SESS="noop"
source "{trace_lib}"
__trace_run "tmux.noop" '{{}}' true
# Verify the trace dir is empty.
if ls "{trace_dir}"/tmux-*.jsonl 2>/dev/null | grep -q .; then
    echo "UNEXPECTED: JSONL file created when KSESSION_TRACE_DIR unset" >&2
    exit 1
fi
"#,
        trace_lib = trace_lib.display(),
        trace_dir = trace_dir.path().display(),
    );

    let output = std::process::Command::new("bash")
        .arg("-c")
        .arg(&script)
        .output()
        .expect("bash execution");
    assert!(
        output.status.success(),
        "bash failed (should be no-op): {}",
        String::from_utf8_lossy(&output.stderr)
    );

    // Double-check from Rust side: no jsonl files.
    let entries: Vec<_> = std::fs::read_dir(trace_dir.path())
        .expect("read trace dir")
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().map(|x| x == "jsonl").unwrap_or(false))
        .collect();
    assert!(
        entries.is_empty(),
        "no JSONL files should exist when tracing is off, found: {:?}",
        entries.iter().map(|e| e.path()).collect::<Vec<_>>()
    );
}
