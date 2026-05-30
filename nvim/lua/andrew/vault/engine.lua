local link_utils = require("andrew.vault.link_utils")
local date_utils = require("andrew.vault.date_utils")
local notify = require("andrew.vault.notify")
local config = require("andrew.vault.config")
local vault_log = require("andrew.vault.vault_log")
local url_validate = require("andrew.vault.url_validate")
local log = vault_log.scope("engine")

local M = {}

-- Lazy accessors for heavy dependencies (deferred until first use)
local _vault_index
local function get_vault_index()
  if not _vault_index then _vault_index = require("andrew.vault.vault_index") end
  return _vault_index
end

local _watcher
local function get_watcher()
  if not _watcher then
    _watcher = require("andrew.vault.engine_watcher")
    _watcher.setup(M)
  end
  return _watcher
end

-- =============================================================================
-- Cache Registry
-- =============================================================================

--- @type table<string, CacheSpec>
M._cache_registry = {}

--- @class CacheSpec
--- @field name string           Unique cache identifier
--- @field module string         Module path for display
--- @field invalidate fun()      Full invalidation callback
--- @field invalidate_file? fun(abs_path: string)  Per-file invalidation (optional)
--- @field stats? fun(): CacheStats  Status reporting callback (optional)

--- @class CacheStats
--- @field entries number|nil    Number of cached entries
--- @field age_seconds number|nil Seconds since last build/refresh
--- @field vault string|nil      Vault path this cache is scoped to
--- @field ttl number|nil        Configured TTL in seconds (nil = no TTL)
--- @field total_bytes number|nil Current byte weight (memory-weighted caches)
--- @field max_bytes number|nil   Byte budget (memory-weighted caches)
--- @field utilization number|nil total_bytes / max_bytes (memory-weighted caches)

--- Register a cache with the central registry.
--- @param spec CacheSpec
function M.register_cache(spec)
  assert(spec.name, "cache spec must have a name")
  assert(spec.invalidate, "cache spec must have an invalidate function")
  M._cache_registry[spec.name] = spec
end

--- Invalidate caches matching the given criteria.
--- @param opts? { scope?: "all"|"files", paths?: string[], module?: string, skip_index?: boolean }
function M.invalidate_caches(opts)
  opts = opts or {}
  local scope = opts.scope or "all"
  local paths = opts.paths
  local module_name = opts.module

  local invalidated = {}

  for name, spec in pairs(M._cache_registry) do
    if module_name and name ~= module_name then
      goto continue
    end

    if scope == "files" and paths and spec.invalidate_file then
      for _, p in ipairs(paths) do
        spec.invalidate_file(p)
      end
    else
      spec.invalidate()
    end

    invalidated[#invalidated + 1] = name
    ::continue::
  end

  -- Propagate to memoized state checks
  if scope == "all" then
    local memo_mod = package.loaded["andrew.vault.memoize"]
    if memo_mod then memo_mod.clear_all() end
  end

  -- Propagate to vault index if it's already initialized
  -- (lazy: don't create the index just for invalidation)
  -- skip_index: caller already updated the index (e.g., fs watcher used update_files_batch)
  if not opts.skip_index then
    local vault_index_mod = package.loaded["andrew.vault.vault_index"]
    if vault_index_mod then
      local idx = vault_index_mod.current()
      if idx then
        if scope == "files" and paths then
          idx:update_files_batch(paths)
        elseif scope == "all" then
          idx:build_async()
        end
      end
    end
  end

  -- Fire the User autocmd so downstream listeners can react
  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "VaultCacheInvalidate",
    data = {
      scope = scope,
      paths = paths,
      module = module_name,
      invalidated = invalidated,
    },
  })
  if not ok then log.debug("autocmd VaultCacheInvalidate failed: %s", err) end
end

--- Get status information for all registered caches.
--- @return table<string, CacheStats>
function M.cache_stats()
  local results = {}
  for name, spec in pairs(M._cache_registry) do
    if spec.stats then
      results[name] = spec.stats()
    else
      results[name] = { entries = nil, age_seconds = nil }
    end
  end
  return results
