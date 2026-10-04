# Handoff: Combined Performance Optimization Techniques for ksession-rs

**Date:** 2026-05-25
**Project:** ksession-rs (kitty session save/restore)
**Context:** Performance optimization via combined techniques - ready for PRD breakdown

---

## Executive Summary

This document outlines a comprehensive performance optimization strategy combining six techniques that work together to dramatically reduce save/restore latency. Each technique is proposed as a separate PRD for incremental implementation.

**Current baseline:** 240ms save, 285ms restore
**Target with all techniques:** <10ms for cached/incremental saves, ~50ms for cold saves

---

## The Six Techniques

### 1. RPC Batching

**What:** Combine multiple RPC calls into fewer requests

```rust
// Current: sequential per window
kitten @ get-text --match id:1  // 2ms
kitten @ get-text --match id:2  // 2ms
kitten @ get-text --match id:3  // 2ms
// Total: 6ms

// Batched: single request
kitten @ get-text --match "id:>=1 && id:<=3"
// Total: 2ms (one round-trip)
```

**Impact:** ~3x reduction in RPC overhead

---

### 2. Connection Pooling

**What:** Multiple simultaneous connections to kitty instead of serial

```rust
// Current: 1 connection, serial execution
let pool = KittyPool::new(1);

// Improved: N connections, parallel execution
let pool = KittyPool::new(4);  // 4 concurrent connections
```

**Impact:** 10 windows: 200ms → 50ms (4x faster)

---

### 3. Caching

**What:** Track window state and skip capture if unchanged

```rust
struct WindowCache {
    content_hash: u64,
    saved_content: String,
}

impl SaveCache {
    fn needs_capture(&self, window: &Window, new_content: &str) -> bool {
        let new_hash = hash(new_content);
        self.windows.get(&window.id)
            .map(|c| c.content_hash != new_hash)
            .unwrap_or(true)
    }
}
```

**Impact:** Cached saves: 240ms → 5ms (48x faster)

---

### 4. Priority Ordering

**What:** Capture visible/focused windows first, background windows lazily

```rust
async fn prioritized_capture(&self, windows: &[Window]) -> Vec<Result> {
    let focused: Vec<_> = windows.iter().filter(|w| w.is_focused).cloned().collect();
    let visible: Vec<_> = windows.iter().filter(|w| w.is_visible && !w.is_focused).cloned().collect();
    let background: Vec<_> = windows.iter().filter(|w| !w.is_visible).cloned().collect();

    // Capture high priority first
    let mut results = self.batch_capture(&focused).await;
    results.extend(self.batch_capture(&visible).await);

    // Background is fire-and-forget
    tokio::spawn(async move {
        self.batch_capture(&background).await;
    });

    results
}
```

**Impact:** User perceives instant save (visible windows done first)

---

### 5. Incremental Saves

**What:** Only capture changed windows, store deltas

```
Save 1: Full capture → store everything
Save 2: Diff → only store changes (delta file)
Save 3: Diff → only store changes
Save N: Full capture (periodic checkpoint)
```

```rust
async fn incremental_save(&self, session: &Session, cache: &SessionCache) -> Result {
    let current = self.batch_ls(&session.windows).await;
    let changes = diff(&current, &cache.last_state);

    if changes.is_empty() {
        return Ok(());  // Instant!
    }

    if changes.len() > session.windows.len() / 2 {
        self.batch_capture(&session.windows).await;  // Full save
    } else {
        self.batch_capture(&changes.windows).await;  // Incremental
        self.write_delta_file(&changes).await;
    }
}
```

**Impact:** Typical save (few changes): 240ms → 20ms (12x faster)

---

### 6. Pre-warm Kitty (Restore)

**What:** Keep kitty instances warm or use socket activation

```rust
// Current: cold start
Command::new("kitty").arg("--session").arg(session).spawn();
// ~285ms

// Pre-warmed: reuse instance
let warm_instance = KITTY_POOL.get();
warm_instance.load_session(session).await;
// ~135ms
```

**Impact:** Restore: 285ms → 135ms (53% faster)

---

## Combined Impact

| Scenario | Before | After | Improvement |
|----------|--------|-------|-------------|
| Cold save (30 windows) | 240ms | ~50ms | 4.8x |
| Cached save (no changes) | 240ms | ~5ms | 48x |
| Incremental save (2 windows changed) | 240ms | ~20ms | 12x |
| Cold restore | 285ms | ~135ms | 2.1x |
| Auto-save hourly (10 saves, 1 change) | 2400ms | ~300ms | 8x |

---

## Proposed PRD Breakdown

### PRD 1: Connection Pool Sizing
- Increase default pool size from 1 to 4
- Add configurable pool size via CLI flag
- Add metrics for pool utilization

### PRD 2: RPC Batching
- Implement batch ls query (multiple windows in one call)
- Add batch get-text for multiple window IDs
- Add integration tests for batch vs serial

### PRD 3: Save Caching
- Add `SaveCache` struct with content hashing
- Implement cache invalidation on window changes
- Add `--no-cache` flag to force full capture
- Add cache storage (file-based for persistence)

### PRD 4: Priority Ordering
- Classify windows as focused/visible/background
- Implement prioritized capture queue
- Add fire-and-forget background capture
- Add progress indicator for user feedback

### PRD 5: Incremental Saves
- Implement delta calculation between captures
- Add delta file format and storage
- Add periodic full-save checkpoint (every N increments)
- Add restore from delta (reconstruct full state)

### PRD 6: Kitty Pre-warm for Restore
- Implement kitty instance pooling for restore
- Add socket activation support
- Add warm-up strategy configuration
- Test with various session sizes

---

## Suggested Skills

1. **to-prd** - Convert each of the 6 PRDs above into formal PRDs and publish to the project issue tracker

2. **grill-with-docs** - Before finalizing each PRD, stress-test against:
   - Existing architecture in `CONTEXT.md`
   - Decision records in `docs/adr/`
   - Test coverage strategy

3. **tdd** - For implementation, use test-driven development:
   - Write performance tests first (assert max latency)
   - Implement optimization
   - Verify improvement

---

## Key Artifacts

- Current benchmarks: `tests/perf_*.rs`
- Source code: `src/session/save.rs`, `src/session/restore.rs`
- Kitty transport: `src/kitty/pool.rs`, `src/kitty/rpc.rs`
- Findings: `docs/findings/restore-latency-baseline.md`

---

## Next Steps

1. Run `grill-with-docs` to validate the combined approach
2. Use `to-prd` to create 6 separate PRDs:
   - PRD-1: Connection Pool Sizing
   - PRD-2: RPC Batching  
   - PRD-3: Save Caching
   - PRD-4: Priority Ordering
   - PRD-5: Incremental Saves
   - PRD-6: Kitty Pre-warm for Restore
3. Prioritize PRDs by:
   - Easiest first (pool sizing, priority ordering)
   - Highest impact first (caching, incremental)
4. Implement in order, measuring at each step
