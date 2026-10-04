# Slice 5 — L1+L2 span ladder for save: phase + per-window spans

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

Instrument the save orchestration with L1 phase spans and L2 per-window spans. After this slice, a chrome-trace of a 12-window save shows a phase-by-phase breakdown with each phase's per-window children nested correctly under `save.capture`.

Spans added:

**L1 (`info` level)** at the orchestration entry in `src/session/save.rs`:
- `save.discover`
- `save.tag_uuids`
- `save.capture` — wraps the entire `buffer_unordered(12)` fan-out
- `save.sanitize`
- `save.render`
- `save.commit`

**L2 (`info` level)** at the `buffer_unordered` site in `save.capture`:
- `save.capture.window` per spawned future, with `kitty_id` as an arg.
- Parent id propagated explicitly: capture the active `save.capture` span's id before spawning; each future calls `Span::with_parent(captured_id)` so the JSONL line carries the right `parent_id` field even though it fires on a different tokio task.

The L0 `save.total` span from Slice 1 stays in place; the new L1 spans nest under it.

Default `KSESSION_TRACE_LEVEL=info` activates all of L1+L2 (and the existing `save.total`); higher levels (`debug`, `trace`) will activate L3+ in later slices but are no-ops for now.

## Acceptance criteria

- [ ] `KSESSION_TRACE_DIR=/tmp/t ksession save <12-window-fixture>` produces JSONL with: one `save.total`, six L1 phase spans, twelve `save.capture.window` spans (one per window).
- [ ] Each `save.capture.window` event carries `args.kitty_id` set to the correct window id.
- [ ] Each `save.capture.window` event carries `parent_id` referencing the `save.capture` span (cross-spawn parent propagation works).
- [ ] `ksession trace show <ts> --format=tree` (Slice 3) renders the windows nested under `save.capture` with no orphan branches.
- [ ] `ksession trace stats save.capture.window` (Slice 2) returns a histogram with count ≥ 12 after one save against the 12-window fixture.
- [ ] Setting `KSESSION_TRACE_LEVEL=debug` produces the same output (L3+ spans not yet added; this verifies the level filter is respected).
- [ ] Existing tests pass.

## Blocked by

- Slice 1 ([`01-tracer-foundation.md`](./01-tracer-foundation.md)).
