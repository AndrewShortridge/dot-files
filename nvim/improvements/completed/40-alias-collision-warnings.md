# 40 — Alias Collision Warnings During Index Build

## Problem

The vault index allows multiple files to define the same alias in their frontmatter. When two or more files share an alias, `resolve_name()` returns all matching paths and `pick_closest()` silently selects one based on proximity. The user is never informed that an ambiguity exists. This silent conflict can cause unexpected link resolution: `[[My Alias]]` might resolve to `NoteA.md` in one buffer and `NoteB.md` in another, depending on which file is closer in the directory tree.

The same problem applies to name-alias collisions: a file named `Report.md` and another file with `aliases: [report]` both match the lookup `report`. The index stores both paths under the same key, but the conflict is invisible.

Without any warning, the user accumulates alias collisions as the vault grows and has no tooling to audit or fix them.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **vault_index.lua** `_rebuild_name_index()` | Builds `_name_index` (basename -> [abs_paths]) and `_alias_index` (alias -> [abs_paths]); silently allows multiple paths per key | `lua/andrew/vault/vault_index.lua:638-669` |
| **vault_index.lua** `_parse_file()` | Extracts aliases from frontmatter, lowercases each; stores as `entry.aliases` array | `lua/andrew/vault/vault_index.lua:495-547` |
| **vault_index.lua** `resolve_name()` | Returns all paths matching a name (checks `_name_index` then `_alias_index`); multiple paths = ambiguity | `lua/andrew/vault/vault_index.lua:1007-1014` |
| **vault_index.lua** `build_async()` / `build_sync()` | Both call `_rebuild_name_index()` after processing files; no collision detection | `lua/andrew/vault/vault_index.lua:838-899` |
| **config.lua** `M.index` | Index configuration (batch_size, persist_debounce_ms, watch, debug); no collision warning config | `lua/andrew/vault/config.lua:225-248` |

### What Is Silent Today

1. **Alias-alias collision**: Two files define the same alias (e.g., `NoteA.md` and `NoteB.md` both have `aliases: [meeting notes]`). The `_alias_index["meeting notes"]` list contains both paths. `resolve_name("meeting notes")` returns both, and `pick_closest()` silently picks one.

2. **Name-alias collision**: A file named `Report.md` (basename `report`) and another file with `aliases: [report]`. The `_name_index["report"]` contains `Report.md`'s path. The `_alias_index["report"]` contains the other file's path. `resolve_name("report")` returns the name match first (line 1010), hiding the alias match entirely.

3. **Basename-basename collision**: Two files with the same basename in different folders (e.g., `projects/Notes.md` and `daily/Notes.md`). The `_name_index["notes"]` list contains both paths. This is technically expected in multi-folder vaults, but the user may not realize it exists.

In all cases, there is zero feedback. The user discovers the problem only when a link resolves to the wrong note.

---

## Proposed Solution

### Architecture

Add collision detection as a post-processing step inside `_rebuild_name_index()`. After the existing loop that populates `name_idx` and `alias_idx`, iterate through both tables to find keys that map to more than one path. Store the collisions in a new `_collisions` field on the index instance. Optionally emit a batched `vim.notify()` summary.

The detection is organized into three collision types:

1. **Alias-alias**: Same alias defined by multiple files.
2. **Name-alias**: A file's basename matches another file's alias.
3. **Basename-basename**: Same basename in different folders (informational, lower severity).

```
_rebuild_name_index()
  |
  existing loop: build name_idx, alias_idx  (UNCHANGED)
  |
  NEW: collision detection pass
  |
  +-- For each key in alias_idx with #paths > 1:
  |     record alias-alias collision
  |
  +-- For each key in alias_idx:
  |     if name_idx[key] exists and paths differ:
  |       record name-alias collision
  |
  +-- For each key in name_idx with #paths > 1:
  |     record basename collision
  |
  store results in self._collisions
  |
  if config.index.warn_collisions and #collisions > 0:
    vim.schedule(batched vim.notify summary)
```

### Collision Detection Code

The following code is added at the end of `_rebuild_name_index()`, after `self._alias_index = alias_idx` (line 668), before the closing `end` of the function:

**Before** (current `_rebuild_name_index()`, lines 638-669):

