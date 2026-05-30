local config = require("andrew.vault.config")
local cleanup = require("andrew.vault.resource_cleanup")
local notify = require("andrew.vault.notify")
local track = require("andrew.vault.search.track").track

local M = {}

--- Advanced search: prompt mode with inline help.
--- Shows a floating input with syntax reference footer and Ctrl-/ help toggle.
function M.search_advanced()
  local advanced = require("andrew.vault.search.advanced")
  local help = require("andrew.vault.search.help")
  local completion = require("andrew.vault.search.completion")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local width = config.search.prompt_width
  local ui_dims = require("andrew.vault.ui").get_screen_dims()
  local row = math.floor((ui_dims.height - 3) / 2)
  local col = math.floor((ui_dims.width - width) / 2)

  -- NOTE: Direct nvim_open_win — not using ui.create_float_input() because this
  -- needs footer chunks, Tab completion, Ctrl-r history, and BufEnter re-insert.
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Advanced Search ",
    title_pos = "center",
    footer = {
      { " field:value tag:x has:tags links-to:Note created:>7d AND OR NOT │ ", "Comment" },
      { "Ctrl-/", "Special" },
      { " help ", "Comment" },
      { " │ ", "Comment" },
      { "Ctrl-r", "Special" },
      { " history ", "Comment" },
    },
    footer_pos = "center",
  })

  vim.cmd("startinsert")

  local closed = false

  local function close_win()
    if closed then return end
    closed = true
    vim.cmd("stopinsert")
    cleanup.close_win(win)
  end

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local query = vim.trim(table.concat(lines, " "))
    close_win()
    if query ~= "" then
      track(query, "all", "advanced", true)
      vim.schedule(function()
        advanced.execute_advanced_query(query)
      end)
    end
  end

  -- Submit / cancel / help keymaps
  vim.keymap.set({ "n", "i" }, "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<Esc>", close_win, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", close_win, { buffer = buf, silent = true })
  vim.keymap.set({ "n", "i" }, "<C-/>", function()
    help.search_help()
  end, { buffer = buf, silent = true })

  -- Ctrl-r: open search history and paste selected query into prompt
  vim.keymap.set({ "n", "i" }, "<C-r>", function()
    local history = require("andrew.vault.search_history")
    local ranked = history.ranked()
    if #ranked == 0 then
      notify.no_search_history()
      return
    end
    local items = {}
    for _, item in ipairs(ranked) do
      items[#items + 1] = item.query
    end
    vim.ui.select(items, { prompt = "Search history:" }, function(choice)
      if choice and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { choice })
        -- Move cursor to end of line
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_cursor(win, { 1, #choice })
            vim.cmd("startinsert!")
          end
        end)
      end
    end)
  end, { buffer = buf, silent = true })

  -- Tab completion for field names, operators, and values
  vim.keymap.set("i", "<Tab>", function()
    local line = vim.api.nvim_get_current_line()
    local cursor_col = vim.fn.col(".")
    local before = line:sub(1, cursor_col - 1)
    local lead = before:match("[%w_%-:%.#,]*$") or ""
    local candidates = completion._complete_advanced(lead)
    if #candidates > 0 then
      vim.fn.complete(cursor_col - #lead, candidates)
    end
  end, { buffer = buf, silent = true })

  -- Re-enter insert mode when returning from help float
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      if not closed then
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(win) then
            vim.cmd("startinsert!")
          end
        end)
      end
    end,
  })
end

return M
