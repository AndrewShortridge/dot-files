use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Program {
    Nvim {
        session_vim: PathBuf,
        manifest: Option<PathBuf>,
        truncated_buffers: u32,
    },
    Less {
        file: PathBuf,
        byte_offset: u64,
        file_size: u64,
    },
    Shell {
        shell: ShellKind,
        venv: Option<PathBuf>,
        conda: Option<String>,
        direnv: Option<PathBuf>,
        oldpwd: Option<PathBuf>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        scrollback: Option<PathBuf>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        history: Option<PathBuf>,
    },
    Tmux {
        session_name: String,
        restore_sh: PathBuf,
        windows: Vec<TmuxWindow>,
        /// Tmux server session id (the numeric part of tmux's `$<N>` session
        /// id). Captured from `#{session_id}` and persisted so the manifest
        /// faithfully describes the captured server-side identity. Pre-§4
        /// manifests omit this field; serde defaults to `0` which is safe —
        /// the patcher does not consume `session_id` (restore.sh handles
        /// session naming via `$SESS`).
        #[serde(default)]
        session_id: u32,
        /// Index of the active window inside this tmux session at capture
        /// time. `None` when no window was active or the value was not
        /// captured. Pre-§4 manifests omit this field; serde defaults to
        /// `None`.
        #[serde(default)]
        active_window_idx: Option<u32>,
    },
    Raw {
        argv: Vec<String>,
    },
    BareShell,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ShellKind {
    Bash,
    Zsh,
    Fish,
    Sh,
    Dash,
    Ash,
}

// Captured for `ksession show` display; not consumed at restore.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct TmuxWindow {
    pub idx: u32,
    pub name: String,
    pub layout: String,
    pub active: bool,
    /// Per-pane detail captured for `ksession show` (Plan §4). Pre-§4
    /// manifests omit this field; serde-default to empty so older fixtures
    /// still deserialise.
    #[serde(default)]
    pub panes: Vec<TmuxPane>,
    /// Index of the active pane inside this tmux window at capture time.
    /// `None` when no pane was active or the value was not captured. Pre-§4
    /// manifests omit this field; serde defaults to `None`.
    #[serde(default)]
    pub active_pane_idx: Option<u32>,
    /// Count of pane leaves encoded in `layout`. Captured alongside the
    /// layout string so a future diagnostic can flag the live-vs-layout
    /// mismatch the adapter already warns about. Pre-§4 manifests omit
    /// this field; serde defaults to `0`.
    #[serde(default)]
    pub layout_leaf_count: u32,
}

// Tests for the §4 model additions live at the bottom of this file (close
// to the structs they exercise). Cross-struct tests (e.g. that a Program
// inside a Pane inside a TmuxWindow inside a SessionFile round-trips) live
// in `model/mod.rs` against the full `SessionFile` fixture.

/// Per-pane detail captured into the manifest for `ksession show`.
///
/// Mirrors the data the tmux adapter already builds into its private
/// `restore_panes` Vec; promoting it to the model means the manifest is
/// the canonical on-disk description of what was captured (Plan §4 / PRD
/// user story 16).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct TmuxPane {
    /// Tmux pane index inside its parent window (e.g. `0`, `1`, ...).
    pub index: u32,
    /// PID of the pane's foreground shell process at capture time.
    pub pane_pid: u32,
    /// Tmux's `%N` pane id with the leading `%` stripped, retained as a
    /// numeric identity key for sidecar paths and diagnostics. Stored as
    /// `u64` so a tmux server with very long uptime (where the pane id
    /// counter has wrapped past `u32::MAX`) still round-trips.
    pub pane_id_digits: u64,
    /// Pane's `pane_current_path` at capture time. `None` when tmux returned
    /// empty (the adapter's `assert_no_nul` clears it on bad input).
    pub cwd: Option<PathBuf>,
    /// Pane's `pane_current_command` at capture time. `None` when tmux
    /// returned empty.
    pub current_command: Option<String>,
    /// Result of recursing the per-pane Adapter Registry — the same
    /// `Program` flavours a top-level kitty window can hold. Boxed to keep
    /// the enclosing `Program::Tmux` size sane (a pane could itself hold a
    /// nested `Program::Tmux`, which would otherwise make the variant
    /// recursive at the type level).
    pub program: Box<Program>,
}

#[cfg(test)]
mod program_tests {
    use super::*;
    use std::path::PathBuf;

    /// Round-trip a `TmuxPane` whose `program` is a given variant.
    /// PRD acceptance criterion: one round-trip test per `Program` variant
    /// inside a pane, including the nested `program: Box<Program>` recursion.
    fn rt_pane(prog: Program) -> TmuxPane {
        let original = TmuxPane {
            index: 7,
            pane_pid: 4242,
            pane_id_digits: 17,
            cwd: Some(PathBuf::from("/home/u/work")),
            current_command: Some("bash".to_string()),
            program: Box::new(prog),
        };
        let json = serde_json::to_string(&original).expect("serialize pane");
        let parsed: TmuxPane = serde_json::from_str(&json).expect("deserialize pane");
        assert_eq!(original, parsed);
        parsed
    }

    #[test]
    fn tmux_pane_round_trip_with_bare_shell_program() {
        let _ = rt_pane(Program::BareShell);
    }

