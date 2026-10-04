//! Validation tests for the restore-baseline workload fixtures (PRD-0003
//! Slice 3). Each test deserialises the manifest JSON into a [`SessionFile`],
//! asserts structural invariants (schema, OS-window / tab / window counts),
//! and checks program types per workload.

use std::path::Path;

use ksession_rs::model::{Program, SessionFile};

const FIXTURES_DIR: &str = "tests/fixtures/restore-baseline";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn validate_fixture(
    dir: &Path,
    name: &str,
    expected_os_windows: usize,
    expected_tabs: usize,
    expected_windows: usize,
) -> SessionFile {
    // 1. Assert conf file exists
    let conf = dir.join(format!("{name}.conf"));
    assert!(conf.exists(), "conf file missing: {}", conf.display());

    // 2. Assert manifest exists and parses
    let manifest_path = dir.join(format!("{name}.state")).join("manifest.json");
    assert!(
        manifest_path.exists(),
        "manifest missing: {}",
        manifest_path.display()
    );
    let raw = std::fs::read_to_string(&manifest_path).expect("read manifest");
    let session: SessionFile = serde_json::from_str(&raw).expect("parse manifest");

    // 3. Assert schema = 1
    assert_eq!(session.schema, 1, "schema mismatch for {name}");

    // 4. Assert expected counts
    assert_eq!(
        session.os_windows.len(),
        expected_os_windows,
        "os_windows count mismatch for {name}"
    );
    let total_tabs: usize = session.os_windows.iter().map(|o| o.tabs.len()).sum();
    assert_eq!(total_tabs, expected_tabs, "tabs count mismatch for {name}");
    let total_windows: usize = session
        .os_windows
        .iter()
        .flat_map(|o| &o.tabs)
        .map(|t| t.windows.len())
        .sum();
    assert_eq!(
        total_windows, expected_windows,
        "windows count mismatch for {name}"
    );

    session
}

/// Collect all [`Program`] variants across all kitty windows in the session.
fn collect_programs(session: &SessionFile) -> Vec<&Program> {
    session
        .os_windows
        .iter()
        .flat_map(|o| &o.tabs)
        .flat_map(|t| &t.windows)
        .map(|w| &w.program)
        .collect()
}

// ---------------------------------------------------------------------------
// W1 — Minimal
// ---------------------------------------------------------------------------

#[test]
fn w1_minimal_fixture_valid() {
    let dir = Path::new(FIXTURES_DIR).join("W1_minimal");
    let session = validate_fixture(&dir, "W1_minimal", 1, 1, 1);
    let programs = collect_programs(&session);
    assert_eq!(programs.len(), 1);
    assert!(
        matches!(programs[0], Program::BareShell),
        "W1 expected BareShell, got {:?}",
        programs[0]
    );
}

// ---------------------------------------------------------------------------
// W2 — Multi-tab shell
// ---------------------------------------------------------------------------

