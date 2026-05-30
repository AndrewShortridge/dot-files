# 20 — Preview Improvements: History, Nested Navigation, and Breadcrumbs

## Problem

The vault's `preview.lua` module provides a floating preview window for wikilinks (K key), with scroll support (C-j/C-k) and an edit-in-float variant (`<leader>vE`). While functional for quick glances at a single note, the preview lacks capabilities that become essential when navigating a densely-linked knowledge base:

### No History Navigation

When previewing multiple links in sequence (close preview, move cursor, open new preview), there is no way to return to a previously-viewed preview. Each K press creates a fresh, stateless float. In a typical workflow, a user might preview note A, close it, preview note B, then want to compare with note A again. Currently this requires navigating back to the original wikilink and pressing K again. There is no `<C-o>` / `<C-i>` jumplist analog within the preview context.

### No Nested Preview (Cannot Follow Links Inside Preview)

The preview float displays rendered markdown content, which often contains wikilinks to other notes. These links are visible but inert -- the user cannot follow them without closing the preview, navigating to the linked note, finding the desired link, and opening a new preview. This breaks the "peek and explore" workflow that makes floating previews useful. Obsidian's hover preview supports click-through to linked notes; the vault preview should support an equivalent keyboard-driven interaction.

### Minimal Title Context

The current float title shows the link target as-is: `" NoteName "`, `" NoteName#Heading "`, or `" #Heading "`. This provides no vault-relative path context. When previewing a note named `Dashboard` that exists in multiple project directories, the title does not disambiguate which `Dashboard` is being shown. The breadcrumbs module (`breadcrumbs.lua`) already solves this for the winbar, but its formatting is not available in the preview float.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **preview.lua** | Floating preview (K key); scroll (C-j/C-k); toggle close; edit-in-float (`<leader>vE`) | `lua/andrew/vault/preview.lua` (~320 lines) |
| **wikilinks.lua** | Link following (gf); `resolve_link()`; jump between links (`]o`/`[o`) | `lua/andrew/vault/wikilinks.lua` (~538 lines) |
| **link_utils.lua** | `get_wikilink_under_cursor()`; `parse_target()`; heading/block section readers | `lua/andrew/vault/link_utils.lua` (~223 lines) |
| **breadcrumbs.lua** | Winbar breadcrumb trail; `build_segments()` with vault-relative path; parent-project frontmatter override | `lua/andrew/vault/breadcrumbs.lua` (~130 lines) |
| **ui.lua** | `create_float_display()` and `create_float_input()` helpers | `lua/andrew/vault/ui.lua` (~109 lines) |
| **config.lua** | `M.preview` section: `max_lines = 25`, `max_width = 80` | `lua/andrew/vault/config.lua` (~544 lines) |
| **colors.lua** | Centralized palette and highlight definitions for all vault modules | `lua/andrew/vault/colors.lua` (~381 lines) |
| **engine.lua** | `vault_path`, `vault_relative()`, `is_vault_path()`, `read_file_lines()` | `lua/andrew/vault/engine.lua` |

---

## Goal

Enhance the preview system with three integrated capabilities:

1. **Preview history navigation** -- Maintain a session-scoped stack of previously previewed targets, with `<C-o>` (back) and `<C-i>` (forward) navigation within the preview float, and a position indicator in the title.

2. **Nested preview (follow links inside preview)** -- Detect wikilinks in the preview buffer and allow `gf` / `K` inside the float to replace its content with the linked note, pushing the current target onto the history stack.

3. **Preview breadcrumbs** -- Show vault-relative path context in the float title, formatted as a breadcrumb trail with distinct highlight segments, updating dynamically as the user navigates history or follows nested links.

---

## Approach

### Architecture

All three features are implemented within `preview.lua`, with minor additions to `config.lua` and `colors.lua`. No new files are created. The key architectural change is introducing a **history stack** as module-level state, and a **target descriptor** type that encapsulates everything needed to render a preview for a given link target.

```
preview.lua (enhanced)
  |
  +-- Data types
  |   +-- PreviewTarget           (NEW: {path, heading, block_id, name, lines})
  |   +-- PreviewHistory          (NEW: {entries[], cursor, max_size})
  |
  +-- History management
  |   +-- push_history(target)    (NEW: push current target, advance cursor)
  |   +-- pop_back()              (NEW: move cursor back, return target)
  |   +-- pop_forward()           (NEW: move cursor forward, return target)
  |   +-- clear_history()         (NEW: reset on full close)
  |   +-- history_position()      (NEW: "3/7" string for title)
  |
  +-- Breadcrumb formatting
  |   +-- format_breadcrumb(target)           (NEW: build title chunks)
  |   +-- vault_relative_segments(path)       (NEW: split path into segments)
  |   +-- truncate_breadcrumb(chunks, max_w)  (NEW: left-truncation)
  |
  +-- Target resolution
  |   +-- resolve_target(details)    (NEW: build PreviewTarget from parsed link)
  |   +-- resolve_target_in_buf(buf) (NEW: detect link under cursor in preview buf)
  |
  +-- Float management
  |   +-- replace_float_content(target)  (NEW: swap content without close/reopen)
  |   +-- update_float_title(target)     (NEW: refresh title with breadcrumb + history)
  |
  +-- Public API
  |   +-- M.preview()             (ENHANCED: history integration, breadcrumb title)
  |   +-- M.edit_link()           (existing, unchanged)
  |   +-- M.setup()               (ENHANCED: new config wiring)
  |
  +-- Float-local keymaps
      +-- <C-o>  -> navigate back in history
      +-- <C-i>  -> navigate forward in history
      +-- gf / K -> follow link inside preview (nested navigation)
      +-- <BS>   -> alias for <C-o> (convenient back navigation)

config.lua (extended)
  +-- M.preview.history_max = 20
  +-- M.preview.nested_preview = true
  +-- M.preview.breadcrumb_style = "full"  -- "full", "short", "none"
  +-- M.preview.breadcrumb_separator = " > "

colors.lua (extended)
  +-- New palette keys: preview_breadcrumb_path, preview_breadcrumb_note,
  |                     preview_breadcrumb_sep, preview_breadcrumb_fragment
  +-- New highlight groups: VaultPreviewBreadcrumbPath, VaultPreviewBreadcrumbNote,
                            VaultPreviewBreadcrumbSep, VaultPreviewBreadcrumbFragment
```

