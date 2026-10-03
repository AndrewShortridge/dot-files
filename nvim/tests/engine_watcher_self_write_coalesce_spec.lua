-- Behavioral spec for lua/andrew/vault/engine_watcher.lua self-write coalescing.
--
-- A real save fires BufWritePost (synchronous, reliable indexer) AND a
-- redundant inotify echo that lands in the debounced watcher flush. The
-- watcher must coalesce away its echo for paths that BufWritePost already
-- registered via note_self_write(), while still indexing genuinely external
-- edits (no note_self_write) and re-indexing once the TTL has expired.
--
-- Run with: nvim --headless -u NONE -l tests/engine_watcher_self_write_coalesce_spec.lua

-- Make the vault package requirable headlessly.
do
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  local tests_dir = src:match("^(.*)[/\\][^/\\]*$") or "."
  local root = tests_dir:match("^(.*)[/\\]tests$") or (tests_dir .. "/..")
  package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
end

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

print("\n=== engine_watcher self-write coalesce tests ===")

local W = require("andrew.vault.engine_watcher")

local VAULT = "/tmp/coalesce-test-vault"

-- Build a fresh fake environment for each test: a spy engine and a fake
-- vault_index whose update_files_batch records the paths it was asked to index.
local function setup_env()
  local updated = {} -- list of path-arrays passed to update_files_batch

  local fake_idx = {
    vault_path = VAULT,
    _building = false,
    update_files_batch = function(_self, paths)
      updated[#updated + 1] = paths
    end,
    build_async = function() end,
  }

  -- flush_pending_files reads package.loaded["andrew.vault.vault_index"].current()
  package.loaded["andrew.vault.vault_index"] = {
    current = function() return fake_idx end,
  }

  W.setup({
    invalidate_caches = function() end,
  })

  W._test.reset()
  W._test.set_active(true)
  W._test.set_vault(VAULT)

  return updated
end

-- Flatten the recorded update batches into a seen-set of paths.
local function indexed_set(updated)
  local seen = {}
  for _, batch in ipairs(updated) do
    for _, p in ipairs(batch) do
      seen[p] = true
    end
  end
  return seen
end

test("self-written path is coalesced away (NOT re-indexed by watcher)", function()
  local updated = setup_env()
  local path = VAULT .. "/note.md"

  -- BufWritePost registers the self-write, then the fs echo lands as pending.
  W.note_self_write(path)
  W._test.add_pending(path)

  W._test.flush_pending_files()

  assert_true(not indexed_set(updated)[path], "self-written path must not be re-indexed by watcher")
end)

test("external edit (no note_self_write) IS indexed by watcher", function()
  local updated = setup_env()
  local path = VAULT .. "/external.md"

  -- No note_self_write: an external editor / git changed it.
  W._test.add_pending(path)

  W._test.flush_pending_files()

  assert_true(indexed_set(updated)[path], "external edit must be indexed by watcher")
end)

test("mixed flush: self-write coalesced, external sibling still indexed", function()
  local updated = setup_env()
  local self_path = VAULT .. "/saved.md"
  local ext_path = VAULT .. "/changed.md"

  W.note_self_write(self_path)
  W._test.add_pending(self_path)
  W._test.add_pending(ext_path)

  W._test.flush_pending_files()

  local seen = indexed_set(updated)
  assert_true(not seen[self_path], "self-written path coalesced")
  assert_true(seen[ext_path], "external sibling still indexed")
end)

test("note_self_write is a no-op when the watcher is inactive", function()
  local updated = setup_env()
  W._test.set_active(false)
  local path = VAULT .. "/inactive.md"

  -- With watcher inactive, note_self_write records nothing; if a stray event
  -- still arrived it would index normally (BufWritePost is the sole indexer).
  W.note_self_write(path)
  W._test.set_active(true) -- re-activate so flush proceeds
  W._test.add_pending(path)

  W._test.flush_pending_files()

  assert_true(indexed_set(updated)[path], "no suppression registered while inactive")
end)

test("second flush after consuming the self-write re-indexes (TTL consumed)", function()
  local updated = setup_env()
  local path = VAULT .. "/note.md"

  W.note_self_write(path)
  W._test.add_pending(path)
  W._test.flush_pending_files() -- consumes the self-write entry

  -- A genuinely new external change to the same path now arrives.
  W._test.add_pending(path)
  W._test.flush_pending_files()

  assert_true(indexed_set(updated)[path], "subsequent external change must be re-indexed")
end)

_H.finish({ style = "plain", exit = "os_guard" })
