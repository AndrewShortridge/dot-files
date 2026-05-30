local types = require("andrew.vault.query.types")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers (duplicated from executor.lua — tiny, avoids cross-module deps)
-- ---------------------------------------------------------------------------

--- Shallow-copy a table (one level deep).
---@param t table
---@return table
local function shallow_copy(t)
  local copy = {}
  for k, v in pairs(t) do
    copy[k] = v
  end
  return copy
end

--- Derive a human-readable column name from an expression AST node.
---@param expr table
---@return string
local function expr_to_name(expr)
  if expr.type == "field" then
    return table.concat(expr.path, ".")
  elseif expr.type == "call" then
    return expr.name .. "(...)"
  elseif expr.type == "literal" then
    return tostring(expr.value)
  else
    return "value"
  end
end

--- Extract the file link from a page, defaulting to "".
---@param page table
---@return string
local function page_link(page)
  return page.file and page.file.link or ""
end

--- Stringify a group key, defaulting nil to "".
---@param key any
---@return string
local function group_key_str(key)
  return tostring(key or "")
end

-- ---------------------------------------------------------------------------
-- Result construction
-- ---------------------------------------------------------------------------

--- Build table headers from the AST fields.
---@param ast table
---@return table headers
local function build_table_headers(ast)
  local headers = {}
  if not ast.without_id then
    table.insert(headers, "File")
  end
  for _, f in ipairs(ast.fields or {}) do
    table.insert(headers, f.alias or expr_to_name(f.expr))
  end
  return headers
end

--- Build a single table row for a page.
---@param ast table
---@param page table
---@param current_page table|nil
---@param eval_expr_fn function
---@return table row
local function build_table_row(ast, page, current_page, eval_expr_fn)
  local row = {}
  if not ast.without_id then
    table.insert(row, page_link(page))
  end
  for _, f in ipairs(ast.fields or {}) do
    table.insert(row, eval_expr_fn(f.expr, page, current_page))
  end
  return row
end

--- Construct render results for a TABLE query.
---@param ast table
---@param pages table
---@param groups table|nil  from GROUP BY
---@param current_page table|nil
---@param eval_expr_fn function
---@return table results
function M.build_table_results(ast, pages, groups, current_page, eval_expr_fn)
  local headers = build_table_headers(ast)

  if groups then
    local results = {}
    for _, g in ipairs(groups) do
      local rows = {}
      for _, page in ipairs(g.pages) do
        table.insert(rows, build_table_row(ast, page, current_page, eval_expr_fn))
      end
      table.insert(results, {
        type = "table",
        group = group_key_str(g.key),
        headers = headers,
        rows = rows,
      })
    end
    return results
  end

  local rows = {}
  for _, page in ipairs(pages) do
    table.insert(rows, build_table_row(ast, page, current_page, eval_expr_fn))
  end
  return { { type = "table", headers = headers, rows = rows } }
end

--- Construct render results for a LIST query.
---@param ast table
---@param pages table
---@param groups table|nil
---@param current_page table|nil
---@param eval_expr_fn function
---@return table results
function M.build_list_results(ast, pages, groups, current_page, eval_expr_fn)
  local function page_to_item(page)
    if ast.list_expr then
      local val = eval_expr_fn(ast.list_expr, page, current_page)
      if ast.without_id then
        return val
      end
      -- Combine file link with expression value
      local link = page_link(page)
      if val ~= nil then
        return tostring(link) .. ": " .. tostring(val)
      end
      return link
    end
    return page_link(page)
  end

  if groups then
    local results = {}
    for _, g in ipairs(groups) do
      local items = {}
      for _, page in ipairs(g.pages) do
        table.insert(items, page_to_item(page))
      end
      table.insert(results, {
        type = "list",
        group = group_key_str(g.key),
        items = items,
      })
    end
    return results
  end

  local items = {}
  for _, page in ipairs(pages) do
    table.insert(items, page_to_item(page))
  end
  return { { type = "list", items = items } }
end

--- Create a merged context where task fields are overlaid on the page.
--- Task fields shadow page-level fields so that expressions like
--- `completed` or `text` resolve to the task's values.
---@param page table
---@param task table
---@return table merged
local function make_task_context(page, task)
  local ctx = shallow_copy(page)
  -- Overlay task fields at the top level
  for k, v in pairs(task) do
    ctx[k] = v
  end
  return ctx
end

--- Construct render results for a TASK query.
---@param ast table
---@param pages table
---@param groups table|nil
---@param current_page table|nil
---@param eval_expr_fn function
---@return table results
function M.build_task_results(ast, pages, groups, current_page, eval_expr_fn)
  -- For TASK queries, the WHERE clause applies to individual tasks.
  -- We need to iterate pages, then tasks within each page, evaluating
  -- WHERE against a merged task+page context.

  local function collect_tasks_for_page(page)
    local tasks = page.file and page.file.tasks or {}
    local out = {}
    for _, task in ipairs(tasks) do
      if ast.where then
        local ctx = make_task_context(page, task)
        if types.truthy(eval_expr_fn(ast.where, ctx, current_page)) then
          table.insert(out, task)
        end
      else
        table.insert(out, task)
      end
    end
    return out
  end

  if groups then
    -- GROUP BY is present: use group keys as section names
    local result_groups = {}
    for _, g in ipairs(groups) do
      local all_tasks = {}
      for _, page in ipairs(g.pages) do
        local tasks = collect_tasks_for_page(page)
        for _, t in ipairs(tasks) do
          table.insert(all_tasks, t)
        end
      end
      if #all_tasks > 0 then
        table.insert(result_groups, {
          name = group_key_str(g.key),
          tasks = all_tasks,
        })
      end
    end
    return { { type = "task_list", groups = result_groups } }
  end

  -- Default grouping: by file.link
  local group_order = {}
  local group_map = {} -- string key -> { name, tasks }
  for _, page in ipairs(pages) do
    local link = page_link(page)
    local name = tostring(link)
    local tasks = collect_tasks_for_page(page)
    if #tasks > 0 then
      if not group_map[name] then
        group_map[name] = { name = name, tasks = {} }
        table.insert(group_order, name)
      end
      for _, t in ipairs(tasks) do
        table.insert(group_map[name].tasks, t)
      end
    end
  end

  local result_groups = {}
  for _, name in ipairs(group_order) do
    table.insert(result_groups, group_map[name])
  end
  return { { type = "task_list", groups = result_groups } }
end

return M
