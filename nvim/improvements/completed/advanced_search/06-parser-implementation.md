# Parser Implementation

## File: `lua/andrew/vault/search_query.lua`

The parser transforms a flat token array into an AST using recursive descent
with explicit precedence levels. It follows the same structural pattern as
the existing DQL parser in `query/parser.lua`.

## Parser State

```lua
local function new_parser(tokens)
  local P = {
    tokens = tokens,
    pos = 1,
  }

  function P:peek()
    return self.tokens[self.pos] or { type = TK.EOF }
  end

  function P:advance()
    local tok = self.tokens[self.pos]
    self.pos = self.pos + 1
    return tok
  end

  function P:match(type)
    if self:peek().type == type then
      return self:advance()
    end
    return nil
  end

  function P:expect(type)
    local tok = self:match(type)
    if not tok then
      return nil, "Expected " .. type .. " at position " .. self:peek().pos
    end
    return tok
  end

  return P
end
```

## Precedence Levels

From lowest (parsed first) to highest (parsed last):

1. **OR** -- `or_expr`
2. **AND / implicit AND** -- `and_expr`
3. **NOT / -** -- `not_expr`
4. **Primary** -- `primary_expr`

## Parsing Functions

### Top-Level: `M.parse(tokens)`

```lua
function M.parse(tokens)
  local P = new_parser(tokens)
  local ast, err = parse_or(P)
  if not ast then return nil, err end

  -- Ensure we consumed all tokens
  if P:peek().type ~= TK.EOF then
    return nil, "Unexpected token '" .. tostring(P:peek().value)
      .. "' at position " .. P:peek().pos
  end

  return ast
end
```

### `parse_or(P)` -- Lowest Precedence

```lua
local function parse_or(P)
  local left, err = parse_and(P)
  if not left then return nil, err end

  while P:peek().type == TK.OR do
    P:advance()  -- consume OR
    local right
    right, err = parse_and(P)
    if not right then return nil, err end
    left = { type = "or", left = left, right = right }
  end

  return left
end
```

### `parse_and(P)` -- AND + Implicit AND

```lua
local function parse_and(P)
  local left, err = parse_not(P)
  if not left then return nil, err end

  while true do
    local tok = P:peek()

    -- Explicit AND
    if tok.type == TK.AND then
      P:advance()
      local right
      right, err = parse_not(P)
      if not right then return nil, err end
      left = { type = "and", left = left, right = right }

    -- Implicit AND: next token starts a new primary expression
    elseif is_primary_start(tok) then
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
```

### Implicit AND Detection

```lua
local function is_primary_start(tok)
  return tok.type == TK.TEXT
      or tok.type == TK.QUOTED
      or tok.type == TK.REGEX
      or tok.type == TK.FIELD
      or tok.type == TK.HAS
      or tok.type == TK.TASK
      or tok.type == TK.LPAREN
      or tok.type == TK.MINUS
      or tok.type == TK.NOT
end
```

When the next token is a valid start of a primary expression (not OR, AND,
RPAREN, or EOF), the parser inserts an implicit AND. This means:

```
type:meeting deploy --> AND(field("type","meeting"), text("deploy"))
a b c               --> AND(AND(text("a"), text("b")), text("c"))
```

### `parse_not(P)` -- NOT / - Prefix

```lua
local function parse_not(P)
  local tok = P:peek()

  if tok.type == TK.NOT then
    P:advance()
    local operand, err = parse_not(P)  -- right-recursive for NOT NOT
    if not operand then return nil, err end
    return { type = "not", operand = operand }

  elseif tok.type == TK.MINUS then
    P:advance()
    local operand, err = parse_not(P)
    if not operand then return nil, err end
    return { type = "not", operand = operand }
  end

  return parse_primary(P)
end
```

NOT is right-recursive: `NOT NOT x` produces `{ type="not", operand={ type="not", operand=x } }`.
The `-` prefix is syntactic sugar for NOT.

### `parse_primary(P)` -- Leaf Nodes

