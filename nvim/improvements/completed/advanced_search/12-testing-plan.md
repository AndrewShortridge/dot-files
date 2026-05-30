# Testing Plan

## Test Framework

Tests use Lua's built-in `assert()` or a minimal test runner. Test files
live alongside source files or in a dedicated `tests/` directory.

## Unit Tests

### 1. Tokenizer Tests (`search_query_spec.lua`)

```lua
-- 1.1 Plain text
assert_tokens("deploy", { {TK.TEXT, "deploy"}, {TK.EOF} })

-- 1.2 Quoted text
assert_tokens('"exact phrase"', { {TK.QUOTED, "exact phrase"}, {TK.EOF} })

-- 1.3 Field filter
assert_tokens("type:meeting", { {TK.FIELD, {name="type", op="=", value="meeting"}}, {TK.EOF} })

-- 1.4 Field with comparison
assert_tokens("priority:>3", { {TK.FIELD, {name="priority", op=">", value="3"}}, {TK.EOF} })
assert_tokens("priority:>=3", { {TK.FIELD, {name="priority", op=">=", value="3"}}, {TK.EOF} })
assert_tokens("priority:<2", { {TK.FIELD, {name="priority", op="<", value="2"}}, {TK.EOF} })

-- 1.5 Field with range
assert_tokens("created:2026-01..2026-02", {
  {TK.FIELD, {name="created", op="..", value="2026-01", value2="2026-02"}}, {TK.EOF}
})

-- 1.6 Boolean keywords
assert_tokens("a AND b", { {TK.TEXT, "a"}, {TK.AND}, {TK.TEXT, "b"}, {TK.EOF} })
assert_tokens("a OR b", { {TK.TEXT, "a"}, {TK.OR}, {TK.TEXT, "b"}, {TK.EOF} })
assert_tokens("NOT a", { {TK.NOT}, {TK.TEXT, "a"}, {TK.EOF} })

-- 1.7 NOT shorthand
assert_tokens("-tag:archived", { {TK.MINUS}, {TK.FIELD, {name="tag", op="=", value="archived"}}, {TK.EOF} })

-- 1.8 Regex
assert_tokens("/^## Results/", { {TK.REGEX, "^## Results"}, {TK.EOF} })

-- 1.9 Mixed query
assert_tokens("type:meeting deploy", {
  {TK.FIELD, {name="type", op="=", value="meeting"}}, {TK.TEXT, "deploy"}, {TK.EOF}
})

-- 1.10 Has filter
assert_tokens("has:tags", { {TK.HAS, "tags"}, {TK.EOF} })

-- 1.11 Task filter
assert_tokens('task-todo:""', { {TK.TASK, {variant="todo", pattern=""}}, {TK.EOF} })

-- 1.12 Parentheses
assert_tokens("(a OR b)", {
  {TK.LPAREN}, {TK.TEXT, "a"}, {TK.OR}, {TK.TEXT, "b"}, {TK.RPAREN}, {TK.EOF}
})

-- 1.13 Empty string
assert_eq(M.tokenize(""), nil, "Empty query")
-- or: assert_tokens("", { {TK.EOF} })

-- 1.14 Error: unclosed quote
local _, err = M.tokenize('"unterminated')
assert(err:find("Unterminated"))

-- 1.15 Error: unclosed regex
local _, err = M.tokenize("/unclosed")
assert(err:find("Unterminated"))

-- 1.16 Case-insensitive keywords
assert_tokens("a and b", { {TK.TEXT, "a"}, {TK.AND}, {TK.TEXT, "b"}, {TK.EOF} })
assert_tokens("a Or b", { {TK.TEXT, "a"}, {TK.OR}, {TK.TEXT, "b"}, {TK.EOF} })

-- 1.17 Generic field (unknown name)
assert_tokens("foo:bar", { {TK.FIELD, {name="foo", op="=", value="bar"}}, {TK.EOF} })

-- 1.18 Non-field colon (numeric prefix)
assert_tokens("10:30", { {TK.TEXT, "10:30"}, {TK.EOF} })

-- 1.19 URL-like text
assert_tokens("http://example.com", { {TK.TEXT, "http://example.com"}, {TK.EOF} })
```

### 2. Parser Tests (`search_query_spec.lua`)

