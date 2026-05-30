# Configuration

## File: `lua/andrew/vault/config.lua`

### New Section: `M.search`

```lua
-- ---------------------------------------------------------------------------
-- Advanced search
-- ---------------------------------------------------------------------------
M.search = {
  -- Debounce interval (ms) for live advanced search re-evaluation.
  -- Applied internally by fzf-lua's fzf_live. Lower = more responsive,
  -- higher = fewer ripgrep invocations.
  live_debounce_ms = 150,

  -- Maximum number of files to pass to ripgrep via --files-from.
  -- If metadata filtering produces more matches than this, fall back
  -- to full vault ripgrep with post-filtering. This avoids hitting
  -- shell argument limits and is faster for large file sets.
  max_files_from = 500,

  -- Known field names shown in completion (auto-extended from vault index).
  -- These are recognized by the tokenizer as field prefixes for field:value
  -- syntax. Unknown identifiers before : are also treated as generic fields
  -- but won't appear in completion.
  builtin_fields = {
    "type", "tag", "path", "file", "folder", "status",
    "created", "modified", "day", "priority",
  },

  -- Custom field aliases: maps user-friendly names to index field paths.
  -- Example: { area = "frontmatter.area", proj = "frontmatter.project" }
  -- When the user types area:xyz, it's evaluated as frontmatter.area = xyz.
  field_aliases = {},
}
```

## Existing Configuration Used by Advanced Search

### `config.scopes`

```lua
M.scopes = {
  { key = "all",      label = "All notes",    glob = "**/*.md" },
  { key = "projects", label = "Projects",     glob = "Projects/**/*.md" },
  { key = "areas",    label = "Areas",        glob = "Areas/**/*.md" },
  { key = "log",      label = "Log",          glob = "Log/**/*.md" },
  { key = "domains",  label = "Domains",      glob = "Domains/**/*.md" },
  { key = "library",  label = "Library",      glob = "Library/**/*.md" },
  { key = "methods",  label = "Methods",      glob = "Methods/**/*.md" },
  { key = "people",   label = "People",       glob = "People/**/*.md" },
}
```

Used by:
- `path:Projects/` filter matches against `rel_path`
- `folder:Log` filter matches against `folder`
- Future: combining scope selection with advanced search

### `config.note_types`

```lua
M.note_types = {
  "meeting", "analysis", "finding", "task", "simulation",
  "literature", "concept", "log", "journal",
}
```

Used by:
- `type:` field completion suggestions
- Validation of `type:` filter values (soft -- unknown types still work)

### `config.status_values`

```lua
M.status_values = { "Not Started", "In Progress", "Blocked", "Complete", "Cancelled" }
M.status_default = "Not Started"
```

Used by:
- `status:` field completion suggestions
- Case-insensitive matching: `status:active` matches "In Progress"? No -- exact
  match. `status:"In Progress"` is needed for multi-word values.

### `config.priority_values`

```lua
M.priority_values = { 1, 2, 3, 4, 5 }
M.priority_default = 3
```

Used by:
- `priority:` comparison operators
- Numeric: `priority:>3`, `priority:1..3`

### `config.maturity_values`

```lua
M.maturity_values = { "Seed", "Developing", "Mature", "Evergreen" }
```

Used by:
- Generic field: `maturity:seed` (case-insensitive match against frontmatter)

### `config.task_states`

```lua
M.task_states = {
  { mark = " ", label = "open" },
  { mark = "/", label = "in-progress" },
  { mark = "x", label = "done" },
  { mark = "-", label = "cancelled" },
  { mark = ">", label = "deferred" },
}
```

Used by:
- `task-todo:""` matches tasks with `status == " "` (open)
- `task-done:""` matches tasks with `completed == true` (status "x" or "X")
- Future: could extend to `task-cancelled:""`, etc.

### `config.graph.date_shortcuts`

```lua
M.graph.date_shortcuts = {
  ["today"]      = { offset_days = 0 },
  ["7d"]         = { offset_days = -7 },
  ["30d"]        = { offset_days = -30 },
  ["90d"]        = { offset_days = -90 },
  ["this-week"]  = "week",
  ["this-month"] = "month",
}
```

The search filter's `resolve_date()` function reuses these same shortcut names
for consistency with the graph filter. The implementation is independent (not
a shared function) but the naming is aligned.

## Configuration Points Summary

| Config Key                  | Type       | Default | Used In              |
|-----------------------------|------------|---------|----------------------|
| `search.live_debounce_ms`   | `number`   | 150     | `search_advanced_live()` |
| `search.max_files_from`     | `number`   | 500     | `ripgrep_in_files()`  |
| `search.builtin_fields`     | `string[]` | 10 fields | Tokenizer, completion |
| `search.field_aliases`      | `table`    | `{}`    | Field filter eval     |
| `scopes`                    | `table[]`  | 8 scopes | Path/folder matching |
| `note_types`                | `string[]` | 9 types | Completion            |
| `status_values`             | `string[]` | 5 values | Completion            |
| `priority_values`           | `number[]` | 1-5     | Numeric comparison    |
| `maturity_values`           | `string[]` | 4 values | Generic field match   |
| `task_states`               | `table[]`  | 5 states | Task filter           |
| `graph.date_shortcuts`      | `table`    | 6 entries | Date reference        |
