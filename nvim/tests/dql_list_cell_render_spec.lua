-- Behavioral spec for DQL list/array cell rendering (ISSUE 3).
-- Run with: nvim --headless -u NONE -l tests/dql_list_cell_render_spec.lua
--
-- Covers query/render.lua to_str(): an array-like Lua value (multi-value
-- inline field) must render joined ", " (Dataview parity), not as a
-- "table: 0x..." address. Typed elements (Link) must still format via
-- their __tostring when nested in an array.
-- Assertions are behavioral: they read back real extmark virt_lines from
-- render.render output, not source introspection.

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true, assert_false, assert_match, assert_eq =
  _H.test, _H.assert_true, _H.assert_false, _H.assert_match, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

package.loaded["andrew.vault.vault_log"] = {
  scope = function()
    return setmetatable({}, { __index = function() return function() end end })
  end,
}

local render = require("andrew.vault.query.render")
local types = require("andrew.vault.query.types")

local ns = vim.api.nvim_create_namespace("vault_query")

-- Render results into a scratch buffer (code fence at line index 2) and return
-- the list of concatenated text strings, one per rendered virt_line.
local function render_lines(results)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```dataview", "Q", "```", "after" })
  render.render(buf, 2, results)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    for _, line in ipairs(m[4].virt_lines or {}) do
      local parts = {}
      for _, chunk in ipairs(line) do
        parts[#parts + 1] = chunk[1]
      end
      out[#out + 1] = table.concat(parts)
    end
  end
  return out
end

-- True if any rendered line matches the Lua pattern.
local function any_match(lines, pat)
  for _, l in ipairs(lines) do
    if l:match(pat) then return true end
  end
  return false
end

-- ── TABLE: array cell joins, no address leak ───────────────────────────────

test("TABLE array cell renders joined values, not a table address", function()
  local lines = render_lines({
    { type = "table", headers = { "File", "genre" },
      rows = { { types.Link.new("NoteA"), { "rock", "jazz" } } } },
  })
  assert_true(any_match(lines, "rock, jazz"), "expected joined 'rock, jazz'")
  assert_false(any_match(lines, "table: 0x%x+"), "no table address should leak")
end)

-- ── LIST: array item joins ─────────────────────────────────────────────────

test("LIST array item renders joined values, not a table address", function()
  local lines = render_lines({
    { type = "list", items = { { "rock", "jazz" } } },
  })
  assert_true(any_match(lines, "rock, jazz"), "expected joined 'rock, jazz' bullet")
  assert_false(any_match(lines, "table: 0x%x+"), "no table address should leak")
end)

-- ── Recursion: typed elements format via __tostring ────────────────────────

test("array of Links recurses through Link.__tostring", function()
  local lines = render_lines({
    { type = "table", headers = { "File", "links" },
      rows = { { types.Link.new("Home"), { types.Link.new("A"), types.Link.new("B") } } } },
  })
  assert_true(any_match(lines, "%[%[A%]%], %[%[B%]%]"), "expected '[[A]], [[B]]'")
  assert_false(any_match(lines, "table: 0x%x+"), "no table address should leak")
end)

-- ── Scalar regression guards ───────────────────────────────────────────────

test("scalar string and number cells render unchanged", function()
  local lines = render_lines({
    { type = "table", headers = { "File", "s", "n" },
      rows = { { types.Link.new("NoteA"), "hello", 5 } } },
  })
  assert_true(any_match(lines, "hello"), "string cell renders")
  assert_true(any_match(lines, "%f[%d]5%f[%D]"), "number cell renders 5")
  assert_false(any_match(lines, "table: 0x%x+"), "no table address should leak")
end)

-- ── nil regression guard ───────────────────────────────────────────────────

test("nil table cell still renders the em dash", function()
  -- A nil row cell must remain the em-dash sentinel, not "" or an address.
  local tlines = render_lines({
    { type = "table", headers = { "a", "b" }, rows = { { "present", nil } } },
  })
  assert_true(any_match(tlines, "\u{2014}"), "nil cell renders em dash")
  assert_false(any_match(tlines, "table: 0x%x+"), "no table address should leak")
end)

-- ── Single typed value regression guard ────────────────────────────────────

test("lone Link cell renders [[NoteA]] (not treated as array)", function()
  local lines = render_lines({
    { type = "table", headers = { "File", "link" },
      rows = { { types.Link.new("X"), types.Link.new("NoteA") } } },
  })
  assert_true(any_match(lines, "%[%[NoteA%]%]"), "lone Link renders [[NoteA]]")
  assert_false(any_match(lines, "table: 0x%x+"), "no table address should leak")
end)

_H.finish({ style = "results", exit = "os" })