#[test]
fn w2_multi_tab_fixture_valid() {
    let dir = Path::new(FIXTURES_DIR).join("W2_multi_tab");
    let session = validate_fixture(&dir, "W2_multi_tab", 1, 4, 4);
    let programs = collect_programs(&session);
    assert_eq!(programs.len(), 4);
    for (i, p) in programs.iter().enumerate() {
        assert!(
            matches!(p, Program::BareShell),
            "W2 tab {i} expected BareShell, got {p:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// W3 — Heavy nvim
// ---------------------------------------------------------------------------

#[test]
fn w3_heavy_nvim_fixture_valid() {
    let dir = Path::new(FIXTURES_DIR).join("W3_heavy_nvim");
    let session = validate_fixture(&dir, "W3_heavy_nvim", 1, 1, 1);
    let programs = collect_programs(&session);
    assert_eq!(programs.len(), 1);
    assert!(
        matches!(programs[0], Program::Nvim { .. }),
        "W3 expected Nvim, got {:?}",
        programs[0]
    );

    // Validate the buffer manifest has 8 buffers
    let buf_manifest_path = dir.join("W3_heavy_nvim.state").join("win-1.json");
    let raw = std::fs::read_to_string(&buf_manifest_path).expect("read buffer manifest");
    let val: serde_json::Value = serde_json::from_str(&raw).expect("parse buffer manifest");
    let buffers = val["buffers"]
        .as_array()
        .expect("buffers should be an array");
    assert_eq!(buffers.len(), 8, "W3 buffer manifest should have 8 buffers");
}

// ---------------------------------------------------------------------------
// W4 — Heavy tmux
// ---------------------------------------------------------------------------

#[test]
fn w4_heavy_tmux_fixture_valid() {
    let dir = Path::new(FIXTURES_DIR).join("W4_heavy_tmux");
    let session = validate_fixture(&dir, "W4_heavy_tmux", 1, 1, 1);
    let programs = collect_programs(&session);
    assert_eq!(programs.len(), 1);

    match programs[0] {
        Program::Tmux { ref windows, .. } => {
            assert_eq!(windows.len(), 3, "W4 should have 3 tmux windows");
            let total_panes: usize = windows.iter().map(|w| w.panes.len()).sum();
            assert_eq!(total_panes, 9, "W4 should have 3x3=9 tmux panes");
            for tw in windows {
                assert_eq!(
                    tw.panes.len(),
                    3,
                    "W4 tmux window '{}' should have 3 panes",
                    tw.name
                );
            }
        }
        ref other => panic!("W4 expected Tmux, got {other:?}"),
    }
}

// ---------------------------------------------------------------------------
// W5 — Mixed realistic
// ---------------------------------------------------------------------------

#[test]
fn w5_mixed_fixture_valid() {
    let dir = Path::new(FIXTURES_DIR).join("W5_mixed");
    // 2 OS windows, 3 tabs total (2 + 1), 3 kitty windows total
    let session = validate_fixture(&dir, "W5_mixed", 2, 3, 3);
    let programs = collect_programs(&session);
    assert_eq!(programs.len(), 3);

    // Count program types
    let nvim_count = programs
        .iter()
        .filter(|p| matches!(p, Program::Nvim { .. }))
        .count();
    let tmux_count = programs
        .iter()
        .filter(|p| matches!(p, Program::Tmux { .. }))
        .count();
    let bare_shell_count = programs
        .iter()
        .filter(|p| matches!(p, Program::BareShell))
        .count();

    assert_eq!(nvim_count, 1, "W5 should have 1 Nvim program");
    assert_eq!(tmux_count, 1, "W5 should have 1 Tmux program");
    assert_eq!(bare_shell_count, 1, "W5 should have 1 BareShell program");

    // Validate nvim buffer manifest has 4 buffers
    let buf_manifest_path = dir.join("W5_mixed.state").join("win-1.json");
    let raw = std::fs::read_to_string(&buf_manifest_path).expect("read W5 buffer manifest");
    let val: serde_json::Value = serde_json::from_str(&raw).expect("parse W5 buffer manifest");
    let buffers = val["buffers"]
        .as_array()
        .expect("buffers should be an array");
    assert_eq!(buffers.len(), 4, "W5 buffer manifest should have 4 buffers");

    // Validate tmux has 2 windows x 2 panes = 4 panes
    let tmux_prog = programs.iter().find(|p| matches!(p, Program::Tmux { .. }));
    match tmux_prog {
        Some(Program::Tmux { ref windows, .. }) => {
            assert_eq!(windows.len(), 2, "W5 tmux should have 2 windows");
            let total_panes: usize = windows.iter().map(|w| w.panes.len()).sum();
            assert_eq!(total_panes, 4, "W5 tmux should have 2x2=4 panes");
        }
        _ => panic!("W5 tmux program not found"),
    }
}
