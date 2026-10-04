//! Regression: the collision-check preamble uses the literal `=` exact-match
//! target syntax — `tmux has-session -t "=$SESS"`,
//! `attach-session -t "=$SESS"`, `kill-session -t "=$SESS"`. Plan §8 Bug 7.
//!
//! Without the `=` prefix, `has-session -t prod` against a live session
//! `production` would spuriously detect collision (tmux falls back to
//! prefix-match on the target spec), and a `kill-session -t prod` under
//! `KSESSION_FORCE=1` would destroy `production`.

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

fn mk_script() -> RestoreScript {
    RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: String::new(),
            active: true,
            panes: vec![RestorePane {
                uid: "1".to_string(),
                idx: 0,
                cwd: "/home/u".to_string(),
                cmd: None,
                scrollback_path: None,
            }],
            active_pane_idx: Some(0),
        }],
        active_pane: Some((0, 0)),
    }
}

#[test]
fn has_session_uses_exact_match() {
    let out = render_restore_sh(&mk_script());
    assert!(
        out.contains(r#"has-session -t "=$SESS""#),
        "expected `has-session -t \"=$SESS\"` (exact match), got:\n{out}"
    );
    // Regression guard: no plain `-t "$SESS"` for has-session.
    assert!(
        !out.contains(r#"has-session -t "$SESS""#),
        "non-exact has-session regressed; got:\n{out}"
    );
}

#[test]
fn attach_session_uses_exact_match() {
    let out = render_restore_sh(&mk_script());
    // The live-session attach path inside the collision branch uses exact match.
    assert!(
        out.contains(r#"attach-session -t "=$SESS""#),
        "expected `attach-session -t \"=$SESS\"`, got:\n{out}"
    );
}

#[test]
fn kill_session_uses_exact_match() {
    let out = render_restore_sh(&mk_script());
    assert!(
        out.contains(r#"kill-session -t "=$SESS""#),
        "expected `kill-session -t \"=$SESS\"`, got:\n{out}"
    );
    assert!(
        !out.contains(r#"kill-session -t "$SESS""#),
        "non-exact kill-session regressed (would destroy `production` for SESS=prod); \
         got:\n{out}"
    );
}
