--- DQL (Dataview Query Language) recursive descent parser.
---
--- Parses Obsidian Dataview queries into an AST suitable for execution
--- against vault metadata. Implements the full DQL grammar including
--- TABLE/LIST/TASK queries, FROM source filters, WHERE expressions,
--- SORT/GROUP BY/FLATTEN/LIMIT clauses, and a full expression language
--- with arithmetic, comparisons, boolean logic, function calls, and
--- dotted field access.

local M = {}

-- =============================================================================
-- Token types
-- =============================================================================

local TK = {
  -- Literals and identifiers
  STRING = "STRING",
  NUMBER = "NUMBER",
  IDENT = "IDENT",

  -- Punctuation
  DOT = "DOT",
  COMMA = "COMMA",
  LPAREN = "LPAREN",
  RPAREN = "RPAREN",
  BANG = "BANG",
  HASH = "HASH",
  SLASH = "SLASH",
  PLUS = "PLUS",
  MINUS = "MINUS",
  STAR = "STAR",

  -- Comparison operators
  EQ = "EQ",
  NEQ = "NEQ",
  LT = "LT",
  GT = "GT",
  LTE = "LTE",
  GTE = "GTE",

  -- End of input
  EOF = "EOF",
}

--- Keywords recognized by the tokenizer. Stored uppercase for
--- case-insensitive matching. When a scanned identifier matches one of
--- these (after uppercasing), the token type becomes that keyword string.
local KEYWORDS = {
  TABLE = true, LIST = true, TASK = true,
  FROM = true, WHERE = true, SORT = true,
  GROUP = true, BY = true, FLATTEN = true, LIMIT = true,
  AS = true, ASC = true, DESC = true,
  WITHOUT = true, ID = true,
  AND = true, OR = true, NOT = true,
  CONTAINS = true,
  TRUE = true, FALSE = true, NULL = true,
  THIS = true,
}

-- =============================================================================
-- Tokenizer
-- =============================================================================

--- Create a token table.
---@param type string   token type from TK or a keyword string
---@param value any     semantic value (string text, number, etc.)
---@param pos  number   1-based byte offset in the source where the token starts
---@return table
local function token(type, value, pos)
  return { type = type, value = value, pos = pos }
end

