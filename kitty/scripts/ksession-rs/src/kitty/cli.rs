//! Subprocess wrapper around `kitty @ ...` — the fallback transport for
//! [`crate::kitty::KittyTransport`] when the direct DCS socket
//! ([`crate::kitty::rpc`]) is unavailable.
//!
//! Each operation spawns `kitty @ <cmd> ...` via `tokio::process::Command`
//! with a 5 s timeout, surfaces non-zero exits as
//! [`KError::KittyRemote`] with a mode-specific hint
//! (`allow_remote_control` for `ls`, generic for the rest), and exposes a
//! `*_via` test-shim that lets unit tests point at a stub script.
//!
//! Performance characteristic: each call is ~50 ms (fork + execve + kitty
//! cold-start). The RPC path is ~15 ms. This module exists for
//! correctness during fallback, not speed.

use std::time::Duration;

use tokio::process::Command;
use tokio::time::timeout;

use crate::error::KError;
use crate::kitty::ls::{parse_ls_output, OsWindow};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);

pub async fn ls_all_env_vars() -> Result<Vec<OsWindow>, KError> {
    ls_via("kitty", &["@", "ls", "--all-env-vars"]).await
}

/// `kitty @ ls --output-format=session` — fallback for [`crate::kitty::pool::KittyPool::ls_session`].
/// Returns the raw session-conf text.
///
/// Trailing whitespace is stripped for transport-symmetry with the
/// [`crate::kitty::rpc`] DCS-socket transport (Plan §6.5 round-3 finding).
pub async fn ls_session(
    all_env_vars: bool,
    use_foreground_process: bool,
) -> Result<String, KError> {
    ls_session_via("kitty", all_env_vars, use_foreground_process).await
}

/// `kitty @ get-text` — fallback for [`crate::kitty::pool::KittyPool::get_text`].
///
/// Trailing whitespace is stripped for transport-symmetry with the
/// [`crate::kitty::rpc`] DCS-socket transport (Plan §6.5 round-3 finding).
pub async fn get_text(match_: &str, extent: &str, ansi: bool) -> Result<String, KError> {
    get_text_via("kitty", match_, extent, ansi).await
}

/// `kitty @ set-user-vars` — fallback for [`crate::kitty::pool::KittyPool::set_user_vars`].
/// Empty `vars` short-circuits to match RPC semantics.
///
/// Same content caveat as the RPC variant: kitty silently rewrites
/// control bytes in user-var values (`\n` → space, `\t`/`\x1b` stripped).
/// Callers writing arbitrary content must sanitize first.
pub async fn set_user_vars<K, V>(match_: &str, vars: &[(K, V)]) -> Result<(), KError>
where
    K: AsRef<str>,
    V: AsRef<str>,
{
    set_user_vars_via("kitty", match_, vars).await
}

// --- `*_via` test seams ----------------------------------------------------

/// Test-shim variant of [`ls_session`] that accepts a stub binary path.
pub(crate) async fn ls_session_via(
    bin: &str,
    all_env_vars: bool,
    use_foreground_process: bool,
) -> Result<String, KError> {
    let mut args: Vec<&str> = vec!["@", "ls", "--output-format=session"];
    if all_env_vars {
        args.push("--all-env-vars");
    }
    if use_foreground_process {
        args.push("--use-foreground-process");
    }
    let out = run_kitty_text(bin, &args).await?;
    Ok(out.trim_end().to_string())
}

/// Test-shim variant of [`get_text`] that accepts a stub binary path.
pub(crate) async fn get_text_via(
    bin: &str,
    match_: &str,
    extent: &str,
    ansi: bool,
) -> Result<String, KError> {
    let extent_arg = format!("--extent={extent}");
    let match_arg = format!("--match={match_}");
    let mut args: Vec<&str> = vec!["@", "get-text", &match_arg, &extent_arg];
    if ansi {
        args.push("--ansi");
    }
    let out = run_kitty_text(bin, &args).await?;
    Ok(out.trim_end().to_string())
}

/// Test-shim variant of [`set_user_vars`] that accepts a stub binary path.
pub(crate) async fn set_user_vars_via<K, V>(
    bin: &str,
    match_: &str,
    vars: &[(K, V)],
) -> Result<(), KError>
where
    K: AsRef<str>,
    V: AsRef<str>,
{
    if vars.is_empty() {
        return Ok(());
    }
    let match_arg = format!("--match={match_}");
    let mut argv: Vec<String> = vec!["@".into(), "set-user-vars".into(), match_arg];
    for (k, v) in vars {
        argv.push(format!("{}={}", k.as_ref(), v.as_ref()));
    }
    let args_ref: Vec<&str> = argv.iter().map(String::as_str).collect();
    // We don't need stdout — discard it.
    let _ = run_kitty_text(bin, &args_ref).await?;
    Ok(())
}

