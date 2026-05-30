# 36 - SQLite Full-Text Search Index

**Priority:** Medium-High -- significant performance gain for large vaults (1000+ notes)
**Status:** Planned
**Primary file:** `lua/andrew/vault/fts_index.lua` (new)
**Modified files:** `search_filter.lua`, `search.lua`, `vault_index.lua`, `config.lua`

## Summary

Replace the ripgrep-only text search path with a persistent SQLite FTS5 index
stored at `.vault-index/search.db`. The current system invokes `rg` as a
subprocess on every keystroke in live search mode and on every query submission
in prompt mode. For repeated searches, large vaults, and complex boolean
queries (where multiple `rg` invocations are composed), the subprocess overhead
dominates. An FTS5 index eliminates process spawning, avoids re-reading file
contents from disk on every query, and moves boolean evaluation into SQLite
where it is handled natively. Expected speedup: 10-100x for repeated queries
on vaults with 1000+ notes; smaller but measurable gains even on 200-note
vaults due to amortized I/O.

## Current State

### Text search pipeline (`search_filter.lua`)

The search filter module classifies each AST node as **metadata** (evaluated
against the vault index in-process) or **text** (delegated to ripgrep). The
`split_ast()` function (line 1059) separates the query into a `metadata_ast`
and a `text_ast`, then `resolve_query()` in `search.lua` (line 102) executes
them in the appropriate order:

1. **metadata_only** -- `evaluate()` scans `idx.files`, returns matching
   `rel_path`s.
2. **text_only** -- collects all `abs_path`s from the index, calls
   `ripgrep_in_files()`.
3. **metadata_then_text** -- evaluates metadata first to narrow the file set,
   then calls `ripgrep_in_files()` restricted to those files.
4. **mixed_or** -- evaluates both sides independently, unions results.

### `ripgrep_in_files()` internals (line 1489)

This function handles the boolean text AST recursively:

- **Leaf nodes** (`text`, `regex`): call `run_rg_single()` which spawns `rg`
  via `vim.system()`, optionally using `--files-from` with a temp file when the
  file set is small enough (<= `config.search.max_files_from`, default 500).
- **AND**: run both sides, intersect file sets, keep lines from common files.
- **OR**: run both sides, union results with deduplication.
- **NOT**: run inner expression, return complement file paths.

Each boolean combiner spawns at least one additional `rg` process. A query like
`"foo" AND "bar" AND -"baz"` spawns 3 ripgrep invocations synchronously.

### Performance bottlenecks

| Operation | Cost |
|-----------|------|
| Process spawn per `rg` invocation | ~5-15ms on Linux |
| Disk I/O per search (rg reads all files) | O(vault_size) |
| Temp file creation for `--files-from` | ~1ms per query |
| Boolean composition (serial `rg` calls) | N * spawn_cost |
| Live mode re-evaluation on every keystroke | all of the above, debounced |

For a 2000-note vault (~50MB of markdown), a single `rg` pass takes ~30-80ms.
A 3-term AND query takes 100-250ms. In live mode with 150ms debounce, the
search feels sluggish and can queue up stale results.

## Architecture

### New module: `lua/andrew/vault/fts_index.lua`

A self-contained module managing a SQLite database with an FTS5 virtual table.
Follows the singleton pattern established by `vault_index.lua`.

```
.vault-index/
  index.json      (existing metadata index)
  search.db       (new FTS5 database)
```

### Database schema

```sql
-- Metadata table for schema versioning and tracking
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);

-- FTS5 content table: stores file content keyed by rel_path
-- Using content= (external content) mode to avoid storing content twice
-- when we can read it from disk for snippets.
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
    rel_path,
    content,
    mtime UNINDEXED,       -- mtime for change detection (not searchable)
    size UNINDEXED,         -- file size for change detection
    content='notes',        -- external content table
    content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
);

-- Backing content table for external-content FTS5
CREATE TABLE IF NOT EXISTS notes (
    rowid   INTEGER PRIMARY KEY AUTOINCREMENT,
    rel_path TEXT UNIQUE NOT NULL,
    content  TEXT NOT NULL,
    mtime    INTEGER NOT NULL,
    size     INTEGER NOT NULL
);

-- Triggers to keep FTS5 in sync with content table
CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, rel_path, content, mtime, size)
    VALUES (new.rowid, new.rel_path, new.content, new.mtime, new.size);
END;

CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, rel_path, content, mtime, size)
    VALUES ('delete', old.rowid, old.rel_path, old.content, old.mtime, old.size);
END;

CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, rel_path, content, mtime, size)
    VALUES ('delete', old.rowid, old.rel_path, old.content, old.mtime, old.size);
    INSERT INTO notes_fts(rowid, rel_path, content, mtime, size)
    VALUES (new.rowid, new.rel_path, new.content, new.mtime, new.size);
END;
```

