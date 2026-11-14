//! `ksession tmux save` — capture one live tmux session into the store.
//!
//! Publish sequence (mirrors the kitty store's §B.4 shape):
//! 1. sweep orphaned `*.gen-*.state/` dirs whose head is gone;
//! 2. allocate `<root>/<name>.gen-<ts>.state/` under a [`fsx::StateTmpdir`]
//!    guard (Drop removes it on any early return);
//! 3. run the pure [`capture_session`] walk into it over the subprocess
//!    transport. Never control mode here: a control-mode attach is a tmux
//!    client, and its detach fires the user's `client-detached` hook —
//!    which runs `ksession tmux autosave --force`, which would attach
//!    again. The kitty adapter can afford the pipe because kitty, not a
//!    tmux hook, drives it;
//! 4. publish `<root>/<name>.json` LAST through [`fsx::commit_session`]
//!    — state dir fsynced, head written + fsynced, renamed into place as
//!    the sole commit point, guard disarmed;
//! 5. remove the generations the new head superseded, so re-saves do not
//!    pile up `<name>.gen-*.state/` dirs. Only dirs older than
//!    [`fsx::SWEEP_MIN_AGE`] are touched: the `status-right` tick and the
//!    `client-detached` hook can run two saves of the same name
//!    concurrently, and a younger sibling may be the other save's
//!    still-uncommitted state dir. (The sweep in step 1 reclaims whatever
//!    this step leaves, under the same age rule.)

use std::path::Path;

use chrono::Utc;

use super::manifest::{self, TmuxSessionManifest};
use super::{validate_name, TmuxSessionError, TmuxTarget};
use crate::adapter::default_registry;
use crate::adapter::tmux::{capture_session, SessionRef, TmuxCaptureError};
use crate::fsx;
use crate::session::save::{mkdir_gen_stamped, resolve_proc_root};
use crate::tmux_rpc::tmux_version_string;

pub struct SaveOpts {
    /// Saved-session name. [`save`] validates it, so lib callers need no
    /// pre-check; the CLI checks it earlier only to fail before any tmux
    /// subprocess runs.
    pub name: String,
    pub target: TmuxTarget,
    /// Capture per-pane scrollback sidecars.
    pub scrollback: bool,
}

pub struct SaveOutcome {
    /// Some pane or window captured less faithfully than the live state
    /// (ADR 0001) — the save is committed but the exit code is 2.
    pub degraded: bool,
    pub manifest: TmuxSessionManifest,
}

/// Save `opts.target` as `opts.name`. Fails (nothing published, state dir
/// removed) on an empty session, an unwritable store, or a tmux error.
pub async fn save(root: &Path, opts: SaveOpts) -> Result<SaveOutcome, TmuxSessionError> {
    let _span = crate::perf_span!(
        crate::perf::Level::Info,
        "tmux_session.save",
        name = opts.name,
        session = opts.target.session_name,
    );
    validate_name(&opts.name)?;
    fsx::sweep_orphans_for(root, manifest::HEAD_EXT);

    let state_dir = allocate_state_dir(root, &opts.name)?;
    let tmux_version = tmux_version_string().unwrap_or_default();
    let io = opts.target.cli();
    let session = SessionRef {
        name: &opts.target.session_name,
        id: opts.target.session_id,
    };
    let captured = capture_session(
        &io,
        &session,
        state_dir.path(),
        default_registry(),
        &resolve_proc_root(),
        opts.scrollback,
    )
    .await;
    let captured = captured.map_err(|e| capture_error(&opts.target.session_name, e))?;
    let degraded = captured.is_degraded();

    let manifest = TmuxSessionManifest {
        name: opts.name,
        created_at: Utc::now(),
        schema: manifest::CURRENT_SCHEMA,
        tmux_version,
        state_dir: state_dir.path().to_path_buf(),
        program: captured.program,
    };
    fsx::commit_session(
        state_dir,
        &manifest::head_bytes(&manifest)?,
        root,
        &manifest.name,
        manifest::HEAD_EXT,
    )
    .map_err(store_error)?;
    remove_superseded_generations(root, &manifest.name, &manifest.state_dir);

    for e in &captured.errors {
        eprintln!("ksession: tmux save {}: pane degraded: {e}", manifest.name);
    }
    Ok(SaveOutcome { degraded, manifest })
}

