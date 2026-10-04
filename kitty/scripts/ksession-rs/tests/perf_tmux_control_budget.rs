//! Performance benchmark: control-mode RPC vs subprocess-per-call.
//!
//! Measures the latency improvement of `TmuxControl` (persistent
//! `tmux -C attach` pipe) over `TmuxCli` (fork-per-call subprocess)
//! by replaying the full adapter query pattern against an isolated
//! tmux server with a realistic workload (4 windows x 2 panes each).
//!
//! Run with:
//!   cargo test --release --test perf_tmux_control_budget -- --ignored --nocapture

mod helpers;

use std::path::Path;
use std::sync::{LazyLock, Mutex};

use helpers::tmux::{tmux_available, IsolatedTmux};
use ksession_rs::perf;
use ksession_rs::tmux_rpc::{tmux_version, TmuxControl, TmuxIo};

// --- Shared tracer (once per process) ----------------------------------------

static TRACE_DIR: LazyLock<tempfile::TempDir> = LazyLock::new(|| {
    let dir = tempfile::tempdir().expect("tempdir for traces");
    perf::tracer::install(dir.path(), perf::Level::Debug).expect("tracer install");
    dir
});

/// Serialise benchmarks so spans from different runs don't interleave.
static BENCH_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

fn reset_trace_dir(dir: &Path) {
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("jsonl") {
            if let Ok(f) = std::fs::OpenOptions::new().write(true).open(&p) {
                let _ = f.set_len(0);
            }
        }
    }
}

// --- Workload ----------------------------------------------------------------

/// Isolated tmux server: 1 session (`bench`), 4 windows, 2 panes each.
/// Scrollback seeded with `seq 1 100` per pane.
fn bench_server() -> IsolatedTmux {
    let server = IsolatedTmux::builder("bench").spawn();
    let session = server.session.as_str();

    // Add 3 more windows (total 4).
    for _ in 0..3 {
        server.run(&["new-window", "-t", session]);
    }

    // Split each window to get 2 panes per window (8 panes total).
    for win_idx in 0..4 {
        server.run(&["split-window", "-t", &format!("{session}:{win_idx}")]);
    }

    // Seed scrollback: run `seq 1 100` in every pane.
    for win_idx in 0..4 {
        for pane_idx in 0..2 {
            let target = format!("{session}:{win_idx}.{pane_idx}");
            server.run(&["send-keys", "-t", &target, "seq 1 100", "Enter"]);
        }
    }

    // Wait briefly for commands to execute so scrollback is populated.
    std::thread::sleep(std::time::Duration::from_millis(500));
    server
}

// --- Query pattern -----------------------------------------------------------

/// Replay the full tmux adapter query pattern against the given transport.
///
/// This is the exact sequence the adapter performs during a save:
/// - 1 list-clients call (find_session_for_client_pid)
/// - 1 list-windows call + 4 display-message per window (name, automatic-rename, layout, active)
/// - Per window: 1 list-panes + 5 display-message per pane (index, pid, cwd, cmd, active)
///
/// Total for 4 windows x 2 panes: 1 + 1 + 16 + 4*(1 + 10) = 62 calls.
async fn run_adapter_queries(tmux: &dyn TmuxIo, session: &str) -> Result<(), String> {
    // 1. list-clients (find_session_for_client_pid equivalent)
    tmux.run(&[
        "list-clients",
        "-F",
        "#{client_pid} #{session_id} #{session_name}",
    ])
    .await
    .map_err(|e| format!("list-clients: {e}"))?;

    // 2. list-windows
    let raw = tmux
        .run(&["list-windows", "-t", session, "-F", "#{window_index}"])
        .await
        .map_err(|e| format!("list-windows: {e}"))?;

    let win_indices: Vec<u32> = raw
        .lines()
        .filter_map(|l| l.trim().parse::<u32>().ok())
        .collect();

    // 3. Per-window display-message (name, automatic-rename, layout, active)
    for &win_idx in &win_indices {
        let target = format!("{session}:{win_idx}");
        tmux.run(&["display-message", "-p", "-t", &target, "#{window_name}"])
            .await
            .map_err(|e| format!("display-message window_name: {e}"))?;
        tmux.run(&["display-message", "-p", "-t", &target, "#{automatic-rename}"])
            .await
            .map_err(|e| format!("display-message automatic-rename: {e}"))?;
        tmux.run(&["display-message", "-p", "-t", &target, "#{window_layout}"])
            .await
            .map_err(|e| format!("display-message window_layout: {e}"))?;
        tmux.run(&["display-message", "-p", "-t", &target, "#{window_active}"])
            .await
            .map_err(|e| format!("display-message window_active: {e}"))?;
    }

    // 4. Per-window: list-panes + per-pane display-message
    for &win_idx in &win_indices {
        let target = format!("{session}:{win_idx}");
        let raw = tmux
            .run(&["list-panes", "-t", &target, "-F", "#{pane_id}"])
            .await
            .map_err(|e| format!("list-panes: {e}"))?;

        let pane_ids: Vec<String> = raw
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect();

        for pane_id in &pane_ids {
            tmux.run(&["display-message", "-p", "-t", pane_id, "#{pane_index}"])
                .await
                .map_err(|e| format!("display-message pane_index: {e}"))?;
            tmux.run(&["display-message", "-p", "-t", pane_id, "#{pane_pid}"])
                .await
                .map_err(|e| format!("display-message pane_pid: {e}"))?;
            tmux.run(&[
                "display-message",
                "-p",
                "-t",
                pane_id,
                "#{pane_current_path}",
            ])
            .await
            .map_err(|e| format!("display-message pane_current_path: {e}"))?;
            tmux.run(&[
                "display-message",
                "-p",
                "-t",
                pane_id,
                "#{pane_current_command}",
            ])
            .await
            .map_err(|e| format!("display-message pane_current_command: {e}"))?;
            tmux.run(&["display-message", "-p", "-t", pane_id, "#{pane_active}"])
                .await
                .map_err(|e| format!("display-message pane_active: {e}"))?;
        }
    }

    Ok(())
}

