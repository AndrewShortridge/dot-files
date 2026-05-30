# 14 -- Strikethrough on Completed Tasks

## Problem

When a task is completed (`- [x] task text`), the checkbox icon changes to a
green checkmark (via render-markdown.nvim), but the task text itself looks
identical to unchecked tasks. There is no visual differentiation of the *content*
-- you must look at the checkbox icon to determine whether a task is done.

This is a readability gap when scanning long task lists. Obsidian, Notion, and
most task-oriented tools apply strikethrough styling to completed task text,
making done items immediately scannable -- the eye can skip them without
consciously reading each checkbox.

The cancelled state (`- [-] cancelled text`) has the same problem: the icon
changes to a red X, but the text looks the same as any active task.

### Current State

#### render-markdown.nvim checkbox config

**File:** `lua/andrew/plugins/render-markdown.lua` (lines 206-213)

```lua
checkbox = {
  custom = {
    in_progress = { raw = "[/]", rendered = "󰔟 ", highlight = "RenderMarkdownWarn" },
    cancelled = { raw = "[-]", rendered = "✘ ", highlight = "RenderMarkdownError" },
    deferred = { raw = "[>]", rendered = "󰒊 ", highlight = "RenderMarkdownInfo" },
  },
},
```

The config defines three custom checkbox states (`[/]`, `[-]`, `[>]`) with icons
and colors. The built-in `checked` (`[x]`) and `unchecked` (`[ ]`) states use
render-markdown's defaults:

- **unchecked:** icon `'󰄱 '`, highlight `'RenderMarkdownUnchecked'`
- **checked:** icon `'󰱒 '`, highlight `'RenderMarkdownChecked'`

None of the states set `scope_highlight`, which means no additional styling is
applied to the task text content.

#### render-markdown.nvim `scope_highlight` feature

The render-markdown.nvim plugin supports a `scope_highlight` property on each
checkbox state (checked, unchecked, and custom). When set, it applies the
specified highlight group to the "scope" of the list item -- the `inline` content
node inside the `paragraph` child of the `list_item` treesitter node. In
practice, this means the task text after the checkbox.

Source: `render-markdown/render/markdown/checkbox.lua` (lines 121-130):

```lua
function Render:scope()
    local highlight = self.data.scope_highlight
    if not highlight then
        return
    end
    self.marks:over(self.config, 'check_scope', self.node:scope(), {
        priority = self.config.scope_priority,
        hl_group = highlight,
    })
end
```

The `node:scope()` method (from `render-markdown/lib/node.lua`, line 187)
returns the `inline` child of the `paragraph` child -- the actual text content.

The highlight is applied as an extmark with the configured `hl_group`. When the
highlight group includes `strikethrough = true`, the text renders with a
horizontal line through it.

#### Soft-paper theme highlights

**File:** `lua/andrew/themes/soft-paper.lua` (lines 531-532)

```lua
RenderMarkdownChecked      = { fg = c.green },
RenderMarkdownUnchecked    = { fg = c.surface2 },
```

The theme defines highlights for the checkbox icons but has no highlight groups
for task text scope styling.

The theme already defines `@markup.strikethrough`:

```lua
["@markup.strikethrough"]   = { fg = c.mauve, strikethrough = true },
```

This uses `c.mauve` (gray, `#8D8D8D`) with the `strikethrough` attribute.

#### Vault task states

**File:** `lua/andrew/vault/config.lua` (lines 32-38)

```lua
M.task_states = {
  { mark = " ", label = "open" },
  { mark = "/", label = "in-progress" },
  { mark = "x", label = "done" },
  { mark = "-", label = "cancelled" },
  { mark = ">", label = "deferred" },
}
```

Five states are defined. Of these, `done` and `cancelled` are terminal states
where strikethrough is appropriate. The other three (`open`, `in-progress`,
`deferred`) represent active/pending work and should NOT have strikethrough.

#### Checkbox cycling

**File:** `ftplugin/markdown.lua` (lines 162-181)

The `<leader>mx` mapping cycles through all five states. When cycling to `[x]`,
a `[completion:: YYYY-MM-DD]` inline field is appended. When cycling away from
`[x]`, the completion field is removed.

This cycling behavior is purely text-based and is unaffected by render-markdown's
visual rendering. No changes to the cycling logic are needed.

---

## Goal

1. Apply strikethrough styling to the text content of completed tasks (`[x]`).
2. Apply strikethrough styling to the text content of cancelled tasks (`[-]`).
3. Use theme-consistent colors: dimmed/muted text with the `strikethrough`
   attribute, so completed/cancelled tasks visually recede.
