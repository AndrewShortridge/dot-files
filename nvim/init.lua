-- Force conda's bin first in PATH inside Neovim
vim.env.PATH = vim.fn.expand("$HOME/miniconda3/bin") .. ":" .. vim.env.PATH

require("andrew.core")
require("andrew.lazy")
require("andrew.custom.plugins.terminal")

vim.opt.termguicolors = true


