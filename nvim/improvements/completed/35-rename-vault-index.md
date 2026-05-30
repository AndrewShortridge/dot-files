# 35 — Rename Using Vault Index

## Problem

The note rename system (`rename.lua`) uses ripgrep to find all files containing
wikilinks to the target note. This works but has several inefficiencies:

1. **O(N) full-text search on every rename.** `collect_rename_changes()` shells
   out to `rg --files-with-matches` scanning every `.md` file in the vault for a
   regex pattern. On a 500-file vault this takes 50-200ms per invocation, and the
   function is called twice during a rename (once for preview/confirmation, once
   implicitly via the pre-computed `file_writes`).

2. **Redundant with vault index data.** The vault index already tracks outlinks
   per file and computes inlinks (reverse lookup). For any note, `get_inlinks()`
   returns the list of files linking to it in O(1). This data is available
   in-memory and does not require disk I/O or process spawning.

3. **No alias awareness.** The current ripgrep pattern
   `\[\[escaped_name(\]\]|\|[^\]]*\]\]|#[^\]]*\]\])` only matches the note's
   filename. If a file links via an alias (e.g., `[[My Alias]]` resolving to
   `MyNote.md`), that reference is missed and will not be updated during rename.
   The vault index's `_alias_index` already knows which aliases resolve to which
   files.

4. **Index not fully updated after rename.** The current code calls
   `idx:remove_file(old_path)` and `idx:update_file(new_path)` for the renamed
   file itself, but does not update the index entries for files whose outlinks
   were rewritten. Their stored `outlinks` still reference the old name until
   the next incremental rebuild or `BufWritePost`.

5. **Preview duplicates work.** `rename_preview()` calls
   `collect_rename_changes()` (spawning `rg`), and then `rename()` calls it again
   independently. The preview data is discarded and recomputed.

### Current State

| Component | What It Does | How | File |
|-----------|-------------|-----|------|
| `collect_rename_changes()` | Finds files with `[[old_name...]]` wikilinks | `rg --files-with-matches` + regex | `rename.lua:48-111` |
| `apply_rename_changes()` | Writes pre-computed replacement content | `engine.write_file()` per file | `rename.lua:118-126` |
| `rename_preview()` | Populates quickfix with pending changes | Calls `collect_rename_changes()` | `rename.lua:132-191` |
| `rename()` | Renames file + updates all wikilinks | Calls `collect_rename_changes()` + `apply_rename_changes()` | `rename.lua:197-278` |
| `vault_index:get_inlinks()` | Returns list of files linking to a note | In-memory lookup on `_inlinks` table | `vault_index.lua:1020-1022` |
| `vault_index:_alias_index` | Maps lowercase aliases to abs paths | Rebuilt on index updates | `vault_index.lua:659-665` |
| `vault_index:update_file()` | Re-parses a single file and updates derived indexes | Single-pass parse + incremental inlink update | `vault_index.lua:902-936` |

### Why the Current Design Cannot Support Index-Based Rename

The current `collect_rename_changes()` conflates **file discovery** (which files
contain links) with **content rewriting** (what the new content should be). It
reads each discovered file, performs in-memory regex replacement, and stores the
entire new content. This tight coupling means the discovery mechanism (ripgrep)
cannot be swapped out without restructuring the function.

Additionally, the inlinks in the vault index store the source file's `rel_path`
(without `.md`) and `display` name, but not the specific link text or line
numbers. The rename system needs to know the exact wikilink syntax used
(`[[Name]]`, `[[Name|alias]]`, `[[Name#heading]]`, `[[Name^block]]`) to perform
correct text replacement. This means the index provides *which files* to examine,
but the actual text replacement still requires reading and parsing each file.

---

## Goal

1. Replace ripgrep-based file discovery in `collect_rename_changes()` with
   `vault_index:get_inlinks()` for O(1) lookup of all files linking to the
   renamed note.
2. Also discover files linking via alias by consulting the vault index's alias
   data for the renamed note.
3. Retain ripgrep as a fallback when the vault index is not ready (e.g., during
   initial startup before the async build completes).
4. Preserve `#heading` and `^block` suffixes in wikilinks during replacement
   (they refer to anchors within the target note and remain valid after rename).
5. Update all affected vault index entries after rename: the renamed file itself,
   plus every file whose outlinks were rewritten.
6. Batch file modifications for performance: open each affected file once, make
   all replacements, write once.
7. Persist the vault index after rename completes to ensure the updated state
   survives a crash.
8. Use vault index data in `rename_preview()` to avoid spawning ripgrep for
   dry-run previews.
