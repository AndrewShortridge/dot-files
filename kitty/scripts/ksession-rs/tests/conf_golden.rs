//! Golden-file tests for `conf::render` (§C.1 skeleton-patch pipeline).
//!
//! Each fixture pairs a `<name>.skel` (the kitty session-format input from
//! `kitty @ ls --output-format=session`) with a hand-built [`SessionFile`]
//! providing argv for each `Window` keyed off `kitty_id`. The render output
//! is compared against the matching `<name>.conf` checked in under
//! `tests/golden/conf/`.
//!
//! To regenerate the goldens after a deliberate format change, run:
//!
//!     KSESSION_UPDATE_GOLDENS=1 cargo test --test conf_golden
//!
//! Then audit `git diff tests/golden/conf/` and re-run without the env var
//! to confirm.

use std::path::{Path, PathBuf};

use chrono::{DateTime, TimeZone, Utc};
use ksession_rs::conf::render;
use ksession_rs::model::{OsWindow, Program, SessionFile, ShellKind, Tab, TmuxWindow, Window};
use pretty_assertions::assert_eq;

fn fixture_ts() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 5, 22, 12, 0, 0).unwrap()
}

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("kitty-session")
}

fn golden_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("golden")
        .join("conf")
}

fn check(name: &str, skel: &str, session: &SessionFile) {
    let rendered = render(skel, session).expect("render");
    let path = golden_dir().join(format!("{name}.conf"));
    if std::env::var_os("KSESSION_UPDATE_GOLDENS").is_some() {
        std::fs::create_dir_all(path.parent().unwrap()).expect("create golden dir");
        std::fs::write(&path, &rendered).expect("write golden");
        return;
    }
    let expected = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read golden {}: {e}", path.display()));
    assert_eq!(rendered, expected, "golden mismatch for {name}");
}

fn read_skel(name: &str) -> String {
    let path = fixtures_dir().join(format!("{name}.skel"));
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read skel {}: {e}", path.display()))
}

// ---------- fixtures ----------

/// Two-tab fixture exercising: a bare shell, an nvim sidecar, a stack-layout
/// tab, kq-borrow/owned token mix, and the `cd <path>` / `focus` / `focus_tab`
/// pass-through.
fn two_tabs_session() -> SessionFile {
    SessionFile {
        name: "two_tabs".to_string(),
        created_at: fixture_ts(),
        schema: 1,
        kitty_version: String::new(),
        os_windows: vec![OsWindow {
            tabs: vec![
                Tab {
                    title: Some("editors".into()),
                    layout: "splits".into(),
                    active_window_idx: 1,
                    windows: vec![
                        Window {
                            kitty_id: 1,
                            ksession_id: "uid-1".into(),
                            cwd: Some(PathBuf::from("/home/u/proj")),
                            program: Program::BareShell,
                            scrollback: None,
                        },
                        Window {
                            kitty_id: 2,
                            ksession_id: "uid-2".into(),
                            cwd: Some(PathBuf::from("/var/log")),
                            program: Program::Nvim {
                                session_vim: PathBuf::from("/tmp/session.vim"),
                                manifest: None,
                                truncated_buffers: 0,
                            },
                            scrollback: None,
                        },
                    ],
                },
                Tab {
                    title: None,
                    layout: "stack".into(),
                    active_window_idx: 0,
                    windows: vec![Window {
                        kitty_id: 3,
                        ksession_id: "uid-3".into(),
                        cwd: Some(PathBuf::from("/home/u")),
                        program: Program::Shell {
                            shell: ShellKind::Zsh,
                            venv: Some(PathBuf::from("/home/u/.venv")),
                            conda: None,
                            direnv: None,
                            oldpwd: None,
                            scrollback: None,
                            history: None,
                        },
                        scrollback: None,
                    }],
                },
            ],
        }],
    }
}

/// Variants: nvim, less, shell+venv, tmux, raw, bare. All in one tab so the
/// argv-emission tail is locked for every Program variant against a single
/// reasonably-sized skeleton.
fn all_program_variants_session() -> SessionFile {
    let mk = |id: u64, prog: Program| Window {
        kitty_id: id,
        ksession_id: format!("uid-{id}"),
        cwd: None,
        program: prog,
        scrollback: None,
    };
    SessionFile {
        name: "all_variants".into(),
        created_at: fixture_ts(),
        schema: 1,
        kitty_version: String::new(),
        os_windows: vec![OsWindow {
            tabs: vec![Tab {
                title: None,
                layout: "splits".into(),
                active_window_idx: 3,
                windows: vec![
                    mk(
                        100,
                        Program::Nvim {
                            session_vim: PathBuf::from("/tmp/session.vim"),
                            manifest: None,
                            truncated_buffers: 0,
                        },
                    ),
                    mk(
                        101,
                        Program::Less {
                            file: PathBuf::from("/var/log/syslog"),
                            byte_offset: 4096,
                            file_size: 1_000_000,
                        },
                    ),
                    mk(
                        102,
                        Program::Shell {
                            shell: ShellKind::Bash,
                            venv: None,
                            conda: None,
                            direnv: None,
                            oldpwd: None,
                            scrollback: None,
                            history: None,
                        },
                    ),
                    mk(
                        103,
                        Program::Shell {
                            shell: ShellKind::Bash,
                            venv: Some(PathBuf::from("/home/u/.venv")),
                            conda: None,
                            direnv: None,
                            oldpwd: Some(PathBuf::from("/tmp")),
                            scrollback: None,
                            history: None,
                        },
                    ),
                    mk(
                        104,
                        Program::Shell {
                            shell: ShellKind::Bash,
                            venv: None,
                            conda: Some("myenv".into()),
                            direnv: None,
                            oldpwd: None,
                            scrollback: None,
                            history: None,
                        },
                    ),
                    mk(
                        105,
                        Program::Tmux {
                            session_name: "work".into(),
                            restore_sh: PathBuf::from("/tmp/restore.sh"),
                            windows: vec![TmuxWindow {
                                idx: 0,
                                name: "main".into(),
                                layout: "abcd,80x24,0,0,0".into(),
                                active: true,
                                panes: vec![],
                                active_pane_idx: None,
                                layout_leaf_count: 1,
                            }],
                            session_id: 0,
                            active_window_idx: Some(0),
                        },
                    ),
                    mk(
                        106,
                        Program::Raw {
                            argv: vec!["btop".into(), "--utf-force".into()],
                        },
                    ),
                    mk(107, Program::BareShell),
                ],
            }],
        }],
    }
}

