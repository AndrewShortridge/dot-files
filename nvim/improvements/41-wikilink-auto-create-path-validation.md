# 41 - Wikilink Auto-Create Path Validation (Vault Boundary Enforcement)

**Priority:** High -- security/safety fix
**Status:** Planned
**Files:** `lua/andrew/vault/wikilinks.lua`, `lua/andrew/vault/engine.lua`

## Problem Statement

The wikilink `follow_link()` function in `wikilinks.lua` auto-creates new notes
when a link target cannot be resolved. When the link name contains relative path
components like `../`, the resolved path can escape the vault directory boundary,
creating files (and parent directories) in arbitrary filesystem locations.

### Concrete Scenario

Given vault path `/home/user/Documents/Vault` and a buffer at
`/home/user/Documents/Vault/Projects/plan.md`:

1. User writes `[[../../../.ssh/authorized_keys]]` in the note.
2. User presses `gf` on that link.
3. `resolve_link()` returns `nil` (no existing file matches).
4. The auto-create branch computes:
   ```
   buf_dir  = /home/user/Documents/Vault/Projects
   new_path = /home/user/Documents/.ssh/authorized_keys.md
   ```
5. `is_vault_path()` returns `false` (correctly), so the fallback fires:
   ```
   new_path = /home/user/Documents/Vault/../../.ssh/authorized_keys.md
   ```
6. After `vim.fs.normalize()` this becomes
   `/home/user/.ssh/authorized_keys.md`.
7. `vim.fn.mkdir(dir, "p")` creates `/home/user/.ssh/` if it does not exist.
8. `vim.cmd("edit ...")` creates the file.

While the current code does check `is_vault_path()` on the first candidate, the
**fallback path** (line 338) blindly concatenates `engine.vault_path .. "/" ..
link` without re-normalizing or re-checking. This means the `../` sequences
survive into the final path and escape the vault after `mkdir` + `edit`.

Even without the fallback issue, a more deeply nested buffer (e.g.,
`Vault/A/B/C/D/note.md`) combined with a carefully crafted link could produce a
first-candidate path that passes the naive `vim.startswith` check in
`is_vault_path()` before normalization resolves the `..` components.

### Why `is_vault_path()` Is Insufficient

```lua
function M.is_vault_path(path)
  return path ~= "" and vim.startswith(path, M.vault_path)
end
```

This check operates on the **raw string**, not the **resolved filesystem path**.
The path `/home/user/Documents/Vault/../../etc/passwd` starts with the vault
path string, so `is_vault_path()` returns `true`. Only after OS-level path
resolution do the `..` components collapse to reveal the real location.

## Current Code Analysis

### Auto-Create in `follow_link()` (wikilinks.lua, lines 329-354)

```lua
-- Create new notes: respect relative paths, otherwise use buffer directory
local new_path
if is_path_like(link) then                                    -- line 330
  local buf_dir = vim.fn.expand("%:p:h")
  new_path = vim.fs.normalize(buf_dir .. "/" .. link)         -- line 332
  if not new_path:match("%.md$") then
    new_path = new_path .. ".md"
  end
  -- Ensure the new path is within the vault
  if not engine.is_vault_path(new_path) then                  -- line 337
    new_path = engine.vault_path .. "/" .. link .. ".md"       -- line 338 BUG
  end
else                                                          -- line 340
  local buf_dir = vim.fn.expand("%:p:h")
  if engine.is_vault_path(buf_dir) then
    new_path = buf_dir .. "/" .. link .. ".md"                 -- line 343
  else
    new_path = engine.vault_path .. "/" .. link .. ".md"       -- line 345
  end
end
local dir = vim.fn.fnamemodify(new_path, ":h")
vim.fn.mkdir(dir, "p")                                        -- line 349 CREATES DIRS
vim.cmd("edit " .. vim.fn.fnameescape(new_path))              -- line 350 CREATES FILE
```

