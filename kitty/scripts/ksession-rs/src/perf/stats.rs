//! Percentile statistics over chrome-trace JSONL span events.
//!
//! The main entry point is [`summarise`], which scans `*.jsonl` files
//! under a trace directory, filters events by a name glob, and computes
//! per-span-name statistics (min, max, mean, stddev, p50, p95, p99, count).
//!
//! [`summarise_all`] is a convenience that collects stats for ALL span
//! names and returns a [`Report`] with sorting and markdown output.
//!
//! This module is shared by the `ksession trace stats` CLI subcommand
//! (Slice 2) and the `perf_save_budget` integration test (Slice 8).

use std::collections::BTreeMap;
use std::fmt::Write as FmtWrite;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::path::Path;

/// Aggregate statistics for a single span name.
#[derive(Debug, Clone)]
pub struct SpanStats {
    pub name: String,
    pub count: usize,
    pub min_us: f64,
    pub max_us: f64,
    pub mean_us: f64,
    pub stddev_us: f64,
    pub p50_us: f64,
    pub p95_us: f64,
    pub p99_us: f64,
    /// Populated by [`Report::sort_by_p50_contribution`]. Represents
    /// `(this span's p50 / root span's p50) * 100`, capped at 100.0.
    pub contribution_pct: Option<f64>,
}

impl SpanStats {
    /// Helper: convert a microsecond value to milliseconds.
    pub fn min_ms(&self) -> f64 {
        self.min_us / 1000.0
    }
    pub fn max_ms(&self) -> f64 {
        self.max_us / 1000.0
    }
    pub fn mean_ms(&self) -> f64 {
        self.mean_us / 1000.0
    }
    pub fn stddev_ms(&self) -> f64 {
        self.stddev_us / 1000.0
    }
    pub fn p50_ms(&self) -> f64 {
        self.p50_us / 1000.0
    }
    pub fn p95_ms(&self) -> f64 {
        self.p95_us / 1000.0
    }
    pub fn p99_ms(&self) -> f64 {
        self.p99_us / 1000.0
    }
}

/// Result of [`summarise`]: statistics grouped by span name, sorted
/// alphabetically.
#[derive(Debug, Clone)]
pub struct Stats {
    /// One entry per distinct span name that matched the glob, sorted
    /// by name.
    pub spans: Vec<SpanStats>,
}

impl Stats {
    /// Look up a single span name. Convenience for the `perf_save_budget`
    /// test which only cares about `save.total`.
    pub fn get(&self, name: &str) -> Option<&SpanStats> {
        self.spans.iter().find(|s| s.name == name)
    }
}

/// A full performance report covering all span names in a trace.
///
/// Unlike [`Stats`] (which is filtered by a glob and sorted alphabetically),
/// `Report` collects every span and supports sorting by p50 contribution
/// and markdown output.
#[derive(Debug, Clone)]
pub struct Report {
    pub spans: Vec<SpanStats>,
    pub root_span_name: Option<String>,
}

impl Report {
    /// Look up a span by name. Panics if not found (intended for test
    /// assertions).
    pub fn span(&self, name: &str) -> &SpanStats {
        self.spans
            .iter()
            .find(|s| s.name == name)
            .unwrap_or_else(|| panic!("span '{name}' not found in report"))
    }

