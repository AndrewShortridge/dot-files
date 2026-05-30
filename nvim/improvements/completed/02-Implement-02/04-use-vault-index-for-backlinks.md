# Use Vault Index for Backlinks Instead of Ripgrep

## Problem

`backlinks.lua` spawns a `ripgrep` subprocess for every backlinks query -- even
though `vault_index._inlinks` already maintains a precomputed reverse-link map
that is rebuilt incrementally on every file save and on startup. This creates
three issues:

1. **Performance.** Ripgrep scans every `.md` file in the vault (O(n) where n is
   total file bytes). On large vaults (1000+ notes) this adds noticeable latency,
   especially over NFS or encrypted filesystems.
2. **Redundant work.** The vault index already parses every outlink during
   indexing and inverts them into `_inlinks`. The same data ripgrep finds is
   already sitting in memory.
3. **Inconsistency.** Ripgrep pattern-matches raw `[[Name...]]` text with regex,
   while the vault index resolves links through the proper name/alias/path
   resolution chain. A note linked via an alias (`[[My Alias]]`) will appear in
   `_inlinks` but may not match the ripgrep pattern that searches for the
   basename.

## Current State

### How `backlinks.lua` works today

**File:** `lua/andrew/vault/backlinks.lua`

The module exposes three functions, all wired to keymaps on markdown buffers:

| Keymap | Function | Behavior |
|--------|----------|----------|
| `<leader>vfb` | `M.backlinks()` | Ripgrep for `\[\[Name([#\|][^\]]*)?]]` with `-C 2` context |
| `<leader>vfh` | `M.heading_backlinks()` | Ripgrep for `\[\[Name#Heading([|][^\]]*)?]]` with `-C 2` context |
| `<leader>vfl` | `M.forwardlinks()` | Parse current buffer for `[[...]]` links, resolve each via `wikilinks.resolve_link()`, present in fzf picker |

#### `M.backlinks()` (lines 14-27)

```lua
function M.backlinks()
  local name = current_note_name()  -- vim.fn.fnamemodify(bufname, ":t:r")
  local fzf = require("fzf-lua")
  fzf.grep(engine.vault_fzf_opts("Backlinks to " .. name, {
    search = "\\[\\[" .. fzf.utils.rg_escape(name) .. "([#|][^\\]]*)?\\]\\]",
    no_esc = true,
    rg_opts = engine.rg_base_opts() .. " -C 2",
  }))
end
```

This launches fzf-lua's `grep` action which spawns `rg` under the hood with the
vault root as `cwd`. The regex matches `[[Name]]`, `[[Name|alias]]`,
`[[Name#heading]]`, and `[[Name#heading|alias]]`. Results appear in fzf with
file:line:content and 2 lines of context.

#### `M.heading_backlinks()` (lines 41-61)

Finds the nearest heading above the cursor via `nearest_heading_above_cursor()`,
then runs a more specific ripgrep search for `[[Name#Heading...]]`. Falls back
to `M.backlinks()` if no heading is found.

#### `M.forwardlinks()` (lines 63-99)

Parses the current buffer's lines with `gmatch("%[%[([^%]|#]+)")`, resolves each
link name via `wikilinks.resolve_link()`, and presents the list in
`fzf.fzf_exec()`. This function already avoids ripgrep entirely.

### What `vault_index._inlinks` provides

**File:** `lua/andrew/vault/vault_index.lua`

`_inlinks` is a table keyed by **target relative path** (e.g.,
`"Projects/My Note.md"`), with each value being an array of inlink records:

```lua
_inlinks["Projects/My Note.md"] = {
  { path = "Log/2024-01-15",    display = "2024-01-15",  embed = false },
  { path = "Areas/Research",    display = "Research",     embed = false },
  -- ...
}
```

Each inlink record has:
- `path` -- relative path of the **source** file (without `.md` extension)
- `display` -- basename of the source file
- `embed` -- always `false` in the current implementation (embed distinction is
  not tracked in inlinks, only in outlinks)

**Resolution chain** used by `_recompute_inlinks()` (lines 882-939):

For each outlink in each file, the raw link path is stripped of `#heading` and
`^blockid` fragments, then resolved through this priority order:
1. Exact relative path match (lowercased)
2. Relative path without `.md` extension
3. Basename-only match
4. Alias match

This means `_inlinks` correctly handles:
- `[[Note]]` -- resolved by basename
- `[[Folder/Note]]` -- resolved by relative path
- `[[My Alias]]` -- resolved by alias
- `[[Note#Heading]]` -- fragment stripped, resolved to `Note`
- `[[Note^blockid]]` -- fragment stripped, resolved to `Note`