**Vulnerable points:**

1. **Line 338 (fallback for path-like links):** Concatenates vault_path with
   the raw `link` string containing `../` without normalization. The resulting
   path escapes the vault after OS resolution.

2. **Line 337 (`is_vault_path` check):** Uses string prefix matching on the
   un-normalized path. A path like `{vault}/../../foo` passes the check because
   the string starts with `{vault}`.

3. **Line 343 (non-path-like links):** Less dangerous since `link` cannot
   contain `/` (the `is_path_like` branch handles those), but a link name
   containing embedded NUL bytes or other exotic characters could still cause
   unexpected behavior.

4. **Lines 349-350 (mkdir + edit):** These are the actual filesystem-modifying
   operations. No final validation gate exists between path computation and
   filesystem mutation.

### `resolve_relative()` (wikilinks.lua, lines 22-60)

This function uses `vim.fs.normalize()` to resolve paths but only for
**existing** files (it checks `vim.uv.fs_stat()`). When the file does not exist,
it returns `nil`, and control falls through to the auto-create branch which
lacks equivalent normalization-then-validate logic.

### `engine.is_vault_path()` (engine.lua, line 637-639)

```lua
function M.is_vault_path(path)
  return path ~= "" and vim.startswith(path, M.vault_path)
end
```

Pure string prefix check. Does not resolve symlinks or normalize `..`
components.

### `engine.write_note()` (engine.lua, lines 359-391)

This function accepts a `rel_path` and prepends `vault_path`, so it is safe by
construction -- callers pass a simple name, not user-controlled path components.
However, it also lacks validation, meaning a compromised caller could still
escape.

## Proposed Solution

### 1. New Validation Function: `validate_vault_path()`

Add a new function to `engine.lua` that normalizes a candidate path and verifies
it resolves inside the vault boundary.

```lua
--- Validate that a target path resolves to a location inside the vault.
--- Normalizes the path (resolves `.`, `..`, removes redundant separators)
--- and checks the result against the vault root.
---
--- Uses vim.fs.normalize() for logical normalization (does not follow symlinks,
--- so works for paths that do not yet exist). For existing paths, additionally
--- checks vim.uv.fs_realpath() to catch symlink escapes.
---
--- @param target string  Absolute path to validate
--- @param vault string|nil  Vault root (defaults to M.vault_path)
--- @return boolean ok  True if the path is inside the vault
--- @return string|nil reason  Human-readable rejection reason (nil when ok)
function M.validate_vault_path(target, vault)
  vault = vault or M.vault_path
  if not vault or vault == "" then
    return false, "no vault path configured"
  end

  -- Normalize both paths: resolve `.`, `..`, collapse `//`, no trailing `/`
  local norm_target = vim.fs.normalize(target)
  local norm_vault = vim.fs.normalize(vault)

  -- Primary check: normalized path must start with vault prefix
  -- Append `/` to vault to prevent prefix collision:
  -- vault = "/home/user/vault" should NOT match "/home/user/vault-other/foo"
  if norm_target ~= norm_vault
    and not vim.startswith(norm_target, norm_vault .. "/") then
    return false, "path resolves outside vault: " .. norm_target
  end

  -- Secondary check: if the target already exists on disk, resolve symlinks
  -- and re-check. This catches symlinks that point outside the vault.
  local real = vim.uv.fs_realpath(norm_target)
  if real then
    local real_vault = vim.uv.fs_realpath(norm_vault) or norm_vault
    if not vim.startswith(real, real_vault .. "/") and real ~= real_vault then
      return false, "symlink resolves outside vault: " .. real
    end
  end

  return true, nil
