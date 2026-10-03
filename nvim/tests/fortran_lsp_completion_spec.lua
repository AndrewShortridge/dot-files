-- Spec for lua/andrew/fortran/lsp_completion.lua -- textDocument/completion
-- and completionItem/resolve for MPI, OpenMP and the Fortran keywords.
--
-- WHAT IT PINS
--
-- The blink source this replaces had three defects that a completion built on
-- the LSP shape cannot have, and each is asserted here as text:
--
--   1. It offered the same 388 items whatever the line said, so on
--      `!$OMP PARALLEL DO PRIV` the menu was led by the PARITY intrinsic and
--      the clause was eighth (omp-audit A-F1).
--   2. Its items carried no textEdit, so blink inserted the LABEL -- and the
--      labels were documentation keys. Accepting the clause wrote
--      `!$OMP PARALLEL DO omp_private`, which no compiler accepts (A-F2).
--   3. Every item carried its full markdown body on every keystroke.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "a clause on a directive line" fails if label/filterText/newText are
--     collapsed back onto one string -- newText `PRIVATE($1)` is exactly the
--     A-F2 fix, and filterText `private` is what makes `priv` match a label
--     that starts with `P` and ends with `(…)`.
--   * "a clause with an argument list is a snippet" fails if `insertTextFormat`
--     goes back to 1 or the `$1` is dropped: nvim-autopairs does NOT close the
--     paren of an accepted completion (it reacts to typed keys) and blink's
--     auto_brackets only fires for Function/Method kinds, so the line was left
--     as `PRIVATE(` with no `)`.
--   * "the sentinel window" fails if `$` goes back to triggering nothing: at
--     `!$` the answer was zero items and at `!$OM` it was 168 omp_lib runtime
--     routines, none of which is legal on a directive line.
--   * "the textEdit range covers the typed prefix" fails if the range is built
--     from anything but the byte offsets of the prefix; a UTF-16 slip moves it.
--   * "directives only right after the sentinel" fails if the head-vs-clause
--     split is dropped: clauses would be offered where only a directive is
--     legal and vice versa.
--   * "off a directive line nothing OpenMP-syntactic is offered" fails if the
--     directive branch ever falls through to the general registry.
--   * "an MPI procedure in a call" fails if labelDetails is dropped (the
--     provenance column goes dark) or if documentation is attached eagerly.
--   * "resolve adds exactly one field" fails if resolve rebuilds the item, and
--     the `(subroutine) ` assertion fails if hover's prefix leaks into
--     completion_doc (design A6).
--   * "every sortText is a bucket" fails on any item that forgets one.
--   * "intrinsics are never offered" fails the moment the registry's keyword
--     file or fortls's own list is merged in -- blink does not dedupe.
--   * "a snippet prefix is demoted" fails if the bucket-12 rule is dropped,
--     which is how `ompdo<CR>` used to insert the literal word.
--   * "inside a comment" fails if the masker is skipped.
--   * "through the server" fails if lsp.lua stops dispatching the method.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_lsp_completion_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil, assert_match, assert_deep_eq =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil, _H.assert_match, _H.assert_deep_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local C = require("andrew.fortran.lsp_completion")
local lsp = require("andrew.fortran.lsp")

