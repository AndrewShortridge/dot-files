-- =============================================================================
-- Code Completion Plugin (blink.cmp)
-- =============================================================================
-- Modern completion plugin that provides LSP-based autocomplete with snippets.
-- Documentation: https://cmp.saghen.dev/

return {
  -- Plugin: blink.cmp - A modern completion plugin for Neovim
  -- Repository: https://github.com/saghen/blink.cmp
  "saghen/blink.cmp",

  -- Events: Load on insert mode OR on ':' / '/' / '?'.
  -- CmdlineEnter is required for the `cmdline` block below: blink registers its
  -- cmdline mappings as global 'c'-mode maps at setup() time, so without this
  -- trigger nothing completes on ':' until some earlier InsertEnter happened to
  -- load the plugin.
  event = { "InsertEnter", "CmdlineEnter" },

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

      -- friendly-snippets MUST be a dependency of LuaSnip, not merely a sibling
      -- in the list below. lazy.nvim loads dependencies in order and runs each
      -- one's `config` before adding the next to the runtimepath, so the
      -- pathless lazy_load() in this config ran while friendly-snippets was
      -- still off the rtp -- it found ZERO snippet directories and every
      -- language came up empty.
      dependencies = { "rafamadriz/friendly-snippets" },

      config = function()
        local ls = require("luasnip")
        ls.config.set_config({ enable_autosnippets = true })

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
    },

    -- Pre-built snippet collections for various languages. Also declared as a
    -- dependency of LuaSnip above, which is what guarantees the load ORDER;
    -- this entry just keeps it visible in blink.cmp's dependency list.
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
      -- <C-k> is RESERVED for insert-mode signature help (lsp/lspconfig.lua
      -- binds it on LspAttach, including the Python/ty branch). Both maps are
      -- buffer-local and blink applies its own on InsertEnter -- i.e. AFTER
      -- LspAttach -- so any blink binding here wins and lspconfig's is dead.
      -- blink's `fallback` cannot rescue it either: fallback.wrap() snapshots
      -- the buffer-local map at apply time (before LspAttach on a fresh buffer)
      -- and afterwards only searches GLOBAL maps, so a buffer-local LSP map is
      -- never found. `false` stops blink from mapping the key at all.
      --
      -- The default preset binds <C-k> to show_signature/hide_signature, so
      -- disabling it is required even without the two lines this replaced
      -- (which were scroll_documentation_up/down on <C-k>/<C-j>).
      --
      -- Documentation scrolling therefore lives on the default preset's
      -- <C-b> / <C-f>, plus <C-j> below for symmetry with <C-b>'s partner.
      ["<C-k>"] = false,
      ["<C-b>"] = { "scroll_documentation_up", "fallback" },
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
        -- NOTE the spellings. blink splits `vim.bo.filetype` on "." and looks
        -- each SEGMENT up in this table (sources/lib/init.lua:77), so a dotted
        -- key such as "fortran.fixed" can never match anything -- it was dead
        -- config. The rest of this repo (andrew.lsp_filetypes,
        -- andrew.fortran.lsp.FILETYPES, fortran/scan.lua) uses the underscore
        -- spellings, which is what a fortran ftplugin/ftdetect would actually
        -- set, so those are used here too.
        --
        -- There is no `fortran_docs` entry any more. That source handed the
        -- same 388 documentation keys to every round in every context, with no
        -- textEdit, so accepting one inserted the KEY (`!$OMP PARALLEL DO
        -- omp_private`). The fortran-extras LSP server answers Fortran
        -- completion now (andrew.fortran.lsp_completion): same registry as
        -- hover, context-aware, lazy documentation through
        -- completionItem/resolve, and `labelDetails.description` lighting the
        -- label_description column below. So `lsp` covers it, and it must stay
        -- first in each of these lists.
        fortran = { "lsp", "snippets", "path", "buffer" },
        fortran_fixed = { "lsp", "snippets", "path", "buffer" },
        fortran_free = { "lsp", "snippets", "path", "buffer" },
        f90 = { "lsp", "snippets", "path", "buffer" },
        f95 = { "lsp", "snippets", "path", "buffer" },
        markdown = { "latex_math", "wikilinks", "vault_tags", "vault_frontmatter", "vault_inline_fields", "lsp", "snippets", "path", "buffer", "spell" },
        -- .tex had no entry and fell through to `default`; listed so the LaTeX
        -- command source is offered there too (its enabled() is unconditional
        -- for tex, math-zone-gated for markdown).
        tex = { "latex_math", "lsp", "snippets", "path", "buffer" },
      },

      providers = {
        -- In prose filetypes (markdown/tex), only surface snippet completions
        -- when the current word the cursor sits on begins with ";".
        --
        -- NOTE: we deliberately do NOT use ctx.get_keyword() here. blink's Rust
        -- fuzzy implementation (fuzzy.implementation = "prefer_rust_with_warning")
        -- hard-codes the keyword charset to [\w-] and ignores 'iskeyword', so for
        -- ";meeting" it returns "meeting" with the ';' stripped. Inspecting the raw
        -- line token before the cursor is implementation-independent and works
        -- under both the Rust and Lua fuzzy backends.
        -- Other filetypes (e.g. Fortran constructs do/program) are unaffected.
        snippets = {
          should_show_items = function(ctx)
            local ft = vim.bo.filetype
            if ft ~= "markdown" and ft ~= "tex" then
              return true
            end
            local before = ctx.line:sub(1, ctx.cursor[2])
            local token = before:match("[^%s]*$") or ""
            -- A ';' anywhere in the current (whitespace-delimited) token means a
            -- ';'-trigger is being typed. Using find rather than a prefix check
            -- handles math like "$;latex-alpha" where the ';' follows a '$'.
            return token:find(";", 1, true) ~= nil
          end,
        },
        -- LaTeX math commands after `\` inside $...$ (markdown) or in .tex.
        -- Data: andrew.latex.symbols. Gated on utils/tex.in_mathzone() for
        -- markdown, so it is silent in prose. min_keyword_length = 0 so a bare
        -- `\` (the trigger character) lists everything.
        latex_math = {
          name = "LaTeX",
          module = "andrew.latex.blink-source",
          min_keyword_length = 0,
          score_offset = 12,
          fallbacks = {},
        },
        wikilinks = {
          name = "Wikilinks",
          module = "andrew.vault.completion",
          min_keyword_length = 0,
          score_offset = 15,
          fallbacks = {},
          async = true,
          timeout_ms = 3000,
          -- source_name for heading/block items is tagged at build time in
          -- completion.lua's make_heading_item/make_block_item, so no
          -- per-keystroke transform_items scan is needed here.
        },
        vault_tags = {
          name = "VaultTags",
          module = "andrew.vault.completion_tags",
          -- min_keyword_length 2: the '#'/'/' trigger chars still force a show,
          -- so the tag menu appears on a bare '#'; this only suppresses the
          -- 1-char-prefix prose case where no trigger fired.
          min_keyword_length = 2,
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
          -- min_keyword_length 2: the ':' trigger char still forces a show, so
          -- the field menu appears on a bare ':' even with this set.
          min_keyword_length = 2,
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

    -- =============================================================================
    -- Command-line completion (':' / '/' / '?')
    -- =============================================================================
    -- Cmdline is a separate blink "mode": it ignores sources.default and
    -- sources.per_filetype entirely and uses cmdline.sources instead, so none of
    -- the vault providers above can leak in here (they are markdown-gated anyway).
    --
    -- blink already ships `enabled = true`, `sources = { "buffer", "cmdline" }`
    -- and `keymap.preset = "cmdline"` by default, and the two default sources
    -- self-gate by cmdtype (cmdline source on ':'/'@', buffer source on '/'/'?'),
    -- so only the deltas below are spelled out.
    --
    -- Only seven config leaves are mode-dispatchable (see blink's
    -- config/init.lua apply_mode_specific); everything else -- the rounded
    -- border, documentation window, fuzzy backend -- is shared with insert mode.
    cmdline = {
      keymap = {
        preset = "cmdline",
        -- The preset binds these to select_prev/select_next. Reclaim them as
        -- plain cursor movement: moving the caret inside a half-typed command is
        -- far more common than walking the menu, and <C-n>/<C-p> already do that.
        ["<Right>"] = false,
        ["<Left>"] = false,
      },
      completion = {
        -- blink defaults this to true, which auto-inserts the first match into
        -- the cmdline as soon as the menu opens -- it rewrites what you typed
        -- before you have chosen anything. Require an explicit <Tab>/<C-n>.
        list = { selection = { preselect = false } },
        menu = {
          -- blink's default only auto-shows in the cmdline window (q:). Extend it
          -- to ':' so commands complete as you type, while leaving '/' and '?'
          -- quiet -- a menu popping open over every search keystroke is noise.
          -- Unlike LazyVim's version, the cmdwin arm is kept: LazyVim tests only
          -- getcmdtype(), which returns "" in q: and so silently drops it.
          auto_show = function(ctx)
            return vim.fn.getcmdtype() == ":" or ctx.mode == "cmdwin"
          end,
          draw = {
            -- Drop the kind_icon and source_name columns used in insert mode.
            -- In cmdline every row would read "Cmdline" or "Buffer", which is
            -- pure noise; the label is the whole signal here.
            columns = { { "label", "label_description", gap = 1 } },
          },
        },
        -- Inline preview of the top match. This only renders because noice owns
        -- the cmdline: blink's ghost text needs a real buffer to hang an extmark
        -- on, and noice.ui.cmdline.position.buf provides it. Without noice this
        -- is a silent no-op rather than an error.
        ghost_text = { enabled = true },
      },
    },

    -- Fuzzy matching
    fuzzy = {
      implementation = "prefer_rust_with_warning",
      -- Fortran only: the LSP group (fortls + fortran-extras) sits above the
      -- snippet group instead of interleaving with it by fuzzy score. The
      -- comparator returns nil for every other filetype and for pairs within
      -- one source, so "score", "sort_text" below is blink's default order
      -- everywhere else (see andrew.fortran.completion_sort).
      sorts = {
        function(a, b)
          return require("andrew.fortran.completion_sort").compare(a, b)
        end,
        "score",
        "sort_text",
      },
    },
  },
}
