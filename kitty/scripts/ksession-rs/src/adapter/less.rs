//! Pager (less/more/most/pg/man) adapter.
//!
//! Mirrors `less_state` + `capture_less_window` (ksession.sh:155-169 + 467-484).
//! Scans `/proc/<fg_pid>/fd/*` for the first regular file the pager is reading
//! that isn't a terminfo/locale/dev/proc/sys artefact, then reads its byte
//! offset from `/proc/<fg_pid>/fdinfo/<n>`. Falls back to a `Program::Raw`
//! with just the pager basename if nothing matches — bash:482 emits the same
//! "basename only" launch line.

use std::path::{Path, PathBuf};

use async_trait::async_trait;

use super::{Adapter, AdapterError, WindowCtx};
use crate::model::Program;
use crate::proc;

#[derive(Default)]
pub struct LessAdapter;

#[async_trait]
impl Adapter for LessAdapter {
    fn name(&self) -> &'static str {
        "less"
    }

    fn detect(&self, ctx: &WindowCtx<'_>) -> bool {
        // ksession.sh:281,574 — case-sensitive shell glob match.
        matches!(
            ctx.fg_exe.as_deref(),
            Some("less" | "more" | "most" | "pg" | "man")
        )
    }

    async fn capture(&self, ctx: &WindowCtx<'_>) -> Result<Program, AdapterError> {
        // ksession.sh:469 — capture_less_window is invoked with $fg_pid (the
        // pager process itself, not the window root).
        let pid = ctx.fg_pid;
        match find_file_fd(ctx.proc_root, pid) {
            Some((file, pos)) => {
                // file_size: bash uses `stat -c '%s'` and defaults to 0 on
                // failure. We do the same — render.rs handles size==0 (no
                // divide by zero, just emits 0%).
                let file_size = std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
                Ok(Program::Less {
                    file,
                    byte_offset: pos,
                    file_size,
                })
            }
            None => {
                // ksession.sh:482 — bash emits just the basename when no file
                // could be recovered. Mirror by yielding Raw with the pager
                // name as argv[0]. fg_exe is set whenever detect() passed; the
                // unwrap_or is defensive.
                let argv0 = ctx.fg_exe.clone().unwrap_or_else(|| "less".into());
                Ok(Program::Raw { argv: vec![argv0] })
            }
        }
    }
}