--- Items for `line` with the cursor at the end of it (or at `col` bytes).
---@param line string
---@param col integer|nil 0-based byte offset
---@param opts table|nil
local function items(line, col, opts)
  return C.items(line, col or #line, opts or {})
end

---@param list table[]
---@param label string
---@return table|nil
local function by_label(list, label)
  for _, it in ipairs(list) do
    if it.label == label then
      return it
    end
  end
  return nil
end

---@param list table[]
---@return table<string, boolean>
local function label_set(list)
  local set = {}
  for _, it in ipairs(list) do
    set[it.label] = true
  end
  return set
end

-- ---------------------------------------------------------------------------
-- Directive lines
-- ---------------------------------------------------------------------------

test("a clause on a directive line inserts PRIVATE(, matches priv, shows PRIVATE(…)", function()
  local line = "      !$OMP PARALLEL DO priv"
  local got = items(line)
  local it = by_label(got, "PRIVATE(…)")
  assert_true(it ~= nil, "no PRIVATE clause offered on a PARALLEL DO line:")
  assert_eq(it.filterText, "private", "filterText must be the bare word blink matches on:")
  assert_eq(it.textEdit.newText, "PRIVATE($1)", "the A-F2 bug: what gets INSERTED:")
  assert_eq(it.insertTextFormat, 2, "a clause with an argument list must expand as a snippet:")
  assert_eq(it.kind, 14, "clauses are keywords:")
  assert_eq(it.detail, "clause")
  assert_eq(it.labelDetails.description, "OpenMP 5.2", "the provenance column:")
  assert_nil(it.documentation, "the initial item must carry no documentation:")
  assert_eq(it.data.k, "private", "resolve keys off the registry key:")
end)

test("the textEdit range covers the typed prefix in bytes", function()
  local line = "      !$OMP PARALLEL DO priv"
  local it = by_label(items(line, #line, { line = 7 }), "PRIVATE(…)")
  assert_eq(it.textEdit.range.start.line, 7, "start line:")
  assert_eq(it.textEdit.range["end"].line, 7, "end line:")
  assert_eq(it.textEdit.range["end"].character, #line, "the range ends at the cursor:")
  assert_eq(it.textEdit.range.start.character, #line - 4, "the range starts at `priv`:")
  assert_eq(line:sub(it.textEdit.range.start.character + 1, it.textEdit.range["end"].character), "priv",
    "the range must index the typed prefix:")
end)

test("directives only right after the sentinel, clauses only after one", function()
  local head = items("      !$OMP ")
  local labels = label_set(head)
  assert_true(labels["PARALLEL DO"], "PARALLEL DO must be offered right after the sentinel:")
  assert_true(labels["BARRIER"], "BARRIER must be offered right after the sentinel:")
  assert_nil(labels["PRIVATE(…)"], "a clause is not legal before a directive word:")
  for _, it in ipairs(head) do
    assert_eq(it.detail, "directive", "only directives here, got " .. it.label .. ":")
  end

  -- ...and after a directive word, only clauses.
  local tail = items("      !$OMP PARALLEL DO ")
  assert_true(#tail > 5, "a bare clause position must list the directive's clauses:")
  for _, it in ipairs(tail) do
    assert_eq(it.detail, "clause", "only clauses here, got " .. it.label .. ":")
  end
end)

--- `line` with `it`'s textEdit applied, and the byte offset of the `$1` stop.
---@param line string
---@param it table
---@return string
local function apply(line, it)
  local r = it.textEdit.range
  local text = it.textEdit.newText:gsub("%$1", "")
  return line:sub(1, r.start.character) .. text .. line:sub(r["end"].character + 1)
end

test("the `$` trigger opens the sentinel window, and only directives are in it", function()
  -- `$` is this server's one completion trigger character (design E1). Typing
  -- it used to answer nothing at all, and one letter later the menu filled
  -- with omp_lib RUNTIME routines, which are illegal on a directive line.
  for _, before in ipairs({ "!$", "!$O", "!$OM", "!$OMP", "      !$om" }) do
    local got = items(before, #before, { trigger_kind = 2, triggerCharacter = "$" })
    assert_true(#got >= 40, before .. " offered only " .. #got .. " items:")
    for _, it in ipairs(got) do
      assert_eq(it.detail, "directive", before .. " offered a non-directive (" .. it.label .. "):")
      assert_match(it.label, "^OMP ", before .. " must complete the sentinel too:")
      assert_match(it.textEdit.newText, "^OMP ", before .. " newText:")
      assert_match(it.sortText, "^00%.0000%.", before .. " must sort in the grammar bucket:")
      assert_nil(it.documentation, "the window's items carry no documentation either:")
    end
  end
  -- Nothing from the runtime, the keywords or MPI leaks in.
  local labels = label_set(items("!$OM", 4, { trigger_kind = 2 }))
  assert_nil(labels["omp_aligned_alloc"], "an omp_lib runtime routine in the sentinel window:")
  assert_nil(labels["omp_get_wtime"], "an omp_lib runtime routine in the sentinel window:")
  assert_nil(labels["MPI_Init"], "MPI in the sentinel window:")
end)

test("accepting from the sentinel window writes a whole directive line", function()
  for _, before in ipairs({ "!$", "!$O", "!$OM", "!$OMP" }) do
    local it = by_label(items(before, #before, { trigger_kind = 2 }), "OMP PARALLEL DO")
    assert_true(it ~= nil, "OMP PARALLEL DO is not offered on `" .. before .. "`:")
    assert_eq(it.filterText, "omp parallel do", "filterText is what the user is typing:")
    assert_eq(it.textEdit.range.start.character, 2, "the edit starts just past the `$`:")
    assert_eq(it.textEdit.range["end"].character, #before, "and ends at the cursor:")
    assert_eq(apply(before, it), "!$OMP PARALLEL DO", "accepting `" .. before .. "`:")
  end
  -- resolve still reaches the directive index through the same data key.
  local it = by_label(items("!$", 2, { trigger_kind = 2 }), "OMP PARALLEL DO")
  assert_eq(it.data.k, "parallel_do", "resolve keys off the registry key:")
end)

test("the sentinel window closes on the space", function()
  -- `!$ ` is conditional compilation of ORDINARY Fortran, so the window is
  -- gone and the line completes as code (nothing, with no prefix typed).
  assert_eq(#items("!$ ", 3, { trigger_kind = 2 }), 0, "`!$ ` is a code line:")
  assert_eq(#items("!$ x", 4, { trigger_kind = 2 }), 0, "`!$ x` has no registry match:")
  -- ...and a cursor parked in front of existing text is an edit, not a sentinel.
  for _, it in ipairs(items("!$OMP PARALLEL", 2, { trigger_kind = 2 })) do
    assert_true(it.label:sub(1, 4) ~= "OMP ", "the window must not fire mid-line: " .. it.label)
  end
end)

test("a partial directive matches on the spelling with the space", function()
  local got = items("      !$omp par")
  local it = by_label(got, "PARALLEL DO")
  assert_true(it ~= nil, "`par` must reach PARALLEL DO:")
  assert_eq(it.filterText, "parallel do", "filterText carries the displayed spelling:")
  assert_eq(it.textEdit.newText, "PARALLEL DO", "directives are inserted upper case:")
  assert_eq(it.sortText, "00.0000.parallel_do", "directives are syntactically required here:")
  assert_eq(it.labelDetails.description, "OpenMP 5.2")
  -- The run-together spelling still matches, with a filterText blink can see.
  local flat = by_label(items("      !$omp paralleldo"), "PARALLEL DO")
  assert_true(flat ~= nil, "`paralleldo` must reach PARALLEL DO too:")
  assert_eq(flat.filterText, "paralleldo", "filterText follows the spelling being typed:")
end)

test("a clause illegal on this directive is not offered", function()
  -- NOWAIT is valid on DO and not on PARALLEL DO -- the parallel region's
  -- closing barrier cannot be removed.
  assert_true(by_label(items("      !$OMP DO now"), "NOWAIT") ~= nil, "NOWAIT belongs on DO:")
  assert_nil(by_label(items("      !$OMP PARALLEL DO now"), "NOWAIT"),
    "NOWAIT is illegal on PARALLEL DO:")
  -- A bare clause with no argument list inserts no paren, and no snippet.
  local nowait = by_label(items("      !$OMP DO now"), "NOWAIT")
  assert_eq(nowait.textEdit.newText, "NOWAIT")
  assert_eq(nowait.insertTextFormat, 1, "a clause with no argument list is plain text:")
end)

test("off a directive line no clause or directive is offered at all", function()
  for _, line in ipairs({
    "      call do_work(priv",
    "      priv",
    "      integer :: priv",
    "      ! !$OMP PARALLEL DO priv",
  }) do
    for _, it in ipairs(items(line)) do
      assert_true(it.detail ~= "clause" and it.detail ~= "directive",
        "OpenMP syntax leaked onto `" .. line .. "` as " .. it.label .. ":")
    end
  end
  -- The Fortran statement keyword of the same spelling is still fine.
  local kw = by_label(items("      priv"), "private")
  assert_true(kw == nil or kw.detail == "keyword", "`private` off a directive line is the statement:")
end)

-- ---------------------------------------------------------------------------
-- Ordinary lines
-- ---------------------------------------------------------------------------

test("an MPI procedure in a call carries its dummies and its module", function()
  local got = items("      call MPI_Comm_r")
  local it = by_label(got, "MPI_Comm_rank")
  assert_true(it ~= nil, "MPI_Comm_rank is not offered after `call MPI_Comm_r`:")
  assert_eq(it.kind, 3, "a subroutine is a Function item:")
  assert_eq(it.detail, "subroutine")
  assert_eq(it.labelDetails.detail, "(comm, rank, ierror)", "the dummy list column:")
  assert_eq(it.labelDetails.description, "mpi", "the provenance column:")
  assert_nil(it.documentation, "documentation must wait for resolve:")
  assert_eq(it.textEdit.newText, "MPI_Comm_rank", "inserted in canonical case:")
  assert_eq(it.sortText, "09.9999.mpi_comm_rank")
  assert_deep_eq(it.data, { k = "mpi_comm_rank" }, "resolve data:")
end)

test("after `call` only subroutines, after `use` only modules", function()
  for _, it in ipairs(items("      call MPI_")) do
    assert_eq(it.detail, "subroutine", it.label .. " is not callable:")
  end
  local mods = label_set(items("      use omp_"))
  assert_true(mods["omp_lib"], "`use omp_` must offer omp_lib:")
  assert_true(mods["omp_lib_kinds"], "`use omp_` must offer omp_lib_kinds:")
  assert_nil(mods["omp_get_wtime"], "a runtime routine is not a module:")
  assert_true(label_set(items("      use mpi"))["mpi_f08"], "`use mpi` must offer mpi_f08:")
end)

test("intrinsics are never offered -- fortls owns them and blink does not dedupe", function()
  for _, line in ipairs({ "      x = si", "      y = su", "      n = cou", "      call flu" }) do
    for _, it in ipairs(items(line)) do
      local l = it.label:lower()
      assert_true(l ~= "size" and l ~= "sum" and l ~= "count" and l ~= "flush",
        "intrinsic `" .. it.label .. "` offered on `" .. line .. "`:")
    end
  end
end)

test("a name that repeats a snippet prefix is demoted to bucket 12", function()
  -- ./snippets contributes an `mpi_init` snippet that expands to the full
  -- call; the bare name must not outrank it.
  assert_true(C.snippet_prefixes()["mpi_init"], "the mpi_init snippet prefix is gone:")
  local it = by_label(items("      call MPI_Ini"), "MPI_Init")
  assert_true(it ~= nil, "MPI_Init is not offered:")
  assert_match(it.sortText, "^12%.", "a snippet-shadowing name must sort in bucket 12:")
  -- A name with no snippet stays in the normal-symbol bucket.
  assert_match(by_label(items("      call MPI_Comm_r"), "MPI_Comm_rank").sortText, "^09%.",
    "a name with no snippet keeps bucket 09:")
end)

test("a Fortran statement keyword sorts below the library names", function()
  local it = by_label(items("      alloca", 13, { trigger_kind = 1 }), "allocatable")
  assert_true(it ~= nil, "`allocatable` is not offered:")
  assert_eq(it.kind, 14, "a keyword item:")
  assert_match(it.sortText, "^1[02]%.", "keywords sort below MPI/OpenMP names:")
end)

test("every sortText is a bucketed sort key", function()
  local seen = 0
  for _, line in ipairs({
    "      !$OMP ",
    "      !$OMP PARALLEL DO ",
    "      call MPI_Comm_r",
    "      use omp_",
    "      x = omp_get_",
  }) do
    for _, it in ipairs(items(line)) do
      assert_match(it.sortText, "^%d%d%.%d%d%d%d%.", it.label .. " has no sort bucket:")
      seen = seen + 1
    end
  end
  assert_true(seen > 50, "too few items inspected to mean anything: " .. seen)
end)

test("inside a comment or a string nothing is offered", function()
  assert_eq(#items("      ! call MPI_Comm_r"), 0, "inside a comment:")
  assert_eq(#items("      x = 'call MPI_Comm_r'", 25), 0, "inside a string literal:")
end)

test("an empty prefix answers only an explicit invoke", function()
  assert_eq(#items("      x = ", 10), 0, "a keystroke with no prefix must not dump the registry:")
  assert_true(#items("      x = ", 10, { trigger_kind = 1 }) > 500, "<C-space> lists everything:")
end)

-- ---------------------------------------------------------------------------
-- resolve
-- ---------------------------------------------------------------------------

--- Synchronously resolve `item`.
---@param item table
---@return table
local function resolve(item)
  local out
  C.resolve(item, function(_, res)
    out = res
  end)
  return out
end

test("resolve adds exactly one field and drops hover's (kind) prefix", function()
  local it = by_label(items("      call MPI_Comm_r"), "MPI_Comm_rank")
  local before = {}
  for k in pairs(it) do
    before[k] = true
  end
  local out = resolve(it)
  local added = {}
  for k in pairs(out) do
    if not before[k] then
      added[#added + 1] = k
    end
  end
  assert_deep_eq(added, { "documentation" }, "resolve must add documentation and nothing else:")
  assert_eq(out.documentation.kind, "markdown")
  assert_eq(out.documentation.value:sub(1, 26), "```fortran\nMPI_Comm_rank(\n",
    "the completion body carries no `(subroutine) ` prefix (design A6):")
end)

test("resolve answers a clause from the directive index, not the keyword file", function()
  local it = by_label(items("      !$OMP PARALLEL DO priv"), "PRIVATE(…)")
  local out = resolve(it)
  assert_match(out.documentation.value, "^```fortran\nPRIVATE%(list%)\n```",
    "the clause body, not the Fortran PRIVATE statement:")
end)

test("resolve leaves an unknown item untouched", function()
  local out = resolve({ label = "sentinel", data = { k = "no_such_name_at_all" } })
  assert_eq(out.label, "sentinel")
  assert_nil(out.documentation, "an unknown key must add nothing:")
  assert_nil(resolve({ label = "bare" }).documentation, "an item with no data must add nothing:")
end)

-- ---------------------------------------------------------------------------
-- Through the server
-- ---------------------------------------------------------------------------

test("textDocument/completion answers through lsp.dispatch", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".f90")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "program p",
    "      !$OMP PARALLEL DO priv",
    "end program p",
  })
  vim.bo[buf].filetype = "fortran"

  local result
  lsp.dispatch("textDocument/completion", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 1, character = 28 },
    context = { triggerKind = 2, triggerCharacter = "$" },
  }, function(_, res)
    result = res
  end)

  assert_true(result ~= nil, "the server answered nothing:")
  assert_eq(result.isIncomplete, false, "the list is complete:")
  local it = by_label(result.items, "PRIVATE(…)")
  assert_true(it ~= nil, "PRIVATE is not reachable over the server:")
  assert_eq(it.textEdit.newText, "PRIVATE($1)")
  assert_eq(it.insertTextFormat, 2, "the snippet format survives the server round trip:")
  assert_eq(it.textEdit.range.start.line, 1, "the range is on the requested line:")

  -- ...and resolve over the same channel.
  local resolved
  lsp.dispatch("completionItem/resolve", it, function(_, res)
    resolved = res
  end)
  assert_true(resolved.documentation ~= nil, "resolve over the server added nothing:")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("completion is cheap enough for a keystroke", function()
  local line = "      call MPI_Comm_r"
  C.items(line, #line, {}) -- warm the caches
  local t0 = vim.uv.hrtime()
  for _ = 1, 100 do
    C.items(line, #line, {})
  end
  local ms = (vim.uv.hrtime() - t0) / 1e6 / 100
  assert_true(ms < 5, ("%.3f ms/call over ~975 candidates, budget 5 ms:"):format(ms))
end)

_H.finish()
