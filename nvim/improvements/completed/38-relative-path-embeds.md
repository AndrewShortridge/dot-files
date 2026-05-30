# 38 — Relative Path Resolution for Embeds and Wikilinks

## Problem

Wikilinks in the vault currently resolve exclusively by **note name** (basename or
alias lookup via `vault_index:resolve_name()`). This means links like
`[[./SiblingNote]]`, `[[../ParentFolder/Note]]`, and `[[Subfolder/Note]]` fail to
resolve even when the target file exists at the expected relative location. Obsidian
supports all three forms: explicit relative paths (`./`, `../`) and implicit
folder-qualified paths (`Subfolder/Note`).

The inconsistency creates problems for users who organize notes into subdirectories
and use folder-qualified links for disambiguation. A vault with:

```
projects/
  ProjectA/
    index.md        (contains [[./tasks]] and [[../Shared/utils]])
    tasks.md
  Shared/
    utils.md
```

...cannot navigate between these notes using relative paths. The user must use bare
names (`[[tasks]]`, `[[utils]]`) which are ambiguous when multiple notes share the
same basename across different directories.

### Current State

| Component | What It Does | How | File |
|-----------|-------------|-----|------|
| `resolve_link(link_name)` | Resolves a wikilink name to an absolute path | Delegates to `vault_index:resolve_name()` — name/alias lookup only, no path logic | `wikilinks.lua:59-68` |
| `resolve_embed(name, bufnr)` | Resolves an embed link for transclusion | Delegates to `wikilinks.resolve_link(name)` for cross-file; returns buffer path for same-file | `embed.lua:94-99` |
| `resolve_image(bufnr, image_name)` | Resolves an image embed to abs path | Checks buffer dir first, then vault root, then common image dirs — **already handles relative paths** | `embed.lua:57-77` |
| `vault_index:resolve_name(name)` | Looks up note by basename or alias | Checks `_name_index` (basename + rel_path stem) and `_alias_index` — no relative path resolution | `vault_index.lua:1007-1014` |
| `link_utils.parse_target(inner)` | Parses `[[inner]]` into structured components | Returns `{name, heading, block_id, alias}` — `name` is used as-is for resolution | `link_utils.lua:8-59` |
| `preview()` | Floating preview of linked note | Calls `wikilinks.resolve_link(details.name)` — inherits same limitation | `preview.lua:101` |
| `follow_link()` | Navigate to linked note (`gf`) | Calls `resolve_link(link)` — inherits same limitation | `wikilinks.lua:161` |
| `pick_closest(paths)` | Disambiguates multiple matches by proximity | Scores paths by directory distance to current buffer — only runs after vault_index returns multiple hits | `wikilinks.lua:33-57` |

### What Is Missing

1. **No relative path detection.** `resolve_link()` passes the name directly to
   `vault_index:resolve_name()` without checking whether it looks like a path
   (`./`, `../`, or contains `/`).

2. **No buffer-relative resolution.** There is no mechanism to resolve a link
   relative to the current buffer's directory. `resolve_image()` in embed.lua does
   this for images, but the logic is not shared with note resolution.

3. **No `.md` extension probing.** A relative path like `./tasks` should resolve
   to `./tasks.md` if the extensionless path does not exist. The vault index's
   `resolve_name()` handles this implicitly (it strips `.md` from basenames), but
   raw filesystem resolution does not.

4. **Folder-qualified links fail.** `[[Subfolder/Note]]` does not resolve because
   `vault_index:resolve_name("Subfolder/Note")` does check `_name_index` by
   rel_path stem (lowercased), but only when the vault index has been built. A
   direct filesystem check relative to the current buffer or vault root would
   provide an additional resolution path.

### How Resolution Currently Works

