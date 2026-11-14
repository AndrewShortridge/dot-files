//! Fixture Builder - Core Infrastructure
//!
//! This module provides infrastructure for building real-world test fixtures
//! by spawning a live Kitty instance and capturing its state.
//!
//! The fixture builder:
//! 1. Spawns a real Kitty process via the `KittySpawner` helper
//! 2. Runs the actual save path against the live state
//! 3. Persists output to `tests/fixtures/real_workflow/<name>/`
//! 4. Generates `metadata.json` with scenario description
//!
//! Run with: `cargo test --test fixture_builder -- --ignored`
//! (The --ignored flag is needed because these tests require a real kitty binary)

mod helpers;

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::time::Instant;

use serde::{Deserialize, Serialize};

use helpers::{kitten_is_usable, kitty_is_usable, tmux_is_usable, KittySpawner};

/// Describes what program to launch in a kitty tab/window.
///
/// Used by `FixtureBuilder` to specify real program launches between
/// window creation and the save pipeline capture.
#[derive(Debug, Clone)]
pub enum WindowProgram {
    /// Plain shell (default behavior, no extra launch).
    Shell,

    /// Launch nvim with no files (clean, empty buffer).
    NvimClean,

    /// Launch nvim with files open (clean, saved state).
    NvimFiles(Vec<String>),

    /// Launch nvim with files and dirty (modified, unsaved) buffers.
    NvimDirty(Vec<String>),

    /// Launch nvim with files opened in separate nvim tab pages.
    NvimMultiTab(Vec<String>),

    /// Launch nvim with files opened in split windows.
    NvimSplits(Vec<String>),

    /// Attach a tmux session (single session, single window).
    /// The session is created if it does not already exist.
    TmuxSingle { session_name: String },

    /// Attach a tmux session with multiple windows.
    TmuxMultiWindow {
        session_name: String,
        window_names: Vec<String>,
    },

    /// Attach one of multiple independent tmux sessions.
    /// Each entry is (session_name, window_names).
    TmuxMultiSession {
        sessions: Vec<(String, Vec<String>)>,
    },

    /// Attach a tmux session with split panes.
    TmuxPanes {
        session_name: String,
        /// Number of vertical splits to create in window 0.
        vertical_splits: u32,
        /// Number of horizontal splits to create in window 0.
        horizontal_splits: u32,
    },
}

/// Per-tab program specification.
///
/// Specifies what program should be launched in a particular tab.
/// The tab index is 0-based (tab 0 is the first tab).
#[derive(Debug, Clone)]
pub struct TabProgram {
    /// Which tab to target (0-based index into the created tabs).
    pub tab_index: u32,
    /// The program to launch.
    pub program: WindowProgram,
}

/// Metadata describing a fixture scenario.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FixtureMetadata {
    /// Unique name of the scenario.
    pub name: String,
    /// Human-readable description.
    pub description: String,
    /// When the fixture was generated.
    pub generated_at: String,
    /// Kitty version used.
    pub kitty_version: String,
    /// Number of tabs in the fixture.
    pub tab_count: u32,
    /// Number of windows in the fixture.
    pub window_count: u32,
    /// Complexity level (light, typical, heavy)
    #[serde(default)]
    pub complexity: String,
    /// Additional tags for categorization.
    #[serde(default)]
    pub tags: Vec<String>,
    /// Build parameters used.
    #[serde(default)]
    pub build_params: HashMap<String, String>,
    /// Scenario parameters defining expected ranges
    #[serde(default)]
    pub scenario: Option<FixtureScenario>,
}

/// Scenario parameters defining expected ranges for a fixture.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FixtureScenario {
    pub min_tabs: u32,
    pub max_tabs: u32,
    pub min_windows: u32,
    pub max_windows: u32,
    pub min_buffers: u32,
    pub max_buffers: u32,
    pub min_nvim: u32,
    pub max_nvim: u32,
    pub min_tmux: u32,
    pub max_tmux: u32,
}

/// Builder configuration for creating fixtures.
#[derive(Debug, Clone)]
pub struct FixtureBuilder {
    /// Name of the fixture.
    pub name: String,
    /// Description of the scenario.
    pub description: String,
    /// Session file to load (optional).
    pub session_file: Option<PathBuf>,
    /// Number of tabs to create.
    pub num_tabs: u32,
    /// Number of windows per tab.
    pub num_windows: u32,
    /// Additional tags for the fixture.
    pub tags: Vec<String>,
    /// Scenario override: tab range (min, max).
    pub scenario_tabs: Option<(u32, u32)>,
    /// Scenario override: window range (min, max).
    pub scenario_windows: Option<(u32, u32)>,
    /// Scenario override: buffer range (min, max).
    pub scenario_buffers: Option<(u32, u32)>,
    /// Scenario override: nvim instance range (min, max).
    pub scenario_nvim: Option<(u32, u32)>,
    /// Scenario override: tmux session range (min, max).
    pub scenario_tmux: Option<(u32, u32)>,
    /// Programs to launch in specific tabs.
    ///
    /// Each entry maps a tab index to a program specification. Tabs not
    /// mentioned here get plain shell windows (the default behavior).
    pub programs: Vec<TabProgram>,
    /// Whether to run the full ksession save path after capturing ls state.
    /// When true (default), the save pipeline runs against the live kitty
    /// instance, populating the fixture's `state/` directory with adapter
    /// outputs (nvim session files, tmux restore.sh, scrollback, manifest).
    pub run_save_path: bool,
    /// If true, regenerate even if cached fixture exists.
    pub force_rebuild: bool,
}

impl Default for FixtureBuilder {
    fn default() -> Self {
        Self {
            name: "default".to_string(),
            description: "Default fixture".to_string(),
            session_file: None,
            num_tabs: 2,
            num_windows: 2,
            tags: vec![],
            scenario_tabs: None,
            scenario_windows: None,
            scenario_buffers: None,
            scenario_nvim: None,
            scenario_tmux: None,
            programs: Vec::new(),
            run_save_path: true,
            force_rebuild: false,
        }
    }
}

