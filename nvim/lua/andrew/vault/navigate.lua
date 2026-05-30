local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local fm_parser = require("andrew.vault.frontmatter_parser")
local link_utils = require("andrew.vault.link_utils")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("navigate")
local semaphore = require("andrew.vault.process_semaphore")
local pat = require("andrew.vault.patterns")

local M = {}

local _weekly_cache = { dir_mtime = 0, reviews = nil }

--- Build standard fzf actions table for opening files via edit/split/vsplit.
--- @param path_map table<string, string|nil> mapping from display label to file path
--- @return table actions table suitable for fzf-lua
local function make_file_actions(path_map)
  return {
    ["default"] = function(selected)
      if selected and selected[1] then
        local path = path_map[selected[1]]
        if path then
          vim.cmd("edit " .. vim.fn.fnameescape(path))
        end
      end
    end,
    ["ctrl-s"] = function(selected)
      if selected and selected[1] then
        local path = path_map[selected[1]]
        if path then
          vim.cmd("split " .. vim.fn.fnameescape(path))
        end
      end
    end,
    ["ctrl-v"] = function(selected)
      if selected and selected[1] then
        local path = path_map[selected[1]]
        if path then
          vim.cmd("vsplit " .. vim.fn.fnameescape(path))
        end
      end
    end,
  }
end

local function notify_no_weekly_reviews()
  notify.info("no weekly reviews found")
end

-- =============================================================================
-- Helpers
-- =============================================================================

--- Extract a YYYY-MM-DD date from the current buffer's filename.
--- Returns nil if the buffer name does not contain a date.
---@return string|nil date in YYYY-MM-DD format
local function current_date()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then
    return nil
  end
  local basename = link_utils.get_basename(bufname)
  return basename:match("(%d%d%d%d%-%d%d%-%d%d)")
end

--- Create a daily log for `date` using the template (with carry-forward).
---@param date string YYYY-MM-DD
local function create_daily(date)
  local daily_log = require("andrew.vault.templates.daily_log")
  local content = daily_log.generate(engine, date)
  engine.write_note(config.dirs.log .. "/" .. date, content)
end

