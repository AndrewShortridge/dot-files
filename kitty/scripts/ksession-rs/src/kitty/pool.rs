//! Connection pool for kitty's DCS-socket RPC protocol.
//!
//! Replaces the single-connection `KittyRpc` (now internal to `rpc.rs`) with a pool
//! of up to `POOL_CAPACITY` (default: `FAN_OUT_LIMIT` = 12) concurrent
//! Unix-socket connections. The save pipeline's `buffer_unordered(FAN_OUT_LIMIT)`
//! fan-out can now issue per-window RPC calls in true concurrency instead of
//! serialising behind a single `Mutex<Option<UnixStream>>`.
//!
//! # Pool behaviour
//!
//! - **Lazy dial**: connections are established on demand, not at construction.
//! - **Capacity**: at most `capacity` connections exist simultaneously (idle +
//!   in-use). When all slots are occupied, [`KittyPool::acquire`] awaits a
//!   [`tokio::sync::Notify`] signal from a returning [`PoolGuard`].
//! - **Per-connection poison**: if an RPC call errors, the [`PoolGuard`]'s
//!   inner stream is set to `None`. On [`Drop`], nothing returns to the idle
//!   queue — only `in_use` is decremented and waiters are notified so a fresh
//!   connection can be dialled. Other connections are unaffected.
//! - **Env override**: `KSESSION_KITTY_POOL_SIZE` overrides the default
//!   capacity, clamped to [1, 32] with a stderr warning on out-of-bounds.

use std::collections::VecDeque;
use std::env;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;

use crate::error::KError;
use crate::kitty::ls::{parse_ls_output, OsWindow};
use crate::kitty::rpc::{
    connect_spec_to_stream, discover_candidates, encode_frame, exchange_on, spec_to_fs_path,
    Envelope, DEFAULT_TIMEOUT, POISONED_MSG, PROTOCOL_VERSION,
};

/// Default pool capacity — matches the save pipeline's fan-out limit.
const FAN_OUT_LIMIT: usize = 12;

/// Absolute upper bound for the env-var override.
const MAX_POOL_SIZE: usize = 32;

/// Result of blocking pre-spawn: socket path + raw std streams.
/// Streams are not bound to any tokio runtime and must be converted
/// via [`KittyPool::from_prespawn`] on the target runtime.
pub struct PreSpawnResult {
    pub socket_path: PathBuf,
    pub streams: Vec<std::os::unix::net::UnixStream>,
    pub capacity: usize,
}

/// Connection pool managing up to `capacity` concurrent Unix-socket
/// connections to a single kitty instance.
#[derive(Debug)]
pub struct KittyPool {
    idle: tokio::sync::Mutex<VecDeque<UnixStream>>,
    socket_path: PathBuf,
    capacity: usize,
    in_use: AtomicUsize,
    notify: tokio::sync::Notify,
    read_timeout: Duration,
}

/// RAII connection handle. On drop, returns a healthy stream to the pool's
/// idle queue; a poisoned stream (set to `None` after an error) is silently
/// discarded.
pub struct PoolGuard<'a> {
    pool: &'a KittyPool,
    stream: Option<UnixStream>,
}

impl<'a> Drop for PoolGuard<'a> {
    fn drop(&mut self) {
        if let Some(stream) = self.stream.take() {
            // Return to idle queue. We must not block, so use try_lock.
            // If the lock is contended, spawn a task to return it.
            let pool = self.pool;
            match pool.idle.try_lock() {
                Ok(mut idle) => {
                    idle.push_back(stream);
                    pool.in_use.fetch_sub(1, Ordering::Release);
                    pool.notify.notify_one();
                }
                Err(_) => {
                    // Can't get lock synchronously — spawn a task.
                    // We need to move the stream into a 'static future.
                    // Use a raw pointer trick via unsafe to extend the lifetime.
                    // Actually, we can just decrement in_use and notify, then
                    // let the stream drop (closing the fd). This is safe because
                    // a new connection will be dialled on next acquire.
                    pool.in_use.fetch_sub(1, Ordering::Release);
                    pool.notify.notify_one();
                    // stream drops here — fd closes. Next acquire dials fresh.
                }
            }
        } else {
            // Poisoned: stream was None (error path). Just decrement and notify.
            self.pool.in_use.fetch_sub(1, Ordering::Release);
            self.pool.notify.notify_one();
        }
    }
}

