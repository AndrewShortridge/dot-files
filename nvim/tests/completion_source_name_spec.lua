-- Perf regression spec: completion source_name is tagged at BUILD time.
--
-- blink.cmp calls a provider's transform_items on EVERY keystroke while the
-- menu is open. The wikilinks provider used to define a transform_items that
-- walked the ENTIRE returned item list each keystroke just to set
-- item.source_name = "Heading"/"Block" on heading/block items. For the common
-- `[[foo` note-name path that list can be huge and contains NO heading/block
-- items, so the scan did nothing but burn per-keystroke time.
--
-- The fix tags source_name once at build time inside make_heading_item /
-- make_block_item (the heading/block lists are small, built per `#`/`^`
-- trigger) and removes transform_items entirely. Output is identical: the
-- heading/block menu items still carry their source label, note/alias items
-- still carry none, and item pooling now clears source_name on release.
--
-- This drives the REAL andrew.vault.completion source against a temp vault
-- buffer (no mocks, no source-introspection). Discriminating power: if the
-- build-time tag is reverted (back to the transform_items-only approach),
-- source_name is nil at the point get_completions returns, so Test A/B fail.
--
-- Run with: nvim --headless -u NONE -l tests/completion_source_name_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")
local completion = require("andrew.vault.completion")

print("\n=== Completion source_name Build-Time Tag Perf Tests ===\n")

-- ---------------------------------------------------------------------------
-- Temp vault: one note with headings and a block id, plus enough sibling notes
-- that the note-name candidate list is non-trivial.
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
  "",
  "## Beta Heading",
  "",
  "More text.",
}
write_file(dir, "note.md", note_lines)
for i = 1, 40 do
  write_file(dir, string.format("foo_%03d.md", i), { "# foo " .. i, "", "body" })
end

-- Point the engine + index at the temp vault and build synchronously.
engine.vault_path = dir
vault_index._instance = nil
local idx = vault_index.get(dir)
idx:build_sync()

-- Load note.md into the current buffer so the same-file heading/block branches
-- read live buffer lines and the buffer name resolves inside the vault.
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/note.md"))
local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, note_lines)

-- Drive source:get_completions(ctx, cb) and synchronously collect result.items.
-- The same-file heading/block branches call back synchronously; the note-name
-- branch may build the item cache via the work scheduler, so pump vim.wait.
local function get_items(line)
  local result = nil
  local ctx = { line = line, cursor = { 1, #line } }
  completion:get_completions(ctx, function(r) result = r end)
  vim.wait(2000, function() return result ~= nil end, 10)
  return result
end

-- ---------------------------------------------------------------------------
-- Test A — heading items carry source_name == "Heading" at build time.
-- ---------------------------------------------------------------------------
test("heading items are tagged source_name=Heading at build", function()
  local result = get_items("[[#")
  assert_true(result ~= nil, "get_completions returned a result")
  local items = result.items or {}
  local heading_count = 0
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "heading" then
      heading_count = heading_count + 1
      assert_eq(item.source_name, "Heading", "heading item source_name set at build")
    end
  end
  assert_true(heading_count >= 1, "same-file heading branch produced heading items")
end)

-- ---------------------------------------------------------------------------
-- Test B — block items carry source_name == "Block" at build time.
-- ---------------------------------------------------------------------------
test("block items are tagged source_name=Block at build", function()
  local result = get_items("[[^")
  assert_true(result ~= nil, "get_completions returned a result")
  local items = result.items or {}
  local block_count = 0
  for _, item in ipairs(items) do
    if item.data and item.data.completion_kind == "block" then
      block_count = block_count + 1
      assert_eq(item.source_name, "Block", "block item source_name set at build")
    end
  end
  assert_true(block_count >= 1, "same-file block branch produced block items")
end)

-- ---------------------------------------------------------------------------
-- Test C — note-name path: items have NO source_name (identical menu output,
-- and no per-keystroke scan tags them). Proves the note path is a no-op for
-- source_name, exactly as before.
-- ---------------------------------------------------------------------------
test("note-name items carry no source_name (no per-keystroke scan)", function()
  local result = get_items("[[foo")
  assert_true(result ~= nil, "get_completions returned a result")
  local items = result.items or {}
  assert_true(#items >= 1, "note-name branch produced note items")
  local tagged = 0
  for _, item in ipairs(items) do
    -- note items must never carry a heading/block label
    assert_nil(item.data and item.data.completion_kind, "note item has no completion_kind")
    if item.source_name ~= nil then tagged = tagged + 1 end
  end
  assert_eq(tagged, 0, "no note item carries a stale source_name label")
end)

_H.finish({ style = "results", exit = "os" })
