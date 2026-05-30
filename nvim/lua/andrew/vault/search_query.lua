--- Search query tokenizer and recursive descent parser.
---
--- Parses vault search queries into an AST for structured searching.
--- Supports boolean logic (AND/OR/NOT), quoted phrases, regex patterns,
--- field filters, has: checks, task: filters, and parenthesized grouping.
--- Implicit AND between adjacent terms. Pure Lua with no requires.

local M = {}

-- =============================================================================
-- Token types
-- =============================================================================

M.TK = {
  TEXT   = "TEXT",
  QUOTED = "QUOTED",
  REGEX  = "REGEX",
  FIELD  = "FIELD",
  AND    = "AND",
  OR     = "OR",
  NOT    = "NOT",
  MINUS  = "MINUS",
  LPAREN = "LPAREN",
  RPAREN = "RPAREN",
  HAS    = "HAS",
  TASK   = "TASK",
  GRAPH  = "GRAPH",
  GROUP  = "GROUP",
  EOF    = "EOF",
}

local TK = M.TK

-- =============================================================================
-- Tokenizer
-- =============================================================================

local function is_ws(b)
  return b == 32 or b == 9 or b == 10 or b == 13
end

--- Create a token table.
---@param type string   token type
---@param value any     semantic value
---@param pos number    1-based byte offset
---@return table
local function token(type, value, pos)
  return { type = type, value = value, pos = pos }
end

--- Parse graph: parameter string into structured params.
--- Supports: "depth=2", "depth=3,dir=forward", "neighbors", "extended",
---           "depth=2,center=Dashboard"
---@param raw string  the raw value after "graph:"
---@return table { depth: number, direction: string, center: string }
local function parse_graph_params(raw)
  local params = { depth = 1, direction = "both", center = "current" }

  if raw == "neighbors" then
    return params
  end
  if raw == "extended" then
    params.depth = 2
    return params
  end

  -- Parse comma-separated key=value pairs
  for part in raw:gmatch("[^,]+") do -- matches pat.CSV_ITEM (no require to preserve zero-dependency design)
    local key, val = part:match("^(%w+)=(.+)$")
    if key and val then
      key = key:lower()
      if key == "depth" then
        params.depth = tonumber(val) or 1
      elseif key == "dir" or key == "direction" then
        val = val:lower()
        if val == "forward" or val == "backward" or val == "both" then
          params.direction = val
        end
      elseif key == "center" then
        params.center = val
      end
    end
  end

  return params
end

--- Parse a field value into operator and value(s).
---@param raw string  the raw value portion after the colon
---@return string op, string value, string|nil value2
local function parse_field_value(raw)
  if raw:sub(1, 2) == ">=" then
    return ">=", raw:sub(3)
  elseif raw:sub(1, 2) == "<=" then
    return "<=", raw:sub(3)
  elseif raw:sub(1, 1) == ">" then
    return ">", raw:sub(2)
  elseif raw:sub(1, 1) == "<" then
    return "<", raw:sub(2)
  end
  local a, b = raw:match("^(.-)%.%.(.+)$")
  if a then
    return "..", a, b
  end
  return "=", raw
end

--- Parse a field:value word into a structured token, or nil if not a field.
---@param word string  the full word including colon
---@param pos number   token start position
---@return table|nil   token or nil
local function parse_field_token(word, pos)
  local colon = word:find(":", 1, true)
  if not colon then return nil end

  local name = word:sub(1, colon - 1):lower()
  local raw_value = word:sub(colon + 1)

  -- URL detection: value starts with // (e.g., http://...)
  if raw_value:sub(1, 2) == "//" then return nil end

  -- Strip surrounding quotes from value if present
  if raw_value:sub(1, 1) == '"' and raw_value:sub(-1) == '"' then
    raw_value = raw_value:sub(2, -2)
  end

  -- group:mode (display directive, not a filter)
  if name == "group" then
    return token(TK.GROUP, raw_value:lower(), pos)
  end

  -- graph:params
  if name == "graph" then
    local params = parse_graph_params(raw_value)
    return token(TK.GRAPH, params, pos)
  end

  -- has:target
  if name == "has" then
    return token(TK.HAS, raw_value:lower(), pos)
  end

  -- task:*, task-todo:*, task-done:*, task-due:*, task-priority:*, etc.
  if name == "task" or name:sub(1, 5) == "task-" then
    -- Legacy variants: task, task-todo, task-done
    if name == "task" then
      return token(TK.TASK, { variant = "any", pattern = raw_value }, pos)
    elseif name == "task-todo" then
      return token(TK.TASK, { variant = "todo", pattern = raw_value }, pos)
    elseif name == "task-done" then
      return token(TK.TASK, { variant = "done", pattern = raw_value }, pos)
    end

    -- Task metadata variants: task-due, task-priority, task-tag, etc.
    local meta_field = name:sub(6) -- strip "task-" prefix
    local known_meta = {
      due = true, priority = true, tag = true,
      state = true, ["repeat"] = true,
      completion = true, scheduled = true,
    }
    if known_meta[meta_field] then
      local op, value, value2 = parse_field_value(raw_value)
      return token(TK.TASK, {
        variant = "meta",
        meta_field = meta_field,
        op = op,
        value = value,
        value2 = value2,
      }, pos)
    end

    -- Unknown task- prefix: fall through to text
    return nil
  end

  -- Identifier check: name must start with a letter and contain only [a-z0-9_-]
  if not name:match("^[a-z][a-z0-9_-]*$") then return nil end

  local op, value, value2 = parse_field_value(raw_value)
  return token(TK.FIELD, { name = name, op = op, value = value, value2 = value2 }, pos)
