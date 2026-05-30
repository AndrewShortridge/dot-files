# Vault Index Metadata Available for Search

## Overview

`lua/andrew/vault/vault_index.lua` is the unified persistent vault index --
the sole source of truth for all vault metadata. Every field documented here
is available in-memory for instant filtering by the advanced search system.

## VaultIndexEntry Schema

Every indexed file has a `VaultIndexEntry` with these fields:

### Basic Metadata

| Field            | Type         | Description                                    | Example                              |
|------------------|--------------|------------------------------------------------|--------------------------------------|
| `rel_path`       | `string`     | Relative path from vault root                  | `"Projects/Alpha/Dashboard.md"`      |
| `abs_path`       | `string`     | Absolute filesystem path                       | `"/home/.../Dashboard.md"`           |
| `basename`       | `string`     | Filename without `.md` extension               | `"Dashboard"`                        |
| `basename_lower` | `string`     | Lowercase basename                             | `"dashboard"`                        |
| `folder`         | `string`     | Parent directory (empty if root)               | `"Projects/Alpha"`                   |
| `day`            | `string\|nil`| Date from filename (`YYYY-MM-DD` pattern)      | `"2026-02-26"` or `nil`             |

### Temporal Metadata

| Field   | Type          | Description                                    | Search Filter |
|---------|---------------|------------------------------------------------|---------------|
| `mtime` | `number`      | Modification time (Unix epoch seconds)         | `modified:`   |
| `size`  | `number`      | File size in bytes                             | --            |
| `ctime` | `number\|nil` | Creation time (nil on some Linux filesystems)  | `created:`    |

**Note:** `ctime` may be nil on ext4 (no true birthtime). When nil, `created:`
filters should fall back to `mtime`.

### Frontmatter

| Field          | Type             | Description                              | Search Filters         |
|----------------|------------------|------------------------------------------|------------------------|
| `frontmatter`  | `table<string,any>` | Parsed YAML key-value pairs           | `type:`, `status:`, etc. |
| `aliases`      | `string[]`       | Lowercased aliases from frontmatter      | `has:aliases`          |

**Frontmatter parsing supports:**
- Scalar values: `key: value` (auto-coerces to bool/number)
- List syntax: `key:\n  - item1\n  - item2`
- Inline arrays: `key: [item1, item2]`

**Common frontmatter fields used in this vault:**
- `type` -- note type (meeting, analysis, finding, task, etc.)
- `status` -- workflow status (Not Started, In Progress, etc.)
- `priority` -- numeric priority (1-5)
- `maturity` -- content maturity (Seed, Developing, Mature, Evergreen)
- `tags` -- frontmatter tags (also extracted into `tags[]`)
- `aliases` -- alternative names for the note

### Tags

| Field  | Type       | Description                                    | Search Filter |
|--------|------------|------------------------------------------------|---------------|
| `tags` | `string[]` | All tags (frontmatter + body), with parent expansion, sorted | `tag:` |

**Tag extraction details:**
- Extracted from `frontmatter.tags` (YAML list)
- Scanned from body via `#tagname` pattern (skips code blocks)
- Excludes pure numeric tags (`#123`)
- **Parent expansion:** `#foo/bar/baz` adds `foo`, `foo/bar`, `foo/bar/baz`
- Always sorted alphabetically
- Always lowercase

### Headings

| Field           | Type                    | Description                        | Search Filter |
|-----------------|-------------------------|------------------------------------|---------------|
| `headings`      | `VaultHeading[]`        | Array of heading objects           | --            |
| `heading_slugs` | `table<string,boolean>` | Set of heading slugs for fast lookup | --         |

**VaultHeading structure:**
```lua
{ text = "Raw Heading Text", slug = "raw-heading-text", level = 2, line = 15 }
```
- `text`: raw heading text (preserves case)
- `slug`: lowercase, special chars stripped, spaces → hyphens
- `level`: 1-6 based on `#` count
- `line`: 1-indexed line number

### Block IDs

| Field       | Type       | Description                         | Search Filter |
|-------------|------------|-------------------------------------|---------------|
| `block_ids` | `string[]` | Block IDs without `^` prefix        | --            |

Extracted from `^blockid` at line end or EOF.

### Outlinks

| Field     | Type          | Description                              | Search Filter  |
|-----------|---------------|------------------------------------------|----------------|
| `outlinks`| `VaultLink[]` | Wikilinks and embeds in the file         | `has:outlinks` |

**VaultLink structure:**
```lua
{ path = "Target#heading", display = "Display Text", embed = false }
```
- `path`: link target (may include `#heading` or `^blockid`)
- `display`: display text or extracted filename
- `embed`: true for `![[...]]`, false for `[[...]]`

