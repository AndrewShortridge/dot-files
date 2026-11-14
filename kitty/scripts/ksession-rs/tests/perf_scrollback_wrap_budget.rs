//! Performance benchmark: conf.render scrollback-wrap overhead.
//!
//! Measures the delta between rendering a 12-shell-window session with
//! scrollback paths populated vs all-None. The scrollback wrap injects a
//! `cat <path> 2>/dev/null;` prefix into each shell's `-c` command chain;
//! this benchmark ensures the overhead stays within budget.
//!
//! Run with:
//!   cargo test --release --test perf_scrollback_wrap_budget -- --ignored --nocapture

use std::path::PathBuf;
use std::time::Instant;

use chrono::{TimeZone, Utc};

use ksession_rs::conf::render;
use ksession_rs::model::{OsWindow, Program, SessionFile, ShellKind, Tab, Window};

const ITERATIONS: usize = 30;
const WINDOWS: usize = 12;

/// Build a skeleton string with `n` launch lines carrying unserialize-data
/// tokens for kitty_ids `1..=n`.
fn build_skeleton(n: usize) -> String {
    let mut s = String::from("new_tab bench\nlayout splits\nenabled_layouts splits,stack\n");
    for id in 1..=n {
        s.push_str(&format!(
            "cd /home/user/proj{id}\nlaunch 'kitty-unserialize-data={{\"id\": {id}}}' /bin/bash -l\n"
        ));
    }
    s.push_str("focus\nfocus_tab 0\n");
    s
}

/// Build a `SessionFile` with `n` shell windows. When `with_scrollback` is
/// true, each window's `Program::Shell.scrollback` points to a synthetic
/// 50 KiB-path-string file (the renderer doesn't read the file, only
/// formats the path into the `-c` command chain).
fn build_session(n: usize, with_scrollback: bool) -> SessionFile {
    let windows: Vec<Window> = (1..=n)
        .map(|id| {
            let scrollback = if with_scrollback {
                Some(PathBuf::from(format!("/tmp/scrollback_{id}_50k.ansi")))
            } else {
                None
            };
            Window {
                kitty_id: id as u64,
                ksession_id: format!("uid-{id}"),
                cwd: Some(PathBuf::from(format!("/home/user/proj{id}"))),
                program: Program::Shell {
                    shell: ShellKind::Bash,
                    venv: None,
                    conda: None,
                    direnv: None,
                    oldpwd: None,
                    scrollback,
                    history: None,
                },
                scrollback: None,
            }
        })
        .collect();

    SessionFile {
        name: "scrollback-bench".to_string(),
        created_at: Utc.with_ymd_and_hms(2026, 5, 26, 12, 0, 0).unwrap(),
        schema: 1,
        kitty_version: String::new(),
        os_windows: vec![OsWindow {
            tabs: vec![Tab {
                title: Some("bench".to_string()),
                layout: "splits".to_string(),
                active_window_idx: 0,
                windows,
            }],
        }],
    }
}

#[test]
#[ignore = "performance benchmark - run manually with --ignored"]
fn perf_scrollback_wrap_budget() {
    let skeleton = build_skeleton(WINDOWS);
    let session_with = build_session(WINDOWS, true);
    let session_without = build_session(WINDOWS, false);

    // Sanity check: both variants render successfully.
    let out_with = render(&skeleton, &session_with).expect("render with scrollback");
    let out_without = render(&skeleton, &session_without).expect("render without scrollback");
    assert!(
        out_with.contains("cat /tmp/scrollback_1_50k.ansi 2>/dev/null"),
        "scrollback cat command must appear in with-scrollback output"
    );
    assert!(
        !out_without.contains("cat /tmp/scrollback_"),
        "scrollback cat command must not appear in without-scrollback output"
    );

    let mut deltas = Vec::new();
    for i in 0..ITERATIONS {
        let t0 = Instant::now();
        let _ = render(&skeleton, &session_with).unwrap();
        let with_time = t0.elapsed();

        let t1 = Instant::now();
        let _ = render(&skeleton, &session_without).unwrap();
        let without_time = t1.elapsed();

        if i > 0 {
            // Skip the first iteration (warm-up).
            deltas.push(with_time.saturating_sub(without_time));
        }
    }

    deltas.sort();
    let p50 = deltas[deltas.len() / 2];

    println!(
        "scrollback wrap delta: p50 = {:?}, min = {:?}, max = {:?}",
        p50,
        deltas.first().unwrap(),
        deltas.last().unwrap()
    );

    assert!(
        p50.as_millis() <= 5,
        "scrollback wrap delta p50 = {:?}, budget = 5ms",
        p50
    );
}
