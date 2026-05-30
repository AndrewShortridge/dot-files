# 42 - Prevent Symlink Loops in Vault Index

**Priority:** High -- data integrity / reliability (can cause Neovim hang)
**Status:** Planned
**Files:** `lua/andrew/vault/vault_index.lua`

## Summary

`vault_index.lua` has two recursive directory walking functions -- `_walk()` and
the inner `walk()` inside `_detect_changes()` -- that recurse into every
subdirectory without tracking which directories have already been visited.
Cyclic symlinks cause infinite recursion, eventually exhausting the Lua call
stack or spinning indefinitely in the coroutine-based async build path,
effectively hanging Neovim.

This document proposes tracking visited directories by device+inode identity so
that cycles are detected and skipped on the first re-encounter, with a warning
logged for the user.

## Problem Statement

### Scenario

```
vault/
  notes/
    projects/
      alpha/       <-- real directory
      beta -> ../  <-- symlink pointing to notes/ (the parent)
```

When `_walk()` enters `notes/projects/beta`, it resolves to `notes/`. From
there it re-enters `notes/projects/`, then `notes/projects/beta` again, and the
cycle repeats forever.

Longer cycles are equally dangerous:

```
vault/
  A/ -> /home/user/vault/B
  B/ -> /home/user/vault/C
  C/ -> /home/user/vault/A
```

The walk enters A -> B -> C -> A -> B -> ... without bound.

### Consequence

- **Synchronous build** (`build_sync`): Lua stack overflow or frozen editor
  until the `E5108: Error executing lua` limit is hit.
- **Async build** (`build_async` via coroutine + `_detect_changes`): The
  coroutine never yields back, so the timer callback that drives it starves the
  event loop. Neovim appears hung -- no user input is processed until the stack
  overflows.

### How It Can Happen in Practice

Users often symlink reference material, shared team vaults, or archive
directories into their vault. A single misplaced `ln -s .. archive` inside a
subdirectory creates a cycle. Version control tools and sync engines
(Syncthing, Dropbox) can also create symlinks during conflict resolution.

## Current Code Analysis

### `_walk()` (line 685)

```lua
function M.VaultIndex:_walk(abs_dir, rel_dir)
  local handle = vim.uv.fs_scandir(abs_dir)
  if not handle then return end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then break end

    local abs_path = abs_dir .. "/" .. name
    local rel_path = (rel_dir == "") and name or (rel_dir .. "/" .. name)

    if ftype == "directory" then
      if not SKIP_DIRS[name] then
        self:_walk(abs_path, rel_path)
      end
    elseif ftype == "file" and name:match("%.md$") then
      local stat = vim.uv.fs_stat(abs_path)
      if stat then
        local entry = self:_parse_file(abs_path, rel_path, stat)
        if entry then
          self.files[rel_path] = entry
        end
      end
    end
  end
end
```

### `walk()` inside `_detect_changes()` (line 721)

```lua
local function walk(abs_dir, rel_dir)
  local handle = vim.uv.fs_scandir(abs_dir)
  if not handle then return end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then break end

    local abs_path = abs_dir .. "/" .. name
    local rel_path = (rel_dir == "") and name or (rel_dir .. "/" .. name)

    if ftype == "directory" then
      if not SKIP_DIRS[name] then
        walk(abs_path, rel_path)
      end
    elseif ftype == "file" and name:match("%.md$") then
      seen[rel_path] = true
      local stat = vim.uv.fs_stat(abs_path)
      if stat then
        local entry = self.files[rel_path]
        if not entry
          or entry.mtime ~= stat.mtime.sec
          or entry.size ~= stat.size
        then
          changed[#changed + 1] = { rel_path = rel_path, abs_path = abs_path, stat = stat }
        end
      end
    end
  end
end
```

### Why It Is Vulnerable

1. **No visited-directory tracking.** Neither function maintains a set of
   already-visited directories.
2. **`SKIP_DIRS` is name-based, not identity-based.** It only matches exact
   directory basenames (e.g., `.git`, `node_modules`). A symlink named
   `archive` pointing back to the vault root would not match.
3. **`vim.uv.fs_scandir_next` follows symlinks.** When it encounters a symlink
   to a directory, it reports `ftype = "directory"`, not `"link"`. The walk
   treats it as a real directory and recurses into it. (By contrast,
   `fs_scandir_next` only reports `"link"` when the symlink target is not a
   directory -- i.e., symlinks to files appear as `"link"` rather than
   `"file"`. But the critical case for cycles is symlinks to directories, and
   those appear as `"directory"`.)
