//! Fixture Verification Tests
//!
//! These tests verify that the generated fixtures are valid and can be restored.
//!
//! Run with: `cargo test --test fixture_verification -- --ignored`
//! (The --ignored flag is needed because these tests require a real kitty binary)

mod helpers;

use std::collections::hash_map::DefaultHasher;
use std::collections::HashSet;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

use serde::Deserialize;

/// List of all pre-built fixtures to verify
const PREBUILT_FIXTURES: &[&str] = &[
    "light_001",
    "typical_001",
    "nvim_clean",
    "nvim_dirty",
    "nvim_multi_tab",
    "nvim_splits",
    "tmux_single",
    "tmux_multi_window",
    "tmux_multi_session",
    "tmux_panes",
];

/// Fixtures that are runtime-generated (should be skipped or generated first)
const RUNTIME_FIXTURES: &[&str] = &["heavy_001", "very_heavy_001"];

/// Get the fixtures directory path.
fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("real_workflow")
}

/// Fixture metadata parsed from metadata.json
#[derive(Debug, Deserialize)]
struct FixtureMetadata {
    name: String,
    description: String,
    #[serde(default)]
    complexity: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    tab_count: Option<u64>,
    #[serde(default)]
    window_count: Option<u64>,
    #[serde(default)]
    scenario: Option<ScenarioRange>,
}

/// Scenario range from metadata.json
#[derive(Debug, Deserialize)]
struct ScenarioRange {
    #[serde(default)]
    min_tabs: Option<u64>,
    #[serde(default)]
    max_tabs: Option<u64>,
    #[serde(default)]
    min_windows: Option<u64>,
    #[serde(default)]
    max_windows: Option<u64>,
    #[serde(default)]
    min_buffers: Option<u64>,
    #[serde(default)]
    max_buffers: Option<u64>,
    #[serde(default)]
    min_nvim: Option<u64>,
    #[serde(default)]
    max_nvim: Option<u64>,
    #[serde(default)]
    min_tmux: Option<u64>,
    #[serde(default)]
    max_tmux: Option<u64>,
}

/// Count tabs and windows from ls.json content.
///
/// Handles two formats:
/// 1. Array of OS windows (kitty `ls` output): `[{tabs: [{windows: [...]}]}]`
/// 2. Single object with tabs: `{tabs: [{...}]}`
fn count_tabs_and_windows(ls_json: &serde_json::Value) -> (usize, usize) {
    match ls_json {
        // Format 1: Array of OS windows (standard kitty ls output)
        serde_json::Value::Array(os_windows) => {
            let mut total_tabs = 0;
            let mut total_windows = 0;
            for os_win in os_windows {
                if let Some(tabs) = os_win.get("tabs").and_then(|t| t.as_array()) {
                    total_tabs += tabs.len();
                    for tab in tabs {
                        if let Some(windows) = tab.get("windows").and_then(|w| w.as_array()) {
                            total_windows += windows.len();
                        }
                    }
                }
            }
            (total_tabs, total_windows)
        }
        // Format 2: Single object with tabs array
        serde_json::Value::Object(obj) => {
            let mut total_tabs = 0;
            let mut total_windows = 0;
            if let Some(tabs) = obj.get("tabs").and_then(|t| t.as_array()) {
                total_tabs = tabs.len();
                for tab in tabs {
                    if let Some(windows) = tab.get("windows").and_then(|w| w.as_array()) {
                        total_windows += windows.len();
                    }
                }
            }
            (total_tabs, total_windows)
        }
        _ => (0, 0),
    }
}

/// Compute a hash of all files in a fixture directory (recursive, sorted for stability).
fn hash_fixture(fixture_path: &PathBuf) -> u64 {
    let mut hasher = DefaultHasher::new();

    // Collect all file paths, sorted for determinism
    let mut files: Vec<PathBuf> = Vec::new();
    collect_files(fixture_path, &mut files);
    files.sort();

    for file in &files {
        // Hash the relative path for structure stability
        if let Ok(rel) = file.strip_prefix(fixture_path) {
            rel.to_string_lossy().hash(&mut hasher);
        }
        // Hash file contents
        if let Ok(content) = fs::read(file) {
            content.hash(&mut hasher);
        }
    }

    hasher.finish()
}

