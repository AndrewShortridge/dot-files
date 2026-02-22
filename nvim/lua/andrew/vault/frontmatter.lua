local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup("VaultFrontmatter", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if not engine.is_vault_path(bufpath) then
        return
      end

      local line_count = vim.api.nvim_buf_line_count(ev.buf)
      local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, math.min(line_count, config.frontmatter.max_scan_lines), false)

      -- No frontmatter at all: initialize a basic block
      if #lines == 0 or lines[1] ~= "---" then
        local now = os.date(config.frontmatter.timestamp_format)
        pcall(vim.cmd, "undojoin")
        vim.api.nvim_buf_set_lines(ev.buf, 0, 0, false, {
          "---",
          config.frontmatter.created_field .. ": " .. now,
          config.frontmatter.modified_field .. ": " .. now,
          "---",
        })
        return
      end

      local now = os.date(config.frontmatter.timestamp_format)
      local closing = nil

      for i = 2, #lines do
        if lines[i] == "---" then
          closing = i
          break
        end
        if lines[i]:match("^" .. config.frontmatter.modified_field .. ":") then
          -- Merge into previous undo entry so 'u' doesn't just undo the timestamp
          pcall(vim.cmd, "undojoin")
          vim.api.nvim_buf_set_lines(ev.buf, i - 1, i, false, { config.frontmatter.modified_field .. ": " .. now })
          return
        end
      end

      -- No modified field found; insert before closing ---
      if closing then
        pcall(vim.cmd, "undojoin")
        vim.api.nvim_buf_set_lines(ev.buf, closing - 1, closing - 1, false, { config.frontmatter.modified_field .. ": " .. now })
      end
    end,
  })
end

return M
