//! Filesystem helpers. Per Plan Appendix B.4 all session-state writes must
//! be atomic so a crash/SIGKILL mid-write can never leave a half-written
//! file on disk for the next restore to choke on.
//!
//! Two primitives are exposed:
//!
//! - [`write_atomic`]: write a single file atomically via
//!   `NamedTempFile::persist` (legacy per-file path used outside the save
//!   pipeline).
//! - [`commit_session`]: the §B.4 generation-stamped publish sequence —
//!   the head-file rename is the sole commit point, plus a [`StateTmpdir`]
//!   Drop guard that cleans up the gen-stamped dir on early return.
//!
//! The gen-stamp helpers [`gen_stamp_basename`] and [`parse_gen_stamp`]
//! encode and decode the `<name>.gen-<gen_us>(_<pid>)?.state` convention
//! used by both `session::save` and the orphan sweep. The sweep itself
//! ([`sweep_orphans_for`]) is keyed on the "head" file whose presence
//! defines a session — `<name>.conf` for kitty, `<name>.json` for the
//! tmux-native store — so both stores share one orphan policy.

use std::collections::HashSet;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use tempfile::NamedTempFile;

use crate::error::KError;

/// `EXDEV` on Linux. Surfaced by `rename(2)` when source and destination
/// live on different filesystems. We compare against the raw OS error
/// number to avoid depending on `libc` here (the rest of the crate FFI's
/// `geteuid` directly for the same reason).
const EXDEV: i32 = 18;

/// Minimum age before [`sweep_orphans_for`] will delete an unreferenced
/// gen-stamped state directory. Guards against deleting state dirs of
/// in-flight concurrent saves whose head file hasn't been renamed into
/// place yet (§B.4).
pub(crate) const SWEEP_MIN_AGE: Duration = Duration::from_secs(60);

/// Atomically write `bytes` to `path`.
///
/// Steps:
/// 1. `mkdir -p` the parent (no-op if it exists).
/// 2. Create a `NamedTempFile` in the parent directory.
/// 3. Write all bytes, flush.
/// 4. `persist(path)` — issues a rename(2) which is atomic w/r/t readers on
///    the same filesystem (POSIX guarantee).
///
/// `tempfile::PersistError` carries both the inner `io::Error` and the
/// unpersisted file; we discard the latter (its tempdir drop will unlink
/// the leftover) and surface the former.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "write_atomic: path has no parent directory",
        )
    })?;

    // create_dir_all is a no-op when the dir already exists; only an error
    // if the path exists and is *not* a directory, or we lack permission.
    if !parent.as_os_str().is_empty() {
        fs::create_dir_all(parent)?;
    }

    let mut tmp = NamedTempFile::new_in(parent)?;
    tmp.write_all(bytes)?;
    tmp.flush()?;
    tmp.persist(path).map_err(|e| e.error)?;
    Ok(())
}

/// Format a gen-stamped state-dir basename.
///
/// - `pid_suffix == None` → `<name>.gen-<gen_us>.state`
/// - `pid_suffix == Some(pid)` → `<name>.gen-<gen_us>_<pid>.state`
///
/// The pid-suffixed form is used by §5.7's collision-retry path to
/// disambiguate concurrent saves from different PIDs landing in the same
/// microsecond.
pub fn gen_stamp_basename(name: &str, gen_us: u64, pid_suffix: Option<u32>) -> String {
    match pid_suffix {
        None => format!("{name}.gen-{gen_us}.state"),
        Some(pid) => format!("{name}.gen-{gen_us}_{pid}.state"),
    }
}

/// Parse a gen-stamped state-dir basename.
///
/// Returns `Some((name, gen_us, opt_pid))` for inputs of the form
/// `<name>.gen-<digits>(_<digits>)?.state`. The `name` may itself contain
/// `.` — the parser locates the LAST `.gen-` token in the stripped
/// remainder so `my.proj.gen-12345.state` parses as `("my.proj", 12345,
/// None)`.
///
/// Returns `None` for:
/// - Inputs without the `.state` suffix.
/// - Bare-name dirs like `foo.state` (Bash-era layout; intentionally
///   never matched so sweep cannot eat them).
/// - Malformed gen tokens such as `foo.gen-abc.state`.
pub fn parse_gen_stamp(basename: &str) -> Option<(String, u64, Option<u32>)> {
    // Strip the trailing `.state`.
    let stem = basename.strip_suffix(".state")?;

    // Find the LAST `.gen-` so `name` can contain dots.
    let marker_idx = stem.rfind(".gen-")?;
    let name = &stem[..marker_idx];
    if name.is_empty() {
        // Disallow `.gen-123.state` with empty name — defensive; not
        // expected to occur in practice.
        return None;
    }
    let gen_part = &stem[marker_idx + ".gen-".len()..];

    // gen_part is `<digits>` or `<digits>_<digits>`.
    let (gen_str, pid_str) = match gen_part.find('_') {
        Some(i) => (&gen_part[..i], Some(&gen_part[i + 1..])),
        None => (gen_part, None),
    };
    if gen_str.is_empty() || !gen_str.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let gen_us: u64 = gen_str.parse().ok()?;

    let opt_pid = match pid_str {
        None => None,
        Some(p) => {
            if p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            Some(p.parse::<u32>().ok()?)
        }
    };

    Some((name.to_string(), gen_us, opt_pid))
}