--- Tokenize a DQL query string into a flat list of tokens.
---@param src string  the raw query text
---@return table[]    list of tokens, always ending with an EOF token
---@return string|nil error message on failure
local function tokenize(src)
  local tokens = {}
  local i = 1
  local len = #src

  --- Skip whitespace and advance `i`.
  local function skip_ws()
    while i <= len do
      local ch = src:byte(i)
      -- space, tab, newline, carriage return
      if ch == 32 or ch == 9 or ch == 10 or ch == 13 then
        i = i + 1
      else
        break
      end
    end
  end

  while true do
    skip_ws()
    if i > len then
      tokens[#tokens + 1] = token(TK.EOF, nil, i)
      break
    end

    local start = i
    local ch = src:sub(i, i)
    local byte = ch:byte()

    -- -----------------------------------------------------------------
    -- Single-character punctuation
    -- -----------------------------------------------------------------
    if ch == "." then
      tokens[#tokens + 1] = token(TK.DOT, ".", start)
      i = i + 1
    elseif ch == "," then
      tokens[#tokens + 1] = token(TK.COMMA, ",", start)
      i = i + 1
    elseif ch == "(" then
      tokens[#tokens + 1] = token(TK.LPAREN, "(", start)
      i = i + 1
    elseif ch == ")" then
      tokens[#tokens + 1] = token(TK.RPAREN, ")", start)
      i = i + 1
    elseif ch == "#" then
      tokens[#tokens + 1] = token(TK.HASH, "#", start)
      i = i + 1
    elseif ch == "/" then
      tokens[#tokens + 1] = token(TK.SLASH, "/", start)
      i = i + 1
    elseif ch == "+" then
      tokens[#tokens + 1] = token(TK.PLUS, "+", start)
      i = i + 1
    elseif ch == "-" then
      tokens[#tokens + 1] = token(TK.MINUS, "-", start)
      i = i + 1
    elseif ch == "*" then
      tokens[#tokens + 1] = token(TK.STAR, "*", start)
      i = i + 1

    -- -----------------------------------------------------------------
    -- Multi-character operators
    -- -----------------------------------------------------------------
    elseif ch == "!" then
      if i + 1 <= len and src:sub(i + 1, i + 1) == "=" then
        tokens[#tokens + 1] = token(TK.NEQ, "!=", start)
        i = i + 2
      else
        tokens[#tokens + 1] = token(TK.BANG, "!", start)
        i = i + 1
      end
    elseif ch == "=" then
      tokens[#tokens + 1] = token(TK.EQ, "=", start)
      i = i + 1
    elseif ch == "<" then
      if i + 1 <= len and src:sub(i + 1, i + 1) == "=" then
        tokens[#tokens + 1] = token(TK.LTE, "<=", start)
        i = i + 2
      else
        tokens[#tokens + 1] = token(TK.LT, "<", start)
        i = i + 1
      end
    elseif ch == ">" then
      if i + 1 <= len and src:sub(i + 1, i + 1) == "=" then
        tokens[#tokens + 1] = token(TK.GTE, ">=", start)
        i = i + 2
      else
        tokens[#tokens + 1] = token(TK.GT, ">", start)
        i = i + 1
      end

    -- -----------------------------------------------------------------
    -- String literals (double or single quoted)
    -- -----------------------------------------------------------------
    elseif ch == '"' or ch == "'" then
      local quote = ch
      i = i + 1 -- skip opening quote
      local buf = {}
      while i <= len and src:sub(i, i) ~= quote do
        buf[#buf + 1] = src:sub(i, i)
        i = i + 1
      end
      if i > len then
        return nil, "Unterminated string starting at position " .. start
      end
      i = i + 1 -- skip closing quote
      tokens[#tokens + 1] = token(TK.STRING, table.concat(buf), start)

    -- -----------------------------------------------------------------
    -- Number literals
    -- -----------------------------------------------------------------
    elseif byte >= 48 and byte <= 57 then -- 0-9
      local j = i
      while i <= len and src:byte(i) >= 48 and src:byte(i) <= 57 do
        i = i + 1
      end
      -- optional fractional part
      if i <= len and src:sub(i, i) == "." then
        i = i + 1
        while i <= len and src:byte(i) >= 48 and src:byte(i) <= 57 do
          i = i + 1
        end
      end
      tokens[#tokens + 1] = token(TK.NUMBER, tonumber(src:sub(j, i - 1)), start)

    -- -----------------------------------------------------------------
    -- Identifiers and keywords
    -- -----------------------------------------------------------------
    elseif (byte >= 65 and byte <= 90)    -- A-Z
        or (byte >= 97 and byte <= 122)   -- a-z
        or byte == 95 then                -- _
      local j = i
      i = i + 1
      while i <= len do
        local b = src:byte(i)
        if (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or (b >= 48 and b <= 57)
            or b == 95   -- _
            or b == 45   -- - (Obsidian allows hyphens in field names)
        then
          i = i + 1
        else
          break
        end
      end
      local word = src:sub(j, i - 1)
      local upper = word:upper()
      if KEYWORDS[upper] then
        tokens[#tokens + 1] = token(upper, word, start)
      else
        tokens[#tokens + 1] = token(TK.IDENT, word, start)
      end

    -- -----------------------------------------------------------------
    -- Unexpected character
    -- -----------------------------------------------------------------
    else
      return nil, "Unexpected character '" .. ch .. "' at position " .. start
    end
  end

  return tokens
end

-- =============================================================================
-- Parser state
-- =============================================================================

--- Create a new parser over a token list.
---@param tokens table[]  list of tokens from tokenize()
---@return table           parser state with cursor and helper methods
local function new_parser(tokens)
  local P = {
    tokens = tokens,
    pos = 1,
  }

  --- Return the current token without consuming it.
  function P:peek()
    return self.tokens[self.pos]
  end

  --- Return the current token and advance the cursor.
  function P:advance()
    local tok = self.tokens[self.pos]
    self.pos = self.pos + 1
    return tok
  end

  --- If the current token matches `type`, consume and return it.
  --- Otherwise return nil.
  function P:match(type)
    if self:peek().type == type then
      return self:advance()
    end
    return nil
  end

  --- Consume a token of `type` or produce an error.
  function P:expect(type)
    local tok = self:peek()
    if tok.type == type then
      return self:advance()
    end
    return nil, "Expected " .. type .. " at position " .. tok.pos
        .. " but got " .. tok.type
        .. (tok.value and (" '" .. tostring(tok.value) .. "'") or "")
  end

  --- Format a contextual error message.
  function P:error(msg)
    local tok = self:peek()
    return msg .. " at position " .. tok.pos
  end

  return P
end

-- =============================================================================
-- Expression parser (recursive descent, precedence climbing)
-- =============================================================================

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
---
--- Handles dotted field access. If the primary is a plain field or `this`,
--- dots extend the path. Otherwise dotted access wraps the primary in a
--- field node (future extension point for method-like syntax).
parse_postfix = function(P)
  local node, err = parse_primary(P)
  if not node then return nil, err end

  while P:peek().type == TK.DOT do
    P:advance() -- consume "."

    -- The segment after a dot is an identifier. Keywords are also valid
    -- as field names in dotted position (e.g., file.name, this.type).
    local seg = P:peek()
    if seg.type == TK.IDENT or KEYWORDS[seg.type] then
      P:advance()
      local name = seg.value

      if node.type == "this" then
        -- Convert bare `this` into a field node with this=true on first dot.
        node = { type = "field", path = { name }, this = true }
      elseif node.type == "field" then
        node.path[#node.path + 1] = name
      else
        -- Dotted access on an arbitrary expression: wrap as field access.
        -- This is a simplification; a full implementation might use a
        -- dedicated "member" node. For DQL purposes this suffices.
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

  -- Null literal (use is_null flag to distinguish from parse failure)
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
    -- Check for function call syntax: ident "(" ... ")"
    if P:peek().type == TK.LPAREN then
      P:advance() -- consume "("

      -- Special handling for dur(): collect all tokens as a raw string
      -- because dur() accepts "30 days", "1 month", etc. as a single argument.
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

      local args = {}
      if P:peek().type ~= TK.RPAREN then
        local arg, argerr = parse_expression(P)
        if not arg then return nil, argerr end
        args[#args + 1] = arg
        while P:match(TK.COMMA) do
          arg, argerr = parse_expression(P)
          if not arg then return nil, argerr end
          args[#args + 1] = arg
        end
      end
      local _, perr = P:expect(TK.RPAREN)
      if perr then return nil, perr end
      return { type = "call", name = tok.value, args = args }
    end
    -- Plain field reference
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

  -- Some keywords are valid as field names in expression context (e.g.,
  -- "id" is a keyword but also a common field name). Allow certain
  -- keywords to be treated as bare identifiers when they appear in
  -- expression position.
  local keyword_as_ident = {
    ID = true, AS = true, ASC = true, DESC = true,
  }
  if keyword_as_ident[tok.type] then
    P:advance()
    if P:peek().type == TK.LPAREN then
      P:advance()
      local args = {}
      if P:peek().type ~= TK.RPAREN then
        local arg, argerr = parse_expression(P)
        if not arg then return nil, argerr end
        args[#args + 1] = arg
        while P:match(TK.COMMA) do
          arg, argerr = parse_expression(P)
          if not arg then return nil, argerr end
          args[#args + 1] = arg
        end
      end
      local _, perr = P:expect(TK.RPAREN)
      if perr then return nil, perr end
      return { type = "call", name = tok.value, args = args }
    end
    return { type = "field", path = { tok.value } }
  end

  return nil, P:error("Expected expression")
end

-- =============================================================================
-- Source parser (FROM clause)
-- =============================================================================

local parse_source, parse_source_atom

--- source = source_atom (("AND"|"OR") source_atom)*
parse_source = function(P)
  local left, err = parse_source_atom(P)
  if not left then return nil, err end
  while P:peek().type == "AND" or P:peek().type == "OR" do
    local op_tok = P:advance()
    local right
    right, err = parse_source_atom(P)
    if not right then return nil, err end
    left = {
      type = op_tok.type == "AND" and "and" or "or",
      left = left,
      right = right,
    }
  end
  return left
end

--- source_atom = string_literal        -- folder: "Projects"
---            | "#" tag_path           -- tag: #project/active
---            | "!" source_atom        -- negation
---            | "(" source ")"         -- grouping
parse_source_atom = function(P)
  local tok = P:peek()

  -- Folder path: quoted string
  if tok.type == TK.STRING then
    P:advance()
    return { type = "folder", path = tok.value }
  end

  -- Tag: # followed by tag_path (ident ("/" ident)*)
  if tok.type == TK.HASH then
    P:advance()
    -- First segment must be an identifier (or keyword used as tag name)
    local seg = P:peek()
    if seg.type ~= TK.IDENT and not KEYWORDS[seg.type] then
      return nil, P:error("Expected tag name after '#'")
    end
    P:advance()
    local parts = { seg.value }
    while P:peek().type == TK.SLASH do
      P:advance() -- consume "/"
      seg = P:peek()
      if seg.type ~= TK.IDENT and not KEYWORDS[seg.type] then
        return nil, P:error("Expected tag segment after '/'")
      end
      P:advance()
      parts[#parts + 1] = seg.value
    end
    return { type = "tag", tag = table.concat(parts, "/") }
  end

  -- Negation
  if tok.type == TK.BANG or tok.type == "NOT" then
    P:advance()
    local operand, err = parse_source_atom(P)
    if not operand then return nil, err end
    return { type = "not", operand = operand }
  end

  -- Grouped source
  if tok.type == TK.LPAREN then
    P:advance()
    local src, err = parse_source(P)
    if not src then return nil, err end
    local _, perr = P:expect(TK.RPAREN)
    if perr then return nil, perr end
    return src
  end

  return nil, P:error("Expected source (quoted path, #tag, !, or parenthesized source)")
end

-- =============================================================================
-- Clause parsers
-- =============================================================================

--- Clause-starting keywords. Used to detect where an optional expression
--- ends (e.g., in LIST queries) or where the field list stops.
local CLAUSE_KEYWORDS = {
  FROM = true, WHERE = true, SORT = true,
  GROUP = true, FLATTEN = true, LIMIT = true,
}

--- Parse a field list for TABLE: field ("," field)*
--- Each field is an expression optionally followed by AS "alias".
---@return table[]|nil fields, string|nil error
local function parse_field_list(P)
  local fields = {}

  local expr, err = parse_expression(P)
  if not expr then return nil, err end
  local alias = nil
  if P:match("AS") then
    local tok = P:peek()
    if tok.type == TK.STRING then
      P:advance()
      alias = tok.value
    elseif tok.type == TK.IDENT or KEYWORDS[tok.type] then
      P:advance()
      alias = tok.value
    else
      return nil, P:error("Expected alias name after AS")
    end
  end
  fields[#fields + 1] = { expr = expr, alias = alias }

  while P:match(TK.COMMA) do
    expr, err = parse_expression(P)
    if not expr then return nil, err end
    alias = nil
    if P:match("AS") then
      local tok = P:peek()
      if tok.type == TK.STRING then
        P:advance()
        alias = tok.value
      elseif tok.type == TK.IDENT or KEYWORDS[tok.type] then
        P:advance()
        alias = tok.value
      else
        return nil, P:error("Expected alias name after AS")
      end
    end
    fields[#fields + 1] = { expr = expr, alias = alias }
  end

  return fields
end

--- Parse the sort clause body: sort_field ("," sort_field)*
--- sort_field = expression ["ASC"|"DESC"]
---@return table[]|nil sorts, string|nil error
local function parse_sort_fields(P)
  local sorts = {}

  local expr, err = parse_expression(P)
  if not expr then return nil, err end
  local dir = "ASC"
  if P:match("ASC") then
    dir = "ASC"
  elseif P:match("DESC") then
    dir = "DESC"
  end
  sorts[#sorts + 1] = { expr = expr, dir = dir }

  while P:match(TK.COMMA) do
    expr, err = parse_expression(P)
    if not expr then return nil, err end
    dir = "ASC"
    if P:match("ASC") then
      dir = "ASC"
    elseif P:match("DESC") then
      dir = "DESC"
    end
    sorts[#sorts + 1] = { expr = expr, dir = dir }
  end

  return sorts
end

-- =============================================================================
-- Top-level query parser
-- =============================================================================

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
  local tokens, tok_err = tokenize(query_string)
  if not tokens then return nil, tok_err end

  local P = new_parser(tokens)
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
    -- The field list ends when we hit a clause keyword or EOF.
    if not CLAUSE_KEYWORDS[P:peek().type] and P:peek().type ~= TK.EOF then
      local fields
      fields, err = parse_field_list(P)
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
  -- Optional clauses. DQL is fairly lenient about clause ordering, so we
  -- loop and accept any recognized clause keyword until EOF.
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
      query.sort, err = parse_sort_fields(P)
      if not query.sort then return nil, err end

    elseif kw == "GROUP" then
      P:advance()
      _, err = P:expect("BY")
      if err then return nil, err end
      local expr
      expr, err = parse_expression(P)
      if not expr then return nil, err end
      local alias = nil
      if P:match("AS") then
        local tok = P:peek()
        if tok.type == TK.IDENT or tok.type == TK.STRING or KEYWORDS[tok.type] then
          P:advance()
          alias = tok.value
        else
          return nil, P:error("Expected alias after AS in GROUP BY")
        end
      end
      query.group_by = { expr = expr, alias = alias }

    elseif kw == "FLATTEN" then
      P:advance()
      local expr
      expr, err = parse_expression(P)
      if not expr then return nil, err end
      local alias = nil
      if P:match("AS") then
        local tok = P:peek()
        if tok.type == TK.IDENT or tok.type == TK.STRING or KEYWORDS[tok.type] then
          P:advance()
          alias = tok.value
        else
          return nil, P:error("Expected alias after AS in FLATTEN")
        end
      end
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
  local tokens, tok_err = tokenize(expr_string)
  if not tokens then return nil, tok_err end

  local P = new_parser(tokens)
  local expr, err = parse_expression(P)
  if not expr then return nil, err end

  -- Ensure all input was consumed
  if P:peek().type ~= TK.EOF then
    return nil, P:error("Unexpected token after expression")
  end

  return expr
end

return M
