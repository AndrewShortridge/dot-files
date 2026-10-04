//! Thin CLI dispatcher for the `ksession` binary.
//!
//! `show`, `save`, and `list` are wired through to the orchestration in
//! `ksession_rs::session`. The remaining subcommands still defer to
//! `ksession.sh` until later steps land them.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use std::process::ExitCode;

use clap::Parser;
use ksession_rs::cli::{trace as cli_trace, Cli, Command, TraceMode};
use ksession_rs::session::{self, manifest};

fn main() -> ExitCode {
    // Initialize logging
    ksession_rs::log::init();

    // Pre-spawn: if argv[1] == "save", kick off pool discovery + pre-warm
    // on a background thread so it overlaps the ~3 ms clap parse below.
    let maybe_prespawn = peek_save_prespawn();

    // Parse CLI first so we can inspect `--trace` before `maybe_init`.
    let cli = Cli::parse();

    // If --trace is active on save/restore, set up env vars for the
    // tracer BEFORE calling maybe_init(). This ensures the OnceLock-
    // guarded tracer picks up the auto-generated trace dir.
    let trace_ctx = setup_trace_env(&cli.command);

    // Initialize perf tracer iff `KSESSION_TRACE_DIR` is set.
    // No-op (one atomic load) when unset; see PRD-0 / ADR 0004.
    ksession_rs::perf::maybe_init();

    match run(cli, trace_ctx, maybe_prespawn) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("ksession: {e:#}");
            ExitCode::from(1)
        }
    }
}

/// If `argv[1] == "save"`, spawn blocking socket discovery + pre-warm on a
/// background thread. Returns a `JoinHandle` that resolves to raw std
/// streams (not runtime-bound). The streams are converted to tokio on the
/// main runtime inside `block_on` before being passed to `session::save()`.
fn peek_save_prespawn() -> Option<
    std::thread::JoinHandle<Result<ksession_rs::kitty::PreSpawnResult, ksession_rs::error::KError>>,
> {
    if std::env::args().nth(1).as_deref() != Some("save") {
        return None;
    }
    Some(std::thread::spawn(|| {
        ksession_rs::kitty::KittyPool::discover_and_warm_blocking(
            ksession_rs::kitty::KittyPool::capacity_from_env(),
        )
    }))
}

/// Context carried from pre-init trace setup to post-operation dispatch.
struct TraceCtx {
    mode: TraceMode,
    trace_dir: PathBuf,
    /// The operation kind, for directory naming. Currently used only
    /// during setup_trace_env; kept for future diagnostic messages.
    #[allow(dead_code)]
    kind: &'static str,
}

/// Inspect the parsed CLI command. If `--trace` is not `off`, generate the
/// trace directory path, create it, and set the env vars that
/// `perf::maybe_init()` reads. Returns `None` when tracing is off.
fn setup_trace_env(command: &Command) -> Option<TraceCtx> {
    let (mode, name, kind) = match command {
        Command::Save { trace, name, .. } => (*trace, name.as_str(), "save"),
        Command::Restore { trace, name, .. } => (*trace, name.as_str(), "restore"),
        _ => return None,
    };

    if mode == TraceMode::Off {
        return None;
    }

    // Check for a user-supplied KSESSION_TRACE_DIR. If set, the user's
    // value wins for the directory but --trace still controls the output
    // mode. Warn on stderr about the override.
    let user_trace_dir = std::env::var_os("KSESSION_TRACE_DIR").map(PathBuf::from);
    let trace_dir = if let Some(ref user_dir) = user_trace_dir {
        eprintln!(
            "ksession: warning: KSESSION_TRACE_DIR is already set to {}; \
             --trace flag controls output mode only, directory unchanged",
            user_dir.display()
        );
        user_dir.clone()
    } else {
        // Auto-generate: ~/.cache/ksession/traces/<rfc3339-ts>-<kind>-<name>/
        let ts = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let dir_name = format!("{ts}-{kind}-{name}");
        let traces_root = cli_trace::traces_root().unwrap_or_else(|| {
            PathBuf::from(
                std::env::var_os("HOME").unwrap_or_else(|| std::ffi::OsString::from("/tmp")),
            )
            .join(".cache/ksession/traces")
        });
        traces_root.join(dir_name)
    };

    // Create the trace directory.
    if let Err(e) = std::fs::create_dir_all(&trace_dir) {
        eprintln!(
            "ksession: warning: could not create trace dir {}: {e}",
            trace_dir.display()
        );
        return None;
    }

    // Set the env vars that maybe_init() reads.
    if user_trace_dir.is_none() {
        std::env::set_var("KSESSION_TRACE_DIR", &trace_dir);
    }

    // Set KSESSION_TRACE_LEVEL to "trace" for full resolution, unless
    // the user already set it (let their value win for --trace=tree per
    // spec: "KSESSION_TRACE_LEVEL=debug ksession save x --trace=tree").
    if std::env::var_os("KSESSION_TRACE_LEVEL").is_none() {
        std::env::set_var("KSESSION_TRACE_LEVEL", "trace");
    }

    Some(TraceCtx {
        mode,
        trace_dir,
        kind,
    })
}