### Key Design Decisions

1. **Single float, content replacement.** Rather than opening a new float for each nested navigation, the existing float's buffer content is replaced in-place. This avoids z-ordering issues, flicker from close/reopen cycles, and unbounded float proliferation. The float window ID and buffer are reused; only the lines, title, and dimensions change.

2. **History stack with cursor, not ring buffer.** The history uses a linear array with a cursor index. Navigating back decrements the cursor; navigating forward increments it. Following a new link while mid-history truncates the forward entries (same semantics as browser history). This is simpler than a ring buffer and matches user expectations from browser/editor jumplist behavior.

3. **History cleared on full close only.** Closing the preview via K toggle, CursorMoved, or BufLeave clears the entire history. The history is a transient exploration aid, not a persistent record. If the user wants to return to a previously-viewed note, they use the vault jumplist or fzf, not the preview history.

4. **Breadcrumbs reuse engine utilities, not breadcrumbs.lua.** The existing `breadcrumbs.lua` module is tightly coupled to the winbar (`%#HlGroup#` statusline syntax, `%@click_handler@` click targets). The preview float title uses `nvim_open_win` title chunks (`{ {text, hl_group} ... }`), which is a different API. Rather than refactoring `breadcrumbs.lua` to serve both contexts, the preview builds its own breadcrumb segments using `engine.vault_relative()` and `engine.vault_path` directly. The formatting logic is ~30 lines and not worth abstracting into a shared module.

5. **Float-local keymaps on the preview buffer.** The preview buffer is a scratch buffer with `modifiable = false`. Buffer-local keymaps for `gf`, `K`, `<C-o>`, `<C-i>`, and `<BS>` are set when the buffer is created. These do not conflict with parent buffer keymaps since the preview buffer is a separate `bufnr`. The parent buffer retains its `C-j`/`C-k` scroll keymaps and `CursorMoved` close autocmd.

6. **Nested preview depth is bounded by history_max.** Each nested navigation pushes onto the history stack. When the stack reaches `history_max`, the oldest entry is evicted. This naturally caps nesting depth without a separate depth counter.

---

## Implementation

### 1. Config changes: `config.lua`

**File:** `lua/andrew/vault/config.lua`

Replace the existing `M.preview` section (lines 58-61) with:

```lua
-- ---------------------------------------------------------------------------
-- Preview
-- ---------------------------------------------------------------------------
M.preview = {
  max_lines = 25,
  max_width = 80,
  -- History navigation within the preview float.
  -- Tracks previously-viewed targets for <C-o>/<C-i> navigation.
  history_max = 20,
  -- Allow following wikilinks inside the preview float (gf/K in float).
  nested_preview = true,
  -- Breadcrumb title style: "full" (vault-relative path), "short" (note name only), "none" (legacy title).
  breadcrumb_style = "full",
  -- Separator character between breadcrumb segments.
  breadcrumb_separator = " \u{203A} ",
}
```

### 2. Color palette and highlight groups: `colors.lua`

**File:** `lua/andrew/vault/colors.lua`

Add preview breadcrumb palette keys to each palette definition.

**In the `onedark` palette** (after `embed_error`, before `-- Footnotes`):

```lua
  -- Preview breadcrumbs
  preview_breadcrumb_path     = "#5c6370",
  preview_breadcrumb_note     = "#61afef",
  preview_breadcrumb_sep      = "#5c6370",
  preview_breadcrumb_fragment = "#98c379",
```

**In the `soft_paper_light` palette** (same location):

```lua
  -- Preview breadcrumbs
  preview_breadcrumb_path     = "#CAC1B9",  -- c.surface2
  preview_breadcrumb_note     = "#1A7DA4",  -- c.accent
  preview_breadcrumb_sep      = "#CAC1B9",  -- c.surface2
  preview_breadcrumb_fragment = "#5BA57B",  -- c.green
```

**In the `soft_paper_dark` palette** (same location):

