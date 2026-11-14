//! 4-tier nvim socket discovery, mirroring `nvim_socket_for_pid`
//! (`ksession.sh:100-136`).
//!
//! Tiers in priority order — first hit wins, no fallthrough on a successful
//! match:
//!
//! 1. `NVIM_LISTEN_ADDRESS` in `/proc/<pid>/environ` (covers users who run
//!    `NVIM_LISTEN_ADDRESS=/tmp/foo nvim`).
//! 2. `${rt}/nvim.<pid>.0` and `${rt}/nvim.<pid>.*` (modern default).
//! 3. `${rt}/nvim.${USER}/*/nvim.<pid>.*` (legacy directory layout, kept for
//!    users on older nvim builds).
//! 4. Last resort: scan every `nvim.*.0` socket in `${rt}` and accept one
//!    whose pid is in `tree` (covers kitty's foreground_processes under-
//!    reporting when nvim has spawned LSP/term children).
//!
//! All filesystem failures are silent (`None`). Per Plan §5.3 the caller
//! degrades to bare `nvim` on `None`.

use std::fs;
use std::path::{Path, PathBuf};

use crate::proc;

/// Locate an nvim Unix socket for `pid`. `rt` is typically `$XDG_RUNTIME_DIR`;
/// `proc_root` is `/proc` in production (parameterised for fixture tests);
/// `tree` is the descendant pid list used by tier 4.
///
/// Returns `None` if none of the four tiers turn up a socket file. Callers
/// fold `None` into "bare `nvim` launch" — see `adapter/nvim.rs` and Plan
/// §5.3 "Error degradation".
#[must_use]
pub fn socket_for_pid(
    rt: &Path,
    proc_root: &Path,
    pid: u32,
    user: Option<&str>,
    tree: &[u32],
) -> Option<PathBuf> {
    // Tier 1: explicit env address.
    if let Some(s) = proc::env_var(proc_root, pid, "NVIM_LISTEN_ADDRESS") {
        if !s.is_empty() {
            let p = PathBuf::from(&s);
            if is_socket(&p) {
                return Some(p);
            }
        }
    }

    // Tier 2: ${rt}/nvim.<pid>.0 then ${rt}/nvim.<pid>.*
    let direct_zero = rt.join(format!("nvim.{pid}.0"));
    if is_socket(&direct_zero) {
        return Some(direct_zero);
    }
    let pid_prefix = format!("nvim.{pid}.");
    if let Ok(entries) = fs::read_dir(rt) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name_str) = name.to_str() else {
                continue;
            };
            if name_str.starts_with(&pid_prefix) {
                let path = entry.path();
                if is_socket(&path) {
                    return Some(path);
                }
            }
        }
    }

    // Tier 3: ${rt}/nvim.<user>/*/nvim.<pid>.*
    if let Some(u) = user {
        let user_root = rt.join(format!("nvim.{u}"));
        if let Ok(subs) = fs::read_dir(&user_root) {
            for sub in subs.flatten() {
                let sub_path = sub.path();
                let Ok(inner) = fs::read_dir(&sub_path) else {
                    continue;
                };
                for entry in inner.flatten() {
                    let name = entry.file_name();
                    let Some(name_str) = name.to_str() else {
                        continue;
                    };
                    if name_str.starts_with(&pid_prefix) {
                        let path = entry.path();
                        if is_socket(&path) {
                            return Some(path);
                        }
                    }
                }
            }
        }
    }

    // Tier 4: scan nvim.*.0 in ${rt} and (if user is set) ${rt}/nvim.<u>/*/,
    // accept the first whose embedded pid is a member of `tree`. The bash
    // reference globs both directories in one loop (ksession.sh:129); we
    // walk them sequentially with the same membership test.
    if let Some(hit) = scan_tier4(rt, tree) {
        return Some(hit);
    }
    if let Some(u) = user {
        let user_root = rt.join(format!("nvim.{u}"));
        if let Ok(subs) = fs::read_dir(&user_root) {
            for sub in subs.flatten() {
                let sub_path = sub.path();
                if let Some(hit) = scan_tier4(&sub_path, tree) {
                    return Some(hit);
                }
            }
        }
    }

    None
}

/// Scan a single directory for `nvim.<X>.0` sockets whose `<X>` parses as u32
/// and is in `tree`. Returns the first hit in `read_dir` order.
fn scan_tier4(dir: &Path, tree: &[u32]) -> Option<PathBuf> {
    let entries = fs::read_dir(dir).ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        let Some(rest) = name_str.strip_prefix("nvim.") else {
            continue;
        };
        let Some(pid_str) = rest.strip_suffix(".0") else {
            continue;
        };
        let Ok(cand_pid) = pid_str.parse::<u32>() else {
            continue;
        };
        if !tree.contains(&cand_pid) {
            continue;
        }
        let path = entry.path();
        if is_socket(&path) {
            return Some(path);
        }
    }
    None
}

