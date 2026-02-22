# Neovim Keymaps Guide

> **Leader key:** `<Space>`
> Auto-generated from config at `~/.config/nvim/`

---

## Table of Contents

- [Core](#core)
- [Splits & Tabs](#splits--tabs)
- [Floating Terminal](#floating-terminal)
- [Fuzzy Finder (fzf-lua)](#fuzzy-finder-fzf-lua)
- [File Explorer (Yazi)](#file-explorer-yazi)
- [LSP](#lsp)
- [Trouble (Diagnostics)](#trouble-diagnostics)
- [Linting](#linting)
- [Git (Gitsigns)](#git-gitsigns)
- [Comment](#comment)
- [Surround](#surround)
- [Substitute](#substitute)
- [TODO Comments](#todo-comments)
- [Build System (Make)](#build-system-make)
- [Rust Development](#rust-development)
- [AI Assistant (OpenCode)](#ai-assistant-opencode)
- [Window Management](#window-management)
- [Markdown Editing](#markdown-editing)
- [LaTeX Editing](#latex-editing)
- [Vault — Templates](#vault--templates)
- [Vault — File Search](#vault--file-search)
- [Vault — Frecency & Recent](#vault--frecency--recent)
- [Vault — Backlinks & Wikilinks](#vault--backlinks--wikilinks)
- [Vault — Navigation (Daily/Weekly)](#vault--navigation-dailyweekly)
- [Vault — Outline & Tags](#vault--outline--tags)
- [Vault — Pins/Bookmarks](#vault--pinsbookmarks)
- [Vault — Graph View](#vault--graph-view)
- [Vault — File Operations](#vault--file-operations)
- [Vault — Metadata Editing](#vault--metadata-editing)
- [Vault — Link Checking](#vault--link-checking)
- [Vault — Block IDs](#vault--block-ids)
- [Vault — Saved Searches](#vault--saved-searches)
- [Vault — Tasks](#vault--tasks)
- [Vault — Preview](#vault--preview)
- [Vault — Images](#vault--images)
- [Vault — Extract](#vault--extract)
- [Vault — Fragments](#vault--fragments)
- [Vault — Export](#vault--export)
- [Vault — Footnotes](#vault--footnotes)
- [Vault — Capture](#vault--capture)
- [Vault — Calendar](#vault--calendar)
- [Vault — Project Picker](#vault--project-picker)
- [Which-Key Groups](#which-key-groups)

---

## Core

*File: `lua/andrew/core/keymaps.lua`*

| Mode | Key | Action |
|------|-----|--------|
| i | `jk` | Exit insert mode |
| n | `<leader>nh` | Clear search highlights |
| n | `<leader>+` | Increment number under cursor |
| n | `<leader>-` | Decrement number under cursor |

---

## Splits & Tabs

*File: `lua/andrew/core/keymaps.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>sv` | Split window vertically |
| n | `<leader>sh` | Split window horizontally |
| n | `<leader>se` | Equalize split sizes |
| n | `<leader>sx` | Close current split |
| n | `<leader>sm` | Maximize/minimize current split |
| n | `<leader>to` | Open new tab |
| n | `<leader>tx` | Close current tab |
| n | `<leader>tn` | Next tab |
| n | `<leader>tp` | Previous tab |
| n | `<leader>tf` | Open current buffer in new tab |

---

## Floating Terminal

*File: `lua/andrew/custom/plugins/terminal.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>tt` | Toggle floating terminal |
| t | `<C-\><C-n>` | Exit terminal mode |
| t | `jk` | Exit terminal mode |

---

## Fuzzy Finder (fzf-lua)

*File: `lua/andrew/plugins/fzf-lua.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>ff` | Find files |
| n | `<leader>fr` | Find recently opened files |
| n | `<leader>fs` | Live grep (search in files) |
| n | `<leader>fc` | Grep word under cursor |
| n | `<leader>fk` | Search keybindings |
| n | `<leader>fh` | Search :help tags |
| n | `<leader>fH` | Grep Neovim :help documentation |
| n | `<leader>ft` | Find TODO/FIXME comments |

---

## File Explorer (Yazi)

*File: `lua/andrew/plugins/yazi.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>ee` | Toggle file explorer |
| n | `<leader>ef` | Open explorer on current file |
| n | `<leader>ec` | Close explorer |
| n | `<leader>er` | Refresh explorer |

---

## LSP

*File: `lua/andrew/plugins/lsp/lspconfig.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `gR` | Show references |
| n | `gD` | Go to declaration |
| n | `gd` | Go to definition |
| n | `gi` | Show implementations |
| n | `gt` | Show type definitions |
| n/v | `<leader>ca` | Code actions |
| n | `<leader>rn` | Smart rename |
| n | `<leader>D` | Buffer diagnostics (fzf) |
| n | `<leader>d` | Line diagnostics float |
| n | `[d` | Previous diagnostic |
| n | `]d` | Next diagnostic |
| n | `K` | Hover documentation |
| n/i | `<C-k>` | Signature help |
| n | `<leader>rs` | Restart LSP |

---

## Trouble (Diagnostics)

*File: `lua/andrew/plugins/trouble.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>xw` | Workspace diagnostics |
| n | `<leader>xd` | Document diagnostics |
| n | `<leader>xe` | Errors only (current file) |
| n | `<leader>xE` | Errors only (workspace) |
| n | `<leader>xq` | Quickfix list |
| n | `<leader>xl` | Location list |
| n | `<leader>xt` | TODO comments |
| n | `<leader>xf` | fzf results in Trouble |
| n | `<leader>xF` | fzf file results in Trouble |

---

## Linting

*File: `lua/andrew/plugins/linting.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>ll` | Run linters for current buffer |
| n | `<leader>lm` | Run ruff (Python) |
| n | `<leader>lf` | Toggle Fortran linter |
| n | `<leader>lF` | Debug linter config |
| n | `<leader>lw` | Workspace lint (Fortran) |
| n | `<leader>lW` | Show workspace lint results |

---

## Git (Gitsigns)

*File: `lua/andrew/plugins/gitsigns.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `]g` | Next git hunk |
| n | `[g` | Previous git hunk |
| n | `<leader>hs` | Stage hunk |
| n | `<leader>hr` | Reset hunk |
| v | `<leader>hs` | Stage hunk (visual selection) |
| v | `<leader>hr` | Reset hunk (visual selection) |
| n | `<leader>hS` | Stage entire buffer |
| n | `<leader>hR` | Reset entire buffer |
| n | `<leader>hu` | Undo stage hunk |
| n | `<leader>hp` | Preview hunk |
| n | `<leader>hb` | Blame current line |
| n | `<leader>hB` | Toggle line blame |
| n | `<leader>hd` | Diff this |
| n | `<leader>hD` | Diff against parent |
| o/x | `ih` | Select git hunk (text object) |

---

## Comment

*File: `lua/andrew/plugins/comment.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `gc{motion}` | Toggle comment with motion (e.g. `gcap` = paragraph) |
| n | `gcc` | Toggle comment on current line |
| n | `gbc` | Block comment with motion |

---

## Surround

*File: `lua/andrew/plugins/surround.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `ys{motion}{char}` | Add surround (e.g. `ysiw"` wraps word in quotes) |
| n | `yss{char}` | Surround entire line |
| n | `yS{char}` | Surround to end of line |
| n | `cs{old}{new}` | Change surround (e.g. `cs"'` changes `"` to `'`) |
| n | `ds{char}` | Delete surround (e.g. `ds"` removes quotes) |
| v | `S{char}` | Surround visual selection |
| n | `ys{motion}e` | Surround with LaTeX `\begin{env}...\end{env}` |
| n | `ys{motion}c` | Surround with LaTeX `\cmd{}` |

---

## Substitute

*File: `lua/andrew/plugins/substitute.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `s{motion}` | Substitute with motion (paste over) |
| n | `ss` | Substitute entire line |
| n | `S` | Substitute to end of line |
| x | `s` | Substitute visual selection |

---

## TODO Comments

*File: `lua/andrew/plugins/todo-comments.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `]t` | Next TODO/FIXME comment |
| n | `[t` | Previous TODO/FIXME comment |

---

## Build System (Make)

*File: `lua/andrew/plugins/fortran-build.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>mb` | Build (pick Makefile) |
| n | `<leader>md` | Build Debug (pick Makefile) |
| n | `<leader>mc` | Clean (pick Makefile) |
| n | `<leader>mr` | Run (pick Makefile) |
| n | `<leader>ma` | All (pick Makefile) |
| n | `<leader>ml` | Re-run last Makefile command |

---

## Rust Development

*File: `lua/andrew/plugins/rustaceanvim.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>ca` | Rust code actions |
| n | `K` | Rust hover actions |
| n | `<leader>rr` | Run (runnables) |
| n | `<leader>rd` | Debug (debuggables) |
| n | `<leader>rt` | Test (testables) |
| n | `<leader>rm` | Expand macro |
| n | `<leader>rc` | Open Cargo.toml |
| n | `<leader>rp` | Go to parent module |
| n | `J` | Join lines (Rust-aware) |
| n | `<leader>re` | Explain error |
| n | `<leader>rD` | Render diagnostics |
| n | `<leader>dt` | Debugger testables |

---

## AI Assistant (OpenCode)

*File: `lua/andrew/plugins/opencode.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>ot` | Toggle OpenCode panel |
| n | `<leader>oa` | Ask about code at cursor |
| v | `<leader>oa` | Ask about selected code |
| n | `<leader>o+` | Add current buffer to prompt |
| v | `<leader>o+` | Add selection to prompt |
| n | `<leader>oe` | Explain code at cursor |
| n | `<leader>on` | New session |
| n | `<S-C-u>` | Scroll messages up |
| n | `<S-C-d>` | Scroll messages down |
| n/v | `<leader>os` | Select prompt |

---

## Window Management

*File: `lua/andrew/plugins/vim-maximizer.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>sm` | Maximize/minimize current split |

---

## Markdown Editing

*File: `ftplugin/markdown.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<Tab>` | Toggle fold under cursor |
| n | `<leader>mf` | Fold all headings |
| n | `<leader>mu` | Unfold all headings |
| n | `<leader>ml` | Set fold level |
| n | `]h` | Next heading (any level) |
| n | `[h` | Previous heading (any level) |
| n | `]1` – `]6` | Next heading at level 1–6 |
| n | `[1` – `[6` | Previous heading at level 1–6 |
| n | `<leader>mx` | Cycle checkbox state |
| n | `<leader>mz` | Toggle callout fold (render-markdown) |

---

## LaTeX Editing

*File: `ftplugin/tex.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `j` / `k` | Move by visual line (for wrapped text) |
| n | `<Tab>` | Toggle fold |
| n | `<leader>mf` | Fold all |
| n | `<leader>mu` | Unfold all |

---

## Vault — Templates

*File: `lua/andrew/vault/init.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vtn` | New note (template picker) |
| n | `<leader>vtd` | New daily log |
| n | `<leader>vtw` | New weekly review |
| n | `<leader>vts` | New simulation note |
| n | `<leader>vta` | New analysis note |
| n | `<leader>vtk` | New task note |
| n | `<leader>vtm` | New meeting note |
| n | `<leader>vtf` | New finding note |
| n | `<leader>vtl` | New literature note |
| n | `<leader>vtp` | New project dashboard |
| n | `<leader>vtj` | New journal entry |
| n | `<leader>vtc` | New concept note |
| n | `<leader>vtM` | New monthly review |
| n | `<leader>vtQ` | New quarterly review |
| n | `<leader>vtY` | New yearly review |
| n | `<leader>vV` | Switch vault |

---

## Vault — File Search

*File: `lua/andrew/vault/search.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vfs` | Search all vault files |
| n | `<leader>vfn` | Search notes only |
| n | `<leader>vfD` | Search filtered by scope |
| n | `<leader>vfy` | Search by note type |

---

## Vault — Frecency & Recent

*Files: `lua/andrew/vault/fzf-lua.lua`, `lua/andrew/vault/recent.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vff` | Find files (frecency-sorted) |
| n | `<leader>vfr` | Find recent files |

---

## Vault — Backlinks & Wikilinks

*Files: `lua/andrew/vault/backlinks.lua`, `lua/andrew/vault/wikilinks.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `gf` | Follow wikilink under cursor |
| n | `gx` | Follow wikilink under cursor |
| n | `]o` | Next wikilink in buffer |
| n | `[o` | Previous wikilink in buffer |
| n | `<leader>vfb` | Find backlinks to current note |
| n | `<leader>vfl` | Find forward links from current note |
| n | `<leader>vfh` | Find link hierarchy |

---

## Vault — Navigation (Daily/Weekly)

*File: `lua/andrew/vault/navigate.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vfd` | Find daily logs |
| n | `<leader>vfw` | Find weekly reviews |
| n | `<leader>vfW` | Find weekly review by date |
| n | `<leader>v[` | Previous daily log |
| n | `<leader>v]` | Next daily log |
| n | `<leader>v{` | Previous week's review |
| n | `<leader>v}` | Next week's review |
| n | `<leader>vC` | Open calendar picker |

---

## Vault — Outline & Tags

*Files: `lua/andrew/vault/outline.lua`, `lua/andrew/vault/tags.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vfo` | Find outline (headings in current note) |
| n | `<leader>vft` | Find notes by tag |
| n | `<leader>vga` | Add tag to current note |
| n | `<leader>vgr` | Remove tag from current note |

---

## Vault — Pins/Bookmarks

*File: `lua/andrew/vault/pins.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vbp` | Pin/unpin current note |
| n | `<leader>vbf` | Find pinned notes |

---

## Vault — Graph View

*File: `lua/andrew/vault/graph.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vG` | Open local graph view |
| n | `<CR>` | *(in graph)* Open selected note |
| n | `gf` | *(in graph)* Follow link |

---

## Vault — File Operations

*Files: `lua/andrew/vault/rename.lua`, `lua/andrew/vault/autofile.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>ver` | Rename current file |
| n | `<leader>veR` | Rename with link refactoring |
| n | `<leader>vet` | Auto-file by type (move to correct folder) |
| n | `<leader>vmv` | Move file to a folder |

---

## Vault — Metadata Editing

*File: `lua/andrew/vault/metaedit.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vms` | Edit note status |
| n | `<leader>vmp` | Edit parent project |
| n | `<leader>vmm` | Edit modified date |
| n | `<leader>vmt` | Edit note type |
| n | `<leader>vmf` | Edit frontmatter tags |

---

## Vault — Link Checking

*Files: `lua/andrew/vault/linkcheck.lua`, `lua/andrew/vault/linkdiag.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vcb` | Check links in current buffer |
| n | `<leader>vca` | Check all vault links |
| n | `<leader>vco` | Open link check results |
| n | `<leader>vcd` | Toggle link diagnostics |
| n | `<leader>vcf` | Fix broken link |
| n | `<leader>vcF` | Fix links (picker) |

---

## Vault — Block IDs

*File: `lua/andrew/vault/blockid.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vki` | Generate block ID for current line |
| n | `<leader>vkl` | Insert link to a block ID |

---

## Vault — Saved Searches

*File: `lua/andrew/vault/saved_searches.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vfS` | Load a saved search |

---

## Vault — Tasks

*Files: `lua/andrew/vault/tasks.lua`, `lua/andrew/vault/quicktask.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vxo` | Open all tasks |
| n | `<leader>vxa` | Add quick task |
| n | `<leader>vxs` | Sync task state |
| n | `<leader>vxq` | Quick task capture |

---

## Vault — Preview

*File: `lua/andrew/vault/preview.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `K` | *(in preview)* Open wikilink in preview |
| n | `<leader>vE` | *(in preview)* Export preview to note |
| n | `<C-j>` | *(in preview)* Scroll down |
| n | `<C-k>` | *(in preview)* Scroll up |
| n | `q` | *(in preview)* Save and close |
| n/i | `<C-s>` | *(in preview)* Save |

---

## Vault — Images

*File: `lua/andrew/vault/images.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vp` | Paste image from clipboard |

---

## Vault — Extract

*File: `lua/andrew/vault/extract.lua`*

| Mode | Key | Action |
|------|-----|--------|
| v | `<leader>vex` | Extract selection to new note |

---

## Vault — Fragments

*File: `lua/andrew/vault/fragments.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vI` | Insert template fragment |

---

## Vault — Export

*File: `lua/andrew/vault/export.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vep` | Export current note to PDF |

---

## Vault — Footnotes

*File: `lua/andrew/vault/footnotes.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>mj` | Jump to footnote |
| n | `<leader>mn` | Create new footnote |

---

## Vault — Capture

*File: `lua/andrew/vault/capture.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<CR>` | *(in capture window)* Save and close |
| n | `q` | *(in capture window)* Cancel |
| n | `<Esc>` | *(in capture window)* Cancel |

---

## Vault — Calendar

*File: `lua/andrew/vault/calendar.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `q` / `<Esc>` | Close calendar |
| n | `<CR>` | Open selected day's log |
| n | `h` / `l` | Previous / next month |
| n | `H` / `L` | Previous / next year |
| n | `j` / `k` | Next / previous week |

---

## Vault — Project Picker

*File: `lua/andrew/vault/pickers.lua`*

| Mode | Key | Action |
|------|-----|--------|
| n | `<leader>vfp` | Pick project |
| n | `<leader>vP` | Cycle project |

---

## Which-Key Groups

Press `<leader>` and wait to see all top-level groups:

| Prefix | Group |
|--------|-------|
| `<leader>a` | Type Check |
| `<leader>c` | Code Actions |
| `<leader>d` | Debug |
| `<leader>e` | Explorer |
| `<leader>f` | Find / Files |
| `<leader>g` | Git |
| `<leader>h` | Git Hunks |
| `<leader>l` | Lint |
| `<leader>m` | Make / Build |
| `<leader>o` | OpenCode (AI) |
| `<leader>r` | Rust / Refactor |
| `<leader>s` | Split / Window |
| `<leader>t` | Tab / Terminal |
| `<leader>v` | Vault |
| `<leader>vt` | Vault: Templates |
| `<leader>vf` | Vault: Find |
| `<leader>vq` | Vault: Query |
| `<leader>ve` | Vault: Edit |
| `<leader>vx` | Vault: Tasks |
| `<leader>vc` | Vault: Check |
| `<leader>x` | Trouble / Diagnostics |

---

**Tip:** Press `<leader>fk` to fuzzy-search all keybindings interactively within Neovim.

**Total keybindings: 250+**
