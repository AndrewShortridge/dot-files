//! Restore latency baseline benchmark (PRD-0003 Slice 6).
//!
//! Exercises the Rust-side restore instrumentation by calling
//! `plan_restore()` (which runs `sweep_orphans` and produces spans)
//! wrapped in a `restore.dispatch` span, then touching ready markers
//! manually. No real kitty instance is spawned.
//!
//! Run with: `cargo test --release --test perf_restore_baseline -- --ignored --nocapture`

use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use tempfile::tempdir;

use ksession_rs::model::{Program, SessionFile};
use ksession_rs::perf;
use ksession_rs::perf::ready::{touch_ready, wait_for_all_with_span};
use ksession_rs::perf::stats::{summarise_all, ReportMetadata};
use ksession_rs::session::restore::plan_restore;

const FIXTURES_DIR: &str = "tests/fixtures/restore-baseline";
const ITERATIONS: usize = 30;

// Serialize benchmarks so spans don't interleave.
static BENCH_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

// Shared trace dir (one per process, like perf_save_budget.rs).
static TRACE_DIR: LazyLock<tempfile::TempDir> = LazyLock::new(|| {
    let dir = tempdir().expect("tempdir for traces");
    perf::tracer::install(dir.path(), perf::Level::Info).expect("tracer install");
    dir
});

