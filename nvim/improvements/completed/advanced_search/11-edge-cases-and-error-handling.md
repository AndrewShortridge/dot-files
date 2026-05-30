# Edge Cases and Error Handling

## Query Parsing Edge Cases

### Malformed Queries

| Input                    | Behavior                                         |
|--------------------------|--------------------------------------------------|
| `""`                     | `parse_query` returns nil, "Empty query"         |
| `"(a OR b"`              | Parser error: "Expected RPAREN at position X"    |
| `'"unterminated`         | Tokenizer error: "Unterminated quoted string"     |
| `"/unclosed`             | Tokenizer error: "Unterminated regex"             |
| `"AND AND"`              | Parser error: unexpected AND after AND            |
| `"OR"`                   | Parser error: unexpected OR at start              |
| `"NOT"`                  | Parser error: NOT with no operand (EOF follows)   |
| `"a OR"`                 | Parser error: OR with no right operand            |
| `"()"`                   | Parser error: unexpected RPAREN (empty parens)    |

All parse errors are displayed via `vim.notify(..., ERROR)` in prompt mode.
In live mode, parse errors are silently ignored (return empty results).

### Ambiguous Syntax

| Input               | Resolution                                           |
|----------------------|------------------------------------------------------|
| `a b OR c`           | `(a AND b) OR c` -- implicit AND same precedence     |
| `a OR b c`           | `(a) OR (b AND c)` -- implicit AND binds right       |
| `NOT NOT a`          | Double negation: `not(not(a))` -- valid, collapses   |
| `-tag:a -tag:b`      | `not(tag:a) AND not(tag:b)` -- implicit AND          |
| `type: deploy`       | `type:` (empty value, "has type") AND text("deploy") |
| `http://example.com` | `http` as field name? No -- `://` not valid field syntax. Treated as TEXT |

### Field Detection Ambiguity

The tokenizer must distinguish field:value from plain text containing colons:

| Input                     | Token                                  |
|---------------------------|----------------------------------------|
| `type:meeting`            | FIELD(type, =, meeting)                |
| `foo:bar`                 | FIELD(foo, =, bar) -- generic field    |
| `http://example.com`      | TEXT("http://example.com") -- not a valid identifier prefix |
| `10:30`                   | TEXT("10:30") -- numeric prefix is not identifier |
| `re:deploy`               | FIELD(re, =, deploy) -- valid identifier |
| `tag:`                    | FIELD(tag, =, "") -- empty value       |
| `a:b:c`                   | FIELD(a, =, "b:c") -- first colon splits |

**Rule:** A colon creates a FIELD token only if the text before the colon
matches `^[a-z][a-z0-9_-]*$` (valid identifier starting with a letter).

## Metadata Filtering Edge Cases

### Missing Fields

| Query               | Entry Missing Field                    | Result   |
|----------------------|----------------------------------------|----------|
| `type:meeting`       | No `frontmatter` key                  | No match |
| `type:meeting`       | `frontmatter = {}` (no type key)      | No match |
| `status:active`      | No frontmatter.status, no inline_fields.status | No match |
| `priority:>3`        | `frontmatter.priority = nil`          | No match |
| `tag:project`        | `tags = {}` (empty array)             | No match |
| `tag:project`        | `tags = nil`                          | No match |
| `has:tags`           | `tags = {}`                           | No match |
| `has:tags`           | `tags = nil`                          | No match |
| `has:frontmatter`    | `frontmatter = {}`                    | No match |
| `has:frontmatter`    | `frontmatter = nil`                   | No match |

### Type Coercion

| Query              | Entry Value              | Match?           |
|--------------------|--------------------------|------------------|
| `priority:3`       | `frontmatter.priority = 3` (number) | Yes (tonumber) |
| `priority:3`       | `frontmatter.priority = "3"` (string) | Yes (tonumber) |
| `priority:>3`      | `inline_fields.priority = "5"` | Yes (tonumber) |
| `priority:>3`      | `inline_fields.priority = "high"` | No (tonumber nil) |
| `status:active`    | `frontmatter.status = "Active"` | Yes (case-insensitive) |
| `type:Meeting`     | `frontmatter.type = "meeting"` | Yes (case-insensitive) |

