local types = require("andrew.vault.query.types")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
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

-- ---------------------------------------------------------------------------
-- Value helpers
-- ---------------------------------------------------------------------------

--- Equality comparison that understands Links, Dates, and plain values.
---@param a any
---@param b any
---@return boolean
local function compare_eq(a, b)
  if a == nil and b == nil then
    return true
  end
  if a == nil or b == nil then
    return false
  end
  -- Link comparison: match on path
  if type(a) == "table" and a.path and type(b) == "table" and b.path then
    return a.path == b.path
  end
  -- Date comparison
  if type(a) == "table" and a.timestamp and type(b) == "table" and b.timestamp then
    return a:timestamp() == b:timestamp()
  end
  -- Fall back to string comparison so numbers and strings can coexist
  return tostring(a) == tostring(b)
end

--- Add two values.  Handles string concatenation, number addition, and
--- Date + Duration arithmetic.
---@param a any
---@param b any
---@return any
local function add_values(a, b)
  if type(a) == "string" or type(b) == "string" then
    return tostring(a or "") .. tostring(b or "")
  end
  if type(a) == "table" and a.plus and type(b) == "table" and b.to_seconds then
    return a:plus(b)
  end
  return (tonumber(a) or 0) + (tonumber(b) or 0)
end

--- Subtract two values.  Handles number subtraction, Date - Duration, and
--- Date - Date.
---@param a any
---@param b any
---@return any
local function sub_values(a, b)
  if type(a) == "table" and a.minus then
    return a:minus(b)
  end
  return (tonumber(a) or 0) - (tonumber(b) or 0)
end

--- Check whether container `a` contains value `b`.
--- Works for arrays (element membership, including Link path matching) and
--- strings (substring search).
---@param a any
---@param b any
---@return boolean
local function contains_value(a, b)
  if type(a) == "table" then
    for _, v in ipairs(a) do
      if compare_eq(v, b) then
        return true
      end
    end
    -- Link-aware secondary pass
    for _, v in ipairs(a) do
      if type(v) == "table" and v.path then
        if type(b) == "table" and b.path then
          if v.path == b.path then
            return true
          end
        elseif type(b) == "string" then
          if v.path == b or v.path:match(b) then
            return true
          end
        end
      end
    end
    return false
  elseif type(a) == "string" then
    return a:find(tostring(b or ""), 1, true) ~= nil
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Expression evaluator
-- ---------------------------------------------------------------------------

--- Forward declaration so mutual recursion between eval_expr and
--- eval_function works.
local eval_expr

