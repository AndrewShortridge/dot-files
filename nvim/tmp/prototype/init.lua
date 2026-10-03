-- Standalone harness:  nvim -u tmp/prototype/init.lua <file.pdf>
-- Loads nothing from your real config except snacks.nvim (for image rendering),
-- so the prototype cannot disturb anything.

vim.g.mapleader = " "
vim.opt.termguicolors = true

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
package.path = here .. "/?.lua;" .. package.path

-- reuse the snacks.nvim already installed by lazy
local snacks = vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim")
if vim.fn.isdirectory(snacks) == 1 then
  vim.opt.runtimepath:prepend(snacks)
  if os.getenv("KITTY_WINDOW_ID") or os.getenv("KITTY_PID") then
    vim.env.SNACKS_KITTY = "1"
  end
  pcall(function()
    require("snacks").setup({ image = { enabled = true, force = true, doc = { inline = true } } })
  end)
end

local proto = require("pdfproto")
local view = require("pdfview")
proto.setup()
view.setup()

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local a = vim.fn.argv(0)
    local page = tonumber(vim.fn.argv(1)) or tonumber(vim.env.PDF_PAGE) or 1
    if type(a) == "string" and a ~= "" and a:lower():match("%.pdf$") then
      for i = 0, vim.fn.argc() - 1 do
        pcall(vim.cmd, "silent! bwipeout! " .. vim.fn.bufnr(vim.fn.argv(i)))
      end
      view.open(a, page) -- image view by default; <Tab> for the text view
    else
      vim.notify("ready -- :PdfProtoView <pdf> [page]   (image)   |   :PdfProtoOpen <pdf> [page]   (text)")
    end
  end,
})
