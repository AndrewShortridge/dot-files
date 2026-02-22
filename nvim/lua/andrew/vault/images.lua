local engine = require("andrew.vault.engine")
local M = {}

--- Paste an image from the system clipboard into the vault attachments folder
--- and insert a markdown image link at the cursor position.
function M.paste_image()
  local timestamp = os.date("%Y%m%d-%H%M%S")
  local filename = "img-" .. timestamp .. ".png"
  local dir = engine.vault_path .. "/attachments"
  vim.fn.mkdir(dir, "p")
  local filepath = dir .. "/" .. filename

  -- Detect clipboard tool
  local cmd
  if vim.fn.executable("xclip") == 1 then
    cmd = { "bash", "-c", "xclip -selection clipboard -t image/png -o > " .. vim.fn.shellescape(filepath) }
  elseif vim.fn.executable("wl-paste") == 1 then
    cmd = { "bash", "-c", "wl-paste --type image/png > " .. vim.fn.shellescape(filepath) }
  elseif vim.fn.executable("xsel") == 1 then
    vim.notify("Vault: xsel does not support image paste", vim.log.levels.ERROR)
    return
  else
    vim.notify("Vault: no clipboard tool found (need xclip or wl-paste)", vim.log.levels.ERROR)
    return
  end

  vim.system(cmd, {}, function(result)
    vim.schedule(function()
      local stat = vim.uv.fs_stat(filepath)
      if result.code ~= 0 or not stat or stat.size == 0 then
        vim.notify("Vault: failed to paste image from clipboard", vim.log.levels.ERROR)
        -- Clean up empty/failed file
        if stat then
          os.remove(filepath)
        end
        return
      end

      -- Insert markdown image link at cursor
      local link = "![](attachments/" .. filename .. ")"
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local line = vim.api.nvim_get_current_line()
      local before = line:sub(1, col)
      local after = line:sub(col + 1)
      vim.api.nvim_set_current_line(before .. link .. after)
      vim.api.nvim_win_set_cursor(0, { row, col + #link })
      vim.notify("Vault: pasted " .. filename, vim.log.levels.INFO)
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("VaultPasteImage", function()
    M.paste_image()
  end, { desc = "Vault: paste clipboard image" })

  local group = vim.api.nvim_create_augroup("VaultImages", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vp", function()
        M.paste_image()
      end, { buffer = ev.buf, desc = "Vault: paste image", silent = true })
    end,
  })
end

return M