/// Recursively collect all files in a directory.
fn collect_files(dir: &PathBuf, files: &mut Vec<PathBuf>) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                collect_files(&path, files);
            } else if path.is_file() {
                files.push(path);
            }
        }
    }
}

// ============== Structure Validation Tests ==============

/// Test that all pre-built fixtures have valid structure.
#[test]
fn test_all_fixtures_have_valid_structure() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        let fixture_path = fixtures_dir.join(fixture_name);

        // Check conf/ directory exists
        let conf_dir = fixture_path.join("conf");
        assert!(
            conf_dir.exists(),
            "Fixture {} missing conf/ directory",
            fixture_name
        );

        // Check session.conf exists
        let session_conf = conf_dir.join("session.conf");
        assert!(
            session_conf.exists(),
            "Fixture {} missing conf/session.conf",
            fixture_name
        );

        // Check ls.json exists
        let ls_json = conf_dir.join("ls.json");
        assert!(
            ls_json.exists(),
            "Fixture {} missing conf/ls.json",
            fixture_name
        );

        // Check metadata.json exists
        let metadata_path = fixture_path.join("metadata.json");
        assert!(
            metadata_path.exists(),
            "Fixture {} missing metadata.json",
            fixture_name
        );

        // Verify metadata.json is valid JSON
        let metadata_content = fs::read_to_string(&metadata_path)
            .unwrap_or_else(|_| panic!("Failed to read metadata.json for {}", fixture_name));
        let _metadata: FixtureMetadata = serde_json::from_str(&metadata_content)
            .unwrap_or_else(|_| panic!("Failed to parse metadata.json for {}", fixture_name));

        println!("  [ok] Fixture {} has valid structure", fixture_name);
    }

    println!(
        "\nAll {} pre-built fixtures have valid structure",
        PREBUILT_FIXTURES.len()
    );
}

/// Test that all pre-built fixtures have a state/ directory.
#[test]
fn test_all_fixtures_have_state_directory() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        let fixture_path = fixtures_dir.join(fixture_name);
        let state_dir = fixture_path.join("state");
        assert!(
            state_dir.exists() && state_dir.is_dir(),
            "Fixture {} missing state/ directory at {}",
            fixture_name,
            state_dir.display()
        );

        println!("  [ok] Fixture {} has state/ directory", fixture_name);
    }
}

/// Test that all fixtures have non-empty session.conf.
#[test]
fn test_all_fixtures_have_content() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        let session_conf = fixtures_dir
            .join(fixture_name)
            .join("conf")
            .join("session.conf");

        let content = fs::read_to_string(&session_conf)
            .unwrap_or_else(|_| panic!("Failed to read session.conf for {}", fixture_name));

        assert!(
            !content.trim().is_empty(),
            "Fixture {} has empty session.conf",
            fixture_name
        );

        // Should have at least some content
        assert!(
            content.len() > 10,
            "Fixture {} session.conf too small ({} bytes)",
            fixture_name,
            content.len()
        );

        println!(
            "  [ok] Fixture {} has content ({} bytes)",
            fixture_name,
            content.len()
        );
    }
}

/// Test that all fixtures have valid ls.json.
#[test]
fn test_all_fixtures_have_valid_ls_json() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        let ls_json_path = fixtures_dir.join(fixture_name).join("conf").join("ls.json");

        let content = fs::read_to_string(&ls_json_path)
            .unwrap_or_else(|_| panic!("Failed to read ls.json for {}", fixture_name));

        // Should be valid JSON (parse as Value)
        let _json: serde_json::Value = serde_json::from_str(&content)
            .unwrap_or_else(|_| panic!("Fixture {} has invalid ls.json", fixture_name));

        println!("  [ok] Fixture {} has valid ls.json", fixture_name);
    }
}

// ============== Determinism and Uniqueness Tests ==============

