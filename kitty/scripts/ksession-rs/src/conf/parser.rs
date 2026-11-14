//! Parser for kitty `.conf` session files.
//!
//! This module parses kitty session files (produced by `kitty @ ls --output-format=session`
//! or `kitten @ action save_as_session`) into a structured Tab → Windows representation.
//!
//! The parser handles the following directives:
//!   - `new_tab` / `new_tab <title>`
//!   - `new_os_window`
//!   - `cd <directory>`
//!   - `layout <name>`
//!   - `enabled_layouts <list>`
//!   - `launch ...` (with various options)
//!   - `focus_matching_window ...`
//!   - `focus_tab <index>`
//!   - `focus`
//!   - `set_layout_state ...`
//!
//! For `launch` lines, the parser extracts:
//!   - `--var ksession_idx=N` (tab index within the OS window)
//!   - `--var ksession_win=N` (window ID from kitty-unserialize-data)
//!   - `--cwd <directory>`
//!   - `--title <title>`
//!   - Program argv

use std::path::PathBuf;

/// Result of parsing a kitty .conf file.
#[derive(Debug, Clone, Default)]
pub struct ParsedConf {
    /// The parsed tabs organized by OS window.
    pub os_windows: Vec<ParsedOsWindow>,
}

/// A parsed OS window (collection of tabs).
#[derive(Debug, Clone, Default)]
pub struct ParsedOsWindow {
    /// The tabs within this OS window.
    pub tabs: Vec<ParsedTab>,
    /// The tab index to focus (from `focus_tab N`).
    pub focus_tab: Option<usize>,
}

/// A parsed tab (collection of windows).
#[derive(Debug, Clone, Default)]
pub struct ParsedTab {
    /// Optional title of the tab.
    pub title: Option<String>,
    /// The layout name (e.g., "splits", "fat", "grid").
    pub layout: Option<String>,
    /// Enabled layouts for this tab.
    pub enabled_layouts: Option<String>,
    /// The raw layout state JSON payload (from `set_layout_state ...`).
    pub layout_state: Option<String>,
    /// Whether explicit `focus` directive was present.
    pub focus: bool,
    /// The focus_matching_window payload (if present).
    pub focus_matching_window: Option<String>,
    /// The working directory inherited by windows in this tab.
    pub cwd: Option<PathBuf>,
    /// The windows within this tab.
    pub windows: Vec<ParsedWindow>,
    /// Index of the active window within this tab.
    pub active_window_idx: usize,
}

impl Default for ParsedWindow {
    fn default() -> Self {
        Self {
            kitty_id: None,
            ksession_idx: None,
            ksession_win: None,
            ksession_id: None,
            window_type: None,
            hold: false,
            cwd: None,
            title: None,
            argv: Vec::new(),
            keep_focus: false,
        }
    }
}

/// A parsed window within a tab.
#[derive(Debug, Clone)]
pub struct ParsedWindow {
    /// The kitty window ID from `kitty-unserialize-data`.
    pub kitty_id: Option<u64>,
    /// The ksession-assigned tab index (from `--var ksession_idx`).
    pub ksession_idx: Option<u32>,
    /// The ksession-assigned window ID (from `--var ksession_win`).
    pub ksession_win: Option<u32>,
    /// The ksession-assigned UUID (from `--var ksession_id`).
    pub ksession_id: Option<String>,
    /// The window type (from `--type=xxx`).
    pub window_type: Option<String>,
    /// Whether to hold the window open after program exits (from `--hold`).
    pub hold: bool,
    /// The working directory for the window.
    pub cwd: Option<PathBuf>,
    /// Window title.
    pub title: Option<String>,
    /// The program argv (command + args).
    pub argv: Vec<String>,
    /// Whether this window should keep focus after launch.
    pub keep_focus: bool,
}

/// Errors that can occur during parsing.
#[derive(Debug)]
pub enum ParseError {
    /// Invalid line format.
    InvalidLine(String),
    /// Invalid directive.
    InvalidDirective(String),
    /// Unterminated quoted string.
    UnterminatedQuote(String),
    /// Invalid JSON in set_layout_state.
    InvalidJson(String),
    /// Unknown error.
    Other(String),
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ParseError::InvalidLine(s) => write!(f, "invalid line: {}", s),
            ParseError::InvalidDirective(s) => write!(f, "invalid directive: {}", s),
            ParseError::UnterminatedQuote(s) => write!(f, "unterminated quote: {}", s),
            ParseError::InvalidJson(s) => write!(f, "invalid JSON: {}", s),
            ParseError::Other(s) => write!(f, "parse error: {}", s),
        }
    }
}

