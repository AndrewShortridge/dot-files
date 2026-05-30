# 45 --- Standardize Notification Levels Across Vault Modules

## Motivation

The vault codebase contains **323 `vim.notify` calls** spread across 50+ modules.
These notifications use inconsistent severity levels, inconsistent message
prefixes, and inconsistent option patterns:

1. **Level misuse** -- Some modules use `ERROR` for user-correctable problems
   (file already exists, invalid tag name) that should be `WARN`. Others use
   `WARN` for expected outcomes (overdue task summary, broken links found) that
   are informational or should be `INFO`.
2. **Prefix inconsistency** -- Most modules prefix messages with `"Vault: "`
   but many do not: `capture.lua` says `"Captured to "`, `tasks.lua` says
   `"No task checkbox on current line"`, `metaedit.lua` uses `"metaedit: "`,
   `frontmatter_editor.lua` mixes `"metaedit: "` and bare messages like
   `"List is empty"`, and `autofile.lua` says `"Failed to move file"` with no
   module prefix at all.
3. **Options inconsistency** -- Only `task_notify.lua` and `vault_index.lua`
   pass `{ title = "Vault" }` in the third argument. Only `vault_index.lua`
   uses a notification ID for in-place replacement. All other modules omit the
   options table entirely.

These inconsistencies make it harder to visually triage notifications, make
notification filtering unreliable (you cannot filter by title if most
notifications lack one), and confuse users about severity (an `ERROR`
notification for "file already exists" implies something is broken when it is
actually a simple name collision).

---

## Current State Analysis

### Level Distribution

Across all vault modules:

| Level | Count | Description |
|-------|-------|-------------|
| `ERROR` | 30 | Red, high-urgency notifications |
| `WARN` | 81 | Yellow, medium-urgency notifications |
| `INFO` | 212 | Blue/neutral, low-urgency notifications |

### Prefix Patterns

| Prefix | Count | Modules |
|--------|-------|---------|
| `"Vault: "` | ~170 | Most modules (engine, init, embed, tags, etc.) |
| `"metaedit: "` | 9 | metaedit.lua, frontmatter_editor.lua |
| `"Kanban: "` | 4 | task_kanban.lua |
| `"Sidebar: "` | 1 | sidebar_meta.lua |
| `"Graph filter: "` | 3 | graph_filter.lua |
| `"Preview: "` | 2 | preview.lua |
| `"Search: "` / `"Advanced search: "` | 4 | search.lua |
| `"Frontmatter editor: "` | 1 | frontmatter_editor.lua |
| `"Vault query: "` / `"Vault query debug: "` | 7 | query/init.lua |
| `"Vault index"` | 3 | vault_index.lua |
| No prefix (bare message) | ~35 | tasks, capture, autofile, footnotes, etc. |

### Options Usage

| Pattern | Modules |
|---------|---------|
| `{ title = "Vault" }` | task_notify.lua (3 calls) |
| `{ title = "Vault Index", id = ..., replace = ... }` | vault_index.lua (1 helper) |
| No options table | Everything else (~320 calls) |

---

## Proposed Standard Policy

### Level Definitions

| Level | When to Use | Examples |
|-------|-------------|---------|
| **ERROR** | Unexpected internal failures where the code path should not normally be reached. Plugin crashes, coroutine errors, I/O failures on files that should exist, external tool crashes (rg, pandoc returning nonzero). | Coroutine resume failure, `rg` stderr output, failed temp file creation, failed file write on a path we just validated |
| **WARN** | User-correctable problems or degraded functionality. The user did something that cannot be completed, or a prerequisite is missing, but the system is not broken. | Broken wikilink target, file already exists (rename collision), invalid input, index not ready, missing external tool, navigation dead ends |
| **INFO** | Success feedback, status updates, expected outcomes, "nothing found" results. Anything the user might want to see but that does not indicate a problem. | "Renamed X -> Y", "No backlinks found", "Toggled X ON/OFF", "Carried forward 3 tasks", debug/diagnostic output |

### Prefix Convention

All user-facing notifications should use the **`"Vault: "` prefix** for
consistency, with one exception: sub-module names may replace `"Vault"` when
the context is unambiguous and the sub-module has its own identity (e.g.,
`"Vault query: "` for the dataview query engine). The `"metaedit: "` prefix
should be normalized to `"Vault: "` since metaedit is not a standalone tool.

### Options Convention

This improvement does **not** mandate adding `{ title = "Vault" }` to every
call -- that is a separate enhancement. The goal here is strictly to fix
incorrect levels and normalize prefixes. The existing `vault_index.lua`
pattern (notification ID for progress updates) and `task_notify.lua` pattern
(title for overdue alerts) are correct for their use cases and should remain.

---

## Notifications Requiring Level Changes

### ERROR -> WARN (User-Correctable Issues)

These notifications currently show a red `ERROR` indicator for situations that
are entirely expected and user-correctable. They should be `WARN` (yellow).

| # | File | Line | Current Message | Rationale |
|---|------|------|-----------------|-----------|
| 1 | `init.lua` | 56 | `"Vault: unknown template '" .. name .. "'"` | User typed a bad template name. Not an internal error. |
| 2 | `engine.lua` | 117 | `"Vault: unknown vault '" .. name .. "'"` | User requested a vault name that does not exist in config. |
| 3 | `rename.lua` | 319 | `"Vault: '" .. name .. ".md' already exists"` | File name collision during rename. User can pick a different name. |
| 4 | `rename.lua` | 405 | `"Vault: invalid tag name '" .. ntag .. "'"` | Invalid characters in tag name. User can re-enter. |
| 5 | `autofile.lua` | 89 | `"Destination already exists: " .. dest` | File already at target path. User should resolve manually. |
| 6 | `blockid.lua` | 150 | `"Vault: could not resolve target note"` | Link resolution failed for user's chosen note. |
| 7 | `blockid.lua` | 157 | `"Vault: could not read " .. target_path` | Target file unreadable (deleted? permissions?). |
| 8 | `tags.lua` | 149 | `"Vault: fd/fdfind not found"` | Missing external tool -- user can install it. |
| 9 | `task_notify.lua` | 152 | `"fzf-lua is required for :VaultOverdue"` | Missing plugin dependency for this command. |
| 10 | `task_kanban.lua` | 467 | `"Kanban: no columns configured"` | Kanban config is incomplete. User needs to add columns. |
| 11 | `search.lua` | 449 | `"Search parse error: " .. (err or "unknown")` | User typed an invalid search query. |
| 12 | `link_repair.lua` | 190 | `"Vault: fzf-lua required for link repair picker"` | Missing plugin dependency. |
| 13 | `link_repair.lua` | 494 | `"Vault: fzf-lua required for vault-wide link repair"` | Missing plugin dependency. |
| 14 | `images.lua` | 20 | `"Vault: xsel does not support image paste"` | Wrong clipboard tool installed. User can switch to xclip. |
| 15 | `images.lua` | 23 | `"Vault: no clipboard tool found (need xclip or wl-paste)"` | Missing external tool. |

