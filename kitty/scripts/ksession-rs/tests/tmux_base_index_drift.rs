//! Regression: a session captured under `base-index 0` and restored under
//! `base-index 1` (or vice versa) survives via the `move-window` mitigation.
//! The emitted `restore.sh` includes (per plan §5.4 "move-window base-index
//! 0 edge case"):
//!
//! ```sh
//! TMUX_BASE_INDEX=$(tmux show-options -v -t "=$SESS" base-index 2>/dev/null \
//!                   || tmux show-options -gv base-index 2>/dev/null \
//!                   || echo 0)
//! TMUX_BASE_INDEX=${TMUX_BASE_INDEX:-0}
//! if [[ "<captured_first_idx>" -gt "$TMUX_BASE_INDEX" ]]; then
//!   tmux move-window -s "=$SESS:" -t "=$SESS:<captured_first_idx>" 2>/dev/null || true
//! fi
//! ```
//!
//! Three correctness properties this enforces, all derived from `cmd-find.c`
//! and `move-window` behavior in tmux source:
//!
//! 1. **`=` exact-match prefix** on both `-s` and `-t` (plan §5.4 Bug 3) —
//!    so the move can't address a different session sharing a name prefix.
//! 2. **Skip when captured == base** — `move-window` to the same index
//!    returns `"same index: <N>"` (non-fatal but spammy). The
//!    `-gt "$TMUX_BASE_INDEX"` arithmetic guard short-circuits.
//! 3. **Skip when captured < base** — `move-window` to an index below the
//!    restore-time `base-index` is rejected with `"index out of range"`.
//!    Without the guard, `set -e` would abort the entire restore. The
//!    `-gt "$TMUX_BASE_INDEX"` guard handles this branch too (since
//!    `captured < base` ⟹ `captured -gt base` is false).
//!
//! Without the mitigation, `new-window -t :<captured_idx>` would error with
//! `index in use` when the target server's base-index differs from the
//! capture-time base-index.

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

fn mk_pane() -> RestorePane {
    RestorePane {
        uid: "1".to_string(),
        idx: 0,
        cwd: "/home/u".to_string(),
        cmd: None,
        scrollback_path: None,
    }
}

#[test]
fn move_window_guard_emits_show_options_chain() {
    // The TMUX_BASE_INDEX show-options chain must appear before any move-window
    // line. Without it the arithmetic guard would compare against an empty
    // variable and bash `set -u` would abort.
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 1,
            name: "main".to_string(),
            layout: String::new(),
            active: true,
            panes: vec![mk_pane()],
            active_pane_idx: None,
        }],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(
        out.contains(r#"TMUX_BASE_INDEX=$(tmux show-options -v -t "=$SESS" base-index"#),
        "expected per-session TMUX_BASE_INDEX show-options chain, got:\n{out}"
    );
    assert!(
        out.contains(r#"tmux show-options -gv base-index"#),
        "expected global fallback in show-options chain, got:\n{out}"
    );
    assert!(
        out.contains("TMUX_BASE_INDEX=${TMUX_BASE_INDEX:-0}"),
        "expected ${{TMUX_BASE_INDEX:-0}} param expansion fallback (covers \
         show-options exit=0/empty-stdout case), got:\n{out}"
    );
}

#[test]
fn captured_first_idx_one_emits_guarded_move_window() {
    // Capture-time first window was index 1 (typical of base-index=1 configs).
    // On a base-index=0 server, the bootstrap new-session creates window 0;
    // the guard fires (1 > 0) and emits a `move-window -t "=$SESS:1"` with
    // `=` exact-match and `|| true` defensive swallow.
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 1,
            name: "main".to_string(),
            layout: String::new(),
            active: true,
            panes: vec![mk_pane()],
            active_pane_idx: None,
        }],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(
        out.contains(r#"if [[ "1" -gt "$TMUX_BASE_INDEX" ]]; then"#),
        "expected arithmetic guard `[[ \"1\" -gt $TMUX_BASE_INDEX ]]`, got:\n{out}"
    );
    assert!(
        out.contains(r#"tmux move-window -s "=$SESS:" -t "=$SESS:1" 2>/dev/null || true"#),
        "expected move-window with `=` exact-match prefix on both -s and -t, \
         and `|| true` to swallow non-fatal errors, got:\n{out}"
    );
}

#[test]
fn captured_first_idx_zero_skips_via_guard() {
    // Capture-time first window was index 0. The guard `0 -gt
    // $TMUX_BASE_INDEX` is false for both base-index=0 (skip, same index —
    // avoids the "same index" non-fatal error) and base-index=1 (skip,
    // destination below base — avoids the "index out of range" error that
    // would `set -e`-abort the restore). The move-window LINE is still in
    // the emitted script (one branch of the `if`); the GUARD prevents it
    // from firing at runtime when captured_idx == 0.
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: String::new(),
            active: true,
            panes: vec![mk_pane()],
            active_pane_idx: None,
        }],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    assert!(
        out.contains(r#"if [[ "0" -gt "$TMUX_BASE_INDEX" ]]; then"#),
        "expected arithmetic guard `[[ \"0\" -gt $TMUX_BASE_INDEX ]]` \
         (false at runtime ⟹ move-window skipped), got:\n{out}"
    );
}

#[test]
fn move_window_appears_after_new_session() {
    // Ordering: the guarded move-window block must come AFTER new-session
    // so the source target spec `"=$SESS:"` (the just-created window) is
    // valid.
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 1,
            name: "main".to_string(),
            layout: String::new(),
            active: true,
            panes: vec![mk_pane()],
            active_pane_idx: None,
        }],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    let ns = out.find("new-session").expect("new-session present");
    let mw = out.find("move-window").expect("move-window present");
    assert!(mw > ns, "move-window must follow new-session:\n{out}");
    // The TMUX_BASE_INDEX chain must also follow new-session — otherwise
    // `show-options -v -t "=$SESS"` would query a non-existent session and
    // fall through to the global, hiding per-session overrides.
    let tbi = out
        .find("TMUX_BASE_INDEX=")
        .expect("TMUX_BASE_INDEX assignment present");
    assert!(
        tbi > ns,
        "TMUX_BASE_INDEX assignment must follow new-session so the per-session \
         show-options lookup sees the session, got:\n{out}"
    );
}