impl std::error::Error for ParseError {}

/// Parser for kitty .conf session files.
pub struct ConfParser {
    /// Completed OS windows.
    finished_os_windows: Vec<ParsedOsWindow>,
    /// Current OS window being parsed.
    current_os_window: ParsedOsWindow,
    /// Current tab being parsed.
    current_tab: Option<ParsedTab>,
    /// Whether we're in an OS window (first one is implicit).
    os_window_count: usize,
    /// Track if we've seen a `focus` directive (indicates active window).
    pending_focus: bool,
    /// Index of the window that was focused.
    focused_window_idx: Option<usize>,
}

impl ConfParser {
    /// Create a new parser.
    pub fn new() -> Self {
        Self {
            finished_os_windows: Vec::new(),
            current_os_window: ParsedOsWindow {
                tabs: Vec::new(),
                focus_tab: None,
            },
            current_tab: None,
            os_window_count: 0,
            pending_focus: false,
            focused_window_idx: None,
        }
    }

    /// Parse a complete .conf file.
    pub fn parse(conf: &str) -> Result<ParsedConf, ParseError> {
        let mut parser = Self::new();
        parser.parse_str(conf)?;
        Ok(parser.finish())
    }

    /// Parse from a string.
    pub fn parse_str(&mut self, conf: &str) -> Result<(), ParseError> {
        for line in conf.lines() {
            self.parse_line(line)?;
        }
        Ok(())
    }

    /// Finish parsing and return the result.
    pub fn finish(mut self) -> ParsedConf {
        // Flush any pending tab.
        if let Some(tab) = self.current_tab.take() {
            self.finalize_tab(tab);
        }

        // Apply pending focus to the last OS window's last tab.
        if self.pending_focus {
            if let Some(last_osw) = self.finished_os_windows.last_mut() {
                if let Some(last_tab) = last_osw.tabs.last_mut() {
                    if !last_tab.windows.is_empty() {
                        last_tab.active_window_idx = last_tab.windows.len() - 1;
                    }
                }
            } else if !self.current_os_window.tabs.is_empty() {
                // Handle case where focus is in the current OS window
                if let Some(last_tab) = self.current_os_window.tabs.last_mut() {
                    if !last_tab.windows.is_empty() {
                        last_tab.active_window_idx = last_tab.windows.len() - 1;
                    }
                }
            }
            self.pending_focus = false;
        }

        // Collect all OS windows.
        let mut os_windows = std::mem::take(&mut self.finished_os_windows);
        if !self.current_os_window.tabs.is_empty() {
            os_windows.push(self.current_os_window);
        }

        // If we have at least one OS window, we're done. Otherwise create a default.
        if os_windows.is_empty() {
            os_windows.push(ParsedOsWindow {
                tabs: Vec::new(),
                focus_tab: None,
            });
        }

        ParsedConf { os_windows }
    }