impl FixtureBuilder {
    /// Create a new fixture builder.
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            ..Default::default()
        }
    }

    /// Set the description.
    pub fn description(mut self, desc: impl Into<String>) -> Self {
        self.description = desc.into();
        self
    }

    /// Set the session file to load.
    pub fn session_file(mut self, path: PathBuf) -> Self {
        self.session_file = Some(path);
        self
    }

    /// Set number of tabs to create.
    pub fn num_tabs(mut self, count: u32) -> Self {
        self.num_tabs = count;
        self
    }

    /// Set number of windows per tab.
    pub fn num_windows(mut self, count: u32) -> Self {
        self.num_windows = count;
        self
    }

    /// Add a tag.
    pub fn add_tag(mut self, tag: impl Into<String>) -> Self {
        self.tags.push(tag.into());
        self
    }

    /// Set scenario tab range (min, max).
    pub fn scenario_tabs(mut self, min: u32, max: u32) -> Self {
        self.scenario_tabs = Some((min, max));
        self
    }

    /// Set scenario window range (min, max).
    pub fn scenario_windows(mut self, min: u32, max: u32) -> Self {
        self.scenario_windows = Some((min, max));
        self
    }

    /// Set scenario buffer range (min, max).
    pub fn scenario_buffers(mut self, min: u32, max: u32) -> Self {
        self.scenario_buffers = Some((min, max));
        self
    }

    /// Set scenario nvim instance range (min, max).
    pub fn scenario_nvim(mut self, min: u32, max: u32) -> Self {
        self.scenario_nvim = Some((min, max));
        self
    }

    /// Set scenario tmux session range (min, max).
    pub fn scenario_tmux(mut self, min: u32, max: u32) -> Self {
        self.scenario_tmux = Some((min, max));
        self
    }

    /// Disable running the full ksession save path.
    ///
    /// When disabled, the fixture will only contain the raw `kitten @ ls`
    /// output (ls.json, session.conf) without running the adapter pipeline.
    /// Useful for simpler fixture generation that only needs kitty state
    /// snapshots without nvim/tmux/scrollback capture.
    pub fn skip_save_path(mut self) -> Self {
        self.run_save_path = false;
        self
    }

    /// Force regeneration even if a cached fixture exists.
    pub fn force_rebuild(mut self) -> Self {
        self.force_rebuild = true;
        self
    }

    /// Add a program to launch in a specific tab.
    ///
    /// # Arguments
    /// * `tab_index` - 0-based tab index
    /// * `program` - The program to launch in that tab
    pub fn program(mut self, tab_index: u32, program: WindowProgram) -> Self {
        self.programs.push(TabProgram { tab_index, program });
        self
    }

    /// Convenience: launch clean nvim (empty buffer) in the given tab.
    pub fn nvim_clean(self, tab_index: u32) -> Self {
        self.program(tab_index, WindowProgram::NvimClean)
    }

    /// Convenience: launch nvim with files in the given tab.
    pub fn nvim_files(self, tab_index: u32, files: Vec<String>) -> Self {
        self.program(tab_index, WindowProgram::NvimFiles(files))
    }

    /// Convenience: launch nvim with dirty buffers in the given tab.
    pub fn nvim_dirty(self, tab_index: u32, files: Vec<String>) -> Self {
        self.program(tab_index, WindowProgram::NvimDirty(files))
    }

    /// Convenience: launch nvim with multiple tab pages in the given tab.
    pub fn nvim_multi_tab(self, tab_index: u32, files: Vec<String>) -> Self {
        self.program(tab_index, WindowProgram::NvimMultiTab(files))
    }

    /// Convenience: launch nvim with split windows in the given tab.
    pub fn nvim_splits(self, tab_index: u32, files: Vec<String>) -> Self {
        self.program(tab_index, WindowProgram::NvimSplits(files))
    }

    /// Convenience: attach a single tmux session in the given tab.
    pub fn tmux_single(self, tab_index: u32, session_name: impl Into<String>) -> Self {
        self.program(
            tab_index,
            WindowProgram::TmuxSingle {
                session_name: session_name.into(),
            },
        )
    }

    /// Convenience: attach a tmux session with multiple windows in the given tab.
    pub fn tmux_multi_window(
        self,
        tab_index: u32,
        session_name: impl Into<String>,
        window_names: Vec<String>,
    ) -> Self {
        self.program(
            tab_index,
            WindowProgram::TmuxMultiWindow {
                session_name: session_name.into(),
                window_names,
            },
        )
    }

    /// Convenience: attach multiple tmux sessions (one per tab starting at `tab_index`).
    pub fn tmux_multi_session(self, tab_index: u32, sessions: Vec<(String, Vec<String>)>) -> Self {
        self.program(tab_index, WindowProgram::TmuxMultiSession { sessions })
    }

    /// Convenience: attach a tmux session with split panes in the given tab.
    pub fn tmux_panes(
        self,
        tab_index: u32,
        session_name: impl Into<String>,
        vertical_splits: u32,
        horizontal_splits: u32,
    ) -> Self {
        self.program(
            tab_index,
            WindowProgram::TmuxPanes {
                session_name: session_name.into(),
                vertical_splits,
                horizontal_splits,
            },
        )
    }

    /// Build the fixture - spawn kitty, capture state, and save to disk.
    pub fn build(&self) -> Result<PathBuf, String> {
        // Check cache: reuse existing fixture if present and not forcing rebuild.
        // The cache is considered valid only when ALL expected outputs exist:
        //   - metadata.json (fixture description)
        //   - conf/ls.json  (captured kitty state)
        //   - state/manifest.json (save pipeline output)
        // If state/manifest.json is missing, the save pipeline hasn't run
        // against this fixture yet and we need to regenerate.
        let fixture_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join("real_workflow")
            .join(&self.name);
        if !self.force_rebuild
            && fixture_dir.join("metadata.json").exists()
            && fixture_dir.join("conf/ls.json").exists()
            && fixture_dir.join("state/manifest.json").exists()
        {
            println!("Using cached fixture: {}", self.name);
            return Ok(fixture_dir);
        }

        // Check availability
        if !kitty_is_usable() {
            return Err("kitty not usable".to_string());
        }
        if !kitten_is_usable() {
            return Err("kitten not usable".to_string());
        }

        // Create output directory
        let fixtures_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join("real_workflow")
            .join(&self.name);

        std::fs::create_dir_all(&fixtures_dir)
            .map_err(|e| format!("failed to create fixtures dir: {}", e))?;

        let conf_dir = fixtures_dir.join("conf");
        let state_dir = fixtures_dir.join("state");
        std::fs::create_dir_all(&conf_dir)
            .map_err(|e| format!("failed to create conf dir: {}", e))?;
        std::fs::create_dir_all(&state_dir)
            .map_err(|e| format!("failed to create state dir: {}", e))?;

        println!(
            "Building fixture '{}' in {}",
            self.name,
            fixtures_dir.display()
        );

        // Spawn kitty
        let spawner = KittySpawner::spawn_default(self.session_file.as_deref())
            .map_err(|e| format!("failed to spawn kitty: {:?}", e))?;

        let socket_spec = spawner.socket_spec();
        let start = Instant::now();

        // Create requested tabs and windows using the spawner.
        // Kitty starts with 1 tab and 1 window, so create (num_tabs - 1) additional tabs.
        for i in 1..self.num_tabs {
            spawner
                .create_tab(Some(&format!("tab-{}", i)))
                .map_err(|e| format!("failed to create tab {}: {:?}", i, e))?;
        }

        // After creating tabs, give kitty a moment to settle, then discover
        // actual tab IDs from ls output so we can target windows correctly.
        std::thread::sleep(std::time::Duration::from_millis(200));

        let tab_ids = Self::discover_tab_ids(&socket_spec)?;
        println!("Discovered {} tab IDs: {:?}", tab_ids.len(), tab_ids);

        // Create additional windows in each tab.
        // Each tab already has 1 window from creation, so create (num_windows - 1) more.
        for &tab_id in &tab_ids {
            for _ in 1..self.num_windows {
                spawner
                    .create_window(tab_id, "tall")
                    .map_err(|e| format!("failed to create window in tab {}: {:?}", tab_id, e))?;
            }
        }

        // Give kitty a moment to stabilize after all tabs/windows are created
        std::thread::sleep(std::time::Duration::from_millis(200));

        // ---- Launch real programs (nvim, tmux) in specified tabs ----
        // This must happen BETWEEN window creation and state capture so that
        // the save pipeline detects real processes via the adapter registry.
        if !self.programs.is_empty() {
            self.launch_programs(&spawner, &tab_ids)?;
        }

        // Capture state via RC socket
        let build_duration = start.elapsed();

        // Get kitty version
        let kitty_version = Self::get_kitty_version();

        // Capture ls_session output (the conf)
        let ls_output = Self::capture_ls_session(&socket_spec);
        let conf_path = conf_dir.join("session.conf");
        if let Some(ref output) = ls_output {
            std::fs::write(&conf_path, output)
                .map_err(|e| format!("failed to write conf: {}", e))?;
            println!("Wrote conf to {}", conf_path.display());
        }

        // Capture ls output (JSON format for ls)
        let ls_json = Self::capture_ls_json(&socket_spec);
        let ls_json_path = conf_dir.join("ls.json");
        if let Some(ref output) = ls_json {
            std::fs::write(&ls_json_path, output)
                .map_err(|e| format!("failed to write ls.json: {}", e))?;
            println!("Wrote ls.json to {}", ls_json_path.display());
        }

        // ---- Full save path execution ----
        // Run the ksession save pipeline against the live kitty instance.
        // This populates the fixture's state/ directory with adapter outputs
        // (nvim session files, tmux restore.sh, scrollback, manifest.json).
        if self.run_save_path {
            if ls_output.is_none() || ls_json.is_none() {
                eprintln!(
                    "  Skipping save pipeline: ls capture failed (ls_output={}, ls_json={})",
                    ls_output.is_some(),
                    ls_json.is_some()
                );
            } else {
                self.run_save_pipeline(&socket_spec, &conf_path, &ls_json_path, &state_dir)?;
            }
        }

        // Count actual tabs and windows from ls.json
        let (actual_tab_count, actual_window_count) = ls_json
            .as_deref()
            .map(Self::count_tabs_windows_from_ls)
            .unwrap_or((
                self.num_tabs as usize,
                (self.num_tabs * self.num_windows) as usize,
            ));

        println!(
            "Actual counts from ls.json: {} tabs, {} windows (requested: {} tabs, {} windows/tab)",
            actual_tab_count, actual_window_count, self.num_tabs, self.num_windows
        );

        // Determine complexity from actual counts
        let total_windows = actual_window_count;
        let complexity = if actual_tab_count <= 2 && total_windows <= 4 {
            "light".to_string()
        } else if actual_tab_count <= 4 && total_windows <= 10 {
            "typical".to_string()
        } else if actual_tab_count <= 6 && total_windows <= 20 {
            "heavy".to_string()
        } else {
            "very_heavy".to_string()
        };

        // Build scenario from overrides or auto-detect from actual counts
        let (min_tabs, max_tabs) = self
            .scenario_tabs
            .unwrap_or((actual_tab_count as u32, actual_tab_count as u32));
        let (min_windows, max_windows) = self
            .scenario_windows
            .unwrap_or((actual_window_count as u32, actual_window_count as u32));
        let (min_buffers, max_buffers) = self
            .scenario_buffers
            .unwrap_or((actual_window_count as u32, actual_window_count as u32));
        let (min_nvim, max_nvim) = self.scenario_nvim.unwrap_or((0, 0));
        let (min_tmux, max_tmux) = self.scenario_tmux.unwrap_or((0, 0));

        let scenario = FixtureScenario {
            min_tabs,
            max_tabs,
            min_windows,
            max_windows,
            min_buffers,
            max_buffers,
            min_nvim,
            max_nvim,
            min_tmux,
            max_tmux,
        };

        let metadata = FixtureMetadata {
            name: self.name.clone(),
            description: self.description.clone(),
            generated_at: chrono::Utc::now().to_rfc3339(),
            kitty_version,
            tab_count: actual_tab_count as u32,
            window_count: actual_window_count as u32,
            complexity,
            tags: self.tags.clone(),
            build_params: {
                let mut params = HashMap::new();
                params.insert("num_tabs".to_string(), self.num_tabs.to_string());
                params.insert("num_windows".to_string(), self.num_windows.to_string());
                params.insert(
                    "build_duration_ms".to_string(),
                    build_duration.as_millis().to_string(),
                );
                params
            },
            scenario: Some(scenario),
        };

        let metadata_path = fixtures_dir.join("metadata.json");
        let metadata_json = serde_json::to_string_pretty(&metadata)
            .map_err(|e| format!("failed to serialize metadata: {}", e))?;
        std::fs::write(&metadata_path, &metadata_json)
            .map_err(|e| format!("failed to write metadata: {}", e))?;
        println!("Wrote metadata to {}", metadata_path.display());

        println!(
            "Fixture '{}' built successfully in {:?}",
            self.name, build_duration
        );

        // The spawner will be dropped here, which will clean up the kitty process
        Ok(fixtures_dir)
    }

    /// Launch real programs (nvim, tmux) in the specified tabs.
    ///
    /// Iterates over `self.programs` and calls the appropriate KittySpawner
    /// methods to launch each program. A settling sleep is added after all
    /// launches so programs are fully initialized before state capture.
    fn launch_programs(&self, spawner: &KittySpawner, tab_ids: &[u32]) -> Result<(), String> {
        // Create a temporary directory for test files that nvim can open.
        let tmp_dir = tempfile::tempdir()
            .map_err(|e| format!("failed to create temp dir for test files: {}", e))?;

        for tab_prog in &self.programs {
            let tab_idx = tab_prog.tab_index as usize;
            if tab_idx >= tab_ids.len() {
                return Err(format!(
                    "program references tab_index {} but only {} tabs exist",
                    tab_prog.tab_index,
                    tab_ids.len()
                ));
            }
            let tab_id = tab_ids[tab_idx];

            match &tab_prog.program {
                WindowProgram::Shell => {
                    // Nothing to do - shell is the default
                }

                WindowProgram::NvimClean => {
                    println!("  Launching nvim (clean) in tab {}", tab_id);
                    spawner
                        .launch_nvim(tab_id, &[])
                        .map_err(|e| format!("launch_nvim clean failed: {:?}", e))?;
                }

                WindowProgram::NvimFiles(files) => {
                    // Create temp files so nvim has real paths to open
                    let paths = Self::create_temp_files(tmp_dir.path(), files)?;
                    let path_strs: Vec<&str> = paths.iter().map(|p| p.as_str()).collect();
                    println!("  Launching nvim (files: {:?}) in tab {}", files, tab_id);
                    spawner
                        .launch_nvim(tab_id, &path_strs)
                        .map_err(|e| format!("launch_nvim files failed: {:?}", e))?;
                }

                WindowProgram::NvimDirty(files) => {
                    let paths = Self::create_temp_files(tmp_dir.path(), files)?;
                    let path_strs: Vec<&str> = paths.iter().map(|p| p.as_str()).collect();
                    println!("  Launching nvim (dirty: {:?}) in tab {}", files, tab_id);
                    spawner
                        .launch_nvim_dirty(tab_id, &path_strs)
                        .map_err(|e| format!("launch_nvim_dirty failed: {:?}", e))?;
                }

                WindowProgram::NvimMultiTab(files) => {
                    let paths = Self::create_temp_files(tmp_dir.path(), files)?;
                    let path_strs: Vec<&str> = paths.iter().map(|p| p.as_str()).collect();
                    println!(
                        "  Launching nvim (multi-tab: {:?}) in tab {}",
                        files, tab_id
                    );
                    spawner
                        .launch_nvim_multi_tab(tab_id, &path_strs)
                        .map_err(|e| format!("launch_nvim_multi_tab failed: {:?}", e))?;
                }

                WindowProgram::NvimSplits(files) => {
                    let paths = Self::create_temp_files(tmp_dir.path(), files)?;
                    let path_strs: Vec<&str> = paths.iter().map(|p| p.as_str()).collect();
                    println!("  Launching nvim (splits: {:?}) in tab {}", files, tab_id);
                    spawner
                        .launch_nvim_splits(tab_id, &path_strs)
                        .map_err(|e| format!("launch_nvim_splits failed: {:?}", e))?;
                }

                WindowProgram::TmuxSingle { session_name } => {
                    if !tmux_is_usable() {
                        return Err("tmux not usable".to_string());
                    }
                    println!(
                        "  Creating tmux session '{}' and attaching in tab {}",
                        session_name, tab_id
                    );
                    // We need a mutable reference to spawner for tmux session tracking.
                    // Since KittySpawner::create_tmux_session takes &mut self, we use
                    // a direct Command invocation here and track cleanup separately.
                    Self::create_tmux_session_direct(session_name)?;
                    spawner
                        .attach_tmux_in_kitty_window(tab_id, session_name)
                        .map_err(|e| format!("attach_tmux failed: {:?}", e))?;
                }

                WindowProgram::TmuxMultiWindow {
                    session_name,
                    window_names,
                } => {
                    if !tmux_is_usable() {
                        return Err("tmux not usable".to_string());
                    }
                    println!(
                        "  Creating tmux session '{}' with {} windows, attaching in tab {}",
                        session_name,
                        window_names.len() + 1,
                        tab_id
                    );
                    Self::create_tmux_session_direct(session_name)?;
                    for wname in window_names {
                        Self::create_tmux_window_direct(session_name, wname)?;
                    }
                    spawner
                        .attach_tmux_in_kitty_window(tab_id, session_name)
                        .map_err(|e| format!("attach_tmux failed: {:?}", e))?;
                }

                WindowProgram::TmuxMultiSession { sessions } => {
                    if !tmux_is_usable() {
                        return Err("tmux not usable".to_string());
                    }
                    // For multi-session, we attach the first session in the
                    // specified tab. Additional sessions are created but attached
                    // in subsequent tabs (if available).
                    for (i, (sname, wnames)) in sessions.iter().enumerate() {
                        println!(
                            "  Creating tmux session '{}' with {} windows",
                            sname,
                            wnames.len() + 1
                        );
                        Self::create_tmux_session_direct(sname)?;
                        for wname in wnames {
                            Self::create_tmux_window_direct(sname, wname)?;
                        }
                        // Attach in the appropriate tab
                        let target_tab_idx = tab_idx + i;
                        if target_tab_idx < tab_ids.len() {
                            let target_tab_id = tab_ids[target_tab_idx];
                            spawner
                                .attach_tmux_in_kitty_window(target_tab_id, sname)
                                .map_err(|e| {
                                    format!("attach_tmux session '{}' failed: {:?}", sname, e)
                                })?;
                        }
                    }
                }

                WindowProgram::TmuxPanes {
                    session_name,
                    vertical_splits,
                    horizontal_splits,
                } => {
                    if !tmux_is_usable() {
                        return Err("tmux not usable".to_string());
                    }
                    println!(
                        "  Creating tmux session '{}' with {} vertical + {} horizontal splits, attaching in tab {}",
                        session_name, vertical_splits, horizontal_splits, tab_id
                    );
                    Self::create_tmux_session_direct(session_name)?;
                    // Create vertical splits first, then horizontal
                    for _ in 0..*vertical_splits {
                        Self::create_tmux_pane_direct(session_name, 0, true)?;
                    }
                    for _ in 0..*horizontal_splits {
                        Self::create_tmux_pane_direct(session_name, 0, false)?;
                    }
                    spawner
                        .attach_tmux_in_kitty_window(tab_id, session_name)
                        .map_err(|e| format!("attach_tmux failed: {:?}", e))?;
                }
            }
        }

        // Settle time for launched programs to fully initialize.
        // nvim needs time to parse files; tmux needs time to render.
        let settle_ms = if self.programs.iter().any(|p| {
            matches!(
                p.program,
                WindowProgram::NvimDirty(_)
                    | WindowProgram::NvimMultiTab(_)
                    | WindowProgram::NvimSplits(_)
            )
        }) {
            1500 // Complex nvim operations need more time
        } else if self.programs.iter().any(|p| {
            matches!(
                p.program,
                WindowProgram::NvimClean | WindowProgram::NvimFiles(_)
            )
        }) {
            1000 // Simple nvim launch
        } else {
            500 // tmux-only
        };

        println!("  Waiting {}ms for programs to initialize...", settle_ms);
        std::thread::sleep(std::time::Duration::from_millis(settle_ms));

        Ok(())
    }

    /// Create temporary test files with some content for nvim to open.
    ///
    /// Each file gets a small amount of placeholder content so nvim has
    /// real buffers to work with.
    fn create_temp_files(
        dir: &std::path::Path,
        filenames: &[String],
    ) -> Result<Vec<String>, String> {
        let mut paths = Vec::new();
        for name in filenames {
            let file_path = dir.join(name);
            // Create parent directories if the filename contains path separators
            if let Some(parent) = file_path.parent() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| format!("failed to create parent dir for {}: {}", name, e))?;
            }
            let content = format!(
                "// Test file: {}\n// Generated by fixture_builder\nfn main() {{}}\n",
                name
            );
            std::fs::write(&file_path, &content)
                .map_err(|e| format!("failed to write test file {}: {}", name, e))?;
            paths.push(file_path.to_string_lossy().to_string());
        }
        Ok(paths)
    }

    /// Create a detached tmux session directly via Command.
    ///
    /// This is used instead of `KittySpawner::create_tmux_session` because
    /// we only have a shared reference to the spawner in `launch_programs`.
    fn create_tmux_session_direct(session_name: &str) -> Result<(), String> {
        let output = Command::new("tmux")
            .args(["new-session", "-d", "-s", session_name])
            .output()
            .map_err(|e| format!("failed to spawn tmux: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "tmux new-session -d -s {} failed: {}",
                session_name, stderr
            ));
        }
        Ok(())
    }

    /// Create a window in an existing tmux session directly via Command.
    fn create_tmux_window_direct(session_name: &str, window_name: &str) -> Result<(), String> {
        let output = Command::new("tmux")
            .args(["new-window", "-t", session_name, "-n", window_name])
            .output()
            .map_err(|e| format!("failed to spawn tmux: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "tmux new-window -t {} -n {} failed: {}",
                session_name, window_name, stderr
            ));
        }
        Ok(())
    }

    /// Create a split pane in a tmux session directly via Command.
    fn create_tmux_pane_direct(
        session_name: &str,
        window_index: u32,
        vertical: bool,
    ) -> Result<(), String> {
        let target = format!("{}:{}", session_name, window_index);
        let split_flag = if vertical { "-v" } else { "-h" };

        let output = Command::new("tmux")
            .args(["split-window", split_flag, "-t", &target])
            .output()
            .map_err(|e| format!("failed to spawn tmux: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "tmux split-window {} -t {} failed: {}",
                split_flag, target, stderr
            ));
        }
        Ok(())
    }

    /// Get the kitty version string.
    fn get_kitty_version() -> String {
        Command::new("kitty")
            .arg("--version")
            .output()
            .ok()
            .and_then(|o| {
                if o.status.success() {
                    Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "unknown".to_string())
    }

    /// Capture ls_session output via RC socket.
    fn capture_ls_session(socket_spec: &str) -> Option<String> {
        let output = Command::new("kitten")
            .args(["@", "--to", socket_spec, "ls", "--output-format=session"])
            .output()
            .ok()?;

        if output.status.success() {
            Some(String::from_utf8_lossy(&output.stdout).to_string())
        } else {
            None
        }
    }

    /// Capture ls JSON output via RC socket.
    fn capture_ls_json(socket_spec: &str) -> Option<String> {
        let output = Command::new("kitten")
            .args(["@", "--to", socket_spec, "ls", "--all-env-vars"])
            .output()
            .ok()?;

        if output.status.success() {
            Some(String::from_utf8_lossy(&output.stdout).to_string())
        } else {
            None
        }
    }

    /// Count the actual number of tabs and windows from kitty ls JSON output.
    ///
    /// The ls JSON format is an array of OS windows, each containing a `tabs`
    /// array, and each tab contains a `windows` array.
    fn count_tabs_windows_from_ls(ls_json: &str) -> (usize, usize) {
        let parsed: Result<serde_json::Value, _> = serde_json::from_str(ls_json);
        match parsed {
            Ok(serde_json::Value::Array(os_windows)) => {
                let mut total_tabs = 0usize;
                let mut total_windows = 0usize;
                for os_win in &os_windows {
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
            _ => (0, 0),
        }
    }

    /// Discover actual tab IDs from a live kitty instance via its ls JSON.
    fn discover_tab_ids(socket_spec: &str) -> Result<Vec<u32>, String> {
        let ls_json = Self::capture_ls_json(socket_spec)
            .ok_or_else(|| "failed to capture ls.json for tab discovery".to_string())?;

        let parsed: serde_json::Value = serde_json::from_str(&ls_json)
            .map_err(|e| format!("failed to parse ls.json: {}", e))?;

        let mut tab_ids = Vec::new();
        if let serde_json::Value::Array(os_windows) = &parsed {
            for os_win in os_windows {
                if let Some(tabs) = os_win.get("tabs").and_then(|t| t.as_array()) {
                    for tab in tabs {
                        if let Some(id) = tab.get("id").and_then(|i| i.as_u64()) {
                            tab_ids.push(id as u32);
                        }
                    }
                }
            }
        }

        if tab_ids.is_empty() {
            return Err("no tab IDs found in ls.json".to_string());
        }

        Ok(tab_ids)
    }

    /// Run the full ksession save pipeline against a live kitty instance.
    ///
    /// Uses the captured ls.json and session.conf as `--from-ls` and
    /// `--from-skeleton` inputs. The save pipeline runs all adapters
    /// (nvim, tmux, shell, less, raw) and populates the `state_dir`
    /// with their outputs plus a manifest.json.
    ///
    /// Errors are logged but do not fail the fixture build -- some
    /// fixtures may not have nvim/tmux running, resulting in minimal
    /// state output which is still valid.
    fn run_save_pipeline(
        &self,
        socket_spec: &str,
        conf_path: &std::path::Path,
        ls_json_path: &std::path::Path,
        state_dir: &std::path::Path,
    ) -> Result<(), String> {
        println!("Running save pipeline for fixture '{}'...", self.name);

        // Use a temporary directory as sessions_dir for the save call.
        // The save function creates a gen-stamped state dir inside it.
        let save_tmp = tempfile::tempdir()
            .map_err(|e| format!("failed to create temp dir for save: {}", e))?;
        let save_sessions_dir = save_tmp.path().to_path_buf();

        // Run the save pipeline via the library API. We need a tokio
        // runtime since save() is async.
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("failed to build tokio runtime: {}", e))?;

        let save_result = rt.block_on(async {
            // Set KITTY_LISTEN_ON so transport discovery finds our socket.
            // Save the previous value so we can restore it.
            let prev_listen = std::env::var_os("KITTY_LISTEN_ON");
            std::env::set_var("KITTY_LISTEN_ON", socket_spec);

            let opts = ksession_rs::session::SaveOpts {
                name: self.name.clone(),
                all: true,
                scrollback: true,
                sessions_dir: save_sessions_dir.clone(),
                from_ls: Some(ls_json_path.to_path_buf()),
                from_skeleton: Some(conf_path.to_path_buf()),
                pre_pool: None,
            };

            let result = ksession_rs::session::save(opts).await;

            // Restore KITTY_LISTEN_ON.
            match prev_listen {
                Some(v) => std::env::set_var("KITTY_LISTEN_ON", v),
                None => std::env::remove_var("KITTY_LISTEN_ON"),
            }

            result
        });

        // Extract the session_file from a successful save so we can write
        // manifest.json as a fallback if copy_state_artifacts finds nothing.
        let session_file = match &save_result {
            Ok(outcome) => {
                if outcome.degraded_any {
                    println!(
                        "  Save completed with degradations (some adapters failed gracefully)"
                    );
                } else {
                    println!("  Save completed successfully");
                }
                Some(&outcome.session_file)
            }
            Err(e) => {
                // Non-fatal: log the error but continue — we still attempt to
                // copy whatever artifacts landed in the gen-stamped dir before
                // the failure. Common causes:
                //   - conf::render fails (skeleton mismatch)
                //   - commit_session fsync fails on tmpfs variant
                //   - adapter timeout on slow CI
                eprintln!("  Warning: save pipeline failed for '{}': {}", self.name, e);
                eprintln!("  Will still attempt to copy any partial state artifacts");
                None
            }
        };

        // Always attempt to copy state artifacts from the gen-stamped dir,
        // regardless of whether save succeeded or failed. The save writes
        // manifest.json and adapter outputs into the gen-stamped dir BEFORE
        // the commit_session call that can fail. If commit_session's
        // StateTmpdir Drop guard cleaned up the dir (early fsync failure),
        // copy_state_artifacts simply reports "no dir found" and we fall
        // through to the manifest fallback below.
        Self::copy_state_artifacts(&save_sessions_dir, &self.name, state_dir)?;

        // Fallback: if copy_state_artifacts found nothing (state dir was
        // cleaned up by StateTmpdir Drop) but save DID produce a SessionFile,
        // write manifest.json directly into the fixture's state/ directory.
        // This ensures fixtures always have at least a manifest even when the
        // atomic-publish phase fails.
        if !state_dir.join("manifest.json").exists() {
            if let Some(sf) = session_file {
                let manifest_bytes = serde_json::to_vec_pretty(sf)
                    .map_err(|e| format!("failed to serialize manifest fallback: {}", e))?;
                std::fs::write(state_dir.join("manifest.json"), &manifest_bytes)
                    .map_err(|e| format!("failed to write manifest fallback: {}", e))?;
                println!("  Wrote manifest.json via fallback (gen-stamped dir was unavailable)");
            } else {
                println!("  No state artifacts produced (save failed before generating manifest)");
            }
        }

        Ok(())
    }

    /// Copy state artifacts from the save pipeline's gen-stamped directory
    /// into the fixture's state/ directory.
    ///
    /// The save creates `<sessions_dir>/<name>.gen-<ts>.state/` with subdirs
    /// like `nvim/`, `tmux/`, `scrollback/`, `.cache/`, and a `manifest.json`.
    /// This method finds that directory and recursively copies its contents.
    fn copy_state_artifacts(
        sessions_dir: &std::path::Path,
        name: &str,
        target_state_dir: &std::path::Path,
    ) -> Result<(), String> {
        // Find the gen-stamped state directory. Pattern: <name>.gen-*.state/
        let prefix = format!("{name}.gen-");
        let mut state_source: Option<PathBuf> = None;

        let entries = std::fs::read_dir(sessions_dir)
            .map_err(|e| format!("failed to read sessions dir: {}", e))?;

        for entry in entries.flatten() {
            let fname = entry.file_name();
            let fname_str = fname.to_string_lossy();
            if fname_str.starts_with(&prefix) && fname_str.ends_with(".state") {
                let candidate = entry.path();
                // Pick the lexicographically greatest (newest) if multiple exist.
                match &state_source {
                    None => state_source = Some(candidate),
                    Some(cur) => {
                        if candidate > *cur {
                            state_source = Some(candidate);
                        }
                    }
                }
            }
        }

        let Some(source) = state_source else {
            println!("  No gen-stamped state directory found; state/ will be empty");
            return Ok(());
        };

        println!(
            "  Copying state from {} to {}",
            source.display(),
            target_state_dir.display()
        );

        copy_dir_recursive(&source, target_state_dir)?;

        // Also copy the rendered conf if it exists (the save produces
        // <name>.conf alongside the state dir).
        let rendered_conf = sessions_dir.join(format!("{name}.conf"));
        if rendered_conf.exists() {
            let target = target_state_dir
                .parent()
                .unwrap_or(target_state_dir)
                .join("conf")
                .join("rendered.conf");
            if let Err(e) = std::fs::copy(&rendered_conf, &target) {
                println!("  Note: could not copy rendered conf: {}", e);
            } else {
                println!("  Wrote rendered conf to {}", target.display());
            }
        }

        Ok(())
    }
}

/// Recursively copy a directory tree from `src` to `dst`.
///
/// Creates `dst` and any missing parent directories. Existing files in
/// `dst` are overwritten. Symlinks are followed (copied as regular files).
fn copy_dir_recursive(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    std::fs::create_dir_all(dst).map_err(|e| format!("create_dir_all {}: {}", dst.display(), e))?;

    let entries =
        std::fs::read_dir(src).map_err(|e| format!("read_dir {}: {}", src.display(), e))?;

    for entry in entries {
        let entry = entry.map_err(|e| format!("read entry in {}: {}", src.display(), e))?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());

        if src_path.is_dir() {
            copy_dir_recursive(&src_path, &dst_path)?;
        } else {
            std::fs::copy(&src_path, &dst_path).map_err(|e| {
                format!(
                    "copy {} -> {}: {}",
                    src_path.display(),
                    dst_path.display(),
                    e
                )
            })?;
        }
    }

    Ok(())
}

/// Simple smoke test to verify the module compiles.
#[test]
fn test_fixture_builder_smoke() {
    // Just verify we can construct the builder with all fields
    let builder = FixtureBuilder::new("test")
        .description("Test fixture")
        .num_tabs(1)
        .num_windows(1)
        .scenario_tabs(1, 2)
        .scenario_windows(2, 4)
        .scenario_buffers(4, 8)
        .scenario_nvim(0, 1)
        .scenario_tmux(0, 0);

    assert_eq!(builder.name, "test");
    assert_eq!(builder.description, "Test fixture");
    assert_eq!(builder.num_tabs, 1);
    assert_eq!(builder.num_windows, 1);
    assert!(
        builder.run_save_path,
        "save path should be enabled by default"
    );
    assert_eq!(builder.scenario_tabs, Some((1, 2)));
    assert_eq!(builder.scenario_windows, Some((2, 4)));
    assert_eq!(builder.scenario_buffers, Some((4, 8)));
    assert_eq!(builder.scenario_nvim, Some((0, 1)));
    assert_eq!(builder.scenario_tmux, Some((0, 0)));
    assert!(
        builder.programs.is_empty(),
        "programs should default to empty"
    );
}

/// Verify program builder methods populate the programs vec.
#[test]
fn test_fixture_builder_program_methods() {
    let builder = FixtureBuilder::new("test_programs")
        .num_tabs(3)
        .num_windows(1)
        .nvim_clean(0)
        .nvim_dirty(1, vec!["a.rs".to_string(), "b.rs".to_string()])
        .tmux_single(2, "my-session");

    assert_eq!(builder.programs.len(), 3);
    assert_eq!(builder.programs[0].tab_index, 0);
    assert_eq!(builder.programs[1].tab_index, 1);
    assert_eq!(builder.programs[2].tab_index, 2);

    // Verify variant types
    assert!(matches!(
        builder.programs[0].program,
        WindowProgram::NvimClean
    ));
    assert!(matches!(
        builder.programs[1].program,
        WindowProgram::NvimDirty(_)
    ));
    assert!(matches!(
        builder.programs[2].program,
        WindowProgram::TmuxSingle { .. }
    ));
}

/// Verify nvim multi-tab and splits builder methods.
#[test]
fn test_fixture_builder_nvim_variants() {
    let builder = FixtureBuilder::new("test_nvim_variants")
        .num_tabs(4)
        .num_windows(1)
        .nvim_files(0, vec!["x.rs".to_string()])
        .nvim_multi_tab(1, vec!["a.rs".to_string(), "b.rs".to_string()])
        .nvim_splits(
            2,
            vec!["c.rs".to_string(), "d.rs".to_string(), "e.rs".to_string()],
        )
        .program(3, WindowProgram::Shell);

    assert_eq!(builder.programs.len(), 4);
    assert!(matches!(
        builder.programs[0].program,
        WindowProgram::NvimFiles(_)
    ));
    assert!(matches!(
        builder.programs[1].program,
        WindowProgram::NvimMultiTab(_)
    ));
    assert!(matches!(
        builder.programs[2].program,
        WindowProgram::NvimSplits(_)
    ));
    assert!(matches!(builder.programs[3].program, WindowProgram::Shell));
}

/// Verify tmux builder methods produce correct variants.
#[test]
fn test_fixture_builder_tmux_variants() {
    let builder = FixtureBuilder::new("test_tmux_variants")
        .num_tabs(3)
        .num_windows(1)
        .tmux_multi_window(0, "sess1", vec!["win-a".to_string(), "win-b".to_string()])
        .tmux_multi_session(
            1,
            vec![
                ("proj-a".to_string(), vec!["code".to_string()]),
                ("proj-b".to_string(), vec!["test".to_string()]),
            ],
        )
        .tmux_panes(2, "pane-sess", 2, 1);

    assert_eq!(builder.programs.len(), 3);
    assert!(matches!(
        builder.programs[0].program,
        WindowProgram::TmuxMultiWindow { .. }
    ));
    assert!(matches!(
        builder.programs[1].program,
        WindowProgram::TmuxMultiSession { .. }
    ));
    assert!(matches!(
        builder.programs[2].program,
        WindowProgram::TmuxPanes { .. }
    ));
}

/// Verify skip_save_path disables the save pipeline.
#[test]
fn test_fixture_builder_skip_save_path() {
    let builder = FixtureBuilder::new("test").skip_save_path();

    assert!(
        !builder.run_save_path,
        "skip_save_path should disable the save pipeline"
    );
}

/// Test metadata serialization.
#[test]
fn test_metadata_serialization() {
    let metadata = FixtureMetadata {
        name: "test".to_string(),
        description: "Test fixture".to_string(),
        generated_at: "2024-01-01T00:00:00Z".to_string(),
        kitty_version: "0.25.0".to_string(),
        tab_count: 2,
        window_count: 4,
        complexity: "light".to_string(),
        tags: vec!["test".to_string()],
        build_params: {
            let mut m = std::collections::HashMap::new();
            m.insert("num_tabs".to_string(), "2".to_string());
            m
        },
        scenario: Some(FixtureScenario {
            min_tabs: 1,
            max_tabs: 2,
            min_windows: 2,
            max_windows: 4,
            min_buffers: 4,
            max_buffers: 8,
            min_nvim: 0,
            max_nvim: 1,
            min_tmux: 0,
            max_tmux: 0,
        }),
    };

    let json = serde_json::to_string_pretty(&metadata).unwrap();
    let parsed: FixtureMetadata = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed.name, "test");
    assert_eq!(parsed.tab_count, 2);
}

