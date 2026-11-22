-- Spec for andrew.utils.codediff_pickers: the `:CodeDiff` arguments behind
-- `<leader>gV` (review a picked commit) and `<leader>gw` (review a picked git
-- worktree).
--
-- WHAT THIS IS GUARDING
--
-- 1. A commit is reviewed against its parent, both as full hashes, in the
--    repository the picker listed.
-- 2. A commit WITHOUT a parent has no `<commit>~1` to compare with. It is
--    compared with git's empty tree, which shows its files as added; asking
--    for the parent would open nothing but an error.
-- 3. A worktree with commits of its own is reviewed from the commit it last
--    had in common with the checkout the review is opened from, so its
--    commits and its uncommitted changes are one changeset.
-- 4. A worktree with no commit of its own -- this checkout, one at the same
--    commit, one that is behind -- gets NO revision. With one, CodeDiff
--    leaves its status view (staged and unstaged apart), and for a worktree
--    that is behind the revision would list this checkout's newer commits as
--    if the worktree had undone them.
-- 5. A worktree whose directory is gone does not raise.
--
-- The repositories are real ones, made in a temporary directory: what is
-- pinned is what git answers, not how the module asks.
--
-- Run with: nvim --headless -u NONE -l tests/codediff_pickers_spec.lua

---@type SpecHelper
local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_deep_eq, assert_nil, assert_true =
  _H.test, _H.assert_eq, _H.assert_deep_eq, _H.assert_nil, _H.assert_true

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local codediff_pickers = require("andrew.utils.codediff_pickers")

local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

--- Run git for the fixture, untouched by the user's own git configuration.
--- Raises with git's message when the command fails.
---@param directory string
---@param arguments string[] what follows `git`
---@return string output
local function git(directory, arguments)
  local command = {
    "git",
    "-C",
    directory,
    "-c",
    "user.name=Spec",
    "-c",
    "user.email=spec@example.invalid",
    "-c",
    "commit.gpgsign=false",
  }
  local result = vim
    .system(vim.list_extend(command, arguments), {
      text = true,
      env = { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_SYSTEM = "/dev/null" },
    })
    :wait()
  assert(result.code == 0, "git " .. table.concat(arguments, " ") .. ": " .. (result.stderr or ""))
  return vim.trim(result.stdout or "")
end

--- Commit a new file in the checkout at `directory`.
---@param directory string
---@param file_name string
---@return string commit its full hash
local function commit_file(directory, file_name)
  vim.fn.writefile({ file_name }, directory .. "/" .. file_name)
  git(directory, { "add", file_name })
  git(directory, { "commit", "--quiet", "-m", "add " .. file_name })
  return git(directory, { "rev-parse", "HEAD" })
end

-- One repository, `first` then `second` on its branch, and four linked
-- worktrees named after where they stand relative to `second`.
local fixture_root = vim.fn.tempname()
vim.fn.mkdir(fixture_root, "p")
local checkout = fixture_root .. "/checkout"
git(fixture_root, { "init", "--quiet", "--initial-branch=trunk", checkout })
local first = commit_file(checkout, "first.txt")
local second = commit_file(checkout, "second.txt")

local worktree_ahead = fixture_root .. "/ahead"
git(checkout, { "worktree", "add", "--quiet", "-b", "ahead", worktree_ahead })
commit_file(worktree_ahead, "ahead.txt")

local worktree_level = fixture_root .. "/level"
git(checkout, { "worktree", "add", "--quiet", "-b", "level", worktree_level })

local worktree_behind = fixture_root .. "/behind"
git(checkout, { "worktree", "add", "--quiet", "--detach", worktree_behind, first })

local worktree_diverged = fixture_root .. "/diverged"
git(checkout, { "worktree", "add", "--quiet", "-b", "diverged", worktree_diverged, first })
commit_file(worktree_diverged, "diverged.txt")

test("a commit is reviewed against its parent, both as full hashes", function()
  local arguments, error_message =
    codediff_pickers.commit_review_arguments(second:sub(1, 7), checkout)
  assert_nil(error_message, "error message:")
  assert_deep_eq(
    arguments,
    { "--repo", checkout, first, second },
    "arguments for the abbreviated hash:"
  )
end)

test("a commit without a parent is reviewed against the empty tree", function()
  local arguments = codediff_pickers.commit_review_arguments(first, checkout)
  assert_deep_eq(arguments, { "--repo", checkout, EMPTY_TREE, first }, "arguments:")
  -- The empty tree was never stored in this repository; git must still
  -- compare with it, or the review of a first commit opens on an error.
  assert_eq(
    git(checkout, { "diff", "--name-status", EMPTY_TREE, first }),
    "A\tfirst.txt",
    "what git lists between them:"
  )
end)

test("a revision that names no commit gives git's message and no arguments", function()
  local arguments, error_message = codediff_pickers.commit_review_arguments("0000000", checkout)
  assert_nil(arguments, "arguments:")
  assert_true(type(error_message) == "string" and error_message ~= "", "git's message is passed on")
end)

test("a worktree that is ahead is reviewed from the commit it started at", function()
  assert_deep_eq(
    codediff_pickers.worktree_review_arguments(worktree_ahead, checkout),
    { "--repo", worktree_ahead, second },
    "arguments:"
  )
end)

test("a worktree that diverged is reviewed from the last commit in common", function()
  assert_deep_eq(
    codediff_pickers.worktree_review_arguments(worktree_diverged, checkout),
    { "--repo", worktree_diverged, first },
    "arguments:"
  )
end)

test("a worktree with no commit of its own is reviewed without a revision", function()
  assert_deep_eq(
    codediff_pickers.worktree_review_arguments(checkout, checkout),
    { "--repo", checkout },
    "the checkout itself:"
  )
  assert_deep_eq(
    codediff_pickers.worktree_review_arguments(worktree_level, checkout),
    { "--repo", worktree_level },
    "a worktree at the same commit:"
  )
  assert_deep_eq(
    codediff_pickers.worktree_review_arguments(worktree_behind, checkout),
    { "--repo", worktree_behind },
    "a worktree that is behind:"
  )
end)

test("a worktree whose directory is gone does not raise", function()
  local missing_worktree = fixture_root .. "/gone"
  assert_deep_eq(
    codediff_pickers.worktree_review_arguments(missing_worktree, checkout),
    { "--repo", missing_worktree },
    "arguments:"
  )
end)

vim.fn.delete(fixture_root, "rf")

_H.finish()
