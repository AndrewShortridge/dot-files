# Feature 17: Vault File Enumeration and `fd`/`fdfind` Detection Consolidation

## Dependencies
- **Feature 03** (engine.is_vault_path / vault_relative) — path utilities
- **Depended on by:** Nothing directly, but improves consistency of file caching

## Problem

### 17a: Four independent vault file enumeration/caching systems
Each module independently scans the vault for `.md` files using a different strategy:

| Module | Strategy | Cache Type | Invalidation |
|---|---|---|---|
| `wikilinks.lua:54-83` | `vim.fs.find()` | basename → path array, alias support | `BufWritePost` autocmd |
| `linkcheck.lua:6-47` | `fd`/`fdfind`/`find` subprocess | basename → boolean set + path map | `BufWritePost` + `BufDelete` |
| `linkdiag.lua:6,31-50` | `vim.fn.globpath()` | basename → boolean set + path map, TTL 10s | TTL + `BufWritePost`/`BufDelete` |
| `query/index.lua:221-244` | `vim.uv.fs_scandir` recursive | Full page index with frontmatter | TTL (30s via config) |
| `completion.lua:124-214` | `fd`/`fdfind`/`find` subprocess | Completion items array | `BufWritePost` autocmd |
| `completion_frontmatter.lua:56-65` | `fd`/`fdfind`/`find` subprocess | Property name/value items | `BufWritePost` autocmd |

### 17b: `fd`/`fdfind` binary detection repeated 4 times
The same detection block appears in:
- `completion.lua:130-139`
- `completion_frontmatter.lua:56-65`
- `linkcheck.lua:23-26`
- `linkcheck.lua:313-316` (duplicate within same file!)

```lua
local fd_bin = vim.fn.executable("fd") == 1 and "fd"
  or vim.fn.executable("fdfind") == 1 and "fdfind"
  or nil
```

## Strategy

**Don't try to unify all caches into one** — each module needs different data structures (wikilinks needs alias maps, completion needs items, query needs full page data). Instead:

1. **Centralize `fd`/`fdfind` detection** into engine.lua (single detection, cached result)
2. **Centralize the "list all vault .md files" command construction** into engine.lua
3. **Let linkcheck.lua and linkdiag.lua share a single name cache** since they build identical data structures
4. **Leave wikilinks.lua, query/index.lua, and completion caches alone** — they have fundamentally different requirements

## Files to Modify
1. `lua/andrew/vault/engine.lua` — Add `M.fd_bin()`, `M.find_md_cmd(base_dir)`, `M.list_md_files(base_dir, callback)`
2. `lua/andrew/vault/linkcheck.lua` — Use engine helpers, share cache with linkdiag
3. `lua/andrew/vault/linkdiag.lua` — Use engine helpers, share cache with linkcheck
4. `lua/andrew/vault/completion.lua` — Use `engine.find_md_cmd()` (if Feature 11 not done yet)
5. `lua/andrew/vault/completion_frontmatter.lua` — Use `engine.find_md_cmd()`

## Implementation Steps

### Step 1: Add file enumeration helpers to engine.lua

```lua
-- Cache the fd binary detection result (checked once per session)
local _fd_bin = nil
local _fd_checked = false

--- Detect the best available file-finder binary.
--- @return string|nil  "fd", "fdfind", or nil
function M.fd_bin()
  if not _fd_checked then
    _fd_checked = true
    if vim.fn.executable("fd") == 1 then
      _fd_bin = "fd"
    elseif vim.fn.executable("fdfind") == 1 then
      _fd_bin = "fdfind"
    end
  end
  return _fd_bin
end

--- Build a command to find all .md files in a directory.
--- @param base_dir? string  Directory to search (default: vault_path)
--- @return string[], boolean  cmd, use_fd
function M.find_md_cmd(base_dir)
  base_dir = base_dir or M.vault_path
  local fd = M.fd_bin()
  if fd then
    return { fd, "--type", "f", "--extension", "md", "--base-directory", base_dir }, true
  else
    return { "find", base_dir, "-type", "f", "-name", "*.md" }, false
  end
end

--- Asynchronously list all .md files in the vault.
--- Calls callback with an array of { rel: string, abs: string } entries.
--- @param callback fun(files: { rel: string, abs: string }[])
--- @param base_dir? string
function M.list_md_files_async(callback, base_dir)
  base_dir = base_dir or M.vault_path
  local cmd, use_fd = M.find_md_cmd(base_dir)
  vim.system(cmd, { text = true }, function(result)
    local files = {}
    if result.code == 0 and result.stdout and result.stdout ~= "" then
      for line in result.stdout:gmatch("[^\n]+") do
        local rel = line
        local abs = line
        if use_fd then
          abs = base_dir .. "/" .. line
        else
          rel = line:sub(#base_dir + 2)
        end
        files[#files + 1] = { rel = rel, abs = abs }
      end
    end
    callback(files)
  end)
end
```