### Tasks

| Field   | Type          | Description                         | Search Filters           |
|---------|---------------|-------------------------------------|--------------------------|
| `tasks` | `VaultTask[]` | Task items from markdown            | `task:`, `task-todo:`, `task-done:`, `has:tasks` |

**VaultTask structure:**
```lua
{ text = "Full task text", status = " ", completed = false, line = 42, tags = {"project"} }
```
- `text`: full text after status character
- `status`: single character: `" "`, `"x"`, `"X"`, `"/"`, `"-"`, `">"`
- `completed`: true if status is `"x"` or `"X"`
- `line`: 1-indexed line number
- `tags`: tags mentioned in task text

**Task states from config:**
| Mark | Label        |
|------|-------------|
| ` `  | open        |
| `/`  | in-progress |
| `x`  | done        |
| `-`  | cancelled   |
| `>`  | deferred    |

### Inline Fields

| Field           | Type              | Description                        | Search Filter |
|-----------------|-------------------|------------------------------------|---------------|
| `inline_fields` | `table<string,string>` | Key-value pairs from content  | `status:`, `priority:`, generic fields |

**Extraction patterns:**
1. `key:: value` at end of line
2. `[key:: value]` (bracketed)
3. `(key:: value)` (parenthesized)

Skips task lines and HTTP/HTTPS pseudo-keys. Last-wins for duplicate keys.

## Derived Lookup Tables

### `_name_index: table<string, string[]>`
- Key: lowercase basename or lowercase rel_path stem (without `.md`)
- Value: array of absolute paths matching that key
- Used for name resolution

### `_alias_index: table<string, string[]>`
- Key: lowercase alias name (from frontmatter)
- Value: array of absolute paths with that alias
- Fallback for name resolution

### `_inlinks: table<string, table[]>`
- Key: relative path of target file
- Value: array of inlink records `{ path, display, embed }`
- Built by resolving all outlinks in all files

## Public API for Search

### Singleton Access
```lua
local idx = require("andrew.vault.vault_index").current()
if not idx or not idx:is_ready() then return end
```

### Iterate All Entries
```lua
for rel_path, entry in pairs(idx.files) do
  -- entry is a VaultIndexEntry
end

-- Or as array:
local all = idx:all_entries()
```

### Single Entry Access
```lua
local entry = idx:get_entry(rel_path)
local entry = idx:get_entry_by_abs(abs_path)
```

### All Tags
```lua
local tags = idx:all_tags()  -- sorted string[]
```

### File Count
```lua
local n = idx:file_count()
```

### Change Detection
```lua
-- Internal: used by build_async()
-- mtime + size comparison against filesystem
```

## Subscriber System

```lua
local unsub = idx:subscribe(function(generation)
  -- Called after every index update
end)
-- Later: unsub() to unsubscribe
```

Allows dependent modules to react to index changes without polling.
`_generation` increments on every update.

## Mapping: Search Filter Fields to Index Fields

| Search Operator | Index Field(s)                              | Match Logic                    |
|-----------------|---------------------------------------------|--------------------------------|
| `type:meeting`  | `frontmatter.type`                          | Exact, case-insensitive        |
| `tag:project`   | `tags[]`                                    | Prefix match (tag or child)    |
| `path:Projects/`| `rel_path`                                  | Prefix match                   |
| `file:Dashboard`| `basename`                                  | Substring, case-insensitive    |
| `folder:Projects/Alpha` | `folder`                             | Exact or prefix match          |
| `status:active` | `frontmatter.status` OR `inline_fields.status` | Exact, case-insensitive    |
| `priority:>3`   | `frontmatter.priority` OR `inline_fields.priority` | Numeric comparison       |
| `created:>7d`   | `ctime` (fallback `mtime`)                  | Date comparison                |
| `modified:>30d` | `mtime`                                     | Date comparison                |
| `day:2026-02-26`| `day`                                       | Date match or range            |
| `has:tags`      | `#tags > 0`                                 | Non-empty check                |
| `has:aliases`   | `#aliases > 0`                              | Non-empty check                |
| `has:tasks`     | `#tasks > 0`                                | Non-empty check                |
| `has:outlinks`  | `#outlinks > 0`                             | Non-empty check                |
| `has:inlinks`   | `#_inlinks[rel_path] > 0`                   | Non-empty check                |
| `task:""`       | `#tasks > 0`                                | Any task exists                |
| `task-todo:""`  | `tasks[].status == " "`                     | Open tasks exist               |
| `task-done:""`  | `tasks[].completed == true`                 | Completed tasks exist          |
| Generic `key:value` | `frontmatter[key]` OR `inline_fields[key]` | Exact or substring          |
