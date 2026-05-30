# 11 — Autocmd Event Batching & Coalescing

## Priority: MEDIUM
## Inspired By: Zed's `ready_chunks(MAX_BATCH_SIZE)` in `project.rs`, `DebouncedDelay`, `EventCoalescer`

## Problem

The vault registers autocmds across 36 files. While `highlight_coordinator.lua` already
consolidates all highlight-related events into a single dispatch pipeline, the remaining
non-highlight BufEnter handlers (10 total) and TextChanged handlers still fire independently:

1. **Redundant condition checks:** Opening a markdown buffer triggers 10 independent BufEnter
   handlers that each separately check vault path, filetype, and buffer validity
2. **Uncoordinated TextChanged:** Three independent TextChanged pipelines exist —
   highlight_coordinator (200ms), embed live sync (500ms), and task_hierarchy (500ms) —
   each with their own timer and condition checks
3. **No `:bufdo` coalescing:** If 50 buffers open in sequence, each buffer's BufEnter triggers
   the full cascade × 50 with no adaptive batching

### Current Autocmd Density (Actual)

```
BufEnter events registered: 10 handlers
  - embed.lua:706           → ensure subscription; gc stale bufs; render if not visible (50ms defer)
  - breadcrumbs.lua:105     → update winbar breadcrumb (pattern=*.md, also BufWritePost)
  - breadcrumbs.lua:111     → clear winbar for non-vault buffers (all files, no pattern)
  - highlight_coordinator.lua:260 → full highlight render (30ms debounce, also BufWritePost)
  - frecency.lua:184        → record file access for frecency scoring (pattern=*.md, 5s access debounce)
  - pickers.lua:228         → auto-detect sticky project from buffer path (pattern=*.md, VaultStickyProject group)
  - task_notify.lua:228     → deferred overdue task check (config.task_notify.init_delay_ms)
  - linkdiag.lua:491        → clear diagnostics for non-vault buffers (all files, no pattern)
  - sidebar.lua:429         → track source buffer and schedule sidebar render (pattern=*.md, checks is_sidebar_active)
  - search/prompt.lua:116   → re-insert search prompt (buffer-specific to search float only)

TextChanged/TextChangedI events: 3 independent pipelines
  - highlight_coordinator.lua:271 → viewport-only highlight render (200ms debounce)
  - embed.lua:724 (TextChanged + InsertLeave, NOT TextChangedI) → self-referential embed live sync rerender (config.embed.sync.self_debounce_ms = 500ms)
  - task_hierarchy.lua:522 (TextChanged + TextChangedI) → task completion vtext rerender (config.hierarchy.debounce_ms = 500ms)

Other high-frequency events:
  - CursorMoved: 2 handlers (preview.lua:441 persistent/no once, footnotes.lua:558 once=true)
  - WinScrolled: 2 handlers (highlight_coordinator:282 200ms debounce, embed.lua:742 80ms lazy scroll debounce)
  - BufWritePost: 4 handlers (breadcrumbs:105, highlight_coordinator:260, init.lua:657 cache invalidation, autofile.lua:118)
  - BufReadPost: 3 handlers (engine.lua:556 one-shot URL cache prewarm 100ms defer, embed.lua:691 render 150ms defer, task_hierarchy.lua:516 500ms debounce)
```

### What's Already Coalesced

`highlight_coordinator.lua` provides **significant existing coordination**:
- Consolidates 5 highlight modules via generic `register()` API (wikilink_highlights p=30,
  tag_highlights p=40, inline_fields p=45, highlights p=50, autolink p=60) into a single dispatch pipeline
- Single debounce timer per buffer (30ms full / 200ms viewport)
- Shared `code_excl` closure built once per update cycle (avoids redundant treesitter parses)
- Priority-ordered execution via `register(name, fn, enabled_fn, priority)`
- Handles BufEnter, BufWritePost, TextChanged, TextChangedI, WinScrolled, VaultCacheInvalidate

