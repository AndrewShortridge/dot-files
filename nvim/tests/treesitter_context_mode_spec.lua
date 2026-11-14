-- Perf regression spec for nvim-treesitter-context in markdown.
--
-- The plugin spec used to pass `mode = "cursor"` with no per-filetype gate, so
-- the context module re-walked the TS tree on EVERY CursorMoved (the hottest
-- nav event). In markdown that re-walks the heading tree per cursor move. The
-- plugin has no per-filetype `mode` option (it is a single global string), so
-- the only behavior-isolated lever is `on_attach`: returning false for
-- markdown makes update_win() short-circuit in cannot_open() before
-- context.get() is ever called for md buffers, while leaving every
-- non-markdown filetype byte-identical (mode stays "cursor").
--
-- This drives the REAL plugin spec file and CALLS its real on_attach against
-- temp buffers whose filetype is set (mirroring how the plugin invokes it on
-- FileType/BufReadPost). No source introspection / string scanning.
--
-- Discriminating power: removing the on_attach gate (or making it return true
-- for markdown) fails Test 3's markdown case; switching `mode` away from
-- "cursor" fails Test 2. So the spec fails iff the fix is reverted.
--
-- Manual :profile verification: open a large markdown file, run
--   :profile start /tmp/p.log | profile func *treesitter-context*
--   :profile file *context.lua*
-- hold `j` to move many lines WITHOUT scrolling, then `:profile stop`.
-- context.M.get / get_parent_nodes call-count attributable to CursorMoved
-- should be ~0 in a markdown buffer after the fix (vs N before); a code
-- buffer still shows context.get firing on cursor move (behavior preserved).
--
-- Run with: nvim --headless -u NONE -l tests/treesitter_context_mode_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/treesitter-context.lua")

local vault = vim.fn.tempname()
vim.fn.mkdir(vault, "p")
local bufs = {}

local function make_buf(name, ft)
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/" .. name)
  vim.bo[buf].filetype = ft
  bufs[#bufs + 1] = buf
  return buf
end

test("plugin spec exposes an opts table", function()
  assert_true(type(plug) == "table", "spec must return a table")
  assert_true(type(plug.opts) == "table", "spec must expose opts table")
end)

test("non-markdown context mode preserved (cursor)", function()
  -- mode must stay "cursor" so code-file sticky context is unchanged.
  assert_eq(plug.opts.mode, "cursor", "code-file cursor mode must be preserved")
  assert_true(type(plug.opts.on_attach) == "function", "on_attach gate must exist")
end)

test("markdown gated off cursor-mode recompute; non-markdown stays attached", function()
  local md = make_buf("note.md", "markdown")
  assert_eq(plug.opts.on_attach(md), false, "markdown must be gated off cursor-mode context")

  local lua = make_buf("code.lua", "lua")
  assert_true(plug.opts.on_attach(lua) ~= false, "non-markdown must stay attached (cursor mode preserved)")
end)

-- Cleanup.
for _, buf in ipairs(bufs) do
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end
pcall(vim.fn.delete, vault, "rf")

_H.finish({ style = "results", exit = "os" })
