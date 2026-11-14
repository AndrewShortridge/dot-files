//! Persistent msgpack-RPC connection to one running nvim.
//!
//! Owns the `UnixStream` half + the IO handle that nvim-rs spawns onto Tokio.
//! Dropping the connection lets nvim-rs tear down cleanly. Per Plan §5.3
//! the JoinHandle must be retained for the lifetime of `NvimConn` — dropping
//! it earlier silently kills the connection.
//!
//! The shape here is deliberately narrow: just the operations the per-window
//! capture path needs. Anything broader would invite scope creep — the
//! ksession.sh adapter only ever did two things: `:mksession!` and a buffer
//! dump.

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use futures::stream::{self, StreamExt};
use nvim_rs::{compat::tokio::Compat, create::tokio::new_path, Handler, Neovim, Value};
use tokio::{io::WriteHalf, net::UnixStream, task::JoinHandle};

use super::error::NvimError;
use crate::model::BufferDump;

/// Hard cap on modified-buffer payload, per Plan §5.3 "Size cap: 8 MiB per
/// buffer". Above this we write what we have, set `truncated: true`, and
/// surface a `vim.notify(...)` warning via the Lua loader at restore time.
pub const BUFFER_DUMP_BYTE_LIMIT: u64 = 8 * 1024 * 1024;

/// nvim-rs requires a `Handler` for incoming notifications from nvim.
/// We never use notifications — `:mksession!` and buffer dumps are pure
/// request/response — so the handler is a no-op marker type whose only
/// purpose is to pin the `Writer` associated type.
#[derive(Clone)]
pub(crate) struct NopHandler;

#[async_trait]
impl Handler for NopHandler {
    type Writer = Compat<WriteHalf<UnixStream>>;
}

/// A live RPC connection to one nvim.
///
/// `_io_handle` is kept alive deliberately — per Plan §5.3 dropping the
/// JoinHandle silently severs the connection without surfacing an error.
pub struct NvimConn {
    pub(crate) nvim: Neovim<Compat<WriteHalf<UnixStream>>>,
    #[allow(dead_code)]
    pub(crate) io_handle: JoinHandle<Result<(), Box<nvim_rs::error::LoopError>>>,
}

impl NvimConn {
    /// Connect over a Unix socket path. Returns immediately on transport
    /// error (no internal retry — caller decides how to degrade).
    pub async fn connect(sock: &Path) -> Result<Self, NvimError> {
        let (nvim, io_handle) = new_path(sock, NopHandler)
            .await
            .map_err(|e| NvimError::Socket(format!("{}: {e}", sock.display())))?;
        Ok(Self { nvim, io_handle })
    }

    /// Drive `:mksession!` on the open connection. Blocks until nvim returns
    /// (no polling — `nvim.command` is request/response). Verifies the file
    /// exists on success, mirroring the Bash `[[ -s "$out" ]]` post-check.
    pub async fn mksession(&self, out: &Path) -> Result<(), NvimError> {
        let mut _span = crate::perf_span!(crate::perf::Level::Debug, "nvim.rpc.mksession");
        let _ = std::fs::remove_file(out);
        // Path is user-controlled (cwd of the running nvim) — interpolating
        // it raw into an Ex command breaks on spaces, `%`, `#`, `|`, `"`,
        // `\`, etc. Build a vim double-quoted string literal for the path
        // and route through `fnameescape()` so vim handles its own special
        // chars per :h fnameescape.
        let escaped = vim_escape_string(&out.display().to_string());
        let cmd = format!("exec 'mksession! ' . fnameescape({})", escaped);
        let bytes_out = cmd.len();
        {
            // L5: nvim-rs bundles write + read + msgpack decode in one
            // await; we can't separate them, so this span covers the
            // entire wire round-trip.
            let _write_span =
                crate::perf_span!(crate::perf::Level::Trace, "nvim.rpc.write_msgpack");
            self.nvim
                .command(&cmd)
                .await
                .map_err(|e| NvimError::Rpc(format!("mksession: {e}")))?;
        }
        {
            let _decode_span =
                crate::perf_span!(crate::perf::Level::Trace, "nvim.rpc.decode_msgpack");
            if !out.exists() || std::fs::metadata(out).map(|m| m.len() == 0).unwrap_or(true) {
                return Err(NvimError::MksessionDidNothing(out.to_path_buf()));
            }
        }
        let bytes_in = std::fs::metadata(out).map(|m| m.len()).unwrap_or(0);
        if let Some(ref mut s) = _span {
            s.push_arg("bytes_out", format!("{}", bytes_out));
            s.push_arg("bytes_in", format!("{}", bytes_in));
        }
        Ok(())
    }

