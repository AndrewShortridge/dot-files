# 34. Unit Tests for Search Query, Search Filter, and Date Utilities

**Priority:** Medium
**Status:** Planned
**Scope:** `search_query.lua`, `search_filter.lua`, `date_utils.lua`

## Summary

Add comprehensive unit tests for the three core modules of the advanced search
system: the tokenizer/parser (`search_query.lua`), the metadata filter evaluator
(`search_filter.lua`), and the shared date utilities (`date_utils.lua`). These
modules are pure (or near-pure) logic with well-defined inputs and outputs,
making them ideal targets for automated testing. The tests catch regressions in
query parsing, boolean evaluation, date resolution, operator inversion, and task
metadata matching.

## Test Framework Analysis

### Existing Infrastructure

The project already has a test runner in `tests/test_vault_fixes.lua` that uses
a custom minimal framework:

- **Runner:** `nvim --headless -u NONE -l tests/test_vault_fixes.lua`
- **Harness:** Custom `test(name, fn)` with `pcall` wrapping and pass/fail
  counters.
- **Assertions:** `assert_eq(got, expected, msg)`, `assert_true(val, msg)`,
  `assert_false(val, msg)`, `assert_match(str, pattern, msg)`.
- **No external dependencies** (no plenary, busted, or mini.test).
- **Runs in headless Neovim** (has access to `vim.*` APIs for `vim.inspect`,
  `vim.fn`, `vim.tbl_deep_extend`, etc.).

### Recommendation

Continue with the same custom minimal framework. The modules under test are
mostly pure Lua (`search_query.lua` has zero requires; `date_utils.lua` has zero
requires). `search_filter.lua` requires `config`, `date_utils`, `vault_index`,
and `filter_utils`, but for unit tests we can construct AST nodes and mock
entries directly, calling `M.match_entry()` without needing a live vault index.

**One important consideration:** `search_filter.lua` uses `require()` at module
load time for `config`, `date_utils`, `vault_index`, and `filter_utils`. For the
test runner invoked with `-u NONE`, we need to set `package.path` so that
`require("andrew.vault.search_filter")` resolves correctly. The existing test
file already runs in this environment successfully using `vim.fn` and
`vim.startswith`, confirming that the `-u NONE` headless environment provides
sufficient vim API.

### Additional Assertions Needed

Add `assert_table_eq` for deep table comparison (AST nodes) and `assert_nil`
for cleaner nil checks:

```lua
local function assert_table_eq(got, expected, msg)
  local gs = vim.inspect(got)
  local es = vim.inspect(expected)
  if gs ~= es then
    error((msg or "") .. "\n  expected: " .. es .. "\n  got:      " .. gs)
  end
end

local function assert_nil(val, msg)
  if val ~= nil then
    error((msg or "expected nil") .. ", got: " .. vim.inspect(val))
  end
end
```

## Detailed Test Plan

### File: `tests/search_query_spec.lua`

Tests the tokenizer (`M.parse_query` which calls `tokenize` + `parse`
internally) and the parser (AST structure). Since `tokenize` and `parse` are
local, we test them through the public `M.parse_query()` API and verify the
resulting AST shape.

#### Tokenizer Verification (via AST output)

We cannot call `tokenize()` directly since it is local. However, we can verify
tokenizer behavior through the AST that `parse_query` produces. For cases where
we need to verify tokens specifically (e.g., error messages), we test the error
string returned by `parse_query`.

#### Parser / AST Structure Tests

| # | Test Name | Query | Expected AST |
|---|-----------|-------|-------------|
| 1 | Single text term | `"deploy"` | `{type="text", value="deploy", quoted=false}` |
| 2 | Quoted text | `'"exact phrase"'` | `{type="text", value="exact phrase", quoted=true}` |
| 3 | Regex pattern | `"/^## Results/"` | `{type="regex", pattern="^## Results"}` |
| 4 | Regex with flags | `"/pattern/im"` | `{type="regex", pattern="pattern", flags="im"}` |
| 5 | Field equals | `"type:meeting"` | `{type="field", name="type", op="=", value="meeting"}` |
| 6 | Field greater than | `"priority:>3"` | `{type="field", name="priority", op=">", value="3"}` |
| 7 | Field greater or equal | `"priority:>=3"` | `{type="field", name="priority", op=">=", value="3"}` |
| 8 | Field less than | `"priority:<2"` | `{type="field", name="priority", op="<", value="2"}` |
| 9 | Field less or equal | `"priority:<=5"` | `{type="field", name="priority", op="<=", value="5"}` |
| 10 | Field range | `"created:2026-01..2026-02"` | `{type="field", name="created", op="..", value="2026-01", value2="2026-02"}` |
| 11 | Has filter | `"has:tags"` | `{type="has", target="tags"}` |
| 12 | Task any | `'task:""'` | `{type="task", variant="any", pattern=""}` |
| 13 | Task todo | `'task-todo:""'` | `{type="task", variant="todo", pattern=""}` |
| 14 | Task done | `'task-done:""'` | `{type="task", variant="done", pattern=""}` |
| 15 | Task with pattern | `"task:review"` | `{type="task", variant="any", pattern="review"}` |
| 16 | Task meta due | `"task-due:<7d"` | `{type="task", variant="meta", meta_field="due", op="<", value="7d"}` |
| 17 | Task meta priority | `"task-priority:<=2"` | `{type="task", variant="meta", meta_field="priority", op="<=", value="2"}` |
| 18 | Task meta state | `"task-state:in-progress"` | `{type="task", variant="meta", meta_field="state", op="=", value="in-progress"}` |
| 19 | Task meta repeat empty | `'task-repeat:""'` | `{type="task", variant="meta", meta_field="repeat", op="=", value=""}` |
| 20 | Graph neighbors | `"graph:neighbors"` | `{type="graph", depth=1, direction="both", center="current"}` |
| 21 | Graph extended | `"graph:extended"` | `{type="graph", depth=2, direction="both", center="current"}` |
| 22 | Graph params | `"graph:depth=3,dir=forward"` | `{type="graph", depth=3, direction="forward", center="current"}` |
| 23 | Graph with center | `"graph:depth=2,center=Dashboard"` | `{type="graph", depth=2, direction="both", center="Dashboard"}` |
| 24 | Implicit AND | `"a b"` | `{type="and", left={type="text",value="a"...}, right={type="text",value="b"...}}` |
| 25 | Explicit AND keyword | `"a AND b"` | `{type="and", ...}` |
| 26 | OR | `"a OR b"` | `{type="or", ...}` |
| 27 | NOT prefix | `"NOT a"` | `{type="not", operand={type="text", value="a"...}}` |
| 28 | Minus prefix | `"-tag:x"` | `{type="not", operand={type="field", name="tag"...}}` |
| 29 | Parenthesized group | `"(a OR b) AND c"` | `{type="and", left={type="or"...}, right={type="text"...}}` |
| 30 | Precedence: AND > OR | `"a b OR c"` | `{type="or", left={type="and"...}, right={type="text"...}}` |
| 31 | Three-way implicit AND | `"a b c"` | Left-associative AND chain |
| 32 | Double NOT | `"NOT NOT a"` | `{type="not", operand={type="not", operand=...}}` |
| 33 | Case-insensitive keywords | `"a and b"` | `{type="and", ...}` |
| 34 | URL not parsed as field | `"http://example.com"` | `{type="text", value="http://example.com"}` |
| 35 | Numeric prefix colon | `"10:30"` | `{type="text", value="10:30"}` |
| 36 | Group directive extracted | `"group:file type:meeting"` | AST for `type:meeting`, group_mode="file" |
| 37 | Group-only query | `"group:folder"` | `{type="match_all"}`, group_mode="folder" |
| 38 | Field with quoted value | `'type:"my meeting"'` | `{type="field", name="type", op="=", value="my meeting"}` |
| 39 | Empty field (exists) | `"type:"` | `{type="field", name="type", op="=", value=""}` |

#### Error Cases

| # | Test Name | Query | Expected |
|---|-----------|-------|----------|
| 40 | Empty query | `""` | `nil, "Empty query"` |
| 41 | Whitespace-only query | `"   "` | `nil, "Empty query"` |
| 42 | Unterminated quote | `'"unterminated'` | `nil, "Unterminated quoted string..."` |
| 43 | Unterminated regex | `"/unclosed"` | `nil, "Unterminated regex..."` |
| 44 | Unmatched open paren | `"(a OR b"` | `nil, "Expected RPAREN..."` |
| 45 | Dangling AND | `"a AND"` | `nil` (unexpected EOF) |
| 46 | Double operator | `"a AND AND b"` | `nil` (unexpected token) |

#### Utility Function Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 47 | edit_distance identical | `"test", "test"` | `0` |
| 48 | edit_distance one sub | `"test", "tast"` | `1` |
| 49 | edit_distance insertion | `"ab", "abc"` | `1` |
| 50 | edit_distance deletion | `"abc", "ac"` | `1` |
| 51 | edit_distance empty | `"", "abc"` | `3` |
| 52 | suggest_field close match | `"typ", {"type","tag","path"}` | `"type", 1` |
| 53 | suggest_field no match | `"xyz", {"type","tag","path"}` | `nil` |
| 54 | suggest_field short name | `"ty", {"type"}` | `nil` (skip < 3 chars) |

---

### File: `tests/search_filter_spec.lua`

Tests `M.match_entry()` and `M.split_ast()` against mock vault index entries.
Since `match_entry` operates on AST nodes (not raw query strings), we first
parse with `search_query.parse_query()` then pass the AST to `match_entry`.

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

