# 34 — Block ID Validation in Link Diagnostics

## Problem

`linkcheck.lua` validates note names and heading anchors in wikilinks, but completely ignores `^block-id` references. The `extract_links()` function in linkcheck calls `link_utils.parse_target()` which returns a `block_id` field, but this field is discarded -- only `name` and `heading` are stored. Any wikilink containing a `^blockref` passes validation silently, even when the block ID does not exist in the target note.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **linkcheck.lua** | Validates note names and `#heading` anchors; reports broken links via fzf picker and diagnostics | `lua/andrew/vault/linkcheck.lua` |
| **vault_index.lua** | Stores `block_ids` array per file entry (extracted during single-pass parse); no query method for block ID lookup | `lua/andrew/vault/vault_index.lua` |
| **link_utils.lua** | `parse_target()` returns `{ name, heading, block_id, alias }` -- fully parses `^blockref` syntax | `lua/andrew/vault/link_utils.lua` |
| **blockid.lua** | Generates `^blk-XXXXXX` IDs; collision-checks within current buffer | `lua/andrew/vault/blockid.lua` |
| **wikilinks.lua** | `gf` follow uses `find_block_in_file()` to jump to block refs -- file-scanning fallback | `lua/andrew/vault/wikilinks.lua` |
| **embed.lua** | `read_block_content()` for transclusion; shows `[Block not found]` on miss | `lua/andrew/vault/embed.lua` |

### What Is Missing

1. **No block ID validation** in `check_buffer()` or `check_vault()`. A link `[[Note^nonexistent]]` is silently treated as valid because `extract_links()` discards the `block_id` field.
2. **No vault index query API** for block IDs. `get_headings(abs_path)` returns a slug set for heading validation, but there is no equivalent `get_block_ids(abs_path)` method. Consumers must manually access `entry.block_ids` and convert the array to a set.
3. **No error differentiation**. When `[[Note^blockid]]` fails, there is no distinction between "Note does not exist" and "Note exists but block ID is missing." The current code only checks the note name.
4. **No block ref statistics** in the `check_buffer()` summary message. The notification says "all N links OK" but `N` only counts note + heading links.
5. **Same-file block refs** like `[[^blockid]]` are not validated at all. The `extract_links()` function requires `name ~= ""` (line 39), so self-referencing block links `[[^blk-abc123]]` are silently skipped.

### How `extract_links` Discards Block IDs Today

```lua
-- linkcheck.lua lines 33-45 (current)
local function extract_links(line)
  local links = {}
  for inner in line:gmatch("%[%[([^%]]+)%]%]") do
    local parsed = link_utils.parse_target(inner)
    local name = parsed.name
    local heading = parsed.heading
    -- parsed.block_id is IGNORED here
    if name ~= "" then
      local display = heading and (name .. "#" .. heading) or name
      links[#links + 1] = { name = name, heading = heading, display = display }
    end
    -- Links with name == "" (self-refs like [[^blockid]]) are also skipped
  end
  return links
end
```

The `link_utils.parse_target()` call on line 36 already returns `block_id` for all link forms (`[[Note^blk]]`, `[[^blk]]`, `[[Note#Heading^blk]]`), but the result is never used.

---

## Goal

Extend the link diagnostics system to validate `^block-id` references:

1. Validate cross-file block refs `[[Note^blockid]]` using vault index data (O(1) lookup per file).
2. Validate same-file block refs `[[^blockid]]` by scanning the current buffer lines.
3. Report broken block refs as diagnostics with the same severity as broken heading refs.
4. Distinguish "note not found" vs "note found but block ID missing" in error messages.
5. Add a `get_block_ids(abs_path)` query method to `vault_index.lua` returning a set for O(1) membership testing.
6. Include block ref counts in the `:VaultLinkCheck` / `:VaultLinkCheckAll` summary statistics.
7. Integrate broken block refs into the existing fzf picker with a `(broken block)` label.
8. Handle compound links `[[Note#Heading^blockid]]` -- validate all three components.

---

## Approach

### Architecture

The change touches three files:

1. **`vault_index.lua`** -- Add a `get_block_ids(abs_path)` query method that mirrors `get_headings()`. This converts the stored `block_ids` array to a `table<string, boolean>` set for O(1) lookup.

2. **`linkcheck.lua`** -- Modify `extract_links()` to preserve `block_id` from `parse_target()`. Modify both `check_buffer()` and `check_vault()` to validate block refs after note/heading validation passes. Add same-file block ref handling via buffer line scanning.

3. No changes to `link_utils.lua` or `blockid.lua` -- `parse_target()` already returns `block_id` correctly.

### Lookup Strategy

For **cross-file** block refs `[[Note^blockid]]`:
```
vault_index.current() -> idx:get_block_ids(filepath) -> set[block_id] == true
```

For **same-file** block refs `[[^blockid]]`:
```
scan vim.api.nvim_buf_get_lines() for ^{id}\s*$ pattern (matches blockid.lua format)
```

The vault index already parses block IDs during its single-pass file parse (`extract_block_ids()` at line 373 of `vault_index.lua`). The stored data is an array like `{"blk-abc123", "blk-def456"}`. The new `get_block_ids()` method converts this to a set `{["blk-abc123"] = true, ["blk-def456"] = true}` for direct membership testing.

### Validation Flow (Updated)

```
For each wikilink [[...]] in buffer:
  1. Parse via link_utils.parse_target() -> { name, heading, block_id }
  2. If name ~= "":
     a. Check note exists (existing link_exists() check)
     b. If note not found -> report "broken note"
     c. If note found AND heading present -> validate heading (existing logic)
     d. If note found AND block_id present -> validate block_id (NEW)
     e. If note found AND heading AND block_id -> validate both (NEW)
  3. If name == "" (self-reference):
     a. If heading present -> validate heading in current buffer (existing for headings)
     b. If block_id present -> validate block_id in current buffer (NEW)
```

### Error Message Differentiation

| Link Form | Note Status | Target Status | Error Message |
|-----------|------------|---------------|---------------|
| `[[Note^blk]]` | Not found | N/A | `[[Note^blk]] (broken note)` |
| `[[Note^blk]]` | Found | Block missing | `[[Note^blk]] (broken block)` |
| `[[Note#H^blk]]` | Found | Heading OK, block missing | `[[Note#H^blk]] (broken block)` |
| `[[Note#H^blk]]` | Found | Heading missing | `[[Note#H^blk]] (broken heading)` |
| `[[Note#H^blk]]` | Found | Both missing | `[[Note#H^blk]] (broken heading)` |
| `[[^blk]]` | Self | Block missing | `[[^blk]] (broken block)` |

When both heading and block ID are broken, the heading error takes precedence (reported first) since a broken heading implies the block context is also unreachable.

---

## Implementation Steps

### Step 1: Add `get_block_ids()` to `vault_index.lua`

Add a new query method immediately after `get_headings()` (after line 1017):

**File:** `lua/andrew/vault/vault_index.lua`

```lua
--- Get block IDs for a file by absolute path.
---@param abs_path string
---@return table<string, boolean> block_id_set  Maps block IDs (without ^) to true
function M.VaultIndex:get_block_ids(abs_path)
  local prefix = self.vault_path .. "/"
  if abs_path:sub(1, #prefix) ~= prefix then return {} end
  local rel_path = abs_path:sub(#prefix + 1)
  local entry = self.files[rel_path]
  if not entry then return {} end
  -- Convert array to set for O(1) lookup
  local set = {}
  for _, id in ipairs(entry.block_ids or {}) do
    set[id] = true
  end
  return set
end
```

This follows the exact pattern of `get_headings()` (lines 1010-1017): takes an `abs_path`, strips the vault prefix, looks up the entry, and returns a set. The only difference is that `heading_slugs` is already stored as a set in the entry, while `block_ids` is stored as an array and must be converted.

### Step 2: Modify `extract_links()` in `linkcheck.lua`

Update the local `extract_links()` function to preserve `block_id` and handle same-file refs:

**File:** `lua/andrew/vault/linkcheck.lua`

Replace the current `extract_links()` (lines 30-45) with:

```lua
--- Extract wikilink targets from a single line.
--- Returns full structured info: name, heading (if any), block_id (if any), and raw display.
---@param line string
---@return {name: string, heading: string|nil, block_id: string|nil, display: string}[]
local function extract_links(line)
  local links = {}
  for inner in line:gmatch("%[%[([^%]]+)%]%]") do
    -- Skip embed syntax ![[...]]
    local pos = line:find("%[%[" .. vim.pesc(inner) .. "%]%]")
    if pos and pos > 1 and line:sub(pos - 1, pos - 1) == "!" then
      goto continue
    end

    local parsed = link_utils.parse_target(inner)
    local name = parsed.name
    local heading = parsed.heading
    local block_id = parsed.block_id

    -- Build display string for diagnostics
    local display = name
    if heading then display = display .. "#" .. heading end
    if block_id then display = display .. "^" .. block_id end

    -- Include self-referencing links (name == "") if they have a heading or block_id
    if name ~= "" or heading or block_id then
      links[#links + 1] = {
        name = name,
        heading = heading,
        block_id = block_id,
        display = display,
      }
    end

    ::continue::
  end
  return links
end
```

Key changes:
- Preserves `block_id` from `parse_target()`.
- Includes self-referencing links (`name == ""`) when they have a `heading` or `block_id`.
- Builds `display` string including the `^blockid` suffix.
- Skips embed syntax `![[...]]` to avoid false positives on image embeds.

### Step 3: Add block ID scanning for current buffer

Add a helper to scan the current buffer for block IDs (for same-file refs):

**File:** `lua/andrew/vault/linkcheck.lua`

Add after the `extract_links()` function:

```lua
--- Scan buffer lines for block IDs, returning a set.
---@param lines string[]
---@return table<string, boolean>
local function scan_buffer_block_ids(lines)
  local ids = {}
  for _, line in ipairs(lines) do
    local id = line:match("%^([%w%-]+)%s*$")
    if id then
      ids[id] = true
    end
  end
  return ids
end
```

This uses the same pattern as `blockid.lua:existing_block_id()` (line 27) and `vault_index.lua:extract_block_ids()` (line 373).

### Step 4: Update `check_buffer()` to validate block refs

**File:** `lua/andrew/vault/linkcheck.lua`

Replace the `check_buffer()` function (lines 73-143) with updated logic that validates block IDs:

```lua
function M.check_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local broken = {}
  local total = 0
  local block_ref_count = 0
  local self_path = vim.api.nvim_buf_get_name(buf)

  -- Cache heading lookups per file to avoid re-reading
  local heading_cache = {}
  -- Cache block ID lookups per file
  local block_id_cache = {}
  local idx = vault_index.current()
  local use_idx = idx and idx._ready

  -- Pre-scan current buffer for same-file block ID validation
  local self_block_ids = scan_buffer_block_ids(lines)

  for i, line in ipairs(lines) do
    local links = extract_links(line)
    total = total + #links
    for _, link in ipairs(links) do
      if link.block_id then
        block_ref_count = block_ref_count + 1
      end

      -- Self-referencing link (name == "")
      if link.name == "" then
        if link.heading then
          -- Validate same-file heading (existing pattern)
          local slug_set
          if not heading_cache[self_path] then
            if use_idx then
              heading_cache[self_path] = idx:get_headings(self_path)
            else
              heading_cache[self_path] = link_utils.extract_headings(lines)
            end
          end
          slug_set = heading_cache[self_path]
          local anchor_slug = link_utils.heading_to_slug(link.heading)
          if not slug_set[anchor_slug] then
            broken[#broken + 1] = { lnum = i, display = link.display, kind = "heading" }
            goto next_link
          end
        end
        if link.block_id then
          if not self_block_ids[link.block_id] then
            broken[#broken + 1] = { lnum = i, display = link.display, kind = "block" }
          end
        end
        goto next_link
      end

      -- Cross-file link: check note existence first
      if not link_exists(link.name) then
        broken[#broken + 1] = { lnum = i, display = link.display, kind = "note" }
        goto next_link
      end

      -- Note exists; resolve filepath for heading/block validation
      local name_lower = link.name:lower()
      local filepath = get_note_path(name_lower)
      local self_name = vim.fn.fnamemodify(self_path, ":t:r"):lower()
      if name_lower == self_name then
        filepath = self_path
      end

      if filepath then
        -- Validate heading if present
        if link.heading then
          if not heading_cache[filepath] then
            if use_idx then
              heading_cache[filepath] = idx:get_headings(filepath)
            else
              heading_cache[filepath] = link_utils.extract_headings(filepath)
            end
          end
          local slug_set = heading_cache[filepath]
          local anchor_slug = link_utils.heading_to_slug(link.heading)
          if not slug_set[anchor_slug] then
            broken[#broken + 1] = { lnum = i, display = link.display, kind = "heading" }
            goto next_link
          end
        end

        -- Validate block ID if present
        if link.block_id then
          if not block_id_cache[filepath] then
            if filepath == self_path then
              block_id_cache[filepath] = self_block_ids
            elseif use_idx then
              block_id_cache[filepath] = idx:get_block_ids(filepath)
            else
              -- Fallback: read file and scan for block IDs
              local f = io.open(filepath, "r")
              if f then
                local content = f:read("*a")
                f:close()
                local ids = {}
                for id in content:gmatch("%^([%w%-]+)%s*\n") do
                  ids[id] = true
                end
                local last_id = content:match("%^([%w%-]+)%s*$")
                if last_id then ids[last_id] = true end
                block_id_cache[filepath] = ids
              else
                block_id_cache[filepath] = {}
              end
            end
          end
          if not block_id_cache[filepath][link.block_id] then
            broken[#broken + 1] = { lnum = i, display = link.display, kind = "block" }
          end
        end
      end

      ::next_link::
    end
  end

  if #broken == 0 then
    local msg = "Vault: all " .. total .. " links OK"
    if block_ref_count > 0 then
      msg = msg .. " (" .. block_ref_count .. " block ref" .. (block_ref_count ~= 1 and "s" or "") .. ")"
    end
    vim.notify(msg, vim.log.levels.INFO)
    return
  end

  local entries = {}
  for _, b in ipairs(broken) do
    local kind_label
    if b.kind == "heading" then
      kind_label = " (broken heading)"
    elseif b.kind == "block" then
      kind_label = " (broken block)"
    else
      kind_label = " (broken note)"
    end
    entries[#entries + 1] = string.format("%d: [[%s]]%s", b.lnum, b.display, kind_label)
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Broken links> ",
    actions = {
      ["default"] = function(selected)
        if selected[1] then
          local lnum = tonumber(selected[1]:match("^(%d+):"))
          if lnum then
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
          end
        end
      end,
    },
  })
end
```

### Step 5: Update `check_vault()` to validate block refs

**File:** `lua/andrew/vault/linkcheck.lua`

The vault-wide scan in `check_vault()` (lines 148-247) must also be updated. The key changes mirror `check_buffer()`:

Replace the inner parsing loop (lines 180-229) with logic that handles block IDs:

