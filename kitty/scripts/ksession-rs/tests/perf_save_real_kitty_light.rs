//! Performance benchmark: save latency against a real kitty instance (light workload).
//!
//! Spawns a real kitty process with a light session (2 tabs, 3-4 windows)
//! and runs 30 save iterations, collecting timing stats. This measures
//! end-to-end save latency including real kitty RC round-trips.
//!
//! Run with:
//!   cargo test --release --test perf_save_real_kitty_light -- --ignored --nocapture

mod helpers;

use std::time::{Duration, Instant};

use helpers::{kitten_is_usable, kitty_is_usable, KittySpawner};
use ksession_rs::session::{save, SaveOpts};
use tempfile::tempdir;

const ITERATIONS: usize = 30;
/// p95 budget — generous threshold for a light workload against a real kitty.
const P95_BUDGET_MS: f64 = 500.0;

/// Minimal stats computation matching the project's reporting style.
struct Stats {
    count: usize,
    min_ms: f64,
    max_ms: f64,
    mean_ms: f64,
    p50_ms: f64,
    p95_ms: f64,
    p99_ms: f64,
}

fn compute_stats(samples: &mut Vec<f64>) -> Stats {
    assert!(!samples.is_empty(), "no samples collected");
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let count = samples.len();
    let sum: f64 = samples.iter().sum();
    let mean_ms = sum / count as f64;
    let min_ms = samples[0];
    let max_ms = samples[count - 1];
    let p50_ms = percentile(samples, 50.0);
    let p95_ms = percentile(samples, 95.0);
    let p99_ms = percentile(samples, 99.0);
    Stats {
        count,
        min_ms,
        max_ms,
        mean_ms,
        p50_ms,
        p95_ms,
        p99_ms,
    }
}

fn percentile(sorted: &[f64], pct: f64) -> f64 {
    if sorted.len() == 1 {
        return sorted[0];
    }
    let rank = (pct / 100.0) * (sorted.len() - 1) as f64;
    let lower = rank.floor() as usize;
    let upper = rank.ceil() as usize;
    if lower == upper {
        sorted[lower]
    } else {
        let frac = rank - lower as f64;
        sorted[lower] * (1.0 - frac) + sorted[upper] * frac
    }
}

#[tokio::test]
#[ignore = "requires real kitty + kitten — run with --ignored --nocapture"]
async fn perf_save_real_kitty_light() {
    // --- Skip checks ---
    if !kitty_is_usable() {
        eprintln!("skip: kitty not usable (not on PATH or no display)");
        return;
    }
    if !kitten_is_usable() {
        eprintln!("skip: kitten not usable (not on PATH)");
        return;
    }

    // --- Spawn a real kitty instance ---
    let spawner = match KittySpawner::spawn_default(None) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("skip: failed to spawn kitty: {e:?}");
            return;
        }
    };

    // --- Set up a light workload: 2 tabs, ~4 windows total ---
    // Tab 1 already exists from the initial spawn (1 window).
    // Create a second window in tab 1.
    let tab1_id: u32 = 1;
    if let Err(e) = spawner.create_window(tab1_id, "splits") {
        eprintln!("warning: create_window in tab1 failed: {e:?}");
    }

    // Create tab 2 with 2 windows.
    let tab2_result = spawner.create_tab(Some("bench-tab-2"));
    let tab2_id = match tab2_result {
        Ok(id) => id,
        Err(e) => {
            eprintln!("warning: create_tab failed: {e:?}");
            // The initial tab still has windows, proceed anyway.
            0
        }
    };
    if tab2_id > 0 {
        if let Err(e) = spawner.create_window(tab2_id, "splits") {
            eprintln!("warning: create_window in tab2 failed: {e:?}");
        }
    }

    // Let shells settle after creation.
    tokio::time::sleep(Duration::from_millis(500)).await;

    // --- Prepare save infrastructure ---
    let sessions_tmp = tempdir().expect("tempdir for sessions");
    let sessions_dir = sessions_tmp.path().to_path_buf();
    let socket_spec = spawner.socket_spec();

    // --- Run benchmark iterations ---
    println!("\n=== Benchmark: perf_save_real_kitty_light ===");
    println!("Running {ITERATIONS} iterations against a real kitty (light workload)...");

    let mut samples_ms: Vec<f64> = Vec::with_capacity(ITERATIONS);

    for i in 0..ITERATIONS {
        // Point the save function at our real kitty instance.
        std::env::set_var("KITTY_LISTEN_ON", &socket_spec);
        let start = Instant::now();

        let result = save(SaveOpts {
            name: format!("bench_light_{i}"),
            all: true,
            scrollback: false,
            sessions_dir: sessions_dir.clone(),
            from_ls: None,
            from_skeleton: None,
            pre_pool: None,
        })
        .await;

        let elapsed = start.elapsed();
        std::env::remove_var("KITTY_LISTEN_ON");

        match result {
            Ok(_) => {
                samples_ms.push(elapsed.as_secs_f64() * 1000.0);
            }
            Err(e) => {
                eprintln!("  iteration {i} failed: {e:?}");
                // Still record the timing so we can see how long failures take.
                samples_ms.push(elapsed.as_secs_f64() * 1000.0);
            }
        }
    }

    // --- Report stats ---
    let stats = compute_stats(&mut samples_ms);

    println!("\nResults ({} iterations):", stats.count);
    println!(
        "  Mean: {:.1} ms  p50: {:.1} ms  p95: {:.1} ms  p99: {:.1} ms",
        stats.mean_ms, stats.p50_ms, stats.p95_ms, stats.p99_ms
    );
    println!("  Min: {:.1} ms  Max: {:.1} ms", stats.min_ms, stats.max_ms);

    // --- Budget assertion ---
    assert!(
        stats.p95_ms <= P95_BUDGET_MS,
        "save p95 {:.1}ms exceeds budget {P95_BUDGET_MS}ms",
        stats.p95_ms
    );

    // KittySpawner Drop will clean up the kitty process.
    drop(spawner);
}
