//! Regression: `DIRENV_DIR` is captured from the pane's environ but is NOT
//! used in the emitted activation string — parity with Bash's
//! captured-but-unused behavior at ksession.sh:248-267. A future v2 fix
//! would wire this in; v1 must replicate the omission. Plan §8 Bug 9.

use std::path::PathBuf;

use ksession_rs::model::{Program, ShellKind};
use ksession_rs::tmux_rpc::program_to_tmux_cmd;

#[test]
fn direnv_alone_yields_none_like_bare_shell() {
    // No venv, no conda, no oldpwd, only direnv set. The shell arm should
    // return None (use tmux default-shell) — direnv is captured but
    // unused, matching ksession.sh:267.
    let p = Program::Shell {
        shell: ShellKind::Bash,
        venv: None,
        conda: None,
        direnv: Some(PathBuf::from("/path/to/project")),
        oldpwd: None,
        scrollback: None,
        history: None,
    };
    let out = program_to_tmux_cmd(&p);
    assert_eq!(
        out, None,
        "DIRENV_DIR alone must NOT trigger an activation wrapper; got {out:?}"
    );
}

#[test]
fn direnv_does_not_leak_into_venv_activation() {
    let p = Program::Shell {
        shell: ShellKind::Bash,
        venv: Some(PathBuf::from("/home/u/.venv")),
        conda: None,
        direnv: Some(PathBuf::from("/path/to/project")),
        oldpwd: None,
        scrollback: None,
        history: None,
    };
    let out = program_to_tmux_cmd(&p).expect("venv → Some");
    assert!(
        out.contains("source /home/u/.venv/bin/activate"),
        "venv activation missing: {out}"
    );
    assert!(
        !out.contains("direnv"),
        "DIRENV_DIR must not appear in emitted command: {out}"
    );
    assert!(
        !out.contains("/path/to/project"),
        "DIRENV_DIR path must not appear in emitted command: {out}"
    );
}

#[test]
fn direnv_does_not_leak_into_conda_activation() {
    let p = Program::Shell {
        shell: ShellKind::Bash,
        venv: None,
        conda: Some("data-sci".into()),
        direnv: Some(PathBuf::from("/path/to/project")),
        oldpwd: None,
        scrollback: None,
        history: None,
    };
    let out = program_to_tmux_cmd(&p).expect("conda → Some");
    assert!(out.contains("conda activate data-sci"));
    assert!(!out.contains("direnv"), "DIRENV_DIR must not appear: {out}");
    assert!(
        !out.contains("/path/to/project"),
        "DIRENV_DIR path must not appear: {out}"
    );
}
