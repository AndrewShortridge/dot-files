//! `ksession tmux restore <name>` — replay a saved session's `restore.sh`.
//!
//! The generated script already does the whole job (stale-session kill,
//! window/pane rebuild, scrollback replay, layout, focus) and ends in a
//! runtime branch: `switch-client` when `$TMUX` is set, `attach-session`
//! otherwise. So restoring from inside a tmux client is just "run the
//! script with the environment passed through"; the script's own
//! live-session guard handles the already-running case (`KSESSION_FORCE=1`
//! rebuilds). The child's exit status is the command's exit status.

use std::path::Path;
use std::process::{Command, ExitCode};

use super::{manifest, validate_name, TmuxSessionError};

pub fn run(root: &Path, name: &str, force: bool) -> Result<ExitCode, TmuxSessionError> {
    let _span = crate::perf_span!(
        crate::perf::Level::Info,
        "tmux_session.restore",
        name = name,
        force = force,
    );
    validate_name(name)?;
    let m = manifest::read(root, name)?;
    let restore_sh = m.restore_sh();
    if !restore_sh.is_file() {
        return Err(TmuxSessionError::Other(format!(
            "restore script missing for '{name}': {}",
            restore_sh.display()
        )));
    }
    let status = restore_command(restore_sh, force).status()?;
    Ok(ExitCode::from(exit_code_of(status.code())))
}

/// `bash <restore_sh>` with the caller's environment inherited verbatim —
/// `TMUX` decides switch-vs-attach inside the script — plus
/// `KSESSION_FORCE=1` when the user asked to rebuild over a live session.
fn restore_command(restore_sh: &Path, force: bool) -> Command {
    let mut cmd = Command::new("bash");
    cmd.arg(restore_sh);
    if force {
        cmd.env("KSESSION_FORCE", "1");
    }
    cmd
}

/// Propagate the script's status; a signal death has no code and maps to
/// the generic failure exit, as does anything outside the `u8` range.
fn exit_code_of(code: Option<i32>) -> u8 {
    code.and_then(|c| u8::try_from(c).ok()).unwrap_or(1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn unknown_name_is_not_found() {
        let dir = tempdir().unwrap();
        let err = run(dir.path(), "ghost", false).unwrap_err();
        assert!(matches!(err, TmuxSessionError::NotFound(n) if n == "ghost"));
    }

    #[test]
    fn invalid_name_rejected_before_disk() {
        let dir = tempdir().unwrap();
        let err = run(dir.path(), "../x", false).unwrap_err();
        assert!(matches!(err, TmuxSessionError::InvalidName(_)));
    }

    #[test]
    fn force_sets_only_the_force_env() {
        let cmd = restore_command(Path::new("/tmp/r.sh"), true);
        let envs: Vec<_> = cmd.get_envs().collect();
        assert_eq!(
            envs,
            vec![(
                std::ffi::OsStr::new("KSESSION_FORCE"),
                Some(std::ffi::OsStr::new("1"))
            )]
        );
        assert_eq!(cmd.get_program(), "bash");
        assert_eq!(cmd.get_args().collect::<Vec<_>>(), vec!["/tmp/r.sh"]);

        let plain = restore_command(Path::new("/tmp/r.sh"), false);
        assert_eq!(plain.get_envs().count(), 0);
    }

    #[test]
    fn exit_code_propagates_and_defaults_to_one() {
        assert_eq!(exit_code_of(Some(0)), 0);
        assert_eq!(exit_code_of(Some(3)), 3);
        assert_eq!(exit_code_of(Some(300)), 1);
        assert_eq!(exit_code_of(Some(-1)), 1);
        assert_eq!(exit_code_of(None), 1);
    }
}
