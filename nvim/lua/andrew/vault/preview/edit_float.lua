local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")
local wikilinks = require("andrew.vault.wikilinks")
local ui = require("andrew.vault.ui")
local cleanup = require("andrew.vault.resource_cleanup")
local guard = require("andrew.vault.guard")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("preview.edit")

--- Edit-in-float functionality for vault wikilinks.
local M = {}

--- Save the buffer if modified.
---@param buf number
local function save_float_buf(buf)
  if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  end
end

--- Open the linked note under the cursor in an editable floating window.
function M.edit_link()
  local details = link_utils.get_wikilink_under_cursor()
  if not details or details.name == "" then
    notify.info("no cross-file wikilink under cursor")
    return
  end

  local link = details.name
  local path = wikilinks.resolve_link(link)
  if not path then
    notify.warn("note not found: " .. link)
    return
  end

  -- Compute float dimensions: centered, using config ratios
  local dims = ui.centered_float_dims(config.preview.edit_width_ratio, config.preview.edit_height_ratio)

  -- Use multi-guard for atomic cleanup: if any step after window creation fails,
  -- window + augroup are cleaned up automatically (defense-in-depth).
  local mg = guard.multi()
  local ok_guard, err = mg:run(function(g)
    -- Open (or reuse) the buffer for the file
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)

    -- Open focused floating window
    -- NOTE: Direct nvim_open_win — not using ui.create_float_display() because this
    -- is an editable file buffer (not a scratch display), with save-on-close semantics.
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = dims.row,
      col = dims.col,
      width = dims.width,
      height = dims.height,
      border = "rounded",
      title = { { " " .. link .. " ", "Function" } },
      title_pos = "center",
    })
    g:add(function() cleanup.close_win(win) end, "edit_win")

    -- Buffer options
    vim.bo[buf].filetype = "markdown"

    -- Window options (shared markdown float setup + edit-specific winhighlight)
    ui.setup_markdown_float_opts(win)
    vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:FloatBorder"

    -- Keymaps inside the float
    local opts = { buffer = buf, nowait = true, silent = true }
    local function save_and_close()
      save_float_buf(buf)
      cleanup.close_win(win)
    end
    vim.keymap.set("n", "q", save_and_close,
      vim.tbl_extend("force", opts, { desc = "Save and close float" }))
    vim.keymap.set("n", "<Esc><Esc>", save_and_close,
      vim.tbl_extend("force", opts, { desc = "Save and close float" }))
    vim.keymap.set({ "n", "i" }, "<C-s>", function()
      save_float_buf(buf)
    end, vim.tbl_extend("force", opts, { desc = "Save float buffer" }))

    -- Auto-save on WinClosed
    local augroup = vim.api.nvim_create_augroup("VaultEditFloat_" .. win, { clear = true })
    g:add(function() cleanup.close_augroup(augroup) end, "edit_augroup")

    vim.api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(win),
      once = true,
      callback = function()
        save_float_buf(buf)
        cleanup.close_augroup(augroup)
      end,
    })

    -- All setup succeeded: transfer ownership to autocmd, dismiss guards
    g:dismiss_all()
  end)

  if not ok_guard then log.error("Edit float failed: %s", err) end
end

return M
