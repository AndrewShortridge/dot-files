-- =============================================================================
-- Git Commands (<leader>g)
-- =============================================================================
-- LazyVim's `<leader>g` git group, ported key for key. LazyVim opens each of
-- these lists in a snacks picker; here they are fzf-lua pickers, so they share
-- the one look every other fzf-lua picker has (andrew/utils/fzf_look.lua) and
-- preview through git-delta. Lazygit, git browse and the GitHub keys are still
-- direct snacks.nvim calls, which is why this stays a snacks fragment. Nothing
-- depends on LazyVim's util module: `LazyVim.root.git()` is replaced by
-- `Snacks.git.get_root()`.
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
-- Lazygit is the exception on both counts: it goes through
-- andrew/utils/lazygit.lua rather than `Snacks.lazygit()` directly, because
-- that wrapper records the launch window that `e` inside lazygit edits in, and
-- its edit command IS set in snacks.lua's `opts.lazygit`.
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
--     dead and would still clutter which-key. The gate only checks that a
--     `gh` exists: the issue pickers also need one recent enough to know the
--     `stateReason` JSON field. Ubuntu's 2.45.0 is not ("Unknown JSON field",
--     empty picker); conda-forge's 2.104.0 is, and init.lua's PATH puts it
--     ahead of /usr/bin/gh.
--
--     Both gates are evaluated at startup, so whether any of these six keys
--     exists depends on what is installed on the current machine -- do not
--     assume either binary is (or is not) there. `:checkhealth` /
--     `:verbose map <leader>gg` will say which ones were registered.
--
--   * `<leader>gc` comes from LazyVim's `editor.fzf` extra rather than its
--     default `editor.snacks_picker` extra, which has no commits key. Now that
--     `<leader>gL` is fzf-lua too, the two open the same picker.
--
--   * Inside the pickers the keys are fzf-lua's, not snacks': in git status
--     `<left>` / `<right>` stage / unstage and `<C-x>` resets (snacks had
--     `<Tab>` and `<C-r>`); Enter on a file-history or line-history commit
--     opens the file as of that commit instead of checking the commit out.
--
--   * `<leader>go` (mini.diff overlay) IS ported, but lives in
--     plugins/mini-diff.lua next to the rest of that plugin's setup. Note
--     LazyVim's mini-diff extra DISABLES gitsigns outright; this config runs
--     both side by side instead.
--
--   * `<leader>gv` `<leader>gV` `<leader>gw` `<leader>gt` `<leader>gT`
--     (codediff.nvim review tab, its commit and worktree pickers, history)
--     are not LazyVim keys and live in plugins/codediff.lua, whose lazy.nvim
--     `keys` load that plugin on first press.
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
  local ok, err = pcall(Snacks.gitbrowse --[[@as function]], opts)
  if ok then
    return
  end
  if type(err) == "string" and err:find("__ignore__", 1, true) then
    return -- snacks already notified the user; the rethrow is upstream noise
  end
  error(err, 0)
end

--- `<leader>gb`: the commits that changed the line under the cursor.
--- fzf-lua has no picker of its own for this -- its git_blame annotates the
--- whole file -- but git_bcommits runs exactly this `git log -L` for a VISUAL
--- selection, so it is handed the same command for the cursor line. The line
--- number is the one in the committed file, as `git log -L` reads HEAD.
local function line_history()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  require("fzf-lua").git_bcommits(require("andrew.utils.fzf_look").titled("Git Line History", {
    cmd = (
      [[git log --color --pretty=format:"%%C(yellow)%%h%%Creset ]]
      .. [[%%Cgreen(%%><(12)%%cr%%><|(12))%%Creset %%s %%C(blue)<%%an>%%Creset" -L %d,+1:{file} --no-patch]]
    ):format(cursor_line),
  }))
end

--- `<leader>gD`: the files this checkout changed relative to `origin`.
--- Compared against the commit the branch forked from rather than origin's
--- tip, so commits that landed upstream since do not show up as reversed
--- changes (what `git diff --merge-base origin` does). The fork point is
--- looked up here and passed as an ordinary `ref`, which keeps the picker's
--- own commands -- and the hunks picker it opens on <A-d> -- working.
local function diff_against_origin()
  local merge_base = vim.system({ "git", "merge-base", "origin", "HEAD" }, { text = true }):wait()
  if merge_base.code ~= 0 then
    vim.notify("Git Diff (origin): " .. vim.trim(merge_base.stderr), vim.log.levels.WARN)
    return
  end
  require("fzf-lua").git_diff(require("andrew.utils.fzf_look").titled("Git Diff (origin)", {
    ref = vim.trim(merge_base.stdout),
  }))
end

-- stylua: ignore
local keys = {
  -- ---------------------------------------------------------------------------
  -- Log / history / blame
  -- ---------------------------------------------------------------------------
  { "<leader>gl", function() require("fzf-lua").git_commits({ cwd = Snacks.git.get_root() }) end, desc = "Git Log" },
  { "<leader>gL", "<cmd>FzfLua git_commits<CR>", desc = "Git Log (cwd)" },
  { "<leader>gc", "<cmd>FzfLua git_commits<CR>", desc = "Commits (fzf-lua)" },
  { "<leader>gf", function() require("fzf-lua").git_bcommits({ follow = true }) end, desc = "Git Current File History" },
  { "<leader>gb", line_history, desc = "Git Blame Line" },

  -- ---------------------------------------------------------------------------
  -- Status / diff / stash
  -- ---------------------------------------------------------------------------
  { "<leader>gs", "<cmd>FzfLua git_status<CR>", desc = "Git Status" },
  { "<leader>gS", "<cmd>FzfLua git_stash<CR>", desc = "Git Stash" },
  -- `ref = "HEAD"`: every uncommitted hunk, staged or not. Left to itself
  -- fzf-lua shows the LAST COMMIT's hunks when the tree is clean.
  { "<leader>gd", function() require("fzf-lua").git_hunks({ ref = "HEAD" }) end, desc = "Git Diff (hunks)" },
  { "<leader>gD", diff_against_origin, desc = "Git Diff (origin)" },

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
  table.insert(keys, { "<leader>gg", function() require("andrew.utils.lazygit").open({ cwd = Snacks.git.get_root() }) end, desc = "Lazygit (Root Dir)" })
  table.insert(keys, { "<leader>gG", function() require("andrew.utils.lazygit").open() end, desc = "Lazygit (cwd)" })
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
