# PRD-10: Save-prompt overlay perceived-latency reduction

Status: measurement-first
Depends on: PRD-0 (`0002-observability-infrastructure.md`)

## Problem Statement

The kitty user's felt save latency is **not** `session::save()` wall
time alone. It is the elapsed time from "key pressed (Cmd+Shift+S)"
to "overlay closes, terminal returns to its session". That path runs
through `ksession-save-prompt.sh` — an fzf-driven overlay that
prompts for a session name, then invokes `ksession save`, then waits
for the save's completion lines on stdout, then closes the overlay.

Plan §9's perf target covers only the middle phase (`session::save()`).
The user feels:

1. Cmd+Shift+S keybind → kitty spawns the prompt overlay window
2. fzf cold-start; sessions dir scan to populate completions
3. User types or selects the session name (UI-bound, excluded)
4. Enter pressed → `ksession save` invoked
5. `session::save()` runs (covered by existing budget)
6. ksession stdout emits "ksession: saved …" lines
7. Save-prompt parses those lines and closes the overlay

Phases 1, 2, 6, and 7 are unmeasured. We don't know if any of them
dominate the perceived latency or if `session::save()` itself does.

## Solution

Two-phase PRD:

**Phase A — Measurement** (this PRD's primary deliverable):
Instrument `ksession-save-prompt.sh` with `EPOCHREALTIME`
timestamps written to the trace dir using PRD-0's JSONL format.
Each phase (overlay-spawn, fzf-startup, scan-sessions-dir,
invoke-ksession, parse-completion-lines, close-overlay) emits one
chrome-trace `X` event line. Run 30 invocations across the workload
matrix from PRD-1; produce `docs/findings/prompt-overlay-latency.md`
ranking phases by p50 contribution.

**Phase B — Optimisation** (sub-PRDs spawned from Phase A's
findings): targets the dominant phase identified in Phase A. Likely
candidates:

- If fzf cold-start dominates: investigate pre-warming or replacing
  fzf with a static name-input prompt for the common case.
- If sessions-dir scan dominates: cache the scan result or do it in
  background during overlay-spawn.
- If completion-line parsing dominates: replace `tail -f`-style
  loops with a single blocking read.
- If `session::save()` dominates: the existing save-side PRDs
  already attack this; PRD-10 surfaces nothing new.

Phase B PRDs are drafted **after** Phase A's findings; this PRD
ships Phase A only.

## User Stories

1. As a kitty user hitting Cmd+Shift+S, I want a perceived-latency
   metric (overlay-close-time) that I can track over time so that I
   know whether my save-prompt experience is getting faster.

2. As the maintainer reviewing whether prompt-overlay work is worth
   doing, I want `docs/findings/prompt-overlay-latency.md` to show
   the phase-by-phase breakdown so that I do not optimise a phase
   that's already <5% of wall time.

3. As a kitty user, I want the prompt overlay to use the same
   `KSESSION_TRACE_DIR` env var as save and restore tracing, so that
   one trace dir captures the entire interaction.

4. As the maintainer, I want `tests/perf_prompt_overlay_baseline.rs`
   (gated `#[ignore]`) to enforce that overlay close-time does not
   regress by > 30% from the established baseline, so that future
   prompt-script changes have a CI signal.

## Implementation Decisions

### Phase A: instrument `ksession-save-prompt.sh`

The script is short (~95 lines per `ksession-save-prompt.sh:1-95`
referenced in plan §A). Each meaningful phase wraps in a
`__trace_emit` helper (the same one PRD-0's `restore.sh` template
uses, factored out into a shared `scripts/ksession-trace-lib.sh`):

```bash
# Source the shared lib at the top of save-prompt.sh
source "$(dirname "$0")/ksession-trace-lib.sh"

__trace_start prompt.total
__trace_run prompt.overlay_spawn  '{}'  ...
__trace_run prompt.scan_sessions  '{}'  ...
__trace_run prompt.fzf            '{}'  ...
# user types — not instrumented (UI-bound)
__trace_run prompt.invoke_ksession '{}'  ...
__trace_run prompt.parse_completion '{}' ...
__trace_emit_end prompt.total
```

`KSESSION_TRACE_DIR` env var enables instrumentation; unset is
no-op (one variable test per call, sub-microsecond).

### Phase A: measurement protocol

- 30 invocations per workload from PRD-1's matrix (W1..W5).
- For each invocation, a wrapper test script captures the timestamp
  of Cmd+Shift+S simulation, the overlay-close timestamp (read from
  a kitty IPC notification or by polling for the overlay window's
  disappearance via `kitty @ ls`), and the trace dir produced.
- Findings doc structure mirrors PRD-1's:
  1. Methodology + hardware
  2. Per-workload phase breakdown (table)
  3. Cross-workload comparison
  4. Unmeasurable contributors (kitty internals between keybind
     receipt and prompt-overlay window appearing — `kitty @ launch`
     own cost)
  5. Candidate Phase B PRDs ranked by potential win

### Phase A: deliverable

- `scripts/ksession-trace-lib.sh` — shared bash helper used by
  `restore.sh` template (PRD-0), `ksession-save-prompt.sh` (this
  PRD), and any future bash-side instrumentation. Refactor from the
  inline helper in PRD-0.
- `scripts/ksession-save-prompt.sh` patches — additive only; the
  trace-off behaviour is byte-identical to today.
- `tests/perf_prompt_overlay_baseline.rs` — `#[ignore]` benchmark,
  asserts `prompt.total` p50 ≤ baseline × 130 / 100.
- `docs/findings/prompt-overlay-latency.md` — the analysis output.

### Phase B: spawned from Phase A

Phase B is a separate set of PRDs drafted after Phase A's data lands.
This PRD does not pre-commit to any Phase B work.

### Out of scope

- Replacing fzf. Even if Phase A shows fzf is the dominant cost,
  removing fzf is a separate design decision (loses fuzzy matching,
  preview, etc.).
- Pre-warming the prompt overlay (e.g., spawning fzf on every kitty
  startup). That's a Phase B candidate, not this PRD's scope.
- Instrumenting the user's keybind handler in kitty.conf. The
  keybind itself is a kitty action; we cannot wrap it.

## Testing Decisions

### Phase A tests

- **`prompt_overlay_instrumentation_smoke.sh`** — shell test under
  `bash 5`: set `KSESSION_TRACE_DIR=/tmp/t/`, run
  `ksession-save-prompt.sh < canned_session_name.txt`, assert
  `/tmp/t/prompt-<pid>.jsonl` exists and contains the expected phase
  spans in order.
- **`prompt_overlay_trace_off_zero_cost.sh`** — unset
  `KSESSION_TRACE_DIR`, run the script, assert no file is written
  under `~/.cache/ksession/traces/`.
- **`tests/perf_prompt_overlay_baseline.rs`** — the
  `#[ignore]`-gated regression test described above.

### Phase B tests

Defined by individual Phase B PRDs once drafted.

## Out of Scope

- Anything past Phase A's "produce findings" deliverable. Phase B
  PRDs are children of this PRD's findings; they are not this PRD.
- Instrumenting `ksession_save_prompt_dispatch.sh`
  (`scripts/ksession_save_prompt_dispatch.sh`). That script is a
  thin dispatcher; if it shows up as material in findings, Phase B
  can address it.

## Further Notes

- The "perceived-latency reduction" framing is deliberate: the user's
  goal in invoking this PRD is "save feels fast", not "session::save()
  is fast". Those two goals are correlated but not identical.
- Phase A is small (~30 LOC of bash patches plus a findings doc).
  The value is information; the optimisation work comes later.
- Cross-references:
  - PRD-0 — JSONL format, env var contract, `__trace_run` helper.
  - PRD-1 — measurement methodology template; workload matrix.
  - CONTEXT.md — Span, Trace.
