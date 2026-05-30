# Neovim Keymaps — Complete Reference

> **Leader key:** `<Space>`
> **Which-key timeout:** 500ms — press `<Space>` and wait to see all available groups
> **Interactive search:** `<leader>fk` to fuzzy-search all keybindings

---

## Table of Contents

1. [Core Editor](#core-editor)
2. [Window & Split Management](#window--split-management)
3. [Tab Management](#tab-management)
4. [File Explorer (Yazi)](#file-explorer-yazi)
5. [Fuzzy Finder (fzf-lua)](#fuzzy-finder-fzf-lua)
6. [LSP — Language Server Protocol](#lsp--language-server-protocol)
7. [Completion (blink.cmp)](#completion-blinkcmp)
8. [Diagnostics & Trouble](#diagnostics--trouble)
9. [Git Integration (gitsigns)](#git-integration-gitsigns)
10. [Debugging (DAP)](#debugging-dap)
11. [Substitute](#substitute)
12. [Surround](#surround)
13. [Comments](#comments)
14. [TODO Comments](#todo-comments)
15. [Treesitter Context](#treesitter-context)
16. [Markdown Editing](#markdown-editing)
17. [LaTeX Editing](#latex-editing)
18. [TeX Motions & Text Objects](#tex-motions--text-objects)
19. [Rust Development (rustaceanvim)](#rust-development-rustaceanvim)
20. [Make / Build (Fortran)](#make--build-fortran)
21. [Linting](#linting)
22. [Type Checking](#type-checking)
23. [OpenCode AI](#opencode-ai)
24. [Terminal](#terminal)
25. [Table Mode](#table-mode)
26. [Vault — Templates](#vault--templates)
27. [Vault — Find & Search](#vault--find--search)
28. [Vault — Navigation](#vault--navigation)
29. [Vault — Wikilinks & Links](#vault--wikilinks--links)
30. [Vault — AutoLink](#vault--autolink)
31. [Vault — Tasks](#vault--tasks)
32. [Vault — Check & Validation](#vault--check--validation)
33. [Vault — Edit & Refactor](#vault--edit--refactor)
34. [Vault — Meta & Frontmatter](#vault--meta--frontmatter)
35. [Vault — Bookmarks & Pins](#vault--bookmarks--pins)
36. [Vault — Block IDs](#vault--block-ids)
37. [Vault — Graph & Tags](#vault--graph--tags)
38. [Vault — Sidebar](#vault--sidebar)
39. [Vault — Preview](#vault--preview)
40. [Vault — Capture & Utility](#vault--capture--utility)
41. [Vault — Calendar](#vault--calendar)
42. [Vault — Graph View (Buffer)](#vault--graph-view-buffer)
43. [Which-Key Group Prefixes](#which-key-group-prefixes)
44. [Formatting (Auto)](#formatting-auto)
45. [Source Files](#source-files)

---

## Core Editor

**File:** `lua/andrew/core/keymaps.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Insert | `jk` | `<ESC>` | Exit insert mode |
| Normal | `<leader>nh` | `:nohl` | Clear search highlighting |
| Normal | `<leader>+` | `<C-a>` | Increment number under cursor |
| Normal | `<leader>-` | `<C-x>` | Decrement number under cursor |

---

## Window & Split Management

**File:** `lua/andrew/core/keymaps.lua`, `lua/andrew/plugins/vim-maximizer.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>sv` | `<C-w>v` | Split window vertically |
| Normal | `<leader>sh` | `<C-w>s` | Split window horizontally |
| Normal | `<leader>se` | `<C-w>=` | Make all splits equal size |
| Normal | `<leader>sx` | `:close` | Close current split |
| Normal | `<leader>sm` | `:MaximizerToggle` | Maximize/minimize current split |

---

## Tab Management

**File:** `lua/andrew/core/keymaps.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>to` | `:tabnew` | Open new tab |
| Normal | `<leader>tx` | `:tabclose` | Close current tab |
| Normal | `<leader>tn` | `:tabn` | Go to next tab |
| Normal | `<leader>tp` | `:tabp` | Go to previous tab |
| Normal | `<leader>tf` | `:tabnew %` | Open current buffer in new tab |

---

## File Explorer (Yazi)

**File:** `lua/andrew/plugins/yazi.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>ee` | Open Yazi | Toggle file explorer |
| Normal | `<leader>ef` | Open Yazi at file | Open explorer on current file |
| Normal | `<leader>ec` | `:close` | Close explorer window |
| Normal | `<leader>er` | Open Yazi | Refresh explorer |

**Inside Yazi:**

| Key | Action |
|-----|--------|
| `<F1>` | Show help |
| `<C-s>` | Grep in directory / selected files |

---

## Fuzzy Finder (fzf-lua)

**File:** `lua/andrew/plugins/fzf-lua.lua`

### Launching Pickers

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>ff` | `fzf.files()` | Fuzzy find files in cwd |
| Normal | `<leader>fr` | `fzf.oldfiles()` | Find recently opened files |
| Normal | `<leader>vff` | Vault frecency | Find vault files (frecency-sorted) |
| Normal | `<leader>fs` | `fzf.live_grep()` | Live grep in cwd |
| Normal | `<leader>fc` | `fzf.grep_cword()` | Grep word under cursor |
| Normal | `<leader>fk` | `fzf.keymaps()` | Find keybindings |
| Normal | `<leader>fh` | `fzf.help_tags()` | Search `:help` tags |
| Normal | `<leader>fH` | Live grep in help docs | Grep Neovim `:help` documentation |
| Normal | `<leader>ft` | `:TodoFzfLua` | Find TODO/FIXME comments |

### Inside fzf Window

| Key | Action |
|-----|--------|
| `<C-n>` | Move down in results |
| `<C-p>` | Move up in results |
| `<C-j>` | Scroll preview down |
| `<C-k>` | Scroll preview up |
| `ctrl-q` | Select all + accept |

### File Picker Actions

| Key | Action |
|-----|--------|
| `<CR>` (Enter) | Open in current window |
| `<C-s>` | Open in horizontal split |
| `<C-v>` | Open in vertical split |
| `<C-t>` | Open in new tab |
| `<C-q>` | Send to quickfix list |

---

## LSP — Language Server Protocol

**File:** `lua/andrew/plugins/lsp/lspconfig.lua`

### Navigation

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `gd` | fzf-lua definitions | Go to definition(s) |
| Normal | `gD` | Declaration / fallback | Go to declaration |
| Normal | `gR` | fzf-lua references | Show references |
| Normal | `gi` | fzf-lua implementations | Show implementations |
| Normal | `gt` | fzf-lua typedefs | Show type definitions |

### Documentation & Diagnostics

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `K` | Hover (with Fortran fallback) | Show documentation under cursor |
| Normal, Insert | `<C-k>` | Signature help | Show function signature help |
| Normal | `<leader>D` | fzf-lua diagnostics | Show buffer diagnostics |
| Normal | `<leader>d` | `diagnostic.open_float` | Show line diagnostics (float) |
| Normal | `[d` | Previous diagnostic | Jump to previous diagnostic |
| Normal | `]d` | Next diagnostic | Jump to next diagnostic |

### Code Actions

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal, Visual | `<leader>ca` | `lsp.buf.code_action` | See available code actions |
| Normal | `<leader>rn` | `lsp.buf.rename` | Smart rename symbol |
| Normal | `<leader>rs` | `:LspRestart` | Restart LSP server |

---

## Completion (blink.cmp)

**File:** `lua/andrew/plugins/blink-cmp.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Insert | `<C-n>` | Select next | Navigate down in completion menu |
| Insert | `<C-p>` | Select previous | Navigate up in completion menu |
| Insert | `<C-j>` | Scroll doc down | Scroll documentation down |
| Insert | `<C-k>` | Scroll doc up | Scroll documentation up |
| Insert | `<C-Space>` | Show menu | Trigger completion |
| Insert | `<C-e>` | Hide menu | Close completion menu |
| Insert | `<CR>` | Accept | Accept selected completion |

**Completion sources by filetype:**

- **Markdown (vault):** wikilinks, vault_tags, vault_frontmatter, vault_inline_fields, lsp, snippets, path, buffer, spell
- **Fortran:** fortran_docs, lsp, snippets, path, buffer
- **Other:** lsp, snippets, path, buffer

---

## Diagnostics & Trouble

**File:** `lua/andrew/plugins/trouble.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>xw` | Trouble preview_float | Workspace diagnostics (floating) |
| Normal | `<leader>xd` | Trouble filter buf=0 | Current file diagnostics |
| Normal | `<leader>xe` | Trouble errors buf=0 | Errors only (current file) |
| Normal | `<leader>xE` | Trouble errors workspace | Errors only (workspace) |
| Normal | `<leader>xq` | Trouble quickfix | Toggle quickfix list |
| Normal | `<leader>xl` | Trouble loclist | Toggle location list |
| Normal | `<leader>xt` | Trouble todo | Open TODO comments |
| Normal | `<leader>xf` | Trouble fzf | fzf-lua results in Trouble |
| Normal | `<leader>xF` | Trouble fzf_files | fzf-lua file results in Trouble |

---

## Git Integration (gitsigns)

**File:** `lua/andrew/plugins/gitsigns.lua`

### Navigation

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `]g` | Next hunk | Jump to next git hunk |
| Normal | `[g` | Previous hunk | Jump to previous git hunk |

### Hunk Actions

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>hs` | Stage hunk | Stage current hunk |
| Visual | `<leader>hs` | Stage hunk (range) | Stage selected hunk |
| Normal | `<leader>hr` | Reset hunk | Reset current hunk |
| Visual | `<leader>hr` | Reset hunk (range) | Reset selected hunk |
| Normal | `<leader>hS` | Stage buffer | Stage entire buffer |
| Normal | `<leader>hR` | Reset buffer | Reset entire buffer |
| Normal | `<leader>hu` | Undo stage hunk | Undo last stage hunk |
| Normal | `<leader>hp` | Preview hunk | Preview hunk changes |

### Blame & Diff

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>hb` | Blame line (full) | Show full blame for line |
| Normal | `<leader>hB` | Toggle line blame | Toggle inline blame |
| Normal | `<leader>hd` | Diff this | Diff against index |
| Normal | `<leader>hD` | Diff this ~ | Diff against previous commit |

### Text Object

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Operator, Visual | `ih` | Select hunk | Select git hunk as text object |

---

## Debugging (DAP)

**Files:** `lua/andrew/plugins/dap/dap.lua`, `lua/andrew/plugins/dap/dap-ui.lua`

### Breakpoints & Flow

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>db` | Toggle breakpoint | Toggle breakpoint at cursor |
| Normal | `<leader>dB` | Conditional breakpoint | Set breakpoint with condition |
| Normal | `<leader>dc` | Continue | Start/continue debugging |
| Normal | `<leader>do` | Step over | Step over current line |
| Normal | `<leader>di` | Step into | Step into function |
| Normal | `<leader>dO` | Step out | Step out of function |
| Normal | `<leader>dC` | Run to cursor | Run to cursor position |
| Normal | `<leader>dt` | Terminate | Terminate debug session |
| Normal | `<leader>dr` | Restart | Restart debug session |
| Normal | `<leader>dR` | Toggle REPL | Toggle debug REPL |

### DAP UI

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>du` | Toggle UI | Toggle DAP UI panels |
| Normal, Visual | `<leader>de` | Evaluate | Evaluate expression |
| Normal | `<leader>df` | Float element | Show floating element |

---

## Substitute

**File:** `lua/andrew/plugins/substitute.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `s{motion}` | Substitute operator | Substitute with motion (e.g., `siw` = substitute inner word) |
| Normal | `ss` | Substitute line | Substitute entire line |
| Normal | `S` | Substitute EOL | Substitute to end of line |
| Visual | `s` | Substitute visual | Substitute selection |

---

## Surround

**File:** `lua/andrew/plugins/surround.lua`

Standard nvim-surround operations plus custom LaTeX surrounds:

| Operation | Keys | Example | Result |
|-----------|------|---------|--------|
| Add surround | `ys{motion}{char}` | `ysiw"` | Wrap word in `"..."` |
| Add surround (line) | `yss{char}` | `yss)` | Wrap line in `(...)` |
| Delete surround | `ds{char}` | `ds"` | Remove surrounding `"` |
| Change surround | `cs{old}{new}` | `cs"'` | Change `"..."` to `'...'` |
| Visual surround | `S{char}` (in visual) | `viwS"` | Wrap selection in `"..."` |

**Custom LaTeX surrounds:**

| Char | Result | Example |
|------|--------|---------|
| `e` | `\begin{env}...\end{env}` | `ysiwe` wraps word in environment |
| `c` | `\cmd{...}` | `ysiwc` wraps word in command |

---

## Comments

**File:** `lua/andrew/plugins/comment.lua`

Uses Comment.nvim defaults with tree-sitter integration:

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `gcc` | Toggle line comment | Comment/uncomment current line |
| Normal | `gc{motion}` | Toggle comment | Comment/uncomment with motion |
| Visual | `gc` | Toggle comment | Comment/uncomment selection |
| Normal | `gbc` | Toggle block comment | Block comment current line |
| Visual | `gb` | Toggle block comment | Block comment selection |

---

## TODO Comments

**File:** `lua/andrew/plugins/todo-comments.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `]t` | Next TODO | Jump to next TODO/FIXME comment |
| Normal | `[t` | Previous TODO | Jump to previous TODO/FIXME comment |

---

## Treesitter Context

**File:** `lua/andrew/plugins/treesitter-context.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `[c` | Go to context | Jump to parent scope context |

---

## Markdown Editing

**File:** `ftplugin/markdown.lua`

### Folding

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<Tab>` | Smart fold toggle | Toggle fold (callout-aware on callout headers) |
| Normal | `za` | Standard fold toggle | Toggle fold |
| Normal | `<leader>mf` | `zM` | Fold all |
| Normal | `<leader>mu` | `zR` | Unfold all |
| Normal | `<leader>ml` | Prompt | Set fold level (interactive) |

> **Note:** `zd`, `zD`, `zE`, `zf`, `zF` are disabled (expr foldmethod)

### Heading Navigation

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `]h` | Next heading (any level) |
| Normal | `[h` | Previous heading (any level) |
| Normal | `]1` through `]6` | Next heading of level 1-6 |
| Normal | `[1` through `[6` | Previous heading of level 1-6 |

### Inline Formatting

| Mode | Key | Description |
|------|-----|-------------|
| Normal, Visual | `<leader>mb` | Toggle **bold** |
| Normal, Visual | `<leader>mi` | Toggle *italic* |
| Normal, Visual | `<leader>ms` | Toggle ~~strikethrough~~ |
| Normal, Visual | `<leader>mc` | Toggle `inline code` |

### Links

| Mode | Key | Description |
|------|-----|-------------|
| Visual | `<leader>mk` | Create `[text](url)` link |
| Visual | `<leader>mK` | Create `[[wikilink]]` |
| Normal, Visual | `<leader>mP` | Paste clipboard as link |

### Headings

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>m1` through `<leader>m6` | Toggle heading level 1-6 |

### Blockquotes & Callouts

| Mode | Key | Description |
|------|-----|-------------|
| Normal, Visual | `<leader>mq` | Add blockquote level |
| Normal, Visual | `<leader>mQ` | Remove blockquote level |
| Normal, Visual | `<leader>mC` | Create callout (interactive type selection) |
| Normal | `<leader>mz` | Toggle callout fold |
| Normal | `<leader>mZ` | Clear callout fold cache (file) |

### Tasks & Media

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>mx` | Cycle checkbox forward |
| Normal | `<leader>mp` | Paste clipboard image |
| Normal | `<leader>mS` | Toggle spell checking |

### Footnotes

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>mj` | Jump between footnote ref/def |
| Normal | `<leader>mn` | List all footnotes |

### Tables

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>Tc` | Create table (interactive) |
| Normal | `<leader>Tir` | Insert table row below |
| Normal | `<leader>Tdt` | Delete entire table |

### Smart List Continuation

| Mode | Key | Description |
|------|-----|-------------|
| Insert | `<CR>` | Smart list continuation (auto-bullet/number) |
| Normal | `o` | Smart new line with list continuation |
| Normal | `O` | Smart new line above with list continuation |

### Spell Navigation (Builtin)

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `]s` | Next misspelling |
| Normal | `[s` | Previous misspelling |
| Normal | `z=` | Spell suggestions |
| Normal | `zg` | Add word to spellfile |
| Normal | `zw` | Mark word as bad |
| Normal | `zug` | Undo add to spellfile |

---

## LaTeX Editing

**File:** `ftplugin/tex.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `j` | `gj` | Move down (visual line, wrapping-aware) |
| Normal | `k` | `gk` | Move up (visual line, wrapping-aware) |
| Normal | `<Tab>` | `za` | Toggle fold |
| Normal | `<leader>mf` | `zM` | Fold all |
| Normal | `<leader>mu` | `zR` | Unfold all |

> **Note:** `zd`, `zD`, `zE`, `zf`, `zF` are disabled (expr foldmethod)

---

## TeX Motions & Text Objects

**File:** `lua/andrew/utils/tex-motions.lua`

Works in both LaTeX and Markdown buffers with embedded math.

### Motions

| Mode | Key | Description |
|------|-----|-------------|
| Normal, Visual, Operator | `]]` | Next section |
| Normal, Visual, Operator | `[[` | Previous section |
| Normal, Visual, Operator | `]e` | Next environment |
| Normal, Visual, Operator | `[e` | Previous environment |
| Normal, Visual, Operator | `]m` | Next math zone |
| Normal, Visual, Operator | `[m` | Previous math zone |

### Text Objects

| Mode | Key | Description |
|------|-----|-------------|
| Visual, Operator | `ae` | Around environment |
| Visual, Operator | `ie` | Inside environment |
| Visual, Operator | `am` | Around math zone |
| Visual, Operator | `im` | Inside math zone |
| Visual, Operator | `ac` | Around command |
| Visual, Operator | `ic` | Inside command |

---

## Rust Development (rustaceanvim)

**File:** `lua/andrew/plugins/rustaceanvim.lua`

Only active in Rust buffers.

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>ca` | `RustLsp codeAction` | Rust code actions |
| Normal | `K` | `RustLsp hover actions` | Rust hover with actions |
| Normal | `J` | `RustLsp joinLines` | Rust-aware join lines |
| Normal | `<leader>rr` | `RustLsp runnables` | Run binary/example |
| Normal | `<leader>rd` | `RustLsp debuggables` | Run debuggables |
| Normal | `<leader>rt` | `RustLsp testables` | Run tests |
| Normal | `<leader>rm` | `RustLsp expandMacro` | Expand macro |
| Normal | `<leader>rc` | `RustLsp openCargo` | Open Cargo.toml |
| Normal | `<leader>rp` | `RustLsp parentModule` | Go to parent module |
| Normal | `<leader>re` | `RustLsp explainError` | Explain error |
| Normal | `<leader>rD` | `RustLsp renderDiagnostic` | Render diagnostics |
| Normal | `<leader>dt` | `RustLsp testables` | Debug testables (DAP) |

---

## Make / Build (Fortran)

**File:** `lua/andrew/plugins/fortran-build.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>mb` | Pick Makefile, run default | Make: Build |
| Normal | `<leader>md` | Pick Makefile, run debug | Make: Build Debug |
| Normal | `<leader>mc` | Pick Makefile, run clean | Make: Clean |
| Normal | `<leader>mr` | Pick Makefile, run target | Make: Run |
| Normal | `<leader>ma` | Pick Makefile, run all | Make: All |
| Normal | `<leader>ml` | Re-run last Makefile | Make: Re-run last |

> **Note:** In Markdown buffers, `<leader>m` is overridden to Markdown editing commands.

---

## Linting

**File:** `lua/andrew/plugins/linting.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>ll` | `lint.try_lint()` | Lint current buffer |
| Normal | `<leader>lm` | `lint.try_lint("ruff")` | Lint with ruff (Python) |
| Normal | `<leader>lf` | Toggle Fortran linter | Toggle Fortran linter compiler |
| Normal | `<leader>lF` | Debug Fortran linter | Run Fortran linter (verbose) |
| Normal | `<leader>lw` | Lint Fortran workspace | Lint entire Fortran workspace |
| Normal | `<leader>lW` | Clear diagnostics | Clear workspace diagnostics |

---

## Type Checking

**File:** `lua/andrew/plugins/type-checker.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>ac` | `:TypeCheck` | Type check (dispatch by filetype) |
| Normal | `<leader>aP` | Python (ruff check) | Python type check |
| Normal | `<leader>aT` | Python (ty) | Ty type check |
| Normal | `<leader>aR` | Rust (cargo check) | Rust type check |
| Normal | `<leader>aL` | Lua (lua-language-server) | Lua type check |
| Normal | `<leader>aF` | Fortran (current) | Fortran type check |
| Normal | `<leader>aC` | C/C++ | C/C++ syntax & warnings |
| Normal | `<leader>ag` | Fortran (mpif90/gfortran) | Fortran: gfortran |
| Normal | `<leader>ai` | Fortran (mpiifx/Intel) | Fortran: Intel |
| Normal | `<leader>at` | Toggle compiler | Toggle Fortran type checker |

---

## OpenCode AI

**File:** `lua/andrew/plugins/opencode.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>ot` | `opencode.toggle()` | Toggle OpenCode panel |
| Normal | `<leader>oa` | Ask about cursor | Ask OpenCode about code at cursor |
| Visual | `<leader>oa` | Ask about selection | Ask OpenCode about selected code |
| Normal | `<leader>o+` | Add buffer to prompt | Add current buffer to OpenCode prompt |
| Visual | `<leader>o+` | Add selection to prompt | Add selection to OpenCode prompt |
| Normal | `<leader>oe` | Explain cursor | Explain code at cursor |
| Normal | `<leader>on` | New session | Create new OpenCode session |
| Normal, Visual | `<leader>os` | Select prompt | Select OpenCode prompt |
| Normal | `<S-C-u>` | Scroll up | Scroll OpenCode messages up |
| Normal | `<S-C-d>` | Scroll down | Scroll OpenCode messages down |

---

## Terminal

**File:** `lua/andrew/custom/plugins/terminal.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>tt` | Toggle | Toggle floating terminal |
| Terminal | `<C-\><C-n>` | Normal mode | Exit terminal mode |
| Terminal | `jk` | Normal mode | Exit terminal mode (alias) |

---

## Table Mode

**File:** `lua/andrew/plugins/vim-table-mode.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| Normal | `<leader>Tm` | Toggle | Toggle table mode on/off |

While table mode is active:
- `|` auto-creates table structure
- `Tab` moves to next cell
- `||` creates horizontal separator

---

## Vault — Templates

**File:** `lua/andrew/vault/init.lua`

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vtn` | Template: picker (choose any template) |
| Normal | `<leader>vtd` | Create daily log |
| Normal | `<leader>vtw` | Create weekly review |
| Normal | `<leader>vts` | Create simulation note |
| Normal | `<leader>vta` | Create analysis note |
| Normal | `<leader>vtk` | Create task note |
| Normal | `<leader>vtm` | Create meeting note |
| Normal | `<leader>vtf` | Create finding note |
| Normal | `<leader>vtl` | Create literature note |
| Normal | `<leader>vtp` | Create project dashboard |
| Normal | `<leader>vtj` | Create journal entry |
| Normal | `<leader>vtc` | Create concept note |
| Normal | `<leader>vtM` | Create monthly review |
| Normal | `<leader>vtQ` | Create quarterly review |
| Normal | `<leader>vtY` | Create yearly review |

---

## Vault — Find & Search

**Files:** `lua/andrew/vault/search.lua`, `lua/andrew/vault/navigate.lua`, `lua/andrew/vault/backlinks.lua`, `lua/andrew/vault/outline.lua`, `lua/andrew/vault/recent.lua`, `lua/andrew/vault/pickers.lua`

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vfs` | Search vault (live grep all) |
| Normal | `<leader>vfn` | Search notes (markdown only) |
| Normal | `<leader>vfD` | Search filtered (scope by directory) |
| Normal | `<leader>vfy` | Search by type (frontmatter type) |
| Normal | `<leader>vfA` | Advanced search (live) |
| Normal | `<leader>vfH` | Search history |
| Normal | `<leader>vfS` | Saved searches |
| Normal | `<leader>vff` | Find files (frecency-sorted) |
| Normal | `<leader>vfo` | Outline (headings) |
| Normal | `<leader>vfr` | Recent notes (frecency) |
| Normal | `<leader>vfp` | Pick project dashboard |
| Normal | `<leader>vfb` | Backlinks to current note |
| Normal | `<leader>vfl` | Forward links from current note |
| Normal | `<leader>vfh` | Heading backlinks |
| Normal | `<leader>vfu` | Unlinked mentions (buffer) |
| Normal | `<leader>vfU` | Unlinked mentions (vault) |
| Normal | `<leader>vfd` | Daily log list |
| Normal | `<leader>vfw` | Weekly review list |
| Normal | `<leader>vfW` | All reviews list |
| Normal | `<leader>vft` | Find by tag |
| Normal | `<leader>vfT` | Find by tag (hierarchical) |
| Normal | `<leader>vfF` | Find inline fields |

---

## Vault — Navigation

**File:** `lua/andrew/vault/navigate.lua`, `lua/andrew/vault/wikilinks.lua`

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>v[` | Previous daily log |
| Normal | `<leader>v]` | Next daily log |
| Normal | `<leader>v{` | Previous weekly review |
| Normal | `<leader>v}` | Next weekly review |
| Normal | `<leader>vC` | Calendar view |
| Normal | `<leader>vdc` | Carry forward tasks to daily log |

---

## Vault — Wikilinks & Links

**File:** `lua/andrew/vault/wikilinks.lua`

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `gf` | Follow link (wiki/markdown/URL) |
| Normal | `gx` | Open link in browser or follow |
| Normal | `]o` | Jump to next link in buffer |
| Normal | `[o` | Jump to previous link in buffer |

---

## Vault — AutoLink

**File:** `lua/andrew/vault/autolink.lua`

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>va` | Toggle autolink suggestions |
| Normal | `<leader>vA` | Accept autolink suggestion at cursor |
| Normal | `<leader>vgA` | Accept autolink for entire line |
| Normal | `<leader>vaB` | Auto-link entire buffer |
| Normal | `<leader>vaV` | Auto-link entire vault |

---

## Vault — Tasks

**Files:** `lua/andrew/vault/quicktask.lua`, `lua/andrew/vault/task_notify.lua`, `lua/andrew/vault/task_hierarchy.lua`

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vxq` | Quick task creation |
| Normal | `<leader>vxd` | List overdue tasks |
| Normal | `<leader>vxh` | Task hierarchy tree |
| Normal | `<leader>vxo` | Open tasks |
| Normal | `<leader>vxa` | All tasks |
| Normal | `<leader>vxs` | Tasks by state |
| Normal | `<leader>vxt` | Cycle task state forward |
| Normal | `<leader>vxT` | Cycle task state backward |
| Normal | `<leader>vxk` | Kanban board |
| Normal | `<leader>vxl` | Task timeline |

---

## Vault — Check & Validation

**File:** `lua/andrew/vault/` (multiple modules)

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vcb` | Check links (buffer) |
| Normal | `<leader>vca` | Check links (vault) |
| Normal | `<leader>vco` | Check orphans |
| Normal | `<leader>vcu` | Check URLs (buffer) |
| Normal | `<leader>vcU` | Check URLs (vault) |
| Normal | `<leader>vcr` | Repair broken links (buffer) |
| Normal | `<leader>vcR` | Repair broken links (vault) |
| Normal | `<leader>vcd` | Toggle link diagnostics |
| Normal | `<leader>vch` | Toggle wikilink highlights |
| Normal | `<leader>vcf` | Code action (fix link) |
| Normal | `<leader>vcF` | Fix all links in buffer |

---

## Vault — Edit & Refactor

**File:** `lua/andrew/vault/` (multiple modules)

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>ver` | Rename note (with link updates) |
| Normal | `<leader>veR` | Preview rename (dry-run) |
| Normal | `<leader>vet` | Rename tag |
| Visual | `<leader>vex` | Extract selection to new note |
| Normal | `<leader>vep` | Export via pandoc |
| Normal | `<leader>vE` | Edit link in float editor |
| Normal | `<leader>vmv` | Move file with vault awareness |

---

## Vault — Meta & Frontmatter

**File:** `lua/andrew/vault/` (multiple modules)

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vms` | Cycle status field |
| Normal | `<leader>vmp` | Cycle priority field |
| Normal | `<leader>vmm` | Cycle maturity field |
| Normal | `<leader>vmt` | Toggle draft field |
| Normal | `<leader>vmf` | Set any frontmatter field |
| Normal | `<leader>vM` | Open frontmatter editor |

---

## Vault — Bookmarks & Pins

**File:** `lua/andrew/vault/` (multiple modules)

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vbp` | Toggle pin on current note |
| Normal | `<leader>vbf` | Find pinned notes |

---

## Vault — Block IDs

**File:** `lua/andrew/vault/blockid.lua`

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vki` | Generate block ID |
| Normal | `<leader>vkl` | Generate block ID + link in target |

---

## Vault — Graph & Tags

**File:** `lua/andrew/vault/` (multiple modules)

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vgt` | Toggle tag highlights |
| Normal | `<leader>vga` | Show all tags |
| Normal | `<leader>vgr` | Show tag relationship graph |
| Normal | `<leader>vG` | Open local graph |
| Normal | `<leader>vr` | Show related notes |
| Normal | `]t` | Next tag |
| Normal | `[t` | Previous tag |

---

## Vault — Sidebar

**File:** `lua/andrew/vault/sidebar.lua`

### Opening

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vS` | Toggle sidebar |
| Normal | `<leader>vSf` | Toggle sidebar focus |
| Normal | `<leader>vSb` | Open sidebar backlinks panel |
| Normal | `<leader>vSt` | Open sidebar tags panel |
| Normal | `<leader>vSm` | Open sidebar meta panel |

### Inside Sidebar

| Key | Description |
|-----|-------------|
| `q` | Close sidebar |
| `<Esc>` | Return focus to editor |
| `1`-`9` or first letter | Switch panel |
| `<Tab>` | Cycle to next panel |
| `<S-Tab>` | Cycle to previous panel |
| `R` | Refresh sidebar |
| `?` | Show help |

### Sidebar: Backlinks Panel

| Key | Description |
|-----|-------------|
| `<CR>` | Jump to backlink source |
| `o` | Open in horizontal split |
| `v` | Open in vertical split |

### Sidebar: Tags Panel

| Key | Description |
|-----|-------------|
| `<CR>` | Search notes with this tag |
| `<Space>` or `l` | Toggle expand/collapse |

### Sidebar: Meta Panel

| Key | Description |
|-----|-------------|
| `<CR>` | Edit field under cursor |
| `a` | Add new frontmatter field |
| `dd` | Delete frontmatter field |
| `j` / `<Down>` / `<Tab>` | Next field |
| `k` / `<Up>` / `<S-Tab>` | Previous field |
| `l` | Edit field value |
| `q` / `<Esc>` | Close editor |

---

## Vault — Preview

**File:** `lua/andrew/vault/preview.lua`

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `K` | Preview link under cursor |
| Normal | `<C-j>` | Scroll preview down |
| Normal | `<C-k>` | Scroll preview up |
| Normal | `<C-o>` | Open link in new split |
| Normal | `<C-i>` | Open link in new vsplit |
| Normal | `<BS>` | Return to parent |
| Normal | `gf` | Follow link in preview |
| Normal | `q` | Close preview (return focus) |
| Normal | `<C-h>` | Return focus to editor |
| Normal | `<CR>` | Follow link in current window |

---

## Vault — Capture & Utility

**File:** `lua/andrew/vault/` (multiple modules)

| Mode | Key | Description |
|------|-----|-------------|
| Normal | `<leader>vQ` | Quick capture to daily log |
| Normal | `<leader>vi` | Capture to inbox |
| Normal | `<leader>vI` | Insert fragment |
| Normal | `<leader>vD` | Vault statistics dashboard |
| Normal | `<leader>vW` | Toggle autosave |
| Normal | `<leader>vP` | Show/set sticky project |
| Normal | `<leader>vV` | Switch vault |
| Normal | `<leader>vp` | Image picker |
| Normal | `<leader>v?` | Command palette |

---

## Vault — Calendar

Local keymaps inside calendar view:

| Key | Description |
|-----|-------------|
| `<CR>` | Open selected day |
| `l` | Shift month forward |
| `h` | Shift month backward |
| `L` | Shift year forward |
| `H` | Shift year backward |
| `j` | Move down week |
| `k` | Move up week |

---

## Vault — Graph View (Buffer)

Local keymaps inside graph buffer:

| Key | Description |
|-----|-------------|
| `<CR>` or `gf` | Navigate to note (create if unresolved) |
| `f` | Open filter panel |
| `+` | Increase graph depth |
| `-` | Decrease graph depth |
| `r` | Reset filters |
| `p` | Load filter preset |
| `P` | Save filter preset |
| `u` | Toggle unresolved link visibility |
| `s` | Search visible graph nodes |
| `?` | Show help |

---

## Which-Key Group Prefixes

Press `<Space>` and wait to see these groups:

| Prefix | Group |
|--------|-------|
| `<leader>a` | Type Check |
| `<leader>c` | Code Actions |
| `<leader>d` | Debug |
| `<leader>e` | Explorer |
| `<leader>f` | Find/Files |
| `<leader>g` | Git |
| `<leader>h` | Git Hunks |
| `<leader>l` | Lint |
| `<leader>m` | Make/Build (Markdown in .md buffers) |
| `<leader>o` | OpenCode |
| `<leader>r` | Rust/Refactor |
| `<leader>s` | Split/Window |
| `<leader>t` | Tab/Terminal |
| `<leader>v` | Vault |
| `<leader>x` | Trouble/Diagnostics |

### Vault Sub-Groups (`<leader>v...`)

| Prefix | Group |
|--------|-------|
| `<leader>va` | AutoLink |
| `<leader>vb` | Bookmarks |
| `<leader>vc` | Check |
| `<leader>vd` | Daily |
| `<leader>ve` | Edit |
| `<leader>vf` | Find |
| `<leader>vg` | Graph/Tags |
| `<leader>vk` | BlockId |
| `<leader>vm` | Meta |
| `<leader>vq` | Query |
| `<leader>vS` | Sidebar |
| `<leader>vt` | Templates |
| `<leader>vx` | Tasks |
| `<leader>v?` | Palette |

---

## Formatting (Auto)

**File:** `lua/andrew/plugins/formatting/conform.lua`

No manual keybindings. Auto-formats on save via `BufWritePre` for:

| Filetype | Formatter |
|----------|-----------|
| Lua | stylua |
| Python | ruff_format |
| JavaScript/TypeScript | prettier |
| JSON, CSS, HTML, YAML | prettier |
| Markdown | prettier |
| Fortran (f90/f95/f03/f08) | fprettify |

---

## Source Files

All keybinding definitions are in these locations:

| File | Category |
|------|----------|
| `lua/andrew/core/keymaps.lua` | Core editor |
| `ftplugin/markdown.lua` | Markdown editing |
| `ftplugin/tex.lua` | LaTeX editing |
| `lua/andrew/utils/tex-motions.lua` | TeX motions & text objects |
| `lua/andrew/plugins/lsp/lspconfig.lua` | LSP |
| `lua/andrew/plugins/blink-cmp.lua` | Completion |
| `lua/andrew/plugins/fzf-lua.lua` | Fuzzy finder |
| `lua/andrew/plugins/gitsigns.lua` | Git hunks |
| `lua/andrew/plugins/trouble.lua` | Diagnostics |
| `lua/andrew/plugins/substitute.lua` | Substitute |
| `lua/andrew/plugins/surround.lua` | Surround |
| `lua/andrew/plugins/comment.lua` | Comments |
| `lua/andrew/plugins/todo-comments.lua` | TODO comments |
| `lua/andrew/plugins/vim-maximizer.lua` | Window maximize |
| `lua/andrew/plugins/vim-table-mode.lua` | Table mode |
| `lua/andrew/plugins/yazi.lua` | File explorer |
| `lua/andrew/plugins/opencode.lua` | OpenCode AI |
| `lua/andrew/plugins/rustaceanvim.lua` | Rust development |
| `lua/andrew/plugins/fortran-build.lua` | Make/Build |
| `lua/andrew/plugins/linting.lua` | Linting |
| `lua/andrew/plugins/type-checker.lua` | Type checking |
| `lua/andrew/plugins/formatting/conform.lua` | Formatting |
| `lua/andrew/plugins/dap/dap.lua` | Debug (DAP) |
| `lua/andrew/plugins/dap/dap-ui.lua` | Debug UI |
| `lua/andrew/plugins/treesitter-context.lua` | Context |
| `lua/andrew/plugins/render-markdown.lua` | Render markdown |
| `lua/andrew/plugins/which-key.lua` | Group registrations |
| `lua/andrew/custom/plugins/terminal.lua` | Terminal |
| `lua/andrew/vault/init.lua` | Vault templates |
| `lua/andrew/vault/search.lua` | Vault search |
| `lua/andrew/vault/navigate.lua` | Vault navigation |
| `lua/andrew/vault/wikilinks.lua` | Vault wikilinks |
| `lua/andrew/vault/backlinks.lua` | Vault backlinks |
| `lua/andrew/vault/autolink.lua` | Vault autolink |
| `lua/andrew/vault/blockid.lua` | Vault block IDs |
| `lua/andrew/vault/sidebar.lua` | Vault sidebar |
| `lua/andrew/vault/preview.lua` | Vault preview |
| `lua/andrew/vault/quicktask.lua` | Vault quick task |
| `lua/andrew/vault/task_notify.lua` | Vault task notifications |
| `lua/andrew/vault/task_hierarchy.lua` | Vault task hierarchy |
| `lua/andrew/vault/outline.lua` | Vault outline |
| `lua/andrew/vault/recent.lua` | Vault recent files |
| `lua/andrew/vault/pickers.lua` | Vault pickers |
| `lua/andrew/vault/capture.lua` | Vault capture |
| `lua/andrew/vault/callout_folds.lua` | Vault callout folds |
| `lua/andrew/vault/graph.lua` | Vault graph |
| `lua/andrew/vault/command_palette.lua` | Vault command palette |