impl<'a> PoolGuard<'a> {
    /// Synchronous request/response on this connection. On error, poisons
    /// this guard's stream (sets to `None`) so it won't return to the pool.
    pub async fn call(&mut self, cmd: &str, payload: Value) -> Result<Value, KError> {
        let pool_in_use = self.pool.in_use.load(Ordering::Relaxed);
        let body = json!({
            "cmd": cmd,
            "version": PROTOCOL_VERSION,
            "payload": payload,
        });
        let frame = encode_frame(&serde_json::to_vec(&body)?);

        let stream = self
            .stream
            .as_mut()
            .ok_or_else(|| KError::KittyRemote(POISONED_MSG.to_string()))?;

        let resp_result = exchange_on(stream, &frame, self.pool.read_timeout).await;
        let resp_bytes = match resp_result {
            Ok(b) => b,
            Err(e) => {
                // Poison this connection.
                self.stream = None;
                return Err(e);
            }
        };

        let envelope: Envelope = {
            let _decode_span = crate::perf_span!(
                crate::perf::Level::Trace,
                "kitty.rpc.decode",
                pool_in_use = pool_in_use,
            );
            match serde_json::from_slice(&resp_bytes) {
                Ok(e) => e,
                Err(e) => {
                    // Malformed response — poison.
                    self.stream = None;
                    return Err(KError::KittyRemote(format!(
                        "malformed RC response: {e} ({})",
                        snippet(&resp_bytes)
                    )));
                }
            }
        };

        if !envelope.ok {
            // Server rejected the command but the connection is fine.
            return Err(KError::KittyRemote(format!(
                "{cmd}: {}",
                envelope.error.unwrap_or_else(|| "unknown error".into())
            )));
        }

        Ok(envelope.data.unwrap_or(Value::Null))
    }

    /// Fire-and-forget request (`no_response: true`). On I/O error the
    /// stream is poisoned.
    pub async fn call_no_response(&mut self, cmd: &str, payload: Value) -> Result<(), KError> {
        let pool_in_use = self.pool.in_use.load(Ordering::Relaxed);
        let body = json!({
            "cmd": cmd,
            "version": PROTOCOL_VERSION,
            "no_response": true,
            "payload": payload,
        });
        let frame = encode_frame(&serde_json::to_vec(&body)?);

        let stream = self
            .stream
            .as_mut()
            .ok_or_else(|| KError::KittyRemote(POISONED_MSG.to_string()))?;

        let r = async {
            let _write_span = crate::perf_span!(
                crate::perf::Level::Trace,
                "kitty.rpc.write_req",
                pool_in_use = pool_in_use,
            );
            stream.write_all(&frame).await.map_err(io_to_remote)?;
            stream.flush().await.map_err(io_to_remote)?;
            Ok::<(), KError>(())
        }
        .await;

        if let Err(e) = r {
            self.stream = None;
            return Err(e);
        }
        Ok(())
    }

    /// Write pre-encoded frames on this connection (for burst writes).
    /// On I/O error the stream is poisoned.
    pub async fn write_frames(&mut self, frames: &[Vec<u8>]) -> Result<(), KError> {
        let stream = self
            .stream
            .as_mut()
            .ok_or_else(|| KError::KittyRemote(POISONED_MSG.to_string()))?;

        let r: Result<(), KError> = async {
            for frame in frames {
                stream.write_all(frame).await.map_err(io_to_remote)?;
            }
            stream.flush().await.map_err(io_to_remote)?;
            Ok(())
        }
        .await;

        if let Err(e) = r {
            self.stream = None;
            return Err(e);
        }
        Ok(())
    }
}

impl KittyPool {
    /// Create a pool targeting the given socket path with the specified capacity.
    pub fn new(socket_path: PathBuf, capacity: usize) -> Self {
        Self {
            idle: tokio::sync::Mutex::new(VecDeque::with_capacity(capacity)),
            socket_path,
            capacity,
            in_use: AtomicUsize::new(0),
            notify: tokio::sync::Notify::new(),
            read_timeout: DEFAULT_TIMEOUT,
        }
    }

