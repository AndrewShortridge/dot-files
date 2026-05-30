# 23 — Spell Checking for Markdown Buffers

## Problem

The markdown ftplugin already sets `spell = true` and `spelllang = "en_us"`, so spell checking is technically active. However, it has several usability issues in the vault context:

1. **False positives in non-prose regions** — spell checking flags words inside code blocks, frontmatter YAML keys/values, wikilink targets (`[[Note Name]]`), URLs, and LaTeX math expressions (`$\alpha$`, `$$\nabla$$`). These are not English prose and should never be spell-checked.
2. **No custom dictionary** — vault-specific technical jargon (e.g., `CFD`, `OpenFOAM`, `RANS`, `LES`, `Navier-Stokes`), project names, and domain terminology are constantly flagged as misspellings.
3. **No completion integration** — spell suggestions are only accessible via the modal `z=` window; they are not surfaced through blink.cmp's inline completion menu.
4. **No toggle** — spell checking cannot be quickly toggled on/off without typing `:set nospell`.
5. **Highlight clutter** — `SpellBad` underlines conflict visually with render-markdown.nvim's concealed/rendered elements, especially inside headings and callouts.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **ftplugin/markdown.lua** | Sets `spell = true`, `spelllang = "en_us"` | `ftplugin/markdown.lua` |
| **Treesitter `markdown`** | `(inline) @spell` marks prose for spell checking | nvim-treesitter queries |
| **Treesitter `markdown_inline`** | `@nospell` on code_span, shortcut_link, link_destination, uri_autolink, entity_reference | nvim-treesitter queries |
| **Frontmatter** | `(plus_metadata)` / `(minus_metadata)` matched as `@keyword.directive` but **not** `@nospell` | nvim-treesitter queries |
| **Wikilinks** | `(shortcut_link (link_text) @nospell)` covers `[[target]]` text but NOT the `[[` brackets | nvim-treesitter queries |
| **LaTeX math** | No `@nospell` capture for inline `$...$` or display `$$...$$` math | nvim-treesitter queries |
| **blink-cmp** | No spell source configured | `blink-cmp.lua` |
| **Custom spellfile** | Does not exist | — |

### What Treesitter Already Handles

The `markdown` and `markdown_inline` highlight queries from nvim-treesitter provide partial spell coverage:

**Already `@nospell` (no changes needed):**
- `(code_span)` — inline code like `` `variable` ``
- `(shortcut_link (link_text))` — wikilink text `[[target]]`
- `(link_destination)`, `(uri_autolink)`, `(email_autolink)` — URLs
- `(entity_reference)` — HTML entities like `&amp;`

**Already `@spell` (prose is correctly checked):**
- `(inline)` in the `markdown` parser — all inline content in paragraphs

**Missing `@nospell` (need custom queries):**
- Frontmatter (`plus_metadata`, `minus_metadata`) — YAML content gets spell-checked
- Fenced code block content — the block node is `@markup.raw.block` but inner lines need `@nospell`
- LaTeX math (inline and display) — parsed by `markdown_inline` as specific node types

---

## Goal

Configure spell checking so that:

1. Spell checking is active in markdown buffers with `en_us` language.
2. Non-prose regions are excluded: code blocks, code spans, frontmatter, wikilinks, URLs, and LaTeX math.
3. A custom spellfile holds vault-specific terms (technical jargon, project names, abbreviations).
4. Spell suggestions are available through blink.cmp completion.
5. Standard vim spell keymaps work (`]s`, `[s`, `zg`, `z=`) plus a toggle at `<leader>mS`.
6. Spell highlight groups are styled to not clash with render-markdown.nvim's rendering.

---

## Approach

### Architecture

This is a configuration-level change spread across several existing files, plus two new files:

1. **Custom treesitter queries** — add `@nospell` captures for frontmatter and LaTeX math.
2. **Spellfile** — create `spell/en.utf-8.add` for custom dictionary words.
3. **ftplugin/markdown.lua** — add spellfile path, toggle keymap, highlight customization.
4. **blink-cmp spell source** — custom blink.cmp source that provides `vim.fn.spellsuggest()` results.
5. **blink-cmp config** — register the spell source for markdown filetype.

### Treesitter `@nospell` Strategy

Neovim's spell checker respects treesitter `@spell` and `@nospell` captures. When treesitter highlighting is active (which it is for markdown), regions marked `@nospell` are excluded from spell checking. We add custom query files that **extend** the default queries (using `;; extends` directive).

| Region | Parser | Query Node | File |
|--------|--------|-----------|------|
| Frontmatter | `markdown` | `(plus_metadata)`, `(minus_metadata)` | `queries/markdown/highlights.scm` |
| Fenced code block content | `markdown` | `(fenced_code_block)` | Already `@markup.raw.block` (covered) |
| LaTeX inline math | `markdown_inline` | `(latex_inline)` | `queries/markdown_inline/highlights.scm` |
| LaTeX display math | `markdown` | `(latex_block)` | `queries/markdown/highlights.scm` |

**Note:** Fenced code blocks are already captured as `@markup.raw.block` which inherits `@nospell` behavior because `(inline) @spell` only applies to inline content within paragraphs, not to code block content. The `markdown` treesitter parser puts code block text inside `(code_fence_content)` which is a child of `(fenced_code_block)`, not of `(inline)`. So code blocks are already effectively `@nospell`. Frontmatter and LaTeX are the primary gaps.

---

## Implementation

### File: `queries/markdown/highlights.scm` (extend existing)

This file already exists in the nvim-treesitter runtime; we create a local override that extends it.

```scheme
;; extends

; Frontmatter (YAML between --- delimiters) should not be spell-checked.
; Covers both --- (minus) and +++ (plus) frontmatter styles.
(minus_metadata) @nospell
(plus_metadata) @nospell

; LaTeX display math blocks ($$...$$) should not be spell-checked.
; Note: This node only exists if the markdown parser has LaTeX extension enabled.
((latex_block) @nospell
  (#set! priority 101))
```

### File: `queries/markdown_inline/highlights.scm` (extend existing)

A local override already exists at `queries/markdown_inline/images.scm` for image queries. The highlights query is separate.

```scheme
;; extends

; LaTeX inline math ($...$) should not be spell-checked.
; Note: This node only exists if the markdown_inline parser has LaTeX extension enabled.
((latex_inline) @nospell
  (#set! priority 101))
```

**Important:** The `#set! priority 101` ensures these `@nospell` captures take precedence over the general `(inline) @spell` capture (priority 100 by default). Without this, the `@spell` capture on the parent `(inline)` node would win.

### Validating Treesitter Nodes

Before writing these queries, verify the actual node names in the installed parsers:

```vim
" Open a markdown file with frontmatter and LaTeX, then:
:InspectTree

" Check if these nodes exist in the tree:
" - minus_metadata / plus_metadata (for --- frontmatter)
" - latex_block (for $$...$$ display math)
" - latex_inline (for $...$ inline math)
```

If the LaTeX nodes are not present, the parser may not have the LaTeX extension. In that case, fall back to a Lua-based approach (see Edge Cases).

---

### File: `spell/en.utf-8.add` (new)

Create the custom spellfile directory and seed it with common vault terms:

```
CFD
OpenFOAM
RANS
LES
DNS
Navier-Stokes
turbomachinery
Kolmogorov
k-epsilon
k-omega
SST
DES
DDES
IDDES
SAS
URANS
Spalart-Allmaras
Smagorinsky
subgrid
timestep
timesteps
discretization
discretize
upwinding
advection
frontmatter
wikilink
wikilinks
treesitter
Neovim
nvim
Lua
LuaSnip
Obsidian
Zettelkasten
backlink
backlinks
transclusion
extmark
extmarks
blockref
callout
callouts
YAML
```

