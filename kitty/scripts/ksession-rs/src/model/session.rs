use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::tab::Tab;

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct SessionFile {
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub schema: u32,
    /// Verbatim `kitty --version` stdout captured at save time. Used by
    /// the reader (`session::manifest::read`) to surface a drift warning
    /// when the major.minor differs from the running kitty (ADR 0002).
    ///
    /// `#[serde(default)]` so older manifests (and synthesised test
    /// fixtures) load as empty string; the reader treats empty as
    /// "unparseable" → no drift warning emitted.
    #[serde(default)]
    pub kitty_version: String,
    pub os_windows: Vec<OsWindow>,
}

impl SessionFile {
    /// The schema number this binary writes and the highest it can read.
    /// Per ADR 0003: pinned at `1` pre-v1.0; additive field changes ride
    /// on `serde(default)` rather than bumping this.
    pub const CURRENT_SCHEMA: u32 = 1;
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct OsWindow {
    pub tabs: Vec<Tab>,
}