| # | Test Name | Query | Entry | Expected |
|---|-----------|-------|-------|----------|
| 1 | type equals match | `type:meeting` | `frontmatter={type="meeting"}` | true |
| 2 | type equals no match | `type:meeting` | `frontmatter={type="analysis"}` | false |
| 3 | type case insensitive | `type:meeting` | `frontmatter={type="Meeting"}` | true |
| 4 | tag match | `tag:project` | `tags={"project"}` | true |
| 5 | tag no match | `tag:project` | `tags={"meeting"}` | false |
| 6 | tag hierarchical | `tag:project` | `tags={"project/active"}` | true |
| 7 | path prefix match | `path:Projects/` | `rel_path="Projects/Alpha/note.md"` | true |
| 8 | path prefix no match | `path:Areas/` | `rel_path="Projects/Alpha/note.md"` | false |
| 9 | file substring match | `file:Dash` | `basename="Dashboard"` | true |
| 10 | file case insensitive | `file:dash` | `basename="Dashboard"` | true |
| 11 | file no match | `file:xyz` | `basename="Dashboard"` | false |
| 12 | priority greater than | `priority:>3` | `frontmatter={priority=4}` | true |
| 13 | priority not greater | `priority:>4` | `frontmatter={priority=4}` | false |
| 14 | priority range | `priority:1..5` | `frontmatter={priority=3}` | true |
| 15 | priority range miss | `priority:1..3` | `frontmatter={priority=4}` | false |
| 16 | status match | `status:active` | `frontmatter={status="active"}` | true |
| 17 | status from inline | `status:active` | `inline_fields={status="active"}` | true |
| 18 | folder exact match | `folder:Projects` | `folder="Projects"` | true |
| 19 | folder prefix match | `folder:Projects` | `folder="Projects/Alpha"` | true |
| 20 | alias match | `alias:alt` | `aliases={"alt"}` | true |
| 21 | empty field (exists) | `type:` | `frontmatter={type="meeting"}` | true |
| 22 | empty field (missing) | `type:` | `frontmatter={}` | false |

#### Date Filter Tests

| # | Test Name | Query | Entry | Expected |
|---|-----------|-------|-------|----------|
| 23 | modified today | `modified:today` | `mtime=<today 10am>` | true |
| 24 | modified not today | `modified:today` | `mtime=<2 days ago>` | false |
| 25 | modified < 7d (within) | `modified:<7d` | `mtime=<3 days ago>` | true |
| 26 | modified < 7d (outside) | `modified:<7d` | `mtime=<10 days ago>` | false |
| 27 | modified absolute date | `modified:2026-01-15` | `mtime=<Jan 15 noon>` | true |
| 28 | modified range | `modified:2026-01..2026-02` | `mtime=<Jan 20>` | true |
| 29 | created from frontmatter | `created:2026-01-15` | `frontmatter={created="2026-01-15T10:00:00"}` | true |
| 30 | created fallback to mtime | `created:<7d` | `mtime=<3 days ago>, ctime=nil, frontmatter={}` | true |

#### Has Filter Tests

| # | Test Name | Query | Entry | Expected |
|---|-----------|-------|-------|----------|
| 31 | has:tags true | `has:tags` | `tags={"a"}` | true |
| 32 | has:tags false | `has:tags` | `tags={}` | false |
| 33 | has:aliases true | `has:aliases` | `aliases={"alt"}` | true |
| 34 | has:aliases false | `has:aliases` | `aliases={}` | false |
| 35 | has:tasks true | `has:tasks` | `tasks={{text="t",status=" "}}` | true |
| 36 | has:tasks false | `has:tasks` | `tasks={}` | false |
| 37 | has:outlinks true | `has:outlinks` | `outlinks={{path="A"}}` | true |
| 38 | has:outlinks false | `has:outlinks` | `outlinks={}` | false |
| 39 | has:frontmatter true | `has:frontmatter` | `frontmatter={type="x"}` | true |
| 40 | has:frontmatter false | `has:frontmatter` | `frontmatter={}` | false |

#### Task Filter Tests

| # | Test Name | Query | Entry | Expected |
|---|-----------|-------|-------|----------|
| 41 | task any match | `task:""` | `tasks={{text="review",status=" "}}` | true |
| 42 | task any empty | `task:""` | `tasks={}` | false |
| 43 | task any pattern | `task:review` | `tasks={{text="Review PR",status=" "}}` | true |
| 44 | task any pattern miss | `task:deploy` | `tasks={{text="Review PR",status=" "}}` | false |
| 45 | task-todo match | `task-todo:""` | `tasks={{text="t",status=" ",completed=false}}` | true |
| 46 | task-todo skip done | `task-todo:""` | `tasks={{text="t",status="x",completed=true}}` | false |
| 47 | task-done match | `task-done:""` | `tasks={{text="t",status="x",completed=true}}` | true |
| 48 | task-done skip open | `task-done:""` | `tasks={{text="t",status=" ",completed=false}}` | false |

#### Task Metadata Filter Tests

| # | Test Name | Query | Entry | Expected |
|---|-----------|-------|-------|----------|
| 49 | task-due exists | `task-due:` | `tasks={{due="2026-03-01"}}` | true |
| 50 | task-due exists miss | `task-due:` | `tasks={{text="no due"}}` | false |
| 51 | task-due = today | `task-due:today` | `tasks={{due=<today str>}}` | true |
| 52 | task-priority <= 2 | `task-priority:<=2` | `tasks={{priority=1}}` | true |
| 53 | task-priority <= 2 fail | `task-priority:<=2` | `tasks={{priority=3}}` | false |
| 54 | task-priority range | `task-priority:1..3` | `tasks={{priority=2}}` | true |
| 55 | task-repeat exists | `task-repeat:""` | `tasks={{repeat_rule="every 1d"}}` | true |
| 56 | task-repeat match | `task-repeat:weekly` | `tasks={{repeat_rule="every 1 week"}}` | false |

#### Boolean Combiner Tests

| # | Test Name | Query | Entry | Expected |
|---|-----------|-------|-------|----------|
| 57 | AND both true | `type:meeting AND tag:urgent` | both match | true |
| 58 | AND one false | `type:analysis AND tag:urgent` | type fails | false |
| 59 | OR one true | `type:meeting OR type:analysis` | type=meeting | true |
| 60 | OR both false | `type:meeting OR type:analysis` | type=finding | false |
| 61 | NOT true | `NOT tag:archived` | tags={"archived"} | false |
| 62 | NOT false | `NOT tag:archived` | tags={"active"} | true |
| 63 | Complex nested | `(type:meeting OR type:analysis) AND tag:active` | meeting+active | true |
| 64 | Complex nested fail | `(type:meeting OR type:analysis) AND tag:active` | meeting+inactive | false |

#### split_ast Tests

| # | Test Name | Query | Expected Mode |
|---|-----------|-------|--------------|
| 65 | Pure metadata | `type:meeting tag:urgent` | "metadata_only" |
| 66 | Pure text | `deploy production` | "text_only" |
| 67 | Mixed AND | `type:meeting deploy` | "metadata_then_text" |
| 68 | Mixed OR | `type:meeting OR deploy` | "mixed_or" |
| 69 | match_all | group-only query | mode="metadata_only", match_all=true |

#### ast_contains_graph Tests

| # | Test Name | Query | Expected |
|---|-----------|-------|----------|
| 70 | No graph | `type:meeting` | false |
| 71 | Has graph | `graph:neighbors` | true |
| 72 | Graph in AND | `graph:neighbors type:meeting` | true |
| 73 | Graph in NOT | `NOT graph:extended` | true |

---

### File: `tests/date_utils_spec.lua`

Tests all exported functions from `date_utils.lua`. Since this module has zero
requires and uses only `os.time` and `os.date`, it is fully testable in headless
mode.

#### start_of_day Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 1 | Strips time components | `{year=2026,month=3,day=2,hour=14,min=30,sec=45}` | Timestamp at 00:00:00 |
| 2 | Already midnight | `{year=2026,month=1,day=1,hour=0,min=0,sec=0}` | Same timestamp |

#### same_day Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 3 | Same day different times | Jan 15 noon, Jan 15 midnight | true |
| 4 | Different days | Jan 15, Jan 16 | false |
| 5 | Year boundary | Dec 31, Jan 1 | false |

#### parse_iso_datetime Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 6 | Full datetime | `"2026-01-15T10:30:00"` | Matches os.time({year=2026,month=1,day=15,hour=10,min=30,sec=0}) |
| 7 | Date only | `"2026-01-15"` | Timestamp at 00:00:00 |
| 8 | Date only custom hour | `"2026-01-15", 12` | Timestamp at 12:00:00 |
| 9 | nil input | `nil` | nil |
| 10 | Empty string | `""` | nil |
| 11 | Invalid format | `"not-a-date"` | nil |
| 12 | Non-string input | `123` | nil |