### WARN -> INFO (Expected Outcomes, Not Problems)

These notifications show a yellow `WARN` indicator for situations that are
normal, expected outcomes. They should be `INFO` (blue/neutral).

| # | File | Line | Current Message | Rationale |
|---|------|------|-----------------|-----------|
| 16 | `task_notify.lua` | 129 | `table.concat(lines, "\n")` (overdue task summary) | This is a status report, not a warning. The overdue state is already communicated by the content. Using WARN makes it look like the plugin itself has a problem. |
| 17 | `linkcheck.lua` | 388 | `"Vault: found " .. n .. " broken link(s) out of " .. total` | This is the result of a user-initiated scan. The broken links are the content, not an error in the tool itself. |
| 18 | `linkcheck.lua` | 474 | `"Vault: " .. #dead .. " dead URL(s) found"` | Same as above -- scan result, not a tool problem. |
| 19 | `footnotes.lua` | 592 | `table.concat(lines, "\n")` (orphan footnotes report) | Diagnostic output from `:VaultFootnoteLint`. Result of an audit, not a problem with the plugin. |
| 20 | `metaedit.lua` | 275 | `"Usage: VaultMetaEdit [field] [value]"` | Usage hint, not a warning. |
| 21 | `metaedit.lua` | 289 | `"Usage: VaultMetaCycle [field]"` | Usage hint, not a warning. |
| 22 | `metaedit.lua` | 312 | `"Usage: VaultMetaToggle [field]"` | Usage hint, not a warning. |
| 23 | `query/init.lua` | 291 | `"Vault query debug: block at line " .. i .. " returned 0 results"` | Debug info gated behind debug mode. Not a warning. |

### WARN -> ERROR (Actual Internal Failures)

These notifications use `WARN` for situations that represent genuine I/O
failures -- the code tried to do something and the system refused. They should
be `ERROR`.

| # | File | Line | Current Message | Rationale |
|---|------|------|-----------------|-----------|
| 24 | `engine.lua` | 283 | `"Vault: failed to write " .. path()` | Persistent store write failed. This is a real I/O error, not a user mistake. |
| 25 | `engine.lua` | 329 | `"Vault: failed to write " .. path .. ": " .. err` | `write_file()` I/O failure. |
| 26 | `engine.lua` | 344 | `"Vault: failed to append to " .. path .. ": " .. err` | `append_file()` I/O failure. |

### Correctly Leveled (No Change Needed)

The following `ERROR`-level notifications are correct:

| File | Line | Message | Rationale |
|------|------|---------|-----------|
| `engine.lua` | 156 | Coroutine resume error | Internal Lua error |
| `engine.lua` | 170 | Coroutine resume error (input) | Internal Lua error |
| `engine.lua` | 188 | Coroutine resume error (select) | Internal Lua error |
| `engine.lua` | 381 | `"Vault: failed to write " .. full_path` | I/O error during note creation |
| `sidebar.lua` | 351 | `"Vault: failed to create sidebar"` | Internal UI failure |
| `linkcheck.lua` | 245 | `"Vault: rg failed: " .. stderr` | External tool crash |
| `linkcheck.lua` | 512 | `"Vault: rg failed"` | External tool crash |
| `unlinked.lua` | 223 | `"Vault: rg error: " .. stderr` | External tool crash |
| `export.lua` | 327 | `"Vault: failed to create temp file"` | I/O failure |
| `export.lua` | 361 | `"Vault: pandoc export failed"` | External tool crash |
| `autofile.lua` | 95 | `"Failed to move file"` | `vim.fn.rename()` returned nonzero |
| `vault_index.lua` | 1291 | `"Vault index error: " .. err` | Index build coroutine crash |
| `query/init.lua` | 295 | `"Vault query debug: block error"` | Query execution error |
| `images.lua` | 31 | `"Vault: failed to paste image"` | Clipboard read I/O failure |

The following `WARN`-level notifications are correct and need no change.
A representative sample:

| File | Line | Message | Why WARN is correct |
|------|------|---------|---------------------|
| `wikilinks.lua` | 278 | `"Heading not found: #..."` | User followed a broken link |
| `wikilinks.lua` | 379 | `"File not found: ..."` | User followed a broken link |
| `preview.lua` | 743 | `"Note not found: ..."` | Broken link in preview |
| `backlinks.lua` | 137 | `"Vault: index not ready"` | Degraded functionality |
| `embed.lua` | 1050 | `"Vault: index not available, sync not started"` | Degraded functionality |
| `pins.lua` | 28 | `"Vault: buffer is not inside the vault"` | User ran command in wrong context |
| `blockid.lua` | 76 | `"Vault: cannot add block ID to an empty line"` | Invalid cursor position |
| `capture.lua` | 21 | `"Vault: empty capture, nothing saved"` | User submitted empty input |
| `extract.lua` | 13 | `"Vault: no selection"` | Command requires visual selection |
| `graph.lua` | 428 | `"Vault index not ready"` | Prerequisite not met |
| `callout_folds.lua` | 257 | `"Vault: not a vault file"` | Wrong buffer context |

---

## Notifications Requiring Prefix Changes

The following notifications lack the `"Vault: "` prefix (or use an
inconsistent sub-module prefix) and should be normalized.

### Bare Messages -> "Vault: " Prefix

