-- Spec for the COMMITTED registry as the user actually sees it:
-- lua/andrew/fortran/render.lua run over lua/andrew/fortran/data/{mpi,openmp,
-- keywords}.lua, with every hover pinned byte-for-byte.
--
-- WHAT IT PINS AND WHY IT IS NOT tests/fortran_render_spec.lua
--
-- `fortran_render_spec.lua` builds its own entry tables inline, so it pins the
-- RENDERER. That is the right way to test `paren_list` and the state machine,
-- and it is exactly why it cannot see the data: every one of its fixtures is
-- hand-written in the spec file, so the committed tables could be regenerated
-- into nonsense -- a prose field that arrives with a stray leading space on
-- every wrapped line, a `standard` that goes missing, a summary that loses its
-- full stop -- and it would stay green. Nothing pinned the bytes a user reads.
--
-- This spec loads the REAL registry and pins the five hovers design A1-A5
-- specify, in full. A change to a generator, to an override table, to
-- `parsed-mpi-omp.json`, or to the renderer, shows up here as a diff of the
-- float's own text.
--
-- Two deliberate deviations from the design document, pinned as SHIPPED:
--   * the trailer is one paragraph joined with ` · ` (design A1 puts
--     `**Binding**` on its own line); and
--   * each block is separated by a blank line, including `**Valid on**` and
--     `**Example**` (design A2 shows them adjacent).
-- A4 -- the `allocatable` keyword -- is byte-exact with the design and is the
-- one fixture here that must never be "re-pinned" to match new output.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "A1: hover on MPI_Comm_rank" fails if the generators stop normalising the
--     one-space hanging indent `parsed-mpi-omp.json` reflows prose with -- the
--     defect this spec was written for: 276 lines of MPI description and 30 of
--     `**Returns**` used to open with a stray column that nvim's float renders
--     literally. It also fails if `interface[]` order drifts, if the `(word) `
--     prefix or the `---` rule is dropped, or if a `params` entry is lost.
--   * "A2: hover on the PRIVATE clause" fails if `registry.directive` stops
--     answering clauses, or if `valid_on`/`example` stop reaching the float.
--   * "A3: hover on omp_get_wtime" fails if `format_signature` starts breaking
--     a zero-dummy procedure across lines (tooltipUtils.ts:311-322) or if the
--     result-type declaration line is dropped.
--   * "A4: hover on the allocatable keyword" fails if data/keywords.lua is
--     regenerated or hand-edited away from the design's block. This is the one
--     fixture quoted verbatim from the design document.
--   * "A5: hover on MPI_COMM_WORLD" fails if constants stop carrying their
--     `parameter` declaration or their scraped value.
--   * "A8: signatureHelp offsets" fails if `M.signature` ever computes offsets
--     after concatenating instead of before, or if the label stops being
--     compact -- the offsets [14,18] [20,24] [26,32] are byte offsets into the
--     label and nvim highlights whatever they point at, right or wrong.
--   * "prose carries no reflow indent" fails on the DATA rather than on one
--     hover: it sweeps every prose field of every mpi/openmp entry, so a new
--     entry that reintroduces the artifact fails even though no fixture above
--     mentions it.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_registry_render_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local registry = require("andrew.fortran.registry")
local render = require("andrew.fortran.render")

