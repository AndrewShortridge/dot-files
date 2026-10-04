//! Ready marker smoke test for the restore path (PRD-0003 Slice 5).
//!
//! Runs the W1 (minimal) fixture through `plan_restore` with tracing
//! enabled, then verifies that:
//!
//! 1. The rust-side ready marker fires (exactly 1 marker for W1, which
//!    has only a BareShell window — no tmux or nvim contributors).
//! 2. The `restore.dispatch` and `restore.sweep_orphans` spans appear
//!    in the trace JSONL.
//!
//! This test exercises the instrumentation contract without spawning
//! kitty: `plan_restore` builds the argv and runs `sweep_orphans`
//! (producing the span), and we touch the ready marker manually
//! (mimicking what the binary does after `restore::run` returns).
//!
//! Marked `#[ignore]` so `cargo test` does not run it by default.
//! Run with: `cargo test --test perf_restore_ready_marker_smoke -- --ignored`

use std::path::Path;
use std::time::Duration;

use tempfile::tempdir;

use ksession_rs::perf;
use ksession_rs::perf::ready::{touch_ready, wait_for_all};
use ksession_rs::perf::stats::summarise;
use ksession_rs::session::restore::plan_restore;

const FIXTURES_DIR: &str = "tests/fixtures/restore-baseline";

#[tokio::test]
#[ignore = "restore ready marker smoke - run with: cargo test --test perf_restore_ready_marker_smoke -- --ignored"]
async fn w1_restore_ready_marker_fires() {
    let trace_dir = tempdir().unwrap();

    // Install the tracer directly (not via maybe_init) so we control
    // the trace dir. This works because each integration test file gets
    // its own binary process, so the OnceLock is fresh.
    perf::tracer::install(trace_dir.path(), perf::Level::Info)
        .expect("tracer install should succeed in a fresh process");

    let fixture_dir = Path::new(FIXTURES_DIR).join("W1_minimal");

    // Wrap plan_restore in a restore.dispatch span, mimicking what
    // session::restore::run() does in the real binary.
    {
        let _dispatch = perf::span!(perf::Level::Info, "restore.dispatch", name = "W1_minimal");
        let plan = plan_restore("W1_minimal", &fixture_dir);
        assert!(
            plan.is_ok(),
            "plan_restore should succeed for W1_minimal fixture: {plan:?}"
        );
    } // _dispatch drops here, emitting the span to JSONL

    // Touch the rust ready marker, mimicking what the binary does
    // after restore::run() returns.
    touch_ready(trace_dir.path(), "rust");

    // Flush the tracer so all buffered spans are written to disk.
    perf::tracer_flush();

    // --- Assert ready marker ---
    // For W1 (BareShell only), expected ready markers = 1 (just "rust").
    let result = wait_for_all(trace_dir.path(), 1, Duration::from_secs(5)).await;
    assert!(
        result.is_ok(),
        "ready marker should fire within 5s: {result:?}"
    );

    // Verify the marker file exists on disk.
    let marker_path = trace_dir.path().join("ready").join("rust");
    assert!(
        marker_path.exists(),
        "ready/rust marker file should exist at {}",
        marker_path.display()
    );

    // --- Assert trace spans ---
    // The restore.dispatch span should appear in the JSONL.
    let stats = summarise(trace_dir.path(), "restore.*");
    assert!(
        stats.get("restore.dispatch").is_some(),
        "restore.dispatch span should appear in trace JSONL; found spans: {:?}",
        stats.spans.iter().map(|s| &s.name).collect::<Vec<_>>()
    );

    // The restore.sweep_orphans span (emitted inside plan_restore)
    // should also appear.
    assert!(
        stats.get("restore.sweep_orphans").is_some(),
        "restore.sweep_orphans span should appear in trace JSONL; found spans: {:?}",
        stats.spans.iter().map(|s| &s.name).collect::<Vec<_>>()
    );

    // Verify restore.dispatch carries the session name arg.
    let jsonl_path = trace_dir
        .path()
        .join(format!("rust-{}.jsonl", std::process::id()));
    let body = std::fs::read_to_string(&jsonl_path).expect("read JSONL file");
    let mut found_dispatch_with_name = false;
    for line in body.lines() {
        if line.trim().is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
            if v["name"] == "restore.dispatch" {
                assert_eq!(
                    v["args"]["name"], "W1_minimal",
                    "restore.dispatch should carry name=W1_minimal arg"
                );
                found_dispatch_with_name = true;
            }
        }
    }
    assert!(
        found_dispatch_with_name,
        "restore.dispatch event with name arg not found in JSONL"
    );
}
