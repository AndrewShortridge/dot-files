local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local ui = require("andrew.vault.ui")
local notify = require("andrew.vault.notify")

local M = {}

--- Open a small floating window for text capture.
---@param title string window title
---@param on_submit function(text: string) called with captured text
local function open_capture_window(title, on_submit)
  ui.create_float_input({
    title = title,
    width = config.ui.input_float_width,
    height = 3,
    filetype = "markdown",
    on_submit = function(lines)
      local text = vim.trim(table.concat(lines, "\n"))
      if text ~= "" then
        on_submit(text)
      else
        notify.warn("empty capture, nothing saved")
      end
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

  if vim.fn.filereadable(abs_path) ~= 1 then
    engine.write_file(abs_path, table.concat(frontmatter, "\n") .. "\n")
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

  local content = first
  for i = 2, #text_lines do
    content = content .. indent .. text_lines[i] .. "\n"
  end
  engine.append_file(abs_path, content)
end

--- Capture a thought to today's daily log.
function M.capture_to_daily()
  open_capture_window("Capture", function(text)
    local date = engine.today()
    local rel_path = config.dirs.log .. "/" .. date .. ".md"
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
    notify.info("captured to " .. date)
  end)
end

--- Capture a thought to the vault inbox.
function M.capture_to_inbox()
  open_capture_window("Inbox", function(text)
    local rel_path = config.dirs.inbox
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
    notify.info("captured to Inbox")
  end)
end

function M.setup()
  local palette = require("andrew.vault.command_palette")

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

  -- Palette registrations
  palette.register_command("VaultCapture", "Quick capture to today's daily log", "Edit", function()
    M.capture_to_daily()
  end, "<leader>vQ")
  palette.register_command("VaultCaptureInbox", "Quick capture to vault inbox", "Edit", function()
    M.capture_to_inbox()
  end, "<leader>vi")
end

return M
