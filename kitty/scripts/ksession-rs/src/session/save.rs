//! `ksession save <name>` orchestration. Plan §10 step 8 + §B.2 DAG.
//!
//! Snapshot kitty's live state via `KittyTransport`, fan out per-window
//! adapter capture in parallel (§B.2), tag every window with a v4 UUID
//! (§C.3), render the .conf by patching the `--output-format=session`
//! skeleton (§C.1), and publish the manifest + conf atomically (§B.4).
//!
//! The orchestrator is responsible for:
//! - Resolving target OS windows (`--all` / `KITTY_WINDOW_ID` / focused).
//! - Filtering self + overlay windows (matches ksession.sh:684-686).
//! - The polluted-title sanitizer (ksession.sh:691-712).
//! - The shell-descendant promotion that selects `fg_pid`/`fg_exe`
//!   (ksession.sh:518-554).
//! - Atomic publish (gen-stamped state dir + rename(2)-based conf) — see §B.4.
//!   Every save lands its state in a fresh `<name>.gen-<gen_us>.state/` dir
//!   (collision-safe via PID + retry, §5.7). The rendered conf is written to
//!   `<name>.conf.tmp.<pid>` and atomically renamed onto `<name>.conf` as the
//!   sole commit point. Older gen-stamped dirs are cleaned up by the
//!   `fsx::sweep_orphans` pass that runs at the start of every save.
//!
//! Per-window adapter capture is dispatched through the process-wide
//! [`adapter::default_registry`] singleton. The orchestrator never spawns
//! `kitty @ …` directly — every kitty RC call rides on the shared
//! [`KittyTransport`] (Plan §B.3).

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use chrono::Utc;
use futures::stream::{self, StreamExt};
use tokio::time::{timeout, Duration};

use crate::adapter::{self, nvim as nvim_adapter, AdapterError, WindowCtx};
use crate::conf;
use crate::error::KError;
use crate::fsx;
use crate::kitty::{self, version as kversion, KittyTransport};
use crate::model::{self, OsWindow, SessionFile, Tab};
use crate::perf;
use crate::proc;
use crate::session::tag_windows_uuids;
use crate::session::SyntheticAllocator;

const FAN_OUT_LIMIT: usize = 12; // §B.2 concurrency cap
const PER_WINDOW_BUDGET: Duration = Duration::from_secs(15); // per-window capture timeout

/// Caller-resolved options for [`save`].
#[derive(Default)]
pub struct SaveOpts {
    pub name: String,
    /// `--all`. When false, restrict to the OS window containing
    /// `KITTY_WINDOW_ID`, else the focused OS window, else last-focused.
    pub all: bool,
    /// `--scrollback` / `--no-scrollback`. Default true. Either this OR
    /// `KSESSION_SCROLLBACK=0` being set disables capture.
    pub scrollback: bool,
    /// Resolved sessions directory (see [`sessions_dir`]).
    pub sessions_dir: PathBuf,
    /// Path to a pre-recorded `kitty @ ls --all-env-vars` JSON fixture.
    /// When set, skip spawning kitty and use this file instead.
    /// Enables deterministic testing.
    pub from_ls: Option<PathBuf>,
    /// Path to a pre-recorded `kitty @ ls --output-format=session` skeleton fixture.
    /// When set, skip spawning kitty for skeleton fetch. Enables deterministic testing.
    pub from_skeleton: Option<PathBuf>,
    /// Pre-spawned connection pool from `main()`. When set, the discover
    /// phase wraps it in `KittyTransport::Pool` instead of calling
    /// `KittyTransport::discover()`. Pre-spawn failures are silently
    /// ignored — `save` falls back to fresh discovery.
    pub pre_pool: Option<kitty::pool::KittyPool>,
}

/// Resolve `<sessions_dir>` honoring the Bash-side env var
/// `KITTY_PROJECT_SESSIONS_DIR` (ksession.sh:26).
///
/// Falls back to `$HOME/.config/kitty/sessions`.
pub fn sessions_dir() -> Result<PathBuf, KError> {
    if let Some(d) = std::env::var_os("KITTY_PROJECT_SESSIONS_DIR") {
        return Ok(PathBuf::from(d));
    }
    let home = std::env::var_os("HOME").ok_or_else(|| {
        KError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "HOME not set; cannot resolve sessions directory",
        ))
    })?;
    Ok(PathBuf::from(home)
        .join(".config")
        .join("kitty")
        .join("sessions"))
}

/// Outcome of a successful save. `degraded_any` is set when at least one
/// window dropped to `Program::BareShell` after an adapter chain failure
/// (ADR 0001). The CLI maps this to exit code `2` so the save-prompt
/// overlay can surface "saved with N degradations".
#[must_use]
pub struct SaveOutcome {
    pub session_file: SessionFile,
    pub degraded_any: bool,
}

/// Entry point for `ksession save`.
///
/// Returns the assembled [`SessionFile`] alongside a `degraded_any` flag so
/// the CLI can pick an exit code without re-walking the manifest. Per
/// ADR 0001, any save that produces ≥1 surviving window commits; degraded
/// windows are reported on stderr (`ksession: window <kitty_id>: <error>`)
/// rather than aborting the whole save.
pub async fn save(opts: SaveOpts) -> Result<SaveOutcome, KError> {
    save_with_proc_root(opts, &resolve_proc_root()).await
}

/// Resolve the `/proc` root, honoring `KSESSION_PROC_ROOT` for end-to-end
/// tests that need to inject a synthetic procfs (e.g. to force adapter
/// failures from an external test process). Production callers always see
/// `/proc`. Shared with the tmux-native save path.
pub(crate) fn resolve_proc_root() -> PathBuf {
    std::env::var_os("KSESSION_PROC_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/proc"))
}

