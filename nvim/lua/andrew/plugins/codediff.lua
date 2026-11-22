-- =============================================================================
-- Diff Review Workspace (codediff.nvim)
-- =============================================================================
-- A dedicated TAB for reviewing changes: a changed-files explorer on the left
-- and a VSCode-style two-pane diff (line + character level) on the right, kept
-- in sync with the repository while it changes underneath.
--
-- Options mirror craftzdog's dotfiles
-- (https://github.com/craftzdog/dotfiles, plugins/ui.lua + plugins/keymaps.lua);
-- his three keys are moved to another prefix, see below.
-- Two of his settings are left out because they restate upstream defaults:
-- `diff.compact_sync_folds = true` and `keymaps.view = {}` (setup() deep-merges,
-- so an empty table changes nothing).
--
-- How it sits next to the other diff tools in this config:
--
--   gitsigns   -- sign column, <leader>gh staging, blame, hunk motions.
--   mini.diff  -- inline overlay in the buffer being edited (<leader>go).
--   snacks     -- <leader>gd / <leader>gD hunk PICKERS.
--   codediff   -- whole-changeset review in its own tab, plus file history.
--
-- =============================================================================
-- Keys live in the <leader>g git group
-- =============================================================================
-- craftzdog binds `<leader>dv` / `<leader>dh` / `<leader>dH`. <leader>d is the
-- DAP group here, so the three sit with the other git keys instead:
--
--   <leader>gv   review tab               (his dv, same letter)
--   <leader>gV   review tab on a commit picked from the log
--   <leader>gw   review tab on a git worktree picked from the list
--   <leader>gt   history of this file     (his dh) -- t for "timeline"
--   <leader>gT   history of the repo      (his dH)
--
-- gV and gw are not his: both are an fzf-lua picker whose Enter opens the
-- review tab on what was picked (utils/codediff_pickers.lua).
--
-- h / H could not carry over: <leader>gh is the gitsigns Hunks PREFIX, so a
-- mapping on it would wait out `timeoutlen` against every <leader>gh* key.
--
-- They are declared here, not in plugins/git.lua, because lazy.nvim `keys` are
-- what load this plugin on first press. The neighbours they are NOT: `gf` and
-- `gl` are snacks PICKERS over the same history; `gd` / `gD` are hunk pickers.
--
-- Inside a CodeDiff tab the plugin binds its own BUFFER-LOCAL keys (`g?` lists
-- them) and removes them again when the tab closes. They are upstream's
-- defaults, untouched; `q` closes the tab.
--
-- =============================================================================
-- Two downloaded binaries, both fetched by `build`
-- =============================================================================
-- Upstream fetches both from GitHub releases on FIRST USE, into the plugin dir:
--
--   libvscode_diff_<version>.so  -- the diff engine; nothing works without it.
--   codediff-watcher_<version>   -- native file watcher that keeps the explorer
--                                   live; without it the plugin warns and polls.
--
-- `build` moves both downloads to install/update time. The container bake
-- (`Lazy! sync` in container/nvim.def) depends on that: the image is read-only
-- and usually air-gapped at run time, where a first-use download can only block
-- on `curl` and then fail.
--
-- `:CodeDiff install` is upstream's public command for the library. The watcher
-- has no command, so its installer module is called directly; `ensure()` is
-- synchronous and a no-op when the binary is already present. If upstream moves
-- that module the build step fails visibly in :Lazy -- the library step has
-- already run by then, and the plugin falls back to polling.

return {
  -- Plugin: codediff.nvim - VSCode-style diff review workspace
  -- Repository: https://github.com/esmuellert/codediff.nvim
  "esmuellert/codediff.nvim",

  cmd = "CodeDiff",
  build = {
    ":CodeDiff install",
    function()
      require("codediff.core.installer.watcher").ensure(function() end)
    end,
  },

  -- =============================================================================
  -- Keybindings
  -- =============================================================================
  keys = {
    -- A bare `:CodeDiff` closes the review when run from inside its tab.
    { "<leader>gv", "<cmd>CodeDiff<CR>", desc = "CodeDiff: toggle review of working-tree changes" },
    {
      "<leader>gV",
      function()
        require("andrew.utils.codediff_pickers").pick_commit()
      end,
      desc = "CodeDiff: pick a commit and review what it changed",
    },
    {
      "<leader>gw",
      function()
        require("andrew.utils.codediff_pickers").pick_worktree()
      end,
      desc = "CodeDiff: pick a git worktree and review its changes",
    },
    { "<leader>gt", "<cmd>CodeDiff history %<CR>", desc = "CodeDiff: history of the current file" },
    { "<leader>gT", "<cmd>CodeDiff history<CR>", desc = "CodeDiff: history of the repository" },
  },

  -- =============================================================================
  -- Plugin Options
  -- =============================================================================
  opts = {
    explorer = {
      width = 50,
      -- j/k in the explorer open the file under the cursor straight away.
      auto_open_on_cursor = true,
      view_mode = "tree",
      -- Per-file `+12 -4` counts and group totals; costs extra git queries.
      line_stats = { enabled = true },
    },
    diff = {
      -- Fold unchanged regions, keeping 8 lines of context round each hunk.
      -- `gc` toggles it per session.
      compact = true,
      compact_context_lines = 8,
    },
  },
}
