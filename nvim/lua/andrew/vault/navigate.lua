local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

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
  local basename = vim.fn.fnamemodify(bufname, ":t:r")
  return basename:match("(%d%d%d%d%-%d%d%-%d%d)")
end

--- Parse a YYYY-MM-DD string into an os.time timestamp.
---@param date string
---@return number
local function parse_date(date)
  local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
end

--- Compute an adjacent date by adding `offset` days to a YYYY-MM-DD string.
--- Uses os.time table normalization to handle DST correctly.
---@param date string YYYY-MM-DD
---@param offset number days to shift (negative for past)
---@return string YYYY-MM-DD
local function shift_date(date, offset)
  local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
  return os.date("%Y-%m-%d", os.time({
    year = tonumber(y), month = tonumber(m), day = tonumber(d) + offset,
  }))
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
--- Returns a list of absolute file paths.
---@param subtype string the subtype value to search for (e.g. "weekly-review")
---@return string[] paths absolute file paths
local function find_by_subtype(subtype)
  local log_dir = engine.vault_path .. "/" .. config.dirs.log
  if vim.fn.isdirectory(log_dir) == 0 then
    return {}
  end
  local cmd = {
    "rg", "--files-with-matches", "--no-heading", "--glob", "*.md",
    "^subtype:\\s*" .. subtype, log_dir,
  }
  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return result
end

--- Extract a frontmatter field value from a file.
--- Reads only the first 30 lines for efficiency.
---@param filepath string absolute path
---@param field string frontmatter key to extract
---@return string|nil value
local function read_frontmatter_field(filepath, field)
  local f = io.open(filepath, "r")
  if not f then
    return nil
  end
  local in_frontmatter = false
  local count = 0
  for line in f:lines() do
    count = count + 1
    if count > 30 then
      break
    end
    if count == 1 and line == "---" then
      in_frontmatter = true
    elseif in_frontmatter and line == "---" then
      break
    elseif in_frontmatter then
      local key, val = line:match("^(%S+):%s*(.+)$")
      if key == field then
        f:close()
        return val
      end
    end
  end
  f:close()
  return nil
end

--- Build a sorted list of weekly review files with metadata.
--- Each entry is { path = string, week_of = string, basename = string }.
--- Sorted newest first by week_of date (falls back to file mtime).
---@return table[] entries
local function get_weekly_reviews_sorted()
  local files = find_by_subtype("weekly%-review")
  local entries = {}
  for _, fpath in ipairs(files) do
    local week_of = read_frontmatter_field(fpath, "week_of")
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
        basename = vim.fn.fnamemodify(fpath, ":t"),
      }
    end
  end
  table.sort(entries, function(a, b)
    return a.week_of > b.week_of
  end)
  return entries
end

-- =============================================================================
-- Daily Navigation
-- =============================================================================

--- Navigate to the previous day's daily log.
--- If the current buffer is a daily log, goes to the day before it.
--- Otherwise, goes to yesterday from today.
function M.daily_prev()
  local date = current_date() or engine.today()
  open_daily(shift_date(date, -1))
end

--- Navigate to the next day's daily log.
--- If the current buffer is a daily log, goes to the day after it.
--- Otherwise, goes to tomorrow from today.
function M.daily_next()
  local date = current_date() or engine.today()
  open_daily(shift_date(date, 1))
end

--- Open today's daily log, auto-creating from template if it doesn't exist.
function M.daily_today()
  open_daily(engine.today(), true)
end