4. Leave unchecked (`[ ]`), in-progress (`[/]`), and deferred (`[>]`) tasks
   unstyled (no scope highlight).
5. Define dedicated highlight groups in the soft-paper theme for precise control
   over the strikethrough appearance (color, weight) independent of the
   `@markup.strikethrough` treesitter highlight.

### Visual Result

Before (current):

```
  󰄱  Write unit tests for search parser       <- unchecked
  󰔟  Refactor embed module                     <- in-progress
  󰱒  Fix heading slug matching                 <- done (no visual diff in text)
  ✘  Remove legacy cache code                  <- cancelled (no visual diff in text)
  󰒊  Migrate to new API                        <- deferred
```

After (with strikethrough):

```
  󰄱  Write unit tests for search parser       <- unchecked
  󰔟  Refactor embed module                     <- in-progress
  󰱒  F̶i̶x̶ ̶h̶e̶a̶d̶i̶n̶g̶ ̶s̶l̶u̶g̶ ̶m̶a̶t̶c̶h̶i̶n̶g̶               <- done (strikethrough + dimmed)
  ✘  R̶e̶m̶o̶v̶e̶ ̶l̶e̶g̶a̶c̶y̶ ̶c̶a̶c̶h̶e̶ ̶c̶o̶d̶e̶                <- cancelled (strikethrough + dimmed)
  󰒊  Migrate to new API                        <- deferred
```

---

## Approach

### Architecture

This improvement requires only configuration changes -- no new Lua modules, no
custom rendering logic. The render-markdown.nvim plugin already supports
`scope_highlight` on both built-in and custom checkbox states. We set the
appropriate highlight groups and define them in the theme.

```
render-markdown.nvim checkbox config
  │
  ├── checked.scope_highlight = "RenderMarkdownCheckedScope"
  │     └── Applied to task text when [x] is detected
  │
  └── custom.cancelled.scope_highlight = "RenderMarkdownCancelledScope"
        └── Applied to task text when [-] is detected
          │
          └── soft-paper theme defines both groups with
              { fg = <dimmed>, strikethrough = true }
```

### Why Dedicated Highlight Groups

We define new highlight groups (`RenderMarkdownCheckedScope`,
`RenderMarkdownCancelledScope`) rather than reusing `@markup.strikethrough`
because:

1. **Color control.** `@markup.strikethrough` uses `c.mauve` (gray), which is
   the theme's designated color for strikethrough markdown syntax (`~~text~~`).
   Task strikethrough should use a different shade to distinguish "the author
   wrote this with strikethrough" from "this task is done."

2. **Independent styling.** The completed task text should appear dimmed (faded)
   in addition to having a strikethrough line, reinforcing that it is no longer
   active. The cancelled text should use the error/red palette to signal
   cancellation. Separate highlight groups allow this without affecting the
   general `@markup.strikethrough` appearance.

3. **Future flexibility.** Separate groups allow per-state customization later
   (e.g., different opacity/color for done vs. cancelled) without cross-cutting
   changes.

---

## Implementation Steps

### Step 1: Add `scope_highlight` to Checkbox Config

**File:** `lua/andrew/plugins/render-markdown.lua` (lines 206-213)

Replace the current checkbox section:

```lua
-- BEFORE
checkbox = {
  custom = {
    in_progress = { raw = "[/]", rendered = "󰔟 ", highlight = "RenderMarkdownWarn" },
    cancelled = { raw = "[-]", rendered = "✘ ", highlight = "RenderMarkdownError" },
    deferred = { raw = "[>]", rendered = "󰒊 ", highlight = "RenderMarkdownInfo" },
  },
},
```

With:

```lua
-- AFTER
checkbox = {
  -- Strikethrough completed task text
  checked = {
    scope_highlight = "RenderMarkdownCheckedScope",
  },
  custom = {
    in_progress = { raw = "[/]", rendered = "󰔟 ", highlight = "RenderMarkdownWarn" },
    cancelled = {
      raw = "[-]",
      rendered = "✘ ",
      highlight = "RenderMarkdownError",
      scope_highlight = "RenderMarkdownCancelledScope",
    },
    deferred = { raw = "[>]", rendered = "󰒊 ", highlight = "RenderMarkdownInfo" },
  },
},
```

**What changed:**

1. Added `checked = { scope_highlight = "RenderMarkdownCheckedScope" }` to
   override the built-in checked state. We only specify `scope_highlight` -- the
   `icon` and `highlight` fields are omitted, so render-markdown.nvim keeps its
   defaults (`'󰱒 '` icon, `'RenderMarkdownChecked'` highlight). The
   `vim.tbl_deep_extend('force', ...)` merge in the plugin's preset system
   ensures our partial override is applied on top of the defaults.

