# 19 — Inline Tag Highlighting

## Problem

The vault uses inline `#tags` and frontmatter `tags:` lists extensively for note categorization and retrieval. The `tags.lua` module handles tag collection, search, and modification via ripgrep — but there is **no visual distinction** for inline tags in the buffer.

Tags like `#project/simulation`, `#status/active`, or `#methodology` appear as plain text, indistinguishable from headings (`# Heading`) or comments. This makes tags:

1. **Hard to spot** when scanning a note — no color or style difference from surrounding text.
2. **Ambiguous** — readers must mentally distinguish `#tag` (metadata) from `# Heading` (structure).
3. **Non-navigable** — no visual cues indicate which words are tags vs. prose.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **tags.lua** | Collects tags via ripgrep, searches, adds/removes tags | `lua/andrew/vault/tags.lua` |
| **Treesitter** | No `tag` node type in `markdown_inline` — tags are just `(inline (text))` | `markdown_inline` parser |
| **render-markdown.nvim** | No tag rendering support | `render-markdown.lua` |
| **ftplugin/markdown.lua** | No tag-related highlights or motions | `ftplugin/markdown.lua` |

### Why Treesitter Queries Cannot Help

The `markdown_inline` parser has no concept of "tags." Inline text like `#project` is parsed as a plain `(text)` node. While a treesitter query could use `#match?` predicates on text nodes:

```scheme
; This would match ALL text starting with # — including headings and other patterns
((text) @tag (#match? @tag "^#[a-zA-Z]"))
```

