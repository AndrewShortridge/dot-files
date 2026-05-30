--- Task matching for search filter pipeline.

local M = {}

local config = require("andrew.vault.config")
local date_utils = require("andrew.vault.date_utils")
local match_helpers = require("andrew.vault.search_filter.match_helpers")

local compare_date = match_helpers.compare_date
local compare_num = match_helpers.compare_num
local in_num_range = match_helpers.in_num_range
local tonumber_cached = match_helpers.tonumber_cached
local same_day = date_utils.same_day

--- Cached label_lower -> mark lookup table (invalidated when config changes).
---@type table<string, string>|nil
local _state_map = nil
local _state_map_states = nil

--- Get or build the state label -> mark lookup table.
---@return table<string, string>
local function get_state_map()
  local states = config.task_states
  if _state_map and _state_map_states == states then
    return _state_map
  end
  local map = {}
  for _, s in ipairs(states) do
    map[s.label:lower()] = s.mark
  end
  _state_map = map
  _state_map_states = states
  return map
end

--- Map a task state label to its checkbox character.
---@param label string e.g. "open", "in-progress", "done", "cancelled", "deferred"
---@return string|nil mark single character for checkbox
local function resolve_state_mark(label)
  if not label or label == "" then return nil end
  if #label == 1 then return label end
  return get_state_map()[label:lower()]
end

--- Resolve a date value for task queries.
--- For forward-looking fields (due, scheduled), Nd patterns resolve to
--- N days FROM NOW (future). For backward-looking fields, delegates to
--- date_utils.resolve_date() which resolves Nd to N days AGO.
---@param value string date value string
---@param forward_looking boolean if true, Nd resolves to future
---@return number|nil timestamp
local function resolve_task_date(value, forward_looking)
  if not value or value == "" then return nil end

  if forward_looking then
    local n = value:lower():match("^(%d+)d$")
    if n then
      local t = os.date("*t")
      t.day = t.day + tonumber(n)
      return date_utils.start_of_day(t)
    end
  end

  return date_utils.resolve_date(value)
end

--- Check if any task has a non-nil value for the given metadata field.
---@param field_name string "due", "priority", "repeat", "completion", "scheduled"
---@param tasks table[] VaultTask[]
---@return boolean
local function match_task_meta_exists(field_name, tasks)
  local key = field_name
  if field_name == "repeat" then key = "repeat_rule" end

  for _, task in ipairs(tasks) do
    if task[key] ~= nil then return true end
  end
  return false
end

--- Resolve a task date value, using FilterContext cache with fallback to resolve_task_date().
--- The ctx cache stores results from date_utils.resolve_date(), which resolves Nd as days AGO.
--- For forward-looking fields (due, scheduled), Nd must resolve to days FROM NOW, so we
--- skip the cache for Nd patterns on forward-looking fields and use resolve_task_date().
---@param value string|nil date value
---@param forward_looking boolean true for due/scheduled fields
---@param ctx table|nil FilterContext
---@return number|nil timestamp
local function resolve_task_date_cached(value, forward_looking, ctx)
  if not value or value == "" then return nil end

  -- For forward-looking Nd patterns, resolve_task_date applies different logic
  -- than date_utils.resolve_date (future vs past), so we can't use the ctx cache
  if forward_looking and date_utils.is_relative_duration(value) then
    return resolve_task_date(value, true)
  end

  -- For everything else, the ctx cache (from resolve_date) is correct
  if ctx then
    local cached = ctx.resolved_dates[value]
    if cached ~= nil then return cached or nil end
  end

  return resolve_task_date(value, forward_looking)
end

--- Match a task date field (due, scheduled, completion) against a query.
---@param tasks table[] VaultTask[]
---@param field_name string "due"|"scheduled"|"completion"
---@param op string
---@param value string
---@param value2 string|nil
---@param ctx table|nil FilterContext with pre-resolved values
---@return boolean
local function match_task_date(tasks, field_name, op, value, value2, ctx)
  local forward_looking = (field_name == "due" or field_name == "scheduled")

  for _, task in ipairs(tasks) do
    local date_str = task[field_name]
    if date_str then
      local task_ts = date_utils.parse_iso_datetime(date_str)
      if task_ts then
        if op == "=" then
          local range_match = date_utils.in_keyword_range(task_ts, value)
          if range_match ~= nil then
            if range_match then return true end
            goto next_task
          end
          local filter_ts = resolve_task_date_cached(value, forward_looking, ctx)
          if filter_ts and same_day(task_ts, filter_ts) then return true end
          goto next_task
        end

        if op == ".." then
          local lo = resolve_task_date_cached(value, forward_looking, ctx)
          local hi = resolve_task_date_cached(value2, forward_looking, ctx)
          if lo and hi then
            if date_utils.in_date_range(task_ts, lo, hi) then return true end
          end
          goto next_task
        end

        local filter_ts = resolve_task_date_cached(value, forward_looking, ctx)
        if filter_ts then
          local invert = not forward_looking and date_utils.is_relative_duration(value)
          if compare_date(task_ts, op, filter_ts, value, invert) then return true end
        end
      end
    end
    ::next_task::
  end
  return false
