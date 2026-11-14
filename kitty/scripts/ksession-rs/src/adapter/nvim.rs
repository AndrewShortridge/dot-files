//! Nvim adapter: discovers the RPC socket for an nvim foreground process,
//! drives `:mksession!`, dumps modified buffers, and emits a JSON manifest
//! sidecar consumed by the bundled Lua loader.
//!
//! Mirrors `capture_nvim_window` + `nvim_capture_to_file` +
//! `nvim_dump_modified_buffers` (`ksession.sh:139-235, 447-465`) but
//! collapses the 15×200ms polling loop to a single synchronous
//! `nvim_command` per Plan §5.3.
//!
//! Per Plan §5.3 "Error degradation": any RPC failure (socket missing,
//! connect refused, mksession error) folds to `Program::Raw { argv:
//! vec!["nvim".into()] }` — bare launch, cursor doesn't restore but the
//! save never aborts.
//!
//! ## Cache-read fast path (PRD-0010 Slice 3)
//!
//! Before attempting a live `:mksession!` RPC (~200ms), the adapter checks
//! for a pre-captured session file at `<state_dir>/.cache/nvim-<uid>.vim`
//! written by the kitty watcher module. If the cache file's mtime is >=
//! the `nvim_dirty` user-var timestamp (indicating no edits since last
//! watcher write), the cached content is returned directly — avoiding the
//! RPC round-trip entirely.

use std::path::{Path, PathBuf};

use async_trait::async_trait;

use super::{Adapter, AdapterError, WindowCtx};
use crate::model::Program;
use crate::nvim_rpc::{socket_for_pid, NvimConn};
use crate::perf;
use crate::proc;

/// On-disk layout for one nvim window's capture, all rooted at
/// `state_dir/nvim/`. Names match the Bash version bit-for-bit for the
/// `.vim` + `.dumps/` paths; the `.json` manifest is the additive new file
/// (Plan §6 "Additive only").
#[must_use]
pub(crate) fn paths_for(state_dir: &std::path::Path, uid: &str) -> NvimPaths {
    let base = state_dir.join("nvim");
    NvimPaths {
        session_vim: base.join(format!("win-{uid}.vim")),
        manifest: base.join(format!("win-{uid}.json")),
        dumps_dir: base.join(format!("win-{uid}.dumps")),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct NvimPaths {
    pub session_vim: PathBuf,
    pub manifest: PathBuf,
    pub dumps_dir: PathBuf,
}

/// Return the cache file path for a given window uid.
///
/// Layout: `<state_dir>/.cache/nvim-<uid>.vim`
#[must_use]
pub(crate) fn cache_path_for(state_dir: &Path, uid: &str) -> PathBuf {
    state_dir.join(".cache").join(format!("nvim-{uid}.vim"))
}

/// Determine whether the cache file is fresh relative to the `nvim_dirty`
/// user-var timestamp.
///
/// Returns `true` (cache hit) when:
/// - `dirty_ts_ms` is `Some(ts)` AND
/// - the cache file exists AND
/// - its mtime (ms since epoch) >= ts.
///
/// Returns `false` (cache miss / fall through to live) when:
/// - `dirty_ts_ms` is `None` (watcher not installed → always live), OR
/// - the cache file does not exist, OR
/// - the cache file's mtime < ts (edits occurred after last watcher write).
pub(crate) fn is_cache_fresh(cache_path: &Path, dirty_ts_ms: Option<u64>) -> bool {
    let Some(dirty_ts) = dirty_ts_ms else {
        // No nvim_dirty var means watcher isn't installed → always use live.
        return false;
    };
    match std::fs::metadata(cache_path) {
        Ok(meta) => {
            let mtime_ms = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            mtime_ms >= dirty_ts
        }
        Err(_) => false, // No cache file → not fresh
    }
}

#[derive(Default)]
pub struct NvimAdapter;

/// Resolve `$XDG_RUNTIME_DIR` with a `/run/user/<uid>` fallback. The uid is
/// read from `/proc/self` ownership so we avoid pulling in `nix` or `libc`
/// just for `getuid()`.
fn xdg_runtime_dir() -> PathBuf {
    std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let uid = std::fs::metadata("/proc/self")
                .map(|m| {
                    use std::os::unix::fs::MetadataExt;
                    m.uid()
                })
                .unwrap_or(1000);
            PathBuf::from(format!("/run/user/{uid}"))
        })
}