```
[[link_name]] parsed by link_utils.parse_target()
       |
       v
  details.name (e.g., "SiblingNote", "./SiblingNote", "Subfolder/Note")
       |
       v
  resolve_link(details.name)
       |
       v
  vault_index:resolve_name(details.name)
       |
       +-- _name_index[lower] -> abs_path[]    (basename match)
       +-- _name_index[rel_stem] -> abs_path[]  (relative path stem match)
       +-- _alias_index[lower] -> abs_path[]    (alias match)
       |
       v
  pick_closest(paths)  if multiple matches
       |
       v
  abs_path or nil
```

Links starting with `./` or `../` never match any `_name_index` key because the
index stores basenames and vault-relative stems (e.g., `projects/projecta/tasks`),
not relative path prefixes.

---

## Proposed Solution

### Architecture

Add a **relative path resolution layer** inside `resolve_link()` that runs
**before** the vault index lookup. When a link name looks like a path (contains
`./`, `../`, or `/`), resolve it against the current buffer's directory using
standard filesystem path normalization. If the resolved path exists (with or without
`.md` extension), return it immediately. Otherwise, fall through to the existing
vault index resolution.

This is the minimal change needed — a single function added to `wikilinks.lua` and
a few lines added to `resolve_link()`. Because `resolve_link()` is the shared
resolution point used by `follow_link()`, `embed.lua`, and `preview.lua`, all three
consumers gain relative path support automatically.

```
[[./SiblingNote]] parsed by link_utils.parse_target()
       |
       v
  details.name = "./SiblingNote"
       |
       v
  resolve_link("./SiblingNote")
       |
       +-- is_path_like("./SiblingNote") = true     <-- NEW
       |       |
       |       v
       |   resolve_relative("./SiblingNote", bufnr)  <-- NEW
       |       |
       |       v
       |   buffer_dir .. "/SiblingNote.md"
       |       |
       |       v
       |   fs_stat() -> exists? return abs_path       <-- DONE
       |
       +-- (fallthrough if not path-like or not found)
       |
       v
  vault_index:resolve_name("./SiblingNote")
       |
       v
  nil (no match — existing behavior preserved)
```

### Path Detection

A link name is treated as a relative path when it matches any of:

1. **Explicit relative:** starts with `./` or `../`
2. **Implicit folder-qualified:** contains `/` anywhere (e.g., `Subfolder/Note`)

This is consistent with Obsidian's behavior where `Subfolder/Note` is resolved as
a path relative to the vault root first, then as a path relative to the current
file.

### Resolution Logic

```lua
--- Check if a link name looks like a relative or folder-qualified path.
---@param name string
---@return boolean
local function is_path_like(name)
  return name:match("^%.%.?/") ~= nil  -- starts with ./ or ../
    or name:find("/") ~= nil            -- contains any /
end

--- Try to resolve a path-like link name relative to the current buffer's directory.
--- Falls back to vault root for folder-qualified paths.
--- Probes with and without .md extension.
---@param name string  The link name (e.g., "./Sibling", "../Parent/Note", "Sub/Note")
---@param bufnr number|nil  Buffer to resolve relative to (defaults to current)
---@return string|nil  Absolute path if found, nil otherwise
local function resolve_relative(name, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then return nil end
  local buf_dir = vim.fs.dirname(bufname)

  --- Probe a base directory + relative name, trying both as-is and with .md.
  ---@param base string  absolute directory path
  ---@return string|nil
  local function probe(base)
    -- Normalize: resolve /./ and /../ segments
    local candidate = vim.fs.normalize(base .. "/" .. name)

    -- Try exact path first (handles names with explicit extension)
    if vim.uv.fs_stat(candidate) then
      return candidate
    end

    -- Try with .md extension appended
    local with_ext = candidate .. ".md"
    if vim.uv.fs_stat(with_ext) then
      return with_ext
    end

    return nil
  end

  -- 1. Resolve relative to the current buffer's directory
  local result = probe(buf_dir)
  if result then return result end

  -- 2. For folder-qualified paths (not explicit ./ or ../),
  --    also try relative to the vault root (Obsidian behavior)
  if not name:match("^%.%.?/") then
    result = probe(engine.vault_path)
    if result then return result end
  end

  return nil
end
```