| # | File | Line | Current | Proposed |
|---|------|------|---------|----------|
| 27 | `tasks.lua` | 91 | `"No task checkbox on current line"` | `"Vault: no task checkbox on current line"` |
| 28 | `tasks.lua` | 161 | `"No matching tasks found"` | `"Vault: no matching tasks found"` |
| 29 | `capture.lua` | 76 | `"Captured to " .. date` | `"Vault: captured to " .. date` |
| 30 | `capture.lua` | 96 | `"Captured to Inbox"` | `"Vault: captured to Inbox"` |
| 31 | `autofile.lua` | 81 | `"Already in correct directory"` | `"Vault: already in correct directory"` |
| 32 | `autofile.lua` | 89 | `"Destination already exists: " .. dest` | `"Vault: destination already exists: " .. dest` |
| 33 | `autofile.lua` | 95 | `"Failed to move file"` | `"Vault: failed to move file"` |
| 34 | `autofile.lua` | 104 | `"Moved: " .. filepath .. " -> " .. dest` | `"Vault: moved " .. filepath .. " -> " .. dest` |
| 35 | `engine.lua` | 389 | `"Created: " .. rel_path .. ".md"` | `"Vault: created " .. rel_path .. ".md"` |
| 36 | `graph.lua` | 722 | `"Created: " .. unresolved_name .. ".md"` | `"Vault: created " .. unresolved_name .. ".md"` |
| 37 | `wikilinks.lua` | 354 | `"Created: " .. link .. ".md"` | `"Vault: created " .. link .. ".md"` |
| 38 | `wikilinks.lua` | 278 | `"Heading not found: #" .. heading` | `"Vault: heading not found: #" .. heading` |
| 39 | `wikilinks.lua` | 286 | `"Block not found: ^" .. block_id` | `"Vault: block not found: ^" .. block_id` |
| 40 | `wikilinks.lua` | 316 | `"Block not found: ^" .. block_id` | `"Vault: block not found: ^" .. block_id` |
| 41 | `wikilinks.lua` | 379 | `"File not found: " .. file_part` | `"Vault: file not found: " .. file_part` |
| 42 | `wikilinks.lua` | 393 | `"Heading not found: #" .. anchor` | `"Vault: heading not found: #" .. anchor` |
| 43 | `extract.lua` | 52 | `"Extracted to [[" .. name .. "]]"` | `"Vault: extracted to [[" .. name .. "]]"` |
| 44 | `export.lua` | 359 | `"Exported: " .. stem .. "." .. format` | `"Vault: exported " .. stem .. "." .. format` |
| 45 | `preview.lua` | 450 | `"Cannot resolve link in preview"` | `"Vault: cannot resolve link in preview"` |
| 46 | `preview.lua` | 524 | `"No wikilink under cursor in preview"` | `"Vault: no wikilink under cursor in preview"` |
| 47 | `preview.lua` | 626 | `"No wikilink or footnote under cursor"` | `"Vault: no wikilink or footnote under cursor"` |
| 48 | `preview.lua` | 633 | `"No wikilink under cursor"` | `"Vault: no wikilink under cursor"` |
| 49 | `preview.lua` | 736 | `"No cross-file wikilink under cursor"` | `"Vault: no cross-file wikilink under cursor"` |
| 50 | `preview.lua` | 743 | `"Note not found: " .. link` | `"Vault: note not found: " .. link` |
| 51 | `user_templates.lua` | 494 | `"Inserted template: " .. template.name` | `"Vault: inserted template " .. template.name` |
| 52 | `user_templates.lua` | 596 | `"No user templates found in " .. dir` | `"Vault: no user templates found in " .. dir` |
| 53 | `fragments.lua` | 287 | `"Inserted: " .. f.name` | `"Vault: inserted fragment " .. f.name` |
| 54 | `task_notify.lua` | 152 | `"fzf-lua is required for :VaultOverdue"` | `"Vault: fzf-lua is required for :VaultOverdue"` |
| 55 | `task_notify.lua` | 158 | `"No overdue tasks"` | `"Vault: no overdue tasks"` |
| 56 | `task_timeline.lua` | 365 | `"No task under cursor"` | `"Vault: no task under cursor"` |
| 57 | `task_timeline.lua` | 418 | `"No tasks found in vault"` | `"Vault: no tasks found in vault"` |
| 58 | `task_hierarchy.lua` | 265 | `"Vault index not ready"` | `"Vault: index not ready"` |
| 59 | `task_hierarchy.lua` | 294 | `"No task hierarchies found in vault"` | `"Vault: no task hierarchies found in vault"` |
| 60 | `task_hierarchy.lua` | 338 | `"No task hierarchies found in vault"` | `"Vault: no task hierarchies found in vault"` |
| 61 | `graph.lua` | 428 | `"Vault index not ready"` | `"Vault: index not ready"` |
| 62 | `search.lua` | 449 | `"Search parse error: " .. err` | `"Vault: search parse error: " .. err` |
| 63 | `search.lua` | 457 | `"Vault index not ready. Falling back to text search."` | `"Vault: index not ready, falling back to text search"` |
| 64 | `search.lua` | 488 | `"Advanced search: text filter..."` | `"Vault: advanced search text filter narrowed to 0 content matches; showing metadata matches"` |
| 65 | `search.lua` | 630 | `"No search history"` | `"Vault: no search history"` |
| 66 | `search.lua` | 687 | `"Vault index not ready for advanced live search."` | `"Vault: index not ready for advanced live search"` |
| 67 | `search.lua` | 1213 | `"No files to search"` | `"Vault: no files to search"` |
| 68 | `footnotes.lua` | 186 | `"No footnote under cursor"` | `"Vault: no footnote under cursor"` |
| 69 | `footnotes.lua` | 207 | `"No reference found for [^" .. id .. "]"` | `"Vault: no reference found for [^" .. id .. "]"` |
| 70 | `footnotes.lua` | 217 | `"No definition found for [^" .. id .. "]"` | `"Vault: no definition found for [^" .. id .. "]"` |
| 71 | `footnotes.lua` | 231 | `"No footnotes in buffer"` | `"Vault: no footnotes in buffer"` |
| 72 | `footnotes.lua` | 285 | `"No footnotes in buffer"` | `"Vault: no footnotes in buffer"` |
| 73 | `footnotes.lua` | 348 | `"No footnotes in buffer"` | `"Vault: no footnotes in buffer"` |
| 74 | `footnotes.lua` | 421 | `"Vault footnotes: ..."` | Keep -- already has Vault prefix |
| 75 | `footnotes.lua` | 548 | `"No footnotes in buffer"` | `"Vault: no footnotes in buffer"` |
| 76 | `footnotes.lua` | 568 | `"All footnotes are properly linked"` | `"Vault: all footnotes are properly linked"` |
| 77 | `inline_fields.lua` | 598 | `"No inline fields found in this buffer"` | `"Vault: no inline fields found in this buffer"` |
| 78 | `inline_fields.lua` | 653 | `"No inline fields found in this buffer"` | `"Vault: no inline fields found in this buffer"` |
| 79 | `pickers.lua` | 207 | `"Sticky project: " .. name` | `"Vault: sticky project: " .. name` |
| 80 | `pickers.lua` | 209 | `"No sticky project set"` | `"Vault: no sticky project set"` |
| 81 | `pickers.lua` | 218 | `"Sticky project set: " .. name` | `"Vault: sticky project set: " .. name` |
| 82 | `pickers.lua` | 223 | `"Sticky project cleared"` | `"Vault: sticky project cleared"` |
| 83 | `pickers.lua` | 231 | `"Sticky project cleared"` | `"Vault: sticky project cleared"` |
| 84 | `pickers.lua` | 248 | `"Sticky project cleared"` | `"Vault: sticky project cleared"` |
| 85 | `search_history.lua` | 157 | `"Deleted from history: " .. query` | `"Vault: deleted from history: " .. query` |
| 86 | `rename.lua` | 375 | `"Renamed '" .. old .. "' -> '" .. new .. "'"` | `"Vault: renamed '" .. old .. "' -> '" .. new .. "'"` |
| 87 | `rename.lua` | 492 | `"Renamed tag #" .. otag .. " -> #" .. ntag` | `"Vault: renamed tag #" .. otag .. " -> #" .. ntag` |
| 88 | `connections.lua` | 682 | `"Usage: :VaultConnectionDebug <note_name>"` | `"Vault: usage: :VaultConnectionDebug <note_name>"` |