4. **Path-string comparison would not help.** A symlink's path
   (`vault/notes/projects/beta`) differs from its target path (`vault/notes/`),
   so naive string deduplication fails.

## Proposed Solution: Device+Inode Visited Set

### Core Idea

Before recursing into any directory, call `vim.uv.fs_lstat()` to obtain the
filesystem identity of the target (device number + inode number). Maintain a
set of `"dev:ino"` strings. If the identity is already in the set, skip the
directory and log a warning. Otherwise add it and proceed.

Using `fs_lstat()` on the path after symlink resolution (or equivalently,
`fs_stat()` since we want the target identity) gives us the real directory's
inode regardless of how we reached it. This catches:

- Direct cycles (A -> A)
- Indirect cycles (A -> B -> C -> A)
- Multiple symlinks converging on the same directory (deduplication, a bonus)

**Note on lstat vs stat:** `vim.uv.fs_lstat()` returns the symlink's own
inode, not the target's. For cycle detection we actually want the **target
directory's** identity, so we should use `vim.uv.fs_stat()` on the directory
path. Since `fs_scandir_next` already resolves symlinks (reporting them as
`"directory"`), the `abs_path` we have in hand points through the symlink, and
`fs_stat(abs_path)` gives us the real directory's inode. We will use
`fs_stat()` for this reason.

### Implementation Detail

```lua
--- Return a string key uniquely identifying a directory on the filesystem.
--- Uses device + inode to detect cycles through symlinks.
---@param abs_path string
---@return string|nil  "dev:ino" or nil if stat fails
local function dir_identity(abs_path)
  local stat = vim.uv.fs_stat(abs_path)
  if not stat then return nil end
  return stat.dev .. ":" .. stat.ino
end
```

Both `_walk()` and the `walk()` closure inside `_detect_changes()` accept an
additional `visited` parameter (a table used as a set). The vault root itself
is added to the set before the first call.

## Alternative Approaches Considered

### 1. Maximum Depth Limit

Add a `depth` counter that increments on each recursive call; bail out when it
exceeds a threshold (e.g., 50).

**Pros:**
- Trivial to implement (one integer comparison per call).
- No syscall overhead.

**Cons:**
- Does not actually detect cycles -- it merely limits damage.
- Legitimate deep directory trees (> 50 levels) would be silently truncated.
- Choosing the right limit is guesswork; too low clips real vaults, too high
  still allows thousands of redundant iterations before triggering.
- Gives no diagnostic information about where the cycle is.

**Verdict:** Useful as a secondary safety net, but insufficient as the primary
defense.

### 2. Path Prefix Detection

Track every absolute path entered so far. Before recursing, resolve the
canonical path (`vim.uv.fs_realpath()`) and check whether it is a prefix of, or
equal to, any ancestor path.

**Pros:**
- Purely string-based, no inode knowledge needed.

**Cons:**
- `fs_realpath()` is itself a syscall -- same overhead as `fs_stat()`.
- Prefix checking is O(depth) per directory rather than O(1) hash lookup.
- Canonical path resolution can fail on broken symlinks.
- Two distinct filesystem mount points can share path prefixes without being
  related (rare, but possible with bind mounts).

**Verdict:** Workable but strictly inferior to inode-based detection in both
correctness and performance.

### 3. Tracking Canonical Paths in a Set (fs_realpath)

Resolve every directory to its canonical path via `vim.uv.fs_realpath()` and
store in a visited set, similar to the inode approach but using path strings.

**Pros:**
- Avoids the inode portability question on Windows.
- O(1) lookup per directory.

**Cons:**
- `fs_realpath()` can fail on broken symlinks or permission errors.
- On case-insensitive filesystems (macOS default), two different path strings
  may refer to the same directory, defeating deduplication.
- Still one syscall per directory, same as fs_stat.

**Verdict:** Reasonable fallback for Windows; inode-based is more robust on
Unix.

## Detailed Code Changes

### Before: `_walk()`

```lua
function M.VaultIndex:_walk(abs_dir, rel_dir)
  local handle = vim.uv.fs_scandir(abs_dir)
  if not handle then return end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then break end

    local abs_path = abs_dir .. "/" .. name
    local rel_path = (rel_dir == "") and name or (rel_dir .. "/" .. name)

    if ftype == "directory" then
      if not SKIP_DIRS[name] then
        self:_walk(abs_path, rel_path)
      end
    elseif ftype == "file" and name:match("%.md$") then
      local stat = vim.uv.fs_stat(abs_path)
      if stat then
        local entry = self:_parse_file(abs_path, rel_path, stat)
        if entry then
          self.files[rel_path] = entry
        end
      end
    end
  end
end
```

