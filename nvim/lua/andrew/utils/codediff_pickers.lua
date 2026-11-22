-- =============================================================================
-- CodeDiff pickers: a commit or a git worktree in the review tab
-- =============================================================================
-- `<leader>gv` reviews the uncommitted changes of the checkout being edited.
-- The two pickers here open the SAME view -- changed-files explorer on the
-- left, two-pane diff on the right -- on something else:
--
--   pick_commit()    a commit: the files that commit changed.
--   pick_worktree()  a git worktree: what that checkout holds and this one
--                    does not.
--
-- Both are fzf-lua's own pickers (`git_commits`, `git_worktrees`) with Enter
-- replaced, so the look, the preview and every other key in them are the
-- ones `<leader>gl` has. Enter there checks the commit out / changes
-- directory; here it runs `:CodeDiff` with the arguments built below. The
-- keys are in plugins/codediff.lua.
--
-- Pinned by tests/codediff_pickers_spec.lua.

local M = {}

--- The tree with no files in it, which git knows in every repository without
--- it being stored: what a commit with no parent is compared with.
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

--- What a git command printed, or nil and git's message when it failed.
--- `directory` goes through `git -C` rather than the process's working
--- directory: a directory that is gone is then git's error to report, where
--- `vim.system` raises on one.
---@param arguments string[] what follows `git`
---@param directory? string where to run it; the working directory when nil
---@return string? output
---@return string? error_message
local function git_output(arguments, directory)
  local command = { "git" }
  if directory then
    vim.list_extend(command, { "-C", directory })
  end
  local result = vim.system(vim.list_extend(command, arguments), { text = true }):wait()
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "")
  end
  return vim.trim(result.stdout or ""), nil
end

--- `:CodeDiff` arguments naming `repository`, so the review is of the
--- repository the picker listed whatever buffer is current by then.
---@param repository? string
---@return string[]
local function repository_arguments(repository)
  return repository and { "--repo", repository } or {}
end

--- The `:CodeDiff` arguments that show what `commit` changed: its first
--- parent against the commit itself. A commit without a parent is compared
--- with the empty tree, so every file it holds shows as added.
---@param commit string any revision naming one commit, e.g. the abbreviated hash of a picker row
---@param repository? string root of the checkout to look it up in; the working directory when nil
---@return string[]? arguments
---@return string? error_message git's, when `commit` names no commit
function M.commit_review_arguments(commit, repository)
  local commit_and_parents, error_message =
    git_output({ "rev-list", "--parents", "--max-count=1", commit }, repository)
  if not commit_and_parents then
    return nil, error_message
  end
  local hashes = vim.split(commit_and_parents, " ", { plain = true })
  return vim.list_extend(repository_arguments(repository), { hashes[2] or EMPTY_TREE, hashes[1] }),
    nil
end

--- The `:CodeDiff` arguments that review the checkout at `worktree` from the
--- one at `repository`.
---
--- The review starts at the commit the two checkouts last had in common, so
--- it holds the commits made in the worktree since AND its uncommitted
--- changes: everything an agent working there has done. A worktree with no
--- commit of its own (this checkout itself, or one that is behind it) is
--- reviewed as `<leader>gv` reviews this one, staged and unstaged apart.
--- Anything git cannot answer (a directory that is gone, a branch without
--- commits) also ends there, and CodeDiff reports it.
---@param worktree string root of the checkout to review
---@param repository? string root of the checkout the review is opened from; the working directory when nil
---@return string[] arguments
function M.worktree_review_arguments(worktree, repository)
  local arguments = { "--repo", worktree }
  local head_here = git_output({ "rev-parse", "--verify", "HEAD" }, repository)
  local head_there = git_output({ "rev-parse", "--verify", "HEAD" }, worktree)
  if not head_here or not head_there then
    return arguments
  end
  local last_common_commit = git_output({ "merge-base", head_here, head_there }, worktree)
  if last_common_commit and last_common_commit ~= head_there then
    arguments[#arguments + 1] = last_common_commit
  end
  return arguments
end

--- Open the review tab. The arguments go to the command as a list, so a path
--- with a space in it stays one argument.
---@param arguments string[]
local function open_review(arguments)
  vim.cmd({ cmd = "CodeDiff", args = arguments })
end

--- Pick a commit of the repository the current file is in; Enter reviews
--- what it changed.
function M.pick_commit()
  local repository = Snacks.git.get_root()
  require("fzf-lua").git_commits(require("andrew.utils.fzf_look").titled("Review a Commit", {
    cwd = repository,
    actions = {
      ---@param selected string[] the picked row; it starts with the abbreviated hash
      ["enter"] = function(selected)
        local commit = selected[1] and selected[1]:match("^%S+")
        if not commit then
          return
        end
        local arguments, error_message = M.commit_review_arguments(commit, repository)
        if not arguments then
          vim.notify("Review a Commit: " .. error_message, vim.log.levels.WARN)
          return
        end
        open_review(arguments)
      end,
    },
  }))
end

--- Pick one of the repository's git worktrees; Enter reviews it.
function M.pick_worktree()
  local repository = Snacks.git.get_root()
  require("fzf-lua").git_worktrees(require("andrew.utils.fzf_look").titled("Review a Worktree", {
    cwd = repository,
    actions = {
      -- The path is the row up to its first blank, as in fzf-lua's own
      -- actions of this picker and its preview: `git worktree list` pads the
      -- columns with spaces and quotes nothing, so a worktree whose path has
      -- a space in it cannot be told apart here or there.
      ---@param selected string[] the picked row of `git worktree list`
      ["enter"] = function(selected)
        local worktree = selected[1] and selected[1]:match("^%S+")
        if worktree then
          open_review(M.worktree_review_arguments(worktree, repository))
        end
      end,
    },
  }))
end

return M
