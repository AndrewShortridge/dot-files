//! Performance benchmarks for save orchestration.
//!
//! Timing comes from the `save.total` chrome-trace span; percentile
//! computation is delegated to `perf::stats::summarise`.
//!
//! Run with:
//!   cargo test --release --test perf_save_budget -- --ignored --nocapture

use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};

use ksession_rs::perf;
use ksession_rs::session::{save, SaveOpts};

use serde_json::{json, Value};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tokio::sync::oneshot;

// --- Shared tracer (once per process) --------------------------------------

static TRACE_DIR: LazyLock<tempfile::TempDir> = LazyLock::new(|| {
    let dir = tempdir().expect("tempdir for traces");
    perf::tracer::install(dir.path(), perf::Level::Info).expect("tracer install");
    dir
});

/// Serialise tests so spans from different benchmarks don't interleave.
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

// --- DCS framing helpers ---------------------------------------------------

const DCS_PREFIX: &[u8] = b"\x1bP@kitty-cmd";
const DCS_TERMINATOR: &[u8] = b"\x1b\\";

fn encode_frame(json_bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(DCS_PREFIX.len() + json_bytes.len() + DCS_TERMINATOR.len());
    out.extend_from_slice(DCS_PREFIX);
    out.extend_from_slice(json_bytes);
    out.extend_from_slice(DCS_TERMINATOR);
    out
}

fn find_terminator(buf: &[u8]) -> Option<usize> {
    buf.windows(DCS_TERMINATOR.len())
        .position(|w| w == DCS_TERMINATOR)
}

async fn spawn_mock_server<F>(handler: F) -> (PathBuf, tempfile::TempDir)
where
    F: Fn(Value) -> Option<Value> + Send + Sync + 'static,
{
    let dir = tempdir().expect("tempdir");
    let sock = dir.path().join("rpc.sock");
    let listener = UnixListener::bind(&sock).expect("bind");
    let h = Arc::new(handler);
    tokio::spawn(async move {
        loop {
            let (mut stream, _) = match listener.accept().await {
                Ok(p) => p,
                Err(_) => return,
            };
            let h2 = h.clone();
            let (done_tx, _done_rx) = oneshot::channel::<()>();
            tokio::spawn(async move {
                let mut acc: Vec<u8> = Vec::new();
                let mut chunk = [0u8; 4096];
                loop {
                    let n = match stream.read(&mut chunk).await {
                        Ok(0) => break,
                        Ok(n) => n,
                        Err(_) => break,
                    };
                    acc.extend_from_slice(&chunk[..n]);
                    while let Some(end) = find_terminator(&acc) {
                        let frame = acc[..end + DCS_TERMINATOR.len()].to_vec();
                        acc.drain(..end + DCS_TERMINATOR.len());
                        let json_bytes =
                            &frame[DCS_PREFIX.len()..frame.len() - DCS_TERMINATOR.len()];
                        let req: Value = match serde_json::from_slice(json_bytes) {
                            Ok(v) => v,
                            Err(_) => continue,
                        };
                        if let Some(resp_json) = h2(req) {
                            let resp_bytes = serde_json::to_vec(&resp_json).expect("ser");
                            let _ = stream.write_all(&encode_frame(&resp_bytes)).await;
                            let _ = stream.flush().await;
                        }
                    }
                }
                let _ = done_tx.send(());
            });
        }
    });
    (sock, dir)
}

// --- Test scenarios -------------------------------------------------------

fn make_typical_ls() -> Value {
    json!([{
        "id": 1, "is_focused": true, "last_focused": true,
        "tabs": [
            { "id": 1, "title": "main", "layout": "splits",
              "windows": (0..6).map(|i| json!({
                  "id": i+1, "pid": 1000+i, "cwd": "/home/user",
                  "foreground_processes": [{"pid": 1000+i, "cmdline": ["/bin/bash"]}],
              })).collect::<Vec<_>>() },
            { "id": 2, "title": "dev", "layout": "stack",
              "windows": (0..6).map(|i| json!({
                  "id": i+10, "pid": 2000+i, "cwd": "/home/user/project",
                  "foreground_processes": [{"pid": 2000+i, "cmdline": ["/bin/bash"]}],
              })).collect::<Vec<_>>() }
        ]
    }])
}

