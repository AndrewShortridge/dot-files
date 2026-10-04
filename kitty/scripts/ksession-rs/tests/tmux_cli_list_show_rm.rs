//! `ksession tmux list` / `show` / `rm` against a scratch tmux server, plus
//! the orphan sweep that `save` performs (design contract §Tests).
//!
//! `list --porcelain` is the picker's input, so its row format is asserted
//! byte-for-byte; the human table is asserted token-wise because column
//! padding depends on the widest cell.

mod helpers;

use std::path::Path;
use std::time::{Duration, SystemTime};

use helpers::tmux::{
    assert_fatal, assert_ok, assert_saved, head_path, state_dirs, stdout_str, tmux_available,
    IsolatedTmux, Ksession, ManifestView,
};
use tempfile::tempdir;

/// Seconds-precision UTC RFC 3339 (`2026-10-03T16:58:08Z`) — the stamp
/// format `list --porcelain` and `show` print.
fn stamp(m: &ManifestView) -> String {
    m.created_at().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// Save the bootstrap session `demo` (1 window / 1 pane) under `name`.
fn save(server: &IsolatedTmux, root: &Path, name: &str) {
    let out = Ksession::at(root)
        .inside(server.tmux_env())
        .run(&["save", name]);
    assert_saved(&out, &format!("tmux save {name}"));
}

#[test]
fn list_porcelain_rows_are_exact_and_sorted_by_name() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    let ks = Ksession::at(root.path()).inside(server.tmux_env());

    // Second session with 2 windows / 3 panes so the counts differ.
    server.run(&["new-session", "-d", "-s", "zeta"]);
    server.run(&["split-window", "-t", "zeta:0"]);
    server.run(&["new-window", "-t", "zeta"]);

    // Saved in reverse alphabetical order to prove the sort.
    save(&server, root.path(), "beta");
    let out = ks.run(&["save", "alpha", "--session", "zeta"]);
    assert_saved(&out, "tmux save alpha --session zeta");

    let alpha = ManifestView::load(root.path(), "alpha");
    let beta = ManifestView::load(root.path(), "beta");
    assert_eq!((alpha.window_count(), alpha.pane_count()), (2, 3));
    assert_eq!((beta.window_count(), beta.pane_count()), (1, 1));

    let out = ks.run(&["list", "--porcelain"]);
    assert_ok(&out, "tmux list --porcelain");
    let expected = format!(
        "alpha\tzeta\t2\t3\t{}\nbeta\tdemo\t1\t1\t{}\n",
        stamp(&alpha),
        stamp(&beta)
    );
    assert_eq!(
        stdout_str(&out),
        expected,
        "porcelain rows: name\\tsession\\twindows\\tpanes\\tcreated_at"
    );
}

#[test]
fn list_porcelain_on_empty_root_prints_nothing() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let root = tempdir().unwrap();
    let out = Ksession::at(root.path()).run(&["list", "--porcelain"]);
    assert_ok(&out, "tmux list --porcelain (empty)");
    assert_eq!(
        stdout_str(&out),
        "",
        "porcelain output must be empty, no header"
    );
}

#[test]
fn list_human_has_header_and_names() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    save(&server, root.path(), "proj");

    let out = Ksession::at(root.path()).run(&["list"]);
    assert_ok(&out, "tmux list");
    let stdout = stdout_str(&out);
    let mut lines = stdout.lines();
    let header: Vec<&str> = lines
        .next()
        .expect("header line")
        .split_whitespace()
        .collect();
    assert_eq!(
        header,
        ["NAME", "SESSION", "WINDOWS", "PANES", "SAVED", "NVIM"]
    );
    let row: Vec<&str> = lines
        .next()
        .expect("one data row")
        .split_whitespace()
        .collect();
    assert_eq!(
        &row[..4],
        ["proj", "demo", "1", "1"],
        "row columns: {stdout}"
    );
    assert_eq!(
        row.last(),
        Some(&"-"),
        "shell-only session has no nvim: {stdout}"
    );
}

#[test]
fn list_human_on_empty_root_says_so() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let root = tempdir().unwrap();
    let out = Ksession::at(root.path()).run(&["list"]);
    assert_ok(&out, "tmux list (empty)");
    assert_eq!(stdout_str(&out).trim(), "no saved tmux sessions");
}

#[test]
fn show_prints_header_lines_then_window_pane_tree() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    save(&server, root.path(), "proj");
    let m = ManifestView::load(root.path(), "proj");

    let out = Ksession::at(root.path()).run(&["show", "proj"]);
    assert_ok(&out, "tmux show proj");
    let stdout = stdout_str(&out);
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines[0], "session: proj", "{stdout}");
    assert_eq!(lines[1], "tmux session: demo", "{stdout}");
    assert_eq!(lines[2], format!("saved: {}", stamp(&m)), "{stdout}");
    assert_eq!(
        lines[3],
        format!("state: {}", m.state_dir().display()),
        "{stdout}"
    );
    assert_eq!(
        lines[4],
        format!("restore: {}", m.restore_sh().display()),
        "{stdout}"
    );
    let tree = lines[5..].join("\n");
    assert!(
        tree.contains("tmux window 0:"),
        "window row missing:\n{stdout}"
    );
    assert!(tree.contains("pane 0"), "pane row missing:\n{stdout}");
}

#[test]
fn rm_removes_head_and_state_dirs_then_reports_not_found() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();
    save(&server, root.path(), "proj");
    assert!(head_path(root.path(), "proj").is_file());
    assert_eq!(state_dirs(root.path(), "proj").len(), 1);

    let out = Ksession::at(root.path()).run(&["rm", "proj"]);
    assert_ok(&out, "tmux rm proj");
    assert!(!head_path(root.path(), "proj").exists(), "head removed");
    assert!(
        state_dirs(root.path(), "proj").is_empty(),
        "state dirs removed"
    );
    let leftovers: Vec<_> = std::fs::read_dir(root.path())
        .unwrap()
        .filter_map(Result::ok)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("proj"))
        .collect();
    assert!(
        leftovers.is_empty(),
        "no tombstones left behind: {leftovers:?}"
    );

    let out = Ksession::at(root.path()).run(&["rm", "proj"]);
    assert_fatal(&out, "no saved tmux session 'proj'", "second tmux rm proj");
}

#[test]
fn save_sweeps_stale_state_dirs_without_a_head() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let server = IsolatedTmux::new();
    let root = tempdir().unwrap();

    // An orphaned gen-stamped state dir (its `stale.json` never landed),
    // backdated past the sweep's 60 s in-flight grace period.
    let stale = root.path().join("stale.gen-1700000000000000.state");
    std::fs::create_dir_all(stale.join("tmux/old")).unwrap();
    std::fs::write(stale.join("tmux/old/restore.sh"), "#!/bin/bash\n").unwrap();
    let two_minutes_ago = SystemTime::now() - Duration::from_secs(120);
    for dir in [stale.join("tmux/old"), stale.join("tmux"), stale.clone()] {
        std::fs::File::open(&dir)
            .unwrap()
            .set_modified(two_minutes_ago)
            .expect("backdate orphan mtime");
    }

    save(&server, root.path(), "fresh");

    assert!(!stale.exists(), "orphaned state dir must be swept on save");
    assert_eq!(
        state_dirs(root.path(), "fresh").len(),
        1,
        "fresh save kept its own state dir"
    );
}
