-- Spec for andrew.lsp_keymaps.is_organize_imports_kind -- the predicate that
-- gates <leader>co (Organize Imports).
--
-- WHAT IT PINS
--
-- Servers NAMESPACE their source actions. ruff advertises
-- `source.organizeImports.ruff`; basedpyright advertises the bare
-- `source.organizeImports`. The original predicate was anchored
-- `^source%.organizeImports%.?$`, which matches the bare kind or the bare kind
-- with a trailing dot and NOTHING ELSE -- so <leader>co could never bind, not
-- even in a Python buffer with ruff attached. An empirical keymap diff on
-- 2026-09-06 found the key absent in both a .py and a .f90 buffer, which is
-- how a gate that never passes hides: it looks exactly like a server that
-- lacks the capability.
--
-- The fix has to be a prefix test that still respects kind SEGMENTS. LSP kinds
-- are dot-separated and a kind is a match when it is the base kind or a
-- descendant of it -- so `source.organizeImports.ruff` qualifies and
-- `source.organizeImportsAggressively` must not. A bare `find("^source%.organizeImports")`
-- would wrongly accept the latter, which is the obvious over-correction.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "ruff's namespaced kind" fails under the ORIGINAL anchored pattern --
--     this is the regression that shipped, and it is the reason this file
--     exists.
--   * "a longer word is not a match" fails if the predicate is loosened to a
--     bare prefix test `^source%.organizeImports` with no segment boundary.
--   * "the bare kind" fails if the exact-equality arm is dropped (a prefix-only
--     test requiring a trailing dot would reject basedpyright's spelling).
--   * "unrelated kinds" fails if the anchor `^` is dropped, since
--     `source.fixAll.source.organizeImports` would then match.
--
-- Run with: nvim --headless -u NONE -l tests/lsp_organize_imports_kind_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq = _H.test, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local keymaps = require("andrew.lsp_keymaps")
local is_oi = keymaps.is_organize_imports_kind

test("the bare kind matches", function()
  -- basedpyright and pyright both advertise exactly this.
  assert_eq(is_oi("source.organizeImports"), true, "bare source.organizeImports:")
end)

test("ruff's namespaced kind matches", function()
  -- The one that shipped broken. ruff is the reason <leader>co exists at all.
  assert_eq(is_oi("source.organizeImports.ruff"), true, "source.organizeImports.ruff:")
end)

test("other vendors' namespaced kinds match", function()
  assert_eq(is_oi("source.organizeImports.biome"), true, "biome:")
  assert_eq(is_oi("source.organizeImports.sortImports.ruff"), true, "a two-segment suffix:")
end)

test("a longer word is not a match", function()
  -- The over-correction guard: a bare prefix test would accept these.
  assert_eq(is_oi("source.organizeImportsAggressively"), false, "no segment boundary:")
  assert_eq(is_oi("source.organizeImports2"), false, "digit suffix:")
end)

test("unrelated kinds do not match", function()
  assert_eq(is_oi("source.fixAll"), false, "source.fixAll:")
  assert_eq(is_oi("source.fixAll.ruff"), false, "source.fixAll.ruff:")
  assert_eq(is_oi("quickfix"), false, "quickfix:")
  assert_eq(is_oi("refactor.extract"), false, "refactor.extract:")
  -- Anchoring: the base kind appearing later in the string is not a match.
  -- This case must carry a `.` SEGMENT after the base kind, or an unanchored
  -- pattern would reject it for the wrong reason and the test would prove
  -- nothing -- which is exactly what the first draft of it did.
  assert_eq(is_oi("refactor.source.organizeImports.ruff"), false, "not anchored at the start:")
end)

test("the trailing-dot spelling the old pattern allowed still matches", function()
  -- Harmless, and keeping it means the fix is a strict superset of the old
  -- behaviour -- no server that used to bind can stop binding.
  assert_eq(is_oi("source.organizeImports."), true, "trailing dot:")
end)

_H.finish()
