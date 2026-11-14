-- =============================================================================
-- Auto-close HTML/XML Tags (nvim-ts-autotag)
-- =============================================================================

return {
  -- Plugin: nvim-ts-autotag - auto-close and auto-rename markup tags
  -- Repository: https://github.com/windwp/nvim-ts-autotag
  "windwp/nvim-ts-autotag",

  -- Markup filetypes only. As a dependency of nvim-treesitter it loaded on
  -- every BufReadPre (2.5-6 ms), Lua and Fortran buffers included.
  --
  -- NOTE: nothing calls require("nvim-ts-autotag").setup(), here or before the
  -- move, and without it the plugin attaches to no buffer -- tags are NOT
  -- auto-closed today. Adding `opts = {}` to this spec turns it on.
  ft = { "html", "vue", "javascriptreact", "typescriptreact" },
}