### Tag Matching

| Query               | Entry Tags                           | Match? | Why                    |
|----------------------|--------------------------------------|--------|------------------------|
| `tag:project`        | `["project"]`                        | Yes    | Exact match            |
| `tag:project`        | `["project/active"]`                 | Yes    | Parent expansion: "project" was added |
| `tag:project/active` | `["project", "project/active"]`      | Yes    | Exact match            |
| `tag:project/active` | `["project"]`                        | No     | No exact or child match |
| `tag:PROJECT`        | `["project"]`                        | Yes    | Tags stored lowercase  |
| `tag:proj`           | `["project"]`                        | No     | Not prefix of tag      |

### Date Edge Cases

| Query                | Scenario                              | Behavior                   |
|----------------------|---------------------------------------|----------------------------|
| `created:<7d`        | `ctime = nil` (Linux ext4)           | Falls back to `mtime`      |
| `created:<7d`        | `ctime = nil`, `mtime = nil`         | No match                   |
| `modified:<7d`       | File modified 3 days ago             | Match (less than 7 days ago) |
| `modified:>7d`       | File modified 3 days ago             | No match (not older than 7d) |
| `modified:last-7d`   | File modified 3 days ago             | Match (range: 7d ago to now) |
| `modified:today`     | File modified at 23:59:59 yesterday  | No match                   |
| `modified:today`     | File modified at 00:00:01 today      | Match                      |
| `day:2026-02-26`     | Filename: `2026-02-26-meeting.md`    | Match (day="2026-02-26")   |
| `day:2026-02-26`     | Filename: `meeting.md`               | No match (day=nil)         |
| `created:invalid`    | Invalid date string                  | `resolve_date` returns nil → no match |
| `modified:this-week` | Monday = start of ISO week           | Uses `(wday - 2) % 7`     |

**Relative duration operator inversion:** For `Nd` values (e.g. `7d`, `30d`),
comparison operators are inverted so they compare *recency* rather than timestamps:
- `modified:<7d` = "modified less than 7 days ago" = within last 7 days
- `modified:>7d` = "modified more than 7 days ago" = older than 7 days
- `modified:<=7d` = "modified 7 days ago or less" (inclusive)
- `modified:>=7d` = "modified 7 days ago or more" (inclusive)

This inversion applies only to `Nd` patterns. Absolute dates (`2026-01-15`) and
keywords (`today`, `this-week`) use standard timestamp comparison (no inversion).

**Timezone:** All dates use local time (matching `os.date()` and `os.time()`).

### Path/Folder Matching

| Query                    | Entry                              | Match? |
|--------------------------|------------------------------------|--------|
| `path:Projects/`         | `rel_path = "Projects/Alpha/n.md"` | Yes    |
| `path:Projects/Alpha`    | `rel_path = "Projects/Alpha/n.md"` | Yes    |
| `path:projects/`         | `rel_path = "Projects/Alpha/n.md"` | No (case-sensitive) |
| `folder:Projects/Alpha`  | `folder = "Projects/Alpha"`        | Yes    |
| `folder:Projects`        | `folder = "Projects/Alpha"`        | Yes (prefix) |
| `file:dashboard`         | `basename = "Dashboard"`           | Yes (case-insensitive substring) |
| `file:dash`              | `basename = "Dashboard"`           | Yes (substring) |

## Ripgrep Integration Edge Cases

### Large File Sets

| Metadata Matches | Strategy                                   |
|------------------|--------------------------------------------|
| 0                | No ripgrep needed (empty results)          |
| 1 - 500          | Use `--files-from` (restricted search)     |
| 501+             | Full vault ripgrep + post-filter results   |

The threshold (500) is configurable via `config.search.max_files_from`.

### Multiple Text Terms