// ---------- tests ----------

#[test]
fn golden_two_tabs() {
    let skel = read_skel("two_tabs");
    check("two_tabs", &skel, &two_tabs_session());
}

#[test]
fn golden_all_program_variants() {
    // Synthesize a minimal skeleton matching the kitty_ids in
    // all_program_variants_session(). Inline rather than checking in a
    // separate `.skel` since it's mechanically derived from the session.
    let mut skel = String::from("new_tab\nlayout splits\n");
    for id in 100u64..=107 {
        skel.push_str(&format!(
            "launch 'kitty-unserialize-data={{\"id\": {id}}}'\n",
        ));
    }
    check(
        "all_program_variants",
        &skel,
        &all_program_variants_session(),
    );
}

#[test]
fn golden_multi_os_window() {
    // Plan supports multi-OSW; this fixture exercises `new_os_window` as a
    // pass-through directive between two os_window blocks, each with its
    // own os_window_class / os_window_name / tab / launch.
    let mk = |id: u64| OsWindow {
        tabs: vec![Tab {
            title: None,
            layout: "splits".into(),
            active_window_idx: 0,
            windows: vec![Window {
                kitty_id: id,
                ksession_id: format!("uid-{id}"),
                cwd: None,
                program: Program::BareShell,
                scrollback: None,
            }],
        }],
    };
    let s = SessionFile {
        name: "multi_osw".into(),
        created_at: fixture_ts(),
        schema: 1,
        kitty_version: String::new(),
        os_windows: vec![mk(1), mk(2)],
    };
    check("multi_os_window", &read_skel("multi_os_window"), &s);
}

#[test]
fn golden_live_skeleton_matched() {
    // Coverage finding from round 3: the existing live golden uses an
    // empty SessionFile, so the matched-path re-tagging (which interacts
    // with the adversarial token forms in the live skel — `--var==`,
    // `--var=--match=`, `'--var= probe_ws=trailspc'`, etc.) is exercised
    // only by unit tests. This golden runs render() over the same live
    // skeleton with a SessionFile whose kitty_ids (4, 2, 3) cover every
    // launch line, so every launch is patched with `--var=ksession_id=...`
    // and a fresh argv. Locks fidelity of the matched path against the
    // real capture's token soup.
    let mk = |id: u64, prog: Program| Window {
        kitty_id: id,
        ksession_id: format!("uid-{id}"),
        cwd: None,
        program: prog,
        scrollback: None,
    };
    let session = SessionFile {
        name: "live_matched".into(),
        created_at: fixture_ts(),
        schema: 1,
        kitty_version: String::new(),
        os_windows: vec![OsWindow {
            tabs: vec![Tab {
                title: None,
                layout: "splits".into(),
                active_window_idx: 0,
                windows: vec![
                    mk(4, Program::BareShell),
                    mk(
                        2,
                        Program::Nvim {
                            session_vim: PathBuf::from("/tmp/nvim-19.vim"),
                            manifest: None,
                            truncated_buffers: 0,
                        },
                    ),
                    mk(3, Program::BareShell),
                ],
            }],
        }],
    };
    check("live_skeleton_matched", &read_skel("live"), &session);
}

#[test]
fn golden_live_skeleton_passthrough() {
    // Pass through the real /tmp/kitty-* capture with an empty SessionFile:
    // no window matches, so the launches lose their kitty-unserialize-data
    // tokens and ksession-owned vars but otherwise come through verbatim.
    let skel = read_skel("live");
    let session = SessionFile {
        name: "live".into(),
        created_at: fixture_ts(),
        schema: 1,
        kitty_version: String::new(),
        os_windows: vec![],
    };
    check("live_skeleton_passthrough", &skel, &session);
}

#[test]
fn no_kitty_unserialize_data_remains() {
    // Plan §C.1 regression: the intra-process reattach token must never
    // appear in any rendered output, including under the no-match path.
    for (name, skel, sess) in [
        ("two_tabs", read_skel("two_tabs"), two_tabs_session()),
        (
            "live",
            read_skel("live"),
            SessionFile {
                name: "live".into(),
                created_at: fixture_ts(),
                schema: 1,
                kitty_version: String::new(),
                os_windows: vec![],
            },
        ),
    ] {
        let out = render(&skel, &sess).expect("render");
        assert!(
            !out.contains("kitty-unserialize-data"),
            "unserialize token leaked in '{name}': {out}",
        );
    }
}
