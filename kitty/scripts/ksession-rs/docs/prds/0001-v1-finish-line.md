# ksession-rs v1 finish line

Status: ready-for-agent

## Problem Statement

`ksession-rs` is substantially built — 440 tests passing, all five adapters
implemented, `save` and `show` working end-to-end — but the v1 success bar
agreed during the grilling session is not yet met:

- `restore`, `list`, and `rm` subcommands exit with "not yet implemented;
  use ksession.sh". Direct shell-prompt use of `ksession-rs` for anything
  except `save` and `show` is broken, and Phase 3 of the migration plan
  (renaming `ksession.sh` → `ksession-legacy.sh`) cannot start until those
  three subcommands work.
- The tmux capture pipeline writes a complete `restore.sh` but only persists
  a thin `TmuxWindow { idx, name, layout, active }` summary into
  `manifest.json`. `ksession show` cannot render panes; `Program::Tmux`
  also lacks the plan-spec'd `session_id` and `active_window_idx` fields.
- `KError::PartialCapture` aborts the entire save when more than
  `max(1, total/4)` windows degrade, throwing away the user's typed session
  name. ADR 0001 commits us to degrading instead.
- The `kitty_version` drift warning from ADR 0002 is not yet captured or
  surfaced.
- Synthetic empty-tab windows (for tabs that filter to zero real windows)
  have no reserved identity — the §C.1 patcher cannot distinguish them from
  real windows.
- The `ksession-save-prompt.sh` overlay hardcodes `ksession.sh` instead of
  dispatching via `KSESSION_IMPL`, so Phase 2 opt-in (point the env var at
  `ksession-rs`) is impossible.

## Solution

Close the gap to v1 in seven contained changes, grouped into three landing
passes:

1. **Pass 1 — model/schema** (model-touching, must precede test/render
   work): add `TmuxPane` plus `Program::Tmux.session_id` and
   `active_window_idx`; add `SessionFile.kitty_version`; reserve the
   synthetic window identity range. Schema stays at `1` (pre-ship, per
   ADR 0003).

2. **Pass 2 — orchestration cleanup**: delete `KError::PartialCapture` per
   ADR 0001; every save that produces any surviving windows commits, with
   per-window degradations printed to stderr and a non-zero exit when any
   degraded.

3. **Pass 3 — user surface**: implement `restore`, `list`, `rm` as thin
   dispatchers reading the now-stable manifest; patch
   `ksession-save-prompt.sh` to dispatch via `$KSESSION_IMPL`.

Plan-document drift (renaming `Window.uuid` → `Window.ksession_id` through
the plan) lands last; it is documentation-only.

## User Stories

1. As a kitty user who saved a session containing a 3-pane tmux window, I
   want `ksession-rs show <name>` to render each pane's program, cwd, and
   command, so that I can audit what will be restored without parsing
   `restore.sh` by hand.

2. As the maintainer reading a `manifest.json` written by a future version,
   I want the manifest to carry every captured detail of a tmux session
   (id, active window index, per-pane program), so that the on-disk
   representation does not silently lose information that `restore.sh`
   already encodes.

3. As a kitty user, I want `ksession-rs restore <name>` to load a session,
   so that I can stop typing the kitty incantation by hand.

4. As a kitty user, I want `ksession-rs restore` to sweep orphaned
   gen-stamped state directories before launching kitty, so that a
   load-only workflow does not accumulate stale state forever.

5. As a kitty user, I want `ksession-rs list` to print one line per saved
   session showing the name, creation time, and a short summary, so that I
   can find the session I want without globbing the sessions directory.

6. As a kitty user, I want `ksession-rs rm <name>` to remove a saved
   session and its sidecar state, so that I do not have to know the
   `<name>.gen-<ts>.state/` naming convention.

7. As a kitty user saving a 4-window session where two nvim instances have
   timed out, I want my `.conf` to still be written with the two healthy
   windows preserved and the two failures shown as `Program::BareShell`
   with stderr warnings, so that I do not lose the half of my work that
   captured successfully.

8. As a kitty user whose save partially degraded, I want `ksession-rs save`
   to exit with code `2`, so that `ksession-save-prompt.sh` can surface a
   "saved with N degradations" indicator in the overlay.

