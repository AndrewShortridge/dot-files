local opt_local = vim.opt_local

-- Writing settings
opt_local.spell = true
opt_local.spelllang = "en_us"
opt_local.wrap = true
opt_local.linebreak = true
opt_local.breakindent = true
opt_local.textwidth = 0

-- Conceal: render \alpha as α, etc. (level 2 hides completely)
opt_local.conceallevel = 2
opt_local.concealcursor = ""

-- Folding via treesitter
opt_local.foldmethod = "expr"
opt_local.foldexpr = "v:lua.vim.treesitter.foldexpr()"
opt_local.foldlevel = 99
opt_local.foldenable = true

-- Use j/k on visual lines when wrapping
local map = function(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = true, desc = desc })
end

map("n", "j", "gj", "Down (visual line)")
map("n", "k", "gk", "Up (visual line)")

map("n", "<Tab>", "za", "Toggle fold")
map("n", "<leader>mf", "zM", "Fold all")
map("n", "<leader>mu", "zR", "Unfold all")

-- LaTeX motions (]]|[[ sections, ]e|[e environments, ]m|[m math)
-- LaTeX text objects (ae|ie environment, am|im math, ac|ic command)
require("andrew.utils.tex-motions").setup()
