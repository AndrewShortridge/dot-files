# Handoff: ksession-rs Performance Integration Audit

**Date:** 2025-05-25
**Working directory:** `/home/andrew/.config/kitty`
**Rust project:** `/home/andrew/.config/kitty/scripts/ksession-rs/`
**Last commit:** `7264966` (Add cold vs. pre-warmed restore latency benchmark)

## What Was Done

A multi-agent audit of how many "real world" performance improvements from the ksession-rs Rust project are actually wired into the live kitty session picker. Six parallel investigation agents examined:

- Full ksession-rs src/ module map (14 modules, 50+ source files)
- Kitty config integration points (kitty.conf, session-picker.sh, save-prompt.sh)
- Per-PRD implementation status (PRD-0 through PRD-12)
- End-to-end wiring from keybinding → shell script → Rust binary → kitty RC

## Key Findings

### 13 of 17 performance features are live

**Fully wired and active:**
- Rust binary dispatch via `KSESSION_IMPL` env var in kitty.conf
- DCS socket transport (~50ms→15ms per RPC call)
- 12-connection pool with pre-spawn discovery (43% faster typical save)
- Chrome-trace observability (36+ spans at 5 levels, tree/chrome/stats subcommands)
- Parallel nvim buffer dumps (`buffer_unordered(4)`)
- Atomic filesystem ops (gen-stamped commit + orphan sweep)
- Scrollback capture (ANSI via `get_text`)
- Frecency scoring (zoxide-style, 6 call sites)
- Page cache pre-warming (background subshell before fzf)
- Restore latency baseline measured (p50=4.3ms)
- Tmux restore script generation (layout + pane recursion)

### 3 features implemented but NOT wired end-to-end

**1. PRD-8: Proactive nvim `:mksession!` cache (~200ms→30ms) — BIGGEST GAP**

All Rust code is written and tested. The cache-read fast path in `src/adapter/nvim.rs:127-148` checks `nvim_dirty` user-var timestamp against cache file mtime. But three install/config steps were never run:

- `make install-watcher install-nvim-plugin` (copies watcher.py + nvim_dirty.lua)
- Add `watcher ksession_kitty_watcher.py` to `kitty.conf`
- Restart kitty + nvim

Without these, no dirty timestamps are emitted, no cache files are written proactively, and the adapter always falls through to the expensive live `:mksession!` RPC.

**Files involved:**
- Source: `scripts/ksession-rs/scripts/ksession_kitty_watcher.py` (kitty watcher)
- Source: `scripts/ksession-rs/scripts/ksession_nvim_dirty.lua` (nvim plugin)
- Target: `~/.config/kitty/ksession_kitty_watcher.py`
- Target: `~/.local/share/nvim/site/plugin/ksession_nvim_dirty.lua`
- Rust: `src/adapter/nvim.rs` (cache-read path, lines 75-148)
- PRD: `docs/prds/0010-nvim-watcher-cache.md`

**2. Exit code 2 degradation badge (ADR-0001)**

Rust binary correctly exits with code 2 on degraded saves (`src/bin/ksession.rs:210-214`). But `ksession-save-prompt.sh` treats exit 2 as failure (shows "save failed") instead of showing "saved with degradations" badge. Both the main repo version and the ksession-rs/scripts version have this gap.

**3. PRD-12 Phase A: Save-prompt overlay tracing**

`scripts/ksession-rs/scripts/ksession-trace-lib.sh` is fully implemented with `__trace_run` and `__trace_emit` helpers. It's sourced by restore.sh templates but NOT by `ksession-save-prompt.sh`. Can't measure overlay startup latency without this.

### 4 features not yet implemented

| Feature | PRD | Est. Impact |
|---------|-----|-------------|
| ProcCache memoization | PRD-5 (`docs/prds/0007-proc-cache.md`) | ~5-10ms on 12-window saves |
| mimalloc allocator | PRD-7 (`docs/prds/0009-mimalloc.md`) | ~0.5-1.5ms (gated on measurement) |
| Restore-side optimizations | PRD-9..N (`docs/prds/0011-restore-optimizations-placeholder.md`) | TBD, blocked on PRD-1 findings |
| RPC batching | PRD-2 (no dedicated PRD file) | ~3x RPC overhead reduction |

## Architecture Reference

```
kitty.conf (env KSESSION_IMPL=$HOME/.local/bin/ksession)
    │
    ├── ctrl+space>s → session-picker.sh (fzf UI, frecency, page-cache prewarm)
    │     └── Dispatch: focus / spawn / ssh
    │
    └── ctrl+space>shift+s → ksession-save-prompt.sh
          └── $KSESSION_IMPL save <name>
                ├── Pre-spawn pool discovery (background thread)
                ├── KittyPool (12 DCS socket connections)
                ├── Adapter fanout (nvim RPC, tmux, less, raw, shell)
                ├── Conf patcher (skeleton + program state)
                ├── Atomic commit (gen-stamped rename)
                └── Chrome-trace telemetry (optional)
```

**Key files:**
- `/home/andrew/.config/kitty/kitty.conf` — env vars, keybindings, watcher directive (missing)
- `/home/andrew/.config/kitty/scripts/session-picker.sh` — main picker UI (27KB)
- `/home/andrew/.config/kitty/scripts/ksession-save-prompt.sh` — save dispatcher (6.9KB)
- `/home/andrew/.local/bin/ksession` — compiled Rust binary (2.2MB)
- `/home/andrew/.config/kitty/scripts/ksession-rs/` — Rust source project

**PRD index:** `scripts/ksession-rs/docs/prds/` (12 PRDs, 0001-0012)
**ADR index:** `scripts/ksession-rs/docs/adr/`
**Performance handoff:** `scripts/ksession-rs/ksession-performance-combined-handoff.md`
**Restore baseline:** `scripts/ksession-rs/docs/findings/restore-latency-baseline.md`

## Suggested Next Steps

1. **Wire PRD-8** — the single largest latency win (~170ms) with all code already written
2. **Fix exit code 2 handling** in save-prompt.sh — small shell change, UX improvement
3. **Wire PRD-12 Phase A** — source trace-lib.sh in save-prompt.sh for measurement
4. **Implement PRD-5** (ProcCache) or **PRD-7** (mimalloc) — smaller wins, straightforward

## Suggested Skills

- `/tdd` — for implementing remaining PRDs (ProcCache, mimalloc) with test-first approach
- `/diagnose` — if investigating why a specific optimization isn't delivering expected gains
- `/verify` — to confirm PRD-8 wiring works end-to-end after installation
- `/code-review` — to review the exit code 2 handling fix before committing
