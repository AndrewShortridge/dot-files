//! Process-wide tracer holding the output JSONL file handle.
//!
//! Activated by [`install`] (called from [`crate::perf::maybe_init`]);
//! retrieved everywhere else via [`Tracer::current`], which is a single
//! `OnceLock::get()` atomic load — the cost paid on every disabled
//! `span!` call site.

use std::fs::{File, OpenOptions};
use std::io::{self, BufWriter, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

/// Span priority. `Info` is the default; `Debug` and `Trace` are
/// progressively more verbose. The comparison operator on `Level` is
/// "more important is <=" — at `info`, `Info` spans pass and `Debug` /
/// `Trace` spans are skipped.
#[derive(Copy, Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Info = 0,
    Debug = 1,
    Trace = 2,
}

impl Level {
    /// Parse `KSESSION_TRACE_LEVEL` body. Unknown / empty → `Info`
    /// (default). Case-insensitive.
    pub fn parse(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "trace" => Level::Trace,
            "debug" => Level::Debug,
            _ => Level::Info,
        }
    }
}

/// Singleton tracer. Stored in a process-wide `OnceLock` and looked up
/// by every `span!` call site.
pub struct Tracer {
    /// Mutex-wrapped buffered writer. Lines are short (one chrome-trace
    /// event each), so the BufWriter's default 8 KB capacity easily
    /// absorbs bursts without a syscall per span. The Mutex serialises
    /// writes across tokio worker threads.
    out: Mutex<BufWriter<File>>,
    level: Level,
    /// Monotonically increasing span id counter. Each `Span::new` or
    /// `Span::with_parent` call allocates a unique id via `fetch_add`.
    /// Zero is reserved for "no parent".
    next_id: AtomicU64,
}

impl Tracer {
    /// Get the installed tracer, if any. **This is the cost paid by every
    /// disabled `span!` call site:** one atomic load on `OnceLock::get`.
    #[inline]
    pub fn current() -> Option<&'static Tracer> {
        TRACER.get()
    }

    /// Active span level. Spans with a higher `Level` value than this
    /// are filtered out at construction.
    #[inline]
    pub fn level(&self) -> Level {
        self.level
    }

    /// Allocate the next unique span id. IDs start at 1; 0 is reserved
    /// for "no parent".
    #[inline]
    pub fn next_span_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Append one already-formatted JSONL line (including the trailing
    /// `\n`). Errors are swallowed — see the `Drop` impl on `Span` for
    /// the rationale (we don't want a disk-full edge case to abort a
    /// save).
    pub fn write_line(&self, line: &[u8]) {
        if let Ok(mut guard) = self.out.lock() {
            let _ = guard.write_all(line);
            // Flush per line so the JSONL file is readable from outside
            // the writing process — this matches PRD-0's "appending is
            // atomic at the kernel level for lines under PIPE_BUF"
            // claim, which requires the bytes to actually reach the
            // kernel. The Tracer lives in a `OnceLock` so its Drop
            // never runs; without per-line flush the buffer would be
            // discarded on process exit. The BufWriter still amortises
            // any incidental small writes within a single line.
            let _ = guard.flush();
        }
    }
}

static TRACER: OnceLock<Tracer> = OnceLock::new();

/// Flush the tracer's BufWriter. Call before reading JSONL files
/// to ensure all buffered spans are written to disk.
///
/// This does NOT uninstall the tracer (OnceLock is permanent).
/// Subsequent spans will still be written normally.
pub fn flush() {
    if let Some(tracer) = TRACER.get() {
        if let Ok(mut guard) = tracer.out.lock() {
            let _ = guard.flush();
        }
    }
}

/// Install the singleton tracer.
///
/// Creates `<dir>/rust-<pid>.jsonl` (creating `<dir>` if needed), opens
/// it for append+create, and wraps it in a `BufWriter<File>` behind a
/// Mutex. Returns Err if either step fails; the caller (`maybe_init`)
/// surfaces those failures as a stderr warning.
///
/// Calling `install` twice in the same process is a no-op on the second
/// call — the underlying `OnceLock::set` returns `Err` for races and
/// we discard that path (the first installer wins).
pub fn install(dir: &Path, level: Level) -> io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let pid = std::process::id();
    let path = dir.join(format!("rust-{pid}.jsonl"));
    let file = OpenOptions::new().create(true).append(true).open(&path)?;
    let tracer = Tracer {
        out: Mutex::new(BufWriter::new(file)),
        level,
        next_id: AtomicU64::new(1), // 0 is reserved for "no parent"
    };
    // First installer wins. Second concurrent install loses silently —
    // both call sites must be supplying the same env-derived config so
    // a duplicate install is harmless.
    let _ = TRACER.set(tracer);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_parse_known_values() {
        assert_eq!(Level::parse("info"), Level::Info);
        assert_eq!(Level::parse("INFO"), Level::Info);
        assert_eq!(Level::parse("debug"), Level::Debug);
        assert_eq!(Level::parse("trace"), Level::Trace);
        assert_eq!(Level::parse(""), Level::Info, "empty → default");
        assert_eq!(Level::parse("garbage"), Level::Info, "unknown → default");
    }

    #[test]
    fn level_ordering_filters_more_verbose() {
        // The macro emits when `span_level <= tracer_level`.
        // At Info, only Info spans pass.
        assert!(Level::Info <= Level::Info);
        assert!(!(Level::Debug <= Level::Info));
        assert!(!(Level::Trace <= Level::Info));
        // At Debug, Info+Debug pass.
        assert!(Level::Info <= Level::Debug);
        assert!(Level::Debug <= Level::Debug);
        assert!(!(Level::Trace <= Level::Debug));
        // At Trace, everything passes.
        assert!(Level::Info <= Level::Trace);
        assert!(Level::Debug <= Level::Trace);
        assert!(Level::Trace <= Level::Trace);
    }
}
