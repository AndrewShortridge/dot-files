//! `ksession tmux rm <name>` — delete a saved tmux-native session.
//!
//! The on-disk shape mirrors the kitty store with a different head file:
//! `<root>/<name>.json` plus every `<root>/<name>.gen-*.state/`. Removal
//! therefore reuses the kitty tombstone-rename-then-delete mechanism
//! ([`crate::session::rm::remove_session_artifacts`]) verbatim; only the
//! head extension and the error type differ.

use std::path::Path;

use crate::session::rm::{remove_session_artifacts, TombstoneHook};

use super::manifest::HEAD_EXT;
use super::TmuxSessionError;

/// Remove `<root>/<name>.json` and every `<root>/<name>.gen-*.state/`.
///
/// `name` is validated before any filesystem work. When nothing on disk
/// belongs to `name` — including when the root itself has never been
/// created — returns [`TmuxSessionError::NotFound`] without touching
/// anything.
pub fn run(root: &Path, name: &str) -> Result<(), TmuxSessionError> {
    super::validate_name(name)?;
    if !root.is_dir() {
        return Err(TmuxSessionError::NotFound(name.to_owned()));
    }
    let removed = remove_session_artifacts(root, name, HEAD_EXT, TombstoneHook::noop())?;
    if removed.is_empty() {
        return Err(TmuxSessionError::NotFound(name.to_owned()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn unknown_name_is_not_found() {
        let dir = tempdir().unwrap();
        let err = run(dir.path(), "ghost").unwrap_err();
        assert!(matches!(err, TmuxSessionError::NotFound(n) if n == "ghost"));
    }

    #[test]
    fn missing_root_is_not_found_not_io() {
        // `rm` never creates the store; on a fresh machine the root does
        // not exist and the answer is still "no such saved session".
        let dir = tempdir().unwrap();
        let root = dir.path().join("never-created");
        let err = run(&root, "ghost").unwrap_err();
        assert!(matches!(err, TmuxSessionError::NotFound(n) if n == "ghost"));
        assert!(!root.exists());
    }

    #[test]
    fn invalid_name_is_rejected_before_touching_disk() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("x.json"), b"{}").unwrap();
        let err = run(dir.path(), "../x").unwrap_err();
        assert!(matches!(err, TmuxSessionError::InvalidName(_)));
        assert!(dir.path().join("x.json").exists());
    }

    #[test]
    fn removes_head_and_every_state_dir() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        fs::write(root.join("work.json"), b"{}").unwrap();
        fs::create_dir_all(root.join("work.gen-1.state/tmux/work")).unwrap();
        fs::create_dir(root.join("work.gen-2_7.state")).unwrap();
        // Sibling session and a kitty-style head must survive.
        fs::write(root.join("other.json"), b"{}").unwrap();
        fs::create_dir(root.join("other.gen-1.state")).unwrap();
        fs::write(root.join("work.conf"), b"").unwrap();

        run(root, "work").unwrap();

        let mut left: Vec<String> = fs::read_dir(root)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        left.sort();
        assert_eq!(left, vec!["other.gen-1.state", "other.json", "work.conf"]);
    }

    #[test]
    fn state_dirs_without_head_still_count_as_present() {
        // A crashed save can leave a state dir with no head; `rm` must be
        // able to clean that up rather than reporting NotFound.
        let dir = tempdir().unwrap();
        fs::create_dir(dir.path().join("work.gen-1.state")).unwrap();
        run(dir.path(), "work").unwrap();
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
    }
}
