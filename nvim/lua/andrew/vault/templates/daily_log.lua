local config = require("andrew.vault.config")
local file_cache = require("andrew.vault.file_cache")
local link_utils = require("andrew.vault.link_utils")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")

local M = {}
M.name = "Daily Log"

-- ---------------------------------------------------------------------------
-- Section skip ranges
-- ---------------------------------------------------------------------------

--- Compute line ranges for sections that should be skipped during task extraction.
---@param lines string[]
---@param section_names string[]
---@return table[] ranges { {start=N, stop=N}, ... }
local function compute_skip_ranges(lines, section_names)
  local ranges = {}
  if not section_names or #section_names == 0 then
    return ranges
  end

  local name_set = {}
  for _, name in ipairs(section_names) do
    name_set[name:lower()] = true
  end

  local current_range = nil
  local current_level = nil

  for i, line in ipairs(lines) do
    local level_str, text = line:match(pat.HEADING)
    if level_str then
      local level = #level_str
      local heading_text = vim.trim(text):lower()

      -- Close any open skip range when we hit a same-or-higher-level heading
      if current_range and level <= current_level then
        current_range.stop = i - 1
        ranges[#ranges + 1] = current_range
        current_range = nil
        current_level = nil
      end

      -- Start a new skip range if this heading matches
      if name_set[heading_text] then
        current_range = { start = i }
        current_level = level
      end
    end
  end

  -- Close any range open at EOF
  if current_range then
    current_range.stop = #lines
    ranges[#ranges + 1] = current_range
  end

  return ranges
end

-- ---------------------------------------------------------------------------
-- Task extraction
-- ---------------------------------------------------------------------------

--- Extract incomplete tasks from a daily log file, respecting configuration.
---@param filepath string absolute path to a daily log
---@param opts table carry_forward config
---@return string[] tasks raw lines (preserving indentation for sub-tasks)
local function extract_incomplete_tasks(filepath, opts)
  local tasks = {}
  local lines = file_cache.read(filepath)
  if not lines then
    return tasks
  end

  -- Build section map if skip_sections is configured
  local skip_ranges = compute_skip_ranges(lines, opts.skip_sections)

  -- Track which lines are inside skipped sections
  local function is_skipped(line_num)
    for _, range in ipairs(skip_ranges) do
      if line_num >= range.start and line_num <= range.stop then
        return true
      end
    end
    return false
  end

  -- Determine which task states to carry
  local states = opts.states or { [" "] = true, ["/"] = true }

  -- First pass: identify top-level incomplete tasks
  local task_groups = {}
  local i = 1
  while i <= #lines do
    if not is_skipped(i) then
      local line = lines[i]
      local indent = line:match("^(%s*)") or ""
      local mark = line:match("^%s*[-*] %[(.)%]")

      if mark and states[mark] then
        -- Check for non-empty task text
        local text = line:match("^%s*[-*] %[.%]%s+(.+)")
        if text and text ~= "" then
          local group = { line }

          -- If preserving subtasks, collect indented children
          if opts.preserve_subtasks then
            local base_indent = #indent
            local j = i + 1
            while j <= #lines do
              local child_indent = #(lines[j]:match("^(%s*)") or "")
              if child_indent > base_indent and lines[j]:match("%S") then
                group[#group + 1] = lines[j]
                j = j + 1
              else
                break
              end
            end
          end

          task_groups[#task_groups + 1] = group
        end
      end
    end

    i = i + 1
  end

  -- Flatten groups into output, normalizing top-level indentation
  for _, group in ipairs(task_groups) do
    local base_indent = #(group[1]:match("^(%s*)") or "")
    for _, line in ipairs(group) do
      local current_indent = #(line:match("^(%s*)") or "")
      local relative_indent = current_indent - base_indent
      local stripped = line:gsub("^%s*", "")
      -- Use 2-space indentation for sub-task levels
      local indent_str = ""
      if relative_indent > 0 then
        indent_str = string.rep("  ", math.floor(relative_indent / 2))
        if relative_indent % 2 == 1 then
          indent_str = indent_str .. " "
        end
      end
      tasks[#tasks + 1] = indent_str .. stripped
    end
  end

  return tasks
end

-- ---------------------------------------------------------------------------
-- Carry-forward finder
-- ---------------------------------------------------------------------------

--- Find carry-forward tasks from recent daily logs.
---@param vault_path string absolute vault root
---@param log_dir string relative log directory name
---@param date string YYYY-MM-DD target date
---@param opts table carry_forward config
---@return string[] tasks, string[] source_dates
local function find_carryforward_tasks(vault_path, log_dir, date, opts)
  local dir = vault_path .. "/" .. log_dir
  if vim.fn.isdirectory(dir) == 0 then
    return {}, {}
  end

  -- Collect and sort previous daily log dates
  local entries = {}
  local handle = vim.uv.fs_scandir(dir)
  if handle then
    while true do
      local name, _ = vim.uv.fs_scandir_next(handle)
      if not name then break end
      entries[#entries + 1] = name
    end
  end
  local logs = {}
  for _, name in ipairs(entries) do
    local d = name:match(pat.ISO_DATE_CAPTURE)
    if d and d < date then
      logs[#logs + 1] = d
    end
  end

  if #logs == 0 then
    return {}, {}
  end

  table.sort(logs, function(a, b)
    return a > b
  end)

  -- Scan up to `lookback` previous logs
  local max_logs = math.min(opts.lookback or 1, #logs)
  local all_tasks = {}
  local seen_tasks = {} -- normalized text -> true (deduplication)
  local source_dates = {}

  for idx = 1, max_logs do
    local prev_date = logs[idx]
    local prev_path = dir .. "/" .. prev_date .. ".md"
    local tasks = extract_incomplete_tasks(prev_path, opts)

    local found_new = false
    for _, task in ipairs(tasks) do
      -- Normalize for dedup: strip leading whitespace, lowercase
      local key = task:gsub("^%s+", ""):lower()
      if not seen_tasks[key] then
        seen_tasks[key] = true
        all_tasks[#all_tasks + 1] = task
        found_new = true
      end
    end

    if found_new then
      source_dates[#source_dates + 1] = prev_date
    end
  end

  return all_tasks, source_dates
end

-- ---------------------------------------------------------------------------
-- Generate daily log content
-- ---------------------------------------------------------------------------

--- Generate daily log content for a specific date, with carry-forward.
---@param e table engine module
---@param date string YYYY-MM-DD
---@return string content full markdown content including frontmatter
function M.generate(e, date)
  local yesterday = e.date_offset_from(date, -1)
  local tomorrow = e.date_offset_from(date, 1)
  local weekday_long = e.format_weekday(date)

  local cf_opts = config.carry_forward or {}
  local carry_section = ""

  if cf_opts.enabled ~= false then
    local carried, source_dates = find_carryforward_tasks(
      e.vault_path, config.dirs.log, date, cf_opts
    )

    if #carried > 0 then
      local heading = cf_opts.heading or "### Carried Forward"
      carry_section = heading .. "\n\n"

      -- Build source attribution
      if cf_opts.source_link ~= false and #source_dates > 0 then
        local links = {}
        for _, d in ipairs(source_dates) do
          links[#links + 1] = "[[" .. d .. "]]"
        end
        carry_section = carry_section
          .. "> [!info] Incomplete tasks from "
          .. table.concat(links, ", ") .. "\n\n"
      end

      for _, task in ipairs(carried) do
        carry_section = carry_section .. task .. "\n"
      end
      carry_section = carry_section .. "\n"

      -- Notify if configured
      if cf_opts.notify then
        vim.schedule(function()
          notify.info(
            "carried forward " .. #carried .. " task(s) from "
              .. table.concat(source_dates, ", ")
          )
        end)
      end
    end
  end

  local content = "---\n"
    .. "type: log\n"
    .. "date: " .. date .. "\n"
    .. "tags:\n"
    .. "  - log\n"
    .. "  - daily\n"
    .. "---\n\n"
    .. "<< [[" .. yesterday .. "]] | [[" .. tomorrow .. "]] >>\n\n"
    .. "# " .. weekday_long .. "\n\n"
    .. "---\n\n"
    .. "## Morning Plan\n\n"
    .. carry_section
    .. "### Today's Focus\n\n"
    .. "> [!target] The single biggest task to complete today. Link to its parent project.\n\n"
    .. "- [ ]\n\n"
    .. "### Other Priorities\n\n"
    .. "- [ ]\n"
    .. "- [ ]\n"
    .. "- [ ]\n\n"
    .. "### Tasks Due Today\n\n"
    .. "```dataview\n"
    .. "TASK FROM \"" .. config.dirs.projects .. "\"\n"
    .. "WHERE !completed AND due = date(\"" .. date .. "\")\n"
    .. "SORT priority ASC\n"
    .. "```\n\n"
    .. "---\n\n"
    .. "## Work Log\n\n"
    .. "> Add an entry for each work block. Include the time range, project, and what you did.\n\n"
    .. "- **__:__ - __:__** |\n"
    .. "- **__:__ - __:__** |\n"
    .. "- **__:__ - __:__** |\n\n"
    .. "---\n\n"
    .. "## Scratchpad\n\n"
    .. "> Fleeting thoughts, ideas, links, questions \xE2\x80\x94 anything that comes to mind. Process into proper notes later.\n\n"
    .. "-\n\n"
    .. "---\n\n"
    .. "## End of Day\n\n"
    .. "### Completed Today\n\n"
    .. "- [x]\n\n"
    .. "### Blockers & Open Questions\n\n"
    .. "> [!warning] What's preventing progress? What needs to be resolved?\n\n"
    .. "-\n\n"
    .. "### Reflection\n\n"
    .. "> One thing I learned, one decision I made, or one thing that clicked.\n\n"
    .. "-\n\n"
    .. "### Tomorrow's Priorities\n\n"
    .. "- [ ]\n"
    .. "- [ ]\n"
    .. "- [ ]\n"

  return content
end

-- ---------------------------------------------------------------------------
-- Retroactive carry-forward into existing buffer
-- ---------------------------------------------------------------------------

--- Insert carried-forward tasks into an existing daily log buffer.
--- Finds the "## Morning Plan" heading and inserts after it.
---@param bufnr number buffer number (0 for current)
function M.carry_forward_into_buffer(bufnr)
  bufnr = bufnr or 0
  local engine = require("andrew.vault.engine")

  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  local date = link_utils.get_basename(bufpath):match("(%d%d%d%d%-%d%d%-%d%d)")
  if not date then
    notify.warn("buffer is not a daily log")
    return
  end

  local cf_opts = config.carry_forward or {}
  local carried, source_dates = find_carryforward_tasks(
    engine.vault_path, config.dirs.log, date, cf_opts
  )

  if #carried == 0 then
    notify.info("no tasks to carry forward")
    return
  end

  -- Check if carry-forward section already exists
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local heading = cf_opts.heading or "### Carried Forward"
  for _, line in ipairs(buf_lines) do
    if line:match("^" .. vim.pesc(heading)) then
      notify.warn("carry-forward section already exists")
      return
    end
  end

  -- Find insertion point: after "## Morning Plan" heading
  local insert_line = nil
  for i, line in ipairs(buf_lines) do
    if line:match("^## Morning Plan") then
      insert_line = i -- 0-indexed for nvim API (buf_lines is 1-indexed, nvim API line = i)
      -- Skip blank line after heading
      if buf_lines[i + 1] and buf_lines[i + 1] == "" then
        insert_line = i + 1
      end
      break
    end
  end

  if not insert_line then
    notify.warn("could not find '## Morning Plan' heading")
    return
  end

  -- Build insertion lines
  local insert = { "", heading, "" }
  if cf_opts.source_link ~= false and #source_dates > 0 then
    local links = {}
    for _, d in ipairs(source_dates) do
      links[#links + 1] = "[[" .. d .. "]]"
    end
    insert[#insert + 1] = "> [!info] Incomplete tasks from "
      .. table.concat(links, ", ")
    insert[#insert + 1] = ""
  end
  for _, task in ipairs(carried) do
    insert[#insert + 1] = task
  end
  insert[#insert + 1] = ""

  vim.api.nvim_buf_set_lines(bufnr, insert_line, insert_line, false, insert)
  notify.info("carried forward " .. #carried .. " task(s)")
end

-- ---------------------------------------------------------------------------
-- Template runner
-- ---------------------------------------------------------------------------

function M.run(e, p)
  local date = e.today()
  local content = M.generate(e, date)
  e.write_note(config.dirs.log .. "/" .. date, content)
end

return M
