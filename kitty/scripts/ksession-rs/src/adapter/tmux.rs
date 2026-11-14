//! Tmux adapter.
//!
//! Mirrors `capture_tmux_window` (ksession.sh:311-442) per Plan §5.4 / 5.5.
//! Two layers:
//!
//! - [`TmuxAdapter`] (kitty context): on match (`fg_exe == "tmux"`) find
//!   the tmux session attached to `ctx.fg_pid` via `tmux list-clients`,
//!   pick a transport (control-mode pipe from the per-save cache, else
//!   subprocess) and decide how to degrade when anything fails.
//! - `capture_session` (pure tmux): walk every window/pane of one
//!   session field-per-call ([`tmux_rpc::list_windows`] /
//!   [`tmux_rpc::list_panes`]), recurse each pane through the same
//!   [`Registry`] via a synthetic [`WindowCtx`] (Plan §5.5 "Tmux
//!   recursion"), capture scrollback to `pane-<uid>/scrollback.ansi`,
//!   build a [`RestoreScript`] and render it to
//!   `<state_dir>/tmux/<sess>/restore.sh`. The tmux-native session
//!   manager (`crate::tmux_session`) calls this layer directly — it knows
//!   its session up front and has no kitty window to degrade into.
//!
//! Degradation per Plan §5.5: any failure that prevents building a valid
//! `Program::Tmux` (tmux not installed, no client, RPC error, restore.sh
//! write failure) folds to `Program::Raw { argv: vec!["tmux"] }` —
//! identical to ksession.sh:315-327 fallbacks.
//!
//! Pane recursion uses a synthetic `kitty::ls::Window` with empty
//! `user_vars` (the outer kitty window's user_vars belong to the outer
//! shell — they would be stale for an inner pane).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;

use super::{Adapter, AdapterError, Registry, WindowCtx};
use crate::kitty;
use crate::model::{Program, TmuxPane, TmuxWindow};
use crate::proc;
use crate::tmux_rpc::{
    find_session_for_client_pid, list_panes, list_windows, parse_tmux_env, program_to_tmux_cmd,
    render_restore_sh, PaneMeta, RestorePane, RestoreScript, RestoreWindow, TmuxCli, TmuxControl,
    TmuxEnvInfo, TmuxError, TmuxIo, WindowMeta,
};

/// Tmux adapter. Owns a boxed [`TmuxIo`] so tests can stub the transport
/// without spawning a real tmux server. The default constructor boxes a
/// fresh [`TmuxCli`] — i.e. the production path is `TmuxAdapter::default()`.
pub struct TmuxAdapter {
    io: Box<dyn TmuxIo + Send + Sync>,
}

impl Default for TmuxAdapter {
    fn default() -> Self {
        Self {
            io: Box::new(TmuxCli::default()),
        }
    }
}

impl TmuxAdapter {
    /// Inject a custom [`TmuxIo`] (test stubs, future `tmux -C` control mode).
    #[must_use]
    pub fn with_io(io: Box<dyn TmuxIo + Send + Sync>) -> Self {
        Self { io }
    }
}

/// Try to get/spawn a persistent control-mode pipe for this capture.
/// `None` when the save runs without a cache or when the socket / server
/// pid cannot be resolved — the caller falls back to the subprocess
/// transport, which always works when tmux is the foreground process.
async fn connect_control(
    ctx: &WindowCtx<'_>,
    cli_io: &(dyn TmuxIo + Send + Sync),
    session_id: u32,
) -> Option<Arc<TmuxControl>> {
    let cache = ctx.tmux_control_cache?;
    let Some(info) = resolve_tmux_env(ctx, cli_io).await else {
        eprintln!(
            "ksession: tmux adapter: could not resolve tmux socket_path/server_pid; \
             falling back to subprocess"
        );
        return None;
    };
    // Probe tmux version for the -r flag decision. Cheap (~5ms) and
    // cached per-process by the OS page cache.
    let version = crate::tmux_rpc::tmux_version();
    match cache
        .get_or_spawn(&info.socket_path, info.server_pid, session_id, version)
        .await
    {
        Ok(ctrl) => Some(ctrl),
        Err(e) => {
            eprintln!(
                "ksession: tmux control-mode connect failed: {e}; \
                 falling back to subprocess"
            );
            None
        }
    }
}

/// Resolve `(socket_path, server_pid)` for the control-mode cache key.
/// Three sources, tried in order:
///   1. `$TMUX` from the kitty window env (shell launched under tmux)
///   2. `$TMUX` from `/proc/<fg_pid>/environ` (the tmux client process)
///   3. Query the tmux server directly via `display-message` (always
///      works when tmux is the foreground process — covers the common
///      case where tmux was attached after the shell started)
async fn resolve_tmux_env(
    ctx: &WindowCtx<'_>,
    cli_io: &(dyn TmuxIo + Send + Sync),
) -> Option<TmuxEnvInfo> {
    if let Some(info) = ctx
        .kitty_window
        .env
        .get("TMUX")
        .and_then(|v| parse_tmux_env(v))
    {
        return Some(info);
    }
    if let Some(info) =
        proc::env_var(ctx.proc_root, ctx.fg_pid, "TMUX").and_then(|v| parse_tmux_env(&v))
    {
        return Some(info);
    }
    cli_io
        .run(&["display-message", "-p", "#{socket_path},#{pid},0"])
        .await
        .ok()
        .and_then(|raw| parse_tmux_env(raw.trim()))
}

/// Whether scrollback should be captured for each tmux pane.
///
/// Honors `KSESSION_SCROLLBACK=0` to disable (matches bash:392 — the same
/// env var gates kitty-level scrollback too). Default: enabled.
pub(crate) fn scrollback_enabled() -> bool {
    match std::env::var("KSESSION_SCROLLBACK") {
        Ok(v) => v != "0",
        Err(_) => true,
    }
}

/// The degraded form of a tmux window: relaunch a bare `tmux` and let the
/// user re-attach by hand (ksession.sh:315-327).
fn bare_tmux() -> Program {
    Program::Raw {
        argv: vec!["tmux".into()],
    }
}

#[async_trait]
impl Adapter for TmuxAdapter {
    fn name(&self) -> &'static str {
        "tmux"
    }

    fn detect(&self, ctx: &WindowCtx<'_>) -> bool {
        matches!(ctx.fg_exe.as_deref(), Some("tmux"))
    }

    async fn capture(&self, ctx: &WindowCtx<'_>) -> Result<Program, AdapterError> {
        // Recursion guard: if the state_dir already lives under a tmux/
        // subdirectory we're being called from inside a tmux pane (Plan
        // §5.5). Bash:298-303 falls back to cmdline for nested tmux; we
        // emit a bare `tmux` argv and let the user re-attach by hand.
        if state_dir_is_inside_tmux(ctx.state_dir) {
            return Ok(bare_tmux());
        }

        // ksession.sh:314 — `command -v tmux`. Synchronous probe rather
        // than waiting for the subprocess `NotInstalled` so the log
        // message points clearly at "tmux not installed".
        if !TmuxCli::is_installed() {
            return Ok(bare_tmux());
        }

        let _tmux_span = crate::perf_span!(
            crate::perf::Level::Info,
            "tmux.capture",
            kitty_id = ctx.kitty_window.id,
        );

        // Phase 1: discover which tmux session the client is attached to.
        // Always uses TmuxCli (subprocess) because we don't yet know the
        // socket_path / server_pid needed to spawn a TmuxControl pipe.
        let cli_io: &(dyn TmuxIo + Send + Sync) = &*self.io;
        let (sess, session_id) = match find_session_for_client_pid(cli_io, ctx.fg_pid).await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("ksession: tmux adapter: client {} → {e}", ctx.fg_pid);
                return Ok(bare_tmux());
            }
        };

        // Phase 2: resolve the TmuxIo transport for all subsequent RPC
        // calls. Prefer the persistent control-mode pipe; the two branches
        // produce the same `&dyn TmuxIo` interface.
        let ctrl = connect_control(ctx, cli_io, session_id).await;
        let io: &dyn TmuxIo = match &ctrl {
            Some(arc) => arc,
            None => cli_io,
        };

        // Phase 3: the pure per-session walk. Every failure that leaves us
        // without a valid `Program::Tmux` degrades to a bare launch.
        let session = SessionRef {
            name: &sess,
            id: session_id,
        };
        match capture_session(
            io,
            &session,
            ctx.state_dir,
            ctx.registry,
            ctx.proc_root,
            scrollback_enabled(),
        )
        .await
        {
            Ok(captured) => Ok(captured.program),
            Err(e) => {
                eprintln!("ksession: tmux adapter: {e}; degrading to bare tmux");
                Ok(bare_tmux())
            }
        }
    }
}