#### resolve_date Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 13 | today | `"today"` | Start of today |
| 14 | yesterday | `"yesterday"` | Start of yesterday |
| 15 | Relative 7d | `"7d"` | Start of day 7 days ago |
| 16 | Relative 0d | `"0d"` | Start of today |
| 17 | Relative 30d | `"30d"` | Start of day 30 days ago |
| 18 | Absolute date | `"2026-01-15"` | Jan 15 2026 00:00:00 |
| 19 | Partial date | `"2026-01"` | Jan 1 2026 00:00:00 |
| 20 | this-week | `"this-week"` | Monday of current week |
| 21 | last-week | `"last-week"` | Monday of previous week |
| 22 | previous-week alias | `"previous-week"` | Same as last-week |
| 23 | this-month | `"this-month"` | 1st of current month |
| 24 | last-month | `"last-month"` | 1st of previous month |
| 25 | previous-month alias | `"previous-month"` | Same as last-month |
| 26 | Empty string | `""` | nil |
| 27 | nil | `nil` | nil |
| 28 | Invalid string | `"invalid"` | nil |
| 29 | Case insensitive | `"TODAY"` | Start of today |
| 30 | Case insensitive 2 | `"This-Week"` | Monday of current week |

#### is_relative_duration Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 31 | 7d | `"7d"` | true |
| 32 | 30d | `"30d"` | true |
| 33 | 0d | `"0d"` | true |
| 34 | today | `"today"` | false |
| 35 | absolute | `"2026-01-15"` | false |
| 36 | nil | `nil` | false |
| 37 | 7D uppercase | `"7D"` | true |

#### resolve_date_range Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 38 | this-week | `"this-week"` | Monday to next Monday |
| 39 | last-week | `"last-week"` | Previous Monday to this Monday |
| 40 | this-month | `"this-month"` | 1st of month to 1st of next month |
| 41 | last-month | `"last-month"` | 1st of prev month to 1st of this month |
| 42 | last-7d | `"last-7d"` | 7 days ago to end of today |
| 43 | last-30d | `"last-30d"` | 30 days ago to end of today |
| 44 | Non-range value | `"today"` | nil, nil |
| 45 | Empty | `""` | nil |
| 46 | nil | `nil` | nil |

#### resolve_date_string Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 47 | today | `"today"` | Today's date string (YYYY-MM-DD) |
| 48 | absolute | `"2026-01-15"` | `"2026-01-15"` |
| 49 | invalid | `"bogus"` | nil |

#### days_between Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 50 | Same day | `"2026-01-15", "2026-01-15"` | 0 |
| 51 | One day | `"2026-01-15", "2026-01-16"` | 1 |
| 52 | Negative | `"2026-01-16", "2026-01-15"` | -1 |
| 53 | Month boundary | `"2026-01-30", "2026-02-02"` | 3 |
| 54 | Leap year Feb | `"2024-02-28", "2024-03-01"` | 2 |
| 55 | Non-leap year Feb | `"2025-02-28", "2025-03-01"` | 1 |

#### date_add Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 56 | Add 1 day | `"2026-01-15", 1` | `"2026-01-16"` |
| 57 | Subtract 1 day | `"2026-01-15", -1` | `"2026-01-14"` |
| 58 | Cross month | `"2026-01-30", 3` | `"2026-02-02"` |
| 59 | Leap year | `"2024-02-28", 1` | `"2024-02-29"` |
| 60 | Year boundary | `"2025-12-31", 1` | `"2026-01-01"` |

#### format_date_short Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 61 | Standard date | `"2026-03-01"` | `"Mar 01"` |
| 62 | Invalid format | `"not-date"` | `"not-date"` |

#### truncate Tests

| # | Test Name | Input | Expected |
|---|-----------|-------|----------|
| 63 | Short enough | `"hello", 10` | `"hello"` |
| 64 | Exactly max | `"hello", 5` | `"hello"` |
| 65 | Truncated | `"hello world", 8` | 7 chars + ellipsis |
| 66 | nil input | `nil, 10` | `""` |

## Full Test Code

### `tests/search_query_spec.lua`