Other existing patterns:
- `resource_cleanup.debounce(existing, delay_ms, callback)` (line 35) used throughout modules for per-buffer timers
- `resource_cleanup.on_buf_delete(group, callback, opts)` (line 64) consolidates BufDelete + BufWipeout pairs
- `init.lua:657` unified cache invalidation (BufWritePost + FileChangedShellPost + BufDelete + BufWipeout)
- `init.lua:669` FocusGained handler with 200ms debounce via `cleanup.debounce()`
- `engine.is_vault_path(path)` (engine.lua:441) — shared condition: `path ~= "" and vim.startswith(path, M.vault_path)`
- Embed system tracks render state (`state.embeds_visible[bufnr]`) to skip redundant renders
- Changedtick-based caching in `link_scan.lua` for code exclusion and frontmatter range
- 17 debounce_ms config values across modules (see config.lua), from 80ms (embed lazy scroll) to 5000ms (index persist)

### Remaining Impact

```
Open 1 markdown file:
  → 10 BufEnter handlers fire independently
  → Each performs its own vault path / filetype / buffer validity check
  → 3 of these schedule deferred work (embed 50ms, highlight 30ms, task_notify delayed)
  → Total: 10 condition checks + 3-5 timer setups
  → CPU: ~3-5ms of redundant setup overhead per buffer open

Run :bufdo on 50 files:
  → 500 handler invocations (10 × 50)
  → 500 condition checks (mostly redundant)
  → Highlight coordinator debounces well (last-wins per buffer)
  → But embed, breadcrumbs, frecency, task_notify, sidebar each fire 50 times
  → ~100-200ms overhead (reduced from original estimate due to existing debouncing)
```

## Proposed Solution

### 1. Event Coalescer Module

Create `lua/andrew/vault/event_coalescer.lua`:

```lua
--- Batches and coalesces autocmd events to reduce redundant processing.
--- Inspired by Zed's ready_chunks(128), DebouncedDelay, and EventCoalescer patterns.

local M = {}

--- @class EventCoalescer
--- @field _pending table<number, table> Pending events by bufnr
--- @field _timer uv_timer_t|nil Coalescing timer
--- @field _delay_ms number Coalescing window (ms)
--- @field _handler function Batch handler callback
--- @field _max_batch number Max events before forced flush

--- Create a new event coalescer.
--- @param opts { delay_ms: number, max_batch: number, handler: function }
--- @return EventCoalescer
function M.new(opts)
  return {
    _pending = {},
    _timer = nil,
    _delay_ms = opts.delay_ms or 16,  -- ~1 frame
    _max_batch = opts.max_batch or 32,
    _handler = opts.handler,
    _pending_count = 0,
  }
end

--- Queue an event for batched processing.
--- @param coalescer EventCoalescer
--- @param bufnr number
--- @param event_data table Additional event context
function M.queue(coalescer, bufnr, event_data)
  -- Coalesce: latest event per buffer wins
  coalescer._pending[bufnr] = event_data or {}

  -- Count unique buffers pending
  coalescer._pending_count = vim.tbl_count(coalescer._pending)

  -- Force flush if batch limit reached
  if coalescer._pending_count >= coalescer._max_batch then
    M.flush(coalescer)
    return
  end

  -- Reset coalescing timer
  if coalescer._timer then
    coalescer._timer:stop()
  else
    coalescer._timer = vim.uv.new_timer()
  end

  coalescer._timer:start(coalescer._delay_ms, 0, vim.schedule_wrap(function()
    M.flush(coalescer)
  end))
end

--- Flush all pending events as a single batch.
--- @param coalescer EventCoalescer
function M.flush(coalescer)
  if coalescer._timer then
    coalescer._timer:stop()
  end

  local batch = coalescer._pending
  coalescer._pending = {}
  coalescer._pending_count = 0

  if next(batch) then
    coalescer._handler(batch)
  end
end

--- Stop the coalescer, flush pending, close timer.
--- @param coalescer EventCoalescer
function M.close(coalescer)
  M.flush(coalescer)
  if coalescer._timer then
    coalescer._timer:stop()
    coalescer._timer:close()
    coalescer._timer = nil
  end
end

return M
```

### 2. BufEnter Consolidation

The 10 BufEnter handlers break into three categories:

**Category A — Already coordinated (no change needed):**
- `highlight_coordinator.lua:260` — already batches all highlight modules (30ms debounce)
- `search/prompt.lua:116` — only fires for search float buffer (not vault-wide)

**Category B — Can be consolidated into a single dispatcher:**
- `embed.lua:706` — render embeds (50ms defer)
- `breadcrumbs.lua:105,111` — update/clear winbar
- `task_notify.lua:228` — overdue task check (delayed)
- `frecency.lua:184` — record file access (5s per-file debounce)
- `linkdiag.lua:491` — clear non-vault diagnostics
- `sidebar.lua:429` — track source buffer and schedule sidebar render

