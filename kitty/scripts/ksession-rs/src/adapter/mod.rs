//! Per-window capture adapters.
//!
//! Each adapter inspects a `WindowCtx` (window JSON + foreground pid + /proc
//! root) and may yield a typed `Program`. A `Registry` walks adapters in
//! registration order, taking the first that returns `Ok` from its `detect`
//! gate; on adapter failure it logs and falls through, ultimately producing
//! `Program::BareShell` if nothing matches. This mirrors the per-window
//! degradation in `ksession.sh` where an unrecognised foreground gracefully
//! falls back to `/bin/bash -l` (see `emit_launch_for_window` line 584).
//!
//! Per `RUST_PORT_PLAN.md` §5.5: `AdapterError` lives in this module (NOT in
//! `crate::error::KError`) so a single failing window never aborts the save.

use std::path::Path;

#[derive(thiserror::Error, Debug)]
pub enum AdapterError {
    #[error("cmdline unavailable for pid {pid}")]
    NoCmdline { pid: u32 },
    #[error("capture timed out for window")]
    Timeout,
}

/// Inputs available to every adapter at capture time.
///
/// Borrows from longer-lived structures (the kitty `ls` snapshot, the state
/// directory, the registry itself). All trait methods take `&WindowCtx<'_>`
/// to keep the elided lifetime explicit across async/trait boundaries.
pub struct WindowCtx<'a> {
    pub kitty_window: &'a crate::kitty::ls::Window,
    /// PID whose `/proc/<pid>/exe` matched the case in `emit_launch_for_window`.
    /// For `less/man`/etc this is the descendant; for shell-only windows the
    /// orchestrator normalises `fg_exe` to `None` and `fg_pid` reverts to the
    /// window root.
    pub fg_pid: u32,
    /// `None` means "no detected interactive program" — the shell adapter's
    /// trigger. Otherwise the basename of `/proc/<fg_pid>/exe`.
    pub fg_exe: Option<String>,
    /// Window root pid (kitty `pid` field). Shell capture keys off this per
    /// `ksession.sh` line 578: `capture_shell_window "$w_pid"`.
    pub window_root_pid: u32,
    pub state_dir: &'a Path,
    /// Unique key for sidecar filenames (e.g. session.vim, dumps dir).
    pub uid: String,
    /// `/proc` root, parameterised for fixture tests.
    pub proc_root: &'a Path,
    pub registry: &'a Registry,
    /// Per-save tmux control-mode connection cache. `None` when control
    /// mode is disabled or unavailable. Slice 3 will wire this into
    /// `TmuxAdapter` so it uses `TmuxControl` instead of `TmuxCli`.
    pub tmux_control_cache: Option<&'a crate::tmux_rpc::TmuxControlCache>,
}