/// Test count_tabs_windows_from_ls with synthetic ls JSON.
#[test]
fn test_count_tabs_windows_from_ls() {
    // Minimal kitty ls JSON: 1 OS window, 2 tabs, 3 windows total
    let ls_json = r#"[
      {
        "id": 1,
        "tabs": [
          { "id": 1, "windows": [ { "id": 1 }, { "id": 2 } ] },
          { "id": 2, "windows": [ { "id": 3 } ] }
        ]
      }
    ]"#;
    let (tabs, windows) = FixtureBuilder::count_tabs_windows_from_ls(ls_json);
    assert_eq!(tabs, 2);
    assert_eq!(windows, 3);

    // Empty array
    let (tabs, windows) = FixtureBuilder::count_tabs_windows_from_ls("[]");
    assert_eq!(tabs, 0);
    assert_eq!(windows, 0);

    // Invalid JSON
    let (tabs, windows) = FixtureBuilder::count_tabs_windows_from_ls("not json");
    assert_eq!(tabs, 0);
    assert_eq!(windows, 0);
}

/// Test scenario setter methods.
#[test]
fn test_scenario_setters() {
    let builder = FixtureBuilder::new("test")
        .scenario_tabs(1, 3)
        .scenario_windows(2, 8)
        .scenario_buffers(4, 12)
        .scenario_nvim(0, 2)
        .scenario_tmux(1, 1);

    assert_eq!(builder.scenario_tabs, Some((1, 3)));
    assert_eq!(builder.scenario_windows, Some((2, 8)));
    assert_eq!(builder.scenario_buffers, Some((4, 12)));
    assert_eq!(builder.scenario_nvim, Some((0, 2)));
    assert_eq!(builder.scenario_tmux, Some((1, 1)));
}

