-- Spec for after/ftplugin/markdown.lua -- the guard around nvim's markdown
-- gO / ]] / [[ keys.
--
-- $VIMRUNTIME/ftplugin/markdown.lua binds those three to
-- vim.treesitter._headings. Those functions are unsafe outside markdown and
-- vimdoc: get_headings() resolves `lang` from the buffer filetype and returns
-- early only when it is nil, then indexes a hardcoded `heading_queries` table
-- that holds ONLY markdown and vimdoc. For any other filetype with a
-- treesitter language it calls ts.query.parse(lang, nil); the nil query reaches
-- vim.func._memoize's hash, which table.concat's it:
--
--   E5108: ... _memoize.lua:79: invalid value (nil) at index 2 in table for 'concat'
--
-- That was hit for real: gO in a .f90 buffer, with markdown.lua:4 in the
-- traceback. How markdown's buffer-local mapping came to be live in a Fortran
-- buffer was never reproduced, so the fix is defensive -- it makes the mapping
-- harmless wherever it ends up rather than relying on it never ending up there.
--
-- This drives the REAL after/ftplugin file by dofile-ing it with a markdown
-- buffer current, then invokes the mapped callbacks. Assertions are on
-- behaviour (does it populate the loclist, does it raise), not on file text.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * Test 2 fails if the guard is dropped and gO calls show_toc
--     unconditionally -- it raises the exact E5108 above.
--   * Test 3 fails if ]] / [[ lose their guard (same crash).
--   * Test 4 fails if gO stops working in real markdown, i.e. if the guard is
--     too aggressive and the feature is lost rather than protected.
--   * Test 5 fails if the guard appends its own copy of the runtime's teardown
--     (a duplicated :nunmap always fails -> v:errmsg = "E31: No such mapping"
--     on every markdown buffer) or if the runtime teardown that covers the
--     three keys -- what stops a filetype change from leaving them behind --
--     stops reaching b:undo_ftplugin.
--
-- Run with: nvim --headless -u NONE -l tests/markdown_headings_guard_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_match = _H.test, _H.assert_eq, _H.assert_true, _H.assert_match

local config_dir = vim.fn.stdpath("config")
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/nvim-treesitter")
vim.opt.runtimepath:prepend(config_dir)

local AFTER = config_dir .. "/after/ftplugin/markdown.lua"

--- Fresh markdown buffer with the guard applied; returns the captured maps.
local function setup_markdown_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# Title",
    "",
    "text",
    "",
    "## Sub",
    "",
    "more",
  })
  vim.bo[buf].filetype = "markdown"
  dofile(AFTER)

  local maps = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    maps[m.lhs] = m
  end
  return buf, maps
end

test("the guard binds gO, ]] and [[ buffer-locally", function()
  local buf, maps = setup_markdown_buffer()
  for _, lhs in ipairs({ "gO", "]]", "[[" }) do
    assert_true(maps[lhs] ~= nil, "missing buffer-local mapping: " .. lhs)
    assert_true(type(maps[lhs].callback) == "function", lhs .. " must have a Lua callback")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("gO does NOT raise when the buffer is no longer markdown", function()
  local buf, maps = setup_markdown_buffer()
  -- Simulate the leak: keep the mapping, change what the buffer is.
  vim.bo[buf].filetype = "fortran"

  local ok, err = pcall(maps["gO"].callback)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert_true(ok, "gO must not raise in a non-markdown buffer, got: " .. tostring(err))
end)

test("]] and [[ do NOT raise when the buffer is no longer markdown", function()
  local buf, maps = setup_markdown_buffer()
  vim.bo[buf].filetype = "fortran"

  for _, lhs in ipairs({ "]]", "[[" }) do
    local ok, err = pcall(maps[lhs].callback)
    assert_true(ok, lhs .. " must not raise in a non-markdown buffer, got: " .. tostring(err))
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("gO still produces an outline in a real markdown buffer", function()
  local buf, maps = setup_markdown_buffer()
  vim.fn.setloclist(0, {}, " ")

  local ok, err = pcall(maps["gO"].callback)
  local entries = #vim.fn.getloclist(0)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert_true(ok, "gO must work in markdown: " .. tostring(err))
  assert_eq(entries, 2, "the two headings in the sample must reach the loclist")
end)

test("teardown is the runtime ftplugin's, and we add no second copy", function()
  -- The guard deliberately appends NOTHING to b:undo_ftplugin. Its mappings
  -- replace the runtime ones on the same lhs, so the runtime's own teardown
  -- removes ours too; a second copy only guaranteed a FAILING :nunmap (the
  -- first had already removed the mapping), which sets v:errmsg to
  -- "E31: No such mapping" on every markdown buffer.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].undo_ftplugin = "SENTINEL"
  dofile(AFTER)
  assert_eq(vim.b[buf].undo_ftplugin, "SENTINEL", "the guard must not append its own teardown")
  vim.api.nvim_buf_delete(buf, { force = true })

  -- ...and in a REAL load the runtime ftplugin already registers exactly one
  -- teardown for each of the three keys, which is what stops a filetype change
  -- from leaving them behind. $VIMRUNTIME must precede our after/ dir here so
  -- the load order matches production.
  local saved_rtp = vim.o.runtimepath
  vim.o.runtimepath = vim.env.VIMRUNTIME .. "," .. config_dir .. "/after"
  vim.cmd("filetype plugin on")
  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf2)
  vim.bo[buf2].filetype = "markdown"
  local undo = vim.b[buf2].undo_ftplugin or ""
  local maps = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf2, "n")) do
    maps[m.lhs] = m
  end
  vim.o.runtimepath = saved_rtp
  vim.api.nvim_buf_delete(buf2, { force = true })

  for _, lhs in ipairs({ "gO", "]]", "%[%[" }) do
    assert_match(undo, "nunmap <buffer> " .. lhs, "b:undo_ftplugin must unmap " .. lhs:gsub("%%", ""))
  end
  -- gO is unmapped exactly once. (]] / [[ are unmapped TWICE by the runtime
  -- itself -- once by ftplugin/markdown.vim, once by ftplugin/markdown.lua --
  -- which is an upstream bug reproducible with `nvim -u NONE`, so it is not
  -- asserted here. What this config must not do is add a THIRD copy.)
  assert_eq(select(2, undo:gsub("nunmap <buffer> gO", "")), 1,
    "exactly one gO teardown (a duplicate always fails -> E31)")
  -- Sanity: the after/ftplugin really did run last in that load.
  for _, lhs in ipairs({ "gO", "]]", "[[" }) do
    assert_true(type(maps[lhs]) == "table" and type(maps[lhs].callback) == "function",
      lhs .. " must be the guard's Lua callback after a real load")
  end
end)

_H.finish({ style = "results", exit = "os" })