#[async_trait::async_trait]
pub trait Adapter: Send + Sync {
    fn name(&self) -> &'static str;
    fn detect(&self, ctx: &WindowCtx<'_>) -> bool;
    async fn capture(&self, ctx: &WindowCtx<'_>) -> Result<crate::model::Program, AdapterError>;
}

/// Ordered adapter chain. First adapter whose `detect` is true wins; on
/// capture error we log and try nothing else — bash's catch-all `*` arm is
/// represented by registering `RawAdapter` last.
pub struct Registry {
    adapters: Vec<Box<dyn Adapter>>,
}

impl Registry {
    #[must_use]
    pub fn new(adapters: Vec<Box<dyn Adapter>>) -> Self {
        Self { adapters }
    }

    /// Empty registry for tests that need a `WindowCtx` but no dispatch.
    #[must_use]
    pub fn empty() -> Self {
        Self {
            adapters: Vec::new(),
        }
    }

    /// Walk adapters, returning the first successful capture along with any
    /// `AdapterError`s collected from earlier adapters that detected but
    /// errored. If no adapter matches OR every match errors, the returned
    /// program is `Program::BareShell` and the error vec carries the chain
    /// of failures so the orchestrator can surface them (per ADR 0001).
    ///
    /// L3 spans (`debug` level) are emitted per adapter per window:
    /// - `adapter.<name>.detect` — one per adapter, wrapping the detect
    ///   call.
    /// - `adapter.<name>.capture` — one per matched adapter, wrapping the
    ///   capture call.
    pub async fn capture(&self, ctx: &WindowCtx<'_>) -> (crate::model::Program, Vec<AdapterError>) {
        use crate::perf;

        let mut errors: Vec<AdapterError> = Vec::new();
        for a in &self.adapters {
            let detected = {
                let _detect_span =
                    perf::span!(perf::Level::Debug, "adapter.detect", adapter = a.name(),);
                a.detect(ctx)
            };
            if detected {
                let _capture_span =
                    perf::span!(perf::Level::Debug, "adapter.capture", adapter = a.name(),);
                match a.capture(ctx).await {
                    Ok(p) => return (p, errors),
                    Err(e) => {
                        errors.push(e);
                    }
                }
            }
        }
        (crate::model::Program::BareShell, errors)
    }
}

pub mod less;
pub mod nvim;
pub mod raw;
pub mod shell;
pub mod tmux;

pub use less::LessAdapter;
pub use nvim::NvimAdapter;
pub use raw::RawAdapter;
pub use shell::ShellAdapter;
pub use tmux::{assert_no_nul, chmod_executable, TmuxAdapter};

/// Process-wide adapter registry used by `session::save`.
///
/// Ordering matches the bash orchestrator's case arms in `emit_launch_for_window`
/// (see plan §5.7): **Nvim → Tmux → Less → Shell → Raw**. `RawAdapter` is the
/// last entry and acts as the catch-all (mirroring bash's `*` arm), so any
/// foreground program not recognised by an earlier adapter still produces a
/// reasonable `Program::Raw { argv }` snapshot.
///
/// The returned `&'static Registry` is constructed exactly once via
/// `once_cell::sync::Lazy` and lives for the remainder of the process, so
/// repeated calls hand out the same pointer. This lets `WindowCtx::registry`
/// hold a borrow without any lifetime juggling at the call sites.
#[must_use]
pub fn default_registry() -> &'static Registry {
    static REGISTRY: once_cell::sync::Lazy<Registry> = once_cell::sync::Lazy::new(|| {
        Registry::new(vec![
            Box::new(NvimAdapter::default()),
            Box::new(TmuxAdapter::default()),
            Box::new(LessAdapter),
            Box::new(ShellAdapter),
            Box::new(RawAdapter),
        ])
    });
    &REGISTRY
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kitty::ls::Window;
    use crate::model::Program;
    use pretty_assertions::assert_eq;
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::{Path, PathBuf};
    use tempfile::tempdir;

    pub(crate) fn mk_window() -> Window {
        // Minimal Window via the lenient JSON path — adapter tests only key
        // off fields that adapters actually read (none, currently), but the
        // borrow still has to be live.
        serde_json::from_value(serde_json::json!({
            "id": 1u64,
            "pid": 1234u32
        }))
        .expect("minimal window JSON parses")
    }

    pub(crate) fn write_exe(root: &Path, pid: u32, target: &str) {
        let pid_dir = root.join(pid.to_string());
        fs::create_dir_all(&pid_dir).unwrap();
        symlink(target, pid_dir.join("exe")).unwrap();
    }

    pub(crate) fn write_environ(root: &Path, pid: u32, entries: &[(&str, &str)]) {
        let pid_dir = root.join(pid.to_string());
        fs::create_dir_all(&pid_dir).unwrap();
        let mut buf = Vec::new();
        for (k, v) in entries {
            buf.extend_from_slice(k.as_bytes());
            buf.push(b'=');
            buf.extend_from_slice(v.as_bytes());
            buf.push(0);
        }
        fs::write(pid_dir.join("environ"), buf).unwrap();
    }

    pub(crate) fn write_cmdline(root: &Path, pid: u32, argv: &[&str]) {
        let pid_dir = root.join(pid.to_string());
        fs::create_dir_all(&pid_dir).unwrap();
        let mut buf = Vec::new();
        for a in argv {
            buf.extend_from_slice(a.as_bytes());
            buf.push(0);
        }
        fs::write(pid_dir.join("cmdline"), buf).unwrap();
    }

    pub(crate) fn write_fd(root: &Path, pid: u32, fd: u32, target: &str) {
        let fd_dir = root.join(pid.to_string()).join("fd");
        fs::create_dir_all(&fd_dir).unwrap();
        symlink(target, fd_dir.join(fd.to_string())).unwrap();
    }

    pub(crate) fn write_fdinfo_pos(root: &Path, pid: u32, fd: u32, pos: u64) {
        let fdinfo_dir = root.join(pid.to_string()).join("fdinfo");
        fs::create_dir_all(&fdinfo_dir).unwrap();
        fs::write(
            fdinfo_dir.join(fd.to_string()),
            format!("pos:\t{pos}\nflags:\t02\nmnt_id:\t1\n"),
        )
        .unwrap();
    }

    pub(crate) fn write_fdinfo_no_pos(root: &Path, pid: u32, fd: u32) {
        // Mimics a kernel-emitted fdinfo file that omits the `pos:` line —
        // shouldn't happen in practice, but proc::fdinfo_pos's `.unwrap_or(0)`
        // fallback should still produce a usable Less.
        let path = root
            .join(pid.to_string())
            .join("fdinfo")
            .join(fd.to_string());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"flags:\t02000000\nmnt_id:\t28\n").unwrap();
    }