```lua
--- Rebuild the name lookup table (basename -> [abs_paths]).
function M.VaultIndex:_rebuild_name_index()
  local name_idx = {}
  local alias_idx = {}

  for _, entry in pairs(self.files) do
    local lower = entry.basename_lower
    if not name_idx[lower] then
      name_idx[lower] = {}
    end
    name_idx[lower][#name_idx[lower] + 1] = entry.abs_path

    -- Also index by relative path stem
    local rel_stem = entry.rel_path:gsub("%.md$", ""):lower()
    if rel_stem ~= lower then
      if not name_idx[rel_stem] then
        name_idx[rel_stem] = {}
      end
      name_idx[rel_stem][#name_idx[rel_stem] + 1] = entry.abs_path
    end

    -- Index aliases
    for _, alias in ipairs(entry.aliases) do
      if not alias_idx[alias] then
        alias_idx[alias] = {}
      end
      alias_idx[alias][#alias_idx[alias] + 1] = entry.abs_path
    end
  end

  self._name_index = name_idx
  self._alias_index = alias_idx
end
```

**After** (with collision detection added):

```lua
--- Rebuild the name lookup table (basename -> [abs_paths]).
function M.VaultIndex:_rebuild_name_index()
  local name_idx = {}
  local alias_idx = {}

  for _, entry in pairs(self.files) do
    local lower = entry.basename_lower
    if not name_idx[lower] then
      name_idx[lower] = {}
    end
    name_idx[lower][#name_idx[lower] + 1] = entry.abs_path

    -- Also index by relative path stem
    local rel_stem = entry.rel_path:gsub("%.md$", ""):lower()
    if rel_stem ~= lower then
      if not name_idx[rel_stem] then
        name_idx[rel_stem] = {}
      end
      name_idx[rel_stem][#name_idx[rel_stem] + 1] = entry.abs_path
    end

    -- Index aliases
    for _, alias in ipairs(entry.aliases) do
      if not alias_idx[alias] then
        alias_idx[alias] = {}
      end
      alias_idx[alias][#alias_idx[alias] + 1] = entry.abs_path
    end
  end

  self._name_index = name_idx
  self._alias_index = alias_idx

  -- Collision detection
  self:_detect_collisions(name_idx, alias_idx)
end
```

### Collision Detection Method

Add as a new private method immediately after `_rebuild_name_index()`:

```lua
--- Detect alias and name collisions, store results, optionally warn.
---@param name_idx table<string, string[]>
---@param alias_idx table<string, string[]>
function M.VaultIndex:_detect_collisions(name_idx, alias_idx)
  local collisions = {}
  local prefix = self.vault_path .. "/"

  --- Convert abs_path to short rel_path for display.
  local function rel(abs_path)
    if abs_path:sub(1, #prefix) == prefix then
      return abs_path:sub(#prefix + 1)
    end
    return abs_path
  end

  --- Deduplicate a path list (same path can appear via basename + rel_stem).
  local function unique_paths(paths)
    local seen = {}
    local result = {}
    for _, p in ipairs(paths) do
      if not seen[p] then
        seen[p] = true
        result[#result + 1] = p
      end
    end
    return result
  end

  -- 1. Alias-alias collisions: same alias defined by multiple files
  for alias, paths in pairs(alias_idx) do
    local uniq = unique_paths(paths)
    if #uniq > 1 then
      local files = {}
      for _, p in ipairs(uniq) do
        files[#files + 1] = rel(p)
      end
      collisions[#collisions + 1] = {
        type = "alias-alias",
        key = alias,
        files = files,
        message = string.format(
          'Alias "%s" defined by %d files: %s',
          alias, #files, table.concat(files, ", ")
        ),
      }
    end
  end

  -- 2. Name-alias collisions: a file's basename matches another file's alias
  for key, alias_paths in pairs(alias_idx) do
    local name_paths = name_idx[key]
    if name_paths then
      -- Collect unique paths from each source
      local alias_set = {}
      for _, p in ipairs(alias_paths) do alias_set[p] = true end
      local name_set = {}
      for _, p in ipairs(name_paths) do name_set[p] = true end

      -- Find alias paths that are NOT in the name set (truly different files)
      local conflicting_alias_files = {}
      for p in pairs(alias_set) do
        if not name_set[p] then
          conflicting_alias_files[#conflicting_alias_files + 1] = rel(p)
        end
      end

      if #conflicting_alias_files > 0 then
        local name_files = {}
        for p in pairs(name_set) do
          name_files[#name_files + 1] = rel(p)
        end
        collisions[#collisions + 1] = {
          type = "name-alias",
          key = key,
          name_files = name_files,
          alias_files = conflicting_alias_files,
          message = string.format(
            'Name-alias conflict on "%s": name in %s, alias in %s',
            key,
            table.concat(name_files, ", "),
            table.concat(conflicting_alias_files, ", ")
          ),
        }
      end
    end
  end

  -- 3. Basename collisions: same basename in different folders (informational)
  for name, paths in pairs(name_idx) do
    -- Only flag basenames (not folder-qualified rel_stems which contain "/")
    if not name:find("/") then
      local uniq = unique_paths(paths)
      if #uniq > 1 then
        local files = {}
        for _, p in ipairs(uniq) do
          files[#files + 1] = rel(p)
        end
        collisions[#collisions + 1] = {
          type = "basename",
          key = name,
          files = files,
          message = string.format(
            'Basename "%s" shared by %d files: %s',
            name, #files, table.concat(files, ", ")
          ),
        }
      end
    end
  end

  self._collisions = collisions

  -- Emit batched warning notification
  self:_notify_collisions()
end
```

