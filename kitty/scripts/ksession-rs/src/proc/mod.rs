//! Best-effort `/proc` introspection helpers.
//!
//! Every function takes a `root: &Path` so tests can stub the filesystem with
//! `tempfile::tempdir()`. In production, callers pass `Path::new("/proc")`.
//! All helpers are silent on failure: missing files, unreadable files, parse
//! errors, etc. yield `None` (or the empty/identity case for the collection
//! variants). They never panic and never propagate errors.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

fn pid_dir(root: &Path, pid: u32) -> PathBuf {
    root.join(pid.to_string())
}

/// Basename of the executable behind `/proc/PID/exe`.
///
/// Reads the symlink (no canonicalisation — the target may not exist on disk,
/// as is the case in fixture filesystems) and returns its final path
/// component. A kernel-appended ` (deleted)` suffix is preserved verbatim;
/// downstream callers compare on the raw string.
pub fn exe_base(root: &Path, pid: u32) -> Option<String> {
    let link = pid_dir(root, pid).join("exe");
    let target = fs::read_link(&link).ok()?;
    let name = target.file_name()?;
    Some(name.to_string_lossy().into_owned())
}

/// Full target of the `/proc/PID/exe` symlink, if readable and the target
/// still exists on disk (a ` (deleted)` suffix — binary replaced while
/// running — yields `None`; restoring from a vanished path can't succeed).
pub fn exe_path(root: &Path, pid: u32) -> Option<PathBuf> {
    let target = fs::read_link(pid_dir(root, pid).join("exe")).ok()?;
    if target.is_file() {
        Some(target)
    } else {
        None
    }
}

/// Argv from `/proc/PID/cmdline`, split on NUL.
///
/// Returns `Some(vec![])` for kernel threads (empty cmdline file) and `None`
/// if the file can't be read. ALL trailing empty elements are dropped, not
/// just the single NUL terminator: programs that rewrite their argv region
/// for the process title (setproctitle pattern — `pi`, `omp`, `claude`, …)
/// leave a run of trailing NULs which would otherwise yield thousands of
/// empty-string args (a real saved manifest captured `pi` with a
/// 3545-element argv). Internal empty elements (between non-empty ones) are
/// preserved.
pub fn cmdline(root: &Path, pid: u32) -> Option<Vec<String>> {
    let path = pid_dir(root, pid).join("cmdline");
    let bytes = fs::read(&path).ok()?;
    if bytes.is_empty() {
        return Some(Vec::new());
    }
    let text = String::from_utf8_lossy(&bytes);
    let mut parts: Vec<String> = text.split('\0').map(|s| s.to_string()).collect();
    // Strip every trailing empty element: the NUL terminator plus any
    // setproctitle padding. Internal empties are preserved.
    while matches!(parts.last(), Some(s) if s.is_empty()) {
        parts.pop();
    }
    Some(parts)
}

/// Full environment map from `/proc/PID/environ`.
///
/// Splits on NUL bytes, then on the FIRST `=` per entry (values may contain
/// `=`). Malformed entries (no `=`) and empty entries (NUL-NUL runs) are
/// dropped silently. Returns `None` if the environ file can't be read.
///
/// Duplicate keys: last-write-wins (not expected in real /proc data).
pub fn parse_environ(root: &Path, pid: u32) -> Option<HashMap<String, String>> {
    let path = pid_dir(root, pid).join("environ");
    let bytes = fs::read(&path).ok()?;
    let mut map = HashMap::new();
    for entry in bytes.split(|&b| b == 0) {
        if entry.is_empty() {
            continue;
        }
        let text = String::from_utf8_lossy(entry);
        if let Some(eq) = text.find('=') {
            // drop leading-'=' entries: empty key is invalid environ data
            if eq == 0 {
                continue;
            }
            let (k, v) = text.split_at(eq);
            map.insert(k.to_string(), v[1..].to_string());
        }
        // No '=' byte → malformed, drop silently.
    }
    Some(map)
}