```lua
local function parse_primary(P)
  local tok = P:peek()

  -- Parenthesized expression
  if tok.type == TK.LPAREN then
    P:advance()
    local expr, err = parse_or(P)
    if not expr then return nil, err end
    local _, close_err = P:expect(TK.RPAREN)
    if not _ then return nil, close_err or "Expected ')'" end
    return expr
  end

  -- Field filter
  if tok.type == TK.FIELD then
    P:advance()
    return {
      type = "field",
      name = tok.value.name,
      op = tok.value.op,
      value = tok.value.value,
      value2 = tok.value.value2,
    }
  end

  -- Has filter
  if tok.type == TK.HAS then
    P:advance()
    return { type = "has", target = tok.value }
  end

  -- Task filter
  if tok.type == TK.TASK then
    P:advance()
    return {
      type = "task",
      variant = tok.value.variant,
      pattern = tok.value.pattern,
    }
  end

  -- Quoted text
  if tok.type == TK.QUOTED then
    P:advance()
    return { type = "text", value = tok.value, quoted = true }
  end

  -- Regex
  if tok.type == TK.REGEX then
    P:advance()
    return { type = "regex", pattern = tok.value }
  end

  -- Plain text
  if tok.type == TK.TEXT then
    P:advance()
    return { type = "text", value = tok.value, quoted = false }
  end

  return nil, "Unexpected token '" .. tostring(tok.value)
    .. "' at position " .. tok.pos
end
```

## Convenience Function

```lua
function M.parse_query(query_string)
  if not query_string or query_string == "" then
    return nil, "Empty query"
  end

  local tokens, tok_err = M.tokenize(query_string)
  if not tokens then
    return nil, tok_err
  end

  return M.parse(tokens)
end
```

## AST Examples

### Simple Text
```
Input: "deploy"
AST:   { type = "text", value = "deploy", quoted = false }
```

### Implicit AND
```
Input: "a b"
AST:   { type = "and",
         left  = { type = "text", value = "a", quoted = false },
         right = { type = "text", value = "b", quoted = false } }
```

### Explicit OR
```
Input: "a OR b"
AST:   { type = "or",
         left  = { type = "text", value = "a", quoted = false },
         right = { type = "text", value = "b", quoted = false } }
```

### Precedence: `a b OR c`
```
Input: "a b OR c"
AST:   { type = "or",
         left  = { type = "and",
                   left  = { type = "text", value = "a" },
                   right = { type = "text", value = "b" } },
         right = { type = "text", value = "c" } }
```
Implicit AND binds tighter than OR (same precedence as explicit AND).

### NOT
```
Input: "NOT a"
AST:   { type = "not", operand = { type = "text", value = "a" } }
```

### Minus Shorthand
```
Input: "-tag:archived"
AST:   { type = "not",
         operand = { type = "field", name = "tag", op = "=", value = "archived" } }
```

### Grouping
```
Input: "(a OR b) AND c"
AST:   { type = "and",
         left  = { type = "or",
                   left  = { type = "text", value = "a" },
                   right = { type = "text", value = "b" } },
         right = { type = "text", value = "c" } }
```

### Complex Mixed Query
```
Input: "type:meeting tag:urgent NOT tag:archived deploy"
AST:   { type = "and",
         left  = { type = "and",
                   left  = { type = "and",
                             left  = { type = "field", name = "type", op = "=", value = "meeting" },
                             right = { type = "field", name = "tag", op = "=", value = "urgent" } },
                   right = { type = "not",
                             operand = { type = "field", name = "tag", op = "=", value = "archived" } } },
         right = { type = "text", value = "deploy", quoted = false } }
```

### Field with Comparison
```
Input: "priority:>3"
AST:   { type = "field", name = "priority", op = ">", value = "3" }
```

### Field with Range
```
Input: "created:2026-01..2026-02"
AST:   { type = "field", name = "created", op = "..", value = "2026-01", value2 = "2026-02" }
```

### Has Filter
```
Input: "has:tags"
AST:   { type = "has", target = "tags" }
```

### Task Filter
```
Input: "task-done:\"\""
AST:   { type = "task", variant = "done", pattern = "" }
```

## Error Cases

```
Input: "(a OR b"
Error: "Expected RPAREN at position 8"

Input: '"unterminated'
Error: "Unterminated quoted string at position 1"

Input: "AND AND"
Error: "Unexpected token 'AND' at position 5"

Input: ""
Error: "Empty query"

Input: "a OR"
Error: "Unexpected token 'nil' at position 5" (EOF after OR)
```

## Comparison with DQL Parser

| Feature             | DQL Parser               | Search Query Parser       |
|---------------------|--------------------------|---------------------------|
| Precedence levels   | 9 (OR → Primary)         | 4 (OR → Primary)         |
| Implicit AND        | No                       | Yes                       |
| Arithmetic          | +, -, *, /               | No                        |
| Function calls      | `date()`, `dur()`, etc.  | No                        |
| Postfix `.` access  | `file.name`              | No (colon prefix instead) |
| Clause parsing      | FROM, WHERE, SORT, etc.  | No (single expression)    |
| Error recovery      | None (first error stops) | None (first error stops)  |
| Token structure     | `{ type, value, pos }`   | `{ type, value, pos }`    |
| Parser state        | `peek/advance/match/expect` | Same                   |
