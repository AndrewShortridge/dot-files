# Tokenizer Implementation

## File: `lua/andrew/vault/search_query.lua`

The tokenizer transforms a raw query string into a flat array of tokens. It
runs in a single pass with no backtracking.

## Token Structure

```lua
---@class SearchToken
---@field type string     -- one of M.TK values
---@field value any       -- parsed value (string, table, etc.)
---@field pos number      -- 1-based byte offset in input string
```

## Token Types

```lua
M.TK = {
  TEXT   = "TEXT",     -- plain unquoted word
  QUOTED = "QUOTED",  -- "quoted string"
  REGEX  = "REGEX",   -- /regex pattern/
  FIELD  = "FIELD",   -- field_name:value (parsed into sub-fields)
  AND    = "AND",     -- AND keyword
  OR     = "OR",      -- OR keyword
  NOT    = "NOT",     -- NOT keyword
  MINUS  = "MINUS",   -- - prefix (NOT shorthand)
  LPAREN = "LPAREN",  -- (
  RPAREN = "RPAREN",  -- )
  HAS    = "HAS",     -- has:target
  TASK   = "TASK",    -- task:""/task-todo:""/task-done:""
  EOF    = "EOF",     -- end of input
}
```

## FIELD Token Value Structure

A FIELD token carries structured data in its value:

```lua
-- Simple equality: type:meeting
{ name = "type", op = "=", value = "meeting" }

-- Comparison: priority:>3
{ name = "priority", op = ">", value = "3" }

-- Range: created:2026-01..2026-02
{ name = "created", op = "..", value = "2026-01", value2 = "2026-02" }

-- Quoted value: status:"In Progress"
{ name = "status", op = "=", value = "In Progress" }
```

## Known Field Names

These field names are recognized by the tokenizer as FIELD tokens when
followed by `:`. Unknown prefixes with `:` are also treated as FIELD tokens
(generic field filter).

```lua
local KNOWN_FIELDS = {
  type = true, tag = true, path = true, file = true,
  folder = true, status = true, created = true, modified = true,
  day = true, priority = true,
}
```

## Tokenization Algorithm

```lua
function M.tokenize(input)
  local tokens = {}
  local i = 1
  local len = #input

  while i <= len do
    -- Skip whitespace
    while i <= len and is_ws(input:byte(i)) do i = i + 1 end
    if i > len then break end

    local ch = input:byte(i)
    local pos = i

    -- 1. Parentheses
    if ch == 40 then  -- '('
      tokens[#tokens + 1] = { type = TK.LPAREN, value = "(", pos = pos }
      i = i + 1

    elseif ch == 41 then  -- ')'
      tokens[#tokens + 1] = { type = TK.RPAREN, value = ")", pos = pos }
      i = i + 1

    -- 2. Quoted strings: "..."
    elseif ch == 34 then  -- '"'
      i = i + 1  -- skip opening quote
      local start = i
      while i <= len and input:byte(i) ~= 34 do i = i + 1 end
      if i > len then
        return nil, "Unterminated quoted string at position " .. pos
      end
      local value = input:sub(start, i - 1)
      tokens[#tokens + 1] = { type = TK.QUOTED, value = value, pos = pos }
      i = i + 1  -- skip closing quote

    -- 3. Regex: /pattern/
    elseif ch == 47 then  -- '/'
      i = i + 1
      local start = i
      while i <= len and input:byte(i) ~= 47 do i = i + 1 end
      if i > len then
        return nil, "Unterminated regex at position " .. pos
      end
      local pattern = input:sub(start, i - 1)
      tokens[#tokens + 1] = { type = TK.REGEX, value = pattern, pos = pos }
      i = i + 1  -- skip closing /

    -- 4. Minus prefix (NOT shorthand)
    -- Only when followed by non-whitespace and not inside a word
    elseif ch == 45 then  -- '-'
      if i + 1 <= len and not is_ws(input:byte(i + 1)) then
        tokens[#tokens + 1] = { type = TK.MINUS, value = "-", pos = pos }
        i = i + 1
      else
        -- Bare hyphen, treat as text
        tokens[#tokens + 1] = { type = TK.TEXT, value = "-", pos = pos }
        i = i + 1
      end

    -- 5. Unquoted words (may be keywords, fields, or text)
    else
      local start = i
      -- Scan to end of word (non-whitespace, non-paren)
      while i <= len do
        local b = input:byte(i)
        if is_ws(b) or b == 40 or b == 41 then break end  -- ws, (, )
        i = i + 1
      end
      local word = input:sub(start, i - 1)

      -- Check for keywords (case-insensitive)
      local upper = word:upper()
      if upper == "AND" then
        tokens[#tokens + 1] = { type = TK.AND, value = "AND", pos = pos }
      elseif upper == "OR" then
        tokens[#tokens + 1] = { type = TK.OR, value = "OR", pos = pos }
      elseif upper == "NOT" then
        tokens[#tokens + 1] = { type = TK.NOT, value = "NOT", pos = pos }

      -- Check for field:value pattern
      elseif word:find(":") then
        local field_token = parse_field_token(word, pos)
        if field_token then
          tokens[#tokens + 1] = field_token
        else
          tokens[#tokens + 1] = { type = TK.TEXT, value = word, pos = pos }
        end

      -- Plain text term
      else
        tokens[#tokens + 1] = { type = TK.TEXT, value = word, pos = pos }
      end
    end
  end

  tokens[#tokens + 1] = { type = TK.EOF, value = nil, pos = i }
  return tokens
end
```

