-- =============================================================================
-- File Type Icons (nvim-web-devicons)
-- =============================================================================
-- Provides file type icons for various UI components:
-- - lualine statusline
-- - bufferline tabs
-- - fzf-lua fuzzy finder
-- - and other plugins
--
-- How lualine resolves the statusline icon
-- ----------------------------------------
-- lualine's `filetype` component tries the FILE NAME first and the FILETYPE
-- second, then gives up:
--
--   devicons.get_icon(vim.fn.expand("%:t"))   -- filename, extension parsed from it
--   devicons.get_icon_by_filetype(vim.bo.filetype)
--   -- both nil: a hardcoded grey U+E612 with the DevIconDefault highlight
--
-- (lualine.nvim/lua/lualine/components/filetype.lua:33-42.)  So an unmapped
-- buffer is not blank -- it is the same grey generic page as every other
-- unmapped buffer, which is what the registrations below fix.
--
-- The filetype leg needs BOTH halves: `set_icon_by_filetype` maps a filetype to
-- an icon KEY, and that key has to exist in the icon table, which is what
-- `set_icon` adds.  Filetype names are matched exactly; icon keys are matched
-- lower-cased.
--
-- Glyphs
-- ------
-- Everything here is nf-md, Plane-15 (U+F0000+).  Writing BMP private-use
-- glyphs (U+E000-U+F8FF) into a source file silently strips them, leaving an
-- empty icon -- which is worse than none, since a blank still counts as a hit.
-- This file is generated so no glyph has to be typed by hand; every codepoint
-- is checked against the installed font's cmap first.
--
-- The installed font is JetBrainsMono Nerd Font 3.5.1, which carries all 336
-- glyphs devicons ships.  The 73 substitute-glyph overrides that used to live
-- here were for the old 3.0.2 font and are gone.
--
-- Covered by tests/devicons_font_coverage_spec.lua.

