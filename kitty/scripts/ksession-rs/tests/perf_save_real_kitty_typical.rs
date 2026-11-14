//! Performance benchmark: save orchestration against a **real** kitty instance
//! with a typical workload (3-4 tabs, 6-10 windows, nvim + tmux).
//!
//! Unlike `perf_save_budget` which uses a mock kitty server, this test spawns
//! a real kitty terminal via `KittySpawner`, sets up a realistic workspace,
//! and measures actual end-to-end save latency including IPC overhead.
//!
//! Run with:
//!   cargo test --release --test perf_save_real_kitty_typical -- --ignored --nocapture

mod helpers;

use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use helpers::{kitten_is_usable, kitty_is_usable, tmux_is_usable, KittySpawner};
use ksession_rs::perf;
use ksession_rs::session::{save, SaveOpts};
use tempfile::tempdir;

// ── Tracer setup ────────────────────────────────────────────────────

static TRACE_DIR: LazyLock<PathBuf> = LazyLock::new(|| {
    let dir = std::env::var_os("KSESSION_TRACE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/ksession-save-real-typical-trace"));
    std::fs::create_dir_all(&dir).expect("create trace dir");
    perf::tracer::install(&dir, perf::Level::Info).expect("tracer install");
    dir
});

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

// ── Prerequisite checks ─────────────────────────────────────────────

fn nvim_is_usable() -> bool {
    std::process::Command::new("nvim")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// ── Benchmark ───────────────────────────────────────────────────────

/// Typical workload benchmark against a real kitty instance.
///
/// Layout:
///   - Tab 1 ("code"): 3 shell windows + 1 nvim instance
///   - Tab 2 ("infra"): 2 shell windows
///   - Tab 3 ("tmux"): 1 window with tmux attached
///   - Tab 4 ("misc"): 2 shell windows
///
/// Total: 4 tabs, ~9 windows, 1 nvim, 1 tmux session.
#[tokio::test]
#[ignore = "requires kitty + kitten + nvim + tmux — run with --ignored --nocapture"]
async fn perf_save_real_kitty_typical() {
    // ── Skip checks ─────────────────────────────────────────────────
    if !kitty_is_usable() {
        eprintln!("skip: kitty not usable (not on PATH or no display)");
        return;
    }
    if !kitten_is_usable() {
        eprintln!("skip: kitten not usable (RC client not available)");
        return;
    }
    if !nvim_is_usable() {
        eprintln!("skip: nvim not on PATH");
        return;
    }
    if !tmux_is_usable() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    let _guard = BENCH_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let trace_dir = &*TRACE_DIR;
    reset_trace_dir(trace_dir);

    // ── Spawn real kitty ────────────────────────────────────────────
    let mut spawner = match KittySpawner::spawn(Duration::from_secs(15), None) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("skip: failed to spawn kitty: {e:?}");
            return;
        }
    };

    // Allow kitty to fully initialise after socket is ready.
    tokio::time::sleep(Duration::from_millis(500)).await;

    // ── Set up typical workload ─────────────────────────────────────
    // Tab 1 is the default tab created at startup.
    // We'll use tab_id=1 as a stand-in; the important thing is that
    // we create additional windows and tabs via RC.

    // Create extra shell windows in the first (default) tab.
    // The default tab already has 1 window, so add 2 more shells.
    let _ = spawner.create_window(1, "splits");
    let _ = spawner.create_window(1, "splits");

    // Launch nvim in the first tab.
    let _ = spawner.launch_nvim(1, &["/tmp/perf_bench_file.rs"]);

    // Tab 2: "infra" — 2 shell windows.
    let _ = spawner.create_tab(Some("infra"));
    let _ = spawner.create_window(2, "splits");

    // Tab 3: "tmux" — create a tmux session and attach it.
    let tab3_result = spawner.create_tab(Some("tmux"));
    let tmux_session_name = format!("ksession-bench-typical-{}", std::process::id());
    if let Err(e) = spawner.create_tmux_session(&tmux_session_name) {
        eprintln!("warning: failed to create tmux session: {e:?}");
    } else if let Ok(tab3_id) = tab3_result {
        let _ = spawner.attach_tmux_in_kitty_window(tab3_id, &tmux_session_name);
        // Give tmux a moment to attach.
        tokio::time::sleep(Duration::from_millis(300)).await;
    }

    // Tab 4: "misc" — 2 shell windows.
    let _ = spawner.create_tab(Some("misc"));
    let _ = spawner.create_window(4, "splits");

    // Allow all processes to settle.
    tokio::time::sleep(Duration::from_millis(500)).await;

    // ── Run benchmark iterations ────────────────────────────────────
    let iterations = 30;
    let sessions_dir = tempdir().expect("tempdir for sessions");
    let socket_spec = spawner.socket_spec();

    println!("\n=== Benchmark: Real Kitty Typical (4 tabs, ~9 windows, nvim+tmux) ===");
    println!("Running {iterations} iterations...");

    for i in 0..iterations {
        // Point KITTY_LISTEN_ON at the real kitty socket so `save()` talks to it.
        std::env::set_var("KITTY_LISTEN_ON", &socket_spec);

        if let Err(e) = save(SaveOpts {
            name: format!("bench_typical_{i}"),
            all: true,
            scrollback: false,
            sessions_dir: sessions_dir.path().to_path_buf(),
            from_ls: None,
            from_skeleton: None,
            pre_pool: None,
        })
        .await
        {
            eprintln!("Iteration {i} failed: {e:?}");
        }

        std::env::remove_var("KITTY_LISTEN_ON");
    }

    // ── Collect and report stats ────────────────────────────────────
    let stats = perf::stats::summarise(trace_dir, "save.total");
    let s = stats
        .get("save.total")
        .expect("save.total span not found in trace output; is the tracer active?")
        .clone();

    println!("Results (from save.total span):");
    println!(
        "  Count: {}  Mean: {:.1} ms  p50: {:.1} ms  p95: {:.1} ms  p99: {:.1} ms",
        s.count,
        s.mean_ms(),
        s.p50_ms(),
        s.p95_ms(),
        s.p99_ms()
    );
    println!("  Min: {:.1} ms  Max: {:.1} ms", s.min_ms(), s.max_ms());

    assert_eq!(
        s.count, iterations,
        "expected {iterations} save.total spans, got {}",
        s.count
    );

    // ── Budget assertion ────────────────────────────────────────────
    // Typical workload with real IPC (nvim + tmux detection) is heavier
    // than the mock-based benchmarks. Budget: p95 <= 1000ms.
    assert!(
        s.p95_ms() <= 1000.0,
        "save.total p95 {:.1}ms exceeds budget 1000ms",
        s.p95_ms()
    );

    // ── Cleanup ─────────────────────────────────────────────────────
    // KittySpawner::drop handles killing kitty + tmux sessions.
    drop(spawner);
}