### After: `_walk()`

```lua
--- Return a string key uniquely identifying a filesystem object.
---@param abs_path string
---@return string|nil  "dev:ino" or nil on stat failure
local function dir_identity(abs_path)
  local stat = vim.uv.fs_stat(abs_path)
  if not stat then return nil end
  return stat.dev .. ":" .. stat.ino
end

function M.VaultIndex:_walk(abs_dir, rel_dir, visited)
  -- Initialize visited set on first call, seeding with the root directory.
  if not visited then
    visited = {}
    local root_id = dir_identity(abs_dir)
    if root_id then visited[root_id] = abs_dir end
  end

  local handle = vim.uv.fs_scandir(abs_dir)
  if not handle then return end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then break end

    local abs_path = abs_dir .. "/" .. name
    local rel_path = (rel_dir == "") and name or (rel_dir .. "/" .. name)

    if ftype == "directory" then
      if not SKIP_DIRS[name] then
        local id = dir_identity(abs_path)
        if id then
          if visited[id] then
            vim.schedule(function()
              vim.notify(
                string.format(
                  "Vault index: skipping cyclic symlink %s (same as %s)",
                  rel_path, visited[id]
                ),
                vim.log.levels.WARN
              )
            end)
          else
            visited[id] = rel_path
            self:_walk(abs_path, rel_path, visited)
          end
        end
        -- id == nil means fs_stat failed (broken symlink or permission error);
        -- silently skip the directory.
      end
    elseif ftype == "file" and name:match("%.md$") then
      local stat = vim.uv.fs_stat(abs_path)
      if stat then
        local entry = self:_parse_file(abs_path, rel_path, stat)
        if entry then
          self.files[rel_path] = entry
        end
      end
    end
  end
end
```

### Before: `walk()` inside `_detect_changes()`

```lua
local function walk(abs_dir, rel_dir)
  local handle = vim.uv.fs_scandir(abs_dir)
  if not handle then return end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then break end

    local abs_path = abs_dir .. "/" .. name
    local rel_path = (rel_dir == "") and name or (rel_dir .. "/" .. name)

    if ftype == "directory" then
      if not SKIP_DIRS[name] then
        walk(abs_path, rel_path)
      end
    elseif ftype == "file" and name:match("%.md$") then
      seen[rel_path] = true
      local stat = vim.uv.fs_stat(abs_path)
      if stat then
        local entry = self.files[rel_path]
        if not entry
          or entry.mtime ~= stat.mtime.sec
          or entry.size ~= stat.size
        then
          changed[#changed + 1] = { rel_path = rel_path, abs_path = abs_path, stat = stat }
        end
      end
    end
  end
end

walk(self.vault_path, "")
```

### After: `walk()` inside `_detect_changes()`

```lua
local visited = {}
local root_id = dir_identity(self.vault_path)
if root_id then visited[root_id] = self.vault_path end

local function walk(abs_dir, rel_dir)
  local handle = vim.uv.fs_scandir(abs_dir)
  if not handle then return end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then break end

    local abs_path = abs_dir .. "/" .. name
    local rel_path = (rel_dir == "") and name or (rel_dir .. "/" .. name)

    if ftype == "directory" then
      if not SKIP_DIRS[name] then
        local id = dir_identity(abs_path)
        if id then
          if visited[id] then
            vim.schedule(function()
              vim.notify(
                string.format(
                  "Vault index: skipping cyclic symlink %s (same as %s)",
                  rel_path, visited[id]
                ),
                vim.log.levels.WARN
              )
            end)
          else
            visited[id] = rel_path
            walk(abs_path, rel_path)
          end
        end
      end
    elseif ftype == "file" and name:match("%.md$") then
      seen[rel_path] = true
      local stat = vim.uv.fs_stat(abs_path)
      if stat then
        local entry = self.files[rel_path]
        if not entry
          or entry.mtime ~= stat.mtime.sec
          or entry.size ~= stat.size
        then
          changed[#changed + 1] = { rel_path = rel_path, abs_path = abs_path, stat = stat }
        end
      end
    end
  end
end

walk(self.vault_path, "")
```

### Caller Change: `build_sync()`

No change needed. `_walk()` initializes its own `visited` set on the first
call when the parameter is nil.

### Optional: Extract Shared Walk Logic

Both walk functions share nearly identical cycle-detection logic. A further
refactoring could extract a shared `walk_vault(root, visitor_fn, visited)` that
handles scanning, SKIP_DIRS, and cycle detection, calling the `visitor_fn` for
each file entry. This is out of scope for this improvement but noted as a
future cleanup.

