# Highlight Syntax (==text==)

## Current State

| Component | Status | Details |
|-----------|--------|---------|
| **tree-sitter-markdown** | No dedicated node | `==text==` is parsed as plain `(inline)` text -- no `highlight` or `mark` node type exists |
| **render-markdown.nvim** | **Already supported** | Has a built-in `inline_highlight` handler that uses regex `==[^=]+==` on `(inline)` nodes |
| **render-markdown config** | Using defaults | The current `render-markdown.lua` does not configure `inline_highlight` -- defaults apply |
| **Obsidian preset** | Active | `preset = "obsidian"` is set, which enables `render_modes = true` (renders in all modes) |
| **Default highlight group** | `RenderMarkdownInlineHighlight` | Links to `RenderMarkdownCodeInline`, which links to `ColorColumn` |
| **Vault modules** | No handling | No vault module touches `==text==` for highlighting, navigation, or search |
| **Custom treesitter queries** | None relevant | `queries/markdown_inline/highlights.scm` has no `==` patterns |

### How render-markdown.nvim Handles ==text== Today

The plugin already has a complete implementation in three files:

1. **`handler/markdown_inline.lua`** -- The treesitter query captures `(inline)` nodes matching `==[^=]+==` as `@highlight`:
   ```scheme
   ((inline) @highlight
       (#lua-match? @highlight "==[^=]+=="))
   ```

2. **`render/inline/highlight.lua`** -- The renderer that:
   - Finds all `==[^=]+==` ranges within the captured `(inline)` node using `self.node:find()`
   - Verifies each range is at the "top level" (parent is `inline`, not inside emphasis/etc.)
   - Conceals the opening `==` and closing `==` delimiters
   - Applies `RenderMarkdownInlineHighlight` to the full range (including concealed delimiters)
   - Supports custom highlight prefixes via `config.inline_highlight.custom`

3. **`settings.lua`** -- Default configuration:
   ```lua
   M.inline_highlight.default = {
       enabled = true,
       render_modes = false,
       highlight = 'RenderMarkdownInlineHighlight',
       custom = {},
   }
   ```

4. **`core/colors.lua`** -- Default highlight group linkage:
   ```
   RenderMarkdownInlineHighlight -> RenderMarkdownCodeInline -> ColorColumn
   ```

### What This Means

The `==text==` highlight syntax **already works out of the box** with the current render-markdown.nvim installation. However, the visual appearance is suboptimal because:

- The default highlight (`ColorColumn` via chain linking) produces a generic background color, not the distinctive yellow/orange highlighter pen effect that Obsidian uses.
- The `render_modes = false` default is overridden by the `obsidian` preset to `render_modes = true`, so highlights render in all modes -- this part is correct.
- No custom highlight variants are configured (e.g., different colors for `==!important==` or `==?question==`).
- The concealment of `==` delimiters happens only in rendered mode, which is the expected behavior.

---

## Problem

While render-markdown.nvim provides the core `==text==` rendering, the experience is incomplete:

1. **Poor visual distinction**: The default highlight group chains to `ColorColumn`, which is a subtle gray background. Obsidian uses a vivid yellow/orange highlighter-pen background that immediately draws the eye. The current rendering is nearly invisible.

2. **No custom highlight colors defined**: The OneDarkPro colorscheme does not define `RenderMarkdownInlineHighlight` explicitly, so it falls back through the chain to a generic background.

3. **No vault-specific behavior**: Unlike wikilinks (which get resolution-aware highlighting via `wikilink_highlights.lua`) or tags (which get category-colored highlighting via `tag_highlights.lua`), highlighted text has no vault integration:
   - No search/navigation for highlighted passages
   - No highlight-aware extmarks that persist when render-markdown is toggled off
   - No jump-to-next/previous highlight motions

4. **No insert-mode visual feedback**: When typing `==`, there is no immediate indication that you are entering a highlight span until both delimiters are complete and render-markdown processes it.