// Factored out so tests can point at a stub script and at a short timeout.
// The 5s constant is fixed for production callers.
pub(crate) async fn ls_via(bin: &str, args: &[&str]) -> Result<Vec<OsWindow>, KError> {
    ls_via_with_timeout(DEFAULT_TIMEOUT, bin, args).await
}

async fn ls_via_with_timeout(
    dur: Duration,
    bin: &str,
    args: &[&str],
) -> Result<Vec<OsWindow>, KError> {
    let output = run_kitty_raw_with_timeout(dur, bin, args, /*hint=*/ true).await?;
    parse_ls_output(&output)
}

/// Spawn `bin args...`, enforce timeout, return stdout as a UTF-8 String
/// (lossy). Used by every non-ls operation.
async fn run_kitty_text(bin: &str, args: &[&str]) -> Result<String, KError> {
    let bytes = run_kitty_raw_with_timeout(DEFAULT_TIMEOUT, bin, args, /*hint=*/ false).await?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Spawn `bin args...`, enforce timeout, return raw stdout bytes on
/// successful exit. `with_allow_rc_hint=true` appends the kitty.conf
/// `allow_remote_control` hint to error messages — useful for `ls` which
/// is the first call most users make and the canonical "remote control
/// not enabled" tripwire. Other ops omit the hint to avoid noise.
async fn run_kitty_raw_with_timeout(
    dur: Duration,
    bin: &str,
    args: &[&str],
    with_allow_rc_hint: bool,
) -> Result<Vec<u8>, KError> {
    let fut = Command::new(bin).args(args).output();
    let output = match timeout(dur, fut).await {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => {
            return Err(KError::KittyRemote(format!(
                "spawn kitty: {e} (is kitty installed and on PATH?)"
            )));
        }
        Err(_) => {
            return Err(KError::KittyRemote(format!(
                "kitty @ {} timed out after {}s",
                args.get(1).copied().unwrap_or("?"),
                dur.as_secs_f32()
            )));
        }
    };

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let body = if stderr.is_empty() {
            match output.status.code() {
                Some(c) => format!("kitty exited with status {c}"),
                None => "kitty was killed by a signal".to_string(),
            }
        } else {
            stderr
        };
        let hint = if with_allow_rc_hint {
            " (is `allow_remote_control` enabled in kitty.conf?)"
        } else {
            ""
        };
        return Err(KError::KittyRemote(format!("{body}{hint}")));
    }

    Ok(output.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    use std::path::PathBuf;
    use std::sync::OnceLock;
    use tempfile::{tempdir, TempDir};

    // Pre-allocate every test script ONCE at module init. After init returns,
    // no thread has a write fd open on any script, so no concurrent
    // `Command::spawn` fork() can inherit a write fd that keeps a script's
    // inode `i_writecount > 0` past `drop(f)`. That fork-inheritance is the
    // race that ETXTBSY fires on; writing inside each test (even with
    // sync_all+drop) leaves a window where another thread's fork inherits
    // the still-open write fd, surfaces as `Text file busy (os error 26)` on
    // execve under high parallelism (`--test-threads=16` reproduced ~13%).
    struct TestScripts {
        _dir: TempDir,
        fake_kitty: PathBuf,
        ok_empty_array: PathBuf,
        ok_minimal: PathBuf,
        garbage: PathBuf,
        silent_fail: PathBuf,
        slow: PathBuf,
        ok_session: PathBuf,
        ok_text: PathBuf,
        ok_empty: PathBuf,
        fail_no_hint: PathBuf,
    }

    fn write_script(dir: &std::path::Path, name: &str, body: &str) -> PathBuf {
        let p = dir.join(name);
        let mut f = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o755)
            .open(&p)
            .unwrap();
        f.write_all(body.as_bytes()).unwrap();
        f.sync_all().unwrap();
        drop(f);
        p
    }

    fn scripts() -> &'static TestScripts {
        static SCRIPTS: OnceLock<TestScripts> = OnceLock::new();
        SCRIPTS.get_or_init(|| {
            let dir = tempdir().unwrap();
            let fake_kitty = write_script(
                dir.path(),
                "fake-kitty.sh",
                "#!/bin/sh\necho 'permission denied' >&2\nexit 1\n",
            );
            let ok_empty_array =
                write_script(dir.path(), "ok-empty.sh", "#!/bin/sh\nprintf '[]'\n");
            let ok_minimal = write_script(
                dir.path(),
                "ok-minimal.sh",
                "#!/bin/sh\nprintf '%s' '[{\"id\": 9, \"tabs\": []}]'\n",
            );
            let garbage = write_script(dir.path(), "garbage.sh", "#!/bin/sh\nprintf 'not json'\n");
            let silent_fail = write_script(dir.path(), "silent-fail.sh", "#!/bin/sh\nexit 2\n");
            let slow = write_script(dir.path(), "slow.sh", "#!/bin/sh\nsleep 1\n");
            let ok_session = write_script(
                dir.path(),
                "ok-session.sh",
                "#!/bin/sh\nprintf 'new_tab\\nlaunch /bin/bash\\nfocus\\n'\n",
            );
            let ok_text = write_script(
                dir.path(),
                "ok-text.sh",
                "#!/bin/sh\nprintf 'hello\\nworld\\n\\n\\n'\n",
            );
            let ok_empty = write_script(dir.path(), "ok-empty-stdout.sh", "#!/bin/sh\nexit 0\n");
            let fail_no_hint = write_script(
                dir.path(),
                "fail-no-hint.sh",
                "#!/bin/sh\necho 'permission denied' >&2\nexit 1\n",
            );
            TestScripts {
                _dir: dir,
                fake_kitty,
                ok_empty_array,
                ok_minimal,
                garbage,
                silent_fail,
                slow,
                ok_session,
                ok_text,
                ok_empty,
                fail_no_hint,
            }
        })
    }

    #[tokio::test]
    async fn subprocess_failure_includes_allow_remote_control_hint() {
        let err = ls_via(scripts().fake_kitty.to_str().unwrap(), &[])
            .await
            .expect_err("must surface failure");
        let msg = err.to_string();
        assert!(
            msg.contains("permission denied"),
            "missing stderr in error: {msg}"
        );
        assert!(
            msg.contains("allow_remote_control"),
            "missing allow_remote_control hint: {msg}"
        );
    }

    #[tokio::test]
    async fn subprocess_success_parses_stdout() {
        let out = ls_via(scripts().ok_empty_array.to_str().unwrap(), &[])
            .await
            .expect("script exits 0 with valid JSON");
        assert!(out.is_empty());
    }

    #[tokio::test]
    async fn subprocess_success_parses_minimal_os_window() {
        let out = ls_via(scripts().ok_minimal.to_str().unwrap(), &[])
            .await
            .expect("script exits 0 with valid JSON");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, 9);
    }

    #[tokio::test]
    async fn subprocess_zero_exit_invalid_json_is_json_error() {
        // A 0-exit with garbage stdout must surface as KError::Json, not
        // KittyRemote — distinguishes "remote control disabled" from "kitty
        // changed its output shape".
        let err = ls_via(scripts().garbage.to_str().unwrap(), &[])
            .await
            .expect_err("garbage stdout must error");
        assert!(
            matches!(err, KError::Json(_)),
            "expected KError::Json, got {err:?}"
        );
    }

    #[tokio::test]
    async fn spawn_failure_includes_path_hint() {
        let err = ls_via("/nonexistent/kitty-binary", &[])
            .await
            .expect_err("spawn must fail");
        assert!(
            matches!(err, KError::KittyRemote(_)),
            "expected KittyRemote, got {err:?}"
        );
        let msg = err.to_string();
        assert!(
            msg.contains("kitty installed") || msg.contains("on PATH"),
            "missing install/PATH hint: {msg}"
        );
    }

    #[tokio::test]
    async fn subprocess_failure_with_empty_stderr_uses_placeholder() {
        let err = ls_via(scripts().silent_fail.to_str().unwrap(), &[])
            .await
            .expect_err("non-zero exit must error");
        let msg = err.to_string();
        assert!(
            msg.contains("kitty exited with status 2"),
            "missing exit-code placeholder: {msg}"
        );
        assert!(!msg.contains("  "), "double-space leak: {msg}");
    }

    #[tokio::test]
    async fn timeout_branch_returns_kitty_remote() {
        let err = ls_via_with_timeout(
            Duration::from_millis(100),
            scripts().slow.to_str().unwrap(),
            &[],
        )
        .await
        .expect_err("must time out");
        assert!(
            matches!(err, KError::KittyRemote(ref m) if m.contains("timed out")),
            "expected KittyRemote(timed out…), got {err:?}"
        );
    }

    // --- `*_via` test-seam coverage ---------------------------------------

    #[tokio::test]
    async fn ls_session_via_trims_trailing_newline() {
        let out = ls_session_via(scripts().ok_session.to_str().unwrap(), false, false)
            .await
            .expect("ok_session stub exits 0");
        assert_eq!(out, "new_tab\nlaunch /bin/bash\nfocus");
    }

    #[tokio::test]
    async fn get_text_via_trims_trailing_whitespace() {
        let out = get_text_via(scripts().ok_text.to_str().unwrap(), "id:1", "screen", false)
            .await
            .expect("ok_text stub exits 0");
        assert_eq!(out, "hello\nworld");
    }

    #[tokio::test]
    async fn get_text_via_empty_stdout_returns_empty() {
        let out = get_text_via(
            scripts().ok_empty.to_str().unwrap(),
            "id:1",
            "screen",
            false,
        )
        .await
        .expect("ok_empty stub exits 0");
        assert_eq!(out, "");
    }

    #[tokio::test]
    async fn set_user_vars_via_success() {
        set_user_vars_via(scripts().ok_empty.to_str().unwrap(), "id:1", &[("k", "v")])
            .await
            .expect("ok_empty stub exits 0");
    }

    #[tokio::test]
    async fn set_user_vars_empty_vars_short_circuits() {
        // Empty vars must short-circuit BEFORE spawn — proves the early
        // return fires by passing a nonexistent binary that would otherwise
        // error out on spawn.
        let empty: &[(&str, &str)] = &[];
        set_user_vars_via("/nonexistent/kitty-binary", "id:1", empty)
            .await
            .expect("empty vars must short-circuit without spawning");
    }

    #[tokio::test]
    async fn ls_session_via_nonzero_exit_no_allow_rc_hint() {
        let err = ls_session_via(scripts().fail_no_hint.to_str().unwrap(), false, false)
            .await
            .expect_err("script exits 1");
        let msg = err.to_string();
        assert!(msg.contains("permission denied"), "missing stderr: {msg}");
        assert!(
            !msg.contains("allow_remote_control"),
            "unexpected allow_remote_control hint: {msg}"
        );
    }

    #[tokio::test]
    async fn get_text_via_nonzero_exit_no_allow_rc_hint() {
        let err = get_text_via(
            scripts().fail_no_hint.to_str().unwrap(),
            "id:1",
            "screen",
            false,
        )
        .await
        .expect_err("script exits 1");
        let msg = err.to_string();
        assert!(msg.contains("permission denied"), "missing stderr: {msg}");
        assert!(
            !msg.contains("allow_remote_control"),
            "unexpected allow_remote_control hint: {msg}"
        );
    }

    #[tokio::test]
    async fn set_user_vars_via_nonzero_exit_no_allow_rc_hint() {
        let err = set_user_vars_via(
            scripts().fail_no_hint.to_str().unwrap(),
            "id:1",
            &[("k", "v")],
        )
        .await
        .expect_err("script exits 1");
        let msg = err.to_string();
        assert!(msg.contains("permission denied"), "missing stderr: {msg}");
        assert!(
            !msg.contains("allow_remote_control"),
            "unexpected allow_remote_control hint: {msg}"
        );
    }

    #[tokio::test]
    async fn ls_session_via_spawn_failure() {
        let err = ls_session_via("/nonexistent/kitty-binary", false, false)
            .await
            .expect_err("spawn must fail");
        let msg = err.to_string();
        assert!(
            msg.contains("spawn kitty") || msg.contains("PATH") || msg.contains("installed"),
            "missing spawn/PATH/install hint: {msg}"
        );
    }

    #[tokio::test]
    #[ignore = "requires live kitty"]
    async fn smoke_against_real_kitty() {
        use crate::kitty::testkitty::LiveKitty;
        let kitty = match LiveKitty::spawn().await {
            Some(k) => k,
            None => {
                eprintln!("test skipped: LiveKitty not available (no kitty or no display)");
                return;
            }
        };
        // Set the environment variable so the CLI transport uses our spawned kitty.
        std::env::set_var("KITTY_LISTEN_ON", kitty.listen_on());
        let out = ls_all_env_vars().await.expect("real kitty responds");
        assert!(!out.is_empty(), "expected >=1 OS window from live kitty");
    }
}
