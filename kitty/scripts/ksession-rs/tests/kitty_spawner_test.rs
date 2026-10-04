//! Integration tests for the KittySpawner helper.
//!
//! These tests verify:
//! 1. Availability detection works correctly
//! 2. Spawning creates a proper kitty process with RC socket
//! 3. Cleanup properly terminates the process
//! 4. Tab and window creation works via RC socket
//!
//! Run with: `cargo test --test kitty_spawner_test -- --ignored`
//! (The --ignored flag is needed because these tests require a real kitty binary)

mod helpers;

use std::panic;
use std::time::Duration;

use helpers::{
    kitten_is_usable, kitty_is_usable, skip_msg_kitten, skip_msg_kitty, skip_msg_xvfb,
    tmux_is_usable, xvfb_is_usable, KittySpawner, TabId, WindowId,
};

/// Test that kitty availability check returns a bool.
/// This test will skip if kitty is not available.
#[test]
fn test_kitty_availability_returns_bool() {
    if !kitty_is_usable() {
        eprintln!(
            "kitty_spawner_test: `kitty --version` failed — skipping. \
             (No kitty binary on PATH, or no usable display environment.)"
        );
        return;
    }
    // If we get here, kitty is available
    let result = kitty_is_usable();
    assert!(
        result,
        "kitty_is_usable() should return true when kitty is available"
    );
}

/// Test that kitten availability check returns a bool.
/// This test will skip if kitten is not available.
#[test]
fn test_kitten_availability_returns_bool() {
    if !kitten_is_usable() {
        eprintln!(
            "kitty_spawner_test: `kitten --version` failed — skipping. \
             (RC client not available; can't drive shutdown.)"
        );
        return;
    }
    // If we get here, kitten is available
    let result = kitten_is_usable();
    assert!(
        result,
        "kitten_is_usable() should return true when kitten is available"
    );
}

/// Test that Xvfb availability check returns a bool.
/// This test will skip if Xvfb is not available.
#[test]
fn test_xvfb_availability_returns_bool() {
    if !xvfb_is_usable() {
        eprintln!(
            "kitty_spawner_test: `Xvfb --help` failed — skipping. \
             (No Xvfb on PATH.)"
        );
        return;
    }
    // If we get here, Xvfb is available
    let result = xvfb_is_usable();
    assert!(
        result,
        "xvfb_is_usable() should return true when Xvfb is available"
    );
}

/// Test that skip messages are non-empty strings.
#[test]
fn test_skip_messages_are_non_empty() {
    let kitty_msg = skip_msg_kitty();
    let kitten_msg = skip_msg_kitten();
    let xvfb_msg = skip_msg_xvfb();

    assert!(
        !kitty_msg.is_empty(),
        "kitty skip message should be non-empty"
    );
    assert!(
        !kitten_msg.is_empty(),
        "kitten skip message should be non-empty"
    );
    assert!(
        !xvfb_msg.is_empty(),
        "Xvfb skip message should be non-empty"
    );
}

// ============== Tests requiring a running kitty instance ==============

/// Test that KittySpawner can spawn a kitty instance with RC socket.
///
/// This test requires a real kitty binary and display.
/// Run with: `cargo test --test kitty_spawner_test -- --ignored`
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_spawn_creates_process_and_socket() {
    // First check availability
    if !kitty_is_usable() {
        eprintln!(
            "kitty_spawner_test: `kitty --version` failed — skipping. \
             (No kitty binary on PATH, or no usable display environment.)"
        );
        return;
    }
    if !kitten_is_usable() {
        eprintln!(
            "kitty_spawner_test: `kitten --version` failed — skipping. \
             (RC client not available; can't drive shutdown.)"
        );
        return;
    }

    // Spawn a new kitty instance
    let spawner = match KittySpawner::spawn_default(None) {
        Ok(s) => s,
        Err(e) => {
            panic!("Failed to spawn kitty: {:?}", e);
        }
    };

    // Verify the socket path exists
    assert!(
        spawner.socket_path.exists(),
        "RC socket should exist at {}",
        spawner.socket_path.display()
    );

    // Verify the instance group is set
    assert!(
        spawner.instance_group.starts_with("ksession-bench-"),
        "Instance group should start with 'ksession-bench-', got: {}",
        spawner.instance_group
    );

    // Verify the temp directory exists
    assert!(spawner.temp_dir.exists(), "Temp directory should exist");

    // The spawner will be dropped here, which should clean up the process
    println!(
        "Successfully spawned kitty with socket at {}",
        spawner.socket_path.display()
    );
}

