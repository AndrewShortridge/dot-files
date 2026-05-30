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
        local ls = require("luasnip")
        ls.config.set_config({ enable_autosnippets = true })

        -- Load VSCode-style snippets from friendly-snippets
        require("luasnip.loaders.from_vscode").lazy_load()
        -- Load custom snippets (Modern Fortran style with full keywords)
        require("luasnip.loaders.from_vscode").lazy_load({
          paths = { vim.fn.stdpath("config") .. "/snippets" },
        })
        -- Load Lua snippets (math autosnippets for tex/markdown)
        require("luasnip.loaders.from_lua").lazy_load({
          paths = { vim.fn.stdpath("config") .. "/luasnippets" },
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
      ["<C-p>"] = { "select_prev", "fallback" },
      ["<C-n>"] = { "select_next", "fallback" },
      ["<C-k>"] = { "scroll_documentation_up", "fallback" },
      ["<C-j>"] = { "scroll_documentation_down", "fallback" },
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

      -- Filetype-specific source lists
      per_filetype = {
        fortran = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
        ["fortran.fixed"] = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
        ["fortran.free"] = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
        f90 = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
        f95 = { "fortran_docs", "lsp", "snippets", "path", "buffer" },
        markdown = { "wikilinks", "vault_tags", "vault_frontmatter", "vault_inline_fields", "lsp", "snippets", "path", "buffer", "spell" },
      },

      providers = {
        fortran_docs = {
          name = "FortranDocs",
          module = "andrew.fortran.blink-source",
          min_keyword_length = 2,
          score_offset = 10,
        },
        wikilinks = {
          name = "Wikilinks",
          module = "andrew.vault.completion",
          min_keyword_length = 0,
          score_offset = 15,
          fallbacks = {},
          async = true,
          timeout_ms = 3000,
          transform_items = function(_, items)
            for _, item in ipairs(items) do
              if item.data and item.data.completion_kind == "heading" then
                item.source_name = "Heading"
              elseif item.data and item.data.completion_kind == "block" then
                item.source_name = "Block"
              end
            end
            return items
          end,
        },
        vault_tags = {
          name = "VaultTags",
          module = "andrew.vault.completion_tags",
          min_keyword_length = 0,
          score_offset = 12,
          fallbacks = {},
        },
        vault_frontmatter = {
          name = "Frontmatter",
          module = "andrew.vault.completion_frontmatter",
          min_keyword_length = 0,
          score_offset = 14,
          fallbacks = {},
        },
        vault_inline_fields = {
          name = "Fields",
          module = "andrew.vault.completion_inline_fields",
          min_keyword_length = 0,
          score_offset = 11,
          fallbacks = {},
        },
        spell = {
          name = "Spell",
          module = "andrew.vault.completion_spell",
          min_keyword_length = 3,
          score_offset = -5,
          fallbacks = {},
        },
      },
    },

    -- Completion settings
    completion = {
      documentation = {
        auto_show = true,
        auto_show_delay_ms = 150,
        treesitter_highlighting = true,
        window = {
          border = "rounded",
          max_width = 100,
          max_height = 40,
          winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:Visual,Search:None",
        },
      },
      ghost_text = {
        enabled = true,
      },
      -- Show source labels in menu for clarity
      menu = {
        border = "rounded",
        winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel,Search:None",
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

  -- Custom config to monkey-patch keyword module before setup
  config = function(_, opts)
    -- Include ';' in keyword characters so ;-prefixed snippet triggers
    -- are properly matched and replaced during completion
    local ok, keyword = pcall(require, 'blink.cmp.fuzzy.lua.keyword')
    if ok and keyword.with_constant_is_keyword then
      function keyword.with_constant_is_keyword(cb)
        local existing = vim.bo.iskeyword
        local desired = '@,48-57,_,-,;,/,192-255'
        if existing == desired then return cb() end
        vim.bo.iskeyword = desired
        local success, a, b = pcall(cb)
        vim.bo.iskeyword = existing
        if success then return a, b end
        error(a)
      end
    end

    -- Normal blink.cmp setup
    require('blink.cmp').setup(opts)
  end,

  -- Extend sources from other plugins
  opts_extend = { "sources.default" },
}
