# 16 — Persistent Sidebar Panels

## Problem

The vault system exposes rich relational metadata — backlinks, forward links,
tag hierarchies, frontmatter fields, inline fields — but all of it is accessed
through transient fzf-lua pickers or floating windows. Once the user selects an
item or dismisses the float, the information disappears. There is no persistent,
always-visible panel that updates as the user navigates between notes.

This contrasts with Obsidian, which provides a sidebar with dockable panels for
backlinks, tags, properties, and outgoing links. These panels remain visible
during editing and auto-update when the active note changes, giving the user
ambient awareness of note context without manual invocation.

### Current Access Patterns

| Data                     | Current Access                      | Limitation                                    |
|--------------------------|-------------------------------------|-----------------------------------------------|
| Backlinks                | `<leader>vfb` -> fzf picker        | Transient; no persistent view; no context     |
| Forward links            | `<leader>vfl` -> fzf picker        | Transient; gone after selection               |
| Heading backlinks        | `<leader>vfh` -> fzf picker        | Transient; requires cursor on heading         |
| Tag list                 | `<leader>vft` -> fzf picker        | Flat list; no hierarchy visible               |
| Tag tree                 | `<leader>vfT` -> fzf picker        | Transient; collapse state not preserved       |
| Frontmatter fields       | `<leader>vM` -> floating editor    | Modal; obscures note content; closes on edit  |
| Inline fields            | Highlighted in buffer               | No aggregated view; scattered across lines    |
| Connection graph         | `<leader>vG` -> float              | Transient; no docking                         |

### UX Consequences

1. **Context loss during editing.** A user writing a note has no way to see
   which notes link here without interrupting their flow to open a picker.
2. **No ambient tag awareness.** Understanding the full tag taxonomy requires
   opening the tag tree picker, which disappears after selection.
3. **Metadata editing friction.** The frontmatter editor float blocks the note.
   Users cannot see the note content while editing properties.
4. **No unified metadata view.** Frontmatter fields and inline fields are
   separate systems with different access patterns. There is no single place to
   see "all metadata about this note."

## Current Architecture

### Backlinks (`backlinks.lua`)

The backlinks module (263 lines) collects inbound links via the vault index:

```lua
local function current_file_index_info()
  local bufname = vim.api.nvim_buf_get_name(0)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return nil, nil end
  local entry = idx:get_entry_by_abs(bufname)
  if not entry then return nil, nil end
  return entry.rel_path, idx
end

local inlinks = idx:get_inlinks(rel_path)
```

`find_link_lines(abs_path, target_name, heading_filter)` reads source files to
extract the specific line and line number where the link appears. This provides
the contextual information needed for a sidebar display.

`collect_backlinks(note_name)` in `graph.lua` (lines 141-189) provides a
complementary approach that returns `{name, path}` entries, sorted
alphabetically, with both index-based and ripgrep fallback paths.

### Tag Tree (`tag_tree.lua`)

The tag tree module (183 lines) is a pure data transformation layer:

- `build_tree(tag_counts)` constructs a `TagTreeNode` hierarchy from flat
  `tag -> count` data.
- `flatten(root, collapsed)` produces ANSI-formatted strings for fzf display,
  respecting a `collapsed` set for expand/collapse state.

The ANSI color system (`HL_TO_ANSI` lookup, `colorize_tag()`) is designed for
fzf terminal rendering. A sidebar panel would use extmark-based highlights
instead, but the tree-building logic and sort/filter config are directly
reusable.

### Frontmatter Editor (`frontmatter_editor.lua`)

The frontmatter editor (973 lines) uses a floating window with a custom render
loop:

- `_state` singleton holds `source_buf`, `float_buf`, `float_win`, `fields[]`,
  `cursor_idx`.
- `render()` writes formatted `key : value` lines into a scratch buffer with
  extmark highlights per field type (`VaultFmEditorKey`, `VaultFmEditorString`,
  etc.).
- Edit dispatching uses type-aware handlers: `edit_string_field`,
  `edit_boolean_field`, `edit_cycle_field`, `edit_list_field`,
  `edit_date_field`.
- `write_field_to_source(source_buf, key, value)` writes changes to the
  original buffer via `metaedit.set_field()`, using `nvim_buf_call` to switch
  context.

This pattern of a scratch buffer with extmark rendering and keymapped actions is
directly applicable to sidebar panels. The key difference: the sidebar uses a
vertical split instead of a centered float.

### Inline Fields (`inline_fields.lua`)

The inline fields module (720 lines) parses `[key:: value]`, `(key:: value)`,
and `key:: value` patterns. Its `get_buffer_fields(bufnr)` function returns all
parsed `InlineField` entries for a buffer — this is the extraction API the
metadata panel needs.

### Vault Index API Surface

The sidebar panels rely heavily on the vault index singleton:

| Method                          | Returns                      | Panel Use                              |
|---------------------------------|------------------------------|----------------------------------------|
| `vault_index.current()`        | `VaultIndex\|nil`            | All panels: existence check            |
| `idx:is_ready()`               | `boolean`                    | All panels: readiness guard            |
| `idx:get_entry_by_abs(path)`   | `VaultIndexEntry\|nil`       | All panels: current note lookup        |
| `idx:get_inlinks(rel_path)`    | `table[]`                    | Backlinks panel                        |
| `idx:all_tags()`               | `string[]`                   | Tag tree panel                         |
| `idx:tags_with_counts()`       | `table<string, number>`      | Tag tree panel (with file counts)      |
| `idx:subscribe(fn)`            | `fun()` (unsubscribe)        | All panels: live update trigger        |
| `idx._generation`              | `number`                     | All panels: cache invalidation         |
| `entry.frontmatter`            | `table<string, any>`         | Metadata panel                         |
| `entry.tags`                   | `string[]`                   | Metadata panel (tag section)           |
| `entry.outlinks`               | `table[]`                    | Potential forward links panel          |
| `entry.inline_fields`          | `table<string, string>`      | Metadata panel (inline fields section) |

### UI Module (`ui.lua`)

The UI module (109 lines) provides `create_float_display()` and
`create_float_input()` — both create centered floating windows. The sidebar
panels need a different window creation pattern (vertical splits), so `ui.lua`
will be extended with a new `create_sidebar()` helper.

### Colors (`colors.lua`)

The colors module (381 lines) centralizes highlight definitions with per-
colorscheme palette detection. New sidebar highlight groups will follow the
existing pattern: define in `build_hl_groups(p)`, add palette entries for each
colorscheme variant (onedark, soft_paper_light, soft_paper_dark).

### Config (`config.lua`)

Configuration follows the established pattern of adding a new section to
`config.lua` with sensible defaults. Existing examples: `M.embed`, `M.graph`,
`M.search`, `M.calendar`.

## Solution

Create a new module `lua/andrew/vault/sidebar.lua` that manages a shared
right-side vertical split window. The split hosts one of three panel modes at a
time — backlinks, tag tree, or metadata — with tab-like switching between them.
Each panel is a separate rendering function that writes content into a shared
scratch buffer with extmark-based highlighting and buffer-local keymaps.

### Architecture Overview

```
sidebar.lua (core window management + panel routing)
  |
  +-- sidebar_backlinks.lua   (backlinks panel renderer)
  +-- sidebar_tags.lua        (tag tree panel renderer)
  +-- sidebar_meta.lua        (metadata/properties panel renderer)
```

The core `sidebar.lua` module handles:

- Creating/destroying the split window
- Managing the scratch buffer lifecycle
- Routing to the active panel's render function
- Autocmd registration for auto-updates
- Panel switching (tab bar at top of sidebar)
- Shared keymaps (close, switch panel, resize)

Each panel module exports:

- `render(buf, win, width)` — populate the buffer with content and extmarks
- `setup_keymaps(buf)` — set buffer-local keymaps for interaction
- `panel_name` — display name for the tab bar

### Display Format

The sidebar window has a tab bar at the top showing available panels:

```
 Backlinks | Tags | Meta          <- tab bar (clickable)
─────────────────────────────────  <- separator
 3 backlinks to "Current Note"    <- panel header

  Meeting Notes                   <- backlink entry
    L42: discussed [[Current...   <- context line

  Project Dashboard               <- backlink entry
    L15: see [[Current Note]]     <- context line

  Weekly Review                   <- backlink entry
    L8: reviewed [[Current N...   <- context line
```