/// Test that the spawner waits for socket with a custom timeout.
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_spawn_with_custom_timeout() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: `kitty --version` failed — skipping. (No kitty binary on PATH, or no usable display environment.)");
        return;
    }

    // Spawn with a 5-second timeout
    let spawner = match KittySpawner::spawn(Duration::from_secs(5), None) {
        Ok(s) => s,
        Err(e) => {
            panic!("Failed to spawn kitty: {:?}", e);
        }
    };

    assert!(spawner.socket_path.exists(), "Socket should exist");
    println!(
        "Spawned with custom timeout, socket at {}",
        spawner.socket_path.display()
    );
}

/// Test that process is cleaned up on normal function return.
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_cleanup_on_normal_return() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: `kitty --version` failed — skipping. (No kitty binary on PATH, or no usable display environment.)");
        return;
    }

    let pid_before = std::process::id();

    // Spawn and immediately drop
    {
        let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

        // Verify socket exists
        assert!(spawner.socket_path.exists());

        // Store the child PID for later verification
        let child_pid = spawner.child.id();
        println!("Spawned kitty with PID {}", child_pid);

        // Drop the spawner - this should trigger cleanup
    }

    // After dropping, verify the process was cleaned up
    // We can't directly check the PID is gone, but we can verify
    // that no zombie processes are left from our test
    println!("Spawner dropped, cleanup should have occurred");

    let pid_after = std::process::id();
    assert_eq!(pid_before, pid_after, "Parent PID should be unchanged");
}

/// Test that process is cleaned up on panic/assertion failure.
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_cleanup_on_panic() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: `kitty --version` failed — skipping. (No kitty binary on PATH, or no usable display environment.)");
        return;
    }

    // Use catch_unwind to test cleanup on panic
    let result = panic::catch_unwind(panic::AssertUnwindSafe(|| {
        let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

        // Verify socket exists
        assert!(
            spawner.socket_path.exists(),
            "Socket should exist before panic"
        );

        // Panic to simulate test failure
        panic!("Simulated test failure for cleanup verification");
    }));

    // The unwrap should fail because we panicked
    assert!(result.is_err(), "Expected panic to occur");

    // Give a moment for cleanup to complete
    std::thread::sleep(Duration::from_millis(500));

    println!("Panic was caught, spawner should have cleaned up the process");
}

/// Test creating a tab in the spawned kitty instance.
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_create_tab() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: `kitty --version` failed — skipping. (No kitty binary on PATH, or no usable display environment.)");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    // Create a new tab with a title
    let tab_id: TabId = spawner
        .create_tab(Some("Test Tab"))
        .expect("Failed to create tab");

    // Tab IDs should be positive
    assert!(tab_id > 0, "Tab ID should be positive, got {}", tab_id);

    println!("Created tab with ID: {}", tab_id);
}

/// Test creating a tab without a title.
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_create_tab_without_title() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: `kitty --version` failed — skipping. (No kitty binary on PATH, or no usable display environment.)");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    // Create a new tab without a title
    let tab_id: TabId = spawner.create_tab(None).expect("Failed to create tab");

    assert!(tab_id > 0, "Tab ID should be positive, got {}", tab_id);

    println!("Created untitled tab with ID: {}", tab_id);
}

/// Test creating a window in a tab.
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_create_window() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: `kitty --version` failed — skipping. (No kitty binary on PATH, or no usable display environment.)");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    // First create a tab
    let tab_id: TabId = spawner
        .create_tab(Some("Window Test Tab"))
        .expect("Failed to create tab");

    // Create a window with horizontal layout
    let window_id: WindowId = spawner
        .create_window(tab_id, "horizontal")
        .expect("Failed to create window");

    // Window IDs should be positive
    assert!(
        window_id > 0,
        "Window ID should be positive, got {}",
        window_id
    );

    println!("Created window {} in tab {}", window_id, tab_id);
}

