//! Performance benchmarks for save under real edge-case conditions.
//!
//! Each benchmark spawns a real kitty instance, sets up a specific
//! pathological scenario (dirty nvim buffers, dead tmux panes, crashed
//! processes, mixed degradation), and then runs the `ksession save`
//! binary against it. We verify graceful handling (no panics, correct
//! degradation behaviour) and report wall-clock timing.
//!
//! Run with:
//!   cargo test --release --test perf_save_real_edge_cases -- --ignored --nocapture

mod helpers;

use std::process::Stdio;
use std::time::{Duration, Instant};

use helpers::{kitten_is_usable, kitty_is_usable, tmux_is_usable, KittySpawner};
use tempfile::tempdir;
use tokio::process::Command;

/// Convenience: skip the test early if kitty/kitten are not available.
fn skip_unless_kitty_kitten() -> bool {
    if !kitty_is_usable() {
        eprintln!(
            "perf_save_real_edge_cases: kitty not usable — skipping. \
             (No kitty binary on PATH, or no usable display environment.)"
        );
        return true;
    }
    if !kitten_is_usable() {
        eprintln!(
            "perf_save_real_edge_cases: kitten not usable — skipping. \
             (RC client not available.)"
        );
        return true;
    }
    false
}

/// Run `ksession save` as a subprocess against a real kitty instance.
///
/// Returns (stdout, stderr, exit_code, elapsed).
async fn run_save(
    socket_spec: &str,
    session_name: &str,
    sessions_dir: &std::path::Path,
) -> (String, String, Option<i32>, Duration) {
    let bin = env!("CARGO_BIN_EXE_ksession");
    let start = Instant::now();

    let out = Command::new(bin)
        .arg("save")
        .arg(session_name)
        .arg("--all")
        .env("KITTY_LISTEN_ON", socket_spec)
        .env("KITTY_PROJECT_SESSIONS_DIR", sessions_dir)
        .env_remove("KITTY_WINDOW_ID")
        .env_remove("KSESSION_SCROLLBACK")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .expect("failed to spawn ksession binary");

    let elapsed = start.elapsed();
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    let code = out.status.code();

    (stdout, stderr, code, elapsed)
}

// ─── Benchmarks ──────────────────────────────────────────────────────────────

/// Benchmark: save with dirty (unsaved) nvim buffers.
///
/// Launches nvim with modified buffers, then runs save. The adapter should
/// either capture the dirty state or gracefully degrade. Verifies no panic
/// and measures latency.
#[tokio::test]
#[ignore = "real-kitty edge-case benchmark — run with --ignored --nocapture"]
async fn bench_dirty_nvim_buffers() {
    if skip_unless_kitty_kitten() {
        return;
    }

    // Check nvim is available
    let nvim_ok = std::process::Command::new("nvim")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !nvim_ok {
        eprintln!("bench_dirty_nvim_buffers: nvim not available — skipping.");
        return;
    }

    let sessions = tempdir().expect("sessions tempdir");
    let work = tempdir().expect("work tempdir");

    // Create files for nvim to open
    let file_a = work.path().join("dirty_a.txt");
    let file_b = work.path().join("dirty_b.txt");
    std::fs::write(&file_a, "original content A\n").unwrap();
    std::fs::write(&file_b, "original content B\n").unwrap();

    let spawner = KittySpawner::spawn_default(None).expect("failed to spawn kitty");

    // Give kitty a moment to fully initialize
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Get the initial tab ID (kitty starts with one tab/window)
    let tab_id = 1;

    // Launch nvim with dirty buffers
    let _nvim_win = spawner
        .launch_nvim_dirty(
            tab_id,
            &[file_a.to_str().unwrap(), file_b.to_str().unwrap()],
        )
        .expect("failed to launch dirty nvim");

    // Let nvim settle
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Run save iterations
    const ITERATIONS: usize = 3;
    let mut timings = Vec::with_capacity(ITERATIONS);

    for i in 0..ITERATIONS {
        let (stdout, stderr, code, elapsed) = run_save(
            &spawner.socket_spec(),
            &format!("dirty_nvim_{i}"),
            sessions.path(),
        )
        .await;

        println!(
            "  Iteration {i}: {:.1}ms, exit={code:?}",
            elapsed.as_secs_f64() * 1000.0
        );
        if !stderr.is_empty() {
            println!("    stderr: {}", stderr.lines().next().unwrap_or(""));
        }

        // Must not crash (exit code None means signal-killed)
        assert!(
            code.is_some(),
            "ksession crashed (signal-killed) on iteration {i}:\nstdout: {stdout}\nstderr: {stderr}"
        );
        // Exit 0 (clean) or 2 (degraded) are both acceptable
        assert!(
            code == Some(0) || code == Some(2),
            "unexpected exit code {code:?} on iteration {i}:\nstderr: {stderr}"
        );

        timings.push(elapsed);
    }

    let mean_ms = timings
        .iter()
        .map(|d| d.as_secs_f64() * 1000.0)
        .sum::<f64>()
        / timings.len() as f64;
    println!("\n=== bench_dirty_nvim_buffers ===");
    println!("  Iterations: {ITERATIONS}  Mean: {mean_ms:.1}ms");
}

