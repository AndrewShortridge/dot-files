//! Performance benchmark: real kitty heavy workload.
//!
//! Spawns a real kitty instance with a heavy session (6 tabs, ~18 windows,
//! multiple nvim instances, multiple tmux sessions) and measures save latency
//! over 20 iterations.
//!
//! Run with:
//!   cargo test --release --test perf_save_real_kitty_heavy -- --ignored --nocapture

mod helpers;

use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use helpers::{kitten_is_usable, kitty_is_usable, tmux_is_usable, KittySpawner};
use ksession_rs::perf;
use ksession_rs::session::{save, SaveOpts};
use tempfile::tempdir;

// --- Shared tracer (once per process) ----------------------------------------
static TRACE_DIR: LazyLock<PathBuf> = LazyLock::new(|| {
    let dir = std::env::var_os("KSESSION_TRACE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/ksession-perf-real-kitty-heavy"));
    std::fs::create_dir_all(&dir).expect("create trace dir");
    perf::tracer::install(&dir, perf::Level::Info).expect("tracer install");
    dir
});

/// Serialise tests so spans don't interleave.
static BENCH_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

fn reset_trace_dir(dir: &std::path::Path) {
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("jsonl") {
            if let Ok(f) = std::fs::OpenOptions::new().write(true).open(&p) {
                let _ = f.set_len(0);
            }
        }
    }
}