```lua
-- 2.1 Single text term
local ast = parse("deploy")
assert_eq(ast, { type = "text", value = "deploy", quoted = false })

-- 2.2 Implicit AND
local ast = parse("a b")
assert_eq(ast, { type = "and",
  left = { type = "text", value = "a" },
  right = { type = "text", value = "b" }
})

-- 2.3 Explicit OR
local ast = parse("a OR b")
assert_eq(ast, { type = "or",
  left = { type = "text", value = "a" },
  right = { type = "text", value = "b" }
})

-- 2.4 Precedence: a b OR c = (a AND b) OR c
local ast = parse("a b OR c")
assert_eq(ast.type, "or")
assert_eq(ast.left.type, "and")
assert_eq(ast.left.left.value, "a")
assert_eq(ast.left.right.value, "b")
assert_eq(ast.right.value, "c")

-- 2.5 NOT
local ast = parse("NOT a")
assert_eq(ast, { type = "not", operand = { type = "text", value = "a" } })

-- 2.6 Minus shorthand
local ast = parse("-tag:x")
assert_eq(ast.type, "not")
assert_eq(ast.operand.type, "field")
assert_eq(ast.operand.name, "tag")

-- 2.7 Grouping
local ast = parse("(a OR b) AND c")
assert_eq(ast.type, "and")
assert_eq(ast.left.type, "or")
assert_eq(ast.right.value, "c")

-- 2.8 Complex query
local ast = parse("type:meeting tag:urgent NOT tag:archived deploy")
assert_eq(ast.type, "and")  -- top-level AND chain

-- 2.9 Field with comparison
local ast = parse("priority:>3")
assert_eq(ast, { type = "field", name = "priority", op = ">", value = "3" })

-- 2.10 Multiple NOT
local ast = parse("NOT NOT a")
assert_eq(ast.type, "not")
assert_eq(ast.operand.type, "not")
assert_eq(ast.operand.operand.value, "a")

-- 2.11 Error: unmatched paren
local ast, err = M.parse_query("(a OR b")
assert(ast == nil)
assert(err:find("Expected"))

-- 2.12 Error: empty query
local ast, err = M.parse_query("")
assert(ast == nil)

-- 2.13 Three-way implicit AND
local ast = parse("a b c")
-- Should be AND(AND(a, b), c) -- left-associative
assert_eq(ast.type, "and")
assert_eq(ast.left.type, "and")
```

### 3. Filter Evaluation Tests (`search_filter_spec.lua`)

#### Mock Entry Helper
```lua
local function mock_entry(overrides)
  return vim.tbl_deep_extend("force", {
    rel_path = "test/note.md",
    abs_path = "/vault/test/note.md",
    basename = "note",
    basename_lower = "note",
    folder = "test",
    mtime = os.time(),
    size = 100,
    ctime = os.time() - 86400,
    frontmatter = {},
    aliases = {},
    tags = {},
    headings = {},
    heading_slugs = {},
    block_ids = {},
    outlinks = {},
    tasks = {},
    inline_fields = {},
    day = nil,
  }, overrides or {})
end
```

#### Field Filter Tests
```lua
-- 3.1 type:meeting matches
local entry = mock_entry({ frontmatter = { type = "meeting" } })
assert(match("type:meeting", entry) == true)

-- 3.2 type:meeting doesn't match analysis
local entry = mock_entry({ frontmatter = { type = "analysis" } })
assert(match("type:meeting", entry) == false)

-- 3.3 type match is case-insensitive
local entry = mock_entry({ frontmatter = { type = "Meeting" } })
assert(match("type:meeting", entry) == true)

-- 3.4 tag:project matches exact
local entry = mock_entry({ tags = { "project" } })
assert(match("tag:project", entry) == true)

-- 3.5 tag:project matches child (parent expansion)
local entry = mock_entry({ tags = { "project", "project/active" } })
assert(match("tag:project", entry) == true)
assert(match("tag:project/active", entry) == true)

-- 3.6 tag:project doesn't match unrelated
local entry = mock_entry({ tags = { "meeting" } })
assert(match("tag:project", entry) == false)

-- 3.7 path:Projects/ matches prefix
local entry = mock_entry({ rel_path = "Projects/Alpha/note.md" })
assert(match("path:Projects/", entry) == true)
assert(match("path:Areas/", entry) == false)

-- 3.8 file:Dashboard matches substring
local entry = mock_entry({ basename = "Dashboard" })
assert(match("file:Dashboard", entry) == true)
assert(match("file:dash", entry) == true)  -- case-insensitive
assert(match("file:xyz", entry) == false)

-- 3.9 priority comparison
local entry = mock_entry({ frontmatter = { priority = 4 } })
assert(match("priority:>3", entry) == true)
assert(match("priority:>4", entry) == false)
assert(match("priority:>=4", entry) == true)
assert(match("priority:1..5", entry) == true)
assert(match("priority:1..3", entry) == false)

-- 3.10 status from inline_fields
local entry = mock_entry({ inline_fields = { status = "active" } })
assert(match("status:active", entry) == true)
assert(match("status:inactive", entry) == false)
```

