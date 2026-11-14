-- =============================================================================
-- Color Highlighter (nvim-colorizer.lua)
-- =============================================================================
-- Highlights color codes (hex, rgb, hsl, etc.) with their actual color.
-- Shows inline color preview for CSS, HTML, and other color-related code.

return {
  -- Plugin: nvim-colorizer.lua - Color highlighter for Neovim
  -- Repository: https://github.com/catgoose/nvim-colorizer.lua
  -- (maintained fork of norcalli/nvim-colorizer.lua; the original is unmaintained
  --  and calls the deprecated vim.tbl_flatten, removed in nvim 0.13)
  "catgoose/nvim-colorizer.lua",

  -- Defer off startup: only load on the first color-relevant filetype (mirrors
  -- the `filetypes` table below), so the ~15 css color-parser submodules are not
  -- pulled in during startup OR on markdown/text opens (markdown is absent here,
  -- so an event gate force-loaded ~15ms of parsers then attached to nothing).
  -- lazy.nvim re-fires FileType on load so colorizer's own FileType autocmd
  -- attaches. (ft implies lazy; do NOT add lazy=false or it re-breaks deferral.)
  ft = { "css", "scss", "sass", "less", "html", "lua", "javascript", "javascriptreact", "typescript", "typescriptreact" },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Restrict colorizing to filetypes where inline color preview matters, so
    -- markdown/text/etc. never get a colorizer attach.
    --
    -- NOTE (catgoose fork): only the NAMED `filetypes` key is honored. A
    -- positional list (e.g. setup({ "css", "lua" })) is silently ignored and
    -- falls back to the default { "*" } — do not regress to that form.
    require("colorizer").setup({
      filetypes = {
        "css",
        "scss",
        "sass",
        "less",
        "html",
        "lua",
        "javascript",
        "javascriptreact",
        "typescript",
        "typescriptreact",
      },
    })
  end,
}
