-- =============================================================================
-- Auto-Pairs Configuration (nvim-autopairs)
-- =============================================================================
-- Automatically inserts and manages matching pairs: (), [], {}, "", '', etc.
-- Integrates with completion plugins for intelligent pair handling.

return {
  -- Plugin: nvim-autopairs - Auto-close brackets and quotes
  -- Repository: https://github.com/windwp/nvim-autopairs
  "windwp/nvim-autopairs",

  -- Load when entering insert mode
  event = { "InsertEnter" },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load autopairs module
    local autopairs = require("nvim-autopairs")

    -- Configure autopairs behavior
    autopairs.setup({
      -- Enable tree-sitter integration for smart pair detection
      check_ts = true,

      -- Tree-sitter configuration for ignored nodes
      ts_config = {
        lua = { "string" },             -- Don't auto-pair in Lua strings
        javascript = { "template_string" },  -- Don't auto-pair in JS template strings
        java = false,                   -- Disable tree-sitter for Java
      },
    })

    -- =========================================================================
    -- markdown: re-open blink's menu after autopairs completes a `[[` wikilink
    -- =========================================================================
    -- Autopairs' `[` rule is an expr mapping that returns `[` .. `]` .. <Left>,
    -- so BOTH characters go through InsertCharPre. blink.cmp records only the
    -- LAST one (lib/buffer_events.lua sets `last_char = vim.v.char` and reads it
    -- on TextChangedI), so after typing `[[` blink sees `]` -- neither a trigger
    -- character nor a keyword character -- and calls trigger.hide(). Result:
    -- `[[` produced `[[]]` with an empty menu (0 items) and the vault wikilink
    -- list only appeared once a letter was typed (`[[a` -> items).
    --
    -- The pairing itself is wanted (the vault completion source relies on the
    -- pre-inserted `]]`: completion.lua strips the `]]` from insertText when it
    -- is already after the cursor, which is what keeps an accepted item at
    -- exactly one `[[Note]]`). So keep the pair and just re-ask blink to show.
    --
    -- Hooked through the `[` rule's end_pair callback rather than a TextChangedI
    -- autocmd so this costs nothing on any keystroke other than `[`.
    local bracket = autopairs.get_rule("[")
    bracket = bracket and (bracket.replace_endpair and bracket or bracket[1])
    if bracket then
      bracket:replace_endpair(function(opts)
        -- opts.col is the 1-based index of the `[` being typed, so opts.col - 1
        -- is the character before it: a second `[` means a wikilink opener.
        if
          opts.char == "["
          and opts.line
          and opts.line:sub(opts.col - 1, opts.col - 1) == "["
          and vim.bo[opts.bufnr or 0].filetype == "markdown"
        then
          vim.schedule(function()
            if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
              return
            end
            local ok, blink = pcall(require, "blink.cmp")
            if ok then
              pcall(blink.show)
            end
          end)
        end
        return "]"
      end)
    end
  end,
}