    /// Resolve pool capacity from env var or default.
    pub fn capacity_from_env() -> usize {
        match env::var("KSESSION_KITTY_POOL_SIZE") {
            Ok(val) => match val.trim().parse::<usize>() {
                Ok(n) if n >= 1 && n <= MAX_POOL_SIZE => n,
                Ok(n) => {
                    let clamped = n.clamp(1, MAX_POOL_SIZE);
                    eprintln!(
                        "ksession: KSESSION_KITTY_POOL_SIZE={n} out of range [1, {MAX_POOL_SIZE}]; \
                         clamped to {clamped}"
                    );
                    clamped
                }
                Err(e) => {
                    eprintln!(
                        "ksession: KSESSION_KITTY_POOL_SIZE={val:?} is not a valid integer ({e}); \
                         using default {FAN_OUT_LIMIT}"
                    );
                    FAN_OUT_LIMIT
                }
            },
            Err(_) => FAN_OUT_LIMIT,
        }
    }

    /// Probe for a kitty RC socket and create a pool targeting it.
    pub async fn discover() -> Result<Self, KError> {
        let capacity = Self::capacity_from_env();
        let candidates = discover_candidates();
        if candidates.is_empty() {
            return Err(KError::KittyRemote(
                "no kitty RC socket found (set KITTY_LISTEN_ON or run from inside kitty)".into(),
            ));
        }
        let mut errs: Vec<String> = Vec::new();
        for spec in &candidates {
            match connect_spec_to_stream(spec).await {
                Ok((stream, path)) => {
                    let mut pool = Self::new(path, capacity);
                    // Seed the pool with this first connection.
                    pool.idle.get_mut().push_back(stream);
                    return Ok(pool);
                }
                Err(e) => errs.push(format!("  {spec}: {e}")),
            }
        }
        Err(KError::KittyRemote(format!(
            "no kitty RC socket connectable:\n{}",
            errs.join("\n")
        )))
    }

    /// Discover the socket AND pre-warm all `capacity` connections
    /// concurrently. Used by `main()` to overlap pool creation with the
    /// ~3 ms of clap CLI parsing.
    ///
    /// 1. Runs [`discover_candidates`] to locate the socket path.
    /// 2. Validates the first candidate with [`connect_spec_to_stream`].
    /// 3. Once a working socket is found, dials `capacity` connections
    ///    concurrently via [`futures::future::join_all`].
    /// 4. Returns the pool with all successfully-opened connections in
    ///    the idle queue, ready for immediate [`acquire`].
    ///
    /// Partial pre-warm is acceptable — if some dials fail, those slots
    /// will be dialled lazily by [`acquire`] on demand.
    pub async fn discover_and_warm(capacity: usize) -> Result<Self, KError> {
        let candidates = discover_candidates();
        if candidates.is_empty() {
            return Err(KError::KittyRemote(
                "no kitty RC socket found (set KITTY_LISTEN_ON or run from inside kitty)".into(),
            ));
        }
        let mut errs: Vec<String> = Vec::new();
        for spec in &candidates {
            match connect_spec_to_stream(spec).await {
                Ok((_first_stream, path)) => {
                    // Found a working socket. Dial capacity connections concurrently.
                    let futs: Vec<_> = (0..capacity).map(|_| UnixStream::connect(&path)).collect();
                    let results = futures::future::join_all(futs).await;
                    let mut pool = Self::new(path, capacity);
                    for r in results {
                        match r {
                            Ok(stream) => pool.idle.get_mut().push_back(stream),
                            Err(e) => {
                                eprintln!("ksession: pre-warm dial failed: {e}");
                            }
                        }
                    }
                    // Even partial pre-warm is fine — acquire() will dial remaining lazily.
                    return Ok(pool);
                }
                Err(e) => errs.push(format!("  {spec}: {e}")),
            }
        }
        Err(KError::KittyRemote(format!(
            "no kitty RC socket connectable:\n{}",
            errs.join("\n")
        )))
    }

