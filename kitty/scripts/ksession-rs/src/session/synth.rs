//! Synthetic-window identity allocation (plan §5.7 / §C.1).
//!
//! A "synthetic window" is the placeholder [`crate::model::Window`] the save
//! orchestrator injects for a tab whose only real captured windows were
//! filtered out (every window was `is_self` or an overlay child). The tab
//! itself survives the round-trip, but it has no real `kitty_id` to attach a
//! captured program to, so the orchestrator assigns it a reserved high
//! `kitty_id` drawn from the top of the `u64` space.
//!
//! [`SyntheticAllocator`] is the single source of those IDs across:
//!
//! - the §5.7 Phase 2 fallback in `session::save` that injects one
//!   synthetic window per empty tab in the captured manifest, and
//! - the §C.1 patcher in `conf` that emits a fresh `launch /bin/bash -l`
//!   line per synthetic window so the tab restores to a bare login shell.
//!
//! Sharing one allocator type keeps the identity contract in one place:
//! both callers agree that synthetic IDs descend from `u64::MAX` and that
//! the `kitty_id >= SYNTHETIC_ID_FLOOR` predicate is the discriminator.

use crate::model::SYNTHETIC_ID_FLOOR;

/// Descending allocator for synthetic-window `kitty_id` values.
///
/// Each call to [`SyntheticAllocator::next`] yields one ID, starting at
/// `u64::MAX` and descending by 1. The allocator panics if it would descend
/// past [`SYNTHETIC_ID_FLOOR`] — which would require >1024 synthetic windows
/// in a single save, structurally impossible for any real kitty session.
#[derive(Debug)]
pub struct SyntheticAllocator {
    /// Next ID to hand out. Starts at `u64::MAX` and decrements.
    next_id: u64,
}

impl SyntheticAllocator {
    /// Construct a fresh allocator whose first [`Self::next`] call returns
    /// `u64::MAX`.
    #[must_use]
    pub fn new() -> Self {
        Self { next_id: u64::MAX }
    }

    /// Yield the next synthetic `kitty_id`.
    ///
    /// # Panics
    ///
    /// Panics if the allocator has already handed out more than 1024 IDs
    /// (i.e. the next value would fall below [`SYNTHETIC_ID_FLOOR`]). That
    /// would only happen if one save contained >1024 empty tabs in a single
    /// OS window, which kitty's UI cannot produce.
    //
    // Method name is `next` to match the PRD spec verbatim. We don't
    // implement `Iterator` because the only return-type that fits
    // (`Option<u64>` with `None` after exhaustion) would defeat the
    // panic-on-overflow contract that catches the "structurally impossible"
    // case loudly.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> u64 {
        assert!(
            self.next_id >= SYNTHETIC_ID_FLOOR,
            "SyntheticAllocator exhausted: handed out >1024 synthetic IDs in one save \
             (next would be {} < SYNTHETIC_ID_FLOOR={})",
            self.next_id,
            SYNTHETIC_ID_FLOOR,
        );
        let id = self.next_id;
        // Last legal slot is exactly SYNTHETIC_ID_FLOOR; saturating_sub keeps
        // the next call's assertion the one that fires rather than an
        // underflow at u64::MIN.
        self.next_id = self.next_id.saturating_sub(1);
        id
    }
}

impl Default for SyntheticAllocator {
    fn default() -> Self {
        Self::new()
    }
}
