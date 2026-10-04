//! Regression: a pane with `OLDPWD` set emits
//! `bash -c '…; export OLDPWD=<oldpwd>; exec bash'` — uses `export OLDPWD=…`,
//! NOT `cd <oldpwd>`. Plan §8 Bug 8.
//!
//! `cd <oldpwd>` would override the `-c <cwd>` arg passed to tmux
//! new-window/split-window and land the pane in the wrong directory.
//! `export OLDPWD=…` makes a subsequent `cd -` work without changing
//! the pane's startup cwd. Mirrors ksession.sh:263.

use std::path::PathBuf;

use ksession_rs::model::{Program, ShellKind};
use ksession_rs::tmux_rpc::program_to_tmux_cmd;

#[test]
fn oldpwd_only_uses_export_not_cd() {
    let p = Program::Shell {
        shell: ShellKind::Bash,
        venv: None,
        conda: None,
        direnv: None,
        oldpwd: Some(PathBuf::from("/prev/dir")),
        scrollback: None,
        history: None,
    };
    let out = program_to_tmux_cmd(&p).expect("non-empty activation");
    assert!(
        out.contains("export OLDPWD=/prev/dir"),
        "expected `export OLDPWD=/prev/dir`, got: {out}"
    );
    // Regression guard: no `cd` substring should escape — that would
    // override tmux's `-c <cwd>` and land the pane wrong.
    assert!(
        !out.contains("cd /prev/dir"),
        "regression: `cd <oldpwd>` would override -c <cwd>, got: {out}"
    );
    assert!(
        !out.contains("cd '/prev/dir'"),
        "regression: quoted `cd <oldpwd>` form, got: {out}"
    );
}

#[test]
fn venv_plus_oldpwd_keeps_export() {
    let p = Program::Shell {
        shell: ShellKind::Bash,
        venv: Some(PathBuf::from("/home/u/.venv")),
        conda: None,
        direnv: None,
        oldpwd: Some(PathBuf::from("/tmp")),
        scrollback: None,
        history: None,
    };
    let out = program_to_tmux_cmd(&p).unwrap();
    assert!(
        out.contains("source /home/u/.venv/bin/activate"),
        "venv missing: {out}"
    );
    assert!(
        out.contains("export OLDPWD=/tmp"),
        "oldpwd export missing: {out}"
    );
    assert!(out.contains("exec bash"), "exec bash missing: {out}");
    assert!(!out.contains("cd /tmp"), "regression `cd /tmp`: {out}");
}

#[test]
fn conda_plus_oldpwd_keeps_export() {
    let p = Program::Shell {
        shell: ShellKind::Bash,
        venv: None,
        conda: Some("data-sci".into()),
        direnv: None,
        oldpwd: Some(PathBuf::from("/old")),
        scrollback: None,
        history: None,
    };
    let out = program_to_tmux_cmd(&p).unwrap();
    assert!(
        out.contains("conda activate data-sci"),
        "conda missing: {out}"
    );
    assert!(out.contains("export OLDPWD=/old"), "oldpwd missing: {out}");
    assert!(!out.contains("cd /old"), "regression `cd /old`: {out}");
}
