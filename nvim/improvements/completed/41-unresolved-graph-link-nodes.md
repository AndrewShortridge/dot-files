# 41 — Unresolved Link Nodes in Graph View

## Problem

The local graph view (`graph.lua`) collects both resolved and unresolved forward links via `collect_forward_links()`, which already returns entries with `path = nil` for links whose target file does not exist. However, the rendering pipeline does not distinguish these unresolved links visually. They appear as plain, unhighlighted text -- identical to an empty row. Users cannot tell at a glance which of their wikilinks point to notes that have not been created yet.

Additionally:

1. **No visual indicator.** Resolved links get the `VaultGraphExistingLink` highlight (bold blue). Unresolved links get no highlight at all -- they blend into the background, making them invisible in a busy graph.
2. **No unresolved count.** The summary line shows `3 backlinks │ 5 forward links` but does not indicate how many of those are unresolved. A user must manually cross-reference to discover broken links.
3. **No action on unresolved links.** Pressing `<CR>` on an unresolved link row does nothing because `line_to_note` stores `nil` for the path. The `follow_link()` function in `wikilinks.lua` already supports creating notes for unresolved links, but the graph view does not offer this.
4. **The `u` toggle is missing.** The `config.graph.show_unresolved` setting and the `state.show_unresolved` filter toggle exist and are applied in `local_graph()` (lines 434-444), but there is no keymap in the graph float to toggle this interactively. The user must open the full filter panel (`f`) or reset filters (`r`) to change visibility.

## Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **graph.lua** | Collects forward/backlinks, renders ASCII graph in floating window, handles navigation keymaps | `lua/andrew/vault/graph.lua` |
| **graph_filter.lua** | Filter state management, predicate composition, `show_unresolved` toggle, preset persistence | `lua/andrew/vault/graph_filter.lua` |
| **config.lua** | `M.graph.show_unresolved` default toggle (line 261) | `lua/andrew/vault/config.lua` |
| **wikilinks.lua** | `follow_link()` creates new notes for unresolved links (lines 193-203) | `lua/andrew/vault/wikilinks.lua` |
| **engine.lua** | `is_vault_path()`, `vault_path`, file utilities | `lua/andrew/vault/engine.lua` |
| **ui.lua** | `create_float_display()` for floating windows | `lua/andrew/vault/ui.lua` |

### How Unresolved Links Flow Through the Current Code

1. `collect_forward_links()` (line 66) extracts `[[...]]` patterns and calls `resolve_link(display)`. When resolution fails, the entry is `{ name = display, path = nil }`.
2. In `local_graph()` (line 434), if `state.show_unresolved` is false, entries with `path = nil` are filtered out before rendering.
3. `render_graph()` (line 209) receives the filtered list. For each forward link entry, it checks `if fl.path then` (line 333) before applying `VaultGraphExistingLink`. When `fl.path` is nil, the name text is rendered but receives no highlight.
4. `line_to_note` (line 313) stores `forward = fl.path` which is nil for unresolved links. The `navigate_to()` helper (line 511) checks `if not path` and shows "no link on this line".

---

## Proposed Solution

### Architecture

The change is minimal -- it extends the existing rendering and navigation logic without restructuring any module. The data flow remains identical; only the presentation layer and one keymap are added.

```
 collect_forward_links()  -- already returns {name, path=nil} for unresolved
         |
         v
 local_graph()  -- already filters on show_unresolved
         |
         v
 render_graph()  -- [MODIFY] apply VaultGraphUnresolvedLink highlight + prefix
         |
         v
 line_to_note  -- [MODIFY] store name for unresolved links (for note creation)
         |
         v
 <CR> handler  -- [MODIFY] offer to create note when path is nil
         |
 u keymap      -- [NEW] toggle show_unresolved and re-render
```

### 1. Add `VaultGraphUnresolvedLink` Highlight Group

Add to `define_highlights()` in `graph.lua`:

```lua
local function define_highlights()
  local function hi(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  hi("VaultGraphTitle", "Title")
  hi("VaultGraphDivider", "FloatBorder")
  hi("VaultGraphBacklink", "Function")
  hi("VaultGraphForwardlink", "String")
  hi("VaultGraphConnector", "NonText")
  hi("VaultGraphCount", "Comment")
  -- Dark blue for links whose target file exists on disk
  vim.api.nvim_set_hl(0, "VaultGraphExistingLink", { default = true, fg = "#3b82f6", bold = true })
  -- Dimmed red for unresolved links (target file does not exist)
  vim.api.nvim_set_hl(0, "VaultGraphUnresolvedLink", { default = true, fg = "#ef4444", italic = true })
end
```

The `#ef4444` red with italic styling provides clear visual distinction from the `#3b82f6` bold blue of resolved links, while remaining readable against dark backgrounds. The `default = true` flag allows user overrides.

### 2. Modify `render_graph()` to Highlight Unresolved Links

The change is in the link row rendering loop (lines 268-338). Currently, the highlight is only applied when `bl.path` or `fl.path` is truthy. The modification adds an `else` branch to apply `VaultGraphUnresolvedLink` when the path is nil, and prepends a `?` indicator to the display name.

```lua
-- In render_graph(), replace lines 268-338 with:

local unresolved_prefix = "? "  -- visual indicator for unresolved links
local unresolved_prefix_dw = display_width(unresolved_prefix)

-- Track unresolved counts for summary
local bl_unresolved = 0
local fl_unresolved = 0

local max_rows = math.max(#backlinks, #forward_links)
for i = 1, max_rows do
  local bl = backlinks[i]
  local fl = forward_links[i]

  local left_part, right_part
  local bl_display, fl_display
  if bl then
    local avail = half - connector_in_dw
    bl_display = bl.name
    -- Prepend unresolved prefix if path is nil
    if not bl.path then
      bl_unresolved = bl_unresolved + 1
      bl_display = unresolved_prefix .. bl_display
    end
    local name_dw = display_width(bl_display)
    if name_dw > avail then
      bl_display = bl_display:sub(1, avail - 1) .. "\u{2026}"
      name_dw = display_width(bl_display)
    end
    local pad = math.max(0, avail - name_dw)
    left_part = string.rep(" ", pad) .. bl_display .. connector_in
  else
    left_part = string.rep(" ", half - divider_dw) .. divider_char
  end

  if fl then
    local avail = half - connector_out_dw - 1
    fl_display = fl.name
    -- Prepend unresolved prefix if path is nil
    if not fl.path then
      fl_unresolved = fl_unresolved + 1
      fl_display = unresolved_prefix .. fl_display
    end
    local name_dw = display_width(fl_display)
    if name_dw > avail then
      fl_display = fl_display:sub(1, avail - 1) .. "\u{2026}"
    end
    right_part = connector_out .. fl_display
  else
    right_part = ""
  end

  local line_str = left_part .. right_part

  lines[#lines + 1] = line_str
  local row = #lines - 1

  -- Store navigation targets.
  -- For unresolved links, store the name so the <CR> handler can offer creation.
  local line_1idx = #lines
  if bl or fl then
    line_to_note[line_1idx] = {
      backlink = bl and bl.path or nil,
      forward = fl and fl.path or nil,
      -- Store names for unresolved link creation
      backlink_name = bl and (not bl.path) and bl.name or nil,
      forward_name = fl and (not fl.path) and fl.name or nil,
    }
  end

  -- Highlights for this row
  if bl then
    if bl.path then
      hl_find(row, line_str, bl_display, "VaultGraphExistingLink")
    else
      hl_find(row, line_str, bl_display, "VaultGraphUnresolvedLink")
    end
    hl_find(row, line_str, connector_in, "VaultGraphConnector")
  else
    hl_find(row, line_str, divider_char, "VaultGraphDivider")
  end

  if fl then
    hl_find(row, line_str, connector_out, "VaultGraphConnector")
    if fl.path then
      hl_find(row, line_str, fl_display, "VaultGraphExistingLink", #left_part)
    else
      hl_find(row, line_str, fl_display, "VaultGraphUnresolvedLink", #left_part)
    end
  end
end
```

