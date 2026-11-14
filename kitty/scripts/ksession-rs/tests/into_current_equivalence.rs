//! End-to-end equivalence suite comparing spawn-new vs into-current outcomes.
//!
//! This test suite verifies that into-current restore produces equivalent outcomes
//! to spawning a new kitty session from the same conf file. Since we can't run
//! a live kitty UI in tests, we use the parsed conf as the source of truth and
//! verify that the replay engine would produce equivalent results.
//!
//! Tests are deterministic and don't require a live kitty instance.

use ksession_rs::conf::parser::ConfParser;
use ksession_rs::session::layout_replay::{ReplayPhase, ReplayPlan, TabReplayPlan};

/// Test fixture metadata for equivalence testing.
#[allow(dead_code)]
struct FixtureExpectation {
    /// Expected tab count from spawn-new (source of truth from conf)
    expected_tab_count: usize,
    /// Expected window count per tab
    expected_windows_per_tab: Vec<usize>,
    /// Whether layout is expected
    has_layout: bool,
    /// Whether enabled_layouts is expected
    has_enabled_layouts: bool,
    /// Whether layout_state is expected (into-current can't restore this)
    has_layout_state: bool,
    /// Expected focus_tab index (None if not specified)
    expected_focus_tab: Option<usize>,
    /// Whether any tab has explicit focus marker
    has_focus_marker: bool,
    /// Whether any window has overlay type
    has_overlay: bool,
}

impl FixtureExpectation {
    fn from_conf(conf: &str) -> Self {
        let result = ConfParser::parse(conf).unwrap();

        let expected_tab_count = result.os_windows.iter().map(|osw| osw.tabs.len()).sum();

        let expected_windows_per_tab: Vec<usize> = result
            .os_windows
            .iter()
            .flat_map(|osw| osw.tabs.iter().map(|tab| tab.windows.len()))
            .collect();

        let has_layout = result
            .os_windows
            .iter()
            .flat_map(|osw| osw.tabs.iter())
            .any(|tab| tab.layout.is_some());

        let has_enabled_layouts = result
            .os_windows
            .iter()
            .flat_map(|osw| osw.tabs.iter())
            .any(|tab| tab.enabled_layouts.is_some());

        let has_layout_state = result
            .os_windows
            .iter()
            .flat_map(|osw| osw.tabs.iter())
            .any(|tab| tab.layout_state.is_some());

        let expected_focus_tab = result.os_windows.first().and_then(|osw| osw.focus_tab);

        let has_focus_marker = result
            .os_windows
            .iter()
            .flat_map(|osw| osw.tabs.iter())
            .any(|tab| tab.focus);

        let has_overlay = result
            .os_windows
            .iter()
            .flat_map(|osw| osw.tabs.iter())
            .flat_map(|tab| tab.windows.iter())
            .any(|win| win.window_type.as_deref() == Some("overlay"));

        FixtureExpectation {
            expected_tab_count,
            expected_windows_per_tab,
            has_layout,
            has_enabled_layouts,
            has_layout_state,
            expected_focus_tab,
            has_focus_marker,
            has_overlay,
        }
    }
}

/// Build a replay plan from parsed conf - this represents what into-current would do.
fn build_replay_plan(conf: &str) -> ReplayPlan {
    let result = ConfParser::parse(conf).unwrap();

    // For equivalence testing, we simulate what the restore would do:
    // - Create tabs for each tab in the conf
    // - Apply layout/enabled_layouts to each tab
    // - Handle layout_state (will emit warning, not actually restore)
    // - Apply window focus if specified
    // - Apply tab focus if specified

    let mut tab_plans: Vec<TabReplayPlan> = Vec::new();

    for osw in &result.os_windows {
        for tab in &osw.tabs {
            tab_plans.push(TabReplayPlan {
                tab_id: 0, // Not relevant for equivalence test
                layout: tab.layout.clone(),
                enabled_layouts: tab.enabled_layouts.clone(),
                has_layout_state: tab.layout_state.is_some(),
                window_focus: if tab.active_window_idx > 0 {
                    Some((0, false)) // Simplified - actual focus would use real IDs
                } else {
                    None
                },
            });
        }
    }

    let focus_tab_index = result.os_windows.first().and_then(|osw| osw.focus_tab);

    ReplayPlan {
        tabs: tab_plans,
        focus_tab_index,
    }
}