### Window Management

The sidebar uses a standard Neovim vertical split (`botright vsplit` or
`topleft vsplit` depending on config). Key decisions:

1. **Scratch buffer, not a real file.** `buftype = "nofile"`, `bufhidden = "wipe"`,
   `swapfile = false`, `modifiable = false` (set modifiable only during render).

2. **Single window, multiple panels.** Switching panels clears and re-renders
   the same buffer. This avoids multiple split windows and simplifies layout.

3. **Fixed width with resize.** Default 40 columns, configurable. The user can
   resize with standard `<C-w><` / `<C-w>>` or a config option.

4. **winfixwidth.** Set `vim.wo[win].winfixwidth = true` so the sidebar does
   not resize when other windows split or close.

5. **Survive buffer changes.** The sidebar window persists across `BufEnter`
   events in other windows. The autocmd triggers a re-render of the active
   panel with new note context.

## Implementation

### New Config Section: `config.lua`

Add to `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/config.lua`:

```lua
-- ---------------------------------------------------------------------------
-- Sidebar panels
-- ---------------------------------------------------------------------------
M.sidebar = {
  -- Default sidebar width in columns.
  width = 40,

  -- Side of the screen: "right" or "left".
  position = "right",

  -- Auto-open sidebar when entering a vault markdown buffer.
  -- Set to false to require manual toggle.
  auto_open = false,

  -- Which panel to show by default when sidebar opens.
  -- One of: "backlinks", "tags", "meta"
  default_panel = "backlinks",

  -- Backlinks panel: number of context lines to show around each link.
  backlinks_context = 1,

  -- Tag tree panel: inherit sort/min_count from config.tag_tree.
  -- Additional sidebar-specific overrides can go here.

  -- Metadata panel: show inline fields alongside frontmatter.
  meta_show_inline = true,

  -- Update debounce in ms (avoid flickering on rapid buffer switches).
  update_debounce_ms = 150,
}
```

### New Palette Entries: `colors.lua`

Add to each palette (onedark, soft_paper_light, soft_paper_dark):

```lua
-- Sidebar
sidebar_tab_active    = "#61afef",   -- active tab text
sidebar_tab_inactive  = "#5c6370",   -- inactive tab text
sidebar_tab_bg        = "#2c323c",   -- tab bar background
sidebar_sep           = "#3e4452",   -- horizontal separators
sidebar_header        = "#c678dd",   -- panel header text
sidebar_file          = "#abb2bf",   -- file/note names
sidebar_context       = "#5c6370",   -- context lines (dimmed)
sidebar_line_nr       = "#4b5263",   -- line numbers in context
sidebar_field_key     = "#e06c75",   -- metadata field keys
sidebar_field_value   = "#98c379",   -- metadata field values
sidebar_tag           = "#c678dd",   -- tags in metadata panel
sidebar_count         = "#5c6370",   -- counts (backlink count, tag count)
sidebar_empty         = "#5c6370",   -- "no backlinks" message
sidebar_cursor        = "#61afef",   -- selected item indicator
```

Add corresponding highlight groups to `build_hl_groups(p)`:

```lua
-- Sidebar
VaultSidebarTabActive     = { fg = p.sidebar_tab_active, bold = true },
VaultSidebarTabInactive   = { fg = p.sidebar_tab_inactive },
VaultSidebarTabBg         = { bg = p.sidebar_tab_bg },
VaultSidebarSep           = { fg = p.sidebar_sep },
VaultSidebarHeader        = { fg = p.sidebar_header, bold = true },
VaultSidebarFile          = { fg = p.sidebar_file, bold = true },
VaultSidebarContext       = { fg = p.sidebar_context, italic = true },
VaultSidebarLineNr        = { fg = p.sidebar_line_nr },
VaultSidebarFieldKey      = { fg = p.sidebar_field_key, bold = true },
VaultSidebarFieldValue    = { fg = p.sidebar_field_value },
VaultSidebarTag           = { fg = p.sidebar_tag, bold = true },
VaultSidebarCount         = { fg = p.sidebar_count },
VaultSidebarEmpty         = { fg = p.sidebar_empty, italic = true },
VaultSidebarCursor        = { fg = p.sidebar_cursor, bold = true },
```

### New File: `lua/andrew/vault/sidebar.lua`

Core sidebar window management module. Estimated: ~350 lines.