    /// Synchronous discover + pre-warm using blocking std sockets.
    /// Safe to call from any thread (no tokio runtime required).
    /// Returns a [`PreSpawnResult`] whose streams must be converted on
    /// the target tokio runtime via [`from_prespawn`].
    pub fn discover_and_warm_blocking(capacity: usize) -> Result<PreSpawnResult, KError> {
        let candidates = discover_candidates();
        if candidates.is_empty() {
            return Err(KError::KittyRemote(
                "no kitty RC socket found (set KITTY_LISTEN_ON or run from inside kitty)".into(),
            ));
        }
        let mut errs: Vec<String> = Vec::new();
        for spec in &candidates {
            let path = match spec_to_fs_path(spec) {
                Some(p) => p,
                None => continue,
            };
            match std::os::unix::net::UnixStream::connect(&path) {
                Ok(probe) => {
                    drop(probe);
                    let streams: Vec<_> = (0..capacity)
                        .filter_map(|_| {
                            let s = std::os::unix::net::UnixStream::connect(&path).ok()?;
                            s.set_nonblocking(true).ok()?;
                            Some(s)
                        })
                        .collect();
                    return Ok(PreSpawnResult {
                        socket_path: path,
                        streams,
                        capacity,
                    });
                }
                Err(e) => errs.push(format!("  {spec}: {e}")),
            }
        }
        Err(KError::KittyRemote(format!(
            "no kitty RC socket connectable:\n{}",
            errs.join("\n")
        )))
    }

    /// Convert a [`PreSpawnResult`] (blocking std streams) into a pool.
    /// Must be called on the tokio runtime that will use the pool.
    pub fn from_prespawn(result: PreSpawnResult) -> Result<Self, KError> {
        let mut pool = Self::new(result.socket_path, result.capacity);
        for std_stream in result.streams {
            match UnixStream::from_std(std_stream) {
                Ok(tokio_stream) => pool.idle.get_mut().push_back(tokio_stream),
                Err(e) => eprintln!("ksession: pre-spawn stream conversion failed: {e}"),
            }
        }
        Ok(pool)
    }

    /// Discover the socket AND issue the first `ls --all-env-vars` in one
    /// future.
    pub async fn discover_and_ls() -> Result<(Self, Vec<OsWindow>), KError> {
        let pool = Self::discover().await?;
        let ls = pool.ls_all_env_vars().await?;
        Ok((pool, ls))
    }

    /// Connect to a filesystem-path socket and create a pool.
    pub async fn connect(socket: &Path, capacity: usize) -> Result<Self, KError> {
        let stream = UnixStream::connect(socket)
            .await
            .map_err(|e| KError::KittyRemote(format!("connect {}: {}", socket.display(), e)))?;
        let mut pool = Self::new(socket.to_path_buf(), capacity);
        pool.idle.get_mut().push_back(stream);
        Ok(pool)
    }

    /// Connect using a raw `listen_on`-style spec.
    pub async fn connect_spec(spec: &str, capacity: usize) -> Result<Self, KError> {
        let (stream, path) = connect_spec_to_stream(spec).await?;
        let mut pool = Self::new(path, capacity);
        pool.idle.get_mut().push_back(stream);
        Ok(pool)
    }

    /// Test-only: override the per-call read timeout.
    #[cfg(test)]
    pub(crate) fn set_read_timeout_for_test(&mut self, t: Duration) {
        self.read_timeout = t;
    }

    /// Path of the socket this pool targets.
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Current number of in-use connections.
    pub fn in_use(&self) -> usize {
        self.in_use.load(Ordering::Relaxed)
    }

