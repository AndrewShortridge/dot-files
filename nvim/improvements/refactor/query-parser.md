# query/parser.lua Refactoring Plan

## File Stats
- **File:** `lua/andrew/vault/query/parser.lua`
- **Lines:** 931
- **Dead Code:** `M.parse_expr()` (lines 915-929) -- exported but never called anywhere in codebase
- **Public API:** `M.parse(query_string)`, `M.parse_expr(expr_string)`
- **Dependencies:** None (zero requires)

## Current Structure

| Section | Lines | Purpose |
|---------|-------|---------|
| Token Types (TK) | 12-44 | 20+ token type constants |
| Keywords Map | 46-59 | Case-insensitive keyword recognition |
| Tokenizer | 62-241 | `tokenize(src)` -- full lexical analyzer (180 lines) |
| Parser State | 243-295 | `new_parser(tokens)` -- cursor with peek/advance/match/expect/error |
| Expression Parser | 297-584 | 6-level precedence: OR->AND->NOT->Compare->Additive->Multiplicative->Unary->Postfix->Primary |
| Source Parser (FROM) | 586-664 | `parse_source()`, `parse_source_atom()` -- folder/tag/negation |
| Clause Helpers | 666-751 | `parse_field_list()`, `parse_sort_fields()`, `CLAUSE_KEYWORDS` |
| Top-Level Query | 753-906 | `M.parse()` -- TABLE/LIST/TASK + FROM/WHERE/SORT/GROUP/FLATTEN/LIMIT |
| Expression Entry Point | 908-929 | `M.parse_expr()` -- standalone expression parsing |

## Dead Code

### `M.parse_expr()` (lines 915-929)
Exported but never called anywhere in the vault codebase. Likely provided for future extension.
**Action:** Mark as internal or remove. If kept for external integration, add a comment noting it is unused internally.

## Duplicated Logic Patterns

### 1. Function Call Argument Parsing (2x -- lines 525-535, 565-575)
Identical loops in `parse_primary()` for regular identifiers and keywords-as-identifiers:
```lua
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
```
**Fix:** Extract `parse_arg_list(P)`.

### 2. Alias Parsing (4x -- lines 686-696, 704-714, 865-872, 882-889)
Four nearly-identical "parse optional alias after AS" blocks in `parse_field_list()` and main query parser (GROUP BY, FLATTEN).
**Fix:** Extract `parse_optional_alias(P)`.

### 3. Direction Parsing (2x -- lines 730-735, 741-746)
Identical ASC/DESC parsing in `parse_sort_fields()`:
```lua
local dir = "ASC"
if P:match("ASC") then dir = "ASC"
elseif P:match("DESC") then dir = "DESC" end
```
**Fix:** Extract `parse_direction(P)`.

### 4. List Item Parsing Pattern
Both `parse_field_list()` and `parse_sort_fields()` follow identical structure: parse first item, while comma parse next item, append to array.
**Fix:** Extract generic `parse_item_list(P, parse_item_fn)` combinator.

## Proposed Extraction Plan

### Subsystem A: Tokenizer -> `query/parser/tokenizer.lua` (~180 lines)
**Functions:** `token()`, `tokenize(src)`
**Data:** TK constants, KEYWORDS map
**Rationale:** Complete lexical analysis, zero parser dependencies. Self-contained.

### Subsystem B: Parser State -> `query/parser/state.lua` (~50 lines)
**Functions:** `new_parser(tokens)` with methods: peek, advance, match, expect, error
**Rationale:** Reusable parser cursor pattern.

### Subsystem C: Expression Parser -> `query/parser/expressions.lua` (~290 lines)
**Functions:** All precedence-level functions from `parse_expression()` through `parse_primary()`
**Rationale:** Self-contained recursive descent with clear interface.

### Subsystem D: Source Parser -> `query/parser/source.lua` (~80 lines)
**Functions:** `parse_source()`, `parse_source_atom()`
**Rationale:** Independent FROM clause logic.

### Subsystem E: Clause Helpers -> `query/parser/clauses.lua` (~85 lines)
**Functions:** `parse_field_list()`, `parse_sort_fields()`, `CLAUSE_KEYWORDS`, `parse_arg_list()` (new), `parse_optional_alias()` (new), `parse_direction()` (new)
**Rationale:** Reusable parsing patterns, eliminates 4 duplication sites.

**Note:** The file is well-structured and at 931 lines is on the border of "needs splitting." The duplication fixes alone would be high-value; full extraction is optional but improves testability.

## External Callers
- `query/init.lua` line 116: `parser.parse(content)`

## Implementation Order
1. Extract dedup helpers (parse_arg_list, parse_optional_alias, parse_direction) -- immediate value
2. Extract tokenizer (self-contained, enables independent testing)
3. Extract expression parser (biggest subsystem)
4. Extract source parser and clause helpers
5. Consider removing or marking `M.parse_expr()` as internal

## Expected Result
- `parser.lua`: ~175 lines (orchestrator: M.parse + M.parse_expr)
- `parser/tokenizer.lua`: ~180 lines
- `parser/state.lua`: ~50 lines
- `parser/expressions.lua`: ~290 lines
- `parser/source.lua`: ~80 lines
- `parser/clauses.lua`: ~85 lines
