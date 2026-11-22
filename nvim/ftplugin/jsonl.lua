-- JSONL: one JSON value per line. Highlighting comes from the `json` parser,
-- registered for this filetype in lua/andrew/plugins/treesitter.lua.

-- One record per screen row; `zl` / `zh` scroll sideways. `vim.wo[0][0]` is
-- `:setlocal` (see ftplugin/tex.lua).
vim.wo[0][0].wrap = false

vim.keymap.set("n", "<leader>cp", function()
  require("andrew.utils.jsonl_preview").toggle()
end, { buffer = true, silent = true, desc = "JSONL: toggle the pretty-printed preview of the record under the cursor" })
