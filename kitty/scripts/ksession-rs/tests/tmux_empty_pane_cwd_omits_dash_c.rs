//! Regression: when `pane_current_path` is empty, the generated
//! `new-session` / `new-window` / `split-window` line omits the `-c <cwd>`
//! flag. Tmux 3.4 accepts `-c ''` but the result is server-cwd, which is
//! non-deterministic; omission is preferred. Plan §8 Bug 4.

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

fn mk_window(idx: u32, panes: Vec<RestorePane>) -> RestoreWindow {
    RestoreWindow {
        idx,
        name: format!("w{idx}"),
        layout: String::new(),
        active: false,
        panes,
        active_pane_idx: None,
    }
}

fn pane(idx: u32, cwd: &str) -> RestorePane {
    RestorePane {
        uid: format!("{idx}"),
        idx,
        cwd: cwd.to_string(),
        cmd: None,
        scrollback_path: None,
    }
}

#[test]
fn empty_cwd_omits_dash_c_on_new_session() {
    let rs = RestoreScript {
        session: "s".to_string(),
        windows: vec![mk_window(0, vec![pane(0, "")])],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(
        !out.contains("-c ''"),
        "expected no -c '' anywhere, got:\n{out}"
    );
    let line = out
        .lines()
        .find(|l| l.contains("new-session"))
        .expect("new-session line present");
    assert!(
        !line.contains(" -c "),
        "expected no -c flag on the new-session line, got: {line}"
    );
}

#[test]
fn empty_cwd_omits_dash_c_on_new_window() {
    let rs = RestoreScript {
        session: "s".to_string(),
        windows: vec![
            mk_window(0, vec![pane(0, "/home/u")]),
            mk_window(1, vec![pane(0, "")]),
        ],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(!out.contains("-c ''"), "got:\n{out}");
    let line = out
        .lines()
        .find(|l| l.contains("new-window"))
        .expect("new-window line present");
    assert!(
        !line.contains(" -c "),
        "expected no -c flag on the new-window line, got: {line}"
    );
}

#[test]
fn empty_cwd_omits_dash_c_on_split_window() {
    let rs = RestoreScript {
        session: "s".to_string(),
        windows: vec![mk_window(0, vec![pane(0, "/home/u"), pane(1, "")])],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(!out.contains("-c ''"), "got:\n{out}");
    let line = out
        .lines()
        .find(|l| l.contains("split-window"))
        .expect("split-window line present");
    assert!(
        !line.contains(" -c "),
        "expected no -c flag on the split-window line, got: {line}"
    );
}

#[test]
fn nonempty_cwd_still_emits_dash_c() {
    let rs = RestoreScript {
        session: "s".to_string(),
        windows: vec![mk_window(0, vec![pane(0, "/var/log")])],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(
        out.contains("-c /var/log"),
        "expected -c /var/log, got:\n{out}"
    );
}
