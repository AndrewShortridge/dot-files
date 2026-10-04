//! Regression: less / man / more / most / pg pane restore commands emit
//! `<exe> +<pct>% -- <file>` with a single `%` (not `%%`).
//! Plan §8 Bug 10.
//!
//! Counterpart to the Bash `printf '%s +%d%%%% -- %s'` format-string bug at
//! ksession.sh:293, which the Rust port silently fixes. A trailing `%%`
//! makes less interpret the trailing `%` as a syntax error and refuse to
//! parse the `+<offset>` form.

use std::path::PathBuf;

use ksession_rs::model::Program;
use ksession_rs::tmux_rpc::program_to_tmux_cmd;

#[test]
fn less_command_single_percent_mid_range() {
    let p = Program::Less {
        file: PathBuf::from("/var/log/syslog"),
        byte_offset: 5,
        file_size: 10,
    };
    let out = program_to_tmux_cmd(&p).expect("Less → Some");
    assert!(out.contains("+50%"), "expected `+50%`, got: {out}");
    assert!(
        !out.contains("%%"),
        "double % regressed (parity with bash bug): {out}"
    );
    // Layout: `<exe> +<pct>% -- <file>`.
    assert!(
        out.contains(" -- "),
        "expected ` -- ` separator before file arg: {out}"
    );
}

#[test]
fn less_command_zero_percent_no_double() {
    let p = Program::Less {
        file: PathBuf::from("/empty"),
        byte_offset: 0,
        file_size: 0,
    };
    let out = program_to_tmux_cmd(&p).unwrap();
    assert!(out.contains("+0%"), "expected `+0%`: {out}");
    assert!(!out.contains("%%"), "double % regressed: {out}");
}

#[test]
fn less_command_clamped_99_no_double() {
    let p = Program::Less {
        file: PathBuf::from("/big"),
        byte_offset: 1_000_000,
        file_size: 100,
    };
    let out = program_to_tmux_cmd(&p).unwrap();
    assert!(out.contains("+99%"), "expected `+99%`: {out}");
    assert!(!out.contains("%%"), "double % regressed: {out}");
}