end
```

### 2. Updated `is_vault_path()` (Optional Hardening)

The existing `is_vault_path()` is used in dozens of places as a fast guard (read
operations, highlight toggling, etc.). Changing its semantics would be
disruptive and add normalization overhead to every call. Instead, keep it as-is
for read-path guards and use `validate_vault_path()` specifically before any
**write/create** operations.

However, add a trailing-slash guard to prevent prefix collisions:

```lua
--- Check if an absolute path is inside the current vault.
--- NOTE: This is a fast string check for read-path guards. For write/create
--- operations, use validate_vault_path() which normalizes and resolves symlinks.
--- @param path string
--- @return boolean
function M.is_vault_path(path)
  if path == "" then return false end
  local vp = M.vault_path
  return path == vp or vim.startswith(path, vp .. "/")
end
```

## Where to Add Validation

### A. `follow_link()` Auto-Create Branch (wikilinks.lua)

Insert a validation gate between path computation and filesystem mutation.

**Before (current code, lines 329-354):**

```lua
-- Create new notes: respect relative paths, otherwise use buffer directory
local new_path
if is_path_like(link) then
  local buf_dir = vim.fn.expand("%:p:h")
  new_path = vim.fs.normalize(buf_dir .. "/" .. link)
  if not new_path:match("%.md$") then
    new_path = new_path .. ".md"
  end
  -- Ensure the new path is within the vault
  if not engine.is_vault_path(new_path) then
    new_path = engine.vault_path .. "/" .. link .. ".md"
  end
else
  local buf_dir = vim.fn.expand("%:p:h")
  if engine.is_vault_path(buf_dir) then
    new_path = buf_dir .. "/" .. link .. ".md"
  else
    new_path = engine.vault_path .. "/" .. link .. ".md"
  end
end
local dir = vim.fn.fnamemodify(new_path, ":h")
vim.fn.mkdir(dir, "p")
vim.cmd("edit " .. vim.fn.fnameescape(new_path))
-- Update vault index for the new file
local idx = vault_index.current()
if idx then idx:update_file(new_path) end
vim.notify("Created: " .. link .. ".md", vim.log.levels.INFO)
```

**After (patched code):**

```lua
-- Create new notes: respect relative paths, otherwise use buffer directory
local new_path
if is_path_like(link) then
  local buf_dir = vim.fn.expand("%:p:h")
  new_path = vim.fs.normalize(buf_dir .. "/" .. link)
  if not new_path:match("%.md$") then
    new_path = new_path .. ".md"
  end
else
  local buf_dir = vim.fn.expand("%:p:h")
  if engine.is_vault_path(buf_dir) then
    new_path = buf_dir .. "/" .. link .. ".md"
  else
    new_path = engine.vault_path .. "/" .. link .. ".md"
  end
end

-- Normalize and validate: reject paths that escape the vault boundary
local ok, reason = engine.validate_vault_path(new_path)
if not ok then
  vim.notify(
    "Vault: cannot create note outside vault boundary\n" .. reason,
    vim.log.levels.WARN
  )
  return
end

local dir = vim.fn.fnamemodify(new_path, ":h")
vim.fn.mkdir(dir, "p")
vim.cmd("edit " .. vim.fn.fnameescape(new_path))
-- Update vault index for the new file
local idx = vault_index.current()
if idx then idx:update_file(new_path) end
vim.notify("Created: " .. link .. ".md", vim.log.levels.INFO)
```

Key changes:

1. **Removed the unsafe fallback** (old lines 337-339). The old code tried to
   "fix" an out-of-vault path by prepending `vault_path` to the raw link --
   which just moved the traversal attack to start from vault root. Now, if the
   normalized path is outside the vault, we reject it outright.

2. **Added `validate_vault_path()` gate** after path computation and before any
   filesystem mutation (`mkdir`, `edit`). This is the single enforcement point.

3. **Simplified the path-like branch.** The `vim.fs.normalize()` call on
   line 332 already resolves `..` components. We just need to validate the
   result instead of trying to "fix" it.

### B. `engine.write_note()` (engine.lua) -- Defense in Depth

Even though `write_note()` takes a `rel_path` that callers construct, add
validation as defense in depth:

**Before:**

```lua
function M.write_note(rel_path, content)
  local full_path = M.vault_path .. "/" .. rel_path .. ".md"
  local dir = vim.fn.fnamemodify(full_path, ":h")
  M.ensure_dir(dir)
  -- ...