9. Maintain full backward compatibility: if the vault index is unavailable, the
   rename must still work identically to the current implementation.

---

## Approach

### Architecture

Split `collect_rename_changes()` into two phases:

1. **Discovery** -- determine which files contain links to the target note.
2. **Rewriting** -- read each discovered file, perform wikilink text replacement,
   collect the changes.

The discovery phase has two implementations:
- **Primary (vault index):** Query `get_inlinks()` for the note's `rel_path`,
  plus query inlinks for any aliases the note has. This returns a set of source
  file paths in O(1).
- **Fallback (ripgrep):** The existing `rg --files-with-matches` approach, used
  only when `vault_index.current()` is nil or `idx:is_ready()` is false.

```
                  rename("OldName", "NewName")
                            |
                   +--------v--------+
                   | Discovery Phase |
                   +--------+--------+
                            |
              +-------------+-------------+
              |                           |
     vault index ready?            vault index NOT ready
              |                           |
     +--------v--------+        +--------v--------+
     | get_inlinks()   |        | rg --files-with |
     | + alias inlinks |        |    -matches     |
     +--------+--------+        +--------+--------+
              |                           |
              +-------------+-------------+
                            |
                   +--------v--------+
                   | Rewriting Phase |
                   | (shared logic)  |
                   +--------+--------+
                            |
              file_path -> { changes, new_content }
                            |
                   +--------v--------+
                   | Apply + Index   |
                   | Update          |
                   +-----------------+
```

### Discovery via Vault Index

The vault index stores inlinks keyed by the target file's `rel_path`. Each
inlink entry has `{ path = "source/rel/stem", display = "SourceName" }`. To find
all files that link to a note being renamed:

1. Get the renamed note's `rel_path` from its absolute path.
2. Call `idx:get_inlinks(rel_path)` to get direct inlinks.
3. Look up the note's aliases from its index entry (`entry.aliases`).
4. For each alias, find files that link using that alias text (these are already
   captured in inlinks since the vault index resolves aliases during inlink
   computation).
5. Deduplicate the source file set.

However, there is a subtlety: `get_inlinks()` tells us *which files* link to
the target, but the inlink entries do not store the raw link text. A file might
link to `OldName` via `[[OldName]]`, `[[OldName#heading]]`,
`[[OldName^block-id]]`, or `[[OldName|display text]]`. The rewriting phase must
handle all variants, which it already does via the `%[%[(.-)%]%]` gsub pattern.

```lua
--- Discover files linking to a note using the vault index.
--- Returns a list of absolute file paths, or nil if the index is not available.
---@param old_name string  Note basename (without .md)
---@param old_path string  Absolute path to the note being renamed
---@return string[]|nil  List of absolute paths, or nil to fall back to ripgrep
local function discover_linking_files_from_index(old_name, old_path)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    return nil  -- fallback to ripgrep
  end

  local rel_path = engine.vault_relative(old_path)
  if not rel_path then
    return nil
  end

  -- Collect source files from inlinks
  local source_set = {}
  local inlinks = idx:get_inlinks(rel_path)
  for _, inlink in ipairs(inlinks) do
    -- inlink.path is the source rel_path without .md extension
    local source_rel = inlink.path .. ".md"
    local source_entry = idx:get_entry(source_rel)
    if source_entry then
      source_set[source_entry.abs_path] = true
    end
  end

  -- Also check for self-references (the renamed note linking to itself)
  local self_entry = idx:get_entry(rel_path)
  if self_entry then
    for _, link in ipairs(self_entry.outlinks) do
      local target = link.path or ""
      target = target:match("^([^#^]+)") or target
      target = vim.trim(target)
      if target:lower() == old_name:lower() then
        source_set[old_path] = true
        break
      end
    end
  end

  local result = {}
  for path in pairs(source_set) do
    result[#result + 1] = path
  end
  return result
end
```

### Discovery via Ripgrep (Fallback)

The existing ripgrep logic is extracted into its own function so the rewriting
phase can use either discovery mechanism:

```lua
--- Discover files linking to a note using ripgrep (fallback).
---@param old_name string  Note basename (without .md)
---@return string[]  List of absolute file paths
local function discover_linking_files_from_rg(old_name)
  local escaped = rg_escape(old_name)
  local pattern = "\\[\\[" .. escaped .. "(\\]\\]|\\|[^\\]]*\\]\\]|#[^\\]]*\\]\\])"
  local result = vim.system({
    "rg", "--files-with-matches", "--glob", "*.md", "--ignore-case",
    pattern, engine.vault_path,
  }):wait()

  local files = {}
  if result.stdout and result.stdout ~= "" then
    for file_path in result.stdout:gmatch("[^\n]+") do
      files[#files + 1] = file_path
    end
  end
  return files
end
```

