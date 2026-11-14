//! Regression: session names containing `#`, `:`, `.`, empty, or non-UTF-8
//! cause the OS-window's capture to degrade to
//! `Program::Raw { argv: vec!["tmux".into()] }` (NOT silently rewritten
//! with `_`). Plan §8 Bug 2.
//!
//! `clean_name()` in tmux/tmux.c silently substitutes `#:.` → `_`, which
//! breaks round-trip identity (the captured name in the SessionFile no
//! longer matches the live tmux server's name). Our defense is to refuse
//! to construct `Program::Tmux { session_name: ... }` at all when the
//! captured name needs cleaning.
//!
//! This test exercises the public validation predicate the adapter uses to
//! gate the degradation. The validator is currently a private helper in
//! `src/adapter/tmux.rs::is_valid_session_name`; once it's promoted to
//! `pub` (or moved to `tmux_rpc::is_valid_session_name`), this test will
//! compile.
//!
//! TODO: pending pub api for `is_valid_session_name`. The end-to-end
//! adapter degradation is `#[ignore]`'d because it requires a TmuxIo stub
//! + WindowCtx fixture that isn't pub yet.

#[test]
#[ignore = "pending pub is_valid_session_name and adapter test fixture"]
fn illegal_names_rejected() {
    // Manual-run trigger:
    //   cargo test --manifest-path scripts/ksession-rs/Cargo.toml \
    //     --test tmux_illegal_session_name_degrades -- --ignored
    //
    // Logic to land once the validator is pub:
    //
    //   use ksession_rs::adapter::tmux::is_valid_session_name;
    //   assert!(!is_valid_session_name("has#hash"));
    //   assert!(!is_valid_session_name("has:colon"));
    //   assert!(!is_valid_session_name("has.dot"));
    //   assert!(!is_valid_session_name(""));
    //   assert!(is_valid_session_name("plain"));
    //   assert!(is_valid_session_name("work-1"));
}

#[test]
#[ignore = "pending adapter integration fixture"]
fn adapter_degrades_to_program_raw_tmux() {
    // When the adapter sees an illegal session name from
    // `find_session_for_client_pid`, it must return
    // Program::Raw { argv: vec!["tmux".into()] } — NOT Program::Tmux
    // with the silently-cleaned name.
}
