-- =============================================================================
-- Search Exclusions Spec
-- =============================================================================
-- Run: nvim --headless -u NONE -l tests/search_exclude_spec.lua
--
-- Guards the search-time directory exclusions (.obsidian, Templates) added in
-- lua/andrew/vault/search_exclude.lua and wired through engine/search_filter.
--
-- What each test pins:
--   1. The is_excluded predicate: any depth, case-insensitive, directory
--      segments only (a FILE called Templates.md must stay searchable).
--   2. The index/search SPLIT. This is the important one. `.obsidian` is removed
--      from the index by config.index.skip_dirs; `Templates` deliberately is NOT
--      -- template notes stay indexed so wikilinks to them resolve and
--      :VaultLinkCheck still reports broken links inside them. Adding "Templates"
--      to skip_dirs would look like a tidy simplification and would silently
--      break both; this test fails if anyone does it.
--   3. Real search over a real temp vault actually drops template notes.
--   4. exclude_dirs = {} turns the feature off completely, and the memoization
--      (keyed on table identity) notices.
--   5. rg_base_opts carries the exclusion globs.
--   6. vault_search_fzf_opts excludes but plain vault_fzf_opts does NOT. Also a
--      correctness guard, not a style one: vault_fzf_opts backs backlinks,
--      orphan lists and the broken-link report, where hiding template notes
--      would hide real broken links.
--   7. Real ripgrep honours the emitted --iglob patterns. The glob SYNTAX is the
--      part most likely to rot silently, so this spawns rg rather than trusting
--      a string comparison.
--   8. The general-picker helper is conditional: {} outside a vault.
--
-- No source introspection -- every assertion drives the real modules.
--
-- Discriminating power (verified by reintroducing each bug):
--   * drop the exclusion from search_filter's predicate  -> tests 3, 4 fail
--   * add "Templates" to config.index.skip_dirs          -> test 2 fails
--   * make matching case-sensitive                       -> tests 1, 3 fail
--   * match the filename as well as directories          -> tests 1, 3 fail
--   * strip the globs from rg_base_opts                  -> test 5 fails
--   * point search.lua back at vault_fzf_opts            -> test 6 fails
--   * emit "!X/**" instead of "!**/X/**"                 -> test 7 fails
--   * make utils.obsidian unconditional                  -> test 8 fails
-- =============================================================================

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_false = _H.test, _H.assert_eq, _H.assert_true, _H.assert_false

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local config = require("andrew.vault.config")
local se = require("andrew.vault.search_exclude")

local DEFAULT_DIRS = { ".obsidian", "Templates" }

--- Reassign (never mutate) so search_exclude's identity-keyed memo invalidates.
local function set_dirs(dirs)
  config.search.exclude_dirs = dirs
end

local function write(dir, rel, lines)
  local abs = dir .. "/" .. rel
  vim.fn.mkdir(abs:match("^(.*)/[^/]+$"), "p")
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

--- A vault holding one ordinary note plus every shape the predicate must judge.
local function make_vault()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write(dir, "Notes/real.md", { "---", "type: note", "---", "needle real" })
  write(dir, "Templates/Book.md", { "---", "type: note", "---", "needle template" })
  write(dir, "Projects/Templates/nest.md", { "---", "type: note", "---", "needle nested" })
  write(dir, "templates/lower.md", { "---", "type: note", "---", "needle lowercase" })
  write(dir, "Templates.md", { "---", "type: note", "---", "needle file named Templates" })
  write(dir, ".obsidian/notes.md", { "---", "type: note", "---", "needle dot obsidian" })
  return dir
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function contains(list, want)
  for _, v in ipairs(list) do
    if v == want then return true end
  end
  return false
end

print("\n=== Search Exclusions Tests ===\n")

-- ---------------------------------------------------------------------------
test("is_excluded matches directory segments at any depth, case-insensitively", function()
  set_dirs(DEFAULT_DIRS)

  assert_true(se.is_excluded("Templates/Book.md"), "top-level Templates/ excluded")
  assert_true(se.is_excluded("Projects/Templates/nest.md"), "nested Templates/ excluded")
  assert_true(se.is_excluded("templates/lower.md"), "lowercase templates/ excluded")
  assert_true(se.is_excluded("TEMPLATES/shout.md"), "uppercase TEMPLATES/ excluded")
  assert_true(se.is_excluded(".obsidian/app.json"), ".obsidian/ excluded")
  assert_true(se.is_excluded("a/b/.obsidian/c.json"), "nested .obsidian/ excluded")

  -- Directory components only: the filename is never matched.
  assert_false(se.is_excluded("Templates.md"), "a FILE named Templates.md stays searchable")
  assert_false(se.is_excluded("Notes/Templates.md"), "Templates.md in a subdir stays searchable")

  -- Whole-segment match: a directory that merely contains the word does not count.
  assert_false(se.is_excluded("My Templates Archive/x.md"), "partial segment not excluded")
  assert_false(se.is_excluded("Notes/real.md"), "ordinary note not excluded")
  assert_false(se.is_excluded("obsidian/x.md"), "obsidian/ without the dot not excluded")
end)

