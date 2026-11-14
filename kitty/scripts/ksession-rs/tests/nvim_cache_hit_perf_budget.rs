//! Performance budget test for the nvim cache-hit fast path.
//!
//! The cache-hit path (PRD-0010 Slice 3) skips the live `:mksession!` RPC
//! (~200ms) by returning a pre-captured session file when the cache is
//! fresh.  This test validates that the cache-hit critical path (file
//! metadata check + file read) meets the PRD's p50 <= 30ms budget.
//!
//! Run with:
//!   cargo test --test nvim_cache_hit_perf_budget -- --ignored --nocapture

use std::path::Path;
use std::sync::{LazyLock, Mutex};
use std::time::UNIX_EPOCH;

use ksession_rs::perf;

// --- Shared tracer (once per process) ----------------------------------------

static TRACE_DIR: LazyLock<tempfile::TempDir> = LazyLock::new(|| {
    let dir = tempfile::tempdir().expect("tempdir for traces");
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

// --- Cache-hit critical path (mirrors src/adapter/nvim.rs) -------------------

/// Inline replica of `adapter::nvim::is_cache_fresh` — the function is
/// `pub(crate)` so integration tests cannot call it directly.  The logic
/// is trivially small (one metadata syscall + mtime comparison) and
/// unlikely to drift.
fn is_cache_fresh(cache_path: &Path, dirty_ts_ms: Option<u64>) -> bool {
    let Some(dirty_ts) = dirty_ts_ms else {
        return false;
    };
    match std::fs::metadata(cache_path) {
        Ok(meta) => {
            let mtime_ms = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            mtime_ms >= dirty_ts
        }
        Err(_) => false,
    }
}

// --- Benchmark ---------------------------------------------------------------

const ITERATIONS: usize = 30;

/// Realistic `:mksession!` content: a minimal but non-trivial Vim script
/// that exercises the file-read path with a plausible payload size (~1 KB).
const MKSESSION_CONTENT: &str = "\
let SessionLoad = 1
let s:so_save = &so | let s:siso_save = &siso | setg so-=i | setg siso-=i
let s:cpo_save=&cpo
set cpo&vim
let s:sx = expand(\"<sfile>:p:r\").\"x.vim\"
if filereadable(s:sx)
  exe \"source \" . fnameescape(s:sx)
endif
let &cpo=s:cpo_save
unlet s:cpo_save
set nocompatible
cd /home/user/project
if bufexists(1)
  silent! buffer 1
endif
set shortmess=filnxtToOS
badd +1 src/main.rs
badd +42 src/lib.rs
badd +7 Cargo.toml
argglobal
%argdel
$argadd src/main.rs
edit src/main.rs
setlocal autoindent
setlocal noexpandtab
setlocal tabstop=4
setlocal shiftwidth=4
normal! zR
let s:l = line(\".\")
let s:c = col(\".\")
call cursor(s:l, s:c)
tabnext 1
let &so = s:so_save | let &siso = s:siso_save
doautoall SessionLoadPost
unlet SessionLoad
";

#[tokio::test]
#[ignore = "performance benchmark - run manually with --ignored"]
async fn nvim_cache_hit_perf_budget() {
    let _guard = BENCH_LOCK.lock().unwrap();
    let trace_dir = TRACE_DIR.path();
    reset_trace_dir(trace_dir);

    // 1. Set up fixture: temp state dir with .cache/nvim-win-42.vim
    let state_dir = tempfile::tempdir().expect("state tempdir");
    let cache_dir = state_dir.path().join(".cache");
    std::fs::create_dir_all(&cache_dir).expect("create .cache dir");
    let cache_file = cache_dir.join("nvim-win-42.vim");
    std::fs::write(&cache_file, MKSESSION_CONTENT).expect("write cache file");

    // 2. Read back the file's mtime and set dirty_ts to an older value
    //    (ensuring cache hit).
    let mtime_ms = std::fs::metadata(&cache_file)
        .expect("cache file metadata")
        .modified()
        .expect("modified time")
        .duration_since(UNIX_EPOCH)
        .expect("duration since epoch")
        .as_millis() as u64;

    // dirty_ts is 1 second older than the cache file's mtime.
    let dirty_ts_ms = Some(mtime_ms.saturating_sub(1000));

    // Verify the fixture produces a cache hit.
    assert!(
        is_cache_fresh(&cache_file, dirty_ts_ms),
        "fixture sanity check: cache file should be fresh"
    );

    // 3. Run 30 iterations of the cache-hit critical path, collecting
    //    durations via the perf tracer.
    println!("\n=== Benchmark: nvim cache-hit fast path ===");
    println!("Running {ITERATIONS} iterations...");

    for _i in 0..ITERATIONS {
        let _span = ksession_rs::perf_span!(perf::Level::Debug, "bench.nvim.cache_hit");

        // Critical path: metadata check + file read (exactly what
        // adapter::nvim::capture() does on a cache hit).
        let fresh = is_cache_fresh(&cache_file, dirty_ts_ms);
        assert!(fresh, "expected cache hit");

        let content = std::fs::read_to_string(&cache_file).expect("read cache file");
        assert!(!content.is_empty(), "cache file should not be empty");
    }

    // 4. Compute percentiles via perf::stats::summarise().
    let stats = perf::stats::summarise(trace_dir, "bench.nvim.cache_hit");
    let s = stats
        .get("bench.nvim.cache_hit")
        .expect("bench.nvim.cache_hit span not found in trace output; is the tracer active?");

    println!("Results (cache-hit fast path):");
    println!(
        "  Count: {}  Mean: {:.3} ms  p50: {:.3} ms  p95: {:.3} ms  p99: {:.3} ms",
        s.count,
        s.mean_ms(),
        s.p50_ms(),
        s.p95_ms(),
        s.p99_ms()
    );
    println!("  Min: {:.3} ms  Max: {:.3} ms", s.min_ms(), s.max_ms());

    assert_eq!(
        s.count, ITERATIONS,
        "expected {ITERATIONS} spans, got {}",
        s.count
    );

    // 5. Assert: p50 <= 30ms (PRD success criterion).
    assert!(
        s.p50_ms() <= 30.0,
        "cache-hit p50 {:.3}ms exceeds PRD budget of 30ms",
        s.p50_ms()
    );
}
