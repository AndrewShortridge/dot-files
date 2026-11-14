-- Perf regression spec: inline-field completion's matcher short-circuits the
-- byte-dependent backtracking Lua patterns behind cheap plain-byte pre-gates.
--
-- The vault_inline_fields source has min_keyword_length=2, so blink.cmp invokes
-- get_completions whenever a 2+ char keyword precedes the cursor — i.e. on
-- essentially every prose word typed. The matcher closure tries several
-- UNANCHORED patterns:
--   before:match("%[([%w_%-]+)::%s+[^%]]*$")  -- bracketed value
--   before:match("%(([%w_%-]+)::%s+[^%)]*$")  -- parenthesized value
--   before:match("%[[%w_%-]*$") / "%[%[[%w_%-]*$"  -- '[' key
--   before:match("%([%w_%-]*$") / "%]%([%w_%-]*$"  -- '(' key
-- Lua attempts unanchored patterns at every byte position of `before`
-- (~6us on a 176-char prose line). None can succeed unless `before` contains a
-- literal '::', '[' or '(' respectively, so plain-byte
--   before:find("::", 1, true) / find("[", 1, true) / find("(", 1, true)
-- short-circuit the entire no-trigger prose case. Each gate is a superset
-- condition, so it changes no observable semantics.
--
-- This drives the REAL andrew.vault.completion_inline_fields source against a
-- temp vault buffer (no mocks, no source-introspection).
--
-- Discriminating power (proven empirically):
--   * On a NO-trigger prose line (no ':', '[', '('), the FIXED matcher runs
--     only the two ^-anchored standalone/line-start matches + the three plain
--     finds; the byte-gated unanchored matches never run.
--     The BUGGY matcher (a gate removed) re-runs its unanchored match(es),
--     raising match_count. So:
--       - match_count <= 4   (bug -> >= 5, assertion FAILS)
--       - saw_colon_find / saw_bracket_find / saw_paren_find == true
--   * BEHAVIORAL guards lock every trigger path (standalone/bracket/paren value
--     completion, bare '['/'(' key completion, '[[' and '](' exclusions).
--
-- Run with:
--   nvim --headless -u NONE -l tests/completion_inline_fields_gate_bytescan_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local fields_source = require("andrew.vault.completion_inline_fields")

print("\n=== Inline-Field Completion Gate Byte-Scan Perf Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault: notes carrying inline fields so build_kv_single_pass yields a
-- non-trivial key/value candidate set.
-- ---------------------------------------------------------------------------
local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
for i = 1, 8 do
  write_file(dir, string.format("note_%03d.md", i), {
    "# Note " .. i,
    "",
    "[status:: active]",
    "(priority:: " .. i .. ")",
    "maturity:: seedling",
    "",
    "body",
  })
end

engine.vault_path = dir
vault_index._instance = nil
local idx = vault_index.get(dir)
idx:build_sync()

vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/note_001.md"))
local bufnr = vim.api.nvim_get_current_buf()

local function get_items(line)
  local result = nil
  local ctx = { line = line, cursor = { 1, #line }, bufnr = bufnr }
  fields_source:get_completions(ctx, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end, 10)
  return (result or {}).items or {}
end

-- A long prose line with NO trigger byte (':', '[', '(') — the common keystroke.
local PROSE = string.rep("word ", 35) -- ~175 chars, no trigger

-- ---------------------------------------------------------------------------
-- PERF — on a no-trigger prose line, the byte-dependent unanchored matches must
-- be gated behind plain-byte finds. Spy string.match AND string.find for the
-- dynamic extent of ONE get_completions call, then always restore.
-- ---------------------------------------------------------------------------
test("no-trigger prose line: byte-dependent matches gated behind plain finds", function()
  -- Prime the item cache so the spied call hits the synchronous path.
  get_items("[status:: ")

  local orig_match = string.match
  local orig_find = string.find
  local match_count = 0
  local find_count = 0
  local saw_colon_find = false
  local saw_bracket_find = false
  local saw_paren_find = false
  local result = nil
  local ok, err = pcall(function()
    string.match = function(...)
      match_count = match_count + 1
      return orig_match(...)
    end
    string.find = function(s, patt, init, plain)
      find_count = find_count + 1
      if plain == true then
        if patt == "::" then saw_colon_find = true end
        if patt == "[" then saw_bracket_find = true end
        if patt == "(" then saw_paren_find = true end
      end
      return orig_find(s, patt, init, plain)
    end
    local ctx = { line = PROSE, cursor = { 1, #PROSE }, bufnr = bufnr }
    fields_source:get_completions(ctx, function(r) result = r end)
  end)
  string.match = orig_match -- finally: always restore
  string.find = orig_find

  assert_true(ok, "get_completions did not error under the spies: " .. tostring(err))
  -- Fixed matcher on a no-trigger prose line runs only the two ^-anchored
  -- standalone matches + two ^-anchored line-start matches = 4 string.match
  -- (the byte-gated unanchored matches never run). Removing ANY gate
  -- reintroduces its unanchored match(es), pushing match_count >= 5.
  assert_true(match_count <= 4,
    "byte-dependent unanchored matches stay gated on prose (got " .. match_count .. ")")
  assert_true(find_count >= 1, "at least one string.find on the prose path, got " .. find_count)
  assert_true(saw_colon_find, "the matcher ran a plain-byte find('::', 1, true)")
  assert_true(saw_bracket_find, "the matcher ran a plain-byte find('[', 1, true)")
  assert_true(saw_paren_find, "the matcher ran a plain-byte find('(', 1, true)")
end)

-- ---------------------------------------------------------------------------
-- BEHAVIORAL equivalence — the gates preserve every trigger path.
-- ---------------------------------------------------------------------------
test("plain no-trigger prose line returns empty_response", function()
  local items = get_items(PROSE)
  assert_eq(#items, 0, "no completion items on a no-trigger prose line")
end)

test("standalone 'status:: ' triggers value completion", function()
  local items = get_items("status:: ")
  assert_true(#items >= 1, "standalone key:: still produces value items")
end)

test("bracketed '[status:: ' triggers value completion", function()
  local items = get_items("[status:: ")
  assert_true(#items >= 1, "[key:: still produces value items")
end)

test("parenthesized '(status:: ' triggers value completion", function()
  local items = get_items("(status:: ")
  assert_true(#items >= 1, "(key:: still produces value items")
end)

test("bare '[' triggers key/name completion", function()
  local items = get_items("[")
  assert_true(#items >= 1, "bare [ still produces field-key items")
end)

test("bare '(' triggers key/name completion", function()
  local items = get_items("(")
  assert_true(#items >= 1, "bare ( still produces field-key items")
end)

test("'[[Note' wikilink prefix returns empty (exclusion still fires)", function()
  local items = get_items("[[Note")
  assert_eq(#items, 0, "[[ wikilink is not a field-key trigger")
end)

test("'](url' markdown-link target returns empty (exclusion still fires)", function()
  local items = get_items("[text](url")
  assert_eq(#items, 0, "]( markdown link target is not a field-key trigger")
end)

_H.finish({ style = "results", exit = "os" })