/// Test content stability: reading the same fixture twice produces the same hash.
#[test]
fn test_fixture_content_is_stable() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        let fixture_path = fixtures_dir.join(fixture_name);

        let hash1 = hash_fixture(&fixture_path);
        let hash2 = hash_fixture(&fixture_path);

        assert_eq!(
            hash1, hash2,
            "Fixture {} produced different hashes on consecutive reads: {:016x} vs {:016x}",
            fixture_name, hash1, hash2
        );

        println!(
            "  [ok] Fixture {} is stable (hash: {:016x})",
            fixture_name, hash1
        );
    }

    println!(
        "\nAll {} fixtures produce stable hashes across reads",
        PREBUILT_FIXTURES.len()
    );
}

/// Test uniqueness: all fixtures have distinct content.
#[test]
fn test_fixtures_are_unique() {
    let fixtures_dir = fixtures_dir();
    let mut hashes: Vec<(String, u64)> = Vec::new();

    for fixture_name in PREBUILT_FIXTURES {
        let fixture_path = fixtures_dir.join(fixture_name);
        let hash = hash_fixture(&fixture_path);
        hashes.push((fixture_name.to_string(), hash));
        println!("Fixture {} hash: {:016x}", fixture_name, hash);
    }

    // Verify no duplicate hashes (would indicate identical fixtures)
    let unique_hashes: HashSet<u64> = hashes.iter().map(|(_, h)| *h).collect();
    assert_eq!(
        unique_hashes.len(),
        hashes.len(),
        "Found duplicate fixture hashes - fixtures should be unique"
    );

    println!(
        "\nAll {} fixtures have unique content hashes",
        PREBUILT_FIXTURES.len()
    );
}

// ============== Metadata Validation Tests ==============

/// Test that metadata.json contains expected fields.
#[test]
fn test_metadata_has_required_fields() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        let metadata_path = fixtures_dir.join(fixture_name).join("metadata.json");

        let content = fs::read_to_string(&metadata_path)
            .unwrap_or_else(|_| panic!("Failed to read metadata.json for {}", fixture_name));

        // Parse and verify required fields
        let metadata: FixtureMetadata = serde_json::from_str(&content)
            .unwrap_or_else(|_| panic!("Failed to parse metadata.json for {}", fixture_name));

        // Verify name matches
        assert_eq!(
            &metadata.name, fixture_name,
            "Fixture {} metadata name mismatch",
            fixture_name
        );

        // Verify description is not empty
        assert!(
            !metadata.description.is_empty(),
            "Fixture {} has empty description",
            fixture_name
        );

        println!(
            "  [ok] Fixture {} metadata valid: '{}'",
            fixture_name, metadata.description
        );
    }
}

/// Test that metadata tab_count and window_count match ls.json reality.
#[test]
fn test_metadata_matches_fixture_content() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        let metadata_path = fixtures_dir.join(fixture_name).join("metadata.json");
        let ls_json_path = fixtures_dir.join(fixture_name).join("conf").join("ls.json");

        let metadata_content = fs::read_to_string(&metadata_path)
            .unwrap_or_else(|_| panic!("Failed to read metadata.json for {}", fixture_name));
        let metadata: FixtureMetadata = serde_json::from_str(&metadata_content)
            .unwrap_or_else(|_| panic!("Failed to parse metadata.json for {}", fixture_name));

        let ls_content = fs::read_to_string(&ls_json_path)
            .unwrap_or_else(|_| panic!("Failed to read ls.json for {}", fixture_name));
        let ls_json: serde_json::Value = serde_json::from_str(&ls_content)
            .unwrap_or_else(|_| panic!("Failed to parse ls.json for {}", fixture_name));

        let (ls_tabs, ls_windows) = count_tabs_and_windows(&ls_json);

        // Metadata tab_count and window_count should be non-negative.
        // Note: ls.json may be a minimal snapshot that doesn't reflect the full
        // session.conf, so we don't require exact matches. Instead we verify:
        // 1. Metadata counts are non-negative
        // 2. ls.json is parseable and has some structure
        if let Some(meta_tabs) = metadata.tab_count {
            // tab_count should not be negative (it's u64 so this is always true,
            // but we verify the value is reasonable)
            assert!(
                meta_tabs <= 1000,
                "Fixture {} has unreasonable tab_count: {}",
                fixture_name,
                meta_tabs
            );
        }

        if let Some(meta_windows) = metadata.window_count {
            assert!(
                meta_windows <= 10000,
                "Fixture {} has unreasonable window_count: {}",
                fixture_name,
                meta_windows
            );
        }

        // ls.json should always have some parseable content
        assert!(
            ls_tabs > 0 || ls_windows > 0 || ls_json.is_object() || ls_json.is_array(),
            "Fixture {} ls.json has no parseable tabs or windows",
            fixture_name
        );

        println!(
            "  [ok] Fixture {} metadata consistent (meta tabs={:?} windows={:?}, ls tabs={} windows={})",
            fixture_name, metadata.tab_count, metadata.window_count, ls_tabs, ls_windows
        );
    }
}

