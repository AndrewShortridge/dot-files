//! Typed deserialization of `kitty @ ls --all-env-vars` output.
//!
//! Hybrid strategy per Plan §5.1: typed structs for the stable spine
//! (id/pid/cwd/title/is_focused/is_active/tabs/windows), `serde_json::Value`
//! for fields kitty has reshaped between releases (`foreground_processes`,
//! `layout_state`, `layout_opts`, `groups`, `neighbors`, `platform_window_id`),
//! and `HashMap<String, String>` for the stable map types we'll key into
//! (`env`, `user_vars`).
//!
//! Every Option / collection field uses `#[serde(default)]` so older or newer
//! kitty versions that omit fields parse cleanly. Never `deny_unknown_fields`:
//! kitty regularly adds fields across point releases.

use std::collections::HashMap;
use std::path::Path;

use serde::Deserialize;
use serde_json::Value;

use crate::error::KError;

#[derive(Debug, Clone, Deserialize)]
pub struct OsWindow {
    pub id: u32,
    #[serde(default)]
    pub is_focused: bool,
    #[serde(default)]
    pub is_active: bool,
    // Phase B.2 active-OS-window restoration keys off this flag.
    #[serde(default)]
    pub last_focused: bool,
    #[serde(default)]
    pub wm_class: Option<String>,
    #[serde(default)]
    pub wm_name: Option<String>,
    // Some kitty versions emit null, others a numeric id — pass through as-is.
    #[serde(default)]
    pub platform_window_id: Option<Value>,
    #[serde(default)]
    pub active_tab_history: Vec<u32>,
    #[serde(default)]
    pub tabs: Vec<Tab>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Tab {
    pub id: u32,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub is_focused: bool,
    #[serde(default)]
    pub is_active: bool,
    #[serde(default)]
    pub layout: Option<String>,
    #[serde(default)]
    pub enabled_layouts: Vec<String>,
    // Opaque — passed verbatim to the rendered .conf per Appendix C.1.
    #[serde(default)]
    pub layout_state: Value,
    #[serde(default)]
    pub layout_opts: Value,
    #[serde(default)]
    pub groups: Value,
    // Window ids are u64 (see `Window.id`); kitty's monotonic counter can
    // exceed u32 over a long-running instance, so keep this in lockstep.
    #[serde(default)]
    pub active_window_history: Vec<u64>,
    #[serde(default)]
    pub windows: Vec<Window>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Window {
    pub id: u64,
    pub pid: u32,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub is_focused: bool,
    #[serde(default)]
    pub is_active: bool,
    #[serde(default)]
    pub is_self: bool,
    #[serde(default)]
    pub overlay_parent: Option<u64>,
    // Kept opaque: kitty has changed this struct shape historically.
    #[serde(default)]
    pub foreground_processes: Vec<Value>,
    #[serde(default)]
    pub neighbors: Value,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub user_vars: HashMap<String, String>,
}

pub fn parse_ls_output(bytes: &[u8]) -> Result<Vec<OsWindow>, KError> {
    Ok(serde_json::from_slice(bytes)?)
}

/// Read a pre-recorded `kitty @ ls --all-env-vars` JSON fixture from a file.
///
/// This enables deterministic testing by bypassing kitty invocation.
pub fn ls_from_file(path: &Path) -> Result<Vec<OsWindow>, KError> {
    let bytes = std::fs::read(path)?;
    parse_ls_output(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    const LIVE_4726: &str = include_str!("../../tests/fixtures/kitty-ls/live-4726.json");
    const LIVE_68204: &str = include_str!("../../tests/fixtures/kitty-ls/live-68204.json");

    #[test]
    fn parses_live_fixture_4726() {
        let parsed = parse_ls_output(LIVE_4726.as_bytes()).expect("fixture parses");
        assert_eq!(parsed.len(), 1);
        let osw = &parsed[0];
        assert_eq!(osw.id, 1);
        assert_eq!(osw.tabs.len(), 2);
        assert!(osw.last_focused);
        assert!(osw.is_active);
        assert!(!osw.is_focused);
        assert_eq!(osw.wm_class.as_deref(), Some("kitty"));

        let tab0 = &osw.tabs[0];
        assert_eq!(tab0.id, 1);
        assert_eq!(tab0.layout.as_deref(), Some("splits"));
        assert_eq!(tab0.enabled_layouts, vec!["splits", "stack"]);
        assert_eq!(tab0.windows.len(), 1);

        let win = &tab0.windows[0];
        assert_eq!(win.id, 1);
        assert_eq!(win.pid, 4744);
        assert!(win.is_active);
        assert!(!win.is_focused);
        assert!(win.is_self);
        assert!(!win.foreground_processes.is_empty());
        assert!(win.env.contains_key("PATH"));
        assert_eq!(
            win.user_vars.get("ksession_probe").map(String::as_str),
            Some("hello")
        );
    }

    #[test]
    fn parses_live_fixture_68204() {
        let parsed = parse_ls_output(LIVE_68204.as_bytes()).expect("fixture parses");
        assert_eq!(parsed.len(), 1);
        let osw = &parsed[0];
        assert_eq!(osw.id, 1);
        assert_eq!(osw.tabs.len(), 2);
        assert!(osw.last_focused);

        assert_eq!(osw.tabs[0].id, 1);
        assert_eq!(osw.tabs[0].windows.len(), 1);
        assert_eq!(osw.tabs[1].id, 2);
        assert_eq!(osw.tabs[1].windows.len(), 1);

        // The §8 overlay-window regression test concept needs both kinds in
        // one fixture so the adapter's is_self filter has something to drop.
        let all_windows: Vec<&Window> = osw.tabs.iter().flat_map(|t| t.windows.iter()).collect();
        assert!(
            all_windows.iter().any(|w| w.is_self),
            "fixture must contain a kitten/self window"
        );
        assert!(
            all_windows.iter().any(|w| !w.is_self),
            "fixture must contain a user window"
        );

        let self_win = &osw.tabs[0].windows[0];
        assert_eq!(self_win.id, 1);
        assert_eq!(self_win.pid, 68224);
        assert!(self_win.is_self);
        assert_eq!(self_win.cwd.as_deref(), Some("/home/andrew"));

        let user_win = &osw.tabs[1].windows[0];
        assert_eq!(user_win.id, 7);
        assert_eq!(user_win.pid, 97221);
        assert!(!user_win.is_self);
        assert!(user_win.user_vars.contains_key("ksession_win"));
        assert!(user_win.user_vars.contains_key("ksession_idx"));
    }

    #[test]
    fn tolerates_unknown_top_level_field() {
        // Inject a future field at OsWindow level; parser must ignore it.
        let injected = LIVE_4726.replacen(r#""id": 1,"#, r#""id": 1,"future_field":42,"#, 1);
        let parsed = parse_ls_output(injected.as_bytes()).expect("unknown field ignored");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].id, 1);
        assert_eq!(parsed[0].tabs.len(), 2);
    }

    #[test]
    fn tolerates_missing_optional_fields() {
        // Minimal JSON exercising the #[serde(default)] story: no wm_class,
        // no wm_name, no last_focused, no is_active/is_focused on the
        // OsWindow.
        let minimal = r#"[{"id": 7, "tabs": []}]"#;
        let parsed = parse_ls_output(minimal.as_bytes()).expect("minimal parses");
        assert_eq!(parsed.len(), 1);
        let osw = &parsed[0];
        assert_eq!(osw.id, 7);
        assert!(osw.tabs.is_empty());
        assert_eq!(osw.wm_class, None);
        assert_eq!(osw.wm_name, None);
        assert!(!osw.last_focused);
        assert!(!osw.is_focused);
        assert!(!osw.is_active);
        assert!(osw.active_tab_history.is_empty());
    }

    #[test]
    fn parses_empty_array() {
        let parsed = parse_ls_output(b"[]").expect("empty array parses");
        assert!(parsed.is_empty());
    }

    #[test]
    fn layout_state_preserved_as_opaque() {
        // Appendix C.1: the conf rewrite step needs the layout_state blob
        // verbatim. Lock that it stays a Value (object) — never decoded into
        // a typed struct.
        let parsed = parse_ls_output(LIVE_4726.as_bytes()).expect("fixture parses");
        let tab0_layout_state = &parsed[0].tabs[0].layout_state;
        assert!(
            tab0_layout_state.is_object(),
            "layout_state should remain an opaque JSON object, got {tab0_layout_state:?}"
        );
        // The known sub-keys from the live capture must still be present in
        // the opaque blob — proves we didn't lose data on the way through.
        let obj = tab0_layout_state.as_object().unwrap();
        for k in ["all_windows", "class", "opts", "pairs"] {
            assert!(obj.contains_key(k), "layout_state missing key {k}");
        }
    }

    #[test]
    fn malformed_json_returns_error() {
        let err = parse_ls_output(b"{not json").expect_err("malformed must error");
        // KError::Json wraps serde_json — check the Display surfaces it.
        let msg = err.to_string();
        assert!(!msg.is_empty());
    }

    #[test]
    fn ls_from_file_parses_fixture() {
        // Use an existing fixture file. Path is relative to crate root.
        let path = Path::new("tests/fixtures/kitty-ls/live-4726.json");
        let parsed = ls_from_file(path).expect("fixture file reads");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].id, 1);
    }

    #[test]
    fn ls_from_file_returns_error_for_missing_file() {
        let path = Path::new("/nonexistent/fixture.json");
        let err = ls_from_file(path).expect_err("missing file must error");
        assert!(err.to_string().contains("No such file"));
    }
}
