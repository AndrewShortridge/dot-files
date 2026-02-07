-- Pull in the wezterm API
local wezterm = require("wezterm")

-- This will hold the configuration.
local config = wezterm.config_builder()

-- This is where you actually apply your config choices.

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
config.term = "xtrem-256color"

-- Finally, return the configuration to wezterm:
return config