/// Check if nvim is available on PATH.
fn nvim_is_usable() -> bool {
    std::process::Command::new("nvim")
        .arg("--version")
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

/// Build a heavy workload in a real kitty instance.
///
/// Creates 6 tabs with 3-4 windows each (totalling ~18 windows), including
/// multiple nvim instances and 2 tmux sessions attached in kitty windows.
fn build_heavy_workload(spawner: &mut KittySpawner) -> Result<(), Box<dyn std::error::Error>> {
    // Create temp files for nvim
    let tmp = tempdir()?;
    let mut files: Vec<String> = Vec::new();
    for i in 0..8 {
        let path = tmp.path().join(format!("heavy_file_{}.rs", i));
        std::fs::write(
            &path,
            format!(
                "// heavy workload file {}\nfn main() {{ println!(\"hello {}\"); }}\n",
                i, i
            ),
        )?;
        files.push(path.to_string_lossy().into_owned());
    }

    // Tab 1: already exists from spawn. Create 3 additional shell windows.
    // (The initial tab has 1 window from spawn.)
    let tab1 = spawner.create_tab(Some("code-main"))?;
    spawner.create_shell_window(tab1, None)?;
    spawner.create_shell_window(tab1, None)?;
    // Launch nvim with splits in tab 1
    let file_refs: Vec<&str> = files[0..3].iter().map(|s| s.as_str()).collect();
    spawner.launch_nvim_splits(tab1, &file_refs)?;

    // Tab 2: nvim multi-tab with 4 files
    let tab2 = spawner.create_tab(Some("editor-multi"))?;
    let file_refs2: Vec<&str> = files[0..4].iter().map(|s| s.as_str()).collect();
    spawner.launch_nvim_multi_tab(tab2, &file_refs2)?;
    spawner.create_shell_window(tab2, None)?;
    spawner.create_shell_window(tab2, None)?;

    // Tab 3: nvim dirty buffers + extra shell windows
    let tab3 = spawner.create_tab(Some("dirty-work"))?;
    let file_refs3: Vec<&str> = files[4..7].iter().map(|s| s.as_str()).collect();
    spawner.launch_nvim_dirty(tab3, &file_refs3)?;
    spawner.create_shell_window(tab3, None)?;
    spawner.create_shell_window(tab3, None)?;

    // Tab 4: tmux session 1 with multiple windows and panes
    let tab4 = spawner.create_tab(Some("tmux-dev"))?;
    spawner.create_tmux_session("ks-heavy-dev")?;
    spawner.create_tmux_window("ks-heavy-dev", "build")?;
    spawner.create_tmux_window("ks-heavy-dev", "logs")?;
    spawner.create_tmux_pane("ks-heavy-dev", 0, true)?;
    spawner.create_tmux_pane("ks-heavy-dev", 1, false)?;
    spawner.attach_tmux_in_kitty_window(tab4, "ks-heavy-dev")?;
    spawner.create_shell_window(tab4, None)?;

    // Tab 5: tmux session 2 with windows and panes
    let tab5 = spawner.create_tab(Some("tmux-ops"))?;
    spawner.create_tmux_session("ks-heavy-ops")?;
    spawner.create_tmux_window("ks-heavy-ops", "monitor")?;
    spawner.create_tmux_window("ks-heavy-ops", "deploy")?;
    spawner.create_tmux_pane("ks-heavy-ops", 0, true)?;
    spawner.create_tmux_pane("ks-heavy-ops", 1, true)?;
    spawner.create_tmux_pane("ks-heavy-ops", 2, false)?;
    spawner.attach_tmux_in_kitty_window(tab5, "ks-heavy-ops")?;
    spawner.create_shell_window(tab5, None)?;

    // Tab 6: additional nvim instance + shell windows
    let tab6 = spawner.create_tab(Some("scratch"))?;
    let file_refs6: Vec<&str> = files[5..8].iter().map(|s| s.as_str()).collect();
    spawner.launch_nvim(tab6, &file_refs6)?;
    spawner.create_shell_window(tab6, None)?;
    spawner.create_shell_window(tab6, None)?;

    // Allow everything to settle
    std::thread::sleep(Duration::from_secs(2));

    // Leak the tempdir so files remain valid during the benchmark
    std::mem::forget(tmp);

    Ok(())
}

/// Run the benchmark: iterate save operations against the real kitty instance.
async fn run_benchmark(socket_path: &std::path::Path, iterations: usize) {
    let sessions_dir = tempdir().expect("tempdir for sessions");
    let sessions_path = sessions_dir.path().to_path_buf();

    // Point save at the real kitty socket
    let socket_spec = format!("unix:{}", socket_path.display());

    for i in 0..iterations {
        // Set KITTY_LISTEN_ON so save discovers the real kitty instance
        unsafe { std::env::set_var("KITTY_LISTEN_ON", &socket_spec) };

        if let Err(e) = save(SaveOpts {
            name: format!("heavy_bench_{i}"),
            all: true,
            scrollback: false,
            sessions_dir: sessions_path.clone(),
            from_ls: None,
            from_skeleton: None,
            pre_pool: None,
        })
        .await
        {
            eprintln!("Iteration {i} failed: {e:?}");
        }

        unsafe { std::env::remove_var("KITTY_LISTEN_ON") };
    }
}

#[tokio::test]
#[ignore = "real-kitty perf benchmark - requires kitty, kitten, nvim, tmux + display"]
async fn perf_save_real_kitty_heavy() {
    // --- Skip checks ---
    if !kitty_is_usable() {
        eprintln!(
            "SKIP: kitty not usable (not on PATH or no display). \
             Run with a display server available."
        );
        return;
    }
    if !kitten_is_usable() {
        eprintln!("SKIP: kitten not on PATH.");
        return;
    }
    if !nvim_is_usable() {
        eprintln!("SKIP: nvim not on PATH.");
        return;
    }
    if !tmux_is_usable() {
        eprintln!("SKIP: tmux not on PATH.");
        return;
    }

    // --- Setup ---
    let _guard = BENCH_LOCK.lock().unwrap();
    let trace_dir = &*TRACE_DIR;
    reset_trace_dir(trace_dir);

    const ITERATIONS: usize = 20;

    println!("\n=== Benchmark: Real Kitty Heavy (6 tabs, ~18 windows, 4 nvim, 2 tmux) ===");
    println!("Spawning kitty with heavy workload...");

    // Spawn real kitty
    let mut spawner = match KittySpawner::spawn(Duration::from_secs(15), None) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("SKIP: failed to spawn kitty: {:?}", e);
            return;
        }
    };

    // Build heavy workload
    if let Err(e) = build_heavy_workload(&mut spawner) {
        eprintln!("SKIP: failed to build heavy workload: {:?}", e);
        return;
    }

    println!("Workload ready. Running {ITERATIONS} iterations...");

    // --- Run benchmark ---
    run_benchmark(&spawner.socket_path, ITERATIONS).await;

    // --- Collect stats ---
    let stats = perf::stats::summarise(trace_dir, "save.total");
    let s = match stats.get("save.total") {
        Some(s) => s.clone(),
        None => {
            panic!(
                "save.total span not found in trace output; \
                 is the tracer active? Check {}/",
                trace_dir.display()
            );
        }
    };

    // --- Report ---
    println!("\nResults (save.total span, {ITERATIONS} iterations):");
    println!("  Min:  {:.1} ms", s.min_ms());
    println!("  Mean: {:.1} ms", s.mean_ms());
    println!("  p50:  {:.1} ms", s.p50_ms());
    println!("  p95:  {:.1} ms", s.p95_ms());
    println!("  p99:  {:.1} ms", s.p99_ms());
    println!("  Max:  {:.1} ms", s.max_ms());

    // Verify we got the expected number of iterations
    assert_eq!(
        s.count, ITERATIONS,
        "expected {ITERATIONS} save.total spans, got {}",
        s.count
    );

    // --- Budget assertion ---
    // Heavy scenario budget: p95 <= 3000ms
    // This is generous for 6 tabs / ~18 windows / 4 nvim / 2 tmux.
    assert!(
        s.p95_ms() <= 3000.0,
        "save.total p95 {:.1}ms exceeds budget 3000ms",
        s.p95_ms()
    );

    println!("\n  PASS: p95 {:.1}ms <= 3000ms budget", s.p95_ms());

    // Spawner Drop cleans up kitty + tmux sessions automatically.
}