fn run(
    cli: Cli,
    trace_ctx: Option<TraceCtx>,
    maybe_prespawn: Option<
        std::thread::JoinHandle<
            Result<ksession_rs::kitty::PreSpawnResult, ksession_rs::error::KError>,
        >,
    >,
) -> anyhow::Result<ExitCode> {
    match cli.command {
        Command::Show { name } => {
            session::show::run(&name)?;
            Ok(ExitCode::SUCCESS)
        }
        Command::Save {
            name,
            all,
            no_scrollback,
            trace: _,
        } => {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?;
            let sessions_dir = session::sessions_dir()
                .map_err(|e| anyhow::anyhow!("resolve sessions dir: {e}"))?;
            std::fs::create_dir_all(&sessions_dir)?;

            // Resolve KSESSION_FROM_LS env var for deterministic fixture-based testing.
            let from_ls = std::env::var_os("KSESSION_FROM_LS").map(PathBuf::from);
            // Also support KSESSION_SKELETON for deterministic skeleton fixture.
            let from_skeleton = std::env::var_os("KSESSION_SKELETON").map(PathBuf::from);

            // Join the pre-spawn thread (blocking std streams), then convert
            // to tokio inside block_on where the runtime is active.
            let prespawn_result = maybe_prespawn.and_then(|handle| match handle.join() {
                Ok(Ok(result)) => Some(result),
                Ok(Err(_e)) => None,
                Err(_) => None,
            });

            let outcome = rt
                .block_on(async {
                    let pre_pool = prespawn_result.and_then(|result| {
                        ksession_rs::kitty::KittyPool::from_prespawn(result).ok()
                    });
                    session::save(session::SaveOpts {
                        name,
                        all,
                        scrollback: !no_scrollback,
                        sessions_dir,
                        from_ls,
                        from_skeleton,
                        pre_pool,
                    })
                    .await
                })
                .map_err(|e| anyhow::anyhow!("ksession save failed: {e}"))?;

            // Slice 11: touch the ready marker after a successful save.
            // Gated on KSESSION_TRACE_DIR — without a trace dir there is
            // no directory to write to.
            ksession_rs::perf::ready::touch_ready_if_tracing("rust");

            // Slice 12: post-save trace output dispatch.
            if let Some(ctx) = trace_ctx {
                dispatch_trace_output(&ctx)?;
            }

            // ADR 0001: per-window degradations commit the save but exit
            // with code 2 so `ksession-save-prompt.sh` can surface a
            // "saved with N degradations" badge in the overlay.
            if outcome.degraded_any {
                Ok(ExitCode::from(2))
            } else {
                Ok(ExitCode::SUCCESS)
            }
        }
        Command::Rm { name } => {
            let sessions_dir = session::sessions_dir()
                .map_err(|e| anyhow::anyhow!("resolve sessions dir: {e}"))?;
            session::rm::run(session::rm::RmOpts { name, sessions_dir })
                .map_err(|e| anyhow::anyhow!("ksession rm failed: {e}"))?;
            Ok(ExitCode::SUCCESS)
        }
        Command::Restore {
            name,
            trace,
            into_current,
        } => {
            let sessions_dir = session::sessions_dir()
                .map_err(|e| anyhow::anyhow!("resolve sessions dir: {e}"))?;

            if into_current {
                // Into-current restore: load session into existing kitty instance
                session::restore::run_into_current(&name, &sessions_dir)
                    .map_err(|e| anyhow::anyhow!("ksession restore --into-current failed: {e}"))?;
            } else {
                match trace {
                    TraceMode::Off => {
                        // Normal restore: detach immediately.
                        session::restore::run(&name, &sessions_dir)
                            .map_err(|e| anyhow::anyhow!("ksession restore failed: {e}"))?;
                    }
                    TraceMode::Tree => {
                        // Tree mode: spawn kitty WITHOUT --detach, then block
                        // until ready markers fire, then render the tree.
                        run_restore_tree(&name, &sessions_dir, &trace_ctx)?;
                    }
                    TraceMode::Chrome => {
                        // Chrome mode: detach normally, then spawn a background
                        // waiter that writes chrome.json after ready markers.
                        run_restore_chrome(&name, &sessions_dir, &trace_ctx)?;
                    }
                }
            }

            Ok(ExitCode::SUCCESS)
        }
        Command::List => {
            run_list()?;
            Ok(ExitCode::SUCCESS)
        }
        Command::Trace { command } => cli_trace::run(command),
        // Typed errors stay inside the lib; the binary boundary turns them
        // into the `ksession: tmux: …` stderr line + exit 1 the scripts key on.
        Command::Tmux { command } => match ksession_rs::tmux_session::run(command) {
            Ok(code) => Ok(code),
            Err(e) => {
                eprintln!("ksession: tmux: {e}");
                Ok(ExitCode::from(1))
            }
        },
    }
}