```lua
  -- Preview breadcrumbs
  preview_breadcrumb_path     = "#62677E",  -- c.surface2
  preview_breadcrumb_note     = "#11B7C5",  -- c.accent
  preview_breadcrumb_sep      = "#62677E",  -- c.surface2
  preview_breadcrumb_fragment = "#67C48F",  -- c.green
```

**In `build_hl_groups()`** (after `VaultEmbedError`, before `-- Footnotes`):

```lua
    -- Preview breadcrumbs
    VaultPreviewBreadcrumbPath     = { fg = p.preview_breadcrumb_path },
    VaultPreviewBreadcrumbNote     = { fg = p.preview_breadcrumb_note, bold = true },
    VaultPreviewBreadcrumbSep      = { fg = p.preview_breadcrumb_sep },
    VaultPreviewBreadcrumbFragment = { fg = p.preview_breadcrumb_fragment, italic = true },
```

### 3. Preview module enhancements: `preview.lua`

**File:** `lua/andrew/vault/preview.lua`

Complete rewrite preserving the existing public API (`M.preview()`, `M.edit_link()`, `M.setup()`) and adding history navigation, nested preview, and breadcrumb formatting.

#### 3.1 Data Structures

```lua
--- A preview target descriptor. Captures everything needed to render a preview.
---@class PreviewTarget
---@field path string|nil      Absolute file path (nil for same-file references)
---@field name string          Display name from the wikilink (e.g., "ProjectNote")
---@field heading string|nil   Heading fragment (without #)
---@field block_id string|nil  Block ID fragment (without ^)
---@field lines string[]       Resolved content lines to display
---@field source_buf number|nil  Buffer number for same-file references (for live lines)

--- History state. Module-level, persists within session.
---@class PreviewHistory
---@field entries PreviewTarget[]  Ordered list of visited targets
---@field cursor number            1-indexed position within entries (0 = no history)
---@field max_size number          Maximum entries before eviction
local history = {
  entries = {},
  cursor = 0,
  max_size = 20, -- overridden from config during setup()
}
```

#### 3.2 History Management

```lua
--- Push a target onto the history stack.
--- If the cursor is mid-stack (user navigated back then follows a new link),
--- truncate all forward entries before pushing (browser-style).
---@param target PreviewTarget
local function push_history(target)
  -- Truncate forward entries if cursor is not at the end
  if history.cursor < #history.entries then
    for i = #history.entries, history.cursor + 1, -1 do
      history.entries[i] = nil
    end
  end

  -- Evict oldest if at capacity
  if #history.entries >= history.max_size then
    table.remove(history.entries, 1)
    -- cursor stays valid (points to what was previously cursor-1)
  end

  history.entries[#history.entries + 1] = target
  history.cursor = #history.entries
end

--- Navigate backward in history. Returns the target to display, or nil.
---@return PreviewTarget|nil
local function pop_back()
  if history.cursor <= 1 then
    return nil
  end
  history.cursor = history.cursor - 1
  return history.entries[history.cursor]
end

--- Navigate forward in history. Returns the target to display, or nil.
---@return PreviewTarget|nil
local function pop_forward()
  if history.cursor >= #history.entries then
    return nil
  end
  history.cursor = history.cursor + 1
  return history.entries[history.cursor]
end

--- Clear all history entries. Called when the preview is fully closed.
local function clear_history()
  history.entries = {}
  history.cursor = 0
end

--- Return a human-readable position string for the title, e.g., "[3/7]".
--- Returns empty string if only one entry (no navigation context needed).
---@return string
local function history_position()
  if #history.entries <= 1 then
    return ""
  end
  return "[" .. history.cursor .. "/" .. #history.entries .. "]"
end
```

#### 3.3 Target Resolution

```lua
--- Build a PreviewTarget from parsed wikilink details.
--- Resolves the file path, reads content lines, and populates all fields.
---@param details { name: string, heading: string|nil, block_id: string|nil }
---@param parent_buf number  The buffer from which the preview was triggered
---@return PreviewTarget|nil  nil if the link cannot be resolved
local function resolve_target(details, parent_buf)
  local target = {
    name = details.name,
    heading = details.heading,
    block_id = details.block_id,
    path = nil,
    lines = {},
    source_buf = nil,
  }

  if details.name == "" then
    -- Same-file reference: [[#heading]] or [[^block-id]]
    target.source_buf = parent_buf
    local buf_lines = vim.api.nvim_buf_get_lines(parent_buf, 0, -1, false)
    if details.heading then
      target.lines = link_utils.read_heading_section(buf_lines, details.heading)
      if #target.lines == 0 then
        target.lines = { "[Heading not found: #" .. details.heading .. "]" }
      end
    elseif details.block_id then
      target.lines = link_utils.read_block_content(buf_lines, details.block_id)
      if #target.lines == 0 then
        target.lines = { "[Block not found: ^" .. details.block_id .. "]" }
      end
    else
      return nil
    end
  else
    -- Cross-file reference
    local path = wikilinks.resolve_link(details.name)
    if path then
      target.path = path
      if details.heading then
        target.lines = link_utils.read_heading_section(path, details.heading)
        if #target.lines == 0 then
          target.lines = { "[Heading not found: #" .. details.heading .. "]" }
        end
      elseif details.block_id then
        target.lines = link_utils.read_block_content(path, details.block_id)
        if #target.lines == 0 then
          target.lines = { "[Block not found: ^" .. details.block_id .. "]" }
        end
      else
        target.lines = engine.read_file_lines(path)
        if #target.lines == 0 then
          target.lines = { "[Could not read file]" }
        end
      end
    else
      target.lines = { "[Note does not exist yet]" }
    end
  end

  return target
end

--- Detect the wikilink under the cursor in a preview buffer.
--- The preview buffer is a scratch buffer with markdown content, so the
--- same cursor/line-based detection logic from link_utils works.
---@param buf number  Preview buffer number
---@param win number  Preview window number
---@return { name: string, heading: string|nil, block_id: string|nil }|nil
local function detect_link_in_preview(buf, win)
  -- Get cursor position within the preview window
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line_idx = cursor[1] - 1
  local col = cursor[2] + 1

  local lines = vim.api.nvim_buf_get_lines(buf, line_idx, line_idx + 1, false)
  if #lines == 0 then return nil end
  local line = lines[1]

  -- Find wikilink at cursor position (same logic as link_utils.get_wikilink_under_cursor
  -- but operating on explicit line/col rather than current window)
  local start = 1
  while true do
    local open_start, open_end = line:find("%[%[", start)
    if not open_start then return nil end
    local close_start, close_end = line:find("%]%]", open_end + 1)
    if not close_start then return nil end

    if col >= open_start and col <= close_end then
      local inner = line:sub(open_end + 1, close_start - 1)
      return link_utils.parse_target(inner)
    end

    start = close_end + 1
  end
end
```

