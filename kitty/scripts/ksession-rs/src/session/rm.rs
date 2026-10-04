//! `ksession rm <name>` — remove a saved session and all its sidecar state.
//!
//! Plan §C (and the v1 finish-line PRD): the on-disk artifacts for a single
//! save are
//!
//! - `<sessions_dir>/<name>.<head_ext>` (the "head" file whose presence
//!   defines the session — `.conf` for kitty, `.json` for the tmux-native
//!   store), and
//! - `<sessions_dir>/<name>.gen-<gen_us>(_<pid>)?.state/` (one or more
//!   gen-stamped state directories; typically one, but a stale collision
//!   retry from §5.7 can leave more than one for the same name).
//!
//! `rm` must atomically dismantle that set with the same crash-safety
//! discipline the save side observes: **never leave a half-deleted session
//! on disk**. The tactic is *tombstone-rename*: every artifact is first
//! renamed to `<original>.deleted.<pid>` (a single fast `rename(2)`), then
//! the renamed targets are removed. A crash between rename and remove
//! leaves only `.deleted.<pid>` debris, which is obviously garbage and
//! never confused with a live session by `list`, `restore`, or
//! [`crate::fsx::sweep_orphans_for`].
//!
//! The mechanism lives in [`remove_session_artifacts`], shared by the kitty
//! entry points here and by `tmux_session::rm`; only the head extension and
//! the error type differ between the two stores.
//!
//! ## IO error injection seam
//!
//! [`TombstoneHook`] is a test-only seam. It runs after **all** renames
//! complete and before any [`std::fs::remove_dir_all`] / [`std::fs::remove_file`]
//! call. Tests use [`TombstoneHook::fail_after_rename`] to simulate a
//! mid-rm crash and assert the on-disk state is `*.deleted.<pid>`-only.
//!
//! Production callers ([`crate::session::rm`] via [`run`]) pass
//! [`TombstoneHook::noop`] and the seam compiles away to a single closure
//! call returning `Ok(())`.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::error::KError;

/// Validate a session name against `^[A-Za-z0-9._-]+$`.
///
/// Returns `true` iff `name` is non-empty and every byte is an ASCII
/// alphanumeric, `.`, `_`, or `-`. Enforced **before** any filesystem
/// work so a hostile or fat-fingered name (e.g. `..`, `/etc/passwd`,
/// `foo bar`) can never escape into a `rename(2)` or `remove_dir_all`
/// call.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// Test-only hook that fires AFTER all tombstone renames complete and
/// BEFORE any delete. Returning an `io::Error` lets a test simulate a
/// crash mid-rm and assert that only `*.deleted.<pid>` artifacts remain
/// on disk (the acceptance-criteria check for the tombstone discipline).
pub struct TombstoneHook {
    /// `None` = noop (the production case). `Some(f)` is called once;
    /// if it returns `Err`, [`run_with_hook`] short-circuits with that
    /// error before any delete.
    inner: Option<Box<dyn FnMut() -> io::Result<()> + Send>>,
}

impl TombstoneHook {
    /// No-op hook. Production callers use this; the closure is never
    /// invoked.
    pub fn noop() -> Self {
        Self { inner: None }
    }

    /// Hook that returns the given error string as an
    /// `io::ErrorKind::Other` IO error on first invocation. Used by
    /// `tests/rm_tombstone.rs` to simulate a crash between rename and
    /// delete.
    pub fn fail_after_rename(msg: &'static str) -> Self {
        Self {
            inner: Some(Box::new(move || Err(io::Error::other(msg)))),
        }
    }

    fn fire(&mut self) -> io::Result<()> {
        match self.inner.as_mut() {
            Some(f) => f(),
            None => Ok(()),
        }
    }
}

/// Which kind of on-disk artifact a path is, so the delete pass knows
/// whether to `remove_file` or `remove_dir_all` without re-parsing the
/// (tombstoned) basename.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ArtifactKind {
    Head,
    StateDir,
}

#[derive(Debug, PartialEq, Eq)]
struct Artifact {
    path: PathBuf,
    kind: ArtifactKind,
}