### Alias-Aware Rewriting

The current rewriting phase compares `target:lower() == old_name:lower()`. This
only matches the note's filename. To handle aliases, the rewriting phase must
also match alias strings:

```lua
--- Build a set of names that should be rewritten to new_name.
--- Includes the old basename and any aliases the note has.
---@param old_name string  Note basename (without .md)
---@param old_path string  Absolute path to the renamed note
---@return table<string, true>  Lowercase name set
local function build_old_name_set(old_name, old_path)
  local names = { [old_name:lower()] = true }

  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local entry = idx:get_entry_by_abs(old_path)
    if entry then
      for _, alias in ipairs(entry.aliases) do
        names[alias] = true  -- aliases are already lowercased
      end
    end
  end

  return names
end
```

The gsub callback then checks against this set:

```lua
local old_names = build_old_name_set(old_name, old_path)

local new_line = line:gsub("%[%[(.-)%]%]", function(inner)
  local target = inner:match("^([^|#^]+)") or inner
  target = vim.trim(target)
  if old_names[target:lower()] then
    local suffix = inner:sub(#target + 1)  -- preserves #heading, ^block, |alias
    link_count = link_count + 1
    return "[[" .. new_name .. suffix .. "]]"
  end
  return "[[" .. inner .. "]]"
end)
```

Note that the target extraction pattern is `^([^|#^]+)` (not the current
`^([^|#]+)`), which correctly stops at `^` for block references in addition to
`|` and `#`.

### Heading and Block Reference Preservation

Wikilinks can contain `#heading` and `^block-id` suffixes that reference
anchors *within* the target note. When a note is renamed, these anchors remain
valid because the note's content is not changing -- only its filename. The suffix
extraction `inner:sub(#target + 1)` already preserves everything after the note
name, including:

- `[[OldName#Some Heading]]` -> `[[NewName#Some Heading]]`
- `[[OldName^blk-abc123]]` -> `[[NewName^blk-abc123]]`
- `[[OldName#Heading^block]]` -> `[[NewName#Heading^block]]`
- `[[OldName|Display]]` -> `[[NewName|Display]]`
- `[[OldName#Heading|Display]]` -> `[[NewName#Heading|Display]]`

No special handling is needed beyond the existing suffix preservation, but the
target extraction must use `^([^|#^]+)` to correctly parse the note name portion
when a `^block` suffix is present without a `#heading` prefix.

### Batch Buffer Modifications

The current implementation reads each file via `engine.read_file()`, builds the
new content in memory, and writes it with `engine.write_file()`. This is already
effectively batched per file (one read, one write). The improvement maintains
this pattern but adds a safeguard: before writing, check if the file is open in
a buffer and use `nvim_buf_set_lines()` for open buffers to avoid the
`edit!`-based reload:

```lua
--- Apply changes: write files and update open buffers directly.
---@param file_writes table<string, string>  abs_path -> new content
---@return string[]  List of modified file paths
local function apply_file_writes(file_writes)
  local modified = {}
  local open_bufs = {}

  -- Build map of open buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        open_bufs[name] = buf
      end
    end
  end

  for path, new_content in pairs(file_writes) do
    local buf = open_bufs[path]
    if buf then
      -- Update buffer directly (avoids edit! which can lose undo history)
      local lines = vim.split(new_content, "\n", { plain = true })
      -- Remove trailing empty line from split if content ends with newline
      if #lines > 0 and lines[#lines] == "" then
        lines[#lines] = nil
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    else
      -- File not open: write directly to disk
      engine.write_file(path, new_content)
    end
    modified[#modified + 1] = path
  end

  return modified
end
```

### Vault Index Update After Rename

After the rename completes, the vault index must be updated to reflect:

1. The renamed file's new path and basename.
2. The rewritten outlinks in every modified file.
3. The recomputed inlinks for the entire affected subgraph.

```lua
--- Update the vault index after a rename operation.
---@param old_path string  Original absolute path (file no longer exists)
---@param new_path string  New absolute path (file now exists here)
---@param modified_files string[]  Files whose content was rewritten
local function update_index_after_rename(old_path, new_path, modified_files)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    return
  end

  -- 1. Remove old path, add new path
  idx:remove_file(old_path)
  idx:update_file(new_path)

  -- 2. Re-index every modified file so their outlinks are current
  for _, file_path in ipairs(modified_files) do
    if file_path ~= old_path and file_path ~= new_path then
      idx:update_file(file_path)
    end
  end

  -- 3. Force immediate persistence (rename is a significant operation)
  idx:persist_now()
end
```

