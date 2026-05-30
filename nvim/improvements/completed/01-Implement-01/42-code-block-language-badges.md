# 42 — Code Block Language Badges

## Problem

Fenced code blocks in vault notes (e.g., Python snippets in simulation notes, Lua
in config documentation, Fortran in methodology notes) display with a background
highlight but no visual indicator of which programming language the block contains.
The reader must look at the opening fence line (` ```python `) to identify the
language — but when `conceal_delimiters` is enabled (the default), fence markers
are hidden in rendered mode, making the language completely invisible.

This is a significant readability gap for vault notes that embed code across
multiple languages (a common pattern in simulation, analysis, and methodology
notes).

### Current State

| Component | What It Does | Limitation |
|-----------|-------------|------------|
| **render-markdown.nvim** `code` section | Renders code block backgrounds via `RenderMarkdownCode` highlight; conceals fence delimiters | Only `sign = false` is configured; all other options use defaults |
| **nvim-web-devicons** | Provides language-specific icons and highlight colors | Installed as a dependency but not leveraged by code block rendering config |
| **`obsidian` preset** | Sets `style = "full"`, `border = "hide"`, `language = true` | Language display is technically enabled by default, but `border = "hide"` conceals the delimiter line where the language label lives |
| **Soft-paper theme** | Defines `RenderMarkdownCode` (bg) and `RenderMarkdownCodeInline` (fg) | No `RenderMarkdownCodeInfo`, `RenderMarkdownCodeBorder`, or `RenderMarkdownCodeFallback` highlights defined |

### Why Current Config Does Not Show Language Badges

The `obsidian` preset sets `border = "hide"`, which conceals fence delimiter
lines. The `language = true` default means the plugin *would* render a language
label on the top fence line — but when that line is concealed/hidden, the label
goes with it. The result is a code block with a colored background but no visible
language indicator.

Additionally, no explicit `position`, `language_pad`, `language_border`, or
highlight configuration exists, so even if the border were visible, the badge
would render as bare text without visual distinction from the code content.

---

## Goal

1. Display a styled language badge at the top of every fenced code block showing
   the language icon (from nvim-web-devicons) and language name.
2. Use `border = "thin"` so the top/bottom fence lines render as subtle border
   characters (▄/▀) with the language label overlaid on the top border.
3. Position the badge on the right side for an unobtrusive, Obsidian-like
   appearance that does not shift code content.
4. Add padding around the language label for visual breathing room.
5. Define custom highlight groups for the language badge (`RenderMarkdownCodeInfo`)
   and border (`RenderMarkdownCodeBorder`) in the soft-paper theme for consistent
   styling.
6. Maintain the existing `sign = false` (no sign column clutter).
7. Ensure inline code rendering (backtick `code`) is unaffected.

### Visual Result

Before (current):

```
┌─────────────────────────────────────────────┐
│  ██████████████████████████████████████████  │  ← code bg, no language indicator
│  ██ def simulate(params):               ██  │
│  ██     return run_solver(params)        ██  │
│  ██████████████████████████████████████████  │
└─────────────────────────────────────────────┘
```

After (with language badge):

```
┌─────────────────────────────────────────────┐
│  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄  Python  │  ← thin top border + right-aligned badge
│  ██ def simulate(params):               ██  │
│  ██     return run_solver(params)        ██  │
│  ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀  │  ← thin bottom border
└─────────────────────────────────────────────┘
```

---

## Approach

### Architecture

This improvement requires only configuration changes — no new Lua modules, no
custom rendering code. The render-markdown.nvim plugin already supports all
necessary options; they just need to be enabled and styled.

```
render-markdown.nvim code config (opts.code)
  │
  ├── border = "thin"        → shows ▄/▀ border lines
  ├── language = true         → enables language label rendering
  ├── language_icon = true    → shows devicon (e.g., , , )
  ├── language_name = true    → shows language text (e.g., "python", "lua")
  ├── position = "right"      → places label on the right side
  ├── language_pad = 1        → adds 1 char padding around label
  └── highlight_border        → custom highlight for border chars
          │
          └── nvim-web-devicons provides icon + icon highlight per language
```

### Configuration Options Explained

| Option | Value | Why |
|--------|-------|-----|
| `border = "thin"` | Show subtle ▄/▀ border characters at top/bottom of code blocks | Provides a visual container for the language badge; less heavy than `"thick"` which fills the entire line with the code background |
| `above = "▄"` | Top border character | Default value, creates a clean top edge |
| `below = "▀"` | Bottom border character | Default value, creates a clean bottom edge |
| `language = true` | Enable language label | Already default, but made explicit for clarity |
| `language_icon = true` | Show language icon from nvim-web-devicons | Adds visual recognition (e.g.,  for Python,  for Lua) |
| `language_name = true` | Show language name text | Shows "python", "lua", "fortran" alongside the icon |
| `language_info = false` | Hide additional info after language name | The info string (e.g., line count metadata) adds clutter without value for vault notes |
| `position = "right"` | Right-align the language label | Keeps the left edge clean for reading; matches Obsidian's code block style |
| `language_pad = 1` | 1 character padding around the label | Prevents the label from touching border characters; adds visual breathing room |
| `left_pad = 2` | 2 characters inner left padding | Indents code content slightly from the left edge for readability |
| `right_pad = 2` | 2 characters inner right padding | Balances the left padding for visual symmetry |
| `highlight_border = "RenderMarkdownCodeBorder"` | Custom border highlight | Allows theme-specific styling (subtle, non-distracting border color) |
| `sign = false` | No sign column icons | Already configured; prevents clutter in the gutter |
| `width = "full"` | Full-width background | Already default; code blocks span the full window width |

---

## Implementation Steps

### Step 1: Update `code` Section in render-markdown Config

**File:** `lua/andrew/plugins/render-markdown.lua` (lines 196-199)

Replace the current minimal `code` block:

```lua
-- BEFORE
-- Code blocks: no sign column, full-width background
code = {
  sign = false,
},
```

With the full language badge configuration:

```lua
-- AFTER
-- Code blocks: language badge (icon + name), thin borders, no sign column
code = {
  sign = false,
  -- Language badge: icon + name, right-aligned
  language = true,
  language_icon = true,
  language_name = true,
  language_info = false,
  position = "right",
  language_pad = 1,
  -- Thin top/bottom borders (▄ / ▀)
  border = "thin",
  above = "▄",
  below = "▀",
  -- Inner padding for readability
  left_pad = 2,
  right_pad = 2,
  -- Full-width background
  width = "full",
},
```

### Step 2: Add Code Block Highlight Groups to Soft-Paper Theme

**File:** `lua/andrew/themes/soft-paper.lua` (after line 525)

The soft-paper theme defines `RenderMarkdownCode` and `RenderMarkdownCodeInline`
but is missing highlight groups for the border and language info. Add them:

```lua
-- BEFORE (lines 524-525)
RenderMarkdownCode         = { bg = c.bg_dark },
RenderMarkdownCodeInline   = { fg = c.flamingo },
```

```lua
-- AFTER (lines 524-528)
RenderMarkdownCode         = { bg = c.bg_dark },
RenderMarkdownCodeInline   = { fg = c.flamingo },
RenderMarkdownCodeBorder   = { fg = c.surface1 },
RenderMarkdownCodeInfo     = { fg = c.subtext0, italic = true },
RenderMarkdownCodeFallback = { fg = c.subtext0 },
```

**Highlight group purposes:**

| Group | Used For | Styling Rationale |
|-------|----------|-------------------|
| `RenderMarkdownCodeBorder` | The ▄/▀ border characters at top/bottom | `surface1` — subtle, does not compete with code content; slightly visible against `bg_dark` |
| `RenderMarkdownCodeInfo` | The language name text (when `highlight_language` is not set, this may be used for info portions) | `subtext0` + italic — secondary text, clearly a label not content |
| `RenderMarkdownCodeFallback` | Language icon fallback when nvim-web-devicons has no highlight for the language | `subtext0` — matches info styling for consistency |

### Step 3 (Optional): Add OneDarkPro Highlight Overrides

If you want the badges to look good in the OneDarkPro theme as well, add overrides
in the colorscheme plugin config. This is optional since render-markdown.nvim
provides sensible default highlight links.

**File:** `lua/andrew/plugins/colorscheme.lua`

If custom highlight overrides exist (e.g., in `config.highlights`), add:

```lua
RenderMarkdownCodeBorder   = { fg = "#3e4452" },  -- OneDark comment grey
RenderMarkdownCodeInfo     = { fg = "#7f848e", italic = true },
RenderMarkdownCodeFallback = { fg = "#7f848e" },
```

If no highlight override section exists, this step can be skipped — the plugin's
built-in defaults will link to reasonable highlight groups.

---

## Summary of File Changes

| File | Change | Type |
|------|--------|------|
| `lua/andrew/plugins/render-markdown.lua` | Expand `code` section with language badge, border, and padding options | Modify |
| `lua/andrew/themes/soft-paper.lua` | Add `RenderMarkdownCodeBorder`, `RenderMarkdownCodeInfo`, `RenderMarkdownCodeFallback` highlight groups | Modify |
| `lua/andrew/plugins/colorscheme.lua` | (Optional) Add code highlight overrides for OneDarkPro | Modify |

---

## Testing

### 1. Basic Language Badge Display

Open a markdown file with fenced code blocks:

```markdown
# Test Note

Some text here.

` `` `python
def hello():
    print("world")
` `` `

More text.

` `` `lua
local M = {}
function M.setup()
  vim.print("hello")
end
return M
` `` `

` `` `fortran
program main
  implicit none
  print *, "Hello, Fortran!"
end program main
` `` `
```

**Expected:**
- Each code block has a thin ▄ border at the top and ▀ border at the bottom.
- The top border line shows the language icon and name right-aligned:
  - Python block: ` Python` (or similar devicon)
  - Lua block: ` Lua`
  - Fortran block: `󰛠 Fortran` (or fallback icon)
- Code content has 2-char left/right padding.
- No sign column icons appear (sign = false).
- Code background uses `RenderMarkdownCode` highlight (bg_dark in soft-paper).

### 2. Code Block Without Language

```markdown
` `` `
plain text with no language specified
` `` `
```

**Expected:**
- Code block renders with background and borders.
- No language badge appears (no language to display).
- No errors or warnings.

### 3. Inline Code Unaffected

```markdown
This is `inline code` in a sentence.
```

**Expected:**
- Inline code renders with `RenderMarkdownCodeInline` highlight (flamingo fg).
- No borders, no language badge, no padding changes.

### 4. Cursor Interaction

1. Move cursor into a code block.
2. **Expected:** Rendering disappears (obsidian preset renders in all modes, but
   the cursor line's concealed elements become visible for editing).
3. Move cursor out of the code block.
4. **Expected:** Rendering reappears with badge and borders.

### 5. Theme Switching

1. Start in OneDarkPro (`:colorscheme onedark`).
2. Verify code blocks have badges with reasonable colors.
3. Switch to Soft-Paper Light (`:lua require("andrew.themes.toggle").next()`).
4. Verify badges use the custom `RenderMarkdownCodeBorder`/`Info` highlights.
5. Switch to Soft-Paper Dark.
6. Verify same highlight groups apply with dark variant colors.

### 6. Edge Cases

**Long language name:**

```markdown
` `` `typescript
const x: number = 42;
` `` `
```

**Expected:** `󰛦 TypeScript` badge renders fully on the right; if the window is
very narrow, the badge may be truncated but should not cause errors.

**Unknown language:**

```markdown
` `` `my_custom_lang
some custom code
` `` `
```

**Expected:** Language name `my_custom_lang` renders without an icon (no devicon
available), using `RenderMarkdownCodeFallback` highlight.

**Empty code block:**

```markdown
` `` `python
` `` `
```

**Expected:** Block renders with borders and badge, even though content is empty.
No errors.

**Nested in callout:**

```markdown
> [!EXAMPLE] Code example
> ` `` `python
> x = 1
> ` `` `
```

**Expected:** Code block inside the callout renders with badge. The callout
quote bar (┃) and the code block borders coexist. (Rendering depends on
treesitter parsing of nested structures.)

### 7. Performance

```vim
:lua local s = vim.uv.hrtime(); vim.cmd("e!"); vim.defer_fn(function() print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6)) end, 200)
```

Open a vault note with 10+ code blocks. Measure buffer load time.

**Target:** No perceptible increase in render time. The language badge is part of
render-markdown's existing extmark pipeline — enabling more options adds negligible
overhead (icon lookup + one additional virtual text element per code block).

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **`border = "thin"` changes visual appearance of all code blocks** | Users accustomed to borderless code blocks may find borders distracting | The thin borders (▄/▀) are single-character and use a subtle color (`surface1`). Can revert to `"hide"` if disliked. |
| **`left_pad`/`right_pad` shift code content** | Code blocks gain 2 chars of indentation that wasn't there before | This improves readability by separating code from the edge. If disliked, set to `0`. |
| **Missing devicon for rare languages** | Some languages (custom, niche) won't have icons | `RenderMarkdownCodeFallback` highlight provides a consistent text-only fallback. The language name still displays. |
| **Concealed fence delimiters with `border = "thin"`** | `conceal_delimiters = true` (default) hides the raw ``` markers; the thin border replaces them visually | This is the intended behavior — the border provides a cleaner visual than raw fence markers. |
| **Interaction with treesitter-context** | The sticky context header might capture the code block's fence line | treesitter-context shows parent scopes (headings), not code fences. No conflict expected. |
| **blink-cmp-documentation buffers** | Code blocks in completion docs also render with badges | This is fine — completion docs benefit from language indicators too. If not desired, `blink-cmp-documentation` can be excluded by checking filetype in a custom `enabled` function. |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `render-markdown.nvim` | Core plugin providing all code block rendering | Yes |
| `nvim-web-devicons` | Language icons and per-language highlight colors | Yes (already installed) |
| `soft-paper.lua` theme | Custom highlight groups for badge/border styling | No (plugin has fallback defaults) |

---

## Future Enhancements

1. **Per-language highlight overrides** — Use `highlight_language` to set specific
   colors for frequently-used languages (e.g., Python = blue, Lua = purple,
   Fortran = green) instead of relying on devicon colors.
2. **`width = "block"` option** — Instead of full-width backgrounds, use
   block-width (content-hugging) backgrounds for a cleaner look in wide terminals.
   Combine with `min_width` to prevent tiny blocks.
3. **Disable background for specific languages** — Use `disable_background` to
   remove the background for certain languages (e.g., `diff` blocks that have
   their own syntax highlighting).
4. **Custom border characters** — Replace `▄`/`▀` with `─` or other box-drawing
   characters for a different aesthetic.
5. **Language name aliases** — Map verbose language names to shorter labels (e.g.,
   `typescript` → `TS`, `javascript` → `JS`) via a custom `language_name`
   function if render-markdown supports it in the future.