--- Evaluate a built-in function call.
---@param name string  function name (case-insensitive)
---@param args table   list of argument Expr nodes
---@param page table   current page context
---@param current_page table|nil  the page for `this` references
---@return any
local function eval_function(name, args, page, current_page)
  local evaluated = {}
  for _, arg in ipairs(args) do
    table.insert(evaluated, eval_expr(arg, page, current_page))
  end

  local fns = {
    -- contains(list_or_string, value)
    contains = function(a, b)
      return contains_value(a, b)
    end,

    -- link(path, display?)
    link = function(path, display)
      if type(path) == "table" and path.path then
        return types.Link.new(path.path, tostring(display or path.display), false)
      end
      return types.Link.new(tostring(path or ""), display and tostring(display) or nil, false)
    end,

    -- date(str)
    date = function(str)
      return types.Date.parse(tostring(str or ""))
    end,

    -- dur(str)
    dur = function(str)
      return types.Duration.parse(tostring(str or ""))
    end,

    -- number(val)
    number = function(val)
      return tonumber(val)
    end,

    -- string(val)
    ["string"] = function(val)
      return tostring(val or "")
    end,

    -- length(val)
    length = function(val)
      if type(val) == "string" then
        return #val
      elseif type(val) == "table" then
        return #val
      end
      return 0
    end,

    -- round(num, digits?)
    round = function(num, digits)
      num = tonumber(num) or 0
      digits = tonumber(digits) or 0
      local mult = 10 ^ digits
      return math.floor(num * mult + 0.5) / mult
    end,

    -- min(...)
    min = function(...)
      local vals = { ... }
      if #vals == 0 then
        return nil
      end
      local best = tonumber(vals[1])
      for i = 2, #vals do
        local v = tonumber(vals[i])
        if v and (best == nil or v < best) then
          best = v
        end
      end
      return best
    end,

    -- max(...)
    max = function(...)
      local vals = { ... }
      if #vals == 0 then
        return nil
      end
      local best = tonumber(vals[1])
      for i = 2, #vals do
        local v = tonumber(vals[i])
        if v and (best == nil or v > best) then
          best = v
        end
      end
      return best
    end,

    -- default(val, default_val)
    default = function(val, def)
      if val == nil then
        return def
      end
      return val
    end,

    -- choice(condition, if_true, if_false)
    choice = function(cond, t, f)
      if types.truthy(cond) then
        return t
      end
      return f
    end,

    -- dateformat(date, format?)
    dateformat = function(d, fmt)
      if type(d) == "table" and d.format then
        return d:format(fmt or "%Y-%m-%d")
      end
      return tostring(d or "")
    end,

    -- striptime(date)
    striptime = function(d)
      if type(d) == "table" and d.year then
        return types.Date.new(d.year, d.month, d.day)
      end
      return d
    end,

    -- flat(list) -- flatten nested arrays one level
    flat = function(list)
      if type(list) ~= "table" then
        return list
      end
      local out = {}
      for _, v in ipairs(list) do
        if type(v) == "table" and #v > 0 then
          for _, inner in ipairs(v) do
            table.insert(out, inner)
          end
        else
          table.insert(out, v)
        end
      end
      return out
    end,

    -- reverse(list)
    reverse = function(list)
      if type(list) ~= "table" then
        return list
      end
      local out = {}
      for i = #list, 1, -1 do
        table.insert(out, list[i])
      end
      return out
    end,

    -- sort(list)
    sort = function(list)
      if type(list) ~= "table" then
        return list
      end
      local copy = { unpack(list) }
      table.sort(copy, function(a, b)
        return types.compare(a, b) < 0
      end)
      return copy
    end,

    -- join(list, sep)
    join = function(list, sep)
      if type(list) ~= "table" then
        return tostring(list or "")
      end
      sep = tostring(sep or ", ")
      local strs = {}
      for _, v in ipairs(list) do
        table.insert(strs, tostring(v))
      end
      return table.concat(strs, sep)
    end,

    -- filter(list, fn_name) -- simplified: just returns non-nil/non-false items
    filter = function(list)
      if type(list) ~= "table" then
        return list
      end
      local out = {}
      for _, v in ipairs(list) do
        if types.truthy(v) then
          table.insert(out, v)
        end
      end
      return out
    end,

    -- regexmatch(str, pattern)
    regexmatch = function(str, pattern)
      if type(str) ~= "string" or type(pattern) ~= "string" then
        return false
      end
      return str:match(pattern) ~= nil
    end,

    -- replace(str, pattern, replacement)
    replace = function(str, pattern, replacement)
      if type(str) ~= "string" then
        return str
      end
      return (str:gsub(tostring(pattern or ""), tostring(replacement or "")))
    end,

    -- lower(str)
    lower = function(str)
      return type(str) == "string" and str:lower() or tostring(str or ""):lower()
    end,

    -- upper(str)
    upper = function(str)
      return type(str) == "string" and str:upper() or tostring(str or ""):upper()
    end,

    -- split(str, sep)
    split = function(str, sep)
      if type(str) ~= "string" then
        return {}
      end
      sep = tostring(sep or ",")
      local parts = {}
      for part in str:gmatch("([^" .. sep:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1") .. "]+)") do
        table.insert(parts, part)
      end
      return parts
    end,

    -- sum(list)
    sum = function(list)
      if type(list) ~= "table" then
        return tonumber(list) or 0
      end
      local total = 0
      for _, v in ipairs(list) do
        total = total + (tonumber(v) or 0)
      end
      return total
    end,

    -- average(list)
    average = function(list)
      if type(list) ~= "table" or #list == 0 then
        return 0
      end
      local total = 0
      for _, v in ipairs(list) do
        total = total + (tonumber(v) or 0)
      end
      return total / #list
    end,

    -- typeof(val)
    typeof = function(val)
      return types.typename(val)
    end,

    -- nonnull(list) -- filter out nil values from an array
    nonnull = function(list)
      if type(list) ~= "table" then
        return list
      end
      local out = {}
      for _, v in ipairs(list) do
        if v ~= nil then
          table.insert(out, v)
        end
      end
      return out
    end,

    -- all(list) -- true if all elements are truthy
    all = function(list)
      if type(list) ~= "table" then
        return types.truthy(list)
      end
      for _, v in ipairs(list) do
        if not types.truthy(v) then
          return false
        end
      end
      return true
    end,

    -- any(list) -- true if any element is truthy
    any = function(list)
      if type(list) ~= "table" then
        return types.truthy(list)
      end
      for _, v in ipairs(list) do
        if types.truthy(v) then
          return true
        end
      end
      return false
    end,

    -- none(list) -- true if no elements are truthy
    none = function(list)
      if type(list) ~= "table" then
        return not types.truthy(list)
      end
      for _, v in ipairs(list) do
        if types.truthy(v) then
          return false
        end
      end
      return true
    end,
  }

  local fn = fns[name:lower()]
  if fn then
    return fn(unpack(evaluated))
  end
  return nil -- unknown function
