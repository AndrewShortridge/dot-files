//! Regression: the emitted `restore.sh` emits a
//! `tmux select-pane -t "=$SESS:<win_idx>.<active_pane>"` AFTER each
//! window's `select-layout`, restoring the active pane in EVERY window
//! (not just the active window). Then a global
//! `tmux select-window -t "=$SESS:<active_win>"` selects the active window.
//! Plan §8 Bug 9/17.
//!
//! All three target uses (`select-pane`, `select-window`, plus the preamble's
//! `has-session`/`attach-session`/`kill-session`) carry the `=` exact-match
//! prefix per plan §5.4 Bug 3 so tmux's start-of-name prefix matching can't
//! address an unintended session that shares a prefix.
//!
//! Regression against the Bash overwrite bug at ksession.sh:381-382 where
//! only the last window's active pane survived assignment.
//!
//! The AST carries the per-window active-pane via
//! `RestoreWindow.active_pane_idx: Option<u32>`. The renderer emits one
//! `select-pane` per window when `active_pane_idx.is_some()`, in place
//! of the previous single global `select-pane`.

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

fn mk_pane(idx: u32) -> RestorePane {
    RestorePane {
        uid: format!("{idx}"),
        idx,
        cwd: "/home/u".to_string(),
        cmd: None,
        scrollback_path: None,
    }
}

#[test]
fn single_window_select_pane_after_select_layout() {
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: "abcd,80x24,0,0,0".to_string(),
            active: true,
            panes: vec![mk_pane(0), mk_pane(1)],
            active_pane_idx: Some(1),
        }],
        active_pane: Some((0, 1)),
    };
    let out = render_restore_sh(&rs);
    // select-pane appears after select-layout for window 0
    let layout_pos = out
        .find("select-layout -t \"$SESS:0\"")
        .expect("select-layout for win 0");
    let pane_pos = out
        .find("select-pane -t \"=$SESS:0.1\"")
        .expect("select-pane for win 0 active pane 1");
    assert!(
        pane_pos > layout_pos,
        "select-pane must follow select-layout for the same window:\n{out}"
    );
}

#[test]
fn every_window_emits_select_pane() {
    // Two windows (idxs 0 and 1) — each with their own active pane —
    // must each emit a `tmux select-pane -t "$SESS:<w>.<p>"` line. The
    // Bash overwrite bug at ksession.sh:381-382 dropped earlier windows'
    // active-pane assignments; the per-window AST field fixes this.
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![
            RestoreWindow {
                idx: 0,
                name: "left".to_string(),
                layout: "aaaa,80x24,0,0{40x24,0,0,0,39x24,41,0,1}".to_string(),
                active: false,
                panes: vec![mk_pane(0), mk_pane(1)],
                active_pane_idx: Some(0),
            },
            RestoreWindow {
                idx: 1,
                name: "right".to_string(),
                layout: "bbbb,80x24,0,0{40x24,0,0,2,39x24,41,0,3}".to_string(),
                active: true,
                panes: vec![mk_pane(2), mk_pane(3)],
                active_pane_idx: Some(3),
            },
        ],
        active_pane: Some((1, 3)),
    };
    let out = render_restore_sh(&rs);
    assert!(
        out.contains("tmux select-pane -t \"=$SESS:0.0\""),
        "expected per-window select-pane for win 0 active pane 0:\n{out}"
    );
    assert!(
        out.contains("tmux select-pane -t \"=$SESS:1.3\""),
        "expected per-window select-pane for win 1 active pane 3:\n{out}"
    );
    // Ordering: window 0's select-pane must precede window 1's
    // (per-window emissions are co-located with their select-layout).
    let p0 = out
        .find("tmux select-pane -t \"=$SESS:0.0\"")
        .expect("win 0 select-pane present");
    let p1 = out
        .find("tmux select-pane -t \"=$SESS:1.3\"")
        .expect("win 1 select-pane present");
    assert!(
        p0 < p1,
        "per-window select-pane lines must appear in window order:\n{out}"
    );
}

#[test]
fn global_select_window_after_per_window_panes() {
    // The global `select-window` (jumping to the active window) MUST come
    // after the per-window select-pane lines so it lands in the right
    // window at attach time.
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: "abcd,80x24,0,0,0".to_string(),
            active: true,
            panes: vec![mk_pane(0)],
            active_pane_idx: Some(0),
        }],
        active_pane: Some((0, 0)),
    };
    let out = render_restore_sh(&rs);
    // Both must appear, and select-window must be present.
    assert!(
        out.contains("select-window -t \"=$SESS:0\""),
        "expected select-window line, got:\n{out}"
    );
    let pane_pos = out
        .find("select-pane -t \"=$SESS:0.0\"")
        .expect("select-pane present");
    let win_pos = out
        .find("select-window -t \"=$SESS:0\"")
        .expect("select-window present");
    assert!(
        win_pos > pane_pos,
        "select-window must follow per-window select-pane:\n{out}"
    );
}
