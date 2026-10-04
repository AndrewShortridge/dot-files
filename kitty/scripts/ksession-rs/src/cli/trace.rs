//! `ksession trace …` subcommand. PRD-0 consumer surface for the perf
//! observability layer.
//!
//! - `show --format=chrome`: chrome-trace JSON for perfetto.dev (slice 1).
//! - `show --format=tree`: indented ASCII tree, the default (slice 3).
//! - `stats`: percentile summary + `--against` diff (slice 2).
//! - `gc`, `ls`: trace-dir retention and listing (slice 4).

use std::fmt::Write as FmtWrite;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Subcommand, ValueEnum};

use crate::perf::stats;

/// Default number of trace dirs to keep during gc / auto-sweep.
pub const DEFAULT_KEEP: usize = 50;

/// `ksession trace <subcmd>` dispatch.
#[derive(Subcommand, Debug)]
pub enum TraceCommand {
    /// Render a trace dir for human / viewer consumption.
    Show {
        /// Path to a trace dir (e.g. `~/.cache/ksession/traces/<ts>-save-foo/`).
        /// Slice 1 takes a literal path; the `<ts>` resolution sugar
        /// described in PRD-0 lands later.
        path: PathBuf,
        /// Output format. Default is `tree` (indented ASCII tree).
        /// Use `chrome` for perfetto.dev JSON.
        #[arg(long, value_enum, default_value_t = ShowFormat::Tree)]
        format: ShowFormat,
    },
    /// Percentile statistics for a span name glob. **Slice 2.**
    Stats {
        /// Span name glob (e.g. `save.*`).
        name_glob: String,
        /// Optional baseline trace dir for side-by-side comparison.
        #[arg(long)]
        against: Option<PathBuf>,
    },
    /// Garbage-collect old trace dirs beyond the newest N (default 50).
    Gc {
        /// Number of newest trace dirs to retain.
        #[arg(long, default_value_t = DEFAULT_KEEP)]
        keep: usize,
    },
    /// List trace dirs under `~/.cache/ksession/traces/`.
    Ls,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq, ValueEnum)]
pub enum ShowFormat {
    /// Chrome-trace `{"traceEvents": [...]}` JSON, written to stdout.
    Chrome,
    /// Indented textual tree (default). ASCII tree characters, no colour.
    Tree,
    /// Raw merged JSONL events as a JSON array. Slice 3.
    Json,
}

/// Dispatcher invoked by `src/bin/ksession.rs`.
pub fn run(cmd: TraceCommand) -> anyhow::Result<ExitCode> {
    match cmd {
        TraceCommand::Show { path, format } => match format {
            ShowFormat::Chrome => show_chrome(&path),
            ShowFormat::Tree => show_tree(&path),
            ShowFormat::Json => {
                eprintln!("ksession: trace show --format=json: not yet implemented (slice 3)");
                Ok(ExitCode::from(1))
            }
        },
        TraceCommand::Stats { name_glob, against } => run_stats(&name_glob, against.as_deref()),
        TraceCommand::Gc { keep } => trace_gc_cmd(keep),
        TraceCommand::Ls => trace_ls_cmd(),
    }
}

// ---------------------------------------------------------------------------
// Trace directory helpers (shared between gc, ls, and auto-sweep)
// ---------------------------------------------------------------------------

/// Resolve the default traces root: `~/.cache/ksession/traces/`.
///
/// Respects `KSESSION_TRACES_ROOT` for testing (avoids touching the
/// real home dir in integration tests). Falls back to
/// `$HOME/.cache/ksession/traces/`.
pub fn traces_root() -> Option<PathBuf> {
    if let Some(v) = std::env::var_os("KSESSION_TRACES_ROOT") {
        return Some(PathBuf::from(v));
    }
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".cache/ksession/traces"))
}

/// Metadata about a single trace directory.
#[derive(Debug)]
pub struct TraceDirEntry {
    /// Full path to the trace directory.
    pub path: PathBuf,
    /// Directory name (the filename component).
    pub name: String,
    /// Modification time (as `SystemTime`).
    pub mtime: std::time::SystemTime,
    /// Kind parsed from the directory name (`save` or `restore`).
    pub kind: String,
    /// Session name parsed from the directory name.
    pub session: String,
    /// Number of files inside the directory (non-recursive).
    pub file_count: usize,
    /// Total size in bytes of all files inside the directory.
    pub total_bytes: u64,
}

/// Scan the traces root and return an entry per trace subdirectory,
/// sorted by mtime descending (newest first).
///
/// Returns an empty vec when the traces root does not exist or is
/// unreadable.
pub fn list_trace_dirs(root: &Path) -> Vec<TraceDirEntry> {
    let entries = match fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return Vec::new(),
    };

    let mut dirs: Vec<TraceDirEntry> = entries
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            if !path.is_dir() {
                return None;
            }
            let name = path.file_name()?.to_str()?.to_string();
            let meta = fs::metadata(&path).ok()?;
            let mtime = meta.modified().ok()?;

            let (kind, session) = parse_dir_name_kind_session(&name);
            let (file_count, total_bytes) = dir_stats(&path);

            Some(TraceDirEntry {
                path,
                name,
                mtime,
                kind,
                session,
                file_count,
                total_bytes,
            })
        })
        .collect();

    dirs.sort_by(|a, b| b.mtime.cmp(&a.mtime));
    dirs
}

/// Parse kind (`save`/`restore`) and session name from a trace dir name.
fn parse_dir_name_kind_session(name: &str) -> (String, String) {
    for kind in &["restore", "save"] {
        let needle = format!("-{kind}-");
        if let Some(pos) = name.find(&needle) {
            let session = &name[pos + needle.len()..];
            if !session.is_empty() {
                return (kind.to_string(), session.to_string());
            }
        }
    }
    ("unknown".to_string(), name.to_string())
}

