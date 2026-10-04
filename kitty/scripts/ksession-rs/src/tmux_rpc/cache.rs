//! Per-save cache of `TmuxControl` pipes, keyed by `(socket_path, server_pid)`.
//!
//! First lookup spawns a connection; subsequent lookups return the cached
//! `Arc`. When the cache is dropped (at save end), all `Arc<TmuxControl>`
//! refs go away, each `TmuxControl`'s `Drop` sends EOF to stdin, and tmux
//! detaches gracefully. The tmux server is NEVER killed.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::sync::Mutex;

use super::control::TmuxControl;
use super::TmuxError;

/// Per-save cache of `TmuxControl` pipes, keyed by `(socket_path, server_pid)`.
///
/// `Clone` is cheap (wraps `Arc<Mutex<...>>`), so the cache can be shared
/// across the fan-out of window captures without lifetime gymnastics.
#[derive(Clone, Default)]
pub struct TmuxControlCache {
    inner: Arc<Mutex<HashMap<(PathBuf, u32), Arc<TmuxControl>>>>,
}

impl TmuxControlCache {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Get an existing connection or spawn a new one.
    ///
    /// `socket_path` is the tmux server socket from `$TMUX` field 0
    /// (e.g. `/tmp/tmux-1000/default`). `server_pid` is field 1.
    /// `session_id` is the numeric `$<N>` session id. `tmux_version`
    /// gates the `-r` attach flag (see `TmuxControl::connect`).
    pub async fn get_or_spawn(
        &self,
        socket_path: &Path,
        server_pid: u32,
        session_id: u32,
        tmux_version: Option<(u32, u32)>,
    ) -> Result<Arc<TmuxControl>, TmuxError> {
        let key = (socket_path.to_path_buf(), server_pid);
        let mut map = self.inner.lock().await;
        if let Some(ctrl) = map.get(&key) {
            return Ok(Arc::clone(ctrl));
        }
        let ctrl = TmuxControl::connect(socket_path, session_id, tmux_version).await?;
        let arc = Arc::new(ctrl);
        map.insert(key, Arc::clone(&arc));
        Ok(arc)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_is_clone_and_default() {
        let c1 = TmuxControlCache::new();
        let c2 = c1.clone();
        // Both point to the same inner map.
        assert!(Arc::ptr_eq(&c1.inner, &c2.inner));
    }

    #[test]
    fn default_cache_is_empty() {
        // Just ensure Default doesn't panic and produces a usable value.
        let _c = TmuxControlCache::default();
    }
}
