-- Regression spec (audit2 fix pass, vault-b §4.1):
-- search_filter/ripgrep.lua built an invalid ripgrep command, so every
-- plain-text / "quoted" / /regex/ vault search silently returned 0 results
-- (:VaultSearch, :VaultSearchAdvanced[Live], <leader>vfs, <leader>vfA, the
-- graph's `s`, and any saved search containing a text term):
--   1. `--` (end of options) was emitted BEFORE --max-count, the exclusion
--      globs and the file list, so rg treated all of those as positional file
--      paths and died with "No such file or directory".
--   2. `--files-from=` is not a ripgrep flag at all (-f/--file reads patterns).
--   3. `--case-insensitive` (from /pattern/i) is not a ripgrep flag either; the
--      long form of -i is --ignore-case.
--
-- This spec runs the real `rg` against a temp vault, so it fails if any of the
-- three regressions comes back (an unknown flag or a misplaced `--` makes rg
-- exit 2 with no stdout, i.e. 0 lines).
--
-- Run with: nvim --headless -u NONE -l tests/fix_vault_ripgrep_args_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;"
  .. vim.fn.stdpath("config") .. "/lua/?/init.lua;" .. package.path

local have_rg = vim.fn.executable("rg") == 1

local tmp_vault = vim.fn.tempname() .. "-vault"
vim.fn.mkdir(tmp_vault, "p")
vim.g.vault_path = tmp_vault

local hay = tmp_vault .. "/hay.md"
local other = tmp_vault .. "/other.md"
vim.fn.writefile({
  "# Hay",
  "",
  "a line with haystack in it",
  "another HAYSTACK line, upper case",
  "## Section Two",
  "tail",
}, hay)
vim.fn.writefile({ "# Other", "", "nothing to find here" }, other)

local sf = require("andrew.vault.search_filter")
local sq = require("andrew.vault.search_query")

--- Parse a query string and hand back just its text half (what rg is given).
local function text_ast(q)
  return sf.split_ast(sq.parse_query(q)).text_ast
end

local function run(q, files)
  local lines = sf.ripgrep_in_files(text_ast(q), files or { hay, other }, tmp_vault)
  return lines or {}
end

test("unquoted text returns the lines rg finds (regression: 0 results)", function()
  if not have_rg then return end
  local lines = run("haystack")
  assert_true(#lines >= 1, "expected at least one match, got " .. #lines)
  -- smart-case: an all-lowercase pattern also matches the upper-case line.
  assert_eq(#lines, 2, "smart-case should match both casings")
  for _, l in ipairs(lines) do
    assert_true(l:sub(1, #hay) == hay,
      "--with-filename must keep the path prefix so extract_rg_file works; got " .. l)
  end
end)

test("extract_rg_file recovers the path from a real rg line", function()
  if not have_rg then return end
  local lines = run("haystack")
  assert_eq(sf.extract_rg_file(lines[1]), hay)
end)

test('"quoted" text uses --fixed-strings and still matches', function()
  if not have_rg then return end
  assert_true(#run('"line with haystack"') >= 1, "quoted phrase must match")
  -- A regex metacharacter must be taken literally, i.e. match nothing here.
  assert_eq(#run('"hay.*stack"'), 0, "--fixed-strings must not treat .* as a regex")
end)

test("/regex/i maps to --ignore-case, not the non-existent --case-insensitive", function()
  if not have_rg then return end
  local ci = run("/HAYSTACK/i")
  assert_eq(#ci, 2, "case-insensitive regex must match both casings, got " .. #ci)
  -- Without the flag the same pattern only matches the upper-case line, which
  -- also proves the flag is what did the work (and that rg did not just error).
  assert_eq(#run("/HAYSTACK/"), 1, "case-sensitive regex must match only one line")
end)

test("a restricted file list really restricts the search", function()
  if not have_rg then return end
  assert_eq(#run("haystack", { other }), 0, "hay.md must not be searched")
  assert_eq(#run("haystack", { hay }), 2, "hay.md must be searched")
end)

test("boolean nodes still combine rg results", function()
  if not have_rg then return end
  assert_true(#run("haystack AND Section") >= 1, "AND over one file")
  assert_true(#run("haystack OR nothing") >= 2, "OR spans both files")
  -- NOT returns bare paths of files that do NOT match.
  local not_lines = run("NOT haystack")
  assert_eq(#not_lines, 1, "only other.md lacks the word")
  assert_eq(not_lines[1], other)
end)

vim.fn.delete(tmp_vault, "rf")

_H.finish()