    /// Parse a single line.
    fn parse_line(&mut self, line: &str) -> Result<(), ParseError> {
        let trimmed = line.trim();

        // Skip empty lines and comments.
        if trimmed.is_empty() || trimmed.starts_with('#') {
            return Ok(());
        }

        // Check for focus directive.
        if trimmed == "focus" {
            self.pending_focus = true;
            // Also mark focus on current tab
            if let Some(ref mut tab) = self.current_tab {
                tab.focus = true;
            }
            return Ok(());
        }

        // Check for focus_tab.
        if let Some(rest) = trimmed.strip_prefix("focus_tab") {
            let rest = rest.trim();
            if !rest.is_empty() {
                // focus_tab N - sets the active tab index
                if let Ok(idx) = rest.parse::<usize>() {
                    self.current_os_window.focus_tab = Some(idx);
                }
            }
            return Ok(());
        }

        // Check for focus_matching_window.
        if let Some(payload) = trimmed.strip_prefix("focus_matching_window") {
            let payload = payload.trim();
            if let Some(ref mut tab) = self.current_tab {
                tab.focus_matching_window = Some(payload.to_string());
            }
            return Ok(());
        }

        // Check for new_os_window.
        if trimmed == "new_os_window" || trimmed.starts_with("new_os_window ") {
            self.handle_new_os_window()?;
            return Ok(());
        }

        // Check for new_tab.
        if trimmed == "new_tab" || trimmed.starts_with("new_tab ") {
            self.handle_new_tab(trimmed)?;
            return Ok(());
        }

        // Check for cd.
        if let Some(dir) = trimmed.strip_prefix("cd ") {
            self.handle_cd(dir.trim())?;
            return Ok(());
        }

        // Check for layout.
        if let Some(layout) = trimmed.strip_prefix("layout ") {
            self.handle_layout(layout.trim())?;
            return Ok(());
        }

        // Check for enabled_layouts.
        if let Some(layouts) = trimmed.strip_prefix("enabled_layouts ") {
            self.handle_enabled_layouts(layouts.trim())?;
            return Ok(());
        }

        // Check for set_layout_state (JSON blob).
        if let Some(payload) = trimmed.strip_prefix("set_layout_state ") {
            // Store the JSON payload for later use (e.g., restoration)
            if let Some(tab) = self.current_tab.as_mut() {
                tab.layout_state = Some(payload.to_string());
            }
            return Ok(());
        }

        // Check for launch.
        if trimmed.starts_with("launch") {
            self.handle_launch(trimmed)?;
            return Ok(());
        }

        // Unknown line - skip but could log warning
        Ok(())
    }

    /// Handle new_os_window directive.
    fn handle_new_os_window(&mut self) -> Result<(), ParseError> {
        // Flush any pending tab.
        if let Some(tab) = self.current_tab.take() {
            self.finalize_tab(tab);
        }

        // Flush current OS window if it has tabs.
        if !self.current_os_window.tabs.is_empty() {
            let osw = std::mem::take(&mut self.current_os_window);
            self.finished_os_windows.push(osw);
        }

        self.current_os_window = ParsedOsWindow {
            tabs: Vec::new(),
            focus_tab: None,
        };
        self.os_window_count += 1;
        Ok(())
    }

    /// Handle new_tab directive.
    fn handle_new_tab(&mut self, line: &str) -> Result<(), ParseError> {
        // Flush any pending tab first.
        if let Some(tab) = self.current_tab.take() {
            self.finalize_tab(tab);
        }

        // Extract optional title.
        let title = if line.starts_with("new_tab ") {
            Some(line[8..].trim().to_string())
        } else {
            None
        };

        self.current_tab = Some(ParsedTab {
            title,
            layout: None,
            enabled_layouts: None,
            layout_state: None,
            focus: false,
            focus_matching_window: None,
            cwd: None,
            windows: Vec::new(),
            active_window_idx: 0,
        });

        Ok(())
    }

    /// Handle cd directive.
    fn handle_cd(&mut self, dir: &str) -> Result<(), ParseError> {
        if let Some(ref mut tab) = self.current_tab {
            tab.cwd = Some(PathBuf::from(dir));
        }
        Ok(())
    }

    /// Handle layout directive.
    fn handle_layout(&mut self, layout: &str) -> Result<(), ParseError> {
        if let Some(ref mut tab) = self.current_tab {
            tab.layout = Some(layout.to_string());
        }
        Ok(())
    }

    /// Handle enabled_layouts directive.
    fn handle_enabled_layouts(&mut self, layouts: &str) -> Result<(), ParseError> {
        if let Some(ref mut tab) = self.current_tab {
            tab.enabled_layouts = Some(layouts.to_string());
        }
        Ok(())
    }