--- Byte-for-byte comparison that reports the first differing LINE, because a
--- 40-line float diffed as one string is unreadable.
---@param got string
---@param want string
---@param label string
local function assert_same_text(got, want, label)
  if got == want then
    assert_eq(#got, #want, label .. " byte length:")
    return
  end
  local gl = vim.split(got, "\n", { plain = true })
  local wl = vim.split(want, "\n", { plain = true })
  for i = 1, math.max(#gl, #wl) do
    if gl[i] ~= wl[i] then
      error(("%s differs at line %d\n  want: %s\n  got : %s")
        :format(label, i, vim.inspect(wl[i]), vim.inspect(gl[i])))
    end
  end
  error(label .. " differs in trailing newline only")
end

--- The fixtures below are `[==[` long strings, which swallow the newline that
--- follows the opening bracket but keep the one before the closing bracket.
--- `hover().value` is trim_end'd, so strip that trailing newline back off.
---@param s string
---@return string
local function fixture(s)
  return (s:gsub("\n$", ""))
end

local FX_A1 = [==[
```fortran
(subroutine) MPI_Comm_rank(
    comm,
    rank,
    ierror
)
  integer, intent(in)  :: comm
  integer, intent(out) :: rank
  integer, intent(out) :: ierror
```
---
Get the calling process's rank within a communicator.

**MPI_Comm_rank** returns the calling process's index within **comm**,
counting from ZERO. Together with MPI_Comm_size it is how a process discovers
which part of the work is its own.

The rank is meaningful only relative to the communicator it came from. A rank
obtained from MPI_COMM_WORLD must not be used as a destination in a
sub-communicator.

**Parameters**
- `comm` — MPI communicator defining the process group, typically MPI_COMM_WORLD.
- `rank` — Returns the calling process's rank, 0 to size-1.
- `ierror` — Error status. Returns MPI_SUCCESS (0) on success, or an MPI error code on failure. In the Fortran binding this is a mandatory final argument -- omitting it is the single most common Fortran MPI bug, and the compiler cannot catch it.

**Returns** **rank** holds the calling process's zero-based index in **comm**.

**Example**
```fortran
  call MPI_Init(ierr)
  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)

  ! Split a loop across ranks
  my_lo = 1 + (rank * n) / nprocs
  my_hi = ((rank + 1) * n) / nprocs
```

**Binding** `mpi` (`include 'mpif.h'`); mpi_f08 spells comm as type(MPI_Comm); ierror is OPTIONAL · **Standard** MPI-1.0 · **See also** `MPI_Comm_size`, `MPI_COMM_WORLD`]==]

local FX_A2 = [==[
```fortran
(clause) PRIVATE(list)
```
---
Give each thread its own uninitialized copy of each variable.

The value is **undefined** on entry and the original variable is **unchanged** on
exit. A private copy is a NEW variable of the same type and shape, so anything the
thread needs from the original must be copied in explicitly — that is what
`FIRSTPRIVATE` is for — and anything it computes is lost unless `LASTPRIVATE` or a
reduction carries it out.

In Fortran the default sharing attribute inside a parallel region is SHARED, so
every scratch variable used in the body needs naming here. The loop iteration
variable of a worksharing `DO` is private automatically, as are the indices of
loops fused by `COLLAPSE`, and variables declared inside a `BLOCK` construct in
the region.

Privatising an allocatable gives each thread an UNALLOCATED copy; privatising a
pointer gives an undefined association status. Both must be set up inside the
region. A variable with the `SAVE` attribute, a common block member or a module
variable cannot be privatised this way — use `THREADPRIVATE`.

**Valid on** `PARALLEL` `DO` `SECTIONS` `SINGLE` `TASK` `SIMD` `TARGET` `TEAMS`

**Example**
```fortran
!$omp parallel do private(i, tmp)
```

**Standard** OpenMP 5.2 §5.4.3 · **See also** `FIRSTPRIVATE`, `LASTPRIVATE`, `SHARED`]==]

local FX_A3 = [==[
```fortran
(function) omp_get_wtime()
  double precision :: omp_get_wtime
```
---
Elapsed wall-clock time in seconds.

The natural timer for an OpenMP program: it measures WALL-CLOCK time, not CPU time,
so it reports what a parallel region actually saved, whereas `cpu_time` sums over
all threads and appears to get worse as you add them.

Take the difference of two calls on the same thread; the origin is arbitrary and
only guaranteed to be fixed for the life of the program. Wrap timed regions in a
barrier when timing a parallel construct, so that the measurement is not taken
while other threads are still working.

**Returns** Wall-clock seconds as DOUBLE PRECISION from an arbitrary origin; only *differences* of two calls on the **same thread** are meaningful.

**Example**
```fortran
double precision :: t0, t1
t0 = omp_get_wtime()
call solve()
t1 = omp_get_wtime()
print '(a,f8.3)', 'seconds: ', t1 - t0
```

**Module** `omp_lib` (`!$ use omp_lib`) · **Standard** OpenMP 2.0 · **See also** `omp_get_wtick`, `MPI_Wtime`, `system_clock`]==]

local FX_A4 = [==[
```fortran
(keyword) allocatable
```
---
Attribute: the variable's shape and storage are deferred to a later `allocate`.

```fortran
real(dp), allocatable :: a(:,:)
allocate(a(n,m), stat=ierr)
if (allocated(a)) deallocate(a)
```
Since F2003 an allocatable may also be a dummy argument, a function result and a derived-type component; since F2008 assignment to an unallocated allocatable allocates it.

**Standard** F90 (F2003 for dummies/results/components) · **See also** `pointer`, `allocate`, `allocated`, `move_alloc`]==]

local FX_A5 = [==[
```fortran
(constant) MPI_COMM_WORLD
  integer, parameter :: MPI_COMM_WORLD = 0
```
---
The communicator containing every process in the job.

**MPI_COMM_WORLD** is the predefined communicator holding all processes
started by the job launcher. It exists from MPI_Init until MPI_Finalize and
is the default context for nearly all communication.

Ranks in it run from 0 to size-1 and never change. It cannot be freed. Note
that a rank number is meaningful only for the communicator it came from --
a rank taken from MPI_COMM_WORLD is not valid in a communicator produced by
MPI_Comm_split.

**Example**
```fortran
  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
  call MPI_Bcast(x, 1, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, ierr)
```

**Binding** `mpi` (`include 'mpif.h'`); value as installed here (Open MPI 5.0.10, mpif-handles.h) · **Standard** MPI-1.0 · **See also** `MPI_Comm_rank`, `MPI_Comm_size`, `MPI_Comm_dup`]==]


test("A1: hover on MPI_Comm_rank is byte-for-byte the shipped float", function()
  local e = registry.get("MPI_Comm_rank")
  assert_true(e ~= nil, "the entry resolves:")
  assert_same_text(render.hover(e).value, fixture(FX_A1), "hover(MPI_Comm_rank)")
end)

test("A2: hover on the PRIVATE clause is byte-for-byte the shipped float", function()
  local e = registry.directive("PRIVATE")
  assert_true(e ~= nil, "the clause resolves through the directive door:")
  assert_eq(e.kind, "clause", "kind:")
  assert_same_text(render.hover(e).value, fixture(FX_A2), "hover(PRIVATE)")
end)

test("A3: hover on omp_get_wtime is byte-for-byte the shipped float", function()
  local e = registry.get("omp_get_wtime")
  assert_true(e ~= nil, "the entry resolves:")
  assert_same_text(render.hover(e).value, fixture(FX_A3), "hover(omp_get_wtime)")
end)

test("A4: hover on the allocatable keyword equals the design block verbatim", function()
  local e = registry.get("allocatable")
  assert_true(e ~= nil, "the keyword resolves:")
  assert_same_text(render.hover(e).value, fixture(FX_A4), "hover(allocatable)")
end)

test("A5: hover on MPI_COMM_WORLD is byte-for-byte the shipped float", function()
  local e = registry.get("MPI_COMM_WORLD")
  assert_true(e ~= nil, "the constant resolves:")
  assert_same_text(render.hover(e).value, fixture(FX_A5), "hover(MPI_COMM_WORLD)")
end)

test("A8: the signature label is compact and its offsets index it exactly", function()
  local sig = render.signature(registry.get("MPI_Comm_rank"), 1)
  assert_eq(sig.label, "MPI_Comm_rank(comm, rank, ierror)", "label:")
  assert_eq(sig.activeParameter, 1, "activeParameter:")
  local want = { { 14, 18 }, { 20, 24 }, { 26, 32 } }
  assert_eq(#sig.parameters, #want, "one parameter per dummy:")
  for i, w in ipairs(want) do
    assert_eq(sig.parameters[i].label[1], w[1], ("parameter %d start offset:"):format(i))
    assert_eq(sig.parameters[i].label[2], w[2], ("parameter %d end offset:"):format(i))
    -- the offsets are bytes into `label`; slice with them and the dummy name
    -- must come back, which is what nvim highlights
    assert_eq(sig.label:sub(w[1] + 1, w[2]), ({ "comm", "rank", "ierror" })[i],
      ("parameter %d slices to its own name:"):format(i))
  end
  -- only the active parameter carries documentation (signatureHelpProvider.ts:304-314)
  assert_eq(sig.parameters[1].documentation.value, "", "inactive parameter 1 is empty:")
  assert_eq(sig.parameters[3].documentation.value, "", "inactive parameter 3 is empty:")
  assert_true(sig.parameters[2].documentation.value:find("^%-%-%-\n") ~= nil,
    "the active parameter ships its own rule (design A8):")
end)

-- ---------------------------------------------------------------------------
-- Data hygiene
-- ---------------------------------------------------------------------------

--- Fields holding human prose. `example` is excluded: it is code, and its
--- indentation is meaning.
local PROSE_TEXT = { "summary", "description", "result", "binding_note" }

--- Is this line a markdown list item? Under one, an indent is continuation and
--- means something -- OpenMP's `schedule` is a real list with 2-space
--- continuations and must survive untouched.
---@param l string
---@return boolean
local function is_list_item(l)
  return l:match("^%s*[%-%*%+] ") ~= nil or l:match("^%s*%d+%.[ \t]") ~= nil
end

--- The reflow artifact: a paragraph whose first line is flush left and whose
--- continuation lines all carry a hanging indent, outside any fence, with no
--- list in sight. nvim's float renders those spaces literally.
---@param s string
---@return string|nil offending line
local function reflow_indent(s)
  local lines = vim.split(s, "\n", { plain = true })
  if #lines < 2 or lines[1]:match("^%s") then
    return nil
  end
  local fenced = false
  for _, l in ipairs(lines) do
    local marker = l:match("^%s*```") ~= nil
    if marker or not fenced then
      if is_list_item(l) then
        return nil
      end
    end
    if marker then
      fenced = not fenced
    end
  end
  fenced = false
  for i, l in ipairs(lines) do
    local marker = l:match("^%s*```") ~= nil
    if (marker or not fenced) and i > 1 and l:match("^[ \t]+%S") then
      return l
    end
    if marker then
      fenced = not fenced
    end
  end
  return nil
end

test("no prose field carries a reflow indent", function()
  local bad = {}
  for _, file in ipairs({ "mpi", "openmp" }) do
    local tbl = require("andrew.fortran.data." .. file)
    for key, e in pairs(tbl) do
      if key ~= "_meta" and type(e) == "table" then
        local fields = {}
        for _, f in ipairs(PROSE_TEXT) do
          if type(e[f]) == "string" then
            fields[f] = e[f]
          end
        end
        if type(e.params) == "table" then
          for pk, pv in pairs(e.params) do
            if type(pv) == "string" then
              fields["params." .. pk] = pv
            end
          end
        end
        for fname, v in pairs(fields) do
          local line = reflow_indent(v)
          if line then
            bad[#bad + 1] = ("%s.%s.%s -> %s"):format(file, key, fname, vim.inspect(line))
          end
        end
      end
    end
  end
  table.sort(bad)
  assert_eq(#bad, 0, "prose fields with a leading-space artifact:\n    "
    .. table.concat(bad, "\n    "))
end)

test("the hygiene sweep actually looks at something", function()
  -- a check that never inspects anything passes for the wrong reason
  local n = 0
  for _, file in ipairs({ "mpi", "openmp" }) do
    for key, e in pairs(require("andrew.fortran.data." .. file)) do
      if key ~= "_meta" and type(e) == "table" and type(e.description) == "string" then
        n = n + 1
      end
    end
  end
  assert_true(n > 150, "entries with a description swept: " .. n)
  -- and that it still FIRES on the artifact's exact shape
  assert_true(reflow_indent("first line\n second line") ~= nil, "detects a one-space hang:")
  assert_true(reflow_indent("first line\n  second line") ~= nil, "detects a two-space hang:")
  assert_true(reflow_indent("first line\n- item\n  more") == nil, "spares a list continuation:")
  assert_true(reflow_indent("a\n```\n  code\n```") == nil, "spares a fence interior:")
end)

_H.finish()
