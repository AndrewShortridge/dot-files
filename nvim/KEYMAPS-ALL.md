# Complete Neovim Keymaps Reference

> **Leader key:** `<Space>`
> **Generated:** 2026-03-16
> **Total keybindings:** 300+ across all modes and contexts

---

## Table of Contents

1. [Core Keymaps](#core-keymaps)
2. [Fuzzy Finder (fzf-lua)](#fuzzy-finder-fzf-lua)
3. [LSP](#lsp)
4. [Completion (blink.cmp)](#completion-blinkcmp)
5. [Diagnostics & Trouble](#diagnostics--trouble)
6. [Git (Gitsigns)](#git-gitsigns)
7. [Debugging (DAP)](#debugging-dap)
8. [File Explorer (Yazi)](#file-explorer-yazi)
9. [Terminal](#terminal)
10. [Window Management](#window-management)
11. [Substitute](#substitute)
12. [Surround](#surround)
13. [Comment](#comment)
14. [TODO Comments](#todo-comments)
15. [Make/Build](#makebuild)
16. [Type Checking](#type-checking)
17. [Linting](#linting)
18. [Rust Development](#rust-development)
19. [OpenCode AI](#opencode-ai)
20. [Vault System](#vault-system)
21. [Markdown-Specific](#markdown-specific)
22. [LaTeX/TeX-Specific](#latextex-specific)
23. [Snippet Triggers](#snippet-triggers)
24. [Bracket Navigation Summary](#bracket-navigation-summary)
25. [Which-Key Groups](#which-key-groups)
26. [Source Files](#source-files)

---

## Core Keymaps

**Source:** `lua/andrew/core/keymaps.lua`

### Insert Mode

| Key | Action | Description |
|-----|--------|-------------|
| `jk` | `<ESC>` | Exit insert mode |

### Normal Mode — Search

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>nh` | `:nohl<CR>` | Clear search highlights |

### Normal Mode — Number Manipulation

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>+` | `<C-a>` | Increment number under cursor |
| `<leader>-` | `<C-x>` | Decrement number under cursor |

### Normal Mode — Window Splits

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>sv` | `<C-w>v` | Split window vertically |
| `<leader>sh` | `<C-w>s` | Split window horizontally |
| `<leader>se` | `<C-w>=` | Equalize split sizes |
| `<leader>sx` | `:close<CR>` | Close current split |

### Normal Mode — Tabs

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>to` | `:tabnew<CR>` | Open new tab |
| `<leader>tx` | `:tabclose<CR>` | Close current tab |
| `<leader>tn` | `:tabn<CR>` | Next tab |
| `<leader>tp` | `:tabp<CR>` | Previous tab |
| `<leader>tf` | `:tabnew %<CR>` | Open current buffer in new tab |

---

## Fuzzy Finder (fzf-lua)

**Source:** `lua/andrew/plugins/fzf-lua.lua`

### Normal Mode

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>ff` | `fzf-lua.files()` | Find files in current directory |
| `<leader>fr` | `fzf-lua.oldfiles()` | Find recently opened files |
| `<leader>fs` | `fzf-lua.live_grep()` | Live grep in current directory |
| `<leader>fc` | `fzf-lua.grep_cword()` | Grep word under cursor |
| `<leader>fk` | `fzf-lua.keymaps()` | Find keybindings |
| `<leader>fh` | `fzf-lua.help_tags()` | Search Neovim help tags |
| `<leader>fH` | `fzf-lua.live_grep(doc_paths)` | Grep Neovim help documentation |
| `<leader>ft` | `:TodoFzfLua<CR>` | Find TODO/FIXME comments |
| `<leader>vff` | vault frecency files | Vault: find files (frecency-sorted) |

### Inside fzf Window

| Key | Action |
|-----|--------|
| `<C-n>` | Select next item |
| `<C-p>` | Select previous item |
| `<C-j>` | Preview scroll down |
| `<C-k>` | Preview scroll up |
| `<C-s>` | Open in horizontal split |
| `<C-v>` | Open in vertical split |
| `<C-t>` | Open in new tab / Send to Trouble |
| `<C-q>` | Select all + send to quickfix |

---

## LSP

**Source:** `lua/andrew/plugins/lsp/lspconfig.lua` (set on `LspAttach` autocmd)

### Navigation

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `gR` | `fzf-lua.lsp_references()` | Show LSP references |
| n | `gD` | `vim.lsp.buf.declaration()` | Go to declaration (with definition fallback) |
| n | `gd` | `fzf-lua.lsp_definitions()` | Go to definitions |
| n | `gi` | `fzf-lua.lsp_implementations()` | Show implementations |
| n | `gt` | `fzf-lua.lsp_typedefs()` | Show type definitions |

### Code Actions

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n, v | `<leader>ca` | `vim.lsp.buf.code_action()` | See available code actions |
| n | `<leader>rn` | `vim.lsp.buf.rename()` | Smart rename symbol |

### Diagnostics

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>D` | `fzf-lua.diagnostics_document()` | Show buffer diagnostics |
| n | `<leader>d` | `vim.diagnostic.open_float()` | Show line diagnostics (float) |
| n | `[d` | `vim.diagnostic.jump({count=-1})` | Previous diagnostic |
| n | `]d` | `vim.diagnostic.jump({count=1})` | Next diagnostic |

### Documentation

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `K` | `vim.lsp.buf.hover()` | Show hover docs (Fortran: custom docs fallback) |
| n, i | `<C-k>` | `vim.lsp.buf.signature_help()` | Show signature help |
| n | `<leader>rs` | `:LspRestart<CR>` | Restart LSP server |

---

## Completion (blink.cmp)

**Source:** `lua/andrew/plugins/blink-cmp.lua`

### Insert Mode (completion menu active)

| Key | Action |
|-----|--------|
| `<C-p>` | Select previous completion |
| `<C-n>` | Select next completion |
| `<C-k>` | Scroll documentation up |
| `<C-j>` | Scroll documentation down |
| `<C-Space>` | Show completion menu |
| `<C-e>` | Hide completion menu |
| `<CR>` | Accept completion |

### Completion Sources by Filetype

| Filetype | Sources |
|----------|---------|
| Markdown | Wikilinks, vault tags, frontmatter, inline fields, LSP, snippets, path, buffer, spell |
| Fortran | LSP, Fortran docs (custom), snippets, path, buffer |
| All others | LSP, path, snippets, buffer |

---

## Diagnostics & Trouble

**Source:** `lua/andrew/plugins/trouble.lua`

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>xw` | `:Trouble preview_float toggle` | Workspace diagnostics (floating preview) |
| `<leader>xd` | `:Trouble preview_float toggle filter.buf=0` | Current file diagnostics |
| `<leader>xe` | `:Trouble ... filter.severity=ERROR` | Errors only (current file) |
| `<leader>xE` | `:Trouble ... filter.severity=ERROR` | Errors only (workspace) |
| `<leader>xq` | `:Trouble quickfix toggle` | Quickfix list |
| `<leader>xl` | `:Trouble loclist toggle` | Location list |
| `<leader>xt` | `:Trouble todo toggle` | TODO comments |
| `<leader>xf` | `:Trouble fzf toggle` | fzf-lua results in Trouble |
| `<leader>xF` | `:Trouble fzf_files toggle` | fzf-lua file results in Trouble |

---

## Git (Gitsigns)

**Source:** `lua/andrew/plugins/gitsigns.lua` (set on `on_attach`)

### Navigation

| Key | Action |
|-----|--------|
| `]g` | Next hunk |
| `[g` | Previous hunk |

### Hunk Operations

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>hs` | `gs.stage_hunk()` | Stage hunk |
| v | `<leader>hs` | `gs.stage_hunk(range)` | Stage hunk (visual selection) |
| n | `<leader>hr` | `gs.reset_hunk()` | Reset hunk |
| v | `<leader>hr` | `gs.reset_hunk(range)` | Reset hunk (visual selection) |
| n | `<leader>hS` | `gs.stage_buffer()` | Stage entire buffer |
| n | `<leader>hR` | `gs.reset_buffer()` | Reset entire buffer |
| n | `<leader>hu` | `gs.undo_stage_hunk()` | Undo stage hunk |
| n | `<leader>hp` | `gs.preview_hunk()` | Preview hunk |

### Blame & Diff

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>hb` | `gs.blame_line({full=true})` | Blame current line (full) |
| `<leader>hB` | `gs.toggle_current_line_blame()` | Toggle inline blame |
| `<leader>hd` | `gs.diffthis()` | Diff this file |
| `<leader>hD` | `gs.diffthis("~")` | Diff this against parent |

### Text Object

| Mode | Key | Action |
|------|-----|--------|
| o, x | `ih` | Select hunk |

---

## Debugging (DAP)

**Source:** `lua/andrew/plugins/dap/dap.lua`, `lua/andrew/plugins/dap/dap-ui.lua`

### Breakpoints & Flow

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>db` | `dap.toggle_breakpoint()` | Toggle breakpoint |
| `<leader>dB` | `dap.set_breakpoint(condition)` | Set conditional breakpoint |
| `<leader>dc` | `dap.continue()` | Start / Continue debugging |
| `<leader>do` | `dap.step_over()` | Step over |
| `<leader>di` | `dap.step_into()` | Step into |
| `<leader>dO` | `dap.step_out()` | Step out |
| `<leader>dt` | `dap.terminate()` | Terminate debugging |
| `<leader>dC` | `dap.run_to_cursor()` | Run to cursor |
| `<leader>dr` | `dap.restart()` | Restart debugging |
| `<leader>dR` | `dap.repl.toggle()` | Toggle REPL |

### DAP UI

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>du` | `dapui.toggle()` | Toggle DAP UI |
| n, v | `<leader>de` | `dapui.eval()` | Evaluate expression |
| n | `<leader>df` | `dapui.float_element()` | Float element |

---

## File Explorer (Yazi)

**Source:** `lua/andrew/plugins/yazi.lua`

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>ee` | `yazi.yazi()` | Toggle file explorer |
| `<leader>ef` | `yazi.yazi({path=current_file})` | Explorer on current file |
| `<leader>ec` | `:close<CR>` | Close explorer window |
| `<leader>er` | `yazi.yazi()` | Refresh explorer |

### Inside Yazi

| Key | Action |
|-----|--------|
| `<f1>` | Show help |
| `<C-s>` | Grep in directory |

---

## Terminal

**Source:** `lua/andrew/custom/plugins/terminal.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>tt` | `floating_terminal.toggle()` | Toggle floating terminal |
| t | `<C-\><C-n>` | exit terminal mode | Exit terminal mode |
| t | `jk` | exit terminal mode | Exit terminal mode (ergonomic) |

### Commands

- `:FloatingTerminal toggle` — Toggle visibility
- `:FloatingTerminal open` — Show terminal
- `:FloatingTerminal hide` — Hide terminal
- `:FloatingTerminal close` — Close and terminate
- `:FloatingTerminal restart` — Restart terminal
- `:FloatingTerminal send <cmd>` — Send command to terminal

---

## Window Management

**Source:** `lua/andrew/plugins/vim-maximizer.lua`

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>sm` | `:MaximizerToggle<CR>` | Maximize/minimize current split |

---

## Substitute

**Source:** `lua/andrew/plugins/substitute.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `s` | `substitute.operator()` | Substitute with motion (e.g. `siw` = inner word) |
| n | `ss` | `substitute.line()` | Substitute entire line |
| n | `S` | `substitute.eol()` | Substitute to end of line |
| x | `s` | `substitute.visual()` | Substitute selection |

---

## Surround

**Source:** `lua/andrew/plugins/surround.lua`

### Default nvim-surround Keymaps

| Key | Action | Example |
|-----|--------|---------|
| `ys{motion}{char}` | Add surround | `ysiw)` = surround inner word with `()` |
| `cs{old}{new}` | Change surround | `cs"'` = change `"` to `'` |
| `ds{char}` | Delete surround | `ds)` = remove surrounding `()` |
| `vS{char}` | Visual surround | Select text then `S)` to surround |

### Custom LaTeX Surrounds (in `.tex` files)

| Trigger | Result |
|---------|--------|
| `e` | `\begin{env}...\end{env}` environment |
| `c` | `\cmd{...}` command |

---

## Comment

**Source:** `lua/andrew/plugins/comment.lua` (default Comment.nvim keymaps)

| Mode | Key | Action |
|------|-----|--------|
| n | `gcc` | Toggle line comment |
| n | `gbc` | Toggle block comment |
| v | `gc` | Toggle comment (selection) |
| v | `gb` | Toggle block comment (selection) |

---

## TODO Comments

**Source:** `lua/andrew/plugins/todo-comments.lua`

| Key | Action |
|-----|--------|
| `]t` | Jump to next TODO/FIXME comment |
| `[t` | Jump to previous TODO/FIXME comment |

---

## Make/Build

**Source:** `lua/andrew/plugins/fortran-build.lua`

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>mb` | `pick_makefile("")` | Make: Build (pick Makefile) |
| `<leader>md` | `pick_makefile("debug")` | Make: Build Debug |
| `<leader>mc` | `pick_makefile("clean")` | Make: Clean |
| `<leader>mr` | `pick_makefile("run")` | Make: Run |
| `<leader>ma` | `pick_makefile("all")` | Make: All |
| `<leader>ml` | `run_make_in_split(last)` | Make: Re-run last Makefile |

---

## Type Checking

**Source:** `lua/andrew/plugins/type-checker.lua`

### Dispatch

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>ac` | `:TypeCheck<CR>` | Type check (auto-dispatch by filetype) |

### Language-Specific

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>aP` | `typecheck_python()` | Python type check (ruff check) |
| `<leader>aT` | `typecheck_python_ty()` | Python Ty type check |
| `<leader>aR` | `typecheck_rust()` | Rust cargo check |
| `<leader>aL` | `typecheck_lua()` | Lua language-server --check |
| `<leader>aF` | `typecheck_fortran()` | Fortran type check (current compiler) |
| `<leader>aC` | `typecheck_cpp()` | C/C++ syntax & warnings |

### Fortran-Specific

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>ag` | `typecheck_fortran_mpif90()` | Fortran (mpif90/gfortran) |
| `<leader>ai` | `typecheck_fortran_mpiifx()` | Fortran (mpiifx/Intel) |
| `<leader>at` | `toggle_fortran_typechecker()` | Toggle Fortran type checker |

---

## Linting

**Source:** `lua/andrew/plugins/linting.lua`

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>ll` | `require("lint").try_lint()` | Lint current buffer |
| `<leader>lm` | `require("lint").try_lint("ruff")` | Run ruff (Python) |
| `<leader>lf` | `toggle_fortran_linter()` | Toggle Fortran linter |
| `<leader>lF` | `debug_fortran_linter()` | Fortran linter (debug) |
| `<leader>lw` | `lint_workspace_fortran()` | Lint entire Fortran workspace |
| `<leader>lW` | `clear_workspace_diagnostics()` | Clear workspace diagnostics |

---

## Rust Development

**Source:** `lua/andrew/plugins/rustaceanvim.lua` (set on Rust buffer attach)

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>ca` | `:RustLsp codeAction` | Rust code actions |
| `K` | `:RustLsp hover actions` | Rust hover actions |
| `<leader>rr` | `:RustLsp runnables` | Rust runnables |
| `<leader>rd` | `:RustLsp debuggables` | Rust debuggables |
| `<leader>rt` | `:RustLsp testables` | Rust testables |
| `<leader>rm` | `:RustLsp expandMacro` | Expand macro recursively |
| `<leader>rc` | `:RustLsp openCargo` | Open Cargo.toml |
| `<leader>rp` | `:RustLsp parentModule` | Go to parent module |
| `J` | `:RustLsp joinLines` | Join lines (Rust-aware) |
| `<leader>re` | `:RustLsp explainError` | Explain error |
| `<leader>rD` | `:RustLsp renderDiagnostic` | Render diagnostics |
| `<leader>dt` | `:RustLsp testables` | Debugger testables |

---

## OpenCode AI

**Source:** `lua/andrew/plugins/opencode.lua`

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n | `<leader>ot` | `opencode.toggle()` | Toggle OpenCode panel |
| n | `<leader>oa` | `opencode.ask("@cursor: ")` | Ask about code at cursor |
| v | `<leader>oa` | `opencode.ask("@selection: ")` | Ask about selected code |
| n | `<leader>o+` | `opencode.prompt("@buffer", {append=true})` | Add buffer to prompt |
| v | `<leader>o+` | `opencode.prompt("@selection", {append=true})` | Add selection to prompt |
| n | `<leader>oe` | `opencode.prompt("Explain @cursor...")` | Explain code at cursor |
| n | `<leader>on` | `opencode.command("session_new")` | New OpenCode session |
| n | `<S-C-u>` | scroll up | Scroll OpenCode messages up |
| n | `<S-C-d>` | scroll down | Scroll OpenCode messages down |
| n, v | `<leader>os` | `opencode.select()` | Select OpenCode prompt |

---

## Vault System

**Source:** `lua/andrew/vault/init.lua` and submodules

### Templates (`<leader>vt`)

| Key | Description |
|-----|-------------|
| `<leader>vtn` | Template: picker (choose any) |
| `<leader>vtd` | Template: daily log |
| `<leader>vtw` | Template: weekly review |
| `<leader>vts` | Template: simulation |
| `<leader>vta` | Template: analysis |
| `<leader>vtk` | Template: task |
| `<leader>vtm` | Template: meeting |
| `<leader>vtf` | Template: finding |
| `<leader>vtl` | Template: literature |
| `<leader>vtp` | Template: project |
| `<leader>vtj` | Template: journal |
| `<leader>vtc` | Template: concept |
| `<leader>vtM` | Template: monthly review |
| `<leader>vtQ` | Template: quarterly review |
| `<leader>vtY` | Template: yearly review |

### Find (`<leader>vf`)

| Key | Description |
|-----|-------------|
| `<leader>vfs` | Search vault (content) |
| `<leader>vfn` | Search notes by name |
| `<leader>vfD` | Search filtered (by directory) |
| `<leader>vfy` | Search by YAML type |
| `<leader>vfA` | Advanced search (live grep) |
| `<leader>vfH` | Search history |
| `<leader>vfS` | Saved searches |
| `<leader>vfb` | Backlinks (current note) |
| `<leader>vfl` | Forward links (current note) |
| `<leader>vfh` | Heading backlinks |
| `<leader>vfo` | Document outline |
| `<leader>vft` | Tags |
| `<leader>vfT` | Tag tree |
| `<leader>vfr` | Recent notes (frecency) |
| `<leader>vfp` | Project dashboard |
| `<leader>vfu` | Unlinked mentions (buffer) |
| `<leader>vfU` | Unlinked mentions (vault) |
| `<leader>vfF` | Toggle inline field highlights |
| `<leader>vfd` | Daily log list |
| `<leader>vfw` | Weekly review list |
| `<leader>vfW` | All reviews list |

### Navigate

| Key | Description |
|-----|-------------|
| `<leader>v[` | Previous daily log |
| `<leader>v]` | Next daily log |
| `<leader>v{` | Previous weekly review |
| `<leader>v}` | Next weekly review |
| `<leader>vC` | Calendar view |
| `<leader>vdc` | Carry forward tasks |

### Edit (`<leader>ve`)

| Mode | Key | Description |
|------|-----|-------------|
| n | `<leader>ver` | Rename note |
| n | `<leader>veR` | Preview rename (dry-run) |
| n | `<leader>vet` | Rename tag |
| n | `<leader>vep` | Export (pandoc) |
| v | `<leader>vex` | Extract selection to new note |

### Meta / Fields (`<leader>vm`)

| Key | Description |
|-----|-------------|
| `<leader>vms` | Cycle status field |
| `<leader>vmp` | Cycle priority field |
| `<leader>vmm` | Cycle maturity field |
| `<leader>vmt` | Toggle draft field |
| `<leader>vmf` | Set any frontmatter field |
| `<leader>vmv` | Auto-file suggestion |
| `<leader>vM` | Frontmatter editor (full UI) |

### Tasks (`<leader>vx`)

| Key | Description |
|-----|-------------|
| `<leader>vxo` | Open tasks |
| `<leader>vxa` | All tasks |
| `<leader>vxs` | Tasks by state |
| `<leader>vxt` | Toggle task forward |
| `<leader>vxT` | Toggle task backward |
| `<leader>vxk` | Kanban board |
| `<leader>vxl` | Task timeline |
| `<leader>vxq` | Quick task |
| `<leader>vxd` | Overdue tasks / notifications |

### Check / Link Health (`<leader>vc`)

| Key | Description |
|-----|-------------|
| `<leader>vcb` | Check links (buffer) |
| `<leader>vca` | Check links (vault) |
| `<leader>vco` | Check orphans |
| `<leader>vcu` | Check URLs (buffer) |
| `<leader>vcU` | Check URLs (vault) |
| `<leader>vcr` | Repair broken links (buffer) |
| `<leader>vcR` | Repair broken links (vault) |
| `<leader>vcd` | Toggle link diagnostics |
| `<leader>vcf` | Fix broken link under cursor |
| `<leader>vcF` | Repair broken links (buffer, alternate) |
| `<leader>vch` | Toggle wikilink highlights |

### AutoLink (`<leader>va`)

| Key | Description |
|-----|-------------|
| `<leader>va` | Toggle autolink at cursor |
| `<leader>vA` | Accept autolink suggestion |
| `<leader>vaB` | Auto-link entire buffer |
| `<leader>vaV` | Auto-link entire vault |

### Tags & Graph (`<leader>vg`)

| Key | Description |
|-----|-------------|
| `<leader>vgt` | Toggle tag highlights |
| `<leader>vga` | Add tag to notes |
| `<leader>vgr` | Remove tag from notes |
| `<leader>vgA` | Accept autolink line |
| `<leader>vG` | Local graph view |

### Block IDs (`<leader>vk`)

| Key | Description |
|-----|-------------|
| `<leader>vki` | Generate block ID |
| `<leader>vkl` | Generate and link block ID |

### Bookmarks (`<leader>vb`)

| Key | Description |
|-----|-------------|
| `<leader>vbp` | Toggle pin (bookmark) |
| `<leader>vbf` | Find pinned notes |

### Sidebar (`<leader>vS`)

| Key | Description |
|-----|-------------|
| `<leader>vS` | Toggle sidebar |
| `<leader>vSf` | Focus sidebar |
| `<leader>vSb` | Sidebar: backlinks panel |
| `<leader>vSt` | Sidebar: tags panel |
| `<leader>vSm` | Sidebar: meta panel |

### Other Vault Keymaps

| Key | Description |
|-----|-------------|
| `<leader>vD` | Statistics dashboard |
| `<leader>vE` | Edit link in float |
| `<leader>vI` | Insert fragment |
| `<leader>vP` | Sticky project |
| `<leader>vQ` | Quick capture to daily |
| `<leader>vV` | Switch vault |
| `<leader>vW` | Toggle auto-save |
| `<leader>vi` | Capture to inbox |
| `<leader>vp` | Paste image |
| `<leader>vr` | Related notes |
| `<leader>v?` | Command palette |
| `K` | Preview link (markdown buffers) |
| `gf` | Follow wiki/markdown/URL link |
| `gx` | Open link in browser or follow |

### Vault Link Navigation (Markdown buffers)

| Key | Description |
|-----|-------------|
| `]o` | Next link |
| `[o` | Previous link |
| `]t` | Next tag |
| `[t` | Previous tag |
| `]h` | Next highlight |
| `[h` | Previous highlight |
| `]f` | Next inline field |
| `[f` | Previous inline field |

### Sidebar Internal Keymaps (buffer-local)

| Key | Action |
|-----|--------|
| `q` | Close sidebar |
| `<Esc>` | Return focus to main window |
| `1` / `b` | Switch to backlinks panel |
| `2` / `t` | Switch to tags panel |
| `3` / `m` | Switch to meta panel |
| `<Tab>` / `<S-Tab>` | Cycle panels |
| `R` | Refresh |
| `?` | Show help |

**Tags panel:** `<CR>` search, `<Space>`/`l` expand, `h` collapse, `zo` expand all, `zc` collapse all

**Backlinks panel:** `<CR>` jump, `o` open in split, `v` open in vsplit

**Meta panel:** `<CR>` edit field, `a` add field, `dd` delete field

### Graph Float Internal Keymaps

| Key | Action |
|-----|--------|
| `<CR>` / `gf` | Navigate to node |
| `f` | Filter / fuzzy find node |
| `+` / `-` | Zoom in / out (or adjust depth) |
| `r` | Recenter / reset view |
| `p` / `P` | Pan mode / load-save preset |
| `u` | Toggle unresolved |
| `s` | Search within graph / smart positioning |
| `?` | Show help |

### Calendar Internal Keymaps

| Key | Action |
|-----|--------|
| `<CR>` | Open day |
| `l` / `h` | Next / previous month |
| `L` / `H` | Next / previous year |
| `j` / `k` | Move week down / up |

### Frontmatter Editor Internal Keymaps

| Key | Action |
|-----|--------|
| `j` / `k` / `<Down>` / `<Up>` | Navigate fields |
| `<Tab>` / `<S-Tab>` | Navigate fields |
| `<CR>` / `l` | Edit field value |
| `a` | Add field |
| `dd` | Delete field |
| `q` / `<Esc>` | Close editor |

### Preview Float Internal Keymaps

| Key | Action |
|-----|--------|
| `<C-j>` / `<C-k>` | Scroll preview |
| `<C-o>` / `<BS>` | History back |
| `<C-i>` | History forward |
| `gf` / `K` | Follow link |
| `q` / `<C-h>` | Return to parent |
| `<CR>` | Focus preview |

---

## Markdown-Specific

**Source:** `ftplugin/markdown.lua` (active only in `.md` files)

### Folding

| Key | Action | Description |
|-----|--------|-------------|
| `<Tab>` | `toggle_fold()` | Smart fold toggle (callout-aware) |
| `za` | `toggle_fold()` | Toggle fold (alternative) |
| `<leader>mf` | `zM` | Fold all |
| `<leader>mu` | `zR` | Unfold all |
| `<leader>ml` | prompt | Set fold level (interactive) |
| `<leader>mz` | toggle callout fold | Toggle callout fold |
| `<leader>mZ` | clear callout folds | Clear all callout folds |
| `zd/zD/zE/zf/zF` | `<Nop>` | Disabled (expr foldmethod conflict) |

### Heading Navigation

| Key | Description |
|-----|-------------|
| `]h` | Next heading (any level) |
| `[h` | Previous heading |
| `]1` through `]6` | Next heading of level 1-6 |
| `[1` through `[6` | Previous heading of level 1-6 |

### Inline Formatting

| Mode | Key | Action | Description |
|------|-----|--------|-------------|
| n, v | `<leader>mb` | `toggle_markup("**")` | Toggle **bold** |
| n, v | `<leader>mi` | `toggle_markup("*")` | Toggle *italic* |
| n, v | `<leader>ms` | `toggle_markup("~~")` | Toggle ~~strikethrough~~ |
| n, v | `<leader>mc` | toggle_markup("`") | Toggle `inline code` |

### Headings

| Key | Description |
|-----|-------------|
| `<leader>m1` through `<leader>m6` | Toggle heading level 1-6 |

### Links

| Mode | Key | Description |
|------|-----|-------------|
| v | `<leader>mk` | Create `[text](url)` link (prompts for URL) |
| v | `<leader>mK` | Create/toggle `[[wikilink]]` |
| n | `<leader>mP` | Paste clipboard as link (word under cursor) |
| v, x | `<leader>mP` | Paste clipboard as link (selection) |
| x | `p` / `P` | Smart paste (auto-creates link if clipboard is URL) |

### Blockquotes & Callouts

| Mode | Key | Description |
|------|-----|-------------|
| n, v | `<leader>mq` | Add blockquote level |
| n, v | `<leader>mQ` | Remove blockquote level |
| n, v | `<leader>mC` | Create callout (prompts for type) |

### Tasks & Media

| Key | Description |
|-----|-------------|
| `<leader>mx` | Cycle checkbox state (forward) |
| `<leader>mp` | Paste clipboard image |

### Spell Checking

| Key | Description |
|-----|-------------|
| `<leader>mS` | Toggle spell check |
| `]s` | Next misspelling |
| `[s` | Previous misspelling |
| `z=` | Spell suggestions |
| `zg` | Add word to spellfile |
| `zw` | Mark word as bad |
| `zug` | Undo add to spellfile |

### Tables

| Key | Description |
|-----|-------------|
| `<leader>Tc` | Create table (interactive prompt) |
| `<leader>Tir` | Insert table row below |
| `<leader>Tdt` | Delete entire table |

### Footnotes

| Key | Description |
|-----|-------------|
| `<leader>mj` | Jump between footnote ref/definition |
| `<leader>mn` | List all footnotes |

### Smart List Continuation

| Mode | Key | Description |
|------|-----|-------------|
| n | `o` / `O` | Intelligent list continuation (new line below/above) |
| i | `<CR>` | Intelligent list continuation |

### Markdown Text Objects & Motions

| Key | Type | Description |
|-----|------|-------------|
| `am` / `im` | text object | Math block (around/inner) |
| `ac` / `ic` | text object | Code block (around/inner) |
| `al` / `il` | text object | List item (around/inner) |
| `aq` / `iq` | text object | Blockquote (around/inner) |
| `]m` / `[m` | motion | Next/prev math block |
| `]b` / `[b` | motion | Next/prev code block |
| `]l` / `[l` | motion | Next/prev list item |
| `]q` / `[q` | motion | Next/prev blockquote |

---

## LaTeX/TeX-Specific

**Source:** `ftplugin/tex.lua` (active only in `.tex` files)

### Visual Line Navigation

| Key | Action | Description |
|-----|--------|-------------|
| `j` | `gj` | Down (visual line, for wrapped text) |
| `k` | `gk` | Up (visual line) |

### Folding

| Key | Action | Description |
|-----|--------|-------------|
| `<Tab>` | `za` | Toggle fold |
| `<leader>mf` | `zM` | Fold all |
| `<leader>mu` | `zR` | Unfold all |
| `zd/zD/zE/zf/zF` | `<Nop>` | Disabled |

### TeX Motions

| Key | Type | Description |
|-----|------|-------------|
| `]]` / `[[` | motion | Next/prev section |
| `]e` / `[e` | motion | Next/prev environment |
| `]m` / `[m` | motion | Next/prev math mode |

### TeX Text Objects

| Key | Type | Description |
|-----|------|-------------|
| `ae` / `ie` | text object | Environment (around/inner) |
| `am` / `im` | text object | Math mode (around/inner) |
| `ac` / `ic` | text object | Command (around/inner) |

---

## Snippet Triggers

### Markdown Callout Snippets (`luasnippets/markdown.lua`)

| Trigger | Description |
|---------|-------------|
| `callout` | Generic callout (prompts for type) |
| `note` | NOTE callout |
| `tip` | TIP callout |
| `warning` | WARNING callout |
| `important` | IMPORTANT callout |
| `caution` | CAUTION callout |
| `info` | INFO callout |
| `todo` | TODO callout |
| `example` | EXAMPLE callout |
| `question` | QUESTION callout |
| `abstract` | ABSTRACT callout |
| `bug` | BUG callout |
| `simulation` | SIMULATION callout (vault-specific) |
| `finding` | FINDING callout (vault-specific) |
| `meeting` | MEETING callout (vault-specific) |
| `analysis` | ANALYSIS callout (vault-specific) |
| `literature` | LITERATURE callout (vault-specific) |
| `concept` | CONCEPT callout (vault-specific) |
| `target` | TARGET callout (vault-specific) |

**Collapsed variants:** Add `-` suffix (e.g., `note-`, `tip-`)
**Expanded variants:** Add `+` suffix (e.g., `note+`, `tip+`)

| Trigger | Description |
|---------|-------------|
| `;callout-nested` | Nested callouts |
| `;note-nested` | Pre-configured nested NOTE |
| `;warning-nested` | Pre-configured nested WARNING |
| `;example-nested` | Pre-configured nested EXAMPLE |
| `;callout-triple` | Triple-nested callouts |
| `;callout-meta` | Callout with metadata |
| `;finding-meta` | FINDING with metadata |
| `;simulation-meta` | SIMULATION with metadata |

### LaTeX Snippets (`luasnippets/tex.lua`)

| Trigger | Description |
|---------|-------------|
| `beg` | `\begin{} / \end{}` |
| `sec` | `\section{}` |
| `ssec` | `\subsection{}` |
| `sssec` | `\subsubsection{}` |
| `eq` | `\begin{equation} / \end{equation}` |
| `ali` | `\begin{align*} / \end{align*}` |
| `enum` | `\begin{enumerate} / \end{enumerate}` |
| `item` | `\begin{itemize} / \end{itemize}` |
| `fig` | `\begin{figure}` with graphics and caption |

### Math Autosnippets (Markdown + LaTeX)

| Trigger | Description |
|---------|-------------|
| `mk` | Inline math `$...$` |
| `dm` | Display math `\[...\]` |
| 100+ | Shared math symbols via `andrew.utils.tex` |

---

## Bracket Navigation Summary

Quick reference for all `]`/`[` navigation pairs:

| Key | Description | Source |
|-----|-------------|--------|
| `]d` / `[d` | Next/prev diagnostic | LSP |
| `]g` / `[g` | Next/prev git hunk | Gitsigns |
| `]t` / `[t` | Next/prev TODO comment | todo-comments |
| `]h` / `[h` | Next/prev heading | Markdown ftplugin |
| `]1`-`]6` / `[1`-`[6` | Next/prev heading by level | Markdown ftplugin |
| `]s` / `[s` | Next/prev misspelling | Vim spell |
| `]o` / `[o` | Next/prev link | Vault |
| `]f` / `[f` | Next/prev inline field | Vault |
| `]m` / `[m` | Next/prev math block | TeX/MD motions |
| `]b` / `[b` | Next/prev code block | MD motions |
| `]l` / `[l` | Next/prev list item | MD motions |
| `]q` / `[q` | Next/prev blockquote | MD motions |
| `]]` / `[[` | Next/prev section | TeX motions |
| `]e` / `[e` | Next/prev environment | TeX motions |
| `[c` | Jump to context (parent scope) | treesitter-context |

---

## Which-Key Groups

These are the top-level leader key groups registered for the which-key popup:

| Prefix | Group Name |
|--------|------------|
| `<leader>a` | Type Check |
| `<leader>c` | Code Actions |
| `<leader>d` | Debug |
| `<leader>e` | Explorer |
| `<leader>f` | Find / Files |
| `<leader>g` | Git |
| `<leader>h` | Git Hunks |
| `<leader>l` | Lint |
| `<leader>m` | Make/Build (Markdown in `.md` buffers) |
| `<leader>o` | OpenCode |
| `<leader>r` | Rust / Refactor |
| `<leader>s` | Split / Window |
| `<leader>t` | Tab / Terminal |
| `<leader>v` | Vault |
| `<leader>x` | Trouble / Diagnostics |

### Vault Sub-Groups

| Prefix | Group Name |
|--------|------------|
| `<leader>va` | AutoLink |
| `<leader>vb` | Bookmarks |
| `<leader>vc` | Check |
| `<leader>vd` | Daily |
| `<leader>ve` | Edit |
| `<leader>vf` | Find |
| `<leader>vg` | Graph / Tags |
| `<leader>vk` | BlockId |
| `<leader>vm` | Meta |
| `<leader>vq` | Query |
| `<leader>vS` | Sidebar |
| `<leader>vt` | Templates |
| `<leader>vx` | Tasks |
| `<leader>v?` | Palette |

---

## Source Files

All keymap definitions are spread across these files (relative to `~/.config/nvim/`):

| File | Category |
|------|----------|
| `lua/andrew/core/keymaps.lua` | Core editor keybindings |
| `lua/andrew/plugins/fzf-lua.lua` | Fuzzy finder |
| `lua/andrew/plugins/gitsigns.lua` | Git hunks |
| `lua/andrew/plugins/trouble.lua` | Diagnostics |
| `lua/andrew/plugins/lsp/lspconfig.lua` | LSP |
| `lua/andrew/plugins/blink-cmp.lua` | Completion |
| `lua/andrew/plugins/dap/dap.lua` | Debug adapter |
| `lua/andrew/plugins/dap/dap-ui.lua` | Debug UI |
| `lua/andrew/plugins/rustaceanvim.lua` | Rust |
| `lua/andrew/plugins/yazi.lua` | File explorer |
| `lua/andrew/plugins/opencode.lua` | AI assistant |
| `lua/andrew/plugins/type-checker.lua` | Type checking |
| `lua/andrew/plugins/fortran-build.lua` | Make/Build |
| `lua/andrew/plugins/linting.lua` | Linting |
| `lua/andrew/plugins/substitute.lua` | Substitute operator |
| `lua/andrew/plugins/surround.lua` | Surround operator |
| `lua/andrew/plugins/comment.lua` | Comment |
| `lua/andrew/plugins/todo-comments.lua` | TODO navigation |
| `lua/andrew/plugins/vim-maximizer.lua` | Window maximize |
| `lua/andrew/plugins/render-markdown.lua` | Callout fold toggle |
| `lua/andrew/plugins/which-key.lua` | Key group registrations |
| `lua/andrew/plugins/treesitter-context.lua` | Context jump |
| `lua/andrew/custom/plugins/terminal.lua` | Floating terminal |
| `lua/andrew/themes/toggle.lua` | Theme cycling |
| `lua/andrew/vault/init.lua` | Vault main (templates, meta, tasks, etc.) |
| `lua/andrew/vault/navigate.lua` | Daily/weekly navigation |
| `lua/andrew/vault/search.lua` | Vault search |
| `lua/andrew/vault/capture.lua` | Quick capture |
| `lua/andrew/vault/tags.lua` | Tag management |
| `lua/andrew/vault/backlinks.lua` | Backlinks |
| `lua/andrew/vault/wikilinks.lua` | Link following |
| `lua/andrew/vault/preview.lua` | Link preview |
| `lua/andrew/vault/sidebar.lua` | Sidebar panels |
| `lua/andrew/vault/graph.lua` | Graph view |
| `lua/andrew/vault/frontmatter_editor.lua` | Frontmatter editor |
| `lua/andrew/vault/calendar.lua` | Calendar view |
| `lua/andrew/vault/callout_folds.lua` | Callout folds |
| `lua/andrew/vault/autolink.lua` | AutoLink |
| `lua/andrew/vault/blockid.lua` | Block ID |
| `lua/andrew/vault/outline.lua` | Heading outline |
| `lua/andrew/vault/autosave.lua` | Auto-save |
| `lua/andrew/vault/task_kanban.lua` | Kanban view |
| `lua/andrew/vault/quicktask.lua` | Quick task |
| `lua/andrew/vault/images.lua` | Image paste |
| `lua/andrew/vault/command_palette.lua` | Command palette |
| `ftplugin/markdown.lua` | Markdown-specific keymaps |
| `ftplugin/tex.lua` | TeX-specific keymaps |
| `lua/andrew/utils/list-continuation.lua` | Smart list continuation |
| `lua/andrew/utils/tex-motions.lua` | TeX/math motions |
| `lua/andrew/utils/md-textobjects.lua` | Markdown text objects |
| `luasnippets/markdown.lua` | Markdown snippets |
| `luasnippets/tex.lua` | LaTeX snippets |