    /// Sort spans by p50 descending and compute contribution percentages
    /// relative to the given root span.
    ///
    /// `contribution_pct = (this span's p50 / root span's p50) * 100`,
    /// capped at 100.0. Child spans may overlap, so the sum across all
    /// spans can exceed 100%.
    pub fn sort_by_p50_contribution(&mut self, root_span_name: &str) {
        let root_p50 = self
            .spans
            .iter()
            .find(|s| s.name == root_span_name)
            .map(|s| s.p50_us)
            .unwrap_or(0.0);

        for span in &mut self.spans {
            let pct = if root_p50 > 0.0 {
                ((span.p50_us / root_p50) * 100.0).min(100.0)
            } else {
                0.0
            };
            span.contribution_pct = Some(pct);
        }

        self.root_span_name = Some(root_span_name.to_string());

        // Sort by p50 descending (highest contribution first).
        self.spans.sort_by(|a, b| {
            b.p50_us
                .partial_cmp(&a.p50_us)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
    }

    /// Write a markdown report to the given path.
    pub fn write_markdown(&self, path: &Path, metadata: &ReportMetadata) -> io::Result<()> {
        let mut out = String::new();

        writeln!(
            out,
            "# Restore Latency Baseline \u{2014} {}\n",
            metadata.workload_name
        )
        .unwrap();

        writeln!(out, "## Methodology\n").unwrap();
        writeln!(out, "- Workload: {}", metadata.workload_name).unwrap();
        writeln!(
            out,
            "- Iterations: {} (first discarded as warm-up)",
            metadata.iterations
        )
        .unwrap();
        writeln!(out, "- Hardware: {}", metadata.hardware).unwrap();
        writeln!(out, "- kitty: {}", metadata.kitty_version).unwrap();
        writeln!(out, "- nvim: {}", metadata.nvim_version).unwrap();
        writeln!(out, "- tmux: {}", metadata.tmux_version).unwrap();

        writeln!(out, "\n## Results\n").unwrap();
        writeln!(
            out,
            "| Span | p50 (ms) | p95 (ms) | min (ms) | max (ms) | stddev (ms) | count | contribution % |"
        )
        .unwrap();
        writeln!(
            out,
            "|------|----------|----------|----------|----------|-------------|-------|----------------|"
        )
        .unwrap();

        for (i, s) in self.spans.iter().enumerate() {
            let bold = i < 5;
            let name_str = if bold {
                format!("**{}**", s.name)
            } else {
                s.name.clone()
            };
            let contrib = s
                .contribution_pct
                .map(|p| format!("{p:.1}%"))
                .unwrap_or_else(|| "\u{2014}".to_string());
            writeln!(
                out,
                "| {} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {} | {} |",
                name_str,
                s.p50_ms(),
                s.p95_ms(),
                s.min_ms(),
                s.max_ms(),
                s.stddev_ms(),
                s.count,
                contrib,
            )
            .unwrap();
        }

        let mut f = fs::File::create(path)?;
        f.write_all(out.as_bytes())?;
        Ok(())
    }
}

/// Metadata attached to a markdown report.
#[derive(Debug, Clone)]
pub struct ReportMetadata {
    pub workload_name: String,
    pub iterations: usize,
    pub hardware: String,
    pub kitty_version: String,
    pub nvim_version: String,
    pub tmux_version: String,
}

/// Like [`summarise`] but collects stats for ALL span names (equivalent
/// to `summarise(dir, "*")`) and returns a [`Report`] instead of [`Stats`].
pub fn summarise_all(trace_dir: &Path) -> Report {
    let stats = summarise(trace_dir, "*");
    Report {
        spans: stats.spans,
        root_span_name: None,
    }
}

/// Scan all `*.jsonl` files under `trace_dir`, filter events whose
/// `name` field matches `name_glob` (supports `*` wildcards), and
/// compute per-span-name percentile statistics.
///
/// Returns an empty `Stats` (no spans) if no matching events are found
/// — this is not an error.
///
/// The `name_glob` pattern supports:
/// - `*` matches any sequence of characters (including none)
/// - Literal characters match exactly (case-sensitive)
/// - e.g. `save.*` matches `save.total`, `save.discover`, etc.
/// - e.g. `*` matches everything
pub fn summarise(trace_dir: &Path, name_glob: &str) -> Stats {
    let mut durations: BTreeMap<String, Vec<f64>> = BTreeMap::new();

    let entries = match fs::read_dir(trace_dir) {
        Ok(e) => e,
        Err(_) => return Stats { spans: Vec::new() },
    };

    let mut jsonl_files: Vec<std::path::PathBuf> = entries
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            if p.extension().and_then(|s| s.to_str()) == Some("jsonl") {
                Some(p)
            } else {
                None
            }
        })
        .collect();
    jsonl_files.sort();