// --- Benchmark ---------------------------------------------------------------

const ITERATIONS: usize = 30;

#[tokio::test]
#[ignore = "performance benchmark - run manually with --ignored"]
async fn benchmark_tmux_control_vs_subprocess() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    let _guard = BENCH_LOCK.lock().unwrap();
    let trace_dir = TRACE_DIR.path();

    let server = bench_server();

    // ── Baseline: subprocess (TmuxCli) ──────────────────────────────

    // TmuxCli uses the default server socket. We need it to talk to our
    // isolated server, so set TMUX_TMPDIR... actually, TmuxCli doesn't
    // support socket selection. We'll use it via the run() interface
    // by wrapping each call with the -L flag baked into the args.
    //
    // Instead of TmuxCli (which has no socket override), create a thin
    // adapter that prepends `-L <socket>` to every invocation.
    let subprocess_io = SocketTmuxCli {
        socket_name: server.socket_name.clone(),
    };

    reset_trace_dir(trace_dir);
    println!("\n=== Benchmark: tmux subprocess (TmuxCli pattern) ===");
    println!("Running {ITERATIONS} iterations...");

    for i in 0..ITERATIONS {
        let _span = ksession_rs::perf_span!(perf::Level::Debug, "bench.tmux.subprocess");
        if let Err(e) = run_adapter_queries(&subprocess_io, &server.session).await {
            panic!("subprocess iteration {i} failed: {e}");
        }
    }

    let subprocess_stats = perf::stats::summarise(trace_dir, "bench.tmux.subprocess");
    let sub_s = subprocess_stats
        .get("bench.tmux.subprocess")
        .expect("bench.tmux.subprocess span not found in trace output");

    println!("Results (subprocess):");
    println!(
        "  Count: {}  Mean: {:.1} ms  p50: {:.1} ms  p95: {:.1} ms  p99: {:.1} ms",
        sub_s.count,
        sub_s.mean_ms(),
        sub_s.p50_ms(),
        sub_s.p95_ms(),
        sub_s.p99_ms()
    );
    println!(
        "  Min: {:.1} ms  Max: {:.1} ms",
        sub_s.min_ms(),
        sub_s.max_ms()
    );

    // ── Control-mode (TmuxControl) ──────────────────────────────────

    reset_trace_dir(trace_dir);
    println!("\n=== Benchmark: tmux control-mode (TmuxControl) ===");
    println!("Running {ITERATIONS} iterations...");

    let ctrl = TmuxControl::connect(&server.socket_path, server.sid, tmux_version())
        .await
        .expect("TmuxControl::connect");

    for i in 0..ITERATIONS {
        let _span = ksession_rs::perf_span!(perf::Level::Debug, "bench.tmux.control");
        if let Err(e) = run_adapter_queries(&ctrl, &server.session).await {
            panic!("control-mode iteration {i} failed: {e}");
        }
    }

    let _ = ctrl.shutdown().await;

    let control_stats = perf::stats::summarise(trace_dir, "bench.tmux.control");
    let ctrl_s = control_stats
        .get("bench.tmux.control")
        .expect("bench.tmux.control span not found in trace output");

    println!("Results (control-mode):");
    println!(
        "  Count: {}  Mean: {:.1} ms  p50: {:.1} ms  p95: {:.1} ms  p99: {:.1} ms",
        ctrl_s.count,
        ctrl_s.mean_ms(),
        ctrl_s.p50_ms(),
        ctrl_s.p95_ms(),
        ctrl_s.p99_ms()
    );
    println!(
        "  Min: {:.1} ms  Max: {:.1} ms",
        ctrl_s.min_ms(),
        ctrl_s.max_ms()
    );

    // ── Summary ─────────────────────────────────────────────────────

    println!("\n=== Side-by-side comparison ===");
    println!(
        "  {:>20}  {:>10}  {:>10}  {:>10}",
        "", "p50 (ms)", "p95 (ms)", "mean (ms)"
    );
    println!(
        "  {:>20}  {:>10.1}  {:>10.1}  {:>10.1}",
        "Subprocess",
        sub_s.p50_ms(),
        sub_s.p95_ms(),
        sub_s.mean_ms()
    );
    println!(
        "  {:>20}  {:>10.1}  {:>10.1}  {:>10.1}",
        "Control-mode",
        ctrl_s.p50_ms(),
        ctrl_s.p95_ms(),
        ctrl_s.mean_ms()
    );
    if sub_s.p50_ms() > 0.0 {
        println!(
            "  {:>20}  {:>9.1}x  {:>9.1}x  {:>9.1}x",
            "Speedup",
            sub_s.p50_ms() / ctrl_s.p50_ms(),
            sub_s.p95_ms() / ctrl_s.p95_ms(),
            sub_s.mean_ms() / ctrl_s.mean_ms()
        );
    }

    // ── Assert PRD budget ───────────────────────────────────────────

    assert_eq!(
        sub_s.count, ITERATIONS,
        "expected {ITERATIONS} subprocess spans, got {}",
        sub_s.count
    );
    assert_eq!(
        ctrl_s.count, ITERATIONS,
        "expected {ITERATIONS} control-mode spans, got {}",
        ctrl_s.count
    );

    assert!(
        ctrl_s.p95_ms() <= 50.0,
        "control-mode p95 {:.1}ms exceeds PRD budget of 50ms",
        ctrl_s.p95_ms()
    );
}