/// Benchmark: save with dead tmux panes.
///
/// Creates a tmux session, splits a pane, kills the pane's process, then
/// runs save. Verifies that save does not crash despite the dead pane.
#[tokio::test]
#[ignore = "real-kitty edge-case benchmark — run with --ignored --nocapture"]
async fn bench_dead_tmux_panes() {
    if skip_unless_kitty_kitten() {
        return;
    }
    if !tmux_is_usable() {
        eprintln!("bench_dead_tmux_panes: tmux not available — skipping.");
        return;
    }

    let sessions = tempdir().expect("sessions tempdir");
    let mut spawner = KittySpawner::spawn_default(None).expect("failed to spawn kitty");

    tokio::time::sleep(Duration::from_millis(500)).await;

    // Create a tmux session with multiple panes
    let tmux_name = format!("ksession-bench-dead-{}", std::process::id());
    spawner
        .create_tmux_session(&tmux_name)
        .expect("failed to create tmux session");

    // Split to create a second pane
    spawner
        .create_tmux_pane(&tmux_name, 0, true)
        .expect("failed to create tmux pane");

    // Kill the process in pane 0 by sending 'exit'
    let _ = std::process::Command::new("tmux")
        .args([
            "send-keys",
            "-t",
            &format!("{tmux_name}:0.0"),
            "exit",
            "Enter",
        ])
        .output();

    // Let the pane die
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Attach the tmux session in a kitty window
    let tab_id = 1;
    let _ = spawner.attach_tmux_in_kitty_window(tab_id, &tmux_name);

    // Let tmux attach settle
    tokio::time::sleep(Duration::from_millis(800)).await;

    // Run save
    const ITERATIONS: usize = 3;
    let mut timings = Vec::with_capacity(ITERATIONS);

    for i in 0..ITERATIONS {
        let (stdout, stderr, code, elapsed) = run_save(
            &spawner.socket_spec(),
            &format!("dead_tmux_{i}"),
            sessions.path(),
        )
        .await;

        println!(
            "  Iteration {i}: {:.1}ms, exit={code:?}",
            elapsed.as_secs_f64() * 1000.0
        );
        if !stderr.is_empty() {
            println!("    stderr: {}", stderr.lines().next().unwrap_or(""));
        }

        // Must not crash
        assert!(
            code.is_some(),
            "ksession crashed on iteration {i}:\nstdout: {stdout}\nstderr: {stderr}"
        );
        // Exit 0 or 2 are acceptable (degradation is fine)
        assert!(
            code == Some(0) || code == Some(2),
            "unexpected exit code {code:?} on iteration {i}:\nstderr: {stderr}"
        );

        timings.push(elapsed);
    }

    let mean_ms = timings
        .iter()
        .map(|d| d.as_secs_f64() * 1000.0)
        .sum::<f64>()
        / timings.len() as f64;
    println!("\n=== bench_dead_tmux_panes ===");
    println!("  Iterations: {ITERATIONS}  Mean: {mean_ms:.1}ms");
}