### Sub-Module Prefixes to Normalize

The `"metaedit: "` prefix should become `"Vault: "` since metaedit is a vault
sub-feature, not a standalone tool. Similarly, bare sub-module prefixes like
`"Kanban: "`, `"Sidebar: "`, `"Frontmatter editor: "`, `"Graph filter: "`
should become `"Vault: "` for consistency.

| # | File | Line | Current Prefix | Proposed Prefix |
|---|------|------|----------------|-----------------|
| 89 | `metaedit.lua` | 127 | `"metaedit: "` | `"Vault: "` |
| 90 | `metaedit.lua` | 140 | `"metaedit: "` | `"Vault: "` |
| 91 | `metaedit.lua` | 150 | `"metaedit: "` | `"Vault: "` |
| 92 | `metaedit.lua` | 181 | `"metaedit: "` | `"Vault: "` |
| 93 | `metaedit.lua` | 206 | `"metaedit: "` | `"Vault: "` |
| 94 | `metaedit.lua` | 232 | `"metaedit: "` | `"Vault: "` |
| 95 | `metaedit.lua` | 275 | `"Usage: VaultMetaEdit"` | `"Vault: usage: VaultMetaEdit [field] [value]"` |
| 96 | `metaedit.lua` | 289 | `"Usage: VaultMetaCycle"` | `"Vault: usage: VaultMetaCycle [field]"` |
| 97 | `metaedit.lua` | 300 | `"metaedit: "` | `"Vault: "` |
| 98 | `metaedit.lua` | 312 | `"Usage: VaultMetaToggle"` | `"Vault: usage: VaultMetaToggle [field]"` |
| 99 | `frontmatter_editor.lua` | 223 | `"metaedit: "` | `"Vault: "` |
| 100 | `frontmatter_editor.lua` | 266 | `"metaedit: "` | `"Vault: "` |
| 101 | `frontmatter_editor.lua` | 272 | `"metaedit: "` | `"Vault: "` |
| 102 | `frontmatter_editor.lua` | 507 | `"List is empty"` | `"Vault: list is empty"` |
| 103 | `frontmatter_editor.lua` | 613 | `"Field '" .. key .. "' already exists"` | `"Vault: field '" .. key .. "' already exists"` |
| 104 | `frontmatter_editor.lua` | 768 | `"Frontmatter editor: "` | `"Vault: "` |
| 105 | `task_kanban.lua` | 411 | `"Kanban: "` | `"Vault: "` |
| 106 | `task_kanban.lua` | 439 | `"Kanban: "` | `"Vault: "` |
| 107 | `task_kanban.lua` | 467 | `"Kanban: "` | `"Vault: "` |
| 108 | `task_kanban.lua` | 480 | `"Kanban: "` | `"Vault: "` |
| 109 | `sidebar_meta.lua` | 343 | `"Sidebar: "` | `"Vault: "` |
| 110 | `graph_filter.lua` | 159 | `"Graph filter: "` | `"Vault: "` |
| 111 | `graph_filter.lua` | 166 | `"Graph filter: "` | `"Vault: "` |
| 112 | `graph_filter.lua` | 705 | `"Invalid search expression: "` | `"Vault: invalid search expression: "` |

---

## Implementation

### Target Files

Every file listed in the tables above requires edits. The changes are purely
mechanical string replacements and `vim.log.levels.*` constant swaps. No
logic, control flow, or function signatures change.

### Execution Order

Process files alphabetically to make progress trackable. Within each file,
apply level changes first (since they are fewer and more impactful), then
prefix changes.

---

### File 1: `lua/andrew/vault/autofile.lua`

#### Change 1: ERROR -> WARN (line 89)

**Before:**

```lua
    vim.notify("Destination already exists: " .. dest, vim.log.levels.ERROR)
```

**After:**

```lua
    vim.notify("Vault: destination already exists: " .. dest, vim.log.levels.WARN)
```

