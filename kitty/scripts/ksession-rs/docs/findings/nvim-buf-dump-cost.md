# nvim Buffer Dump Cost Analysis — PRD-0008 Gating Decision

## Status

Pending — run `cargo test --release --test perf_nvim_buf_fanout_decide -- --ignored --nocapture` to populate.

## Methodology

- Workload: 8 modified buffers (2 empty, 2 small ~10 lines, 2 medium ~100 lines, 2 large ~500 lines)
- Iterations: 10
- Measurement: `nvim.rpc.buf_get_lines` + `nvim.rpc.buf_get_var` cumulative cost as % of `dump_modified_buffers` wall time
- Decision thresholds: <5% → drop PRD-0008, >15% → proceed, 5-15% → inconclusive

## Results

_To be populated by test run._

## Decision

_To be populated by test run._

## Fan-out Benchmark

### Methodology

- Workload: 12 modified buffers (3 empty, 3x20 lines, 3x200 lines, 3x1000 lines)
- Iterations: 8 per configuration
- Configurations: `KSESSION_NVIM_BUF_FAN_OUT=1` (serial) vs `KSESSION_NVIM_BUF_FAN_OUT=4` (concurrent)
- Measurement: `dump_modified_buffers` p50 wall time

### Results

_To be populated by test run:_ `cargo test --release --test nvim_buf_fanout_perf -- --ignored --nocapture`

### Analysis

_To be populated by test run._