/// Locate every artifact in `sessions_dir` that belongs to session `name`:
///
/// - `<name>.<head_ext>` (if present), and
/// - every `<name>.gen-*.state/` directory.
///
/// Returns the full absolute paths. Order is unspecified; callers must
/// not rely on it. Missing-directory `read_dir` errors are surfaced; an
/// absent head (without other artifacts) is **not** an error here — the
/// caller decides whether to report a missing-session error based on the
/// empty result.
fn collect_artifacts(sessions_dir: &Path, name: &str, head_ext: &str) -> io::Result<Vec<Artifact>> {
    let mut out = Vec::new();

    let head = sessions_dir.join(format!("{name}.{head_ext}"));
    if head.exists() {
        out.push(Artifact {
            path: head,
            kind: ArtifactKind::Head,
        });
    }

    // Scan for `<name>.gen-*.state/` directories. We re-use the existing
    // gen-stamp parser from `fsx` so the predicate matches the save-side
    // convention exactly (any drift between the two would silently miss
    // state dirs).
    let prefix = format!("{name}.gen-");
    let entries = fs::read_dir(sessions_dir)?;
    for ent in entries {
        let ent = match ent {
            Ok(e) => e,
            Err(_) => continue,
        };
        let fname = match ent.file_name().into_string() {
            Ok(s) => s,
            Err(_) => continue,
        };
        if !fname.starts_with(&prefix) || !fname.ends_with(".state") {
            continue;
        }
        // Confirm it parses as a gen-stamp owned by THIS name, not e.g.
        // `<name>foo.gen-1.state` where the prefix check is a false hit.
        match crate::fsx::parse_gen_stamp(&fname) {
            Some((parsed_name, _, _)) if parsed_name == name => {}
            _ => continue,
        }
        // Only directories qualify (matches save-side: state is always a
        // dir). A stray plain file with the same name is left alone.
        if !matches!(ent.file_type(), Ok(ft) if ft.is_dir()) {
            continue;
        }
        out.push(Artifact {
            path: ent.path(),
            kind: ArtifactKind::StateDir,
        });
    }

    Ok(out)
}

/// Append the `.deleted.<pid>` tombstone suffix to a path's final
/// component, preserving the parent. Returns the new path; the source is
/// untouched (the caller invokes `rename` to move it).
fn tombstone_path(orig: &Path, pid: u32) -> PathBuf {
    let parent = orig.parent().unwrap_or_else(|| Path::new(""));
    let basename = orig
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    parent.join(format!("{basename}.deleted.{pid}"))
}

/// Caller-resolved options for [`run`] / [`run_with_hook`].
pub struct RmOpts {
    /// Session name. Caller MUST validate via [`valid_name`] before
    /// passing — `run` re-validates as a defence-in-depth check.
    pub name: String,
    /// Sessions directory (typically [`crate::session::sessions_dir`]).
    pub sessions_dir: PathBuf,
}

/// Entry point for `ksession rm`.
///
/// See [`run_with_hook`] for the full contract; this is a thin wrapper
/// that passes [`TombstoneHook::noop`] and then performs best-effort
/// frecency cleanup.
pub fn run(opts: RmOpts) -> Result<(), KError> {
    let name = opts.name.clone();
    run_with_hook(opts, TombstoneHook::noop())?;
    // Frecency cleanup is a best-effort post-rm step.
    //
    // The Rust port does NOT yet have a native frecency implementation —
    // the store's atomic-write + flock semantics live in
    // `scripts/lib/frecency.sh`. Reimplementing them here (just to drop
    // ONE key on rm) would duplicate ~50 lines of code and a JSON+lock
    // contract that's already well-tested via `scripts/tests/frecency/`.
    // Shelling out to the lib is the pragmatic call: one extra `bash` fork
    // per `ksession rm` invocation is cheap, and any failure here MUST NOT
    // propagate — the rm itself already succeeded. If the user has no
    // frecency lib on disk (e.g. minimal install), the shell-out is a
    // silent no-op.
    let _ = invoke_frecency_remove(&name);
    Ok(())
}