## Performance Impact Analysis

### Overhead Per Directory

The change adds one `vim.uv.fs_stat()` call per directory encountered during
the walk. This is a synchronous libuv stat syscall.

| Operation | Typical latency | Notes |
|-----------|-----------------|-------|
| `fs_stat` on local SSD | 1-5 us | Hot dentry cache |
| `fs_stat` on HDD | 50-200 us | Cold cache, seek time |
| `fs_stat` on NFS | 0.5-5 ms | Network round trip |
| Hash table insert/lookup | ~100 ns | Lua table, amortized |

### Vault Scale Estimates

| Vault size | Estimated dirs | Added stat time (SSD) | Added stat time (NFS) |
|------------|-----------------|----------------------|----------------------|
| Small (100 files) | ~20 dirs | ~0.1 ms | ~10 ms |
| Medium (1,000 files) | ~100 dirs | ~0.5 ms | ~100 ms |
| Large (10,000 files) | ~500 dirs | ~2.5 ms | ~500 ms |

The existing walk already calls `fs_stat()` once per `.md` file (to get mtime
and size), so the new per-directory stat is a modest addition -- typically 5-10%
more stat calls than already exist.

For the common case of local SSDs, the overhead is negligible (sub-millisecond
for most vaults). For network filesystems the cost is higher but still
proportional to the number of directories, which is typically much smaller than
the number of files.

### Memory Overhead

The `visited` table stores one `"dev:ino"` string (~15-20 bytes) plus its
associated `rel_path` string per directory. For 500 directories, this is
roughly 10-20 KB -- negligible.

## Platform Considerations

### Linux

Full support. Device numbers (`stat.dev`) and inode numbers (`stat.ino`) are
reliably populated by `libuv`'s `fs_stat`. Every real directory has a unique
`dev:ino` pair. This is the primary target platform.

### macOS

Full support. HFS+/APFS provide inode numbers. `libuv` populates `stat.dev`
and `stat.ino` correctly. Case-insensitive APFS is not a concern because we
use inodes, not path strings.

### Windows

Partial support. Windows NTFS provides a file index (`stat.ino`) that can serve
as an inode equivalent, and `libuv` maps it to `stat.ino`. However:

- **FAT32** does not provide stable inode numbers. `stat.ino` may be zero.
- **`stat.dev`** on Windows is the drive letter index, which works for single-
  drive vaults but may not distinguish junctions across drives correctly.
- **NTFS junctions and symlinks** are less common in vault setups.

For vaults on NTFS (the common Windows case), `dev:ino` works. For exotic
setups, a fallback to `fs_realpath()`-based path deduplication could be added
later. Since this is a Neovim config (not a distributed plugin), Linux is the
only platform that matters in practice.

### Fallback Strategy (Not Implemented)

If portability to all platforms were required, a two-tier approach would work:

```lua
local function dir_identity(abs_path)
  local stat = vim.uv.fs_stat(abs_path)
  if not stat then return nil end
  -- Use inode if available (Unix, NTFS)
  if stat.ino and stat.ino > 0 then
    return stat.dev .. ":" .. stat.ino
  end
  -- Fall back to canonical path (FAT32, other)
  local real = vim.uv.fs_realpath(abs_path)
  return real  -- nil if realpath fails
end
```

This is not needed for the current use case but documented for completeness.

## Testing Strategy

### 1. Create a Cyclic Symlink in a Test Vault

```bash
# Setup
mkdir -p /tmp/test-vault/notes/projects
echo "# Alpha" > /tmp/test-vault/notes/projects/alpha.md
ln -s /tmp/test-vault/notes /tmp/test-vault/notes/projects/loop
```

This creates the cycle:
```
/tmp/test-vault/notes/projects/loop -> /tmp/test-vault/notes
  -> notes/projects/loop -> notes -> ...
```

### 2. Manual Test in Neovim

```vim
:lua local vi = require("andrew.vault.vault_index")
:lua local idx = vi.get("/tmp/test-vault")
:lua idx:build_sync()
" Expected: completes without hanging, warning notification about
" 'notes/projects/loop' being cyclic
:lua print(vim.inspect(vim.tbl_keys(idx.files)))
" Expected: { "notes/projects/alpha.md" } -- the file is indexed once
```

### 3. Indirect Cycle (3-node)

```bash
mkdir -p /tmp/test-vault2/{A,B,C}
echo "# A" > /tmp/test-vault2/A/a.md
echo "# B" > /tmp/test-vault2/B/b.md
echo "# C" > /tmp/test-vault2/C/c.md
ln -s /tmp/test-vault2/B /tmp/test-vault2/A/to_b
ln -s /tmp/test-vault2/C /tmp/test-vault2/B/to_c
ln -s /tmp/test-vault2/A /tmp/test-vault2/C/to_a
```