end

--- Evaluate an expression AST node against a page context.
---@param expr table       expression AST node
---@param page table       the page being evaluated
---@param current_page table|nil  the page for `this` references
---@return any
eval_expr = function(expr, page, current_page)
  if expr.type == "literal" then
    if expr.is_null then
      return nil
    end
    return expr.value

  elseif expr.type == "field" then
    local source = expr.this and current_page or page
    local val = source
    for _, key in ipairs(expr.path) do
      if val == nil then
        return nil
      end
      if type(val) == "table" then
        val = val[key]
      else
        return nil
      end
    end
    return val

  elseif expr.type == "this" then
    return current_page

  elseif expr.type == "binary" then
    -- Short-circuit boolean operators
    if expr.op == "AND" then
      local l = eval_expr(expr.left, page, current_page)
      if not types.truthy(l) then
        return false
      end
      return types.truthy(eval_expr(expr.right, page, current_page))
    elseif expr.op == "OR" then
      local l = eval_expr(expr.left, page, current_page)
      if types.truthy(l) then
        return true
      end
      return types.truthy(eval_expr(expr.right, page, current_page))
    end

    local l = eval_expr(expr.left, page, current_page)
    local r = eval_expr(expr.right, page, current_page)

    if expr.op == "=" then
      return compare_eq(l, r)
    elseif expr.op == "!=" then
      return not compare_eq(l, r)
    elseif expr.op == "<" then
      return types.compare(l, r) < 0
    elseif expr.op == ">" then
      return types.compare(l, r) > 0
    elseif expr.op == "<=" then
      return types.compare(l, r) <= 0
    elseif expr.op == ">=" then
      return types.compare(l, r) >= 0
    elseif expr.op == "+" then
      return add_values(l, r)
    elseif expr.op == "-" then
      return sub_values(l, r)
    elseif expr.op == "*" then
      return (tonumber(l) or 0) * (tonumber(r) or 0)
    elseif expr.op == "/" then
      local d = tonumber(r) or 0
      if d == 0 then
        return nil
      end
      return (tonumber(l) or 0) / d
    elseif expr.op == "%" then
      local d = tonumber(r) or 0
      if d == 0 then
        return nil
      end
      return (tonumber(l) or 0) % d
    elseif expr.op == "CONTAINS" then
      return contains_value(l, r)
    end

  elseif expr.type == "unary" then
    local val = eval_expr(expr.operand, page, current_page)
    if expr.op == "NOT" or expr.op == "!" then
      return not types.truthy(val)
    end

  elseif expr.type == "negate" then
    local val = eval_expr(expr.operand, page, current_page)
    return -(tonumber(val) or 0)

  elseif expr.type == "call" then
    return eval_function(expr.name, expr.args, page, current_page)
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Pipeline stages
-- ---------------------------------------------------------------------------