2. Added `scope_highlight = "RenderMarkdownCancelledScope"` to the existing
   `cancelled` custom state definition.

**Note on merge behavior:** The render-markdown.nvim presets system
(`lib/presets.lua`, line 14) uses `vim.tbl_deep_extend('force', ...)` to merge
the preset config, partial config, and user overrides. Since the `obsidian`
preset only sets `render_modes = true` (line 28) and does not touch checkbox
config, our `checked` override is applied directly onto the plugin defaults
(from `settings.lua`, lines 318-333). The default `icon` and `highlight` values
are preserved because we do not specify them.

### Step 2: Add Highlight Groups to Soft-Paper Theme

**File:** `lua/andrew/themes/soft-paper.lua` (after line 532)

Add the new highlight groups after the existing `RenderMarkdownChecked` and
`RenderMarkdownUnchecked` definitions:

```lua
-- BEFORE (lines 531-532)
RenderMarkdownChecked      = { fg = c.green },
RenderMarkdownUnchecked    = { fg = c.surface2 },
```

```lua
-- AFTER (lines 531-535)
RenderMarkdownChecked      = { fg = c.green },
RenderMarkdownUnchecked    = { fg = c.surface2 },
RenderMarkdownCheckedScope   = { fg = c.fg_faint, strikethrough = true },
RenderMarkdownCancelledScope = { fg = c.fg_faint, strikethrough = true },
```

**Highlight design choices:**

| Group | fg | Attributes | Rationale |
|-------|-----|-----------|-----------|
| `RenderMarkdownCheckedScope` | `c.fg_faint` | `strikethrough = true` | Dimmed text (like line numbers/ghost text) with strikethrough. Completed tasks recede visually without disappearing. |
| `RenderMarkdownCancelledScope` | `c.fg_faint` | `strikethrough = true` | Same treatment as completed: dimmed + strikethrough. Both are terminal states. |

**Color values by variant:**

| Variant | `c.fg_faint` |
|---------|-------------|
| Light | `#797593` (Rose Pine subtle -- muted purple-gray) |
| Dark | `#A5ADCE` (Catppuccin Frappe overlay0 -- muted blue-gray) |

Using `c.fg_faint` rather than `c.mauve` differentiates task strikethrough from
markdown `~~strikethrough~~` syntax (`@markup.strikethrough` uses `c.mauve`).
Using `c.fg_faint` rather than `c.surface2` keeps the text readable (surface2
would be too faint to read if someone actually wants to see the task text).

**Alternative:** If you prefer cancelled tasks to use a reddish tint to
visually distinguish them from completed tasks, change `RenderMarkdownCancelledScope`
to `{ fg = c.red, strikethrough = true }`. This makes cancellations look more
"alarming" compared to the neutral fade of completions. The initial implementation
uses the same style for both since they are both terminal states.

### Step 3 (Optional): Set `scope_priority`

If other extmarks conflict with the scope highlight (e.g., wikilink highlights,
inline field highlights, or treesitter highlights on the same text), you may need
to set `scope_priority` to ensure the strikethrough renders on top.

**File:** `lua/andrew/plugins/render-markdown.lua`

```lua
checkbox = {
  checked = {
    scope_highlight = "RenderMarkdownCheckedScope",
  },
  scope_priority = 200,  -- higher than default extmark priorities
  custom = {
    -- ...
  },
},
```

This is optional. The default (`nil`) usually works because render-markdown.nvim
applies its extmarks at a reasonable priority. Only add this if testing reveals
that other highlights override the strikethrough.

---

## Summary of File Changes

| File | Change | Type | Lines Affected |
|------|--------|------|----------------|
| `lua/andrew/plugins/render-markdown.lua` | Add `checked.scope_highlight`, add `scope_highlight` to `cancelled` custom state | Modify | Lines 206-213 |
| `lua/andrew/themes/soft-paper.lua` | Add `RenderMarkdownCheckedScope` and `RenderMarkdownCancelledScope` highlight groups | Modify | After line 532 |

No new files are created. No files are deleted.

---

## Edge Cases and Considerations

### 1. Inline formatting inside task text

Task text may contain bold, italic, links, or inline code:

```markdown
- [x] Fix **critical** bug in `embed.lua`
- [-] Remove [[legacy-module]] references
```

The `scope_highlight` applies to the `inline` treesitter node which contains
these child nodes. The render-markdown extmark uses `hl_group` on the scope
range. Neovim's extmark highlights blend with treesitter highlights according to
priority. The strikethrough attribute should combine with existing bold/italic
since strikethrough is an independent text attribute.