// ---------- pure per-session capture ----------

/// The tmux session to capture: its name (restore-script identity) and
/// the server-side `$<N>` id persisted into the manifest.
pub(crate) struct SessionRef<'a> {
    pub name: &'a str,
    pub id: u32,
}

/// Reasons [`capture_session`] cannot produce a `Program::Tmux` at all.
/// Per-pane problems never surface here — they degrade in place (ADR
/// 0001) and are counted in [`CapturedTmuxSession`].
#[derive(Debug, thiserror::Error)]
pub(crate) enum TmuxCaptureError {
    /// Tmux's `clean_name()` would silently rewrite the name (`:`/`.` →
    /// `_`), so the `=$SESS` exact-match guards in restore.sh could never
    /// find the live session again. NUL bytes are folded in here too.
    #[error("tmux session={0}: name needs cleaning by tmux")]
    InvalidSessionName(String),
    #[error("session {0} has no windows")]
    EmptySession(String),
    #[error("list-windows {session}: {source}")]
    ListWindows {
        session: String,
        #[source]
        source: TmuxError,
    },
    #[error("{op} {}: {source}", .path.display())]
    Io {
        op: &'static str,
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

/// Result of one session walk: the `Program::Tmux` payload plus the ADR
/// 0001 degradation tally the caller turns into an exit code.
pub(crate) struct CapturedTmuxSession {
    pub program: Program,
    /// Panes that were skipped (mkdir failure) or whose program capture
    /// reported adapter errors / lost their scrollback sidecar.
    pub degraded_panes: usize,
    /// Windows dropped from the restore script because their directory
    /// could not be created or their panes could not be listed.
    pub skipped_windows: usize,
    /// Every adapter error raised while recursing into panes.
    pub errors: Vec<AdapterError>,
}

impl CapturedTmuxSession {
    /// Whether anything in the session was captured less faithfully than
    /// the live state (exit code 2 territory).
    pub fn is_degraded(&self) -> bool {
        self.degraded_panes > 0 || self.skipped_windows > 0
    }
}

/// Capture one tmux session into `state_dir`: lists windows and panes,
/// recurses every pane through `registry`, captures scrollback when
/// `scrollback` is set, and renders `<state_dir>/tmux/<name>/restore.sh`.
///
/// Pure of kitty: the only inputs are a tmux transport, the session, and
/// filesystem roots. Both the kitty adapter and the tmux-native session
/// manager call this.
pub(crate) async fn capture_session(
    io: &dyn TmuxIo,
    session: &SessionRef<'_>,
    state_dir: &Path,
    registry: &Registry,
    proc_root: &Path,
    scrollback: bool,
) -> Result<CapturedTmuxSession, TmuxCaptureError> {
    let sess = session.name;
    // Bug 13 + Bug 16: refuse names tmux would rewrite and names that
    // cannot survive a shell-escape boundary.
    if !is_valid_session_name(sess) || assert_no_nul("session_name", sess).is_err() {
        return Err(TmuxCaptureError::InvalidSessionName(sess.to_string()));
    }

    let tmux_dir = state_dir.join("tmux").join(sess);
    create_dir_all(&tmux_dir)?;

    let windows_meta =
        list_windows(io, sess)
            .await
            .map_err(|source| TmuxCaptureError::ListWindows {
                session: sess.to_string(),
                source,
            })?;
    // Empty session → no point writing a restore.sh that would just
    // attach to nothing. The renderer tolerates empty windows defensively,
    // but bailing here means we don't write a useless script to disk.
    if windows_meta.is_empty() {
        return Err(TmuxCaptureError::EmptySession(sess.to_string()));
    }

    let env = PaneCaptureEnv {
        io,
        session: sess,
        registry,
        proc_root,
        scrollback,
        // Synthetic kitty window for pane recursion. user_vars are empty
        // intentionally — the outer kitty window's user_vars apply to the
        // outer shell and would be stale for pane-internal shells.
        synth_kitty_window: synthesize_pane_kitty_window(),
    };
    let mut tally = DegradationTally::default();
    let mut restore_windows: Vec<RestoreWindow> = Vec::with_capacity(windows_meta.len());
    let mut model_windows: Vec<TmuxWindow> = Vec::with_capacity(windows_meta.len());
    for w in &windows_meta {
        match env.capture_window(w, &tmux_dir, &mut tally).await {
            Some((restore, model)) => {
                restore_windows.push(restore);
                model_windows.push(model);
            }
            None => tally.skipped_windows += 1,
        }
    }

    // Bug 9/17: the session-level focus is the active pane of the active
    // window. Per-window active panes are tracked on each window so the
    // renderer emits one `select-pane` per window; only the active
    // window's pane becomes the session-level pair.
    let active_pane = model_windows
        .iter()
        .rev()
        .find(|w| w.active)
        .and_then(|w| w.active_pane_idx.map(|p| (w.idx, p)));
    let restore = RestoreScript {
        session: sess.to_string(),
        windows: restore_windows,
        active_pane,
    };
    let restore_sh = tmux_dir.join("restore.sh");
    crate::fsx::write_atomic(&restore_sh, render_restore_sh(&restore).as_bytes()).map_err(
        |source| TmuxCaptureError::Io {
            op: "write",
            path: restore_sh.clone(),
            source,
        },
    )?;
    // chmod +x for parity with bash:440 — purely cosmetic since the
    // conf renderer invokes `bash <restore_sh>` rather than exec'ing
    // the script directly, but matches the on-disk layout the user
    // might inspect.
    chmod_executable(&restore_sh);

    // Plan §4: `active_window_idx` is the idx of the window flagged
    // active at capture time. `find()` is cheap (small windows).
    let active_window_idx = model_windows.iter().find(|w| w.active).map(|w| w.idx);
    Ok(CapturedTmuxSession {
        program: Program::Tmux {
            session_name: sess.to_string(),
            restore_sh,
            windows: model_windows,
            session_id: session.id,
            active_window_idx,
        },
        degraded_panes: tally.degraded_panes,
        skipped_windows: tally.skipped_windows,
        errors: tally.errors,
    })
}

fn create_dir_all(path: &Path) -> Result<(), TmuxCaptureError> {
    std::fs::create_dir_all(path).map_err(|source| TmuxCaptureError::Io {
        op: "mkdir",
        path: path.to_path_buf(),
        source,
    })
}

/// Running ADR 0001 bookkeeping for one session walk.
#[derive(Default)]
struct DegradationTally {
    degraded_panes: usize,
    skipped_windows: usize,
    errors: Vec<AdapterError>,
}

/// Everything the per-window / per-pane walk shares. Bundled so the
/// helpers stay readable instead of threading seven borrows each.
struct PaneCaptureEnv<'a> {
    io: &'a dyn TmuxIo,
    session: &'a str,
    registry: &'a Registry,
    proc_root: &'a Path,
    scrollback: bool,
    synth_kitty_window: kitty::ls::Window,
}

impl PaneCaptureEnv<'_> {
    /// Capture one window. `None` means the window is dropped from the
    /// restore script entirely (its directory or pane list failed);
    /// per-pane problems are tallied and the window still restores.
    async fn capture_window(
        &self,
        w: &WindowMeta,
        tmux_dir: &Path,
        tally: &mut DegradationTally,
    ) -> Option<(RestoreWindow, TmuxWindow)> {
        let win_dir = tmux_dir.join(format!("win-{}", w.idx));
        if let Err(e) = std::fs::create_dir_all(&win_dir) {
            eprintln!("ksession: tmux adapter: mkdir {}: {e}", win_dir.display());
            return None;
        }
        let panes_meta = match list_panes(self.io, self.session, w.idx).await {
            Ok(p) => p,
            Err(e) => {
                eprintln!(
                    "ksession: tmux adapter: list-panes {}:{}: {e}",
                    self.session, w.idx
                );
                return None;
            }
        };

        let effective_layout = effective_layout(self.session, w, panes_meta.len());
        // Bug 16: validate window name (becomes `-n <name>`).
        let win_name = nul_checked("window_name", &w.name);
        // Only a user-renamed window gets `-n`: `new-window -n` turns
        // automatic-rename off, which would freeze an auto-derived name
        // (the cwd basename in tmux.conf) on the restored window.
        let restore_name = if w.renamed { win_name.clone() } else { String::new() };

        let mut restore_panes: Vec<RestorePane> = Vec::with_capacity(panes_meta.len());
        // Plan §4: per-pane model data persisted into manifest.json so
        // `ksession show` can render pane children and a round-trip
        // test can assert against the manifest rather than diffing the
        // restore.sh byte string.
        let mut model_panes: Vec<TmuxPane> = Vec::with_capacity(panes_meta.len());
        let mut active_pane_idx: Option<u32> = None;
        for pane in &panes_meta {
            if pane.active {
                active_pane_idx = Some(pane.idx);
            }
            match self.capture_pane(pane, &win_dir, tally).await {
                Some((restore, model)) => {
                    restore_panes.push(restore);
                    model_panes.push(model);
                }
                None => tally.degraded_panes += 1,
            }
        }

        // Plan §4: the manifest records the leaf count of the layout we
        // actually emit — once a stale layout has been dropped that is 0,
        // so a downstream diagnostic doesn't misreport.
        let layout_leaf_count = if effective_layout.is_empty() {
            0
        } else {
            count_panes_in_layout(&effective_layout) as u32
        };
        let restore = RestoreWindow {
            idx: w.idx,
            name: restore_name,
            layout: effective_layout.clone(),
            active: w.active,
            panes: restore_panes,
            active_pane_idx,
        };
        let model = TmuxWindow {
            idx: w.idx,
            name: win_name,
            layout: effective_layout,
            active: w.active,
            panes: model_panes,
            active_pane_idx,
            layout_leaf_count,
        };
        Some((restore, model))
    }

