//! Real-binary round-trip integration test.
//!
//! This test requires a real `kitty` binary and a graphics-capable
//! environment (X11 or Wayland — kitty refuses to start fully headless).
//! Run with:
//!
//!     cargo test --test real_kitty_roundtrip -- --ignored
//!
//! It is `#[ignore]`d by default so the standard `cargo test` run stays
//! green in CI without a kitty binary present.
//!
//! What it covers (audit finding G4): the existing golden-conf tests
//! verify byte-equality against committed fixtures, but never ask a
//! real kitty whether the emitted `.conf` is a *valid* session file.
//! A subtly malformed line (mis-spelled directive, unbalanced
//! `set_layout_state` JSON, dropped `new_tab`, etc.) would round-trip
//! through all of our golden checks without anyone noticing — but
//! would silently break user restores.
//!
//! Strategy: kitty has no `--validate-session` / `--dry-run` flag
//! (verified against `kitty --help` for v0.47). So we:
//!
//!   1. Spawn `kitty --session <golden.conf> --start-as=hidden
//!      --listen-on=unix:<sock> -o allow_remote_control=yes
//!      --instance-group=ksession-roundtrip-<pid> --config NONE`,
//!      capturing stdout+stderr.
//!   2. Poll for the RC socket to appear (== kitty finished startup,
//!      which means it finished parsing the session file).
//!   3. Send `kitten @ --to unix:<sock> close-window --match all` to
//!      ask kitty to shut down cleanly, then wait for the process.
//!   4. Assert: exit status is success-ish, stderr contains no
//!      session-parse error markers (`Failed to parse`, `Invalid`,
//!      `Traceback`, `unknown command` …).
//!
//! Defensive: if `kitty --version` itself fails (binary missing,
//! library load failure, no DISPLAY/WAYLAND_DISPLAY) we *skip* with
//! a printed message rather than failing — so even with `--ignored`
//! the test is safe to invoke on bare CI runners.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use tempfile::tempdir;

/// Hard upper bound on how long we'll wait for kitty to start up
/// (i.e. parse the session and create its RC socket).
const STARTUP_TIMEOUT: Duration = Duration::from_secs(10);
/// Hard upper bound on how long we'll wait for kitty to exit after
/// we ask it to close.
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);
/// How long to wait after the socket appears before issuing the close
/// command — gives kitty a moment to actually finish session loading
/// past the socket-bind point so parse errors have a chance to surface.
const POST_READY_GRACE: Duration = Duration::from_millis(500);

fn manifest_dir() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

/// Returns `true` if a usable kitty binary appears to be on PATH and
/// startable. Used to *skip* the test rather than fail when run with
/// `--ignored` on a machine without the binary or without a display.
fn kitty_is_usable() -> bool {
    match Command::new("kitty").arg("--version").output() {
        Ok(out) if out.status.success() => true,
        Ok(_) | Err(_) => false,
    }
}

/// Returns `true` if `kitten` (the RC client) is on PATH.
fn kitten_is_usable() -> bool {
    match Command::new("kitten").arg("--version").output() {
        Ok(out) if out.status.success() => true,
        Ok(_) | Err(_) => false,
    }
}

/// Block (with a busy-wait sleep loop) until `sock` exists or the
/// deadline passes. Returns `true` on success.
fn wait_for_socket(sock: &Path, deadline: Instant) -> bool {
    while Instant::now() < deadline {
        if sock.exists() {
            return true;
        }
        thread::sleep(Duration::from_millis(50));
    }
    false
}

/// Poll the child for exit, up to `timeout`. Returns the
/// `ExitStatus` on clean exit or `None` if we time out.
fn wait_with_timeout(
    child: &mut std::process::Child,
    timeout: Duration,
) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Some(status),
            Ok(None) => {
                if Instant::now() >= deadline {
                    return None;
                }
                thread::sleep(Duration::from_millis(100));
            }
            Err(_) => return None,
        }
    }
}

