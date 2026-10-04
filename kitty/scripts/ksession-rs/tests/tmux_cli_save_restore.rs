//! End-to-end `ksession tmux save` / `ksession tmux restore` against a
//! scratch tmux server (design contract §Tests).
//!
//! The binary is driven exactly as the tmux key bindings drive it:
//! `KSESSION_TMUX_SESSIONS_DIR` points at a private root and `TMUX` is
//! set to the scratch server's `<socket>,<pid>,<sid>` so the binary
//! resolves the target session "from inside tmux".
//!
//! Restore caveat: `restore.sh` ends in `exec tmux switch-client` when
//! `$TMUX` is set, and no client is attached to a headless scratch server,
//! so that final exec fails and the binary's exit status is not
//! meaningful here. The tests therefore assert the *effect* — the session
//! exists again with the saved windows, panes, cwds and pane geometry —
//! and never the restore exit code.

mod helpers;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use helpers::tmux::{
    assert_saved, find_files_named, state_dirs, stderr_str, tmux_available, IsolatedTmux, Ksession,
    ManifestView,
};
use tempfile::{tempdir, TempDir};

/// Scratch server holding a 2-window / 3-pane session named `demo` whose
/// panes sit in three distinct tempdirs and whose first window uses the
/// non-default `main-vertical` layout. Keeps the tempdirs alive so the
/// restored shells can `cd` into them again.
struct Workspace {
    server: IsolatedTmux,
    /// Canonical pane cwds, sorted — what `#{pane_current_path}` reports.
    cwds: Vec<String>,
    _dirs: Vec<TempDir>,
}

impl Workspace {
    const SESSION: &'static str = "demo";

    fn spawn() -> Self {
        let dirs: Vec<TempDir> = (0..3)
            .map(|_| tempdir().expect("pane cwd tempdir"))
            .collect();
        let canon: Vec<PathBuf> = dirs
            .iter()
            .map(|d| std::fs::canonicalize(d.path()).expect("canonicalize pane cwd"))
            .collect();

        // 200×50 so `main-vertical` yields a visibly non-even split
        // (80-column main pane + 119-column side pane) instead of the
        // 1-column degenerate case an 80×24 window produces.
        let server = IsolatedTmux::builder(Self::SESSION)
            .size(200, 50)
            .cwd(&canon[0])
            .spawn();
        server.run(&[
            "split-window",
            "-t",
            "demo:0",
            "-c",
            canon[1].to_str().unwrap(),
        ]);
        server.run(&["select-layout", "-t", "demo:0", "main-vertical"]);
        server.run(&["new-window", "-t", "demo", "-c", canon[2].to_str().unwrap()]);

        // Seed every pane with a marker line so scrollback capture has
        // bytes to write (zero-byte captures are dropped by the adapter).
        for (target, marker) in [
            ("demo:0.0", "marker-w0-p0"),
            ("demo:0.1", "marker-w0-p1"),
            ("demo:1.0", "marker-w1-p0"),
        ] {
            server.run(&[
                "send-keys",
                "-t",
                target,
                &format!("echo {marker}"),
                "Enter",
            ]);
        }
        for (target, marker) in [
            ("demo:0.0", "marker-w0-p0"),
            ("demo:0.1", "marker-w0-p1"),
            ("demo:1.0", "marker-w1-p0"),
        ] {
            server.wait_for_pane_text(target, marker, Duration::from_secs(10));
        }

        let mut cwds: Vec<String> = canon
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        cwds.sort();
        Self {
            server,
            cwds,
            _dirs: dirs,
        }
    }

    fn ksession(&self, root: &Path) -> Ksession {
        Ksession::at(root).inside(self.server.tmux_env())
    }

    fn window_count(&self) -> usize {
        self.server
            .run(&["list-windows", "-t", Self::SESSION, "-F", "#{window_index}"])
            .lines()
            .count()
    }

