# Footnote Snippets

## Current State

### Snippet Infrastructure

The Neovim config uses **LuaSnip v2** as the snippet engine, integrated through **blink.cmp** for completion. The loading chain is:

1. **blink.cmp** (`lua/andrew/plugins/blink-cmp.lua`) configures LuaSnip as a dependency with `snippets = { preset = "luasnip" }`.
2. **VSCode-format snippets** loaded via `luasnip.loaders.from_vscode`:
   - `friendly-snippets` (community collection)
   - `~/.config/nvim/snippets/` (custom Fortran snippets only; `package.json` registers `fortran.json` and `new-snippets.json`)
3. **Lua-format snippets** loaded via `luasnip.loaders.from_lua`:
   - `~/.config/nvim/luasnippets/markdown.lua` (~1500 lines, ~200+ snippets)
   - `~/.config/nvim/luasnippets/tex.lua` (LaTeX-specific snippets)

For markdown files, blink.cmp sources are: `wikilinks`, `vault_tags`, `vault_frontmatter`, `lsp`, `snippets`, `path`, `buffer`, `spell`.

### Markdown Snippet File

All markdown snippets live in `luasnippets/markdown.lua`. The file uses these LuaSnip primitives:

- `s()` -- snippet definition
- `t()` -- text node
- `i()` -- insert node (tab stops)
- `c()` -- choice node (cycle through alternatives)
- `f()` -- function node (dynamic text, e.g., `os.date()`)
- `fmt()` -- format strings

Convention for trigger names:
- Short triggers for common patterns: `wl`, `fm`, `task`, `code`, `tbl`
- Semicolon-prefixed triggers for templates: `;meeting-full`, `;research-article`
- Semicolon-prefixed triggers for template sections: `;dailylog-focus`, `;literature-claim`

The file returns `snippets, autosnippets` at the end. Autosnippets are only used for math-mode entry (`mk`, `dm`).

### Existing Footnote Module

`lua/andrew/vault/footnotes.lua` provides:

- `M.jump()` -- Jump between `[^id]` reference and `[^id]:` definition (bound to `<leader>mj`)
- `M.list()` -- List all footnotes via fzf-lua picker (bound to `<leader>mn`)
- Pattern matching: `%[%^([%w_-]+)%]` for references, `^%[%^...%]:` for definitions
- Setup via `require("andrew.vault.footnotes").setup()` in `lua/andrew/vault/init.lua`

The module handles navigation but provides **no snippet or insertion support**.

### blink.cmp Keyword Patch

The blink.cmp config includes a monkey-patch for `keyword.with_constant_is_keyword` that sets `iskeyword` to `@,48-57,_,-,;,192-255`. This ensures semicolon-prefixed triggers (`;meeting-full`, etc.) are treated as single keywords during completion. The `^` character is **not** in this set, which means `[^` will trigger blink.cmp's default word boundary behavior. Snippet triggers should use alphabetic prefixes.

---

## Problem

There are no snippets for inserting markdown footnotes. When writing notes that need footnotes, the user must:

1. Manually type `[^1]` at the reference site
2. Scroll to the end of the document (or a footnotes section)
3. Manually type `[^1]: definition text`
4. Remember which footnote number to use next (requires scanning the buffer)
5. Navigate back to continue writing

This is error-prone (duplicate/skipped numbers) and interrupts writing flow. The existing `footnotes.lua` module can jump between ref/def but cannot create them.

---

## Proposed Solution

Add LuaSnip snippets to `luasnippets/markdown.lua` and a helper function to `lua/andrew/vault/footnotes.lua` for auto-numbering. The snippets use `function_node` (already imported in markdown.lua) to scan the buffer and determine the next available footnote number.

### Auto-Numbering Logic

Add a `next_id()` function to `lua/andrew/vault/footnotes.lua` that scans the current buffer for all `[^N]` patterns and returns the next available integer.

**File to edit:** `lua/andrew/vault/footnotes.lua`

Add after the `get_footnote_at_cursor()` local function (before `M.jump`):

```lua
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
```

**Behavior:**
- Scans only numeric footnote IDs (ignores named footnotes like `[^note-name]`)
- Returns `1` when there are no numeric footnotes in the buffer
- Returns `max + 1` to avoid collisions (e.g., if buffer has `[^1]` and `[^3]`, returns `4`)
- Intentionally does not fill gaps (consistent with Obsidian and Pandoc conventions)

### Snippet Definitions

**File to edit:** `luasnippets/markdown.lua`

Add a new section after the "Inline field snippets" block (after line ~464) and before the "Table snippet" block. This keeps footnote snippets grouped with other inline syntax elements.