#### Date Filter Tests
```lua
-- 3.11 modified:>7d
local entry = mock_entry({ mtime = os.time() - 86400 * 3 })  -- 3 days ago
assert(match("modified:>7d", entry) == true)

local entry = mock_entry({ mtime = os.time() - 86400 * 10 })  -- 10 days ago
assert(match("modified:>7d", entry) == false)

-- 3.12 modified:today
local today_start = os.time({ year = ..., month = ..., day = ..., hour = 0, min = 0, sec = 0 })
local entry = mock_entry({ mtime = today_start + 3600 })  -- 1am today
assert(match("modified:today", entry) == true)

-- 3.13 created with ctime fallback
local entry = mock_entry({ ctime = nil, mtime = os.time() - 86400 })
assert(match("created:>7d", entry) == true)  -- falls back to mtime
```

#### Has Filter Tests
```lua
-- 3.14 has:tags
assert(match("has:tags", mock_entry({ tags = { "a" } })) == true)
assert(match("has:tags", mock_entry({ tags = {} })) == false)

-- 3.15 has:aliases
assert(match("has:aliases", mock_entry({ aliases = { "alt" } })) == true)
assert(match("has:aliases", mock_entry({ aliases = {} })) == false)

-- 3.16 has:tasks
assert(match("has:tasks", mock_entry({ tasks = { { text = "t", status = " " } } })) == true)
assert(match("has:tasks", mock_entry({ tasks = {} })) == false)
```

#### Task Filter Tests
```lua
-- 3.17 task-todo:""
local entry = mock_entry({ tasks = { { text = "t", status = " ", completed = false } } })
assert(match('task-todo:""', entry) == true)

-- 3.18 task-done:""
local entry = mock_entry({ tasks = { { text = "t", status = "x", completed = true } } })
assert(match('task-done:""', entry) == true)

-- 3.19 task:"" (any task)
assert(match('task:""', mock_entry({ tasks = { { text = "t" } } })) == true)
assert(match('task:""', mock_entry({ tasks = {} })) == false)
```

#### Boolean Combiner Tests
```lua
-- 3.20 AND
local entry = mock_entry({ frontmatter = { type = "meeting" }, tags = { "urgent" } })
assert(match("type:meeting AND tag:urgent", entry) == true)
assert(match("type:analysis AND tag:urgent", entry) == false)

-- 3.21 OR
local entry = mock_entry({ frontmatter = { type = "meeting" } })
assert(match("type:meeting OR type:analysis", entry) == true)
local entry = mock_entry({ frontmatter = { type = "analysis" } })
assert(match("type:meeting OR type:analysis", entry) == true)
local entry = mock_entry({ frontmatter = { type = "finding" } })
assert(match("type:meeting OR type:analysis", entry) == false)

-- 3.22 NOT
local entry = mock_entry({ tags = { "archived" } })
assert(match("NOT tag:archived", entry) == false)
assert(match("-tag:archived", entry) == false)
local entry = mock_entry({ tags = { "active" } })
assert(match("NOT tag:archived", entry) == true)

-- 3.23 Complex: (type:meeting OR type:analysis) AND tag:active
local entry = mock_entry({ frontmatter = { type = "meeting" }, tags = { "active" } })
assert(match("(type:meeting OR type:analysis) AND tag:active", entry) == true)
local entry = mock_entry({ frontmatter = { type = "meeting" }, tags = { "inactive" } })
assert(match("(type:meeting OR type:analysis) AND tag:active", entry) == false)
```

