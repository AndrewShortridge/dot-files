-- Spec for lua/andrew/fortran/render.lua -- the one place that turns a
-- registry Entry into markdown for hover, completion and signature help.
--
-- WHAT IT PINS
--
-- The renderer is the whole visible product of the Fortran documentation
-- port: four LSP methods, one string builder. Three classes of bug live here
-- and none of them is visible to any other test.
--
--   1. Byte drift. The design fixes the target output literally (port-design
--      sections A1-A5): the `(kind) ` prefix INSIDE the fence, a bare `---`
--      between fence and prose ONLY when both halves exist, one dummy per
--      line at four spaces ONLY when there is more than one dummy, the `::`
--      column aligned across the dummy block. Every one of those is a
--      one-character edit away from being wrong and still "looking fine", so
--      the A1 hover is asserted as a whole multi-line string rather than by
--      pattern.
--   2. Offset drift in signature help. `parameters[i].label` is a pair of
--      BYTE offsets into the signature label. nvim highlights `label:sub()`
--      of that range directly, so an off-by-one underlines the comma instead
--      of the argument. The offsets are recorded as the label is concatenated
--      (signatureHelpProvider.ts:254-295) and this spec re-derives every one
--      of them from the finished label.
--   3. A hanging docstring converter. doc_to_markdown is a state machine; a
--      state that neither eats a line nor changes state spins forever, inside
--      a hover handler, in the UI thread. Upstream guards it
--      (docStringConversion.ts:145-150) and so do we.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "paren_list breaks only above one part" fails if `#parts > 1` becomes
--     `#parts > 0` -- a one-dummy procedure then splits over three lines, and
--     A3's zero-dummy `omp_get_wtime()` is the case that must never split.
--   * "paren_list indents four spaces" fails if the indent width changes.
--   * "the :: column is aligned" fails if the padding is dropped: the block
--     stops matching fortls's own hover and the two servers' floats diverge.
--   * "optional renders in the attribute column" fails if the optional flag
--     is ignored -- the single most consequential fact about `ierror`.
--   * "dim attaches to the name" fails if `dim` is dropped or moved onto the
--     type, which is not Fortran.
--   * "hover A1 is byte-exact" fails on ANY of: losing the `(kind) ` prefix,
--     moving it outside the fence, dropping the `---`, changing the fence
--     language, reordering the body blocks, or changing the trailer join.
--   * "no rule without both halves" fails if the `---` is emitted
--     unconditionally: a keyword hover then opens with a horizontal rule.
--   * "label replaces the name on the first line only" fails if the override
--     leaks into the declaration block, which would print the cursor's case
--     as if it were the canonical spelling.
--   * "completion_doc drops the kind prefix" fails if it delegates to hover
--     with a prefix -- the completion item would say "(subroutine)" twice,
--     once in `detail` and once in the documentation window.
--   * "parameters use interface order" fails if it iterates `params` (a hash)
--     instead of `interface` (the ordered source of truth); pairs() order is
--     unspecified, so the bug is intermittent by construction.
--   * "parameters skip undocumented dummies" fails if an empty entry emits a
--     bullet with a dangling em dash.
--   * "signature offsets address the parameter" fails on any off-by-one, and
--     on any attempt to build the label with table.concat after the fact.
--   * "only the active parameter is documented" fails if documentation is
--     attached to all of them: nvim then renders every dummy's prose at once.
--   * "the signature label ignores display mode" fails if it consults
--     vim.g.fortran_signature_display -- a formatted label makes nvim's
--     offset highlighting point into the wrong line.
--   * "detail carries kind and provenance" fails if `detail` and
--     `labelDetails.detail` are swapped, which blink renders as a duplicate.
--   * "@param becomes a bullet" fails if the continuation rule stops being
--     "indented strictly more than the marker".
--   * "an indent change is a hard break" fails if the `  \n` is dropped: a
--     `@param` block collapses into one run-on paragraph.
--   * "a :: block becomes a fence" fails if the literal-block opener is lost.
--   * "~~~ becomes ---" fails if the tilde header rule is dropped; markdown
--     then reads the underline as a code fence and swallows the rest.
--   * "the progress guard exits" HANGS (it does not fail) if the guard is
--     removed -- which is exactly why it is tested with an injected state.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_render_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil, assert_deep_eq = _H.assert_nil, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local render = require("andrew.fortran.render")

