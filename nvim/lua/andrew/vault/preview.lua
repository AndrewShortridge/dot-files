local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")
local ui = require("andrew.vault.ui")
local cleanup = require("andrew.vault.resource_cleanup")
local guard = require("andrew.vault.guard")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("preview")
local text_utils = require("andrew.vault.text_utils")

local history = require("andrew.vault.preview.history")
local breadcrumb = require("andrew.vault.preview.breadcrumb")
local target_mod = require("andrew.vault.preview.target")
local edit_float = require("andrew.vault.preview.edit_float")

local M = {}

-- Pre-compute terminal keycodes for scrolling
local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
local ctrl_y = vim.api.nvim_replace_termcodes("<C-y>", true, false, true)

-- ---------------------------------------------------------------------------
-- Active Preview State
-- ---------------------------------------------------------------------------

local state = {
  win = nil,
  buf = nil,
  parent_buf = nil,
  augroup = nil,
  focused = false,
  _markdown_rendered = false,  -- treesitter + render-markdown already set up
  _focus_keymaps_set = false,  -- focus-mode keymaps already registered
  _scroll_keymaps_set = false, -- scroll keymaps already registered
  _scroll_keymaps_buf = nil,   -- buffer scroll keymaps were set on
  _history_keymaps_set = false, -- history keymaps already registered
  _history_keymaps_buf = nil,   -- buffer history keymaps were set on
  _cr_keymap_set = false,       -- <CR> keymap on parent already registered
  _cr_keymap_buf = nil,         -- buffer <CR> keymap was set on
}

-- ---------------------------------------------------------------------------
-- Float Helpers
-- ---------------------------------------------------------------------------

--- Check if a preview is currently active (window AND buffer are valid).
local function is_active()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return false
  end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end
  return true
end

--- Scroll the preview window by delta lines.
---@param delta number positive = down, negative = up
local function scroll_preview(delta)
  if not is_active() then
    return
  end
  local count = math.abs(delta)
  local key = delta > 0 and ctrl_e or ctrl_y
  vim.fn.win_execute(state.win, "normal! " .. count .. key)
end

--- Compute float dimensions from content lines.
---@param lines string[]
---@return number width, number height
local function compute_float_dims(lines)
  local max_width = config.preview.max_width
  local max_height = config.preview.max_lines
  local width = math.min(math.max(text_utils.max_display_width(lines), config.preview.min_width), max_width)
  local height = math.min(#lines, max_height)
  return width, height
end

--- Setup markdown rendering on the preview buffer/window.
--- Treesitter + filetype only need to be started once per buffer;
--- render-markdown is called each time content changes.
local function setup_markdown_rendering()
  if not is_active() then return end
  if not state._markdown_rendered then
    -- First call: full setup (filetype, treesitter, render-markdown)
    ui.setup_and_render_markdown(state.buf, state.win)
    state._markdown_rendered = true
  else
    -- Subsequent calls: only re-render markdown (treesitter already started)
    local ok, rm = pcall(require, "render-markdown")
    if ok and rm and rm.render then
      rm.render({ buf = state.buf, win = state.win })
    end
  end
end

--- Set up C-j/C-k scroll keymaps on a buffer.
---@param buf number  Buffer to set keymaps on
local function setup_scroll_keymaps(buf)
  if state._scroll_keymaps_set and state._scroll_keymaps_buf == buf then return end
  state._scroll_keymaps_set = true
  state._scroll_keymaps_buf = buf
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<C-j>", function()
    scroll_preview(config.preview.scroll_lines)
  end, vim.tbl_extend("force", opts, { desc = "Scroll preview down" }))
  vim.keymap.set("n", "<C-k>", function()
    scroll_preview(-config.preview.scroll_lines)
  end, vim.tbl_extend("force", opts, { desc = "Scroll preview up" }))
end

-- Forward declarations for circular references
local close_preview
local focus_preview
local unfocus_preview

-- ---------------------------------------------------------------------------
-- Float Content Management
-- ---------------------------------------------------------------------------

--- Update only the float title (breadcrumb + history position).
---@param target PreviewTarget
local function update_float_title(target)
  if not is_active() then return end

  local float_width = vim.api.nvim_win_get_width(state.win)
  local max_title_w = float_width - 4

  local chunks = breadcrumb.format(target, history.position())
  chunks = breadcrumb.truncate(chunks, max_title_w)

  vim.api.nvim_win_set_config(state.win, {
    title = chunks,
    title_pos = "center",
  })
end

--- Replace the content of the active preview float with a new target.
---@param target PreviewTarget
local function replace_float_content(target)
  if not is_active() then return end
  if not vim.api.nvim_buf_is_valid(state.buf) then
    close_preview()
    return
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, target.lines)

  local width, height = compute_float_dims(target.lines)

  vim.api.nvim_win_set_config(state.win, {
    width = width,
    height = height,
  })

  update_float_title(target)
  setup_markdown_rendering()

  vim.bo[state.buf].modifiable = false
end

-- ---------------------------------------------------------------------------
-- Nested Navigation
-- ---------------------------------------------------------------------------