### Step 2: Create shared name cache for linkcheck + linkdiag

Create a shared cache module or add to engine.lua:

```lua
--- Shared vault note name cache for link validation.
--- Used by linkcheck.lua and linkdiag.lua.
local _name_cache = nil
local _name_cache_vault = nil
local _name_cache_ts = 0
local NAME_CACHE_TTL = 10 -- seconds

--- Get or build the vault note name cache.
--- @return { names: table<string, boolean>, paths: table<string, string> }
function M.get_name_cache()
  local now = vim.uv.now() / 1000
  if _name_cache and _name_cache_vault == M.vault_path and (now - _name_cache_ts) < NAME_CACHE_TTL then
    return _name_cache
  end

  local names = {} -- lowercase basename → true
  local paths = {} -- lowercase basename → first absolute path found
  local cmd, use_fd = M.find_md_cmd()
  local result = vim.system(cmd, { text = true }):wait()

  if result.code == 0 and result.stdout then
    for line in result.stdout:gmatch("[^\n]+") do
      local abs = use_fd and (M.vault_path .. "/" .. line) or line
      local basename = vim.fn.fnamemodify(abs, ":t:r"):lower()
      names[basename] = true
      if not paths[basename] then
        paths[basename] = abs
      end
    end
  end

  _name_cache = { names = names, paths = paths }
  _name_cache_vault = M.vault_path
  _name_cache_ts = now
  return _name_cache
end

--- Invalidate the shared name cache.
function M.invalidate_name_cache()
  _name_cache_ts = 0
end
```

### Step 3: Update linkcheck.lua

Delete the local `get_name_cache` function and its associated state variables (lines 6-47).
Delete the duplicate `fd`/`fdfind` detection in `check_orphans` (lines 313-316).

```lua
-- Before:
local ok = _name_cache[link_name:lower()]

-- After:
local cache = engine.get_name_cache()
local ok = cache.names[link_name:lower()]
```

For `check_orphans`, replace the independent file listing with:
```lua
local cache = engine.get_name_cache()
-- iterate cache.paths for orphan detection
```

Remove the `BufWritePost`/`BufDelete` autocmd that invalidates the local cache — the shared cache uses TTL. Or add:
```lua
vim.api.nvim_create_autocmd({ "BufWritePost", "BufDelete" }, {
  pattern = "*.md",
  callback = engine.invalidate_name_cache,
})
```

### Step 4: Update linkdiag.lua

Delete `M._cache` and `M.build_cache` (lines 6, 31-50). Replace with:

```lua
-- Before:
local cache = M.build_cache()
local exists = cache.names[name:lower()]

-- After:
local cache = engine.get_name_cache()
local exists = cache.names[name:lower()]
```

Remove the local `BufWritePost`/`BufDelete` autocmd — shared cache handles it.

### Step 5: Update completion.lua and completion_frontmatter.lua

Replace the `fd`/`fdfind` detection block with:

```lua
local cmd, use_fd = engine.find_md_cmd()
```

If Feature 11 (completion base factory) is already implemented, this is handled by `base.find_md_cmd()` which should itself delegate to `engine.find_md_cmd()`.

### Step 6: Deduplicate fd detection within linkcheck.lua

The `check_orphans` function (line 313-316) has its own copy of the `fd`/`fdfind` detection. After Step 3, this is eliminated since orphan checking uses `engine.get_name_cache()`.

## What NOT to Change
- **wikilinks.lua** cache — it adds alias support and proximity disambiguation. These are unique to wikilinks and should stay separate. It could optionally *consume* the shared name cache as a base, but that's a deeper refactor.
- **query/index.lua** — it builds a comprehensive page index with full frontmatter, tags, links, and tasks. This is fundamentally different from a simple name lookup and should stay independent.
- **completion.lua** item building — it needs file metadata (mtime, frontmatter) per file for completion items. The shared cache provides only names/paths. The `find_md_cmd` sharing is sufficient.

## Testing
- `VaultLinkCheck` on current buffer — detects broken links correctly
- `VaultLinkCheckAll` — scans entire vault for broken links
- `VaultOrphans` — finds notes with no backlinks
- `VaultLinkDiag` — real-time diagnostics show broken links
- `VaultLinkDiagToggle` — enable/disable works
- After creating a new note, within 10 seconds the name cache refreshes and the new note resolves
- Wikilink completion still works (regression check)
- After a save, diagnostics update (invalidation works)

## Estimated Impact
- **Lines removed:** ~60 (two separate name caches + 4 fd detection blocks)
- **Lines added:** ~40 (shared cache + helpers in engine)
- **Net reduction:** ~20 lines
- **Bonus:** linkcheck and linkdiag now share a single cached file scan instead of each doing their own
- **Bonus:** fd binary detection runs once per session, not on every cache rebuild
