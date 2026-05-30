-- sidebar.lua — Persistent sidebar panel manager
-- Manages a shared vertical split with switchable panel views.

local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local cleanup = require("andrew.vault.resource_cleanup")
local watch = require("andrew.vault.watch_channel")
local log = require("andrew.vault.vault_log").scope("sidebar")

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

---@type SidebarState
local _state = {
  win = nil,
  buf = nil,
  panel = config.sidebar.default_panel,
  visible = false,
  source_win = nil,
  source_buf = nil,
}

-- Watch channel for sidebar render coalescing
local _sidebar_send, _sidebar_handle = watch.new(nil)
_sidebar_handle.subscribe(function()
  if _state.visible then
    M.render()
  end
end)

-- Panel renderers (lazy-loaded)
local _panels = {}

--- Check if the sidebar window and buffer are active and valid.
---@return boolean
local function is_sidebar_active()
  return _state.visible
    and _state.buf ~= nil
    and vim.api.nvim_buf_is_valid(_state.buf)
    and _state.win ~= nil
    and vim.api.nvim_win_is_valid(_state.win)
end

--- Focus the source (editor) window if it is still valid.
---@return boolean success
local function focus_source_win()
  if _state.source_win and vim.api.nvim_win_is_valid(_state.source_win) then
    vim.api.nvim_set_current_win(_state.source_win)
    return true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Namespace
-- ---------------------------------------------------------------------------

local NS = vim.api.nvim_create_namespace("vault_sidebar")

-- ---------------------------------------------------------------------------
-- Forward declarations
-- ---------------------------------------------------------------------------

local setup_shared_keymaps

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
  focus_source_win()

  -- Setup shared keymaps
  setup_shared_keymaps(buf)

  -- Auto-close when buffer is deleted or wiped
  cleanup.on_buf_delete_once(buf, function()
    _state.win = nil
    _state.buf = nil
    _state.visible = false
  end)

  return true
end

--- Close the sidebar.
local function close_sidebar()
  cleanup.close_win_buf(_state.win, _state.buf)
  _state.win = nil
  _state.buf = nil
  _state.visible = false
  _state.source_win = nil
  _state.source_buf = nil
end

-- ---------------------------------------------------------------------------
-- Tab bar rendering
-- ---------------------------------------------------------------------------

local PANEL_ORDER = { "backlinks", "tags", "meta" }
local PANEL_LABELS = { backlinks = "Backlinks", tags = "Tags", meta = "Meta" }
local PANEL_DESCS = { backlinks = "backlinks", tags = "tag tree", meta = "metadata" }

--- Render the tab bar at the top of the sidebar buffer.
---@param buf number
---@param active_panel string
---@return number lines_used Number of lines consumed by the tab bar
local function render_tab_bar(buf, active_panel)
  local parts = {}
  for _, name in ipairs(PANEL_ORDER) do
    parts[#parts + 1] = " " .. PANEL_LABELS[name] .. " "
  end
  local tab_line = table.concat(parts, "|")
  local sep_line = string.rep("\u{2500}", config.sidebar.width)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { tab_line, sep_line })

  -- Highlight active/inactive tabs
  local col = 0
  for _, name in ipairs(PANEL_ORDER) do
    local label = " " .. PANEL_LABELS[name] .. " "
    local hl = name == active_panel and "VaultSidebarTabActive" or "VaultSidebarTabInactive"
    local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, NS, 0, col, {
      end_col = col + #label,
      hl_group = hl,
    })
    if not ok then log.debug("extmark failed at row 0: %s", err) end
    col = col + #label + 1 -- +1 for the "|" separator
  end

  -- Separator highlight
  local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, NS, 1, 0, {
    end_col = #sep_line,
    hl_group = "VaultSidebarSep",
  })
  if not ok then log.debug("extmark failed at row 1: %s", err) end

  return 2 -- tab bar + separator
end

-- ---------------------------------------------------------------------------
-- Render dispatch
-- ---------------------------------------------------------------------------