-- ---------------------------------------------------------------------------
test("index keeps template notes but drops .obsidian (search-only exclusion)", function()
  set_dirs(DEFAULT_DIRS)
  local dir = make_vault()
  local idx = require("andrew.vault.vault_index").VaultIndex.new(dir)
  idx:build_sync()
  local files = sorted_keys(idx:snapshot_files())

  -- Templates MUST stay indexed: wikilink resolution, backlinks and linkcheck
  -- all read the index. Excluding them here would break those silently.
  assert_true(contains(files, "Templates/Book.md"), "template note stays in the index")
  assert_true(contains(files, "Projects/Templates/nest.md"), "nested template stays in the index")
  assert_true(contains(files, "templates/lower.md"), "lowercase template stays in the index")

  -- .obsidian is excluded at the INDEX level, by config.index.skip_dirs.
  assert_false(contains(files, ".obsidian/notes.md"), ".obsidian is skipped during the index walk")
  assert_true(config.index.skip_dirs[".obsidian"] == true, "skip_dirs still owns .obsidian")
  assert_true(config.index.skip_dirs["Templates"] == nil, "Templates must NOT be in skip_dirs")
end)

-- ---------------------------------------------------------------------------
test("search results drop template notes but keep a note named Templates.md", function()
  set_dirs(DEFAULT_DIRS)
  local dir = make_vault()
  local idx = require("andrew.vault.vault_index").VaultIndex.new(dir)
  idx:build_sync()

  local ast = require("andrew.vault.search_query").parse_query("type:note")
  local matches = require("andrew.vault.search_filter").evaluate(ast, idx, nil, nil)
  local got = sorted_keys(matches)

  assert_true(contains(got, "Notes/real.md"), "ordinary note is returned")
  assert_true(contains(got, "Templates.md"), "file named Templates.md is returned")
  assert_false(contains(got, "Templates/Book.md"), "template note is filtered out")
  assert_false(contains(got, "Projects/Templates/nest.md"), "nested template is filtered out")
  assert_false(contains(got, "templates/lower.md"), "lowercase template is filtered out")
  assert_eq(#got, 2, "exactly the two searchable notes come back")
end)

-- ---------------------------------------------------------------------------
test("exclude_dirs = {} disables exclusion entirely", function()
  local dir = make_vault()
  local idx = require("andrew.vault.vault_index").VaultIndex.new(dir)
  idx:build_sync()
  local ast = require("andrew.vault.search_query").parse_query("type:note")

  set_dirs({})
  assert_false(se.active(), "no exclusions configured")
  assert_false(se.is_excluded("Templates/Book.md"), "predicate is off")
  local all = sorted_keys(require("andrew.vault.search_filter").evaluate(ast, idx, nil, nil))
  assert_eq(#all, 5, "every indexed note is searchable again")
  assert_eq(se.rg_opts(), "", "no rg globs emitted")
  assert_eq(#se.fzf_patterns(), 0, "no fzf patterns emitted")

  -- Reassigning the table must invalidate the memo (identity-keyed).
  set_dirs(DEFAULT_DIRS)
  assert_true(se.active(), "exclusions come back on")
  assert_true(se.is_excluded("Templates/Book.md"), "predicate is on again")
end)

-- ---------------------------------------------------------------------------
test("rg_base_opts carries the exclusion globs", function()
  set_dirs(DEFAULT_DIRS)
  local opts = require("andrew.vault.engine").rg_base_opts()
  assert_true(opts:find('--glob "*.md"', 1, true) ~= nil, "original *.md glob is preserved")
  assert_true(opts:find('--iglob "!**/Templates/**"', 1, true) ~= nil, "Templates excluded")
  assert_true(opts:find('--iglob "!**/.obsidian/**"', 1, true) ~= nil, ".obsidian excluded")

  -- A caller-supplied glob must still win for the include side.
  local scoped = require("andrew.vault.engine").rg_base_opts("*.txt")
  assert_true(scoped:find('--glob "*.txt"', 1, true) ~= nil, "caller glob respected")
  assert_true(scoped:find('--iglob "!**/Templates/**"', 1, true) ~= nil, "exclusions still applied")
end)

-- ---------------------------------------------------------------------------
test("vault_search_fzf_opts excludes; plain vault_fzf_opts does not", function()
  set_dirs(DEFAULT_DIRS)
  local engine = require("andrew.vault.engine")

  local plain = engine.vault_fzf_opts("Backlinks")
  assert_true(plain.file_ignore_patterns == nil,
    "plain vault_fzf_opts must NOT exclude -- it backs linkcheck/backlinks/orphans")

  local search = engine.vault_search_fzf_opts("Vault search")
  assert_true(search.file_ignore_patterns ~= nil, "search wrapper adds patterns")
  assert_true(#search.file_ignore_patterns > 0, "patterns are non-empty")
  assert_eq(search.cwd, plain.cwd, "wrapper keeps vault_fzf_opts' cwd")
  assert_eq(search.prompt, "Vault search> ", "wrapper keeps the prompt contract")

  -- A caller's own patterns must survive (fzf-lua appends this option).
  local merged = engine.vault_search_fzf_opts("X", { file_ignore_patterns = { "^zzz/" } })
  assert_true(contains(merged.file_ignore_patterns, "^zzz/"), "caller patterns are kept")
  assert_true(#merged.file_ignore_patterns > 1, "exclusion patterns are kept too")
end)

-- ---------------------------------------------------------------------------
test("real ripgrep honours the emitted exclusion globs", function()
  if vim.fn.executable("rg") ~= 1 then
    print("    (skipped: rg not on PATH)")
    return
  end
  set_dirs(DEFAULT_DIRS)
  local dir = make_vault()

  local args = { "rg", "--files-with-matches", "--hidden", "--smart-case" }
  for _, a in ipairs(se.rg_args()) do args[#args + 1] = a end
  args[#args + 1] = "needle"
  args[#args + 1] = dir

  local res = vim.system(args, { text = true }):wait()
  local hits = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    hits[#hits + 1] = line:sub(#dir + 2)
  end
  table.sort(hits)

  assert_true(contains(hits, "Notes/real.md"), "ordinary note found by rg")
  assert_true(contains(hits, "Templates.md"), "file named Templates.md found by rg")
  assert_false(contains(hits, "Templates/Book.md"), "rg skipped the templates folder")
  assert_false(contains(hits, "Projects/Templates/nest.md"), "rg skipped the nested templates folder")
  assert_false(contains(hits, "templates/lower.md"), "rg glob is case-insensitive")
  assert_false(contains(hits, ".obsidian/notes.md"), "rg skipped .obsidian even with --hidden")
end)

-- ---------------------------------------------------------------------------
test("general-picker helper only excludes inside a vault", function()
  set_dirs(DEFAULT_DIRS)
  local ob = require("andrew.utils.obsidian")

  local vault = make_vault() -- make_vault() creates .obsidian/, so it IS a vault
  assert_eq(ob.vault_root(vault), vault, "vault root detected via .obsidian marker")
  assert_eq(ob.vault_root(vault .. "/Notes"), vault, "detected from a subdirectory")
  local inside = ob.picker_opts(vault)
  assert_true(inside.file_ignore_patterns ~= nil, "excludes inside a vault")

  local plain_dir = vim.fn.tempname()
  vim.fn.mkdir(plain_dir .. "/src", "p")
  vim.fn.mkdir(plain_dir .. "/Templates", "p")
  assert_true(ob.vault_root(plain_dir) == nil, "an ordinary project is not a vault")
  assert_eq(vim.tbl_count(ob.picker_opts(plain_dir)), 0,
    "ordinary project keeps its searchable Templates/ directory")

  -- cwd travels through the merge helper so detection uses the picker's cwd.
  local merged = ob.with_picker_opts({ cwd = vault, prompt = "P> " })
  assert_eq(merged.prompt, "P> ", "caller opts preserved")
  assert_true(merged.file_ignore_patterns ~= nil, "exclusions applied for the given cwd")
  assert_eq(vim.tbl_count(ob.with_picker_opts({ cwd = plain_dir })), 1,
    "no exclusions merged in for a non-vault cwd")
end)

set_dirs(DEFAULT_DIRS)
_H.finish()