**Critically:** `_inlinks` does NOT preserve which heading or block ID was
targeted. It only records "file A links to file B." This matters for
heading-scoped backlinks.

### What the outlinks `path` field preserves

Each outlink record in `entry.outlinks` stores the **full raw link path**
including fragments:

```lua
{ path = "Note#Heading",   display = "Note",   embed = false }
{ path = "Note^blk-abc",   display = "Note",   embed = false }
{ path = "Note|Alias",     display = "Alias",  embed = false }
```

The `|alias` portion is split during extraction (the pipe-separated display name
becomes the `display` field), but `#heading` and `^blockid` fragments ARE
preserved in the `path` field. This is important -- we can use the raw outlinks
to implement heading-scoped backlinks.

### Incremental inlinks updates

The index maintains inlinks incrementally via
`_recompute_inlinks_incremental()` (lines 941-1042). On single-file saves
(`update_file()`), only the affected source file's inlink contributions are
removed and re-added. Full recomputation happens only on `build_sync()` and
`build_async()`.

### What the backlinks picker expects

`fzf.grep()` with ripgrep expects to show results as `file:line:content` with
context lines. The user can navigate these grep results to see exactly where in
each file the backlink appears.

If we switch to vault index lookups, we'll instead have a list of source file
paths. We lose the inline grep context (which line contains the link, surrounding
lines). We need to decide whether that's acceptable or whether to add a secondary
pass.

## Solution

Replace ripgrep with vault index lookups as the primary path. Keep ripgrep as
fallback when the index isn't ready. For heading-scoped backlinks, use the raw
outlinks data to filter by heading fragment.

### Design decisions

1. **Primary path:** Use `vault_index:get_inlinks(rel_path)` for O(1) lookup.
2. **Fallback:** Keep ripgrep for when `idx:is_ready()` is false (cold start
   before index loads).
3. **Picker change:** Switch from `fzf.grep()` to `fzf.fzf_exec()` for the
   index-based path, since we're no longer feeding ripgrep results. Use the
   builtin previewer to show file contents on selection.
4. **Context lines:** The ripgrep approach showed the exact line containing the
   backlink plus 2 context lines. With the index approach, we can either:
   - (a) Show just the file list with file preview (simpler, faster), or
   - (b) Post-process: for each inlink source, find the line(s) containing the
     `[[target]]` reference and format as grep-like output.

   **Recommendation:** Option (b) for parity. Read each source file's outlinks
   from the index to find matching link positions, then format results as
   `rel_path:line_num:line_content`. This avoids spawning ripgrep while still
   showing context. However, the outlinks in the index don't store line numbers.
   Two sub-options:
   - (b1) Do a quick `io.open` + line scan of each source file to find the
     `[[target]]` pattern. This is much cheaper than ripgrep because we only scan
     the files that we already know contain the link (typically 5-20 files, not
     the entire vault).
   - (b2) Add line numbers to the outlinks in `extract_links()`. This would be
     the cleanest solution long-term but changes the index schema.

   **Recommendation:** Start with (b1) for minimal schema changes. Add line
   numbers to outlinks later if needed.

5. **Heading-scoped backlinks:** The outlinks `path` field preserves
   `#heading` fragments. For each inlink source file, check if any of its
   outlinks targeting the current file include the `#heading` fragment. This
   replaces the heading-specific ripgrep regex.

6. **Forward links:** Already uses buffer parsing + `resolve_link()`. No changes
   needed for the index path. However, we can optionally add an index-based fast
   path using `entry.outlinks` for the current file.

## Implementation Steps

### Step 1: Add backlink query helpers to `backlinks.lua`

Add helper functions that query the vault index and format results for the fzf
picker.

