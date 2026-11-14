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
          -- nvim-surround's `change.target` uses FOUR captures, read as
          -- (text)(pos)(text)(pos) -- see nvim-surround/patterns.lua
          -- get_selections(), which derives each replaced region as "the
          -- #text characters ending immediately BEFORE pos". The empty
          -- position capture must therefore sit DIRECTLY after the text it
          -- belongs to; with a literal `}` in between, both regions slid one
          -- character right and `cs?e` rewrote "temize}" instead of
          -- "itemize", corrupting the buffer (e.g. `\begin{ialign`).
          target = "^\\begin{(.-)()}.+\\end{(.-)()}$",
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
          -- Same four-capture convention as `e` above. Only the command NAME
          -- is rewritten, so the right-hand region is deliberately empty --
          -- exactly how nvim-surround's own `f` (function call) surround is
          -- written, and what `replacement` below already returns ({cmd},{""}).
          -- The old pattern put `()` after the `{`, so `cscc` replaced
          -- "extbf{" rather than "textbf".
          target = "^\\(%a+)(){.-}()()$",
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
