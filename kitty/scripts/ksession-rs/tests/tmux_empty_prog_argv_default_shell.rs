//! Regression: when a shell pane has no activation context (no
//! `VIRTUAL_ENV`, no `CONDA_DEFAULT_ENV`, no `OLDPWD`), the emitted
//! `tmux new-window` / `split-window` drops the trailing program-argv
//! argument entirely, letting tmux launch its configured `default-shell`.
//! Plan §8 Bug 12.

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

fn mk_pane_no_cmd(idx: u32) -> RestorePane {
    RestorePane {
        uid: format!("{idx}"),
        idx,
        cwd: "/home/u".to_string(),
        cmd: None,
        scrollback_path: None,
    }
}

#[test]
fn first_window_no_cmd_omits_trailing_argv() {
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: String::new(),
            active: true,
            panes: vec![mk_pane_no_cmd(0)],
            active_pane_idx: None,
        }],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    let line = out
        .lines()
        .find(|l| l.contains("new-session"))
        .expect("new-session line");
    // The line ends with the -c <cwd> token; no trailing program argv.
    assert!(
        line.ends_with("-c /home/u"),
        "expected line to end at -c <cwd> with no trailing argv, got: {line}"
    );
}

#[test]
fn subsequent_window_no_cmd_omits_trailing_argv() {
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![
            RestoreWindow {
                idx: 0,
                name: "first".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![mk_pane_no_cmd(0)],
                active_pane_idx: None,
            },
            RestoreWindow {
                idx: 1,
                name: "second".to_string(),
                layout: String::new(),
                active: false,
                panes: vec![mk_pane_no_cmd(0)],
                active_pane_idx: None,
            },
        ],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    let line = out
        .lines()
        .find(|l| l.contains("new-window"))
        .expect("new-window line");
    assert!(
        line.ends_with("-c /home/u"),
        "expected new-window line to end at -c <cwd> with no trailing argv, \
         got: {line}"
    );
}

#[test]
fn extra_pane_no_cmd_omits_trailing_argv_on_split() {
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: String::new(),
            active: false,
            panes: vec![mk_pane_no_cmd(0), mk_pane_no_cmd(1)],
            active_pane_idx: None,
        }],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    let line = out
        .lines()
        .find(|l| l.contains("split-window"))
        .expect("split-window line");
    assert!(
        line.ends_with("-c /home/u"),
        "expected split-window line to end at -c <cwd> with no trailing argv, \
         got: {line}"
    );
}
