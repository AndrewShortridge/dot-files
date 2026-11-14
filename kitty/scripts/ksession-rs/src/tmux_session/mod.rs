//! `ksession tmux …` — the tmux-native session manager (ADR 0009).
//!
//! Sidesteps `crate::session` (which snapshots kitty via `kitty @ ls`)
//! and drives the tmux layers directly: target resolution from the
//! process's own `$TMUX`, the pure `adapter::tmux::capture_session`
//! walk, `tmux_rpc` codegen, `fsx` atomic publish. Storage is a separate
//! root from the kitty store (`<root>/<name>.json` heads +
//! `<name>.gen-<ts>.state/` dirs), so neither store can sweep the other.
//!
//! Module map: [`manifest`] (head file), [`save`], [`restore`], [`list`],
//! [`show`], [`rm`], [`autosave`]; this file owns the shared pieces —
//! error type, storage root, name validation, [`TmuxTarget`] resolution,
//! and the CLI dispatch [`run`].

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use crate::cli::tmux::TmuxCommand;
use crate::tmux_rpc::{parse_tmux_env, TmuxCli, TmuxEnvInfo, TmuxError, TmuxIo};

pub mod autosave;
pub mod list;
pub mod manifest;
pub mod restore;
pub mod rm;
pub mod save;
pub mod show;

