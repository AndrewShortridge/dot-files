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

        -- Never disable status line (always show)
        disabled_filetypes = {
          statusline = {},
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

        -- Center section: Filename
        lualine_c = {
          {
            "filename",
            file_status = true, -- Show modified/readonly status
            newfile_status = true, -- Show [New] for unsaved files
            path = 1, -- Show relative path
            symbols = {
              modified = " ●", -- Modified indicator
              readonly = " ", -- Readonly indicator
              unnamed = "[No Name]", -- Placeholder for unnamed buffers
            },
          },
        },

        -- Right section: Diagnostics, encoding, format, filetype
        lualine_x = {
          -- Lazy plugin updates indicator
          {
            lazy_status.updates,
            cond = lazy_status.has_updates,
            color = { fg = colors.yellow },
          },

          -- Workspace diagnostics (from <leader>lw Fortran lint)
          -- Single component with highlight groups for coloring: folder (purple), errors (red), warnings (yellow)
          {
            function()
              local ws = _G.fortran_workspace_diagnostics or { errors = 0, warnings = 0 }
              if ws.errors == 0 and ws.warnings == 0 then
                return ""
              end

              -- Create highlight groups if they don't exist
              vim.api.nvim_set_hl(0, "LualineWsFolder", { fg = "#c678dd" }) -- purple
              vim.api.nvim_set_hl(0, "LualineWsError", { fg = "#e06c75" }) -- red
              vim.api.nvim_set_hl(0, "LualineWsWarn", { fg = "#e5c07b" }) -- yellow

              local result = "%#LualineWsFolder#󰉋"
              if ws.errors > 0 then
                result = result .. "%#LualineWsError#  " .. ws.errors
              end
              if ws.warnings > 0 then
                result = result .. "%#LualineWsWarn#  " .. ws.warnings
              end
              return result .. "%*"
            end,
            cond = function()
              local ws = _G.fortran_workspace_diagnostics or { errors = 0, warnings = 0 }
              return ws.errors > 0 or ws.warnings > 0
            end,
          },
          -- Diagnostics (errors, warnings, hints, info) for current buffer
          {
            "diagnostics",
            sources = { "nvim_diagnostic" },
            sections = { "error", "warn", "info", "hint" },
            padding = { left = 0, right = 1 },
            -- Extra space before warn/info/hint for proper spacing
            symbols = {
              error = " ",
              warn = " ",
              info = " ",
              hint = "  󰠠 ",
            },
            diagnostics_color = {
              error = { fg = colors.red },
              warn = { fg = colors.yellow },
              info = { fg = colors.cyan },
              hint = { fg = colors.green },
            },
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