    /// Enumerate modified non-special buffers, dump each into `dumps_dir`,
    /// return the per-buffer manifest entries. Honours `BUFFER_DUMP_BYTE_LIMIT`
    /// — over-cap buffers are truncated rather than skipped (Plan §5.3
    /// "Skipping entirely is worse than partial restore").
    pub async fn dump_modified_buffers(
        &self,
        dumps_dir: &Path,
    ) -> Result<Vec<BufferDump>, NvimError> {
        let bufs = {
            let mut _span = crate::perf_span!(crate::perf::Level::Debug, "nvim.rpc.list_bufs");
            let result = {
                let _write_span =
                    crate::perf_span!(crate::perf::Level::Trace, "nvim.rpc.write_msgpack");
                self.nvim
                    .list_bufs()
                    .await
                    .map_err(|e| NvimError::Rpc(format!("list_bufs: {e}")))?
            };
            if let Some(ref mut s) = _span {
                s.push_arg("bytes_out", format!("{}", 16));
                s.push_arg("bytes_in", format!("{}", result.len() * 8));
            }
            result
        };
        std::fs::create_dir_all(dumps_dir)?;

        let fan_out = nvim_buf_fan_out();
        let nvim = self.nvim.clone();
        let dumps_dir_owned = dumps_dir.to_path_buf();

        // Save is read-only on nvim state. Concurrent reads of independent
        // buffers are safe because each buf_get_lines targets a different
        // buffer handle and nvim's msgpack-RPC demultiplexes by msgid.
        let results: Vec<Result<Option<BufferDump>, NvimError>> =
            stream::iter(bufs.into_iter().enumerate().map(|(i, buf)| {
                let nvim = nvim.clone();
                let dir = dumps_dir_owned.clone();
                async move { dump_single_buffer(&nvim, buf, i, &dir).await }
            }))
            .buffer_unordered(fan_out)
            .collect()
            .await;

        let mut dumps = Vec::new();
        for r in results {
            if let Some(dump) = r? {
                dumps.push(dump);
            }
        }
        Ok(dumps)
    }
}

