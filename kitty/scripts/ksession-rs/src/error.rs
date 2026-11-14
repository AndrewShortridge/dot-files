//! Library-level error type.
//!
//! Per RUST_PORT_PLAN §5.8, this is the fatal-error surface for the lib.
//! `AdapterError` lives separately (added in the adapter step) so per-window
//! capture failures can degrade to `Program::BareShell` without aborting the
//! whole save.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum KError {
    #[error("kitty @ ls failed: {0}")]
    KittyRemote(String),
    #[error("invalid session name '{0}'")]
    InvalidName(String),
    #[error("session '{0}' not found")]
    NotFound(String),
    /// The on-disk manifest claims a schema number this binary cannot
    /// read. Per ADR 0003, additive field changes ride on `serde(default)`
    /// without bumping `CURRENT_SCHEMA`; this variant fires only when a
    /// future binary writes a higher number to mark a genuinely breaking
    /// change.
    #[error("manifest schema {found} is newer than supported ({supported})")]
    SchemaMismatch { found: u32, supported: u32 },
    #[error("no OS windows matched")]
    NoTargets,
    /// `commit_session` attempted to rename `<name>.<ext>.tmp.<pid>` to
    /// the head `<name>.<ext>` (or the state dir) across a filesystem boundary;
    /// `rename(2)` returned `EXDEV`. Recovery is caller-driven (move
    /// `<sessions>` onto the same filesystem as the state-dir target).
    #[error("cross-filesystem rename: cannot rename {src:?} to {dst:?}")]
    CrossFilesystem {
        src: std::path::PathBuf,
        dst: std::path::PathBuf,
    },
    /// Phase 0 could not allocate a fresh gen-stamped state directory
    /// after the §5.7 retry loop exhausted its attempts (same µs + same
    /// pid + several `gen_us + N` retries all collided — only reachable
    /// from pathological intra-process reentrant save bursts).
    #[error("could not allocate a fresh gen-stamped state directory after {attempts} attempts")]
    GenCollision { attempts: u32 },
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}
