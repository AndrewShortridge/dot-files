//! Shell-only window adapter.
//!
//! Mirrors `capture_shell_window` (ksession.sh:486-511). Triggered when the
//! orchestrator has determined the foreground is a plain interactive shell
//! with no notable descendant (`ctx.fg_exe == None`). Reads the window's root
//! process env + exe to recover venv/conda/oldpwd/direnv hints; falls back to
//! `Program::Shell { shell: Bash, .. all None }` on any missing piece. Never
//! errors: bash's reference is also infallible.

use std::path::PathBuf;

use async_trait::async_trait;

use super::{Adapter, AdapterError, WindowCtx};
use crate::model::{Program, ShellKind};
use crate::proc;

#[derive(Default)]
pub struct ShellAdapter;

#[async_trait]
impl Adapter for ShellAdapter {
    fn name(&self) -> &'static str {
        "shell"
    }

    fn detect(&self, ctx: &WindowCtx<'_>) -> bool {
        // Orchestrator (step 8) is responsible for normalising fg_exe to None
        // when the descendant scan finds nothing interactive. So all we check
        // here is the marker itself — see ksession.sh:577 ("") arm.
        ctx.fg_exe.is_none()
    }

    async fn capture(&self, ctx: &WindowCtx<'_>) -> Result<Program, AdapterError> {
        // ksession.sh:578 — capture_shell_window is invoked with $w_pid (the
        // window root), NOT the foreground pid. The shell's env is what we
        // want for venv/conda/oldpwd inspection.
        let pid = ctx.window_root_pid;
        let root = ctx.proc_root;

        let shell = match proc::exe_base(root, pid) {
            Some(name) => parse_shell_kind(&name),
            None => ShellKind::Bash, // ksession.sh:492 default
        };

        let venv = lookup_env(ctx, "ksession_venv", "VIRTUAL_ENV").and_then(|v| {
            // ksession.sh:496 — only emit when `$venv/bin/activate` exists.
            if v.is_empty() {
                return None;
            }
            let p = PathBuf::from(&v);
            if p.join("bin").join("activate").is_file() {
                Some(p)
            } else {
                None
            }
        });

        let conda = lookup_env(ctx, "ksession_conda", "CONDA_DEFAULT_ENV").and_then(|c| {
            // ksession.sh:499 — non-empty AND not "base".
            if c.is_empty() || c == "base" {
                None
            } else {
                Some(c)
            }
        });

        let direnv = lookup_env(ctx, "ksession_direnv", "DIRENV_DIR").and_then(|d| {
            if d.is_empty() {
                None
            } else {
                Some(PathBuf::from(d))
            }
        });

        let oldpwd = lookup_env(ctx, "ksession_oldpwd", "OLDPWD").and_then(|o| {
            // ksession.sh:503 — only `[[ -n "$oldpwd" ]]`; no further check.
            if o.is_empty() {
                None
            } else {
                Some(PathBuf::from(o))
            }
        });

        // Copy per-window shell history from the shell hook's live-write
        // location (~/.cache/ksession/hist/<kitty_window_id>) into the
        // session state directory so the session file is self-contained.
        let hist_source = PathBuf::from(format!(
            "{}/.cache/ksession/hist/{}",
            std::env::var("HOME").unwrap_or_default(),
            ctx.kitty_window.id
        ));
        let history = if hist_source.is_file() {
            let _span = crate::perf::span!(
                crate::perf::Level::Debug,
                "save.capture.history_copy",
                win_id = ctx.kitty_window.id,
                hist_bytes = std::fs::metadata(&hist_source)
                    .map(|m| m.len())
                    .unwrap_or(0),
            );
            let hist_dir = ctx.state_dir.join("history");
            std::fs::create_dir_all(&hist_dir).ok();
            let dest = hist_dir.join(format!("{}.hist", ctx.uid));
            match std::fs::copy(&hist_source, &dest) {
                Ok(_) => Some(dest),
                Err(_) => None,
            }
        } else {
            None
        };

        Ok(Program::Shell {
            shell,
            venv,
            conda,
            direnv,
            oldpwd,
            scrollback: None,
            history,
        })
    }
}