### Integration into `resolve_link()`

The change to `resolve_link()` is minimal — add the relative path check before the
vault index lookup:

**Before:**

```lua
local function resolve_link(link_name)
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local paths = idx:resolve_name(link_name)
    if paths and #paths > 0 then
      return pick_closest(paths)
    end
  end
  return nil
end
```

**After:**

```lua
local function resolve_link(link_name, bufnr)
  -- Try relative/folder-qualified path resolution first
  if is_path_like(link_name) then
    local path = resolve_relative(link_name, bufnr)
    if path then return path end
  end

  -- Fall through to vault index name-based resolution
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local paths = idx:resolve_name(link_name)
    if paths and #paths > 0 then
      return pick_closest(paths)
    end
  end
  return nil
end
```

Key points:
- The `bufnr` parameter is **optional** and defaults to the current buffer inside
  `resolve_relative()`. Existing callers that pass no argument continue to work.
- If a path-like name fails to resolve as a relative path, it falls through to
  vault index lookup. This handles the case where `Subfolder/Note` is already
  indexed as a rel_path stem in `_name_index`.
- Non-path-like names (the common case: bare note names like `MyNote`) skip the
  relative resolution entirely — zero overhead.

### Callers of `resolve_link()`

All callers gain relative path support without changes, because `resolve_link()`
now handles it internally:

| Caller | File | How It Calls | Change Needed |
|--------|------|-------------|---------------|
| `follow_link()` | `wikilinks.lua:161` | `resolve_link(link)` | None — uses current buffer implicitly |
| `resolve_embed()` | `embed.lua:98` | `wikilinks.resolve_link(name)` | None — uses current buffer implicitly |
| `preview()` | `preview.lua:101` | `wikilinks.resolve_link(details.name)` | None — uses current buffer implicitly |
| `linkcheck.lua` | Various | Via `link_exists()` -> `resolve_link()` indirectly | None — if linkcheck calls resolve_link, it inherits the change |

The `bufnr` parameter is provided for future use when resolution needs to happen
in the context of a specific buffer (e.g., batch operations processing embeds in
non-current buffers). For now, all callers use the implicit current buffer default.

### New Note Creation with Relative Paths

When `follow_link()` encounters an unresolved link and creates a new note, it
already creates the note in the current buffer's directory (line 194-200 of
`wikilinks.lua`). For relative path links, the creation path should respect the
relative path:

**Before** (in `follow_link()`, lines 193-208):

```lua
      else
        -- Create new notes in the same directory as the current buffer (Obsidian behavior)
        local buf_dir = vim.fn.expand("%:p:h")
        local new_path
        if engine.is_vault_path(buf_dir) then
          new_path = buf_dir .. "/" .. link .. ".md"
        else
          new_path = engine.vault_path .. "/" .. link .. ".md"
        end
```

**After:**

```lua
      else
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
```

This ensures that `gf` on `[[./SubDir/NewNote]]` creates
`{current_dir}/SubDir/NewNote.md` rather than `{current_dir}/./SubDir/NewNote.md`.

---

## Configuration

No new configuration is needed. Relative path resolution is a natural extension of
the existing link resolution behavior and should always be active. The feature
activates automatically when a link name contains path separators.

If a future need arises to disable relative path resolution (e.g., for vaults that
use `/` in note names), a `config.wikilinks.resolve_relative_paths` boolean could
be added, defaulting to `true`.

---

## File Changes