**Risk:** If `scope_priority` is set very high, the scope highlight may override
treesitter highlights for bold/italic colors within the task text. Without
`scope_priority` (nil), the default priority lets treesitter highlights take
precedence for color while the strikethrough attribute still renders.

**Recommendation:** Start without `scope_priority` (nil). If the strikethrough
does not appear on formatted text, set it to a low-but-positive value like `100`.

### 2. Multi-line tasks

If a task spans multiple lines (continuation lines indented under the checkbox):

```markdown
- [x] This is a long task that
  spans multiple lines
```

The treesitter `list_item` node encompasses all continuation lines, but
`node:scope()` returns only the `inline` child of the first `paragraph`. This
means only the first line of the task gets the strikethrough, not continuation
lines.

This is acceptable behavior -- it matches how most editors render checkbox
scope, and multi-line tasks are relatively rare in practice.

### 3. Nested tasks

```markdown
- [x] Parent task done
  - [ ] Sub-task still open
  - [x] Sub-task also done
```

Each list item is an independent treesitter node with its own checkbox. The
`scope_highlight` is scoped to each individual list item's text -- it does NOT
cascade to child list items. So the parent's strikethrough applies only to
"Parent task done", and each sub-task gets its own treatment based on its
checkbox state.

### 4. Completion date inline fields

When a task is completed via `<leader>mx`, the cycling logic appends
`[completion:: 2026-02-27]`:

```markdown
- [x] Fix heading slug matching [completion:: 2026-02-27]
```

The inline field text is part of the `inline` node and will also receive the
strikethrough styling. This is the desired behavior -- the entire task line
(including metadata) should appear "done."

The vault's inline field highlighting module
(`lua/andrew/vault/inline_fields.lua`) may apply its own highlight to the
`[completion:: ...]` segment. If the inline field highlight has higher priority,
it will override the strikethrough color for that segment but the strikethrough
line should still render (since `strikethrough` is an attribute, not a color).

### 5. Wikilinks in task text

```markdown
- [x] Review [[meeting-notes]] from last week
```

The wikilink highlighting module applies `VaultWikiLinkValid` (or similar) to
the `[[meeting-notes]]` text. Similar to inline fields, the link highlight color
may take precedence over the scope highlight color, but the strikethrough
attribute should combine.

### 6. Cursor interaction

The `obsidian` preset sets `render_modes = true`, meaning rendering persists in
all modes (normal, insert, visual). However, when the cursor is on a rendered
line, concealed elements become visible for editing. The scope highlight
(strikethrough) is an extmark-based highlight, not concealment, so it will remain
visible even when the cursor is on the line. This is the correct behavior -- the
user should still see the strikethrough while editing the task.

### 7. Theme switching

If the user switches to a theme that does not define `RenderMarkdownCheckedScope`
or `RenderMarkdownCancelledScope`, Neovim will use an empty highlight (no
styling). The strikethrough will silently not appear. This is safe -- no errors,
no visual glitches. The feature is simply inactive on non-soft-paper themes.

To make it work across themes, you could set up fallback highlights in the
render-markdown plugin config callback (Step 4 below). This is optional.

### Step 4 (Optional): Fallback Highlights for Non-Soft-Paper Themes

**File:** `lua/andrew/plugins/render-markdown.lua` (inside `config = function`)

Add before the `require("render-markdown").setup(opts)` call:

```lua
-- Ensure strikethrough highlights exist even when soft-paper is not active
local function ensure_hl(name, attrs)
  local ok, current = pcall(vim.api.nvim_get_hl, 0, { name = name })
  if not ok or vim.tbl_isempty(current) then
    vim.api.nvim_set_hl(0, name, attrs)
  end
end
ensure_hl("RenderMarkdownCheckedScope", { strikethrough = true, fg = "#888888" })
ensure_hl("RenderMarkdownCancelledScope", { strikethrough = true, fg = "#888888" })
```

This sets neutral gray fallback highlights that will be overridden when
soft-paper loads (since soft-paper does `vim.api.nvim_set_hl(0, ...)` for all
its highlight groups). On non-soft-paper themes, the fallback provides basic
strikethrough functionality.

---

## Testing

### 1. Basic Strikethrough Rendering

Create or open a markdown file with various task states:

```markdown
## Task List

- [ ] Open task
- [/] In-progress task
- [x] Completed task
- [-] Cancelled task
- [>] Deferred task
```