#[async_trait]
impl Adapter for NvimAdapter {
    fn name(&self) -> &'static str {
        "nvim"
    }

    fn detect(&self, ctx: &WindowCtx<'_>) -> bool {
        // ksession.sh:269,568 — string equality on the basename of /proc/PID/exe.
        matches!(ctx.fg_exe.as_deref(), Some("nvim"))
    }

    async fn capture(&self, ctx: &WindowCtx<'_>) -> Result<Program, AdapterError> {
        // --- Cache-read fast path (PRD-0010 Slice 3) ---
        // Check for a pre-captured session file from the kitty watcher before
        // doing the expensive live mksession RPC.
        let cache_path = cache_path_for(ctx.state_dir, &ctx.uid);
        let dirty_ts_ms: Option<u64> = ctx
            .kitty_window
            .user_vars
            .get("nvim_dirty")
            .and_then(|v| v.parse::<u64>().ok());

        if is_cache_fresh(&cache_path, dirty_ts_ms) {
            let _span = perf::span!(
                perf::Level::Debug,
                "adapter.nvim.capture.cache_hit",
                uid = ctx.uid,
            );
            return Ok(Program::Nvim {
                session_vim: cache_path,
                manifest: None,
                truncated_buffers: 0,
            });
        }

        let _miss_span = perf::span!(
            perf::Level::Debug,
            "adapter.nvim.capture.cache_miss",
            uid = ctx.uid,
        );

        let rt = xdg_runtime_dir();
        let user = std::env::var("USER").ok();

        // ksession.sh:453-455 — try fg_pid first, then window-root pid if the
        // foreground was a descendant (e.g. nvim → LSP child reported as fg).
        let tree = proc::descendants(ctx.proc_root, ctx.fg_pid);
        let sock =
            socket_for_pid(&rt, ctx.proc_root, ctx.fg_pid, user.as_deref(), &tree).or_else(|| {
                if ctx.window_root_pid != ctx.fg_pid {
                    let root_tree = proc::descendants(ctx.proc_root, ctx.window_root_pid);
                    socket_for_pid(
                        &rt,
                        ctx.proc_root,
                        ctx.window_root_pid,
                        user.as_deref(),
                        &root_tree,
                    )
                } else {
                    None
                }
            });

        // ksession.sh:462-463 fallback: no socket → bare `nvim` argv.
        let Some(sock) = sock else {
            return Ok(Program::Raw {
                argv: vec!["nvim".into()],
            });
        };

        let paths = paths_for(ctx.state_dir, &ctx.uid);
        // mksession needs the parent dir to exist; mkdir failure here will
        // surface as an mksession error and fold to bare nvim below.
        if let Some(parent) = paths.session_vim.parent() {
            let _ = std::fs::create_dir_all(parent);
        }

        let conn = match NvimConn::connect(&sock).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!(
                    "ksession: nvim adapter: connect to {} failed: {e}",
                    sock.display()
                );
                return Ok(Program::Raw {
                    argv: vec!["nvim".into()],
                });
            }
        };

        if let Err(e) = conn.mksession(&paths.session_vim).await {
            eprintln!(
                "ksession: nvim adapter: mksession to {} failed: {e}",
                paths.session_vim.display()
            );
            return Ok(Program::Raw {
                argv: vec!["nvim".into()],
            });
        }

        // Buffer-dump failure is soft: we still have a usable session.vim,
        // just no modified-buffer restore.
        let dumps = match conn.dump_modified_buffers(&paths.dumps_dir).await {
            Ok(d) => d,
            Err(e) => {
                eprintln!(
                    "ksession: nvim adapter: buffer dump to {} failed: {e}",
                    paths.dumps_dir.display()
                );
                Vec::new()
            }
        };

        let truncated_buffers = dumps.iter().filter(|d| d.truncated).count() as u32;

        if dumps.is_empty() {
            return Ok(Program::Nvim {
                session_vim: paths.session_vim,
                manifest: None,
                truncated_buffers: 0,
            });
        }

        // Manifest write + session.vim Lua-loader append are best-effort
        // but coupled: appending the `require('ksession_restore').load(...)`
        // line to session.vim only makes sense if the manifest actually
        // landed on disk. If the manifest write fails, skip the append and
        // degrade to a cursor-only restore (manifest: None).
        let manifest_value = serde_json::json!({
            "schema": 1u32,
            "buffers": &dumps,
        });
        let manifest_bytes = match serde_json::to_vec_pretty(&manifest_value) {
            Ok(b) => b,
            Err(e) => {
                eprintln!(
                    "ksession: nvim adapter: serialize manifest failed: {e} \
                     — degrading to cursor-only restore"
                );
                return Ok(Program::Nvim {
                    session_vim: paths.session_vim,
                    manifest: None,
                    truncated_buffers: 0,
                });
            }
        };
        if let Err(e) = crate::fsx::write_atomic(&paths.manifest, &manifest_bytes) {
            eprintln!(
                "ksession: nvim adapter: atomic write manifest to {} failed: {e} \
                 — degrading to cursor-only restore",
                paths.manifest.display()
            );
            return Ok(Program::Nvim {
                session_vim: paths.session_vim,
                manifest: None,
                truncated_buffers: 0,
            });
        }

        // Single-quote path embed is safe because `paths.manifest` is
        // constructed from a digit-only uid and the state dir prefix — no
        // embedded apostrophes possible by construction.
        let mut session_vim_contents =
            std::fs::read_to_string(&paths.session_vim).unwrap_or_default();
        if !session_vim_contents.ends_with('\n') {
            session_vim_contents.push('\n');
        }
        let manifest_filename = paths
            .manifest
            .file_name()
            .and_then(|s| s.to_str())
            .expect("manifest path always has a filename");
        session_vim_contents.push_str(&format!(
            "\n\" ---- ksession buffer restore ----\nlua require('ksession_restore').load(vim.fn.expand('<sfile>:p:h') .. '/{}')\n",
            manifest_filename
        ));
        if let Err(e) =
            crate::fsx::write_atomic(&paths.session_vim, session_vim_contents.as_bytes())
        {
            eprintln!(
                "ksession: nvim adapter: atomic write session.vim append to {} failed: {e} \
                 — session.vim from mksession is still intact",
                paths.session_vim.display()
            );
        }

        Ok(Program::Nvim {
            session_vim: paths.session_vim,
            manifest: Some(paths.manifest),
            truncated_buffers,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapter::tests::CtxFixture;
    use crate::adapter::Registry;
    use pretty_assertions::assert_eq;
    use std::os::unix::net::UnixListener;
    use std::path::Path;
    use std::process::Stdio;
    use std::time::Duration;
    use tempfile::tempdir;

    // ---------- detect ----------

    #[test]
    fn detect_matches_nvim_only() {
        let fx = CtxFixture::new();
        let a = NvimAdapter;
        assert!(a.detect(&fx.ctx(1, Some("nvim".into()))));
        assert!(!a.detect(&fx.ctx(1, Some("vim".into()))));
        assert!(!a.detect(&fx.ctx(1, Some("nvim-qt".into()))));
        assert!(!a.detect(&fx.ctx(1, None)));
        assert!(!a.detect(&fx.ctx(1, Some(String::new()))));
    }

    // ---------- paths_for ----------

    #[test]
    fn paths_for_layout() {
        let p = paths_for(Path::new("/state"), "abc123");
        assert_eq!(p.session_vim, PathBuf::from("/state/nvim/win-abc123.vim"));
        assert_eq!(p.manifest, PathBuf::from("/state/nvim/win-abc123.json"));
        assert_eq!(p.dumps_dir, PathBuf::from("/state/nvim/win-abc123.dumps"));
    }

    // ---------- capture: no socket → bare nvim ----------

    /// Build a WindowCtx with XDG_RUNTIME_DIR / USER scoped to the test's
    /// own tempdir + a sentinel user that won't collide with the host's
    /// real nvim sockets. `proc_root` is empty so socket_for_pid's tier 1
    /// also yields nothing.
    ///
    /// NB: this mutates process env. `serial_test` isn't a dep; the test
    /// names below are scheduled close together by `cargo test` per-thread
    /// but the env vars are reset on drop of the guard to minimise blast
    /// radius on parallel test runs.
    /// Serializes the three env-mutating tests below so they don't race on
    /// the process-global `XDG_RUNTIME_DIR` / `USER` env vars that the
    /// adapter reads via `std::env::var`. cargo runs `#[test]` on a thread
    /// pool by default, and without this lock the three tests would
    /// stomp on each other's env between `set_var` and the adapter's read,
    /// causing intermittent fallback-to-Raw failures in
    /// `capture_with_real_nvim_emits_program_nvim`. We avoid pulling in
    /// `serial_test` to honour the no-new-deps rule.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    struct EnvGuard {
        old_xdg: Option<String>,
        old_user: Option<String>,
        // Held for the lifetime of the guard so the lock is released only
        // after env vars are restored in Drop.
        _lock: std::sync::MutexGuard<'static, ()>,
    }
    impl EnvGuard {
        fn set(xdg: &Path, user: Option<&str>) -> Self {
            // Recover from poisoning: a panic in another test that held the
            // lock should not cascade into spurious failures here — the
            // env-restore in Drop runs regardless of panic outcome.
            let lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let g = Self {
                old_xdg: std::env::var("XDG_RUNTIME_DIR").ok(),
                old_user: std::env::var("USER").ok(),
                _lock: lock,
            };
            std::env::set_var("XDG_RUNTIME_DIR", xdg);
            match user {
                Some(u) => std::env::set_var("USER", u),
                None => std::env::remove_var("USER"),
            }
            g
        }
    }
    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.old_xdg {
                Some(v) => std::env::set_var("XDG_RUNTIME_DIR", v),
                None => std::env::remove_var("XDG_RUNTIME_DIR"),
            }
            match &self.old_user {
                Some(v) => std::env::set_var("USER", v),
                None => std::env::remove_var("USER"),
            }
        }
    }

    #[tokio::test]
    async fn capture_no_socket_yields_raw_nvim_argv() {
        // FIXME(serial): env mutation. See EnvGuard.
        let fx = CtxFixture::new();
        let rt = tempdir().unwrap();
        let _guard = EnvGuard::set(rt.path(), Some("ksession_test_no_such_user"));

        // No /proc/<pid> seeded → tier 1 silent; rt is empty → tiers 2-4 silent.
        let reg = Registry::empty();
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 4242,
            fg_exe: Some("nvim".into()),
            window_root_pid: 4242,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };

        let out = NvimAdapter.capture(&ctx).await.unwrap();
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["nvim".into()],
            }
        );
    }

    // ---------- capture: connect error → bare nvim ----------

    #[tokio::test]
    async fn capture_dead_socket_folds_to_raw_nvim() {
        // FIXME(serial): env mutation. See EnvGuard.
        // Create a real Unix socket file at the tier-2 path BUT with nothing
        // listening (we drop the listener immediately) — connect will fail,
        // exercising the connect-error fold path.
        let fx = CtxFixture::new();
        let rt = tempdir().unwrap();
        let _guard = EnvGuard::set(rt.path(), Some("ksession_test_no_such_user"));

        let sock_path = rt.path().join("nvim.4242.0");
        {
            let _listener = UnixListener::bind(&sock_path).unwrap();
            // Drop the listener so connect() will fail — but the socket
            // *file* persists (it's the inode that matters for tier-2's
            // is_socket check). Some systems may auto-unlink on listener
            // drop; tolerate both outcomes below.
        }
        // If the socket file no longer exists (listener unlinked it), this
        // test reduces to the no-socket case. Either way the expected output
        // is the same.

        let reg = Registry::empty();
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 4242,
            fg_exe: Some("nvim".into()),
            window_root_pid: 4242,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };

        let out = NvimAdapter.capture(&ctx).await.unwrap();
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["nvim".into()],
            }
        );
    }

    // ---------- capture: real nvim end-to-end ----------

    fn nvim_or_skip() -> Option<()> {
        if std::process::Command::new("nvim")
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .ok()?
            .success()
        {
            Some(())
        } else {
            None
        }
    }

    async fn spawn_nvim(sock: &Path) -> tokio::process::Child {
        let child = tokio::process::Command::new("nvim")
            .args(["--headless", "--clean", "-u", "NORC", "--listen"])
            .arg(sock)
            .kill_on_drop(true)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn nvim");
        for _ in 0..80 {
            if sock.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(sock.exists(), "nvim socket never appeared at {sock:?}");
        child
    }

    #[tokio::test]
    async fn capture_with_real_nvim_emits_program_nvim() {
        // FIXME(serial): env mutation. See EnvGuard.
        if nvim_or_skip().is_none() {
            eprintln!("skip: nvim not on PATH");
            return;
        }

        let fx = CtxFixture::new();
        let rt = tempdir().unwrap();
        // Use a sentinel USER value so tier 3 finds nothing in our scoped rt.
        let _guard = EnvGuard::set(rt.path(), Some("ksession_test_no_such_user"));

        // Tier-2 socket naming: nvim.<pid>.0. We pick an arbitrary pid; the
        // adapter only uses it for the socket name and /proc lookups (the
        // latter find nothing in our empty proc_root, so it just falls to
        // tier 2).
        let fake_pid: u32 = 4242;
        let sock = rt.path().join(format!("nvim.{fake_pid}.0"));
        let mut child = spawn_nvim(&sock).await;

        let reg = Registry::empty();
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: fake_pid,
            fg_exe: Some("nvim".into()),
            window_root_pid: fake_pid,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };

        let out = NvimAdapter.capture(&ctx).await.unwrap();

        match out {
            Program::Nvim {
                session_vim,
                manifest,
                truncated_buffers,
            } => {
                assert!(session_vim.exists(), "session_vim should exist");
                let meta = std::fs::metadata(&session_vim).unwrap();
                assert!(meta.len() > 0, "session_vim should be non-empty");
                assert_eq!(truncated_buffers, 0);
                // No buffers dirtied → manifest should be None.
                assert!(
                    manifest.is_none(),
                    "expected None manifest with no modified buffers, got {manifest:?}"
                );
            }
            other => panic!("expected Program::Nvim, got {other:?}"),
        }

        let _ = child.kill().await;
    }

    // ---------- cache_path_for ----------

    #[test]
    fn cache_path_for_layout() {
        let p = cache_path_for(Path::new("/state"), "win42");
        assert_eq!(p, PathBuf::from("/state/.cache/nvim-win42.vim"));
    }

    // ---------- is_cache_fresh ----------

    #[test]
    fn cache_fresh_mtime_greater_than_dirty_ts() {
        let dir = tempdir().unwrap();
        let cache = dir.path().join("nvim-test.vim");
        std::fs::write(&cache, "\" mksession content\n").unwrap();
        // Set the dirty_ts to 0 (ancient) — any real file will have mtime > 0.
        assert!(is_cache_fresh(&cache, Some(0)));
    }

    #[test]
    fn cache_fresh_mtime_equals_dirty_ts() {
        let dir = tempdir().unwrap();
        let cache = dir.path().join("nvim-test.vim");
        std::fs::write(&cache, "\" mksession content\n").unwrap();
        // Read back the actual mtime and use that as dirty_ts → equal → fresh.
        let mtime_ms = std::fs::metadata(&cache)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        assert!(is_cache_fresh(&cache, Some(mtime_ms)));
    }

    #[test]
    fn cache_stale_mtime_less_than_dirty_ts() {
        let dir = tempdir().unwrap();
        let cache = dir.path().join("nvim-test.vim");
        std::fs::write(&cache, "\" mksession content\n").unwrap();
        // Use a dirty_ts far in the future → stale.
        let future_ts = u64::MAX / 2;
        assert!(!is_cache_fresh(&cache, Some(future_ts)));
    }

    #[test]
    fn cache_no_dirty_ts_always_miss() {
        let dir = tempdir().unwrap();
        let cache = dir.path().join("nvim-test.vim");
        std::fs::write(&cache, "\" mksession content\n").unwrap();
        // None dirty_ts → watcher not installed → always miss.
        assert!(!is_cache_fresh(&cache, None));
    }

    #[test]
    fn cache_file_missing_is_miss() {
        let dir = tempdir().unwrap();
        let cache = dir.path().join("nvim-nonexistent.vim");
        // File does not exist → miss regardless of dirty_ts.
        assert!(!is_cache_fresh(&cache, Some(0)));
    }

    // ---------- cache hit integration ----------

    #[tokio::test]
    async fn nvim_cache_hit_smoke() {
        // Pre-populate a cache file with valid mksession content and set
        // user_vars with an older nvim_dirty timestamp. The adapter should
        // return the cached path without doing any RPC.
        let mut fx = CtxFixture::new();

        // Write cache file.
        let cache_dir = fx.state.path().join(".cache");
        std::fs::create_dir_all(&cache_dir).unwrap();
        let cache_file = cache_dir.join("nvim-test-uid.vim");
        std::fs::write(&cache_file, "\" cached session\nset nocompatible\n").unwrap();

        // Set nvim_dirty to 0 (ancient) so the cache file's mtime wins.
        fx.with_user_vars(&[("nvim_dirty", "0")]);

        let reg = Registry::empty();
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 9999,
            fg_exe: Some("nvim".into()),
            window_root_pid: 9999,
            state_dir: fx.state.path(),
            uid: "test-uid".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };

        let out = NvimAdapter.capture(&ctx).await.unwrap();
        assert_eq!(
            out,
            Program::Nvim {
                session_vim: cache_file,
                manifest: None,
                truncated_buffers: 0,
            }
        );
    }

    #[tokio::test]
    async fn nvim_cache_stale_falls_back() {
        // Set dirty timestamp far in the future so the cache file is stale.
        // With no socket available, the adapter should fall through to the
        // live path and ultimately return Program::Raw (no socket found).
        let mut fx = CtxFixture::new();
        let rt = tempdir().unwrap();
        let _guard = EnvGuard::set(rt.path(), Some("ksession_test_no_such_user"));

        // Write cache file.
        let cache_dir = fx.state.path().join(".cache");
        std::fs::create_dir_all(&cache_dir).unwrap();
        let cache_file = cache_dir.join("nvim-test-uid.vim");
        std::fs::write(&cache_file, "\" cached session\nset nocompatible\n").unwrap();

        // Set nvim_dirty to far future → cache is stale.
        fx.with_user_vars(&[("nvim_dirty", "99999999999999")]);

        let reg = Registry::empty();
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 9999,
            fg_exe: Some("nvim".into()),
            window_root_pid: 9999,
            state_dir: fx.state.path(),
            uid: "test-uid".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };

        let out = NvimAdapter.capture(&ctx).await.unwrap();
        // Stale cache → fall through to live → no socket → bare nvim.
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["nvim".into()],
            }
        );
    }

    #[tokio::test]
    async fn nvim_no_user_var_falls_back_to_live() {
        // No nvim_dirty user var → watcher not installed → always live path.
        // With no socket, this degrades to bare nvim.
        let fx = CtxFixture::new();
        let rt = tempdir().unwrap();
        let _guard = EnvGuard::set(rt.path(), Some("ksession_test_no_such_user"));

        // Write cache file (exists but should not be used without user var).
        let cache_dir = fx.state.path().join(".cache");
        std::fs::create_dir_all(&cache_dir).unwrap();
        let cache_file = cache_dir.join("nvim-test-uid.vim");
        std::fs::write(&cache_file, "\" cached session\n").unwrap();

        let reg = Registry::empty();
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 9999,
            fg_exe: Some("nvim".into()),
            window_root_pid: 9999,
            state_dir: fx.state.path(),
            uid: "test-uid".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };

        let out = NvimAdapter.capture(&ctx).await.unwrap();
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["nvim".into()],
            }
        );
    }
}