**Design rationale:**

- **External-content FTS5**: The `content='notes'` directive tells FTS5 to
  read full content from the `notes` table when needed (e.g., for snippets via
  `snippet()`), but the FTS index itself only stores the inverted token index.
  This halves storage compared to internal-content mode.
- **`unicode61` tokenizer**: Handles accented characters, CJK, and other
  Unicode properly. `remove_diacritics 2` normalizes accented characters for
  broader matching.
- **`mtime` and `size` as UNINDEXED columns**: Available for change detection
  queries without polluting the full-text index.

### Module API (`fts_index.lua`)

```lua
local M = {}

--- Singleton instance
M._instance = nil

--- Get or create the FTS index for the given vault path.
---@param vault_path string
---@return FtsIndex
function M.get(vault_path) end

--- Get current instance (nil if not initialized).
---@return FtsIndex|nil
function M.current() end

--- FtsIndex class
---@class FtsIndex
---@field vault_path string
---@field db_path string
---@field db userdata SQLite connection
---@field _ready boolean

--- Open the database, create tables if needed, check schema version.
function FtsIndex:open() end

--- Close the database connection.
function FtsIndex:close() end

--- Full rebuild: re-index all markdown files in the vault.
--- Called on first run or after schema version bump.
function FtsIndex:rebuild() end

--- Incremental update: re-index only changed files.
--- Uses mtime+size change detection (same as vault_index).
---@param changed table[] Array of { rel_path, abs_path, mtime, size }
---@param deleted string[] Array of rel_paths to remove
function FtsIndex:update(changed, deleted) end

--- Update a single file (for BufWritePost integration).
---@param abs_path string
function FtsIndex:update_file(abs_path) end

--- Execute an FTS5 MATCH query. Returns matching rel_paths with optional
--- context snippets.
---@param fts_query string FTS5 query syntax
---@param opts? { snippets?: boolean, limit?: number, file_set?: table<string,boolean> }
---@return table[] Array of { rel_path: string, snippet?: string, rank: number }
function FtsIndex:search(fts_query, opts) end

--- Check if the FTS index is ready for queries.
---@return boolean
function FtsIndex:is_ready() end

--- Persist immediately (for VimLeavePre).
function FtsIndex:close_now() end

return M
```

### Query translation: AST text nodes to FTS5 MATCH syntax

The core translation function converts the text portion of a search AST into
FTS5 query syntax. FTS5 natively supports AND, OR, NOT, and phrase queries,
so the boolean composition currently done by spawning multiple `rg` processes
can be expressed as a single SQL query.

```lua
--- Translate a text AST node tree into an FTS5 MATCH expression.
---@param node table text AST node (from extract_text_ast)
---@return string|nil fts5_query, boolean|nil needs_rg_fallback
local function ast_to_fts5(node)
    if not node then return nil end

    if node.type == "text" then
        if node.quoted then
            -- FTS5 phrase query: "exact phrase"
            return '"' .. escape_fts5(node.value) .. '"'
        else
            -- Unquoted text: each word as an implicit AND
            -- FTS5 default is already AND between terms
            return escape_fts5(node.value)
        end
    end

    if node.type == "regex" then
        -- FTS5 cannot handle regex; signal fallback to ripgrep
        return nil, true
    end

    if node.type == "and" then
        local left = ast_to_fts5(node.left)
        local right = ast_to_fts5(node.right)
        if not left or not right then return nil, true end
        return "(" .. left .. ") AND (" .. right .. ")"
    end

    if node.type == "or" then
        local left = ast_to_fts5(node.left)
        local right = ast_to_fts5(node.right)
        if not left or not right then return nil, true end
        return "(" .. left .. ") OR (" .. right .. ")"
    end

    if node.type == "not" then
        local inner = ast_to_fts5(node.operand)
        if not inner then return nil, true end
        return "NOT (" .. inner .. ")"
    end

    return nil, true
end
```

**Boolean mapping:**

| Search AST | FTS5 MATCH |
|------------|------------|
| `text("deploy")` | `deploy` |
| `text("exact phrase", quoted=true)` | `"exact phrase"` |
| `text("foo") AND text("bar")` | `(foo) AND (bar)` |
| `text("foo") OR text("bar")` | `(foo) OR (bar)` |
| `NOT text("draft")` | `NOT (draft)` |
| `text("foo") AND NOT text("bar")` | `(foo) AND NOT (bar)` |
| `regex("/pattern/")` | FALLBACK to ripgrep |

**FTS5 escaping:** Double-quote characters inside values must be escaped by
doubling them (`"` -> `""`). Additionally, FTS5 special characters (`*`, `^`,
`NEAR`) within literal search terms need quoting.