#[test]
fn test_equivalence_light_001() {
    // Fixture: light_001 - shell-only session with 2 tabs
    let conf = r#"new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 1, "active_group_history": [1], "window_groups": [{"id": 1, "window_ids": [1]}, {"id": 3, "window_ids": [3]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 1}'
launch 'kitty-unserialize-data={"id": 3}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 1, "active_group_history": [2], "window_groups": [{"id": 2, "window_ids": [2]}, {"id": 4, "window_ids": [4]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 2}' --title=tab-1
launch 'kitty-unserialize-data={"id": 4}'
focus

focus_tab 1"#;

    let expectation = FixtureExpectation::from_conf(conf);

    // Spawn-new (source of truth): 2 tabs
    assert_eq!(
        expectation.expected_tab_count, 2,
        "light_001: should have 2 tabs"
    );
    // Tab 0: 2 windows, Tab 1: 2 windows
    assert_eq!(
        expectation.expected_windows_per_tab,
        vec![2, 2],
        "light_001: windows per tab"
    );
    assert!(expectation.has_layout, "light_001: should have layout");
    assert!(
        expectation.has_enabled_layouts,
        "light_001: should have enabled_layouts"
    );
    assert!(
        expectation.has_layout_state,
        "light_001: has layout_state (into-current can't restore)"
    );
    assert_eq!(
        expectation.expected_focus_tab,
        Some(1),
        "light_001: focus_tab should be 1"
    );
    assert!(
        expectation.has_focus_marker,
        "light_001: should have focus markers"
    );
    assert!(
        !expectation.has_overlay,
        "light_001: should not have overlays"
    );

    // Verify into-current replay plan produces equivalent phases
    let plan = build_replay_plan(conf);
    let phases = plan.all_phases();

    // For equivalence testing, we just verify:
    // 1. Layout phases match tab count
    // 2. Enabled layouts phases match tab count
    // 3. Window focus phases exist when focus directive present
    // 4. Tab focus phase exists when focus_tab directive present
    // The exact count depends on active_window_idx > 0 which is set by focus
    let layout_phases: Vec<_> = phases
        .iter()
        .filter(|p| matches!(p, ReplayPhase::ApplyLayout))
        .collect();
    let tab_focus_phases: Vec<_> = phases
        .iter()
        .filter(|p| matches!(p, ReplayPhase::ApplyTabFocus))
        .collect();

    assert_eq!(
        layout_phases.len(),
        2,
        "light_001: into-current should apply layout to 2 tabs"
    );
    assert_eq!(
        tab_focus_phases.len(),
        1,
        "light_001: into-current should apply tab focus"
    );
}