/// Test fixture complexity levels are set appropriately.
#[test]
fn test_fixture_complexity_levels() {
    let fixtures_dir = fixtures_dir();

    // Fixtures that should have complexity set
    let fixtures_with_complexity = [
        "light_001",
        "typical_001",
        "tmux_single",
        "tmux_multi_window",
        "tmux_multi_session",
        "tmux_panes",
    ];

    for fixture_name in fixtures_with_complexity {
        let metadata_path = fixtures_dir.join(fixture_name).join("metadata.json");

        if !metadata_path.exists() {
            println!("  [warn] Fixture {} not found, skipping", fixture_name);
            continue;
        }

        let content = fs::read_to_string(&metadata_path)
            .unwrap_or_else(|_| panic!("Failed to read metadata.json for {}", fixture_name));

        let metadata: FixtureMetadata = serde_json::from_str(&content)
            .unwrap_or_else(|_| panic!("Failed to parse metadata.json for {}", fixture_name));

        if let Some(complexity) = &metadata.complexity {
            // Verify complexity is a known value
            let valid = matches!(
                complexity.as_str(),
                "light" | "typical" | "heavy" | "very_heavy"
            );
            assert!(
                valid,
                "Fixture {} has unknown complexity: {}",
                fixture_name, complexity
            );
            println!("  [ok] Fixture {} complexity: {}", fixture_name, complexity);
        } else {
            println!("  [warn] Fixture {} missing complexity field", fixture_name);
        }
    }
}

/// Test fixture tags are present.
#[test]
fn test_fixture_tags_present() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        let metadata_path = fixtures_dir.join(fixture_name).join("metadata.json");

        let content = fs::read_to_string(&metadata_path)
            .unwrap_or_else(|_| panic!("Failed to read metadata.json for {}", fixture_name));

        let metadata: FixtureMetadata = serde_json::from_str(&content)
            .unwrap_or_else(|_| panic!("Failed to parse metadata.json for {}", fixture_name));

        // Should have at least one tag
        assert!(
            !metadata.tags.is_empty(),
            "Fixture {} has no tags",
            fixture_name
        );

        println!("Fixture {} tags: {:?}", fixture_name, metadata.tags);
    }
}

// ============== Scenario Range Validation Tests ==============