    /// Sorted `left,top,width,height` of every pane — the geometry that
    /// `select-layout <saved layout>` must reproduce. Pane ids are not
    /// part of it because they are reallocated across a kill/restore.
    fn pane_rects(&self) -> Vec<String> {
        let mut rects: Vec<String> = self
            .server
            .run(&[
                "list-panes",
                "-s",
                "-t",
                Self::SESSION,
                "-F",
                "#{window_index}:#{pane_left},#{pane_top},#{pane_width},#{pane_height}",
            ])
            .lines()
            .map(str::to_string)
            .collect();
        rects.sort();
        rects
    }

    /// Sorted live `#{pane_current_path}` of every pane.
    fn live_cwds(&self) -> Vec<String> {
        let mut cwds: Vec<String> = self
            .server
            .run(&[
                "list-panes",
                "-s",
                "-t",
                Self::SESSION,
                "-F",
                "#{pane_current_path}",
            ])
            .lines()
            .map(str::to_string)
            .collect();
        cwds.sort();
        cwds
    }
}

fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|m| m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// The shipped tmux.conf runs `ksession tmux autosave --force` from the
/// `client-detached` hook. A save that attached a (control-mode) client
/// would therefore trigger itself on detach, forever. Pin: a save fires
/// no client hook on the server it captures.
#[test]
fn save_never_attaches_a_client_so_detach_hooks_stay_quiet() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let ws = Workspace::spawn();
    let root = tempdir().unwrap();
    let marker = root.path().join("client-detached.fired");
    ws.server.run(&[
        "set-hook",
        "-g",
        "client-detached",
        &format!("run-shell \"touch {}\"", marker.display()),
    ]);

    let out = ws.ksession(root.path()).run(&["save", "proj"]);
    assert_saved(&out, "tmux save proj");
    std::thread::sleep(Duration::from_millis(300));

    assert!(
        !marker.exists(),
        "save attached and detached a tmux client; the client-detached hook fired"
    );
    assert_eq!(
        ws.server.run(&["list-clients", "-F", "#{client_name}"]),
        "",
        "save must leave no client behind"
    );
}

#[test]
fn save_captures_windows_panes_cwds_layout_and_scrollback() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let ws = Workspace::spawn();
    let root = tempdir().unwrap();
    let layout_before = ws.server.display("demo:0", "#{window_layout}");

    let out = ws.ksession(root.path()).run(&["save", "proj"]);
    assert_saved(&out, "tmux save proj");

    let m = ManifestView::load(root.path(), "proj");
    assert_eq!(m.name(), "proj");
    assert_eq!(m.schema(), 1, "manifest schema must be 1");
    assert_eq!(m.program_kind(), "tmux", "program must be Program::Tmux");
    assert_eq!(m.session_name(), Workspace::SESSION);
    assert!(!m.tmux_version().is_empty(), "tmux_version must be stamped");
    assert_eq!(m.window_count(), 2, "two windows captured: {}", m.0);
    assert_eq!(m.pane_count(), 3, "three panes captured: {}", m.0);
    assert_eq!(m.pane_cwds(), ws.cwds, "pane cwds captured verbatim");
    assert_eq!(
        m.window_layout(0),
        layout_before,
        "window 0 layout string captured verbatim"
    );

    // State dir: absolute, under the root, gen-stamped, and the only one.
    let state_dir = m.state_dir();
    assert!(
        state_dir.is_absolute(),
        "state_dir must be absolute: {}",
        state_dir.display()
    );
    assert!(
        state_dir.starts_with(root.path()),
        "state_dir under root: {}",
        state_dir.display()
    );
    assert!(
        state_dir.is_dir(),
        "state_dir exists: {}",
        state_dir.display()
    );
    assert_eq!(state_dirs(root.path(), "proj"), vec![state_dir.clone()]);
    let basename = state_dir.file_name().unwrap().to_str().unwrap();
    assert!(
        basename.starts_with("proj.gen-") && basename.ends_with(".state"),
        "gen-stamped basename, got {basename}"
    );

    // restore.sh: inside the state dir, present, executable.
    let restore_sh = m.restore_sh();
    assert!(
        restore_sh.starts_with(&state_dir),
        "restore.sh under state_dir"
    );
    assert!(
        restore_sh.is_file(),
        "restore.sh exists: {}",
        restore_sh.display()
    );
    assert!(is_executable(&restore_sh), "restore.sh is executable");

    // Scrollback: one sidecar per pane under tmux/<session>/.
    let scrollbacks = find_files_named(
        &state_dir.join("tmux").join(Workspace::SESSION),
        "scrollback.ansi",
    );
    assert_eq!(
        scrollbacks.len(),
        3,
        "one scrollback.ansi per pane, got {scrollbacks:?}"
    );
}

