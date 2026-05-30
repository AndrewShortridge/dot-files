# 39 — Improve Search Discoverability

## Motivation

The vault advanced search system is one of the most powerful features in the plugin. It supports boolean logic, field filters, task metadata queries, link-relationship filters, graph traversal, regex, result grouping, and more. However, this power is largely hidden from the user:

1. **The fzf header shows operator names but no concrete examples.** A user seeing `field:value tag:x` for the first time does not know what fields exist, what values are valid, or what the output looks like.

2. **The `:VaultSearchHelp` float exists but is not prominently discoverable.** Users must already know about `Ctrl-/` or the command name to find it. There is no onboarding pathway for new users.

3. **Link filters (`links-to:`, `linked-from:`, `alias:`) are undocumented in KEYMAPS-REFERENCE.md.** The advanced search keymaps (`<leader>vfA`, `:VaultSearchAdvanced`, `:VaultSearchAdvancedLive`) are also missing from the reference entirely.

4. **The graph operator has no examples in the fzf header** and its documentation in the help float is sparse compared to its expressive power.

5. **No first-time guidance.** A user who opens `<leader>vfA` for the first time gets a blank prompt with a dense footer. There is no nudge toward the help system.

---

## Current State Analysis

### `search_help()` — Floating Help Window

**File:** `lua/andrew/vault/search.lua`, lines 778-900

The current `search_help()` function creates a floating window with a comprehensive syntax reference. It is well-structured and covers all operator categories. However:

| Aspect | Current State | Issue |
|--------|--------------|-------|
| **Content** | ~90 lines covering text, fields, dates, tasks, links, graph, boolean, grouping | Content is solid but lacks a "Quick Start" section for newcomers |
| **Width** | Fixed at 55 columns | Some example lines are truncated or feel cramped |
| **Highlighting** | `filetype = "markdown"` | Markdown highlighting is wrong for this content; operator names, values, and comments blend together |
| **Navigation** | Scroll only (no sections, no jump keys) | Long document with no way to jump to a category |
| **Closing** | `q` or `<Esc>` | Good |
| **Discoverability** | `Ctrl-/` in prompt/live mode, `:VaultSearchHelp` command | No mention in KEYMAPS-REFERENCE.md; no first-time hint |

### `SEARCH_HEADER` — fzf Header Content

**File:** `lua/andrew/vault/search.lua`, lines 89-93

```lua
local SEARCH_HEADER = table.concat({
  "field:value  tag:x  task-due:<7d  has:tags  created:>7d  graph:depth=2  group:folder",
  "AND  OR  NOT  -excluded  (a OR b) AND c   |  Ctrl-/ full help  Ctrl-g graph",
}, "\n")
```

Issues:
- Line 1 lists operators abstractly (`field:value`) rather than showing a concrete, copy-paste-ready example
- No example of `links-to:`, `linked-from:`, or `alias:` filters
- No example of quoted values (essential for multi-word note names)
- `Ctrl-/` and `Ctrl-g` are mentioned but could be more prominent
- Stats line (when `config.search.show_stats ~= false`) is prepended, pushing the header further from view

### KEYMAPS-REFERENCE.md — Missing Entries

**File:** `KEYMAPS-REFERENCE.md`

Section 31 ("Vault -- Search & Find") lists basic search keymaps but is missing:

| Missing Entry | Type | Description |
|---------------|------|-------------|
| `<leader>vfA` | Keymap | Advanced search (live mode) |
| `<leader>vfH` | Keymap | Search history picker |
| `:VaultSearchAdvanced` | Command | Advanced search (prompt mode) |
| `:VaultSearchAdvancedLive` | Command | Advanced search (live mode) |
| `:VaultSearchHelp` | Command | Search syntax help float |

Section 45 ("User Commands") lists vault commands but is missing the three search commands above.

There is no mention anywhere in the document of the advanced search query syntax, the link filters, or the graph operator.

---

## Implementation Plan

### Feature 1: Enhanced `:VaultSearchHelp` Float

#### 1a. Content Restructuring

Reorganize the help content into clearly labeled sections with a "Quick Start" preamble. Each section gets a distinct visual separator. Examples should be concrete and immediately usable.

**New content structure:**