```lua
local vault_index = require("andrew.vault.vault_index")

--- Get the current file's rel_path in the vault index.
---@return string|nil rel_path
---@return VaultIndex|nil idx
local function current_file_index_info()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then return nil, nil end

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return nil, nil end

  local entry = idx:get_entry_by_abs(bufname)
  if not entry then return nil, nil end

  return entry.rel_path, idx
end

--- Find lines in a file that contain a wikilink to the target name.
--- Returns a list of { lnum = number, text = string }.
---@param abs_path string
---@param target_name string  The note name to search for (case-insensitive)
---@param heading_filter string|nil  If set, only match links with this #heading
---@return { lnum: number, text: string }[]
local function find_link_lines(abs_path, target_name, heading_filter)
  local f = io.open(abs_path, "r")
  if not f then return {} end

  local results = {}
  local lnum = 0
  local target_lower = target_name:lower()
  local pattern = "%[%[(.-)%]%]"

  for line in f:lines() do
    lnum = lnum + 1
    for inner in line:gmatch(pattern) do
      -- Strip display alias
      local link_path = inner:match("^(.-)%|") or inner
      -- Separate heading/block fragment
      local name_part = link_path:match("^([^#^]+)") or link_path
      name_part = vim.trim(name_part):lower()

      -- Check if this link targets our note
      -- Match by basename or full path
      local matches = (name_part == target_lower)
        or (name_part:match("([^/]+)$") == target_lower)

      if matches then
        if heading_filter then
          local heading_frag = link_path:match("#(.+)$")
          if heading_frag and heading_frag:lower() == heading_filter:lower() then
            results[#results + 1] = { lnum = lnum, text = line }
          end
        else
          results[#results + 1] = { lnum = lnum, text = line }
        end
      end
    end
  end

  f:close()
  return results
end
```

### Step 2: Replace `M.backlinks()` with index-first approach

```lua
function M.backlinks()
  local name = current_note_name()
  if not name then
    vim.notify("Vault: buffer has no filename", vim.log.levels.WARN)
    return
  end

  -- Try vault index first
  local rel_path, idx = current_file_index_info()
  if rel_path and idx then
    local inlinks = idx:get_inlinks(rel_path)
    if #inlinks == 0 then
      vim.notify("Vault: no backlinks found for " .. name, vim.log.levels.INFO)
      return
    end

    -- Build grep-like results: rel_path:lnum:text
    local results = {}
    for _, inlink in ipairs(inlinks) do
      local source_rel = inlink.path .. ".md"
      local source_entry = idx:get_entry(source_rel)
      if source_entry then
        local lines = find_link_lines(source_entry.abs_path, name, nil)
        for _, hit in ipairs(lines) do
          results[#results + 1] = source_rel .. ":" .. hit.lnum .. ":" .. hit.text
        end
      end
    end

    if #results == 0 then
      -- Inlinks exist but couldn't find the actual lines (edge case)
      -- Fall back to file-only list
      local file_list = {}
      for _, inlink in ipairs(inlinks) do
        file_list[#file_list + 1] = inlink.path .. ".md"
      end
      table.sort(file_list)
      require("fzf-lua").fzf_exec(file_list, engine.vault_fzf_opts(
        "Backlinks to " .. name, {
          previewer = "builtin",
          actions = engine.vault_fzf_actions(),
        }
      ))
      return
    end

    require("fzf-lua").fzf_exec(results, engine.vault_fzf_opts(
      "Backlinks to " .. name .. " (index)", {
        fzf_opts = { ["--delimiter"] = ":", ["--nth"] = "3.." },
        previewer = "builtin",
        actions = engine.vault_fzf_actions(),
      }
    ))
    return
  end

  -- Fallback: ripgrep (index not ready)
  M._backlinks_rg(name)
end

--- Ripgrep fallback for backlinks (used when index is not ready).
function M._backlinks_rg(name)
  local fzf = require("fzf-lua")
  fzf.grep(engine.vault_fzf_opts("Backlinks to " .. name, {
    search = "\\[\\[" .. fzf.utils.rg_escape(name) .. "([#|][^\\]]*)?\\]\\]",
    no_esc = true,
    rg_opts = engine.rg_base_opts() .. " -C 2",
  }))
end
```

**Note on fzf_exec with grep-like results:** The `fzf_exec` + file-based
actions approach requires that the result strings are parseable as file
locations. fzf-lua's builtin actions use the `file_edit` action which parses
`path:line:col:text` format. Since we produce `rel_path:lnum:text`, the default
actions should work. The `cwd` in `vault_fzf_opts` ensures paths resolve
correctly.

### Step 3: Replace `M.heading_backlinks()` with index-first approach

Heading backlinks require checking whether a source file's link to the current
note includes a specific `#heading` fragment. The outlinks stored in the vault
index preserve this fragment.