### Batched Notification

Add immediately after `_detect_collisions`:

```lua
--- Emit a single batched notification summarizing all collisions.
--- Only runs when config.index.warn_collisions is true.
function M.VaultIndex:_notify_collisions()
  local config = require("andrew.vault.config")
  if not config.index.warn_collisions then return end

  local collisions = self._collisions
  if not collisions or #collisions == 0 then return end

  -- Count by type
  local counts = { ["alias-alias"] = 0, ["name-alias"] = 0, basename = 0 }
  for _, c in ipairs(collisions) do
    counts[c.type] = (counts[c.type] or 0) + 1
  end

  local parts = {}
  if counts["alias-alias"] > 0 then
    parts[#parts + 1] = counts["alias-alias"] .. " alias collision"
      .. (counts["alias-alias"] ~= 1 and "s" or "")
  end
  if counts["name-alias"] > 0 then
    parts[#parts + 1] = counts["name-alias"] .. " name-alias conflict"
      .. (counts["name-alias"] ~= 1 and "s" or "")
  end
  if counts["basename"] > 0 then
    parts[#parts + 1] = counts["basename"] .. " basename ambiguit"
      .. (counts["basename"] ~= 1 and "ies" or "y")
  end

  local summary = "Vault index: " .. table.concat(parts, ", ")
    .. " (run :VaultIndexCollisions for details)"

  -- Use vim.schedule to batch — _rebuild_name_index() may be called from
  -- a coroutine (build_async) where vim.notify is not safe directly.
  vim.schedule(function()
    vim.notify(summary, vim.log.levels.WARN)
  end)
end
```

### Public Query API

Add to the Query API section (after `get_entry_by_abs`, around line 1105):

```lua
--- Get all detected collisions from the last index build.
---@return table[]  Array of collision records: { type, key, files, message, ... }
function M.VaultIndex:get_collisions()
  return self._collisions or {}
end
```

### Floating Window Command

Add as a new function after `get_collisions()`:

```lua
--- Show all collisions in a floating window.
function M.VaultIndex:show_collisions()
  local collisions = self._collisions or {}

  if #collisions == 0 then
    vim.notify("Vault index: no collisions detected", vim.log.levels.INFO)
    return
  end

  -- Build display lines
  local lines = {}
  local highlights = {} -- { line_idx, hl_group, col_start, col_end }

  -- Group by type
  local grouped = { ["alias-alias"] = {}, ["name-alias"] = {}, basename = {} }
  for _, c in ipairs(collisions) do
    local group = grouped[c.type]
    if group then
      group[#group + 1] = c
    end
  end

  local section_order = { "alias-alias", "name-alias", "basename" }
  local section_titles = {
    ["alias-alias"] = "Alias Collisions",
    ["name-alias"]  = "Name-Alias Conflicts",
    basename        = "Basename Ambiguities",
  }
  local section_hl = {
    ["alias-alias"] = "DiagnosticError",
    ["name-alias"]  = "DiagnosticWarn",
    basename        = "DiagnosticInfo",
  }

  for _, stype in ipairs(section_order) do
    local items = grouped[stype]
    if #items > 0 then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      local title = section_titles[stype] .. " (" .. #items .. ")"
      highlights[#highlights + 1] = { #lines, section_hl[stype], 0, #title }
      lines[#lines + 1] = title
      lines[#lines + 1] = string.rep("-", #title)

      for _, c in ipairs(items) do
        lines[#lines + 1] = "  " .. c.message
      end
    end
  end

  -- Create floating window
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, #line)
  end
  width = math.min(width + 4, math.floor(vim.o.columns * 0.85))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.7))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "vault-collisions"

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(buf, -1, hl[2], hl[1], hl[3], hl[4])
  end

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Vault Index Collisions ",
    title_pos = "center",
  })

  -- Close on q or Escape
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, nowait = true })
end
```

