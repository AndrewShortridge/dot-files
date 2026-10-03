-- =============================================================================
-- snippets/fortran-overrides.lua -- the one door onto the hand-authored tables
-- =============================================================================
--
-- WHY THIS EXISTS
--
-- `snippets/overrides/{mpi,openmp}.lua` carry everything no machine source on
-- this box can say: which MPI version introduced a call, what a clause MEANS,
-- and the ~50 entries `mpi.mod` and `omp_lib.f90` have no record of at all.
-- Two generators, the freshness spec and anything else that wants to ask "what
-- did a human assert here, as opposed to what did the compiler say" all need
-- them, and each doing its own `loadfile` is three spellings of the same path
-- and three different answers to "what if it is missing".
--
-- So this is the single door. `M.load(name, dir)` resolves `dir` (default:
-- `overrides/` next to THIS file, so it works under `nvim -u NONE` from any
-- cwd) and reports three things a caller may care about:
--
--   * the table -- `{}` when the file is absent, never an error;
--   * `present` -- absent and empty are different facts: gen-omp records which
--     one it saw in `_meta.overrides`, because an OpenMP table generated with
--     no overrides has no directives in it at all;
--   * `err` -- a syntax error in a hand-edited file. The generators DIE on
--     this. Silently generating a table with 137 entries missing, because a
--     comma was fat-fingered, is the one failure mode worth stopping for.
--
-- `M.mpi` / `M.openmp` are the eager convenience view for readers that only
-- want the default directory and do not care why a table is empty.

local dir = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h")

local M = {}

--- Default directory holding `<name>.lua` override files.
M.dir = dir .. "/overrides"

--- Load one override table.
---@param name string `"mpi"` or `"openmp"`
---@param from string|nil directory to read from; defaults to `M.dir`
---@return table tbl, boolean present, string|nil err
function M.load(name, from)
  local path = (from or M.dir) .. "/" .. name .. ".lua"
  if vim.fn.filereadable(path) ~= 1 then
    return {}, false, nil
  end
  local chunk, lerr = loadfile(path)
  if not chunk then
    return {}, true, tostring(lerr)
  end
  local ok, t = pcall(chunk)
  if not ok then
    return {}, true, tostring(t)
  end
  if type(t) ~= "table" then
    return {}, true, path .. " did not return a table"
  end
  return t, true, nil
end

M.mpi = M.load("mpi")
M.openmp = M.load("openmp")

return M
