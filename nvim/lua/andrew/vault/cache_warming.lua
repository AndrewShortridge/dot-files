--- Idle-time proactive cache warming for the vault plugin.
--- Schedules IDLE-priority warming tasks via work_scheduler to pre-populate
--- file_cache and connections caches during user idle periods (CursorHold).
---
--- Strategies:
---   A. Completion cache pre-build — already handled by completion_base.lua (DEFERRED)
---   B. Adjacent file pre-read — pre-reads wikilink/embed targets into file_cache
---   C. Connection score pre-compute — pre-computes connection scores for current file
---   D. Code exclusion zone pre-parse — already memoized by link_scan.lua (memo.changedtick)
---   E. Search date context — already cached by search_filter.lua (_date_memo)

local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("cache_warming")
local scheduler = require("andrew.vault.work_scheduler")
local pat = require("andrew.vault.patterns")

local M = {}

-- -----------------------------------------------------------------------
-- Warming Statistics
-- -----------------------------------------------------------------------

local warm_stats = {
  scheduled = 0,
  completed = 0,
  failed = 0,
}

--- Schedule a warming task via work_scheduler IDLE priority.
--- @param label string  Human-readable identifier for logging/debug
--- @param fn fun()      The warming function
function M.schedule_warm(label, fn)
  if not config.cache_warming.enabled then return end

  warm_stats.scheduled = warm_stats.scheduled + 1
  scheduler.schedule(scheduler.IDLE, function()
    local start = vim.uv.hrtime()
    local ok, err = pcall(fn)
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6

    if ok then
      warm_stats.completed = warm_stats.completed + 1
      log.debug("warm completed: %s (%.1fms)", label, elapsed_ms)
    else
      warm_stats.failed = warm_stats.failed + 1
      log.warn("warm failed: %s: %s (%.1fms)", label, tostring(err), elapsed_ms)
    end
  end, { domain = "warming", label = label })
end

--- Cancel all pending warming tasks.
function M.cancel_warming()
  scheduler.cancel_domain("warming")
end

-- -----------------------------------------------------------------------
-- Warming Strategies
-- -----------------------------------------------------------------------

--- Image extension set for fast lookup.
local IMAGE_EXTS = {
  [".png"] = true, [".jpg"] = true, [".jpeg"] = true,
  [".gif"] = true, [".webp"] = true, [".svg"] = true,
  [".bmp"] = true, [".ico"] = true,
}

--- Check if a note part refers to an image file.
--- @param note_part string
--- @return boolean
local function is_image(note_part)
  local ext = note_part:match("%.[^%.]+$")
  return ext and IMAGE_EXTS[ext:lower()] or false
end