After creating this file, Neovim auto-compiles it to `spell/en.utf-8.add.spl` on first use. The `.spl` file should be gitignored.

---

### File: `ftplugin/markdown.lua` (modify)

Add spellfile configuration and toggle keymap. Changes to the existing file:

```lua
-- At the top, after existing opt_local settings:

local opt_local = vim.opt_local

opt_local.spell = true
opt_local.spelllang = "en_us"
opt_local.conceallevel = 2

-- Custom spellfile for vault-specific terms.
-- vim.opt_local.spellfile is a comma-separated list; append our custom file.
-- The first entry is the default (where zg adds words).
local spell_dir = vim.fn.stdpath("config") .. "/spell"
vim.fn.mkdir(spell_dir, "p")
opt_local.spellfile = spell_dir .. "/en.utf-8.add"

-- ... (existing fold settings, keymaps, etc.) ...

-- =============================================================================
-- Spell Checking Toggle and Keymaps
-- =============================================================================

map("<leader>mS", function()
  vim.opt_local.spell = not vim.opt_local.spell:get()
  vim.notify(
    "Spell checking " .. (vim.opt_local.spell:get() and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end, "Toggle spell check")
```

The built-in spell keymaps (`]s`, `[s`, `zg`, `z=`, `zw`, `zug`) already work when `spell` is enabled. No custom mappings are needed for these — they are vim defaults. Document them in the which-key group for discoverability:

```lua
-- In the which-key section at the bottom of ftplugin/markdown.lua:
local ok, wk = pcall(require, "which-key")
if ok then
  wk.add({
    { "<leader>m", group = "Markdown", buffer = 0 },
    -- Spell sub-documentation (these are built-in vim motions, listed for discoverability)
    { "]s", desc = "Next misspelling", buffer = 0 },
    { "[s", desc = "Prev misspelling", buffer = 0 },
    { "z=", desc = "Spell suggestions", buffer = 0 },
    { "zg", desc = "Add word to spellfile", buffer = 0 },
    { "zw", desc = "Mark word as bad", buffer = 0 },
    { "zug", desc = "Undo add to spellfile", buffer = 0 },
  })
end
```

---

### File: `lua/andrew/vault/completion_spell.lua` (new)

A blink.cmp source that provides spell suggestions for the word under the cursor. This integrates spell correction into the normal completion flow.

```lua
--- blink.cmp spell suggestion source for markdown buffers.
--- Provides vim.fn.spellsuggest() results as completion items.
---
--- Only activates when the cursor is on a misspelled word (identified by
--- vim's spell checking). This avoids polluting the completion menu with
--- spell suggestions for correctly-spelled words.

local kind_text = 1 -- CompletionItemKind.Text

--- @class blink.cmp.SpellSource : blink.cmp.Source
local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

--- Check if spell source should be enabled.
--- Only provide completions when spell checking is active.
function M:enabled()
  return vim.wo.spell
end

--- Get completions: spell suggestions for the word under cursor.
---@param _context blink.cmp.Context
---@param callback fun(response: blink.cmp.CompletionResponse)
function M:get_completions(_context, callback)
  -- Get the word under cursor
  local word = vim.fn.expand("<cword>")
  if not word or word == "" then
    callback({ is_incomplete_forward = false, items = {} })
    return
  end

  -- Only suggest corrections for misspelled words.
  -- vim.fn.spellbadword() returns {"word", "type"} for bad words, {"", ""} otherwise.
  local bad = vim.fn.spellbadword(word)
  if not bad or not bad[1] or bad[1] == "" then
    callback({ is_incomplete_forward = false, items = {} })
    return
  end

  -- Get suggestions (limit to 10 for performance)
  local suggestions = vim.fn.spellsuggest(word, 10)
  local items = {}
  for i, suggestion in ipairs(suggestions) do
    items[i] = {
      label = suggestion,
      kind = kind_text,
      insertText = suggestion,
      filterText = word, -- Match against the misspelled word so the menu shows
      sortText = string.format("%04d", i), -- Preserve spellsuggest order
      labelDetails = {
        description = "Spell",
      },
      data = {
        source = "spell",
      },
    }
  end

  callback({
    is_incomplete_forward = false,
    items = items,
  })
end

return M
```