#### 3.4 Breadcrumb Formatting

```lua
--- Split an absolute file path into vault-relative breadcrumb segments.
--- Returns { "Vault", "Projects", "MyProject", "Note.md" } for a file at
--- {vault_root}/Projects/MyProject/Note.md.
---@param path string|nil  Absolute path (nil for same-file refs)
---@param parent_buf number|nil  Parent buffer for same-file ref context
---@return string[]  Ordered segments from vault root to filename
local function vault_relative_segments(path, parent_buf)
  local abs_path = path
  if not abs_path and parent_buf then
    abs_path = vim.api.nvim_buf_get_name(parent_buf)
  end
  if not abs_path or abs_path == "" then
    return { "Vault" }
  end

  local rel = engine.vault_relative(abs_path)
  if not rel or rel == "" then
    -- Not a vault path; show basename only
    return { vim.fn.fnamemodify(abs_path, ":t") }
  end

  local segments = { "Vault" }
  for seg in rel:gmatch("[^/]+") do
    segments[#segments + 1] = seg
  end
  return segments
end

--- Format a PreviewTarget into float title chunks (array of {text, hl_group} pairs).
--- Produces breadcrumb trail: "Vault > Projects > Note.md #Heading [3/7]"
---
--- Uses config.preview.breadcrumb_style:
---   "full"  -> full vault-relative path with separator
---   "short" -> note name only (legacy-like)
---   "none"  -> raw link target text (current behavior)
---
---@param target PreviewTarget
---@return table[] title_chunks  Array of {text, hl_group} for nvim_open_win title
local function format_breadcrumb(target)
  local style = config.preview.breadcrumb_style or "full"

  if style == "none" then
    -- Legacy behavior: just the link target text
    local title = target.name
    if target.heading then
      title = (target.name ~= "" and target.name or "") .. "#" .. target.heading
    elseif target.block_id then
      title = (target.name ~= "" and target.name or "") .. "^" .. target.block_id
    end
    local pos = history_position()
    if pos ~= "" then
      title = title .. " " .. pos
    end
    return { { " " .. title .. " ", "Function" } }
  end

  local sep = config.preview.breadcrumb_separator or " \u{203A} "
  local sep_hl = "VaultPreviewBreadcrumbSep"
  local path_hl = "VaultPreviewBreadcrumbPath"
  local note_hl = "VaultPreviewBreadcrumbNote"
  local frag_hl = "VaultPreviewBreadcrumbFragment"

  local chunks = {}
  chunks[#chunks + 1] = { " ", sep_hl }  -- left padding

  if style == "short" then
    -- Note name only
    local note_name = target.name
    if note_name == "" then
      note_name = vim.fn.fnamemodify(
        vim.api.nvim_buf_get_name(target.source_buf or 0), ":t:r"
      )
    end
    chunks[#chunks + 1] = { note_name, note_hl }
  else
    -- Full breadcrumb: Vault > Dir > Note.md
    local segments = vault_relative_segments(target.path, target.source_buf)

    for i, seg in ipairs(segments) do
      if i == #segments then
        -- Last segment (filename): use note highlight, strip .md
        local display = seg:gsub("%.md$", "")
        chunks[#chunks + 1] = { display, note_hl }
      else
        chunks[#chunks + 1] = { seg, path_hl }
      end
      if i < #segments then
        chunks[#chunks + 1] = { sep, sep_hl }
      end
    end
  end

  -- Append heading or block fragment
  if target.heading then
    chunks[#chunks + 1] = { " #" .. target.heading, frag_hl }
  elseif target.block_id then
    chunks[#chunks + 1] = { " ^" .. target.block_id, frag_hl }
  end

  -- Append history position
  local pos = history_position()
  if pos ~= "" then
    chunks[#chunks + 1] = { " " .. pos, sep_hl }
  end

  chunks[#chunks + 1] = { " ", sep_hl }  -- right padding

  return chunks
end

--- Truncate breadcrumb chunks from the left to fit within max_width.
--- Replaces leading path segments with "..." until the total display width
--- fits within the constraint.
---@param chunks table[]  Array of {text, hl_group} pairs
---@param max_width number  Maximum display width
---@return table[]  Truncated chunks
local function truncate_breadcrumb(chunks, max_width)
  -- Calculate total display width
  local total_w = 0
  for _, chunk in ipairs(chunks) do
    total_w = total_w + vim.fn.strdisplaywidth(chunk[1])
  end

  if total_w <= max_width then
    return chunks
  end

  -- Strategy: find path segments (not the first padding, note, fragment, or last padding)
  -- and replace them left-to-right with a single "..." chunk until we fit.
  local sep = config.preview.breadcrumb_separator or " \u{203A} "
  local sep_hl = "VaultPreviewBreadcrumbSep"
  local path_hl = "VaultPreviewBreadcrumbPath"
  local ellipsis_w = vim.fn.strdisplaywidth("\u{2026}" .. sep)

  -- Find the range of path segments that can be truncated.
  -- Path segments use path_hl and are not the first/last entry.
  local first_path_idx = nil
  local last_path_idx = nil
  for i, chunk in ipairs(chunks) do
    if chunk[2] == path_hl then
      if not first_path_idx then first_path_idx = i end
      last_path_idx = i
    end
  end

  if not first_path_idx then
    -- No path segments to truncate; return as-is
    return chunks
  end

  -- Remove path segments from the left (and their trailing separators)
  -- until the total fits
  local result = {}
  local removed_any = false
  local skip_until = 0

  for i, chunk in ipairs(chunks) do
    if i <= skip_until then
      -- skip
    elseif i >= first_path_idx and i <= last_path_idx
           and chunk[2] == path_hl and total_w > max_width then
      -- Remove this path segment
      local removed_w = vim.fn.strdisplaywidth(chunk[1])
      total_w = total_w - removed_w

      -- Also remove the following separator if present
      if chunks[i + 1] and chunks[i + 1][2] == sep_hl
         and chunks[i + 1][1] == sep then
        total_w = total_w - vim.fn.strdisplaywidth(sep)
        skip_until = i + 1
      end

      if not removed_any then
        result[#result + 1] = { "\u{2026}" .. sep, sep_hl }
        total_w = total_w + ellipsis_w
        removed_any = true
      end
    else
      result[#result + 1] = chunk
    end
  end

  return result
end
```