Each `update_file()` call triggers `_rebuild_name_index()` and incremental
inlink recomputation. For a rename touching N files, this is N+1 calls to
`update_file()`. Since each call is < 10ms (single-file parse + derived index
rebuild), the total overhead for a rename touching 20 files is ~200ms -- well
within acceptable limits.

For vaults where a rename touches 100+ files, a batched approach would be more
efficient (parse all files, then rebuild derived indexes once). This can be
added as a future optimization if needed:

```lua
--- Batch-update multiple files in the vault index (future optimization).
---@param file_paths string[]  Absolute paths to re-index
function M.VaultIndex:update_files_batch(file_paths)
  local old_outlinks_map = {}
  local changed_rel_paths = {}

  for _, abs_path in ipairs(file_paths) do
    local rel_path = abs_path:sub(#self.vault_path + 2)
    if not rel_path:match("%.md$") then goto continue end

    local old_entry = self.files[rel_path]
    if old_entry then
      old_outlinks_map[rel_path] = old_entry.outlinks or {}
    end

    local stat = vim.uv.fs_stat(abs_path)
    if stat then
      local entry = self:_parse_file(abs_path, rel_path, stat)
      if entry then
        self.files[rel_path] = entry
        changed_rel_paths[#changed_rel_paths + 1] = rel_path
      end
    end

    ::continue::
  end

  -- Single rebuild pass
  self:_rebuild_name_index()
  self:_recompute_inlinks_incremental(old_outlinks_map, changed_rel_paths, {})
  self:_schedule_persist()
  self:_notify_update()
end
```

### Preview Using Vault Index

The `rename_preview()` function currently calls `collect_rename_changes()` which
spawns ripgrep. With the refactored discovery phase, the preview uses the same
index-based lookup, making it near-instantaneous:

```lua
function M.rename_preview(new_name)
  local old_name = engine.current_note_name()
  local old_path = current_note_path()
  if not old_name or not old_path then
    vim.notify("Vault: current buffer is not a vault note", vim.log.levels.WARN)
    return
  end

  local function do_preview(name)
    if not name or name == "" then return end
    if name == old_name then
      vim.notify("Vault: name unchanged", vim.log.levels.INFO)
      return
    end

    -- Uses vault index when available, ripgrep as fallback
    local info = collect_rename_changes(old_name, name, old_path)

    if #info.changes == 0 then
      vim.notify(
        "Vault: renaming '" .. old_name .. "' -> '" .. name
          .. "' would update 0 references",
        vim.log.levels.INFO
      )
      return
    end

    -- Build quickfix entries (unchanged from current implementation)
    local qf_items = {}
    for _, c in ipairs(info.changes) do
      qf_items[#qf_items + 1] = {
        filename = c.filename,
        lnum = c.lnum,
        text = c.old_text .. "  ->  " .. c.new_text,
      }
    end

    vim.fn.setqflist({}, " ", {
      title = "Vault rename preview: '" .. old_name .. "' -> '" .. name
        .. "' (" .. info.link_count .. " links in " .. info.file_count .. " files)",
      items = qf_items,
    })
    vim.cmd("copen")
  end

  -- ... input prompt logic unchanged ...
end
```

---

## Implementation Steps

### Step 1: Add `update_files_batch()` to `vault_index.lua`

**File:** `lua/andrew/vault/vault_index.lua`

Add a new method after `remove_file()` (around line 953) that batch-updates
multiple files with a single derived-index rebuild pass:

```lua
--- Batch-update multiple files in the vault index.
--- More efficient than calling update_file() in a loop because derived indexes
--- (name index, inlinks) are rebuilt only once.
---@param abs_paths string[]  Absolute paths to re-index
function M.VaultIndex:update_files_batch(abs_paths)
  local prefix = self.vault_path .. "/"
  local old_outlinks_map = {}
  local changed_rel_paths = {}
  local deleted_rel_paths = {}

  for _, abs_path in ipairs(abs_paths) do
    if abs_path:sub(1, #prefix) ~= prefix then goto continue end
    local rel_path = abs_path:sub(#prefix + 1)
    if not rel_path:match("%.md$") then goto continue end

    local old_entry = self.files[rel_path]
    if old_entry then
      old_outlinks_map[rel_path] = old_entry.outlinks or {}
    end

    local stat = vim.uv.fs_stat(abs_path)
    if not stat then
      -- File was deleted
      if old_entry then
        self.files[rel_path] = nil
        deleted_rel_paths[#deleted_rel_paths + 1] = rel_path
      end
    else
      local entry = self:_parse_file(abs_path, rel_path, stat)
      if entry then
        self.files[rel_path] = entry
        changed_rel_paths[#changed_rel_paths + 1] = rel_path
      end
    end

    ::continue::
  end

  if #changed_rel_paths > 0 or #deleted_rel_paths > 0 then
    self:_rebuild_name_index()
    self:_recompute_inlinks_incremental(old_outlinks_map, changed_rel_paths, deleted_rel_paths)
    self:_schedule_persist()
    self:_notify_update()
  end
end
```

