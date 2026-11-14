//! Performance benchmark: history file copy throughput.
//!
//! Simulates the shell history copy step of the save path: 12 x 10 KiB
//! files copied from a source directory to a destination directory.
//! Measures cumulative copy time and asserts it stays within budget.
//!
//! Run with:
//!   cargo test --release --test perf_history_copy_budget -- --ignored --nocapture

use std::time::Instant;

const ITERATIONS: usize = 30;
const FILE_COUNT: usize = 12;
const FILE_SIZE: usize = 10 * 1024; // 10 KiB

#[test]
#[ignore = "performance benchmark - run manually with --ignored"]
fn perf_history_copy_budget() {
    let dir = tempfile::tempdir().expect("tempdir");
    let src_dir = dir.path().join("src");
    let dst_dir = dir.path().join("dst");
    std::fs::create_dir_all(&src_dir).expect("create src dir");
    std::fs::create_dir_all(&dst_dir).expect("create dst dir");

    // Create 12 x 10 KiB source files with representative content.
    let data = vec![b'x'; FILE_SIZE];
    for i in 0..FILE_COUNT {
        std::fs::write(src_dir.join(format!("{i}.hist")), &data).expect("write source file");
    }

    let mut times = Vec::new();
    for iter in 0..ITERATIONS {
        let t0 = Instant::now();
        for i in 0..FILE_COUNT {
            let _ = std::fs::copy(
                src_dir.join(format!("{i}.hist")),
                dst_dir.join(format!("{i}.hist")),
            );
        }
        let elapsed = t0.elapsed();

        if iter > 0 {
            // Skip the first iteration (warm-up / page-cache priming).
            times.push(elapsed);
        }
    }

    times.sort();
    let p50 = times[times.len() / 2];

    println!(
        "history copy (12 x 10 KiB): p50 = {:?}, min = {:?}, max = {:?}",
        p50,
        times.first().unwrap(),
        times.last().unwrap()
    );

    assert!(
        p50.as_millis() <= 10,
        "history copy p50 = {:?}, budget = 10ms",
        p50
    );
}
