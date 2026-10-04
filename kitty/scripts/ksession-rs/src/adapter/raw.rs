//! Catch-all adapter that records the foreground process's argv verbatim.
//!
//! Mirrors the `*)` arm of `emit_launch_for_window` (ksession.sh:580-582).
//! Bash reads `foreground_processes[-1].cmdline` out of the kitty `ls` JSON;
//! we read `/proc/<fg_pid>/cmdline` directly — same data, fresher, and not
//! reliant on transporting it through `WindowCtx`. Must be registered LAST
//! in the chain; its `detect` is unconditionally true so anything still
//! reaching it gets captured.
//!
//! One normalisation: a bare `argv[0]` (no `/`) that the window's own PATH
//! cannot resolve is replaced with the `/proc/<fg_pid>/exe` target. This is
//! the `#!/usr/bin/env bun` case — the kernel execs `bun /path/omp` with
//! argv[0] literally `bun`, found only via the *interactive* shell's PATH
//! (`~/.bun/bin` from .bashrc). Restores run under kitty's GUI PATH or the
//! restoring overlay's PATH, neither of which has it, so the launch dies with
//! `exec: "bun": executable file not found in $PATH`. Recording the absolute
//! exe makes the launch line self-sufficient. argv[0]s the window PATH does
//! resolve are left untouched so venv/conda shims keep their identity.

use async_trait::async_trait;

use super::{Adapter, AdapterError, WindowCtx};
use crate::model::Program;
use crate::proc;

#[derive(Default)]
pub struct RawAdapter;

#[async_trait]
impl Adapter for RawAdapter {
    fn name(&self) -> &'static str {
        "raw"
    }

    fn detect(&self, _ctx: &WindowCtx<'_>) -> bool {
        // Catch-all. Must be registered last; orchestrator routes
        // shell/less/nvim/tmux first per ksession.sh:567-583 case arms.
        true
    }

    async fn capture(&self, ctx: &WindowCtx<'_>) -> Result<Program, AdapterError> {
        match proc::cmdline(ctx.proc_root, ctx.fg_pid) {
            None => Err(AdapterError::NoCmdline { pid: ctx.fg_pid }),
            // Empty cmdline file (kernel thread) is indistinguishable from
            // "nothing useful" for our purposes — bash's :584 fallback
            // (`(( ${#cmd_argv[@]} == 0 ))`) replaces it with /bin/bash -l
            // upstream; registry handles that by routing us to BareShell.
            Some(argv) if argv.is_empty() => Err(AdapterError::NoCmdline { pid: ctx.fg_pid }),
            Some(mut argv) => {
                if let Some(abs) = absolute_argv0(ctx, &argv[0]) {
                    argv[0] = abs;
                }
                Ok(Program::Raw { argv })
            }
        }
    }
}

