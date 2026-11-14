//! Fatal-path contract of `ksession tmux …`: exit code 1 and a
//! `ksession: tmux …` diagnostic on stderr for the user-facing failure
//! modes (design contract §Tests).

mod helpers;

use helpers::tmux::{assert_fatal, tmux_available, IsolatedTmux, Ksession};
use tempfile::tempdir;

#[test]
fn save_outside_tmux_without_session_is_fatal() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let root = tempdir().unwrap();
    // `Ksession::at` without `.inside(..)` scrubs the inherited `TMUX`.
    let out = Ksession::at(root.path()).run(&["save", "proj"]);
    assert_fatal(&out, "not inside tmux", "tmux save outside tmux");
    assert!(
        std::fs::read_dir(root.path()).unwrap().next().is_none(),
        "no artifacts may be written before the target is resolved"
    );
}

#[test]
fn invalid_name_is_reported_even_outside_tmux() {
    // The name is checked before any tmux target is resolved, so the user
    // hears about the real mistake rather than "not inside tmux".
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let root = tempdir().unwrap();
    let out = Ksession::at(root.path()).run(&["save", "bad name"]);
    assert_fatal(
        &out,
        "invalid session name",
        "tmux save 'bad name' outside tmux",
    );
}

#[test]
fn invalid_names_are_rejected_by_every_subcommand() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    let ks = Ksession::at(root.path()).inside(server.tmux_env());

    for bad in ["bad name", "../escape", "sl/ash"] {
        for sub in ["save", "restore", "show", "rm"] {
            let out = ks.run(&[sub, bad]);
            assert_fatal(&out, "invalid session name", &format!("tmux {sub} {bad:?}"));
        }
    }
    assert!(
        std::fs::read_dir(root.path()).unwrap().next().is_none(),
        "invalid names must not create anything under the root"
    );
}

#[test]
fn unknown_saved_session_is_not_found() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    let ks = Ksession::at(root.path()).inside(server.tmux_env());

    for sub in ["restore", "show", "rm"] {
        let out = ks.run(&[sub, "nope"]);
        assert_fatal(
            &out,
            "no saved tmux session 'nope'",
            &format!("tmux {sub} nope"),
        );
    }
}

#[test]
fn unknown_tmux_session_target_is_fatal() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    let out = Ksession::at(root.path()).inside(server.tmux_env()).run(&[
        "save",
        "proj",
        "--session",
        "no-such-session",
    ]);
    assert_fatal(
        &out,
        "no-such-session",
        "tmux save --session no-such-session",
    );
    assert!(
        !helpers::tmux::head_path(root.path(), "proj").exists(),
        "nothing saved for an unresolvable target"
    );
}
