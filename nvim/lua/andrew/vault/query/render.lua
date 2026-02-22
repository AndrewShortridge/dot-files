local M = {}

local ns = vim.api.nvim_create_namespace("vault_query")

-- =============================================================================
-- Highlight groups
-- =============================================================================

function M.setup_highlights()
  local set = vim.api.nvim_set_hl
  set(0, "VaultQueryBorder", { fg = "#c678dd", default = true })
  set(0, "VaultQueryHeader", { link = "@markup.heading", default = true })
  set(0, "VaultQueryValue", { link = "Normal", default = true })
  set(0, "VaultQueryNull", { link = "Comment", default = true })
  set(0, "VaultQueryError", { link = "DiagnosticError", default = true })
  set(0, "VaultQueryTaskDone", { link = "Comment", default = true })
  set(0, "VaultQueryTaskOpen", { link = "Normal", default = true })
  set(0, "VaultQuerySep", { fg = "#c678dd", default = true })
  set(0, "VaultQueryGroupHeader", { link = "Title", default = true })
end

M.setup_highlights()

-- =============================================================================
-- Helpers
-- =============================================================================

--- Convert any value to a display string.
---@param val any
---@return string
local function to_str(val)
  if val == nil then
    return "\u{2014}" -- em dash
  end
  return tostring(val)
end

--- Truncate a string to max_len, adding ellipsis if needed.
---@param s string
---@param max_len number
---@return string
local function truncate(s, max_len)
  if #s <= max_len then
    return s
  end
  return s:sub(1, max_len - 1) .. "\u{2026}"
end

--- Measure display width (accounts for unicode).
---@param s string
---@return number
local function display_width(s)
  return vim.fn.strdisplaywidth(s)
end

--- Pad string to width with spaces.
---@param s string
---@param width number
---@return string
local function pad(s, width)
  local current = display_width(s)
  if current >= width then
    return s
  end
  return s .. string.rep(" ", width - current)
end

-- =============================================================================
-- Table rendering
-- =============================================================================

