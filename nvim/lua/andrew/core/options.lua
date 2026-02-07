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
-- Window Splitting
-- =============================================================================
-- Configure new window placement for splits
opt.splitright = true   -- Vertical splits open to the right of current window
opt.splitbelow = true   -- Horizontal splits open below current window