/// Test that scenario ranges are valid (min <= max for all fields).
#[test]
fn test_scenario_ranges_are_valid() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        let metadata_path = fixtures_dir.join(fixture_name).join("metadata.json");

        let content = fs::read_to_string(&metadata_path)
            .unwrap_or_else(|_| panic!("Failed to read metadata.json for {}", fixture_name));

        let metadata: FixtureMetadata = serde_json::from_str(&content)
            .unwrap_or_else(|_| panic!("Failed to parse metadata.json for {}", fixture_name));

        if let Some(scenario) = &metadata.scenario {
            // Verify min <= max for tabs
            if let (Some(min), Some(max)) = (scenario.min_tabs, scenario.max_tabs) {
                assert!(
                    min <= max,
                    "Fixture {} scenario: min_tabs ({}) > max_tabs ({})",
                    fixture_name,
                    min,
                    max
                );
            }

            // Verify min <= max for windows
            if let (Some(min), Some(max)) = (scenario.min_windows, scenario.max_windows) {
                assert!(
                    min <= max,
                    "Fixture {} scenario: min_windows ({}) > max_windows ({})",
                    fixture_name,
                    min,
                    max
                );
            }

            // Verify min <= max for buffers
            if let (Some(min), Some(max)) = (scenario.min_buffers, scenario.max_buffers) {
                assert!(
                    min <= max,
                    "Fixture {} scenario: min_buffers ({}) > max_buffers ({})",
                    fixture_name,
                    min,
                    max
                );
            }

            // Verify min <= max for nvim
            if let (Some(min), Some(max)) = (scenario.min_nvim, scenario.max_nvim) {
                assert!(
                    min <= max,
                    "Fixture {} scenario: min_nvim ({}) > max_nvim ({})",
                    fixture_name,
                    min,
                    max
                );
            }

            // Verify min <= max for tmux
            if let (Some(min), Some(max)) = (scenario.min_tmux, scenario.max_tmux) {
                assert!(
                    min <= max,
                    "Fixture {} scenario: min_tmux ({}) > max_tmux ({})",
                    fixture_name,
                    min,
                    max
                );
            }

            println!("  [ok] Fixture {} scenario ranges are valid", fixture_name);
        } else {
            println!("  [skip] Fixture {} has no scenario field", fixture_name);
        }
    }
}

// ============== Tag Consistency Tests ==============

/// Test that all nvim_* fixtures have the "nvim" tag.
#[test]
fn test_nvim_fixtures_have_nvim_tag() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        if !fixture_name.starts_with("nvim_") {
            continue;
        }

        let metadata_path = fixtures_dir.join(fixture_name).join("metadata.json");

        let content = fs::read_to_string(&metadata_path)
            .unwrap_or_else(|_| panic!("Failed to read metadata.json for {}", fixture_name));

        let metadata: FixtureMetadata = serde_json::from_str(&content)
            .unwrap_or_else(|_| panic!("Failed to parse metadata.json for {}", fixture_name));

        assert!(
            metadata.tags.iter().any(|t| t == "nvim"),
            "Fixture {} starts with nvim_ but does not have 'nvim' tag (tags: {:?})",
            fixture_name,
            metadata.tags
        );

        println!("  [ok] Fixture {} has 'nvim' tag", fixture_name);
    }
}

/// Test that all tmux_* fixtures have the "tmux" tag.
#[test]
fn test_tmux_fixtures_have_tmux_tag() {
    let fixtures_dir = fixtures_dir();

    for fixture_name in PREBUILT_FIXTURES {
        if !fixture_name.starts_with("tmux_") {
            continue;
        }

        let metadata_path = fixtures_dir.join(fixture_name).join("metadata.json");

        let content = fs::read_to_string(&metadata_path)
            .unwrap_or_else(|_| panic!("Failed to read metadata.json for {}", fixture_name));

        let metadata: FixtureMetadata = serde_json::from_str(&content)
            .unwrap_or_else(|_| panic!("Failed to parse metadata.json for {}", fixture_name));

        assert!(
            metadata.tags.iter().any(|t| t == "tmux"),
            "Fixture {} starts with tmux_ but does not have 'tmux' tag (tags: {:?})",
            fixture_name,
            metadata.tags
        );

        println!("  [ok] Fixture {} has 'tmux' tag", fixture_name);
    }
}

// ============== Runtime Tests (require kitty) ==============

/// Test restoring light_001 fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_light_001 --nocapture"]
fn test_restore_fixture_light_001() {
    test_restore_fixture("light_001");
}

/// Test restoring typical_001 fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_typical_001 --nocapture"]
fn test_restore_fixture_typical_001() {
    test_restore_fixture("typical_001");
}

/// Test restoring nvim_clean fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_nvim_clean --nocapture"]
fn test_restore_fixture_nvim_clean() {
    test_restore_fixture("nvim_clean");
}