```lua
-- Unit tests for search_query.lua (tokenizer + parser)
-- Run with: nvim --headless -u NONE -l tests/search_query_spec.lua

-- Setup package path so require works
local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
package.path = config_dir .. "/lua/?.lua;" .. config_dir .. "/lua/?/init.lua;" .. package.path

local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    table.insert(errors, { name = name, err = tostring(err) })
    print("  FAIL: " .. name .. " -> " .. tostring(err))
  end
end

local function assert_eq(got, expected, msg)
  if got ~= expected then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

local function assert_true(val, msg)
  if not val then error((msg or "assertion failed") .. " (got falsy)") end
end

local function assert_false(val, msg)
  if val then error((msg or "assertion failed") .. " (got truthy)") end
end

local function assert_nil(val, msg)
  if val ~= nil then error((msg or "expected nil") .. ", got: " .. vim.inspect(val)) end
end

local function assert_match(str, pattern, msg)
  if not str or not str:match(pattern) then
    error((msg or "") .. " string '" .. tostring(str) .. "' does not match pattern '" .. pattern .. "'")
  end
end

local M = require("andrew.vault.search_query")

-- ============================================================================
print("\n=== 1. PARSER: Single term queries ===")
-- ============================================================================

test("single text term", function()
  local ast = M.parse_query("deploy")
  assert_eq(ast.type, "text")
  assert_eq(ast.value, "deploy")
  assert_eq(ast.quoted, false)
end)

test("quoted text term", function()
  local ast = M.parse_query('"exact phrase"')
  assert_eq(ast.type, "text")
  assert_eq(ast.value, "exact phrase")
  assert_eq(ast.quoted, true)
end)

test("regex pattern", function()
  local ast = M.parse_query("/^## Results/")
  assert_eq(ast.type, "regex")
  assert_eq(ast.pattern, "^## Results")
end)

test("regex with flags", function()
  local ast = M.parse_query("/pattern/im")
  assert_eq(ast.type, "regex")
  assert_eq(ast.pattern, "pattern")
  assert_eq(ast.flags, "im")
end)

test("regex with single flag", function()
  local ast = M.parse_query("/test/i")
  assert_eq(ast.type, "regex")
  assert_eq(ast.pattern, "test")
  assert_eq(ast.flags, "i")
end)

-- ============================================================================
print("\n=== 2. PARSER: Field filters ===")
-- ============================================================================

test("field equals", function()
  local ast = M.parse_query("type:meeting")
  assert_eq(ast.type, "field")
  assert_eq(ast.name, "type")
  assert_eq(ast.op, "=")
  assert_eq(ast.value, "meeting")
end)

test("field greater than", function()
  local ast = M.parse_query("priority:>3")
  assert_eq(ast.type, "field")
  assert_eq(ast.name, "priority")
  assert_eq(ast.op, ">")
  assert_eq(ast.value, "3")
end)

test("field greater or equal", function()
  local ast = M.parse_query("priority:>=3")
  assert_eq(ast.op, ">=")
  assert_eq(ast.value, "3")
end)

test("field less than", function()
  local ast = M.parse_query("priority:<2")
  assert_eq(ast.op, "<")
  assert_eq(ast.value, "2")
end)

test("field less or equal", function()
  local ast = M.parse_query("priority:<=5")
  assert_eq(ast.op, "<=")
  assert_eq(ast.value, "5")
end)

test("field range", function()
  local ast = M.parse_query("created:2026-01..2026-02")
  assert_eq(ast.type, "field")
  assert_eq(ast.name, "created")
  assert_eq(ast.op, "..")
  assert_eq(ast.value, "2026-01")
  assert_eq(ast.value2, "2026-02")
end)

test("field with quoted value", function()
  local ast = M.parse_query('type:"my meeting"')
  assert_eq(ast.type, "field")
  assert_eq(ast.name, "type")
  assert_eq(ast.value, "my meeting")
end)

test("empty field value (exists check)", function()
  local ast = M.parse_query("type:")
  assert_eq(ast.type, "field")
  assert_eq(ast.name, "type")
  assert_eq(ast.op, "=")
  assert_eq(ast.value, "")
end)

test("generic unknown field", function()
  local ast = M.parse_query("foo:bar")
  assert_eq(ast.type, "field")
  assert_eq(ast.name, "foo")
  assert_eq(ast.value, "bar")
end)

-- ============================================================================
print("\n=== 3. PARSER: Special filters ===")
-- ============================================================================

test("has filter", function()
  local ast = M.parse_query("has:tags")
  assert_eq(ast.type, "has")
  assert_eq(ast.target, "tags")
end)

test("has filter case normalized", function()
  local ast = M.parse_query("has:Tags")
  assert_eq(ast.target, "tags")
end)

test("task any", function()
  local ast = M.parse_query('task:""')
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "any")
  assert_eq(ast.pattern, "")
end)

test("task with pattern", function()
  local ast = M.parse_query("task:review")
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "any")
  assert_eq(ast.pattern, "review")
end)

test("task-todo", function()
  local ast = M.parse_query('task-todo:""')
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "todo")
  assert_eq(ast.pattern, "")
end)

test("task-done", function()
  local ast = M.parse_query('task-done:""')
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "done")
  assert_eq(ast.pattern, "")
end)

test("task-due meta", function()
  local ast = M.parse_query("task-due:<7d")
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "meta")
  assert_eq(ast.meta_field, "due")
  assert_eq(ast.op, "<")
  assert_eq(ast.value, "7d")
end)

test("task-priority meta", function()
  local ast = M.parse_query("task-priority:<=2")
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "meta")
  assert_eq(ast.meta_field, "priority")
  assert_eq(ast.op, "<=")
  assert_eq(ast.value, "2")
end)

test("task-state meta", function()
  local ast = M.parse_query("task-state:in-progress")
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "meta")
  assert_eq(ast.meta_field, "state")
  assert_eq(ast.op, "=")
  assert_eq(ast.value, "in-progress")
end)

test("task-repeat empty (exists)", function()
  local ast = M.parse_query('task-repeat:""')
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "meta")
  assert_eq(ast.meta_field, "repeat")
  assert_eq(ast.op, "=")
  assert_eq(ast.value, "")
end)

test("task-scheduled meta", function()
  local ast = M.parse_query("task-scheduled:this-week")
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "meta")
  assert_eq(ast.meta_field, "scheduled")
  assert_eq(ast.op, "=")
  assert_eq(ast.value, "this-week")
end)

test("task-completion meta", function()
  local ast = M.parse_query("task-completion:<7d")
  assert_eq(ast.type, "task")
  assert_eq(ast.variant, "meta")
  assert_eq(ast.meta_field, "completion")
  assert_eq(ast.op, "<")
  assert_eq(ast.value, "7d")
end)

-- ============================================================================
print("\n=== 4. PARSER: Graph operator ===")
-- ============================================================================

test("graph:neighbors", function()
  local ast = M.parse_query("graph:neighbors")
  assert_eq(ast.type, "graph")
  assert_eq(ast.depth, 1)
  assert_eq(ast.direction, "both")
  assert_eq(ast.center, "current")
end)

test("graph:extended", function()
  local ast = M.parse_query("graph:extended")
  assert_eq(ast.type, "graph")
  assert_eq(ast.depth, 2)
end)

test("graph with params", function()
  local ast = M.parse_query("graph:depth=3,dir=forward")
  assert_eq(ast.type, "graph")
  assert_eq(ast.depth, 3)
  assert_eq(ast.direction, "forward")
  assert_eq(ast.center, "current")
end)

test("graph with center", function()
  local ast = M.parse_query("graph:depth=2,center=Dashboard")
  assert_eq(ast.type, "graph")
  assert_eq(ast.depth, 2)
  assert_eq(ast.center, "Dashboard")
end)

test("graph backward direction", function()
  local ast = M.parse_query("graph:dir=backward")
  assert_eq(ast.direction, "backward")
end)

-- ============================================================================
print("\n=== 5. PARSER: Boolean operators ===")
-- ============================================================================

test("implicit AND", function()
  local ast = M.parse_query("a b")
  assert_eq(ast.type, "and")
  assert_eq(ast.left.value, "a")
  assert_eq(ast.right.value, "b")
end)

test("explicit AND", function()
  local ast = M.parse_query("a AND b")
  assert_eq(ast.type, "and")
  assert_eq(ast.left.value, "a")
  assert_eq(ast.right.value, "b")
end)

test("case insensitive AND", function()
  local ast = M.parse_query("a and b")
  assert_eq(ast.type, "and")
end)

test("OR", function()
  local ast = M.parse_query("a OR b")
  assert_eq(ast.type, "or")
  assert_eq(ast.left.value, "a")
  assert_eq(ast.right.value, "b")
end)

test("case insensitive OR", function()
  local ast = M.parse_query("a or b")
  assert_eq(ast.type, "or")
end)

test("mixed case Or", function()
  local ast = M.parse_query("a Or b")
  assert_eq(ast.type, "or")
end)

test("NOT prefix", function()
  local ast = M.parse_query("NOT a")
  assert_eq(ast.type, "not")
  assert_eq(ast.operand.type, "text")
  assert_eq(ast.operand.value, "a")
end)

test("minus prefix on field", function()
  local ast = M.parse_query("-tag:x")
  assert_eq(ast.type, "not")
  assert_eq(ast.operand.type, "field")
  assert_eq(ast.operand.name, "tag")
end)

test("minus prefix on text", function()
  local ast = M.parse_query("-deploy")
  assert_eq(ast.type, "not")
  assert_eq(ast.operand.type, "text")
  assert_eq(ast.operand.value, "deploy")
end)

test("double NOT", function()
  local ast = M.parse_query("NOT NOT a")
  assert_eq(ast.type, "not")
  assert_eq(ast.operand.type, "not")
  assert_eq(ast.operand.operand.value, "a")
end)

-- ============================================================================
print("\n=== 6. PARSER: Precedence and grouping ===")
-- ============================================================================

test("AND binds tighter than OR", function()
  local ast = M.parse_query("a b OR c")
  assert_eq(ast.type, "or")
  assert_eq(ast.left.type, "and")
  assert_eq(ast.left.left.value, "a")
  assert_eq(ast.left.right.value, "b")
  assert_eq(ast.right.value, "c")
end)

test("parentheses override precedence", function()
  local ast = M.parse_query("(a OR b) AND c")
  assert_eq(ast.type, "and")
  assert_eq(ast.left.type, "or")
  assert_eq(ast.right.value, "c")
end)

test("three-way implicit AND is left-associative", function()
  local ast = M.parse_query("a b c")
  assert_eq(ast.type, "and")
  assert_eq(ast.left.type, "and")
  assert_eq(ast.left.left.value, "a")
  assert_eq(ast.left.right.value, "b")
  assert_eq(ast.right.value, "c")
end)

test("nested parens", function()
  local ast = M.parse_query("((a OR b))")
  assert_eq(ast.type, "or")
  assert_eq(ast.left.value, "a")
  assert_eq(ast.right.value, "b")
end)

test("complex boolean: (type:meeting OR type:analysis) tag:active", function()
  local ast = M.parse_query("(type:meeting OR type:analysis) tag:active")
  assert_eq(ast.type, "and")
  assert_eq(ast.left.type, "or")
  assert_eq(ast.right.type, "field")
  assert_eq(ast.right.name, "tag")
end)

-- ============================================================================
print("\n=== 7. PARSER: Group directive ===")
-- ============================================================================

test("group directive extracted", function()
  local ast, err, group = M.parse_query("group:file type:meeting")
  assert_nil(err)
  assert_eq(group, "file")
  assert_eq(ast.type, "field")
  assert_eq(ast.name, "type")
end)

test("group-only query returns match_all", function()
  local ast, err, group = M.parse_query("group:folder")
  assert_nil(err)
  assert_eq(ast.type, "match_all")
  assert_eq(group, "folder")
end)

-- ============================================================================
print("\n=== 8. PARSER: Edge cases and non-field colons ===")
-- ============================================================================

test("URL not parsed as field", function()
  local ast = M.parse_query("http://example.com")
  assert_eq(ast.type, "text")
  assert_eq(ast.value, "http://example.com")
end)

test("numeric prefix colon as text", function()
  local ast = M.parse_query("10:30")
  assert_eq(ast.type, "text")
  assert_eq(ast.value, "10:30")
end)

test("bare minus as text", function()
  -- Bare minus followed by whitespace or end-of-input
  local ast = M.parse_query("hello - world")
  -- "hello" AND "-" AND "world"
  assert_eq(ast.type, "and")
end)

test("unknown task- prefix falls through to text", function()
  local ast = M.parse_query("task-unknown:value")
  assert_eq(ast.type, "text")
  assert_eq(ast.value, "task-unknown:value")
end)

-- ============================================================================
print("\n=== 9. PARSER: Error cases ===")
-- ============================================================================

test("empty query", function()
  local ast, err = M.parse_query("")
  assert_nil(ast)
  assert_eq(err, "Empty query")
end)

test("whitespace-only query", function()
  local ast, err = M.parse_query("   ")
  assert_nil(ast)
  assert_eq(err, "Empty query")
end)

test("nil query", function()
  local ast, err = M.parse_query(nil)
  assert_nil(ast)
end)

test("unterminated quote", function()
  local ast, err = M.parse_query('"unterminated')
  assert_nil(ast)
  assert_match(err, "Unterminated")
end)

test("unterminated regex", function()
  local ast, err = M.parse_query("/unclosed")
  assert_nil(ast)
  assert_match(err, "Unterminated")
end)

test("unmatched open paren", function()
  local ast, err = M.parse_query("(a OR b")
  assert_nil(ast)
  assert_match(err, "Expected")
end)

test("dangling AND", function()
  local ast, err = M.parse_query("a AND")
  assert_nil(ast)
  assert_true(err ~= nil, "should return error for dangling AND")
end)

test("double operator AND AND", function()
  local ast, err = M.parse_query("a AND AND b")
  assert_nil(ast)
  assert_true(err ~= nil, "should return error for AND AND")
end)

-- ============================================================================
print("\n=== 10. UTILITY: edit_distance ===")
-- ============================================================================

test("edit_distance identical strings", function()
  assert_eq(M.edit_distance("test", "test"), 0)
end)

test("edit_distance one substitution", function()
  assert_eq(M.edit_distance("test", "tast"), 1)
end)

test("edit_distance one insertion", function()
  assert_eq(M.edit_distance("ab", "abc"), 1)
end)

test("edit_distance one deletion", function()
  assert_eq(M.edit_distance("abc", "ac"), 1)
end)

test("edit_distance empty to non-empty", function()
  assert_eq(M.edit_distance("", "abc"), 3)
end)

test("edit_distance non-empty to empty", function()
  assert_eq(M.edit_distance("abc", ""), 3)
end)

test("edit_distance both empty", function()
  assert_eq(M.edit_distance("", ""), 0)
end)

-- ============================================================================
print("\n=== 11. UTILITY: suggest_field ===")
-- ============================================================================

test("suggest_field close match", function()
  local suggestion, dist = M.suggest_field("typ", { "type", "tag", "path" })
  assert_eq(suggestion, "type")
  assert_eq(dist, 1)
end)

test("suggest_field no close match", function()
  local suggestion = M.suggest_field("xyz", { "type", "tag", "path" })
  assert_nil(suggestion)
end)

test("suggest_field short name skipped", function()
  local suggestion = M.suggest_field("ty", { "type" })
  assert_nil(suggestion)
end)

test("suggest_field exact match", function()
  local suggestion, dist = M.suggest_field("type", { "type", "tag" })
  assert_eq(suggestion, "type")
  assert_eq(dist, 0)
end)

-- ============================================================================
-- Summary
-- ============================================================================

print("\n============================================")
print(string.format("search_query_spec: %d passed, %d failed", passed, failed))
if #errors > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print("  " .. e.name .. ": " .. e.err)
  end
end
print("============================================\n")

if failed > 0 then os.exit(1) end
```