This approach has critical limitations:
- Cannot distinguish `#tag` from `#Heading` (headings are in `(atx_heading)` in the `markdown` parser, but inline `#` in paragraphs is just text in `markdown_inline`).
- Cannot exclude tags inside code spans or code blocks.
- Cannot apply different highlights to different tag categories.
- No access to the tag registry (can't validate if a tag is "known").

**Conclusion**: An extmark-based Lua module is required.

---

## Goal

Add inline tag highlighting so that:

1. Inline `#tags` are visually distinct from surrounding text (colored, optionally bold/italic).
2. Tags in different categories get different colors (e.g., `#project/*` in blue, `#status/*` in green).
3. Tags inside code blocks and code spans are **not** highlighted (false positive prevention).
4. Tags in frontmatter `tags:` lists are highlighted (optional, lower priority).
5. Highlighting is performant — debounced, handles buffers with 100+ tags.
6. Users can customize tag category colors via config.

---

## Approach

### Architecture

Create a new module `lua/andrew/vault/tag_highlights.lua` that:

1. Scans buffer lines for inline `#tag` patterns (matching `tags.lua`'s regex).
2. Filters out false positives (headings, code blocks, code spans, URLs with fragments).
3. Applies extmarks with highlight groups based on tag category.
4. Runs on `BufEnter`, `TextChanged`, `TextChangedI` (debounced 200ms).
5. Uses treesitter to detect code blocks/spans for exclusion.

### Tag Pattern

Must match the same pattern as `tags.lua` uses for ripgrep:

```
(?:^|\s)#([a-zA-Z][a-zA-Z0-9_/-]+)
```

Lua equivalent:

```lua
-- Match #tag preceded by whitespace or start of line
-- Tag must start with a letter, then allow letters, digits, _, /, -
local TAG_PATTERN = "()#([a-zA-Z][a-zA-Z0-9_/-]+)"
```

### False Positive Filters

| Pattern | Why It's Not a Tag | Detection Method |
|---------|-------------------|------------------|
| `# Heading` | ATX heading (has space after `#`) | Regex: `^#+%s` |
| `##`, `###`, etc. | Multi-level headings | Regex: `^#+%s` |
| `` `#channel` `` | Inside inline code span | Treesitter: `code_span` node range |
| ```` ```\n#include\n``` ```` | Inside fenced code block | Treesitter: `fenced_code_block` node range |
| `https://url#fragment` | URL fragment identifier | Regex: preceded by alphanumeric, `/`, or `.` |
| `color: #ff0000` | CSS hex color | Regex: `#[0-9a-fA-F]{3,8}` |
| YAML frontmatter `tags:` | Handled separately (optional) | Line range: between `---` delimiters |

### Highlight Groups

| Group | Applies To | Default Style |
|-------|-----------|---------------|
| `VaultTag` | Default tag highlight | `fg = #c678dd` (purple), `bold = true` |
| `VaultTagProject` | Tags starting with `project/` | `fg = #61afef` (blue), `bold = true` |
| `VaultTagStatus` | Tags starting with `status/` | `fg = #98c379` (green), `bold = true` |
| `VaultTagType` | Tags starting with `type/` | `fg = #e5c07b` (yellow), `bold = true` |
| `VaultTagPerson` | Tags starting with `person/` | `fg = #56b6c2` (cyan), `bold = true` |
| `VaultTagHash` | The `#` prefix character | `fg = #5c6370` (gray) |

Colors are from the OneDarkPro palette.

### Category Mapping

Configurable via `config.lua`:

```lua
tag_categories = {
  { prefix = "project/",  highlight = "VaultTagProject" },
  { prefix = "status/",   highlight = "VaultTagStatus" },
  { prefix = "type/",     highlight = "VaultTagType" },
  { prefix = "person/",   highlight = "VaultTagPerson" },
  -- Default for unmatched tags: "VaultTag"
},
```

---

## Implementation

### File: `lua/andrew/vault/tag_highlights.lua`

```lua
local engine = require("andrew.vault.engine")

local M = {}

M.enabled = true
M.ns = vim.api.nvim_create_namespace("vault_tag_hl")

---@type uv.uv_timer_t|nil
local timer = nil
local DEBOUNCE_MS = 200

-- ---------------------------------------------------------------------------
-- Tag pattern (matches tags.lua ripgrep pattern)
-- ---------------------------------------------------------------------------

--- Check if a character at position is a valid tag predecessor.
--- Tags must be preceded by whitespace, start of line, or certain punctuation.
---@param line string
---@param pos number 1-indexed position of the `#`
---@return boolean
local function valid_tag_start(line, pos)
  if pos == 1 then return true end
  local prev = line:sub(pos - 1, pos - 1)
  -- Whitespace, parentheses, brackets, or start of YAML list item
  return prev:match("[%s%(%)%[%]{},;:\"']") ~= nil
end

--- Check if a tag-like match is actually a CSS hex color.
---@param tag string the text after #
---@return boolean
local function is_hex_color(tag)
  return tag:match("^[0-9a-fA-F]+$") ~= nil and (#tag == 3 or #tag == 6 or #tag == 8)
end

-- ---------------------------------------------------------------------------
-- Code block / code span detection via treesitter
-- ---------------------------------------------------------------------------

--- Build a set of line ranges that are inside code blocks or code spans.
--- Returns a function: is_in_code(row, col) -> boolean
---@param bufnr number
---@return fun(row: number, col: number): boolean
local function build_code_exclusion(bufnr)
  local ranges = {}

  -- Try treesitter first (most accurate)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if ok and parser then
    local tree = parser:parse()[1]
    if tree then
      local root = tree:root()

      -- Find fenced_code_block nodes
      local query_str = "(fenced_code_block) @code"
      local query_ok, query = pcall(vim.treesitter.query.parse, "markdown", query_str)
      if query_ok and query then
        for _, node in query:iter_captures(root, bufnr, 0, -1) do
          local sr, sc, er, ec = node:range()
          ranges[#ranges + 1] = { sr, sc, er, ec }
        end
      end

      -- Find indented_code_block nodes
      local iq_str = "(indented_code_block) @code"
      local iq_ok, iq = pcall(vim.treesitter.query.parse, "markdown", iq_str)
      if iq_ok and iq then
        for _, node in iq:iter_captures(root, bufnr, 0, -1) do
          local sr, sc, er, ec = node:range()
          ranges[#ranges + 1] = { sr, sc, er, ec }
        end
      end
    end
  end

  -- Also get inline code spans from markdown_inline parser
  local iok, iparser = pcall(vim.treesitter.get_parser, bufnr, "markdown_inline")
  if iok and iparser then
    local itrees = iparser:parse()
    for _, itree in ipairs(itrees) do
      local iroot = itree:root()
      local cs_str = "(code_span) @code"
      local cs_ok, cs_query = pcall(vim.treesitter.query.parse, "markdown_inline", cs_str)
      if cs_ok and cs_query then
        for _, node in cs_query:iter_captures(iroot, bufnr, 0, -1) do
          local sr, sc, er, ec = node:range()
          ranges[#ranges + 1] = { sr, sc, er, ec }
        end
      end
    end
  end

  return function(row, col)
    for _, r in ipairs(ranges) do
      local sr, sc, er, ec = r[1], r[2], r[3], r[4]
      if row > sr and row < er then return true end
      if row == sr and row == er and col >= sc and col < ec then return true end
      if row == sr and row ~= er and col >= sc then return true end
      if row == er and row ~= sr and col < ec then return true end
    end
    return false
  end
end

-- ---------------------------------------------------------------------------
-- Frontmatter detection
-- ---------------------------------------------------------------------------

--- Find the line range of YAML frontmatter (if present).
--- Returns (start_line, end_line) as 0-indexed, or nil if no frontmatter.
---@param bufnr number
---@return number|nil, number|nil
local function get_frontmatter_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(5, vim.api.nvim_buf_line_count(bufnr)), false)
  if not lines[1] or lines[1] ~= "---" then return nil, nil end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local max_scan = math.min(line_count, 200)
  for i = 2, max_scan do
    local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
    if line == "---" or line == "..." then
      return 0, i - 1 -- 0-indexed
    end
  end
  return nil, nil
end

-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

local hl_groups = {
  VaultTag = { fg = "#c678dd", bold = true },
  VaultTagProject = { fg = "#61afef", bold = true },
  VaultTagStatus = { fg = "#98c379", bold = true },
  VaultTagType = { fg = "#e5c07b", bold = true },
  VaultTagPerson = { fg = "#56b6c2", bold = true },
  VaultTagHash = { fg = "#5c6370" },
}

local function define_highlights()
  for group, attrs in pairs(hl_groups) do
    attrs.default = true
    vim.api.nvim_set_hl(0, group, attrs)
  end
end

--- Category prefix -> highlight group mapping.
--- Order matters: first match wins (most specific prefix first).
local default_categories = {
  { prefix = "project/", highlight = "VaultTagProject" },
  { prefix = "status/", highlight = "VaultTagStatus" },
  { prefix = "type/", highlight = "VaultTagType" },
  { prefix = "person/", highlight = "VaultTagPerson" },
}

--- Determine the highlight group for a tag based on its category prefix.
---@param tag string the tag text (without #)
---@return string highlight_group
local function tag_highlight(tag)
  local categories = default_categories
  -- Allow config override if available
  local ok, config = pcall(require, "andrew.vault.config")
  if ok and config.tag_categories then
    categories = config.tag_categories
  end

  local lower = tag:lower()
  for _, cat in ipairs(categories) do
    if lower:sub(1, #cat.prefix) == cat.prefix then
      return cat.highlight
    end
  end
  return "VaultTag"
end

-- ---------------------------------------------------------------------------
-- Core highlight application
-- ---------------------------------------------------------------------------

--- Clear all tag highlights from a buffer.
---@param bufnr number
local function clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

--- Scan buffer and apply highlights to all inline tags.
---@param bufnr number
local function apply(bufnr)
  if not M.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then
    clear(bufnr)
    return
  end

  clear(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local is_in_code = build_code_exclusion(bufnr)
  local fm_start, fm_end = get_frontmatter_range(bufnr)

  for i, line in ipairs(lines) do
    local row = i - 1 -- 0-indexed

    -- Skip frontmatter lines (tags there are in YAML format, not inline)
    if fm_start and fm_end and row >= fm_start and row <= fm_end then
      goto next_line
    end

    -- Skip heading lines (# Heading, ## Heading, etc.)
    if line:match("^#+ ") then
      goto next_line
    end

    -- Scan for #tag patterns
    local pos = 1
    while pos <= #line do
      -- Find next # character
      local hash_pos = line:find("#", pos, true)
      if not hash_pos then break end

      -- Check if this # starts a valid tag
      if not valid_tag_start(line, hash_pos) then
        pos = hash_pos + 1
        goto next_tag
      end

      -- Extract the tag text after #
      local tag = line:match("^([a-zA-Z][a-zA-Z0-9_/-]*)", hash_pos + 1)
      if not tag then
        pos = hash_pos + 1
        goto next_tag
      end

      -- Filter out hex colors (#ff0000, #abc, etc.)
      if is_hex_color(tag) then
        pos = hash_pos + 1 + #tag
        goto next_tag
      end

      -- Filter out code blocks/spans (0-indexed col)
      if is_in_code(row, hash_pos - 1) then
        pos = hash_pos + 1 + #tag
        goto next_tag
      end

      -- Valid tag found — apply highlights
      local tag_start = hash_pos - 1 -- 0-indexed byte position of #
      local tag_end = hash_pos + #tag -- 0-indexed byte position past end of tag

      -- Highlight the # character (dim)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, tag_start, {
        end_col = tag_start + 1,
        hl_group = "VaultTagHash",
        hl_mode = "combine",
        priority = 190,
      })

      -- Highlight the tag text (category-colored)
      local hl = tag_highlight(tag)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, tag_start + 1, {
        end_col = tag_end,
        hl_group = hl,
        hl_mode = "combine",
        priority = 190,
      })

      pos = hash_pos + 1 + #tag
      ::next_tag::
    end

    ::next_line::
  end
end

-- ---------------------------------------------------------------------------
-- Debounced update
-- ---------------------------------------------------------------------------

---@param bufnr number
local function schedule_update(bufnr)
  if timer then
    timer:stop()
  end
  timer = vim.uv.new_timer()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      apply(bufnr)
    end
  end))
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    apply(vim.api.nvim_get_current_buf())
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      clear(buf)
    end
  end
  vim.notify(
    "Vault: tag highlights " .. (M.enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end

-- ---------------------------------------------------------------------------
-- Tag navigation (bonus: jump to next/prev tag)
-- ---------------------------------------------------------------------------

--- Jump to the next or previous inline tag in the buffer.
---@param direction 1|-1 forward or backward
local function jump_tag(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cur_row, cur_col = unpack(vim.api.nvim_win_get_cursor(0))
  cur_col = cur_col + 1 -- 1-indexed

  local is_in_code = build_code_exclusion(bufnr)
  local fm_start, fm_end = get_frontmatter_range(bufnr)

  -- Collect all tag positions
  local tags = {}
  for i, line in ipairs(lines) do
    local row = i - 1
    if fm_start and fm_end and row >= fm_start and row <= fm_end then
      goto skip
    end
    if line:match("^#+ ") then goto skip end

    local pos = 1
    while pos <= #line do
      local hash_pos = line:find("#", pos, true)
      if not hash_pos then break end
      if valid_tag_start(line, hash_pos) then
        local tag = line:match("^([a-zA-Z][a-zA-Z0-9_/-]*)", hash_pos + 1)
        if tag and not is_hex_color(tag) and not is_in_code(row, hash_pos - 1) then
          tags[#tags + 1] = { row = i, col = hash_pos }
        end
        pos = hash_pos + 1 + (tag and #tag or 0)
      else
        pos = hash_pos + 1
      end
    end
    ::skip::
  end

  if #tags == 0 then return end

  if direction == 1 then
    for _, t in ipairs(tags) do
      if t.row > cur_row or (t.row == cur_row and t.col > cur_col) then
        vim.api.nvim_win_set_cursor(0, { t.row, t.col - 1 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(0, { tags[1].row, tags[1].col - 1 })
  else
    for j = #tags, 1, -1 do
      local t = tags[j]
      if t.row < cur_row or (t.row == cur_row and t.col < cur_col) then
        vim.api.nvim_win_set_cursor(0, { t.row, t.col - 1 })
        return
      end
    end
    local last = tags[#tags]
    vim.api.nvim_win_set_cursor(0, { last.row, last.col - 1 })
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  define_highlights()

  local group = vim.api.nvim_create_augroup("VaultTagHL", { clear = true })

  -- Apply on buffer enter and after writes
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            apply(ev.buf)
          end
        end, 30)
      end
    end,
  })

  -- Debounced update on text changes
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        schedule_update(ev.buf)
      end
    end,
  })

  -- Re-define highlights when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_highlights,
  })

  -- Clean up on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      clear(ev.buf)
    end,
  })

  -- Commands
  vim.api.nvim_create_user_command("VaultTagHLToggle", function()
    M.toggle()
  end, { desc = "Toggle inline tag highlighting" })

  vim.api.nvim_create_user_command("VaultTagHLRefresh", function()
    apply(vim.api.nvim_get_current_buf())
  end, { desc = "Refresh tag highlights in current buffer" })

  -- Buffer-local keymaps
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vgt", function()
        M.toggle()
      end, {
        buffer = ev.buf,
        desc = "Tags: highlights toggle",
        silent = true,
      })
      vim.keymap.set("n", "]t", function()
        jump_tag(1)
      end, {
        buffer = ev.buf,
        desc = "Next inline tag",
        silent = true,
      })
      vim.keymap.set("n", "[t", function()
        jump_tag(-1)
      end, {
        buffer = ev.buf,
        desc = "Previous inline tag",
        silent = true,
      })
    end,
  })
end

return M
```

---

## Integration

### 1. Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add to the module setup chain (after `tags`):

```lua
require("andrew.vault.tag_highlights").setup()
```

### 2. Add category config

**File:** `lua/andrew/vault/config.lua`

Add to the config table:

```lua
--- Tag highlight settings
tag_highlights = {
  enabled = true,
  debounce_ms = 200,
  --- Category prefix -> highlight group mapping.
  --- First match wins (put more specific prefixes first).
  categories = {
    { prefix = "project/", highlight = "VaultTagProject" },
    { prefix = "status/", highlight = "VaultTagStatus" },
    { prefix = "type/", highlight = "VaultTagType" },
    { prefix = "person/", highlight = "VaultTagPerson" },
  },
},
```

---

## Testing

### Manual Verification

1. **Create a test note with various tag patterns:**

   ```markdown
   ---
   tags: [project/simulation, methodology]
   ---

   # Test Note

   This note has inline tags like #project/cfd and #status/active.

   Some tags are simple: #methodology, #concept, #literature.

   Person tags: #person/alice, #person/bob.

   ## Things That Should NOT Be Highlighted

   Headings use # but aren't tags.

   Code spans: `#include <stdio.h>` should not highlight.

   ```python
   # This is a comment, not a tag
   color = "#ff0000"
   ```

   CSS colors like #ff0000 or #abc should not highlight.

   URLs with fragments: https://example.com#section should not highlight.
   ```

2. **Expected behavior:**
   - `#project/cfd` → blue bold
   - `#status/active` → green bold
   - `#methodology`, `#concept`, `#literature` → purple bold (default)
   - `#person/alice`, `#person/bob` → cyan bold
   - `#` prefix character → dim gray in all cases
   - Headings, code spans, code blocks, hex colors, URL fragments → no highlight
   - Frontmatter `tags:` line → no highlight (YAML format, not inline)

3. **Navigation:**
   - `]t` jumps to next tag, `[t` jumps to previous tag
   - Wraps around at buffer boundaries

4. **Toggle:**
   - `<leader>vgt` or `:VaultTagHLToggle` turns highlights on/off

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: tag_highlights module structure
do
  local source = io.open("lua/andrew/vault/tag_highlights.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- Core functionality present
    assert_true(content:find("VaultTag") ~= nil, "defines VaultTag highlight group")
    assert_true(content:find("VaultTagProject") ~= nil, "defines VaultTagProject group")
    assert_true(content:find("nvim_buf_set_extmark") ~= nil, "uses extmarks")
    assert_true(content:find("build_code_exclusion") ~= nil, "has code block filtering")
    assert_true(content:find("is_hex_color") ~= nil, "has hex color filtering")
    assert_true(content:find("valid_tag_start") ~= nil, "validates tag boundaries")
    assert_true(content:find("schedule_update") ~= nil, "has debounced update")
    assert_true(content:find("jump_tag") ~= nil, "has tag navigation")
  end
end
```

### Performance Verification

In a vault note with 50+ inline tags:

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.tag_highlights").apply(0); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

Target: < 15ms for a 50-tag buffer. The main cost is `build_code_exclusion()` (treesitter parse) which runs once per update. Tag pattern matching is fast string scanning.

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| `#123` (bare number) | Not highlighted — tag must start with a letter |
| `#a` (single letter) | Not highlighted — minimum 2 chars after `#` (letter + alphanumeric) |
| `#project/sub/deep` | Highlighted — nested `/` allowed in tag pattern |
| `#status-active` | Highlighted — hyphens allowed |
| `#tag_with_underscores` | Highlighted — underscores allowed |
| `#TAG` (uppercase) | Highlighted — category matching is case-insensitive |
| `(#tag)` | Highlighted — parentheses are valid predecessors |
| `"#tag"` | Highlighted — quotes are valid predecessors |
| `foo#tag` (no space) | Not highlighted — must be preceded by whitespace or punctuation |
| `##double` | First `#` starts a heading check; `#double` after would need a space predecessor |
| Empty buffer | No highlights, no errors |
| Non-vault markdown file | Skipped — `is_vault_path()` check |
| 1000+ line buffer | Debounced — only re-scans after 200ms idle |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `is_vault_path()` for vault detection | Yes |
| `config.lua` | Tag category definitions (optional) | No (fallback defaults) |
| Treesitter `markdown` parser | Code block exclusion | No (degrades gracefully without it) |
| Treesitter `markdown_inline` parser | Code span exclusion | No (degrades gracefully) |

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/tag_highlights.lua` | **New file** — complete module |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.tag_highlights").setup()` |
| `lua/andrew/vault/config.lua` | Add `tag_highlights` config section (optional) |

---

## Risk Assessment

**Risk: Low**

- New module, no existing code modified (except one `require` line in `init.lua`).
- Uses established patterns from `linkdiag.lua` and `tags.lua`.
- Extmarks with `priority = 190` won't conflict with wikilink highlights (200), render-markdown (1000+), or diagnostics (~10).
- Treesitter code exclusion degrades gracefully — if parser isn't available, tags inside code blocks may get highlighted (false positive, not false negative).
- Toggle command and `:VaultTagHLRefresh` provide easy control.

---

## Relationship to #18 (Wikilink Concealing)

Both #18 and #19 are independent extmark-based highlighting modules that follow the same architectural pattern:

- Same namespace/extmark approach
- Same debounce pattern
- Same autocmd structure
- Same toggle/refresh commands
- Compatible extmark priorities (wikilinks: 200, tags: 190)

They can be implemented in either order. Both integrate into `init.lua` with a single `require().setup()` call. They share no code but could theoretically share a common `highlight_utils.lua` base — this is **not recommended** at this stage as it would add unnecessary abstraction for two modules.