9. As a kitty user who saved a session under kitty 0.42 and is restoring
   under kitty 0.43, I want a one-line warning on `restore` / `list` /
   `show` when the captured `kitty_version` major.minor differs from the
   running kitty, so that I can correlate a weird-looking restored layout
   with the version skew.

10. As a kitty user, I want a session containing a tab whose only window
    was an overlay (and therefore got filtered) to restore as a tab
    containing a single bare login shell, so that my tab count survives
    the round-trip.

11. As a kitty user with multiple empty tabs in one OS window, I want each
    empty tab to be represented by a distinct synthetic window in the
    manifest, so that the patcher can emit one `launch /bin/bash -l` line
    per empty tab rather than collapsing them.

12. As the maintainer, I want synthetic windows to be detectable by
    `kitty_id >= SYNTHETIC_ID_FLOOR` in a single check, so that the
    patcher does not need a side-table to ask "is this window real?"

13. As a kitty user during Phase 2 opt-in, I want to set
    `KSESSION_IMPL=$HOME/.local/bin/ksession-rs` in `kitty.conf` and have
    the save keybinding route through the Rust binary, so that I can run
    the Rust port daily without renaming `ksession.sh`.

14. As a kitty user during Phase 2 opt-in, I want
    `ksession-save-prompt.sh` to reject a `KSESSION_IMPL` value that is
    not executable or that points at a bare shell name, so that a
    fat-fingered env var cannot silently misroute saves.

15. As the maintainer, I want every implementation detail in the plan
    document to use the same field name as the code (`ksession_id`), so
    that a future contributor cross-referencing plan and code does not
    chase a phantom `uuid` field.

16. As the maintainer running a save→restore round-trip test, I want the
    manifest to contain every field needed to faithfully describe what
    was captured (including `session_id`, `active_window_idx`, pane
    list), so that the test can assert against the manifest instead of
    diffing `restore.sh` byte strings.

17. As the maintainer reading the source code, I want the `Program::Tmux`
    Rust struct to match its plan-spec'd shape verbatim, so that the
    plan continues to function as a reference document.

## Implementation Decisions

### Pass 1 — model & schema

- Add `model::TmuxPane` with fields `index: u32`, `pane_pid: u32`,
  `pane_id_digits: u64`, `cwd: Option<PathBuf>`,
  `current_command: Option<String>`, `program: Box<Program>` per plan §4.
- Extend `model::TmuxWindow` with `panes: Vec<TmuxPane>`,
  `active_pane_idx: Option<u32>`, `layout_leaf_count: u32`.
- Extend `Program::Tmux` with `session_id: u32` and
  `active_window_idx: Option<u32>`.
- The tmux adapter already builds the equivalent data into its private
  `restore_panes` Vec during capture; populate the new model fields in
  the same loop iteration. No additional `/proc` reads or tmux queries
  required.
- Add `SessionFile.kitty_version: String` (capture verbatim from
  `kitty --version` stdout including any dev-build suffix).
- Add `const SYNTHETIC_ID_FLOOR: u64 = u64::MAX - 1024` to
  `model::window`. Synthetic windows in §5.7 Phase 2 receive descending
  IDs (`u64::MAX`, `u64::MAX - 1`, …) allocated by a
  `SyntheticAllocator` so the §C.1 patcher and the Phase 2 fallback
  draw from the same identity source.
- Schema number stays at `1` per ADR 0003.
- `session::show` renders panes by recursing into
  `TmuxWindow.panes`; the existing `TODO(step 7)` comment in
  `session/show.rs` is the removal site.

### Deep modules extracted

- **`kitty::version`** — `Version { major: u32, minor: u32, raw: String }`
  plus `parse(stdout: &str) -> Result<Version, KError>` and
  `Version::compat(other: &Version) -> Compat` returning
  `Same | MajorMinorDiffers | Unparseable`. Pure, testable on string
  fixtures; no `/proc`, no subprocess. Production callers spawn
  `kitty --version`, hand stdout to `parse`, persist the `Version`.
- **`session::manifest`** — `read(path: &Path) -> Result<Loaded, KError>`
  where `Loaded` carries the deserialised `SessionFile` plus a `Vec<Warning>`
  (currently containing just the kitty-version drift, but the shape leaves
  room for schema-soft-drift in the future). Used by `restore`, `list`,
  `show`. The schema check (rejecting any future incompatible bump per
  ADR 0003) lives here, not duplicated across three subcommands.
