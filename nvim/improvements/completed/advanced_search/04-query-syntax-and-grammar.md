# Query Syntax and Grammar

## Design Philosophy

The search query language is intentionally separate from the Dataview Query
Language (DQL) in `query/parser.lua`. DQL is SQL-like for table/list/task
rendering in code blocks. The search query language is optimized for quick
interactive filtering: terser syntax, implicit AND, prefix-operator field
filters. Obsidian-compatible syntax where possible.

## Query Syntax Reference

### Text Search (Passed to Ripgrep)

```
deploy                          # files containing "deploy"
"exact phrase"                  # quoted exact match
/^##\s+Results/                 # regex passed to ripgrep
```

### Field Filters (`field:value`)

```
type:meeting                    # frontmatter type = meeting
tag:project/active              # has tag project/active (or child)
tag:urgent                      # has tag urgent
path:Projects/                  # file path starts with Projects/
file:Dashboard                  # basename contains Dashboard
folder:Projects/Alpha           # folder is exactly Projects/Alpha
status:active                   # frontmatter OR inline field status = active
priority:1                      # frontmatter OR inline field priority = 1
```

### Comparison Operators

```
priority:>3                     # priority greater than 3
priority:>=3                    # priority >= 3
priority:<2                     # priority less than 2
priority:<=2                    # priority <= 2
priority:1..3                   # priority between 1 and 3 inclusive
```

### Date Filters

```
# Relative dates (Nd = "N days ago"; operators compare recency/age)
modified:<7d                    # modified less than 7 days ago (within last 7 days)
modified:<30d                   # modified less than 30 days ago
modified:>90d                   # modified more than 90 days ago
modified:last-7d                # within last 7 days (range keyword)
modified:last-30d               # within last 30 days (range keyword)
modified:today                  # modified today
modified:yesterday              # modified yesterday
modified:this-week              # modified this week (since Monday)
modified:this-month             # modified this month

# Absolute dates
created:2026-01-15              # created on that exact date
day:2026-02-26                  # filename-based date

# Date ranges
created:2026-01-01..2026-02-01  # created in January 2026
modified:2026-01..2026-02       # modified in January through February
```

### Task Filters

```
task:""                         # any task
task-todo:""                    # open tasks (status " ")
task-done:""                    # completed tasks (status "x")
has:tasks                       # files containing any tasks
```

### Existence Checks

```
has:tags                        # files with any tags
has:aliases                     # files with aliases
has:outlinks                    # files with outgoing links
has:inlinks                     # files with incoming links
has:frontmatter                 # files with any frontmatter
```

### Boolean Operators

```
type:meeting AND tag:urgent     # both conditions
type:meeting OR type:analysis   # either condition
NOT tag:archived                # negation
-tag:archived                   # shorthand for NOT (Obsidian compatible)
```

### Grouping

```
(type:meeting OR type:analysis) AND tag:active
```

### Combined: Metadata + Text

```
type:meeting tag:urgent deploy  # implicit AND between all terms
# = type:meeting AND tag:urgent AND (ripgrep "deploy")
```

## Implicit AND Rule

When terms are separated by spaces without an explicit operator, they are
combined with AND. This matches Obsidian's behavior:

```
type:meeting deploy     --> AND(field("type","meeting"), text("deploy"))
tag:a tag:b             --> AND(field("tag","a"), field("tag","b"))
foo bar baz             --> AND(text("foo"), AND(text("bar"), text("baz")))
```

## Operator Precedence

From lowest to highest:

1. `OR`
2. `AND` (explicit) / implicit AND (same precedence)
3. `NOT` / `-`

So `a b OR c` parses as `(a AND b) OR c`, not `a AND (b OR c)`.

## Formal Grammar (EBNF)

```ebnf
query          = or_expr ;
or_expr        = and_expr { "OR" and_expr } ;
and_expr       = not_expr { ("AND" | implicit_and) not_expr } ;
not_expr       = ("NOT" | "-") not_expr | primary_expr ;
primary_expr   = field_filter | text_term | regex_term
               | has_filter | task_filter | "(" or_expr ")" ;

field_filter   = field_name ":" field_value ;
field_name     = "type" | "tag" | "path" | "file" | "folder" | "status"
               | "created" | "modified" | "day" | "priority"
               | identifier ;            (* extensible: any frontmatter/inline key *)
field_value    = comparison_value | range_value | bare_value ;
comparison_value = (">" | ">=" | "<" | "<=") value ;
range_value    = value ".." value ;
bare_value     = quoted_string | unquoted_token ;

has_filter     = "has" ":" has_target ;
has_target     = "tags" | "aliases" | "tasks" | "outlinks" | "inlinks"
               | "frontmatter" | identifier ;

task_filter    = ("task" | "task-todo" | "task-done") ":" quoted_string ;

text_term      = quoted_string | unquoted_word ;
regex_term     = "/" regex_body "/" ;

quoted_string  = '"' { any_char } '"' ;
unquoted_word  = { non_whitespace - special_char } ;
identifier     = letter { letter | digit | "-" | "_" } ;
```

## Token Types

