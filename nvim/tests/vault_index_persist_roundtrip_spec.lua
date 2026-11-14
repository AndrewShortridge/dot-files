-- End-to-end spec for vault index persist/load fidelity.
--
-- Regression for the persist strip bug: strip_derived() used to MUTATE the live
-- self.files entries, nulling fields that the entry metatable cannot recompute
-- (rel_stem / rel_stem_lower, per-task tags_lower / text_lower, per-outlink
-- _name_lower). After the first persist those fields stayed nil in memory until
-- the next Neovim restart, silently breaking inlink resolution (reads rel_stem)
-- and task-tag search (reads tags_lower). The strip is now non-mutating: it
-- encodes a stripped COPY and leaves live entries fully derived.
--
-- This drives the REAL vault_index module against a temp vault (no mock), so it
-- verifies the actual code path. Assertions are observable behavior only:
--   * live entries keep their derived fields across a full persist AND a WAL delta
--   * inlinks recomputed AFTER a persist still resolve (the bug's main victim)
--   * the persisted JSON still omits derived fields (size win preserved)
--   * persist -> load reconstructs derived state identically
--
-- Run with: nvim --headless -u NONE -l tests/vault_index_persist_roundtrip_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
local vi = require("andrew.vault.vault_index")

print("\n=== Vault Index Persist Round-Trip Tests ===\n")

-- ---------------------------------------------------------------------------
-- Build a throwaway vault on disk and return a freshly built index over it.
-- ---------------------------------------------------------------------------
local function write_file(dir, rel, lines)
  local abs = dir .. "/" .. rel
  local parent = abs:match("^(.*)/[^/]+$")
  if parent then vim.fn.mkdir(parent, "p") end
  local f = assert(io.open(abs, "w"))
  f:write(table.concat(lines, "\n"))
  f:close()
end

local function make_vault()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  write_file(dir, "notes/alpha.md", {
    "---",
    "title: Alpha",
    "aliases: [A1]",
    "tags: [project]",
    "---",
    "",
    "# Heading One",
    "",
    "Links to [[beta]].",
    "",
    "- [ ] do a thing #urgent [due:: 2026-02-01]",
    "",
    "A block paragraph. ^blk-001",
  })
  write_file(dir, "notes/beta.md", {
    "---",
    "title: Beta",
    "---",
    "",
    "# Beta Heading",
    "",
    "Back to [[alpha]].",
  })
  return dir
end

local ALPHA = "notes/alpha.md"
local BETA = "notes/beta.md"

-- Find the (single) task on alpha, and its outlink to beta.
local function alpha_task(idx)
  return idx.files[ALPHA].tasks[1]
end
local function alpha_outlink(idx)
  for _, l in ipairs(idx.files[ALPHA].outlinks) do
    if (l._name_lower or ""):find("beta") or (l.path or ""):find("beta") then return l end
  end
  return idx.files[ALPHA].outlinks[1]
end

-- ===========================================================================
-- 1. The bug: live entries must stay fully derived after a FULL persist.
-- ===========================================================================
test("full persist does not strip derived fields off live entries", function()
  local dir = make_vault()
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()

  -- Sanity: derived fields present after build.
  assert_eq(idx.files[ALPHA].rel_stem, "notes/alpha", "rel_stem present after build")
  assert_true(alpha_task(idx).tags_lower ~= nil, "task tags_lower present after build")
  assert_true(alpha_task(idx).tags_lower["urgent"], "task tag 'urgent' indexed")
  assert_true(alpha_outlink(idx)._name_lower ~= nil, "outlink _name_lower present after build")

  -- Force a synchronous full persist (the path that used to mutate live state).
  idx:persist_now()

  -- THE FIX: live entries are untouched.
  assert_eq(idx.files[ALPHA].rel_stem, "notes/alpha", "rel_stem survives persist")
  assert_true(idx.files[ALPHA].rel_stem_lower ~= nil, "rel_stem_lower survives persist")
  assert_true(alpha_task(idx).tags_lower ~= nil, "task tags_lower survives persist")
  assert_true(alpha_task(idx).tags_lower["urgent"], "task tag still indexed after persist")
  assert_true(alpha_outlink(idx)._name_lower ~= nil, "outlink _name_lower survives persist")
end)

-- ===========================================================================
-- 2. The bug's main victim: inlinks recomputed AFTER persist still resolve.
--    (add_inlink reads source_entry.rel_stem; a nil rel_stem yields path=nil.)
-- ===========================================================================
test("inlinks recomputed after persist still resolve source paths", function()
  local dir = make_vault()
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  idx:persist_now()

  -- Recompute inlinks AFTER the persist. With the old mutating strip, alpha's
  -- rel_stem would be nil here and beta's inlink record would carry path=nil.
  idx:_recompute_inlinks()

  local beta_inlinks = idx._inlinks[BETA]
  assert_true(beta_inlinks ~= nil and #beta_inlinks > 0, "beta has at least one inlink")
  local found = false
  for _, rec in ipairs(beta_inlinks) do
    if rec.path == "notes/alpha" then found = true end
  end
  assert_true(found, "beta's inlink from alpha resolves to 'notes/alpha' (not nil)")
end)

-- ===========================================================================
-- 3. WAL delta path (incremental persist) must also not mutate live entries.
-- ===========================================================================
test("WAL delta persist does not strip live entries", function()
  local dir = make_vault()
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()

  -- Re-index alpha (single-file update -> _persist_delta / WAL path).
  idx:update_file(dir .. "/" .. ALPHA)

  assert_eq(idx.files[ALPHA].rel_stem, "notes/alpha", "rel_stem intact after WAL delta")
  assert_true(alpha_task(idx).tags_lower ~= nil, "task tags_lower intact after WAL delta")
  assert_true(alpha_task(idx).tags_lower["urgent"], "task tag intact after WAL delta")
end)

-- ===========================================================================
-- 4. Size win preserved: persisted JSON still omits derived fields.
-- ===========================================================================
test("persisted JSON omits derived fields", function()
  local dir = make_vault()
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  idx:persist_now()

  local f = assert(io.open(dir .. "/.vault-index/index.json", "r"))
  local raw = f:read("*a")
  f:close()
  local data = vim.json.decode(raw)
  local pe = data.files[ALPHA]
  assert_true(pe ~= nil, "alpha present in persisted index")
  assert_nil(pe.rel_stem, "persisted entry omits rel_stem")
  assert_nil(pe.rel_stem_lower, "persisted entry omits rel_stem_lower")
  assert_nil(pe.tasks[1].tags_lower, "persisted task omits tags_lower")
  assert_nil(pe.tasks[1].text_lower, "persisted task omits text_lower")
  -- Non-derived data is retained.
  assert_true(pe.tasks[1].tags ~= nil, "persisted task keeps raw tags")
  assert_eq(pe.frontmatter.title, "Alpha", "persisted frontmatter retained")
end)

-- ===========================================================================
-- 5. Round-trip fidelity: persist -> load reconstructs derived state.
-- ===========================================================================
test("persist then load reconstructs derived fields", function()
  local dir = make_vault()
  local idx = vi.VaultIndex.new(dir)
  idx:build_sync()
  idx:persist_now()

  -- Fresh index loading from the persisted JSON.
  local idx2 = vi.VaultIndex.new(dir)
  local ok = idx2:load()
  assert_true(ok, "load() succeeds")

  assert_eq(idx2.files[ALPHA].rel_stem, "notes/alpha", "rel_stem reconstructed on load")
  assert_true(idx2.files[ALPHA].rel_stem_lower ~= nil, "rel_stem_lower reconstructed")
  local t = idx2.files[ALPHA].tasks[1]
  assert_true(t.tags_lower ~= nil, "task tags_lower reconstructed on load")
  assert_true(t.tags_lower["urgent"], "task tag reconstructed on load")
  assert_true(alpha_outlink(idx2)._name_lower ~= nil, "outlink _name_lower reconstructed")

  -- Loaded inlinks resolve (beta linked from alpha).
  local beta_inlinks = idx2._inlinks[BETA]
  assert_true(beta_inlinks ~= nil and #beta_inlinks > 0, "loaded index has beta inlinks")
end)

_H.finish({ style = "results", exit = "os" })