end

--- Tokenize a search query string into a flat list of tokens.
---
--- Returns a token list ending with EOF on success, or nil + error string.
---
---@param input string  the raw query text
---@return table[]|nil  list of tokens
---@return string|nil   error message on failure
local function tokenize(input)
  local tokens = {}
  local i = 1
  local len = #input

  while i <= len do
    local b = input:byte(i)

    -- Skip whitespace
    if is_ws(b) then
      i = i + 1

    -- Parentheses
    elseif b == 40 then -- (
      tokens[#tokens + 1] = token(TK.LPAREN, "(", i)
      i = i + 1
    elseif b == 41 then -- )
      tokens[#tokens + 1] = token(TK.RPAREN, ")", i)
      i = i + 1

    -- Quoted string
    elseif b == 34 then -- "
      local start = i
      i = i + 1
      while i <= len and input:byte(i) ~= 34 do
        i = i + 1
      end
      if i > len then
        return nil, "unterminated quoted string at position " .. start
      end
      tokens[#tokens + 1] = token(TK.QUOTED, input:sub(start + 1, i - 1), start)
      i = i + 1 -- skip closing "

    -- Regex
    elseif b == 47 then -- /
      local start = i
      i = i + 1
      while i <= len do
        local rb = input:byte(i)
        if rb == 47 then break end            -- closing /
        if rb == 92 and i + 1 <= len then     -- backslash: skip escaped char
          i = i + 1
        end
        i = i + 1
      end
      if i > len then
        return nil, "unterminated regex at position " .. start
      end
      local pattern = input:sub(start + 1, i - 1)
      i = i + 1 -- skip closing /

      -- Consume optional flags after closing /
      local flags = ""
      while i <= len do
        local fb = input:byte(i)
        -- i=105, m=109, s=115
        if fb == 105 or fb == 109 or fb == 115 then
          flags = flags .. string.char(fb)
          i = i + 1
        else
          break
        end
      end

      if flags ~= "" then
        tokens[#tokens + 1] = token(TK.REGEX, { pattern = pattern, flags = flags }, start)
      else
        tokens[#tokens + 1] = token(TK.REGEX, pattern, start)
      end

    -- Minus prefix
    elseif b == 45 then -- -
      if i + 1 <= len and not is_ws(input:byte(i + 1)) then
        tokens[#tokens + 1] = token(TK.MINUS, "-", i)
        i = i + 1
      else
        -- Bare minus or minus followed by whitespace → TEXT
        tokens[#tokens + 1] = token(TK.TEXT, "-", i)
        i = i + 1
      end

    -- Unquoted word
    else
      local start = i
      while i <= len do
        local wb = input:byte(i)
        if is_ws(wb) or wb == 40 or wb == 41 then break end -- ws, (, )
        if wb == 34 then -- " inside a word (e.g., field:"value")
          i = i + 1 -- skip opening quote
          while i <= len and input:byte(i) ~= 34 do i = i + 1 end
          if i <= len then i = i + 1 end -- skip closing quote
        else
          i = i + 1
        end
      end
      local word = input:sub(start, i - 1)

      -- Check for keywords (case-insensitive)
      local upper = word:upper()
      if upper == "AND" then
        tokens[#tokens + 1] = token(TK.AND, word, start)
      elseif upper == "OR" then
        tokens[#tokens + 1] = token(TK.OR, word, start)
      elseif upper == "NOT" then
        tokens[#tokens + 1] = token(TK.NOT, word, start)
      elseif word:find(":", 1, true) then
        -- Try to parse as field token
        local ftok = parse_field_token(word, start)
        if ftok then
          tokens[#tokens + 1] = ftok
        else
          tokens[#tokens + 1] = token(TK.TEXT, word, start)
        end
      else
        tokens[#tokens + 1] = token(TK.TEXT, word, start)
      end
    end
  end

  tokens[#tokens + 1] = token(TK.EOF, nil, i)
  return tokens
end

-- =============================================================================
-- Parser
-- =============================================================================

--- Create a new parser over a token list.
---@param tokens table[]  list of tokens from tokenize()
---@return table           parser state with cursor and helper methods
local function new_parser(tokens)
  local P = { tokens = tokens, pos = 1 }

  function P:peek()
    return self.tokens[self.pos] or { type = TK.EOF, pos = self.pos }
  end

  function P:advance()
    local tok = self.tokens[self.pos]
    self.pos = self.pos + 1
    return tok
  end

  function P:match(type)
    if self:peek().type == type then return self:advance() end
    return nil
  end

  function P:expect(type)
    local tok = self:match(type)
    if not tok then
      return nil, "expected " .. type .. " at position " .. self:peek().pos
    end
    return tok
  end

  return P
end

-- Forward declarations
local parse_or
local parse_and
local parse_not
local parse_primary

--- Set of token types that can begin a primary expression.
local PRIMARY_START = {
  [TK.TEXT]   = true,
  [TK.QUOTED] = true,
  [TK.REGEX]  = true,
  [TK.FIELD]  = true,
  [TK.HAS]    = true,
  [TK.TASK]   = true,
  [TK.GRAPH]  = true,
  [TK.LPAREN] = true,
  [TK.MINUS]  = true,
  [TK.NOT]    = true,
}

--- or_expr = and_expr ("OR" and_expr)*
parse_or = function(P)
  local left, err = parse_and(P)
  if not left then return nil, err end
  while P:peek().type == TK.OR do
    P:advance()
    local right
    right, err = parse_and(P)
    if not right then return nil, err end
    left = { type = "or", left = left, right = right }
  end
  return left
end

--- and_expr = not_expr (("AND" | implicit) not_expr)*
parse_and = function(P)
  local left, err = parse_not(P)
  if not left then return nil, err end
  while true do
    local pt = P:peek().type
    if pt == TK.AND then
      P:advance()
      local right
      right, err = parse_not(P)
      if not right then return nil, err end
      left = { type = "and", left = left, right = right }
    elseif PRIMARY_START[pt] then
      -- Implicit AND
      local right
      right, err = parse_not(P)
      if not right then return nil, err end
      left = { type = "and", left = left, right = right }
    else
      break
    end
  end
  return left
end

--- not_expr = ("NOT" | MINUS) not_expr | primary
parse_not = function(P)
  local pt = P:peek().type
  if pt == TK.NOT or pt == TK.MINUS then
    P:advance()
    local operand, err = parse_not(P)
    if not operand then return nil, err end
    return { type = "not", operand = operand }
  end
  return parse_primary(P)
end

--- primary = "(" or_expr ")"
---         | FIELD | HAS | TASK
---         | QUOTED | REGEX | TEXT
parse_primary = function(P)
  local tok = P:peek()

  if tok.type == TK.LPAREN then
    P:advance()
    local node, err = parse_or(P)
    if not node then return nil, err end
    local _, perr = P:expect(TK.RPAREN)
    if perr then return nil, perr end
    return node
  end

  if tok.type == TK.FIELD then
    P:advance()
    return {
      type   = "field",
      name   = tok.value.name,
      op     = tok.value.op,
      value  = tok.value.value,
      value2 = tok.value.value2,
    }
  end

  if tok.type == TK.GRAPH then
    P:advance()
    return {
      type = "graph",
      depth = tok.value.depth or 1,
      direction = tok.value.direction or "both",
      center = tok.value.center or "current",
    }
  end

  if tok.type == TK.HAS then
    P:advance()
    return { type = "has", target = tok.value }
  end

  if tok.type == TK.TASK then
    P:advance()
    local v = tok.value
    if v.variant == "meta" then
      return {
        type = "task",
        variant = "meta",
        meta_field = v.meta_field,
        op = v.op,
        value = v.value,
        value2 = v.value2,
      }
    end
    return { type = "task", variant = v.variant, pattern = v.pattern }
  end

  if tok.type == TK.QUOTED then
    P:advance()
    return { type = "text", value = tok.value, quoted = true }
  end

  if tok.type == TK.REGEX then
    P:advance()
    -- Handle both old (string) and new (table with flags) formats
    if type(tok.value) == "table" then
      return { type = "regex", pattern = tok.value.pattern, flags = tok.value.flags }
    end
    return { type = "regex", pattern = tok.value }
  end

  if tok.type == TK.TEXT then
    P:advance()
    return { type = "text", value = tok.value, quoted = false }
  end

  return nil, "unexpected token '" .. tostring(tok.value or tok.type) .. "' at position " .. tok.pos
end

--- Parse a token list into an AST.
---
--- Returns the root AST node on success, or nil + error string on failure.
---
---@param tokens table[]  list of tokens from tokenize()
---@return table|nil       AST root node
---@return string|nil      error message on failure
local function parse(tokens)
  local P = new_parser(tokens)
  local ast, err = parse_or(P)
  if not ast then return nil, err end
  if P:peek().type ~= TK.EOF then
    local tok = P:peek()
    return nil, "unexpected token '" .. tostring(tok.value or tok.type) .. "' at position " .. tok.pos
  end
  return ast
end

--- Extract group: directives from a token list.
--- Removes GROUP tokens in-place and returns the group mode.
---@param tokens table[] token list
---@return string|nil group_mode
local function extract_group(tokens)
  local mode = nil
  local filtered = {}
  for _, tok in ipairs(tokens) do
    if tok.type == TK.GROUP then
      mode = tok.value
    else
      filtered[#filtered + 1] = tok
    end
  end
  -- Replace tokens in-place
  for i = 1, math.max(#tokens, #filtered) do
    tokens[i] = filtered[i]
  end
  return mode
end

--- Convenience wrapper: tokenize and parse a query string in one call.
---
--- Returns the root AST node on success, or nil + error string on failure.
--- If a group: directive is present, it is extracted and returned as the third value.
---
---@param query_string string  the raw search query
---@return table|nil            AST root node
---@return string|nil           error message on failure
---@return string|nil           group mode from group: directive
function M.parse_query(query_string)
  if type(query_string) ~= "string" or query_string:match("^%s*$") then
    return nil, "empty query"
  end
  local tokens, tok_err = tokenize(query_string)
  if not tokens then return nil, tok_err end
  local group_mode = extract_group(tokens)
  -- If only a group: directive was given (no filter tokens remain except EOF),
  -- we still need a valid AST. Check if only EOF remains.
  if #tokens == 1 and tokens[1].type == TK.EOF then
    -- No filter: return a special "match all" sentinel
    return { type = "match_all" }, nil, group_mode
  end
  local ast, parse_err = parse(tokens)
  return ast, parse_err, group_mode
end

-- =============================================================================
-- Field name suggestion (fuzzy correction)
-- =============================================================================

--- Compute the Levenshtein edit distance between two strings.
---@param a string
---@param b string
---@return number
function M.edit_distance(a, b)
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end

  -- Use two rows instead of full matrix (space optimization)
  local prev = {}
  local curr = {}
  for j = 0, lb do prev[j] = j end

  for i = 1, la do
    curr[0] = i
    for j = 1, lb do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
      curr[j] = math.min(
        prev[j] + 1,       -- deletion
        curr[j - 1] + 1,   -- insertion
        prev[j - 1] + cost -- substitution
      )
    end
    prev, curr = curr, prev
  end
  return prev[lb]
end

--- Find the closest known field name to an unknown identifier.
--- Returns the best match if edit distance <= max_distance, or nil.
---@param unknown string the unrecognized field name
---@param known_fields string[] list of valid field names
---@param max_distance? number threshold (default 2)
---@return string|nil suggested field name
---@return number|nil edit distance
function M.suggest_field(unknown, known_fields, max_distance)
  max_distance = max_distance or 2
  -- Skip very short names (high false-positive rate)
  if #unknown < 3 then return nil, nil end

  local best_field = nil
  local best_dist = max_distance + 1
  local unknown_lower = unknown:lower()

  for _, field in ipairs(known_fields) do
    local dist = M.edit_distance(unknown_lower, field:lower())
    if dist < best_dist then
      best_dist = dist
      best_field = field
    end
  end

  if best_dist <= max_distance then
    return best_field, best_dist
  end
  return nil, nil
end

return M
