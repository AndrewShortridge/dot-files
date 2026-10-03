-- =============================================================================
-- Core Editor Options
-- =============================================================================
-- Global Neovim options that apply to the entire editor.
-- These settings are fundamental and apply before any plugins load.

-- Configure netrw (built-in file explorer) to use tree style listing
vim.cmd("let g:netrw_liststyle = 3")

-- Local alias for vim.opt to make configuration more concise
local opt = vim.opt

-- =============================================================================
-- Line Numbers
-- =============================================================================
-- Enable absolute line numbers and relative line numbers for better navigation
opt.number = true
opt.relativenumber = true

-- =============================================================================
-- Tabs and Indentation
-- =============================================================================
-- Configure tab behavior: 2 spaces for tabs, auto-expand tabs to spaces
opt.tabstop = 2     -- Number of spaces a tab character displays
opt.shiftwidth = 2  -- Number of spaces used for indentation
opt.expandtab = true  -- Convert tabs to spaces
opt.autoindent = true  -- Copy indentation from current line when starting new line

-- =============================================================================
-- Text Wrapping
-- =============================================================================
-- Disable automatic line wrapping
opt.wrap = false

-- =============================================================================
-- Search Options
-- =============================================================================
-- Configure case sensitivity for search
opt.ignorecase = true   -- Ignore case when searching
opt.smartcase = true    -- Become case-sensitive if search contains uppercase

-- =============================================================================
-- Cursor and UI
-- =============================================================================
-- Highlight the cursor line for better visibility
opt.cursorline = true

-- Enable true color support and dark background for terminal colors
opt.termguicolors = true  -- Enable 24-bit RGB color in terminal
opt.background = "dark"   -- Set background color scheme to dark
opt.signcolumn = "yes"    -- Always show sign column for diagnostics/git signs
opt.showtabline = 2       -- Always show the tabline (bufferline no longer
                          -- manages this; <leader>uA toggles it)

-- =============================================================================
-- Backspace Behavior
-- =============================================================================
-- Allow backspace to work on indent, end of line, and before insert position
opt.backspace = "indent,eol,start"

-- =============================================================================
-- Clipboard
-- =============================================================================
-- Use system clipboard as the default unnamed register for yank/put operations
opt.clipboard:append("unnamedplus")

-- =============================================================================
-- Undo and Swap
-- =============================================================================
opt.undofile = true     -- Persistent undo across sessions
opt.swapfile = false    -- Avoid swap prompts (git provides safety)

-- =============================================================================
-- Scrolling
-- =============================================================================
opt.scrolloff = 8       -- Keep 8 lines visible above/below cursor
opt.sidescrolloff = 8   -- Horizontal equivalent for nowrap mode

-- Scroll wrapped lines by screen row instead of jumping a whole logical line.
-- Only has an effect where 'wrap' is on: markdown (via ftplugin/markdown.lua,
-- which sets it window-locally too) and any buffer where <leader>uw turns wrap
-- on. LazyVim sets this globally (config/options.lua:100); without it, toggling
-- wrap on a long-lined buffer scrolls in jarring multi-row jumps.
opt.smoothscroll = true

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
opt.sessionoptions = { "buffers", "curdir", "tabpages", "winsize", "help", "globals", "skiprtp", "folds" }

-- =============================================================================
-- Performance and UI
-- =============================================================================
opt.updatetime = 250    -- Faster CursorHold (default 4000ms is too slow for gitsigns/diagnostics)
opt.showmode = false    -- Lualine already displays the mode
opt.pumheight = 15      -- Limit completion popup height
opt.completeopt = "menu,menuone,noselect"  -- Better native completion behavior

-- =============================================================================
-- Window Splitting
-- =============================================================================
-- Configure new window placement for splits
opt.splitright = true   -- Vertical splits open to the right of current window
opt.splitbelow = true   -- Horizontal splits open below current window
opt.splitkeep = "screen" -- Keep text on the same screen line when splitting
opt.winminwidth = 5     -- Never shrink a window narrower than this