```lua
-- sidebar.lua — Persistent sidebar panel manager
-- Manages a shared vertical split with switchable panel views.

local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

---@class SidebarState
---@field win number|nil       Window handle
---@field buf number|nil       Buffer handle
---@field panel string         Active panel name: "backlinks"|"tags"|"meta"
---@field visible boolean      Whether sidebar is currently open
---@field source_win number|nil The main editing window
---@field source_buf number|nil The buffer being inspected
---@field generation number    Last vault index generation rendered
---@field update_timer uv.uv_timer_t|nil Debounce timer for updates

---@type SidebarState
local _state = {
  win = nil,
  buf = nil,
  panel = config.sidebar.default_panel,
  visible = false,
  source_win = nil,
  source_buf = nil,
  generation = -1,
  update_timer = nil,
}

-- Panel renderers (lazy-loaded)
local _panels = {}

--- Register a panel renderer.
---@param name string
---@param panel_module table Must export render(buf, win, width, source_buf), setup_keymaps(buf), panel_name
function M.register_panel(name, panel_module)
  _panels[name] = panel_module
end

-- ---------------------------------------------------------------------------
-- Namespace
-- ---------------------------------------------------------------------------

local NS = vim.api.nvim_create_namespace("vault_sidebar")

-- ---------------------------------------------------------------------------
-- Window management
-- ---------------------------------------------------------------------------

--- Create the sidebar split window and scratch buffer.
---@return boolean success
local function create_sidebar()
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    return true -- already open
  end

  -- Remember the current (editing) window
  _state.source_win = vim.api.nvim_get_current_win()
  _state.source_buf = vim.api.nvim_get_current_buf()

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "vault_sidebar"

  -- Open split
  local position = config.sidebar.position
  local cmd = position == "left" and "topleft vsplit" or "botright vsplit"
  vim.cmd(cmd)

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- Set window options
  vim.api.nvim_win_set_width(win, config.sidebar.width)
  vim.wo[win].winfixwidth = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = true
  vim.wo[win].spell = false
  vim.wo[win].list = false
  vim.wo[win].winfixbuf = true

  _state.win = win
  _state.buf = buf
  _state.visible = true

  -- Return focus to the source window
  if _state.source_win and vim.api.nvim_win_is_valid(_state.source_win) then
    vim.api.nvim_set_current_win(_state.source_win)
  end

  -- Setup shared keymaps
  setup_shared_keymaps(buf)

  -- Auto-close when buffer is wiped
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      _state.win = nil
      _state.buf = nil
      _state.visible = false
    end,
  })

  return true
end

--- Close the sidebar.
local function close_sidebar()
  if _state.win and vim.api.nvim_win_is_valid(_state.win) then
    vim.api.nvim_win_close(_state.win, true)
  end
  if _state.buf and vim.api.nvim_buf_is_valid(_state.buf) then
    pcall(vim.api.nvim_buf_delete, _state.buf, { force = true })
  end
  _state.win = nil
  _state.buf = nil
  _state.visible = false
end

-- ---------------------------------------------------------------------------
-- Tab bar rendering
-- ---------------------------------------------------------------------------

local PANEL_ORDER = { "backlinks", "tags", "meta" }
local PANEL_LABELS = { backlinks = "Backlinks", tags = "Tags", meta = "Meta" }

--- Render the tab bar at the top of the sidebar buffer.
---@param buf number
---@param active_panel string
---@return number lines_used Number of lines consumed by the tab bar
local function render_tab_bar(buf, active_panel)
  local parts = {}
  for _, name in ipairs(PANEL_ORDER) do
    if name == active_panel then
      parts[#parts + 1] = " " .. PANEL_LABELS[name] .. " "
    else
      parts[#parts + 1] = " " .. PANEL_LABELS[name] .. " "
    end
  end
  local tab_line = table.concat(parts, "|")
  local sep_line = string.rep("\u{2500}", config.sidebar.width)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { tab_line, sep_line })

  -- Highlight active/inactive tabs
  local col = 0
  for _, name in ipairs(PANEL_ORDER) do
    local label = " " .. PANEL_LABELS[name] .. " "
    local hl = name == active_panel and "VaultSidebarTabActive" or "VaultSidebarTabInactive"
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, 0, col, {
      end_col = col + #label,
      hl_group = hl,
    })
    col = col + #label + 1 -- +1 for the "|" separator
  end

  -- Separator highlight
  pcall(vim.api.nvim_buf_set_extmark, buf, NS, 1, 0, {
    end_col = #sep_line,
    hl_group = "VaultSidebarSep",
  })

  return 2 -- tab bar + separator
end

-- ---------------------------------------------------------------------------
-- Render dispatch
-- ---------------------------------------------------------------------------

--- Re-render the active panel into the sidebar buffer.
function M.render()
  if not _state.visible then return end
  if not _state.buf or not vim.api.nvim_buf_is_valid(_state.buf) then return end
  if not _state.win or not vim.api.nvim_win_is_valid(_state.win) then return end

  -- Determine source buffer (the note being inspected)
  local source_buf = _state.source_buf
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    source_buf = vim.api.nvim_get_current_buf()
    _state.source_buf = source_buf
  end

  local panel = _panels[_state.panel]
  if not panel then return end

  local width = vim.api.nvim_win_get_width(_state.win)

  -- Make buffer modifiable for writing
  vim.bo[_state.buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(_state.buf, NS, 0, -1)

  -- Render tab bar
  local header_lines = render_tab_bar(_state.buf, _state.panel)

  -- Render panel content below the tab bar
  panel.render(_state.buf, _state.win, width, source_buf, header_lines, NS)

  -- Lock buffer again
  vim.bo[_state.buf].modifiable = false

  -- Setup panel-specific keymaps (idempotent)
  panel.setup_keymaps(_state.buf, _state.source_win)
end

--- Schedule a debounced render.
local function schedule_render()
  if _state.update_timer then
    _state.update_timer:stop()
  end
  _state.update_timer = vim.uv.new_timer()
  _state.update_timer:start(config.sidebar.update_debounce_ms, 0, vim.schedule_wrap(function()
    M.render()
  end))
end

-- ---------------------------------------------------------------------------
-- Shared keymaps (set once on the sidebar buffer)
-- ---------------------------------------------------------------------------

--- Setup keymaps shared across all panels.
---@param buf number
function setup_shared_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Close sidebar
  vim.keymap.set("n", "q", function()
    close_sidebar()
  end, vim.tbl_extend("force", opts, { desc = "Close sidebar" }))

  -- Switch panels: 1/2/3 or b/t/m
  vim.keymap.set("n", "1", function()
    M.switch_panel("backlinks")
  end, vim.tbl_extend("force", opts, { desc = "Switch to backlinks panel" }))

  vim.keymap.set("n", "2", function()
    M.switch_panel("tags")
  end, vim.tbl_extend("force", opts, { desc = "Switch to tag tree panel" }))

  vim.keymap.set("n", "3", function()
    M.switch_panel("meta")
  end, vim.tbl_extend("force", opts, { desc = "Switch to metadata panel" }))

  vim.keymap.set("n", "b", function()
    M.switch_panel("backlinks")
  end, vim.tbl_extend("force", opts, { desc = "Switch to backlinks panel" }))

  vim.keymap.set("n", "t", function()
    M.switch_panel("tags")
  end, vim.tbl_extend("force", opts, { desc = "Switch to tag tree panel" }))

  vim.keymap.set("n", "m", function()
    M.switch_panel("meta")
  end, vim.tbl_extend("force", opts, { desc = "Switch to metadata panel" }))

  -- Tab/Shift-Tab to cycle panels
  vim.keymap.set("n", "<Tab>", function()
    local idx = 1
    for i, name in ipairs(PANEL_ORDER) do
      if name == _state.panel then idx = i break end
    end
    local next_idx = (idx % #PANEL_ORDER) + 1
    M.switch_panel(PANEL_ORDER[next_idx])
  end, vim.tbl_extend("force", opts, { desc = "Next panel" }))

  vim.keymap.set("n", "<S-Tab>", function()
    local idx = 1
    for i, name in ipairs(PANEL_ORDER) do
      if name == _state.panel then idx = i break end
    end
    local prev_idx = ((idx - 2) % #PANEL_ORDER) + 1
    M.switch_panel(PANEL_ORDER[prev_idx])
  end, vim.tbl_extend("force", opts, { desc = "Previous panel" }))

  -- Refresh
  vim.keymap.set("n", "R", function()
    _state.generation = -1
    M.render()
  end, vim.tbl_extend("force", opts, { desc = "Force refresh" }))

  -- Help
  vim.keymap.set("n", "?", function()
    local help = {
      "Sidebar Keybindings:",
      "",
      "  q          Close sidebar",
      "  1 / b      Backlinks panel",
      "  2 / t      Tag tree panel",
      "  3 / m      Metadata panel",
      "  Tab        Next panel",
      "  S-Tab      Previous panel",
      "  R          Force refresh",
      "  ?          This help",
      "",
      "Panel-specific keys shown in each panel.",
    }
    vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
  end, vim.tbl_extend("force", opts, { desc = "Show help" }))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Toggle the sidebar open/closed.
function M.toggle()
  if _state.visible then
    close_sidebar()
  else
    M.open()
  end
end

--- Open the sidebar (idempotent).
---@param panel? string Optional panel to show ("backlinks"|"tags"|"meta")
function M.open(panel)
  if panel then
    _state.panel = panel
  end

  -- Lazy-load panel modules
  if not _panels.backlinks then
    _panels.backlinks = require("andrew.vault.sidebar_backlinks")
  end
  if not _panels.tags then
    _panels.tags = require("andrew.vault.sidebar_tags")
  end
  if not _panels.meta then
    _panels.meta = require("andrew.vault.sidebar_meta")
  end

  if not create_sidebar() then
    vim.notify("Vault: failed to create sidebar", vim.log.levels.ERROR)
    return
  end

  M.render()
end

--- Switch to a different panel.
---@param panel string
function M.switch_panel(panel)
  if not _panels[panel] then
    vim.notify("Vault: unknown panel '" .. panel .. "'", vim.log.levels.WARN)
    return
  end
  _state.panel = panel
  M.render()
end

--- Check if the sidebar is currently visible.
---@return boolean
function M.is_visible()
  return _state.visible
    and _state.win ~= nil
    and vim.api.nvim_win_is_valid(_state.win)
end

--- Get the current sidebar state (for external consumers).
---@return SidebarState
function M.get_state()
  return _state
end

-- ---------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------

--- Update the sidebar when the active buffer changes or a file is saved.
local function on_buf_change(ev)
  if not _state.visible then return end
  if not _state.win or not vim.api.nvim_win_is_valid(_state.win) then return end

  -- Ignore events from the sidebar buffer itself
  if ev.buf == _state.buf then return end

  -- Only update for vault markdown files
  local bufname = vim.api.nvim_buf_get_name(ev.buf)
  if not vim.endswith(bufname, ".md") then return end
  if not engine.is_vault_path(bufname) then return end

  -- Track the new source buffer
  _state.source_buf = ev.buf
  _state.source_win = vim.api.nvim_get_current_win()

  schedule_render()
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local group = vim.api.nvim_create_augroup("VaultSidebar", { clear = true })

  -- Re-render on buffer enter and file save
  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = group,
    callback = on_buf_change,
  })

  vim.api.nvim_create_autocmd({ "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = on_buf_change,
  })

  -- Subscribe to vault index updates for live refresh
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VaultCacheInvalidate",
    callback = function()
      if _state.visible then
        _state.generation = -1
        schedule_render()
      end
    end,
  })

  -- User commands
  vim.api.nvim_create_user_command("VaultSidebar", function(opts)
    if opts.args == "" then
      M.toggle()
    elseif opts.args == "close" then
      close_sidebar()
    else
      M.open(opts.args)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "backlinks", "tags", "meta", "close" }
    end,
    desc = "Toggle or open vault sidebar panel",
  })

  vim.api.nvim_create_user_command("VaultSidebarBacklinks", function()
    M.open("backlinks")
  end, { desc = "Open vault sidebar: backlinks panel" })

  vim.api.nvim_create_user_command("VaultSidebarTags", function()
    M.open("tags")
  end, { desc = "Open vault sidebar: tag tree panel" })

  vim.api.nvim_create_user_command("VaultSidebarMeta", function()
    M.open("meta")
  end, { desc = "Open vault sidebar: metadata panel" })

  -- Keymaps (global, not buffer-local)
  vim.keymap.set("n", "<leader>vS", function()
    M.toggle()
  end, { desc = "Vault: toggle sidebar", silent = true })

  vim.keymap.set("n", "<leader>vSb", function()
    M.open("backlinks")
  end, { desc = "Vault: sidebar backlinks", silent = true })

  vim.keymap.set("n", "<leader>vSt", function()
    M.open("tags")
  end, { desc = "Vault: sidebar tag tree", silent = true })

  vim.keymap.set("n", "<leader>vSm", function()
    M.open("meta")
  end, { desc = "Vault: sidebar metadata", silent = true })
end

return M
```

