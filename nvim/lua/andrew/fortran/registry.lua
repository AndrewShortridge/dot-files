-- =============================================================================
-- The Fortran documentation registry
-- =============================================================================
--
-- WHY THIS EXISTS
--
-- Before this module, four different things each owned their own idea of what
-- the editor knows about a Fortran name. `mpi.SIGNATURES` (46 entries) and
-- `openmp.SIGNATURES` (31) fed inlay hints. `snippets/fortran-docs.json` (388
-- keys, most of them snippet abbreviations) fed hover. `highlight.words()` read
-- that same JSON, which is why ordinary variables called `count`, `mat`, `dp`
-- or `pi` were being painted as library names. And `openmp.doc_keys` had a
-- fifth opinion for directive lines. The four sets disagreed, so a name could
-- be coloured but not hoverable, hoverable but not completable, or given
-- argument names that contradicted the compiler's own symbol table.
--
-- This module is the one set. It loads three generated tables --
-- `data/mpi.lua`, `data/openmp.lua`, `data/keywords.lua` -- and answers every
-- question about them. `interface[]` in those tables is the single source of
-- argument order, so hover, signature help and inlay hints cannot drift apart
-- again.
--
-- THREE THINGS WORTH KNOWING
--
-- * Fortran is case-insensitive. Every lookup folds to lowercase; the entry's
--   `name` keeps the canonical case (`MPI_Comm_rank`, `PRIVATE`, `allocatable`)
--   for display.
-- * The data path comes from THIS FILE's own location, not from
--   `stdpath("config")`. The two are the same in normal use and different under
--   `nvim -u NONE` in a spec, which is how every spec in this repo runs.
-- * A missing data file is not an error. The registry answers with what it has,
--   so a checkout without `data/mpi.lua` degrades to "no MPI documentation"
--   rather than to a stack trace on every keystroke.

local M = {}

--- Directory holding the generated tables, resolved from this module's path.
---@return string
local function data_dir()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  return vim.fn.fnamemodify(path, ":p:h") .. "/data"
end

local FILES = { "mpi", "openmp", "keywords" }

---@type table<string, table>|nil  file name -> raw table
local files = nil
---@type table<string, table>|nil  lname -> entry, merged in precedence order
local index = nil
---@type table<string, string>|nil lname -> "mpi"|"openmp"|"keyword"
local origin = nil
---@type table<string, table>|nil  lname -> entry, directives/clauses/modules only
local directives = nil

--- Load one generated table. Missing or broken file -> empty table.
---@param name string
---@return table
local function load_one(name)
  local path = data_dir() .. "/" .. name .. ".lua"
  local chunk = loadfile(path)
  if not chunk then
    return {}
  end
  local ok, t = pcall(chunk)
  if not ok or type(t) ~= "table" then
    return {}
  end
  return t
end