--- Open a daily log file. If it does not exist, prompt to create it.
--- When `auto_create` is true, creates without prompting.
---@param date string YYYY-MM-DD
---@param auto_create? boolean
local function open_daily(date, auto_create)
  local path = engine.vault_path .. "/" .. config.dirs.log .. "/" .. date .. ".md"
  if vim.fn.filereadable(path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return
  end

  if auto_create then
    engine.run(function()
      create_daily(date)
    end)
  else
    engine.run(function()
      local choice = engine.select(
        { "Create daily log", "Cancel" },
        { prompt = "No daily log for " .. date }
      )
      if choice == "Create daily log" then
        create_daily(date)
      end
    end)
  end
end

--- Use ripgrep to find vault files whose frontmatter contains a specific subtype.
--- Calls `callback` with a list of absolute file paths (empty list on failure).
---@param subtype string the subtype value to search for (e.g. "weekly-review")
---@param callback fun(paths: string[])
local function find_by_subtype(subtype, callback)
  local log_dir = engine.vault_path .. "/" .. config.dirs.log
  if vim.fn.isdirectory(log_dir) == 0 then
    log.debug("find_by_subtype(%s): directory missing: %s", subtype, log_dir)
    callback({})
    return
  end
  local cmd = {
    "rg", "--files-with-matches", "--no-heading", "--glob", "*.md",
    "^subtype:\\s*" .. subtype, log_dir,
  }
  semaphore.acquire(semaphore.rg_semaphore(), function(release)
    vim.system(cmd, { text = true }, function(result)
      release()
      vim.schedule(function()
        if result.code ~= 0 then
          log.debug("find_by_subtype(%s): ripgrep exited with code %d", subtype, result.code)
          callback({})
          return
        end
        local files = {}
        local stdout = result.stdout or ""
        if stdout ~= "" then
          for line in stdout:gmatch(pat.LINE_NONEMPTY) do
            if line ~= "" then
              files[#files + 1] = line
            end
          end
        end
        callback(files)
      end)
    end)
  end)
end

--- Build a sorted list of weekly review files with metadata.
--- Each entry is { path = string, week_of = string, basename = string }.
--- Sorted newest first by week_of date (falls back to file mtime).
--- Calls `callback` with the sorted entries list.
---@param callback fun(entries: table[])
local function get_weekly_reviews_sorted(callback)
  -- Check directory mtime to decide whether to use cached results
  local log_dir = engine.vault_path .. "/" .. config.dirs.log
  local dir_stat = vim.uv.fs_stat(log_dir)
  local dir_mtime = dir_stat and dir_stat.mtime.sec or 0

  if _weekly_cache.reviews and _weekly_cache.dir_mtime == dir_mtime then
    log.debug("get_weekly_reviews_sorted: using cached results (%d entries)", #_weekly_cache.reviews)
    callback(_weekly_cache.reviews)
    return
  end

  find_by_subtype("weekly%-review", function(files)
    local entries = {}
    for _, fpath in ipairs(files) do
      local week_of = fm_parser.file_field(fpath, "week_of")
      if not week_of then
        -- Fall back to file modification time
        local stat = vim.uv.fs_stat(fpath)
        if stat then
          week_of = os.date("%Y-%m-%d", stat.mtime.sec)
        end
      end
      if week_of then
        entries[#entries + 1] = {
          path = fpath,
          week_of = week_of,
          basename = link_utils.get_tail(fpath),
        }
      end
    end
    table.sort(entries, function(a, b)
      return a.week_of > b.week_of
    end)

    -- Cache the results with current directory mtime
    _weekly_cache.dir_mtime = dir_mtime
    _weekly_cache.reviews = entries
    log.debug("get_weekly_reviews_sorted: rebuilt cache (%d entries, dir_mtime=%d)", #entries, dir_mtime)

    callback(entries)
  end)
end

-- =============================================================================
-- Daily Navigation
-- =============================================================================

--- Navigate to the previous day's daily log.
--- If the current buffer is a daily log, goes to the day before it.
--- Otherwise, goes to yesterday from today.
function M.daily_prev()
  local date = current_date() or engine.today()
  open_daily(engine.date_offset_from(date, -1))
end

--- Navigate to the next day's daily log.
--- If the current buffer is a daily log, goes to the day after it.
--- Otherwise, goes to tomorrow from today.
function M.daily_next()
  local date = current_date() or engine.today()
  open_daily(engine.date_offset_from(date, 1))
end

--- Open today's daily log, auto-creating from template if it doesn't exist.
function M.daily_today()
  open_daily(engine.today(), true)
end

--- Open a daily log by explicit date string, with optional auto-creation.
--- Public wrapper around open_daily() for use by other modules (e.g., temporal aliases).
---@param date string YYYY-MM-DD
---@param auto_create? boolean
function M.open_daily_by_date(date, auto_create)
  open_daily(date, auto_create)
end

--- Show all daily logs in fzf-lua picker, sorted newest first.
function M.daily_list()
  local log_dir = engine.vault_path .. "/" .. config.dirs.log
  if vim.fn.isdirectory(log_dir) == 0 then
    notify.directory_not_found(config.dirs.log)
    return
  end

  local logs = {}
  local handle = vim.uv.fs_scandir(log_dir)
  if handle then
    while true do
      local name, _ = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if name:match(pat.ISO_DATE_MD) then
        logs[#logs + 1] = name
      end
    end
  end

  if #logs == 0 then
    notify.info("no daily logs found")
    return
  end

  -- Sort newest first (reverse lexicographic works for YYYY-MM-DD)
  table.sort(logs, function(a, b)
    return a > b
  end)

  require("fzf-lua").fzf_exec(logs, engine.vault_fzf_opts("Daily logs", {
    cwd = log_dir,
    previewer = "builtin",
    actions = engine.vault_fzf_actions(),
  }))
end

-- =============================================================================
-- Weekly Review Navigation
-- =============================================================================

--- Show all weekly review files in fzf-lua picker, sorted newest first.
function M.weekly_list()
  get_weekly_reviews_sorted(function(entries)
    if #entries == 0 then
      notify_no_weekly_reviews()
      return
    end

    local display = {}
    local path_map = {}
    for _, e in ipairs(entries) do
      local label = e.basename
      if e.week_of and e.week_of ~= "" then
        label = e.week_of .. "  " .. e.basename
      end
      display[#display + 1] = label
      path_map[label] = e.path
    end

    local fzf = require("fzf-lua")
    fzf.fzf_exec(display, {
      prompt = "Weekly reviews> ",
      previewer = "builtin",
      actions = make_file_actions(path_map),
    })
  end)
end

--- Navigate to an adjacent weekly review in the sorted list.
--- Entries are sorted newest first, so direction +1 = older, -1 = newer.
--- If the current buffer is not a weekly review, opens the most recent one.
---@param direction integer +1 for older (prev), -1 for newer (next)
local function navigate_weekly(direction)
  local bufpath = vim.api.nvim_buf_get_name(0)
  get_weekly_reviews_sorted(function(entries)
    if #entries == 0 then
      notify_no_weekly_reviews()
      return
    end

    local current_idx = nil
    for i, e in ipairs(entries) do
      if e.path == bufpath then
        current_idx = i
        break
      end
    end

    if current_idx then
      local target = current_idx + direction
      if target < 1 or target > #entries then
        local msg = direction > 0 and "no older weekly review" or "no newer weekly review"
        notify.info(msg)
        return
      end
      vim.cmd("edit " .. vim.fn.fnameescape(entries[target].path))
    else
      -- Not in a weekly review; go to the most recent one
      vim.cmd("edit " .. vim.fn.fnameescape(entries[1].path))
    end
  end)
end

--- Navigate to the previous weekly review.
--- If currently in a weekly review, goes to the one before it.
--- Otherwise, goes to the most recent weekly review.
function M.weekly_prev()
  navigate_weekly(1)
end

--- Navigate to the next weekly review.
--- If currently in a weekly review, goes to the one after it.
--- Otherwise, goes to the most recent weekly review.
function M.weekly_next()
  navigate_weekly(-1)
end

-- =============================================================================
-- All Reviews List
-- =============================================================================

--- Show ALL review types (weekly, monthly, quarterly, yearly) in a single fzf-lua picker.
--- Uses ripgrep to find files with subtype matching any review pattern.
function M.review_list()
  local log_dir = engine.vault_path .. "/" .. config.dirs.log
  if vim.fn.isdirectory(log_dir) == 0 then
    notify.directory_not_found(config.dirs.log)
    return
  end

  -- Search for any review subtype in frontmatter
  local cmd = {
    "rg", "--files-with-matches", "--no-heading", "--glob", "*.md",
    "^subtype:\\s*\\S*-review", log_dir,
  }
  semaphore.acquire(semaphore.rg_semaphore(), function(release)
    vim.system(cmd, { text = true }, function(result)
      release()
      vim.schedule(function()
        local files = {}
        if result.code == 0 and result.stdout and result.stdout ~= "" then
          for line in result.stdout:gmatch(pat.LINE_NONEMPTY) do
            if line ~= "" then
              files[#files + 1] = line
            end
          end
        end

        if #files == 0 then
          notify.info("no reviews found")
          return
        end

        -- Build entries with subtype for grouping
        local entries = {}
        for _, fpath in ipairs(files) do
          local subtype = fm_parser.file_field(fpath, "subtype") or "unknown"
          local week_of = fm_parser.file_field(fpath, "week_of") or ""
          local date_field = fm_parser.file_field(fpath, "date") or week_of
          entries[#entries + 1] = {
            path = fpath,
            subtype = subtype,
            date = date_field,
            basename = link_utils.get_tail(fpath),
          }
        end

        -- Sort by subtype group (yearly > quarterly > monthly > weekly), then by date newest first
        local type_order = {
          ["yearly-review"] = 1,
          ["quarterly-review"] = 2,
          ["monthly-review"] = 3,
          ["weekly-review"] = 4,
        }
        table.sort(entries, function(a, b)
          local oa = type_order[a.subtype] or 99
          local ob = type_order[b.subtype] or 99
          if oa ~= ob then
            return oa < ob
          end
          return a.date > b.date
        end)

        local display = {}
        local path_map = {}
        local prev_type = nil
        for _, e in ipairs(entries) do
          -- Insert a group header when the subtype changes
          if e.subtype ~= prev_type then
            local header = string.upper(e.subtype:gsub("-", " "))
            display[#display + 1] = "--- " .. header .. " ---"
            path_map["--- " .. header .. " ---"] = nil
            prev_type = e.subtype
          end
          local label = (e.date ~= "" and (e.date .. "  ") or "") .. e.basename
          display[#display + 1] = label
          path_map[label] = e.path
        end

        local fzf = require("fzf-lua")
        fzf.fzf_exec(display, {
          prompt = "All reviews> ",
          previewer = "builtin",
          actions = make_file_actions(path_map),
        })
      end)
    end)
  end)
end

-- =============================================================================
-- Setup
-- =============================================================================

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  -- Daily prev/next
  vim.keymap.set("n", "<leader>v[", function()
    M.daily_prev()
  end, { buffer = ev.buf, desc = "Vault: previous daily log", silent = true })

  vim.keymap.set("n", "<leader>v]", function()
    M.daily_next()
  end, { buffer = ev.buf, desc = "Vault: next daily log", silent = true })

  -- Weekly prev/next
  vim.keymap.set("n", "<leader>v{", function()
    M.weekly_prev()
  end, { buffer = ev.buf, desc = "Vault: previous weekly review", silent = true })

  vim.keymap.set("n", "<leader>v}", function()
    M.weekly_next()
  end, { buffer = ev.buf, desc = "Vault: next weekly review", silent = true })

  -- Calendar
  vim.keymap.set("n", "<leader>vC", function()
    require("andrew.vault.calendar").calendar()
  end, { buffer = ev.buf, desc = "Vault: calendar view", silent = true })

  -- Carry forward tasks
  vim.keymap.set("n", "<leader>vdc", function()
    local daily_log = require("andrew.vault.templates.daily_log")
    daily_log.carry_forward_into_buffer(0)
  end, { buffer = ev.buf, desc = "Vault: carry forward tasks", silent = true })
end

function M.setup()
  -- -------------------------------------------------------------------------
  -- Daily commands
  -- -------------------------------------------------------------------------
  vim.api.nvim_create_user_command("VaultDailyPrev", function()
    M.daily_prev()
  end, { desc = "Navigate to previous daily log" })

  vim.api.nvim_create_user_command("VaultDailyNext", function()
    M.daily_next()
  end, { desc = "Navigate to next daily log" })

  vim.api.nvim_create_user_command("VaultDailyToday", function()
    M.daily_today()
  end, { desc = "Open today's daily log" })

  vim.api.nvim_create_user_command("VaultDailyList", function()
    M.daily_list()
  end, { desc = "List all daily logs" })

  vim.api.nvim_create_user_command("VaultCarryForward", function()
    local daily_log = require("andrew.vault.templates.daily_log")
    daily_log.carry_forward_into_buffer(0)
  end, { desc = "Carry forward incomplete tasks into current daily log" })

  -- -------------------------------------------------------------------------
  -- Weekly review commands
  -- -------------------------------------------------------------------------
  vim.api.nvim_create_user_command("VaultWeeklyList", function()
    M.weekly_list()
  end, { desc = "List all weekly reviews" })

  vim.api.nvim_create_user_command("VaultWeeklyPrev", function()
    M.weekly_prev()
  end, { desc = "Navigate to previous weekly review" })

  vim.api.nvim_create_user_command("VaultWeeklyNext", function()
    M.weekly_next()
  end, { desc = "Navigate to next weekly review" })

  vim.api.nvim_create_user_command("VaultReviewList", function()
    M.review_list()
  end, { desc = "List all reviews (weekly, monthly, quarterly, yearly)" })

  -- -------------------------------------------------------------------------
  -- Calendar command
  -- -------------------------------------------------------------------------
  vim.api.nvim_create_user_command("VaultCalendar", function()
    require("andrew.vault.calendar").calendar()
  end, { desc = "Open calendar view for daily logs" })

  -- -------------------------------------------------------------------------
  -- Global keymaps (find group)
  -- -------------------------------------------------------------------------
  vim.keymap.set("n", "<leader>vfd", function()
    M.daily_list()
  end, { desc = "Find: daily log list", silent = true })

  vim.keymap.set("n", "<leader>vfw", function()
    M.weekly_list()
  end, { desc = "Find: weekly review list", silent = true })

  vim.keymap.set("n", "<leader>vfW", function()
    M.review_list()
  end, { desc = "Find: all reviews list", silent = true })

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  local palette = require("andrew.vault.command_palette")

  palette.register_command("VaultDailyPrev", "Navigate to previous daily log", "Navigate", M.daily_prev, "<leader>v[")
  palette.register_command("VaultDailyNext", "Navigate to next daily log", "Navigate", M.daily_next, "<leader>v]")
  palette.register_command("VaultDailyToday", "Open today's daily log", "Navigate", M.daily_today)
  palette.register_command("VaultDailyList", "List all daily logs", "Navigate", M.daily_list, "<leader>vfd")
  palette.register_command("VaultCarryForward", "Carry forward incomplete tasks into current daily log", "Navigate", function()
    require("andrew.vault.templates.daily_log").carry_forward_into_buffer(0)
  end, "<leader>vdc")
  palette.register_command("VaultWeeklyList", "List all weekly reviews", "Navigate", M.weekly_list, "<leader>vfw")
  palette.register_command("VaultWeeklyPrev", "Navigate to previous weekly review", "Navigate", M.weekly_prev, "<leader>v{")
  palette.register_command("VaultWeeklyNext", "Navigate to next weekly review", "Navigate", M.weekly_next, "<leader>v}")
  palette.register_command("VaultReviewList", "List all reviews (weekly, monthly, quarterly, yearly)", "Navigate", M.review_list, "<leader>vfW")
  palette.register_command("VaultCalendar", "Open calendar view for daily logs", "Navigate", function()
    require("andrew.vault.calendar").calendar()
  end, "<leader>vC")
end

return M
