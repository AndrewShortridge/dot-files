-- Spec for lua/andrew/fortran/lsp_callhierarchy.lua -- the callHierarchy
-- provider behind `gai` / `gao` in a Fortran buffer.
--
-- WHAT IT PINS
--
-- fortls has no callHierarchyProvider, so this module is the only thing
-- answering those two keymaps. A call hierarchy is not a list of call sites:
-- it is call sites GROUPED BY the program unit on either end, and every hard
-- part of that is Fortran-specific.
--
--   1. `Foo(x)` is a function call or an array subscript depending on nothing
--      but whether the project defines a procedure called Foo. An unfiltered
--      paren scan turns `arr(3)` into an outgoing call.
--   2. A definition header is its OWN paren candidate: `subroutine Heating(t)`
--      matches `Heating(` at exactly the column of the definition, so without
--      a position filter every procedure calls itself once.
--   3. `call Foo(x)` is found twice by the project scan -- once by the `call`
--      keyword pass, once by the paren pass -- at one position.
--   4. Outgoing `fromRanges` live in the CALLER's document, not the callee's.
--   5. A CONTAINS-ed procedure's calls belong to it, not to its host.
--   6. `call` in a comment is not a call; `call &` puts the callee on the next
--      line; `CALL HEATING` and `call Heating` are one procedure but keep
--      their own source spelling.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * build_spans stops reading the closing line off scan.nesting_depths
--     (`last = d.lnum`): 9 tests fail -- every unit collapses to its header,
--     so no call site is inside any unit any more.
--   * prepare answers a call site from the buffer instead of resolving it
--     through the project definition index: "prepare on a call site" and
--     "prepare on a paren reference" fail -- the item's uri points at the
--     CALLER, and `Energy(t)` stops being recognised at all.
--   * prepare's PROC_KINDS gate on a definition removed: "prepare on a
--     non-procedure" fails -- a `module` header becomes a hierarchy subject.
--   * prepare accepts a paren candidate with no project definition:
--     "prepare on a paren reference" fails -- `arr(3)` becomes a call.
--   * incoming's grouping key drops the enclosing unit (`key = site.path`):
--     "incoming groups call sites" fails -- Step and Drive collapse into one
--     entry because they share a file.
--   * ensure_calls drops the definition-position filter: 4 tests fail --
--     `subroutine Heating(t)` reports Heating as its own caller.
--   * ensure_calls drops the position seen-set: "incoming reports one range
--     per call site" fails at 7 ranges for 4 call sites -- `call Foo(x)` is
--     counted once by the `call` pass and once by the paren pass.
--   * outgoing's enclosing-unit test weakened to a line range: "outgoing stops
--     at CONTAINS" fails -- Inner's `call Report` is attributed to Main.
--   * local_sites stops filtering paren candidates by the project's procedure
--     names: 3 tests fail -- `arr(10)`, `arr(3)` and `real(8)` become calls.
--   * local_sites drops its definition-position filter: 3 tests fail -- every
--     procedure gains a call to itself from its own header.
--   * outgoing takes fromRanges from the callee's definition instead of the
--     call site: 3 tests fail -- the ranges land in physics.f90.
--   * ensure_defs stops memoizing: "the project cache is built once" fails at
--     4 definition scans for 4 requests; ensure_calls stops memoizing: the
--     same test fails on the call-scan count. This is what makes every picker
--     expansion re-run ripgrep over the whole tree.
--   * M.invalidate(root) made a no-op: "invalidate rebuilds exactly the root
--     it was given" fails -- a written file's project is answered from a
--     stale index forever.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_lsp_callhierarchy_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil, assert_deep_eq = _H.assert_nil, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local scan = require("andrew.fortran.scan")
local ch = require("andrew.fortran.lsp_callhierarchy")

local HAVE_RG = vim.fn.executable("rg") == 1

