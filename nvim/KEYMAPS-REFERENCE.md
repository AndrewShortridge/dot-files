# Neovim Keymaps — Complete Reference

> **Leader key:** `<Space>`
> **Local leader:** *(not set)*
> **Config:** `~/.config/nvim`

Press `<Space>` and wait for the **which-key** popup to see all available leader groups.

---

## Table of Contents

1. [General / Core](#1-general--core)
2. [Window & Split Management](#2-window--split-management)
3. [Tab Management](#3-tab-management)
4. [Fuzzy Finder (fzf-lua)](#4-fuzzy-finder-fzf-lua)
5. [LSP — Language Server Protocol](#5-lsp--language-server-protocol)
6. [Completion (blink.cmp)](#6-completion-blinkcmp)
7. [Diagnostics & Trouble](#7-diagnostics--trouble)
8. [Git (Gitsigns)](#8-git-gitsigns)
9. [File Explorer (Yazi)](#9-file-explorer-yazi)
10. [Debugging (DAP)](#10-debugging-dap)
11. [Terminal](#11-terminal)
12. [Make / Build (Fortran)](#12-make--build-fortran)
13. [Type Checking](#13-type-checking)
14. [Linting](#14-linting)
15. [Formatting (conform.nvim)](#15-formatting-conformnvim)
16. [Treesitter](#16-treesitter)
17. [Commenting (Comment.nvim)](#17-commenting-commentnvim)
18. [Surround (nvim-surround)](#18-surround-nvim-surround)
19. [Substitute (substitute.nvim)](#19-substitute-substitutenvim)
20. [TODO Comments](#20-todo-comments)
21. [Table Mode](#21-table-mode)
22. [Window Maximizer](#22-window-maximizer)
23. [Rust Development (rustaceanvim)](#23-rust-development-rustaceanvim)
24. [OpenCode AI](#24-opencode-ai)
25. [Markdown — Filetype Keymaps](#25-markdown--filetype-keymaps)
26. [LaTeX (tex) — Filetype Keymaps](#26-latex-tex--filetype-keymaps)
27. [Markdown Text Objects & Motions](#27-markdown-text-objects--motions)
28. [LaTeX Text Objects & Motions](#28-latex-text-objects--motions)
29. [Vault — Templates](#29-vault--templates)
30. [Vault — Navigation & Daily Logs](#30-vault--navigation--daily-logs)
31. [Vault — Search & Find](#31-vault--search--find)
32. [Vault — Query Engine](#32-vault--query-engine)
33. [Vault — Wikilinks & Links](#33-vault--wikilinks--links)
34. [Vault — Edit & Rename](#34-vault--edit--rename)
35. [Vault — Meta Edit (Frontmatter)](#35-vault--meta-edit-frontmatter)
36. [Vault — Tasks](#36-vault--tasks)
37. [Vault — Tags](#37-vault--tags)
38. [Vault — Link Checking & Diagnostics](#38-vault--link-checking--diagnostics)
39. [Vault — Pins & Bookmarks](#39-vault--pins--bookmarks)
40. [Vault — Capture & Quick Note](#40-vault--capture--quick-note)
41. [Vault — Graph & Preview](#41-vault--graph--preview)
42. [Vault — Miscellaneous](#42-vault--miscellaneous)
43. [Vault — Calendar View (Inside Float)](#43-vault--calendar-view-inside-float)
44. [Vault — Preview Float (Inside Float)](#44-vault--preview-float-inside-float)
45. [User Commands](#45-user-commands)
46. [Which-Key Group Index](#46-which-key-group-index)

---

## 1. General / Core

**Source:** `lua/andrew/core/keymaps.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| i | `jk` | `<ESC>` | Exit insert mode |
| n | `<leader>nh` | `:nohl<CR>` | Clear search highlights |
| n | `<leader>+` | `<C-a>` | Increment number under cursor |
| n | `<leader>-` | `<C-x>` | Decrement number under cursor |

**Yank highlight:** Yanked text flashes for 300ms (via `TextYankPost` autocmd).

---

## 2. Window & Split Management

**Source:** `lua/andrew/core/keymaps.lua` | **Prefix:** `<leader>s`

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>sv` | `<C-w>v` | Split window vertically |
| `<leader>sh` | `<C-w>s` | Split window horizontally |
| `<leader>se` | `<C-w>=` | Equalize all split sizes |
| `<leader>sx` | `:close` | Close current split |

**Tmux Navigator** (vim-tmux-navigator):
| Key | Action |
|-----|--------|
| `<C-h>` | Navigate to left split (or tmux pane) |
| `<C-j>` | Navigate to split below (or tmux pane) |
| `<C-k>` | Navigate to split above (or tmux pane) |
| `<C-l>` | Navigate to right split (or tmux pane) |

---

## 3. Tab Management

**Source:** `lua/andrew/core/keymaps.lua` | **Prefix:** `<leader>t`

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>to` | `:tabnew` | Open new tab |
| `<leader>tx` | `:tabclose` | Close current tab |
| `<leader>tn` | `:tabn` | Go to next tab |
| `<leader>tp` | `:tabp` | Go to previous tab |
| `<leader>tf` | `:tabnew %` | Open current buffer in new tab |

---

## 4. Fuzzy Finder (fzf-lua)

**Source:** `lua/andrew/plugins/fzf-lua.lua` | **Prefix:** `<leader>f`

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>ff` | `files` | Find files in current directory |
| `<leader>fr` | `oldfiles` | Find recently opened files |
| `<leader>fs` | `live_grep` | Live grep (search string in cwd) |
| `<leader>fc` | `grep_cword` | Grep word under cursor |
| `<leader>fk` | `keymaps` | Search all keybindings |
| `<leader>fh` | `help_tags` | Search `:help` tags |
| `<leader>fH` | `grep` (help docs) | Grep through `:help` documentation |
| `<leader>ft` | `todo-comments` | Find TODO/FIXME comments |

**Inside fzf picker window:**

| Key | Action |
|-----|--------|
| `<C-n>` | Navigate down |
| `<C-p>` | Navigate up |
| `<C-j>` | Scroll preview down |
| `<C-k>` | Scroll preview up |
| `ctrl-q` | Select all + accept |
| `ctrl-s` | Open in horizontal split |
| `ctrl-v` | Open in vertical split |
| `ctrl-t` | Send results to Trouble |

---

## 5. LSP — Language Server Protocol

**Source:** `lua/andrew/plugins/lsp/lspconfig.lua` | Active on `LspAttach` (buffer-local)

### Navigation

| Key | Action | Description |
|-----|--------|-------------|
| `gd` | Definitions | Go to definition(s) via fzf-lua |
| `gD` | Declaration | Go to declaration (fallback to definition) |
| `gR` | References | Show all references via fzf-lua |
| `gi` | Implementations | Show implementations via fzf-lua |
| `gt` | Type definitions | Show type definitions via fzf-lua |

### Hover & Signature

| Key | Mode | Description |
|-----|------|-------------|
| `K` | n | Show hover documentation (with Fortran custom docs) |
| `<C-k>` | n, i | Show signature help (ty for Python if available) |

### Code Actions & Refactoring

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>ca` | n, v | See available code actions |
| `<leader>rn` | n | Smart rename symbol |
| `<leader>rs` | n | Restart LSP server |

### Diagnostics

| Key | Description |
|-----|-------------|
| `<leader>D` | Show buffer diagnostics (fzf-lua picker) |
| `<leader>d` | Show line diagnostics (floating window) |
| `[d` | Go to previous diagnostic |
| `]d` | Go to next diagnostic |

**Configured LSP servers:** lua_ls, pylsp, fortls, ctags_lsp, rust_analyzer (via rustaceanvim)

---

## 6. Completion (blink.cmp)

**Source:** `lua/andrew/plugins/blink-cmp.lua` | Active in insert mode

| Key | Action | Description |
|-----|--------|-------------|
| `<C-Space>` | Show menu | Trigger completion menu |
| `<C-n>` | Next item | Select next completion item |
| `<C-p>` | Previous item | Select previous completion item |
| `<CR>` | Accept | Accept selected completion / expand snippet |
| `<C-e>` | Hide | Dismiss completion menu |
| `<C-j>` | Scroll down | Scroll documentation window down |
| `<C-k>` | Scroll up | Scroll documentation window up |

**Completion sources by filetype:**
- **Fortran:** fortran_docs, lsp, snippets, path, buffer
- **Markdown:** wikilinks, vault_tags, vault_frontmatter, lsp, snippets, path, buffer
- **Default:** lsp, snippets, path, buffer

**Snippet expansion:** Snippets loaded from `snippets/` (VSCode JSON) and `luasnippets/` (Lua). LuaSnip autosnippets enabled (`;` prefix triggers, e.g. `;frac`).

---

## 7. Diagnostics & Trouble

**Source:** `lua/andrew/plugins/trouble.lua` | **Prefix:** `<leader>x`

| Key | Description |
|-----|-------------|
| `<leader>xw` | Workspace diagnostics (floating preview) |
| `<leader>xd` | Current file diagnostics |
| `<leader>xe` | Errors only — current file |
| `<leader>xE` | Errors only — workspace |
| `<leader>xq` | Open quickfix list |
| `<leader>xl` | Open location list |
| `<leader>xt` | Open TODO comments |
| `<leader>xf` | Open fzf-lua results in Trouble |
| `<leader>xF` | Open fzf-lua file results in Trouble |

---

## 8. Git (Gitsigns)

**Source:** `lua/andrew/plugins/gitsigns.lua` | Active on `on_attach` (buffer-local)

### Hunk Navigation

| Key | Description |
|-----|-------------|
| `]g` | Jump to next hunk |
| `[g` | Jump to previous hunk |

### Hunk Actions — Prefix: `<leader>h`

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>hs` | n, v | Stage hunk (or visual selection) |
| `<leader>hr` | n, v | Reset hunk (or visual selection) |
| `<leader>hS` | n | Stage entire buffer |
| `<leader>hR` | n | Reset entire buffer |
| `<leader>hu` | n | Undo stage hunk |
| `<leader>hp` | n | Preview hunk (inline popup) |
| `<leader>hb` | n | Blame line (full git blame) |
| `<leader>hB` | n | Toggle current line blame (inline) |
| `<leader>hd` | n | Diff this file |
| `<leader>hD` | n | Diff this ~ (against previous commit) |

### Text Object

| Key | Mode | Description |
|-----|------|-------------|
| `ih` | o, x | Select hunk (operator/visual mode) |

---

## 9. File Explorer (Yazi)

**Source:** `lua/andrew/plugins/yazi.lua` | **Prefix:** `<leader>e`

| Key | Description |
|-----|-------------|
| `<leader>ee` | Open Yazi file explorer |
| `<leader>ef` | Open Yazi at current file location |
| `<leader>ec` | Close explorer window |
| `<leader>er` | Refresh explorer |

**Inside Yazi:**

| Key | Description |
|-----|-------------|
| `<F1>` | Show help |
| `<C-s>` | Grep in directory / grep selected files |

---

## 10. Debugging (DAP)

**Source:** `lua/andrew/plugins/dap/dap.lua`, `lua/andrew/plugins/dap/dap-ui.lua` | **Prefix:** `<leader>d`

### Debug Session Control

| Key | Description |
|-----|-------------|
| `<leader>dc` | Start / Continue debugging |
| `<leader>do` | Step over |
| `<leader>di` | Step into |
| `<leader>dO` | Step out |
| `<leader>dt` | Terminate debugging session |
| `<leader>dC` | Run to cursor |
| `<leader>dr` | Restart debugging |
| `<leader>dR` | Toggle REPL |

### Breakpoints

| Key | Description |
|-----|-------------|
| `<leader>db` | Toggle breakpoint on current line |
| `<leader>dB` | Set conditional breakpoint (prompts for condition) |

### DAP UI

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>du` | n | Toggle DAP UI panel |
| `<leader>de` | n, v | Evaluate expression |
| `<leader>df` | n | Float element (hover window) |

**Inside DAP float:** `q` or `<Esc>` to close.

**Configured debuggers:** CodeLLDB (C, C++, Rust, Fortran)

**DAP signs:** `●` breakpoint (red), `●` conditional (yellow), `×` rejected (red), `▶` stopped (green), `◆` log point (blue)

---

## 11. Terminal

**Source:** `lua/andrew/custom/plugins/terminal.lua`

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>tt` | n | Toggle floating terminal |
| `<C-\><C-n>` | t | Exit terminal mode (standard) |
| `jk` | t | Exit terminal mode (custom) |

**Commands:**
- `:FloatingTerminal toggle` — Toggle visibility
- `:FloatingTerminal open` — Show terminal (restore session)
- `:FloatingTerminal hide` — Hide (preserve session)
- `:FloatingTerminal close` — Close and terminate
- `:FloatingTerminal restart` — Restart terminal
- `:FloatingTerminal send <cmd>` — Send command to terminal

**Config:** 80% width x 80% height, centered, rounded border, session-persistent.

---

## 12. Make / Build (Fortran)

**Source:** `lua/andrew/plugins/fortran-build.lua` | **Prefix:** `<leader>m` *(non-markdown buffers)*

| Key | Description |
|-----|-------------|
| `<leader>mb` | Make: Build (pick Makefile) |
| `<leader>md` | Make: Build Debug |
| `<leader>mc` | Make: Clean |
| `<leader>mr` | Make: Run |
| `<leader>ma` | Make: All |
| `<leader>ml` | Make: Re-run last Makefile |

---

## 13. Type Checking

**Source:** `lua/andrew/plugins/type-checker.lua` | **Prefix:** `<leader>a`

### Dispatch (auto-detect filetype)

| Key | Description |
|-----|-------------|
| `<leader>ac` | Type check — dispatch by current filetype |

### Language-Specific

| Key | Description |
|-----|-------------|
| `<leader>aP` | Python type check (ruff check) |
| `<leader>aT` | Ty type check (Python) |
| `<leader>aR` | cargo check (Rust) |
| `<leader>aL` | lua-language-server --check (Lua) |
| `<leader>aF` | Fortran type check (current compiler) |
| `<leader>aC` | C/C++ syntax & warnings |

### Fortran Compiler Toggle

| Key | Description |
|-----|-------------|
| `<leader>ag` | Fortran check with mpif90/gfortran |
| `<leader>ai` | Fortran check with mpiifx/Intel |
| `<leader>at` | Toggle Fortran compiler (mpif90 <-> mpiifx) |

---

## 14. Linting

**Source:** `lua/andrew/plugins/linting.lua` | **Prefix:** `<leader>l`

| Key | Description |
|-----|-------------|
| `<leader>ll` | Run linters for current buffer |
| `<leader>lm` | Run ruff (Python) |
| `<leader>lf` | Toggle Fortran linter |
| `<leader>lF` | Run Fortran linter (debug mode) |
| `<leader>lw` | Lint entire Fortran workspace |
| `<leader>lW` | Clear workspace diagnostics |

---

## 15. Formatting (conform.nvim)

**Source:** `lua/andrew/plugins/formatting/conform.lua`

**No explicit keymaps** — formatting runs automatically on `:w` (save) via `BufWritePre` autocmd.

| Filetype | Formatter |
|----------|-----------|
| Lua | stylua |
| Python | ruff_format |
| Fortran | fprettify |
| JS/TS/Vue/HTML/CSS/JSON/YAML/Markdown | prettier |
| Rust | rustfmt (via rustaceanvim) |

---

## 16. Treesitter

**Source:** `lua/andrew/plugins/treesitter.lua`, `lua/andrew/plugins/treesitter-context.lua`

### Incremental Selection

| Key | Mode | Description |
|-----|------|-------------|
| `<C-Space>` | n | Start selection / expand to next node |
| `<BS>` | x | Shrink selection to previous node |

### Treesitter Context (Sticky Headers)

| Key | Description |
|-----|-------------|
| `[c` | Jump to context (parent scope / containing heading) |

---

## 17. Commenting (Comment.nvim)

**Source:** `lua/andrew/plugins/comment.lua` | Uses default Comment.nvim mappings

| Key | Mode | Description |
|-----|------|-------------|
| `gcc` | n | Toggle comment on current line |
| `gc{motion}` | n | Toggle comment with motion (e.g., `gcap` = paragraph) |
| `gc` | v | Toggle comment on visual selection |
| `gbc` | n | Toggle block comment on current line |
| `gb` | v | Toggle block comment on visual selection |

Supports treesitter-aware context (JSX, HTML, Vue, embedded languages).

---

## 18. Surround (nvim-surround)

**Source:** `lua/andrew/plugins/surround.lua` | Uses default nvim-surround mappings

### Core Operations

| Key | Mode | Description |
|-----|------|-------------|
| `ys{motion}{char}` | n | Add surround (e.g., `ysiw"` = wrap word in `"`) |
| `cs{old}{new}` | n | Change surround (e.g., `cs'"` = change `'` to `"`) |
| `ds{char}` | n | Delete surround (e.g., `ds"` = remove `"`) |
| `S{char}` | v | Surround visual selection |

### Custom Surround Characters

| Char | Surround Type | Example |
|------|---------------|---------|
| `e` | LaTeX environment | `\begin{env}...\end{env}` |
| `c` | LaTeX command | `\cmd{...}` |

**Examples:**
- `ysiwe` — Wrap word in LaTeX environment (prompts for env name)
- `ySse` — Wrap entire line in LaTeX environment
- `vSc` — Wrap visual selection in LaTeX command
- `dse` — Delete enclosing LaTeX environment
- `cse` — Change LaTeX environment name

---

## 19. Substitute (substitute.nvim)

**Source:** `lua/andrew/plugins/substitute.lua`

| Key | Mode | Description |
|-----|------|-------------|
| `s{motion}` | n | Substitute with motion (e.g., `siw` = substitute word) |
| `ss` | n | Substitute entire line |
| `S` | n | Substitute from cursor to end of line |
| `s` | v | Substitute visual selection |

Replaces the selected text with register contents (or new text you type).

---

## 20. TODO Comments

**Source:** `lua/andrew/plugins/todo-comments.lua`

| Key | Description |
|-----|-------------|
| `]t` | Jump to next TODO/FIXME comment |
| `[t` | Jump to previous TODO/FIXME comment |

Recognized keywords: `TODO`, `FIXME`, `HACK`, `WARN`, `PERF`, `NOTE`, `TEST`

---

## 21. Table Mode

**Source:** `lua/andrew/plugins/vim-table-mode.lua`

| Key | Description |
|-----|-------------|
| `<leader>Tm` | Toggle table mode on/off |

**When table mode is active:**

| Key | Description |
|-----|-------------|
| `\|` | Auto-create table structure as you type |
| `Tab` | Move to next cell |
| `\|\|` | Create horizontal separator row |

Produces markdown-compatible tables with auto-aligned columns.

---

## 22. Window Maximizer

**Source:** `lua/andrew/plugins/vim-maximizer.lua`

| Key | Description |
|-----|-------------|
| `<leader>sm` | Maximize / restore current split window |

---

## 23. Rust Development (rustaceanvim)

**Source:** `lua/andrew/plugins/rustaceanvim.lua` | Active only in Rust files (buffer-local)

| Key | Description |
|-----|-------------|
| `<leader>ca` | Rust code actions |
| `K` | Rust hover actions (overrides default) |
| `<leader>rr` | Run runnables |
| `<leader>rd` | Run debuggables |
| `<leader>rt` | Run testables |
| `<leader>rm` | Expand macro recursively |
| `<leader>rc` | Open Cargo.toml |
| `<leader>rp` | Go to parent module |
| `J` | Join lines (Rust-aware) |
| `<leader>re` | Explain error |
| `<leader>rD` | Render diagnostics |
| `<leader>dt` | Debugger testables |

---

## 24. OpenCode AI

**Source:** `lua/andrew/plugins/opencode.lua` | **Prefix:** `<leader>o`

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>ot` | n | Toggle OpenCode panel |
| `<leader>oa` | n, v | Ask OpenCode about code at cursor / selection |
| `<leader>o+` | n, v | Add current buffer / selection to prompt |
| `<leader>oe` | n | Explain code at cursor |
| `<leader>on` | n | Create new OpenCode session |
| `<leader>os` | n, v | Select OpenCode prompt |
| `<S-C-u>` | n | Scroll OpenCode messages up |
| `<S-C-d>` | n | Scroll OpenCode messages down |

---

## 25. Markdown — Filetype Keymaps

**Source:** `ftplugin/markdown.lua` | Active only in markdown files (buffer-local)
**Prefix:** `<leader>m` (which-key shows "Markdown" instead of "Make/Build")

### Folding

| Key | Description |
|-----|-------------|
| `<Tab>` | Toggle fold under cursor |
| `<leader>mf` | Fold all (close all folds) |
| `<leader>mu` | Unfold all (open all folds) |
| `<leader>ml` | Set fold level (prompts for number) |

### Heading Navigation (Treesitter-based)

| Key | Description |
|-----|-------------|
| `]h` | Jump to next heading (any level) |
| `[h` | Jump to previous heading (any level) |
| `]1` — `]6` | Jump to next heading at level 1-6 |
| `[1` — `[6` | Jump to previous heading at level 1-6 |

### Heading Level Toggle

| Key | Description |
|-----|-------------|
| `<leader>m1` — `<leader>m6` | Set heading to level 1-6 (removes heading if already at that level) |

### Checkbox / Task

| Key | Description |
|-----|-------------|
| `<leader>mx` | Cycle checkbox state (unchecked -> checked -> cancelled, auto-adds `[completion:: date]`) |

### Inline Formatting

| Key | Mode | Markup | Description |
|-----|------|--------|-------------|
| `<leader>mb` | n | `**text**` | Toggle bold on word under cursor |
| `<leader>mb` | v | `**text**` | Toggle bold on selection |
| `<leader>mi` | n | `*text*` | Toggle italic on word under cursor |
| `<leader>mi` | v | `*text*` | Toggle italic on selection |
| `<leader>ms` | n | `~~text~~` | Toggle strikethrough on word |
| `<leader>ms` | v | `~~text~~` | Toggle strikethrough on selection |
| `<leader>mc` | n | `` `text` `` | Toggle inline code on word |
| `<leader>mc` | v | `` `text` `` | Toggle inline code on selection |

### Link Creation (Visual Mode)

| Key | Description |
|-----|-------------|
| `<leader>mk` | Create markdown link `[text](url)` (prompts for URL) |
| `<leader>mK` | Create / toggle wikilink `[[text]]` |

### Images & Callouts

| Key | Description |
|-----|-------------|
| `<leader>mp` | Paste clipboard image |
| `<leader>mz` | Toggle callout fold (render-markdown) |

### Footnotes

| Key | Description |
|-----|-------------|
| `<leader>mj` | Jump between footnote reference <-> definition |
| `<leader>mn` | List all footnotes (picker) |

---

## 26. LaTeX (tex) — Filetype Keymaps

**Source:** `ftplugin/tex.lua` | Active only in TeX files (buffer-local)

| Key | Mode | Description |
|-----|------|-------------|
| `j` | n | Move down by visual line (`gj`) |
| `k` | n | Move up by visual line (`gk`) |
| `<Tab>` | n | Toggle fold |
| `<leader>mf` | n | Fold all |
| `<leader>mu` | n | Unfold all |

**Also enabled:** Spell checking (en_us), conceal level 2 (renders `\alpha` as alpha), treesitter folding.

---

## 27. Markdown Text Objects & Motions

**Source:** `lua/andrew/utils/md-textobjects.lua` | Active in markdown (buffer-local)

### Text Objects (Visual & Operator-Pending)

| Key | Description |
|-----|-------------|
| `ac` | Around code block (including ``` fences) |
| `ic` | Inside code block (content only) |
| `al` | Around list item (bullet + sub-items) |
| `il` | Inside list item (text only, no bullet) |
| `aq` | Around blockquote (including `>` prefix) |
| `iq` | Inside blockquote (content after `>`) |

### Motions (Normal, Visual, Operator-Pending)

| Key | Description |
|-----|-------------|
| `]b` | Jump to next code block |
| `[b` | Jump to previous code block |
| `]l` | Jump to next list item |
| `[l` | Jump to previous list item |
| `]q` | Jump to next blockquote |
| `[q` | Jump to previous blockquote |

### Math Text Objects & Motions (Markdown)

**Source:** `lua/andrew/utils/tex-motions.lua` (`setup_markdown()`)

| Key | Mode | Description |
|-----|------|-------------|
| `am` | x, o | Around math zone (`$...$` or `$$...$$`) |
| `im` | x, o | Inside math zone |
| `]m` | n, x, o | Jump to next math zone |
| `[m` | n, x, o | Jump to previous math zone |

All motions support `v:count` (e.g., `3]b` jumps 3 code blocks forward).

---

## 28. LaTeX Text Objects & Motions

**Source:** `lua/andrew/utils/tex-motions.lua` (`setup()`) | Active in TeX files (buffer-local)

### Motions (Normal, Visual, Operator-Pending)

| Key | Description |
|-----|-------------|
| `]]` | Jump to next section (`\section`, `\subsection`, etc.) |
| `[[` | Jump to previous section |
| `]e` | Jump to next environment (`\begin{...}`) |
| `[e` | Jump to previous environment |
| `]m` | Jump to next math zone |
| `[m` | Jump to previous math zone |

### Text Objects (Visual & Operator-Pending)

| Key | Description |
|-----|-------------|
| `ae` | Around environment (full `\begin{...}...\end{...}`) |
| `ie` | Inside environment (content between begin/end) |
| `am` | Around math zone (including delimiters) |
| `im` | Inside math zone (content only) |
| `ac` | Around command (full `\cmd{...}`) |
| `ic` | Inside command (content within `{...}`) |

All motions support `v:count` (e.g., `3]]` jumps 3 sections forward).

---

## 29. Vault — Templates

**Source:** `lua/andrew/vault/init.lua` | **Prefix:** `<leader>vt`

| Key | Description | Note Type |
|-----|-------------|-----------|
| `<leader>vtn` | Template picker (all types) | — |
| `<leader>vtd` | Daily log | `log` |
| `<leader>vtw` | Weekly review | `log` (weekly-review) |
| `<leader>vts` | Simulation note | `simulation` |
| `<leader>vta` | Analysis note | `analysis` |
| `<leader>vtk` | Task note | `task` |
| `<leader>vtm` | Meeting note | `meeting` |
| `<leader>vtf` | Finding note | `finding` |
| `<leader>vtl` | Literature note | `literature` |
| `<leader>vtp` | Project dashboard | `project-dashboard` |
| `<leader>vtj` | Journal entry | `journal-entry` |
| `<leader>vtc` | Concept note | `concept` |
| `<leader>vtM` | Monthly review | `log` (monthly) |
| `<leader>vtQ` | Quarterly review | `log` (quarterly) |
| `<leader>vtY` | Yearly review | `log` (yearly) |

**Commands:** `:VaultNew` (template picker), `:VaultDaily` (daily log), `:VaultSwitch` (switch vault)

---

## 30. Vault — Navigation & Daily Logs

**Source:** `lua/andrew/vault/navigate.lua`

| Key | Description |
|-----|-------------|
| `<leader>v[` | Previous daily log |
| `<leader>v]` | Next daily log |
| `<leader>v{` | Previous weekly review |
| `<leader>v}` | Next weekly review |
| `<leader>vC` | Calendar view (floating popup) |
| `<leader>vfd` | Find: daily log list (picker) |
| `<leader>vfw` | Find: weekly review list (picker) |
| `<leader>vfW` | Find: all reviews list (picker) |

---

## 31. Vault — Search & Find

**Source:** `lua/andrew/vault/search.lua`, `lua/andrew/vault/outline.lua`, `lua/andrew/vault/backlinks.lua`, `lua/andrew/vault/pickers.lua`, `lua/andrew/vault/recent.lua`, `lua/andrew/vault/saved_searches.lua`, `lua/andrew/plugins/fzf-lua.lua`

**Prefix:** `<leader>vf`

| Key | Source | Description |
|-----|--------|-------------|
| `<leader>vff` | fzf-lua.lua | Find vault files (frecency-sorted) |
| `<leader>vfs` | search.lua | Search vault (full-text) |
| `<leader>vfn` | search.lua | Search notes (title/filename) |
| `<leader>vfD` | search.lua | Search filtered (scope by directory) |
| `<leader>vfy` | search.lua | Search by type (frontmatter type field) |
| `<leader>vfo` | outline.lua | Document outline (heading picker) |
| `<leader>vft` | tags.lua | Find by tag |
| `<leader>vfb` | backlinks.lua | Find backlinks to current note |
| `<leader>vfl` | backlinks.lua | Find forward links from current note |
| `<leader>vfh` | backlinks.lua | Find heading backlinks |
| `<leader>vfp` | pickers.lua | Find project dashboards |
| `<leader>vfr` | recent.lua | Find recent notes (frecency) |
| `<leader>vfS` | saved_searches.lua | Open saved searches |

---

## 32. Vault — Query Engine

**Source:** `lua/andrew/vault/query/init.lua` | **Prefix:** `<leader>vq`

| Key | Description |
|-----|-------------|
| `<leader>vqr` | Render query block under cursor |
| `<leader>vqa` | Render all query blocks in buffer |
| `<leader>vqc` | Clear output for query block under cursor |
| `<leader>vqx` | Clear all query outputs in buffer |
| `<leader>vqq` | Toggle query block (render / clear) |
| `<leader>vqi` | Rebuild vault index |

---

## 33. Vault — Wikilinks & Links

**Source:** `lua/andrew/vault/wikilinks.lua`, `lua/andrew/vault/wikilink_highlights.lua`

| Key | Description |
|-----|-------------|
| `gf` | Follow link (wikilink, markdown link, or URL) |
| `gx` | Open link in browser / follow link |
| `]o` | Jump to next link in buffer |
| `[o` | Jump to previous link in buffer |

---

## 34. Vault — Edit & Rename

**Source:** `lua/andrew/vault/rename.lua`, `lua/andrew/vault/preview.lua`, `lua/andrew/vault/export.lua`, `lua/andrew/vault/extract.lua`

**Prefix:** `<leader>ve`

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>ver` | n | Rename current note (updates all backlinks) |
| `<leader>veR` | n | Preview rename (dry-run) |
| `<leader>vet` | n | Rename tag across vault |
| `<leader>vE` | n | Edit linked note in floating window |
| `<leader>vep` | n | Export note via Pandoc |
| `<leader>vex` | v | Extract selection to new note |

---

## 35. Vault — Meta Edit (Frontmatter)

**Source:** `lua/andrew/vault/metaedit.lua`, `lua/andrew/vault/autofile.lua` | **Prefix:** `<leader>vm`

| Key | Description |
|-----|-------------|
| `<leader>vms` | Cycle status field (type-aware values) |
| `<leader>vmp` | Cycle priority field |
| `<leader>vmm` | Cycle maturity field |
| `<leader>vmt` | Toggle draft status |
| `<leader>vmf` | Pick and set any frontmatter field |
| `<leader>vmv` | Auto-file suggestion (move note to correct folder) |

---

## 36. Vault — Tasks

**Source:** `lua/andrew/vault/tasks.lua`, `lua/andrew/vault/quicktask.lua` | **Prefix:** `<leader>vx`

| Key | Description |
|-----|-------------|
| `<leader>vxo` | Show open tasks across vault |
| `<leader>vxa` | Show all tasks across vault |
| `<leader>vxs` | Show tasks by state |
| `<leader>vxq` | Quick task — create inline task |

---

## 37. Vault — Tags

**Source:** `lua/andrew/vault/tags.lua`, `lua/andrew/vault/tag_highlights.lua` | **Prefix:** `<leader>vg`

| Key | Description |
|-----|-------------|
| `<leader>vga` | Add tag to current note |
| `<leader>vgr` | Remove tag from current note |
| `<leader>vgt` | Toggle inline tag highlighting |
| `]t` | Jump to next inline tag *(markdown buffer override)* |
| `[t` | Jump to previous inline tag *(markdown buffer override)* |

> **Note:** `]t` / `[t` in markdown overrides the TODO comment navigation from `todo-comments.lua`. Outside markdown, `]t`/`[t` navigate TODO comments.

---

## 38. Vault — Link Checking & Diagnostics

**Source:** `lua/andrew/vault/linkdiag.lua`, `lua/andrew/vault/linkcheck.lua` | **Prefix:** `<leader>vc`

### Real-time Diagnostics (linkdiag.lua)

| Key | Description |
|-----|-------------|
| `<leader>vcd` | Toggle real-time link diagnostics |
| `<leader>vcf` | Fix broken link under cursor |
| `<leader>vcF` | Fix all broken links (picker) |

### Batch Link Checking (linkcheck.lua)

| Key | Description |
|-----|-------------|
| `<leader>vcb` | Check wikilinks in current buffer |
| `<leader>vca` | Check wikilinks across entire vault |
| `<leader>vco` | Find orphan notes (no inbound links) |

### Wikilink Highlights (wikilink_highlights.lua)

| Key | Description |
|-----|-------------|
| `<leader>vch` | Toggle wikilink resolution highlighting |

---

## 39. Vault — Pins & Bookmarks

**Source:** `lua/andrew/vault/pins.lua` | **Prefix:** `<leader>vb`

| Key | Description |
|-----|-------------|
| `<leader>vbp` | Toggle pin on current note |
| `<leader>vbf` | Find pinned notes (picker) |

---

## 40. Vault — Capture & Quick Note

**Source:** `lua/andrew/vault/capture.lua`

| Key | Description |
|-----|-------------|
| `<leader>vQ` | Quick capture to daily log |
| `<leader>vi` | Capture to inbox |

---

## 41. Vault — Graph & Preview

**Source:** `lua/andrew/vault/graph.lua`, `lua/andrew/vault/preview.lua`

| Key | Description |
|-----|-------------|
| `<leader>vG` | Open local knowledge graph |
| `<leader>vP` | Sticky project: show / set active project |
| `K` | Preview linked note on hover *(markdown buffer, overrides LSP hover)* |

---

## 42. Vault — Miscellaneous

**Source:** Various vault modules

| Key | Mode | Source | Description |
|-----|------|--------|-------------|
| `<leader>vI` | n | fragments.lua | Insert fragment from template |
| `<leader>vp` | n | images.lua | Paste image from clipboard |
| `<leader>vki` | n | blockid.lua | Generate block ID |
| `<leader>vkl` | n | blockid.lua | Generate block ID and copy link |
| `<leader>vV` | n | init.lua | Switch active vault |

---

## 43. Vault — Calendar View (Inside Float)

**Source:** `lua/andrew/vault/calendar.lua` | Active inside the calendar floating window

| Key | Action |
|-----|--------|
| `<CR>` | Open selected day's note |
| `h` | Previous month |
| `l` | Next month |
| `H` | Previous year |
| `L` | Next year |
| `j` | Navigate down in calendar grid |
| `k` | Navigate up in calendar grid |
| `q` / `<Esc>` | Close calendar |

---

## 44. Vault — Preview Float (Inside Float)

**Source:** `lua/andrew/vault/preview.lua` | Active inside the preview edit float

| Key | Action |
|-----|--------|
| `q` | Save and close |
| `<Esc><Esc>` | Save and close |
| `<C-s>` | Save without closing |
| `<C-j>` | Scroll parent buffer preview down |
| `<C-k>` | Scroll parent buffer preview up |

---

## 45. User Commands

Custom commands defined across the configuration, usable with `:CommandName`.

### Vault Commands

| Command | Source | Description |
|---------|--------|-------------|
| `:VaultNew` | vault/init.lua | Create new note from template picker |
| `:VaultDaily` | vault/init.lua | Create today's daily log |
| `:VaultSwitch` | vault/init.lua | Switch active vault |
| `:VaultBacklinks` | vault/backlinks.lua | Show notes linking to current note |
| `:VaultForwardlinks` | vault/backlinks.lua | List wikilinks in current note |
| `:VaultOutline` | vault/outline.lua | Show heading outline for current buffer |
| `:VaultExtract` | vault/extract.lua | Extract selection to new vault note |
| `:VaultPasteImage` | vault/images.lua | Paste clipboard image into vault |
| `:VaultBlockId` | vault/blockid.lua | Generate block ID for current line |
| `:VaultBlockIdLink` | vault/blockid.lua | Generate block ID and insert reference |
| `:VaultCheckBuffer` | vault/linkcheck.lua | Check wikilinks in buffer |
| `:VaultCheckVault` | vault/linkcheck.lua | Check wikilinks across vault |
| `:VaultCheckOrphans` | vault/linkcheck.lua | Find orphan notes (no inbound links) |
| `:VaultRename` | vault/rename.lua | Rename note across vault |
| `:VaultRenamePreview` | vault/rename.lua | Preview rename changes (dry-run) |
| `:VaultRenameTag` | vault/rename.lua | Rename tag across vault |
| `:VaultWikilinkHLToggle` | vault/wikilink_highlights.lua | Toggle wikilink highlighting |
| `:VaultWikilinkHLRefresh` | vault/wikilink_highlights.lua | Refresh wikilink highlights |
| `:VaultTagHLRefresh` | vault/tag_highlights.lua | Refresh tag highlights |
| `:VaultPreview` | vault/preview.lua | Preview wikilink under cursor |
| `:VaultFiles` | vault/frecency.lua | Find vault files by frecency |
| `:VaultDailyPrev` | vault/navigate.lua | Go to previous daily log |
| `:VaultDailyNext` | vault/navigate.lua | Go to next daily log |
| `:VaultWeeklyPrev` | vault/navigate.lua | Go to previous weekly review |
| `:VaultWeeklyNext` | vault/navigate.lua | Go to next weekly review |
| `:VaultReviews` | vault/navigate.lua | Find all reviews |
| `:VaultExport` | vault/export.lua | Export note via pandoc |
| `:VaultStickyProject` | vault/pickers.lua | Show/set sticky project |
| `:VaultStickyClear` | vault/pickers.lua | Clear sticky project |

### Plugin Commands

| Command | Source | Description |
|---------|--------|-------------|
| `:FloatingTerminal` | custom/plugins/terminal.lua | Manage floating terminal (toggle/open/close/hide/restart/send) |
| `:CtagsLspRestart` | plugins/lsp/lspconfig.lua | Restart ctags LSP server |
| `:CtagsLspInfo` | plugins/lsp/lspconfig.lua | Show ctags LSP info |
| `:TypeCheck` | plugins/type-checker.lua | Run type check (dispatch by filetype) |

### Float Window Keymaps

Active inside floating input/display windows (`lua/andrew/vault/ui.lua`):

| Key | Mode | Action |
|-----|------|--------|
| `<CR>` | n, i | Submit input |
| `q` | n | Close float |
| `<Esc>` | n | Close float |

---

## 46. Which-Key Group Index

Press `<Space>` and wait to see all groups. Here's the complete prefix map:

| Prefix | Group | Scope |
|--------|-------|-------|
| `<leader>a` | Type Check | Global |
| `<leader>c` | Code Actions | LSP buffers |
| `<leader>d` | Debug | Global |
| `<leader>e` | Explorer | Global |
| `<leader>f` | Find/Files | Global |
| `<leader>g` | Git | Global |
| `<leader>h` | Git Hunks | Git buffers |
| `<leader>l` | Lint | Global |
| `<leader>m` | Make/Build *(or Markdown in .md files)* | Global / Markdown |
| `<leader>o` | OpenCode | Global |
| `<leader>r` | Rust/Refactor | Global / Rust |
| `<leader>s` | Split/Window | Global |
| `<leader>t` | Tab/Terminal | Global |
| `<leader>v` | Vault | Markdown |
| `<leader>vb` | Vault: Pins | Markdown |
| `<leader>vc` | Vault: Check | Markdown |
| `<leader>ve` | Vault: Edit | Markdown |
| `<leader>vf` | Vault: Find | Markdown |
| `<leader>vg` | Vault: Tags | Markdown |
| `<leader>vk` | Vault: Block IDs | Markdown |
| `<leader>vm` | Vault: Meta Edit | Markdown |
| `<leader>vq` | Vault: Query | Markdown |
| `<leader>vt` | Vault: Templates | Global |
| `<leader>vx` | Vault: Tasks | Markdown |
| `<leader>x` | Trouble/Diagnostics | Global |

---

*Generated from `~/.config/nvim` — 300+ keybindings across 40+ source files.*
