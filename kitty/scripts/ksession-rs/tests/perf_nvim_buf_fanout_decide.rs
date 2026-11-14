//! PRD-0008 Slice 1: decision-gating measurement for parallel nvim buffer dumps.
//!
//! This test measures how much of `dump_modified_buffers` wall time is spent
//! in sequential `buf_get_lines` + `buf_get_var` RPC calls. If the percentage
//! is high enough, parallelising those calls (PRD-0008) is worthwhile.
//!
//! The test is `#[ignore]` because it requires a real nvim on PATH and takes
//! non-trivial wall time (10 iterations against a headless nvim with 8
//! modified buffers of varying sizes).
//!
//! Run with:
//!   cargo test --release --test perf_nvim_buf_fanout_decide -- --ignored --nocapture

use std::path::Path;
use std::process::Stdio;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use ksession_rs::nvim_rpc::NvimConn;
use ksession_rs::perf;
use nvim_rs::{compat::tokio::Compat, create::tokio::new_path, Handler};
use tempfile::tempdir;
use tokio::io::WriteHalf;
use tokio::net::UnixStream;

// --- Shared tracer (once per process) ----------------------------------------

static TRACE_DIR: LazyLock<tempfile::TempDir> = LazyLock::new(|| {
    let dir = tempdir().expect("tempdir for traces");
    perf::tracer::install(dir.path(), perf::Level::Debug).expect("tracer install");
    dir
});

/// Serialise benchmarks so spans don't interleave.
static BENCH_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

fn reset_trace_dir(dir: &Path) {
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("jsonl") {
            if let Ok(f) = std::fs::OpenOptions::new().write(true).open(&p) {
                let _ = f.set_len(0);
            }
        }
    }
}

// --- nvim helpers ------------------------------------------------------------

/// nvim-rs requires a notification handler even when we never receive any.
/// Mirrors `NopHandler` in `src/nvim_rpc/conn.rs`.
#[derive(Clone)]
struct NopHandler;

#[async_trait]
impl Handler for NopHandler {
    type Writer = Compat<WriteHalf<UnixStream>>;
}