### 4. AST Splitting Tests

```lua
-- 4.1 Pure metadata
local meta, text = split_ast(parse("type:meeting tag:urgent"))
assert(meta ~= nil)
assert(#text == 0)

-- 4.2 Pure text
local meta, text = split_ast(parse("deploy production"))
assert(meta == nil)
assert(#text == 2)

-- 4.3 Mixed
local meta, text = split_ast(parse("type:meeting deploy"))
assert(meta ~= nil)  -- type:meeting
assert(#text == 1)    -- deploy

-- 4.4 Nested boolean
local meta, text = split_ast(parse("type:meeting AND (tag:a OR tag:b)"))
assert(meta ~= nil)
assert(#text == 0)
```

### 5. Date Parsing Tests

```lua
-- 5.1 Relative dates
local now = os.time()
assert(math.abs(resolve_date("today") - start_of_today()) < 2)
assert(math.abs(resolve_date("7d") - (now - 7 * 86400)) < 2)
assert(math.abs(resolve_date("30d") - (now - 30 * 86400)) < 2)

-- 5.2 Absolute dates
assert(resolve_date("2026-01-15") == os.time({year=2026, month=1, day=15, hour=0, min=0, sec=0}))

-- 5.3 Partial dates
assert(resolve_date("2026-01") == os.time({year=2026, month=1, day=1, hour=0, min=0, sec=0}))

-- 5.4 Named periods
assert(resolve_date("this-week") ~= nil)
assert(resolve_date("this-month") ~= nil)

-- 5.5 Invalid
assert(resolve_date("invalid") == nil)
assert(resolve_date("") == nil)
```

## Integration Tests (In Neovim)

### 6. Metadata-Only Search
```
:VaultSearchAdvanced
> type:meeting
Expected: Only files with type: meeting in frontmatter
Compare:  :VaultSearchType with "meeting" selection
```

### 7. Text-Only Search
```
:VaultSearchAdvanced
> deploy
Expected: Same results as :VaultSearch with "deploy"
```

### 8. Combined Search
```
:VaultSearchAdvanced
> type:meeting deploy
Expected: Intersection of type=meeting files and files containing "deploy"
```

### 9. Boolean Operators
```
type:meeting OR type:analysis    → union
tag:project NOT tag:archived     → project without archived
(type:meeting OR type:analysis) AND tag:urgent → correct intersection
```

### 10. Date Filters
```
modified:>7d     → only recently modified files
created:today    → files created today
```

### 11. Saved Advanced Search
```
1. Run :VaultSearchAdvanced with "type:meeting tag:active"
2. Run :VaultSearchSave "Active meetings"
3. Check .vault-searches.json has "advanced": true
4. Run :VaultSearchList, select "Active meetings"
5. Verify it executes correctly
```

### 12. Graceful Degradation
```
1. :VaultIndexRebuild (force rebuild)
2. Immediately run :VaultSearchAdvanced with "type:meeting deploy"
3. If index not ready: should fall back to plain ripgrep with notification
```

### 13. Parse Error Handling
```
:VaultSearchAdvanced
> type:meeting AND AND     → error notification
> (a OR b                  → error notification
> No crash, can retry
```

## Performance Benchmarks

### 14. Metadata Filter Speed
```lua
-- On 500-file vault
local start = vim.loop.hrtime()
for _, entry in pairs(idx.files) do
  search_filter.match_entry(complex_ast, entry)
end
local elapsed = (vim.loop.hrtime() - start) / 1e6  -- ms
assert(elapsed < 10, "Metadata filtering took " .. elapsed .. "ms")
```

### 15. Live Search Responsiveness
```
-- Measure keystroke to result display
-- Target: < 300ms (including ripgrep and fzf render)
```

### 16. Parser Speed
```lua
local start = vim.loop.hrtime()
for i = 1, 1000 do
  search_query.parse_query("type:meeting tag:urgent modified:>7d deploy")
end
local elapsed = (vim.loop.hrtime() - start) / 1e6
assert(elapsed < 50, "1000 parses took " .. elapsed .. "ms")
```
