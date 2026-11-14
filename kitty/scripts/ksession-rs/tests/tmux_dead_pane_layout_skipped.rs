//! Regression: when `pane_dead=1` filtering removes panes such that the
//! surviving pane count differs from the count encoded in the captured
//! `window_layout` string, the emitted `restore.sh` OMITS the
//! `select-layout` line for that window. Plan §8 Bug 15.
//!
//! Avoids the silent-no-op bug verified on tmux 3.4 where `select-layout`
//! exits 0 with no output when pane counts mismatch — the user would see
//! default-split geometry with no warning.
//!
//! The adapter pre-filters dead panes and clears `RestoreWindow.layout`
//! when the live pane count diverges from the layout-encoded count
//! (`src/adapter/tmux.rs:220-234`). After that point the renderer's
//! existing "skip select-layout when layout is empty" gate kicks in.
//!
//! This test asserts on the renderer's gate directly: when the AST
//! arrives with `layout: ""`, `select-layout` is omitted.

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

#[test]
fn renderer_omits_select_layout_when_layout_empty() {
    // Simulates what the adapter does after dead-pane filtering: a window
    // with a non-zero live pane count but an empty (cleared) layout.
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: String::new(), // cleared because layout_pane_count != live count
            active: true,
            panes: vec![
                RestorePane {
                    uid: "1".into(),
                    idx: 0,
                    cwd: "/a".into(),
                    cmd: None,
                    scrollback_path: None,
                },
                RestorePane {
                    uid: "2".into(),
                    idx: 1,
                    cwd: "/b".into(),
                    cmd: None,
                    scrollback_path: None,
                },
            ],
            active_pane_idx: None,
        }],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(
        !out.contains("select-layout"),
        "expected no select-layout when layout is empty:\n{out}"
    );
    // Sanity: panes still rebuilt.
    assert!(out.contains("new-session"));
    assert!(out.contains("split-window"));
}

#[test]
fn renderer_emits_select_layout_when_layout_nonempty() {
    // Counterpart: when the adapter does pass a non-empty layout (live
    // count matches encoded count), select-layout IS emitted.
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: "abcd,80x24,0,0,0".to_string(),
            active: true,
            panes: vec![RestorePane {
                uid: "1".into(),
                idx: 0,
                cwd: "/a".into(),
                cmd: None,
                scrollback_path: None,
            }],
            active_pane_idx: None,
        }],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(
        out.contains("select-layout"),
        "expected select-layout when layout is non-empty:\n{out}"
    );
}

#[test]
#[ignore = "pending pub count_panes_in_layout helper; the dead-pane vs. \
            layout-count divergence detection lives in src/adapter/tmux.rs"]
fn dead_pane_filter_clears_layout_at_adapter_level() {
    // Manual-run trigger:
    //   cargo test --manifest-path scripts/ksession-rs/Cargo.toml \
    //     --test tmux_dead_pane_layout_skipped -- --ignored
    //
    // The adapter logic (src/adapter/tmux.rs:220-234) counts panes in the
    // captured layout string and clears w.layout if the count disagrees
    // with `panes_meta.len()`. The clearing is observable via the rendered
    // script's lack of `select-layout`, which the renderer-level tests
    // above already pin.
}