---

### File: `lua/andrew/plugins/blink-cmp.lua` (modify)

Register the spell source for markdown buffers. Add to the `sources.providers` table and the `per_filetype.markdown` list:

```lua
-- In sources.providers, add:
spell = {
  name = "Spell",
  module = "andrew.vault.completion_spell",
  min_keyword_length = 3,
  score_offset = -5, -- Lower priority than LSP, snippets, wikilinks
  fallbacks = {},
},

-- In sources.per_filetype.markdown, append "spell":
markdown = { "wikilinks", "vault_tags", "vault_frontmatter", "lsp", "snippets", "path", "buffer", "spell" },
```

The negative `score_offset` ensures spell suggestions appear below more relevant sources (wikilinks, tags, LSP) but still surface when typing a misspelled word.

---

### Highlight Group Customization

The default `SpellBad` highlight uses a red undercurl, which can be visually noisy alongside render-markdown.nvim's styled headings and callouts. Customize the spell highlight groups in `lua/andrew/plugins/colorscheme.lua`:

```lua
-- Add to the highlights table in onedarkpro.setup():
highlights = {
  Normal = { bg = "#1E222A" },
  NormalFloat = { bg = "#17191d" },
  FloatBorder = { fg = "#E06C75", bg = "#1E222A" },

  -- Spell checking: subtle underline instead of aggressive undercurl.
  -- Uses colors from the OneDarkPro palette.
  SpellBad = { sp = "#e06c75", undercurl = true },        -- Red undercurl (misspelling)
  SpellCap = { sp = "#e5c07b", undercurl = true },        -- Yellow undercurl (capitalization)
  SpellLocal = { sp = "#56b6c2", undercurl = true },      -- Cyan undercurl (local-only word)
  SpellRare = { sp = "#c678dd", undercurl = true },       -- Purple undercurl (rare word)
},
```

**Interaction with render-markdown.nvim:** The `render-markdown.nvim` plugin uses extmarks with high priority (1000+) for its concealed rendering. Spell highlights are applied at the syntax/treesitter level, not via extmarks, so they layer underneath. When render-markdown conceals text (e.g., `**bold**` becomes **bold**), the concealed delimiters are hidden and spell checking only applies to the visible text. No special handling is needed.

**Interaction with conceallevel:** At `conceallevel = 2`, concealed characters are hidden completely. Spell checking operates on the actual buffer text, not the displayed text. This means:
- Wikilink syntax `[[note name]]` — the `[[` and `]]` are concealed visually but still present in the buffer. The `@nospell` on `(shortcut_link)` prevents "note name" from being spell-checked.
- Bold `**word**` — the `**` delimiters are concealed. The word itself is still spell-checked (correct behavior).

---

## Integration

### 1. Create spell directory and spellfile

```bash
mkdir -p ~/.config/nvim/spell
# Create en.utf-8.add with vault-specific terms (see content above)
```

### 2. Add to .gitignore

```gitignore
# Compiled spell files (auto-generated from .add files)
spell/*.spl
```

### 3. Create treesitter query extensions

```bash
# These directories may already exist
mkdir -p ~/.config/nvim/queries/markdown
mkdir -p ~/.config/nvim/queries/markdown_inline

# Create the highlights.scm files with ;; extends directive
```

### 4. Modify existing files