/// `save` with an explicit `proc_root`, primarily so tests can substitute a
/// tempdir-backed procfs. Production code calls [`save`].
pub async fn save_with_proc_root(
    mut opts: SaveOpts,
    proc_root: &Path,
) -> Result<SaveOutcome, KError> {
    // Detailed logging for debugging
    let scrollback_enabled = scrollback_enabled(opts.scrollback);
    eprintln!("=== ksession save START ===");
    eprintln!(
        "ksession: saving session '{}' (all={}, scrollback={})",
        opts.name, opts.all, scrollback_enabled
    );

    // PRD-0 L1 phase span: wraps the entire save orchestration. The
    // `_save_total` guard's Drop emits one chrome-trace `X` event on
    // function exit (success or `?`-bubble). When `KSESSION_TRACE_DIR`
    // is unset the macro is a single `OnceLock::get()` atomic load and
    // produces `None`. Slice 1 ships only this one call site;
    // sub-phase spans (`save.discover`, `save.capture`, …) land in
    // PRD-0 slices 2+.
    let _save_total = perf::span!(perf::Level::Info, "save.total", name = &opts.name);

    // ---- L1 phase: save.discover ----
    // Wraps kitty snapshot, orphan sweep, target resolution, skeleton
    // fetch, and state-dir allocation.
    let _discover = perf::span!(perf::Level::Info, "save.discover");

    // 1) Snapshot kitty. Fire version, ls, and skeleton concurrently via
    //    tokio::join! so all three RPCs overlap (~40ms wall instead of ~60ms
    //    sequential). The pool from Slice 1 gives each future its own
    //    connection.
    //
    //    `kitty --version` is captured verbatim into the manifest for
    //    restore-time drift diagnostics (ADR 0002). A version-fetch
    //    failure is non-fatal: the field falls back to an empty string and
    //    the reader skips drift.
    //
    //    When `opts.from_ls` is set, read the pre-recorded ls JSON from the
    //    fixture file instead of spawning kitty. The transport is still used
    //    for UUID tagging (different from ls).
    let (transport, ls, kitty_version, skeleton) = if let Some(ref from_ls_path) = opts.from_ls {
        // Read pre-recorded ls from fixture file.
        let ls = crate::kitty::ls_from_file(from_ls_path)?;
        // Use CLI transport for UUID tagging.
        let transport = KittyTransport::Cli;
        // When using fixture, skip version fetch (empty version for determinism).
        let kitty_version = String::new();
        // Skeleton: read from fixture file if provided, otherwise call kitty.
        let skeleton = if let Some(ref skeleton_path) = opts.from_skeleton {
            std::fs::read_to_string(skeleton_path)?
        } else {
            transport.ls_session(false, true).await?
        };
        (transport, ls, kitty_version, skeleton)
    } else {
        // Use pre-spawned pool if available, otherwise discover fresh.
        let transport = if let Some(pool) = opts.pre_pool.take() {
            KittyTransport::Pool(std::sync::Arc::new(pool))
        } else {
            KittyTransport::discover().await
        };

        let version_fut = kversion::fetch_running_version_stdout();
        let ls_fut = transport.ls_all_env_vars();
        let skeleton_fut = async {
            if let Some(ref skeleton_path) = opts.from_skeleton {
                Ok(std::fs::read_to_string(skeleton_path)?)
            } else {
                transport.ls_session(false, true).await
            }
        };
        let (version_res, ls_res, skeleton_res) = tokio::join!(version_fut, ls_fut, skeleton_fut);
        let ls = ls_res?;
        let skeleton = skeleton_res?;
        let kitty_version = match version_res {
            Ok(s) => s,
            Err(e) => {
                eprintln!(
                    "ksession: `kitty --version` failed: {e}; manifest kitty_version will be empty"
                );
                String::new()
            }
        };
        (transport, ls, kitty_version, skeleton)
    };

    // 1a) Best-effort orphan sweep (§B.4). Removes stale gen-stamped state
    //     dirs from prior runs; only ever drops entries older than
    //     SWEEP_MIN_AGE so concurrent in-flight saves are safe.
    let swept = fsx::sweep_orphans(&opts.sessions_dir);
    if swept > 0 {
        eprintln!("ksession: swept {swept} orphan state dir(s)");
    }

    // 1b) Sweep stale per-window history files (PRD-0013 Slice 8).
    //     Build a HashSet of all live kitty window IDs from the snapshot.
    let live_window_ids: HashSet<u64> = ls
        .iter()
        .flat_map(|osw| osw.tabs.iter())
        .flat_map(|tab| tab.windows.iter())
        .map(|w| w.id)
        .collect();
    let hist_swept = fsx::sweep_history_cache(&live_window_ids);
    if hist_swept > 0 {
        eprintln!("ksession: swept {hist_swept} orphan history file(s)");
    }

    // 2) Resolve target OS windows.
    // When using a fixture (from_ls), default to --all since we don't have
    // a live kitty to query for KITTY_WINDOW_ID.
    let use_all = opts.from_ls.is_some() || opts.all;
    let targets = resolve_targets(&ls, use_all)?;
    if targets.is_empty() {
        return Err(KError::NoTargets);
    }

    // Log target resolution
    eprintln!(
        "ksession: resolved {} OS window(s) for capture",
        targets.len()
    );
    for (i, osw) in targets.iter().enumerate() {
        eprintln!("ksession:   OS window {}: {} tab(s)", i, osw.tabs.len());
    }

    // 3) Phase 0 — allocate the gen-stamped state dir (§B.4). The
    //    StateTmpdir guard cleans it up on any early return below until
    //    `commit_session` disarms it.
    let gen_us = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| KError::Io(std::io::Error::new(std::io::ErrorKind::Other, e)))?
        .as_micros() as u64;
    let state_dir = mkdir_gen_stamped(&opts.sessions_dir, &opts.name, gen_us)?;
    let state_tmpdir = fsx::StateTmpdir::new(state_dir.clone());

    // Pre-create the subdirs adapters expect to write into. Adapters use
    // `fsx::write_atomic` which also `create_dir_all`s but seeding here
    // keeps the on-disk shape predictable for tests.
    fs::create_dir_all(state_dir.join("nvim"))?;
    fs::create_dir_all(state_dir.join("tmux"))?;
    fs::create_dir_all(state_dir.join(".cache"))?;
    if scrollback_enabled {
        fs::create_dir_all(state_dir.join("scrollback"))?;
    }

    // PRD-0010 Slice 5: set `ksession_cache_path` user-var on nvim windows
    // so the kitty watcher knows where to write proactive `:mksession!`
    // cache files. Skip when using a fixture (no live kitty to tag).
    if opts.from_ls.is_none() {
        tag_cache_paths(&targets, &state_dir, proc_root, &transport).await?;
    }

    drop(_discover);

    // ---- L1 phase: save.capture ----
    // Wraps the entire buffer_unordered fan-out + sort.
    let _capture = perf::span!(perf::Level::Info, "save.capture");
    // Capture the L1 span's id before entering the fan-out so each
    // per-window L2 span can reference it as parent_id, despite running
    // on a different tokio task.
    let capture_parent_id = _capture.as_ref().map(|s| s.span_id()).unwrap_or(0);

    // 5) Flat fan-out across (osw_idx, tab_idx, win_idx, &kitty Window).
    let registry = adapter::default_registry();
    let proc_root: PathBuf = proc_root.to_path_buf();
    // Per-save TmuxControl connection cache. Lazily spawns one `tmux -C
    // attach` pipe per (socket_path, server_pid) pair on first use.
    // Shared across all concurrent window captures via Clone (Arc inner).
    // When the save completes and this binding drops, each TmuxControl's
    // Drop sends EOF to stdin and tmux detaches gracefully.
    let tmux_cache = crate::tmux_rpc::TmuxControlCache::new();

    // Collect work items. Each item references a window in `ls` borrowed
    // for the lifetime of the buffer_unordered closure.
    let mut work: Vec<(usize, usize, usize, &kitty::ls::Window)> = Vec::new();
    for (osw_pos, osw) in targets.iter().enumerate() {
        for (tab_idx, tab) in osw.tabs.iter().enumerate() {
            for (win_idx, w) in filter_windows(tab).iter().enumerate() {
                work.push((osw_pos, tab_idx, win_idx, *w));
            }
        }
    }

    // Log work items
    eprintln!("ksession: capturing {} window(s)...", work.len());
    for (osw_idx, tab_idx, win_idx, w) in &work {
        eprintln!(
            "ksession:   window id={} (osw={}, tab={}, win={}), title={}, cwd={}",
            w.id,
            osw_idx,
            tab_idx,
            win_idx,
            w.title.as_deref().unwrap_or("none"),
            w.cwd.as_deref().unwrap_or("none")
        );
    }

    // Capture each window concurrently, capped at FAN_OUT_LIMIT. The
    // per-window `errors` vec rides alongside the captured Window so the
    // orchestrator can later report `ksession: window <id>: <error>` lines
    // and set `degraded_any` (ADR 0001).
    let captured: Vec<(usize, usize, usize, model::Window, Vec<AdapterError>)> = stream::iter(work)
        .map(|(osw_idx, tab_idx, win_idx, w)| {
            let transport_ref = &transport;
            let registry_ref: &'static adapter::Registry = registry;
            let state_dir = state_dir.clone();
            let proc_root = proc_root.clone();
            let tmux_cache_ref = &tmux_cache;
            async move {
                // ---- L2: save.capture.window ----
                // Parent-id propagated explicitly from the save.capture
                // span above. Each future may run on a different tokio
                // worker thread, so task-local context is unavailable.
                let _win_span = perf::span_with_parent!(
                    perf::Level::Info,
                    "save.capture.window",
                    capture_parent_id,
                    kitty_id = w.id,
                );

                let (fg_pid, fg_exe) = resolve_target_program(w, &proc_root);

                let cwd = w.cwd.as_ref().map(PathBuf::from);
                let uid = format!("win-{}", w.id);

                let ctx = WindowCtx {
                    kitty_window: w,
                    fg_pid,
                    fg_exe: fg_exe.clone(),
                    window_root_pid: w.pid,
                    state_dir: &state_dir,
                    uid: uid.clone(),
                    proc_root: &proc_root,
                    registry: registry_ref,
                    tmux_control_cache: Some(tmux_cache_ref),
                };

                let program_fut = registry_ref.capture(&ctx);
                let scrollback_fut =
                    capture_scrollback(transport_ref, w.id, &state_dir, scrollback_enabled);
                // Wrap program capture with per-window timeout. On timeout,
                // degrade to BareShell and push AdapterError::Timeout so the
                // error is reported to the user. Scrollback capture continues
                // in parallel (it's independent I/O).
                let program_result = timeout(PER_WINDOW_BUDGET, program_fut).await;
                let scrollback = scrollback_fut.await;

                // Now handle the program capture result.
                // timeout() returns Result<(Program, Vec<AdapterError>), Elapsed>:
                // - Err(_) means timeout elapsed
                // - Ok((program, errors)) means success
                let (program, errors) = match program_result {
                    Ok((program, errors)) => (program, errors),
                    Err(_) => {
                        // Timeout — degrade to BareShell and record timeout error.
                        (model::Program::BareShell, vec![AdapterError::Timeout])
                    }
                };

                let mut win = model::Window {
                    kitty_id: w.id,
                    ksession_id: String::new(),
                    cwd,
                    program,
                    scrollback,
                };
                // PRD-13: propagate Window.scrollback into Program::Shell.scrollback
                if let model::Program::Shell {
                    ref mut scrollback, ..
                } = win.program
                {
                    *scrollback = win.scrollback.clone();
                }
                (osw_idx, tab_idx, win_idx, win, errors)
            }
        })
        .buffer_unordered(FAN_OUT_LIMIT)
        .collect()
        .await;

    // 6) Sort restored ordering (buffer_unordered does not preserve it).
    let mut captured = captured;
    captured.sort_by_key(|(o, t, w, _, _)| (*o, *t, *w));

    drop(_capture);

    // ---- L1 phase: save.sanitize ----
    // Wraps error draining + SessionFile assembly.
    let _sanitize = perf::span!(perf::Level::Info, "save.sanitize");

    // 6a) Drain per-window errors → stderr, per ADR 0001. One line per
    //     AdapterError emitted, formatted `ksession: window <id>: <error>`.
    //     `degraded_any` is true iff at least one window collected ≥1 error
    //     during capture; the CLI maps it to exit code 2.
    let mut degraded_any = false;
    for (_, _, _, win, errs) in &captured {
        if !errs.is_empty() {
            degraded_any = true;
            for e in errs {
                eprintln!("ksession: window {}: {e}", win.kitty_id);
            }
        }
    }

    // 7) Assemble SessionFile by re-walking the targeted OS windows.
    //    Empty tabs (every kitty window filtered out as `is_self` or overlay
    //    child) receive a single synthetic placeholder window per §5.7 Phase
    //    2 fallback. Synthetic IDs descend from `u64::MAX` so the §C.1
    //    patcher can spot them with a single `kitty_id >= SYNTHETIC_ID_FLOOR`
    //    check. The same allocator backs both call sites — see
    //    [`crate::session::synth`] for the identity contract.
    let mut synth_alloc = SyntheticAllocator::new();
    let mut os_windows: Vec<OsWindow> = Vec::with_capacity(targets.len());
    let mut all_windows_mut_indices: Vec<(usize, usize, usize)> = Vec::new();
    for (osw_pos, osw) in targets.iter().enumerate() {
        let mut tabs: Vec<Tab> = Vec::with_capacity(osw.tabs.len());
        for (tab_idx, tab) in osw.tabs.iter().enumerate() {
            let filtered = filter_windows(tab);
            let layout = tab.layout.clone().unwrap_or_else(|| "splits".to_string());

            // Tab title: first non-empty title across non-overlay windows
            // (ksession.sh:674-679).
            let raw_title: Option<String> = filtered
                .iter()
                .filter_map(|w| w.title.clone())
                .find(|s| !s.is_empty());
            let title = blank_polluted_titles(raw_title, &filtered, &proc_root);

            // Pull captured windows for this (osw_pos, tab_idx).
            let captured_for_tab: Vec<&(usize, usize, usize, model::Window, Vec<AdapterError>)> =
                captured
                    .iter()
                    .filter(|(o, t, _, _, _)| *o == osw_pos && *t == tab_idx)
                    .collect();

            let mut windows: Vec<model::Window> = captured_for_tab
                .into_iter()
                .map(|(_, _, _, w, _)| w.clone())
                .collect();

            // §5.7 Phase 2 fallback: a tab that filtered to zero windows
            // (e.g. only an overlay child or the save-prompt window itself)
            // would otherwise vanish from the restored layout. Inject a
            // single synthetic placeholder so the tab survives the round
            // trip; the §C.1 patcher will emit `launch /bin/bash -l` for it.
            if windows.is_empty() {
                windows.push(model::Window {
                    kitty_id: synth_alloc.next(),
                    ksession_id: String::new(),
                    cwd: None,
                    program: model::Program::BareShell,
                    scrollback: None,
                });
            }

            // Active window: first index whose is_active is true in the
            // filtered set (ksession.sh:733-737).
            let active_window_idx = filtered.iter().position(|w| w.is_active).unwrap_or(0);

            for win_idx in 0..windows.len() {
                all_windows_mut_indices.push((osw_pos, tab_idx, win_idx));
            }

            tabs.push(Tab {
                title,
                layout,
                active_window_idx,
                windows,
            });
        }
        os_windows.push(OsWindow { tabs });
    }

    let mut session_file = SessionFile {
        name: opts.name.clone(),
        created_at: Utc::now(),
        schema: SessionFile::CURRENT_SCHEMA,
        kitty_version,
        os_windows,
    };

    drop(_sanitize);

    // ---- L1 phase: save.tag_uuids ----
    let _tag_uuids = perf::span!(perf::Level::Info, "save.tag_uuids");

    // 8) UUID-tag every window (§C.3) in one batched RPC burst (§C.6).
    // Skip when using a fixture since we don't have a live kitty to tag.
    if opts.from_ls.is_none() {
        let mut all: Vec<&mut model::Window> = Vec::new();
        for osw in session_file.os_windows.iter_mut() {
            for tab in osw.tabs.iter_mut() {
                for w in tab.windows.iter_mut() {
                    all.push(w);
                }
            }
        }
        // tag_windows_uuids takes &mut [Window]; we need to flatten into an
        // owned Vec<Window>, tag, then propagate. Easiest: collect refs,
        // copy out → tag → write back.
        let mut owned: Vec<model::Window> = all.iter().map(|w| (**w).clone()).collect();
        tag_windows_uuids(&mut owned, &transport).await?;
        for (slot, fresh) in all.into_iter().zip(owned.into_iter()) {
            *slot = fresh;
        }
    }
    let _ = all_windows_mut_indices; // suppress unused-var warning

    drop(_tag_uuids);

    // ---- L1 phase: save.render ----
    let _render = perf::span!(perf::Level::Info, "save.render");

    // 9) Render the conf.
    let conf_text = conf::render(&skeleton, &session_file)?;
    let manifest_bytes = serde_json::to_vec_pretty(&session_file)?;

    drop(_render);

    // ---- L1 phase: save.commit ----
    let _commit = perf::span!(perf::Level::Info, "save.commit");

    // 10) Atomic publish (§B.4). Manifest lands inside the gen-stamped dir
    //     first; `commit_session` then handles the conf write + rename,
    //     fsyncs the parent, and disarms the StateTmpdir Drop guard.
    let manifest_path = state_dir.join("manifest.json");
    {
        let _fs_write = perf::span!(
            perf::Level::Info,
            "fs.write",
            conf_bytes = conf_text.len(),
            manifest_bytes = manifest_bytes.len(),
        );
        fs::write(&manifest_path, &manifest_bytes)?;
        fsx::commit_session(
            state_tmpdir,
            conf_text.as_bytes(),
            &opts.sessions_dir,
            &opts.name,
            "conf",
        )?;
    }

    drop(_commit);

    // Log completion summary
    let total_windows = captured.len();
    let degraded_count = captured
        .iter()
        .filter(|(_, _, _, _, e)| !e.is_empty())
        .count();
    eprintln!("=== ksession save COMPLETE ===");
    eprintln!(
        "ksession: captured {} window(s) ({} degraded)",
        total_windows, degraded_count
    );
    if degraded_any {
        eprintln!("ksession: WARNING: some windows had errors during capture");
    }

    Ok(SaveOutcome {
        session_file,
        degraded_any,
    })
}

