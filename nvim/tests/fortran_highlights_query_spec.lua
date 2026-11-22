-- Spec for queries/fortran/highlights.scm.
--
-- That file EXTENDS nvim-treesitter's Fortran highlights so the colour
-- schemes' two style rules (keywords italic, procedure names bold) reach the
-- tokens upstream leaves uncaptured, and so an intrinsic procedure and a
-- statement written like a call can be told apart.
--
-- What it guards:
--   * A node or token name the installed grammar does not have makes the
--     whole highlights query fail to compile -- upstream's part included --
--     which is a Fortran buffer with no colour at all. Test 2 fails then.
--   * Test 3 fails if the file loses its ";; extends" modeline: it would then
--     REPLACE upstream's query and every capture not listed in it would go.
--   * Tests 4-7 fail if a pattern stops matching (a grammar update renaming a
--     node keeps compiling when the name still exists elsewhere).
--   * Test 8 fails when the intrinsic names in the query and
--     andrew.fortran.intrinsics drift apart; the query cannot read the Lua
--     list, so it carries a copy.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_highlights_query_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local config_dir = vim.fn.stdpath("config")
local QUERY_PATH = config_dir .. "/queries/fortran/highlights.scm"

-- The config dir first so its query files are found; removed before it is
-- prepended because from Neovim 0.13 `:prepend()` leaves an entry that is
-- already listed where it is.
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/nvim-treesitter")
vim.opt.runtimepath:remove(config_dir)
vim.opt.runtimepath:prepend(config_dir)

local SAMPLE = {
  "module shapes",
  "  use mpi, only: MPI_Wtime",
  "  implicit none",
  "  type :: shape",
  "  contains",
  "    procedure :: describe => describe_shape",
  "  end type shape",
  "contains",
  "  subroutine describe_shape(self)",
  "    class(shape), intent(in) :: self",
  "    character(len=8) :: label",
  "    real, allocatable :: buffer(:)",
  "    real :: started",
  "    allocate (buffer(3))",
  "    started = MPI_Wtime() + SQRT(abs(buffer(1))) * (-cos(buffer(2)))",
  "    call random_number(buffer)",
  "    call self%describe()",
  "    select case (size(buffer))",
  "    case (3)",
  "      write (*, *) trim(label)",
  "    end select",
  "    outer: do while (started > 0)",
  "      if (started > 1) cycle outer",
  "      if (started > 2) stop started",
  "    end do outer",
  "    flush (6)",
  "    deallocate (buffer)",
  "  end subroutine describe_shape",
  "end module shapes",
}

--- Every capture the highlights query makes in SAMPLE, by the text it is on:
--- `captures["write"]["function.builtin.statement"] == true`.
---@return table<string, table<string, true>>
local function sample_captures()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, SAMPLE)
  local parser = assert(vim.treesitter.get_parser(buf, "fortran"))
  local root = parser:parse()[1]:root()
  local query = assert(vim.treesitter.query.get("fortran", "highlights"))

  local captures = {} ---@type table<string, table<string, true>>
  for id, node in query:iter_captures(root, buf, 0, -1) do
    local text = vim.treesitter.get_node_text(node, buf)
    captures[text] = captures[text] or {}
    captures[text][query.captures[id]] = true
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return captures
end

--- Assert that every word of `words` carries `capture` in SAMPLE.
---@param captures table<string, table<string, true>>
---@param capture string
---@param words string[]
local function assert_captured(captures, capture, words)
  for _, word in ipairs(words) do
    assert_true(
      captures[word] ~= nil and captures[word][capture] == true,
      ("`%s` must be @%s (has: %s)"):format(word, capture, table.concat(vim.tbl_keys(captures[word] or {}), ", "))
    )
  end
end

test("the fortran parser is available (guards against vacuous passes)", function()
  local ok = pcall(vim.treesitter.language.add, "fortran")
  assert_true(ok, "fortran parser must be installed -- every assertion below is meaningless without it")
end)

test("the highlights query compiles with this config's additions", function()
  local ok, query = pcall(vim.treesitter.query.get, "fortran", "highlights")
  assert_true(ok, "query must compile: " .. tostring(query))
  assert_true(query ~= nil, "query must not be nil")
end)

test("the additions extend upstream's query instead of replacing it", function()
  local files = vim.treesitter.query.get_files("fortran", "highlights")
  assert_true(vim.list_contains(files, QUERY_PATH), "the config's file must be part of the query")
  assert_true(#files >= 2, "upstream's file must be part of it too: without `;; extends` ours replaces it")
  -- Upstream's own captures still arrive.
  local captures = sample_captures()
  assert_captured(captures, "keyword.function", { "subroutine", "call" })
  assert_captured(captures, "type.builtin", { "real" })
end)

test("keywords upstream leaves uncaptured are keywords", function()
  local captures = sample_captures()
  assert_captured(captures, "keyword", { "case" })
  assert_captured(captures, "keyword.import", { "only" })
end)

test("a statement written like a call is not an intrinsic procedure, and the reverse", function()
  local captures = sample_captures()
  assert_captured(captures, "function.builtin.statement", { "write", "allocate", "deallocate", "flush" })
  -- `cos` is the signed call `-cos(x)`, which the grammar nests differently.
  assert_captured(captures, "function.builtin.intrinsic", { "SQRT", "abs", "size", "trim", "random_number", "cos" })
  for _, statement in ipairs({ "write", "allocate", "deallocate", "flush" }) do
    assert_true(
      not captures[statement]["function.builtin.intrinsic"],
      statement .. " would be drawn bold AND italic with both captures"
    )
  end
  assert_true(
    not captures["character"]["function.builtin.statement"],
    "`character` is a type: styling it is what the two captures exist to avoid"
  )
end)

test("type-bound procedures and library functions are procedure names", function()
  local captures = sample_captures()
  assert_captured(captures, "function.method", { "describe", "describe_shape" })
  assert_captured(captures, "function.method.call", { "describe" })
  assert_captured(captures, "function.call", { "MPI_Wtime" })
  assert_true(not captures["buffer"]["function.call"], "an array element is not a call")
end)

test("construct names are labels and a used module is a module", function()
  local captures = sample_captures()
  -- The name is written three times: `outer: do`, `cycle outer`, `end do outer`.
  assert_captured(captures, "label", { "outer" })
  assert_true(not captures["outer:"], "the colon stays punctuation: only the name is the label")
  assert_true(not captures["started"]["label"], "`stop started` names a variable, not a construct")
  assert_captured(captures, "module", { "mpi", "shapes" })
end)

test("the query's intrinsic names are andrew.fortran.intrinsics' names", function()
  local alternation ---@type string?
  for _, line in ipairs(vim.fn.readfile(QUERY_PATH)) do
    alternation = alternation or line:match('#match%? @function%.builtin%.intrinsic "\\\\c\\\\v%^%((.-)%)%$"')
  end
  assert_true(alternation ~= nil, "the intrinsic pattern must be findable in the query file")
  ---@cast alternation -nil

  local expected = {} ---@type string[]
  for _, name in ipairs(require("andrew.fortran.intrinsics").names) do
    -- `flush (6)` is the statement; see the query file.
    if name ~= "flush" then
      expected[#expected + 1] = name
    end
  end
  table.sort(expected)

  assert_eq(
    alternation,
    table.concat(expected, "|"),
    "regenerate the list in queries/fortran/highlights.scm: the sorted names joined with `|`"
  )
end)

_H.finish({ style = "results", exit = "os" })