/// Dispatch trace output after save completes (Slice 12).
fn dispatch_trace_output(ctx: &TraceCtx) -> anyhow::Result<()> {
    match ctx.mode {
        TraceMode::Off => Ok(()),
        TraceMode::Tree => {
            let tree = cli_trace::render_tree_from_dir(&ctx.trace_dir)?;
            let stderr = std::io::stderr();
            let mut handle = stderr.lock();
            handle.write_all(tree.as_bytes())?;
            Ok(())
        }
        TraceMode::Chrome => {
            let chrome_path = ctx.trace_dir.join("chrome.json");
            cli_trace::write_chrome_to_file(&ctx.trace_dir, &chrome_path)?;
            eprintln!("ksession: trace: {}", chrome_path.display());
            Ok(())
        }
    }
}

/// Restore with `--trace=tree`: run kitty without `--detach`, wait for
/// ready markers, then render the tree to stderr.
fn run_restore_tree(
    name: &str,
    sessions_dir: &Path,
    trace_ctx: &Option<TraceCtx>,
) -> anyhow::Result<()> {
    let plan = session::restore::plan_restore(name, sessions_dir)
        .map_err(|e| anyhow::anyhow!("ksession restore failed: {e}"))?;

    if let Some(line) = &plan.drift_warning {
        eprintln!("{line}");
    }

    // Build argv without --detach. The plan includes --detach by default;
    // filter it out for tree mode.
    let argv: Vec<&str> = plan
        .argv
        .iter()
        .map(|s| s.as_str())
        .filter(|s| *s != "--detach")
        .collect();

    // Spawn kitty and wait for it to exit.
    let mut cmd = std::process::Command::new(argv[0]);
    cmd.args(&argv[1..]);
    let mut child = {
        let _launch = ksession_rs::perf_span!(ksession_rs::perf::Level::Info, "kitty.launch");
        cmd.spawn()
            .map_err(|e| anyhow::anyhow!("spawn kitty: {e}"))?
    };

    // Build a tokio runtime to run wait_for_all.
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;

    if let Some(ctx) = trace_ctx {
        // Count expected markers from the manifest.
        let expected = count_expected_markers(name, sessions_dir);
        let timeout = ksession_rs::perf::ready::ready_timeout_from_env(
            ksession_rs::perf::ready::DEFAULT_TIMEOUT_MS,
        );

        let td = ctx.trace_dir.clone();
        let result = rt.block_on(async {
            ksession_rs::perf::ready::wait_for_all_with_span(&td, expected, timeout).await
        });

        if let Err(e) = result {
            eprintln!("ksession: warning: {e}");
        }

        // Render the tree.
        let tree = cli_trace::render_tree_from_dir(&ctx.trace_dir)?;
        let stderr = std::io::stderr();
        let mut handle = stderr.lock();
        handle.write_all(tree.as_bytes())?;
    }

    // Reap the child process if it hasn't exited yet.
    let _ = child.wait();

    Ok(())
}