return {
  -- Plugin: nvim-web-devicons - File type icons for Neovim
  -- Repository: https://github.com/nvim-tree/nvim-web-devicons
  "nvim-tree/nvim-web-devicons",

  -- Load lazily (only when needed)
  lazy = true,

  -- Use default configuration
  opts = {},

  config = function(_, opts)
    local devicons = require("nvim-web-devicons")
    devicons.setup(opts)

    -- Icon entries.  set_icon() is used rather than setup({ override = ... })
    -- because setup() is a no-op once devicons has already initialised, which
    -- it may have via another plugin's require.
    devicons.set_icon({
      -- Fortran: devicons only ships .f90 / .F90; these are the other five
      -- suffixes gfortran accepts, using devicons' own Fortran glyph+colour.
      ["f95"]                     = { icon = "󱈚", color = "#734F96", cterm_color = "60", name = "Fortran" }, -- md-language_fortran
      ["f03"]                     = { icon = "󱈚", color = "#734F96", cterm_color = "60", name = "Fortran" }, -- md-language_fortran
      ["f"]                       = { icon = "󱈚", color = "#734F96", cterm_color = "60", name = "Fortran" }, -- md-language_fortran
      ["for"]                     = { icon = "󱈚", color = "#734F96", cterm_color = "60", name = "Fortran" }, -- md-language_fortran
      ["f77"]                     = { icon = "󱈚", color = "#734F96", cterm_color = "60", name = "Fortran" }, -- md-language_fortran

      -- Data / input decks this vault and the Fortran work actually open.
      ["dat"]                     = { icon = "󰆼", color = "#6D8086", cterm_color = "66", name = "Data" }, -- md-database
      ["nml"]                     = { icon = "󰒓", color = "#6D8086", cterm_color = "66", name = "Namelist" }, -- md-cog
      ["in"]                      = { icon = "󰒓", color = "#6D8086", cterm_color = "66", name = "InputDeck" }, -- md-cog
      ["gnu"]                     = { icon = "󰄪", color = "#7DAEA3", cterm_color = "109", name = "Gnuplot" }, -- md-chart_line
      ["gp"]                      = { icon = "󰄪", color = "#7DAEA3", cterm_color = "109", name = "Gnuplot" }, -- md-chart_line

      -- Filetypes nvim misdetects for this user's .p / .inf data files.
      ["progress"]                = { icon = "󰈙", color = "#6D8086", cterm_color = "66", name = "Progress" }, -- md-file_document
      ["inform"]                  = { icon = "󰈙", color = "#6D8086", cterm_color = "66", name = "Inform" }, -- md-file_document
      ["gitrebase"]               = { icon = "󰊢", color = "#F14C28", cterm_color = "202", name = "GitRebase" }, -- md-git

      -- Plugin UI buffers.  devicons has no filetype mapping for any of these,
      -- so without them every picker, tree and panel shows the same grey
      -- U+E612 fallback lualine substitutes when both lookups miss.
      ["snacks_dashboard"]        = { icon = "󰕮", color = "#7AA2F7", cterm_color = "111", name = "Dashboard" }, -- md-view_dashboard
      ["picker"]                  = { icon = "󰍉", color = "#7DAEA3", cterm_color = "109", name = "Picker" }, -- md-magnify
      ["notification"]            = { icon = "󰂜", color = "#E5C07B", cterm_color = "180", name = "Notification" }, -- md-bell_outline
      ["terminal_ui"]             = { icon = "󰆍", color = "#98C379", cterm_color = "108", name = "Terminal" }, -- md-console
      ["input_ui"]                = { icon = "󰘎", color = "#7AA2F7", cterm_color = "111", name = "Input" }, -- md-form_textbox
      ["help_ui"]                 = { icon = "󰗚", color = "#6D8086", cterm_color = "66", name = "Help" }, -- md-book_open_page_variant
      ["snacks_image"]            = { icon = "󰋩", color = "#C678DD", cterm_color = "176", name = "Image" }, -- md-image
      ["qf"]                      = { icon = "󰉹", color = "#E06C75", cterm_color = "168", name = "Quickfix" }, -- md-format_list_bulleted
      ["trouble"]                 = { icon = "󰗖", color = "#E06C75", cterm_color = "168", name = "Trouble" }, -- md-alert_circle_outline
      ["lazy"]                    = { icon = "󰒲", color = "#C678DD", cterm_color = "176", name = "Lazy" }, -- md-sleep
      ["mason"]                   = { icon = "󰏔", color = "#98C379", cterm_color = "108", name = "Mason" }, -- md-package_down
      ["wk"]                      = { icon = "󰌌", color = "#7AA2F7", cterm_color = "111", name = "WhichKey" }, -- md-keyboard
      ["noice"]                   = { icon = "󰍥", color = "#C678DD", cterm_color = "176", name = "Noice" }, -- md-message_outline
      ["yazi"]                    = { icon = "󰝰", color = "#E5C07B", cterm_color = "180", name = "Yazi" }, -- md-folder_open
      ["dap_ui"]                  = { icon = "󰃤", color = "#E06C75", cterm_color = "168", name = "Dap" }, -- md-bug
      ["dap-repl"]                = { icon = "󰞷", color = "#E06C75", cterm_color = "168", name = "DapRepl" }, -- md-console_line
      ["opencode_ask"]            = { icon = "󱙺", color = "#61AFEF", cterm_color = "75", name = "OpenCode" }, -- md-robot_outline
      ["gitsigns-blame"]          = { icon = "󰘬", color = "#F14C28", cterm_color = "202", name = "GitBlame" }, -- md-source_branch
      ["blink-cmp-documentation"] = { icon = "󰧭", color = "#6D8086", cterm_color = "66", name = "CmpDoc" }, -- md-text_box_outline
      ["lspinfo"]                 = { icon = "󰋽", color = "#61AFEF", cterm_color = "75", name = "LspInfo" }, -- md-information_outline

      -- Buffers this config defines itself.
      ["typecheck"]               = { icon = "󰞑", color = "#98C379", cterm_color = "108", name = "TypeCheck" }, -- md-check_decagram
      ["vault_sidebar"]           = { icon = "󰙅", color = "#7AA2F7", cterm_color = "111", name = "VaultSidebar" }, -- md-file_tree
      ["vault_fm_editor"]         = { icon = "󰨸", color = "#E5C07B", cterm_color = "180", name = "VaultFrontmatter" }, -- md-clipboard_text_outline
      ["vault-collisions"]        = { icon = "󰀩", color = "#E06C75", cterm_color = "168", name = "VaultCollisions" }, -- md-alert_octagon
      ["vault-profiler"]          = { icon = "󰍛", color = "#C678DD", cterm_color = "176", name = "VaultProfiler" }, -- md-memory
      ["vault_readable_pad"]      = { icon = "󰖯", color = "#6D8086", cterm_color = "66", name = "ReadablePad" }, -- md-window_maximize
    })

    -- Filetype -> icon key.
    devicons.set_icon_by_filetype({
      -- Fortran dialects: reuse devicons' own f90 entry.
      ["fortran_free"]            = "f90",
      ["fortran_fixed"]           = "f90",
      ["f95"]                     = "f90",

      -- Misdetected data files.
      ["progress"]                = "progress",
      ["inform"]                  = "inform",
      ["gitrebase"]               = "gitrebase",

      -- snacks.nvim.
      ["snacks_dashboard"]        = "snacks_dashboard",
      ["snacks_picker_list"]      = "picker",
      ["snacks_picker_input"]     = "picker",
      ["snacks_picker_preview"]   = "picker",
      ["snacks_notif"]            = "notification",
      ["snacks_notif_history"]    = "notification",
      ["snacks_terminal"]         = "terminal_ui",
      ["snacks_input"]            = "input_ui",
      ["snacks_win_help"]         = "help_ui",
      ["snacks_image"]            = "snacks_image",

      -- Other plugin panels.
      ["fzf"]                     = "picker",
      ["trouble"]                 = "trouble",
      ["lazy"]                    = "lazy",
      ["mason"]                   = "mason",
      ["wk"]                      = "wk",
      ["noice"]                   = "noice",
      ["yazi"]                    = "yazi",
      ["opencode_ask"]            = "opencode_ask",
      ["gitsigns-blame"]          = "gitsigns-blame",
      ["blink-cmp-documentation"] = "blink-cmp-documentation",
      ["DressingInput"]           = "input_ui",
      ["DressingSelect"]          = "input_ui",

      -- nvim-dap-ui.
      ["dapui_scopes"]            = "dap_ui",
      ["dapui_breakpoints"]       = "dap_ui",
      ["dapui_stacks"]            = "dap_ui",
      ["dapui_watches"]           = "dap_ui",
      ["dapui_console"]           = "dap_ui",
      ["dapui_hover"]             = "dap_ui",
      ["dap-repl"]                = "dap-repl",

      -- Built-in buffers devicons leaves unmapped.
      ["qf"]                      = "qf",
      ["man"]                     = "help_ui",
      ["lspinfo"]                 = "lspinfo",

      -- Defined by this config.
      ["floating_terminal"]       = "terminal_ui",
      ["typecheck"]               = "typecheck",
      ["vault_sidebar"]           = "vault_sidebar",
      ["vault_fm_editor"]         = "vault_fm_editor",
      ["vault-collisions"]        = "vault-collisions",
      ["vault-profiler"]          = "vault-profiler",
      ["vault_readable_pad"]      = "vault_readable_pad",
    })
  end,
}
