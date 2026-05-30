# Incremental Indexing

## Current State

The vault module uses multiple independent scanning and caching mechanisms, each
with its own TTL-based invalidation. There is no unified persistent index. Every
time a consumer needs vault-wide data, it either shells out to `fd`/`find` and
`rg`, or walks the filesystem with `vim.uv.fs_scandir`.

### Scanning Operations Inventory

**1. Engine Name Cache (`engine.lua`)**
- **What it does:** Maps lowercase note basenames and relative paths (without
  extension) to absolute file paths. Used by wikilink resolution, link
  diagnostics, autolink, completion, linkcheck, and unlinked mentions.
- **How it works:** Runs `fd --type f --extension md` (or `find`) synchronously
  via `vim.system():wait()`. Iterates every line of stdout, computing basenames
  and rel-stems.
- **TTL:** 10 seconds (`NAME_CACHE_TTL`). After expiry, the next
  `get_name_cache()` call triggers a full re-scan.
- **Invalidation:** `invalidate_name_cache()` resets the timestamp.
  `invalidate_all_caches()` calls this plus seven other module invalidators.
- **Pre-warming:** Async `prebuild_name_cache_async()` fires on the first
  `BufReadPost *.md` inside the vault (100ms deferred).
- **File:** `lua/andrew/vault/engine.lua` lines 640-742

**2. Wikilinks Resolution Cache (`wikilinks.lua`)**
- **What it does:** Maps lowercase note names (including frontmatter aliases) to
  arrays of absolute paths. Used by `resolve_link()` for `gf` navigation, embed
  resolution, graph, preview, completion, and wikilink highlights.
- **How it works:** Runs `fd`/`find` synchronously via `vim.system():wait()`.
  For *every* `.md` file found, calls `fm_parser.parse_file()` which opens and
  reads the file from disk to extract frontmatter aliases. This is the heaviest
  scan operation in the codebase.
- **TTL:** None (boolean `cache_valid` flag). Invalidated on `BufWritePost` for
  any vault `.md` file, or via `engine.invalidate_all_caches()`.
- **Trigger:** Lazy -- first call to `resolve_link()` or `ensure_cache()`.
  Pre-warmed on first vault `BufReadPost` (50ms deferred).
- **File:** `lua/andrew/vault/wikilinks.lua` lines 14-54

**3. Query Index (`query/index.lua`)**
- **What it does:** Builds a comprehensive per-file page structure: frontmatter
  fields, inline fields, tags (with parent expansion), outlinks, inlinks, tasks,
  lists, file stats (ctime, mtime, size), and day-from-filename.
- **How it works:** Recursive `vim.uv.fs_scandir` walk of the vault directory
  tree, reading every `.md` file fully into memory (`io.open + read("*a")`),
  parsing frontmatter, extracting links/tags/tasks with regex, then computing
  inlinks across all pages.
- **TTL:** 30 seconds (`config.query.index_ttl`).
- **Incremental support:** Partial -- `update_incremental()` exists and compares
  `stat.mtime.sec` against stored `_mtimes`, but still re-walks the entire
  directory tree on each call (the walk itself is not skipped, only the file
  parsing). Inlinks are fully recomputed every time.
- **Consumers:** Query system (dataview/vault code blocks), connections module.
- **File:** `lua/andrew/vault/query/index.lua`

**4. Connections Index (`connections.lua`)**
- **What it does:** Computes similarity scores between the current note and all
  other notes using tags (IDF-weighted), frontmatter fields, co-links, link
  proximity (1-hop and 2-hop), and temporal proximity.
- **How it works:** Calls `Index.new(vault_path):build_sync()` which triggers a
  full query index build. Then iterates all pages to score each candidate.
- **TTL:** 30 seconds for the index, 60 seconds for computed scores per source
  note.
- **File:** `lua/andrew/vault/connections.lua` lines 29-48

**5. Tag Collection (`tags.lua`)**
- **What it does:** Collects all unique tags (inline `#tag` and frontmatter YAML
  list items) across the vault.
- **How it works:** Two concurrent `rg` invocations: one for inline tags, one
  for frontmatter `tags:` blocks. Results merged and deduplicated.
- **TTL:** 15 seconds (`TAG_CACHE_TTL`).
- **File:** `lua/andrew/vault/tags.lua` lines 46-136

**6. Completion Source (`completion.lua` via `completion_base.lua`)**
- **What it does:** Provides blink-cmp completion items for wikilink note names,
  aliases, headings, and block IDs.
- **How it works:** Async `fd`/`find` to enumerate `.md` files. For each file,
  calls `vim.uv.fs_stat()` (for mtime-based sorting) and
  `fm_parser.parse_file()` (for aliases and description). Reads individual files
  on-demand for heading/block completion.
- **Invalidation:** On `BufWritePost *.md` via shared invalidator list.
- **File:** `lua/andrew/vault/completion.lua`, `completion_base.lua`