Add `require("andrew.vault.footnotes")` at the top of the file (after line 8):

```lua
local footnotes = require("andrew.vault.footnotes")
```

Then add the following snippets inside the `local snippets = { ... }` table:

#### 1. Footnote Reference (`fnr`)

Insert `[^N]` at cursor with auto-incremented number.

```lua
  ---------------------------------------------------------------------------
  -- Footnote snippets
  ---------------------------------------------------------------------------

  s({ trig = "fnr", desc = "Footnote reference [^N]" }, {
    t("[^"),
    f(function() return tostring(footnotes.next_id()) end),
    t("]"),
  }),
```

**Trigger:** `fnr`
**Expansion:** `[^3]` (if 2 footnotes already exist)
**Jump points:** None (fire-and-forget reference insertion)

#### 2. Footnote Definition (`fnd`)

Insert `[^N]: definition` at cursor for writing the definition body.

```lua
  s({ trig = "fnd", desc = "Footnote definition [^N]: ..." }, {
    t("[^"),
    f(function() return tostring(footnotes.next_id()) end),
    t("]: "),
    i(1, "definition"),
  }),
```

**Trigger:** `fnd`
**Expansion:** `[^3]: definition`
**Jump points:** `$1` = definition text

#### 3. Footnote with Specific ID (`fn`)

Insert a footnote reference with a manually-specified ID.

```lua
  s({ trig = "fn", desc = "Footnote reference [^id]" }, {
    t("[^"),
    i(1, "id"),
    t("]"),
  }),
```

**Trigger:** `fn`
**Expansion:** `[^id]`
**Jump points:** `$1` = footnote identifier

#### 4. Footnote Definition with Specific ID (`fndef`)

Insert a footnote definition with a manually-specified ID.

```lua
  s({ trig = "fndef", desc = "Footnote definition [^id]: ..." }, {
    t("[^"),
    i(1, "id"),
    t("]: "),
    i(2, "definition"),
  }),
```

**Trigger:** `fndef`
**Expansion:** `[^id]: definition`
**Jump points:** `$1` = footnote identifier, `$2` = definition text

#### 5. Paired Footnote (`fnp`)

Insert a reference at cursor and a definition block below (separated by a blank line). Uses `function_node` for the auto-number and `rep` to mirror it in both locations.

Requires adding `rep` import at the top of the file:

```lua
local rep = require("luasnip.extras").rep
```

```lua
  s({ trig = "fnp", desc = "Paired footnote: reference + definition" }, {
    t("[^"),
    i(1, "1"),
    t("]"),
    t({ "", "", "[^" }),
    rep(1),
    t("]: "),
    i(2, "definition"),
  }),
```

**Trigger:** `fnp`
**Expansion:**
```
[^1]

[^1]: definition
```
**Jump points:** `$1` = footnote ID (mirrored in both reference and definition), `$2` = definition text
**Note:** The user types the ID once and it appears in both places. This uses `rep(1)` (repeat node) to mirror the first insert node.

#### 6. Paired Footnote with Auto-Number (`fnpa`)

Same as `fnp` but pre-fills the next available number.

```lua
  s({ trig = "fnpa", desc = "Paired footnote (auto-numbered): reference + definition" }, {
    t("[^"),
    f(function() return tostring(footnotes.next_id()) end),
    t({ "]", "", "[^" }),
    f(function() return tostring(footnotes.next_id()) end),
    t("]: "),
    i(1, "definition"),
  }),
```

**Trigger:** `fnpa`
**Expansion:** `[^3]\n\n[^3]: definition` (auto-numbered)
**Jump points:** `$1` = definition text
**Note:** Both `f()` calls execute at expansion time and return the same value since no buffer modification has occurred between them.

#### 7. Inline Footnote (`fni`)

Pandoc/some renderers support inline footnotes: `^[definition text]`.

```lua
  s({ trig = "fni", desc = "Inline footnote ^[...]" }, {
    t("^["),
    i(1, "footnote text"),
    t("]"),
  }),
```

**Trigger:** `fni`
**Expansion:** `^[footnote text]`
**Jump points:** `$1` = inline footnote content

### Integration

#### Loading Path

The snippets are added to `luasnippets/markdown.lua` which is already loaded by:

```lua
require("luasnip.loaders.from_lua").lazy_load({
  paths = { vim.fn.stdpath("config") .. "/luasnippets" },
})
```

No additional loader configuration is needed.

#### Dependency on footnotes.lua

The `require("andrew.vault.footnotes")` call at the top of `luasnippets/markdown.lua` is safe because:

