-- =============================================================================
-- Keybinding Hints (which-key.nvim)
-- =============================================================================
-- Displays available keybindings when the leader key is pressed.
-- Shows a popup with all key mappings starting with the pressed prefix.
--
-- Icons
-- -----
-- LazyVim itself defines NO which-key icons: all 67 of its `group =` entries
-- are bare. Every glyph you see in a LazyVim popup comes from which-key's own
-- built-in rule table (`which-key/icons.lua`), resolved through mini.icons.
-- So "LazyVim's which-key icons" are really which-key's, and we already get
-- them -- `icons.rules = {}` is a user-extension slot that is checked BEFORE
-- the built-ins and falls through to them, it does not replace them.
--
-- That leaves two real gaps, which this file closes:
--
--   1. Groups whose names match no built-in pattern (Vault, LSP, Templates,
--      Tasks, ...) rendered blank. They now carry an explicit `icon`, which
--      short-circuits rule lookup entirely.
--   2. Leaf mappings using this config's own vocabulary (template/task/query/
--      meta/check/...) matched nothing either. `icon_rules` below covers them
--      by pattern, so new mappings inherit an icon for free.
--
-- Resolution order (which-key/icons.lua:196-210): explicit `icon` -> these
-- user rules (no filetype lookup) -> built-in rules (with filetype lookup).
-- First match wins within a list, so specific patterns are ordered before
-- generic ones ("template" before "task", "check" before "link", and the
-- catch-all "vault"/"note" last).
--
-- Colors map to `WhichKeyIcon<Color>`, which link to `MiniIcons<Color>` when
-- those groups exist (onedarkpro defines them) and to `Diagnostic*` otherwise.
-- mini.icons is deliberately NOT installed: measured against this config it
-- added icons to only 6 more mappings, because the plugin-rule path needs
-- lazy-loaded `keys =` specs and almost all mappings here are registered
-- eagerly. nvim-web-devicons already covers the one rule that matters (git).