/// Predicate testing whether `p` is an actual Unix socket (not a regular
/// file, not a dangling symlink). Pulled out as `pub(crate)` so the impl
/// agent can share it with tests.
#[must_use]
pub(crate) fn is_socket(p: &Path) -> bool {
    use std::os::unix::fs::FileTypeExt;
    std::fs::metadata(p)
        .map(|m| m.file_type().is_socket())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use std::os::unix::net::UnixListener;
    use tempfile::tempdir;

    /// Create a real Unix domain socket at `path`. The returned listener must
    /// be kept alive for the duration of the test (drop closes the listener
    /// but the inode persists; we keep it bound to be defensive across
    /// platforms/filesystems).
    fn mk_sock(path: &Path) -> UnixListener {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        UnixListener::bind(path).unwrap()
    }

    /// Write `/proc/<pid>/environ` with NUL-separated `K=V` pairs.
    fn write_environ(proc_root: &Path, pid: u32, pairs: &[(&str, &str)]) {
        let dir = proc_root.join(pid.to_string());
        fs::create_dir_all(&dir).unwrap();
        let mut bytes: Vec<u8> = Vec::new();
        for (k, v) in pairs {
            bytes.extend_from_slice(k.as_bytes());
            bytes.push(b'=');
            bytes.extend_from_slice(v.as_bytes());
            bytes.push(0);
        }
        fs::write(dir.join("environ"), bytes).unwrap();
    }

    // ---------- Tier 1: env ----------

    #[test]
    fn tier1_env_hit() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let sock_path = rt.path().join("explicit.sock");
        let _l = mk_sock(&sock_path);
        write_environ(
            proc_root.path(),
            42,
            &[("NVIM_LISTEN_ADDRESS", sock_path.to_str().unwrap())],
        );
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, None, &[]),
            Some(sock_path)
        );
    }

    #[test]
    fn tier1_env_nonexistent_falls_through() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        write_environ(
            proc_root.path(),
            42,
            &[("NVIM_LISTEN_ADDRESS", "/nonexistent/path/sock")],
        );
        // No tier-2 socket either → None.
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, None, &[]),
            None
        );

        // Now plant a tier-2 socket — the env path is still bogus, so we
        // should fall through and return the tier-2 hit.
        let tier2 = rt.path().join("nvim.42.0");
        let _l = mk_sock(&tier2);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, None, &[]),
            Some(tier2)
        );
    }

    #[test]
    fn tier1_env_regular_file_falls_through() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let reg_file = rt.path().join("not-a-socket");
        fs::write(&reg_file, b"hello").unwrap();
        write_environ(
            proc_root.path(),
            42,
            &[("NVIM_LISTEN_ADDRESS", reg_file.to_str().unwrap())],
        );
        let tier2 = rt.path().join("nvim.42.0");
        let _l = mk_sock(&tier2);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, None, &[]),
            Some(tier2)
        );
    }

    #[test]
    fn tier1_env_empty_value_falls_through() {
        // KEY= (explicitly empty) must not be treated as a path.
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        write_environ(proc_root.path(), 42, &[("NVIM_LISTEN_ADDRESS", "")]);
        let tier2 = rt.path().join("nvim.42.0");
        let _l = mk_sock(&tier2);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, None, &[]),
            Some(tier2)
        );
    }

    // ---------- Tier 2: direct pid ----------

    #[test]
    fn tier2_direct_zero() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let sock = rt.path().join("nvim.123.0");
        let _l = mk_sock(&sock);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 123, None, &[]),
            Some(sock)
        );
    }

    #[test]
    fn tier2_direct_nonzero_suffix() {
        // No .0 present; some other nvim.<pid>.* sibling exists.
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let sock = rt.path().join("nvim.123.7");
        let _l = mk_sock(&sock);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 123, None, &[]),
            Some(sock)
        );
    }

    #[test]
    fn tier2_prefers_zero_over_other_suffix() {
        // Both nvim.<pid>.0 and nvim.<pid>.7 exist — .0 wins (bash order).
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let zero = rt.path().join("nvim.123.0");
        let seven = rt.path().join("nvim.123.7");
        let _l0 = mk_sock(&zero);
        let _l7 = mk_sock(&seven);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 123, None, &[]),
            Some(zero)
        );
    }

    #[test]
    fn tier2_ignores_other_pid_prefix() {
        // nvim.1230.0 must not match a search for pid 123 — the trailing dot
        // in the prefix prevents that confusion.
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let other = rt.path().join("nvim.1230.0");
        let _l = mk_sock(&other);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 123, None, &[]),
            None
        );
    }

    // ---------- Tier 3: per-user ----------

    #[test]
    fn tier3_per_user_hit() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let sock = rt.path().join("nvim.alice/sub1/nvim.555.0");
        let _l = mk_sock(&sock);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 555, Some("alice"), &[]),
            Some(sock)
        );
    }

    #[test]
    fn tier3_skipped_when_user_none() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let sock = rt.path().join("nvim.alice/sub1/nvim.555.0");
        let _l = mk_sock(&sock);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 555, None, &[]),
            None
        );
    }

    #[test]
    fn tier3_walks_multiple_subdirs() {
        // Two subdirs under nvim.<user>; the matching socket is in the second.
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        fs::create_dir_all(rt.path().join("nvim.alice/empty")).unwrap();
        let sock = rt.path().join("nvim.alice/other/nvim.777.3");
        let _l = mk_sock(&sock);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 777, Some("alice"), &[]),
            Some(sock)
        );
    }

    // ---------- Tier 4: last resort, tree membership ----------

    #[test]
    fn tier4_descendant_pid_match() {
        // No direct match for pid 100, but a nvim.<descendant>.0 exists and
        // <descendant> is in the tree.
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let sock = rt.path().join("nvim.200.0");
        let _l = mk_sock(&sock);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 100, None, &[100, 200]),
            Some(sock)
        );
    }

    #[test]
    fn tier4_ignores_pid_not_in_tree() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let sock = rt.path().join("nvim.999.0");
        let _l = mk_sock(&sock);
        // Tree only contains 100; the 999 socket is ignored.
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 100, None, &[100]),
            None
        );
    }

    #[test]
    fn tier4_walks_per_user_subdirs() {
        // nvim.*.0 isn't in $rt but is in $rt/nvim.<u>/<sub>/.
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let sock = rt.path().join("nvim.alice/sX/nvim.314.0");
        let _l = mk_sock(&sock);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 100, Some("alice"), &[100, 314]),
            Some(sock)
        );
    }

    #[test]
    fn tier4_non_numeric_pid_name_skipped() {
        // nvim.notapid.0 must not crash or match.
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let bogus = rt.path().join("nvim.notapid.0");
        let _l = mk_sock(&bogus);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 100, None, &[100]),
            None
        );
    }

    // ---------- None cases ----------

    #[test]
    fn returns_none_when_nothing_matches() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 1, None, &[]),
            None
        );
    }

    #[test]
    fn returns_none_when_rt_missing() {
        // rt path that doesn't exist — every tier's read_dir errors silently.
        let tmp = tempdir().unwrap();
        let bogus_rt = tmp.path().join("nope");
        let proc_root = tempdir().unwrap();
        assert_eq!(
            socket_for_pid(&bogus_rt, proc_root.path(), 1, Some("alice"), &[1, 2, 3]),
            None
        );
    }

    #[test]
    fn returns_none_when_proc_root_missing() {
        // proc_root that doesn't exist — env tier silently returns None.
        let rt = tempdir().unwrap();
        let tmp = tempdir().unwrap();
        let bogus_proc = tmp.path().join("nope");
        assert_eq!(socket_for_pid(rt.path(), &bogus_proc, 1, None, &[]), None);
    }

    #[test]
    fn regular_file_at_tier2_path_skipped() {
        // A regular file at ${rt}/nvim.<pid>.0 must not be returned.
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let path = rt.path().join("nvim.42.0");
        fs::write(&path, b"").unwrap();
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, None, &[42]),
            None
        );
    }

    // ---------- priority ----------

    #[test]
    fn tier1_beats_tier2() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let env_sock = rt.path().join("env.sock");
        let _le = mk_sock(&env_sock);
        let tier2 = rt.path().join("nvim.42.0");
        let _l2 = mk_sock(&tier2);
        write_environ(
            proc_root.path(),
            42,
            &[("NVIM_LISTEN_ADDRESS", env_sock.to_str().unwrap())],
        );
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, None, &[]),
            Some(env_sock)
        );
    }

    #[test]
    fn tier2_beats_tier3() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let tier2 = rt.path().join("nvim.42.0");
        let _l2 = mk_sock(&tier2);
        let tier3 = rt.path().join("nvim.alice/sub/nvim.42.0");
        let _l3 = mk_sock(&tier3);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, Some("alice"), &[]),
            Some(tier2)
        );
    }

    #[test]
    fn tier2_beats_tier4() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        // Tier 2 socket for the queried pid.
        let tier2 = rt.path().join("nvim.42.0");
        let _l2 = mk_sock(&tier2);
        // Tier 4 candidate (a descendant pid).
        let tier4 = rt.path().join("nvim.200.0");
        let _l4 = mk_sock(&tier4);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, None, &[42, 200]),
            Some(tier2)
        );
    }

    #[test]
    fn tier3_beats_tier4() {
        let rt = tempdir().unwrap();
        let proc_root = tempdir().unwrap();
        let tier3 = rt.path().join("nvim.alice/sub/nvim.42.0");
        let _l3 = mk_sock(&tier3);
        let tier4 = rt.path().join("nvim.200.0");
        let _l4 = mk_sock(&tier4);
        assert_eq!(
            socket_for_pid(rt.path(), proc_root.path(), 42, Some("alice"), &[42, 200]),
            Some(tier3)
        );
    }
}
