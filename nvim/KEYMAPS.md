# Neovim Keymaps — Complete Reference

> **Leader key: `Space`** | 300+ keybindings | 40+ source files
>
> Press `<Space>` and wait to see Which-Key popup with all available groups.
> Press `<leader>fk` to fuzzy-search all keybindings at runtime via fzf-lua.

---

## Table of Contents

- [Which-Key Groups Overview](#which-key-groups-overview)
- [Core Keymaps](#core-keymaps)
- [Navigation & Window Management](#navigation--window-management)
- [Find / Files (`<leader>f`)](#find--files-leaderf)
- [Explorer (`<leader>e`)](#explorer-leadere)
- [Git Hunks (`<leader>h`)](#git-hunks-leaderh)
- [LSP & Code Actions (`<leader>c`, `g*`)](#lsp--code-actions-leaderc-g)
- [Rust / Refactor (`<leader>r`)](#rust--refactor-leaderr)
- [Debug (`<leader>d`)](#debug-leaderd)
- [Lint (`<leader>l`)](#lint-leaderl)
- [Type Check (`<leader>a`)](#type-check-leadera)
- [Trouble / Diagnostics (`<leader>x`)](#trouble--diagnostics-leaderx)
- [Make / Build (`<leader>m`)](#make--build-leaderm)
- [OpenCode AI (`<leader>o`)](#opencode-ai-leadero)
- [Vault (`<leader>v`)](#vault-leaderv)
- [Markdown Editing (`<leader>m` in .md files)](#markdown-editing-leaderm-in-md-files)
- [Bracket Navigation (`]`/`[`)](#bracket-navigation)
- [Text Objects](#text-objects)
- [Substitute / Surround / Comment](#substitute--surround--comment)
- [Completion (Insert Mode)](#completion-insert-mode)
- [TeX / LaTeX](#tex--latex)
- [Special Buffers](#special-buffers)
- [Snippet Triggers](#snippet-triggers)
- [User Commands](#user-commands)
- [LSP Servers](#lsp-servers)

---

## Which-Key Groups Overview

Press `<Space>` then a letter to enter a group. Which-Key shows available sub-keys.

| Prefix | Group | Description |
|--------|-------|-------------|
| `<leader>a` | Type Check | Run type checkers by language |
| `<leader>c` | Code Actions | LSP code actions |
| `<leader>d` | Debug | DAP debugger controls |
| `<leader>e` | Explorer | Yazi file explorer |
| `<leader>f` | Find/Files | fzf-lua fuzzy finder |
| `<leader>g` | Git | Git operations |
| `<leader>h` | Git Hunks | Gitsigns hunk operations |
| `<leader>l` | Lint | Linting commands |
| `<leader>m` | Make/Build | Makefile build system (overridden to **Markdown** in `.md` files) |
| `<leader>o` | OpenCode | AI assistant (OpenCode) |
| `<leader>r` | Rust/Refactor | LSP rename + Rust-specific in `.rs` files |
| `<leader>s` | Split/Window | Window split management |
| `<leader>t` | Tab/Terminal | Tabs and floating terminal |
| `<leader>T` | Table Mode | Markdown table editing |
| `<leader>v` | Vault | Obsidian vault operations (70+ keymaps) |
| `<leader>x` | Trouble/Diag | Diagnostics and quickfix |

**Vault sub-groups:**

| Prefix | Sub-group |
|--------|-----------|
| `<leader>vt` | Templates |
| `<leader>vf` | Find |
| `<leader>vq` | Query |
| `<leader>ve` | Edit |
| `<leader>vx` | Tasks |
| `<leader>vc` | Check |
| `<leader>vm` | MetaEdit |
| `<leader>vg` | Tags |
| `<leader>vb` | Bookmarks/Pins |
| `<leader>vk` | Block IDs |

---

## Core Keymaps

**Source:** `lua/andrew/core/keymaps.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| i | `jk` | Exit insert mode | Type `jk` quickly instead of reaching for `Esc` |
| n | `<leader>nh` | Clear search highlights | After searching with `/`, press `Space nh` to remove yellow highlights |
| n | `<leader>+` | Increment number under cursor | Place cursor on a number, press `Space +` to increase it |
| n | `<leader>-` | Decrement number under cursor | Place cursor on a number, press `Space -` to decrease it |

**Auto-behavior:** Yanked text is highlighted for 300ms after `y` operations (TextYankPost autocmd).

---

## Navigation & Window Management

### Tmux/Pane Navigation

**Source:** `christoomey/vim-tmux-navigator` (plugin defaults)

Seamlessly move between Neovim splits and tmux panes with the same keys:

| Mode | Key | Description |
|------|-----|-------------|
| n | `<C-h>` | Move to left pane (tmux/nvim) |
| n | `<C-j>` | Move to bottom pane |
| n | `<C-k>` | Move to top pane |
| n | `<C-l>` | Move to right pane |

### Splits (`<leader>s`)

**Source:** `lua/andrew/core/keymaps.lua`, `vim-maximizer`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>sv` | Split window vertically | Creates a new pane to the right |
| n | `<leader>sh` | Split window horizontally | Creates a new pane below |
| n | `<leader>se` | Equalize all split sizes | Makes all splits equal width/height |
| n | `<leader>sx` | Close current split | Closes the focused split pane |
| n | `<leader>sm` | Maximize/restore current split | Toggles between maximized and normal split size |

### Tabs (`<leader>t`)

**Source:** `lua/andrew/core/keymaps.lua`, `lua/andrew/custom/plugins/terminal.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>to` | Open new tab | Opens a blank new tab |
| n | `<leader>tx` | Close current tab | Closes the active tab |
| n | `<leader>tn` | Next tab | Switch to the tab on the right |
| n | `<leader>tp` | Previous tab | Switch to the tab on the left |
| n | `<leader>tf` | Open current buffer in new tab | Useful for temporarily maximizing a file |
| n | `<leader>tt` | Toggle floating terminal | Opens/closes a persistent floating terminal window |

### Terminal Mode

When inside the floating terminal:

| Mode | Key | Description |
|------|-----|-------------|
| t | `<C-\><C-n>` | Exit terminal mode (return to normal mode) |
| t | `jk` | Exit terminal mode (same as above, faster) |

**Commands:** `:FloatingTerminal toggle|open|hide|close|restart|send <cmd>`

---

## Find / Files (`<leader>f`)

**Source:** `lua/andrew/plugins/fzf-lua.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>ff` | Find files in current directory | Fuzzy search file names; type partial names to filter |
| n | `<leader>fr` | Find recently opened files | Quickly reopen files you worked on recently |
| n | `<leader>fs` | Live grep (search string in cwd) | Search file contents; results update as you type |
| n | `<leader>fc` | Grep word under cursor | Place cursor on a word, press this to find all occurrences |
| n | `<leader>fk` | Search keybindings | Fuzzy-search all active keymaps to find any binding |
| n | `<leader>fh` | Search `:help` tags | Find Neovim help topics |
| n | `<leader>fH` | Grep through `:help` docs | Full-text search through help documentation |
| n | `<leader>ft` | Find TODO/FIXME comments | Lists all TODO, FIXME, HACK, etc. comments in project |

### Inside fzf Picker

These keys work when the fzf picker window is open:

| Key | Description |
|-----|-------------|
| `<C-n>` / `<C-p>` | Navigate list down/up |
| `<C-j>` / `<C-k>` | Scroll preview down/up |
| `<C-q>` | Select all + accept |
| `<CR>` (Enter) | Open in current window |
| `ctrl-s` | Open in horizontal split |
| `ctrl-v` | Open in vertical split |
| `ctrl-t` | Send to Trouble |
| `ctrl-q` | Send all to quickfix |

---

## Explorer (`<leader>e`)

**Source:** `lua/andrew/plugins/yazi.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>ee` | Open Yazi file explorer | Opens floating Yazi in cwd; navigate with Yazi keybindings |
| n | `<leader>ef` | Open Yazi at current file | Opens Yazi with current file highlighted |
| n | `<leader>ec` | Close explorer | Close the Yazi window |
| n | `<leader>er` | Refresh explorer | Reopen Yazi (refreshes file list) |

Inside Yazi: `<f1>` = help, `<C-s>` = grep in directory.

---

## Git Hunks (`<leader>h`)

**Source:** `lua/andrew/plugins/gitsigns.lua` (buffer-local on attach)

Use these to manage git changes line-by-line without leaving the editor:

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `]g` | Next git hunk | Jump to next changed section |
| n | `[g` | Previous git hunk | Jump to previous changed section |
| n | `<leader>hs` | Stage hunk | Stage the hunk under cursor for commit |
| v | `<leader>hs` | Stage hunk (visual) | Stage only the selected lines |
| n | `<leader>hr` | Reset hunk | Discard changes in hunk under cursor |
| v | `<leader>hr` | Reset hunk (visual) | Discard only selected changed lines |
| n | `<leader>hS` | Stage entire buffer | Stage all changes in current file |
| n | `<leader>hR` | Reset entire buffer | Discard all changes in current file |
| n | `<leader>hu` | Undo stage hunk | Unstage the last staged hunk |
| n | `<leader>hp` | Preview hunk inline | Show diff preview of hunk in popup |
| n | `<leader>hb` | Blame line (full) | Show full git blame for current line |
| n | `<leader>hB` | Toggle line blame | Show/hide inline blame annotations |
| n | `<leader>hd` | Diff this file | Open diff view for current file |
| n | `<leader>hD` | Diff this against `~` | Diff against previous commit |
| o, x | `ih` | Select hunk (text object) | Use with operators: `dih` = delete hunk, `vih` = select hunk |

---

## LSP & Code Actions (`<leader>c`, `g*`)

**Source:** `lua/andrew/plugins/lsp/lspconfig.lua` (buffer-local on LspAttach)

### Go-To Navigation

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `gd` | Go to definition(s) | Jump to where symbol is defined; fzf picker if multiple |
| n | `gD` | Go to declaration | Jump to declaration (fallback to definition for fortls) |
| n | `gR` | Show references | List all files/lines that reference the symbol under cursor |
| n | `gi` | Show implementations | List all implementations of an interface/abstract |
| n | `gt` | Show type definitions | Jump to the type definition of the symbol |
| n | `K` | Hover documentation | Show docs for symbol under cursor (Fortran: custom docs) |
| n, i | `<C-k>` | Signature help | Show function signature while typing arguments |

### Actions & Diagnostics

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n, v | `<leader>ca` | Code actions | Show available quick fixes and refactoring options |
| n | `<leader>rn` | Rename symbol | Rename a variable/function across the project |
| n | `<leader>rs` | Restart LSP | Use when LSP seems stuck or after config changes |
| n | `<leader>D` | Buffer diagnostics (fzf picker) | Browse all warnings/errors in current file |
| n | `<leader>d` | Line diagnostics (float) | Show diagnostic details for current line |
| n | `[d` | Previous diagnostic | Jump to previous warning/error |
| n | `]d` | Next diagnostic | Jump to next warning/error |

### Treesitter Selection

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<C-Space>` | Start/expand treesitter selection | Press repeatedly to expand selection to larger syntax nodes |
| n | `<BS>` | Shrink treesitter selection | Shrink back to smaller syntax node |
| n | `[c` | Jump to parent context | Jump to enclosing function/class (treesitter-context) |

---

## Rust / Refactor (`<leader>r`)

**Source:** `lua/andrew/plugins/rustaceanvim.lua` (Rust buffers only, except `rn`/`rs`)

| Mode | Key | Description | Scope | How to Use |
|------|-----|-------------|-------|------------|
| n | `<leader>rn` | Smart rename | All LSP buffers | Rename symbol project-wide |
| n | `<leader>rs` | Restart LSP | All LSP buffers | Restart when LSP is stuck |
| n | `<leader>rr` | Rust runnables | Rust only | Run a binary/example from picker |
| n | `<leader>rd` | Rust debuggables | Rust only | Debug a target from picker |
| n | `<leader>rt` | Rust testables | Rust only | Run a test from picker |
| n | `<leader>rm` | Expand macro | Rust only | See what a macro expands to |
| n | `<leader>rc` | Open Cargo.toml | Rust only | Quick jump to project manifest |
| n | `<leader>rp` | Go to parent module | Rust only | Navigate up the module tree |
| n | `<leader>re` | Explain error | Rust only | Show detailed error explanation |
| n | `<leader>rD` | Render diagnostics | Rust only | Pretty-print diagnostic details |
| n | `<leader>ca` | Rust code actions (overrides LSP) | Rust only | Rust-specific code actions |
| n | `K` | Rust hover actions (overrides LSP) | Rust only | Hover with Rust-specific actions |
| n | `J` | Join lines (Rust-aware) | Rust only | Smart line joining respecting Rust syntax |

---

## Debug (`<leader>d`)

**Source:** `lua/andrew/plugins/dap/dap.lua`, `dap-ui.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>db` | Toggle breakpoint | Click to add/remove breakpoint on current line |
| n | `<leader>dB` | Set conditional breakpoint | Prompts for condition expression |
| n | `<leader>dc` | Start / Continue | Begin debugging or resume after breakpoint |
| n | `<leader>do` | Step over | Execute current line without entering functions |
| n | `<leader>di` | Step into | Enter the function on current line |
| n | `<leader>dO` | Step out | Run until current function returns |
| n | `<leader>dt` | Terminate | Stop the debugger (or Rust testables in `.rs`) |
| n | `<leader>dC` | Run to cursor | Continue execution until cursor position |
| n | `<leader>dr` | Restart | Restart the debug session |
| n | `<leader>dR` | Toggle REPL | Open interactive debug console |
| n | `<leader>du` | Toggle DAP UI | Show/hide the debug panels (variables, stack, watches) |
| n, v | `<leader>de` | Evaluate expression | Evaluate expression under cursor or selected text |
| n | `<leader>df` | Float element | Show a debug element in a floating window |

---

## Lint (`<leader>l`)

**Source:** `lua/andrew/plugins/linting.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>ll` | Run linters for current buffer | Triggers the configured linter for current filetype |
| n | `<leader>lm` | Run ruff (Python) | Manually run Python linter |
| n | `<leader>lf` | Toggle Fortran linter | Cycle through available Fortran compilers for linting |
| n | `<leader>lF` | Run Fortran linter (debug mode) | Verbose output for troubleshooting lint issues |
| n | `<leader>lw` | Lint entire Fortran workspace | Lint all `.f90` files in `code/` directory |
| n | `<leader>lW` | Clear workspace diagnostics | Remove all workspace-level lint diagnostics |

**Linters by filetype:** Python (ruff), Fortran (gfortran/mpiifx/ifort/ifx/nagfor), JS/TS (eslint), C/C++ (cppcheck)

---

## Type Check (`<leader>a`)

**Source:** `lua/andrew/plugins/type-checker.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>ac` | Type check (auto-dispatch by filetype) | Runs the right checker for current file type |
| n | `<leader>aP` | Python: ruff check | Run ruff type/style check on current Python file |
| n | `<leader>aT` | Python: ty check | Run ty type checker on current Python file |
| n | `<leader>aR` | Rust: cargo check | Run `cargo check` for the Rust project |
| n | `<leader>aL` | Lua: lua-language-server --check | Check Lua project for type errors |
| n | `<leader>aF` | Fortran: current compiler | Type-check with whichever Fortran compiler is active |
| n | `<leader>aC` | C/C++: syntax & warnings | Check C/C++ file for syntax errors |
| n | `<leader>ag` | Fortran: mpif90/gfortran | Force gfortran for type checking |
| n | `<leader>ai` | Fortran: mpiifx/Intel | Force Intel compiler for type checking |
| n | `<leader>at` | Toggle Fortran compiler (mpif90/mpiifx) | Switch between gfortran and Intel |

---

## Trouble / Diagnostics (`<leader>x`)

**Source:** `lua/andrew/plugins/trouble.lua`

Trouble provides a structured list view for diagnostics, quickfix, and TODOs:

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>xw` | Workspace diagnostics | Show all warnings/errors across project |
| n | `<leader>xd` | Current file diagnostics | Show diagnostics for current buffer only |
| n | `<leader>xe` | Errors only (current file) | Filter to only errors in current file |
| n | `<leader>xE` | Errors only (workspace) | Filter to only errors across workspace |
| n | `<leader>xq` | Quickfix list | Open the quickfix list in Trouble |
| n | `<leader>xl` | Location list | Open the location list in Trouble |
| n | `<leader>xt` | TODO comments | List all TODO/FIXME/HACK comments |
| n | `<leader>xf` | fzf-lua results in Trouble | View fzf results in Trouble format |
| n | `<leader>xF` | fzf-lua file results in Trouble | View fzf file results in Trouble format |

---

## Make / Build (`<leader>m`)

**Source:** `lua/andrew/plugins/fortran-build.lua`

> **Note:** In markdown files, `<leader>m` is overridden to the [Markdown group](#markdown-editing-leaderm-in-md-files).

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>mb` | Build (pick Makefile) | Select a Makefile then run default target |
| n | `<leader>md` | Build debug | Run `debug` target from selected Makefile |
| n | `<leader>mc` | Clean | Run `clean` target from selected Makefile |
| n | `<leader>mr` | Run | Run `run` target from selected Makefile |
| n | `<leader>ma` | All targets | Run `all` target from selected Makefile |
| n | `<leader>ml` | Re-run last Makefile | Repeat the last Makefile command without re-picking |

---

## OpenCode AI (`<leader>o`)

**Source:** `lua/andrew/plugins/opencode.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>ot` | Toggle OpenCode panel | Open/close the AI assistant sidebar |
| n | `<leader>oa` | Ask about code at cursor | Sends cursor context to AI with a question prompt |
| v | `<leader>oa` | Ask about selected code | Sends selection to AI with a question prompt |
| n | `<leader>o+` | Add buffer to prompt | Include current file in AI context |
| v | `<leader>o+` | Add selection to prompt | Include selected text in AI context |
| n | `<leader>oe` | Explain code at cursor | Ask AI to explain the code under cursor |
| n | `<leader>on` | New session | Start a fresh conversation |
| n, v | `<leader>os` | Select prompt | Choose from available prompts |
| n | `<S-C-u>` | Scroll messages up | Scroll through AI conversation history |
| n | `<S-C-d>` | Scroll messages down | Scroll through AI conversation history |

---

## Vault (`<leader>v`)

### Templates (`<leader>vt`)

**Source:** `lua/andrew/vault/init.lua`

Create new notes from templates. Each opens a prompt for the note title and auto-populates frontmatter:

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>vtn` | Template picker (all types) | Choose any template from a list |
| n | `<leader>vtd` | Daily log | Creates today's daily log in `Log/` |
| n | `<leader>vtw` | Weekly review | Creates this week's review in `Log/` |
| n | `<leader>vts` | Simulation note | Creates in `Projects/<proj>/Simulations/` |
| n | `<leader>vta` | Analysis note | Creates in `Projects/<proj>/Analysis/` |
| n | `<leader>vtk` | Task note | Creates in `Projects/<proj>/Tasks/` |
| n | `<leader>vtm` | Meeting note | Creates in `Projects/<proj>/Meetings/` |
| n | `<leader>vtf` | Finding note | Creates in `Projects/<proj>/Findings/` |
| n | `<leader>vtl` | Literature note | Creates in `Library/` |
| n | `<leader>vtp` | Project dashboard | Creates `Projects/<name>/Dashboard.md` |
| n | `<leader>vtj` | Journal entry | Creates in `Projects/<proj>/Journal/` |
| n | `<leader>vtc` | Concept note | Creates in `Domains/<domain>/` |
| n | `<leader>vtM` | Monthly review | Creates monthly review in `Log/` |
| n | `<leader>vtQ` | Quarterly review | Creates quarterly review in `Log/` |
| n | `<leader>vtY` | Yearly review | Creates yearly review in `Log/` |

### Find (`<leader>vf`)

**Source:** `lua/andrew/vault/search.lua`, `backlinks.lua`, `outline.lua`, `tags.lua`, `pickers.lua`, `recent.lua`, `navigate.lua`, `saved_searches.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>vff` | Find vault files (frecency) | Files sorted by how often/recently you open them |
| n | `<leader>vfs` | Search vault content (live grep) | Full-text search across all vault notes |
| n | `<leader>vfn` | Find notes by name | Search notes by filename |
| n | `<leader>vfD` | Search filtered by folder | Pick a folder first, then search within it |
| n | `<leader>vfy` | Search by note type | Filter notes by their `type` frontmatter field |
| n | `<leader>vfb` | Backlinks to current note | See what notes link to this one |
| n | `<leader>vfl` | Forward links from current note | See what notes this one links to |
| n | `<leader>vfh` | Heading backlinks | Find links to specific headings in this note |
| n | `<leader>vfd` | Daily log list | Browse daily logs chronologically |
| n | `<leader>vfw` | Weekly review list | Browse weekly reviews |
| n | `<leader>vfW` | All reviews list | Browse all review types (weekly/monthly/quarterly/yearly) |
| n | `<leader>vfo` | Heading outline | Jump to any heading in current file |
| n | `<leader>vft` | Search by tag | Browse and select notes by frontmatter tags |
| n | `<leader>vfr` | Recent notes (frecency) | Recently opened notes sorted by frequency |
| n | `<leader>vfp` | Project picker | Quick jump to any project dashboard |
| n | `<leader>vfS` | Saved searches | Run previously saved search queries |

### Query (`<leader>vq`)

**Source:** `lua/andrew/vault/query/init.lua`

Renders Dataview-like query blocks written in vault query syntax:

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>vqr` | Render query block under cursor | Place cursor in a query block and render its output |
| n | `<leader>vqa` | Render all query blocks in file | Render every query block in the current file |
| n | `<leader>vqc` | Clear query output under cursor | Remove rendered output for one query |
| n | `<leader>vqx` | Clear all query outputs | Remove all rendered outputs in file |
| n | `<leader>vqq` | Toggle query block | Render or clear the query under cursor |
| n | `<leader>vqi` | Rebuild query index | Reindex vault for query engine |

### Edit (`<leader>ve`)

**Source:** `lua/andrew/vault/rename.lua`, `extract.lua`, `export.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>ver` | Rename note (updates all links) | Renames file and updates all wikilinks pointing to it |
| n | `<leader>veR` | Rename preview (dry-run) | See what would change without actually renaming |
| n | `<leader>vet` | Rename tag vault-wide | Rename a tag across all notes |
| v | `<leader>vex` | Extract selection to new note | Select text, extract it into a new note with a link left behind |
| n | `<leader>vep` | Export to PDF/HTML (pandoc) | Export current note using pandoc |

### Tasks (`<leader>vx`)

**Source:** `lua/andrew/vault/tasks.lua`, `quicktask.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>vxo` | Open tasks | List all open (uncompleted) tasks in vault |
| n | `<leader>vxa` | All tasks | List all tasks including completed |
| n | `<leader>vxs` | Tasks by state | Filter tasks by their state (picker) |
| n | `<leader>vxq` | Quick task capture | Quickly add a task to current note or daily log |

### Check (`<leader>vc`)

**Source:** `lua/andrew/vault/linkcheck.lua`, `linkdiag.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>vcb` | Check broken links (buffer) | Find broken wikilinks in current file |
| n | `<leader>vca` | Check broken links (vault) | Find broken wikilinks across entire vault |
| n | `<leader>vco` | Check orphan notes | Find notes with no incoming links |
| n | `<leader>vcd` | Toggle link diagnostics | Show/hide inline diagnostics for broken links |
| n | `<leader>vcf` | Fix broken link under cursor | Suggest corrections for the broken link |
| n | `<leader>vcF` | Fix all broken links (picker) | Browse and fix all broken links |

### MetaEdit (`<leader>vm`)

**Source:** `lua/andrew/vault/metaedit.lua`, `autofile.lua` (buffer-local, markdown)

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>vms` | Cycle `status` field | Cycle through valid status values for this note type |
| n | `<leader>vmp` | Cycle `priority` field | Cycle priority (1-5) |
| n | `<leader>vmm` | Cycle `maturity` field | Cycle maturity (Seed/Developing/Mature/Evergreen) |
| n | `<leader>vmt` | Toggle `draft` field | Toggle draft status on/off |
| n | `<leader>vmf` | Edit any frontmatter field | Pick a field from a list and edit its value |
| n | `<leader>vmv` | Auto-file: suggest move location | Suggests correct folder based on note type |

### Tags (`<leader>vg`)

**Source:** `lua/andrew/vault/tags.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>vga` | Add tag to frontmatter | Pick from existing tags or type a new one |
| n | `<leader>vgr` | Remove tag from frontmatter | Remove a tag from the tags list |

### Pins / Bookmarks (`<leader>vb`)

**Source:** `lua/andrew/vault/pins.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>vbp` | Toggle pin on current note | Pin/unpin the current note for quick access |
| n | `<leader>vbf` | List pinned notes | Browse all pinned notes |

### Block IDs (`<leader>vk`)

**Source:** `lua/andrew/vault/blockid.lua` (buffer-local, markdown)

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>vki` | Generate block ID for current line | Adds `^blk-xxxxx` to end of current line |
| n | `<leader>vkl` | Generate block ID + copy link | Generates ID and copies `[[note#^blk-xxxxx]]` to clipboard |

### Other Vault Keymaps

| Mode | Key | Description | Source |
|------|-----|-------------|--------|
| n | `<leader>vV` | Switch vault | init.lua |
| n | `<leader>vQ` | Quick capture to daily log | capture.lua |
| n | `<leader>vi` | Quick capture to inbox | capture.lua |
| n | `<leader>vG` | Local graph view | graph.lua |
| n | `<leader>vI` | Insert template fragment | fragments.lua |
| n | `<leader>vp` | Paste clipboard image | images.lua |
| n | `<leader>vP` | Set/show sticky project | pickers.lua |
| n | `<leader>vE` | Edit linked note in float | preview.lua |
| n | `<leader>vC` | Open calendar | navigate.lua |
| n | `<leader>v[` | Previous daily log | navigate.lua |
| n | `<leader>v]` | Next daily log | navigate.lua |
| n | `<leader>v{` | Previous weekly review | navigate.lua |
| n | `<leader>v}` | Next weekly review | navigate.lua |

### Wikilink Navigation (buffer-local, markdown)

**Source:** `lua/andrew/vault/wikilinks.lua`, `preview.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `gf` | Follow wikilink under cursor | Place cursor on `[[link]]` and press `gf` to open it |
| n | `gx` | Open link (browser for URLs) | Opens URLs in browser, wikilinks in editor |
| n | `]o` | Next wikilink | Jump to the next `[[link]]` in the file |
| n | `[o` | Previous wikilink | Jump to the previous `[[link]]` in the file |
| n | `K` | Preview linked note (hover) | Shows a popup preview of the linked note content |

---

## Markdown Editing (`<leader>m` in .md files)

**Source:** `ftplugin/markdown.lua` (buffer-local, overrides Make/Build group)

### Formatting

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n, v | `<leader>mb` | Toggle **bold** | Normal: toggles word under cursor; Visual: toggles selection |
| n, v | `<leader>mi` | Toggle *italic* | Normal: toggles word under cursor; Visual: toggles selection |
| n, v | `<leader>ms` | Toggle ~~strikethrough~~ | Normal: toggles word under cursor; Visual: toggles selection |
| n, v | `<leader>mc` | Toggle `inline code` | Normal: toggles word under cursor; Visual: toggles selection |
| v | `<leader>mk` | Create `[text](url)` link | Select text, press `<leader>mk`, enter URL |
| v | `<leader>mK` | Create/toggle `[[wikilink]]` | Select text, press `<leader>mK` to wrap in `[[]]` |

### Headings

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>m1` | Toggle heading level 1 | Adds/removes `# ` prefix on current line |
| n | `<leader>m2` | Toggle heading level 2 | Adds/removes `## ` prefix |
| n | `<leader>m3` | Toggle heading level 3 | Adds/removes `### ` prefix |
| n | `<leader>m4` | Toggle heading level 4 | Adds/removes `#### ` prefix |
| n | `<leader>m5` | Toggle heading level 5 | Adds/removes `##### ` prefix |
| n | `<leader>m6` | Toggle heading level 6 | Adds/removes `###### ` prefix |

### Folding

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<Tab>` | Toggle fold under cursor | Folds/unfolds the section under cursor |
| n | `<leader>mf` | Fold all | Collapse all sections (like overview mode) |
| n | `<leader>mu` | Unfold all | Expand all sections |
| n | `<leader>ml` | Set fold level (prompted) | Enter a number (1-6) to fold to that heading depth |

### Other

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>mx` | Cycle checkbox state | Cycles: ` ` -> `/` -> `x` -> `-` -> `>` -> ` `. Auto-adds `[completion:: date]` on `x` |
| n | `<leader>mp` | Paste clipboard image | Pastes image from clipboard into attachments folder and inserts link |
| n | `<leader>mz` | Toggle callout fold | Collapse/expand an Obsidian callout block (render-markdown) |
| n | `<leader>mj` | Jump to/from footnote | Toggle between footnote reference `[^1]` and its definition |
| n | `<leader>mn` | List all footnotes | Browse all footnotes in current file |

---

## Bracket Navigation

Bracket motions work in Normal, Visual, and Operator-pending modes (unless noted).

### Global

| Key | Description | Source |
|-----|-------------|--------|
| `]d` / `[d` | Next / prev diagnostic | LSP |
| `]g` / `[g` | Next / prev git hunk | gitsigns |
| `]t` / `[t` | Next / prev TODO comment | todo-comments |
| `[c` | Jump to context (parent scope) | treesitter-context |

### Markdown Only (buffer-local)

| Key | Description | Source |
|-----|-------------|--------|
| `]h` / `[h` | Next / prev heading (any level) | ftplugin/markdown.lua |
| `]1`-`]6` / `[1`-`[6` | Next / prev heading at level N | ftplugin/markdown.lua |
| `]o` / `[o` | Next / prev wikilink | wikilinks.lua |
| `]b` / `[b` | Next / prev code block | md-textobjects.lua |
| `]l` / `[l` | Next / prev list item | md-textobjects.lua |
| `]q` / `[q` | Next / prev blockquote | md-textobjects.lua |
| `]m` / `[m` | Next / prev math zone (`$...$` or `$$...$$`) | tex-motions.lua |

### TeX Only (buffer-local)

| Key | Description | Source |
|-----|-------------|--------|
| `]]` / `[[` | Next / prev section (supports count: `3]]`) | tex-motions.lua |
| `]e` / `[e` | Next / prev environment | tex-motions.lua |
| `]m` / `[m` | Next / prev math zone | tex-motions.lua |

### Vault Navigation

| Key | Description | Source |
|-----|-------------|--------|
| `<leader>v[` / `<leader>v]` | Previous / next daily log | vault/navigate |
| `<leader>v{` / `<leader>v}` | Previous / next weekly review | vault/navigate |

---

## Text Objects

Use with operators like `d`, `c`, `y`, or in Visual mode (`v`).

**Examples:** `dih` = delete git hunk, `cim` = change inside math zone, `yac` = yank around code block, `vic` = select inside command.

### Git

| Key | Description | Source |
|-----|-------------|--------|
| `ih` | Select git hunk | gitsigns |

### Markdown (buffer-local)

| Key | Description | Source |
|-----|-------------|--------|
| `ac` / `ic` | Around / inside code block | md-textobjects.lua |
| `al` / `il` | Around / inside list item | md-textobjects.lua |
| `aq` / `iq` | Around / inside blockquote | md-textobjects.lua |
| `am` / `im` | Around / inside math zone | tex-motions.lua |

### TeX (buffer-local)

| Key | Description | Source |
|-----|-------------|--------|
| `ae` / `ie` | Around / inside environment (`\begin{}`...`\end{}`) | tex-motions.lua |
| `am` / `im` | Around / inside math zone | tex-motions.lua |
| `ac` / `ic` | Around / inside command (`\cmd{...}`) | tex-motions.lua |

---

## Substitute / Surround / Comment

### Substitute

**Source:** `lua/andrew/plugins/substitute.lua`

Replace text using a register. Works like a "paste with motion" operator:

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `s{motion}` | Substitute with motion | `yiw` to yank a word, move to target, `siw` to replace it |
| n | `ss` | Substitute entire line | Replace entire line with register content |
| n | `S` | Substitute to end of line | Replace from cursor to end of line |
| x | `s` | Substitute visual selection | Select text, press `s` to replace with register |

### Surround

**Source:** `lua/andrew/plugins/surround.lua` (nvim-surround defaults)

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `ys{motion}{char}` | Add surrounding pair | `ysiw"` wraps word in `"quotes"`, `ysiw)` wraps in `(parens)` |
| n | `yss{char}` | Surround entire line | `yss)` wraps entire line in parentheses |
| n | `cs{old}{new}` | Change surrounding pair | `cs"'` changes `"quoted"` to `'quoted'` |
| n | `ds{char}` | Delete surrounding pair | `ds"` removes surrounding quotes |
| v | `S{char}` | Surround visual selection | Select text, press `S"` to wrap in quotes |

Custom surrounds: `e` = LaTeX environment (`\begin{env}...\end{env}`), `c` = LaTeX command (`\cmd{...}`).

### Comment

**Source:** `lua/andrew/plugins/comment.lua` (Comment.nvim defaults)

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `gcc` | Toggle comment on current line | Press `gcc` to comment/uncomment current line |
| n | `gc{motion}` | Toggle comment (linewise) over motion | `gcap` comments a paragraph, `gc3j` comments 3 lines down |
| n | `gb{motion}` | Toggle comment (blockwise) over motion | `gbc` toggles block comment on current line |
| v | `gc` | Toggle comment on selection (linewise) | Select lines, press `gc` to toggle comments |
| v | `gb` | Toggle comment on selection (blockwise) | Select text, press `gb` for block comments |

### Table Mode

**Source:** `lua/andrew/plugins/vim-table-mode.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>Tm` | Toggle table mode on/off | When on, `|` auto-formats tables and `Tab` moves between cells |
| i | `Tab` | Move to next cell | When table mode is on, in insert mode |
| i | `\|\|` | Create horizontal separator row | Type `||` at start of line to create `|---|---|` |

---

## Completion (Insert Mode)

**Source:** `lua/andrew/plugins/blink-cmp.lua`

| Key | Description | How to Use |
|-----|-------------|------------|
| `<C-n>` | Next completion item | Navigate down in the completion menu |
| `<C-p>` | Previous completion item | Navigate up in the completion menu |
| `<C-j>` | Scroll docs down | Scroll the documentation preview |
| `<C-k>` | Scroll docs up | Scroll the documentation preview |
| `<C-Space>` | Show completion menu | Manually trigger completion |
| `<C-e>` | Hide completion menu | Dismiss the completion popup |
| `<CR>` | Accept selected completion | Confirm the highlighted item (also expands snippets) |

**Snippet engine:** LuaSnip v2 (autosnippets enabled)
**Custom snippet dirs:** `snippets/` (VSCode-style), `luasnippets/` (Lua math autosnippets)

**Completion sources by filetype:**
- **Default:** lsp, path, snippets, buffer
- **Fortran:** fortran_docs, lsp, snippets, path, buffer
- **Markdown:** wikilinks, vault_tags, vault_frontmatter, lsp, snippets, path, buffer

---

## TeX / LaTeX

**Source:** `ftplugin/tex.lua`, `lua/andrew/utils/tex-motions.lua`

### Buffer-local Options

| Mode | Key | Description |
|------|-----|-------------|
| n | `j` / `k` | Visual-line movement (for wrapped text) |
| n | `<Tab>` | Toggle fold |
| n | `<leader>mf` | Fold all |
| n | `<leader>mu` | Unfold all |

### Motions & Text Objects

See [Bracket Navigation > TeX](#tex-only-buffer-local) and [Text Objects > TeX](#tex-buffer-local).

All TeX motions support `v:count` — e.g., `3]]` jumps forward 3 sections.

---

## Special Buffers

### Calendar (`<leader>vC`)

**Source:** `lua/andrew/vault/calendar.lua`

| Key | Description |
|-----|-------------|
| `<CR>` | Open daily log for selected day |
| `h` / `l` | Previous / next month |
| `H` / `L` | Previous / next year |
| `j` / `k` | Navigate down / up in grid |

### Graph (`<leader>vG`)

**Source:** `lua/andrew/vault/graph.lua`

| Key | Description |
|-----|-------------|
| `<CR>` | Navigate to note on current line |
| `gf` | Navigate to note on current line |

### Preview Float (`K` on wikilink)

**Source:** `lua/andrew/vault/preview.lua`

When a preview float is showing:

| Key | Description |
|-----|-------------|
| `<C-j>` / `<C-k>` | Scroll preview down / up |

### Edit Float (`<leader>vE`)

| Key | Description |
|-----|-------------|
| `q` | Save and close |
| `<Esc><Esc>` | Save and close |
| `<C-s>` | Save (keep open) |

### Popup/Input UI

| Key | Description |
|-----|-------------|
| `<CR>` | Submit |
| `q` / `<Esc>` | Cancel |

---

## Snippet Triggers

### LuaSnip Markdown Snippets (`luasnippets/markdown.lua`)

Type the trigger and press `<CR>` (via completion) or let autosnippets expand automatically.

#### Callouts

| Trigger | Expansion | Notes |
|---------|-----------|-------|
| `callout` | Callout block | Prompted for type |
| `callout-` | Collapsed callout | |
| `callout+` | Expanded callout | |
| `note`, `tip`, `warning`, `important`, `caution`, `info`, `todo`, `example`, `question`, `abstract`, `bug` | Callout by type | Each has collapsed variant with `-` suffix |
| `simulation`, `finding`, `meeting`, `analysis`, `literature`, `concept` | Vault-specific callouts | |

#### Callouts with Metadata

| Trigger | Expansion | Notes |
|---------|-----------|-------|
| `finding` | Finding callout with date, author, status fields | Structured metadata |
| `simulation` | Simulation callout with date, author, status fields | |
| `literature` | Literature callout with citation fields | |
| `analysis` | Analysis callout with methodology fields | |
| `meeting` | Meeting callout with attendees, agenda | |

#### Nested Callouts

| Trigger | Expansion |
|---------|-----------|
| `callout2` | Two-level nested callout |
| `callout3` | Three-level nested callout |

#### Dataview Queries

| Trigger | Expansion |
|---------|-----------|
| `dv` | Dataview TABLE query |
| `dvl` | Dataview LIST query |
| `dvt` | Dataview TASK query |
| `dvjs` | Dataview JS block |

#### Wiki Links & Embeds

| Trigger | Expansion |
|---------|-----------|
| `wl` | Wiki-link `[[]]` |
| `wla` | Wiki-link with alias `[[target\|alias]]` |
| `wlh` | Wiki-link with heading `[[note#heading]]` |
| `embed` | Embed `![[]]` |
| `embedh` | Embed with heading `![[note#heading]]` |

#### Tasks

| Trigger | Expansion |
|---------|-----------|
| `task` | Basic task `- [ ]` |
| `taskd` | Task with due date and priority |
| `taskp` | Task with priority only |

#### Structure

| Trigger | Expansion |
|---------|-----------|
| `code` | Fenced code block (language chooser) |
| `mermaid` | Mermaid diagram block |
| `fm` | Frontmatter block |
| `field` | Inline field `[key:: value]` |
| `fieldi` | Inline field (invisible) |
| `tbl` | Markdown table |

#### Section Templates (`;notetype-section` prefix)

These insert pre-structured sections for specific note types. All triggers begin with `;` followed by the note type and section name:

| Note Type | Example Triggers |
|-----------|-----------------|
| Meeting | `;meeting-full`, `;meeting-quick`, `;meeting-agenda`, `;meeting-discussion`, `;meeting-actions`, `;meeting-decisions`, `;meeting-followup` |
| Daily Log | `;daily-focus`, `;daily-priorities`, `;daily-worklog`, `;daily-scratchpad`, `;daily-completed`, `;daily-blockers`, `;daily-reflection`, `;daily-tomorrow` |
| Task | `;task-objective`, `;task-subtasks`, `;task-context`, `;task-approach`, `;task-log` |
| Concept | `;concept-core`, `;concept-explanation`, `;concept-evidence`, `;concept-counterpoints`, `;concept-connections` |
| Literature | `;lit-claim`, `;lit-results`, `;lit-methodology`, `;lit-relevance`, `;lit-figures`, `;lit-methods`, `;lit-questions`, `;lit-quotes`, `;lit-related` |
| Methodology | `;method-purpose`, `;method-approach`, `;method-params`, `;method-validation`, `;method-limitations` |
| Simulation | `;sim-purpose`, `;sim-params`, `;sim-input`, `;sim-methods`, `;sim-results`, `;sim-comparison`, `;sim-issues`, `;sim-feeds`, `;sim-postprocess`, `;sim-figures` |
| Analysis | `;analysis-objective`, `;analysis-runs`, `;analysis-methods`, `;analysis-results`, `;analysis-interpretation`, `;analysis-litcompare`, `;analysis-implications`, `;analysis-followup` |
| Finding | `;finding-summary`, `;finding-context`, `;finding-details`, `;finding-impact`, `;finding-resolution`, `;finding-lessons` |
| Changelog | `;changelog-summary`, `;changelog-major`, `;changelog-minor`, `;changelog-motivation` |
| Presentation | `;pres-audience`, `;pres-outline`, `;pres-talking`, `;pres-questions`, `;pres-postnotes` |
| Draft | `;draft-structure`, `;draft-figures`, `;draft-feedback`, `;draft-submission` |
| Journal | `;journal-observations`, `;journal-worked`, `;journal-challenges`, `;journal-questions` |
| Recurring Task | `;recurring-whatis`, `;recurring-checklist`, `;recurring-log` |
| Financial | `;financial-networth`, `;financial-income`, `;financial-expenses`, `;financial-goals`, `;financial-reflection` |
| Project Dashboard | `;project-objective`, `;project-focus`, `;project-pipeline`, `;project-decisions`, `;project-resources` |
| Area Dashboard | `;area-purpose`, `;area-status`, `;area-deadlines`, `;area-review` |
| Domain MOC | `;domain-concepts`, `;domain-subdomains`, `;domain-openquestions`, `;domain-emerging`, `;domain-resources` |
| Person | `;person-context`, `;person-feedback`, `;person-preferences`, `;person-conversations` |
| Asset | `;asset-details`, `;asset-documents`, `;asset-service`, `;asset-upcoming` |
| Weekly Review | `;weekly-accomplishments`, `;weekly-personal`, `;weekly-progress`, `;weekly-areas`, `;weekly-insights`, `;weekly-didntwork`, `;weekly-maintenance`, `;weekly-nextweek` |
| Monthly/Quarterly/Yearly | `;monthly-summary`, `;quarterly-overview`, `;yearly-strategic`, `;yearly-OKR` |
| Generic | `;notes`, `;open-questions`, `;action-items`, `;decision-log`, `;feeds-into`, `;log` |

#### Auto-expanding Math Delimiters

| Trigger | Result | Notes |
|---------|--------|-------|
| `mk` | Inline math `$...$` | **Auto-trigger** — only outside math zones |
| `dm` | Display math `$$...$$` | **Auto-trigger** — only outside math zones |

### LuaSnip TeX Snippets (`luasnippets/tex.lua`)

| Trigger | Expansion |
|---------|-----------|
| `beg` | `\begin{env}...\end{env}` |
| `sec` | `\section{}` |
| `ssec` | `\subsection{}` |
| `sssec` | `\subsubsection{}` |
| `eq` | `\begin{equation}...\end{equation}` |
| `ali` | `\begin{align*}...\end{align*}` |
| `enum` | `\begin{enumerate}...\end{enumerate}` |
| `item` | `\begin{itemize}...\end{itemize}` |
| `fig` | `\begin{figure}...\end{figure}` |
| `mk` | Inline math `$...$` (**auto-trigger**) |
| `dm` | Display math `\[...\]` (**auto-trigger**) |

### Math-Mode Auto-Snippets (active inside `$...$` or `$$...$$` zones)

These expand automatically when typing in a math zone. Shared across Markdown and TeX files.

#### Greek Letters (`;` prefix)

| Trigger | Result | Trigger | Result |
|---------|--------|---------|--------|
| `;a` | `\alpha` | `;A` | — |
| `;b` | `\beta` | `;B` | — |
| `;g` | `\gamma` | `;G` | `\Gamma` |
| `;d` | `\delta` | `;D` | `\Delta` |
| `;e` | `\epsilon` | `;E` | — |
| `;z` | `\zeta` | `;Z` | — |
| `;h` | `\eta` | `;H` | — |
| `;q` | `\theta` | `;Q` | `\Theta` |
| `;i` | `\iota` | `;I` | — |
| `;k` | `\kappa` | `;K` | — |
| `;l` | `\lambda` | `;L` | `\Lambda` |
| `;m` | `\mu` | `;M` | — |
| `;n` | `\nu` | `;N` | — |
| `;x` | `\xi` | `;X` | `\Xi` |
| `;p` | `\pi` | `;P` | `\Pi` |
| `;r` | `\rho` | `;R` | — |
| `;s` | `\sigma` | `;S` | `\Sigma` |
| `;t` | `\tau` | `;T` | — |
| `;f` | `\phi` | `;F` | `\Phi` |
| `;c` | `\chi` | `;C` | — |
| `;y` | `\psi` | `;Y` | `\Psi` |
| `;w` | `\omega` | `;W` | `\Omega` |

Variants: `;ve` = `\varepsilon`, `;vq` = `\vartheta`, `;vf` = `\varphi`

#### Fractions & Scripts

| Trigger | Result | Description |
|---------|--------|-------------|
| `ff` | `\frac{}{}` | Fraction |
| `//` | `\frac{}{}` | Fraction (alternate) |
| `td` | `^{}` | Generic superscript (power) |
| `sb` | `_{}` | Subscript |
| `sr` | `^{2}` | Squared |
| `cb` | `^{3}` | Cubed |
| `inv` | `^{-1}` | Inverse |

#### Operators & Relations

| Trigger | Result | Trigger | Result |
|---------|--------|---------|--------|
| `<=` | `\leq` | `>=` | `\geq` |
| `!=` | `\neq` | `~~` | `\approx` |
| `~=` | `\simeq` | `>>` | `\gg` |
| `<<` | `\ll` | `xx` | `\times` |
| `**` | `\cdot` | `->` | `\to` |
| `<-` | `\leftarrow` | `=>` | `\implies` |
| `iff` | `\iff` | `inn` | `\in` |
| `notin` | `\notin` | `sset` | `\subset` |
| `ssq` | `\subseteq` | `uu` | `\cup` |
| `nn` | `\cap` | `EE` | `\exists` |
| `AA` | `\forall` | | |

#### Big Operators

| Trigger | Result | Description |
|---------|--------|-------------|
| `sum` | `\sum_{}^{}` | Summation with limits |
| `prod` | `\prod_{}^{}` | Product with limits |
| `lim` | `\lim_{}` | Limit |
| `dint` | `\int_{}^{} \, d` | Definite integral |

#### Miscellaneous

| Trigger | Result | Description |
|---------|--------|-------------|
| `ooo` | `\infty` | Infinity |
| `par` | `\partial` | Partial derivative |
| `nab` | `\nabla` | Nabla/del operator |
| `...` | `\ldots` | Horizontal dots |
| `ddd` | `\, d` | Differential d |

#### Decorators / Accents

| Trigger | Result | Description |
|---------|--------|-------------|
| `hat` | `\hat{}` | Hat accent |
| `bar` | `\overline{}` | Overline |
| `vec` | `\vec{}` | Vector arrow |
| `dot` | `\dot{}` | Single dot |
| `ddot` | `\ddot{}` | Double dot |
| `tld` | `\tilde{}` | Tilde |

#### Delimiters

| Trigger | Result | Description |
|---------|--------|-------------|
| `lr(` | `\left(\right)` | Auto-sized parentheses |
| `lr[` | `\left[\right]` | Auto-sized brackets |
| `lr{` | `\left\{\right\}` | Auto-sized braces |
| `lr\|` | `\left\|\right\|` | Auto-sized pipes |
| `lra` | `\left\langle\right\rangle` | Auto-sized angle brackets |

#### Environments

| Trigger | Result |
|---------|--------|
| `pmat` | `\begin{pmatrix}...\end{pmatrix}` |
| `bmat` | `\begin{bmatrix}...\end{bmatrix}` |
| `case` | `\begin{cases}...\end{cases}` |

#### Text & Fonts

| Trigger | Result | Description |
|---------|--------|-------------|
| `textt` | `\text{}` | Text in math mode |
| `mcal` | `\mathcal{}` | Calligraphic |
| `mbb` | `\mathbb{}` | Blackboard bold |
| `mbf` | `\mathbf{}` | Bold |
| `mrm` | `\mathrm{}` | Roman |

#### Common Sets

| Trigger | Result |
|---------|--------|
| `RR` | `\mathbb{R}` |
| `ZZ` | `\mathbb{Z}` |
| `NN` | `\mathbb{N}` |
| `QQ` | `\mathbb{Q}` |
| `CC` | `\mathbb{C}` |

#### Readable Name Aliases (`;latex-*` prefix)

300+ readable-name aliases available in the completion menu. Type `;latex-` to browse:

- `;latex-alpha`, `;latex-beta`, ..., `;latex-omega` — Greek letters
- `;latex-alpha-hat`, `;latex-alpha-bar`, etc. — Decorated Greek
- `;latex-leq`, `;latex-geq`, `;latex-neq` — Relations
- `;latex-fraction`, `;latex-sqrt`, `;latex-nroot` — Operations
- `;latex-sum`, `;latex-integral`, `;latex-limit` — Big operators
- `;latex-norm`, `;latex-floor`, `;latex-ceil` — Delimiters
- `;latex-pmatrix`, `;latex-bmatrix` — Environments
- `;latex-sin`, `;latex-cos`, `;latex-log` — Functions
- And many more...

### JSON Snippets (VSCode format)

- **Markdown** (`snippets/markdown.json`): 22 snippets for callouts, dataview, frontmatter, tasks, wikilinks, headings, code blocks, tables.
- **Fortran** (`snippets/fortran.json` + `new-snippets.json`): 45+ snippets covering program structure, loops, functions, subroutines, types, interfaces, IO, allocations, modules, and comprehensive intrinsic function documentation.

---

## User Commands

| Command | Description | Source |
|---------|-------------|--------|
| `:VaultNew` | Create new vault note (template picker) | vault/init.lua |
| `:VaultDaily` | Create/open today's daily log | vault/init.lua |
| `:VaultCapture` | Quick capture to daily log | vault/capture.lua |
| `:VaultStickyProject` | Set sticky project | vault/pickers.lua |
| `:FloatingTerminal` | Toggle floating terminal | custom/plugins/terminal.lua |
| `:TypeCheck` | Run type checker for current filetype | plugins/type-checker.lua |
| `:TableModeToggle` | Toggle table editing mode | vim-table-mode |
| `:LspRestart` | Restart LSP server | built-in |
| `:TodoFzfLua` | Search TODO/FIXME comments | todo-comments + fzf-lua |

---

## LSP Servers

| Server | Language | Notes |
|--------|----------|-------|
| lua_ls | Lua | Conda path, workspace libs |
| fortls | Fortran | Custom hover docs, autocomplete, snippets |
| pylsp | Python | Jedi-based completion |
| ctags_lsp | C/C++ | For Fortran ISO_C_BINDING headers |
| rust-analyzer | Rust | Via rustaceanvim plugin |

---

*Generated from Neovim config at `~/.config/nvim/` — 300+ keybindings across 40+ Lua source files.*