### `tests/search_filter_spec.lua`

```lua
-- Unit tests for search_filter.lua (metadata matching)
-- Run with: nvim --headless -u NONE -l tests/search_filter_spec.lua

-- Setup package path so require works
local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
package.path = config_dir .. "/lua/?.lua;" .. config_dir .. "/lua/?/init.lua;" .. package.path

local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    table.insert(errors, { name = name, err = tostring(err) })
    print("  FAIL: " .. name .. " -> " .. tostring(err))
  end
end

local function assert_eq(got, expected, msg)
  if got ~= expected then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

local function assert_true(val, msg)
  if not val then error((msg or "assertion failed") .. " (got falsy)") end
end

local function assert_false(val, msg)
  if val then error((msg or "assertion failed") .. " (got truthy)") end
end

local function assert_nil(val, msg)
  if val ~= nil then error((msg or "expected nil") .. ", got: " .. vim.inspect(val)) end
end

local search_query = require("andrew.vault.search_query")
local search_filter = require("andrew.vault.search_filter")
local date_utils = require("andrew.vault.date_utils")

--- Parse a query and return the AST (convenience).
local function parse(q)
  local ast, err = search_query.parse_query(q)
  if not ast then error("parse failed: " .. (err or "nil")) end
  return ast
end

--- Evaluate a query string against a mock entry.
--- For metadata-only queries, uses match_entry directly.
local function match(query_str, entry)
  local ast = parse(query_str)
  return search_filter.match_entry(ast, entry)
end

--- Build a mock VaultIndexEntry with sensible defaults.
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

-- ============================================================================
print("\n=== 1. FIELD: type filter ===")
-- ============================================================================

test("type:meeting matches", function()
  local entry = mock_entry({ frontmatter = { type = "meeting" } })
  assert_true(match("type:meeting", entry))
end)

test("type:meeting does not match analysis", function()
  local entry = mock_entry({ frontmatter = { type = "analysis" } })
  assert_false(match("type:meeting", entry))
end)

test("type match is case-insensitive", function()
  local entry = mock_entry({ frontmatter = { type = "Meeting" } })
  assert_true(match("type:meeting", entry))
end)

test("type: empty value checks existence (true)", function()
  local entry = mock_entry({ frontmatter = { type = "project" } })
  assert_true(match("type:", entry))
end)

test("type: empty value checks existence (false)", function()
  local entry = mock_entry({ frontmatter = {} })
  assert_false(match("type:", entry))
end)

-- ============================================================================
print("\n=== 2. FIELD: tag filter ===")
-- ============================================================================

test("tag:project matches exact", function()
  local entry = mock_entry({ tags = { "project" } })
  assert_true(match("tag:project", entry))
end)

test("tag:project does not match unrelated", function()
  local entry = mock_entry({ tags = { "meeting" } })
  assert_false(match("tag:project", entry))
end)

test("tag:project matches hierarchical child", function()
  local entry = mock_entry({ tags = { "project/active" } })
  assert_true(match("tag:project", entry))
end)

test("tag match on empty tags", function()
  local entry = mock_entry({ tags = {} })
  assert_false(match("tag:project", entry))
end)

-- ============================================================================
print("\n=== 3. FIELD: path, file, folder filters ===")
-- ============================================================================

test("path:Projects/ matches prefix", function()
  local entry = mock_entry({ rel_path = "Projects/Alpha/note.md" })
  assert_true(match("path:Projects/", entry))
end)

test("path:Areas/ does not match", function()
  local entry = mock_entry({ rel_path = "Projects/Alpha/note.md" })
  assert_false(match("path:Areas/", entry))
end)

test("file:Dashboard matches substring", function()
  local entry = mock_entry({ basename = "Dashboard" })
  assert_true(match("file:Dashboard", entry))
end)

test("file:dash matches case-insensitive substring", function()
  local entry = mock_entry({ basename = "Dashboard" })
  assert_true(match("file:dash", entry))
end)

test("file:xyz does not match", function()
  local entry = mock_entry({ basename = "Dashboard" })
  assert_false(match("file:xyz", entry))
end)

test("folder exact match", function()
  local entry = mock_entry({ folder = "Projects" })
  assert_true(match("folder:Projects", entry))
end)

test("folder prefix match with slash", function()
  local entry = mock_entry({ folder = "Projects/Alpha" })
  assert_true(match("folder:Projects", entry))
end)

-- ============================================================================
print("\n=== 4. FIELD: priority and status ===")
-- ============================================================================

test("priority:>3 matches 4", function()
  local entry = mock_entry({ frontmatter = { priority = 4 } })
  assert_true(match("priority:>3", entry))
end)

test("priority:>4 does not match 4", function()
  local entry = mock_entry({ frontmatter = { priority = 4 } })
  assert_false(match("priority:>4", entry))
end)

test("priority:>=4 matches 4", function()
  local entry = mock_entry({ frontmatter = { priority = 4 } })
  assert_true(match("priority:>=4", entry))
end)

test("priority:1..5 matches 3", function()
  local entry = mock_entry({ frontmatter = { priority = 3 } })
  assert_true(match("priority:1..5", entry))
end)

test("priority:1..3 does not match 4", function()
  local entry = mock_entry({ frontmatter = { priority = 4 } })
  assert_false(match("priority:1..3", entry))
end)

test("status:active matches frontmatter", function()
  local entry = mock_entry({ frontmatter = { status = "active" } })
  assert_true(match("status:active", entry))
end)

test("status:active matches inline_fields", function()
  local entry = mock_entry({ inline_fields = { status = "active" } })
  assert_true(match("status:active", entry))
end)

test("status:inactive does not match", function()
  local entry = mock_entry({ frontmatter = { status = "active" } })
  assert_false(match("status:inactive", entry))
end)

-- ============================================================================
print("\n=== 5. FIELD: alias ===")
-- ============================================================================

test("alias:alt matches", function()
  local entry = mock_entry({ aliases = { "alt" } })
  assert_true(match("alias:alt", entry))
end)

test("alias:other does not match", function()
  local entry = mock_entry({ aliases = { "alt" } })
  assert_false(match("alias:other", entry))
end)

test("alias on empty aliases", function()
  local entry = mock_entry({ aliases = {} })
  assert_false(match("alias:alt", entry))
end)

-- ============================================================================
print("\n=== 6. FIELD: date filters (modified/created) ===")
-- ============================================================================

test("modified:today matches file modified today", function()
  local today_ts = date_utils.start_of_day(os.date("*t"))
  local entry = mock_entry({ mtime = today_ts + 3600 })  -- 1am today
  assert_true(match("modified:today", entry))
end)

test("modified:today does not match old file", function()
  local entry = mock_entry({ mtime = os.time() - 86400 * 5 })
  assert_false(match("modified:today", entry))
end)

test("modified:<7d matches file from 3 days ago (within 7 days)", function()
  -- modified:<7d with relative duration inversion means entry_ts > threshold
  -- threshold = start of day 7 days ago
  -- 3 days ago > 7 days ago, so should match
  local entry = mock_entry({ mtime = os.time() - 86400 * 3 })
  assert_true(match("modified:<7d", entry))
end)

test("modified:<7d does not match file from 10 days ago", function()
  local entry = mock_entry({ mtime = os.time() - 86400 * 10 })
  assert_false(match("modified:<7d", entry))
end)

test("modified with absolute date", function()
  local ts = os.time({ year = 2026, month = 1, day = 15, hour = 12, min = 0, sec = 0 })
  local entry = mock_entry({ mtime = ts })
  assert_true(match("modified:2026-01-15", entry))
end)

test("created from frontmatter", function()
  local entry = mock_entry({
    frontmatter = { created = "2026-01-15T10:00:00" },
    mtime = os.time(),
  })
  assert_true(match("created:2026-01-15", entry))
end)

test("created falls back to ctime", function()
  local ctime = os.time({ year = 2026, month = 2, day = 1, hour = 0, min = 0, sec = 0 })
  local entry = mock_entry({ frontmatter = {}, ctime = ctime })
  assert_true(match("created:2026-02-01", entry))
end)

-- ============================================================================
print("\n=== 7. HAS filter ===")
-- ============================================================================

test("has:tags true", function()
  assert_true(match("has:tags", mock_entry({ tags = { "a" } })))
end)

test("has:tags false", function()
  assert_false(match("has:tags", mock_entry({ tags = {} })))
end)

test("has:aliases true", function()
  assert_true(match("has:aliases", mock_entry({ aliases = { "alt" } })))
end)

test("has:aliases false", function()
  assert_false(match("has:aliases", mock_entry({ aliases = {} })))
end)

test("has:tasks true", function()
  assert_true(match("has:tasks", mock_entry({ tasks = { { text = "t", status = " " } } })))
end)

test("has:tasks false", function()
  assert_false(match("has:tasks", mock_entry({ tasks = {} })))
end)

test("has:outlinks true", function()
  assert_true(match("has:outlinks", mock_entry({ outlinks = { { path = "A" } } })))
end)

test("has:outlinks false", function()
  assert_false(match("has:outlinks", mock_entry({ outlinks = {} })))
end)

test("has:frontmatter true", function()
  assert_true(match("has:frontmatter", mock_entry({ frontmatter = { type = "x" } })))
end)

test("has:frontmatter false", function()
  assert_false(match("has:frontmatter", mock_entry({ frontmatter = {} })))
end)

-- ============================================================================
print("\n=== 8. TASK filter ===")
-- ============================================================================

test("task any match", function()
  local entry = mock_entry({ tasks = { { text = "review", status = " " } } })
  assert_true(match('task:""', entry))
end)

test("task any empty tasks", function()
  local entry = mock_entry({ tasks = {} })
  assert_false(match('task:""', entry))
end)

test("task any with pattern match", function()
  local entry = mock_entry({ tasks = { { text = "Review PR", status = " " } } })
  assert_true(match("task:review", entry))
end)

test("task any with pattern no match", function()
  local entry = mock_entry({ tasks = { { text = "Review PR", status = " " } } })
  assert_false(match("task:deploy", entry))
end)

test("task-todo matches open task", function()
  local entry = mock_entry({ tasks = { { text = "t", status = " ", completed = false } } })
  assert_true(match('task-todo:""', entry))
end)

test("task-todo skips done task", function()
  local entry = mock_entry({ tasks = { { text = "t", status = "x", completed = true } } })
  assert_false(match('task-todo:""', entry))
end)

test("task-done matches completed task", function()
  local entry = mock_entry({ tasks = { { text = "t", status = "x", completed = true } } })
  assert_true(match('task-done:""', entry))
end)

test("task-done skips open task", function()
  local entry = mock_entry({ tasks = { { text = "t", status = " ", completed = false } } })
  assert_false(match('task-done:""', entry))
end)

-- ============================================================================
print("\n=== 9. TASK METADATA filter ===")
-- ============================================================================

test("task-due: exists check (has due)", function()
  local entry = mock_entry({ tasks = { { due = "2026-03-01" } } })
  assert_true(match("task-due:", entry))
end)

test("task-due: exists check (no due)", function()
  local entry = mock_entry({ tasks = { { text = "no due" } } })
  assert_false(match("task-due:", entry))
end)

test("task-due:today matches", function()
  local today = os.date("%Y-%m-%d")
  local entry = mock_entry({ tasks = { { due = today } } })
  assert_true(match("task-due:today", entry))
end)

test("task-priority:<=2 matches priority 1", function()
  local entry = mock_entry({ tasks = { { priority = 1 } } })
  assert_true(match("task-priority:<=2", entry))
end)

test("task-priority:<=2 does not match priority 3", function()
  local entry = mock_entry({ tasks = { { priority = 3 } } })
  assert_false(match("task-priority:<=2", entry))
end)

test("task-priority range 1..3 matches 2", function()
  local entry = mock_entry({ tasks = { { priority = 2 } } })
  assert_true(match("task-priority:1..3", entry))
end)

test("task-repeat: exists check", function()
  local entry = mock_entry({ tasks = { { repeat_rule = "every 1d" } } })
  assert_true(match('task-repeat:""', entry))
end)

test("task-repeat: no match when absent", function()
  local entry = mock_entry({ tasks = { { text = "plain" } } })
  assert_false(match('task-repeat:""', entry))
end)

-- ============================================================================
print("\n=== 10. BOOLEAN combiners ===")
-- ============================================================================

test("AND both true", function()
  local entry = mock_entry({
    frontmatter = { type = "meeting" },
    tags = { "urgent" },
  })
  assert_true(match("type:meeting AND tag:urgent", entry))
end)

test("AND one false", function()
  local entry = mock_entry({
    frontmatter = { type = "analysis" },
    tags = { "urgent" },
  })
  assert_false(match("type:meeting AND tag:urgent", entry))
end)

test("OR one true", function()
  local entry = mock_entry({ frontmatter = { type = "meeting" } })
  assert_true(match("type:meeting OR type:analysis", entry))
end)

test("OR other true", function()
  local entry = mock_entry({ frontmatter = { type = "analysis" } })
  assert_true(match("type:meeting OR type:analysis", entry))
end)

test("OR both false", function()
  local entry = mock_entry({ frontmatter = { type = "finding" } })
  assert_false(match("type:meeting OR type:analysis", entry))
end)

test("NOT inverts true to false", function()
  local entry = mock_entry({ tags = { "archived" } })
  assert_false(match("NOT tag:archived", entry))
end)

test("NOT inverts false to true", function()
  local entry = mock_entry({ tags = { "active" } })
  assert_true(match("NOT tag:archived", entry))
end)

test("minus shorthand equals NOT", function()
  local entry = mock_entry({ tags = { "archived" } })
  assert_false(match("-tag:archived", entry))
end)

test("complex: (type:meeting OR type:analysis) AND tag:active", function()
  local entry = mock_entry({
    frontmatter = { type = "meeting" },
    tags = { "active" },
  })
  assert_true(match("(type:meeting OR type:analysis) AND tag:active", entry))
end)

test("complex: (type:meeting OR type:analysis) AND tag:active fails on wrong tag", function()
  local entry = mock_entry({
    frontmatter = { type = "meeting" },
    tags = { "inactive" },
  })
  assert_false(match("(type:meeting OR type:analysis) AND tag:active", entry))
end)

-- ============================================================================
print("\n=== 11. TEXT/REGEX nodes pass through (always true in metadata eval) ===")
-- ============================================================================

test("text node always true in match_entry", function()
  local ast = parse("deploy")
  local entry = mock_entry()
  assert_true(search_filter.match_entry(ast, entry))
end)

test("regex node always true in match_entry", function()
  local ast = parse("/pattern/")
  local entry = mock_entry()
  assert_true(search_filter.match_entry(ast, entry))
end)

-- ============================================================================
print("\n=== 12. split_ast ===")
-- ============================================================================

test("split_ast pure metadata", function()
  local ast = parse("type:meeting tag:urgent")
  local split = search_filter.split_ast(ast)
  assert_eq(split.mode, "metadata_only")
  assert_true(split.metadata_ast ~= nil)
  assert_nil(split.text_ast)
end)

test("split_ast pure text", function()
  local ast = parse("deploy production")
  local split = search_filter.split_ast(ast)
  assert_eq(split.mode, "text_only")
  assert_nil(split.metadata_ast)
  assert_true(split.text_ast ~= nil)
end)

test("split_ast mixed AND", function()
  local ast = parse("type:meeting deploy")
  local split = search_filter.split_ast(ast)
  assert_eq(split.mode, "metadata_then_text")
  assert_true(split.metadata_ast ~= nil)
  assert_true(split.text_ast ~= nil)
end)

test("split_ast match_all", function()
  local ast, _, group = search_query.parse_query("group:folder")
  local split = search_filter.split_ast(ast)
  assert_eq(split.mode, "metadata_only")
  assert_true(split.match_all)
end)

-- ============================================================================
print("\n=== 13. ast_contains_graph ===")
-- ============================================================================

test("ast_contains_graph: no graph", function()
  assert_false(search_filter.ast_contains_graph(parse("type:meeting")))
end)

test("ast_contains_graph: direct graph", function()
  assert_true(search_filter.ast_contains_graph(parse("graph:neighbors")))
end)

test("ast_contains_graph: graph in AND", function()
  assert_true(search_filter.ast_contains_graph(parse("graph:neighbors type:meeting")))
end)

test("ast_contains_graph: graph in NOT", function()
  assert_true(search_filter.ast_contains_graph(parse("NOT graph:extended")))
end)

test("ast_contains_graph: nil AST", function()
  assert_false(search_filter.ast_contains_graph(nil))
end)

-- ============================================================================
print("\n=== 14. match_entry edge cases ===")
-- ============================================================================

test("match_entry nil AST returns true", function()
  assert_true(search_filter.match_entry(nil, mock_entry()))
end)

test("match_entry nil entry returns false", function()
  assert_false(search_filter.match_entry(parse("type:meeting"), nil))
end)

test("match_entry match_all node returns false (unknown type)", function()
  -- match_all is a sentinel, not a real matchable type; falls through to false
  -- unless handled upstream (in split_ast logic)
  local ast = { type = "match_all" }
  assert_false(search_filter.match_entry(ast, mock_entry()))
end)

-- ============================================================================
-- Summary
-- ============================================================================

print("\n============================================")
print(string.format("search_filter_spec: %d passed, %d failed", passed, failed))
if #errors > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print("  " .. e.name .. ": " .. e.err)
  end
end
print("============================================\n")

if failed > 0 then os.exit(1) end
```

