-- =============================================================================
-- MPI support for Fortran: include discovery + builtin signatures
-- =============================================================================
--
-- WHY THIS EXISTS
--
-- This project brings MPI in the Fortran 77 way -- `INCLUDE 'mpif.h'`, 229
-- files of it -- and `mpif.h` ships with the MPI installation, not with the
-- source. Nothing in the project tree resolves it, so gfortran hit
--
--     Share-EAM.f90:5:0: Fatal Error: Cannot open included file 'mpif.h'
--     compilation terminated.
--
-- and STOPPED. Not "missed some checks": a fatal error terminates the parse,
-- so every MPI file in the tree showed exactly one diagnostic, that diagnostic
-- was false (the code builds fine under the cluster's mpif90), and it masked
-- everything else the compiler would have said. Adding the include directory
-- took one file from 2 lines of compiler output to 313.
--
-- The obvious fix -- lint with the `mpif90` wrapper, which supplies its own
-- include path -- does NOT work here. The conda Intel-MPI package ships the
-- wrapper with its install prefix unsubstituted:
--
--     $ mpif90 -show
--     gfortran -I"I_MPI_SUBSTITUTE_INSTALLDIR/include" ...
--     $ mpiifort -show
--     mpiifort: line 45: mpiifx: command not found
--
-- so both wrappers are broken and an explicit `-I` is the only route that
-- works. That is what `M.include_dirs()` finds.
--
-- WHAT DOES *NOT* LEAK OUT OF THIS
--
-- `mpif.h` is 651 lines of PARAMETER declarations and gfortran warns about
-- 294 of them as unused. Those never reach a buffer: `parsers.gcc` in
-- linting.lua keeps only diagnostics whose basename matches the linted file.
-- Verified end to end -- with the include path set, Share-EAM.f90 gets 12
-- diagnostics, none of them from mpif.h.
--
-- ON THE SIGNATURE TABLE
--
-- andrew.fortran.lsp_inlayhint builds its argument-name index from a ripgrep
-- pass over the PROJECT, so MPI routines -- declared in the library, never in
-- the source -- got no hints at all. They are the best possible case for the
-- feature: `MPI_BCAST(crita, 1, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD,
-- ierr)` is six positional arguments with a trailing status code and no
-- keyword arguments anywhere in F77. Names below follow the MPI standard's
-- Fortran binding.
--
-- Project definitions WIN over this table: a project that defines its own
-- `MPI_SEND` wrapper should get the wrapper's real dummy names, so seeding
-- happens after the project scan and only fills gaps.

local M = {}

-- ---------------------------------------------------------------------------
-- Include discovery
-- ---------------------------------------------------------------------------

--- Directories to test for `mpif.h`, most specific first.
---
--- Environment variables come first because a user who set one meant it. The
--- active conda prefix comes before the sibling environments, which are
--- globbed because MPI commonly lives in an env that is not the active one --
--- here it is `envs/hpc` while nvim runs from the base environment.
---@return string[]
function M.candidates()
  local out = {}
  local function add(p)
    if p and p ~= "" then
      out[#out + 1] = p
    end
  end

  for _, var in ipairs({ "I_MPI_ROOT", "MPI_HOME", "MPI_ROOT", "MPICH_DIR", "OPAL_PREFIX" }) do
    local v = vim.env[var]
    if v and v ~= "" then
      add(v .. "/include")
    end
  end

  add(vim.env.CONDA_PREFIX and (vim.env.CONDA_PREFIX .. "/include") or nil)

  -- Sibling conda environments. vim.fn.glob with a nil-safe expand keeps this
  -- working when no conda is installed at all.
  for _, root in ipairs({ "~/miniconda3/envs", "~/anaconda3/envs", "~/mambaforge/envs", "~/miniforge3/envs" }) do
    local expanded = vim.fn.expand(root)
    if vim.fn.isdirectory(expanded) == 1 then
      for _, env in ipairs(vim.fn.glob(expanded .. "/*", false, true)) do
        add(env .. "/include")
      end
    end
  end

  for _, p in ipairs({
    "/usr/lib/x86_64-linux-gnu/openmpi/include",
    "/usr/lib/x86_64-linux-gnu/mpich/include",
    "/usr/include/x86_64-linux-gnu/mpich",
    "/usr/include/openmpi",
    "/usr/include/mpich",
    "/usr/include/mpi",
    "/usr/local/include",
    "/usr/include",
    "/opt/intel/oneapi/mpi/latest/include",
  }) do
    add(p)
  end

  return out
end

--- Filter `cands` down to those that actually hold an `mpif.h`, preserving
--- order and dropping duplicates.
---
--- Split out from `include_dirs` so it can be driven with a stub `readable`
--- in a spec without touching the filesystem.
---@param cands string[]
---@param readable fun(path: string): boolean
---@param limit integer|nil stop after this many hits (default 1)
---@return string[]
function M.discover(cands, readable, limit)
  limit = limit or 1
  local out, seen = {}, {}
  for _, dir in ipairs(cands) do
    if not seen[dir] then
      seen[dir] = true
      if readable(dir .. "/mpif.h") then
        out[#out + 1] = dir
        if #out >= limit then
          return out
        end
      end
    end
  end
  return out
end

local cached_dirs = nil

--- Include directories that supply `mpif.h`, memoized.
---
--- `vim.g.fortran_mpi_include_dirs` overrides discovery entirely (set it to an
--- empty table to disable this feature). Only the FIRST hit is returned:
--- two MPI implementations on one include path is a way to get a subtly wrong
--- `MPI_STATUS_SIZE`, not a way to be thorough.
---@return string[]
function M.include_dirs()
  local override = vim.g.fortran_mpi_include_dirs
  if type(override) == "table" then
    return override
  end
  if cached_dirs then
    return cached_dirs
  end
  cached_dirs = M.discover(M.candidates(), function(p)
    return vim.fn.filereadable(p) == 1
  end)
  return cached_dirs
end

--- Drop the memoized discovery result. `:FortranMpiRescan` calls this.
function M.invalidate()
  cached_dirs = nil
end

--- True when `name` -- a filename exactly as the compiler spelled it -- is a
--- header supplied by the MPI installation rather than by the project.
---
--- Needed because gfortran reports a diagnostic inside an INCLUDE with the
--- name AS WRITTEN in the source and no directory at all:
---
---     mpif.h:372:36: Warning: Unused parameter 'mpi_2double_precision' ...
---
--- The per-buffer lint path drops those by comparing basenames with the file
--- being linted, but `:FortranLintWorkspace` groups by reported name and calls
--- `vim.fn.bufnr(name, true)`, which would MANUFACTURE an empty buffer called
--- `mpif.h` in the project root and hang 294 diagnostics off lines it does not
--- have. That regression arrives with the include path, not before it.
---
--- Resolving `name` against the project root instead is wrong: `common.h`
--- comes back equally bare and lives in `code/`, so a project-root test would
--- discard real diagnostics.
---
--- A project file of the same name always wins, so a project that ships its
--- own `mpif.h` keeps its diagnostics.
---@param name string
---@param mpi_dirs string[]
---@param project_dirs string[] directories a project header could live in
---@param readable fun(path: string): boolean
---@return boolean
function M.is_external_header(name, mpi_dirs, project_dirs, readable)
  if type(name) ~= "string" or name == "" then
    return false
  end
  -- An absolute path answers the question by itself.
  if name:sub(1, 1) == "/" then
    for _, d in ipairs(mpi_dirs) do
      if name:sub(1, #d + 1) == d .. "/" then
        return true
      end
    end
    return false
  end
  for _, d in ipairs(project_dirs) do
    if readable(d .. "/" .. name) then
      return false
    end
  end
  for _, d in ipairs(mpi_dirs) do
    if readable(d .. "/" .. name) then
      return true
    end
  end
  return false
end

--- `is_external_header` bound to the real filesystem and the discovered dirs.
---@param name string
---@param project_root string
---@return boolean
function M.is_external(name, project_root)
  return M.is_external_header(name, M.include_dirs(), {
    project_root,
    project_root .. "/code",
  }, function(path)
    return vim.fn.filereadable(path) == 1
  end)
end

-- ---------------------------------------------------------------------------
-- Builtin signatures
-- ---------------------------------------------------------------------------

--- Dummy-argument names for the MPI Fortran binding, keyed by LOWERCASE name.
---
--- Scope: the routines this project actually calls, plus the immediate
--- neighbours of each (if MPI_SEND is here, MPI_ISEND belongs here too -- the
--- cost is one line and the alternative is a hint that vanishes the day
--- someone switches to the non-blocking form).
---
--- Constants (MPI_COMM_WORLD, MPI_DOUBLE_PRECISION, MPI_STATUS_SIZE, ...) are
--- deliberately absent: they are PARAMETERs, never called, and an entry here
--- would make `call_sites` treat `MPI_STATUS_SIZE` in `INTEGER
--- status(MPI_STATUS_SIZE)` as a call with one argument. They get hover
--- documentation instead.
---@type table<string, string[]>
M.SIGNATURES = {
  -- Environment
  mpi_init = { "ierror" },
  mpi_init_thread = { "required", "provided", "ierror" },
  mpi_finalize = { "ierror" },
  mpi_abort = { "comm", "errorcode", "ierror" },
  mpi_initialized = { "flag", "ierror" },
  mpi_get_processor_name = { "name", "resultlen", "ierror" },

  -- Communicators
  mpi_comm_rank = { "comm", "rank", "ierror" },
  mpi_comm_size = { "comm", "size", "ierror" },
  mpi_comm_dup = { "comm", "newcomm", "ierror" },
  mpi_comm_split = { "comm", "color", "key", "newcomm", "ierror" },
  mpi_comm_free = { "comm", "ierror" },
  mpi_comm_group = { "comm", "group", "ierror" },

  -- Point to point
  mpi_send = { "buf", "count", "datatype", "dest", "tag", "comm", "ierror" },
  mpi_recv = { "buf", "count", "datatype", "source", "tag", "comm", "status", "ierror" },
  mpi_isend = { "buf", "count", "datatype", "dest", "tag", "comm", "request", "ierror" },
  mpi_irecv = { "buf", "count", "datatype", "source", "tag", "comm", "request", "ierror" },
  mpi_ssend = { "buf", "count", "datatype", "dest", "tag", "comm", "ierror" },
  mpi_bsend = { "buf", "count", "datatype", "dest", "tag", "comm", "ierror" },
  mpi_sendrecv = {
    "sendbuf", "sendcount", "sendtype", "dest", "sendtag",
    "recvbuf", "recvcount", "recvtype", "source", "recvtag",
    "comm", "status", "ierror",
  },
  mpi_get_count = { "status", "datatype", "count", "ierror" },
  mpi_probe = { "source", "tag", "comm", "status", "ierror" },
  mpi_iprobe = { "source", "tag", "comm", "flag", "status", "ierror" },
  mpi_wait = { "request", "status", "ierror" },
  mpi_waitall = { "count", "array_of_requests", "array_of_statuses", "ierror" },
  mpi_waitany = { "count", "array_of_requests", "index", "status", "ierror" },
  mpi_test = { "request", "flag", "status", "ierror" },
  mpi_request_free = { "request", "ierror" },

  -- Collectives
  mpi_barrier = { "comm", "ierror" },
  mpi_bcast = { "buffer", "count", "datatype", "root", "comm", "ierror" },
  mpi_reduce = { "sendbuf", "recvbuf", "count", "datatype", "op", "root", "comm", "ierror" },
  mpi_allreduce = { "sendbuf", "recvbuf", "count", "datatype", "op", "comm", "ierror" },
  mpi_scan = { "sendbuf", "recvbuf", "count", "datatype", "op", "comm", "ierror" },
  mpi_gather = {
    "sendbuf", "sendcount", "sendtype",
    "recvbuf", "recvcount", "recvtype", "root", "comm", "ierror",
  },
  mpi_gatherv = {
    "sendbuf", "sendcount", "sendtype",
    "recvbuf", "recvcounts", "displs", "recvtype", "root", "comm", "ierror",
  },
  mpi_allgather = {
    "sendbuf", "sendcount", "sendtype",
    "recvbuf", "recvcount", "recvtype", "comm", "ierror",
  },
  mpi_allgatherv = {
    "sendbuf", "sendcount", "sendtype",
    "recvbuf", "recvcounts", "displs", "recvtype", "comm", "ierror",
  },
  mpi_scatter = {
    "sendbuf", "sendcount", "sendtype",
    "recvbuf", "recvcount", "recvtype", "root", "comm", "ierror",
  },
  mpi_scatterv = {
    "sendbuf", "sendcounts", "displs", "sendtype",
    "recvbuf", "recvcount", "recvtype", "root", "comm", "ierror",
  },
  mpi_alltoall = {
    "sendbuf", "sendcount", "sendtype",
    "recvbuf", "recvcount", "recvtype", "comm", "ierror",
  },

  -- Derived types
  mpi_type_contiguous = { "count", "oldtype", "newtype", "ierror" },
  mpi_type_vector = { "count", "blocklength", "stride", "oldtype", "newtype", "ierror" },
  mpi_type_commit = { "datatype", "ierror" },
  mpi_type_free = { "datatype", "ierror" },
  mpi_type_size = { "datatype", "size", "ierror" },

  -- Timing (functions, no dummy arguments -- present so `call_sites` knows
  -- the name, which costs nothing and keeps the table a complete answer to
  -- "is this an MPI routine")
  mpi_wtime = {},
  mpi_wtick = {},
}

--- Fill `sigs` with any builtin not already defined by the project.
---
--- Called at the END of the project scan, so a project-defined wrapper always
--- wins over the standard binding.
---
--- The argument names come from `andrew.fortran.registry`, which generates them
--- from the installed `mpi.mod` -- the compiler's own symbol table -- rather
--- than from the table above. That matters: the hand-written list was built
--- from the shipped prose, and the prose had `MPI_Isend`'s `datatype` in the
--- wrong position, so every hint after the third argument of an MPI_Isend call
--- was labelled with the wrong dummy. SIGNATURES stays as the fallback for a
--- checkout with no generated data, and because other callers read it.
---@param sigs table<string, table>
---@return table<string, table> the same table, mutated
function M.seed(sigs)
  local ok, registry = pcall(require, "andrew.fortran.registry")
  if ok then
    local origin = registry.names()
    local seeded = false
    for lname, sig in pairs(registry.signatures()) do
      if origin[lname] == "mpi" then
        seeded = true
        if not sigs[lname] then
          sigs[lname] = { name = sig.name, args = sig.args, builtin = true }
        end
      end
    end
    if seeded then
      return sigs
    end
  end
  for lname, args in pairs(M.SIGNATURES) do
    if not sigs[lname] then
      sigs[lname] = { name = lname:upper(), args = args, builtin = true }
    end
  end
  return sigs
end

return M
