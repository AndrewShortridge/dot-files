# 10 -- Vault Statistics Dashboard

## Problem

There is no way to get an at-a-glance overview of vault health and composition. Individual commands exist for specific tasks -- `:VaultLinkCheckAll` finds broken links, `:VaultOrphans` finds orphan notes, `:VaultTagTree` shows tag distribution -- but a researcher must invoke each one separately and mentally aggregate the results. There is no single summary view that answers questions like "How large is my vault?", "What percentage of notes are orphaned?", "Which notes are my most-connected hubs?", or "How has my note-creation cadence changed over time?"

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **vault_index.lua** | Singleton index with all vault metadata: files, tags, headings, outlinks, inlinks, frontmatter, tasks | `lua/andrew/vault/vault_index.lua` |
| **linkcheck.lua** | `check_vault()` for broken links (async rg), `check_orphans()` for orphan detection (async rg) | `lua/andrew/vault/linkcheck.lua` |
| **connections.lua** | `compute()` scores related notes using tags, frontmatter, co-links, link proximity, temporal proximity | `lua/andrew/vault/connections.lua` |
| **tags.lua** | `collect_tags()`, `tags_with_counts()` via vault index | `lua/andrew/vault/tags.lua` |
| **config.lua** | `note_types` list, `dirs` structure, `scopes` definitions | `lua/andrew/vault/config.lua` |
| **ui.lua** | `create_float_display()` for read-only floating windows with `q`/`<Esc>` close keymaps | `lua/andrew/vault/ui.lua` |
| **engine.lua** | Vault path, `vault_relative()`, `is_vault_path()`, `cache_stats()`, `register_cache()` | `lua/andrew/vault/engine.lua` |
| **init.lua** | Module setup chain, `VaultIndexStatus` command showing file count and generation | `lua/andrew/vault/init.lua` |

### Why No Dashboard Exists Today

The vault index (`vault_index.lua`) already stores all the raw data needed: every file's outlinks, inlinks, tags, frontmatter (including `type` field), creation timestamps, folder paths, and tasks. But there is no module that aggregates this data into a summary. The closest existing commands are:

- `:VaultIndexStatus` (line 415 of `init.lua`) -- shows file count, ready state, and generation number (4 lines of output).
- `:VaultCacheStatus` (line 332 of `init.lua`) -- shows cache entry counts per module.

Neither produces vault-level analytics.

---

## Goal

Add a `:VaultStats` command that opens a styled floating window displaying a comprehensive vault statistics dashboard. The dashboard is computed entirely from the in-memory vault index (no disk I/O, no ripgrep) and should render in under 50ms for vaults of 1000+ notes.

The dashboard includes:

1. **Overview** -- total notes, total tags, total outlinks, total tasks (open/done).
2. **Orphan analysis** -- count of notes with zero inbound links, percentage of vault.
3. **Broken link summary** -- count of outlinks that do not resolve to existing notes.
4. **Most-connected notes** -- top 10 notes by total link degree (inlinks + outlinks).
5. **Tag distribution** -- top 15 tags by file count.
6. **Notes by type** -- counts grouped by the `type` frontmatter field.
7. **Notes by folder** -- counts grouped by top-level directory.
8. **Activity timeline** -- notes per month based on `day` field (daily log dates) or `ctime`.
9. **Task summary** -- total tasks by status character.

---

## Approach

### Architecture

Create a single new module `lua/andrew/vault/stats.lua` that:

1. Reads all data from `vault_index.current()` -- the singleton index is the sole data source.
2. Computes all statistics in a single pass over `idx.files` (O(n) where n = number of files).
3. Formats the results as styled text lines with highlight annotations.
4. Opens a floating window via `ui.create_float_display()` with per-line and per-region highlights.
5. Registers the `:VaultStats` command and `<leader>vS` keymap in its `setup()` function.

The module has zero caching -- it recomputes on every invocation from the live index. At O(n) with no I/O, this is fast enough (< 10ms for 1000 files) that caching would add complexity for no benefit.

### Data Flow

```
vault_index.current().files
        |
        v
  stats.compute(idx)          -- single-pass aggregation
        |
        v
  stats.format(data)          -- build lines[] + highlights[]
        |
        v
  ui.create_float_display()   -- render in floating window
```

