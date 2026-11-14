-- =============================================================================
-- OpenMP support for Fortran
-- =============================================================================
--
-- SCOPE, HONESTLY STATED
--
-- A survey of every Fortran file in this user's trees on 2026-09-06 found
-- ZERO OpenMP: no `!$OMP` directives, no `omp_*` runtime calls, no
-- `USE omp_lib`. The only OpenMP on the machine is inside CHARMM and LAMMPS,
-- which are third-party and never edited here. This module was added anyway,
-- deliberately and with that known, so the tooling is already correct on the
-- day the first directive is written rather than silently wrong.
--
-- WHAT `-fopenmp` BUYS
--
-- Without it gfortran treats `!$OMP` as an ordinary comment, so a malformed
-- directive is silently ignored -- the worst failure mode available, because
-- the code then compiles and runs single-threaded. With it the directive is
-- parsed:
--
--     !$OMP PARALLEL DO PRIVATE(I) BOGUSCLAUSE(N)
--     Error: Failed to match clause at (1)
--     Error: Unexpected !$OMP END PARALLEL DO statement at (1)
--
-- Two notes on the flag. It implies `-frecursive`, which suppresses the
-- `-Wsurprising` "moved from stack to static storage" warnings -- that is a
-- real change to this project's current output, and it is the correct one,
-- since those warnings describe a hazard that only matters under threading.
-- And under `-fsyntax-only` no OpenMP runtime is linked, so the flag is free
-- for a project that has no OpenMP at all.
--
-- The `omp_*` signatures below feed andrew.fortran.lsp_inlayhint through the
-- same seeding path as the MPI ones; see andrew.fortran.mpi for why builtins
-- are seeded after the project scan rather than before it.
--
-- WHAT IS NOT HERE ANY MORE
--
-- `doc_keys` and `best_key` used to map a word on a directive line onto a key
-- of snippets/fortran-docs.json, trying both the `omp_<w>` and `omp<w>`
-- spellings and breaking the tie on body length. Nothing needs them now:
-- `registry.directive(word)` is the one door onto directive and clause
-- documentation, and hover (lsp_hover), completion (lsp_completion) and the
-- highlighter (highlight.paint_directive) all go through it. `is_directive`
-- stays, because deciding WHETHER a line is a directive line is still this
-- module's job -- and it is the one place that knows `!$acc` belongs to
-- OpenACC and not to us (see `M.sentinel`).

local M = {}

--- Dummy-argument names for the OpenMP Fortran runtime (`omp_lib`), keyed by
--- LOWERCASE name. Zero-argument queries are present with an empty list for
--- the same reason as MPI_WTIME: naming the routine costs one line and makes
--- the table a complete answer.
---@type table<string, string[]>
M.SIGNATURES = {
  -- Thread team
  omp_set_num_threads = { "num_threads" },
  omp_get_num_threads = {},
  omp_get_max_threads = {},
  omp_get_thread_num = {},
  omp_get_num_procs = {},
  omp_in_parallel = {},
  omp_get_thread_limit = {},

  -- Nesting and levels
  omp_set_dynamic = { "dynamic_threads" },
  omp_get_dynamic = {},
  omp_set_nested = { "nested" },
  omp_get_nested = {},
  omp_set_max_active_levels = { "max_levels" },
  omp_get_max_active_levels = {},
  omp_get_level = {},
  omp_get_active_level = {},
  omp_get_ancestor_thread_num = { "level" },
  omp_get_team_size = { "level" },

  -- Scheduling
  omp_set_schedule = { "kind", "chunk_size" },
  omp_get_schedule = { "kind", "chunk_size" },

  -- Locks
  omp_init_lock = { "svar" },
  omp_destroy_lock = { "svar" },
  omp_set_lock = { "svar" },
  omp_unset_lock = { "svar" },
  omp_test_lock = { "svar" },
  omp_init_nest_lock = { "nvar" },
  omp_destroy_nest_lock = { "nvar" },
  omp_set_nest_lock = { "nvar" },
  omp_unset_nest_lock = { "nvar" },
  omp_test_nest_lock = { "nvar" },

  -- Timing
  omp_get_wtime = {},
  omp_get_wtick = {},
}

--- Fill `sigs` with any builtin not already defined by the project.
---
--- Names and argument lists come from `andrew.fortran.registry`, generated from
--- gfortran's own `omp_lib.f90`, which covers all 102 runtime routines rather
--- than the 31 hand-listed below and carries their real intents. SIGNATURES
--- stays as the fallback for a checkout with no generated data.
---@param sigs table<string, table>
---@return table<string, table> the same table, mutated
function M.seed(sigs)
  local ok, registry = pcall(require, "andrew.fortran.registry")
  if ok then
    local origin = registry.names()
    local seeded = false
    for lname, sig in pairs(registry.signatures()) do
      if origin[lname] == "openmp" then
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
      sigs[lname] = { name = lname, args = args, builtin = true }
    end
  end
  return sigs
end

--- Which OpenMP sentinel opens `line`, and where it ends.
---
--- OpenMP 5.2 §3.2.2 spells both sentinels as TOKENS, not as prefixes:
---
---   * the directive sentinel is `!$omp` (fixed form also `C$OMP` / `*$OMP` in
---     columns 1-5) followed by a boundary -- a space in free form, a space or
---     the continuation character in column 6 in fixed form;
---   * the conditional-compilation sentinel is `!$` / `C$` / `*$` followed by
---     a space, a tab, or the end of the line. It turns the REST of the line
---     into live Fortran under -fopenmp and leaves it a comment without, so
---     the same source is two programs depending on a flag.
---
--- Requiring that boundary is the whole point of this function. `!$` is not a
--- reserved prefix: `!$acc parallel loop` is OpenACC, `!$ACC DATA` likewise,
--- `!$dir` is somebody else's directive and `!$x=1` is nothing at all. A
--- prefix-only test read every one of them as OpenMP, and hover, completion
--- and the highlighter each take a directive line to be a CLOSED WORLD -- so
--- on an OpenACC line hover answered from the OpenMP clause index, completion
--- offered OpenMP clauses, and the sentinel was painted as ours.
---@param line string
---@return "directive"|"conditional"|nil kind
---@return integer|nil send 1-based byte index of the sentinel's `$`
function M.sentinel(line)
  if type(line) ~= "string" then
    return nil
  end
  -- The sentinel must be the first non-blank text: `x = 1 !$OMP` is a comment.
  local _, send = line:find("^%s*[!cC%*]%$")
  if not send then
    return nil
  end
  local rest = line:sub(send + 1)
  -- `omp` as a whole token. `!$ompx` (the vendor-extension sentinel) and
  -- `!$acc` are deliberately not ours.
  if rest:match("^[oO][mM][pP]$") or rest:match("^[oO][mM][pP][^%w_]") then
    return "directive", send
  end
  if rest == "" or rest:match("^[ \t]") then
    return "conditional", send
  end
  return nil
end

--- True when `line` carries an OpenMP conditional-compilation sentinel or
--- directive.
---
--- The one shared predicate: hover (`lsp_hover`), completion
--- (`lsp_completion.code_view` / `directive_context`), signature help and the
--- highlighter (`highlight.paint_directive`) all gate on this, so any line it
--- accepts is an OpenMP line for all four. See `M.sentinel` for the rule.
---@param line string
---@return boolean
function M.is_directive(line)
  return M.sentinel(line) ~= nil
end

return M
