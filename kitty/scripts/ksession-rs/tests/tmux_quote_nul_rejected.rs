//! Regression: a string containing `\x00` passed to the shell-escape wrapper
//! is rejected (debug: panic; release: warn-log + degrade to bare shell).
//! NUL cannot round-trip through `bash -c <argv>` because bash truncates
//! argv at NUL (C string semantics). Plan §8 Bug 14.
//!
//! The validation lives in `assert_no_nul()` in `src/adapter/tmux.rs`
//! (currently a private helper). Until it's promoted to `pub`, the
//! release-mode test cannot be driven directly. The debug-mode panic
//! test is exercised indirectly via the codegen path: NUL bytes appearing
//! in fields fed to `render_restore_sh` should not produce valid output.
//!
//! TODO: pending `pub assert_no_nul` (or `pub bash_quote_checked`).

use ksession_rs::adapter::assert_no_nul;
use ksession_rs::tmux_rpc::bash_quote;

#[test]
fn bash_quote_handles_normal_strings() {
    // Sanity: bash_quote is the wrapper that the NUL-rejection contract
    // ultimately protects. Empty / typical inputs round-trip.
    assert_eq!(bash_quote(""), "''");
    assert_eq!(bash_quote("hello"), "hello");
    assert_eq!(bash_quote("with space"), "'with space'");
}

// Debug-mode: assert_no_nul should panic when handed a NUL byte
#[cfg(debug_assertions)]
#[test]
fn debug_nul_panics() {
    let result = std::panic::catch_unwind(|| {
        let _ = assert_no_nul("test", "ab\0cd");
    });
    assert!(
        result.is_err(),
        "assert_no_nul should panic on NUL in debug mode"
    );
}

// In release mode, assert_no_nul returns an error instead of panicking
#[cfg(not(debug_assertions))]
#[test]
fn release_nul_returns_err() {
    let result = assert_no_nul("test", "ab\0cd");
    assert!(
        result.is_err(),
        "assert_no_nul should return Err on NUL in release mode"
    );
}

#[test]
fn bash_quote_at_least_does_not_silently_strip_nul() {
    // Defensive: if NUL DOES reach bash_quote (i.e. some path missed the
    // assert_no_nul gate), the output must still contain the byte
    // verbatim (single-quote wrap is byte-lossless). This guarantees
    // that downstream `cargo test`s catching a malformed restore.sh will
    // notice — they'd see a NUL embedded in the script.
    let out = bash_quote("a\0b");
    assert!(
        out.contains('\0'),
        "bash_quote silently stripped NUL — adapter must reject at the boundary; got: {out:?}"
    );
}
