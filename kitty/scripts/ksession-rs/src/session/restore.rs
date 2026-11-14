//! `ksession restore <name>` — load a previously saved session into kitty.
//!
//! Thin dispatcher (Plan Pass 3 / PRD §05):
//!
//! 1. Validate `<name>` against `^[A-Za-z0-9._-]+$` (cheap, pre-IO).
//! 2. Resolve `<sessions_dir>/<name>.conf`; missing → `KError::NotFound`.
//! 3. Best-effort orphan sweep via [`fsx::sweep_orphans`] so load-only
//!    workflows do not accumulate stale gen-stamped state dirs (PRD user
//!    story 4).
//! 4. If the captured manifest is readable, emit a one-line drift warning
//!    when the captured `kitty_version` major.minor differs from the
//!    running kitty (ADR 0002 — reuses [`super::manifest::read`]).
//! 5. Spawn `kitty --detach --class kitty-project-<name> --session <conf>`
//!    via [`Command::spawn`] — **not** exec — so the calling shell stays
//!    alive after the new kitty detaches.
//!
//! ## Per-component spans (Issue #10)
//!
//! The restore path emits the following spans:
//!
//! - `restore.dispatch` — wraps the entire restore orchestration.
//! - `restore.sweep_orphans` — the orphan state-dir sweep.
//! - `kitty.launch` — time from kitty process spawn to return (detach).
//! - `nvim.spawn` — time to launch nvim in a kitty window (external).
//! - `nvim.source_session` — time for nvim to source its mksession script (external).
//! - `tmux.spawn` — time to launch tmux new-session (external).
//! - `tmux.restore` — time to execute restore.sh and recreate session structure (external).
//! - `ready.wait` — time spent polling for all ready markers to appear.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::conf::parser::{ParsedTab, ParsedWindow};
use crate::error::KError;
use crate::fsx;
use crate::perf;
use crate::session::manifest;

/// Reject names containing anything outside `[A-Za-z0-9._-]`. Mirrors the
/// Bash-era ksession.sh validator so restore + save accept the same set
/// of legal names. An empty name is also rejected — even though `+` in
/// the regex would catch it, this makes the failure mode explicit.
pub fn validate_name(name: &str) -> Result<(), KError> {
    if name.is_empty() {
        return Err(KError::InvalidName(name.to_string()));
    }
    let ok = name
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-');
    if !ok {
        return Err(KError::InvalidName(name.to_string()));
    }
    Ok(())
}

/// Result of [`plan_restore`] — the validated argv plus any drift warning
/// to emit before spawning. Split out from [`run`] so tests can exercise
/// the argv shape without actually spawning kitty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub argv: Vec<String>,
    pub conf_path: PathBuf,
    pub drift_warning: Option<String>,
}

/// Build the spawn plan: validate name, resolve conf path, sweep
/// orphans, and probe the manifest for a drift warning. Pure of
/// `Command::spawn` so the smoke test can target [`run`] end-to-end and
/// unit tests can target this helper.
pub fn plan_restore(name: &str, sessions_dir: &Path) -> Result<Plan, KError> {
    validate_name(name)?;

    let conf_path = sessions_dir.join(format!("{name}.conf"));
    if !conf_path.exists() {
        return Err(KError::NotFound(conf_path.display().to_string()));
    }

    // Load-only users need this sweep — without it they accumulate
    // gen-stamped state dirs indefinitely (PRD user story 4).
    let mut _sweep_span = perf::span!(perf::Level::Info, "restore.sweep_orphans");
    let removed_count = fsx::sweep_orphans(sessions_dir);
    if let Some(s) = _sweep_span.as_mut() {
        s.push_arg("removed_count", format!("{removed_count}"));
    }
    drop(_sweep_span);

    // Drift probe. The manifest path mirrors what `show` looks for —
    // `<sessions_dir>/<name>.state/manifest.json`. If the file is missing
    // or unreadable we silently skip the warning, because restore must
    // still work for hand-written confs that have no manifest.
    let drift_warning = drift_warning_for(name, sessions_dir);

    let class = format!("kitty-project-{name}");
    let argv = vec![
        "kitty".to_string(),
        "--detach".to_string(),
        "--class".to_string(),
        class,
        "--session".to_string(),
        conf_path.display().to_string(),
    ];

    Ok(Plan {
        argv,
        conf_path,
        drift_warning,
    })
}

