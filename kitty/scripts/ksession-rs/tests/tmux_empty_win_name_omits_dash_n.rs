//! Regression: when a window's `#{window_name}` is empty, the generated
//! `new-session` / `new-window` line omits the `-n <name>` flag entirely
//! (does not emit `-n ''`). Plan §8 Bug 3.
//!
//! Asserts on the string output of the public codegen entry-point
//! [`render_restore_sh`].

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

fn mk_window(idx: u32, name: &str) -> RestoreWindow {
    RestoreWindow {
        idx,
        name: name.to_string(),
        layout: String::new(),
        active: idx == 0,
        panes: vec![RestorePane {
            uid: format!("{idx}"),
            idx: 0,
            cwd: "/home/u".to_string(),
            cmd: None,
            scrollback_path: None,
        }],
        active_pane_idx: None,
    }
}

#[test]
fn empty_window_name_omits_dash_n_on_new_session() {
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![mk_window(0, "")],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    // The new-session line must be present...
    assert!(
        out.contains("tmux new-session -d -s \"$SESS\""),
        "expected new-session line, got:\n{out}"
    );
    // ...but without a -n flag pointing at an empty quoted literal.
    assert!(
        !out.contains("-n ''"),
        "expected no -n '' (empty -n flag), got:\n{out}"
    );
    // And the entire `-n ` substring should be absent for this window's line.
    let new_session_line = out
        .lines()
        .find(|l| l.contains("new-session"))
        .expect("new-session line present");
    assert!(
        !new_session_line.contains(" -n "),
        "expected no -n flag on the new-session line, got: {new_session_line}"
    );
}

#[test]
fn empty_window_name_omits_dash_n_on_new_window() {
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![mk_window(0, "first"), mk_window(1, "")],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(
        !out.contains("-n ''"),
        "expected no -n '' anywhere, got:\n{out}"
    );
    let new_window_line = out
        .lines()
        .find(|l| l.contains("new-window"))
        .expect("new-window line present");
    assert!(
        !new_window_line.contains(" -n "),
        "expected no -n flag on the new-window line, got: {new_window_line}"
    );
}

#[test]
fn nonempty_window_name_still_emits_dash_n() {
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![mk_window(0, "main")],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(
        out.contains("-n main"),
        "expected -n main on the new-session line, got:\n{out}"
    );
}