/// Resolve the frecency lib path relative to this binary, then shell out
/// to `frecency_remove <key>`. Returns `Ok(())` on a clean run, `Err(_)`
/// on any failure (lib missing, bash unavailable, non-zero exit). Caller
/// MUST discard the error — frecency cleanup never blocks rm.
fn invoke_frecency_remove(key: &str) -> io::Result<()> {
    use std::process::Command;
    // The lib lives at scripts/lib/frecency.sh, two levels above the
    // ksession-rs crate root: scripts/ksession-rs/.. -> scripts/, then
    // scripts/lib/frecency.sh. The binary is typically invoked from a
    // path like ~/.config/kitty/scripts/ksession-rs/target/release/ksession,
    // so resolve via $0's grandparent dir as a fallback; otherwise try
    // a canonical install path.
    let lib_path = locate_frecency_lib()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "frecency.sh not found"))?;
    let script = format!(
        "source {q_lib} && frecency_remove {q_key}",
        q_lib = shell_quote(&lib_path.to_string_lossy()),
        q_key = shell_quote(key),
    );
    let status = Command::new("bash").arg("-c").arg(&script).status()?;
    if !status.success() {
        return Err(io::Error::other(format!(
            "frecency_remove exited with status {status}"
        )));
    }
    Ok(())
}

/// Locate `scripts/lib/frecency.sh`. Tries, in order:
///   1. `$KSESSION_FRECENCY_LIB` (env override; primarily for tests).
///   2. The path derived from the current executable: ascend until we hit
///      a directory containing `scripts/lib/frecency.sh`, OR until we find
///      a sibling `lib/frecency.sh` (when the binary lives directly in
///      `scripts/`).
///   3. `$HOME/.config/kitty/scripts/lib/frecency.sh` (default install).
fn locate_frecency_lib() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("KSESSION_FRECENCY_LIB") {
        let pb = PathBuf::from(p);
        if pb.is_file() {
            return Some(pb);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        let mut cur = exe.as_path();
        while let Some(parent) = cur.parent() {
            let candidate = parent.join("lib").join("frecency.sh");
            if candidate.is_file() {
                return Some(candidate);
            }
            let candidate2 = parent.join("scripts").join("lib").join("frecency.sh");
            if candidate2.is_file() {
                return Some(candidate2);
            }
            cur = parent;
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let pb = PathBuf::from(home).join(".config/kitty/scripts/lib/frecency.sh");
        if pb.is_file() {
            return Some(pb);
        }
    }
    None
}

/// Single-quote a string for bash. Backslash-escape embedded single quotes
/// by ending the quote, emitting `\'`, and reopening.
fn shell_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

/// Tally of what [`remove_session_artifacts`] found and deleted.
///
/// `is_empty()` means the session had no on-disk presence at all and
/// nothing was touched — callers turn that into their store-specific
/// "not found" error.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RemovedArtifacts {
    /// Whether `<name>.<head_ext>` existed and was removed.
    pub(crate) head: bool,
    /// Number of `<name>.gen-*.state/` directories removed.
    pub(crate) state_dirs: usize,
}

impl RemovedArtifacts {
    pub(crate) fn is_empty(&self) -> bool {
        !self.head && self.state_dirs == 0
    }
}

/// Tombstone-then-delete every artifact of session `name` whose head file
/// is `<sessions_dir>/<name>.<head_ext>`.
///
/// `name` MUST already be validated by the caller (`valid_name` /
/// `session::restore::validate_name`); a `debug_assert!` backs that up so
/// no unvalidated string can reach `rename(2)` in a debug build.
///
/// Sequence:
///
/// 1. Enumerate `<name>.<head_ext>` + every `<name>.gen-*.state/`
///    directory. If the enumeration is empty, return an empty
///    [`RemovedArtifacts`] without touching the filesystem.
/// 2. Rename each artifact to `<original>.deleted.<pid>`. The first
///    rename failure aborts (returning the IO error); already-renamed
///    artifacts stay tombstoned, which is the correct crash-equivalent
///    state.
/// 3. Fire the [`TombstoneHook`]. In production this is a noop; in tests
///    it can inject an IO error to simulate a crash before step 4.
/// 4. `remove_dir_all` each tombstoned state dir; `remove_file` the
///    tombstoned head. Per-target removal errors are surfaced so the
///    caller knows cleanup is incomplete.
pub(crate) fn remove_session_artifacts(
    sessions_dir: &Path,
    name: &str,
    head_ext: &str,
    mut hook: TombstoneHook,
) -> io::Result<RemovedArtifacts> {
    debug_assert!(valid_name(name), "caller must validate '{name}' first");

    let artifacts = collect_artifacts(sessions_dir, name, head_ext)?;
    if artifacts.is_empty() {
        return Ok(RemovedArtifacts::default());
    }

    let pid = std::process::id();

    // Step 1: tombstone-rename every artifact. We collect the tombstoned
    // paths so the delete pass touches only what we successfully renamed.
    let mut tombstoned: Vec<Artifact> = Vec::with_capacity(artifacts.len());
    for orig in artifacts {
        let dst = tombstone_path(&orig.path, pid);
        fs::rename(&orig.path, &dst)?;
        tombstoned.push(Artifact {
            path: dst,
            kind: orig.kind,
        });
    }

    // Step 2: injected-error seam. In prod this is a no-op; tests use it
    // to assert that a crash here leaves only `*.deleted.<pid>` artifacts
    // on disk (no half-deleted state).
    hook.fire()?;

    // Step 3: delete the tombstoned artifacts.
    let mut removed = RemovedArtifacts::default();
    for Artifact { path, kind } in tombstoned {
        match kind {
            ArtifactKind::StateDir => {
                fs::remove_dir_all(&path)?;
                removed.state_dirs += 1;
            }
            ArtifactKind::Head => {
                fs::remove_file(&path)?;
                removed.head = true;
            }
        }
    }

    Ok(removed)
}

