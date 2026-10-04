use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::program::Program;

/// Lower bound of the reserved identity range for synthetic windows.
///
/// Synthetic windows (see [`crate::session::synth`]) are placeholders the
/// orchestrator injects for tabs that filter to zero real captured windows
/// (every window was `is_self` or an overlay child). Their `kitty_id` is
/// allocated from the top of the `u64` space — `u64::MAX`, `u64::MAX - 1`, …
/// — so that the §C.1 patcher can distinguish them from real captured
/// windows with a single `kitty_id >= SYNTHETIC_ID_FLOOR` check instead of
/// maintaining a side table.
///
/// The 1024-window headroom is structurally unreachable: a single save would
/// need 1024 empty tabs in one OS window, which kitty's UI cannot produce.
pub const SYNTHETIC_ID_FLOOR: u64 = u64::MAX - 1024;

// SplitHint dropped per C.1 — set_layout_state carries geometry now.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Window {
    pub kitty_id: u64,
    /// Per-window UUID (v4) generated at save time. Plan §C.3: each window
    /// is also tagged with `ksession_id=<uuid>` via `set-user-vars` so that
    /// runtime sidecars and the restore path can locate the live window by
    /// stable identity even after kitty issues fresh `kitty_id`s.
    ///
    /// `#[serde(default)]` lets pre-§C.3 manifests deserialize to an empty
    /// string; the renderer skips the `--var=ksession_id=` emission when the
    /// value is empty (callers should re-save to refresh it).
    #[serde(default)]
    pub ksession_id: String,
    pub cwd: Option<PathBuf>,
    pub program: Program,
    pub scrollback: Option<PathBuf>,
}