#### 3.5 Float Content Management

```lua
--- Replace the content of the active preview float with a new target.
--- Reuses the existing window and buffer, updating lines, title, and dimensions.
--- If the window is no longer valid, does nothing.
---@param target PreviewTarget
local function replace_float_content(target)
  if not is_active() then return end

  -- Unlock buffer for modification
  vim.bo[state.buf].modifiable = true

  -- Replace content
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, target.lines)

  -- Recompute dimensions
  local max_width = config.preview.max_width
  local max_height = config.preview.max_lines
  local width = 0
  for _, l in ipairs(target.lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width, 20), max_width)
  local height = math.min(#target.lines, max_height)

  -- Update window dimensions
  vim.api.nvim_win_set_config(state.win, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
  })

  -- Update title
  update_float_title(target)

  -- Re-setup markdown rendering
  vim.bo[state.buf].filetype = "markdown"
  pcall(vim.treesitter.start, state.buf, "markdown")
  pcall(function()
    require("render-markdown").render({ buf = state.buf, win = state.win })
  end)

  -- Lock buffer after rendering
  vim.bo[state.buf].modifiable = false
end

--- Update only the float title (breadcrumb + history position).
---@param target PreviewTarget
local function update_float_title(target)
  if not is_active() then return end

  local float_width = vim.api.nvim_win_get_width(state.win)
  local max_title_w = float_width - 4  -- padding for border corners

  local chunks = format_breadcrumb(target)
  chunks = truncate_breadcrumb(chunks, max_title_w)

  vim.api.nvim_win_set_config(state.win, {
    relative = "cursor",
    row = 1,
    col = 0,
    title = chunks,
    title_pos = "center",
  })
end
```

#### 3.6 Float-Local Keymaps for Nested Navigation

When the preview float is created, the following buffer-local keymaps are set on the preview buffer. These keymaps require the float to be focused temporarily (via `nvim_set_current_win`) or use `nvim_buf_set_keymap` with a callback that operates on the known state variables.

Since the current preview is non-focused (the parent window remains active), the nested navigation keymaps are set on the **parent buffer** and check whether the preview is active before acting. The `gf` and `K` keys in the parent are already bound to `follow_link` and `M.preview()` respectively; the nested navigation extends the scroll keymap pattern (C-j/C-k already work this way).