    /// Handle launch directive.
    fn handle_launch(&mut self, line: &str) -> Result<(), ParseError> {
        // Ensure we have a current tab.
        if self.current_tab.is_none() {
            self.current_tab = Some(ParsedTab {
                title: None,
                layout: None,
                enabled_layouts: None,
                layout_state: None,
                focus: false,
                focus_matching_window: None,
                cwd: None,
                windows: Vec::new(),
                active_window_idx: 0,
            });
        }

        let tab = self.current_tab.as_mut().unwrap();

        // Parse the launch line tokens.
        let tokens = shlex_split(line);

        // Extract options and argv.
        let mut kitty_id: Option<u64> = None;
        let mut ksession_idx: Option<u32> = None;
        let mut ksession_win: Option<u32> = None;
        let mut ksession_id: Option<String> = None;
        let mut window_type: Option<String> = None;
        let mut hold = false;
        let mut cwd: Option<PathBuf> = None;
        let mut title: Option<String> = None;
        let keep_focus = false;
        let mut argv: Vec<String> = Vec::new();

        let mut iter = tokens.into_iter().skip(1); // Skip "launch"

        // Latch: launch options only appear before the program name. Once the
        // first non-option token (the program) is seen, every subsequent token
        // -- including `--`-prefixed ones such as `pi --continue` or
        // `nvim --clean` -- is program argv and must be kept verbatim.
        // Mirrors the `in_argv` pattern in conf/mod.rs::patch_launch.
        let mut in_argv = false;

        while let Some(token) = iter.next() {
            if !in_argv {
                // Check for our special tokens.
                if let Some(id_str) = token.strip_prefix("kitty-unserialize-data=") {
                    // Parse JSON: {"id": N}
                    if let Some(id) = parse_unserialize_id(id_str) {
                        kitty_id = Some(id);
                    }
                    continue;
                }

                // Handle --var KEY=VALUE (single-token form)
                if let Some(rest) = token.strip_prefix("--var=") {
                    let key_val: Vec<&str> = rest.splitn(2, '=').collect();
                    if key_val.len() == 2 {
                        match key_val[0] {
                            "ksession_idx" => {
                                if let Ok(idx) = key_val[1].parse() {
                                    ksession_idx = Some(idx);
                                }
                            }
                            "ksession_win" => {
                                if let Ok(win) = key_val[1].parse() {
                                    ksession_win = Some(win);
                                }
                            }
                            "ksession_id" => {
                                // Store the UUID string
                                ksession_id = Some(key_val[1].to_string());
                            }
                            _ => {}
                        }
                    }
                    continue;
                }

                // Handle --var (two-token form)
                if token == "--var" {
                    if let Some(next) = iter.next() {
                        let key_val: Vec<&str> = next.splitn(2, '=').collect();
                        if key_val.len() == 2 {
                            match key_val[0] {
                                "ksession_idx" => {
                                    if let Ok(idx) = key_val[1].parse() {
                                        ksession_idx = Some(idx);
                                    }
                                }
                                "ksession_win" => {
                                    if let Ok(win) = key_val[1].parse() {
                                        ksession_win = Some(win);
                                    }
                                }
                                "ksession_id" => {
                                    // Store the UUID string
                                    ksession_id = Some(key_val[1].to_string());
                                }
                                _ => {}
                            }
                        }
                    }
                    continue;
                }

                // Handle --var (other user vars - skip any --var-prefixed)
                if token.starts_with("--var") {
                    continue;
                }

                // Handle --cwd
                if let Some(dir) = token.strip_prefix("--cwd=") {
                    cwd = Some(PathBuf::from(dir));
                    continue;
                }
                if token == "--cwd" {
                    if let Some(dir) = iter.next() {
                        cwd = Some(PathBuf::from(dir));
                    }
                    continue;
                }

                // Handle --title
                if let Some(t) = token.strip_prefix("--title=") {
                    title = Some(t.to_string());
                    continue;
                }
                if token == "--title" {
                    if let Some(t) = iter.next() {
                        title = Some(t.to_string());
                    }
                    continue;
                }

                // Handle --type (window type: overlay, window, tab, etc.)
                if let Some(typ) = token.strip_prefix("--type=") {
                    window_type = Some(typ.to_string());
                    continue;
                }
                if token == "--type" {
                    // Two-token form: extract the value from the next token.
                    if let Some(typ) = iter.next() {
                        window_type = Some(typ.to_string());
                    }
                    continue;
                }

                // Handle --env (environment variables). Consume the value of
                // the two-token form so `--env KEY=VAL` doesn't flip the latch
                // and leak KEY=VAL into argv.
                if token == "--env" {
                    let _ = iter.next();
                    continue;
                }
                if token.starts_with("--env") {
                    continue;
                }

                // Handle --hold
                if token == "--hold" {
                    hold = true;
                    continue;
                }

                // Any other pre-program option (--keep-focus, --no-response,
                // --opt=value, etc.) is skipped. Unknown two-token options
                // cannot be distinguished from the program name; assume
                // flag-only, matching conf/mod.rs::patch_launch.
                if token.starts_with("--") {
                    continue;
                }

                // First non-option token: the program starts here.
                in_argv = true;
            }

            // Inside argv: keep every token verbatim (including `--continue`,
            // `--resume`, `-u`, ...).
            argv.push(token);
        }

        // Apply pending focus.
        if self.pending_focus {
            self.focused_window_idx = Some(tab.windows.len());
            self.pending_focus = false;
        }

        let window = ParsedWindow {
            kitty_id,
            ksession_idx,
            ksession_win,
            ksession_id,
            window_type,
            hold,
            cwd: cwd.or_else(|| tab.cwd.clone()),
            title,
            argv,
            keep_focus,
        };

        tab.windows.push(window);

        Ok(())
    }

