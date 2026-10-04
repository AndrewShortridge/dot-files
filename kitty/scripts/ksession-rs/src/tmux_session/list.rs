//! `ksession tmux list [--porcelain]` — enumerate saved tmux-native
//! sessions.
//!
//! Two output shapes share one row model:
//!
//! - porcelain: `name\tsession_name\twindows\tpanes\tcreated_at_rfc3339`,
//!   one row per session, no header, no colour. Consumed by the tmux
//!   picker script, so the format is a contract.
//! - human: an aligned table with a header, SAVED in local time.
//!
//! A head that fails to parse is reported on stderr and skipped (ADR 0001:
//! one corrupt manifest must not hide the rest).

use std::io::Write;
use std::path::Path;

use chrono::{DateTime, Local, SecondsFormat, Utc};

use super::manifest::{self, TmuxSessionManifest};
use super::TmuxSessionError;

/// Write every readable saved session under `root` to `out`, sorted by
/// name; `porcelain` selects the tab-separated machine format over the
/// table.
pub fn run(root: &Path, porcelain: bool, out: &mut dyn Write) -> Result<(), TmuxSessionError> {
    let rows = load_rows(root)?;
    let text = if porcelain {
        render_porcelain(&rows)
    } else {
        render_human(&rows)
    };
    out.write_all(text.as_bytes())?;
    Ok(())
}

/// One list row, decoupled from the manifest so rendering is pure.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Row {
    name: String,
    session_name: String,
    windows: usize,
    panes: usize,
    created_at: DateTime<Utc>,
    has_nvim: bool,
}

impl From<&TmuxSessionManifest> for Row {
    fn from(m: &TmuxSessionManifest) -> Self {
        Self {
            name: m.name.clone(),
            session_name: m.session_name().to_owned(),
            windows: m.window_count(),
            panes: m.pane_count(),
            created_at: m.created_at,
            has_nvim: m.has_nvim(),
        }
    }
}

/// Read every head under `root` in name order. Unreadable or malformed
/// heads are reported on stderr and dropped; only the directory listing
/// itself is fatal.
fn load_rows(root: &Path) -> Result<Vec<Row>, TmuxSessionError> {
    let names = manifest::list_names(root)?;
    let mut rows = Vec::with_capacity(names.len());
    for name in names {
        match manifest::read(root, &name) {
            Ok(m) => rows.push(Row::from(&m)),
            Err(e) => eprintln!("ksession: tmux list: skipping {name}: {e}"),
        }
    }
    Ok(rows)
}

fn render_porcelain(rows: &[Row]) -> String {
    let mut out = String::new();
    for r in rows {
        out.push_str(&format!(
            "{}\t{}\t{}\t{}\t{}\n",
            r.name,
            r.session_name,
            r.windows,
            r.panes,
            r.created_at.to_rfc3339_opts(SecondsFormat::Secs, true)
        ));
    }
    out
}

const HUMAN_HEADER: [&str; 6] = ["NAME", "SESSION", "WINDOWS", "PANES", "SAVED", "NVIM"];

/// SAVED column: local wall-clock time, minute precision — what a user
/// scanning for "the one from this morning" actually wants.
fn format_saved_local(t: DateTime<Utc>) -> String {
    t.with_timezone(&Local).format("%Y-%m-%d %H:%M").to_string()
}

fn human_cells(r: &Row) -> [String; 6] {
    [
        r.name.clone(),
        r.session_name.clone(),
        r.windows.to_string(),
        r.panes.to_string(),
        format_saved_local(r.created_at),
        if r.has_nvim { "yes" } else { "-" }.to_owned(),
    ]
}

fn render_human(rows: &[Row]) -> String {
    if rows.is_empty() {
        return String::from("no saved tmux sessions\n");
    }
    let mut table: Vec<Vec<String>> = Vec::with_capacity(rows.len() + 1);
    table.push(HUMAN_HEADER.map(str::to_owned).to_vec());
    table.extend(rows.iter().map(|r| human_cells(r).to_vec()));
    render_table(&table)
}

