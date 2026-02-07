-- =============================================================================
-- Code Completion Plugin (blink.cmp)
-- =============================================================================
-- Modern completion plugin that provides LSP-based autocomplete with snippets.
-- Documentation: https://cmp.saghen.dev/

return {
  -- Plugin: blink.cmp - A modern completion plugin for Neovim
  -- Repository: https://github.com/saghen/blink.cmp
  "saghen/blink.cmp",

  -- Event: Load plugin when entering insert mode
  event = "InsertEnter",

  -- Version constraint: Use latest 1.x stable version
  version = "1.*",

  -- =============================================================================
  -- Plugin Dependencies
  -- =============================================================================
  dependencies = {
    -- Snippet engine for snippet expansion
    {
      "L3MON4D3/LuaSnip",
      version = "v2.*",
      build = "make install_jsregexp",
      config = function()
        -- Load VSCode-style snippets from friendly-snippets
        require("luasnip.loaders.from_vscode").lazy_load()
        -- Load custom snippets (Modern Fortran style with full keywords)
        require("luasnip.loaders.from_vscode").lazy_load({
          paths = { vim.fn.stdpath("config") .. "/snippets" },
        })
      end,
    },

    -- Pre-built snippet collections for various languages
    "rafamadriz/friendly-snippets",
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  opts = {
    -- Snippet engine
    snippets = {
      preset = "luasnip",
    },

    -- Keymap configuration
    keymap = {
      preset = "default",
      ["<C-k>"] = { "select_prev", "fallback" },
      ["<C-j>"] = { "select_next", "fallback" },
      ["<C-b>"] = { "scroll_documentation_up", "fallback" },
      ["<C-f>"] = { "scroll_documentation_down", "fallback" },
      ["<C-Space>"] = { "show", "fallback" },
      ["<C-e>"] = { "hide", "fallback" },
      ["<CR>"] = { "accept", "fallback" },
    },

    -- Appearance
    appearance = {
      nerd_font_variant = "mono",
    },

    -- Completion sources
    -- Note: C header completions for Fortran come via ctags_lsp (configured in lspconfig.lua)
    sources = {
      default = { "lsp", "path", "snippets", "buffer" },

      -- Filetype-specific: prioritize fortran_docs for Fortran files
      per_filetype = {
        fortran = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
        ["fortran.fixed"] = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
        ["fortran.free"] = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
        f90 = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
        f95 = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
      },

      providers = {
        fortran_docs = {
          name = "FortranDocs",
          module = "andrew.fortran.blink-source",
          min_keyword_length = 2,
          score_offset = 10,
        },
      },
    },

    -- Completion settings
    completion = {
      documentation = {
        auto_show = true,
        auto_show_delay_ms = 200,
        treesitter_highlighting = true,
        window = {
          border = "rounded",
          max_width = 80,
          max_height = 20,
        },
      },
      ghost_text = {
        enabled = true,
      },
      -- Show source labels in menu for clarity
      menu = {
        draw = {
          columns = { { "kind_icon" }, { "label", "label_description", gap = 1 }, { "source_name" } },
        },
      },
    },

    -- Fuzzy matching
    fuzzy = {
      implementation = "prefer_rust_with_warning",
    },
  },

  -- Extend sources from other plugins
  opts_extend = { "sources.default" },
}
