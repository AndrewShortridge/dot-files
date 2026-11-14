//! Session-level orchestration helpers.
//!
//! Currently contains the §C.3 UUID tagging helper. Step 8 save orchestration
//! (snapshot → adapt → render → write) will land in a sibling module and
//! invoke this helper between the snapshot and render phases.

pub mod layout_replay;
pub mod manifest;
pub mod restore;
pub mod rm;
pub mod save;
pub mod show;
pub mod synth;

pub use save::{save, save_with_proc_root, sessions_dir, SaveOpts, SaveOutcome};
pub use synth::SyntheticAllocator;

use uuid::Uuid;

use crate::error::KError;
use crate::kitty::KittyTransport;
use crate::model::Window;

/// Assign each window a stable per-window UUID (v4) and burst-write the
/// `ksession_id=<uuid>` user-var to the matching live kitty windows.
///
/// Plan §C.3 — the conf renderer emits `--var=ksession_id=<uuid>` for each
/// window so that restore + runtime sidecars can locate the live window by
/// stable identity even after kitty issues fresh `kitty_id`s on relaunch.
/// That emission is wired, but until this helper runs, the `Window` values
/// it reads from have an empty `ksession_id` (the field's serde default)
/// and the live kitty window has no `user_var` either. This closes that gap
/// in one place so Step 8's save orchestration can call it once between
/// snapshot and render.
///
/// Behavior:
/// - For each window whose `ksession_id` is empty, generate `Uuid::new_v4()`
///   and assign its dashed string form.
/// - Windows that already carry a `ksession_id` are left untouched (idempotent
///   re-save reuses the same UUID).
/// - All `(kitty_id, ksession_id)` pairs are then sent to kitty as a single
///   batched `set_user_vars_many` call so we ride the §C.6 burst path:
///   one socket lock acquisition, N back-to-back `no_response` frames,
///   one flush.
/// - Empty `windows` slice → `Ok(())` with no RC call. The underlying
///   `set_user_vars_many` also short-circuits on empty input, but we don't
///   even build the iterator in that case.
pub async fn tag_windows_uuids(
    windows: &mut [Window],
    transport: &KittyTransport,
) -> Result<(), KError> {
    if windows.is_empty() {
        return Ok(());
    }

    for w in windows.iter_mut() {
        if w.ksession_id.is_empty() {
            w.ksession_id = Uuid::new_v4().to_string();
        }
    }

    let entries: Vec<(String, Vec<(&str, &str)>)> = windows
        .iter()
        .map(|w| {
            (
                format!("id:{}", w.kitty_id),
                vec![("ksession_id", w.ksession_id.as_str())],
            )
        })
        .collect();

    transport.set_user_vars_many(entries).await
}

#[cfg(test)]
mod tests {
    //! Tests for [`tag_windows_uuids`].
    //!
    //! Mini DCS mock server duplicated from `crate::kitty::tests` because
    //! that helper isn't reachable across modules (its `#[cfg(test)]` mod
    //! is module-private and lifting it to `pub(crate)` would pull test
    //! infra into the prod crate surface).
    use super::*;
    use crate::kitty::pool::KittyPool;
    use crate::kitty::rpc::encode_frame;
    use crate::model::Program;
    use serde_json::Value;
    use std::path::PathBuf;
    use std::sync::Arc;
    use tempfile::tempdir;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;
    use tokio::sync::oneshot;

    const DCS_PREFIX: &[u8] = b"\x1bP@kitty-cmd";
    const DCS_TERMINATOR: &[u8] = b"\x1b\\";

    fn find_terminator(buf: &[u8]) -> Option<usize> {
        buf.windows(DCS_TERMINATOR.len())
            .position(|w| w == DCS_TERMINATOR)
    }

