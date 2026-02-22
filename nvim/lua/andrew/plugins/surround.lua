-- =============================================================================
-- Surround Plugin (nvim-surround)
-- =============================================================================
-- Provides mappings to easily add, change, and delete surrounding pairs.
-- Works with: parentheses, brackets, braces, quotes, tags, and more.

return {
  -- Plugin: nvim-surround - Surround plugin for Neovim
  -- Repository: https://github.com/kylechui/nvim-surround
  "kylechui/nvim-surround",

  -- Load when reading files
  event = { "BufReadPre", "BufNewFile" },

  -- Use latest stable version
  version = "*",

  opts = {
    surrounds = {
      -- LaTeX environment: use "e" to wrap with \begin{env}...\end{env}
      -- Usage: ysiwe → wrap word, ySse → wrap line, vSe → wrap selection
      ["e"] = {
        add = function()
          local env = require("nvim-surround.config").get_input("Environment: ")
          if env then
            return {
              { "\\begin{" .. env .. "}" },
              { "\\end{" .. env .. "}" },
            }
          end
        end,
        find = "\\begin%b{}.-\\end%b{}",
        delete = "^(\\begin%b{})().-(\\end%b{})()$",
        change = {
          target = "^\\begin{(.-)}().+\\end{(.-)}()$",
          replacement = function()
            local env = require("nvim-surround.config").get_input("Environment: ")
            if env then
              return { { env }, { env } }
            end
          end,
        },
      },
      -- LaTeX command: use "c" in tex files to wrap with \cmd{}
      -- Usage: ysiwc → wrap word, vSc → wrap selection
      ["c"] = {
        add = function()
          local cmd = require("nvim-surround.config").get_input("Command: ")
          if cmd then
            return {
              { "\\" .. cmd .. "{" },
              { "}" },
            }
          end
        end,
        find = "\\%a+%b{}",
        delete = "^(\\%a+{)().-(})()$",
        change = {
          target = "^\\(%a+){().-(})()$",
          replacement = function()
            local cmd = require("nvim-surround.config").get_input("Command: ")
            if cmd then
              return { { cmd }, { "" } }
            end
          end,
        },
      },
    },
  },
}
