//! Regression tests for key behaviors.
//!
//! This file contains tests for various edge cases and behaviors that have
//! caused issues in the past.

use ksession_rs::session::{save, SaveOpts};

use tempfile::tempdir;

// --- Tests ---------------------------------------------------------------

/// Test that save with from_ls fixture produces valid manifest.
#[tokio::test]
async fn save_with_from_ls_fixture() {
    let ls_json = serde_json::json!([
        {
            "id": 1,
            "tabs": [
                {
                    "id": 1,
                    "windows": [
                        {
                            "id": 1,
                            "pid": 100,
                            "cwd": "/home/user",
                            "foreground_processes": [{"pid": 100, "cmdline": ["/bin/bash"]}]
                        }
                    ]
                }
            ]
        }
    ]);

    let tmp = tempdir().unwrap();
    let sessions_dir = tmp.path().to_path_buf();
    std::fs::create_dir_all(&sessions_dir).expect("create sessions dir");

    // Write fixture file
    let fixture_path = tmp.path().join("fixture.json");
    std::fs::write(&fixture_path, serde_json::to_string(&ls_json).unwrap()).unwrap();

    let skeleton = "new_tab\nlaunch /bin/bash -l\n";
    let skeleton_path = tmp.path().join("skeleton.txt");
    std::fs::write(&skeleton_path, skeleton).unwrap();

    let result = save(SaveOpts {
        name: "test_fixture".to_string(),
        all: true,
        scrollback: false,
        sessions_dir: sessions_dir.clone(),
        from_ls: Some(fixture_path),
        from_skeleton: Some(skeleton_path),
        pre_pool: None,
    })
    .await;

    assert!(
        result.is_ok(),
        "save with from_ls should succeed: {:?}",
        result.err()
    );

    // Verify manifest was created
    let entries = std::fs::read_dir(&sessions_dir).unwrap();
    let gen_dirs: Vec<_> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("test_fixture.gen-"))
                .unwrap_or(false)
        })
        .collect();

    assert!(
        !gen_dirs.is_empty(),
        "should have created gen-stamped directory"
    );
}

/// Test that save with from_ls fixture with multiple tabs works.
#[tokio::test]
async fn save_with_from_ls_multiple_tabs() {
    let ls_json = serde_json::json!([
        {
            "id": 1,
            "tabs": [
                {
                    "id": 1,
                    "title": "Tab 1",
                    "layout": "splits",
                    "windows": [
                        {"id": 1, "pid": 100, "cwd": "/home/user", "foreground_processes": [{"pid": 100, "cmdline": ["/bin/bash"]}]},
                        {"id": 2, "pid": 101, "cwd": "/home/user", "foreground_processes": [{"pid": 101, "cmdline": ["/bin/bash"]}]}
                    ]
                },
                {
                    "id": 2,
                    "title": "Tab 2",
                    "layout": "stack",
                    "windows": [
                        {"id": 3, "pid": 102, "cwd": "/home/user/project", "foreground_processes": [{"pid": 102, "cmdline": ["/bin/zsh"]}]}
                    ]
                }
            ]
        }
    ]);

    let tmp = tempdir().unwrap();
    let sessions_dir = tmp.path().to_path_buf();
    std::fs::create_dir_all(&sessions_dir).expect("create sessions dir");

    // Write fixture file
    let fixture_path = tmp.path().join("fixture.json");
    std::fs::write(&fixture_path, serde_json::to_string(&ls_json).unwrap()).unwrap();

    let skeleton = "new_tab\nlaunch /bin/bash -l\n";
    let skeleton_path = tmp.path().join("skeleton.txt");
    std::fs::write(&skeleton_path, skeleton).unwrap();

    let result = save(SaveOpts {
        name: "test_multi_tab".to_string(),
        all: true,
        scrollback: false,
        sessions_dir: sessions_dir.clone(),
        from_ls: Some(fixture_path),
        from_skeleton: Some(skeleton_path),
        pre_pool: None,
    })
    .await;

    assert!(
        result.is_ok(),
        "save with multiple tabs should succeed: {:?}",
        result.err()
    );

    // Verify manifest was created
    let entries = std::fs::read_dir(&sessions_dir).unwrap();
    let gen_dirs: Vec<_> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("test_multi_tab.gen-"))
                .unwrap_or(false)
        })
        .collect();

    assert!(
        !gen_dirs.is_empty(),
        "should have created gen-stamped directory"
    );

    // Verify manifest has correct structure
    let manifest_path = gen_dirs[0].join("manifest.json");
    let manifest_content = std::fs::read_to_string(&manifest_path).unwrap();
    let manifest: serde_json::Value = serde_json::from_str(&manifest_content).unwrap();

    // Should have 2 tabs
    let tabs = manifest["os_windows"][0]["tabs"].as_array().unwrap();
    assert_eq!(tabs.len(), 2, "should have 2 tabs");

    // First tab should have 2 windows
    assert_eq!(
        tabs[0]["windows"].as_array().unwrap().len(),
        2,
        "first tab should have 2 windows"
    );
}

