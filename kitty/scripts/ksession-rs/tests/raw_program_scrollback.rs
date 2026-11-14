//! Regression tests for restoring `Program::Raw` windows (interactive agent
//! CLIs like `pi`, `omp`, `claude`).
//!
//! Two confirmed bugs are locked here:
//!
//! 1. Capture: programs using the setproctitle pattern rewrite their argv
//!    region for the process title, leaving a run of trailing NULs in
//!    `/proc/PID/cmdline`. A real saved manifest captured `pi` with a
//!    3545-element argv (one real element + 3544 empty strings).
//!    `proc::cmdline` must strip ALL trailing empty elements.
//!
//! 2. Restore: ADR 0007's cat-before-exec scrollback replay was being
//!    applied to `Program::Raw`, dumping the raw-ANSI transcript into the
//!    PTY before exec — visually rerunning the prior session and leaving
//!    the terminal in a dirty mode. Raw programs are excluded from the
//!    replay wrapper (ADR 0007 addendum 2026-06-09); their argv is emitted
//!    directly. Shell windows keep their replay chain.

use std::path::PathBuf;

use chrono::{TimeZone, Utc};
use ksession_rs::conf::render;
use ksession_rs::model::{OsWindow, Program, SessionFile, ShellKind, Tab, Window};
use ksession_rs::proc;
use pretty_assertions::assert_eq;
use tempfile::tempdir;

fn session_with(windows: Vec<Window>) -> SessionFile {
    SessionFile {
        name: "raw_sb".into(),
        created_at: Utc.with_ymd_and_hms(2026, 6, 9, 12, 0, 0).unwrap(),
        schema: 1,
        kitty_version: String::new(),
        os_windows: vec![OsWindow {
            tabs: vec![Tab {
                title: None,
                layout: "splits".into(),
                active_window_idx: 0,
                windows,
            }],
        }],
    }
}

/// Requirement: a `Program::Raw` window WITH a saved scrollback path renders
/// a launch line with NO cat/scrollback reference, exec-ing the argv
/// directly — while a `Program::Shell` window with scrollback in the same
/// session still gets its replay chain.
#[test]
fn raw_with_scrollback_renders_direct_argv_shell_keeps_replay() {
    let raw = Window {
        kitty_id: 1,
        ksession_id: "uid-raw".into(),
        cwd: None,
        program: Program::Raw {
            argv: vec!["pi".into()],
        },
        scrollback: Some(PathBuf::from("/state/scrollback/win-1.ansi")),
    };
    let shell = Window {
        kitty_id: 2,
        ksession_id: "uid-shell".into(),
        cwd: None,
        program: Program::Shell {
            shell: ShellKind::Bash,
            venv: None,
            conda: None,
            direnv: None,
            oldpwd: None,
            scrollback: Some(PathBuf::from("/state/scrollback/win-2.ansi")),
            history: None,
        },
        scrollback: Some(PathBuf::from("/state/scrollback/win-2.ansi")),
    };
    let session = session_with(vec![raw, shell]);

    let skel = "new_tab\nlayout splits\n\
        launch 'kitty-unserialize-data={\"id\": 1}'\n\
        launch 'kitty-unserialize-data={\"id\": 2}'\n\
        focus_tab 0\n";
    let out = render(skel, &session).expect("render");

    let raw_line = out
        .lines()
        .find(|l| l.contains("uid-raw"))
        .expect("raw launch line present");
    // (a) no cat / scrollback reference on the raw line.
    assert!(
        !raw_line.contains("cat") && !raw_line.contains("win-1.ansi"),
        "raw launch must not replay scrollback: {raw_line}"
    );
    assert!(
        !raw_line.contains("/bin/sh -c"),
        "raw launch must not be wrapped: {raw_line}"
    );
    // (b) execs the argv directly (with --hold per §C.4). `pi` is a known
    // agent CLI, so ADR 0008 appends `--continue` to resume its session.
    assert_eq!(
        raw_line,
        "launch --hold --var=ksession_id=uid-raw pi --continue"
    );

    // The shell window in the same render keeps its replay chain.
    let shell_line = out
        .lines()
        .find(|l| l.contains("uid-shell"))
        .expect("shell launch line present");
    assert_eq!(
        shell_line,
        "launch --var=ksession_id=uid-shell /bin/bash -l -c \
         'cat /state/scrollback/win-2.ansi 2>/dev/null; exec bash'"
    );
}

/// End-to-end across the two stages that compose the real pipeline (the
/// fixture save path goes through live /proc, so we compose the stages
/// directly): a /proc cmdline simulating the setproctitle pattern is parsed
/// by `proc::cmdline`, becomes a `Program::Raw`, and renders to a launch
/// line that is exactly `pi` — no empty-string args, no scrollback cat.
#[test]
fn setproctitle_capture_to_conf_round_trip() {
    // Stage 1: capture. /proc/4242/cmdline as left by setproctitle: one
    // real element + a run of trailing NULs (scaled like the real bug).
    let proc_root = tempdir().expect("tempdir");
    let pid_dir = proc_root.path().join("4242");
    std::fs::create_dir_all(&pid_dir).expect("mk pid dir");
    let mut bytes = b"pi".to_vec();
    bytes.extend(std::iter::repeat(0u8).take(3544));
    std::fs::write(pid_dir.join("cmdline"), bytes).expect("write cmdline");

    let argv = proc::cmdline(proc_root.path(), 4242).expect("cmdline readable");
    assert_eq!(argv, vec!["pi".to_string()], "trailing NULs stripped");

    // Stage 2: restore. The captured argv flows into Program::Raw with a
    // saved scrollback (capture is write-only for raw windows) and renders.
    let w = Window {
        kitty_id: 7,
        ksession_id: "uid-pi".into(),
        cwd: None,
        program: Program::Raw { argv },
        scrollback: Some(PathBuf::from("/state/scrollback/win-7.ansi")),
    };
    let session = session_with(vec![w]);
    let skel = "new_tab\nlayout splits\nlaunch 'kitty-unserialize-data={\"id\": 7}'\nfocus_tab 0\n";
    let out = render(skel, &session).expect("render");

    let line = out
        .lines()
        .find(|l| l.starts_with("launch"))
        .expect("launch line present");
    // ADR 0008 appends `--continue` for the agent CLI `pi`.
    assert_eq!(line, "launch --hold --var=ksession_id=uid-pi pi --continue");
    // kq renders an empty-string arg as '' — none may appear.
    assert!(
        !line.contains("''"),
        "no empty-string args may survive: {line}"
    );
    assert!(
        !out.contains("cat ") && !out.contains(".ansi"),
        "no scrollback replay anywhere in the conf: {out}"
    );
}