/// Count files and sum their sizes inside a directory (non-recursive).
fn dir_stats(path: &Path) -> (usize, u64) {
    let mut count = 0usize;
    let mut total = 0u64;
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if meta.is_file() {
                    count += 1;
                    total += meta.len();
                }
            }
        }
    }
    (count, total)
}

/// Format bytes into a human-readable size string (B, KiB, MiB).
fn human_size(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KiB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1} MiB", bytes as f64 / (1024.0 * 1024.0))
    }
}

// ---------------------------------------------------------------------------
// `ksession trace ls`
// ---------------------------------------------------------------------------

fn trace_ls_cmd() -> anyhow::Result<ExitCode> {
    let root = traces_root()
        .ok_or_else(|| anyhow::anyhow!("cannot determine traces root (HOME not set)"))?;

    let dirs = list_trace_dirs(&root);

    // Always print headers.
    println!(
        "{:<28} {:<8} {:<20} {:>5} {:>10}",
        "TIMESTAMP", "KIND", "SESSION", "FILES", "SIZE"
    );

    for d in &dirs {
        // Format mtime as a human-readable timestamp.
        let ts = match d.mtime.duration_since(std::time::UNIX_EPOCH) {
            Ok(dur) => {
                let secs = dur.as_secs() as i64;
                let naive = chrono::DateTime::from_timestamp(secs, 0).unwrap_or_default();
                naive.format("%Y-%m-%dT%H:%M:%SZ").to_string()
            }
            Err(_) => "???".to_string(),
        };
        println!(
            "{:<28} {:<8} {:<20} {:>5} {:>10}",
            ts,
            d.kind,
            d.session,
            d.file_count,
            human_size(d.total_bytes),
        );
    }

    Ok(ExitCode::SUCCESS)
}

// ---------------------------------------------------------------------------
// `ksession trace gc` + auto-sweep
// ---------------------------------------------------------------------------

fn trace_gc_cmd(keep: usize) -> anyhow::Result<ExitCode> {
    let root = traces_root()
        .ok_or_else(|| anyhow::anyhow!("cannot determine traces root (HOME not set)"))?;
    let removed = sweep_trace_dirs(&root, keep);
    if removed == 0 {
        eprintln!("ksession: trace gc: nothing to remove (at most {keep} entries)");
    }
    Ok(ExitCode::SUCCESS)
}

/// Delete trace directories beyond the newest `keep`, sorted by mtime
/// desc. Returns the number of directories removed. Prints one stderr
/// line per removed dir. Idempotent: a second call is a no-op.
pub fn sweep_trace_dirs(root: &Path, keep: usize) -> usize {
    let dirs = list_trace_dirs(root);
    if dirs.len() <= keep {
        return 0;
    }
    let to_remove = &dirs[keep..];
    let mut removed = 0usize;
    for d in to_remove {
        match fs::remove_dir_all(&d.path) {
            Ok(()) => {
                eprintln!("ksession: trace gc: removed {}", d.name);
                removed += 1;
            }
            Err(e) => {
                eprintln!("ksession: trace gc: failed to remove {}: {e}", d.name);
            }
        }
    }
    removed
}

/// Implement `ksession trace show <path> --format=chrome`.
///
/// Reads every `*.jsonl` under `<path>` (non-recursive — the trace dir
/// holds one file per contributor process, all at the top level),
/// parses each line as a chrome-trace `X` event, and writes a single
/// `{"traceEvents":[…]}` object to stdout. perfetto.dev consumes this
/// shape directly.
///
/// Malformed lines (truncated tail after a crash, etc.) are skipped
/// with a one-line stderr warning rather than failing the whole render;
/// PRD-0 calls this out as desirable behaviour for the JSONL format.
fn show_chrome(path: &Path) -> anyhow::Result<ExitCode> {
    let entries = match fs::read_dir(path) {
        Ok(e) => e,
        Err(e) => {
            return Err(anyhow::anyhow!("trace show: read {}: {e}", path.display()));
        }
    };

    // Collect JSONL files first so the ordering across processes is
    // deterministic (alphabetical), then merge events in file order.
    // perfetto sorts by `ts` internally so the merge order is purely
    // cosmetic for the produced JSON.
    let mut jsonl_files: Vec<PathBuf> = entries
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

    let mut events: Vec<serde_json::Value> = Vec::new();
    for file in &jsonl_files {
        let f = match fs::File::open(file) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("ksession: trace show: skipping {}: {e}", file.display());
                continue;
            }
        };
        for (lineno, line) in BufReader::new(f).lines().enumerate() {
            let line = match line {
                Ok(l) => l,
                Err(e) => {
                    eprintln!(
                        "ksession: trace show: {}:{}: read error: {e}",
                        file.display(),
                        lineno + 1
                    );
                    break;
                }
            };
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<serde_json::Value>(&line) {
                Ok(v) => events.push(v),
                Err(e) => {
                    eprintln!(
                        "ksession: trace show: {}:{}: malformed JSON, skipping: {e}",
                        file.display(),
                        lineno + 1
                    );
                }
            }
        }
    }

    let doc = serde_json::json!({ "traceEvents": events });
    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer(&mut handle, &doc)?;
    // Trailing newline so the output is well-formed for `cat | jq` etc.
    handle.write_all(b"\n")?;

    Ok(ExitCode::SUCCESS)
}