/// Probe `<sessions_dir>/<name>.state/manifest.json` and, if it loads
/// cleanly and the captured kitty version differs from the live one,
/// return the rendered stderr warning line. All errors (missing file,
/// parse failure, kitty-not-on-PATH) are swallowed — drift surfacing is
/// a diagnostic, never a blocker.
///
/// Uses the synchronous [`manifest::read_with_running_version`] reader
/// combined with a blocking `kitty --version` probe, so restore stays
/// off the tokio runtime entirely (one fewer mutex on its way to spawning
/// the real kitty, and one less set of inherited fds to worry about).
fn drift_warning_for(name: &str, sessions_dir: &Path) -> Option<String> {
    let manifest_path = sessions_dir
        .join(format!("{name}.state"))
        .join("manifest.json");
    if !manifest_path.exists() {
        return None;
    }
    let running = fetch_running_kitty_version().ok()?;
    let loaded = manifest::read_with_running_version(&manifest_path, &running).ok()?;
    loaded.warnings.first().map(|w| w.to_stderr_line())
}

/// Synchronous wrapper around `kitty --version`. Returns the trimmed
/// stdout on success. Any failure (spawn error, non-zero exit) maps to
/// `Err(())` — callers always treat drift as best-effort, so the error
/// type carries no detail.
fn fetch_running_kitty_version() -> Result<String, ()> {
    let out = Command::new("kitty").arg("--version").output().map_err(|_| ())?;
    if !out.status.success() {
        return Err(());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim_end().to_string())
}

/// Entry point for `ksession restore`. See module docs for the full
/// sequence. Spawns kitty with `Command::spawn` (not exec) so the caller's
/// shell stays alive after the kitty process detaches.
pub fn run(name: &str, sessions_dir: &Path) -> Result<(), KError> {
    let mut _dispatch = perf::span!(perf::Level::Info, "restore.dispatch", name = name);

    let plan = plan_restore(name, sessions_dir)?;

    if let Some(s) = _dispatch.as_mut() {
        let conf_bytes = std::fs::metadata(&plan.conf_path)
            .map(|m| m.len())
            .unwrap_or(0);
        s.push_arg("conf_bytes", format!("{conf_bytes}"));
    }

    if let Some(line) = &plan.drift_warning {
        eprintln!("{line}");
    }

    let mut cmd = Command::new(&plan.argv[0]);
    cmd.args(&plan.argv[1..]);
    {
        let _launch = perf::span!(perf::Level::Info, "kitty.launch");
        cmd.spawn().map_err(KError::Io)?;
    }
    Ok(())
}

/// Result of [`run_into_current`].
#[derive(Debug, Clone)]
pub struct IntoCurrentResult {
    /// Number of tabs created in the current OS window.
    pub tabs_created: usize,
    /// Number of windows created (across all created tabs).
    pub windows_created: usize,
    /// Number of pre-existing tabs that were closed.
    pub tabs_closed: usize,
}

/// Parse the window id printed by `kitten @ launch`. Different kitty versions
/// print either a bare integer or `Launched window: id=N`; accept both, and as
/// a last resort grab the trailing integer on the line.
fn parse_launched_window_id(stdout: &str) -> Option<u64> {
    let s = stdout.trim();
    if let Some(rest) = s.strip_prefix("Launched window: id=") {
        return rest.trim().parse().ok();
    }
    if let Ok(id) = s.parse::<u64>() {
        return Some(id);
    }
    s.rsplit(|c: char| !c.is_ascii_digit())
        .find(|t| !t.is_empty())
        .and_then(|t| t.parse().ok())
}