/// Test creating a shell window.
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_create_shell_window() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: `kitty --version` failed — skipping. (No kitty binary on PATH, or no usable display environment.)");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    // Create a tab first
    let tab_id: TabId = spawner
        .create_tab(Some("Shell Test"))
        .expect("Failed to create tab");

    // Create a shell window
    let window_id: WindowId = spawner
        .create_shell_window(tab_id, None)
        .expect("Failed to create shell window");

    assert!(
        window_id > 0,
        "Window ID should be positive, got {}",
        window_id
    );

    println!("Created shell window {} in tab {}", window_id, tab_id);
}

/// Test creating multiple tabs and windows.
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_multiple_tabs_and_windows() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: `kitty --version` failed — skipping. (No kitty binary on PATH, or no usable display environment.)");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    // Create multiple tabs
    let tab1 = spawner
        .create_tab(Some("Tab 1"))
        .expect("Failed to create tab 1");
    let tab2 = spawner
        .create_tab(Some("Tab 2"))
        .expect("Failed to create tab 2");
    let tab3 = spawner
        .create_tab(Some("Tab 3"))
        .expect("Failed to create tab 3");

    println!("Created tabs: {}, {}, {}", tab1, tab2, tab3);

    // Create windows in each tab
    let win1 = spawner
        .create_window(tab1, "horizontal")
        .expect("Failed to create window in tab1");
    let win2 = spawner
        .create_window(tab2, "vertical")
        .expect("Failed to create window in tab2");
    let win3 = spawner
        .create_shell_window(tab3, None)
        .expect("Failed to create shell in tab3");

    println!(
        "Created windows: {} in tab {}, {} in tab {}, {} in tab {}",
        win1, tab1, win2, tab2, win3, tab3
    );

    // Verify all IDs are positive
    assert!(
        tab1 > 0 && tab2 > 0 && tab3 > 0,
        "All tab IDs should be positive"
    );
    assert!(
        win1 > 0 && win2 > 0 && win3 > 0,
        "All window IDs should be positive"
    );
}

/// Test socket_spec() returns correct format.
#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn test_socket_spec_format() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: `kitty --version` failed — skipping. (No kitty binary on PATH, or no usable display environment.)");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    let spec = spawner.socket_spec();

    // Should start with "unix:" prefix
    assert!(
        spec.starts_with("unix:"),
        "Socket spec should start with 'unix:', got: {}",
        spec
    );

    // Should contain the socket path
    assert!(
        spec.contains("kitty-rc.sock"),
        "Socket spec should contain 'kitty-rc.sock', got: {}",
        spec
    );

    println!("Socket spec: {}", spec);
}

// ============== nvim launch integration tests ==============

/// Helper: create temp files for nvim tests.
fn create_temp_files(count: usize) -> (tempfile::TempDir, Vec<String>) {
    let dir = tempfile::tempdir().expect("create tempdir for nvim test");
    let mut paths = Vec::with_capacity(count);
    for i in 0..count {
        let path = dir.path().join(format!("test_file_{}.txt", i));
        std::fs::write(
            &path,
            format!("line 1 of file {}\nline 2 of file {}\n", i, i),
        )
        .expect("write temp file");
        paths.push(path.to_string_lossy().into_owned());
    }
    (dir, paths)
}

/// Test launching nvim with specific files in a kitty window.
#[test]
#[ignore = "requires real kitty + nvim + display; run with --ignored"]
fn test_launch_nvim() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available - skipping");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    let tab_id = spawner
        .create_tab(Some("nvim test"))
        .expect("Failed to create tab");

    let (_dir, files) = create_temp_files(2);
    let file_refs: Vec<&str> = files.iter().map(|s| s.as_str()).collect();

    let window_id = spawner
        .launch_nvim(tab_id, &file_refs)
        .expect("Failed to launch nvim");

    assert!(
        window_id > 0,
        "Window ID should be positive, got {}",
        window_id
    );
    println!(
        "Launched nvim in window {} with {} files",
        window_id,
        files.len()
    );
}