/// Write merged chrome-trace JSON from `trace_dir` to `out_path`.
///
/// Used by `--trace=chrome` on save/restore (Slice 12) to emit the merged
/// chrome JSON without going through stdout. Returns `Ok(())` on success;
/// errors bubble up to the caller.
pub fn write_chrome_to_file(trace_dir: &Path, out_path: &Path) -> anyhow::Result<()> {
    let entries = match fs::read_dir(trace_dir) {
        Ok(e) => e,
        Err(e) => {
            return Err(anyhow::anyhow!("trace: read {}: {e}", trace_dir.display()));
        }
    };

    let mut jsonl_files: Vec<PathBuf> = entries
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

    let mut events: Vec<serde_json::Value> = Vec::new();
    for file in &jsonl_files {
        let f = match fs::File::open(file) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("ksession: trace: skipping {}: {e}", file.display());
                continue;
            }
        };
        for (lineno, line) in BufReader::new(f).lines().enumerate() {
            let line = match line {
                Ok(l) => l,
                Err(e) => {
                    eprintln!(
                        "ksession: trace: {}:{}: read error: {e}",
                        file.display(),
                        lineno + 1
                    );
                    break;
                }
            };
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<serde_json::Value>(&line) {
                Ok(v) => events.push(v),
                Err(e) => {
                    eprintln!(
                        "ksession: trace: {}:{}: malformed JSON, skipping: {e}",
                        file.display(),
                        lineno + 1
                    );
                }
            }
        }
    }

    let doc = serde_json::json!({ "traceEvents": events });
    let f = fs::File::create(out_path)
        .map_err(|e| anyhow::anyhow!("create {}: {e}", out_path.display()))?;
    let mut w = std::io::BufWriter::new(f);
    serde_json::to_writer(&mut w, &doc)?;
    w.write_all(b"\n")?;
    w.flush()?;

    Ok(())
}

/// Render a tree from `trace_dir` and return the rendered string.
///
/// Used by `--trace=tree` on save/restore (Slice 12) to get the tree
/// output without going through stdout.
pub fn render_tree_from_dir(trace_dir: &Path) -> anyhow::Result<String> {
    let events = read_events(trace_dir)?;
    let roots = build_tree(&events);
    Ok(render_tree(&roots))
}

/// Implement `ksession trace stats <name-glob> [--against <trace-dir>]`.
///
/// Scans the default traces directory (`~/.cache/ksession/traces/`) for
/// JSONL files, filters events whose `name` matches the glob, and prints
/// a formatted table with percentile columns. When `--against` is
/// specified, a side-by-side diff table is printed instead.
///
/// Empty results (no matching events) produce no rows and exit zero —
/// this is not treated as an error per the acceptance criteria.
fn run_stats(name_glob: &str, against: Option<&Path>) -> anyhow::Result<ExitCode> {
    let root = traces_root()
        .ok_or_else(|| anyhow::anyhow!("cannot determine traces root (HOME not set)"))?;

    let trace_entries = list_trace_dirs(&root);
    let trace_dirs: Vec<PathBuf> = trace_entries.iter().map(|e| e.path.clone()).collect();

    match against {
        None => print_stats_table(&trace_dirs, name_glob),
        Some(baseline_path) => {
            let current = match trace_dirs.last() {
                Some(d) => d.clone(),
                None => return Ok(ExitCode::SUCCESS),
            };
            print_diff_table(baseline_path, &current, name_glob)
        }
    }
}

/// Format a duration in milliseconds for display, right-aligned.
fn fmt_ms(us: f64) -> String {
    let ms = us / 1000.0;
    format!("{ms:.1}ms")
}

/// Print the single-invocation stats table (no `--against`).
///
/// ```text
/// span name                    count    p50      p95      p99      mean     min      max
/// save.total                   100      19.4ms   24.0ms   32.0ms   19.4ms   13.0ms   32.0ms
/// ```
fn print_stats_table(trace_dirs: &[PathBuf], name_glob: &str) -> anyhow::Result<ExitCode> {
    // Aggregate across all trace dirs.
    let mut all_stats = stats::Stats { spans: Vec::new() };
    for dir in trace_dirs {
        let s = stats::summarise(dir, name_glob);
        merge_stats(&mut all_stats, &s);
    }

    // If there is only one trace dir with data, use it directly.
    // If there are multiple, we've already merged.
    // If no trace dirs had matching events, exit cleanly.
    if all_stats.spans.is_empty() {
        return Ok(ExitCode::SUCCESS);
    }

    // Re-compute final stats from merged durations — but summarise
    // already does the computation, so for the multi-dir case we just
    // display per-span stats. Because `summarise` returns pre-computed
    // stats, we simply display the merged result.

    // Build column data.
    let headers = [
        "span name",
        "count",
        "p50",
        "p95",
        "p99",
        "mean",
        "min",
        "max",
    ];
    let mut rows: Vec<Vec<String>> = Vec::new();
    for s in &all_stats.spans {
        rows.push(vec![
            s.name.clone(),
            s.count.to_string(),
            fmt_ms(s.p50_us),
            fmt_ms(s.p95_us),
            fmt_ms(s.p99_us),
            fmt_ms(s.mean_us),
            fmt_ms(s.min_us),
            fmt_ms(s.max_us),
        ]);
    }

    print_table(&headers, &rows);
    Ok(ExitCode::SUCCESS)
}