```

**After:**

```lua
function M.write_note(rel_path, content)
  local full_path = M.vault_path .. "/" .. rel_path .. ".md"

  -- Validate path stays inside vault (defense in depth)
  local ok, reason = M.validate_vault_path(full_path)
  if not ok then
    vim.notify("Vault: refusing to write outside vault: " .. (reason or ""), vim.log.levels.ERROR)
    return false
  end

  local dir = vim.fn.fnamemodify(full_path, ":h")
  M.ensure_dir(dir)
  -- ...
```

### C. `engine.write_file()` (engine.lua) -- Optional Deeper Gate

`write_file()` is a lower-level utility used by multiple modules. Adding
validation here would protect all callers but could impact legitimate writes
to non-vault paths (e.g., export). If desired, an opt-in parameter could be
added:

```lua
function M.write_file(path, content, opts)
  opts = opts or {}
  if opts.vault_only then
    local ok, reason = M.validate_vault_path(path)
    if not ok then
      vim.notify("Vault: write blocked: " .. (reason or ""), vim.log.levels.ERROR)
      return false
    end
  end
  -- existing logic ...
end
```

This is optional and lower priority than the `follow_link()` fix.

## User Feedback

When a path is rejected, the user should see a clear, actionable notification:

```
Vault: cannot create note outside vault boundary
path resolves outside vault: /home/user/.ssh/authorized_keys.md
```

The notification uses `vim.log.levels.WARN` (not ERROR) because this is a
user-input issue, not a system failure. The message includes:

- **What happened:** "cannot create note outside vault boundary"
- **Why:** the resolved path and how it violates the constraint
- **Implicit fix:** the user needs to change the link target

For symlink escapes, the message is slightly different:

```
Vault: cannot create note outside vault boundary
symlink resolves outside vault: /etc/real-target.md
```

## Edge Cases

### 1. Symlinks Pointing Outside the Vault

A directory inside the vault could be a symlink to an external location:

```
~/Vault/external -> /tmp/shared/
```

Writing `[[external/secret]]` would resolve to `/tmp/shared/secret.md`. The
`validate_vault_path()` function handles this in two stages:

- **Logical check** (always): `vim.fs.normalize()` resolves `..` but does NOT
  follow symlinks. This catches traversal attacks using `../`.
- **Physical check** (when path exists): `vim.uv.fs_realpath()` resolves
  symlinks and re-validates. This catches symlink escapes for existing targets.

**Limitation:** When creating a new file through a symlinked directory, the
intermediate directory exists (it is the symlink) but the target file does not.
`fs_realpath()` returns `nil` for non-existent paths, so the symlink escape is
not detected at creation time. To fully handle this case, we would need to check
`fs_realpath()` on each **existing ancestor directory**:

```lua
-- Walk up from target to find the deepest existing ancestor
local check_path = norm_target
while check_path and check_path ~= "/" do
  local real = vim.uv.fs_realpath(check_path)
  if real then
    local real_vault = vim.uv.fs_realpath(norm_vault) or norm_vault
    if not vim.startswith(real, real_vault .. "/") and real ~= real_vault then
      return false, "symlink in path resolves outside vault: " .. check_path .. " -> " .. real
    end
    break
  end
  check_path = vim.fn.fnamemodify(check_path, ":h")