### `tests/date_utils_spec.lua`

```lua
-- Unit tests for date_utils.lua
-- Run with: nvim --headless -u NONE -l tests/date_utils_spec.lua

-- Setup package path so require works
local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
package.path = config_dir .. "/lua/?.lua;" .. config_dir .. "/lua/?/init.lua;" .. package.path

local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    table.insert(errors, { name = name, err = tostring(err) })
    print("  FAIL: " .. name .. " -> " .. tostring(err))
  end
end

local function assert_eq(got, expected, msg)
  if got ~= expected then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

local function assert_true(val, msg)
  if not val then error((msg or "assertion failed") .. " (got falsy)") end
end

local function assert_false(val, msg)
  if val then error((msg or "assertion failed") .. " (got truthy)") end
end

local function assert_nil(val, msg)
  if val ~= nil then error((msg or "expected nil") .. ", got: " .. vim.inspect(val)) end
end

local M = require("andrew.vault.date_utils")

-- ============================================================================
print("\n=== 1. start_of_day ===")
-- ============================================================================

test("start_of_day strips time components", function()
  local t = { year = 2026, month = 3, day = 2, hour = 14, min = 30, sec = 45 }
  local ts = M.start_of_day(t)
  local result = os.date("*t", ts)
  assert_eq(result.hour, 0)
  assert_eq(result.min, 0)
  assert_eq(result.sec, 0)
  assert_eq(result.year, 2026)
  assert_eq(result.month, 3)
  assert_eq(result.day, 2)
end)

test("start_of_day at midnight is idempotent", function()
  local t = { year = 2026, month = 1, day = 1, hour = 0, min = 0, sec = 0 }
  local ts = M.start_of_day(t)
  local expected = os.time({ year = 2026, month = 1, day = 1, hour = 0, min = 0, sec = 0 })
  assert_eq(ts, expected)
end)

-- ============================================================================
print("\n=== 2. same_day ===")
-- ============================================================================

test("same_day: same day different times", function()
  local a = os.time({ year = 2026, month = 1, day = 15, hour = 0, min = 0, sec = 0 })
  local b = os.time({ year = 2026, month = 1, day = 15, hour = 23, min = 59, sec = 59 })
  assert_true(M.same_day(a, b))
end)

test("same_day: different days", function()
  local a = os.time({ year = 2026, month = 1, day = 15, hour = 23, min = 59, sec = 59 })
  local b = os.time({ year = 2026, month = 1, day = 16, hour = 0, min = 0, sec = 0 })
  assert_false(M.same_day(a, b))
end)

test("same_day: year boundary", function()
  local a = os.time({ year = 2025, month = 12, day = 31, hour = 23, min = 0, sec = 0 })
  local b = os.time({ year = 2026, month = 1, day = 1, hour = 0, min = 0, sec = 0 })
  assert_false(M.same_day(a, b))
end)

test("same_day: identical timestamps", function()
  local ts = os.time()
  assert_true(M.same_day(ts, ts))
end)

-- ============================================================================
print("\n=== 3. parse_iso_datetime ===")
-- ============================================================================

test("parse_iso_datetime: full datetime", function()
  local ts = M.parse_iso_datetime("2026-01-15T10:30:00")
  local expected = os.time({ year = 2026, month = 1, day = 15, hour = 10, min = 30, sec = 0 })
  assert_eq(ts, expected)
end)

test("parse_iso_datetime: date only", function()
  local ts = M.parse_iso_datetime("2026-01-15")
  local expected = os.time({ year = 2026, month = 1, day = 15, hour = 0, min = 0, sec = 0 })
  assert_eq(ts, expected)
end)

test("parse_iso_datetime: date only with custom default_hour", function()
  local ts = M.parse_iso_datetime("2026-01-15", 12)
  local expected = os.time({ year = 2026, month = 1, day = 15, hour = 12, min = 0, sec = 0 })
  assert_eq(ts, expected)
end)

test("parse_iso_datetime: nil input", function()
  assert_nil(M.parse_iso_datetime(nil))
end)

test("parse_iso_datetime: empty string", function()
  assert_nil(M.parse_iso_datetime(""))
end)

test("parse_iso_datetime: non-string input", function()
  assert_nil(M.parse_iso_datetime(123))
end)

test("parse_iso_datetime: invalid format", function()
  assert_nil(M.parse_iso_datetime("not-a-date"))
end)

test("parse_iso_datetime: partial (just year-month)", function()
  -- "2026-01" won't match the full pattern but will match YYYY-MM-DD? No, it's
  -- only 7 chars. Should return nil since there's no day.
  assert_nil(M.parse_iso_datetime("2026-01"))
end)

-- ============================================================================
print("\n=== 4. resolve_date ===")
-- ============================================================================

test("resolve_date: today", function()
  local ts = M.resolve_date("today")
  local expected = M.start_of_day(os.date("*t"))
  assert_eq(ts, expected)
end)

test("resolve_date: TODAY (case insensitive)", function()
  local ts = M.resolve_date("TODAY")
  local expected = M.start_of_day(os.date("*t"))
  assert_eq(ts, expected)
end)

test("resolve_date: yesterday", function()
  local ts = M.resolve_date("yesterday")
  local t = os.date("*t")
  t.day = t.day - 1
  local expected = M.start_of_day(t)
  assert_eq(ts, expected)
end)

test("resolve_date: 7d relative", function()
  local ts = M.resolve_date("7d")
  local t = os.date("*t")
  t.day = t.day - 7
  local expected = M.start_of_day(t)
  assert_eq(ts, expected)
end)

test("resolve_date: 0d equals today", function()
  local ts = M.resolve_date("0d")
  local expected = M.start_of_day(os.date("*t"))
  assert_eq(ts, expected)
end)

test("resolve_date: 30d relative", function()
  local ts = M.resolve_date("30d")
  local t = os.date("*t")
  t.day = t.day - 30
  local expected = M.start_of_day(t)
  assert_eq(ts, expected)
end)

test("resolve_date: absolute date", function()
  local ts = M.resolve_date("2026-01-15")
  local expected = os.time({ year = 2026, month = 1, day = 15, hour = 0, min = 0, sec = 0 })
  assert_eq(ts, expected)
end)

test("resolve_date: partial date YYYY-MM", function()
  local ts = M.resolve_date("2026-01")
  local expected = os.time({ year = 2026, month = 1, day = 1, hour = 0, min = 0, sec = 0 })
  assert_eq(ts, expected)
end)

test("resolve_date: this-week is a Monday", function()
  local ts = M.resolve_date("this-week")
  assert_true(ts ~= nil)
  local d = os.date("*t", ts)
  assert_eq(d.wday, 2, "this-week should resolve to Monday (wday=2)")
end)

test("resolve_date: This-Week (case insensitive)", function()
  local ts = M.resolve_date("This-Week")
  assert_true(ts ~= nil)
  local d = os.date("*t", ts)
  assert_eq(d.wday, 2)
end)

test("resolve_date: last-week", function()
  local ts = M.resolve_date("last-week")
  assert_true(ts ~= nil)
  local d = os.date("*t", ts)
  assert_eq(d.wday, 2, "last-week should resolve to a Monday")
  -- Should be 7 days before this-week
  local this_week = M.resolve_date("this-week")
  assert_eq(this_week - ts, 7 * 86400)
end)

test("resolve_date: previous-week equals last-week", function()
  assert_eq(M.resolve_date("previous-week"), M.resolve_date("last-week"))
end)

test("resolve_date: this-month", function()
  local ts = M.resolve_date("this-month")
  assert_true(ts ~= nil)
  local d = os.date("*t", ts)
  assert_eq(d.day, 1, "this-month should be 1st of month")
  local now = os.date("*t")
  assert_eq(d.month, now.month)
  assert_eq(d.year, now.year)
end)

test("resolve_date: last-month", function()
  local ts = M.resolve_date("last-month")
  assert_true(ts ~= nil)
  local d = os.date("*t", ts)
  assert_eq(d.day, 1, "last-month should be 1st of month")
end)

test("resolve_date: previous-month equals last-month", function()
  assert_eq(M.resolve_date("previous-month"), M.resolve_date("last-month"))
end)

test("resolve_date: empty string", function()
  assert_nil(M.resolve_date(""))
end)

test("resolve_date: nil", function()
  assert_nil(M.resolve_date(nil))
end)

test("resolve_date: invalid string", function()
  assert_nil(M.resolve_date("invalid"))
end)

-- ============================================================================
print("\n=== 5. is_relative_duration ===")
-- ============================================================================

test("is_relative_duration: 7d", function()
  assert_true(M.is_relative_duration("7d"))
end)

test("is_relative_duration: 30d", function()
  assert_true(M.is_relative_duration("30d"))
end)

test("is_relative_duration: 0d", function()
  assert_true(M.is_relative_duration("0d"))
end)

test("is_relative_duration: 7D uppercase", function()
  assert_true(M.is_relative_duration("7D"))
end)

test("is_relative_duration: today is false", function()
  assert_false(M.is_relative_duration("today"))
end)

test("is_relative_duration: absolute date is false", function()
  assert_false(M.is_relative_duration("2026-01-15"))
end)

test("is_relative_duration: nil", function()
  assert_false(M.is_relative_duration(nil))
end)

test("is_relative_duration: empty string", function()
  assert_false(M.is_relative_duration(""))
end)

-- ============================================================================
print("\n=== 6. resolve_date_range ===")
-- ============================================================================

test("resolve_date_range: this-week", function()
  local s, e = M.resolve_date_range("this-week")
  assert_true(s ~= nil)
  assert_true(e ~= nil)
  assert_eq(e - s, 7 * 86400, "this-week range should span 7 days")
end)

test("resolve_date_range: last-week", function()
  local s, e = M.resolve_date_range("last-week")
  assert_true(s ~= nil)
  assert_true(e ~= nil)
  assert_eq(e - s, 7 * 86400, "last-week range should span 7 days")
  -- end should be start of this-week
  local this_week = M.resolve_date("this-week")
  assert_eq(e, this_week)
end)

test("resolve_date_range: this-month", function()
  local s, e = M.resolve_date_range("this-month")
  assert_true(s ~= nil)
  assert_true(e ~= nil)
  assert_true(e > s, "end should be after start")
  local d = os.date("*t", s)
  assert_eq(d.day, 1)
end)

test("resolve_date_range: last-month", function()
  local s, e = M.resolve_date_range("last-month")
  assert_true(s ~= nil)
  assert_true(e ~= nil)
  -- end should be start of this-month
  local this_month = M.resolve_date("this-month")
  assert_eq(e, this_month)
end)

test("resolve_date_range: last-7d", function()
  local s, e = M.resolve_date_range("last-7d")
  assert_true(s ~= nil)
  assert_true(e ~= nil)
  -- Start should be 7 days ago, end should be tomorrow start
  local seven_ago = M.resolve_date("7d")
  assert_eq(s, seven_ago)
end)

test("resolve_date_range: last-30d", function()
  local s, e = M.resolve_date_range("last-30d")
  assert_true(s ~= nil)
  assert_true(e ~= nil)
  local thirty_ago = M.resolve_date("30d")
  assert_eq(s, thirty_ago)
end)

test("resolve_date_range: today returns nil (not a range)", function()
  assert_nil(M.resolve_date_range("today"))
end)

test("resolve_date_range: empty returns nil", function()
  assert_nil(M.resolve_date_range(""))
end)

test("resolve_date_range: nil returns nil", function()
  assert_nil(M.resolve_date_range(nil))
end)

test("resolve_date_range: previous-week equals last-week", function()
  local s1, e1 = M.resolve_date_range("last-week")
  local s2, e2 = M.resolve_date_range("previous-week")
  assert_eq(s1, s2)
  assert_eq(e1, e2)
end)

test("resolve_date_range: previous-month equals last-month", function()
  local s1, e1 = M.resolve_date_range("last-month")
  local s2, e2 = M.resolve_date_range("previous-month")
  assert_eq(s1, s2)
  assert_eq(e1, e2)
end)

-- ============================================================================
print("\n=== 7. resolve_date_string ===")
-- ============================================================================

test("resolve_date_string: today returns YYYY-MM-DD", function()
  local result = M.resolve_date_string("today")
  assert_true(result ~= nil)
  assert_true(result:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil)
  assert_eq(result, os.date("%Y-%m-%d"))
end)

test("resolve_date_string: absolute date round-trips", function()
  assert_eq(M.resolve_date_string("2026-01-15"), "2026-01-15")
end)

test("resolve_date_string: invalid returns nil", function()
  assert_nil(M.resolve_date_string("bogus"))
end)

-- ============================================================================
print("\n=== 8. days_between ===")
-- ============================================================================

test("days_between: same day", function()
  assert_eq(M.days_between("2026-01-15", "2026-01-15"), 0)
end)

test("days_between: one day forward", function()
  assert_eq(M.days_between("2026-01-15", "2026-01-16"), 1)
end)

test("days_between: one day backward (negative)", function()
  assert_eq(M.days_between("2026-01-16", "2026-01-15"), -1)
end)

test("days_between: across month boundary", function()
  assert_eq(M.days_between("2026-01-30", "2026-02-02"), 3)
end)

test("days_between: leap year Feb 28 to Mar 1", function()
  assert_eq(M.days_between("2024-02-28", "2024-03-01"), 2)
end)

test("days_between: non-leap year Feb 28 to Mar 1", function()
  assert_eq(M.days_between("2025-02-28", "2025-03-01"), 1)
end)

test("days_between: across year boundary", function()
  assert_eq(M.days_between("2025-12-31", "2026-01-01"), 1)
end)

test("days_between: invalid input", function()
  assert_eq(M.days_between("invalid", "also-invalid"), 0)
end)

-- ============================================================================
print("\n=== 9. date_add ===")
-- ============================================================================

test("date_add: add 1 day", function()
  assert_eq(M.date_add("2026-01-15", 1), "2026-01-16")
end)

test("date_add: subtract 1 day", function()
  assert_eq(M.date_add("2026-01-15", -1), "2026-01-14")
end)

test("date_add: cross month boundary", function()
  assert_eq(M.date_add("2026-01-30", 3), "2026-02-02")
end)

test("date_add: leap year Feb 28 + 1", function()
  assert_eq(M.date_add("2024-02-28", 1), "2024-02-29")
end)

test("date_add: non-leap year Feb 28 + 1", function()
  assert_eq(M.date_add("2025-02-28", 1), "2025-03-01")
end)

test("date_add: year boundary", function()
  assert_eq(M.date_add("2025-12-31", 1), "2026-01-01")
end)

test("date_add: invalid input returns unchanged", function()
  assert_eq(M.date_add("not-a-date", 5), "not-a-date")
end)

-- ============================================================================
print("\n=== 10. format_date_short ===")
-- ============================================================================

test("format_date_short: standard date", function()
  local result = M.format_date_short("2026-03-01")
  assert_eq(result, "Mar 01")
end)

test("format_date_short: invalid format", function()
  assert_eq(M.format_date_short("not-date"), "not-date")
end)

test("format_date_short: December", function()
  local result = M.format_date_short("2026-12-25")
  assert_eq(result, "Dec 25")
end)

-- ============================================================================
print("\n=== 11. truncate ===")
-- ============================================================================

test("truncate: short enough", function()
  assert_eq(M.truncate("hello", 10), "hello")
end)

test("truncate: exactly at max", function()
  assert_eq(M.truncate("hello", 5), "hello")
end)

test("truncate: over max", function()
  local result = M.truncate("hello world", 8)
  -- Should be 7 chars + ellipsis (multi-byte)
  assert_eq(#result > 0 and #result <= 10, true, "truncated string should be short")
  assert_true(result:sub(-3) == "\xe2\x80\xa6" or #result <= 8,
    "should end with ellipsis or be within limit")
end)

test("truncate: nil input", function()
  assert_eq(M.truncate(nil, 10), "")
end)

test("truncate: empty string", function()
  assert_eq(M.truncate("", 10), "")
end)

-- ============================================================================
-- Summary
-- ============================================================================

print("\n============================================")
print(string.format("date_utils_spec: %d passed, %d failed", passed, failed))
if #errors > 0 then
  print("\nFailures:")
  for _, e in ipairs(errors) do
    print("  " .. e.name .. ": " .. e.err)
  end
end
print("============================================\n")

if failed > 0 then os.exit(1) end
```

