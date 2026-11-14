-- =============================================================================
-- Window Labels (incline.nvim)
-- =============================================================================
-- A small label floating at the top-right corner of every split: the file's
-- icon and name, with "[+]" in front while it has unsaved changes. With the
-- tabline showing tab pages rather than files (andrew/utils/tabline.lua), this
-- is what says which file each split holds.
--
-- Ported from craftzdog's dotfiles (lua/craftzdog/plugins/ui.lua). The icon
-- comes from nvim-web-devicons (he uses mini.icons).
--
-- Colours: his colourscheme fills the focused window's label with an accent
-- and gives the others text on a plain background. The same here:
--
--   focused split   dark bold text on the scheme's cyan (DiagnosticHint)
--   other splits    bold white text on the unfocused window's own
--                   background, so only the name shows, with no box
--
-- The colours are read from the active colourscheme and re-read on
-- ColorScheme, so the labels follow the light/dark toggle as the tabs do.
-- White is the one fixed colour, and only on a dark background: under the
-- light theme white text cannot be read, so the label uses the text colour.

local FOCUSED_LABEL_GROUP = "WindowLabelFocused"
local UNFOCUSED_LABEL_GROUP = "WindowLabelUnfocused"
local WHITE = 0xffffff

--- (Re)define the two label groups from the active colourscheme.
local function apply_label_colours()
  local function colour_of(group, attribute)
    return vim.api.nvim_get_hl(0, { name = group, link = false })[attribute]
  end
  vim.api.nvim_set_hl(0, FOCUSED_LABEL_GROUP, {
    fg = colour_of("Normal", "bg"),
    bg = colour_of("DiagnosticHint", "fg"),
    bold = true,
  })
  vim.api.nvim_set_hl(0, UNFOCUSED_LABEL_GROUP, {
    fg = vim.o.background == "dark" and WHITE or colour_of("Normal", "fg"),
    -- Unfocused windows are drawn with NormalNC where the scheme sets it.
    bg = colour_of("NormalNC", "bg") or colour_of("Normal", "bg"),
    bold = true,
  })
end

return {
  -- Plugin: incline.nvim - Floating statuslines for Neovim
  -- Repository: https://github.com/b0o/incline.nvim
  "b0o/incline.nvim",

  dependencies = { "nvim-tree/nvim-web-devicons" },

  -- Defer until after the UI paints
  event = "VeryLazy",

  opts = {
    window = {
      margin = { vertical = 0, horizontal = 1 },
      -- Under every other float (the default, 50, is level with them), so a
      -- picker or a hover window covers the label rather than the reverse.
      zindex = 10,
    },
    highlight = {
      groups = {
        InclineNormal = FOCUSED_LABEL_GROUP,
        InclineNormalNC = UNFOCUSED_LABEL_GROUP,
      },
    },
    hide = {
      -- Step out of the way while the cursor, or a Visual selection, is on
      -- the text the label covers. (incline's default; spelled out as his is.)
      cursorline = "smart",
    },
    render = function(props)
      local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(props.buf), ":t")
      local icon, icon_highlight =
        require("nvim-web-devicons").get_icon(filename, nil, { default = true })
      local label = vim.bo[props.buf].modified and ("[+] " .. filename) or filename
      -- On the accent the icon is drawn in the label's own text colour: its
      -- filetype colour is often close to the accent and disappears into it.
      local icon_part = props.focused and { icon } or { icon, group = icon_highlight }
      return { icon_part, { " " }, { label } }
    end,
  },

  config = function(_, opts)
    apply_label_colours()
    vim.api.nvim_create_autocmd("ColorScheme", {
      desc = "Re-derive the window labels' colours from the new colourscheme",
      group = vim.api.nvim_create_augroup("AndrewWindowLabel", { clear = true }),
      callback = apply_label_colours,
    })
    require("incline").setup(opts)
  end,
}