    /// Acquire a connection from the pool. Lazy-dials when idle is empty
    /// and under capacity; waits on Notify when at capacity.
    pub async fn acquire(&self) -> Result<PoolGuard<'_>, KError> {
        loop {
            // 1. Try to pop from idle queue.
            {
                let mut idle = self.idle.lock().await;
                if let Some(stream) = idle.pop_front() {
                    self.in_use.fetch_add(1, Ordering::Acquire);
                    return Ok(PoolGuard {
                        pool: self,
                        stream: Some(stream),
                    });
                }
            }

            // 2. If under capacity, dial a new connection.
            let current = self.in_use.load(Ordering::Acquire);
            if current < self.capacity {
                // Try to claim a slot with CAS.
                if self
                    .in_use
                    .compare_exchange(current, current + 1, Ordering::AcqRel, Ordering::Relaxed)
                    .is_ok()
                {
                    match UnixStream::connect(&self.socket_path).await {
                        Ok(stream) => {
                            return Ok(PoolGuard {
                                pool: self,
                                stream: Some(stream),
                            });
                        }
                        Err(e) => {
                            // Failed to dial — release the slot.
                            self.in_use.fetch_sub(1, Ordering::Release);
                            return Err(KError::KittyRemote(format!(
                                "connect {}: {}",
                                self.socket_path.display(),
                                e
                            )));
                        }
                    }
                }
                // CAS failed — another task beat us. Loop and retry.
                continue;
            }

            // 3. At capacity — wait for a connection to return.
            self.notify.notified().await;
        }
    }

    // --- High-level RPC methods ---

    /// `kitty @ ls --all-env-vars` — returns the typed window tree.
    pub async fn ls_all_env_vars(&self) -> Result<Vec<OsWindow>, KError> {
        let mut _span = crate::perf_span!(
            crate::perf::Level::Debug,
            "kitty.rpc.ls",
            pool_in_use = self.in_use.load(Ordering::Relaxed),
        );
        let payload = json!({ "all_env_vars": true });
        let bytes_out = serde_json::to_string(&payload)
            .map(|s| s.len())
            .unwrap_or(0);
        let mut guard = self.acquire().await?;
        let data = guard.call("ls", payload).await?;
        drop(guard);
        let inner = data.as_str().ok_or_else(|| {
            KError::KittyRemote("ls: data was not a string (kitty changed protocol?)".into())
        })?;
        if let Some(ref mut s) = _span {
            s.push_arg("bytes_out", format!("{}", bytes_out));
            s.push_arg("bytes_in", format!("{}", inner.len()));
        }
        parse_ls_output(inner.as_bytes())
    }

    /// `kitty @ ls --output-format=session`
    pub async fn ls_session(
        &self,
        all_env_vars: bool,
        use_foreground_process: bool,
    ) -> Result<String, KError> {
        let mut _span = crate::perf_span!(
            crate::perf::Level::Debug,
            "kitty.ls_session",
            pool_in_use = self.in_use.load(Ordering::Relaxed),
        );
        let mut guard = self.acquire().await?;
        let data = guard
            .call(
                "ls",
                json!({
                    "output_format": "session",
                    "all_env_vars": all_env_vars,
                    "use_foreground_process": use_foreground_process,
                }),
            )
            .await?;
        let result = data
            .as_str()
            .ok_or_else(|| KError::KittyRemote("ls(session): data was not a string".into()))?
            .trim_end()
            .to_string();
        if let Some(ref mut s) = _span {
            s.push_arg("bytes_in", format!("{}", result.len()));
        }
        Ok(result)
    }

    /// `kitty @ get-text --match <m> --extent <e> [--ansi]`.
    pub async fn get_text(&self, match_: &str, extent: &str, ansi: bool) -> Result<String, KError> {
        let mut _span = crate::perf_span!(
            crate::perf::Level::Debug,
            "kitty.rpc.get_text",
            pool_in_use = self.in_use.load(Ordering::Relaxed),
        );
        let payload = json!({
            "match": match_,
            "extent": extent,
            "ansi": ansi,
        });
        let bytes_out = serde_json::to_string(&payload)
            .map(|s| s.len())
            .unwrap_or(0);
        let mut guard = self.acquire().await?;
        let data = guard.call("get_text", payload).await?;
        drop(guard);
        if data.is_null() {
            if let Some(ref mut s) = _span {
                s.push_arg("bytes_out", format!("{}", bytes_out));
                s.push_arg("bytes_in", "0".to_string());
            }
            return Ok(String::new());
        }
        let result = data
            .as_str()
            .ok_or_else(|| {
                KError::KittyRemote(format!(
                    "get_text: expected string data, got {}",
                    type_of_value(&data)
                ))
            })?
            .trim_end()
            .to_string();
        if let Some(ref mut s) = _span {
            s.push_arg("bytes_out", format!("{}", bytes_out));
            s.push_arg("bytes_in", format!("{}", result.len()));
        }
        Ok(result)
    }

    /// `kitty @ set-user-vars --match <m> k=v ...`, fire-and-forget.
    pub async fn set_user_vars<K, V>(&self, match_: &str, vars: &[(K, V)]) -> Result<(), KError>
    where
        K: AsRef<str>,
        V: AsRef<str>,
    {
        if vars.is_empty() {
            return Ok(());
        }
        let kv: Vec<String> = vars
            .iter()
            .map(|(k, v)| format!("{}={}", k.as_ref(), v.as_ref()))
            .collect();
        let payload = json!({
            "match": match_,
            "var": kv,
        });
        let bytes_out = serde_json::to_string(&payload)
            .map(|s| s.len())
            .unwrap_or(0);
        let _span = crate::perf_span!(
            crate::perf::Level::Debug,
            "kitty.rpc.set_user_vars",
            bytes_out = bytes_out,
            bytes_in = 0,
            pool_in_use = self.in_use.load(Ordering::Relaxed),
        );
        let mut guard = self.acquire().await?;
        guard.call_no_response("set_user_vars", payload).await
    }

    /// Burst-write set_user_vars for many windows on one connection.
    pub async fn set_user_vars_many<I, M, K, V>(&self, entries: I) -> Result<(), KError>
    where
        I: IntoIterator<Item = (M, Vec<(K, V)>)>,
        M: AsRef<str>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        // Build all frames up-front so the connection is held only for I/O.
        let mut frames: Vec<Vec<u8>> = Vec::new();
        for (m, vars) in entries {
            if vars.is_empty() {
                continue;
            }
            let kv: Vec<String> = vars
                .iter()
                .map(|(k, v)| format!("{}={}", k.as_ref(), v.as_ref()))
                .collect();
            let body = json!({
                "cmd": "set_user_vars",
                "version": PROTOCOL_VERSION,
                "no_response": true,
                "payload": { "match": m.as_ref(), "var": kv },
            });
            frames.push(encode_frame(&serde_json::to_vec(&body)?));
        }
        if frames.is_empty() {
            return Ok(());
        }
        let bytes_out: usize = frames.iter().map(|f| f.len()).sum();
        let _span = crate::perf_span!(
            crate::perf::Level::Debug,
            "kitty.rpc.set_user_vars",
            bytes_out = bytes_out,
            bytes_in = 0,
            count = frames.len(),
            pool_in_use = self.in_use.load(Ordering::Relaxed),
        );
        let mut guard = self.acquire().await?;
        guard.write_frames(&frames).await
    }
}