1. `footnotes.lua` has no side effects on `require` (it just returns a table `M`)
2. `footnotes.setup()` is called later from `vault/init.lua` to register keymaps, which is independent
3. The `M.next_id()` function only reads buffer lines -- no state initialization required
4. LuaSnip's `from_lua` loader uses `lazy_load()`, so the require happens only when a markdown buffer is first opened

#### blink.cmp Keyword Handling

The triggers `fn`, `fnr`, `fnd`, `fndef`, `fnp`, `fnpa`, `fni` are all purely alphabetic. They will work correctly with blink.cmp's monkey-patched `iskeyword` setting (`@,48-57,_,-,;,192-255`) since all characters fall within the `@` (alpha) class.

### File Changes

| File | Action | Description |
|------|--------|-------------|
| `lua/andrew/vault/footnotes.lua` | **Edit** | Add `M.next_id()` function (~12 lines) |
| `luasnippets/markdown.lua` | **Edit** | Add `require("andrew.vault.footnotes")` import (1 line) |
| `luasnippets/markdown.lua` | **Edit** | Add `rep` import from `luasnip.extras` (1 line) |
| `luasnippets/markdown.lua` | **Edit** | Add 7 footnote snippets (~55 lines) in new "Footnote snippets" section |

No new files need to be created. No plugin configuration changes needed.

### Configuration

No user-configurable options are proposed for the initial implementation. The snippet triggers are hardcoded, consistent with all other snippet triggers in `luasnippets/markdown.lua`.

**Future options** (if needed, add to `lua/andrew/vault/config.lua`):

```lua
M.footnotes = {
  auto_number = true,     -- whether fnr/fnd use auto-numbering
  number_style = "int",   -- "int" (1,2,3) or "alpha" (a,b,c) or "named"
  fill_gaps = false,       -- whether next_id fills gaps or always uses max+1
}
```

These are not included in the initial implementation to avoid over-engineering.

### Testing Plan

#### Manual Tests

1. **Auto-numbering accuracy:**
   - Open a markdown file with no footnotes. Expand `fnr`. Verify it produces `[^1]`.
   - Add `[^1]` and `[^2]` manually. Expand `fnr`. Verify it produces `[^3]`.
   - Add `[^1]` and `[^5]` (gap). Expand `fnr`. Verify it produces `[^6]` (max+1, not gap-fill).
   - Add named footnotes only (`[^note]`, `[^ref-name]`). Expand `fnr`. Verify it produces `[^1]` (ignores non-numeric).

2. **Snippet expansion:**
   - Type `fnr` in insert mode, select from completion menu. Verify `[^N]` appears.
   - Type `fnd` in insert mode, select from completion menu. Verify `[^N]: definition` appears with cursor on "definition".
   - Type `fn` in insert mode, select from completion menu. Verify `[^id]` appears with cursor on "id".
   - Type `fndef` in insert mode, select from completion menu. Verify `[^id]: definition` appears. Tab from id to definition.
   - Type `fnp` in insert mode, select from completion menu. Verify reference and definition appear. Type a number in `$1` and verify it mirrors in both locations.
   - Type `fnpa` in insert mode, select from completion menu. Verify auto-numbered reference and definition appear.
   - Type `fni` in insert mode, select from completion menu. Verify `^[footnote text]` appears.

3. **Jump point navigation:**
   - For `fnd`: Verify Tab moves to definition text.
   - For `fndef`: Verify Tab moves from id to definition.
   - For `fnp`: Verify Tab moves from id to definition. Verify id is mirrored.

4. **Integration with existing footnotes module:**
   - Insert a footnote via `fnr`. Use `<leader>mj` (footnote jump). Verify "No definition found" message.
   - Insert a matching definition via `fnd`. Use `<leader>mj` to jump between them.
   - Use `<leader>mn` (footnote list). Verify snippet-inserted footnotes appear in the picker.

5. **blink.cmp completion:**
   - In a markdown buffer, type `fn` and verify completion menu shows all footnote snippets.
   - Verify the source label shows "Snippet" in the completion menu.
   - Verify ghost text preview shows the expansion.
   - Verify the snippets do NOT appear in non-markdown files (filetype gating via LuaSnip loader).

6. **Edge cases:**
   - Empty buffer: `fnr` should produce `[^1]`.
   - Buffer with only footnote definitions (no references): auto-number should still find them.
   - Buffer with footnotes in code blocks: `next_id()` will count them (acceptable; perfect parsing is not worth the complexity).
   - Very large buffer with many footnotes: `next_id()` scans all lines -- should be fast for typical note sizes.
