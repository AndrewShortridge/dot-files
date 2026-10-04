# PRD-8: Proactive nvim `:mksession!` cache via kitty `launch --watcher`

Status: ready-for-agent
Depends on: PRD-0 (`0002-observability-infrastructure.md`)
See also: ADR 0006 (`0006-reopen-nvim-watcher-via-kitty-launch-watcher.md`)

## Problem Statement

`adapter::nvim::capture` issues `:mksession!` synchronously over
msgpack-RPC to each live nvim instance during save. The call typically
costs ~200 ms — nvim has to walk every buffer, window, tab, option,
mark, fold, and emit the entire restore script. This is the
documented floor in plan §C.9 ("Floor remains nvim mksession ~200 ms.
Total save can't drop below ~125 ms on the typical case without
either (a) running mksession before the save (live cache via watcher
— see C.5), or (b) accepting stale nvim state.")

Plan §C.5 evaluated a "watcher / kitten daemon" approach and rejected
it on grounds of "+300 Python LOC" plus race-condition risk. ADR 0006
records why we are reopening that decision: kitty's native
`launch --watcher` framework (kitty ≥ 0.28) eliminates the daemon-loop
scaffolding that drove the 300-LOC estimate. We write callback
functions, not a process.

## Solution

Three coordinated components — kitty watcher + nvim autocmd + Rust
cache-read path — that together let the save path read a
pre-captured `mksession.vim` file instead of invoking `:mksession!`
synchronously.

1. **`scripts/ksession_kitty_watcher.py`** (~50 LOC): a kitty watcher
   module installed via `watcher` in `kitty.conf`. Implements:
   - `on_set_user_var(boss, window, data)` — fires when nvim emits
     OSC 1337 `SetUserVar nvim_dirty=<ts>`. The watcher schedules a
     debounced `:mksession!` invocation on the affected nvim window
     via `boss.call_remote_control([...])` or directly via its
     msgpack socket.
   - `on_cmd_startstop(boss, window, data)` — fires on OSC 133 A/D
     (shell-cmd start/stop). Used to trigger pre-emptive capture
     during natural pauses (cmd just finished).
2. **`scripts/ksession_nvim_dirty.lua`** (~15 LOC): an nvim plugin
   snippet (installed via `~/.local/share/nvim/site/lua/` per existing
   Makefile pattern) that registers autocmds on `BufWritePost`,
   `CursorHold` (idle-timer), `VimLeavePre`, and `BufEnter`. Each
   autocmd emits an OSC 1337 `SetUserVar nvim_dirty=<unix_ms>` to
   kitty.
3. **`src/adapter/nvim.rs` cache-read path**: `capture()` checks for
   `<state_dir>/.cache/nvim-<window_id>.vim` with mtime newer than
   the most recent `nvim_dirty` user-var value (read via
   `kitty @ ls`). If fresh, read it; if stale or missing, fall back
   to live `:mksession!`. The cache file is written by the watcher
   (via nvim msgpack-RPC) into a known path; the Rust adapter just
   reads it.

PRD-0's `adapter.nvim.capture` histogram is the success criterion:
cache-hit p50 should be ≤30 ms (single file read + small validation);
cache-miss p50 falls back to the existing ~200 ms.

## User Stories

1. As a kitty user who has been editing in nvim and hits Cmd+Shift+S
   to save the session, I want the nvim portion of save to read a
   pre-captured session file at ~0 ms instead of paying the live
   `:mksession!` ~200 ms cost, so that save feels instant.

2. As a kitty user finishing a shell command in a non-nvim window and
   immediately saving the session, I want the kitty watcher's
   `on_cmd_startstop` trigger to have refreshed the nvim cache during
   the natural pause after the command, so that the save still hits
   cache.

3. As a kitty user whose cache is stale (nvim_dirty user var newer
   than the cache file's mtime), I want the save to transparently
   fall back to live `:mksession!`, so that staleness never produces
   an incorrect restore.

4. As a kitty user whose kitty version is < 0.28 (no watcher
   support), I want the cache-read path to no-op gracefully and save
   to behave exactly as today, so that the feature doesn't break
   older setups.

5. As the maintainer, I want PRD-0's histogram to show two distinct
   peaks for `adapter.nvim.capture` — a fast cache-hit peak and a
   slow cache-miss peak — so that the cache-hit-rate is observable
   from data.

6. As a kitty user, I want the cache files to live under the
   session's gen-stamped state dir so that they participate in the
   existing orphan-sweep lifecycle and don't accumulate forever.

## Implementation Decisions

### Component 1: kitty watcher (`scripts/ksession_kitty_watcher.py`)

```python
# Installed at ~/.config/kitty/ksession_kitty_watcher.py and referenced
# via `watcher ksession_kitty_watcher.py` in kitty.conf.

from typing import Any
import time
import threading

# debounce state per window
_debounce: dict[int, float] = {}
_DEBOUNCE_S = 0.5

def _maybe_capture(boss: Any, window: Any) -> None:
    """Run :mksession! into the cache path for a given window."""
    nvim_sock = window.user_vars.get('nvim_socket')  # set by Component 2
    cache_path = window.user_vars.get('ksession_cache_path')
    if not (nvim_sock and cache_path):
        return
    # Connect to nvim, run mksession! via msgpack-RPC.
    # Implementation: spawn a thread, never block the kitty UI thread.
    threading.Thread(
        target=_run_mksession,
        args=(nvim_sock, cache_path),
        daemon=True,
    ).start()

def _run_mksession(sock: str, cache: str) -> None:
    # ~20 LOC of msgpack-RPC: connect, send nvim_command(":mksession! "+cache),
    # read response, close. Errors logged to a kitty-managed file; never raised
    # to the watcher thread (which would not be caught).
    ...

def on_set_user_var(boss: Any, window: Any, data: dict[str, Any]) -> None:
    if data.get('key') != 'nvim_dirty':
        return
    now = time.monotonic()
    last = _debounce.get(window.id, 0)
    if now - last < _DEBOUNCE_S:
        return
    _debounce[window.id] = now
    _maybe_capture(boss, window)

def on_cmd_startstop(boss: Any, window: Any, data: dict[str, Any]) -> None:
    # is_start=False means a cmd just finished — likely a natural pause.
    if data.get('is_start'):
        return
    # Trigger refresh on any nvim window in the same OS window.
    for w in boss.all_windows:
        if w.user_vars.get('nvim_socket'):
            _maybe_capture(boss, w)
```

Key behaviours:

- **Debounce**: 500 ms per window. Prevents `:mksession!` from
  thrashing under rapid autocmds (e.g., `CursorHold` after every
  movement).
- **Non-blocking**: Watcher hooks run on kitty's UI thread; the
  msgpack-RPC call to nvim spawns a thread. The watcher hook itself
  returns in <1 ms.
- **Failures are silent**: any error in `_run_mksession` is logged to
  a known file (`~/.cache/ksession/watcher.log`) but never raised. A
  failed proactive capture just means the next save will pay the
  live `:mksession!` cost (i.e., today's behaviour).

### Component 2: nvim plugin (`scripts/ksession_nvim_dirty.lua`)

```lua
-- Installed via Makefile to ~/.local/share/nvim/site/plugin/
-- ksession_nvim_dirty.lua (auto-loaded on nvim startup).

local function emit_dirty()
    -- OSC 1337 SetUserVar to kitty.
    local ts = vim.uv.hrtime() // 1000000  -- ms
    io.stdout:write(string.format("\27]1337;SetUserVar=nvim_dirty=%s\27\\",
        vim.fn.system("printf '%d' " .. ts .. " | base64 -w0")))
end

-- Register the nvim socket path with kitty so the watcher can find it.
local function register_socket()
    local sock = vim.v.servername
    if sock and sock ~= "" then
        io.stdout:write(string.format("\27]1337;SetUserVar=nvim_socket=%s\27\\",
            vim.fn.system("printf %s '" .. sock .. "' | base64 -w0")))
    end
end

vim.api.nvim_create_autocmd("VimEnter", { callback = register_socket })
vim.api.nvim_create_autocmd(
    {"BufWritePost", "CursorHold", "VimLeavePre", "BufEnter"},
    { callback = emit_dirty }
)
```

The autocmd emits `nvim_dirty=<unix_ms>` on the events most likely to
correlate with "user state changed". The watcher debounces; the lua
side emits cheaply.

### Component 3: Rust cache-read path

`src/adapter/nvim.rs` `capture()` is rewritten:

```rust
pub async fn capture(ctx: &WindowCtx) -> Result<Program, AdapterError> {
    let _s = perf::span!(Level::Info, "adapter.nvim.capture", win = ctx.kitty_window.id);

    let cache_path = ctx.state_dir.join(format!(".cache/nvim-{}.vim", ctx.kitty_window.id));
    let dirty_ts_ms = ctx.kitty_window.user_vars.get("nvim_dirty")
        .and_then(|s| s.parse::<u64>().ok());

    if let (Ok(meta), Some(dirty_ts)) = (fs::metadata(&cache_path), dirty_ts_ms) {
        let mtime_ms = meta.modified()?.duration_since(UNIX_EPOCH)?.as_millis() as u64;
        if mtime_ms >= dirty_ts {
            let _s = perf::span!(Level::Debug, "adapter.nvim.capture.cache_hit");
            return read_cached(&cache_path).await;
        }
    }

    let _s = perf::span!(Level::Debug, "adapter.nvim.capture.cache_miss");
    // Fall back to live mksession (existing code path unchanged).
    capture_live(ctx).await
}
```

The cache-hit vs cache-miss span distinction in PRD-0's histogram is
the primary observability output. Cache-hit rate over time is a
first-class metric.

### Staleness model

Cache is fresh iff `mtime(cache_file) ≥ value(nvim_dirty user var)`.
Both are millisecond timestamps. If the watcher debounced and
suppressed a capture, the cache mtime stays older than nvim_dirty —
which is detected as stale, and we fall back to live mksession. That
is the **correct** outcome: a suppressed proactive capture means we
should not trust the cache.

### Lifecycle of cache files

- **Location**: `<state_dir>/.cache/nvim-<window_id>.vim`. The
  `.cache/` subdirectory of the gen-stamped state dir.
- **Created by**: the watcher's `_run_mksession` (writes to the path
  specified by the `ksession_cache_path` user-var, which is set by
  ksession-rs at save start).
- **Cleaned up by**: existing orphan-sweep in `fsx::sweep_orphans`
  (the entire gen-stamped state dir is swept atomically; cache
  subdir goes with it).

There is a chicken-and-egg setup: the cache path is per-save (lives
inside the gen-stamped state dir), but the watcher needs to know it
before save starts. Resolution: on save start, Rust sets
`ksession_cache_path` user-var on every nvim-containing window via
`kitty @ set-user-vars`. The watcher reads it from `window.user_vars`
on each `on_set_user_var` trigger.

**But**: the very first save against a never-saved session has no
gen-stamped state dir yet. For that first save, cache-miss falls
through to live mksession (current behaviour). The cache populates
during/after that first save; subsequent saves benefit.

### Installation surface

- `Makefile` adds two install targets:
  ```make
  install-watcher: $(HOME)/.config/kitty/ksession_kitty_watcher.py
      @echo "Add 'watcher ksession_kitty_watcher.py' to kitty.conf"

  install-nvim-plugin: $(HOME)/.local/share/nvim/site/plugin/ksession_nvim_dirty.lua
      @echo "Plugin auto-loads on next nvim start"
  ```
- README documents the kitty.conf `watcher` line and the kitty ≥ 0.28
  requirement.
- Both components no-op gracefully when not installed; ksession-rs
  detects "no watcher" by observing that `nvim_dirty` user-var never
  appears, falls back to live mksession every save (current
  behaviour).

### Out of scope

- Recreating the OSC 1337 emit path for other programs (less, tmux).
  Only nvim has a `:mksession!`-shaped expensive synchronous call.
- A doctor subcommand that verifies the watcher is installed and the
  nvim plugin is loaded. Worth adding later; not in scope here.
- Cross-machine cache sharing. The cache is per-save-on-this-machine.
- Cache compression. Mksession output is small text (~10 KiB per nvim
  instance with normal buffer counts); compression adds latency.

## Testing Decisions

### Modules to test directly

- **`adapter::nvim::is_cache_fresh`** — unit test: golden table of
  `(cache_mtime_ms, dirty_user_var, expected)` covering: mtime ahead
  (fresh), mtime equal (fresh, edge case), mtime behind (stale),
  no user_var present (treat as live-required), no cache file
  (live-required).
- **Lua plugin smoke** — headless nvim test: load
  `ksession_nvim_dirty.lua`, trigger a `BufWritePost`, capture
  stdout, assert it contains the OSC 1337 sequence with a parseable
  base64 timestamp.
- **Watcher debounce logic** — unit-testable in Python: simulate two
  `on_set_user_var` calls within 100 ms, assert only one
  `_maybe_capture` runs.

### End-to-end tests to add

- **`nvim_cache_hit_smoke.rs`** — fixture: pre-populate
  `<state_dir>/.cache/nvim-12.vim` with valid mksession content, set
  the `nvim_dirty` user-var to a timestamp older than the file's
  mtime; run `adapter::nvim::capture`; assert it returns the cached
  content and the span emits `cache_hit`.
- **`nvim_cache_stale_falls_back.rs`** — same fixture but
  `nvim_dirty` newer than mtime; assert capture falls back to live
  `:mksession!`, span emits `cache_miss`, result is from nvim not
  cache.
- **`nvim_watcher_kitty_028_required.rs`** — set the simulated kitty
  version to 0.27 via the test kitty harness; assert ksession-rs
  detects no watcher support and uses live mksession always; emits
  no warnings (silent fall-through).
- **`nvim_cache_perf_budget.rs`** — `#[ignore]` benchmark; warm the
  cache (one save) then 30 iterations; assert
  `adapter.nvim.capture` cache-hit p50 ≤ 30 ms (vs current ~200 ms
  live).

## Out of Scope

- Replacing `:mksession!` entirely with native msgpack-RPC queries.
  That is the "Option D" considered in grilling but kept as a
  follow-up; this PRD ships Option A (kitty watcher) only.
- Caching at any level above the session-state-dir granularity.
- Telling the user when their kitty is too old. The README documents
  the requirement; silent fall-through is the runtime behaviour.

## Further Notes

- This PRD reverses §C.5's explicit SKIP. ADR 0006 records the
  justification.
- The two-landing decomposition (Option B first, then Option A)
  proposed in early grilling was rejected: the user chose to skip B
  and go straight to A. PRD-8 is therefore one landing covering all
  three components.
- Cache file format: literal mksession output (Vim script). Same
  format `:mksession!` produces today. No new format to maintain.
- The 500 ms debounce constant is a starting value; tuning happens
  via PRD-0 measurements once the system is live. If cache-hit rate
  is low under realistic workload, debounce shortens; if mksession
  CPU dominates idle, debounce lengthens. Bisect via
  `KSESSION_WATCHER_DEBOUNCE_MS` env var (read by the watcher at
  startup).
- Cross-references:
  - ADR 0006 — design decision rationale.
  - Plan §C.5 — original SKIP verdict (now superseded).
  - Plan §C.2 — OSC 1337 user-var hook (the substrate this PRD
    extends from "save state at shell prompt" to "save state at any
    nvim event").
  - PRD-0 — `adapter.nvim.capture.cache_hit` / `.cache_miss` spans;
    cache-hit rate is a histogram across these.
