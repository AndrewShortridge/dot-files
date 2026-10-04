# Slice 6 — L3+L4 span ladder: per-adapter + per-RPC spans

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

Extend the instrumentation ladder with adapter-level and RPC-level spans. After this slice, a chrome-trace shows individual adapter invocations and every external RPC the save makes — `kitty @ ls`, `nvim_command`, `tmux display-message`, etc.

Spans added:

**L3 (`debug` level)** at the `Adapter` trait dispatch in `src/adapter/registry.rs`:
- `adapter.<name>.detect` — once per adapter per window during dispatch.
- `adapter.<name>.capture` — once per matched adapter per window.
- Names: `adapter.nvim`, `adapter.tmux`, `adapter.less`, `adapter.shell`, `adapter.raw`.

**L4 (`debug` level)** inside each RPC client:
- `kitty.rpc.ls`, `kitty.rpc.get_text`, `kitty.rpc.set_user_vars` in `src/kitty/rpc.rs`. Args: `bytes_out`, `bytes_in`.
- `nvim.rpc.mksession`, `nvim.rpc.list_bufs`, `nvim.rpc.buf_get_lines`, `nvim.rpc.buf_get_var` in `src/nvim_rpc/conn.rs`. Args: `bytes_out`, `bytes_in`, plus `buf` where applicable.
- `tmux.cmd.<subcmd>` in `src/tmux_rpc/`. Args: `cmd` (the verb).
- `fsx.commit_session` in `src/fsx/` covering the state-dir write+fsync+rename atomic publish.

Activation: `KSESSION_TRACE_LEVEL=debug` enables L1–L4; `info` continues to limit to L1–L2.

## Acceptance criteria

- [ ] With `KSESSION_TRACE_LEVEL=debug` and the 12-window fixture, the JSONL contains all of: at least one `adapter.*.detect`, the matching adapter's `adapter.*.capture` per window, ≥1 `kitty.rpc.ls`, ≥12 `kitty.rpc.set_user_vars` (one per window from the UUID-tag phase), and at least one `fsx.commit_session`.
- [ ] `bytes_out` and `bytes_in` are populated on every RPC span; values look plausible (e.g., `kitty.rpc.ls` has `bytes_in` > 1000 for a 12-window session).
- [ ] `ksession trace stats kitty.rpc.ls` returns a histogram with the expected count.
- [ ] With `KSESSION_TRACE_LEVEL=info` (default), the JSONL contains **no** L3 or L4 spans — the level filter is respected.
- [ ] Adapter spans correctly nest under their owning `save.capture.window` parent in the chrome trace.
- [ ] Existing tests pass.

## Blocked by

- Slice 5 ([`05-spans-L1-L2.md`](./05-spans-L1-L2.md)) — builds on the L1+L2 hierarchy.