fn reset_trace_dir(dir: &Path) {
    // Clear JSONL files between benchmarks.
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

/// Count expected ready markers from a fixture's manifest.
/// 1 (rust) + count of Program::Tmux + count of Program::Nvim
fn count_expected_markers(fixture_dir: &Path, name: &str) -> usize {
    let manifest_path = fixture_dir
        .join(format!("{name}.state"))
        .join("manifest.json");
    let raw = std::fs::read_to_string(&manifest_path).expect("read manifest");
    let session: SessionFile = serde_json::from_str(&raw).expect("parse manifest");
    let mut count = 1usize; // rust
    for osw in &session.os_windows {
        for tab in &osw.tabs {
            for win in &tab.windows {
                match &win.program {
                    Program::Tmux { .. } => count += 1,
                    Program::Nvim { .. } => count += 1,
                    _ => {}
                }
            }
        }
    }
    count
}

/// Run one benchmark iteration: plan_restore + touch ready markers.
fn run_iteration(fixture_dir: &Path, name: &str, trace_dir: &Path) {
    // Wrap in restore.dispatch span (mimicking session::restore::run).
    {
        let mut dispatch = perf::span!(perf::Level::Info, "restore.dispatch", name = name);
        let plan = plan_restore(name, fixture_dir).expect("plan_restore should succeed");
        if let Some(s) = dispatch.as_mut() {
            let conf_bytes = std::fs::metadata(&plan.conf_path)
                .map(|m| m.len())
                .unwrap_or(0);
            s.push_arg("conf_bytes", format!("{conf_bytes}"));
        }
        // Simulate kitty.launch span (no actual spawn).
        {
            let _launch = perf::span!(perf::Level::Info, "kitty.launch");
            std::thread::sleep(Duration::from_micros(100));
        }
    }

    // Touch ready markers: rust always, plus tmux/nvim based on manifest.
    // Emit per-component spans to simulate the external processes' timing.
    touch_ready(trace_dir, "rust");

    let manifest_path = fixture_dir
        .join(format!("{name}.state"))
        .join("manifest.json");
    if let Ok(raw) = std::fs::read_to_string(&manifest_path) {
        if let Ok(session) = serde_json::from_str::<SessionFile>(&raw) {
            for osw in &session.os_windows {
                for tab in &osw.tabs {
                    for win in &tab.windows {
                        match &win.program {
                            Program::Tmux { session_name, .. } => {
                                // Simulate tmux.spawn + tmux.restore spans.
                                {
                                    let _s = perf::ready::span_tmux_spawn(session_name);
                                    std::thread::sleep(Duration::from_micros(50));
                                }
                                {
                                    let _s = perf::ready::span_tmux_restore(session_name);
                                    std::thread::sleep(Duration::from_micros(50));
                                }
                                touch_ready(trace_dir, &format!("tmux-{session_name}"));
                            }
                            Program::Nvim { .. } => {
                                // Simulate nvim.spawn + nvim.source_session spans.
                                {
                                    let _s = perf::ready::span_nvim_spawn(win.kitty_id);
                                    std::thread::sleep(Duration::from_micros(50));
                                }
                                {
                                    let _s = perf::ready::span_nvim_source_session(win.kitty_id);
                                    std::thread::sleep(Duration::from_micros(50));
                                }
                                touch_ready(trace_dir, &format!("nvim-{}", win.kitty_id));
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
    }
}

async fn bench(workload: &str, name: &str) -> perf::stats::Report {
    let _guard = BENCH_LOCK.lock().unwrap();
    let trace_dir = TRACE_DIR.path();
    reset_trace_dir(trace_dir);

    let fixture_dir = PathBuf::from(FIXTURES_DIR).join(workload);
    let expected_markers = count_expected_markers(&fixture_dir, name);

    println!("\n=== Benchmark: {workload} ===");
    println!("Running {ITERATIONS} iterations (first is warm-up)...");

    for i in 0..ITERATIONS {
        run_iteration(&fixture_dir, name, trace_dir);

        // Verify ready markers (should be immediate since we touch them
        // synchronously). Uses wait_for_all_with_span so the ready.wait
        // span appears in the benchmark trace output.
        let result =
            wait_for_all_with_span(trace_dir, expected_markers, Duration::from_secs(5)).await;
        assert!(
            result.is_ok(),
            "iteration {i}: ready markers should fire: {result:?}"
        );

        // Clear ready markers for next iteration.
        let ready_dir = trace_dir.join("ready");
        if ready_dir.exists() {
            let _ = std::fs::remove_dir_all(&ready_dir);
        }
    }

    perf::tracer_flush();

    let mut report = summarise_all(trace_dir);
    report.sort_by_p50_contribution("restore.dispatch");

    // Print summary.
    if let Some(dispatch) = report.spans.iter().find(|s| s.name == "restore.dispatch") {
        println!(
            "Results ({} iterations, first discarded as warm-up):",
            dispatch.count
        );
        println!(
            "  restore.dispatch p50: {:.2} ms  p95: {:.2} ms",
            dispatch.p50_ms(),
            dispatch.p95_ms()
        );
        println!(
            "  Min: {:.2} ms  Max: {:.2} ms  Stddev: {:.2} ms",
            dispatch.min_ms(),
            dispatch.max_ms(),
            dispatch.stddev_ms()
        );
    }

    report
}

// ---------------------------------------------------------------------------
// Per-workload benchmarks
// ---------------------------------------------------------------------------

#[tokio::test]
#[ignore = "restore baseline benchmark - run with: cargo test --release --test perf_restore_baseline -- --ignored"]
async fn restore_baseline_w1_minimal() {
    let report = bench("W1_minimal", "W1_minimal").await;
    let p50 = report.span("restore.dispatch").p50_ms();
    println!("W1 restore.dispatch p50: {p50:.2} ms");
}

#[tokio::test]
#[ignore = "restore baseline benchmark - run with: cargo test --release --test perf_restore_baseline -- --ignored"]
async fn restore_baseline_w2_multi_tab() {
    let report = bench("W2_multi_tab", "W2_multi_tab").await;
    let p50 = report.span("restore.dispatch").p50_ms();
    println!("W2 restore.dispatch p50: {p50:.2} ms");
}

#[tokio::test]
#[ignore = "restore baseline benchmark - run with: cargo test --release --test perf_restore_baseline -- --ignored"]
async fn restore_baseline_w3_heavy_nvim() {
    let report = bench("W3_heavy_nvim", "W3_heavy_nvim").await;
    let p50 = report.span("restore.dispatch").p50_ms();
    println!("W3 restore.dispatch p50: {p50:.2} ms");
}

#[tokio::test]
#[ignore = "restore baseline benchmark - run with: cargo test --release --test perf_restore_baseline -- --ignored"]
async fn restore_baseline_w4_heavy_tmux() {
    let report = bench("W4_heavy_tmux", "W4_heavy_tmux").await;
    let p50 = report.span("restore.dispatch").p50_ms();
    println!("W4 restore.dispatch p50: {p50:.2} ms");
}

#[tokio::test]
#[ignore = "restore baseline benchmark - run with: cargo test --release --test perf_restore_baseline -- --ignored"]
async fn restore_baseline_w5_mixed() {
    let report = bench("W5_mixed", "W5_mixed").await;
    let p50 = report.span("restore.dispatch").p50_ms();
    println!("W5 restore.dispatch p50: {p50:.2} ms");

    // Write the findings document for W5 (the most representative workload).
    let findings_dir = PathBuf::from("docs/findings");
    std::fs::create_dir_all(&findings_dir).expect("create findings dir");

    let metadata = ReportMetadata {
        workload_name: "W5_mixed (2 OS windows, 3 tabs, nvim+tmux+shell)".to_string(),
        iterations: ITERATIONS,
        hardware: get_hardware_info(),
        kitty_version: get_version("kitty", &["--version"]),
        nvim_version: get_version("nvim", &["--version"]),
        tmux_version: get_version("tmux", &["-V"]),
    };

    report
        .write_markdown(&findings_dir.join("restore-latency-baseline.md"), &metadata)
        .expect("write findings doc");

    println!("Findings written to docs/findings/restore-latency-baseline.md");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn get_hardware_info() -> String {
    let cpu = std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("model name"))
                .map(|l| l.split(':').nth(1).unwrap_or("").trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());
    let mem = std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("MemTotal"))
                .map(|l| l.split(':').nth(1).unwrap_or("").trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());
    format!("{cpu}, {mem}")
}

fn get_version(cmd: &str, args: &[&str]) -> String {
    std::process::Command::new(cmd)
        .args(args)
        .output()
        .ok()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .next()
                .unwrap_or("")
                .trim()
                .to_string()
        })
        .unwrap_or_else(|| format!("{cmd} not found"))
}