/// Restore with `--trace=chrome`: detach normally, spawn a background
/// thread that waits for ready markers then writes chrome.json.
fn run_restore_chrome(
    name: &str,
    sessions_dir: &Path,
    trace_ctx: &Option<TraceCtx>,
) -> anyhow::Result<()> {
    // Normal detaching restore.
    session::restore::run(name, sessions_dir)
        .map_err(|e| anyhow::anyhow!("ksession restore failed: {e}"))?;

    if let Some(ctx) = trace_ctx {
        let chrome_path = ctx.trace_dir.join("chrome.json");
        eprintln!("ksession: trace: {} (pending)", chrome_path.display());

        let trace_dir = ctx.trace_dir.clone();
        let expected = count_expected_markers(name, sessions_dir);
        let timeout = ksession_rs::perf::ready::ready_timeout_from_env(
            ksession_rs::perf::ready::DEFAULT_TIMEOUT_MS,
        );

        // Spawn a background thread that waits then writes.
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("tokio runtime");
            let td = trace_dir.clone();
            let result = rt.block_on(async {
                ksession_rs::perf::ready::wait_for_all_with_span(&td, expected, timeout).await
            });
            if let Err(e) = result {
                eprintln!("ksession: warning: {e}");
            }
            let chrome = trace_dir.join("chrome.json");
            if let Err(e) = cli_trace::write_chrome_to_file(&trace_dir, &chrome) {
                eprintln!("ksession: warning: failed to write chrome.json: {e}");
            }
        })
        .join()
        .ok();
    }

    Ok(())
}

/// Count expected ready markers for a restore: 1 (rust) + count of
/// `Program::Tmux` + count of `Program::Nvim` in the manifest.
fn count_expected_markers(name: &str, sessions_dir: &Path) -> usize {
    let manifest_path = sessions_dir
        .join(format!("{name}.state"))
        .join("manifest.json");
    if !manifest_path.exists() {
        // No manifest — fall back to just the rust marker.
        return 1;
    }
    let loaded = match manifest::read_no_drift(&manifest_path) {
        Ok(l) => l,
        Err(_) => return 1,
    };
    let mut count = 1usize; // rust
    for osw in &loaded.session.os_windows {
        for tab in &osw.tabs {
            for win in &tab.windows {
                match &win.program {
                    ksession_rs::model::Program::Tmux { .. } => count += 1,
                    ksession_rs::model::Program::Nvim { .. } => count += 1,
                    _ => {}
                }
            }
        }
    }
    count
}

/// `ksession list` dispatcher (PRD issue #06).
///
/// Enumerates `<sessions_dir>/*.conf`, attempts `session::manifest::read_no_drift`
/// for each, and prints one tab-aligned line per session sorted by
/// `created_at` descending. A manifest that fails to read still produces
/// an output line with a `(no manifest)` marker so the user knows the
/// session exists even when its sidecar state is missing or corrupt.
///
/// Manifest path resolution mirrors the on-disk layout written by
/// `session::save`: the canonical home is
/// `<sessions_dir>/<name>.gen-<ts>.state/manifest.json` (the conf body
/// embeds the gen-stamped reference). We fall back to the Bash-era
/// `<sessions_dir>/<name>.state/manifest.json` for legacy artifacts that
/// `show` also reads (kept here so the two subcommands agree).
fn run_list() -> anyhow::Result<()> {
    let sessions_dir =
        session::sessions_dir().map_err(|e| anyhow::anyhow!("resolve sessions dir: {e}"))?;

    // Missing sessions dir is not an error — print nothing and exit 0.
    let entries = match fs::read_dir(&sessions_dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => {
            return Err(anyhow::anyhow!(
                "read sessions dir {}: {e}",
                sessions_dir.display()
            ));
        }
    };

    // Collect (name, conf_path) for every `*.conf` (skipping `.conf.tmp.<pid>`).
    let mut confs: Vec<(String, PathBuf)> = Vec::new();
    for ent in entries.flatten() {
        let path = ent.path();
        let Some(fname) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        // `.conf` suffix with non-empty stem; skip `.conf.tmp.*` which has
        // `.conf` mid-string but a different suffix.
        if let Some(stem) = fname.strip_suffix(".conf") {
            if !stem.is_empty() {
                confs.push((stem.to_string(), path));
            }
        }
    }

    // Empty: print nothing and exit 0.
    if confs.is_empty() {
        return Ok(());
    }

    // Resolve a Row per conf. Manifest read failures produce a `(no manifest)`
    // sentinel Row so the loop continues for sibling sessions.
    struct Row {
        name: String,
        created_at: Option<chrono::DateTime<chrono::Utc>>,
        kitty_version: String,
        window_count: Option<usize>,
        marker: Option<&'static str>,
    }

    let mut rows: Vec<Row> = confs
        .into_iter()
        .map(|(name, conf_path)| {
            let manifest_path = resolve_manifest_path(&sessions_dir, &name, &conf_path);
            match manifest_path.and_then(|p| manifest::read_no_drift(&p).ok()) {
                Some(loaded) => Row {
                    name: loaded.session.name.clone(),
                    created_at: Some(loaded.session.created_at),
                    kitty_version: loaded.session.kitty_version.clone(),
                    window_count: Some(count_windows(&loaded.session)),
                    marker: None,
                },
                None => Row {
                    name,
                    created_at: None,
                    kitty_version: String::new(),
                    window_count: None,
                    marker: Some("(no manifest)"),
                },
            }
        })
        .collect();

    // Sort by created_at desc; sessions with no manifest sort last
    // (stable within their group) so the listing's "live" sessions
    // appear above any broken ones.
    rows.sort_by(|a, b| match (a.created_at, b.created_at) {
        (Some(x), Some(y)) => y.cmp(&x),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });

    // Tab-aligned output: name<TAB>created_at<TAB>kitty_version<TAB>windows
    for row in rows {
        match row.marker {
            Some(m) => println!("{}\t{}", row.name, m),
            None => println!(
                "{}\t{}\t{}\t{} window(s)",
                row.name,
                row.created_at
                    .map(|t| t.format("%Y-%m-%dT%H:%M:%SZ").to_string())
                    .unwrap_or_default(),
                if row.kitty_version.is_empty() {
                    "-"
                } else {
                    row.kitty_version.as_str()
                },
                row.window_count.unwrap_or(0),
            ),
        }
    }

    Ok(())
}