### New File: `lua/andrew/vault/sidebar_backlinks.lua`

Backlinks panel renderer. Estimated: ~250 lines.

```lua
-- sidebar_backlinks.lua — Backlinks panel for the vault sidebar
-- Shows all notes linking to the current note with context.

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local link_utils = require("andrew.vault.link_utils")

local M = {}

M.panel_name = "Backlinks"

-- ---------------------------------------------------------------------------
-- Data collection (reuses patterns from backlinks.lua)
-- ---------------------------------------------------------------------------

--- Find lines in a file that contain a wikilink to the target name.
---@param abs_path string
---@param target_name string
---@return { lnum: number, text: string }[]
local function find_link_lines(abs_path, target_name)
  local f = io.open(abs_path, "r")
  if not f then return {} end

  local results = {}
  local lnum = 0
  local target_lower = target_name:lower()
  local pattern = "%[%[(.-)%]%]"

  for line in f:lines() do
    lnum = lnum + 1
    for inner in line:gmatch(pattern) do
      local link_path = inner:match("^(.-)%|") or inner
      local name_part = link_path:match("^([^#^]+)") or link_path
      name_part = vim.trim(name_part):lower()
      local name_basename = name_part:match("([^/]+)$") or name_part
      if name_part == target_lower or name_basename == target_lower then
        results[#results + 1] = { lnum = lnum, text = line }
        break -- one match per line is sufficient
      end
    end
  end

  f:close()
  return results
end

--- Collect backlink data for the current note.
---@param source_buf number
---@return { name: string, path: string, lines: { lnum: number, text: string }[] }[]
local function collect_backlinks(source_buf)
  local bufname = vim.api.nvim_buf_get_name(source_buf)
  if bufname == "" then return {} end

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return {} end

  local entry = idx:get_entry_by_abs(bufname)
  if not entry then return {} end

  local inlinks = idx:get_inlinks(entry.rel_path)
  if #inlinks == 0 then return {} end

  local note_name = entry.basename
  local results = {}

  for _, inlink in ipairs(inlinks) do
    local source_rel = inlink.path .. ".md"
    local source_entry = idx:get_entry(source_rel)
    if source_entry and source_entry.abs_path ~= bufname then
      local lines = find_link_lines(source_entry.abs_path, note_name)
      results[#results + 1] = {
        name = source_entry.basename,
        path = source_entry.abs_path,
        lines = lines,
      }
    end
  end

  table.sort(results, function(a, b) return a.name:lower() < b.name:lower() end)
  return results
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Line-to-action map for navigation.
---@type table<number, { path: string, lnum: number|nil }>
local _line_actions = {}

--- Render the backlinks panel content.
---@param buf number Sidebar buffer
---@param win number Sidebar window
---@param width number Available width in columns
---@param source_buf number The note buffer being inspected
---@param start_line number First line to write content (after tab bar)
---@param ns number Namespace for extmarks
function M.render(buf, win, width, source_buf, start_line, ns)
  _line_actions = {}

  local config = require("andrew.vault.config")
  local context_lines = config.sidebar.backlinks_context

  local backlinks = collect_backlinks(source_buf)

  local lines = {}
  local highlights = {} -- { line_offset, col_start, col_end, hl_group }

  -- Header
  local note_name = engine.current_note_name()
    or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source_buf), ":t:r")
  local header = " " .. #backlinks .. " backlink" .. (#backlinks == 1 and "" or "s")
  if note_name then
    header = header .. ' to "' .. note_name .. '"'
  end
  lines[#lines + 1] = header
  highlights[#highlights + 1] = { 0, 0, #header, "VaultSidebarHeader" }
  lines[#lines + 1] = ""

  if #backlinks == 0 then
    local msg = "  (no backlinks found)"
    lines[#lines + 1] = msg
    highlights[#highlights + 1] = { #lines - 1, 0, #msg, "VaultSidebarEmpty" }
  else
    for _, bl in ipairs(backlinks) do
      -- File name line
      local name_line = "  " .. bl.name
      local line_idx = #lines
      lines[#lines + 1] = name_line
      highlights[#highlights + 1] = { line_idx, 2, 2 + #bl.name, "VaultSidebarFile" }
      _line_actions[start_line + #lines] = { path = bl.path, lnum = nil }

      -- Context lines
      for _, hit in ipairs(bl.lines) do
        local ctx_text = vim.trim(hit.text)
        if #ctx_text > width - 8 then
          ctx_text = ctx_text:sub(1, width - 10) .. "\u{2026}"
        end
        local ctx_line = "    L" .. hit.lnum .. ": " .. ctx_text
        local ctx_idx = #lines
        lines[#lines + 1] = ctx_line
        -- Highlight line number
        local lnum_str = "L" .. hit.lnum
        highlights[#highlights + 1] = { ctx_idx, 4, 4 + #lnum_str, "VaultSidebarLineNr" }
        -- Highlight rest as context
        highlights[#highlights + 1] = { ctx_idx, 4 + #lnum_str + 2, #ctx_line, "VaultSidebarContext" }
        _line_actions[start_line + #lines] = { path = bl.path, lnum = hit.lnum }
      end

      -- Blank line between entries
      lines[#lines + 1] = ""
    end
  end

  -- Write lines into buffer
  vim.api.nvim_buf_set_lines(buf, start_line, -1, false, lines)

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    local row = start_line + hl[1]
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

--- Setup panel-specific keymaps on the sidebar buffer.
---@param buf number
---@param source_win number|nil The editing window to navigate in
function M.setup_keymaps(buf, source_win)
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Enter: jump to backlink source
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local action = _line_actions[cursor[1]]
    if not action then return end

    -- Navigate in the source (editing) window, not the sidebar
    local target_win = source_win
    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
      -- Find a non-sidebar window
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local wbuf = vim.api.nvim_win_get_buf(w)
        if vim.bo[wbuf].filetype ~= "vault_sidebar" then
          target_win = w
          break
        end
      end
    end
    if not target_win then return end

    vim.api.nvim_set_current_win(target_win)
    vim.cmd("edit " .. vim.fn.fnameescape(action.path))
    if action.lnum then
      pcall(vim.api.nvim_win_set_cursor, target_win, { action.lnum, 0 })
    end
  end, vim.tbl_extend("force", opts, { desc = "Jump to backlink" }))

  -- o: open in split
  vim.keymap.set("n", "o", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local action = _line_actions[cursor[1]]
    if not action then return end

    local target_win = source_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    end
    vim.cmd("split " .. vim.fn.fnameescape(action.path))
    if action.lnum then
      pcall(vim.api.nvim_win_set_cursor, 0, { action.lnum, 0 })
    end
  end, vim.tbl_extend("force", opts, { desc = "Open in split" }))

  -- v: open in vsplit
  vim.keymap.set("n", "v", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local action = _line_actions[cursor[1]]
    if not action then return end

    local target_win = source_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    end
    vim.cmd("vsplit " .. vim.fn.fnameescape(action.path))
    if action.lnum then
      pcall(vim.api.nvim_win_set_cursor, 0, { action.lnum, 0 })
    end
  end, vim.tbl_extend("force", opts, { desc = "Open in vsplit" }))
end

return M
```

### New File: `lua/andrew/vault/sidebar_tags.lua`

Tag tree panel renderer. Estimated: ~280 lines.