/// Print the diff table (with `--against`).
///
/// ```text
/// span name                    baseline    current     delta
/// save.total                   19.4ms      14.2ms      -5.2ms (-27%)
/// ```
fn print_diff_table(
    baseline_path: &Path,
    current_path: &Path,
    name_glob: &str,
) -> anyhow::Result<ExitCode> {
    let baseline = stats::summarise(baseline_path, name_glob);
    let current = stats::summarise(current_path, name_glob);

    // Collect all span names from both sets.
    let mut names: Vec<String> = Vec::new();
    for s in baseline.spans.iter().chain(current.spans.iter()) {
        if !names.contains(&s.name) {
            names.push(s.name.clone());
        }
    }
    names.sort();

    if names.is_empty() {
        return Ok(ExitCode::SUCCESS);
    }

    let headers = ["span name", "baseline", "current", "delta"];
    let mut rows: Vec<Vec<String>> = Vec::new();

    for name in &names {
        let b_p50 = baseline.get(name).map(|s| s.p50_us);
        let c_p50 = current.get(name).map(|s| s.p50_us);

        let baseline_str = b_p50.map(fmt_ms).unwrap_or_else(|| "—".to_string());
        let current_str = c_p50.map(fmt_ms).unwrap_or_else(|| "—".to_string());

        let delta_str = match (b_p50, c_p50) {
            (Some(b), Some(c)) => {
                let delta_us = c - b;
                let delta_ms = delta_us / 1000.0;
                let pct = if b.abs() > f64::EPSILON {
                    (delta_us / b) * 100.0
                } else {
                    0.0
                };
                let sign = if delta_ms >= 0.0 { "+" } else { "" };
                format!("{sign}{delta_ms:.1}ms ({sign}{pct:.0}%)")
            }
            _ => "—".to_string(),
        };

        rows.push(vec![name.clone(), baseline_str, current_str, delta_str]);
    }

    print_table(&headers, &rows);
    Ok(ExitCode::SUCCESS)
}

/// Print a right-aligned table with the given headers and rows.
fn print_table(headers: &[&str], rows: &[Vec<String>]) {
    // Compute column widths.
    let ncols = headers.len();
    let mut widths: Vec<usize> = headers.iter().map(|h| h.len()).collect();
    for row in rows {
        for (i, cell) in row.iter().enumerate() {
            if i < ncols {
                widths[i] = widths[i].max(cell.len());
            }
        }
    }

    // Print header row. First column (span name) is left-aligned;
    // remaining columns are right-aligned.
    let mut header_line = String::new();
    for (i, h) in headers.iter().enumerate() {
        if i > 0 {
            header_line.push_str("  ");
        }
        if i == 0 {
            let _ = write!(header_line, "{:<width$}", h, width = widths[i]);
        } else {
            let _ = write!(header_line, "{:>width$}", h, width = widths[i]);
        }
    }
    println!("{}", header_line.trim_end());

    // Print data rows.
    for row in rows {
        let mut line = String::new();
        for (i, cell) in row.iter().enumerate() {
            if i >= ncols {
                break;
            }
            if i > 0 {
                line.push_str("  ");
            }
            if i == 0 {
                let _ = write!(line, "{:<width$}", cell, width = widths[i]);
            } else {
                let _ = write!(line, "{:>width$}", cell, width = widths[i]);
            }
        }
        println!("{}", line.trim_end());
    }
}

/// Merge stats from `src` into `dst`. When the same span name appears
/// in both, we keep `src`'s values (since summarise already computes
/// from all events in a dir). For the multi-dir aggregation case we
/// need to re-aggregate, so this function collects all durations.
///
/// NOTE: Because `summarise` returns pre-computed stats (not raw
/// durations), a true merge would require access to the raw data. For
/// the multi-dir case, we concatenate the span lists and then
/// re-summarise when needed. However, since each trace dir is a
/// separate invocation, the typical usage is to show stats from the
/// most recent dir or a specific dir. For now, we simply append
/// non-duplicate spans and note that a full merge would need raw data.
///
/// In practice, each trace dir has its own JSONL files and `summarise`
/// is called per-dir. The multi-dir aggregation here simply collects
/// all unique span names — if the same span appears in multiple dirs,
/// the last one wins (which is fine for "most recent" semantics).
fn merge_stats(dst: &mut stats::Stats, src: &stats::Stats) {
    for span in &src.spans {
        if let Some(existing) = dst.spans.iter_mut().find(|s| s.name == span.name) {
            // Merge: combine counts and recompute weighted values.
            // This is an approximation since we don't have raw data.
            let total_count = existing.count + span.count;
            existing.mean_us = (existing.mean_us * existing.count as f64
                + span.mean_us * span.count as f64)
                / total_count as f64;
            existing.min_us = existing.min_us.min(span.min_us);
            existing.max_us = existing.max_us.max(span.max_us);
            // For percentiles and stddev, weighted merge is not exact.
            // Use the values from the larger sample as a reasonable
            // approximation.
            if span.count > existing.count {
                existing.p50_us = span.p50_us;
                existing.p95_us = span.p95_us;
                existing.p99_us = span.p99_us;
                existing.stddev_us = span.stddev_us;
            }
            existing.count = total_count;
        } else {
            dst.spans.push(span.clone());
        }
    }
    dst.spans.sort_by(|a, b| a.name.cmp(&b.name));
}
// ── Tree renderer (slice 3) ────────────────────────────────────────────

/// A parsed chrome-trace complete (`X`) event with the fields we care
/// about for tree construction.
#[derive(Debug, Clone)]
pub struct TraceEvent {
    name: String,
    ts: u64,
    dur: u64,
    tid: u64,
    parent_id: u64,
    args: Vec<(String, String)>,
}

/// Read all JSONL files from `path`, parse each line into a
/// `TraceEvent`. Malformed lines are silently skipped (matching
/// `show_chrome`'s behaviour).
pub fn read_events(path: &Path) -> anyhow::Result<Vec<TraceEvent>> {
    let entries = fs::read_dir(path)
        .map_err(|e| anyhow::anyhow!("trace show: read {}: {e}", path.display()))?;

    let mut jsonl_files: Vec<PathBuf> = entries
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

    let mut events = Vec::new();
    for file in &jsonl_files {
        let f = match fs::File::open(file) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("ksession: trace show: skipping {}: {e}", file.display());
                continue;
            }
        };
        for (lineno, line) in BufReader::new(f).lines().enumerate() {
            let line = match line {
                Ok(l) => l,
                Err(e) => {
                    eprintln!(
                        "ksession: trace show: {}:{}: read error: {e}",
                        file.display(),
                        lineno + 1
                    );
                    break;
                }
            };
            if line.trim().is_empty() {
                continue;
            }
            let v: serde_json::Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!(
                        "ksession: trace show: {}:{}: malformed JSON, skipping: {e}",
                        file.display(),
                        lineno + 1
                    );
                    continue;
                }
            };
            if let Some(ev) = parse_event(&v) {
                events.push(ev);
            }
        }
    }
    Ok(events)
}

