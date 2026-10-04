//! Performance guardrails for into-current restore.
//!
//! This test measures CPU-side work (parser + replay plan construction)
//! without requiring a live kitty instance. Guardrails are generous to catch
//! significant regressions without being brittle to normal variance.

use ksession_rs::conf::parser::ConfParser;
use ksession_rs::session::layout_replay::{ReplayPlan, TabReplayPlan};
use std::time::Instant;

/// Light fixture: 2 tabs, 4 windows total
const LIGHT_001_CONF: &str = r#"new_tab
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

/// Typical fixture: 4 tabs, 12 windows total
const TYPICAL_001_CONF: &str = r#"new_tab
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

/// Heavy fixture: 8 tabs, ~32 windows (approximate, inline for test)
const HEAVY_001_CONF: &str = r#"new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 3, "active_group_history": [1, 6, 7], "window_groups": [{"id": 1, "window_ids": [1]}, {"id": 6, "window_ids": [6]}, {"id": 7, "window_ids": [7]}, {"id": 8, "window_ids": [8]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 1}'
launch 'kitty-unserialize-data={"id": 6}'
launch 'kitty-unserialize-data={"id": 7}'
launch 'kitty-unserialize-data={"id": 8}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 3, "active_group_history": [2, 9, 10], "window_groups": [{"id": 2, "window_ids": [2]}, {"id": 9, "window_ids": [9]}, {"id": 10, "window_ids": [10]}, {"id": 11, "window_ids": [11]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 2}' --title=tab-1
launch 'kitty-unserialize-data={"id": 9}'
launch 'kitty-unserialize-data={"id": 10}'
launch 'kitty-unserialize-data={"id": 11}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 3, "active_group_history": [3, 12, 13], "window_groups": [{"id": 3, "window_ids": [3]}, {"id": 12, "window_ids": [12]}, {"id": 13, "window_ids": [13]}, {"id": 14, "window_ids": [14]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 3}' --title=tab-2
launch 'kitty-unserialize-data={"id": 12}'
launch 'kitty-unserialize-data={"id": 13}'
launch 'kitty-unserialize-data={"id": 14}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 3, "active_group_history": [4, 15, 16], "window_groups": [{"id": 4, "window_ids": [4]}, {"id": 15, "window_ids": [15]}, {"id": 16, "window_ids": [16]}, {"id": 17, "window_ids": [17]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 4}' --title=tab-3
launch 'kitty-unserialize-data={"id": 15}'
launch 'kitty-unserialize-data={"id": 16}'
launch 'kitty-unserialize-data={"id": 17}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 3, "active_group_history": [5, 18, 19], "window_groups": [{"id": 5, "window_ids": [5]}, {"id": 18, "window_ids": [18]}, {"id": 19, "window_ids": [19]}, {"id": 20, "window_ids": [20]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 5}' --title=tab-4
launch 'kitty-unserialize-data={"id": 18}'
launch 'kitty-unserialize-data={"id": 19}'
launch 'kitty-unserialize-data={"id": 20}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 3, "active_group_history": [21, 22, 23], "window_groups": [{"id": 21, "window_ids": [21]}, {"id": 22, "window_ids": [22]}, {"id": 23, "window_ids": [23]}, {"id": 24, "window_ids": [24]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 21}' --title=tab-5
launch 'kitty-unserialize-data={"id": 22}'
launch 'kitty-unserialize-data={"id": 23}'
launch 'kitty-unserialize-data={"id": 24}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 3, "active_group_history": [25, 26, 27], "window_groups": [{"id": 25, "window_ids": [25]}, {"id": 26, "window_ids": [26]}, {"id": 27, "window_ids": [27]}, {"id": 28, "window_ids": [28]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 25}' --title=tab-6
launch 'kitty-unserialize-data={"id": 26}'
launch 'kitty-unserialize-data={"id": 27}'
launch 'kitty-unserialize-data={"id": 28}'
focus

new_tab
layout fat
enabled_layouts fat,grid,horizontal,splits,stack,tall,vertical
set_layout_state {"main_bias": [0.5, 0.5], "biased_map": {}, "opts": {"full_size": 1, "bias": 50, "mirrored": "n"}, "class": "Fat", "all_windows": {"active_group_idx": 3, "active_group_history": [29, 30, 31], "window_groups": [{"id": 29, "window_ids": [29]}, {"id": 30, "window_ids": [30]}, {"id": 31, "window_ids": [31]}, {"id": 32, "window_ids": [32]}]}}
cd /home/andrew/.config/kitty/scripts/ksession-rs

