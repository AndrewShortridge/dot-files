--- DQL clause helpers: shared parsing patterns for field lists, sort, aliases.

local tokenizer = require("andrew.vault.query.parser.tokenizer")
local TK = tokenizer.TK
local KEYWORDS = tokenizer.KEYWORDS

local M = {}

--- Clause-starting keywords. Used to detect where an optional expression
--- ends (e.g., in LIST queries) or where the field list stops.
M.CLAUSE_KEYWORDS = {
  FROM = true, WHERE = true, SORT = true,
  GROUP = true, FLATTEN = true, LIMIT = true,
}

--- Parse a comma-separated argument list (already past the opening paren).
--- Stops before the closing RPAREN (caller must expect it).
---@param P table            parser state
---@param parse_expr_fn function  expression parser function
---@return table[]|nil args
---@return string|nil error
function M.parse_arg_list(P, parse_expr_fn)
  local args = {}
  if P:peek().type ~= TK.RPAREN then
    local arg, argerr = parse_expr_fn(P)
    if not arg then return nil, argerr end
    args[#args + 1] = arg
    while P:match(TK.COMMA) do
      arg, argerr = parse_expr_fn(P)
      if not arg then return nil, argerr end
      args[#args + 1] = arg
    end
  end
  return args
end

--- Parse an optional AS alias after an expression.
---@param P table  parser state
---@return string|nil alias
---@return string|nil error (only if AS present but alias missing)
function M.parse_optional_alias(P)
  if P:match("AS") then
    local tok = P:peek()
    if tok.type == TK.STRING then
      P:advance()
      return tok.value
    elseif tok.type == TK.IDENT or KEYWORDS[tok.type] then
      P:advance()
      return tok.value
    else
      return nil, P:error("Expected alias name after AS")
    end
  end
  return nil
end

--- Parse an optional sort direction (ASC/DESC). Defaults to "ASC".
---@param P table  parser state
---@return string  "ASC" or "DESC"
function M.parse_direction(P)
  if P:match("ASC") then
    return "ASC"
  elseif P:match("DESC") then
    return "DESC"
  end
  return "ASC"
end

--- Parse a field list for TABLE: field ("," field)*
--- Each field is an expression optionally followed by AS "alias".
---@param P table              parser state
---@param parse_expr_fn function  expression parser function
---@return table[]|nil fields
---@return string|nil error
function M.parse_field_list(P, parse_expr_fn)
  local fields = {}

  local expr, err = parse_expr_fn(P)
  if not expr then return nil, err end
  local alias, alias_err = M.parse_optional_alias(P)
  if alias_err then return nil, alias_err end
  fields[#fields + 1] = { expr = expr, alias = alias }

  while P:match(TK.COMMA) do
    expr, err = parse_expr_fn(P)
    if not expr then return nil, err end
    alias, alias_err = M.parse_optional_alias(P)
    if alias_err then return nil, alias_err end
    fields[#fields + 1] = { expr = expr, alias = alias }
  end

  return fields
end

--- Parse the sort clause body: sort_field ("," sort_field)*
--- sort_field = expression ["ASC"|"DESC"]
---@param P table              parser state
---@param parse_expr_fn function  expression parser function
---@return table[]|nil sorts
---@return string|nil error
function M.parse_sort_fields(P, parse_expr_fn)
  local sorts = {}

  local expr, err = parse_expr_fn(P)
  if not expr then return nil, err end
  sorts[#sorts + 1] = { expr = expr, dir = M.parse_direction(P) }

  while P:match(TK.COMMA) do
    expr, err = parse_expr_fn(P)
    if not expr then return nil, err end
    sorts[#sorts + 1] = { expr = expr, dir = M.parse_direction(P) }
  end

  return sorts
end

return M
