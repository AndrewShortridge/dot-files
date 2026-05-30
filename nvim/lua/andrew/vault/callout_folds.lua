local engine = require("andrew.vault.engine")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("callout_folds")
local callout_utils = require("andrew.vault.callout_utils")
local memo = require("andrew.vault.memoize")

local M = {}

-- ---------------------------------------------------------------------------
-- Callout block boundary cache (changedtick-based, via MemoizedCheck)
-- ---------------------------------------------------------------------------

local _all_blocks_check = memo.new(memo.changedtick, function(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local raw = callout_utils.scan_blocks(lines)
  local blocks = {}
  for _, b in ipairs(raw) do
    blocks[#blocks + 1] = {
      start_line = b.start_line,
      end_line = b.end_line,
      header_lnum = b.start_line,
      suffix = b.suffix,
    }
  end
  return blocks
end, "callout_blocks_all")
memo.register_buf_cleanup(_all_blocks_check)

local _suffixed_blocks_check = memo.new(memo.changedtick, function(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local raw = callout_utils.scan_blocks(lines)
  local blocks = {}
  for _, b in ipairs(raw) do
    if b.suffix then
      blocks[#blocks + 1] = {
        start_line = b.start_line,
        end_line = b.end_line,
        header_lnum = b.start_line,
        suffix = b.suffix,
      }
    end
  end
  return blocks
end, "callout_blocks_suffixed")
memo.register_buf_cleanup(_suffixed_blocks_check)

--- Build callout block boundaries map, cached per changedtick.
---@param bufnr number
---@param suffixed_only? boolean  if true, only return blocks with +/- suffix (default false)
---@return table[] blocks  { { start_line: number, end_line: number, header_lnum: number }, ... }
local function get_callout_blocks(bufnr, suffixed_only)
  if suffixed_only then
    return _suffixed_blocks_check:get(bufnr)
  else
    return _all_blocks_check:get(bufnr)
  end
end

-- ---------------------------------------------------------------------------
-- Cache store
-- ---------------------------------------------------------------------------

local store = engine.json_store(".vault-callout-folds.json")

---@return table<string, table<string, string>>
local function load_db()
  return store.cached_load()
end

--- Prune stale entries for files that no longer exist.
---@param db table
local function prune_stale(db)
  local vault = engine.vault_path
  if not vault then return end
  for rel in pairs(db) do
    local abs = vault .. "/" .. rel
    if vim.fn.filereadable(abs) ~= 1 then
      db[rel] = nil
    end
  end
end

---@param db table
---@param prune? boolean  whether to prune stale entries (default false)
local function save_db(db, prune)
  if prune then
    prune_stale(db)
  end
  store.cached_save(db)
end

-- ---------------------------------------------------------------------------
-- Callout fingerprinting
-- ---------------------------------------------------------------------------

--- Parse callout header — delegates to callout_utils.parse_header.
local parse_callout_header = callout_utils.parse_header

--- Collect the first N content lines of a callout block (after the header).
--- Lines are stripped of the `> ` prefix and joined.
---@param bufnr number
---@param header_lnum number 1-indexed
---@param max_lines? number default 3
---@return string
local function callout_content_preview(bufnr, header_lnum, max_lines)
  max_lines = max_lines or 3
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local parts = {}
  local collected = 0

  for lnum = header_lnum + 1, line_count do
    if collected >= max_lines then break end
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if not line or not line:match("^>") then break end
    -- Strip `> ` prefix
    local content = line:gsub("^>%s?", "")
    -- Skip empty content lines for hashing purposes
    if vim.trim(content) ~= "" then
      parts[#parts + 1] = vim.trim(content)
      collected = collected + 1
    end
  end

  return table.concat(parts, "\n")
end

--- Compute the fingerprint for a callout at the given header line.
---@param bufnr number
---@param header_lnum number 1-indexed
---@return string|nil fingerprint
---@return string|nil suffix  the source suffix ("-" or "+")
local function fingerprint(bufnr, header_lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, header_lnum - 1, header_lnum, false)[1]
  if not line then return nil, nil end

  local ctype, suffix, title = parse_callout_header(line)
  if not ctype or not suffix then return nil, nil end

  local preview = callout_content_preview(bufnr, header_lnum)
  local content_hash = vim.fn.sha256(preview):sub(1, 8)

  local fp = ctype .. "|" .. title:lower() .. "|" .. content_hash
  return fp, suffix
end

--- Determine the default fold state from the source suffix.
---@param suffix string "-" or "+"
---@return string "open" or "closed"
local function default_state(suffix)
  if suffix == "-" then
    return "closed"
  else
    return "open"
  end
end

--- Get ALL callout block boundaries (including unsuffixed) for toggle/fold purposes.
---@param bufnr number
---@return table[] blocks  { { start_line, end_line, header_lnum, suffix? }, ... }
function M.get_all_blocks(bufnr)
  return get_callout_blocks(bufnr, false)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Record a fold toggle for the callout at the given header line.
--- Only stores the override if it differs from the source suffix default.
---@param bufnr number
---@param header_lnum number 1-indexed line of the callout header
---@param is_now_open boolean whether the callout is now open after the toggle
function M.record_toggle(bufnr, header_lnum, is_now_open)
  if not engine.is_vault_buf(bufnr) then return end
  local fname = vim.api.nvim_buf_get_name(bufnr)

  local fp, suffix = fingerprint(bufnr, header_lnum)
  if not fp or not suffix then return end

  local rel = engine.vault_relative(fname)
  local db = load_db()

  local user_state = is_now_open and "open" or "closed"
  local def = default_state(suffix)

  if user_state == def then
    -- User toggled back to the default -- remove the override
    if db[rel] then
      db[rel][fp] = nil
      -- Remove file entry if no overrides remain
      if next(db[rel]) == nil then
        db[rel] = nil
      end
    end
  else
    -- User overrode the default -- store it
    if not db[rel] then
      db[rel] = {}
    end
    db[rel][fp] = user_state
  end

  save_db(db)
end

--- Clear all cached fold states for the current file (or all files).
---@param all? boolean if true, clear the entire cache
function M.clear(all)
  local db = load_db()

  if all then
    db = {}
    save_db(db, true)
    notify.info("cleared all callout fold states")
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if not engine.is_vault_buf(bufnr) then
    notify.not_vault_file()
    return
  end
  local fname = vim.api.nvim_buf_get_name(bufnr)

  local rel = engine.vault_relative(fname)
  if db[rel] then
    db[rel] = nil
    save_db(db)
    notify.info("cleared callout fold states for " .. rel)
  else
    notify.info("no saved fold states for " .. rel)
  end
end

--- Debug: show cached fold states for the current file.
function M.debug()
  local bufnr = vim.api.nvim_get_current_buf()
  if not engine.is_vault_buf(bufnr) then
    notify.not_vault_file()
    return
  end
  local fname = vim.api.nvim_buf_get_name(bufnr)

  local rel = engine.vault_relative(fname)
  local db = load_db()
  local file_overrides = db[rel]

  if not file_overrides or next(file_overrides) == nil then
    notify.info("no fold overrides for " .. rel)
    return
  end

  local lines = { "Callout fold overrides for " .. rel .. ":" }
  for fp_key, state in pairs(file_overrides) do
    local parts = vim.split(fp_key, "|")
    local ctype = parts[1] or "?"
    local title = parts[2] or ""
    local hash = parts[3] or "?"
    local display_title = title ~= "" and (' "' .. title .. '"') or ""
    lines[#lines + 1] = ("  [!%s]%s [%s] -> %s"):format(ctype, display_title, hash, state)
  end

  notify.info_lines(lines)
end

--- Restore saved fold overrides for all suffixed callouts in the buffer.
--- Must be called AFTER apply_callout_folds() has set up the default folds.
---@param bufnr number
function M.restore(bufnr)
  if not engine.is_vault_buf(bufnr) then return end
  local fname = vim.api.nvim_buf_get_name(bufnr)

  local rel = engine.vault_relative(fname)
  local db = load_db()
  local file_overrides = db[rel]
  if not file_overrides or next(file_overrides) == nil then return end

  local blocks = get_callout_blocks(bufnr, true) -- suffixed only
  for _, block in ipairs(blocks) do
    local fp, _ = fingerprint(bufnr, block.header_lnum)
    if fp and file_overrides[fp] then
      local override = file_overrides[fp]
      local content_start = block.start_line + 1
      local block_end = block.end_line

      vim.api.nvim_buf_call(bufnr, function()
        if override == "open" then
          pcall(vim.cmd, content_start .. "foldopen")
        elseif override == "closed" then
          local fold_level = vim.fn.foldlevel(content_start)
          if fold_level > 0 then
            pcall(vim.cmd, content_start .. "foldclose")
          else
            pcall(vim.cmd, content_start .. "," .. block_end .. "fold")
            pcall(vim.cmd, content_start .. "foldclose")
          end
        end
      end)
    end
  end

  log.debug("restored fold overrides for %s", rel)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local palette = require("andrew.vault.command_palette")

  engine.register_cache({
    name = "callout_folds",
    module = "andrew.vault.callout_folds",
    invalidate = function()
      store.cached_invalidate()
    end,
    invalidate_file = function(abs_path)
      local db = store.cached_get()
      if not db then return end
      local rel = engine.vault_relative(abs_path)
      if rel and db[rel] then
        db[rel] = nil
      end
    end,
    stats = function()
      local db = store.cached_get()
      return {
        entries = db and vim.tbl_count(db) or 0,
        age_seconds = nil,
        vault = engine.vault_path,
        ttl = nil,
      }
    end,
  })

  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "callout_folds_all",
      get_size = function() return _all_blocks_check._entry_count end,
      get_capacity = function() return nil end,
      get_hits = function() return _all_blocks_check._hits end,
      get_misses = function() return _all_blocks_check._misses end,
      get_evictions = function() return nil end,
    })
    profiler.register_cache({
      name = "callout_folds_suffixed",
      get_size = function() return _suffixed_blocks_check._entry_count end,
      get_capacity = function() return nil end,
      get_hits = function() return _suffixed_blocks_check._hits end,
      get_misses = function() return _suffixed_blocks_check._misses end,
      get_evictions = function() return nil end,
    })
  end

  vim.api.nvim_create_user_command("VaultFoldClear", function(cmd_opts)
    M.clear(cmd_opts.bang)
  end, {
    desc = "Clear cached callout fold states (! for all files)",
    bang = true,
  })

  vim.api.nvim_create_user_command("VaultFoldDebug", function()
    M.debug()
  end, { desc = "Show cached callout fold states for current file" })

  -- VimLeavePre autocmd removed: now dispatched via event_dispatch.lua

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  palette.register_command("VaultFoldClear", "Clear cached callout fold states (! for all files)", "Debug", function()
    M.clear()
  end)
  palette.register_command("VaultFoldDebug", "Show cached callout fold states for current file", "Debug", function()
    M.debug()
  end)
  palette.register_keymap("<leader>mZ", "Clear callout fold cache (this file)", "Debug", function()
    M.clear()
  end, true)
end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "<leader>mZ", function()
    M.clear()
  end, {
    buffer = ev.buf,
    desc = "Clear callout fold cache (this file)",
    silent = true,
  })
end

--- Called by event_dispatch.lua on VimLeavePre for cleanup.
function M.teardown()
  local db = store.cached_get()
  if db then
    save_db(db, true)
  end
end

return M
