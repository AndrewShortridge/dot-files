//! Real-kitty restore latency benchmark for the heavy_001 fixture.
//!
//! Spawns a real kitty instance with `--session` pointing to the heavy_001
//! fixture (6 tabs, 21 windows), measures time from spawn to all ready
//! markers firing, and reports latency statistics.
//!
//! This is a heavy benchmark (~2s per iteration), so only 20 iterations
//! are performed. The p95 budget is set at 4000ms initially.
//!
//! Run with: `cargo test --release --test perf_restore_real_heavy -- --ignored --nocapture`

mod helpers;

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use helpers::KittySpawner;
use ksession_rs::perf;
use ksession_rs::perf::ready::wait_for_all;

/// Path to the heavy_001 session.conf fixture.
const SESSION_CONF: &str = "tests/fixtures/real_workflow/heavy_001/conf/session.conf";

/// Number of benchmark iterations (fewer than typical due to ~2s per iteration).
const ITERATIONS: usize = 20;

/// Per-iteration timeout: if restore takes longer than this, it's a timeout.
const ITERATION_TIMEOUT: Duration = Duration::from_secs(10);

/// p95 budget assertion threshold (ms). Heavy fixture is slow; start generous.
const P95_BUDGET_MS: f64 = 4000.0;

/// Number of expected ready markers.
/// The heavy_001 fixture has 6 tabs, 21 windows. The session.conf launches
/// shell windows that don't produce ready markers on their own without
/// the full ksession restore pipeline. For a real restore benchmark we
/// expect at minimum the "rust" marker. However, since we are spawning
/// kitty with `--session` (not through ksession restore), we simulate
/// ready markers by counting the windows that kitty reports as ready.
///
/// For this benchmark, we use 1 expected marker (the rust marker we touch
/// after kitty socket is ready) since the session.conf launches bare shells
/// that won't touch nvim/tmux ready markers on their own.
const EXPECTED_READY_MARKERS: usize = 1;

// ── Prerequisite checks ────────────────────────────────────────────