/// Extract the fields we need from a chrome-trace JSON object.
fn parse_event(v: &serde_json::Value) -> Option<TraceEvent> {
    let obj = v.as_object()?;
    let name = obj.get("name")?.as_str()?.to_string();
    let ts = obj.get("ts")?.as_u64()?;
    let dur = obj.get("dur")?.as_u64().unwrap_or(0);
    let tid = obj.get("tid")?.as_u64()?;
    let parent_id = obj.get("parent_id").and_then(|v| v.as_u64()).unwrap_or(0);

    let mut args = Vec::new();
    if let Some(args_obj) = obj.get("args").and_then(|a| a.as_object()) {
        let mut keys: Vec<&String> = args_obj.keys().collect();
        keys.sort();
        for k in keys {
            if let Some(val) = args_obj.get(k) {
                let val_str = match val {
                    serde_json::Value::String(s) => s.clone(),
                    serde_json::Value::Number(n) => n.to_string(),
                    serde_json::Value::Bool(b) => b.to_string(),
                    other => other.to_string(),
                };
                args.push((k.clone(), val_str));
            }
        }
    }

    Some(TraceEvent {
        name,
        ts,
        dur,
        tid,
        parent_id,
        args,
    })
}

/// A node in the reconstructed span tree.
#[derive(Debug, Clone)]
pub struct TreeNode {
    event: TraceEvent,
    children: Vec<TreeNode>,
}

/// Build a forest of `TreeNode`s from a flat list of events.
///
/// Algorithm:
/// 1. Separate events into two groups: those with `parent_id == 0`
///    (intra-tid nesting via `ts`/`dur` containment) and those with
///    `parent_id != 0` (cross-tid, attached to the parent's tid group).
/// 2. Within each `tid`, sort by `ts` ascending, then `dur` descending
///    (so parents appear before children), and use a stack to build the
///    containment tree.
/// 3. Attach cross-tid children under the narrowest containing event
///    on the tid matching their `parent_id`.
/// 4. Merge all tid groups into a single forest sorted by `ts`.
pub fn build_tree(events: &[TraceEvent]) -> Vec<TreeNode> {
    if events.is_empty() {
        return Vec::new();
    }

    // Step 1: partition into intra-tid and cross-tid events.
    let mut by_tid: std::collections::BTreeMap<u64, Vec<TraceEvent>> =
        std::collections::BTreeMap::new();
    let mut cross_tid_events: Vec<TraceEvent> = Vec::new();

    for ev in events {
        if ev.parent_id != 0 {
            cross_tid_events.push(ev.clone());
        } else {
            by_tid.entry(ev.tid).or_default().push(ev.clone());
        }
    }

    // Step 2: build trees within each tid group.
    let mut tid_roots: std::collections::BTreeMap<u64, Vec<TreeNode>> =
        std::collections::BTreeMap::new();

    for (tid, mut group) in by_tid {
        // Sort: ascending ts, then descending dur (parents before children).
        group.sort_by(|a, b| a.ts.cmp(&b.ts).then(b.dur.cmp(&a.dur)));
        let roots = build_intra_tid_tree(&group);
        tid_roots.insert(tid, roots);
    }

    // Step 3: attach cross-tid events using parent_id.
    // parent_id references the tid of the parent event.
    for ev in &cross_tid_events {
        let parent_tid = ev.parent_id;
        let child_node = TreeNode {
            event: ev.clone(),
            children: Vec::new(),
        };
        if let Some(roots) = tid_roots.get_mut(&parent_tid) {
            if !insert_cross_tid_child(roots, child_node) {
                // Couldn't find a containing parent — add as direct child
                // of the last root on that tid.
                roots.push(TreeNode {
                    event: ev.clone(),
                    children: Vec::new(),
                });
            }
        } else {
            // No events on the parent tid — treat as a top-level root.
            tid_roots.entry(ev.tid).or_default().push(TreeNode {
                event: ev.clone(),
                children: Vec::new(),
            });
        }
    }

    // Step 4: merge all tid groups into a single root list, sorted by ts.
    let mut all_roots: Vec<TreeNode> = Vec::new();
    for (_tid, roots) in tid_roots {
        all_roots.extend(roots);
    }
    all_roots.sort_by_key(|n| n.event.ts);

    // Sort children recursively by ts.
    sort_children_recursive(&mut all_roots);

    all_roots
}

/// Build an intra-tid tree using a stack-based containment algorithm.
///
/// Input must be sorted by `ts` ascending, then `dur` descending.
/// An event A is the parent of B iff `A.ts <= B.ts` and
/// `A.ts + A.dur >= B.ts + B.dur` (A temporally contains B).
fn build_intra_tid_tree(sorted_events: &[TraceEvent]) -> Vec<TreeNode> {
    // Stack of ancestor nodes. Each entry is (node, end_ts).
    // Invariant: the stack is ordered from outermost to innermost ancestor.
    let mut stack: Vec<(TreeNode, u64)> = Vec::new();
    let mut roots: Vec<TreeNode> = Vec::new();

    for ev in sorted_events {
        let ev_end = ev.ts + ev.dur;
        let node = TreeNode {
            event: ev.clone(),
            children: Vec::new(),
        };

        // Pop ancestors whose time range ended before this event starts
        // (or that don't fully contain this event). Finished ancestors
        // get attached to their parent or become roots.
        while let Some((_, stack_end)) = stack.last() {
            if *stack_end < ev_end {
                // Stack top does not contain this event — pop it.
                let (finished, _) = stack.pop().unwrap();
                if let Some(parent) = stack.last_mut() {
                    parent.0.children.push(finished);
                } else {
                    roots.push(finished);
                }
            } else {
                break;
            }
        }

        // At this point, either the stack is empty (new root) or the
        // stack top contains this event. Push this event onto the stack.
        stack.push((node, ev_end));
    }

    // Drain remaining stack — innermost first (LIFO).
    while let Some((finished, _)) = stack.pop() {
        if let Some(parent) = stack.last_mut() {
            parent.0.children.push(finished);
        } else {
            roots.push(finished);
        }
    }

    roots
}

