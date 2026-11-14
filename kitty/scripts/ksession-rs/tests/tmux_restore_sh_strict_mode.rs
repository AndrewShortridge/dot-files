//! Regression: the emitted `restore.sh` begins with
//! `#!/bin/bash\nset -euo pipefail\n`. A failed `new-window` between
//! bootstrap and attach must abort (exit nonzero), not silently continue.
//! Plan §8 Bug 6.

use ksession_rs::tmux_rpc::{render_restore_sh, RestorePane, RestoreScript, RestoreWindow};

fn mk_script(windows: usize) -> RestoreScript {
    RestoreScript {
        session: "demo".to_string(),
        windows: (0..windows as u32)
            .map(|idx| RestoreWindow {
                idx,
                name: format!("w{idx}"),
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
            })
            .collect(),
        active_pane: None,
    }
}

#[test]
fn script_starts_with_bin_bash_shebang() {
    let out = render_restore_sh(&mk_script(1));
    assert!(
        out.starts_with("#!/bin/bash\n"),
        "expected `#!/bin/bash\\n` shebang, got start:\n{}",
        &out[..out.len().min(80)]
    );
}

#[test]
fn script_enables_strict_mode() {
    let out = render_restore_sh(&mk_script(1));
    assert!(
        out.contains("set -euo pipefail\n"),
        "expected `set -euo pipefail`, got:\n{out}"
    );
    // Regression guard: must not be the looser `set -e` (the previous
    // skeleton used `set -e` only, which left an unset-var bug latent).
    let head: String = out.lines().take(5).collect::<Vec<_>>().join("\n");
    assert!(
        !head.contains("\nset -e\n"),
        "lone `set -e` (missing -uo pipefail) regressed in header:\n{head}"
    );
}

#[test]
fn strict_mode_appears_before_first_tmux_command() {
    // The whole point: `set -euo pipefail` MUST execute before any
    // `tmux new-session` so a failure inside the bootstrap aborts the
    // script before it reaches `attach-session`.
    let out = render_restore_sh(&mk_script(2));
    let strict_pos = out
        .find("set -euo pipefail")
        .expect("strict mode line present");
    let first_tmux_cmd = out
        .find("tmux new-session")
        .expect("new-session line present");
    assert!(
        strict_pos < first_tmux_cmd,
        "strict mode must precede first tmux command:\n{out}"
    );
}
