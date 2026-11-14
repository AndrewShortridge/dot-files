-- =============================================================================
-- Fortran completion ordering: the LSP group above everything else
-- =============================================================================
--
-- blink.cmp orders the menu by fuzzy score first, and the fortran-extras LSP
-- items and this config's Fortran snippets score alike for the same typed
-- prefix, so `MPI_Comm_rank` from the server and `mpi_comm_rank` from the
-- snippet collection interleaved. The user asked for the LSP group to sit
-- above the snippet group. This comparator runs FIRST in `fuzzy.sorts`
-- (plugins/blink-cmp.lua) and decides only that question; every other pair
-- falls through (nil) to blink's own `score` and `sort_text`.
--
-- Two rules keep it safe:
--
-- * It is a total pre-order over sources -- lsp = 1, everything else = 2 --
--   not "lsp beats snippets and the rest is score". A comparator that mixes
--   two orderings is intransitive and table.sort may raise "invalid order
--   function for sorting" on it. Ranking only `lsp` and leaving path, buffer
--   and snippets to score together is consistent, and it is also what the
--   menu shows in practice: `buffer` is blink's fallback for `lsp` (never
--   shown beside it) and `path` items appear only inside a path.
-- * It applies only in Fortran buffers (andrew.fortran.lsp.FILETYPES). Every
--   other filetype keeps blink's default ordering byte for byte.
--
-- One exception, and it comes before the grouping: an EXACT match to what
-- was typed wins. blink marks `item.exact` when the keyword equals the label,
-- and without this rule `ompdo` put a weak fuzzy LSP hit
-- (`command_argument_count`, score 41) above the exact `ompdo` snippet
-- (score 98); with preselect on, <CR> would then have inserted the wrong
-- word instead of expanding the block -- the very defect the LSP source's
-- bucket-12 rule exists to prevent. So the order in a Fortran buffer is:
-- exact matches, then the LSP group, then everything else, each tier by
-- blink's score and sort_text. Within the LSP group the server's own
-- sortText buckets still apply (00 directives, 09 MPI/omp_lib, 10 keywords,
-- 12 snippet-shadowing names).

local M = {}

local RANK = { lsp = 1 }
local OTHER = 2

--- Source rank: lsp first, everything else together.
---@param item table blink.cmp.CompletionItem (needs `source_id`)
---@return integer
function M.rank(item)
  return RANK[item.source_id] or OTHER
end

--- Is completion happening in a Fortran buffer? blink matches per_filetype
--- on each dot-separated segment of 'filetype', so do the same.
---@param ft string|nil defaults to the current buffer's filetype
---@return boolean
function M.is_fortran(ft)
  ft = ft or vim.bo.filetype
  if type(ft) ~= "string" or ft == "" then
    return false
  end
  local FILETYPES = require("andrew.fortran.lsp").FILETYPES
  for seg in ft:gmatch("[^.]+") do
    if FILETYPES[seg] then
      return true
    end
  end
  return false
end

--- blink.cmp.SortFunction. Returns nil to defer to the next sort.
---
--- Lexicographic on (exact desc, rank asc), which is a total pre-order, so
--- table.sort never sees an inconsistent comparator.
---@param a table
---@param b table
---@param ft string|nil filetype override (tests); the current buffer's otherwise
---@return boolean|nil
function M.compare(a, b, ft)
  local ea, eb = a.exact == true, b.exact == true
  local ra, rb = M.rank(a), M.rank(b)
  -- Cheapest test first: most pairs tie on both keys and need no filetype check.
  if ea == eb and ra == rb then
    return nil
  end
  if not M.is_fortran(ft) then
    return nil
  end
  if ea ~= eb then
    return ea
  end
  return ra < rb
end

return M
