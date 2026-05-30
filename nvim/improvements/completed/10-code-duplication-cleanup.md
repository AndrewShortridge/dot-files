# Code Duplication Cleanup: Heading Extraction & Block Ref Reading

## 1. Problem Statement

Two categories of content-extraction logic are duplicated across the vault module:

**Heading extraction** (reading headings from a markdown file and returning slug sets) is
implemented in 3 separate modules:

| Module | Function | Line Numbers | Notes |
|--------|----------|-------------|-------|
| `preview.lua` | `extract_heading_section()` | Lines 65-92 | Takes a lines array + heading text, returns section lines |
| `linkcheck.lua` | `extract_headings()` | Lines 19-33 | Reads file, returns `{slug_set, raw_headings}` |
| `linkdiag.lua` | `M.get_headings()` | Lines 29-60 | Same as linkcheck + mtime caching |

**Block ref reading** (finding a paragraph by `^block-id` and extracting it) is
implemented in 2 modules:

| Module | Function | Line Numbers | Notes |
|--------|----------|-------------|-------|
| `preview.lua` | `extract_block_content()` | Lines 98-130 | Takes lines array + block_id, returns paragraph lines |
| `link_utils.lua` | `M.read_block_content()` | Lines 160-194 | Takes source (path or lines array) + block_id |

Additionally, `preview.lua` has its own `extract_heading_section()` (lines 65-92) that
duplicates `link_utils.read_heading_section()` (lines 127-153), and its own
`read_file_lines()` (lines 135-146) that duplicates `engine.read_file_lines()` (line 199).

**Key insight**: `link_utils.lua` already has shared versions of both
`read_heading_section()` and `read_block_content()` that accept either a file path or a
lines array. The `preview.lua` copies are therefore completely redundant. Similarly,
`linkcheck.lua` and `linkdiag.lua` each have their own heading extraction that could be
consolidated.

---

## 2. Current Duplicated Code

