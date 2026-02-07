-- =============================================================================
-- Core Keybindings
-- =============================================================================
-- Global key mappings that apply to the entire editor.
-- These bindings are set before plugins load and provide essential editor navigation.

-- Set the leader key to space (all leader keymaps use this prefix)
vim.g.mapleader = " "

-- Local alias for vim.keymap to make keybinding definitions more concise
local keymap = vim.keymap

-- =============================================================================
-- Insert Mode Keybindings
-- =============================================================================

-- Exit insert mode quickly by typing "jk" (ergonomic alternative to Escape)
keymap.set("i", "jk", "<ESC>", { desc = "Exit insert mode with jk" })

-- =============================================================================
-- Normal Mode Keybindings
-- =============================================================================

-- Search-related keybindings
keymap.set("n", "<leader>nh", ":nohl<CR>", { desc = "Clear search results" })

-- Number manipulation keybindings
keymap.set("n", "<leader>+", "<C-a>", { desc = "Increment number under cursor" })
keymap.set("n", "<leader>-", "<C-x>", { desc = "Decrement number under cursor" })

-- =============================================================================
-- Window Management Keybindings
-- =============================================================================
-- These keybindings use the window prefix <leader>s for split operations

-- Create new splits for horizontal/vertical window layouts
keymap.set("n", "<leader>sv", "<C-w>v", { desc = "Split window vertically" })
keymap.set("n", "<leader>sh", "<C-w>s", { desc = "Split window horizontally" })

-- Window layout adjustments
keymap.set("n", "<leader>se", "<C-w>=", { desc = "Make all split windows equal size" })
keymap.set("n", "<leader>sx", "<cmd>close<CR>", { desc = "Close current split window" })

-- =============================================================================
-- Tab Management Keybindings
-- =============================================================================
-- These keybindings use the tab prefix <leader>t for tab operations

-- Tab creation and closure
keymap.set("n", "<leader>to", "<cmd>tabnew<CR>", { desc = "Open new tab" })
keymap.set("n", "<leader>tx", "<cmd>tabclose<CR>", { desc = "Close current tab" })

-- Tab navigation
keymap.set("n", "<leader>tn", "<cmd>tabn<CR>", { desc = "Go to next tab (navigate right)" })
keymap.set("n", "<leader>tp", "<cmd>tabp<CR>", { desc = "Go to previous tab (navigate left)" })

-- Move current buffer to a new tab
keymap.set("n", "<leader>tf", "<cmd>tabnew %<CR>", { desc = "Open current buffer in new tab" })

-- =============================================================================
-- Visual Feedback Autocommands
-- =============================================================================

-- Highlight text briefly after yanking (copying) to provide visual confirmation
-- This autocmd triggers on the TextYankPost event which fires after any yank operation
vim.api.nvim_create_autocmd("TextYankPost", {
  desc = "Highlight text briefly after yanking",
  group = vim.api.nvim_create_augroup("highlight-yank", { clear = true }),
  callback = function()
    -- Highlight the yanked text region for 300ms
    vim.highlight.on_yank({ higroup = "IncSearch", timeout = 300 })
  end,
})