    pub(crate) struct CtxFixture {
        pub tmp: tempfile::TempDir,
        pub state: tempfile::TempDir,
        pub window: Window,
        pub registry: Registry,
    }

    impl CtxFixture {
        pub fn new() -> Self {
            Self {
                tmp: tempdir().unwrap(),
                state: tempdir().unwrap(),
                window: mk_window(),
                registry: Registry::empty(),
            }
        }

        pub fn proc_root(&self) -> PathBuf {
            self.tmp.path().to_path_buf()
        }

        /// Seed `Window.user_vars` for the shell adapter's user_vars fast path
        /// (Plan §C.2 / step 5.5). Replaces any prior entries.
        pub fn with_user_vars(&mut self, vars: &[(&str, &str)]) -> &mut Self {
            self.window.user_vars = vars
                .iter()
                .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
                .collect();
            self
        }

        pub fn ctx<'a>(&'a self, fg_pid: u32, fg_exe: Option<String>) -> WindowCtx<'a> {
            WindowCtx {
                kitty_window: &self.window,
                fg_pid,
                fg_exe,
                window_root_pid: fg_pid,
                state_dir: self.state.path(),
                uid: "test-uid".into(),
                proc_root: self.tmp.path(),
                registry: &self.registry,
                tmux_control_cache: None,
            }
        }

        pub fn ctx_split<'a>(
            &'a self,
            fg_pid: u32,
            fg_exe: Option<String>,
            window_root_pid: u32,
        ) -> WindowCtx<'a> {
            WindowCtx {
                kitty_window: &self.window,
                fg_pid,
                fg_exe,
                window_root_pid,
                state_dir: self.state.path(),
                uid: "test-uid".into(),
                proc_root: self.tmp.path(),
                registry: &self.registry,
                tmux_control_cache: None,
            }
        }
    }

    // ---------- Registry dispatch ----------

    #[tokio::test]
    async fn empty_registry_yields_bare_shell() {
        let fx = CtxFixture::new();
        let ctx = fx.ctx(42, None);
        let (out, errs) = Registry::empty().capture(&ctx).await;
        assert_eq!(out, Program::BareShell);
        assert!(errs.is_empty(), "no adapters → no errors");
    }

    #[tokio::test]
    async fn less_then_raw_dispatches_to_less() {
        // Real file + matching exe → LessAdapter takes it.
        let fx = CtxFixture::new();
        let f = fx.tmp.path().join("readme.txt");
        fs::write(&f, b"hello").unwrap();
        write_exe(&fx.proc_root(), 99, "/usr/bin/less");
        write_fd(&fx.proc_root(), 99, 3, f.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 99, 3, 2);

        let reg = Registry::new(vec![Box::new(LessAdapter), Box::new(RawAdapter)]);
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 99,
            fg_exe: Some("less".into()),
            window_root_pid: 99,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let (out, errs) = reg.capture(&ctx).await;
        assert_eq!(
            out,
            Program::Less {
                file: f,
                byte_offset: 2,
                file_size: 5,
            }
        );
        assert!(
            errs.is_empty(),
            "happy-path capture must not collect errors"
        );
    }

    #[tokio::test]
    async fn less_skips_then_raw_catches_nvim() {
        // LessAdapter's detect rejects `nvim`; RawAdapter sweeps it.
        let fx = CtxFixture::new();
        write_cmdline(&fx.proc_root(), 33, &["nvim", "foo.txt"]);
        let reg = Registry::new(vec![Box::new(LessAdapter), Box::new(RawAdapter)]);
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 33,
            fg_exe: Some("nvim".into()),
            window_root_pid: 33,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let (out, _) = reg.capture(&ctx).await;
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["nvim".into(), "foo.txt".into()],
            }
        );
    }

    #[tokio::test]
    async fn less_no_eligible_fd_returns_raw_basename() {
        // Less matched by detect but found nothing scan-worthy → its OWN
        // internal fallback is Program::Raw { argv: ["less"] }. Critically:
        // because that's an Ok return, RawAdapter is never consulted.
        let fx = CtxFixture::new();
        // Only fd targets are excluded paths.
        write_fd(&fx.proc_root(), 50, 0, "/dev/pts/0");
        write_fd(&fx.proc_root(), 50, 1, "/dev/pts/0");

        let reg = Registry::new(vec![Box::new(LessAdapter), Box::new(RawAdapter)]);
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 50,
            fg_exe: Some("less".into()),
            window_root_pid: 50,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let (out, _) = reg.capture(&ctx).await;
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["less".into()],
            }
        );
    }

    // ---------- Registry: adapter Err must NOT short-circuit the chain ----------

    struct BoomAdapter;

    #[async_trait::async_trait]
    impl Adapter for BoomAdapter {
        fn name(&self) -> &'static str {
            "boom"
        }
        fn detect(&self, _ctx: &WindowCtx<'_>) -> bool {
            true
        }
        async fn capture(&self, _ctx: &WindowCtx<'_>) -> Result<Program, AdapterError> {
            Err(AdapterError::NoCmdline { pid: 0 })
        }
    }

    #[tokio::test]
    async fn registry_adapter_err_falls_through_to_bare_shell() {
        // Sole adapter errs → nothing else registered → BareShell. The
        // failing adapter's error is surfaced in the returned vec so the
        // orchestrator can degrade-and-warn per ADR 0001 (previously this
        // case would have aborted with `KError::PartialCapture` above the
        // threshold; we now report and continue).
        let fx = CtxFixture::new();
        let reg = Registry::new(vec![Box::new(BoomAdapter)]);
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 12,
            fg_exe: Some("anything".into()),
            window_root_pid: 12,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let (out, errs) = reg.capture(&ctx).await;
        assert_eq!(out, Program::BareShell);
        assert_eq!(
            errs.len(),
            1,
            "exactly one error collected from BoomAdapter"
        );
        assert!(matches!(errs[0], AdapterError::NoCmdline { .. }));
    }

    #[tokio::test]
    async fn registry_adapter_err_falls_through_to_next_adapter() {
        // Boom errs → Raw still gets a shot and succeeds.
        let fx = CtxFixture::new();
        write_cmdline(&fx.proc_root(), 13, &["btop", "--utf-force"]);
        let reg = Registry::new(vec![Box::new(BoomAdapter), Box::new(RawAdapter)]);
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 13,
            fg_exe: Some("btop".into()),
            window_root_pid: 13,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let (out, errs) = reg.capture(&ctx).await;
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["btop".into(), "--utf-force".into()],
            }
        );
        // Successful Raw capture wins; the Boom failure is still recorded so
        // the orchestrator can flag the window as degraded (ADR 0001).
        assert_eq!(errs.len(), 1, "earlier failure preserved alongside Ok");
    }

    // ---------- default_registry: process-wide singleton ----------

    #[test]
    fn default_registry_is_singleton() {
        let a = default_registry() as *const _;
        let b = default_registry() as *const _;
        assert_eq!(a, b, "default_registry must return the same instance");
    }

    // ---------- Registry: detect()=false also falls through cleanly ----------

    #[tokio::test]
    async fn registry_no_detect_falls_through_to_next_adapter() {
        // ShellAdapter rejects (fg_exe = Some) → RawAdapter takes it.
        let fx = CtxFixture::new();
        write_cmdline(&fx.proc_root(), 14, &["btop", "--utf-force"]);
        let reg = Registry::new(vec![Box::new(ShellAdapter), Box::new(RawAdapter)]);
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 14,
            fg_exe: Some("btop".into()),
            window_root_pid: 14,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let (out, _) = reg.capture(&ctx).await;
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["btop".into(), "--utf-force".into()],
            }
        );
    }
}
