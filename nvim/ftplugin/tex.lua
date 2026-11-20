-- `:setlocal` for this buffer and its window. `vim.wo[0][0]`, not `vim.wo`: the
-- latter writes the window's global value as well, which a split made from it
-- inherits. Not `vim.opt_local` either: from Neovim 0.13 its fields are typed
-- `vim.Option`, so lua_ls flags every plain value assigned through it.
local buffer_options = vim.bo
local window_options = vim.wo[0][0]

-- Writing settings
window_options.spell = true
buffer_options.spelllang = "en_us"
window_options.wrap = true
window_options.linebreak = true
window_options.breakindent = true
buffer_options.textwidth = 0

-- Conceal: render \alpha as α, etc. (level 2 hides completely)
window_options.conceallevel = 2
window_options.concealcursor = ""

-- Folding via treesitter
window_options.foldmethod = "expr"
window_options.foldexpr = "v:lua.vim.treesitter.foldexpr()"
window_options.foldlevel = 99
window_options.foldenable = true
window_options.foldnestmax = 6  -- cap fold depth to reduce fold work

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