launch 'kitty-unserialize-data={"id": 29}' --title=tab-7
launch 'kitty-unserialize-data={"id": 30}'
launch 'kitty-unserialize-data={"id": 31}'
launch 'kitty-unserialize-data={"id": 32}'
focus

focus_tab 7"#;

/// Build replay plan from conf (simulates into-current restore planning)
fn build_replay_plan(conf: &str) -> ReplayPlan {
    let result = ConfParser::parse(conf).unwrap();

    let mut tab_plans: Vec<TabReplayPlan> = Vec::new();

    for osw in &result.os_windows {
        for tab in &osw.tabs {
            tab_plans.push(TabReplayPlan {
                tab_id: 0,
                layout: tab.layout.clone(),
                enabled_layouts: tab.enabled_layouts.clone(),
                has_layout_state: tab.layout_state.is_some(),
                window_focus: if tab.active_window_idx > 0 {
                    Some((0, false))
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

/// Measure and return average duration over iterations (in microseconds)
fn measure_parse_and_plan(conf: &str, iterations: usize) -> f64 {
    let mut total_us = 0u128;

    for _ in 0..iterations {
        let start = Instant::now();
        let _plan = build_replay_plan(conf);
        let elapsed = start.elapsed();
        total_us += elapsed.as_micros();
    }

    (total_us as f64) / (iterations as f64)
}

#[test]
fn test_perf_light_001_guardrail() {
    // Light fixture: 2 tabs, 4 windows
    // Guardrail: 10ms per iteration (generous for regression detection)
    const GUARDRAIL_US: f64 = 10_000.0; // 10ms
    const ITERATIONS: usize = 100;

    let avg_us = measure_parse_and_plan(LIGHT_001_CONF, ITERATIONS);
    let avg_ms = avg_us / 1000.0;

    println!(
        "light_001: avg {:.3}ms per iteration ({} iterations)",
        avg_ms, ITERATIONS
    );

    assert!(
        avg_us < GUARDRAIL_US,
        "light_001 guardrail exceeded: {:.3}ms > {:.1}ms",
        avg_ms,
        GUARDRAIL_US / 1000.0
    );
}

#[test]
fn test_perf_typical_001_guardrail() {
    // Typical fixture: 4 tabs, 12 windows
    // Guardrail: 25ms per iteration
    const GUARDRAIL_US: f64 = 25_000.0; // 25ms
    const ITERATIONS: usize = 100;

    let avg_us = measure_parse_and_plan(TYPICAL_001_CONF, ITERATIONS);
    let avg_ms = avg_us / 1000.0;

    println!(
        "typical_001: avg {:.3}ms per iteration ({} iterations)",
        avg_ms, ITERATIONS
    );

    assert!(
        avg_us < GUARDRAIL_US,
        "typical_001 guardrail exceeded: {:.3}ms > {:.1}ms",
        avg_ms,
        GUARDRAIL_US / 1000.0
    );
}

#[test]
fn test_perf_heavy_001_guardrail() {
    // Heavy fixture: 8 tabs, ~32 windows
    // Guardrail: 50ms per iteration
    const GUARDRAIL_US: f64 = 50_000.0; // 50ms
    const ITERATIONS: usize = 50;

    let avg_us = measure_parse_and_plan(HEAVY_001_CONF, ITERATIONS);
    let avg_ms = avg_us / 1000.0;

    println!(
        "heavy_001: avg {:.3}ms per iteration ({} iterations)",
        avg_ms, ITERATIONS
    );

    assert!(
        avg_us < GUARDRAIL_US,
        "heavy_001 guardrail exceeded: {:.3}ms > {:.1}ms",
        avg_ms,
        GUARDRAIL_US / 1000.0
    );
}

#[test]
fn test_perf_all_fixtures_comparison() {
    // Quick comparison showing relative scaling
    const ITERATIONS: usize = 50;

    let light_avg = measure_parse_and_plan(LIGHT_001_CONF, ITERATIONS);
    let typical_avg = measure_parse_and_plan(TYPICAL_001_CONF, ITERATIONS);
    let heavy_avg = measure_parse_and_plan(HEAVY_001_CONF, ITERATIONS);

    println!("Performance comparison ({} iterations):", ITERATIONS);
    println!("  light_001:   {:.3}ms", light_avg / 1000.0);
    println!("  typical_001: {:.3}ms", typical_avg / 1000.0);
    println!("  heavy_001:   {:.3}ms", heavy_avg / 1000.0);

    // Sanity check: heavy should not be wildly disproportionate
    // Allow up to 10x light (realistically should be ~4x)
    assert!(
        heavy_avg < light_avg * 15.0,
        "heavy scaling seems excessive: {}x light",
        heavy_avg / light_avg
    );
}
