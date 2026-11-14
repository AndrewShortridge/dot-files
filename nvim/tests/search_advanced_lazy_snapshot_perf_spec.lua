-- Perf regression spec for lazy snapshot_files() in the live-search pipeline.
--
-- THE BUG (now fixed): advanced.resolve_query opened with an UNCONDITIONAL
--   local snap_files = restrict_to or idx:snapshot_files()
-- at the top, even though the metadata_only / metadata_then_text branches never
-- use snap_files (they derive their file list from the metadata matches). So
-- every keystroke on the common metadata-only live query paid a full O(N)
-- copy_files() of the entire vault for nothing. The per-generation memoized
-- snapshot inside search_filter.prepare_evaluate is a SEPARATE mechanism; this
-- redundant SECOND copy is what the fix removes.
--
-- THE FIX: snap_files is now a lazy, memoized get_snap() that calls
-- idx:snapshot_files() only when a branch that iterates the full file set
-- (text_only / mixed_or) actually needs it.
--
-- DISCRIMINATING POWER: this drives the REAL advanced.evaluate_advanced_ast
-- (sync path) against a REAL vault_index built over a temp vault, with the
-- index instance's snapshot_files wrapped to count calls.
--   * A metadata_only query (tag:foo) must trigger ZERO snapshot_files() calls.
--   * A text_only query (a bare text term) must still trigger snapshot_files()
--     (the branch genuinely needs the full file list).
-- Reintroduce the eager top-of-function copy and the metadata_only count jumps
-- to 1, failing the first assertion.
--
-- Run with: nvim --headless -u NONE -l tests/search_advanced_lazy_snapshot_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local vault_index = require("andrew.vault.vault_index")
local search_query = require("andrew.vault.search_query")
local advanced = require("andrew.vault.search.advanced")
local engine = require("andrew.vault.engine")

print("\n=== Advanced Search Lazy Snapshot Perf Tests ===\n")

local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

-- Build a small vault: every note carries #foo so metadata matching has work,
-- and the body has a distinct text term for the text-only branch.
local function make_vault(n)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for i = 1, n do
    write_file(dir, string.format("note_%03d.md", i), {
      "---",
      "tags: [foo]",
      "---",
      "# Note " .. i,
      "",
      "alpha bravo charlie body text.",
    })
  end
  return dir
end

local function fresh_vi(dir)
  vault_index._instance = nil
  local idx = vault_index.get(dir)
  idx:build_sync()
  return idx
end

-- Wrap the instance's snapshot_files with a call counter. Assigning directly on
-- the instance shadows the metatable method; the wrapper forwards to the real
-- one so behavior/output is unchanged.
local function instrument(idx)
  local counter = { n = 0 }
  local real = getmetatable(idx).snapshot_files
  rawset(idx, "snapshot_files", function(self)
    counter.n = counter.n + 1
    return real(self)
  end)
  return counter
end

test("metadata_only query triggers ZERO snapshot_files copies", function()
  local dir = make_vault(12)
  local idx = fresh_vi(dir)
  engine.vault_path = dir
  local counter = instrument(idx)

  local ast = search_query.parse_query("tag:foo")
  local result = advanced.evaluate_advanced_ast(ast, nil, idx, dir, nil, nil)

  assert_eq(counter.n, 0, "metadata_only must not snapshot the files table")
  assert_true(result ~= nil, "metadata_only returns a result")
  -- 12 notes all carry #foo, so the metadata branch matched them.
  assert_eq(#result.entries, 12, "metadata_only matched all tagged notes")
end)

test("text_only query still snapshots the files table", function()
  local dir = make_vault(12)
  local idx = fresh_vi(dir)
  engine.vault_path = dir
  local counter = instrument(idx)

  local ast = search_query.parse_query("alpha")
  local result = advanced.evaluate_advanced_ast(ast, nil, idx, dir, nil, nil)

  assert_true(counter.n >= 1, "text_only branch needs the full file list (snapshot)")
  assert_true(result ~= nil, "text_only returns a result")
end)

test("memoized: a single resolve copies snapshot at most once", function()
  -- A mixed_or query exercises a full-file-set branch; even though get_snap is
  -- referenced more than once in code, the memo guarantees a single copy.
  local dir = make_vault(8)
  local idx = fresh_vi(dir)
  engine.vault_path = dir
  local counter = instrument(idx)

  local ast = search_query.parse_query("alpha OR tag:foo")
  advanced.evaluate_advanced_ast(ast, nil, idx, dir, nil, nil)

  assert_true(counter.n <= 1, "snapshot copied at most once per resolve (memoized)")
end)

_H.finish({ style = "results", exit = "os" })