--- Load the three tables and build the indices. Idempotent; cached.
---@return table<string, table> files  name -> raw table
function M.load()
  if files then
    return files
  end
  files = {}
  index = {}
  origin = {}
  directives = {}
  local ORIGIN = { mpi = "mpi", openmp = "openmp", keywords = "keyword" }
  -- reverse precedence: later files must NOT overwrite earlier ones, so walk
  -- mpi -> openmp -> keywords and keep the first hit.
  for _, name in ipairs(FILES) do
    local t = load_one(name)
    files[name] = t
    for lname, entry in pairs(t) do
      if lname ~= "_meta" and type(entry) == "table" then
        local k = entry.kind
        -- Directives and clauses are reachable ONLY through M.directive().
        -- Off a directive line `if`, `do`, `private`, `reduction` and
        -- `critical` are Fortran words (or the user's variables), and letting
        -- the OpenMP entry win the general index is exactly the leak the old
        -- JSON had, where `K` on a plain `critical` showed OpenMP prose.
        local is_directive = name == "openmp" and (k == "directive" or k == "clause")
        if is_directive then
          directives[lname] = entry
        elseif name == "openmp" and k == "module" then
          directives[lname] = entry
          if index[lname] == nil then
            index[lname] = entry
            origin[lname] = ORIGIN[name]
          end
        elseif index[lname] == nil then
          index[lname] = entry
          origin[lname] = ORIGIN[name]
        end
      end
    end
  end
  return files
end

--- Drop every cache. Tests call this after writing a data file.
function M.reset()
  files, index, origin, directives = nil, nil, nil, nil
end

---@param name string|nil
---@return string|nil
local function fold(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  return name:lower()
end

--- Look up `name` anywhere, case-insensitively. Precedence mpi > openmp > keywords.
--- Never answers a directive or clause -- those live behind M.directive().
---@param name string|nil
---@return table|nil
function M.get(name)
  local l = fold(name)
  if not l then
    return nil
  end
  M.load()
  return index[l]
end

---@param name string|nil
---@return table|nil
function M.mpi(name)
  local l = fold(name)
  if not l then
    return nil
  end
  M.load()
  local t = files.mpi[l]
  return (l ~= "_meta") and t or nil
end

---@param name string|nil
---@return table|nil
function M.openmp(name)
  local l = fold(name)
  if not l then
    return nil
  end
  M.load()
  local t = files.openmp[l]
  return (l ~= "_meta") and t or nil
end

---@param name string|nil
---@return table|nil
function M.keyword(name)
  local l = fold(name)
  if not l then
    return nil
  end
  M.load()
  local t = files.keywords[l]
  return (l ~= "_meta") and t or nil
end

--- The entry for a word sitting on an OpenMP directive line.
---
--- Hover resolves `<cword>`, which on `!$OMP PARALLEL DO PRIVATE(i)` is ONE of
--- `OMP`, `PARALLEL`, `DO` or `PRIVATE`. So the directive set is keyed by
--- single words, and this is the only door into it: it never returns a runtime
--- routine, a Fortran keyword or anything from MPI, because on a directive line
--- `DO` names the worksharing construct and not the Fortran DO statement.
---
--- `END` names no construct of its own (`!$OMP END PARALLEL` is closing
--- PARALLEL), and `OMP` itself resolves to the `omp_lib` module entry, whose
--- documentation carries the fact most worth surfacing from a directive line:
--- without `-fopenmp` the whole line is a comment and the program runs serially.
---@param word string|nil
---@return table|nil
function M.directive(word)
  local l = fold(word)
  if not l or l == "end" then
    return nil
  end
  M.load()
  if l == "omp" then
    local e = directives.omp_lib
    return (e and e.kind == "module") and e or nil
  end
  return directives[l]
end

--- Every entry, sorted by lowercase key.
---@param kind_filter table<string, boolean>|nil set of kinds to keep
---@return table[]
function M.entries(kind_filter)
  M.load()
  local keys = {}
  for lname in pairs(index) do
    if kind_filter == nil or kind_filter[index[lname].kind] then
      keys[#keys + 1] = lname
    end
  end
  table.sort(keys)
  local out = {}
  for i, k in ipairs(keys) do
    out[i] = index[k]
  end
  return out
end

--- lname -> which file it came from. Feeds `highlight.words()`.
---@return table<string, string>
function M.names()
  M.load()
  local out = {}
  for lname, src in pairs(origin) do
    out[lname] = src
  end
  return out
end

--- Every procedure with an interface, in the shape `lsp_inlayhint` seeds from.
---
--- Replaces `mpi.SIGNATURES` and `openmp.SIGNATURES`: same shape, but the
--- argument names now come from the compiler's own symbol table rather than
--- from a hand-written list, which is what fixes the `MPI_Isend` argument-order
--- bug (`datatype` was third in the binding and fifth in the prose).
---@return table<string, {name: string, args: string[], builtin: boolean, result_type: string|nil}>
function M.signatures()
  M.load()
  local out = {}
  for lname, e in pairs(index) do
    if type(e.interface) == "table" and (e.kind == "subroutine" or e.kind == "function") then
      local args = {}
      for i, d in ipairs(e.interface) do
        args[i] = d.name
      end
      out[lname] = {
        name = e.name or lname,
        args = args,
        builtin = true,
        result_type = e.result_type,
      }
    end
  end
  return out
end

--- The `_meta` block of each data file.
---@return table<string, table>
function M.meta()
  M.load()
  return {
    mpi = files.mpi._meta or {},
    openmp = files.openmp._meta or {},
    keywords = files.keywords._meta or {},
  }
end

return M
