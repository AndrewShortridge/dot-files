-- =============================================================================
-- OpenCode AI Integration (opencode.nvim)
-- =============================================================================
-- AI-powered coding assistant integration.
-- Provides commands for asking questions about code and generating responses.
--
-- KEYMAPS REMOVED (2026-09-06, by request). The plugin, its dependency and its
-- startup side effects are all still declared below -- only the bindings are
-- gone, so opencode has no interactive entry point. See the disabled block
-- further down to restore them.

return {
  -- Plugin: opencode.nvim - AI coding assistant for Neovim
  -- Repository: https://github.com/NickvanDyke/opencode.nvim
  "NickvanDyke/opencode.nvim",

  -- Dependencies
  dependencies = {
    -- Snacks for UI components (configured in plugins/snacks.lua)
    "folke/snacks.nvim",
  },

  -- =============================================================================
  -- lazy = true is LOAD-BEARING now that `keys` is gone.
  -- =============================================================================
  -- lazy.nvim infers lazy=true from the PRESENCE of a lazy handler (keys/cmd/
  -- event/ft). With the keymaps removed there is no handler left, so a spec
  -- that merely dropped `keys` would fall back to lazy=false and start
  -- sourcing opencode's 6 plugin/*.lua files at every startup -- the exact
  -- regression the old `keys` table was there to prevent, now with no keymaps
  -- to show for it. Setting lazy=true explicitly keeps the plugin dormant:
  -- installed and updatable by :Lazy, loaded only by an explicit
  -- require("opencode"), which nothing in this config does.
  lazy = true,

  -- =============================================================================
  -- Disabled keymaps (previously the `keys = {}` table).
  -- =============================================================================
  -- Kept verbatim as a comment so restoring is a matter of uncommenting this
  -- block and deleting the `lazy = true` line above -- `keys` re-implies
  -- lazy=true on its own, and the two must not both be present in a way that
  -- suggests the plugin is reachable when it is not.
  --
  -- keys = {
  --   -- Toggle the OpenCode panel
  --   { "<leader>ot", function() require("opencode").toggle() end, desc = "Toggle OpenCode panel" },
  --
  --   -- Ask about code at cursor
  --   { "<leader>oa", function() require("opencode").ask("@cursor: ") end, desc = "Ask OpenCode about code at cursor" },
  --
  --   -- Ask about selected code
  --   { "<leader>oa", function() require("opencode").ask("@selection: ") end, mode = "v", desc = "Ask OpenCode about selected code" },
  --
  --   -- Add buffer to prompt
  --   { "<leader>o+", function() require("opencode").prompt("@buffer", { append = true }) end, desc = "Add current buffer to OpenCode prompt" },
  --
  --   -- Add selection to prompt
  --   { "<leader>o+", function() require("opencode").prompt("@selection", { append = true }) end, mode = "v", desc = "Add selection to OpenCode prompt" },
  --
  --   -- Explain code at cursor
  --   { "<leader>oe", function() require("opencode").prompt("Explain @cursor and its context") end, desc = "Explain code at cursor" },
  --
  --   -- New session
  --   { "<leader>on", function() require("opencode").command("session_new") end, desc = "Create new OpenCode session" },
  --
  --   -- Message navigation
  --   { "<S-C-u>", function() require("opencode").command("messages_half_page_up") end, desc = "Scroll OpenCode messages up" },
  --   { "<S-C-d>", function() require("opencode").command("messages_half_page_down") end, desc = "Scroll OpenCode messages down" },
  --
  --   -- Select prompt
  --   { "<leader>os", function() require("opencode").select() end, mode = { "n", "v" }, desc = "Select OpenCode prompt" },
  -- },

  -- =============================================================================
  -- Startup side effects (run WITHOUT loading the plugin).
  -- =============================================================================
  -- Deliberately KEPT. The request was to remove the keymaps, not the setup, so
  -- init() still runs on every startup exactly as before. lazy.nvim runs init()
  -- for dormant plugins by design, so this is unaffected by lazy = true.
  init = function()
    -- Empty options (use defaults)
    vim.g.opencode_opts = {}

    -- Enable auto-reload for file changes (opencode reload.lua expects this)
    vim.opt.autoread = true
  end,
}
