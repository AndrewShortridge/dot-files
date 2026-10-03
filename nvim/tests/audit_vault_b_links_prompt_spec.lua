-- Regression specs (vault-b audit):
--   1. :VaultForwardlinks must not invent a ".md" note for an attachment embed.
--      Bug: forwardlinks() appended ".md" to every wikilink target it could not
--      resolve, so `![[diagram.png]]` was listed as "diagram.png.md" -- a note
--      that does not exist and that <CR> would have created.
--   2. The Advanced Search prompt must opt out of blink.cmp.
--      Bug: blink.cmp binds <CR> to { "accept", "fallback" } in insert mode, so
--      while its menu was open the prompt's own <CR> (= submit the search) was
--      swallowed and the user had to press Enter twice. Confirmed in a pty:
--      first <CR> only dismissed the blink menu, the second opened fzf.
--
-- Run with: nvim --headless -u NONE -l tests/audit_vault_b_links_prompt_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault

-- fzf-lua is a lazy plugin and is not on the rtp under `-u NONE`; stub the
-- entry points the code under test uses so the pickers are observable.
local captured = {}
package.loaded["fzf-lua"] = {
  fzf_exec = function(items, opts) captured.items = items; captured.opts = opts end,
  fzf_live = function() end,
  grep = function() end,
  live_grep = function() end,
  files = function() end,
  actions = setmetatable({}, { __index = function() return function() end end }),
  utils = { rg_escape = function(s) return s end },
}

vim.fn.writefile({ "# Real", "", "body" }, tmp_vault .. "/real.md")
vim.fn.writefile({ "\137PNG" }, tmp_vault .. "/pic.png")

local host = tmp_vault .. "/host.md"
vim.fn.writefile({
  "# Host",
  "",
  "- [[real]]",
  "- ![[pic.png]]",
  "- [[nope]]",
}, host)

test("forwardlinks lists an image embed by name, not as <name>.md", function()
  local backlinks = require("andrew.vault.backlinks")
  vim.cmd("edit! " .. vim.fn.fnameescape(host))
  vim.bo.filetype = "markdown"

  captured = {}
  backlinks.forwardlinks()

  local items = captured.items or {}
  local set = {}
  for _, v in ipairs(items) do set[v] = true end

  assert_true(set["pic.png"], "image embed must be listed verbatim; got " .. vim.inspect(items))
  assert_true(not set["pic.png.md"], "image embed must NOT become pic.png.md; got " .. vim.inspect(items))
  -- A genuinely missing NOTE still gets the .md hint (unchanged behaviour).
  assert_true(set["nope.md"], "missing note keeps the .md suffix; got " .. vim.inspect(items))
  assert_true(set["real.md"], "resolved note is listed by its vault-relative path")
end)

test("the Advanced Search prompt buffer disables blink.cmp", function()
  local prompt = require("andrew.vault.search.prompt")
  local before = vim.api.nvim_list_bufs()
  local seen = {}
  for _, b in ipairs(before) do seen[b] = true end

  prompt.search_advanced()

  local prompt_buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not seen[b] then prompt_buf = b end
  end
  assert_true(prompt_buf ~= nil, "search_advanced must create a prompt buffer")
  assert_eq(vim.b[prompt_buf].completion, false,
    "prompt buffer must set vim.b.completion = false so blink.cmp does not steal <CR>")

  -- <CR> must still be the prompt's own submit mapping, in both n and i.
  local function has_cr(mode)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(prompt_buf, mode)) do
      if m.lhs == "<CR>" then return true end
    end
    return false
  end
  assert_true(has_cr("n"), "<CR> must be mapped in normal mode on the prompt buffer")
  assert_true(has_cr("i"), "<CR> must be mapped in insert mode on the prompt buffer")

  vim.cmd("stopinsert")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then pcall(vim.api.nvim_win_close, w, true) end
  end
end)

vim.fn.delete(tmp_vault, "rf")

_H.finish()