### Link Resolution for Broken Link Detection

The vault index stores outlinks as raw `{ path, display, embed }` records (see `extract_links()` at line 403 of `vault_index.lua`). To detect broken links, we must resolve each outlink target against the index's name/alias lookup tables. The resolution logic mirrors `linkcheck.lua`'s `link_exists()` function (line 84) but uses the index directly instead of ripgrep:

1. Strip heading/block refs from `link.path` (get the note name portion).
2. Lowercase and check `idx:resolve_name(lower)`.
3. If nil, the link is broken.

This approach gives us the same broken link detection as `linkcheck.lua` but synchronously and without spawning rg.

---

## Implementation

### File: `lua/andrew/vault/stats.lua`

```lua
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local ui = require("andrew.vault.ui")

local M = {}

-- ---------------------------------------------------------------------------
-- Data collection (single pass)
-- ---------------------------------------------------------------------------

---@class VaultStatsData
---@field total_notes number
---@field total_tags number
---@field total_outlinks number
---@field total_inlinks number
---@field orphan_count number
---@field orphan_pct number
---@field broken_link_count number
---@field broken_link_notes number
---@field top_connected { name: string, rel_path: string, degree: number }[]
---@field tag_counts { tag: string, count: number }[]
---@field type_counts table<string, number>
---@field folder_counts table<string, number>
---@field month_counts table<string, number>
---@field task_counts table<string, number>
---@field task_total number
---@field total_aliases number
---@field total_headings number
---@field total_block_ids number
---@field avg_outlinks number
---@field avg_tags number

--- Compute all vault statistics from the index in a single pass.
---@param idx VaultIndex
---@return VaultStatsData
function M.compute(idx)
  local files = idx.files
  local inlinks = idx._inlinks

  local total_notes = 0
  local total_outlinks = 0
  local total_tags_refs = 0  -- total tag references (not unique)
  local total_aliases = 0
  local total_headings = 0
  local total_block_ids = 0
  local orphan_count = 0

  -- Broken link tracking
  local broken_link_count = 0
  local broken_link_notes = 0

  -- Tag distribution
  local tag_file_counts = {}  -- tag -> number of files

  -- Type distribution
  local type_counts = {}

  -- Folder distribution (top-level only)
  local folder_counts = {}

  -- Monthly activity
  local month_counts = {}

  -- Task aggregation
  local task_counts = {}
  local task_total = 0

  -- Degree tracking for most-connected
  local degree_map = {}  -- rel_path -> { name, degree }

  for rel_path, entry in pairs(files) do
    total_notes = total_notes + 1

    -- Outlinks
    local out_count = #entry.outlinks
    total_outlinks = total_outlinks + out_count

    -- Inlinks
    local in_count = #(inlinks[rel_path] or {})

    -- Degree (in + out)
    degree_map[rel_path] = {
      name = entry.basename,
      degree = in_count + out_count,
    }

    -- Orphan: zero inbound links
    if in_count == 0 then
      orphan_count = orphan_count + 1
    end

    -- Broken links: check each outlink target
    local has_broken = false
    for _, link in ipairs(entry.outlinks) do
      local raw = link.path or ""
      -- Strip heading/block refs
      raw = raw:match("^([^#^]+)") or raw
      raw = vim.trim(raw)
      if raw ~= "" then
        local lower = raw:lower()
        -- Strip .md extension for name lookup
        local name = lower:gsub("%.md$", "")
        -- Check basename (last path component)
        local basename = name:match("([^/]+)$") or name
        local resolved = idx:resolve_name(basename)
        if not resolved or #resolved == 0 then
          -- Try full path
          resolved = idx:resolve_name(name)
        end
        if not resolved or #resolved == 0 then
          broken_link_count = broken_link_count + 1
          has_broken = true
        end
      end
    end
    if has_broken then
      broken_link_notes = broken_link_notes + 1
    end

    -- Tags
    total_tags_refs = total_tags_refs + #entry.tags
    local seen_tags = {}
    for _, tag in ipairs(entry.tags) do
      if not seen_tags[tag] then
        seen_tags[tag] = true
        tag_file_counts[tag] = (tag_file_counts[tag] or 0) + 1
      end
    end

    -- Aliases
    total_aliases = total_aliases + #entry.aliases

    -- Headings
    total_headings = total_headings + #entry.headings

    -- Block IDs
    total_block_ids = total_block_ids + #entry.block_ids

    -- Type (from frontmatter)
    local note_type = entry.frontmatter and entry.frontmatter.type
    if note_type then
      local t = tostring(note_type)
      type_counts[t] = (type_counts[t] or 0) + 1
    else
      type_counts["(untyped)"] = (type_counts["(untyped)"] or 0) + 1
    end

    -- Folder (top-level directory)
    local folder = entry.folder
    if folder == "" then
      folder = "(root)"
    else
      -- Extract top-level dir only
      folder = folder:match("^([^/]+)") or folder
    end
    folder_counts[folder] = (folder_counts[folder] or 0) + 1

    -- Monthly activity: prefer `day` field (YYYY-MM-DD basename pattern),
    -- fall back to ctime if available
    local month_key = nil
    if entry.day then
      month_key = entry.day:sub(1, 7)  -- "YYYY-MM"
    elseif entry.ctime and entry.ctime > 0 then
      month_key = os.date("%Y-%m", entry.ctime)
    end
    if month_key then
      month_counts[month_key] = (month_counts[month_key] or 0) + 1
    end

    -- Tasks
    for _, task in ipairs(entry.tasks) do
      task_total = task_total + 1
      local status = task.status or " "
      task_counts[status] = (task_counts[status] or 0) + 1
    end
  end

  -- Build sorted tag list (top N)
  local tag_list = {}
  for tag, count in pairs(tag_file_counts) do
    tag_list[#tag_list + 1] = { tag = tag, count = count }
  end
  table.sort(tag_list, function(a, b) return a.count > b.count end)

  -- Build sorted top-connected list
  local connected = {}
  for rel_path, info in pairs(degree_map) do
    if info.degree > 0 then
      connected[#connected + 1] = {
        name = info.name,
        rel_path = rel_path,
        degree = info.degree,
      }
    end
  end
  table.sort(connected, function(a, b) return a.degree > b.degree end)

  -- Unique tag count
  local unique_tag_count = vim.tbl_count(tag_file_counts)

  -- Total inlinks (sum across all files)
  local total_inlinks = 0
  for _, links in pairs(inlinks) do
    total_inlinks = total_inlinks + #links
  end

  return {
    total_notes = total_notes,
    total_tags = unique_tag_count,
    total_outlinks = total_outlinks,
    total_inlinks = total_inlinks,
    orphan_count = orphan_count,
    orphan_pct = total_notes > 0 and (orphan_count / total_notes * 100) or 0,
    broken_link_count = broken_link_count,
    broken_link_notes = broken_link_notes,
    top_connected = connected,
    tag_counts = tag_list,
    type_counts = type_counts,
    folder_counts = folder_counts,
    month_counts = month_counts,
    task_counts = task_counts,
    task_total = task_total,
    total_aliases = total_aliases,
    total_headings = total_headings,
    total_block_ids = total_block_ids,
    avg_outlinks = total_notes > 0 and (total_outlinks / total_notes) or 0,
    avg_tags = total_notes > 0 and (total_tags_refs / total_notes) or 0,
  }
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

--- Task status label lookup (mirrors config.task_states).
local TASK_LABELS = {}
for _, state in ipairs(config.task_states) do
  TASK_LABELS[state.mark] = state.label
end

--- Right-pad a string to a minimum width.
---@param s string
---@param width number
---@return string
local function rpad(s, width)
  if #s >= width then return s end
  return s .. string.rep(" ", width - #s)
end

--- Format a number with thousand separators.
---@param n number
---@return string
local function fmt_num(n)
  if n < 1000 then return tostring(n) end
  local s = string.format("%d", n)
  local result = ""
  local len = #s
  for i = 1, len do
    if i > 1 and (len - i + 1) % 3 == 0 then
      result = result .. ","
    end
    result = result .. s:sub(i, i)
  end
  return result
end

--- Build the formatted lines and highlight annotations for the dashboard.
---@param data VaultStatsData
---@return string[] lines
---@return { line: number, hl: string, col_start: number, col_end: number }[] highlights
function M.format(data)
  local lines = {}
  local highlights = {}

  local function add(text)
    lines[#lines + 1] = text
  end

  local function add_hl(text, hl_group)
    local line_idx = #lines
    lines[#lines + 1] = text
    highlights[#highlights + 1] = {
      line = line_idx,
      hl = hl_group,
      col_start = 0,
      col_end = -1,
    }
  end

  local function add_separator()
    add("")
  end

  -- ===== OVERVIEW =====
  add_hl("  Overview", "Title")
  add(string.rep("-", 50))
  add(string.format("  Notes:       %s", fmt_num(data.total_notes)))
  add(string.format("  Unique tags: %s", fmt_num(data.total_tags)))
  add(string.format("  Outlinks:    %s  (avg %.1f/note)", fmt_num(data.total_outlinks), data.avg_outlinks))
  add(string.format("  Inlinks:     %s", fmt_num(data.total_inlinks)))
  add(string.format("  Aliases:     %s", fmt_num(data.total_aliases)))
  add(string.format("  Headings:    %s", fmt_num(data.total_headings)))
  add(string.format("  Block IDs:   %s", fmt_num(data.total_block_ids)))
  add(string.format("  Avg tags:    %.1f/note", data.avg_tags))

  add_separator()

  -- ===== HEALTH =====
  add_hl("  Health", "Title")
  add(string.rep("-", 50))

  -- Orphans
  local orphan_hl = data.orphan_pct > 30 and "DiagnosticWarn" or "DiagnosticInfo"
  local orphan_line = string.format(
    "  Orphans:      %s / %s  (%.0f%%)",
    fmt_num(data.orphan_count), fmt_num(data.total_notes), data.orphan_pct
  )
  add_hl(orphan_line, orphan_hl)

  -- Broken links
  if data.broken_link_count > 0 then
    add_hl(
      string.format(
        "  Broken links: %s across %s note(s)",
        fmt_num(data.broken_link_count), fmt_num(data.broken_link_notes)
      ),
      "DiagnosticError"
    )
  else
    add_hl("  Broken links: 0", "DiagnosticOk")
  end

  add_separator()

  -- ===== MOST CONNECTED =====
  add_hl("  Most Connected Notes (top 10)", "Title")
  add(string.rep("-", 50))

  local max_connected = math.min(10, #data.top_connected)
  for i = 1, max_connected do
    local item = data.top_connected[i]
    add(string.format("  %2d. %-30s %3d links", i, item.name, item.degree))
  end
  if max_connected == 0 then
    add("  (no connected notes)")
  end

  add_separator()

  -- ===== TAG DISTRIBUTION =====
  add_hl("  Tag Distribution (top 15)", "Title")
  add(string.rep("-", 50))

  local max_tags = math.min(15, #data.tag_counts)
  if max_tags > 0 then
    -- Find max count for bar chart scaling
    local max_count = data.tag_counts[1].count
    for i = 1, max_tags do
      local item = data.tag_counts[i]
      local bar_len = math.max(1, math.floor(item.count / max_count * 20))
      local bar = string.rep("*", bar_len)
      add(string.format("  #%-20s %4d  %s", item.tag, item.count, bar))
    end
  else
    add("  (no tags)")
  end

  add_separator()

  -- ===== NOTES BY TYPE =====
  add_hl("  Notes by Type", "Title")
  add(string.rep("-", 50))

  -- Sort types by count descending
  local type_list = {}
  for t, count in pairs(data.type_counts) do
    type_list[#type_list + 1] = { name = t, count = count }
  end
  table.sort(type_list, function(a, b) return a.count > b.count end)

  for _, item in ipairs(type_list) do
    add(string.format("  %-20s %4d", item.name, item.count))
  end
  if #type_list == 0 then
    add("  (no frontmatter types)")
  end

  add_separator()

  -- ===== NOTES BY FOLDER =====
  add_hl("  Notes by Folder", "Title")
  add(string.rep("-", 50))

  local folder_list = {}
  for folder, count in pairs(data.folder_counts) do
    folder_list[#folder_list + 1] = { name = folder, count = count }
  end
  table.sort(folder_list, function(a, b) return a.count > b.count end)

  for _, item in ipairs(folder_list) do
    add(string.format("  %-20s %4d", item.name, item.count))
  end
  if #folder_list == 0 then
    add("  (no folders)")
  end

  add_separator()

  -- ===== ACTIVITY TIMELINE =====
  add_hl("  Activity (notes per month)", "Title")
  add(string.rep("-", 50))

  -- Sort months chronologically and show last 12
  local month_list = {}
  for month, count in pairs(data.month_counts) do
    month_list[#month_list + 1] = { month = month, count = count }
  end
  table.sort(month_list, function(a, b) return a.month > b.month end)

  local max_months = math.min(12, #month_list)
  if max_months > 0 then
    -- Find max for bar scaling (within displayed range)
    local max_month_count = 0
    for i = 1, max_months do
      if month_list[i].count > max_month_count then
        max_month_count = month_list[i].count
      end
    end
    -- Display newest first
    for i = 1, max_months do
      local item = month_list[i]
      local bar_len = math.max(1, math.floor(item.count / max_month_count * 20))
      local bar = string.rep("|", bar_len)
      add(string.format("  %s  %4d  %s", item.month, item.count, bar))
    end
    if #month_list > max_months then
      add(string.format("  ... and %d earlier months", #month_list - max_months))
    end
  else
    add("  (no date information)")
  end

  add_separator()

  -- ===== TASKS =====
  add_hl("  Tasks", "Title")
  add(string.rep("-", 50))

  if data.task_total > 0 then
    add(string.format("  Total: %s", fmt_num(data.task_total)))
    -- Sort task statuses by the order in config.task_states
    for _, state in ipairs(config.task_states) do
      local count = data.task_counts[state.mark] or 0
      if count > 0 then
        local pct = data.task_total > 0 and (count / data.task_total * 100) or 0
        add(string.format("  [%s] %-15s %4d  (%.0f%%)", state.mark, state.label, count, pct))
      end
    end
    -- Any statuses not in config (custom marks)
    for mark, count in pairs(data.task_counts) do
      if not TASK_LABELS[mark] then
        add(string.format("  [%s] %-15s %4d", mark, "(custom)", count))
      end
    end
  else
    add("  (no tasks)")
  end

  add_separator()
  add("  Press q or <Esc> to close")

  return lines, highlights
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

--- Open the vault statistics dashboard.
function M.show()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()

  if not idx or not idx:is_ready() then
    vim.notify("Vault: index not ready", vim.log.levels.WARN)
    return
  end

  local start_time = vim.uv.hrtime()
  local data = M.compute(idx)
  local lines, highlights = M.format(data)
  local elapsed_ms = (vim.uv.hrtime() - start_time) / 1e6

  -- Append timing info
  lines[#lines] = string.format(
    "  Computed in %.1fms | Press q or <Esc> to close",
    elapsed_ms
  )

  local float = ui.create_float_display({
    title = "Vault Statistics",
    lines = lines,
    cursor_line = false,
  })

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(float.buf, -1, hl.hl, hl.line, hl.col_start, hl.col_end)
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  vim.api.nvim_create_user_command("VaultStats", function()
    M.show()
  end, { desc = "Show vault statistics dashboard" })

  vim.keymap.set("n", "<leader>vS", function()
    M.show()
  end, { desc = "Vault: statistics dashboard", silent = true })
end

return M
```

