//! Wrapper around `kitty @` remote control.
//!
//! Three layers:
//!
//! - [`ls`] — typed deserialization of the `kitty @ ls` JSON tree (shared
//!   regardless of transport).
//! - [`cli`] — subprocess transport: spawn `kitty @ ls --all-env-vars`,
//!   pipe stdout into the parser. The original implementation; still
//!   present as the fallback path.
//! - [`rpc`] — direct DCS-socket transport (Plan §B.3.1, step 6.5).
//!   Persistent unix-socket connection, ~50 ms/call → ~15 ms/call. The
//!   preferred path when `KITTY_LISTEN_ON` (or `/tmp/kitty-*`) is reachable.
//!
//! [`KittyTransport`] is the thin enum callers use to get "RPC-with-
//! subprocess-fallback" for the four RC operations the save orchestration
//! needs: `ls --all-env-vars`, `ls --output-format=session`, `get-text`,
//! and `set-user-vars`. Both transports implement all four so a
//! caller can stay transport-agnostic.

pub mod cli;
pub mod ls;
pub mod pool;
pub mod rpc;
pub mod version;

#[cfg(test)]
pub mod testkitty;

pub use cli::ls_all_env_vars;
pub use ls::{ls_from_file, parse_ls_output, OsWindow, Tab, Window};
pub use pool::{KittyPool, PreSpawnResult};
pub use rpc::KittyRpc;

use std::sync::Arc;

use crate::error::KError;

/// Unified entry point for kitty RC operations. Constructed once per save
/// via [`KittyTransport::discover`]; falls back to subprocess transport if
/// the DCS socket can't be reached (kitty too old, permission denied on
/// the socket, kitty configured with TTY-only transport, etc.). Callers
/// never need to know which transport actually ran.
pub enum KittyTransport {
    Pool(Arc<KittyPool>),
    /// Direct RPC connection (used by tests).
    Rpc(Arc<KittyRpc>),
    Cli,
}

impl KittyTransport {
    /// Try pool (socket) first, fall back to subprocess on failure.
    ///
    /// Does not make any RC calls — only opens the socket. A socket that
    /// connects but later rejects requests (e.g. version mismatch on the
    /// first real call) does NOT silently retry through the subprocess;
    /// that surfaces as a [`KError::KittyRemote`] on the operation itself.
    /// Callers who want full degradation should match the error and
    /// reconstruct the [`KittyTransport::Cli`] variant.
    pub async fn discover() -> Self {
        match KittyPool::discover().await {
            Ok(pool) => Self::Pool(Arc::new(pool)),
            Err(_e) => {
                // Intentionally swallowed: if `cli` also fails the caller
                // sees the failure on the first RC operation. (Once
                // `tracing` is wired in step 8, log discover-error at WARN.)
                Self::Cli
            }
        }
    }

    pub async fn ls_all_env_vars(&self) -> Result<Vec<OsWindow>, KError> {
        match self {
            Self::Pool(pool) => pool.ls_all_env_vars().await,
            Self::Rpc(rpc) => rpc.ls_all_env_vars().await,
            Self::Cli => cli::ls_all_env_vars().await,
        }
    }

    /// `kitty @ ls --output-format=session`. Used by step 6.75 (§C.1) as
    /// the skeleton for the emitted .conf.
    pub async fn ls_session(
        &self,
        all_env_vars: bool,
        use_foreground_process: bool,
    ) -> Result<String, KError> {
        match self {
            Self::Pool(pool) => pool.ls_session(all_env_vars, use_foreground_process).await,
            Self::Rpc(rpc) => rpc.ls_session(all_env_vars, use_foreground_process).await,
            Self::Cli => cli::ls_session(all_env_vars, use_foreground_process).await,
        }
    }

    /// `kitty @ get-text`. Used by scrollback capture per §5.7.
    pub async fn get_text(&self, match_: &str, extent: &str, ansi: bool) -> Result<String, KError> {
        match self {
            Self::Pool(pool) => pool.get_text(match_, extent, ansi).await,
            Self::Rpc(rpc) => rpc.get_text(match_, extent, ansi).await,
            Self::Cli => cli::get_text(match_, extent, ansi).await,
        }
    }

    /// `kitty @ set-user-vars`. Used by §C.3 UUID tagging.
    pub async fn set_user_vars<K, V>(&self, match_: &str, vars: &[(K, V)]) -> Result<(), KError>
    where
        K: AsRef<str>,
        V: AsRef<str>,
    {
        match self {
            Self::Pool(pool) => pool.set_user_vars(match_, vars).await,
            Self::Rpc(rpc) => rpc.set_user_vars(match_, vars).await,
            Self::Cli => cli::set_user_vars(match_, vars).await,
        }
    }