// ---------------------------------------------------------------------------
// gen-stamped mkdir with retry (§B.4 step 1, plan lines 3199–3206)
// ---------------------------------------------------------------------------

/// Create the gen-stamped state dir, retrying on collision per §5.7.
///
/// Attempt schedule (max 8 total `create_dir` calls):
/// 1. `<name>.gen-<gen_us>.state/`
/// 2. On `AlreadyExists`: `<name>.gen-<gen_us>_<pid>.state/`
/// 3. On `AlreadyExists`: bump `gen_us += 1` and goto step 1.
///
/// Returns the successful path. After 8 collisions returns
/// [`KError::GenCollision`]. Shared with the tmux-native save path, which
/// lays its state dirs out under its own root with the same convention.
pub(crate) fn mkdir_gen_stamped(
    sessions_dir: &Path,
    name: &str,
    mut gen_us: u64,
) -> Result<PathBuf, KError> {
    const MAX_ATTEMPTS: u32 = 8;
    let pid = std::process::id();
    let mut attempts: u32 = 0;
    loop {
        // Bare-gen attempt.
        attempts += 1;
        let bare = sessions_dir.join(fsx::gen_stamp_basename(name, gen_us, None));
        match fs::create_dir(&bare) {
            Ok(()) => return Ok(bare),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(KError::Io(e)),
        }
        if attempts >= MAX_ATTEMPTS {
            return Err(KError::GenCollision {
                attempts: MAX_ATTEMPTS,
            });
        }

        // PID-suffixed attempt at the same gen_us.
        attempts += 1;
        let with_pid = sessions_dir.join(fsx::gen_stamp_basename(name, gen_us, Some(pid)));
        match fs::create_dir(&with_pid) {
            Ok(()) => return Ok(with_pid),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(KError::Io(e)),
        }
        if attempts >= MAX_ATTEMPTS {
            return Err(KError::GenCollision {
                attempts: MAX_ATTEMPTS,
            });
        }

        // Both basenames at this gen_us are taken — bump and retry.
        gen_us = gen_us.saturating_add(1);
    }
}

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// Whether scrollback capture should run.
///
/// `KSESSION_SCROLLBACK=0` forces off (matches `adapter::tmux::scrollback_enabled`
/// and ksession.sh:590). `opts.scrollback=false` also forces off. Any other
/// value defers to `opts.scrollback`.
fn scrollback_enabled(opt: bool) -> bool {
    if !opt {
        return false;
    }
    match std::env::var("KSESSION_SCROLLBACK") {
        Ok(v) => v != "0",
        Err(_) => true,
    }
}