**Category C — Domain-specific, keep separate:**
- `pickers.lua:228` — sticky project detection (fast, checks Projects/ prefix only)

Consolidate Category B into a single BufEnter handler with shared context:

```lua
local event_coalescer = require("andrew.vault.event_coalescer")

local _buf_enter_coalescer = event_coalescer.new({
  delay_ms = 16,  -- Coalesce within 1 frame
  max_batch = 32,
  handler = function(batch)
    local vault = engine.vault_path  -- Note: vault_path is a string field, not a function
    for bufnr, data in pairs(batch) do
      if not vim.api.nvim_buf_is_valid(bufnr) then goto continue end
      local ft = vim.bo[bufnr].filetype
      local file = vim.api.nvim_buf_get_name(bufnr)
      local is_vault_md = ft == "markdown" and vault and vim.startswith(file, vault)

      -- Context computed once, shared across all handlers
      local ctx = { bufnr = bufnr, vault = vault, file = file, is_vault_md = is_vault_md }

      -- Always: clear non-vault diagnostics
      if not is_vault_md then
        linkdiag.clear_for_buffer(ctx)
        breadcrumbs.clear_winbar(ctx)
        goto continue
      end

      -- Vault markdown handlers (shared context, no redundant checks)
      breadcrumbs.update_winbar(ctx)
      embed.ensure_rendered(ctx)
      frecency.record_access(ctx)
      task_notify.check_overdue(ctx)
      sidebar.on_buf_change(ctx)

      ::continue::
    end
  end,
})

-- Single BufEnter autocmd replaces 7 independent ones:
vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  pattern = "*.md",
  callback = function(ev)
    _buf_enter_coalescer:queue(ev.buf, { event = "BufEnter" })
  end,
})
```

### 3. TextChanged Consolidation

The three TextChanged pipelines have different debounce requirements, so full
consolidation isn't appropriate. Instead, share the condition check:

```lua
-- Single TextChanged autocmd dispatches to all three pipelines
vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
  group = group,
  pattern = "*.md",
  callback = function(ev)
    -- Shared condition check (computed once)
    local bufnr = ev.buf
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if vim.bo[bufnr].filetype ~= "markdown" then return end

    local vault = engine.vault_path  -- string field, not a function
    if not vault then return end
    local file = vim.api.nvim_buf_get_name(bufnr)
    if not vim.startswith(file, vault) then return end

    -- Dispatch to each pipeline (each has own debounce timer)
    highlight_coordinator.schedule(bufnr, { full = false })  -- 200ms
    embed.on_text_changed(bufnr)                              -- 500ms (if live sync)
    task_hierarchy.schedule_render(bufnr)                     -- debounced
  end,
})
```

### 4. Bufdo/Batch Operation Detection

```lua
--- Detect rapid buffer switching (e.g., :bufdo) and increase coalescing window.
--- Inspired by Zed's EventCoalescer time-window pattern (20s for telemetry,
--- adapted to 200ms for UI events).
local _last_buf_enter_time = 0
local _rapid_switch_count = 0

local function adaptive_delay()
  local now = vim.uv.now()
  if now - _last_buf_enter_time < 50 then  -- <50ms between switches
    _rapid_switch_count = _rapid_switch_count + 1
  else
    _rapid_switch_count = 0
  end
  _last_buf_enter_time = now

  -- During rapid switching, increase coalescing window
  if _rapid_switch_count > 3 then
    return 200  -- Wait 200ms for :bufdo to finish
  end
  return 16     -- Normal: 1 frame
end
```

### 5. Shared Condition Checks

The consolidated approach eliminates redundant per-handler condition checks:

```lua
-- BEFORE: Each of 10 handlers independently checks:
--   vim.bo[bufnr].filetype ~= "markdown"
--   engine.is_vault_path(path)  -- engine.lua:441, checks path ~= "" and vim.startswith(path, M.vault_path)
--   vim.api.nvim_buf_get_name(bufnr)
--   vim.startswith(file, vault)
-- = 10 × 4 = 40 condition evaluations per BufEnter

-- AFTER: Coalescer batch handler checks once per buffer:
-- = 1 × 4 = 4 condition evaluations per BufEnter
-- Validated context passed to all downstream handlers
```

## Configuration

