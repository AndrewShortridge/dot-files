-- Spec for queries/fortran/context.scm.
--
-- nvim-treesitter-context ships a Fortran context query written against an
-- older tree-sitter-fortran grammar. Against the grammar nvim-treesitter
-- installs here it does not compile:
--
--   Unable to load context query for fortran:
--   query.lua:374: Query error at 11:2. Invalid node type "do_loop"
--
-- A query that fails to compile is discarded WHOLE, so the symptom was not
-- "no context on do-loops" but "no sticky context in Fortran at all", plus an
-- error on every .f90 open. queries/fortran/context.scm replaces it with the
-- two stale node names corrected (do_loop -> do_loop_statement; do_statement
-- gone, loop_control_expression is now a direct child).
--
-- Drives the REAL query against the REAL installed parser. No source
-- introspection: it compiles the query, runs it over a parsed Fortran buffer,
-- and asserts on the captures.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * Test 2 fails if the override is removed or renamed -- the plugin's broken
--     query becomes the base again and compilation errors.
--   * Test 3 fails if the override gains a ";; extends" modeline, which would
--     APPEND to the broken upstream query instead of replacing it (the single
--     easiest way to silently undo this fix).
--   * Test 4 fails if do_loop_statement is dropped or misspelled again.
--
-- Run with: nvim --headless -u NONE -l tests/fortran_context_query_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

local config_dir = vim.fn.stdpath("config")
local lazy_dir = vim.fn.stdpath("data") .. "/lazy"

-- Config dir FIRST so its queries win; the context plugin is added too, so the
-- precedence claim is actually exercised rather than assumed.
vim.opt.runtimepath:prepend(lazy_dir .. "/nvim-treesitter-context")
vim.opt.runtimepath:prepend(lazy_dir .. "/nvim-treesitter")
vim.opt.runtimepath:prepend(config_dir)

local SAMPLE = table.concat({
  "program demo",
  "  implicit none",
  "  integer :: i, n",
  "  n = 3",
  "  do i = 1, n",
  "    if (i > 1) then",
  "      n = n + i",
  "    end if",
  "  end do",
  "contains",
  "  subroutine helper(a)",
  "    integer, intent(in) :: a",
  "  end subroutine helper",
  "end program demo",
}, "\n")

test("the fortran parser is available (guards against vacuous passes)", function()
  local ok = pcall(vim.treesitter.language.add, "fortran")
  assert_true(ok, "fortran parser must be installed -- every assertion below is meaningless without it")
  local sym = vim.treesitter.language.inspect("fortran").symbols
  assert_true(sym["do_loop_statement"] == true, "installed grammar must have do_loop_statement")
  assert_false(sym["do_loop"] == true, "and must NOT have do_loop -- that is the whole reason this override exists")
end)

test("this config's override is the base query, not the plugin's", function()
  local files = vim.treesitter.query.get_files("fortran", "context")
  assert_true(#files > 0, "some context query must resolve")
  assert_eq(
    files[1],
    config_dir .. "/queries/fortran/context.scm",
    "the config's query must be the base; if the plugin's file wins, its stale node names break compilation"
  )
  for _, f in ipairs(files) do
    assert_false(
      f:find("nvim%-treesitter%-context"),
      "the plugin's broken query must be DISCARDED, not appended -- a \";; extends\" modeline would pull it back in"
    )
  end
end)

test("the context query compiles against the installed grammar", function()
  local ok, q = pcall(vim.treesitter.query.get, "fortran", "context")
  assert_true(ok, "query must compile: " .. tostring(q))
  assert_true(q ~= nil, "query must not be nil")
end)

test("it actually matches -- compiling is not enough", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(SAMPLE, "\n"))
  vim.bo[buf].filetype = "fortran"

  local parser = assert(vim.treesitter.get_parser(buf, "fortran"))
  local root = parser:parse()[1]:root()
  local q = assert(vim.treesitter.query.get("fortran", "context"))

  local seen, total = {}, 0
  for id, node in q:iter_captures(root, buf, 0, -1) do
    if q.captures[id] == "context" then
      seen[node:type()] = true
      total = total + 1
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })

  assert_true(total > 0, "the query must capture something")
  for _, want in ipairs({ "program", "do_loop_statement", "if_statement", "subroutine" }) do
    assert_true(seen[want], "missing @context capture for " .. want)
  end
end)

_H.finish({ style = "results", exit = "os" })
