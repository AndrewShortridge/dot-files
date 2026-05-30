-- sidebar_meta.lua — Metadata panel for the vault sidebar
-- Shows frontmatter fields + inline fields for the current note.
-- Supports inline editing via delegating to existing metaedit/frontmatter_editor.

local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")
local vault_index = require("andrew.vault.vault_index")
local fm_parser = require("andrew.vault.frontmatter_parser")
local link_utils = require("andrew.vault.link_utils")
local log = require("andrew.vault.vault_log").scope("sidebar_meta")
local type_utils = require("andrew.vault.frontmatter_editor.type_utils")

local M = {}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

---@type table<number, { section: string, key: string, value: any, field_type: string, source_buf: number, row: number|nil }>
local _line_actions = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local detect_field_type = type_utils.detect_field_type
local format_value = type_utils.format_display_value

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
---@param width number
---@param source_buf number
---@param start_line number
---@param ns number
function M.render(buf, width, source_buf, start_line, ns)
  _line_actions = {}

  local bufname = vim.api.nvim_buf_get_name(source_buf)
  local lines = {}
  local highlights = {}

  -- Note name header
  local note_name = link_utils.get_basename(bufname)
  local header = " " .. note_name
  lines[#lines + 1] = header
  highlights[#highlights + 1] = { 0, 0, #header, "VaultSidebarHeader" }

  -- ─────────────────── Frontmatter section ───────────────────
  lines[#lines + 1] = ""
  local fm_header = " Frontmatter"
  local fm_header_idx = #lines
  lines[#lines + 1] = fm_header
  highlights[#highlights + 1] = { fm_header_idx, 0, #fm_header, "VaultSidebarHeader" }

  local fm = fm_parser.parse_buffer_cached(source_buf)
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
      if raw_lines[i] then
        local key = raw_lines[i]:match(pat.FM_KEY_PREFIX)
        if key and not seen[key] and fm.fields[key] ~= nil then
          seen[key] = true
          ordered_keys[#ordered_keys + 1] = key
        end
      end
    end
    -- Catch any keys not found by line scanning
    for key in pairs(fm.fields) do
      if not seen[key] then
        ordered_keys[#ordered_keys + 1] = key
      end
    end

    -- Find max key width for alignment
    local max_kw = type_utils.max_key_width(ordered_keys)

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

  if entry and entry.tags and #entry.tags > 0 then
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

    local ok, inline_fields_mod = pcall(require, "andrew.vault.inline_fields")
    local fields = ok and inline_fields_mod.get_buffer_fields(source_buf) or {}

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

      local max_kw = type_utils.max_key_width(key_order)

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
    local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
    if not ok then log.debug("extmark failed at row %d: %s", row, err) end
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
          local ok, err = pcall(vim.api.nvim_win_set_cursor, source_win, { action.row + 1, 0 })
          if not ok then log.debug("set_cursor failed: %s", err) end
        end
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "Edit field" }))

  -- a: add a new frontmatter field (delegates to frontmatter_editor add flow)
  vim.keymap.set("n", "a", function()
    require("andrew.vault.frontmatter_editor").open()
  end, vim.tbl_extend("force", opts, { desc = "Add field (open editor)" }))

  -- dd: delete frontmatter field under cursor
  vim.keymap.set("n", "dd", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local action = _line_actions[cursor[1]]
    if not action or action.section ~= "frontmatter" then
      notify.warn("can only delete frontmatter fields")
      return
    end

    vim.ui.select({ "Yes", "No" }, {
      prompt = "Delete '" .. action.key .. "'?",
    }, function(choice)
      if choice ~= "Yes" then return end
      require("andrew.vault.frontmatter_editor").delete_field(action.source_buf, action.key)
      vim.schedule(function()
        require("andrew.vault.sidebar").render()
      end)
    end)
  end, vim.tbl_extend("force", opts, { desc = "Delete field" }))
end

return M