#[test]
fn save_no_scrollback_writes_no_sidecars() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let ws = Workspace::spawn();
    let root = tempdir().unwrap();

    let out = ws
        .ksession(root.path())
        .run(&["save", "quiet", "--no-scrollback"]);
    assert_saved(&out, "tmux save quiet --no-scrollback");

    let m = ManifestView::load(root.path(), "quiet");
    assert_eq!(m.pane_count(), 3);
    let scrollbacks = find_files_named(&m.state_dir(), "scrollback.ansi");
    assert!(
        scrollbacks.is_empty(),
        "--no-scrollback must not write sidecars: {scrollbacks:?}"
    );
    assert!(m.restore_sh().is_file(), "restore.sh still rendered");
}

#[test]
fn restore_rebuilds_killed_session_and_honours_force() {
    if !tmux_available() {
        eprintln!("skip: tmux not on PATH");
        return;
    }
    let ws = Workspace::spawn();
    let root = tempdir().unwrap();

    let out = ws.ksession(root.path()).run(&["save", "proj"]);
    assert_saved(&out, "tmux save proj");
    let rects_before = ws.pane_rects();
    let cwds_before = ws.live_cwds();
    assert_eq!(cwds_before, ws.cwds, "live cwds match the seeded tempdirs");

    // A second live session keeps the server alive once `demo` is
    // killed and stands in for "the client the user is running from".
    ws.server.run(&["new-session", "-d", "-s", "anchor"]);
    let from_anchor = Ksession::at(root.path()).inside(ws.server.tmux_env_for("anchor"));

    ws.server.run(&["kill-session", "-t", "=demo"]);
    assert!(!ws.server.has_session("demo"), "demo killed before restore");

    // Restore: the trailing `switch-client` has no client to switch, so
    // only the rebuilt server state is asserted (see module docs).
    let out = from_anchor.run(&["restore", "proj"]);
    let stderr = stderr_str(&out);
    assert!(
        !stderr.contains("no saved tmux session"),
        "restore must find the saved session:\n{stderr}"
    );
    assert!(
        ws.server.has_session("demo"),
        "restore recreated demo:\n{stderr}"
    );
    assert_eq!(ws.window_count(), 2, "two windows rebuilt:\n{stderr}");
    assert_eq!(ws.live_cwds(), cwds_before, "pane cwds rebuilt:\n{stderr}");
    assert_eq!(
        ws.pane_rects(),
        rects_before,
        "pane geometry (layout) rebuilt:\n{stderr}"
    );
    let id_after_restore = ws.server.session_id_of("demo");

    // Without --force a live session is left alone (switch/attach path).
    let out = from_anchor.run(&["restore", "proj"]);
    let stderr = stderr_str(&out);
    assert!(
        stderr.contains("already exists"),
        "restore onto a live session must say so:\n{stderr}"
    );
    assert_eq!(
        ws.server.session_id_of("demo"),
        id_after_restore,
        "restore without --force must not rebuild the live session"
    );

    // With --force the live session is torn down and rebuilt: a fresh
    // `$N` id proves it (ids are never reused within a server lifetime;
    // `#{session_created}` has only second resolution).
    let out = from_anchor.run(&["restore", "proj", "--force"]);
    let stderr = stderr_str(&out);
    assert!(
        ws.server.has_session("demo"),
        "--force rebuilt demo:\n{stderr}"
    );
    assert_ne!(
        ws.server.session_id_of("demo"),
        id_after_restore,
        "--force must create a new tmux session:\n{stderr}"
    );
    assert_eq!(ws.window_count(), 2, "two windows after --force:\n{stderr}");
    assert_eq!(
        ws.pane_rects(),
        rects_before,
        "geometry after --force:\n{stderr}"
    );
    assert_eq!(ws.live_cwds(), cwds_before, "cwds after --force:\n{stderr}");
}
