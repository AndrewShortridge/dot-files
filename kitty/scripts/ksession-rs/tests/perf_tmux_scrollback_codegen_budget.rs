//! Performance benchmark: tmux restore.sh codegen with scrollback replay.
//!
//! Measures the delta between generating a `restore.sh` for a 3-window x
//! 3-pane tmux session with scrollback file paths vs without. The
//! scrollback-aware codegen wraps each pane's command in a `/bin/sh -c`
//! file-existence-guarded `cat` prefix; this benchmark ensures the
//! overhead stays within budget.
//!
//! Run with:
//!   cargo test --release --test perf_tmux_scrollback_codegen_budget -- --ignored --nocapture

use std::path::PathBuf;
use std::time::Instant;

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

const ITERATIONS: usize = 30;
const WINDOW_COUNT: usize = 3;
const PANES_PER_WINDOW: usize = 3;

fn build_script(with_scrollback: bool) -> RestoreScript {
    let mut windows = Vec::new();
    for w in 0..WINDOW_COUNT {
        let mut panes = Vec::new();
        for p in 0..PANES_PER_WINDOW {
            panes.push(RestorePane {
                uid: format!("{}", w * PANES_PER_WINDOW + p),
                idx: p as u32,
                cwd: format!("/home/u/proj{w}"),
                cmd: None,
                scrollback_path: if with_scrollback {
                    Some(PathBuf::from(format!(
                        "/tmp/state/tmux/sess/win-{w}/pane-{p}/scrollback.ansi"
                    )))
                } else {
                    None
                },
            });
        }
        windows.push(RestoreWindow {
            idx: w as u32,
            name: format!("win{w}"),
            layout: format!("abcd,80x24,0,0,{w}"),
            active: w == 0,
            panes,
            active_pane_idx: Some(0),
        });
    }
    RestoreScript {
        session: "bench".to_string(),
        windows,
        active_pane: Some((0, 0)),
    }
}

#[test]
#[ignore = "performance benchmark - run manually with --ignored"]
fn perf_tmux_scrollback_codegen_budget() {
    let with_sb = build_script(true);
    let without_sb = build_script(false);

    // Sanity check: the with-scrollback variant emits scrollback replay commands.
    let out_with = render_restore_sh(&with_sb);
    let out_without = render_restore_sh(&without_sb);
    assert!(
        out_with.contains("scrollback.ansi"),
        "scrollback path must appear in with-scrollback output"
    );
    assert!(
        !out_without.contains("scrollback"),
        "scrollback must not appear in without-scrollback output"
    );

    let mut deltas = Vec::new();
    for i in 0..ITERATIONS {
        let t0 = Instant::now();
        let _ = render_restore_sh(&with_sb);
        let with_time = t0.elapsed();

        let t1 = Instant::now();
        let _ = render_restore_sh(&without_sb);
        let without_time = t1.elapsed();

        if i > 0 {
            // Skip the first iteration (warm-up).
            deltas.push(with_time.saturating_sub(without_time));
        }
    }

    deltas.sort();
    let p50 = deltas[deltas.len() / 2];

    println!(
        "tmux scrollback codegen delta: p50 = {:?}, min = {:?}, max = {:?}",
        p50,
        deltas.first().unwrap(),
        deltas.last().unwrap()
    );

    assert!(
        p50.as_millis() <= 2,
        "tmux scrollback codegen delta p50 = {:?}, budget = 2ms",
        p50
    );
}
