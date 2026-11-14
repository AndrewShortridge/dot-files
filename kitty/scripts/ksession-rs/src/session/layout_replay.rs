//! Layout Replay Engine for --into-current restore.
//!
//! This module encapsulates the deterministic phases for replaying session layout:
//! 1. Apply layout mode (`goto-layout`)
//! 2. Apply enabled layouts (`set-enabled-layouts`)
//! 3. Handle detailed layout state (warning if present)
//! 4. Apply window focus (`focus-window`)
//! 5. Apply tab focus (`focus-tab`)
//!
//! Each phase has explicit error handling and warning diagnostics.

use std::process::Command;

/// Execute a kitty RC command and emit actionable diagnostics on failure.
///
/// Returns `true` if the command succeeded, `false` otherwise.
pub fn exec_kitty_rc(phase: &str, target: &str, args: &[String]) -> bool {
    let output = Command::new("kitten").args(args).output();

    match output {
        Ok(output) if output.status.success() => true,
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            eprintln!(
                "Warning: {} failed for {}: {}",
                phase,
                target,
                stderr.trim()
            );
            false
        }
        Err(e) => {
            eprintln!("Warning: {} failed for {}: {}", phase, target, e);
            false
        }
    }
}

/// Apply layout mode to a tab using `goto-layout`.
pub fn apply_layout_mode(socket: &str, tab_id: u32, layout: &str) -> bool {
    let args = vec![
        "@".to_string(),
        "--to".to_string(),
        socket.to_string(),
        "goto-layout".to_string(),
        "--match".to_string(),
        format!("id:{}", tab_id),
        layout.to_string(),
    ];
    exec_kitty_rc("apply-layout", &format!("tab id:{}", tab_id), &args)
}

/// Apply enabled layouts to a tab using `set-enabled-layouts`.
pub fn apply_enabled_layouts(socket: &str, tab_id: u32, enabled: &str) -> bool {
    // Convert comma-separated to space-separated (kitty expects "splits stack" not "splits,stack")
    let enabled_space_sep = enabled.replace(',', " ");
    let args = vec![
        "@".to_string(),
        "--to".to_string(),
        socket.to_string(),
        "set-enabled-layouts".to_string(),
        "--match".to_string(),
        format!("id:{}", tab_id),
        enabled_space_sep,
    ];
    exec_kitty_rc(
        "apply-enabled-layouts",
        &format!("tab id:{}", tab_id),
        &args,
    )
}

/// Handle layout state - emits warning since it's not supported by kitty RC.
///
/// Returns `true` if layout state was present (and warning was emitted), `false` otherwise.
pub fn handle_layout_state(tab_id: u32, has_layout_state: bool) -> bool {
    if has_layout_state {
        eprintln!("Warning: apply-layout-state not supported for tab id:{} (only layout name is restored)", tab_id);
        true
    } else {
        false
    }
}

/// Apply window focus using `focus-window`.
///
/// This function skips focusing for overlay windows since they overlay the current
/// content and shouldn't be focused.
///
/// Returns `true` if focus was applied, `false` if skipped or failed.
pub fn apply_window_focus(socket: &str, window_id: u32, is_overlay: bool) -> bool {
    if is_overlay {
        eprintln!("Warning: skipping focus for overlay window id:{} (overlay windows should not be focused)", window_id);
        return false;
    }

    let args = vec![
        "@".to_string(),
        "--to".to_string(),
        socket.to_string(),
        "focus-window".to_string(),
        "--match".to_string(),
        format!("id:{}", window_id),
    ];
    exec_kitty_rc("focus-window", &format!("window id:{}", window_id), &args)
}

/// Apply tab focus using `focus-tab` with ID-based targeting.
pub fn apply_tab_focus(socket: &str, tab_id: u32) -> bool {
    let args = vec![
        "@".to_string(),
        "--to".to_string(),
        socket.to_string(),
        "focus-tab".to_string(),
        "--match".to_string(),
        format!("id:{}", tab_id),
    ];
    exec_kitty_rc("focus-tab", &format!("tab id:{}", tab_id), &args)
}

/// Represents a single phase in the layout replay sequence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplayPhase {
    ApplyLayout,
    ApplyEnabledLayouts,
    HandleLayoutState,
    ApplyWindowFocus,
    ApplyTabFocus,
}

/// A deterministic replay plan for a single tab.
/// This structure captures the order of operations for testing.
#[derive(Debug, Clone)]
pub struct TabReplayPlan {
    pub tab_id: u32,
    pub layout: Option<String>,
    pub enabled_layouts: Option<String>,
    pub has_layout_state: bool,
    pub window_focus: Option<(u32, bool)>, // (window_id, is_overlay)
}

impl TabReplayPlan {
    /// Returns the ordered phases for this tab replay.
    /// This is deterministic and matches the actual replay order.
    pub fn phases(&self) -> Vec<ReplayPhase> {
        let mut phases = Vec::new();

        // Phase 1: Apply layout mode
        if self.layout.is_some() {
            phases.push(ReplayPhase::ApplyLayout);
        }

        // Phase 2: Apply enabled layouts
        if self.enabled_layouts.is_some() {
            phases.push(ReplayPhase::ApplyEnabledLayouts);
        }

        // Phase 3: Handle layout state (warning if present)
        if self.has_layout_state {
            phases.push(ReplayPhase::HandleLayoutState);
        }

        // Phase 4: Apply window focus
        if self.window_focus.is_some() {
            phases.push(ReplayPhase::ApplyWindowFocus);
        }

        phases
    }
}

/// A complete replay plan for all tabs.
#[derive(Debug, Clone)]
pub struct ReplayPlan {
    pub tabs: Vec<TabReplayPlan>,
    pub focus_tab_index: Option<usize>,
}

