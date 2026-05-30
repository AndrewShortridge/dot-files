local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("tasks")
local task_utils = require("andrew.vault.task_utils")
local pat = require("andrew.vault.patterns")

local M = {}

-- ============================================================================
-- Task Status Cycling
-- ============================================================================

--- Pattern matching a task checkbox line: prefix, mark character, suffix.
M.CHECKBOX_PATTERN = pat.TASK_CHECKBOX

--- Apply completion metadata transformation to a task line suffix.
--- Adds `[completion:: YYYY-MM-DD]` when transitioning to `x`, strips it otherwise.
---@param suffix string The part after the mark (e.g., "] task text [due:: ...]")
---@param old_mark string Current checkbox mark
---@param new_mark string Target checkbox mark
---@return string transformed suffix
function M.apply_completion_meta(suffix, old_mark, new_mark)
  if new_mark == "x" and old_mark ~= "x" then
    suffix = suffix:gsub("%s*%[completion::%s*[^%]]*%]", "")
    suffix = suffix .. " [completion:: " .. engine.today() .. "]"
  elseif new_mark ~= "x" and old_mark == "x" then
    suffix = suffix:gsub("%s*%[completion::%s*[^%]]*%]", "")
  end
  return suffix
end

local ns_flash = vim.api.nvim_create_namespace("vault_task_flash")

--- Cached label lookup: mark -> label (invalidated when task_states changes).
local _label_map = nil
local _label_map_states = nil

--- Get or build the mark -> label lookup table.
---@return table<string, string>
local function get_label_map()
  local states = config.task_states
  if _label_map and _label_map_states == states then
    return _label_map
  end
  local map = {}
  for _, s in ipairs(states) do
    map[s.mark] = s.label
  end
  _label_map = map
  _label_map_states = states
  return map
end


--- Build forward and reverse lookup tables from config.task_states.
--- Cached; invalidated when config.task_states reference changes.
local _cycle_fwd, _cycle_rev, _cycle_states

---@return table forward, table reverse
local function build_cycle_maps()
  local states = config.task_states
  if _cycle_fwd and _cycle_states == states then
    return _cycle_fwd, _cycle_rev
  end
  local marks = {}
  for _, s in ipairs(states) do
    marks[#marks + 1] = s.mark
  end
  local fwd = {}
  local rev = {}
  for i, v in ipairs(marks) do
    fwd[v] = marks[i % #marks + 1]
    rev[v] = marks[(i - 2) % #marks + 1]
  end
  _cycle_fwd, _cycle_rev, _cycle_states = fwd, rev, states
  return fwd, rev
end

--- Show a brief virtual text flash indicating the state transition.
---@param bufnr number
---@param line_nr number 1-indexed
---@param old_mark string
---@param new_mark string
local function flash_transition(bufnr, line_nr, old_mark, new_mark)
  local label_map = get_label_map()
  local msg = string.format("[%s] %s -> [%s] %s",
    old_mark, label_map[old_mark] or "?",
    new_mark, label_map[new_mark] or "?")

  -- Clear any previous flash extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, ns_flash, 0, -1)

  local id = vim.api.nvim_buf_set_extmark(bufnr, ns_flash, line_nr - 1, 0, {
    virt_text = { { "  " .. msg, "DiagnosticHint" } },
    virt_text_pos = "eol",
  })
  vim.defer_fn(function()
    local ok, err = pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_flash, id)
    if not ok then log.debug("failed to delete flash extmark %d: %s", id, err) end
  end, 1500)
end

--- Cycle the task checkbox state on the current cursor line.
--- Handles completion metadata, recurrence, and visual feedback.
---@param direction? "forward"|"backward"  Default: "forward"
---@return boolean true if a task was cycled, false otherwise
function M.cycle_task(direction)
  direction = direction or "forward"
  local fwd, rev = build_cycle_maps()
  local cycle_map = direction == "backward" and rev or fwd

  local bufnr = vim.api.nvim_get_current_buf()
  local line_nr = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, line_nr - 1, line_nr, false)[1]
  if not line then
    return false
  end

  local prefix, mark, rest = line:match(M.CHECKBOX_PATTERN)
  if not prefix then
    notify.warn("no task checkbox on current line")
    return false
  end

  local new_mark = cycle_map[mark]
  if not new_mark then
    -- Unknown mark, fall back to first state
    new_mark = config.task_states[1] and config.task_states[1].mark or " "
  end

  -- Handle completion metadata
  rest = M.apply_completion_meta(rest, mark, new_mark)

  -- Apply the change
  vim.api.nvim_buf_set_lines(bufnr, line_nr - 1, line_nr, false, {
    prefix .. new_mark .. rest,
  })

  -- Handle recurrence when completing a task
  if new_mark == "x" then
    local recurrence = require("andrew.vault.recurrence")
    local created = recurrence.handle_recurrence(line_nr)
    if created then
      -- The new recurring task was inserted above, so our completed task
      -- is now at line_nr + 1. Adjust cursor to stay on the completed task.
      vim.api.nvim_win_set_cursor(0, { line_nr + 1, vim.api.nvim_win_get_cursor(0)[2] })
      line_nr = line_nr + 1
    end
  end

  -- Visual feedback
  flash_transition(bufnr, line_nr, mark, new_mark)

  return true
end

--- Collect tasks from the vault index matching an optional filter predicate.
---@param prompt string fzf prompt label
---@param filter? fun(task: table): boolean predicate (default: accept all)
local function index_tasks(prompt, filter)
  local fzf = require("fzf-lua")
  local all = task_utils.get_raw_tasks()

  if not all then
    notify.warn("vault index not available")
    return
  end

  local entries = {}
  for _, item in ipairs(all) do
    if not filter or filter(item.task) then
      entries[#entries + 1] = string.format("%s:%d:1:- [%s] %s",
        item.abs_path, item.task.line, item.task.status, item.task.text)
    end
  end

  table.sort(entries)

  if #entries == 0 then
    notify.info("no matching tasks found")
    return
  end

  fzf.fzf_exec(entries, vim.tbl_extend("force",
    engine.vault_fzf_opts(prompt),
    { previewer = "builtin" }
  ))
end

--- Collect all open tasks (- [ ]) across the vault and show in fzf-lua.
function M.tasks()
  M.tasks_by_state(" ")
end

--- Collect tasks matching a specific checkbox state.
---@param mark string single char: " ", "/", "x", "-", ">"
function M.tasks_by_state(mark)
  index_tasks("Vault tasks [" .. mark .. "]", function(task)
    return task.status == mark
  end)
end

--- Show all tasks regardless of state.
function M.tasks_all()
  index_tasks("Vault tasks (all)")
end

engine.register_cache({
  name = "tasks",
  module = "andrew.vault.tasks",
  invalidate = function()
    task_utils.invalidate_raw_tasks()
  end,
})

do
  local profiler = require("andrew.vault.memory_profiler")
  profiler.register_cache({
    name = "tasks",
    get_size = function()
      local tasks = task_utils.get_raw_tasks()
      return tasks and #tasks or 0
    end,
    get_capacity = function() return nil end,
    get_hits = function() return task_utils.get_cache_hits() end,
    get_misses = function() return task_utils.get_cache_misses() end,
    get_evictions = function() return 0 end, -- gen_cache; no eviction
  })
end

return M
