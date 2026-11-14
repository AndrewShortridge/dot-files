# Hand-rolled Span/Tracer instead of the `tracing` crate ecosystem

PRD-0 ships a perf observability layer that wraps every boundary on the
L1–L5 ladder (phase / per-window / per-adapter / per-RPC / per-socket-IO).
The obvious default would be to depend on `tracing` + `tracing-subscriber`
+ `tracing-chrome` (~50 transitive crates) and let those layers emit the
chrome-trace JSON, the textual tree, and the histogram.

We instead implement `perf::Span` + `perf::Tracer` ourselves in ~150 LOC
of `std` (no new deps). The Span is a plain struct holding name, start
`Instant`, parent id, and a small args vec; its `Drop` impl writes one
chrome-trace `X` event line to a process-wide `BufWriter<File>` guarded
by a `Mutex`, gated on a `OnceLock<Tracer>` initialised from
`KSESSION_TRACE_DIR`. When the env var is unset the OnceLock is empty and
span Drop is a single atomic load with no allocation, write, or syscall.

The decision is driven by three constraints that don't apply to most
projects: (a) cross-process tracing must include `restore.sh` (bash) and
`ksession_restore.lua` (lua), neither of which can use the `tracing`
crate — so the JSONL format ends up hand-rolled on those legs regardless,
and matching the format on the Rust side keeps the wire shape uniform;
(b) the release profile already prioritises binary size (LTO fat,
codegen-units 1, strip debuginfo) and adding 50 crates fights that; and
(c) no OpenTelemetry/Jaeger/Honeycomb integration is in scope, so the
ecosystem flexibility `tracing` buys is unused. The Span/Drop shape is
intentionally `tracing`-compatible so a future migration is a
sed-style rename rather than a redesign.
