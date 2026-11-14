-- Regression spec (audit2 fix pass, vault-b §4.2):
-- link_utils.parse_target() had no case for Obsidian's block-reference syntax
-- `[[Note#^block]]` / `[[#^block]]`, so it fell through to LINK_NAME_HEADING and
-- returned `heading = "^block"`. Every consumer goes through this one funnel, so
-- a perfectly good block ref looked like a broken anchor: `gf` landed on line 1,
-- `K` showed "Heading not found: #^blk1", :VaultLinkDiag reported "Broken
-- heading" and :VaultFixLinks offered to "repair" it.
--
-- The second half of the spec pins every OTHER link form to today's parse, so a
-- future reordering of the patterns cannot quietly change them.
--
-- Run with: nvim --headless -u NONE -l tests/fix_vault_blockref_target_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;"
  .. vim.fn.stdpath("config") .. "/lua/?/init.lua;" .. package.path

local link_utils = require("andrew.vault.link_utils")

local function parsed(inner)
  local r = link_utils.parse_target(inner)
  return { name = r.name, heading = r.heading, block_id = r.block_id, alias = r.alias }
end

local function check(inner, want)
  local got = parsed(inner)
  for _, k in ipairs({ "name", "heading", "block_id", "alias" }) do
    assert_eq(got[k], want[k], inner .. " -> " .. k)
  end
end

test("[[Note#^block]] is a block reference, not a heading", function()
  check("delta#^blk1", { name = "delta", block_id = "blk1" })
  -- With an alias, and with a block id that does not exist (still a block ref).
  check("delta#^blk1|Alias", { name = "delta", block_id = "blk1", alias = "Alias" })
  check("delta#^nope", { name = "delta", block_id = "nope" })
end)

test("[[#^block]] is a block reference in the current note", function()
  check("#^blk1", { name = "", block_id = "blk1" })
end)

test("the #^ form parses identically to the bare ^ form", function()
  assert_true(vim.deep_equal(parsed("delta#^blk1"), parsed("delta^blk1")),
    "[[Note#^id]] and [[Note^id]] are the same reference")
  assert_true(vim.deep_equal(parsed("#^blk1"), parsed("^blk1")),
    "[[#^id]] and [[^id]] are the same reference")
end)

test("every other link form parses exactly as before", function()
  check("alpha", { name = "alpha" })
  check("beta|Beta Alias", { name = "beta", alias = "Beta Alias" })
  check("gamma#Section Two", { name = "gamma", heading = "Section Two" })
  check("delta^blk1", { name = "delta", block_id = "blk1" })
  check("#Head", { name = "", heading = "Head" })
  check("^blk1", { name = "", block_id = "blk1" })
  check("a#b^c", { name = "a", heading = "b", block_id = "c" })
  check("a#b#c", { name = "a", heading = "b#c" })
  check("note#Head|Alias", { name = "note", heading = "Head", alias = "Alias" })
  check("diagram.png", { name = "diagram.png" })
  -- Escaped pipe (markdown tables) is still normalised to an alias separator.
  check("note\\|Alias", { name = "note", alias = "Alias" })
end)

_H.finish()
