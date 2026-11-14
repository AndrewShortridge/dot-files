-- =============================================================================
-- Snippet Engine (LuaSnip)
-- =============================================================================
-- Expands snippets for blink.cmp (`snippets.preset = "luasnip"` in
-- blink-cmp.lua) and runs the math autosnippets for markdown/tex.

return {
  -- Plugin: LuaSnip - snippet engine
  -- Repository: https://github.com/L3MON4D3/LuaSnip
  "L3MON4D3/LuaSnip",
  version = "v2.*",
  build = "make install_jsregexp",

  -- Snippets only matter while typing. This used to be a dependency of
  -- blink.cmp, which nvim-lspconfig in turn depended on, so the three snippet
  -- loaders below ran while every code file was opening.
  event = "InsertEnter",

  -- friendly-snippets MUST be a dependency of LuaSnip, not a separate spec.
  -- lazy.nvim puts a dependency on the runtimepath before running this
  -- `config`; without that the pathless lazy_load() below finds ZERO snippet
  -- directories and every language comes up empty.
  dependencies = { "rafamadriz/friendly-snippets" },

  config = function()
    local luasnip = require("luasnip")
    luasnip.config.set_config({ enable_autosnippets = true })

    -- Load VSCode-style snippets from friendly-snippets.
    -- Fortran is excluded: friendly-snippets ships 84 generic Fortran
    -- snippets that collide with the custom ones loaded from ./snippets
    -- below (8 prefixes overlap outright).
    require("luasnip.loaders.from_vscode").lazy_load({ exclude = { "fortran" } })
    -- Load custom snippets (Modern Fortran style with full keywords)
    require("luasnip.loaders.from_vscode").lazy_load({
      paths = { vim.fn.stdpath("config") .. "/snippets" },
    })
    -- Load Lua snippets (math autosnippets for tex/markdown)
    require("luasnip.loaders.from_lua").lazy_load({
      paths = { vim.fn.stdpath("config") .. "/luasnippets" },
    })
  end,
}