// ============== Fixture Generation Tests ==============
// These tests generate actual fixtures that are committed to the repo.
// Run with: cargo test --test fixture_builder -- --ignored

/// Generate light scenario fixture: 1-2 tabs, 2-4 windows, 4-8 buffers
#[test]
#[ignore = "generates fixture files; run manually to update fixtures"]
fn generate_light_001_fixture() {
    if !kitty_is_usable() {
        eprintln!("fixture_builder: `kitty --version` failed -- skipping fixture generation.");
        return;
    }
    if !kitten_is_usable() {
        eprintln!("fixture_builder: `kitten --version` failed -- skipping fixture generation.");
        return;
    }

    let builder = FixtureBuilder::new("light_001")
        .description("Light scenario: minimal session for baseline benchmarks")
        .num_tabs(2)
        .num_windows(2)
        .scenario_tabs(1, 2)
        .scenario_windows(2, 4)
        .scenario_buffers(4, 8)
        .scenario_nvim(1, 2)
        .scenario_tmux(0, 1)
        .add_tag("light")
        .add_tag("baseline");

    match builder.build() {
        Ok(path) => println!("Light fixture generated at: {}", path.display()),
        Err(e) => panic!("Failed to generate light fixture: {}", e),
    }
}

/// Generate typical scenario fixture: 3-4 tabs, 6-10 windows, 15-25 buffers
#[test]
#[ignore = "generates fixture files; run manually to update fixtures"]
fn generate_typical_001_fixture() {
    if !kitty_is_usable() {
        eprintln!("fixture_builder: `kitty --version` failed -- skipping fixture generation.");
        return;
    }
    if !kitten_is_usable() {
        eprintln!("fixture_builder: `kitten --version` failed -- skipping fixture generation.");
        return;
    }

    let builder = FixtureBuilder::new("typical_001")
        .description("Typical scenario: moderate session for realistic benchmarks")
        .num_tabs(4)
        .num_windows(3)
        .scenario_tabs(3, 4)
        .scenario_windows(6, 10)
        .scenario_buffers(15, 25)
        .scenario_nvim(2, 4)
        .scenario_tmux(1, 2)
        .add_tag("typical")
        .add_tag("realistic");

    match builder.build() {
        Ok(path) => println!("Typical fixture generated at: {}", path.display()),
        Err(e) => panic!("Failed to generate typical fixture: {}", e),
    }
}