/// First eligible (target, byte-offset) under `/proc/<pid>/fd/`.
///
/// "Eligible" follows `less_state`'s skip list (ksession.sh:158-163):
///   - target must be absolute
///   - target prefixes `/dev/`, `/proc/`, `/sys/` are skipped
///   - any path containing `/usr/share/terminfo/` is skipped
///   - any path ending `/locale-archive` is skipped
///   - target must point at a real regular file on disk
///
/// fdinfo `pos:` defaults to 0 on parse failure (ksession.sh:165 awk fallback).
fn find_file_fd(proc_root: &Path, pid: u32) -> Option<(PathBuf, u64)> {
    // bash:157 iterates `/proc/$pid/fd/*` (lex-sorted: 10 < 2 < 3); we use
    // numeric ascending. Real pagers open ≤1 eligible file, so the
    // first-match-wins selection is identical in practice.
    for fd in proc::list_fds(proc_root, pid) {
        let Some(target) = proc::fd_target(proc_root, pid, fd) else {
            continue;
        };
        if !target.is_absolute() {
            continue;
        }
        let s = target.to_string_lossy();
        if s.starts_with("/dev/") || s.starts_with("/proc/") || s.starts_with("/sys/") {
            continue;
        }
        if s.contains("/usr/share/terminfo/") {
            continue;
        }
        if s.ends_with("/locale-archive") {
            continue;
        }
        // bash `[[ -f "$target" ]]` — regular file, no symlink follow
        // distinction in `metadata` matters here because fd_target already
        // returned the kernel-reported absolute path; the kernel exposes the
        // resolved target, not a chain.
        if !std::fs::metadata(&target)
            .map(|m| m.is_file())
            .unwrap_or(false)
        {
            continue;
        }
        let pos = proc::fdinfo_pos(proc_root, pid, fd).unwrap_or(0);
        return Some((target, pos));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapter::tests::{write_fd, write_fdinfo_no_pos, write_fdinfo_pos, CtxFixture};
    use crate::adapter::WindowCtx;
    use pretty_assertions::assert_eq;
    use std::fs;
    use std::os::unix::fs::symlink;

    // ---------- detect ----------

    #[test]
    fn detect_matches_pagers() {
        let fx = CtxFixture::new();
        for name in ["less", "more", "most", "pg", "man"] {
            assert!(
                LessAdapter.detect(&fx.ctx(1, Some(name.into()))),
                "{name} should match"
            );
        }
    }

    #[test]
    fn detect_rejects_non_pagers() {
        let fx = CtxFixture::new();
        for name in ["nvim", "bash", "vim", "tmux"] {
            assert!(!LessAdapter.detect(&fx.ctx(1, Some(name.into()))));
        }
        assert!(!LessAdapter.detect(&fx.ctx(1, None)));
        // case-sensitive: shell glob in bash:574 doesn't fold case.
        assert!(!LessAdapter.detect(&fx.ctx(1, Some("LESS".into()))));
    }

    // ---------- capture: happy path ----------

    #[tokio::test]
    async fn capture_real_file_at_nonzero_pos() {
        let fx = CtxFixture::new();
        let file = fx.tmp.path().join("notes.txt");
        fs::write(&file, b"hello, world").unwrap();
        write_fd(&fx.proc_root(), 10, 3, file.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 10, 3, 4);

        let p = LessAdapter
            .capture(&fx.ctx(10, Some("less".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Less {
                file,
                byte_offset: 4,
                file_size: 12,
            }
        );
    }

    // ---------- capture: skip list ----------

    #[tokio::test]
    async fn capture_skips_dev_proc_sys_terminfo_locale() {
        let fx = CtxFixture::new();
        // Plant a bunch of would-be-skipped fds, then a single legit file at
        // the highest fd so we can prove it's the one chosen after skipping.
        write_fd(&fx.proc_root(), 20, 0, "/dev/null");
        write_fd(&fx.proc_root(), 20, 1, "/proc/cpuinfo");
        write_fd(&fx.proc_root(), 20, 2, "/sys/devices/foo");
        write_fd(
            &fx.proc_root(),
            20,
            3,
            "/some/path/usr/share/terminfo/x/xterm",
        );
        write_fd(&fx.proc_root(), 20, 4, "/usr/lib/locale/locale-archive");

        let file = fx.tmp.path().join("good.txt");
        fs::write(&file, b"a").unwrap();
        write_fd(&fx.proc_root(), 20, 5, file.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 20, 5, 0);

        let p = LessAdapter
            .capture(&fx.ctx(20, Some("less".into())))
            .await
            .unwrap();
        match p {
            Program::Less {
                file: f,
                byte_offset,
                file_size,
            } => {
                assert_eq!(f, file);
                assert_eq!(byte_offset, 0);
                assert_eq!(file_size, 1);
            }
            other => panic!("expected Less, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn capture_skips_broken_symlink() {
        // Target string is plausible but the file doesn't exist on disk.
        let fx = CtxFixture::new();
        write_fd(&fx.proc_root(), 21, 3, "/nonexistent/missing.txt");
        // No second legit fd → adapter falls through to Raw fallback.
        let p = LessAdapter
            .capture(&fx.ctx(21, Some("less".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["less".into()]
            }
        );
    }

    #[tokio::test]
    async fn capture_skips_relative_target() {
        // less_state's `[[ "$target" == /* ...]]` rejects non-absolute targets.
        // /proc never reports relative paths in real life, but the guard is
        // explicit so we test the equivalent Rust check.
        let fx = CtxFixture::new();
        // Plant a relative-target symlink at fd 3 → must be skipped.
        let fd_dir = fx.proc_root().join("22/fd");
        fs::create_dir_all(&fd_dir).unwrap();
        symlink("relative-target.txt", fd_dir.join("3")).unwrap();
        // ... then a legit absolute target at fd 4.
        let file = fx.tmp.path().join("good2.txt");
        fs::write(&file, b"xx").unwrap();
        write_fd(&fx.proc_root(), 22, 4, file.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 22, 4, 1);

        let p = LessAdapter
            .capture(&fx.ctx(22, Some("less".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Less {
                file,
                byte_offset: 1,
                file_size: 2,
            }
        );
    }

    // ---------- capture: fallback to Raw ----------

    #[tokio::test]
    async fn capture_no_eligible_fd_yields_raw_basename() {
        let fx = CtxFixture::new();
        // Only excluded paths in the fd table.
        write_fd(&fx.proc_root(), 30, 0, "/dev/pts/0");
        write_fd(&fx.proc_root(), 30, 1, "/dev/pts/0");
        write_fd(&fx.proc_root(), 30, 2, "/dev/pts/0");

        let p = LessAdapter
            .capture(&fx.ctx(30, Some("man".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["man".into()]
            }
        );
    }

    // ---------- capture: fdinfo defaults ----------

    #[tokio::test]
    async fn capture_missing_fdinfo_pos_defaults_zero() {
        let fx = CtxFixture::new();
        let file = fx.tmp.path().join("nopos.txt");
        fs::write(&file, b"data").unwrap();
        write_fd(&fx.proc_root(), 40, 3, file.to_str().unwrap());
        // Note: NO fdinfo file written → pos defaults to 0 (bash :165 awk
        // fallback semantics).
        let p = LessAdapter
            .capture(&fx.ctx(40, Some("less".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Less {
                file,
                byte_offset: 0,
                file_size: 4,
            }
        );
    }

    // ---------- capture: locale-archive skip is path-suffix, not full-path ----------

    #[tokio::test]
    async fn capture_skips_any_path_ending_in_locale_archive() {
        // bash glob `*/locale-archive` matches ANY path ending in
        // `/locale-archive` — not just the canonical /usr/lib/locale one. Use
        // a tempdir-rooted file so the path exists on disk (an extra hurdle
        // for the test, since the skip check happens BEFORE the is_file
        // check; but if a future refactor swaps that order, the existence
        // requirement won't bite us). Then plant a fallback file at a higher
        // fd to prove the skip happened.
        let fx = CtxFixture::new();
        let archive = fx.tmp.path().join("locale-archive");
        fs::write(&archive, b"binary").unwrap();
        write_fd(&fx.proc_root(), 23, 3, archive.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 23, 3, 0);

        let fallback = fx.tmp.path().join("readme.md");
        fs::write(&fallback, b"docs").unwrap();
        write_fd(&fx.proc_root(), 23, 4, fallback.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 23, 4, 0);

        let p = LessAdapter
            .capture(&fx.ctx(23, Some("less".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Less {
                file: fallback,
                byte_offset: 0,
                file_size: 4,
            }
        );
    }

    // ---------- capture: empty file (file_size == 0) ----------

    #[tokio::test]
    async fn capture_empty_file_records_zero_size_no_panic() {
        // Empty file is a legit edge case (`touch empty.log | less empty.log`).
        // capture must faithfully record file_size: 0 — conf/render handles
        // the divide-by-zero downstream; this layer just reports the truth.
        let fx = CtxFixture::new();
        let file = fx.tmp.path().join("empty.log");
        fs::write(&file, b"").unwrap();
        write_fd(&fx.proc_root(), 24, 3, file.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 24, 3, 0);

        let p = LessAdapter
            .capture(&fx.ctx(24, Some("less".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Less {
                file,
                byte_offset: 0,
                file_size: 0,
            }
        );
    }

    // ---------- capture: fdinfo file present but lacks `pos:` line ----------

    #[tokio::test]
    async fn capture_fdinfo_present_but_no_pos_line_defaults_offset_zero() {
        // proc::fdinfo_pos returns None when the `pos:` field is missing; the
        // adapter's `.unwrap_or(0)` then kicks in. Differential vs the
        // "missing fdinfo file" case already covered.
        let fx = CtxFixture::new();
        let file = fx.tmp.path().join("missing_pos.txt");
        fs::write(&file, b"hello world").unwrap();
        write_fd(&fx.proc_root(), 25, 3, file.to_str().unwrap());
        write_fdinfo_no_pos(&fx.proc_root(), 25, 3);

        let p = LessAdapter
            .capture(&fx.ctx(25, Some("less".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Less {
                file,
                byte_offset: 0,
                file_size: 11,
            }
        );
    }

    // ---------- capture: defensive `fg_exe = None` fallback (item M) ----------

    #[tokio::test]
    async fn capture_with_none_fg_exe_falls_back_to_literal_less() {
        // detect() guarantees fg_exe is Some, but capture() defensively
        // falls back to "less" if a future orchestrator regression bypasses
        // detect. Construct the ctx by hand to exercise that branch.
        let fx = CtxFixture::new();
        // No eligible fds → find_file_fd returns None → fallback path.
        let reg = crate::adapter::Registry::empty();
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 26,
            fg_exe: None,
            window_root_pid: 26,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let p = LessAdapter.capture(&ctx).await.unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["less".into()],
            }
        );
    }

    // ---------- capture: smallest fd wins ----------

    #[tokio::test]
    async fn capture_smallest_eligible_fd_wins() {
        // Two eligible files at fd 3 and fd 5; fd 3 must win because
        // list_fds is sorted ascending and we return on first match.
        let fx = CtxFixture::new();
        let f_small = fx.tmp.path().join("small-fd.txt");
        let f_big = fx.tmp.path().join("big-fd.txt");
        fs::write(&f_small, b"small").unwrap();
        fs::write(&f_big, b"big").unwrap();

        write_fd(&fx.proc_root(), 50, 5, f_big.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 50, 5, 1);
        write_fd(&fx.proc_root(), 50, 3, f_small.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 50, 3, 2);

        let p = LessAdapter
            .capture(&fx.ctx(50, Some("less".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Less {
                file: f_small,
                byte_offset: 2,
                file_size: 5,
            }
        );
    }
}