**7. Backlinks (`backlinks.lua`)**
- **What it does:** Finds notes linking to the current note.
- **How it works:** `rg` search for `[[note_name` across the vault. No caching.
- **File:** `lua/andrew/vault/backlinks.lua`

**8. Graph (`graph.lua`)**
- **What it does:** Builds a local link graph showing backlinks and forward links
  for the current note.
- **How it works:** Forward links extracted from buffer lines; backlinks via
  synchronous `vim.fn.systemlist({"rg", ...})`. Uses `wikilinks.resolve_link()`
  for path resolution.
- **File:** `lua/andrew/vault/graph.lua`

**9. Link Check / Link Diagnostics (`linkcheck.lua`, `linkdiag.lua`)**
- **What it does:** Validates wikilinks in the current buffer or entire vault.
  Checks note existence and heading anchor validity.
- **How it works:** Uses `engine.get_name_cache()` for existence checks.
  `linkdiag.lua` maintains a per-file heading cache keyed by
  `(mtime, ino, size)`.
- **File:** `lua/andrew/vault/linkcheck.lua`, `linkdiag.lua`

**10. Autolink Suggestions (`autolink.lua`)**
- **What it does:** Highlights text matching note names that could be wikilinked.
- **How it works:** Rebuilds a name index from `engine.get_name_cache()` every 15
  seconds. Splits into single-word and multi-word name lists.
- **File:** `lua/andrew/vault/autolink.lua`

**11. Unlinked Mentions (`unlinked.lua`)**
- **What it does:** Finds occurrences of note names in vault files that are not
  wrapped in wikilinks.
- **How it works:** Collects all note names via `engine.get_name_cache()`, batches
  them into rg patterns (max 50 per invocation), then post-filters results to
  exclude code blocks, frontmatter, headings, existing links, and URLs.
- **File:** `lua/andrew/vault/unlinked.lua`

**12. Wikilink Highlights (`wikilink_highlights.lua`)**
- **What it does:** Colors wikilinks based on resolution status (valid, broken,
  self-ref, heading valid/broken).
- **How it works:** Calls `wikilinks.resolve_link()` for every wikilink in the
  buffer. Uses `linkdiag.get_headings()` for heading validation.
- **File:** `lua/andrew/vault/wikilink_highlights.lua`

### Filesystem Watcher

`engine.lua` already has a `vim.uv.new_fs_event()` watcher on the vault root
with `{ recursive = true }`. On `.md` file changes it debounces (500ms) and
calls `invalidate_all_caches()`. However, `recursive = true` may not work on
Linux (inotify limitation), and the watcher only invalidates -- it does not
trigger any rebuild.

### Cache Invalidation Chain

`engine.invalidate_all_caches()` is called on:
- `FocusGained` (200ms debounced)
- Filesystem watcher events (500ms debounced)
- Vault switch

It invalidates: engine name cache, wikilinks cache, linkdiag heading cache,
calendar deadline cache, completion sources, tag cache, connection cache, callout
fold cache, and autolink index.

### Performance Cost Summary

For a vault with N markdown files:
- **Name cache rebuild:** 1 external process (`fd`) + O(N) string processing
- **Wikilinks cache rebuild:** 1 external process + O(N) file reads (frontmatter
  parsing)
- **Query index build:** O(N) `fs_scandir` calls + O(N) full file reads +
  O(N*L) link extraction + O(N^2) inlink computation (in the worst case)
- **Tag collection:** 2 external `rg` processes
- **Completion rebuild:** 1 external process + O(N) file reads (frontmatter) +
  O(N) `fs_stat` calls

On a 500-file vault, a full invalidation cycle that triggers all consumers can
cause multiple redundant full scans within seconds of each other, each reading
hundreds of files from disk.

## Problem

1. **Redundant scanning.** Multiple modules independently enumerate and parse the
   same files. A single `BufWritePost` can trigger the wikilinks cache, the
   engine name cache, the tag cache, the completion cache, and the linkdiag
   heading cache to all rebuild separately -- each re-reading overlapping sets of
   files from disk.

2. **No persistence.** Every Neovim session starts cold. Opening a vault file
   triggers synchronous full scans that block the UI. On a large vault (500+
   files), the initial `build_cache()` in wikilinks.lua (which reads frontmatter
   from every file) can take several hundred milliseconds.

3. **TTL-based invalidation is imprecise.** Caches expire by wall-clock time, not
   by actual filesystem changes. A 10-second TTL means the same scan runs
   repeatedly even when no files have changed. Conversely, changes made between
   TTL checks are invisible until the TTL expires.

4. **Full directory walks on incremental updates.** Even `query/index.lua`'s
   `update_incremental()` re-walks the entire directory tree (via
   `fs_scandir`) -- it only skips re-parsing files whose mtime hasn't changed.
   The walk itself is O(N) syscalls.