```lua
--- Set up keymaps on the parent buffer for nested preview navigation.
--- Called after the float is created, alongside the existing C-j/C-k scroll keymaps.
---@param parent_buf number
local function setup_nested_keymaps(parent_buf)
  if not config.preview.nested_preview then return end

  -- <C-o> -- navigate back in preview history
  vim.keymap.set("n", "<C-o>", function()
    if not is_active() then return end
    local target = pop_back()
    if target then
      replace_float_content(target)
    else
      vim.notify("Preview: beginning of history", vim.log.levels.INFO)
    end
  end, { buffer = parent_buf, nowait = true, silent = true, desc = "Preview: history back" })

  -- <C-i> -- navigate forward in preview history
  vim.keymap.set("n", "<C-i>", function()
    if not is_active() then return end
    local target = pop_forward()
    if target then
      replace_float_content(target)
    else
      vim.notify("Preview: end of history", vim.log.levels.INFO)
    end
  end, { buffer = parent_buf, nowait = true, silent = true, desc = "Preview: history forward" })

  -- <BS> -- alias for <C-o> (convenient back navigation)
  vim.keymap.set("n", "<BS>", function()
    if not is_active() then return end
    local target = pop_back()
    if target then
      replace_float_content(target)
    end
  end, { buffer = parent_buf, nowait = true, silent = true, desc = "Preview: history back" })
end
```

**Alternative approach for `gf`/`K` inside the preview float:** Since the preview buffer is non-focused, the user cannot directly interact with it via cursor-based keymaps. Two viable approaches:

**Option A: Focused preview mode.** Add a keymap on the parent buffer (e.g., `<CR>` or `<C-l>`) that focuses the preview float. Once focused, standard `gf` and `K` keymaps apply (set as buffer-local on the preview buffer). A `<C-h>` or `q` keymap in the preview buffer returns focus to the parent.

**Option B: Visual link cursor in preview.** Track a "virtual cursor" position in the preview buffer. `]o` / `[o` on the parent buffer cycle through links visible in the preview. `<CR>` on the parent follows the highlighted link. This avoids focus switching but adds complexity.

**Recommended: Option A** -- it is simpler, leverages existing keymap infrastructure, and gives the user full cursor control within the preview for precise link selection.

```lua
--- Focus the preview float, setting up keymaps for nested navigation.
--- The preview buffer gains gf, K, q, <C-h> keymaps while focused.
local function focus_preview()
  if not is_active() then return end

  -- Remember that we're in focused mode (affects close behavior)
  state.focused = true

  -- Focus the float window
  vim.api.nvim_set_current_win(state.win)

  -- Make buffer temporarily navigable (still not modifiable)
  vim.wo[state.win].cursorline = true

  -- Set float-local keymaps
  local buf = state.buf
  local opts = { buffer = buf, nowait = true, silent = true }

  -- gf: follow wikilink under cursor within the preview
  vim.keymap.set("n", "gf", function()
    local details = detect_link_in_preview(buf, state.win)
    if not details then
      vim.notify("No wikilink under cursor in preview", vim.log.levels.INFO)
      return
    end
    navigate_in_preview(details)
  end, vim.tbl_extend("force", opts, { desc = "Preview: follow link" }))

  -- K: same as gf (preview the link under cursor)
  vim.keymap.set("n", "K", function()
    local details = detect_link_in_preview(buf, state.win)
    if not details then return end
    navigate_in_preview(details)
  end, vim.tbl_extend("force", opts, { desc = "Preview: follow link" }))

  -- q or <C-h>: return focus to parent
  vim.keymap.set("n", "q", function()
    unfocus_preview()
  end, vim.tbl_extend("force", opts, { desc = "Preview: return to parent" }))

  vim.keymap.set("n", "<C-h>", function()
    unfocus_preview()
  end, vim.tbl_extend("force", opts, { desc = "Preview: return to parent" }))

  -- <C-o>: navigate back
  vim.keymap.set("n", "<C-o>", function()
    local target = pop_back()
    if target then
      replace_float_content(target)
    end
  end, vim.tbl_extend("force", opts, { desc = "Preview: history back" }))

  -- <C-i>: navigate forward
  vim.keymap.set("n", "<C-i>", function()
    local target = pop_forward()
    if target then
      replace_float_content(target)
    end
  end, vim.tbl_extend("force", opts, { desc = "Preview: history forward" }))

  -- <BS>: alias for back
  vim.keymap.set("n", "<BS>", function()
    local target = pop_back()
    if target then
      replace_float_content(target)
    end
  end, vim.tbl_extend("force", opts, { desc = "Preview: history back" }))
end

--- Return focus from the preview float to the parent window.
local function unfocus_preview()
  if not state.focused then return end
  state.focused = false
  vim.wo[state.win].cursorline = false

  -- Return to parent window
  local parent_win = vim.fn.bufwinid(state.parent_buf)
  if parent_win ~= -1 then
    vim.api.nvim_set_current_win(parent_win)
  end
end

--- Follow a link detected inside the preview float.
--- Pushes the current target onto history and replaces float content.
---@param details { name: string, heading: string|nil, block_id: string|nil }
local function navigate_in_preview(details)
  -- Resolve the new target using the current preview target's context
  local current = history.entries[history.cursor]

  -- For same-file refs inside the preview, the "file" is the preview target's file
  local effective_parent = state.parent_buf
  if current and current.path then
    -- The link is relative to the file being previewed, not the parent buffer.
    -- We need to resolve using the preview target's file context.
    -- Create a temporary approach: if details.name is empty, use current.path
    -- as the source for heading/block resolution.
  end

  local new_target = resolve_target(details, effective_parent)
  if not new_target then
    vim.notify("Cannot resolve link in preview", vim.log.levels.WARN)
    return
  end

  -- Push current onto history
  if current then
    push_history(current)
  end
  push_history(new_target)

  -- Replace float content
  replace_float_content(new_target)
end
```

