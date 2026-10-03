# Neovim Complete Keymaps Reference

Leader key: `<Space>`

---

## Table of Contents

1. [Core Keymaps](#core-keymaps)
2. [Fuzzy Finder (fzf-lua)](#fuzzy-finder-fzf-lua)
3. [LSP — Language Server Protocol](#lsp--language-server-protocol)
4. [Completion (blink.cmp)](#completion-blinkcmp)
5. [Trouble (Diagnostics Panel)](#trouble-diagnostics-panel)
6. [Git Commands (`<leader>g`)](#git-commands-leaderg)
7. [Git Hunks (gitsigns)](#git-hunks-gitsigns)
7. [File Explorer (yazi)](#file-explorer-yazi)
8. [Debugging (DAP)](#debugging-dap)
9. [Terminal](#terminal)
10. [Make / Build (Fortran)](#make--build-fortran)
11. [Type Checking](#type-checking)
12. [Linting](#linting)
13. [Treesitter](#treesitter)
14. [Commenting (Comment.nvim)](#commenting-commentnvim)
15. [Surround (nvim-surround)](#surround-nvim-surround)
16. [Substitute (substitute.nvim)](#substitute-substitutenvim)
17. [TODO Comments](#todo-comments)
18. [Table Mode](#table-mode)
19. [Window Maximizer](#window-maximizer)
20. [Rust Development (rustaceanvim)](#rust-development-rustaceanvim)
21. [OpenCode AI](#opencode-ai)
22. [Markdown Filetype Keymaps](#markdown-filetype-keymaps)
23. [Markdown Text Objects & Motions](#markdown-text-objects--motions)
24. [LaTeX Filetype Keymaps](#latex-filetype-keymaps)
25. [LaTeX Text Objects & Motions](#latex-text-objects--motions)
26. [Vault — Templates](#vault--templates)
27. [Vault — Navigation & Daily Logs](#vault--navigation--daily-logs)
28. [Vault — Search & Find](#vault--search--find)
29. [Vault — Query Engine](#vault--query-engine)
30. [Vault — Wikilinks & Links](#vault--wikilinks--links)
31. [Vault — Edit & Rename](#vault--edit--rename)
32. [Vault — Meta Edit (Frontmatter)](#vault--meta-edit-frontmatter)
33. [Vault — Tasks](#vault--tasks)
34. [Vault — Tags](#vault--tags)
35. [Vault — Link Checking & Diagnostics](#vault--link-checking--diagnostics)
36. [Vault — Pins & Bookmarks](#vault--pins--bookmarks)
37. [Vault — Capture & Quick Note](#vault--capture--quick-note)
38. [Vault — Graph & Preview](#vault--graph--preview)
39. [Vault — Miscellaneous](#vault--miscellaneous)
40. [UI / Toggle](#ui--toggle)

---

## Core Keymaps

Source: `lua/andrew/core/keymaps.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `jk` | Insert | `<ESC>` | Exit insert mode |
| `<leader>nh` | Normal | `:nohl<CR>` | Clear search highlights |
| `<leader>na` | Normal | `<C-a>` | Increment number under cursor |
| `<leader>nx` | Normal | `<C-x>` | Decrement number under cursor |
| `<leader>sv` | Normal | `<C-w>v` | Split window vertically |
| `<leader>sh` | Normal | `<C-w>s` | Split window horizontally |
| `<leader>se` | Normal | `<C-w>=` | Equalize all split sizes |
| `<leader>sx` | Normal | `:close<CR>` | Close current split |
| `<leader>to` | Normal | `:tabnew<CR>` | Open new tab |
| `<leader>tx` | Normal | `:tabclose<CR>` | Close current tab |
| `<leader>tn` | Normal | `:tabn<CR>` | Go to next tab |
| `<leader>tp` | Normal | `:tabp<CR>` | Go to previous tab |
| `<leader>tf` | Normal | `:tabnew %<CR>` | Open current buffer in new tab |
| `<leader><Tab><Tab>` | Normal | `:tabnew<CR>` | New Tab (LazyVim group) |
| `<leader><Tab>d` | Normal | `:tabclose<CR>` | Close Tab (LazyVim group) |
| `<leader><Tab>o` | Normal | `:tabonly<CR>` | Close Other Tabs (LazyVim group) |
| `<leader><Tab>]` | Normal | `:tabnext<CR>` | Next Tab (LazyVim group) |
| `<leader><Tab>[` | Normal | `:tabprevious<CR>` | Previous Tab (LazyVim group) |
| `<leader><Tab>f` | Normal | `:tabfirst<CR>` | First Tab (LazyVim group) |
| `<leader><Tab>l` | Normal | `:tablast<CR>` | Last Tab (LazyVim group) |

---

## Fuzzy Finder (fzf-lua)

Source: `lua/andrew/plugins/fzf-lua.lua`

### Picker Launchers

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>ff` | Normal | `fzf files` | Find files in current directory |
| `<leader>fr` | Normal | `fzf oldfiles` | Find recently opened files |
| `<leader>fs` | Normal | `fzf live_grep` | Live grep (search string in cwd) |
| `<leader>fc` | Normal | `fzf grep_cword` | Grep word under cursor |
| `<leader>fk` | Normal | `fzf keymaps` | Search all keybindings |
| `<leader>fh` | Normal | `fzf help_tags` | Search `:help` tags |
| `<leader>fH` | Normal | `fzf grep help` | Grep through `:help` documentation |
| `<leader>ft` | Normal | `fzf todo-comments` | Find TODO/FIXME comments |
| `<leader>vff` | Normal | `fzf vault files` | Vault: find files (frecency-sorted) |

### Inside fzf Picker

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

## LSP — Language Server Protocol

Source: `lua/andrew/plugins/lsp/lspconfig.lua`

### Navigation

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `gd` | Normal | `lsp_definitions` | Go to definition(s) |
| `gD` | Normal | `lsp_declaration` | Go to declaration (fallback to definition) |
| `gr` | Normal | `lsp_references` | Show all references (Fortran: scanner fallback) |
| `gI` | Normal | `lsp_implementations` | Show implementations |
| `gy` | Normal | `lsp_typedefs` | Show type definitions |
| `gai` / `gao` | Normal | `lsp_incoming_calls` / `lsp_outgoing_calls` | Call hierarchy |
| `]]` / `[[` | Normal | `Snacks.words.jump` | Next / prev reference |
| `<A-n>` / `<A-p>` | Normal | `Snacks.words.jump` (wrapping) | Next / prev reference |
| `<leader>ss` / `<leader>sS` | Normal | `lsp_document_symbols` / `lsp_live_workspace_symbols` | Symbols |
All LSP keys except `gD` and `<leader>cl` are **capability-gated** (`lua/andrew/lsp_keymaps.lua`):
bound only when an attached server advertises the method. nvim 0.12's built-in
`grn`/`gra`/`grx`/`grr`/`gri`/`grt` are deleted at startup so `gr` does not stall
behind `timeoutlen`.


### Hover & Signature

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `K` | Normal | `vim.lsp.buf.hover()` | Show hover documentation |
| `<C-k>` | Normal, Insert | `vim.lsp.buf.signature_help()` | Show signature help |
| `gK` | Normal | `vim.lsp.buf.signature_help()` | Show signature help (LazyVim spelling) |

### Code Actions & Refactoring

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>ca` | Normal, Visual | `fzf-lua.lsp_code_actions()` | See available code actions (diff preview) |
| `<leader>cA` | Normal | source action, applied | Source Action |
| `<leader>co` | Normal | `source.organizeImports` | Organize Imports (gated on the kind) |
| `<leader>cc` / `<leader>cC` | Normal, Visual | `vim.lsp.codelens.run` / `.enable` | Run / display codelens |
| `<leader>cr` | Normal | `vim.lsp.buf.rename()` | Smart rename symbol |
| `<leader>cR` | Normal | `Snacks.rename.rename_file()` | Rename file (LSP-aware) |
| `<leader>cf` / `<leader>cF` | Normal, Visual | `conform.format()` | Format / format injected langs |
| `<leader>cs` / `<leader>cS` | Normal | `lsp_document_symbols` / `lsp_live_workspace_symbols` | Document / workspace symbols (fzf; aliases of `<leader>ss` / `<leader>sS`) |
| `<leader>cl` | Normal | fzf client picker | LSP info |
| `<leader>cm` | Normal | `<cmd>Mason<CR>` | Mason |
| `<leader>lr` | Normal | `<cmd>lsp restart<CR>` | Restart LSP server |
| `<leader>lh` | Normal | inlay hints | Toggle inlay hints |

### Diagnostics

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>D` | Normal | `fzf diagnostics_document` | Show buffer diagnostics |
| `<leader>cd` | Normal | `vim.diagnostic.open_float()` | Show line diagnostics |
| `[d` / `]d` | Normal | `vim.diagnostic.jump()` | Previous / next diagnostic |
| `[e` / `]e` | Normal | severity=ERROR | Previous / next error (shadowed in `.tex`) |
| `[w` / `]w` | Normal | severity=WARN | Previous / next warning |

These are GLOBAL, not LspAttach-bound.

---

## Completion (blink.cmp)

Source: `lua/andrew/plugins/blink-cmp.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<C-Space>` | Insert | Show completion menu | Trigger completion menu |
| `<C-n>` | Insert | Next item | Select next completion item |
| `<C-p>` | Insert | Previous item | Select previous completion item |
| `<CR>` | Insert | Accept | Accept selected completion / expand snippet |
| `<C-e>` | Insert | Hide menu | Dismiss completion menu |
| `<C-j>` | Insert | Scroll down | Scroll documentation window down |
| `<C-k>` | Insert | Scroll up | Scroll documentation window up |

---

## Trouble (Diagnostics Panel)

Source: `lua/andrew/plugins/trouble.lua` — Prefix: `<leader>x`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>xw` | Normal | Trouble preview_float | Workspace diagnostics |
| `<leader>xd` | Normal | Trouble current file | Current file diagnostics |
| `<leader>xe` | Normal | Trouble errors (file) | Errors only — current file |
| `<leader>xE` | Normal | Trouble errors (workspace) | Errors only — workspace |
| `<leader>xq` | Normal | Trouble quickfix | Open quickfix list |
| `<leader>xl` | Normal | Trouble loclist | Open location list |
| `<leader>xt` | Normal | Trouble todo | Open TODO comments |
| `<leader>xf` | Normal | Trouble fzf | Open fzf-lua results in Trouble |
| `<leader>xF` | Normal | Trouble fzf_files | Open fzf-lua file results in Trouble |

---

## Git Commands (`<leader>g`)

Source: `lua/andrew/plugins/git.lua` (snacks.nvim spec fragment, ported from LazyVim)

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>gg` | Normal | Lazygit (root dir) |
| `<leader>gG` | Normal | Lazygit (cwd) |
| `<leader>gl` | Normal | Git log |
| `<leader>gL` | Normal | Git log (cwd) |
| `<leader>gc` | Normal | Commits (fzf-lua) |
| `<leader>gf` | Normal | Current file history |
| `<leader>gb` | Normal | Blame line |
| `<leader>gs` | Normal | Git status |
| `<leader>gS` | Normal | Git stash |
| `<leader>gd` | Normal | Git diff (hunks) |
| `<leader>gD` | Normal | Git diff (origin) |
| `<leader>gB` | Normal, Visual | Git browse — open on the remote host |
| `<leader>gY` | Normal, Visual | Git browse — copy the URL |

**Conditional:** `<leader>gg` / `<leader>gG` need the `lazygit` binary (present). `<leader>gi` `<leader>gI` (issues) and `<leader>gp` `<leader>gP` (pull requests) need the `gh` binary, which is **not installed**, so they are inactive.

---

## Git Hunks (gitsigns)

Source: `lua/andrew/plugins/gitsigns.lua` — Prefix: `<leader>gh`

### Navigation

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `]g` / `[g` | Normal | `nav_hunk("next"/"prev")` | Next / previous hunk — every filetype |
| `]h` / `[h` | Normal | `nav_hunk("next"/"prev")` | Same, but **not bound in markdown** |
| `]H` / `[H` | Normal | `nav_hunk("last"/"first")` | Last / first hunk in the file |
> `]h` / `[h` are LazyVim's hunk keys but are **not bound in markdown**, where headings (`ftplugin/markdown.lua`) and `==highlights==` (`vault/highlights.lua`) already own them. `]g` / `[g` is the alias that works in every filetype.


### Hunk Actions

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>ghs` | Normal, Visual | `stage_hunk` | Stage hunk (or visual selection) |
| `<leader>ghr` | Normal, Visual | `reset_hunk` | Reset hunk (or visual selection) |
| `<leader>ghS` | Normal | `stage_buffer` | Stage entire buffer |
| `<leader>ghR` | Normal | `reset_buffer` | Reset entire buffer |
| `<leader>ghu` | Normal | `undo_stage_hunk` | Undo stage hunk |
| `<leader>ghp` | Normal | `preview_hunk_inline` | Preview hunk (inline popup) |
| `<leader>ghb` | Normal | `blame_line` | Blame line (full git blame) |
| `<leader>ghB` | Normal | `blame` | Blame the whole buffer |
| `<leader>ght` | Normal | `toggle_current_line_blame` | Toggle current line blame (inline) |
| `<leader>ghd` | Normal | `diffthis` | Diff this file |
| `<leader>ghD` | Normal | `diffthis ~` | Diff against previous commit |

> `<leader>ghd`/`ghD` leave the cursor in the DIFF window, so `:q` closes the diff and returns you to
> your file. Upstream gitsigns restores focus to your file instead, which makes `:q` close your own
> window and strand you in the unlisted `gitsigns://…` index buffer.


### Text Object

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `ih` | Operator, Visual | Gitsigns select_hunk | Select hunk text object |

---

---

## Diff Overlay (mini.diff)

**Source:** `lua/andrew/plugins/mini-diff.lua`

| Key | Description |
|-----|-------------|
| `<leader>go` | Toggle the diff overlay (old content shown inline) |
| `gh + motion` | Apply (stage) the range |
| `gH + motion` | Reset the range |
| `gh (o, x)` | Hunk range text object |

| Command | Description |
|---------|-------------|
| `:MiniDiffOverlay` | Toggle the overlay |
| `:MiniDiffToggle` | Enable/disable mini.diff for this buffer |
| `:MiniDiffQuickfix` | Send every hunk to the quickfix list |

> Runs **alongside** gitsigns, which keeps the sign column, `<leader>gh` staging, blame and all
> hunk motions. mini.diff's own `]h`/`[h`/`]H`/`[H` are disabled (gitsigns owns them; in markdown
> headings and `==highlights==` do), and hunk marks go in the **number** column to avoid drawing
> the same hunks twice. `gh`/`gH` shadow the built-in Select-mode starters.
> On a buffer with no diff (picker previews, diff scratch buffers, terminals) all four keys report
> `mini.diff: no diff for this buffer` rather than raising `E5108`.
> The overlay choice is remembered per file and re-applied after a buffer reload (mini.diff drops it
> from its per-buffer cache on any reload, `:edit` included).

## File Explorer (yazi)

Source: `lua/andrew/plugins/yazi.lua` — Prefix: `<leader>e`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>ee` | Normal | `yazi()` | Open Yazi file explorer |
| `<leader>ef` | Normal | `yazi at current file` | Open Yazi at current file location |
| `<leader>ec` | Normal | `:close<CR>` | Close explorer window |
| `<leader>er` | Normal | `yazi()` | Refresh explorer |

### Inside Yazi

| Key | Action |
|-----|--------|
| `<F1>` | Show help |
| `<C-s>` | Grep in directory / grep selected files |

---

## Debugging (DAP)

Source: `lua/andrew/plugins/dap/dap.lua`, `lua/andrew/plugins/dap/dap-ui.lua` — Prefix: `<leader>d`

### Session Control

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>dc` | Normal | `dap.continue()` | Start / Continue debugging |
| `<leader>do` | Normal | `dap.step_over()` | Step over |
| `<leader>di` | Normal | `dap.step_into()` | Step into |
| `<leader>dO` | Normal | `dap.step_out()` | Step out |
| `<leader>dt` | Normal | `dap.terminate()` | Terminate debugging session |
| `<leader>dC` | Normal | `dap.run_to_cursor()` | Run to cursor |
| `<leader>dr` | Normal | `dap.restart()` | Restart debugging |
| `<leader>dR` | Normal | `dap.repl.toggle()` | Toggle REPL |

### Breakpoints

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>db` | Normal | `dap.toggle_breakpoint()` | Toggle breakpoint on current line |
| `<leader>dB` | Normal | `dap.set_breakpoint(condition)` | Set conditional breakpoint |

### DAP UI

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>du` | Normal | `dapui.toggle()` | Toggle DAP UI panel |
| `<leader>de` | Normal, Visual | `dapui.eval()` | Evaluate expression |
| `<leader>df` | Normal | `dapui.float_element()` | Float element (hover window) |

---

## Terminal

Source: `lua/andrew/custom/plugins/terminal.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>tt` | Normal | Toggle terminal | Toggle floating terminal |
| `<C-\><C-n>` | Terminal | Exit terminal mode | Standard escape from terminal mode |
| `jk` | Terminal | Exit terminal mode | Custom escape from terminal mode |

---

## Make / Build (Fortran)

Source: `lua/andrew/plugins/fortran-build.lua` — Prefix: `<leader>m` (non-markdown buffers)

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>mb` | Normal | Make: Build | Make: Build (pick Makefile) |
| `<leader>md` | Normal | Make: Build Debug | Make: Build Debug |
| `<leader>mc` | Normal | Make: Clean | Make: Clean |
| `<leader>mr` | Normal | Make: Run | Make: Run |
| `<leader>ma` | Normal | Make: All | Make: All |
| `<leader>ml` | Normal | Make: Re-run last | Make: Re-run last Makefile |

---

## Type Checking

Source: `lua/andrew/plugins/type-checker.lua` — Prefix: `<leader>a`

### Dispatch

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>ac` | Normal | TypeCheck dispatch | Type check — auto-detect filetype |

### Language-Specific

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>aP` | Normal | typecheck_python | Python type check (ruff check) |
| `<leader>aT` | Normal | typecheck_python_ty | Ty type check (Python) |
| `<leader>aR` | Normal | typecheck_rust | cargo check (Rust) |
| `<leader>aL` | Normal | typecheck_lua | lua-language-server --check (Lua) |
| `<leader>aF` | Normal | typecheck_fortran | Fortran type check (current compiler) |
| `<leader>aC` | Normal | typecheck_cpp | C/C++ syntax & warnings |

### Fortran Compiler Toggle

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>ag` | Normal | typecheck_fortran_mpif90 | Fortran check with mpif90/gfortran |
| `<leader>ai` | Normal | typecheck_fortran_mpiifx | Fortran check with mpiifx/Intel |
| `<leader>at` | Normal | Toggle compiler | Toggle Fortran compiler (mpif90 <-> mpiifx) |

---

## Linting

Source: `lua/andrew/plugins/linting.lua` — Prefix: `<leader>l`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>Ll` | Normal | Run linters | Run linters for current buffer |
| `<leader>Lm` | Normal | ruff check | Run ruff (Python) |
| `<leader>Lf` | Normal | Toggle Fortran linter | Toggle Fortran linter |
| `<leader>LF` | Normal | Run Fortran linter | Run Fortran linter (debug mode) |
| `<leader>Lw` | Normal | Lint workspace | Lint entire Fortran workspace |
| `<leader>LW` | Normal | Clear workspace | Clear workspace diagnostics |
| `<leader>Lc` | Normal | Check capitalization | Flag intrinsics / project procedures that are not ALL CAPS |
| `<leader>LC` | Normal | Fix capitalization | Uppercase every flagged name in the buffer |
| `<leader>Lt` | Normal | Toggle case check | Turn the on-save capitalization check on/off |

---

## Treesitter

Source: `lua/andrew/plugins/treesitter.lua`

### Incremental Selection

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<C-Space>` | Normal | Start selection | Start selection / expand to next node |
| `<BS>` | Visual | Shrink selection | Shrink selection to previous node |

### Context (Sticky Headers)

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `[c` | Normal | Jump to context | Jump to context (parent scope / containing heading) |

---

## Commenting (Comment.nvim)

Source: `lua/andrew/plugins/comment.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `gcc` | Normal | Toggle comment | Toggle comment on current line |
| `gc{motion}` | Normal | Toggle comment | Toggle comment with motion (e.g., `gcap` for paragraph) |
| `gc` | Visual | Toggle comment | Toggle comment on visual selection |
| `gbc` | Normal | Toggle block comment | Toggle block comment on current line |
| `gb` | Visual | Toggle block comment | Toggle block comment on visual selection |

---

## Surround (nvim-surround)

Source: `lua/andrew/plugins/surround.lua`

### Core Operations

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `ys{motion}{char}` | Normal | Add surround | Add surround (e.g., `ysiw"` wraps word in `"`) |
| `cs{old}{new}` | Normal | Change surround | Change surround (e.g., `cs'"` changes `'` to `"`) |
| `ds{char}` | Normal | Delete surround | Delete surround (e.g., `ds"` removes `"`) |
| `S{char}` | Visual | Surround selection | Surround visual selection |

### Custom LaTeX Characters

| Char | Type | Example |
|------|------|---------|
| `e` | LaTeX environment | `\begin{env}...\end{env}` |
| `c` | LaTeX command | `\cmd{...}` |

---

## Substitute (substitute.nvim)

Source: `lua/andrew/plugins/substitute.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `gs{motion}` | Normal | Substitute with motion | Substitute with motion (e.g., `gsiw`) |
| `gss` | Normal | Substitute line | Substitute entire line |
| `gS` | Normal | Substitute to EOL | Substitute from cursor to end of line |
| `gs` | Visual | Substitute selection | Substitute visual selection |

---

## TODO Comments

Source: `lua/andrew/plugins/todo-comments.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `]t` | Normal | Jump next | Jump to next TODO/FIXME comment |
| `[t` | Normal | Jump prev | Jump to previous TODO/FIXME comment |

---

## Table Mode

Source: `lua/andrew/plugins/vim-table-mode.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>Tm` | Normal | Toggle table mode | Toggle table mode on/off |

### When Table Mode is Active

| Key | Action |
|-----|--------|
| `\|` | Auto-create table structure as you type |
| `Tab` | Move to next cell |
| `\|\|` | Create horizontal separator row |

---

## Window Maximizer

Source: `lua/andrew/plugins/vim-maximizer.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>sm` | Normal | MaximizerToggle | Maximize / restore current split window |

---

## Rust Development (rustaceanvim)

Source: `lua/andrew/plugins/rustaceanvim.lua` — Buffer-local, Rust files only

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>ca` | Normal | RustLsp codeAction | Rust code actions (overrides default) |
| `K` | Normal | RustLsp hover actions | Rust hover actions (overrides default) |
| `<leader>rr` | Normal | RustLsp runnables | Run runnables |
| `<leader>rd` | Normal | RustLsp debuggables | Run debuggables |
| `<leader>rt` | Normal | RustLsp testables | Run testables |
| `<leader>rm` | Normal | RustLsp expandMacro | Expand macro recursively |
| `<leader>rc` | Normal | RustLsp openCargo | Open Cargo.toml |
| `<leader>rp` | Normal | RustLsp parentModule | Go to parent module |
| `J` | Normal | RustLsp joinLines | Join lines (Rust-aware) |
| `<leader>re` | Normal | RustLsp explainError | Explain error |
| `<leader>rD` | Normal | RustLsp renderDiagnostic | Render diagnostics |
| `<leader>dt` | Normal | RustLsp testables | Debugger testables |

---

## Quit / Session

Source: `lua/andrew/plugins/persistence.lua`, `lua/andrew/core/keymaps.lua` — Prefix: `<leader>q`

Sessions save on quit and restore only on request -- one per working directory, plus a separate one per git branch when it is not `main`/`master`. Terminals are deliberately not restored.

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>qq` | Normal | Quit All | Close every window and exit (`:qa`) |
| `<leader>qs` | Normal | Restore Session | Reopen the session for the current directory |
| `<leader>qS` | Normal | Select Session | Pick any saved session; changes directory into it |
| `<leader>ql` | Normal | Restore Last Session | Reopen the most recently saved session |
| `<leader>qd` | Normal | Don't Save Current Session | Leave the stored session untouched on quit |

## OpenCode AI

Source: `lua/andrew/plugins/opencode.lua` — Prefix: `<leader>o`

**Keymaps removed 2026-09-06.** opencode.nvim is still installed and its
`init()` side effects still run, but the spec no longer declares any `keys`, so
nothing under `<leader>o` (or `<S-C-u>` / `<S-C-d>`) is bound and the plugin
never loads. The ten original bindings are preserved verbatim as a commented
block in `lua/andrew/plugins/opencode.lua`; uncomment it and delete the
`lazy = true` line to restore them.

---

## Markdown Filetype Keymaps

Source: `ftplugin/markdown.lua` — Prefix: `<leader>m` (markdown buffers only)

### Folding

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<Tab>` | Normal | `za` | Toggle fold under cursor |
| `<leader>mf` | Normal | `zM` | Fold all (close all folds) |
| `<leader>mu` | Normal | `zR` | Unfold all (open all folds) |
| `<leader>ml` | Normal | Set fold level | Set fold level (prompts for number) |

### Heading Navigation (Treesitter-based)

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `]h` | Normal | Next heading | Jump to next heading (any level) |
| `[h` | Normal | Prev heading | Jump to previous heading (any level) |
| `]1` — `]6` | Normal | Next h1-h6 | Jump to next heading at level 1-6 |
| `[1` — `[6` | Normal | Prev h1-h6 | Jump to previous heading at level 1-6 |

### Heading Level Toggle

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>m1` — `<leader>m6` | Normal | Set heading | Set heading to level 1-6 (removes if already at that level) |

### Checkbox / Task

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>mx` | Normal | Cycle checkbox | Cycle checkbox state (unchecked -> checked -> cancelled) |

### Inline Formatting

| Key | Mode | Markup | Description |
|-----|------|--------|-------------|
| `<leader>mb` | Normal | `**text**` | Toggle bold on word under cursor |
| `<leader>mb` | Visual | `**text**` | Toggle bold on selection |
| `<leader>mi` | Normal | `*text*` | Toggle italic on word under cursor |
| `<leader>mi` | Visual | `*text*` | Toggle italic on selection |
| `<leader>ms` | Normal | `~~text~~` | Toggle strikethrough on word |
| `<leader>ms` | Visual | `~~text~~` | Toggle strikethrough on selection |
| `<leader>mc` | Normal | `` `text` `` | Toggle inline code on word |
| `<leader>mc` | Visual | `` `text` `` | Toggle inline code on selection |

### Link Creation (Visual Mode)

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>mk` | Visual | Create markdown link | Create `[text](url)` |
| `<leader>mK` | Visual | Create wikilink | Create / toggle `[[text]]` |

### Images, Callouts, Spell

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>mp` | Normal | Paste image | Paste clipboard image |
| `<leader>mz` | Normal | Toggle callout fold | Toggle callout fold (render-markdown) |
| `<leader>mS` | Normal | Toggle spell check | Toggle spell checking |

### Footnotes

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>mj` | Normal | Jump footnote | Jump between footnote reference and definition |
| `<leader>mn` | Normal | List footnotes | List all footnotes (picker) |

---

## Markdown Text Objects & Motions

Source: `lua/andrew/utils/md-textobjects.lua`

### Text Objects (Visual & Operator-Pending)

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `ac` | Visual, Operator | Around code block | Around code block (including fences) |
| `ic` | Visual, Operator | Inside code block | Inside code block (content only) |
| `al` | Visual, Operator | Around list item | Around list item (bullet + sub-items) |
| `il` | Visual, Operator | Inside list item | Inside list item (text only, no bullet) |
| `aq` | Visual, Operator | Around blockquote | Around blockquote (including `>`) |
| `iq` | Visual, Operator | Inside blockquote | Inside blockquote (content after `>`) |
| `am` | Visual, Operator | Around math zone | Around math zone (`$...$` or `$$...$$`) |
| `im` | Visual, Operator | Inside math zone | Inside math zone |

### Motions

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `]b` | Normal, Visual, Operator | Next code block | Jump to next code block |
| `[b` | Normal, Visual, Operator | Prev code block | Jump to previous code block |
| `]l` | Normal, Visual, Operator | Next list item | Jump to next list item |
| `[l` | Normal, Visual, Operator | Prev list item | Jump to previous list item |
| `]q` | Normal, Visual, Operator | Next blockquote | Jump to next blockquote |
| `[q` | Normal, Visual, Operator | Prev blockquote | Jump to previous blockquote |
| `]m` | Normal, Visual, Operator | Next math zone | Jump to next math zone |
| `[m` | Normal, Visual, Operator | Prev math zone | Jump to previous math zone |

---

## LaTeX Filetype Keymaps

Source: `ftplugin/tex.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `j` | Normal | `gj` | Move down by visual line |
| `k` | Normal | `gk` | Move up by visual line |
| `<Tab>` | Normal | `za` | Toggle fold |
| `<leader>mf` | Normal | `zM` | Fold all |
| `<leader>mu` | Normal | `zR` | Unfold all |

---

## LaTeX Text Objects & Motions

Source: `lua/andrew/utils/tex-motions.lua`

### Motions

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `]]` | Normal, Visual, Operator | Next section | Jump to next section (`\section`, `\subsection`, etc.) |
| `[[` | Normal, Visual, Operator | Prev section | Jump to previous section |
| `]e` | Normal, Visual, Operator | Next environment | Jump to next `\begin{...}` |
| `[e` | Normal, Visual, Operator | Prev environment | Jump to previous `\begin{...}` |
| `]m` | Normal, Visual, Operator | Next math zone | Jump to next math zone |
| `[m` | Normal, Visual, Operator | Prev math zone | Jump to previous math zone |

### Text Objects

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `ae` | Visual, Operator | Around environment | Full `\begin{...}...\end{...}` |
| `ie` | Visual, Operator | Inside environment | Content between begin/end |
| `am` | Visual, Operator | Around math zone | Including delimiters |
| `im` | Visual, Operator | Inside math zone | Content only |
| `ac` | Visual, Operator | Around command | Full `\cmd{...}` |
| `ic` | Visual, Operator | Inside command | Content within `{...}` |

---

## Vault — Templates

Source: `lua/andrew/vault/init.lua` — Prefix: `<leader>vt`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vtn` | Normal | Template picker | Template picker (all types) |
| `<leader>vtd` | Normal | Daily log | Create daily log |
| `<leader>vtw` | Normal | Weekly review | Create weekly review |
| `<leader>vts` | Normal | Simulation note | Create simulation note |
| `<leader>vta` | Normal | Analysis note | Create analysis note |
| `<leader>vtk` | Normal | Task note | Create task note |
| `<leader>vtm` | Normal | Meeting note | Create meeting note |
| `<leader>vtf` | Normal | Finding note | Create finding note |
| `<leader>vtl` | Normal | Literature note | Create literature note |
| `<leader>vtp` | Normal | Project dashboard | Create project dashboard |
| `<leader>vtj` | Normal | Journal entry | Create journal entry |
| `<leader>vtc` | Normal | Concept note | Create concept note |
| `<leader>vtM` | Normal | Monthly review | Create monthly review |
| `<leader>vtQ` | Normal | Quarterly review | Create quarterly review |
| `<leader>vtY` | Normal | Yearly review | Create yearly review |

---

## Vault — Navigation & Daily Logs

Source: `lua/andrew/vault/navigate.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>v[` | Normal | Daily prev | Previous daily log |
| `<leader>v]` | Normal | Daily next | Next daily log |
| `<leader>v{` | Normal | Weekly prev | Previous weekly review |
| `<leader>v}` | Normal | Weekly next | Next weekly review |
| `<leader>vC` | Normal | Calendar view | Calendar view (floating popup) |
| `<leader>vfd` | Normal | Find daily logs | Find: daily log list (picker) |
| `<leader>vfw` | Normal | Find weekly reviews | Find: weekly review list (picker) |
| `<leader>vfW` | Normal | Find all reviews | Find: all reviews list (picker) |

### Calendar Float Keys

| Key | Action |
|-----|--------|
| `<CR>` | Open selected day's note |
| `h` | Previous month |
| `l` | Next month |
| `H` | Previous year |
| `L` | Next year |
| `j` / `k` | Navigate up/down in calendar grid |
| `q` / `<Esc>` | Close calendar |

---

## Vault — Search & Find

Source: `lua/andrew/vault/search.lua`, `lua/andrew/vault/outline.lua` — Prefix: `<leader>vf`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vff` | Normal | Find vault files | Find vault files (frecency-sorted) |
| `<leader>vfs` | Normal | Search vault | Search vault (full-text) |
| `<leader>vfn` | Normal | Search notes | Search notes (title/filename) |
| `<leader>vfD` | Normal | Search filtered | Search filtered (scope by directory) |
| `<leader>vfy` | Normal | Search by type | Search by type (frontmatter type field) |
| `<leader>vfo` | Normal | Document outline | Document outline (heading picker) |
| `<leader>vft` | Normal | Find by tag | Find by tag |
| `<leader>vfb` | Normal | Find backlinks | Find backlinks to current note |
| `<leader>vfl` | Normal | Find forward links | Find forward links from current note |
| `<leader>vfh` | Normal | Find heading backlinks | Find heading backlinks |
| `<leader>vfp` | Normal | Find project dashboards | Find project dashboards |
| `<leader>vfr` | Normal | Find recent notes | Find recent notes (frecency) |
| `<leader>vfS` | Normal | Saved searches | Open saved searches |
| `<leader>vfu` | Normal | Unlinked mentions | Unlinked mentions (scanner) |
| `<leader>vfU` | Normal | Unlinked inverse | Unlinked mentions (inverse) |

---

## Vault — Query Engine

Source: `lua/andrew/vault/query/init.lua` — Prefix: `<leader>vq`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vqr` | Normal | Query render | Render query block under cursor |
| `<leader>vqa` | Normal | Query render all | Render all query blocks in buffer |
| `<leader>vqc` | Normal | Query clear | Clear output for query block under cursor |
| `<leader>vqx` | Normal | Query clear all | Clear all query outputs in buffer |
| `<leader>vqq` | Normal | Query toggle | Toggle query block (render / clear) |
| `<leader>vqi` | Normal | Query rebuild | Rebuild vault index |

---

## Vault — Wikilinks & Links

Source: `lua/andrew/vault/wikilinks.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `gf` | Normal | Follow link | Follow wikilink, markdown link, or URL |
| `gx` | Normal | Open link | Open link in browser / follow link |
| `]o` | Normal | Next link | Jump to next link in buffer |
| `[o` | Normal | Prev link | Jump to previous link in buffer |

---

## Vault — Edit & Rename

Source: `lua/andrew/vault/rename.lua`, `lua/andrew/vault/preview.lua` — Prefix: `<leader>ve`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>ver` | Normal | Rename note | Rename current note (updates all backlinks) |
| `<leader>veR` | Normal | Preview rename | Preview rename (dry-run) |
| `<leader>vet` | Normal | Rename tag | Rename tag across vault |
| `<leader>vE` | Normal | Edit in float | Edit linked note in floating window |
| `<leader>vep` | Normal | Export note | Export note via Pandoc |
| `<leader>vex` | Visual | Extract to note | Extract selection to new note |

### Preview Float Keys

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `q` | Normal | Save and close | Save and close |
| `<Esc><Esc>` | Normal | Save and close | Save and close |
| `<C-s>` | Normal, Insert | Save | Save without closing |
| `<C-j>` | Normal | Scroll down | Scroll parent buffer preview down |
| `<C-k>` | Normal | Scroll up | Scroll parent buffer preview up |

---

## Vault — Meta Edit (Frontmatter)

Source: `lua/andrew/vault/metaedit.lua`, `lua/andrew/vault/autofile.lua` — Prefix: `<leader>vm`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vms` | Normal | Cycle status | Cycle status field (type-aware values) |
| `<leader>vmp` | Normal | Cycle priority | Cycle priority field |
| `<leader>vmm` | Normal | Cycle maturity | Cycle maturity field |
| `<leader>vmt` | Normal | Toggle draft | Toggle draft status |
| `<leader>vmf` | Normal | Edit field | Pick and set any frontmatter field |
| `<leader>vmv` | Normal | Auto-file | Auto-file suggestion (move note to correct folder) |

---

## Vault — Tasks

Source: `lua/andrew/vault/tasks.lua`, `lua/andrew/vault/quicktask.lua` — Prefix: `<leader>vx`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vxo` | Normal | Open tasks | Show open tasks across vault |
| `<leader>vxa` | Normal | All tasks | Show all tasks across vault |
| `<leader>vxs` | Normal | Tasks by state | Show tasks by state |
| `<leader>vxq` | Normal | Quick task | Quick task — create inline task |

---

## Vault — Tags

Source: `lua/andrew/vault/tags.lua`, `lua/andrew/vault/tag_highlights.lua` — Prefix: `<leader>vg`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vga` | Normal | Add tag | Add tag to current note |
| `<leader>vgr` | Normal | Remove tag | Remove tag from current note |
| `<leader>vgt` | Normal | Toggle highlighting | Toggle inline tag highlighting |
| `]t` | Normal | Next tag | Jump to next inline tag (markdown buffer override) |
| `[t` | Normal | Prev tag | Jump to previous inline tag (markdown buffer override) |

---

## Vault — Link Checking & Diagnostics

Source: `lua/andrew/vault/linkdiag.lua`, `lua/andrew/vault/linkcheck.lua` — Prefix: `<leader>vc`

### Real-time Diagnostics

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vcd` | Normal | Toggle diagnostics | Toggle real-time link diagnostics |
| `<leader>vcf` | Normal | Fix link | Fix broken link under cursor |
| `<leader>vcF` | Normal | Fix all links | Fix all broken links (picker) |

### Batch Link Checking

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vcb` | Normal | Check buffer | Check wikilinks in current buffer |
| `<leader>vca` | Normal | Check vault | Check wikilinks across entire vault |
| `<leader>vco` | Normal | Find orphans | Find orphan notes (no inbound links) |

### Wikilink Highlights

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vch` | Normal | Toggle highlighting | Toggle wikilink resolution highlighting |

---

## Vault — Pins & Bookmarks

Source: `lua/andrew/vault/pins.lua` — Prefix: `<leader>vb`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vbp` | Normal | Toggle pin | Toggle pin on current note |
| `<leader>vbf` | Normal | Find pins | Find pinned notes (picker) |

---

## Vault — Capture & Quick Note

Source: `lua/andrew/vault/capture.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vQ` | Normal | Quick capture | Quick capture to daily log |
| `<leader>vi` | Normal | Capture to inbox | Capture to inbox |

---

## Vault — Graph & Preview

Source: `lua/andrew/vault/graph.lua`, `lua/andrew/vault/preview.lua`

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>vG` | Normal | Open graph | Open local knowledge graph |
| `<leader>vP` | Normal | Sticky project | Sticky project: show / set active project |
| `K` | Normal | Preview link | Preview linked note on hover (markdown, overrides LSP) |

### Graph Float Keys

| Key | Action |
|-----|--------|
| `<CR>` | Open selected note |
| `gf` | Follow link |

---

## Vault — Miscellaneous

| Key | Mode | Source | Description |
|-----|------|--------|-------------|
| `<leader>vI` | Normal | fragments.lua | Insert fragment from template |
| `<leader>vp` | Normal | images.lua | Paste image from clipboard |
| `<leader>vki` | Normal | blockid.lua | Generate block ID |
| `<leader>vkl` | Normal | blockid.lua | Generate block ID and copy link |
| `<leader>vV` | Normal | init.lua | Switch active vault |
| `<leader>va` | Normal | autolink.lua | Add autolinks (smart suggestions) |
| `<leader>vA` | Normal | autolink.lua | Clear autolinks from note |
| `<leader>vgA` | Normal | autolink.lua | Autolinks picker |
| `<leader>vr` | Normal | connections.lua | Smart connection suggestions |
| `]f` | Normal | inline_fields.lua | Jump to next inline field |
| `[f` | Normal | inline_fields.lua | Jump to previous inline field |

---

## UI / Toggle

Source: `lua/andrew/plugins/snacks.lua` (most), `lua/andrew/plugins/gitsigns.lua`
(`<leader>uG`), `lua/andrew/themes/toggle.lua` (light/dark),
`lua/andrew/plugins/vim-maximizer.lua` (`<leader>uZ`),
`lua/andrew/vault/readable_width.lua` (`<leader>uW`).

Letters follow LazyVim's `<leader>u` group. Each entry built with `Snacks.toggle`
registers its own which-key icon, which changes colour with the on/off state.

| Key | Mode | Action | Description |
|-----|------|--------|-------------|
| `<leader>ua` | Normal | Animations | All snacks animations (`vim.g.snacks_animate`) — includes smooth scroll and dimming |
| `<leader>uA` | Normal | Tabline | Show/hide the tabline (`showtabline`) |
| `<leader>ub` | Normal | Dark background | Dark = OneDark (Atom One Dark), light = Soft Paper Light |
| `<leader>uc` | Normal | Conceal level | `conceallevel` between 0 and 2 |
| `<leader>uC` | Normal | Colorschemes | fzf-lua colorscheme picker, applies on selection |
| `<leader>ud` | Normal | Diagnostics | Enable/disable LSP diagnostics |
| `<leader>uD` | Normal | Dimming | Dim inactive code (`snacks.dim`) |
| `<leader>ug` | Normal | Indent guides | indent-blankline, buffer-local |
| `<leader>uG` | Normal | Git signs | gitsigns sign-column markers (mini.diff's number-column marks are separate) |
| `<leader>uh` | Normal | Inlay hints | LSP inlay hints (lua_ls and rust_analyzer) |
| `<leader>ul` | Normal | Line numbers | `number` + `relativenumber` together |
| `<leader>uL` | Normal | Relative numbers | `relativenumber` only |
| `<leader>us` | Normal | Spelling | `spell` |
| `<leader>uS` | Normal | Smooth scroll | Animated scrolling (`snacks.scroll`) |
| `<leader>uT` | Normal | Treesitter | Treesitter highlighting |
| `<leader>uw` | Normal | Wrap | `wrap` |
| `<leader>uW` | Normal | Readable width | Full window ↔ centred column (markdown sessions only) |
| `<leader>uz` | Normal | Zen mode | `Snacks.zen()` |
| `<leader>uZ` | Normal | Zoom | Maximize the current split |

Note `<leader>ud` is diagnostics and `<leader>uD` is dimming — the reverse of
what this config used before the LazyVim alignment.

The light/dark pair is also available as `:SoftPaperLight` and `:SoftPaperDark`.
The old three-way cycler (`<leader>ut`, `:ThemeCycle`) has been removed; the
soft-paper *dark* variant is now reachable only through `:SoftPaperDark` or the
`<leader>uC` picker.

---

## Quick Reference — Leader Key Groups

| Prefix | Domain |
|--------|--------|
| `<leader>f` | Fuzzy finder (fzf-lua) |
| `<leader>s` | Splits & window management |
| `<leader><Tab>` | Tabs (LazyVim group) |
| `<leader>t` | Tabs & terminal |
| `<leader>e` | File explorer (yazi) |
| `<leader>gh` | Git hunks (gitsigns) |
| `<leader>d` | Debugging (DAP) |
| `<leader>x` | Trouble (diagnostics panel) |
| `<leader>l` | Linting |
| `<leader>a` | Type checking / analysis |
| `<leader>m` | Markdown editing / Make (context-dependent) |
| `<leader>o` | _(unused — OpenCode keymaps removed)_ |
| `<leader>r` | Rust / Rename / Restart LSP |
| `<leader>c` | Code actions |
| `<leader>T` | Table mode |
| `<leader>v` | Vault (Obsidian) |
| `<leader>vt` | Vault: templates |
| `<leader>vf` | Vault: find & search |
| `<leader>ve` | Vault: edit & rename |
| `<leader>vm` | Vault: meta edit (frontmatter) |
| `<leader>vx` | Vault: tasks |
| `<leader>vg` | Vault: tags |
| `<leader>vc` | Vault: link checking |
| `<leader>vb` | Vault: pins & bookmarks |
| `<leader>vq` | Vault: query engine |
| `<leader>vk` | Vault: block IDs |

## Bracket Navigation Quick Reference

| Key | Action |
|-----|--------|
| `]d` / `[d` | Next / prev diagnostic |
| `]g` / `[g` | Next / prev git hunk |
| `]t` / `[t` | Next / prev TODO comment (or inline tag in markdown) |
| `]h` / `[h` | Next / prev heading (markdown) |
| `]1`-`]6` / `[1`-`[6` | Next / prev heading level 1-6 (markdown) |
| `]b` / `[b` | Next / prev code block (markdown) |
| `]l` / `[l` | Next / prev list item (markdown) |
| `]q` / `[q` | Next / prev blockquote (markdown) |
| `]m` / `[m` | Next / prev math zone (markdown/LaTeX) |
| `]o` / `[o` | Next / prev link (vault) |
| `]f` / `[f` | Next / prev inline field (vault) |
| `]e` / `[e` | Next / prev environment (LaTeX) |
| `]]` / `[[` | Next / prev section (LaTeX) |
| `[c` | Jump to context (treesitter) |