5. **No cross-module data sharing.** The wikilinks cache, engine name cache,
   query index, and completion source all parse the same frontmatter data
   independently. There is no unified data layer.

6. **Blocking synchronous operations.** `engine.get_name_cache()` and
   `wikilinks.build_cache()` use `vim.system():wait()` (synchronous) as a
   fallback when the async pre-warm hasn't completed yet. This can freeze the UI
   for hundreds of milliseconds on the first interaction.

## Proposed Solution

### Architecture

Replace the current collection of independent caches with a single **persistent
vault index** that:

1. Lives in a JSON (or MessagePack) file on disk, surviving across Neovim
   sessions.
2. Stores per-file metadata extracted from a single parse pass: note names,
   aliases, tags, links, headings, block IDs, frontmatter fields, file stats.
3. Uses **mtime-based change detection** on startup and on filesystem events to
   incrementally update only changed files.
4. Provides a unified API that all downstream modules consume instead of
   maintaining their own caches.
5. Rebuilds in the background using `vim.schedule` / coroutine yielding to avoid
   blocking the UI.

```
                     +-------------------+
                     |  Filesystem       |
                     |  (.md files)      |
                     +--------+----------+
                              |
                   fs_event / BufWritePost
                              |
                     +--------v----------+
                     |  Change Detector  |
                     |  (mtime + size)   |
                     +--------+----------+
                              |
                    changed files list
                              |
                     +--------v----------+
                     |  File Parser      |
                     |  (single pass)    |
                     +--------+----------+
                              |
                     +--------v----------+
                     |  Vault Index      |
                     |  (in-memory)      |
                     +--------+----------+
                        |     |     |
            +-----------+  +--+--+  +-----------+
            |              |     |              |
     name_cache    links/tags  headings   frontmatter
            |              |     |              |
     wikilinks      query   linkdiag    completion
     autolink       connections         wikilink_hl
     linkcheck      graph               tags
     unlinked       backlinks
```

### Index Schema

```lua
---@class VaultIndex
---@field version number Schema version for migration detection
---@field vault_path string Absolute path to vault root
---@field built_at number Timestamp of last full build
---@field files table<string, VaultIndexEntry> Keyed by vault-relative path

---@class VaultIndexEntry
---@field rel_path string Vault-relative path (e.g. "Projects/Alpha.md")
---@field abs_path string Absolute filesystem path
---@field basename string Filename without extension (e.g. "Alpha")
---@field basename_lower string Lowercase basename for lookups
---@field folder string Parent folder relative to vault (e.g. "Projects")
---@field mtime number File modification time (seconds since epoch)
---@field size number File size in bytes
---@field ctime number|nil File creation time (birthtime, may be nil on Linux)
---@field frontmatter table<string, any> Parsed frontmatter fields
---@field aliases string[] Frontmatter aliases (lowercased)
---@field tags string[] All tags (inline + frontmatter, with parent expansion)
---@field headings VaultHeading[] Ordered list of headings
---@field heading_slugs table<string, boolean> Slug lookup set
---@field block_ids string[] Block reference IDs (without ^ prefix)
---@field outlinks VaultLink[] Wikilinks and embeds
---@field tasks VaultTask[] Task items
---@field inline_fields table<string, any> Dataview-style inline fields
---@field day string|nil Date extracted from filename (YYYY-MM-DD)

---@class VaultHeading
---@field text string Raw heading text (without # prefix)
---@field slug string URL-safe slug
---@field level number Heading level (1-6)
---@field line number 1-indexed line number

---@class VaultLink
---@field path string Link target (note name or path, may include #heading/^block)
---@field display string Display text
---@field embed boolean Whether this is an embed (![[...]])

---@class VaultTask
---@field text string Task text
---@field status string Character inside brackets (space, x, /, -, >)
---@field completed boolean
---@field line number 1-indexed line number
---@field tags string[]
---@field fields table<string, any> Inline fields on the task line
```

### Change Detection

**Primary: mtime + size comparison**

On startup and on filesystem events, compare each file's `(mtime, size)` tuple
against the stored index entry. If either differs, the file is marked as changed
and queued for re-parsing.

```lua
local function detect_changes(index, vault_path)
  local changed = {}   -- files to re-parse
  local deleted = {}    -- files removed from disk
  local seen = {}       -- track which indexed files still exist

  -- Walk filesystem
  walk_directory(vault_path, function(rel_path, abs_path, stat)
    seen[rel_path] = true
    local entry = index.files[rel_path]
    if not entry
      or entry.mtime ~= stat.mtime.sec
      or entry.size ~= stat.size
    then
      changed[#changed + 1] = { rel_path = rel_path, abs_path = abs_path, stat = stat }
    end
  end)

  -- Detect deletions
  for rel_path in pairs(index.files) do
    if not seen[rel_path] then
      deleted[#deleted + 1] = rel_path
    end
  end

  return changed, deleted
end
```