| File | Change |
|------|--------|
| `lua/andrew/vault/wikilinks.lua` | Add `is_path_like()` and `resolve_relative()` helper functions; update `resolve_link()` to try relative resolution before vault index; update `follow_link()` new-note creation to respect relative paths |
| `lua/andrew/vault/embed.lua` | No changes — `resolve_embed()` delegates to `wikilinks.resolve_link()` which now handles relative paths |
| `lua/andrew/vault/preview.lua` | No changes — calls `wikilinks.resolve_link()` which now handles relative paths |
| `lua/andrew/vault/link_utils.lua` | No changes — `parse_target()` already returns the raw name including any `./` or `../` prefix |
| `lua/andrew/vault/vault_index.lua` | No changes — `resolve_name()` is unchanged; relative paths that fail filesystem resolution fall through to it |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `vault_path` for vault root fallback, `is_vault_path()` for safety check | Yes (unchanged) |
| `vault_index.lua` | `resolve_name()` as fallback after relative path resolution fails | Yes (unchanged) |
| `link_utils.lua` | `parse_target()` returns `name` field used as input to `resolve_link()` | Yes (unchanged) |
| `vim.fs.normalize()` | Path normalization (resolves `.` and `..` segments) | Yes (Neovim built-in, available since 0.8) |
| `vim.fs.dirname()` | Extract directory from buffer path | Yes (Neovim built-in) |
| `vim.uv.fs_stat()` | Check file existence on the resolved path | Yes (Neovim built-in) |

---

## Testing Plan

### Manual Verification

#### 1. Explicit relative path: `./SiblingNote`

Set up a vault directory with:
```
vault/
  folder/
    NoteA.md     (contains [[./NoteB]])
    NoteB.md
```

Open `NoteA.md`. Press `gf` on `[[./NoteB]]`. Verify navigation to `NoteB.md`.
Press `K` on `[[./NoteB]]`. Verify floating preview shows `NoteB.md` content.
Add `![[./NoteB]]` to `NoteA.md`. Run `:VaultEmbedRender`. Verify transclusion appears.

#### 2. Parent directory path: `../OtherFolder/Note`

```
vault/
  folderA/
    NoteA.md     (contains [[../folderB/NoteB]])
  folderB/
    NoteB.md
```

Open `NoteA.md`. Press `gf` on `[[../folderB/NoteB]]`. Verify navigation to
`folderB/NoteB.md`. Test `K` preview and `![[../folderB/NoteB]]` embed.

#### 3. Implicit folder-qualified path: `Subfolder/Note`

```
vault/
  projects/
    tasks.md
  index.md       (contains [[projects/tasks]])
```

Open `index.md`. Press `gf` on `[[projects/tasks]]`. Verify navigation to
`projects/tasks.md`. This should resolve via vault root fallback (not buffer-relative,
since `vault/projects/tasks` relative to `vault/` = `vault/projects/tasks.md`).

#### 4. Folder-qualified from nested buffer

```
vault/
  area/
    notes/
      deep.md    (contains [[../shared/util]])
    shared/
      util.md
```

Open `deep.md`. Press `gf` on `[[../shared/util]]`. Verify it resolves to
`vault/area/shared/util.md`.

#### 5. Existing name-based resolution still works

Open any note with `[[SomeNote]]` (bare name, no path separators). Press `gf`.
Verify it still resolves via vault index as before — no regression.

#### 6. Heading and block refs with relative paths

Test `[[./NoteB#Some Heading]]` and `[[./NoteB^blk-abc123]]`:
- `gf` should navigate to the note and jump to the heading/block.
- `K` should preview the heading section or block content.
- `![[./NoteB#Some Heading]]` should transclude the heading section.

#### 7. New note creation with relative path

Open `vault/folder/NoteA.md`. Press `gf` on `[[./SubDir/NewNote]]` (does not
exist yet). Verify:
- A new file is created at `vault/folder/SubDir/NewNote.md`.
- The `SubDir/` directory is created automatically.
- The vault index is updated for the new file.

#### 8. Path escaping outside vault

Open `vault/folder/NoteA.md`. Press `gf` on `[[../../outside]]`. Verify:
- The resolved path would be outside the vault.
- The system falls through to vault index resolution (which returns nil).
- A new note is created inside the vault (not outside it).

#### 9. Image embeds with relative paths (already working)