end

--- Match task priority field.
---@param tasks table[] VaultTask[]
---@param op string
---@param value string
---@param value2 string|nil
---@param ctx table|nil FilterContext with pre-resolved values
---@return boolean
local function match_task_priority(tasks, op, value, value2, ctx)
  local num_filter = tonumber_cached(value, ctx)
  if not num_filter then return false end

  for _, task in ipairs(tasks) do
    if task.priority then
      if op == ".." then
        local num_filter2 = tonumber_cached(value2, ctx)
        if num_filter2 and in_num_range(task.priority, num_filter, num_filter2) then
          return true
        end
      elseif compare_num(task.priority, op, num_filter) then
        return true
      end
    end
  end
  return false
end

--- Match task-level tags (distinct from note-level tags).
---@param tasks table[] VaultTask[]
---@param target string tag to match (without #)
---@return boolean
local function match_task_tag(tasks, target)
  if not target or target == "" then return false end
  local lower_target = target:lower()
  local prefix = lower_target .. "/"

  for _, task in ipairs(tasks) do
    if task.tags_lower then
      if task.tags_lower[lower_target] then return true end
      -- Check hierarchical prefix match
      for tag_lower in pairs(task.tags_lower) do
        if tag_lower:sub(1, #prefix) == prefix then
          return true
        end
      end
    end
  end
  return false
end

--- Match task recurrence rules.
---@param tasks table[] VaultTask[]
---@param op string
---@param value string
---@return boolean
local function match_task_repeat(tasks, op, value)
  if op ~= "=" then return false end
  local value_lower = (value and value ~= "") and value:lower() or nil
  for _, task in ipairs(tasks) do
    if task.repeat_rule then
      if not value_lower then return true end
      if task.repeat_rule_lower and task.repeat_rule_lower:find(value_lower, 1, true) then
        return true
      end
    end
  end
  return false
end

--- Evaluate a task-metadata query against a file's task list.
---@param node table task AST node with variant="meta"
---@param tasks table[] VaultTask[]
---@param ctx table|nil FilterContext with pre-resolved values
---@return boolean
local function match_task_meta(node, tasks, ctx)
  local meta_field = node.meta_field
  local op = node.op
  local value = node.value
  local value2 = node.value2

  -- Empty value with = operator means "field exists on any task"
  if op == "=" and (value == nil or value == "") then
    return match_task_meta_exists(meta_field, tasks)
  end

  if meta_field == "due" then
    return match_task_date(tasks, "due", op, value, value2, ctx)
  end

  if meta_field == "scheduled" then
    return match_task_date(tasks, "scheduled", op, value, value2, ctx)
  end

  if meta_field == "completion" then
    return match_task_date(tasks, "completion", op, value, value2, ctx)
  end

  if meta_field == "priority" then
    return match_task_priority(tasks, op, value, value2, ctx)
  end

  if meta_field == "tag" then
    return match_task_tag(tasks, value)
  end

  if meta_field == "repeat" then
    return match_task_repeat(tasks, op, value)
  end

  if meta_field == "state" then
    local target_mark = resolve_state_mark(value)
    if not target_mark then return false end
    for _, task in ipairs(tasks) do
      if task.status == target_mark then return true end
    end
    return false
  end

  return false
end

--- Match a task: node against an entry.
---@param node table task AST node { variant, pattern } or { variant="meta", ... }
---@param entry table VaultIndexEntry
---@param ctx table|nil FilterContext with pre-resolved values
---@return boolean
function M.match_task(node, entry, ctx)
  if not entry.tasks or #entry.tasks == 0 then return false end

  local variant = node.variant
  local pattern = node.pattern
  local has_pattern = pattern and pattern ~= ""

  -- Pre-lower pattern once for all task text matching
  local pattern_lower = has_pattern and pattern:lower() or nil

  if variant == "any" then
    if not has_pattern then return true end
    for _, task in ipairs(entry.tasks) do
      if task.text_lower and task.text_lower:find(pattern_lower, 1, true) then
        return true
      end
    end
    return false
  end

  if variant == "todo" then
    for _, task in ipairs(entry.tasks) do
      if task.status == " " then
        if not has_pattern then return true end
        if task.text_lower and task.text_lower:find(pattern_lower, 1, true) then
          return true
        end
      end
    end
    return false
  end

  if variant == "done" then
    for _, task in ipairs(entry.tasks) do
      if task.completed then
        if not has_pattern then return true end
        if task.text_lower and task.text_lower:find(pattern_lower, 1, true) then
          return true
        end
      end
    end
    return false
  end

  if variant == "meta" then
    return match_task_meta(node, entry.tasks, ctx)
  end

  return false
end

return M