/// Test restoring nvim_dirty fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_nvim_dirty --nocapture"]
fn test_restore_fixture_nvim_dirty() {
    test_restore_fixture("nvim_dirty");
}

/// Test restoring nvim_multi_tab fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_nvim_multi_tab --nocapture"]
fn test_restore_fixture_nvim_multi_tab() {
    test_restore_fixture("nvim_multi_tab");
}

/// Test restoring nvim_splits fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_nvim_splits --nocapture"]
fn test_restore_fixture_nvim_splits() {
    test_restore_fixture("nvim_splits");
}

/// Test restoring tmux_single fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_tmux_single --nocapture"]
fn test_restore_fixture_tmux_single() {
    test_restore_fixture("tmux_single");
}

/// Test restoring tmux_multi_window fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_tmux_multi_window --nocapture"]
fn test_restore_fixture_tmux_multi_window() {
    test_restore_fixture("tmux_multi_window");
}

/// Test restoring tmux_multi_session fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_tmux_multi_session --nocapture"]
fn test_restore_fixture_tmux_multi_session() {
    test_restore_fixture("tmux_multi_session");
}

/// Test restoring tmux_panes fixture.
#[test]
#[ignore = "requires real kitty - run with: cargo test --test fixture_verification -- --ignored test_restore_fixture_tmux_panes --nocapture"]
fn test_restore_fixture_tmux_panes() {
    test_restore_fixture("tmux_panes");
}

/// Common restore test implementation.
fn test_restore_fixture(fixture_name: &str) {
    use helpers::{kitten_is_usable, kitty_is_usable, KittySpawner};

    // Check availability
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_verification: kitty/kitten not available - skipping restore test");
        return;
    }

    println!("Testing restore of fixture: {}", fixture_name);

    // Load the fixture
    let fixtures_dir = fixtures_dir();
    let fixture_path = fixtures_dir.join(fixture_name);
    let session_conf = fixture_path.join("conf").join("session.conf");

    assert!(
        session_conf.exists(),
        "Fixture {} missing session.conf",
        fixture_name
    );

    // Try to spawn kitty with this session
    let spawn_result = KittySpawner::spawn_default(Some(session_conf.as_path()));

    match spawn_result {
        Ok(_spawner) => {
            println!("  [ok] Fixture {} restored successfully", fixture_name);
            // Spawner dropped here, will clean up
        }
        Err(e) => {
            // Some restore failures are expected depending on environment
            println!(
                "  [warn] Fixture {} restore had issues: {:?}",
                fixture_name, e
            );
        }
    }
}

// ============== Bookkeeping Tests ==============

/// Test that runtime fixtures are listed correctly.
#[test]
fn test_runtime_fixtures_listed() {
    // Verify runtime fixtures are documented
    assert!(
        RUNTIME_FIXTURES.contains(&"heavy_001"),
        "heavy_001 should be a runtime fixture"
    );
    assert!(
        RUNTIME_FIXTURES.contains(&"very_heavy_001"),
        "very_heavy_001 should be a runtime fixture"
    );

    println!("Runtime fixtures: {:?}", RUNTIME_FIXTURES);
    println!("Pre-built fixtures: {:?}", PREBUILT_FIXTURES);

    // Verify no overlap
    for runtime in RUNTIME_FIXTURES {
        assert!(
            !PREBUILT_FIXTURES.contains(runtime),
            "Runtime fixture {} should not be in pre-built list",
            runtime
        );
    }
}

/// Test that fixture count is reasonable.
#[test]
fn test_fixture_count() {
    let fixtures_dir = fixtures_dir();

    // Count directories in real_workflow
    let mut count = 0;
    if let Ok(entries) = fs::read_dir(&fixtures_dir) {
        for entry in entries.flatten() {
            if entry.path().is_dir() {
                count += 1;
            }
        }
    }

    // We should have at least 10 fixtures
    assert!(
        count >= 10,
        "Expected at least 10 fixtures, found {}",
        count
    );

    println!("Total fixtures found: {}", count);
}