Verify that `![[./attachments/photo.png]]` continues to work — `resolve_image()`
already handles buffer-relative paths. This test confirms no regression.

#### 10. Alias in relative path link

Test `[[./NoteB|My Display Text]]`. Verify the alias is preserved for display
purposes and the `name` portion (`./NoteB`) resolves correctly.

### Performance Verification

Relative path resolution adds at most 2-4 `fs_stat()` calls per link (buffer-relative
with/without `.md`, vault-root with/without `.md`). For non-path-like links (the
common case), the `is_path_like()` check is a single string match — effectively zero
overhead.

```vim
" Measure resolution time for a relative path link
:lua local s = vim.uv.hrtime(); local r = require("andrew.vault.wikilinks").resolve_link("./SiblingNote"); print(("%.3f ms -> %s"):format((vim.uv.hrtime() - s) / 1e6, tostring(r)))

" Measure resolution time for a bare name (should be identical to before)
:lua local s = vim.uv.hrtime(); local r = require("andrew.vault.wikilinks").resolve_link("SomeNote"); print(("%.3f ms -> %s"):format((vim.uv.hrtime() - s) / 1e6, tostring(r)))
```

**Targets:**
- Relative path resolution: < 1ms (2-4 `fs_stat` calls at ~0.1ms each)
- Bare name resolution: unchanged (no `fs_stat` calls, vault index only)
- `is_path_like()` check on non-path names: < 0.001ms (single pattern match)

### Automated Verification

Add to the existing test suite:

```lua
-- Test: wikilinks module supports relative path resolution
do
  local source = io.open("lua/andrew/vault/wikilinks.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- New helper functions present
    assert_true(content:find("is_path_like") ~= nil,
      "has is_path_like() path detection function")
    assert_true(content:find("resolve_relative") ~= nil,
      "has resolve_relative() filesystem resolution function")

    -- resolve_link calls relative resolution before vault index
    assert_true(content:find("is_path_like.-resolve_relative") ~= nil,
      "resolve_link checks path-like names before vault index")

    -- Uses vim.fs.normalize for path normalization
    assert_true(content:find("vim.fs.normalize") ~= nil,
      "uses vim.fs.normalize for ../. resolution")

    -- Probes with .md extension
    assert_true(content:find('%.md"') ~= nil or content:find("%.md$") ~= nil,
      "probes with .md extension for extensionless links")

    -- Vault root fallback for folder-qualified paths
    assert_true(content:find("vault_path") ~= nil,
      "uses vault_path for folder-qualified fallback")

    -- New note creation respects relative paths
    assert_true(content:find("is_path_like.-link") ~= nil,
      "new note creation handles path-like links")
  end
end

-- Test: parse_target preserves path prefixes in name field
do
  local link_utils = require("andrew.vault.link_utils")

  local r1 = link_utils.parse_target("./SiblingNote")
  assert_true(r1.name == "./SiblingNote", "parse_target preserves ./ prefix")

  local r2 = link_utils.parse_target("../Parent/Note")
  assert_true(r2.name == "../Parent/Note", "parse_target preserves ../ prefix")

  local r3 = link_utils.parse_target("Subfolder/Note")
  assert_true(r3.name == "Subfolder/Note", "parse_target preserves folder/ path")

  local r4 = link_utils.parse_target("./Note#Heading")
  assert_true(r4.name == "./Note", "parse_target extracts name from relative path with heading")
  assert_true(r4.heading == "Heading", "parse_target extracts heading from relative path link")

  local r5 = link_utils.parse_target("../Dir/Note^blk-123")
  assert_true(r5.name == "../Dir/Note", "parse_target extracts name from relative path with block")
  assert_true(r5.block_id == "blk-123", "parse_target extracts block_id from relative path link")

  local r6 = link_utils.parse_target("./Note|Display")
  assert_true(r6.name == "./Note", "parse_target extracts name from relative path with alias")
  assert_true(r6.alias == "Display", "parse_target extracts alias from relative path link")
end
```
