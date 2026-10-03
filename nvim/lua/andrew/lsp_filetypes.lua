-- =============================================================================
-- LSP Server Filetypes
-- =============================================================================
-- Filetypes that actually have a configured LSP server or a mason-managed tool.
-- Mason is only an *installer* (servers are attached natively in lspconfig.lua),
-- so both mason and lspconfig only need to load for these. Server-less filetypes
-- — markdown, text, help, etc. — never drag the LSP tree in, keeping their open
-- path fast.
--
-- This lives outside the lazy plugin-import path (NOT under andrew.plugins) so
-- lazy.nvim does not mistake the returned array for a plugin spec.

return {
  "lua",
  "python",
  "fortran", "fortran_free", "fortran_fixed", "f90", "f95",
  "c", "cpp",
  "rust",
  "html", "css", "scss",
  "javascript", "javascriptreact",
  "typescript", "typescriptreact",
  "prisma",
  "json", "jsonc", "yaml",
}