```lua
M.events = {
  buf_enter_coalesce_ms = 16,       -- BufEnter coalescing window
  text_changed_coalesce_ms = 50,    -- TextChanged coalescing window (unused if pipelines keep own debounce)
  rapid_switch_threshold_ms = 50,   -- Detect :bufdo-style operations
  rapid_switch_delay_ms = 200,      -- Extended delay during rapid switching
  max_batch_size = 32,              -- Force flush at this many pending events
}
```

## Zed Reference

### Pattern 1: `ready_chunks` — Stream Batching (project.rs:2691,2721)

```rust
// crates/project/src/project.rs:2691
const MAX_BATCH_SIZE: usize = 128;
// crates/project/src/project.rs:2721
let mut changes = rx.ready_chunks(MAX_BATCH_SIZE);
while let Some(batch) = changes.next().await {
    // Accumulate operations by buffer_id in HashMap
    // Flush on encountering LanguageServerUpdate or Resync
    // Send batched operations via proto::UpdateBuffer
}
```

Also used for:
- Search results: `project_search.rs:312` — `search.ready_chunks(1024)` (1024 items, not 64)
- Matching buffers: `project.rs:3814` — `matching_buffers_rx.ready_chunks(64)` (64 buffers)
- Workspace serialization: `workspace.rs:5329` — `items_rx.ready_chunks(200)` (200 items)
- Edit agent: `edit_agent.rs:331` — `edits.ready_chunks(32)` (32 edits)
- Semantic index embeddings use `chunks_timeout` instead (see Pattern 4)

### Pattern 2: `DebouncedDelay` — Cancel-and-Restart (crates/project/src/debounced_delay.rs)

```rust
// debounced_delay.rs:26-53
pub fn fire_new<F>(&mut self, delay: Duration, cx: &mut Context<E>, func: F) {
    // Cancel previous pending operation via oneshot channel
    if let Some(channel) = self.cancel_channel.take() {
        _ = channel.send(());
    }
    // Spawn new task: select_biased! { timer vs cancel }
    // On expiration: execute callback
}
```

Used for git diff recalculation:
- `project.rs:197` — `buffers_needing_diff: HashSet<WeakEntity<Buffer>>`
- `project.rs:198` — `git_diff_debouncer: DebouncedDelay<Self>`
- `project.rs:3127-3160` — `request_buffer_diff_recalculation()`: inserts buffer into HashSet,
  fires debouncer with `const MIN_DELAY: u64 = 50` (line 3152), configurable via `git.gutter_debounce`
- `project.rs:3162-3190` — `recalculate_buffer_diffs()`: drains all accumulated buffers in one batch

### Pattern 3: `EventCoalescer` — Time-Window Coalescing (crates/client/src/telemetry/event_coalescer.rs)

```rust
// event_coalescer.rs:6
const COALESCE_TIMEOUT: time::Duration = time::Duration::from_secs(20);
// event_coalescer.rs:16-19 — struct with clock + Optional<PeriodData> state
// event_coalescer.rs:21-67 — log_event() merges events into time-windowed periods
// Returns (start, end, environment) when period closes (timeout exceeded or env changes)
```

### Pattern 4: `chunks_timeout` — Hybrid Size/Time Batching (semantic_index)

```rust
// crates/semantic_index/src/embedding_index.rs:286
let mut chunked_file_batches = pin!(
    chunked_files.chunks_timeout(512, Duration::from_secs(2))
);
// Emits batch when 512 items collected OR 2 second timeout — whichever first

// crates/semantic_index/src/summary_index.rs:617
let mut summaries = pin!(summaries.chunks_timeout(4096, Duration::from_secs(2)));
// Summary persistence: 4096 items max, 2s timeout
// Both use futures_batch::ChunksTimeoutStreamExt trait
```

### Pattern 5: Buffer Edit Coalescing (crates/language/src/buffer.rs:4953)

```rust
// buffer.rs:4953-4979 — contiguous_ranges(values, max_len) → Iterator<Item = Range<u32>>
// Merges consecutive u32 values into contiguous ranges, bounded by max_len
// Used at:
//   buffer.rs:1647 — autoindent computation, max_rows_between_yields = 100
//   buffer.rs:2901 — indent size suggestions, max_len = 10
```

### Key Insight: Per-Module Batching

Zed has **no centralized GPUI framework batching layer**. Each module implements its
own batching strategy with appropriate batch sizes and timeouts. This validates our
approach of keeping `highlight_coordinator` separate and adding coalescing at the
BufEnter dispatch level rather than building a monolithic event bus.