```lua
-- sidebar_tags.lua — Tag tree panel for the vault sidebar
-- Shows the full tag hierarchy with expand/collapse and file counts.

local config = require("andrew.vault.config")
local vault_index = require("andrew.vault.vault_index")
local tag_tree_builder = require("andrew.vault.tag_tree")

local M = {}

M.panel_name = "Tags"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- Set of collapsed tag paths (persists across re-renders within a session).
---@type table<string, boolean>
local _collapsed = {}

--- Map from display line number to full tag path (for interaction).
---@type table<number, string>
local _line_to_tag = {}

--- The last rendered tree root (for toggle operations).
---@type table|nil
local _last_root = nil

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Render a single tag tree node into display lines (recursive).
---@param node TagTreeNode
---@param depth number Indentation level
---@param lines string[] Accumulator for display lines
---@param highlights table[] Accumulator for highlight entries
---@param start_line number Global line offset for _line_to_tag mapping
---@param width number Available width
local function render_node(node, depth, lines, highlights, start_line, width)
  local has_children = next(node.children) ~= nil
  local is_collapsed = _collapsed[node.full_tag] or false

  local indent = string.rep("  ", depth)
  local icon = has_children and (is_collapsed and "\u{25B8} " or "\u{25BE} ") or "  "

  -- Count string
  local count_str
  local tree_cfg = config.tag_tree
  local show_totals = tree_cfg.show_totals ~= false
  if show_totals and node.count ~= node.total and has_children then
    count_str = " (" .. node.count .. "/" .. node.total .. ")"
  else
    count_str = " (" .. node.count .. ")"
  end

  local display = indent .. icon .. node.name .. count_str
  local line_idx = #lines
  lines[#lines + 1] = display

  -- Register line-to-tag mapping
  _line_to_tag[start_line + #lines] = node.full_tag

  -- Highlights
  local tag_start = #indent + #icon
  local tag_end = tag_start + #node.name

  -- Tag name: use colorize logic from tag_tree module
  local tag_hl = "VaultSidebarTag"
  local ok, cfg = pcall(require, "andrew.vault.config")
  if ok and cfg.tag_highlights and cfg.tag_highlights.categories then
    local lower = node.full_tag:lower()
    for _, cat in ipairs(cfg.tag_highlights.categories) do
      if lower:sub(1, #cat.prefix) == cat.prefix then
        tag_hl = cat.highlight
        break
      end
    end
  end

  highlights[#highlights + 1] = { line_idx, tag_start, tag_end, tag_hl }

  -- Count: dimmed
  highlights[#highlights + 1] = { line_idx, tag_end, #display, "VaultSidebarCount" }

  -- Recurse into children if expanded
  if has_children and not is_collapsed then
    local sort_mode = tree_cfg.sort or "alpha"
    local keys = {}
    for k in pairs(node.children) do keys[#keys + 1] = k end
    if sort_mode == "count" then
      table.sort(keys, function(a, b)
        return node.children[a].total > node.children[b].total
      end)
    else
      table.sort(keys)
    end

    for _, key in ipairs(keys) do
      local child = node.children[key]
      local min_count = tree_cfg.min_count or 0
      if min_count <= 0 or child.total >= min_count or child.count >= min_count then
        render_node(child, depth + 1, lines, highlights, start_line, width)
      end
    end
  end
end

--- Render the tag tree panel content.
---@param buf number
---@param win number
---@param width number
---@param source_buf number (unused for tags — vault-global view)
---@param start_line number
---@param ns number
function M.render(buf, win, width, source_buf, start_line, ns)
  _line_to_tag = {}

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    local msg = "  (vault index not ready)"
    vim.api.nvim_buf_set_lines(buf, start_line, -1, false, { "", msg })
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_line + 1, 0, {
      end_col = #msg,
      hl_group = "VaultSidebarEmpty",
    })
    return
  end

  local tag_counts = idx:tags_with_counts()
  if not next(tag_counts) then
    local msg = "  (no tags found)"
    vim.api.nvim_buf_set_lines(buf, start_line, -1, false, { "", msg })
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_line + 1, 0, {
      end_col = #msg,
      hl_group = "VaultSidebarEmpty",
    })
    return
  end

  local root = tag_tree_builder.build_tree(tag_counts)
  _last_root = root

  local lines = {}
  local highlights = {}

  -- Header
  local total_tags = 0
  for _ in pairs(tag_counts) do total_tags = total_tags + 1 end
  local header = " " .. total_tags .. " tags"
  lines[#lines + 1] = header
  highlights[#highlights + 1] = { 0, 0, #header, "VaultSidebarHeader" }
  lines[#lines + 1] = ""

  -- Render tree nodes
  local sort_mode = config.tag_tree.sort or "alpha"
  local keys = {}
  for k in pairs(root) do keys[#keys + 1] = k end
  if sort_mode == "count" then
    table.sort(keys, function(a, b) return root[a].total > root[b].total end)
  else
    table.sort(keys)
  end

  for _, key in ipairs(keys) do
    render_node(root[key], 0, lines, highlights, start_line, width)
  end

  -- Write to buffer
  vim.api.nvim_buf_set_lines(buf, start_line, -1, false, lines)

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    local row = start_line + hl[1]
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

function M.setup_keymaps(buf, source_win)
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Enter: search notes with this tag
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local tag = _line_to_tag[cursor[1]]
    if not tag then return end
    require("andrew.vault.tags").search_tag(tag)
  end, vim.tbl_extend("force", opts, { desc = "Search notes with tag" }))

  -- Space / l: toggle expand/collapse
  vim.keymap.set("n", "<Space>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local tag = _line_to_tag[cursor[1]]
    if not tag then return end
    _collapsed[tag] = not _collapsed[tag]
    -- Trigger re-render
    local sidebar = require("andrew.vault.sidebar")
    sidebar.render()
  end, vim.tbl_extend("force", opts, { desc = "Toggle expand/collapse" }))

  vim.keymap.set("n", "l", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local tag = _line_to_tag[cursor[1]]
    if not tag then return end
    if _collapsed[tag] then
      _collapsed[tag] = false
      require("andrew.vault.sidebar").render()
    end
  end, vim.tbl_extend("force", opts, { desc = "Expand node" }))

  vim.keymap.set("n", "h", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local tag = _line_to_tag[cursor[1]]
    if not tag then return end
    if not _collapsed[tag] then
      _collapsed[tag] = true
      require("andrew.vault.sidebar").render()
    else
      -- Collapse parent: find parent tag
      local parent = tag:match("^(.+)/[^/]+$")
      if parent and _line_to_tag then
        _collapsed[parent] = true
        require("andrew.vault.sidebar").render()
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "Collapse node or go to parent" }))

  -- zo: expand all
  vim.keymap.set("n", "zo", function()
    _collapsed = {}
    require("andrew.vault.sidebar").render()
  end, vim.tbl_extend("force", opts, { desc = "Expand all" }))

  -- zc: collapse all
  vim.keymap.set("n", "zc", function()
    if _last_root then
      local function collapse_all(children)
        for _, node in pairs(children) do
          if next(node.children) then
            _collapsed[node.full_tag] = true
            collapse_all(node.children)
          end
        end
      end
      collapse_all(_last_root)
      require("andrew.vault.sidebar").render()
    end
  end, vim.tbl_extend("force", opts, { desc = "Collapse all" }))
end

return M
```

### New File: `lua/andrew/vault/sidebar_meta.lua`

Metadata/properties panel renderer. Estimated: ~320 lines.

