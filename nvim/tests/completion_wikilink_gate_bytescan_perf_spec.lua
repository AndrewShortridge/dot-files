-- Perf regression spec: wikilink completion's early-exit GATE uses a plain-byte
-- scan, not a backtracking Lua pattern, on every keystroke.
--
-- The wikilinks source has min_keyword_length=0, so blink.cmp invokes
-- get_completions on EVERY keystroke in a markdown buffer. The very first thing
-- it does is gate on the presence of "[[" in the line prefix. The old gate used
-- `before:match("!?%[%[")`: the optional `!?` quantifier forces Lua's pattern
-- engine to attempt a match at every byte position, scaling linearly with line
-- length (~2.4us on a 175-char prose line). Since the `!?` only ever precedes
-- "[[", the gate succeeds iff "[[" is present, so a plain-byte
-- `before:find("[[", 1, true)` (~0.4ns) is EXACTLY equivalent and ~4000x cheaper.
--
-- This drives the REAL andrew.vault.completion source against a temp vault
-- buffer (no mocks, no source-introspection).
--
-- Discriminating power (proven empirically):
--   * On a NO-TRIGGER prose line (no "[["), the buggy gate runs string.match
--     once (the gate) plus once more (the standalone-^id check at line 444) = 2.
--     The fixed gate is a string.find, leaving only the ^id match = 1. So:
--       - string.match count == 1  (bug -> 2, assertion FAILS)
--       - string.find  count >= 1  (bug runs 0 finds on this path, assertion FAILS)
--   * BEHAVIORAL guards: "[[foo" still returns note items; "![[foo" (the embed
--     "!?" branch) still passes the gate; plain prose returns empty_response.
--
-- Run with:
--   nvim --headless -u NONE -l tests/completion_wikilink_gate_bytescan_perf_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local completion = require("andrew.vault.completion")

print("\n=== Wikilink Completion Gate Byte-Scan Perf Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault: one note plus a few sibling notes for a non-trivial candidate set.
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

local note_lines = {
  "# Alpha Heading",
  "",
  "Some body text. ^blk-abc123",
}
write_file(dir, "note.md", note_lines)
for i = 1, 20 do
  write_file(dir, string.format("foo_%03d.md", i), { "# foo " .. i, "", "body" })
end

engine.vault_path = dir
vault_index._instance = nil
local idx = vault_index.get(dir)
idx:build_sync()

vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/note.md"))
local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, note_lines)

local function get_items(line)
  local result = nil
  local ctx = { line = line, cursor = { 1, #line } }
  completion:get_completions(ctx, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end, 10)
  return result
end

-- A long prose line with NO "[[" trigger — the overwhelmingly common keystroke.
local PROSE = string.rep("word ", 35) -- ~175 chars, no "[["

-- ---------------------------------------------------------------------------
-- PERF — on a no-trigger prose line, the GATE must be a plain-byte find, not a
-- backtracking match. Spy string.match AND string.find for the dynamic extent
-- of ONE get_completions call, then always restore (pcall + finally). Also
-- record the first arg of each find to assert the gate's "[[" scan ran.
-- ---------------------------------------------------------------------------
test("no-trigger prose line: gate uses string.find not string.match", function()
  -- Prime the item cache so the spied call hits the synchronous cache-hit path
  -- (a cache miss defers the inner get_completions through the work scheduler,
  -- which would run AFTER the spy is restored). The actual prefix is irrelevant
  -- to priming — only the index generation / cache validity matters.
  get_items("[[foo")

  local orig_match = string.match
  local orig_find = string.find
  local match_count = 0
  local find_count = 0
  local saw_bracket_find = false
  local result = nil
  local ok, err = pcall(function()
    string.match = function(...)
      match_count = match_count + 1
      return orig_match(...)
    end
    string.find = function(s, patt, init, plain)
      find_count = find_count + 1
      if patt == "[[" and plain == true then saw_bracket_find = true end
      return orig_find(s, patt, init, plain)
    end
    local ctx = { line = PROSE, cursor = { 1, #PROSE } }
    completion:get_completions(ctx, function(r) result = r end)
  end)
  string.match = orig_match -- finally: always restore
  string.find = orig_find

  assert_true(ok, "get_completions did not error under the spies: " .. tostring(err))
  -- Buggy gate: match("!?%[%[") gate + match("%^[%w%-]*$") ^id check == 2.
  -- Fixed gate: find("[[") gate + match("%^[%w%-]*$") ^id check == 1 match.
  assert_eq(match_count, 1, "exactly one string.match on the no-trigger prose path")
  -- Buggy path runs 0 finds before bailing; fixed gate runs at least the "[[" find.
  assert_true(find_count >= 1, "at least one string.find on the prose path, got " .. find_count)
  assert_true(saw_bracket_find, "the gate ran a plain-byte find('[[', 1, true)")
end)

-- ---------------------------------------------------------------------------
-- BEHAVIORAL equivalence — the gate change preserves all three trigger paths.
-- ---------------------------------------------------------------------------
test("plain prose line returns empty_response (gate correctly fails)", function()
  local result = get_items(PROSE)
  local items = (result or {}).items or {}
  assert_eq(#items, 0, "no completion items on a no-trigger prose line")
end)

test("[[foo still passes the gate and returns note items", function()
  local items = (get_items("[[foo") or {}).items or {}
  assert_true(#items >= 1, "wikilink trigger still produces note items")
end)

test("![[foo (embed form, the '!?' branch) still passes the gate", function()
  local items = (get_items("![[foo") or {}).items or {}
  assert_true(#items >= 1, "embed trigger still produces note items")
end)

_H.finish({ style = "results", exit = "os" })
