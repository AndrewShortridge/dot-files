# Slice 7 — L5 span ladder: per-socket-IO spans

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

Add the deepest layer of the ladder — bracket every socket write, socket read, and serde decode with its own span. After this slice, an RPC's L4 span has three or four L5 children showing exactly where time went: wire-out, wire-in, decode.

Spans added (all `trace` level):

**Inside `src/kitty/rpc.rs`** for each RPC method:
- `kitty.rpc.<method>.write_req`
- `kitty.rpc.<method>.read_resp`
- `kitty.rpc.<method>.decode` (json/binary decode of the response payload)

**Inside `src/nvim_rpc/conn.rs`** for each msgpack-RPC call:
- `nvim.rpc.write_msgpack`
- `nvim.rpc.read_msgpack`
- `nvim.rpc.decode_msgpack`

**Inside `src/tmux_rpc/`** for each subprocess invocation (control-mode pipe lifecycle covered by PRD-2 once it lands):
- `tmux.subprocess.spawn`
- `tmux.subprocess.wait`
- `tmux.subprocess.decode_stdout`

Activation: `KSESSION_TRACE_LEVEL=trace` enables L1–L5. `debug` and `info` continue to suppress L5.

## Acceptance criteria

- [ ] With `KSESSION_TRACE_LEVEL=trace` and the 12-window fixture, every L4 RPC span has the corresponding L5 children present in the JSONL.
- [ ] Sum of L5 child `dur`s ≤ parent L4 `dur` (sanity check — children don't exceed parent).
- [ ] `chrome://tracing` rendering of the trace shows each RPC's three L5 children as visually nested phases inside the parent.
- [ ] With `KSESSION_TRACE_LEVEL=debug`, no L5 spans appear in the JSONL.
- [ ] L5 span emission cost on hot paths is bounded — manual inspection of `kitty.rpc.set_user_vars` total cost vs same call without L5 shows the overhead is ≤5% (verified via Slice 2's `--against` workflow).
- [ ] Existing tests pass.

## Blocked by

- Slice 6 ([`06-spans-L3-L4.md`](./06-spans-L3-L4.md)) — L5 spans are children of L4 RPCs.