/// `save --auto` over `targets`: each session is saved as
/// `auto-<sanitized session name>`; sessions with no windows are skipped
/// silently (a fresh `tmux new` has nothing worth keeping).
///
/// Degrade-not-abort (ADR 0001) at session granularity: a session that
/// fails to save — typically one killed between `list-sessions` and its
/// own capture, a real race for the 2 s autosave tick — is reported on
/// stderr as `ksession: tmux save <name>: <error>` and the sweep moves on.
/// Returns whether any session degraded or failed, i.e. whether the
/// caller should exit 2.
pub async fn save_auto(root: &Path, targets: Vec<TmuxTarget>, scrollback: bool) -> bool {
    let mut degraded = false;
    for target in targets {
        let name = auto_name(&target.session_name);
        match save(
            root,
            SaveOpts {
                name: name.clone(),
                target,
                scrollback,
            },
        )
        .await
        {
            Ok(outcome) => degraded |= outcome.degraded,
            Err(TmuxSessionError::EmptySession(_)) => {}
            Err(e) => {
                eprintln!("ksession: tmux save {name}: {e}");
                degraded = true;
            }
        }
    }
    degraded
}

/// `auto-<session>` with every byte outside `[A-Za-z0-9._-]` replaced by
/// `-`, so any tmux session name (spaces, unicode, `#`) yields a valid
/// saved-session name. Lossy by design: the manifest keeps the real
/// session name.
pub fn auto_name(session_name: &str) -> String {
    let sanitized: String = session_name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '-'
            }
        })
        .collect();
    format!("auto-{sanitized}")
}

/// A fatal capture failure in `TmuxSessionError` terms. Pane-level
/// degradation never reaches here.
fn capture_error(session_name: &str, e: TmuxCaptureError) -> TmuxSessionError {
    match e {
        TmuxCaptureError::EmptySession(_) => {
            TmuxSessionError::EmptySession(session_name.to_string())
        }
        TmuxCaptureError::Io { source, .. } => TmuxSessionError::Io(source),
        TmuxCaptureError::ListWindows { source, .. } => source.into(),
        other @ TmuxCaptureError::InvalidSessionName(_) => {
            TmuxSessionError::Other(other.to_string())
        }
    }
}

/// A store-layer (`fsx` / gen-stamp) failure in `TmuxSessionError` terms:
/// plain I/O stays typed, the rest (gen collision, cross-filesystem
/// rename) is reported by its own message.
fn store_error(e: crate::error::KError) -> TmuxSessionError {
    match e {
        crate::error::KError::Io(io) => TmuxSessionError::Io(io),
        other => TmuxSessionError::Other(other.to_string()),
    }
}

/// `<root>/<name>.gen-<now_us>.state/`, guarded so an aborted save leaves
/// no half-populated directory behind.
fn allocate_state_dir(root: &Path, name: &str) -> Result<fsx::StateTmpdir, TmuxSessionError> {
    let gen_us = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0);
    let dir = mkdir_gen_stamped(root, name, gen_us).map_err(store_error)?;
    Ok(fsx::StateTmpdir::new(dir))
}

