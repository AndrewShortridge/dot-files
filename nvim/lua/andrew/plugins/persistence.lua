-- =============================================================================
-- Session Management (<leader>q)
-- =============================================================================
-- LazyVim's `<leader>q` quit/session group, ported wholesale from
-- lazyvim/plugins/util.lua:40-53 plus the standalone `<leader>qq` from
-- lazyvim/config/keymaps.lua:183 (which lives in core/keymaps.lua here, matching
-- where LazyVim puts it).
--
-- persistence.nvim saves a session per working directory -- open buffers, window
-- layout, tabpages -- on VimLeavePre, and restores it on demand. Nothing is
-- restored automatically; every entry point below is explicit.
--
-- Session file: ~/.local/state/nvim/sessions/<cwd-with-slashes-as-%>.vim, with
-- the git branch appended when it is not main/master (persistence/init.lua:11-21).
-- So a session is per-directory AND per-branch, and switching branches gives you
-- a different session -- `<leader>qs` falls back to the branchless file when the
-- branch-specific one does not exist yet.
--
-- =============================================================================
-- Why `event`, and not a pure `keys` gate
-- =============================================================================
-- The save hook is a VimLeavePre autocmd registered by setup() via M.start()
-- (persistence/init.lua:39-61). lazy.nvim only calls setup() once the plugin
-- loads, so gating this spec on `keys` alone would mean NOTHING IS EVER SAVED
-- until you happened to press one of the four keys in that session -- and the
-- keys that matter are for restoring, which you press at the START of a session.
-- The failure is silent: no error, just a session dir that stays empty.
-- `event = "BufReadPre"` (LazyVim's choice) makes the hook exist as soon as a
-- real file is opened, which is also why an empty `nvim` never saves.
--
-- =============================================================================
-- Deviations from LazyVim, and why
-- =============================================================================
--   * None in the keymaps: all five keys, their rhs and their descriptions are
--     byte-identical to LazyVim's.
--
--   * `opts = {}` is kept literally empty, as LazyVim has it. That is
--     load-bearing rather than lazy: lazy.nvim only calls setup() when `opts`
--     (or config) is present, and setup() is what starts the save hook. The
--     defaults it accepts are dir / need=1 / branch=true
--     (persistence/config.lua:4-10); `need = 1` means a session is only written
--     when at least one real file buffer is open, so quitting out of a scratch
--     or dashboard buffer will not clobber a good session with an empty one.
--
--   * The which-key group is registered in plugins/which-key.lua as
--     "Quit/Session" (Title Case) rather than LazyVim's lowercase
--     "quit/session", matching how every other group in this config is written.
--     It is left WITHOUT an explicit icon on purpose: which-key's built-in rule
--     list has `session` (icons.lua:51) ahead of `quit` (icons.lua:53), so the
--     group resolves to the same azure session glyph LazyVim shows.
--
-- Related: `<leader>wq` (quit a WINDOW) is a different thing that reads
-- similarly in which-key -- see core/keymaps.lua.
--
-- Covered by tests/session_keymaps_spec.lua.

return {
  -- Plugin: persistence.nvim - Session management for Neovim
  -- Repository: https://github.com/folke/persistence.nvim
  "folke/persistence.nvim",

  -- Load once a real file is open, so the VimLeavePre save hook is armed long
  -- before you quit. See the note above -- this must not become a keys-only gate.
  event = "BufReadPre",

  -- Empty on purpose (LazyVim parity); presence is what triggers setup().
  opts = {},

  -- =============================================================================
  -- Keybindings
  -- =============================================================================
  -- stylua: ignore
  keys = {
    -- Restore the session for the current directory (and branch).
    { "<leader>qs", function() require("persistence").load() end, desc = "Restore Session" },
    -- Pick any saved session, from any directory; chdirs into it first.
    { "<leader>qS", function() require("persistence").select() end, desc = "Select Session" },
    -- Restore the most recently written session, whatever directory it was for.
    { "<leader>ql", function() require("persistence").load({ last = true }) end, desc = "Restore Last Session" },
    -- Disarm the save hook for THIS run only, so quitting leaves the session
    -- file as it was. Use it after opening a pile of unrelated files.
    { "<leader>qd", function() require("persistence").stop() end, desc = "Don't Save Current Session" },
  },
}
