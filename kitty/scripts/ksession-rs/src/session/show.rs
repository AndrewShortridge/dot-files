//! `ksession show <name>` — render `<sessions_dir>/<name>.state/manifest.json`
//! as a tree to stdout.
//!
//! Plan §10 step 9: pure consumer of the captured `SessionFile`. No live
//! kitty state is queried for rendering; the only live call is the
//! `kitty --version` drift probe inside [`super::manifest::read`].
//!
//! [`render_tmux_windows`] is `pub(crate)` so `tmux_session::show` can
//! render the same window → pane subtree without a kitty OS-window / tab
//! wrapper and without duplicating the formatting rules; every other
//! helper stays private to this module.

use std::path::PathBuf;

use anyhow::{Context, Result};

use crate::model::{OsWindow, Program, SessionFile, Tab, TmuxPane, TmuxWindow};
use crate::session::manifest;

/// Entry point used by the binary: resolve the manifest path for `name`,
/// load + parse it via [`super::manifest::read`], emit any drift warnings
/// to stderr (ADR 0002), then print the rendered tree to stdout.
pub fn run(name: &str) -> Result<()> {
    let dir = sessions_dir()?;
    let manifest_path = dir.join(format!("{name}.state")).join("manifest.json");

    // The reader's `read` is async because the drift comparison spawns
    // `kitty --version`. `show` is otherwise sync; spin up a small
    // current-thread runtime just for this call.
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("build tokio runtime for manifest read")?;
    let loaded = rt
        .block_on(manifest::read(&manifest_path))
        .with_context(|| {
            format!(
                "could not read manifest for session '{name}' at {}",
                manifest_path.display()
            )
        })?;

    for w in &loaded.warnings {
        eprintln!("{}", w.to_stderr_line());
    }

    let rendered = render(&loaded.session);
    print!("{rendered}");
    Ok(())
}

/// Resolve the sessions directory. Delegates to [`super::save::sessions_dir`]
/// so the env-var contract (`KITTY_PROJECT_SESSIONS_DIR`) matches the Bash
/// reference (ksession.sh:26) for both subcommands.
fn sessions_dir() -> Result<PathBuf> {
    super::save::sessions_dir()
        .map_err(|e| anyhow::anyhow!("cannot resolve sessions directory: {e}"))
}

/// Render a parsed `SessionFile` as a Unicode tree. Pure; easy to unit-test.
pub fn render(session: &SessionFile) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "{}  (created {}, schema={})\n",
        session.name,
        session.created_at.format("%Y-%m-%dT%H:%M:%SZ"),
        session.schema
    ));

    let n = session.os_windows.len();
    for (i, osw) in session.os_windows.iter().enumerate() {
        let last = i + 1 == n;
        let (branch, child_prefix) = branch_chars(last);
        out.push_str(&format!("{branch} OS window {}\n", i + 1));
        render_os_window(&mut out, osw, child_prefix);
    }
    out
}

fn render_os_window(out: &mut String, osw: &OsWindow, prefix: &str) {
    let n = osw.tabs.len();
    for (i, tab) in osw.tabs.iter().enumerate() {
        let last = i + 1 == n;
        let (branch, child) = branch_chars(last);
        let title = tab.title.as_deref().unwrap_or("");
        out.push_str(&format!(
            "{prefix}{branch} Tab {}: {:?}  layout={}\n",
            i + 1,
            title,
            truncate_layout(&tab.layout)
        ));
        let new_prefix = format!("{prefix}{child}");
        render_tab(out, tab, &new_prefix);
    }
}

fn render_tab(out: &mut String, tab: &Tab, prefix: &str) {
    let n = tab.windows.len();
    for (i, win) in tab.windows.iter().enumerate() {
        let last = i + 1 == n;
        let (branch, child) = branch_chars(last);
        out.push_str(&format!(
            "{prefix}{branch} Window {}{}  {}\n",
            win.kitty_id,
            cwd_clause(&win.cwd),
            program_summary(&win.program),
        ));
        // For tmux windows, recurse into the captured TmuxWindow list.
        if let Program::Tmux { windows, .. } = &win.program {
            let new_prefix = format!("{prefix}{child}");
            render_tmux_windows(out, windows, &new_prefix);
        }
        // For other variants there is no further structure to render under
        // a kitty window — the program_summary line is the leaf.
    }
}