## Expected Impact

| Metric | Before | After |
|--------|--------|-------|
| BufEnter handler invocations | 10 per buffer | 1 coalesced batch → dispatches to ~6 handlers |
| BufEnter condition checks per buffer | 10 × 4 = 40 | 1 × 4 = 4 (shared context) |
| :bufdo 50 files overhead | ~500 handler calls | ~50 batched calls (adaptive delay) |
| TextChanged condition checks | 3 independent | 1 shared (each pipeline keeps own debounce) |
| Timer objects for TextChanged | 3 per event type | 3 per event type (unchanged — each needs own delay) |

**Estimated improvement:** 40-60% reduction in autocmd overhead for buffer operations.
(Lower than original 60-80% estimate because highlight_coordinator already handles the
heaviest coalescing. Remaining gains come from BufEnter consolidation and :bufdo detection.)

## Testing Strategy

1. Open markdown file, count handler invocations (should be 1 coalesced BufEnter dispatch)
2. Run `:bufdo` on 50 markdown files, verify adaptive delay activates (200ms window)
3. Verify all handlers still fire correctly: breadcrumbs updates, embeds render, frecency records
4. Type rapidly, verify TextChanged condition check runs once (not 3 times) per event
5. Close Neovim — verify coalescer timers properly cleaned up
6. Profile: `:lua local t = vim.uv.hrtime(); <open file>; print((vim.uv.hrtime()-t)/1e6)`
7. Verify highlight_coordinator still works independently (no regression)

## Dependencies

- Coordinate with `highlight_coordinator.lua` — it keeps its own BufEnter/TextChanged
  handlers and debouncing. The coalescer handles the remaining non-highlight handlers.
- Benefits from doc 03 (timer leak fixes) — coalescer uses timers
- `resource_cleanup.debounce()` (line 35) already provides per-buffer timer management

## Implementation Notes

### Modules That Need Refactoring

To consolidate BufEnter, these modules need their autocmd callbacks extracted into
callable functions that accept a shared context:

| Module | Current Autocmd | Extract To |
|--------|----------------|------------|
| `embed.lua:706` | Inline callback with `vim.defer_fn`, gc_stale_buffers, ensure_subscription | `M.ensure_rendered(ctx)` |
| `breadcrumbs.lua:105,111` | Two separate autocmds (105 also fires on BufWritePost) | `M.update_winbar(ctx)`, `M.clear_winbar(ctx)` |
| `frecency.lua:184` | Inline callback (has internal 5s access debounce) | `M.record_access(ctx)` |
| `task_notify.lua:228` | Inline callback with `vim.defer_fn(config.task_notify.init_delay_ms)` | `M.check_overdue(ctx)` |
| `linkdiag.lua:491` | Inline callback (no pattern — fires for all files) | `M.clear_for_buffer(ctx)` |
| `sidebar.lua:429` | Calls `on_buf_change` (line 403), guards with `is_sidebar_active()` | `M.on_buf_change(ctx)` |

### Modules To Leave Alone

| Module | Reason |
|--------|--------|
| `highlight_coordinator.lua` | Already fully coordinated with its own debounce pipeline (5 modules, priority-ordered via generic `register()` API) |
| `search/prompt.lua` | Only fires for search float buffer (buffer-specific, not vault-wide) |
| `pickers.lua` | Checks Projects/ prefix only (VaultStickyProject group), domain-specific |
| `preview.lua:441` CursorMoved | Persistent handler (NOT once=true), scoped to parent buffer, closes preview float |
| `footnotes.lua:558` CursorMoved | once=true, deletes own augroup on fire |
| `autosave.lua` | Uses BufLeave/WinLeave/FocusLost (not BufEnter), config.autosave.debounce_ms = 1000 |

## Risk Assessment

- **Low-Medium risk:** Narrower scope than originally planned (highlight_coordinator
  already handles the hardest part)
- **Mitigation:** Implement coalescer as opt-in; migrate modules one at a time
- **Rollback:** Each module can revert to direct autocmd registration independently
- **Key invariant:** Coalesced behavior must be identical to sequential (order-independent handlers)
- **Watch out:** `embed.lua` BufEnter uses `vim.defer_fn(50)` — the coalescer's 16ms
  window must complete before embed's 50ms defer, or embed may fire before coalescer flushes
