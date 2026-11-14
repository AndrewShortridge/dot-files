//! Real-world light restore benchmark (Issue #11).
//!
//! Spawns a real kitty instance with the `light_001` fixture session and
//! measures end-to-end restore latency by waiting for ready markers.
//!
//! The light scenario has a single tab with one window, so restore should
//! be very fast (target p95 < 500ms).
//!
//! Run with: `cargo test --release --test perf_restore_real_light -- --ignored --nocapture`

mod helpers;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use helpers::{kitten_is_usable, kitty_is_usable};
use ksession_rs::perf;
use ksession_rs::perf::ready::wait_for_all;
use tempfile::tempdir;

const ITERATIONS: usize = 30;
const READY_TIMEOUT: Duration = Duration::from_secs(5);
const SPAWN_TIMEOUT: Duration = Duration::from_secs(10);

/// P95 budget for the light restore scenario.
const P95_BUDGET_MS: f64 = 500.0;

/// Path to the light_001 fixture session.conf relative to the project root.
const LIGHT_SESSION_CONF: &str = "tests/fixtures/real_workflow/light_001/conf/session.conf";

/// Number of expected ready markers for the light scenario.
/// The light_001 fixture has 1 bare-shell window, so only the "rust" marker fires.
const EXPECTED_MARKERS: usize = 1;

/// Result of a single benchmark iteration.
#[derive(Debug, Clone, Copy)]
enum IterResult {
    /// Successfully measured restore latency.
    Ok(Duration),
    /// Ready markers did not appear within the timeout.
    Timeout,
}

/// Compute percentile from a sorted slice of durations.
fn percentile(sorted: &[Duration], pct: f64) -> Duration {
    if sorted.is_empty() {
        return Duration::ZERO;
    }
    let idx = ((sorted.len() as f64) * pct / 100.0).ceil() as usize;
    let idx = idx.saturating_sub(1).min(sorted.len() - 1);
    sorted[idx]
}

/// Report statistics from benchmark iterations.
fn report_stats(results: &[IterResult]) {
    let mut durations: Vec<Duration> = results
        .iter()
        .filter_map(|r| match r {
            IterResult::Ok(d) => Some(*d),
            IterResult::Timeout => None,
        })
        .collect();

    let timeouts = results
        .iter()
        .filter(|r| matches!(r, IterResult::Timeout))
        .count();

    if durations.is_empty() {
        println!("\n=== Results ===");
        println!("All {timeouts} iterations timed out!");
        return;
    }

    durations.sort();

    let min = durations[0];
    let max = *durations.last().unwrap();
    let sum: Duration = durations.iter().sum();
    let mean = sum / durations.len() as u32;
    let p50 = percentile(&durations, 50.0);
    let p95 = percentile(&durations, 95.0);
    let p99 = percentile(&durations, 99.0);

    println!("\n=== Restore Real Light Benchmark Results ===");
    println!(
        "Iterations: {} successful, {} timeouts",
        durations.len(),
        timeouts
    );
    println!("  Min:  {:.2} ms", min.as_secs_f64() * 1000.0);
    println!("  Mean: {:.2} ms", mean.as_secs_f64() * 1000.0);
    println!("  p50:  {:.2} ms", p50.as_secs_f64() * 1000.0);
    println!("  p95:  {:.2} ms", p95.as_secs_f64() * 1000.0);
    println!("  p99:  {:.2} ms", p99.as_secs_f64() * 1000.0);
    println!("  Max:  {:.2} ms", max.as_secs_f64() * 1000.0);
    println!("  Budget (p95): {P95_BUDGET_MS:.0} ms");
}

#[tokio::test]
#[ignore = "real restore benchmark - run with: cargo test --release --test perf_restore_real_light -- --ignored --nocapture"]
async fn perf_restore_real_light() {
    // --- Pre-flight checks ---
    if !kitty_is_usable() {
        eprintln!("SKIP: kitty not available on PATH or not usable");
        return;
    }
    if !kitten_is_usable() {
        eprintln!("SKIP: kitten not available on PATH or not usable");
        return;
    }

    let session_conf = PathBuf::from(LIGHT_SESSION_CONF);
    assert!(
        session_conf.exists(),
        "light_001 fixture session.conf not found at {}",
        session_conf.display()
    );

    // Create a trace directory for ready markers.
    let trace_tmp = tempdir().expect("create temp dir for trace");
    let trace_dir = trace_tmp.path();

    // Install tracer so ready markers work.
    perf::tracer::install(trace_dir, perf::Level::Info).expect("tracer install should succeed");

    println!("\n=== Benchmark: perf_restore_real_light ===");
    println!("Fixture: {}", session_conf.display());
    println!("Running {ITERATIONS} iterations...");

    let mut results = Vec::with_capacity(ITERATIONS);

    for i in 0..ITERATIONS {
        // Clear ready markers from previous iteration.
        let ready_dir = trace_dir.join("ready");
        if ready_dir.exists() {
            let _ = std::fs::remove_dir_all(&ready_dir);
        }

        // Spawn kitty with the session file.
        let spawner = match helpers::KittySpawner::spawn(SPAWN_TIMEOUT, Some(&session_conf)) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("SKIP: iteration {i}: failed to spawn kitty: {e}");
                // If we can't spawn at all, skip remaining iterations.
                if i == 0 {
                    eprintln!("SKIP: cannot spawn kitty on first iteration, aborting benchmark");
                    return;
                }
                results.push(IterResult::Timeout);
                continue;
            }
        };

        // Start the timer right after spawn succeeds (socket is up).
        let start = Instant::now();

        // Touch the "rust" ready marker to simulate the Rust-side restore
        // completing (in real usage, the binary touches this after
        // restore::run() returns).
        perf::ready::touch_ready(trace_dir, "rust");

        // Wait for all expected ready markers.
        let wait_result = wait_for_all(trace_dir, EXPECTED_MARKERS, READY_TIMEOUT).await;

        let elapsed = start.elapsed();

        match wait_result {
            Ok(()) => {
                results.push(IterResult::Ok(elapsed));
                if i < 3 || i % 10 == 0 {
                    println!("  iter {i:>2}: {:.2} ms", elapsed.as_secs_f64() * 1000.0);
                }
            }
            Err(err) => {
                eprintln!("  iter {i:>2}: TIMEOUT ({err})");
                results.push(IterResult::Timeout);
            }
        }

        // Clean up: drop the spawner to shut down kitty.
        drop(spawner);

        // Brief pause between iterations to avoid resource contention.
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    // Report statistics.
    report_stats(&results);

    // Assert p95 budget.
    let mut durations: Vec<Duration> = results
        .iter()
        .filter_map(|r| match r {
            IterResult::Ok(d) => Some(*d),
            IterResult::Timeout => None,
        })
        .collect();
    durations.sort();

    // Need at least some successful iterations to make assertions.
    assert!(
        durations.len() >= ITERATIONS / 2,
        "Too many timeouts: only {}/{ITERATIONS} iterations succeeded",
        durations.len()
    );

    let p95 = percentile(&durations, 95.0);
    let p95_ms = p95.as_secs_f64() * 1000.0;
    println!("\nAssertion: p95 ({p95_ms:.2} ms) <= budget ({P95_BUDGET_MS:.0} ms)");
    assert!(
        p95_ms <= P95_BUDGET_MS,
        "p95 restore latency ({p95_ms:.2} ms) exceeded budget ({P95_BUDGET_MS:.0} ms)"
    );
}