#### Change 2: Prefix (line 81)

**Before:**

```lua
    vim.notify("Already in correct directory", vim.log.levels.INFO)
```

**After:**

```lua
    vim.notify("Vault: already in correct directory", vim.log.levels.INFO)
```

#### Change 3: Prefix (line 95)

**Before:**

```lua
    vim.notify("Failed to move file", vim.log.levels.ERROR)
```

**After:**

```lua
    vim.notify("Vault: failed to move file", vim.log.levels.ERROR)
```

#### Change 4: Prefix (line 104)

**Before:**

```lua
  vim.notify("Moved: " .. filepath .. " -> " .. dest, vim.log.levels.INFO)
```

**After:**

```lua
  vim.notify("Vault: moved " .. filepath .. " -> " .. dest, vim.log.levels.INFO)
```

---

### File 2: `lua/andrew/vault/blockid.lua`

#### Change 1: ERROR -> WARN (line 150)

**Before:**

```lua
      vim.notify("Vault: could not resolve target note", vim.log.levels.ERROR)
```

**After:**

```lua
      vim.notify("Vault: could not resolve target note", vim.log.levels.WARN)
```

#### Change 2: ERROR -> WARN (line 157)

**Before:**

```lua
      vim.notify("Vault: could not read " .. target_path, vim.log.levels.ERROR)
```

**After:**

```lua
      vim.notify("Vault: could not read " .. target_path, vim.log.levels.WARN)
```

---

### File 3: `lua/andrew/vault/capture.lua`

#### Change 1: Prefix (line 76)

**Before:**

```lua
    vim.notify("Captured to " .. date, vim.log.levels.INFO)
```

**After:**

```lua
    vim.notify("Vault: captured to " .. date, vim.log.levels.INFO)
```

#### Change 2: Prefix (line 96)

**Before:**

```lua
    vim.notify("Captured to Inbox", vim.log.levels.INFO)
```

**After:**

```lua
    vim.notify("Vault: captured to Inbox", vim.log.levels.INFO)
```

---

### File 4: `lua/andrew/vault/engine.lua`

#### Change 1: ERROR -> WARN (line 117)

**Before:**

```lua
    vim.notify("Vault: unknown vault '" .. name .. "'", vim.log.levels.ERROR)
```

**After:**

```lua
    vim.notify("Vault: unknown vault '" .. name .. "'", vim.log.levels.WARN)
```

#### Change 2: WARN -> ERROR (line 283)

**Before:**

```lua
      vim.notify("Vault: failed to write " .. path(), vim.log.levels.WARN)
```

**After:**

```lua
      vim.notify("Vault: failed to write " .. path(), vim.log.levels.ERROR)
```

#### Change 3: WARN -> ERROR (line 329)

**Before:**

```lua
    vim.notify("Vault: failed to write " .. path .. ": " .. (err or "unknown"), vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: failed to write " .. path .. ": " .. (err or "unknown"), vim.log.levels.ERROR)
```

#### Change 4: WARN -> ERROR (line 344)

**Before:**

```lua
    vim.notify("Vault: failed to append to " .. path .. ": " .. (err or "unknown"), vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: failed to append to " .. path .. ": " .. (err or "unknown"), vim.log.levels.ERROR)
```

#### Change 5: Prefix (line 389)

**Before:**

```lua
  vim.notify("Created: " .. rel_path .. ".md", vim.log.levels.INFO)
```

**After:**

```lua
  vim.notify("Vault: created " .. rel_path .. ".md", vim.log.levels.INFO)
```

---

### File 5: `lua/andrew/vault/footnotes.lua`

#### Change 1: WARN -> INFO (line 592)

**Before:**

```lua
  vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
```

**After:**

```lua
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
```

#### Change 2-8: Prefix (lines 186, 207, 217, 231, 285, 348, 548, 568)

All bare `"No footnote..."` and `"All footnotes..."` messages gain the
`"Vault: "` prefix and lowercase the first word after the prefix. Example:

**Before:**

```lua
    vim.notify("No footnote under cursor", vim.log.levels.INFO)
```

**After:**

```lua
    vim.notify("Vault: no footnote under cursor", vim.log.levels.INFO)
```

Apply the same pattern to all eight lines.

---

### File 6: `lua/andrew/vault/frontmatter_editor.lua`

#### Change 1-3: Prefix normalization (lines 223, 266, 272)

**Before:**

```lua
  vim.notify("metaedit: " .. key .. " = [" .. #items .. " items]", vim.log.levels.INFO)
```

**After:**

```lua
  vim.notify("Vault: " .. key .. " = [" .. #items .. " items]", vim.log.levels.INFO)
```

#### Change 4: Prefix (line 507)

**Before:**

```lua
        vim.notify("List is empty", vim.log.levels.WARN)
```

**After:**

```lua
        vim.notify("Vault: list is empty", vim.log.levels.WARN)
```

#### Change 5: Prefix (line 613)

**Before:**

```lua
        vim.notify("Field '" .. new_key .. "' already exists", vim.log.levels.WARN)
```

**After:**

```lua
        vim.notify("Vault: field '" .. new_key .. "' already exists", vim.log.levels.WARN)
```

#### Change 6: Prefix (line 768)

**Before:**

```lua
    vim.notify("Frontmatter editor: not a vault file", vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: not a vault file", vim.log.levels.WARN)
```

---

### File 7: `lua/andrew/vault/graph.lua`

#### Change 1: Prefix (line 428)

**Before:**

```lua
    vim.notify("Vault index not ready", vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: index not ready", vim.log.levels.WARN)
```

#### Change 2: Prefix (line 722)

**Before:**

```lua
          vim.notify("Created: " .. unresolved_name .. ".md", vim.log.levels.INFO)
```

**After:**

```lua
          vim.notify("Vault: created " .. unresolved_name .. ".md", vim.log.levels.INFO)
```

---

### File 8: `lua/andrew/vault/graph_filter.lua`

#### Change 1: Prefix (line 159)

**Before:**

```lua
    vim.notify("Graph filter: text search terms are not supported in " ..
      "search expressions. Use metadata filters only (tag:, type:, has:, etc.)",
      vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: text search terms are not supported in " ..
      "search expressions. Use metadata filters only (tag:, type:, has:, etc.)",
      vim.log.levels.WARN)
```

