-- =============================================================================
-- Git Commands (<leader>g)
-- =============================================================================
-- LazyVim's `<leader>g` git group, ported wholesale. Every key here is a direct
-- snacks.nvim call, so nothing depends on LazyVim's util module -- the one
-- exception is LazyVim's `LazyVim.root.git()`, replaced by `Snacks.git.get_root()`.
--
-- This is a SPEC FRAGMENT for folke/snacks.nvim, not a second copy of the
-- plugin. lazy.nvim merges fragments that name the same repo, so these `keys`
-- are appended to the spec in plugins/snacks.lua, which owns `opts`/`config`.
-- Keeping them here rather than in snacks.lua is purely for discoverability.
--
-- Snacks submodules load on first access via a metatable (`snacks/init.lua`),
-- so `lazygit`, `gitbrowse` and `picker` all work WITHOUT being listed in
-- snacks.lua's `opts`. `opts.<mod>.enabled` only controls startup autocmd
-- integration, never direct invocation.
--
-- Hunk keymaps are NOT here -- they are buffer-local and live under
-- <leader>gh in plugins/gitsigns.lua.
--
-- =============================================================================
-- Deviations from LazyVim, and why
-- =============================================================================
--   * `<leader>gg` / `<leader>gG` (lazygit) are gated on `executable("lazygit")`,
--     exactly as LazyVim gates them: the keys are registered only when the
--     binary is present on the machine running this config.
--
--   * `<leader>gi` `<leader>gI` `<leader>gp` `<leader>gP` (GitHub issues and
--     PRs) are gated on `executable("gh")`, which LazyVim does NOT do. Snacks'
--     gh_issue/gh_pr finders shell out to `gh`; without it the keys would be
--     dead and would still clutter which-key.
--
--     Both gates are evaluated at startup, so whether any of these six keys
--     exists depends on what is installed on the current machine -- do not
--     assume either binary is (or is not) there. `:checkhealth` /
--     `:verbose map <leader>gg` will say which ones were registered.
--
--   * `<leader>gc` comes from LazyVim's `editor.fzf` extra rather than its
--     default `editor.snacks_picker` extra, which has no commits key. fzf-lua
--     is installed here, and it is a genuinely different UI from `<leader>gl`.
--
--   * `<leader>go` (mini.diff overlay) IS ported, but lives in
--     plugins/mini-diff.lua next to the rest of that plugin's setup. Note
--     LazyVim's mini-diff extra DISABLES gitsigns outright; this config runs
--     both side by side instead.
--
-- NOT ported, because the plugin each one needs is not installed:
--   `<leader>ge` Git Explorer (neo-tree extra) and `<leader>gr` List Repos
--   (octo extra). LazyVim's `<leader>G` GitHub group (util.gh extra) is a
--   separate prefix and also needs the `gh` binary.

local has_lazygit = vim.fn.executable("lazygit") == 1
local has_gh = vim.fn.executable("gh") == 1

--- Call Snacks.gitbrowse, swallowing ONLY its `__ignore__` abort sentinel.
--- Every other error is re-raised unchanged.
local function gitbrowse_guarded(opts)
  local ok, err = pcall(Snacks.gitbrowse, opts)
  if ok then
    return
  end
  if type(err) == "string" and err:find("__ignore__", 1, true) then
    return -- snacks already notified the user; the rethrow is upstream noise
  end
  error(err, 0)
end

-- stylua: ignore
local keys = {
  -- ---------------------------------------------------------------------------
  -- Log / history / blame
  -- ---------------------------------------------------------------------------
  { "<leader>gl", function() Snacks.picker.git_log({ cwd = Snacks.git.get_root() }) end, desc = "Git Log" },
  { "<leader>gL", function() Snacks.picker.git_log() end, desc = "Git Log (cwd)" },
  { "<leader>gc", "<cmd>FzfLua git_commits<CR>", desc = "Commits (fzf-lua)" },
  { "<leader>gf", function() Snacks.picker.git_log_file() end, desc = "Git Current File History" },
  { "<leader>gb", function() Snacks.picker.git_log_line() end, desc = "Git Blame Line" },

  -- ---------------------------------------------------------------------------
  -- Status / diff / stash
  -- ---------------------------------------------------------------------------
  { "<leader>gs", function() Snacks.picker.git_status() end, desc = "Git Status" },
  { "<leader>gS", function() Snacks.picker.git_stash() end, desc = "Git Stash" },
  { "<leader>gd", function() Snacks.picker.git_diff() end, desc = "Git Diff (hunks)" },
  { "<leader>gD", function() Snacks.picker.git_diff({ base = "origin", group = true }) end, desc = "Git Diff (origin)" },

  -- ---------------------------------------------------------------------------
  -- Browse the remote (reads `git remote`; does NOT need the gh binary)
  -- ---------------------------------------------------------------------------
  -- pcall: snacks' gitbrowse aborts its failure paths with `error("__ignore__")`,
  -- but Lua prefixes the source position, so gitbrowse's own `err ~= "__ignore__"`
  -- filter never matches and the sentinel is re-raised as a raw E5108 traceback
  -- (e.g. on a file outside any git repo). snacks has already shown a friendly
  -- notify by then, so swallowing ONLY that sentinel loses nothing; any other
  -- error is re-raised so real bugs stay visible.
  { "<leader>gB", mode = { "n", "x" }, function() gitbrowse_guarded() end, desc = "Git Browse (open)" },
  {
    "<leader>gY",
    mode = { "n", "x" },
    function()
      -- See the note on <leader>gB. With notify = false the rethrown sentinel
      -- would be the ONLY thing the user sees, so the guard matters more here.
      gitbrowse_guarded({ open = function(url) vim.fn.setreg("+", url) end, notify = false })
    end,
    desc = "Git Browse (copy)",
  },
}

if has_lazygit then
  -- stylua: ignore start
  table.insert(keys, { "<leader>gg", function() Snacks.lazygit({ cwd = Snacks.git.get_root() }) end, desc = "Lazygit (Root Dir)" })
  table.insert(keys, { "<leader>gG", function() Snacks.lazygit() end, desc = "Lazygit (cwd)" })
  -- stylua: ignore end
end

if has_gh then
  -- stylua: ignore start
  table.insert(keys, { "<leader>gi", function() Snacks.picker.gh_issue() end, desc = "GitHub Issues (open)" })
  table.insert(keys, { "<leader>gI", function() Snacks.picker.gh_issue({ state = "all" }) end, desc = "GitHub Issues (all)" })
  table.insert(keys, { "<leader>gp", function() Snacks.picker.gh_pr() end, desc = "GitHub Pull Requests (open)" })
  table.insert(keys, { "<leader>gP", function() Snacks.picker.gh_pr({ state = "all" }) end, desc = "GitHub Pull Requests (all)" })
  -- stylua: ignore end
end

return {
  -- Plugin: snacks.nvim - spec fragment supplying the <leader>g git keymaps
  -- Repository: https://github.com/folke/snacks.nvim
  "folke/snacks.nvim",
  keys = keys,
}