```lua
-- sidebar_meta.lua — Metadata panel for the vault sidebar
-- Shows frontmatter fields + inline fields for the current note.
-- Supports inline editing via delegating to existing metaedit/frontmatter_editor.

local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local vault_index = require("andrew.vault.vault_index")
local fm_parser = require("andrew.vault.frontmatter_parser")

local M = {}

M.panel_name = "Meta"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

---@type table<number, { section: string, key: string, value: any, field_type: string, source_buf: number }>
local _line_actions = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Classify a field value for display highlighting.
---@param key string
---@param value any
---@return string field_type
local function detect_field_type(key, value)
  if type(value) == "boolean" then return "boolean" end
  if type(value) == "number" then return "number" end
  if type(value) == "table" then return "list" end
  if type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d") then
    return "date"
  end
  return "string"
end

--- Format a field value for display.
---@param value any
---@param field_type string
---@return string
local function format_value(value, field_type)
  if field_type == "list" and type(value) == "table" then
    return table.concat(vim.tbl_map(tostring, value), ", ")
  end
  if field_type == "boolean" then
    return value and "true" or "false"
  end
  return tostring(value)
end

--- Map field type to highlight group.
---@param field_type string
---@return string
local function type_highlight(field_type)
  local map = {
    string  = "VaultSidebarFieldValue",
    number  = "VaultFieldValueNumber",
    boolean = "VaultFieldValueBool",
    date    = "VaultFieldValueDate",
    list    = "VaultSidebarFieldValue",
  }
  return map[field_type] or "VaultSidebarFieldValue"
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Render the metadata panel content.
---@param buf number
---@param win number
---@param width number
---@param source_buf number
---@param start_line number
---@param ns number
function M.render(buf, win, width, source_buf, start_line, ns)
  _line_actions = {}

  local bufname = vim.api.nvim_buf_get_name(source_buf)
  local lines = {}
  local highlights = {}

  -- Note name header
  local note_name = vim.fn.fnamemodify(bufname, ":t:r")
  local header = " " .. note_name
  lines[#lines + 1] = header
  highlights[#highlights + 1] = { 0, 0, #header, "VaultSidebarHeader" }

  -- ─────────────────── Frontmatter section ───────────────────
  lines[#lines + 1] = ""
  local fm_header = " Frontmatter"
  local fm_header_idx = #lines
  lines[#lines + 1] = fm_header
  highlights[#highlights + 1] = { fm_header_idx, 0, #fm_header, "VaultSidebarHeader" }

  local fm = fm_parser.parse_buffer(source_buf)
  if not fm or not fm.fields or not next(fm.fields) then
    local msg = "  (no frontmatter)"
    local msg_idx = #lines
    lines[#lines + 1] = msg
    highlights[#highlights + 1] = { msg_idx, 0, #msg, "VaultSidebarEmpty" }
  else
    -- Determine key order: scan raw lines for insertion order
    local max_scan = config.frontmatter.max_scan_lines
    local line_count = vim.api.nvim_buf_line_count(source_buf)
    local limit = math.min(line_count, max_scan)
    local raw_lines = vim.api.nvim_buf_get_lines(source_buf, 0, limit, false)

    local ordered_keys = {}
    local seen = {}
    for i = fm.start_line + 1, fm.end_line - 1 do
      local key = raw_lines[i]:match("^([%w_%-]+):")
      if key and not seen[key] and fm.fields[key] ~= nil then
        seen[key] = true
        ordered_keys[#ordered_keys + 1] = key
      end
    end
    -- Catch any keys not found by line scanning
    for key in pairs(fm.fields) do
      if not seen[key] then
        ordered_keys[#ordered_keys + 1] = key
      end
    end

    -- Find max key width for alignment
    local max_kw = 0
    for _, k in ipairs(ordered_keys) do
      if #k > max_kw then max_kw = #k end
    end

    for _, key in ipairs(ordered_keys) do
      local value = fm.fields[key]
      local ft = detect_field_type(key, value)
      local disp = format_value(value, ft)
      local padding = string.rep(" ", max_kw - #key)

      local line = "  " .. key .. padding .. " : " .. disp
      if #line > width then
        line = line:sub(1, width - 1) .. "\u{2026}"
      end
      local line_idx = #lines
      lines[#lines + 1] = line

      -- Key highlight
      highlights[#highlights + 1] = { line_idx, 2, 2 + #key, "VaultSidebarFieldKey" }
      -- Separator
      local sep_pos = line:find(" : ", 1, true)
      if sep_pos then
        highlights[#highlights + 1] = { line_idx, sep_pos - 1, sep_pos + 2, "VaultSidebarSep" }
        -- Value
        highlights[#highlights + 1] = { line_idx, sep_pos + 2, #line, type_highlight(ft) }
      end

      -- Register action for editing
      _line_actions[start_line + #lines] = {
        section = "frontmatter",
        key = key,
        value = value,
        field_type = ft,
        source_buf = source_buf,
      }
    end
  end

  -- ─────────────────── Tags section ───────────────────
  local idx = vault_index.current()
  local entry = idx and idx:is_ready() and idx:get_entry_by_abs(bufname) or nil

  lines[#lines + 1] = ""
  local tags_header = " Tags"
  local tags_header_idx = #lines
  lines[#lines + 1] = tags_header
  highlights[#highlights + 1] = { tags_header_idx, 0, #tags_header, "VaultSidebarHeader" }

  if entry and #entry.tags > 0 then
    local tag_line = "  " .. table.concat(
      vim.tbl_map(function(t) return "#" .. t end, entry.tags),
      "  "
    )
    if #tag_line > width then
      -- Wrap tags across multiple lines
      local current = " "
      for _, t in ipairs(entry.tags) do
        local tag_str = " #" .. t
        if #current + #tag_str > width then
          local tidx = #lines
          lines[#lines + 1] = current
          highlights[#highlights + 1] = { tidx, 0, #current, "VaultSidebarTag" }
          current = " " .. tag_str
        else
          current = current .. tag_str
        end
      end
      if current ~= " " then
        local tidx = #lines
        lines[#lines + 1] = current
        highlights[#highlights + 1] = { tidx, 0, #current, "VaultSidebarTag" }
      end
    else
      local tidx = #lines
      lines[#lines + 1] = tag_line
      highlights[#highlights + 1] = { tidx, 0, #tag_line, "VaultSidebarTag" }
    end
  else
    local msg = "  (no tags)"
    local msg_idx = #lines
    lines[#lines + 1] = msg
    highlights[#highlights + 1] = { msg_idx, 0, #msg, "VaultSidebarEmpty" }
  end

  -- ─────────────────── Inline fields section ───────────────────
  if config.sidebar.meta_show_inline then
    lines[#lines + 1] = ""
    local if_header = " Inline Fields"
    local if_header_idx = #lines
    lines[#lines + 1] = if_header
    highlights[#highlights + 1] = { if_header_idx, 0, #if_header, "VaultSidebarHeader" }

    local inline_fields_mod = require("andrew.vault.inline_fields")
    local fields = inline_fields_mod.get_buffer_fields(source_buf)

    if #fields == 0 then
      local msg = "  (no inline fields)"
      local msg_idx = #lines
      lines[#lines + 1] = msg
      highlights[#highlights + 1] = { msg_idx, 0, #msg, "VaultSidebarEmpty" }
    else
      -- Deduplicate by key (show last occurrence)
      local by_key = {}
      local key_order = {}
      for _, f in ipairs(fields) do
        if not by_key[f.key] then
          key_order[#key_order + 1] = f.key
        end
        by_key[f.key] = f
      end

      local max_kw = 0
      for _, k in ipairs(key_order) do
        if #k > max_kw then max_kw = #k end
      end

      for _, key in ipairs(key_order) do
        local f = by_key[key]
        local padding = string.rep(" ", max_kw - #key)
        local line = "  " .. key .. padding .. " : " .. f.value
        if #line > width then
          line = line:sub(1, width - 1) .. "\u{2026}"
        end
        local line_idx = #lines
        lines[#lines + 1] = line

        highlights[#highlights + 1] = { line_idx, 2, 2 + #key, "VaultSidebarFieldKey" }
        local sep_pos = line:find(" : ", 1, true)
        if sep_pos then
          highlights[#highlights + 1] = { line_idx, sep_pos - 1, sep_pos + 2, "VaultSidebarSep" }
          highlights[#highlights + 1] = { line_idx, sep_pos + 2, #line, "VaultSidebarFieldValue" }
        end

        _line_actions[start_line + #lines] = {
          section = "inline",
          key = key,
          value = f.value,
          field_type = "string",
          source_buf = source_buf,
          row = f.row,
        }
      end
    end
  end

  -- ─────────────────── Help footer ───────────────────
  lines[#lines + 1] = ""
  local help = "  [Enter] edit  [a] add field  [dd] delete"
  local help_idx = #lines
  lines[#lines + 1] = help
  highlights[#highlights + 1] = { help_idx, 0, #help, "VaultSidebarCount" }

  -- Write to buffer
  vim.api.nvim_buf_set_lines(buf, start_line, -1, false, lines)

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    local row = start_line + hl[1]
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

function M.setup_keymaps(buf, source_win)
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Enter: edit the field under cursor
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local action = _line_actions[cursor[1]]
    if not action then return end

    if action.section == "frontmatter" then
      -- Delegate to metaedit for frontmatter fields
      local metaedit = require("andrew.vault.metaedit")
      vim.ui.input({
        prompt = action.key .. ": ",
        default = format_value(action.value, action.field_type),
      }, function(new_val)
        if new_val == nil then return end
        local typed = fm_parser.parse_value(new_val)
        vim.api.nvim_buf_call(action.source_buf, function()
          metaedit.set_field(action.key, typed)
        end)
        -- Re-render sidebar
        vim.schedule(function()
          require("andrew.vault.sidebar").render()
        end)
      end)
    elseif action.section == "inline" then
      -- Jump to the inline field in the source buffer for editing
      if source_win and vim.api.nvim_win_is_valid(source_win) then
        vim.api.nvim_set_current_win(source_win)
        if action.row then
          pcall(vim.api.nvim_win_set_cursor, source_win, { action.row + 1, 0 })
        end
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "Edit field" }))

  -- a: add a new frontmatter field (delegates to frontmatter_editor add flow)
  vim.keymap.set("n", "a", function()
    -- Open the full frontmatter editor for adding
    require("andrew.vault.frontmatter_editor").open()
  end, vim.tbl_extend("force", opts, { desc = "Add field (open editor)" }))

  -- dd: delete frontmatter field under cursor
  vim.keymap.set("n", "dd", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local action = _line_actions[cursor[1]]
    if not action or action.section ~= "frontmatter" then
      vim.notify("Sidebar: can only delete frontmatter fields", vim.log.levels.WARN)
      return
    end

    vim.ui.select({ "Yes", "No" }, {
      prompt = "Delete '" .. action.key .. "'?",
    }, function(choice)
      if choice ~= "Yes" then return end

      vim.api.nvim_buf_call(action.source_buf, function()
        -- Use the delete logic from frontmatter_editor
        local max = config.frontmatter.max_scan_lines
        local line_count = vim.api.nvim_buf_line_count(action.source_buf)
        local limit = math.min(line_count, max)
        local buf_lines = vim.api.nvim_buf_get_lines(action.source_buf, 0, limit, false)

        local fm = fm_parser.parse_lines(buf_lines, max)
        if not fm then return end

        local field_start, field_end
        local pat = "^" .. vim.pesc(action.key) .. ":%s*(.*)"
        for i = fm.start_line + 1, fm.end_line - 1 do
          if not field_start then
            if buf_lines[i]:match(pat) then
              field_start = i
              field_end = i
              for j = i + 1, fm.end_line - 1 do
                if buf_lines[j]:match("^%s+%-") then
                  field_end = j
                else
                  break
                end
              end
            end
          end
        end

        if field_start then
          pcall(vim.cmd, "undojoin")
          vim.api.nvim_buf_set_lines(action.source_buf, field_start - 1, field_end, false, {})
        end
      end)

      vim.schedule(function()
        require("andrew.vault.sidebar").render()
      end)
    end)
  end, vim.tbl_extend("force", opts, { desc = "Delete field" }))
end

return M
```