    /// Capture one pane: recurse through the registry and (optionally)
    /// capture its scrollback, concurrently. `None` means the pane's
    /// directory could not be created and it is dropped.
    async fn capture_pane(
        &self,
        pane: &PaneMeta,
        win_dir: &Path,
        tally: &mut DegradationTally,
    ) -> Option<(RestorePane, TmuxPane)> {
        // Bug 7: the sidecar directory is keyed by the tmux pane_id with
        // the leading `%` stripped (a path component / identity key from
        // tmux's POV); the uid handed to the recursed adapter is pane_pid
        // as a string (the stable per-capture unique key for sidecar
        // filenames such as nvim's `win-<uid>.vim`). They must diverge.
        let pane_path_key = pane.id.trim_start_matches('%').to_string();
        let pane_uid = pane.pid.to_string();
        let pane_dir = win_dir.join(format!("pane-{pane_path_key}"));
        if let Err(e) = std::fs::create_dir_all(&pane_dir) {
            eprintln!("ksession: tmux adapter: mkdir {}: {e}", pane_dir.display());
            return None;
        }

        let pane_ctx = build_pane_ctx(
            &self.synth_kitty_window,
            pane,
            &pane_dir,
            &pane_uid,
            self.proc_root,
            self.registry,
        );

        // Scrollback runs in parallel with the program capture — both are
        // independent I/O so the wall-clock cost is max(rpc, capture-pane)
        // rather than sum. When scrollback is disabled we skip the future
        // entirely — no file write attempted, no spurious remove_file.
        //
        // Pane-level adapter errors are tallied but never abort: a pane
        // that degrades still appears in `restore.sh` as a default-shell
        // pane, which matches the bash parity goal (ADR 0001).
        let sb_path = pane_dir.join("scrollback.ansi");
        let prog_fut = self.registry.capture(&pane_ctx);
        let ((prog, pane_errs), sb_res) = if self.scrollback {
            let sb_fut = self.io.capture_pane_to_file(&pane.id, &sb_path, true);
            let (prog, sb_res) = tokio::join!(prog_fut, sb_fut);
            (prog, Some(sb_res))
        } else {
            (prog_fut.await, None)
        };
        let mut degraded = !pane_errs.is_empty();
        tally.errors.extend(pane_errs);
        match sb_res {
            // The file was created but the scrollback was genuinely empty
            // — bash:393-394 drops zero-byte sidecars so `ksession show`
            // doesn't list noise.
            Some(Ok(0)) => {
                let _ = std::fs::remove_file(&sb_path);
            }
            Some(Ok(_)) | None => {}
            Some(Err(e)) => {
                eprintln!("ksession: tmux adapter: capture-pane {}: {e}", pane.id);
                // capture-pane may have partially written before erroring
                // — clean up so we don't leave a truncated sidecar visible
                // to `ksession show`.
                let _ = std::fs::remove_file(&sb_path);
                degraded = true;
            }
        }
        if degraded {
            tally.degraded_panes += 1;
        }

        // Bug 16: NUL-check cwd before it reaches `-c <cwd>` shell escape.
        // Empty cwd is fine (the renderer omits the flag); we degrade by
        // omission for this one field rather than sinking the window.
        let pane_cwd = nul_checked("pane_cwd", &pane.cwd);
        // Bug 16: likewise for the program command — a recursed adapter
        // producing an embedded NUL yields a default-shell pane rather
        // than a truncated shell-escape.
        let cmd = program_to_tmux_cmd(&prog).and_then(|c| match assert_no_nul("pane_cmd", &c) {
            Ok(()) => Some(c),
            Err(e) => {
                eprintln!("ksession: tmux adapter: {e}; dropping pane cmd");
                None
            }
        });
        // `pane_id_digits` parses the same string the path-key already
        // validated (digits-only). The fallback `0` is unreachable for any
        // real tmux %N id but defended for future stubs.
        let pane_id_digits = pane_path_key.parse::<u64>().unwrap_or(0);
        let model = TmuxPane {
            index: pane.idx,
            pane_pid: pane.pid,
            pane_id_digits,
            cwd: (!pane_cwd.is_empty()).then(|| PathBuf::from(&pane_cwd)),
            current_command: (!pane.current_command.is_empty())
                .then(|| pane.current_command.clone()),
            program: Box::new(prog),
        };
        // Slice 6: a non-empty scrollback sidecar makes the restore codegen
        // wrap the pane command in a cat-before-exec pattern.
        let scrollback_path = sb_path.exists().then_some(sb_path);
        let restore = RestorePane {
            uid: pane_path_key,
            idx: pane.idx,
            cwd: pane_cwd,
            cmd,
            scrollback_path,
        };
        Some((restore, model))
    }
}

/// Bug 10: the layout string is only safe to replay when it encodes
/// exactly the live pane count. A mismatch means the captured layout is
/// stale (dead-pane filter or capture race) — passing it would silently
/// no-op at restore time, leaving default-split geometry — so the layout
/// is dropped, which suppresses `select-layout` emission in the renderer.
fn effective_layout(session: &str, w: &WindowMeta, live_pane_count: usize) -> String {
    if w.layout.is_empty() {
        return String::new();
    }
    let layout_pane_count = count_panes_in_layout(&w.layout);
    if layout_pane_count != live_pane_count {
        eprintln!(
            "ksession: tmux window={session}:{}: {live_pane_count} live panes but layout encodes {layout_pane_count}; \
             geometry will use default splits",
            w.idx
        );
        return String::new();
    }
    nul_checked("window_layout", &w.layout)
}

/// Bug 16: a field that fails the NUL check is dropped (empty), with a
/// diagnostic naming the field, rather than reaching a shell-escape.
fn nul_checked(field: &str, value: &str) -> String {
    match assert_no_nul(field, value) {
        Ok(()) => value.to_string(),
        Err(e) => {
            eprintln!("ksession: tmux adapter: {e}; dropping {field}");
            String::new()
        }
    }
}