```lua
M.TK = {
  TEXT   = "TEXT",     -- plain text term (unquoted word)
  QUOTED = "QUOTED",  -- "quoted string"
  REGEX  = "REGEX",   -- /regex/
  FIELD  = "FIELD",   -- field_name:value (single token)
  AND    = "AND",     -- AND keyword
  OR     = "OR",      -- OR keyword
  NOT    = "NOT",     -- NOT keyword
  MINUS  = "MINUS",   -- - prefix (NOT shorthand)
  LPAREN = "LPAREN",  -- (
  RPAREN = "RPAREN",  -- )
  HAS    = "HAS",     -- has:target
  TASK   = "TASK",    -- task:"", task-todo:"", task-done:""
  EOF    = "EOF",     -- end of input
}
```

## AST Node Types

```lua
-- Boolean operators
{ type = "and", left = node, right = node }
{ type = "or",  left = node, right = node }
{ type = "not", operand = node }

-- Leaf nodes: text search (dispatched to ripgrep)
{ type = "text",  value = "deploy", quoted = false }
{ type = "text",  value = "exact phrase", quoted = true }
{ type = "regex", pattern = "^##\\s+Results" }

-- Leaf nodes: metadata filter (evaluated against vault index)
{ type = "field", name = "type",     op = "=",  value = "meeting" }
{ type = "field", name = "priority", op = ">",  value = "3" }
{ type = "field", name = "priority", op = "..", value = "1", value2 = "3" }
{ type = "field", name = "created",  op = ">",  value = "7d" }

-- Special metadata filters
{ type = "has",  target = "tags" }
{ type = "task", variant = "any",  pattern = "" }
{ type = "task", variant = "todo", pattern = "" }
{ type = "task", variant = "done", pattern = "" }
```

## Node Classification: Metadata vs Text

The filter pipeline classifies each AST leaf as either "metadata" (evaluable
from the vault index) or "text" (requires ripgrep):

| Node Type  | Classification | Evaluation Source               |
|------------|----------------|---------------------------------|
| `field`    | Metadata       | `vault_index.files[].field`     |
| `has`      | Metadata       | `vault_index.files[].field`     |
| `task`     | Metadata       | `vault_index.files[].tasks`     |
| `text`     | Text           | Ripgrep content search          |
| `regex`    | Text           | Ripgrep content search          |
| `and`      | Mixed          | Depends on children             |
| `or`       | Mixed          | Depends on children             |
| `not`      | Mixed          | Depends on operand              |

## Comparison with Existing DQL Parser

| Aspect               | DQL Parser (`query/parser.lua`)      | Search Query Parser (new)         |
|----------------------|--------------------------------------|-----------------------------------|
| Purpose              | SQL-like table/list/task queries     | Interactive search filtering      |
| Syntax style         | `TABLE ... FROM ... WHERE ...`       | `field:value term AND term`       |
| Implicit AND         | No                                   | Yes (space = AND)                 |
| Field access         | `file.name`, `frontmatter.type`      | `type:`, `tag:`, `file:`          |
| Boolean operators    | `AND`, `OR`, `NOT` (in WHERE)        | `AND`, `OR`, `NOT`, `-`           |
| Comparison ops       | `=`, `!=`, `<`, `>`, `<=`, `>=`      | `>`, `>=`, `<`, `<=`, `..`        |
| Functions            | `date()`, `dur()`, `contains()`, etc.| None (simpler)                    |
| Type system          | Rich (Date, Duration, Link, arrays)  | Simple (string, number, date)     |
| Output               | Table rows, list items, tasks        | File paths for fzf display        |
| Evaluation target    | Query index pages                    | Vault index entries               |
| Reusable patterns    | Tokenizer structure, parser state    | Same approach, different tokens   |

## Tokenizer Design Notes

### Field Detection
The tokenizer recognizes `field:value` as a single FIELD token by checking if
an unquoted word contains `:` and the prefix matches known field names or
follows the identifier pattern.

Known field names: `type`, `tag`, `path`, `file`, `folder`, `status`,
`created`, `modified`, `day`, `priority`.

Unknown prefixes (e.g., `foo:bar`) are treated as generic field filters that
check both `frontmatter.foo` and `inline_fields.foo`.

### Minus Prefix
`-` is NOT shorthand only when it appears at the start of a term, not inside
a word or as a hyphenated field name. Detection: `-` followed by a
non-whitespace character at a word boundary.

### Comparison Operators in Field Values
After the `:` in a field filter, the tokenizer checks for `>`, `>=`, `<`, `<=`
prefixes in the value portion and for `..` as a range separator.

### Regex Terms
`/pattern/` is recognized by leading `/` and scanning for closing `/`.
The regex body is passed verbatim to ripgrep.

## Parser Design Notes

### Implicit AND
When two primary expressions appear adjacent without an explicit operator,
insert AND. This is detected by the parser when the next token is a valid
start of a primary expression (TEXT, QUOTED, REGEX, FIELD, HAS, TASK, LPAREN,
MINUS) but not OR/AND/RPAREN/EOF.

### Left-Associative Loop Pattern
Following the existing DQL parser, each precedence level uses a while loop:

```lua
local function parse_or(P)
  local left = parse_and(P)
  while P:peek().type == TK.OR do
    P:advance()
    local right = parse_and(P)
    left = { type = "or", left = left, right = right }
  end
  return left
end
```

### Error Handling
- Unmatched parentheses: parser returns `nil, "Expected ')' at position X"`
- Unmatched quotes: tokenizer returns error
- Unknown field after parsing: treated as generic field (not an error)
- Empty field value (e.g., `type:`): interpreted as "has this field"
