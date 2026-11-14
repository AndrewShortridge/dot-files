//! `Span` — RAII guard that emits one chrome-trace `X` (complete) event
//! JSONL line on Drop.
//!
//! The shape intentionally mirrors `tracing::Span`'s usage pattern (a
//! guard whose lifetime brackets the scope), but the type is hand-rolled
//! per [ADR 0004](../../docs/adr/0004-custom-span-tracer.md) so there is
//! no dependency on the `tracing` ecosystem.

use std::time::Instant;

use super::tracer::Tracer;

/// A timed scope. Created by [`crate::perf::span!`]; emits on Drop.
///
/// Fields are private; callers should never inspect a `Span` directly —
/// the only observable behaviour is the JSONL line written when the
/// guard goes out of scope.
pub struct Span {
    name: &'static str,
    start: Instant,
    pid: u32,
    tid: u64,
    span_id: u64,
    parent_id: u64,
    /// `(key, value)` pairs serialised under `args` in the emitted line.
    /// The number of args is small in practice (≤ 4 at the documented
    /// call sites), so a plain `Vec` is fine — allocation only happens
    /// when tracing is active.
    args: Vec<(&'static str, String)>,
}

impl Span {
    /// Construct a new span. Called from the [`crate::perf::span!`] macro
    /// after the tracer / level checks have passed; callers should not
    /// invoke this directly.
    ///
    /// The args slice is copied (the values are already owned `String`s
    /// by the time the macro reaches us).
    pub fn new(name: &'static str, args: &[(&'static str, String)]) -> Self {
        let pid = std::process::id();
        let tid = current_tid();
        let span_id = Tracer::current().map(|t| t.next_span_id()).unwrap_or(0);
        let parent_id = 0;
        Self {
            name,
            start: Instant::now(),
            pid,
            tid,
            span_id,
            parent_id,
            args: args.to_vec(),
        }
    }

    /// Construct a span with an explicit parent id. Used for cross-task
    /// parent propagation at the `buffer_unordered` fan-out boundary
    /// where each spawned future runs on a different tokio task and
    /// cannot inherit parent context via task-local state.
    pub fn with_parent(
        name: &'static str,
        args: &[(&'static str, String)],
        parent_id: u64,
    ) -> Self {
        let pid = std::process::id();
        let tid = current_tid();
        let span_id = Tracer::current().map(|t| t.next_span_id()).unwrap_or(0);
        Self {
            name,
            start: Instant::now(),
            pid,
            tid,
            span_id,
            parent_id,
            args: args.to_vec(),
        }
    }

    /// Return this span's unique id. Used by the orchestration layer to
    /// capture a phase span's id before spawning per-window futures that
    /// reference it as their `parent_id`.
    #[inline]
    pub fn span_id(&self) -> u64 {
        self.span_id
    }

    /// Append a key-value arg pair after construction. Used for args
    /// whose values are only known after the work is done (e.g.
    /// `bytes_in` on an RPC span whose response size isn't known until
    /// the response arrives). The arg is appended to the end of the
    /// existing args list.
    pub fn push_arg(&mut self, key: &'static str, value: String) {
        self.args.push((key, value));
    }
}

impl Drop for Span {
    fn drop(&mut self) {
        // `Tracer::current()` is the same atomic-load that gated
        // construction. If it returns `None` here something has gone
        // very wrong (the tracer can't be uninstalled in this slice);
        // but be defensive and skip rather than panic during Drop.
        let Some(tracer) = Tracer::current() else {
            return;
        };
        let dur_us = self.start.elapsed().as_micros() as u64;
        // `ts` is microseconds since the Unix epoch at span START, so
        // perfetto can place this event on a wall-clock timeline.
        let ts_us = match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
            Ok(d) => d.as_micros() as u64,
            Err(_) => 0,
        }
        .saturating_sub(dur_us);

        // Build the JSON line via serde_json::to_string so commas, quotes
        // and escapes in args values are handled correctly. Each line
        // ends with `\n`. The combined write is one `write_all` call
        // inside the BufWriter, which serialises against other emitters
        // via the surrounding Mutex (see tracer.rs).
        let mut args_obj = serde_json::Map::with_capacity(self.args.len());
        for (k, v) in &self.args {
            args_obj.insert((*k).to_string(), serde_json::Value::String(v.clone()));
        }
        let line = serde_json::json!({
            "name": self.name,
            "ph": "X",
            "ts": ts_us,
            "dur": dur_us,
            "pid": self.pid,
            "tid": self.tid,
            "span_id": self.span_id,
            "parent_id": self.parent_id,
            "args": serde_json::Value::Object(args_obj),
        });
        // serde_json::to_string never fails for this shape (all values
        // are primitives or strings). Suppress error rather than panic
        // in Drop — a swallowed line is preferable to aborting on a
        // disk-full edge case mid-save.
        if let Ok(mut s) = serde_json::to_string(&line) {
            s.push('\n');
            tracer.write_line(s.as_bytes());
        }
    }
}

/// Best-effort thread id, exposed as a `u64` to match chrome-trace's
/// numeric `tid` field. We use the low bits of a `ThreadId`'s
/// `Debug` repr because `std::thread::ThreadId::as_u64` is unstable.
///
/// The exact value doesn't matter for correctness — perfetto only
/// requires that distinct concurrent threads emit distinct `tid`s so
/// their spans land on separate lanes.
fn current_tid() -> u64 {
    // ThreadId implements Debug as `ThreadId(N)`; parse N out of that.
    // On main thread N=1; spawned threads get monotonically-increasing
    // ids. This is stable enough for perfetto's lane grouping.
    let dbg = format!("{:?}", std::thread::current().id());
    // Find the digits inside the Debug repr.
    let start = dbg.find(|c: char| c.is_ascii_digit()).unwrap_or(0);
    let end = dbg[start..]
        .find(|c: char| !c.is_ascii_digit())
        .map(|i| start + i)
        .unwrap_or(dbg.len());
    dbg[start..end].parse::<u64>().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_tid_is_nonzero_on_main() {
        // `ThreadId(1)` on the main test thread → 1. Spawned test
        // threads see higher ids.
        let tid = current_tid();
        assert!(tid >= 1, "expected nonzero tid, got {tid}");
    }
}
