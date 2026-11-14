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
opt_local.foldnestmax = 6  -- cap fold depth to reduce fold work

-- Use j/k on visual lines when wrapping
local map = function(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = true, desc = desc })
end

-- Move by SCREEN line under soft wrap, count-guarded exactly like
-- ftplugin/markdown.lua: `gj`/`gk` are exclusive and NOT linewise (:h gj), so an
-- unconditional map turns `5j` into `5gj` (5 screen rows, not 5 buffer lines)
-- and breaks relative-number jumps. Normal + visual; operator-pending is left
-- alone deliberately.
for _, key in ipairs({ "j", "k" }) do
  vim.keymap.set({ "n", "x" }, key, function()
    return vim.v.count == 0 and ("g" .. key) or key
  end, { buffer = true, expr = true, desc = "Down/up (screen line when countless)" })
end

map("n", "<Tab>", "za", "Toggle fold")
map("n", "<leader>mf", "zM", "Fold all")
map("n", "<leader>mu", "zR", "Unfold all")
map("n", "zd", "<Nop>", "Fold delete disabled (expr foldmethod)")
map("n", "zD", "<Nop>", "Fold delete disabled (expr foldmethod)")
map("n", "zE", "<Nop>", "Fold eliminate disabled (expr foldmethod)")
map("n", "zf", "<Nop>", "Fold create disabled (expr foldmethod)")
map("n", "zF", "<Nop>", "Fold create disabled (expr foldmethod)")

-- LaTeX motions (]]|[[ sections, ]e|[e environments, ]m|[m math)
-- LaTeX text objects (ae|ie environment, am|im math, ac|ic command)
require("andrew.utils.tex-motions").setup()