    /// Finalize the current tab.
    fn finalize_tab(&mut self, mut tab: ParsedTab) {
        // Set active window index from focus if applicable.
        if let Some(idx) = self.focused_window_idx {
            if idx < tab.windows.len() {
                tab.active_window_idx = idx;
            }
        }
        self.focused_window_idx = None;

        self.current_os_window.tabs.push(tab);
    }
}

impl Default for ConfParser {
    fn default() -> Self {
        Self::new()
    }
}

/// Parse kitty-unserialize-data JSON.
fn parse_unserialize_id(json: &str) -> Option<u64> {
    // Handle both quoted and unquoted JSON.
    let json = json.trim();
    if json.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(json) {
            return v.get("id").and_then(|v| v.as_u64());
        }
    }
    None
}

/// Split a line into shell-style tokens (similar to conf/mod.rs).
fn shlex_split(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut have_token = false;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        if c == '\'' {
            have_token = true;
            for nc in chars.by_ref() {
                if nc == '\'' {
                    break;
                }
                cur.push(nc);
            }
        } else if c == '"' {
            have_token = true;
            for nc in chars.by_ref() {
                if nc == '"' {
                    break;
                }
                cur.push(nc);
            }
        } else if c.is_ascii_whitespace() {
            if have_token {
                out.push(std::mem::take(&mut cur));
                have_token = false;
            }
        } else {
            cur.push(c);
            have_token = true;
        }
    }
    if have_token {
        out.push(cur);
    }
    out
}