```lua
local lines = {
  "╔══════════════════════════════════════════════════════════════╗",
  "║                    VAULT SEARCH REFERENCE                   ║",
  "╚══════════════════════════════════════════════════════════════╝",
  "",
  "Quick Start:",
  "  type:meeting tag:active         Notes of type 'meeting' with tag 'active'",
  "  task-due:<today                 Overdue tasks",
  "  links-to:\"Project Alpha\"        Notes linking to Project Alpha",
  "  graph:depth=2 has:tasks         Notes within 2 hops that have tasks",
  "",
  "── Text Search ──────────────────────────────────────────────────",
  "",
  "  deploy                          Plain text (ripgrep)",
  "  \"exact phrase\"                  Quoted exact match",
  "  /^## Results/                   Regex pattern (PCRE2)",
  "  /pattern/i                      Case-insensitive regex",
  "  /pattern/m                      Multiline regex",
  "  /pattern/s                      Dotall (. matches newline)",
  "",
  "── Field Filters ───────────────────────────────────────────────",
  "",
  "  type:meeting                    Frontmatter 'type' field",
  "  tag:project/active              Has tag (or child tag)",
  "  tag:project,-archived           Tag with exclusion",
  "  tag:project,-a,-b               Multiple exclusions",
  "  path:Projects/                  File path prefix",
  "  file:Dashboard                  Basename substring",
  "  folder:Projects/Alpha           Folder prefix",
  "  status:active                   Frontmatter 'status' field",
  "  priority:>3                     Numeric comparison (>, <, >=, <=)",
  "  priority:1..3                   Numeric range (inclusive)",
  "  <field>:                        Field exists (any value)",
  "",
  "── Date Filters ────────────────────────────────────────────────",
  "",
  "  modified:<7d                    Less than 7 days ago",
  "  modified:>30d                   More than 30 days ago",
  "  modified:last-7d                Within last 7 days",
  "  modified:today                  Modified today",
  "  modified:this-week              Since Monday",
  "  modified:this-month             Since 1st of month",
  "  created:2026-01-15              Exact date",
  "  created:2026-01..2026-02        Date range",
  "",
  "── Task Filters ────────────────────────────────────────────────",
  "",
  "  task:\"\"                         Any task in file",
  "  task-todo:\"\"                    Open tasks only",
  "  task-done:\"\"                    Completed tasks only",
  "  task-due:<today                 Overdue tasks",
  "  task-due:this-week              Tasks due this week",
  "  task-due:<7d                    Due within 7 days",
  "  task-priority:1                 Priority 1 tasks",
  "  task-priority:<=2               High priority (1 or 2)",
  "  task-priority:1..3              Priority range",
  "  task-tag:urgent                 Tasks tagged #urgent",
  "  task-state:in-progress          In-progress tasks",
  "  task-repeat:\"\"                  Recurring tasks (any repeat rule)",
  "  task-completion:<7d             Recently completed (within 7 days)",
  "  task-scheduled:this-week        Scheduled for this week",
  "",
  "── Link Filters ────────────────────────────────────────────────",
  "",
  "  links-to:NoteName               Notes that link to NoteName",
  "  links-to:Note#Heading           Notes linking to specific heading",
  "  links-to:\"Project Alpha\"        Quote names with spaces",
  "  linked-from:NoteName            Notes that NoteName links to",
  "  linked-from:Note#Heading        Notes linked from a heading section",
  "  alias:CFD                       Notes with alias 'CFD'",
  "",
  "── Existence Checks ────────────────────────────────────────────",
  "",
  "  has:tags                        Files with any tags",
  "  has:aliases                     Files with any aliases",
  "  has:outlinks                    Files containing wikilinks",
  "  has:inlinks                     Files linked to by other notes",
  "  has:tasks                       Files containing tasks",
  "  has:frontmatter                 Files with YAML frontmatter",
  "",
  "── Graph Traversal ─────────────────────────────────────────────",
  "",
  "  graph:neighbors                 Direct neighbors (depth=1, both dirs)",
  "  graph:extended                  Extended neighborhood (depth=2)",
  "  graph:depth=2                   Notes within 2 link-hops of current",
  "  graph:depth=3,dir=forward       3 hops following outlinks only",
  "  graph:depth=2,dir=backward      2 hops following inlinks only",
  "  graph:depth=2,center=Dashboard  2 hops from 'Dashboard' note",
  "  graph:depth=2 tag:active        Combine graph scope with filters",
  "  graph:depth=2 task-due:<today   Graph neighbors with overdue tasks",
  "",
  "── Boolean Logic ────────────────────────────────────────────────",
  "",
  "  term1 term2                     Implicit AND (both required)",
  "  term1 AND term2                 Explicit AND",
  "  term1 OR term2                  Either term matches",
  "  NOT term                        Exclude matches",
  "  -term                           Shorthand for NOT",
  "  -tag:archived                   Exclude specific field value",
  "  (a OR b) AND c                  Grouping with parentheses",
  "  type:meeting (tag:a OR tag:b)   Complex filter expression",
  "",
  "  Precedence: NOT > AND > OR",
  "",
  "── Result Grouping ─────────────────────────────────────────────",
  "",
  "  group:folder                    Group by parent folder",
  "  group:type                      Group by frontmatter type",
  "  group:tag                       Group by top-level tag",
  "  group:date                      Group by modification date",
  "  group:month                     Group by modification month",
  "  group:created                   Group by creation date",
  "  group:status                    Group by status field",
  "",
  "── Keybindings ──────────────────────────────────────────────────",
  "",
  "  Ctrl-/                          Toggle this help window",
  "  Ctrl-g                          Open graph view of search results",
  "  Ctrl-r                          Browse search history (prompt mode)",
  "  Tab                             Auto-complete field names (prompt mode)",
  "",
  "Press q or <Esc> to close.  Press / to search within this help.",
}
```

