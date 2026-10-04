//! `ksession tmux save --auto` naming and `ksession tmux autosave`
//! throttling against a scratch tmux server (design contract §Tests).
//!
//! `autosave` is wired into `status-right` `#()` and the `client-detached`
//! hook, so beyond the stamp semantics every invocation must keep stdout
//! empty — anything printed there would end up in the status line.

mod helpers;

use std::path::Path;

use helpers::tmux::{
    assert_ok, assert_saved, head_path, state_dirs, stdout_str, tmux_available, IsolatedTmux,
    Ksession, ManifestView,
};
use tempfile::tempdir;

const STAMP: &str = ".autosave-stamp";

fn sorted_heads(root: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(root)
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|e| {
            e.file_name()
                .to_str()
                .and_then(|n| n.strip_suffix(".json"))
                .map(str::to_string)
        })
        .collect();
    names.sort();
    names
}

#[test]
fn save_auto_names_after_sanitised_session_name() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    server.run(&["new-session", "-d", "-s", "my session!"]);

    let out = Ksession::at(root.path()).inside(server.tmux_env()).run(&[
        "save",
        "--auto",
        "--session",
        "my session!",
    ]);
    assert_saved(&out, "tmux save --auto --session 'my session!'");

    // Every character outside [A-Za-z0-9._-] becomes `-`.
    assert!(
        head_path(root.path(), "auto-my-session-").is_file(),
        "expected auto-my-session-.json, root has {:?}",
        sorted_heads(root.path())
    );
    let m = ManifestView::load(root.path(), "auto-my-session-");
    assert_eq!(m.name(), "auto-my-session-");
    assert_eq!(
        m.session_name(),
        "my session!",
        "original session name kept in the manifest"
    );
}

#[test]
fn save_auto_all_saves_every_session_on_the_server() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    server.run(&["new-session", "-d", "-s", "work"]);

    let out = Ksession::at(root.path())
        .inside(server.tmux_env())
        .run(&["save", "--auto", "--all"]);
    assert_saved(&out, "tmux save --auto --all");

    assert_eq!(sorted_heads(root.path()), ["auto-demo", "auto-work"]);
    assert_eq!(
        ManifestView::load(root.path(), "auto-demo").session_name(),
        "demo"
    );
    assert_eq!(
        ManifestView::load(root.path(), "auto-work").session_name(),
        "work"
    );
}

#[test]
fn autosave_touches_stamp_and_is_throttled_until_forced() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    let ks = Ksession::at(root.path()).inside(server.tmux_env());
    let stamp = root.path().join(STAMP);

    // First run: saves every session and drops the stamp.
    let out = ks.run(&["autosave"]);
    assert_saved(&out, "tmux autosave (first)");
    assert!(
        stdout_str(&out).is_empty(),
        "autosave must never write stdout"
    );
    assert!(stamp.is_file(), "autosave writes {STAMP}");
    assert_eq!(sorted_heads(root.path()), ["auto-demo"]);
    let first = ManifestView::load(root.path(), "auto-demo");
    let first_bytes = std::fs::read(head_path(root.path(), "auto-demo")).unwrap();

    // Second run inside the default 15 m window: a silent no-op.
    let out = ks.run(&["autosave"]);
    assert_ok(&out, "tmux autosave (throttled)");
    assert!(
        stdout_str(&out).is_empty(),
        "throttled autosave must stay silent"
    );
    assert_eq!(
        std::fs::read(head_path(root.path(), "auto-demo")).unwrap(),
        first_bytes,
        "throttled autosave must not rewrite the manifest"
    );
    assert_eq!(state_dirs(root.path(), "auto-demo").len(), 1);

    // --force bypasses the stamp: a new capture lands (new gen-stamped
    // state dir, created_at not older than before) and the old one is
    // retired. Retirement is age-guarded (a sibling younger than the
    // sweep minimum may belong to a concurrent save), so the first state
    // dir is aged past that minimum here to observe it.
    backdate(&first.state_dir());
    let out = ks.run(&["autosave", "--force"]);
    assert_saved(&out, "tmux autosave --force");
    assert!(
        stdout_str(&out).is_empty(),
        "forced autosave must stay silent"
    );
    let forced = ManifestView::load(root.path(), "auto-demo");
    assert_ne!(
        forced.state_dir(),
        first.state_dir(),
        "--force re-saves into a new state dir"
    );
    assert!(
        forced.created_at() >= first.created_at(),
        "created_at moves forward"
    );
    assert_eq!(
        state_dirs(root.path(), "auto-demo"),
        vec![forced.state_dir()],
        "re-save retires the aged state dir and leaves exactly the new one"
    );
}

#[test]
fn re_save_keeps_a_young_sibling_state_dir() {
    // Two saves of the same name can overlap (status tick + detach hook);
    // a state dir younger than the sweep minimum is never deleted by a
    // sibling save because it may be that save's uncommitted capture.
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    let ks = Ksession::at(root.path()).inside(server.tmux_env());

    assert_saved(&ks.run(&["save", "--auto"]), "tmux save --auto (first)");
    let first = ManifestView::load(root.path(), "auto-demo");
    assert_saved(&ks.run(&["save", "--auto"]), "tmux save --auto (second)");
    let second = ManifestView::load(root.path(), "auto-demo");

    assert_ne!(first.state_dir(), second.state_dir());
    let mut expected = vec![first.state_dir(), second.state_dir()];
    expected.sort();
    assert_eq!(
        state_dirs(root.path(), "auto-demo"),
        expected,
        "young sibling survives; the orphan sweep reclaims it later"
    );
}

/// Age a state dir past the sweep minimum (60 s) so a re-save may retire it.
fn backdate(dir: &Path) {
    let old = std::time::SystemTime::now() - std::time::Duration::from_secs(120);
    std::fs::File::open(dir).unwrap().set_modified(old).unwrap();
}
