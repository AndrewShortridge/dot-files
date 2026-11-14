-- Spec for lua/andrew/fortran/lsp_hover.lua -- the answer rule behind `K` in a
-- Fortran buffer.
--
-- WHAT IT PINS
--
-- `K` used to be a keymap closure that read snippets/fortran-docs.json and
-- opened its own float. Four separate defects lived in it, and not one of them
-- was reachable by a test, because the logic was inside a keymap:
--
--   * S3a -- on `!$OMP PARALLEL DO REDUCTION(+:sum)`, K on `sum` showed the
--     SUM intrinsic. The word is a reduction operand, not a call.
--   * F4 -- the JSON holds ~210 snippet abbreviations as top-level keys, so K
--     on the user's own `dp`, `mat`, `count` or `pi` documented a snippet.
--   * double-hover -- fortls answers for every project-defined symbol. If this
--     server answers too, vim.lsp.buf.hover concatenates both into one float
--     under `# fortls` / `# fortran-extras` banners (buf.lua:141-145).
--   * masking -- a word inside a `!` comment or a string literal is not code
--     and must not be documented; but a word inside `!$OMP ...` IS the thing
--     the user is asking about, even though it is a comment to the compiler.
--
-- The rule that fixes all four is four ordered steps, and the value of this
-- spec is that each step fails on its own.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "a directive line never falls through" fails if step 2's miss returns
--     anything but nil -- `sum` in REDUCTION(+:sum) then documents the SUM
--     intrinsic again, which is S3a exactly.
--   * "a clause on a directive line is answered" fails if step 2 consults
--     registry.get() instead of registry.directive(): the general index holds
--     a DIFFERENT `private` -- the Fortran accessibility keyword -- so the bug
--     shows the wrong documentation rather than none.
--   * "a name defined in this buffer is fortls's" fails if step 3 is dropped
--     or if it consults only the project index and not the buffer -- the
--     buffer is the half that catches a procedure not yet written to disk.
--   * "a variable declared in this buffer is fortls's" fails if `decls` is
--     dropped from the buffer oracle; `count` then answers with the legacy
--     intrinsic prose while the cursor is on an integer counter (F4).
--   * "seeded builtins are not project symbols" fails if step 3 forgets to
--     exempt `sig.builtin` -- lsp_inlayhint seeds the MPI/OpenMP signatures
--     into the same index, so every MPI hover would go silent.
--   * "MPI_Comm_rank renders design A1" fails on any drift between this
--     handler and render.hover, and on passing the cursor spelling as the
--     label (the float would then print the user's casing as canonical).
--   * "the range covers exactly the word" fails on any off-by-one: nvim
--     highlights that range in the source buffer.
--   * "a keyword is answered" fails if keywords are dropped from step 4;
--     fortls returns null for every one of them (fortls-baseline.md A.2).
--   * "the legacy prose needs an intrinsic" fails if the `intrinsics.is` gate
--     is removed -- that gate IS the F4 fix.
--   * "no intrinsic is answered while fortls is attached" fails if the
--     `opts.fortls` gate on the legacy-prose branch is removed: all 82
--     intrinsics the JSON shares with fortls answer again and `K` on `size(a)`
--     is back to one ~320-line float with a `# fortls` / `# fortran-extras`
--     banner. It also fails the other way if the gate is widened into "answer
--     nothing when fortls is attached" -- the same test asserts the prose is
--     still served when it is not.
--   * "what fortls does not know is answered anyway" fails if the gate is put
--     on the whole of step 4 rather than on the legacy branch alone: every MPI
--     name, keyword, OpenMP runtime call and directive clause -- the entire
--     reason this server exists -- would go silent the moment fortls attached.
--   * "hover marks fortls from the attached clients" fails if `M.hover` stops
--     computing the flag, or computes it from the wrong buffer.
--   * "a word in a comment is not code" and "a word in a string is not code"
--     fail if the masked line stops being consulted.
--   * "a word on a directive line survives masking" fails if the RAW line
--     stops being the one searched: scan.mask blanks an entire `!$OMP` line,
--     so every directive hover would vanish.
--   * "hover over the wire answers a real buffer" fails if the handler is not
--     wired into lsp.dispatch, if the filetype guard rejects fortran, or if
--     the async project-index path never calls back.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_lsp_hover_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true
local assert_nil = _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local hover = require("andrew.fortran.lsp_hover")
local lsp = require("andrew.fortran.lsp")
local registry = require("andrew.fortran.registry")
local render = require("andrew.fortran.render")

-- Helpers -------------------------------------------------------------------

--- Answer for the first occurrence of `word` in `line`.
---@param line string
---@param word string
---@param opts table|nil
local function at(line, word, opts)
  local col = assert(line:find(word, 1, true), "fixture does not contain " .. word)
  return hover.answer(line, col, opts or {})
end

--- The markdown value of an answer, or nil.
local function value(res)
  return res and res.contents and res.contents.value or nil
end

-- Step 1 -- a word, in code ---------------------------------------------------

test("no identifier under the cursor answers nil", function()
  assert_nil(hover.answer("      x = 1 + 2", 10, {}), "an operator is not a word:")
  assert_nil(hover.answer("", 1, {}), "an empty line has no word:")
  assert_nil(hover.answer(nil, 1, {}), "a missing line answers nil:")
end)

test("a word in a comment is not code", function()
  -- `allocatable` is a registry keyword, so this can only answer nil because
  -- the masked line says the position is inside a comment.
  local line = "      x = 1 ! allocatable goes here"
  assert_nil(at(line, "allocatable"), "comment text is not documented:")
end)

test("a word in a string is not code", function()
  local line = "      msg = 'allocatable'"
  assert_nil(at(line, "allocatable"), "string contents are not documented:")
end)

test("a filetype outside FILETYPES answers nil", function()
  local line = "  real, allocatable :: a(:)"
  assert_true(at(line, "allocatable", { filetype = "fortran" }) ~= nil, "fortran answers:")
  assert_nil(at(line, "allocatable", { filetype = "python" }), "python does not:")
end)

-- Step 2 -- directive lines ---------------------------------------------------

test("a directive line never falls through to the intrinsic table", function()
  -- S3a. `sum` is a reduction operand here; the SUM intrinsic has nothing to
  -- do with it, and registry.directive() deliberately does not know the word.
  local line = "      !$OMP PARALLEL DO REDUCTION(+:sum)"
  assert_nil(at(line, "sum"), "a clause operand is not documented:")
  -- Proof that the same word DOES answer off a directive line, so the nil
  -- above is step 2's doing and not a missing entry.
  assert_true(at("      s = sum(a)", "sum") ~= nil, "off a directive line `sum` is the intrinsic:")
end)

test("a clause on a directive line is answered", function()
  local line = "!$OMP PARALLEL DO PRIVATE(i)"
  local v = value(at(line, "PRIVATE"))
  assert_true(v ~= nil, "PRIVATE is answered:")
  assert_eq(v:sub(1, #"```fortran\n(clause) PRIVATE(list)\n```\n---\n"), "```fortran\n(clause) PRIVATE(list)\n```\n---\n")
  -- PRIVATE is reachable ONLY through registry.directive(). The general index
  -- holds a DIFFERENT `private` -- the Fortran accessibility keyword -- so a
  -- step 2 that called registry.get() would answer the wrong documentation
  -- rather than none, which is the harder bug to notice.
  assert_eq(registry.get("private").kind, "keyword", "the general index holds the Fortran keyword:")
  assert_eq(registry.directive("private").kind, "clause", "the directive index holds the OpenMP clause:")
end)

test("a word on a directive line survives masking", function()
  -- scan.mask blanks the whole line -- it is a comment to the compiler. The
  -- word has to be found in the RAW line or every directive hover vanishes.
  local line = "      !$OMP PARALLEL DO"
  assert_true(at(line, "PARALLEL") ~= nil, "PARALLEL is found on a masked-out line:")
  local v = value(at(line, "DO"))
  assert_true(v ~= nil and v:find("(directive) !$OMP DO [clauses]", 1, true) ~= nil,
    "DO is the worksharing construct here, not the Fortran DO statement:")
end)

test("a directive hover ignores the project oracle", function()
  -- A project variable named `private` must not silence the clause: step 2
  -- returns before step 3 is ever reached.
  local line = "!$OMP PARALLEL DO PRIVATE(i)"
  assert_true(at(line, "PRIVATE", { locals = { private = true } }) ~= nil, "the clause still answers:")
end)

-- Step 3 -- fortls owns the project -------------------------------------------

test("a name defined in this buffer is fortls's", function()
  local line = "      call heat(t)"
  assert_nil(at(line, "heat", { locals = { heat = true } }), "the project's own subroutine is not ours:")
end)

test("a variable declared in this buffer is fortls's", function()
  -- F4. `count` is both an intrinsic and a perfectly ordinary counter name.
  local line = "      count = count + 1"
  assert_true(at(line, "count") ~= nil, "undeclared, it is the intrinsic:")
  assert_nil(at(line, "count", { locals = { count = true } }), "declared here, fortls owns it:")
end)

test("the buffer oracle reads defs AND decls", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "      subroutine heat(t)",
    "      integer :: count",
    "      end subroutine",
  })
  local names = hover.buffer_locals(buf)
  assert_true(names.heat, "the definition is known:")
  assert_true(names.t, "the dummy argument is known:")
  assert_true(names.count, "the local declaration is known:")
  assert_nil(names.mpi_comm_rank, "a name it never saw is not:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("a project symbol from the signature index is fortls's", function()
  local line = "      call heat(t)"
  local project = { heat = { name = "heat", args = { "t" } } }
  assert_nil(at(line, "heat", { project = project }), "the index answers for the project:")
end)

test("seeded builtins are not project symbols", function()
  -- lsp_inlayhint seeds the MPI/OpenMP signatures into the SAME index so
  -- library calls get argument hints. Reading those back as "the project
  -- defines it" would silence every MPI hover this server exists for.
  local line = "      call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)"
  local project = { mpi_comm_rank = { name = "MPI_Comm_rank", args = {}, builtin = true } }
  assert_true(at(line, "MPI_Comm_rank", { project = project }) ~= nil, "a seeded builtin stays ours:")
  assert_true(hover.is_project_symbol("mpi_comm_rank", nil, project) == false, "and is not a project symbol:")
end)

-- Step 4 -- the registry, then the legacy prose -------------------------------

test("MPI_Comm_rank renders design A1", function()
  local line = "      call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)"
  local res = at(line, "MPI_Comm_rank", { lnum = 12 })
  local v = value(res)
  assert_true(v ~= nil, "the call site is answered:")

  -- The whole payload is render.hover of the registry entry and nothing else:
  -- no second string builder, no cursor-spelling label.
  assert_eq(v, render.hover(registry.get("MPI_Comm_rank")).value, "hover delegates wholly to render:")
  assert_eq(res.contents.kind, "markdown", "markdown, not plaintext:")

  -- Design A1, asserted where it is most fragile: the `(kind) ` prefix inside
  -- the fence, the four-space dummy break, the aligned `::` column, the bare
  -- rule, the first prose line, and the ` · `-joined trailer.
  local head = "```fortran\n(subroutine) MPI_Comm_rank(\n    comm,\n    rank,\n    ierror\n)\n"
    .. "  integer, intent(in)  :: comm\n"
    .. "  integer, intent(out) :: rank\n"
    .. "  integer, intent(out) :: ierror\n```\n---\n"
    .. "Get the calling process's rank within a communicator.\n"
  assert_eq(v:sub(1, #head), head, "the A1 fence and first prose line:")
  assert_true(v:find("**Standard** MPI-1.0 · **See also** `MPI_Comm_size`, `MPI_COMM_WORLD`", 1, true) ~= nil,
    "the trailer is one ` · `-joined line:")
end)

test("the range covers exactly the word", function()
  local line = "      call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)"
  local res = at(line, "MPI_Comm_rank", { lnum = 12 })
  local r = res.range
  assert_eq(r.start.line, 11, "0-based line:")
  assert_eq(r["end"].line, 11, "one line only:")
  -- `MPI_Comm_rank` starts at byte 12 (1-based) and is 13 bytes long.
  assert_eq(r.start.character, 11, "0-based start byte:")
  assert_eq(r["end"].character, 24, "end is start + length:")
  assert_eq(line:sub(r.start.character + 1, r["end"].character), "MPI_Comm_rank", "the range slices the word:")
end)

test("the cursor spelling does not become the label", function()
  local line = "      call mpi_comm_rank(mpi_comm_world, rank, ierr)"
  local v = value(at(line, "mpi_comm_rank"))
  assert_true(v:find("(subroutine) MPI_Comm_rank(", 1, true) ~= nil, "the canonical case is shown:")
end)

test("a keyword is answered where fortls returns null", function()
  local line = "      real, allocatable :: a(:)"
  local v = value(at(line, "allocatable"))
  assert_true(v ~= nil, "a keyword is answered:")
  assert_eq(v:sub(1, #"```fortran\n(keyword) allocatable\n```\n---\n"), "```fortran\n(keyword) allocatable\n```\n---\n")
end)

test("a constant carries its parameter declaration", function()
  local line = "      call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)"
  local v = value(at(line, "MPI_COMM_WORLD"))
  assert_true(v ~= nil, "the constant is answered:")
  assert_true(v:find("```fortran\n(constant) MPI_COMM_WORLD\n  integer, parameter :: MPI_COMM_WORLD = 0\n```", 1, true) == 1,
    "the value as installed here is in the fence:")
end)

test("the legacy prose needs the name to be an intrinsic", function()
  -- `size` is in fortran-docs.json AND in intrinsics.lua -> answered, but only
  -- where fortls is not there to answer it first (see the fortls tests below).
  local v = value(at("      n = size(a)", "size"))
  assert_true(v ~= nil, "size gets the legacy prose with no fortls:")
  assert_true(v:find("size", 1, true) ~= nil, "and it is about size:")
  assert_nil(registry.get("size"), "which did not come from the registry:")
  assert_nil(at("      n = size(a)", "size", { fortls = true }), "and nothing at all with fortls:")

  -- F4. These four are keys in fortran-docs.json and are NOT intrinsics, so
  -- they can only ever be the user's own variables.
  for _, shadow in ipairs({ "dp", "mat", "pi", "vec" }) do
    local line = "      x = " .. shadow .. " + 1"
    assert_nil(at(line, shadow), "the snippet key `" .. shadow .. "` does not shadow a variable:")
  end
end)

test("an unknown word answers nil", function()
  assert_nil(at("      qqzz = 1", "qqzz"), "nothing invents an answer:")
end)

-- Step 4, the fortls half ------------------------------------------------------

test("no intrinsic is answered while fortls is attached", function()
  -- THE double-float regression. fortls documents every standard intrinsic
  -- itself, so the 82 names the legacy JSON also covers were answered TWICE:
  -- vim.lsp.buf.hover concatenated both into one float under `# fortls` and
  -- `# fortran-extras` banners (buf.lua:141-145), ~320 lines for `K` on
  -- `size(a)`. Rule B2 -- silent wherever fortls would answer -- applies to
  -- every one of them, not just to the project's own symbols.
  local intrinsics = require("andrew.fortran.intrinsics")
  local docs = require("andrew.fortran.docs")
  local checked, leaked = 0, {}
  for _, name in ipairs(intrinsics.names) do
    local prose = docs.get(name)
    if type(prose) == "string" and prose ~= "" then
      checked = checked + 1
      local line = "      x = " .. name .. "(a)"
      local res = at(line, name, { fortls = true })
      -- A handful of these names are ALSO registry entries (`kind` is a
      -- keyword, `logical` a type). fortls returns null for keywords and types
      -- (design A4), so those must keep answering -- from the registry, never
      -- from the prose.
      if registry.get(name) then
        assert_true(res ~= nil, "the registry still answers `" .. name .. "`:")
      elseif res ~= nil then
        leaked[#leaked + 1] = name
      end
      -- Without fortls the prose is still the fallback: a machine with no
      -- fortls installed must not lose the documentation it has today.
      assert_true(at(line, name) ~= nil, "`" .. name .. "` still answers with no fortls:")
    end
  end
  assert_true(checked >= 80, "the JSON's intrinsic overlap is still ~82 names (checked " .. checked .. "):")
  assert_eq(#leaked, 0, "intrinsics still answered under fortls: " .. table.concat(leaked, ", "))
end)

test("what fortls does not know is answered anyway", function()
  -- The other half of the rule, and the reason it is a per-name gate and not a
  -- blanket "stay silent when fortls is attached": fortls sees mpif.h as a
  -- stub, .mod files as binary, and returns null for keywords and for every
  -- `!$OMP` directive. Those are the whole point of this server.
  local cases = {
    { "      call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)", "MPI_Comm_rank" },
    { "      call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)", "MPI_COMM_WORLD" },
    { "      real, allocatable :: a(:)", "allocatable" },
    { "      t = omp_get_wtime()", "omp_get_wtime" },
    { "!$OMP PARALLEL DO PRIVATE(i)", "PRIVATE" },
  }
  for _, c in ipairs(cases) do
    assert_true(at(c[1], c[2], { fortls = true }) ~= nil, "`" .. c[2] .. "` is answered with fortls attached:")
  end
end)

test("hover marks fortls from the attached clients", function()
  -- The wiring: `answer` cannot see the buffer, so `hover` is the only place
  -- the flag can be computed. With no fortls client in this headless editor it
  -- must be false, which is what makes the prose reachable over the wire.
  -- A real file in a real (empty) project: the handler resolves a root and
  -- builds the signature index from it, and an unnamed scratch buffer would
  -- resolve the root to the CWD and scan this repository instead.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  local path = dir .. "/probe.f90"
  local src = "      n = size(a)"
  vim.fn.writefile({ src }, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "fortran"
  local got, done = nil, false
  hover.hover({
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = lsp.to_pos(1, src:find("size", 1, true)),
  }, function(_, result)
    got, done = result, true
  end)
  assert_true(vim.wait(10000, function()
    return done
  end, 10), "the handler called back:")
  assert_true(got ~= nil, "no fortls attached, so the prose is served:")
  hover.invalidate_locals(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(dir, "rf")
end)

-- End to end -----------------------------------------------------------------

test("hover over the wire answers a real buffer", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  local path = dir .. "/main.f90"
  local lines = {
    "program main",
    "  include 'mpif.h'",
    "  integer :: rank, ierr",
    "  call MPI_Init(ierr)",
    "  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)",
    "end program main",
  }
  vim.fn.writefile(lines, path)

  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = "fortran"

  local function request(lnum, col)
    local got, done = nil, false
    lsp.dispatch("textDocument/hover", {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = lsp.to_pos(lnum, col),
    }, function(_, result)
      got, done = result, true
    end)
    assert_true(vim.wait(10000, function()
      return done
    end, 10), "the handler called back:")
    return got
  end

  local call_line = lines[5]
  local res = request(5, call_line:find("MPI_Comm_rank", 1, true))
  assert_true(res ~= nil, "the server answered for MPI_Comm_rank:")
  assert_eq(res.contents.value, render.hover(registry.get("MPI_Comm_rank")).value, "with design A1:")
  assert_eq(res.range.start.line, 4, "on the call line:")

  -- `rank` is declared on line 3 of this very buffer, so fortls owns it and
  -- the double-hover banner can never appear for it.
  assert_nil(request(5, call_line:find("rank,", 1, true)), "a declared local is fortls's:")

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(dir, "rf")
end)

test("hover refuses a non-Fortran buffer", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "real, allocatable :: a(:)" })
  vim.bo[buf].filetype = "python"
  local got, done = nil, false
  hover.hover({
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 0, character = 8 },
  }, function(_, result)
    got, done = result, true
  end)
  assert_true(done, "answered synchronously:")
  assert_nil(got, "python is not ours:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

_H.finish()