```lua
      -- Inside the vim.schedule callback, after existing heading_file_cache:
      local block_id_file_cache = {} -- filepath -> block_id_set

      for line in output:gmatch("[^\n]+") do
        -- rg output: /path/to/file.md:42:[[Link Target]]
        local file, lnum, match = line:match("^(.+):(%d+):%[%[(.+)%]%]$")
        if file and lnum and match then
          local parsed = link_utils.parse_target(match)
          local name = parsed.name
          local heading = parsed.heading
          local block_id = parsed.block_id

          -- Skip self-referencing links in vault-wide scan
          -- (they reference the same file, which we handle in check_buffer)
          if name == "" then goto next_match end

          total = total + 1

          -- Check note existence
          if resolved[name] == nil then
            resolved[name] = link_exists(name)
          end

          if not resolved[name] then
            local rel = file:sub(#engine.vault_path + 2)
            local display = name
            if heading then display = display .. "#" .. heading end
            if block_id then display = display .. "^" .. block_id end
            broken[#broken + 1] = string.format("%s:%s: [[%s]] (broken note)", rel, lnum, display)
          else
            local name_lower = name:lower()
            local filepath = get_note_path(name_lower)
            local self_name = vim.fn.fnamemodify(file, ":t:r"):lower()
            if name_lower == self_name then
              filepath = file
            end

            if filepath then
              -- Validate heading if present
              local heading_broken = false
              if heading then
                if not heading_file_cache[filepath] then
                  if use_idx then
                    heading_file_cache[filepath] = idx:get_headings(filepath)
                  else
                    heading_file_cache[filepath] = link_utils.extract_headings(filepath)
                  end
                end
                local slug_set = heading_file_cache[filepath]
                local anchor_slug = link_utils.heading_to_slug(heading)
                if not slug_set[anchor_slug] then
                  heading_broken = true
                  local rel = file:sub(#engine.vault_path + 2)
                  local display = name
                  if heading then display = display .. "#" .. heading end
                  if block_id then display = display .. "^" .. block_id end
                  broken[#broken + 1] = string.format(
                    "%s:%s: [[%s]] (broken heading)", rel, lnum, display
                  )
                end
              end

              -- Validate block ID if present (skip if heading already broken)
              if block_id and not heading_broken then
                if not block_id_file_cache[filepath] then
                  if use_idx then
                    block_id_file_cache[filepath] = idx:get_block_ids(filepath)
                  else
                    local fh = io.open(filepath, "r")
                    if fh then
                      local content = fh:read("*a")
                      fh:close()
                      local ids = {}
                      for id in content:gmatch("%^([%w%-]+)%s*\n") do
                        ids[id] = true
                      end
                      local last_id = content:match("%^([%w%-]+)%s*$")
                      if last_id then ids[last_id] = true end
                      block_id_file_cache[filepath] = ids
                    else
                      block_id_file_cache[filepath] = {}
                    end
                  end
                end
                if not block_id_file_cache[filepath][block_id] then
                  local rel = file:sub(#engine.vault_path + 2)
                  local display = name
                  if heading then display = display .. "#" .. heading end
                  if block_id then display = display .. "^" .. block_id end
                  broken[#broken + 1] = string.format(
                    "%s:%s: [[%s]] (broken block)", rel, lnum, display
                  )
                end
              end
            end
          end
        end
        ::next_match::
      end
```

### Step 6: Update ripgrep pattern for vault-wide scan

The current ripgrep pattern `\[\[[^\]]+\]\]` (line 157) does not match self-referencing links `[[^blockid]]` when they appear standalone, but this is acceptable for vault-wide scanning since self-refs are validated by `check_buffer()`. No change needed to the rg command.

However, the rg pattern also matches embed syntax `![[...]]`. The current code's `link_utils.parse_target()` handles this gracefully (images parse as a name, which fails `link_exists()` but isn't a meaningful false positive since the vault scan only shows actual broken links). For correctness, the rg match extraction should skip embeds:

```lua
        -- Skip embed links (![[...]])
        local prefix_check = line:match(":(%!?)%[%[")
        if prefix_check == "!" then goto next_match end
```

This is a minor correctness fix bundled into the same change.

---

## Testing

### Manual Verification

#### 1. Create test notes with block IDs

```markdown
<!-- TestNote.md -->
# Test Note

This is a paragraph with a block ID. ^blk-test01

Another paragraph. ^blk-test02
```

```markdown
<!-- LinkNote.md -->
# Link Note

Valid block ref: [[TestNote^blk-test01]]
Broken block ref: [[TestNote^blk-nonexistent]]
Broken note with block: [[FakeNote^blk-test01]]
Same-file block ref: [[^blk-local01]]
Valid same-file: [[^blk-local02]]

Local block. ^blk-local02
```

#### 2. Buffer check

Open `LinkNote.md` and run `:VaultLinkCheck`.

**Expected output (fzf picker):**
```
4: [[TestNote^blk-nonexistent]] (broken block)
5: [[FakeNote^blk-test01]] (broken note)
6: [[^blk-local01]] (broken block)
```

Lines 3 (`blk-test01` in `TestNote`) and 7 (`blk-local02` same-file) should pass validation.

#### 3. Vault-wide check

Run `:VaultLinkCheckAll`.