Key differences from the current code:

- **Lines with `? ` prefix**: Unresolved links are prepended with `"? "` so users can instantly spot them even without color support.
- **`VaultGraphUnresolvedLink` highlight**: Applied to the full display name (including the `? ` prefix) when `path` is nil.
- **`backlink_name` / `forward_name` fields**: Stored in `line_to_note` so the `<CR>` handler knows which note name to create.
- **`bl_unresolved` / `fl_unresolved` counters**: Tracked for the summary line.

### 3. Enhanced Summary Line with Unresolved Counts

Replace the summary line construction (lines 358-375) to include unresolved counts when present:

```lua
-- Summary line with unresolved counts
local function fmt_count(total, unresolved, label)
  local s = string.format("%d %s%s", total, label, total == 1 and "" or "s")
  if unresolved > 0 then
    s = s .. string.format(" (%d unresolved)", unresolved)
  end
  return s
end

local summary = "  " .. fmt_count(#backlinks, bl_unresolved, "backlink")
local summary_right = fmt_count(#forward_links, fl_unresolved, "forward link")
local summary_line = summary
  .. string.rep(" ", math.max(1, half - display_width(summary)))
  .. divider_char
  .. "  "
  .. summary_right
lines[#lines + 1] = summary_line
add_hl(#lines - 1, 0, #summary_line, "VaultGraphCount")
```

This produces output like:

```
  3 backlinks (1 unresolved)              │  5 forward links (2 unresolved)
```

When there are no unresolved links, the parenthetical is omitted and the summary looks identical to the current output.

### 4. Return Unresolved Counts from `render_graph()`

Update the return signature to include the counters so `local_graph()` can use them for window height calculation:

```lua
---@return string[] lines, table[] highlight_ranges, table line_to_note, number bl_unresolved, number fl_unresolved
local function render_graph(note_name, backlinks, forward_links, total_width)
  -- ... (body as modified above) ...
  return lines, highlights, line_to_note, bl_unresolved, fl_unresolved
end
```

The caller in `local_graph()` updates to:

```lua
local rendered_lines, highlights, line_to_note, bl_unresolved, fl_unresolved =
  render_graph(note_name, backlinks, forward_links, total_width)
```

The extra return values are unused by `local_graph()` currently but are available for future features (e.g., conditional notifications, status bar enrichment).

### 5. Make Unresolved Links Actionable via `<CR>`

Modify the `navigate_to()` helper and `<CR>` keymap in `local_graph()` to offer note creation when the target is unresolved:

```lua
-- Helper: navigate to a note by absolute path, or offer to create it
local function navigate_to(path, unresolved_name)
  if path and path ~= "" then
    float.close()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return
  end

  if unresolved_name and unresolved_name ~= "" then
    -- Offer to create the note (same behavior as wikilinks.follow_link)
    vim.ui.select({ "Create note", "Cancel" }, {
      prompt = "'" .. unresolved_name .. "' does not exist:",
    }, function(choice)
      if choice == "Create note" then
        local buf_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(
          vim.fn.bufnr(graph_ctx.source_buf_name)
        ), ":h")
        local new_path
        if engine.is_vault_path(buf_dir) then
          new_path = buf_dir .. "/" .. unresolved_name .. ".md"
        else
          new_path = engine.vault_path .. "/" .. unresolved_name .. ".md"
        end
        local dir = vim.fn.fnamemodify(new_path, ":h")
        vim.fn.mkdir(dir, "p")
        float.close()
        vim.cmd("edit " .. vim.fn.fnameescape(new_path))
      end
    end)
    return
  end

  vim.notify("Vault: no link on this line", vim.log.levels.INFO)
end
```

Update `target_from_cursor()` to return both the path and the unresolved name:

```lua
-- Helper: resolve navigation target from cursor position
local function target_from_cursor()
  local cursor = vim.api.nvim_win_get_cursor(graph_ctx.win)
  local entry = graph_ctx.line_to_note[cursor[1]]
  if not entry then
    return nil, nil
  end
  local half = math.floor(graph_ctx.total_width / 2)
  local line_text = vim.api.nvim_buf_get_lines(graph_ctx.buf, cursor[1] - 1, cursor[1], false)[1]
  local col_display = vim.fn.strdisplaywidth(line_text:sub(1, cursor[2]))
  local on_left = col_display < half

  if on_left then
    return entry.backlink, entry.backlink_name
  else
    return entry.forward, entry.forward_name
  end
end
```

Update the `<CR>` and `gf` keymaps:

```lua
-- <CR>: navigate to the note on the current line, or create if unresolved
vim.keymap.set("n", "<CR>", function()
  local path, unresolved_name = target_from_cursor()
  navigate_to(path, unresolved_name)
end, {
  buffer = buf,
  nowait = true,
  silent = true,
  desc = "Follow graph link (create if unresolved)",
})

-- gf: same as <CR>
vim.keymap.set("n", "gf", function()
  local path, unresolved_name = target_from_cursor()
  navigate_to(path, unresolved_name)
end, {
  buffer = buf,
  nowait = true,
  silent = true,
  desc = "Follow graph link (create if unresolved)",
})
```

Store the source buffer name in `graph_ctx` so `navigate_to` can determine the directory for new note creation:

```lua
local graph_ctx = {
  win = win,
  buf = buf,
  total_width = total_width,
  line_to_note = line_to_note,
  source_buf_name = buf_path,  -- the note that opened the graph
}
```

### 6. Respect `config.graph.show_unresolved` Toggle

This is already implemented in `local_graph()` lines 434-444. The existing code filters out entries with `path = nil` when `state.show_unresolved` is false. No change is needed here. The new rendering code simply operates on whatever list survives the filter.

### 7. Add `u` Keymap for Interactive Toggle

Add a new keymap in `local_graph()` after the existing filter keymaps:

```lua
-- u: toggle unresolved link visibility
vim.keymap.set("n", "u", function()
  state.show_unresolved = not state.show_unresolved
  float.close()
  M.local_graph()
end, { buffer = buf, nowait = true, silent = true, desc = "Toggle unresolved links" })
```

This follows the same pattern as the existing `+`/`-` depth keymaps: mutate the filter state, close the float, and re-render.

Update the filter status bar hints line to include the new keymap:

```lua
-- In local_graph(), update the hints line (currently line 478):
local hints_line = "  [f] filter  [u] unresolved  [+/-] depth  [r] reset  [p] presets  [?] help"
```

---

## Configuration

No new configuration keys are needed. The existing `config.graph.show_unresolved` (line 261 in `config.lua`) controls the default visibility state. The highlight group `VaultGraphUnresolvedLink` uses `default = true` so users can override it in their colorscheme or `after/plugin/` directory:

```lua
-- User override example (in after/plugin/highlights.lua or colorscheme):
vim.api.nvim_set_hl(0, "VaultGraphUnresolvedLink", { fg = "#f97316", underdashed = true })
```

The existing config section is unchanged:

```lua
-- lua/andrew/vault/config.lua (lines 253-273, no modifications)
M.graph = {
  max_depth = 5,
  max_nodes = 50,
  default_depth = 1,
  show_filter_bar = true,
  show_orphans = true,
  show_unresolved = true,    -- controls default visibility of unresolved links
  existing_only = false,
  date_shortcuts = { ... },
}
```

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `lua/andrew/vault/graph.lua` | **Modify** | Add `VaultGraphUnresolvedLink` highlight; modify `render_graph()` to apply unresolved highlight + `? ` prefix; add `backlink_name`/`forward_name` to `line_to_note`; add unresolved counts to summary line; update `navigate_to()` and `target_from_cursor()` for note creation on unresolved links; add `u` keymap; add `source_buf_name` to `graph_ctx`; update hints line |
| `lua/andrew/vault/config.lua` | **No change** | `show_unresolved` already exists in `M.graph` |
| `lua/andrew/vault/graph_filter.lua` | **No change** | `state.show_unresolved` and filtering logic already exist |
| `lua/andrew/vault/wikilinks.lua` | **No change** | Note creation logic in `follow_link()` is the reference pattern; the graph replicates it directly |
| `lua/andrew/vault/ui.lua` | **No change** | `create_float_display()` is sufficient |