-- Fixture project ------------------------------------------------------------
--
-- A real tree on disk, scanned by the real ripgrep-backed scanner. The shapes
-- here are the ones the traps above are about: two units in one file, a
-- CONTAINS-ed procedure, a commented-out call, a `call &` continuation, a
-- known name in paren position next to an array subscript, and a callee the
-- project does not define.

local PHYSICS = {
  "module physics", --  1
  "contains", --  2
  "  subroutine Heating(t)", --  3
  "    real(8) :: t", --  4
  "    call Report(t)", --  5
  "  end subroutine Heating", --  6
  "  real(8) function Energy(t) result(e)", --  7
  "    real(8) :: t, e", --  8
  "    e = t", --  9
  "  end function Energy", -- 10
  "end module physics", -- 11
}

local SOLVER = {
  "subroutine Step(t)", --  1
  "  real(8) :: t, arr(10)", --  2
  "  ! call Heating(t)", --  3
  "  call        Heating(t)", --  4
  "  t = Energy(t) + arr(3)", --  5
  "  call &", --  6
  "    Heating(t)", --  7
  "end subroutine Step", --  8
  "", --  9
  "subroutine Drive(t)", -- 10
  "  real(8) :: t", -- 11
  "  call Heating(t)", -- 12
  "  call HEATING(t)", -- 13
  "  call MPI_Barrier(t)", -- 14
  "end subroutine Drive", -- 15
}

local MAIN = {
  "program Main", --  1
  "  real(8) :: t", --  2
  "  t = 1.0", --  3
  "  call Step(t)", --  4
  "contains", --  5
  "  subroutine Inner(x)", --  6
  "    real(8) :: x", --  7
  "    call Report(x)", --  8
  "  end subroutine Inner", --  9
  "end program Main", -- 10
}

local REPORT = {
  "subroutine Report(x)",
  "  real(8) :: x",
  "end subroutine Report",
}

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/code", "p")
vim.fn.writefile({ "" }, root .. "/.fortls")
vim.fn.writefile(PHYSICS, root .. "/code/physics.f90")
vim.fn.writefile(SOLVER, root .. "/code/solver.f90")
vim.fn.writefile(MAIN, root .. "/code/main.f90")
vim.fn.writefile(REPORT, root .. "/code/report.f90")

local function path_of(name)
  return root .. "/code/" .. name
end

local function uri_of(name)
  return vim.uri_from_fname(path_of(name))
end

-- Helpers --------------------------------------------------------------------

--- LSP position of `needle` on line `lnum` (1-based) of `lines`.
local function pos_of(lines, lnum, needle)
  local col = assert(lines[lnum]:find(needle, 1, true), "needle not on that line")
  return { line = lnum - 1, character = col - 1 }
end

--- Drive an async provider entry point to completion.
local function await(run)
  local result, done = nil, false
  run(function(_, res)
    result = res
    done = true
  end)
  assert_true(vim.wait(10000, function()
    return done
  end), "provider request timed out")
  return result
end

local function prepare(file, lines, lnum, needle)
  return await(function(cb)
    ch.prepare({ textDocument = { uri = uri_of(file) }, position = pos_of(lines, lnum, needle) }, cb)
  end)
end