**Why not file hashing?** Hashing (e.g., xxhash of file content) provides
stronger change detection but requires reading every file on every check. The
`(mtime, size)` pair catches all normal edits with zero file I/O. In the rare
case of a file modified without mtime change (e.g., `touch -m -t` with same
timestamp), a manual `:VaultIndexRebuild` command provides an escape hatch.

**File watcher integration:**

The existing `vim.uv.new_fs_event()` watcher in engine.lua will be extended to
feed changed file paths directly into the incremental update pipeline instead
of blanket-invalidating all caches. On Linux where `recursive = true` is
unreliable, fall back to watching the vault root only and use the debounced
`invalidate_all_caches()` behavior to trigger a directory walk diff.

```lua
-- In the fs_event callback, instead of invalidating everything:
if filename and filename:match("%.md$") then
  local rel_path = filename  -- already relative on most platforms
  local abs_path = vault_path .. "/" .. rel_path
  vault_index.queue_file_update(abs_path, rel_path)
end
```

### Incremental Update Pipeline

**Step 1: Detect changes**
- On startup: load persisted index, walk filesystem, compare mtimes.
- On fs_event/BufWritePost: add specific file(s) to the update queue.
- On FocusGained: walk filesystem, compare mtimes (debounced).

**Step 2: Parse changed files**
- For each changed file, perform a single-pass parse that extracts all data
  needed by every consumer: frontmatter, aliases, tags, links, headings,
  block IDs, tasks, inline fields.
- This replaces the current pattern where wikilinks.lua, completion.lua,
  query/index.lua, and tags.lua each parse the same files independently.

**Step 3: Merge into index**
- Update `index.files[rel_path]` with the new entry.
- Remove entries for deleted files.

**Step 4: Recompute derived data**
- Rebuild the name lookup table (basename -> paths).
- Recompute inlinks: for efficiency, only recompute inlinks involving changed
  files. Maintain a reverse map: `target_name -> set of source_rel_paths`. When
  a file changes, remove its old outlinks from the reverse map and add its new
  outlinks.
- Signal downstream consumers that the index has been updated.

**Step 5: Persist to disk**
- Write the updated index to the persistence file.
- Debounce writes (e.g., at most once per 5 seconds) to avoid excessive I/O.

```lua
function VaultIndex:incremental_update(changed_files, deleted_files)
  -- Remove deleted entries
  for _, rel_path in ipairs(deleted_files) do
    self:_remove_file(rel_path)
  end

  -- Parse and update changed entries
  for _, file in ipairs(changed_files) do
    local entry = self:_parse_file(file.abs_path, file.rel_path, file.stat)
    if entry then
      self.files[file.rel_path] = entry
    end
  end

  -- Recompute derived data
  self:_rebuild_name_index()
  self:_recompute_inlinks_incremental(changed_files, deleted_files)

  -- Schedule persistence
  self:_schedule_persist()

  -- Notify consumers
  self:_notify_update()
end
```

### Persistence Layer

**File format: JSON**

JSON is chosen over MessagePack for:
- Human readability (debuggable with any text editor)
- Native support via `vim.json.encode`/`vim.json.decode` (no external deps)
- Acceptable performance for vault sizes up to ~2000 files

For larger vaults, MessagePack can be a future optimization (replace
`vim.json.encode` with `vim.mpack.encode`).

**Storage location:**

```
{vault_path}/.vault-index/index.json
```

The `.vault-index/` directory is inside the vault so it travels with the vault
(useful for syncing between machines), but should be added to `.gitignore`. An
alternative location can be configured:

```lua
-- Alternative: Neovim data directory (never synced)
vim.fn.stdpath("data") .. "/vault-index/" .. vault_hash .. "/index.json"
```

**Read/write implementation:**

```lua
local PERSIST_DEBOUNCE_MS = 5000

function VaultIndex:load()
  local path = self:_index_path()
  local content = engine.read_file(path)
  if not content then return false end

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return false end

  -- Version check
  if data.version ~= CURRENT_SCHEMA_VERSION then
    return false  -- trigger full rebuild
  end

  -- Vault path check
  if data.vault_path ~= self.vault_path then
    return false  -- wrong vault
  end

  self.files = data.files or {}
  self.built_at = data.built_at or 0
  return true
end

function VaultIndex:_schedule_persist()
  if self._persist_timer then
    self._persist_timer:stop()
  end
  self._persist_timer = vim.uv.new_timer()
  self._persist_timer:start(PERSIST_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    self:_persist()
  end))
end

function VaultIndex:_persist()
  local data = {
    version = CURRENT_SCHEMA_VERSION,
    vault_path = self.vault_path,
    built_at = os.time(),
    files = self.files,
  }
  local json = vim.json.encode(data)
  engine.write_file(self:_index_path(), json)
end
```

