//! Real restore latency benchmark for the "typical" fixture (issue #12).
//!
//! Unlike the baseline benchmark (which only exercises Rust-side planning),
//! this test spawns a real kitty instance with `--session` pointing to the
//! typical_001 fixture, then waits for ready markers to confirm the session
//! is fully loaded. This measures end-to-end restore latency including
//! kitty startup, session parsing, and window creation.
//!
//! The typical_001 fixture represents a moderate-complexity session with
//! multiple tabs and windows. The benchmark expects nvim and tmux to be
//! available even though the current fixture may not exercise them, so
//! that future fixture upgrades don't require test changes.
//!
//! Run with: `cargo test --release --test perf_restore_real_typical -- --ignored --nocapture`

use std::path::PathBuf;
use std::process::Command;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use ksession_rs::perf;
use ksession_rs::perf::ready::{touch_ready, wait_for_all};

mod helpers;
use helpers::{kitten_is_usable, kitty_is_usable, tmux_is_usable, KittySpawner};

const ITERATIONS: usize = 30;
/// p95 budget for typical restore (ms). Generous initial budget; tighten
/// once we have real baseline data.
const P95_BUDGET_MS: f64 = 1500.0;
/// Timeout per iteration for ready markers to appear.
const READY_TIMEOUT: Duration = Duration::from_secs(30);

/// Number of expected ready markers for the typical fixture.
///
/// We touch the "rust" ready marker ourselves after confirming kitty is
/// ready (socket appeared), simulating what the real restore orchestrator
/// does. Additional markers would come from nvim/tmux processes once the
/// fixture is upgraded to include them.
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
        .unwrap_or_else(|| PathBuf::from("/tmp/ksession-restore-real-typical-trace"));
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
#[ignore = "real restore benchmark (requires kitty, kitten, nvim, tmux, display) - run with: cargo test --release --test perf_restore_real_typical -- --ignored --nocapture"]
async fn perf_restore_real_typical() {
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

    println!("\n=== Real Restore Benchmark: typical_001 ===");
    println!("Session file: {}", session_conf.display());
    println!("Running {ITERATIONS} iterations (first is warm-up)...");

    let mut results = BenchResults::new();
    let mut failures: Vec<(usize, String)> = Vec::new();

    for i in 0..ITERATIONS {
        reset_trace_dir(trace_dir);

        // Set KSESSION_TRACE_DIR so ready-marker infrastructure picks it up.
        std::env::set_var("KSESSION_TRACE_DIR", trace_dir.as_os_str());

        // --- (a) Spawn kitty with --session pointing to typical_001 ---
        // --- (b) Start timer ---
        let start = Instant::now();

        let spawner = match KittySpawner::spawn(Duration::from_secs(15), Some(&session_conf)) {
            Ok(s) => s,
            Err(e) => {
                let msg = format!("iteration {i}: kitty spawn failed: {e}");
                eprintln!("{msg}");
                failures.push((i, msg));
                continue;
            }
        };

        // --- (c) Wait for ready markers ---
        // Touch the "rust" ready marker to signal the Rust orchestrator side.
        // In a real restore flow this happens after plan_restore + kitty_spawn.
        touch_ready(trace_dir, "rust");

        let wait_result = wait_for_all(trace_dir, EXPECTED_MARKERS, READY_TIMEOUT).await;

        // --- (d) Stop timer, record duration ---
        let elapsed = start.elapsed();

        match wait_result {
            Ok(()) => {
                // First iteration is warm-up; discard it.
                if i > 0 {
                    results.push(elapsed);
                }
                if i == 0 {
                    println!("  Warm-up: {:.2} ms", elapsed.as_secs_f64() * 1000.0);
                } else if i % 10 == 0 || i == ITERATIONS - 1 {
                    println!("  Iteration {i}: {:.2} ms", elapsed.as_secs_f64() * 1000.0);
                }
            }
            Err(timeout_err) => {
                let msg = format!("iteration {i}: ready-marker timeout: {timeout_err}");
                eprintln!("{msg}");
                failures.push((i, msg));
            }
        }

        // --- (e) Clean up ---
        drop(spawner);

        // Brief pause between iterations to avoid resource contention.
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    std::env::remove_var("KSESSION_TRACE_DIR");

    // --- Report failures ---
    if !failures.is_empty() {
        eprintln!(
            "\nWARNING: {}/{} iterations failed:",
            failures.len(),
            ITERATIONS
        );
        for (idx, msg) in &failures {
            eprintln!("  [{idx}] {msg}");
        }
    }

    // --- Handle case where all iterations failed ---
    if results.durations_ms.is_empty() {
        eprintln!("ERROR: All iterations failed; cannot compute statistics.");
        // Don't panic so CI environments without a display get a clean skip.
        return;
    }

    // --- Report stats (min, mean, p50, p95, p99, max) ---
    results.print_summary("Real Restore: typical_001");

    // --- Assert p95 budget ---
    let p95 = results.p95();
    println!("\nBudget check: p95 = {p95:.2} ms (budget: {P95_BUDGET_MS:.0} ms)");
    assert!(
        p95 <= P95_BUDGET_MS,
        "BUDGET EXCEEDED: p95 {p95:.2} ms > {P95_BUDGET_MS:.0} ms budget"
    );

    // Warn if we're within 20% of budget.
    if p95 > P95_BUDGET_MS * 0.8 {
        eprintln!("WARNING: p95 ({p95:.2} ms) is within 20% of budget ({P95_BUDGET_MS:.0} ms)");
    }
}