    /// Burst-write set-user-vars for many windows. Plan §C.3 (UUID tag every
    /// window at save time) + §C.6 (one held mutex, N back-to-back
    /// `no_response` frames, one flush).
    ///
    /// - **Pool path**: forwards to [`KittyPool::set_user_vars_many`], the §C.6
    ///   burst — single connection acquisition, one flush at the end. This
    ///   is the fast path step 8 orchestration was built around.
    /// - **Cli path**: degraded but functional — loops over entries and shells
    ///   out one `kitty @ set-user-vars` per entry. Stops on the first error.
    ///   Empty inner var lists are skipped (matching the pool burst's
    ///   behavior); [`cli::set_user_vars`] also short-circuits on empty as a
    ///   belt-and-braces guard. The per-entry spawn is **forced**, not lazy:
    ///   `kitty @ set-user-vars` accepts only one `--match` per invocation
    ///   (live-verified — a second `--match` flag silently overrides the
    ///   first), so there is no CLI-side batching shape.
    pub async fn set_user_vars_many<I, M, K, V>(&self, entries: I) -> Result<(), KError>
    where
        I: IntoIterator<Item = (M, Vec<(K, V)>)>,
        M: AsRef<str>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        match self {
            Self::Pool(pool) => pool.set_user_vars_many(entries).await,
            Self::Rpc(rpc) => rpc.set_user_vars_many(entries).await,
            Self::Cli => {
                for (match_, vars) in entries {
                    if vars.is_empty() {
                        continue;
                    }
                    cli::set_user_vars(match_.as_ref(), &vars).await?;
                }
                Ok(())
            }
        }
    }

    /// Discover the transport AND issue the first `ls --all-env-vars` in one
    /// call. Plan §B.5: pre-spawning lets the ~15 ms RC round-trip overlap
    /// clap-parse / log-init in `main()`, saving ~10 ms cold start.
    ///
    /// The perf win is pool-specific — under the Cli arm this is just
    /// `discover().await` followed by a subprocess `kitty @ ls` round-trip,
    /// no overlap with anything. The helper exists for call-site symmetry
    /// regardless of transport: callers don't need to special-case the
    /// fallback to avoid the convenience.
    ///
    /// **Contract**: [`KittyTransport::discover`] never errors — pool
    /// failure silently falls back to `Cli` — so this helper only returns
    /// `Err` from the `ls_all_env_vars` step. A caller that needs to
    /// distinguish "pool failed, fell back to Cli, which then failed at ls"
    /// from "pool succeeded but ls failed" must check
    /// [`KittyTransport::is_pool`] on the returned transport.
    pub async fn discover_and_ls() -> Result<(Self, Vec<OsWindow>), KError> {
        let transport = Self::discover().await;
        let ls = transport.ls_all_env_vars().await?;
        Ok((transport, ls))
    }

    /// Diagnostic: did we get the fast path (pool/socket transport)?
    pub fn is_pool(&self) -> bool {
        matches!(self, Self::Pool(_))
    }

    /// Diagnostic: did we get the fast path? Alias for [`is_pool`] for
    /// backward compatibility.
    pub fn is_rpc(&self) -> bool {
        self.is_pool()
    }
}

#[cfg(test)]
mod tests {
    //! Transport-level dispatch tests.
    //!
    //! These assert that the [`KittyTransport::Pool`] arms route to the
    //! [`KittyPool`] inner pool correctly. The [`KittyTransport::Cli`]
    //! arms are mechanical `Self::Cli => cli::xxx(...)` dispatches; their
    //! subprocess behavior is covered by the `*_via` shim tests in
    //! [`crate::kitty::cli`].
    //!
    //! Mini-mock server (~50 LOC) replicated here rather than imported
    //! from `rpc.rs`'s `#[cfg(test)] mod tests` — that helper isn't
    //! reachable across modules and lifting it to `pub(crate)` would
    //! cost more than copying.
    use super::*;
    use crate::kitty::rpc::encode_frame;
    use serde_json::{json, Value};
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

    /// Mock server speaking the DCS protocol. Handler takes the parsed
    /// request and returns the JSON response body, or `None` for
    /// no_response (write nothing). Mirrors the `spawn_mock_server` in
    /// `rpc.rs`'s test module; intentionally duplicated for module
    /// independence.
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

    // --- is_pool() / is_rpc() ---------------------------------------------