#### 1b. Float Window Creation — Width, Height, Scrolling

The current float uses a fixed width of 55 and height equal to the number of lines. This needs adjustment:

**Before (lines 874-895):**

```lua
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].modifiable = false
vim.bo[buf].bufhidden = "wipe"
vim.bo[buf].filetype = "markdown"

local width = 55
local height = #lines
local row = math.floor((vim.o.lines - height) / 2)
local col = math.floor((vim.o.columns - width) / 2)

local win = vim.api.nvim_open_win(buf, true, {
  relative = "editor",
  width = width,
  height = height,
  row = row,
  col = col,
  style = "minimal",
  border = "rounded",
  title = " Search Help ",
  title_pos = "center",
})

-- Close on q or Esc
vim.keymap.set("n", "q", function() cleanup.close_win(win) end, { buffer = buf })
vim.keymap.set("n", "<Esc>", function() cleanup.close_win(win) end, { buffer = buf })
```

**After:**

```lua
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].modifiable = false
vim.bo[buf].bufhidden = "wipe"
vim.bo[buf].buftype = "nofile"

local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
local width = math.min(68, ui.width - 4)
local height = math.min(#lines, ui.height - 4)
local row = math.floor((ui.height - height) / 2)
local col = math.floor((ui.width - width) / 2)

local win = vim.api.nvim_open_win(buf, true, {
  relative = "editor",
  width = width,
  height = height,
  row = row,
  col = col,
  style = "minimal",
  border = "rounded",
  title = " Search Syntax Reference ",
  title_pos = "center",
  footer = { { " q close  / search  j/k scroll ", "Comment" } },
  footer_pos = "center",
})

-- Disable line wrapping for clean layout
vim.wo[win].wrap = false
vim.wo[win].cursorline = true
vim.wo[win].sidescrolloff = 0

-- Close on q or Esc
local function close() cleanup.close_win(win) end
vim.keymap.set("n", "q", close, { buffer = buf })
vim.keymap.set("n", "<Esc>", close, { buffer = buf })

-- Section jump: ] goes to next section header, [ goes to previous
vim.keymap.set("n", "]", function()
  vim.fn.search("^──", "W")
end, { buffer = buf, desc = "Next section" })
vim.keymap.set("n", "[", function()
  vim.fn.search("^──", "bW")
end, { buffer = buf, desc = "Previous section" })

-- / to search within help
vim.keymap.set("n", "/", function()
  -- Temporarily make buffer searchable
  vim.cmd("/" )
end, { buffer = buf })
```

Key changes:
- **Width**: Increased from 55 to 68 to accommodate the longer example lines without truncation
- **Height**: Capped to `ui.height - 4` so the float never exceeds the terminal
- **Footer**: Added navigation hint footer
- **Section jumping**: `]` and `[` keys jump between section headers (lines starting with `──`)
- **Filetype**: Removed `filetype = "markdown"` (it produces wrong highlighting for this content)
- **Cursorline**: Enabled for easier reading while scrolling
- **Search**: `/` key activates Neovim's built-in search within the help buffer

#### 1c. Syntax Highlighting

Instead of relying on markdown filetype detection (which highlights incorrectly), apply custom highlighting via `nvim_buf_add_highlight` or a dedicated highlighting function.

