-- =============================================================================
-- Command Line and Message UI (noice.nvim)
-- =============================================================================
-- Two jobs:
--
--   1. The command line. `:` opens in a floating popup; `/` and `?` get an icon
--      plus regex syntax highlighting.
--
--   2. Messages. What Neovim would print on the message row -- "3 lines yanked",
--      "3 fewer lines", a write confirmation, an error -- appears in a small box
--      at the bottom-right corner instead. Messages arriving close together
--      stack in that one box, newest at the bottom, and each line leaves on its
--      own timer. Modelled on craftzdog's dotfiles, which get the same box from
--      Neovim's experimental message UI (`vim._core.ui2`); that UI draws a
--      command line of its own, which would double up with the one above.
--
-- Still NOT noice's: vim.notify, the LSP hover / signature windows and the
-- wildmenu. vim.notify stays Neovim's stock function (vault/notify.lua and
-- vault/vault_log.lua call it directly); what it prints is an ordinary message
-- and so lands in the box like any other. snacks owns vim.ui.input and
-- vim.ui.select.
--
-- Taking the messages over also takes them off the message row for good, and
-- with them the two things Neovim drew there besides messages: the pending
-- keys ('showcmd') and "recording @q". Both are shown in the statusline
-- instead (andrew/plugins/lualine.lua).

-- How long one message stays in the box, as in craftzdog's message window.
local MESSAGE_TIMEOUT_MS = 5000

-- The box grows to this many lines; a taller message opens in a split.
local MESSAGE_BOX_MAX_HEIGHT = 10

-- Kinds that always open in the split, whatever their height: a `:!command`
-- and a 'verbose' trace each arrive as several messages, which belong
-- together. See `:help ui-messages` for every kind.
local MULTI_PART_MESSAGE_KINDS = { "shell_cmd", "shell_out", "shell_err", "verbose" }

-- Kinds that only made sense on the message row: the echo of a search
-- repeated with `n`, insert-completion status, the 'wildmode' list, and the
-- empty message whose one purpose is to clear that row.
local MESSAGE_ROW_ONLY_KINDS = { "search_cmd", "completion", "wildlist", "empty" }

-- Kinds noice has a dedicated view for, which the catch-all route below must
-- leave to noice's own routes: prompts expecting an answer, and the search
-- count (virtual text beside the match).
local NOICE_ROUTED_KINDS = { "confirm", "confirm_sub", "number_prompt", "search_count" }

return {
  -- Plugin: noice.nvim - replaces the UI for the cmdline, messages, popupmenu
  -- Repository: https://github.com/folke/noice.nvim
  "folke/noice.nvim",

  -- Load after startup; nothing here is needed to draw the first frame
  event = "VeryLazy",

  -- Plugin dependencies
  dependencies = {
    "MunifTanjim/nui.nvim", -- Float/popup primitives noice renders into
  },

  opts = {
    cmdline = {
      enabled = true,
      view = "cmdline_popup",
    },

    -- Every message goes to the box ("mini" is noice's name for it). These
    -- three are the views noice's built-in routes use; the routes below decide
    -- first, and cover the message kinds the built-in ones do not know.
    messages = {
      enabled = true,
      view = "mini",
      view_error = "mini",
      view_warn = "mini",
    },

    -- Leave notifications and the wildmenu alone (see header note)
    notify = { enabled = false },
    popupmenu = { enabled = false },

    -- Leave every LSP window rendered by nvim/lspconfig as-is
    lsp = {
      hover = { enabled = false },
      signature = { enabled = false },
      message = { enabled = false },
      progress = { enabled = false },
      override = {
        ["vim.lsp.util.convert_input_to_markdown_lines"] = false,
        ["vim.lsp.util.stylize_markdown"] = false,
        ["cmp.entry.get_documentation"] = false,
      },
    },

    views = {
      -- The message box
      mini = {
        timeout = MESSAGE_TIMEOUT_MS,
        border = { style = "rounded" },
        size = { max_height = MESSAGE_BOX_MAX_HEIGHT },
        -- Bottom-right, one row up from noice's default so that the border
        -- clears the statusline
        position = { row = -2, col = "100%" },
        -- Oldest message at the top, text flush left, and the text alone:
        -- noice would otherwise prefix errors with an icon and "Error"
        reverse = false,
        align = "message-left",
        format = { "{message}" },
        win_options = {
          winblend = 0,
          -- The background and grey border of the pickers
          -- (andrew/utils/fzf_look.lua). noice's defaults under onedark are
          -- a red border, which reads as an alarm, on a darker background.
          winhighlight = { Normal = "TelescopeNormal", FloatBorder = "TelescopeBorder" },
        },
      },
    },

    -- A message takes the first route that matches it. These come before
    -- noice's built-in routes.
    routes = {
      {
        filter = { event = "msg_show", kind = MESSAGE_ROW_ONLY_KINDS },
        opts = { skip = true },
      },

      -- Writing a file sends two messages: `"name" ` when the write starts,
      -- then the full `"name" 12L, 291B written`, marked as replacing the
      -- first. noice does not act on that mark and would show both lines.
      {
        filter = { event = "msg_show", kind = "progress", find = '^"[^"]*"%s*$' },
        opts = { skip = true },
      },

      -- Anything too tall for the box (`:map`, a long traceback), and the
      -- multi-part kinds, open in a split at the bottom with the cursor in
      -- it; `q` closes it.
      {
        view = "messages",
        filter = {
          event = "msg_show",
          any = {
            { kind = MULTI_PART_MESSAGE_KINDS },
            { min_height = MESSAGE_BOX_MAX_HEIGHT + 1 },
          },
        },
      },

      -- Everything else goes to the box. noice's built-in routes name the
      -- kinds they send to `messages.view` one by one and predate several
      -- (bufwrite, undo, quickfix, shell_ret, ...), which would otherwise match
      -- no route and never be shown.
      {
        view = "mini",
        filter = { event = "msg_show", ["not"] = { kind = NOICE_ROUTED_KINDS } },
      },
    },

    presets = {
      -- `:` popup sits near the top of the screen rather than dead centre
      command_palette = true,

      -- `/` and `?` render as a styled full-width bottom line, matching
      -- LazyVim. Set to false to float them in the same popup as `:`.
      bottom_search = true,

      -- The split route above does this job, with the box's height as the limit
      long_message_to_split = false,
      inc_rename = false,
    },
  },
}