#### Change 2: Prefix (line 166)

**Before:**

```lua
    vim.notify("Graph filter: text search terms ignored in search expression. " ..
      "Only metadata filters are applied.",
      vim.log.levels.INFO)
```

**After:**

```lua
    vim.notify("Vault: text search terms ignored in search expression. " ..
      "Only metadata filters are applied.",
      vim.log.levels.INFO)
```

#### Change 3: Prefix (line 705)

**Before:**

```lua
            vim.notify("Invalid search expression: " .. (err or "unknown"),
              vim.log.levels.WARN)
```

**After:**

```lua
            vim.notify("Vault: invalid search expression: " .. (err or "unknown"),
              vim.log.levels.WARN)
```

---

### File 9: `lua/andrew/vault/images.lua`

#### Change 1: ERROR -> WARN (line 20)

**Before:**

```lua
    vim.notify("Vault: xsel does not support image paste", vim.log.levels.ERROR)
```

**After:**

```lua
    vim.notify("Vault: xsel does not support image paste", vim.log.levels.WARN)
```

#### Change 2: ERROR -> WARN (line 23)

**Before:**

```lua
    vim.notify("Vault: no clipboard tool found (need xclip or wl-paste)", vim.log.levels.ERROR)
```

**After:**

```lua
    vim.notify("Vault: no clipboard tool found (need xclip or wl-paste)", vim.log.levels.WARN)
```

---

### File 10: `lua/andrew/vault/init.lua`

#### Change 1: ERROR -> WARN (line 56)

**Before:**

```lua
  vim.notify("Vault: unknown template '" .. name .. "'", vim.log.levels.ERROR)
```

**After:**

```lua
  vim.notify("Vault: unknown template '" .. name .. "'", vim.log.levels.WARN)
```

---

### File 11: `lua/andrew/vault/inline_fields.lua`

#### Change 1-2: Prefix (lines 598, 653)

**Before:**

```lua
      vim.notify("No inline fields found in this buffer", vim.log.levels.INFO)
```

**After:**

```lua
      vim.notify("Vault: no inline fields found in this buffer", vim.log.levels.INFO)
```

---

### File 12: `lua/andrew/vault/link_repair.lua`

#### Change 1: ERROR -> WARN (line 190)

**Before:**

```lua
    vim.notify("Vault: fzf-lua required for link repair picker", vim.log.levels.ERROR)
```

**After:**

```lua
    vim.notify("Vault: fzf-lua required for link repair picker", vim.log.levels.WARN)
```

#### Change 2: ERROR -> WARN (line 494)

**Before:**

```lua
      vim.notify("Vault: fzf-lua required for vault-wide link repair", vim.log.levels.ERROR)
```

**After:**

```lua
      vim.notify("Vault: fzf-lua required for vault-wide link repair", vim.log.levels.WARN)
```

---

### File 13: `lua/andrew/vault/linkcheck.lua`

#### Change 1: WARN -> INFO (line 388)

**Before:**

```lua
    vim.notify(
      "Vault: found " .. #broken_links .. " broken link(s) out of " .. total,
      vim.log.levels.WARN
    )
```

**After:**

```lua
    vim.notify(
      "Vault: found " .. #broken_links .. " broken link(s) out of " .. total,
      vim.log.levels.INFO
    )
```

#### Change 2: WARN -> INFO (line 474)

**Before:**

```lua
      vim.notify(
        "Vault: " .. #dead .. " dead URL(s) found",
        vim.log.levels.WARN
      )
```

**After:**

```lua
      vim.notify(
        "Vault: " .. #dead .. " dead URL(s) found",
        vim.log.levels.INFO
      )
```

---

### File 14: `lua/andrew/vault/metaedit.lua`

#### Change 1-6: Prefix (lines 127, 140, 150, 181, 206, 232)

Replace `"metaedit: "` with `"Vault: "` in all six lines. Example:

**Before:**

```lua
  vim.notify("metaedit: " .. field_name .. " = " .. format_value(value), vim.log.levels.INFO)
```

**After:**

```lua
  vim.notify("Vault: " .. field_name .. " = " .. format_value(value), vim.log.levels.INFO)
```

#### Change 7: Prefix (line 300)

**Before:**

```lua
      vim.notify("metaedit: no known cycle values for '" .. field .. "'", vim.log.levels.WARN)
```

**After:**

```lua
      vim.notify("Vault: no known cycle values for '" .. field .. "'", vim.log.levels.WARN)
```

#### Change 8-10: WARN -> INFO + Prefix (lines 275, 289, 312)

**Before:**

```lua
      vim.notify("Usage: VaultMetaEdit [field] [value]", vim.log.levels.WARN)
```

**After:**

```lua
      vim.notify("Vault: usage: VaultMetaEdit [field] [value]", vim.log.levels.INFO)
```

Apply same pattern to lines 289 and 312.

---

### File 15: `lua/andrew/vault/pickers.lua`

#### Change 1-6: Prefix (lines 207, 209, 218, 223, 231, 248)

All `"Sticky project..."` / `"No sticky project..."` messages gain `"Vault: "`
prefix. Example:

**Before:**

```lua
      vim.notify("Sticky project set: " .. name, vim.log.levels.INFO)
```

**After:**

```lua
      vim.notify("Vault: sticky project set: " .. name, vim.log.levels.INFO)
```

---

### File 16: `lua/andrew/vault/preview.lua`

#### Change 1: Prefix (line 450)

**Before:**

```lua
    vim.notify("Cannot resolve link in preview", vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: cannot resolve link in preview", vim.log.levels.WARN)
```

#### Change 2-5: Prefix (lines 524, 626, 633, 736)

**Before:**

```lua
      vim.notify("No wikilink under cursor in preview", vim.log.levels.INFO)
```

**After:**

```lua
      vim.notify("Vault: no wikilink under cursor in preview", vim.log.levels.INFO)
```

Apply same pattern to all four lines.

#### Change 6: Prefix (line 743)

**Before:**

```lua
    vim.notify("Note not found: " .. link, vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: note not found: " .. link, vim.log.levels.WARN)
```