```lua
-- Apply custom highlighting to the help buffer
local function apply_help_highlights(buf, lines)
  local ns = vim.api.nvim_create_namespace("vault_search_help")

  for i, line in ipairs(lines) do
    local row = i - 1  -- 0-indexed

    -- Box-drawing title lines
    if line:match("^[╔╚║]") then
      vim.api.nvim_buf_add_highlight(buf, ns, "Title", row, 0, -1)

    -- Section headers (── Text Search ──)
    elseif line:match("^──") then
      vim.api.nvim_buf_add_highlight(buf, ns, "Statement", row, 0, -1)

    -- Quick Start label
    elseif line:match("^Quick Start:") then
      vim.api.nvim_buf_add_highlight(buf, ns, "WarningMsg", row, 0, -1)

    -- Example lines: highlight the operator portion differently from the comment
    elseif line:match("^  %S") then
      -- Find the boundary between example and description
      -- Pattern: leading spaces, then the example, then spaces padding, then description
      local example_end = line:find("  %u", 3) or line:find("  [A-Z]", 3)
      if example_end then
        -- Operator/example part
        vim.api.nvim_buf_add_highlight(buf, ns, "Identifier", row, 0, example_end - 1)
        -- Description/comment part
        vim.api.nvim_buf_add_highlight(buf, ns, "Comment", row, example_end - 1, -1)
      else
        vim.api.nvim_buf_add_highlight(buf, ns, "Identifier", row, 0, -1)
      end

    -- Precedence line and other notes
    elseif line:match("^  Precedence:") then
      vim.api.nvim_buf_add_highlight(buf, ns, "WarningMsg", row, 0, -1)

    -- Closing instructions
    elseif line:match("^Press") then
      vim.api.nvim_buf_add_highlight(buf, ns, "Comment", row, 0, -1)
    end
  end
end
```

This produces a clean visual hierarchy:
- **Title** (gold/yellow): The top banner
- **Statement** (purple/keyword): Section divider lines
- **Identifier** (cyan/blue): The actual search operator examples
- **Comment** (gray): The plain-English descriptions
- **WarningMsg** (yellow/orange): Quick Start label and Precedence note

---

### Feature 2: Expanded fzf Header with Concrete Examples

#### Current Header

```lua
local SEARCH_HEADER = table.concat({
  "field:value  tag:x  task-due:<7d  has:tags  created:>7d  graph:depth=2  group:folder",
  "AND  OR  NOT  -excluded  (a OR b) AND c   |  Ctrl-/ full help  Ctrl-g graph",
}, "\n")
```

#### New Header

Replace the abstract operator listing with concrete, copy-paste-ready examples and clearer keybinding hints:

```lua
local SEARCH_HEADER = table.concat({
  "Examples: type:meeting tag:active  task-due:<today  links-to:\"Project Alpha\"  graph:depth=2",
  "Operators: AND  OR  NOT  -excluded  (a OR b)  group:folder  has:tasks  created:>7d",
  "Keys: Ctrl-/ help  Ctrl-g graph  Tab complete",
}, "\n")
```

Changes:
- **Line 1**: Real, useful examples a user can immediately adapt. Shows quoting for multi-word names.
- **Line 2**: Boolean operators, grouping, existence checks, date comparison — the building blocks.
- **Line 3**: Keybinding hints are on their own line with clear labels. Added `Tab complete` hint.
- Each line has a bold prefix label (`Examples:`, `Operators:`, `Keys:`) for quick scanning.

#### ANSI Color Support

Since fzf supports ANSI escape codes in headers, consider colorizing the labels:

```lua
local function header_label(text)
  return "\x1b[1;36m" .. text .. "\x1b[0m"  -- bold cyan
end

local function header_key(text)
  return "\x1b[1;33m" .. text .. "\x1b[0m"  -- bold yellow
end

local SEARCH_HEADER = table.concat({
  header_label("Examples:") .. " type:meeting tag:active  task-due:<today  links-to:\"Project Alpha\"  graph:depth=2",
  header_label("Operators:") .. " AND  OR  NOT  -excluded  (a OR b)  group:folder  has:tasks  created:>7d",
  header_label("Keys:") .. " " .. header_key("Ctrl-/") .. " help  " .. header_key("Ctrl-g") .. " graph  " .. header_key("Tab") .. " complete",
}, "\n")
```