/// Build a synthetic [`kitty::ls::Window`] with empty `user_vars` for tmux
/// pane recursion. Concrete reason: the outer kitty window's `user_vars`
/// were set by the OUTER shell hook and would shadow the pane-internal
/// /proc data, so ShellAdapter's `lookup_env` fast path must not see them.
fn synthesize_pane_kitty_window() -> kitty::ls::Window {
    serde_json::from_value(serde_json::json!({
        "id": 0u64,
        "pid": 0u32,
    }))
    .expect("synthetic pane kitty window JSON parses")
}

fn build_pane_ctx<'a>(
    kitty_window: &'a kitty::ls::Window,
    pane: &PaneMeta,
    state_dir: &'a Path,
    uid: &str,
    proc_root: &'a Path,
    registry: &'a Registry,
) -> WindowCtx<'a> {
    // ksession.sh:243-246 — `exe_base=$(proc_exe_base "$pid" || echo "$cmd")`.
    // Fall back to `pane_current_command` if /proc says nothing.
    let exe = proc::exe_base(proc_root, pane.pid).unwrap_or_else(|| pane.current_command.clone());
    // ksession.sh:248 — bash/zsh/fish/dash/sh/ash classes route to the
    // shell arm. Normalise to `None` so ShellAdapter detects (its
    // `fg_exe.is_none()` gate mirrors the orchestrator's normalisation
    // at ksession.sh:537-554).
    let normalized = normalize_pane_exe(exe);
    WindowCtx {
        kitty_window,
        fg_pid: pane.pid,
        fg_exe: normalized,
        // Pane has no separate "window root" — pane_pid is both fg AND root
        // for adapter purposes. Mirrors ksession.sh:486 capture_shell_window
        // which is invoked with $w_pid (the pane's own pid in this scope).
        window_root_pid: pane.pid,
        state_dir,
        uid: uid.to_string(),
        proc_root,
        registry,
        // Pane recursion never uses control-mode directly — the parent
        // tmux adapter already selected the TmuxIo transport for this
        // session.
        tmux_control_cache: None,
    }
}

/// Collapse shell exe names to `None` so [`super::ShellAdapter`] takes the
/// capture. Anything else (including unknown names) keeps `Some(exe)`.
fn normalize_pane_exe(exe: String) -> Option<String> {
    if exe.is_empty() {
        return None;
    }
    match exe.as_str() {
        "bash" | "zsh" | "fish" | "dash" | "sh" | "ash" => None,
        _ => Some(exe),
    }
}

/// Detect whether `state_dir` lives inside an existing tmux adapter output
/// (i.e. we're being called recursively from inside a captured pane).
///
/// We can't just look for ANY component named "tmux" — users may legitimately
/// keep state under `~/tmux-states/<name>.state/` or `~/.config/tmux/...`
/// and we'd mis-fold every save to a bare `tmux`. Instead require the exact
/// layout this adapter writes: a `tmux/<session>/win-<digits>/pane-<digits>`
/// sequence somewhere in the ancestors. The `<session>` token can be anything
/// because session names are user-controlled.
fn state_dir_is_inside_tmux(state_dir: &Path) -> bool {
    use std::path::Component;
    let comps: Vec<&std::ffi::OsStr> = state_dir
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(s),
            _ => None,
        })
        .collect();
    if comps.len() < 4 {
        return false;
    }
    // Slide a 4-wide window: [..., "tmux", <any>, "win-N", "pane-M", ...].
    for w in comps.windows(4) {
        let a = w[0];
        let win = w[2].to_str();
        let pane = w[3].to_str();
        if a == std::ffi::OsStr::new("tmux")
            && win
                .map(|s| s.strip_prefix("win-").is_some_and(all_digits))
                .unwrap_or(false)
            && pane
                .map(|s| s.strip_prefix("pane-").is_some_and(all_digits))
                .unwrap_or(false)
        {
            return true;
        }
    }
    false
}

fn all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

pub fn chmod_executable(p: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(meta) = std::fs::metadata(p) {
            let mut perms = meta.permissions();
            // Bug 4: full 0o755 — owner rwx + group/other rx. Matches the
            // plan's `Permissions::from_mode(0o755)` recommendation.
            let mode = (perms.mode() & !0o777) | 0o755;
            perms.set_mode(mode);
            let _ = std::fs::set_permissions(p, perms);
        }
    }
}

/// Bug 13: validate that a captured tmux session name is safe to emit.
///
/// Tmux's internal `clean_name()` silently rewrites the bytes `:` and `.`
/// to `_` (see `cmd-rename-session.c`), so a captured name like
/// `my.proj` would round-trip as `my_proj` and the re-restore
/// `has-session -t "=my.proj"` collision check would miss the live session.
/// Note: `#` is allowed per tmux 3.4+. Empty names are outright rejected
/// by tmux. We refuse to silently rewrite — degrade the whole tmux window
/// to a bare `tmux` launch instead and let the user re-attach manually.
#[must_use]
fn is_valid_session_name(name: &str) -> bool {
    if name.is_empty() {
        return false;
    }
    !name.contains([':', '.'])
}

/// Bug 16: assert that a string is NUL-free before passing it to a
/// shell-escape function.
///
/// Tmux metadata can't legitimately contain NUL (tmux's own field parsers
/// reject it earlier), but the shell-pane adapter reads from
/// `/proc/<pid>/environ` where bytes are NUL-separated by definition — a
/// malformed environ block could theoretically yield an embedded NUL.
/// `bash -c <script>` parses argv as C strings and truncates at the first
/// NUL byte, so round-trip equivalence breaks silently.
///
/// In debug builds we panic to surface the bug loudly; in release we
/// return an error and the caller picks a degrade strategy (drop the
/// specific field, drop the whole window, etc.).
pub fn assert_no_nul(field: &str, value: &str) -> Result<(), String> {
    if !value.contains('\0') {
        return Ok(());
    }
    #[cfg(debug_assertions)]
    {
        panic!("tmux adapter: NUL byte in field {field}: {value:?}");
    }
    #[cfg(not(debug_assertions))]
    {
        Err(format!(
            "NUL byte in field {field} (value len={})",
            value.len()
        ))
    }
}