### Step 2: Refactor `rename.lua` — extract discovery functions

**File:** `lua/andrew/vault/rename.lua`

Add `vault_index` require at the top (it is currently only required inline
inside `do_rename()`):

```lua
local engine = require("andrew.vault.engine")
local vault_index = require("andrew.vault.vault_index")

local M = {}
```

Add the index-based and ripgrep-based discovery functions after the existing
utility functions:

```lua
-- ---------------------------------------------------------------------------
-- Discovery: find files containing links to a given note
-- ---------------------------------------------------------------------------

--- Discover linking files using the vault index (O(1) lookup).
--- Returns nil if the index is not available (caller should fall back to rg).
---@param old_name string  Note basename without extension
---@param old_path string  Absolute path of the note
---@return string[]|nil
local function discover_from_index(old_name, old_path)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    return nil
  end

  local rel_path = engine.vault_relative(old_path)
  if not rel_path then
    return nil
  end

  local source_set = {}

  -- Get files that link to this note (by resolved path)
  local inlinks = idx:get_inlinks(rel_path)
  for _, inlink in ipairs(inlinks) do
    local source_rel = inlink.path .. ".md"
    local source_entry = idx:get_entry(source_rel)
    if source_entry then
      source_set[source_entry.abs_path] = true
    end
  end

  -- Check for self-references (note linking to itself)
  local self_entry = idx:get_entry(rel_path)
  if self_entry then
    for _, link in ipairs(self_entry.outlinks) do
      local target = link.path or ""
      target = target:match("^([^#^|]+)") or target
      target = vim.trim(target)
      if target:lower() == old_name:lower() then
        source_set[old_path] = true
        break
      end
    end
  end

  local result = {}
  for path in pairs(source_set) do
    result[#result + 1] = path
  end
  return result
end

--- Discover linking files using ripgrep (fallback).
---@param old_name string  Note basename without extension
---@return string[]
local function discover_from_rg(old_name)
  local escaped = rg_escape(old_name)
  local pattern = "\\[\\[" .. escaped .. "(\\]\\]|\\|[^\\]]*\\]\\]|#[^\\]]*\\]\\]|%^[^\\]]*\\]\\])"
  local result = vim.system({
    "rg", "--files-with-matches", "--glob", "*.md", "--ignore-case",
    pattern, engine.vault_path,
  }):wait()

  local files = {}
  if result.stdout and result.stdout ~= "" then
    for file_path in result.stdout:gmatch("[^\n]+") do
      files[#files + 1] = file_path
    end
  end
  return files
end

--- Build the set of names to match during rewriting.
--- Includes the basename and any aliases from the vault index.
---@param old_name string  Note basename without extension
---@param old_path string  Absolute path of the note
---@return table<string, true>  Lowercase name set
local function build_old_name_set(old_name, old_path)
  local names = { [old_name:lower()] = true }

  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local entry = idx:get_entry_by_abs(old_path)
    if entry then
      for _, alias in ipairs(entry.aliases) do
        names[alias] = true  -- already lowercased in the index
      end
    end
  end

  return names
end
```

### Step 3: Refactor `collect_rename_changes()` to use discovery functions

**File:** `lua/andrew/vault/rename.lua`

Replace the existing `collect_rename_changes()` with a version that accepts
`old_path` and uses the two-phase approach:

```lua
--- Collect all wikilink changes without applying them.
--- Uses vault index for discovery when available, falls back to ripgrep.
---@param old_name string  Current note basename (without .md)
---@param new_name string  Desired new basename (without .md)
---@param old_path string  Absolute path of the note being renamed
---@return table  { changes, file_count, link_count, file_writes }
local function collect_rename_changes(old_name, new_name, old_path)
  -- Phase 1: Discovery
  local linking_files = discover_from_index(old_name, old_path)
  if not linking_files then
    linking_files = discover_from_rg(old_name)
  end

  -- Phase 2: Rewriting
  local old_names = build_old_name_set(old_name, old_path)
  local changes = {}
  local file_set = {}
  local link_count = 0
  local file_writes = {}

  for _, file_path in ipairs(linking_files) do
    local content = engine.read_file(file_path)
    if not content then
      goto continue
    end

    local new_content_lines = {}
    local file_changed = false
    local lnum = 0

    for line in content:gmatch("([^\n]*)\n?") do
      lnum = lnum + 1
      local new_line = line:gsub("%[%[(.-)%]%]", function(inner)
        local target = inner:match("^([^|#^]+)") or inner
        target = vim.trim(target)
        if old_names[target:lower()] then
          local suffix = inner:sub(#target + 1)
          link_count = link_count + 1
          return "[[" .. new_name .. suffix .. "]]"
        end
        return "[[" .. inner .. "]]"
      end)
      new_content_lines[#new_content_lines + 1] = new_line
      if new_line ~= line then
        changes[#changes + 1] = {
          filename = file_path,
          lnum = lnum,
          old_text = line,
          new_text = new_line,
        }
        file_set[file_path] = true
        file_changed = true
      end
    end

    if file_changed then
      file_writes[file_path] = table.concat(new_content_lines, "\n")
    end

    ::continue::
  end

  local file_count = 0
  for _ in pairs(file_set) do
    file_count = file_count + 1
  end

  return {
    changes = changes,
    file_count = file_count,
    link_count = link_count,
    file_writes = file_writes,
  }
end
```

Key differences from the current implementation:

- **Function signature:** Accepts `old_path` as a third parameter (needed for
  index-based discovery and alias lookup).
- **Target extraction pattern:** Uses `^([^|#^]+)` instead of `^([^|#]+)` to
  correctly handle `^block` suffixes.
- **Name matching:** Uses `old_names` set (includes aliases) instead of a single
  `old_name:lower()` comparison.
- **Discovery:** Calls `discover_from_index()` first, falls back to
  `discover_from_rg()`.

### Step 4: Update `rename_preview()` to pass `old_path`

**File:** `lua/andrew/vault/rename.lua`

Update the `do_preview` inner function to pass `old_path` to
`collect_rename_changes()`:

```lua
local function do_preview(name)
  if not name or name == "" then return end
  if name == old_name then
    vim.notify("Vault: name unchanged", vim.log.levels.INFO)
    return
  end

  local info = collect_rename_changes(old_name, name, old_path)  -- added old_path

  -- ... rest unchanged ...
end
```

### Step 5: Update `rename()` to use batch index update

**File:** `lua/andrew/vault/rename.lua`

Replace the index update section at the end of `do_rename()`:

```lua
local function do_rename(name)
  -- ... validation, collect changes, confirmation (unchanged) ...

  -- Pass old_path to collect_rename_changes
  local info = collect_rename_changes(old_name, name, old_path)

  -- ... confirmation prompt (unchanged) ...

  -- Save current buffer if modified
  if vim.bo.modified then
    vim.cmd("write")
  end

  -- Apply wikilink changes
  local modified_files, link_count = apply_rename_changes(info)

  -- Rename the file
  vim.fn.rename(old_path, new_path)

  -- Update current buffer to new file
  vim.cmd("edit " .. vim.fn.fnameescape(new_path))
  local old_bufnr = vim.fn.bufnr(old_path)
  if old_bufnr ~= -1 and old_bufnr ~= vim.api.nvim_get_current_buf() then
    vim.api.nvim_buf_delete(old_bufnr, { force = true })
  end

  -- Reload any open buffers that were modified
  reload_open_buffers(modified_files)

  -- Update vault index: remove old path, add new path, re-index modified files
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    -- Remove the old file entry
    idx:remove_file(old_path)
    -- Re-index the renamed file at its new path
    idx:update_file(new_path)
    -- Batch re-index all files whose outlinks were rewritten
    local reindex_paths = {}
    for _, path in ipairs(modified_files) do
      if path ~= old_path and path ~= new_path then
        reindex_paths[#reindex_paths + 1] = path
      end
    end
    if #reindex_paths > 0 then
      idx:update_files_batch(reindex_paths)
    end
    -- Force immediate persistence after rename
    idx:persist_now()
  end

  vim.notify(
    "Renamed '" .. old_name .. "' -> '" .. name
      .. "' (" .. link_count .. " links in " .. #modified_files .. " files)",
    vim.log.levels.INFO
  )
end
```