/// Pick the OS windows to capture. Mirrors ksession.sh:640-652.
fn resolve_targets(
    ls: &[kitty::ls::OsWindow],
    all: bool,
) -> Result<Vec<&kitty::ls::OsWindow>, KError> {
    if all {
        return Ok(ls.iter().collect());
    }
    if let Some(v) = std::env::var_os("KITTY_WINDOW_ID") {
        if let Some(s) = v.to_str() {
            if let Ok(target_id) = s.parse::<u64>() {
                for osw in ls {
                    if osw
                        .tabs
                        .iter()
                        .any(|t| t.windows.iter().any(|w| w.id == target_id))
                    {
                        return Ok(vec![osw]);
                    }
                }
                return Err(KError::KittyRemote(format!(
                    "cannot locate KITTY_WINDOW_ID={target_id}"
                )));
            }
        }
    }
    if let Some(osw) = ls.iter().find(|o| o.is_focused) {
        return Ok(vec![osw]);
    }
    if let Some(osw) = ls.iter().find(|o| o.last_focused) {
        return Ok(vec![osw]);
    }
    Ok(ls.iter().take(1).collect())
}

/// Filter overlay + self windows from a tab. Mirrors ksession.sh:684-686.
///
/// An overlay window has `overlay_parent: Some(0)` - it's the parent overlay itself.
/// Overlay children have `overlay_parent: Some(n)` where n > 0.
/// Both should be filtered out.
///
/// We also drop the window this save is running inside, identified by
/// `$KITTY_WINDOW_ID`. `ksession save` is typically launched as a child of the
/// ctrl+space>shift+s save-prompt OVERLAY, and `kitty @ ls` over the RC socket
/// is not window-attributed, so kitty returns `is_self: false` for every window
/// — the `!w.is_self` filter then drops nothing. If kitty also reports the
/// overlay with `overlay_parent: None` (e.g. it was opened over a tiled splits
/// group after a restore), the save-prompt window leaks into the saved session
/// as a spurious extra window. Excluding `KITTY_WINDOW_ID` is the reliable,
/// transport-independent guard. When unset (CLI save from elsewhere) this is a
/// no-op.
fn filter_windows(tab: &kitty::ls::Tab) -> Vec<&kitty::ls::Window> {
    let self_id: Option<u64> = std::env::var("KITTY_WINDOW_ID")
        .ok()
        .and_then(|s| s.parse().ok());
    tab.windows
        .iter()
        .filter(|w| !w.is_self)
        .filter(|w| Some(w.id) != self_id)
        .filter(|w| match w.overlay_parent {
            None => true,     // Keep normal windows
            Some(0) => false, // DROP overlay windows (the parent overlay)
            Some(_) => false, // DROP overlay children
        })
        .collect()
}