### Background Processing

The initial startup diff and any large re-index operations must not block the UI.
Use a coroutine-based approach that yields control back to the event loop after
processing each batch of files.

```lua
local BATCH_SIZE = 20  -- files per batch before yielding

function VaultIndex:build_async(callback)
  local co = coroutine.create(function()
    local changed, deleted = detect_changes(self, self.vault_path)

    -- Process deletions immediately (cheap)
    for _, rel_path in ipairs(deleted) do
      self:_remove_file(rel_path)
    end

    -- Process changed files in batches
    for i = 1, #changed, BATCH_SIZE do
      local batch_end = math.min(i + BATCH_SIZE - 1, #changed)
      for j = i, batch_end do
        local file = changed[j]
        local entry = self:_parse_file(file.abs_path, file.rel_path, file.stat)
        if entry then
          self.files[file.rel_path] = entry
        end
      end
      -- Yield after each batch so the UI stays responsive
      coroutine.yield()
    end

    -- Recompute derived data
    self:_rebuild_name_index()
    self:_recompute_inlinks()
    self:_schedule_persist()
    self:_notify_update()

    if callback then callback() end
  end)

  -- Resume the coroutine on each vim.schedule tick
  local function step()
    if coroutine.status(co) == "dead" then return end
    local ok, err = coroutine.resume(co)
    if not ok then
      vim.notify("Vault index error: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if coroutine.status(co) ~= "dead" then
      vim.schedule(step)
    end
  end

  vim.schedule(step)
end
```

For single-file updates (e.g., `BufWritePost`), the operation is fast enough to
run synchronously since only one file is parsed.

### Integration Points

Each downstream module will be refactored to consume the unified index instead
of maintaining its own cache.

**wikilinks.lua:**
- Remove `build_cache()` and the `fd`/`find` + `fm_parser.parse_file()` loop.
- `resolve_link(name)` queries `vault_index:resolve_name(name)` which uses the
  pre-built basename + alias lookup tables.

**engine.lua (name cache):**
- Remove `get_name_cache()`, `prebuild_name_cache_async()`, and the
  `_name_cache` module-level state.
- Replace with `vault_index:get_name_cache()` that returns the same
  `{ names, paths }` structure from the index's derived data.

**query/index.lua:**
- `Index:build_sync()` and `Index:update_incremental()` read from the vault
  index instead of walking the filesystem. The query index becomes a *view* on
  top of the vault index, constructing its page objects from index entries.
- This eliminates the second full filesystem walk and file read pass.

**connections.lua:**
- `get_index()` uses the vault index-backed query index. Scores are cached as
  before, but the underlying index is always fresh.

**tags.lua:**
- `collect_tags()` reads tags directly from `vault_index.files[*].tags` instead
  of running two `rg` processes. This is O(N) iteration over in-memory data
  instead of two external process invocations.

**completion.lua:**
- The `build` function reads from the vault index instead of running `fd` and
  parsing frontmatter for every file. Completion items are constructed from
  index entries.

**linkcheck.lua / linkdiag.lua:**
- `link_exists()` and heading validation use the vault index's name lookup and
  per-file heading slug sets directly, instead of calling
  `engine.get_name_cache()` and `link_utils.extract_headings()`.

**autolink.lua:**
- `rebuild_index()` reads names from the vault index instead of
  `engine.get_name_cache()`.

**backlinks.lua / graph.lua:**
- Backlink searches can optionally use the vault index's inlink data instead of
  running `rg`, providing instant results for the local graph view.
- For regex-based backlink search (context lines, fuzzy matching), `rg` remains
  the right tool -- but the index can provide a pre-filtered file list to
  narrow the search.

**unlinked.lua:**
- Note name collection uses the vault index. The `rg`-based search remains for
  actual content matching, but the name list is instant.

### Migration Path

The migration is designed to be incremental -- each module can be converted
independently while the system remains functional throughout.

**Phase 1: Core index module**
- Create `lua/andrew/vault/vault_index.lua` with the persistent index, change
  detection, single-pass parser, and background build.
- Add the index lifecycle to `init.lua` (load on startup, persist on exit).
- Add `:VaultIndexRebuild`, `:VaultIndexStatus` commands.
- The old caches continue to work; the new index runs alongside them.

**Phase 2: Engine integration**
- Replace `engine.get_name_cache()` with a wrapper that delegates to the vault
  index. Remove the `fd`/`find` scanning code.
- Replace `engine.list_md_files_async()` with an index-backed version.
- Update `engine.invalidate_all_caches()` to trigger an incremental index update
  instead of blanket invalidation.

**Phase 3: Wikilinks integration**
- Replace `wikilinks.build_cache()` with index-backed name + alias resolution.
- Remove the `fm_parser.parse_file()` loop inside wikilinks.