5. **Interaction with nested markup unknown**: The behavior when `==text==` contains bold (`**`), italic (`*`), or wikilinks (`[[]]`) needs verification and potentially a vault-level fallback.

---

## Proposed Solution

A two-tier approach: configure render-markdown.nvim for proper visual rendering (tier 1, minimal effort), then optionally build a vault module for enhanced functionality (tier 2, larger scope).

### Architecture

**Tier 1: render-markdown.nvim Configuration (Recommended First Step)**

Customize the existing `inline_highlight` settings in the render-markdown plugin config and define a proper highlight group in the colorscheme. This requires zero new Lua modules -- only configuration changes.

**Tier 2: Vault Highlight Module (Optional Enhancement)**

Create `lua/andrew/vault/highlights.lua` following the established pattern of `tag_highlights.lua` and `wikilink_highlights.lua`. This would add:
- Extmark-based highlighting that works independently of render-markdown
- Jump-to-next/previous highlight motions (`]h` / `[h`)
- Toggle command
- Search integration (find all highlighted passages across vault)

The two tiers are complementary: render-markdown handles concealment and rendered-mode display, while the vault module adds navigation and search capabilities.

### Implementation Details

#### Tier 1: render-markdown.nvim Configuration

**Step 1: Define the highlight group in the colorscheme**

Add to `lua/andrew/plugins/colorscheme.lua` inside the `highlights` table:

```lua
highlights = {
    -- ... existing highlights ...

    -- Obsidian-style ==highlight== background (yellow highlighter pen)
    RenderMarkdownInlineHighlight = { bg = "#4a3a10", fg = "#e5c07b" },
},
```

The color choice uses a warm dark-yellow background (`#4a3a10`) with a bright gold foreground (`#e5c07b`) from the OneDark palette, creating a highlighter-pen effect without being garish.

Alternative colors to consider:
- Brighter yellow: `{ bg = "#5a4a15", fg = "#e5c07b" }`
- Orange tint: `{ bg = "#4a3015", fg = "#d19a66" }`
- Green highlight: `{ bg = "#2a3a20", fg = "#98c379" }`

**Step 2: Configure inline_highlight in render-markdown opts**

Add to `lua/andrew/plugins/render-markdown.lua` inside the `opts` table:

```lua
opts = {
    -- ... existing opts ...

    -- Obsidian-style ==highlight== rendering
    inline_highlight = {
        enabled = true,
        -- Custom highlight variants (prefix-based)
        custom = {
            -- ==!important text== renders with red/error highlighting
            important = {
                prefix = "!",
                highlight = "RenderMarkdownError",
            },
            -- ==?question text== renders with yellow/warning highlighting
            question = {
                prefix = "?",
                highlight = "RenderMarkdownWarn",
            },
        },
    },
},
```

The `custom` prefixes allow different highlight colors based on the first character after `==`. This mirrors Obsidian's community plugins that support colored highlights. The prefix is concealed along with the `==` delimiters.

#### Tier 2: Vault Highlight Module

**File: `lua/andrew/vault/highlights.lua`**

Follows the identical architecture as `tag_highlights.lua` and `inline_fields.lua`:

```lua
local engine = require("andrew.vault.engine")

local M = {}

M.enabled = true
M.ns = vim.api.nvim_create_namespace("vault_highlight_hl")

---@type uv.uv_timer_t|nil
local timer = nil
local DEBOUNCE_MS = 200

-- -----------------------------------------------------------------------
-- Highlight groups (fallback when render-markdown is not active)
-- -----------------------------------------------------------------------

local hl_groups = {
    VaultHighlight = { bg = "#4a3a10", fg = "#e5c07b" },
    VaultHighlightDelim = { fg = "#5c6370" },
}

local function define_highlights()
    for group, attrs in pairs(hl_groups) do
        attrs.default = true
        vim.api.nvim_set_hl(0, group, attrs)
    end
end

-- -----------------------------------------------------------------------
-- Code block / code span exclusion (reuse pattern from tag_highlights)
-- -----------------------------------------------------------------------

--- Build a function: is_in_code(row, col) -> boolean
---@param bufnr number
---@return fun(row: number, col: number): boolean
local function build_code_exclusion(bufnr)
    local ranges = {}

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
    if ok and parser then
        local tree = parser:parse()[1]
        if tree then
            local root = tree:root()
            for _, query_str in ipairs({
                "(fenced_code_block) @code",
                "(indented_code_block) @code",
            }) do
                local q_ok, query = pcall(vim.treesitter.query.parse, "markdown", query_str)
                if q_ok and query then
                    for _, node in query:iter_captures(root, bufnr, 0, -1) do
                        local sr, sc, er, ec = node:range()
                        ranges[#ranges + 1] = { sr, sc, er, ec }
                    end
                end
            end
        end
    end

    local iok, iparser = pcall(vim.treesitter.get_parser, bufnr, "markdown_inline")
    if iok and iparser then
        local itrees = iparser:parse()
        for _, itree in ipairs(itrees) do
            local iroot = itree:root()
            local cs_ok, cs_query = pcall(
                vim.treesitter.query.parse, "markdown_inline", "(code_span) @code"
            )
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

-- -----------------------------------------------------------------------
-- Frontmatter exclusion
-- -----------------------------------------------------------------------

---@param bufnr number
---@return number|nil, number|nil
local function get_frontmatter_range(bufnr)
    local lines = vim.api.nvim_buf_get_lines(
        bufnr, 0, math.min(5, vim.api.nvim_buf_line_count(bufnr)), false
    )
    if not lines[1] or lines[1] ~= "---" then return nil, nil end
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local max_scan = math.min(line_count, 200)
    for i = 2, max_scan do
        local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
        if line == "---" or line == "..." then
            return 0, i - 1
        end
    end
    return nil, nil
end

-- -----------------------------------------------------------------------
-- Core highlight application
-- -----------------------------------------------------------------------

---@param bufnr number
local function clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

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
        local row = i - 1

        if fm_start and fm_end and row >= fm_start and row <= fm_end then
            goto next_line
        end

        -- Find all ==...== patterns on this line
        local pos = 1
        while pos <= #line do
            local s, e = line:find("==[^=]+==", pos)
            if not s then break end

            -- Skip if inside code block/span
            if is_in_code(row, s - 1) then
                pos = e + 1
                goto next_match
            end

            -- Highlight the delimiters (dim)
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, s - 1, {
                end_col = s + 1,
                hl_group = "VaultHighlightDelim",
                hl_mode = "combine",
                priority = 195,
            })
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, e - 2, {
                end_col = e,
                hl_group = "VaultHighlightDelim",
                hl_mode = "combine",
                priority = 195,
            })

            -- Highlight the content (between delimiters)
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, s + 1, {
                end_col = e - 2,
                hl_group = "VaultHighlight",
                hl_mode = "combine",
                priority = 195,
            })

            pos = e + 1
            ::next_match::
        end

        ::next_line::
    end
end

M.apply = apply

-- -----------------------------------------------------------------------
-- Debounced update
-- -----------------------------------------------------------------------

---@param bufnr number
local function schedule_update(bufnr)
    if timer then timer:stop() end
    timer = vim.uv.new_timer()
    timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            apply(bufnr)
        end
    end))
end

-- -----------------------------------------------------------------------
-- Toggle
-- -----------------------------------------------------------------------

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
        "Vault: highlight marks " .. (M.enabled and "ON" or "OFF"),
        vim.log.levels.INFO
    )
end

-- -----------------------------------------------------------------------
-- Navigation: jump to next/previous ==highlight==
-- -----------------------------------------------------------------------

---@param direction 1|-1
local function jump_highlight(direction)
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cur_row, cur_col = unpack(vim.api.nvim_win_get_cursor(0))
    cur_col = cur_col + 1  -- 1-indexed

    local is_in_code = build_code_exclusion(bufnr)
    local fm_start, fm_end = get_frontmatter_range(bufnr)

    local positions = {}
    for i, line in ipairs(lines) do
        local row = i - 1
        if fm_start and fm_end and row >= fm_start and row <= fm_end then
            goto skip
        end
        local pos = 1
        while pos <= #line do
            local s, e = line:find("==[^=]+==", pos)
            if not s then break end
            if not is_in_code(row, s - 1) then
                positions[#positions + 1] = { row = i, col = s }
            end
            pos = e + 1
        end
        ::skip::
    end

    if #positions == 0 then return end

    if direction == 1 then
        for _, p in ipairs(positions) do
            if p.row > cur_row or (p.row == cur_row and p.col > cur_col) then
                vim.api.nvim_win_set_cursor(0, { p.row, p.col - 1 })
                return
            end
        end
        vim.api.nvim_win_set_cursor(0, { positions[1].row, positions[1].col - 1 })
    else
        for j = #positions, 1, -1 do
            local p = positions[j]
            if p.row < cur_row or (p.row == cur_row and p.col < cur_col) then
                vim.api.nvim_win_set_cursor(0, { p.row, p.col - 1 })
                return
            end
        end
        local last = positions[#positions]
        vim.api.nvim_win_set_cursor(0, { last.row, last.col - 1 })
    end
end

-- -----------------------------------------------------------------------
-- Setup
-- -----------------------------------------------------------------------

function M.setup()
    define_highlights()

    local group = vim.api.nvim_create_augroup("VaultHighlightHL", { clear = true })

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

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = group,
        pattern = "*.md",
        callback = function(ev)
            if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
                schedule_update(ev.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = define_highlights,
    })

    vim.api.nvim_create_autocmd("BufDelete", {
        group = group,
        pattern = "*.md",
        callback = function(ev) clear(ev.buf) end,
    })

    -- Commands
    vim.api.nvim_create_user_command("VaultHighlightToggle", function()
        M.toggle()
    end, { desc = "Toggle ==highlight== rendering" })

    vim.api.nvim_create_user_command("VaultHighlightRefresh", function()
        apply(vim.api.nvim_get_current_buf())
    end, { desc = "Refresh ==highlight== marks in current buffer" })

    -- Buffer-local keymaps
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "markdown",
        callback = function(ev)
            vim.keymap.set("n", "]h", function()
                jump_highlight(1)
            end, {
                buffer = ev.buf,
                desc = "Next ==highlight==",
                silent = true,
            })
            vim.keymap.set("n", "[h", function()
                jump_highlight(-1)
            end, {
                buffer = ev.buf,
                desc = "Previous ==highlight==",
                silent = true,
            })
        end,
    })
end

return M
```

