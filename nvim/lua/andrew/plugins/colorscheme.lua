-- =============================================================================
-- Color Scheme Plugin
-- =============================================================================
-- Configures the OneDarkPro color scheme with custom highlights.
-- This plugin is loaded with high priority (1000) to ensure colors load early.

return {
  -- Plugin: OneDarkPro - A dark color scheme for Neovim
  -- Repository: https://github.com/olimorris/onedarkpro.nvim
  "olimorris/onedarkpro.nvim",

  -- Priority: Load this plugin first among those with priority
  -- This ensures the color scheme is applied before other plugins that might override it
  priority = 1000,

  -- Configuration function called when plugin loads
  config = function()
    -- Setup OneDarkPro with custom options
    require("onedarkpro").setup({
      -- =============================================================================
      -- Plugin Options
      -- =============================================================================
      options = {
        transparency = false,           -- Use opaque background (not transparent)
        terminal_colors = true,         -- Apply theme colors to terminal buffers
        cursorline = true,              -- Highlight the cursor line
        highlight_inactive_windows = false,  -- Don't highlight inactive windows
      },

      -- =============================================================================
      -- Custom Highlight Groups
      -- =============================================================================
      -- Override specific highlight groups to match our preferences

      highlights = {
        -- Normal buffer background: dark gray-blue.
        -- `extend = true` is required: without it onedarkpro REPLACES the group
        -- (lib/compile.lua:80 only merges into the existing highlight when
        -- `extend` is set), so Normal would lose its foreground colour entirely.
        Normal = { bg = "#1E222A", extend = true },

        -- Floating window background: slightly darker (see the note above about
        -- `extend` -- without it NormalFloat loses its foreground too).
        NormalFloat = { bg = "#17191d", extend = true },

        -- Floating window border: gray foreground with dark background
        FloatBorder = { fg = "#E06C75", bg = "#1E222A" },

        -- Spell checking: subtle undercurl using OneDarkPro palette colors
        SpellBad = { sp = "#e06c75", undercurl = true },
        SpellCap = { sp = "#e5c07b", undercurl = true },
        SpellLocal = { sp = "#56b6c2", undercurl = true },
        SpellRare = { sp = "#c678dd", undercurl = true },

        -- Word operators (`and`, `or`, `not`, `in`) look like every other
        -- keyword. onedarkpro styles them as operators, and for Lua paints
        -- them in the plain text colour, so they were the only keywords that
        -- did not take `styles.keywords`.
        ["@keyword.operator"] = { link = "@keyword" },
        ["@keyword.operator.lua"] = { link = "@keyword.lua" },

        -- Fortran, so that it reads like Lua does: every keyword italic,
        -- every procedure name bold. onedarkpro has no Fortran file of its
        -- own. The last two captures come from queries/fortran/highlights.scm,
        -- which explains them; the colours are the ones each had.
        ["@keyword.function.fortran"] = { link = "@keyword" }, -- `subroutine`, `call`, `program`
        ["@attribute.fortran"] = { fg = "${purple}", italic = true }, -- `implicit none`, `intent`
        ["@function.builtin.statement"] = { fg = "${yellow}", italic = true }, -- `write`, `allocate`
        ["@function.builtin.intrinsic"] = { fg = "${yellow}", bold = true }, -- `sin`, `size`
      },

      -- =============================================================================
      -- Style Options
      -- =============================================================================
      -- Apply text styles to specific syntax elements

      -- The italic and bold sets of olimorris' own config (the author of
      -- onedarkpro), all of his `styles` block:
      -- https://github.com/olimorris/dotfiles/blob/main/.config/nvim/plugin/colorscheme.lua
      -- `themes/soft-paper.lua` states the same rules by hand; change both.
      styles = {
        comments = "italic",      -- Comment
        keywords = "italic",      -- Keyword / @keyword (`local`, `return`, `end`); was "bold"
        conditionals = "italic",  -- Conditional / @keyword.conditional (`if`, `else`)
        parameters = "italic",    -- @variable.parameter
        tags = "italic",          -- @tag.attribute (html)
        virtual_text = "italic",  -- DiagnosticVirtualText*, completion ghost text
        -- Function / @function and its calls. Also @keyword.function
        -- (`subroutine`, `def`), except in Lua where that one is a keyword.
        functions = "bold",
        methods = "bold",         -- @function.method and its calls
      },
    })

    -- Apply the onedark color scheme
    vim.cmd("colorscheme onedark")
  end,
}
