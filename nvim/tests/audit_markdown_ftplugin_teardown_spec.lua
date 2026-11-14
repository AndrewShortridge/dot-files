-- Regression spec: ftplugin/markdown.lua must undo its own buffer-local state
-- when the buffer's filetype really CHANGES, but must keep everything on the
-- markdown -> markdown re-fires (vault/init.lua Phase B, `:edit`, `:setf`).
--
-- Before the fix nothing was added to `b:undo_ftplugin`, so `:setlocal ft=lua`
-- on a markdown buffer left ~140 markdown-only buffer-local mappings live in a
-- Lua buffer: `o`/`O` kept continuing lists, `j`/`k` kept walking screen lines,
-- `<Tab>` kept toggling folds, `ac`/`al`/`aq` kept shadowing text objects, and
-- the three buffer commands stayed. (The gO / ]] / [[ traceback that
-- after/ftplugin/markdown.lua defends against is the same class of leak.)
--
-- The inverse regression matters just as much: the teardown runs from
-- $VIMRUNTIME/ftplugin.vim on EVERY FileType event, so tearing down
-- unconditionally would destroy and rebuild every mapping on each re-fire --
-- exactly what the vim.b.__md_ftplugin_done guard exists to prevent.
-- Run with: nvim --headless -u NONE -l tests/audit_markdown_ftplugin_teardown_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local config = vim.fn.stdpath("config")
package.path = config .. "/lua/?.lua;" .. package.path
vim.opt.runtimepath:prepend(config)
vim.opt.runtimepath:append(config .. "/after")
vim.cmd("filetype plugin on")

-- `-u NONE` leaves 'mapleader' at its default, so build the <leader> prefix
-- from whatever this process actually has instead of hardcoding a space.
local LEADER = vim.g.mapleader or "\\"

--- lhs set of every buffer-local mapping, keyed "<mode>\0<lhs>".
local function map_set(buf)
  local seen = {}
  for _, mode in ipairs({ "n", "i", "v", "x", "s", "o" }) do
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      seen[mode .. "\0" .. m.lhs] = m.desc or ""
    end
  end
  return seen
end

local function fresh_markdown_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  return buf
end

test("the ftplugin registers a teardown hook and records what to undo", function()
  local buf = fresh_markdown_buf()
  assert_true(
    tostring(vim.b[buf].undo_ftplugin or ""):find("__md_undo_ftplugin", 1, true) ~= nil,
    "b:undo_ftplugin must call the markdown teardown: " .. tostring(vim.b[buf].undo_ftplugin)
  )
  local recorded = vim.b[buf].__md_ft_maps
  assert_eq(type(recorded), "table", "__md_ft_maps must be a list")
  assert_true(#recorded > 50, "expected the ftplugin's own mappings to be recorded, got " .. #recorded)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("a markdown -> markdown re-fire keeps every mapping and the guard", function()
  local buf = fresh_markdown_buf()
  local before = map_set(buf)
  local n_before = vim.tbl_count(before)
  assert_true(n_before > 50, "sanity: markdown buffer should have many maps, got " .. n_before)

  -- Phase-B style re-fire, then a same-value `filetype` set, then a full reload.
  vim.cmd("doautocmd FileType")
  vim.bo[buf].filetype = "markdown"
  vim.cmd("doautocmd FileType markdown")

  assert_eq(vim.tbl_count(map_set(buf)), n_before, "re-firing FileType must not drop or duplicate maps")
  assert_eq(vim.b[buf].__md_ftplugin_done, true, "the once-per-buffer guard must survive a re-fire")
  assert_true(
    tostring(vim.b[buf].undo_ftplugin or ""):find("__md_undo_ftplugin", 1, true) ~= nil,
    "the teardown hook must be re-registered on every FileType event"
  )
  assert_true(#(vim.b[buf].__md_ft_maps or {}) > 50, "the recorded undo list must survive a re-fire")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("a real filetype change removes the markdown-only mappings", function()
  local buf = fresh_markdown_buf()
  local before = map_set(buf)
  -- A representative slice: ftplugin-owned, md-textobjects, tex-motions,
  -- list-continuation and the table helpers.
  local owned = {
    "n\0<Tab>", "n\0za", "n\0]#", "n\0[#", "n\0]1", "n\0j", "n\0k",
    "n\0o", "n\0O", "n\0" .. LEADER .. "mb", "n\0" .. LEADER .. "m1", "n\0" .. LEADER .. "mq",
    "n\0" .. LEADER .. "mS", "n\0" .. LEADER .. "Tc", "n\0" .. LEADER .. "Tir", "n\0" .. LEADER .. "Tdt",
    "x\0ac", "o\0ac", "x\0al", "o\0il", "x\0aq", "o\0aq", "x\0am", "o\0im",
    "n\0]b", "n\0]l", "n\0]q", "n\0]m", "x\0p", "x\0P",
  }
  for _, key in ipairs(owned) do
    assert_true(before[key] ~= nil, "precondition: markdown buffer should map " .. key:gsub("%z", " "))
  end

  vim.bo[buf].filetype = "lua"

  local after = map_set(buf)
  for _, key in ipairs(owned) do
    assert_nil(after[key], key:gsub("%z", " ") .. " must be gone after ft=lua")
  end
  assert_eq(vim.fn.exists(":TableCreate"), 0, ":TableCreate must be gone after ft=lua")
  assert_eq(vim.fn.exists(":VaultListContinue"), 0, ":VaultListContinue must be gone after ft=lua")
  assert_eq(vim.fn.exists(":SmartPasteToggle"), 0, ":SmartPasteToggle must be gone after ft=lua")
  assert_nil(vim.b[buf].__md_ftplugin_done, "the guard must be cleared so markdown can re-register later")
  assert_nil(vim.b[buf].__md_ft_maps, "the recorded undo list must be cleared")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("plain `o` behaviour is restored in the changed buffer", function()
  local buf = fresh_markdown_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- item" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.bo[buf].filetype = "lua"
  vim.cmd("silent! normal o")
  vim.cmd("silent! normal! \27")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(lines[2], "", "`o` must open an EMPTY line once the buffer is no longer markdown")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("switching back to markdown re-registers everything", function()
  local buf = fresh_markdown_buf()
  vim.bo[buf].filetype = "lua"
  vim.bo[buf].filetype = "markdown"
  local after = map_set(buf)
  for _, key in ipairs({ "n\0<Tab>", "n\0o", "n\0" .. LEADER .. "mb", "x\0ac", "n\0]#" }) do
    assert_true(after[key] ~= nil, key:gsub("%z", " ") .. " must come back with markdown")
  end
  assert_eq(vim.fn.exists(":TableCreate"), 2, ":TableCreate must come back with markdown")
  assert_eq(vim.b[buf].__md_ftplugin_done, true, "the guard must be set again")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("a second markdown buffer gets its own mappings and guard", function()
  local a = fresh_markdown_buf()
  local b = fresh_markdown_buf()
  assert_eq(vim.b[a].__md_ftplugin_done, true, "first buffer keeps its guard")
  assert_eq(vim.b[b].__md_ftplugin_done, true, "second buffer gets its own guard")
  assert_true(map_set(b)["n\0" .. LEADER .. "mb"] ~= nil, "second buffer has the markdown maps")
  -- Tearing down buffer b must not touch buffer a.
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "lua"
  assert_nil(map_set(b)["n\0" .. LEADER .. "mb"], "b lost its maps")
  assert_true(map_set(a)["n\0" .. LEADER .. "mb"] ~= nil, "a kept its maps")
  vim.api.nvim_buf_delete(a, { force = true })
  vim.api.nvim_buf_delete(b, { force = true })
end)

_H.finish()
