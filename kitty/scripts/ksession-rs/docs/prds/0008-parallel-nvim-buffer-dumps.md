# PRD-6: Parallel nvim buffer dumps within a single adapter capture

Status: conditional — drop if PRD-0 data shows no win
Depends on: PRD-0 (`0002-observability-infrastructure.md`)

## Problem Statement

`adapter::nvim::capture` (`src/adapter/nvim.rs`) issues a sequential
sequence of msgpack-RPC calls to a single nvim instance: `list_bufs`,
then per-buffer `buf_get_var(modified)`, `buf_get_lines`, `buf_get_var(...)`.
For a nvim window with 8 modified buffers, that is 1 + 3×8 = 25 sequential
RPCs on one connection.

Plan §5.3 does not parallelize within an adapter — the assumption
through §B.2 was that the cross-window `buffer_unordered(12)` fan-out
gives sufficient parallelism. But within a single heavy-nvim window,
buffer dumps sit on the critical path and could conceivably overlap.
nvim's msgpack-RPC supports multiple in-flight requests on one
connection (each request carries a `msgid`, responses are demultiplexed
by it), so the protocol allows it.

**This PRD is conditional.** PRD-0's histograms will reveal whether
nvim buffer dumps are a non-trivial fraction of `adapter.nvim.capture`
wall time. If `nvim.rpc.buf_get_lines` cumulative cost is <5% of
`adapter.nvim.capture` p50, this PRD is dropped — the dominant cost is
`:mksession!` itself, which PRD-8 attacks differently. If it's >15%,
this PRD proceeds.

## Solution

Inside `adapter::nvim::capture`, replace the sequential per-buffer
loop with a `futures::stream::iter(bufs).buffer_unordered(N)`
pipeline issuing concurrent `buf_get_var` / `buf_get_lines` calls on
the same `NvimConn`. The msgpack-RPC client (`src/nvim_rpc/conn.rs`)
already demultiplexes responses by `msgid`, so multiple in-flight
requests on one connection work out of the box.

The concurrency cap N is small (default 4) because nvim's API
handler is single-threaded — going past ~4 produces no further wall-
clock improvement and increases response-queue depth.

## User Stories

1. As a kitty user saving a session where one nvim window has 12
   modified buffers, I want per-buffer dumps to overlap so that the
   total capture time approaches "longest single buffer" rather than
   "sum of all buffers".

2. As the maintainer who landed PRD-0, I want to make the
   conditional-drop decision from data: if `nvim.rpc.buf_get_lines`
   cumulative p50 inside one `adapter.nvim.capture` is ≤5% of its
   parent span, this PRD is closed without code.

## Implementation Decisions

### Gate the decision on PRD-0 data

Step 1 of executing this PRD is to land PRD-0, run the perf budget
test on a fixture nvim with 8 modified buffers, and look at
`nvim.rpc.buf_get_lines` cumulative cost. **If the cost is <5% of
adapter.nvim.capture p50, close this PRD with no code changes and
record the measurement in `docs/findings/`.** Only if >15% do we
proceed.

### Implementation (if proceeding)

- `src/adapter/nvim.rs` `capture()` — replace the per-buffer `for`
  loop with:

  ```rust
  let bufs = conn.list_bufs().await?;
  let dumps: Vec<BufferDump> = futures::stream::iter(bufs)
      .map(|buf| async move {
          let modified = conn.buf_get_var(buf, "&modified").await?;
          if !modified.as_bool() { return Ok(BufferDump::unmodified(buf)); }
          let lines = conn.buf_get_lines(buf, 0, -1, false).await?;
          // ... other per-buf queries
          Ok(BufferDump::full(buf, lines, ...))
      })
      .buffer_unordered(NVIM_BUF_FAN_OUT)
      .try_collect()
      .await?;
  ```

- `NVIM_BUF_FAN_OUT: usize = 4` — exposed via env var
  `KSESSION_NVIM_BUF_FAN_OUT` for bisection.

### Span instrumentation

Per-buffer L4 spans already exist in PRD-0:
`nvim.rpc.buf_get_lines{buf}`. After this PRD, those spans will
overlap in time on the chrome-trace view, visually validating the
parallelism.

### Risk: msgpack-RPC ordering

The msgpack-RPC spec allows arbitrary `msgid` ordering, but nvim's
internal handler processes requests serially. Issuing 4 concurrent
`buf_get_lines` for different buffers is safe — each is a pure
read of independent state.

The risk is concurrent writes (e.g., if we ever called `buf_set_lines`
concurrently with a read on the same buffer). Save is read-only on
nvim state, so this risk doesn't apply here. A comment in
`adapter::nvim::capture` documents the assumption.

### Out of scope

- Parallelising `:mksession!` itself. `mksession` is a single
  Vimscript invocation; we can't decompose it. PRD-8 attacks the
  `mksession` cost via a different mechanism (proactive caching).
- Parallelising across nvim instances. That's already done by the
  outer `buffer_unordered(12)` at the window level.
- Replacing `nvim-rs` with a hand-rolled msgpack-RPC client. The
  existing client supports concurrent requests; no rewrite needed.

## Testing Decisions

### Decision-gating test

- **`tests/perf_nvim_buf_fanout_decide.rs`** — `#[ignore]`,
  measurement-only. Set up a fixture nvim with 8 modified buffers,
  run capture with tracing on, report `nvim.rpc.buf_get_lines`
  cumulative as a percentage of `adapter.nvim.capture` p50. Print
  the decision: "drop PRD-6" if <5%, "proceed" if >15%, "needs
  re-measurement" in the gap.

### Tests for the implementation (if proceeding)

- **`nvim_buf_concurrent_dump.rs`** — fixture nvim with 4 modified
  buffers of different sizes; assert all 4 `buf_get_lines` calls
  return correctly under buffer_unordered fan-out; assert the
  resulting `BufferDump` set is correct regardless of completion
  order.
- **`nvim_buf_fanout_perf.rs`** — benchmark with 12 modified buffers,
  compare wall time at FAN_OUT=1 (serial) vs FAN_OUT=4. Assert
  FAN_OUT=4 is meaningfully faster (target: ≥30% reduction if
  per-buffer cost is dominated by msgpack-RPC RTT, less if dominated
  by buffer-read CPU).

## Out of Scope

- This PRD's existence past the gating decision. If the data shows
  the gain isn't there, the PRD closes; we don't ship a
  "parallel buffer dump" knob for the principle of it.

## Further Notes

- This is the one PRD on the batch that may evaporate. The framing
  is deliberate: PRD-0 gives us the data; we don't pre-commit to
  shipping code that may not help.
- Cross-references:
  - PRD-0 — gates the decision via `nvim.rpc.buf_get_lines` histogram.
  - PRD-8 — separate attack on `:mksession!`; if PRD-8 lands first
    and reduces `adapter.nvim.capture` p50 substantially, the
    fraction calculus for PRD-6 changes and it likely closes.