/// Value of `key` in `/proc/PID/environ`.
///
/// Returns `Some(String::new())` for an explicitly empty value (`KEY=\0`) and
/// `None` if the key is absent or the environ file can't be read. An empty
/// `key` always returns `None` (no valid environ entry has an empty key).
pub fn env_var(root: &Path, pid: u32, key: &str) -> Option<String> {
    parse_environ(root, pid)?.get(key).cloned()
}

/// All descendant PIDs of `pid` (including `pid` itself).
///
/// Iterative DFS via `/proc/PID/task/<TID>/children`. ROOT PID IS INCLUDED in
/// the output. Order matches the Bash reference (sorted-glob task iteration,
/// pre-order with deepest-rightmost-first via stack LIFO).
///
/// Cycles in /proc are not expected but a visited-set prevents infinite loops
/// on pathological fixtures. Differs from Bash reference: duplicates are
/// removed. Real /proc never produces duplicate PIDs across task children,
/// and downstream callers (socket_for_pid first-match) don't care about
/// duplicates.
// Safe for all current callers (first-match or set-membership semantics) — see ksession.sh:117,128,541.
pub fn descendants(root: &Path, pid: u32) -> Vec<u32> {
    let mut stack: Vec<u32> = vec![pid];
    let mut out: Vec<u32> = Vec::new();
    let mut seen: HashSet<u32> = HashSet::new();
    while let Some(p) = stack.pop() {
        if !seen.insert(p) {
            continue;
        }
        out.push(p);
        let task_dir = pid_dir(root, p).join("task");
        let Ok(entries) = fs::read_dir(&task_dir) else {
            continue;
        };
        // Sort task entries by filename to match Bash's sorted glob.
        let mut task_entries: Vec<_> = entries.flatten().collect();
        task_entries.sort_by_key(|e| e.file_name());
        for entry in task_entries {
            let children_path = entry.path().join("children");
            let Ok(text) = fs::read_to_string(&children_path) else {
                continue;
            };
            // Push children in read order; LIFO pop means the last child is
            // visited next (matches Bash's stack-push semantics).
            for tok in text.split_ascii_whitespace() {
                if let Ok(child) = tok.parse::<u32>() {
                    stack.push(child);
                }
            }
        }
    }
    out
}

/// Numeric `pos:` field from `/proc/PID/fdinfo/FD`.
pub fn fdinfo_pos(root: &Path, pid: u32, fd: u32) -> Option<u64> {
    let path = pid_dir(root, pid).join("fdinfo").join(fd.to_string());
    let text = fs::read_to_string(&path).ok()?;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("pos:") {
            let value = rest.split_ascii_whitespace().next()?;
            return value.parse::<u64>().ok();
        }
    }
    None
}

/// Sorted list of open fd numbers from `/proc/PID/fd/`.
///
/// Non-numeric entries are skipped. Returns an empty vec if the fd dir is
/// unreadable.
pub fn list_fds(root: &Path, pid: u32) -> Vec<u32> {
    let fd_dir = pid_dir(root, pid).join("fd");
    let Ok(entries) = fs::read_dir(&fd_dir) else {
        return Vec::new();
    };
    let mut fds: Vec<u32> = entries
        .flatten()
        .filter_map(|e| e.file_name().to_string_lossy().parse::<u32>().ok())
        .collect();
    fds.sort_unstable();
    fds
}