---

## Dependencies

No new external dependencies. All functionality uses existing infrastructure:

| Dependency | How It's Used | Status |
|------------|-------------|--------|
| `vim.api.nvim_set_hl` | Define `VaultGraphUnresolvedLink` highlight group | Already used for other graph highlights |
| `vim.ui.select` | Prompt user to create note from unresolved link | Already available in Neovim core |
| `engine.is_vault_path` | Determine directory for new note creation | Already used throughout vault modules |
| `graph_filter.state` | `show_unresolved` toggle state | Already implemented in `graph_filter.lua` |

---

## Testing Plan

### Manual Verification

**1. Visual rendering of unresolved links:**

- Open a vault note containing wikilinks to both existing and non-existing notes (e.g., `[[ExistingNote]]` and `[[NonExistent]]`).
- Run `:VaultGraph` or `<leader>vG`.
- Verify that resolved links appear in bold blue (`VaultGraphExistingLink`).
- Verify that unresolved links appear in italic red (`VaultGraphUnresolvedLink`) with a `? ` prefix before the name.
- Verify that the `? ` prefix does not cause truncation for names that previously fit.

**2. Summary line with unresolved counts:**

- On a note with 3 forward links where 1 is unresolved, verify the summary reads:
  `3 forward links (1 unresolved)`.
- On a note with 0 unresolved links, verify the parenthetical is absent:
  `3 forward links`.

**3. Note creation via `<CR>` on unresolved link:**

- Cursor to an unresolved forward link row in the graph.
- Press `<CR>`.
- Verify a `vim.ui.select` prompt appears with "Create note" and "Cancel".
- Select "Create note". Verify a new `.md` file is created in the same directory as the source note and opened in the editor.
- Re-open the graph. Verify the previously unresolved link now appears as resolved (blue, no `? ` prefix).

**4. `u` keymap toggle:**

- Open the graph on a note with at least one unresolved forward link.
- Press `u`. Verify the graph re-renders and unresolved links are hidden.
- Press `u` again. Verify unresolved links reappear.
- Verify the toggle state persists across the re-render (the graph remembers the toggle via `graph_filter.state`).

**5. Interaction with `show_unresolved = false` default:**

- Temporarily set `config.graph.show_unresolved = false`.
- Open the graph. Verify unresolved links are hidden by default.
- Press `u` to show them. Verify they appear with the unresolved highlight.

**6. Cursor-side detection for split rows:**

- On a row with both a backlink (left) and forward link (right), position cursor on the left half and press `<CR>`. Verify it navigates to (or offers to create) the backlink target.
- Position cursor on the right half and press `<CR>`. Verify it targets the forward link.

**7. Edge cases:**

| Case | Expected Behavior |
|------|-------------------|
| All forward links are unresolved | All render with `? ` prefix and red highlight; summary shows full unresolved count |
| No unresolved links at all | Rendering is identical to current behavior; no `? ` prefixes; no parenthetical in summary |
| Zero links total | "(no connections)" message unchanged |
| Unresolved link name exceeds available width | Name is truncated with `...` after the `? ` prefix |
| `u` toggle when no unresolved links exist | Graph re-renders identically (no-op, no error) |
| Backlinks are always resolved (ripgrep only finds existing files) | Backlink column unaffected; `bl_unresolved` stays 0; no `? ` prefixes on left side |

### Highlight Verification

```vim
" Verify both highlight groups are defined after opening the graph:
:hi VaultGraphExistingLink
" Expected: xxx fg=#3b82f6 bold

:hi VaultGraphUnresolvedLink
" Expected: xxx fg=#ef4444 italic
```

### Performance

No performance impact. The change adds one string comparison (`if not bl.path`) and one string concatenation (`"? " .. name`) per unresolved link per render. Both are O(1) operations. The `u` keymap toggle triggers a full re-render via `M.local_graph()`, which is the same path as all other filter keymaps.