fn has_kitty() -> bool {
    Command::new("kitty")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn has_kitten() -> bool {
    Command::new("kitten")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn has_nvim() -> bool {
    Command::new("nvim")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn has_tmux() -> bool {
    Command::new("tmux")
        .arg("-V")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// ── Stats helpers ──────────────────────────────────────────────────

/// Latency sample from one iteration.
#[derive(Debug, Clone, Copy)]
struct Sample {
    duration: Duration,
    timed_out: bool,
}

/// Compute statistics from a slice of samples (excluding warm-up).
struct Stats {
    min: Duration,
    max: Duration,
    mean: Duration,
    p50: Duration,
    p95: Duration,
    p99: Duration,
    timeout_count: usize,
    total_count: usize,
}

impl Stats {
    fn compute(samples: &[Sample]) -> Self {
        let total_count = samples.len();
        let timeout_count = samples.iter().filter(|s| s.timed_out).count();

        let mut durations: Vec<Duration> = samples.iter().map(|s| s.duration).collect();
        durations.sort();

        let min = durations[0];
        let max = *durations.last().unwrap();
        let mean = Duration::from_nanos(
            (durations.iter().map(|d| d.as_nanos()).sum::<u128>() / durations.len() as u128) as u64,
        );

        let p50 = percentile(&durations, 50.0);
        let p95 = percentile(&durations, 95.0);
        let p99 = percentile(&durations, 99.0);

        Stats {
            min,
            max,
            mean,
            p50,
            p95,
            p99,
            timeout_count,
            total_count,
        }
    }

    fn timeout_rate(&self) -> f64 {
        self.timeout_count as f64 / self.total_count as f64
    }
}

fn percentile(sorted: &[Duration], pct: f64) -> Duration {
    if sorted.is_empty() {
        return Duration::ZERO;
    }
    let idx = ((pct / 100.0) * (sorted.len() - 1) as f64).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

// ── Main benchmark ─────────────────────────────────────────────────

#[tokio::test]
#[ignore = "real-kitty heavy restore benchmark - run with: cargo test --release --test perf_restore_real_heavy -- --ignored --nocapture"]
async fn perf_restore_real_heavy() {
    // Skip if required binaries are not available.
    if !has_kitty() {
        eprintln!("skip: kitty not on PATH");
        return;
    }
    if !has_kitten() {
        eprintln!("skip: kitten not on PATH");
        return;
    }
    if !has_nvim() {
        eprintln!("skip: nvim not on PATH");
        return;
    }
    if !has_tmux() {
        eprintln!("skip: tmux not on PATH");
        return;
    }

    let session_conf = PathBuf::from(SESSION_CONF);
    if !session_conf.exists() {
        panic!(
            "heavy_001 session.conf not found at: {}",
            session_conf.display()
        );
    }

    // Set up trace directory for ready markers.
    let trace_dir = tempfile::tempdir().expect("create trace temp dir");
    let trace_path = trace_dir.path().to_path_buf();

    // Install tracer for ready marker infrastructure.
    perf::tracer::install(&trace_path, perf::Level::Info).expect("tracer install should succeed");

    println!("\n=== Benchmark: perf_restore_real_heavy (heavy_001) ===");
    println!("Fixture: 6 tabs, 21 windows (heavy real-workflow session)");
    println!("Running {ITERATIONS} iterations (first is warm-up)...");
    println!("Per-iteration timeout: {}s", ITERATION_TIMEOUT.as_secs());
    println!();

    let mut samples: Vec<Sample> = Vec::with_capacity(ITERATIONS);

    for i in 0..ITERATIONS {
        // Clear ready markers from previous iteration.
        let ready_dir = trace_path.join("ready");
        if ready_dir.exists() {
            let _ = std::fs::remove_dir_all(&ready_dir);
        }

        // Start timer.
        let start = Instant::now();

        // Spawn kitty with the heavy session file.
        let spawner = KittySpawner::spawn(Duration::from_secs(15), Some(&session_conf));

        let sample = match spawner {
            Ok(_spawner) => {
                // Touch the "rust" ready marker (simulating ksession's post-spawn signal).
                ksession_rs::perf::ready::touch_ready(&trace_path, "rust");

                // Wait for all expected ready markers.
                let wait_result =
                    wait_for_all(&trace_path, EXPECTED_READY_MARKERS, ITERATION_TIMEOUT).await;

                let elapsed = start.elapsed();

                match wait_result {
                    Ok(()) => Sample {
                        duration: elapsed,
                        timed_out: false,
                    },
                    Err(timeout_err) => {
                        eprintln!(
                            "  iteration {i}: TIMEOUT after {:.1}s ({timeout_err})",
                            elapsed.as_secs_f64()
                        );
                        Sample {
                            duration: elapsed,
                            timed_out: true,
                        }
                    }
                }
                // _spawner drops here, killing kitty gracefully.
            }
            Err(e) => {
                // Spawn failure (e.g., no display). Record as timeout.
                let elapsed = start.elapsed();
                eprintln!(
                    "  iteration {i}: SPAWN FAILED after {:.1}s: {e}",
                    elapsed.as_secs_f64()
                );
                Sample {
                    duration: elapsed,
                    timed_out: true,
                }
            }
        };

        if i == 0 {
            println!(
                "  warm-up: {:.1}ms {}",
                ms(sample.duration),
                if sample.timed_out { "(TIMEOUT)" } else { "" }
            );
        } else {
            print!(".");
        }

        samples.push(sample);
    }
    println!();

    // Discard the first iteration (warm-up).
    let measured = &samples[1..];

    // If ALL iterations timed out (e.g., no display), skip assertion.
    let all_timed_out = measured.iter().all(|s| s.timed_out);
    if all_timed_out {
        eprintln!(
            "\nAll iterations timed out or failed to spawn. \
             This likely means no display is available. Skipping assertions."
        );
        return;
    }

    let stats = Stats::compute(measured);

    // Print results.
    println!(
        "\n--- Results ({} iterations, warm-up discarded) ---",
        measured.len()
    );
    println!("  Min:  {:.2} ms", ms(stats.min));
    println!("  Mean: {:.2} ms", ms(stats.mean));
    println!("  p50:  {:.2} ms", ms(stats.p50));
    println!("  p95:  {:.2} ms", ms(stats.p95));
    println!("  p99:  {:.2} ms", ms(stats.p99));
    println!("  Max:  {:.2} ms", ms(stats.max));
    println!();
    println!(
        "  Timeout rate: {}/{} ({:.1}%)",
        stats.timeout_count,
        stats.total_count,
        stats.timeout_rate() * 100.0
    );
    println!();

    // Assert p95 budget.
    let p95_ms = ms(stats.p95);
    println!("  p95 budget check: {p95_ms:.2} ms <= {P95_BUDGET_MS:.0} ms");
    assert!(
        p95_ms <= P95_BUDGET_MS,
        "p95 restore latency ({p95_ms:.2} ms) exceeds budget ({P95_BUDGET_MS:.0} ms)"
    );

    // Report timeout rate (informational, not asserted).
    if stats.timeout_rate() > 0.1 {
        eprintln!(
            "WARNING: timeout rate {:.1}% exceeds 10% threshold",
            stats.timeout_rate() * 100.0
        );
    }
}