// ============== Fixture Generation Tests ==============
// These tests run with --ignored and generate actual fixtures

/// Build light scenario fixture: minimal session for baseline benchmarks
/// Run with: cargo test --test fixture_builder test_build_light_001 -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty"]
fn test_build_light_001() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building light_001 fixture...");

    let result = FixtureBuilder::new("light_001")
        .description("Light scenario: minimal session for baseline benchmarks")
        .num_tabs(2)
        .num_windows(2)
        .scenario_tabs(1, 2)
        .scenario_windows(2, 4)
        .scenario_buffers(4, 8)
        .scenario_nvim(1, 2)
        .scenario_tmux(0, 1)
        .add_tag("light")
        .add_tag("baseline")
        .build();

    match result {
        Ok(path) => {
            println!("Light fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build light fixture: {}", e);
        }
    }
}

/// Build typical scenario fixture: moderate session for realistic benchmarks
/// Run with: cargo test --test fixture_builder test_build_typical_001 -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty"]
fn test_build_typical_001() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building typical_001 fixture...");

    let result = FixtureBuilder::new("typical_001")
        .description("Typical scenario: moderate session for realistic benchmarks")
        .num_tabs(4)
        .num_windows(3)
        .scenario_tabs(3, 4)
        .scenario_windows(6, 10)
        .scenario_buffers(15, 25)
        .scenario_nvim(2, 4)
        .scenario_tmux(1, 2)
        .add_tag("typical")
        .add_tag("realistic")
        .build();

    match result {
        Ok(path) => {
            println!("Typical fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build typical fixture: {}", e);
        }
    }
}