/// Symlink target of `/proc/PID/fd/FD`.
///
/// No canonicalisation — the kernel exposes the absolute target directly and
/// any ` (deleted)` suffix must be preserved.
pub fn fd_target(root: &Path, pid: u32, fd: u32) -> Option<PathBuf> {
    let path = pid_dir(root, pid).join("fd").join(fd.to_string());
    fs::read_link(&path).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::Path;
    use tempfile::tempdir;

    fn write(path: &Path, bytes: &[u8]) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, bytes).unwrap();
    }

    // ---------- exe_base ----------

    #[test]
    fn exe_base_resolves_symlink_basename() {
        let tmp = tempdir().unwrap();
        let pid_dir = tmp.path().join("42");
        fs::create_dir_all(&pid_dir).unwrap();
        symlink("/usr/bin/fake_bash", pid_dir.join("exe")).unwrap();
        assert_eq!(exe_base(tmp.path(), 42), Some("fake_bash".to_string()));
    }

    #[test]
    fn exe_base_handles_versioned_target() {
        let tmp = tempdir().unwrap();
        let pid_dir = tmp.path().join("7");
        fs::create_dir_all(&pid_dir).unwrap();
        symlink("/path/to/python3.11", pid_dir.join("exe")).unwrap();
        assert_eq!(exe_base(tmp.path(), 7), Some("python3.11".to_string()));
    }

    #[test]
    fn exe_base_missing_pid_returns_none() {
        let tmp = tempdir().unwrap();
        assert_eq!(exe_base(tmp.path(), 999), None);
    }

    #[test]
    fn exe_base_relative_target_still_yields_basename() {
        let tmp = tempdir().unwrap();
        let pid_dir = tmp.path().join("8");
        fs::create_dir_all(&pid_dir).unwrap();
        symlink("relative-binary", pid_dir.join("exe")).unwrap();
        assert_eq!(exe_base(tmp.path(), 8), Some("relative-binary".to_string()));
    }

    #[test]
    fn exe_base_strips_no_deleted_suffix() {
        // Kernel appends " (deleted)" when the executable has been unlinked.
        // Both the Bash reference and our impl preserve it; downstream code
        // does string contains/equals on the result.
        let tmp = tempdir().unwrap();
        let pid_dir = tmp.path().join("11");
        fs::create_dir_all(&pid_dir).unwrap();
        symlink("/usr/bin/bash (deleted)", pid_dir.join("exe")).unwrap();
        assert_eq!(exe_base(tmp.path(), 11), Some("bash (deleted)".to_string()));
    }

    // ---------- cmdline ----------

    #[test]
    fn cmdline_basic_args() {
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("42/cmdline"), b"bash\0-l\0");
        assert_eq!(
            cmdline(tmp.path(), 42),
            Some(vec!["bash".to_string(), "-l".to_string()])
        );
    }

    #[test]
    fn cmdline_no_trailing_nul_still_parses() {
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("42/cmdline"), b"bash\0-l");
        assert_eq!(
            cmdline(tmp.path(), 42),
            Some(vec!["bash".to_string(), "-l".to_string()])
        );
    }

    #[test]
    fn cmdline_argv_with_spaces() {
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("9/cmdline"), b"vi\0my file\0");
        assert_eq!(
            cmdline(tmp.path(), 9),
            Some(vec!["vi".to_string(), "my file".to_string()])
        );
    }

    #[test]
    fn cmdline_empty_for_kernel_thread() {
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("2/cmdline"), b"");
        assert_eq!(cmdline(tmp.path(), 2), Some(vec![]));
    }

    #[test]
    fn cmdline_missing_pid_returns_none() {
        let tmp = tempdir().unwrap();
        assert_eq!(cmdline(tmp.path(), 12345), None);
    }

    #[test]
    fn cmdline_only_nuls() {
        // A file of pure NULs has no real argv elements at all — every
        // element is a trailing empty, so they are all stripped. Callers
        // treat the empty vec like an unreadable cmdline (degrade path).
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("13/cmdline"), b"\0\0\0");
        assert_eq!(cmdline(tmp.path(), 13), Some(vec![]));
    }

    #[test]
    fn cmdline_strips_all_trailing_nuls() {
        // setproctitle pattern (pi/omp/claude): the program rewrites its
        // argv region for the process title, leaving many trailing NULs.
        // All trailing empties must be stripped, not just the terminator —
        // a real saved manifest captured `pi` with 3544 empty-string args.
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("14/cmdline"), b"pi\0\0\0\0\0\0");
        assert_eq!(cmdline(tmp.path(), 14), Some(vec!["pi".to_string()]));
    }

    #[test]
    fn cmdline_preserves_internal_empty_args() {
        // An empty argv element BETWEEN non-empty ones is a real (if odd)
        // argument and must survive; only the trailing run is stripped.
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("15/cmdline"), b"a\0\0b\0");
        assert_eq!(
            cmdline(tmp.path(), 15),
            Some(vec!["a".to_string(), "".to_string(), "b".to_string()])
        );
    }

    #[test]
    fn cmdline_setproctitle_large_padding() {
        // Scaled-up setproctitle fixture: one real element plus thousands
        // of NULs (the shape of the real `pi` capture bug).
        let tmp = tempdir().unwrap();
        let mut bytes = b"pi".to_vec();
        bytes.extend(std::iter::repeat(0u8).take(3544));
        write(&tmp.path().join("16/cmdline"), &bytes);
        assert_eq!(cmdline(tmp.path(), 16), Some(vec!["pi".to_string()]));
    }

    // ---------- env_var ----------

    #[test]
    fn env_var_finds_values() {
        let tmp = tempdir().unwrap();
        write(
            &tmp.path().join("42/environ"),
            b"PATH=/usr/bin\0HOME=/h\0EMPTY=\0KEY=value\0",
        );
        let p = tmp.path();
        assert_eq!(env_var(p, 42, "PATH"), Some("/usr/bin".to_string()));
        assert_eq!(env_var(p, 42, "HOME"), Some("/h".to_string()));
        assert_eq!(env_var(p, 42, "EMPTY"), Some(String::new()));
        assert_eq!(env_var(p, 42, "KEY"), Some("value".to_string()));
    }

    #[test]
    fn env_var_missing_key_returns_none() {
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("42/environ"), b"PATH=/usr/bin\0");
        assert_eq!(env_var(tmp.path(), 42, "MISSING"), None);
    }

    #[test]
    fn env_var_missing_pid_returns_none() {
        let tmp = tempdir().unwrap();
        assert_eq!(env_var(tmp.path(), 99, "PATH"), None);
    }

    #[test]
    fn env_var_value_containing_equals() {
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("42/environ"), b"FOO=a=b\0");
        assert_eq!(env_var(tmp.path(), 42, "FOO"), Some("a=b".to_string()));
    }

    #[test]
    fn env_var_does_not_match_prefix() {
        // "PATH_EXTRA" must not be returned when searching for "PATH".
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("42/environ"), b"PATH_EXTRA=zzz\0");
        assert_eq!(env_var(tmp.path(), 42, "PATH"), None);
    }

    #[test]
    fn env_var_empty_key_returns_none() {
        // Pins the post-refactor behavior: an empty key looks up "" in the
        // map, which is never a valid environ key in real /proc data, so we
        // return None cleanly. The fixture includes a leading-'=' entry
        // ("=orphan") to actually exercise the guard in parse_environ — if
        // that guard regressed, the map would contain a "" key and this
        // assert would fail. Also locks the distinction between a leading
        // '=' (entry dropped) and a '==' later in the entry ("WEIRD==value",
        // kept with value "=value" since split is on the first '=' only).
        let tmp = tempdir().unwrap();
        write(
            &tmp.path().join("42/environ"),
            b"=orphan\0KEY=v\0WEIRD==value\0",
        );
        assert_eq!(env_var(tmp.path(), 42, ""), None);
        assert_eq!(env_var(tmp.path(), 42, "KEY"), Some("v".to_string()));
        assert_eq!(env_var(tmp.path(), 42, "WEIRD"), Some("=value".to_string()));
    }

    #[test]
    fn env_var_skips_malformed_entries() {
        // Entry without an '=' is dropped silently; subsequent valid entries
        // still parse.
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("42/environ"), b"NOEQUALS\0KEY=v\0");
        assert_eq!(env_var(tmp.path(), 42, "KEY"), Some("v".to_string()));
        assert_eq!(env_var(tmp.path(), 42, "NOEQUALS"), None);
    }

    // ---------- parse_environ ----------

    #[test]
    fn parse_environ_returns_full_map() {
        let tmp = tempdir().unwrap();
        write(
            &tmp.path().join("42/environ"),
            b"PATH=/usr/bin\0HOME=/h\0EMPTY=\0KEY=a=b\0",
        );
        let map = parse_environ(tmp.path(), 42).expect("environ readable");
        assert_eq!(map.get("PATH").map(String::as_str), Some("/usr/bin"));
        assert_eq!(map.get("HOME").map(String::as_str), Some("/h"));
        assert_eq!(map.get("EMPTY").map(String::as_str), Some(""));
        assert_eq!(map.get("KEY").map(String::as_str), Some("a=b"));
        assert_eq!(map.len(), 4);
    }

    #[test]
    fn parse_environ_drops_leading_equals_entries() {
        // Locks the parse_environ contract directly: a leading-'=' entry
        // ("=orphan") is dropped (no "" key in the map), while a "==" later
        // in the entry ("WEIRD==value") is preserved with the second '=' in
        // the value (first-'='-split semantics).
        let tmp = tempdir().unwrap();
        write(
            &tmp.path().join("42/environ"),
            b"=orphan\0KEY=v\0WEIRD==value\0",
        );
        let map = parse_environ(tmp.path(), 42).expect("environ readable");
        assert_eq!(map.get("KEY").map(String::as_str), Some("v"));
        assert_eq!(map.get("WEIRD").map(String::as_str), Some("=value"));
        assert!(!map.contains_key(""));
        assert_eq!(map.len(), 2);
    }

    #[test]
    fn parse_environ_missing_pid_returns_none() {
        let tmp = tempdir().unwrap();
        assert!(parse_environ(tmp.path(), 99).is_none());
    }

    // ---------- descendants ----------

    fn write_children(root: &Path, pid: u32, tid: u32, body: &str) {
        let p = root
            .join(pid.to_string())
            .join("task")
            .join(tid.to_string());
        fs::create_dir_all(&p).unwrap();
        fs::write(p.join("children"), body).unwrap();
    }

    #[test]
    fn descendants_tree() {
        let tmp = tempdir().unwrap();
        write_children(tmp.path(), 1, 1, "2 3\n");
        write_children(tmp.path(), 2, 2, "4\n");
        write_children(tmp.path(), 3, 3, "");
        write_children(tmp.path(), 4, 4, "");
        let mut got = descendants(tmp.path(), 1);
        got.sort();
        assert_eq!(got, vec![1, 2, 3, 4]);
    }

    #[test]
    fn descendants_no_children() {
        let tmp = tempdir().unwrap();
        write_children(tmp.path(), 10, 10, "");
        assert_eq!(descendants(tmp.path(), 10), vec![10]);
    }

    #[test]
    fn descendants_missing_root_still_includes_self() {
        // Bash semantics: the root pid is pushed onto the stack and emitted
        // unconditionally — even when its task dir doesn't exist.
        let tmp = tempdir().unwrap();
        assert_eq!(descendants(tmp.path(), 777), vec![777]);
    }

    #[test]
    fn descendants_multi_tid() {
        // A process with two threads, each owning its own children file.
        let tmp = tempdir().unwrap();
        write_children(tmp.path(), 5, 5, "6\n");
        write_children(tmp.path(), 5, 7, "8\n");
        write_children(tmp.path(), 6, 6, "");
        write_children(tmp.path(), 8, 8, "");
        let mut got = descendants(tmp.path(), 5);
        got.sort();
        assert_eq!(got, vec![5, 6, 8]);
    }

    #[test]
    fn descendants_cycle_does_not_hang() {
        // pid 1 lists 2 as a child; pid 2 lists 1 as a child. Visited-set
        // breaks the cycle so each pid appears exactly once.
        let tmp = tempdir().unwrap();
        write_children(tmp.path(), 1, 1, "2");
        write_children(tmp.path(), 2, 2, "1");
        let mut got = descendants(tmp.path(), 1);
        got.sort();
        assert_eq!(got, vec![1, 2]);
    }

    #[test]
    fn descendants_skips_non_numeric_tokens() {
        // Garbage tokens in the children file are silently dropped.
        let tmp = tempdir().unwrap();
        write_children(tmp.path(), 1, 1, "abc 12 xyz");
        write_children(tmp.path(), 12, 12, "");
        let mut got = descendants(tmp.path(), 1);
        got.sort();
        assert_eq!(got, vec![1, 12]);
    }

    #[test]
    fn descendants_ordering_matches_bash() {
        // Locks the exact pre-order produced by the Bash reference:
        //   1's children: "2 3"   2's children: "4 5"   3's children: "6"
        // With sorted task iteration + LIFO stack (push-in-order, pop-from-end),
        // the visit order is: 1, 3, 6, 2, 5, 4.
        let tmp = tempdir().unwrap();
        write_children(tmp.path(), 1, 1, "2 3");
        write_children(tmp.path(), 2, 2, "4 5");
        write_children(tmp.path(), 3, 3, "6");
        write_children(tmp.path(), 4, 4, "");
        write_children(tmp.path(), 5, 5, "");
        write_children(tmp.path(), 6, 6, "");
        assert_eq!(descendants(tmp.path(), 1), vec![1, 3, 6, 2, 5, 4]);
    }

    // ---------- fdinfo_pos ----------

    #[test]
    fn fdinfo_pos_reads_value() {
        let tmp = tempdir().unwrap();
        write(
            &tmp.path().join("42/fdinfo/3"),
            b"pos:\t9876\nflags:\t02000000\nmnt_id:\t28\n",
        );
        assert_eq!(fdinfo_pos(tmp.path(), 42, 3), Some(9876));
    }

    #[test]
    fn fdinfo_pos_missing_file() {
        let tmp = tempdir().unwrap();
        assert_eq!(fdinfo_pos(tmp.path(), 42, 3), None);
    }

    #[test]
    fn fdinfo_pos_no_pos_line() {
        let tmp = tempdir().unwrap();
        write(
            &tmp.path().join("42/fdinfo/3"),
            b"flags:\t02000000\nmnt_id:\t28\n",
        );
        assert_eq!(fdinfo_pos(tmp.path(), 42, 3), None);
    }

    #[test]
    fn fdinfo_pos_non_numeric_value() {
        let tmp = tempdir().unwrap();
        write(&tmp.path().join("42/fdinfo/3"), b"pos:\tnope\n");
        assert_eq!(fdinfo_pos(tmp.path(), 42, 3), None);
    }

    #[test]
    fn fdinfo_pos_distractor_prefix() {
        // Guards against a regression where `strip_prefix("pos:")` becomes
        // `starts_with("pos")` — "pos_other:" must NOT match.
        let tmp = tempdir().unwrap();
        write(
            &tmp.path().join("42/fdinfo/3"),
            b"pos_other:\t5\npos:\t1234\n",
        );
        assert_eq!(fdinfo_pos(tmp.path(), 42, 3), Some(1234));
    }

    // ---------- list_fds ----------

    #[test]
    fn list_fds_returns_sorted() {
        let tmp = tempdir().unwrap();
        let fd_dir = tmp.path().join("42/fd");
        fs::create_dir_all(&fd_dir).unwrap();
        for n in [1u32, 2, 17, 3] {
            symlink("/dev/null", fd_dir.join(n.to_string())).unwrap();
        }
        assert_eq!(list_fds(tmp.path(), 42), vec![1, 2, 3, 17]);
    }

    #[test]
    fn list_fds_missing_pid_returns_empty() {
        let tmp = tempdir().unwrap();
        assert_eq!(list_fds(tmp.path(), 99), Vec::<u32>::new());
    }

    // ---------- fd_target ----------

    #[test]
    fn fd_target_reads_symlink() {
        let tmp = tempdir().unwrap();
        let fd_dir = tmp.path().join("42/fd");
        fs::create_dir_all(&fd_dir).unwrap();
        symlink("/tmp/some/file", fd_dir.join("3")).unwrap();
        assert_eq!(
            fd_target(tmp.path(), 42, 3),
            Some(PathBuf::from("/tmp/some/file"))
        );
    }

    #[test]
    fn fd_target_missing_fd_returns_none() {
        let tmp = tempdir().unwrap();
        assert_eq!(fd_target(tmp.path(), 42, 3), None);
    }
}