| File | Change |
|------|--------|
| `ftplugin/markdown.lua` | Add `spellfile` path, `<leader>mS` toggle, which-key spell entries |
| `lua/andrew/plugins/blink-cmp.lua` | Add `spell` provider and add to markdown `per_filetype` |
| `lua/andrew/plugins/colorscheme.lua` | Add `SpellBad`/`SpellCap`/`SpellLocal`/`SpellRare` highlight overrides |

### 5. Create new files

| File | Purpose |
|------|---------|
| `spell/en.utf-8.add` | Custom spellfile for vault-specific terms |
| `queries/markdown/highlights.scm` | `@nospell` for frontmatter and LaTeX display math |
| `queries/markdown_inline/highlights.scm` | `@nospell` for LaTeX inline math |
| `lua/andrew/vault/completion_spell.lua` | blink.cmp spell suggestion source |

---

## Testing

### Manual Verification

1. **Open a vault markdown file with mixed content:**

   ```markdown
   ---
   title: Test Spell Checking
   tags: [CFD, simulation]
   status: In Progress
   ---

   # Spell Checking Test

   This paragraph has a misspeled word that should be underlined.

   Technical terms like CFD, RANS, LES, and OpenFOAM should NOT be flagged.

   Wikilinks like [[Navier-Stokes Equations]] should not be flagged.

   Code spans like `kubectl apply -f deployment.yaml` should not be flagged.

   ```python
   # Nothing in here should be spell-checked
   variabel_name = "not a typo in code"
   ```

   Inline math $\alpha + \beta = \gamma$ should not be flagged.

   Display math:
   $$
   \frac{\partial u}{\partial t} + (u \cdot \nabla)u = -\nabla p + \nu \nabla^2 u
   $$

   A URL like https://openfoam.org/documentation should not be flagged.
   ```

2. **Expected behavior:**
   - `misspeled` (line 11) gets `SpellBad` undercurl
   - Frontmatter keys/values (`title`, `tags`, `status`) — no spell highlights
   - `CFD`, `RANS`, `LES`, `OpenFOAM` — no highlights (in custom spellfile)
   - `[[Navier-Stokes Equations]]` — no highlights (`@nospell` on shortcut_link)
   - Code span content — no highlights (`@nospell` on code_span)
   - Fenced code block content — no highlights (not inside `(inline)`)
   - LaTeX math — no highlights (custom `@nospell` query)
   - URL — no highlights (`@nospell` on link_destination/uri_autolink)

3. **Spell operations:**
   - `]s` jumps to `misspeled`
   - `z=` opens suggestion window showing "misspelled"
   - `zg` adds word to `spell/en.utf-8.add`
   - `<leader>mS` toggles spell on/off with notification

4. **Completion integration:**
   - Position cursor on `misspeled` in insert mode
   - Trigger completion (`<C-Space>` or type)
   - Spell suggestions should appear with "Spell" source label

### Verify Treesitter `@nospell` Captures

```vim
" Place cursor on frontmatter text and run:
:Inspect

" Should show @nospell capture. If not, the custom query isn't loading.
" Check that the query file starts with ";; extends" (two semicolons, not one).
```

### Verify Spellfile

```vim
" Check that the spellfile is loaded:
:set spellfile?
" Should show: ~/.config/nvim/spell/en.utf-8.add

" Check that custom words are recognized:
:echo spellbadword("CFD")
" Should return ['', ''] (empty = not misspelled)

" If it returns ['CFD', 'bad'], the spellfile isn't compiled.
" Force recompile:
:mkspell! ~/.config/nvim/spell/en.utf-8.add
```

### Performance