---

### File 17: `lua/andrew/vault/query/init.lua`

#### Change 1: WARN -> INFO (line 291)

**Before:**

```lua
              vim.notify("Vault query debug: block at line " .. i .. " (" .. block_type .. ") returned 0 results", vim.log.levels.WARN)
```

**After:**

```lua
              vim.notify("Vault query debug: block at line " .. i .. " (" .. block_type .. ") returned 0 results", vim.log.levels.INFO)
```

---

### File 18: `lua/andrew/vault/rename.lua`

#### Change 1: ERROR -> WARN (line 319)

**Before:**

```lua
      vim.notify("Vault: '" .. name .. ".md' already exists", vim.log.levels.ERROR)
```

**After:**

```lua
      vim.notify("Vault: '" .. name .. ".md' already exists", vim.log.levels.WARN)
```

#### Change 2: ERROR -> WARN (line 405)

**Before:**

```lua
      vim.notify("Vault: invalid tag name '" .. ntag .. "'", vim.log.levels.ERROR)
```

**After:**

```lua
      vim.notify("Vault: invalid tag name '" .. ntag .. "'", vim.log.levels.WARN)
```

#### Change 3-4: Prefix (lines 375, 492)

**Before:**

```lua
    vim.notify(
      "Renamed '" .. old_name .. "' -> '" .. name .. "' (" .. link_count .. " links in " .. #modified_files .. " files)",
      vim.log.levels.INFO
    )
```

**After:**

```lua
    vim.notify(
      "Vault: renamed '" .. old_name .. "' -> '" .. name .. "' (" .. link_count .. " links in " .. #modified_files .. " files)",
      vim.log.levels.INFO
    )
```

---

### File 19: `lua/andrew/vault/search.lua`

#### Change 1: ERROR -> WARN (line 449)

**Before:**

```lua
      vim.notify("Search parse error: " .. (err or "unknown"), vim.log.levels.ERROR)
```

**After:**

```lua
      vim.notify("Vault: search parse error: " .. (err or "unknown"), vim.log.levels.WARN)
```

#### Change 2-5: Prefix (lines 457, 488, 630, 687, 1213)

Normalize all bare messages to `"Vault: "` prefix. Example:

**Before:**

```lua
      vim.notify("Vault index not ready. Falling back to text search.", vim.log.levels.WARN)
```

**After:**

```lua
      vim.notify("Vault: index not ready, falling back to text search", vim.log.levels.WARN)
```

---

### File 20: `lua/andrew/vault/search_history.lua`

#### Change 1: Prefix (line 157)

**Before:**

```lua
          vim.notify("Deleted from history: " .. item.query, vim.log.levels.INFO)
```

**After:**

```lua
          vim.notify("Vault: deleted from history: " .. item.query, vim.log.levels.INFO)
```

---

### File 21: `lua/andrew/vault/sidebar_meta.lua`

#### Change 1: Prefix (line 343)

**Before:**

```lua
      vim.notify("Sidebar: can only delete frontmatter fields", vim.log.levels.WARN)
```

**After:**

```lua
      vim.notify("Vault: can only delete frontmatter fields", vim.log.levels.WARN)
```

---

### File 22: `lua/andrew/vault/tags.lua`

#### Change 1: ERROR -> WARN (line 149)

**Before:**

```lua
      vim.notify("Vault: fd/fdfind not found", vim.log.levels.ERROR)
```

**After:**

```lua
      vim.notify("Vault: fd/fdfind not found", vim.log.levels.WARN)
```

---

### File 23: `lua/andrew/vault/task_hierarchy.lua`

#### Change 1-3: Prefix (lines 265, 294, 338)

**Before:**

```lua
    vim.notify("Vault index not ready", vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: index not ready", vim.log.levels.WARN)
```

**Before:**

```lua
    vim.notify("No task hierarchies found in vault", vim.log.levels.INFO)
```

**After:**

```lua
    vim.notify("Vault: no task hierarchies found in vault", vim.log.levels.INFO)
```

---

### File 24: `lua/andrew/vault/task_kanban.lua`

#### Change 1: ERROR -> WARN (line 467)

**Before:**

```lua
    vim.notify("Kanban: no columns configured", vim.log.levels.ERROR)
```

**After:**

```lua
    vim.notify("Vault: no kanban columns configured", vim.log.levels.WARN)
```

#### Change 2-4: Prefix (lines 411, 439, 480)

Replace `"Kanban: "` with `"Vault: "`. Example:

**Before:**

```lua
    vim.notify("Kanban: vault index not ready", vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: kanban index not ready", vim.log.levels.WARN)
```

---

### File 25: `lua/andrew/vault/task_notify.lua`

#### Change 1: WARN -> INFO (line 129)

**Before:**

```lua
  vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN, { title = "Vault" })
```

**After:**

```lua
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Vault" })
```

#### Change 2: ERROR -> WARN (line 152)

**Before:**

```lua
    vim.notify("fzf-lua is required for :VaultOverdue", vim.log.levels.ERROR)
```

**After:**

```lua
    vim.notify("Vault: fzf-lua is required for :VaultOverdue", vim.log.levels.WARN)
```

#### Change 3: Prefix (line 158)

**Before:**

```lua
    vim.notify("No overdue tasks", vim.log.levels.INFO, { title = "Vault" })
```

**After:**

```lua
    vim.notify("Vault: no overdue tasks", vim.log.levels.INFO, { title = "Vault" })
```

---

### File 26: `lua/andrew/vault/task_timeline.lua`

#### Change 1-2: Prefix (lines 365, 418)

**Before:**

```lua
      vim.notify("No task under cursor", vim.log.levels.INFO)
```

**After:**

```lua
      vim.notify("Vault: no task under cursor", vim.log.levels.INFO)
```

---

### File 27: `lua/andrew/vault/tasks.lua`

#### Change 1-2: Prefix (lines 91, 161)

**Before:**

```lua
    vim.notify("No task checkbox on current line", vim.log.levels.WARN)
```

**After:**

```lua
    vim.notify("Vault: no task checkbox on current line", vim.log.levels.WARN)
```

---

### File 28: `lua/andrew/vault/user_templates.lua`

