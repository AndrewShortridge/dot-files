//! Conf-render integration tests for agent session resume (ADR 0008).
//!
//! `Program::Raw` windows whose exe basename is a known interactive agent
//! CLI (`claude`, `pi`, `opi`, `omp`) get `--continue` appended to their
//! restored argv so the agent resumes its prior conversation — these CLIs
//! key sessions by cwd, which ksession restores. The rewrite happens at
//! conf-render time so existing saved manifests benefit without a re-save.
//!
//! Skip conditions: argv already carrying a resume/session-selection flag,
//! a non-interactive flag (`-p`/`--print`), or `--no-session` (no session
//! was saved — resuming would pick up an unrelated one) renders unchanged.

use std::path::PathBuf;

use chrono::{TimeZone, Utc};
use ksession_rs::conf::render;
use ksession_rs::model::{OsWindow, Program, SessionFile, Tab, Window};
use pretty_assertions::assert_eq;

fn session_with(windows: Vec<Window>) -> SessionFile {
    SessionFile {
        name: "agent_resume".into(),
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

fn raw_window(id: u64, uid: &str, argv: &[&str], scrollback: Option<&str>) -> Window {
    Window {
        kitty_id: id,
        ksession_id: uid.into(),
        cwd: None,
        program: Program::Raw {
            argv: argv.iter().map(|s| s.to_string()).collect(),
        },
        scrollback: scrollback.map(PathBuf::from),
    }
}

/// Requirement: a saved `claude` window restores with `--continue` so the
/// conversation in that cwd resumes instead of starting fresh.
#[test]
fn claude_window_renders_launch_line_ending_continue() {
    let session = session_with(vec![raw_window(1, "uid-claude", &["claude"], None)]);
    let skel = "new_tab\nlayout splits\nlaunch 'kitty-unserialize-data={\"id\": 1}'\nfocus_tab 0\n";
    let out = render(skel, &session).expect("render");

    let line = out
        .lines()
        .find(|l| l.contains("uid-claude"))
        .expect("claude launch line present");
    assert_eq!(
        line,
        "launch --hold --var=ksession_id=uid-claude claude --continue"
    );
}

/// Requirement: an argv that already resumes (`pi -c`) renders unchanged —
/// no duplicate `--continue`.
#[test]
fn pi_with_existing_resume_flag_renders_unchanged() {
    let session = session_with(vec![raw_window(2, "uid-pi", &["pi", "-c"], None)]);
    let skel = "new_tab\nlayout splits\nlaunch 'kitty-unserialize-data={\"id\": 2}'\nfocus_tab 0\n";
    let out = render(skel, &session).expect("render");

    let line = out
        .lines()
        .find(|l| l.contains("uid-pi"))
        .expect("pi launch line present");
    assert_eq!(line, "launch --hold --var=ksession_id=uid-pi pi -c");
    assert!(
        !line.contains("--continue"),
        "no duplicate resume flag: {line}"
    );
}

/// Requirement: the resume rewrite composes with ADR 0007's addendum — an
/// agent window WITH a saved scrollback path gets `--continue` and still
/// NO cat-wrapper (raw TUIs need a clean PTY).
#[test]
fn agent_with_scrollback_gets_continue_and_no_cat_wrapper() {
    let session = session_with(vec![raw_window(
        3,
        "uid-omp",
        &["omp"],
        Some("/state/scrollback/win-3.ansi"),
    )]);
    let skel = "new_tab\nlayout splits\nlaunch 'kitty-unserialize-data={\"id\": 3}'\nfocus_tab 0\n";
    let out = render(skel, &session).expect("render");

    let line = out
        .lines()
        .find(|l| l.contains("uid-omp"))
        .expect("omp launch line present");
    assert!(
        !line.contains("cat") && !line.contains("win-3.ansi"),
        "agent launch must not replay scrollback: {line}"
    );
    assert!(
        !line.contains("/bin/sh -c"),
        "agent launch must not be wrapped: {line}"
    );
    assert_eq!(line, "launch --hold --var=ksession_id=uid-omp omp --continue");
}

/// Requirement: full-path argv[0] is matched via basename, and user args
/// survive with the resume flag appended after them.
#[test]
fn full_path_agent_with_user_args_appends_continue_last() {
    let session = session_with(vec![raw_window(
        4,
        "uid-opi",
        &["/home/andrew/.local/bin/opi", "--model", "gpt-5.2"],
        None,
    )]);
    let skel = "new_tab\nlayout splits\nlaunch 'kitty-unserialize-data={\"id\": 4}'\nfocus_tab 0\n";
    let out = render(skel, &session).expect("render");

    let line = out
        .lines()
        .find(|l| l.contains("uid-opi"))
        .expect("opi launch line present");
    assert_eq!(
        line,
        "launch --hold --var=ksession_id=uid-opi /home/andrew/.local/bin/opi --model gpt-5.2 --continue"
    );
}

/// Requirement: `--no-session` windows are left alone (no session was
/// saved; `--continue` would resume an unrelated conversation), and
/// non-agent raw programs are untouched.
#[test]
fn no_session_and_non_agent_windows_render_unchanged() {
    let session = session_with(vec![
        raw_window(5, "uid-nosess", &["pi", "--no-session"], None),
        raw_window(6, "uid-btop", &["btop"], None),
    ]);
    let skel = "new_tab\nlayout splits\n\
        launch 'kitty-unserialize-data={\"id\": 5}'\n\
        launch 'kitty-unserialize-data={\"id\": 6}'\n\
        focus_tab 0\n";
    let out = render(skel, &session).expect("render");

    let nosess = out
        .lines()
        .find(|l| l.contains("uid-nosess"))
        .expect("no-session launch line present");
    assert_eq!(
        nosess,
        "launch --hold --var=ksession_id=uid-nosess pi --no-session"
    );

    let btop = out
        .lines()
        .find(|l| l.contains("uid-btop"))
        .expect("btop launch line present");
    assert_eq!(btop, "launch --hold --var=ksession_id=uid-btop btop");
}
