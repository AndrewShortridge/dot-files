//! The tmux-native session "head" file: `<root>/<name>.json`.
//!
//! Its presence defines a saved session, exactly like `<name>.conf` does
//! for the kitty store — it is written last (atomically) so a crash
//! mid-save can never publish a half-built state dir, and the orphan
//! sweep treats any `<name>.gen-*.state/` without a head as garbage.
//!
//! The payload is the adapter's `Program::Tmux` verbatim, wrapped with the
//! bookkeeping `show`/`list` need. No kitty OS-window/tab hierarchy: a
//! tmux session has exactly one top-level thing, the session itself.

use std::fs;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::TmuxSessionError;
use crate::model::{Program, TmuxWindow};

/// Extension of the head file (no dot). Also the value handed to
/// [`crate::fsx::sweep_orphans_for`] and [`crate::fsx::commit_session`]
/// so sweep and publish key on the same convention.
pub const HEAD_EXT: &str = "json";

/// Pinned per ADR 0003: additive fields ride `#[serde(default)]`; bump
/// only for a genuinely breaking shape change.
pub const CURRENT_SCHEMA: u32 = 1;

/// One saved tmux session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TmuxSessionManifest {
    /// Saved-session name (the head file stem).
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub schema: u32,
    /// Verbatim `tmux -V` output at save time (e.g. `tmux 3.4`), for
    /// restore-time drift diagnostics (ADR 0002 analogue).
    #[serde(default)]
    pub tmux_version: String,
    /// Absolute path of the `<name>.gen-<ts>.state/` dir this manifest
    /// points at; everything under `program` lives inside it.
    pub state_dir: PathBuf,
    /// Always `Program::Tmux { .. }` — the adapter's capture payload.
    pub program: Program,
}

impl TmuxSessionManifest {
    /// The live tmux session name the save was taken from.
    pub fn session_name(&self) -> &str {
        match &self.program {
            Program::Tmux { session_name, .. } => session_name,
            _ => "",
        }
    }

    /// Path of the generated restore script inside [`Self::state_dir`].
    pub fn restore_sh(&self) -> &Path {
        match &self.program {
            Program::Tmux { restore_sh, .. } => restore_sh,
            _ => Path::new(""),
        }
    }

    pub fn windows(&self) -> &[TmuxWindow] {
        match &self.program {
            Program::Tmux { windows, .. } => windows,
            _ => &[],
        }
    }

    pub fn window_count(&self) -> usize {
        self.windows().len()
    }

    pub fn pane_count(&self) -> usize {
        self.windows().iter().map(|w| w.panes.len()).sum()
    }

    /// Whether any pane was running nvim at save time (surfaced in `list`
    /// because those sessions carry an nvim session to replay).
    pub fn has_nvim(&self) -> bool {
        self.windows()
            .iter()
            .flat_map(|w| &w.panes)
            .any(|p| matches!(*p.program, Program::Nvim { .. }))
    }
}

/// `<root>/<name>.json`.
pub fn head_path(root: &Path, name: &str) -> PathBuf {
    root.join(format!("{name}.{HEAD_EXT}"))
}

/// Load the manifest for `name`. A missing head is [`TmuxSessionError::NotFound`];
/// a head written by a newer, incompatible binary is refused rather than
/// misread (ADR 0003).
pub fn read(root: &Path, name: &str) -> Result<TmuxSessionManifest, TmuxSessionError> {
    let path = head_path(root, name);
    let bytes = match fs::read(&path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(TmuxSessionError::NotFound(name.to_string()));
        }
        Err(e) => return Err(e.into()),
    };
    let manifest: TmuxSessionManifest = serde_json::from_slice(&bytes)?;
    if manifest.schema > CURRENT_SCHEMA {
        return Err(TmuxSessionError::Other(format!(
            "manifest schema {} is newer than supported ({CURRENT_SCHEMA})",
            manifest.schema
        )));
    }
    Ok(manifest)
}

/// Head-file bytes for `m`: pretty-printed so a user can read the head
/// directly. Publishing them is [`crate::fsx::commit_session`]'s job
/// (`save`), which fsyncs the state dir first and renames the head last.
pub fn head_bytes(m: &TmuxSessionManifest) -> Result<Vec<u8>, TmuxSessionError> {
    Ok(serde_json::to_vec_pretty(m)?)
}

/// Test fixture: drop a head for `m` under `root` without a state dir.
#[cfg(test)]
pub(crate) fn write(root: &Path, m: &TmuxSessionManifest) -> Result<(), TmuxSessionError> {
    fs::write(head_path(root, &m.name), head_bytes(m)?)?;
    Ok(())
}

/// Names of every saved session under `root` (stem of each `*.json`),
/// sorted. A missing root is an empty store, not an error.
pub fn list_names(root: &Path) -> Result<Vec<String>, TmuxSessionError> {
    let entries = match fs::read_dir(root) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.into()),
    };
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .filter_map(|e| head_stem(&e.file_name().to_string_lossy()))
        .collect();
    names.sort();
    Ok(names)
}