```lua
function M.heading_backlinks()
  local name = current_note_name()
  if not name then
    vim.notify("Vault: buffer has no filename", vim.log.levels.WARN)
    return
  end

  local heading = nearest_heading_above_cursor()
  if not heading then
    vim.notify("Vault: no heading above cursor, falling back to regular backlinks",
      vim.log.levels.INFO)
    M.backlinks()
    return
  end

  -- Try vault index first
  local rel_path, idx = current_file_index_info()
  if rel_path and idx then
    local inlinks = idx:get_inlinks(rel_path)
    if #inlinks == 0 then
      vim.notify("Vault: no backlinks found for " .. name .. "#" .. heading,
        vim.log.levels.INFO)
      return
    end

    -- Filter: check each source file's outlinks for heading match
    local results = {}
    local heading_slug = require("andrew.vault.link_utils").heading_to_slug(heading)

    for _, inlink in ipairs(inlinks) do
      local source_rel = inlink.path .. ".md"
      local source_entry = idx:get_entry(source_rel)
      if source_entry then
        -- Check outlinks for heading-targeted links to this file
        for _, outlink in ipairs(source_entry.outlinks) do
          local raw = outlink.path or ""
          local heading_frag = raw:match("#(.+)$")
          if heading_frag then
            local link_name = raw:match("^([^#]+)") or ""
            link_name = vim.trim(link_name)
            -- Check if this outlink targets our file
            local target_paths = idx:resolve_name(link_name)
            if target_paths then
              local entry = idx:get_entry(rel_path)
              if entry then
                for _, tp in ipairs(target_paths) do
                  if tp == entry.abs_path then
                    -- Check heading match via slug comparison
                    local frag_slug = require("andrew.vault.slug").heading_to_slug(heading_frag)
                    if frag_slug == heading_slug then
                      -- Find the actual line in the source file
                      local lines = find_link_lines(source_entry.abs_path, name, heading)
                      for _, hit in ipairs(lines) do
                        results[#results + 1] = source_rel .. ":" .. hit.lnum
                          .. ":" .. hit.text
                      end
                    end
                    break
                  end
                end
              end
            end
          end
        end
      end
    end

    if #results == 0 then
      vim.notify("Vault: no heading backlinks found for " .. name .. "#" .. heading,
        vim.log.levels.INFO)
      return
    end

    require("fzf-lua").fzf_exec(results, engine.vault_fzf_opts(
      "Heading backlinks to " .. name .. "#" .. heading .. " (index)", {
        fzf_opts = { ["--delimiter"] = ":", ["--nth"] = "3.." },
        previewer = "builtin",
        actions = engine.vault_fzf_actions(),
      }
    ))
    return
  end

  -- Fallback: ripgrep
  M._heading_backlinks_rg(name, heading)
end

function M._heading_backlinks_rg(name, heading)
  local fzf = require("fzf-lua")
  fzf.grep(engine.vault_fzf_opts("Heading backlinks to " .. name .. "#" .. heading, {
    search = "\\[\\[" .. fzf.utils.rg_escape(name) .. "#"
      .. fzf.utils.rg_escape(heading) .. "([|][^\\]]*)?\\]\\]",
    no_esc = true,
    rg_opts = engine.rg_base_opts() .. " -C 2",
  }))
end
```

**Simplification opportunity:** The heading backlinks implementation above is
complex because it cross-references outlinks with inlinks. A simpler approach:
since we already know the set of inlink source files from the index, we can just
use `find_link_lines()` with a heading filter on only those files. This avoids
the outlinks cross-reference entirely:

```lua
-- Simpler approach for heading backlinks:
for _, inlink in ipairs(inlinks) do
  local source_rel = inlink.path .. ".md"
  local source_entry = idx:get_entry(source_rel)
  if source_entry then
    local lines = find_link_lines(source_entry.abs_path, name, heading)
    for _, hit in ipairs(lines) do
      results[#results + 1] = source_rel .. ":" .. hit.lnum .. ":" .. hit.text
    end
  end
end
```

This is recommended. The `find_link_lines()` function already handles heading
filtering by checking the `#fragment` portion of each wikilink it encounters.

### Step 4: Optionally improve `M.forwardlinks()` with index

The current `forwardlinks()` parses the buffer and resolves each link via
`wikilinks.resolve_link()`. This works well but could be simplified using the
index entry's outlinks:

```lua
function M.forwardlinks_indexed()
  local rel_path, idx = current_file_index_info()
  if not rel_path or not idx then
    -- Fall back to current implementation
    M.forwardlinks()
    return
  end

  local entry = idx:get_entry(rel_path)
  if not entry or #entry.outlinks == 0 then
    vim.notify("Vault: no wikilinks found in current buffer", vim.log.levels.INFO)
    return
  end

  local seen = {}
  local links = {}
  local path_map = {}

  for _, outlink in ipairs(entry.outlinks) do
    local raw = outlink.path or ""
    local name_part = raw:match("^([^#^]+)") or raw
    name_part = vim.trim(name_part)
    if name_part == "" or seen[name_part] then goto continue end
    seen[name_part] = true

    local resolved = idx:resolve_name(name_part)
    if resolved and #resolved > 0 then
      local abs = resolved[1]
      local rel = abs:sub(#engine.vault_path + 2)
      links[#links + 1] = rel
      path_map[rel] = abs
    else
      links[#links + 1] = name_part .. ".md"
    end

    ::continue::
  end

  -- ... same fzf picker as current forwardlinks()
end
```

**Note:** This has a caveat -- the index entry's outlinks reflect the last-saved
state of the file, not the current buffer contents. If the user has unsaved
changes with new links, those won't appear. The current buffer-parsing approach
is better for forward links. **Recommendation: keep `forwardlinks()` as-is.**

### Step 5: Add `vault_index` require to `backlinks.lua`

```lua
local vault_index = require("andrew.vault.vault_index")
```

This is safe -- `vault_index.lua` has zero requires of its own (except
`andrew.vault.slug`), so no circular dependency risk.

### Step 6: Update user commands

No changes needed. The `:VaultBacklinks` and `:VaultForwardlinks` commands call
`M.backlinks()` and `M.forwardlinks()` which will internally dispatch to index
or ripgrep.

## Files to Modify

### `lua/andrew/vault/backlinks.lua`

1. Add `require("andrew.vault.vault_index")` at top.
2. Add `current_file_index_info()` helper -- resolves current buffer to
   `rel_path` via the vault index.
3. Add `find_link_lines(abs_path, target_name, heading_filter)` helper -- scans
   a single file for wikilinks matching a target, optionally filtered by heading.
4. Extract current `M.backlinks()` ripgrep logic into `M._backlinks_rg(name)`.
5. Rewrite `M.backlinks()` to try index first, fallback to `_backlinks_rg()`.
6. Extract current `M.heading_backlinks()` ripgrep logic into
   `M._heading_backlinks_rg(name, heading)`.
7. Rewrite `M.heading_backlinks()` to try index first, use `find_link_lines()`
   with heading filter on inlink sources, fallback to `_heading_backlinks_rg()`.
8. Leave `M.forwardlinks()` unchanged (buffer parsing is correct for unsaved
   edits).
9. Leave `M.setup()` unchanged (keymaps and commands stay the same).

### No changes needed in other files

- `vault_index.lua` -- already exposes `get_inlinks(rel_path)`,
  `get_entry_by_abs()`, `get_entry()`, `resolve_name()`, `is_ready()`,
  `current()`. All needed APIs exist.
- `engine.lua` -- `vault_fzf_opts()`, `vault_fzf_actions()`, `vault_path` all
  used as-is.
- `config.lua` -- no new config keys needed.
- `wikilinks.lua` -- no changes.

## Performance Comparison

### Before (ripgrep)

| Operation | Cost |
|-----------|------|
| `M.backlinks()` | Fork `rg` process, scan all `.md` files in vault (O(n) on total bytes), regex match, pipe results back |
| `M.heading_backlinks()` | Same as above with more specific regex |
| Latency | ~100-500ms on large vaults (depends on disk cache, vault size) |
| Startup cost | None (ripgrep is stateless) |

### After (vault index)

| Operation | Cost |
|-----------|------|
| `M.backlinks()` | O(1) hash lookup for `_inlinks[rel_path]`, then O(k) where k = number of inlink source files to scan for line numbers |
| `M.heading_backlinks()` | Same O(1) lookup + O(k) scan with heading filter |
| Latency | <10ms for index lookup + ~5-50ms for line scanning (k files, typically 5-20) |
| Startup cost | Index build (amortized, runs once at startup, ~1-3s for large vaults) |

**Key insight:** The ripgrep approach scans ALL vault files. The index approach
reads only the files that are known to contain backlinks (typically a tiny
subset). For a 2000-file vault where a note has 10 backlinks, ripgrep scans 2000
files while the index approach reads 10.

### Worst case

When the index is not ready (first 1-3 seconds after Neovim startup before
`build_async` completes), the ripgrep fallback fires. This is identical to
current behavior.

## Edge Cases

### New files not yet indexed