This makes the header visually scannable even in a dense fzf listing. The `--ansi` flag is already set in the fzf options, so ANSI codes render correctly.

---

### Feature 3: KEYMAPS-REFERENCE.md Additions

#### 3a. Section 31 — Add Advanced Search Keymaps

Insert after the existing `<leader>vfS` row (line 799) and before the `---` separator (line 801):

```markdown
| `<leader>vfA` | search.lua | Advanced search — live mode (structured query) |
| `<leader>vfH` | search.lua | Search history (frecency-ranked) |
```

#### 3b. Section 31 — Add Advanced Search Subsection

Insert a new subsection after the table in Section 31 (after line 801):

```markdown

### Advanced Search Syntax (inside `<leader>vfA` or `:VaultSearchAdvanced`)

The advanced search supports structured queries with field filters, boolean logic, and graph traversal. Press `Ctrl-/` inside the search prompt for the full syntax reference.

**Inside advanced search picker:**

| Key | Action |
|-----|--------|
| `Ctrl-/` | Toggle search syntax help float |
| `Ctrl-g` | Open graph view of matched files |
| `Ctrl-r` | Browse search history (prompt mode) |
| `Tab` | Auto-complete field names (prompt mode) |

**Common query patterns:**

| Query | What It Finds |
|-------|---------------|
| `type:meeting tag:active` | Active meetings |
| `task-due:<today` | Overdue tasks |
| `task-due:this-week task-priority:<=2` | High-priority tasks due this week |
| `links-to:"Project Alpha"` | Notes linking to Project Alpha |
| `linked-from:Dashboard` | Notes that Dashboard links to |
| `alias:CFD` | Notes with alias "CFD" |
| `graph:depth=2 has:tasks` | Notes within 2 hops that contain tasks |
| `graph:depth=2,dir=forward,center=Dashboard` | 2-hop forward neighborhood of Dashboard |
| `has:aliases -tag:archived` | Notes with aliases, excluding archived tag |
| `(tag:project OR tag:area) type:note` | Notes tagged project or area |
| `modified:<7d group:folder` | Recently modified, grouped by folder |
```

#### 3c. Section 45 — Add Missing User Commands

Insert after the `:VaultStickyClear` row (line 1035) and before `### Plugin Commands` (line 1037):

```markdown
| `:VaultSearchAdvanced` | vault/search.lua | Advanced vault search (prompt mode) |
| `:VaultSearchAdvancedLive` | vault/search.lua | Advanced vault search (live mode) |
| `:VaultSearchHelp` | vault/search.lua | Show advanced search syntax reference |
```

---

### Feature 4: Graph Operator Documentation

The graph operator is the most complex and least documented feature. The help float content (Feature 1a above) already includes expanded graph examples. Additionally, document the parameter semantics clearly.

#### Graph Operator Parameters

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `depth` | 1-N (capped by `config.graph.max_depth`) | 1 | Number of link-hops to traverse |
| `dir` / `direction` | `forward`, `backward`, `both` | `both` | Direction of link traversal |
| `center` | Note name or `current` | `current` | Starting note for traversal |

#### Shorthand Forms

| Shorthand | Equivalent | Description |
|-----------|------------|-------------|
| `graph:neighbors` | `graph:depth=1,dir=both` | Direct neighbors of current note |
| `graph:extended` | `graph:depth=2,dir=both` | Extended neighborhood (2 hops) |

#### Combined Query Examples

These should appear in both the help float and the KEYMAPS-REFERENCE.md:

```
graph:depth=2 tag:active              Nearby active notes
graph:depth=3,dir=forward type:note   Forward 3-hop neighborhood, notes only
graph:depth=2,center=Dashboard        2 hops from Dashboard (regardless of current note)
graph:extended task-due:<today         Extended neighborhood with overdue tasks
graph:neighbors links-to:Meeting      Direct neighbors that also link to Meeting
graph:depth=2 (tag:a OR tag:b)        2-hop neighborhood with either tag
graph:depth=2 -tag:archived           2-hop neighborhood excluding archived notes
```

---

### Feature 5: First-Time Search Notification

#### Design

When a user opens the advanced search for the first time (ever, in this Neovim config), show a brief notification pointing them to the help system. Use a persistent flag file to avoid repeating.

#### Implementation

Add a helper function and call it from `search_advanced()` and `search_advanced_live()`:

```lua
--- Path to the first-time hint flag file.
local function hint_flag_path()
  return vim.fn.stdpath("data") .. "/vault-search-hint-shown"
end

--- Show a one-time hint about the search help system.
--- Only fires once per installation; sets a flag file afterward.
local function maybe_show_first_time_hint()
  local flag = hint_flag_path()
  if vim.uv.fs_stat(flag) then return end

  -- Create the flag file immediately so it never fires twice
  local fd = vim.uv.fs_open(flag, "w", 438)  -- 0o666
  if fd then
    vim.uv.fs_write(fd, "shown", -1)
    vim.uv.fs_close(fd)
  end

  -- Show a non-blocking notification after a short delay
  vim.defer_fn(function()
    vim.notify(
      "Tip: Press Ctrl-/ for the full search syntax reference, or run :VaultSearchHelp",
      vim.log.levels.INFO
    )
  end, 500)
end
```

Then call `maybe_show_first_time_hint()` at the top of both `search_advanced()` and `search_advanced_live()`.

**Why a flag file instead of a vim variable?**
- A vim variable (`vim.g.vault_search_hint_shown`) resets on restart -- the hint would fire on every Neovim session until the user learns the binding
- A flag file in `stdpath("data")` persists across sessions
- The file is tiny (5 bytes) and created atomically via `uv.fs_open`
- The user can delete it (`rm ~/.local/share/nvim/vault-search-hint-shown`) to see the hint again

---

## File-by-File Change Summary

### `lua/andrew/vault/search.lua`

| Section | Change |
|---------|--------|
| `SEARCH_HEADER` (line 90-93) | Replace with expanded 3-line header with concrete examples and ANSI labels |
| `search_help()` (line 778-900) | Replace content with restructured ~110-line reference; increase width to 68; add section jump keys `]`/`[`; add custom highlighting function; add footer with navigation hints; remove `filetype = "markdown"` |
| `search_advanced()` (line 564) | Add `maybe_show_first_time_hint()` call |
| `search_advanced_live()` (line 680) | Add `maybe_show_first_time_hint()` call |
| New function | `apply_help_highlights(buf, lines)` — custom namespace-based highlighting |
| New function | `maybe_show_first_time_hint()` — one-time flag-file-based notification |
| New function | `header_label(text)`, `header_key(text)` — ANSI helpers for fzf header |

### `KEYMAPS-REFERENCE.md`

| Section | Change |
|---------|--------|
| Section 31 table (line 799) | Add `<leader>vfA` and `<leader>vfH` rows |
| After Section 31 table | Add "Advanced Search Syntax" subsection with inner-picker keybindings and example queries |
| Section 45 table (line 1035) | Add `:VaultSearchAdvanced`, `:VaultSearchAdvancedLive`, `:VaultSearchHelp` commands |

---

## Implementation Order

1. **SEARCH_HEADER expansion** — Smallest change, immediate user benefit. Independent of other changes.
2. **search_help() content restructuring** — New content, wider float, better layout. No new dependencies.
3. **apply_help_highlights()** — Custom highlighting for the help float. Depends on step 2 (needs final content to write highlight rules).
4. **Section navigation keys** — `]`/`[` for jumping between help sections. Depends on step 2.
5. **KEYMAPS-REFERENCE.md updates** — Documentation only. Independent of code changes.
6. **First-time hint** — Flag file + deferred notification. Independent of other changes.

Steps 1, 5, and 6 can be done in parallel. Steps 2-4 are sequential.

---

## Testing Plan

- [ ] Open `:VaultSearchHelp` — verify all sections render, width/height are correct, no truncation
- [ ] Press `]` and `[` in the help float — verify section jumping works
- [ ] Press `/` in the help float — verify search works within the buffer
- [ ] Press `q` and `<Esc>` — verify the float closes cleanly
- [ ] Open `<leader>vfA` (live mode) — verify the new 3-line header appears in fzf
- [ ] Press `Ctrl-/` inside live mode — verify help float opens
- [ ] Press `Ctrl-/` inside prompt mode — verify help float opens and prompt regains focus on close
- [ ] Delete the flag file and open advanced search — verify the first-time hint notification appears
- [ ] Open advanced search again — verify the hint does not appear a second time
- [ ] Verify ANSI colors render in the fzf header (requires `--ansi` flag, already set)
- [ ] Check highlight groups in help float — verify Title, Statement, Identifier, Comment are applied correctly
- [ ] Review KEYMAPS-REFERENCE.md — verify new entries are in correct sections and tables parse correctly