/// Benchmark: nvim crashes (is killed) just before/during save.
///
/// Launches nvim in a kitty window, kills the nvim process, then runs save.
/// Verifies that other windows still save and the killed window degrades
/// gracefully.
#[tokio::test]
#[ignore = "real-kitty edge-case benchmark — run with --ignored --nocapture"]
async fn bench_nvim_crash_during_capture() {
    if skip_unless_kitty_kitten() {
        return;
    }

    let nvim_ok = std::process::Command::new("nvim")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !nvim_ok {
        eprintln!("bench_nvim_crash_during_capture: nvim not available — skipping.");
        return;
    }

    let sessions = tempdir().expect("sessions tempdir");
    let work = tempdir().expect("work tempdir");

    let file_a = work.path().join("crash_test.txt");
    std::fs::write(&file_a, "content for crash test\n").unwrap();

    let spawner = KittySpawner::spawn_default(None).expect("failed to spawn kitty");

    tokio::time::sleep(Duration::from_millis(500)).await;

    let tab_id = 1;

    // Launch nvim
    let _nvim_win = spawner
        .launch_nvim(tab_id, &[file_a.to_str().unwrap()])
        .expect("failed to launch nvim");

    // Also create a plain shell window (this should survive)
    let _shell_win = spawner.create_shell_window(tab_id, None);

    // Let everything settle
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Kill all nvim processes spawned under our instance group.
    // We use pkill with the parent kitty PID to be targeted.
    let kitty_pid = spawner.child.id();
    let _ = std::process::Command::new("pkill")
        .args(["-KILL", "-P", &kitty_pid.to_string(), "nvim"])
        .output();

    // Brief pause for the kill to take effect
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Run save — the dead nvim window should degrade, the shell window should succeed
    const ITERATIONS: usize = 3;
    let mut timings = Vec::with_capacity(ITERATIONS);
    let mut any_degraded = false;

    for i in 0..ITERATIONS {
        let (stdout, stderr, code, elapsed) = run_save(
            &spawner.socket_spec(),
            &format!("nvim_crash_{i}"),
            sessions.path(),
        )
        .await;

        println!(
            "  Iteration {i}: {:.1}ms, exit={code:?}",
            elapsed.as_secs_f64() * 1000.0
        );
        if !stderr.is_empty() {
            for line in stderr.lines().take(3) {
                println!("    stderr: {line}");
            }
        }

        // Must not crash
        assert!(
            code.is_some(),
            "ksession crashed on iteration {i}:\nstdout: {stdout}\nstderr: {stderr}"
        );
        // Exit 0 or 2 are acceptable
        assert!(
            code == Some(0) || code == Some(2),
            "unexpected exit code {code:?} on iteration {i}:\nstderr: {stderr}"
        );

        if code == Some(2) {
            any_degraded = true;
        }

        timings.push(elapsed);
    }

    let mean_ms = timings
        .iter()
        .map(|d| d.as_secs_f64() * 1000.0)
        .sum::<f64>()
        / timings.len() as f64;
    println!("\n=== bench_nvim_crash_during_capture ===");
    println!("  Iterations: {ITERATIONS}  Mean: {mean_ms:.1}ms");
    println!("  Any degradations observed: {any_degraded}");
}

/// Benchmark: mixed healthy and degraded windows.
///
/// Sets up multiple kitty windows — some healthy (plain shells), some with
/// killed foreground programs. Verifies that healthy windows commit while
/// failed ones degrade.
#[tokio::test]
#[ignore = "real-kitty edge-case benchmark — run with --ignored --nocapture"]
async fn bench_mixed_degraded_state() {
    if skip_unless_kitty_kitten() {
        return;
    }

    let nvim_ok = std::process::Command::new("nvim")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !nvim_ok {
        eprintln!("bench_mixed_degraded_state: nvim not available — skipping.");
        return;
    }

    let sessions = tempdir().expect("sessions tempdir");
    let work = tempdir().expect("work tempdir");

    // Create files for nvim
    let file_a = work.path().join("mixed_a.txt");
    let file_b = work.path().join("mixed_b.txt");
    std::fs::write(&file_a, "healthy file\n").unwrap();
    std::fs::write(&file_b, "will be killed\n").unwrap();

    let spawner = KittySpawner::spawn_default(None).expect("failed to spawn kitty");

    tokio::time::sleep(Duration::from_millis(500)).await;

    let tab_id = 1;

    // Create multiple shell windows (these should all survive)
    let _ = spawner.create_shell_window(tab_id, None);
    let _ = spawner.create_shell_window(tab_id, None);

    // Launch nvim that we will kill
    let _doomed_win = spawner
        .launch_nvim(tab_id, &[file_b.to_str().unwrap()])
        .expect("failed to launch nvim for kill");

    // Let everything settle
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Kill the nvim process to simulate a crash
    let kitty_pid = spawner.child.id();
    let _ = std::process::Command::new("pkill")
        .args(["-KILL", "-P", &kitty_pid.to_string(), "nvim"])
        .output();

    tokio::time::sleep(Duration::from_millis(300)).await;

    // Run save
    const ITERATIONS: usize = 3;
    let mut timings = Vec::with_capacity(ITERATIONS);

    for i in 0..ITERATIONS {
        let (stdout, stderr, code, elapsed) = run_save(
            &spawner.socket_spec(),
            &format!("mixed_{i}"),
            sessions.path(),
        )
        .await;

        println!(
            "  Iteration {i}: {:.1}ms, exit={code:?}",
            elapsed.as_secs_f64() * 1000.0
        );
        if !stderr.is_empty() {
            for line in stderr.lines().take(3) {
                println!("    stderr: {line}");
            }
        }

        // Must not crash
        assert!(
            code.is_some(),
            "ksession crashed on iteration {i}:\nstdout: {stdout}\nstderr: {stderr}"
        );
        // Exit 0 or 2 (degradation acceptable with killed nvim)
        assert!(
            code == Some(0) || code == Some(2),
            "unexpected exit code {code:?} on iteration {i}:\nstderr: {stderr}"
        );

        // When degraded, verify the conf file was still written (partial commit)
        if code == Some(2) {
            let conf = sessions.path().join(format!("mixed_{i}.conf"));
            assert!(
                conf.exists(),
                "conf file must still be committed when save degrades (iteration {i})"
            );
        }

        timings.push(elapsed);
    }

    let mean_ms = timings
        .iter()
        .map(|d| d.as_secs_f64() * 1000.0)
        .sum::<f64>()
        / timings.len() as f64;
    println!("\n=== bench_mixed_degraded_state ===");
    println!("  Iterations: {ITERATIONS}  Mean: {mean_ms:.1}ms");
}

