# Neovim Configuration — Fixes & Improvements

> Tracked fixes, deprecation updates, and improvement candidates for this config.
> See `AGENTS.md` (lines 891–904) for the authoritative deprecation reference.

---

## 1. Deprecation Fixes (Neovim 0.11+)

These are breaking in future Neovim releases. Fix when touching the affected file.

### 1.1 API Replacements

- [ ] **`vim.highlight` → `vim.hl`**
  - File: `lua/andrew/core/keymaps.lua:71`
  - Change: `vim.highlight.on_yank` → `vim.hl.on_yank`

- [ ] **`vim.loop` → `vim.uv`**
  - File: `lua/andrew/lazy.lua:16`
  - Change: `vim.loop` → `vim.uv`

- [ ] **`vim.diagnostic.goto_prev/next()` → `vim.diagnostic.jump()`**
  - File: `lua/andrew/plugins/lsp/lspconfig.lua:277, 281`
  - Change: `goto_prev()` → `jump({ count = -1 })`, `goto_next()` → `jump({ count = 1 })`

- [ ] **`vim.lsp.stop_client()` → `client:stop()`**
  - File: `lua/andrew/plugins/lsp/lspconfig.lua:577`

- [ ] **`nvim_win_set_option()` → `vim.wo[winid]`**
  - File: `lua/andrew/custom/plugins/terminal.lua:143–153`
  - Change: replace each `nvim_win_set_option(winid, k, v)` with `vim.wo[winid][k] = v`

### 1.2 Plugin Repository Migrations

- [ ] **mason.nvim** — `williamboman/mason.nvim` → `mason-org/mason.nvim`
  - File: `lua/andrew/plugins/lsp/mason.lua`

- [ ] **mason-lspconfig.nvim** — `williamboman/mason-lspconfig.nvim` → `mason-org/mason-lspconfig.nvim`
  - File: `lua/andrew/plugins/lsp/mason.lua`

- [ ] **neodev.nvim** → **lazydev.nvim** — `folke/neodev.nvim` → `folke/lazydev.nvim`
  - File: `lua/andrew/plugins/lsp/lspconfig.lua` (dependency)

---

## 2. Missing `vim.opt` Settings

Settings that improve daily comfort and data safety.

- [x] **`vim.opt.undofile = true`** — persistent undo across sessions
- [x] **`vim.opt.scrolloff = 8`** — keep 8 lines visible above/below cursor
- [x] **`vim.opt.sidescrolloff = 8`** — horizontal equivalent (`wrap = false`)
- [x] **`vim.opt.updatetime = 250`** — faster CursorHold (default 4000ms is too slow for gitsigns/diagnostics)
- [x] **`vim.opt.showmode = false`** — lualine already displays the mode
- [x] **`vim.opt.pumheight = 15`** — limit completion popup height
- [x] **`vim.opt.swapfile = false`** — avoid swap prompts (git provides safety)
- [x] **`vim.opt.completeopt = "menu,menuone,noselect"`** — better native completion behavior

---

## 3. Which-Key Group Registration

Several keymap prefixes are not registered with which-key, so the popup shows raw keys instead of group names.

- [x] `<leader>l` → "Lint"
- [x] `<leader>a` → "Type Check"
- [x] `<leader>m` → "Make/Build"
- [x] `<leader>v` → "Vault"
- [x] `<leader>o` → "OpenCode"
- [x] `<leader>e` → "Explorer"
- [x] `<leader>t` → "Tab/Terminal"
- [x] `<leader>h` → "Git Hunks"

File: `lua/andrew/plugins/which-key.lua`

---

## 4. Treesitter Parsers

Primary languages missing from `ensure_installed`.

- [x] Add `"fortran"` — primary language, currently relies on Vim builtin syntax only
- [x] Add `"python"` — secondary language, improves indentation and incremental selection

File: `lua/andrew/plugins/treesitter.lua`

---

## 5. Missing Keymaps

- [ ] **Quickfix navigation** — `]q` / `[q` for `cnext` / `cprev` (workspace lint populates quickfix)
- [ ] **Window resizing** — `<C-Up/Down/Left/Right>` for `resize +2` / `vertical resize -2`
- [ ] **Visual line movement** — `J` / `K` in visual mode to move selected lines up/down

File: `lua/andrew/core/keymaps.lua`

---

## 6. Plugin Candidates

Plugins to evaluate. Sorted by impact.

### High Priority

- [ ] **`folke/flash.nvim`** — fast in-buffer jump to any character in 2–3 keystrokes; pairs with treesitter selection
- [ ] **`kdheepak/lazygit.nvim`** or **`NeogitOrg/neogit`** — full git workflow without leaving Neovim (commits, rebase, log, branches)
- [ ] **`nvim-treesitter/nvim-treesitter-context`** — sticky function/class/module scope at top of window; useful in long Fortran subroutines

### Medium Priority

- [ ] **`sindrets/diffview.nvim`** — multi-file diff view, merge conflict resolution, file history
- [ ] **`mbbill/undotree`** — visual undo history with branch navigation
- [ ] **`folke/persistence.nvim`** — auto-save/restore sessions per directory

### Low Priority

- [ ] **`rcarriga/nvim-notify`** — animated non-blocking notifications (replaces `vim.notify` default)
- [ ] **`kevinhwang91/nvim-ufo`** — treesitter/LSP-powered code folding with hover preview
