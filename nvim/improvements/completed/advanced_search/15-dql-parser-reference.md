# DQL Parser Reference

## Overview

The existing Dataview Query Language (DQL) parser lives in
`lua/andrew/vault/query/parser.lua` (932 lines). This document captures the
patterns and code that serve as reference for the search query parser.

## Why This Matters

The spec says the search query language is intentionally separate from DQL,
but both parsers share the same structural approach. Understanding the DQL
parser helps:
1. Follow established patterns for consistency
2. Avoid reinventing solutions to already-solved problems
3. Know where to diverge deliberately

## DQL Grammar Summary

```
Query      ::= Type [WITHOUT ID] [Fields|Expr] [Clauses]
Type       ::= TABLE | LIST | TASK
Clauses    ::= (FROM | WHERE | SORT | GROUP BY | FLATTEN | LIMIT)*

FROM       ::= FROM Source
Source     ::= SourceAtom ((AND|OR) SourceAtom)*
SourceAtom ::= "folder" | #tag | !SourceAtom | (Source)

WHERE      ::= WHERE Expr
Expr       ::= OR_expr
OR_expr    ::= AND_expr (OR AND_expr)*
AND_expr   ::= NOT_expr (AND NOT_expr)*
NOT_expr   ::= (NOT|!) NOT_expr | Comparison
Comparison ::= Additive (comp_op Additive)?
Additive   ::= Multiplicative ((+|-) Multiplicative)*
...down to Primary
```

## Tokenizer Patterns to Reuse

### Token Structure
```lua
-- DQL uses:
{ type = TK.IDENT, value = "status", pos = 15 }
-- Search should use same shape:
{ type = TK.FIELD, value = { name = "type", op = "=", value = "meeting" }, pos = 1 }
```

### Character Class Checking
```lua
-- DQL tokenizer uses byte values for speed
local function is_alpha(b) return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) end
local function is_digit(b) return b >= 48 and b <= 57 end
local function is_ws(b) return b == 32 or b == 9 or b == 10 or b == 13 end
```

### Keyword Detection
```lua
-- DQL uppercases the word and checks a table
local KEYWORDS = {
  AND = TK.AND, OR = TK.OR, NOT = TK.NOT,
  TABLE = TK.TABLE, LIST = TK.LIST, TASK = TK.TASK,
  -- ...
}

local upper = word:upper()
if KEYWORDS[upper] then
  tokens[#tokens + 1] = { type = KEYWORDS[upper], value = word, pos = start }
```

### String Parsing
```lua
-- DQL handles both single and double quotes
if ch == 34 or ch == 39 then  -- " or '
  local quote = ch
  i = i + 1
  local start = i
  while i <= len and input:byte(i) ~= quote do
    i = i + 1
  end
  -- ...
end
```

### Identifier Scanning
```lua
-- DQL allows hyphens in identifiers (for field names like "start-date")
while i <= len do
  local b = input:byte(i)
  if is_alpha(b) or is_digit(b) or b == 95 or b == 45 then  -- _, -
    i = i + 1
  else
    break
  end
end
```

## Parser Patterns to Reuse

### Parser State Object
```lua
local function new_parser(tokens)
  local P = { tokens = tokens, pos = 1 }

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
      return nil, string.format("Expected %s at position %d, got %s",
        type, self:peek().pos, self:peek().type)
    end
    return tok
  end

  return P
end
```

### Left-Associative Binary Expression Loop
```lua
-- This is the core pattern used at every precedence level
local function parse_binary_level(P, next_level, operators)
  local left, err = next_level(P)
  if not left then return nil, err end

  while operators[P:peek().type] do
    local op_tok = P:advance()
    local right
    right, err = next_level(P)
    if not right then return nil, err end
    left = { type = "binary", op = op_tok.value, left = left, right = right }
  end

  return left
end
```

