# 08 — Footnote Rendering & Enhanced Navigation

## Problem

The vault has a basic footnote module (`lua/andrew/vault/footnotes.lua`) that provides:

1. **`M.jump()`** — Toggles between a `[^id]` reference and its `[^id]:` definition (bound to `<leader>mj`).
2. **`M.list()`** — Lists all footnotes via fzf-lua picker (bound to `<leader>mn`).
3. **`M.next_id()`** — Auto-numbering helper used by LuaSnip snippets (`fnr`, `fnd`, etc.).

However, several significant gaps remain:

### No Inline Footnote Content Preview

When reading a note with footnotes scattered throughout the text, understanding `[^1]` requires scrolling to the bottom of the document to find `[^1]: definition text`. This breaks reading flow. Obsidian renders footnote content inline as a hover or virtual text preview. The vault's embed system (`embed.lua`) already demonstrates how to render content inline via extmark virtual text, but nothing equivalent exists for footnotes.

### No Floating Preview on Hover

The vault's `preview.lua` module provides a floating preview window for wikilinks (K key), supporting same-file heading/block references and cross-file resolution. No similar capability exists for footnotes. Pressing K on `[^1]` does nothing useful because `get_wikilink_under_cursor()` does not detect footnote syntax.

### Picker Shows Minimal Information

The current `M.list()` function produces entries like `42: [^1] ` or `42: [^1] (no definition)`. It does not show the definition content in the picker, making it difficult to identify which footnote is which without opening each one.

### No Orphan Detection

There is no way to find footnote references without definitions or definitions without references. The `M.list()` function flags missing definitions but does not surface orphaned definitions (definitions that no reference points to).

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **footnotes.lua** | `get_footnote_at_cursor()`, `M.next_id()`, `M.jump()`, `M.list()`, `M.setup()` | `lua/andrew/vault/footnotes.lua` (147 lines) |
| **embed.lua** | Renders `![[...]]` as virtual text extmarks; handles image embeds via snacks placements; recursive resolution with cycle/depth detection | `lua/andrew/vault/embed.lua` (1017 lines) |
| **preview.lua** | Floating preview for wikilinks (K key); scroll support (C-j/C-k); edit-in-float (`<leader>vE`) | `lua/andrew/vault/preview.lua` (316 lines) |
| **config.lua** | Centralized configuration; `M.preview` (max_lines, max_width); `M.embed` (max_lines, max_depth, etc.) | `lua/andrew/vault/config.lua` (459 lines) |
| **colors.lua** | Centralized palette and highlight definitions for all vault modules | `lua/andrew/vault/colors.lua` (350 lines) |
| **ftplugin/markdown.lua** | Buffer-local keymaps; which-key registration for `<leader>mj` and `<leader>mn` (lines 848-850) | `ftplugin/markdown.lua` (895 lines) |
| **init.lua** | Module load chain; `require("andrew.vault.footnotes").setup()` at line 139 | `lua/andrew/vault/init.lua` (442 lines) |
| **render-markdown.lua** | Plugin config; does NOT have any footnote-specific rendering configuration | `lua/andrew/plugins/render-markdown.lua` (317 lines) |

### Markdown Footnote Syntax

Standard markdown footnotes use two constructs:

```markdown
This is text with a footnote reference[^1] in the middle.

Another reference[^named-fn] here.

[^1]: This is the footnote definition. It can span
    multiple lines with indentation.

[^named-fn]: Named footnotes work identically to numeric ones.
```

- **Reference**: `[^id]` — inline in text, where `id` is alphanumeric, hyphens, or underscores.
- **Definition**: `[^id]: content` — starts at column 0, with `id` matching a reference. Continuation lines are indented (typically 4 spaces or 1 tab).
- **Inline footnote** (Pandoc extension): `^[inline definition text]` — self-contained, no separate definition needed.

---

## Goal

Enhance the footnote module with three new capabilities:

1. **Inline virtual text rendering** — Show footnote definition content as virtual text below each `[^id]` reference, using the same extmark pattern as `embed.lua`.
2. **Floating preview on K** — Extend `preview.lua` to detect footnote references and show definition content in a floating window.
3. **Enhanced picker** — Show definition text as preview in the fzf-lua picker; flag orphaned definitions; add diagnostic highlighting for missing definitions.

Additionally:

4. **Multi-line definition parsing** — Properly handle footnote definitions that span multiple lines (continuation via indentation).
5. **Footnote highlighting** — Add dedicated highlight groups for footnote references, definitions, and virtual text through the centralized `colors.lua` palette.
6. **Orphan detection command** — `:VaultFootnoteOrphans` to find references without definitions and definitions without references.

---

## Approach

### Architecture

The implementation extends `footnotes.lua` as the primary module, with integration hooks into `preview.lua` and `colors.lua`. A new extmark namespace `VaultFootnote` handles the virtual text rendering, following the `embed.lua` pattern but scoped to footnote syntax.