**Expected:**
- `[ ]` line: no strikethrough, normal text color.
- `[/]` line: no strikethrough, normal text color, yellow clock icon.
- `[x]` line: text has strikethrough + dimmed color (`fg_faint`), green checkmark icon.
- `[-]` line: text has strikethrough + dimmed color (`fg_faint`), red X icon.
- `[>]` line: no strikethrough, normal text color, blue defer icon.

### 2. Formatted Text Inside Completed Task

```markdown
- [x] Fix **critical** bug in `embed.lua` for [[vault-module]]
```

**Expected:**
- The entire text line has strikethrough.
- Bold (`**critical**`) may retain its red/bold styling underneath the strikethrough.
- Inline code (`` `embed.lua` ``) may retain its flamingo color underneath the strikethrough.
- Wikilink (`[[vault-module]]`) may retain its accent color underneath the strikethrough.
- The strikethrough line itself should be visible across all formatted segments.

### 3. Task with Completion Date

```markdown
- [x] Review pull request [completion:: 2026-02-27]
```

**Expected:**
- Strikethrough applies to the entire line including the completion date field.
- The inline field highlight (if active) may color the `[completion:: ...]` part,
  but the strikethrough line should still be visible.

### 4. Nested Tasks

```markdown
- [x] Parent task done
  - [ ] Sub-task still open
  - [x] Sub-task also done
```

**Expected:**
- "Parent task done" has strikethrough.
- "Sub-task still open" has NO strikethrough.
- "Sub-task also done" has strikethrough.
- Strikethrough does NOT cascade from parent to children.

### 5. Checkbox Cycling Interaction

1. Start with `- [ ] Test task`.
2. Press `<leader>mx` to cycle to `[/]` (in-progress).
   - **Expected:** No strikethrough.
3. Press `<leader>mx` to cycle to `[x]` (done).
   - **Expected:** Strikethrough appears. Completion date is appended.
4. Press `<leader>mx` to cycle to `[-]` (cancelled).
   - **Expected:** Strikethrough remains (cancelled also has it). Completion date is removed.
5. Press `<leader>mx` to cycle to `[>]` (deferred).
   - **Expected:** Strikethrough disappears.
6. Press `<leader>mx` to cycle back to `[ ]` (open).
   - **Expected:** No strikethrough.

**Note:** render-markdown.nvim re-renders on text change (CursorMoved/TextChanged
events), so the strikethrough should appear/disappear immediately after the
checkbox character changes.

### 6. Long Task List Scan Test

Open a file with 20+ mixed-state tasks and visually scan:

**Expected:**
- Completed and cancelled tasks are immediately distinguishable by their
  dimmed + struck-through appearance.
- Active tasks (open, in-progress, deferred) are clearly readable with full
  color text.
- The visual hierarchy makes it easy to identify remaining work at a glance.

### 7. Theme Variant Check

1. Load soft-paper light (`:lua require("andrew.themes.soft-paper").load("light")`).
2. Verify strikethrough uses `#797593` (fg_faint light).
3. Load soft-paper dark (`:lua require("andrew.themes.soft-paper").load("dark")`).
4. Verify strikethrough uses `#A5ADCE` (fg_faint dark).
5. Both variants should show clear strikethrough with readable (but dimmed) text.

### 8. Render-Markdown Toggle

1. Disable render-markdown (`:RenderMarkdown disable`).
   - **Expected:** Raw markdown visible, no icons, no strikethrough.
2. Re-enable (`:RenderMarkdown enable`).
   - **Expected:** Icons and strikethrough reappear.

### 9. Performance

Open a vault note with many tasks. There should be no perceptible performance
impact. The `scope_highlight` adds one extmark per completed/cancelled task --
negligible overhead compared to the existing checkbox rendering.

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `render-markdown.nvim` | Provides `scope_highlight` on checkbox states | Yes (already installed and configured) |
| `soft-paper.lua` theme | Defines the `RenderMarkdownCheckedScope` / `RenderMarkdownCancelledScope` highlight groups | Yes for themed colors; No for basic functionality (fallback works without) |

No new plugin dependencies are introduced.

---

## Future Enhancements

1. **Distinct cancelled styling.** Use `{ fg = c.red, strikethrough = true }` for
   `RenderMarkdownCancelledScope` to visually distinguish cancelled tasks from
   completed ones (red strikethrough vs. gray strikethrough).

2. **Scope highlight for deferred tasks.** Apply a subtle italic or dimmed
   style (without strikethrough) to deferred tasks to signal "not active right
   now" without implying "done."

3. **Configurable scope highlights.** Add a `config.task_scope_highlights` table
   in `vault/config.lua` mapping task marks to highlight groups, so users can
   customize the appearance per state without editing the render-markdown plugin
   config directly.