- **`session::synth`** — `SyntheticAllocator::new() -> Self` +
  `fn next(&mut self) -> u64`. Yields `u64::MAX`, `u64::MAX - 1`, …;
  panics if it descends past `SYNTHETIC_ID_FLOOR` (which would mean
  >1024 synthetic windows in one save, structurally impossible).
- **`fsx::sweep_orphans`** (existing) — no refactor; `restore` calls it
  before launching kitty so load-only workflows still GC.

### Pass 2 — orchestration cleanup

- Delete `KError::PartialCapture` from `error.rs`.
- Delete the post-Phase-1 threshold check in `session::save`.
- Drain `ctx.errors` after Phase 1 and emit one stderr line per
  `AdapterError`. Format: `ksession: window <kitty_id>: <error>`.
- Set a `degraded_any: bool` flag if anything was drained; return it
  alongside `SessionFile` so `cli::save` can exit with code `2` when set.
- Update the test that asserts `PartialCapture` to assert
  degrade-and-warn behaviour.

### Pass 3 — user surface

- **`restore <name>`**: validate name against `^[A-Za-z0-9._-]+$`; resolve
  `<sessions_dir>/<name>.conf`; if absent return error `not_found`; call
  `fsx::sweep_orphans(&sessions_dir)`; spawn
  `kitty --detach --class kitty-project-<name> --session <conf_path>`
  via `Command::spawn` (not exec — the user keeps their shell). If
  manifest is readable and `kitty_version` major.minor differs from the
  running kitty, eprintln a one-line drift warning before spawning.

- **`list`**: enumerate `<sessions_dir>/*.conf`; for each, attempt
  `session::manifest::read` to get name, `created_at`,
  `kitty_version`, and a window count; print one tab-aligned line per
  session sorted by `created_at` desc. If a manifest cannot be read,
  print the basename and a `(no manifest)` marker but do not abort the
  whole listing.

- **`rm <name>`**: validate name; locate `<sessions_dir>/<name>.conf`
  and every `<sessions_dir>/<name>.gen-*.state/` directory; rename each
  to `<original>.deleted.<pid>` first, then `remove_dir_all` / `remove_file`.
  The rename-first step is a tombstone so a crash mid-rm leaves obvious
  garbage instead of half-deleted state.

- **`ksession-save-prompt.sh`** patch: replace the hardcoded
  `KSESSION="$(dirname "$0")/ksession.sh"` line with
  `KSESSION="${KSESSION_IMPL:-$(dirname "$0")/ksession.sh}"`, plus two
  validation lines: reject if `[[ ! -x "$KSESSION" ]]`, reject if
  `$(basename "$KSESSION")` matches `^(bash|sh|zsh|dash|fish)$`. ~6
  lines of bash added.

### Documentation drift

- `RUST_PORT_PLAN.md` rename of `Window.uuid` → `Window.ksession_id` is
  mechanical (39 instances by my count). Run as a single sed-style
  pass; spot-check that no false-positive on the `uuid` crate name,
  generic UUID-string references, or `Uuid` type itself.

## Testing Decisions

A good test here exercises external behaviour: the on-disk artifact
shape (`.conf` body, `manifest.json` fields), CLI exit codes, stderr
messages, and observable filesystem state. Internal types like
`SyntheticAllocator`'s next-value sequence get tested through
`session::save`'s emitted manifest, not by calling `.next()` 1024 times
in a unit test.

The existing 440-test suite is the prior art — `tests/conf_golden.rs`
for `.conf` shape, `tests/save_orchestration.rs` for the save pipeline,
`tests/tmux_*.rs` for tmux-specific edge cases. New tests slot into
that pattern.

### Modules to test directly

- **`kitty::version::parse`** — golden table of (`stdout_string`,
  `expected_major_minor_or_err`) covering: `kitty 0.42.0`,
  `kitty 0.42.1-rc1`, `kitty 0.42`, garbage. Pure unit test.
- **`kitty::version::compat`** — golden table covering same / minor
  diff / major diff / unparseable.
- **`session::manifest::read`** — golden fixture manifests for: valid v1,
  manifest missing optional new fields (uses serde defaults
  successfully), manifest with mismatched kitty_version (returns
  warning), missing file (returns NotFound), schema bump beyond
  CURRENT_SCHEMA (returns SchemaMismatch).