fn type_of_value(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn snippet(b: &[u8]) -> String {
    let n = b.len().min(80);
    String::from_utf8_lossy(&b[..n])
        .replace('\x1b', "\\e")
        .replace('\n', "\\n")
}

fn io_to_remote(e: std::io::Error) -> KError {
    KError::KittyRemote(format!("RC I/O error: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kitty::rpc::{DCS_PREFIX, DCS_TERMINATOR};
    use std::sync::Arc;
    use tempfile::tempdir;
    use tokio::io::AsyncReadExt;
    use tokio::net::UnixListener;
    use tokio::sync::oneshot;

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
            // Accept multiple connections for pool tests.
            loop {
                let (mut stream, _) = match listener.accept().await {
                    Ok(p) => p,
                    Err(_) => break,
                };
                let h = h.clone();
                tokio::spawn(async move {
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
                            let json_bytes =
                                &frame[DCS_PREFIX.len()..frame.len() - DCS_TERMINATOR.len()];
                            let req: Value =
                                serde_json::from_slice(json_bytes).expect("req parses");
                            if let Some(resp_json) = h(req) {
                                let resp_bytes = serde_json::to_vec(&resp_json).expect("ser");
                                let _ = stream.write_all(&encode_frame(&resp_bytes)).await;
                                let _ = stream.flush().await;
                            }
                        }
                    }
                });
            }
            let _ = done_tx.send(());
        });
        (sock, dir, done_rx)
    }

    /// Single-connection mock server (like rpc.rs tests). Accepts only one
    /// connection then shuts down.
    async fn spawn_single_mock_server<F>(
        handler: F,
    ) -> (PathBuf, tempfile::TempDir, oneshot::Receiver<()>)
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

    fn find_terminator(buf: &[u8]) -> Option<usize> {
        buf.windows(DCS_TERMINATOR.len())
            .position(|w| w == DCS_TERMINATOR)
    }

    // --- Basic pool tests ---

    #[tokio::test]
    async fn pool_connect_and_ls() {
        let (sock, _dir, _done) = spawn_single_mock_server(|req| {
            assert_eq!(req["cmd"], "ls");
            Some(json!({ "ok": true, "data": r#"[{"id": 5, "tabs": []}]"# }))
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let osws = pool.ls_all_env_vars().await.expect("ls ok");
        assert_eq!(osws.len(), 1);
        assert_eq!(osws[0].id, 5);
    }

    #[tokio::test]
    async fn pool_get_text() {
        let (sock, _dir, _done) = spawn_single_mock_server(|req| {
            assert_eq!(req["cmd"], "get_text");
            Some(json!({ "ok": true, "data": "hello\nworld" }))
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let txt = pool.get_text("id:7", "screen", false).await.expect("ok");
        assert_eq!(txt, "hello\nworld");
    }

    #[tokio::test]
    async fn pool_set_user_vars() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let saw = Arc::new(AtomicBool::new(false));
        let saw_h = saw.clone();
        let (sock, _dir, _done) = spawn_single_mock_server(move |req| {
            assert_eq!(req["cmd"], "set_user_vars");
            assert_eq!(req["payload"]["var"], json!(["k=v"]));
            saw_h.store(true, Ordering::SeqCst);
            None
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        pool.set_user_vars("id:1", &[("k", "v")]).await.expect("ok");
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(saw.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn pool_set_user_vars_many() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let count = Arc::new(AtomicUsize::new(0));
        let count_h = count.clone();
        let (sock, _dir, _done) = spawn_single_mock_server(move |req| {
            assert_eq!(req["cmd"], "set_user_vars");
            count_h.fetch_add(1, Ordering::SeqCst);
            None
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let entries: Vec<(String, Vec<(&str, &str)>)> = vec![
            ("id:1".into(), vec![("a", "1")]),
            ("id:2".into(), vec![("b", "2")]),
            ("id:3".into(), vec![("c", "3")]),
        ];
        pool.set_user_vars_many(entries).await.expect("burst ok");
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(count.load(Ordering::SeqCst), 3);
    }

    // --- Pool capacity & contention ---

    #[tokio::test]
    async fn pool_capacity_limits_concurrent_connections() {
        // With capacity=2, we should never have more than 2 in_use.
        use std::sync::atomic::{AtomicUsize, Ordering};
        let max_concurrent = Arc::new(AtomicUsize::new(0));
        let current = Arc::new(AtomicUsize::new(0));
        let max_h = max_concurrent.clone();
        let cur_h = current.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |_req| {
            let c = cur_h.fetch_add(1, Ordering::SeqCst) + 1;
            max_h.fetch_max(c, Ordering::SeqCst);
            // Simulate some work.
            std::thread::sleep(Duration::from_millis(10));
            cur_h.fetch_sub(1, Ordering::SeqCst);
            Some(json!({ "ok": true, "data": "ok" }))
        })
        .await;
        let pool = Arc::new(KittyPool::connect(&sock, 2).await.expect("connect"));

        let mut handles = vec![];
        for i in 0..6 {
            let p = pool.clone();
            handles.push(tokio::spawn(async move {
                p.get_text(&format!("id:{i}"), "screen", false)
                    .await
                    .expect("ok");
            }));
        }
        for h in handles {
            h.await.unwrap();
        }
        // max_concurrent should be at most 2 (the pool capacity).
        let max = max_concurrent.load(Ordering::SeqCst);
        assert!(
            max <= 2,
            "max concurrent connections was {max}, expected <= 2"
        );
    }

    #[tokio::test]
    async fn pool_in_use_counter_accuracy() {
        let (sock, _dir, _done) =
            spawn_mock_server(|_| Some(json!({ "ok": true, "data": "ok" }))).await;
        let pool = KittyPool::connect(&sock, 4).await.expect("connect");
        assert_eq!(pool.in_use(), 0);

        // Acquire a guard.
        let guard = pool.acquire().await.expect("acquire");
        assert_eq!(pool.in_use(), 1);

        // Drop it.
        drop(guard);
        assert_eq!(pool.in_use(), 0);

        // After a call, in_use should be 0 again.
        pool.get_text("id:1", "screen", false).await.expect("ok");
        assert_eq!(pool.in_use(), 0);
    }

    // --- Per-connection poison ---

    #[tokio::test]
    async fn pool_per_connection_poison_does_not_affect_others() {
        // Pool with capacity 2. One connection errors (poisoned), but the
        // other should still work. And a new connection should be dialled
        // to replace the poisoned one.
        let call_count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let call_count_h = call_count.clone();
        let (sock, _dir, _done) = spawn_mock_server(move |_req| {
            let n = call_count_h.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if n == 0 {
                // First call: return server error (non-poison, to show it works)
                Some(json!({ "ok": false, "error": "test error" }))
            } else {
                Some(json!({ "ok": true, "data": "ok" }))
            }
        })
        .await;
        let pool = KittyPool::connect(&sock, 2).await.expect("connect");

        // First call should error but not poison.
        let err = pool.get_text("id:1", "screen", false).await;
        assert!(err.is_err());

        // Second call should succeed (same or new connection).
        let ok = pool.get_text("id:2", "screen", false).await;
        assert!(ok.is_ok());
    }

    #[tokio::test]
    async fn pool_io_error_poisons_one_connection() {
        // Server drops immediately. The connection should be poisoned,
        // but a new acquire should dial fresh.
        let dir = tempdir().unwrap();
        let sock = dir.path().join("close.sock");
        let listener = UnixListener::bind(&sock).unwrap();

        // Accept connections but immediately close them.
        tokio::spawn(async move {
            loop {
                match listener.accept().await {
                    Ok((stream, _)) => drop(stream),
                    Err(_) => break,
                }
            }
        });

        let pool = KittyPool::connect(&sock, 2).await.expect("connect");
        tokio::time::sleep(Duration::from_millis(10)).await;

        // Calls will fail because the server keeps closing.
        // But the pool should keep trying to dial new connections (not
        // permanently poisoned like the old single-connection model).
        let err = pool.get_text("id:1", "screen", false).await;
        assert!(err.is_err());
        // in_use should be 0 after the failed call.
        assert_eq!(pool.in_use(), 0);
    }

    #[tokio::test]
    async fn pool_server_error_keeps_connection_alive() {
        // ok:false should NOT poison the connection.
        let counter = Arc::new(std::sync::Mutex::new(0u64));
        let counter_h = counter.clone();
        let (sock, _dir, _done) = spawn_single_mock_server(move |_| {
            let mut n = counter_h.lock().unwrap();
            *n += 1;
            if *n == 1 {
                Some(json!({ "ok": false, "error": "test error" }))
            } else {
                Some(json!({ "ok": true, "data": "later" }))
            }
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let err = pool
            .get_text("id:1", "screen", false)
            .await
            .expect_err("first errs");
        let KError::KittyRemote(m) = err else {
            panic!()
        };
        assert!(m.contains("test error"));

        // Connection should still work.
        let ok = pool
            .get_text("id:2", "screen", false)
            .await
            .expect("second ok");
        assert_eq!(ok, "later");
    }

    #[tokio::test]
    async fn pool_concurrent_calls_on_multi_connection_pool() {
        // With capacity > 1, multiple concurrent calls should each get
        // their own connection and all succeed.
        let (sock, _dir, _done) = spawn_mock_server(|req| {
            let match_ = req["payload"]["match"].as_str().unwrap_or("").to_string();
            Some(json!({ "ok": true, "data": format!("resp-{match_}") }))
        })
        .await;
        let pool = Arc::new(KittyPool::connect(&sock, 4).await.expect("connect"));

        let mut handles = vec![];
        for i in 0..4 {
            let p = pool.clone();
            handles.push(tokio::spawn(async move {
                p.get_text(&format!("id:{i}"), "screen", false)
                    .await
                    .expect("ok")
            }));
        }
        let mut results = vec![];
        for h in handles {
            results.push(h.await.unwrap());
        }
        results.sort();
        assert_eq!(
            results,
            vec!["resp-id:0", "resp-id:1", "resp-id:2", "resp-id:3"]
        );
    }

    #[tokio::test]
    async fn pool_ls_session() {
        let (sock, _dir, _done) = spawn_single_mock_server(|req| {
            assert_eq!(req["payload"]["output_format"], "session");
            Some(json!({ "ok": true, "data": "new_tab\nfocus\n" }))
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let s = pool.ls_session(false, true).await.expect("ok");
        assert_eq!(s, "new_tab\nfocus");
    }

    #[tokio::test]
    async fn pool_get_text_null_returns_empty() {
        let (sock, _dir, _done) =
            spawn_single_mock_server(|_| Some(json!({ "ok": true, "data": Value::Null }))).await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let txt = pool.get_text("id:99", "screen", false).await.expect("ok");
        assert_eq!(txt, "");
    }

    #[tokio::test]
    async fn pool_set_user_vars_empty_short_circuits() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let invoked = Arc::new(AtomicBool::new(false));
        let invoked_h = invoked.clone();
        let (sock, _dir, _done) = spawn_single_mock_server(move |_| {
            invoked_h.store(true, Ordering::SeqCst);
            None
        })
        .await;
        let pool = KittyPool::connect(&sock, 1).await.expect("connect");
        let empty: &[(&str, &str)] = &[];
        pool.set_user_vars("id:1", empty).await.expect("no-op ok");
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(!invoked.load(Ordering::SeqCst));
    }
}
