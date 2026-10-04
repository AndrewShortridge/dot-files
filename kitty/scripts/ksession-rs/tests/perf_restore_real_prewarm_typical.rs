//! Cold vs. pre-warmed restore latency benchmark for the "typical" fixture.
//!
//! This benchmark measures the effect of OS page-cache pre-warming on kitty
//! restore latency. The pre-warm strategy spawns a throwaway kitty instance
//! (no session) before the real restore, so that the kitty binary, shared
//! libraries, and GPU driver pages are already resident in the page cache
//! when the real restore starts.
//!
//! Two modes run sequentially:
//!   1. **Cold** -- baseline restore (no pre-warming).
//!   2. **Pre-warmed** -- spawn + kill a bare kitty first, then restore.
//!
//! The test prints a side-by-side comparison and asserts that the pre-warmed
//! p95 stays under the PRD target (100 ms).
//!
//! Run with: `cargo test --release --test perf_restore_real_prewarm_typical -- --ignored --nocapture`

use std::path::PathBuf;
use std::process::Command;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use ksession_rs::perf;
use ksession_rs::perf::ready::{touch_ready, wait_for_all};

mod helpers;
use helpers::{kitten_is_usable, kitty_is_usable, tmux_is_usable, KittySpawner};

const ITERATIONS: usize = 15;
/// p95 budget for cold (baseline) restore (ms). Matches the existing typical
/// benchmark so we catch regressions.
const COLD_P95_BUDGET_MS: f64 = 1500.0;
/// p95 budget for pre-warmed restore (ms). This is the PRD target.
const PREWARM_P95_BUDGET_MS: f64 = 100.0;
/// Timeout per iteration for ready markers to appear.
const READY_TIMEOUT: Duration = Duration::from_secs(30);

/// Number of expected ready markers for the typical fixture.
///
/// We touch the "rust" ready marker ourselves after confirming kitty is
/// ready (socket appeared), simulating what the real restore orchestrator
/// does.
const EXPECTED_MARKERS: usize = 1;

/// Session file for the typical_001 fixture.
fn session_conf_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/real_workflow/typical_001/conf/session.conf")
}

// Serialize benchmarks so spans don't interleave.
static BENCH_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

// Shared trace dir.
static TRACE_DIR: LazyLock<PathBuf> = LazyLock::new(|| {
    let dir = std::env::var_os("KSESSION_TRACE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/ksession-restore-real-prewarm-typical-trace"));
    std::fs::create_dir_all(&dir).expect("create trace dir");
    perf::tracer::install(&dir, perf::Level::Info).expect("tracer install");
    dir
});

/// Check if nvim is available on the system.
fn nvim_is_usable() -> bool {
    Command::new("nvim")
        .arg("--version")
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

fn reset_trace_dir(dir: &std::path::Path) {
    // Clear JSONL files between iterations.
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("jsonl") {
            if let Ok(f) = std::fs::OpenOptions::new().write(true).open(&p) {
                let _ = f.set_len(0);
            }
        }
    }
    // Clear ready markers.
    let ready_dir = dir.join("ready");
    if ready_dir.exists() {
        let _ = std::fs::remove_dir_all(&ready_dir);
    }
}

/// Durations collected across iterations (wall-clock, not span-based).
struct BenchResults {
    durations_ms: Vec<f64>,
}

impl BenchResults {
    fn new() -> Self {
        Self {
            durations_ms: Vec::with_capacity(ITERATIONS),
        }
    }

    fn push(&mut self, d: Duration) {
        self.durations_ms.push(d.as_secs_f64() * 1000.0);
    }

    fn sorted(&self) -> Vec<f64> {
        let mut v = self.durations_ms.clone();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v
    }

    fn min(&self) -> f64 {
        self.sorted().first().copied().unwrap_or(0.0)
    }

    fn max(&self) -> f64 {
        self.sorted().last().copied().unwrap_or(0.0)
    }

    fn mean(&self) -> f64 {
        if self.durations_ms.is_empty() {
            return 0.0;
        }
        self.durations_ms.iter().sum::<f64>() / self.durations_ms.len() as f64
    }

    fn percentile(&self, pct: f64) -> f64 {
        let sorted = self.sorted();
        if sorted.is_empty() {
            return 0.0;
        }
        let idx = ((pct / 100.0) * (sorted.len() - 1) as f64).round() as usize;
        sorted[idx.min(sorted.len() - 1)]
    }

    fn p50(&self) -> f64 {
        self.percentile(50.0)
    }

    fn p95(&self) -> f64 {
        self.percentile(95.0)
    }

    fn p99(&self) -> f64 {
        self.percentile(99.0)
    }