--- Follow a link detected inside the preview float.
---@param details { name: string, heading: string|nil, block_id: string|nil }
local function navigate_in_preview(details)
  local new_target = target_mod.resolve_in_preview(details, history.current(), state.parent_buf or 0)
  if not new_target then
    notify.warn("cannot resolve link in preview")
    return
  end

  history.push(new_target)
  replace_float_content(new_target)
end

--- Return focus from the preview float to the parent window.
unfocus_preview = function()
  if not state.focused then return end
  state.focused = false
  if is_active() then
    vim.wo[state.win].cursorline = false
  end

  local parent_win = vim.fn.bufwinid(state.parent_buf or 0)
  if parent_win ~= -1 then
    vim.api.nvim_set_current_win(parent_win)
  end
end

--- Set up C-o/C-i/BS history keymaps on a buffer.
---@param buf number  Buffer to set keymaps on
---@param notify_on_boundary boolean  Show notification when at beginning/end of history
local function setup_history_keymaps(buf, notify_on_boundary)
  if state._history_keymaps_set and state._history_keymaps_buf == buf then return end
  state._history_keymaps_set = true
  state._history_keymaps_buf = buf

  local keymap_opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "<C-o>", function()
    if not is_active() then return end
    local target = history.pop_back()
    if target then
      replace_float_content(target)
    elseif notify_on_boundary then
      notify.info("beginning of history")
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Preview: history back" }))

  vim.keymap.set("n", "<C-i>", function()
    if not is_active() then return end
    local target = history.pop_forward()
    if target then
      replace_float_content(target)
    elseif notify_on_boundary then
      notify.info("end of history")
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Preview: history forward" }))

  vim.keymap.set("n", "<BS>", function()
    if not is_active() then return end
    local target = history.pop_back()
    if target then
      replace_float_content(target)
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Preview: history back" }))
end

--- Focus the preview float for nested navigation.
focus_preview = function()
  if not is_active() then return end

  state.focused = true
  vim.api.nvim_set_current_win(state.win)
  vim.wo[state.win].cursorline = true

  -- Only register keymaps once per buffer lifetime
  if state._focus_keymaps_set then return end
  state._focus_keymaps_set = true

  local buf = state.buf
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Follow wikilink under cursor within the preview
  local function follow_link(verbose)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local details = link_utils.get_wikilink_in_buf(buf, state.win)
    if not details then
      if verbose then notify.info("no wikilink under cursor in preview") end
      return
    end
    navigate_in_preview(details)
  end

  vim.keymap.set("n", "gf", function() follow_link(true) end,
    vim.tbl_extend("force", opts, { desc = "Preview: follow link" }))
  vim.keymap.set("n", "K", function() follow_link(false) end,
    vim.tbl_extend("force", opts, { desc = "Preview: follow link" }))

  -- q or <C-h>: return focus to parent
  vim.keymap.set("n", "q", function()
    unfocus_preview()
  end, vim.tbl_extend("force", opts, { desc = "Preview: return to parent" }))

  vim.keymap.set("n", "<C-h>", function()
    unfocus_preview()
  end, vim.tbl_extend("force", opts, { desc = "Preview: return to parent" }))

  -- History navigation (no boundary notifications in focused mode)
  setup_history_keymaps(buf, false)

  -- Scroll keymaps (shared helper)
  setup_scroll_keymaps(buf)
end

--- Set up keymaps on the parent buffer for history navigation.
---@param parent_buf number
local function setup_nested_keymaps(parent_buf)
  if not config.preview.nested_preview then return end
  setup_history_keymaps(parent_buf, true)
end

-- ---------------------------------------------------------------------------
-- Close / Cleanup
-- ---------------------------------------------------------------------------

--- Close the active preview and clean up keymaps/autocmds.
close_preview = function()
  if state.win == nil then
    return
  end

  if state.focused then
    unfocus_preview()
  end

  -- Clean up parent buffer keymaps.
  if state.parent_buf and vim.api.nvim_buf_is_valid(state.parent_buf) then
    for _, key in ipairs({ "<C-j>", "<C-k>", "<C-o>", "<C-i>", "<BS>", "<CR>" }) do
      local ok, err = pcall(vim.keymap.del, "n", key, { buffer = state.parent_buf })
      if not ok then log.debug("keymap.del %s failed: %s", key, err) end
    end
  end

  if state.augroup then
    cleanup.close_augroup(state.augroup)
    state.augroup = nil
  end

  -- Close the window but keep the buffer for reuse
  cleanup.close_win(state.win)

  state.win = nil
  -- Keep state.buf alive for reuse (buffer persists across previews)
  state.parent_buf = nil
  state.focused = false
  -- Reset parent-buffer keymap flags (keymaps were deleted above)
  state._history_keymaps_set = false
  state._history_keymaps_buf = nil
  state._scroll_keymaps_set = false
  state._scroll_keymaps_buf = nil
  state._cr_keymap_set = false
  state._cr_keymap_buf = nil
  -- Keep _markdown_rendered and _focus_keymaps_set — they track per-buffer state

  history.clear()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Show a floating preview of the note linked under the cursor.
function M.preview()
  -- Toggle off if already showing
  if is_active() then
    close_preview()
    return
  end

  local details = link_utils.get_wikilink_under_cursor()
  if not details then
    -- Try footnote preview as fallback
    local footnotes = require("andrew.vault.footnotes")
    if footnotes.preview_footnote() then
      return
    end
    notify.info("no wikilink or footnote under cursor")
    return
  end

  local parent_buf = vim.api.nvim_get_current_buf()
  local target = target_mod.resolve(details, parent_buf)
  if not target then
    notify.info("no wikilink under cursor")
    return
  end

  -- Initialize history with this target
  history.clear()
  history.max_size = config.preview.history_max
  history.push(target)

  -- Compute float dimensions
  local width, height = compute_float_dims(target.lines)

  -- Build breadcrumb title
  local title_chunks = breadcrumb.format(target, history.position())
  title_chunks = breadcrumb.truncate(title_chunks, width - 4)

  -- Use multi-guard for atomic cleanup: if any step after window creation fails,
  -- all prior resources are cleaned up automatically (defense-in-depth).
  local mg = guard.multi()
  local ok, err = mg:run(function(g)
    -- Reuse existing buffer if valid, otherwise create a new one
    local buf
    local new_buf = false
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      buf = state.buf
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, target.lines)
    else
      buf = vim.api.nvim_create_buf(false, true)
      new_buf = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, target.lines)
      state._markdown_rendered = false
      state._focus_keymaps_set = false
      state._scroll_keymaps_set = false
      state._scroll_keymaps_buf = nil
      state._history_keymaps_set = false
      state._history_keymaps_buf = nil
      state._cr_keymap_set = false
      state._cr_keymap_buf = nil
    end
    vim.bo[buf].bufhidden = "hide"
    if new_buf then
      g:add(function() cleanup.delete_buf(buf) end, "preview_buf")
    end

    -- Open floating window near cursor (not focused)
    -- NOTE: Direct nvim_open_win — not using ui.create_float_display() because this
    -- reuses a persistent buffer across previews and has complex state management.
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "cursor",
      row = 1,
      col = 0,
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = title_chunks,
      title_pos = "center",
    })
    g:add(function() cleanup.close_win(win) end, "preview_win")

    -- Window options (shared markdown float setup)
    ui.setup_markdown_float_opts(win)

    -- Markdown rendering + lock buffer
    setup_markdown_rendering()
    vim.bo[buf].modifiable = false

    -- Scroll keymaps on parent buffer (shared helper)
    setup_scroll_keymaps(parent_buf)

    -- Focus keymap: <CR> on parent enters the preview float
    if config.preview.nested_preview and not (state._cr_keymap_set and state._cr_keymap_buf == parent_buf) then
      state._cr_keymap_set = true
      state._cr_keymap_buf = parent_buf
      vim.keymap.set("n", "<CR>", function()
        if is_active() then
          focus_preview()
        end
      end, { buffer = parent_buf, nowait = true, silent = true, desc = "Preview: enter float" })
    end

    -- History navigation keymaps on parent buffer
    setup_nested_keymaps(parent_buf)

    -- Auto-close on cursor move, leaving the buffer, or external window close.
    local augroup = vim.api.nvim_create_augroup("VaultPreviewClose", { clear = true })
    g:add(function() cleanup.close_augroup(augroup) end, "preview_augroup")

    vim.api.nvim_create_autocmd("CursorMoved", {
      group = augroup,
      buffer = parent_buf,
      callback = function()
        if state.focused then return end
        close_preview()
      end,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
      group = augroup,
      buffer = parent_buf,
      callback = function()
        if state.focused then return end
        close_preview()
      end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(win),
      callback = function()
        close_preview()
      end,
    })

    -- All setup succeeded: transfer ownership to state + autocmds, dismiss guards
    state.win = win
    state.buf = buf
    state.parent_buf = parent_buf
    state.focused = false
    state.augroup = augroup
    g:dismiss_all()
  end)

  if not ok then log.error("Preview open failed: %s", err) end
end

--- Open the linked note under the cursor in an editable floating window.
function M.edit_link()
  edit_float.edit_link()
end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "K", function()
    M.preview()
  end, { buffer = ev.buf, desc = "Vault: preview link", silent = true })
  vim.keymap.set("n", "<leader>vE", function()
    M.edit_link()
  end, { buffer = ev.buf, desc = "Vault: edit link in float", silent = true })
end

function M.setup()
  vim.api.nvim_create_user_command("VaultPreview", function()
    M.preview()
  end, { desc = "Vault: preview wikilink under cursor" })

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  local palette = require("andrew.vault.command_palette")

  palette.register_command("VaultPreview", "Vault: preview wikilink under cursor", "Navigate", M.preview, "K")
  palette.register_keymap("<leader>vE", "Vault: edit link in float", "Navigate", M.edit_link, true)
end

return M
