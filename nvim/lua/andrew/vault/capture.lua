local engine = require("andrew.vault.engine")

local M = {}

--- Open a small floating window for text capture.
---@param title string window title
---@param on_submit function(text: string) called with captured text
local function open_capture_window(title, on_submit)
  local width = 60
  local height = 3
  local ui = vim.api.nvim_list_uis()[1]
  local col = math.floor((ui.width - width) / 2)
  local row = math.floor((ui.height - height) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  -- Start in insert mode
  vim.cmd("startinsert")

  local closed = false

  local function close_window(save)
    if closed then return end
    closed = true

    if save then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = vim.trim(table.concat(lines, "\n"))
      if text ~= "" then
        on_submit(text)
      else
        vim.notify("Vault: empty capture, nothing saved", vim.log.levels.WARN)
      end
    end

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- <CR> in normal mode: save and close
  vim.keymap.set("n", "<CR>", function()
    close_window(true)
  end, { buffer = buf, silent = true })

  -- q and <Esc> in normal mode: close without saving
  vim.keymap.set("n", "q", function()
    close_window(false)
  end, { buffer = buf, silent = true })

  vim.keymap.set("n", "<Esc>", function()
    close_window(false)
  end, { buffer = buf, silent = true })

  -- BufLeave: close without saving (user navigated away)
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      close_window(false)
    end,
  })
end

--- Ensure a file exists with basic daily log frontmatter.
--- Returns the absolute path.
---@param rel_path string path relative to vault root (with .md extension)
---@param frontmatter string[] lines of frontmatter content
---@return string abs_path
local function ensure_file(rel_path, frontmatter)
  local abs_path = engine.vault_path .. "/" .. rel_path
  local dir = vim.fn.fnamemodify(abs_path, ":h")
  engine.ensure_dir(dir)

  if vim.fn.filereadable(abs_path) ~= 1 then
    local file = io.open(abs_path, "w")
    if file then
      file:write(table.concat(frontmatter, "\n") .. "\n")
      file:close()
    end
  end

  return abs_path
end

--- Append a timestamped bullet to a file.
---@param abs_path string absolute file path
---@param text string captured text
local function append_bullet(abs_path, text)
  local timestamp = os.date("%H:%M")
  local text_lines = vim.split(text, "\n", { trimempty = true })
  local first = "- " .. timestamp .. " " .. (text_lines[1] or "") .. "\n"
  local indent = string.rep(" ", #("- " .. timestamp .. " "))

  local file = io.open(abs_path, "a")
  if not file then
    vim.notify("Vault: failed to write " .. abs_path, vim.log.levels.ERROR)
    return
  end
  file:write(first)
  for i = 2, #text_lines do
    file:write(indent .. text_lines[i] .. "\n")
  end
  file:close()
end

--- Capture a thought to today's daily log.
function M.capture_to_daily()
  open_capture_window("Capture", function(text)
    local date = engine.today()
    local rel_path = "Log/" .. date .. ".md"
    local frontmatter = {
      "---",
      "type: daily",
      "date: " .. date,
      "tags: [daily]",
      "---",
      "",
      "# " .. engine.today_weekday(),
      "",
    }

    local abs_path = ensure_file(rel_path, frontmatter)
    append_bullet(abs_path, text)
    vim.notify("Captured to " .. date, vim.log.levels.INFO)
  end)
end

--- Capture a thought to the vault inbox.
function M.capture_to_inbox()
  open_capture_window("Inbox", function(text)
    local rel_path = "Inbox.md"
    local frontmatter = {
      "---",
      "type: inbox",
      "tags: [inbox]",
      "---",
      "",
      "# Inbox",
      "",
    }

    local abs_path = ensure_file(rel_path, frontmatter)
    append_bullet(abs_path, text)
    vim.notify("Captured to Inbox", vim.log.levels.INFO)
  end)
end

function M.setup()
  -- Commands
  vim.api.nvim_create_user_command("VaultCapture", function()
    M.capture_to_daily()
  end, { desc = "Quick capture to today's daily log" })

  vim.api.nvim_create_user_command("VaultCaptureInbox", function()
    M.capture_to_inbox()
  end, { desc = "Quick capture to vault inbox" })

  -- Global keybindings
  local keymap = vim.keymap.set
  local opts = function(desc)
    return { desc = desc, silent = true }
  end

  keymap("n", "<leader>vQ", function()
    M.capture_to_daily()
  end, opts("Vault: quick capture to daily log"))

  keymap("n", "<leader>vi", function()
    M.capture_to_inbox()
  end, opts("Vault: capture to inbox"))
end

return M