--- Resolve the source pages from the AST and index.
---@param ast table
---@param index table
---@return table pages
local function resolve_source(ast, index)
  if ast.from then
    return index:resolve_source(ast.from)
  end
  return index:all_pages()
end

--- Apply FLATTEN to the page list.
---@param pages table
---@param ast table
---@param current_page table|nil
---@return table
local function apply_flatten(pages, ast, current_page)
  if not ast.flatten then
    return pages
  end
  local flattened = {}
  local key = ast.flatten.alias or expr_to_name(ast.flatten.expr)
  for _, page in ipairs(pages) do
    local val = eval_expr(ast.flatten.expr, page, current_page)
    if type(val) == "table" and #val > 0 then
      for _, item in ipairs(val) do
        local copy = shallow_copy(page)
        copy[key] = item
        table.insert(flattened, copy)
      end
    else
      table.insert(flattened, page)
    end
  end
  return flattened
end

--- Apply WHERE filtering.
---@param pages table
---@param ast table
---@param current_page table|nil
---@return table
local function apply_where(pages, ast, current_page)
  if not ast.where then
    return pages
  end
  local filtered = {}
  for _, page in ipairs(pages) do
    if types.truthy(eval_expr(ast.where, page, current_page)) then
      table.insert(filtered, page)
    end
  end
  return filtered
end

--- Apply SORT.
---@param pages table
---@param ast table
---@param current_page table|nil
---@return table  (sorted in place, also returned for convenience)
local function apply_sort(pages, ast, current_page)
  if not ast.sort then
    return pages
  end
  table.sort(pages, function(a, b)
    for _, s in ipairs(ast.sort) do
      local va = eval_expr(s.expr, a, current_page)
      local vb = eval_expr(s.expr, b, current_page)
      local cmp = types.compare(va, vb)
      if cmp ~= 0 then
        if s.dir == "DESC" then
          return cmp > 0
        end
        return cmp < 0
      end
    end
    return false
  end)
  return pages
end

--- Apply LIMIT.
---@param pages table
---@param ast table
---@return table
local function apply_limit(pages, ast)
  if not ast.limit or #pages <= ast.limit then
    return pages
  end
  local limited = {}
  for i = 1, ast.limit do
    limited[i] = pages[i]
  end
  return limited
end

--- Group pages by a GROUP BY expression.
--- Returns an ordered list of { key = any, pages = {page,...} }.
---@param pages table
---@param ast table
---@param current_page table|nil
---@return table groups  list of { key = any, pages = {page,...} }
local function apply_group_by(pages, ast, current_page)
  if not ast.group_by then
    return nil
  end
  local key_order = {}
  local key_map = {} -- tostring(key) -> { key = any, pages = {} }
  for _, page in ipairs(pages) do
    local val = eval_expr(ast.group_by.expr, page, current_page)
    local str_key = tostring(val or "nil")
    if not key_map[str_key] then
      key_map[str_key] = { key = val, pages = {} }
      table.insert(key_order, str_key)
    end
    table.insert(key_map[str_key].pages, page)
  end
  local groups = {}
  for _, sk in ipairs(key_order) do
    table.insert(groups, key_map[sk])
  end
  return groups
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
---@return table row
local function build_table_row(ast, page, current_page)
  local row = {}
  if not ast.without_id then
    table.insert(row, page.file and page.file.link or "")
  end
  for _, f in ipairs(ast.fields or {}) do
    table.insert(row, eval_expr(f.expr, page, current_page))
  end
  return row
end