#### 3.7 Enhanced `M.preview()` — Main Entry Point

```lua
--- Show a floating preview of the note linked under the cursor.
--- Enhanced with history tracking, breadcrumb titles, and nested navigation support.
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

  local parent_buf = vim.api.nvim_get_current_buf()
  local target = resolve_target(details, parent_buf)
  if not target then
    vim.notify("No wikilink under cursor", vim.log.levels.INFO)
    return
  end

  -- Initialize history with this target
  clear_history()
  push_history(target)

  -- Compute float dimensions
  local max_width = config.preview.max_width
  local max_height = config.preview.max_lines
  local width = 0
  for _, l in ipairs(target.lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width, 20), max_width)
  local height = math.min(#target.lines, max_height)

  -- Build breadcrumb title
  local title_chunks = format_breadcrumb(target)
  title_chunks = truncate_breadcrumb(title_chunks, width - 4)

  -- Create buffer with content
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, target.lines)
  vim.bo[buf].bufhidden = "wipe"

  -- Open floating window (not focused)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title_chunks,
    title_pos = "center",
  })

  -- Window options
  vim.wo[win].conceallevel = 2
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].foldenable = false

  -- Set filetype and start treesitter
  vim.bo[buf].filetype = "markdown"
  pcall(vim.treesitter.start, buf, "markdown")
  pcall(function()
    require("render-markdown").render({ buf = buf, win = win })
  end)

  -- Lock buffer
  vim.bo[buf].modifiable = false

  -- Store state
  state.win = win
  state.buf = buf
  state.parent_buf = parent_buf
  state.focused = false

  -- Scroll keymaps on parent buffer
  local scroll_amount = 3
  vim.keymap.set("n", "<C-j>", function()
    scroll_preview(scroll_amount)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview down" })
  vim.keymap.set("n", "<C-k>", function()
    scroll_preview(-scroll_amount)
  end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Scroll preview up" })

  -- Focus keymap: <CR> on parent enters the preview float for nested navigation
  if config.preview.nested_preview then
    vim.keymap.set("n", "<CR>", function()
      if is_active() then
        focus_preview()
      end
    end, { buffer = state.parent_buf, nowait = true, silent = true, desc = "Preview: enter float" })
  end

  -- History navigation keymaps on parent buffer
  setup_nested_keymaps(state.parent_buf)

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
    callback = function()
      -- If we're leaving because we focused the preview float, don't close
      if state.focused then return end
      close_preview()
    end,
  })
end
```

#### 3.8 Enhanced `close_preview()` — Cleanup with History

```lua
--- Close the active preview and clean up keymaps/autocmds.
--- Clears the history stack (preview is transient, not persistent).
local function close_preview()
  -- If focused in the preview, return to parent first
  if state.focused then
    unfocus_preview()
  end

  -- Remove parent buffer keymaps
  if state.parent_buf and vim.api.nvim_buf_is_valid(state.parent_buf) then
    for _, key in ipairs({ "<C-j>", "<C-k>", "<C-o>", "<C-i>", "<BS>", "<CR>" }) do
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
  state.focused = false

  -- Clear history on full close
  clear_history()
end
```

---

## Keybinding Summary

All keybindings operate within the preview context. Parent-buffer bindings are set when the preview opens and removed when it closes.

### Parent Buffer (preview open, not focused)

| Key | Action | Notes |
|-----|--------|-------|
| `K` | Toggle preview (close) | Existing behavior |
| `C-j` | Scroll preview down | Existing behavior |
| `C-k` | Scroll preview up | Existing behavior |
| `C-o` | Navigate back in preview history | New |
| `C-i` | Navigate forward in preview history | New |
| `BS` | Alias for `C-o` (back) | New |
| `CR` | Enter/focus the preview float | New (enables nested navigation) |

### Preview Buffer (focused mode after `<CR>`)

| Key | Action | Notes |
|-----|--------|-------|
| `gf` | Follow wikilink under cursor (nested preview) | New |
| `K` | Follow wikilink under cursor (same as gf) | New |
| `C-o` | Navigate back in history | New |
| `C-i` | Navigate forward in history | New |
| `BS` | Alias for `C-o` | New |
| `q` | Return focus to parent buffer | New |
| `C-h` | Return focus to parent buffer | New |

---

## Edge Cases

### Deep Nesting
Each nested navigation pushes onto the history stack. When `history_max` (default 20) is reached, the oldest entry is evicted via `table.remove(entries, 1)`. The cursor is adjusted accordingly. This naturally bounds memory usage and nesting depth. No explicit depth counter is needed.

