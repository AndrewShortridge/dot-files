-- Perf regression spec for nvim-treesitter-context lazy gating.
--
-- The plugin spec used to declare `event = { "BufReadPre", "BufNewFile" }`, so
-- the plugin (and its .config/.render/.util submodules, plus its global
-- CursorMoved/WinScrolled autocmds) loaded on EVERY buffer open — including
-- markdown/text — even though `on_attach` already returns false for markdown,
-- meaning the plugin attaches to nothing there. The entire load was wasted for
-- markdown-only sessions.
--
-- The fix: drop the eager `event` trigger and gate with `ft = { ...code/struct
-- filetypes that actually have sticky context... }` (mirrors treesitter
-- ensure_installed MINUS markdown/markdown_inline). `ft` implies lazy, so the
-- plugin no longer loads at all in markdown/text. `[c` (go_to_context) still
-- lazy-loads the plugin on demand via the `keys` block even in markdown buffers.
--
-- This drives the REAL plugin spec table (dofile) and asserts the load gate. No
-- source introspection / string scanning.
--
-- Discriminating power:
--   * Re-adding `event = {...}` fails Test 2 (assert_nil(plug.event)).
--   * Adding `lazy = false` fails Test 2 (assert_nil(plug.lazy)).
--   * Dropping `ft` fails Test 2 (ft-table assertion).
--   * Adding markdown/markdown_inline back to ft fails Test 3.
--   * Removing the `[c` keys entry fails Test 4 (go_to_context on demand).
--
-- Run with: nvim --headless -u NONE -l tests/treesitter_context_lazy_ft_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_true, assert_nil = _H.test, _H.assert_true, _H.assert_nil

local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/treesitter-context.lua")

local function ft_set()
  local set = {}
  for _, ft in ipairs(plug.ft or {}) do
    set[ft] = true
  end
  return set
end

test("plugin spec returns a table for nvim-treesitter-context", function()
  assert_true(type(plug) == "table", "spec must return a table")
  assert_true(plug[1] == "nvim-treesitter/nvim-treesitter-context", "spec must point at treesitter-context")
end)

test("lazy-gated on code/struct filetypes (not eager event)", function()
  -- The whole point: no eager `event`, no `lazy = false`; `ft` implies lazy.
  assert_nil(plug.event, "event gate must be removed (eager event force-loads on every md open)")
  assert_nil(plug.lazy, "lazy must not be set (ft implies lazy; lazy=false would re-break startup deferral)")
  assert_true(type(plug.ft) == "table", "ft gate must exist")
end)

test("markdown does NOT trigger load (gated off via on_attach instead)", function()
  local set = ft_set()
  assert_nil(set["markdown"], "markdown must NOT be in ft (it attaches to nothing — gated off in on_attach)")
  assert_nil(set["markdown_inline"], "markdown_inline must NOT be in ft")
  -- Representative code/struct filetypes still gate the plugin on.
  assert_true(set["lua"], "lua must trigger load")
  assert_true(set["python"], "python must trigger load")
  assert_true(set["rust"], "rust must trigger load")
  assert_true(set["c"], "c must trigger load")
  assert_true(set["typescript"], "typescript must trigger load")
end)

test("[c keymap still lazy-loads go_to_context on demand", function()
  assert_true(type(plug.keys) == "table", "keys block must exist (on-demand load survives in markdown)")
  local found
  for _, entry in ipairs(plug.keys) do
    if entry[1] == "[c" and type(entry[2]) == "function" then
      found = true
      break
    end
  end
  assert_true(found, "[c -> go_to_context entry must exist so it loads on demand even in non-ft buffers")
end)

_H.finish({ style = "results", exit = "os" })