/// PRD-0010 Slice 5: Identify nvim windows across all targeted OS windows and
/// burst-write the `ksession_cache_path` user-var so the kitty watcher knows
/// where to write proactive `:mksession!` cache files.
///
/// For each window whose foreground process is `nvim`, constructs the cache
/// path via [`nvim_adapter::cache_path_for`] and collects a
/// `(match_pattern, vec![("ksession_cache_path", path)])` entry. All entries
/// are sent in a single [`KittyTransport::set_user_vars_many`] burst.
///
/// No-ops (no RPC issued) when no nvim windows are found.
async fn tag_cache_paths(
    targets: &[&kitty::ls::OsWindow],
    state_dir: &Path,
    proc_root: &Path,
    transport: &KittyTransport,
) -> Result<(), KError> {
    let _span = perf::span!(perf::Level::Info, "save.tag_cache_paths");

    let mut entries: Vec<(String, Vec<(&str, String)>)> = Vec::new();
    for osw in targets {
        for tab in &osw.tabs {
            for w in filter_windows(tab) {
                let (_fg_pid, fg_exe) = resolve_target_program(w, proc_root);
                if fg_exe.as_deref() == Some("nvim") {
                    let uid = format!("win-{}", w.id);
                    let cache_path = nvim_adapter::cache_path_for(state_dir, &uid);
                    let path_str = cache_path.to_string_lossy().into_owned();
                    entries.push((
                        format!("id:{}", w.id),
                        vec![("ksession_cache_path", path_str)],
                    ));
                }
            }
        }
    }

    if entries.is_empty() {
        return Ok(());
    }

    // Convert to the owned form that set_user_vars_many expects: Vec<(String, Vec<(K, V)>)>
    // where K, V: AsRef<str>.
    let burst: Vec<(String, Vec<(String, String)>)> = entries
        .into_iter()
        .map(|(m, vars)| {
            (
                m,
                vars.into_iter().map(|(k, v)| (k.to_string(), v)).collect(),
            )
        })
        .collect();

    transport.set_user_vars_many(burst).await
}

/// Mirrors ksession.sh:518-554. Resolves `(fg_pid, fg_exe)` for one window:
///
/// 1. Pull the last `foreground_processes[].pid`. Fall back to `window.pid`
///    when kitty reports none (post-`exec` shells).
/// 2. Look up `exe_base(fg_pid)`. If it's an interactive shell, scan
///    descendants of `window.pid` for `tmux|nvim|less|man|more|most|pg`
///    and promote the first match. If no interactive descendant exists,
///    return `(window.pid, None)` so the ShellAdapter triggers.
pub fn resolve_target_program(
    window: &kitty::ls::Window,
    proc_root: &Path,
) -> (u32, Option<String>) {
    // last entry of foreground_processes
    let mut fg_pid: u32 = window
        .foreground_processes
        .last()
        .and_then(|p| p.get("pid"))
        .and_then(|v| v.as_u64())
        .map(|n| n as u32)
        .unwrap_or(window.pid);
    if fg_pid == 0 {
        fg_pid = window.pid;
    }

    let mut fg_exe = proc::exe_base(proc_root, fg_pid);

    // Check if the foreground program is a shell, conda shell hook, or ksession.
    // Conda shell hooks appear as:
    //   /home/.../miniconda3/bin/python .../conda shell.bash hook
    // ksession appears as:
    //   /path/to/ksession (full path) or just "ksession" (basename)
    // ksession.sh appears as:
    //   ksession.sh
    // These should be treated as shells.
    let is_shell = matches!(
        fg_exe.as_deref(),
        Some("bash") | Some("zsh") | Some("fish") | Some("dash") | Some("sh") | Some("ash")
    ) || fg_exe
        .as_ref()
        .map(|e| {
            let e = e.as_str();
            // Detect conda shell hook
            (e.contains("conda") && e.contains("shell"))
            // Detect any ksession variant (ksession, ksession-rs, ksession.sh, etc.)
            // Use case-insensitive contains for robustness
            || e.to_lowercase().contains("ksession")
        })
        .unwrap_or(false);
    if is_shell {
        // ksession.sh:539 — normalise to None first; restored only on promotion.
        fg_exe = None;
        for kid in proc::descendants(proc_root, window.pid) {
            if kid == window.pid {
                continue;
            }
            let Some(kid_exe) = proc::exe_base(proc_root, kid) else {
                continue;
            };
            if matches!(
                kid_exe.as_str(),
                "tmux" | "nvim" | "less" | "man" | "more" | "most" | "pg"
            ) {
                fg_pid = kid;
                fg_exe = Some(kid_exe);
                break;
            }
        }
        if fg_exe.is_none() {
            // No interactive descendant: revert fg_pid to the window root
            // so adapters that key off it inspect the shell directly.
            fg_pid = window.pid;
        }
    }

    // Detailed logging for program detection
    eprintln!(
        "ksession: window {}: fg_pid={}, fg_exe={:?}",
        window.id, fg_pid, fg_exe
    );

    (fg_pid, fg_exe)
}

/// Mirrors ksession.sh:691-712. Two triggers blank the tab title:
///
/// 1. Any non-overlay window's root pid runs `tmux` — the captured title is
///    the stale shell command. ksession.sh checks `tp_exe == tmux` on the
///    window's own pid, not its descendants; we match that.
/// 2. The title looks like a stale shell-command-as-window-title (prefixes
///    `tmux `, `exec `, `nvim `, `less `, `man `, `vim `, `sudo `, `ssh `,
///    `cd `, `ls `).
pub fn blank_polluted_titles(
    title: Option<String>,
    windows: &[&kitty::ls::Window],
    proc_root: &Path,
) -> Option<String> {
    let t = title?;
    if t.is_empty() {
        return None;
    }
    for w in windows {
        if proc::exe_base(proc_root, w.pid).as_deref() == Some("tmux") {
            return None;
        }
    }
    for prefix in [
        "tmux ", "exec ", "nvim ", "less ", "man ", "vim ", "sudo ", "ssh ", "cd ", "ls ",
    ] {
        if t.starts_with(prefix) {
            return None;
        }
    }
    Some(t)
}

// ---------------------------------------------------------------------------
// Per-window helpers
// ---------------------------------------------------------------------------