/// Left-align every column to its widest cell with two-space gutters; the
/// last column is unpadded so lines carry no trailing whitespace.
fn render_table(table: &[Vec<String>]) -> String {
    let ncols = table.first().map_or(0, Vec::len);
    let widths: Vec<usize> = (0..ncols)
        .map(|c| {
            table
                .iter()
                .map(|row| row[c].chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    let mut out = String::new();
    for row in table {
        for (c, cell) in row.iter().enumerate() {
            if c + 1 == ncols {
                out.push_str(cell);
            } else {
                out.push_str(&format!("{cell:<w$}  ", w = widths[c]));
            }
        }
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Program, TmuxPane, TmuxWindow};
    use chrono::TimeZone;
    use std::path::PathBuf;

    fn pane(index: u32, program: Program) -> TmuxPane {
        TmuxPane {
            index,
            pane_pid: 1,
            pane_id_digits: 0,
            cwd: None,
            current_command: None,
            program: Box::new(program),
        }
    }

    fn window(idx: u32, panes: Vec<TmuxPane>) -> TmuxWindow {
        TmuxWindow {
            idx,
            name: format!("w{idx}"),
            layout: String::new(),
            active: idx == 0,
            panes,
            active_pane_idx: None,
            layout_leaf_count: 0,
        }
    }

    fn manifest_with(
        name: &str,
        session_name: &str,
        windows: Vec<TmuxWindow>,
    ) -> TmuxSessionManifest {
        TmuxSessionManifest {
            name: name.to_string(),
            created_at: Utc.with_ymd_and_hms(2026, 10, 3, 16, 58, 8).unwrap(),
            schema: manifest::CURRENT_SCHEMA,
            tmux_version: "tmux 3.4".to_string(),
            state_dir: PathBuf::from(format!("/data/{name}.gen-1.state")),
            program: Program::Tmux {
                session_name: session_name.to_string(),
                restore_sh: PathBuf::from(format!("/data/{name}.gen-1.state/tmux/restore.sh")),
                windows,
                session_id: 0,
                active_window_idx: Some(0),
            },
        }
    }

    fn nvim() -> Program {
        Program::Nvim {
            session_vim: PathBuf::from("/data/s.vim"),
            manifest: None,
            truncated_buffers: 0,
        }
    }

    fn rows() -> Vec<Row> {
        vec![
            Row::from(&manifest_with(
                "alpha",
                "dev",
                vec![
                    window(0, vec![pane(0, nvim()), pane(1, Program::BareShell)]),
                    window(1, vec![pane(0, Program::BareShell)]),
                ],
            )),
            Row::from(&manifest_with(
                "beta-long-name",
                "s",
                vec![window(0, vec![pane(0, Program::BareShell)])],
            )),
        ]
    }

    #[test]
    fn row_derives_counts_and_nvim_flag_from_manifest() {
        let rs = rows();
        assert_eq!(
            rs[0],
            Row {
                name: "alpha".into(),
                session_name: "dev".into(),
                windows: 2,
                panes: 3,
                created_at: Utc.with_ymd_and_hms(2026, 10, 3, 16, 58, 8).unwrap(),
                has_nvim: true,
            }
        );
        assert!(!rs[1].has_nvim);
    }

    #[test]
    fn porcelain_rows_are_tab_separated_without_header() {
        let text = render_porcelain(&rows());
        assert_eq!(
            text,
            "alpha\tdev\t2\t3\t2026-10-03T16:58:08Z\n\
             beta-long-name\ts\t1\t1\t2026-10-03T16:58:08Z\n"
        );
    }

    #[test]
    fn porcelain_is_empty_when_nothing_saved() {
        assert_eq!(render_porcelain(&[]), "");
    }

    #[test]
    fn human_table_is_aligned_to_widest_cell() {
        let rs = rows();
        let text = render_human(&rs);
        let saved = format_saved_local(rs[0].created_at);
        // NAME is as wide as "beta-long-name" (14); SESSION/WINDOWS/PANES
        // are as wide as their headers (7/7/5); SAVED as wide as a local
        // timestamp; NVIM (last) is unpadded.
        let line = |n: &str, s: &str, w: &str, p: &str, t: &str, v: &str| {
            format!(
                "{n:<14}  {s:<7}  {w:<7}  {p:<5}  {t:<tw$}  {v}",
                tw = saved.len()
            )
        };
        let expected = [
            line("NAME", "SESSION", "WINDOWS", "PANES", "SAVED", "NVIM"),
            line("alpha", "dev", "2", "3", &saved, "yes"),
            line("beta-long-name", "s", "1", "1", &saved, "-"),
        ];
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines, expected);
        assert!(
            lines.iter().all(|l| !l.ends_with(' ')),
            "no trailing whitespace"
        );
    }

    #[test]
    fn human_table_reports_empty_store() {
        assert_eq!(render_human(&[]), "no saved tmux sessions\n");
    }

    #[test]
    fn run_skips_corrupt_heads_and_sorts_by_name() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        manifest::write(root, &manifest_with("zeta", "z", vec![window(0, vec![])])).unwrap();
        manifest::write(root, &manifest_with("alpha", "a", vec![window(0, vec![])])).unwrap();
        std::fs::write(manifest::head_path(root, "broken"), b"{ not json").unwrap();

        let mut out = Vec::new();
        run(root, true, &mut out).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "alpha\ta\t1\t0\t2026-10-03T16:58:08Z\n\
             zeta\tz\t1\t0\t2026-10-03T16:58:08Z\n"
        );
    }

    #[test]
    fn run_human_on_empty_root_prints_placeholder() {
        let dir = tempfile::tempdir().unwrap();
        let mut out = Vec::new();
        run(dir.path(), false, &mut out).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "no saved tmux sessions\n");
    }
}
