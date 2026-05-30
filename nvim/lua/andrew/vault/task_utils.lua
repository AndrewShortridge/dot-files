--- Shared task utilities for vault task UI modules.
--- Provides task iteration, generation-based caching, and checkbox display.
--- @module andrew.vault.task_utils

local vault_index = require("andrew.vault.vault_index")
local gen_cache = require("andrew.vault.gen_cache")

local M = {}

--- Canonical task item fields:
--- @field text string        Task description
--- @field status string      Status mark character (" ", "x", "/", "-", ">")
--- @field due string|nil     Due date (YYYY-MM-DD)
--- @field priority number|nil Priority level
--- @field line number        Source line number
--- @field rel_path string    Relative path from vault root
--- @field abs_path string    Absolute path to source file
--- @field tags string[]|nil  Tag list
--- @field scheduled string|nil  Scheduled date
--- @field completion string|nil Completion date
--- @field repeat_rule string|nil Recurrence rule
---
--- Module-specific derived fields (not shared):
--- @field days_overdue number   (task_notify only)
--- @field children table[]      (task_hierarchy only)
--- @field parent_line number    (task_hierarchy only)

-- ---------------------------------------------------------------------------
-- Task iteration
-- ---------------------------------------------------------------------------

--- Iterate all tasks in the vault index.
--- @param callback fun(task: table, rel_path: string, entry: table): boolean?
---   Return false to stop iteration (optional).
function M.iterate_tasks(callback)
  local idx = vault_index.current()
  if not idx or not idx.files then return end

  for rel_path, entry in pairs(idx:snapshot_files()) do
    if entry.tasks then
      for _, task in ipairs(entry.tasks) do
        if callback(task, rel_path, entry) == false then
          return
        end
      end
    end
  end
end