    for file in &jsonl_files {
        let f = match fs::File::open(file) {
            Ok(f) => f,
            Err(_) => continue,
        };
        for line in BufReader::new(f).lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => break,
            };
            if line.trim().is_empty() {
                continue;
            }
            let v: serde_json::Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let name = match v.get("name").and_then(|n| n.as_str()) {
                Some(n) => n,
                None => continue,
            };
            if !glob_match(name_glob, name) {
                continue;
            }
            let dur = match v.get("dur").and_then(|d| d.as_f64()) {
                Some(d) => d,
                None => continue,
            };
            durations.entry(name.to_string()).or_default().push(dur);
        }
    }

    let mut spans = Vec::with_capacity(durations.len());
    for (name, mut vals) in durations {
        vals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let count = vals.len();
        let sum: f64 = vals.iter().sum();
        let mean = sum / count as f64;
        let min = vals[0];
        let max = vals[count - 1];
        let p50 = percentile(&vals, 50.0);
        let p95 = percentile(&vals, 95.0);
        let p99 = percentile(&vals, 99.0);
        let variance: f64 = vals.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / count as f64;
        let stddev = variance.sqrt();
        spans.push(SpanStats {
            name,
            count,
            min_us: min,
            max_us: max,
            mean_us: mean,
            stddev_us: stddev,
            p50_us: p50,
            p95_us: p95,
            p99_us: p99,
            contribution_pct: None,
        });
    }

    Stats { spans }
}

/// Compute a percentile from a sorted slice using linear interpolation
/// (the "exclusive" / "C=1" method, matching NumPy's default).
///
/// `pct` is in `[0, 100]`.
fn percentile(sorted: &[f64], pct: f64) -> f64 {
    assert!(!sorted.is_empty());
    if sorted.len() == 1 {
        return sorted[0];
    }
    let n = sorted.len() as f64;
    // Use the "nearest rank" method: rank = (pct/100) * (n - 1)
    let rank = (pct / 100.0) * (n - 1.0);
    let lo = rank.floor() as usize;
    let hi = rank.ceil().min(n - 1.0) as usize;
    let frac = rank - lo as f64;
    sorted[lo] * (1.0 - frac) + sorted[hi] * frac
}

