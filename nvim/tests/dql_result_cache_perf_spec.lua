-- Perf regression spec for the DQL/Lua/JS query result cache.
--
-- THE BUG (now fixed): query/init.lua's execute_dql re-parsed (parser.parse)
-- and re-executed (executor.execute) a full vault scan on EVERY render, even
-- when neither the query text, the vault (index generation) nor the current
-- file changed. render_all calls these per block on every buffer render, so a
-- file with N dataview blocks paid N full vault scans per render with no reuse.
-- The fix wraps execute_dql/execute_lua/execute_js in a bounded LRU result
-- cache keyed on (block kind, content, vault_index generation, current_file).
--
-- DISCRIMINATING POWER: this spec monkeypatches the REAL parser.parse and
-- executor.execute (the functions the cache is supposed to bypass) with
-- counting wrappers, then renders the SAME dataview block twice with the SAME
-- generation + current_file. With the cache, the second render is a hit:
-- parse/execute counts increase by exactly 1 across the two renders. Remove the
-- wrapper guards (reintroduce the no-cache behavior) and the second render
-- parses+executes again, pushing each count to 2 and FAILING assertion #1.
--
-- It also proves correct invalidation: bumping vault_index._generation (real
-- vault edit + update_file) forces a re-execute, and rendering identical
-- content from a DIFFERENT current_file (distinct key) also re-executes.
--
-- Drives the REAL modules against a temp vault (no mocks, no source
-- introspection — only behavioral instrumentation of public module functions).
--
-- Run with: nvim --headless -u NONE -l tests/dql_result_cache_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local parser = require("andrew.vault.query.parser")
local executor = require("andrew.vault.query.executor")
local query = require("andrew.vault.query")

print("\n=== DQL Result Cache Perf Tests ===\n")

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

-- Build a small vault with a couple of notes carrying a tag so a LIST query
-- returns rows.
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
  -- Drop ALL registered caches (incl. the content-keyed DQL AST cache, which
  -- otherwise persists across tests because it is generation-independent),
  -- giving each test a clean parse_count baseline.
  -- skip_index: do NOT kick off a vault_index build_async (it would set the
  -- _building flag and block the later update_file generation bump in headless,
  -- where no event loop completes the async build).
  engine.invalidate_caches({ scope = "all", skip_index = true })
  -- Force the query index to rebuild against this fresh vault.
  query.rebuild_index()
  return vi
end

-- Spy counters installed on the REAL module functions the cache bypasses.
-- query/init.lua holds parser/executor as upvalues pointing at these shared
-- tables, so replacing the field is seen by the module.
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

-- Create a scratch buffer with a dataview block, named to an abs path in dir.
local function make_block_buffer(dir, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# Notes",
    "",
    "```dataview",
    "LIST FROM #topic",
    "```",
    "",
  })
  vim.api.nvim_set_current_buf(buf)
  return buf
end

-- ===========================================================================
-- 1. Same content + same generation + same file: second render is a cache hit.
--    (Discriminating core — removing the cache makes counts hit 2 here.)
-- ===========================================================================
test("identical render hits the cache (parse+execute run exactly once)", function()
  local dir = make_vault()
  setup_vault(dir)
  make_block_buffer(dir, "home.md")

  parse_count, exec_count = 0, 0

  query.render_all() -- cold: miss
  local p1, e1 = parse_count, exec_count
  query.render_all() -- warm: hit, must NOT re-parse / re-execute
  local p2, e2 = parse_count, exec_count

  assert_eq(p1, 1, "cold render parses once")
  assert_eq(e1, 1, "cold render executes once")
  assert_eq(p2, 1, "warm render does NOT re-parse (cache hit)")
  assert_eq(e2, 1, "warm render does NOT re-execute (cache hit)")
end)

-- ===========================================================================
-- 2. Generation bump forces a re-execute (correct invalidation).
-- ===========================================================================
test("generation bump invalidates the cached result", function()
  local dir = make_vault()
  local vi = setup_vault(dir)
  make_block_buffer(dir, "home.md")

  parse_count, exec_count = 0, 0
  query.render_all() -- cold
  assert_eq(exec_count, 1, "cold render executes once")
  query.render_all() -- hit
  assert_eq(exec_count, 1, "second render is a hit")

  -- Real vault edit -> reindex -> generation bump.
  local gen_before = vi._generation
  write_file(dir, "gamma.md", { "---", "tags: [topic]", "---", "# Gamma", "New." })
  vi:update_file(dir .. "/gamma.md")
  query.rebuild_index() -- query index follows the vault generation
  assert_true(vi._generation ~= gen_before, "vault generation advanced after edit")

  query.render_all() -- must re-execute after gen bump
  assert_eq(exec_count, 2, "render after generation bump re-executes")
  -- AST cache (issue L) is content-keyed and generation-independent: the gen
  -- bump forces a re-EXECUTE but the byte-identical query is NOT re-parsed.
  assert_eq(parse_count, 1, "render after generation bump does NOT re-parse (AST cache hit)")
end)

-- ===========================================================================
-- 3. current_file discrimination: same content from a different file re-runs.
-- ===========================================================================
test("different current_file uses a distinct cache key", function()
  local dir = make_vault()
  setup_vault(dir)

  make_block_buffer(dir, "home.md")
  parse_count, exec_count = 0, 0
  query.render_all() -- cold for home.md
  assert_eq(exec_count, 1, "cold render for home.md executes once")

  -- Same dataview content, different abs path -> distinct key -> re-execute.
  make_block_buffer(dir, "alpha.md")
  query.render_all()
  assert_eq(exec_count, 2, "render for a different file re-executes (distinct key)")
end)

-- Restore the real functions (good hygiene; process exits next anyway).
parser.parse = real_parse
executor.execute = real_execute

-- ===========================================================================
-- Summary
-- ===========================================================================
_H.finish({ style = "results", exit = "os" })