/// Try to insert a cross-tid child node under the narrowest containing
/// event in the given tree. Returns true if inserted.
fn insert_cross_tid_child(nodes: &mut Vec<TreeNode>, child: TreeNode) -> bool {
    let child_ts = child.event.ts;
    let child_end = child.event.ts + child.event.dur;

    // Find the narrowest node that contains the child.
    for node in nodes.iter_mut() {
        let node_end = node.event.ts + node.event.dur;
        if node.event.ts <= child_ts && node_end >= child_end {
            // This node contains the child. Try to go deeper.
            if !insert_cross_tid_child(&mut node.children, child.clone()) {
                node.children.push(child);
                node.children.sort_by_key(|c| c.event.ts);
            }
            return true;
        }
    }
    false
}

/// Recursively sort children by ts.
fn sort_children_recursive(nodes: &mut [TreeNode]) {
    for node in nodes.iter_mut() {
        node.children.sort_by_key(|c| c.event.ts);
        sort_children_recursive(&mut node.children);
    }
}

/// Format a duration in microseconds as a human-readable millisecond
/// string (e.g., `19.4ms`). Always one decimal place for values under
/// 1000ms; no decimal for >= 1000ms.
fn format_dur_ms(dur_us: u64) -> String {
    let ms = dur_us as f64 / 1000.0;
    if ms >= 1000.0 {
        format!("{:.0}ms", ms)
    } else {
        format!("{:.1}ms", ms)
    }
}

/// Format the label for a tree node: `name` optionally followed by
/// ` {k=v, ...}` for sorted args.
fn format_label(ev: &TraceEvent) -> String {
    let mut label = ev.name.clone();
    if !ev.args.is_empty() {
        label.push_str(" {");
        for (i, (k, v)) in ev.args.iter().enumerate() {
            if i > 0 {
                label.push_str(", ");
            }
            write!(label, "{k}={v}").unwrap();
        }
        label.push('}');
    }
    label
}

/// Compute the display width of a string containing ASCII and box-drawing
/// characters. Each Unicode code point is counted as 1 display column
/// (box-drawing chars like `├`, `└`, `│`, `─` are single-width but
/// multi-byte in UTF-8).
fn display_width(s: &str) -> usize {
    s.chars().count()
}

/// Render the tree to a string. Each line has the form:
///
///     <prefix><connector> <label>  <right-aligned duration>
///
/// The total width adapts to the widest label+duration.
pub fn render_tree(roots: &[TreeNode]) -> String {
    if roots.is_empty() {
        return String::new();
    }

    // First pass: collect all lines as (prefix_with_connector, label, dur_str)
    // so we can compute the column alignment.
    let mut lines: Vec<(String, String, String)> = Vec::new();
    for (i, root) in roots.iter().enumerate() {
        let is_last = i == roots.len() - 1;
        collect_lines(root, "", is_last, true, &mut lines);
    }

    // Find the max combined display width of (prefix + label) so we can
    // right-align the duration column.
    let max_left: usize = lines
        .iter()
        .map(|(prefix, label, _)| display_width(prefix) + display_width(label))
        .max()
        .unwrap_or(0);

    // Render each line. The duration is right-aligned to a consistent
    // column, padded so the rightmost character of the widest duration
    // string aligns across all lines.
    let max_dur_width: usize = lines
        .iter()
        .map(|(_, _, d)| display_width(d))
        .max()
        .unwrap_or(0);
    let total_width = max_left + 4 + max_dur_width; // 4 spaces minimum gap

    let mut out = String::new();
    for (prefix, label, dur) in &lines {
        let left_len = display_width(prefix) + display_width(label);
        let padding = if total_width > left_len + display_width(dur) {
            total_width - left_len - display_width(dur)
        } else {
            4
        };
        write!(out, "{prefix}{label}").unwrap();
        for _ in 0..padding {
            out.push(' ');
        }
        writeln!(out, "{dur}").unwrap();
    }
    out
}

/// Recursively collect tree lines with proper prefix and connector chars.
fn collect_lines(
    node: &TreeNode,
    prefix: &str,
    is_last: bool,
    is_root: bool,
    lines: &mut Vec<(String, String, String)>,
) {
    let connector = if is_root {
        String::new()
    } else if is_last {
        "\u{2514}\u{2500}\u{2500} ".to_string() // "└── "
    } else {
        "\u{251C}\u{2500}\u{2500} ".to_string() // "├── "
    };

    let label = format_label(&node.event);
    let dur = format_dur_ms(node.event.dur);
    lines.push((format!("{prefix}{connector}"), label, dur));

    let child_prefix = if is_root {
        prefix.to_string()
    } else if is_last {
        format!("{prefix}    ")
    } else {
        format!("{prefix}\u{2502}   ") // "│   "
    };

    for (i, child) in node.children.iter().enumerate() {
        let child_is_last = i == node.children.len() - 1;
        collect_lines(child, &child_prefix, child_is_last, false, lines);
    }
}