### 2a. Heading Section Extraction (preview.lua vs link_utils.lua)

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/preview.lua` lines 65-92**
```lua
local function extract_heading_section(lines, heading)
  local target_slug = link_utils.heading_to_slug(heading)
  local result = {}
  local capturing = false
  local target_level = nil

  for _, line in ipairs(lines) do
    if capturing then
      local level_str = line:match("^(#+)%s+")
      if level_str and #level_str <= target_level then
        break
      end
      result[#result + 1] = line
    else
      local level_str, text = line:match("^(#+)%s+(.*)")
      if text then
        local slug = link_utils.heading_to_slug(text)
        if slug == target_slug then
          target_level = #level_str
          capturing = true
          result[#result + 1] = line
        end
      end
    end
  end

  return result
end
```

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/link_utils.lua` lines 127-153**
```lua
function M.read_heading_section(source, heading)
  local all_lines = read_all_lines(source)
  if not all_lines then return {} end

  local lines = {}
  local capturing = false
  local target_level = nil

  for _, line in ipairs(all_lines) do
    if capturing then
      local level_str = line:match("^(#+)%s+")
      if level_str and #level_str <= target_level then
        break
      end
      lines[#lines + 1] = line
    else
      local level_str, text = line:match("^(#+)%s+(.*)")
      if text and M.heading_to_slug(vim.trim(text)) == M.heading_to_slug(heading) then
        target_level = #level_str
        capturing = true
        lines[#lines + 1] = line
      end
    end
  end

  return lines
end
```

These are structurally identical. The `link_utils` version already accepts a lines array
via its `read_all_lines()` helper (line 108-120), so `preview.lua`'s version is fully
redundant.

### 2b. Block Content Extraction (preview.lua vs link_utils.lua)

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/preview.lua` lines 98-130**
```lua
local function extract_block_content(lines, block_id)
  local escaped = vim.pesc(block_id)
  local paragraphs = {}
  local current = {}

  for _, line in ipairs(lines) do
    if line:match("^%s*$") then
      if #current > 0 then
        paragraphs[#paragraphs + 1] = current
        current = {}
      end
    else
      current[#current + 1] = line
    end
  end
  if #current > 0 then
    paragraphs[#paragraphs + 1] = current
  end

  for _, para in ipairs(paragraphs) do
    for _, line in ipairs(para) do
      if line:match("%^" .. escaped .. "%s*$") then
        local result = {}
        for _, l in ipairs(para) do
          result[#result + 1] = l:gsub("%s*%^" .. escaped .. "%s*$", "")
        end
        return result
      end
    end
  end

  return {}
end
```

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/link_utils.lua` lines 160-194**
```lua
function M.read_block_content(source, block_id)
  local all_lines = read_all_lines(source)
  if not all_lines then return {} end

  local paragraphs = {}
  local current = {}
  for _, line in ipairs(all_lines) do
    if line:match("^%s*$") then
      if #current > 0 then
        paragraphs[#paragraphs + 1] = current
        current = {}
      end
    else
      current[#current + 1] = line
    end
  end
  if #current > 0 then
    paragraphs[#paragraphs + 1] = current
  end

  local escaped = vim.pesc(block_id)
  for _, para in ipairs(paragraphs) do
    for _, line in ipairs(para) do
      if line:match("%^" .. escaped .. "%s*$") then
        local result = {}
        for _, l in ipairs(para) do
          result[#result + 1] = l:gsub("%s*%^" .. escaped .. "%s*$", "")
        end
        return result
      end
    end
  end

  return {}
end
```

These are line-for-line identical in logic. The `link_utils` version already accepts a
lines array, making the `preview.lua` copy fully redundant.

### 2c. Heading Slug Set Extraction (linkcheck.lua vs linkdiag.lua)

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/linkcheck.lua` lines 19-33**
```lua
local function extract_headings(filepath)
  local slugs = {}
  local headings = {}
  local f = io.open(filepath, "r")
  if not f then return slugs, headings end
  for line in f:lines() do
    local heading_text = line:match("^#+%s+(.*)")
    if heading_text then
      heading_text = heading_text:gsub("%s+$", "")
      headings[#headings + 1] = heading_text
      slugs[link_utils.heading_to_slug(heading_text)] = true
    end
  end
  f:close()
  return slugs, headings
end
```

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/linkdiag.lua` lines 29-60**
```lua
function M.get_headings(filepath)
  local stat = vim.uv.fs_stat(filepath)
  if not stat then return {}, {} end

  local cached = M._heading_cache[filepath]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.slugs, cached.headings
  end

  local slugs = {}
  local headings = {}
  local f = io.open(filepath, "r")
  if not f then return {}, {} end

  for line in f:lines() do
    local heading_text = line:match("^#+%s+(.*)")
    if heading_text then
      -- Trim trailing whitespace
      heading_text = heading_text:gsub("%s+$", "")
      headings[#headings + 1] = heading_text
      slugs[link_utils.heading_to_slug(heading_text)] = true
    end
  end
  f:close()

  M._heading_cache[filepath] = {
    mtime = stat.mtime.sec,
    slugs = slugs,
    headings = headings,
  }
  return slugs, headings
end
```

The core heading-reading logic (lines 40-51 of linkdiag, lines 22-31 of linkcheck) is
identical. `linkdiag.lua` adds mtime caching on top. `linkcheck.lua` uses a per-call
`heading_cache` dict to avoid re-reading within a single scan but has no mtime-based
persistence.

### 2d. File Reading (preview.lua vs engine.lua)

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/preview.lua` lines 135-146**
```lua
local function read_file_lines(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local lines = {}
  for l in f:lines() do
    lines[#lines + 1] = l
  end
  f:close()
  return lines
end
```

This is functionally identical to `engine.read_file_lines()` (engine.lua line 199),
except `engine.read_file_lines` returns `{}` on failure while `preview.lua` returns `nil`.

---

## 3. Shared Module Design

The solution extends `link_utils.lua` with one new function (`extract_headings`) and
has all consumers use the existing `link_utils.read_heading_section()` and
`link_utils.read_block_content()`. No new module is needed.

### 3.1 New function: `link_utils.extract_headings(source)`

This consolidates the heading slug set extraction from linkcheck.lua and linkdiag.lua:

```lua
--- Extract all headings from a markdown source, returning both a slug lookup set
--- and an ordered list of raw heading texts.
--- @param source string|string[]  Absolute file path or array of lines
--- @return table<string, boolean> slug_set  Maps heading slugs to true
--- @return string[] raw_headings  Ordered list of heading texts (without # prefix)
function M.extract_headings(source)
  local all_lines = read_all_lines(source)
  if not all_lines then return {}, {} end

  local slugs = {}
  local headings = {}
  for _, line in ipairs(all_lines) do
    local heading_text = line:match("^#+%s+(.*)")
    if heading_text then
      heading_text = heading_text:gsub("%s+$", "")
      headings[#headings + 1] = heading_text
      slugs[M.heading_to_slug(heading_text)] = true
    end
  end
  return slugs, headings
end
```

**Design decisions:**
- Accepts `string|string[]` like the existing `read_heading_section` and
  `read_block_content`, so it works with both file paths and buffer lines.
- Returns the same `(slug_set, raw_headings)` tuple that both linkcheck and linkdiag
  currently return.
- Does NOT include mtime caching -- that is a concern of the caller (linkdiag.lua can
  wrap this with its own caching layer).

### 3.2 Existing functions already suitable

`link_utils.read_heading_section(source, heading)` and
`link_utils.read_block_content(source, block_id)` already accept `string|string[]` for
`source`, so `preview.lua` can call them directly with a lines array.

---

## 4. Where to Put Shared Code

**Extend `link_utils.lua`** -- do not create a new module.

Rationale:
- `link_utils.lua` already contains `read_heading_section()`, `read_block_content()`,
  `heading_to_slug()`, and `parse_target()` -- all the heading/block/link parsing
  primitives.
- Adding `extract_headings()` is a natural fit alongside those functions.
- All three consumer modules (`preview.lua`, `linkcheck.lua`, `linkdiag.lua`) already
  `require("andrew.vault.link_utils")`.
- Creating a separate module would add a new file without clear benefit.

---

## 5. Refactoring Plan

### Step 1: Add `extract_headings()` to link_utils.lua

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/link_utils.lua`**

Insert after `read_block_content()` (after line 194), before the final `return M`:

```lua
--- Extract all headings from a markdown source.
--- Returns both a slug lookup set and an ordered list of raw heading texts.
--- @param source string|string[]  Absolute file path or array of lines
--- @return table<string, boolean> slug_set  Maps heading slugs to true
--- @return string[] raw_headings  Ordered list of heading texts (without # prefix)
function M.extract_headings(source)
  local all_lines = read_all_lines(source)
  if not all_lines then return {}, {} end

  local slugs = {}
  local headings = {}
  for _, line in ipairs(all_lines) do
    local heading_text = line:match("^#+%s+(.*)")
    if heading_text then
      heading_text = heading_text:gsub("%s+$", "")
      headings[#headings + 1] = heading_text
      slugs[M.heading_to_slug(heading_text)] = true
    end
  end
  return slugs, headings
end
```

### Step 2: Update preview.lua -- remove 3 local functions, use link_utils

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/preview.lua`**

**Delete** the following local functions entirely:
- `extract_heading_section` (lines 65-92, 28 lines)
- `extract_block_content` (lines 98-130, 33 lines)
- `read_file_lines` (lines 135-146, 12 lines)

**Replace** all call sites in `M.preview()`:

Before (lines 169-177, same-file heading/block):
```lua
    if details.heading then
      all_lines = extract_heading_section(buf_lines, details.heading)
      ...
    elseif details.block_id then
      all_lines = extract_block_content(buf_lines, details.block_id)
```

After:
```lua
    if details.heading then
      all_lines = link_utils.read_heading_section(buf_lines, details.heading)
      ...
    elseif details.block_id then
      all_lines = link_utils.read_block_content(buf_lines, details.block_id)
```

Before (lines 191-204, cross-file with file reading):
```lua
      local file_lines = read_file_lines(path)
      if file_lines then
        if details.heading then
          all_lines = extract_heading_section(file_lines, details.heading)
          ...
        elseif details.block_id then
          all_lines = extract_block_content(file_lines, details.block_id)
          ...
        else
          all_lines = file_lines
        end
      else
        all_lines = { "[Could not read file]" }
      end
```

After (using `link_utils` which accepts a path directly):
```lua
      if details.heading then
        all_lines = link_utils.read_heading_section(path, details.heading)
        title = details.name .. "#" .. details.heading
        if #all_lines == 0 then
          all_lines = { "[Heading not found: #" .. details.heading .. "]" }
        end
      elseif details.block_id then
        all_lines = link_utils.read_block_content(path, details.block_id)
        title = details.name .. "^" .. details.block_id
        if #all_lines == 0 then
          all_lines = { "[Block not found: ^" .. details.block_id .. "]" }
        end
      else
        all_lines = engine.read_file_lines(path)
        if #all_lines == 0 then
          all_lines = { "[Could not read file]" }
        end
      end
```

Note: For the full-note case, use `engine.read_file_lines(path)` which already exists
and returns `{}` on failure. The `preview.lua` `read_file_lines` returns `nil` on
failure, but the new code uses `#all_lines == 0` which handles both `{}` from engine
and the case where the file is empty.

The `require("andrew.vault.engine")` import is already at the top of preview.lua
(line 1). No new requires needed.

### Step 3: Update linkcheck.lua -- replace local `extract_headings` with link_utils call

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/linkcheck.lua`**

**Delete** the local `extract_headings` function (lines 19-33, 15 lines).

**Replace** all call sites. There are two:

1. `check_buffer()` line 94:
   ```lua
   -- Before:
   heading_cache[filepath] = extract_headings(filepath)
   -- After:
   heading_cache[filepath] = { link_utils.extract_headings(filepath) }
   ```
   And the consumer at line 96:
   ```lua
   -- Before:
   local slug_set = heading_cache[filepath]
   -- After:
   local slug_set = heading_cache[filepath][1]
   ```

   **Alternatively** (simpler, recommended): Keep the same caching pattern but assign
   both returns:
   ```lua
   -- Before:
   if not heading_cache[filepath] then
     heading_cache[filepath] = extract_headings(filepath)
   end
   local slug_set = heading_cache[filepath]

   -- After:
   if not heading_cache[filepath] then
     local slugs = link_utils.extract_headings(filepath)
     heading_cache[filepath] = slugs
   end
   local slug_set = heading_cache[filepath]
   ```
   This works because `extract_headings()` returns `(slug_set, headings)` and
   `linkcheck.lua` only needs the slug set. Discarding the second return is fine.

2. `check_vault()` line 197:
   ```lua
   -- Before:
   if not heading_file_cache[filepath] then
     heading_file_cache[filepath] = extract_headings(filepath)
   end
   local slug_set = heading_file_cache[filepath]

   -- After:
   if not heading_file_cache[filepath] then
     local slugs = link_utils.extract_headings(filepath)
     heading_file_cache[filepath] = slugs
   end
   local slug_set = heading_file_cache[filepath]
   ```

### Step 4: Update linkdiag.lua -- simplify `get_headings` to use link_utils

**File: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/linkdiag.lua`**

Replace the core of `M.get_headings()` (lines 29-60) with a call to
`link_utils.extract_headings()`, keeping the mtime caching wrapper:

```lua
function M.get_headings(filepath)
  local stat = vim.uv.fs_stat(filepath)
  if not stat then return {}, {} end

  local cached = M._heading_cache[filepath]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.slugs, cached.headings
  end

  local slugs, headings = link_utils.extract_headings(filepath)

  M._heading_cache[filepath] = {
    mtime = stat.mtime.sec,
    slugs = slugs,
    headings = headings,
  }
  return slugs, headings
end
```

This reduces the function from 32 lines to 16 lines, eliminating the duplicated
`io.open` / line-reading / heading-parsing logic while preserving the mtime cache
behavior.

---

## 6. Relationship to Existing Refactoring Plan

This cleanup directly implements parts of three features from the 17-step plan in
`/home/andrew-cmmg/.config/nvim/docs/refactor/README.md`:

| Refactor Plan Feature | Overlap | Status |
|----------------------|---------|--------|
| **Feature 07** (`heading_to_slug`) | Already done -- `link_utils.heading_to_slug()` exists at line 73 and all consumers already use it. The duplication described in Feature 07's doc has been resolved. |
| **Feature 09** (`read_heading_section` / `read_block_content`) | Partially done -- `link_utils.lua` already has both functions (lines 127, 160). `embed.lua` and `export.lua` already use them. **But `preview.lua` still has its own copies.** This cleanup finishes Feature 09. |
| **Feature 02** (`engine.read_file`) | Related -- `preview.lua` has a redundant `read_file_lines()` that duplicates `engine.read_file_lines()`. This cleanup removes it. |

### What the existing plan missed

The 17-step plan (Feature 09) focused on `embed.lua` and `export.lua` as the two files
with duplicated content extraction. It did not identify `preview.lua` as a third copy,
likely because `preview.lua`'s functions are named differently (`extract_heading_section`
vs `read_heading_section`) and operate on in-memory lines rather than file paths. However,
since `link_utils.lua`'s versions now accept `string|string[]`, the `preview.lua` copies
are fully redundant.

The 17-step plan also did not identify the heading slug-set extraction duplication between
`linkcheck.lua` and `linkdiag.lua` as a separate consolidation target. This is a distinct
kind of duplication (extracting all headings from a file as a set, rather than extracting
the content under a specific heading).

### Sequencing

This cleanup has **no blockers** from the existing plan:
- Feature 06 (link_utils module + parse_target): Already implemented.
- Feature 07 (heading_to_slug): Already implemented.
- Feature 09 (read_heading_section / read_block_content): Partially implemented. This
  cleanup finishes it.
- Feature 02 (engine.read_file): Independent. The `preview.lua` read_file_lines removal
  uses `engine.read_file_lines` which already exists.

---

## 7. Full Code

### 7.1 link_utils.lua -- add `extract_headings()`

The full updated file. Only the addition is shown as a diff; the rest is unchanged.

```diff
--- a/lua/andrew/vault/link_utils.lua
+++ b/lua/andrew/vault/link_utils.lua
@@ -192,4 +192,23 @@ function M.read_block_content(source, block_id)
   return {}
 end

+--- Extract all headings from a markdown source.
+--- Returns both a slug lookup set and an ordered list of raw heading texts.
+--- @param source string|string[]  Absolute file path or array of lines
+--- @return table<string, boolean> slug_set  Maps heading slugs to true
+--- @return string[] raw_headings  Ordered list of heading texts (without # prefix)
+function M.extract_headings(source)
+  local all_lines = read_all_lines(source)
+  if not all_lines then return {}, {} end
+
+  local slugs = {}
+  local headings = {}
+  for _, line in ipairs(all_lines) do
+    local heading_text = line:match("^#+%s+(.*)")
+    if heading_text then
+      heading_text = heading_text:gsub("%s+$", "")
+      headings[#headings + 1] = heading_text
+      slugs[M.heading_to_slug(heading_text)] = true
+    end
+  end
+  return slugs, headings
+end
+
 return M
```

### 7.2 preview.lua -- full updated file

```lua
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")
local wikilinks = require("andrew.vault.wikilinks")

local M = {}

-- Pre-compute terminal keycodes for scrolling
local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
local ctrl_y = vim.api.nvim_replace_termcodes("<C-y>", true, false, true)

-- Active preview state
local state = {
  win = nil,
  buf = nil,
  parent_buf = nil,
  augroup = nil,
}

--- Close the active preview and clean up keymaps/autocmds.
local function close_preview()
  -- Remove parent buffer scroll keymaps
  if state.parent_buf and vim.api.nvim_buf_is_valid(state.parent_buf) then
    for _, key in ipairs({ "<C-j>", "<C-k>" }) do
      pcall(vim.keymap.del, "n", key, { buffer = state.parent_buf })
    end
  end
  -- Clear autocmds
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  state.parent_buf = nil
end

--- Check if a preview is currently active.
local function is_active()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- Scroll the preview window by delta lines.
---@param delta number positive = down, negative = up
local function scroll_preview(delta)
  if not is_active() then
    return
  end
  local count = math.abs(delta)
  local key = delta > 0 and ctrl_e or ctrl_y
  vim.fn.win_execute(state.win, "normal! " .. count .. key)
end

--- Show a floating preview of the note linked under the cursor.
--- Supports same-file heading/block references: [[#Heading]], [[^block-id]]
--- Press K again or move the cursor to close. C-j/C-k scroll the preview.
function M.preview()
  -- Toggle off if already showing
  if is_active() then
    close_preview()
    return
  end

  local details = link_utils.get_wikilink_under_cursor()
  if not details then
    vim.notify("No wikilink under cursor", vim.log.levels.INFO)
    return
  end

  local all_lines
  local title

  if details.name == "" then
    -- Same-file reference: [[#heading]] or [[^block-id]]
    local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if details.heading then
      all_lines = link_utils.read_heading_section(buf_lines, details.heading)
      title = "#" .. details.heading
      if #all_lines == 0 then
        all_lines = { "[Heading not found: #" .. details.heading .. "]" }
      end
    elseif details.block_id then
      all_lines = link_utils.read_block_content(buf_lines, details.block_id)
      title = "^" .. details.block_id
      if #all_lines == 0 then
        all_lines = { "[Block not found: ^" .. details.block_id .. "]" }
      end
    else
      vim.notify("No wikilink under cursor", vim.log.levels.INFO)
      return
    end
  else
    -- Cross-file reference
    title = details.name
    local path = wikilinks.resolve_link(details.name)
    if path then
      if details.heading then
        all_lines = link_utils.read_heading_section(path, details.heading)
        title = details.name .. "#" .. details.heading
        if #all_lines == 0 then
          all_lines = { "[Heading not found: #" .. details.heading .. "]" }
        end
      elseif details.block_id then
        all_lines = link_utils.read_block_content(path, details.block_id)
        title = details.name .. "^" .. details.block_id
        if #all_lines == 0 then
          all_lines = { "[Block not found: ^" .. details.block_id .. "]" }
        end
      else
        all_lines = engine.read_file_lines(path)
        if #all_lines == 0 then
          all_lines = { "[Could not read file]" }
        end
      end
    else
      all_lines = { "[Note does not exist yet]" }
    end
  end

  -- Compute float dimensions
  local max_width = config.preview.max_width
  local max_height = config.preview.max_lines
  local width = 0
  for _, l in ipairs(all_lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width, 20), max_width)
  local height = math.min(#all_lines, max_height)

  -- Create buffer with content (enables scrolling)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].bufhidden = "wipe"

  -- Open floating window near cursor (not focused -- stays in parent)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = { { " " .. title .. " ", "Function" } },
    title_pos = "center",
  })

  -- Window options: enable render-markdown rendering and readable wrapping
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].foldenable = false

  -- Set filetype AFTER window exists so render-markdown can find the buffer
  -- in a valid window context during its FileType autocmd handler
  vim.bo[buf].filetype = "markdown"

  -- Explicitly start treesitter for the scratch buffer
  pcall(vim.treesitter.start, buf, "markdown")

  -- Manually trigger render-markdown since the float is not focused and
  -- normal render events (BufWinEnter, CursorMoved, etc.) won't fire
  pcall(function()
    require("render-markdown").render({ buf = buf, win = win })
  end)

  -- Lock buffer after all rendering setup is complete
  vim.bo[buf].modifiable = false

  -- Store state
  state.win = win
  state.buf = buf
  state.parent_buf = vim.api.nvim_get_current_buf()

  -- Scroll keymaps on the PARENT buffer (C-j/C-k don't move cursor, so
  -- CursorMoved won't fire and the preview stays open while scrolling)
  local scroll_amount = 3
  vim.keymap.set("n", "<C-j>", function()
    scroll_preview(scroll_amount)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview down" })
  vim.keymap.set("n", "<C-k>", function()
    scroll_preview(-scroll_amount)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview up" })

  -- Auto-close on cursor move or leaving the buffer
  state.augroup = vim.api.nvim_create_augroup("VaultPreviewClose", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = state.augroup,
    buffer = state.parent_buf,
    once = true,
    callback = close_preview,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = state.augroup,
    buffer = state.parent_buf,
    once = true,
    callback = close_preview,
  })
end

--- Open the linked note under the cursor in an editable floating window.
function M.edit_link()
  local details = link_utils.get_wikilink_under_cursor()
  if not details or details.name == "" then
    vim.notify("No cross-file wikilink under cursor", vim.log.levels.INFO)
    return
  end

  local link = details.name
  local path = wikilinks.resolve_link(link)
  if not path then
    vim.notify("Note not found: " .. link, vim.log.levels.WARN)
    return
  end

  -- Compute float dimensions: 80% width, 60% height, centered
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local width = math.floor(editor_width * 0.8)
  local height = math.floor(editor_height * 0.6)
  local row = math.floor((editor_height - height) / 2)
  local col = math.floor((editor_width - width) / 2)

  -- Open (or reuse) the buffer for the file
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)

  -- Open focused floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    title = { { " " .. link .. " ", "Function" } },
    title_pos = "center",
  })

  -- Buffer options
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")

  -- Window options
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].foldenable = false
  vim.wo[win].winhighlight = "Normal:Normal,FloatBorder:FloatBorder"

  -- Helper to save and close the float
  local function save_and_close()
    if vim.api.nvim_buf_get_option(buf, "modified") then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, false)
    end
  end

  -- Keymaps inside the float
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", save_and_close, vim.tbl_extend("force", opts, { desc = "Save and close float" }))
  vim.keymap.set("n", "<Esc><Esc>", save_and_close, vim.tbl_extend("force", opts, { desc = "Save and close float" }))
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
  end, vim.tbl_extend("force", opts, { desc = "Save float buffer" }))

  -- Auto-save on WinClosed
  local augroup = vim.api.nvim_create_augroup("VaultEditFloat_" .. win, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "modified") then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("silent write")
        end)
      end
      pcall(vim.api.nvim_del_augroup_by_id, augroup)
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("VaultPreview", function()
    M.preview()
  end, { desc = "Vault: preview wikilink under cursor" })

  local group = vim.api.nvim_create_augroup("VaultPreview", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "K", function()
        M.preview()
      end, { buffer = ev.buf, desc = "Vault: preview link", silent = true })
      vim.keymap.set("n", "<leader>vE", function()
        M.edit_link()
      end, { buffer = ev.buf, desc = "Vault: edit link in float", silent = true })
    end,
  })
end

return M
```

### 7.3 linkcheck.lua -- updated `extract_headings` call sites

```diff
--- a/lua/andrew/vault/linkcheck.lua
+++ b/lua/andrew/vault/linkcheck.lua
@@ -16,20 +16,6 @@ local function get_note_path(name_lower)
   return cache.paths[name_lower] or cache.paths[basename]
 end

---- Read headings from a file and return slug set + raw heading list.
----@param filepath string
----@return table<string, boolean> slug_set
----@return string[] raw_headings
-local function extract_headings(filepath)
-  local slugs = {}
-  local headings = {}
-  local f = io.open(filepath, "r")
-  if not f then return slugs, headings end
-  for line in f:lines() do
-    local heading_text = line:match("^#+%s+(.*)")
-    if heading_text then
-      heading_text = heading_text:gsub("%s+$", "")
-      headings[#headings + 1] = heading_text
-      slugs[link_utils.heading_to_slug(heading_text)] = true
-    end
-  end
-  f:close()
-  return slugs, headings
-end
-
 --- Extract wikilink targets from a single line.
 --- Returns full structured info: name, heading (if any), and raw display.
 ---@param line string
@@ -91,7 +77,8 @@ function M.check_buffer()
         if name_lower == self_name then
           filepath = self_path
         end
         if filepath then
-          if not heading_cache[filepath] then
-            heading_cache[filepath] = extract_headings(filepath)
+          if not heading_cache[filepath] then
+            local slugs = link_utils.extract_headings(filepath)
+            heading_cache[filepath] = slugs
           end
           local slug_set = heading_cache[filepath]
@@ -194,8 +181,9 @@ function M.check_vault()
           if name_lower == self_name then
             filepath = file
           end
           if filepath then
-            if not heading_file_cache[filepath] then
-              heading_file_cache[filepath] = extract_headings(filepath)
+            if not heading_file_cache[filepath] then
+              local slugs = link_utils.extract_headings(filepath)
+              heading_file_cache[filepath] = slugs
             end
             local slug_set = heading_file_cache[filepath]
```

### 7.4 linkdiag.lua -- simplified `get_headings()`

```diff
--- a/lua/andrew/vault/linkdiag.lua
+++ b/lua/andrew/vault/linkdiag.lua
@@ -29,28 +29,13 @@ function M.get_headings(filepath)
   if not stat then return {}, {} end

   local cached = M._heading_cache[filepath]
   if cached and cached.mtime == stat.mtime.sec then
     return cached.slugs, cached.headings
   end

-  local slugs = {}
-  local headings = {}
-  local f = io.open(filepath, "r")
-  if not f then return {}, {} end
-
-  for line in f:lines() do
-    local heading_text = line:match("^#+%s+(.*)")
-    if heading_text then
-      -- Trim trailing whitespace
-      heading_text = heading_text:gsub("%s+$", "")
-      headings[#headings + 1] = heading_text
-      slugs[link_utils.heading_to_slug(heading_text)] = true
-    end
-  end
-  f:close()
+  local slugs, headings = link_utils.extract_headings(filepath)

   M._heading_cache[filepath] = {
     mtime = stat.mtime.sec,
     slugs = slugs,
     headings = headings,
   }
   return slugs, headings
```

---

## 8. Testing

### 8.1 Heading Section Extraction (preview.lua changes)

1. **Same-file heading preview**: Open a vault markdown file. Place cursor on
   `[[#Some Heading]]` and press `K`. Verify the floating preview shows the correct
   section content under that heading.

2. **Cross-file heading preview**: Place cursor on `[[OtherNote#Section]]` and press `K`.
   Verify the correct section from OtherNote.md appears.

3. **Broken heading preview**: Place cursor on `[[#NonExistent]]` and press `K`. Verify
   the preview shows `[Heading not found: #NonExistent]`.

4. **Nested heading boundary**: Create a test file with:
   ```markdown
   ## Parent
   Content under parent.
   ### Child
   Content under child.
   ## Sibling
   Content under sibling.
   ```
   Preview `[[#Parent]]` and verify it includes the `### Child` section but stops before
   `## Sibling`.

### 8.2 Block Content Extraction (preview.lua changes)

5. **Same-file block preview**: Place cursor on `[[^blk-abc123]]` and press `K`. Verify
   the paragraph containing that block ID appears, with the `^blk-abc123` marker stripped.

6. **Cross-file block preview**: Place cursor on `[[OtherNote^blk-xyz]]` and press `K`.
   Verify the correct paragraph from OtherNote.md appears.

7. **Broken block preview**: Place cursor on `[[^nonexistent]]` and press `K`. Verify
   `[Block not found: ^nonexistent]` message.

### 8.3 Full Note Preview (read_file_lines removal)

8. **Full note preview**: Place cursor on `[[SomeNote]]` (no heading/block) and press `K`.
   Verify all lines of SomeNote.md appear in the preview float.

9. **Missing note preview**: Place cursor on `[[DoesNotExist]]` and press `K`. Verify
   `[Note does not exist yet]` message.

### 8.4 Heading Slug Set Extraction (linkcheck.lua and linkdiag.lua changes)

10. **Buffer link check**: Run `:VaultLinkCheck` on a file with both valid and broken
    heading links (e.g., `[[Note#ValidHeading]]` and `[[Note#BrokenHeading]]`). Verify
    broken headings are detected and valid ones pass.

11. **Vault-wide link check**: Run `:VaultLinkCheckAll`. Verify the same broken/valid
    classification as before the refactor.

12. **Live diagnostics**: Open a vault file with broken heading links. Verify diagnostic
    underlines appear under broken heading anchors (WARN severity) as before.

13. **Code actions**: Place cursor on a broken heading diagnostic and run the code action
    (`<leader>vcf`). Verify suggestions for closest matching headings still appear.

14. **Heading cache invalidation**: Edit a file to add a new heading, save, then run
    `:VaultLinkDiag`. Verify the new heading is recognized (the mtime cache in
    linkdiag.lua should invalidate).

### 8.5 Embed System (verify no regression)

15. **Note embed rendering**: Open a file with `![[SomeNote#Heading]]` and
    `![[SomeNote^block]]`. Run `:VaultEmbedRender`. Verify content appears as virtual
    text (this should be unaffected since embed.lua already uses link_utils).

16. **Export**: Run `:VaultExport html` on a file with embeds. Verify heading sections and
    block refs are inlined correctly (this should be unaffected since export.lua already
    uses link_utils).

### 8.6 Automated Smoke Test (optional)

A minimal Lua script that can be run with `nvim --headless`:

```lua
-- Run with: nvim --headless -u NONE -c "lua dofile('test_dedup.lua')" -c "qa!"
-- Place in the vault root or adjust paths.

local link_utils = dofile(vim.fn.expand("~/.config/nvim/lua/andrew/vault/link_utils.lua"))

-- Test extract_headings
local test_lines = {
  "# Top Level",
  "Some content.",
  "## Sub Heading",
  "More content.",
  "### Deep",
  "Deep content.",
  "## Another Sub",
  "Final.",
}

local slugs, headings = link_utils.extract_headings(test_lines)
assert(slugs["top-level"], "should find top-level slug")
assert(slugs["sub-heading"], "should find sub-heading slug")
assert(slugs["deep"], "should find deep slug")
assert(slugs["another-sub"], "should find another-sub slug")
assert(#headings == 4, "should have 4 headings, got " .. #headings)

-- Test read_heading_section with lines array
local section = link_utils.read_heading_section(test_lines, "Sub Heading")
assert(#section >= 3, "section should include Sub Heading + content + ### Deep lines")
assert(section[1]:match("## Sub Heading"), "first line should be the heading")

-- Test read_block_content with lines array
local block_lines = {
  "First paragraph.",
  "",
  "Second paragraph with ref. ^blk-test",
  "",
  "Third paragraph.",
}
local block = link_utils.read_block_content(block_lines, "blk-test")
assert(#block == 1, "should extract one line, got " .. #block)
assert(not block[1]:match("%^blk%-test"), "block id should be stripped")

print("All dedup tests passed.")
```

---

## Summary of Changes

| File | Change | Lines Removed | Lines Added | Net |
|------|--------|:------------:|:-----------:|:---:|
| `link_utils.lua` | Add `extract_headings()` | 0 | 19 | +19 |
| `preview.lua` | Delete 3 local functions, update call sites | 73 | 9 | -64 |
| `linkcheck.lua` | Delete `extract_headings()`, update 2 call sites | 15 | 4 | -11 |
| `linkdiag.lua` | Simplify `get_headings()` core | 13 | 1 | -12 |
| **Total** | | **101** | **33** | **-68** |

The refactoring removes 68 net lines of duplicated code while centralizing all
heading/block content extraction logic in `link_utils.lua`, making future changes to
heading matching or block extraction a single-point edit.