// --- Socket-aware subprocess transport ---------------------------------------

/// A `TmuxIo` implementation that uses subprocess spawning (like `TmuxCli`)
/// but targets a specific tmux server via `-L <socket_name>`. This lets us
/// benchmark the subprocess pattern against the same isolated server the
/// control-mode transport uses.
struct SocketTmuxCli {
    socket_name: String,
}

#[async_trait::async_trait]
impl TmuxIo for SocketTmuxCli {
    async fn run(&self, args: &[&str]) -> Result<String, ksession_rs::tmux_rpc::TmuxError> {
        use ksession_rs::tmux_rpc::TmuxError;
        use std::process::Stdio;

        let mut cmd = tokio::process::Command::new("tmux");
        cmd.args(["-L", &self.socket_name]);
        cmd.args(args);
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());

        let output = tokio::time::timeout(std::time::Duration::from_secs(5), cmd.output())
            .await
            .map_err(|_| TmuxError::Timeout)?
            .map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => TmuxError::NotInstalled,
                _ => TmuxError::Io(e),
            })?;

        if !output.status.success() {
            return Err(TmuxError::Subprocess {
                subcommand: args.first().map(|s| (*s).to_string()).unwrap_or_default(),
                status: output.status.code().unwrap_or(-1),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            });
        }

        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }

    async fn capture_pane_to_file(
        &self,
        _pane_id: &str,
        _dest: &Path,
        _ansi: bool,
    ) -> Result<u64, ksession_rs::tmux_rpc::TmuxError> {
        // Not used in this benchmark.
        unimplemented!("capture_pane_to_file not needed for the benchmark")
    }
}
