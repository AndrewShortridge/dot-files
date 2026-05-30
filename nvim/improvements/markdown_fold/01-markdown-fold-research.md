# Markdown Folding: A Comprehensive Analysis

This document is an exhaustive investigation of every method used to implement
code folding in markdown files across Vim, Neovim, LSP, and the plugin ecosystem.

---

## Table of Contents

1. [Treesitter-Based Folding (Neovim Native)](#1-treesitter-based-folding-neovim-native)
2. [Vim Built-in Fold Methods](#2-vim-built-in-fold-methods)
   - [foldmethod=indent](#2a-foldmethodindent)
   - [foldmethod=syntax](#2b-foldmethodsyntax)
   - [foldmethod=marker](#2c-foldmethodmarker)
   - [foldmethod=manual](#2d-foldmethodmanual)
   - [foldmethod=diff](#2e-foldmethoddiff)
3. [Expression-Based Folding (foldmethod=expr)](#3-expression-based-folding-foldmethodexpr)
   - [g:markdown_folding (Vim built-in ftplugin)](#3a-gmarkdown_folding)
4. [Plugin-Based Folding](#4-plugin-based-folding)
   - [preservim/vim-markdown](#4a-preservimvim-markdown)
   - [masukomi/vim-markdown-folding](#4b-masukomivim-markdown-folding)
   - [kevinhwang91/nvim-ufo](#4c-kevinhwang91nvim-ufo)
   - [jakewvincent/mkdnflow.nvim](#4d-jakewvincentmkdnflownvim)
   - [chimay/organ](#4e-chimayorgan)
   - [Konfekt/FastFold (performance companion)](#4f-konfektfastfold)
5. [LSP-Based Folding](#5-lsp-based-folding)
   - [The Protocol: textDocument/foldingRange](#5a-the-protocol)
   - [VS Code's Markdown Language Service](#5b-vs-codes-markdown-language-service)
   - [Marksman, markdown-oxide, remark-language-server](#5c-other-markdown-lsps)
   - [Neovim's Native LSP Folding (0.11+)](#5d-neovims-native-lsp-folding)
6. [Your Current Configuration](#6-your-current-configuration)
7. [Master Comparison Table](#7-master-comparison-table)

---

## 1. Treesitter-Based Folding (Neovim Native)

### Architecture

Treesitter folding operates in two decoupled phases:

1. **Compute phase** (`compute_folds_levels`): Walks the treesitter syntax tree,
   collects `@fold` captures from `folds.scm` queries, and builds a per-line
   fold level cache.
2. **Evaluate phase** (`foldexpr`): Called by Vim for each line when
   `foldmethod=expr` is active. Reads from the cache (O(1) lookup) — it does
   NOT re-walk the tree on every call.

**Entry point:**
```lua
vim.wo.foldmethod = 'expr'
vim.wo.foldexpr = 'v:lua.vim.treesitter.foldexpr()'
```

Available since Neovim 0.9, stabilized in 0.10. The implementation lives at
`runtime/lua/vim/treesitter/_fold.lua`. The legacy `nvim_treesitter#foldexpr()`
wrapper is obsolete and should not be used.

### Internal Data Structure

```lua
---@class TS.FoldInfo
---@field levels string[]     -- cached foldexpr result per line (">2", "1", "0")
---@field levels0 integer[]   -- raw fold levels (unclamped) per line
---@field on_bytes_range? Range2   -- range dirty from edits
---@field foldupdate_range? Range2 -- range pending foldUpdate
---@field parser? vim.treesitter.LanguageTree
```

A `FoldInfo` object is keyed per buffer in a module-level `foldinfos` table.

### The Fold Level Computation Algorithm

1. Calls `parser:parse()` asynchronously, then `parser:for_each_tree()` to
   iterate over all language trees (including injections like code blocks).
2. For each tree, loads the `folds` query via `ts.query.get(lang, 'folds')`.
3. Iterates `@fold` capture matches within the changed range.
4. For each `@fold` node: extracts start/stop rows. If `stop_col == 0`, the
   fold ends at `stop - 1` (avoids including trailing empty lines).
5. Filters: only processes folds where `fold_length > vim.wo.foldminlines`.
6. Increments `enter_counts[start+1]` and `leave_counts[stop+1]`.
7. Sweeps through lines computing: `level0 = level0_prev - leave_prev + enter_line`
8. Generates the foldexpr string: `">" .. level0` when a fold starts (clamped
   to `foldnestmax`). Lines inside a fold get their numeric level.

### The Markdown `folds.scm` Query

The bundled query at `runtime/queries/markdown/folds.scm`:

```scheme
([
  (fenced_code_block)
  (indented_code_block)
  (list_item
    (list))
  (section)
] @fold
  (#trim! @fold))

(section
  (list) @fold
  (#trim! @fold))
```

### The `section` Node — Key to Heading Folding

The tree-sitter-markdown grammar defines nested `section` nodes. This is the
critical structural insight:

```markdown
# H1 Title
content under h1

## H2 Title
content under h2
```

Produces a tree like:
```
document
  section (h1, spans lines 1–N)
    atx_heading (# H1 Title)
    paragraph (content under h1)
    section (h2, spans lines 4–N)
      atx_heading (## H2 Title)
      paragraph (content under h2)
```

Since every `section` is captured as `@fold`, fold level 1 = H1, fold level 2 =
H2 inside H1, etc. The nesting depth maps directly to fold depth. **No special
heading-level detection code is needed.**

Both ATX (`#`) and Setext (underline) headings produce `section` nodes and are
handled identically.

### What Gets Folded

| Markdown Element         | Folded? | Mechanism                         |
|--------------------------|---------|-----------------------------------|
| ATX heading section      | Yes     | `(section) @fold`                 |
| Setext heading section   | Yes     | `(section) @fold`                 |
| Fenced code block        | Yes     | `(fenced_code_block) @fold`       |
| Indented code block      | Yes     | `(indented_code_block) @fold`     |
| Nested list item         | Yes     | `(list_item (list)) @fold`        |
| Flat list item           | No      | Not captured                      |
| List inside section      | Yes     | `(section (list) @fold)`          |
| Blockquote               | No      | Not captured (must add to custom) |
| Frontmatter (YAML `---`) | No      | `minus_metadata` not in query     |
| Frontmatter (TOML `+++`) | No      | `plus_metadata` not in query      |
| Paragraph                | No      | Never foldable                    |
| HTML block               | No      | Not captured                      |

### The `#trim!` Directive

Instructs the query engine to trim trailing whitespace/blank lines from the
node's range. This prevents folds from including trailing empty lines.

### Update Mechanism

**`on_changedtree`** (parser re-parses a region):
- Scheduled via `vim.schedule()` to avoid textlock issues.
- Recomputes fold levels only for changed regions (incremental).
- Calls `vim._foldupdate(win, srow, erow)` for every window displaying the buffer.

**`on_bytes`** (every text edit):
- Immediately shifts the cached `levels` arrays to keep them line-aligned.
- Schedules an async compute pass.

**Insert mode deferral**: If in insert mode, `foldupdate()` defers to
`InsertLeave` autocmd (Vim guards `foldUpdate()` in insert mode).

### `foldtext` Integration

**Transparent foldtext** (Neovim 0.10+): Setting `foldtext = ""` renders the
folded line using the buffer's actual content with all treesitter highlights
preserved:

```lua
vim.opt.foldtext = ""
vim.opt.fillchars = { fold = " " }
```

The collapsed fold looks like a normally highlighted heading line.

The old `vim.treesitter.foldtext()` function (PR #25391) was merged and then
reverted — it does NOT exist in Neovim 0.11+.

### Customization — Override Queries

To add blockquote or frontmatter folding, create:
`~/.config/nvim/after/queries/markdown/folds.scm`

```scheme
; extends
(block_quote) @fold
(minus_metadata) @fold
(plus_metadata) @fold
```

Without `; extends`, your file replaces the built-in query entirely.

### Known Bugs and Limitations

**A. Folds incorrectly closing on edit (Issue #32759, OPEN)**
When you close a fold with `za`, then edit text in a different fold, that other
fold may also close. Root cause: in `fold.c`, newly computed folds inherit state
from previous folds at the same position. Deferred treesitter updates cause
stale position mapping.

**B. `<C-c>` leaves stale folds (Fixed PR #29581)**
`<C-c>` exits insert mode without triggering `InsertLeave`. Folds become
temporarily stale after `<C-c>` but resync on next edit or `zx`.

**C. "E490: No Fold Found" when setting options globally (Issue #28692, OPEN)**
If `foldexpr` is set globally before a buffer has its filetype, treesitter
initializes before a parser is available. Fix: set in `FileType` autocmd or
`ftplugin`:
```lua
vim.wo[0][0].foldmethod = 'expr'
vim.wo[0][0].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
```

**D. Two folds starting on the same line — misrepresented**
The fold-expr interface cannot represent two folds opening on the same line.
This is a fundamental limitation of Vim's `foldexpr` interface.

**E. Injected languages not computed lazily**
Fold levels for injected languages (e.g., Python inside a markdown code block)
are computed upfront, not lazily as the window scrolls. Can impact performance
on large files with many injections.

**F. Performance**
- Fold levels are cached per buffer (not recomputed per `foldexpr()` call).
- Recomputation is incremental (only changed regions).
- On large files with many injected code blocks, initial computation can be expensive.
- `foldnestmax` (default 20) caps depth — setting to 4-6 reduces work.

---

## 2. Vim Built-in Fold Methods

### 2a. `foldmethod=indent`

**How it works:**
```
foldlevel = indent(line) / shiftwidth  (rounded down)
```

Lines with same or higher fold level form a single fold. Higher levels become
nested folds. Empty lines and lines starting with `foldignore` characters
borrow the fold level from surrounding context.

**Markdown applicability:**
Markdown's primary structure (headings) is zero-indented. This means:
- **Headings never fold** — they and their body paragraphs are all fold level 0
- **Nested list items** — indented items fold correctly
- **Indented code blocks** — 4-space blocks become fold level 1
- **Everything at column 0** — one undifferentiated level-0 mass

**Limitations:**
- Completely misses heading-based structure
- Blank lines between paragraphs don't separate folds (both sides are level 0)
- `shiftwidth` mismatch: if `shiftwidth=2` but lists use 4-space indent, fold
  levels don't match logical list levels
- Known bug (vim#3214): blank lines can cause incorrect fold boundaries

**Practical usability:** Poor for typical markdown. Only useful for
list-oriented documents where content is encoded in indentation depth.

### 2b. `foldmethod=syntax`

**How it works:**
Syntax folding is driven by `syn region` or `syn match` definitions that
include the `fold` argument. The fold level is determined by nesting depth of
fold-attributed syntax regions.

**Markdown applicability:**
**Produces ZERO folds.** Vim's built-in `runtime/syntax/markdown.vim` does NOT
include the `fold` argument on any syntax definition. The heading regions
(`markdownH1`, `markdownH2`, etc.) are for highlighting only. Pressing `za`
gives "E490: No fold found."

There is an important subtlety: `syntax/markdown.vim` preserves and restores
the buffer's existing `foldmethod` when it loads, to prevent embedded language
syntax files (e.g., JavaScript inside a code block) from overriding the user's
fold settings.

**Common confusion:** `g:markdown_folding = 1` enables `foldmethod=expr`, NOT
`foldmethod=syntax`. See section 3a.

**Practical usability:** Not useful. Requires custom `syn region ... fold`
definitions in `after/syntax/markdown.vim` to create any folds.

### 2c. `foldmethod=marker`

**How it works:**
Scans each line for literal `{{{` / `}}}` strings (configurable via
`foldmarker`). Numbered markers (`{{{1`, `{{{2}`) set explicit fold levels.

**Markdown applicability:**
Any content between markers becomes a fold:
```markdown
# Section One {{{1
Content here.

## Subsection {{{2
More content.

# Section Two {{{1
```

**The fundamental problem:** Markers appear literally in rendered output.
- `{{{1` shows up in HTML, PDF, and GitHub rendering
- Markdown has no comment syntax to hide them (unlike `// {{{` in code)
- If `commentstring` is set to `<!-- %s -->`, `zf` wraps markers as
  `<!-- {{{ -->`, which hides them from most renderers — but this is non-default

**Limitations:**
- Pollutes document text unless wrapped in HTML comments
- Markers are subject to undo/redo
- `zd` only removes the first marker on a line correctly
- No semantic relationship to markdown structure

**Practical usability:** Moderate for personal Vim-only notes. Non-starter for
files shared with others or rendered to HTML/PDF. The most persistent form of
folding (markers are in the file itself).

### 2d. `foldmethod=manual`

**How it works:**
No automatic determination. User explicitly defines every fold:
- `zf{motion}` — creates a fold (e.g., `zf3j`, `zfap`, `zf'a`)
- `V{motion}zf` — visual select then fold
- `:{range}fold` — ex command

Fold level is determined by nesting depth.

**Persistence via `:mkview` / `:loadview`:**
- `:mkview` writes a view file to `viewdir` (~/.local/share/nvim/view/)
- `:loadview` restores it
- Automate via `BufWinLeave`/`BufWinEnter` autocmds

**Limitations:**
- Ephemeral by default — lost when buffer is abandoned
- Fold boundaries tracked by line number; insertions/deletions above shift them
- `:loadview` after heavy editing produces incorrect fold positions
- No integration with markdown content structure
- Must be created individually

**Practical usability:** High for focused single-session work. Poor for
maintaining consistent fold structure across sessions. Useful for temporarily
hiding boilerplate during a writing session.

### 2e. `foldmethod=diff`

**How it works:**
Activated automatically in diff mode (`vimdiff`, `:diffthis`). Folds away all
lines identical between compared buffers, leaving only changed lines and
configurable context visible.

```vim
set diffopt=filler,context:6    " default: 6 lines of context
set diffopt=filler,context:0    " show only changed lines
```

**Markdown applicability:**
Content-agnostic — treats markdown as plain text. Folds based on line-by-line
equality, not semantic structure. All unchanged headings, paragraphs, and code
blocks between two versions collapse.

**Limitations:**
- Only meaningful in diff mode
- Manually setting `foldmethod=diff` outside diff mode makes entire buffer one fold
- `context:0` can fold too aggressively (vim#4005)
- Entering diff mode overrides previous `foldmethod`; leaving doesn't restore it
- Whitespace-only changes affect folding (controlled by `diffopt` flags)

**Practical usability:** Excellent for reviewing changes between document
versions. Not a general-purpose editing tool.

---

## 3. Expression-Based Folding (foldmethod=expr)

### 3a. `g:markdown_folding` (Vim Built-in ftplugin)

Vim/Neovim's `runtime/ftplugin/markdown.vim` contains opt-in folding gated
behind `g:markdown_folding = 1` (must be set BEFORE the ftplugin loads):

```vim
if has("folding") && get(g:, "markdown_folding", 0)
  setlocal foldexpr=MarkdownFold()
  setlocal foldmethod=expr
  setlocal foldtext=MarkdownFoldText()
endif
```

**The `MarkdownFold()` function:**
```vim
function! MarkdownFold() abort
  let line = getline(v:lnum)
  if line =~# '^#\+ ' && s:NotCodeBlock(v:lnum)
    return ">" . match(line, ' ')
  endif
  let nextline = getline(v:lnum + 1)
  if (line =~ '^.\+$') && (nextline =~ '^=\+$') && s:NotCodeBlock(v:lnum + 1)
    return ">1"
  endif
  if (line =~ '^.\+$') && (nextline =~ '^-\+$') && s:NotCodeBlock(v:lnum + 1)
    return ">2"
  endif
  return "="
endfunction
```

**What gets folded:** ATX headings, setext headings. Content under each heading
folds with its heading. Code blocks are explicitly excluded via `s:NotCodeBlock()`.

**What does NOT fold:** Fenced code blocks themselves, YAML frontmatter, lists,
blockquotes, paragraphs.

**Gotcha:** `g:markdown_folding` must be set before the ftplugin runs (in
`init.vim`/`init.lua`, NOT in `after/ftplugin/`).

**Practical usability:** Simplest option. Heading-only folding, no dependencies,
good performance. Add `au FileType markdown setlocal foldlevel=99` to start
with folds open.

---

## 4. Plugin-Based Folding

### 4a. preservim/vim-markdown

**Mechanism:** `foldmethod=expr` with `foldexpr=Foldexpr_markdown(v:lnum)`.
Two modes:

- **Default:** Heading-based, fold starts at heading line
- **Pythonic** (`g:vim_markdown_folding_style_pythonic = 1`): Headings fold in
  with content, collapsing shows only the heading

**What gets folded:** ATX headings, setext headings, fenced code blocks,
YAML frontmatter (with `g:vim_markdown_frontmatter = 1`), preamble content.

**Configuration:**
| Variable | Default | Effect |
|----------|---------|--------|
| `g:vim_markdown_folding_disabled` | 0 | Disable all folding |
| `g:vim_markdown_folding_style_pythonic` | 0 | Pythonic style |
| `g:vim_markdown_folding_level` | 1 | Initial foldlevel (pythonic only) |
| `g:vim_markdown_override_foldtext` | 1 | Override foldtext |
| `g:vim_markdown_frontmatter` | 0 | Enable YAML frontmatter folding |

**MAJOR LIMITATION — Performance:**
`Foldexpr_markdown` is called 107,000+ times during basic edits. On ~750 line
files with complex content, measured at ~15 seconds per edit (issues #162, #266).
Root cause: `foldmethod=expr` recalculates every line on every change.

**Mitigation:** Pair with FastFold (section 4f).

**Other issues:**
- Frontmatter closing `---` misrecognized as setext heading (#160)
- Pythonic mode level-1 headers may not fold (#262)

### 4b. masukomi/vim-markdown-folding

Originally by Drew Neil (Vimcasts). Uses `foldmethod=expr` with two modes:

- **`MarkdownFolds()`** — "Stacked" mode (default): each heading level folds
  independently, H2 and H3 appear as siblings
- **`NestedMarkdownFolds()`** — "Nested" mode: parent headings collapse
  subordinate sections

**What gets folded:** ATX headings, setext headings, fenced code blocks.
**NOT folded:** Frontmatter, lists.

**Commands:** `:FoldToggle` switches between stacked and nested mode.

**Limitations:**
- Folds open on save (bug #24)
- No frontmatter support
- No configuration options
- **Unmaintained** — actively seeking new maintainer

### 4c. kevinhwang91/nvim-ufo

A general-purpose fold enhancer (not markdown-specific). Core innovation: async
provider system that stores results in `foldmethod=manual`.

**Provider chain:**
1. **LSP** — calls `textDocument/foldingRange` (most markdown LSPs don't support this)
2. **Treesitter** — reads from `folds.scm` queries
3. **Indent** — fallback based on indentation

```lua
require('ufo').setup({
  provider_selector = function(bufnr, filetype, buftype)
    if filetype == 'markdown' then
      return { 'treesitter', 'indent' }
    end
    return { 'lsp', 'indent' }
  end,
})
```

**Distinctive features:**
- **Fold peek/preview:** floating window showing folded content without opening
- **`fold_virt_text_handler`:** callback controlling collapsed fold appearance
- **`close_fold_kinds_for_ft`:** auto-close specific fold types on buffer open:
  ```lua
  close_fold_kinds_for_ft = {
    markdown = { 'fenced_code_block' },
  }
  ```

**Configuration requirements:**
```lua
vim.o.foldlevel = 99          -- must be large; ufo manages this
vim.o.foldlevelstart = 99
vim.o.foldenable = true
-- Must remap zR/zM to ufo's functions
vim.keymap.set('n', 'zR', require('ufo').openAllFolds)
vim.keymap.set('n', 'zM', require('ufo').closeAllFolds)
```

**Limitations:**
- `foldlevel` must be large (99) or folds auto-close unexpectedly
- Native `zR`/`zM` must be remapped (they change `foldlevel`, breaking ufo)
- No markdown-specific logic — delegates entirely to provider
- Adds complexity over simple `foldexpr`

### 4d. jakewvincent/mkdnflow.nvim

Comprehensive markdown notebook plugin with a `folds` module (enabled by
default). Uses `foldmethod=expr` with Lua-based heading detection.

**Keymaps:**
- `<leader>f` — fold current section
- `<leader>F` — unfold current section
- `<CR>` on heading — toggle fold

**Rich foldtext customization:**
- Heading level indicator
- Object counts (tables, lists, code blocks) with configurable icons
- Line count and percentage through document
- Word count (optional)
- `title_transformer` function hook

**Limitations:**
- YAML frontmatter folding incomplete/pending
- Primarily a notebook tool — folding is one feature among many

### 4e. chimay/organ

Org-mode inspired plugin supporting Markdown, Org, and fold-marker formats.
Uses heading-level folding via `foldmethod=expr`. Supports "speed keys" —
single-key commands on heading first character — for fold cycling and subtree
operations.

Notable: full subtree operations (yank, delete, move subtrees), bringing
Org-mode outlining to markdown.

### 4f. Konfekt/FastFold (Performance Companion)

Not markdown-specific, but critical for any `foldmethod=expr` plugin. Prevents
Vim from recalculating folds on every text change. Folds recalculate only:
- When saving the buffer
- When explicitly opening/closing a fold (`zo`, `zc`, `za`, etc.)

```vim
let g:fastfold_foldmethods = ['syntax', 'expr']  " add 'expr' for markdown
```

Practical fix for preservim/vim-markdown performance issues.

---

## 5. LSP-Based Folding

### 5a. The Protocol

The `textDocument/foldingRange` request (LSP 3.10.0+) returns an array of
`FoldingRange` objects:

```typescript
interface FoldingRange {
  startLine: number;           // zero-based, inclusive
  startCharacter?: number;     // optional
  endLine: number;             // zero-based, inclusive
  endCharacter?: number;       // optional
  kind?: FoldingRangeKind;     // "comment", "imports", or "region"
  collapsedText?: string;      // since LSP 3.17.0
}
```

**Range semantics:** The range specifies content that gets hidden. It includes
the newline at end of `startLine`. For a heading fold, `startLine` is the
heading (stays visible), range covers through `endLine` (hidden).

**Client capabilities:**
```typescript
interface FoldingRangeClientCapabilities {
  rangeLimit?: number;           // max ranges (hint, default 5000)
  lineFoldingOnly?: boolean;     // only complete-line folding
  foldingRangeKind?: {
    valueSet?: FoldingRangeKind[];
  };
  foldingRange?: {
    collapsedText?: boolean;
  };
}
```

### 5b. VS Code's Markdown Language Service

**Repository:** microsoft/vscode-markdown-languageservice

The reference implementation. The `MdFoldingProvider` produces three categories:

1. **Region markers:** `<!-- #region -->` / `<!-- #endregion -->` (case-insensitive).
   Kind = `region`. Nesting via stack.

2. **Headings:** All ATX and setext headings. Hierarchy from TOC provider.
   `endLine` adjusted to exclude trailing blank lines. Kind = undefined.

3. **Block elements:**
   - `fence` — fenced code blocks
   - `list_item_open` — multi-line list items
   - `table_open` — tables
   - `blockquote_open` — blockquotes
   - `html_block` — HTML blocks (must span 2+ lines)

**NOT folded:** YAML/TOML frontmatter.

**Known limitation:** HTML blocks with blank lines inside (like `<details>` tags)
are split into separate tokens by markdown-it, making them unfoldable as a unit
(issue #119, still open).

### 5c. Other Markdown LSPs

| Server | Folding Support | Notes |
|--------|----------------|-------|
| **Marksman** | **No** | No `foldingRangeProvider` in capabilities |
| **markdown-oxide** | **No** | PKM-focused, no folding |
| **remark-language-server** | **No** | Lint/format only |
| **common-mark-language-server** | Yes (limited) | Proof-of-concept, not production-ready |
| **ltex-ls** | **No** | Grammar/spell checking only |

**Practical implication:** Since Marksman (the most popular Neovim markdown LSP)
does not support `foldingRange`, LSP-based markdown folding is effectively
unavailable in typical Neovim setups. Treesitter is the practical alternative.

### 5d. Neovim's Native LSP Folding (0.11+)

**PR #31311** (merged Nov 2024) added native support:

```lua
vim.o.foldmethod = 'expr'
vim.o.foldexpr = 'v:lua.vim.lsp.foldexpr()'
```

Three functions:
- **`vim.lsp.foldexpr()`** — queries all attached LSP clients with `foldingRange`
  support, merges results
- **`vim.lsp.foldtext()`** — displays `collapsedText` from server
- **`vim.lsp.foldclose(kind, winid)`** — closes all folds of a specific kind

**Recommended pattern with fallback:**
```lua
vim.o.foldmethod = 'expr'
vim.o.foldexpr = 'v:lua.vim.treesitter.foldexpr()'  -- default

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client:supports_method('textDocument/foldingRange') then
      local win = vim.api.nvim_get_current_win()
      vim.wo[win][0].foldexpr = 'v:lua.vim.lsp.foldexpr()'
    end
  end,
})
```

**Default capabilities advertised:**
```lua
foldingRange = {
  dynamicRegistration = false,
  lineFoldingOnly = true,
  foldingRangeKind = { valueSet = { 'comment', 'imports', 'region' } },
  foldingRange = { collapsedText = true }
}
```

---

## 6. Your Current Configuration

Your Neovim config uses a sophisticated multi-layered approach:

### Core Settings (ftplugin/markdown.lua)
```lua
vim.wo.foldmethod = "expr"
vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.wo.foldlevel = 99
vim.wo.foldcolumn = "1"
vim.wo.foldenable = true
vim.wo.foldtext = "v:lua.MarkdownFoldText()"

function MarkdownFoldText()
  local first = vim.fn.getline(vim.v.foldstart)
  local count = vim.v.foldend - vim.v.foldstart
  return first .. " (" .. count .. " lines)"
end
```

### Custom Treesitter Query (queries/markdown/folds.scm)
```scheme
; extends
(block_quote) @fold
```
Adds blockquotes as foldable regions on top of the defaults.

### Keymaps
| Key | Action | Purpose |
|-----|--------|---------|
| `<Tab>` | `za` | Toggle fold under cursor |
| `<leader>mf` | `zM` | Fold all |
| `<leader>mu` | `zR` | Unfold all |
| `<leader>ml` | Set fold level (1-6) | Prompted input |
| `zd`, `zD`, `zE`, `zf`, `zF` | `<Nop>` | Disabled (not applicable with expr) |

### Callout Collapse System (render-markdown.lua + callout_folds.lua)

A sophisticated system for Obsidian-style collapsible callouts:

**Dynamic fold method switching:**
1. On `BufWinEnter`/`BufRead`: switches to `foldmethod=expr`, recomputes
   treesitter folds via `zx`
2. Freezes folds with `foldmethod=manual` for programmatic control
3. Applies callout-specific fold states based on suffix (`-` collapsed, `+` expanded)

**Persistence:** Stores toggle states in `.vault-callout-folds.json` using
content fingerprinting (`TYPE|title|content_hash`) for content-based matching
across edits.

**Commands:**
| Command | Purpose |
|---------|---------|
| `:VaultFoldClear` | Clear callout fold cache (current file) |
| `:VaultFoldClear!` | Clear all callout fold states |
| `:VaultFoldDebug` | Show cached fold states |
| `<leader>mz` | Toggle callout fold |
| `<leader>mZ` | Clear callout fold cache (current file) |

---

## 7. Master Comparison Table

| Method | Fold Source | Headings | Code Blocks | Lists | Blockquotes | Frontmatter | Performance | Persistence |
|--------|-----------|----------|-------------|-------|-------------|-------------|-------------|-------------|
| **Treesitter (native)** | `folds.scm` query | Yes (nested sections) | Yes | Nested only | No (custom query needed) | No (custom query needed) | Excellent (cached) | Session |
| **indent** | Whitespace depth | No | Indented only | If indented | No | No | Excellent | Session |
| **syntax** | Syntax `fold` arg | No (not defined) | No | No | No | No | N/A | N/A |
| **marker** | `{{{`/`}}}` in file | If markers added | If markers added | If markers added | If markers added | If markers added | Excellent | In-file |
| **manual** | User commands | User-defined | User-defined | User-defined | User-defined | User-defined | Excellent | mkview |
| **diff** | Line equality | N/A (diff context) | N/A | N/A | N/A | N/A | Excellent | N/A |
| **g:markdown_folding** | Heading regex | Yes | No | No | No | No | Good | Session |
| **preservim/vim-markdown** | Heading regex + state | Yes | Yes | No | No | Yes (buggy) | **Poor** | Session |
| **masukomi/vim-markdown-folding** | Heading regex | Yes (stacked/nested) | Yes | No | No | No | Good | Session |
| **nvim-ufo** | Provider chain | Via provider | Via provider | Via provider | Via provider | Via provider | Excellent (async) | Session |
| **mkdnflow.nvim** | Heading regex (Lua) | Yes | Unknown | No | No | Pending | Good | Session |
| **LSP (VS Code service)** | AST analysis | Yes (hierarchical) | Yes | Multi-line only | Yes | No | Good | Session |
| **LSP (Marksman)** | N/A | **Not supported** | N/A | N/A | N/A | N/A | N/A | N/A |

### Recommendation Summary

| Use Case | Best Method |
|----------|-------------|
| Neovim with treesitter (2025 standard) | `vim.treesitter.foldexpr()` + custom `folds.scm` |
| Rich fold UI + peek + async | nvim-ufo with treesitter provider |
| Minimal/no plugins (Vim or Neovim) | `g:markdown_folding = 1` |
| Vim without treesitter | masukomi/vim-markdown-folding (nested mode) |
| Diff review | `foldmethod=diff` (automatic in vimdiff) |
| Obsidian-style callouts | Custom system (as in your config) |
| VS Code | Built-in markdown language features (automatic) |

---

## Sources

### Neovim/Treesitter
- [neovim/neovim - runtime/lua/vim/treesitter/_fold.lua](https://github.com/neovim/neovim)
- [nvim-treesitter/nvim-treesitter - queries/markdown/folds.scm](https://github.com/nvim-treesitter/nvim-treesitter)
- [tree-sitter-grammars/tree-sitter-markdown](https://github.com/tree-sitter-grammars/tree-sitter-markdown)
- [Issue #32759: Folds incorrectly closing on edit](https://github.com/neovim/neovim/issues/32759)
- [Issue #28692: E490 with global foldexpr](https://github.com/neovim/neovim/issues/28692)
- [PR #31311: Native LSP foldingRange](https://github.com/neovim/neovim/pull/31311)
- [PR #29581: Ctrl-C foldexpr fix](https://github.com/neovim/neovim/pull/29581)
- [PR #20750: Transparent foldtext](https://github.com/neovim/neovim/pull/20750)
- [Discussion #34246: How to properly enable treesitter folds](https://github.com/neovim/neovim/discussions/34246)

### Plugins
- [preservim/vim-markdown](https://github.com/preservim/vim-markdown)
- [masukomi/vim-markdown-folding](https://github.com/masukomi/vim-markdown-folding)
- [kevinhwang91/nvim-ufo](https://github.com/kevinhwang91/nvim-ufo)
- [jakewvincent/mkdnflow.nvim](https://github.com/jakewvincent/mkdnflow.nvim)
- [chimay/organ](https://github.com/chimay/organ)
- [Konfekt/FastFold](https://github.com/Konfekt/FastFold)

### LSP
- [LSP 3.17 Specification — FoldingRange](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
- [microsoft/vscode-markdown-languageservice](https://github.com/microsoft/vscode-markdown-languageservice)
- [artempyanykh/marksman](https://github.com/artempyanykh/marksman)
- [Feel-ix-343/markdown-oxide](https://github.com/Feel-ix-343/markdown-oxide)

### Vim Documentation
- `:h fold.txt` — [vimhelp.org/fold.txt.html](https://vimhelp.org/fold.txt.html)
- `:h fold-indent`, `:h fold-syntax`, `:h fold-marker`, `:h fold-manual`, `:h fold-diff`
- [vim/vim - ftplugin/markdown.vim](https://github.com/vim/vim/blob/master/runtime/ftplugin/markdown.vim)
- [Cracking Neovim code folding - Jack Franklin](https://www.jackfranklin.co.uk/blog/code-folding-in-vim-neovim/)
- [Folding sections of Markdown in Vim - bitcrowd](https://bitcrowd.dev/folding-sections-of-markdown-in-vim/)