/// `Some(abs_path)` when `argv0` is bare, the window's PATH has no executable
/// of that name, and `/proc/<fg_pid>/exe` names a live file with that
/// basename. Any missing piece (no PATH in the window env, no exe link, name
/// mismatch) means "leave it alone".
fn absolute_argv0(ctx: &WindowCtx<'_>, argv0: &str) -> Option<String> {
    if argv0.contains('/') {
        return None;
    }
    let path = ctx.kitty_window.env.get("PATH")?;
    let resolvable = path
        .split(':')
        .filter(|d| !d.is_empty())
        .any(|d| std::path::Path::new(d).join(argv0).is_file());
    if resolvable {
        return None;
    }
    let exe = proc::exe_path(ctx.proc_root, ctx.fg_pid)?;
    if exe.file_name()?.to_str()? != argv0 {
        return None;
    }
    Some(exe.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapter::tests::{write_cmdline, write_exe, CtxFixture};
    use pretty_assertions::assert_eq;

    // ---------- detect ----------

    #[test]
    fn detect_always_true() {
        let fx = CtxFixture::new();
        assert!(RawAdapter.detect(&fx.ctx(1, None)));
        assert!(RawAdapter.detect(&fx.ctx(1, Some("less".into()))));
        assert!(RawAdapter.detect(&fx.ctx(1, Some("anything".into()))));
        assert!(RawAdapter.detect(&fx.ctx(1, Some("".into()))));
    }

    // ---------- capture: happy path ----------

    #[tokio::test]
    async fn capture_normal_argv() {
        let fx = CtxFixture::new();
        write_cmdline(&fx.proc_root(), 100, &["btop", "--utf-force"]);
        let p = RawAdapter
            .capture(&fx.ctx(100, Some("btop".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["btop".into(), "--utf-force".into()],
            }
        );
    }

    #[tokio::test]
    async fn capture_preserves_argv_with_spaces() {
        // /proc/PID/cmdline is NUL-separated so embedded spaces survive the
        // round-trip; no bash-style word splitting.
        let fx = CtxFixture::new();
        write_cmdline(&fx.proc_root(), 101, &["vi", "my file"]);
        let p = RawAdapter
            .capture(&fx.ctx(101, Some("vi".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["vi".into(), "my file".into()],
            }
        );
    }

    // ---------- capture: error paths ----------

    #[tokio::test]
    async fn capture_empty_cmdline_errors() {
        let fx = CtxFixture::new();
        // Write empty cmdline file (kernel thread).
        let pid_dir = fx.proc_root().join("102");
        std::fs::create_dir_all(&pid_dir).unwrap();
        std::fs::write(pid_dir.join("cmdline"), b"").unwrap();
        let err = RawAdapter
            .capture(&fx.ctx(102, Some("kthread".into())))
            .await
            .unwrap_err();
        assert!(matches!(err, AdapterError::NoCmdline { pid: 102 }));
    }

    #[tokio::test]
    async fn capture_missing_proc_dir_errors() {
        let fx = CtxFixture::new();
        // No /proc/103 at all.
        let err = RawAdapter
            .capture(&fx.ctx(103, Some("ghost".into())))
            .await
            .unwrap_err();
        assert!(matches!(err, AdapterError::NoCmdline { pid: 103 }));
    }

    #[tokio::test]
    async fn capture_setproctitle_padding_yields_clean_argv() {
        // Programs that rewrite argv for the process title (pi/omp/claude)
        // leave a run of trailing NULs in /proc/PID/cmdline. The capture
        // must yield just the real elements — no empty-string args.
        let fx = CtxFixture::new();
        let pid_dir = fx.proc_root().join("105");
        std::fs::create_dir_all(&pid_dir).unwrap();
        std::fs::write(pid_dir.join("cmdline"), b"pi\0\0\0\0\0\0\0\0").unwrap();
        let p = RawAdapter
            .capture(&fx.ctx(105, Some("pi".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["pi".into()],
            }
        );
    }

    #[tokio::test]
    async fn capture_all_nul_cmdline_degrades_like_missing() {
        // A cmdline of pure NULs trims to an empty argv — per ADR 0001
        // ("partial capture degrades instead of aborting") the adapter
        // must degrade exactly like an unreadable cmdline, so the
        // registry routes the window to BareShell.
        let fx = CtxFixture::new();
        let pid_dir = fx.proc_root().join("106");
        std::fs::create_dir_all(&pid_dir).unwrap();
        std::fs::write(pid_dir.join("cmdline"), b"\0\0\0\0").unwrap();
        let err = RawAdapter
            .capture(&fx.ctx(106, Some("mystery".into())))
            .await
            .unwrap_err();
        assert!(matches!(err, AdapterError::NoCmdline { pid: 106 }));
    }

    #[tokio::test]
    async fn capture_single_arg() {
        let fx = CtxFixture::new();
        write_cmdline(&fx.proc_root(), 104, &["htop"]);
        let p = RawAdapter
            .capture(&fx.ctx(104, Some("htop".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["htop".into()],
            }
        );
    }

    // ---------- capture: bare argv[0] outside the window PATH ----------

    /// Lay out a fake `bin/<name>` executable under the fixture tmp dir and
    /// point `/proc/<pid>/exe` at it. Returns the bin dir and exe path.
    fn fake_exe(fx: &CtxFixture, pid: u32, dir: &str, name: &str) -> (String, String) {
        let bin = fx.tmp.path().join(dir);
        std::fs::create_dir_all(&bin).unwrap();
        let exe = bin.join(name);
        std::fs::write(&exe, b"#!/bin/sh\n").unwrap();
        write_exe(&fx.proc_root(), pid, exe.to_str().unwrap());
        (
            bin.to_string_lossy().into_owned(),
            exe.to_string_lossy().into_owned(),
        )
    }

    #[tokio::test]
    async fn capture_absolutizes_argv0_missing_from_window_path() {
        // `#!/usr/bin/env bun` script: cmdline is `bun /abs/omp`, exe is
        // ~/.bun/bin/bun, and the window's PATH (kitty GUI PATH) lacks it.
        let mut fx = CtxFixture::new();
        let (_, exe) = fake_exe(&fx, 200, "bunbin", "bun");
        let (other, _) = fake_exe(&fx, 201, "usrbin", "unrelated");
        fx.window.env.insert("PATH".into(), other);
        write_cmdline(&fx.proc_root(), 200, &["bun", "/home/u/.bun/bin/omp"]);
        let p = RawAdapter
            .capture(&fx.ctx(200, Some("bun".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec![exe, "/home/u/.bun/bin/omp".into()],
            }
        );
    }

    #[tokio::test]
    async fn capture_keeps_bare_argv0_resolvable_on_window_path() {
        // venv/conda shims: PATH resolves the name, so identity is preserved.
        let mut fx = CtxFixture::new();
        let (bin, _) = fake_exe(&fx, 202, "venvbin", "python");
        fx.window
            .env
            .insert("PATH".into(), format!("/nonexistent:{bin}"));
        write_cmdline(&fx.proc_root(), 202, &["python", "app.py"]);
        let p = RawAdapter
            .capture(&fx.ctx(202, Some("python".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["python".into(), "app.py".into()],
            }
        );
    }

    #[tokio::test]
    async fn capture_leaves_argv0_when_exe_basename_differs() {
        // argv[0] rewritten by the program (setproctitle) — exe is `bun` but
        // argv[0] says `omp`; substituting would misname the launch.
        let mut fx = CtxFixture::new();
        fake_exe(&fx, 203, "bunbin", "bun");
        fx.window.env.insert("PATH".into(), "/nonexistent".into());
        write_cmdline(&fx.proc_root(), 203, &["omp"]);
        let p = RawAdapter
            .capture(&fx.ctx(203, Some("bun".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["omp".into()],
            }
        );
    }

    #[tokio::test]
    async fn capture_leaves_argv0_without_window_path() {
        // No PATH in the window env (fixture default): can't judge, don't touch.
        let fx = CtxFixture::new();
        fake_exe(&fx, 204, "bunbin", "bun");
        write_cmdline(&fx.proc_root(), 204, &["bun", "x.js"]);
        let p = RawAdapter
            .capture(&fx.ctx(204, Some("bun".into())))
            .await
            .unwrap();
        assert_eq!(
            p,
            Program::Raw {
                argv: vec!["bun".into(), "x.js".into()],
            }
        );
    }
}
