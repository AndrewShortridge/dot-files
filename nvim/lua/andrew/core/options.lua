-- =============================================================================
-- Core Editor Options
-- =============================================================================
-- Global Neovim options that apply to the entire editor.
-- These settings are fundamental and apply before any plugins load.

-- Configure netrw (built-in file explorer) to use tree style listing
vim.cmd("let g:netrw_liststyle = 3")

-- Plain values (boolean, number, string) are assigned through `vim.o`, whose
-- fields lua_ls knows the type of. `vim.opt` is kept for what only it does: a
-- list given as a table, and `:append()`. From Neovim 0.13 a `vim.opt` field is
-- typed `vim.Option`, so a plain value assigned to one is flagged
-- (assign-type-mismatch), although it sets the option exactly as `vim.o` does.

-- =============================================================================
-- Line Numbers
-- =============================================================================
-- Enable absolute line numbers and relative line numbers for better navigation
vim.o.number = true
vim.o.relativenumber = true

-- =============================================================================
-- Tabs and Indentation
-- =============================================================================
-- Configure tab behavior: 2 spaces for tabs, auto-expand tabs to spaces
vim.o.tabstop = 2     -- Number of spaces a tab character displays
vim.o.shiftwidth = 2  -- Number of spaces used for indentation
vim.o.expandtab = true  -- Convert tabs to spaces
vim.o.autoindent = true  -- Copy indentation from current line when starting new line

-- =============================================================================
-- Text Wrapping
-- =============================================================================
-- Disable automatic line wrapping
vim.o.wrap = false

-- =============================================================================
-- Search Options
-- =============================================================================
-- Configure case sensitivity for search
vim.o.ignorecase = true   -- Ignore case when searching
vim.o.smartcase = true    -- Become case-sensitive if search contains uppercase

-- =============================================================================
-- Cursor and UI
-- =============================================================================
-- Highlight the cursor line for better visibility
vim.o.cursorline = true

-- Enable true color support and dark background for terminal colors
vim.o.termguicolors = true  -- Enable 24-bit RGB color in terminal
vim.o.background = "dark"   -- Set background color scheme to dark
vim.o.signcolumn = "yes"    -- Always show sign column for diagnostics/git signs
vim.o.showtabline = 2       -- Always show the tabline (andrew/utils/tabline.lua
                            -- draws it; <leader>uA toggles it)

-- =============================================================================
-- Backspace Behavior
-- =============================================================================
-- Allow backspace to work on indent, end of line, and before insert position
vim.o.backspace = "indent,eol,start"

-- =============================================================================
-- Clipboard
-- =============================================================================
-- Use system clipboard as the default unnamed register for yank/put operations
vim.opt.clipboard:append("unnamedplus")

-- =============================================================================
-- Undo and Swap
-- =============================================================================
vim.o.undofile = true     -- Persistent undo across sessions
vim.o.swapfile = false    -- Avoid swap prompts (git provides safety)

-- =============================================================================
-- Scrolling
-- =============================================================================
vim.o.scrolloff = 8       -- Keep 8 lines visible above/below cursor
vim.o.sidescrolloff = 8   -- Horizontal equivalent for nowrap mode

-- Scroll wrapped lines by screen row instead of jumping a whole logical line.
-- Only has an effect where 'wrap' is on: markdown (via ftplugin/markdown.lua,
-- which sets it window-locally too) and any buffer where <leader>uw turns wrap
-- on. LazyVim sets this globally (config/options.lua:100); without it, toggling
-- wrap on a long-lined buffer scrolls in jarring multi-row jumps.
vim.o.smoothscroll = true

-- snacks.nvim animation kill-switch, read by Snacks.animate.enabled() and
-- flipped by <leader>ua. nil already behaves as true, so this is declarative
-- rather than load-bearing -- it matches LazyVim (config/options.lua:10) and
-- makes the global off-switch discoverable from the options file.
vim.g.snacks_animate = true

-- =============================================================================
-- Sessions
-- =============================================================================
-- What :mksession writes, for persistence.nvim (<leader>q, plugins/persistence.lua).
-- This is LazyVim's exact list (config/options.lua:91). Deltas from Neovim's
-- default `blank,buffers,curdir,folds,help,tabpages,winsize,terminal`:
--   + globals  -- persist g: variables (upper-case names only, per :h mksession)
--   + skiprtp  -- do not bake 'runtimepath'/'packpath' into the session file,
--                 which would otherwise pin a stale lazy.nvim plugin set
--   - blank    -- skip empty unnamed buffers
--   - terminal -- do NOT restore terminals. Load-bearing here: this config's
--                 floating terminal does its own buffer reuse, and restored
--                 terminal buffers would come back dead alongside it.
-- 'folds' is kept (as LazyVim keeps it) and is safe with the treesitter `expr`
-- folding markdown uses -- the session records fold STATE, and ftplugin/markdown
-- re-establishes foldmethod/foldexpr on FileType when the buffer reloads.
vim.opt.sessionoptions = { "buffers", "curdir", "tabpages", "winsize", "help", "globals", "skiprtp", "folds" }

-- =============================================================================
-- Performance and UI
-- =============================================================================
vim.o.updatetime = 250    -- Faster CursorHold (default 4000ms is too slow for gitsigns/diagnostics)
vim.o.showmode = false    -- Lualine already displays the mode
vim.o.pumheight = 15      -- Limit completion popup height
vim.o.completeopt = "menu,menuone,noselect"  -- Better native completion behavior

-- =============================================================================
-- Window Splitting
-- =============================================================================
-- Configure new window placement for splits
vim.o.splitright = true   -- Vertical splits open to the right of current window
vim.o.splitbelow = true   -- Horizontal splits open below current window
vim.o.splitkeep = "screen" -- Keep text on the same screen line when splitting
vim.o.winminwidth = 5     -- Never shrink a window narrower than this
