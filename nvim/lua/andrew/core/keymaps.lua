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
keymap.set("n", "<leader>nh", "<cmd>nohlsearch<CR>", { desc = "Clear search results" })

-- Number manipulation keybindings. These live under <leader>n rather than
-- <leader>+ / <leader>- because LazyVim claims those two for window splits
-- (see below). Plain <C-a> / <C-x> still work natively.
keymap.set("n", "<leader>na", "<C-a>", { desc = "Increment number under cursor" })
keymap.set("n", "<leader>nx", "<C-x>", { desc = "Decrement number under cursor" })

-- =============================================================================
-- Diagnostics
-- =============================================================================
-- LazyVim's diagnostic layout (lazyvim/config/keymaps.lua:124-140), ported with
-- its exact keys and descriptions. These are GLOBAL on purpose: vim.diagnostic
-- needs no LSP client, so the old buffer-local versions (bound on LspAttach in
-- plugins/lsp/lspconfig.lua) were missing from exactly the buffers where nvim-lint
-- and the Fortran workspace linter put diagnostics without a language server.
--
-- <leader>cd replaces the old <leader>d, which was both a mapping AND the
-- prefix for the ten <leader>d debug keys -- so the DAP menu was only reachable
-- by typing the second key within timeoutlen (500ms). That collision is gone.
--
-- ]d/[d override nvim 0.12's own defaults (runtime lua/vim/_core/defaults.lua:263)
-- to add float = true. NOTE ]e/[e are shadowed inside .tex buffers, where
-- utils/tex-motions.lua binds them buffer-locally to environment navigation;
-- ]w/[w and ]d/[d work everywhere.
local function diagnostic_goto(next, severity)
  return function()
    vim.diagnostic.jump({
      count = (next and 1 or -1) * vim.v.count1,
      severity = severity and vim.diagnostic.severity[severity] or nil,
      float = true,
    })
  end
end

keymap.set("n", "<leader>cd", vim.diagnostic.open_float, { desc = "Line Diagnostics" })
keymap.set("n", "]d", diagnostic_goto(true), { desc = "Next Diagnostic" })
keymap.set("n", "[d", diagnostic_goto(false), { desc = "Prev Diagnostic" })
keymap.set("n", "]e", diagnostic_goto(true, "ERROR"), { desc = "Next Error" })
keymap.set("n", "[e", diagnostic_goto(false, "ERROR"), { desc = "Prev Error" })
keymap.set("n", "]w", diagnostic_goto(true, "WARN"), { desc = "Next Warning" })
keymap.set("n", "[w", diagnostic_goto(false, "WARN"), { desc = "Prev Warning" })

-- =============================================================================
-- Window Management Keybindings
-- =============================================================================
-- The <leader>w group mirrors LazyVim, which in turn mirrors the native <C-w>
-- submap one-for-one: every <leader>wX below runs <C-w>X. LazyVim produces this
-- group dynamically through which-key's `proxy` feature; we bind it out
-- explicitly instead so the keys work even before which-key has loaded and are
-- visible to :map and <leader>K.
--
-- NOTE two keys changed meaning when this group adopted LazyVim's layout:
--   <leader>wh  was "split horizontally", now "go to left window" (split is <leader>ws)
--   <leader>wx  was "close window",       now "swap with next"    (close is <leader>wd)
--
-- <C-w> itself is left completely untouched. Maximize (<leader>wm) lives in
-- plugins/vim-maximizer.lua so the key triggers that plugin's lazy load.

-- Move between windows. <C-h/j/k/l> do the same thing globally via
-- vim-tmux-navigator, which also crosses into tmux panes.
keymap.set("n", "<leader>wh", "<C-w>h", { desc = "Go to left window", remap = true })
keymap.set("n", "<leader>wj", "<C-w>j", { desc = "Go to lower window", remap = true })
keymap.set("n", "<leader>wk", "<C-w>k", { desc = "Go to upper window", remap = true })
keymap.set("n", "<leader>wl", "<C-w>l", { desc = "Go to right window", remap = true })
keymap.set("n", "<leader>ww", "<C-w>w", { desc = "Switch windows", remap = true })

-- Create and destroy windows
keymap.set("n", "<leader>ws", "<C-w>s", { desc = "Split window", remap = true })
keymap.set("n", "<leader>wv", "<C-w>v", { desc = "Split window vertically", remap = true })
keymap.set("n", "<leader>wd", "<C-w>c", { desc = "Delete window", remap = true })
keymap.set("n", "<leader>wq", "<C-w>q", { desc = "Quit a window", remap = true })
keymap.set("n", "<leader>wo", "<C-w>o", { desc = "Close all other windows", remap = true })

-- Resize windows
keymap.set("n", "<leader>w=", "<C-w>=", { desc = "Equally high and wide", remap = true })
keymap.set("n", "<leader>w+", "<C-w>+", { desc = "Increase height", remap = true })
keymap.set("n", "<leader>w-", "<C-w>-", { desc = "Decrease height", remap = true })
keymap.set("n", "<leader>w>", "<C-w>>", { desc = "Increase width", remap = true })
keymap.set("n", "<leader>w<", "<C-w><", { desc = "Decrease width", remap = true })
keymap.set("n", "<leader>w_", "<C-w>_", { desc = "Max out the height", remap = true })
keymap.set("n", "<leader>w|", "<C-w>|", { desc = "Max out the width", remap = true })

-- Rearrange windows
keymap.set("n", "<leader>wx", "<C-w>x", { desc = "Swap current with next", remap = true })
keymap.set("n", "<leader>wH", "<C-w>H", { desc = "Move window to far left", remap = true })
keymap.set("n", "<leader>wJ", "<C-w>J", { desc = "Move window to far bottom", remap = true })
keymap.set("n", "<leader>wK", "<C-w>K", { desc = "Move window to far top", remap = true })
keymap.set("n", "<leader>wL", "<C-w>L", { desc = "Move window to far right", remap = true })
keymap.set("n", "<leader>wT", "<C-w>T", { desc = "Break out into a new tab", remap = true })

-- Top-level split shortcuts, matching LazyVim's <leader>- / <leader>|
keymap.set("n", "<leader>-", "<C-w>s", { desc = "Split window below", remap = true })
keymap.set("n", "<leader>|", "<C-w>v", { desc = "Split window right", remap = true })

-- Resize the current window with the arrow keys, 2 cells at a time
keymap.set("n", "<C-Up>", "<cmd>resize +2<CR>", { desc = "Increase window height" })
keymap.set("n", "<C-Down>", "<cmd>resize -2<CR>", { desc = "Decrease window height" })
keymap.set("n", "<C-Left>", "<cmd>vertical resize -2<CR>", { desc = "Decrease window width" })
keymap.set("n", "<C-Right>", "<cmd>vertical resize +2<CR>", { desc = "Increase window width" })

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
keymap.set("n", "<leader>tf", function()
  -- `tabnew %` fails with E499 on an unnamed buffer (% expands to nothing), so
  -- fall back to splitting the current window and promoting the split to a tab.
  if vim.api.nvim_buf_get_name(0) ~= "" then
    vim.cmd("tabnew %")
  else
    vim.cmd("split")
    vim.cmd("wincmd T")
  end
end, { desc = "Open current buffer in new tab" })

-- =============================================================================
-- Tab Management Keybindings (LazyVim <leader><Tab>)
-- =============================================================================
-- LazyVim's tab group, ported whole (lazyvim/config/keymaps.lua:205-212) with
-- its exact key letters and its exact descriptions.
--
-- This sits ALONGSIDE the older <leader>t keys above rather than replacing
-- them. Five of those (to/tx/tn/tp/tf) now have a LazyVim-spelled equivalent
-- here, but <leader>t also carries the floating terminal (tt), so the prefix
-- could not simply be retired even if the duplicates were dropped. Both sets
-- work; see KEYMAPS.md for the mapping between them.
--
-- Three of the seven have no <leader>t counterpart and are the real gain:
-- <leader><Tab>o closes every OTHER tab, and f/l jump to the first/last.
--
-- Note <leader><Tab>f is First Tab, which is NOT what <leader>tf does (that
-- opens the current buffer in a new tab). Same letter, different verb.
--
-- `silent` is deliberately omitted even though LazyVim's map helper forces it
-- on (LazyVim.safe_keymap_set, util/init.lua:206-226). A <cmd> mapping never
-- echoes to the command line and none of these seven commands prints anything
-- on success, so silent is a no-op here -- and the one message you can provoke
-- (E784 "Cannot close last tab page") is an error, which 'silent' would not
-- suppress in any case. Omitting it matches every other keymap in this file.
keymap.set("n", "<leader><Tab>l", "<cmd>tablast<CR>", { desc = "Last Tab" })
keymap.set("n", "<leader><Tab>o", "<cmd>tabonly<CR>", { desc = "Close Other Tabs" })
keymap.set("n", "<leader><Tab>f", "<cmd>tabfirst<CR>", { desc = "First Tab" })
keymap.set("n", "<leader><Tab><Tab>", "<cmd>tabnew<CR>", { desc = "New Tab" })
keymap.set("n", "<leader><Tab>]", "<cmd>tabnext<CR>", { desc = "Next Tab" })
keymap.set("n", "<leader><Tab>d", "<cmd>tabclose<CR>", { desc = "Close Tab" })
keymap.set("n", "<leader><Tab>[", "<cmd>tabprevious<CR>", { desc = "Previous Tab" })

-- =============================================================================
-- Quit / Session Keybindings
-- =============================================================================
-- The <leader>q group mirrors LazyVim. The other four keys (<leader>qs/qS/ql/qd)
-- are session restores and live with the plugin that provides them, in
-- plugins/persistence.lua -- LazyVim splits them the same way, keeping only
-- Quit All in its core keymaps (lazyvim/config/keymaps.lua:183).
--
-- Do not confuse this with <leader>wq above, which quits a single WINDOW.
keymap.set("n", "<leader>qq", "<cmd>qa<CR>", { desc = "Quit All" })

-- =============================================================================
-- Quick Access Keybindings
-- =============================================================================
-- Top-level leader shortcuts for the most common actions, modeled on the
-- adibhanna/nvim layout but wired to this config's stack: fzf-lua (pickers),
-- snacks (scratch), which-key (keymap help). The terminal toggle (<C-/>) lives
-- in custom/plugins/terminal.lua where the module is in scope. See <leader>tt
-- for the same terminal toggle.

-- Find files (fuzzy file picker) — mirrors <leader>ff
-- Inside an Obsidian vault these two also drop .obsidian/ and the templates
-- folder (andrew.utils.obsidian); outside one the helper returns {} and they
-- behave exactly as before.
keymap.set("n", "<leader><space>", function()
  require("fzf-lua").files(require("andrew.utils.obsidian").picker_opts())
end, { desc = "Find files" })

-- Grep across the project root (live grep). Unlike <leader>fs, which greps the
-- current working directory, this anchors to the detected project root:
-- LSP workspace -> nearest .git/lua ancestor -> cwd. See utils/root.lua.
keymap.set("n", "<leader>/", function()
  require("fzf-lua").live_grep(require("andrew.utils.obsidian").with_picker_opts({
    cwd = require("andrew.utils.root").get(),
  }))
end, { desc = "Grep (root dir)" })

-- Switch buffer (buffer picker)
keymap.set("n", "<leader>,", function()
  require("fzf-lua").buffers()
end, { desc = "Switch buffer" })

-- Command history: fuzzy-pick a previously typed : command and re-run it
keymap.set("n", "<leader>:", function()
  require("fzf-lua").command_history()
end, { desc = "Command history" })

-- Scratch buffer (snacks)
keymap.set("n", "<leader>.", function()
  Snacks.scratch()
end, { desc = "Scratch buffer" })

-- Keymap help: buffer-local vs. all (which-key popups)
keymap.set("n", "<leader>?", function()
  require("which-key").show({ global = false })
end, { desc = "Buffer keymaps" })
keymap.set("n", "<leader>K", function()
  require("which-key").show({ global = true })
end, { desc = "All keymaps" })

-- =============================================================================
-- Window Autocommands
-- =============================================================================

-- Re-equalize splits when the terminal itself is resized, so a layout that was
-- balanced before the resize stays balanced after it. Windows carrying
-- winfixwidth (the vault readable-width pads) keep their width either way.
vim.api.nvim_create_autocmd("VimResized", {
  desc = "Equalize split sizes after the editor is resized",
  group = vim.api.nvim_create_augroup("resize-splits", { clear = true }),
  callback = function()
    local current_tab = vim.fn.tabpagenr()
    vim.cmd("tabdo wincmd =")
    vim.cmd("tabnext " .. current_tab)
  end,
})

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
    vim.hl.on_yank({ higroup = "IncSearch", timeout = 300 })
  end,
})