| Query                    | Strategy                                |
|--------------------------|-----------------------------------------|
| `deploy`                 | Single ripgrep call                     |
| `deploy AND production`  | Two ripgrep calls, intersect file sets  |
| `deploy OR staging`      | Single ripgrep with `deploy\|staging`   |
| `"exact phrase"`         | Single ripgrep with `-F "exact phrase"` |
| `/regex/`                | Single ripgrep with pattern             |
| `deploy NOT staging`     | ripgrep "deploy", then ripgrep "staging", set difference |

### Text + Metadata Combined

| Query                           | Execution                           |
|---------------------------------|-------------------------------------|
| `type:meeting deploy`           | Metadata filter → restrict to meetings → ripgrep "deploy" in those files |
| `deploy -type:meeting`          | Ripgrep "deploy" in all files → post-filter to exclude meetings |
| `type:meeting OR deploy`        | Union: metadata meetings + ripgrep "deploy" results |

## Performance Edge Cases

### Cold Start (Index Not Ready)

```lua
if not idx or not idx:is_ready() then
  vim.notify("Vault index not ready. Falling back to text search.", WARN)
  -- Metadata filters silently ignored
  -- Text terms still work via ripgrep
end
```

### Empty Vault Index

```lua
if idx:file_count() == 0 then
  -- No files indexed yet
  -- Metadata-only queries return empty
  -- Text queries still work (ripgrep on filesystem)
end
```

### Very Selective Metadata Filters

When metadata filters match 0 files (e.g., `type:nonexistent`), no ripgrep
is needed. The result set is empty immediately.

### Very Broad Metadata Filters

When metadata filters match all files (e.g., `has:frontmatter` in a vault
where all files have frontmatter), the `--files-from` optimization provides
no benefit. Falls back to full vault ripgrep.

## Boolean Operator Edge Cases

| Input                    | AST                                          |
|--------------------------|----------------------------------------------|
| `NOT a`                  | `not(text("a"))`                             |
| `NOT NOT a`              | `not(not(text("a")))` → evaluates to `text("a")` |
| `NOT NOT NOT a`          | `not(not(not(text("a"))))` → `not(text("a"))` |
| `a AND NOT b`            | `and(text("a"), not(text("b")))`             |
| `NOT a AND b`            | `and(not(text("a")), text("b"))` -- NOT binds tighter |
| `NOT (a AND b)`          | `not(and(text("a"), text("b")))`             |
| `a OR NOT b`             | `or(text("a"), not(text("b")))`              |

## Regex Edge Cases

| Input                    | Behavior                                    |
|--------------------------|---------------------------------------------|
| `/simple/`               | Passed to ripgrep as regex                  |
| `/^## Heading/`          | Matches markdown headings                   |
| `/[invalid/`             | ripgrep may error (passed through)          |
| `//`                     | Empty regex (matches everything)            |
| `/a\/b/`                 | Escaped slash -- tokenizer must handle      |

**Note:** Regex in field values is NOT supported in v1. `/pattern/` is only
for content search via ripgrep.

## Error Recovery

### Parser Errors
- First error stops parsing (no recovery)
- Returns `nil, error_message`
- Prompt mode: displays error notification
- Live mode: returns empty results silently

### Runtime Errors
- `match_entry` should never error (nil-safe checks on every field)
- `ripgrep_in_files` handles io.popen failures gracefully
- `resolve_date` returns nil for unrecognized formats (no error)

### Graceful Degradation Table

| Failure Mode                | Behavior                              |
|-----------------------------|---------------------------------------|
| Parse error                 | Error notification (prompt) or empty (live) |
| Index not ready             | Fallback to plain ripgrep             |
| ctime unavailable           | Use mtime instead                     |
| Unknown field name          | Check frontmatter + inline_fields     |
| ripgrep execution failure   | Empty text results, metadata still shown |
| Empty vault                 | Empty results                         |
| Temp file creation failure  | Fall back to full vault ripgrep       |
