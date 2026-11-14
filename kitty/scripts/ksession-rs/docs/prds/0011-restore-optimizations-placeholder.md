# PRD-9..N: Restore-side optimizations (placeholder)

Status: placeholder — depends on PRD-1 findings
Depends on: PRD-1 (`0003-restore-measurement-deep-dive.md`)

## Problem Statement

Restore-side latency is presently unmeasured. PRD-1 ships the
measurement methodology and produces `docs/findings/restore-latency-baseline.md`,
which ranks restore-side holdups by p50 contribution and proposes
candidate optimisation PRDs.

This file exists as a numbered placeholder so the PRD batch sequence
in the planning grilling has a reserved slot. The actual scope of
PRD-9 through PRD-N is unknowable until PRD-1's findings exist.

## What this placeholder will become

Once PRD-1 lands and its findings doc is committed, this PRD splits
into one PRD per top-5 actionable contributor. Candidates we expect
(based on grilling-time guesses, **not yet validated**):

- **Candidate A**: Parallelise per-tmux-window restore inside one
  `restore.sh`. The generated script currently runs every
  `new-window`/`split-window`/`new-session` command serially via bash.
  Independent windows in different sessions could fan out as bash
  background jobs. Wins scale with tmux session count.
- **Candidate B**: Parallelise per-buffer reload inside
  `ksession_restore.lua`. Each modified buffer is currently sourced
  one at a time; nvim's API allows concurrent `nvim_buf_set_lines`
  on different buffers.
- **Candidate C**: Skip orphan-sweep in `restore.dispatch` when the
  trace dir count is below a threshold. The sweep is bounded but
  walks the sessions dir on every restore.
- **Candidate D**: Pre-warm the nvim restore plugin via a kitty
  watcher hook on window create, so `ksession_restore.lua`'s startup
  cost overlaps with kitty's launch-line execution rather than
  serialising afterwards.

Each candidate becomes a PRD only if PRD-1's findings rank it in the
measurable-and-impactful set.

## What this placeholder does NOT do

- Commit to any of the candidates above. They are guesses.
- Reserve a specific span name or instrumentation point. PRD-1's
  findings will determine what gets measured.
- Promise a target latency number. PRD-1 establishes the baseline;
  individual PRDs set their own targets relative to it.

## Process

1. PRD-1 lands; `docs/findings/restore-latency-baseline.md` is
   committed.
2. This placeholder file is deleted.
3. New PRDs are created (`0012-...`, `0013-...`, etc.) — one per
   top-N actionable contributor identified in the findings.
4. Each new PRD references the findings doc as motivation and cites
   the specific span name + measured p50 contribution.

## Cross-references

- PRD-1 — establishes baseline; this placeholder cannot become real
  PRDs without it.
- PRD-0 — provides the measurement infrastructure both PRD-1 and
  the eventual PRD-9..N use for validation.