/// Test that save with from_ls fixture works with nvim process.
#[tokio::test]
async fn save_with_from_ls_nvim_process() {
    let ls_json = serde_json::json!([
        {
            "id": 1,
            "tabs": [
                {
                    "id": 1,
                    "windows": [
                        {"id": 1, "pid": 100, "cwd": "/home/user", "foreground_processes": [{"pid": 100, "cmdline": ["/bin/bash", "-c", "nvim"]}]}
                    ]
                }
            ]
        }
    ]);

    let tmp = tempdir().unwrap();
    let sessions_dir = tmp.path().to_path_buf();
    std::fs::create_dir_all(&sessions_dir).expect("create sessions dir");

    let fixture_path = tmp.path().join("fixture.json");
    std::fs::write(&fixture_path, serde_json::to_string(&ls_json).unwrap()).unwrap();

    let skeleton = "new_tab\nlaunch /bin/bash -l\n";
    let skeleton_path = tmp.path().join("skeleton.txt");
    std::fs::write(&skeleton_path, skeleton).unwrap();

    let result = save(SaveOpts {
        name: "test_nvim".to_string(),
        all: true,
        scrollback: false,
        sessions_dir: sessions_dir.clone(),
        from_ls: Some(fixture_path),
        from_skeleton: Some(skeleton_path),
        pre_pool: None,
    })
    .await;

    // Should succeed (may degrade to BareShell if nvim not available)
    assert!(
        result.is_ok(),
        "save with nvim should succeed: {:?}",
        result.err()
    );
}

/// Test that save with from_ls fixture works with tmux process.
#[tokio::test]
async fn save_with_from_ls_tmux_process() {
    let ls_json = serde_json::json!([
        {
            "id": 1,
            "tabs": [
                {
                    "id": 1,
                    "windows": [
                        {"id": 1, "pid": 100, "cwd": "/home/user", "foreground_processes": [{"pid": 100, "cmdline": ["/usr/bin/tmux"]}]}
                    ]
                }
            ]
        }
    ]);

    let tmp = tempdir().unwrap();
    let sessions_dir = tmp.path().to_path_buf();
    std::fs::create_dir_all(&sessions_dir).expect("create sessions dir");

    let fixture_path = tmp.path().join("fixture.json");
    std::fs::write(&fixture_path, serde_json::to_string(&ls_json).unwrap()).unwrap();

    let skeleton = "new_tab\nlaunch /bin/bash -l\n";
    let skeleton_path = tmp.path().join("skeleton.txt");
    std::fs::write(&skeleton_path, skeleton).unwrap();

    let result = save(SaveOpts {
        name: "test_tmux".to_string(),
        all: true,
        scrollback: false,
        sessions_dir: sessions_dir.clone(),
        from_ls: Some(fixture_path),
        from_skeleton: Some(skeleton_path),
        pre_pool: None,
    })
    .await;

    // Should succeed (may degrade if no tmux server running)
    assert!(
        result.is_ok(),
        "save with tmux should succeed: {:?}",
        result.err()
    );
}

/// Test that save with from_ls produces degraded result when no valid windows.
#[tokio::test]
async fn save_with_from_ls_self_only() {
    // This fixture only contains is_self windows which should be filtered out
    let ls_json = serde_json::json!([
        {
            "id": 1,
            "tabs": [
                {
                    "id": 1,
                    "windows": [
                        {"id": 1, "pid": 100, "cwd": "/home/user", "is_self": true, "foreground_processes": [{"pid": 100, "cmdline": ["/bin/ksession"]}]}
                    ]
                }
            ]
        }
    ]);

    let tmp = tempdir().unwrap();
    let sessions_dir = tmp.path().to_path_buf();
    std::fs::create_dir_all(&sessions_dir).expect("create sessions dir");

    let fixture_path = tmp.path().join("fixture.json");
    std::fs::write(&fixture_path, serde_json::to_string(&ls_json).unwrap()).unwrap();

    let skeleton = "new_tab\nlaunch /bin/bash -l\n";
    let skeleton_path = tmp.path().join("skeleton.txt");
    std::fs::write(&skeleton_path, skeleton).unwrap();

    let result = save(SaveOpts {
        name: "test_self_only".to_string(),
        all: true,
        scrollback: false,
        sessions_dir: sessions_dir.clone(),
        from_ls: Some(fixture_path),
        from_skeleton: Some(skeleton_path),
        pre_pool: None,
    })
    .await;

    // Should succeed - will create synthetic window for filtered tab
    assert!(
        result.is_ok(),
        "save with self-only windows should succeed: {:?}",
        result.err()
    );

    // Verify manifest was created with synthetic window
    let entries = std::fs::read_dir(&sessions_dir).unwrap();
    let gen_dirs: Vec<_> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("test_self_only.gen-"))
                .unwrap_or(false)
        })
        .collect();

    assert!(
        !gen_dirs.is_empty(),
        "should have created gen-stamped directory"
    );
}