Spell checking is handled natively by Neovim's C code and is very fast. The only Lua overhead is:
- `completion_spell.lua`: calls `spellsuggest()` only when cursor is on a misspelled word (guarded by `spellbadword()` check). Cost: < 1ms per completion trigger.
- Treesitter `@nospell` queries: evaluated as part of the normal treesitter highlight pass. No additional cost.

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| No treesitter parser | Vim falls back to syntax-based spell regions; less accurate but functional |
| LaTeX nodes missing from parser | `@nospell` query silently has no effect; LaTeX math may get spell-checked. Mitigation: check with `:InspectTree` and fall back to syntax-level `@nospell` if needed |
| Very long document (1000+ lines) | Spell checking is incremental (Neovim only checks visible lines + a buffer). No performance issue |
| Word in spellfile AND misspelled elsewhere | `zg` adds to the first spellfile in the list; word is accepted everywhere |
| Non-vault markdown files | Spell checking still works (it's set via ftplugin, not vault module). Custom spellfile still loads |
| Concealed text with `conceallevel = 2` | Spell checking applies to buffer text, not display text. Concealed regions may still be checked unless `@nospell` is set |
| Blink.cmp spell source on correct words | `spellbadword()` guard returns early — no suggestions shown for correct words |
| Mixed-language content | Only `en_us` is checked. Foreign language words will be flagged. User can `zg` to add them or add a second `spelllang` |
| `render-markdown.nvim` inline rendering | render-markdown uses extmarks at high priority; spell underlines render below. Visual overlap is minimal since underlines are beneath text |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| Treesitter `markdown` parser | `@nospell` captures for frontmatter, display math | Yes (already installed) |
| Treesitter `markdown_inline` parser | `@nospell` captures for inline math, code spans | Yes (already installed) |
| blink.cmp | Hosts the spell completion source | No (spell works without completion integration) |
| render-markdown.nvim | No changes needed; spell underlines layer below extmarks | No |
| vim spell engine | Core functionality — built into Neovim | Yes (built-in) |

---

## Key Files Modified

| File | Change |
|------|--------|
| `ftplugin/markdown.lua` | Add `spellfile` path, `<leader>mS` toggle, which-key entries |
| `lua/andrew/plugins/blink-cmp.lua` | Add spell provider, update markdown per_filetype |
| `lua/andrew/plugins/colorscheme.lua` | Add SpellBad/SpellCap/SpellLocal/SpellRare highlights |
| `queries/markdown/highlights.scm` | **New file** — `@nospell` for frontmatter and display math |
| `queries/markdown_inline/highlights.scm` | **New file** — `@nospell` for inline math |
| `spell/en.utf-8.add` | **New file** — custom spellfile with vault terms |
| `lua/andrew/vault/completion_spell.lua` | **New file** — blink.cmp spell suggestion source |

---

## Risk Assessment

**Risk: Low**

- Spell checking is already enabled (`ftplugin/markdown.lua` line 3-4). This improvement adds configuration around existing functionality rather than introducing new behavior.
- Custom treesitter queries use the `;; extends` directive, so they add captures without replacing the default queries. If they fail to load, the default behavior continues unchanged.
- The blink.cmp spell source is an additive completion provider with negative `score_offset` — it cannot interfere with existing sources.
- The custom spellfile is append-only; `zg` adds words, and the file can be version-controlled.
- Highlight group overrides use `onedarkpro`'s `highlights` table, which is the intended customization mechanism.
- No existing keymaps are modified. `<leader>mS` is unused (lowercase `<leader>ms` is strikethrough).

---

## Future Enhancements

1. **Vault-aware spell exclusion** — A Lua module (similar to `tag_highlights.lua`) could scan for `[[wikilink]]` targets that are valid note names and dynamically add them to the spellfile. This would prevent flagging valid note names that aren't in the static spellfile.

2. **Per-note language** — Read a `lang:` frontmatter field and set `spelllang` per-buffer. Useful for multilingual vaults.

3. **Spell diagnostics via nvim-lint** — Use `cspell` as an nvim-lint linter for more sophisticated spell checking with domain-specific dictionaries (e.g., scientific, programming).

4. **Auto-populate spellfile from vault** — A command that scans all vault notes for words that appear frequently (3+ times) but aren't in any dictionary, then offers to add them to the spellfile in bulk.