---

## Integration

### 1. Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add after the existing module setup chain (e.g., after `require("andrew.vault.autosave").setup()`):

```lua
-- Load vault statistics dashboard
require("andrew.vault.stats").setup()
```

No other files need modification. The module is entirely self-contained -- it reads from `vault_index.current()` and uses `ui.create_float_display()`, both of which are existing public APIs.

---

## Data Sources (per section)

Each dashboard section maps to specific vault index fields. This table shows exactly where each statistic comes from:

| Dashboard Section | VaultIndexEntry Field(s) | Computation |
|-------------------|--------------------------|-------------|
| Total notes | `idx.files` | `vim.tbl_count(idx.files)` |
| Unique tags | `entry.tags` | Collect into a set, count keys |
| Total outlinks | `entry.outlinks` | Sum `#entry.outlinks` |
| Total inlinks | `idx._inlinks` | Sum `#list` for each key in `_inlinks` |
| Aliases / Headings / Block IDs | `entry.aliases`, `entry.headings`, `entry.block_ids` | Sum lengths |
| Avg outlinks/note | derived | `total_outlinks / total_notes` |
| Orphans | `idx._inlinks[rel_path]` | Count entries where `_inlinks[rel_path]` is nil or empty |
| Broken links | `entry.outlinks` + `idx:resolve_name()` | For each outlink, strip `#`/`^` refs, call `resolve_name(basename)` |
| Most connected | `entry.outlinks` + `idx._inlinks` | `degree = #outlinks + #inlinks`, sort descending |
| Tag distribution | `entry.tags` | Per-file tag set (deduplicated within file), count files per tag |
| Notes by type | `entry.frontmatter.type` | Group by `type` field, `"(untyped)"` for missing |
| Notes by folder | `entry.folder` | Extract first path segment, group and count |
| Activity timeline | `entry.day` or `entry.ctime` | Extract `YYYY-MM`, group and count |
| Tasks | `entry.tasks[].status` | Group by status character, count |