## How to Run the Tests

### Individual Test Files

```bash
# From the nvim config root (~/.config/nvim)
nvim --headless -u NONE -l tests/search_query_spec.lua
nvim --headless -u NONE -l tests/search_filter_spec.lua
nvim --headless -u NONE -l tests/date_utils_spec.lua
```

### All Tests at Once

Create a runner script `tests/run_all.sh`:

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")/.."
EXIT=0

for spec in tests/*_spec.lua; do
  echo "--- Running $spec ---"
  if nvim --headless -u NONE -l "$spec"; then
    echo "OK"
  else
    EXIT=1
    echo "FAILED"
  fi
  echo
done

# Also run the existing test suite
echo "--- Running tests/test_vault_fixes.lua ---"
if nvim --headless -u NONE -l tests/test_vault_fixes.lua; then
  echo "OK"
else
  EXIT=1
  echo "FAILED"
fi

exit $EXIT
```

**Note on `-u NONE`:** The search_filter test requires `require()` to resolve
vault modules. The test files prepend the correct `package.path` at the top. If
a module transitively requires something that needs Neovim plugins loaded (e.g.,
`vault_index` requiring `slug`), these must also be available on the Lua path.
The `package.path` setup at the top of each spec file handles this.

If `search_filter.lua` fails to load due to its `require("andrew.vault.config")`
or `require("andrew.vault.vault_index")`, consider either:
1. Mocking the requires (replace `package.loaded["andrew.vault.vault_index"]`
   before requiring search_filter), or
2. Running with `-u ~/.config/nvim/init.lua` so all plugins are available (but
   this is slower).

A lightweight approach for (1):

```lua
-- Pre-seed minimal stubs before requiring search_filter
package.loaded["andrew.vault.vault_index"] = {
  tag_matches = function(tags, target, opts)
    local lower_target = target:lower()
    local prefix = lower_target .. "/"
    for _, tag in ipairs(tags) do
      local lower_tag = tag:lower()
      if lower_tag == lower_target or lower_tag:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end,
}
package.loaded["andrew.vault.filter_utils"] = {
  resolve_in_index = function() return nil end,
}
```

## CI Integration Suggestions

### GitHub Actions

```yaml
name: Vault Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Neovim
        uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          version: stable
      - name: Run unit tests
        run: |
          cd $HOME/.config/nvim   # or wherever the config is checked out
          bash tests/run_all.sh
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit (or .husky/pre-commit)
if ls tests/*_spec.lua 1>/dev/null 2>&1; then
  echo "Running vault unit tests..."
  bash tests/run_all.sh || exit 1
fi
```

### Make Target

```makefile
.PHONY: test
test:
	@bash tests/run_all.sh
```

## Files Created

| File | Description |
|------|-------------|
| `tests/search_query_spec.lua` | Tokenizer and parser unit tests (~54 tests) |
| `tests/search_filter_spec.lua` | Metadata filter evaluation tests (~73 tests) |
| `tests/date_utils_spec.lua` | Date utility function tests (~66 tests) |
| `tests/run_all.sh` | Convenience runner for all test suites |

## Total Test Count

- `search_query_spec.lua`: ~54 test cases
- `search_filter_spec.lua`: ~73 test cases
- `date_utils_spec.lua`: ~66 test cases
- **Total: ~193 test cases**
