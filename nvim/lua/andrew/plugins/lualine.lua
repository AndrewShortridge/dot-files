-- =============================================================================
-- Status Line Configuration (lualine.nvim)
-- =============================================================================
-- Configures lualine for a customizable status line at the bottom of the editor.
-- Displays mode, git branch, diagnostics, file info, and more.

return {
  -- Plugin: lualine.nvim - A blazing fast status line for Neovim
  -- Repository: https://github.com/nvim-lualine/lualine.nvim
  "nvim-lualine/lualine.nvim",

  -- Dependencies
  dependencies = { "nvim-tree/nvim-web-devicons" },

  -- Defer until after the UI paints (Tier 2 startup win)
  event = "VeryLazy",

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load modules
    local lualine = require("lualine")
    local lazy_status = require("lazy.status")

    -- =============================================================================
    -- OneDark Color Palette and Theme
    -- =============================================================================
    -- Both live in andrew.themes.lualine_theme so the light/dark toggle
    -- (<leader>ub, andrew.themes.toggle) can restore this exact theme when
    -- switching back to OneDark, instead of falling back to lualine's "auto".
    local onedark = require("andrew.themes.lualine_theme")
    local colors = onedark.colors
    local my_lualine_theme = onedark.theme
    local statusline_path = require("andrew.utils.statusline_path")

    -- =============================================================================
    -- Diagnostics Counts
    -- =============================================================================
    -- Two counts sit side by side: the workspace's (folder icon) and the
    -- current file's. They share symbols and colours.
    local diagnostic_symbols = {
      error = " ",
      warn = " ",
      info = " ",
      -- Extra space before the hint symbol for proper spacing
      hint = "  󰠠 ",
    }
    local diagnostic_colors = {
      error = { fg = colors.red },
      warn = { fg = colors.yellow },
      info = { fg = colors.cyan },
      hint = { fg = colors.green },
    }

    -- "Workspace" is every buffer Neovim holds diagnostics for, shown or not:
    -- exactly the entries <leader>xw lists. A server that reports on files
    -- nobody opened (lua_ls) makes that the whole project; one that reports
    -- on open files only makes it the files opened so far. What <leader>Lw
    -- finds for Fortran is in it too.
    --
    -- One pass over them. lualine's own "nvim_workspace_diagnostic" source
    -- builds a list of the diagnostics per severity on every redraw.
    local function count_workspace_diagnostics()
      local count_of_severity = vim.diagnostic.count(nil)
      local severity = vim.diagnostic.severity
      return {
        error = count_of_severity[severity.ERROR],
        warn = count_of_severity[severity.WARN],
        info = count_of_severity[severity.INFO],
        hint = count_of_severity[severity.HINT],
      }
    end

    -- Use global status line (single line for all windows)
    vim.opt.laststatus = 3

    -- =============================================================================
    -- Status Line Setup
    -- =============================================================================
    lualine.setup({
      -- General options
      options = {
        theme = my_lualine_theme,
        icons_enabled = true,
        component_separators = { left = "", right = "" },
        section_separators = { left = "", right = "" },

        -- Shown everywhere except the start screen (plugins/snacks.lua,
        -- `dashboard`), as in LazyVim. With `globalstatus` the row itself
        -- stays: lualine leaves it blank rather than removing it.
        disabled_filetypes = {
          statusline = { "snacks_dashboard" },
          winbar = {},
        },

        globalstatus = true, -- Single status line for all windows
      },

      -- =============================================================================
      -- Active Window Sections
      -- =============================================================================
      sections = {
        -- Left section: Mode indicator
        lualine_a = { "mode" },

        -- Left section: Git branch and diff
        lualine_b = {
          {
            "branch",
            icon = "",
            color = { fg = colors.yellow },
          },
          {
            "diff",
            symbols = {
              added = " ", -- Green plus for added
              modified = " ", -- Yellow pencil for modified
              removed = " ", -- Red minus for removed
            },
            diff_color = {
              added = { fg = colors.green },
              modified = { fg = colors.yellow },
              removed = { fg = colors.red },
            },
          },
        },

        -- Center section: which project, what kind of file, where it is.
        -- The project name appears only while the project root is not the
        -- working directory; the path is relative to the working directory
        -- (andrew/utils/statusline_path.lua).
        lualine_c = {
          statusline_path.root_name({ fg = colors.blue }),
          -- The icon alone, tight against the path it belongs to
          { "filetype", icon_only = true, separator = "", padding = { left = 1, right = 0 } },
          statusline_path.pretty_path(),
        },

        -- Right section: Diagnostics, encoding, format, filetype
        lualine_x = {
          -- The keys of the command being typed ('showcmd': `2d`, a Visual
          -- selection's size) and "recording @q". Neovim drew both on the
          -- message row; noice owns what appears there now
          -- (andrew/plugins/noice.lua) and draws neither.
          --
          -- noice does keep the latest 'showcmd' text, and never clears it, so
          -- the keys of the last command stay until the next one starts.
          -- 'showcmdloc' = "statusline" with a `%S` item would clear them, but
          -- loses the Visual size: lualine redraws from inside nvim_win_call(),
          -- which resets it. noice loads on VeryLazy, hence the guard.
          {
            function()
              -- noice.api reaches `status` through noice.util.lazy, whose proxy
              -- hides that it is a table<string, NoiceStatus> (noice/api/status.lua).
              ---@diagnostic disable-next-line: undefined-field
              return require("noice").api.status.command.get()
            end,
            cond = function()
              -- As above: `command` is a NoiceStatus, which has `has`.
              ---@diagnostic disable-next-line: undefined-field
              return package.loaded["noice"] ~= nil and require("noice").api.status.command.has()
            end,
            color = { fg = colors.purple },
          },
          {
            function()
              return "recording @" .. vim.fn.reg_recording()
            end,
            cond = function()
              return vim.fn.reg_recording() ~= ""
            end,
            color = { fg = colors.red },
          },

          -- Lazy plugin updates indicator
          {
            lazy_status.updates,
            cond = lazy_status.has_updates,
            color = { fg = colors.yellow },
          },

          -- Diagnostics (errors, warnings, info, hints) for the workspace
          {
            "diagnostics",
            sources = { count_workspace_diagnostics },
            sections = { "error", "warn", "info", "hint" },
            icon = { "󰉋", color = { fg = colors.purple } },
            symbols = diagnostic_symbols,
            diagnostics_color = diagnostic_colors,
          },
          -- Diagnostics (errors, warnings, info, hints) for current buffer
          {
            "diagnostics",
            sources = { "nvim_diagnostic" },
            sections = { "error", "warn", "info", "hint" },
            padding = { left = 0, right = 1 },
            symbols = diagnostic_symbols,
            diagnostics_color = diagnostic_colors,
          },

          -- File encoding
          { "encoding", color = { fg = colors.cyan } },

          -- File format (Unix/Dos/Mac)
          {
            "fileformat",
            symbols = {
              unix = "", -- Linux/Unix
              dos = "", -- Windows
              mac = "", -- macOS
            },
            color = { fg = colors.green },
          },

          -- File type icon
          { "filetype", colored = true },
        },

        -- Right section: Progress
        lualine_y = {
          {
            function()
              local wc = vim.fn.wordcount().words
              return wc .. "w"
            end,
            cond = function()
              return vim.bo.filetype == "markdown"
            end,
            color = { fg = colors.cyan },
          },
          {
            "progress",
            color = { fg = colors.purple },
          },
        },

        -- Right section: Location (line/column)
        lualine_z = {
          {
            "location",
            color = { fg = colors.blue },
          },
        },
      },

      -- =============================================================================
      -- Inactive Window Sections
      -- =============================================================================
      inactive_sections = {
        lualine_a = { "mode" },
        lualine_b = {},
        lualine_c = {
          {
            "filename",
            path = 1,
          },
        },
        lualine_x = { "location" },
        lualine_y = {},
        lualine_z = {},
      },

      -- No extensions (simpler, more consistent)
      extensions = {},
    })
  end,
}