/// Pick a manifest path for `<name>.conf`.
///
/// Order:
/// 1. `<sessions_dir>/<name>.state/manifest.json` (Bash-era layout, also
///    used by `session::show`). Cheap stat — preferred when present.
/// 2. Scan the conf body for an embedded `<name>.gen-<digits>.state` path
///    and resolve `<sessions_dir>/<that_basename>/manifest.json` (the
///    canonical Rust-side layout written by `session::save`).
/// 3. As a last-ditch fallback, glob `<sessions_dir>/<name>.gen-*.state/`
///    and pick the lexicographically-greatest (which is also the largest
///    `gen_us` since the timestamp is a fixed-width-ish suffix).
///
/// Returns `None` if no candidate exists; the caller renders a
/// `(no manifest)` row in that case.
fn resolve_manifest_path(sessions_dir: &Path, name: &str, conf_path: &Path) -> Option<PathBuf> {
    // (1) Legacy `<name>.state/manifest.json`.
    let legacy = sessions_dir
        .join(format!("{name}.state"))
        .join("manifest.json");
    if legacy.exists() {
        return Some(legacy);
    }

    // (2) Scan the conf body for a gen-stamped reference.
    if let Ok(body) = fs::read_to_string(conf_path) {
        let needle = format!("{name}.gen-");
        if let Some(pos) = body.find(&needle) {
            // Walk forward to `.state` and confirm it's the boundary.
            let after = &body[pos + needle.len()..];
            // Accept digits, then optional `_digits`, then `.state`.
            let mut i = 0usize;
            let bytes = after.as_bytes();
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            if i > 0 && i < bytes.len() && bytes[i] == b'_' {
                let pid_start = i + 1;
                let mut j = pid_start;
                while j < bytes.len() && bytes[j].is_ascii_digit() {
                    j += 1;
                }
                if j > pid_start {
                    i = j;
                }
            }
            if after[i..].starts_with(".state") {
                let basename = format!("{name}.gen-{}.state", &after[..i]);
                let candidate = sessions_dir.join(&basename).join("manifest.json");
                if candidate.exists() {
                    return Some(candidate);
                }
            }
        }
    }

    // (3) Directory glob: pick the newest `<name>.gen-*.state/`.
    if let Ok(entries) = fs::read_dir(sessions_dir) {
        let prefix = format!("{name}.gen-");
        let mut best: Option<String> = None;
        for ent in entries.flatten() {
            let Some(fname) = ent.file_name().to_str().map(|s| s.to_string()) else {
                continue;
            };
            if fname.starts_with(&prefix) && fname.ends_with(".state") {
                match &best {
                    None => best = Some(fname),
                    Some(cur) if fname > *cur => best = Some(fname),
                    _ => {}
                }
            }
        }
        if let Some(b) = best {
            let candidate = sessions_dir.join(&b).join("manifest.json");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }

    None
}

/// Count every `Window` across every tab in every OS window. Used as a
/// rough "size of session" hint in the list output.
fn count_windows(s: &ksession_rs::model::SessionFile) -> usize {
    s.os_windows
        .iter()
        .flat_map(|osw| osw.tabs.iter())
        .map(|tab| tab.windows.len())
        .sum()
}
