//! Perf observability layer — hand-rolled chrome-trace span emitter.
//!
//! See [PRD-0](../../docs/prds/0002-observability-infrastructure.md) and
//! [ADR 0004](../../docs/adr/0004-custom-span-tracer.md) for why this is
//! not built on top of the `tracing` crate.
//!
//! # Usage
//!
//! ```ignore
//! use ksession_rs::perf;
//!
//! perf::maybe_init(); // once at process startup
//!
//! {
//!     let _s = perf::span!(perf::Level::Info, "save.total");
//!     // ... work ...
//! } // Drop emits one chrome-trace `X` event JSONL line.
//! ```
//!
//! # Activation
//!
//! - `KSESSION_TRACE_DIR` — when set, a `Tracer` is initialised that
//!   appends to `<dir>/rust-<pid>.jsonl`. When unset, every `span!` call
//!   compiles to a single `OnceLock::get()` atomic load that returns
//!   `None`, after which the macro short-circuits with no allocation.
//! - `KSESSION_TRACE_LEVEL` — `info` (default) / `debug` / `trace`. Spans
//!   declared at a higher (more verbose) level than the configured one
//!   are skipped at construction.
//!
//! # Span call sites
//!
//! - L0: `save.total` — wraps the entire save orchestration.
//! - L1: `save.discover`, `save.tag_uuids`, `save.capture`,
//!   `save.sanitize`, `save.render`, `save.commit` — per-phase spans.
//! - L2: `save.capture.window` — per-window span inside the
//!   `buffer_unordered` fan-out, with explicit parent-id propagation
//!   via [`Span::with_parent`].
//! - L3: `adapter.detect`, `adapter.capture` — per-adapter per-window
//!   spans at the adapter registry dispatch. Args: `adapter` (name).
//!   Level: `debug`.
//! - L3.5: per-component spans within the save pipeline. Level: `info`
//!   unless noted.
//!   - `conf.render` — time spent rendering the final .conf from the patched skeleton.
//!   - `fs.write` — time spent writing conf + state artifacts to disk (manifest +
//!     commit_session). Args: `conf_bytes`, `manifest_bytes`.
//!   - `tmux.capture` — wraps per-session tmux capture work inside the
//!     TmuxAdapter. Args: `kitty_id`.
//! - L4: `kitty.rpc.ls`, `kitty.rpc.get_text`, `kitty.rpc.set_user_vars`,
//!   `kitty.ls_session`, `nvim.rpc.mksession`, `nvim.rpc.list_bufs`,
//!   `nvim.rpc.buf_get_lines`, `nvim.rpc.buf_get_var`, `tmux.cmd`,
//!   `fsx.commit_session` — per-RPC spans. Args: `bytes_out`, `bytes_in`
//!   (approximate), plus `buf` where applicable, `cmd` for tmux.
//!   Level: `debug`.
//! - L5: per-socket-IO spans inside each L4 span. Level: `trace`.
//!   - `kitty.rpc.write_req` — bracket the socket write (inside `exchange_on` / `call_no_response`)
//!   - `kitty.rpc.read_resp` — bracket the socket read (inside `exchange_on`)
//!   - `kitty.rpc.decode` — bracket the JSON decode of the response envelope
//!   - `nvim.rpc.write_msgpack` — bracket the nvim-rs RPC call (write+read+decode
//!     are bundled inside the nvim-rs library; this span covers the full round-trip)
//!   - `nvim.rpc.decode_msgpack` — bracket any post-RPC decode/validation step
//!   - `tmux.subprocess.spawn` — bracket `Command::new(...).spawn()` / `cmd.output()`
//!   - `tmux.subprocess.wait` — bracket `child.wait_with_output()`
//!   - `tmux.subprocess.decode_stdout` — bracket stdout parsing
//!
//! ## Restore path spans (Issue #10)
//!
//! - `restore.dispatch` — wraps the entire restore orchestration.
//! - `restore.sweep_orphans` — time in orphan state-dir sweep.
//! - `kitty.launch` — time from kitty process spawn to return (detach mode)
//!   or to the kitty socket becoming reachable (traced mode).
//! - `nvim.spawn` — time to launch nvim in a kitty window (emitted by
//!   the external contributor or simulated in baseline benchmarks).
//! - `nvim.source_session` — time for nvim to source its mksession script.
//! - `tmux.spawn` — time to launch tmux new-session.
//! - `tmux.restore` — time to execute restore.sh and recreate session.
//! - `ready.wait` — time spent polling for all ready markers to appear.

pub mod ready;
pub mod span;
pub mod stats;
pub mod tracer;

pub use span::Span;
pub use tracer::{Level, Tracer};

/// Flush the tracer before reading trace files for stats collection.
pub fn tracer_flush() {
    tracer::flush();
}

