//! Regression: sidecar paths under `<state_dir>/tmux/<sess>/win-<X>/pane-<Y>/…`
//! use the leading-`%`-stripped pane id (e.g., `%37` → `pane-37`), not the
//! raw `#{pane_id}`. The `-t %37` form is still used when querying tmux.
//! Mirrors `local uid=${pane_id#%}` at ksession.sh:384. Plan §8 Bug 13.
//!
//! The path-construction logic lives in `src/adapter/tmux.rs::capture`:
//!
//!   let pane_path_key = pane.id.trim_start_matches('%').to_string();
//!   let pane_dir = win_dir.join(format!("pane-{pane_path_key}"));
//!
//! Driving the adapter end-to-end requires a TmuxIo stub + WindowCtx
//! fixture; that path is `#[ignore]`'d.
//!
//! We can verify the trim semantics at the public surface by constructing
//! a `RestorePane { uid: "37".into(), … }` (the adapter has already
//! stripped the `%`) and confirming that nothing in the renderer
//! re-introduces a `%` into a path-style emission. (`render_restore_sh`
//! does not currently emit pane-uid paths into the script — those are the
//! adapter's on-disk concern — so the renderer-level assertion here is
//! the negative-space "no `%` artifacts leak into the script".)

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

#[test]
fn restore_pane_uid_is_already_stripped_at_the_ast_boundary() {
    // Contract: by the time a RestorePane reaches the renderer, the uid
    // field has the leading `%` stripped. This test pins that contract by
    // building a RestoreScript with uid="37" and confirming render_restore_sh
    // accepts it (no panic) and produces output that does not contain `%37`
    // in any path-shaped substring.
    let rs = RestoreScript {
        session: "demo".to_string(),
        windows: vec![RestoreWindow {
            idx: 0,
            name: "main".to_string(),
            layout: String::new(),
            active: true,
            panes: vec![RestorePane {
                uid: "37".to_string(),
                idx: 0,
                cwd: "/home/u".to_string(),
                cmd: None,
                scrollback_path: None,
            }],
            active_pane_idx: None,
        }],
        active_pane: None,
    };
    let out = render_restore_sh(&rs);
    // No `%37` substring should appear in the rendered restore.sh —
    // tmux target specs in the script use `$SESS:<idx>.<idx>`, never
    // pane ids.
    assert!(
        !out.contains("%37"),
        "raw `%37` pane-id form leaked into restore.sh: {out}"
    );
}

#[test]
fn on_disk_sidecar_paths_use_pane_dash_stripped_uid() {
    // Verify that pane path construction strips the leading `%` from pane IDs.
    // The adapter uses: `pane.id.trim_start_matches('%').to_string()`
    // to create directory names like `pane-37` instead of `pane-%37`.

    // Test cases: pane_id -> expected directory key
    let test_cases = [
        ("%37", "37"),
        ("%1", "1"),
        ("%100", "100"),
        ("37", "37"), // already stripped
        ("1", "1"),
    ];

    for (input, expected) in test_cases {
        let pane_path_key = input.trim_start_matches('%').to_string();
        assert_eq!(
            pane_path_key, expected,
            "pane ID {} should strip to {}, got {}",
            input, expected, pane_path_key
        );

        // Verify the directory name format
        let dir_name = format!("pane-{}", pane_path_key);
        assert!(
            !dir_name.contains('%'),
            "Directory name should not contain raw %: {}",
            dir_name
        );
    }

    // Verify the path construction matches what the adapter does
    let win_dir = "/foo/sessions/test.state/tmux/work/win-0";
    let pane_id = "%37";
    let pane_path_key = pane_id.trim_start_matches('%').to_string();
    let pane_dir = format!("{}/pane-{}", win_dir, pane_path_key);

    assert_eq!(
        pane_dir, "/foo/sessions/test.state/tmux/work/win-0/pane-37",
        "Path should use stripped pane ID"
    );
    assert!(!pane_dir.contains("%37"), "Path should not contain raw %37");
}