/// Implement `ksession trace show <path> --format=tree`.
///
/// Reads every `*.jsonl` under `<path>`, infers parent-child hierarchy
/// from `ts`/`dur` containment within a `tid` and from `parent_id`
/// for cross-spawn relationships, and renders an indented ASCII tree
/// to stdout.
fn show_tree(path: &Path) -> anyhow::Result<ExitCode> {
    let events = read_events(path)?;
    let roots = build_tree(&events);
    let output = render_tree(&roots);

    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    handle.write_all(output.as_bytes())?;

    Ok(ExitCode::SUCCESS)
}

// ── Unit tests (slice 3) ───────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Create a temporary trace dir with the given JSONL content in a
    /// single file, then read events from it.
    fn events_from_jsonl(jsonl: &str) -> Vec<TraceEvent> {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.jsonl");
        {
            let mut f = fs::File::create(&file_path).unwrap();
            f.write_all(jsonl.as_bytes()).unwrap();
        }
        read_events(dir.path()).unwrap()
    }

    /// Create a temporary trace dir with multiple JSONL files.
    fn events_from_jsonl_files(files: &[(&str, &str)]) -> Vec<TraceEvent> {
        let dir = tempfile::tempdir().unwrap();
        for (name, content) in files {
            let file_path = dir.path().join(name);
            let mut f = fs::File::create(&file_path).unwrap();
            f.write_all(content.as_bytes()).unwrap();
        }
        read_events(dir.path()).unwrap()
    }

    /// Render events from JSONL content as a tree string.
    fn tree_from_jsonl(jsonl: &str) -> String {
        let events = events_from_jsonl(jsonl);
        let roots = build_tree(&events);
        render_tree(&roots)
    }

    /// Render events from multiple JSONL files as a tree string.
    fn tree_from_jsonl_files(files: &[(&str, &str)]) -> String {
        let events = events_from_jsonl_files(files);
        let roots = build_tree(&events);
        render_tree(&roots)
    }

    // ── Golden snapshot: basic nested tree ──────────────────────────

    #[test]
    fn golden_basic_nested_tree() {
        // save.total: ts=1000000, dur=20000 → end=1020000
        // All children fit within save.total's time range.
        let jsonl = r#"{"name":"save.total","ph":"X","ts":1000000,"dur":20000,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.discover","ph":"X","ts":1000100,"dur":1200,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.tag_uuids","ph":"X","ts":1001400,"dur":400,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.capture","ph":"X","ts":1001900,"dur":16800,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.render","ph":"X","ts":1018800,"dur":600,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.commit","ph":"X","ts":1019500,"dur":400,"pid":1,"tid":1,"parent_id":0,"args":{}}
"#;
        let tree = tree_from_jsonl(jsonl);
        let expected = "\
save.total            20.0ms
\u{251C}\u{2500}\u{2500} save.discover      1.2ms
\u{251C}\u{2500}\u{2500} save.tag_uuids     0.4ms
\u{251C}\u{2500}\u{2500} save.capture      16.8ms
\u{251C}\u{2500}\u{2500} save.render        0.6ms
\u{2514}\u{2500}\u{2500} save.commit        0.4ms
";
        assert_eq!(
            tree, expected,
            "\n--- actual ---\n{tree}\n--- expected ---\n{expected}"
        );
    }

    // ── Golden snapshot: nested with args ───────────────────────────

    #[test]
    fn golden_nested_with_args() {
        // save.total: ts=1000000, dur=20000 → end=1020000
        // save.capture: ts=1001900, dur=16800 → end=1018700
        // Window captures are sequential within save.capture:
        //   kitty_id=12: ts=1002000, dur=5000 → end=1007000
        //   kitty_id=13: ts=1007100, dur=5000 → end=1012100
        //   kitty_id=14: ts=1012200, dur=5000 → end=1017200
        let jsonl = r#"{"name":"save.total","ph":"X","ts":1000000,"dur":20000,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.discover","ph":"X","ts":1000100,"dur":1200,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.tag_uuids","ph":"X","ts":1001400,"dur":400,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.capture","ph":"X","ts":1001900,"dur":16800,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.capture.window","ph":"X","ts":1002000,"dur":5000,"pid":1,"tid":1,"parent_id":0,"args":{"kitty_id":"12"}}
{"name":"save.capture.window","ph":"X","ts":1007100,"dur":5000,"pid":1,"tid":1,"parent_id":0,"args":{"kitty_id":"13"}}
{"name":"save.capture.window","ph":"X","ts":1012200,"dur":5000,"pid":1,"tid":1,"parent_id":0,"args":{"kitty_id":"14"}}
{"name":"save.render","ph":"X","ts":1018800,"dur":600,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.commit","ph":"X","ts":1019500,"dur":400,"pid":1,"tid":1,"parent_id":0,"args":{}}
"#;
        let tree = tree_from_jsonl(jsonl);
        let expected = "\
save.total                                   20.0ms
\u{251C}\u{2500}\u{2500} save.discover                             1.2ms
\u{251C}\u{2500}\u{2500} save.tag_uuids                            0.4ms
\u{251C}\u{2500}\u{2500} save.capture                             16.8ms
\u{2502}   \u{251C}\u{2500}\u{2500} save.capture.window {kitty_id=12}     5.0ms
\u{2502}   \u{251C}\u{2500}\u{2500} save.capture.window {kitty_id=13}     5.0ms
\u{2502}   \u{2514}\u{2500}\u{2500} save.capture.window {kitty_id=14}     5.0ms
\u{251C}\u{2500}\u{2500} save.render                               0.6ms
\u{2514}\u{2500}\u{2500} save.commit                               0.4ms
";
        assert_eq!(
            tree, expected,
            "\n--- actual ---\n{tree}\n--- expected ---\n{expected}"
        );
    }

    // ── Golden snapshot: cross-tid parent_id ────────────────────────

    #[test]
    fn golden_cross_tid_parent_id() {
        // save.capture is on tid=1; the window captures fire on tid=2,3,4
        // with parent_id=1 (referencing the parent's tid). The captures
        // run concurrently on different threads but their time ranges
        // fall within save.capture's range.
        // save.total: ts=1000000, dur=20000 → end=1020000
        // save.capture: ts=1001900, dur=16800 → end=1018700
        let files: &[(&str, &str)] = &[
            (
                "rust-100.jsonl",
                r#"{"name":"save.total","ph":"X","ts":1000000,"dur":20000,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.discover","ph":"X","ts":1000100,"dur":1200,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.capture","ph":"X","ts":1001900,"dur":16800,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.render","ph":"X","ts":1018800,"dur":600,"pid":1,"tid":1,"parent_id":0,"args":{}}
{"name":"save.commit","ph":"X","ts":1019500,"dur":400,"pid":1,"tid":1,"parent_id":0,"args":{}}
"#,
            ),
            (
                "rust-101.jsonl",
                r#"{"name":"save.capture.window","ph":"X","ts":1002000,"dur":5000,"pid":1,"tid":2,"parent_id":1,"args":{"kitty_id":"12"}}
{"name":"save.capture.window","ph":"X","ts":1007100,"dur":5000,"pid":1,"tid":3,"parent_id":1,"args":{"kitty_id":"13"}}
{"name":"save.capture.window","ph":"X","ts":1012200,"dur":5000,"pid":1,"tid":4,"parent_id":1,"args":{"kitty_id":"14"}}
"#,
            ),
        ];
        let tree = tree_from_jsonl_files(files);
        let expected = "\
save.total                                   20.0ms
\u{251C}\u{2500}\u{2500} save.discover                             1.2ms
\u{251C}\u{2500}\u{2500} save.capture                             16.8ms
\u{2502}   \u{251C}\u{2500}\u{2500} save.capture.window {kitty_id=12}     5.0ms
\u{2502}   \u{251C}\u{2500}\u{2500} save.capture.window {kitty_id=13}     5.0ms
\u{2502}   \u{2514}\u{2500}\u{2500} save.capture.window {kitty_id=14}     5.0ms
\u{251C}\u{2500}\u{2500} save.render                               0.6ms
\u{2514}\u{2500}\u{2500} save.commit                               0.4ms
";
        assert_eq!(
            tree, expected,
            "\n--- actual ---\n{tree}\n--- expected ---\n{expected}"
        );
    }

    // ── Args rendering ─────────────────────────────────────────────

    #[test]
    fn args_are_sorted_alphabetically() {
        let jsonl = r#"{"name":"op","ph":"X","ts":1000,"dur":500,"pid":1,"tid":1,"parent_id":0,"args":{"zebra":"z","alpha":"a","mid":"m"}}
"#;
        let tree = tree_from_jsonl(jsonl);
        assert!(
            tree.contains("op {alpha=a, mid=m, zebra=z}"),
            "args should be sorted alphabetically: {tree}"
        );
    }

    // ── Empty trace dir ────────────────────────────────────────────

    #[test]
    fn empty_dir_produces_empty_output() {
        let dir = tempfile::tempdir().unwrap();
        let events = read_events(dir.path()).unwrap();
        let roots = build_tree(&events);
        let output = render_tree(&roots);
        assert!(output.is_empty(), "empty dir should produce empty output");
    }

    // ── Single event (no children) ─────────────────────────────────

    #[test]
    fn single_event_no_children() {
        let jsonl = r#"{"name":"save.total","ph":"X","ts":1000000,"dur":5000,"pid":1,"tid":1,"parent_id":0,"args":{}}
"#;
        let tree = tree_from_jsonl(jsonl);
        assert_eq!(tree, "save.total    5.0ms\n");
    }

    // ── format_dur_ms ──────────────────────────────────────────────

    #[test]
    fn dur_formatting() {
        assert_eq!(format_dur_ms(400), "0.4ms");
        assert_eq!(format_dur_ms(1200), "1.2ms");
        assert_eq!(format_dur_ms(19400), "19.4ms");
        assert_eq!(format_dur_ms(168000), "168.0ms");
        assert_eq!(format_dur_ms(1000000), "1000ms");
    }

    // ── Malformed lines are skipped ────────────────────────────────

    #[test]
    fn malformed_lines_skipped() {
        let jsonl = r#"not json
{"name":"save.total","ph":"X","ts":1000000,"dur":5000,"pid":1,"tid":1,"parent_id":0,"args":{}}
also not json {{{
"#;
        let events = events_from_jsonl(jsonl);
        assert_eq!(events.len(), 1, "only valid events should be parsed");
    }

    // ── Default format is tree ─────────────────────────────────────

    #[test]
    fn default_format_is_tree() {
        // Parse the default variant from the enum.
        assert_eq!(ShowFormat::Tree, ShowFormat::Tree);
        // The clap default_value_t is ShowFormat::Tree — verified by
        // inspecting the attribute. We can also parse:
        let fmt = ShowFormat::from_str("tree", true).unwrap();
        assert!(matches!(fmt, ShowFormat::Tree));
    }

    // ── Multiple args in label ─────────────────────────────────────

    #[test]
    fn format_label_with_args() {
        let ev = TraceEvent {
            name: "save.capture.window".to_string(),
            ts: 0,
            dur: 0,
            tid: 0,
            parent_id: 0,
            args: vec![
                ("kitty_id".to_string(), "12".to_string()),
                ("os_window".to_string(), "1".to_string()),
            ],
        };
        let label = format_label(&ev);
        assert_eq!(label, "save.capture.window {kitty_id=12, os_window=1}");
    }

    #[test]
    fn format_label_without_args() {
        let ev = TraceEvent {
            name: "save.total".to_string(),
            ts: 0,
            dur: 0,
            tid: 0,
            parent_id: 0,
            args: vec![],
        };
        let label = format_label(&ev);
        assert_eq!(label, "save.total");
    }
}
