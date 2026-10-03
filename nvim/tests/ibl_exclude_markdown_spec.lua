-- Perf regression spec for excluding markdown from indent-blankline (ibl).
--
-- ibl attaches to markdown buffers (markdown is NOT in its default exclude
-- list) and runs a viewport refresh on CursorMoved/CursorMovedI/TextChanged/
-- TextChangedI/BufWinEnter/WinScrolled (~0.3-1.5ms/refresh). render-markdown
-- already supplies the desired list/indent visuals, so ibl is redundant on
-- markdown. The fix adds `exclude = { filetypes = { "markdown" } }` to the ibl
-- opts. ibl MERGES exclude.filetypes with its defaults (utils.tbl_join in
-- config.lua), so this APPENDS markdown and preserves the default excludes.
--
-- This drives the REAL plugin spec table (dofile) and the REAL ibl config/
-- merge/gate (when ibl is installed). No source introspection / string scan.
--
-- Discriminating power:
--   * Removing `exclude` from opts fails Test A (markdown not in opts).
--   * An 'overwrite' merge that clobbers defaults fails Test B (the default
--     excludes like 'help'/'man'/'gitcommit' would vanish).
--   * is_buffer_active returning true for a markdown buffer (i.e. the gate not
--     honoring the merged exclude) fails Test B.
--
-- Run with: nvim --headless -u NONE -l tests/ibl_exclude_markdown_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

local plug = dofile(vim.fn.stdpath("config") .. "/lua/andrew/plugins/indent-blankline.lua")

local function contains(list, val)
  for _, v in ipairs(list or {}) do
    if v == val then return true end
  end
  return false
end

test("plugin spec returns a table for lukas-reineke/indent-blankline.nvim", function()
  assert_true(type(plug) == "table", "spec must return a table")
  assert_eq(plug[1], "lukas-reineke/indent-blankline.nvim", "spec must point at indent-blankline.nvim")
end)

test("Test A: opts excludes markdown", function()
  assert_true(type(plug.opts) == "table", "opts must be a table")
  assert_true(type(plug.opts.exclude) == "table", "opts.exclude must exist")
  assert_true(type(plug.opts.exclude.filetypes) == "table", "opts.exclude.filetypes must be a table")
  assert_true(contains(plug.opts.exclude.filetypes, "markdown"), "exclude.filetypes must contain 'markdown'")
end)

-- Test B: real merge + gate. Only runs when ibl is installed (skips gracefully).
local lazy_root = vim.fn.stdpath("data") .. "/lazy/indent-blankline.nvim/lua"
if vim.fn.isdirectory(lazy_root) == 1 then
  package.path = package.path .. ";" .. lazy_root .. "/?.lua;" .. lazy_root .. "/?/init.lua"
end

local ok_config, ibl_config = pcall(require, "ibl.config")
local ok_utils, ibl_utils = pcall(require, "ibl.utils")

if ok_config and ok_utils then
  test("Test B: merged config appends markdown and preserves defaults; gate honors it", function()
    local merged = ibl_config.set_config(plug.opts)
    assert_true(type(merged) == "table", "set_config must return the merged config")

    -- markdown was appended
    assert_true(contains(merged.exclude.filetypes, "markdown"),
      "merged exclude.filetypes must contain the appended 'markdown'")

    -- defaults preserved (tbl_join append, NOT overwrite)
    for _, ft in ipairs({ "help", "man", "gitcommit", "TelescopePrompt", "checkhealth" }) do
      assert_true(contains(merged.exclude.filetypes, ft),
        "merged exclude.filetypes must still contain default '" .. ft .. "' (append, not clobber)")
    end

    -- gate: markdown buffer is NOT active. (buftype="" so the filetype gate is
    -- what's exercised — ibl's default exclude.buftypes excludes nofile, which
    -- scratch buffers default to.)
    local md_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "", { buf = md_buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = md_buf })
    assert_false(ibl_utils.is_buffer_active(md_buf, merged),
      "ibl must NOT be active for a markdown buffer")

    -- gate: a non-markdown (lua) buffer IS active
    local lua_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "", { buf = lua_buf })
    vim.api.nvim_set_option_value("filetype", "lua", { buf = lua_buf })
    assert_true(ibl_utils.is_buffer_active(lua_buf, merged),
      "ibl must still be active for a non-markdown (.lua) buffer")

    vim.api.nvim_buf_delete(md_buf, { force = true })
    vim.api.nvim_buf_delete(lua_buf, { force = true })
  end)
else
  print("  SKIP: ibl.config/ibl.utils not requireable (plugin not installed) — Test B skipped")
end

_H.finish({ style = "results", exit = "os" })