// ---------- tests ----------

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn parse_empty() {
        let result = ConfParser::parse("").unwrap();
        assert_eq!(result.os_windows.len(), 1);
        assert!(result.os_windows[0].tabs.is_empty());
    }

    #[test]
    fn parse_new_tab() {
        let conf = "new_tab\n";
        let result = ConfParser::parse(conf).unwrap();
        assert_eq!(result.os_windows.len(), 1);
        assert_eq!(result.os_windows[0].tabs.len(), 1);
    }

    #[test]
    fn parse_new_tab_with_title() {
        let conf = "new_tab editor\n";
        let result = ConfParser::parse(conf).unwrap();
        assert_eq!(
            result.os_windows[0].tabs[0].title,
            Some("editor".to_string())
        );
    }

    #[test]
    fn parse_multiple_tabs() {
        let conf = r#"
new_tab tab1
launch /bin/bash
new_tab tab2
launch /bin/zsh
"#;
        let result = ConfParser::parse(conf).unwrap();
        assert_eq!(result.os_windows[0].tabs.len(), 2);
        assert_eq!(result.os_windows[0].tabs[0].title, Some("tab1".to_string()));
        assert_eq!(result.os_windows[0].tabs[1].title, Some("tab2".to_string()));
    }

    #[test]
    fn parse_layout() {
        let conf = r#"
new_tab
layout splits
launch /bin/bash
"#;
        let result = ConfParser::parse(conf).unwrap();
        assert_eq!(
            result.os_windows[0].tabs[0].layout,
            Some("splits".to_string())
        );
    }

    #[test]
    fn parse_cd() {
        let conf = r#"
new_tab
cd /home/user
launch /bin/bash
"#;
        let result = ConfParser::parse(conf).unwrap();
        assert_eq!(
            result.os_windows[0].tabs[0].cwd,
            Some(PathBuf::from("/home/user"))
        );
    }

    #[test]
    fn parse_launch_with_unserialize_id() {
        let conf = r#"new_tab
launch 'kitty-unserialize-data={"id": 42}' /bin/bash
"#;
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        assert_eq!(window.kitty_id, Some(42));
        assert_eq!(window.argv, vec!["/bin/bash"]);
    }

    #[test]
    fn parse_launch_with_ksession_vars() {
        let conf = r#"new_tab
launch 'kitty-unserialize-data={"id": 5}' --var=ksession_idx=0 --var=ksession_win=1 /bin/bash -l
"#;
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        assert_eq!(window.kitty_id, Some(5));
        assert_eq!(window.ksession_idx, Some(0));
        assert_eq!(window.ksession_win, Some(1));
        assert_eq!(window.argv, vec!["/bin/bash", "-l"]);
    }

    #[test]
    fn parse_launch_with_cwd_and_title() {
        let conf = r#"new_tab
launch --cwd=/home/user --title=MyWindow /bin/bash
"#;
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        assert_eq!(window.cwd, Some(PathBuf::from("/home/user")));
        assert_eq!(window.title, Some("MyWindow".to_string()));
    }

    #[test]
    fn parse_focus_sets_active_window() {
        let conf = r#"
new_tab
launch /bin/bash
launch /usr/bin/zsh
focus
"#;
        let result = ConfParser::parse(conf).unwrap();
        assert_eq!(result.os_windows[0].tabs[0].active_window_idx, 1);
    }

    #[test]
    fn parse_multiple_windows_in_tab() {
        let conf = r#"
new_tab
launch /bin/bash
launch /usr/bin/zsh
launch /bin/fish
"#;
        let result = ConfParser::parse(conf).unwrap();
        assert_eq!(result.os_windows[0].tabs[0].windows.len(), 3);
    }

    #[test]
    fn parse_nested_quotes() {
        let conf = r#"new_tab
launch --title="Hello World" '/usr/bin/with space'
"#;
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        assert_eq!(window.title, Some("Hello World".to_string()));
        assert_eq!(window.argv, vec!["/usr/bin/with space"]);
    }

    #[test]
    fn parse_two_token_var_form() {
        let conf = r#"new_tab
launch 'kitty-unserialize-data={"id": 3}' --var ksession_idx=0 --var ksession_win=1 nvim
"#;
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        assert_eq!(window.ksession_idx, Some(0));
        assert_eq!(window.ksession_win, Some(1));
        assert_eq!(window.argv, vec!["nvim"]);
    }

    #[test]
    fn parse_real_world_fixture() {
        let conf = r#"# W1_minimal session
new_os_window
new_tab main
layout splits
launch --type=window /bin/bash
"#;
        let result = ConfParser::parse(conf).unwrap();
        assert_eq!(result.os_windows.len(), 1);
        assert_eq!(result.os_windows[0].tabs.len(), 1);
        assert_eq!(result.os_windows[0].tabs[0].title, Some("main".to_string()));
        assert_eq!(
            result.os_windows[0].tabs[0].layout,
            Some("splits".to_string())
        );
    }

    #[test]
    fn parse_complex_fixture() {
        // From W5_mixed fixture
        let conf = r#"# W5_mixed session
new_os_window
new_tab editor
layout splits
launch --type=window nvim
new_tab tmux
layout splits
launch --type=window tmux attach -t dev
new_os_window
new_tab shell
layout splits
launch --type=window /bin/bash
"#;
        let result = ConfParser::parse(conf).unwrap();
        assert_eq!(result.os_windows.len(), 2);
        assert_eq!(result.os_windows[0].tabs.len(), 2);
        assert_eq!(result.os_windows[1].tabs.len(), 1);
    }

    #[test]
    fn parse_launch_overlay_with_scrollback_and_tmux() {
        // This is the problematic case: overlay window with scrollback-wrapped tmux command
        // The .conf line looks like:
        // launch --type=overlay --hold --var=ksession_id=UUID /bin/sh -c 'cat ...ansi; exec tmux'
        let conf = r#"new_tab
launch --type=overlay --hold --var=ksession_id=abc123 /bin/sh -c 'cat /path/scrollback/win-5.ansi 2>/dev/null; exec tmux'
"#;
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        // ksession_id should be extracted
        assert_eq!(window.ksession_id.as_deref(), Some("abc123"));
        // window_type should be extracted
        assert_eq!(window.window_type.as_deref(), Some("overlay"));
        // hold should be extracted
        assert!(window.hold);
        // argv should contain the program and args, NOT the kitty options
        assert_eq!(window.argv.len(), 3);
        assert_eq!(window.argv[0], "/bin/sh");
        assert_eq!(window.argv[1], "-c");
        assert!(window.argv[2].contains("cat"));
        assert!(window.argv[2].contains("scrollback"));
        assert!(window.argv[2].contains("tmux"));
        // --type=overlay and --hold should NOT be in argv
        for arg in &window.argv {
            assert!(!arg.starts_with("--"));
        }
    }

    #[test]
    fn parse_launch_agent_resume_flag_kept_in_argv() {
        // Regression: `--continue` appended at save time by AGENT_RESUME_RULES
        // must survive the into-current re-parse. Previously the option loop
        // treated every `--`-prefixed token as a launch option, even after the
        // program name, so `pi --continue` parsed to just `["pi"]`.
        let conf = r#"new_tab
launch --hold --var=ksession_id=abc pi --continue
"#;
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        assert!(window.hold);
        assert_eq!(window.ksession_id.as_deref(), Some("abc"));
        assert_eq!(window.argv, vec!["pi", "--continue"]);
    }

    #[test]
    fn parse_launch_claude_resume_kept_in_argv() {
        let conf = "new_tab\nlaunch claude --resume\n";
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        assert_eq!(window.argv, vec!["claude", "--resume"]);
    }

    #[test]
    fn parse_launch_program_flags_kept_verbatim() {
        // Program flags after the program name must pass through verbatim,
        // including long options that the parser would otherwise mistake for
        // launch options.
        let conf = "new_tab\nlaunch --cwd=/tmp nvim --clean -u NONE\n";
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        assert_eq!(window.cwd, Some(PathBuf::from("/tmp")));
        assert_eq!(window.argv, vec!["nvim", "--clean", "-u", "NONE"]);
    }

    #[test]
    fn parse_launch_options_before_program_still_parsed_as_options() {
        // Guard for existing behavior: launch options BEFORE the program are
        // consumed as options, not argv -- even with two-token value forms.
        let conf = r#"new_tab
launch --type=overlay --hold --keep-focus --var ksession_idx=2 --env FOO=bar --title MyTitle pi --continue
"#;
        let result = ConfParser::parse(conf).unwrap();
        let window = &result.os_windows[0].tabs[0].windows[0];
        assert_eq!(window.window_type.as_deref(), Some("overlay"));
        assert!(window.hold);
        assert_eq!(window.ksession_idx, Some(2));
        assert_eq!(window.title.as_deref(), Some("MyTitle"));
        assert_eq!(window.argv, vec!["pi", "--continue"]);
    }

    #[test]
    fn parse_tab_with_layout_state() {
        // Test that set_layout_state is preserved
        let conf = r#"new_tab
layout splits
set_layout_state {"pairs": {"one": 1}, "opts": {"default_axis_is_horizontal": true}}
launch /bin/bash
"#;
        let result = ConfParser::parse(conf).unwrap();
        let tab = &result.os_windows[0].tabs[0];
        // layout should be parsed
        assert_eq!(tab.layout.as_deref(), Some("splits"));
        // layout_state should be preserved
        assert!(tab.layout_state.is_some());
        let layout_state = tab.layout_state.as_ref().unwrap();
        assert!(layout_state.contains("pairs"));
        assert!(layout_state.contains("opts"));
    }

    #[test]
    fn parse_focus_tab() {
        // Test that focus_tab is preserved
        let conf = r#"new_tab
focus_tab 0
new_tab
focus_tab 1
"#;
        let result = ConfParser::parse(conf).unwrap();
        // First OS window should have 2 tabs
        assert_eq!(result.os_windows.len(), 1);
        assert_eq!(result.os_windows[0].tabs.len(), 2);
        // focus_tab should be stored on the OS window
        assert_eq!(result.os_windows[0].focus_tab, Some(1));
    }

    #[test]
    fn parse_focus_directive() {
        // Test that explicit focus directive is preserved
        let conf = r#"new_tab
launch /bin/bash
focus
"#;
        let result = ConfParser::parse(conf).unwrap();
        let tab = &result.os_windows[0].tabs[0];
        // focus should be true
        assert!(tab.focus);
    }

    #[test]
    fn parse_focus_matching_window() {
        // Test that focus_matching_window directive is preserved
        let conf = r#"new_tab
launch /bin/bash
focus_matching_window id:5
"#;
        let result = ConfParser::parse(conf).unwrap();
        let tab = &result.os_windows[0].tabs[0];
        // focus_matching_window should be stored
        assert!(tab.focus_matching_window.is_some());
        assert_eq!(tab.focus_matching_window.as_deref(), Some("id:5"));
    }

    #[test]
    fn parse_real_workflow_light_001_layout_and_focus() {
        // Regression test for real-workflow fixture light_001
        // This fixture has: layout, enabled_layouts, set_layout_state, focus, focus_tab
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

        let result = ConfParser::parse(conf).unwrap();

        // Should have 1 OS window with 2 tabs
        assert_eq!(result.os_windows.len(), 1);
        assert_eq!(result.os_windows[0].tabs.len(), 2);

        // First tab: check layout
        let tab0 = &result.os_windows[0].tabs[0];
        assert_eq!(
            tab0.layout.as_deref(),
            Some("fat"),
            "tab 0 layout should be 'fat'"
        );

        // First tab: check enabled_layouts
        assert_eq!(
            tab0.enabled_layouts.as_deref(),
            Some("fat,grid,horizontal,splits,stack,tall,vertical"),
            "tab 0 enabled_layouts should be preserved"
        );

        // First tab: check layout_state
        assert!(
            tab0.layout_state.is_some(),
            "tab 0 should have layout_state"
        );
        let state0 = tab0.layout_state.as_ref().unwrap();
        assert!(
            state0.contains("Fat"),
            "tab 0 layout_state should contain class"
        );
        assert!(
            state0.contains("main_bias"),
            "tab 0 layout_state should contain main_bias"
        );

        // First tab: check focus (window focus marker)
        // The focus directive sets focus=true on the tab when present
        assert!(tab0.focus, "tab 0 should have focus marker");

        // First tab: should have 2 windows
        assert_eq!(tab0.windows.len(), 2, "tab 0 should have 2 windows");

        // Second tab: check layout
        let tab1 = &result.os_windows[0].tabs[1];
        assert_eq!(
            tab1.layout.as_deref(),
            Some("fat"),
            "tab 1 layout should be 'fat'"
        );

        // Second tab: check enabled_layouts
        assert_eq!(
            tab1.enabled_layouts.as_deref(),
            Some("fat,grid,horizontal,splits,stack,tall,vertical"),
            "tab 1 enabled_layouts should be preserved"
        );

        // Second tab: check layout_state
        assert!(
            tab1.layout_state.is_some(),
            "tab 1 should have layout_state"
        );

        // Second tab: check focus
        assert!(tab1.focus, "tab 1 should have focus marker");

        // Second tab: should have 2 windows
        assert_eq!(tab1.windows.len(), 2, "tab 1 should have 2 windows");

        // Check focus_tab on OS window
        assert_eq!(
            result.os_windows[0].focus_tab,
            Some(1),
            "os_window focus_tab should be 1"
        );
    }

    #[test]
    fn parse_real_workflow_typical_001_layout_and_focus() {
        // Check typical_001 fixture if it exists and has layout/focus directives
        // This is a second regression test for another fixture
        let conf = r#"new_tab editors
layout vertical
enabled_layouts vertical,horizontal,grid,splits,tall,fat,stack
cd /home/andrew
launch /bin/bash
focus

new_tab
layout splits
enabled_layouts vertical,horizontal,grid,splits,tall,fat,stack
cd /home/andrew
launch /usr/bin/vim
launch /bin/bash
focus

focus_tab 1"#;

        let result = ConfParser::parse(conf).unwrap();

        // Should have 1 OS window with 2 tabs
        assert_eq!(result.os_windows.len(), 1);
        assert_eq!(result.os_windows[0].tabs.len(), 2);

        // First tab
        let tab0 = &result.os_windows[0].tabs[0];
        assert_eq!(tab0.layout.as_deref(), Some("vertical"));
        assert!(tab0.enabled_layouts.is_some());
        assert!(tab0.focus, "first tab should have focus");

        // Second tab
        let tab1 = &result.os_windows[0].tabs[1];
        assert_eq!(tab1.layout.as_deref(), Some("splits"));
        assert!(tab1.enabled_layouts.is_some());
        assert!(tab1.focus, "second tab should have focus");
        assert_eq!(tab1.windows.len(), 2, "second tab should have 2 windows");

        // Check focus_tab
        assert_eq!(result.os_windows[0].focus_tab, Some(1));
    }
}
