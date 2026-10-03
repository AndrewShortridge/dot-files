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
- [Git (`<leader>g`)](#git-leaderg)
- [Git Hunks (`<leader>gh`)](#git-hunks-leadergh)
- [Diff Overlay (mini.diff)](#diff-overlay-minidiff)
- [LSP & Code Actions (`<leader>c`, `g*`)](#lsp--code-actions-leaderc-g)
- [Rust (`<leader>r`)](#rust-leaderr)
- [Debug (`<leader>d`)](#debug-leaderd)
- [Lint (`<leader>L`)](#lint-leaderl)
  - [Fortran symbols and call sites](#fortran-symbols-and-call-sites)
  - [Fortran references](#fortran-references)
  - [Fortran capitalization rule](#fortran-capitalization-rule)
- [Type Check (`<leader>a`)](#type-check-leadera)
- [Trouble / Diagnostics (`<leader>x`)](#trouble--diagnostics-leaderx)
- [Make / Build (`<leader>m`)](#make--build-leaderm)
- [OpenCode AI (`<leader>o`)](#opencode-ai-leadero)
- [Quit / Session (`<leader>q`)](#quit--session-leaderq)
- [Vault (`<leader>v`)](#vault-leaderv)
- [Markdown Editing (`<leader>m` in .md files)](#markdown-editing-leaderm-in-md-files)
- [Bracket Navigation (`]`/`[`)](#bracket-navigation)
- [Text Objects](#text-objects)
- [Motions / Jumps (flash.nvim)](#motions--jumps-flashnvim)
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

**Icons.** Groups and mappings show nerd-font icons. Most come from which-key's own
built-in rule table (LazyVim defines no which-key icons of its own -- it relies on the
same built-ins). `lua/andrew/plugins/which-key.lua` closes the two gaps those leave:
groups whose names match no built-in pattern get an explicit `icon`, and an
`icons.rules` list maps this config's own vocabulary (template/task/query/meta/check/
vault/...) onto glyphs, so new mappings pick up an icon automatically from their
description. Rules are matched top-down, first hit wins, so specific patterns are
listed before generic ones. Covered by `tests/which_key_icons_spec.lua`.

| Prefix | Group | Description |
|--------|-------|-------------|
| `<leader>a` | Type Check | Run type checkers by language |
| `<leader>c` | Code Actions | LSP code actions |
| `<leader>c` | Code | Code actions, codelens, rename, format, diagnostics |
| `<leader>d` | Debug | DAP debugger controls (no longer shadowed by a diagnostic float) |
| `<leader>e` | Explorer | Yazi file explorer |
| `<leader>f` | Find/Files | fzf-lua fuzzy finder |
| `<leader>g` | Git | Git operations |
| `<leader>gh` | Hunks | Gitsigns hunk operations |
| `<leader>l` | Lint | Linting commands |
| `<leader>m` | Make/Build | Makefile build system (overridden to **Markdown** in `.md` files) |
| `<leader>o` | _(unused)_ | Was OpenCode AI; keymaps removed 2026-09-06 |
| `<leader>q` | Quit/Session | Quit all, save and restore sessions |
| `<leader>r` | Rust/Refactor | LSP rename + Rust-specific in `.rs` files |
| `<leader>s` | Split/Window | Window split management |
| `<leader><Tab>` | Tabs | LazyVim tab group (new/close/next/prev/first/last/only) |
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
| n | `<leader>na` | Increment number under cursor | Place cursor on a number, press `Space n a` to increase it |
| n | `<leader>nx` | Decrement number under cursor | Place cursor on a number, press `Space n x` to decrease it |

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

### Tabs -- LazyVim group (`<leader><Tab>`)

**Source:** `lua/andrew/core/keymaps.lua`

The `<leader><Tab>` group is LazyVim's, ported whole. It overlaps the older `<leader>t` keys above -- both work. `<leader><Tab>o` (close every other tab) and the first/last jumps have no `<leader>t` equivalent. Careful: `<leader><Tab>f` is *First Tab*, while `<leader>tf` opens the current buffer in a new tab.

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader><Tab><Tab>` | New Tab | Opens a blank new tab (same as `<leader>to`) |
| n | `<leader><Tab>d` | Close Tab | Closes the active tab (same as `<leader>tx`) |
| n | `<leader><Tab>o` | Close Other Tabs | Closes every tab except this one (`:tabonly`) |
| n | `<leader><Tab>]` | Next Tab | Switch to the tab on the right (same as `<leader>tn`) |
| n | `<leader><Tab>[` | Previous Tab | Switch to the tab on the left (same as `<leader>tp`) |
| n | `<leader><Tab>f` | First Tab | Jump to the leftmost tab (`:tabfirst`) |
| n | `<leader><Tab>l` | Last Tab | Jump to the rightmost tab (`:tablast`) |

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

## Git (`<leader>g`)

**Source:** `lua/andrew/plugins/git.lua` (a spec fragment for snacks.nvim)

Ported from LazyVim. Every key is a direct snacks.nvim call, so nothing depends
on LazyVim's util module. Hunk operations live one level deeper, under
[`<leader>gh`](#git-hunks-leadergh).

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>gg` | Lazygit (root dir) | Full lazygit TUI, opened at the git root |
| n | `<leader>gG` | Lazygit (cwd) | Same, but rooted at the current working directory |
| n | `<leader>gl` | Git log | Commit picker for the repo |
| n | `<leader>gL` | Git log (cwd) | Commits touching the current working directory |
| n | `<leader>gc` | Commits (fzf-lua) | Same idea as `gl`, through the fzf-lua UI |
| n | `<leader>gf` | Current file history | Every commit that touched this file |
| n | `<leader>gb` | Blame line | Commits behind the line under the cursor |
| n | `<leader>gs` | Git status | Changed files, with a diff preview |
| n | `<leader>gS` | Git stash | Browse stashes; `<CR>` applies one |
| n | `<leader>gd` | Git diff (hunks) | Every unstaged hunk in the repo |
| n | `<leader>gD` | Git diff (origin) | Diff against `origin`, grouped by file |
| n, x | `<leader>gB` | Git browse (open) | Open the current line or selection on the remote host |
| n, x | `<leader>gY` | Git browse (copy) | Copy that URL to the clipboard instead |

**Conditional keys.** `<leader>gg` / `<leader>gG` appear only when the `lazygit`
binary is on `$PATH` (it is). The GitHub keys `<leader>gi` `<leader>gI`
(issues) and `<leader>gp` `<leader>gP` (pull requests) appear only when the
`gh` binary is installed — it is **not**, so they are currently inactive.
Install `gh` and restart to get them.

---

## Git Hunks (`<leader>gh`)

**Source:** `lua/andrew/plugins/gitsigns.lua` (buffer-local on attach)

Use these to manage git changes line-by-line without leaving the editor:

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `]g` / `[g` | Next / previous hunk | Works in **every** filetype, markdown included |
| n | `]h` / `[h` | Next / previous hunk | LazyVim's keys. **Not bound in markdown** — see the note below |
| n | `]H` / `[H` | Last / first hunk | Jump straight to either end of the file |
| n | `<leader>ghs` | Stage hunk | Stage the hunk under cursor for commit |
| v | `<leader>ghs` | Stage hunk (visual) | Stage only the selected lines |
| n | `<leader>ghr` | Reset hunk | Discard changes in hunk under cursor |
| v | `<leader>ghr` | Reset hunk (visual) | Discard only selected changed lines |
| n | `<leader>ghS` | Stage entire buffer | Stage all changes in current file |
| n | `<leader>ghR` | Reset entire buffer | Discard all changes in current file |
| n | `<leader>ghu` | Undo stage hunk | Unstage the last staged hunk |
| n | `<leader>ghp` | Preview hunk inline | Show diff preview of hunk in popup |
| n | `<leader>ghb` | Blame line (full) | Show full git blame for current line |
| n | `<leader>ghB` | Blame buffer | Open a full blame view for the whole file |
| n | `<leader>ght` | Toggle line blame | Show/hide inline blame annotations |
| n | `<leader>ghd` | Diff this file | Open diff view for current file |
| n | `<leader>ghD` | Diff this against `~` | Diff against previous commit |
| o, x | `ih` | Select hunk (text object) | Use with operators: `dih` = delete hunk, `vih` = select hunk |

> **Leaving a diff.** `<leader>ghd` / `<leader>ghD` put the cursor in the **diff**
> window, so `:q` closes the diff and returns you to your file. Upstream gitsigns
> deliberately does the opposite — it restores focus to your file
> (`actions/diffthis.lua:161`) — which meant a reflexive `:q` closed *your file's*
> window and left you stranded in the `gitsigns://…` index buffer. That buffer is
> unlisted, so `:bnext` will not cycle back to your file, and `bufhidden=wipe`, so
> it disappears the moment you navigate away. Nothing was ever lost — the file,
> its signs and any mini.diff overlay are all still there — but it looks alarming.
> Pressing the key again while already in a diff is a no-op and will not move you.

> **Why `]g` exists as well as `]h`.** In markdown, `]h` / `[h` are already
> taken twice — `ftplugin/markdown.lua` binds them to next/previous heading and
> `vault/highlights.lua` rebinds them to next/previous `==highlight==`. Those are
> buffer-local maps, exactly like gitsigns', so binding `]h` unconditionally
> would make the winner depend on autocmd ordering. gitsigns therefore skips
> `]h` / `[h` in markdown buffers, and `]g` / `[g` is the alias that always
> works. `]H` / `[H` are free in every filetype and are always bound.

> **`<leader>ght` is not a LazyVim key.** It was `<leader>hB` before this port.
> LazyVim's `<leader>ghB` is "blame buffer", a different feature, so the inline
> blame toggle moved to `t` rather than being dropped.

---

---

## Diff Overlay (mini.diff)

**Source:** `lua/andrew/plugins/mini-diff.lua`

Runs **alongside** gitsigns rather than replacing it (LazyVim's `mini-diff`
extra disables gitsigns; this config does not). The split of work:

- **gitsigns** — sign column, `<leader>gh` staging, blame, and every hunk motion.
- **mini.diff** — the overlay, plus operator-style apply/reset and a hunk text object.

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>go` | Toggle diff overlay | Show the *old* content inline as virtual lines, above each change |
| n | `gh` + motion | Apply (stage) a range | `ghip` stages a paragraph, `ghih` the hunk under the cursor |
| n | `gH` + motion | Reset a range | `gHih` discards the hunk under the cursor |
| o, x | `gh` | Hunk range text object | Combine with any operator, or use it to extend a selection |

| Command | Description |
|---------|-------------|
| `:MiniDiffOverlay` | Same as `<leader>go` |
| `:MiniDiffToggle` | Enable/disable mini.diff for the current buffer |
| `:MiniDiffQuickfix` | Send every hunk in the buffer to the quickfix list |

> **Why hunk marks appear on the line number.** Both plugins mark the *same*
> hunks, so mini.diff uses `view.style = "number"` and tints the line number
> while gitsigns keeps the sign column. Setting it to `"sign"` would draw
> every hunk twice.

> **mini.diff's own `]h` / `[h` / `]H` / `[H` are disabled.** All four already
> belong to gitsigns, and in markdown `]h` / `[h` belong to headings and
> `==highlights==`. Nothing is lost — mini.diff reads the same git index, so
> its hunks *are* gitsigns' hunks.

> `gh` / `gH` shadow the built-in Select-mode starters, which nothing else in
> this config uses. They are unrelated to the `<leader>gh` hunks group.
> **On a buffer with no diff** — a picker preview, a leftover `<leader>gd` diff
> buffer, a terminal, help — all four keys report `mini.diff: no diff for this
> buffer` instead of raising. Upstream's `toggle_overlay()`, `textobject()` and
> `do_hunks()` each throw `E5108: (mini.diff) Buffer N is not enabled` there, so
> every upstream mapping is disabled and re-bound behind a guard.
> **The overlay is remembered per file.** Its state lives in mini.diff's
> per-buffer cache, which is destroyed on any buffer reload — including `:edit`
> and the reload that can follow a `<leader>ghd` diff — and re-created with the
> overlay off. A `User MiniDiffUpdated` hook re-applies your choice whenever
> mini.diff re-attaches, so it survives reloads. Turning it *off* is remembered
> just as well; it is never forced back on.

## LSP & Code Actions (`<leader>c`, `g*`)

**Source:** `lua/andrew/plugins/lsp/lspconfig.lua` (buffer-local on LspAttach)

### Go-To Navigation

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `gd` | Go to definition(s) | Jump to where symbol is defined; fzf picker if multiple |
| n | `gD` | Go to declaration | Jump to declaration (fallback to definition for fortls) |
| n | `gr` | Show references | List all files/lines that reference the symbol under cursor (Fortran: falls back to a project scan) |
| n | `gI` | Show implementations | List all implementations of an interface/abstract |
| n | `gy` | Show type definitions | Jump to the type definition of the symbol |
| n | `K` | Hover documentation | Show docs for symbol under cursor (Fortran MPI/OpenMP docs come from fortran-extras) |
| n | `gK` | Signature help | Same as `<C-k>`, in LazyVim's spelling |
| n, i | `<C-k>` | Signature help | Show function signature while typing arguments |
| n | `gai` | Incoming calls | Who calls the function under the cursor |
| n | `gao` | Outgoing calls | What the function under the cursor calls |
| n | `]]` / `[[` | Next / prev reference | Cycle references of the symbol under cursor (Snacks.words) |
| n | `<A-n>` / `<A-p>` | Next / prev reference (wrapping) | Same, but wraps around at the ends |

All of the above except `gD` are **capability-gated**: the key is bound only if
an attached server advertises the matching LSP method, so it is absent rather
than answering "not supported". `gD` is ungated because its fallback to
definitions is the whole point (fortls advertises no `declarationProvider`).

### Actions & Diagnostics

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
Code actions and friends now live under `<leader>c`, matching LazyVim -- see
the [Code (`<leader>c`)](#code-leaderc) section below.

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>D` | Buffer diagnostics (fzf picker) | Browse all warnings/errors in current file |
| n | `<leader>lr` | Restart LSP | Use when LSP seems stuck or after config changes |
| n | `<leader>lh` | Toggle inlay hints | Buffer-local; `<leader>uh` does the same thing globally |

Diagnostic navigation is global (it works without a language server, which
matters for nvim-lint and the Fortran workspace linter):

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>cd` | Line diagnostics (float) | Show diagnostic details for current line |
| n | `]d` / `[d` | Next / previous diagnostic | Any severity |
| n | `]e` / `[e` | Next / previous **error** | Skips warnings and hints. Shadowed in `.tex` buffers, where `]e`/`[e` navigate LaTeX environments |
| n | `]w` / `[w` | Next / previous **warning** | |

## Code (`<leader>c`)

**Source:** `lua/andrew/lsp_keymaps.lua` (LSP-gated), `lua/andrew/plugins/trouble.lua`,
`lua/andrew/plugins/formatting/conform.lua`, `lua/andrew/plugins/lsp/mason.lua`,
`lua/andrew/core/keymaps.lua`

LazyVim's `<leader>c` group, ported. Keys marked *gated* appear only when an
attached LSP server advertises the capability.

| Mode | Key | Description | Gated on |
|------|-----|-------------|----------|
| n, x | `<leader>ca` | Code Action (fzf picker with diff preview) | codeAction |
| n | `<leader>cA` | Source Action (applies a single `source.*` action with no prompt) | codeAction |
| n | `<leader>co` | Organize Imports | the `source.organizeImports` **kind** specifically |
| n, x | `<leader>cc` | Run Codelens | codeLens |
| n | `<leader>cC` | Refresh & Display Codelens | codeLens |
| n | `<leader>cr` | Rename symbol (was `<leader>rn`) | rename |
| n | `<leader>cR` | Rename **file**, updating imports via LSP | workspace/willRenameFiles |
| n | `<leader>cd` | Line diagnostics (was `<leader>d`) | -- |
| n, x | `<leader>cf` | Format now (ignores the auto-format toggle) | -- |
| n, x | `<leader>cF` | Format injected languages (fenced code blocks) | -- |
| n | `<leader>cs` | Document symbols -- **plus call sites in Fortran** | documentSymbol |
| n | `<leader>cS` | Workspace symbols -- **plus call sites in Fortran** | workspace/symbol |
| n | `<leader>cl` | LSP info -- fzf picker of attached clients | -- |
| n | `<leader>cm` | Mason | -- |

`<leader>cd` replaces the old `<leader>d`, which was simultaneously a mapping
and the prefix for the ten `<leader>d` debug keys -- the DAP menu could only be
reached by typing the second key inside `timeoutlen`. That collision is gone.

Symbol pickers are on `<leader>cs` / `<leader>cS`, with `<leader>ss` /
`<leader>sS` as LazyVim-spelled aliases for the same two fzf pickers. Both
lowercase keys are document symbols, both uppercase are workspace symbols.
LazyVim points `<leader>cs`/`<leader>cS` at Trouble instead; this config uses
the fzf pickers for both and leaves Trouble to the `<leader>x` group (which
still has `xw`/`xd`/`xe`/`xE` diagnostics, `xq`/`xl`, `xt` todo and `xf`/`xF`).
Auto-format toggles are `<leader>uf` (global) / `<leader>uF` (buffer).

**In Fortran buffers all four keys list call sites and variable declarations
as well as definitions** -- see
[Fortran symbols and call sites](#fortran-symbols-and-call-sites). `gr` there
falls back to a project scan when fortls has never heard of the name, which is
the normal case for COMMON-block variables -- see
[Fortran references](#fortran-references).

**Note:** nvim 0.12's built-in `grn`/`gra`/`grx`/`grr`/`gri`/`grt` are deleted
at startup, because binding `gr` to References would otherwise make every `gr`
press wait out `timeoutlen`. Each has a replacement above.

### Treesitter Selection

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<C-Space>` | Start/expand treesitter selection | Press repeatedly to expand selection to larger syntax nodes |
| n | `<BS>` | Shrink treesitter selection | Shrink back to smaller syntax node |
| n | `[c` | Jump to parent context | Jump to enclosing function/class (treesitter-context) |

---

## Quit / Session (`<leader>q`)

**Source:** `lua/andrew/plugins/persistence.lua` (session keys), `lua/andrew/core/keymaps.lua` (`qq`)

Sessions are saved automatically when you quit, and restored only when you ask.
One session per working directory, plus a separate one per git branch when the
branch is not `main`/`master`. Session files live in
`~/.local/state/nvim/sessions/`.

Nothing is saved unless at least one real file buffer is open, so quitting out of
an empty editor will not overwrite a good session.

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>qq` | Quit All | Close every window and exit (`:qa`). Not to be confused with `<leader>wq`, which quits one window |
| n | `<leader>qs` | Restore Session | Reopen the session for the current directory. Run it right after `nvim` in a project |
| n | `<leader>qS` | Select Session | Pick any saved session from a list; changes directory into it first |
| n | `<leader>ql` | Restore Last Session | Reopen the most recently saved session, whatever directory it belonged to |
| n | `<leader>qd` | Don't Save Current Session | Disarm saving for this run only, so quitting leaves the stored session untouched |

What is restored is controlled by `sessionoptions` in `lua/andrew/core/options.lua`:
open buffers, window layout, tabpages, the working directory and fold state.
Terminals are deliberately **not** restored -- the floating terminal manages its
own buffers.

## Rust (`<leader>r`)

**Source:** `lua/andrew/plugins/rustaceanvim.lua` (Rust buffers only)

Rename moved to `<leader>cr` and LSP restart to `<leader>lr`, so this group
is now purely Rust.

| Mode | Key | Description | Scope | How to Use |
|------|-----|-------------|-------|------------|
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

## Lint (`<leader>L`)

**Source:** `lua/andrew/plugins/linting.lua`

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `<leader>Ll` | Run linters for current buffer | Triggers the configured linter for current filetype |
| n | `<leader>Lm` | Run ruff (Python) | Manually run Python linter |
| n | `<leader>Lf` | Toggle Fortran linter | Cycle through available Fortran compilers for linting |
| n | `<leader>LF` | Run Fortran linter (debug mode) | Verbose output for troubleshooting lint issues |
| n | `<leader>Lw` | Lint entire Fortran workspace | Lint all `.f90` files in `code/` directory |
| n | `<leader>LW` | Clear workspace diagnostics | Remove all workspace-level lint diagnostics |
| n | `<leader>Lc` | Check Fortran capitalization | Flags intrinsics and project procedures that are not ALL CAPS |
| n | `<leader>LC` | Fix Fortran capitalization (buffer) | Uppercases every flagged name in the current buffer |
| n | `<leader>Lt` | Toggle the capitalization check | Turns the on-save style check on and off (`vim.g.fortran_case_check`) |

**Linters by filetype:** Python (ruff), Fortran (gfortran/mpiifx/ifort/ifx/nagfor), JS/TS (eslint), C/C++ (cppcheck)

### Fortran symbols and call sites

**Source:** `lua/andrew/fortran/scan.lua`, `lua/andrew/fortran/symbols.lua`

fortls answers `documentSymbol` and `workspace/symbol` with **definitions
only**, so searching for `Heating` finds the one line that declares it and none
of the lines that call it. In a Fortran buffer, `<leader>cs` / `<leader>ss`
(document) and `<leader>cS` / `<leader>sS` (workspace) therefore open a merged
picker instead. `:FortranSymbols` and `:FortranSymbolsWorkspace` do the same
thing by name. Every other filetype keeps the plain LSP picker.

Rows are laid out the way fzf-lua lays out LSP document symbols -- location
first, then the symbol -- so a Fortran picker and a basedpyright picker read
the same:

```
   4:18  [F Subroutine] TTMDiffuse
   9:19    [V Variable] T_e_new
   9:29    [V Ref] nlc2
  10:17    [V Variable] ixcell
```

(`F` and `V` stand in for the glyphs here.) Line and column are right-aligned
on the left, coloured with fzf-lua's own `FzfLuaPathLineNr` /
`FzfLuaPathColNr`; then a bracketed, coloured `<glyph> <Kind>` block; then the
name, indented under its container. The glyph, the colour, the bracket and the
indent unit all come from your own `lsp.symbols` fzf-lua config -- change it
once and both pickers change.

The workspace picker leads with the path as well, since its rows span files:

```
code/AddEnergy.f90:4:18    [F Subroutine] AddEnergy
code/AddEnergy.f90:4:28    [P Argument] ENT
```

Under that is one more field the picker never shows -- the machine-readable
`path:lnum:col:` that fzf-lua's `path.entry_to_file` parses to jump, preview
and fill the quickfix list. `--with-nth 2..` hides it; fzf still reports the
whole line on selection, so hiding it costs nothing.

Matching is scoped to the symbol with `--nth 2` (indices count fields of the
`--with-nth` *view*, so field 2 there is field 3 of the entry). Without it,
matching runs over the location too and a short query like `dift` fuzzy-matches
a subsequence spread across a file path -- against this project, 2451 rows
instead of 31.

The **kind names are Fortran's**, though: `Subroutine`, not `Function`;
`Common`, not `Object`. Each maps to an LSP `SymbolKind` only to borrow its
glyph and highlight group, and where your colorscheme leaves that group unset
(`@method` and `@typeparameter` usually are) a fallback is used, so no row ends
up grey while its neighbours are coloured.

The kind is ordinary searchable text, so type `call` in the picker to see only
call sites, `subroutine` to see only definitions:

| Kind | Meaning |
|------|---------|
| `Subroutine` `Function` `Module` `Program` `Type` `Interface` `Submodule` | a definition |
| `Call` | a `call NAME` statement, or `NAME(...)` where NAME is a procedure the project defines |
| `Variable` | a declared variable, including every COMMON block member |
| `Argument` | a dummy argument of a procedure header |
| `Common` | a COMMON block name |
| `Ref` | a use of a declared variable |

`Call` is restricted to project-defined names deliberately. Fortran spells a
function call and an array reference identically -- `Heating(t)` and `arr(i)`
are the same syntax -- so the only sound filter is whether the project actually
defines a procedure by that name. Without it every array index would be a hit.

**Every variable reference is in the list**, so any of them can be jumped to.
That is the bulk of it: on the project this was measured against, 19505 `Ref`
rows against 2085 declarations, 462 call sites and 114 definitions. It only
works because fzf matches the first field alone -- typing `dift` narrows 20185
rows to the thirty that name it. If you want one symbol with nothing else in
the list, that is [`gr`](#fortran-references).

Declarations are found in every spelling the language allows, including the
legacy ones that carry no `::`:

```fortran
COMMON /DIFFST/ dift, difx(0:n), &      ! [common] DIFFST, [var] dift, difx,
                dify(0:n)               ! [var] dify -- across the continuation
REAL*8 DEPTHZ(nlcz)                     ! [var] DEPTHZ
CHARACTER (LEN=17) nFile                ! [var] nFile
INTEGER, PARAMETER :: n = 10            ! [var] n  (and not `10`)
PARAMETER (ITTM = 9)                    ! [var] ITTM
SUBROUTINE Diffuse(nnode, dt)           ! [arg] nnode, [arg] dt
```

`REAL(8) FUNCTION Energy(t)` opens with a type keyword and declares no variable
at all, only the dummy argument `t`; `TYPE(State) :: s` declares `s`,
`TYPE :: State` defines a type, and `TYPE IS (t)` declares nothing.

**Include files are scanned too** (`*.h`, `*.inc`, `*.fh`), because that is
where F77-descended projects keep their entire declaration section. The
capitalization fixer still writes only to source files.

What the scan handles, none of which a `grep -w call` gets right:

- **Any amount of whitespace** between `call` and the callee. Two spaces, eight
  spaces and a tab are one call statement.
- **Case**: `CALL`, `Call` and `call` are one keyword; the name is reported
  with the spelling that is actually in the file.
- **Comments and string literals**: `! call Ghost(x)` and `'call Ghost(x)'` are
  not calls.
- **Continuations**: `call &` on one line puts the callee on the next.

The document picker reads the **buffer**, so unsaved edits are included, and
indents rows by program-unit nesting. The workspace picker reads from **disk**
via ripgrep, like every other grep-backed picker here, and is flat -- the same
split an LSP client makes between `documentSymbol` and `workspace/symbol`. It
builds 20185 rows in about 350 ms -- which needs the kind block memoized per
kind: resolving the glyph and colour per row, or recomputing a cache key from
`vim.g.colors_name` per row, cost 1.5 s. The cache is dropped on `ColorScheme`
instead.

Both pickers consult the project even for the current buffer, for two sets one
file cannot supply: which names are procedures, and which are declared
variables. The second matters more than it sounds -- in F77-descended code the
declarations live in `.h` includes, so a buffer that uses fifty variables often
declares none of them.

### Fortran references

**Source:** `lua/andrew/fortran/scan.lua` (`project_references`)

`gr` on a Fortran name asks fortls first and falls back to the project scanner
when the server comes back empty. `:FortranReferences` runs the scanner
directly, on the word under the cursor or on a name you pass it.

The fallback is not a nicety. In F77-descended code a variable is routinely
declared in the one way no language server looks at: `dift` appears in a COMMON
block, in a `.h` include, split across continuation lines, and gets its type
from `IMPLICIT` rather than from any declaration statement. fortls has never
heard of it, so `gr` used to return nothing. The scanner reads include files,
ignores comments and string literals, and needs no server running.

It is the **empty answer**, not the absence of a server, that selects the
scanner -- so `gr` behaves the same whether or not fortls is up, and a name
fortls *does* understand still gets its scope-aware answer.

Rows carry the same kinds as the symbol picker, so the declaration is labelled
rather than buried among its uses:

```
code/commonTTM.h:40:22    [V Variable] dift   COMMON/DIFFST/ dift,difx(0:n), &
code/TTMDiffuse.f90:99:32 [V Ref] dift        Time_curr=Time_curr+dift
```

This picker keeps a source-line column, which the symbol pickers drop.

Unlike the symbol picker this one matches on the **whole row**: every row names
the same symbol, so the useful way to narrow is by file or by surrounding code.

### Fortran capitalization rule

**Source:** `lua/andrew/fortran/case.lua`, `lua/andrew/fortran/intrinsics.lua`, `lua/andrew/fortran/keywords.lua`

House style: every intrinsic procedure, every procedure the project defines,
and every language keyword is written in FULL CAPITALS:

```fortran
MODULE SOLVER
  USE PHYSICS, ONLY: HEATING
  IMPLICIT NONE
  PUBLIC :: STEP
  TYPE :: STATE
    LOGICAL :: active = .TRUE.
  END TYPE STATE
CONTAINS
  SUBROUTINE STEP(s)
    TYPE(STATE), INTENT(INOUT) :: s
    IF (s%active .AND. .NOT. (s%t .LT. 0.0d0)) THEN
      CALL HEATING(s%t)
    END IF
  END SUBROUTINE STEP
END MODULE SOLVER
```

Variable names (`s`, `active`), comments, string literals and numeric literals
are never touched.

Fortran is case-insensitive, so the rewrite can never change what the code
means.

Findings are published as diagnostics in their own namespace, so they sit
alongside the compiler diagnostics rather than replacing them. The check runs
on read and on write, and also as part of `<leader>Ll` (buffer) and
`<leader>Lw` (workspace).

| Command | Effect |
|---------|--------|
| `:FortranCaseCheck` | Check the current buffer |
| `:FortranCaseCheck workspace` | Check every source file under the project root, and fill the quickfix list |
| `:FortranCaseFix` | Uppercase every flagged name in the current buffer |
| `:FortranCaseFix workspace` | Same across the whole project (asks first -- files not open in a buffer are written straight to disk) |
| `:FortranCaseClear` | Drop this rule's diagnostics |
| `:FortranCaseToggle` | Turn the on-save check on / off |

**Procedures.** `NAME(` in invocation position, `CALL NAME` with any whitespace
between the two, and `SUBROUTINE NAME` / `END SUBROUTINE NAME` so a procedure
and its calls cannot end up half-capitalized. Names the project does not define
and that are not intrinsics are never touched -- `arr(3)` and `Heating(t)` are
the same syntax, so an unknown name could be either.

Type specifications are excluded: `real(8) :: x` is a declaration and
`y = real(i)` is an intrinsic call, and they are the same six characters --
names that are both a type keyword and an intrinsic (`real`, `logical`, `len`,
`int`, `char`, `cmplx`, `dble`, `kind`) are skipped in declaration position.

**Language keywords**, in five classes (`lua/andrew/fortran/keywords.lua`):

| Class | Covers |
|-------|--------|
| `control` | `if` `then` `else` `do` `while` `select` `case` `default` `end` `cycle` `exit` `goto` `where` `forall` `associate` `block` `return` `stop` `call` |
| `unit` | `program` `module` `subroutine` `function` `interface` `contains` `use` `only` `result` `recursive` `pure` `elemental` `procedure` |
| `declaration` | `implicit` `none` `integer` `real` `character` `type` `class` `dimension` `allocatable` `pointer` `parameter` `intent` `public` `private` ... |
| `io` | `write` `read` `print` `open` `close` `inquire` `rewind` `flush` `format` |
| `memory` | `allocate` `deallocate` `nullify` |
| `operator` | `.and.` `.or.` `.not.` `.eqv.` `.neqv.` `.true.` `.false.` `.eq.` `.ne.` `.lt.` `.le.` `.gt.` `.ge.` |

The `operator` class is matched by its **dots**, not as identifiers, and only
the letters between them are rewritten -- so `.and.` becomes `.AND.` and the
replacement stays the same width. The dots are also what makes it safe: `and`,
`not` and `true` are all legal Fortran variable names, but `.and.` cannot be
anything else. For the same reason the three guards below do not apply to it --
`logical :: flag = .true.` sits right of a `::` and is still checked.

**Fortran reserves nothing** -- `integer :: if` is legal, so every keyword is
also a possible variable name. Uppercasing a variable is harmless but noisy, so
three positional guards suppress the shapes a variable of that name is written
in: right of a `::` (the declaration list is variable names), after a `%`
(`obj%count`), and followed by `=` (`format = '(A)'`, `iostat=ios`, `p => x`,
`type == 3`). A keyword introduces or terminates a statement, so it is never
followed by `=`.

Words too common as variable names for those guards to cover are left out of
the lists entirely -- `value`, `data`, `target`, `len`, `kind`, `error`, and
every I/O specifier (`unit`, `file`, `status`, `iostat`, ...), which are always
written `name=` anyway. `in` / `out` / `inout` are checked positionally, only
inside `intent(...)`.

**Unit names.** Module, submodule, program and derived-type names are checked
too (`vim.g.fortran_case_units`). They are not procedures, so they get a rule of
their own, anchored on the keyword that introduces or references them -- `type`
puts the name inside parentheses that belong to the *keyword*
(`type(State)`), and `use physics` has no parentheses at all:

| Written | Found |
|---------|-------|
| `module physics` / `end module physics` | `physics` |
| `use physics` / `use physics, only: x` | `physics` |
| `type :: State` / `end type State` | `State` |
| `type(State) :: s` / `class(State), pointer :: p` | `State` |
| `type, extends(State) :: Big` | `State` |
| `s = State(1.0d0)` | `State`, via the invocation scan |

Anchoring on the keyword is what keeps a variable that merely shares the name
out of it: `real :: state_of_charge` is untouched.

**Import and access lists.** `use m, only: Heating` and `public :: Heating`
name existing procedures with no parentheses and no `call`, so they get one
more rule -- without it a procedure's *calls* would be capitalized while the
line that exports it was not. The entity list of a `public` / `private` /
`protected` / `external` / `intrinsic` / `import` statement, and everything
after `only:`, is names. The entity list of a *type declaration* is not:
`real :: energy` declares a variable and is left alone even when the project
also defines a function called `Energy`.

**Configuration** (all optional, read live):

| Variable | Default | Effect |
|----------|---------|--------|
| `vim.g.fortran_case_check` | `true` | The on-save check |
| `vim.g.fortran_case_severity` | `"WARN"` | `ERROR` / `WARN` / `INFO` / `HINT` |
| `vim.g.fortran_case_intrinsics` | `true` | Check intrinsic procedures |
| `vim.g.fortran_case_defined` | `true` | Check procedures the project defines |
| `vim.g.fortran_case_documented` | `false` | Also check the names in `snippets/fortran-docs.json` (MPI, OpenMP, custom) |
| `vim.g.fortran_case_all_calls` | `false` | Also require `CALL` targets the project does not define (external libraries) |
| `vim.g.fortran_case_keywords` | `true` | `false` disables the keyword rule; a list picks classes, e.g. `{ "control", "operator" }` |
| `vim.g.fortran_case_units` | `true` | Check module / submodule / program / derived-type **names** |

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

**Keymaps removed 2026-09-06.** opencode.nvim is still installed and its
`init()` side effects still run, but the spec no longer declares any `keys`, so
nothing under `<leader>o` (or `<S-C-u>` / `<S-C-d>`) is bound and the plugin
never loads. The ten original bindings are preserved verbatim as a commented
block in `lua/andrew/plugins/opencode.lua`; uncomment it and delete the
`lazy = true` line to restore them.

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
| n | `<leader>vtl` | Literature note | Creates in `Library/<title>/` (PDF goes beside it) |
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

## Motions / Jumps (flash.nvim)

**Source:** `lua/andrew/plugins/flash.lua`

Jump anywhere on screen by typing a couple of characters and then the label
that appears at the match.

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n, x, o | `s{chars}{label}` | Flash jump | Type `s` then a few characters; press the shown label to jump. Works as a motion, so `ds{label}` deletes up to it |
| n, o | `S` | Flash treesitter | Labels every syntax node around the cursor, innermost first. `;` grows the selection, `,` shrinks it |
| o | `r` | Remote flash | `yr{label}iw` yanks a word somewhere else and returns the cursor here |
| o, x | `R` | Treesitter search | Type a pattern, then pick a syntax node around any match |
| c | `<C-s>` | Toggle flash search | At the `/` or `?` prompt, turn jump labels on for the search in flight |

Enhanced `f`/`F`/`t`/`T` (installed by flash itself, not listed above): after
`f{char}`, press `f` or `;` for the next match and `F` or `,` for the previous,
so a mistyped target is corrected without restarting. Restricted to the current
line, matching vanilla Vim.

**Not bound, on purpose:** `S` in visual mode stays with nvim-surround (wrap a
selection), and `<C-space>` stays with nvim-treesitter's incremental selection.
LazyVim binds flash to both; see the header comment in `flash.lua` for why this
config does not.

---

## Substitute / Surround / Comment

### Substitute

**Source:** `lua/andrew/plugins/substitute.lua`

Replace text using a register. Works like a "paste with motion" operator:

| Mode | Key | Description | How to Use |
|------|-----|-------------|------------|
| n | `gs{motion}` | Substitute with motion | `yiw` to yank a word, move to target, `gsiw` to replace it |
| n | `gss` | Substitute entire line | Replace entire line with register content |
| n | `gS` | Substitute to end of line | Replace from cursor to end of line |
| x | `gs` | Substitute visual selection | Select text, press `gs` to replace with register |

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
- **Fortran:** lsp, snippets, path, buffer (MPI/OpenMP completion comes from the in-process `fortran-extras` LSP server)
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
| `:FortranSymbols` | Fortran definitions **and call sites** in this buffer | fortran/symbols.lua |
| `:FortranSymbolsWorkspace` | Fortran definitions **and call sites** across the project | fortran/symbols.lua |
| `:FortranReferences [name]` | Every use of one Fortran name (default: word under cursor) | fortran/symbols.lua |
| `:FortranCaseCheck [workspace]` | Check procedure-name capitalization | fortran/case.lua |
| `:FortranCaseFix [workspace]` | Uppercase intrinsic / project procedure names | fortran/case.lua |
| `:FortranCaseClear` | Clear capitalization diagnostics | fortran/case.lua |
| `:FortranCaseToggle` | Toggle the on-save capitalization check | fortran/case.lua |

---

## LSP Servers

| Server | Language | Notes |
|--------|----------|-------|
| lua_ls | Lua | Conda path, workspace libs |
| fortls | Fortran | Project symbols; paired with the in-process `fortran-extras` server |
| fortran-extras | Fortran | In-process Lua LSP: MPI/OpenMP hover, signature help, completion |
| pylsp | Python | Jedi-based completion |
| ctags_lsp | C/C++ | For Fortran ISO_C_BINDING headers |
| rust-analyzer | Rust | Via rustaceanvim plugin |

---

*Generated from Neovim config at `~/.config/nvim/` — 300+ keybindings across 40+ Lua source files.*
