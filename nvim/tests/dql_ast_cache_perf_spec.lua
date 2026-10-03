-- Perf regression spec for the DQL content->AST cache (issue L).
--
-- THE BUG (now fixed): query/init.lua's result cache keys on (kind, generation,
-- current_file, content), so EVERY index-generation bump (every vault save) was
-- a result-cache miss that re-ran parser.parse(content) — re-tokenizing and
-- rebuilding the AST from scratch — even when the query text was byte-identical.
-- The AST is a pure function of content and never goes stale (the executor only
-- READS it), so the fix adds a bounded content->AST cache keyed on content ALONE
-- (independent of generation), mirroring the js2lua transpile cache.
--
-- DISCRIMINATING POWER: this spec monkeypatches the REAL parser.parse (the
-- function the AST cache is supposed to bypass) with a counting wrapper, then
-- renders the SAME dataview block before and after a REAL generation bump.
-- With the AST cache, the post-bump render re-EXECUTES (result-cache miss) but
-- does NOT re-parse: parse_count stays 1 while exec_count advances to 2.
-- Revert parse_cached() back to a direct parser.parse(content) call (the pre-fix
-- behavior) and the post-gen-bump render re-parses, pushing parse_count to 2 and
-- FAILING assertion #1. (Manually verified once during implementation.)
--
-- Drives the REAL modules against a temp vault (no mocks, no source
-- introspection — only behavioral instrumentation of public module functions).
--
-- Run with: nvim --headless -u NONE -l tests/dql_ast_cache_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local parser = require("andrew.vault.query.parser")
local executor = require("andrew.vault.query.executor")
local query = require("andrew.vault.query")

print("\n=== DQL AST Cache Perf Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault helpers.
-- ---------------------------------------------------------------------------
local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

local function make_vault()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "alpha.md", { "---", "tags: [topic]", "---", "# Alpha", "Body." })
  write_file(dir, "beta.md", { "---", "tags: [topic]", "---", "# Beta", "Body." })
  write_file(dir, "home.md", { "# Home", "" })
  return dir
end

local function setup_vault(dir)
  vault_index._instance = nil
  local vi = vault_index.get(dir)
  vi:build_sync()
  engine.vault_path = dir
  -- Drop ALL registered caches (incl. the content-keyed AST cache, which
  -- otherwise persists across tests because rebuild_index does not clear it),
  -- giving each test a clean parse_count baseline.
  -- skip_index: do NOT kick off a vault_index build_async (it would set the
  -- _building flag and block the later update_file generation bump in headless,
  -- where no event loop completes the async build).
  engine.invalidate_caches({ scope = "all", skip_index = true })
  -- Force the query index to rebuild against this fresh vault.
  query.rebuild_index()
  return vi
end

-- Spy counters installed on the REAL module functions. query/init.lua holds
-- parser/executor as upvalues pointing at these shared tables, so replacing the
-- field is seen by the module.
local parse_count = 0
local exec_count = 0
local real_parse = parser.parse
local real_execute = executor.execute
parser.parse = function(...)
  parse_count = parse_count + 1
  return real_parse(...)
end
executor.execute = function(...)
  exec_count = exec_count + 1
  return real_execute(...)
end

-- Create a scratch buffer with one or more dataview blocks.
local function make_buffer(dir, name, blocks)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. name)
  local lines = { "# Notes", "" }
  for _, content in ipairs(blocks) do
    lines[#lines + 1] = "```dataview"
    for _, l in ipairs(vim.split(content, "\n", { plain = true })) do
      lines[#lines + 1] = l
    end
    lines[#lines + 1] = "```"
    lines[#lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

-- ===========================================================================
-- 1. Generation bump: re-execute WITHOUT re-parse (discriminating core).
-- ===========================================================================
test("generation bump re-executes but reuses the cached AST (no re-parse)", function()
  local dir = make_vault()
  local vi = setup_vault(dir)
  make_buffer(dir, "home.md", { "LIST FROM #topic" })

  parse_count, exec_count = 0, 0
  query.render_all() -- cold: parse + execute once
  assert_eq(parse_count, 1, "cold render parses once")
  assert_eq(exec_count, 1, "cold render executes once")

  -- Real vault edit -> reindex -> generation bump.
  local gen_before = vi._generation
  write_file(dir, "gamma.md", { "---", "tags: [topic]", "---", "# Gamma", "New." })
  vi:update_file(dir .. "/gamma.md")
  -- Rebuild the query index WITHOUT the registered invalidate hook clearing our
  -- caches: rebuild_index() invalidates the query_index cache only via its own
  -- path; the result/AST caches stay populated and rely on the generation key.
  query.rebuild_index()
  assert_true(vi._generation ~= gen_before, "vault generation advanced after edit")

  query.render_all() -- post-bump: result-cache miss -> re-execute, AST cache hit
  assert_eq(exec_count, 2, "post-bump render re-executes (result-cache miss)")
  assert_eq(parse_count, 1, "post-bump render does NOT re-parse (AST cache hit)")
end)

-- ===========================================================================
-- 2. Identical content within the same generation parses exactly once.
-- ===========================================================================
test("warm render reuses the cached AST (parse runs once)", function()
  local dir = make_vault()
  setup_vault(dir)
  make_buffer(dir, "home.md", { "LIST FROM #topic" })

  parse_count = 0
  query.render_all() -- cold
  query.render_all() -- warm (result-cache hit too, so executor short-circuits)
  assert_eq(parse_count, 1, "identical content parses exactly once across renders")
end)

-- ===========================================================================
-- 3. Distinct content -> distinct AST (no collision); repeat adds 0 parses.
-- ===========================================================================
test("distinct query content parses once each, repeat reuses both", function()
  local dir = make_vault()
  setup_vault(dir)
  make_buffer(dir, "home.md", { "LIST FROM #topic", "TABLE file.name FROM #topic" })

  parse_count = 0
  query.render_all() -- two distinct blocks -> two parses
  assert_eq(parse_count, 2, "two distinct queries parse once each")

  query.render_all() -- both cached
  assert_eq(parse_count, 2, "repeat render adds zero parses (both ASTs reused)")
end)

-- ===========================================================================
-- 4. Error AST is cached too (matches js2lua semantics): malformed query
--    parses once, and the error render item is identical across renders.
-- ===========================================================================
test("malformed query caches its error AST (parses once, identical error)", function()
  local dir = make_vault()
  setup_vault(dir)
  -- "GARBAGE" is not a valid DQL command -> parser.parse returns nil, err.
  local buf = make_buffer(dir, "home.md", { "GARBAGE FROM #topic" })

  parse_count = 0
  query.render_all()
  local lines1 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  query.render_all()
  local lines2 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  assert_eq(parse_count, 1, "malformed query parses exactly once (error AST cached)")
  assert_eq(table.concat(lines2, "\n"), table.concat(lines1, "\n"),
    "error render output is byte-identical across renders")
end)

-- Restore the real functions (good hygiene; process exits next anyway).
parser.parse = real_parse
executor.execute = real_execute

-- ===========================================================================
-- Summary
-- ===========================================================================
_H.finish({ style = "results", exit = "os" })