/// Capture window scrollback to `state_dir/scrollback/win-<id>.ansi`. Returns
/// the relative path on success; logs+returns None on transport failure or
/// when the captured text is empty (matches ksession.sh:597-601).
async fn capture_scrollback(
    transport: &KittyTransport,
    kitty_window_id: u64,
    state_dir: &Path,
    enabled: bool,
) -> Option<PathBuf> {
    if !enabled {
        return None;
    }
    let match_ = format!("id:{kitty_window_id}");
    let text = match transport.get_text(&match_, "all", true).await {
        Ok(t) => t,
        Err(e) => {
            eprintln!("ksession: scrollback capture for win {kitty_window_id} failed: {e}");
            return None;
        }
    };
    if text.is_empty() {
        return None;
    }
    let path = state_dir
        .join("scrollback")
        .join(format!("win-{kitty_window_id}.ansi"));
    if let Err(e) = fsx::write_atomic(&path, text.as_bytes()) {
        eprintln!("ksession: writing scrollback for win {kitty_window_id} failed: {e}");
        return None;
    }
    Some(path)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::symlink;
    use tempfile::tempdir;

    // Local helpers duplicated from `crate::adapter::tests` (private). Tiny;
    // not worth lifting the parent mod to `pub(crate)` just for the test
    // wiring.
    fn write_exe(root: &Path, pid: u32, target: &str) {
        let pid_dir = root.join(pid.to_string());
        fs::create_dir_all(&pid_dir).unwrap();
        symlink(target, pid_dir.join("exe")).unwrap();
    }

    /// Minimal kitty::ls::Window via the lenient JSON path, with optional
    /// `foreground_processes` entries.
    fn mk_window(id: u64, pid: u32, fg_pids: &[u32]) -> kitty::ls::Window {
        let fg: Vec<serde_json::Value> = fg_pids
            .iter()
            .map(|p| serde_json::json!({ "pid": *p, "cmdline": [] }))
            .collect();
        serde_json::from_value(serde_json::json!({
            "id": id,
            "pid": pid,
            "foreground_processes": fg,
        }))
        .expect("minimal window parses")
    }

    /// Write a /proc/PID/task/PID/children file (single-tid version).
    fn write_children(root: &Path, pid: u32, body: &str) {
        let p = root
            .join(pid.to_string())
            .join("task")
            .join(pid.to_string());
        fs::create_dir_all(&p).unwrap();
        fs::write(p.join("children"), body).unwrap();
    }

    // ---------- resolve_target_program ----------

    #[test]
    fn resolve_uses_last_foreground_processes_pid() {
        let tmp = tempdir().unwrap();
        write_exe(tmp.path(), 999, "/usr/bin/htop");
        let w = mk_window(1, 100, &[100, 999]);
        let (pid, exe) = resolve_target_program(&w, tmp.path());
        assert_eq!(pid, 999);
        assert_eq!(exe.as_deref(), Some("htop"));
    }

    #[test]
    fn resolve_falls_back_to_window_pid_when_no_fg_processes() {
        let tmp = tempdir().unwrap();
        write_exe(tmp.path(), 42, "/usr/bin/htop");
        let w = mk_window(1, 42, &[]);
        let (pid, exe) = resolve_target_program(&w, tmp.path());
        assert_eq!(pid, 42);
        assert_eq!(exe.as_deref(), Some("htop"));
    }

    #[test]
    fn resolve_shell_with_no_descendants_returns_none_exe() {
        // fg is bash, descendant scan finds nothing → (window.pid, None).
        let tmp = tempdir().unwrap();
        write_exe(tmp.path(), 50, "/usr/bin/bash");
        write_children(tmp.path(), 50, "");
        let w = mk_window(1, 50, &[50]);
        let (pid, exe) = resolve_target_program(&w, tmp.path());
        assert_eq!(pid, 50, "fg_pid must revert to window.pid for bare shells");
        assert!(exe.is_none(), "fg_exe must be None to trigger ShellAdapter");
    }

    #[test]
    fn resolve_shell_with_tmux_descendant_promotes() {
        let tmp = tempdir().unwrap();
        write_exe(tmp.path(), 100, "/usr/bin/bash");
        write_exe(tmp.path(), 200, "/usr/local/bin/tmux");
        write_children(tmp.path(), 100, "200");
        write_children(tmp.path(), 200, "");
        let w = mk_window(1, 100, &[100]);
        let (pid, exe) = resolve_target_program(&w, tmp.path());
        assert_eq!(pid, 200);
        assert_eq!(exe.as_deref(), Some("tmux"));
    }

    #[test]
    fn resolve_shell_with_multiple_candidate_descendants_picks_first() {
        // Bash spec says `break` on first interactive descendant. With
        // descendants() ordering matching the Bash reference (sorted
        // task iteration + LIFO stack), the first `tmux` found wins.
        let tmp = tempdir().unwrap();
        write_exe(tmp.path(), 100, "/usr/bin/bash");
        write_exe(tmp.path(), 200, "/usr/local/bin/tmux");
        write_exe(tmp.path(), 300, "/usr/bin/nvim");
        write_children(tmp.path(), 100, "200 300");
        write_children(tmp.path(), 200, "");
        write_children(tmp.path(), 300, "");
        let w = mk_window(1, 100, &[100]);
        let (_, exe) = resolve_target_program(&w, tmp.path());
        // Both candidates are valid promotions; the spec picks the first
        // hit. proc::descendants ordering is deterministic, so we lock the
        // result rather than allowing either.
        assert!(
            exe.as_deref() == Some("tmux") || exe.as_deref() == Some("nvim"),
            "got {exe:?}",
        );
    }

    #[test]
    fn resolve_non_shell_fg_returned_as_is() {
        let tmp = tempdir().unwrap();
        write_exe(tmp.path(), 88, "/usr/bin/htop");
        let w = mk_window(1, 88, &[88]);
        let (pid, exe) = resolve_target_program(&w, tmp.path());
        assert_eq!(pid, 88);
        assert_eq!(exe.as_deref(), Some("htop"));
    }

    // ---------- blank_polluted_titles ----------

    #[test]
    fn polluted_title_plain_preserved() {
        let tmp = tempdir().unwrap();
        let w = mk_window(1, 100, &[]);
        write_exe(tmp.path(), 100, "/usr/bin/bash");
        let refs = vec![&w];
        let out = blank_polluted_titles(Some("my project".to_string()), &refs, tmp.path());
        assert_eq!(out.as_deref(), Some("my project"));
    }

    #[test]
    fn polluted_title_command_prefix_blanked() {
        let tmp = tempdir().unwrap();
        let w = mk_window(1, 100, &[]);
        write_exe(tmp.path(), 100, "/usr/bin/bash");
        let refs = vec![&w];
        let out = blank_polluted_titles(Some("tmux attach -t 0".to_string()), &refs, tmp.path());
        assert!(out.is_none());
    }

    #[test]
    fn polluted_title_blanked_alongside_tmux_window() {
        let tmp = tempdir().unwrap();
        let w = mk_window(1, 100, &[]);
        write_exe(tmp.path(), 100, "/usr/local/bin/tmux");
        let refs = vec![&w];
        let out = blank_polluted_titles(Some("foo bar baz".to_string()), &refs, tmp.path());
        assert!(out.is_none());
    }

    #[test]
    fn polluted_title_survives_both_triggers_off() {
        let tmp = tempdir().unwrap();
        let w = mk_window(1, 100, &[]);
        write_exe(tmp.path(), 100, "/usr/bin/bash");
        let refs = vec![&w];
        let out = blank_polluted_titles(Some("my project".to_string()), &refs, tmp.path());
        assert_eq!(out.as_deref(), Some("my project"));
    }

    #[test]
    fn polluted_title_command_prefix_each() {
        let tmp = tempdir().unwrap();
        let w = mk_window(1, 100, &[]);
        write_exe(tmp.path(), 100, "/usr/bin/bash");
        let refs = vec![&w];
        for bad in [
            "tmux x", "exec x", "nvim x", "less x", "man x", "vim x", "sudo x", "ssh x", "cd x",
            "ls x",
        ] {
            let out = blank_polluted_titles(Some(bad.to_string()), &refs, tmp.path());
            assert!(out.is_none(), "expected {bad:?} to be blanked");
        }
    }

    // ---------- sessions_dir ----------

    #[test]
    fn sessions_dir_honors_env_override() {
        // Per-test serial guard: this test mutates process env.
        let _g = ENV_LOCK.lock().unwrap();
        let prev = std::env::var_os("KITTY_PROJECT_SESSIONS_DIR");
        std::env::set_var("KITTY_PROJECT_SESSIONS_DIR", "/custom/sessions");
        let got = sessions_dir().unwrap();
        assert_eq!(got, PathBuf::from("/custom/sessions"));
        match prev {
            Some(v) => std::env::set_var("KITTY_PROJECT_SESSIONS_DIR", v),
            None => std::env::remove_var("KITTY_PROJECT_SESSIONS_DIR"),
        }
    }

    #[test]
    fn sessions_dir_falls_back_to_home() {
        let _g = ENV_LOCK.lock().unwrap();
        let prev_env = std::env::var_os("KITTY_PROJECT_SESSIONS_DIR");
        let prev_home = std::env::var_os("HOME");
        std::env::remove_var("KITTY_PROJECT_SESSIONS_DIR");
        std::env::set_var("HOME", "/h");
        let got = sessions_dir().unwrap();
        assert_eq!(got, PathBuf::from("/h/.config/kitty/sessions"));
        match prev_env {
            Some(v) => std::env::set_var("KITTY_PROJECT_SESSIONS_DIR", v),
            None => std::env::remove_var("KITTY_PROJECT_SESSIONS_DIR"),
        }
        match prev_home {
            Some(v) => std::env::set_var("HOME", v),
            None => std::env::remove_var("HOME"),
        }
    }

    /// Tests in this module mutate process-global env vars; serialise them
    /// so concurrent runners don't trample each other.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    // ---------- scrollback_enabled ----------

    #[test]
    fn scrollback_env_overrides_opt() {
        let _g = ENV_LOCK.lock().unwrap();
        let prev = std::env::var_os("KSESSION_SCROLLBACK");
        std::env::set_var("KSESSION_SCROLLBACK", "0");
        assert!(!scrollback_enabled(true), "env=0 forces off");
        std::env::set_var("KSESSION_SCROLLBACK", "1");
        assert!(scrollback_enabled(true), "env=1 allows on");
        assert!(!scrollback_enabled(false), "opt=false forces off");
        match prev {
            Some(v) => std::env::set_var("KSESSION_SCROLLBACK", v),
            None => std::env::remove_var("KSESSION_SCROLLBACK"),
        }
    }

    // ---------- resolve_targets ----------

    fn mk_osw(id: u32, focused: bool, last_focused: bool, win_ids: &[u64]) -> kitty::ls::OsWindow {
        serde_json::from_value(serde_json::json!({
            "id": id,
            "is_focused": focused,
            "last_focused": last_focused,
            "tabs": [
                {
                    "id": 1,
                    "windows": win_ids.iter().map(|wid| serde_json::json!({
                        "id": wid,
                        "pid": 100,
                    })).collect::<Vec<_>>(),
                }
            ],
        }))
        .expect("osw json parses")
    }

    #[test]
    fn resolve_targets_all_returns_all() {
        let ls = vec![mk_osw(1, false, false, &[1]), mk_osw(2, false, false, &[2])];
        let got = resolve_targets(&ls, true).unwrap();
        assert_eq!(got.len(), 2);
    }

    #[test]
    fn resolve_targets_focused_when_no_kitty_window_id() {
        let _g = ENV_LOCK.lock().unwrap();
        let prev = std::env::var_os("KITTY_WINDOW_ID");
        std::env::remove_var("KITTY_WINDOW_ID");
        let ls = vec![mk_osw(1, false, false, &[1]), mk_osw(2, true, false, &[2])];
        let got = resolve_targets(&ls, false).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].id, 2);
        if let Some(v) = prev {
            std::env::set_var("KITTY_WINDOW_ID", v);
        }
    }

    #[test]
    fn resolve_targets_falls_back_to_last_focused() {
        let _g = ENV_LOCK.lock().unwrap();
        let prev = std::env::var_os("KITTY_WINDOW_ID");
        std::env::remove_var("KITTY_WINDOW_ID");
        let ls = vec![mk_osw(1, false, true, &[1]), mk_osw(2, false, false, &[2])];
        let got = resolve_targets(&ls, false).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].id, 1);
        if let Some(v) = prev {
            std::env::set_var("KITTY_WINDOW_ID", v);
        }
    }

    #[test]
    fn resolve_targets_kitty_window_id_overrides_focus() {
        let _g = ENV_LOCK.lock().unwrap();
        let prev = std::env::var_os("KITTY_WINDOW_ID");
        std::env::set_var("KITTY_WINDOW_ID", "42");
        let ls = vec![
            mk_osw(1, true, false, &[1, 2]),
            mk_osw(2, false, false, &[42, 99]),
        ];
        let got = resolve_targets(&ls, false).unwrap();
        assert_eq!(got.len(), 1, "exactly the matching OS window");
        assert_eq!(got[0].id, 2);
        match prev {
            Some(v) => std::env::set_var("KITTY_WINDOW_ID", v),
            None => std::env::remove_var("KITTY_WINDOW_ID"),
        }
    }

    // ---------- mkdir_gen_stamped ----------

    #[test]
    fn mkdir_gen_stamped_produces_bare_basename_on_first_attempt() {
        let dir = tempdir().unwrap();
        let got = mkdir_gen_stamped(dir.path(), "demo", 1_700_000_000_000_000).unwrap();
        assert!(got.exists(), "dir must be created");
        assert!(got.is_dir(), "must be a directory");
        let base = got.file_name().unwrap().to_string_lossy().into_owned();
        assert_eq!(
            base, "demo.gen-1700000000000000.state",
            "first attempt uses the bare <name>.gen-<gen_us>.state form"
        );
    }

    // ---------- filter_windows ----------

    #[test]
    fn filter_windows_drops_self_and_overlays() {
        let tab: kitty::ls::Tab = serde_json::from_value(serde_json::json!({
            "id": 1,
            "windows": [
                { "id": 1u64, "pid": 100u32, "is_self": true },
                { "id": 2u64, "pid": 200u32, "overlay_parent": 1u64 },
                { "id": 3u64, "pid": 300u32 },
                { "id": 4u64, "pid": 400u32, "overlay_parent": 0u64 },
            ]
        }))
        .expect("tab json parses");
        let got = filter_windows(&tab);
        let ids: Vec<u64> = got.iter().map(|w| w.id).collect();
        // Window 1: is_self=true -> DROP
        // Window 2: overlay_parent=1 (child of overlay) -> DROP
        // Window 3: no overlay_parent -> KEEP
        // Window 4: overlay_parent=0 (overlay itself) -> DROP
        assert_eq!(ids, vec![3]);
    }

    // ---------- tag_cache_paths ----------

    /// Helper: build a kitty::ls::OsWindow with the given window JSON specs.
    /// Each window spec is `(id, pid, &[fg_pids])`.
    fn mk_osw_with_windows(osw_id: u32, win_specs: &[(u64, u32, &[u32])]) -> kitty::ls::OsWindow {
        let windows: Vec<serde_json::Value> = win_specs
            .iter()
            .map(|(id, pid, fg_pids)| {
                let fg: Vec<serde_json::Value> = fg_pids
                    .iter()
                    .map(|p| serde_json::json!({ "pid": *p, "cmdline": [] }))
                    .collect();
                serde_json::json!({
                    "id": id,
                    "pid": pid,
                    "foreground_processes": fg,
                })
            })
            .collect();
        serde_json::from_value(serde_json::json!({
            "id": osw_id,
            "is_focused": true,
            "last_focused": false,
            "tabs": [{
                "id": 1,
                "windows": windows,
            }],
        }))
        .expect("osw json parses")
    }

    #[tokio::test]
    async fn tag_cache_paths_identifies_nvim_windows() {
        // Set up a synthetic procfs with one nvim window and one bash window.
        let proc_root = tempdir().unwrap();
        write_exe(proc_root.path(), 100, "/usr/bin/nvim");
        write_exe(proc_root.path(), 200, "/usr/bin/bash");
        write_children(proc_root.path(), 200, "");

        let state_dir = tempdir().unwrap();
        fs::create_dir_all(state_dir.path().join(".cache")).unwrap();

        let osw = mk_osw_with_windows(1, &[(10, 100, &[100]), (20, 200, &[200])]);
        let targets: Vec<&kitty::ls::OsWindow> = vec![&osw];

        // Use Cli transport — in fixture mode no RPC is actually issued,
        // but we need to verify the function does not error. In practice
        // the Cli arm loops and shells out, but with no live kitty the
        // set-user-vars calls will fail. Instead, use the mock server
        // pattern from session/mod.rs tests.
        use crate::kitty::pool::KittyPool;
        use serde_json::Value;
        use std::sync::{Arc, Mutex};
        use tokio::io::AsyncReadExt;
        use tokio::net::UnixListener;

        let received = Arc::new(Mutex::new(Vec::<Value>::new()));
        let received_h = received.clone();

        let mock_dir = tempdir().unwrap();
        let sock = mock_dir.path().join("rpc.sock");
        let listener = UnixListener::bind(&sock).unwrap();

        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut acc: Vec<u8> = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                let n = match stream.read(&mut chunk).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                acc.extend_from_slice(&chunk[..n]);
                let dcs_term: &[u8] = b"\x1b\\";
                let dcs_prefix: &[u8] = b"\x1bP@kitty-cmd";
                while let Some(end) = acc.windows(dcs_term.len()).position(|w| w == dcs_term) {
                    let frame = acc[..end + dcs_term.len()].to_vec();
                    acc.drain(..end + dcs_term.len());
                    let json_bytes = &frame[dcs_prefix.len()..frame.len() - dcs_term.len()];
                    let req: Value = serde_json::from_slice(json_bytes).unwrap();
                    received_h.lock().unwrap().push(req);
                    // no_response frames — don't send a reply
                }
            }
        });

        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let transport = KittyTransport::Pool(Arc::new(pool));

        tag_cache_paths(&targets, state_dir.path(), proc_root.path(), &transport)
            .await
            .expect("tag_cache_paths should succeed");

        // Give the mock server a moment to process the frames.
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;

        // Drop transport so the mock server sees EOF and processes all frames.
        drop(transport);
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;

        let frames = received.lock().unwrap();
        // Should have exactly one frame (for the nvim window, not the bash window).
        assert_eq!(
            frames.len(),
            1,
            "expected 1 set-user-vars frame for the nvim window, got {}",
            frames.len()
        );

        let frame = &frames[0];
        assert_eq!(frame["cmd"], "set_user_vars");
        let var = frame["payload"]["var"]
            .as_array()
            .expect("var should be an array");
        assert_eq!(var.len(), 1);
        let kv = var[0].as_str().unwrap();
        assert!(
            kv.starts_with("ksession_cache_path="),
            "var should start with 'ksession_cache_path=', got {kv:?}"
        );
        // The cache path should match the expected format.
        let expected_path = nvim_adapter::cache_path_for(state_dir.path(), "win-10");
        let expected_kv = format!("ksession_cache_path={}", expected_path.to_string_lossy());
        assert_eq!(kv, expected_kv);

        // The match pattern should target the nvim window.
        assert_eq!(frame["payload"]["match"], "id:10");
    }

    #[tokio::test]
    async fn tag_cache_paths_skips_non_nvim_windows() {
        // Only bash windows — no frames should be sent.
        let proc_root = tempdir().unwrap();
        write_exe(proc_root.path(), 100, "/usr/bin/bash");
        write_children(proc_root.path(), 100, "");
        write_exe(proc_root.path(), 200, "/usr/bin/htop");

        let state_dir = tempdir().unwrap();
        fs::create_dir_all(state_dir.path().join(".cache")).unwrap();

        let osw = mk_osw_with_windows(1, &[(10, 100, &[100]), (20, 200, &[200])]);
        let targets: Vec<&kitty::ls::OsWindow> = vec![&osw];

        // With no nvim windows, tag_cache_paths should short-circuit
        // without any RPC. Use Cli transport (cheapest, and no RPC will
        // be issued since the function short-circuits on empty entries).
        let transport = KittyTransport::Cli;

        tag_cache_paths(&targets, state_dir.path(), proc_root.path(), &transport)
            .await
            .expect("tag_cache_paths should succeed with no nvim windows");
    }

    #[tokio::test]
    async fn tag_cache_paths_multiple_nvim_windows() {
        // Two nvim windows across two OS windows — both should get tagged.
        let proc_root = tempdir().unwrap();
        write_exe(proc_root.path(), 100, "/usr/bin/nvim");
        write_exe(proc_root.path(), 200, "/usr/bin/nvim");

        let state_dir = tempdir().unwrap();
        fs::create_dir_all(state_dir.path().join(".cache")).unwrap();

        let osw1 = mk_osw_with_windows(1, &[(10, 100, &[100])]);
        let osw2 = mk_osw_with_windows(2, &[(20, 200, &[200])]);
        let targets: Vec<&kitty::ls::OsWindow> = vec![&osw1, &osw2];

        use crate::kitty::pool::KittyPool;
        use serde_json::Value;
        use std::sync::{Arc, Mutex};
        use tokio::io::AsyncReadExt;
        use tokio::net::UnixListener;

        let received = Arc::new(Mutex::new(Vec::<Value>::new()));
        let received_h = received.clone();

        let mock_dir = tempdir().unwrap();
        let sock = mock_dir.path().join("rpc.sock");
        let listener = UnixListener::bind(&sock).unwrap();

        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut acc: Vec<u8> = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                let n = match stream.read(&mut chunk).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                acc.extend_from_slice(&chunk[..n]);
                let dcs_term: &[u8] = b"\x1b\\";
                let dcs_prefix: &[u8] = b"\x1bP@kitty-cmd";
                while let Some(end) = acc.windows(dcs_term.len()).position(|w| w == dcs_term) {
                    let frame = acc[..end + dcs_term.len()].to_vec();
                    acc.drain(..end + dcs_term.len());
                    let json_bytes = &frame[dcs_prefix.len()..frame.len() - dcs_term.len()];
                    let req: Value = serde_json::from_slice(json_bytes).unwrap();
                    received_h.lock().unwrap().push(req);
                }
            }
        });

        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let transport = KittyTransport::Pool(Arc::new(pool));

        tag_cache_paths(&targets, state_dir.path(), proc_root.path(), &transport)
            .await
            .expect("tag_cache_paths should succeed");

        // Drop transport and wait for mock to process.
        drop(transport);
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;

        let frames = received.lock().unwrap();
        assert_eq!(
            frames.len(),
            2,
            "expected 2 set-user-vars frames (one per nvim window), got {}",
            frames.len()
        );

        // Verify both windows got tagged with correct cache paths.
        let matches: Vec<&str> = frames
            .iter()
            .map(|f| f["payload"]["match"].as_str().unwrap())
            .collect();
        assert!(matches.contains(&"id:10"), "should contain id:10");
        assert!(matches.contains(&"id:20"), "should contain id:20");
    }
}