/// Kitty-store `rm` with an optional post-rename hook for
/// crash-simulation tests.
///
/// Validates `name` against [`valid_name`] (rejecting with
/// [`KError::InvalidName`] *before* any filesystem work), then runs
/// [`remove_session_artifacts`] against the `.conf` head. An empty result
/// is reported as [`KError::NotFound`].
pub fn run_with_hook(opts: RmOpts, hook: TombstoneHook) -> Result<(), KError> {
    if !valid_name(&opts.name) {
        return Err(KError::InvalidName(opts.name));
    }

    let removed = remove_session_artifacts(&opts.sessions_dir, &opts.name, "conf", hook)?;
    if removed.is_empty() {
        return Err(KError::NotFound(opts.name));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn valid_name_accepts_simple_names() {
        assert!(valid_name("foo"));
        assert!(valid_name("foo-bar"));
        assert!(valid_name("foo_bar"));
        assert!(valid_name("foo.bar"));
        assert!(valid_name("Foo123"));
        assert!(valid_name("a"));
    }

    #[test]
    fn valid_name_accepts_dot_only_names_per_regex() {
        // The regex `^[A-Za-z0-9._-]+$` literally permits `.` and `..`.
        // Path traversal is blocked by the absence of `/` from the
        // character class, not by rejecting `.` outright; document the
        // behaviour here so a future tightener has a deliberate signal.
        assert!(valid_name("."));
        assert!(valid_name(".."));
    }

    #[test]
    fn valid_name_rejects_slashes_and_whitespace() {
        assert!(!valid_name("foo/bar"));
        assert!(!valid_name("foo bar"));
        assert!(!valid_name("../foo"));
        assert!(!valid_name("foo\nbar"));
        assert!(!valid_name("foo*"));
    }

    #[test]
    fn valid_name_rejects_empty() {
        assert!(!valid_name(""));
    }

    #[test]
    fn tombstone_path_appends_suffix() {
        let p = Path::new("/tmp/foo.conf");
        let t = tombstone_path(p, 42);
        assert_eq!(t, PathBuf::from("/tmp/foo.conf.deleted.42"));
    }

    #[test]
    fn tombstone_path_preserves_parent_for_state_dir() {
        let p = Path::new("/var/sessions/foo.gen-12345.state");
        let t = tombstone_path(p, 9);
        assert_eq!(
            t,
            PathBuf::from("/var/sessions/foo.gen-12345.state.deleted.9")
        );
    }

    /// Sorted paths of a collect result, kind discarded.
    fn paths(mut found: Vec<Artifact>) -> Vec<PathBuf> {
        found.sort_by(|a, b| a.path.cmp(&b.path));
        found.into_iter().map(|a| a.path).collect()
    }

    #[test]
    fn collect_artifacts_finds_conf_and_state_dirs() {
        let dir = tempdir().unwrap();
        let sessions = dir.path();
        fs::write(sessions.join("foo.conf"), b"# conf\n").unwrap();
        fs::create_dir(sessions.join("foo.gen-100.state")).unwrap();
        fs::create_dir(sessions.join("foo.gen-200_9.state")).unwrap();
        // Sibling unrelated session — must NOT appear.
        fs::write(sessions.join("bar.conf"), b"").unwrap();
        fs::create_dir(sessions.join("bar.gen-1.state")).unwrap();

        let found = collect_artifacts(sessions, "foo", "conf").unwrap();
        let mut expected = vec![
            sessions.join("foo.conf"),
            sessions.join("foo.gen-100.state"),
            sessions.join("foo.gen-200_9.state"),
        ];
        expected.sort();
        assert_eq!(paths(found), expected);
    }

    #[test]
    fn collect_artifacts_tags_head_and_state_dir_kinds() {
        let dir = tempdir().unwrap();
        let s = dir.path();
        fs::write(s.join("foo.json"), b"{}").unwrap();
        fs::create_dir(s.join("foo.gen-1.state")).unwrap();
        // The kitty head is not a head under the "json" extension.
        fs::write(s.join("foo.conf"), b"").unwrap();

        let mut found = collect_artifacts(s, "foo", "json").unwrap();
        found.sort_by(|a, b| a.path.cmp(&b.path));
        assert_eq!(
            found,
            vec![
                Artifact {
                    path: s.join("foo.gen-1.state"),
                    kind: ArtifactKind::StateDir,
                },
                Artifact {
                    path: s.join("foo.json"),
                    kind: ArtifactKind::Head,
                },
            ]
        );
    }

    #[test]
    fn collect_artifacts_returns_empty_for_unknown_name() {
        let dir = tempdir().unwrap();
        let found = collect_artifacts(dir.path(), "ghost", "conf").unwrap();
        assert!(found.is_empty());
    }

    #[test]
    fn collect_artifacts_ignores_name_prefix_collision() {
        // `<name>foo.gen-1.state` must NOT match name=`<name>` — the
        // parsed gen-stamp name has to equal `name` exactly.
        let dir = tempdir().unwrap();
        let s = dir.path();
        fs::create_dir(s.join("foo.gen-1.state")).unwrap();
        fs::create_dir(s.join("foobar.gen-1.state")).unwrap();
        let found = collect_artifacts(s, "foo", "conf").unwrap();
        assert_eq!(paths(found), vec![s.join("foo.gen-1.state")]);
    }

    #[test]
    fn remove_session_artifacts_reports_empty_without_touching_disk() {
        let dir = tempdir().unwrap();
        let removed =
            remove_session_artifacts(dir.path(), "ghost", "json", TombstoneHook::noop()).unwrap();
        assert!(removed.is_empty());
        assert_eq!(removed, RemovedArtifacts::default());
    }

    #[test]
    fn remove_session_artifacts_counts_head_and_state_dirs() {
        let dir = tempdir().unwrap();
        let s = dir.path();
        fs::write(s.join("foo.json"), b"{}").unwrap();
        fs::create_dir(s.join("foo.gen-1.state")).unwrap();
        fs::create_dir(s.join("foo.gen-2.state")).unwrap();
        fs::write(s.join("foo.gen-2.state/scrollback"), b"x").unwrap();

        let removed = remove_session_artifacts(s, "foo", "json", TombstoneHook::noop()).unwrap();
        assert_eq!(
            removed,
            RemovedArtifacts {
                head: true,
                state_dirs: 2,
            }
        );
        assert_eq!(fs::read_dir(s).unwrap().count(), 0, "nothing left behind");
    }

    #[test]
    fn remove_session_artifacts_leaves_only_tombstones_when_hook_fails() {
        let dir = tempdir().unwrap();
        let s = dir.path();
        fs::write(s.join("foo.json"), b"{}").unwrap();
        fs::create_dir(s.join("foo.gen-1.state")).unwrap();

        let err = remove_session_artifacts(
            s,
            "foo",
            "json",
            TombstoneHook::fail_after_rename("simulated crash"),
        )
        .expect_err("hook error must surface");
        assert_eq!(err.to_string(), "simulated crash");

        let pid = std::process::id();
        let mut left: Vec<String> = fs::read_dir(s)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        left.sort();
        assert_eq!(
            left,
            vec![
                format!("foo.gen-1.state.deleted.{pid}"),
                format!("foo.json.deleted.{pid}"),
            ]
        );
    }
}