--- Render a table result as virtual lines.
---@param item table { type="table", headers={}, rows={{},..}, group=string|nil }
---@return table[] virt_lines
local function render_table(item)
  local headers = item.headers or {}
  local rows = item.rows or {}
  local lines = {}
  local max_cell = 60

  if #headers == 0 and #rows == 0 then
    return { { { "  (empty table)", "VaultQueryNull" } } }
  end

  -- Convert all values to strings and measure column widths
  local str_headers = {}
  for i, h in ipairs(headers) do
    str_headers[i] = truncate(to_str(h), max_cell)
  end

  local str_rows = {}
  for _, row in ipairs(rows) do
    local sr = {}
    for i = 1, #headers do
      sr[i] = truncate(to_str(row[i]), max_cell)
    end
    str_rows[#str_rows + 1] = sr
  end

  -- Calculate column widths
  local widths = {}
  for i, h in ipairs(str_headers) do
    widths[i] = display_width(h)
  end
  for _, row in ipairs(str_rows) do
    for i, cell in ipairs(row) do
      local w = display_width(cell)
      if w > (widths[i] or 0) then
        widths[i] = w
      end
    end
  end

  -- Build box-drawing table
  -- Top border
  local top_parts = {}
  for i, w in ipairs(widths) do
    top_parts[i] = string.rep("\u{2500}", w + 2)
  end
  lines[#lines + 1] = {
    { "  \u{256D}" .. table.concat(top_parts, "\u{252C}") .. "\u{256E}", "VaultQueryBorder" },
  }

  -- Header row
  local hdr_parts = {}
  for i, h in ipairs(str_headers) do
    hdr_parts[i] = " " .. pad(h, widths[i]) .. " "
  end
  lines[#lines + 1] = {
    { "  \u{2502}", "VaultQueryBorder" },
    { table.concat(hdr_parts, "\u{2502}"), "VaultQueryHeader" },
    { "\u{2502}", "VaultQueryBorder" },
  }

  -- Separator
  local sep_parts = {}
  for i, w in ipairs(widths) do
    sep_parts[i] = string.rep("\u{2500}", w + 2)
  end
  lines[#lines + 1] = {
    { "  \u{251C}" .. table.concat(sep_parts, "\u{253C}") .. "\u{2524}", "VaultQueryBorder" },
  }

  -- Data rows
  for _, row in ipairs(str_rows) do
    local cell_parts = {}
    for i = 1, #widths do
      local cell = row[i] or "\u{2014}"
      local hl = (cell == "\u{2014}") and "VaultQueryNull" or "VaultQueryValue"
      cell_parts[#cell_parts + 1] = { "\u{2502}", "VaultQueryBorder" }
      cell_parts[#cell_parts + 1] = { " " .. pad(cell, widths[i]) .. " ", hl }
    end
    cell_parts[#cell_parts + 1] = { "\u{2502}", "VaultQueryBorder" }

    local line = { { "  ", "" } }
    for _, part in ipairs(cell_parts) do
      line[#line + 1] = part
    end
    lines[#lines + 1] = line
  end

  -- Bottom border
  local bot_parts = {}
  for i, w in ipairs(widths) do
    bot_parts[i] = string.rep("\u{2500}", w + 2)
  end
  lines[#lines + 1] = {
    { "  \u{2570}" .. table.concat(bot_parts, "\u{2534}") .. "\u{256F}", "VaultQueryBorder" },
  }

  return lines
end

-- =============================================================================
-- List rendering
-- =============================================================================

---@param item table { type="list", items={}, group=string|nil }
---@return table[] virt_lines
local function render_list(item)
  local items = item.items or {}
  local lines = {}

  if #items == 0 then
    return { { { "  (empty list)", "VaultQueryNull" } } }
  end

  for _, v in ipairs(items) do
    local text = to_str(v)
    lines[#lines + 1] = {
      { "  \u{2022} ", "VaultQueryBorder" },
      { text, "VaultQueryValue" },
    }
  end

  return lines
end

-- =============================================================================
-- Paragraph rendering
-- =============================================================================

---@param item table { type="paragraph", text=string }
---@return table[] virt_lines
local function render_paragraph(item)
  local text = item.text or ""
  -- Strip HTML tags (progress bars etc. from Dataview)
  text = text:gsub("<[^>]+>", "")
  -- Strip markdown bold/italic for cleaner display
  text = text:gsub("%*%*(.-)%*%*", "%1")
  text = text:gsub("%*(.-)%*", "%1")

  local lines = {}
  -- Wrap at 80 chars
  local max_width = 80
  while #text > 0 do
    if #text <= max_width then
      lines[#lines + 1] = { { "  " .. text, "VaultQueryValue" } }
      break
    end
    local wrap_at = text:sub(1, max_width):match(".*()%s") or max_width
    lines[#lines + 1] = { { "  " .. text:sub(1, wrap_at), "VaultQueryValue" } }
    text = text:sub(wrap_at + 1):gsub("^%s+", "")
  end

  return lines
end

-- =============================================================================
-- Header rendering
-- =============================================================================

---@param item table { type="header", level=number, text=string }
---@return table[] virt_lines
local function render_header(item)
  local prefix = string.rep("#", item.level or 3) .. " "
  return {
    { { "  " .. prefix .. (item.text or ""), "VaultQueryGroupHeader" } },
  }
end

-- =============================================================================
-- Task list rendering
-- =============================================================================

---@param item table { type="task_list", groups={{name=string, tasks={{text=string, completed=bool}}}} }
---@return table[] virt_lines
local function render_task_list(item)
  local groups = item.groups or {}
  local lines = {}

  if #groups == 0 then
    return { { { "  (no tasks)", "VaultQueryNull" } } }
  end

  for _, group in ipairs(groups) do
    -- Group name
    lines[#lines + 1] = {
      { "  " .. (group.name or ""), "VaultQueryGroupHeader" },
    }
    -- Tasks
    for _, task in ipairs(group.tasks or {}) do
      if task.completed then
        lines[#lines + 1] = {
          { "    \u{2713} ", "VaultQueryTaskDone" },
          { task.text or "", "VaultQueryTaskDone" },
        }
      else
        lines[#lines + 1] = {
          { "    \u{25CB} ", "VaultQueryBorder" },
          { task.text or "", "VaultQueryTaskOpen" },
        }
      end
    end
  end

  return lines
end

-- =============================================================================
-- Error rendering
-- =============================================================================

---@param item table { type="error", message=string }
---@return table[] virt_lines
local function render_error(item)
  return {
    { { "  \u{2717} Error: " .. (item.message or "unknown"), "VaultQueryError" } },
  }
end

-- =============================================================================
-- Main render dispatch
-- =============================================================================

local renderers = {
  table = render_table,
  list = render_list,
  paragraph = render_paragraph,
  header = render_header,
  task_list = render_task_list,
  error = render_error,
}

--- Compute the display width of a virt_line (array of {text, hl} chunks).
---@param vl table[]
---@return number
local function virt_line_width(vl)
  local w = 0
  for _, chunk in ipairs(vl) do
    w = w + display_width(chunk[1])
  end
  return w
end

--- Wrap content virt_lines in a box border.
---@param content_lines table[]  array of virt_lines (each an array of {text,hl} chunks)
---@return table[]  bordered virt_lines
local function wrap_in_border(content_lines)
  -- Measure max content width
  local max_w = 0
  for _, vl in ipairs(content_lines) do
    local w = virt_line_width(vl)
    if w > max_w then max_w = w end
  end

  -- Ensure minimum width for the "Results" label
  local label = " Results "
  local label_w = display_width(label)
  if max_w < label_w + 4 then
    max_w = label_w + 4
  end

  -- Inner width = max_w + 1 (right padding)
  local inner = max_w + 1

  local bordered = {}

  -- Top border: ╭─── Results ───...─╮
  local top_after = inner - label_w - 1
  if top_after < 1 then top_after = 1 end
  bordered[#bordered + 1] = {
    { "\u{256D}\u{2500}" .. label, "VaultQueryBorder" },
    { string.rep("\u{2500}", top_after) .. "\u{256E}", "VaultQueryBorder" },
  }

  -- Content lines with left/right borders
  for _, vl in ipairs(content_lines) do
    local w = virt_line_width(vl)
    local pad_n = inner - w
    if pad_n < 0 then pad_n = 0 end

    local bordered_line = { { "\u{2502}", "VaultQueryBorder" } }
    for _, chunk in ipairs(vl) do
      bordered_line[#bordered_line + 1] = chunk
    end
    bordered_line[#bordered_line + 1] = { string.rep(" ", pad_n), "" }
    bordered_line[#bordered_line + 1] = { "\u{2502}", "VaultQueryBorder" }
    bordered[#bordered + 1] = bordered_line
  end

  -- Bottom border: ╰───...─╯
  bordered[#bordered + 1] = {
    { "\u{2570}" .. string.rep("\u{2500}", inner + 1) .. "\u{256F}", "VaultQueryBorder" },
  }

  return bordered
end

--- Render query results as virtual lines below a code block.
---@param buf number buffer handle
---@param line number 0-indexed line of closing ``` fence
---@param results table[] list of render items
function M.render(buf, line, results)
  -- Clear existing output at this line
  M.clear(buf, line)

  if not results or #results == 0 then
    return
  end

  -- Collect content lines (without border)
  local content_lines = {}

  for _, item in ipairs(results) do
    -- Add group header if present
    if item.group then
      content_lines[#content_lines + 1] = {
        { "  ### " .. item.group, "VaultQueryGroupHeader" },
      }
    end

    local renderer = renderers[item.type]
    if renderer then
      local item_lines = renderer(item)
      for _, vl in ipairs(item_lines) do
        content_lines[#content_lines + 1] = vl
      end
    else
      content_lines[#content_lines + 1] = {
        { "  (unknown result type: " .. tostring(item.type) .. ")", "VaultQueryNull" },
      }
    end
  end

  -- Wrap in box border
  local all_virt_lines = wrap_in_border(content_lines)

  -- Place extmark on the line after the closing fence to avoid conflicts
  -- with render-markdown.nvim which manages code block fence lines
  local line_count = vim.api.nvim_buf_line_count(buf)
  local target_line = line
  if line + 1 < line_count then
    target_line = line + 1
    vim.api.nvim_buf_set_extmark(buf, ns, target_line, 0, {
      virt_lines = all_virt_lines,
      virt_lines_above = true,
      virt_lines_leftcol = true,
      priority = 200,
    })
  else
    -- Last line of buffer, place below
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      virt_lines = all_virt_lines,
      virt_lines_above = false,
      virt_lines_leftcol = true,
      priority = 200,
    })
  end
end

--- Clear rendered output at a specific code block.
---@param buf number buffer handle
---@param line number 0-indexed line of closing ``` fence
function M.clear(buf, line)
  -- Check both the fence line and the line after it (where we now place extmarks)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { line, 0 }, { line + 1, -1 }, {})
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(buf, ns, mark[1])
  end
end

--- Clear all rendered output in a buffer.
---@param buf number buffer handle
function M.clear_all(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

--- Check if there's rendered output at a specific line.
---@param buf number buffer handle
---@param line number 0-indexed line
---@return boolean
function M.is_rendered(buf, line)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { line, 0 }, { line + 1, -1 }, {})
  return #marks > 0
end

--- Toggle rendering on/off at a specific line.
---@param buf number buffer handle
---@param line number 0-indexed line
---@param results table[] render items (needed if toggling on)
function M.toggle(buf, line, results)
  if M.is_rendered(buf, line) then
    M.clear(buf, line)
  else
    M.render(buf, line, results)
  end
end

-- =============================================================================
-- Inline rendering (for `$=expr` inline dataviewjs)
-- =============================================================================

local inline_ns = vim.api.nvim_create_namespace("vault_query_inline")

--- Render an inline result as virtual text appended to the line.
---@param buf number buffer handle
---@param line number 0-indexed line
---@param col number 0-indexed column of the closing backtick
---@param text string the result text to display
---@param is_error boolean whether this is an error/info message
function M.render_inline(buf, line, col, text, is_error)
  local hl = is_error and "VaultQueryNull" or "VaultQueryValue"
  vim.api.nvim_buf_set_extmark(buf, inline_ns, line, col, {
    virt_text = {
      { " \u{2502}", "VaultQueryBorder" },
      { " " .. text .. " ", hl },
      { "\u{2502}", "VaultQueryBorder" },
    },
    virt_text_pos = "inline",
    priority = 200,
  })
end

--- Clear all inline rendered output in a buffer.
---@param buf number buffer handle
function M.clear_all_inline(buf)
  vim.api.nvim_buf_clear_namespace(buf, inline_ns, 0, -1)
end

return M
