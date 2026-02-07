-- Fortran custom features module
-- Provides syntax highlighting and hover documentation for custom keywords
local M = {}

function M.setup()
  local highlight = require("andrew.fortran.highlight")

  -- Setup highlight groups once
  highlight.setup_highlights()

  -- Apply syntax matches when opening Fortran files
  vim.api.nvim_create_autocmd("FileType", {
    pattern = { "fortran", "fortran_fixed", "fortran_free", "f90", "f95" },
    group = vim.api.nvim_create_augroup("FortranCustomHighlight", { clear = true }),
    callback = function(ev)
      -- Defer slightly to ensure syntax is loaded first
      vim.defer_fn(function()
        highlight.apply(ev.buf)
      end, 10)
    end,
  })
end

return M
