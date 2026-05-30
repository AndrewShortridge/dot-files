--- DQL expression parser: recursive descent with precedence climbing.
---
--- Parses the full DQL expression grammar including arithmetic,
--- comparisons, boolean logic, function calls, and dotted field access.

local tokenizer = require("andrew.vault.query.parser.tokenizer")
local TK = tokenizer.TK
local KEYWORDS = tokenizer.KEYWORDS
local clauses = require("andrew.vault.query.parser.clauses")

local M = {}

-- Forward declarations: each precedence level is a separate function.
local parse_expression
local parse_or_expr
local parse_and_expr
local parse_not_expr
local parse_comparison
local parse_additive
local parse_multiplicative
local parse_unary
local parse_postfix
local parse_primary

--- expression = or_expr
parse_expression = function(P)
  return parse_or_expr(P)
end

--- or_expr = and_expr ("OR" and_expr)*
parse_or_expr = function(P)
  local left, err = parse_and_expr(P)
  if not left then return nil, err end
  while P:peek().type == "OR" do
    P:advance()
    local right
    right, err = parse_and_expr(P)
    if not right then return nil, err end
    left = { type = "binary", op = "OR", left = left, right = right }
  end
  return left
end

--- and_expr = not_expr ("AND" not_expr)*
parse_and_expr = function(P)
  local left, err = parse_not_expr(P)
  if not left then return nil, err end
  while P:peek().type == "AND" do
    P:advance()
    local right
    right, err = parse_not_expr(P)
    if not right then return nil, err end
    left = { type = "binary", op = "AND", left = left, right = right }
  end
  return left
end

--- not_expr = "!" not_expr | comparison
parse_not_expr = function(P)
  if P:peek().type == TK.BANG or P:peek().type == "NOT" then
    P:advance()
    local operand, err = parse_not_expr(P)
    if not operand then return nil, err end
    return { type = "unary", op = "NOT", operand = operand }
  end
  return parse_comparison(P)
end

--- Comparison operators map from token type to AST op string.
local COMP_OPS = {
  [TK.EQ]  = "=",
  [TK.NEQ] = "!=",
  [TK.LT]  = "<",
  [TK.GT]  = ">",
  [TK.LTE] = "<=",
  [TK.GTE] = ">=",
  CONTAINS = "CONTAINS",
}

--- comparison = additive (comp_op additive)?
parse_comparison = function(P)
  local left, err = parse_additive(P)
  if not left then return nil, err end
  local op = COMP_OPS[P:peek().type]
  if op then
    P:advance()
    local right
    right, err = parse_additive(P)
    if not right then return nil, err end
    left = { type = "binary", op = op, left = left, right = right }
  end
  return left
end

--- additive = multiplicative (("+" | "-") multiplicative)*
parse_additive = function(P)
  local left, err = parse_multiplicative(P)
  if not left then return nil, err end
  while P:peek().type == TK.PLUS or P:peek().type == TK.MINUS do
    local op_tok = P:advance()
    local right
    right, err = parse_multiplicative(P)
    if not right then return nil, err end
    left = { type = "binary", op = op_tok.value, left = left, right = right }
  end
  return left
end

--- multiplicative = unary (("*" | "/") unary)*
parse_multiplicative = function(P)
  local left, err = parse_unary(P)
  if not left then return nil, err end
  while P:peek().type == TK.STAR or P:peek().type == TK.SLASH do
    local op_tok = P:advance()
    local right
    right, err = parse_unary(P)
    if not right then return nil, err end
    left = { type = "binary", op = op_tok.value, left = left, right = right }
  end
  return left
end

--- unary = "-" unary | postfix
parse_unary = function(P)
  if P:peek().type == TK.MINUS then
    P:advance()
    local operand, err = parse_unary(P)
    if not operand then return nil, err end
    return { type = "negate", operand = operand }
  end
  return parse_postfix(P)
end

--- postfix = primary ("." identifier)*
parse_postfix = function(P)
  local node, err = parse_primary(P)
  if not node then return nil, err end

  while P:peek().type == TK.DOT do
    P:advance() -- consume "."

    local seg = P:peek()
    if seg.type == TK.IDENT or KEYWORDS[seg.type] then
      P:advance()
      local name = seg.value

      if node.type == "this" then
        node = { type = "field", path = { name }, this = true }
      elseif node.type == "field" then
        node.path[#node.path + 1] = name
      else
        node = { type = "field", path = { name }, base = node }
      end
    else
      return nil, P:error("Expected field name after '.'")
    end
  end

  return node
end

--- primary = number_literal
---         | string_literal
---         | "true" | "false" | "null"
---         | "this"
---         | identifier "(" [expression ("," expression)*] ")"  -- function call
---         | identifier                                         -- field name
---         | "(" expression ")"                                 -- grouping
parse_primary = function(P)
  local tok = P:peek()

  -- Number literal
  if tok.type == TK.NUMBER then
    P:advance()
    return { type = "literal", value = tok.value }
  end

  -- String literal
  if tok.type == TK.STRING then
    P:advance()
    return { type = "literal", value = tok.value }
  end

  -- Boolean literals
  if tok.type == "TRUE" then
    P:advance()
    return { type = "literal", value = true }
  end
  if tok.type == "FALSE" then
    P:advance()
    return { type = "literal", value = false }
  end

  -- Null literal
  if tok.type == "NULL" then
    P:advance()
    return { type = "literal", value = nil, is_null = true }
  end

  -- `this` keyword
  if tok.type == "THIS" then
    P:advance()
    return { type = "this" }
  end

  -- Identifier: either a field name or a function call
  if tok.type == TK.IDENT then
    P:advance()
    if P:peek().type == TK.LPAREN then
      P:advance() -- consume "("

      -- Special handling for dur()
      if tok.value == "dur" then
        local parts = {}
        while P:peek().type ~= TK.RPAREN and P:peek().type ~= TK.EOF do
          local t = P:advance()
          parts[#parts + 1] = tostring(t.value)
        end
        local _, perr = P:expect(TK.RPAREN)
        if perr then return nil, perr end
        local raw = table.concat(parts, " ")
        return { type = "call", name = "dur", args = { { type = "literal", value = raw } } }
      end

      local args, argerr = clauses.parse_arg_list(P, parse_expression)
      if not args then return nil, argerr end
      local _, perr = P:expect(TK.RPAREN)
      if perr then return nil, perr end
      return { type = "call", name = tok.value, args = args }
    end
    return { type = "field", path = { tok.value } }
  end

  -- Parenthesized expression
  if tok.type == TK.LPAREN then
    P:advance()
    local expr, pexpr_err = parse_expression(P)
    if not expr then return nil, pexpr_err end
    local _, perr = P:expect(TK.RPAREN)
    if perr then return nil, perr end
    return expr
  end

  -- Keywords valid as field names in expression context
  local keyword_as_ident = {
    ID = true, AS = true, ASC = true, DESC = true,
  }
  if keyword_as_ident[tok.type] then
    P:advance()
    if P:peek().type == TK.LPAREN then
      P:advance()
      local args, argerr = clauses.parse_arg_list(P, parse_expression)
      if not args then return nil, argerr end
      local _, perr = P:expect(TK.RPAREN)
      if perr then return nil, perr end
      return { type = "call", name = tok.value, args = args }
    end
    return { type = "field", path = { tok.value } }
  end

  return nil, P:error("Expected expression")
end

M.parse_expression = parse_expression

return M