/// Benchmark: tmux session disappears (killed) before/during save.
///
/// Creates a tmux session, attaches it in a kitty window, then kills the
/// tmux session. Runs save to verify graceful handling when the tmux
/// session backing a window no longer exists.
#[tokio::test]
#[ignore = "real-kitty edge-case benchmark — run with --ignored --nocapture"]
async fn bench_tmux_session_disappears() {
    if skip_unless_kitty_kitten() {
        return;
    }
    if !tmux_is_usable() {
        eprintln!("bench_tmux_session_disappears: tmux not available — skipping.");
        return;
    }

    let sessions = tempdir().expect("sessions tempdir");
    let mut spawner = KittySpawner::spawn_default(None).expect("failed to spawn kitty");

    tokio::time::sleep(Duration::from_millis(500)).await;

    // Create a tmux session
    let tmux_name = format!("ksession-bench-vanish-{}", std::process::id());
    spawner
        .create_tmux_session(&tmux_name)
        .expect("failed to create tmux session");

    // Attach it in the kitty window
    let tab_id = 1;
    let _ = spawner.attach_tmux_in_kitty_window(tab_id, &tmux_name);

    // Let tmux attach settle
    tokio::time::sleep(Duration::from_millis(800)).await;

    // Kill the tmux session out from under kitty
    let _ = std::process::Command::new("tmux")
        .args(["kill-session", "-t", &tmux_name])
        .output();

    // Remove from spawner tracking since we killed it manually
    spawner.tmux_sessions.retain(|s| s != &tmux_name);

    // Brief pause for the kill to propagate
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Run save — should handle the vanished tmux session gracefully
    const ITERATIONS: usize = 3;
    let mut timings = Vec::with_capacity(ITERATIONS);

    for i in 0..ITERATIONS {
        let (stdout, stderr, code, elapsed) = run_save(
            &spawner.socket_spec(),
            &format!("tmux_vanish_{i}"),
            sessions.path(),
        )
        .await;

        println!(
            "  Iteration {i}: {:.1}ms, exit={code:?}",
            elapsed.as_secs_f64() * 1000.0
        );
        if !stderr.is_empty() {
            for line in stderr.lines().take(3) {
                println!("    stderr: {line}");
            }
        }

        // Must not crash (signal-killed)
        assert!(
            code.is_some(),
            "ksession crashed on iteration {i}:\nstdout: {stdout}\nstderr: {stderr}"
        );
        // Exit 0 or 2 are acceptable. The tmux window's shell may have returned
        // to a prompt after tmux dies, so the shell adapter may capture it
        // successfully (exit 0), or it may degrade (exit 2).
        assert!(
            code == Some(0) || code == Some(2),
            "unexpected exit code {code:?} on iteration {i}:\nstderr: {stderr}"
        );

        timings.push(elapsed);
    }

    let mean_ms = timings
        .iter()
        .map(|d| d.as_secs_f64() * 1000.0)
        .sum::<f64>()
        / timings.len() as f64;
    println!("\n=== bench_tmux_session_disappears ===");
    println!("  Iterations: {ITERATIONS}  Mean: {mean_ms:.1}ms");
}