fn make_heavy_ls() -> Value {
    json!([
        { "id": 1, "is_focused": true, "last_focused": true,
          "tabs": (0..15).map(|i| json!({
              "id": i+1, "title": format!("tab-{i}"), "layout": "splits",
              "windows": [json!({
                  "id": i+1, "pid": 1000+i, "cwd": "/home/user",
                  "foreground_processes": [{"pid": 1000+i, "cmdline": ["/bin/bash"]}],
              })]
          })).collect::<Vec<_>>() },
        { "id": 2, "is_focused": false, "last_focused": false,
          "tabs": (0..15).map(|i| json!({
              "id": i+20, "title": format!("tab-{}", i+15), "layout": "splits",
              "windows": [json!({
                  "id": i+20, "pid": 2000+i, "cwd": "/home/user/project",
                  "foreground_processes": [{"pid": 2000+i, "cmdline": ["/bin/bash"]}],
              })]
          })).collect::<Vec<_>>() }
    ])
}

// --- Benchmark runner ------------------------------------------------------

async fn run_benchmark(ls_json: Value, iterations: usize) {
    let skeleton = "os_window_class kitty\nos_window_name test\nnew_tab\nlayout splits\n\
                    enabled_layouts splits,stack\ncd /home/user\nlaunch /bin/bash -l\nfocus\n"
        .to_string();
    let tmp = tempdir().expect("tempdir");
    let sessions_dir = tmp.path().to_path_buf();

    for i in 0..iterations {
        let ls = ls_json.clone();
        let skel = skeleton.clone();
        let (sock, _dir) = spawn_mock_server(move |req| {
            let cmd = req.get("cmd").and_then(|v| v.as_str()).unwrap_or("");
            match cmd {
                "ls" if req
                    .get("payload")
                    .and_then(|p| p.get("all_env_vars"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false) =>
                {
                    Some(json!({"ok":true,"data":serde_json::to_string(&ls).unwrap()}))
                }
                "ls" => Some(json!({"ok":true,"data":&skel})),
                "get_text" => Some(json!({"ok":true,"data":""})),
                "set_user_vars" => Some(json!({"ok":true})),
                _ => None,
            }
        })
        .await;
        std::env::set_var("KITTY_LISTEN_ON", sock.to_str().unwrap());
        if let Err(e) = save(SaveOpts {
            name: format!("bench_{i}"),
            all: true,
            scrollback: false,
            sessions_dir: sessions_dir.clone(),
            from_ls: None,
            from_skeleton: None,
            pre_pool: None,
        })
        .await
        {
            eprintln!("Iteration {i} failed: {e:?}");
        }
        std::env::remove_var("KITTY_LISTEN_ON");
    }
}

/// Run a benchmark, summarise the trace, print stats, and return the
/// `SpanStats` for `save.total`.
async fn bench(label: &str, ls_json: Value, iterations: usize) -> perf::stats::SpanStats {
    let _guard = BENCH_LOCK.lock().unwrap();
    let trace_dir = TRACE_DIR.path();
    reset_trace_dir(trace_dir);

    println!("\n=== Benchmark: {label} ===");
    println!("Running {iterations} iterations...");

    run_benchmark(ls_json, iterations).await;

    let stats = perf::stats::summarise(trace_dir, "save.total");
    let s = stats
        .get("save.total")
        .expect("save.total span not found in trace output; is the tracer active?")
        .clone();

    println!("Results (from save.total span):");
    println!(
        "  Count: {}  Mean: {:.1} ms  p50: {:.1} ms  p95: {:.1} ms  p99: {:.1} ms",
        s.count,
        s.mean_ms(),
        s.p50_ms(),
        s.p95_ms(),
        s.p99_ms()
    );
    println!("  Min: {:.1} ms  Max: {:.1} ms", s.min_ms(), s.max_ms());

    assert_eq!(
        s.count, iterations,
        "expected {iterations} save.total spans, got {}",
        s.count
    );
    s
}

// --- Benchmarks -----------------------------------------------------------

#[tokio::test]
#[ignore = "performance benchmark - run manually with --ignored"]
async fn benchmark_typical_12_windows() {
    let s = bench(
        "Typical (12 windows, 2 nvim, 1 tmux)",
        make_typical_ls(),
        100,
    )
    .await;
    assert!(
        s.p50_ms() <= 200.0,
        "save.total p50 {:.1}ms exceeds budget 200ms",
        s.p50_ms()
    );
}

#[tokio::test]
#[ignore = "performance benchmark - run manually with --ignored"]
async fn benchmark_heavy_30_windows() {
    let s = bench("Heavy (30 windows, 6 nvim, 2 tmux)", make_heavy_ls(), 100).await;
    assert!(
        s.p95_ms() <= 500.0,
        "save.total p95 {:.1}ms exceeds budget 500ms",
        s.p95_ms()
    );
}

#[tokio::test]
#[ignore = "performance benchmark - run manually with --ignored"]
async fn benchmark_single_iteration() {
    let s = bench("Quick single iteration", make_typical_ls(), 1).await;
    assert!(
        s.p50_ms() < 5000.0,
        "save.total single iteration took too long: {:.1} ms",
        s.p50_ms()
    );
}