### Error Propagation Pattern
```lua
-- Every parse function returns (result, err)
-- Errors propagate up without try/catch
local function parse_or(P)
  local left, err = parse_and(P)
  if not left then return nil, err end  -- propagate

  while P:peek().type == TK.OR do
    P:advance()
    local right
    right, err = parse_and(P)
    if not right then return nil, err end  -- propagate
    left = { type = "or", left = left, right = right }
  end

  return left
end
```

## DQL Execution Patterns (Reference Only)

### Page Context Building
DQL builds a "page" context for each vault entry:
```lua
local page = {
  file = {
    name = entry.basename,
    path = entry.rel_path,
    folder = entry.folder,
    link = Link.new(...),
    ctime = Date.from_epoch(entry.ctime),
    mtime = Date.from_epoch(entry.mtime),
    size = entry.size,
    tags = entry.tags,
    outlinks = ...,
    inlinks = ...,
    tasks = ...,
  },
  -- Frontmatter fields merged at top level
  status = entry.frontmatter.status,
  type = entry.frontmatter.type,
  -- Inline fields merged
  ...
}
```

The search filter doesn't need this indirection -- it accesses
VaultIndexEntry fields directly.

### Source Resolution (FROM)
DQL resolves FROM clauses against the index:
```lua
-- Folder source
if node.type == "folder" then
  for _, entry in pairs(idx.files) do
    if entry.folder:sub(1, #node.path) == node.path then
      matches[entry.rel_path] = build_page(entry)
    end
  end
end

-- Tag source
if node.type == "tag" then
  for _, entry in pairs(idx.files) do
    for _, tag in ipairs(entry.tags) do
      if tag == node.tag or tag:sub(1, #node.tag + 1) == node.tag .. "/" then
        matches[entry.rel_path] = build_page(entry)
        break
      end
    end
  end
end
```

The search filter uses the same logic for `path:` and `tag:` filters,
just without the page context wrapper.

### Expression Evaluation
DQL evaluates expressions against pages:
```lua
local function eval_expr(expr, page, current_page)
  if expr.type == "field" then
    return resolve_field(expr.path, page)
  elseif expr.type == "binary" then
    local left = eval_expr(expr.left, page, current_page)
    local right = eval_expr(expr.right, page, current_page)
    return apply_op(expr.op, left, right)
  -- ...
  end
end
```

The search filter's `match_entry()` is simpler: it evaluates boolean
expressions over direct field comparisons, without the expression evaluation
layer.

## Key Differences from Search Parser

| Aspect            | DQL Parser                    | Search Query Parser          |
|-------------------|-------------------------------|------------------------------|
| Token count       | ~25 types                     | ~12 types                    |
| Grammar depth     | 9 precedence levels           | 4 precedence levels          |
| Clause parsing    | Yes (FROM/WHERE/SORT/...)     | No                           |
| Field access      | Dotted paths (`file.name`)    | Prefix colon (`type:value`)  |
| Implicit AND      | No                            | Yes                          |
| Function calls    | Yes (50+ functions)           | No                           |
| Arithmetic        | Yes (+, -, *, /)              | No                           |
| Type system       | Rich (Date, Duration, Link)   | Simple (string, number)      |
| Output            | Structured results for render | File path sets for fzf       |

## Code Reuse Summary

### Directly Reusable
- Parser state object pattern (peek/advance/match/expect)
- Left-associative binary loop pattern
- Error propagation (result, err) pattern
- Character class helpers (is_alpha, is_digit, is_ws)
- Keyword detection via uppercase table

### Adapted (Same Pattern, Different Details)
- Tokenizer loop structure (different token types)
- Precedence climbing (fewer levels)
- AST node conventions (same shape, different node types)
- Boolean evaluation (simpler, no expression evaluator)

### Not Reusable
- DQL clause parsing (FROM/WHERE/SORT/GROUP/FLATTEN/LIMIT)
- DQL expression evaluator (arithmetic, function calls, dot access)
- DQL type system (Date, Duration, Link)
- DQL page context building