    #[test]
    fn tmux_pane_round_trip_with_shell_program() {
        let _ = rt_pane(Program::Shell {
            shell: ShellKind::Bash,
            venv: Some(PathBuf::from("/home/u/.venv")),
            conda: None,
            direnv: None,
            oldpwd: None,
            scrollback: None,
            history: None,
        });
    }

    #[test]
    fn tmux_pane_round_trip_with_nvim_program() {
        let _ = rt_pane(Program::Nvim {
            session_vim: PathBuf::from("/tmp/s.vim"),
            manifest: None,
            truncated_buffers: 0,
        });
    }

    #[test]
    fn tmux_pane_round_trip_with_less_program() {
        let _ = rt_pane(Program::Less {
            file: PathBuf::from("/var/log/syslog"),
            byte_offset: 4096,
            file_size: 1_000_000,
        });
    }

    #[test]
    fn tmux_pane_round_trip_with_raw_program() {
        let _ = rt_pane(Program::Raw {
            argv: vec!["htop".to_string()],
        });
    }

    #[test]
    fn tmux_pane_round_trip_with_nested_tmux_program() {
        // Pin the `Box<Program>` recursion guard: a pane whose program is
        // itself a tmux session (the nested-tmux degrade path) must
        // round-trip through serde without infinite-type errors.
        let _ = rt_pane(Program::Tmux {
            session_name: "inner".to_string(),
            restore_sh: PathBuf::from("/tmp/inner-restore.sh"),
            windows: vec![],
            session_id: 9,
            active_window_idx: None,
        });
    }

    #[test]
    fn tmux_window_round_trip_carries_new_fields() {
        let original = TmuxWindow {
            idx: 1,
            name: "build".to_string(),
            layout: "abcd,80x24,0,0,1".to_string(),
            active: false,
            panes: vec![TmuxPane {
                index: 0,
                pane_pid: 9000,
                pane_id_digits: 3,
                cwd: None,
                current_command: None,
                program: Box::new(Program::BareShell),
            }],
            active_pane_idx: Some(0),
            layout_leaf_count: 1,
        };
        let json = serde_json::to_string(&original).expect("serialize");
        let back: TmuxWindow = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(original, back);
    }

    #[test]
    fn program_tmux_round_trip_carries_new_fields() {
        let original = Program::Tmux {
            session_name: "work".to_string(),
            restore_sh: PathBuf::from("/tmp/r.sh"),
            windows: vec![],
            session_id: 42,
            active_window_idx: Some(3),
        };
        let json = serde_json::to_string(&original).expect("serialize");
        let back: Program = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(original, back);
    }

    #[test]
    fn tmux_window_pre_v4_manifest_deserialises_with_defaults() {
        // ADR 0003 compatibility: pre-§4 manifests omit the new fields.
        // Serde defaults must fill them so older fixtures still load.
        let raw = r#"{
            "idx": 0,
            "name": "main",
            "layout": "abcd,80x24,0,0,0",
            "active": true
        }"#;
        let w: TmuxWindow = serde_json::from_str(raw).expect("legacy parses");
        assert_eq!(w.panes, Vec::<TmuxPane>::new());
        assert_eq!(w.active_pane_idx, None);
        assert_eq!(w.layout_leaf_count, 0);
    }

    #[test]
    fn program_tmux_pre_v4_manifest_deserialises_with_defaults() {
        let raw = r#"{
            "kind": "tmux",
            "session_name": "work",
            "restore_sh": "/tmp/r.sh",
            "windows": []
        }"#;
        let p: Program = serde_json::from_str(raw).expect("legacy parses");
        match p {
            Program::Tmux {
                session_id,
                active_window_idx,
                ..
            } => {
                assert_eq!(session_id, 0);
                assert_eq!(active_window_idx, None);
            }
            other => panic!("expected Tmux, got {other:?}"),
        }
    }

    #[test]
    fn shell_scrollback_history_round_trip() {
        let original = Program::Shell {
            shell: ShellKind::Zsh,
            venv: None,
            conda: None,
            direnv: None,
            oldpwd: None,
            scrollback: Some(PathBuf::from("/tmp/state/scrollback-42.txt")),
            history: Some(PathBuf::from("/tmp/state/history-42.txt")),
        };
        let json = serde_json::to_string(&original).expect("serialize");
        let back: Program = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(original, back);
        // Verify both fields appear in the JSON output.
        assert!(json.contains("scrollback"), "scrollback in JSON: {json}");
        assert!(json.contains("history"), "history in JSON: {json}");
    }

    #[test]
    fn shell_pre_v13_manifest_without_scrollback_history_deserialises_to_none() {
        // Pre-PRD-13 manifests omit scrollback/history. serde defaults must
        // fill them with None so older fixtures still load.
        let raw = r#"{
            "kind": "shell",
            "shell": "bash",
            "venv": null,
            "conda": null,
            "direnv": null,
            "oldpwd": null
        }"#;
        let p: Program = serde_json::from_str(raw).expect("legacy parses");
        match p {
            Program::Shell {
                scrollback,
                history,
                ..
            } => {
                assert_eq!(scrollback, None);
                assert_eq!(history, None);
            }
            other => panic!("expected Shell, got {other:?}"),
        }
    }
}
