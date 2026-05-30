local types = require("andrew.vault.query.types")
local values = require("andrew.vault.query.executor_values")
local results = require("andrew.vault.query.executor_results")
local builtins = require("andrew.vault.query.executor_builtins")

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

--- Generate a type-aware string key for GROUP BY grouping.
--- Prevents collisions between different types (e.g., 1 vs "1" vs true).
---@param val any
---@return string
local function group_key(val)
  if val == nil then
    return "nil:"
  end
  local t = type(val)
  if t == "table" then
    if val.path then
      return "link:" .. val.path
    end
    if val.timestamp then
      return "date:" .. tostring(val:timestamp())
    end
    if val.to_seconds then
      return "dur:" .. tostring(val:to_seconds())
    end
    return "table:" .. tostring(val)
  end
  return t .. ":" .. tostring(val)
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
-- Value helpers (delegated to executor_values)
-- ---------------------------------------------------------------------------

local compare_eq = values.compare_eq
local add_values = values.add_values
local sub_values = values.sub_values
local contains_value = values.contains_value

local builtin_fns = builtins.make_fns({ contains_value = contains_value })

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

  local fn = builtin_fns[name:lower()]
  if fn then
    return fn(unpack(evaluated))
  end
  return nil
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
    local str_key = group_key(val)
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

    -- 5. LIMIT (applied to flat page list before grouping)
    pages = apply_limit(pages, ast)

    -- 6. GROUP BY
    local groups = apply_group_by(pages, ast, current_page)

    -- 7. Result construction
    if ast.type == "TABLE" then
      return results.build_table_results(ast, pages, groups, current_page, eval_expr)
    elseif ast.type == "LIST" then
      return results.build_list_results(ast, pages, groups, current_page, eval_expr)
    elseif ast.type == "TASK" then
      return results.build_task_results(ast, pages, groups, current_page, eval_expr)
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