--- Construct render results for a TABLE query.
---@param ast table
---@param pages table
---@param groups table|nil  from GROUP BY
---@param current_page table|nil
---@return table results
local function build_table_results(ast, pages, groups, current_page)
  local headers = build_table_headers(ast)

  if groups then
    local results = {}
    for _, g in ipairs(groups) do
      local rows = {}
      for _, page in ipairs(g.pages) do
        table.insert(rows, build_table_row(ast, page, current_page))
      end
      table.insert(results, {
        type = "table",
        group = tostring(g.key or ""),
        headers = headers,
        rows = rows,
      })
    end
    return results
  end

  local rows = {}
  for _, page in ipairs(pages) do
    table.insert(rows, build_table_row(ast, page, current_page))
  end
  return { { type = "table", headers = headers, rows = rows } }
end

--- Construct render results for a LIST query.
---@param ast table
---@param pages table
---@param groups table|nil
---@param current_page table|nil
---@return table results
local function build_list_results(ast, pages, groups, current_page)
  local function page_to_item(page)
    if ast.list_expr then
      local val = eval_expr(ast.list_expr, page, current_page)
      if ast.without_id then
        return val
      end
      -- Combine file link with expression value
      local link = page.file and page.file.link or ""
      if val ~= nil then
        return tostring(link) .. ": " .. tostring(val)
      end
      return link
    end
    return page.file and page.file.link or ""
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
        group = tostring(g.key or ""),
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
---@return table results
local function build_task_results(ast, pages, groups, current_page)
  -- For TASK queries, the WHERE clause applies to individual tasks.
  -- We need to iterate pages, then tasks within each page, evaluating
  -- WHERE against a merged task+page context.

  local function collect_tasks_for_page(page)
    local tasks = page.file and page.file.tasks or {}
    local out = {}
    for _, task in ipairs(tasks) do
      if ast.where then
        local ctx = make_task_context(page, task)
        if types.truthy(eval_expr(ast.where, ctx, current_page)) then
          table.insert(out, {
            text = task.text or "",
            completed = task.completed or false,
          })
        end
      else
        table.insert(out, {
          text = task.text or "",
          completed = task.completed or false,
        })
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
          name = tostring(g.key or ""),
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
    local link = page.file and page.file.link or ""
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

-- ---------------------------------------------------------------------------
-- Main entry point
-- ---------------------------------------------------------------------------

--- Execute a parsed DQL query AST against the vault index.
---
---@param ast table              Query AST from the parser
---@param index table            Index object with :all_pages(), :resolve_source(), :current_page()
---@param current_file_path string  Absolute path of the file containing the query
---@return table results         List of render items
---@return string|nil error      Error message, or nil on success
function M.execute(ast, index, current_file_path)
  -- Validate inputs
  if not ast or not ast.type then
    return {}, "Invalid query AST: missing type"
  end
  if not index then
    return {}, "No index provided"
  end

  local current_page = index:current_page(current_file_path)

  -- Wrap execution in pcall to catch runtime errors gracefully
  local ok, result_or_err = pcall(function()
    -- 1. Source resolution
    local pages = resolve_source(ast, index)

    -- 2. FLATTEN (before WHERE)
    pages = apply_flatten(pages, ast, current_page)

    -- 3. WHERE filtering
    -- For TASK queries the WHERE is applied per-task later, not here.
    if ast.type ~= "TASK" then
      pages = apply_where(pages, ast, current_page)
    end

    -- 4. SORT
    pages = apply_sort(pages, ast, current_page)

    -- 5. GROUP BY
    local groups = apply_group_by(pages, ast, current_page)

    -- 6. LIMIT (applied to the flat page list, before grouping renders)
    if not groups then
      pages = apply_limit(pages, ast)
    end

    -- 7. Result construction
    if ast.type == "TABLE" then
      return build_table_results(ast, pages, groups, current_page)
    elseif ast.type == "LIST" then
      return build_list_results(ast, pages, groups, current_page)
    elseif ast.type == "TASK" then
      return build_task_results(ast, pages, groups, current_page)
    else
      return { { type = "error", message = "Unknown query type: " .. tostring(ast.type) } }
    end
  end)

  if not ok then
    return { { type = "error", message = tostring(result_or_err) } }, tostring(result_or_err)
  end

  return result_or_err, nil
end

return M
