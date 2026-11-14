//! Regression: the emitted `restore.sh` has mode 0o755 set, and the kitty
//! `.conf` `launch` line invokes it as `/bin/bash <restore_sh>` (NOT bare
//! `bash`, NOT shebang-only). Plan §8 Bug 5.
//!
//! Two layers under test:
//!  1. The conf renderer's `launch` line for `Program::Tmux` — exercised
//!     here via `conf::render` with a stubbed skeleton.
//!  2. The on-disk mode after the adapter has written `restore.sh` —
//!     exercised by adapter unit tests (which create a TempDir + stub
//!     TmuxIo). The integration-test layer doesn't have a pub adapter
//!     fixture; that path is `#[ignore]`'d here.

use ksession_rs::adapter::chmod_executable;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use tempfile::tempdir;

use chrono::{TimeZone, Utc};
use ksession_rs::conf::render;
use ksession_rs::model::{OsWindow, Program, SessionFile, Tab, Window};

#[test]
fn launch_line_invokes_via_bin_bash() {
    let skel = "new_tab\nlayout splits\nlaunch 'kitty-unserialize-data={\"id\": 42}'\n";
    let session = SessionFile {
        name: "tmux-perms".into(),
        created_at: Utc.with_ymd_and_hms(2026, 5, 22, 12, 0, 0).unwrap(),
        schema: 1,
        kitty_version: String::new(),
        os_windows: vec![OsWindow {
            tabs: vec![Tab {
                title: None,
                layout: "splits".into(),
                active_window_idx: 0,
                windows: vec![Window {
                    kitty_id: 42,
                    ksession_id: "uid-42".into(),
                    cwd: None,
                    program: Program::Tmux {
                        session_name: "work".into(),
                        restore_sh: PathBuf::from("/tmp/state/tmux/work/restore.sh"),
                        windows: vec![],
                        session_id: 0,
                        active_window_idx: None,
                    },
                    scrollback: None,
                }],
            }],
        }],
    };
    let out = render(skel, &session).expect("render");
    assert!(
        out.contains("/bin/bash /tmp/state/tmux/work/restore.sh"),
        "expected `/bin/bash <restore_sh>`, got:\n{out}"
    );
    // Negative: no bare `bash <path>` (without /bin/ prefix), and no shebang-only
    // invocation (i.e. the script alone with no interpreter).
    let launch_line = out
        .lines()
        .find(|l| l.starts_with("launch ") && l.contains("restore.sh"))
        .expect("launch line for tmux present");
    assert!(
        launch_line.contains("/bin/bash"),
        "expected absolute /bin/bash, got: {launch_line}"
    );
    // The launch line must not invoke the script directly without an interpreter:
    // `launch /tmp/state/tmux/work/restore.sh` (no /bin/bash before it) would be
    // shebang-only.
    let bad = "launch /tmp/state/tmux/work/restore.sh";
    assert!(
        !launch_line.starts_with(bad) || launch_line.contains("/bin/bash"),
        "shebang-only invocation regressed: {launch_line}"
    );
}

#[cfg(unix)]
#[test]
fn restore_sh_mode_is_0o755() {
    // The adapter writes restore.sh via fsx::write_atomic, then calls
    // chmod_executable which ORs in 0o111. The starting mode from
    // write_atomic is 0o644 → final mode 0o755.
    let dir = tempdir().expect("tempdir");
    let script_path = dir.path().join("restore.sh");

    // Create a file with default permissions (0o644)
    std::fs::write(&script_path, "#!/bin/bash\necho test").expect("write script");

    // Apply chmod_executable
    chmod_executable(&script_path);

    // Verify the permissions are now 0o755
    let meta = std::fs::metadata(&script_path).expect("metadata");
    let mode = meta.permissions().mode() & 0o777;
    assert_eq!(
        mode, 0o755,
        "restore.sh should have mode 0o755, got {:#o}",
        mode
    );
}