/// Bug 10: count pane leaves in a tmux layout string.
///
/// Layout strings look like:
/// - `c5a5,200x60,0,0,1`                                            → 1 leaf
/// - `c5a5,200x60,0,0[200x29,0,0,1,200x30,0,30,2]`                  → 2 leaves
/// - `5b40,200x60,0,0{100x60,0,0,1,99x60,101,0[99x30,101,0,2,99x29,101,31,3]}` → 3 leaves
///
/// A leaf is `<W>x<H>,<X>,<Y>,<pane_id>` where `<pane_id>` is a non-empty
/// run of digits terminated by either a `,` (next leaf), `]`/`}` (closing
/// a parent group), or end-of-string. The header `<chksum>,<W>x<H>,0,0`
/// must be skipped: it's followed by either `[`, `{`, or `,<digits>`
/// (top-level single pane). To disambiguate the header's trailing
/// `<W>x<H>,0,0` from a leaf, we require that a leaf candidate's `<W>x<H>`
/// substring be preceded by either `[`, `{`, or `,` (i.e. NOT the
/// start-of-string position right after the checksum).
///
/// Heuristic: walk the string left-to-right, maintain a small state
/// machine that recognises `<digits>x<digits>,<digits>,<digits>,<digits>`
/// quintuples and counts them, EXCLUDING the leading top-level header
/// quintuple when followed immediately by `[` or `{`.
#[must_use]
fn count_panes_in_layout(layout: &str) -> usize {
    let bytes = layout.as_bytes();
    // Strip the leading "<chksum>," prefix if present (4 hex digits + ',').
    // tmux's checksum is exactly 4 lowercase hex chars.
    let start =
        if bytes.len() > 5 && bytes[0..4].iter().all(|b| b.is_ascii_hexdigit()) && bytes[4] == b','
        {
            5
        } else {
            0
        };
    let s = &layout[start..];

    // Tokenise WxH,X,Y,ID quintuples. A leaf ID is immediately followed by
    // `,` (sibling leaf or sibling subtree at same depth), `]`, `}`, or
    // end-of-string. The first quintuple in the (possibly-checksum-stripped)
    // string is the WHOLE-WINDOW header iff it is followed by `[` or `{`
    // (i.e. it has children); otherwise it IS the only leaf (single-pane
    // window).
    let mut count = 0usize;
    let s_bytes = s.as_bytes();
    let mut i = 0usize;
    // Find each `<digits>x<digits>,<digits>,<digits>,<digits>` quintuple.
    let mut first_seen_at: Option<usize> = None;
    while i < s_bytes.len() {
        // Skip non-digit bytes until we find a digit.
        if !s_bytes[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        // Try to match WxH,X,Y,ID starting at i.
        let start_q = i;
        // parse digits
        let parse_run = |from: usize| -> Option<usize> {
            let mut j = from;
            while j < s_bytes.len() && s_bytes[j].is_ascii_digit() {
                j += 1;
            }
            if j > from {
                Some(j)
            } else {
                None
            }
        };
        let Some(after_w) = parse_run(i) else {
            i += 1;
            continue;
        };
        if after_w >= s_bytes.len() || s_bytes[after_w] != b'x' {
            i = after_w;
            continue;
        }
        let Some(after_h) = parse_run(after_w + 1) else {
            i = after_w + 1;
            continue;
        };
        if after_h >= s_bytes.len() || s_bytes[after_h] != b',' {
            i = after_h;
            continue;
        }
        let Some(after_x) = parse_run(after_h + 1) else {
            i = after_h + 1;
            continue;
        };
        if after_x >= s_bytes.len() || s_bytes[after_x] != b',' {
            i = after_x;
            continue;
        }
        let Some(after_y) = parse_run(after_x + 1) else {
            i = after_x + 1;
            continue;
        };
        if after_y >= s_bytes.len() || s_bytes[after_y] != b',' {
            i = after_y;
            continue;
        }
        let Some(after_id) = parse_run(after_y + 1) else {
            i = after_y + 1;
            continue;
        };
        // Found a candidate WxH,X,Y,ID at [start_q, after_id).
        // Track whether this is the FIRST quintuple and whether it is
        // followed by `[` or `{` (→ it's the header, not a leaf).
        let terminator = s_bytes.get(after_id).copied();
        let is_header_candidate = matches!(terminator, Some(b'[' | b'{'));
        if first_seen_at.is_none() {
            first_seen_at = Some(start_q);
            if !is_header_candidate {
                // No children → the only leaf is the header itself.
                count += 1;
            }
        } else {
            // Subsequent quintuples never act as the parent header here
            // (the header sits at the start). If this one has children
            // (`[`/`{`), it's an inner subtree header and we DON'T count
            // it as a leaf; if it has a sibling/closing terminator or EOF,
            // it IS a leaf.
            if !is_header_candidate {
                count += 1;
            }
        }
        i = after_id;
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapter::tests::{write_cmdline, write_exe, CtxFixture};
    use crate::adapter::{LessAdapter, NvimAdapter, RawAdapter, ShellAdapter};
    use pretty_assertions::assert_eq;

    fn full_pane_registry() -> Registry {
        Registry::new(vec![
            Box::new(ShellAdapter),
            Box::new(NvimAdapter),
            Box::new(LessAdapter),
            Box::new(RawAdapter),
        ])
    }

    // ---------- detect ----------

    #[test]
    fn detect_matches_tmux_only() {
        let fx = CtxFixture::new();
        let a = TmuxAdapter::default();
        assert!(a.detect(&fx.ctx(1, Some("tmux".into()))));
        assert!(!a.detect(&fx.ctx(1, Some("tmuxinator".into()))));
        assert!(!a.detect(&fx.ctx(1, Some("nvim".into()))));
        assert!(!a.detect(&fx.ctx(1, None)));
    }

    // ---------- normalize_pane_exe ----------

    #[test]
    fn normalize_shells_to_none() {
        for sh in ["bash", "zsh", "fish", "dash", "sh", "ash"] {
            assert_eq!(normalize_pane_exe(sh.to_string()), None);
        }
    }

    #[test]
    fn normalize_keeps_non_shells() {
        assert_eq!(
            normalize_pane_exe("nvim".to_string()),
            Some("nvim".to_string())
        );
        assert_eq!(
            normalize_pane_exe("less".to_string()),
            Some("less".to_string())
        );
        assert_eq!(
            normalize_pane_exe("htop".to_string()),
            Some("htop".to_string())
        );
    }

    #[test]
    fn normalize_empty_is_none() {
        assert_eq!(normalize_pane_exe(String::new()), None);
    }

    // ---------- count_panes_in_layout (Bug 10) ----------

    #[test]
    fn count_panes_single_pane() {
        // c5a5,200x60,0,0,1 → 1 leaf
        assert_eq!(count_panes_in_layout("c5a5,200x60,0,0,1"), 1);
    }

    #[test]
    fn count_panes_two_pane_split() {
        // c5a5,200x60,0,0[200x29,0,0,1,200x30,0,30,2] → 2 leaves
        assert_eq!(
            count_panes_in_layout("c5a5,200x60,0,0[200x29,0,0,1,200x30,0,30,2]"),
            2
        );
    }

    #[test]
    fn count_panes_three_pane_nested() {
        // 5b40,200x60,0,0{100x60,0,0,1,99x60,101,0[99x30,101,0,2,99x29,101,31,3]} → 3 leaves
        assert_eq!(
            count_panes_in_layout(
                "5b40,200x60,0,0{100x60,0,0,1,99x60,101,0[99x30,101,0,2,99x29,101,31,3]}"
            ),
            3
        );
    }

    #[test]
    fn count_panes_empty_string() {
        assert_eq!(count_panes_in_layout(""), 0);
    }

    // ---------- is_valid_session_name (Bug 13) ----------

    #[test]
    fn session_name_rejects_empty() {
        assert!(!is_valid_session_name(""));
    }

    #[test]
    fn session_name_rejects_colon_dot() {
        assert!(!is_valid_session_name("foo:bar"));
        assert!(!is_valid_session_name("foo.bar"));
        assert!(!is_valid_session_name("my.proj"));
    }

    #[test]
    fn session_name_accepts_hash() {
        // # is allowed per tmux 3.4+
        assert!(is_valid_session_name("foo#bar"));
    }

    #[test]
    fn session_name_accepts_normal() {
        assert!(is_valid_session_name("work"));
        assert!(is_valid_session_name("project_2"));
        assert!(is_valid_session_name("my-session"));
        assert!(is_valid_session_name("with space")); // tmux tolerates spaces
    }

    // ---------- assert_no_nul (Bug 16) ----------

    #[cfg(not(debug_assertions))]
    #[test]
    fn assert_no_nul_release_returns_err() {
        assert!(assert_no_nul("x", "no nul here").is_ok());
        assert!(assert_no_nul("x", "with\0nul").is_err());
    }

    #[cfg(debug_assertions)]
    #[test]
    fn assert_no_nul_debug_clean_input_ok() {
        // In debug builds we panic on NUL — only exercise the happy path
        // here so the test suite stays deterministic.
        assert!(assert_no_nul("x", "clean").is_ok());
    }

    #[cfg(debug_assertions)]
    #[test]
    #[should_panic(expected = "NUL byte")]
    fn assert_no_nul_debug_panics_on_nul() {
        let _ = assert_no_nul("field", "bad\0value");
    }

    // ---------- state_dir_is_inside_tmux ----------
    //
    // The guard MUST require the specific `tmux/<sess>/win-N/pane-M` layout
    // this adapter itself writes — not merely "any component named tmux" —
    // otherwise users who keep state under `~/tmux-states/...` or
    // `~/.config/tmux/sessions/...` get every save mis-degraded to bare `tmux`.

    #[test]
    fn recursion_guard_fires_for_real_pane_subdir() {
        assert!(state_dir_is_inside_tmux(Path::new(
            "/foo/sessions/abc.state/tmux/work/win-0/pane-3"
        )));
        // Deeper nesting (extra trailing components) still matches.
        assert!(state_dir_is_inside_tmux(Path::new(
            "/a/.state/tmux/work/win-0/pane-3/sidecar"
        )));
    }

    #[test]
    fn recursion_guard_does_not_fire_for_user_tmux_dir() {
        // User keeps state in a tmux-themed parent directory — must not
        // false-positive.
        assert!(!state_dir_is_inside_tmux(Path::new(
            "/home/u/tmux-states/abc.state"
        )));
        assert!(!state_dir_is_inside_tmux(Path::new(
            "/home/u/.config/tmux/sessions/abc.state"
        )));
    }

    #[test]
    fn recursion_guard_does_not_fire_for_substring() {
        // `tmuxlike` is a substring of `tmux`-prefixed components but is
        // itself a separate component — must NOT match.
        assert!(!state_dir_is_inside_tmux(Path::new("/a/tmuxlike/sub")));
        // Empty path: no components → false.
        assert!(!state_dir_is_inside_tmux(Path::new("")));
    }

    #[test]
    fn recursion_guard_does_not_fire_for_tmux_only_no_pane_pattern() {
        // A bare `tmux` component without the rest of the
        // `<sess>/win-N/pane-M` shape must not fold.
        assert!(!state_dir_is_inside_tmux(Path::new("/a/tmux/b")));
        // Even with a session-shaped 2nd token, the win-/pane- prefix is
        // load-bearing.
        assert!(!state_dir_is_inside_tmux(Path::new(
            "/a/tmux/work/window-0/pane-3"
        )));
        assert!(!state_dir_is_inside_tmux(Path::new(
            "/a/tmux/work/win-0/p-3"
        )));
        // win-/pane- prefix but non-digit suffix must not match.
        assert!(!state_dir_is_inside_tmux(Path::new(
            "/a/tmux/work/win-abc/pane-3"
        )));
        assert!(!state_dir_is_inside_tmux(Path::new(
            "/a/tmux/work/win-0/pane-x"
        )));
    }

    // ---------- capture: degradation paths ----------

    #[tokio::test]
    async fn capture_in_nested_tmux_state_dir_yields_raw_tmux() {
        // Recursion guard: state_dir contains "/tmux/" → bail.
        let fx = CtxFixture::new();
        let pane_dir = fx
            .state
            .path()
            .join("tmux")
            .join("inner")
            .join("win-0")
            .join("pane-3");
        std::fs::create_dir_all(&pane_dir).unwrap();
        let reg = full_pane_registry();
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 1234,
            fg_exe: Some("tmux".into()),
            window_root_pid: 1234,
            state_dir: &pane_dir,
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let out = TmuxAdapter::default().capture(&ctx).await.unwrap();
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["tmux".into()]
            }
        );
    }

    #[tokio::test]
    async fn capture_no_attached_session_yields_raw_tmux() {
        // tmux is installed but our fg_pid has no client attached →
        // find_session_for_client_pid returns NoClient → fold. Uses an
        // implausible pid so the host's live tmux (if any) won't match.
        if !TmuxCli::is_installed() {
            eprintln!("skip: tmux not on PATH");
            return;
        }

        let fx = CtxFixture::new();
        let reg = full_pane_registry();
        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 99_999_999,
            fg_exe: Some("tmux".into()),
            window_root_pid: 99_999_999,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let out = TmuxAdapter::default().capture(&ctx).await.unwrap();
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["tmux".into()]
            }
        );
    }

    // ---------- build_pane_ctx ----------

    #[tokio::test]
    async fn build_pane_ctx_normalises_shell_exe_to_none() {
        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 555, "/usr/bin/bash");
        let synth = synthesize_pane_kitty_window();
        let reg = full_pane_registry();
        let pane = PaneMeta {
            id: "%3".into(),
            idx: 0,
            pid: 555,
            cwd: "/tmp".into(),
            current_command: "bash".into(),
            active: true,
        };
        let pane_dir = fx.state.path().join("pane");
        let ctx = build_pane_ctx(&synth, &pane, &pane_dir, "3", fx.tmp.path(), &reg);
        assert!(ctx.fg_exe.is_none(), "shell should normalise to None");
        assert_eq!(ctx.fg_pid, 555);
        assert_eq!(ctx.window_root_pid, 555);
    }

    #[tokio::test]
    async fn build_pane_ctx_keeps_nvim_exe() {
        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 556, "/usr/bin/nvim");
        let synth = synthesize_pane_kitty_window();
        let reg = full_pane_registry();
        let pane = PaneMeta {
            id: "%4".into(),
            idx: 1,
            pid: 556,
            cwd: "/tmp".into(),
            current_command: "nvim".into(),
            active: false,
        };
        let pane_dir = fx.state.path().join("pane");
        let ctx = build_pane_ctx(&synth, &pane, &pane_dir, "4", fx.tmp.path(), &reg);
        assert_eq!(ctx.fg_exe.as_deref(), Some("nvim"));
    }

    #[tokio::test]
    async fn build_pane_ctx_falls_back_to_current_command_when_proc_unavailable() {
        // /proc unreadable → use pane_current_command. Matches bash:246
        // `proc_exe_base ... || echo "$cmd"`.
        let fx = CtxFixture::new();
        // No write_exe for pid 557 — exe_base returns None.
        let synth = synthesize_pane_kitty_window();
        let reg = full_pane_registry();
        let pane = PaneMeta {
            id: "%5".into(),
            idx: 2,
            pid: 557,
            cwd: "/tmp".into(),
            current_command: "htop".into(),
            active: false,
        };
        let pane_dir = fx.state.path().join("pane");
        let ctx = build_pane_ctx(&synth, &pane, &pane_dir, "5", fx.tmp.path(), &reg);
        assert_eq!(ctx.fg_exe.as_deref(), Some("htop"));
    }

    // ---------- synthetic kitty window ----------

    #[test]
    fn synthetic_window_has_empty_user_vars() {
        // Anchor for the staleness-avoidance comment in capture(): the
        // ShellAdapter user_vars fast path must miss for pane recursion.
        let w = synthesize_pane_kitty_window();
        assert!(
            w.user_vars.is_empty(),
            "synthetic window must have empty user_vars"
        );
        assert!(w.env.is_empty());
        assert_eq!(w.id, 0);
        assert_eq!(w.pid, 0);
    }

    // ---------- recursion-via-registry smoke tests ----------
    //
    // These exercise build_pane_ctx + registry.capture in isolation —
    // no tmux subprocess required.

    #[tokio::test]
    async fn pane_ctx_dispatches_to_less_via_registry() {
        use crate::adapter::tests::{write_fd, write_fdinfo_pos};
        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 600, "/usr/bin/less");
        let target = fx.tmp.path().join("file.txt");
        std::fs::write(&target, b"hello world").unwrap();
        write_fd(&fx.proc_root(), 600, 3, target.to_str().unwrap());
        write_fdinfo_pos(&fx.proc_root(), 600, 3, 5);

        let synth = synthesize_pane_kitty_window();
        let reg = full_pane_registry();
        let pane = PaneMeta {
            id: "%6".into(),
            idx: 0,
            pid: 600,
            cwd: "/tmp".into(),
            current_command: "less".into(),
            active: true,
        };
        let pane_dir = fx.state.path().join("pane");
        let ctx = build_pane_ctx(&synth, &pane, &pane_dir, "6", fx.tmp.path(), &reg);
        let (prog, _errs) = reg.capture(&ctx).await;
        match prog {
            Program::Less {
                file,
                byte_offset,
                file_size,
            } => {
                assert_eq!(file, target);
                assert_eq!(byte_offset, 5);
                assert_eq!(file_size, 11);
            }
            other => panic!("expected Program::Less, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn pane_ctx_dispatches_to_shell_via_registry() {
        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 601, "/usr/bin/zsh");

        let synth = synthesize_pane_kitty_window();
        let reg = full_pane_registry();
        let pane = PaneMeta {
            id: "%7".into(),
            idx: 0,
            pid: 601,
            cwd: "/home".into(),
            current_command: "zsh".into(),
            active: false,
        };
        let pane_dir = fx.state.path().join("pane");
        let ctx = build_pane_ctx(&synth, &pane, &pane_dir, "7", fx.tmp.path(), &reg);
        let (prog, _errs) = reg.capture(&ctx).await;
        match prog {
            Program::Shell { shell, .. } => {
                assert_eq!(shell, crate::model::ShellKind::Zsh);
            }
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn pane_ctx_dispatches_to_raw_via_registry() {
        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 602, "/usr/bin/btop");
        write_cmdline(&fx.proc_root(), 602, &["btop", "--utf-force"]);

        let synth = synthesize_pane_kitty_window();
        let reg = full_pane_registry();
        let pane = PaneMeta {
            id: "%8".into(),
            idx: 0,
            pid: 602,
            cwd: "/tmp".into(),
            current_command: "btop".into(),
            active: false,
        };
        let pane_dir = fx.state.path().join("pane");
        let ctx = build_pane_ctx(&synth, &pane, &pane_dir, "8", fx.tmp.path(), &reg);
        let (prog, _errs) = reg.capture(&ctx).await;
        assert_eq!(
            prog,
            Program::Raw {
                argv: vec!["btop".into(), "--utf-force".into()]
            }
        );
    }

    // ---------- scrollback_enabled gate ----------
    //
    // env::set_var is process-global; cargo's default parallel runner can
    // race these three checks unless we serialise them ourselves. Use a
    // single test that holds a Mutex for the duration.

    use std::sync::atomic::Ordering;
    use std::sync::Mutex;

    static SCROLLBACK_ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn scrollback_enabled_default_zero_and_one() {
        let _g = SCROLLBACK_ENV_LOCK.lock().unwrap();
        let saved = std::env::var_os("KSESSION_SCROLLBACK");

        // unset → on
        std::env::remove_var("KSESSION_SCROLLBACK");
        assert!(scrollback_enabled(), "default (unset) should be enabled");

        // "0" → off
        std::env::set_var("KSESSION_SCROLLBACK", "0");
        assert!(!scrollback_enabled(), "explicit 0 disables");

        // "1" → on
        std::env::set_var("KSESSION_SCROLLBACK", "1");
        assert!(scrollback_enabled(), "explicit 1 enables");

        // Any other value (truthy by our impl) → on
        std::env::set_var("KSESSION_SCROLLBACK", "yes");
        assert!(scrollback_enabled(), "non-zero string enables");

        match saved {
            Some(v) => std::env::set_var("KSESSION_SCROLLBACK", v),
            None => std::env::remove_var("KSESSION_SCROLLBACK"),
        }
    }

    // ---------- scrollback disabled vs empty, through capture_session ----------

    /// One-window / one-pane stub session named `demo` whose pane is a
    /// bash shell at `pane_pid`; `scrollback` controls what
    /// `capture-pane` writes (`None` = unrouted, like the default stub).
    fn single_pane_stub(pane_pid: u32, scrollback: Option<&'static [u8]>) -> StubTmuxIo {
        let mut io = StubTmuxIo {
            list_windows: Some("0\n".into()),
            scrollback,
            ..Default::default()
        };
        for (k, v) in [
            ("demo:0|#{window_name}", "bash"),
            ("demo:0|#{automatic-rename}", "1"),
            ("demo:0|#{window_layout}", ""),
            ("demo:0|#{window_active}", "1"),
            ("%5|#{pane_index}", "0"),
            ("%5|#{pane_current_path}", "/tmp"),
            ("%5|#{pane_current_command}", "bash"),
            ("%5|#{pane_active}", "1"),
        ] {
            io.display_messages.insert(k.into(), format!("{v}\n"));
        }
        io.display_messages
            .insert("%5|#{pane_pid}".into(), format!("{pane_pid}\n"));
        io.list_panes.insert("demo:0".into(), "%5\n".into());
        io
    }

    async fn capture_single_pane_session(
        fx: &CtxFixture,
        io: &StubTmuxIo,
        scrollback: bool,
    ) -> CapturedTmuxSession {
        let reg = full_pane_registry();
        capture_session(
            io,
            &SessionRef {
                name: "demo",
                id: 1,
            },
            fx.state.path(),
            &reg,
            fx.tmp.path(),
            scrollback,
        )
        .await
        .expect("capture_session")
    }

    #[tokio::test]
    async fn capture_session_with_scrollback_disabled_never_calls_capture_pane() {
        // Disabled must mean "skipped", not "captured and found empty":
        // no capture-pane RPC, no sidecar, no degradation.
        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 700, "/usr/bin/bash");
        let io = single_pane_stub(700, None);

        let got = capture_single_pane_session(&fx, &io, false).await;

        assert_eq!(io.capture_calls.load(Ordering::Relaxed), 0);
        let sidecar = fx
            .state
            .path()
            .join("tmux/demo/win-0/pane-5/scrollback.ansi");
        assert!(
            !sidecar.exists(),
            "disabled scrollback must not create files"
        );
        assert_eq!(got.degraded_panes, 0);
        let restore =
            std::fs::read_to_string(fx.state.path().join("tmux/demo/restore.sh")).unwrap();
        assert!(
            !restore.contains("scrollback.ansi"),
            "restore.sh must not replay a sidecar that was never captured:\n{restore}"
        );
    }

    #[tokio::test]
    async fn capture_session_removes_empty_scrollback_sidecar() {
        // Enabled but genuinely empty: the zero-byte sidecar is dropped so
        // `show` and restore.sh do not advertise it, and it is not a
        // degradation.
        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 701, "/usr/bin/bash");
        let io = single_pane_stub(701, Some(b""));

        let got = capture_single_pane_session(&fx, &io, true).await;

        assert_eq!(io.capture_calls.load(Ordering::Relaxed), 1);
        let sidecar = fx
            .state
            .path()
            .join("tmux/demo/win-0/pane-5/scrollback.ansi");
        assert!(!sidecar.exists(), "empty capture must remove the sidecar");
        assert_eq!(got.degraded_panes, 0);
        match &got.program {
            Program::Tmux { windows, .. } => {
                assert_eq!(windows.len(), 1);
                assert_eq!(windows[0].panes.len(), 1);
            }
            other => panic!("expected Program::Tmux, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn capture_session_keeps_non_empty_scrollback_sidecar() {
        let fx = CtxFixture::new();
        write_exe(&fx.proc_root(), 702, "/usr/bin/bash");
        let io = single_pane_stub(702, Some(b"$ ls\n"));

        capture_single_pane_session(&fx, &io, true).await;

        let sidecar = fx
            .state
            .path()
            .join("tmux/demo/win-0/pane-5/scrollback.ansi");
        assert_eq!(std::fs::read(&sidecar).unwrap(), b"$ ls\n");
        let restore =
            std::fs::read_to_string(fx.state.path().join("tmux/demo/restore.sh")).unwrap();
        assert!(
            restore.contains("scrollback.ansi"),
            "restore.sh replays a non-empty sidecar:\n{restore}"
        );
    }

    // ---------- TmuxIo stub for high-level capture tests ----------

    /// In-memory [`TmuxIo`] for adapter-level tests. Field per RPC; missing
    /// fields make calls fail with `Subprocess` so unrouted calls surface
    /// loudly in test output.
    #[derive(Default)]
    struct StubTmuxIo {
        // Map of (subcommand, key) → response. For list-clients/list-windows
        // we only key on the subcommand. For display-message we key on the
        // format token so different fields can be answered.
        list_clients: Option<String>,
        list_windows: Option<String>,
        // display-message responses keyed by "<target>|<fmt>".
        display_messages: std::collections::HashMap<String, String>,
        // list-panes keyed by session:winidx
        list_panes: std::collections::HashMap<String, String>,
        // capture-pane: bytes written to `dest` and reported back; `None`
        // leaves the call unrouted.
        scrollback: Option<&'static [u8]>,
        capture_calls: std::sync::atomic::AtomicUsize,
    }

    #[async_trait::async_trait]
    impl crate::tmux_rpc::TmuxIo for StubTmuxIo {
        async fn run(&self, args: &[&str]) -> Result<String, crate::tmux_rpc::TmuxError> {
            match args.first().copied() {
                Some("list-clients") => self.list_clients.clone().ok_or_else(|| {
                    crate::tmux_rpc::TmuxError::Subprocess {
                        subcommand: "list-clients".into(),
                        status: 1,
                        stderr: "stub: no list-clients configured".into(),
                    }
                }),
                Some("list-windows") => self.list_windows.clone().ok_or_else(|| {
                    crate::tmux_rpc::TmuxError::Subprocess {
                        subcommand: "list-windows".into(),
                        status: 1,
                        stderr: "stub: no list-windows configured".into(),
                    }
                }),
                Some("list-panes") => {
                    // args = ["list-panes", "-t", "<sess>:<idx>", "-F", "..."]
                    let target = args.get(2).copied().unwrap_or("");
                    self.list_panes.get(target).cloned().ok_or_else(|| {
                        crate::tmux_rpc::TmuxError::Subprocess {
                            subcommand: "list-panes".into(),
                            status: 1,
                            stderr: format!("stub: no list-panes for {target}"),
                        }
                    })
                }
                Some("display-message") => {
                    // args = ["display-message", "-p", "-t", "<tgt>", "<fmt>"]
                    let target = args.get(3).copied().unwrap_or("");
                    let fmt = args.get(4).copied().unwrap_or("");
                    let key = format!("{target}|{fmt}");
                    self.display_messages.get(&key).cloned().ok_or_else(|| {
                        crate::tmux_rpc::TmuxError::Subprocess {
                            subcommand: "display-message".into(),
                            status: 1,
                            stderr: format!("stub: no display-message for {key}"),
                        }
                    })
                }
                _ => Err(crate::tmux_rpc::TmuxError::Subprocess {
                    subcommand: args.first().map(|s| (*s).into()).unwrap_or_default(),
                    status: 1,
                    stderr: "stub: unrouted".into(),
                }),
            }
        }

        async fn capture_pane_to_file(
            &self,
            _pane_id: &str,
            dest: &Path,
            _ansi: bool,
        ) -> Result<u64, crate::tmux_rpc::TmuxError> {
            self.capture_calls.fetch_add(1, Ordering::Relaxed);
            let Some(bytes) = self.scrollback else {
                return Err(crate::tmux_rpc::TmuxError::Subprocess {
                    subcommand: "capture-pane".into(),
                    status: 1,
                    stderr: "stub: capture-pane unrouted".into(),
                });
            };
            // Like the real transports: the file exists even when empty;
            // the caller decides what an empty capture means.
            std::fs::write(dest, bytes)?;
            Ok(bytes.len() as u64)
        }
    }

    // ---------- D: empty windows folds to Raw ----------

    #[tokio::test]
    async fn capture_empty_session_yields_raw_tmux() {
        // list-clients matches our fg_pid → session "demo", but list-windows
        // returns NO windows. Adapter must NOT write a useless restore.sh —
        // it should fold to bare `tmux`.
        let fx = CtxFixture::new();
        let reg = full_pane_registry();
        let io = StubTmuxIo {
            list_clients: Some("4242 $1 demo\n".into()),
            list_windows: Some(String::new()), // ← empty: no windows
            ..Default::default()
        };
        let adapter = TmuxAdapter::with_io(Box::new(io));

        let ctx = WindowCtx {
            kitty_window: &fx.window,
            fg_pid: 4242,
            fg_exe: Some("tmux".into()),
            window_root_pid: 4242,
            state_dir: fx.state.path(),
            uid: "u".into(),
            proc_root: fx.tmp.path(),
            registry: &reg,
            tmux_control_cache: None,
        };
        let out = adapter.capture(&ctx).await.unwrap();
        assert_eq!(
            out,
            Program::Raw {
                argv: vec!["tmux".into()]
            }
        );
        // restore.sh must not exist for the empty-session path.
        let restore_sh = fx.state.path().join("tmux").join("demo").join("restore.sh");
        assert!(
            !restore_sh.exists(),
            "empty session must not write restore.sh, found at {}",
            restore_sh.display()
        );
    }

    // ---------- E: pane_pid points at shell, not less child ----------

    #[tokio::test]
    async fn pane_ctx_with_shell_exe_pid_but_less_child_resolves_to_shell() {
        // This PINS a documented limitation shared with the bash reference
        // (capture_pane_program_cmd, ksession.sh:243-306): tmux's
        // `pane_pid` returns the SHELL pid, not the foreground less child
        // running inside the pane. So a user running `less foo.txt` in a
        // tmux pane gets captured as plain Shell, not Less. Fixing this
        // would require running proc::descendants inside the pane path,
        // mirroring ksession.sh:541-553's outer-window scan — out of scope
        // for step 7.
        use crate::adapter::tests::write_exe;
        let fx = CtxFixture::new();
        // pid 600 = bash, with a less child at pid 601.
        write_exe(&fx.proc_root(), 600, "/usr/bin/bash");
        // /proc/600/task/600/children → "601"
        let task_dir = fx.proc_root().join("600").join("task").join("600");
        std::fs::create_dir_all(&task_dir).unwrap();
        std::fs::write(task_dir.join("children"), b"601").unwrap();
        write_exe(&fx.proc_root(), 601, "/usr/bin/less");

        let synth = synthesize_pane_kitty_window();
        let reg = full_pane_registry();
        let pane = PaneMeta {
            id: "%9".into(),
            idx: 0,
            pid: 600, // ← bash, NOT less
            cwd: "/tmp".into(),
            current_command: "bash".into(),
            active: true,
        };
        let pane_dir = fx.state.path().join("pane");
        let ctx = build_pane_ctx(&synth, &pane, &pane_dir, "9", fx.tmp.path(), &reg);

        // Step 1: shell normalisation fires — pane reads as a shell.
        assert!(
            ctx.fg_exe.is_none(),
            "bash pane_pid must normalise to None even with a less child"
        );

        // Step 2: registry dispatch yields Shell, NOT Less.
        let (prog, _errs) = reg.capture(&ctx).await;
        match prog {
            Program::Shell { .. } | Program::BareShell => {}
            Program::Less { .. } => panic!(
                "pane_pid limitation regressed: shell pane with less child must \
                 NOT capture as Less (would require descendant scan, out of scope)"
            ),
            other => panic!("expected Shell/BareShell, got {other:?}"),
        }
    }

    // ---------- F: ShellAdapter user_vars leakage prevention ----------

    #[tokio::test]
    async fn pane_recursion_does_not_leak_outer_user_vars() {
        // The synthetic pane kitty window has empty user_vars so that the
        // outer shell's `ksession_venv` user_var (set by the outer kitty
        // hook) does NOT shadow the pane-internal /proc/<pid>/environ.
        // This test pins the load-bearing claim in this module's doc.
        use crate::adapter::tests::{write_environ, write_exe};

        let mut fx = CtxFixture::new();
        // Seed the OUTER kitty window with a misleading user_var.
        fx.with_user_vars(&[("ksession_venv", "/from/outer")]);

        // Pane process is a shell whose environ points at a DIFFERENT venv.
        let pid: u32 = 4500;
        write_exe(&fx.proc_root(), pid, "/usr/bin/bash");
        // Plant a real activate file so the venv passes the existence check.
        let real_venv = fx.tmp.path().join("from-proc-venv");
        std::fs::create_dir_all(real_venv.join("bin")).unwrap();
        std::fs::write(real_venv.join("bin").join("activate"), b"# stub").unwrap();
        write_environ(
            &fx.proc_root(),
            pid,
            &[("VIRTUAL_ENV", real_venv.to_str().unwrap())],
        );

        let synth = synthesize_pane_kitty_window();
        let reg = full_pane_registry();
        let pane = PaneMeta {
            id: "%10".into(),
            idx: 0,
            pid,
            cwd: "/tmp".into(),
            current_command: "bash".into(),
            active: true,
        };
        let pane_dir = fx.state.path().join("pane");
        let ctx = build_pane_ctx(&synth, &pane, &pane_dir, "10", fx.tmp.path(), &reg);
        // Sanity: the synthetic window we use has NO user_vars even though
        // the outer fixture window does. This is the whole point.
        assert!(ctx.kitty_window.user_vars.is_empty());

        let (prog, _errs) = reg.capture(&ctx).await;
        match prog {
            Program::Shell { venv, .. } => {
                assert_eq!(
                    venv,
                    Some(real_venv),
                    "ShellAdapter must read venv from /proc, NOT outer window's user_vars"
                );
            }
            other => panic!("expected Program::Shell, got {other:?}"),
        }
    }
}
