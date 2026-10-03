-- Regression spec (vault-b audit): embeds must render even when the pipeline
-- line-parse cache is still cold.
--
-- Bug found by the vault-b audit: embed.lua's build_descriptors() built embed
-- descriptors ONLY from line_parse_cache.pipeline_token_iter(). For every
-- markdown buffer opened after the first one in a session that cache is still
-- cold when the initial render runs, so the iterator was nil, zero descriptors
-- were produced, nothing was rendered -- and render_embeds() then called
-- region_tracker.mark_ranges_valid() for the whole buffer anyway. The buffer
-- was permanently marked "clean", so no later pass ever retried and
-- :VaultEmbedRender answered "embeds up to date" while showing no
-- transclusion at all. Observed for real in a pty: `![[beta]]` rendered in the
-- first note opened and in no note opened afterwards.
--
-- Run with: nvim --headless -u NONE -l tests/audit_vault_b_embed_cold_cache_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault

local target = tmp_vault .. "/target.md"
vim.fn.writefile({ "# Target", "", "TARGET-BODY-LINE" }, target)
local host = tmp_vault .. "/host.md"
vim.fn.writefile({ "# Host", "", "![[target]]", "", "tail" }, host)

local lpc = require("andrew.vault.line_parse_cache")
local embed = require("andrew.vault.embed")
local state = require("andrew.vault.embed_state")

local function embed_virt_text(bufnr)
  local parts = {}
  for name, ns in pairs(vim.api.nvim_get_namespaces()) do
    if name:match("VaultEmbed") then
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        local d = m[4] or {}
        for _, vl in ipairs(d.virt_lines or {}) do
          for _, chunk in ipairs(vl) do parts[#parts + 1] = tostring(chunk[1]) end
        end
      end
    end
  end
  return table.concat(parts, " ")
end

test("build_descriptors falls back to a buffer scan when the parse cache is cold", function()
  vim.cmd("edit! " .. vim.fn.fnameescape(host))
  vim.bo.filetype = "markdown"
  local bufnr = vim.api.nvim_get_current_buf()

  -- Simulate the "second buffer of the session" situation: the buffer has
  -- embed syntax but the pipeline parse cache has never seen it.
  lpc.invalidate(bufnr)
  local warm = lpc.has_token(bufnr, "embed")
  assert_true(not warm, "precondition: parse cache must be cold for this buffer")
  assert_true(state.has_embeds(bufnr), "precondition: buffer must contain ![[...]] syntax")

  embed.render_embeds({ silent = true })
  vim.wait(300, function() return embed_virt_text(bufnr) ~= "" end)

  -- Before the fix this was "" (zero extmarks): no descriptors were built, so
  -- nothing at all was rendered for the embed line.
  local txt = embed_virt_text(bufnr)
  assert_true(txt:find("%[%[target%]%]") ~= nil,
    "cold parse cache must still render the embed block; got: " .. vim.inspect(txt))
end)

test("descriptor columns from the cold-cache path match the ![[...]] span", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local bst = state.try_get_buf_state(bufnr)
  assert_true(bst ~= nil and bst.descriptors ~= nil, "render must store descriptors")
  local list = bst.descriptors.list
  assert_eq(#list, 1, "host.md has exactly one embed")
  local d = list[1]
  assert_eq(d.lnum, 3, "embed is on line 3 (1-indexed)")
  assert_eq(d.col_s, 1, "col_s is the 1-indexed start of '!'")
  assert_eq(d.col_e, 11, "col_e is the 1-indexed inclusive end of ']]'")
  assert_eq(d.inner, "target", "inner is the wikilink body")
  assert_true(d.is_image == false, "![[target]] is a note embed, not an image")
end)

vim.fn.delete(tmp_vault, "rf")

_H.finish()