--- Sorted "Name" list from a hierarchy result, reading `from` or `to`.
local function endpoints(result, field)
  local out = {}
  for _, entry in ipairs(result or {}) do
    out[#out + 1] = entry[field].name
  end
  table.sort(out)
  return out
end

local function entry_named(result, field, name)
  for _, e in ipairs(result or {}) do
    if e[field].name == name then
      return e
    end
  end
  return nil
end

--- 0-based start lines of a fromRanges list, sorted.
local function range_lines(entry)
  local out = {}
  for _, r in ipairs(entry.fromRanges) do
    out[#out + 1] = r.start.line
  end
  table.sort(out)
  return out
end

-- ---------------------------------------------------------------------------
-- prepare
-- ---------------------------------------------------------------------------

test("prepare on a definition spans the whole unit and needs no project scan", function()
  ch.reset()
  local items = prepare("physics.f90", PHYSICS, 3, "Heating")
  assert_true(items and #items == 1, "one item for the procedure under the cursor:")
  local item = items[1]
  assert_eq(item.name, "Heating", "source spelling is kept:")
  -- SymbolKind.Function -- a subroutine is a free-standing program unit, not a
  -- member of a type, so Method (6) would be a lie.
  assert_eq(item.kind, 12, "subroutine reports as SymbolKind.Function:")
  assert_eq(item.uri, uri_of("physics.f90"))
  assert_eq(item.selectionRange.start.line, 2, "selectionRange is the name on line 3:")
  assert_eq(item.selectionRange.start.character, 13, "byte column maps to a utf-8 character:")
  -- The unit runs from its header to its own `end subroutine`, NOT to the end
  -- of the module and NOT just the header line.
  assert_eq(item.range.start.line, 2, "range opens on the header:")
  assert_eq(item.range["end"].line, 5, "range closes on `end subroutine` (line 6):")
  assert_eq(item.data.lname, "heating", "data carries the lowercase name:")
  assert_eq(item.data.root, root, "data carries the project root:")
end)

test("prepare on a nested unit does not swallow its siblings", function()
  ch.reset()
  local items = prepare("physics.f90", PHYSICS, 7, "Energy")
  assert_true(items and #items == 1)
  assert_eq(items[1].name, "Energy")
  assert_eq(items[1].range.start.line, 6, "opens on line 7:")
  assert_eq(items[1].range["end"].line, 9, "closes on `end function` (line 10):")
end)

test("prepare on a non-procedure answers nothing", function()
  ch.reset()
  -- A module is not callable and has no body of its own.
  assert_nil(prepare("physics.f90", PHYSICS, 1, "physics"), "a module header is not a subject:")
  -- A bare variable is no token the scanner claims.
  assert_nil(prepare("physics.f90", PHYSICS, 4, "t"), "a variable is not a subject:")
end)

test("prepare on a call site resolves to the callee's definition", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local items = prepare("solver.f90", SOLVER, 4, "Heating")
  assert_true(items and #items == 1, "the callee is identified from the call statement:")
  assert_eq(items[1].name, "Heating")
  assert_eq(items[1].uri, uri_of("physics.f90"), "the item is the DEFINITION, not the call site:")
  assert_eq(items[1].selectionRange.start.line, 2, "at physics.f90 line 3:")
end)

test("prepare on a paren reference: a known procedure yes, an array no", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local fn = prepare("solver.f90", SOLVER, 5, "Energy")
  assert_true(fn and #fn == 1, "Energy( is a call because the project defines Energy:")
  assert_eq(fn[1].uri, uri_of("physics.f90"))

  -- Same syntax, no definition: `arr(3)` is a subscript. This is the single
  -- rule that keeps a call hierarchy from listing array indexing.
  assert_nil(prepare("solver.f90", SOLVER, 5, "arr("), "arr(3) is a subscript, not a call:")
end)

-- ---------------------------------------------------------------------------
-- incoming
-- ---------------------------------------------------------------------------

test("incoming groups call sites by the unit that contains them", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local item = prepare("physics.f90", PHYSICS, 3, "Heating")[1]
  local result = await(function(cb)
    ch.incoming({ item = item }, cb)
  end)

  -- Both callers live in solver.f90. Grouping by FILE would give one entry.
  assert_deep_eq(endpoints(result, "from"), { "Drive", "Step" }, "one entry per calling unit:")

  local step = entry_named(result, "from", "Step")
  assert_eq(step.from.uri, uri_of("solver.f90"))
  assert_eq(step.from.range.start.line, 0, "the caller item spans the calling unit:")
  assert_eq(step.from.range["end"].line, 7, "Step ends on line 8:")
  -- Line 4 is the spaced-out call, line 7 is the callee of the `call &`
  -- continuation. Line 3 is a comment and must not appear.
  assert_deep_eq(range_lines(step), { 3, 6 }, "Step's two call sites (0-based lines 3 and 6):")

  local drive = entry_named(result, "from", "Drive")
  assert_deep_eq(range_lines(drive), { 11, 12 }, "`call Heating` and `call HEATING` are both calls:")

  -- Trap 2: `subroutine Heating(t)` is itself a `Heating(` hit. If the
  -- definition-position filter goes, Heating reports as its own caller.
  assert_nil(entry_named(result, "from", "Heating"), "a definition header is not a call site:")
end)

test("incoming reports one range per call site, not one per scanner pass", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local item = prepare("physics.f90", PHYSICS, 3, "Heating")[1]
  local result = await(function(cb)
    ch.incoming({ item = item }, cb)
  end)
  local total = 0
  for _, e in ipairs(result) do
    total = total + #e.fromRanges
  end
  -- Four call sites: solver 4, 7, 12, 13. `call Heating(t)` is matched by the
  -- `call` pass AND the paren pass at the same column; without the position
  -- seen-set this counts 7.
  assert_eq(total, 4, "each call site is reported exactly once:")
end)

test("incoming on a name nobody calls is empty, not an error", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local item = prepare("main.f90", MAIN, 1, "Main")[1]
  local result = await(function(cb)
    ch.incoming({ item = item }, cb)
  end)
  assert_nil(result, "nothing calls the program:")
end)

-- ---------------------------------------------------------------------------
-- outgoing
-- ---------------------------------------------------------------------------

test("outgoing is the item's own body, not its whole file", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local item = prepare("solver.f90", SOLVER, 1, "Step")[1]
  local result = await(function(cb)
    ch.outgoing({ item = item }, cb)
  end)

  -- Step calls Heating twice and Energy once. Drive -- the OTHER unit in the
  -- same file -- calls Heating and MPI_Barrier, and none of that is Step's.
  assert_deep_eq(endpoints(result, "to"), { "Energy", "Heating" }, "Step's callees only:")
  assert_nil(entry_named(result, "to", "MPI_Barrier"), "Drive's callee is not Step's:")

  local heating = entry_named(result, "to", "Heating")
  assert_deep_eq(range_lines(heating), { 3, 6 }, "both of Step's calls, continuation included:")
end)

test("outgoing excludes array subscripts and self-referencing headers", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local item = prepare("solver.f90", SOLVER, 1, "Step")[1]
  local result = await(function(cb)
    ch.outgoing({ item = item }, cb)
  end)
  assert_nil(entry_named(result, "to", "arr"), "arr(10) / arr(3) are subscripts:")
  assert_nil(entry_named(result, "to", "real"), "real(8) is a kind selector:")
  -- `subroutine Step(t)` matches `Step(`; the header is not a call to itself.
  assert_nil(entry_named(result, "to", "Step"), "the header is not a self-call:")
end)

test("outgoing fromRanges are in the CALLER's document", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local item = prepare("solver.f90", SOLVER, 1, "Step")[1]
  local result = await(function(cb)
    ch.outgoing({ item = item }, cb)
  end)
  local energy = entry_named(result, "to", "Energy")
  -- The callee lives in physics.f90 at line 7...
  assert_eq(energy.to.uri, uri_of("physics.f90"), "`to` is the callee's definition:")
  assert_eq(energy.to.selectionRange.start.line, 6)
  -- ...but the range is where Step invokes it, solver.f90 line 5.
  assert_deep_eq(range_lines(energy), { 4 }, "fromRanges are the caller's line 5:")
end)

test("outgoing stops at CONTAINS: a contained procedure's calls are its own", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local main = prepare("main.f90", MAIN, 1, "Main")[1]
  local result = await(function(cb)
    ch.outgoing({ item = main }, cb)
  end)
  -- Inner is inside Main's line range and calls Report. It is not Main's call.
  assert_deep_eq(endpoints(result, "to"), { "Step" }, "only the program's own calls:")

  local inner = prepare("main.f90", MAIN, 6, "Inner")[1]
  local inner_result = await(function(cb)
    ch.outgoing({ item = inner }, cb)
  end)
  assert_deep_eq(endpoints(inner_result, "to"), { "Report" }, "the contained unit owns its call:")
end)

test("outgoing keeps a callee the project does not define", function()
  if not HAVE_RG then
    return
  end
  ch.reset()
  local item = prepare("solver.f90", SOLVER, 10, "Drive")[1]
  local result = await(function(cb)
    ch.outgoing({ item = item }, cb)
  end)
  local mpi = entry_named(result, "to", "MPI_Barrier")
  assert_true(mpi ~= nil, "`call MPI_Barrier` is a call even with no definition:")
  assert_eq(mpi.to.detail, "external", "and is labelled as unresolved:")
  assert_eq(mpi.to.uri, uri_of("solver.f90"), "positioned at the only place it is known:")

  -- `call Heating` and `call HEATING` are one callee with two ranges.
  local heating = entry_named(result, "to", "Heating")
  assert_deep_eq(range_lines(heating), { 11, 12 }, "case-insensitive grouping:")
  assert_eq(heating.to.name, "Heating", "the callee keeps its DEFINITION's spelling:")
end)

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

test("the project cache is built once and dropped on reset", function()
  if not HAVE_RG then
    return
  end
  ch.reset()

  local real_defs, real_calls = scan.project_definitions, scan.project_calls
  local n_defs, n_calls = 0, 0
  scan.project_definitions = function(r, cb)
    n_defs = n_defs + 1
    return real_defs(r, cb)
  end
  scan.project_calls = function(r, known, cb)
    n_calls = n_calls + 1
    return real_calls(r, known, cb)
  end

  local ok, err = pcall(function()
    local item = prepare("physics.f90", PHYSICS, 3, "Heating")[1]
    -- prepare on a DEFINITION answers from the buffer alone.
    assert_eq(n_defs, 0, "a definition needs no project scan:")

    for _ = 1, 3 do
      local result = await(function(cb)
        ch.incoming({ item = item }, cb)
      end)
      assert_eq(#result, 2, "every expansion answers the same:")
    end
    -- Three expansions of the picker, one ripgrep pass of each kind.
    assert_eq(n_defs, 1, "definitions scanned once for three requests:")
    assert_eq(n_calls, 1, "calls scanned once for three requests:")

    ch.reset()
    await(function(cb)
      ch.incoming({ item = item }, cb)
    end)
    assert_eq(n_defs, 2, "reset drops the cache:")
    assert_eq(n_calls, 2, "reset drops the call index too:")
  end)

  scan.project_definitions, scan.project_calls = real_defs, real_calls
  if not ok then
    error(err)
  end
end)

test("invalidate rebuilds exactly the root it was given", function()
  if not HAVE_RG then
    return
  end
  ch.reset()

  local real_defs = scan.project_definitions
  local n_defs = 0
  scan.project_definitions = function(r, cb)
    n_defs = n_defs + 1
    return real_defs(r, cb)
  end

  local ok, err = pcall(function()
    local item = prepare("physics.f90", PHYSICS, 3, "Heating")[1]
    local before = await(function(cb)
      ch.incoming({ item = item }, cb)
    end)
    assert_eq(n_defs, 1, "one scan to build the index:")

    -- A root nobody asked about: the live cache must survive it.
    ch.invalidate("/nonexistent-root")
    await(function(cb)
      ch.incoming({ item = item }, cb)
    end)
    assert_eq(n_defs, 1, "invalidating another root leaves this one cached:")

    ch.invalidate(root)
    local after = await(function(cb)
      ch.incoming({ item = item }, cb)
    end)
    assert_eq(n_defs, 2, "invalidating THIS root forces a rebuild:")
    assert_deep_eq(endpoints(after, "from"), endpoints(before, "from"), "same answer after the rebuild:")
  end)

  scan.project_definitions = real_defs
  if not ok then
    error(err)
  end
end)

-- ---------------------------------------------------------------------------

vim.fn.delete(root, "rf")
_H.finish()