/// Simple glob matcher supporting `*` as a wildcard that matches any
/// sequence of characters (including empty). No other metacharacters.
///
/// This avoids pulling in a third-party glob crate for production code
/// (`glob` is in dev-dependencies only).
fn glob_match(pattern: &str, text: &str) -> bool {
    // Split pattern on `*` to get literal segments.
    let segments: Vec<&str> = pattern.split('*').collect();

    // No wildcard at all: exact match.
    if segments.len() == 1 {
        return pattern == text;
    }

    let mut pos = 0;

    for (i, seg) in segments.iter().enumerate() {
        if seg.is_empty() {
            continue;
        }
        if i == 0 {
            // First segment must match at the start.
            if !text.starts_with(seg) {
                return false;
            }
            pos = seg.len();
        } else if i == segments.len() - 1 {
            // Last segment must match at the end.
            if !text[pos..].ends_with(seg) {
                return false;
            }
            pos = text.len();
        } else {
            // Middle segments: find next occurrence after current pos.
            match text[pos..].find(seg) {
                Some(offset) => pos += offset + seg.len(),
                None => return false,
            }
        }
    }

    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    // ── glob_match tests ──────────────────────────────────────────

    #[test]
    fn glob_exact_match() {
        assert!(glob_match("save.total", "save.total"));
        assert!(!glob_match("save.total", "save.discover"));
    }

    #[test]
    fn glob_trailing_star() {
        assert!(glob_match("save.*", "save.total"));
        assert!(glob_match("save.*", "save.discover"));
        assert!(glob_match("save.*", "save.capture.window"));
        assert!(!glob_match("save.*", "restore.total"));
    }

    #[test]
    fn glob_leading_star() {
        assert!(glob_match("*.total", "save.total"));
        assert!(glob_match("*.total", "restore.total"));
        assert!(!glob_match("*.total", "save.discover"));
    }

    #[test]
    fn glob_middle_star() {
        assert!(glob_match("save.*.window", "save.capture.window"));
        assert!(!glob_match("save.*.window", "save.capture.pane"));
    }

    #[test]
    fn glob_star_only() {
        assert!(glob_match("*", "save.total"));
        assert!(glob_match("*", ""));
    }

    #[test]
    fn glob_double_star() {
        assert!(glob_match("save.**", "save.capture.window"));
        assert!(glob_match("**", "anything"));
    }

    // ── percentile tests ──────────────────────────────────────────

    #[test]
    fn percentile_single_value() {
        assert!((percentile(&[42.0], 50.0) - 42.0).abs() < f64::EPSILON);
        assert!((percentile(&[42.0], 99.0) - 42.0).abs() < f64::EPSILON);
    }

    #[test]
    fn percentile_two_values() {
        // p50 of [10, 20] with linear interp: rank = 0.5*(2-1) = 0.5
        // → 10*0.5 + 20*0.5 = 15.0
        let v = vec![10.0, 20.0];
        assert!((percentile(&v, 50.0) - 15.0).abs() < f64::EPSILON);
    }

    #[test]
    fn percentile_known_distribution() {
        // 100 values: 1, 2, 3, ..., 100 (in microseconds)
        let vals: Vec<f64> = (1..=100).map(|i| i as f64).collect();
        let p50 = percentile(&vals, 50.0);
        let p95 = percentile(&vals, 95.0);
        let p99 = percentile(&vals, 99.0);
        // p50: rank = 0.5 * 99 = 49.5 → 50*0.5 + 51*0.5 = 50.5
        assert!((p50 - 50.5).abs() < 0.01, "p50={p50}");
        // p95: rank = 0.95 * 99 = 94.05 → 95*0.95 + 96*0.05 = 95.05
        assert!((p95 - 95.05).abs() < 0.01, "p95={p95}");
        // p99: rank = 0.99 * 99 = 98.01 → 99*0.99 + 100*0.01 = 99.01
        assert!((p99 - 99.01).abs() < 0.01, "p99={p99}");
    }

    // ── summarise tests with golden JSONL fixtures ────────────────

    /// Write a JSONL fixture file with known timings and verify stats.
    #[test]
    fn summarise_golden_fixture() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("rust-12345.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();

        // 10 events for save.total with durations (in us):
        // 13000, 15000, 17000, 18000, 19000, 20000, 21000, 22000, 24000, 32000
        let durations_us = [
            13000, 15000, 17000, 18000, 19000, 20000, 21000, 22000, 24000, 32000,
        ];
        for dur in &durations_us {
            writeln!(
                f,
                r#"{{"name":"save.total","ph":"X","ts":1700000000000000,"dur":{},"pid":12345,"tid":1,"args":{{}}}}"#,
                dur
            )
            .unwrap();
        }
        // 5 events for save.discover
        let discover_durs = [1000, 2000, 3000, 4000, 5000];
        for dur in &discover_durs {
            writeln!(
                f,
                r#"{{"name":"save.discover","ph":"X","ts":1700000000000000,"dur":{},"pid":12345,"tid":1,"args":{{}}}}"#,
                dur
            )
            .unwrap();
        }
        // 3 events for restore.total (should NOT match save.*)
        for dur in [100000, 200000, 300000] {
            writeln!(
                f,
                r#"{{"name":"restore.total","ph":"X","ts":1700000000000000,"dur":{},"pid":12345,"tid":1,"args":{{}}}}"#,
                dur
            )
            .unwrap();
        }
        drop(f);

        // Test with exact name
        let stats = summarise(dir.path(), "save.total");
        assert_eq!(stats.spans.len(), 1);
        let s = &stats.spans[0];
        assert_eq!(s.name, "save.total");
        assert_eq!(s.count, 10);
        assert!((s.min_ms() - 13.0).abs() < 0.5, "min={}", s.min_ms());
        assert!((s.max_ms() - 32.0).abs() < 0.5, "max={}", s.max_ms());
        // mean = (13+15+17+18+19+20+21+22+24+32)/10 = 201/10 = 20.1 ms
        assert!((s.mean_ms() - 20.1).abs() < 0.5, "mean={}", s.mean_ms());
        // sorted: 13,15,17,18,19,20,21,22,24,32 (ms)
        // p50: rank=0.5*9=4.5 → 19*0.5+20*0.5=19.5
        assert!((s.p50_ms() - 19.5).abs() < 0.5, "p50={}", s.p50_ms());
        // p95: rank=0.95*9=8.55 → 24*0.45+32*0.55=28.4
        assert!((s.p95_ms() - 28.4).abs() < 0.5, "p95={}", s.p95_ms());
        // p99: rank=0.99*9=8.91 → 24*0.09+32*0.91=31.28
        assert!((s.p99_ms() - 31.28).abs() < 0.5, "p99={}", s.p99_ms());

        // Test with glob
        let stats = summarise(dir.path(), "save.*");
        assert_eq!(stats.spans.len(), 2);
        assert_eq!(stats.spans[0].name, "save.discover");
        assert_eq!(stats.spans[1].name, "save.total");
        assert_eq!(stats.spans[0].count, 5);
        assert_eq!(stats.spans[1].count, 10);

        // Test glob * matches everything
        let stats = summarise(dir.path(), "*");
        assert_eq!(stats.spans.len(), 3);

        // Test empty dir
        let empty = tempfile::tempdir().unwrap();
        let stats = summarise(empty.path(), "save.*");
        assert!(stats.spans.is_empty());
    }

    /// Verify that non-existent trace dir returns empty stats (not an error).
    #[test]
    fn summarise_nonexistent_dir() {
        let stats = summarise(Path::new("/nonexistent/path/xyz"), "save.*");
        assert!(stats.spans.is_empty());
    }

    /// Verify malformed JSONL lines are skipped gracefully.
    #[test]
    fn summarise_skips_malformed_lines() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("rust-1.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();
        writeln!(f, "not valid json at all").unwrap();
        writeln!(f, r#"{{"no_name_field": true}}"#).unwrap();
        writeln!(
            f,
            r#"{{"name":"save.total","ph":"X","ts":0,"dur":5000,"pid":1,"tid":1,"args":{{}}}}"#
        )
        .unwrap();
        drop(f);

        let stats = summarise(dir.path(), "*");
        assert_eq!(stats.spans.len(), 1);
        assert_eq!(stats.spans[0].count, 1);
    }

    /// Golden fixture: assert each percentile to within ±0.5 ms as
    /// required by the acceptance criteria.
    #[test]
    fn summarise_golden_percentiles_within_tolerance() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();

        // 20 events with known durations (microseconds):
        // sorted: 1000 2000 3000 4000 5000 6000 7000 8000 9000 10000
        //         11000 12000 13000 14000 15000 16000 17000 18000 19000 20000
        for i in 1..=20 {
            writeln!(
                f,
                r#"{{"name":"test.span","ph":"X","ts":0,"dur":{},"pid":1,"tid":1,"args":{{}}}}"#,
                i * 1000
            )
            .unwrap();
        }
        drop(f);

        let stats = summarise(dir.path(), "test.span");
        let s = &stats.spans[0];
        assert_eq!(s.count, 20);

        // min = 1ms, max = 20ms
        assert!((s.min_ms() - 1.0).abs() < 0.5, "min={}", s.min_ms());
        assert!((s.max_ms() - 20.0).abs() < 0.5, "max={}", s.max_ms());

        // mean = (1+2+...+20)/20 = 210/20 = 10.5 ms
        assert!((s.mean_ms() - 10.5).abs() < 0.5, "mean={}", s.mean_ms());

        // p50: rank=0.5*19=9.5 → sorted[9]*0.5+sorted[10]*0.5 = 10*0.5+11*0.5=10.5
        assert!((s.p50_ms() - 10.5).abs() < 0.5, "p50={}", s.p50_ms());

        // p95: rank=0.95*19=18.05 → sorted[18]*0.95+sorted[19]*0.05 = 19*0.95+20*0.05=19.05
        assert!((s.p95_ms() - 19.05).abs() < 0.5, "p95={}", s.p95_ms());

        // p99: rank=0.99*19=18.81 → sorted[18]*0.19+sorted[19]*0.81 = 19*0.19+20*0.81=19.81
        assert!((s.p99_ms() - 19.81).abs() < 0.5, "p99={}", s.p99_ms());
    }

    /// Verify that multiple JSONL files in the same dir are aggregated.
    #[test]
    fn summarise_multiple_jsonl_files() {
        let dir = tempfile::tempdir().unwrap();

        let mut f1 = fs::File::create(dir.path().join("rust-100.jsonl")).unwrap();
        for dur in [5000, 10000, 15000] {
            writeln!(
                f1,
                r#"{{"name":"save.total","ph":"X","ts":0,"dur":{},"pid":100,"tid":1,"args":{{}}}}"#,
                dur
            )
            .unwrap();
        }
        drop(f1);

        let mut f2 = fs::File::create(dir.path().join("rust-200.jsonl")).unwrap();
        for dur in [20000, 25000] {
            writeln!(
                f2,
                r#"{{"name":"save.total","ph":"X","ts":0,"dur":{},"pid":200,"tid":1,"args":{{}}}}"#,
                dur
            )
            .unwrap();
        }
        drop(f2);

        let stats = summarise(dir.path(), "save.total");
        assert_eq!(stats.spans.len(), 1);
        assert_eq!(stats.spans[0].count, 5);
        assert!((stats.spans[0].min_ms() - 5.0).abs() < 0.5);
        assert!((stats.spans[0].max_ms() - 25.0).abs() < 0.5);
    }

    // ── stddev_us tests ──────────────────────────────────────────

    #[test]
    fn stddev_computed_correctly() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();

        // 5 events with durations: 2, 4, 4, 4, 5 (in us)
        // mean = 19/5 = 3.8
        // variance = ((2-3.8)^2 + (4-3.8)^2 + (4-3.8)^2 + (4-3.8)^2 + (5-3.8)^2) / 5
        //          = (3.24 + 0.04 + 0.04 + 0.04 + 1.44) / 5
        //          = 4.8 / 5 = 0.96
        // stddev = sqrt(0.96) ≈ 0.9798
        for dur in [2, 4, 4, 4, 5] {
            writeln!(
                f,
                r#"{{"name":"test","ph":"X","ts":0,"dur":{},"pid":1,"tid":1,"args":{{}}}}"#,
                dur
            )
            .unwrap();
        }
        drop(f);

        let stats = summarise(dir.path(), "test");
        let s = &stats.spans[0];
        let expected_stddev = (0.96_f64).sqrt();
        assert!(
            (s.stddev_us - expected_stddev).abs() < 0.001,
            "stddev_us={}, expected={}",
            s.stddev_us,
            expected_stddev
        );
    }

    #[test]
    fn stddev_single_value_is_zero() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();
        writeln!(
            f,
            r#"{{"name":"test","ph":"X","ts":0,"dur":42000,"pid":1,"tid":1,"args":{{}}}}"#
        )
        .unwrap();
        drop(f);

        let stats = summarise(dir.path(), "test");
        let s = &stats.spans[0];
        assert!(
            s.stddev_us.abs() < f64::EPSILON,
            "single value stddev should be 0, got {}",
            s.stddev_us
        );
    }

    #[test]
    fn stddev_ms_conversion() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();
        // 1000 us and 3000 us → mean=2000, variance=1000000, stddev=1000 us = 1.0 ms
        for dur in [1000, 3000] {
            writeln!(
                f,
                r#"{{"name":"test","ph":"X","ts":0,"dur":{},"pid":1,"tid":1,"args":{{}}}}"#,
                dur
            )
            .unwrap();
        }
        drop(f);

        let stats = summarise(dir.path(), "test");
        let s = &stats.spans[0];
        assert!(
            (s.stddev_ms() - 1.0).abs() < 0.001,
            "stddev_ms={}, expected=1.0",
            s.stddev_ms()
        );
    }

    // ── summarise_all / Report tests ─────────────────────────────

    #[test]
    fn summarise_all_returns_all_spans() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();
        for name in ["save.total", "save.discover", "restore.total"] {
            writeln!(
                f,
                r#"{{"name":"{}","ph":"X","ts":0,"dur":10000,"pid":1,"tid":1,"args":{{}}}}"#,
                name
            )
            .unwrap();
        }
        drop(f);

        let report = summarise_all(dir.path());
        assert_eq!(report.spans.len(), 3);
        // Verify all names present via span() accessor
        assert_eq!(report.span("save.total").count, 1);
        assert_eq!(report.span("save.discover").count, 1);
        assert_eq!(report.span("restore.total").count, 1);
    }

    #[test]
    fn sort_by_p50_contribution_computes_pct() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();
        // root: p50 = 100000 us (single value)
        writeln!(
            f,
            r#"{{"name":"root","ph":"X","ts":0,"dur":100000,"pid":1,"tid":1,"args":{{}}}}"#
        )
        .unwrap();
        // child: p50 = 45000 us → 45% contribution
        writeln!(
            f,
            r#"{{"name":"child","ph":"X","ts":0,"dur":45000,"pid":1,"tid":1,"args":{{}}}}"#
        )
        .unwrap();
        // small: p50 = 5000 us → 5% contribution
        writeln!(
            f,
            r#"{{"name":"small","ph":"X","ts":0,"dur":5000,"pid":1,"tid":1,"args":{{}}}}"#
        )
        .unwrap();
        drop(f);

        let mut report = summarise_all(dir.path());
        report.sort_by_p50_contribution("root");

        // Root should be 100%
        let root = report.span("root");
        assert!(
            (root.contribution_pct.unwrap() - 100.0).abs() < 0.01,
            "root contribution={}",
            root.contribution_pct.unwrap()
        );

        // Child should be 45%
        let child = report.span("child");
        assert!(
            (child.contribution_pct.unwrap() - 45.0).abs() < 0.01,
            "child contribution={}",
            child.contribution_pct.unwrap()
        );

        // Small should be 5%
        let small = report.span("small");
        assert!(
            (small.contribution_pct.unwrap() - 5.0).abs() < 0.01,
            "small contribution={}",
            small.contribution_pct.unwrap()
        );

        // Verify sorted by p50 descending
        assert_eq!(report.spans[0].name, "root");
        assert_eq!(report.spans[1].name, "child");
        assert_eq!(report.spans[2].name, "small");
    }

    #[test]
    fn contribution_pct_capped_at_100() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();
        // root span with p50 = 10000
        writeln!(
            f,
            r#"{{"name":"root","ph":"X","ts":0,"dur":10000,"pid":1,"tid":1,"args":{{}}}}"#
        )
        .unwrap();
        // child span with p50 = 20000 (exceeds root — capped at 100%)
        writeln!(
            f,
            r#"{{"name":"child","ph":"X","ts":0,"dur":20000,"pid":1,"tid":1,"args":{{}}}}"#
        )
        .unwrap();
        drop(f);

        let mut report = summarise_all(dir.path());
        report.sort_by_p50_contribution("root");

        let child = report.span("child");
        assert!(
            (child.contribution_pct.unwrap() - 100.0).abs() < 0.01,
            "should be capped at 100, got {}",
            child.contribution_pct.unwrap()
        );
    }

    #[test]
    #[should_panic(expected = "span 'nonexistent' not found in report")]
    fn report_span_panics_on_missing_name() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();
        writeln!(
            f,
            r#"{{"name":"exists","ph":"X","ts":0,"dur":1000,"pid":1,"tid":1,"args":{{}}}}"#
        )
        .unwrap();
        drop(f);

        let report = summarise_all(dir.path());
        let _ = report.span("nonexistent");
    }

    // ── write_markdown tests ─────────────────────────────────────

    #[test]
    fn write_markdown_produces_valid_output() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();
        // Root span
        for dur in [19000, 20000, 21000] {
            writeln!(
                f,
                r#"{{"name":"restore.total","ph":"X","ts":0,"dur":{},"pid":1,"tid":1,"args":{{}}}}"#,
                dur
            )
            .unwrap();
        }
        // Child span
        for dur in [8000, 9000, 10000] {
            writeln!(
                f,
                r#"{{"name":"restore.tmux","ph":"X","ts":0,"dur":{},"pid":1,"tid":1,"args":{{}}}}"#,
                dur
            )
            .unwrap();
        }
        drop(f);

        let mut report = summarise_all(dir.path());
        report.sort_by_p50_contribution("restore.total");

        let md_path = dir.path().join("report.md");
        let metadata = ReportMetadata {
            workload_name: "test-workload".to_string(),
            iterations: 30,
            hardware: "test-hw".to_string(),
            kitty_version: "0.30.0".to_string(),
            nvim_version: "0.10.0".to_string(),
            tmux_version: "3.4".to_string(),
        };
        report.write_markdown(&md_path, &metadata).unwrap();

        let content = fs::read_to_string(&md_path).unwrap();

        // Check key headers
        assert!(
            content.contains("# Restore Latency Baseline"),
            "missing title"
        );
        assert!(content.contains("test-workload"), "missing workload name");
        assert!(content.contains("## Methodology"), "missing methodology");
        assert!(content.contains("Iterations: 30"), "missing iterations");
        assert!(content.contains("## Results"), "missing results");

        // Check table headers
        assert!(content.contains("| Span |"), "missing table header");
        assert!(content.contains("p50 (ms)"), "missing p50 column header");
        assert!(
            content.contains("stddev (ms)"),
            "missing stddev column header"
        );
        assert!(
            content.contains("contribution %"),
            "missing contribution header"
        );

        // Check span names appear (top 5 are bolded)
        assert!(
            content.contains("**restore.total**"),
            "top span should be bolded"
        );

        // Check metadata fields
        assert!(content.contains("kitty: 0.30.0"), "missing kitty version");
        assert!(content.contains("nvim: 0.10.0"), "missing nvim version");
        assert!(content.contains("tmux: 3.4"), "missing tmux version");
        assert!(content.contains("Hardware: test-hw"), "missing hardware");
    }

    #[test]
    fn contribution_pct_none_before_sort() {
        let dir = tempfile::tempdir().unwrap();
        let jsonl_path = dir.path().join("test.jsonl");
        let mut f = fs::File::create(&jsonl_path).unwrap();
        writeln!(
            f,
            r#"{{"name":"test","ph":"X","ts":0,"dur":1000,"pid":1,"tid":1,"args":{{}}}}"#
        )
        .unwrap();
        drop(f);

        let stats = summarise(dir.path(), "*");
        assert!(
            stats.spans[0].contribution_pct.is_none(),
            "contribution_pct should be None before sort_by_p50_contribution"
        );
    }
}
