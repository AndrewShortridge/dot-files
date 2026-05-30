--- Graph help display.

local M = {}

--- Show a help float with graph keybindings.
function M.show_help()
  local ui = require("andrew.vault.ui")
  local lines = {
    "  Graph Keybindings",
    "  ─────────────────────────────────",
    "",
    "  Navigation:",
    "    <CR> / gf    Follow link under cursor",
    "    q / <Esc>    Close graph",
    "",
    "  Filtering:",
    "    f            Open filter panel",
    "    u            Toggle unresolved links",
    "    +            Increase link depth",
    "    -            Decrease link depth",
    "    r            Reset all filters",
    "",
    "  Presets:",
    "    p            Load a saved preset",
    "    P            Save current filters as preset",
    "",
    "  Search Integration:",
    "    s            Search within visible graph nodes",
    "",
    "  Filter panel (when open):",
    "    1-8          Configure filter category",
    "    a            Apply and close",
    "    r            Reset all",
    "    q / <Esc>    Cancel",
    "",
    "  Preset picker:",
    "    <CR>         Load selected preset",
    "    Ctrl-x       Delete selected preset",
  }
  ui.create_float_display({
    title = "Graph Help",
    lines = lines,
    width = 50,
    height = #lines,
    cursor_line = false,
  })
end

return M
