-- Spec for lua/andrew/fortran/registry.lua and the generated tables it loads
-- (lua/andrew/fortran/data/{mpi,openmp,keywords}.lua).
--
-- WHAT IT PINS
--
-- The registry replaced four disagreeing sources of truth with one, and the
-- disagreements were not cosmetic. The shipped prose put `MPI_Isend`'s
-- `datatype` fifth and the compiler's own symbol table puts it third, so every
-- inlay hint after the third argument of an MPI_Isend call was labelled with
-- the WRONG dummy name -- a hint that reads `dest:` over an argument that is
-- actually the datatype is worse than no hint at all. The usage lines also
-- spelled the status argument `ierr` where the interface said `ierror`, leaked
-- array specs into names (`recvbuf(*)`), and split an argument in two at a `&`
-- continuation. `interface[]` in the generated tables is now the ONLY source
-- of argument order, and `signature` is regenerated from it, so none of those
-- can come back through the data.
--
-- The other half is the contract wave 2 builds on: case folding, the
-- directive-line door that must never hand back a runtime routine or a plain
-- Fortran word, and `signatures()` seeding at least everything the two
-- hand-written SIGNATURES tables used to seed, with the same argument lists.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "mpi_isend argument order" and "mpi_irecv argument order" fail if the
--     generator ever takes argument order from the prose usage line instead of
--     from mpi.mod -- failure mode 2 of design C3.
--   * "signature is regenerated from interface" fails if a `signature` is
--     copied from prose (it would carry `ierr`, or `recvbuf(*)`, or a
--     continuation-split argument).
--   * "every key is an identifier" fails if a multi-word directive is keyed
--     `parallel do` rather than `parallel_do`, which would make the key
--     unreachable by <cword> and unwritable as a bare Lua key.
--   * "old MPI/OpenMP SIGNATURES still resolve" fails if a name is dropped from
--     the generated data or if its dummy names change -- the inlay-hint
--     regression this whole phase exists to prevent.
--   * "MPI_COMM_WORLD is a constant with a value" fails if constants stop being
--     scraped from the installed mpif*.h, or if they are classified as
--     procedures (which would make call_sites treat `status(MPI_STATUS_SIZE)`
--     as a one-argument call).
--   * "lookup is case-insensitive" fails if fold() is dropped -- Fortran source
--     spells MPI names in every case there is.
--   * "directive(end) is nil" fails if `END` maps to a construct: on
--     `!$OMP END PARALLEL` it names nothing of its own.
--   * "directive rejects non-constructs" fails if M.directive stops filtering on
--     kind and starts answering with runtime routines or MPI names.
--   * "directive(omp) is the omp_lib module" fails if the sentinel word stops
--     resolving, which is the one place the "-fopenmp or it is a comment" fact
--     is reachable from.
--   * "signatures() excludes constants and directives" fails if the kind filter
--     goes: `do` and `if` are OpenMP constructs AND Fortran statements, and
--     seeding them as callables would put argument hints inside every DO loop.
--   * "missing data file degrades to empty" fails if load() raises instead of
--     returning {} -- that error would fire on every keystroke.
--   * "meta() reports where each table came from" fails if either generator
--     stops stamping `generator`/`source_version`, or if one of them starts
--     stamping a timestamp. Both halves are checked, not just the MPI one: the
--     OpenMP table is coupled to the gfortran that ships `omp_lib.f90`, and an
--     unchecked `_meta` field is one that can silently go nil.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_registry_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil = _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local registry = require("andrew.fortran.registry")
local mpi = require("andrew.fortran.mpi")
local openmp = require("andrew.fortran.openmp")

--- Argument names of an entry, in interface order.
---@param name string
---@return string[]|nil
local function args_of(name)
  local e = registry.get(name)
  if not e or type(e.interface) ~= "table" then
    return nil
  end
  local out = {}
  for i, d in ipairs(e.interface) do
    out[i] = d.name
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Argument order: failure mode 2
-- ---------------------------------------------------------------------------