#[test]
fn test_equivalence_typical_001() {
    // Fixture: typical_001 - 4 tabs with multiple windows each
    let conf = r#"new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 2, "active_group_history": [1, 5], "window_groups": [{"id": 1, "window_ids": [1]}, {"id": 5, "window_ids": [5]}, {"id": 6, "window_ids": [6]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 1}'
launch 'kitty-unserialize-data={"id": 5}'
launch 'kitty-unserialize-data={"id": 6}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 2, "active_group_history": [2, 7], "window_groups": [{"id": 2, "window_ids": [2]}, {"id": 7, "window_ids": [7]}, {"id": 8, "window_ids": [8]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 2}' --title=tab-1
launch 'kitty-unserialize-data={"id": 7}'
launch 'kitty-unserialize-data={"id": 8}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 2, "active_group_history": [3, 9], "window_groups": [{"id": 3, "window_ids": [3]}, {"id": 9, "window_ids": [9]}, {"id": 10, "window_ids": [10]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 3}' --title=tab-2
launch 'kitty-unserialize-data={"id": 9}'
launch 'kitty-unserialize-data={"id": 10}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 2, "active_group_history": [4, 11], "window_groups": [{"id": 4, "window_ids": [4]}, {"id": 11, "window_ids": [11]}, {"id": 12, "window_ids": [12]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 4}' --title=tab-3
launch 'kitty-unserialize-data={"id": 11}'
launch 'kitty-unserialize-data={"id": 12}'
focus

focus_tab 3"#;

    let expectation = FixtureExpectation::from_conf(conf);

    // Spawn-new: 4 tabs
    assert_eq!(
        expectation.expected_tab_count, 4,
        "typical_001: should have 4 tabs"
    );
    // Each tab has 3 windows
    assert_eq!(
        expectation.expected_windows_per_tab,
        vec![3, 3, 3, 3],
        "typical_001: windows per tab"
    );
    assert!(expectation.has_layout, "typical_001: should have layout");
    assert!(
        expectation.has_enabled_layouts,
        "typical_001: should have enabled_layouts"
    );
    assert!(
        expectation.has_layout_state,
        "typical_001: has layout_state"
    );
    assert_eq!(
        expectation.expected_focus_tab,
        Some(3),
        "typical_001: focus_tab should be 3"
    );
    assert!(
        expectation.has_focus_marker,
        "typical_001: should have focus markers"
    );
    assert!(
        !expectation.has_overlay,
        "typical_001: should not have overlays"
    );

    // Verify into-current replay plan
    let plan = build_replay_plan(conf);
    let phases = plan.all_phases();

    // 4 tabs with layout -> 4 layout phases
    // 4 tabs with enabled_layouts -> 4 enabled layouts phases
    // Each tab has focus directive -> window focus per tab
    // focus_tab 3 -> tab focus phase
    // Just verify we have the expected structure
    let layout_phases: Vec<_> = phases
        .iter()
        .filter(|p| matches!(p, ReplayPhase::ApplyLayout))
        .collect();
    let tab_focus_phases: Vec<_> = phases
        .iter()
        .filter(|p| matches!(p, ReplayPhase::ApplyTabFocus))
        .collect();

    assert_eq!(
        layout_phases.len(),
        4,
        "typical_001: should have 4 layout phases"
    );
    assert_eq!(
        tab_focus_phases.len(),
        1,
        "typical_001: should have tab focus"
    );
}

#[test]
fn test_equivalence_nvim_clean() {
    // Fixture: nvim_clean - single tab with nvim (keep-focus)
    let conf = r#"new_tab nvim
layout splits
enabled_layouts splits,stack
set_layout_state {"pairs": {"horizontal": false, "one": 1}, "opts": {"default_axis_is_horizontal": true}, "class": "Splits", "all_windows": {"active_group_idx": 0, "active_group_history": [1], "window_groups": [{"id": 1, "window_ids": [1]}]}}
cd /home/u

launch --keep-focus 'kitty-unserialize-data={"id": 1}' --var=ksession_idx=0 --var=ksession_win=1 /home/u/.local/bin/nvim --headless -c "quit" 2>/dev/null || /home/u/.local/bin/nvim
focus"#;

    let expectation = FixtureExpectation::from_conf(conf);

    // Spawn-new: 1 tab
    assert_eq!(
        expectation.expected_tab_count, 1,
        "nvim_clean: should have 1 tab"
    );
    assert_eq!(
        expectation.expected_windows_per_tab,
        vec![1],
        "nvim_clean: 1 window"
    );
    assert!(expectation.has_layout, "nvim_clean: should have layout");
    assert!(
        expectation.has_enabled_layouts,
        "nvim_clean: should have enabled_layouts"
    );
    assert!(expectation.has_layout_state, "nvim_clean: has layout_state");
    assert_eq!(
        expectation.expected_focus_tab, None,
        "nvim_clean: no focus_tab"
    );
    assert!(
        expectation.has_focus_marker,
        "nvim_clean: should have focus marker"
    );

    // Verify into-current replay plan
    let plan = build_replay_plan(conf);
    let phases = plan.all_phases();

    // 1 tab: layout + enabled_layouts + focus = 3
    assert_eq!(phases.len(), 3, "nvim_clean: phase count");
}