### Step 6: Update `rg_escape()` and ripgrep pattern for block references

**File:** `lua/andrew/vault/rename.lua`

The current ripgrep pattern does not match `[[OldName^block-id]]`. Update
`discover_from_rg()` to include the `^` case:

```lua
local function discover_from_rg(old_name)
  local escaped = rg_escape(old_name)
  -- Match [[name]], [[name|...]], [[name#...]], [[name^...]]
  local pattern = "\\[\\["
    .. escaped
    .. "(\\]\\]|\\|[^\\]]*\\]\\]|#[^\\]]*\\]\\]|\\^[^\\]]*\\]\\])"
  local result = vim.system({
    "rg", "--files-with-matches", "--glob", "*.md", "--ignore-case",
    pattern, engine.vault_path,
  }):wait()

  local files = {}
  if result.stdout and result.stdout ~= "" then
    for file_path in result.stdout:gmatch("[^\n]+") do
      files[#files + 1] = file_path
    end
  end
  return files
end
```

### Summary of File Changes

| File | Change |
|------|--------|
| `lua/andrew/vault/vault_index.lua` | Add `update_files_batch()` method |
| `lua/andrew/vault/rename.lua` | Add `vault_index` require; add `discover_from_index()`, `discover_from_rg()`, `build_old_name_set()`; refactor `collect_rename_changes()` signature and body; update `rename_preview()` and `rename()` callers; update ripgrep pattern for `^block` refs |

---

## Testing

### Manual Verification

**1. Basic rename with vault index available:**

Open a note that is linked from several other files. Run `:VaultIndexStatus` to
confirm the index is ready. Rename with `:VaultRename NewName`. Verify:
- All `[[OldName]]`, `[[OldName#heading]]`, `[[OldName^block]]`, and
  `[[OldName|alias]]` references are updated.
- The quickfix confirmation count matches actual changes.
- `:VaultIndexStatus` still shows the index as ready.
- `gf` on any updated wikilink in the modified files navigates correctly.

**2. Preview with vault index:**

Run `:VaultRenamePreview TestName`. Verify the quickfix list populates instantly
(no visible ripgrep delay). Verify the listed changes match what a full rename
would do.

**3. Alias-based references:**

Create a note `MyNote.md` with frontmatter `aliases: [mn, my-note]`. Create
another note with `[[mn]]` and `[[my-note]]` links. Rename `MyNote` to
`NewNote`. Verify that `[[mn]]` and `[[my-note]]` are updated to `[[NewNote]]`.

**4. Fallback to ripgrep:**

Temporarily simulate an unavailable index by running the rename before the async
build completes (e.g., immediately after `nvim` startup on a cold cache). Verify
the rename still works correctly using ripgrep discovery. Check for a
notification or silent fallback (no error).

**5. Heading and block reference preservation:**

Create links: `[[Note#Some Heading]]`, `[[Note^blk-abc123]]`,
`[[Note#Heading^block]]`. Rename `Note` to `RenamedNote`. Verify:
- `[[RenamedNote#Some Heading]]` -- heading preserved
- `[[RenamedNote^blk-abc123]]` -- block ID preserved
- `[[RenamedNote#Heading^block]]` -- both preserved
- Actually following these links still works after rename

**6. Self-referencing links:**

Create a note `Alpha.md` that contains `[[Alpha#heading]]` (self-link). Rename
to `Beta`. Verify the self-link becomes `[[Beta#heading]]`.

**7. Index consistency after rename:**

After a rename, immediately run:

```vim
:lua local idx = require("andrew.vault.vault_index").current()
:lua print(vim.inspect(idx:get_inlinks("path/to/NewNote.md")))
```

Verify the inlinks reflect the updated wikilinks (all source files now link to
`NewNote`, not `OldName`).

### Performance Verification

On a vault with 500+ notes, compare rename preview speed:

```vim
" Before (ripgrep-based):
:lua local s = vim.uv.hrtime(); require("andrew.vault.rename").rename_preview("TestName"); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))

" After (index-based):
:lua local s = vim.uv.hrtime(); require("andrew.vault.rename").rename_preview("TestName"); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

**Targets:**
- Discovery phase (index): < 1ms (O(1) hash lookup)
- Discovery phase (ripgrep fallback): 50-200ms (unchanged)
- Rewriting phase: < 50ms for 20 affected files
- Index update after rename: < 200ms for 20 affected files

### Automated Verification

Add to existing test suite:

```lua
-- Test: rename module uses vault_index when available
do
  local source = io.open("lua/andrew/vault/rename.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    assert_true(content:find("discover_from_index") ~= nil,
      "has index-based discovery function")
    assert_true(content:find("discover_from_rg") ~= nil,
      "has ripgrep fallback discovery function")
    assert_true(content:find("build_old_name_set") ~= nil,
      "has alias-aware name set builder")
    assert_true(content:find("vault_index") ~= nil,
      "requires vault_index module")
    assert_true(content:find("update_files_batch") ~= nil,
      "uses batch index update after rename")
    assert_true(content:find("persist_now") ~= nil,
      "forces index persistence after rename")
    -- Verify block reference handling in target extraction
    assert_true(content:find("[^|#^]") ~= nil,
      "target extraction stops at ^ for block refs")
  end