fn nvim_or_skip() -> bool {
    std::process::Command::new("nvim")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

async fn spawn_nvim(sock: &Path) -> tokio::process::Child {
    let child = tokio::process::Command::new("nvim")
        .args(["--headless", "--clean", "-u", "NORC", "--listen"])
        .arg(sock)
        .args(["-c", "set noswapfile"])
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn nvim");
    for _ in 0..80 {
        if sock.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(sock.exists(), "nvim socket never appeared at {sock:?}");
    child
}

// --- Buffer setup ------------------------------------------------------------

/// Generate `n` lines of filler content.
fn filler_lines(n: usize) -> Vec<String> {
    (0..n)
        .map(|i| format!("content line {i} -- padding to make it realistic"))
        .collect()
}

/// Create 8 modified buffers with varying sizes via a raw nvim-rs connection:
///   - 2 empty buffers (just marked modified)
///   - 2 small buffers (~10 lines each)
///   - 2 medium buffers (~100 lines each)
///   - 2 large buffers (~500 lines each)
async fn setup_buffers(nvim: &nvim_rs::Neovim<Compat<WriteHalf<UnixStream>>>) {
    // Buffer 1: empty (the default scratch buffer)
    nvim.command("set modified")
        .await
        .expect("set modified buf 1");

    // Buffer 2: empty
    nvim.command("enew").await.expect("enew buf 2");
    nvim.command("set modified")
        .await
        .expect("set modified buf 2");

    // Buffers 3-4: small (~10 lines)
    for buf_idx in 3..=4 {
        nvim.command("enew")
            .await
            .unwrap_or_else(|e| panic!("enew buf {buf_idx}: {e}"));
        let lines = filler_lines(10);
        let joined = lines
            .iter()
            .map(|l| format!("'{}'", l.replace('\'', "''")))
            .collect::<Vec<_>>()
            .join(", ");
        nvim.command(&format!("call setline(1, [{joined}])"))
            .await
            .unwrap_or_else(|e| panic!("setline buf {buf_idx}: {e}"));
        nvim.command("set modified")
            .await
            .unwrap_or_else(|e| panic!("set modified buf {buf_idx}: {e}"));
    }

    // Buffers 5-6: medium (~100 lines)
    for buf_idx in 5..=6 {
        nvim.command("enew")
            .await
            .unwrap_or_else(|e| panic!("enew buf {buf_idx}: {e}"));
        let lines = filler_lines(100);
        // Use repeat() for efficiency — 100 identical lines is fine for
        // measuring RPC overhead, which is what we care about here.
        nvim.command(&format!(
            "call setline(1, repeat(['{}'], 100))",
            lines[0].replace('\'', "''")
        ))
        .await
        .unwrap_or_else(|e| panic!("setline buf {buf_idx}: {e}"));
        nvim.command("set modified")
            .await
            .unwrap_or_else(|e| panic!("set modified buf {buf_idx}: {e}"));
    }

    // Buffers 7-8: large (~500 lines)
    for buf_idx in 7..=8 {
        nvim.command("enew")
            .await
            .unwrap_or_else(|e| panic!("enew buf {buf_idx}: {e}"));
        nvim.command(&format!(
            "call setline(1, repeat(['{}'], 500))",
            filler_lines(1)[0].replace('\'', "''")
        ))
        .await
        .unwrap_or_else(|e| panic!("setline buf {buf_idx}: {e}"));
        nvim.command("set modified")
            .await
            .unwrap_or_else(|e| panic!("set modified buf {buf_idx}: {e}"));
    }
}

// --- Decision constants ------------------------------------------------------

const ITERATIONS: usize = 10;
const THRESHOLD_DROP: f64 = 5.0;
const THRESHOLD_PROCEED: f64 = 15.0;

// --- Test --------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
#[ignore = "decision-gating measurement — run manually with --ignored --nocapture"]
async fn buf_fanout_decision_gate() {
    if !nvim_or_skip() {
        eprintln!("skip: nvim not on PATH");
        return;
    }

    let _guard = BENCH_LOCK.lock().unwrap();
    let trace_dir = TRACE_DIR.path();
    reset_trace_dir(trace_dir);

    // 1. Spawn headless nvim
    let tmp = tempdir().expect("tempdir");
    let sock = tmp.path().join("nv.sock");
    let mut child = spawn_nvim(&sock).await;

    // 2. Set up 8 modified buffers via raw nvim-rs connection
    let (raw_nvim, _raw_io) = new_path(&sock, NopHandler)
        .await
        .expect("raw nvim-rs connect");
    setup_buffers(&raw_nvim).await;

    // Sanity check: confirm we have 8 buffers
    let bufs = raw_nvim.list_bufs().await.expect("list_bufs");
    assert!(
        bufs.len() >= 8,
        "expected at least 8 buffers, got {}",
        bufs.len()
    );

    // 3. Connect via NvimConn for the measurement loop
    let conn = NvimConn::connect(&sock).await.expect("NvimConn::connect");
    let dumps_base = tmp.path().join("dumps");

    println!("\n=== PRD-0008 Decision Gate: parallel nvim buffer dump ===");
    println!("Workload: 8 modified buffers (2 empty, 2x10, 2x100, 2x500 lines)");
    println!("Iterations: {ITERATIONS}");
    println!();

    // 4. Run measurement loop
    for i in 0..ITERATIONS {
        let dumps_dir = dumps_base.join(format!("iter-{i}"));
        let _span = ksession_rs::perf_span!(perf::Level::Info, "bench.nvim.dump_modified_buffers");
        conn.dump_modified_buffers(&dumps_dir)
            .await
            .unwrap_or_else(|e| panic!("dump_modified_buffers iteration {i}: {e}"));
    }

    // 5. Flush tracer before reading JSONL files
    perf::tracer_flush();

    // 6. Summarise the spans
    let wrapper_stats = perf::stats::summarise(trace_dir, "bench.nvim.dump_modified_buffers");
    let wrapper = wrapper_stats
        .get("bench.nvim.dump_modified_buffers")
        .expect("bench.nvim.dump_modified_buffers span not found — is tracer active?");

    let buf_get_lines_stats = perf::stats::summarise(trace_dir, "nvim.rpc.buf_get_lines");
    let buf_get_lines = buf_get_lines_stats
        .get("nvim.rpc.buf_get_lines")
        .expect("nvim.rpc.buf_get_lines span not found — tracer level may be too high");

    let buf_get_var_stats = perf::stats::summarise(trace_dir, "nvim.rpc.buf_get_var");
    let buf_get_var = buf_get_var_stats
        .get("nvim.rpc.buf_get_var")
        .expect("nvim.rpc.buf_get_var span not found — tracer level may be too high");

    // 7. Compute the per-iteration cumulative RPC cost.
    //
    // Each iteration calls buf_get_lines and buf_get_var once per modified
    // buffer (8 buffers). The stats module gives us aggregate numbers across
    // all events. The estimated cumulative per-iteration cost is:
    //   mean_per_call * calls_per_iteration
    //
    // buf_get_var fires for every buffer (modified or not) since it checks
    // the `modified` option before filtering. With 8 buffers, that's 8
    // buf_get_var calls per iteration. buf_get_lines only fires for the 8
    // modified buffers.
    let calls_per_iter_lines = buf_get_lines.count as f64 / ITERATIONS as f64;
    let calls_per_iter_var = buf_get_var.count as f64 / ITERATIONS as f64;

    let cumulative_lines_us = buf_get_lines.mean_us * calls_per_iter_lines;
    let cumulative_var_us = buf_get_var.mean_us * calls_per_iter_var;
    let cumulative_rpc_us = cumulative_lines_us + cumulative_var_us;

    let pct = (cumulative_rpc_us / wrapper.p50_us) * 100.0;

    // 8. Print results
    println!("--- Wrapper span (dump_modified_buffers) ---");
    println!(
        "  Count: {}  Mean: {:.1} ms  p50: {:.1} ms  p95: {:.1} ms",
        wrapper.count,
        wrapper.mean_ms(),
        wrapper.p50_ms(),
        wrapper.p95_ms(),
    );
    println!(
        "  Min: {:.1} ms  Max: {:.1} ms",
        wrapper.min_ms(),
        wrapper.max_ms(),
    );

    println!("\n--- buf_get_lines ---");
    println!(
        "  Count: {} ({:.0}/iter)  Mean: {:.3} ms  p50: {:.3} ms",
        buf_get_lines.count,
        calls_per_iter_lines,
        buf_get_lines.mean_ms(),
        buf_get_lines.p50_ms(),
    );
    println!(
        "  Cumulative per iteration: {:.3} ms",
        cumulative_lines_us / 1000.0,
    );

    println!("\n--- buf_get_var ---");
    println!(
        "  Count: {} ({:.0}/iter)  Mean: {:.3} ms  p50: {:.3} ms",
        buf_get_var.count,
        calls_per_iter_var,
        buf_get_var.mean_ms(),
        buf_get_var.p50_ms(),
    );
    println!(
        "  Cumulative per iteration: {:.3} ms",
        cumulative_var_us / 1000.0,
    );

    println!("\n--- Cost analysis ---");
    println!(
        "  Total sequential RPC per iteration: {:.3} ms",
        cumulative_rpc_us / 1000.0,
    );
    println!("  Wrapper p50: {:.3} ms", wrapper.p50_us / 1000.0,);
    println!("  RPC as % of wall time: {pct:.1}%");

    // 9. Print decision
    println!();
    if pct < THRESHOLD_DROP {
        println!(
            "DECISION: drop PRD-0008 \u{2014} buf_get_lines is {pct:.1}% of capture wall time"
        );
    } else if pct > THRESHOLD_PROCEED {
        println!(
            "DECISION: proceed with PRD-0008 \u{2014} buf_get_lines is {pct:.1}% of capture wall time"
        );
    } else {
        println!(
            "DECISION: inconclusive \u{2014} buf_get_lines is {pct:.1}% of capture wall time, needs re-measurement"
        );
    }

    // Verify we got the expected number of iterations
    assert_eq!(
        wrapper.count, ITERATIONS,
        "expected {ITERATIONS} wrapper spans, got {}",
        wrapper.count
    );

    // Cleanup
    drop(conn);
    drop(raw_nvim);
    let _ = child.kill().await;
}