/// Concurrency cap for per-buffer RPC calls within one nvim connection.
/// nvim's API handler is single-threaded -- going past ~4 produces no
/// further wall-clock improvement and increases response-queue depth.
/// Overridable via `KSESSION_NVIM_BUF_FAN_OUT` env var for bisection.
fn nvim_buf_fan_out() -> usize {
    std::env::var("KSESSION_NVIM_BUF_FAN_OUT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(4)
}

/// Process a single buffer: check modified/buftype, fetch lines, write dump.
/// Returns `Ok(Some(dump))` for modified normal buffers, `Ok(None)` for
/// buffers that should be skipped (unmodified or special buftype).
async fn dump_single_buffer(
    nvim: &Neovim<Compat<WriteHalf<UnixStream>>>,
    buf: nvim_rs::Buffer<Compat<WriteHalf<UnixStream>>>,
    index: usize,
    dumps_dir: &Path,
) -> Result<Option<BufferDump>, NvimError> {
    let buf_val = buf.get_value().clone();
    let buf_id_early = buf_id_from_value(&buf_val).unwrap_or(index as i64);
    let opts = vec![(Value::from("buf"), buf_val.clone())];

    let modified = {
        let _span = crate::perf_span!(
            crate::perf::Level::Debug,
            "nvim.rpc.buf_get_var",
            buf = buf_id_early,
            bytes_out = 24,
            bytes_in = 1,
        );
        let _write_span = crate::perf_span!(crate::perf::Level::Trace, "nvim.rpc.write_msgpack");
        nvim.get_option_value("modified", opts.clone())
            .await
            .map_err(|e| NvimError::Rpc(format!("get_option_value modified: {e}")))?
    };
    if !matches!(modified, Value::Boolean(true)) {
        return Ok(None);
    }

    let buftype = nvim
        .get_option_value("buftype", opts.clone())
        .await
        .map_err(|e| NvimError::Rpc(format!("get_option_value buftype: {e}")))?;
    let buftype_str = buftype.as_str().unwrap_or("");
    if !buftype_str.is_empty() {
        return Ok(None);
    }

    let name = buf
        .get_name()
        .await
        .map_err(|e| NvimError::Rpc(format!("buf get_name: {e}")))?;

    let filetype_val = nvim
        .get_option_value("filetype", opts)
        .await
        .map_err(|e| NvimError::Rpc(format!("get_option_value filetype: {e}")))?;
    let filetype = filetype_val.as_str().unwrap_or("").to_string();

    let lines = {
        let mut _span = crate::perf_span!(
            crate::perf::Level::Debug,
            "nvim.rpc.buf_get_lines",
            buf = buf_id_early,
        );
        let result = {
            let _write_span =
                crate::perf_span!(crate::perf::Level::Trace, "nvim.rpc.write_msgpack");
            buf.get_lines(0, -1, false)
                .await
                .map_err(|e| NvimError::Rpc(format!("buf get_lines: {e}")))?
        };
        if let Some(ref mut s) = _span {
            let bytes_in: usize = result.iter().map(|l| l.len() + 1).sum();
            s.push_arg("bytes_out", format!("{}", 24));
            s.push_arg("bytes_in", format!("{}", bytes_in));
        }
        result
    };

    let buf_id = buf_id_from_value(&buf_val).unwrap_or(index as i64);

    let limit = BUFFER_DUMP_BYTE_LIMIT;
    let mut kept: Vec<String> = Vec::with_capacity(lines.len());
    let mut running: u64 = 0;
    let mut truncated = false;
    for line in lines.iter() {
        let add = line.len() as u64 + 1;
        if running + add > limit {
            truncated = true;
            break;
        }
        running += add;
        kept.push(line.clone());
    }

    let mut joined = kept.join("\n");
    if !kept.is_empty() {
        joined.push('\n');
    }
    let byte_count = joined.len() as u64;

    let dump_filename = format!("buf-{buf_id}.txt");
    let abs_dump_path = dumps_dir.join(&dump_filename);
    std::fs::write(&abs_dump_path, &joined)?;

    // Store the dump path RELATIVE to the manifest's directory so the
    // state dir can be moved on disk without breaking restore. The
    // manifest sits at `<state>/nvim/win-<uid>.json`; `dumps_dir` is
    // `<state>/nvim/win-<uid>.dumps/` — i.e. a sibling of the
    // manifest. The relative path is therefore
    // `win-<uid>.dumps/buf-N.txt`.
    let rel_dump_path = dumps_dir
        .file_name()
        .and_then(|n| n.to_str())
        .map(|name| PathBuf::from(name).join(&dump_filename))
        .expect("dumps_dir must have a UTF-8 file_name (paths_for guarantees `win-<uid>.dumps`)");

    Ok(Some(BufferDump {
        buf_id,
        name,
        modified: true,
        filetype,
        dump_path: rel_dump_path,
        truncated,
        byte_count,
    }))
}

/// Wrap `s` as a vim double-quoted string literal, escaping `\` and `"`.
///
/// Vim double-quoted strings interpret backslash escapes (`\n`, `\t`, `\x..`,
/// `\"`), so any literal `\` or `"` in the path must be doubled / escaped.
/// Other bytes — including spaces, `%`, `#`, `|` — are not special inside a
/// vim string, so we don't touch them; their Ex-command significance is
/// neutralised by `fnameescape()` at the call site.
fn vim_escape_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

/// rmpv ExtType 0 = Buffer per nvim msgpack convention; the payload is a
/// single msgpack-encoded integer (the buffer handle).
fn buf_id_from_value(v: &Value) -> Option<i64> {
    let Value::Ext(_, bytes) = v else {
        return None;
    };
    let mut cursor = bytes.as_slice();
    rmpv::decode::read_value(&mut cursor).ok()?.as_i64()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Stdio;
    use std::time::Duration;
    use tempfile::tempdir;

    fn nvim_or_skip() -> Option<()> {
        if std::process::Command::new("nvim")
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .ok()?
            .success()
        {
            Some(())
        } else {
            None
        }
    }

    async fn spawn_nvim(sock: &Path) -> tokio::process::Child {
        spawn_nvim_with_dir(sock, None).await
    }

    /// Spawn nvim with proper swap file handling.
    ///
    /// Uses `-c` instead of `--cmd` to ensure settings are applied after all
    /// initializations. Also sets `directory` to a test-specific location
    /// to isolate swap files.
    async fn spawn_nvim_with_dir(sock: &Path, tmp_dir: Option<&Path>) -> tokio::process::Child {
        // Build nvim args with proper swap file handling:
        // 1. Use -c "set noswapfile" instead of --cmd (runs after all init)
        // 2. Set directory to temp location to isolate swap files
        let args: Vec<&str> = vec![
            "--headless",
            "--clean",
            "-u",
            "NORC",
            "--listen",
            sock.to_str().unwrap(),
        ];

        // Use -c for settings that need to run after init (more reliable than --cmd)
        // Disable swap files completely
        let noswapfile = "set noswapfile".to_string();
        let dir_arg: String;

        // Also set directory to prevent any swap file creation attempts
        // Use the temp directory if provided, otherwise use a path that will fail
        if let Some(dir) = tmp_dir {
            dir_arg = format!("set directory={}", dir.display());
        } else {
            // Fallback: set to non-existent path
            dir_arg = "set directory=/dev/null".to_string();
        }

        // Build the full args vec with all options
        let mut full_args: Vec<&str> = args.clone();
        full_args.push("-c");
        full_args.push(&noswapfile);
        full_args.push("-c");
        full_args.push(&dir_arg);

        let child = tokio::process::Command::new("nvim")
            .args(&full_args)
            .kill_on_drop(true)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn nvim");
        for _ in 0..80 {
            if sock.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(sock.exists(), "nvim socket never appeared at {sock:?}");
        child
    }

    #[tokio::test]
    async fn mksession_writes_file() {
        if nvim_or_skip().is_none() {
            eprintln!("skip: nvim not on PATH");
            return;
        }
        let tmp = tempdir().unwrap();
        let sock = tmp.path().join("nv.sock");
        let mut child = spawn_nvim(&sock).await;

        let conn = NvimConn::connect(&sock).await.expect("connect");
        let out = tmp.path().join("session.vim");
        conn.mksession(&out).await.expect("mksession");

        assert!(out.exists(), "session file not written");
        let meta = std::fs::metadata(&out).unwrap();
        assert!(meta.len() > 0, "session file is empty");
        let contents = std::fs::read_to_string(&out).unwrap();
        assert!(
            contents.contains("mksession") || contents.to_lowercase().contains("vim"),
            "session file looks bogus: {contents:?}"
        );

        drop(conn);
        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn mksession_error_when_path_unwritable() {
        if nvim_or_skip().is_none() {
            eprintln!("skip: nvim not on PATH");
            return;
        }
        let tmp = tempdir().unwrap();
        let sock = tmp.path().join("nv.sock");
        let mut child = spawn_nvim(&sock).await;

        let conn = NvimConn::connect(&sock).await.expect("connect");
        let out = tmp.path().join("nope/does/not/exist/session.vim");
        let err = conn.mksession(&out).await.expect_err("should fail");
        match err {
            NvimError::Rpc(_) | NvimError::MksessionDidNothing(_) => {}
            other => panic!("unexpected error variant: {other:?}"),
        }

        drop(conn);
        let _ = child.kill().await;
    }

    /// Regression: with `silent!` stripped from the mksession Ex command,
    /// errors from nvim (e.g. writing through a path whose parent is a
    /// regular file, not a directory) must propagate to the rust caller as
    /// `NvimError::Rpc(_)` rather than being swallowed and only caught by
    /// the post-write existence backstop. If this test ever starts hitting
    /// `MksessionDidNothing` instead, `silent!` (or equivalent) has crept
    /// back in.
    #[tokio::test]
    async fn mksession_error_propagates_when_parent_is_file() {
        if nvim_or_skip().is_none() {
            eprintln!("skip: nvim not on PATH");
            return;
        }
        let tmp = tempdir().unwrap();
        let sock = tmp.path().join("nv.sock");
        let mut child = spawn_nvim(&sock).await;

        // Create a regular file, then ask mksession to write *through* it
        // as if it were a directory. nvim's open() will fail with ENOTDIR
        // and emit an E-series error message, which `command()` now
        // surfaces (was swallowed by `silent!` previously).
        let blocker = tmp.path().join("not-a-dir");
        std::fs::write(&blocker, b"i am a file\n").expect("write blocker");
        let out = blocker.join("session.vim");

        let conn = NvimConn::connect(&sock).await.expect("connect");
        let err = conn.mksession(&out).await.expect_err("should fail");
        assert!(
            matches!(err, NvimError::Rpc(_)),
            "expected Rpc(_) propagated from nvim, got: {err:?}"
        );

        drop(conn);
        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn dump_modified_buffers_empty_when_no_modified() {
        if nvim_or_skip().is_none() {
            eprintln!("skip: nvim not on PATH");
            return;
        }
        let tmp = tempdir().unwrap();
        let sock = tmp.path().join("nv.sock");
        let mut child = spawn_nvim(&sock).await;

        let conn = NvimConn::connect(&sock).await.expect("connect");
        // Be explicit: a fresh buffer in some nvim versions reports modified=true
        // for the unnamed scratch buffer. Force it off so we're testing the
        // "no work" branch.
        let _ = conn.nvim.command("setlocal nomodified").await;
        let dumps_dir = tmp.path().join("dumps");
        let dumps = conn.dump_modified_buffers(&dumps_dir).await.expect("dump");
        assert!(
            dumps.is_empty(),
            "expected no modified buffers, got: {dumps:?}"
        );

        drop(conn);
        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn dump_modified_buffers_captures_unnamed_modified() {
        if nvim_or_skip().is_none() {
            eprintln!("skip: nvim not on PATH");
            return;
        }
        let tmp = tempdir().unwrap();
        // Clean up any pre-existing swap files in the temp directory
        let swap_glob = tmp.path().join("*.sw?");
        if let Ok(entries) = glob::glob(&swap_glob.to_string_lossy()) {
            for entry in entries.flatten() {
                let _ = std::fs::remove_file(entry);
            }
        }
        let sock = tmp.path().join("nv.sock");
        // Use spawn_nvim_with_dir to properly configure swap file handling
        let mut child = spawn_nvim_with_dir(&sock, Some(tmp.path())).await;

        let conn = NvimConn::connect(&sock).await.expect("connect");
        conn.nvim
            .command("call setline(1, ['hello', 'world'])")
            .await
            .expect("setline");
        conn.nvim
            .command("set modified")
            .await
            .expect("set modified");

        let dumps_dir = tmp.path().join("dumps");
        let dumps = conn.dump_modified_buffers(&dumps_dir).await.expect("dump");
        assert!(!dumps.is_empty(), "expected at least one modified buffer");
        let d = &dumps[0];
        assert!(d.modified);
        assert!(!d.truncated);
        // dump_path is now stored RELATIVE to the manifest's directory; the
        // manifest dir is the parent of `dumps_dir` per the production
        // layout (`<state>/nvim/win-<uid>.json` next to
        // `<state>/nvim/win-<uid>.dumps/`). Reconstruct the absolute path
        // by joining the manifest dir with the relative entry.
        let manifest_dir = dumps_dir.parent().unwrap();
        assert!(
            d.dump_path.is_relative(),
            "dump_path must be relative, got {:?}",
            d.dump_path
        );
        let abs = manifest_dir.join(&d.dump_path);
        assert!(abs.exists(), "dump file missing on disk at {abs:?}");
        let body = std::fs::read_to_string(&abs).unwrap();
        assert_eq!(body, "hello\nworld\n");
        assert_eq!(d.byte_count, body.len() as u64);

        drop(conn);
        let _ = child.kill().await;
    }

    #[test]
    fn vim_escape_string_plain_ascii() {
        assert_eq!(vim_escape_string("hello"), "\"hello\"");
    }

    #[test]
    fn vim_escape_string_with_space() {
        // Spaces aren't special inside a vim string literal — only the outer
        // Ex command parser cares, and fnameescape() handles that.
        assert_eq!(vim_escape_string("a b"), "\"a b\"");
        assert_eq!(
            vim_escape_string("/tmp/with space/session.vim"),
            "\"/tmp/with space/session.vim\""
        );
    }

    #[test]
    fn vim_escape_string_with_double_quote() {
        assert_eq!(vim_escape_string("a\"b"), "\"a\\\"b\"");
    }

    #[test]
    fn vim_escape_string_with_backslash() {
        assert_eq!(vim_escape_string("a\\b"), "\"a\\\\b\"");
    }

    #[test]
    fn vim_escape_string_with_both() {
        // Input: a\b"c  →  "a\\b\"c"
        assert_eq!(vim_escape_string("a\\b\"c"), "\"a\\\\b\\\"c\"");
    }

    #[tokio::test]
    async fn mksession_handles_path_with_space() {
        if nvim_or_skip().is_none() {
            eprintln!("skip: nvim not on PATH");
            return;
        }
        let tmp = tempdir().unwrap();
        let sock = tmp.path().join("nv.sock");
        let mut child = spawn_nvim(&sock).await;

        // Parent dir contains a space — this would break the old unquoted
        // `mksession! {path}` formatting.
        let spaced_dir = tmp.path().join("with space");
        std::fs::create_dir_all(&spaced_dir).expect("mkdir 'with space'");

        let conn = NvimConn::connect(&sock).await.expect("connect");
        let out = spaced_dir.join("session.vim");
        conn.mksession(&out)
            .await
            .expect("mksession into spaced dir");

        assert!(out.exists(), "session file not written at {out:?}");
        let meta = std::fs::metadata(&out).unwrap();
        assert!(meta.len() > 0, "session file is empty");

        drop(conn);
        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn dump_modified_buffers_truncates_oversized() {
        if nvim_or_skip().is_none() {
            eprintln!("skip: nvim not on PATH");
            return;
        }
        let tmp = tempdir().unwrap();
        // Clean up any pre-existing swap files in the temp directory
        let swap_glob = tmp.path().join("*.sw?");
        if let Ok(entries) = glob::glob(&swap_glob.to_string_lossy()) {
            for entry in entries.flatten() {
                let _ = std::fs::remove_file(entry);
            }
        }
        let sock = tmp.path().join("nv.sock");
        // Use spawn_nvim_with_dir to properly configure swap file handling
        let mut child = spawn_nvim_with_dir(&sock, Some(tmp.path())).await;

        let conn = NvimConn::connect(&sock).await.expect("connect");
        // Each line: 100 'x' chars + 1 newline = 101 bytes. 100_000 lines =
        // ~10.1 MiB > 8 MiB cap, so truncation must fire.
        conn.nvim
            .command("call setline(1, repeat([repeat('x', 100)], 100000))")
            .await
            .expect("setline big");
        conn.nvim
            .command("set modified")
            .await
            .expect("set modified");

        let dumps_dir = tmp.path().join("dumps");
        let dumps = conn.dump_modified_buffers(&dumps_dir).await.expect("dump");
        let big = dumps
            .iter()
            .find(|d| d.truncated)
            .expect("expected at least one truncated dump");
        assert!(big.byte_count <= BUFFER_DUMP_BYTE_LIMIT);
        // dump_path is relative to the manifest dir (parent of dumps_dir).
        let manifest_dir = dumps_dir.parent().unwrap();
        assert!(
            big.dump_path.is_relative(),
            "dump_path must be relative, got {:?}",
            big.dump_path
        );
        let abs = manifest_dir.join(&big.dump_path);
        let on_disk = std::fs::metadata(&abs).unwrap().len();
        assert!(on_disk <= BUFFER_DUMP_BYTE_LIMIT);
        assert_eq!(on_disk, big.byte_count);

        drop(conn);
        let _ = child.kill().await;
    }
}