/// Initialise the process-wide tracer iff `KSESSION_TRACE_DIR` is set.
///
/// Idempotent: subsequent calls are no-ops because the underlying
/// `OnceLock` is single-shot. Safe to call from `main()` before parsing
/// CLI flags.
///
/// When the tracer activates, an auto-sweep runs against the traces
/// root directory (PRD-0 slice 4) so the cache never grows unbounded.
/// The sweep keeps the newest `DEFAULT_KEEP` dirs and removes the rest.
/// Sweep failures are non-fatal — a one-line warning is emitted to
/// stderr and the tracer proceeds normally.
///
/// Failures (env var set but the dir is not writable, etc.) emit a
/// one-line warning to stderr and leave the tracer uninitialised so the
/// rest of the binary proceeds as if tracing were off.
pub fn maybe_init() {
    let Some(dir) = std::env::var_os("KSESSION_TRACE_DIR") else {
        return;
    };
    let dir = std::path::PathBuf::from(dir);
    let level = std::env::var("KSESSION_TRACE_LEVEL")
        .ok()
        .as_deref()
        .map(Level::parse)
        .unwrap_or(Level::Info);
    if let Err(e) = tracer::install(&dir, level) {
        eprintln!(
            "ksession: perf: could not initialise tracer at {}: {e}; \
             tracing disabled for this run",
            dir.display()
        );
        return;
    }

    // Auto-sweep: prune trace dirs beyond the newest DEFAULT_KEEP so
    // the cache directory never grows unbounded. Runs once per traced
    // invocation (the OnceLock ensures `maybe_init` is single-shot).
    auto_sweep();
}

/// Best-effort auto-sweep of the traces root directory. Removes trace
/// dirs beyond the newest `DEFAULT_KEEP`. Called from `maybe_init` when
/// the tracer is successfully installed.
fn auto_sweep() {
    use crate::cli::trace::{sweep_trace_dirs, traces_root, DEFAULT_KEEP};

    let Some(root) = traces_root() else {
        return;
    };
    // The traces root may not exist yet (first invocation). That is
    // fine — `sweep_trace_dirs` returns 0 when `read_dir` fails.
    let _ = sweep_trace_dirs(&root, DEFAULT_KEEP);
}

/// Construct a `Span` guard.
///
/// Expansion is gated so the disabled path is a single atomic load on
/// `Tracer::current()`. When the tracer is uninitialised the result is
/// `None`, which the compiler can drop trivially.
///
/// The macro accepts an optional trailing `key = value, …` arg list.
/// Values are stringified via `format!` so they may be any
/// `Display`-implementing type.
///
/// # Example
///
/// ```ignore
/// let _s = perf::span!(perf::Level::Info, "save.capture.window", kitty_id = id);
/// ```
#[macro_export]
macro_rules! perf_span {
    ($level:expr, $name:literal) => {{
        match $crate::perf::Tracer::current() {
            Some(t) if $level <= t.level() => {
                Some($crate::perf::Span::new($name, &[]))
            }
            _ => None,
        }
    }};
    ($level:expr, $name:literal, $($k:ident = $v:expr),+ $(,)?) => {{
        match $crate::perf::Tracer::current() {
            Some(t) if $level <= t.level() => {
                let args: &[(&'static str, String)] = &[
                    $((stringify!($k), format!("{}", $v))),+
                ];
                Some($crate::perf::Span::new($name, args))
            }
            _ => None,
        }
    }};
}

/// Construct a `Span` guard with an explicit `parent_id`.
///
/// Same gating as [`span!`] but uses [`Span::with_parent`] so the
/// emitted JSONL carries the supplied parent id. Used at the
/// `buffer_unordered` fan-out boundary where each spawned future
/// cannot inherit parent context via task-local state.
///
/// # Example
///
/// ```ignore
/// let parent_id = capture_span.as_ref().map(|s| s.span_id()).unwrap_or(0);
/// let _s = perf::span_with_parent!(perf::Level::Info, "save.capture.window", parent_id, kitty_id = id);
/// ```
#[macro_export]
macro_rules! perf_span_with_parent {
    ($level:expr, $name:literal, $parent:expr) => {{
        match $crate::perf::Tracer::current() {
            Some(t) if $level <= t.level() => {
                Some($crate::perf::Span::with_parent($name, &[], $parent))
            }
            _ => None,
        }
    }};
    ($level:expr, $name:literal, $parent:expr, $($k:ident = $v:expr),+ $(,)?) => {{
        match $crate::perf::Tracer::current() {
            Some(t) if $level <= t.level() => {
                let args: &[(&'static str, String)] = &[
                    $((stringify!($k), format!("{}", $v))),+
                ];
                Some($crate::perf::Span::with_parent($name, args, $parent))
            }
            _ => None,
        }
    }};
}

#[doc(inline)]
pub use crate::perf_span as span;

#[doc(inline)]
pub use crate::perf_span_with_parent as span_with_parent;

#[cfg(test)]
mod tests {
    use super::*;

    /// When the tracer is uninitialised, `span!` returns `None` and
    /// performs no I/O. Verified via behaviour (no panic, no file
    /// writes) — the "one atomic load" claim is satisfied by inspection
    /// of the macro expansion in `perf_span!` above.
    #[test]
    fn span_is_noop_when_tracer_uninitialised() {
        // `Tracer::current()` returns None when `install` has not been
        // called for this process. We can't reset a `OnceLock`, so this
        // test is only valid when run in a process where no other test
        // has installed a tracer first. Stays in `mod.rs` rather than
        // an integration test so it observes the same process state.
        if Tracer::current().is_some() {
            // Earlier test already installed; skip the assertion.
            return;
        }
        let s = span!(Level::Info, "test.no_op", k = 1);
        assert!(s.is_none(), "span! must be None when tracer is uninit");
    }
}
