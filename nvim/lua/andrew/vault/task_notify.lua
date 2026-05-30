local M = {}

local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local date_utils = require("andrew.vault.date_utils")
local task_utils = require("andrew.vault.task_utils")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("task_notify")
local truncate = date_utils.truncate

--- @type number|nil  timestamp of last check
local last_check = nil

--- @type number|nil  timestamp when snooze expires
local snooze_until = nil

--- gen_cache for overdue tasks (generation-based, auto-invalidates on index change)
local _overdue_cache = task_utils.gen_cache(function(idx)
  if not idx:is_ready() then return {} end
  local today = engine.today()
  local all_items = task_utils.get_raw_tasks()
  local tasks = {}
  for _, item in ipairs(all_items) do
    local task = item.task
    if task.due and task.due ~= "" then
      local mark = task.status or " "
      if mark ~= "x" and mark ~= "-" then
        local days = date_utils.days_between(task.due, today)
        if days > 0 then
          local task_item = task_utils.build_task_item(task, item)
          -- Notify-specific defensive defaults and extra field
          task_item.line = task_item.line or 1
          task_item.text = task_item.text or ""
          task_item.status = mark
          task_item.priority = task_item.priority or 99
          task_item.days_overdue = days
          tasks[#tasks + 1] = task_item
        end
      end
    end
  end
  table.sort(tasks, function(a, b)
    if a.days_overdue ~= b.days_overdue then
      return a.days_overdue > b.days_overdue
    end
    return a.priority < b.priority
  end)
  return tasks
end)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Collect overdue tasks from the vault index (via gen_cache).
--- @return number count, table[] tasks
local function find_overdue()
  local tasks = _overdue_cache.get() or {}
  return #tasks, tasks
end

-- ---------------------------------------------------------------------------
-- Notification
-- ---------------------------------------------------------------------------

--- Check for overdue tasks and notify the user.
--- Throttled by `config.task_notify.check_interval` and respects snooze.
local function check_overdue()
  local cfg = config.task_notify or {}
  if cfg.enabled == false then return end

  local now = vim.uv.now() / 1000 -- seconds

  -- Respect snooze
  if snooze_until and now < snooze_until then return end

  -- Throttle checks
  local interval = cfg.check_interval or 300
  if last_check and (now - last_check) < interval then return end
  last_check = now

  local count, tasks = find_overdue()
  if count == 0 then return end

  local style = cfg.style or "detail"
  local detail_limit = cfg.detail_limit or 3

  local lines = {}
  if style == "detail" then
    lines[#lines + 1] = string.format("Overdue tasks: %d", count)
    lines[#lines + 1] = ""
    for i = 1, math.min(count, detail_limit) do
      local t = tasks[i]
      local label = truncate(t.text, 50)
      lines[#lines + 1] = string.format("  [%dd] %s", t.days_overdue, label)
    end
    if count > detail_limit then
      lines[#lines + 1] = string.format("  ... and %d more", count - detail_limit)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Run :VaultOverdue to see all"
  else
    -- "count" style
    lines[#lines + 1] = string.format("You have %d overdue task%s", count, count == 1 and "" or "s")
  end

  notify.info_lines_titled(lines, { title = "Vault" })

  -- Optional system notification via notify-send
  if cfg.system_notify then
    local summary = string.format("%d overdue task%s", count, count == 1 and "" or "s")
    vim.fn.jobstart({
      "notify-send",
      "--app-name=Neovim Vault",
      "--urgency=normal",
      "Vault: Overdue Tasks",
      summary,
    }, { detach = true })
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open an fzf-lua picker listing all overdue tasks.
function M.list_overdue()
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    log.debug("require fzf-lua failed: %s", fzf)
    notify.warn("fzf-lua is required for :VaultOverdue")
    return
  end

  local count, tasks = find_overdue()
  if count == 0 then
    notify.info("no overdue tasks")
    return
  end

  -- Build entries compatible with fzf-lua builtin previewer:
  --   abs_path:line:col:display_text
  local entries = {}
  for _, t in ipairs(tasks) do
    -- Mark label for display
    local label = truncate(t.text, 80)
    local entry = string.format(
      "%s:%d:1:[%dd] - %s %s",
      t.abs_path, t.line, t.days_overdue, task_utils.checkbox(t.status), label
    )
    entries[#entries + 1] = entry
  end

  local fzf_opts = engine.vault_fzf_opts("Overdue Tasks", {
    fzf_opts = {
      ["--no-sort"] = "",
      ["--header"] = string.format("%d overdue task%s", count, count == 1 and "" or "s"),
    },
  })

  fzf.fzf_exec(entries, vim.tbl_deep_extend("force", fzf_opts, {
    previewer = "builtin",
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local entry = selected[1]
        local path, lnum = entry:match("^(.+):(%d+):1:")
        if path and lnum then
          vim.cmd("edit " .. vim.fn.fnameescape(path))
          vim.api.nvim_win_set_cursor(0, { tonumber(lnum), 0 })
        end
      end,
    },
  }))
end

--- Snooze overdue task notifications for the given number of minutes.
--- @param minutes number|nil  defaults to config.task_notify.snooze_minutes (60)
function M.snooze(minutes)
  local cfg = config.task_notify or {}
  minutes = minutes or cfg.snooze_minutes or 60
  snooze_until = (vim.uv.now() / 1000) + (minutes * 60)
  notify.info("overdue task notifications snoozed for " .. minutes .. " minutes")
end

--- Invalidate cached results (called when vault index changes).
function M.invalidate()
  last_check = nil
  _overdue_cache.invalidate()
end

--- Return stats for cache registration.
--- @return table
function M.stats()
  local tasks = _overdue_cache.get() or {}
  return {
    cached_count = #tasks,
    snoozed = snooze_until and (vim.uv.now() / 1000) < snooze_until or false,
  }
end

--- Set up commands, keymaps, and autocmds for overdue task notifications.
function M.setup()
  local cfg = config.task_notify or {}
  if cfg.enabled == false then return end

  local palette = require("andrew.vault.command_palette")

  -- Commands
  vim.api.nvim_create_user_command("VaultOverdue", function()
    M.list_overdue()
  end, { desc = "List overdue vault tasks" })

  vim.api.nvim_create_user_command("VaultOverdueSnooze", function(opts)
    local minutes = tonumber(opts.args)
    M.snooze(minutes)
  end, {
    desc = "Snooze overdue task notifications",
    nargs = "?",
  })

  -- Keymap
  vim.keymap.set("n", "<leader>vxd", function()
    M.list_overdue()
  end, { desc = "Vault: overdue tasks" })

  -- BufEnter autocmd removed: now dispatched via event_dispatch.lua

  -- Register with engine cache system
  engine.register_cache({
    name = "task_notify",
    module = M,
    invalidate = M.invalidate,
    stats = M.stats,
  })

  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "task_notify",
      get_size = function()
        local tasks = _overdue_cache.get()
        return tasks and #tasks or 0
      end,
      get_capacity = function() return nil end,
      get_hits = function() return _overdue_cache.get_hits() end,
      get_misses = function() return _overdue_cache.get_misses() end,
      get_evictions = function() return 0 end,
    })
  end

  -- Palette registrations
  palette.register_command("VaultOverdue", "List overdue vault tasks", "Tasks", M.list_overdue, "<leader>vxd")
  palette.register_command("VaultOverdueSnooze", "Snooze overdue task notifications", "Tasks", M.snooze)
end

--- Called by event_dispatch.lua on BufEnter for vault markdown buffers.
--- @param _ctx { bufnr: number, file: string, is_vault_md: boolean }
function M.on_buf_enter(_ctx)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if idx then
    idx:wait_for_ready(function()
      vim.schedule(function()
        check_overdue()
      end)
    end, "task_notify.overdue")
  end
end

return M