/// Run `kitten @ <args>` and capture stdout. Talks to the kitty instance we
/// were launched inside (via inherited `KITTY_LISTEN_ON`), so no `--to` is
/// needed — same as the surrounding shell tooling.
fn kitten(args: &[&str]) -> Result<String, KError> {
    let out = Command::new("kitten")
        .arg("@")
        .args(args)
        .output()
        .map_err(KError::Io)?;
    if !out.status.success() {
        return Err(KError::KittyRemote(format!(
            "kitten @ {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Find the id of the tab within `osw` (a `kitten @ ls` OS-window object) that
/// contains the window `window_id`.
fn tab_id_containing(osw: &serde_json::Value, window_id: u64) -> Option<u64> {
    let tabs = osw.get("tabs")?.as_array()?;
    for tab in tabs {
        let in_tab = tab
            .get("windows")
            .and_then(|w| w.as_array())
            .is_some_and(|wins| {
                wins.iter()
                    .any(|w| w.get("id").and_then(|i| i.as_u64()) == Some(window_id))
            });
        if in_tab {
            return tab.get("id").and_then(|i| i.as_u64());
        }
    }
    None
}

/// Launch a session tab's first window as a brand-new tab in the OS window that
/// contains `anchor_window`. Returns the new window id, or `None` if the launch
/// failed (a warning is printed).
fn launch_tab(
    tab: &ParsedTab,
    first: &ParsedWindow,
    anchor_window: u64,
    path_env: Option<&str>,
) -> Result<Option<u64>, KError> {
    let mut cmd = Command::new("kitten");
    cmd.arg("@").arg("launch").arg("--type=tab");
    // `--next-to` with `--type=tab` forces the tab into the OS window holding
    // the matched window, so we always build into the invoking kitty.
    cmd.arg("--next-to").arg(format!("id:{anchor_window}"));
    if first.hold {
        cmd.arg("--hold");
    }
    if let Some(title) = &tab.title {
        if !title.is_empty() {
            cmd.arg("--tab-title").arg(title);
        }
    }
    if let Some(cwd) = &first.cwd {
        cmd.arg("--cwd").arg(cwd);
    }
    // Windows created via `kitten @ launch` inherit the (often minimal) PATH of
    // the running kitty instance, not the user's login PATH. Programs invoked as
    // `/bin/sh -c 'exec <prog>'` (nvim, etc.) then fail to resolve. Forward our
    // own PATH (augmented by project-loader.sh) so those programs are found.
    if let Some(p) = path_env {
        cmd.arg("--env").arg(format!("PATH={p}"));
    }
    // The conf's argv already bakes in scrollback replay (`cat … ; exec …`),
    // so we pass it straight through — no scrollback_injector wrapping.
    for a in &first.argv {
        cmd.arg(a);
    }

    let out = cmd.output().map_err(KError::Io)?;
    if !out.status.success() {
        eprintln!(
            "ksession: failed to create tab: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
        return Ok(None);
    }
    Ok(parse_launched_window_id(&String::from_utf8_lossy(&out.stdout)))
}

/// Launch a window as a split next to `anchor_window` (the first window of its
/// tab). Always tiled via `--location=split` regardless of the conf's saved
/// `--type` — this is what stops a captured `--type=overlay` window from
/// covering its sibling on restore.
fn launch_split(
    w: &ParsedWindow,
    anchor_window: u64,
    path_env: Option<&str>,
) -> Result<Option<u64>, KError> {
    let mut cmd = Command::new("kitten");
    cmd.arg("@")
        .arg("launch")
        .arg("--location=split")
        .arg("--next-to")
        .arg(format!("id:{anchor_window}"));
    if w.hold {
        cmd.arg("--hold");
    }
    if let Some(cwd) = &w.cwd {
        cmd.arg("--cwd").arg(cwd);
    }
    if let Some(p) = path_env {
        cmd.arg("--env").arg(format!("PATH={p}"));
    }
    for a in &w.argv {
        cmd.arg(a);
    }

    let out = cmd.output().map_err(KError::Io)?;
    if !out.status.success() {
        eprintln!(
            "ksession: failed to create split window: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
        return Ok(None);
    }
    Ok(parse_launched_window_id(&String::from_utf8_lossy(&out.stdout)))
}

/// Close `tab_id` in a detached process. Used for the invoking tab: closing it
/// kills the window this process runs in, so we hand the request to a `setsid`
/// child that survives our death. Best-effort — a surviving tab is harmless.
fn close_tab_detached(tab_id: u64) {
    let m = format!("id:{tab_id}");
    let detached = Command::new("setsid")
        .args(["kitten", "@", "close-tab", "--match", &m])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if detached.is_err() {
        // setsid unavailable — fall back to a plain spawn (may be torn down
        // with our window, but the close request is usually delivered first).
        let _ = Command::new("kitten")
            .args(["@", "close-tab", "--match", &m])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    }
}

/// Entry point for `ksession restore <name> --into-current`.
///
/// Loads a session into the kitty instance this process is running inside,
/// instead of spawning a new OS window. Kitty has no remote command to load a
/// `.conf` into a running instance, so we replay it via `kitten @ launch`:
///
/// 1. Validate name and locate the conf.
/// 2. Find our OS window + tab via `kitten @ ls` (using `KITTY_WINDOW_ID`).
/// 3. For each tab in the conf: open a new tab (first window) pinned to our OS
///    window, then tile the remaining windows as splits.
/// 4. Focus the saved active window (which also raises its tab).
/// 5. Close every pre-existing tab — others synchronously, our own tab last and
///    detached so we don't kill ourselves mid-restore.
pub fn run_into_current(name: &str, sessions_dir: &Path) -> Result<IntoCurrentResult, KError> {
    validate_name(name)?;

    let conf_path = sessions_dir.join(format!("{name}.conf"));
    if !conf_path.exists() {
        return Err(KError::NotFound(conf_path.display().to_string()));
    }

    let my_window_id: u64 = std::env::var("KITTY_WINDOW_ID")
        .ok()
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| {
            KError::KittyRemote(
                "KITTY_WINDOW_ID unset — --into-current must run inside kitty".to_string(),
            )
        })?;

    let conf_content = std::fs::read_to_string(&conf_path).map_err(KError::Io)?;
    let parsed = crate::conf::parser::ConfParser::parse(&conf_content)
        .map_err(|e| KError::KittyRemote(format!("failed to parse conf: {e}")))?;

    // Locate our OS window, our tab, and every existing tab in that OS window.
    let ls_out = kitten(&["ls"])?;
    let ls_json: serde_json::Value = serde_json::from_str(&ls_out).map_err(KError::Json)?;
    let os_windows = ls_json
        .as_array()
        .ok_or_else(|| KError::KittyRemote("expected JSON array from kitten @ ls".to_string()))?;

    let osw = os_windows
        .iter()
        .find(|osw| tab_id_containing(osw, my_window_id).is_some())
        .ok_or_else(|| {
            KError::KittyRemote("could not find current window in kitty state".to_string())
        })?;

    let my_tab_id = tab_id_containing(osw, my_window_id)
        .ok_or_else(|| KError::KittyRemote("could not find current tab".to_string()))?;

    let old_tab_ids: Vec<u64> = osw
        .get("tabs")
        .and_then(|t| t.as_array())
        .map(|tabs| {
            tabs.iter()
                .filter_map(|t| t.get("id").and_then(|i| i.as_u64()))
                .collect()
        })
        .unwrap_or_default();

    // Build the new tabs. We only replay the first OS window from the conf —
    // additional OS windows can't be merged into this one.
    let mut tabs_created = 0usize;
    let mut windows_created = 0usize;
    let mut focus_win: Option<u64> = None;

    // Forwarded to every launched window so programs resolve against the same
    // PATH ksession sees (project-loader.sh augments it) rather than the running
    // kitty instance's leaner PATH.
    let path_env = std::env::var("PATH").ok();

    if let Some(osw_conf) = parsed.os_windows.first() {
        for (tab_idx, tab) in osw_conf.tabs.iter().enumerate() {
            let Some(first) = tab.windows.first() else {
                continue;
            };

            let mut win_ids: Vec<u64> = Vec::new();
            match launch_tab(tab, first, my_window_id, path_env.as_deref())? {
                Some(id) => {
                    tabs_created += 1;
                    windows_created += 1;
                    win_ids.push(id);
                }
                None => continue,
            }

            let anchor = win_ids[0];
            for w in tab.windows.iter().skip(1) {
                if let Some(id) = launch_split(w, anchor, path_env.as_deref())? {
                    windows_created += 1;
                    win_ids.push(id);
                }
            }

            // Decide whether this is the tab to focus at the end. Honor the
            // conf's `focus_tab` index; otherwise default to the last tab.
            let want_focus = match osw_conf.focus_tab {
                Some(fi) => fi == tab_idx,
                None => tab_idx + 1 == osw_conf.tabs.len(),
            };
            if want_focus {
                let idx = tab.active_window_idx.min(win_ids.len().saturating_sub(1));
                focus_win = win_ids.get(idx).copied();
            }
        }
    }

    // Don't tear down the user's existing layout if we failed to build anything.
    if tabs_created == 0 {
        return Err(KError::KittyRemote(
            "no tabs were created from the session conf; left current tabs intact".to_string(),
        ));
    }

    if let Some(wid) = focus_win {
        let _ = kitten(&["focus-window", "--match", &format!("id:{wid}")]);
    }

    // Replace the previous layout: close every prior tab. Others first
    // (synchronous), then our own tab last and detached.
    let mut tabs_closed = 0usize;
    for tid in old_tab_ids.iter().copied().filter(|t| *t != my_tab_id) {
        if kitten(&["close-tab", "--match", &format!("id:{tid}")]).is_ok() {
            tabs_closed += 1;
        }
    }
    close_tab_detached(my_tab_id);
    tabs_closed += 1;

    Ok(IntoCurrentResult {
        tabs_created,
        windows_created,
        tabs_closed,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn validate_name_accepts_legal_chars() {
        for n in &[
            "demo",
            "my-session",
            "my_session",
            "my.session",
            "v1.2.3",
            "ABC123",
            "a",
            "0",
        ] {
            validate_name(n).unwrap_or_else(|e| panic!("{n:?} should validate: {e}"));
        }
    }

    #[test]
    fn validate_name_rejects_empty() {
        assert!(matches!(validate_name(""), Err(KError::InvalidName(_))));
    }

    #[test]
    fn validate_name_rejects_path_traversal() {
        for n in &["../etc", "foo/bar", "foo\\bar", "foo bar", "foo;ls", "foo$"] {
            let err = validate_name(n).expect_err(&format!("{n:?} must reject"));
            assert!(matches!(err, KError::InvalidName(_)), "got {err:?}");
        }
    }

    #[test]
    fn plan_restore_rejects_bad_name_before_io() {
        // Sessions dir intentionally does not exist — validation should
        // fire first and we never touch the filesystem.
        let err = plan_restore("../bad", Path::new("/no/such/dir"))
            .expect_err("bad name must reject");
        assert!(matches!(err, KError::InvalidName(_)), "got {err:?}");
    }

    #[test]
    fn plan_restore_missing_conf_returns_not_found() {
        let dir = tempdir().unwrap();
        let err = plan_restore("demo", dir.path()).expect_err("missing conf must error");
        match err {
            KError::NotFound(msg) => assert!(
                msg.contains("demo.conf"),
                "NotFound payload should reference conf path, got {msg:?}"
            ),
            other => panic!("expected NotFound, got {other:?}"),
        }
    }

    #[test]
    fn plan_restore_builds_expected_argv() {
        let dir = tempdir().unwrap();
        let conf = dir.path().join("demo.conf");
        std::fs::write(&conf, "# empty conf\n").unwrap();
        let plan = plan_restore("demo", dir.path()).expect("plan ok");
        assert_eq!(
            plan.argv,
            vec![
                "kitty".to_string(),
                "--detach".to_string(),
                "--class".to_string(),
                "kitty-project-demo".to_string(),
                "--session".to_string(),
                conf.display().to_string(),
            ]
        );
        assert_eq!(plan.conf_path, conf);
    }

    #[test]
    fn plan_restore_no_drift_warning_when_no_manifest() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join("demo.conf"), "# noop\n").unwrap();
        let plan = plan_restore("demo", dir.path()).expect("plan ok");
        assert!(
            plan.drift_warning.is_none(),
            "drift warning must be absent when manifest is missing: {:?}",
            plan.drift_warning,
        );
    }
}
