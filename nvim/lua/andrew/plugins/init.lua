-- =============================================================================
-- Plugin Specifications
-- =============================================================================
-- This module defines all plugins used in the Neovim configuration.
-- Each plugin is specified as a table with lazy.nvim configuration options.
--
-- Plugin Organization:
-- - Core utilities and dependencies
-- - User interface components (statusline, tabs, icons)
-- - Editing enhancements (autopairs, comments, surround)
-- - Code navigation and search (fzf-lua, LSP)
-- - Language support (treesitter, LSP servers)
-- - Formatting and linting tools
--
-- Plugins are loaded by lazy.nvim based on their event/cmd/lazy specifications.

return {
  -- =============================================================================
  -- Core Dependencies
  -- =============================================================================

  -- Provides useful Lua functions used by many plugins
  -- Used by: fzf-lua, yazi, and various other plugins
  "nvim-lua/plenary.nvim",

  -- Seamless navigation between Neovim and tmux splits/windows
  -- Keybindings: Ctrl-h/j/k/l to move between panes
  "christoomey/vim-tmux-navigator",

  -- =============================================================================
  -- User Interface
  -- =============================================================================

  -- Color scheme: OneDarkPro theme with custom highlights
  -- Sets the editor color scheme on startup
  require("andrew.plugins.colorscheme"),

  -- File type icons for various UI components
  -- Used by: lualine, bufferline, fzf-lua, and other plugins
  require("andrew.plugins.ui.devicons"),

  -- Status line at the bottom of the editor
  -- Shows mode, git branch, diagnostics, file info, and more
  require("andrew.plugins.lualine"),

  -- =============================================================================
  -- Code Completion
  -- =============================================================================

  -- Modern completion plugin with LSP integration
  -- Provides: autocomplete menu, snippets, and LSP completion
  require("andrew.plugins.blink-cmp"),

  -- =============================================================================
  -- File Navigation and Search
  -- =============================================================================

  -- Fuzzy finder for files, grep, buffers, and more
  -- Keybindings: <leader>ff, <leader>fr, <leader>fs, etc.
  require("andrew.plugins.fzf-lua"),

  -- =============================================================================
  -- Syntax and Parsing
  -- =============================================================================

  -- Syntax highlighting and text objects via tree-sitter
  -- Provides: improved syntax, text objects, and indentation
  require("andrew.plugins.treesitter"),

  -- =============================================================================
  -- Editing Enhancements
  -- =============================================================================

  -- Auto-close brackets, quotes, and other pairs
  -- Integrates with blink.cmp for completion-based closing
  require("andrew.plugins.autopairs"),

  -- Easy commenting for all supported file types
  -- Keybindings: gc (motion), gcc (line), gb (block)
  require("andrew.plugins.comment"),

  -- Visual indentation guides
  -- Shows indentation levels with vertical lines
  require("andrew.plugins.indent-blankline"),

  -- Tab/buffer line for managing multiple tabs
  -- Shows open tabs with close buttons and status indicators
  require("andrew.plugins.bufferline"),

  -- Highlight and search for TODO, FIXME, HACK, etc. comments
  -- Keybindings: ]t (next), [t (previous), <leader>ft (fuzzy search)
  require("andrew.plugins.todo-comments"),

  -- Diagnostic and quickfix list viewer
  -- Shows LSP diagnostics, todo comments, and quickfix items
  require("andrew.plugins.trouble"),

  -- Maximize/restore the current split window
  -- Keybinding: <leader>sm (toggle maximization)
  require("andrew.plugins.vim-maximizer"),

  -- Improved UI for vim.ui.input and vim.ui.select
  -- Provides: better looking prompts and file pickers
  require("andrew.plugins.dressing"),

  -- Substitute motion: replace text with ease
  -- Keybindings: s (motion), ss (line), S (to EOL), x (visual)
  require("andrew.plugins.substitute"),

  -- Add/change/delete surrounding pairs
  -- Keybindings: ys (add), cs (change), ds (delete), ysiw (around word)
  require("andrew.plugins.surround"),

  -- Keybinding hints popup
  -- Shows available keybindings when you press leader
  require("andrew.plugins.which-key"),

  -- =============================================================================
  -- Language Server Protocol
  -- =============================================================================

  -- LSP server installer (mason) and configuration helper
  -- Installs: lua_ls, pylsp, rust_analyzer, fortls, and more
  require("andrew.plugins.lsp.mason"),

  -- LSP configuration and keybindings
  -- Configures: language servers, diagnostics, and LSP keymaps
  -- Includes custom Fortran hover handler for snippet documentation
  require("andrew.plugins.lsp.lspconfig"),

  -- =============================================================================
  -- Code Formatting
  -- =============================================================================

  -- Formatter configuration with conform.nvim
  -- Formatters: stylua (Lua), ruff format (Python), rustfmt (Rust), prettier (JS/TS)
  require("andrew.plugins.formatting.conform"),

  -- =============================================================================
  -- Markdown
  -- =============================================================================

  -- Render markdown in-buffer: styled headings, box-drawing tables,
  -- checkboxes, code blocks, callouts, and wiki-link icons
  require("andrew.plugins.render-markdown"),

  -- Auto-format markdown tables as you type with column alignment
  -- Toggle: <leader>Tm, Tab to move between cells
  require("andrew.plugins.vim-table-mode"),

  -- =============================================================================
  -- Language-specific Plugins
  -- =============================================================================

  -- Rust development with enhanced LSP, debugging, and commands
  -- Provides: rust-analyzer integration, DAP debugging, runnables, testables
  require("andrew.plugins.rustaceanvim"),

  -- =============================================================================
  -- Debugging
  -- =============================================================================

  -- Debug Adapter Protocol client
  -- Provides: breakpoints, stepping, variable inspection
  require("andrew.plugins.dap.dap"),

  -- Debug UI for nvim-dap
  -- Provides: visual debugging interface with scopes, watches, call stack
  require("andrew.plugins.dap.dap-ui"),
}
