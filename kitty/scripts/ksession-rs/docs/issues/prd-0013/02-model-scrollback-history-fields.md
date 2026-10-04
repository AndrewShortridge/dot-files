# Slice 2 — Add scrollback + history fields to Program::Shell model

## Parent

[`docs/prds/0013-scrollback-replay-and-per-window-history.md`](../../prds/0013-scrollback-replay-and-per-window-history.md) — PRD-13, Model changes.

## What to build

Extend the `Program::Shell` variant in `model/program.rs` with two new optional fields:

- `scrollback: Option<PathBuf>` — path to the saved ANSI scrollback file for this window.
- `history: Option<PathBuf>` — path to the per-window history file in the state dir.

Both fields use `#[serde(default, skip_serializing_if = "Option::is_none")]` for forward/backward compatibility with existing manifests (older manifests without these fields deserialize cleanly as `None`).

Wire the `scrollback` field during save: `Window.scrollback` (already populated by `capture_scrollback()` in `save.rs`) is propagated into `Program::Shell.scrollback` when the program variant is `Shell`. This happens after scrollback capture and before manifest serialization.

The `history` field is left as `None` in this slice — it will be populated by the shell adapter in Slice 4.

All existing code that constructs `Program::Shell` (adapter/shell.rs, tests, fixtures) must be updated to include the new fields (defaulting to `None`).

## Acceptance criteria

- [ ] `Program::Shell` has `scrollback: Option<PathBuf>` and `history: Option<PathBuf>` fields.
- [ ] Both fields are `#[serde(default, skip_serializing_if = "Option::is_none")]`.
- [ ] Existing manifests (without the new fields) deserialize without error.
- [ ] New manifests with the fields round-trip through serde correctly.
- [ ] During save, when a shell window has `Window.scrollback = Some(path)`, the same path appears in `Program::Shell.scrollback`.
- [ ] When `Window.scrollback` is `None`, `Program::Shell.scrollback` is `None`.
- [ ] All existing tests pass (`cargo test`).
- [ ] A unit test verifies serde round-trip for `Program::Shell` with and without the new fields.

## Blocked by

None — can start immediately.