    #[tokio::test]
    async fn is_pool_returns_true_for_pool_variant() {
        let (sock, _dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": "" }))).await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let transport = KittyTransport::Pool(Arc::new(pool));
        assert!(
            transport.is_pool(),
            "Pool variant must report is_pool()=true"
        );
        assert!(
            transport.is_rpc(),
            "Pool variant must report is_rpc()=true (compat alias)"
        );
    }

    #[test]
    fn is_pool_returns_false_for_cli_variant() {
        assert!(
            !KittyTransport::Cli.is_pool(),
            "Cli variant must report is_pool()=false"
        );
        assert!(
            !KittyTransport::Cli.is_rpc(),
            "Cli variant must report is_rpc()=false"
        );
    }

    // --- dispatch from Pool variant ---------------------------------------

    #[tokio::test]
    async fn pool_variant_dispatches_ls_to_pool() {
        // Assert the enum's ls_all_env_vars routes through KittyPool::ls
        // (cmd: "ls", all_env_vars: true).
        use std::sync::atomic::{AtomicBool, Ordering};
        let saw_ls = Arc::new(AtomicBool::new(false));
        let saw_ls_h = saw_ls.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |req| {
            assert_eq!(req["cmd"], "ls");
            assert_eq!(req["payload"]["all_env_vars"], true);
            saw_ls_h.store(true, Ordering::SeqCst);
            // ls's data is a JSON-encoded JSON STRING (double-decode).
            Some(json!({ "ok": true, "data": "[]" }))
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let transport = KittyTransport::Pool(Arc::new(pool));
        let osws = transport.ls_all_env_vars().await.expect("ls ok");
        assert!(osws.is_empty(), "empty mock returns no windows");
        assert!(
            saw_ls.load(Ordering::SeqCst),
            "Pool arm must dispatch to KittyPool::ls_all_env_vars"
        );
    }

    #[tokio::test]
    async fn pool_variant_dispatches_ls_session_to_pool() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let saw = Arc::new(AtomicBool::new(false));
        let saw_h = saw.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |req| {
            assert_eq!(req["cmd"], "ls");
            assert_eq!(req["payload"]["output_format"], "session");
            saw_h.store(true, Ordering::SeqCst);
            Some(json!({ "ok": true, "data": "new_tab\nfocus\n" }))
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let transport = KittyTransport::Pool(Arc::new(pool));
        let s = transport
            .ls_session(false, true)
            .await
            .expect("ls(session) ok");
        assert_eq!(
            s, "new_tab\nfocus",
            "trailing whitespace stripped per round-3 finding"
        );
        assert!(
            saw.load(Ordering::SeqCst),
            "Pool arm must dispatch to KittyPool::ls_session"
        );
    }

    #[tokio::test]
    async fn pool_variant_dispatches_get_text_to_pool() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let saw = Arc::new(AtomicBool::new(false));
        let saw_h = saw.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |req| {
            assert_eq!(req["cmd"], "get_text");
            assert_eq!(req["payload"]["match"], "id:7");
            assert_eq!(req["payload"]["extent"], "screen");
            assert_eq!(req["payload"]["ansi"], false);
            saw_h.store(true, Ordering::SeqCst);
            Some(json!({ "ok": true, "data": "hello" }))
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let transport = KittyTransport::Pool(Arc::new(pool));
        let txt = transport
            .get_text("id:7", "screen", false)
            .await
            .expect("get_text ok");
        assert_eq!(txt, "hello");
        assert!(
            saw.load(Ordering::SeqCst),
            "Pool arm must dispatch to KittyPool::get_text"
        );
    }

    #[tokio::test]
    async fn pool_variant_dispatches_set_user_vars_to_pool() {
        // set_user_vars uses no_response: true (§C.3). Server records the
        // payload shape; we assert match+var arrived.
        use std::sync::atomic::{AtomicBool, Ordering};
        let saw = Arc::new(AtomicBool::new(false));
        let saw_h = saw.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |req| {
            assert_eq!(req["cmd"], "set_user_vars");
            assert_eq!(req["no_response"], true);
            assert_eq!(req["payload"]["match"], "id:1");
            // Critical: payload key is `var` (singular). Lock the bugfix.
            assert_eq!(req["payload"]["var"], json!(["k=v"]));
            saw_h.store(true, Ordering::SeqCst);
            None
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let transport = KittyTransport::Pool(Arc::new(pool));
        let vars: Vec<(&str, &str)> = vec![("k", "v")];
        transport
            .set_user_vars("id:1", &vars)
            .await
            .expect("set_user_vars ok");
        // no_response, so the call returns once the frame's written. Give
        // the server task a beat to parse it before we check.
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        assert!(
            saw.load(Ordering::SeqCst),
            "Pool arm must dispatch to KittyPool::set_user_vars"
        );
    }

    #[tokio::test]
    async fn pool_variant_dispatches_set_user_vars_many_to_pool() {
        // §C.6 burst: 3 entries → 3 frames in one connection acquisition.
        // Server increments a counter per frame; asserts all three arrived.
        use std::sync::atomic::{AtomicUsize, Ordering};
        let count = Arc::new(AtomicUsize::new(0));
        let count_h = count.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |req| {
            assert_eq!(req["cmd"], "set_user_vars");
            assert_eq!(req["no_response"], true);
            assert!(req["payload"]["var"].is_array());
            count_h.fetch_add(1, Ordering::SeqCst);
            None
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let transport = KittyTransport::Pool(Arc::new(pool));
        let entries: Vec<(String, Vec<(&str, &str)>)> = vec![
            ("id:1".into(), vec![("a", "1")]),
            ("id:2".into(), vec![("b", "2"), ("c", "3")]),
            ("id:3".into(), vec![("d", "4")]),
        ];
        transport
            .set_user_vars_many(entries)
            .await
            .expect("burst ok");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        assert_eq!(
            count.load(Ordering::SeqCst),
            3,
            "Pool arm must dispatch to KittyPool::set_user_vars_many — all three frames must land",
        );
    }
}