## Field Token Parsing

```lua
local function parse_field_token(word, pos)
  local colon = word:find(":")
  local name = word:sub(1, colon - 1):lower()
  local raw_value = word:sub(colon + 1)

  -- Special: has:target
  if name == "has" then
    return { type = TK.HAS, value = raw_value:lower(), pos = pos }
  end

  -- Special: task:, task-todo:, task-done:
  if name == "task" or name == "task-todo" or name == "task-done" then
    return { type = TK.TASK, value = { variant = ..., pattern = raw_value }, pos = pos }
  end

  -- Check if name is a known field or looks like an identifier
  if not KNOWN_FIELDS[name] and not name:match("^[a-z][a-z0-9_-]*$") then
    return nil  -- Not a field, treat as plain text
  end

  -- Parse value portion for comparison operators and ranges
  local op, value, value2 = parse_field_value(raw_value)

  return {
    type = TK.FIELD,
    value = { name = name, op = op, value = value, value2 = value2 },
    pos = pos,
  }
end

local function parse_field_value(raw)
  -- Check for comparison operators
  if raw:sub(1, 2) == ">=" then
    return ">=", raw:sub(3)
  elseif raw:sub(1, 2) == "<=" then
    return "<=", raw:sub(3)
  elseif raw:sub(1, 1) == ">" then
    return ">", raw:sub(2)
  elseif raw:sub(1, 1) == "<" then
    return "<", raw:sub(2)
  end

  -- Check for range operator
  local lo, hi = raw:match("^(.-)%.%.(.+)$")
  if lo and hi then
    return "..", lo, hi
  end

  -- Plain equality
  return "=", raw
end
```

## Edge Cases

### Quoted Field Values
`status:"In Progress"` -- The tokenizer needs to handle quotes after the colon.
When scanning an unquoted word and hitting `:`, look ahead for `"` to capture
the quoted portion.

### Hyphenated Field Names
`task-todo:""` and `task-done:""` contain hyphens. The tokenizer checks for
these specific prefixes before `:`.

### Empty Field Values
`type:` with nothing after the colon -- interpreted as "has this field" by the
evaluator (value is empty string, op is "=").

### Consecutive Operators
`AND AND` or `NOT NOT` -- the parser handles these (double NOT is valid and
collapses during evaluation).

### Case Sensitivity
- Keywords `AND`, `OR`, `NOT` are case-insensitive (checked via `.upper()`)
- Field names are lowercased
- Field values preserve case (case-insensitive matching is done during evaluation)

## Test Cases

```lua
-- Plain text
tokenize("deploy") --> [TEXT("deploy"), EOF]

-- Quoted text
tokenize('"exact phrase"') --> [QUOTED("exact phrase"), EOF]

-- Field filter
tokenize("type:meeting") --> [FIELD({name="type", op="=", value="meeting"}), EOF]

-- Comparison
tokenize("priority:>3") --> [FIELD({name="priority", op=">", value="3"}), EOF]

-- Range
tokenize("created:2026-01..2026-02") --> [FIELD({name="created", op="..", value="2026-01", value2="2026-02"}), EOF]

-- Boolean
tokenize("a AND b") --> [TEXT("a"), AND, TEXT("b"), EOF]

-- NOT shorthand
tokenize("-tag:archived") --> [MINUS, FIELD({name="tag", op="=", value="archived"}), EOF]

-- Regex
tokenize("/^## Results/") --> [REGEX("^## Results"), EOF]

-- Mixed
tokenize("type:meeting deploy") --> [FIELD({name="type", op="=", value="meeting"}), TEXT("deploy"), EOF]

-- Has filter
tokenize("has:tags") --> [HAS("tags"), EOF]

-- Task filter
tokenize("task-todo:\"\"") --> [TASK({variant="todo", pattern=""}), EOF]

-- Grouping
tokenize("(a OR b) AND c") --> [LPAREN, TEXT("a"), OR, TEXT("b"), RPAREN, AND, TEXT("c"), EOF]

-- Empty string
tokenize("") --> [EOF]

-- Unclosed quote
tokenize('"unterminated') --> nil, "Unterminated quoted string at position 1"

-- Unclosed regex
tokenize("/unclosed") --> nil, "Unterminated regex at position 1"
```