    async fn spawn_mock_server<F>(handler: F) -> (PathBuf, tempfile::TempDir, oneshot::Receiver<()>)
    where
        F: Fn(Value) -> Option<Value> + Send + Sync + 'static,
    {
        let dir = tempdir().expect("tempdir");
        let sock = dir.path().join("rpc.sock");
        let listener = UnixListener::bind(&sock).expect("bind");
        let (done_tx, done_rx) = oneshot::channel();
        let h = Arc::new(handler);
        tokio::spawn(async move {
            let (mut stream, _) = match listener.accept().await {
                Ok(p) => p,
                Err(_) => {
                    let _ = done_tx.send(());
                    return;
                }
            };
            let mut acc: Vec<u8> = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                let n = match stream.read(&mut chunk).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                acc.extend_from_slice(&chunk[..n]);
                while let Some(end) = find_terminator(&acc) {
                    let frame = acc[..end + DCS_TERMINATOR.len()].to_vec();
                    acc.drain(..end + DCS_TERMINATOR.len());
                    let json_bytes = &frame[DCS_PREFIX.len()..frame.len() - DCS_TERMINATOR.len()];
                    let req: Value = serde_json::from_slice(json_bytes).expect("req parses");
                    if let Some(resp_json) = h(req) {
                        let resp_bytes = serde_json::to_vec(&resp_json).expect("ser");
                        let _ = stream.write_all(&encode_frame(&resp_bytes)).await;
                        let _ = stream.flush().await;
                    }
                }
            }
            let _ = done_tx.send(());
        });
        (sock, dir, done_rx)
    }

    fn mk_window(kitty_id: u64, ksession_id: &str) -> Window {
        Window {
            kitty_id,
            ksession_id: ksession_id.to_string(),
            cwd: None,
            program: Program::BareShell,
            scrollback: None,
        }
    }

    /// Spawn an accept-all mock server (records nothing) for tests that
    /// only care about the in-memory mutation, not the wire shape.
    async fn accept_all_transport() -> (KittyTransport, tempfile::TempDir) {
        let (sock, dir, _done) = spawn_mock_server(|_| None).await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        (KittyTransport::Pool(Arc::new(pool)), dir)
    }

    #[tokio::test]
    async fn tag_windows_uuids_assigns_missing_uuids() {
        let (transport, _dir) = accept_all_transport().await;
        let mut windows = vec![mk_window(1, ""), mk_window(2, "")];
        tag_windows_uuids(&mut windows, &transport)
            .await
            .expect("tag ok");
        for w in &windows {
            assert!(!w.ksession_id.is_empty(), "ksession_id must be assigned");
            assert_eq!(
                w.ksession_id.len(),
                36,
                "v4 UUID dashed string is 36 chars, got {:?}",
                w.ksession_id
            );
            assert_eq!(
                w.ksession_id.matches('-').count(),
                4,
                "v4 UUID dashed string has 4 hyphens, got {:?}",
                w.ksession_id
            );
            // Confirm it round-trips through the uuid crate parser.
            Uuid::parse_str(&w.ksession_id).expect("parses as UUID");
        }
    }

    #[tokio::test]
    async fn tag_windows_uuids_preserves_existing_uuids() {
        let (transport, _dir) = accept_all_transport().await;
        let mut windows = vec![mk_window(1, "preset-uuid"), mk_window(2, "")];
        tag_windows_uuids(&mut windows, &transport)
            .await
            .expect("tag ok");
        assert_eq!(
            windows[0].ksession_id, "preset-uuid",
            "existing ksession_id must be preserved (idempotent re-save)",
        );
        assert!(
            !windows[1].ksession_id.is_empty(),
            "empty ksession_id must be filled in",
        );
        assert_ne!(
            windows[1].ksession_id, "preset-uuid",
            "newly-filled UUID must not collide with the preset value",
        );
    }

    #[tokio::test]
    async fn tag_windows_uuids_empty_slice_is_noop() {
        // No transport needed — empty slice must short-circuit before any
        // RC call. We pass a Cli transport (cheapest variant to construct);
        // if the helper *did* try to dispatch, the test would still pass
        // because Cli's set_user_vars_many short-circuits on empty input
        // too, but the explicit short-circuit is the contract.
        let transport = KittyTransport::Cli;
        let mut windows: Vec<Window> = vec![];
        tag_windows_uuids(&mut windows, &transport)
            .await
            .expect("empty slice must be Ok");
        assert!(windows.is_empty(), "no windows appeared out of thin air");
    }

    #[tokio::test]
    async fn tag_windows_uuids_assigns_distinct_uuids() {
        let (transport, _dir) = accept_all_transport().await;
        let mut windows = vec![mk_window(1, ""), mk_window(2, ""), mk_window(3, "")];
        tag_windows_uuids(&mut windows, &transport)
            .await
            .expect("tag ok");
        let a = &windows[0].ksession_id;
        let b = &windows[1].ksession_id;
        let c = &windows[2].ksession_id;
        assert_ne!(a, b, "UUIDs for distinct windows must differ");
        assert_ne!(b, c, "UUIDs for distinct windows must differ");
        assert_ne!(a, c, "UUIDs for distinct windows must differ");
    }
}