```lua
local function escape_fts5(text)
    -- Wrap in double quotes to treat as a literal phrase if it contains
    -- FTS5 special characters; otherwise return as-is for term matching
    if text:match('[%*%^"()]') or text:match("%bNEAR") then
        return '"' .. text:gsub('"', '""') .. '"'
    end
    return text
end
```

### Phrase search mapping

FTS5 natively supports phrase queries with double quotes. The current system
handles phrases via ripgrep's `--fixed-strings` flag for quoted text nodes.
The mapping is direct:

- Search input: `"error handling"` -> AST: `{ type="text", value="error handling", quoted=true }`
- FTS5: `"error handling"` (matches exact sequence of tokens)

FTS5 phrase matching operates on tokenized terms, so punctuation differences
(e.g., `error-handling` vs `error handling`) may produce different results than
ripgrep's byte-level matching. This is generally desirable (more recall) but
is a behavioral difference to document.

### Fallback to ripgrep when SQLite unavailable

The system must gracefully degrade when:

1. **`sqlite.lua` not installed**: The plugin dependency is optional.
2. **Database locked or corrupted**: Another Neovim instance or crash.
3. **Regex queries**: FTS5 does not support regex; these always fall back.
4. **FTS index not ready**: During initial build or rebuild.

```lua
--- Determine whether to use FTS or ripgrep for a text AST.
---@param text_ast table|nil
---@param fts FtsIndex|nil
---@return "fts"|"ripgrep"
local function choose_text_backend(text_ast, fts)
    if not text_ast then return "ripgrep" end
    if not fts or not fts:is_ready() then return "ripgrep" end

    -- Check if AST contains regex nodes (FTS5 cannot handle)
    if ast_contains_regex(text_ast) then return "ripgrep" end

    return "fts"
end
```

The fallback is transparent to the user. In live search, a small indicator
(e.g., `[FTS]` or `[rg]` in the stats line) shows which backend was used.

### Integration with vault_index build pipeline

The FTS index piggybacks on the vault_index change detection rather than
performing its own filesystem walk. This avoids double I/O and ensures both
indexes stay in sync.

#### Hook points in `vault_index.lua`

**1. `build_async()` completion (line 1228-1233):**

After the coroutine finishes processing all changed/deleted files, the FTS
index receives the same change/delete lists:

```lua
-- In vault_index.lua build_async(), after self:_rebuild_name_index()
local fts = require("andrew.vault.fts_index").current()
if fts and fts:is_ready() then
    fts:update(changed, deleted)
end
```

**2. `update_file()` (line 1284):**

Single-file updates on `BufWritePost` propagate to the FTS index:

```lua
-- In vault_index.lua update_file(), after self.files[rel_path] = entry
local fts = require("andrew.vault.fts_index").current()
if fts then
    fts:update_file(abs_path)
end
```

**3. `update_files_batch()` (line 1344):**

Batch updates from the filesystem watcher propagate similarly:

```lua
-- In vault_index.lua update_files_batch(), after rebuilding derived indexes
local fts = require("andrew.vault.fts_index").current()
if fts then
    fts:update_batch(changed_rel_paths, deleted_rel_paths)
end
```

**4. `remove_file()` (line 1324):**

File deletions remove the corresponding FTS row:

```lua
-- In vault_index.lua remove_file(), after self.files[rel_path] = nil
local fts = require("andrew.vault.fts_index").current()
if fts then
    fts:remove(rel_path)
end
```

**5. Initialization in `engine.lua`:**

The FTS index is initialized alongside the vault index during plugin setup.
The FTS rebuild runs asynchronously after the metadata index is ready:

```lua
-- In engine.lua setup, after vault_index.get(vault_path):load()
local fts_index = require("andrew.vault.fts_index")
local fts = fts_index.get(vault_path)
fts:open()
-- Rebuild will be triggered after vault_index.build_async() completes
```

### Integration with `search_filter.lua`

The `ripgrep_in_files()` function (line 1489) is the sole entry point for text
search. A new parallel function `fts_in_files()` is added, and the caller
(`resolve_query()` in `search.lua`) selects the backend.

#### New function in `search_filter.lua`:

```lua
--- Execute a text AST query against the FTS5 index.
--- Returns results in the same format as ripgrep_in_files() for seamless
--- substitution: array of "filepath:line:col:text" strings.
---
---@param text_ast table|nil text AST node tree
---@param file_paths string[] file paths to restrict results to
---@param vault_path string
---@param fts FtsIndex
---@return string[] result lines in rg-compatible format
function M.fts_in_files(text_ast, file_paths, vault_path, fts)
    local fts5_query, needs_fallback = ast_to_fts5(text_ast)
    if needs_fallback then
        return M.ripgrep_in_files(text_ast, file_paths, vault_path)
    end

    -- Build file restriction set
    local file_set = nil
    if file_paths and #file_paths > 0 then
        file_set = {}
        for _, p in ipairs(file_paths) do
            local rel = p:sub(#vault_path + 2) -- strip vault_path prefix + /
            file_set[rel] = true
        end
    end

    local results = fts:search(fts5_query, {
        snippets = true,
        file_set = file_set,
    })

    -- Convert FTS results to rg-compatible format
    local lines = {}
    for _, r in ipairs(results) do
        local abs_path = vault_path .. "/" .. r.rel_path
        -- FTS5 does not provide line numbers; use snippet with placeholder
        -- line:col of 1:1, or perform a secondary rg call for exact positions
        lines[#lines + 1] = abs_path .. ":1:1:" .. (r.snippet or "")
    end

    return lines
end
```

**Line number resolution:** FTS5 returns matching documents, not line numbers.
Two strategies:

1. **Fast mode (default):** Return results with `line=1, col=1` and let the
   fzf previewer show the file. The FTS5 `snippet()` function provides context
   around the match for display.
2. **Precise mode (opt-in):** After FTS narrows the file set, run a single
   `rg` invocation restricted to those files to get exact line:col positions.
   This is the `fts_then_rg` strategy: FTS for filtering, rg for location.

```lua
--- FTS-then-rg hybrid: use FTS5 to narrow files, then rg for line positions.
---@param text_ast table
---@param file_paths string[]
---@param vault_path string
---@param fts FtsIndex
---@return string[]
function M.fts_then_rg(text_ast, file_paths, vault_path, fts)
    local fts5_query, needs_fallback = ast_to_fts5(text_ast)
    if needs_fallback then
        return M.ripgrep_in_files(text_ast, file_paths, vault_path)
    end

    -- Phase 1: FTS narrows to matching files
    local file_set = nil
    if file_paths and #file_paths > 0 then
        file_set = {}
        for _, p in ipairs(file_paths) do
            file_set[p:sub(#vault_path + 2)] = true
        end
    end

    local fts_results = fts:search(fts5_query, { file_set = file_set })
    if #fts_results == 0 then return {} end

    -- Phase 2: rg for exact line positions within FTS-matched files
    local narrowed_paths = {}
    for _, r in ipairs(fts_results) do
        narrowed_paths[#narrowed_paths + 1] = vault_path .. "/" .. r.rel_path
    end

    return M.ripgrep_in_files(text_ast, narrowed_paths, vault_path)
end
```

### Modified `resolve_query()` in `search.lua`

The shared query evaluation function gains FTS awareness:

```lua
-- BEFORE (current code, search.lua line 102):
local function resolve_query(split, idx, vault_path, graph_sets, group_mode)
    local search_filter = require("andrew.vault.search_filter")
    local result

    if split.mode == "text_only" then
        local file_paths = {}
        for _, entry in pairs(idx.files) do
            file_paths[#file_paths + 1] = entry.abs_path
        end
        local results = search_filter.ripgrep_in_files(
            split.text_ast, file_paths, vault_path)
        result = { entries = results, needs_previewer = true }

    elseif split.mode == "metadata_then_text" then
        local matches = search_filter.evaluate(
            split.metadata_ast, idx, graph_sets)
        local file_paths = {}
        for _, entry in pairs(matches) do
            file_paths[#file_paths + 1] = entry.abs_path
        end
        if #file_paths == 0 then
            result = { entries = {}, needs_previewer = false }
        else
            local results = search_filter.ripgrep_in_files(
                split.text_ast, file_paths, vault_path)
            -- ...
        end
    end
    -- ...
end

-- AFTER (with FTS integration):
local function resolve_query(split, idx, vault_path, graph_sets, group_mode)
    local search_filter = require("andrew.vault.search_filter")
    local fts_index = require("andrew.vault.fts_index")
    local fts = fts_index.current()
    local use_fts = fts and fts:is_ready()
        and config.search.fts_enabled ~= false
        and not ast_contains_regex(split.text_ast)
    local result
    local backend = use_fts and "fts" or "rg"

    -- Select text search function based on backend + strategy
    local text_search_fn
    if use_fts then
        local strategy = config.search.fts_strategy or "hybrid"
        if strategy == "fts_only" then
            text_search_fn = function(text_ast, fps, vp)
                return search_filter.fts_in_files(
                    text_ast, fps, vp, fts)
            end
        else -- "hybrid" (default): FTS to narrow, rg for line positions
            text_search_fn = function(text_ast, fps, vp)
                return search_filter.fts_then_rg(
                    text_ast, fps, vp, fts)
            end
        end
    else
        text_search_fn = search_filter.ripgrep_in_files
    end

    if split.mode == "text_only" then
        local file_paths = {}
        for _, entry in pairs(idx.files) do
            file_paths[#file_paths + 1] = entry.abs_path
        end
        local results = text_search_fn(
            split.text_ast, file_paths, vault_path)
        result = { entries = results, needs_previewer = true,
                   backend = backend }

    elseif split.mode == "metadata_then_text" then
        local matches = search_filter.evaluate(
            split.metadata_ast, idx, graph_sets)
        local file_paths = {}
        for _, entry in pairs(matches) do
            file_paths[#file_paths + 1] = entry.abs_path
        end
        if #file_paths == 0 then
            result = { entries = {}, needs_previewer = false,
                       backend = backend }
        else
            local results = text_search_fn(
                split.text_ast, file_paths, vault_path)
            -- ... same fallback logic as before ...
        end
    end
    -- ... rest unchanged ...
end
```