A file created outside Neovim (e.g., via Obsidian mobile) won't appear in the
index until the next `build_async()` or filesystem watcher event. During this
window:
- The ripgrep fallback would find it, but the index path won't.
- **Mitigation:** The index's `build_async()` runs at startup and the fs watcher
  (`config.index.watch = true`) picks up changes. Gap is typically <1 second.
- **Additional mitigation:** If the index returns 0 inlinks for a file that the
  user expects to have backlinks, the user can `:VaultIndexRebuild` to force a
  full reindex.

### Aliases resolving to same note

If note "Foo.md" has alias "bar", then `[[bar]]` in another file resolves to
`Foo.md` during inlinks computation. This already works correctly --
`_recompute_inlinks()` resolves via basename > alias priority and stores the
inlink under `Foo.md`'s `rel_path`. No special handling needed.

### Renamed files

When a file is renamed:
1. The old path is removed from the index (either via fs watcher or manual
   `remove_file()`).
2. The new path is added via `update_file()`.
3. Inlinks are recomputed incrementally.
4. Any file that linked to the old name via `[[OldName]]` will have a broken
   outlink (won't resolve to any target), so it will NOT appear in the new
   file's inlinks. This is correct behavior -- the link text hasn't been
   updated.

### Case-insensitive matching

The vault index uses lowercased names/aliases for resolution
(`entry.basename_lower`, aliases stored as `.lower()`). Ripgrep uses
`--smart-case`. The `find_link_lines()` helper should also lowercase-compare to
maintain parity. The implementation above does `target_name:lower()` comparison.

### Multiple links to same target in one file

A source file may contain `[[Note]]` on multiple lines. The `find_link_lines()`
scan will find all of them, producing multiple result entries for the same source
file. This matches ripgrep behavior (ripgrep also shows every matching line).

### Embed links `![[Note]]`

The current ripgrep pattern `\[\[Name...\]\]` also matches `![[Name]]` (the `!`
is before the `[[`). The vault index's `_inlinks` are built from ALL outlinks
including embeds (see `extract_links()` -- both embed and non-embed links are
extracted). The `_recompute_inlinks` loop processes all outlinks regardless of
the `embed` field. So embed backlinks are already included. The
`find_link_lines()` helper should also match `![[...]]` patterns. The
`gmatch("%[%[(.-)%]%]")` pattern in the helper naturally matches inside
`![[...]]` since `!` is not part of the `[[` anchor.

### Self-referential links

`_recompute_inlinks()` explicitly filters self-links:
`if target and target.rel_path ~= source_entry.rel_path then`. A note linking
to itself (`[[Self]]`) won't appear in its own inlinks. This is correct and
matches user expectations.

### Same-file heading/block links

Links like `[[#Heading]]` or `[[^blockid]]` (no note name, just fragment) have
an empty name part after stripping the fragment. `_recompute_inlinks()` skips
these via `if raw == "" then goto continue end`. These are same-file navigation
links, not cross-file backlinks. Correct behavior.

## Testing

### Manual verification

1. **Basic backlinks:**
   - Open a note that is linked to by other notes.
   - Press `<leader>vfb`.
   - Verify results match what ripgrep would find.
   - Cross-check: run `:VaultBacklinks` and compare with
     `rg '\[\[NoteName' /path/to/vault --glob '*.md'`.

2. **Heading backlinks:**
   - Open a note with headings. Place cursor under a heading.
   - Press `<leader>vfh`.
   - Verify only links with `#HeadingName` fragment appear.

3. **Alias backlinks:**
   - Open a note that has aliases in frontmatter.
   - Verify that files linking to the note via its alias appear in backlinks.

4. **Fallback:**
   - Add a temporary `self._ready = false` in vault_index to force fallback.
   - Verify `<leader>vfb` still works (ripgrep path).

5. **Empty backlinks:**
   - Open a note with no inlinks (orphan note).
   - Verify a clean "no backlinks found" notification.

6. **Performance:**
   - In a large vault, compare latency of `<leader>vfb` before and after
     the change. Use `:lua vim.g._bl_start = vim.uv.hrtime()` before and
     `:lua print((vim.uv.hrtime() - vim.g._bl_start) / 1e6 .. "ms")` after
     picker opens.

### Automated verification (optional)

Add a minimal test in the vault test harness (if one exists) that:
1. Creates a temp vault with 3 files: A links to B, C links to B.
2. Builds the index synchronously.
3. Calls `idx:get_inlinks("B.md")` and asserts 2 entries.
4. Calls `find_link_lines()` on A and verifies the correct line number.