end
```

This ancestor walk is included in the full implementation of
`validate_vault_path()`. It adds minimal overhead (at most a few `stat` calls)
and closes the symlink-through-directory loophole.

### 2. Vault Path Itself Contains Symlinks

If the vault root is a symlink (e.g., `~/Vault -> /mnt/nas/vault`), then
`vault_path` and `fs_realpath(vault_path)` differ. The validation function
handles this by normalizing both the vault path and the target path through
`fs_realpath()` when available. The comparison is always between consistently
resolved paths.

### 3. Windows Paths

Windows uses backslash separators and drive letters. `vim.fs.normalize()`
already handles this by converting backslashes to forward slashes and lowercasing
drive letters on Windows. The `vim.startswith()` check works correctly on the
normalized result. No special Windows handling is needed beyond what
`vim.fs.normalize()` provides.

One subtlety: Windows paths are case-insensitive. `vim.startswith()` is
case-sensitive. A path `C:/Users/vault` would not match `c:/users/vault`. Since
`vim.fs.normalize()` lowercases drive letters but not directory names, a
production-grade Windows fix would need case-folded comparison. This is out of
scope for this vault plugin (Linux/macOS only) but noted for completeness.

### 4. Trailing Slash Variations

`/home/user/vault/` vs `/home/user/vault` -- `vim.fs.normalize()` strips
trailing slashes, so this is handled. The `.. "/"` in the `vim.startswith`
check prevents false matches like `/home/user/vault-other` matching vault
`/home/user/vault`.

### 5. Unicode and Special Characters in Link Names

Link names can contain Unicode characters (e.g., `[[Uber/note]]`). These pass
through `vim.fs.normalize()` unmodified and do not affect path validation.
However, NUL bytes (`\0`) in link names could truncate C-level path operations.
The tokenizer/parser should reject NUL bytes, but as defense in depth:

```lua
if target:find("\0") then
  return false, "path contains null byte"
end
```

### 6. Race Conditions (TOCTOU)

Between `validate_vault_path()` returning `true` and `mkdir`/`edit` executing,
a symlink could theoretically be created. This is a classic TOCTOU race and is
not practically exploitable in a single-user editor context. No mitigation is
needed.

## Complete `validate_vault_path()` Implementation

Including the ancestor-walk symlink check from Edge Case 1:

```lua
--- Validate that a target path resolves to a location inside the vault.
--- Normalizes the path (resolves `.`, `..`, removes redundant separators)
--- and checks the result against the vault root. For existing paths and
--- path ancestors, additionally resolves symlinks to catch symlink escapes.
---
--- @param target string  Absolute path to validate
--- @param vault string|nil  Vault root (defaults to M.vault_path)
--- @return boolean ok  True if the path is inside the vault
--- @return string|nil reason  Human-readable rejection reason (nil when ok)
function M.validate_vault_path(target, vault)
  vault = vault or M.vault_path
  if not vault or vault == "" then
    return false, "no vault path configured"
  end

  -- Reject null bytes (defense against C-string truncation)
  if target:find("\0") then
    return false, "path contains null byte"
  end

  -- Normalize both: resolve `.`, `..`, collapse `//`, strip trailing `/`
  local norm_target = vim.fs.normalize(target)
  local norm_vault = vim.fs.normalize(vault)

  -- Primary check: normalized path must be inside vault
  if norm_target ~= norm_vault
    and not vim.startswith(norm_target, norm_vault .. "/") then
    return false, "path resolves outside vault: " .. norm_target
  end

  -- Secondary check: resolve symlinks on existing path or nearest ancestor.
  -- Walk up from target to find the deepest existing path component, then
  -- verify its real path is inside the real vault.
  local real_vault = vim.uv.fs_realpath(norm_vault) or norm_vault
  local check = norm_target
  while check and check ~= "/" and #check > 0 do
    local real = vim.uv.fs_realpath(check)
    if real then
      if real ~= real_vault
        and not vim.startswith(real, real_vault .. "/") then
        return false,
          "symlink resolves outside vault: " .. check .. " -> " .. real
      end
      break
    end
    check = vim.fn.fnamemodify(check, ":h")
  end

  return true, nil
