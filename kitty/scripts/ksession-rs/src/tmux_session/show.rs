//! `ksession tmux show <name>` — render a saved tmux-native session as a
//! header plus a window → pane tree.
//!
//! Pure consumer of the manifest: nothing live is queried. The tree body is
//! the same renderer kitty `show` uses for a tmux window
//! ([`crate::session::show::render_tmux_windows`]) so both commands stay
//! visually identical for the same captured session; only the header
//! differs because the tmux-native store has no kitty OS window / tab
//! wrapper and instead leads with the paths a user needs to inspect or
//! hand-run the saved state.

use std::io::Write;
use std::path::Path;

use super::manifest::{self, TmuxSessionManifest};
use super::TmuxSessionError;
use crate::session::show::render_tmux_windows;

/// Load `<root>/<name>.json` and write the rendered session to `out`.
///
/// `name` is validated first so an unvalidated string never reaches a
/// path join; a missing head surfaces as [`TmuxSessionError::NotFound`].
pub fn run(root: &Path, name: &str, out: &mut dyn Write) -> Result<(), TmuxSessionError> {
    super::validate_name(name)?;
    let m = manifest::read(root, name)?;
    out.write_all(render(&m).as_bytes())?;
    Ok(())
}

/// Render the manifest: a fixed five-line header followed by the
/// window → pane tree at top level. Pure; unit-tested below.
pub(crate) fn render(m: &TmuxSessionManifest) -> String {
    let mut out = String::new();
    out.push_str(&format!("session: {}\n", m.name));
    out.push_str(&format!("tmux session: {}\n", m.session_name()));
    out.push_str(&format!(
        "saved: {}\n",
        m.created_at.format("%Y-%m-%dT%H:%M:%SZ")
    ));
    out.push_str(&format!("state: {}\n", m.state_dir.display()));
    out.push_str(&format!("restore: {}\n", m.restore_sh().display()));
    render_tmux_windows(&mut out, m.windows(), "");
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Program, TmuxPane, TmuxWindow};
    use chrono::{TimeZone, Utc};
    use std::path::PathBuf;

    fn sample() -> TmuxSessionManifest {
        TmuxSessionManifest {
            name: "work".to_string(),
            created_at: Utc.with_ymd_and_hms(2026, 10, 3, 16, 58, 8).unwrap(),
            schema: manifest::CURRENT_SCHEMA,
            tmux_version: "tmux 3.4".to_string(),
            state_dir: PathBuf::from("/data/work.gen-1.state"),
            program: Program::Tmux {
                session_name: "dev".to_string(),
                restore_sh: PathBuf::from("/data/work.gen-1.state/tmux/dev/restore.sh"),
                windows: vec![
                    TmuxWindow {
                        idx: 0,
                        name: "edit".to_string(),
                        layout: "abcd,80x24,0,0,0".to_string(),
                        active: true,
                        panes: vec![TmuxPane {
                            index: 0,
                            pane_pid: 1,
                            pane_id_digits: 0,
                            cwd: Some(PathBuf::from("/home/u/proj")),
                            current_command: Some("nvim".to_string()),
                            program: Box::new(Program::Nvim {
                                session_vim: PathBuf::from("/data/s.vim"),
                                manifest: None,
                                truncated_buffers: 0,
                            }),
                        }],
                        active_pane_idx: Some(0),
                        layout_leaf_count: 1,
                    },
                    TmuxWindow {
                        idx: 1,
                        name: "shell".to_string(),
                        layout: "efgh,80x24,0,0,1".to_string(),
                        active: false,
                        panes: vec![],
                        active_pane_idx: None,
                        layout_leaf_count: 1,
                    },
                ],
                session_id: 3,
                active_window_idx: Some(0),
            },
        }
    }

    #[test]
    fn header_lines_come_first_in_contract_order() {
        let rendered = render(&sample());
        let lines: Vec<&str> = rendered.lines().collect();
        assert_eq!(lines[0], "session: work");
        assert_eq!(lines[1], "tmux session: dev");
        assert_eq!(lines[2], "saved: 2026-10-03T16:58:08Z");
        assert_eq!(lines[3], "state: /data/work.gen-1.state");
        assert_eq!(
            lines[4],
            "restore: /data/work.gen-1.state/tmux/dev/restore.sh"
        );
    }

    #[test]
    fn tree_follows_header_at_top_level() {
        let rendered = render(&sample());
        let tree: Vec<&str> = rendered.lines().skip(5).collect();
        assert_eq!(
            tree,
            vec![
                "├── tmux window 0: \"edit\"  layout=abcd,80x24,0,0,0 (active)",
                "│   └── pane 0  [nvim]  truncated=0  cwd=/home/u/proj  cmd=nvim (active)",
                "└── tmux window 1: \"shell\"  layout=efgh,80x24,0,0,1",
            ]
        );
    }

    #[test]
    fn run_reports_not_found_for_missing_head() {
        let dir = tempfile::tempdir().unwrap();
        let mut out = Vec::new();
        let err = run(dir.path(), "ghost", &mut out).unwrap_err();
        assert!(matches!(err, TmuxSessionError::NotFound(n) if n == "ghost"));
        assert!(out.is_empty());
    }

    #[test]
    fn run_rejects_invalid_name() {
        let dir = tempfile::tempdir().unwrap();
        let mut out = Vec::new();
        let err = run(dir.path(), "a/b", &mut out).unwrap_err();
        assert!(matches!(err, TmuxSessionError::InvalidName(_)));
    }

    #[test]
    fn run_round_trips_through_manifest_on_disk() {
        let dir = tempfile::tempdir().unwrap();
        let m = sample();
        manifest::write(dir.path(), &m).unwrap();
        let mut out = Vec::new();
        run(dir.path(), "work", &mut out).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), render(&m));
    }
}