### Broken Link Resolution

The broken link detection in `stats.lua` uses the vault index's `resolve_name()` method (line 1323 of `vault_index.lua`) which checks `_name_index` and `_alias_index`. This is the same resolution logic used by `linkcheck.lua`'s `link_exists()` (line 84), but synchronous and without ripgrep overhead. The key difference:

- `linkcheck.lua` uses `link_exists()` which calls `idx:resolve_name()` and also falls back to `engine.get_name_cache()`.
- `stats.lua` only uses `idx:resolve_name()` because if the index is ready, the name cache fallback is unnecessary.

This means the broken link count from `:VaultStats` may very slightly differ from `:VaultLinkCheckAll` in edge cases where the index has not yet picked up a recently created file, but this is acceptable for a summary view.

### Orphan Detection

The orphan detection differs from `linkcheck.lua`'s `check_orphans()` (line 421):

- `check_orphans()` uses async ripgrep to find all `[[...]]` patterns and builds a `linked` set from raw text matching.
- `stats.lua` uses the precomputed `idx._inlinks` table, which was built during index construction via `_recompute_inlinks()` (line 907 of `vault_index.lua`).

The index-based approach is more accurate because `_recompute_inlinks()` resolves links through the name/alias lookup tables (matching by basename, relative path stem, and aliases), whereas `check_orphans()` does raw text matching on the wikilink target string.

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Index not ready | `show()` displays "Vault: index not ready" notification and returns |
| Empty vault (0 files) | All sections show zero counts; no division-by-zero errors (guarded) |
| Note with no frontmatter `type` | Counted under `"(untyped)"` in the type distribution |
| Note in vault root (no folder) | Counted under `"(root)"` in folder distribution |
| Note with no date info | Not counted in activity timeline; no error |
| Daily log (basename `2026-02-27`) | `entry.day` is `"2026-02-27"`, month key is `"2026-02"` |
| Non-daily note with `ctime` | Falls back to `os.date("%Y-%m", entry.ctime)` for month key |
| Self-referencing outlinks (`[[#Heading]]`) | `raw` after stripping `#` refs is empty, skipped by `raw ~= ""` check |
| Embed outlinks (`![[Note]]`) | Included in outlink count (embeds are in `entry.outlinks` with `embed = true`) |
| Tags with hierarchy (`project/simulation`) | Each parent segment is also in `entry.tags` (added by `add_tag_with_parents()` at line 321 of `vault_index.lua`), so `project` and `project/simulation` both appear in tag counts |
| Very long note name in top-connected | Truncated to 30 chars by `%-30s` format specifier |
| Vault switch | Next `:VaultStats` call picks up the new vault's index automatically |
| Large vault (5000+ notes) | Single O(n) pass; `resolve_name()` is O(1) hash lookup; expect < 50ms |
| Custom task marks not in config | Displayed with `"(custom)"` label after the configured task states |

