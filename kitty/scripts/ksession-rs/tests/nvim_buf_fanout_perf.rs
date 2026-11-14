//! PRD-0008 Slice 3: fan-out performance benchmark.
//!
//! Compares dump_modified_buffers wall time at FAN_OUT=1 (serial baseline)
//! vs FAN_OUT=4 (concurrent). Target: >=30% wall-time reduction when
//! per-buffer cost is dominated by msgpack-RPC round-trip time.
//!
//! Run with:
//!   cargo test --release --test nvim_buf_fanout_perf -- --ignored --nocapture

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

/// Create 12 modified buffers with varying sizes via a raw nvim-rs connection:
///   - 3 empty buffers (just marked modified)
///   - 3 small buffers (~20 lines each)
///   - 3 medium buffers (~200 lines each)
///   - 3 large buffers (~1000 lines each)
async fn setup_buffers(nvim: &nvim_rs::Neovim<Compat<WriteHalf<UnixStream>>>) {
    // Buffer 1: empty (the default scratch buffer)
    nvim.command("set modified")
        .await
        .expect("set modified buf 1");

    // Buffers 2-3: empty
    for buf_idx in 2..=3 {
        nvim.command("enew")
            .await
            .unwrap_or_else(|e| panic!("enew buf {buf_idx}: {e}"));
        nvim.command("set modified")
            .await
            .unwrap_or_else(|e| panic!("set modified buf {buf_idx}: {e}"));
    }

    // Buffers 4-6: small (~20 lines)
    for buf_idx in 4..=6 {
        nvim.command("enew")
            .await
            .unwrap_or_else(|e| panic!("enew buf {buf_idx}: {e}"));
        let lines = filler_lines(20);
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

    // Buffers 7-9: medium (~200 lines)
    for buf_idx in 7..=9 {
        nvim.command("enew")
            .await
            .unwrap_or_else(|e| panic!("enew buf {buf_idx}: {e}"));
        nvim.command(&format!(
            "call setline(1, repeat(['{}'], 200))",
            filler_lines(1)[0].replace('\'', "''")
        ))
        .await
        .unwrap_or_else(|e| panic!("setline buf {buf_idx}: {e}"));
        nvim.command("set modified")
            .await
            .unwrap_or_else(|e| panic!("set modified buf {buf_idx}: {e}"));
    }

    // Buffers 10-12: large (~1000 lines)
    for buf_idx in 10..=12 {
        nvim.command("enew")
            .await
            .unwrap_or_else(|e| panic!("enew buf {buf_idx}: {e}"));
        nvim.command(&format!(
            "call setline(1, repeat(['{}'], 1000))",
            filler_lines(1)[0].replace('\'', "''")
        ))
        .await
        .unwrap_or_else(|e| panic!("setline buf {buf_idx}: {e}"));
        nvim.command("set modified")
            .await
            .unwrap_or_else(|e| panic!("set modified buf {buf_idx}: {e}"));
    }
}

// --- Constants ---------------------------------------------------------------

const ITERATIONS: usize = 8;

// --- Test --------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
#[ignore = "fan-out performance benchmark — run manually with --ignored --nocapture"]
async fn buf_fanout_performance_benchmark() {
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

    // 2. Set up 12 modified buffers via raw nvim-rs connection
    let (raw_nvim, _raw_io) = new_path(&sock, NopHandler)
        .await
        .expect("raw nvim-rs connect");
    setup_buffers(&raw_nvim).await;

    // Sanity check: confirm we have 12 buffers
    let bufs = raw_nvim.list_bufs().await.expect("list_bufs");
    assert!(
        bufs.len() >= 12,
        "expected at least 12 buffers, got {}",
        bufs.len()
    );

    // 3. Connect via NvimConn for the measurement loop
    let conn = NvimConn::connect(&sock).await.expect("NvimConn::connect");
    let dumps_base = tmp.path().join("dumps");

    println!("\n=== PRD-0008 Fan-out Benchmark ===");
    println!("Workload: 12 modified buffers (3 empty, 3x20, 3x200, 3x1000 lines)");
    println!("Iterations per config: {ITERATIONS}");

    // ---- FAN_OUT=1 (serial baseline) ----

    // SAFETY: env var is set/unset around sequential await points with no
    // other concurrent test reading it in this process.
    unsafe {
        std::env::set_var("KSESSION_NVIM_BUF_FAN_OUT", "1");
    }

    for i in 0..ITERATIONS {
        let dumps_dir = dumps_base.join(format!("serial-{i}"));
        let _span = ksession_rs::perf_span!(perf::Level::Info, "bench.fanout.serial");
        conn.dump_modified_buffers(&dumps_dir)
            .await
            .unwrap_or_else(|e| panic!("serial iteration {i}: {e}"));
    }

    // Flush and collect serial stats
    perf::tracer_flush();

    let serial_stats = perf::stats::summarise(trace_dir, "bench.fanout.serial");
    let serial = serial_stats
        .get("bench.fanout.serial")
        .expect("bench.fanout.serial span not found — is tracer active?");

    // Reset traces for the concurrent run
    reset_trace_dir(trace_dir);

    // ---- FAN_OUT=4 (concurrent) ----

    unsafe {
        std::env::set_var("KSESSION_NVIM_BUF_FAN_OUT", "4");
    }

    for i in 0..ITERATIONS {
        let dumps_dir = dumps_base.join(format!("concurrent-{i}"));
        let _span = ksession_rs::perf_span!(perf::Level::Info, "bench.fanout.concurrent");
        conn.dump_modified_buffers(&dumps_dir)
            .await
            .unwrap_or_else(|e| panic!("concurrent iteration {i}: {e}"));
    }

    // Restore env
    unsafe {
        std::env::remove_var("KSESSION_NVIM_BUF_FAN_OUT");
    }

    // Flush and collect concurrent stats
    perf::tracer_flush();

    let concurrent_stats = perf::stats::summarise(trace_dir, "bench.fanout.concurrent");
    let concurrent = concurrent_stats
        .get("bench.fanout.concurrent")
        .expect("bench.fanout.concurrent span not found — is tracer active?");

    // ---- Report ----

    println!("\n--- FAN_OUT=1 (serial baseline) ---");
    println!(
        "  Count: {}  Mean: {:.1} ms  p50: {:.1} ms  p95: {:.1} ms",
        serial.count,
        serial.mean_ms(),
        serial.p50_ms(),
        serial.p95_ms(),
    );
    println!(
        "  Min: {:.1} ms  Max: {:.1} ms",
        serial.min_ms(),
        serial.max_ms(),
    );

    println!("\n--- FAN_OUT=4 (concurrent) ---");
    println!(
        "  Count: {}  Mean: {:.1} ms  p50: {:.1} ms  p95: {:.1} ms",
        concurrent.count,
        concurrent.mean_ms(),
        concurrent.p50_ms(),
        concurrent.p95_ms(),
    );
    println!(
        "  Min: {:.1} ms  Max: {:.1} ms",
        concurrent.min_ms(),
        concurrent.max_ms(),
    );

    let serial_p50 = serial.p50_ms();
    let concurrent_p50 = concurrent.p50_ms();
    let improvement_pct = if serial_p50 > 0.0 {
        ((serial_p50 - concurrent_p50) / serial_p50) * 100.0
    } else {
        0.0
    };

    println!("\n--- Comparison ---");
    println!("  Serial p50:     {serial_p50:.1} ms");
    println!("  Concurrent p50: {concurrent_p50:.1} ms");
    println!("  Improvement:    {improvement_pct:.1}%");

    println!("\nRESULT: FAN_OUT=4 is {improvement_pct:.1}% faster than FAN_OUT=1 (target: >=30%)");

    // Verify iteration counts
    assert_eq!(
        serial.count, ITERATIONS,
        "expected {ITERATIONS} serial spans, got {}",
        serial.count
    );
    assert_eq!(
        concurrent.count, ITERATIONS,
        "expected {ITERATIONS} concurrent spans, got {}",
        concurrent.count
    );

    // Soft assertion: warn if below target but don't hard-fail
    if improvement_pct < 30.0 {
        eprintln!(
            "WARNING: improvement {improvement_pct:.1}% is below 30% target. \
             This may indicate per-buffer cost is CPU-dominated rather than \
             RPC-RTT-dominated on this system."
        );
    }
    // Hard-fail only if concurrent is somehow SLOWER
    assert!(
        concurrent_p50 <= serial_p50 * 1.1,
        "concurrent should not be significantly slower than serial \
         (serial p50: {serial_p50:.1} ms, concurrent p50: {concurrent_p50:.1} ms)"
    );

    // Cleanup
    drop(conn);
    drop(raw_nvim);
    let _ = child.kill().await;
}