end
```

---

## Risks & Mitigations

### Vault Index Staleness

**Risk:** The vault index may be out of date if external tools (e.g., Obsidian,
`sed`, another editor) modified files without triggering a Neovim `BufWritePost`
event. The index-based discovery could miss files that have new links not yet
indexed.

**Mitigation:** The ripgrep fallback guarantees correctness when the index is
unavailable. For the case where the index exists but is stale, the inlinks are
recomputed on every `build_async()` cycle (triggered by `FocusGained`,
filesystem watcher, and `BufWritePost`). Additionally, the rename operation
itself calls `persist_now()` which ensures the post-rename state is captured. If
staleness is suspected, the user can run `:VaultIndexRebuild` before renaming.

### Alias Rename Side Effects

**Risk:** When a note has aliases and is renamed, updating `[[alias]]` links to
`[[NewName]]` changes the visible link text. A user who deliberately used an
alias for readability (`[[My Project Notes]]` instead of `[[project-notes]]`)
may not want the alias reference replaced with the new filename.

**Mitigation:** This is actually the correct behavior -- the alias was a name
for the old note, and after rename the canonical name changes. However, if the
link used a pipe alias (`[[OldName|Display Text]]`), the display text is
preserved because the suffix `|Display Text` is kept. The only case affected is
bare alias links (`[[alias]]` without `|`), which is the expected rename
behavior. Document this in the `:VaultRename` help text. A future enhancement
could add an option to convert alias matches to `[[NewName|old-alias]]` to
preserve readability.

### Performance with Many Inlinks

**Risk:** A highly-linked note (e.g., a MOC or index note linked from 200+
files) will require reading and rewriting 200+ files during rename. The index
update via `update_files_batch()` must re-parse all 200 files.

**Mitigation:** The `update_files_batch()` method rebuilds derived indexes only
once (not once per file), keeping the overhead at O(N) file parses + O(1) index
rebuild. For 200 files at ~1ms per parse, this is ~200ms total. The rewriting
phase is already O(N) in the current ripgrep implementation, so the index update
is additive but proportional. For extreme cases (1000+ inlinks), a progress
notification could be shown.

### Backward Compatibility

**Risk:** The `collect_rename_changes()` function signature changes from
`(old_name, new_name)` to `(old_name, new_name, old_path)`. If any external
code calls this function directly, it would break.

**Mitigation:** `collect_rename_changes()` is a local function (not exported on
`M`). Only `rename_preview()` and `rename()` within the same file call it. No
external callers exist. The public API (`M.rename()`, `M.rename_preview()`,
`M.tag_rename()`) signatures are unchanged.

### Block Reference Pattern in Ripgrep Fallback

**Risk:** The current ripgrep pattern `#[^\]]*\]\]` already captures
`[[Name#heading^block]]` because `#` matches first and everything after it
(including `^block`) is consumed by `[^\]]*`. However, it does not match the
standalone `[[Name^block]]` pattern (no `#` prefix). The updated pattern adds
`\^[^\]]*\]\]` as an alternative.

**Mitigation:** The updated ripgrep pattern is strictly a superset of the
current one. It matches everything the old pattern matched, plus the additional
`[[Name^block]]` case. No existing matches are lost.

### Race Condition: Rename During Async Index Build

**Risk:** If the user triggers a rename while `build_async()` is in progress
(`idx._building == true`), the index state is partially updated. Discovery via
`get_inlinks()` may return incomplete results.

**Mitigation:** `is_ready()` returns true even during an incremental rebuild
(the index was loaded from persistence and is queryable). The incremental build
only updates entries whose mtime/size changed. Since the inlinks are derived
from the *current* state of `self.files`, they reflect the persisted state plus
any already-processed batch. In the worst case, a very recently added file's
links might be missed, but `is_ready()` correctly indicates the index is usable.
The ripgrep fallback remains available as a safety net if `is_ready()` returns
false.