--- Collect tasks matching a predicate into a flat array.
--- @param predicate fun(task: table, rel_path: string, entry: table): table|nil
---   Return an item table to include it, or nil to skip.
--- @return table[] items
function M.collect_tasks(predicate)
  local items = {}
  M.iterate_tasks(function(task, rel_path, entry)
    local item = predicate(task, rel_path, entry)
    if item then
      items[#items + 1] = item
    end
  end)
  return items
end

-- ---------------------------------------------------------------------------
-- Checkbox display
-- ---------------------------------------------------------------------------

--- Render a task status mark as a display checkbox string.
--- @param status string|nil  The status mark character.
--- @return string  e.g. "[x]", "[ ]", "[/]"
function M.checkbox(status)
  if status == "x" or status == "X" then return "[x]" end
  if status == "/" then return "[/]" end
  if status == "-" then return "[-]" end
  if status == ">" then return "[>]" end
  return "[ ]"
end

-- ---------------------------------------------------------------------------
-- Task line formatting
-- ---------------------------------------------------------------------------

--- Format a task for single-line display.
--- Produces: [indent][checkbox] [text...] [priority] [due]
---
--- @param task table  with .status, .text, and optional .priority, .due
--- @param opts table|nil  {
---   width      = number  (max line width; text is truncated to fit, default 80),
---   indent     = string  (prefix before checkbox, default "    "),
---   show_priority = boolean (append "(PN)" suffix, default true),
---   show_due   = boolean (append due date suffix, default false),
---   reserved   = number  (extra chars to reserve beyond priority/due, default 0),
--- }
--- @return string
function M.format_task_line(task, opts)
  opts = opts or {}
  local indent = opts.indent or "    "
  local width = opts.width or 80
  local show_priority = opts.show_priority ~= false
  local show_due = opts.show_due == true
  local reserved = opts.reserved or 0

  local parts = {}
  parts[#parts + 1] = indent .. M.checkbox(task.status) .. " "

  -- Calculate space taken by suffixes
  local suffix_len = reserved
  local prio_str, due_str
  if show_priority and task.priority then
    prio_str = "  (P" .. task.priority .. ")"
    suffix_len = suffix_len + #prio_str
  end
  if show_due and task.due then
    due_str = "  " .. task.due
    suffix_len = suffix_len + #due_str
  end

  -- Truncate text to remaining space
  local prefix_len = #indent + 4 -- "[x] "
  local text_max = width - prefix_len - suffix_len
  if text_max < 10 then text_max = 10 end

  local truncate = require("andrew.vault.date_utils").truncate
  parts[#parts + 1] = truncate(task.text or "", text_max)

  if prio_str then parts[#parts + 1] = prio_str end
  if due_str then parts[#parts + 1] = due_str end

  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Sort comparators
-- ---------------------------------------------------------------------------

--- Compare tasks by priority (ascending, nil last) then due date (ascending, nil last).
--- @param a table
--- @param b table
--- @return boolean
function M.compare_priority_due(a, b)
  local pa = a.priority or 999
  local pb = b.priority or 999
  if pa ~= pb then return pa < pb end
  local da = a.due or "9999-99-99"
  local db = b.due or "9999-99-99"
  return da < db
end

--- Compare tasks by priority (ascending, nil last) then text (ascending).
--- @param a table
--- @param b table
--- @return boolean
function M.compare_priority_text(a, b)
  local pa = a.priority or 999
  local pb = b.priority or 999
  if pa ~= pb then return pa < pb end
  return (a.text or "") < (b.text or "")
end

-- ---------------------------------------------------------------------------
-- Generation-based cache factory (delegates to gen_cache module)
-- ---------------------------------------------------------------------------

--- Create a generation-based cache.
--- @param build_fn fun(idx: table, ...): any  Builder called on cache miss.
--- @param opts? { key_fn: fun(...): string }  Optional composite key extractor.
--- @return { get: fun(...): any, invalidate: fun() }
M.gen_cache = gen_cache.gen_cache

--- Create a multi-key generation-based cache.
--- Unlike gen_cache which stores one value, this caches multiple keyed entries
--- and invalidates all of them when the vault index generation changes.
--- @param build_fn fun(idx: table, key: string, ...): any  Builder for a single key.
--- @return { get: fun(key: string, ...): any, invalidate: fun() }
M.keyed_gen_cache = gen_cache.keyed_gen_cache

-- ---------------------------------------------------------------------------
-- Task item construction
-- ---------------------------------------------------------------------------

--- Build a task item from raw task data and a raw-tasks-cache entry.
--- Returns a table with all commonly-needed task fields (superset).
--- Callers can add module-specific fields after construction.
---@param task table  Task record from vault index
---@param raw_entry table  Entry from get_raw_tasks() ({ task, rel_path, abs_path })
---@return table item
function M.build_task_item(task, raw_entry)
  return {
    text        = task.text,
    text_lower  = task.text_lower,
    status      = task.status,
    priority    = task.priority,
    due         = task.due,
    scheduled   = task.scheduled,
    completion  = task.completion,
    repeat_rule = task.repeat_rule,
    tags        = task.tags,
    tags_lower  = task.tags_lower,
    rel_path    = raw_entry.rel_path,
    abs_path    = raw_entry.abs_path,
    line        = task.line,
  }
end

-- ---------------------------------------------------------------------------
-- Shared raw task items cache
-- ---------------------------------------------------------------------------

local _raw_tasks_cache = M.gen_cache(function(idx)
  if not idx:is_ready() then return {} end
  return M.collect_tasks(function(task, rel_path, entry)
    return { task = task, rel_path = rel_path, abs_path = entry.abs_path }
  end)
end, {
  partial_fn = function(cached, idx, ctx)
    if not cached then return cached end
    -- Collect all affected relative paths
    local affected = {}
    for _, list in ipairs({ ctx.changed_paths, ctx.deleted_paths }) do
      if list then
        for _, p in ipairs(list) do affected[p] = true end
      end
    end

    -- Remove tasks from affected files
    local new_items = {}
    for _, item in ipairs(cached) do
      if not affected[item.rel_path] then
        new_items[#new_items + 1] = item
      end
    end

    -- Re-collect tasks from changed/added files
    local all_paths = {}
    for _, list in ipairs({ ctx.changed_paths, ctx.added_paths }) do
      if list then
        for _, p in ipairs(list) do all_paths[#all_paths + 1] = p end
      end
    end
    for _, rel_path in ipairs(all_paths) do
      local entry = idx.files[rel_path]
      if entry and entry.tasks then
        for _, task in ipairs(entry.tasks) do
          new_items[#new_items + 1] = { task = task, rel_path = rel_path, abs_path = entry.abs_path }
        end
      end
    end

    return new_items
  end,
})

--- Get all raw task items from vault index (generation-cached).
--- Returns a flat array of { task, rel_path, abs_path }.
---@return table[]
function M.get_raw_tasks()
  return _raw_tasks_cache.get() or {}
end

--- Force-invalidate the shared raw tasks cache.
function M.invalidate_raw_tasks()
  _raw_tasks_cache.invalidate()
end

--- Return cache hit count for profiler.
---@return number
function M.get_cache_hits()
  return _raw_tasks_cache.get_hits()
end

--- Return cache miss count for profiler.
---@return number
function M.get_cache_misses()
  return _raw_tasks_cache.get_misses()
end

return M
