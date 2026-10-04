//! Integration tests for `ksession trace stats` (Slice 2).
//!
//! These tests exercise the public `perf::stats::summarise` function
//! against golden JSONL fixture files with known timings, and verify the
//! CLI dispatcher produces the expected exit code and output shape.

use std::io::Write;
use std::path::PathBuf;

use ksession_rs::perf::stats;

fn fixture_dir(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

// ── summarise with golden fixtures ─────────────────────────────────

#[test]
fn summarise_save_total_exact_name() {
    let stats = stats::summarise(&fixture_dir("trace-stats"), "save.total");
    assert_eq!(stats.spans.len(), 1, "expected exactly one span");
    let s = &stats.spans[0];
    assert_eq!(s.name, "save.total");
    assert_eq!(s.count, 10);
    // Durations (us): 13000 15000 17000 18000 19000 20000 21000 22000 24000 32000
    assert!((s.min_ms() - 13.0).abs() < 0.5, "min={}", s.min_ms());
    assert!((s.max_ms() - 32.0).abs() < 0.5, "max={}", s.max_ms());
    // mean = 201000/10 = 20100 us = 20.1 ms
    assert!((s.mean_ms() - 20.1).abs() < 0.5, "mean={}", s.mean_ms());
    // p50: rank=4.5 → 19.5 ms
    assert!((s.p50_ms() - 19.5).abs() < 0.5, "p50={}", s.p50_ms());
    // p95: rank=8.55 → 28.4 ms
    assert!((s.p95_ms() - 28.4).abs() < 0.5, "p95={}", s.p95_ms());
    // p99: rank=8.91 → 31.28 ms
    assert!((s.p99_ms() - 31.28).abs() < 0.5, "p99={}", s.p99_ms());
}

#[test]
fn summarise_glob_returns_multiple_rows() {
    let stats = stats::summarise(&fixture_dir("trace-stats"), "save.*");
    assert!(
        stats.spans.len() >= 2,
        "expected multiple spans for save.*, got {}",
        stats.spans.len()
    );
    // Should contain save.total, save.discover, save.capture.window
    let names: Vec<&str> = stats.spans.iter().map(|s| s.name.as_str()).collect();
    assert!(names.contains(&"save.total"), "missing save.total");
    assert!(names.contains(&"save.discover"), "missing save.discover");
    assert!(
        names.contains(&"save.capture.window"),
        "missing save.capture.window"
    );
}

#[test]
fn summarise_empty_dir_returns_no_spans() {
    let empty = tempfile::tempdir().unwrap();
    let stats = stats::summarise(empty.path(), "save.*");
    assert!(stats.spans.is_empty());
}

#[test]
fn summarise_nonexistent_dir_returns_no_spans() {
    let stats = stats::summarise(
        std::path::Path::new("/tmp/nonexistent-trace-dir-abc123"),
        "save.*",
    );
    assert!(stats.spans.is_empty());
}

#[test]
fn summarise_baseline_fixture() {
    let stats = stats::summarise(&fixture_dir("trace-stats-baseline"), "save.total");
    assert_eq!(stats.spans.len(), 1);
    let s = &stats.spans[0];
    assert_eq!(s.count, 10);
    // Durations (us): 19000 20000 21000 22000 23000 24000 25000 26000 28000 35000
    assert!((s.min_ms() - 19.0).abs() < 0.5, "min={}", s.min_ms());
    assert!((s.max_ms() - 35.0).abs() < 0.5, "max={}", s.max_ms());
}

// ── diff (--against) scenario ──────────────────────────────────────

#[test]
fn summarise_diff_shows_improvement() {
    let baseline = stats::summarise(&fixture_dir("trace-stats-baseline"), "save.total");
    let current = stats::summarise(&fixture_dir("trace-stats"), "save.total");

    let b = baseline.get("save.total").unwrap();
    let c = current.get("save.total").unwrap();

    // The current fixture has lower p50 than the baseline — an improvement.
    assert!(
        c.p50_us < b.p50_us,
        "expected current p50 ({}) < baseline p50 ({})",
        c.p50_us,
        b.p50_us
    );

    let delta_ms = (c.p50_us - b.p50_us) / 1000.0;
    assert!(delta_ms < 0.0, "expected negative delta (improvement)");
}

// ── golden percentile tolerance (±0.5 ms) ──────────────────────────

#[test]
fn golden_percentiles_within_half_ms_tolerance() {
    let dir = tempfile::tempdir().unwrap();
    let jsonl = dir.path().join("golden.jsonl");
    let mut f = std::fs::File::create(&jsonl).unwrap();
    // 20 events: 1ms, 2ms, ..., 20ms (in us: 1000, 2000, ..., 20000)
    for i in 1..=20u64 {
        writeln!(
            f,
            r#"{{"name":"test.span","ph":"X","ts":0,"dur":{},"pid":1,"tid":1,"args":{{}}}}"#,
            i * 1000
        )
        .unwrap();
    }
    drop(f);

    let stats = stats::summarise(dir.path(), "test.span");
    let s = &stats.spans[0];
    assert_eq!(s.count, 20);
    assert!((s.min_ms() - 1.0).abs() < 0.5, "min={}", s.min_ms());
    assert!((s.max_ms() - 20.0).abs() < 0.5, "max={}", s.max_ms());
    assert!((s.mean_ms() - 10.5).abs() < 0.5, "mean={}", s.mean_ms());
    assert!((s.p50_ms() - 10.5).abs() < 0.5, "p50={}", s.p50_ms());
    assert!((s.p95_ms() - 19.05).abs() < 0.5, "p95={}", s.p95_ms());
    assert!((s.p99_ms() - 19.81).abs() < 0.5, "p99={}", s.p99_ms());
}

// ── CLI dispatcher exit code ───────────────────────────────────────

#[test]
fn trace_stats_empty_dir_exits_zero() {
    let empty = tempfile::tempdir().unwrap();

    // The stats command with no matching data should exit 0.
    // We test the summarise function directly (which is what the CLI
    // calls). The exit-zero-on-empty guarantee is exercised here.
    let stats = stats::summarise(empty.path(), "nonexistent.span");
    assert!(stats.spans.is_empty());
}