### Command Registration

The `:VaultIndexCollisions` command should be registered alongside the existing `:VaultIndexRebuild` and `:VaultIndexStatus` commands. These are registered in `engine.lua` or `init.lua` (wherever the other vault index commands are set up). Add:

```lua
vim.api.nvim_create_user_command("VaultIndexCollisions", function()
  local idx = vault_index.current()
  if not idx then
    vim.notify("Vault index not initialized", vim.log.levels.WARN)
    return
  end
  idx:show_collisions()
end, { desc = "Show alias/name collisions in vault index" })
```

### VaultIndex Class Field

Add `_collisions` to the class definition near the top of the file (around line 27):

```lua
---@class VaultIndex
---@field vault_path string
---@field files table<string, VaultIndexEntry>
---@field _name_index table<string, string[]>
---@field _alias_index table<string, string[]>
---@field _collisions table[]
```

### Initialization

In the `VaultIndex.new()` constructor, initialize the field:

```lua
self._collisions = {}
```

---

## Configuration

Add `warn_collisions` to the existing `M.index` config section in `config.lua`.

**File:** `lua/andrew/vault/config.lua`

**Before** (lines 225-248):

```lua
M.index = {
  -- Where to store the persistent index.
  -- "vault" = {vault_path}/.vault-index/index.json
  -- "data"  = vim.fn.stdpath("data")/vault-index/{hash}/index.json
  storage = "vault",

  -- Max time (ms) for synchronous index ops before deferring to async.
  sync_timeout_ms = 100,

  -- Batch size for background parsing (files per vim.schedule tick).
  batch_size = 20,

  -- Debounce interval (ms) for persisting index to disk after updates.
  persist_debounce_ms = 5000,

  -- Enable filesystem watcher for real-time change detection.
  watch = true,

  -- Debounce interval (ms) for filesystem watcher events.
  watch_debounce_ms = 500,

  -- Log index operations to :messages (for debugging).
  debug = false,
}
```

**After:**

```lua
M.index = {
  -- Where to store the persistent index.
  -- "vault" = {vault_path}/.vault-index/index.json
  -- "data"  = vim.fn.stdpath("data")/vault-index/{hash}/index.json
  storage = "vault",

  -- Max time (ms) for synchronous index ops before deferring to async.
  sync_timeout_ms = 100,

  -- Batch size for background parsing (files per vim.schedule tick).
  batch_size = 20,

  -- Debounce interval (ms) for persisting index to disk after updates.
  persist_debounce_ms = 5000,

  -- Enable filesystem watcher for real-time change detection.
  watch = true,

  -- Debounce interval (ms) for filesystem watcher events.
  watch_debounce_ms = 500,

  -- Log index operations to :messages (for debugging).
  debug = false,

  -- Warn about alias/name collisions after index builds.
  -- Set to false to suppress the notification.
  warn_collisions = true,
}
```

---

## File Changes

| File | Change |
|------|--------|
| `lua/andrew/vault/vault_index.lua` | Add `_collisions` field to class; initialize in `new()`; add `_detect_collisions()` call at end of `_rebuild_name_index()`; add `_detect_collisions()` method; add `_notify_collisions()` method; add `get_collisions()` query method; add `show_collisions()` floating window method |
| `lua/andrew/vault/config.lua` | Add `warn_collisions = true` to `M.index` |
| `lua/andrew/vault/init.lua` (or command registration file) | Add `:VaultIndexCollisions` user command |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `vault_index.lua` | All detection logic lives here; `_rebuild_name_index()` is the insertion point | Yes |
| `config.lua` | `config.index.warn_collisions` controls notification behavior | Yes |
| `init.lua` / `engine.lua` | Command registration for `:VaultIndexCollisions` | Yes (for command only) |

No new external dependencies. No new `require()` calls in `vault_index.lua` -- `config` is already lazy-required inside `_notify_collisions()` to avoid circular dependency (vault_index.lua has zero top-level requires by design).

---

## Testing Plan

### Manual Verification

#### 1. Alias-alias collision

Create two notes with the same alias:

```markdown
<!-- NoteA.md -->
---
aliases: [meeting notes, mn]
---
Content of Note A.
```

```markdown
<!-- NoteB.md -->
---
aliases: [meeting notes]
---
Content of Note B.
```

Run `:VaultIndexRebuild`. Verify:
- A single WARN notification appears: `Vault index: 1 alias collision (run :VaultIndexCollisions for details)`
- `:VaultIndexCollisions` opens a float showing `Alias "meeting notes" defined by 2 files: NoteA.md, NoteB.md`

#### 2. Name-alias collision

Create a note named `Report.md` and another note with `aliases: [report]`:

```markdown
<!-- Report.md -->
---
aliases: [weekly-report]
---
The actual report.
```

```markdown
<!-- Summary.md -->
---
aliases: [report]
---
A summary that aliases as "report".
```

Run `:VaultIndexRebuild`. Verify:
- Notification includes `1 name-alias conflict`
- `:VaultIndexCollisions` shows `Name-alias conflict on "report": name in Report.md, alias in Summary.md`

#### 3. No collisions

In a vault with no alias collisions, run `:VaultIndexRebuild`. Verify:
- No WARN notification appears.
- `:VaultIndexCollisions` shows `Vault index: no collisions detected` (INFO level).

#### 4. Config toggle

Set `config.index.warn_collisions = false`. Create collisions as in test 1. Run `:VaultIndexRebuild`. Verify:
- No WARN notification appears.
- `:VaultIndexCollisions` still works and shows the collisions (the data is always collected; only the notification is suppressed).

#### 5. Programmatic API

```vim
:lua local idx = require("andrew.vault.vault_index").current()
:lua print(#idx:get_collisions())
:lua print(vim.inspect(idx:get_collisions()[1]))
```

Verify the returned table has `type`, `key`, `files`/`name_files`/`alias_files`, and `message` fields.

#### 6. Floating window interaction

Run `:VaultIndexCollisions` with collisions present. Verify:
- Float opens centered with rounded border and title.
- Sections are grouped by type with colored headers.
- Pressing `q` or `<Esc>` closes the float.
- Buffer is non-modifiable.

#### 7. Build_async batching

Open Neovim with a vault that has collisions. Verify:
- During initial async index build, only ONE notification appears (not one per collision).
- The notification appears after the build completes, not during batch processing.

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: alias collision detection in vault_index
do
  local source = io.open("lua/andrew/vault/vault_index.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- Collision detection methods present
    assert_true(content:find("function M.VaultIndex:_detect_collisions") ~= nil,
      "has _detect_collisions method")
    assert_true(content:find("function M.VaultIndex:_notify_collisions") ~= nil,
      "has _notify_collisions method")
    assert_true(content:find("function M.VaultIndex:get_collisions") ~= nil,
      "has get_collisions query method")
    assert_true(content:find("function M.VaultIndex:show_collisions") ~= nil,
      "has show_collisions method")

    -- Collision detection is called from _rebuild_name_index
    assert_true(content:find("self:_detect_collisions%(name_idx, alias_idx%)") ~= nil,
      "_rebuild_name_index calls _detect_collisions")

    -- _collisions field initialized
    assert_true(content:find("_collisions") ~= nil,
      "has _collisions field")

    -- Three collision types detected
    assert_true(content:find('"alias%-alias"') ~= nil,
      "detects alias-alias collisions")
    assert_true(content:find('"name%-alias"') ~= nil,
      "detects name-alias collisions")
    assert_true(content:find('"basename"') ~= nil,
      "detects basename collisions")

    -- Notification respects config
    assert_true(content:find("warn_collisions") ~= nil,
      "checks warn_collisions config")
  end
end

-- Test: warn_collisions config exists
do
  local source = io.open("lua/andrew/vault/config.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    assert_true(content:find("warn_collisions") ~= nil,
      "config has warn_collisions setting")
  end
end
```

### Performance Verification

The collision detection pass iterates `_alias_index` and `_name_index` once each. Both tables have at most N entries (where N = number of unique names + aliases). The inner deduplication is O(k) per key where k is the path count (typically 1-3). Total cost is O(N) which is negligible compared to the file parsing that precedes it.

```vim
:lua local s = vim.uv.hrtime(); local idx = require("andrew.vault.vault_index").current(); idx:_rebuild_name_index(); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

Target: < 1ms additional overhead on a 500-file vault. The `_rebuild_name_index()` itself is already < 5ms; the collision detection adds a single-pass scan of the resulting tables.
