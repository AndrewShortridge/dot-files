-- tests/fixtures.lua
-- Shared test-DATA builders for vault specs (temp-vault scaffolding).
-- Separate concern from spec_helper.lua (which holds the test()/assert_* harness).
--
-- Load with the script-dir pattern so it works under both:
--   nvim --headless -u NONE -l tests/<spec>.lua  (cwd = anywhere)
--   run_all.lua (cwd = config root)
--
-- Usage:
--   local _F = dofile((debug.getinfo(1,"S").source:gsub("^@",""):match("^(.*)[/\\]") or ".") .. "/fixtures.lua")
--
-- NOTE: This module intentionally does NOT provide a "synthetic index / entry"
-- builder. The three specs that build in-memory indexes/entries
-- (search_query_spec make_entry, graph_traversal_spec stub_idx/make_resolver_stub,
-- behavioral_upgrades_spec make_mock_index) use structurally different shapes
-- with no reconcilable common form, so they keep their own local builders.

local M = {}

-- ============================================================================
-- write_file(path, content) — write a string to an absolute path.
-- Byte-identical to the local helpers previously in graph_traversal_spec.lua
-- and link_maintenance_spec.lua. Parent directory must already exist
-- (make_temp_vault creates parent dirs for nested names).
-- ============================================================================
function M.write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

-- ============================================================================
-- make_tmp_dir() — fresh temp directory (vim.fn.tempname() + mkdir -p).
-- Mirrors link_maintenance_spec.make_tmp_dir.
-- ============================================================================
function M.make_tmp_dir()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  return tmp
end

-- ============================================================================
-- make_temp_vault(files, opts) — create a temp vault directory and write files.
--
--   files : table<string, string>  -- relative name -> string content
--   opts  : { suffix=string }      -- optional suffix appended to tempname()
--
-- Returns the absolute temp-vault path. Parent directories of nested
-- relative names (e.g. "sub/Note.md") are created automatically, so this is a
-- strict superset of both prior call patterns.
--
-- Files are written via M.write_file (string content). This does NOT build a
-- vault index or set engine.vault_path — callers own that, since the index
-- handle and engine state are used differently per spec.
-- ============================================================================
function M.make_temp_vault(files, opts)
  opts = opts or {}
  local tmp = vim.fn.tempname() .. (opts.suffix or "")
  vim.fn.mkdir(tmp, "p")
  for name, content in pairs(files or {}) do
    local path = tmp .. "/" .. name
    local dir = vim.fn.fnamemodify(path, ":h")
    if dir ~= tmp then
      vim.fn.mkdir(dir, "p")
    end
    M.write_file(path, content)
  end
  return tmp
end

return M
