//! Integration tests for `ksession trace gc` and `ksession trace ls` (Slice 4).
//!
//! Tests create fake trace directories under a tempdir and exercise the
//! listing, garbage collection, and auto-sweep logic without touching
//! the real `~/.cache/ksession/traces/` directory.

use std::fs;
use std::path::Path;
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use tempfile::tempdir;

use ksession_rs::cli::trace::{
    list_trace_dirs, sweep_trace_dirs, traces_root, TraceCommand, DEFAULT_KEEP,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Create `count` fake trace directories under `root`, each with a
/// distinct mtime (staggered by 10 ms to guarantee ordering). Returns
/// the names sorted oldest-first.
fn create_fake_trace_dirs(root: &Path, count: usize) -> Vec<String> {
    fs::create_dir_all(root).expect("create traces root");
    let mut names = Vec::with_capacity(count);
    for i in 0..count {
        let name = format!("2025-01-{:02}T00:00:00Z-save-session{}", (i % 28) + 1, i);
        let dir = root.join(&name);
        fs::create_dir_all(&dir).expect("create trace dir");

        // Drop a dummy file so file_count / total_bytes are nonzero.
        let data = format!("event-{i}\n");
        fs::write(dir.join("rust-1.jsonl"), data.as_bytes()).expect("write jsonl");

        names.push(name);

        // Stagger mtime by sleeping briefly. This ensures OS-level mtime
        // ordering is deterministic across the dirs.
        if i + 1 < count {
            thread::sleep(Duration::from_millis(10));
        }
    }
    names
}

/// Convenience: create dirs and return names sorted newest-first (the
/// order `list_trace_dirs` returns).
fn create_and_list_names(root: &Path, count: usize) -> Vec<String> {
    let mut names = create_fake_trace_dirs(root, count);
    names.reverse(); // newest first
    names
}

// ---------------------------------------------------------------------------
// `ksession trace ls` tests
// ---------------------------------------------------------------------------

#[test]
fn ls_output_shape_nonempty() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    let expected = create_and_list_names(&root, 3);

    let dirs = list_trace_dirs(&root);
    assert_eq!(dirs.len(), 3, "expected 3 trace dirs");

    // Verify ordering: newest first.
    let got_names: Vec<&str> = dirs.iter().map(|d| d.name.as_str()).collect();
    let exp_refs: Vec<&str> = expected.iter().map(|s| s.as_str()).collect();
    assert_eq!(got_names, exp_refs, "dirs must be sorted newest-first");

    // Verify columns are populated.
    for d in &dirs {
        assert!(!d.kind.is_empty(), "kind must not be empty");
        assert_eq!(d.kind, "save", "all test dirs are saves");
        assert!(!d.session.is_empty(), "session name must not be empty");
        assert!(d.file_count >= 1, "each dir has at least one file");
        assert!(d.total_bytes > 0, "each dir has nonzero total size");
    }
}

#[test]
fn ls_empty_cache_returns_empty_vec() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    // Don't create the directory at all.
    let dirs = list_trace_dirs(&root);
    assert!(dirs.is_empty(), "missing dir must yield empty list");
}

#[test]
fn ls_empty_existing_dir() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    fs::create_dir_all(&root).expect("create");
    let dirs = list_trace_dirs(&root);
    assert!(dirs.is_empty(), "empty dir must yield empty list");
}

#[test]
fn ls_parses_restore_kind() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    fs::create_dir_all(&root).expect("create");
    let name = "2025-06-01T12:00:00Z-restore-mybox";
    fs::create_dir_all(root.join(name)).expect("mkdir");
    fs::write(root.join(name).join("rust-1.jsonl"), b"x").expect("write");

    let dirs = list_trace_dirs(&root);
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].kind, "restore");
    assert_eq!(dirs[0].session, "mybox");
}

// ---------------------------------------------------------------------------
// `ksession trace gc` tests
// ---------------------------------------------------------------------------

#[test]
fn gc_reduces_to_keep() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    create_fake_trace_dirs(&root, 60);

    let removed = sweep_trace_dirs(&root, DEFAULT_KEEP);
    assert_eq!(removed, 10, "should remove 60 - 50 = 10 dirs");

    let remaining = list_trace_dirs(&root);
    assert_eq!(remaining.len(), DEFAULT_KEEP, "must have exactly 50 left");
}

#[test]
fn gc_keep_custom() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    create_fake_trace_dirs(&root, 20);

    let removed = sweep_trace_dirs(&root, 10);
    assert_eq!(removed, 10, "should remove 20 - 10 = 10 dirs");

    let remaining = list_trace_dirs(&root);
    assert_eq!(remaining.len(), 10, "must have exactly 10 left");
}

#[test]
fn gc_idempotent() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    create_fake_trace_dirs(&root, 55);

    let first = sweep_trace_dirs(&root, DEFAULT_KEEP);
    assert_eq!(first, 5);

    // Second run is a no-op.
    let second = sweep_trace_dirs(&root, DEFAULT_KEEP);
    assert_eq!(second, 0, "second gc must be a no-op");

    let remaining = list_trace_dirs(&root);
    assert_eq!(remaining.len(), DEFAULT_KEEP);
}

