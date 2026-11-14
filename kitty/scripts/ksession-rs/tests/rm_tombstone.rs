//! End-to-end test for `ksession rm` (PRD issue #07).
//!
//! Covers:
//!
//! 1. Happy path: a saved session's `.conf` and every `.gen-*.state/`
//!    are removed cleanly, leaving no debris.
//! 2. Crash-after-tombstone: an injected IO error fired immediately
//!    after the tombstone renames must leave only `*.deleted.<pid>`
//!    artifacts on disk — never half-deleted state.
//! 3. Name validation: hostile names are rejected BEFORE any filesystem
//!    work so the rejection can never side-effect.
//! 4. Missing session: `rm` on a name with no artifacts returns
//!    `KError::NotFound`.

use std::fs;
use std::path::Path;

use ksession_rs::error::KError;
use ksession_rs::session::rm::{run, run_with_hook, RmOpts, TombstoneHook};
use tempfile::tempdir;

/// Materialise a fake saved session on disk: a `<name>.conf` plus one or
/// more `<name>.gen-<gen_us>.state/` directories, each with a sentinel
/// file so we can assert the directory wasn't half-emptied.
fn seed_session(sessions_dir: &Path, name: &str, gens: &[u64]) {
    fs::write(sessions_dir.join(format!("{name}.conf")), b"# fake conf\n").expect("write conf");
    for &g in gens {
        let dir = sessions_dir.join(format!("{name}.gen-{g}.state"));
        fs::create_dir(&dir).expect("mkdir state");
        fs::write(dir.join("manifest.json"), b"{}").expect("write manifest");
        fs::create_dir(dir.join("tmux")).expect("mkdir tmux subdir");
        fs::write(dir.join("tmux/restore.sh"), b"#!/bin/sh\n").expect("write restore.sh");
    }
}

/// Count entries in `dir` whose basename matches `pred`.
fn count_entries(dir: &Path, pred: impl Fn(&str) -> bool) -> usize {
    fs::read_dir(dir)
        .expect("read_dir")
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_str().map(&pred).unwrap_or(false))
        .count()
}

#[test]
fn rm_happy_path_removes_conf_and_all_state_dirs() {
    let dir = tempdir().unwrap();
    let sess = dir.path();
    seed_session(sess, "myproj", &[100, 200]);
    // Sibling session — MUST survive.
    seed_session(sess, "other", &[42]);

    run(RmOpts {
        name: "myproj".into(),
        sessions_dir: sess.to_path_buf(),
    })
    .expect("rm ok");

    // No `myproj.*` survives.
    let leftovers = count_entries(sess, |n| n.starts_with("myproj"));
    assert_eq!(
        leftovers, 0,
        "rm must leave no myproj.* artifacts; found {leftovers}"
    );

    // Sibling session is untouched.
    assert!(sess.join("other.conf").exists(), "sibling conf survives");
    assert!(
        sess.join("other.gen-42.state").is_dir(),
        "sibling state dir survives"
    );
}

#[test]
fn rm_crash_after_tombstone_leaves_only_deleted_artifacts() {
    let dir = tempdir().unwrap();
    let sess = dir.path();
    seed_session(sess, "crashy", &[1, 2]);

    let err = run_with_hook(
        RmOpts {
            name: "crashy".into(),
            sessions_dir: sess.to_path_buf(),
        },
        TombstoneHook::fail_after_rename("simulated crash"),
    )
    .expect_err("hook must surface the IO error");

    // The error is the injected one, not e.g. NotFound.
    match err {
        KError::Io(_) => {}
        other => panic!("expected KError::Io, got {other:?}"),
    }

    // CRITICAL ASSERTION: no live (non-tombstone) `crashy.*` survives.
    // A half-deleted state dir here would be the regression we're
    // guarding against — the rename-first discipline must move the
    // artifacts out of the live namespace BEFORE any delete.
    let live = count_entries(sess, |n| {
        n.starts_with("crashy") && !n.contains(".deleted.")
    });
    assert_eq!(
        live, 0,
        "no live crashy.* artifacts allowed after crash; found {live}"
    );

    // And there must be exactly the expected number of tombstones
    // (1 conf + 2 state dirs = 3).
    let pid = std::process::id();
    let tomb_suffix = format!(".deleted.{pid}");
    let tombs = count_entries(sess, |n| {
        n.starts_with("crashy") && n.ends_with(&tomb_suffix)
    });
    assert_eq!(
        tombs, 3,
        "expected 3 tombstoned artifacts (conf + 2 state dirs); found {tombs}"
    );

    // Specifically verify each tombstone path exists.
    assert!(sess.join(format!("crashy.conf{tomb_suffix}")).exists());
    assert!(sess
        .join(format!("crashy.gen-1.state{tomb_suffix}"))
        .is_dir());
    assert!(sess
        .join(format!("crashy.gen-2.state{tomb_suffix}"))
        .is_dir());

    // And the tombstoned state dir still has its sentinel — proves we
    // didn't half-delete its contents either.
    assert!(sess
        .join(format!("crashy.gen-1.state{tomb_suffix}"))
        .join("manifest.json")
        .exists());
}

#[test]
fn rm_rejects_invalid_names_before_filesystem_work() {
    let dir = tempdir().unwrap();
    let sess = dir.path();
    // Seed a session whose existence would, if name validation ran
    // late, be visible to the (rejected) call.
    seed_session(sess, "foo", &[1]);

    for bad in &[
        "", "foo/bar", "foo bar", "../etc", "foo*", "foo\nbar", "foo;rm",
    ] {
        let err = run(RmOpts {
            name: (*bad).into(),
            sessions_dir: sess.to_path_buf(),
        })
        .expect_err(&format!("name {bad:?} should be rejected"));
        match err {
            KError::InvalidName(n) => assert_eq!(n, *bad),
            other => panic!("expected InvalidName for {bad:?}, got {other:?}"),
        }
    }

    // The legitimate session is still intact.
    assert!(sess.join("foo.conf").exists());
    assert!(sess.join("foo.gen-1.state").is_dir());
}

#[test]
fn rm_returns_not_found_when_no_artifacts_exist() {
    let dir = tempdir().unwrap();
    let sess = dir.path();
    // Empty sessions dir.
    let err = run(RmOpts {
        name: "ghost".into(),
        sessions_dir: sess.to_path_buf(),
    })
    .expect_err("rm on missing session must fail");
    match err {
        KError::NotFound(n) => assert_eq!(n, "ghost"),
        other => panic!("expected NotFound, got {other:?}"),
    }
}

#[test]
fn rm_handles_conf_only_with_no_state_dir() {
    // Edge case: hand-edited or interrupted save left only the conf.
    // `rm` must still find and remove it.
    let dir = tempdir().unwrap();
    let sess = dir.path();
    fs::write(sess.join("stub.conf"), b"# orphan conf\n").unwrap();

    run(RmOpts {
        name: "stub".into(),
        sessions_dir: sess.to_path_buf(),
    })
    .expect("rm ok");
    assert!(!sess.join("stub.conf").exists());
}

#[test]
fn rm_handles_state_dir_only_with_no_conf() {
    // Edge case: conf was hand-deleted (or sweep missed cleanup). `rm`
    // must still locate and remove the state dir.
    let dir = tempdir().unwrap();
    let sess = dir.path();
    fs::create_dir(sess.join("orphan.gen-7.state")).unwrap();

    run(RmOpts {
        name: "orphan".into(),
        sessions_dir: sess.to_path_buf(),
    })
    .expect("rm ok");
    assert!(!sess.join("orphan.gen-7.state").exists());
}
