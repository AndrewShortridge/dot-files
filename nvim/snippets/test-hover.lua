-- Test hover via keymap override - source with :luafile %
local fortran_docs = require("andrew.fortran.docs")

-- Override K keymap for Fortran files
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "fortran", "fortran_fixed", "fortran_free", "f90", "f95" },
  callback = function(ev)
    vim.keymap.set("n", "K", function()
      local word = vim.fn.expand("<cword>")
      local custom_doc = fortran_docs.get(word)

      if custom_doc then
        -- Show custom docs
        vim.lsp.util.open_floating_preview(
          vim.split(custom_doc, "\n"),
          "markdown",
          { border = "rounded", focus = false }
        )
      else
        -- Fall back to LSP hover
        vim.lsp.buf.hover()
      end
    end, { buffer = ev.buf, desc = "Fortran hover with custom docs" })
  end,
})

-- Also set it for the current buffer if it's already a Fortran file
local ft = vim.bo.filetype
if ft == "fortran" or ft:match("^fortran") or ft == "f90" or ft == "f95" then
  vim.keymap.set("n", "K", function()
    local word = vim.fn.expand("<cword>")
    local custom_doc = fortran_docs.get(word)

    if custom_doc then
      vim.lsp.util.open_floating_preview(
        vim.split(custom_doc, "\n"),
        "markdown",
        { border = "rounded", focus = false }
      )
    else
      vim.lsp.buf.hover()
    end
  end, { buffer = 0, desc = "Fortran hover with custom docs" })
end

print("Fortran K hover installed!")
