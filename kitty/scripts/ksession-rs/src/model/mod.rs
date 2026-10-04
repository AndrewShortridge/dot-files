mod buffer;
mod program;
mod session;
mod tab;
mod window;

pub use buffer::BufferDump;
pub use program::{Program, ShellKind, TmuxPane, TmuxWindow};
pub use session::{OsWindow, SessionFile};
pub use tab::Tab;
pub use window::{Window, SYNTHETIC_ID_FLOOR};

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};
    use pretty_assertions::assert_eq;
    use std::path::PathBuf;

    fn sample_session() -> SessionFile {
        SessionFile {
            name: "demo".to_string(),
            created_at: Utc.with_ymd_and_hms(2026, 5, 22, 12, 0, 0).unwrap(),
            schema: 1,
            kitty_version: String::new(),
            os_windows: vec![OsWindow {
                tabs: vec![
                    Tab {
                        title: Some("editors".to_string()),
                        layout: "splits".to_string(),
                        active_window_idx: 0,
                        windows: vec![
                            Window {
                                kitty_id: 101,
                                ksession_id: "uid-101".to_string(),
                                cwd: Some(PathBuf::from("/home/u/proj")),
                                program: Program::Nvim {
                                    session_vim: PathBuf::from("/tmp/session.vim"),
                                    manifest: Some(PathBuf::from("/tmp/manifest.json")),
                                    truncated_buffers: 2,
                                },
                                scrollback: Some(PathBuf::from("/tmp/sb-101.txt")),
                            },
                            Window {
                                kitty_id: 102,
                                ksession_id: "uid-102".to_string(),
                                cwd: Some(PathBuf::from("/var/log")),
                                program: Program::Less {
                                    file: PathBuf::from("/var/log/syslog"),
                                    byte_offset: 4096,
                                    file_size: 1_000_000,
                                },
                                scrollback: None,
                            },
                        ],
                    },
                    Tab {
                        title: None,
                        layout: "stack".to_string(),
                        active_window_idx: 1,
                        windows: vec![
                            Window {
                                kitty_id: 201,
                                ksession_id: "uid-201".to_string(),
                                cwd: Some(PathBuf::from("/home/u")),
                                program: Program::Shell {
                                    shell: ShellKind::Zsh,
                                    venv: Some(PathBuf::from("/home/u/.venv")),
                                    conda: Some("base".to_string()),
                                    direnv: Some(PathBuf::from("/home/u/proj")),
                                    oldpwd: Some(PathBuf::from("/tmp")),
                                    scrollback: None,
                                    history: None,
                                },
                                scrollback: None,
                            },
                            Window {
                                kitty_id: 202,
                                ksession_id: "uid-202".to_string(),
                                cwd: None,
                                program: Program::Tmux {
                                    session_name: "work".to_string(),
                                    restore_sh: PathBuf::from("/tmp/restore.sh"),
                                    windows: vec![TmuxWindow {
                                        idx: 0,
                                        name: "main".to_string(),
                                        layout: "abcd,80x24,0,0,0".to_string(),
                                        active: true,
                                        panes: vec![],
                                        active_pane_idx: None,
                                        layout_leaf_count: 1,
                                    }],
                                    session_id: 0,
                                    active_window_idx: Some(0),
                                },
                                scrollback: None,
                            },
                            Window {
                                kitty_id: 203,
                                ksession_id: "uid-203".to_string(),
                                cwd: None,
                                program: Program::Raw {
                                    argv: vec!["btop".to_string(), "--utf-force".to_string()],
                                },
                                scrollback: None,
                            },
                            Window {
                                kitty_id: 204,
                                ksession_id: "uid-204".to_string(),
                                cwd: None,
                                program: Program::BareShell,
                                scrollback: None,
                            },
                        ],
                    },
                ],
            }],
        }
    }

    #[test]
    fn round_trip_all_program_variants() {
        let original = sample_session();
        let json = serde_json::to_string_pretty(&original).expect("serialize");
        let parsed: SessionFile = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(original, parsed);
    }

    #[test]
    fn buffer_dump_round_trip() {
        let dump = BufferDump {
            buf_id: 7,
            name: "src/main.rs".to_string(),
            modified: true,
            filetype: "rust".to_string(),
            dump_path: PathBuf::from("/tmp/buf-7.txt"),
            truncated: false,
            byte_count: 1234,
        };
        let json = serde_json::to_string(&dump).expect("serialize");
        let back: BufferDump = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(dump, back);
    }

    #[test]
    fn program_kind_tags_are_snake_case() {
        use std::collections::BTreeSet;

        let session = sample_session();
        let value = serde_json::to_value(&session).expect("serialize to value");

        let mut seen: BTreeSet<String> = BTreeSet::new();
        let os_windows = value
            .get("os_windows")
            .and_then(|v| v.as_array())
            .expect("os_windows array");
        for osw in os_windows {
            let tabs = osw
                .get("tabs")
                .and_then(|v| v.as_array())
                .expect("tabs array");
            for tab in tabs {
                let windows = tab
                    .get("windows")
                    .and_then(|v| v.as_array())
                    .expect("windows array");
                for w in windows {
                    let program = w.get("program").expect("program field");
                    let kind = program
                        .get("kind")
                        .and_then(|v| v.as_str())
                        .expect("program.kind string");
                    seen.insert(kind.to_string());
                }
            }
        }

        let expected: BTreeSet<String> = ["nvim", "less", "shell", "tmux", "raw", "bare_shell"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(seen, expected);
    }
}