Expected: All three `.md` files indexed exactly once. Three warnings emitted
(one per back-edge encountered).

### 4. Non-Cyclic Symlinks (Regression Test)

```bash
mkdir -p /tmp/test-vault3/{notes,shared}
echo "# Shared" > /tmp/test-vault3/shared/ref.md
ln -s /tmp/test-vault3/shared /tmp/test-vault3/notes/shared_link
```

Expected: `ref.md` is indexed (via `notes/shared_link/ref.md`). No warning
emitted. The symlink target (`shared/`) is also walked as a top-level
directory, so `ref.md` might appear under two `rel_path` values
(`shared/ref.md` and `notes/shared_link/ref.md`). This is existing behavior
and unrelated to cycle detection -- but worth noting. If deduplication of
content across symlinked paths is desired, that is a separate improvement.

### 5. Automated Unit Test Sketch

```lua
-- tests/vault_index_symlink_spec.lua
describe("vault_index symlink cycle detection", function()
  local test_dir

  before_each(function()
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir .. "/sub", "p")
    vim.fn.writefile({ "# Test" }, test_dir .. "/sub/note.md")
    -- Create cycle: sub/loop -> test_dir
    vim.uv.fs_symlink(test_dir, test_dir .. "/sub/loop")
  end)

  after_each(function()
    vim.fn.delete(test_dir, "rf")
  end)

  it("does not infinite loop on cyclic symlink", function()
    local vi = require("andrew.vault.vault_index")
    -- Ensure fresh instance
    vi._instance = nil
    local idx = vi.get(test_dir)
    -- This must return, not hang
    idx:build_sync()
    -- File should be indexed exactly once
    local count = 0
    for _ in pairs(idx.files) do count = count + 1 end
    assert.equals(1, count)
  end)
end)
```

## Edge Cases

### Symlinks to Files (Not Directories)

`vim.uv.fs_scandir_next` reports symlinks to files as `ftype = "link"`, **not**
`"file"`. The current code only processes entries with `ftype == "file"`, so
symlinked `.md` files are silently ignored. This is a separate issue (not a
safety concern) and is out of scope for this improvement. If file symlink
support is desired later, the `ftype == "file"` check should be expanded to
include `ftype == "link"` with a `fs_stat()` to verify the target is a regular
file.

### Broken Symlinks

A broken symlink (target does not exist) causes `fs_stat()` to return `nil`.
In the proposed code, `dir_identity()` returns `nil` when stat fails, and the
directory is silently skipped. This is safe -- a broken symlink cannot be
entered anyway. No warning is emitted for broken symlinks to avoid noise; if
desired, a separate diagnostic could be added.

### Permission Errors

If a directory exists but is not readable (e.g., `chmod 000`):

- `fs_stat()` will succeed (stat only needs parent directory permission).
- `fs_scandir()` will fail and return `nil`.
- The existing `if not handle then return end` guard handles this correctly.

If the directory is not statable (extremely rare -- requires the parent
directory to lack execute permission), `dir_identity()` returns `nil` and the
directory is skipped. This is the safest behavior.

### Mount Points and Bind Mounts

Two directories on different filesystems may share the same inode number (e.g.,
both are inode 2, the root inode). The `dev:ino` composite key handles this
correctly because the device numbers will differ.

Bind mounts of the same filesystem will share `dev:ino`, which is the correct
behavior -- they are the same directory and should be visited only once.

### Race Conditions

If a symlink is created or deleted between the `dir_identity()` call and the
`fs_scandir()` call, the walk may encounter a stale state. This is inherent to
any non-atomic filesystem traversal and is not made worse by this change. The
existing guards (`if not handle then return end`) handle the resulting errors.

### Very Deep Non-Cyclic Trees

The inode tracking does not impose a depth limit. A legitimate directory tree
that is 100+ levels deep will be walked completely, just as it is today. If a
stack depth limit is also desired as a secondary safety measure, it could be
added independently:

```lua
local MAX_WALK_DEPTH = 100

function M.VaultIndex:_walk(abs_dir, rel_dir, visited, depth)
  depth = depth or 0
  if depth > MAX_WALK_DEPTH then
    vim.schedule(function()
      vim.notify("Vault index: max directory depth exceeded at " .. rel_dir, vim.log.levels.WARN)
    end)
    return
  end
  -- ... rest of function, passing depth + 1 to recursive calls
end
```

This is optional and not part of the primary proposal.