--- Re-render the active panel into the sidebar buffer.
function M.render()
  if not is_sidebar_active() then return end

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
  panel.render(_state.buf, width, source_buf, header_lines, NS)

  -- Lock buffer again
  vim.bo[_state.buf].modifiable = false

  -- Setup panel-specific keymaps (idempotent)
  panel.setup_keymaps(_state.buf, _state.source_win)
end

--- Schedule a coalesced render (fires on next event loop tick).
local function schedule_render()
  if not _state.visible then return end
  _sidebar_send(true)
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

  -- Return focus to editor (without closing)
  vim.keymap.set("n", "<Esc>", function()
    focus_source_win()
  end, vim.tbl_extend("force", opts, { desc = "Return focus to editor" }))

  -- Switch panels: number keys (1/2/3) and letter shortcuts (b/t/m)
  for i, name in ipairs(PANEL_ORDER) do
    local desc = "Switch to " .. PANEL_DESCS[name] .. " panel"
    local switch = function() M.switch_panel(name) end
    vim.keymap.set("n", tostring(i), switch, vim.tbl_extend("force", opts, { desc = desc }))
    vim.keymap.set("n", name:sub(1, 1), switch, vim.tbl_extend("force", opts, { desc = desc }))
  end

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
    M.render()
  end, vim.tbl_extend("force", opts, { desc = "Force refresh" }))

  -- Help
  vim.keymap.set("n", "?", function()
    local help = {
      "Sidebar Keybindings:",
      "",
      "  q          Close sidebar",
      "  <Esc>      Return focus to editor",
      "  1 / b      Backlinks panel",
      "  2 / t      Tag tree panel",
      "  3 / m      Metadata panel",
      "  Tab        Next panel",
      "  S-Tab      Previous panel",
      "  R          Force refresh",
      "  ?          This help",
      "",
      "Global:  <leader>vSf  Toggle sidebar focus",
      "",
      "Panel-specific keys shown in each panel.",
    }
    notify.info_lines(help)
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
    notify.error("failed to create sidebar")
    return
  end

  M.render()
end

--- Switch to a different panel.
---@param panel string
function M.switch_panel(panel)
  if not _panels[panel] then
    notify.warn("unknown panel '" .. panel .. "'")
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

--- Toggle focus between the sidebar and the source (editor) window.
--- If the sidebar is not visible, open it first (focus stays on editor).
--- If focus is currently on the sidebar, return to source window.
--- If focus is on the editor, move to the sidebar.
function M.focus_toggle()
  if not M.is_visible() then
    M.open()
    return
  end

  local cur_win = vim.api.nvim_get_current_win()

  if cur_win == _state.win then
    -- Currently in sidebar → return to source window
    focus_source_win()
  else
    -- Currently in editor → focus sidebar
    _state.source_win = cur_win
    _state.source_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_win(_state.win)
  end
end

-- ---------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------

--- Update the sidebar when the active buffer changes or a file is saved.
local function on_buf_change(ev)
  if not is_sidebar_active() then return end

  -- Ignore events from the sidebar buffer itself
  if ev.buf == _state.buf then return end

  -- Only update for vault markdown files
  local bufname = vim.api.nvim_buf_get_name(ev.buf)
  if not vim.endswith(bufname, ".md") then return end
  if not engine.is_vault_buf(ev.buf) then return end

  -- Track the new source buffer
  _state.source_buf = ev.buf
  _state.source_win = vim.api.nvim_get_current_win()

  schedule_render()
end

--- Called by event_dispatch.lua on BufEnter for vault markdown buffers.
--- @param ctx { bufnr: number, file: string, is_vault_md: boolean }
function M.on_buf_enter(ctx)
  on_buf_change({ buf = ctx.bufnr })
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local group = vim.api.nvim_create_augroup("VaultSidebar", { clear = true })

  -- BufEnter autocmd removed: now dispatched via event_dispatch.lua

  -- Subscribe to vault index updates for live refresh (covers BufWritePost
  -- via centralized cache invalidation in init.lua)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VaultCacheInvalidate",
    callback = function(_ev)
      -- Sidebar always refreshes regardless of scope (files/file/all)
      -- because sidebar content may depend on any changed file's metadata
      if _state.visible then
        schedule_render()
      end
    end,
  })

end

return M