```
footnotes.lua (enhanced)
  │
  ├─ Parsing layer
  │   ├─ get_footnote_at_cursor()        (existing, unchanged)
  │   ├─ parse_all_footnotes(bufnr)      (NEW: full buffer scan)
  │   ├─ get_definition_content(bufnr, id) (NEW: multi-line definition reader)
  │   └─ M.next_id()                     (existing, unchanged)
  │
  ├─ Navigation layer
  │   ├─ M.jump()                        (existing, unchanged)
  │   └─ M.list()                        (ENHANCED: shows definition preview)
  │
  ├─ Rendering layer (NEW)
  │   ├─ M.render_footnotes(opts)        (virtual text extmarks)
  │   ├─ M.clear_footnotes()             (clear extmarks)
  │   ├─ M.toggle_footnotes()            (toggle on/off)
  │   └─ M.preview_footnote()            (floating preview for K key)
  │
  └─ Diagnostic layer (NEW)
      └─ M.orphans()                     (find orphaned refs/defs)

colors.lua (extended)
  └─ New palette keys: footnote_ref, footnote_def, footnote_content, footnote_border, footnote_orphan
  └─ New highlight groups: VaultFootnoteRef, VaultFootnoteDef, VaultFootnoteContent,
                           VaultFootnoteBorder, VaultFootnoteOrphan

preview.lua (extended)
  └─ M.preview() now detects [^id] under cursor and shows definition content

config.lua (extended)
  └─ M.footnotes = { render = true, max_lines = 5, preview_max_lines = 15 }
```

### Key Design Decisions

1. **Separate namespace from embeds.** Footnote virtual text uses its own namespace (`VaultFootnote`) rather than sharing `VaultEmbed`. This allows independent toggle/clear operations without affecting embed rendering, and avoids interference during `render_embeds()` calls.

2. **Buffer-local rendering.** Footnote definitions are always in the same file as their references (unlike embeds which resolve cross-file). This simplifies the implementation: no file I/O, no caching, no async — just buffer line scanning.

3. **Multi-line definition support.** Footnote definitions can span multiple lines with indentation continuation. The parser collects all continuation lines (lines starting with 4 spaces or 1 tab after a `[^id]:` line) until a blank line or non-indented line is encountered.

4. **Render below reference, not below definition.** The virtual text appears below the line containing `[^id]` (the reference site), not below the `[^id]:` definition. This is where the reader needs the context.

5. **Opt-in auto-render.** Unlike embeds which auto-render on `BufReadPost`, footnote rendering is triggered manually via `:VaultFootnoteRender` or `<leader>mj` with a prefix. This avoids visual clutter for users who prefer the standard footnote workflow.

---

## Implementation

### 1. Config change: `config.lua`

**File:** `lua/andrew/vault/config.lua`

Add a new section after the `M.embed` block (after line 82):

```lua
-- ---------------------------------------------------------------------------
-- Footnotes
-- ---------------------------------------------------------------------------
M.footnotes = {
  -- Render footnote definitions as virtual text below references.
  render = false,             -- off by default (opt-in)
  -- Maximum content lines to show in virtual text per footnote.
  max_lines = 5,
  -- Maximum content lines in the floating preview window.
  preview_max_lines = 20,
  -- Auto-render on BufReadPost (like embeds). Only applies when render = true.
  auto_render = false,
  -- Show orphan diagnostics (references without definitions, definitions without references).
  diagnostics = true,
}
```

### 2. Color palette and highlight groups: `colors.lua`

**File:** `lua/andrew/vault/colors.lua`

Add footnote palette keys to each palette definition.

**In the `onedark` palette** (after `embed_error`, around line 59):

```lua
  -- Footnotes
  footnote_ref           = "#56b6c2",
  footnote_def           = "#5c6370",
  footnote_content       = "#8888aa",
  footnote_border        = "#555577",
  footnote_orphan        = "#e06c75",
```

**In the `soft_paper_light` palette** (after `embed_error`, around line 121):

```lua
  -- Footnotes
  footnote_ref           = "#669EA6",  -- c.teal
  footnote_def           = "#CAC1B9",  -- c.surface2
  footnote_content       = "#9A85AE",  -- c.lavender
  footnote_border        = "#8D8D8D",  -- c.mauve
  footnote_orphan        = "#BA7184",  -- c.red
```

**In the `soft_paper_dark` palette** (after `embed_error`, around line 180):

```lua
  -- Footnotes
  footnote_ref           = "#11B7C5",  -- c.teal
  footnote_def           = "#62677E",  -- c.surface2
  footnote_content       = "#BB93D6",  -- c.lavender
  footnote_border        = "#8D8D8D",  -- c.mauve
  footnote_orphan        = "#E78284",  -- c.red
```

**In `build_hl_groups()`** (after `VaultEmbedError`, around line 277):

```lua
    -- Footnotes
    VaultFootnoteRef           = { fg = p.footnote_ref, bold = true },
    VaultFootnoteDef           = { fg = p.footnote_def, italic = true },
    VaultFootnoteContent       = { italic = true, fg = p.footnote_content },
    VaultFootnoteBorder        = { fg = p.footnote_border },
    VaultFootnoteOrphan        = { fg = p.footnote_orphan, undercurl = true, sp = p.footnote_orphan },
```

### 3. Enhanced footnotes module: `footnotes.lua`

**File:** `lua/andrew/vault/footnotes.lua`

Complete rewrite preserving existing public API (`M.jump()`, `M.list()`, `M.next_id()`, `M.setup()`) and adding new capabilities.