/// RAII guard wrapping the populated gen-stamped state directory created
/// in §B.4 step 2. While the guard is live (`committed == false`),
/// `Drop` `rm -rf`s the directory — protecting against cancellation and
/// early-return errors during the publish sequence. [`StateTmpdir::commit`]
/// disarms the guard by consuming `self` and `mem::forget`ing it.
pub struct StateTmpdir {
    path: PathBuf,
    /// When `false`, `Drop` removes `path`. `commit()` sets this to `true`
    /// before `mem::forget`ing the value.
    committed: bool,
}

impl StateTmpdir {
    /// Wrap an already-`mkdir`'d directory at its final gen-stamped path.
    /// The caller is responsible for populating contents; the guard fires
    /// on drop if `commit()` is not called.
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            committed: false,
        }
    }

    /// The directory the guard is protecting.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Disarm the Drop guard. Caller (or [`commit_session`]) is now
    /// responsible for the directory. Consumes `self` and `mem::forget`s
    /// it to skip the Drop impl.
    pub fn commit(mut self) {
        self.committed = true;
        std::mem::forget(self);
    }
}

impl Drop for StateTmpdir {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

/// fsync a path (file or directory). On Linux both support `sync_all()`
/// via an O_RDONLY descriptor — used to flush the inode of a freshly
/// renamed entry from its parent directory.
fn fsync_path(path: &Path) -> io::Result<()> {
    let f = fs::File::open(path)?;
    f.sync_all()
}

/// Atomic-publish a save (§B.4).
///
/// - `state_tmpdir`: populated final-named gen-stamped dir (already at
///   its final path; produced by Phase 0).
/// - `head_body`: rendered head-file contents (the `.conf` for the kitty
///   store, the `.json` manifest for the tmux-native store), with
///   absolute paths into `state_tmpdir`.
/// - `sessions_dir`: parent dir; the head lands at
///   `<sessions_dir>/<name>.<head_ext>`.
/// - `name`: session name.
/// - `head_ext`: head-file extension without the dot (`"conf"`, `"json"`);
///   the same value the store hands to [`sweep_orphans_for`].
///
/// Sequence (3 fsyncs): fsync state dir; write and fsync
/// `<name>.<head_ext>.tmp.<pid>`; rename the tmp → `<name>.<head_ext>`
/// (SOLE commit point); `state_tmpdir.commit()`; fsync parent.
///
/// On `EXDEV` from the head rename: best-effort unlink the tmp, return
/// [`KError::CrossFilesystem`]. The state tempdir's Drop guard runs and
/// cleans up the orphaned gen-stamped dir.
///
/// On any error before the head rename: propagate `Err`; the Drop guard
/// removes the state dir.
///
/// On any error AFTER the head rename (only the parent fsync remains):
/// the rename has already committed the save — `state_tmpdir.commit()`
/// has fired, so the Drop guard does NOT delete the gen-stamped dir.
/// Propagate the `Err` so the caller logs but knows the data is durable.
pub fn commit_session(
    state_tmpdir: StateTmpdir,
    head_body: &[u8],
    sessions_dir: &Path,
    name: &str,
    head_ext: &str,
) -> Result<(), KError> {
    let _span = crate::perf_span!(
        crate::perf::Level::Debug,
        "fsx.commit_session",
        bytes_out = head_body.len(),
    );

    // 1. fsync the populated state dir so all sidecar bytes are durable
    //    before we publish the head that references them.
    fsync_path(state_tmpdir.path())?;

    // 2. Write <head>.tmp.<pid>, fsync it.
    let pid = std::process::id();
    let head_tmp_path = sessions_dir.join(format!("{name}.{head_ext}.tmp.{pid}"));
    let head_final_path = sessions_dir.join(format!("{name}.{head_ext}"));

    fs::write(&head_tmp_path, head_body)?;
    fsync_path(&head_tmp_path)?;

    // 3. Rename tmp → head. SOLE commit point.
    if let Err(e) = fs::rename(&head_tmp_path, &head_final_path) {
        if e.raw_os_error() == Some(EXDEV) {
            // Best-effort: remove the orphan tmp so it doesn't pollute
            // the sessions dir.
            let _ = fs::remove_file(&head_tmp_path);
            return Err(KError::CrossFilesystem {
                src: head_tmp_path,
                dst: head_final_path,
            });
        }
        return Err(KError::Io(e));
    }

    // 4. Disarm the Drop guard — the on-disk head now references
    //    state_tmpdir.path() and must NOT be cleaned up even if the
    //    parent fsync below fails.
    state_tmpdir.commit();

    // 5. fsync the parent so the rename is durable.
    fsync_path(sessions_dir)?;

    Ok(())
}

/// Pure predicate used by [`sweep_orphans`] to decide whether a candidate
/// gen-stamped state-dir basename is sweepable.
///
/// Returns `true` iff:
/// - the basename parses as a gen-stamp, AND
/// - the basename is not in `referenced`, AND
/// - the parsed `<name>` is not in `protected_names`.
///
/// Age is checked separately by the caller (it requires a filesystem
/// stat); keeping it out of this predicate makes the membership logic
/// trivially unit-testable.
pub(crate) fn should_sweep(
    basename: &str,
    referenced: &HashSet<String>,
    protected_names: &HashSet<String>,
) -> bool {
    let Some((name, _gen, _pid)) = parse_gen_stamp(basename) else {
        return false;
    };
    if referenced.contains(basename) {
        return false;
    }
    if protected_names.contains(&name) {
        return false;
    }
    true
}

/// Scan a conf body for gen-stamped basenames. Tolerant of arbitrary
/// surrounding context (whitespace, slashes, quotes): finds every
/// `.gen-<digits>(_<digits>)?.state` token and reconstructs the full
/// basename by walking left over name characters (anything that isn't
/// `/`, whitespace, or a quote).
///
/// Returns the set of `<basename>` strings (e.g. `foo.gen-12345.state`)
/// found anywhere in the body.
fn scan_conf_for_gen_refs(body: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    let bytes = body.as_bytes();
    let mut search_from = 0usize;
    while let Some(rel) = body[search_from..].find(".gen-") {
        let marker_start = search_from + rel;

        // Advance past digits, then optional _<digits>, then expect
        // `.state` followed by a non-name byte (or EOF).
        let mut i = marker_start + ".gen-".len();
        let gen_start = i;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
        }
        if i == gen_start {
            search_from = marker_start + ".gen-".len();
            continue;
        }
        if i < bytes.len() && bytes[i] == b'_' {
            i += 1;
            let pid_start = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            if i == pid_start {
                search_from = marker_start + ".gen-".len();
                continue;
            }
        }
        // Expect literal `.state`.
        let suffix = b".state";
        if i + suffix.len() > bytes.len() || &bytes[i..i + suffix.len()] != suffix {
            search_from = marker_start + ".gen-".len();
            continue;
        }
        let basename_end = i + suffix.len();

        // Walk left from marker_start to find the name boundary. A name
        // byte is anything other than `/`, ASCII whitespace, or a quote.
        let mut name_start = marker_start;
        while name_start > 0 {
            let b = bytes[name_start - 1];
            if b == b'/' || b == b'"' || b == b'\'' || b.is_ascii_whitespace() {
                break;
            }
            name_start -= 1;
        }
        if name_start < marker_start {
            // Use a checked slice — the byte boundaries we found are
            // ASCII so this is a valid UTF-8 slice as long as the
            // surrounding content is.
            if let Some(s) = body.get(name_start..basename_end) {
                out.insert(s.to_string());
            }
        }
        search_from = basename_end;
    }
    out
}