/// Render a tmux session's windows (and their panes) as a subtree, every
/// line prefixed by `prefix`. Pass `""` to render the tree at top level
/// (tmux-native `show`); kitty `show` passes the tab's child prefix.
pub(crate) fn render_tmux_windows(out: &mut String, windows: &[TmuxWindow], prefix: &str) {
    let n = windows.len();
    for (i, tw) in windows.iter().enumerate() {
        let last = i + 1 == n;
        let (branch, child) = branch_chars(last);
        out.push_str(&format!(
            "{prefix}{branch} tmux window {}: {:?}  layout={}{}\n",
            tw.idx,
            tw.name,
            truncate_layout(&tw.layout),
            if tw.active { " (active)" } else { "" },
        ));
        // Plan §4 / PRD user story 1: descend into pane children. Pre-§4
        // manifests have an empty `tw.panes` (serde default) and emit no
        // child rows — same shape as before, no spurious blanks.
        let pane_prefix = format!("{prefix}{child}");
        render_tmux_panes(out, &tw.panes, tw.active_pane_idx, &pane_prefix);
    }
}

fn render_tmux_panes(
    out: &mut String,
    panes: &[TmuxPane],
    active_pane_idx: Option<u32>,
    prefix: &str,
) {
    let n = panes.len();
    for (i, p) in panes.iter().enumerate() {
        let last = i + 1 == n;
        let (branch, _child) = branch_chars(last);
        let active_marker = if Some(p.index) == active_pane_idx {
            " (active)"
        } else {
            ""
        };
        let cwd_clause = cwd_clause(&p.cwd);
        // Plan §4 PRD user story 1: each pane line shows program (via the
        // existing one-line summary), cwd, and current_command. Order:
        // program tag first (most identifying), then cwd, then current
        // tmux command (useful when program degraded to BareShell but
        // the live `pane_current_command` told us "less" or "htop").
        let cmd_clause = match &p.current_command {
            Some(c) => format!("  cmd={c}"),
            None => String::new(),
        };
        out.push_str(&format!(
            "{prefix}{branch} pane {}  {}{cwd_clause}{cmd_clause}{active_marker}\n",
            p.index,
            program_summary(&p.program),
        ));
    }
}

/// Tree-drawing characters. Returns `(branch, child_prefix)`:
/// - `branch` is what prefixes this line (e.g. `├──` or `└──`).
/// - `child_prefix` is what every descendant of this node gets prepended
///   (e.g. `│   ` for non-last, `    ` for last).
fn branch_chars(is_last: bool) -> (&'static str, &'static str) {
    if is_last {
        ("└──", "    ")
    } else {
        ("├──", "│   ")
    }
}

fn cwd_clause(cwd: &Option<PathBuf>) -> String {
    match cwd {
        Some(p) => format!("  cwd={}", truncate_path(&p.display().to_string())),
        None => String::new(),
    }
}

/// One-line summary of a `Program` variant. Renders the most useful field(s).
fn program_summary(p: &Program) -> String {
    match p {
        Program::Nvim {
            truncated_buffers, ..
        } => {
            // TODO: the manifest doesn't carry an authoritative buffer count
            // (only `truncated_buffers`). The example output in the plan shows
            // `buffers=4 truncated=0`; until the model grows a `buffers: u32`
            // field we render the count we do have.
            format!("[nvim]  truncated={truncated_buffers}")
        }
        Program::Less {
            file,
            byte_offset,
            file_size,
        } => {
            let basename = file
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| file.display().to_string());
            let pct = if *file_size > 0 {
                (*byte_offset as f64 / *file_size as f64 * 100.0).round() as u64
            } else {
                0
            };
            format!(
                "[less] file={} offset={} ({}%)",
                basename,
                human_bytes(*byte_offset),
                pct
            )
        }
        Program::Shell {
            shell: _,
            venv,
            conda,
            direnv,
            oldpwd,
            scrollback: _,
            history: _,
        } => {
            let mut s = String::from("[shell]");
            if let Some(v) = venv {
                s.push_str(&format!(
                    " venv={}",
                    truncate_path(&v.display().to_string())
                ));
            }
            if let Some(c) = conda {
                s.push_str(&format!(" conda={c}"));
            }
            if let Some(d) = direnv {
                s.push_str(&format!(
                    " direnv={}",
                    truncate_path(&d.display().to_string())
                ));
            }
            if let Some(o) = oldpwd {
                s.push_str(&format!(
                    " oldpwd={}",
                    truncate_path(&o.display().to_string())
                ));
            }
            s
        }
        Program::Tmux { session_name, .. } => {
            format!("[tmux] session={session_name}")
        }
        Program::Raw { argv } => {
            // Shell-quote only when needed so the common case stays readable.
            let joined = argv
                .iter()
                .map(|a| {
                    if a.chars()
                        .any(|c| c.is_whitespace() || c == '\'' || c == '"')
                    {
                        format!("{a:?}")
                    } else {
                        a.clone()
                    }
                })
                .collect::<Vec<_>>()
                .join(" ");
            format!("[raw] argv={joined}")
        }
        Program::BareShell => String::from("[shell]"),
    }
}