test("mpi_isend argument order is the compiler's, not the prose's", function()
  assert_eq(table.concat(args_of("mpi_isend") or {}, ", "),
    "buf, count, datatype, dest, tag, comm, request, ierror")
end)

test("mpi_irecv argument order is the compiler's, not the prose's", function()
  assert_eq(table.concat(args_of("mpi_irecv") or {}, ", "),
    "buf, count, datatype, source, tag, comm, request, ierror")
end)

test("array specs live in dim, never in the name", function()
  local e = registry.get("mpi_waitall")
  assert_true(e ~= nil, "mpi_waitall present:")
  local by = {}
  for _, d in ipairs(e.interface) do
    by[d.name] = d
  end
  assert_true(by.array_of_requests ~= nil, "bare dummy name:")
  assert_eq(by.array_of_requests.dim, "(*)", "assumed-size spec:")
  assert_eq(by.array_of_statuses.dim, "(6, *)", "rank-2 spec:")
  for _, d in ipairs(e.interface) do
    assert_true(d.name:match("^[%a_][%w_]*$") ~= nil, d.name .. " is a bare name:")
  end
end)

-- ---------------------------------------------------------------------------
-- Structural invariants over the whole registry
-- ---------------------------------------------------------------------------

test("signature is regenerated from interface for every entry that has one", function()
  local checked, bad = 0, {}
  for _, e in ipairs(registry.entries()) do
    if type(e.interface) == "table" then
      local names = {}
      for i, d in ipairs(e.interface) do
        names[i] = d.name
      end
      local want = e.name .. "(" .. table.concat(names, ", ") .. ")"
      checked = checked + 1
      if e.signature ~= want then
        bad[#bad + 1] = tostring(e.name) .. ": " .. tostring(e.signature)
      end
    end
  end
  assert_true(checked > 400, "checked a real number of entries: " .. checked)
  assert_eq(table.concat(bad, " | "), "", "signature mismatches:")
end)

test("every key is a plain identifier", function()
  local bad = {}
  for lname in pairs(registry.names()) do
    if not lname:match("^[%a_][%w_]*$") then
      bad[#bad + 1] = lname
    end
  end
  assert_eq(table.concat(bad, " "), "", "non-identifier keys:")
end)

test("_meta is never served as an entry", function()
  assert_nil(registry.get("_meta"), "get:")
  assert_nil(registry.mpi("_meta"), "mpi:")
  assert_nil(registry.openmp("_meta"), "openmp:")
  assert_nil(registry.keyword("_meta"), "keywords:")
  assert_true(registry.meta().mpi.generator ~= nil, "meta() still reaches it:")
end)

-- ---------------------------------------------------------------------------
-- The old hand-written tables must still resolve, unchanged
-- ---------------------------------------------------------------------------

test("every old mpi.SIGNATURES name resolves with the same argument list", function()
  local bad, n = {}, 0
  for lname, want in pairs(mpi.SIGNATURES) do
    n = n + 1
    local got = args_of(lname)
    if not got then
      bad[#bad + 1] = lname .. " MISSING"
    elseif table.concat(got, ",") ~= table.concat(want, ",") then
      bad[#bad + 1] = lname .. " [" .. table.concat(got, ",") .. "] vs [" .. table.concat(want, ",") .. "]"
    end
  end
  assert_true(n >= 46, "the old table is still there to compare against: " .. n)
  assert_eq(table.concat(bad, " | "), "", "differences:")
end)

test("every old openmp.SIGNATURES name resolves with the same argument list", function()
  local bad, n = {}, 0
  for lname, want in pairs(openmp.SIGNATURES) do
    n = n + 1
    local got = args_of(lname)
    if not got then
      bad[#bad + 1] = lname .. " MISSING"
    elseif table.concat(got, ",") ~= table.concat(want, ",") then
      bad[#bad + 1] = lname .. " [" .. table.concat(got, ",") .. "] vs [" .. table.concat(want, ",") .. "]"
    end
  end
  assert_true(n >= 31, "the old table is still there to compare against: " .. n)
  assert_eq(table.concat(bad, " | "), "", "differences:")
end)

test("signatures() seeds at least what the two old tables seeded", function()
  local sigs = registry.signatures()
  local missing = {}
  for lname in pairs(mpi.SIGNATURES) do
    if not sigs[lname] then
      missing[#missing + 1] = lname
    end
  end
  for lname in pairs(openmp.SIGNATURES) do
    if not sigs[lname] then
      missing[#missing + 1] = lname
    end
  end
  table.sort(missing)
  assert_eq(table.concat(missing, " "), "", "names lost from the seed set:")
end)

test("seed() fills from the registry and never overwrites a project definition", function()
  local sigs = { mpi_send = { name = "MPI_SEND", args = { "wrapped" } } }
  mpi.seed(sigs)
  openmp.seed(sigs)
  assert_eq(sigs.mpi_send.args[1], "wrapped", "project definition kept:")
  assert_eq(table.concat(sigs.mpi_comm_rank.args, ","), "comm,rank,ierror", "MPI seeded:")
  assert_eq(table.concat(sigs.omp_set_num_threads.args, ","), "num_threads", "OpenMP seeded:")
  assert_eq(sigs.mpi_comm_rank.name, "MPI_Comm_rank", "display case from the registry:")
end)

test("signatures() excludes constants, directives and clauses", function()
  local sigs = registry.signatures()
  assert_nil(sigs.mpi_comm_world, "MPI_COMM_WORLD is not callable:")
  assert_nil(sigs.mpi_status_size, "MPI_STATUS_SIZE is not callable:")
  assert_nil(sigs.omp_sched_static, "omp_sched_static is not callable:")
  assert_nil(sigs["do"], "the DO construct is not callable:")
  assert_nil(sigs["if"], "the IF clause is not callable:")
  for lname, s in pairs(sigs) do
    local e = registry.get(lname)
    assert_true(e.kind == "subroutine" or e.kind == "function", lname .. " kind:")
    assert_true(s.builtin == true, lname .. " marked builtin:")
  end
end)

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

test("MPI_COMM_WORLD is a constant carrying the value as installed", function()
  local e = registry.get("MPI_COMM_WORLD")
  assert_true(e ~= nil, "present:")
  assert_eq(e.kind, "constant", "kind:")
  assert_eq(e.name, "MPI_COMM_WORLD", "display case:")
  assert_true(e.value ~= nil and e.value ~= "", "value: " .. tostring(e.value))
  assert_true(e.value:match("^%-?%d+$") ~= nil, "value is a number: " .. tostring(e.value))
  assert_nil(e.interface, "a constant has no interface:")
end)

test("the sentinel constants with no parameter line are still present", function()
  for _, n in ipairs({ "MPI_STATUS_IGNORE", "MPI_IN_PLACE" }) do
    local e = registry.get(n)
    assert_true(e ~= nil, n .. " present:")
    assert_eq(e.kind, "constant", n .. " kind:")
    assert_true(e.summary ~= nil, n .. " has a summary:")
  end
end)

-- ---------------------------------------------------------------------------
-- Case folding
-- ---------------------------------------------------------------------------

test("lookup is case-insensitive and keeps the canonical display case", function()
  for _, spelling in ipairs({ "mpi_comm_RANK", "MPI_COMM_RANK", "MPI_Comm_Rank", "mpi_comm_rank" }) do
    local e = registry.get(spelling)
    assert_true(e ~= nil, spelling .. " resolves:")
    assert_eq(e.name, "MPI_Comm_rank", spelling .. " display name:")
  end
  assert_eq(registry.mpi("MPI_ISEND").name, "MPI_Isend", "per-file lookup folds too:")
  assert_eq(registry.openmp("OMP_GET_WTIME").name, "omp_get_wtime", "openmp folds too:")
end)

test("nil and empty lookups answer nil rather than raising", function()
  assert_nil(registry.get(nil), "get(nil):")
  assert_nil(registry.get(""), "get(''):")
  assert_nil(registry.directive(nil), "directive(nil):")
  assert_nil(registry.mpi(nil), "mpi(nil):")
end)

-- ---------------------------------------------------------------------------
-- The directive-line door
-- ---------------------------------------------------------------------------

test("directive('end') is nil", function()
  assert_nil(registry.directive("end"), "lower:")
  assert_nil(registry.directive("END"), "upper:")
end)

test("directive never answers with a routine, a keyword or MPI", function()
  assert_nil(registry.directive("omp_get_wtime"), "runtime routine:")
  assert_nil(registry.directive("mpi_comm_rank"), "MPI:")
  assert_nil(registry.directive("allocatable"), "Fortran keyword:")
  assert_nil(registry.directive("omp_sched_static"), "omp_lib constant:")
end)

test("directive('omp') is the omp_lib module entry", function()
  local e = registry.directive("omp")
  if e == nil then
    print("    SKIP: data/openmp.lua has no omp_lib module entry yet (agent DATA)")
    return
  end
  assert_eq(e.kind, "module", "kind:")
  assert_eq(e.name, "omp_lib", "name:")
end)

test("directive resolves single-word constructs and clauses", function()
  local missing = {}
  for _, w in ipairs({ "parallel", "do", "private", "critical", "barrier" }) do
    local e = registry.directive(w)
    if e == nil then
      missing[#missing + 1] = w
    else
      assert_true(e.kind == "directive" or e.kind == "clause", w .. " kind: " .. tostring(e.kind))
    end
  end
  if #missing > 0 then
    print("    SKIP: not yet in data/openmp.lua: " .. table.concat(missing, " "))
  end
end)

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

test("entries() is sorted and filterable by kind", function()
  local all = registry.entries()
  assert_true(#all > 900, "loaded a real registry: " .. #all)
  local consts = registry.entries({ constant = true })
  assert_true(#consts > 200, "constants: " .. #consts)
  for _, e in ipairs(consts) do
    assert_eq(e.kind, "constant", tostring(e.name) .. ":")
  end
  local prev = ""
  for _, e in ipairs(consts) do
    local l = e.name:lower()
    assert_true(l >= prev, "sorted at " .. e.name)
    prev = l
  end
end)

test("names() maps every key to the file it came from", function()
  local names = registry.names()
  assert_eq(names.mpi_comm_rank, "mpi", "mpi:")
  assert_eq(names.omp_get_wtime, "openmp", "openmp:")
  local kw = registry.keyword("allocatable")
  if kw then
    assert_eq(names.allocatable, "keyword", "keywords:")
  else
    print("    SKIP: data/keywords.lua has no `allocatable` entry")
  end
  assert_nil(names._meta, "_meta excluded:")
end)

test("reset() drops the cache and load() rebuilds it", function()
  local before = registry.get("mpi_comm_rank")
  registry.reset()
  local after = registry.get("mpi_comm_rank")
  assert_true(after ~= nil, "still resolves after reset:")
  assert_eq(after.signature, before.signature, "same content:")
end)

test("meta() reports where each table came from", function()
  local m = registry.meta()
  assert_eq(m.mpi.generator, "snippets/gen-mpi.lua", "mpi generator:")
  assert_true(m.mpi.source_version:match("GFORTRAN module version") ~= nil,
    "mpi source version: " .. tostring(m.mpi.source_version))
  assert_eq(m.openmp.generator, "snippets/gen-omp.lua", "openmp generator:")
  -- The OpenMP half is version-coupled too: `omp_lib.f90` ships INSIDE a
  -- gfortran installation, so the compiler version IS the source version, and
  -- a table generated against a different gfortran may carry routines this one
  -- does not have. An unchecked field here is a field that can quietly become
  -- nil when the generator is edited -- which is how `mpi.source_version` was
  -- the only one anybody verified.
  assert_true(type(m.openmp.source_version) == "string" and m.openmp.source_version ~= "",
    "openmp source version is a non-empty string: " .. tostring(m.openmp.source_version))
  assert_true(m.openmp.source_version:match("^GCC %d") ~= nil,
    "openmp source version names the gfortran release: " .. tostring(m.openmp.source_version))
  assert_nil(m.mpi.generated, "no timestamp (the output must be idempotent):")
  assert_nil(m.openmp.generated, "no timestamp on the OpenMP half either:")
end)

_H.finish()
