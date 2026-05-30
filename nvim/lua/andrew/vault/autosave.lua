local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local cleanup = require("andrew.vault.resource_cleanup")
local notify = require("andrew.vault.notify")

local M = {}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- Whether auto-save is currently active.
---@type boolean
local _enabled = false

--- Per-buffer debounce timers.
--- Keyed by buffer number to allow independent debounce per buffer.
---@type table<number, uv_timer_t>
local _timers = {}

--- Augroup ID (nil when not active).
---@type number|nil
local _augroup = nil

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------

--- Check whether a buffer should be auto-saved.
---@param bufnr number
---@return boolean
local function should_save(bufnr)
  -- Buffer must be valid and loaded
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if not vim.api.nvim_buf_is_loaded(bufnr) then return false end

  -- Must have unsaved changes
  if not vim.bo[bufnr].modified then return false end

  -- Must be modifiable and not readonly
  if not vim.bo[bufnr].modifiable then return false end
  if vim.bo[bufnr].readonly then return false end

  -- Must be a normal buffer (not terminal, prompt, nofile, etc.)
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" then return false end

  -- Must be a markdown file
  if vim.bo[bufnr].filetype ~= "markdown" then return false end

  -- Must have a file name (not a scratch buffer)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then return false end

  -- Must be inside a vault path
  if not engine.is_vault_buf(bufnr) then return false end

  return true
end

-- ---------------------------------------------------------------------------
-- Core save logic
-- ---------------------------------------------------------------------------

--- Save a single buffer if it passes all guards.
---@param bufnr number
local function save_buffer(bufnr)
  if not should_save(bufnr) then return end

  -- Use nvim_buf_call to ensure the update targets the correct buffer,
  -- even if the current buffer has changed since the timer fired.
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent! update")
  end)
end

--- Schedule a debounced save for the given buffer.
---@param bufnr number
local function schedule_save(bufnr)
  if not _enabled then return end
  if not should_save(bufnr) then return end

  local debounce_ms = config.autosave.debounce_ms

  -- Debounce: close any existing timer, create a new one
  _timers[bufnr] = cleanup.debounce(_timers[bufnr], debounce_ms, function()
    _timers[bufnr] = nil
    save_buffer(bufnr)
  end)
end

-- ---------------------------------------------------------------------------
-- Autocmd management
-- ---------------------------------------------------------------------------

--- Create the autocmds that trigger auto-save.
local function create_autocmds()
  if _augroup then return end

  _augroup = vim.api.nvim_create_augroup("VaultAutoSave", { clear = true })

  local events = config.autosave.events

  -- Buffer-specific events (BufLeave, WinLeave): save the buffer being left
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = _augroup,
    pattern = "*.md",
    callback = function(ev)
      schedule_save(ev.buf)
    end,
  })

  -- FocusLost: save ALL modified vault markdown buffers (user left Neovim)
  if vim.tbl_contains(events, "FocusLost") then
    vim.api.nvim_create_autocmd("FocusLost", {
      group = _augroup,
      callback = function()
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if should_save(bufnr) then
            -- On FocusLost, save immediately (no debounce) since the user
            -- has left the editor entirely
            save_buffer(bufnr)
          end
        end
      end,
    })
  end
end

--- Remove autocmds and clean up timers.
local function remove_autocmds()
  if _augroup then
    cleanup.close_augroup(_augroup)
    _augroup = nil
  end

  -- Stop and close all pending timers
  for bufnr, _ in pairs(_timers) do
    cleanup.close_timer_in(_timers, bufnr)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Enable auto-save.
function M.enable()
  _enabled = true
  create_autocmds()
end

--- Disable auto-save.
function M.disable()
  _enabled = false
  remove_autocmds()
end

--- Toggle auto-save on/off.
---@return boolean new_state
function M.toggle()
  if _enabled then
    M.disable()
  else
    M.enable()
  end
  notify.toggle("auto-save", _enabled)
  return _enabled
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local palette = require("andrew.vault.command_palette")

  -- Register the toggle command
  vim.api.nvim_create_user_command("VaultAutoSave", function()
    M.toggle()
  end, { desc = "Toggle vault auto-save on focus loss" })

  -- Keymap: <leader>vW to toggle (W = Write/auto-save)
  vim.keymap.set("n", "<leader>vW", function()
    M.toggle()
  end, { desc = "Vault: toggle auto-save", silent = true })

  -- Enable by default if config says so
  if config.autosave.enabled then
    M.enable()
  end

  -- Clean up timers for deleted buffers to prevent leaks.
  -- Uses a separate augroup from _augroup so it persists across enable/disable.
  local cleanup_group = vim.api.nvim_create_augroup("VaultAutoSaveCleanup", { clear = true })
  cleanup.on_buf_delete(cleanup_group, function(bufnr) cleanup.close_timer_in(_timers, bufnr) end)

  -- VimLeavePre autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  palette.register_command("VaultAutoSave", "Toggle vault auto-save on focus loss", "Meta", function()
    M.toggle()
  end, "<leader>vW")
end

--- Called by event_dispatch.lua on VimLeavePre for cleanup.
function M.teardown()
  for bufnr, _ in pairs(_timers) do
    cleanup.close_timer_in(_timers, bufnr)
  end
end

-- Deferred profiler registration (safe: profiler may not be loaded yet)
do
  local ok, profiler = pcall(require, "andrew.vault.memory_profiler")
  if ok then
    profiler.register_counter_deferred({
      name = "autosave_timers",
      get_count = function()
        local n = 0
        for _ in pairs(_timers) do n = n + 1 end
        return n
      end,
      description = "autosave per-buffer debounce timers",
    })
  end
end

return M