// Step 5.5 (Plan §C.2): prefer the kitty `user_vars` fast path over /proc.
// The OSC 1337 `SetUserVar=<key>=<base64(value)>` payload is decoded by kitty
// itself before being exposed on `Window.user_vars` (verified against the live
// `@ ls` fixtures at tests/fixtures/kitty-ls/, where values are plain UTF-8
// like "hello" / "50" rather than base64), so no decode step is needed here.
// An explicitly-empty user_var (the hook emits `ksession_venv=""` when the
// user isn't in a venv) returns Some("") and is filtered by the downstream
// is_empty() checks at each call site — we intentionally do NOT collapse
// empty → fallback here, since that would conflate "hook says explicitly
// empty" with "hook isn't sourced". The /proc path is only consulted when
// the key is absent altogether.
fn lookup_env(ctx: &WindowCtx<'_>, user_var: &str, env_key: &str) -> Option<String> {
    if let Some(v) = ctx.kitty_window.user_vars.get(user_var) {
        return Some(v.clone());
    }
    crate::proc::env_var(ctx.proc_root, ctx.window_root_pid, env_key)
}

/// Map an exe basename to a `ShellKind`. Unknown → `Bash` per ksession.sh:493.
#[must_use]
fn parse_shell_kind(name: &str) -> ShellKind {
    match name {
        "bash" => ShellKind::Bash,
        "zsh" => ShellKind::Zsh,
        "fish" => ShellKind::Fish,
        "dash" => ShellKind::Dash,
        "sh" => ShellKind::Sh,
        // ash: included to match the inclusive set at ksession.sh:253; bash:493
        // omits but recognising ash here is strictly better than mis-classifying.
        "ash" => ShellKind::Ash,
        _ => ShellKind::Bash,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapter::tests::{write_environ, write_exe, CtxFixture};
    use pretty_assertions::assert_eq;
    use std::fs;
    use std::path::Path;

    // ---------- detect ----------

    #[tokio::test]
    async fn detect_true_when_fg_exe_none() {
        let fx = CtxFixture::new();
        assert!(ShellAdapter.detect(&fx.ctx(100, None)));
    }

    #[tokio::test]
    async fn detect_false_when_fg_exe_some() {
        let fx = CtxFixture::new();
        assert!(!ShellAdapter.detect(&fx.ctx(100, Some("less".into()))));
    }

    // ---------- exe → ShellKind ----------

    #[test]
    fn parse_shell_kind_known() {
        assert_eq!(parse_shell_kind("bash"), ShellKind::Bash);
        assert_eq!(parse_shell_kind("zsh"), ShellKind::Zsh);
        assert_eq!(parse_shell_kind("fish"), ShellKind::Fish);
        assert_eq!(parse_shell_kind("dash"), ShellKind::Dash);
        assert_eq!(parse_shell_kind("sh"), ShellKind::Sh);
        assert_eq!(parse_shell_kind("ash"), ShellKind::Ash);
    }

    #[test]
    fn parse_shell_kind_unknown_defaults_bash() {
        assert_eq!(parse_shell_kind("nu"), ShellKind::Bash);
        assert_eq!(parse_shell_kind(""), ShellKind::Bash);
        assert_eq!(parse_shell_kind("BASH"), ShellKind::Bash); // case-sensitive
    }

    // ---------- capture: defaults ----------

    #[tokio::test]
    async fn capture_no_exe_no_env_yields_bash_all_none() {
        let fx = CtxFixture::new();
        let ctx = fx.ctx(100, None);
        let p = ShellAdapter.capture(&ctx).await.unwrap();
        assert_eq!(
            p,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: None,
                history: None,
            }
        );
    }

    // ---------- capture: per-shell exe detection ----------

    #[tokio::test]
    async fn capture_integrates_exe_base_with_shell_kind_mapping() {
        // Smoke test: proves `exe_base` → `parse_shell_kind` wiring works.
        // The full known/unknown mapping is exhaustively covered by the
        // `parse_shell_kind_*` unit tests; here we only need one known and
        // one unknown case to pin the integration.
        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 200, "/usr/bin/zsh");
        let p = ShellAdapter.capture(&fx.ctx(200, None)).await.unwrap();
        match p {
            Program::Shell { shell, .. } => assert_eq!(shell, ShellKind::Zsh),
            other => panic!("expected Program::Shell, got {other:?}"),
        }

        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 201, "/usr/bin/unknown_shell_name");
        let p = ShellAdapter.capture(&fx.ctx(201, None)).await.unwrap();
        match p {
            Program::Shell { shell, .. } => assert_eq!(shell, ShellKind::Bash),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    // ---------- venv normalisation ----------

    #[tokio::test]
    async fn venv_without_activate_returns_none() {
        let fx = CtxFixture::new();
        let dir = fx.tmp.path().join("venv-no-activate");
        fs::create_dir_all(&dir).unwrap();
        write_environ(
            &fx.proc_root(),
            300,
            &[("VIRTUAL_ENV", dir.to_str().unwrap())],
        );
        let p = ShellAdapter.capture(&fx.ctx(300, None)).await.unwrap();
        assert!(matches!(p, Program::Shell { venv: None, .. }));
    }

    #[tokio::test]
    async fn venv_with_activate_returns_some() {
        let fx = CtxFixture::new();
        let dir = fx.tmp.path().join("real-venv");
        fs::create_dir_all(dir.join("bin")).unwrap();
        fs::write(dir.join("bin").join("activate"), b"# stub").unwrap();
        write_environ(
            &fx.proc_root(),
            301,
            &[("VIRTUAL_ENV", dir.to_str().unwrap())],
        );
        let p = ShellAdapter.capture(&fx.ctx(301, None)).await.unwrap();
        match p {
            Program::Shell { venv, .. } => assert_eq!(venv, Some(dir)),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn venv_empty_returns_none() {
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 302, &[("VIRTUAL_ENV", "")]);
        let p = ShellAdapter.capture(&fx.ctx(302, None)).await.unwrap();
        assert!(matches!(p, Program::Shell { venv: None, .. }));
    }

    // ---------- conda normalisation ----------

    #[tokio::test]
    async fn conda_base_returns_none() {
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 400, &[("CONDA_DEFAULT_ENV", "base")]);
        let p = ShellAdapter.capture(&fx.ctx(400, None)).await.unwrap();
        assert!(matches!(p, Program::Shell { conda: None, .. }));
    }

    #[tokio::test]
    async fn conda_named_env_returns_some() {
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 401, &[("CONDA_DEFAULT_ENV", "myenv")]);
        let p = ShellAdapter.capture(&fx.ctx(401, None)).await.unwrap();
        match p {
            Program::Shell { conda, .. } => assert_eq!(conda, Some("myenv".into())),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    // ---------- oldpwd / direnv ----------

    #[tokio::test]
    async fn oldpwd_empty_returns_none() {
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 500, &[("OLDPWD", "")]);
        let p = ShellAdapter.capture(&fx.ctx(500, None)).await.unwrap();
        assert!(matches!(p, Program::Shell { oldpwd: None, .. }));
    }

    #[tokio::test]
    async fn oldpwd_set_returns_some() {
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 501, &[("OLDPWD", "/tmp")]);
        let p = ShellAdapter.capture(&fx.ctx(501, None)).await.unwrap();
        match p {
            Program::Shell { oldpwd, .. } => assert_eq!(oldpwd, Some(PathBuf::from("/tmp"))),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn direnv_set_returns_some() {
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 600, &[("DIRENV_DIR", "/proj")]);
        let p = ShellAdapter.capture(&fx.ctx(600, None)).await.unwrap();
        match p {
            Program::Shell { direnv, .. } => assert_eq!(direnv, Some(PathBuf::from("/proj"))),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn direnv_empty_returns_none() {
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 601, &[("DIRENV_DIR", "")]);
        let p = ShellAdapter.capture(&fx.ctx(601, None)).await.unwrap();
        assert!(matches!(p, Program::Shell { direnv: None, .. }));
    }

    // ---------- window_root_pid is the source, not fg_pid ----------

    #[tokio::test]
    async fn capture_keys_off_window_root_pid_not_fg_pid() {
        // Per ksession.sh:578. Plant DIFFERENT data on both pids so success
        // requires actually reading window_root_pid, not just "fg_pid happens
        // to be missing".
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 700, &[("OLDPWD", "/tmp/from_root")]);
        write_exe(&fx.proc_root(), 700, "/usr/bin/zsh");
        // fg_pid carries decoy data — adapter must NOT see it.
        write_environ(&fx.proc_root(), 701, &[("OLDPWD", "/tmp/from_fg")]);
        write_exe(&fx.proc_root(), 701, "/usr/bin/fish");

        let ctx = fx.ctx_split(701, None, 700);
        let p = ShellAdapter.capture(&ctx).await.unwrap();
        assert_eq!(
            p,
            Program::Shell {
                shell: ShellKind::Zsh,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: Some(PathBuf::from("/tmp/from_root")),
                scrollback: None,
                history: None,
            }
        );
    }

    // ---------- venv: bin/activate is a directory, not a regular file ----------

    #[tokio::test]
    async fn venv_with_activate_directory_returns_none() {
        // bash:496 uses `-f`, which is false for directories. Create
        // <venv>/bin/activate as a DIR — adapter must reject.
        let fx = CtxFixture::new();
        let dir = fx.tmp.path().join("dir-activate-venv");
        fs::create_dir_all(dir.join("bin").join("activate")).unwrap();
        write_environ(
            &fx.proc_root(),
            310,
            &[("VIRTUAL_ENV", dir.to_str().unwrap())],
        );
        let p = ShellAdapter.capture(&fx.ctx(310, None)).await.unwrap();
        assert!(matches!(p, Program::Shell { venv: None, .. }));
    }

    // ---------- env: key absent from a populated environ ----------

    #[tokio::test]
    async fn capture_environ_present_but_keys_absent_yields_all_none() {
        // Distinct from "no environ file" branch: environ EXISTS, parses, but
        // doesn't include any of our four shell keys. parse_environ returns
        // Some(map); map.get(key) returns None for each.
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 320, &[("PATH", "/usr/bin")]);
        let p = ShellAdapter.capture(&fx.ctx(320, None)).await.unwrap();
        assert_eq!(
            p,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: None,
                conda: None,
                direnv: None,
                oldpwd: None,
                scrollback: None,
                history: None,
            }
        );
    }

    // ---------- conda: case-sensitive vs bash's literal "base" ----------

    #[tokio::test]
    async fn conda_capitalised_base_is_kept() {
        // bash:499 compares to literal lowercase "base". `Base` (capital B)
        // is a legitimate env name — must survive. Pin so nobody silently
        // lowercases.
        let fx = CtxFixture::new();
        write_environ(&fx.proc_root(), 410, &[("CONDA_DEFAULT_ENV", "Base")]);
        let p = ShellAdapter.capture(&fx.ctx(410, None)).await.unwrap();
        match p {
            Program::Shell { conda, .. } => assert_eq!(conda, Some("Base".to_string())),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    // ---------- step 5.5 (Plan §C.2): user_vars fast path ----------
    //
    // Kitty decodes `OSC 1337 SetUserVar=<key>=<base64(value)>` on receipt and
    // exposes the literal value via `@ ls` (verified by inspecting the live
    // fixtures at tests/fixtures/kitty-ls/{live-4726,live-68204}.json, where
    // values like "hello" / "50" appear as plain UTF-8 rather than base64).
    // Therefore these tests pass plain strings, not base64.

    #[tokio::test]
    async fn user_var_venv_hit_bypasses_proc() {
        // Fast path: ksession_venv present in user_vars; /proc/<pid>/environ
        // intentionally absent. Adapter must read from kitty, not /proc.
        let mut fx = CtxFixture::new();
        let dir = fx.tmp.path().join("uv-venv");
        fs::create_dir_all(dir.join("bin")).unwrap();
        fs::write(dir.join("bin").join("activate"), b"# stub").unwrap();
        fx.with_user_vars(&[("ksession_venv", dir.to_str().unwrap())]);
        // NO write_environ — proves the fast path doesn't fall through.
        let p = ShellAdapter.capture(&fx.ctx(800, None)).await.unwrap();
        match p {
            Program::Shell { venv, .. } => assert_eq!(venv, Some(dir)),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn user_var_conda_hit_bypasses_proc() {
        let mut fx = CtxFixture::new();
        fx.with_user_vars(&[("ksession_conda", "myenv")]);
        let p = ShellAdapter.capture(&fx.ctx(801, None)).await.unwrap();
        match p {
            Program::Shell { conda, .. } => assert_eq!(conda, Some("myenv".into())),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn user_var_empty_does_not_fall_through_to_proc() {
        // Pins the "explicitly empty" semantics: the hook emits an empty
        // ksession_oldpwd when OLDPWD is unset, and we must treat that as
        // "definitively unset" — NOT as "missing, try /proc". If we accidentally
        // fell back to /proc, the OLDPWD planted there would surface and this
        // assertion would fail. Critical: protects against a regression where
        // someone "helpfully" collapses empty → None inside lookup_env.
        let mut fx = CtxFixture::new();
        fx.with_user_vars(&[("ksession_oldpwd", "")]);
        write_environ(&fx.proc_root(), 802, &[("OLDPWD", "/from_proc")]);
        let p = ShellAdapter.capture(&fx.ctx(802, None)).await.unwrap();
        assert!(matches!(p, Program::Shell { oldpwd: None, .. }));
    }

    #[tokio::test]
    async fn user_var_absent_falls_through_to_proc() {
        // No ksession_* keys at all → /proc is consulted as before.
        let fx = CtxFixture::new();
        let dir = fx.tmp.path().join("proc-venv");
        fs::create_dir_all(dir.join("bin")).unwrap();
        fs::write(dir.join("bin").join("activate"), b"# stub").unwrap();
        write_environ(
            &fx.proc_root(),
            803,
            &[("VIRTUAL_ENV", dir.to_str().unwrap())],
        );
        let p = ShellAdapter.capture(&fx.ctx(803, None)).await.unwrap();
        match p {
            Program::Shell { venv, .. } => assert_eq!(venv, Some(dir)),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn user_var_mixed_per_key_independence() {
        // Per-key wiring: ksession_venv from user_vars, ksession_conda absent so
        // CONDA_DEFAULT_ENV from /proc takes over. Proves the helper's
        // user_var/env_key pairing is independent at each call site.
        let mut fx = CtxFixture::new();
        let dir = fx.tmp.path().join("mixed-venv");
        fs::create_dir_all(dir.join("bin")).unwrap();
        fs::write(dir.join("bin").join("activate"), b"# stub").unwrap();
        fx.with_user_vars(&[("ksession_venv", dir.to_str().unwrap())]);
        write_environ(&fx.proc_root(), 804, &[("CONDA_DEFAULT_ENV", "projX")]);
        let p = ShellAdapter.capture(&fx.ctx(804, None)).await.unwrap();
        match p {
            Program::Shell { venv, conda, .. } => {
                assert_eq!(venv, Some(dir));
                assert_eq!(conda, Some("projX".into()));
            }
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn user_var_all_four_keys_route_correctly() {
        // Pins the per-call-site user_var key mapping:
        //   venv   ← ksession_venv     (line 46)
        //   conda  ← ksession_conda    (line 59)
        //   direnv ← ksession_direnv   (line 68)
        //   oldpwd ← ksession_oldpwd   (line 76)
        // Regression net: if anyone shuffles the string args between call
        // sites, exactly one assertion below fails per swap.
        let mut fx = CtxFixture::new();
        let venv_dir = fx.tmp.path().join("all4-venv");
        fs::create_dir_all(venv_dir.join("bin")).unwrap();
        fs::write(venv_dir.join("bin").join("activate"), b"# stub").unwrap();
        fx.with_user_vars(&[
            ("ksession_venv", venv_dir.to_str().unwrap()),
            ("ksession_conda", "myenv"),
            ("ksession_direnv", "/proj/.envrc.dir"),
            ("ksession_oldpwd", "/prev/dir"),
        ]);
        let p = ShellAdapter.capture(&fx.ctx(805, None)).await.unwrap();
        assert_eq!(
            p,
            Program::Shell {
                shell: ShellKind::Bash,
                venv: Some(venv_dir),
                conda: Some("myenv".into()),
                direnv: Some(PathBuf::from("/proj/.envrc.dir")),
                oldpwd: Some(PathBuf::from("/prev/dir")),
                scrollback: None,
                history: None,
            }
        );
    }

    #[tokio::test]
    async fn user_var_receives_post_decode_plain_utf8() {
        // Anchor for the decoding-ownership assumption (Plan §C.2 lines 1303-
        // 1382). The OSC 1337 wire format is `SetUserVar=<key>=<base64(val)>`
        // but kitty decodes before exposing on Window.user_vars — see live
        // fixtures at tests/fixtures/kitty-ls/live-{4726,68204}.json where
        // `user_vars` values are plain UTF-8 ("hello", "50", "1", "7"), not
        // base64. If this assertion ever breaks because we receive base64,
        // kitty's behavior changed and the helper needs to decode.
        let mut fx = CtxFixture::new();
        // Value contains characters that are not in the RFC 4648 base64
        // alphabet ('~' and '!'; note '/' IS valid base64 — index 63 — so it
        // alone would not anchor the assumption). If anyone tried to decode
        // this as base64 it would fail to round-trip.
        fx.with_user_vars(&[("ksession_conda", "env~with/slash!")]);
        let p = ShellAdapter.capture(&fx.ctx(806, None)).await.unwrap();
        match p {
            Program::Shell { conda, .. } => assert_eq!(conda, Some("env~with/slash!".into())),
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    // ---------- history file copy ----------

    static HOME_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

    const HIST_WIN_ID: u64 = 99999;

    fn hist_fixture() -> CtxFixture {
        let mut fx = CtxFixture::new();
        fx.window.id = HIST_WIN_ID;
        fx
    }

    struct HomeGuard {
        prev: Option<String>,
    }

    impl HomeGuard {
        fn set(home: &Path) -> Self {
            let prev = std::env::var("HOME").ok();
            unsafe { std::env::set_var("HOME", home) };
            Self { prev }
        }
    }

    impl Drop for HomeGuard {
        fn drop(&mut self) {
            match &self.prev {
                Some(v) => unsafe { std::env::set_var("HOME", v) },
                None => unsafe { std::env::remove_var("HOME") },
            }
        }
    }

    #[tokio::test]
    async fn history_file_exists_is_copied() {
        let _lock = HOME_MUTEX.lock().unwrap();
        let fx = hist_fixture();

        let fake_home = fx.tmp.path().join("fakehome");
        let hist_dir = fake_home.join(".cache/ksession/hist");
        fs::create_dir_all(&hist_dir).unwrap();
        fs::write(
            hist_dir.join(HIST_WIN_ID.to_string()),
            b"echo hello\nls -la\n",
        )
        .unwrap();

        let _guard = HomeGuard::set(&fake_home);
        let ctx = fx.ctx(900, None);
        let p = ShellAdapter.capture(&ctx).await.unwrap();
        match p {
            Program::Shell { history, .. } => {
                let dest = history.expect("history should be Some when source file exists");
                assert!(dest.exists(), "destination file must exist after copy");
                assert_eq!(
                    fs::read_to_string(&dest).unwrap(),
                    "echo hello\nls -la\n",
                    "copied content must match source"
                );
                // Destination should be in state_dir/history/<uid>.hist
                assert!(dest.ends_with("test-uid.hist"));
            }
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn history_file_missing_yields_none() {
        let _lock = HOME_MUTEX.lock().unwrap();
        let fx = hist_fixture();
        // Point HOME to a dir that has NO .cache/ksession/hist/<id> file.
        let fake_home = fx.tmp.path().join("empty-home");
        fs::create_dir_all(&fake_home).unwrap();

        let _guard = HomeGuard::set(&fake_home);
        let ctx = fx.ctx(901, None);
        let p = ShellAdapter.capture(&ctx).await.unwrap();
        assert!(matches!(p, Program::Shell { history: None, .. }));
    }

    #[tokio::test]
    async fn history_file_empty_is_still_copied() {
        let _lock = HOME_MUTEX.lock().unwrap();
        let fx = hist_fixture();

        let fake_home = fx.tmp.path().join("empty-hist-home");
        let hist_dir = fake_home.join(".cache/ksession/hist");
        fs::create_dir_all(&hist_dir).unwrap();
        fs::write(hist_dir.join(HIST_WIN_ID.to_string()), b"").unwrap();

        let _guard = HomeGuard::set(&fake_home);
        let ctx = fx.ctx(902, None);
        let p = ShellAdapter.capture(&ctx).await.unwrap();
        match p {
            Program::Shell { history, .. } => {
                let dest = history.expect("history should be Some even for empty file");
                assert!(dest.exists());
                assert_eq!(fs::read(&dest).unwrap().len(), 0, "empty file copied as-is");
            }
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn history_source_still_exists_after_copy() {
        let _lock = HOME_MUTEX.lock().unwrap();
        let fx = hist_fixture();

        let fake_home = fx.tmp.path().join("source-persists-home");
        let hist_dir = fake_home.join(".cache/ksession/hist");
        fs::create_dir_all(&hist_dir).unwrap();
        let source = hist_dir.join(HIST_WIN_ID.to_string());
        fs::write(&source, b"history line\n").unwrap();

        let _guard = HomeGuard::set(&fake_home);
        let ctx = fx.ctx(903, None);
        let _p = ShellAdapter.capture(&ctx).await.unwrap();
        assert!(
            source.is_file(),
            "source file must still exist after copy (not moved)"
        );
    }
}