### Modified File: `lua/andrew/vault/config.lua`

Add the `M.sidebar` configuration section (shown in the config section above).

### Modified File: `lua/andrew/vault/colors.lua`

Add palette entries for all three colorscheme variants and the corresponding
highlight group definitions in `build_hl_groups()` (shown in the colors section
above).

### Modified File: `lua/andrew/vault/ui.lua` (Optional)

If shared sidebar window helpers are needed, add a `create_sidebar()` function.
However, the current design handles window creation directly in `sidebar.lua`,
keeping `ui.lua` focused on floating windows. This modification is optional and
deferred unless multiple modules need sidebar window creation.

### Integration: Vault Init

The sidebar module needs to be initialized alongside other vault modules. Add
to the vault initialization path (wherever modules call `.setup()`):

```lua
require("andrew.vault.sidebar").setup()
```

## Keybindings

All sidebar keybindings use the `<leader>vS` prefix:

### Global Keybindings

| Key             | Action                          | Scope       |
|-----------------|---------------------------------|-------------|
| `<leader>vS`    | Toggle sidebar (any panel)      | Global      |
| `<leader>vSb`   | Open/switch to backlinks panel  | Global      |
| `<leader>vSt`   | Open/switch to tag tree panel   | Global      |
| `<leader>vSm`   | Open/switch to metadata panel   | Global      |

### Sidebar Buffer Keybindings (All Panels)

| Key         | Action                      |
|-------------|-----------------------------|
| `q`         | Close sidebar               |
| `1` / `b`   | Switch to backlinks panel   |
| `2` / `t`   | Switch to tag tree panel    |
| `3` / `m`   | Switch to metadata panel    |
| `Tab`       | Next panel                  |
| `S-Tab`     | Previous panel              |
| `R`         | Force refresh               |
| `?`         | Show help                   |

### Backlinks Panel Keybindings

| Key     | Action                                  |
|---------|-----------------------------------------|
| `<CR>`  | Jump to backlink source in editor       |
| `o`     | Open backlink source in horizontal split|
| `v`     | Open backlink source in vertical split  |

### Tag Tree Panel Keybindings

| Key       | Action                              |
|-----------|-------------------------------------|
| `<CR>`    | Search notes with selected tag      |
| `<Space>` | Toggle expand/collapse              |
| `l`       | Expand node                         |
| `h`       | Collapse node or go to parent       |
| `zo`      | Expand all nodes                    |
| `zc`      | Collapse all nodes                  |

### Metadata Panel Keybindings

| Key     | Action                                        |
|---------|-----------------------------------------------|
| `<CR>`  | Edit field (frontmatter via input; inline via jump) |
| `a`     | Add field (opens frontmatter editor)          |
| `dd`    | Delete frontmatter field under cursor         |

## Auto-Update Mechanism

The sidebar re-renders automatically in response to three event sources:

### 1. Buffer Navigation (BufEnter)