--- Show all daily logs in fzf-lua picker, sorted newest first.
function M.daily_list()
  local log_dir = engine.vault_path .. "/" .. config.dirs.log
  if vim.fn.isdirectory(log_dir) == 0 then
    vim.notify("Vault: " .. config.dirs.log .. "/ directory not found", vim.log.levels.WARN)
    return
  end

  local entries = vim.fn.readdir(log_dir)
  local logs = {}
  for _, name in ipairs(entries) do
    if name:match("^%d%d%d%d%-%d%d%-%d%d%.md$") then
      logs[#logs + 1] = name
    end
  end

  if #logs == 0 then
    vim.notify("Vault: no daily logs found", vim.log.levels.INFO)
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
  local files = find_by_subtype("weekly%-review")
  if #files == 0 then
    vim.notify("Vault: no weekly reviews found", vim.log.levels.INFO)
    return
  end

  -- Build display entries with week_of dates for sorting
  local entries = {}
  for _, fpath in ipairs(files) do
    local week_of = read_frontmatter_field(fpath, "week_of") or ""
    entries[#entries + 1] = { path = fpath, week_of = week_of, basename = vim.fn.fnamemodify(fpath, ":t") }
  end
  table.sort(entries, function(a, b)
    return a.week_of > b.week_of
  end)

  local display = {}
  local path_map = {}
  for _, e in ipairs(entries) do
    local label = e.basename
    if e.week_of ~= "" then
      label = e.week_of .. "  " .. e.basename
    end
    display[#display + 1] = label
    path_map[label] = e.path
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(display, {
    prompt = "Weekly reviews> ",
    previewer = "builtin",
    actions = {
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
    },
  })
end

--- Navigate to the previous weekly review.
--- If currently in a weekly review, goes to the one before it.
--- Otherwise, goes to the most recent weekly review.
function M.weekly_prev()
  local entries = get_weekly_reviews_sorted()
  if #entries == 0 then
    vim.notify("Vault: no weekly reviews found", vim.log.levels.INFO)
    return
  end

  local bufpath = vim.api.nvim_buf_get_name(0)
  local current_idx = nil
  for i, e in ipairs(entries) do
    if e.path == bufpath then
      current_idx = i
      break
    end
  end

  if current_idx then
    -- Entries are sorted newest first, so "previous" means older = higher index
    local target = current_idx + 1
    if target > #entries then
      vim.notify("Vault: no older weekly review", vim.log.levels.INFO)
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(entries[target].path))
  else
    -- Not in a weekly review; go to the most recent one
    vim.cmd("edit " .. vim.fn.fnameescape(entries[1].path))
  end
end

--- Navigate to the next weekly review.
--- If currently in a weekly review, goes to the one after it.
--- Otherwise, goes to the most recent weekly review.
function M.weekly_next()
  local entries = get_weekly_reviews_sorted()
  if #entries == 0 then
    vim.notify("Vault: no weekly reviews found", vim.log.levels.INFO)
    return
  end

  local bufpath = vim.api.nvim_buf_get_name(0)
  local current_idx = nil
  for i, e in ipairs(entries) do
    if e.path == bufpath then
      current_idx = i
      break
    end
  end

  if current_idx then
    -- Entries are sorted newest first, so "next" means newer = lower index
    local target = current_idx - 1
    if target < 1 then
      vim.notify("Vault: no newer weekly review", vim.log.levels.INFO)
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(entries[target].path))
  else
    -- Not in a weekly review; go to the most recent one
    vim.cmd("edit " .. vim.fn.fnameescape(entries[1].path))
  end
end

-- =============================================================================
-- All Reviews List
-- =============================================================================

--- Show ALL review types (weekly, monthly, quarterly, yearly) in a single fzf-lua picker.
--- Uses ripgrep to find files with subtype matching any review pattern.
function M.review_list()
  local log_dir = engine.vault_path .. "/" .. config.dirs.log
  if vim.fn.isdirectory(log_dir) == 0 then
    vim.notify("Vault: " .. config.dirs.log .. "/ directory not found", vim.log.levels.WARN)
    return
  end

  -- Search for any review subtype in frontmatter
  local cmd = {
    "rg", "--files-with-matches", "--no-heading", "--glob", "*.md",
    "^subtype:\\s*\\S*-review", log_dir,
  }
  local files = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 or #files == 0 then
    vim.notify("Vault: no reviews found", vim.log.levels.INFO)
    return
  end

  -- Build entries with subtype for grouping
  local entries = {}
  for _, fpath in ipairs(files) do
    local subtype = read_frontmatter_field(fpath, "subtype") or "unknown"
    local week_of = read_frontmatter_field(fpath, "week_of") or ""
    local date_field = read_frontmatter_field(fpath, "date") or week_of
    entries[#entries + 1] = {
      path = fpath,
      subtype = subtype,
      date = date_field,
      basename = vim.fn.fnamemodify(fpath, ":t"),
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
    actions = {
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
    },
  })
end

-- =============================================================================
-- Setup
-- =============================================================================

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

  -- -------------------------------------------------------------------------
  -- Filetype-local keybindings for prev/next (daily + weekly)
  -- -------------------------------------------------------------------------
  local group = vim.api.nvim_create_augroup("VaultDailyNav", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
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
    end,
  })
end

return M