/// `foo.json` → `Some("foo")`; anything else (state dirs, tombstones,
/// temp files, the autosave stamp) → `None`.
fn head_stem(file_name: &str) -> Option<String> {
    let stem = file_name.strip_suffix(HEAD_EXT)?.strip_suffix('.')?;
    (!stem.is_empty()).then(|| stem.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::TmuxPane;
    use chrono::TimeZone;
    use tempfile::tempdir;

    fn pane(index: u32, program: Program) -> TmuxPane {
        TmuxPane {
            index,
            pane_pid: 100 + index,
            pane_id_digits: u64::from(index),
            cwd: Some(PathBuf::from("/tmp")),
            current_command: None,
            program: Box::new(program),
        }
    }

    fn sample(name: &str) -> TmuxSessionManifest {
        TmuxSessionManifest {
            name: name.to_string(),
            created_at: Utc.with_ymd_and_hms(2026, 10, 3, 12, 0, 0).unwrap(),
            schema: CURRENT_SCHEMA,
            tmux_version: "tmux 3.4".to_string(),
            state_dir: PathBuf::from("/data/work.gen-1.state"),
            program: Program::Tmux {
                session_name: "work".to_string(),
                restore_sh: PathBuf::from("/data/work.gen-1.state/tmux/work/restore.sh"),
                windows: vec![
                    TmuxWindow {
                        idx: 0,
                        name: "code".to_string(),
                        layout: String::new(),
                        active: true,
                        panes: vec![pane(0, Program::BareShell), pane(1, Program::BareShell)],
                        active_pane_idx: Some(0),
                        layout_leaf_count: 2,
                    },
                    TmuxWindow {
                        idx: 1,
                        name: "edit".to_string(),
                        layout: String::new(),
                        active: false,
                        panes: vec![pane(
                            0,
                            Program::Nvim {
                                session_vim: PathBuf::from("/data/s.vim"),
                                manifest: None,
                                truncated_buffers: 0,
                            },
                        )],
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
    fn accessors_read_through_program_tmux() {
        let m = sample("work");
        assert_eq!(m.session_name(), "work");
        assert_eq!(
            m.restore_sh(),
            Path::new("/data/work.gen-1.state/tmux/work/restore.sh")
        );
        assert_eq!(m.window_count(), 2);
        assert_eq!(m.pane_count(), 3);
        assert!(m.has_nvim());
    }

    #[test]
    fn has_nvim_false_without_nvim_pane() {
        let mut m = sample("work");
        if let Program::Tmux { windows, .. } = &mut m.program {
            windows.pop();
        }
        assert!(!m.has_nvim());
    }

    #[test]
    fn write_then_read_round_trips() {
        let dir = tempdir().unwrap();
        let m = sample("work");
        write(dir.path(), &m).unwrap();
        assert!(head_path(dir.path(), "work").exists());

        let back = read(dir.path(), "work").unwrap();
        assert_eq!(back.name, m.name);
        assert_eq!(back.created_at, m.created_at);
        assert_eq!(back.schema, CURRENT_SCHEMA);
        assert_eq!(back.tmux_version, "tmux 3.4");
        assert_eq!(back.state_dir, m.state_dir);
        assert_eq!(back.program, m.program);
    }

    #[test]
    fn read_missing_head_is_not_found() {
        let dir = tempdir().unwrap();
        let err = read(dir.path(), "ghost").unwrap_err();
        assert!(matches!(err, TmuxSessionError::NotFound(n) if n == "ghost"));
    }

    #[test]
    fn read_rejects_newer_schema() {
        let dir = tempdir().unwrap();
        let mut m = sample("future");
        m.schema = CURRENT_SCHEMA + 1;
        write(dir.path(), &m).unwrap();
        let err = read(dir.path(), "future").unwrap_err();
        assert!(matches!(err, TmuxSessionError::Other(msg) if msg.contains("newer")));
    }

    #[test]
    fn tmux_version_defaults_when_absent() {
        let dir = tempdir().unwrap();
        let mut v = serde_json::to_value(sample("old")).unwrap();
        v.as_object_mut().unwrap().remove("tmux_version");
        fs::write(
            head_path(dir.path(), "old"),
            serde_json::to_vec(&v).unwrap(),
        )
        .unwrap();
        assert_eq!(read(dir.path(), "old").unwrap().tmux_version, "");
    }

    #[test]
    fn list_names_sorted_and_only_heads() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        write(root, &sample("zeta")).unwrap();
        write(root, &sample("alpha")).unwrap();
        fs::create_dir(root.join("alpha.gen-1.state")).unwrap();
        fs::create_dir(root.join("dir.json")).unwrap();
        fs::write(root.join(".autosave-stamp"), b"").unwrap();
        fs::write(root.join(".json"), b"").unwrap();
        fs::write(root.join("notes.txt"), b"").unwrap();
        assert_eq!(list_names(root).unwrap(), vec!["alpha", "zeta"]);
    }

    #[test]
    fn list_names_missing_root_is_empty() {
        let dir = tempdir().unwrap();
        assert!(list_names(&dir.path().join("nope")).unwrap().is_empty());
    }

    #[test]
    fn head_stem_requires_dot_json_suffix() {
        assert_eq!(head_stem("work.json").as_deref(), Some("work"));
        assert_eq!(head_stem("my.proj.json").as_deref(), Some("my.proj"));
        assert_eq!(head_stem("json"), None);
        assert_eq!(head_stem(".json"), None);
        assert_eq!(head_stem("work.json.tmp"), None);
    }
}