When the user switches to a different vault markdown buffer, the sidebar
detects the new `source_buf` and re-renders with the new note's context.
Non-vault and non-markdown buffers are ignored (sidebar shows stale data,
which is correct -- the last vault note's context remains relevant).

### 2. File Saves (BufWritePost)

After saving a vault markdown file, frontmatter and inline fields may have
changed. A debounced re-render picks up the new state.

### 3. Vault Index Updates (VaultCacheInvalidate)

When the vault index rebuilds (file watcher event, manual rebuild, or
background async build), `_generation` is reset and the sidebar re-renders
with fresh backlink and tag data.

### Debounce Strategy

All three event sources trigger `schedule_render()`, which debounces at
`config.sidebar.update_debounce_ms` (default 150ms). This prevents flickering
during rapid buffer switches (e.g., `:bnext` in a loop) and avoids redundant
renders when multiple events fire in quick succession (BufEnter + BufWritePost
on save).

## Edge Cases

### 1. No Vault Detected

If `engine.vault_path` is not set or `engine.is_vault_path()` returns false for
the current buffer, the sidebar suppresses updates. The `on_buf_change()`
callback exits early, leaving the last rendered content visible. If the sidebar
is opened outside a vault context, each panel shows an appropriate message
("vault index not ready", "no frontmatter", etc.).

### 2. Vault Index Not Ready

All three panels guard on `idx:is_ready()`. If the index is not ready:
- Backlinks panel: shows "(no backlinks found)" -- inlinks cannot be queried.
- Tag tree panel: shows "(vault index not ready)".
- Metadata panel: frontmatter is parsed directly from the buffer (no index
  dependency); tags section shows "(vault index not ready)".

### 3. Empty Backlinks

A note with zero inbound links shows "(no backlinks found)" with the
`VaultSidebarEmpty` highlight. This is informative rather than hiding the panel.

### 4. Large Tag Trees

Tag trees with hundreds of tags could overflow the sidebar height. The sidebar
buffer is scrollable (standard Vim `j`/`k`/`Ctrl-d`/`Ctrl-u`). The
`min_count` config inherited from `config.tag_tree` can prune low-count tags.
The collapse/expand system ensures the user can focus on relevant subtrees.

### 5. Window Layout Conflicts

The sidebar uses `winfixwidth = true` and `winfixbuf = true` to prevent layout
reflow when other windows split or close. If the user closes all other windows,
the sidebar becomes the only window. The `BufWipeout` autocmd handles cleanup
if the buffer is wiped externally (e.g., `:bwipeout`).

### 6. Multiple Tabs

The sidebar is per-tab. `_state` is module-level, so opening the sidebar in one
tab and switching to another tab does not affect the first tab's sidebar. If
per-tab isolation is needed in the future, `_state` could be keyed by
`vim.api.nvim_get_current_tabpage()`.

### 7. Source Buffer Deleted

If the source buffer is deleted or wiped while the sidebar is open, the next
`BufEnter` event updates `_state.source_buf` to the new buffer. Stale
references are caught by `vim.api.nvim_buf_is_valid()` checks at the top of
`M.render()`.

### 8. Sidebar Width vs Content

Fields with long values are truncated with an ellipsis character. The tag tree
wraps within the sidebar width via `vim.wo[win].wrap = true` and
`vim.wo[win].linebreak = true`. The truncation threshold is
`config.sidebar.width`, dynamically read from `vim.api.nvim_win_get_width()` in
case the user manually resized.

### 9. Interaction While Sidebar Has Focus

When the user presses `<CR>` on a backlink entry, the navigation happens in the
`source_win`, not the sidebar. The function explicitly calls
`vim.api.nvim_set_current_win(target_win)` to switch focus. If `source_win` was
closed, it falls back to the first non-sidebar window.

## Design Decisions

1. **Splits, not floats.** The sidebar must persist during editing. Floating
   windows are dismissed by focus loss and obscure content. A vertical split
   provides a stable, resizable panel that coexists with the editor.

2. **Single buffer, multiple panels.** Using one scratch buffer for all three
   panels avoids complex multi-window management. Tab-like switching is
   implemented by clearing and re-rendering the buffer content.

3. **Render-on-demand, not reactive.** The sidebar re-renders on events
   (BufEnter, BufWritePost, VaultCacheInvalidate) rather than continuously
   polling. The debounce timer prevents excessive re-renders.

4. **Separation of concerns.** The core `sidebar.lua` handles window/buffer
   lifecycle and routing. Each `sidebar_*.lua` module is a pure renderer that
   accepts a buffer and writes content. This mirrors the existing
   `tag_tree.lua` pattern of pure data transformation.

5. **Reuse existing data paths.** Backlinks come from `vault_index.get_inlinks()`.
   Tags from `vault_index.tags_with_counts()`. Frontmatter from
   `frontmatter_parser.parse_buffer()`. Inline fields from
   `inline_fields.get_buffer_fields()`. No new data collection is needed.

6. **Delegation for editing.** The metadata panel does not reimplement field
   editing. It delegates to `metaedit.set_field()` for frontmatter changes and
   jumps to the source line for inline field editing. This avoids duplicating
   the complex type-aware editing logic in `frontmatter_editor.lua`.

7. **Colors via palette.** New highlight groups are added to `colors.lua` with
   entries in all three palette variants. This ensures correct rendering across
   colorscheme changes and follows the established pattern.

8. **No dependency on external plugins.** The sidebar uses only Neovim core
   APIs (splits, buffers, extmarks, autocmds). No dependency on nvim-tree,
   neo-tree, or other sidebar frameworks.

## Files to Create

| File                                     | Purpose                          | Est. Lines |
|------------------------------------------|----------------------------------|------------|
| `lua/andrew/vault/sidebar.lua`           | Core window management + routing | ~350       |
| `lua/andrew/vault/sidebar_backlinks.lua` | Backlinks panel renderer         | ~250       |
| `lua/andrew/vault/sidebar_tags.lua`      | Tag tree panel renderer          | ~280       |
| `lua/andrew/vault/sidebar_meta.lua`      | Metadata panel renderer          | ~320       |

## Files to Modify

| File                                  | Changes                                           |
|---------------------------------------|---------------------------------------------------|
| `lua/andrew/vault/config.lua`         | Add `M.sidebar` config section                    |
| `lua/andrew/vault/colors.lua`         | Add sidebar palette entries + highlight groups     |
| Vault init path (engine.lua or init)  | Add `require("andrew.vault.sidebar").setup()` call |

## Step-by-Step Implementation Plan

### Step 1: Config and Colors

Add `M.sidebar` to `config.lua` with default values. Add sidebar palette
entries to all three variants in `colors.lua` and the highlight group
definitions in `build_hl_groups()`.

### Step 2: Core Sidebar Module

Create `sidebar.lua` with window management, tab bar rendering, panel routing,
autocmd registration, and shared keymaps. Verify that the sidebar
opens/closes/toggles correctly with an empty panel.

### Step 3: Backlinks Panel

Create `sidebar_backlinks.lua`. Implement `collect_backlinks()` (adapting from
`backlinks.lua` and `graph.lua` patterns), `render()`, and `setup_keymaps()`.
Test: open a well-linked note, verify backlinks appear with context, press
`<CR>` to navigate.

### Step 4: Tag Tree Panel

Create `sidebar_tags.lua`. Implement tree rendering using `tag_tree.build_tree()`
for the data and custom extmark-based rendering (replacing the ANSI-based fzf
approach). Test: verify hierarchy displays, expand/collapse works, `<CR>`
triggers tag search.

### Step 5: Metadata Panel

Create `sidebar_meta.lua`. Implement frontmatter display using
`frontmatter_parser.parse_buffer()`, tag display from vault index, inline
field display from `inline_fields.get_buffer_fields()`. Test: verify all
three sections render, `<CR>` edits fields, `dd` deletes.

### Step 6: Auto-Update

Verify that switching buffers re-renders the sidebar. Verify that saving a file
updates the metadata panel. Verify that vault index rebuilds update backlinks
and tags.

### Step 7: Integration Testing

- Open sidebar -> switch to non-vault buffer -> verify sidebar stays with
  last vault data.
- Open sidebar -> close sidebar -> verify clean window layout.
- Open sidebar -> resize window -> verify content adapts.
- Open sidebar -> switch panels via Tab -> verify all three panels render.
- Open sidebar -> edit frontmatter via metadata panel -> verify source buffer
  updated and sidebar re-renders.

## Testing

### Manual Test Cases

1. **Sidebar toggle:**
   - `<leader>vS` opens sidebar on right side.
   - `<leader>vS` again closes it.
   - Layout returns to pre-sidebar state.

2. **Panel switching:**
   - `1`/`b` shows backlinks, tab bar highlights "Backlinks".
   - `2`/`t` shows tag tree, tab bar highlights "Tags".
   - `3`/`m` shows metadata, tab bar highlights "Meta".
   - `Tab` cycles forward through panels.

3. **Backlinks auto-update:**
   - Navigate to Note A -> sidebar shows A's backlinks.
   - Navigate to Note B -> sidebar updates to B's backlinks.
   - Add `[[Note B]]` to Note C, save -> backlinks count increases.

4. **Tag tree interaction:**
   - Expand/collapse with `Space`/`l`/`h`.
   - `zo` expands all, `zc` collapses all.
   - `<CR>` on a tag opens fzf search for that tag.

5. **Metadata editing:**
   - `<CR>` on a frontmatter field opens input prompt.
   - Type new value -> field updates in source buffer.
   - Sidebar re-renders with new value.
   - `dd` on a field removes it from frontmatter.

6. **Edge cases:**
   - Open sidebar with no vault file active -> shows empty/placeholder.
   - Open sidebar during index build -> shows "(vault index not ready)".
   - Open sidebar on note with 0 backlinks -> shows "(no backlinks found)".

### Verification Checklist

- [ ] Sidebar opens on right side (default) with correct width
- [ ] Sidebar opens on left side when `config.sidebar.position = "left"`
- [ ] Tab bar renders with correct active/inactive highlighting
- [ ] Panel switching preserves scroll position (or resets appropriately)
- [ ] Backlinks panel shows file name + context line + line number
- [ ] Backlinks `<CR>` navigates to correct file and line in editor window
- [ ] Tag tree shows hierarchy with counts
- [ ] Tag tree expand/collapse persists within session
- [ ] Metadata panel shows frontmatter fields aligned with type-aware colors
- [ ] Metadata panel shows inline fields when `meta_show_inline = true`
- [ ] Metadata `<CR>` edits field and updates source buffer
- [ ] Auto-update fires on BufEnter, BufWritePost, VaultCacheInvalidate
- [ ] Debounce prevents flickering on rapid buffer switches
- [ ] Sidebar survives when other windows split/close (winfixwidth)
- [ ] `q` closes sidebar cleanly
- [ ] No errors when vault index is nil or not ready
- [ ] Highlight groups adapt to colorscheme changes
- [ ] Sidebar does not interfere with existing fzf pickers or floats
