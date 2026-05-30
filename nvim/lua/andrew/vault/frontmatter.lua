local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local fm_parser = require("andrew.vault.frontmatter_parser")
local log = require("andrew.vault.vault_log").scope("frontmatter")

local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup("VaultFrontmatter", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if not engine.is_vault_buf(ev.buf) then
        return
      end

      local max = config.frontmatter.max_scan_lines
      local line_count = vim.api.nvim_buf_line_count(ev.buf)
      local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, math.min(line_count, max), false)

      -- No frontmatter at all: initialize a basic block
      if #lines == 0 or lines[1] ~= "---" then
        local now = os.date(config.frontmatter.timestamp_format)
        local ok, err = pcall(vim.cmd, "undojoin")
        if not ok then log.debug("undojoin before frontmatter init: %s", err) end
        vim.api.nvim_buf_set_lines(ev.buf, 0, 0, false, {
          "---",
          config.frontmatter.created_field .. ": " .. now,
          config.frontmatter.modified_field .. ": " .. now,
          "---",
        })
        return
      end

      local fm = fm_parser.parse_lines(lines, max)
      if not fm then return end -- unclosed frontmatter

      local now = os.date(config.frontmatter.timestamp_format)

      -- Search for modified field within frontmatter boundaries
      for i = fm.start_line + 1, fm.end_line - 1 do
        if lines[i]:match("^" .. config.frontmatter.modified_field .. ":") then
          -- Merge into previous undo entry so 'u' doesn't just undo the timestamp
          local ok, err = pcall(vim.cmd, "undojoin")
          if not ok then log.debug("undojoin before modified update: %s", err) end
          vim.api.nvim_buf_set_lines(ev.buf, i - 1, i, false, { config.frontmatter.modified_field .. ": " .. now })
          return
        end
      end

      -- No modified field found; insert before closing ---
      local ok, err = pcall(vim.cmd, "undojoin")
      if not ok then log.debug("undojoin before modified insert: %s", err) end
      vim.api.nvim_buf_set_lines(ev.buf, fm.end_line - 1, fm.end_line - 1, false, { config.frontmatter.modified_field .. ": " .. now })
    end,
  })
end

return M