end
```

## Testing Strategy

### Unit Tests for `validate_vault_path()`

Use a temporary directory structure to test each case. All tests assume:

```lua
local vault = "/tmp/test-vault"
vim.fn.mkdir(vault, "p")
```

| # | Input | Expected | Rationale |
|---|-------|----------|-----------|
| 1 | `vault .. "/Notes/foo.md"` | `true` | Normal path inside vault |
| 2 | `vault .. "/Notes/../Notes/foo.md"` | `true` | Redundant `..` that stays in vault |
| 3 | `vault .. "/../escape.md"` | `false` | Single `..` escapes vault root |
| 4 | `vault .. "/A/B/C/../../../../etc/passwd"` | `false` | Deep traversal escape |
| 5 | `vault .. "/./Notes/./foo.md"` | `true` | `.` components are harmless |
| 6 | `vault .. ""` (vault root itself) | `true` | Vault root is valid |
| 7 | `vault .. "-other/foo.md"` | `false` | Prefix collision: vault-other != vault |
| 8 | `"/completely/different/path.md"` | `false` | Unrelated path |
| 9 | `""` | `false` | Empty path |
| 10 | `vault .. "/foo\0bar.md"` | `false` | Null byte injection |
| 11 | Path through symlink to external dir | `false` | Symlink escape |
| 12 | Path through symlink to internal dir | `true` | Symlink stays in vault |
| 13 | Vault root is itself a symlink | `true` | Vault root symlink is trusted |

### Integration Tests for `follow_link()`

These test the full `gf` flow with crafted wikilinks:

1. **Normal auto-create:** `[[NewNote]]` in a vault buffer creates
   `{vault}/{buf_dir}/NewNote.md`. Verify file is inside vault.

2. **Subdirectory auto-create:** `[[Sub/NewNote]]` creates
   `{vault}/Sub/NewNote.md`. Verify file is inside vault.

3. **Traversal blocked:** `[[../../../etc/passwd]]` shows warning notification,
   does NOT create any files, does NOT create any directories.

4. **Traversal from deep path:** Buffer at `{vault}/A/B/C/D/note.md` with
   `[[../../../../..]]/escape` -- verify blocked.

5. **Fallback removal:** `[[../outside]]` where buffer is at vault root --
   verify warning, no file creation (old code would have used the unsafe
   fallback).

### Symlink Tests (Require Setup)

```bash
# Setup
mkdir -p /tmp/test-vault/Notes
mkdir -p /tmp/external
ln -s /tmp/external /tmp/test-vault/escape-link
ln -s /tmp/test-vault/Notes /tmp/test-vault/safe-link
```

6. **Symlink escape:** `[[escape-link/secret]]` -- verify blocked with
   "symlink resolves outside vault" message.

7. **Internal symlink:** `[[safe-link/note]]` -- verify allowed (symlink target
   is inside vault).

### Manual Smoke Test Procedure

1. Open a vault note.
2. Type `[[../../../tmp/test-escape]]` and press `gf`.
3. Verify: warning notification appears, no file created, `:!ls /tmp/test-escape*` shows nothing.
4. Type `[[Subfolder/LegitNote]]` and press `gf`.
5. Verify: new note created, no warning.
6. Run `:VaultIndexStatus` to confirm index updated.

## Summary of Changes

| File | Function | Change |
|------|----------|--------|
| `engine.lua` | `validate_vault_path()` | **New function.** Normalize + vault boundary + symlink check. |
| `engine.lua` | `is_vault_path()` | Add trailing-slash guard (`path == vp or startswith(path, vp .. "/")`) to prevent prefix collisions. |
| `engine.lua` | `write_note()` | Add `validate_vault_path()` call before `ensure_dir()` (defense in depth). |
| `wikilinks.lua` | `follow_link()` | Remove unsafe fallback (line 338). Add `validate_vault_path()` gate before `mkdir` + `edit`. |
