-- =============================================================================
-- JSONL record preview: the record under the cursor, pretty-printed beside it
-- =============================================================================
-- A JSONL file holds one JSON value per line, so a record of any size is one
-- long line. The preview is a split to the right of the file that shows the
-- record under the cursor as `jq .` prints it, in a scratch `json` buffer. It
-- follows the cursor and the edits made to the file, and closes with it.
--
-- jq, not vim.json: decoding a record into a Lua table loses the order of its
-- keys, and the order is how a record is recognised at a glance.
--
-- PROTOTYPE: no spec in tests/ and no entry in AGENTS.md / KEYMAPS.md yet.

local M = {}

local JQ_COMMAND = "jq"

---@class JsonlPreview
---@field buffer integer scratch buffer the record is printed into
---@field window integer the split showing that buffer
---@field augroup integer the autocmds that keep it following the source buffer
---@field shown_line_number integer? line of the source the buffer shows
---@field request_serial integer number of jq runs started; tells a late answer from the latest

--- The open preview of each JSONL buffer, by that buffer's number.
---@type table<integer, JsonlPreview>
local preview_of_source = {}

--- Replace what the preview shows.
---@param preview JsonlPreview
---@param lines string[]
---@param title string shown in the preview window's winbar; must hold no `%`
local function show(preview, lines, title)
  if not vim.api.nvim_buf_is_valid(preview.buffer) then
    return
  end
  vim.bo[preview.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(preview.buffer, 0, -1, false, lines)
  vim.bo[preview.buffer].modifiable = false

  local is_still_shown = vim.api.nvim_win_is_valid(preview.window)
    and vim.api.nvim_win_get_buf(preview.window) == preview.buffer
  if is_still_shown then
    vim.wo[preview.window][0].winbar = title
    -- Every record starts at its top, wherever the last one was scrolled to.
    vim.api.nvim_win_set_cursor(preview.window, { 1, 0 })
  end
end

--- Print the record under the cursor of the current window into the preview.
---@param source_buffer integer
---@param is_forced boolean print again even if the cursor is on the line already shown
local function refresh(source_buffer, is_forced)
  local preview = preview_of_source[source_buffer]
  if not preview or vim.api.nvim_get_current_buf() ~= source_buffer then
    return
  end
  local line_number = vim.api.nvim_win_get_cursor(0)[1]
  if not is_forced and line_number == preview.shown_line_number then
    return
  end
  preview.shown_line_number = line_number
  preview.request_serial = preview.request_serial + 1
  local request_serial = preview.request_serial

  local record = vim.api.nvim_buf_get_lines(source_buffer, line_number - 1, line_number, false)[1] or ""
  local title = ("record %d of %d"):format(line_number, vim.api.nvim_buf_line_count(source_buffer))

  -- on_exit runs outside the main loop (:help vim.system()), hence the wrap.
  local on_exit = vim.schedule_wrap(function(result) ---@param result vim.SystemCompleted
    -- Holding `j` starts a jq per line; only the answer for the line the
    -- cursor ended on may be shown.
    if preview_of_source[source_buffer] ~= preview or preview.request_serial ~= request_serial then
      return
    end
    if result.code ~= 0 then
      show(preview, vim.split(result.stderr or "", "\n", { trimempty = true }), title .. " -- not valid JSON")
      return
    end
    local pretty_lines = vim.split(result.stdout or "", "\n", { trimempty = true })
    show(preview, pretty_lines, #pretty_lines == 0 and (title .. " -- empty line") or title)
  end)
  vim.system({ JQ_COMMAND, "." }, { stdin = record, text = true }, on_exit)
end

--- Close the preview of a JSONL buffer, if it has one.
---@param source_buffer integer
function M.close(source_buffer)
  local preview = preview_of_source[source_buffer]
  if not preview then
    return
  end
  preview_of_source[source_buffer] = nil
  vim.api.nvim_del_augroup_by_id(preview.augroup)

  local is_still_shown = vim.api.nvim_win_is_valid(preview.window)
    and vim.api.nvim_win_get_buf(preview.window) == preview.buffer
  if is_still_shown then
    -- Fails when it is the last window; the buffer delete below then empties it.
    pcall(vim.api.nvim_win_close, preview.window, true)
  end
  if vim.api.nvim_buf_is_valid(preview.buffer) then
    vim.api.nvim_buf_delete(preview.buffer, { force = true })
  end
end

--- Open the preview to the right of the current window, for the buffer in it.
---@param source_buffer integer the JSONL buffer; must be the current buffer
function M.open(source_buffer)
  if preview_of_source[source_buffer] then
    return
  end
  if vim.fn.executable(JQ_COMMAND) ~= 1 then
    vim.notify("JSONL preview needs `jq` on PATH", vim.log.levels.WARN)
    return
  end

  -- An unlisted scratch buffer: 'buftype' is "nofile" before 'filetype' is
  -- set, so no language server attaches to it.
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].modifiable = false
  local source_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source_buffer), ":t")
  -- Fails on a name already taken (two unnamed JSONL buffers); the preview
  -- then stays unnamed.
  pcall(vim.api.nvim_buf_set_name, buffer, source_name .. " [record]")
  vim.bo[buffer].filetype = "json"

  local window = vim.api.nvim_open_win(buffer, false, { split = "right", win = 0 })
  -- The split inherits the JSONL window's options, 'nowrap' among them.
  local window_options = vim.wo[window][0]
  window_options.wrap = true
  window_options.linebreak = true
  window_options.breakindent = true
  window_options.number = false
  window_options.relativenumber = false
  window_options.signcolumn = "no"
  window_options.foldmethod = "expr"
  window_options.foldexpr = "v:lua.vim.treesitter.foldexpr()"
  window_options.foldlevel = 99

  local augroup = vim.api.nvim_create_augroup("jsonl-preview-" .. source_buffer, { clear = true })
  ---@type JsonlPreview
  local preview = { buffer = buffer, window = window, augroup = augroup, request_serial = 0 }
  preview_of_source[source_buffer] = preview

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter", "WinEnter" }, {
    group = augroup,
    buffer = source_buffer,
    desc = "JSONL preview: follow the cursor to another record",
    callback = function()
      refresh(source_buffer, false)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = source_buffer,
    desc = "JSONL preview: print the record again after an edit",
    callback = function()
      refresh(source_buffer, true)
    end,
  })
  vim.api.nvim_create_autocmd("QuitPre", {
    group = augroup,
    buffer = source_buffer,
    desc = "JSONL preview: let :q on the file's last window quit instead of leaving the preview",
    callback = function()
      if #vim.fn.win_findbuf(source_buffer) == 1 then
        M.close(source_buffer)
      end
    end,
  })

  -- The file left its last window, or the preview was closed by hand. Both
  -- arrive in the middle of a window or buffer being torn down, so the
  -- closing waits for that to finish.
  local close_this_preview = vim.schedule_wrap(function()
    if preview_of_source[source_buffer] == preview then
      M.close(source_buffer)
    end
  end)
  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout" }, {
    group = augroup,
    buffer = source_buffer,
    desc = "JSONL preview: close with the file",
    callback = close_this_preview,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = buffer,
    desc = "JSONL preview: forget a preview closed by hand",
    callback = close_this_preview,
  })

  vim.keymap.set("n", "q", function()
    M.close(source_buffer)
  end, { buffer = buffer, silent = true, desc = "JSONL: close the record preview" })

  refresh(source_buffer, true)
end

--- Open the preview of the current buffer, or close it when it is open.
function M.toggle()
  local source_buffer = vim.api.nvim_get_current_buf()
  if preview_of_source[source_buffer] then
    M.close(source_buffer)
  else
    M.open(source_buffer)
  end
end

return M
