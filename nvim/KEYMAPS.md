# Neovim Keymaps — Complete Reference

> **Leader Key:** `<Space>` | **Config:** `~/.config/nvim/`
> **Tip:** Press `<leader>fk` to fuzzy-search all keybindings at runtime via fzf-lua.

---

## Table of Contents

- [Core](#core)
- [Window Management](#window-management)
- [Tab Management](#tab-management)
- [Terminal](#terminal)
- [File Explorer (Yazi)](#file-explorer-yazi)
- [Fuzzy Finding (fzf-lua)](#fuzzy-finding-fzf-lua)
- [Completion (blink-cmp)](#completion-blink-cmp)
- [Treesitter](#treesitter)
- [LSP](#lsp)
- [Diagnostics (Trouble)](#diagnostics-trouble)
- [Git (gitsigns)](#git-gitsigns)
- [Debug (DAP)](#debug-dap)
- [Rust (rustaceanvim)](#rust-rustaceanvim)
- [Type Checking](#type-checking)
- [Linting](#linting)
- [Make / Build](#make--build)
- [Comment](#comment)
- [Surround](#surround)
- [Substitute](#substitute)
- [Table Mode](#table-mode)
- [Todo Comments](#todo-comments)
- [OpenCode AI](#opencode-ai)
- [Vim Maximizer](#vim-maximizer)
- [Markdown-Specific](#markdown-specific)
- [TeX / LaTeX-Specific](#tex--latex-specific)
- [Vault System](#vault-system)
  - [Templates](#vault-templates)
  - [Find / Search](#vault-find--search)
  - [Navigation](#vault-navigation)
  - [Wikilinks](#vault-wikilinks)
  - [Backlinks](#vault-backlinks)
  - [Tasks](#vault-tasks)
  - [Edit / Rename](#vault-edit--rename)
  - [Meta / Frontmatter](#vault-meta--frontmatter)
  - [Block IDs / Pins](#vault-block-ids--pins)
  - [Tags](#vault-tags)
  - [Query / Dataview](#vault-query--dataview)
  - [Check / Link Diagnostics](#vault-check--link-diagnostics)
  - [Capture](#vault-capture)
  - [Graph](#vault-graph)
  - [Preview](#vault-preview)
  - [Calendar](#vault-calendar)
  - [Images / Fragments / Footnotes](#vault-images--fragments--footnotes)
  - [Other Vault](#vault-other)
- [FZF Internal Keymaps](#fzf-internal-keymaps)
- [User Commands](#user-commands)
- [Which-Key Groups](#which-key-groups)
- [Bracket Navigation Summary](#bracket-navigation-summary)
- [Snippet Triggers](#snippet-triggers)
  - [Fortran Snippets](#fortran-snippets)
  - [Markdown Snippets (JSON)](#markdown-snippets-json)
  - [Markdown Snippets (LuaSnip)](#markdown-snippets-luasnip)
  - [TeX / LaTeX Snippets (LuaSnip)](#tex--latex-snippets-luasnip)
  - [Math-Mode Autosnippets](#math-mode-autosnippets)

---

## Core

**Source:** `lua/andrew/core/keymaps.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| i | `jk` | `<ESC>` | Exit insert mode |
| n | `<leader>nh` | `:nohl<CR>` | Clear search highlights |
| n | `<leader>+` | `<C-a>` | Increment number under cursor |
| n | `<leader>-` | `<C-x>` | Decrement number under cursor |

---

## Window Management

**Source:** `lua/andrew/core/keymaps.lua` | **Group:** `<leader>s` (Split/Window)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>sv` | `<C-w>v` | Split window vertically |
| n | `<leader>sh` | `<C-w>s` | Split window horizontally |
| n | `<leader>se` | `<C-w>=` | Make all splits equal size |
| n | `<leader>sx` | `:close<CR>` | Close current split |
| n | `<leader>sm` | `:MaximizerToggle<CR>` | Maximize/minimize current split |

---

## Tab Management

**Source:** `lua/andrew/core/keymaps.lua` | **Group:** `<leader>t` (Tab/Terminal)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>to` | `:tabnew<CR>` | Open new tab |
| n | `<leader>tx` | `:tabclose<CR>` | Close current tab |
| n | `<leader>tn` | `:tabn<CR>` | Next tab |
| n | `<leader>tp` | `:tabp<CR>` | Previous tab |
| n | `<leader>tf` | `:tabnew %<CR>` | Open current buffer in new tab |

---

## Terminal

**Source:** `lua/andrew/core/keymaps.lua`, floating terminal plugin

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>tt` | Toggle floating terminal | Toggle floating terminal visibility |
| t | `<C-\><C-n>` | Exit terminal mode | Return to normal mode from terminal |
| t | `jk` | Exit terminal mode | Return to normal mode (alternate) |

**User commands:** `:FloatingTerminal toggle|open|hide|close|restart|send <cmd>`

---

## File Explorer (Yazi)

**Source:** `lua/andrew/plugins/yazi.lua` | **Group:** `<leader>e` (Explorer)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>ee` | `yazi.yazi()` | Toggle file explorer |
| n | `<leader>ef` | `yazi.yazi({path=file})` | Open explorer at current file |
| n | `<leader>ec` | `:close` | Close explorer window |
| n | `<leader>er` | `yazi.yazi()` | Refresh explorer |

**Inside Yazi:** `<f1>` = help, `<C-s>` = grep with fzf-lua

---

## Fuzzy Finding (fzf-lua)

**Source:** `lua/andrew/plugins/fzf-lua.lua` | **Group:** `<leader>f` (Find/Files)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>ff` | `fzf.files()` | Find files in cwd |
| n | `<leader>fr` | `fzf.oldfiles()` | Find recently opened files |
| n | `<leader>fs` | `fzf.live_grep()` | Live grep in cwd |
| n | `<leader>fc` | `fzf.grep_cword()` | Grep word under cursor |
| n | `<leader>fk` | `fzf.keymaps()` | Search all keybindings |
| n | `<leader>fh` | `fzf.help_tags()` | Search :help tags |
| n | `<leader>fH` | `fzf.live_grep()` on help docs | Grep :help documentation |
| n | `<leader>ft` | `:TodoFzfLua<CR>` | Find TODO/FIXME comments |

---

## Completion (blink-cmp)

**Source:** `lua/andrew/plugins/blink-cmp.lua` | Insert mode only

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| i | `<C-p>` | Select previous | Select previous completion item |
| i | `<C-n>` | Select next | Select next completion item |
| i | `<C-k>` | Scroll docs up | Scroll documentation window up |
| i | `<C-j>` | Scroll docs down | Scroll documentation window down |
| i | `<C-Space>` | Show completion | Manually trigger completion menu |
| i | `<C-e>` | Hide completion | Dismiss completion menu |
| i | `<CR>` | Accept | Accept selected completion |

---

## Treesitter

**Source:** `lua/andrew/plugins/treesitter.lua`, `lua/andrew/plugins/treesitter-context.lua`

### Incremental Selection

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<C-space>` | Init selection | Start treesitter incremental selection |
| n, x | `<C-space>` | Increment node | Expand selection to next syntax node |
| n, x | `<bs>` | Decrement node | Shrink selection to previous syntax node |

### Context

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `[c` | Jump to context | Jump to parent scope / treesitter context |

---

## LSP

**Source:** `lua/andrew/plugins/lsp/lspconfig.lua` | Attached via `LspAttach` autocommand (buffer-local)

### Navigation

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `gR` | `fzf.lsp_references()` | Show LSP references |
| n | `gD` | `vim.lsp.buf.declaration()` | Go to declaration (fallback: definition) |
| n | `gd` | `fzf.lsp_definitions()` | Go to definition |
| n | `gi` | `fzf.lsp_implementations()` | Show implementations |
| n | `gt` | `fzf.lsp_typedefs()` | Show type definitions |

### Code Actions

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n, v | `<leader>ca` | `vim.lsp.buf.code_action` | See available code actions |
| n | `<leader>rn` | `vim.lsp.buf.rename` | Smart rename |

### Diagnostics

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>D` | `fzf.diagnostics_document()` | Show buffer diagnostics |
| n | `<leader>d` | `vim.diagnostic.open_float` | Show line diagnostics |
| n | `[d` | `vim.diagnostic.goto_prev` | Previous diagnostic |
| n | `]d` | `vim.diagnostic.goto_next` | Next diagnostic |

### Documentation

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `K` | `vim.lsp.buf.hover` | Show hover documentation (Fortran: custom docs) |
| n, i | `<C-k>` | `vim.lsp.buf.signature_help` | Show signature help (Python: ty LSP preferred) |

### Management

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>rs` | `:LspRestart<CR>` | Restart LSP server |

---

## Diagnostics (Trouble)

**Source:** `lua/andrew/plugins/trouble.lua` | **Group:** `<leader>x` (Trouble/Diagnostics)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>xw` | Trouble workspace diagnostics | Workspace diagnostics (floating preview) |
| n | `<leader>xd` | Trouble current file diagnostics | Current file diagnostics |
| n | `<leader>xe` | Trouble errors (current file) | Errors only (current file) |
| n | `<leader>xE` | Trouble errors (workspace) | Errors only (workspace) |
| n | `<leader>xq` | Trouble quickfix | Open quickfix list |
| n | `<leader>xl` | Trouble loclist | Open location list |
| n | `<leader>xt` | Trouble todo | Open TODO comments |
| n | `<leader>xf` | Trouble fzf | Open fzf-lua results in Trouble |
| n | `<leader>xF` | Trouble fzf_files | Open fzf-lua file results in Trouble |

---

## Git (gitsigns)

**Source:** `lua/andrew/plugins/gitsigns.lua` | **Group:** `<leader>h` (Git Hunks) | Attached via `on_attach`

### Hunk Navigation

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `]g` | Next hunk | Go to next git hunk |
| n | `[g` | Previous hunk | Go to previous git hunk |

### Hunk Actions

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>hs` | `gs.stage_hunk` | Stage hunk |
| v | `<leader>hs` | `gs.stage_hunk` (selection) | Stage hunk (visual) |
| n | `<leader>hr` | `gs.reset_hunk` | Reset hunk |
| v | `<leader>hr` | `gs.reset_hunk` (selection) | Reset hunk (visual) |
| n | `<leader>hS` | `gs.stage_buffer` | Stage entire buffer |
| n | `<leader>hR` | `gs.reset_buffer` | Reset entire buffer |
| n | `<leader>hu` | `gs.undo_stage_hunk` | Undo last staged hunk |
| n | `<leader>hp` | `gs.preview_hunk` | Preview hunk inline |

### Blame & Diff

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>hb` | `gs.blame_line({full=true})` | Show full blame for line |
| n | `<leader>hB` | `gs.toggle_current_line_blame` | Toggle inline blame |
| n | `<leader>hd` | `gs.diffthis` | Diff current file |
| n | `<leader>hD` | `gs.diffthis("~")` | Diff against parent |

### Text Objects

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| o, x | `ih` | Select hunk | Gitsigns hunk text object |

---

## Debug (DAP)

**Source:** `lua/andrew/plugins/dap/dap.lua`, `lua/andrew/plugins/dap/dap-ui.lua` | **Group:** `<leader>d` (Debug)

### Control

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>dc` | `dap.continue()` | Start / Continue debugging |
| n | `<leader>do` | `dap.step_over()` | Step over |
| n | `<leader>di` | `dap.step_into()` | Step into |
| n | `<leader>dO` | `dap.step_out()` | Step out |
| n | `<leader>dC` | `dap.run_to_cursor()` | Run to cursor |
| n | `<leader>dr` | `dap.restart()` | Restart debugging |
| n | `<leader>dt` | `dap.terminate()` | Terminate debugging |

### Breakpoints

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>db` | `dap.toggle_breakpoint()` | Toggle breakpoint |
| n | `<leader>dB` | `dap.set_breakpoint(condition)` | Set conditional breakpoint |

### UI

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>du` | `dapui.toggle()` | Toggle DAP UI |
| n, v | `<leader>de` | `dapui.eval()` | Evaluate expression |
| n | `<leader>df` | `dapui.float_element()` | Float element |
| n | `<leader>dR` | `dap.repl.toggle()` | Toggle REPL |

---

## Rust (rustaceanvim)

**Source:** `lua/andrew/plugins/rustaceanvim.lua` | **Group:** `<leader>r` (Rust/Refactor) | Rust files only (via `on_attach`)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>ca` | `RustLsp codeAction` | Rust code actions (overrides LSP) |
| n | `K` | `RustLsp hover actions` | Rust hover with actions (overrides LSP) |
| n | `J` | `RustLsp joinLines` | Join lines (Rust-aware) |
| n | `<leader>rr` | `RustLsp runnables` | Run (main, examples, etc.) |
| n | `<leader>rd` | `RustLsp debuggables` | Debug with DAP |
| n | `<leader>rt` | `RustLsp testables` | Run tests |
| n | `<leader>rm` | `RustLsp expandMacro` | Expand macro recursively |
| n | `<leader>rc` | `RustLsp openCargo` | Open Cargo.toml |
| n | `<leader>rp` | `RustLsp parentModule` | Go to parent module |
| n | `<leader>re` | `RustLsp explainError` | Explain error |
| n | `<leader>rD` | `RustLsp renderDiagnostic` | Render diagnostics |
| n | `<leader>dt` | `RustLsp testables` | Debug testables |

---

## Type Checking

**Source:** `lua/andrew/plugins/type-checker.lua` | **Group:** `<leader>a` (Type Check)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>ac` | Dispatch by filetype | Type check (auto-detect language) |
| n | `<leader>aP` | Ruff check | Python type check (ruff) |
| n | `<leader>aT` | Ty check | Python type check (ty) |
| n | `<leader>aR` | `cargo check` | Rust project check |
| n | `<leader>aL` | lua-language-server --check | Lua project check |
| n | `<leader>aF` | Fortran compiler check | Fortran type check (current compiler) |
| n | `<leader>aC` | C/C++ syntax & warnings | C/C++ check |
| n | `<leader>ag` | mpif90/gfortran check | Fortran check (GNU) |
| n | `<leader>ai` | mpiifx check | Fortran check (Intel) |
| n | `<leader>at` | Toggle Fortran compiler | Toggle between mpif90 and mpiifx |

---

## Linting

**Source:** `lua/andrew/plugins/linting.lua` | **Group:** `<leader>l` (Lint)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>ll` | `lint.try_lint()` | Run linters for current buffer |
| n | `<leader>lm` | `lint.try_lint("ruff")` | Run ruff (Python) |
| n | `<leader>lf` | Toggle Fortran linter | Toggle Fortran compiler linter |
| n | `<leader>lF` | Run Fortran linter (debug) | Run Fortran linter with debug output |
| n | `<leader>lw` | Lint Fortran workspace | Lint entire Fortran workspace |
| n | `<leader>lW` | Clear workspace diagnostics | Clear Fortran workspace diagnostics |

---

## Make / Build

**Source:** `lua/andrew/plugins/fortran-build.lua` | **Group:** `<leader>m` (Make/Build)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>mb` | Pick Makefile + build | Make: Build |
| n | `<leader>md` | Pick Makefile + debug build | Make: Build Debug |
| n | `<leader>mc` | Pick Makefile + clean | Make: Clean |
| n | `<leader>mr` | Pick Makefile + run | Make: Run |
| n | `<leader>ma` | Pick Makefile + all | Make: All |
| n | `<leader>ml` | Re-run last Makefile target | Make: Re-run last |

---

## Comment

**Source:** `lua/andrew/plugins/comment.lua` (Comment.nvim defaults)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `gcc` | Toggle line comment | Comment/uncomment current line |
| n | `gc{motion}` | Toggle comment with motion | Comment/uncomment by motion (e.g., `gcip`) |
| n | `gbc` | Toggle block comment | Block comment current line |
| v | `gc` | Toggle comment (selection) | Comment/uncomment visual selection |
| v | `gb` | Toggle block comment (selection) | Block comment visual selection |

---

## Surround

**Source:** `lua/andrew/plugins/surround.lua` (nvim-surround)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `ys{motion}{char}` | Add surround | e.g., `ysiw"` wraps word in quotes |
| n | `yss{char}` | Add surround to line | Surround entire line |
| n | `cs{old}{new}` | Change surround | e.g., `cs"'` changes `"` to `'` |
| n | `ds{char}` | Delete surround | e.g., `ds"` removes surrounding quotes |
| v | `S{char}` | Surround selection | Wrap visual selection |

### LaTeX Custom Surrounds

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `yse` | Add LaTeX environment | Wrap with `\begin{env}...\end{env}` |
| n | `ysiwc` | Add LaTeX command | Wrap with `\cmd{}` |

---

## Substitute

**Source:** `lua/andrew/plugins/substitute.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `s{motion}` | Substitute with motion | e.g., `siw` substitutes inner word |
| n | `ss` | Substitute line | Substitute entire line |
| n | `S` | Substitute to EOL | Substitute from cursor to end of line |
| x | `s` | Substitute selection | Substitute visual selection |

---

## Table Mode

**Source:** `lua/andrew/plugins/vim-table-mode.lua` (Markdown files)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>Tm` | `:TableModeToggle` | Toggle table mode on/off |
| any | `Tab` | Next cell | Move to next table cell (when table mode on) |
| any | `\|\|` | Separator row | Creates horizontal separator row |

---

## Todo Comments

**Source:** `lua/andrew/plugins/todo-comments.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `]t` | `todo_comments.jump_next()` | Jump to next TODO/FIXME |
| n | `[t` | `todo_comments.jump_prev()` | Jump to previous TODO/FIXME |

---

## OpenCode AI

**Source:** `lua/andrew/plugins/opencode.lua` | **Group:** `<leader>o` (OpenCode)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>ot` | `opencode.toggle()` | Toggle OpenCode panel |
| n | `<leader>oa` | `opencode.ask("@cursor: ")` | Ask about code at cursor |
| v | `<leader>oa` | `opencode.ask("@selection: ")` | Ask about selected code |
| n | `<leader>o+` | `opencode.prompt("@buffer")` | Add buffer to prompt |
| v | `<leader>o+` | `opencode.prompt("@selection")` | Add selection to prompt |
| n | `<leader>oe` | `opencode.prompt("Explain @cursor")` | Explain code at cursor |
| n | `<leader>on` | `opencode.command("session_new")` | New OpenCode session |
| n | `<S-C-u>` | Scroll messages up | Scroll OpenCode messages up |
| n | `<S-C-d>` | Scroll messages down | Scroll OpenCode messages down |
| n, v | `<leader>os` | `opencode.select()` | Select OpenCode prompt |

---

## Vim Maximizer

**Source:** `lua/andrew/plugins/vim-maximizer.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>sm` | `:MaximizerToggle<CR>` | Maximize/minimize current split |

---

## Markdown-Specific

**Source:** `ftplugin/markdown.lua` | Buffer-local (markdown files only)

### Folding

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<Tab>` | `za` | Toggle fold at cursor |
| n | `<leader>mf` | `zM` | Fold all sections |
| n | `<leader>mu` | `zR` | Unfold all sections |
| n | `<leader>ml` | Set fold level (prompt) | Set custom fold level |

### Heading Navigation

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `]h` | Next heading | Jump to next heading (any level) |
| n | `[h` | Previous heading | Jump to previous heading (any level) |
| n | `]1` - `]6` | Next h{N} | Jump to next heading at level N |
| n | `[1` - `[6` | Previous h{N} | Jump to previous heading at level N |

### Checkboxes

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>mx` | Cycle checkbox | `[ ]` -> `[/]` -> `[x]` -> `[-]` -> `[>]` -> `[ ]` |

### Math Motions & Text Objects

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `]m` | Next math zone | Jump to next inline/display math |
| n | `[m` | Previous math zone | Jump to previous inline/display math |
| o, x | `am` | Around math | Select around math zone |
| o, x | `im` | Inner math | Select inner math zone |

### Callouts

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>mz` | Toggle callout fold | Fold/unfold callout block |

### Footnotes

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>mj` | Jump footnote ref/def | Jump between footnote reference and definition |
| n | `<leader>mn` | New footnote | Create new footnote / list all footnotes |

---

## TeX / LaTeX-Specific

**Source:** `ftplugin/tex.lua` | Buffer-local (TeX files only)

### Navigation

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `j` | `gj` | Down (visual line, for wrapped text) |
| n | `k` | `gk` | Up (visual line, for wrapped text) |

### Folding

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<Tab>` | `za` | Toggle fold |
| n | `<leader>mf` | `zM` | Fold all |
| n | `<leader>mu` | `zR` | Unfold all |

### LaTeX Motions & Text Objects

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n, x | `]]` / `[[` | Section motions | Jump to next/previous LaTeX section |
| n, x | `]e` / `[e` | Environment motions | Jump to next/previous environment |
| n, x | `]m` / `[m` | Math motions | Jump to next/previous math zone |
| o, x | `ae` / `ie` | Environment objects | Select around/inner environment |
| o, x | `am` / `im` | Math objects | Select around/inner math |
| o, x | `ac` / `ic` | Command objects | Select around/inner command |

---

## Vault System

All vault keymaps use the `<leader>v` prefix. Many are restricted to markdown files.

### Vault Templates

**Source:** `lua/andrew/vault/init.lua` | **Group:** `<leader>vt` (Templates)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vtn` | Template picker | Open template picker |
| n | `<leader>vtd` | Daily Log | Create daily log |
| n | `<leader>vtw` | Weekly Review | Create weekly review |
| n | `<leader>vts` | Simulation Note | Create simulation note |
| n | `<leader>vta` | Analysis Note | Create analysis note |
| n | `<leader>vtk` | Task Note | Create task note |
| n | `<leader>vtm` | Meeting Note | Create meeting note |
| n | `<leader>vtf` | Finding Note | Create finding note |
| n | `<leader>vtl` | Literature Note | Create literature note |
| n | `<leader>vtp` | Project Dashboard | Create project dashboard |
| n | `<leader>vtj` | Journal Entry | Create journal entry |
| n | `<leader>vtc` | Concept Note | Create concept note |
| n | `<leader>vtM` | Monthly Review | Create monthly review |
| n | `<leader>vtQ` | Quarterly Review | Create quarterly review |
| n | `<leader>vtY` | Yearly Review | Create yearly review |

### Vault Find / Search

**Source:** `lua/andrew/vault/search.lua`, `lua/andrew/vault/navigate.lua`, etc. | **Group:** `<leader>vf` (Find)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vff` | `fzf.files({cwd=vault})` | Find files in vault |
| n | `<leader>vfs` | `search.search()` | Live grep across vault |
| n | `<leader>vfn` | `search.search_notes()` | Live grep across markdown notes |
| n | `<leader>vfD` | `search.search_filtered()` | Search scoped by directory |
| n | `<leader>vfy` | `search.search_by_type()` | Search by frontmatter type |
| n | `<leader>vfd` | Daily log picker | List all daily logs |
| n | `<leader>vfw` | Weekly review picker | List all weekly reviews |
| n | `<leader>vfW` | All reviews list | List all reviews |
| n | `<leader>vfb` | Backlinks | Notes linking to current note |
| n | `<leader>vfl` | Forward links | Wikilinks in current note |
| n | `<leader>vfh` | Heading backlinks | Notes linking to headings |
| n | `<leader>vfp` | Project dashboards | Pick a project dashboard |
| n | `<leader>vfr` | Recent notes | Recently edited vault notes |
| n | `<leader>vft` | Tags | Browse vault tags |
| n | `<leader>vfo` | Outline | Heading outline of current buffer |
| n | `<leader>vfS` | Saved searches | List saved vault searches |

### Vault Navigation

**Source:** `lua/andrew/vault/navigate.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>v[` | Previous daily log | Navigate to previous day |
| n | `<leader>v]` | Next daily log | Navigate to next day |
| n | `<leader>v{` | Previous weekly review | Navigate to previous week |
| n | `<leader>v}` | Next weekly review | Navigate to next week |
| n | `<leader>vC` | Calendar picker | Open calendar view |

### Vault Wikilinks

**Source:** `lua/andrew/vault/wikilinks.lua` | Markdown files only (FileType autocommand)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `gf` | `follow_link()` | Follow wikilink / markdown link / URL |
| n | `gx` | `follow_link()` | Follow link (open in browser if URL) |
| n | `]o` | Next link | Jump to next wikilink in buffer |
| n | `[o` | Previous link | Jump to previous wikilink in buffer |

### Vault Backlinks

**Source:** `lua/andrew/vault/backlinks.lua` | Markdown files only

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vfb` | `backlinks.backlinks()` | Find incoming backlinks |
| n | `<leader>vfl` | `backlinks.forwardlinks()` | Find outgoing links |
| n | `<leader>vfh` | `backlinks.heading_backlinks()` | Find heading-level backlinks |

### Vault Tasks

**Source:** `lua/andrew/vault/tasks.lua`, `lua/andrew/vault/quicktask.lua` | **Group:** `<leader>vx` (Tasks)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vxo` | `tasks.tasks()` | Show open tasks across vault |
| n | `<leader>vxa` | `tasks.tasks_all()` | Show all tasks (any state) |
| n | `<leader>vxs` | `tasks.tasks_by_state()` | Filter tasks by checkbox state |
| n | `<leader>vxq` | `quicktask.quick_task()` | Quick task creation |

### Vault Edit / Rename

**Source:** `lua/andrew/vault/rename.lua`, `lua/andrew/vault/extract.lua` | **Group:** `<leader>ve` (Edit)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>ver` | `rename.rename_note()` | Rename current note + update wikilinks |
| n | `<leader>veR` | `rename.rename_preview()` | Preview rename (dry-run, no changes) |
| n | `<leader>vep` | `export.export_pdf()` | Export note to PDF |
| n | `<leader>vet` | `rename.rename_tag()` | Rename tag across vault |
| v | `<leader>vex` | `extract.extract()` | Extract selection to new note |
| n | `<leader>vE` | Edit in float | Edit linked note in floating window |

### Vault Meta / Frontmatter

**Source:** `lua/andrew/vault/metaedit.lua`, `lua/andrew/vault/autofile.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vms` | Cycle status | Cycle `status` field value |
| n | `<leader>vmp` | Cycle priority / parent-project | Cycle `priority` or toggle `parent-project` |
| n | `<leader>vmm` | Cycle maturity | Cycle `maturity` field value |
| n | `<leader>vmt` | Toggle draft / insert type | Toggle `draft` field or insert type picker |
| n | `<leader>vmf` | Set any field | Pick and set any frontmatter field |
| n | `<leader>vmv` | Auto-file note | Move note to expected directory by type |

### Vault Block IDs / Pins

**Source:** `lua/andrew/vault/blockid.lua`, `lua/andrew/vault/pins.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vki` | Generate block ID | Add block ID to current line |
| n | `<leader>vkl` | Block ID + link | Generate block ID and copy reference link |
| n | `<leader>vbp` | Toggle pin | Pin/unpin current note |
| n | `<leader>vbf` | Find pinned notes | List all pinned vault notes |

### Vault Tags

**Source:** `lua/andrew/vault/tags.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vft` | Tag picker | Browse and search vault tags |
| n | `<leader>vga` | Add tag | Add a tag to notes |
| n | `<leader>vgr` | Remove tag | Remove a tag from notes |

### Vault Query / Dataview

**Source:** `lua/andrew/vault/query/` | **Group:** `<leader>vq` (Query)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vqr` | Render query | Render vault query under cursor |
| n | `<leader>vqa` | Render all | Render all vault queries in buffer |
| n | `<leader>vqc` | Clear output | Clear rendered output under cursor |
| n | `<leader>vqx` | Clear all | Clear all rendered output in buffer |
| n | `<leader>vqq` | Toggle query | Toggle vault query output |
| n | `<leader>vqi` | Rebuild index | Rebuild vault query index |

### Vault Check / Link Diagnostics

**Source:** `lua/andrew/vault/linkdiag.lua`, `lua/andrew/vault/linkcheck.lua` | **Group:** `<leader>vc` (Check)

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vcd` | Toggle diagnostics | Toggle link diagnostics display |
| n | `<leader>vcf` | Fix link | Fix broken link under cursor |
| n | `<leader>vcF` | Fix all links | Fix all broken links (picker) |
| n | `<leader>vcb` | Check buffer | Check current buffer for broken links |
| n | `<leader>vca` | Check vault | Check entire vault for broken links |
| n | `<leader>vco` | Open issues / orphans | Find orphan notes or link issues |

### Vault Capture

**Source:** `lua/andrew/vault/capture.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vQ` | Quick capture to daily | Capture thought to today's daily log |
| n | `<leader>vi` | Capture to inbox | Capture thought to inbox |

**Inside capture window (buffer-local):**

| Key | Action |
|-----|--------|
| `<CR>` | Save and close |
| `q` / `<Esc>` | Close without saving |

### Vault Graph

**Source:** `lua/andrew/vault/graph.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vG` | Local graph | Open local graph view |

**Inside graph window:**

| Key | Action |
|-----|--------|
| `<CR>` / `gf` | Follow link to note |
| `q` / `<Esc>` | Close graph |

### Vault Preview

**Source:** `lua/andrew/vault/preview.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `K` | Preview wikilink | Preview linked note under cursor (markdown files) |
| n | `<leader>vE` | Edit in buffer | Open preview note in main buffer |

**Inside preview float:**

| Mode | Key | Action |
|------|-----|--------|
| n | `<C-j>` | Scroll preview down |
| n | `<C-k>` | Scroll preview up |
| n | `q` | Save and close |
| n | `<Esc><Esc>` | Save and close |
| n, i | `<C-s>` | Save edits |

### Vault Calendar

**Source:** `lua/andrew/vault/navigate.lua`

**Inside calendar view (buffer-local):**

| Key | Action |
|-----|--------|
| `<CR>` | Open selected day's log |
| `h` / `l` | Previous / next month |
| `H` / `L` | Previous / next year |
| `j` / `k` | Down / up one week |
| `q` / `<Esc>` | Close calendar |

### Vault Images / Fragments / Footnotes

**Source:** `lua/andrew/vault/images.lua`, `lua/andrew/vault/fragments.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vp` | Paste image | Paste image from clipboard (markdown) |
| n | `<leader>vI` | Insert fragment | Insert template fragment (markdown) |
| n | `<leader>vP` | Sticky project | Show/set sticky project |

### Vault Other

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>vV` | Switch vault | Pick and switch active vault |

---

## FZF Internal Keymaps

**Inside fzf picker windows:**

### Navigation

| Key | Action |
|-----|--------|
| `<C-n>` / `ctrl-n` | Move down in results |
| `<C-p>` / `ctrl-p` | Move up in results |
| `<C-j>` / `ctrl-j` | Scroll preview down |
| `<C-k>` / `ctrl-k` | Scroll preview up |
| `ctrl-q` | Select all + accept |

### File Actions

| Key | Action |
|-----|--------|
| `<CR>` (default) | Open in current window |
| `ctrl-s` | Open in horizontal split |
| `ctrl-v` | Open in vertical split |
| `ctrl-t` | Open in new tab |
| `ctrl-q` | Send selected to quickfix list |

---

## User Commands

### Vault Commands

| Command | Description |
|---------|-------------|
| `:VaultNew` | Create new vault note from template |
| `:VaultDaily` | Create today's daily log |
| `:VaultSearch` | Live grep across vault |
| `:VaultSearchNotes` | Live grep across markdown notes |
| `:VaultSearchFiltered` | Search scoped by folder |
| `:VaultSearchType` | Search by frontmatter type |
| `:VaultBacklinks` | Notes linking to current note |
| `:VaultForwardlinks` | Wikilinks in current note |
| `:VaultOutline` | Heading outline for current buffer |
| `:VaultPin` | Pin current note |
| `:VaultUnpin` | Unpin current note |
| `:VaultPins` | List pinned notes |
| `:VaultTasks` | Show open tasks across vault |
| `:VaultTasksAll` | Show all tasks (any state) |
| `:VaultTasksByState [state]` | Filter tasks by checkbox state |
| `:VaultRename [name]` | Rename note + update wikilinks |
| `:VaultRenamePreview [name]` | Preview wikilink changes from rename |
| `:VaultTagRename [old] [new]` | Rename tag across vault |
| `:VaultBlockId` | Generate block ID for current line |
| `:VaultBlockIdLink` | Generate block ID + insert reference |
| `:VaultGraph` | Open local graph view |
| `:VaultSwitch` | Switch active vault |
| `:VaultCapture` | Quick capture to today's daily log |
| `:VaultCaptureInbox` | Quick capture to vault inbox |
| `:VaultFiles` | Find vault files ranked by frecency |
| `:VaultRecent` | Show recently edited vault notes |
| `:VaultProjects` | Pick a vault project dashboard |
| `:VaultStickyProject` | Show/set sticky project |
| `:VaultStickyClear` | Clear the sticky project |
| `:VaultPreview` | Preview wikilink under cursor |
| `:VaultExport` | Export current note via pandoc |
| `:VaultInsertFragment` | Insert a template fragment at cursor |
| `:VaultPasteImage` | Paste image from clipboard |
| `:VaultEmbedRender` | Render embed transclusions |
| `:VaultEmbedClear` | Clear embed transclusions |
| `:VaultEmbedToggle` | Toggle embed transclusions |
| `:VaultMetaEdit` | Edit frontmatter fields |
| `:VaultMetaCycle` | Cycle through field values |
| `:VaultMetaToggle` | Toggle field values |
| `:VaultLinkDiag` | Run link diagnostics on current buffer |
| `:VaultLinkDiagToggle` | Toggle auto link diagnostics |
| `:VaultFixLinks` | Show broken links with fix suggestions |

### Terminal Commands

| Command | Description |
|---------|-------------|
| `:FloatingTerminal toggle` | Toggle terminal visibility |
| `:FloatingTerminal open` | Show terminal (restore session) |
| `:FloatingTerminal hide` | Hide terminal (preserve session) |
| `:FloatingTerminal close` | Close and terminate terminal |
| `:FloatingTerminal restart` | Restart terminal |
| `:FloatingTerminal send <cmd>` | Send command to terminal |

### LSP Commands

| Command | Description |
|---------|-------------|
| `:LspRestart` | Restart LSP server |
| `:CtagsLspRestart` | Restart ctags LSP server |
| `:CtagsLspInfo` | Show ctags LSP info |
| `:CtagsGenerate` | Generate ctags for Fortran headers |
| `:CtagsInfo` | Show ctags configuration |

### Fortran Commands

| Command | Description |
|---------|-------------|
| `:FortranLinter` | Show/change Fortran linter |
| `:FortranAddInclude` | Add Fortran include path |
| `:FortranLinterInfo` | Show Fortran linter configuration |

---

## Which-Key Groups

Press `<leader>` and wait 500ms to see all available groups:

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
| `<leader>o` | OpenCode |
| `<leader>r` | Rust / Refactor |
| `<leader>s` | Split / Window |
| `<leader>t` | Tab / Terminal |
| `<leader>v` | Vault |
| `<leader>x` | Trouble / Diagnostics |

### Vault Sub-Groups

| Prefix | Group |
|--------|-------|
| `<leader>vt` | Templates |
| `<leader>vf` | Find |
| `<leader>ve` | Edit |
| `<leader>vx` | Tasks |
| `<leader>vc` | Check |
| `<leader>vq` | Query |
| `<leader>vm` | Meta / Frontmatter |
| `<leader>vb` | Bookmarks / Pins |
| `<leader>vk` | Block IDs |
| `<leader>vg` | Tags |

---

## Bracket Navigation Summary

Quick reference for all `]`/`[` navigation patterns:

| Forward | Backward | What | Context |
|---------|----------|------|---------|
| `]d` | `[d` | Diagnostic | LSP (any file) |
| `]g` | `[g` | Git hunk | Git (any file) |
| `]t` | `[t` | TODO comment | Todo-comments (any file) |
| `[c` | — | Treesitter context | Treesitter (any file) |
| `]h` | `[h` | Heading | Markdown |
| `]1`-`]6` | `[1`-`[6` | Heading level N | Markdown |
| `]o` | `[o` | Wikilink | Markdown |
| `]m` | `[m` | Math zone | Markdown / TeX |
| `]]` | `[[` | Section | TeX |
| `]e` | `[e` | Environment | TeX |

---

## Snippet Triggers

Snippets expand when you type the trigger text and press `<Tab>` (or accept via completion). Autosnippets expand automatically in math mode without pressing Tab.

**Source files:** `snippets/` (JSON, via friendly-snippets), `luasnippets/` (LuaSnip), `lua/andrew/utils/tex.lua` (math autosnippets)

### Fortran Snippets

**Source:** `snippets/fortran.json` | 47 triggers (case-sensitive, uppercase variants available)

| Trigger | Expansion |
|---------|-----------|
| `program` / `PROGRAM` | `program name ... end program name` |
| `module` / `MODULE` | `module name ... end module name` |
| `submodule` / `SUBMODULE` | `submodule (parent) name ... end submodule` |
| `do` / `DO` | `do i = start, end ... end do` |
| `dowhile` / `DOWHILE` | `do while (condition) ... end do` |
| `doconcurrent` / `DOCONCURRENT` | `do concurrent (i = start:end) ... end do` |
| `function` / `FUNCTION` | `function name(args) result(res) ... end function` |
| `purefunction` / `PUREFUNCTION` | `pure function name(args) ... end function` |
| `elemental` / `ELEMENTAL` | `elemental function name(args) ... end function` |
| `subroutine` / `SUBROUTINE` | `subroutine name(args) ... end subroutine` |
| `puresub` / `PURESUB` | `pure subroutine name(args) ... end subroutine` |
| `type` / `TYPE` | `type :: name ... end type name` |
| `typeproc` / `TYPEPROC` | `type with procedure block` |
| `interface` / `INTERFACE` | `interface ... end interface` |
| `abstractinterface` / `ABSTRACTINTERFACE` | `abstract interface ... end interface` |
| `if` / `IF` | `if (condition) then ... end if` |
| `ifelse` / `IFELSE` | `if (condition) then ... else ... end if` |
| `elseif` / `ELSEIF` | `else if (condition) then ...` |
| `select` / `SELECT` | `select case (expr) ... end select` |
| `selectcase` | `select case with cases` |
| `selecttype` / `SELECTTYPE` | `select type (variable) ... end select` |
| `where` / `WHERE` | `where (mask) ... end where` |
| `forall` / `FORALL` | `forall (index) ... end forall` |
| `block` / `BLOCK` | `block ... end block` |
| `associate` / `ASSOCIATE` | `associate (name => expr) ... end associate` |
| `allocate` / `ALLOCATE` | `allocate(array, stat=ierr)` |
| `deallocate` / `DEALLOCATE` | `deallocate(array, stat=ierr)` |
| `implicit` / `IMPLICIT` | `implicit none` |
| `use` / `USE` | `use module_name, only: ...` |
| `useiso` / `isoc` | `use iso_c_binding, only: ...` |
| `usefortranenv` / `isofortran` | `use iso_fortran_env, only: ...` |
| `intentin` / `INTENTIN` | `type, intent(in) :: name` |
| `intentout` / `INTENTOUT` | `type, intent(out) :: name` |
| `intentinout` / `INTENTINOUT` | `type, intent(in out) :: name` |
| `real` / `REAL` | `real(kind) :: name` |
| `integer` / `INTEGER` | `integer :: name` |
| `character` / `CHARACTER` | `character(len=N) :: name` |
| `logical` / `LOGICAL` | `logical :: name` |
| `array` / `ARRAY` | `type, dimension(:) :: name` |
| `open` / `OPEN` | `open(unit=N, file='...', ...)` |
| `close` / `CLOSE` | `close(unit=N)` |
| `read` / `READ` | `read(unit, fmt) vars` |
| `write` / `WRITE` | `write(unit, fmt) vars` |
| `print` / `PRINT` | `print *, vars` |
| `errorstop` / `ERRORSTOP` | `error stop 'message'` |
| `contains` / `CONTAINS` | `contains` |
| `private` / `PRIVATE` | `private` |
| `public` / `PUBLIC` | `public` |
| `modoc` / `MODOC` | Module documentation block |

### Markdown Snippets (JSON)

**Source:** `snippets/markdown.json` | 27 triggers

| Trigger | Expansion |
|---------|-----------|
| `note` | `> [!note] ...` callout |
| `tip` | `> [!tip] ...` callout |
| `warning` | `> [!warning] ...` callout |
| `important` | `> [!important] ...` callout |
| `info` | `> [!info] ...` callout |
| `question` | `> [!question] ...` callout |
| `example` | `> [!example] ...` callout |
| `abstract` | `> [!abstract] ...` callout |
| `target` | `> [!target] ...` callout |
| `dvtable` | Dataview TABLE query block |
| `dvlist` | Dataview LIST query block |
| `dvtask` | Dataview TASK query block |
| `dvjs` | Dataview JS code block |
| `vault` | Vault query code block |
| `fm` | YAML frontmatter block |
| `fmtask` | Task frontmatter block |
| `fmlit` | Literature frontmatter block |
| `task` | Task checkbox `- [ ] ...` |
| `taskdone` | Done task checkbox `- [x] ...` |
| `wl` | Wikilink `[[...]]` |
| `wla` | Wikilink with alias `[[...\|alias]]` |
| `embed` | Embed wikilink `![[...]]` |
| `h2` | Level 2 heading |
| `h3` | Level 3 heading |
| `cb` | Fenced code block |
| `table` | Markdown table |

### Markdown Snippets (LuaSnip)

**Source:** `luasnippets/markdown.lua` | 22 triggers

| Trigger | Expansion |
|---------|-----------|
| `callout` | Callout block (prompts for type) |
| `callout-` | Collapsed callout (foldable) |
| `callout+` | Expanded callout |
| `dv` | Dataview query block |
| `dvl` | Dataview LIST query |
| `dvt` | Dataview TABLE query |
| `dvjs` | Dataview JS block |
| `wl` | Wikilink `[[...]]` |
| `wla` | Wikilink with alias |
| `wlh` | Wikilink with heading `[[..#heading]]` |
| `embed` | Embed wikilink `![[...]]` |
| `embedh` | Embed with heading |
| `task` | Task `- [ ] ...` |
| `taskd` | Done task `- [x] ...` |
| `taskp` | Priority task with due date |
| `mermaid` | Mermaid diagram code block |
| `code` | Fenced code block (prompts for lang) |
| `fm` | YAML frontmatter |
| `field` | YAML field `key: value` |
| `fieldi` | Inline field `[key:: value]` |
| `tbl` | Markdown table |
| `mk` | Inline math `$...$` |
| `dm` | Display math `$$...$$` |

### TeX / LaTeX Snippets (LuaSnip)

**Source:** `luasnippets/tex.lua` | 11 triggers

| Trigger | Expansion |
|---------|-----------|
| `beg` | `\begin{env} ... \end{env}` |
| `sec` | `\section{...}` |
| `ssec` | `\subsection{...}` |
| `sssec` | `\subsubsection{...}` |
| `eq` | `\begin{equation} ... \end{equation}` |
| `ali` | `\begin{align} ... \end{align}` |
| `enum` | `\begin{enumerate} \item ... \end{enumerate}` |
| `item` | `\begin{itemize} \item ... \end{itemize}` |
| `fig` | `\begin{figure} \includegraphics ... \end{figure}` |
| `mk` | Inline math `$...$` |
| `dm` | Display math `\[ ... \]` |

### Math-Mode Autosnippets

**Source:** `lua/andrew/utils/tex.lua` | Active inside `$...$`, `$$...$$`, `\[...\]`, and math environments in both Markdown and TeX files. These expand **automatically** without pressing Tab.

#### Fractions & Scripts

| Trigger | Expansion | Description |
|---------|-----------|-------------|
| `ff` | `\frac{}{} ` | Fraction |
| `//` | `\frac{}{} ` | Fraction (alternate) |
| `td` | `^{}` | Superscript (custom) |
| `sb` | `_{}` | Subscript |
| `sr` | `^2` | Squared |
| `cb` | `^3` | Cubed |
| `inv` | `^{-1}` | Inverse |

#### Greek Letters

| Trigger | Output | | Trigger | Output |
|---------|--------|-|---------|--------|
| `;a` | `\alpha` | | `;n` | `\nu` |
| `;b` | `\beta` | | `;x` | `\xi` |
| `;g` | `\gamma` | | `;X` | `\Xi` |
| `;G` | `\Gamma` | | `;p` | `\pi` |
| `;d` | `\delta` | | `;P` | `\Pi` |
| `;D` | `\Delta` | | `;r` | `\rho` |
| `;e` | `\epsilon` | | `;s` | `\sigma` |
| `;z` | `\zeta` | | `;S` | `\Sigma` |
| `;h` | `\eta` | | `;u` | `\upsilon` |
| `;t` | `\theta` | | `;f` | `\phi` |
| `;T` | `\Theta` | | `;F` | `\Phi` |
| `;i` | `\iota` | | `;c` | `\chi` |
| `;k` | `\kappa` | | `;y` | `\psi` |
| `;l` | `\lambda` | | `;Y` | `\Psi` |
| `;L` | `\Lambda` | | `;o` | `\omega` |
| `;m` | `\mu` | | `;O` | `\Omega` |
| `;ve` | `\varepsilon` | | `;vt` | `\vartheta` |
| `;vf` | `\varphi` | | | |

#### Operators & Relations

| Trigger | Output | Description |
|---------|--------|-------------|
| `<=` | `\leq` | Less than or equal |
| `>=` | `\geq` | Greater than or equal |
| `!=` | `\neq` | Not equal |
| `~~` | `\sim` | Similar |
| `~=` | `\approx` | Approximately |
| `>>` | `\gg` | Much greater |
| `<<` | `\ll` | Much less |
| `xx` | `\times` | Times |
| `**` | `\cdot` | Dot product |
| `->` | `\to` | Right arrow |
| `<-` | `\leftarrow` | Left arrow |
| `=>` | `\implies` | Implies |
| `iff` | `\iff` | If and only if |
| `inn` | `\in` | Element of |
| `notin` | `\notin` | Not element of |
| `sset` | `\subset` | Subset |
| `ssq` | `\subseteq` | Subset or equal |
| `uu` | `\cup` | Union |
| `nn` | `\cap` | Intersection |
| `EE` | `\exists` | Exists |
| `AA` | `\forall` | For all |

#### Big Operators

| Trigger | Output | Description |
|---------|--------|-------------|
| `sum` | `\sum_{i=}^{}` | Summation |
| `prod` | `\prod_{i=}^{}` | Product |
| `lim` | `\lim_{n\to\infty}` | Limit |
| `dint` | `\int_{}^{} \, dx` | Definite integral |

#### Symbols

| Trigger | Output | Description |
|---------|--------|-------------|
| `ooo` | `\infty` | Infinity |
| `par` | `\partial` | Partial derivative |
| `nab` | `\nabla` | Nabla / gradient |
| `...` | `\ldots` | Horizontal dots |
| `ddd` | `\cdots` | Centered dots |

#### Decorators

| Trigger | Output | Description |
|---------|--------|-------------|
| `hat` | `\hat{}` | Hat accent |
| `bar` | `\bar{}` | Bar accent |
| `vec` | `\vec{}` | Vector accent |
| `dot` | `\dot{}` | Dot accent |
| `ddot` | `\ddot{}` | Double dot |
| `tld` | `\tilde{}` | Tilde accent |

#### Delimiters

| Trigger | Output | Description |
|---------|--------|-------------|
| `lr(` | `\left( ... \right)` | Auto-sized parentheses |
| `lr[` | `\left[ ... \right]` | Auto-sized brackets |
| `lr{` | `\left\\{ ... \right\\}` | Auto-sized braces |
| `lr\|` | `\left\| ... \right\|` | Auto-sized pipes |
| `lra` | `\left< ... \right>` | Auto-sized angle brackets |

#### Math Environments

| Trigger | Output | Description |
|---------|--------|-------------|
| `pmat` | `\begin{pmatrix} ... \end{pmatrix}` | Parenthesis matrix |
| `bmat` | `\begin{bmatrix} ... \end{bmatrix}` | Bracket matrix |
| `case` | `\begin{cases} ... \end{cases}` | Cases |

#### Text & Fonts in Math

| Trigger | Output | Description |
|---------|--------|-------------|
| `textt` | `\text{}` | Roman text in math |
| `mcal` | `\mathcal{}` | Calligraphic font |
| `mbb` | `\mathbb{}` | Blackboard bold |
| `mbf` | `\mathbf{}` | Bold font |
| `mrm` | `\mathrm{}` | Roman font |
| `RR` | `\mathbb{R}` | Real numbers |
| `ZZ` | `\mathbb{Z}` | Integers |
| `NN` | `\mathbb{N}` | Natural numbers |
| `QQ` | `\mathbb{Q}` | Rational numbers |
| `CC` | `\mathbb{C}` | Complex numbers |

---

*250+ keybindings across 45+ plugins and custom modules, plus 168+ snippet triggers*
