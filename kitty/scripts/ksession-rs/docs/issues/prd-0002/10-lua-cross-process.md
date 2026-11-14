# Slice 10 — Lua cross-process tracing for `ksession_restore.lua`

## Parent

[`docs/prds/0002-observability-infrastructure.md`](../../prds/0002-observability-infrastructure.md) — PRD-0.

## What to build

Extend the trace stream to nvim. After this slice, a restore that re-loads an nvim session through `ksession_restore.lua` produces a `<trace_dir>/nvim-<pid>.jsonl` containing one chrome-trace event per restore phase (source session.vim, restore buffers, restore window options, fire user autocmds).

Components:

- **`trace_span(name, args, fn)` helper** added to `ksession_restore.lua`:
  - Reads `KSESSION_TRACE_DIR` from `os.getenv` once at module load.
  - If unset: the helper is a passthrough that just runs `fn()` with no timing or I/O.
  - If set: brackets `fn()` with `vim.uv.hrtime()` (monotonic ns, no syscall on Linux), formats one chrome-trace `X` JSON line using `vim.json.encode` for args, appends to `<trace_dir>/nvim-<pid>.jsonl` via `io.open`/`write`/`close`. Errors during emit go silently into a fallback `nvim-error.log` file in the trace dir; never raised into the user's restore.
- **Wrap each restore phase** in `ksession_restore.lua`:
  - `nvim.restore.source_session_vim`
  - `nvim.restore.load_modified_buffers`
  - `nvim.restore.restore_window_options`
  - `nvim.restore.fire_user_autocmds`
  (Phase names are placeholders — actual phases enumerated in PRD-1; this slice's job is the helper + initial four wraps. PRD-1 may add more.)

No bash dependency, no shared lib needed — the lua helper is self-contained.

## Acceptance criteria

- [ ] A new test `tests/lua_trace_smoke.lua` (or `.rs` invoking headless nvim with the lua loaded): with `KSESSION_TRACE_DIR=/tmp/t`, call `trace_span("test.span", {foo="bar"}, function() end)`, assert `/tmp/t/nvim-*.jsonl` exists with one valid chrome-trace JSON line containing `"name":"test.span"` and `args.foo == "bar"`.
- [ ] Same test with `KSESSION_TRACE_DIR` unset: no file created; helper runs the inner function transparently.
- [ ] Integration test `tests/lua_trace_restore_integration.rs`: run a fixture restore with a saved nvim window and `KSESSION_TRACE_DIR` set; assert the resulting trace dir contains a `nvim-<pid>.jsonl` with at least one `nvim.restore.*` event.
- [ ] `ksession trace show <ts> --format=chrome` (Slice 1) merges the lua-side JSONL alongside the rust-side. Resulting JSON loads in perfetto.
- [ ] Lua helper errors during emit do **not** crash the restore — verified by a test that creates an unwritable trace dir and asserts restore still succeeds with the same `.conf` round-trip.
- [ ] No new lua dependencies (`vim.uv.hrtime`, `vim.json.encode`, `io.*` are all built-in).

## Blocked by

- Slice 1 ([`01-tracer-foundation.md`](./01-tracer-foundation.md)) — needs the JSONL format and trace-dir layout.
