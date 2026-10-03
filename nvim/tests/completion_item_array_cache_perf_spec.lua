-- Perf regression spec: the wikilinks completion source caches the BUILT block
-- and same-file-heading item arrays keyed on (bufnr, changedtick, variant), not
-- just the parsed blocks/headings.
--
-- Before the fix, build_buffer_block_items and the same-file heading path looped
-- the cached parsed blocks/headings and rebuilt the item array (make_item +
-- build_context_lines + vim.tbl_extend, 2N throwaway tables) on EVERY keystroke
-- of an unchanged buffer. blink.cmp re-filters returned lists with its own fuzzy
-- matcher (both incomplete flags false), so returning the identical immutable
-- array across keystrokes is output-safe.
--
-- The fix memoizes the built array. A second identical trigger on an unchanged
-- buffer (same changedtick) does ZERO new make_item calls and returns the SAME
-- table reference. Editing the buffer bumps changedtick -> cache miss -> rebuild.
-- The two block variants (standalone '^id' label_prefix vs same-file '[[^'
-- insert_suffix) are keyed separately so they never cross-contaminate.
--
-- This drives the REAL andrew.vault.completion source against a temp vault + a
-- real markdown buffer (no mocks, no source-introspection). A counting wrapper
-- around completion_base.make_item proves the rebuild is skipped.
--
-- Discriminating power: reintroducing the per-keystroke rebuild makes the
-- second-trigger make_item count non-zero and breaks the reference-identity and
-- variant assertions.
--
-- Run with: nvim --headless -u NONE -l tests/completion_item_array_cache_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local completion_base = require("andrew.vault.completion_base")
local source = require("andrew.vault.completion") -- wikilinks source

print("\n=== Completion Item Array Cache Perf Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault + buffer helpers
-- ---------------------------------------------------------------------------
local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

--- Run `fn` with completion_base.make_item spied; returns the call count.
local function count_make_item(fn)
  local orig = completion_base.make_item
  local n = 0
  completion_base.make_item = function(...)
    n = n + 1
    return orig(...)
  end
  local ok, err = pcall(fn)
  completion_base.make_item = orig -- finally: always restore
  assert_true(ok, "spied body did not error: " .. tostring(err))
  return n
end

--- Drive the source's get_completions synchronously and return the result table.
local function complete(line)
  local result = nil
  local ctx = { line = line, cursor = { 1, #line }, bufnr = vim.api.nvim_get_current_buf() }
  source:get_completions(ctx, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end, 5)
  return result or {}
end

-- ---------------------------------------------------------------------------
-- Setup: a temp vault with one note that has blocks + headings.
-- ---------------------------------------------------------------------------
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
write_file(dir, "main.md", {
  "# Top Heading",
  "",
  "Some intro text.",
  "",
  "## Section A",
  "",
  "First paragraph. ^blk-aaaaaa",
  "",
  "## Section B",
  "",
  "Second paragraph. ^blk-bbbbbb",
})
engine.vault_path = dir
vault_index._instance = nil
local idx = vault_index.get(dir)
idx:build_sync()
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/main.md"))
completion_base.invalidate_all()

-- ===========================================================================
-- 1. Standalone block path: identical trigger -> same array, zero rebuild.
-- ===========================================================================
test("standalone block: second identical trigger does zero make_item, same array", function()
  local first = complete("^blk")
  assert_true(first.items and #first.items >= 2,
    "standalone block items produced (got " .. tostring(first.items and #first.items) .. ")")

  -- Second identical trigger on the unchanged buffer (same changedtick).
  local second
  local n = count_make_item(function() second = complete("^blk") end)
  assert_eq(n, 0, "no make_item calls on cached second trigger (standalone block)")
  assert_true(first.items == second.items,
    "cached block array is the SAME table reference across triggers")
end)

-- ===========================================================================
-- 2. Variant separation: standalone '^' vs same-file '[[^' don't collide.
-- ===========================================================================
test("block variants do not cross-contaminate", function()
  local standalone = complete("^blk").items
  local samefile = complete("[[^").items
  assert_true(standalone ~= samefile, "the two variants are distinct arrays")

  -- standalone: label prefixed with '^', insertText is the bare id.
  local s1 = standalone[1]
  assert_eq(s1.label:sub(1, 1), "^", "standalone label is '^'-prefixed")
  assert_true(s1.insertText:sub(-2) ~= "]]", "standalone insertText has no ']]' suffix")

  -- same-file: insertText carries the ']]' suffix, label is the bare id.
  local f1 = samefile[1]
  assert_eq(f1.insertText:sub(-2), "]]", "same-file insertText has ']]' suffix")
  assert_eq(f1.label:sub(1, 1), "b", "same-file label is the bare block id (no '^')")
end)

-- ===========================================================================
-- 3. Same-file heading path: identical trigger -> same array, zero rebuild.
-- ===========================================================================
test("same-file heading: second identical trigger does zero make_item, same array", function()
  local first = complete("[[#")
  assert_true(first.items and #first.items >= 3,
    "same-file heading items produced (got " .. tostring(first.items and #first.items) .. ")")

  local second
  local n = count_make_item(function() second = complete("[[#") end)
  assert_eq(n, 0, "no make_item calls on cached second trigger (same-file heading)")
  assert_true(first.items == second.items,
    "cached heading array is the SAME table reference across triggers")
end)

-- ===========================================================================
-- 4. Invalidation: editing the buffer bumps changedtick -> rebuild + new data.
-- ===========================================================================
test("editing buffer invalidates block cache and surfaces the new block", function()
  local before = complete("^blk").items
  local before_count = #before

  -- Append a new block line, bumping changedtick.
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "Third paragraph. ^blk-cccccc" })

  local after
  local n = count_make_item(function() after = complete("^blk") end)
  assert_true(n >= 1, "make_item rebuilt items after edit (got " .. n .. " calls)")
  assert_true(after.items ~= before, "post-edit array is a fresh table (not the cached one)")
  assert_eq(#after.items, before_count + 1, "the newly added block appears in results")

  local found = false
  for _, item in ipairs(after.items) do
    if item.label:find("cccccc", 1, true) then found = true break end
  end
  assert_true(found, "the new ^blk-cccccc block is present in completion results")
end)

-- The same-file heading list is sourced from the vault index (saved file), so
-- an unsaved in-buffer edit does not change the heading *contents* — but the
-- (bufnr, changedtick) key must still invalidate the memoized array on any edit
-- (the cache must not serve a stale array keyed to the old tick). This proves
-- the invalidation fires: a cache hit does zero make_item, a post-edit trigger
-- rebuilds (>= 1) and returns a fresh array.
test("editing buffer invalidates heading item-array cache (rebuild on new tick)", function()
  local before = complete("[[#").items

  -- Warm the cache, confirm a hit does zero rebuild.
  local hit
  local hit_n = count_make_item(function() hit = complete("[[#") end)
  assert_eq(hit_n, 0, "cached heading trigger does zero make_item before edit")
  assert_true(hit.items == before, "warm heading array is the cached reference")

  -- Edit the buffer (bump changedtick) -> next trigger must rebuild.
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "## Section C" })

  local after
  local n = count_make_item(function() after = complete("[[#") end)
  assert_true(n >= 1, "make_item rebuilt heading items after edit (got " .. n .. " calls)")
  assert_true(after.items ~= before, "post-edit heading array is a fresh table")
end)

_H.finish({ style = "results", exit = "os" })