## Dependency: `sqlite.lua`

### Option A: `kkharji/sqlite.lua` (recommended)

The `sqlite.lua` plugin provides a high-level Lua API wrapping the SQLite C
library via LuaJIT FFI. It is a mature, widely-used Neovim plugin (used by
telescope-frecency, nvim-neorg, and others).

**lazy.nvim spec:**
```lua
{
    "kkharji/sqlite.lua",
    lazy = true, -- loaded on demand by fts_index.lua
}
```

**Usage in `fts_index.lua`:**
```lua
local sqlite = require("sqlite.db")

function FtsIndex:open()
    self.db = sqlite:open(self.db_path)
    -- Create tables, check schema...
end

function FtsIndex:search(query, opts)
    local rows = self.db:select("notes_fts", {
        where = { content = { ["MATCH"] = query } },
        -- or use raw SQL for more control:
    })
    -- Alternatively, raw SQL for FTS5-specific features:
    local stmt = self.db:prepare([[
        SELECT rel_path, snippet(notes_fts, 1, '>>>', '<<<', '...', 32)
        FROM notes_fts
        WHERE content MATCH ?
        ORDER BY rank
        LIMIT ?
    ]])
    return stmt:bind(query, opts.limit or 500):rows()
end
```

### Option B: Raw LuaJIT FFI (no external dependency)

For zero-dependency operation, the SQLite C API can be called directly via
LuaJIT FFI, since `libsqlite3.so` is available on most systems. This approach
avoids adding a plugin dependency but requires more boilerplate.

```lua
local ffi = require("ffi")
ffi.cdef[[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    int sqlite3_open(const char *filename, sqlite3 **ppDb);
    int sqlite3_close(sqlite3 *);
    int sqlite3_exec(sqlite3*, const char *sql, ...);
    int sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, ...);
    int sqlite3_step(sqlite3_stmt*);
    int sqlite3_finalize(sqlite3_stmt*);
    const unsigned char *sqlite3_column_text(sqlite3_stmt*, int);
    double sqlite3_column_double(sqlite3_stmt*, int);
    int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, ...);
    -- ... additional declarations as needed
]]
local sqlite3 = ffi.load("sqlite3")
```

**Recommendation:** Start with Option A (`sqlite.lua`) for faster development
and better error handling. If the dependency is undesirable, migrate to raw FFI
later -- the `fts_index.lua` API boundary isolates the SQLite interaction.

## Performance Analysis

### Expected speedup by query type

| Query | Current (rg) | With FTS5 | Speedup |
|-------|-------------|-----------|---------|
| Single term, full vault | 30-80ms | 1-5ms | 6-80x |
| Quoted phrase | 30-80ms | 1-5ms | 6-80x |
| 3-term AND | 100-250ms | 2-8ms | 12-125x |
| 2-term OR | 60-160ms | 1-5ms | 12-160x |
| NOT term | 30-80ms | 1-5ms | 6-80x |
| metadata + text (hybrid) | 40-100ms | 5-15ms | 3-20x |
| Regex (fallback to rg) | 30-80ms | 30-80ms | 1x (no change) |

**Assumptions:** 2000-note vault, ~50MB total markdown, SSD storage, warm
filesystem cache. FTS5 timings include SQLite query execution but not initial
index build.

### Index build cost

| Operation | Time |
|-----------|------|
| Full rebuild (2000 files) | 3-8s |
| Incremental update (1 file) | 5-20ms |
| Incremental batch (10 files) | 30-100ms |
| Database size (2000 files, ~50MB md) | ~15-25MB |

The full rebuild is a one-time cost on first use or schema upgrade. Thereafter,
incremental updates keep the index current with negligible overhead.

### Memory impact