// ============== nvim State Fixture Generation Tests ==============
// These tests generate nvim state fixtures for testing save/restore edge cases.
// Run with: cargo test --test fixture_builder test_build_nvim -- --ignored --nocapture

/// Build nvim clean fixture: no open files, no changes
/// Run with: cargo test --test fixture_builder test_build_nvim_clean -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty with nvim"]
fn test_build_nvim_clean() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building nvim_clean fixture...");

    let result = FixtureBuilder::new("nvim_clean")
        .description("Clean nvim: no open files, no unsaved changes")
        .num_tabs(1)
        .num_windows(1)
        .scenario_tabs(1, 1)
        .scenario_windows(1, 1)
        .scenario_buffers(0, 0)
        .scenario_nvim(1, 1)
        .scenario_tmux(0, 0)
        .nvim_clean(0)
        .add_tag("nvim")
        .add_tag("clean")
        .add_tag("no-files")
        .build();

    match result {
        Ok(path) => {
            println!("nvim_clean fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build nvim_clean fixture: {}", e);
        }
    }
}

/// Build nvim dirty fixture: modified files with unsaved changes
/// Run with: cargo test --test fixture_builder test_build_nvim_dirty -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty with nvim"]
fn test_build_nvim_dirty() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building nvim_dirty fixture...");

    let result = FixtureBuilder::new("nvim_dirty")
        .description("Dirty nvim: modified files with unsaved changes")
        .num_tabs(1)
        .num_windows(1)
        .scenario_tabs(1, 1)
        .scenario_windows(1, 2)
        .scenario_buffers(2, 4)
        .scenario_nvim(1, 1)
        .scenario_tmux(0, 0)
        .nvim_dirty(0, vec!["dirty_a.rs".to_string(), "dirty_b.rs".to_string()])
        .add_tag("nvim")
        .add_tag("dirty")
        .add_tag("modified")
        .build();

    match result {
        Ok(path) => {
            println!("nvim_dirty fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build nvim_dirty fixture: {}", e);
        }
    }
}