#[test]
fn gc_noop_when_under_limit() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    create_fake_trace_dirs(&root, 10);

    let removed = sweep_trace_dirs(&root, DEFAULT_KEEP);
    assert_eq!(removed, 0, "nothing to remove when under the limit");

    let remaining = list_trace_dirs(&root);
    assert_eq!(remaining.len(), 10);
}

#[test]
fn gc_removes_oldest_keeps_newest() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");

    // Create 5 dirs with known ordering.
    let names = create_fake_trace_dirs(&root, 5);
    // names[0] is oldest, names[4] is newest.

    let removed = sweep_trace_dirs(&root, 3);
    assert_eq!(removed, 2, "should remove 5 - 3 = 2 dirs");

    let remaining = list_trace_dirs(&root);
    let remaining_names: Vec<&str> = remaining.iter().map(|d| d.name.as_str()).collect();

    // The 2 oldest must be gone.
    assert!(
        !remaining_names.contains(&names[0].as_str()),
        "oldest dir must be removed"
    );
    assert!(
        !remaining_names.contains(&names[1].as_str()),
        "second-oldest dir must be removed"
    );

    // The 3 newest must remain.
    assert!(
        remaining_names.contains(&names[4].as_str()),
        "newest must remain"
    );
    assert!(
        remaining_names.contains(&names[3].as_str()),
        "second-newest must remain"
    );
    assert!(
        remaining_names.contains(&names[2].as_str()),
        "third-newest must remain"
    );
}

// ---------------------------------------------------------------------------
// Auto-sweep at invocation 51
// ---------------------------------------------------------------------------

#[test]
fn auto_sweep_at_invocation_51() {
    // Simulate the auto-sweep scenario: create 51 trace dirs, then call
    // sweep_trace_dirs (the same function auto_sweep calls via
    // maybe_init). After the sweep, only DEFAULT_KEEP (50) dirs must
    // remain.
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    create_fake_trace_dirs(&root, 51);

    // Verify we start with 51.
    assert_eq!(list_trace_dirs(&root).len(), 51);

    // Sweep with default keep.
    let removed = sweep_trace_dirs(&root, DEFAULT_KEEP);
    assert_eq!(removed, 1, "51st invocation triggers removal of 1 dir");

    let remaining = list_trace_dirs(&root);
    assert_eq!(
        remaining.len(),
        DEFAULT_KEEP,
        "after auto-sweep, exactly 50 dirs must remain"
    );
}

// ---------------------------------------------------------------------------
// `ksession trace gc` via CLI dispatch
// ---------------------------------------------------------------------------

#[test]
fn gc_cli_dispatch_returns_success() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    create_fake_trace_dirs(&root, 5);

    // Point KSESSION_TRACES_ROOT at our tempdir so `traces_root()` resolves there.
    std::env::set_var("KSESSION_TRACES_ROOT", root.to_str().unwrap());

    let code = ksession_rs::cli::trace::run(TraceCommand::Gc { keep: 3 })
        .expect("gc dispatch must not error");
    assert_eq!(
        format!("{code:?}"),
        format!("{:?}", ExitCode::SUCCESS),
        "gc must exit 0"
    );

    let remaining = list_trace_dirs(&root);
    assert_eq!(remaining.len(), 3);

    std::env::remove_var("KSESSION_TRACES_ROOT");
}

#[test]
fn ls_cli_dispatch_returns_success() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    create_fake_trace_dirs(&root, 2);

    std::env::set_var("KSESSION_TRACES_ROOT", root.to_str().unwrap());

    let code = ksession_rs::cli::trace::run(TraceCommand::Ls).expect("ls dispatch must not error");
    assert_eq!(
        format!("{code:?}"),
        format!("{:?}", ExitCode::SUCCESS),
        "ls must exit 0"
    );

    std::env::remove_var("KSESSION_TRACES_ROOT");
}

#[test]
fn ls_cli_dispatch_empty_cache() {
    let tmp = tempdir().expect("tempdir");
    let root = tmp.path().join("traces");
    // Don't create the dir — should still succeed (headers only).

    std::env::set_var("KSESSION_TRACES_ROOT", root.to_str().unwrap());

    let code = ksession_rs::cli::trace::run(TraceCommand::Ls)
        .expect("ls dispatch must not error on empty cache");
    assert_eq!(
        format!("{code:?}"),
        format!("{:?}", ExitCode::SUCCESS),
        "ls must exit 0 even with empty cache"
    );

    std::env::remove_var("KSESSION_TRACES_ROOT");
}

// ---------------------------------------------------------------------------
// traces_root resolution
// ---------------------------------------------------------------------------

#[test]
fn traces_root_respects_env_override() {
    let tmp = tempdir().expect("tempdir");
    let expected = tmp.path().join("custom-traces");
    std::env::set_var("KSESSION_TRACES_ROOT", expected.to_str().unwrap());

    let got = traces_root().expect("must resolve");
    assert_eq!(got, expected);

    std::env::remove_var("KSESSION_TRACES_ROOT");
}