/// Fatal errors of the tmux-native commands. Per-pane degradation never
/// lands here (ADR 0001) — it becomes exit code 2 via `save::SaveOutcome`.
#[derive(Debug, thiserror::Error)]
pub enum TmuxSessionError {
    #[error("not inside tmux (set --session)")]
    NotInsideTmux,
    #[error("invalid session name '{0}' (allowed: A-Z a-z 0-9 . _ -)")]
    InvalidName(String),
    #[error("no saved tmux session '{0}'")]
    NotFound(String),
    #[error("tmux session '{0}' has no windows")]
    EmptySession(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    /// A tmux transport failure, kept typed for callers. Displayed as
    /// tmux's own stderr when it reported any — what the user would see
    /// running the command by hand; the binary already prefixes
    /// `ksession: tmux: `.
    #[error("{}", tmux_error_text(.0))]
    Tmux(#[from] TmuxError),
    /// `--session <name>` names no live session on the server. Same wording
    /// tmux uses, since that is what `-t` would have said.
    #[error("can't find session: {0}")]
    NoSuchSession(String),
    /// `$TMUX` names a session id the server no longer has — the client's
    /// session was killed under it.
    #[error("session ${0} from $TMUX no longer exists")]
    AmbientSessionGone(u32),
    #[error("{0}")]
    Other(String),
}

/// Display text for [`TmuxSessionError::Tmux`]: bare subprocess stderr
/// when present, the variant's own message otherwise.
fn tmux_error_text(e: &TmuxError) -> String {
    match e {
        TmuxError::Subprocess { stderr, .. } if !stderr.trim().is_empty() => {
            stderr.trim().to_string()
        }
        other => other.to_string(),
    }
}

/// Where saved tmux sessions live: `$KSESSION_TMUX_SESSIONS_DIR`, else
/// `$XDG_DATA_HOME/ksession/tmux-sessions`, else
/// `~/.local/share/ksession/tmux-sessions`. Resolution only — the
/// read-only commands treat a missing root as an empty store, so only
/// the save paths create it ([`writable_sessions_root`]).
pub fn sessions_root() -> Result<PathBuf, TmuxSessionError> {
    sessions_root_from(
        std::env::var_os("KSESSION_TMUX_SESSIONS_DIR"),
        std::env::var_os("XDG_DATA_HOME"),
        std::env::var_os("HOME"),
    )
    .ok_or_else(|| TmuxSessionError::Other("cannot resolve sessions root: HOME unset".into()))
}

/// [`sessions_root`], created if missing. For commands that publish.
fn writable_sessions_root() -> Result<PathBuf, TmuxSessionError> {
    let root = sessions_root()?;
    std::fs::create_dir_all(&root)?;
    Ok(root)
}

/// Pure precedence behind [`sessions_root`]; empty values count as unset.
fn sessions_root_from(
    explicit: Option<std::ffi::OsString>,
    xdg_data_home: Option<std::ffi::OsString>,
    home: Option<std::ffi::OsString>,
) -> Option<PathBuf> {
    let non_empty = |v: Option<std::ffi::OsString>| v.filter(|s| !s.is_empty()).map(PathBuf::from);
    if let Some(dir) = non_empty(explicit) {
        return Some(dir);
    }
    if let Some(data) = non_empty(xdg_data_home) {
        return Some(data.join("ksession").join("tmux-sessions"));
    }
    non_empty(home).map(|h| h.join(".local/share/ksession/tmux-sessions"))
}

/// Saved-session names share the kitty store's rule (`^[A-Za-z0-9._-]+$`)
/// so a name is valid for both managers and can never escape the root.
pub fn validate_name(name: &str) -> Result<(), TmuxSessionError> {
    crate::session::restore::validate_name(name)
        .map_err(|_| TmuxSessionError::InvalidName(name.to_string()))
}

// ---------- target resolution ----------

/// A tmux session addressed precisely enough to capture it: the server
/// socket (every subprocess connects through it) and the session's id
/// and name on that server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxTarget {
    pub socket_path: PathBuf,
    /// Numeric part of tmux's `$<N>` session id.
    pub session_id: u32,
    pub session_name: String,
}

impl TmuxTarget {
    /// Subprocess transport pinned to this target's server.
    pub fn cli(&self) -> TmuxCli {
        TmuxCli::at_socket(&self.socket_path)
    }
}

/// What the process's own `$TMUX` says about where it runs. `None`
/// outside tmux; inside, the session id is itself optional because
/// tmux-spawned jobs (`status-right #()`, hooks) run with `-1` while the
/// socket is still the right server for `--all`/`--session`.
fn ambient() -> Option<TmuxEnvInfo> {
    std::env::var("TMUX").ok().and_then(|v| parse_tmux_env(&v))
}

/// Transport for the ambient server: the socket from `$TMUX` when inside
/// tmux, else whatever the `tmux` binary picks (the default socket).
fn ambient_cli(ambient: Option<&TmuxEnvInfo>) -> TmuxCli {
    ambient.map_or_else(TmuxCli::default, |a| TmuxCli::at_socket(&a.socket_path))
}

/// Tab-separated so neither a socket path nor a session name containing
/// spaces can shift the columns. tmux does not forbid tabs in session
/// names, but such a name is not addressable by `-t` anyway, so the
/// parser simply treats the rest of the line as the name.
const LIST_SESSIONS_FORMAT: &str = "#{socket_path}\t#{session_id}\t#{session_name}";

/// Every session on the server behind `io`, server order.
async fn list_targets(io: &dyn TmuxIo) -> Result<Vec<TmuxTarget>, TmuxSessionError> {
    let raw = io
        .run(&["list-sessions", "-F", LIST_SESSIONS_FORMAT])
        .await?;
    Ok(parse_list_sessions(&raw))
}

/// Parse [`LIST_SESSIONS_FORMAT`] rows; malformed lines are skipped.
fn parse_list_sessions(raw: &str) -> Vec<TmuxTarget> {
    raw.lines()
        .filter_map(|line| {
            let mut cols = line.splitn(3, '\t');
            let socket_path = cols.next().filter(|s| !s.is_empty())?;
            let session_id = cols.next()?.strip_prefix('$')?.parse().ok()?;
            let session_name = cols.next()?;
            Some(TmuxTarget {
                socket_path: PathBuf::from(socket_path),
                session_id,
                session_name: session_name.to_string(),
            })
        })
        .collect()
}

/// The session to save: `--session <name>` on the ambient server, else
/// the session this process runs in (`$TMUX`). Outside tmux with no
/// `--session` there is nothing to resolve.
pub async fn resolve_target(session: Option<&str>) -> Result<TmuxTarget, TmuxSessionError> {
    let _span = crate::perf_span!(crate::perf::Level::Debug, "tmux_session.resolve_target");
    let ambient = ambient();
    let io = ambient_cli(ambient.as_ref());
    match (session, ambient.and_then(|a| a.session_id)) {
        (Some(name), _) => list_targets(&io)
            .await?
            .into_iter()
            .find(|t| t.session_name == name)
            .ok_or_else(|| TmuxSessionError::NoSuchSession(name.to_string())),
        (None, Some(session_id)) => list_targets(&io)
            .await?
            .into_iter()
            .find(|t| t.session_id == session_id)
            .ok_or(TmuxSessionError::AmbientSessionGone(session_id)),
        (None, None) => Err(TmuxSessionError::NotInsideTmux),
    }
}

/// Every session on the ambient server (`save --auto --all`, `autosave`).
pub async fn resolve_all_targets() -> Result<Vec<TmuxTarget>, TmuxSessionError> {
    let _span = crate::perf_span!(
        crate::perf::Level::Debug,
        "tmux_session.resolve_all_targets"
    );
    list_targets(&ambient_cli(ambient().as_ref())).await
}

// ---------- dispatch ----------

/// `ksession tmux <subcmd>` dispatcher invoked by `src/bin/ksession.rs`.
/// Exit codes: 0 ok, 2 saved-but-degraded (ADR 0001); fatal errors are
/// returned for the binary to print and map to 1.
pub fn run(cmd: TmuxCommand) -> Result<ExitCode, TmuxSessionError> {
    match cmd {
        TmuxCommand::Save {
            name,
            // Clap: `name` is `None` exactly when `--auto` is given.
            auto: _,
            all,
            session,
            no_scrollback,
        } => {
            let root = writable_sessions_root()?;
            let scrollback = !no_scrollback && crate::adapter::tmux::scrollback_enabled();
            runtime()?.block_on(run_save(&root, name, all, session.as_deref(), scrollback))
        }
        TmuxCommand::Restore { name, force } => restore::run(&sessions_root()?, &name, force),
        TmuxCommand::List { porcelain } => {
            list::run(&sessions_root()?, porcelain, &mut std::io::stdout().lock())?;
            Ok(ExitCode::SUCCESS)
        }
        TmuxCommand::Show { name } => {
            show::run(&sessions_root()?, &name, &mut std::io::stdout().lock())?;
            Ok(ExitCode::SUCCESS)
        }
        TmuxCommand::Rm { name } => {
            rm::run(&sessions_root()?, &name)?;
            Ok(ExitCode::SUCCESS)
        }
        TmuxCommand::Autosave { every, force } => {
            let every = autosave::parse_every(&every)?;
            let root = writable_sessions_root()?;
            let scrollback = crate::adapter::tmux::scrollback_enabled();
            runtime()?.block_on(autosave::run(&root, every, force, scrollback))
        }
    }
}

/// `save` in its three shapes: named, `--auto`, `--auto --all`. Clap has
/// already enforced "name xor --auto" and "--all needs --auto", so a
/// missing name means `--auto`. A named save validates the name before
/// any tmux subprocess runs: a bad name is a bad name whether or not the
/// caller is inside tmux.
async fn run_save(
    root: &Path,
    name: Option<String>,
    all: bool,
    session: Option<&str>,
    scrollback: bool,
) -> Result<ExitCode, TmuxSessionError> {
    let degraded = match name {
        None if all => save::save_auto(root, resolve_all_targets().await?, scrollback).await,
        None => save::save_auto(root, vec![resolve_target(session).await?], scrollback).await,
        Some(name) => {
            validate_name(&name)?;
            let target = resolve_target(session).await?;
            save::save(
                root,
                save::SaveOpts {
                    name,
                    target,
                    scrollback,
                },
            )
            .await?
            .degraded
        }
    };
    Ok(exit_code(degraded))
}

/// ADR 0001: a committed save with degraded panes exits 2, not 1.
pub(crate) fn exit_code(degraded: bool) -> ExitCode {
    if degraded {
        ExitCode::from(2)
    } else {
        ExitCode::SUCCESS
    }
}

/// Current-thread runtime, like the kitty `save` path: the work is a
/// handful of subprocesses / one control pipe, not CPU-bound fan-out.
fn runtime() -> Result<tokio::runtime::Runtime, TmuxSessionError> {
    Ok(tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    #[test]
    fn root_precedence_explicit_then_xdg_then_home() {
        let os = |s: &str| Some(OsString::from(s));
        assert_eq!(
            sessions_root_from(os("/explicit"), os("/xdg"), os("/home/u")),
            Some(PathBuf::from("/explicit"))
        );
        assert_eq!(
            sessions_root_from(None, os("/xdg"), os("/home/u")),
            Some(PathBuf::from("/xdg/ksession/tmux-sessions"))
        );
        assert_eq!(
            sessions_root_from(os(""), os(""), os("/home/u")),
            Some(PathBuf::from("/home/u/.local/share/ksession/tmux-sessions"))
        );
        assert_eq!(sessions_root_from(None, None, None), None);
    }

    #[test]
    fn validate_name_mirrors_kitty_rules() {
        assert!(validate_name("work-2.proj_a").is_ok());
        for bad in ["", "a b", "../x", "a/b", "a:b", "é"] {
            assert!(
                matches!(validate_name(bad), Err(TmuxSessionError::InvalidName(n)) if n == bad),
                "{bad:?} must be rejected"
            );
        }
    }

    #[test]
    fn ambient_cli_pins_socket_only_inside_tmux() {
        let inside = TmuxEnvInfo {
            socket_path: PathBuf::from("/tmp/tmux-1000/x"),
            server_pid: 12345,
            session_id: None,
        };
        assert_eq!(
            ambient_cli(Some(&inside)),
            TmuxCli::at_socket("/tmp/tmux-1000/x")
        );
        assert_eq!(ambient_cli(None), TmuxCli::default());
    }

    #[test]
    fn parse_list_sessions_rows() {
        let raw = "/tmp/tmux-1000/k\t$0\tdemo\n\
                   /tmp/tmux-1000/k\t$7\tmy proj\twith\ttabs\n\
                   broken line\n\
                   /tmp/tmux-1000/k\t7\tno-dollar\n";
        let got = parse_list_sessions(raw);
        assert_eq!(
            got,
            vec![
                TmuxTarget {
                    socket_path: PathBuf::from("/tmp/tmux-1000/k"),
                    session_id: 0,
                    session_name: "demo".into(),
                },
                TmuxTarget {
                    socket_path: PathBuf::from("/tmp/tmux-1000/k"),
                    session_id: 7,
                    session_name: "my proj\twith\ttabs".into(),
                },
            ]
        );
    }

    #[test]
    fn tmux_error_stays_typed_and_displays_bare_stderr() {
        let e = TmuxSessionError::from(TmuxError::Subprocess {
            subcommand: "list-sessions".into(),
            status: 1,
            stderr: "no server running on /tmp/tmux-1000/default\n".into(),
        });
        assert!(matches!(
            e,
            TmuxSessionError::Tmux(TmuxError::Subprocess { .. })
        ));
        assert_eq!(e.to_string(), "no server running on /tmp/tmux-1000/default");

        let e = TmuxSessionError::from(TmuxError::Timeout);
        assert!(matches!(e, TmuxSessionError::Tmux(TmuxError::Timeout)));
        assert_eq!(e.to_string(), "tmux subprocess timed out");

        // Empty stderr falls back to the variant's own message.
        let e = TmuxSessionError::from(TmuxError::Subprocess {
            subcommand: "list-sessions".into(),
            status: 1,
            stderr: "  \n".into(),
        });
        assert_eq!(e.to_string(), "tmux list-sessions: exit 1:   \n");
    }

    #[test]
    fn resolution_errors_keep_tmux_wording() {
        assert_eq!(
            TmuxSessionError::NoSuchSession("work".into()).to_string(),
            "can't find session: work"
        );
        assert_eq!(
            TmuxSessionError::AmbientSessionGone(3).to_string(),
            "session $3 from $TMUX no longer exists"
        );
    }
}