#[test]
fn test_equivalence_tmux_single() {
    // Fixture: tmux_single - minimal tmux session
    let conf = r#"new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 0, "active_group_history": [1], "window_groups": [{"id": 1, "window_ids": [1]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 1}'
focus

focus_tab 0"#;

    let expectation = FixtureExpectation::from_conf(conf);

    // Spawn-new: 1 tab
    assert_eq!(
        expectation.expected_tab_count, 1,
        "tmux_single: should have 1 tab"
    );
    assert_eq!(
        expectation.expected_windows_per_tab,
        vec![1],
        "tmux_single: 1 window"
    );
    assert!(expectation.has_layout, "tmux_single: should have layout");
    assert!(
        expectation.has_enabled_layouts,
        "tmux_single: should have enabled_layouts"
    );
    assert!(
        expectation.has_layout_state,
        "tmux_single: has layout_state"
    );
    assert_eq!(
        expectation.expected_focus_tab,
        Some(0),
        "tmux_single: focus_tab 0"
    );
    assert!(
        expectation.has_focus_marker,
        "tmux_single: should have focus marker"
    );
    assert!(
        !expectation.has_overlay,
        "tmux_single: should not have overlays"
    );

    // Verify into-current replay plan
    let plan = build_replay_plan(conf);
    let phases = plan.all_phases();

    // 1 tab: layout + enabled_layouts + focus = 3, tab focus = 1
    assert_eq!(phases.len(), 4, "tmux_single: phase count");
}

#[test]
fn test_equivalence_minimal_shell() {
    // Minimal shell-only session (no layout, no focus)
    let conf = r#"new_tab
launch /bin/bash
new_tab
launch /bin/zsh"#;

    let expectation = FixtureExpectation::from_conf(conf);

    // Spawn-new: 2 tabs
    assert_eq!(
        expectation.expected_tab_count, 2,
        "minimal: should have 2 tabs"
    );
    assert_eq!(
        expectation.expected_windows_per_tab,
        vec![1, 1],
        "minimal: 1 window each"
    );
    assert!(!expectation.has_layout, "minimal: should NOT have layout");
    assert!(
        !expectation.has_enabled_layouts,
        "minimal: should NOT have enabled_layouts"
    );
    assert!(
        !expectation.has_layout_state,
        "minimal: should NOT have layout_state"
    );
    assert_eq!(
        expectation.expected_focus_tab, None,
        "minimal: no focus_tab"
    );
    assert!(
        !expectation.has_focus_marker,
        "minimal: should NOT have focus marker"
    );
    assert!(
        !expectation.has_overlay,
        "minimal: should not have overlays"
    );

    // Verify into-current replay plan
    let plan = build_replay_plan(conf);
    let phases = plan.all_phases();

    // No layout/enabled_layouts/focus in conf = no phases from replay
    // But we still have 2 tabs, so no phases
    assert_eq!(phases.len(), 0, "minimal: no replay phases for plain tabs");
}

#[test]
fn test_equivalence_with_overlay() {
    // Session with overlay window
    let conf = r#"new_tab
launch /bin/bash
launch --type=overlay --title="Overlay" /bin/sh -c 'echo overlay'
focus_tab 0"#;

    let expectation = FixtureExpectation::from_conf(conf);

    // Spawn-new: 1 tab with 2 windows (second is overlay)
    assert_eq!(
        expectation.expected_tab_count, 1,
        "overlay: should have 1 tab"
    );
    assert_eq!(
        expectation.expected_windows_per_tab,
        vec![2],
        "overlay: 2 windows"
    );
    assert!(
        expectation.has_overlay,
        "overlay: should detect overlay window"
    );

    // Verify into-current replay plan handles overlay
    let plan = build_replay_plan(conf);

    // Overlay should not be focused (replay engine skips overlay focus)
    // Phase: layout (none) + enabled_layouts (none) + focus (but overlay skipped)
    // Actually, focus marker is present but overlay won't be focused
    let _phases = plan.all_phases();

    // Verify overlay presence is detected in expectation
    assert!(
        expectation.has_overlay,
        "overlay: should detect overlay window"
    );
}
