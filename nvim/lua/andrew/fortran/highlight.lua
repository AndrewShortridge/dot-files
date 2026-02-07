-- Fortran custom syntax highlighting module
-- Provides syntax highlighting for documented keywords from fortran-docs.json
local M = {}

local docs = require("andrew.fortran.docs")

-- Define highlight groups for different keyword categories
function M.setup_highlights()
  -- Link to existing highlight groups or define custom ones
  vim.api.nvim_set_hl(0, "FortranCustomKeyword", { link = "Function" })
  vim.api.nvim_set_hl(0, "FortranMPIKeyword", { link = "Constant" })
  vim.api.nvim_set_hl(0, "FortranOMPKeyword", { link = "PreProc" })
end

-- Categorize a keyword based on its name
local function categorize(keyword)
  if keyword:match("^mpi") or keyword:match("^MPI") then
    return "FortranMPIKeyword"
  elseif keyword:match("^omp") or keyword:match("^OMP") then
    return "FortranOMPKeyword"
  else
    return "FortranCustomKeyword"
  end
end

-- Apply syntax matches for all documented keywords
function M.apply(bufnr)
  bufnr = bufnr or 0
  local keywords = docs.keywords()

  for _, kw in ipairs(keywords) do
    local group = categorize(kw)
    -- Use \< and \> for word boundaries
    -- Case insensitive with \c
    local pattern = string.format("\\c\\<%s\\>", vim.fn.escape(kw, "\\"))
    vim.cmd(string.format(
      "syntax match %s /%s/ containedin=ALL",
      group, pattern
    ))
  end
end

return M