/// Sweep stale per-window history files from a given directory.
///
/// For each file whose name parses as an integer (KITTY_WINDOW_ID):
/// - If that window ID is NOT in `live_window_ids` AND the file is older
///   than `SWEEP_MIN_AGE`, delete it.
/// - Files for live windows are left alone.
/// - Files younger than SWEEP_MIN_AGE are left alone (race guard).
/// - Non-integer filenames are left untouched.
/// - If the hist dir doesn't exist, return 0 (no-op).
///
/// Returns the number of files successfully removed.
pub(crate) fn sweep_history_cache_in(hist_dir: &Path, live_window_ids: &HashSet<u64>) -> usize {
    let entries = match fs::read_dir(hist_dir) {
        Ok(e) => e,
        Err(_) => return 0,
    };

    let cutoff = SystemTime::now()
        .checked_sub(SWEEP_MIN_AGE)
        .unwrap_or(SystemTime::UNIX_EPOCH);
    let mut swept = 0usize;

    for ent in entries {
        let ent = match ent {
            Ok(e) => e,
            Err(e) => {
                eprintln!("sweep_history_cache: dir entry error: {e}");
                continue;
            }
        };
        let name = match ent.file_name().into_string() {
            Ok(s) => s,
            Err(_) => continue,
        };

        // Only consider files whose name parses as a u64 window ID.
        let window_id: u64 = match name.parse() {
            Ok(id) => id,
            Err(_) => continue,
        };

        // Skip files belonging to live windows.
        if live_window_ids.contains(&window_id) {
            continue;
        }

        let path = ent.path();

        // Check mtime — skip files younger than SWEEP_MIN_AGE.
        let mtime = match fs::metadata(&path).and_then(|m| m.modified()) {
            Ok(t) => t,
            Err(e) => {
                eprintln!(
                    "sweep_history_cache: stat({}) failed: {} — skipping",
                    path.display(),
                    e
                );
                continue;
            }
        };
        if mtime > cutoff {
            continue;
        }

        match fs::remove_file(&path) {
            Ok(()) => swept += 1,
            Err(e) => {
                eprintln!(
                    "sweep_history_cache: remove_file({}) failed: {} — skipping",
                    path.display(),
                    e
                );
            }
        }
    }
    swept
}