**Phase 4: Query index integration**
- Refactor `query/index.lua` to construct page objects from vault index entries
  instead of walking the filesystem and re-parsing files.
- Keep the `Index` API surface identical so query execution is unaffected.

**Phase 5: Remaining modules**
- Convert tags, completion, linkdiag, autolink, linkcheck to use the vault
  index.
- Remove redundant caching code from each module.

**Phase 6: Cleanup**
- Remove unused `fd`/`find` helpers from engine.lua (or keep for non-index
  fallback).
- Remove per-module TTL constants that are no longer needed.
- Update config.lua to remove `query.index_ttl` and `connections.index_ttl` (the
  index is always live).

### Implementation Details

**New module: `lua/andrew/vault/vault_index.lua`**

```lua
local M = {}

local SCHEMA_VERSION = 1
local BATCH_SIZE = 20
local PERSIST_DEBOUNCE_MS = 5000

-- Skip these directories during walks
local SKIP_DIRS = {
  [".obsidian"] = true,
  [".git"] = true,
  [".trash"] = true,
  [".vault-index"] = true,
  ["node_modules"] = true,
}

---@class VaultIndexInstance
---@field vault_path string
---@field files table<string, VaultIndexEntry>
---@field _name_index table<string, string[]> lowercase name -> [abs_paths]
---@field _alias_index table<string, string[]> lowercase alias -> [abs_paths]
---@field _inlinks table<string, VaultLink[]> rel_path -> inbound links
---@field _persist_timer uv.uv_timer_t|nil
---@field _generation number Monotonically increasing update counter
---@field _subscribers function[] Update notification callbacks

M.VaultIndex = {}
M.VaultIndex.__index = M.VaultIndex

function M.VaultIndex.new(vault_path)
  local self = setmetatable({}, M.VaultIndex)
  self.vault_path = vault_path:gsub("/$", "")
  self.files = {}
  self._name_index = {}
  self._alias_index = {}
  self._inlinks = {}
  self._persist_timer = nil
  self._generation = 0
  self._subscribers = {}
  return self
end

--- Subscribe to index updates. Returns an unsubscribe function.
function M.VaultIndex:subscribe(fn)
  self._subscribers[#self._subscribers + 1] = fn
  return function()
    for i, sub in ipairs(self._subscribers) do
      if sub == fn then
        table.remove(self._subscribers, i)
        return
      end
    end
  end
end

--- Notify all subscribers that the index has been updated.
function M.VaultIndex:_notify_update()
  self._generation = self._generation + 1
  for _, fn in ipairs(self._subscribers) do
    pcall(fn, self._generation)
  end
end

--- Load from persistence file. Returns true if successful.
function M.VaultIndex:load()
  -- Implementation as described in Persistence Layer section
end

--- Full synchronous build (fallback).
function M.VaultIndex:build_sync()
  self.files = {}
  self:_walk(self.vault_path, "")
  self:_rebuild_name_index()
  self:_recompute_inlinks()
  self:_schedule_persist()
  self:_notify_update()
  return self
end

--- Async incremental build (normal startup path).
function M.VaultIndex:build_async(callback)
  -- Implementation as described in Background Processing section
end

--- Single-file update (for BufWritePost).
function M.VaultIndex:update_file(abs_path)
  local rel_path = abs_path:sub(#self.vault_path + 2)
  local stat = vim.uv.fs_stat(abs_path)
  if not stat then
    -- File deleted
    self:_remove_file(rel_path)
  else
    local entry = self:_parse_file(abs_path, rel_path, stat)
    if entry then
      self.files[rel_path] = entry
    end
  end
  self:_rebuild_name_index()
  self:_recompute_inlinks_incremental({ rel_path })
  self:_schedule_persist()
  self:_notify_update()
end

--- Resolve a note name to absolute path(s).
function M.VaultIndex:resolve_name(name)
  local lower = name:lower()
  local by_name = self._name_index[lower]
  if by_name and #by_name > 0 then return by_name end
  local by_alias = self._alias_index[lower]
  if by_alias and #by_alias > 0 then return by_alias end
  return nil
end

--- Get the name cache in the same format as engine.get_name_cache().
function M.VaultIndex:get_name_cache()
  local names = {}
  local paths = {}
  for rel_path, entry in pairs(self.files) do
    names[entry.basename_lower] = true
    if not paths[entry.basename_lower] then
      paths[entry.basename_lower] = entry.abs_path
    end
    local rel_stem = rel_path:gsub("%.md$", ""):lower()
    if rel_stem ~= entry.basename_lower then
      names[rel_stem] = true
      if not paths[rel_stem] then
        paths[rel_stem] = entry.abs_path
      end
    end
  end
  return { names = names, paths = paths }
end

--- Get all tags across the vault.
function M.VaultIndex:all_tags()
  local tag_set = {}
  for _, entry in pairs(self.files) do
    for _, tag in ipairs(entry.tags) do
      tag_set[tag] = true
    end
  end
  local tags = {}
  for tag in pairs(tag_set) do
    tags[#tags + 1] = tag
  end
  table.sort(tags)
  return tags
end

--- Parse a single file into a VaultIndexEntry.
function M.VaultIndex:_parse_file(abs_path, rel_path, stat)
  -- Single-pass extraction of all metadata
  -- Reuses parsing logic from query/index.lua
end

return M
```