### Render Pipeline Integration

The rendering pipeline for `==text==` involves two independent layers that can coexist:

```
Layer 1: render-markdown.nvim (visual rendering + concealment)
  treesitter parse -> (inline) node captured by #lua-match? "==[^=]+=="
    -> render/inline/highlight.lua
      -> conceal opening == (extmark with conceal="")
      -> conceal closing == (extmark with conceal="")
      -> apply RenderMarkdownInlineHighlight to full range
      -> check for custom prefix -> apply custom highlight if matched
  Result: In rendered mode, == is hidden and text has colored background.
          In insert mode on that line, == becomes visible (anti-conceal).

Layer 2: vault highlights.lua (navigation + vault integration)
  BufEnter / TextChanged -> regex scan for ==[^=]+==
    -> exclude code blocks (treesitter) and frontmatter
    -> apply VaultHighlight extmarks to content
    -> apply VaultHighlightDelim extmarks to == delimiters
  Result: Extmarks provide highlighting independently of render-markdown.
          Navigation motions (]h / [h) jump between highlights.
```

**Priority ordering** (higher = wins in overlap):
| Module | Priority | Purpose |
|--------|----------|---------|
| Wikilink highlights | 200 | Link resolution coloring |
| Vault highlight marks | 195 | ==text== content coloring |
| Tag highlights | 190 | #tag coloring |
| Inline field highlights | 185 | [key:: value] coloring |
| render-markdown.nvim | ~1000 | Concealment + rendered display |