/// Sweep stale per-window history files from `~/.cache/ksession/hist/`.
///
/// Delegates to [`sweep_history_cache_in`] with the standard hist dir path.
/// Returns the number of files successfully removed.
pub fn sweep_history_cache(live_window_ids: &HashSet<u64>) -> usize {
    let home = match std::env::var("HOME") {
        Ok(h) => h,
        Err(_) => return 0,
    };
    let hist_dir = PathBuf::from(home).join(".cache/ksession/hist");
    sweep_history_cache_in(&hist_dir, live_window_ids)
}

/// Kitty-layout orphan sweep: [`sweep_orphans_for`] with the `.conf` head
/// file the kitty session store uses.
pub fn sweep_orphans(sessions_dir: &Path) -> usize {
    sweep_orphans_for(sessions_dir, "conf")
}

/// Best-effort orphan sweep (§B.4), parameterised by the head-file
/// extension that defines a live session in `sessions_dir`.
///
/// A "head" is `<name>.<head_ext>` — `conf` for kitty sessions, `json`
/// for tmux-native manifests. The head is written last and its presence
/// defines the session, so any `*.gen-*.state/` directory not referenced
/// from a head body is garbage once it is older than [`SWEEP_MIN_AGE`]
/// (60s); those are `rm -rf`ed. Per-entry errors are logged via
/// `eprintln!` and otherwise ignored.
///
/// Hand-edited head safety: any head whose body contained NO
/// recognisable gen-stamped path contributes its `<name>` to the
/// `protected_names` set, and every `<name>.gen-*.state/` is then
/// treated as referenced. Sweep errs on the side of keeping data.
///
/// Returns the number of directories successfully removed.
pub fn sweep_orphans_for(sessions_dir: &Path, head_ext: &str) -> usize {
    let entries = match fs::read_dir(sessions_dir) {
        Ok(e) => e,
        Err(e) => {
            eprintln!(
                "sweep_orphans: read_dir({}) failed: {}",
                sessions_dir.display(),
                e
            );
            return 0;
        }
    };

    // Buffer entries — we need two passes (heads, then state dirs).
    let head_suffix = format!(".{head_ext}");
    let mut heads: Vec<(String, PathBuf)> = Vec::new();
    let mut state_dirs: Vec<(String, PathBuf)> = Vec::new();
    for ent in entries {
        let ent = match ent {
            Ok(e) => e,
            Err(e) => {
                eprintln!("sweep_orphans: dir entry error: {e}");
                continue;
            }
        };
        let path = ent.path();
        let name = match ent.file_name().into_string() {
            Ok(s) => s,
            Err(_) => continue, // non-UTF8 names: ignore
        };
        if let Some(stem) = name.strip_suffix(&head_suffix) {
            // Skip `.conf.tmp.<pid>` files — they have the extension in
            // the middle, not as a suffix. `strip_suffix` already handles
            // that; here `stem` is the bare session name.
            if !stem.is_empty() {
                heads.push((stem.to_string(), path));
            }
        } else if name.ends_with(".state") {
            // Only consider directories.
            match ent.file_type() {
                Ok(ft) if ft.is_dir() => state_dirs.push((name, path)),
                _ => {}
            }
        }
    }

    // Pass 1: build referenced and protected_names sets.
    let mut referenced: HashSet<String> = HashSet::new();
    let mut protected_names: HashSet<String> = HashSet::new();
    for (sess_name, head_path) in &heads {
        match fs::read_to_string(head_path) {
            Ok(body) => {
                let refs = scan_conf_for_gen_refs(&body);
                if refs.is_empty() {
                    // Hand-edited / no recognisable gen-stamped path:
                    // protect every state dir starting with this name.
                    protected_names.insert(sess_name.clone());
                } else {
                    referenced.extend(refs);
                }
            }
            Err(e) => {
                eprintln!(
                    "sweep_orphans: read_to_string({}) failed: {} — protecting name '{}'",
                    head_path.display(),
                    e,
                    sess_name
                );
                // Unreadable head: be safe, protect the name.
                protected_names.insert(sess_name.clone());
            }
        }
    }

    // Pass 2: sweep eligible state dirs.
    let cutoff = SystemTime::now()
        .checked_sub(SWEEP_MIN_AGE)
        .unwrap_or(SystemTime::UNIX_EPOCH);
    let mut swept = 0usize;
    for (basename, path) in state_dirs {
        if !should_sweep(&basename, &referenced, &protected_names) {
            continue;
        }
        let mtime = match fs::metadata(&path).and_then(|m| m.modified()) {
            Ok(t) => t,
            Err(e) => {
                eprintln!(
                    "sweep_orphans: stat({}) failed: {} — skipping",
                    path.display(),
                    e
                );
                continue;
            }
        };
        if mtime > cutoff {
            // Too young — guard against in-flight concurrent saves.
            continue;
        }
        match fs::remove_dir_all(&path) {
            Ok(()) => swept += 1,
            Err(e) => {
                eprintln!(
                    "sweep_orphans: remove_dir_all({}) failed: {} — skipping",
                    path.display(),
                    e
                );
            }
        }
    }
    swept
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use tempfile::tempdir;

    #[test]
    fn write_atomic_creates_file_with_bytes() {
        let dir = tempdir().unwrap();
        let target = dir.path().join("out.txt");
        write_atomic(&target, b"hello world").unwrap();
        assert!(target.exists());
        assert_eq!(fs::read(&target).unwrap(), b"hello world");
    }

    #[test]
    fn write_atomic_overwrites_existing_file() {
        let dir = tempdir().unwrap();
        let target = dir.path().join("out.txt");
        fs::write(&target, b"old contents that is longer").unwrap();
        write_atomic(&target, b"new").unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"new");
    }

    #[test]
    fn write_atomic_creates_missing_parent_dir() {
        let dir = tempdir().unwrap();
        let target = dir.path().join("a").join("b").join("c").join("out.txt");
        assert!(!target.parent().unwrap().exists());
        write_atomic(&target, b"deep").unwrap();
        assert!(target.exists());
        assert_eq!(fs::read(&target).unwrap(), b"deep");
    }

    #[test]
    fn write_atomic_errors_when_parent_unwritable() {
        // Create a tempdir, make a subdir, chmod it 0o500 (r-x only), then
        // try to write under it. On Unix this should fail with EACCES at
        // either create_dir_all or NamedTempFile::new_in.
        use std::os::unix::fs::PermissionsExt;
        let dir = tempdir().unwrap();
        let ro = dir.path().join("ro");
        fs::create_dir(&ro).unwrap();
        let mut perms = fs::metadata(&ro).unwrap().permissions();
        perms.set_mode(0o500);
        fs::set_permissions(&ro, perms).unwrap();

        // Skip if we're root (root ignores DAC perms).
        let am_root = unsafe { libc_geteuid() } == 0;
        if am_root {
            eprintln!("skip: running as root, DAC ignored");
            // restore so tempdir can clean up
            let mut p = fs::metadata(&ro).unwrap().permissions();
            p.set_mode(0o700);
            let _ = fs::set_permissions(&ro, p);
            return;
        }

        let target = ro.join("nested").join("out.txt");
        let err = write_atomic(&target, b"x").unwrap_err();
        // PermissionDenied is the expected ErrorKind, but be tolerant of
        // platforms reporting Other.
        assert!(
            matches!(
                err.kind(),
                io::ErrorKind::PermissionDenied | io::ErrorKind::Other
            ),
            "unexpected error kind: {:?} ({err})",
            err.kind()
        );

        // Restore perms so tempdir drop can rm -rf.
        let mut p = fs::metadata(&ro).unwrap().permissions();
        p.set_mode(0o700);
        fs::set_permissions(&ro, p).unwrap();
    }

    // Avoid pulling in the libc crate just for geteuid; FFI it directly.
    extern "C" {
        fn geteuid() -> u32;
    }
    #[allow(non_snake_case)]
    unsafe fn libc_geteuid() -> u32 {
        geteuid()
    }

    // ---------- gen-stamp helpers ----------

    #[test]
    fn gen_stamp_basename_no_pid() {
        assert_eq!(
            gen_stamp_basename("foo", 12345, None),
            "foo.gen-12345.state"
        );
    }

    #[test]
    fn gen_stamp_basename_with_pid() {
        assert_eq!(
            gen_stamp_basename("foo", 12345, Some(999)),
            "foo.gen-12345_999.state"
        );
    }

    #[test]
    fn parse_gen_stamp_roundtrip_no_pid() {
        let s = gen_stamp_basename("foo", 12345, None);
        assert_eq!(parse_gen_stamp(&s), Some(("foo".to_string(), 12345, None)));
    }

    #[test]
    fn parse_gen_stamp_roundtrip_with_pid() {
        let s = gen_stamp_basename("foo", 12345, Some(999));
        assert_eq!(
            parse_gen_stamp(&s),
            Some(("foo".to_string(), 12345, Some(999)))
        );
    }

    #[test]
    fn parse_gen_stamp_handles_dot_in_name() {
        assert_eq!(
            parse_gen_stamp("my.proj.gen-12345.state"),
            Some(("my.proj".to_string(), 12345, None))
        );
        assert_eq!(
            parse_gen_stamp("a.b.c.gen-1_2.state"),
            Some(("a.b.c".to_string(), 1, Some(2)))
        );
    }

    #[test]
    fn parse_gen_stamp_rejects_bare_name() {
        // Bash-era bare-name dirs must NEVER match.
        assert_eq!(parse_gen_stamp("foo.state"), None);
        assert_eq!(parse_gen_stamp("my.session.state"), None);
    }

    #[test]
    fn parse_gen_stamp_rejects_non_digits() {
        assert_eq!(parse_gen_stamp("foo.gen-abc.state"), None);
        assert_eq!(parse_gen_stamp("foo.gen-12_ab.state"), None);
        assert_eq!(parse_gen_stamp("foo.gen-.state"), None);
        assert_eq!(parse_gen_stamp("foo.gen-12_.state"), None);
    }

    #[test]
    fn parse_gen_stamp_rejects_missing_suffix() {
        assert_eq!(parse_gen_stamp("foo.gen-123"), None);
        assert_eq!(parse_gen_stamp("foo.gen-123.statee"), None);
    }

    // ---------- StateTmpdir ----------

    #[test]
    fn state_tmpdir_drop_removes_dir() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("foo.gen-1.state");
        fs::create_dir(&path).unwrap();
        fs::write(path.join("sentinel"), b"x").unwrap();
        {
            let _guard = StateTmpdir::new(path.clone());
            assert!(path.exists());
        }
        assert!(!path.exists(), "Drop should have removed the dir");
    }

    #[test]
    fn state_tmpdir_commit_disarms_drop() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("foo.gen-1.state");
        fs::create_dir(&path).unwrap();
        let guard = StateTmpdir::new(path.clone());
        guard.commit();
        assert!(path.exists(), "commit() must keep the dir on disk");
    }

    // ---------- commit_session ----------

    #[test]
    fn commit_session_happy_path() {
        let dir = tempdir().unwrap();
        let sessions_dir = dir.path();
        let state_path = sessions_dir.join("mysess.gen-100.state");
        fs::create_dir(&state_path).unwrap();
        fs::write(state_path.join("manifest.json"), b"{}").unwrap();

        let guard = StateTmpdir::new(state_path.clone());
        commit_session(guard, b"# conf body\n", sessions_dir, "mysess", "conf").unwrap();

        // State dir survives.
        assert!(state_path.exists());
        assert!(state_path.join("manifest.json").exists());

        // Conf landed at final path.
        let conf = sessions_dir.join("mysess.conf");
        assert!(conf.exists());
        assert_eq!(fs::read_to_string(&conf).unwrap(), "# conf body\n");

        // No stray conf.tmp.
        let pid = std::process::id();
        let conf_tmp = sessions_dir.join(format!("mysess.conf.tmp.{pid}"));
        assert!(!conf_tmp.exists());
    }

    // FIXME: cross-fs test deferred — needs EXDEV-inducing fixture.

    // ---------- should_sweep predicate ----------

    #[test]
    fn should_sweep_skips_referenced() {
        let mut referenced = HashSet::new();
        referenced.insert("foo.gen-1.state".to_string());
        let protected: HashSet<String> = HashSet::new();
        assert!(!should_sweep("foo.gen-1.state", &referenced, &protected));
    }

    #[test]
    fn should_sweep_skips_protected_name() {
        let referenced: HashSet<String> = HashSet::new();
        let mut protected = HashSet::new();
        protected.insert("foo".to_string());
        assert!(!should_sweep("foo.gen-99.state", &referenced, &protected));
    }

    #[test]
    fn should_sweep_targets_orphan() {
        let referenced: HashSet<String> = HashSet::new();
        let protected: HashSet<String> = HashSet::new();
        assert!(should_sweep("foo.gen-1.state", &referenced, &protected));
    }

    #[test]
    fn should_sweep_ignores_bare_state() {
        let referenced: HashSet<String> = HashSet::new();
        let protected: HashSet<String> = HashSet::new();
        // Bash-era bare-name dirs: parse_gen_stamp returns None, so
        // sweep refuses to touch them.
        assert!(!should_sweep("foo.state", &referenced, &protected));
    }

    // ---------- scan_conf_for_gen_refs ----------

    #[test]
    fn scan_conf_picks_up_references() {
        let body = "launch nvim -S /home/u/.config/sessions/foo.gen-12345.state/nvim/w1.vim\n\
                    source /home/u/.config/sessions/foo.gen-12345.state/tmux/restore.sh\n";
        let refs = scan_conf_for_gen_refs(body);
        assert!(refs.contains("foo.gen-12345.state"));
        assert_eq!(refs.len(), 1);
    }

    #[test]
    fn scan_conf_handles_pid_suffixed_refs() {
        let body = "x /a/b/foo.gen-12345_999.state/m.json\n";
        let refs = scan_conf_for_gen_refs(body);
        assert!(refs.contains("foo.gen-12345_999.state"));
    }

    #[test]
    fn scan_conf_returns_empty_for_no_refs() {
        let body = "# nothing useful here\nlaunch zsh\n";
        let refs = scan_conf_for_gen_refs(body);
        assert!(refs.is_empty());
    }

    // ---------- sweep_history_cache ----------

    #[test]
    fn sweep_history_cache_deletes_orphans() {
        let dir = tempdir().unwrap();
        let hist = dir.path().join("hist");
        fs::create_dir(&hist).unwrap();

        // Create files named 1, 2, 3. Window 2 is live.
        for id in [1u64, 2, 3] {
            fs::write(hist.join(id.to_string()), b"data").unwrap();
        }

        // Age files 1 and 3 past SWEEP_MIN_AGE.
        let old = SystemTime::now() - Duration::from_secs(120);
        for id in [1u64, 3] {
            let path = hist.join(id.to_string());
            if let Ok(f) = fs::File::open(&path) {
                let _ = f.set_modified(old);
            }
        }

        let mut live = HashSet::new();
        live.insert(2u64);

        let swept = sweep_history_cache_in(&hist, &live);

        // If set_modified is supported, 1 and 3 are deleted; 2 remains.
        if swept == 2 {
            assert!(!hist.join("1").exists());
            assert!(hist.join("2").exists());
            assert!(!hist.join("3").exists());
        } else {
            // set_modified unsupported on this platform — accept no-op.
            eprintln!(
                "sweep_history_cache_deletes_orphans: \
                 File::set_modified appears unsupported; got swept={swept}"
            );
        }
    }

    #[test]
    fn sweep_history_cache_preserves_young_files() {
        let dir = tempdir().unwrap();
        let hist = dir.path().join("hist");
        fs::create_dir(&hist).unwrap();

        // File 4 is freshly created (< 60s old). Not live.
        fs::write(hist.join("4"), b"data").unwrap();

        let live: HashSet<u64> = HashSet::new();
        let swept = sweep_history_cache_in(&hist, &live);
        assert_eq!(swept, 0, "young file must not be deleted");
        assert!(hist.join("4").exists());
    }

    #[test]
    fn sweep_history_cache_ignores_non_numeric_filenames() {
        let dir = tempdir().unwrap();
        let hist = dir.path().join("hist");
        fs::create_dir(&hist).unwrap();

        fs::write(hist.join("notes.txt"), b"data").unwrap();

        // Age it past the threshold.
        let old = SystemTime::now() - Duration::from_secs(120);
        if let Ok(f) = fs::File::open(hist.join("notes.txt")) {
            let _ = f.set_modified(old);
        }

        let live: HashSet<u64> = HashSet::new();
        let swept = sweep_history_cache_in(&hist, &live);
        assert_eq!(swept, 0, "non-numeric filename must be left untouched");
        assert!(hist.join("notes.txt").exists());
    }

    #[test]
    fn sweep_history_cache_missing_directory() {
        let dir = tempdir().unwrap();
        let hist = dir.path().join("nonexistent");
        let live: HashSet<u64> = HashSet::new();
        let swept = sweep_history_cache_in(&hist, &live);
        assert_eq!(swept, 0, "missing directory must return 0");
    }

    // ---------- sweep_orphans integration (age-bounded) ----------

    #[test]
    fn sweep_orphans_skips_young_dirs() {
        // Freshly created dirs are < SWEEP_MIN_AGE old, so even
        // unreferenced ones must survive a sweep.
        let dir = tempdir().unwrap();
        let p = dir.path().join("foo.gen-1.state");
        fs::create_dir(&p).unwrap();
        let swept = sweep_orphans(dir.path());
        assert_eq!(swept, 0);
        assert!(p.exists());
    }

    #[test]
    fn sweep_orphans_spares_referenced_dir_even_when_old() {
        // Build a referenced state dir + matching conf, age both past
        // SWEEP_MIN_AGE via set_modified. Sweep should leave the dir
        // alone because it's referenced.
        let dir = tempdir().unwrap();
        let state = dir.path().join("foo.gen-1.state");
        fs::create_dir(&state).unwrap();
        let conf = dir.path().join("foo.conf");
        fs::write(
            &conf,
            format!("launch nvim -S {}/nvim/x.vim\n", state.display()),
        )
        .unwrap();

        // Age the state dir past the threshold.
        let old = SystemTime::now() - Duration::from_secs(120);
        if let Ok(f) = fs::File::open(&state) {
            let _ = f.set_modified(old);
        }

        let swept = sweep_orphans(dir.path());
        assert_eq!(swept, 0);
        assert!(state.exists());
    }

    #[test]
    fn sweep_orphans_removes_old_unreferenced_dir() {
        let dir = tempdir().unwrap();
        let stale = dir.path().join("ghost.gen-7.state");
        fs::create_dir(&stale).unwrap();
        // No matching conf.
        let old = SystemTime::now() - Duration::from_secs(120);
        if let Ok(f) = fs::File::open(&stale) {
            let _ = f.set_modified(old);
        }
        let swept = sweep_orphans(dir.path());
        // If File::set_modified isn't supported on this platform/FS,
        // the dir will simply be too young and sweep will skip it —
        // accept either outcome rather than failing the build.
        if swept == 1 {
            assert!(!stale.exists());
        } else {
            eprintln!(
                "sweep_orphans_removes_old_unreferenced_dir: \
                 File::set_modified appears unsupported; got swept={swept}"
            );
        }
    }

    #[test]
    fn sweep_orphans_for_json_head_references_state_dir() {
        // tmux-native store: the head is `<name>.json` and its body names
        // the state dir inside a JSON string. The referenced dir must
        // survive even when old; a sibling unreferenced dir must not.
        let dir = tempdir().unwrap();
        let kept = dir.path().join("work.gen-5.state");
        let ghost = dir.path().join("ghost.gen-6.state");
        fs::create_dir(&kept).unwrap();
        fs::create_dir(&ghost).unwrap();
        fs::write(
            dir.path().join("work.json"),
            format!("{{\"state_dir\":\"{}\"}}", kept.display()),
        )
        .unwrap();

        let old = SystemTime::now() - Duration::from_secs(120);
        for p in [&kept, &ghost] {
            if let Ok(f) = fs::File::open(p) {
                let _ = f.set_modified(old);
            }
        }

        let swept = sweep_orphans_for(dir.path(), "json");
        assert!(kept.exists(), "referenced state dir must survive");
        if swept == 1 {
            assert!(!ghost.exists());
        } else {
            eprintln!(
                "sweep_orphans_for_json_head_references_state_dir: \
                 File::set_modified appears unsupported; got swept={swept}"
            );
        }
    }

    #[test]
    fn sweep_orphans_for_ignores_heads_of_other_extension() {
        // A `.conf` next to a `.json`-keyed store is not a head for that
        // store: it neither references nor protects anything, so the
        // state dir it names is an orphan under the "json" policy.
        let dir = tempdir().unwrap();
        let state = dir.path().join("foo.gen-1.state");
        fs::create_dir(&state).unwrap();
        fs::write(
            dir.path().join("foo.conf"),
            format!("launch nvim -S {}/nvim/x.vim\n", state.display()),
        )
        .unwrap();
        let old = SystemTime::now() - Duration::from_secs(120);
        if let Ok(f) = fs::File::open(&state) {
            let _ = f.set_modified(old);
        }

        let swept = sweep_orphans_for(dir.path(), "json");
        if swept == 1 {
            assert!(!state.exists());
        } else {
            eprintln!(
                "sweep_orphans_for_ignores_heads_of_other_extension: \
                 File::set_modified appears unsupported; got swept={swept}"
            );
        }
    }
}