/// Build nvim multi-tab fixture: nvim with multiple tab pages
/// Run with: cargo test --test fixture_builder test_build_nvim_multi_tab -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty with nvim"]
fn test_build_nvim_multi_tab() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building nvim_multi_tab fixture...");

    let result = FixtureBuilder::new("nvim_multi_tab")
        .description("Multi-tab nvim: multiple nvim tab pages open")
        .num_tabs(1)
        .num_windows(1)
        .scenario_tabs(1, 1)
        .scenario_windows(1, 1)
        .scenario_buffers(3, 6)
        .scenario_nvim(1, 1)
        .scenario_tmux(0, 0)
        .nvim_multi_tab(
            0,
            vec![
                "tab1.rs".to_string(),
                "tab2.rs".to_string(),
                "tab3.rs".to_string(),
            ],
        )
        .add_tag("nvim")
        .add_tag("multi-tab")
        .build();

    match result {
        Ok(path) => {
            println!("nvim_multi_tab fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build nvim_multi_tab fixture: {}", e);
        }
    }
}

/// Build nvim splits fixture: nvim with horizontal/vertical split windows
/// Run with: cargo test --test fixture_builder test_build_nvim_splits -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty with nvim"]
fn test_build_nvim_splits() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building nvim_splits fixture...");

    let result = FixtureBuilder::new("nvim_splits")
        .description("Split nvim: horizontal and vertical splits in a single tab")
        .num_tabs(1)
        .num_windows(1)
        .scenario_tabs(1, 1)
        .scenario_windows(1, 1)
        .scenario_buffers(4, 4)
        .scenario_nvim(1, 1)
        .scenario_tmux(0, 0)
        .nvim_splits(
            0,
            vec![
                "split_main.rs".to_string(),
                "split_left.rs".to_string(),
                "split_right.rs".to_string(),
                "split_bottom.rs".to_string(),
            ],
        )
        .add_tag("nvim")
        .add_tag("splits")
        .add_tag("multi-window")
        .build();

    match result {
        Ok(path) => {
            println!("nvim_splits fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build nvim_splits fixture: {}", e);
        }
    }
}

// ============== tmux Fixture Generation Tests ==============
// These tests generate tmux session fixtures for benchmarking capture/restore.
// Run with: cargo test --test fixture_builder test_build_tmux -- --ignored --nocapture

/// Build tmux single session fixture: one session, one window
/// Run with: cargo test --test fixture_builder test_build_tmux_single -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty with tmux"]
fn test_build_tmux_single() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building tmux_single fixture...");

    let result = FixtureBuilder::new("tmux_single")
        .description("Single tmux session with a single window")
        .num_tabs(1)
        .num_windows(1)
        .scenario_tabs(1, 1)
        .scenario_windows(1, 1)
        .scenario_buffers(0, 0)
        .scenario_nvim(0, 0)
        .scenario_tmux(1, 1)
        .tmux_single(0, "fixture-single")
        .add_tag("tmux")
        .add_tag("single")
        .build();

    match result {
        Ok(path) => {
            println!("tmux_single fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build tmux_single fixture: {}", e);
        }
    }
}