render-markdown.nvim uses high-priority extmarks for concealment, so its conceal behavior takes precedence in rendered mode. The vault module's extmarks provide a fallback when render-markdown is disabled or toggled off, and enable navigation regardless.

**Interaction with render-markdown concealment**: When render-markdown is active and rendering, it conceals the `==` delimiters and applies its own highlight. The vault module's extmarks on the delimiter positions become invisible (the delimiter characters are concealed). The vault module's content extmark overlaps with render-markdown's highlight extmark -- since both use `hl_mode = "combine"`, the background colors merge (which is fine; they should use the same color).

### Configuration

Add to `lua/andrew/vault/config.lua`:

```lua
-- ---------------------------------------------------------------------------
-- Highlight marks (==text==)
-- ---------------------------------------------------------------------------
M.highlight_marks = {
    enabled = true,
    debounce_ms = 200,
}
```

Add to `lua/andrew/plugins/colorscheme.lua` highlights:

```lua
-- Obsidian-style ==highlight== (yellow highlighter pen)
RenderMarkdownInlineHighlight = { bg = "#4a3a10", fg = "#e5c07b" },
```

Add to `lua/andrew/plugins/render-markdown.lua` opts:

```lua
inline_highlight = {
    enabled = true,
    custom = {
        important = { prefix = "!", highlight = "RenderMarkdownError" },
        question  = { prefix = "?", highlight = "RenderMarkdownWarn" },
    },
},
```

### File Changes

**Tier 1 (minimal -- configuration only):**

| File | Change | Impact |
|------|--------|--------|
| `lua/andrew/plugins/colorscheme.lua` | Add `RenderMarkdownInlineHighlight` highlight definition | Proper yellow highlighter-pen color |
| `lua/andrew/plugins/render-markdown.lua` | Add `inline_highlight` section to opts | Custom prefix highlights (optional) |

**Tier 2 (vault module -- optional):**

| File | Change | Impact |
|------|--------|--------|
| `lua/andrew/vault/highlights.lua` | **New file** -- extmark highlighting + navigation | `]h`/`[h` motions, toggle, refresh |
| `lua/andrew/vault/config.lua` | Add `highlight_marks` section | Centralized configuration |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.highlights").setup()` | Module registration |

### Dependencies

**Tier 1**: None beyond what is already installed.
- render-markdown.nvim (already present and configured)
- OneDarkPro colorscheme (already present)

**Tier 2**: None beyond existing vault infrastructure.
- `andrew.vault.engine` (vault path detection, already loaded)
- nvim-treesitter (code exclusion queries, already loaded)

No external dependencies required for either tier.

### Edge Cases

1. **Nested markup inside highlights**: `==**bold** inside highlight==`
   - render-markdown.nvim handles this correctly: the `(inline)` node contains both the emphasis and highlight markers. The highlight renderer checks `top_level()` to ensure the `==` markers are at the inline level (not nested inside emphasis). Since `==` in standard markdown is not emphasis syntax, treesitter treats the entire `==**bold** inside highlight==` as inline text, and render-markdown matches the outer `==...==` range.
   - The vault module uses simple regex matching, which also handles this correctly: `==[^=]+==` matches the full span because `**bold** inside highlight` contains no `=` characters.

2. **Multiple highlights on one line**: `==first== normal text ==second==`
   - Both render-markdown and the vault module scan for all occurrences per line, so both highlights render correctly.

