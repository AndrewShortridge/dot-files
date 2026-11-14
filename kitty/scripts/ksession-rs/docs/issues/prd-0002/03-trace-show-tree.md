# Slice 3 — `ksession trace show --format=tree` textual tree

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

Implement the `tree` format variant for `ksession trace show <ts>` (the `chrome` format already landed in Slice 1). After this slice, `ksession trace show <ts> --format=tree` renders an indented spans-tree to stdout for terminal consumption, no external viewer required.

Output shape:

```
save.total                                          19.4ms
├── save.discover                                    1.2ms
├── save.tag_uuids                                   0.4ms
├── save.capture                                    16.8ms
│   ├── save.capture.window {kitty_id=12}            8.2ms
│   ├── save.capture.window {kitty_id=13}            7.9ms
│   └── save.capture.window {kitty_id=14}            8.4ms
├── save.render                                      0.6ms
└── save.commit                                      0.4ms
```

Algorithm:

- Read all JSONL files in the trace dir, parse each event.
- Group by `tid` (events on the same thread are guaranteed sequential by chrome-trace semantics).
- Within a `tid`, infer parent-child by `ts`/`dur` containment: an event A is the parent of event B if A.ts ≤ B.ts and (A.ts + A.dur) ≥ (B.ts + B.dur) and A is the closest such enclosing event on the same `tid`.
- Cross-`tid` parent-child uses the `parent_id` field if present (e.g., `buffer_unordered`-spawned futures).
- Render `name` followed by sorted `args` in `{k=v}` form, right-align elapsed time.
- Make `--format=tree` the default when no `--format` is passed.

## Acceptance criteria

- [ ] `ksession trace show <ts>` (no `--format`) prints a tree.
- [ ] `ksession trace show <ts> --format=tree` prints the same tree.
- [ ] Tree correctly nests `save.capture.window` events under `save.capture` even though they fire on different `tid`s (cross-spawn parent-id is honoured).
- [ ] Args are rendered when present (e.g., `save.capture.window {kitty_id=12}`).
- [ ] Unit tests: golden fixture JSONL → expected tree output snapshot.
- [ ] Output is plain ASCII tree characters (`├`, `└`, `│`, `─`) — terminal-friendly, no colour codes by default.
- [ ] No new third-party crates.
- [ ] `cargo test` passes.

## Blocked by

- Slice 1 ([`01-tracer-foundation.md`](./01-tracer-foundation.md)).