    fn print_summary(&self, label: &str) {
        println!("\n=== {label} ===");
        println!(
            "Iterations: {} (first discarded as warm-up)",
            self.durations_ms.len()
        );
        println!("  Min:  {:.2} ms", self.min());
        println!("  Mean: {:.2} ms", self.mean());
        println!("  p50:  {:.2} ms", self.p50());
        println!("  p95:  {:.2} ms", self.p95());
        println!("  p99:  {:.2} ms", self.p99());
        println!("  Max:  {:.2} ms", self.max());
    }
}

#[tokio::test]
#[ignore = "pre-warm restore benchmark (requires kitty, kitten, nvim, tmux, display) - run with: cargo test --release --test perf_restore_real_prewarm_typical -- --ignored --nocapture"]
async fn perf_restore_real_prewarm_typical() {
    // --- Skip checks for required binaries ---
    if !kitty_is_usable() {
        eprintln!("SKIP: kitty not available on this system");
        return;
    }
    if !kitten_is_usable() {
        eprintln!("SKIP: kitten not available on this system");
        return;
    }
    if !nvim_is_usable() {
        eprintln!("SKIP: nvim not available on this system");
        return;
    }
    if !tmux_is_usable() {
        eprintln!("SKIP: tmux not available on this system");
        return;
    }

    let _guard = BENCH_LOCK.lock().unwrap();
    let trace_dir = &*TRACE_DIR;
    let session_conf = session_conf_path();

    assert!(
        session_conf.exists(),
        "typical_001 session.conf not found at: {}",
        session_conf.display()
    );

    // ================================================================
    // Mode 1: Cold restore (baseline)
    // ================================================================
    println!("\n=== Pre-warm Benchmark: typical_001 ===");
    println!("Session file: {}", session_conf.display());
    println!("\n--- Mode 1: Cold restore (baseline) ---");
    println!("Running {ITERATIONS} iterations (first is warm-up)...");

    let mut cold_results = BenchResults::new();
    let mut cold_failures: Vec<(usize, String)> = Vec::new();

    for i in 0..ITERATIONS {
        reset_trace_dir(trace_dir);
        std::env::set_var("KSESSION_TRACE_DIR", trace_dir.as_os_str());

        let start = Instant::now();

        let spawner = match KittySpawner::spawn(Duration::from_secs(15), Some(&session_conf)) {
            Ok(s) => s,
            Err(e) => {
                let msg = format!("cold iteration {i}: kitty spawn failed: {e}");
                eprintln!("{msg}");
                cold_failures.push((i, msg));
                continue;
            }
        };

        touch_ready(trace_dir, "rust");

        let wait_result = wait_for_all(trace_dir, EXPECTED_MARKERS, READY_TIMEOUT).await;
        let elapsed = start.elapsed();

        match wait_result {
            Ok(()) => {
                if i > 0 {
                    cold_results.push(elapsed);
                }
                if i == 0 {
                    println!("  Warm-up: {:.2} ms", elapsed.as_secs_f64() * 1000.0);
                } else if i % 5 == 0 || i == ITERATIONS - 1 {
                    println!("  Iteration {i}: {:.2} ms", elapsed.as_secs_f64() * 1000.0);
                }
            }
            Err(timeout_err) => {
                let msg = format!("cold iteration {i}: ready-marker timeout: {timeout_err}");
                eprintln!("{msg}");
                cold_failures.push((i, msg));
            }
        }

        drop(spawner);
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    // Report cold failures.
    if !cold_failures.is_empty() {
        eprintln!(
            "\nWARNING: {}/{} cold iterations failed:",
            cold_failures.len(),
            ITERATIONS
        );
        for (idx, msg) in &cold_failures {
            eprintln!("  [{idx}] {msg}");
        }
    }

    if cold_results.durations_ms.is_empty() {
        eprintln!("ERROR: All cold iterations failed; cannot compute statistics.");
        std::env::remove_var("KSESSION_TRACE_DIR");
        return;
    }

    cold_results.print_summary("Cold Restore: typical_001");

    // ================================================================
    // Mode 2: Pre-warmed restore
    // ================================================================
    println!("\n--- Mode 2: Pre-warmed restore ---");
    println!("Running {ITERATIONS} iterations (first is warm-up)...");

    let mut warm_results = BenchResults::new();
    let mut warm_failures: Vec<(usize, String)> = Vec::new();

    for i in 0..ITERATIONS {
        // Step 1: Spawn a bare kitty (the "warm" kitty) to prime the page cache.
        let warm_spawner = match KittySpawner::spawn(Duration::from_secs(15), None) {
            Ok(s) => s,
            Err(e) => {
                let msg = format!("warm iteration {i}: warm kitty spawn failed: {e}");
                eprintln!("{msg}");
                warm_failures.push((i, msg));
                continue;
            }
        };

        // Step 2: Socket appeared (spawn already waits for it). Drop the warm kitty.
        drop(warm_spawner);

        // Step 3: Brief pause to let cleanup settle.
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Step 4: Reset trace dir.
        reset_trace_dir(trace_dir);
        std::env::set_var("KSESSION_TRACE_DIR", trace_dir.as_os_str());

        // Step 5: Start timer.
        let start = Instant::now();

        // Step 6: Spawn the real kitty with session.
        let spawner = match KittySpawner::spawn(Duration::from_secs(15), Some(&session_conf)) {
            Ok(s) => s,
            Err(e) => {
                let msg = format!("warm iteration {i}: real kitty spawn failed: {e}");
                eprintln!("{msg}");
                warm_failures.push((i, msg));
                continue;
            }
        };

        // Step 7: Touch ready marker and wait.
        touch_ready(trace_dir, "rust");

        let wait_result = wait_for_all(trace_dir, EXPECTED_MARKERS, READY_TIMEOUT).await;

        // Step 8: Stop timer.
        let elapsed = start.elapsed();

        match wait_result {
            Ok(()) => {
                if i > 0 {
                    warm_results.push(elapsed);
                }
                if i == 0 {
                    println!("  Warm-up: {:.2} ms", elapsed.as_secs_f64() * 1000.0);
                } else if i % 5 == 0 || i == ITERATIONS - 1 {
                    println!("  Iteration {i}: {:.2} ms", elapsed.as_secs_f64() * 1000.0);
                }
            }
            Err(timeout_err) => {
                let msg = format!("warm iteration {i}: ready-marker timeout: {timeout_err}");
                eprintln!("{msg}");
                warm_failures.push((i, msg));
            }
        }

        // Step 9: Clean up the real kitty.
        drop(spawner);
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    std::env::remove_var("KSESSION_TRACE_DIR");

    // Report warm failures.
    if !warm_failures.is_empty() {
        eprintln!(
            "\nWARNING: {}/{} warm iterations failed:",
            warm_failures.len(),
            ITERATIONS
        );
        for (idx, msg) in &warm_failures {
            eprintln!("  [{idx}] {msg}");
        }
    }

    if warm_results.durations_ms.is_empty() {
        eprintln!("ERROR: All warm iterations failed; cannot compute statistics.");
        return;
    }

    warm_results.print_summary("Pre-warmed Restore: typical_001");

    // ================================================================
    // Comparison
    // ================================================================
    let cold_p50 = cold_results.p50();
    let cold_p95 = cold_results.p95();
    let warm_p50 = warm_results.p50();
    let warm_p95 = warm_results.p95();

    let delta_p50 = warm_p50 - cold_p50;
    let delta_p95 = warm_p95 - cold_p95;
    let pct_p50 = if cold_p50 > 0.0 {
        (delta_p50 / cold_p50) * 100.0
    } else {
        0.0
    };
    let pct_p95 = if cold_p95 > 0.0 {
        (delta_p95 / cold_p95) * 100.0
    } else {
        0.0
    };

    println!("\n=== Comparison: Cold vs. Pre-warmed ===");
    println!("  Cold  p50: {cold_p50:.2} ms  p95: {cold_p95:.2} ms");
    println!("  Warm  p50: {warm_p50:.2} ms  p95: {warm_p95:.2} ms");
    println!("  Delta p50: {delta_p50:+.2} ms ({pct_p50:+.1}%)");
    println!("  Delta p95: {delta_p95:+.2} ms ({pct_p95:+.1}%)");

    // ================================================================
    // Budget assertions
    // ================================================================
    println!("\nBudget check: cold p95 = {cold_p95:.2} ms (budget: {COLD_P95_BUDGET_MS:.0} ms)");
    assert!(
        cold_p95 <= COLD_P95_BUDGET_MS,
        "COLD BUDGET EXCEEDED: p95 {cold_p95:.2} ms > {COLD_P95_BUDGET_MS:.0} ms budget"
    );

    println!("Budget check: warm p95 = {warm_p95:.2} ms (budget: {PREWARM_P95_BUDGET_MS:.0} ms)");
    assert!(
        warm_p95 <= PREWARM_P95_BUDGET_MS,
        "PREWARM BUDGET EXCEEDED: p95 {warm_p95:.2} ms > {PREWARM_P95_BUDGET_MS:.0} ms budget"
    );

    // Warn if within 20% of budget.
    if cold_p95 > COLD_P95_BUDGET_MS * 0.8 {
        eprintln!(
            "WARNING: cold p95 ({cold_p95:.2} ms) is within 20% of budget ({COLD_P95_BUDGET_MS:.0} ms)"
        );
    }
    if warm_p95 > PREWARM_P95_BUDGET_MS * 0.8 {
        eprintln!(
            "WARNING: warm p95 ({warm_p95:.2} ms) is within 20% of budget ({PREWARM_P95_BUDGET_MS:.0} ms)"
        );
    }
}