---

## Testing

### Manual Verification

1. **Basic display test:**

   ```vim
   :VaultStats
   ```

   Verify: floating window opens, shows all 8 sections, closes on `q` or `<Esc>`.

2. **Cross-reference with existing commands:**

   ```vim
   :VaultIndexStatus     " compare file count
   :VaultOrphans          " compare orphan count
   :VaultLinkCheckAll     " compare broken link count (approximately)
   :VaultTagTree          " compare tag distribution
   ```

3. **Empty vault test:**

   Create a temporary vault with 0 or 1 markdown files. Run `:VaultStats`. Verify no errors, all counts are 0 or 1, no division-by-zero.

4. **Performance test:**

   ```vim
   :lua local s = vim.uv.hrtime(); require("andrew.vault.stats").show(); print(("%.1fms"):format((vim.uv.hrtime() - s) / 1e6))
   ```

   Target: < 50ms for a vault with 1000+ notes. The timing is also displayed in the dashboard footer.

5. **Vault switch test:**

   ```vim
   :VaultSwitch           " switch to a different vault
   :VaultStats             " verify stats reflect the new vault
   ```

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: stats module structure
do
  local source = io.open("lua/andrew/vault/stats.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    assert_true(content:find("function M%.compute") ~= nil, "has compute function")
    assert_true(content:find("function M%.format") ~= nil, "has format function")
    assert_true(content:find("function M%.show") ~= nil, "has show function")
    assert_true(content:find("function M%.setup") ~= nil, "has setup function")
    assert_true(content:find("VaultStats") ~= nil, "defines VaultStats command")
    assert_true(content:find("vault_index") ~= nil, "uses vault_index")
    assert_true(content:find("create_float_display") ~= nil, "uses float display")
    assert_true(content:find("orphan") ~= nil, "computes orphans")
    assert_true(content:find("broken") ~= nil, "computes broken links")
    assert_true(content:find("resolve_name") ~= nil, "uses resolve_name for broken link detection")
    assert_true(content:find("top_connected") ~= nil, "computes most connected")
    assert_true(content:find("tag_counts") ~= nil, "computes tag distribution")
    assert_true(content:find("type_counts") ~= nil, "computes type distribution")
    assert_true(content:find("month_counts") ~= nil, "computes monthly activity")
    assert_true(content:find("task_counts") ~= nil, "computes task summary")
  end
end
```

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `vault_index.lua` | `vault_index.current()` for index access, `idx:resolve_name()` for broken link detection, `idx.files` for data, `idx._inlinks` for inbound links | Yes |
| `ui.lua` | `create_float_display()` for the floating window | Yes |
| `engine.lua` | Not directly used at runtime (no require needed) | No |
| `config.lua` | `config.task_states` for task status labels | Yes |

The module has minimal dependencies (3 requires) and no circular dependency risk. `vault_index.lua` is accessed via `require()` inside `show()` rather than at module load time, following the same pattern used by `tags.lua` (line 50) and `linkcheck.lua` (line 3).

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/stats.lua` | **New file** -- complete module (compute, format, show, setup) |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.stats").setup()` to the setup chain |

---

## Risk Assessment

**Risk: Very Low**

- New module with a single touchpoint (one line added to `init.lua`).
- Read-only: does not modify any index data, files, or caches.
- No async operations, no ripgrep, no I/O -- pure computation from in-memory data.
- Uses established patterns: `vault_index.current()` for data access (same as `tags.lua`, `connections.lua`, `linkcheck.lua`), `ui.create_float_display()` for rendering (same as `vault_index:show_collisions()`).
- If the module fails to load, no other module is affected (it has no subscribers, no cache registration, no autocmds beyond setup).
- The `resolve_name()` calls for broken link detection are the same O(1) hash lookups that `linkcheck.lua` uses; no performance concern.

---

## Future Enhancements

1. **Export to markdown** -- `:VaultStats!` writes the dashboard to a `Vault Stats.md` note in the vault for archival.
2. **Comparative stats** -- show delta vs. last week/month (requires persisting a snapshot of previous stats).
3. **Interactive sections** -- pressing Enter on a top-connected note opens it; pressing Enter on a tag runs `:VaultTags <tag>`.
4. **Graph density metric** -- ratio of actual edges to possible edges, measuring how interconnected the vault is.
5. **Word count / reading time** -- aggregate word counts across the vault (would require a new field in the index or a separate pass).
6. **Stale notes detection** -- notes not modified in N days with open tasks.