### Broken Links in Preview
If a wikilink inside the preview cannot be resolved (note does not exist), `resolve_target()` returns a target with `lines = { "[Note does not exist yet]" }`. This is displayed in the preview float just like a broken link in the top-level preview. The broken target is still pushed onto history, allowing the user to navigate back.

### Link to Self
If a preview of Note A contains a link to Note A itself, following it creates a new target for the same file. This is intentional -- the user may be following a same-file heading link (`[[#Section]]`) within the previewed note. No special-casing is needed.

### Circular References
A -> B -> C -> A navigation is allowed. Each step creates a separate history entry. There is no cycle detection at the preview level (unlike embed.lua which must prevent infinite recursion). The history stack's finite size naturally prevents unbounded loops.

### Same-File References in Nested Context
When the user follows `[[#Heading]]` inside a preview of Note B, the heading should be resolved within Note B's content, not the parent buffer's content. The `navigate_in_preview()` function must use the current preview target's path as the resolution context, not `state.parent_buf`. This requires passing the resolved file path to `link_utils.read_heading_section()`.

### History Truncation on New Navigation
If the user navigates back 3 steps (cursor at position 4 of 7), then follows a new link, positions 5-7 are discarded. The new target becomes position 5. This matches browser back/forward semantics and prevents a confusing branching history.

### Focus Transitions and Auto-Close
The `CursorMoved` autocmd on the parent buffer closes the preview. When the user presses `<CR>` to focus the preview float, a `BufLeave` event fires on the parent buffer. The `close_preview` callback must check `state.focused` and skip closing if the user is entering focused mode. Similarly, when the user presses `q` in the preview float to return to the parent, the `BufLeave` on the preview buffer should not trigger unexpected behavior.

### Float Dimensions on Content Change
When `replace_float_content()` swaps the preview content (e.g., from a short note to a long one), the float dimensions are recalculated based on the new content. `nvim_win_set_config()` updates the width and height in-place. The float remains anchored to `cursor` position in the parent window.

### `<C-o>` / `<C-i>` Conflict with Neovim Jumplist
These keys conflict with Neovim's built-in jumplist navigation (`<C-o>` back, `<C-i>` / `<Tab>` forward). The buffer-local keymap takes precedence when the preview is active, overriding the global jumplist. This is intentional -- the user is in "preview exploration mode" and expects these keys to navigate preview history. When the preview closes, the keymaps are removed and normal jumplist behavior resumes. If this proves problematic, alternative bindings like `[p` / `]p` (preview back/forward) could be used instead.

---

## Estimated Line Counts

| Component | Current Lines | Added/Changed Lines | New Total |
|-----------|--------------|--------------------:|-----------|
| `preview.lua` | ~320 | +380 | ~700 |
| `config.lua` | ~544 | +6 | ~550 |
| `colors.lua` | ~381 | +20 | ~401 |
| **Total** | | **~406** | |

### Breakdown of `preview.lua` additions:

| Section | Lines |
|---------|------:|
| Data structures (PreviewTarget, history) | ~20 |
| History management (push/pop/clear/position) | ~55 |
| Target resolution (resolve_target, detect_link_in_preview) | ~75 |
| Breadcrumb formatting (segments, format, truncate) | ~100 |
| Float content management (replace, update_title) | ~45 |
| Nested navigation keymaps (focus/unfocus, navigate) | ~85 |
| Enhanced M.preview() changes | ~30 net (refactored, not all new) |
| Enhanced close_preview() changes | ~10 net |

---

## Files to Modify

| File | Change Type | Description |
|------|------------|-------------|
| `lua/andrew/vault/preview.lua` | **Major enhancement** | History stack, nested preview, breadcrumb formatting, focus management, enhanced keymaps |
| `lua/andrew/vault/config.lua` | **Minor addition** | Add `history_max`, `nested_preview`, `breadcrumb_style`, `breadcrumb_separator` to `M.preview` |
| `lua/andrew/vault/colors.lua` | **Minor addition** | Add `preview_breadcrumb_*` palette keys and `VaultPreviewBreadcrumb*` highlight groups |

No new files are created. The `breadcrumbs.lua`, `link_utils.lua`, `wikilinks.lua`, `ui.lua`, and `embed.lua` modules are not modified.

---

## Implementation Order

1. **Config + colors first** -- Add the new config options and highlight groups. These are leaf changes with no dependencies.

2. **History stack** -- Implement the history data structure and management functions. Unit-testable in isolation.

3. **Breadcrumb formatting** -- Implement `vault_relative_segments()`, `format_breadcrumb()`, and `truncate_breadcrumb()`. Can be tested by temporarily modifying the existing `M.preview()` to use the new title format.

4. **Target resolution refactor** -- Extract the current inline resolution logic from `M.preview()` into `resolve_target()`. Verify that the refactored `M.preview()` behaves identically to the original.

5. **Float content replacement** -- Implement `replace_float_content()` and `update_float_title()`. Test by manually calling them from a debug command.

6. **Nested navigation** -- Implement focus mode, `detect_link_in_preview()`, `navigate_in_preview()`, and all float-local keymaps. This is the most complex step and depends on steps 2-5.

7. **Integration testing** -- Verify the full workflow: open preview, enter float, follow link, navigate back, follow another link, close. Test edge cases: broken links, same-file refs, deep nesting, history truncation.