/// Build tmux multiple windows fixture: one session, three windows
/// Run with: cargo test --test fixture_builder test_build_tmux_multi_window -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty with tmux"]
fn test_build_tmux_multi_window() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building tmux_multi_window fixture...");

    let result = FixtureBuilder::new("tmux_multi_window")
        .description("Single tmux session with multiple windows")
        .num_tabs(1)
        .num_windows(1)
        .scenario_tabs(1, 1)
        .scenario_windows(1, 1)
        .scenario_buffers(0, 0)
        .scenario_nvim(0, 0)
        .scenario_tmux(1, 1)
        .tmux_multi_window(
            0,
            "fixture-multi-win",
            vec![
                "editor".to_string(),
                "build".to_string(),
                "logs".to_string(),
            ],
        )
        .add_tag("tmux")
        .add_tag("multi-window")
        .build();

    match result {
        Ok(path) => {
            println!("tmux_multi_window fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build tmux_multi_window fixture: {}", e);
        }
    }
}

/// Build tmux multiple sessions fixture: two sessions, two windows each
/// Run with: cargo test --test fixture_builder test_build_tmux_multi_session -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty with tmux"]
fn test_build_tmux_multi_session() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building tmux_multi_session fixture...");

    let result = FixtureBuilder::new("tmux_multi_session")
        .description("Multiple independent tmux sessions")
        .num_tabs(2)
        .num_windows(1)
        .scenario_tabs(2, 2)
        .scenario_windows(2, 2)
        .scenario_buffers(0, 0)
        .scenario_nvim(0, 0)
        .scenario_tmux(2, 2)
        .tmux_multi_session(
            0,
            vec![
                (
                    "fixture-project-a".to_string(),
                    vec!["code".to_string(), "tests".to_string()],
                ),
                (
                    "fixture-project-b".to_string(),
                    vec!["server".to_string(), "client".to_string()],
                ),
            ],
        )
        .add_tag("tmux")
        .add_tag("multi-session")
        .build();

    match result {
        Ok(path) => {
            println!("tmux_multi_session fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build tmux_multi_session fixture: {}", e);
        }
    }
}

/// Build tmux panes fixture: windows with multiple split panes
/// Run with: cargo test --test fixture_builder test_build_tmux_panes -- --ignored --nocapture
#[test]
#[ignore = "generates fixture - run with --ignored; requires live kitty with tmux"]
fn test_build_tmux_panes() {
    if !kitty_is_usable() || !kitten_is_usable() {
        eprintln!("fixture_builder: kitty/kitten not available - skipping");
        return;
    }

    println!("Building tmux_panes fixture...");

    let result = FixtureBuilder::new("tmux_panes")
        .description("tmux windows with multiple split panes")
        .num_tabs(1)
        .num_windows(1)
        .scenario_tabs(1, 1)
        .scenario_windows(1, 1)
        .scenario_buffers(0, 0)
        .scenario_nvim(0, 0)
        .scenario_tmux(1, 1)
        .tmux_panes(0, "fixture-panes", 2, 1)
        .add_tag("tmux")
        .add_tag("panes")
        .build();

    match result {
        Ok(path) => {
            println!("tmux_panes fixture created at: {}", path.display());
        }
        Err(e) => {
            panic!("Failed to build tmux_panes fixture: {}", e);
        }
    }
}

// ============== Heavy / Very-Heavy Fixture Generation ==============
// These are runtime-generated and cached locally (NOT committed).

/// Build heavy scenario fixture: 5 tabs, 4 windows per tab = 20 windows total
/// Run with: cargo test --test fixture_builder -- --ignored test_build_heavy_001 --nocapture
#[test]
#[ignore = "requires real kitty + high resources - run with: cargo test --test fixture_builder -- --ignored test_build_heavy_001 --nocapture"]
fn test_build_heavy_001() -> Result<(), Box<dyn std::error::Error>> {
    FixtureBuilder::new("heavy_001")
        .description("Heavy scenario: large session for stress benchmarks")
        .num_tabs(5)
        .num_windows(4) // 5*4 = 20 windows
        .add_tag("heavy")
        .add_tag("benchmark")
        .build()?;
    Ok(())
}

/// Build very heavy scenario fixture: 8 tabs, 4 windows per tab = 32 windows total
///
/// Includes multiple nvim instances (files, multi-tab, splits, dirty) and
/// multiple tmux sessions to exercise the full adapter pipeline under load.
///
/// Scenario ranges:
/// - tabs: 6..8+
/// - windows: 20..32+
/// - buffers: 60..80+
/// - nvim instances: 4..6+
/// - tmux sessions: 3..4+
///
/// Run with: cargo test --test fixture_builder -- --ignored test_build_very_heavy_001 --nocapture
#[test]
#[ignore = "requires real kitty + very high resources - run with: cargo test --test fixture_builder -- --ignored test_build_very_heavy_001 --nocapture"]
fn test_build_very_heavy_001() -> Result<(), Box<dyn std::error::Error>> {
    FixtureBuilder::new("very_heavy_001")
        .description(
            "Very heavy scenario: maximum session with multiple nvim instances and tmux sessions \
             for stress testing the full save/restore pipeline",
        )
        .num_tabs(8)
        .num_windows(4) // 8*4 = 32 windows total
        .scenario_tabs(6, 10)
        .scenario_windows(20, 40)
        .scenario_buffers(60, 100)
        .scenario_nvim(4, 6)
        .scenario_tmux(3, 5)
        // Tab 0: nvim with multiple files open (clean state)
        .nvim_files(
            0,
            vec![
                "src/main.rs".to_string(),
                "src/lib.rs".to_string(),
                "src/session.rs".to_string(),
                "src/transport.rs".to_string(),
                "Cargo.toml".to_string(),
            ],
        )
        // Tab 1: nvim with multi-tab pages (many buffers)
        .nvim_multi_tab(
            1,
            vec![
                "src/adapters/mod.rs".to_string(),
                "src/adapters/nvim.rs".to_string(),
                "src/adapters/tmux.rs".to_string(),
                "src/adapters/shell.rs".to_string(),
                "src/adapters/scrollback.rs".to_string(),
            ],
        )
        // Tab 2: nvim with split windows
        .nvim_splits(
            2,
            vec![
                "tests/fixture_builder.rs".to_string(),
                "tests/fixture_verification.rs".to_string(),
                "tests/helpers/mod.rs".to_string(),
            ],
        )
        // Tab 3: nvim with dirty (unsaved) buffers
        .nvim_dirty(
            3,
            vec![
                "scratch/notes.md".to_string(),
                "scratch/todo.txt".to_string(),
                "scratch/draft.rs".to_string(),
            ],
        )
        // Tab 4: nvim clean (empty buffer, like :enew)
        .nvim_clean(4)
        // Tab 5: tmux with multiple independent sessions (covers 3 sessions across tabs 5-7)
        .tmux_multi_session(
            5,
            vec![
                (
                    "vh-project-a".to_string(),
                    vec!["code".to_string(), "test".to_string(), "logs".to_string()],
                ),
                (
                    "vh-project-b".to_string(),
                    vec!["server".to_string(), "client".to_string()],
                ),
                (
                    "vh-infra".to_string(),
                    vec![
                        "docker".to_string(),
                        "k8s".to_string(),
                        "monitoring".to_string(),
                    ],
                ),
            ],
        )
        .add_tag("very-heavy")
        .add_tag("benchmark")
        .add_tag("stress-test")
        .add_tag("nvim")
        .add_tag("tmux")
        .build()?;
    Ok(())
}

// ============== Helper Functions ==============

/// Ensure a fixture exists, generating it if needed.
///
/// Returns the path to the fixture directory. If the fixture already exists
/// (has metadata.json, conf/ls.json, AND state/manifest.json), returns the
/// cached path. Otherwise calls `builder_fn` to generate it.
pub fn ensure_fixture(
    name: &str,
    builder_fn: impl FnOnce() -> Result<PathBuf, Box<dyn std::error::Error>>,
) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let fixture_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("real_workflow")
        .join(name);
    if fixture_dir.join("metadata.json").exists()
        && fixture_dir.join("conf/ls.json").exists()
        && fixture_dir.join("state/manifest.json").exists()
    {
        return Ok(fixture_dir);
    }
    builder_fn()
}