#### Change 1-2: Prefix (lines 494, 596)

**Before:**

```lua
  vim.notify("Inserted template: " .. template.name, vim.log.levels.INFO)
```

**After:**

```lua
  vim.notify("Vault: inserted template " .. template.name, vim.log.levels.INFO)
```

---

### File 29: `lua/andrew/vault/wikilinks.lua`

#### Change 1-6: Prefix (lines 278, 286, 316, 354, 379, 393)

All bare `"Heading not found"`, `"Block not found"`, `"Created:"`,
`"File not found"` messages gain `"Vault: "` prefix. Example:

**Before:**

```lua
        vim.notify("Heading not found: #" .. details.heading, vim.log.levels.WARN)
```

**After:**

```lua
        vim.notify("Vault: heading not found: #" .. details.heading, vim.log.levels.WARN)
```

---

### File 30: `lua/andrew/vault/connections.lua`

#### Change 1: Prefix (line 682)

**Before:**

```lua
      vim.notify("Usage: :VaultConnectionDebug <note_name>", vim.log.levels.INFO)
```

**After:**

```lua
      vim.notify("Vault: usage: :VaultConnectionDebug <note_name>", vim.log.levels.INFO)
```

---

### File 31: `lua/andrew/vault/export.lua`

#### Change 1: Prefix (line 359)

**Before:**

```lua
            vim.notify("Exported: " .. stem .. "." .. format, vim.log.levels.INFO)
```

**After:**

```lua
            vim.notify("Vault: exported " .. stem .. "." .. format, vim.log.levels.INFO)
```

---

### File 32: `lua/andrew/vault/fragments.lua`

#### Change 1: Prefix (line 287)

**Before:**

```lua
        vim.notify("Inserted: " .. f.name, vim.log.levels.INFO)
```

**After:**

```lua
        vim.notify("Vault: inserted fragment " .. f.name, vim.log.levels.INFO)
```

---

## Testing Instructions

### 1. Level Change Verification

For each level change, trigger the notification and verify the color:

- **ERROR (red):** Open a vault note, trigger `engine.write_file()` on a
  read-only path (e.g., `chmod 000` a test file, attempt save). Should show
  red.
- **WARN (yellow):** Run `:VaultSwitch nonexistent_vault`. Should show yellow
  instead of red.
- **INFO (blue):** Run `:VaultLinkCheck` on a vault with broken links. The
  summary should show blue, not yellow. The individual broken link entries
  are shown in the fzf picker, not via notify.

### 2. Prefix Verification

After applying all prefix changes, run a grep to confirm no bare messages
remain:

```vim
:vimgrep /vim\.notify("[^Vt]/ lua/andrew/vault/**/*.lua
```

This pattern catches any `vim.notify(` where the message does not start with
`V` (for "Vault") or `t` (for `table.concat`). The only exceptions should be
`table.concat` calls (which build multi-line messages that start with "Vault:"
in their first line).

### 3. Regression Check

Open a daily log, toggle embeds, follow a broken wikilink, run `:VaultTags`,
run `:VaultSearch`, run `:VaultRename`, run `:VaultMetaCycle status`. Confirm
that all notifications display correctly with proper prefix and color.

### 4. Edge Cases

- Run `:VaultMetaEdit` with no arguments -- should show blue INFO "usage"
  hint, not yellow WARN.
- Run `:VaultOverdue` without fzf-lua loaded -- should show yellow WARN, not
  red ERROR.
- Open a non-vault file and run `:VaultPin` -- should show yellow WARN with
  "Vault:" prefix.

---

## Summary of Changes

| File | Level Changes | Prefix Changes | Total Edits |
|------|---------------|----------------|-------------|
| `autofile.lua` | 1 (ERROR->WARN) | 3 | 4 |
| `blockid.lua` | 2 (ERROR->WARN) | 0 | 2 |
| `capture.lua` | 0 | 2 | 2 |
| `connections.lua` | 0 | 1 | 1 |
| `engine.lua` | 1 (ERROR->WARN), 3 (WARN->ERROR) | 1 | 5 |
| `export.lua` | 0 | 1 | 1 |
| `footnotes.lua` | 1 (WARN->INFO) | 8 | 9 |
| `fragments.lua` | 0 | 1 | 1 |
| `frontmatter_editor.lua` | 0 | 6 | 6 |
| `graph.lua` | 0 | 2 | 2 |
| `graph_filter.lua` | 0 | 3 | 3 |
| `images.lua` | 2 (ERROR->WARN) | 0 | 2 |
| `init.lua` | 1 (ERROR->WARN) | 0 | 1 |
| `inline_fields.lua` | 0 | 2 | 2 |
| `link_repair.lua` | 2 (ERROR->WARN) | 0 | 2 |
| `linkcheck.lua` | 2 (WARN->INFO) | 0 | 2 |
| `metaedit.lua` | 3 (WARN->INFO) | 7 | 10 |
| `pickers.lua` | 0 | 6 | 6 |
| `preview.lua` | 0 | 6 | 6 |
| `query/init.lua` | 1 (WARN->INFO) | 0 | 1 |
| `rename.lua` | 2 (ERROR->WARN) | 2 | 4 |
| `search.lua` | 1 (ERROR->WARN) | 4 | 5 |
| `search_history.lua` | 0 | 1 | 1 |
| `sidebar_meta.lua` | 0 | 1 | 1 |
| `tags.lua` | 1 (ERROR->WARN) | 0 | 1 |
| `task_hierarchy.lua` | 0 | 3 | 3 |
| `task_kanban.lua` | 1 (ERROR->WARN) | 3 | 4 |
| `task_notify.lua` | 1 (WARN->INFO), 1 (ERROR->WARN) | 2 | 4 |
| `task_timeline.lua` | 0 | 2 | 2 |
| `tasks.lua` | 0 | 2 | 2 |
| `user_templates.lua` | 0 | 2 | 2 |
| `wikilinks.lua` | 0 | 6 | 6 |
| **Total** | **26 level changes** | **77 prefix changes** | **103 edits** |

No new files are created. No function signatures, control flow, or logic
changes. No new dependencies. All changes are string literal replacements and
`vim.log.levels.*` constant swaps.