/// Delete every `<root>/<name>.gen-*.state/` except `keep` (the one the
/// freshly written head points at) and except dirs younger than
/// [`fsx::SWEEP_MIN_AGE`], which may belong to a concurrent save that has
/// not published yet. Best effort: a failure here leaves garbage for the
/// next sweep, never a broken save.
fn remove_superseded_generations(root: &Path, name: &str, keep: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    let cutoff = std::time::SystemTime::now()
        .checked_sub(fsx::SWEEP_MIN_AGE)
        .unwrap_or(std::time::UNIX_EPOCH);
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path == keep || !path.is_dir() {
            continue;
        }
        let is_ours = entry
            .file_name()
            .to_str()
            .and_then(fsx::parse_gen_stamp)
            .is_some_and(|(stem, _, _)| stem == name);
        // Unknown mtime counts as young: never delete what we can't date.
        let is_old = entry
            .metadata()
            .and_then(|m| m.modified())
            .is_ok_and(|mtime| mtime < cutoff);
        if is_ours && is_old {
            if let Err(e) = std::fs::remove_dir_all(&path) {
                eprintln!(
                    "ksession: tmux save {name}: could not remove superseded {}: {e}",
                    path.display()
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn auto_name_keeps_valid_chars() {
        assert_eq!(auto_name("work"), "auto-work");
        assert_eq!(auto_name("my-proj_2.0"), "auto-my-proj_2.0");
    }

    #[test]
    fn auto_name_replaces_everything_else_with_dash() {
        assert_eq!(auto_name("my proj"), "auto-my-proj");
        assert_eq!(auto_name("a/b:c#d"), "auto-a-b-c-d");
        assert_eq!(auto_name("héllo"), "auto-h-llo");
        assert_eq!(auto_name(""), "auto-");
    }

    #[test]
    fn auto_name_is_always_a_valid_saved_name() {
        for s in ["work", "my proj", "a/b:c#d", "héllo", "  ", "\t"] {
            validate_name(&auto_name(s)).expect(s);
        }
    }

    /// Age `path` past `SWEEP_MIN_AGE` so the cleanup is allowed to touch it.
    fn backdate(path: &Path) {
        let old = std::time::SystemTime::now() - fsx::SWEEP_MIN_AGE * 2;
        std::fs::File::open(path)
            .unwrap()
            .set_modified(old)
            .unwrap();
    }

    #[test]
    fn superseded_generations_are_removed_but_kept_one_and_others_survive() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        let keep = root.join("work.gen-3.state");
        for d in [
            "work.gen-1.state",
            "work.gen-2_77.state",
            "work.gen-3.state",
            "other.gen-1.state",
            "work.state",
        ] {
            std::fs::create_dir(root.join(d)).unwrap();
            backdate(&root.join(d));
        }
        std::fs::write(root.join("work.json"), b"{}").unwrap();

        remove_superseded_generations(root, "work", &keep);

        let mut left: Vec<String> = std::fs::read_dir(root)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        left.sort();
        assert_eq!(
            left,
            vec![
                "other.gen-1.state",
                "work.gen-3.state",
                "work.json",
                "work.state"
            ]
        );
    }

    #[test]
    fn superseded_generations_younger_than_sweep_min_age_survive() {
        // A sibling younger than SWEEP_MIN_AGE may be a concurrent save's
        // not-yet-published state dir (status tick vs detach hook);
        // deleting it would leave that save's head pointing at nothing.
        let dir = tempdir().unwrap();
        let root = dir.path();
        let keep = root.join("work.gen-3.state");
        for d in ["work.gen-1.state", "work.gen-2.state", "work.gen-3.state"] {
            std::fs::create_dir(root.join(d)).unwrap();
        }
        backdate(&root.join("work.gen-1.state"));

        remove_superseded_generations(root, "work", &keep);

        assert!(
            !root.join("work.gen-1.state").exists(),
            "old sibling removed"
        );
        assert!(root.join("work.gen-2.state").exists(), "young sibling kept");
        assert!(keep.exists());
    }

    #[test]
    fn capture_error_maps_empty_session_to_typed_variant() {
        let e = capture_error("demo", TmuxCaptureError::EmptySession("demo".into()));
        assert!(matches!(e, TmuxSessionError::EmptySession(s) if s == "demo"));
        let e = capture_error("demo", TmuxCaptureError::InvalidSessionName("a.b".into()));
        assert!(matches!(e, TmuxSessionError::Other(msg) if msg.contains("a.b")));
    }

    #[test]
    fn allocate_state_dir_creates_guarded_gen_dir() {
        let dir = tempdir().unwrap();
        let path = {
            let guard = allocate_state_dir(dir.path(), "demo").unwrap();
            let p = guard.path().to_path_buf();
            assert!(p.is_dir());
            let base = p.file_name().unwrap().to_str().unwrap().to_string();
            assert_eq!(
                fsx::parse_gen_stamp(&base).map(|(n, _, _)| n).as_deref(),
                Some("demo")
            );
            p
        };
        // Guard dropped without commit → directory removed.
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn save_auto_continues_past_a_vanished_session() {
        // Simulates the autosave race: `ghost` was listed by `list-sessions`
        // and killed before its own capture. The sweep must report it and
        // still save `demo`, returning the exit-2 tally.
        use crate::tmux_rpc::tests::{tmux_available, IsolatedTmux};
        if !tmux_available() {
            eprintln!("skip: tmux not on PATH");
            return;
        }
        let tx = IsolatedTmux::new().await;
        let socket_path = tx.socket_path().await;
        let root = tempdir().unwrap();

        let ghost = TmuxTarget {
            socket_path: socket_path.clone(),
            session_id: 999,
            session_name: "ghost".into(),
        };
        let demo = TmuxTarget {
            socket_path,
            session_id: tx.demo_session_id().await,
            session_name: "demo".into(),
        };

        let degraded = save_auto(root.path(), vec![ghost, demo], false).await;

        assert!(degraded, "a vanished session degrades the sweep");
        assert!(
            !manifest::head_path(root.path(), "auto-ghost").exists(),
            "nothing published for the vanished session"
        );
        let saved = manifest::read(root.path(), "auto-demo").expect("demo still saved");
        assert_eq!(saved.session_name(), "demo");
    }
}
