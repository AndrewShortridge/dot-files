local M = {}
M.name = "Daily Log"

--- Extract incomplete tasks (open or in-progress) from a daily log file.
--- Skips placeholder tasks with no text after the checkbox.
---@param filepath string absolute path to a daily log
---@return string[] tasks normalized to top-level indentation
local function extract_incomplete_tasks(filepath)
  local tasks = {}
  local f = io.open(filepath, "r")
  if not f then
    return tasks
  end
  for line in f:lines() do
    if line:match("^%s*- %[[ /]%]") then
      local text = line:match("^%s*- %[.%]%s+(.+)")
      if text and text ~= "" then
        local mark = line:match("^%s*- %[(.)%]")
        tasks[#tasks + 1] = "- [" .. mark .. "] " .. text
      end
    end
  end
  f:close()
  return tasks
end

--- Find the most recent daily log before `date` and return its incomplete tasks.
---@param vault_path string absolute vault root
---@param log_dir string relative log directory name
---@param date string YYYY-MM-DD target date
---@return string[] tasks, string|nil source_date
local function find_carryforward_tasks(vault_path, log_dir, date)
  local dir = vault_path .. "/" .. log_dir
  if vim.fn.isdirectory(dir) == 0 then
    return {}, nil
  end

  local entries = vim.fn.readdir(dir)
  local logs = {}
  for _, name in ipairs(entries) do
    local d = name:match("^(%d%d%d%d%-%d%d%-%d%d)%.md$")
    if d and d < date then
      logs[#logs + 1] = d
    end
  end

  if #logs == 0 then
    return {}, nil
  end

  table.sort(logs, function(a, b)
    return a > b
  end)
  local prev_date = logs[1]
  local prev_path = dir .. "/" .. prev_date .. ".md"

  return extract_incomplete_tasks(prev_path), prev_date
end

--- Generate daily log content for a specific date, with carry-forward.
---@param e table engine module
---@param date string YYYY-MM-DD
---@return string content full markdown content including frontmatter
function M.generate(e, date)
  local config = require("andrew.vault.config")

  local y, mn, d = date:match("(%d+)-(%d+)-(%d+)")
  y, mn, d = tonumber(y), tonumber(mn), tonumber(d)
  local ts = os.time({ year = y, month = mn, day = d, hour = 12 })
  local yesterday = os.date("%Y-%m-%d", os.time({ year = y, month = mn, day = d - 1, hour = 12 }))
  local tomorrow = os.date("%Y-%m-%d", os.time({ year = y, month = mn, day = d + 1, hour = 12 }))
  local day_num = tonumber(os.date("%d", ts))
  local weekday_long = os.date("%A, %B ", ts) .. day_num .. os.date(", %Y", ts)

  -- Carry forward incomplete tasks from most recent previous daily log
  local carried, source_date = find_carryforward_tasks(e.vault_path, config.dirs.log, date)

  local carry_section = ""
  if #carried > 0 then
    carry_section = "### Carried Forward\n\n"
      .. "> [!info] Incomplete tasks from [[" .. source_date .. "]]\n\n"
    for _, task in ipairs(carried) do
      carry_section = carry_section .. task .. "\n"
    end
    carry_section = carry_section .. "\n"
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
    .. "TASK FROM \"Projects\"\n"
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

function M.run(e, p)
  local date = e.today()
  local content = M.generate(e, date)
  e.write_note("Log/" .. date, content)
end

return M