impl ReplayPlan {
    /// Build a replay plan from parsed session data.
    pub fn from_parsed_tabs(
        tabs: &[crate::conf::parser::ParsedTab],
        tab_ids: &[u32],
        focus_tab_index: Option<usize>,
    ) -> Self {
        let tab_plans: Vec<TabReplayPlan> = tabs
            .iter()
            .enumerate()
            .filter_map(|(idx, tab)| {
                let tab_id = tab_ids.get(idx).copied()?;
                Some(TabReplayPlan {
                    tab_id,
                    layout: tab.layout.clone(),
                    enabled_layouts: tab.enabled_layouts.clone(),
                    has_layout_state: tab.layout_state.is_some(),
                    window_focus: if tab.active_window_idx > 0 {
                        // This is simplified; actual mapping would need window_id_map
                        None
                    } else {
                        None
                    },
                })
            })
            .collect();

        ReplayPlan {
            tabs: tab_plans,
            focus_tab_index,
        }
    }

    /// Returns the ordered phases across all tabs, plus final tab focus.
    pub fn all_phases(&self) -> Vec<ReplayPhase> {
        let mut phases = Vec::new();

        for tab in &self.tabs {
            phases.extend(tab.phases());
        }

        // Final phase: tab focus
        if self.focus_tab_index.is_some() {
            phases.push(ReplayPhase::ApplyTabFocus);
        }

        phases
    }
}

/// Resolve focus_tab index to actual tab ID.
/// Returns None if index is out of range.
pub fn resolve_focus_tab_index(focus_tab_index: Option<usize>, tab_ids: &[u32]) -> Option<u32> {
    let idx = focus_tab_index?;
    tab_ids.get(idx).copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_layout_state_warning() {
        // Test that layout state handling returns correct bool
        assert!(handle_layout_state(123, true));
        assert!(!handle_layout_state(123, false));
    }

    #[test]
    fn test_tab_replay_plan_phases_ordered() {
        // Test deterministic phase ordering: layout -> enabled_layouts -> layout_state -> window_focus
        let plan = TabReplayPlan {
            tab_id: 1,
            layout: Some("splits".to_string()),
            enabled_layouts: Some("splits,tall,grid".to_string()),
            has_layout_state: true,
            window_focus: Some((5, false)),
        };

        let phases = plan.phases();

        // Verify exact order
        assert_eq!(phases.len(), 4);
        assert_eq!(phases[0], ReplayPhase::ApplyLayout);
        assert_eq!(phases[1], ReplayPhase::ApplyEnabledLayouts);
        assert_eq!(phases[2], ReplayPhase::HandleLayoutState);
        assert_eq!(phases[3], ReplayPhase::ApplyWindowFocus);
    }

    #[test]
    fn test_tab_replay_plan_phases_partial() {
        // Test with only layout (no enabled_layouts, no layout_state, no focus)
        let plan = TabReplayPlan {
            tab_id: 1,
            layout: Some("fat".to_string()),
            enabled_layouts: None,
            has_layout_state: false,
            window_focus: None,
        };

        let phases = plan.phases();

        assert_eq!(phases.len(), 1);
        assert_eq!(phases[0], ReplayPhase::ApplyLayout);
    }

    #[test]
    fn test_replay_plan_all_phases() {
        // Test complete replay plan with multiple tabs
        let plan = ReplayPlan {
            tabs: vec![
                TabReplayPlan {
                    tab_id: 1,
                    layout: Some("splits".to_string()),
                    enabled_layouts: Some("splits,tall".to_string()),
                    has_layout_state: false,
                    window_focus: None,
                },
                TabReplayPlan {
                    tab_id: 2,
                    layout: Some("fat".to_string()),
                    enabled_layouts: None,
                    has_layout_state: true,
                    window_focus: Some((10, false)),
                },
            ],
            focus_tab_index: Some(1),
        };

        let phases = plan.all_phases();

        // Tab 1: layout -> enabled_layouts (2 phases)
        // Tab 2: layout -> layout_state -> window_focus (3 phases)
        // Final: tab_focus (1 phase)
        // Total: 2 + 3 + 1 = 6
        assert_eq!(phases.len(), 6);
        assert_eq!(phases[0], ReplayPhase::ApplyLayout); // tab 1
        assert_eq!(phases[1], ReplayPhase::ApplyEnabledLayouts); // tab 1
        assert_eq!(phases[2], ReplayPhase::ApplyLayout); // tab 2
        assert_eq!(phases[3], ReplayPhase::HandleLayoutState); // tab 2
        assert_eq!(phases[4], ReplayPhase::ApplyWindowFocus); // tab 2
        assert_eq!(phases[5], ReplayPhase::ApplyTabFocus); // final
    }

    #[test]
    fn test_resolve_focus_tab_index_success() {
        // Test valid index resolution
        let tab_ids = [100u32, 200, 300];

        assert_eq!(resolve_focus_tab_index(Some(0), &tab_ids), Some(100));
        assert_eq!(resolve_focus_tab_index(Some(1), &tab_ids), Some(200));
        assert_eq!(resolve_focus_tab_index(Some(2), &tab_ids), Some(300));
    }

    #[test]
    fn test_resolve_focus_tab_index_out_of_range() {
        // Test out-of-range index returns None
        let tab_ids = [100u32, 200, 300];

        assert_eq!(resolve_focus_tab_index(Some(3), &tab_ids), None); // beyond length
        assert_eq!(resolve_focus_tab_index(Some(100), &tab_ids), None); // way beyond
    }

    #[test]
    fn test_resolve_focus_tab_index_none() {
        // Test None index returns None
        let tab_ids = [100u32, 200, 300];

        assert_eq!(resolve_focus_tab_index(None, &tab_ids), None);
    }
}