- **`TmuxPane` round-trip** — serialise → deserialise should round-trip
  including nested `program: Box<Program>` recursion. One test per
  Program variant inside a pane.
- **`ksession show`** — golden fixtures for a session with one tmux
  window containing three panes (shell, nvim, less), verify the tree
  rendering descends into panes.

### End-to-end tests to add

- **`partial_degrade_commits.rs`** — set up a save where one of two
  windows degrades; assert `.conf` is written, manifest contains the
  degraded window as `BareShell`, stderr has one `window N:` line, exit
  code is `2`.
- **`restore_smoke.rs`** — given a valid `.conf`, the `restore`
  subcommand spawns `kitty` with the right argv. Use a stub kitty
  binary on `$PATH` that logs its argv to a tmpfile; assert argv.
- **`list_smoke.rs`** — populate a tmp sessions dir with three saves of
  varying ages; assert list output is sorted desc by created_at, format
  matches.
- **`rm_tombstone.rs`** — `rm <name>` produces no `<name>.conf` and no
  `<name>.gen-*.state/`; mid-deletion crash (simulated by injecting an
  IO error after the tombstone rename) leaves only `*.deleted.<pid>`
  artifacts, not half-deleted state.
- **`synthetic_window_round_trip.rs`** — capture a kitty OS window with
  one empty tab; assert manifest contains a window with
  `kitty_id >= SYNTHETIC_ID_FLOOR`; assert the rendered conf injects
  the corresponding `launch /bin/bash -l` line in that tab.
- **`ksession_save_prompt_dispatch.sh`** — shell test (run under
  `bash -x` redirecting to /dev/null): with `KSESSION_IMPL=/bin/true`
  the script invokes `/bin/true`; with `KSESSION_IMPL=bash` it rejects
  with the bare-shell message; with `KSESSION_IMPL=/no/such/file` it
  rejects with the not-executable message.

### Tests intentionally not added

- Unit tests for `SyntheticAllocator::next` — exercised through the
  end-to-end synthetic-window round-trip; isolating the allocator buys
  nothing.
- Direct unit tests on the `degraded_any` plumbing inside
  `session::save` — exercised through `partial_degrade_commits.rs`.

## Out of Scope

- Fixing the v1-parity bugs the grilling explicitly preserved: pane
  position scrambling under `select-layout`, `DIRENV_DIR`
  captured-but-unused in the shell-pane activation string. These are
  intentional Bash-parity preservations with TODO(v2) markers in §5.4
  and §C.2. Do not touch them in this PRD's scope.
- The `ksession-rs doctor` subcommand. Discussed in grilling Q9;
  skipped from v1.
- Full from-scratch fallback rendering of `set_layout_state`. ADR 0002
  commits us to round-trip + version warning; do not resurrect the
  ~150 LOC of from-scratch renderer.
- The §B.3.2 tmux control-mode transport (step 7.5). The field-per-call
  subprocess path stays in v1; control mode is a perf optimisation for
  v1.1+.
- Migration Phases 3 and 4 (renaming `ksession.sh` →
  `ksession-legacy.sh`, then deleting it). This PRD completes Phase 2's
  prerequisites only.

## Further Notes

- The `restore` subcommand is the first opportunity to sweep orphan
  gen-stamped state dirs for a load-only user. Without it, anyone who
  only ever restores saved sessions (never overwrites them) accumulates
  orphans indefinitely.
- The deep-module split is deliberately conservative: `kitty::version`,
  `session::manifest`, and `session::synth` were extracted because each
  has a non-trivial behaviour (parsing, schema check + drift warning,
  identity allocation) that is independently meaningful. Other candidate
  modules (`session::list`, `session::rm`) are intentionally NOT
  extracted — they are CLI-side dispatchers thin enough that unit-testing
  them through the binary's stdout is sufficient.
- Cross-references to the canonical spec:
  - ADR 0001 — partial-capture degrade behaviour
  - ADR 0002 — kitty_version stamping
  - ADR 0003 — schema versioning policy
  - CONTEXT.md — domain terminology (synthetic window, skeleton,
    patcher, restore.sh, gen-stamped state dir, degraded window)
  - RUST_PORT_PLAN.md §4, §5.4, §5.7, §C.1, §C.3 — the relevant plan
    sections for each work item, with the caveat that the plan still
    uses `Window.uuid` and will need the rename pass.