end

--- Known LRU cache name -> config.cache field mapping.
--- Used by cache_debug() to show max capacity and fill percentage.
--- @type table<string, string>
local LRU_CONFIG_KEYS = {
  connections = "connections_max",
  slug = "slug_max",
  date_parse = "date_parse_max",
  section_cache = "section_cache_max",
  note_data = "note_data_max",
  file_content = "file_content_max",
  section_outlinks = "section_cache_max",
  graph_filter_bfs = "bfs_traversal_max",
}

--- Registered weighted cache names.
--- Budget totals are derived from each cache's stats().max_bytes (which
--- aggregates sub-cache budgets, e.g. file_content includes section_cache).
--- @type string[]
local WEIGHTED_CACHE_NAMES = {
  "connections",
  "file_content",
  "section_outlinks",
  "graph_filter_bfs",
}

--- Build a detailed debug report of all registered caches and LRU limits.
--- Returns formatted lines suitable for display in a scratch buffer.
--- @return string[]
function M.cache_debug()
  local stats = M.cache_stats()
  local lines = { "Vault Cache Debug", string.rep("=", config.ui.status_separator_width), "" }

  -- Section 1: Registered caches
  lines[#lines + 1] = "Registered Caches (" .. vim.tbl_count(M._cache_registry) .. ")"
  lines[#lines + 1] = string.rep("-", config.ui.status_separator_width)

  local names = {}
  for name in pairs(M._cache_registry) do names[#names + 1] = name end
  table.sort(names)

  for _, name in ipairs(names) do
    local spec = M._cache_registry[name]
    local s = stats[name] or {}
    local parts = {}

    -- Entries / size
    if s.entries ~= nil then
      parts[#parts + 1] = string.format("entries: %d", s.entries)
    end

    -- Check if this cache has a known LRU max from config
    local cfg_key = LRU_CONFIG_KEYS[name]
    local max_cap = cfg_key and config.cache[cfg_key]
    if max_cap and s.entries then
      local pct = (s.entries / max_cap) * 100
      parts[#parts + 1] = string.format("max: %d", max_cap)
      parts[#parts + 1] = string.format("fill: %.1f%%", pct)
    end

    -- Byte utilization (for memory-weighted caches)
    if s.total_bytes and s.max_bytes and s.max_bytes > 0 then
      local mb_used = s.total_bytes / (1024 * 1024)
      local mb_max = s.max_bytes / (1024 * 1024)
      local byte_pct = (s.total_bytes / s.max_bytes) * 100
      parts[#parts + 1] = string.format("%.1f MB / %.1f MB (%d%%)", mb_used, mb_max, byte_pct)
    end

    -- Age
    if s.age_seconds then
      parts[#parts + 1] = string.format("age: %.1fs", s.age_seconds)
    end

    -- TTL
    if s.ttl then
      parts[#parts + 1] = string.format("TTL: %ds", s.ttl)
    end

    -- Vault
    if s.vault then
      parts[#parts + 1] = "vault: " .. link_utils.get_tail(s.vault)
    end

    -- Generation / index info
    if s.index_generation then
      parts[#parts + 1] = "gen: " .. tostring(s.index_generation)
    end

    -- Module-specific extras (items_count, type, etc.)
    if s.items_count then
      parts[#parts + 1] = string.format("items: %d", s.items_count)
    end
    if s.type then
      parts[#parts + 1] = "type: " .. s.type
    end

    local detail = #parts > 0 and table.concat(parts, ", ") or "no stats"
    local mod_str = type(spec.module) == "string" and spec.module or ""
    lines[#lines + 1] = string.format("  %-24s %s", name, detail)
    if mod_str ~= "" then
      lines[#lines + 1] = string.format("  %-24s module: %s", "", mod_str)
    end
  end

  -- Section 2: LRU capacity limits from config
  lines[#lines + 1] = ""
  lines[#lines + 1] = "LRU Capacity Limits (config.cache)"
  lines[#lines + 1] = string.rep("-", config.ui.status_separator_width)

  local cfg_keys = {}
  for k in pairs(config.cache) do cfg_keys[#cfg_keys + 1] = k end
  table.sort(cfg_keys)

  for _, k in ipairs(cfg_keys) do
    local v = config.cache[k]
    if k:match("_bytes$") then
      lines[#lines + 1] = string.format("  %-28s %.1f MB", k, v / (1024 * 1024))
    else
      lines[#lines + 1] = string.format("  %-28s %d", k, v)
    end
  end

  -- Section 3: Memory budget summary (weighted caches)
  local total_used, total_budget = 0, 0
  for _, cache_name in ipairs(WEIGHTED_CACHE_NAMES) do
    local s = stats[cache_name]
    if s then
      if s.total_bytes then total_used = total_used + s.total_bytes end
      if s.max_bytes then total_budget = total_budget + s.max_bytes end
    end
  end
  if total_budget > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Memory Budget Summary"
    lines[#lines + 1] = string.rep("-", config.ui.status_separator_width)
    lines[#lines + 1] = string.format("  Total weighted:    %.1f MB / %.1f MB (%.1f%%)",
      total_used / (1024 * 1024), total_budget / (1024 * 1024),
      (total_used / total_budget) * 100)
  end

  -- Section 4: Vault index summary (if available)
  local vault_index_mod = package.loaded["andrew.vault.vault_index"]
  if vault_index_mod then
    local idx = vault_index_mod.current()
    if idx then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Vault Index"
      lines[#lines + 1] = string.rep("-", config.ui.status_separator_width)
      lines[#lines + 1] = string.format("  %-24s %s", "vault", idx.vault_path)
      lines[#lines + 1] = string.format("  %-24s %d", "files", idx:file_count())
      lines[#lines + 1] = string.format("  %-24s %s", "ready", tostring(idx:is_ready()))
      lines[#lines + 1] = string.format("  %-24s %d", "generation", idx._generation)
    end
  end

  -- Section 5: String intern pools
  if vault_index_mod then
    local pool_stats = vault_index_mod.intern_pool_stats()
    if pool_stats and next(pool_stats) then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "String Intern Pools"
      lines[#lines + 1] = string.rep("-", config.ui.status_separator_width)
      local pool_names = {}
      for name in pairs(pool_stats) do pool_names[#pool_names + 1] = name end
      table.sort(pool_names)
      for _, name in ipairs(pool_names) do
        local s = pool_stats[name]
        lines[#lines + 1] = string.format("  %-24s %d/%d (hit rate: %.1f%%)",
          name, s.size, s.max, s.hit_rate)
      end
    end
  end

  -- Section 6: Memoized state checks
  local memo_ok, memo_mod = pcall(require, "andrew.vault.memoize")
  if memo_ok then
    local memo_stats = memo_mod.stats()
    if #memo_stats > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Memoized State Checks"
      lines[#lines + 1] = string.rep("-", config.ui.status_separator_width)
      for _, s in ipairs(memo_stats) do
        local total = s.hits + s.misses
        local rate = total > 0 and string.format("%.1f%%", (s.hits / total) * 100) or "n/a"
        lines[#lines + 1] = string.format("  %-24s entries: %d, hits: %d, misses: %d (rate: %s)",
          s.name, s.entries, s.hits, s.misses, rate)
      end
    end
  end

  return lines
end

-- Available vaults (name -> path)
M.vaults = {
  ["Main"] = vim.fn.expand("~/Documents/Obsidian-Vault/Obsidian-Vault"),
  ["Personal"] = vim.fn.expand("~/Desktop/Personal Vault"),
}

-- Active vault (default to Main)
M.vault_path = M.vaults["Main"]

--- Switch to a different vault by name.
---@param name string vault name from M.vaults
function M.switch_vault(name)
  local path = M.vaults[name]
  if not path then
    notify.warn("unknown vault '" .. name .. "'")
    return
  end
  M.vault_path = path

  -- Cancel all pending scheduled work (stale for the old vault)
  require("andrew.vault.work_scheduler").cancel_all()

  -- Invalidate all downstream caches immediately
  M.invalidate_caches({ scope = "all" })

  -- Restart filesystem watcher for the new vault root
  M.start_fs_watcher()

  notify.info("switched to " .. name .. " (" .. path .. ")")
end

--- Show a picker to select and switch vaults.
function M.pick_vault()
  local names = {}
  for name, _ in pairs(M.vaults) do
    names[#names + 1] = name
  end
  table.sort(names)

  M.run(function()
    local choice = M.select(names, { prompt = "Switch vault" })
    if choice then
      M.switch_vault(choice)
    end
  end)
end

--- Run a template function inside a coroutine.
--- The function can call M.input() and M.select() which yield/resume automatically.
---@param fn function
function M.run(fn)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then
    notify.error(tostring(err))
  end
end

--- Create a coroutine-aware wrapper around a vim.ui.* function.
--- The wrapper must be called from within M.run().
--- Uses late binding (looks up the function at call time) so that lazy-loaded
--- overrides like dressing.nvim are picked up even if they load after engine.lua.
---@param ui_field string  field name on vim.ui (e.g. "input" or "select")
---@return function
local function wrap_ui(ui_field)
  return function(...)
    local co = coroutine.running()
    assert(co, "engine UI wrapper must be called within engine.run()")
    local args = { ... }
    args[#args + 1] = function(result)
      vim.schedule(function()
        local ok, err = coroutine.resume(co, result)
        if not ok then
          notify.error(tostring(err))
        end
      end)
    end
    vim.ui[ui_field](unpack(args))
    return coroutine.yield()
  end
end

--- Coroutine-wrapped vim.ui.input. Must be called from within M.run().
---@param opts table {prompt: string}
---@return string|nil value, nil if cancelled
M.input = wrap_ui("input")

--- Coroutine-wrapped vim.ui.select. Must be called from within M.run().
---@param items string[]
---@param opts table {prompt: string, format_item?: function}
---@return string|nil chosen item, nil if cancelled
M.select = wrap_ui("select")

--- Returns today's date in YYYY-MM-DD format
function M.today()
  return os.date("%Y-%m-%d")
end

--- Format a timestamp with unpadded day number.
--- @param prefix_fmt string  strftime prefix (e.g., "%B " or "%A, %B ")
--- @param ts? number  os.time timestamp (default: now)
--- @return string
local function format_date_with_day(prefix_fmt, ts)
  local day_num = tonumber(os.date("%d", ts))
  return os.date(prefix_fmt, ts) .. day_num .. os.date(", %Y", ts)
end

--- Returns date like "February 18, 2026"
function M.today_long()
  return format_date_with_day("%B ")
end

--- Returns date like "Tuesday, February 18, 2026"
function M.today_weekday()
  return format_date_with_day("%A, %B ")
end

--- Returns ISO week number as zero-padded string (e.g., "07")
function M.week_number()
  return os.date("%V")
end

--- Returns YYYY-MM-DD offset by `days` from today (can be negative).
--- Uses os.time table normalization to handle DST correctly.
function M.date_offset(days)
  return M.date_offset_from(M.today(), days)
end

--- Offset an arbitrary date string by N days.
--- @param date_str string  "YYYY-MM-DD" format
--- @param days number  Positive for future, negative for past
--- @return string  "YYYY-MM-DD" format
function M.date_offset_from(date_str, days)
  local ts = date_utils.parse_iso_datetime(date_str, 12)
  if not ts then return date_str end
  return os.date("%Y-%m-%d", ts + days * date_utils.SECS_PER_DAY)
end

--- Format a date string as a long weekday string.
--- e.g., "2026-02-22" -> "Sunday, February 22, 2026"
--- @param date_str string  "YYYY-MM-DD" format
--- @return string
function M.format_weekday(date_str)
  local ts = date_utils.parse_iso_datetime(date_str, 12)
  if not ts then return date_str end
  return format_date_with_day("%A, %B ", ts)
end

-- =============================================================================
-- Re-exports from extracted modules
-- =============================================================================

-- File I/O (engine_file_io.lua)
local file_io = require("andrew.vault.engine_file_io")
file_io.setup(M)
M.ensure_dir = file_io.ensure_dir
M.json_store = file_io.json_store
M.read_file = file_io.read_file
M.write_file = file_io.write_file
M.append_file = file_io.append_file
M.write_note = file_io.write_note

-- Idle-time proactive cache warming (cache_warming.lua)
local ok_warming, cache_warming = pcall(require, "andrew.vault.cache_warming")
if ok_warming then
  cache_warming.setup()
end

-- Template substitution (engine_templates.lua)
local templates = require("andrew.vault.engine_templates")
templates.setup(M)
M.register_var = templates.register_var
M.substitute = templates.substitute

--- Template variable substitution (alias for M.substitute).
--- Supports both {{var}} (Obsidian) and ${var} (legacy) syntax.
--- Also supports {{date:FORMAT}} and {{time:FORMAT}} with Obsidian format strings.
---@param template string
---@param vars table<string, string>
---@return string
function M.render(template, vars)
  return M.substitute(template, vars)
end

-- Filesystem watcher (engine_watcher.lua) — lazy-loaded on first call
M.start_fs_watcher = function(...) return get_watcher().start_fs_watcher(...) end
M.stop_fs_watcher = function(...) return get_watcher().stop_fs_watcher(...) end
M.watcher_status = function(...) return get_watcher().watcher_status(...) end

-- =============================================================================
-- Utility Functions
-- =============================================================================

--- Split an absolute vault path into ordered directory/file segments.
--- Returns nil if path is not inside the vault.
--- @param abs_path string
--- @return string[]|nil  Segments from vault root to filename, or nil
function M.vault_path_segments(abs_path)
  local rel = M.vault_relative(abs_path)
  if not rel or rel == "" then return nil end
  local parts = {}
  for seg in rel:gmatch("[^/]+") do
    parts[#parts + 1] = seg
  end
  if #parts == 0 then return nil end
  return parts
end

--- Check if an absolute path is inside the current vault.
--- @param path string
--- @return boolean
function M.is_vault_path(path)
  return path ~= "" and vim.startswith(path, M.vault_path)
end

-- Memoized bufnr-keyed version of is_vault_path
local memo = require("andrew.vault.memoize")
local _is_vault_check = memo.new(
  function(bufnr)
    -- Version: buffer name + vault_path (both effectively immutable per buffer)
    local name = vim.api.nvim_buf_get_name(bufnr)
    return name .. "|" .. (M.vault_path or "")
  end,
  function(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    return M.is_vault_path(name)
  end,
  "is_vault_buf"
)
memo.register_buf_cleanup(_is_vault_check)

M.register_cache({
  name = "is_vault_buf",
  module = "andrew.vault.engine",
  invalidate = function() _is_vault_check:clear() end,
  stats = function()
    return { entries = _is_vault_check._entry_count }
  end,
})

--- Cached version of is_vault_path for buffer-keyed callers.
---@param bufnr? number  Buffer number (defaults to current)
---@return boolean
function M.is_vault_buf(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return _is_vault_check:get(bufnr)
end

--- Convert an absolute path to a vault-relative path.
--- Returns nil if path is not inside the vault.
--- @param path string
--- @return string|nil
function M.vault_relative(path)
  if not M.is_vault_path(path) then return nil end
  return path:sub(#M.vault_path + 2)
end

--- Get the basename (without extension) of the current buffer.
--- Returns nil if buffer has no name.
--- @return string|nil
function M.current_note_name()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return nil end
  return link_utils.get_basename(bufname)
end

--- Base ripgrep options for vault-wide searches.
--- @param glob? string  File glob pattern (default: "*.md")
--- @return string
function M.rg_base_opts(glob)
  glob = glob or "*.md"
  return '--column --line-number --no-heading --color=always --smart-case --glob "' .. glob .. '"'
end

--- Escape special regex/PCRE2 characters for use in ripgrep patterns.
---@param str string
---@return string
function M.rg_escape(str)
  return str:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\])", "\\%1")
end

--- Common fzf-lua options for vault pickers.
--- @param prompt string  The prompt text (without trailing "> ")
--- @param extra? table   Additional options to merge
--- @return table
function M.vault_fzf_opts(prompt, extra)
  local opts = {
    cwd = M.vault_path,
    prompt = prompt .. "> ",
    file_icons = true,
    git_icons = false,
  }
  if extra then
    for k, v in pairs(extra) do
      opts[k] = v
    end
  end
  return opts
end

--- Standard fzf-lua actions for file open/split/vsplit/tab.
--- @return table
function M.vault_fzf_actions()
  local fzf = require("fzf-lua")
  return {
    ["default"] = fzf.actions.file_edit,
    ["ctrl-s"] = fzf.actions.file_split,
    ["ctrl-v"] = fzf.actions.file_vsplit,
    ["ctrl-t"] = fzf.actions.file_tabedit,
  }
end

-- =============================================================================
-- File Enumeration
-- =============================================================================

local _fd_bin = nil
local _fd_checked = false

--- Detect the best available file-finder binary.
--- @return string|nil  "fd", "fdfind", or nil
function M.fd_bin()
  if not _fd_checked then
    _fd_checked = true
    if vim.fn.executable("fd") == 1 then
      _fd_bin = "fd"
    elseif vim.fn.executable("fdfind") == 1 then
      _fd_bin = "fdfind"
    end
  end
  return _fd_bin
end


-- =============================================================================
-- Name Cache
-- =============================================================================

--- Get or build the vault note name cache.
--- Delegates to vault index when it's ready; returns empty cache otherwise (non-blocking).
--- @return { names: table<string, boolean>, paths: table<string, string> }
function M.get_name_cache()
  local idx = get_vault_index().current()
  if idx and idx:is_ready() then
    return idx:get_name_cache()
  end

  -- Non-blocking: return empty cache, callers handle gracefully
  log.debug("vault index not ready, returning empty name cache")
  return { paths = {}, names = {} }
end

-- =============================================================================
-- Initialization
-- =============================================================================

-- Load persisted URL validation cache on first vault file open
do
  local prewarm_done = false
  vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = "*.md",
    callback = function(ev)
      if prewarm_done then return end
      if M.is_vault_buf(ev.buf) then
        prewarm_done = true
        if config.url_validation.enabled then
          local sched = require("andrew.vault.work_scheduler")
          sched.schedule(sched.DEFERRED, function()
            url_validate.load_cache(M.vault_path)
          end, { domain = "url-validate", label = "load-cache" })
        end
      end
    end,
  })
end

-- VimLeavePre autocmd removed: now dispatched via event_dispatch.lua

--- Called by event_dispatch.lua on VimLeavePre for cleanup.
function M.teardown()
  local profiler = require("andrew.vault.memory_profiler")
  profiler.shutdown()
  if config.url_validation.enabled then
    url_validate.persist_now()
  end

  -- Slot map cleanup (destroy() reports leaks via vim.notify when leak_detect is on)
  local embed_state = require("andrew.vault.embed_state")
  local embed_images = require("andrew.vault.embed_images")
  local hl_coord = require("andrew.vault.highlight_coordinator")
  embed_state._get_slot_map():destroy()
  embed_images._get_slot_map():destroy()
  hl_coord._get_slot_map():destroy()

  vault_log.close()
end

-- Configure the structured logger from config
do
  local log_config = config.log
  vault_log.configure(log_config)
end

-- Configure the per-render arena allocator from config
do
  local render_arena = require("andrew.vault.render_arena")
  render_arena.configure(config.arena)
end

-- Initialize the memory profiler from config
do
  local profiler = require("andrew.vault.memory_profiler")
  profiler.init(config.profiler)
end

-- :VaultLog command — show tail of log file in a scratch buffer
vim.api.nvim_create_user_command("VaultLog", function(cmd)
  local n = tonumber(cmd.args) or 50
  local lines = vault_log.tail(n)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "log"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
end, { nargs = "?", desc = "Show vault log tail (default 50 lines)" })

return M