**Key function: `_parse_file` (single-pass parser)**

This function consolidates the parsing logic currently spread across
`query/index.lua` (`_index_file`, `_split_frontmatter`, `_parse_frontmatter`,
`_extract_tags`, `_extract_links`, `_extract_tasks_and_lists`,
`_extract_inline_fields`), `frontmatter_parser.lua` (`parse_file`), and
`link_utils.lua` (`extract_headings`).

```lua
function M.VaultIndex:_parse_file(abs_path, rel_path, stat)
  local content = engine.read_file(abs_path)
  if not content then return nil end

  local basename = rel_path:match("([^/]+)%.md$") or rel_path:gsub("%.md$", "")
  local folder = rel_path:match("^(.+)/[^/]+$") or ""

  -- Split frontmatter / body
  local fm_text, body = split_frontmatter(content)
  local fm_fields = parse_frontmatter(fm_text)

  -- Extract aliases
  local aliases = {}
  local raw_aliases = fm_fields.aliases
  if type(raw_aliases) == "table" then
    for _, a in ipairs(raw_aliases) do
      aliases[#aliases + 1] = tostring(a):lower()
    end
  elseif type(raw_aliases) == "string" then
    aliases[#aliases + 1] = raw_aliases:lower()
  end

  -- Extract tags (frontmatter + inline body tags with parent expansion)
  local tags = extract_tags(fm_fields, body)

  -- Extract headings
  local headings, heading_slugs = extract_headings(content)

  -- Extract block IDs
  local block_ids = extract_block_ids(content)

  -- Extract outlinks (wikilinks + embeds)
  local outlinks = extract_links(content)

  -- Extract tasks
  local tasks = extract_tasks(body)

  -- Extract inline fields
  local inline_fields = extract_inline_fields(body)

  -- Date from filename
  local day = basename:match("^(%d%d%d%d%-%d%d%-%d%d)")

  return {
    rel_path = rel_path,
    abs_path = abs_path,
    basename = basename,
    basename_lower = basename:lower(),
    folder = folder,
    mtime = stat.mtime.sec,
    size = stat.size,
    ctime = stat.birthtime and stat.birthtime.sec or nil,
    frontmatter = fm_fields,
    aliases = aliases,
    tags = tags,
    headings = headings,
    heading_slugs = heading_slugs,
    block_ids = block_ids,
    outlinks = outlinks,
    tasks = tasks,
    inline_fields = inline_fields,
    day = day,
  }
end
```

### File Changes

**New files:**
- `lua/andrew/vault/vault_index.lua` -- Core index module (persistent index,
  change detection, single-pass parser, background build, subscriber
  notifications)

**Modified files (in migration order):**

1. `lua/andrew/vault/engine.lua`
   - Add `vault_index` instance lifecycle (create on startup, load persisted,
     build async)
   - Replace `get_name_cache()` internals with index delegation
   - Replace `list_md_files_async()` with index-backed version
   - Update `invalidate_all_caches()` to trigger incremental index update
   - Update `start_fs_watcher()` to feed file paths to index

2. `lua/andrew/vault/init.lua`
   - Initialize the vault index on load
   - Start async build on first vault file open
   - Register VaultIndex commands

3. `lua/andrew/vault/wikilinks.lua`
   - Replace `build_cache()` with index-backed resolution
   - Remove `fd`/`find` + frontmatter parsing loop
   - `resolve_link()` delegates to `vault_index:resolve_name()`

4. `lua/andrew/vault/query/index.lua`
   - `build_sync()` constructs page objects from vault index entries
   - `update_incremental()` only re-wraps changed entries
   - Remove filesystem walking and file reading code

5. `lua/andrew/vault/connections.lua`
   - `get_index()` uses the vault-index-backed query index
   - Remove redundant `_index` state and TTL checking

6. `lua/andrew/vault/tags.lua`
   - `collect_tags()` reads from `vault_index:all_tags()`
   - Remove `rg` invocations for tag collection

7. `lua/andrew/vault/completion.lua`
   - `build()` reads from vault index entries
   - Remove `fd`/`find` + `fm_parser.parse_file()` loop

8. `lua/andrew/vault/linkcheck.lua`
   - Use vault index for name existence and heading validation
   - Remove direct `engine.get_name_cache()` calls

9. `lua/andrew/vault/linkdiag.lua`
   - Use vault index heading data instead of per-file heading cache
   - Remove `_heading_cache` module state

