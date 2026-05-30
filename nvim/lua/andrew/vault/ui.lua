local cleanup = require("andrew.vault.resource_cleanup")
local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("ui")

local M = {}

--- Get screen dimensions with fallback for headless mode.
---@return { width: number, height: number }
function M.get_screen_dims()
  return vim.api.nvim_list_uis()[1] or { width = config.ui.fallback_screen_width, height = config.ui.fallback_screen_height }
end

--- Calculate centered float dimensions based on screen ratios.
---@param width_ratio number fraction of screen width (0-1)
---@param height_ratio number fraction of screen height (0-1)
---@param opts? { max_width?: number, max_height?: number, content_lines?: number }
---@return { width: number, height: number, row: number, col: number }
function M.centered_float_dims(width_ratio, height_ratio, opts)
  opts = opts or {}
  local screen = M.get_screen_dims()
  local width = math.floor(screen.width * width_ratio)
  local height = math.floor(screen.height * height_ratio)
  if opts.max_width then width = math.min(width, opts.max_width) end
  if opts.max_height then height = math.min(height, opts.max_height) end
  if opts.content_lines then
    height = math.min(opts.content_lines + 2, height)
  end
  local row = math.floor((screen.height - height) / 2)
  local col = math.floor((screen.width - width) / 2)
  return { width = width, height = height, row = row, col = col }
end

--- Create a centered floating input window.
--- @param opts { title: string, width?: number, height?: number, filetype?: string, on_submit: fun(lines: string[]), submit_modes?: string[] }
--- @return { buf: number, win: number, close: fun() }
function M.create_float_input(opts)
  local width = opts.width or config.ui.input_float_width
  local height = opts.height or 1
  local ui = M.get_screen_dims()
  local col = math.floor((ui.width - width) / 2)
  local row = math.floor((ui.height - height) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
  })

  vim.cmd("startinsert")

  local closed = false
  local function close(submit)
    if closed then return end
    closed = true
    if submit and opts.on_submit then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      opts.on_submit(lines)
    end
    vim.cmd("stopinsert")
    cleanup.close_win(win)
  end

  local submit_modes = opts.submit_modes or { "n" }
  vim.keymap.set(submit_modes, "<CR>", function() close(true) end, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", function() close(false) end, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", function() close(false) end, { buffer = buf, silent = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function() close(false) end,
  })

  return { buf = buf, win = win, close = close }
end

--- Create a centered floating display window (read-only).
--- @param opts { title: string|table, lines: string[], width?: number, height?: number, enter?: boolean, cursor_line?: boolean, relative?: string, row?: number, col?: number, filetype?: string, close_keymaps?: boolean }
--- @return { buf: number, win: number, close: fun() }
function M.create_float_display(opts)
  local ui = M.get_screen_dims()
  local width = opts.width or math.floor(ui.width * config.ui.default_float_width_ratio)
  local height = opts.height or math.min(#opts.lines + 2, math.floor(ui.height * config.ui.default_float_height_ratio))
  local relative = opts.relative or "editor"

  -- Default to centered positioning for editor-relative floats
  local row, col
  if opts.row then
    row = opts.row
  else
    row = math.floor((ui.height - height) / 2)
  end
  if opts.col then
    col = opts.col
  else
    col = math.floor((ui.width - width) / 2)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end

  -- Title: accept string (auto-padded) or table (raw title chunks)
  local title
  if type(opts.title) == "table" then
    title = opts.title
  else
    title = " " .. opts.title .. " "
  end

  local enter = opts.enter ~= false -- default true
  local win = vim.api.nvim_open_win(buf, enter, {
    relative = relative,
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  if opts.cursor_line ~= nil then
    vim.wo[win].cursorline = opts.cursor_line
  end
  vim.wo[win].wrap = false

  local function close()
    cleanup.close_win(win)
  end

  -- close_keymaps defaults to true; set false to skip q/<Esc> bindings
  if opts.close_keymaps ~= false then
    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
    end
  end

  return { buf = buf, win = win, close = close }
end

--- Set up markdown filetype, treesitter highlighting, and render-markdown
--- rendering on a float buffer/window pair. Errors are logged but not raised.
--- @param buf number  Buffer handle
--- @param win number  Window handle
function M.setup_and_render_markdown(buf, win)
  vim.bo[buf].filetype = "markdown"
  local ok, err = pcall(vim.treesitter.start, buf, "markdown")
  if not ok then log.debug("treesitter start failed: %s", err) end
  local rm_ok, rm_err = pcall(function()
    require("render-markdown").render({ buf = buf, win = win })
  end)
  if not rm_ok then log.debug("render-markdown render failed: %s", rm_err) end
end

--- Apply standard markdown float window options.
--- Sets conceallevel, wrap, linebreak, and foldenable for consistent
--- markdown preview rendering across all vault float windows.
--- @param win number  Window handle
function M.setup_markdown_float_opts(win)
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].foldenable = false
end

--- Apply incremental line+highlight updates to a buffer.
--- Only re-sets lines and highlights for rows that actually changed.
--- Falls back to full replacement when prev_lines is nil or line count differs.
---@param buf number  Buffer handle
---@param ns_id number  Highlight namespace
---@param prev_lines string[]|nil  Previous line content (nil = first render)
---@param lines string[]  New line content
---@param highlights table[]  { [1]=group, [2]=row, [3]=col_start, [4]=col_end }
---@return string[]  The new lines (to store as prev_lines for next call)
function M.apply_incremental_render(buf, ns_id, prev_lines, lines, highlights)
  if prev_lines and #prev_lines == #lines then
    -- Incremental: only update changed lines and their highlights
    for i, new_line in ipairs(lines) do
      if new_line ~= prev_lines[i] then
        vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { new_line })
        vim.api.nvim_buf_clear_namespace(buf, ns_id, i - 1, i)
        for _, hl in ipairs(highlights) do
          if hl[2] == i - 1 then
            pcall(vim.api.nvim_buf_add_highlight, buf, ns_id, hl[1], hl[2], hl[3], hl[4])
          end
        end
      end
    end
  else
    -- Full replacement on first render or line count change
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
    for _, hl in ipairs(highlights) do
      pcall(vim.api.nvim_buf_add_highlight, buf, ns_id, hl[1], hl[2], hl[3], hl[4])
    end
  end
  return lines
end

return M