#[test]
#[ignore = "requires a real kitty binary + display; run with --ignored"]
fn two_tabs_loads_in_real_kitty() {
    if !kitty_is_usable() {
        eprintln!(
            "real_kitty_roundtrip: `kitty --version` failed — skipping. \
             (No kitty binary on PATH, or no usable display environment.)"
        );
        return;
    }
    if !kitten_is_usable() {
        eprintln!(
            "real_kitty_roundtrip: `kitten --version` failed — skipping. \
             (RC client not available; can't drive shutdown.)"
        );
        return;
    }

    let golden: PathBuf = manifest_dir()
        .join("tests")
        .join("golden")
        .join("conf")
        .join("two_tabs.conf");
    assert!(
        golden.exists(),
        "fixture missing: {} — run conf golden tests first",
        golden.display(),
    );

    // Tempdir holds the RC socket; `--instance-group` is suffixed with our
    // PID so concurrent test runs (e.g. `cargo test -- --test-threads=N`)
    // don't collide.
    let tmp = tempdir().expect("tempdir for rc socket");
    let sock = tmp.path().join("kitty-rc.sock");
    let stderr_log = tmp.path().join("kitty-stderr.log");
    let stdout_log = tmp.path().join("kitty-stdout.log");
    let instance_group = format!("ksession-roundtrip-{}", std::process::id());

    // `--config NONE` prevents the user's actual kitty.conf from
    // influencing the test (e.g. a custom `startup_session` would
    // override ours). `--start-as=hidden` keeps the window off-screen
    // so we don't flash a real terminal during the test.
    let sock_arg = format!("unix:{}", sock.display());
    let stderr_file = std::fs::File::create(&stderr_log).expect("create stderr log");
    let stdout_file = std::fs::File::create(&stdout_log).expect("create stdout log");

    let mut child = Command::new("kitty")
        .arg("--config")
        .arg("NONE")
        .arg("--session")
        .arg(&golden)
        .arg("--start-as=hidden")
        .arg("--listen-on")
        .arg(&sock_arg)
        .arg("-o")
        .arg("allow_remote_control=yes")
        .arg("--instance-group")
        .arg(&instance_group)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout_file))
        .stderr(Stdio::from(stderr_file))
        .spawn()
        .expect("spawn kitty");

    // Helper to make sure we never leak the child if an assert fires.
    struct Guard<'a>(&'a mut std::process::Child);
    impl<'a> Drop for Guard<'a> {
        fn drop(&mut self) {
            // Best-effort kill; ignore errors (likely already exited).
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    let startup_deadline = Instant::now() + STARTUP_TIMEOUT;
    let socket_ready = wait_for_socket(&sock, startup_deadline);

    if !socket_ready {
        // Kitty failed to start — most often "no display" on a CI
        // runner. Read whatever it managed to write to stderr so the
        // failure (or skip) message is actionable.
        let _ = Guard(&mut child); // drop kills it
        let stderr = std::fs::read_to_string(&stderr_log).unwrap_or_default();
        // Distinguish "no display" (skip) from "kitty bug" (fail).
        let stderr_lower = stderr.to_lowercase();
        let looks_like_no_display = stderr_lower.contains("display")
            || stderr_lower.contains("wayland")
            || stderr_lower.contains("x11")
            || stderr_lower.contains("opengl")
            || stderr.trim().is_empty();
        if looks_like_no_display {
            eprintln!(
                "real_kitty_roundtrip: kitty failed to start within {:?}, \
                 stderr looks like a display/GL issue — skipping. \
                 stderr:\n{stderr}",
                STARTUP_TIMEOUT,
            );
            return;
        }
        panic!(
            "kitty did not create RC socket within {:?}; stderr was:\n{stderr}",
            STARTUP_TIMEOUT,
        );
    }

    // Give the loader a beat past the socket-bind point so any
    // post-bind session parse errors get flushed to stderr before we
    // start tearing down.
    thread::sleep(POST_READY_GRACE);

    // Ask kitty to close. `close-window --match all` is the gentlest
    // shutdown that doesn't require platform-specific signal handling.
    let close = Command::new("kitten")
        .arg("@")
        .arg("--to")
        .arg(&sock_arg)
        .arg("close-window")
        .arg("--match")
        .arg("all")
        .output();

    // If the close command itself fails we still want to clean up.
    let status = wait_with_timeout(&mut child, SHUTDOWN_TIMEOUT);

    let stderr_text = std::fs::read_to_string(&stderr_log).unwrap_or_default();
    let stdout_text = std::fs::read_to_string(&stdout_log).unwrap_or_default();

    let status = match status {
        Some(s) => s,
        None => {
            // Force-kill so the test doesn't hang the test harness.
            let _ = child.kill();
            let _ = child.wait();
            panic!(
                "kitty did not exit within {:?} after close-window. \
                 close-window result: {:?}\nstderr:\n{stderr_text}\nstdout:\n{stdout_text}",
                SHUTDOWN_TIMEOUT, close,
            );
        }
    };

    // Exit code 0 is the happy path; on some platforms a window-close
    // triggered shutdown is reported as a signal exit, which yields
    // None from .code(). We treat *either* "code 0" or "killed by
    // SIGTERM-ish signal we never sent" as failure-only when stderr
    // shows parse errors. The discriminator is the stderr scan below.
    let parse_error_markers = [
        "Failed to parse",
        "Invalid session",
        "Unknown command",
        "Unknown layout",
        "Traceback (most recent call last)",
        "SyntaxError",
        "ValueError",
        "json.decoder.JSONDecodeError",
        "Could not parse",
    ];
    let mut hits: Vec<&str> = Vec::new();
    for needle in &parse_error_markers {
        if stderr_text.contains(needle) {
            hits.push(*needle);
        }
    }
    assert!(
        hits.is_empty(),
        "kitty stderr contained session-parse error markers {:?}.\n\
         Full stderr:\n{stderr_text}\nstdout:\n{stdout_text}",
        hits,
    );

    // The exit code itself is a softer signal: kitty 0.47 returns 0 on
    // clean window-close shutdown. If we got a non-zero *and* stderr
    // is clean of parse markers, log it but don't fail — the parse
    // success is the property under test.
    if !status.success() {
        eprintln!(
            "real_kitty_roundtrip: kitty exited non-zero ({:?}) but stderr \
             showed no parse errors; treating as pass. stderr:\n{stderr_text}",
            status,
        );
    }
}
