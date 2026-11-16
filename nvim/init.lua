-- PATH inside Neovim, highest priority first: mason's bin dir, then conda's.
--
-- Mason's entry is added HERE, not by mason.nvim (whose own PATH handling is
-- switched off in plugins/lsp/mason.lua). mason.nvim only loads on :Mason, but
-- pylsp, prettier, ruff and eslint_d are resolved from $PATH the moment a
-- buffer opens.
vim.env.PATH = table.concat({
  vim.fn.stdpath("data") .. "/mason/bin",
  vim.fn.expand("$HOME/miniconda3/bin"),
  vim.env.PATH,
}, ":")

require("andrew.core")
require("andrew.lazy")
require("andrew.custom.plugins.terminal")
require("andrew.vault")
require("andrew.themes.toggle").setup()
require("andrew.utils.tabline").setup()
require("andrew.utils.markdown_renderer").setup()

vim.opt.termguicolors = true


