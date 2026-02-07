-- Pull in the wezterm API
local wezterm = require("wezterm")

-- This will hold the configuration.
local config = wezterm.config_builder()

-- Setting the leader key to "CTRL+a"
config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1000 }

-- For example, changing the initial geometry for new windows:
config.initial_cols = 120
config.initial_rows = 28

-- Setting the font details
-- config.font = wezterm.font("JetBrains Mono", { weight = "Bold" })
config.font = wezterm.font("JetBrains Mono", { weight = "Regular" })
config.font_size = 16

-- Stting the color scheme
-- config.color_scheme = "One Dark (Gogh)"
-- config.color_scheme = "One Light (Gogh)"
-- config.color_scheme = "One Dark (base16)"
-- config.color_scheme = "One Light (base16)"
-- config.color_scheme = "One Half Black (Gogh)"
-- config.color_scheme = "OneHalfBlack"
config.color_scheme = "Operator Mono Dark"

-- Automatically reload the config
config.automatically_reload_config = true

-- Remove the tab bar from the top
config.enable_tab_bar = true

-- Allow resizable borders
config.window_decorations = "RESIZE"

-- Setting the cursor style
config.default_cursor_style = "BlinkingBar"
config.cursor_blink_rate = 1000

-- Themeing the tab bars
config.use_fancy_tab_bar = false
-- config.window_frame = {}

-- Setting the window padding around the terminal
config.window_padding = {
	left = 10,
	right = 10,
	top = 10,
	bottom = 10,
}

-- Setting the animation and fps explicitly to ensure running at best settings
config.max_fps = 144
config.animation_fps = 30

-- Explicitly setting the color terminal to ensure proper use
-- config.term = "xtrem-256color"

-- --------------------- User Defined keybinds section -------------------------
config.keys = {
	-- Creating and closing new tabs
	-- { key = "t", mods = "CTRL|SHIFT", action = wezterm.action.SpawnTab("CurrentPaneDomain") },
	-- { key = "q", mods = "CTRL|SHIFT", action = wezterm.action.CloseCurrentTab({ confirm = false }) },
	{ key = "t", mods = "LEADER", action = wezterm.action.SpawnTab("CurrentPaneDomain") },
	{ key = "q", mods = "LEADER", action = wezterm.action.CloseCurrentTab({ confirm = false }) },

	-- Changing between tabs
	-- { key = "Tab", mods = "ALT", action = wezterm.action.ActivateTabRelative(1) }, -- This conflicts with some app switchers, may need to update
	-- { key = "Tab", mods = "ALT|SHIFT", action = wezterm.action.ActivateTabRelative(-1) }, -- This conflicts with some app switchers, may need to update
	{ key = "n", mods = "LEADER", action = wezterm.action.ActivateTabRelative(1) },
	{ key = "p", mods = "LEADER", action = wezterm.action.ActivateTabRelative(-1) },

	-- Creating and closing new splits for panes
	-- { key = "-", mods = "CTRL|SHIFT", action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }) },
	--   Setting keybinds similar to tmux keybinds
	{ key = "|", mods = "LEADER|SHIFT", action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }) }, -- This does not work without shift (need shift to use the "|" character)
	{ key = "-", mods = "LEADER", action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }) },
	{ key = "x", mods = "LEADER", action = wezterm.action.CloseCurrentPane({ confirm = false }) }, -- This may conflict with some keybinds for other applications, may need to update later

	-- Changing between splits and panes
	-- { key = "h", mods = "CTRL", action = wezterm.action.ActivatePaneDirection("Left") },
	-- { key = "l", mods = "CTRL", action = wezterm.action.ActivatePaneDirection("Right") },
	-- { key = "j", mods = "CTRL", action = wezterm.action.ActivatePaneDirection("Down") },
	-- { key = "k", mods = "CTRL", action = wezterm.action.ActivatePaneDirection("Up") },
	--   Setting keybinds simlar to tmux keybinds
	{ key = "h", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Left") },
	{ key = "l", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Right") },
	{ key = "j", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Down") },
	{ key = "k", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Up") },
}

-- Finally, return the configuration to wezterm:
return config