```lua
local config = require("andrew.vault.config")

local M = {}

local ns = vim.api.nvim_create_namespace("VaultFootnote")
local footnotes_visible = {} -- bufnr -> boolean

-- ============================================================================
-- Patterns
-- ============================================================================

-- Reference pattern: [^id] where id is alphanumeric, hyphens, or underscores
local REF_PAT = "%[%^([%w_-]+)%]"
-- Definition pattern: [^id]: at the start of a line
local DEF_PAT = "^%[%^([%w_-]+)%]:%s?(.*)"
-- Continuation line: 4 spaces or 1 tab (standard markdown footnote continuation)
local CONT_PAT = "^%s%s%s%s(.*)"
local CONT_TAB_PAT = "^\t(.*)"

-- ============================================================================
-- Parsing
-- ============================================================================

--- Find the footnote identifier under or near the cursor.
---@return string|nil footnote id (without [^ and ])
---@return number|nil start column (1-indexed)
---@return number|nil end column (1-indexed)
local function get_footnote_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  local start = 1
  while true do
    local s, e, id = line:find("%[%^([%w_-]+)%]", start)
    if not s then return nil end
    if col >= s and col <= e then
      return id, s, e
    end
    start = e + 1
  end
end

--- Read the full content of a footnote definition, including continuation lines.
--- Returns the content as an array of strings (one per line), with the definition
--- marker stripped from the first line and indentation stripped from continuations.
---@param buf_lines string[] all buffer lines
---@param def_lnum number 1-indexed line number of the [^id]: definition
---@return string[] content lines
---@return number end_lnum 1-indexed last line of the definition block
local function read_definition_content(buf_lines, def_lnum)
  local first_line = buf_lines[def_lnum]
  if not first_line then return {}, def_lnum end

  local _, content_start = first_line:match(DEF_PAT)
  if not content_start then return {}, def_lnum end

  local lines = {}
  -- First line: text after [^id]:
  local trimmed = vim.trim(content_start)
  if trimmed ~= "" then
    lines[#lines + 1] = trimmed
  end

  -- Continuation lines: indented by 4 spaces or 1 tab
  local lnum = def_lnum + 1
  while lnum <= #buf_lines do
    local line = buf_lines[lnum]
    -- Stop at blank lines (end of footnote block)
    if line:match("^%s*$") then
      break
    end
    -- Check for continuation indentation
    local cont = line:match(CONT_PAT)
    if not cont then
      cont = line:match(CONT_TAB_PAT)
    end
    if cont then
      lines[#lines + 1] = cont
      lnum = lnum + 1
    else
      -- Non-indented, non-blank line: end of definition
      break
    end
  end

  return lines, lnum - 1
end

--- Scan the buffer and build a complete footnote map.
--- Returns tables mapping footnote IDs to their references and definitions.
---@param bufnr number
---@return table footnote_map { [id] = { refs = {{lnum, col}...}, def_lnum = number|nil, def_content = string[], def_end_lnum = number|nil } }
local function parse_all_footnotes(bufnr)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local map = {}

  for i, line in ipairs(buf_lines) do
    -- Check for definition first (definitions start at column 0)
    local def_id, def_text = line:match(DEF_PAT)
    if def_id then
      if not map[def_id] then
        map[def_id] = { refs = {}, def_lnum = nil, def_content = {}, def_end_lnum = nil }
      end
      local content, end_lnum = read_definition_content(buf_lines, i)
      map[def_id].def_lnum = i
      map[def_id].def_content = content
      map[def_id].def_end_lnum = end_lnum
    end

    -- Find all references on this line (including on definition lines — a definition
    -- line contains a reference-like pattern as part of its own syntax, but we only
    -- count references that are NOT the definition marker itself)
    local start = 1
    while true do
      local s, e, ref_id = line:find(REF_PAT, start)
      if not s then break end

      -- Skip if this is the definition marker itself: [^id]: at start of line
      local is_def_marker = (s == 1) and line:sub(e + 1, e + 1) == ":"
      if not is_def_marker then
        if not map[ref_id] then
          map[ref_id] = { refs = {}, def_lnum = nil, def_content = {}, def_end_lnum = nil }
        end
        table.insert(map[ref_id].refs, { lnum = i, col = s })
      end

      start = e + 1
    end
  end

  return map
end

--- Get the definition content for a specific footnote ID in the current buffer.
---@param bufnr number
---@param id string footnote identifier
---@return string[]|nil content lines, nil if definition not found
---@return number|nil def_lnum 1-indexed definition line number
local function get_definition_for_id(bufnr, id)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local escaped = vim.pesc(id)
  local pattern = "^%[%^" .. escaped .. "%]:"

  for i, line in ipairs(buf_lines) do
    if line:match(pattern) then
      local content, _ = read_definition_content(buf_lines, i)
      return content, i
    end
  end
  return nil, nil
end

-- ============================================================================
-- Public: next_id (existing)
-- ============================================================================

--- Find the next available numeric footnote ID in the current buffer.
--- Scans all lines for [^N] patterns and returns max(N) + 1.
---@return integer next available footnote number
function M.next_id()
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local max_id = 0
  for _, line in ipairs(buf_lines) do
    for id_str in line:gmatch("%[%^(%d+)%]") do
      local n = tonumber(id_str)
      if n and n > max_id then
        max_id = n
      end
    end
  end
  return max_id + 1
end

-- ============================================================================
-- Public: jump (existing, unchanged)
-- ============================================================================

--- Jump between footnote reference and definition.
--- If on a definition `[^id]:`, jump to first reference `[^id]`.
--- If on a reference `[^id]`, jump to the definition `[^id]:`.
function M.jump()
  local id = get_footnote_at_cursor()
  if not id then
    vim.notify("No footnote under cursor", vim.log.levels.INFO)
    return
  end

  local line = vim.api.nvim_get_current_line()
  local is_definition = line:match("^%[%^" .. vim.pesc(id) .. "%]:")

  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  if is_definition then
    -- Jump to first reference (not a definition)
    local pattern = "%[%^" .. vim.pesc(id) .. "%]"
    for i, l in ipairs(buf_lines) do
      if not l:match("^%[%^" .. vim.pesc(id) .. "%]:") then
        local s = l:find(pattern)
        if s then
          vim.api.nvim_win_set_cursor(0, { i, s - 1 })
          return
        end
      end
    end
    vim.notify("No reference found for [^" .. id .. "]", vim.log.levels.INFO)
  else
    -- Jump to definition
    local pattern = "^%[%^" .. vim.pesc(id) .. "%]:"
    for i, l in ipairs(buf_lines) do
      if l:match(pattern) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
    vim.notify("No definition found for [^" .. id .. "]", vim.log.levels.INFO)
  end
end

-- ============================================================================
-- Public: list (enhanced — shows definition preview)
-- ============================================================================

--- List all footnotes in current buffer via fzf-lua, with definition previews.
function M.list()
  local bufnr = vim.api.nvim_get_current_buf()
  local fn_map = parse_all_footnotes(bufnr)

  if vim.tbl_isempty(fn_map) then
    vim.notify("No footnotes in buffer", vim.log.levels.INFO)
    return
  end

  -- Build sorted list of entries
  local entries = {}
  local ids = vim.tbl_keys(fn_map)
  table.sort(ids, function(a, b)
    -- Sort numeric IDs numerically, then alphabetically
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    if na then return true end
    if nb then return false end
    return a < b
  end)

  for _, id in ipairs(ids) do
    local info = fn_map[id]
    local ref_count = #info.refs
    local first_ref_lnum = info.refs[1] and info.refs[1].lnum or 0

    local status = ""
    if ref_count == 0 then
      status = " [ORPHAN DEF]"
    elseif not info.def_lnum then
      status = " [NO DEF]"
    end

    local preview = ""
    if #info.def_content > 0 then
      -- Show first line of definition, truncated
      local first_line = info.def_content[1]
      if #first_line > 60 then
        first_line = first_line:sub(1, 57) .. "..."
      end
      preview = " :: " .. first_line
    end

    local display_lnum = info.def_lnum or first_ref_lnum
    entries[#entries + 1] = {
      display = string.format(
        "%d: [^%s] (%d ref%s)%s%s",
        display_lnum,
        id,
        ref_count,
        ref_count == 1 and "" or "s",
        status,
        preview
      ),
      lnum = display_lnum,
    }
  end

  if #entries == 0 then
    vim.notify("No footnotes in buffer", vim.log.levels.INFO)
    return
  end

  local display_list = {}
  for _, e in ipairs(entries) do
    display_list[#display_list + 1] = e.display
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(display_list, {
    prompt = "Footnotes> ",
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

-- ============================================================================
-- Rendering: virtual text inline footnote content
-- ============================================================================

--- Build a footnote header border line.
---@param id string footnote identifier
---@param suffix string|nil optional annotation
---@return string
local function footnote_header(id, suffix)
  local label = " [^" .. id .. "]"
  if suffix then
    label = label .. " " .. suffix
  end
  label = label .. " "
  local prefix_w = 2
  local tail_w = math.max(4, 40 - prefix_w - vim.fn.strdisplaywidth(label))
  return string.rep("\u{2500}", prefix_w) .. label .. string.rep("\u{2500}", tail_w)
end

--- Build a footnote footer border line.
---@return string
local function footnote_footer()
  return string.rep("\u{2500}", 40)
end

--- Render footnote definition content as virtual text below each reference.
---@param opts? { silent?: boolean }
function M.render_footnotes(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()

  -- Clear existing footnote extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local fn_map = parse_all_footnotes(bufnr)
  if vim.tbl_isempty(fn_map) then
    footnotes_visible[bufnr] = false
    if not opts.silent then
      vim.notify("No footnotes in buffer", vim.log.levels.INFO)
    end
    return
  end

  local fn_config = config.footnotes or {}
  local max_lines = fn_config.max_lines or 5
  local border_hl = "VaultFootnoteBorder"
  local content_hl = "VaultFootnoteContent"
  local orphan_hl = "VaultFootnoteOrphan"

  local rendered_count = 0

  for id, info in pairs(fn_map) do
    -- Only render below reference sites, not definition sites
    for _, ref in ipairs(info.refs) do
      local virt_lines = {}

      if #info.def_content > 0 then
        -- Header
        virt_lines[#virt_lines + 1] = { { footnote_header(id), border_hl } }

        -- Content lines (capped by max_lines)
        local line_count = math.min(#info.def_content, max_lines)
        for j = 1, line_count do
          virt_lines[#virt_lines + 1] = { { "  " .. info.def_content[j], content_hl } }
        end

        -- Truncation indicator
        if #info.def_content > max_lines then
          virt_lines[#virt_lines + 1] = {
            { "  \u{22ef} (" .. (#info.def_content - max_lines) .. " more line" ..
              (#info.def_content - max_lines == 1 and "" or "s") .. ")", border_hl },
          }
        end

        -- Footer
        virt_lines[#virt_lines + 1] = { { footnote_footer(), border_hl } }
        rendered_count = rendered_count + 1
      elseif not info.def_lnum then
        -- No definition exists: show orphan indicator
        virt_lines[#virt_lines + 1] = {
          { footnote_header(id, "(no definition)"), orphan_hl },
        }
      end

      if #virt_lines > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, ns, ref.lnum - 1, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
        })
      end
    end
  end

  footnotes_visible[bufnr] = true

  if not opts.silent then
    local orphan_count = 0
    for _, info in pairs(fn_map) do
      if #info.refs > 0 and not info.def_lnum then
        orphan_count = orphan_count + 1
      end
    end

    local parts = {}
    if rendered_count > 0 then
      parts[#parts + 1] = rendered_count .. " footnote(s) rendered"
    end
    if orphan_count > 0 then
      parts[#parts + 1] = orphan_count .. " missing definition(s)"
    end
    if #parts > 0 then
      vim.notify("Vault footnotes: " .. table.concat(parts, ", "), vim.log.levels.INFO)
    end
  end
end

--- Clear all footnote virtual text from the current buffer.
function M.clear_footnotes()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  footnotes_visible[bufnr] = false
end

--- Toggle footnote rendering on/off in the current buffer.
function M.toggle_footnotes()
  local bufnr = vim.api.nvim_get_current_buf()
  if footnotes_visible[bufnr] then
    M.clear_footnotes()
  else
    M.render_footnotes()
  end
end

-- ============================================================================
-- Floating preview for footnote under cursor
-- ============================================================================

--- Show a floating preview of the footnote definition under the cursor.
--- Designed to be called from preview.lua's preview() function as a fallback
--- when no wikilink is detected.
---@return boolean true if a footnote was found and previewed
function M.preview_footnote()
  local id = get_footnote_at_cursor()
  if not id then
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local content, def_lnum = get_definition_for_id(bufnr, id)

  local all_lines
  local title = "[^" .. id .. "]"

  if content and #content > 0 then
    all_lines = content
  elseif def_lnum then
    all_lines = { "(empty footnote definition)" }
  else
    all_lines = { "[No definition found for [^" .. id .. "]]" }
  end

  -- Compute float dimensions
  local fn_config = config.footnotes or {}
  local max_width = config.preview.max_width
  local max_height = fn_config.preview_max_lines or config.preview.max_lines
  local width = 0
  for _, l in ipairs(all_lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width, 20), max_width)
  local height = math.min(#all_lines, max_height)

  -- Create buffer with content
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].bufhidden = "wipe"

  -- Open floating window
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = { { " " .. title .. " ", "VaultFootnoteRef" } },
    title_pos = "center",
  })

  -- Window options
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].foldenable = false

  -- Set filetype for potential render-markdown rendering
  vim.bo[buf].filetype = "markdown"
  pcall(vim.treesitter.start, buf, "markdown")
  pcall(function()
    require("render-markdown").render({ buf = buf, win = win })
  end)

  vim.bo[buf].modifiable = false

  -- Auto-close on cursor move or leaving the buffer
  local parent_buf = vim.api.nvim_get_current_buf()
  local augroup = vim.api.nvim_create_augroup("VaultFootnotePreviewClose", { clear = true })

  local function close()
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = parent_buf,
    once = true,
    callback = close,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    buffer = parent_buf,
    once = true,
    callback = close,
  })

  return true
end

-- ============================================================================
-- Orphan detection
-- ============================================================================

--- Find orphaned footnotes: references without definitions and definitions
--- without references. Shows results in a notification.
function M.orphans()
  local bufnr = vim.api.nvim_get_current_buf()
  local fn_map = parse_all_footnotes(bufnr)

  if vim.tbl_isempty(fn_map) then
    vim.notify("No footnotes in buffer", vim.log.levels.INFO)
    return
  end

  local orphan_refs = {}   -- refs with no definition
  local orphan_defs = {}   -- definitions with no references

  for id, info in pairs(fn_map) do
    if #info.refs > 0 and not info.def_lnum then
      orphan_refs[#orphan_refs + 1] = id
    end
    if info.def_lnum and #info.refs == 0 then
      orphan_defs[#orphan_defs + 1] = id
    end
  end

  table.sort(orphan_refs)
  table.sort(orphan_defs)

  if #orphan_refs == 0 and #orphan_defs == 0 then
    vim.notify("All footnotes are properly linked", vim.log.levels.INFO)
    return
  end

  local lines = { "Footnote Orphans:" }
  if #orphan_refs > 0 then
    lines[#lines + 1] = "  References without definitions:"
    for _, id in ipairs(orphan_refs) do
      local info = fn_map[id]
      local lnums = {}
      for _, ref in ipairs(info.refs) do
        lnums[#lnums + 1] = tostring(ref.lnum)
      end
      lines[#lines + 1] = "    [^" .. id .. "] at line(s) " .. table.concat(lnums, ", ")
    end
  end
  if #orphan_defs > 0 then
    lines[#lines + 1] = "  Definitions without references:"
    for _, id in ipairs(orphan_defs) do
      local info = fn_map[id]
      lines[#lines + 1] = "    [^" .. id .. "]: at line " .. info.def_lnum
    end
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
end

-- ============================================================================
-- Setup
-- ============================================================================

function M.setup()
  local group = vim.api.nvim_create_augroup("VaultFootnotes", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>mj", function()
        M.jump()
      end, { buffer = ev.buf, desc = "Footnote: jump ref/def", silent = true })

      vim.keymap.set("n", "<leader>mn", function()
        M.list()
      end, { buffer = ev.buf, desc = "Footnote: list all", silent = true })
    end,
  })

  -- Commands
  vim.api.nvim_create_user_command("VaultFootnoteRender", function()
    M.render_footnotes()
  end, { desc = "Vault: render footnote content inline" })

  vim.api.nvim_create_user_command("VaultFootnoteClear", function()
    M.clear_footnotes()
  end, { desc = "Vault: clear footnote virtual text" })

  vim.api.nvim_create_user_command("VaultFootnoteToggle", function()
    M.toggle_footnotes()
  end, { desc = "Vault: toggle footnote virtual text" })

  vim.api.nvim_create_user_command("VaultFootnoteOrphans", function()
    M.orphans()
  end, { desc = "Vault: find orphaned footnote refs/defs" })

  -- Auto-render if configured
  local fn_config = config.footnotes or {}
  if fn_config.render and fn_config.auto_render then
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = group,
      pattern = "*.md",
      callback = function(ev)
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf)
            and vim.api.nvim_get_current_buf() == ev.buf
          then
            M.render_footnotes({ silent = true })
          end
        end, 200)
      end,
    })
  end

  -- Clean up on buffer delete
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(ev)
      footnotes_visible[ev.buf] = nil
    end,
  })
end

-- Expose parse function for potential external use (e.g., vault_index integration)
M.parse_all_footnotes = parse_all_footnotes

return M
```