-- Fixtures -------------------------------------------------------------------
-- Hand-written Entries matching design A1-A5. They are NOT loaded from
-- lua/andrew/fortran/data/*.lua: the renderer's contract is the Entry shape,
-- and a spec that depends on generated data cannot say which side broke.

--- design A1
local function mpi_comm_rank()
  return {
    name = "MPI_Comm_rank",
    kind = "subroutine",
    signature = "MPI_Comm_rank(comm, rank, ierror)",
    interface = {
      { name = "comm", type = "integer", intent = "in", optional = false },
      { name = "rank", type = "integer", intent = "out", optional = false },
      { name = "ierror", type = "integer", intent = "out", optional = false },
    },
    params = {
      comm = "MPI communicator defining the process group, typically MPI_COMM_WORLD.",
      rank = "Returns the calling process's rank, 0 to size-1.",
      ierror = "Error status; MPI_SUCCESS (0) on success. In the `mpi` / `mpif.h` binding this "
        .. "argument is MANDATORY.",
    },
    summary = "Get the calling process's rank within a communicator",
    description = "**MPI_Comm_rank** returns the calling process's index within **comm**, "
      .. "counting from ZERO.",
    standard = "MPI-1.0",
    module = "mpi",
    binding_note = "`mpi_f08` spells `comm` as `type(MPI_Comm)` and makes `ierror` **optional**",
    see_also = { "MPI_Comm_size", "MPI_COMM_WORLD" },
  }
end

--- design A2
local function private_clause()
  return {
    name = "PRIVATE",
    kind = "clause",
    signature = "PRIVATE(list)",
    summary = "Give each thread its own uninitialized copy of each variable",
    description = "The value is **undefined** on entry and the original variable is "
      .. "**unchanged** on exit.",
    example = "!$omp parallel do private(i, tmp)",
    valid_on = { "PARALLEL", "DO", "SECTIONS", "SINGLE", "TASK", "SIMD", "TARGET", "TEAMS" },
    standard = "OpenMP 5.2 §5.4.3",
    module = "OpenMP 5.2",
    see_also = { "FIRSTPRIVATE", "LASTPRIVATE", "SHARED" },
  }
end

--- design A3
local function omp_get_wtime()
  return {
    name = "omp_get_wtime",
    kind = "function",
    signature = "omp_get_wtime()",
    interface = {},
    result = "Wall-clock seconds as DOUBLE PRECISION from an arbitrary origin.",
    result_type = "double precision",
    summary = "Elapsed wall-clock time in seconds",
    standard = "OpenMP 2.0",
    module = "omp_lib",
    see_also = { "omp_get_wtick", "MPI_Wtime" },
  }
end

--- design A4
local function allocatable_kw()
  return {
    name = "allocatable",
    kind = "keyword",
    summary = "Attribute: the variable's shape and storage are deferred to a later `allocate`",
    description = "```fortran\nreal(dp), allocatable :: a(:,:)\n```\nSince F2003 an allocatable "
      .. "may also be a dummy argument.",
    standard = "F90 (F2003 for dummies/results/components)",
    module = "Fortran 90",
    see_also = { "pointer", "allocate", "allocated", "move_alloc" },
  }
end

--- design A5
local function mpi_comm_world()
  return {
    name = "MPI_COMM_WORLD",
    kind = "constant",
    value = "0",
    summary = "The communicator containing every process in the job",
    description = "Predefined by `MPI_Init`, valid until `MPI_Finalize`.",
    module = "mpi",
    binding_note = "the value is implementation-defined -- 0 in the Open MPI 5.0.10 installed here",
    see_also = { "MPI_Comm_rank", "MPI_Comm_size", "MPI_Comm_dup" },
  }
end

--- a procedure with an optional dummy and an assumed-size array
local function mpi_bcast()
  return {
    name = "MPI_Bcast",
    kind = "subroutine",
    interface = {
      { name = "buffer", type = "real", intent = "inout", dim = "(*)" },
      { name = "count", type = "integer", intent = "in" },
      { name = "ierror", type = "integer", intent = "out", optional = true },
    },
    params = { count = "Number of entries in the buffer." },
    summary = "Broadcast from one rank to every rank in a communicator",
  }
end

-- paren_list -----------------------------------------------------------------

test("paren_list: empty and single stay on one line even when formatted", function()
  assert_eq(render.paren_list({}, true), "()")
  assert_eq(render.paren_list({ "comm" }, true), "(comm)")
  assert_eq(render.paren_list(nil, true), "()")
end)

test("paren_list: two or more break at four spaces with ) on its own line", function()
  assert_eq(render.paren_list({ "a", "b" }, true), "(\n    a,\n    b\n)")
  assert_eq(render.paren_list({ "a", "b", "c" }, true), "(\n    a,\n    b,\n    c\n)")
end)

test("paren_list: compact never breaks", function()
  assert_eq(render.paren_list({ "a", "b", "c" }, false), "(a, b, c)")
  assert_eq(render.paren_list({}, false), "()")
end)

-- format_signature -----------------------------------------------------------

test("format_signature: the :: column is aligned across the dummy block", function()
  local got = render.format_signature(mpi_comm_rank())
  assert_eq(got, table.concat({
    "MPI_Comm_rank(",
    "    comm,",
    "    rank,",
    "    ierror",
    ")",
    "  integer, intent(in)  :: comm",
    "  integer, intent(out) :: rank",
    "  integer, intent(out) :: ierror",
  }, "\n"))
end)

test("format_signature: optional renders in the attribute column, dim on the name", function()
  local got = render.format_signature(mpi_bcast())
  assert_true(got:find("  real, intent(inout)            :: buffer(*)", 1, true) ~= nil, got)
  assert_true(got:find("  integer, intent(out), optional :: ierror", 1, true) ~= nil, got)
  -- the shape belongs to the name in the call line too
  assert_true(got:find("    buffer(*),", 1, true) ~= nil, got)
end)

test("format_signature: a function appends its result declaration", function()
  assert_eq(render.format_signature(omp_get_wtime()), "omp_get_wtime()\n  double precision :: omp_get_wtime")
end)

test("format_signature: a constant renders a parameter declaration", function()
  assert_eq(render.format_signature(mpi_comm_world()), "MPI_COMM_WORLD\n  integer, parameter :: MPI_COMM_WORLD = 0")
end)

test("format_signature: clause, keyword and directive render one line", function()
  assert_eq(render.format_signature(private_clause()), "PRIVATE(list)")
  assert_eq(render.format_signature(allocatable_kw()), "allocatable")
  assert_eq(render.format_signature({ name = "PARALLEL DO", kind = "directive", signature = "!$OMP PARALLEL DO [clauses]" }), "!$OMP PARALLEL DO [clauses]")
end)

test("format_signature: compact display collapses the call line", function()
  assert_eq(
    render.format_signature(mpi_comm_rank(), { display = "compact" }),
    "MPI_Comm_rank(comm, rank, ierror)"
      .. "\n  integer, intent(in)  :: comm"
      .. "\n  integer, intent(out) :: rank"
      .. "\n  integer, intent(out) :: ierror"
  )
end)

test("format_signature: vim.g.fortran_signature_display selects the mode", function()
  local saved = vim.g.fortran_signature_display
  vim.g.fortran_signature_display = "compact"
  assert_true(render.format_signature(mpi_comm_rank()):find("MPI_Comm_rank(comm, rank, ierror)", 1, true) == 1)
  vim.g.fortran_signature_display = "formatted"
  assert_true(render.format_signature(mpi_comm_rank()):find("MPI_Comm_rank(\n", 1, true) == 1)
  vim.g.fortran_signature_display = saved
end)

-- hover ----------------------------------------------------------------------

test("hover: design A1 is byte-exact", function()
  local expected = [==[
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

**MPI_Comm_rank** returns the calling process's index within **comm**, counting from ZERO.

**Parameters**
- `comm` — MPI communicator defining the process group, typically MPI_COMM_WORLD.
- `rank` — Returns the calling process's rank, 0 to size-1.
- `ierror` — Error status; MPI_SUCCESS (0) on success. In the `mpi` / `mpif.h` binding this argument is MANDATORY.

**Binding** `mpi` (`include 'mpif.h'`); `mpi_f08` spells `comm` as `type(MPI_Comm)` and makes `ierror` **optional** · **Standard** MPI-1.0 · **See also** `MPI_Comm_size`, `MPI_COMM_WORLD`]==]
  local got = render.hover(mpi_comm_rank())
  assert_eq(got.kind, "markdown")
  assert_eq(got.value, expected)
end)

test("hover: the kind prefix lives inside the fence", function()
  local v = render.hover(private_clause()).value
  assert_eq(v:sub(1, #"```fortran\n(clause) PRIVATE(list)\n```"), "```fortran\n(clause) PRIVATE(list)\n```")
end)

test("hover: the rule appears only when both halves are non-empty", function()
  assert_eq(render.hover({ name = "allocatable", kind = "keyword" }).value, "```fortran\n(keyword) allocatable\n```")
  assert_true(render.hover(allocatable_kw()).value:find("\n```\n---\n", 1, true) ~= nil)
end)

test("hover: label replaces the display name on the first line only", function()
  local v = render.hover(mpi_comm_rank(), "mpi_comm_rank").value
  assert_true(v:find("```fortran\n(subroutine) mpi_comm_rank(\n", 1, true) == 1, v)
  assert_true(v:find("  integer, intent(in)  :: comm", 1, true) ~= nil)
  local c = render.hover(mpi_comm_world(), "mpi_comm_world").value
  assert_true(c:find("(constant) mpi_comm_world\n  integer, parameter :: MPI_COMM_WORLD = 0", 1, true) ~= nil, c)
end)

test("hover: A3 keeps a zero-dummy function on one line", function()
  local v = render.hover(omp_get_wtime()).value
  assert_true(v:find("```fortran\n(function) omp_get_wtime()\n  double precision :: omp_get_wtime\n```\n---\n", 1, true) == 1, v)
  assert_true(v:find("**Returns** Wall-clock seconds", 1, true) ~= nil)
  assert_true(v:find("**Module** `omp_lib` (`!$ use omp_lib`) · **Standard** OpenMP 2.0 · **See also** `omp_get_wtick`, `MPI_Wtime`", 1, true) ~= nil, v)
end)

test("hover: A5 renders the constant value and the mpi binding", function()
  local v = render.hover(mpi_comm_world()).value
  assert_true(v:find("```fortran\n(constant) MPI_COMM_WORLD\n  integer, parameter :: MPI_COMM_WORLD = 0\n```\n---\n", 1, true) == 1, v)
  assert_true(v:find("**Binding** `mpi` (`include 'mpif.h'`); the value is implementation-defined", 1, true) ~= nil, v)
end)

-- body -----------------------------------------------------------------------

test("body: parameters follow interface order and skip undocumented dummies", function()
  local b = render.body(mpi_bcast())
  assert_true(b:find("**Parameters**\n- `count` — Number of entries in the buffer.", 1, true) ~= nil, b)
  assert_true(b:find("`buffer`", 1, true) == nil, "undocumented dummy must not get a bullet")
  -- order, not hash order
  local e = mpi_comm_rank()
  local body = render.body(e)
  local i_comm = body:find("`comm`", 1, true)
  local i_rank = body:find("`rank`", 1, true)
  local i_ierr = body:find("- `ierror`", 1, true)
  assert_true(i_comm < i_rank and i_rank < i_ierr, "interface order")
end)

test("body: valid_on is backticked names separated by single spaces", function()
  local b = render.body(private_clause())
  assert_true(b:find("**Valid on** `PARALLEL` `DO` `SECTIONS` `SINGLE` `TASK` `SIMD` `TARGET` `TEAMS`", 1, true) ~= nil, b)
end)

test("body: example is wrapped in a fortran fence under its own header", function()
  local b = render.body(private_clause())
  assert_true(b:find("**Example**\n```fortran\n!$omp parallel do private(i, tmp)\n```", 1, true) ~= nil, b)
end)

test("body: the trailer is one paragraph joined with a middle dot", function()
  local b = render.body(private_clause())
  local tail = b:match("\n\n([^\n]+)$")
  assert_eq(tail, "**Standard** OpenMP 5.2 §5.4.3 · **See also** `FIRSTPRIVATE`, `LASTPRIVATE`, `SHARED`")
  -- a module that is neither mpi nor omp_lib contributes no binding line
  assert_true(b:find("**Module**", 1, true) == nil, b)
end)

test("body: a summary without punctuation gets a full stop", function()
  assert_true(render.body({ summary = "Already done." }) == "Already done.")
  assert_true(render.body({ summary = "Needs one" }) == "Needs one.")
end)

-- completion_doc -------------------------------------------------------------

test("completion_doc: identical to hover minus the kind prefix", function()
  local e = mpi_comm_rank()
  local hover = render.hover(e).value
  local doc = render.completion_doc(e).value
  assert_eq(doc, (hover:gsub("^```fortran\n%(subroutine%) ", "```fortran\n")))
  assert_true(doc:find("(subroutine)", 1, true) == nil)
  assert_eq(render.completion_doc(e).kind, "markdown")
end)

-- signature ------------------------------------------------------------------

--- The contract nvim relies on: label:sub(start+1, end_) is the parameter.
local function assert_offsets(entry)
  local info = render.signature(entry, 0)
  for i, p in ipairs(entry.interface) do
    local s, e = info.parameters[i].label[1], info.parameters[i].label[2]
    assert_eq(info.label:sub(s + 1, e), p.name, "parameter " .. i)
  end
  return info
end

test("signature: byte offsets address each parameter of a 3-dummy routine", function()
  local info = assert_offsets(mpi_comm_rank())
  assert_eq(info.label, "MPI_Comm_rank(comm, rank, ierror)")
  assert_deep_eq(info.parameters[1].label, { 14, 18 })
  assert_deep_eq(info.parameters[2].label, { 20, 24 })
  assert_deep_eq(info.parameters[3].label, { 26, 32 })
end)

test("signature: a 0-dummy routine has an empty parameter list", function()
  local info = assert_offsets(omp_get_wtime())
  assert_eq(info.label, "omp_get_wtime()")
  assert_eq(#info.parameters, 0)
end)

test("signature: only the active parameter is documented", function()
  local info = render.signature(mpi_comm_rank(), 1)
  assert_eq(info.activeParameter, 1)
  assert_eq(info.parameters[1].documentation.value, "")
  assert_eq(info.parameters[3].documentation.value, "")
  assert_eq(
    info.parameters[2].documentation.value,
    "---\n`integer, intent(out) :: rank`\n\nReturns the calling process's rank, 0 to size-1."
  )
  assert_eq(info.parameters[2].documentation.kind, "markdown")
  -- the separator nvim will not insert for us
  assert_eq(info.parameters[2].documentation.value:sub(1, 4), "---\n")
end)

test("signature: documentation is summary plus the first description paragraph", function()
  local e = mpi_comm_rank()
  e.description = "First paragraph.\n\nSecond paragraph."
  local info = render.signature(e, 0)
  assert_eq(
    info.documentation.value,
    "Get the calling process's rank within a communicator.\n\nFirst paragraph."
  )
end)

test("signature: the label is compact even when display is formatted", function()
  local saved = vim.g.fortran_signature_display
  vim.g.fortran_signature_display = "formatted"
  local info = assert_offsets(mpi_comm_rank())
  assert_eq(info.label, "MPI_Comm_rank(comm, rank, ierror)")
  assert_true(info.label:find("\n", 1, true) == nil)
  vim.g.fortran_signature_display = saved
end)

test("signature: no active parameter means no activeParameter field", function()
  local info = render.signature(mpi_comm_rank(), nil)
  assert_nil(info.activeParameter)
  assert_eq(info.parameters[2].documentation.value, "")
end)

-- detail ---------------------------------------------------------------------

test("detail: kind, compact argument list and provenance", function()
  local detail, ld = render.detail(mpi_comm_rank())
  assert_eq(detail, "subroutine")
  assert_eq(ld.detail, "(comm, rank, ierror)")
  assert_eq(ld.description, "mpi")
end)

test("detail: non-procedures carry no argument list, standard is the fallback", function()
  local detail, ld = render.detail(private_clause())
  assert_eq(detail, "clause")
  assert_nil(ld.detail)
  assert_eq(ld.description, "OpenMP 5.2")
  local _, ld2 = render.detail({ name = "x", kind = "keyword", standard = "F2008" })
  assert_eq(ld2.description, "F2008")
end)

-- doc_to_markdown ------------------------------------------------------------

test("doc_to_markdown: @param becomes a bullet, continuations join", function()
  assert_eq(
    render.doc_to_markdown("!> @param n  the size\n!>   continuation"),
    "- `n` — the size continuation"
  )
  -- a line indented no further than the marker ends the field
  assert_eq(
    render.doc_to_markdown("!> @param n  the size\n!> after"),
    "- `n` — the size\nafter"
  )
end)

test("doc_to_markdown: a :: literal block becomes a fence", function()
  local got = render.doc_to_markdown(table.concat({
    "!> Example::",
    "!>",
    "!>     call foo(x)",
    "!>",
    "!> done",
  }, "\n"))
  assert_eq(got, "Example:\n\n```\ncall foo(x)\n```\n\ndone")
end)

test("doc_to_markdown: an indent change is a markdown hard break", function()
  assert_eq(render.doc_to_markdown("!> alpha\n!>   beta"), "alpha  \nbeta")
end)

test("doc_to_markdown: a ~~~ underline becomes ---", function()
  assert_eq(render.doc_to_markdown("!> Heading\n!> ~~~~~~~"), "Heading\n-------")
  assert_eq(render.doc_to_markdown("!> Heading\n!> ~~~"), "Heading\n---")
  assert_eq(render.doc_to_markdown("!> Heading\n!> +++"), "Heading\n---")
end)

test("doc_to_markdown: doc-comment leaders are stripped, !$ is not", function()
  assert_eq(render.doc_to_markdown("!! trailing form\n!! second"), "trailing form\nsecond")
  assert_eq(render.doc_to_markdown("!< preceding form"), "preceding form")
  assert_eq(render.doc_to_markdown("!$omp parallel"), "!$omp parallel")
end)

test("doc_to_markdown: empty input is empty output", function()
  assert_eq(render.doc_to_markdown(nil), "")
  assert_eq(render.doc_to_markdown(""), "")
  assert_eq(render.doc_to_markdown("!>\n!>"), "")
end)

test("doc_to_markdown: the progress guard exits a stuck state", function()
  -- A state that neither eats a line nor changes state. Without the guard
  -- this loops forever inside a hover handler; with it, conversion stops.
  local saved = render._states.text
  render._states.text = function() end
  local ok, got = pcall(render.doc_to_markdown, "!> anything at all")
  render._states.text = saved
  assert_true(ok, "conversion must return, not raise")
  assert_eq(got, "")
  -- and the machine still works afterwards
  assert_eq(render.doc_to_markdown("!> alpha"), "alpha")
end)

-- purity ---------------------------------------------------------------------

test("render is pure: no plugin requires, no buffer access", function()
  local path = vim.fn.stdpath("config") .. "/lua/andrew/fortran/render.lua"
  local src = table.concat(vim.fn.readfile(path), "\n")
  for call in src:gmatch('require%("([%w%.%-_]+)"%)') do
    assert_true(false, "render.lua must not require anything, found: " .. call)
  end
  for ns in src:gmatch("vim%.([%w_]+)") do
    assert_true(
      ns == "split" or ns == "g" or ns:sub(1, 4) == "tbl_",
      "render.lua may only touch vim.split / vim.g / vim.tbl_*, found vim." .. ns
    )
  end
end)

_H.finish({ style = "results" })