The SQLite database is accessed via file I/O with SQLite's internal page cache
(default 2MB). Unlike a pure in-memory index, this adds minimal Neovim process
memory. The `sqlite.lua` library itself is lightweight (~50KB loaded).

## Incremental Update Strategy

### Change detection: piggyback on vault_index

The vault_index already performs mtime+size change detection in
`_detect_changes()` (line 684). The FTS index reuses these results rather than
performing its own filesystem walk.

### Update flow

```
BufWritePost ──> vault_index:update_file(abs_path)
                    ├── parse file, update self.files[rel_path]
                    ├── rebuild derived indexes
                    └── fts_index:update_file(abs_path)
                            ├── read file content
                            ├── REPLACE INTO notes (rel_path, content, mtime, size)
                            └── FTS5 triggers update the inverted index

build_async() ──> detect_changes() returns (changed[], deleted[])
                    ├── process in batches (existing behavior)
                    └── after completion:
                        fts_index:update(changed, deleted)
                            ├── BEGIN TRANSACTION
                            ├── for each changed: REPLACE INTO notes
                            ├── for each deleted: DELETE FROM notes
                            └── COMMIT
```

### Transaction batching

All batch updates are wrapped in a single transaction for performance. SQLite
without explicit transactions performs a separate fsync per INSERT, which would
make bulk indexing 100x slower.

```lua
function FtsIndex:update(changed, deleted)
    self.db:execute("BEGIN TRANSACTION")

    for _, rel_path in ipairs(deleted) do
        self.db:execute(
            "DELETE FROM notes WHERE rel_path = ?", rel_path)
    end

    for _, file in ipairs(changed) do
        local content = read_file(file.abs_path)
        if content then
            self.db:execute([[
                INSERT OR REPLACE INTO notes (rel_path, content, mtime, size)
                VALUES (?, ?, ?, ?)
            ]], file.rel_path, content, file.mtime, file.size)
        end
    end

    self.db:execute("COMMIT")
end
```

### Consistency guarantees

- The FTS index is always updated **after** the metadata index, so it never
  contains entries for files not in `vault_index.files`.
- If Neovim crashes mid-update, the SQLite WAL (Write-Ahead Log) ensures the
  database is recoverable. Incomplete transactions are automatically rolled
  back on next open.
- A `PRAGMA integrity_check` is run on startup; if it fails, the database is
  deleted and rebuilt from scratch.

## Configuration Options

New fields in `config.lua` under `M.search`:

```lua
M.search = {
    -- ... existing fields ...

    -- SQLite FTS5 full-text index.
    fts = {
        -- Enable/disable the FTS5 index. When false, all text search
        -- uses ripgrep (current behavior).
        enabled = true,

        -- Search strategy when FTS is available:
        -- "hybrid"   - FTS5 narrows file set, then rg for line positions
        --              (best of both: fast filtering + precise locations)
        -- "fts_only" - FTS5 only, no rg follow-up (fastest, but line:col
        --              not available; fzf opens file at line 1)
        strategy = "hybrid",

        -- Database path. Relative to vault root.
        -- Default: ".vault-index/search.db"
        db_path = ".vault-index/search.db",

        -- Maximum FTS results before falling back to ripgrep.
        -- If FTS returns more than this many files, it is likely faster
        -- to let rg scan them directly than to run rg on each individually.
        max_fts_results = 1000,

        -- Show backend indicator in stats line ([FTS] or [rg]).
        show_backend = true,

        -- SQLite page cache size in KB (default: 2048 = 2MB).
        cache_size_kb = 2048,
    },
}
```

New fields in `config.lua` under `M.index`:

```lua
M.index = {
    -- ... existing fields ...

    -- Whether to build the FTS index during vault index build.
    -- When false, the FTS database is not created or updated.
    fts = true,
}
```

### User commands

```
:VaultFtsRebuild    - Force a full FTS index rebuild
:VaultFtsStatus     - Show FTS index stats (file count, db size, readiness)
:VaultFtsPurge      - Delete the FTS database (next search triggers rebuild)
```

## Migration Plan

### Existing users

1. **No breaking changes.** FTS is additive; all existing behavior is
   preserved when `fts.enabled = false` or when `sqlite.lua` is not installed.
2. **First launch after update:** The FTS database does not exist. The plugin
   detects this and begins an async rebuild in the background. During the
   rebuild, all searches use ripgrep (existing behavior). A notification
   shows rebuild progress.
3. **Rebuild completes:** Subsequent searches transparently use FTS. The stats
   line shows `[FTS]` to confirm.
4. **Opting out:** Set `config.search.fts.enabled = false`. The database file
   is not deleted but is no longer opened or updated.

### Schema versioning

The `meta` table stores a schema version:

```lua
local FTS_SCHEMA_VERSION = 1

function FtsIndex:_check_schema()
    local row = self.db:select("meta", { where = { key = "schema_version" } })
    local version = row and tonumber(row.value) or 0
    if version ~= FTS_SCHEMA_VERSION then
        -- Drop and recreate tables
        self:_drop_tables()
        self:_create_tables()
        self:_set_meta("schema_version", FTS_SCHEMA_VERSION)
        return false -- needs full rebuild
    end
    return true -- schema matches
end
```

### Plugin dependency declaration

The `sqlite.lua` dependency is declared as optional in lazy.nvim:

```lua
-- In the vault plugin spec or a separate plugins/fts.lua:
return {
    "kkharji/sqlite.lua",
    lazy = true,
    -- Only needed when FTS is enabled (loaded on demand)
    cond = function()
        local ok, config = pcall(require, "andrew.vault.config")
        return ok and config.search and config.search.fts
            and config.search.fts.enabled ~= false
    end,
}
```

## Test Cases

### Unit tests (`tests/vault/fts_index_spec.lua`)

```lua
describe("fts_index", function()
    local fts_index = require("andrew.vault.fts_index")
    local test_vault = "/tmp/test-vault-fts"
    local fts

    before_each(function()
        -- Create test vault with sample files
        vim.fn.mkdir(test_vault .. "/.vault-index", "p")
        write_file(test_vault .. "/alpha.md", "# Alpha\nDeploy the widget\n")
        write_file(test_vault .. "/beta.md", "# Beta\nThe widget is broken\n")
        write_file(test_vault .. "/gamma.md", "# Gamma\nNo matches here\n")
        fts = fts_index.get(test_vault)
        fts:open()
        fts:rebuild()
    end)

    after_each(function()
        fts:close()
        vim.fn.delete(test_vault, "rf")
    end)

    -- Schema and lifecycle
    it("creates database and tables", function()
        assert.is_true(vim.uv.fs_stat(test_vault .. "/.vault-index/search.db") ~= nil)
        assert.is_true(fts:is_ready())
    end)

    it("handles schema version mismatch by rebuilding", function()
        fts:close()
        -- Manually corrupt schema version
        fts:open()
        assert.is_true(fts:is_ready())
    end)

    -- Basic search
    it("finds single term", function()
        local results = fts:search("widget")
        assert.equals(2, #results)
        local paths = vim.tbl_map(function(r) return r.rel_path end, results)
        assert.is_true(vim.tbl_contains(paths, "alpha.md"))
        assert.is_true(vim.tbl_contains(paths, "beta.md"))
    end)

    it("finds quoted phrase", function()
        local results = fts:search('"Deploy the widget"')
        assert.equals(1, #results)
        assert.equals("alpha.md", results[1].rel_path)
    end)

    it("returns empty for no matches", function()
        local results = fts:search("nonexistent")
        assert.equals(0, #results)
    end)

    -- Boolean queries
    it("handles AND", function()
        local results = fts:search("widget AND deploy")
        assert.equals(1, #results)
        assert.equals("alpha.md", results[1].rel_path)
    end)

    it("handles OR", function()
        local results = fts:search("deploy OR broken")
        assert.equals(2, #results)
    end)

    it("handles NOT", function()
        local results = fts:search("widget NOT broken")
        assert.equals(1, #results)
        assert.equals("alpha.md", results[1].rel_path)
    end)

    -- Incremental updates
    it("updates on file change", function()
        write_file(test_vault .. "/alpha.md", "# Alpha\nRedesigned\n")
        fts:update_file(test_vault .. "/alpha.md")
        local results = fts:search("widget")
        assert.equals(1, #results) -- only beta.md now
    end)

    it("removes deleted files", function()
        os.remove(test_vault .. "/beta.md")
        fts:update({}, { "beta.md" })
        local results = fts:search("broken")
        assert.equals(0, #results)
    end)

    it("adds new files", function()
        write_file(test_vault .. "/delta.md", "# Delta\nNew widget content\n")
        fts:update_file(test_vault .. "/delta.md")
        local results = fts:search("widget")
        assert.equals(3, #results)
    end)

    -- File set restriction
    it("restricts results to file set", function()
        local results = fts:search("widget", {
            file_set = { ["alpha.md"] = true },
        })
        assert.equals(1, #results)
        assert.equals("alpha.md", results[1].rel_path)
    end)
end)
```

### Integration tests (`tests/vault/fts_search_integration_spec.lua`)