**Expected:** Broken block refs appear in the vault-wide fzf picker with grep-like format:
```
LinkNote.md:4: [[TestNote^blk-nonexistent]] (broken block)
LinkNote.md:5: [[FakeNote^blk-test01]] (broken note)
```

Same-file refs (`[[^blk-local01]]`) are not included in the vault-wide scan (they are validated by `check_buffer()` only, since rg matches them but `name == ""` causes them to be skipped).

#### 4. Statistics output

Run `:VaultLinkCheck` on a buffer with all valid links including block refs:

**Expected notification:**
```
Vault: all 5 links OK (2 block refs)
```

#### 5. Compound links

Test `[[TestNote#Test Note^blk-test01]]` -- should validate both the heading and the block ID.

Test `[[TestNote#Nonexistent^blk-test01]]` -- should report `(broken heading)` even though the block ID is valid.

### Performance Verification

Block ID lookup via vault index is O(1) per file (set construction from array) with caching across multiple lookups to the same file:

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.linkcheck").check_buffer(); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

**Target:** No measurable regression from current `check_buffer()` performance. The block ID set construction is negligible (typically 0-5 block IDs per file).

---

## Risks & Mitigations

### Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Block ID at end of file (no trailing newline) | Handled by `extract_block_ids()` in vault_index (lines 379-386) and the fallback scanner |
| Block ID inside fenced code block | vault_index `extract_block_ids()` does NOT filter code blocks (matches raw content). This is consistent with Obsidian behavior where block IDs in code blocks are still addressable |
| Block ID with only hyphens and letters `^my-block` | Matched by `[%w%-]+` pattern, same as `blockid.lua` |
| Block ID containing uppercase `^MyBlock` | Stored as-is in vault index; comparison is case-sensitive (matches Obsidian behavior) |
| Link with heading AND block ID `[[Note#H^blk]]` | Both validated; heading error takes precedence if both are broken |
| Self-referencing `[[^blockid]]` in vault-wide scan | Skipped (name == ""); validated only in buffer-local check |
| Vault index not ready | Falls back to file-reading scanner (same pattern as heading validation fallback) |
| Empty `block_ids` array in index entry | `get_block_ids()` returns empty set; all block refs report as broken |
| Same note referenced by basename and alias | `get_note_path()` resolves both to the same filepath; block ID cache is keyed by filepath so lookups are deduplicated |

### Backwards Compatibility

- **No breaking changes.** The `extract_links()` return type gains a `block_id` field; existing consumers only destructure `name`, `heading`, and `display`.
- **Statistics message changes.** The "all N links OK" message may now include a block ref count parenthetical. This is additive.
- **New diagnostic kind.** The fzf picker entries gain a `(broken block)` label alongside existing `(broken note)` and `(broken heading)`. The default action (jump to line) is unchanged.
- **New vault_index method.** `get_block_ids()` is additive; no existing callers are affected.

### Performance Impact

- **Block ID set construction** is O(k) where k is the number of block IDs in a file (typically 0-10). The set is cached per filepath within a single `check_buffer()` / `check_vault()` invocation.
- **Same-file block ID scan** adds one pass over the buffer lines at the start of `check_buffer()`. This is O(n) for n lines, identical cost to the existing line-by-line link extraction.
- **Vault-wide scan** adds block ID cache lookups using the vault index, which is already loaded. No additional filesystem I/O when the index is ready.

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/vault_index.lua` | Add `get_block_ids(abs_path)` query method |
| `lua/andrew/vault/linkcheck.lua` | Update `extract_links()` to preserve block_id; update `check_buffer()` and `check_vault()` to validate block refs; add `scan_buffer_block_ids()` helper; add block ref statistics |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `vault_index.lua` | `get_block_ids(abs_path)` for O(1) cross-file block ID lookup | Yes (with fallback) |
| `link_utils.lua` | `parse_target()` already returns `block_id` -- no changes needed | Yes (unchanged) |
| `engine.lua` | Vault path, `vault_fzf_opts()`, `vault_fzf_actions()` | Yes (unchanged) |
| `fzf-lua` | Picker UI for broken link results | Yes (unchanged) |