/// Format a byte count as a short human string (`1.2MiB`, `512B`, `32KiB`).
/// Binary units; one decimal place above KiB, no decimal for bytes.
fn human_bytes(n: u64) -> String {
    const KIB: u64 = 1024;
    const MIB: u64 = 1024 * KIB;
    const GIB: u64 = 1024 * MIB;
    if n >= GIB {
        format!("{:.1}GiB", n as f64 / GIB as f64)
    } else if n >= MIB {
        format!("{:.1}MiB", n as f64 / MIB as f64)
    } else if n >= KIB {
        format!("{:.1}KiB", n as f64 / KIB as f64)
    } else {
        format!("{n}B")
    }
}

/// Layout strings (esp. tmux's) can be huge; clip to ~30 chars with an ellipsis.
fn truncate_layout(s: &str) -> String {
    const MAX: usize = 30;
    if s.chars().count() <= MAX {
        s.to_string()
    } else {
        let head: String = s.chars().take(MAX).collect();
        format!("{head}…")
    }
}

/// If a path is overly long, replace its middle with `…` to keep the line readable.
fn truncate_path(s: &str) -> String {
    const MAX: usize = 60;
    if s.len() <= MAX {
        return s.to_string();
    }
    // Keep tail (most informative for venvs / project dirs).
    let tail_len = MAX - 1;
    let tail: String = s.chars().rev().take(tail_len).collect::<String>();
    let tail: String = tail.chars().rev().collect();
    format!("…{tail}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{OsWindow, ShellKind, Tab, TmuxPane, TmuxWindow, Window};
    use chrono::{TimeZone, Utc};
    use std::path::PathBuf;

    fn sample() -> SessionFile {
        SessionFile {
            name: "demo".to_string(),
            created_at: Utc.with_ymd_and_hms(2026, 5, 23, 14, 32, 1).unwrap(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![
                OsWindow {
                    tabs: vec![
                        Tab {
                            title: Some("project A".to_string()),
                            layout: "splits".to_string(),
                            active_window_idx: 0,
                            windows: vec![
                                Window {
                                    kitty_id: 12,
                                    ksession_id: String::new(),
                                    cwd: Some(PathBuf::from("/home/u/proj")),
                                    program: Program::Nvim {
                                        session_vim: PathBuf::from("/tmp/s.vim"),
                                        manifest: None,
                                        truncated_buffers: 0,
                                    },
                                    scrollback: None,
                                },
                                Window {
                                    kitty_id: 13,
                                    ksession_id: String::new(),
                                    cwd: Some(PathBuf::from("/home/u/proj")),
                                    program: Program::Shell {
                                        shell: ShellKind::Bash,
                                        venv: Some(PathBuf::from("/home/u/proj/.venv")),
                                        conda: None,
                                        direnv: None,
                                        oldpwd: None,
                                        scrollback: None,
                                        history: None,
                                    },
                                    scrollback: None,
                                },
                            ],
                        },
                        Tab {
                            title: Some("logs".to_string()),
                            layout: "stack".to_string(),
                            active_window_idx: 0,
                            windows: vec![Window {
                                kitty_id: 14,
                                ksession_id: String::new(),
                                cwd: Some(PathBuf::from("/var/log")),
                                program: Program::Less {
                                    file: PathBuf::from("/var/log/syslog"),
                                    byte_offset: 1_258_291,
                                    file_size: 3_932_159,
                                },
                                scrollback: None,
                            }],
                        },
                    ],
                },
                OsWindow {
                    tabs: vec![Tab {
                        title: None,
                        layout: "splits".to_string(),
                        active_window_idx: 0,
                        windows: vec![Window {
                            kitty_id: 15,
                            ksession_id: String::new(),
                            cwd: None,
                            program: Program::Tmux {
                                session_name: "mysess".to_string(),
                                restore_sh: PathBuf::from("/tmp/r.sh"),
                                windows: vec![
                                    TmuxWindow {
                                        idx: 0,
                                        name: "main".to_string(),
                                        layout: "abcd,80x24,0,0,0".to_string(),
                                        active: true,
                                        panes: vec![],
                                        active_pane_idx: None,
                                        layout_leaf_count: 1,
                                    },
                                    TmuxWindow {
                                        idx: 1,
                                        name: "build".to_string(),
                                        layout: "efgh,80x24,0,0,1".to_string(),
                                        active: false,
                                        panes: vec![],
                                        active_pane_idx: None,
                                        layout_leaf_count: 1,
                                    },
                                ],
                                session_id: 0,
                                active_window_idx: Some(0),
                            },
                            scrollback: None,
                        }],
                    }],
                },
            ],
        }
    }

    #[test]
    fn header_includes_name_timestamp_schema() {
        let out = render(&sample());
        let first = out.lines().next().unwrap();
        assert!(first.starts_with("demo  (created 2026-05-23T14:32:01Z, schema=1)"));
    }

    #[test]
    fn tree_uses_unicode_branches() {
        let out = render(&sample());
        assert!(out.contains("├── OS window 1"));
        assert!(out.contains("└── OS window 2"));
        assert!(out.contains("│   ├── Tab 1: \"project A\""));
        assert!(out.contains("│   └── Tab 2: \"logs\""));
    }

    #[test]
    fn nvim_window_summary_present() {
        let out = render(&sample());
        assert!(
            out.contains("[nvim]"),
            "expected [nvim] tag in output:\n{out}"
        );
    }

    #[test]
    fn less_window_renders_basename_and_percent() {
        let out = render(&sample());
        assert!(out.contains("[less] file=syslog"), "got:\n{out}");
        assert!(out.contains("offset=1.2MiB"), "got:\n{out}");
        assert!(out.contains("(32%)"), "got:\n{out}");
    }

    #[test]
    fn shell_window_renders_venv() {
        let out = render(&sample());
        assert!(out.contains("[shell] venv="), "got:\n{out}");
    }

    #[test]
    fn tmux_window_recurses() {
        let out = render(&sample());
        assert!(out.contains("[tmux] session=mysess"), "got:\n{out}");
        assert!(out.contains("tmux window 0: \"main\""), "got:\n{out}");
        assert!(out.contains("tmux window 1: \"build\""), "got:\n{out}");
    }

    #[test]
    fn human_bytes_thresholds() {
        assert_eq!(human_bytes(0), "0B");
        assert_eq!(human_bytes(512), "512B");
        assert_eq!(human_bytes(1024), "1.0KiB");
        assert_eq!(human_bytes(1_258_291), "1.2MiB");
        assert_eq!(human_bytes(3 * 1024 * 1024 * 1024), "3.0GiB");
    }

    #[test]
    fn truncate_layout_clips_long_strings() {
        let long = "a".repeat(100);
        let out = truncate_layout(&long);
        assert!(out.ends_with('…'));
        assert!(out.chars().count() <= 31);
        assert_eq!(truncate_layout("short"), "short");
    }

    #[test]
    fn raw_program_renders_argv() {
        let mut s = sample();
        s.os_windows[0].tabs[0].windows[0].program = Program::Raw {
            argv: vec!["btop".to_string(), "--utf-force".to_string()],
        };
        let out = render(&s);
        assert!(out.contains("[raw] argv=btop --utf-force"), "got:\n{out}");
    }

    #[test]
    fn bare_shell_renders_minimal_tag() {
        let mut s = sample();
        s.os_windows[0].tabs[0].windows[0].program = Program::BareShell;
        let out = render(&s);
        assert!(out.contains("[shell]"), "got:\n{out}");
    }

    // ---------- §4 / PRD user story 1: tmux pane rendering ----------

    /// SessionFile with one tmux window holding three panes — shell, nvim,
    /// less — exercising the per-pane `program_summary` recursion.
    fn three_pane_tmux_session() -> SessionFile {
        SessionFile {
            name: "panes".to_string(),
            created_at: Utc.with_ymd_and_hms(2026, 5, 23, 14, 0, 0).unwrap(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![Tab {
                    title: Some("tmux".to_string()),
                    layout: "splits".to_string(),
                    active_window_idx: 0,
                    windows: vec![Window {
                        kitty_id: 1,
                        ksession_id: "uid-1".to_string(),
                        cwd: None,
                        program: Program::Tmux {
                            session_name: "work".to_string(),
                            restore_sh: PathBuf::from("/tmp/restore.sh"),
                            windows: vec![TmuxWindow {
                                idx: 0,
                                name: "main".to_string(),
                                layout: "abcd,80x24,0,0,0".to_string(),
                                active: true,
                                panes: vec![
                                    TmuxPane {
                                        index: 0,
                                        pane_pid: 1001,
                                        pane_id_digits: 1,
                                        cwd: Some(PathBuf::from("/home/u/proj")),
                                        current_command: Some("bash".to_string()),
                                        program: Box::new(Program::Shell {
                                            shell: ShellKind::Bash,
                                            venv: None,
                                            conda: None,
                                            direnv: None,
                                            oldpwd: None,
                                            scrollback: None,
                                            history: None,
                                        }),
                                    },
                                    TmuxPane {
                                        index: 1,
                                        pane_pid: 1002,
                                        pane_id_digits: 2,
                                        cwd: Some(PathBuf::from("/home/u/proj/src")),
                                        current_command: Some("nvim".to_string()),
                                        program: Box::new(Program::Nvim {
                                            session_vim: PathBuf::from("/tmp/pane-2.vim"),
                                            manifest: None,
                                            truncated_buffers: 0,
                                        }),
                                    },
                                    TmuxPane {
                                        index: 2,
                                        pane_pid: 1003,
                                        pane_id_digits: 3,
                                        cwd: Some(PathBuf::from("/var/log")),
                                        current_command: Some("less".to_string()),
                                        program: Box::new(Program::Less {
                                            file: PathBuf::from("/var/log/syslog"),
                                            byte_offset: 1024,
                                            file_size: 4096,
                                        }),
                                    },
                                ],
                                active_pane_idx: Some(1),
                                layout_leaf_count: 3,
                            }],
                            session_id: 3,
                            active_window_idx: Some(0),
                        },
                        scrollback: None,
                    }],
                }],
            }],
        }
    }

    #[test]
    fn tmux_pane_tree_descends_one_line_per_pane() {
        let out = render(&three_pane_tmux_session());
        // One line per pane, each tagged with its program flavour and the
        // captured cwd / current_command.
        assert!(
            out.contains("pane 0  [shell]  cwd=/home/u/proj  cmd=bash"),
            "shell pane missing or wrong:\n{out}"
        );
        assert!(
            out.contains("pane 1  [nvim]  truncated=0  cwd=/home/u/proj/src  cmd=nvim (active)"),
            "nvim pane missing, wrong, or active marker missing:\n{out}"
        );
        assert!(
            out.contains("pane 2  [less] file=syslog"),
            "less pane missing program summary:\n{out}"
        );
        assert!(
            out.contains("cwd=/var/log  cmd=less"),
            "less pane fields missing:\n{out}"
        );
    }

    #[test]
    fn tmux_pane_tree_uses_unicode_branches_under_window() {
        // Pin the tree-drawing nesting: each pane sits one level deeper
        // than its parent tmux window, using the standard prefix glyphs.
        let out = render(&three_pane_tmux_session());
        // The parent tmux window is itself the last child of the kitty
        // Window, so its child prefix is `    ` (four spaces). Combined
        // with `├──` / `└──` for the panes.
        assert!(
            out.contains("├── pane 0"),
            "expected `├── pane 0` in:\n{out}"
        );
        assert!(
            out.contains("├── pane 1"),
            "expected `├── pane 1` in:\n{out}"
        );
        assert!(
            out.contains("└── pane 2"),
            "expected `└── pane 2` in:\n{out}"
        );
    }

    #[test]
    fn tmux_pane_tree_omitted_when_panes_empty() {
        // A legacy manifest with no panes (or a freshly-degraded tmux
        // capture) must NOT spuriously emit pane rows.
        let mut s = three_pane_tmux_session();
        if let Program::Tmux { windows, .. } = &mut s.os_windows[0].tabs[0].windows[0].program {
            windows[0].panes.clear();
            windows[0].active_pane_idx = None;
        }
        let out = render(&s);
        assert!(
            !out.contains("pane "),
            "no pane rows expected when panes Vec is empty, got:\n{out}"
        );
    }
}