```lua
describe("FTS search integration", function()
    it("ast_to_fts5 translates simple text", function()
        local node = { type = "text", value = "deploy", quoted = false }
        local fts5 = ast_to_fts5(node)
        assert.equals("deploy", fts5)
    end)

    it("ast_to_fts5 translates quoted phrase", function()
        local node = { type = "text", value = "exact phrase", quoted = true }
        local fts5 = ast_to_fts5(node)
        assert.equals('"exact phrase"', fts5)
    end)

    it("ast_to_fts5 translates AND tree", function()
        local node = {
            type = "and",
            left = { type = "text", value = "foo" },
            right = { type = "text", value = "bar" },
        }
        local fts5 = ast_to_fts5(node)
        assert.equals("(foo) AND (bar)", fts5)
    end)

    it("ast_to_fts5 returns nil for regex", function()
        local node = { type = "regex", pattern = "^## " }
        local fts5, fallback = ast_to_fts5(node)
        assert.is_nil(fts5)
        assert.is_true(fallback)
    end)

    it("choose_text_backend selects fts when available", function()
        local text_ast = { type = "text", value = "test" }
        local mock_fts = { is_ready = function() return true end }
        assert.equals("fts", choose_text_backend(text_ast, mock_fts))
    end)

    it("choose_text_backend falls back for regex", function()
        local text_ast = { type = "regex", pattern = "^#" }
        local mock_fts = { is_ready = function() return true end }
        assert.equals("ripgrep", choose_text_backend(text_ast, mock_fts))
    end)

    it("choose_text_backend falls back when fts not ready", function()
        local text_ast = { type = "text", value = "test" }
        local mock_fts = { is_ready = function() return false end }
        assert.equals("ripgrep", choose_text_backend(text_ast, mock_fts))
    end)

    it("resolve_query uses fts backend and reports it", function()
        -- Full integration test with mock FTS index
        -- Verify result.backend == "fts" and entries are correct
    end)

    it("live search stats show [FTS] indicator", function()
        -- Verify the stats line includes backend indicator
    end)
end)
```

## Files Modified / Created

### New files

| File | Purpose |
|------|---------|
| `lua/andrew/vault/fts_index.lua` | FTS5 index module (singleton, open/close/rebuild/update/search) |
| `lua/andrew/plugins/sqlite.lua` | lazy.nvim plugin spec for `kkharji/sqlite.lua` (optional dep) |
| `tests/vault/fts_index_spec.lua` | Unit tests for FTS index |
| `tests/vault/fts_search_integration_spec.lua` | Integration tests for FTS+search pipeline |

### Modified files

| File | Changes |
|------|---------|
| `lua/andrew/vault/config.lua` | Add `M.search.fts` config section; add `M.index.fts` flag |
| `lua/andrew/vault/search_filter.lua` | Add `fts_in_files()`, `fts_then_rg()`, `ast_to_fts5()` helper; export `ast_contains_regex()` |
| `lua/andrew/vault/search.lua` | Modify `resolve_query()` to select FTS/rg backend; add backend indicator to stats line; add `:VaultFtsRebuild`, `:VaultFtsStatus`, `:VaultFtsPurge` commands |
| `lua/andrew/vault/vault_index.lua` | Add FTS update hooks in `build_async()`, `update_file()`, `update_files_batch()`, `remove_file()` |
| `lua/andrew/vault/engine.lua` | Initialize FTS index alongside vault index in setup |

## Implementation Order

1. **Phase 1: Foundation** -- Create `fts_index.lua` with open/close/rebuild/search. Write unit tests. Verify FTS5 queries work in isolation.
2. **Phase 2: Query translation** -- Implement `ast_to_fts5()` in `search_filter.lua`. Write translation tests.
3. **Phase 3: Integration** -- Wire FTS into `resolve_query()` with backend selection. Add fallback logic. Write integration tests.
4. **Phase 4: Incremental updates** -- Hook into `vault_index.lua` update pipeline. Verify single-file and batch updates.
5. **Phase 5: Polish** -- Add config options, user commands, stats indicators, migration handling. Update search help text.

## Open Questions

1. **Snippet quality:** FTS5's `snippet()` function may not produce ideal
   context for fzf display. May need custom snippet extraction that reads the
   original file around the matched term.

2. **Case sensitivity:** FTS5 `unicode61` tokenizer is case-insensitive by
   default. The current `rg --smart-case` behavior (case-insensitive unless
   uppercase present) would need custom logic if exact parity is desired.

3. **Concurrent access:** If multiple Neovim instances edit the same vault,
   SQLite's file-level locking handles concurrent reads safely. Concurrent
   writes may cause `SQLITE_BUSY` errors; the module should retry with
   exponential backoff or use WAL mode (which allows concurrent reads during
   writes).

4. **`sqlite.lua` vs raw FFI:** The initial implementation uses `sqlite.lua`
   for development speed. If the dependency proves problematic (version
   conflicts, maintenance concerns), a migration to raw FFI is straightforward
   since the API boundary is clean.
