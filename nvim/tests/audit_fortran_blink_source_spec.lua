-- Spec for the RETIREMENT of andrew.fortran.blink-source, the FortranDocs
-- completion source.
--
-- WHAT IT PINS
--
-- The source is gone and Fortran completion comes from the fortran-extras LSP
-- server (andrew.fortran.lsp_completion, tests/fortran_lsp_completion_spec.lua).
-- Three defects went with it, and the reason each was unfixable where it lived
-- is the reason this file now asserts absence rather than behaviour:
--
--   1. It ignored the line. On `!$OMP PARALLEL DO PRIV` it offered the same
--      388 items it offers in a declaration (omp-audit A-F1).
--   2. Its items had no textEdit, so blink inserted the LABEL -- and the
--      labels were documentation KEYS. `!$OMP PARALLEL DO omp_private` is not
--      a program (A-F2).
--   3. It shipped every markdown body on every keystroke; a blink source has
--      nowhere to put a lazy document. `resolveProvider` does.
--
-- Its two hard-won lessons survive in the new source: copy-before-serve is
-- moot once items arrive over LSP (blink copies per round), and the
-- snippet-shadow penalty -- which kept `ompdo<CR>` from inserting the literal
-- word instead of expanding the block -- is now sort bucket `12.`.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * "the module is gone" fails if the file comes back, which is the only way
--     the provider block could start working again.
--   * "no Fortran source list names it" fails if any per_filetype entry is
--     restored -- blink would then load a module that is not there and log on
--     every keystroke in a Fortran buffer.
--   * "lsp is first in every Fortran list" fails if the LSP source is dropped
--     while removing the old one, which would leave Fortran with no MPI or
--     OpenMP completion at all.
--   * "no provider block survives" fails if the `fortran_docs` provider table
--     is left behind: a provider named by nothing is dead config, and this
--     repo has been bitten by exactly that (the dotted per_filetype keys).
--   * "the snippet-shadow lesson is carried" fails if lsp_completion stops
--     computing the snippet prefixes.
--
-- Run with: nvim --headless -u NONE -l tests/audit_fortran_blink_source_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg = vim.fn.stdpath("config")
package.path = cfg .. "/lua/?.lua;" .. package.path

-- The plugin spec is read the same way audit_plugins_surround_blink_spec.lua
-- reads it: dofile the module, which returns the lazy.nvim spec table.
local blink = dofile(cfg .. "/lua/andrew/plugins/blink-cmp.lua")
local per_ft = blink.opts.sources.per_filetype
local providers = blink.opts.sources.providers

local FORTRAN_FTS = { "fortran", "fortran_free", "fortran_fixed", "f90", "f95" }

test("the blink source module is gone", function()
  assert_eq(vim.fn.filereadable(cfg .. "/lua/andrew/fortran/blink-source.lua"), 0,
    "lua/andrew/fortran/blink-source.lua is back:")
  local ok = pcall(require, "andrew.fortran.blink-source")
  assert_true(not ok, "andrew.fortran.blink-source is still requirable:")
end)

test("no Fortran source list names fortran_docs, and lsp leads every one", function()
  for _, ft in ipairs(FORTRAN_FTS) do
    local list = per_ft[ft]
    assert_true(type(list) == "table", "per_filetype." .. ft .. " must still exist:")
    for _, name in ipairs(list) do
      assert_true(name ~= "fortran_docs", "per_filetype." .. ft .. " still names fortran_docs:")
    end
    assert_eq(list[1], "lsp", "per_filetype." .. ft .. " must lead with lsp:")
  end
end)

test("no fortran_docs provider block survives", function()
  assert_nil(providers.fortran_docs, "the provider table is still there:")
  for name, p in pairs(providers) do
    assert_true(p.module ~= "andrew.fortran.blink-source",
      "provider `" .. name .. "` still points at the deleted module:")
  end
end)

test("nothing else in the config still references the source", function()
  local hits = vim.fn.systemlist({
    "grep", "-rIl", "--include=*.lua", "fortran%.blink%-source", cfg .. "/lua",
  })
  assert_eq(#hits, 0, "still referenced by: " .. table.concat(hits, ", "))
end)

test("the snippet-shadow lesson is carried by the LSP source", function()
  -- It was a score_offset in the blink source; it is a sort bucket now, which
  -- is the portable spelling. `ompdo` is a snippet abbreviation and must still
  -- be recognised as one.
  local C = require("andrew.fortran.lsp_completion")
  local prefixes = C.snippet_prefixes()
  assert_true(prefixes["ompdo"], "the snippet prefixes are no longer being read:")
  assert_true(prefixes["mpi_init"], "mpi_init is a snippet prefix and must be known:")
  local demoted
  for _, it in ipairs(C.items("      call MPI_Ini", 19, {})) do
    if it.label == "MPI_Init" then
      demoted = it.sortText
    end
  end
  assert_eq((demoted or ""):sub(1, 3), "12.", "a snippet-shadowing name must sort in bucket 12:")
end)

test("Fortran completion still works, through the LSP source", function()
  -- The whole point of the removal: what the old source could not do.
  local C = require("andrew.fortran.lsp_completion")
  local line = "      !$OMP PARALLEL DO priv"
  local found
  for _, it in ipairs(C.items(line, #line, {})) do
    if it.label == "PRIVATE(…)" then
      found = it
    end
  end
  assert_true(found ~= nil, "the clause the old source could not offer in context:")
  -- A snippet, so the closing paren is written too and the cursor lands inside
  -- it (autopairs never sees an LSP textEdit, so a bare `PRIVATE(` stayed open).
  assert_eq(found.textEdit.newText, "PRIVATE($1)", "...and what accepting it now inserts (A-F2):")
  assert_eq(found.insertTextFormat, 2, "inserted as a snippet, not plain text:")
end)

_H.finish()