--- Strategy B: Pre-read adjacent (linked/embedded) files into file_cache.
--- @param bufnr number
local function warm_adjacent_files(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local vault_path = require("andrew.vault.engine").vault_path
  if not vault_path then return end

  local file_cache = require("andrew.vault.file_cache")
  local vault_index = require("andrew.vault.vault_index")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local targets = {}

  for _, line in ipairs(lines) do
    -- Collect embed targets: ![[...]]
    for inner in line:gmatch(pat.EMBED) do
      local note_part = inner:match("^([^#^]+)")
      if note_part and not is_image(note_part) then
        targets[note_part] = true
      end
    end
    -- Collect link targets: [[...]] (strip aliases and headings)
    for inner in line:gmatch(pat.WIKILINK) do
      if not inner:match("^!") then
        local note_part = inner:match("^([^#|]+)")
        if note_part and #note_part > 0 then
          targets[note_part] = true
        end
      end
    end
  end

  local idx = vault_index.current()
  if not idx then return end

  local warmed = 0
  for name, _ in pairs(targets) do
    -- resolve_name() returns string[]|nil (array of matching absolute paths)
    local paths = idx:resolve_name(name)
    if paths and #paths > 0 then
      -- file_cache.read() handles mtime validation internally;
      -- if the file is already cached and mtime matches, this is a no-op
      local read_lines, _ = file_cache.read(paths[1])
      if read_lines then
        warmed = warmed + 1
      end
    end
    if warmed >= config.cache_warming.max_files_per_warm then
      break
    end
  end

  log.debug("warmed %d adjacent files from buf %d", warmed, bufnr)
end

--- Strategy C: Pre-compute connection scores for current file.
--- @param bufnr number
local function warm_connections(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local abs_path = vim.api.nvim_buf_get_name(bufnr)
  if abs_path == "" then return end

  local vault_path = require("andrew.vault.engine").vault_path
  if not vault_path then return end

  local rel_path = abs_path:sub(#vault_path + 2)
  local connections = require("andrew.vault.connections")

  -- compute() checks its own cache (generation + TTL) and returns early
  -- on hit, so this is safe to call unconditionally.
  local result = connections.compute(rel_path)
  if result then
    log.debug("warmed connection scores for %s (%d results)", rel_path, #result)
  end
end

-- -----------------------------------------------------------------------
-- Buffer Warmup Scheduling
-- -----------------------------------------------------------------------

--- Schedule warming tasks relevant to the current buffer.
--- @param bufnr number
function M.schedule_buffer_warmup(bufnr)
  if not config.cache_warming.enabled then return end

  -- Don't warm while index is building
  local vault_index = package.loaded["andrew.vault.vault_index"]
  if vault_index then
    local idx = vault_index.current()
    if idx and idx:is_building() then
      log.debug("skipping warmup: index is building")
      return
    end
  end

  local strategies = config.cache_warming.strategies

  if strategies.adjacent_files then
    M.schedule_warm("adjacent_files:" .. bufnr, function()
      warm_adjacent_files(bufnr)
    end)
  end

  if strategies.connections then
    M.schedule_warm("connections:" .. bufnr, function()
      warm_connections(bufnr)
    end)
  end
end

-- -----------------------------------------------------------------------
-- Autocmd Setup
-- -----------------------------------------------------------------------

local augroup = nil

function M.setup()
  if not config.cache_warming.enabled then return end
  if augroup then return end

  augroup = vim.api.nvim_create_augroup("VaultCacheWarming", { clear = true })

  -- Aggressive drain on FocusLost (user is away from Neovim)
  vim.api.nvim_create_autocmd("FocusLost", {
    group = augroup,
    callback = function()
      vim.schedule(function()
        local stats = scheduler.stats()
        if stats.pending_idle > 0 then
          scheduler.drain_idle(stats.pending_idle)
        end
      end)
    end,
  })

  -- Cancel warming when user starts active input
  vim.api.nvim_create_autocmd({ "InsertEnter", "CmdlineEnter" }, {
    group = augroup,
    callback = function()
      M.cancel_warming()
    end,
  })

  -- Schedule warming tasks on buffer enter (deferred)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*.md",
    callback = function(ev)
      vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(ev.buf) then return end
        M.schedule_buffer_warmup(ev.buf)
      end, config.cache_warming.idle_delay_ms)
    end,
  })

  -- Re-schedule warming when index changes
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "VaultCacheInvalidate",
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local ft = vim.bo[bufnr].filetype
      if ft == "markdown" then
        M.schedule_buffer_warmup(bufnr)
      end
    end,
  })

  log.info("cache warming enabled")
end

-- -----------------------------------------------------------------------
-- Cache Registry Integration
-- -----------------------------------------------------------------------

local engine = require("andrew.vault.engine")
engine.register_cache({
  name = "warming",
  module = "andrew.vault.cache_warming",
  invalidate = function()
    M.cancel_warming()
    warm_stats = { scheduled = 0, completed = 0, failed = 0 }
  end,
  stats = function()
    return {
      entries = 0, -- warming has no persistent cache; it populates file_cache and connections._cache
    }
  end,
})

-- -----------------------------------------------------------------------
-- Debug
-- -----------------------------------------------------------------------

--- Format bytes for human-readable display.
--- @param bytes number
--- @return string
local function fmt_bytes(bytes)
  if bytes >= 1048576 then
    return string.format("%.1f MB", bytes / 1048576)
  elseif bytes >= 1024 then
    return string.format("%.1f KB", bytes / 1024)
  end
  return string.format("%d B", bytes)
end

--- Get warming statistics for debug display.
--- @return table
function M.stats()
  return {
    scheduled = warm_stats.scheduled,
    completed = warm_stats.completed,
    failed = warm_stats.failed,
    scheduler_stats = scheduler.stats(),
    file_cache_stats = require("andrew.vault.file_cache").stats(),
  }
end

vim.api.nvim_create_user_command("VaultWarmDebug", function()
  local s = M.stats()
  local sched = s.scheduler_stats
  local fc = s.file_cache_stats
  local lines = {
    "Cache Warming Stats",
    "",
    string.format("  Warming:   %d scheduled, %d completed, %d failed",
      s.scheduled, s.completed, s.failed),
    "",
    string.format("  Scheduler: %d pending IDLE, %d total executed",
      sched.pending_idle, sched.executed),
    "",
    string.format("  File cache: %d entries, %d hits, %d misses",
      fc.file_size or 0, fc.hits or 0, fc.misses or 0),
  }
  if fc.hit_rate and fc.hit_rate > 0 then
    table.insert(lines, string.format("  Hit rate:   %.1f%%", fc.hit_rate))
  end
  if fc.file_bytes and fc.file_max_bytes then
    table.insert(lines, string.format("  Bytes:      %s / %s",
      fmt_bytes(fc.file_bytes), fmt_bytes(fc.file_max_bytes)))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.cmd.split()
  vim.api.nvim_set_current_buf(buf)
end, {})

return M