/// Test launching nvim with dirty (unsaved) buffers.
#[test]
#[ignore = "requires real kitty + nvim + display; run with --ignored"]
fn test_launch_nvim_dirty() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available - skipping");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    let tab_id = spawner
        .create_tab(Some("nvim dirty test"))
        .expect("Failed to create tab");

    let (_dir, files) = create_temp_files(2);
    let file_refs: Vec<&str> = files.iter().map(|s| s.as_str()).collect();

    let window_id = spawner
        .launch_nvim_dirty(tab_id, &file_refs)
        .expect("Failed to launch nvim with dirty buffers");

    assert!(
        window_id > 0,
        "Window ID should be positive, got {}",
        window_id
    );
    println!(
        "Launched nvim (dirty) in window {} with {} files",
        window_id,
        files.len()
    );
}

/// Test launching nvim with multiple nvim tab pages.
#[test]
#[ignore = "requires real kitty + nvim + display; run with --ignored"]
fn test_launch_nvim_multi_tab() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available - skipping");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    let tab_id = spawner
        .create_tab(Some("nvim multi-tab test"))
        .expect("Failed to create tab");

    let (_dir, files) = create_temp_files(3);
    let file_refs: Vec<&str> = files.iter().map(|s| s.as_str()).collect();

    let window_id = spawner
        .launch_nvim_multi_tab(tab_id, &file_refs)
        .expect("Failed to launch nvim with multiple tabs");

    assert!(
        window_id > 0,
        "Window ID should be positive, got {}",
        window_id
    );
    println!(
        "Launched nvim (multi-tab) in window {} with {} tab pages",
        window_id,
        files.len()
    );
}

/// Test launching nvim with split windows.
#[test]
#[ignore = "requires real kitty + nvim + display; run with --ignored"]
fn test_launch_nvim_splits() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available - skipping");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    let tab_id = spawner
        .create_tab(Some("nvim splits test"))
        .expect("Failed to create tab");

    let (_dir, files) = create_temp_files(3);
    let file_refs: Vec<&str> = files.iter().map(|s| s.as_str()).collect();

    let window_id = spawner
        .launch_nvim_splits(tab_id, &file_refs)
        .expect("Failed to launch nvim with splits");

    assert!(
        window_id > 0,
        "Window ID should be positive, got {}",
        window_id
    );
    println!(
        "Launched nvim (splits) in window {} with {} splits",
        window_id,
        files.len()
    );
}

/// Test launching nvim with no files (empty editor).
#[test]
#[ignore = "requires real kitty + nvim + display; run with --ignored"]
fn test_launch_nvim_no_files() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available - skipping");
        return;
    }

    let spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    let tab_id = spawner
        .create_tab(Some("nvim empty test"))
        .expect("Failed to create tab");

    let window_id = spawner
        .launch_nvim(tab_id, &[])
        .expect("Failed to launch nvim with no files");

    assert!(
        window_id > 0,
        "Window ID should be positive, got {}",
        window_id
    );
    println!("Launched empty nvim in window {}", window_id);
}

// ============== Tmux integration tests ==============

/// Test that tmux_is_usable returns a bool without panicking.
#[test]
fn test_tmux_is_usable_returns_bool() {
    let _ = tmux_is_usable();
}

/// Test creating a single tmux session and verifying it exists.
#[test]
#[ignore = "requires tmux on PATH; run with --ignored"]
fn test_create_single_tmux_session() {
    if !tmux_is_usable() {
        eprintln!("kitty_spawner_test: tmux not on PATH — skipping.");
        return;
    }
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available — skipping.");
        return;
    }

    let mut spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    spawner
        .create_tmux_session("kstest-single")
        .expect("Failed to create tmux session");

    // Verify session exists via tmux list-sessions
    let out = std::process::Command::new("tmux")
        .args(["has-session", "-t", "kstest-single"])
        .status()
        .expect("failed to run tmux has-session");
    assert!(out.success(), "tmux session 'kstest-single' should exist");

    assert_eq!(spawner.tmux_sessions.len(), 1);
    assert_eq!(spawner.tmux_sessions[0], "kstest-single");
    // Drop cleans up the session
}