return {
  -- Plugin: which-key.nvim - Keybinding hints popup
  -- Repository: https://github.com/folke/which-key.nvim
  "folke/which-key.nvim",

  -- Load lazily
  event = "VeryLazy",

  -- =============================================================================
  -- Keybindings
  -- =============================================================================
  keys = {
    -- Hydra mode: a which-key popup that does NOT close after each action.
    -- `loop = true` makes which-key re-enter itself once a mapping runs
    -- (which-key/state.lua:357-366 re-calls State.start instead of clearing
    -- state), so the <C-w> board stays up until <Esc>. That turns the resize
    -- keys into something you can hold a conversation with: <C-w><Space> then
    -- + + + to grow, < < to narrow, j k to move, all without re-pressing <C-w>.
    --
    -- The keys it lists come from which-key's own `windows` preset
    -- (which-key/plugins/presets.lua:100-125), which is on by default and
    -- already labels <C-w> + - < > = _ | h j k l o q s v w x H J K L T. They
    -- are native Neovim commands, so nothing here rebinds them -- and <C-w>
    -- itself stays untouched, exactly as the <leader>w mirror in
    -- core/keymaps.lua promises.
    {
      "<c-w><space>",
      function()
        require("which-key").show({ keys = "<c-w>", loop = true })
      end,
      desc = "Window Hydra Mode (which-key)",
    },
  },

  -- Initialize before config
  init = function()
    -- Enable keybinding timeout
    vim.o.timeout = true

    -- Timeout length in milliseconds (500ms)
    vim.o.timeoutlen = 500
  end,

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    local wk = require("which-key")

    -- =============================================================================
    -- Icon Rules (pattern -> glyph, matched against a mapping's description)
    -- =============================================================================
    -- Checked before which-key's built-ins, top-down, first match wins.
    -- stylua: ignore
    local icon_rules = {
      -- Git: LazyVim renders these with mini.icons' `filetype = "git"` glyph
      -- (U+F02A2, MiniIconsOrange). We are on nvim-web-devicons, whose git
      -- filetype glyph is a DIFFERENT character (U+E702, the nf-dev git logo),
      -- so the built-in `{ pattern = "%f[%a]git", cat = "filetype" }` rule would
      -- not match LazyVim. Baking the literal glyph in reproduces LazyVim
      -- exactly without pulling in mini.icons. Same frontier pattern as
      -- upstream, so "lazygit" is deliberately NOT matched -- LazyVim skips it
      -- too. Listed first so "Git Current File History" reads as git, not
      -- history, which is also what LazyVim shows.
      { pattern = "%f[%a]git", icon = "󰊢 ", color = "orange" },
      -- Vault: specific actions before the generic "vault"/"note" catch-alls.
      { pattern = "template",   icon = "󰈙 ", color = "cyan"   },
      { pattern = "kanban",     icon = "󰨞 ", color = "green"  },
      { pattern = "timeline",   icon = "󰅐 ", color = "green"  },
      { pattern = "task",       icon = "󰄵 ", color = "green"  },
      { pattern = "footnote",   icon = "󰆽 ", color = "purple" },
      { pattern = "sidebar",    icon = "󱂦 ", color = "blue"   },
      { pattern = "query",      icon = "󱂔 ", color = "cyan"   },
      { pattern = "check",      icon = "󰄬 ", color = "green"  },
      { pattern = "backlink",   icon = "󰌷 ", color = "blue"   },
      { pattern = "link",       icon = "󰌷 ", color = "blue"   },
      { pattern = "graph",      icon = "󱁉 ", color = "purple" },
      { pattern = "tag",        icon = "󰓹 ", color = "yellow" },
      { pattern = "bookmark",   icon = "󰃀 ", color = "yellow" },
      { pattern = "frontmatter", icon = "󰘎 ", color = "grey"  },
      { pattern = "meta",       icon = "󰋽 ", color = "grey"   },
      { pattern = "rename",     icon = "󰑕 ", color = "orange" },
      { pattern = "export",     icon = "󰈇 ", color = "orange" },
      { pattern = "daily",      icon = "󰃭 ", color = "azure"  },
      { pattern = "journal",    icon = "󰃭 ", color = "azure"  },
      { pattern = "statistic",  icon = "󰄨 ", color = "cyan"   },
      { pattern = "dashboard",  icon = "󰸝 ", color = "cyan"   },
      { pattern = "vault",      icon = "󰠮 ", color = "purple" },
      { pattern = "note",       icon = "󰠮 ", color = "purple" },

      -- Editor / UI
      { pattern = "theme",      icon = "󰸌 ", color = "purple" },
      { pattern = "colorscheme", icon = "󰸌 ", color = "purple" },
      { pattern = "zen",        icon = "󱅻 ", color = "cyan"   },
      { pattern = "zoom",       icon = "󰊓 ", color = "blue"   },
      { pattern = "maximi",     icon = "󰊓 ", color = "blue"   },
      -- Splits: direction-specific first, then the catch-all. These must
      -- precede "window" so "Split window right" reads as a split.
      { pattern = "split window right",  icon = "󰨓 ", color = "blue" },
      { pattern = "split window vertical",  icon = "󰨓 ", color = "blue" },
      { pattern = "split window below",  icon = "󰨔 ", color = "blue" },
      { pattern = "split",        icon = "󰨔 ", color = "blue" },
      { pattern = "window",       icon = "󰔐 ", color = "blue" },
      -- Window resize / rearrange descriptions, which the generic "window" rule
      -- above does not reach (they name the dimension, not the window).
      { pattern = "width",        icon = "󰡏 ", color = "blue" },
      { pattern = "height",       icon = "󰤼 ", color = "blue" },
      { pattern = "equally high", icon = "󰕮 ", color = "blue" },
      { pattern = "swap current", icon = "󰓡 ", color = "blue" },
      -- Diagnostic severities (]e/[e, ]w/[w and the Lint group's leaves).
      { pattern = "error",        icon = "󰅚 ", color = "red"  },
      { pattern = "warning",      icon = "󰀪 ", color = "yellow" },
      { pattern = "find files",   icon = "󰱼 ", color = "green" },
      { pattern = "grep",       icon = "󱎸 ", color = "green"  },
      { pattern = "keymap",     icon = "󰌌 ", color = "cyan"   },
      { pattern = "history",    icon = "󰋚 ", color = "azure"  },
      { pattern = "help",       icon = "󰋖 ", color = "blue"   },
      { pattern = "number",     icon = "󰎠 ", color = "cyan"   },
      { pattern = "comment",    icon = "󰅺 ", color = "grey"   },
      { pattern = "flash",      icon = "󱐋 ", color = "yellow" },
      { pattern = "node",       icon = "󰅴 ", color = "green"  },

      -- Debug
      { pattern = "breakpoint", icon = "󰭂 ", color = "red"    },
      { pattern = "step",       icon = "󰆹 ", color = "red"    },
      { pattern = "evaluate",   icon = "󰓆 ", color = "red"    },
    }

    wk.setup({
      -- =============================================================================
      -- Popup Layout
      -- =============================================================================
      -- LazyVim's one and only which-key UI setting (lazyvim/plugins/editor.lua).
      -- It swaps which-key's stock "classic" popup for the "helix" one:
      --
      --   classic (was)  border "none", width math.huge, col 0
      --                  -> a borderless bar spanning the full editor width,
      --                     pinned to the bottom edge
      --   helix   (now)  border "rounded", width { min = 30, max = 60 },
      --                  col -1, row -1, title_pos "left"
      --                  -> a rounded, titled panel in the bottom-RIGHT corner,
      --                     sized to its content, columns at least 30 wide
      --
      -- See which-key/presets.lua for the two tables. Presets are merged BEFORE
      -- user opts (which-key/config.lua:233 layers defaults -> preset -> opts),
      -- so `icons.rules` below still wins; the preset only fills in `win` and
      -- `layout`, neither of which this config sets.
      preset = "helix",

      icons = {
        rules = icon_rules,
      },
    })

    -- =============================================================================
    -- Register Key Groups
    -- =============================================================================
    -- Pre-register groups so which-key shows them even for lazy-loaded plugins
    --
    -- Groups without an explicit `icon` already resolve through which-key's
    -- built-in rules (Git, Debug, Find/Files, Search, UI/Toggle, Windows,
    -- Code Actions, Trouble/Diagnostics, ...) and are left alone on purpose.

    local groups = {
      -- Bare on purpose: which-key lowercases the group name before matching
      -- its built-in rules (icons.lua:177), and rule `tab` (icons.lua:54) is
      -- the first that matches, so Title Case "Tabs" resolves to exactly the
      -- same purple nf-md-tab glyph LazyVim gets from its lowercase "tabs".
      -- Registered here even though the seven keys live in core/keymaps.lua,
      -- because which-key only needs the PREFIX to label the popup.
      { "<leader><Tab>", group = "Tabs" },
      { "<leader>a", group = "Type Check", icon = { icon = "󰕥 ", color = "cyan" } },
      { "<leader>c", group = "Code" },
      { "<leader>d", group = "Debug" },
      { "<leader>e", group = "Explorer", icon = { icon = "󰉋 ", color = "yellow" } },
      { "<leader>f", group = "Find/Files", icon = { icon = "󰱼 ", color = "green" } },
      { "<leader>g", group = "Git" },
      { "<leader>gh", group = "Hunks", icon = { icon = "󰢩 ", color = "orange" } },
      { "<leader>l", group = "LSP", icon = { icon = "󰒓 ", color = "azure" } },
      { "<leader>L", group = "Lint", icon = { icon = "󰀪 ", color = "yellow" } },
      -- Explicit icon: the built-in "ui" rule otherwise matches the *substring*
      -- in b-ui-ld and stamps Make/Build with the UI glyph.
      { "<leader>m", group = "Make/Build", icon = { icon = "󱌢 ", color = "orange" } },
      { "<leader>n", group = "Number/Search" },
      -- Bare on purpose: which-key's built-in `session` rule (icons.lua:51) is
      -- listed ahead of `quit` (icons.lua:53), so this resolves to the same
      -- azure session glyph LazyVim shows for its "quit/session" group.
      { "<leader>q", group = "Quit/Session" },
      -- Explicit icon: the group used to be "Rust/Refactor", which resolved
      -- through which-key's built-in "refactor" rule. Now that rename moved to
      -- <leader>cr the group is pure Rust, and bare "rust" matches no built-in
      -- rule -- which_key_icons_spec fails on any group that resolves to none.
      { "<leader>r", group = "Rust", icon = { icon = " ", color = "orange" } },
      { "<leader>s", group = "Search", icon = { icon = "󰍉 ", color = "green" } },
      { "<leader>t", group = "Tab/Terminal" },
      -- Children live in ftplugin/markdown.lua (<leader>Tc/Tdt/Tir/Tm).
      { "<leader>T", group = "Table", icon = { icon = "󰓫 ", color = "cyan" } },
      { "<leader>u", group = "UI/Toggle" },
      { "<leader>v", group = "Vault", icon = { icon = "󰠮 ", color = "purple" } },
      { "<leader>va", group = "AutoLink", icon = { icon = "󰌷 ", color = "blue" } },
      { "<leader>vb", group = "Bookmarks", icon = { icon = "󰃀 ", color = "yellow" } },
      { "<leader>vc", group = "Check", icon = { icon = "󰄬 ", color = "green" } },
      { "<leader>vd", group = "Daily", icon = { icon = "󰃭 ", color = "azure" } },
      { "<leader>ve", group = "Edit", icon = { icon = "󰏫 ", color = "orange" } },
      { "<leader>vf", group = "Find" },
      { "<leader>vg", group = "Graph/Tags", icon = { icon = "󱁉 ", color = "purple" } },
      { "<leader>vk", group = "BlockId", icon = { icon = "󰌋 ", color = "azure" } },
      { "<leader>vm", group = "Meta", icon = { icon = "󰋽 ", color = "grey" } },
      { "<leader>vq", group = "Query", icon = { icon = "󱂔 ", color = "cyan" } },
      { "<leader>vS", group = "Sidebar", icon = { icon = "󱂦 ", color = "blue" } },
      { "<leader>vt", group = "Templates", icon = { icon = "󰈙 ", color = "cyan" } },
      { "<leader>vx", group = "Tasks", icon = { icon = "󰄵 ", color = "green" } },
      -- Leaf mapping, not a prefix: <leader>v? opens the vault command palette
      -- directly, so it carries an icon but must NOT be registered as a group.
      { "<leader>v?", icon = { icon = "󰏘 ", color = "purple" } },
      -- `expand` mirrors LazyVim: it lists every other visible window in the
      -- tabpage as <leader>w0..<leader>w9 for direct jumps.
      {
        "<leader>w",
        group = "Windows",
        icon = { icon = "󰔐 ", color = "blue" },
        expand = function()
          return require("which-key.extras").expand.win()
        end,
      },
      { "<leader>x", group = "Trouble/Diagnostics" },
    }

    -- LazyVim registers its whole group block under `mode = { "n", "x" }`
    -- (lazyvim/plugins/editor.lua:67); which-key otherwise defaults to normal
    -- mode only (which-key/mappings.lua:277), which left the visual-mode popup
    -- unlabeled for the prefixes that DO have visual maps -- <leader>c
    -- (ca/cc, lsp_keymaps.lua), <leader>g and <leader>gh (gitsigns ghs/ghr,
    -- git gB). Groups whose keys are normal-only simply never surface in the
    -- visual popup, so tagging the whole list is safe and keeps new groups
    -- correct by default.
    --
    -- Applied as a field on each FLAT entry rather than by wrapping the list in
    -- a `{ mode = ..., {...}, {...} }` table: which_key_icons_spec walks the
    -- top level of what reaches wk.add, and a wrapper would collapse 34 group
    -- entries into 1.
    for _, group in ipairs(groups) do
      group.mode = { "n", "x" }
    end

    wk.add(groups)
  end,
}
