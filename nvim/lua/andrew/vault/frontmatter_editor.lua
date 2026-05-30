local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local fm_parser = require("andrew.vault.frontmatter_parser")
local notify = require("andrew.vault.notify")
local cleanup = require("andrew.vault.resource_cleanup")
local ui = require("andrew.vault.ui")
local log = require("andrew.vault.vault_log").scope("fm_editor")

local type_utils = require("andrew.vault.frontmatter_editor.type_utils")
local field_ops = require("andrew.vault.frontmatter_editor.field_ops")
local editors = require("andrew.vault.frontmatter_editor.editors")

local M = {}

local NS = vim.api.nvim_create_namespace("vault_fm_editor")

-- Forward declarations (referenced before definition)
local resize_float

---@class FmEditorField
---@field key string
---@field value any
---@field field_type FieldType

---@class FmEditorState
---@field source_buf number    The original markdown buffer being edited
---@field float_buf number     The scratch buffer displayed in the float
---@field float_win number     The floating window handle
---@field fields FmEditorField[]
---@field cursor_idx number    1-based index into fields
---@field source_file string   Absolute path of the source buffer

---@type FmEditorState|nil
local _state = nil

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Render the editor content into the float buffer.
local function render()
  if not _state then return end

  local buf = _state.float_buf
  local fields = _state.fields

  -- First pass: compute max key width (needed before formatting lines)
  local kw = type_utils.max_key_width(fields)

  -- Clear existing extmarks
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  -- Second pass: build display lines, display values, and highlight positions
  local display_lines = {}
  local disp_values = {}
  local hl_info = {}
  for i, f in ipairs(fields) do
    local dv = type_utils.format_display_value(f.value, f.field_type)
    disp_values[i] = dv

    local padding = string.rep(" ", kw - #f.key)
    local line = "  " .. f.key .. padding .. "  :  " .. dv
    display_lines[i] = line

    local key_start = 2
    local key_end = key_start + #f.key
    local sep_pos = line:find(" : ", 1, true)
    hl_info[i] = {
      key_start = key_start,
      key_end = key_end,
      sep_pos = sep_pos,
      val_hl = type_utils.TYPE_HIGHLIGHTS[f.field_type] or "VaultFmEditorString",
      line_len = #line,
    }
  end

  -- Cache display data for float_dimensions() reuse
  _state._render_cache = { kw = kw, disp_values = disp_values }

  -- Add blank line + help text
  display_lines[#display_lines + 1] = ""
  display_lines[#display_lines + 1] = "  [Enter/l]edit  [a]dd  [dd]elete  [Tab]next  [q]uit"

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)
  vim.bo[buf].modifiable = false

  -- Apply highlights from pre-computed positions
  for i, hl in ipairs(hl_info) do
    local line_idx = i - 1

    vim.api.nvim_buf_set_extmark(buf, NS, line_idx, hl.key_start, {
      end_col = hl.key_end,
      hl_group = "VaultFmEditorKey",
    })

    if hl.sep_pos then
      vim.api.nvim_buf_set_extmark(buf, NS, line_idx, hl.sep_pos - 1, {
        end_col = hl.sep_pos + 2,
        hl_group = "VaultFmEditorSep",
      })
      vim.api.nvim_buf_set_extmark(buf, NS, line_idx, hl.sep_pos + 2, {
        end_col = hl.line_len,
        hl_group = hl.val_hl,
      })
    end

    if i == _state.cursor_idx then
      vim.api.nvim_buf_set_extmark(buf, NS, line_idx, 0, {
        end_col = 2,
        hl_group = "VaultFmEditorCursor",
        virt_text = { { ">", "VaultFmEditorCursor" } },
        virt_text_pos = "overlay",
      })
    end
  end

  -- Help line highlight
  local help_idx = #display_lines - 1
  vim.api.nvim_buf_set_extmark(buf, NS, help_idx, 0, {
    end_col = #display_lines[#display_lines],
    hl_group = "VaultFmEditorHelp",
  })

  -- Restore focus to the float window and position cursor
  if _state.float_win and vim.api.nvim_win_is_valid(_state.float_win) then
    if vim.api.nvim_get_current_win() ~= _state.float_win then
      vim.api.nvim_set_current_win(_state.float_win)
    end
    local ok, err = pcall(vim.api.nvim_win_set_cursor, _state.float_win, { _state.cursor_idx, 2 })
    if not ok then log.debug("set cursor in float: %s", err) end
  end
end

-- ---------------------------------------------------------------------------
-- Float window management
-- ---------------------------------------------------------------------------

--- Compute float dimensions based on current state.
---@return { width: number, height: number, row: number, col: number }
local function float_dimensions()
  local fields = _state and _state.fields or {}

  -- Reuse cached render data when available to avoid redundant format_display_value calls
  local cache = _state and _state._render_cache
  local kw, max_disp = 0, 0
  if cache and cache.kw and cache.disp_values and #cache.disp_values == #fields then
    kw = cache.kw
    for _, dv in ipairs(cache.disp_values) do
      if #dv > max_disp then max_disp = #dv end
    end
  else
    kw = type_utils.max_key_width(fields)
    for _, f in ipairs(fields) do
      local dlen = #type_utils.format_display_value(f.value, f.field_type)
      if dlen > max_disp then max_disp = dlen end
    end
  end
  -- line_w = 2 (indent) + kw (padded key) + 5 (" : ") + disp_len
  local max_w = math.max(46, 2 + kw + 5 + max_disp)

  return ui.centered_float_dims(
    config.frontmatter_editor.float_width_ratio,
    config.frontmatter_editor.float_height_ratio,
    { max_width = max_w + 4, content_lines = #fields }
  )
end

--- Resize the float window to fit current content.
resize_float = function()
  if not _state or not _state.float_win or not vim.api.nvim_win_is_valid(_state.float_win) then
    return
  end

  local dims = float_dimensions()
  vim.api.nvim_win_set_config(_state.float_win, {
    relative = "editor",
    width = dims.width,
    height = dims.height,
    row = dims.row,
    col = dims.col,
  })
end

--- Close the frontmatter editor float.
local function close_editor()
  if not _state then return end

  cleanup.close_win_buf(_state.float_win, _state.float_buf)

  _state = nil
end

--- Move cursor to the next field.
local function next_field()
  if not _state or #_state.fields == 0 then return end
  _state.cursor_idx = (_state.cursor_idx % #_state.fields) + 1
  render()
end

--- Move cursor to the previous field.
local function prev_field()
  if not _state or #_state.fields == 0 then return end
  _state.cursor_idx = ((_state.cursor_idx - 2) % #_state.fields) + 1
  render()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Remove a frontmatter field from the source buffer (public API for external callers).
---@param source_buf number
---@param key string
function M.delete_field(source_buf, key)
  field_ops.delete_field(source_buf, key)
end

--- Open the frontmatter editor float for the current buffer.
function M.open()
  -- Guard: only in vault markdown files
  local source_buf = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(source_buf)
  if not engine.is_vault_buf(source_buf) then
    notify.not_vault_file()
    return
  end

  -- Close existing editor if open
  if _state then
    close_editor()
  end

  -- Parse frontmatter from source buffer
  local fm = fm_parser.parse_buffer_cached(source_buf)
  if not fm then
    -- No frontmatter — offer to create one
    engine.run(function()
      local create = engine.select({ "Yes", "No" }, {
        prompt = "No frontmatter found. Create one?",
      })
      if create ~= "Yes" then return end

      local ok, err = pcall(vim.cmd, "undojoin")
      if not ok then log.debug("undojoin before frontmatter create: %s", err) end
      vim.api.nvim_buf_set_lines(source_buf, 0, 0, false, { "---", "---" })

      vim.schedule(function()
        M.open()
      end)
    end)
    return
  end

  -- Build field list from parsed frontmatter
  local fields = {}
  local raw_lines = field_ops.read_frontmatter_lines(source_buf)

  local seen_keys = {}
  for i = fm.start_line + 1, fm.end_line - 1 do
    local key = raw_lines[i]:match("^([%w_%-]+):")
    if key and not seen_keys[key] then
      seen_keys[key] = true
      local value = fm.fields[key]
      if value ~= nil then
        fields[#fields + 1] = {
          key = key,
          value = value,
          field_type = type_utils.detect_field_type(key, value),
        }
      end
    end
  end

  -- Also add any fields from fm.fields not captured by line scanning
  for key, value in pairs(fm.fields) do
    if not seen_keys[key] then
      fields[#fields + 1] = {
        key = key,
        value = value,
        field_type = type_utils.detect_field_type(key, value),
      }
    end
  end

  -- Create float buffer
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].buftype = "nofile"
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].swapfile = false
  vim.bo[float_buf].filetype = "vault_fm_editor"

  -- Initialize state before computing dimensions
  _state = {
    source_buf = source_buf,
    float_buf = float_buf,
    float_win = nil,  -- set below
    fields = fields,
    cursor_idx = 1,
    source_file = bufname,
  }

  -- Compute dimensions and open window
  -- NOTE: Direct nvim_open_win — not using ui.create_float_display() because this
  -- is an interactive editor with custom rendering, resize, and navigation logic.
  local dims = float_dimensions()
  local float_win = vim.api.nvim_open_win(float_buf, true, {
    relative = "editor",
    width = dims.width,
    height = dims.height,
    row = dims.row,
    col = dims.col,
    style = "minimal",
    border = "rounded",
    title = " Frontmatter ",
    title_pos = "center",
  })
  _state.float_win = float_win

  -- Window options
  vim.wo[float_win].cursorline = false
  vim.wo[float_win].wrap = false
  vim.wo[float_win].number = false
  vim.wo[float_win].relativenumber = false
  vim.wo[float_win].signcolumn = "no"

  -- Render initial content
  render()

  -- Set up keymaps in the float buffer
  local map_opts = { buffer = float_buf, nowait = true, silent = true }

  -- Navigation
  vim.keymap.set("n", "j", next_field, vim.tbl_extend("force", map_opts, { desc = "Next field" }))
  vim.keymap.set("n", "k", prev_field, vim.tbl_extend("force", map_opts, { desc = "Prev field" }))
  vim.keymap.set("n", "<Down>", next_field, vim.tbl_extend("force", map_opts, { desc = "Next field" }))
  vim.keymap.set("n", "<Up>", prev_field, vim.tbl_extend("force", map_opts, { desc = "Prev field" }))
  vim.keymap.set("n", "<Tab>", next_field, vim.tbl_extend("force", map_opts, { desc = "Next field" }))
  vim.keymap.set("n", "<S-Tab>", prev_field, vim.tbl_extend("force", map_opts, { desc = "Prev field" }))

  -- Edit
  vim.keymap.set("n", "<CR>", function()
    if not _state or #_state.fields == 0 then return end
    local field = _state.fields[_state.cursor_idx]
    if field then editors.edit_field(field, _state, render, resize_float) end
  end, vim.tbl_extend("force", map_opts, { desc = "Edit field" }))

  vim.keymap.set("n", "l", function()
    if not _state or #_state.fields == 0 then return end
    local field = _state.fields[_state.cursor_idx]
    if field then editors.edit_field(field, _state, render, resize_float) end
  end, vim.tbl_extend("force", map_opts, { desc = "Edit field" }))

  -- Add / Delete
  vim.keymap.set("n", "a", function()
    if not _state then return end
    editors.add_field(_state, render, resize_float)
  end, vim.tbl_extend("force", map_opts, { desc = "Add field" }))
  vim.keymap.set("n", "dd", function()
    if not _state then return end
    editors.delete_current_field(_state, render, resize_float)
  end, vim.tbl_extend("force", map_opts, { desc = "Delete field" }))

  -- Close
  vim.keymap.set("n", "q", close_editor, vim.tbl_extend("force", map_opts, { desc = "Close editor" }))
  vim.keymap.set("n", "<Esc>", close_editor, vim.tbl_extend("force", map_opts, { desc = "Close editor" }))

  -- Auto-close if the float window is somehow left
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = float_buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if _state and _state.float_buf == float_buf then
          _state = nil
        end
      end)
    end,
  })
end

--- Setup highlights and user commands.
function M.setup()
  local highlights = {
    VaultFmEditorKey     = { link = "Identifier" },
    VaultFmEditorSep     = { link = "Delimiter" },
    VaultFmEditorString  = { link = "String" },
    VaultFmEditorNumber  = { link = "Number" },
    VaultFmEditorBoolean = { link = "Boolean" },
    VaultFmEditorDate    = { link = "Special" },
    VaultFmEditorList    = { link = "Type" },
    VaultFmEditorCursor  = { link = "CursorLineNr" },
    VaultFmEditorHelp    = { link = "Comment" },
  }

  for name, def in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", def, { default = true }))
  end

  -- Commands, keymaps, and palette registrations are handled by init.lua lazy stubs
end

return M