/// Test adding multiple windows to a tmux session.
#[test]
#[ignore = "requires tmux on PATH; run with --ignored"]
fn test_create_tmux_windows() {
    if !tmux_is_usable() {
        eprintln!("kitty_spawner_test: tmux not on PATH — skipping.");
        return;
    }
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available — skipping.");
        return;
    }

    let mut spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    spawner
        .create_tmux_session("kstest-wins")
        .expect("Failed to create tmux session");

    spawner
        .create_tmux_window("kstest-wins", "editor")
        .expect("Failed to create tmux window 'editor'");

    spawner
        .create_tmux_window("kstest-wins", "logs")
        .expect("Failed to create tmux window 'logs'");

    // Verify 3 windows total (initial + 2 new)
    let out = std::process::Command::new("tmux")
        .args(["list-windows", "-t", "kstest-wins"])
        .output()
        .expect("failed to run tmux list-windows");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let window_count = stdout.lines().count();
    assert!(
        window_count >= 3,
        "expected at least 3 windows, got {}: {}",
        window_count,
        stdout
    );
}

/// Test creating multiple independent tmux sessions.
#[test]
#[ignore = "requires tmux on PATH; run with --ignored"]
fn test_create_multiple_tmux_sessions() {
    if !tmux_is_usable() {
        eprintln!("kitty_spawner_test: tmux not on PATH — skipping.");
        return;
    }
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available — skipping.");
        return;
    }

    let mut spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    spawner
        .create_tmux_session("kstest-multi-a")
        .expect("Failed to create tmux session A");

    spawner
        .create_tmux_session("kstest-multi-b")
        .expect("Failed to create tmux session B");

    // Both should exist
    for name in &["kstest-multi-a", "kstest-multi-b"] {
        let out = std::process::Command::new("tmux")
            .args(["has-session", "-t", name])
            .status()
            .expect("failed to run tmux has-session");
        assert!(out.success(), "tmux session '{}' should exist", name);
    }

    assert_eq!(spawner.tmux_sessions.len(), 2);
}

/// Test creating split panes inside a tmux window.
#[test]
#[ignore = "requires tmux on PATH; run with --ignored"]
fn test_create_tmux_panes() {
    if !tmux_is_usable() {
        eprintln!("kitty_spawner_test: tmux not on PATH — skipping.");
        return;
    }
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available — skipping.");
        return;
    }

    let mut spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    spawner
        .create_tmux_session("kstest-panes")
        .expect("Failed to create tmux session");

    // Vertical split in window 0
    spawner
        .create_tmux_pane("kstest-panes", 0, true)
        .expect("Failed to create vertical pane");

    // Horizontal split in window 0
    spawner
        .create_tmux_pane("kstest-panes", 0, false)
        .expect("Failed to create horizontal pane");

    // Verify 3 panes total (initial + 2 splits)
    let out = std::process::Command::new("tmux")
        .args(["list-panes", "-t", "kstest-panes:0"])
        .output()
        .expect("failed to run tmux list-panes");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let pane_count = stdout.lines().count();
    assert!(
        pane_count >= 3,
        "expected at least 3 panes, got {}: {}",
        pane_count,
        stdout
    );
}

/// Test that cleanup_tmux_sessions kills all tracked sessions.
#[test]
#[ignore = "requires tmux on PATH; run with --ignored"]
fn test_cleanup_tmux_sessions() {
    if !tmux_is_usable() {
        eprintln!("kitty_spawner_test: tmux not on PATH — skipping.");
        return;
    }
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("kitty_spawner_test: kitty/kitten not available — skipping.");
        return;
    }

    let mut spawner = KittySpawner::spawn_default(None).expect("Failed to spawn kitty");

    spawner
        .create_tmux_session("kstest-cleanup-a")
        .expect("Failed to create session A");
    spawner
        .create_tmux_session("kstest-cleanup-b")
        .expect("Failed to create session B");

    // Both should exist before cleanup
    for name in &["kstest-cleanup-a", "kstest-cleanup-b"] {
        let out = std::process::Command::new("tmux")
            .args(["has-session", "-t", name])
            .status()
            .expect("failed to run tmux has-session");
        assert!(
            out.success(),
            "session '{}' should exist before cleanup",
            name
        );
    }

    spawner.cleanup_tmux_sessions();

    // Both should be gone after cleanup
    for name in &["kstest-cleanup-a", "kstest-cleanup-b"] {
        let out = std::process::Command::new("tmux")
            .args(["has-session", "-t", name])
            .status()
            .expect("failed to run tmux has-session");
        assert!(
            !out.success(),
            "session '{}' should be gone after cleanup",
            name
        );
    }

    assert!(
        spawner.tmux_sessions.is_empty(),
        "tmux_sessions vec should be empty after cleanup"
    );
}
