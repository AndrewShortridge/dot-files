--- DQL (Dataview Query Language) recursive descent parser.
---
--- Parses Obsidian Dataview queries into an AST suitable for execution
--- against vault metadata. Delegates to submodules for tokenization,
--- parser state, expression parsing, source parsing, and clause helpers.

local tokenizer = require("andrew.vault.query.parser.tokenizer")
local state = require("andrew.vault.query.parser.state")
local expressions = require("andrew.vault.query.parser.expressions")
local source = require("andrew.vault.query.parser.source")
local clauses = require("andrew.vault.query.parser.clauses")

local TK = tokenizer.TK
local parse_expression = expressions.parse_expression
local parse_source = source.parse_source
local CLAUSE_KEYWORDS = clauses.CLAUSE_KEYWORDS

local M = {}

--- Parse a complete DQL query string.
---
--- Returns a Query AST node on success, or nil + error string on failure.
---
--- Example:
---   local ast, err = parser.parse('TABLE file.name FROM "Projects" WHERE status = "active"')
---   if not ast then error(err) end
---
---@param query_string string  the DQL query text
---@return table|nil query     the Query AST node
---@return string|nil error    error message if parsing failed
function M.parse(query_string)
  local tokens, tok_err = tokenizer.tokenize(query_string)
  if not tokens then return nil, tok_err end

  local P = state.new(tokens)
  local err

  local query = {
    without_id = false,
    fields = nil,
    list_expr = nil,
    from = nil,
    where = nil,
    sort = nil,
    group_by = nil,
    flatten = nil,
    limit = nil,
  }

  -- -----------------------------------------------------------------------
  -- Type clause (required)
  -- -----------------------------------------------------------------------
  local type_tok = P:peek()

  if type_tok.type == "TABLE" then
    P:advance()
    query.type = "TABLE"

    -- Optional WITHOUT ID
    if P:peek().type == "WITHOUT" then
      P:advance()
      _, err = P:expect("ID")
      if err then return nil, err end
      query.without_id = true
    end

    -- Field list (required for TABLE, at least one field)
    if not CLAUSE_KEYWORDS[P:peek().type] and P:peek().type ~= TK.EOF then
      local fields
      fields, err = clauses.parse_field_list(P, parse_expression)
      if not fields then return nil, err end
      query.fields = fields
    else
      query.fields = {}
    end

  elseif type_tok.type == "LIST" then
    P:advance()
    query.type = "LIST"

    -- Optional expression after LIST (but not a clause keyword)
    if not CLAUSE_KEYWORDS[P:peek().type] and P:peek().type ~= TK.EOF then
      local expr
      expr, err = parse_expression(P)
      if not expr then return nil, err end
      query.list_expr = expr
    end

  elseif type_tok.type == "TASK" then
    P:advance()
    query.type = "TASK"

  else
    return nil, P:error("Expected TABLE, LIST, or TASK")
  end

  -- -----------------------------------------------------------------------
  -- Optional clauses
  -- -----------------------------------------------------------------------
  while P:peek().type ~= TK.EOF do
    local kw = P:peek().type

    if kw == "FROM" then
      P:advance()
      query.from, err = parse_source(P)
      if not query.from then return nil, err end

    elseif kw == "WHERE" then
      P:advance()
      query.where, err = parse_expression(P)
      if not query.where then return nil, err end

    elseif kw == "SORT" then
      P:advance()
      query.sort, err = clauses.parse_sort_fields(P, parse_expression)
      if not query.sort then return nil, err end

    elseif kw == "GROUP" then
      P:advance()
      _, err = P:expect("BY")
      if err then return nil, err end
      local expr
      expr, err = parse_expression(P)
      if not expr then return nil, err end
      local alias, alias_err = clauses.parse_optional_alias(P)
      if alias_err then return nil, alias_err end
      query.group_by = { expr = expr, alias = alias }

    elseif kw == "FLATTEN" then
      P:advance()
      local expr
      expr, err = parse_expression(P)
      if not expr then return nil, err end
      local alias, alias_err = clauses.parse_optional_alias(P)
      if alias_err then return nil, alias_err end
      query.flatten = { expr = expr, alias = alias }

    elseif kw == "LIMIT" then
      P:advance()
      local tok
      tok, err = P:expect(TK.NUMBER)
      if not tok then return nil, err end
      query.limit = tok.value

    else
      return nil, P:error("Unexpected token '" .. tostring(P:peek().value) .. "'")
    end
  end

  return query
end

--- Parse a standalone expression (for inline DQL like `= this.file.name`).
---
--- Returns an Expr AST node on success, or nil + error string on failure.
---
---@param expr_string string  the expression text (without the leading `=`)
---@return table|nil expr     the Expr AST node
---@return string|nil error   error message if parsing failed
function M.parse_expr(expr_string)
  local tokens, tok_err = tokenizer.tokenize(expr_string)
  if not tokens then return nil, tok_err end

  local P = state.new(tokens)
  local expr, err = parse_expression(P)
  if not expr then return nil, err end

  -- Ensure all input was consumed
  if P:peek().type ~= TK.EOF then
    return nil, P:error("Unexpected token after expression")
  end

  return expr
end

return M