### 4. Preview integration: `preview.lua`

**File:** `lua/andrew/vault/preview.lua`

Modify the `M.preview()` function to check for footnotes before giving up. The change is at the beginning of the function, after the wikilink check returns nil.

**Current code** (line 70-76):

```lua
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
```

**Replace with:**

```lua
function M.preview()
  -- Toggle off if already showing
  if is_active() then
    close_preview()
    return
  end

  local details = link_utils.get_wikilink_under_cursor()
  if not details then
    -- Try footnote preview as fallback
    local footnotes = require("andrew.vault.footnotes")
    if footnotes.preview_footnote() then
      return
    end
    vim.notify("No wikilink or footnote under cursor", vim.log.levels.INFO)
    return
  end
```

This change is minimal: when `get_wikilink_under_cursor()` returns nil (cursor is not on a wikilink), we try `footnotes.preview_footnote()` before showing the "not found" message. The footnote preview manages its own floating window and autocmds (independent of preview.lua's `state` table), so there is no conflict.

### 5. Which-key descriptions: `ftplugin/markdown.lua`

**File:** `ftplugin/markdown.lua`

The which-key entries for `<leader>mj` and `<leader>mn` already exist (lines 849-850) with appropriate icons. No changes needed to the which-key registration. The descriptions come from the keymap `desc` field set in `footnotes.lua`'s `setup()`.

---

## Configuration

**File:** `lua/andrew/vault/config.lua`

```lua
M.footnotes = {
  render = false,               -- Render footnote definitions as virtual text (opt-in)
  max_lines = 5,                -- Max content lines per footnote in virtual text
  preview_max_lines = 20,       -- Max content lines in floating preview
  auto_render = false,          -- Auto-render on BufReadPost (requires render = true)
  diagnostics = true,           -- Show orphan indicators in virtual text
}
```

**Behavior by configuration:**

| Setting | Default | Effect |
|---------|---------|--------|
| `render = false` | Off | Virtual text rendering is manual-only via `:VaultFootnoteRender` |
| `render = true` | - | Enables the rendering system; auto_render controls auto-trigger |
| `auto_render = true` | Off | Auto-render on BufReadPost (like embed system) |
| `max_lines = 5` | 5 | Virtual text shows at most 5 lines per footnote |
| `preview_max_lines = 20` | 20 | Floating preview shows at most 20 lines |
| `diagnostics = true` | On | Orphan indicators shown in virtual text and list picker |

---

## File Changes

| File | Change |
|------|--------|
| `lua/andrew/vault/config.lua` | Add `M.footnotes` configuration section (~10 lines) |
| `lua/andrew/vault/colors.lua` | Add `footnote_*` palette keys to all three palettes (~15 lines); add 5 highlight groups to `build_hl_groups()` (~5 lines) |
| `lua/andrew/vault/footnotes.lua` | Complete rewrite: preserve existing API, add `parse_all_footnotes()`, `read_definition_content()`, `get_definition_for_id()`, `render_footnotes()`, `clear_footnotes()`, `toggle_footnotes()`, `preview_footnote()`, `orphans()`, 4 new user commands, auto-render autocmd (~300 lines total) |
| `lua/andrew/vault/preview.lua` | Add footnote fallback in `M.preview()` (~5 lines changed) |

No new files need to be created. The existing `footnotes.lua` module is rewritten in place, preserving all existing public API signatures.

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `config.lua` | `config.footnotes` for rendering settings, `config.preview` for float dimensions | Yes (reads existing config table) |
| `colors.lua` | Defines `VaultFootnote*` highlight groups via centralized palette | Yes (extended, not new dep) |
| `preview.lua` | Calls `footnotes.preview_footnote()` as fallback when no wikilink found | Yes (integration point, 5-line change) |
| `fzf-lua` | Used by `M.list()` for picker display | Yes (existing dependency) |
| `render-markdown` | Optional: called in floating preview for markdown rendering | No (pcall-wrapped) |

No new external dependencies. The `footnotes.lua` module requires only `config.lua` (already a standard vault dependency). The `preview.lua` integration uses `require("andrew.vault.footnotes")` inside the function body (lazy load, no circular dependency since `footnotes.lua` does not require `preview.lua`).

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Footnote in a code block (`` `[^1]` `` or fenced block) | Matched by pattern — acceptable false positive. Treesitter-based parsing would be more accurate but adds complexity not worth the trade-off for this use case. |
| Multi-line footnote definition | Continuation lines (4-space or tab-indented) are collected by `read_definition_content()` and shown in virtual text up to `max_lines`. |
| Footnote with no content (`[^1]:` with nothing after it) | Empty content array. Virtual text header is shown but no content lines. |
| Multiple references to the same footnote | Virtual text rendered below each reference site independently. Each shows the same definition content. |
| Named footnotes (`[^long-descriptive-name]`) | Supported by the `[%w_-]+` pattern. Displayed in full in headers and picker. |
| Inline footnotes (`^[text]`) | Not handled by this implementation. Inline footnotes have no separate definition — they are self-contained. A future enhancement could detect and highlight them. |
| Very long footnote definitions (50+ lines) | Capped by `config.footnotes.max_lines` in virtual text. Full content shown in floating preview (capped by `preview_max_lines`). Truncation indicator shown in virtual text. |
| Footnote reference on a definition line (`[^1]: See also [^2]`) | The reference `[^2]` within a definition line IS detected as a reference. The definition marker `[^1]` at the start is NOT counted as a reference (guarded by `is_def_marker` check). |
| Buffer with no footnotes | `parse_all_footnotes()` returns empty table. Render/list functions exit early with notification. |
| Non-vault markdown file | Rendering works on any markdown buffer (footnotes are buffer-local, not vault-dependent). The module does not check `engine.is_vault_path()` because footnotes are a markdown feature, not a vault-specific one. |
| Concurrent rendering with embeds | Separate namespace (`VaultFootnote` vs `VaultEmbed`). Clear/toggle operations are independent. Both can be visible simultaneously without interference. |
| Definition appears before any references | Definition is parsed and stored. If references appear later in the file, they are linked. Definitions without references are flagged as orphans. |
| Toggling footnotes after buffer edit | `clear_footnotes()` removes all extmarks. Re-render picks up current buffer state. No stale extmark issues. |

---

## Testing Plan

### Manual Verification

#### 1. Basic virtual text rendering

Create a test markdown file:

```markdown
# Test Note

This has a footnote[^1] in the text.

Another reference[^2] here.

And a named one[^my-note] for good measure.

[^1]: First footnote definition.

[^2]: Second footnote with
    a continuation line
    and another one.

[^my-note]: A named footnote definition.
```

Run `:VaultFootnoteRender`.

**Expected:** Virtual text appears below each reference line showing the definition content. The multi-line definition for `[^2]` shows all continuation lines (up to `max_lines`). Each virtual text block has a header (`── [^1] ──`) and footer border in `VaultFootnoteBorder` highlight.

#### 2. Floating preview

Place cursor on `[^2]` and press `K`.

**Expected:** A floating window appears with the full definition content (all continuation lines). The window title shows `[^2]` in `VaultFootnoteRef` highlight. Moving the cursor closes the float.

#### 3. Enhanced picker

Run `:VaultFootnoteList` (via `<leader>mn`).

**Expected:** The picker shows entries like:
```
10: [^1] (1 ref) :: First footnote definition.
12: [^2] (1 ref) :: Second footnote with
14: [^my-note] (1 ref) :: A named footnote definition.
```

Selecting an entry jumps to the definition line.

#### 4. Orphan detection

Add a reference without a definition:

```markdown
Orphaned reference[^missing] here.
```

Run `:VaultFootnoteOrphans`.

**Expected:** Notification shows:
```
Footnote Orphans:
  References without definitions:
    [^missing] at line(s) 5
```

#### 5. Orphaned definition

Add a definition with no reference:

```markdown
[^unused]: This definition has no corresponding reference.
```

Run `:VaultFootnoteOrphans`.

**Expected:** Notification also includes:
```
  Definitions without references:
    [^unused]: at line 16
```

#### 6. Toggle behavior

Run `:VaultFootnoteRender` to show virtual text. Run `:VaultFootnoteToggle` to hide. Run again to show. Verify extmarks are properly cleared and re-created.

#### 7. Interaction with embed system

In a note with both `![[SomeNote]]` embeds and `[^1]` footnotes:
- Run `:VaultEmbedRender` and `:VaultFootnoteRender`.
- Both virtual text types should be visible simultaneously.
- Run `:VaultFootnoteClear` — only footnote virtual text disappears. Embed virtual text remains.
- Run `:VaultEmbedClear` — embed virtual text disappears. Footnote virtual text (if re-rendered) would remain.

#### 8. K key fallback chain

Place cursor on:
- A wikilink `[[Note]]` — K opens wikilink preview (existing behavior).
- A footnote `[^1]` — K opens footnote floating preview (new behavior).
- Plain text — K shows "No wikilink or footnote under cursor" message.

#### 9. Multi-line definition parsing

```markdown
[^complex]: First line of the definition.
    Second line with continuation.
    Third line with continuation.

    This paragraph after a blank line is NOT part of the footnote.
```

Run `:VaultFootnoteRender`.

**Expected:** Virtual text shows only the first 3 lines (before the blank line). The blank line terminates the definition block.

#### 10. Jump behavior preserved

Existing `<leader>mj` behavior is unchanged:
- On `[^1]` reference: jumps to `[^1]:` definition.
- On `[^1]:` definition: jumps to first `[^1]` reference.

### Performance Verification

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.footnotes").render_footnotes({ silent = true }); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

**Targets:**
- Buffer with 5 footnotes: < 5ms (single buffer scan + extmark creation).
- Buffer with 20 footnotes: < 15ms.
- Buffer with 0 footnotes: < 1ms (early exit).

All operations are buffer-local with no file I/O, no async, and no caching overhead.

### Automated Verification

```lua
-- Test: footnotes module structure
do
  local source = io.open("lua/andrew/vault/footnotes.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- Existing API preserved
    assert_true(content:find("function M.jump") ~= nil, "has M.jump() function")
    assert_true(content:find("function M.list") ~= nil, "has M.list() function")
    assert_true(content:find("function M.next_id") ~= nil, "has M.next_id() function")
    assert_true(content:find("function M.setup") ~= nil, "has M.setup() function")

    -- New rendering functions
    assert_true(content:find("function M.render_footnotes") ~= nil, "has render_footnotes()")
    assert_true(content:find("function M.clear_footnotes") ~= nil, "has clear_footnotes()")
    assert_true(content:find("function M.toggle_footnotes") ~= nil, "has toggle_footnotes()")
    assert_true(content:find("function M.preview_footnote") ~= nil, "has preview_footnote()")
    assert_true(content:find("function M.orphans") ~= nil, "has orphans()")

    -- Parsing infrastructure
    assert_true(content:find("parse_all_footnotes") ~= nil, "has parse_all_footnotes()")
    assert_true(content:find("read_definition_content") ~= nil, "has read_definition_content()")

    -- Extmark namespace
    assert_true(content:find("VaultFootnote") ~= nil, "uses VaultFootnote namespace")

    -- Commands
    assert_true(content:find("VaultFootnoteRender") ~= nil, "defines VaultFootnoteRender command")
    assert_true(content:find("VaultFootnoteClear") ~= nil, "defines VaultFootnoteClear command")
    assert_true(content:find("VaultFootnoteToggle") ~= nil, "defines VaultFootnoteToggle command")
    assert_true(content:find("VaultFootnoteOrphans") ~= nil, "defines VaultFootnoteOrphans command")

    -- No new external requires (only config)
    local requires = {}
    for req in content:gmatch('require%("([^"]+)"%)') do
      requires[req] = true
    end
    assert_true(requires["andrew.vault.config"] ~= nil, "requires config")
  end
end

-- Test: colors.lua has footnote highlights
do
  local source = io.open("lua/andrew/vault/colors.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()
    assert_true(content:find("footnote_ref") ~= nil, "palette has footnote_ref")
    assert_true(content:find("footnote_content") ~= nil, "palette has footnote_content")
    assert_true(content:find("VaultFootnoteRef") ~= nil, "defines VaultFootnoteRef highlight")
    assert_true(content:find("VaultFootnoteBorder") ~= nil, "defines VaultFootnoteBorder highlight")
    assert_true(content:find("VaultFootnoteOrphan") ~= nil, "defines VaultFootnoteOrphan highlight")
  end
end

-- Test: config.lua has footnotes section
do
  local source = io.open("lua/andrew/vault/config.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()
    assert_true(content:find("M.footnotes") ~= nil, "config has M.footnotes section")
    assert_true(content:find("max_lines") ~= nil, "config has max_lines")
    assert_true(content:find("preview_max_lines") ~= nil, "config has preview_max_lines")
  end
end

-- Test: preview.lua has footnote fallback
do
  local source = io.open("lua/andrew/vault/preview.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()
    assert_true(content:find("preview_footnote") ~= nil, "preview.lua calls footnote preview")
    assert_true(content:find("andrew.vault.footnotes") ~= nil, "preview.lua requires footnotes module")
  end
end
```

---

## Future Enhancements

1. **Treesitter-based parsing** — Use treesitter's `footnote_reference` and `footnote_definition` node types instead of Lua patterns. This would eliminate false positives in code blocks and handle edge cases in complex markdown. The trade-off is parser availability and complexity.

2. **Cross-file footnote resolution** — For vaults where footnotes are defined in a shared "References" note and referenced in other notes. Would require vault index integration.

3. **Inline footnote support** — Detect `^[inline text]` (Pandoc extension) and render appropriately. These are self-contained and do not need definition lookup.

4. **Footnote renumbering** — `:VaultFootnoteRenumber` command to sequentially renumber all footnotes in a buffer (1, 2, 3, ...) while maintaining ref/def correspondence.

5. **Diagnostic signs** — Use `vim.diagnostic` API to place sign column indicators for orphaned footnotes, similar to how `linkdiag.lua` marks broken wikilinks.

6. **Auto-creation of definitions** — When `<leader>mj` is pressed on a reference with no definition, offer to create the definition at the bottom of the buffer (or in a configurable location).

7. **Footnote backlinks** — In the floating preview, show which line(s) reference this footnote, with clickable links to jump back.