3. **Consecutive equals signs**: `===triple===` or `====quad====`
   - The regex `==[^=]+==` requires at least one non-`=` character between delimiters, so `====` alone is not matched. `===triple===` would match `==triple==` with extra `=` before/after (the regex finds the first `==` followed by non-`=` content).
   - render-markdown's `top_level()` check adds additional safety by ensuring the match positions are at the inline level.

4. **Multiline highlights**: `==start\ncontinuation==`
   - **Not supported** by either render-markdown or the vault module. The regex `==[^=]+==` does not span lines, and the vault module scans line-by-line. This matches Obsidian's behavior, which also does not support multiline highlights.

5. **Highlights inside code blocks/spans**: `` `==not highlighted==` ``
   - render-markdown: The treesitter query captures `(inline)` nodes, and code spans produce `(code_span)` nodes instead. The `==` inside a code span is part of the code span's text, not an `(inline)` child. So render-markdown correctly ignores it.
   - Vault module: The `build_code_exclusion()` function explicitly checks treesitter ranges for `(fenced_code_block)`, `(indented_code_block)`, and `(code_span)` nodes. Any `==` inside code is skipped.

6. **Highlights inside frontmatter**:
   - Vault module: `get_frontmatter_range()` skips lines between `---` delimiters.
   - render-markdown: Frontmatter is parsed as `(minus_metadata)` by treesitter, not as `(inline)`, so it is not captured.

7. **Empty highlight**: `====`
   - Not matched by `==[^=]+==` (requires at least one non-`=` character). Correctly ignored.

8. **Single equals**: `=text=`
   - Not matched: the pattern requires `==` (two consecutive equals) on each side.

9. **Highlight at end of line with no closing**: `==orphaned`
   - Not matched: no closing `==`. Correctly ignored.

10. **Interaction with wikilinks**: `==highlighted [[link]]==`
    - The vault module's regex matches the outer `==...==` span correctly. The wikilink highlights module (priority 200) applies its own extmarks to `[[link]]` within the span, which takes visual precedence for the link portion due to higher priority. The result is a highlighted background on the text, with the wikilink portion showing link-colored text on the same highlighted background.

### Testing Plan

**Tier 1 (configuration changes):**

1. Open a vault markdown file containing `==highlighted text==` passages.
2. Verify the `==` delimiters are concealed when the cursor is not on that line.
3. Verify the highlighted text has a visible yellow/gold background.
4. Verify `==` delimiters become visible when the cursor enters the line (anti-conceal).
5. Test custom prefixes: type `==!important==` and verify it renders with error-red highlighting.
6. Test inside a code block: `` ```\n==not highlighted==\n``` `` should NOT render.
7. Test inline code: `` `==not highlighted==` `` should NOT render.
8. Test multiple highlights on one line: `==first== and ==second==`.
9. Run `:checkhealth render-markdown` to verify no configuration errors.
10. Verify other render-markdown features (headings, tables, checkboxes, callouts) still work.

**Tier 2 (vault module):**

1. Verify `]h` and `[h` motions jump between `==highlights==` in the buffer.
2. Verify wrapping: `]h` at the last highlight jumps to the first, `[h` at the first jumps to the last.
3. Verify `:VaultHighlightToggle` toggles extmark highlighting on/off.
4. Verify `:VaultHighlightRefresh` re-applies highlights.
5. Verify highlights inside code blocks and frontmatter are not marked.
6. Verify debounced updates: type `==new highlight==` and confirm highlighting appears within 200ms.
7. Verify no errors in `:messages` after opening files, editing, and toggling.
8. Test interaction: toggle render-markdown off (`:RenderMarkdown toggle`), verify vault highlights still visible.
9. Test priority: ensure wikilinks inside highlights show link coloring, not highlight coloring.
10. Open a non-vault markdown file and verify no vault highlights are applied.