10. `lua/andrew/vault/autolink.lua`
    - `rebuild_index()` reads from vault index name data
    - Remove `engine.get_name_cache()` dependency

11. `lua/andrew/vault/wikilink_highlights.lua`
    - No structural changes; benefits automatically from faster
      `resolve_link()` and `get_headings()`

12. `lua/andrew/vault/unlinked.lua`
    - Name collection reads from vault index
    - rg search remains for content matching

13. `lua/andrew/vault/graph.lua`
    - Backlink collection can optionally use index inlinks
    - Forward link resolution benefits from faster `resolve_link()`

14. `lua/andrew/vault/config.lua`
    - Add `index` configuration section
    - Deprecate `query.index_ttl` and `connections.index_ttl`

### Configuration

Add to `lua/andrew/vault/config.lua`:

```lua
-- ---------------------------------------------------------------------------
-- Vault index
-- ---------------------------------------------------------------------------
M.index = {
  -- Where to store the persistent index.
  -- "vault" = {vault_path}/.vault-index/index.json
  -- "data"  = vim.fn.stdpath("data")/vault-index/{hash}/index.json
  storage = "vault",

  -- Maximum time (ms) to spend on synchronous index operations
  -- before deferring to async. Affects first-access latency.
  sync_timeout_ms = 100,

  -- Batch size for background parsing (files per vim.schedule tick).
  -- Lower = more responsive UI, higher = faster total build time.
  batch_size = 20,

  -- Debounce interval (ms) for persisting index to disk after updates.
  persist_debounce_ms = 5000,

  -- Enable filesystem watcher for real-time change detection.
  -- Set to false if the watcher causes issues (e.g., on network drives).
  watch = true,

  -- Debounce interval (ms) for filesystem watcher events.
  watch_debounce_ms = 500,

  -- Log index operations to :messages (for debugging).
  debug = false,
}
```

### Testing Plan

**Unit tests (standalone, no Neovim required):**

1. **Parser correctness:** Feed known markdown files to `_parse_file()` and
   verify extracted frontmatter, tags, links, headings, block IDs, and tasks
   match expected values. Cover edge cases: empty files, no frontmatter, nested
   tags, escaped pipes in table wikilinks, multi-alias frontmatter.

2. **Change detection:** Create a mock index with known mtimes. Modify some
   files' mtimes, add new files, delete some. Verify `detect_changes()` returns
   the correct changed/deleted sets.

3. **Incremental update:** Start with a built index. Modify one file, add one
   file, delete one file. Run incremental update. Verify the index matches a
   fresh full build.

4. **Name resolution:** Build an index, then test `resolve_name()` with
   basenames, relative paths, aliases, case variations, and ambiguous names
   (same basename in different folders).

5. **Inlink computation:** Build an index with known link structure. Verify
   inlinks are correct. Modify one file's links, run incremental update, verify
   inlinks are still correct.

**Integration tests (in Neovim):**

6. **Startup performance:** Measure time from first vault file open to index
   availability. On a cold start (no persisted index), verify the async build
   completes within a reasonable time. On a warm start (persisted index with no
   changes), verify the index is available within 50ms.

7. **Wikilink resolution accuracy:** After switching to index-backed resolution,
   verify that `gf` navigation, completion, and link diagnostics produce
   identical results to the old cache-based system. Run `:VaultLinkCheckAll` and
   compare output before and after migration.

8. **Tag collection accuracy:** Compare `vault_index:all_tags()` output against
   the old `rg`-based `collect_tags()` output. They should produce identical
   sorted tag lists.

9. **Query results consistency:** Run a set of dataview queries before and after
   the migration. Results should be identical.

10. **Filesystem watcher:** Create, modify, rename, and delete `.md` files
    outside Neovim while it is running. Verify the index picks up changes within
    the debounce window.

11. **Vault switch:** Switch between vaults using `:VaultSwitch`. Verify the
    index loads/builds correctly for the new vault and all downstream modules
    reflect the change.

12. **Index corruption recovery:** Corrupt the persisted index file (truncate it,
    write garbage). Verify that on next startup, the system detects corruption,
    falls back to a full rebuild, and writes a valid index.

13. **Schema migration:** Change `SCHEMA_VERSION`, restart Neovim. Verify the
    old index is discarded and a full rebuild occurs.

**Performance benchmarks:**

14. **Cold build time:** Measure full index build time on vaults of 100, 500,
    and 1000 files. Target: < 500ms for 500 files.

15. **Warm startup time:** Measure time to load persisted index and diff against
    filesystem with 0 changes. Target: < 50ms for 500 files.

16. **Single-file update time:** Measure time for `update_file()` on a single
    changed file. Target: < 10ms.

17. **Memory usage:** Compare memory usage before and after migration. The
    unified index should use less total memory than the sum of all independent
    caches, since data is stored once instead of duplicated across modules.
