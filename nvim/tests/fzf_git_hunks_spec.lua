-- Spec for andrew/utils/fzf_git_hunks.lua, the row parser behind fzf-lua's
-- `git_hunks` picker (<leader>gd).
--
-- WHAT THIS PROTECTS. The parser it replaces, fzf-lua's make_entry.git_hunk,
-- reads the line number out of a hunk header with a pattern that requires
-- `@@ -a,b +c,d @@`. git omits a count of 1, so `@@ -1 +1,2 @@` yields nil,
-- the next line adds 1 to it, and the error leaves the picker EMPTY -- every
-- file's rows gone because one short file was among the changes.
--
-- Feeds real `git diff` text through to_entry() line by line, exactly as the
-- picker does. Only fzf-lua's file-column formatter is stubbed (identity), so
-- the rows read `path:line:text`.
--
-- Discriminating power:
--   * Requiring the counts again -> the short-header tests raise.
--   * Counting `-` lines as new-file lines -> the numbering test fails.
--   * Keeping the tab git appends to a path with a space -> the path test fails.
--   * Carrying one file's name or line into the next -> the two-file test fails.
--   * Reading `+++ /dev/null` as a path, or nothing at all -> the deleted-file
--     test fails.
--
-- Run with: nvim --headless -u NONE -l tests/fzf_git_hunks_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq = _H.test, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path
package.loaded["fzf-lua.make_entry"] = {
  file = function(path)
    return path
  end,
}

local hunks = require("andrew.utils.fzf_git_hunks")

--- Rows for a whole diff, as one picker would produce them.
local function rows_of(diff_text)
  local picker_opts, rows = {}, {}
  for _, diff_line in ipairs(vim.split(diff_text, "\n")) do
    rows[#rows + 1] = hunks.to_entry(diff_line, picker_opts)
  end
  return rows
end

test("a hunk header without a count still gives its rows a line number", function()
  -- THE REGRESSION: a change at the top of a one-line file.
  local rows = rows_of(table.concat({
    "diff --git a/short.txt b/short.txt",
    "index 7898192..422c2b7 100644",
    "--- a/short.txt",
    "+++ b/short.txt",
    "@@ -1 +1,2 @@",
    " a",
    "+b",
  }, "\n"))
  assert_eq(#rows, 1, "one changed line, one row")
  assert_eq(rows[1], "short.txt:2:+b", "the added line is line 2 of the new file")
end)

test("a new one-line file is listed at line 1", function()
  local rows = rows_of(table.concat({
    "diff --git a/new.txt b/new.txt",
    "new file mode 100644",
    "index 0000000..3e75765",
    "--- /dev/null",
    "+++ b/new.txt",
    "@@ -0,0 +1 @@",
    "+new",
  }, "\n"))
  assert_eq(rows[1], "new.txt:1:+new", "header `+1` has no count either")
end)

test("context and added lines advance the number, removed lines do not", function()
  local rows = rows_of(table.concat({
    "diff --git a/mod.lua b/mod.lua",
    "index 1111111..2222222 100644",
    "--- a/mod.lua",
    "+++ b/mod.lua",
    "@@ -10,5 +10,5 @@ function M.alpha()",
    " context",
    "-old one",
    "-old two",
    "+new one",
    "+new two",
    " context",
  }, "\n"))
  assert_eq(#rows, 4, "two removed and two added lines")
  -- Removed lines sit where their replacement starts.
  assert_eq(rows[1], "mod.lua:11:-old one", "first removed line")
  assert_eq(rows[2], "mod.lua:11:-old two", "second removed line stays put")
  assert_eq(rows[3], "mod.lua:11:+new one", "first added line")
  assert_eq(rows[4], "mod.lua:12:+new two", "second added line")
end)

test("a path with a space loses the tab git appends to it", function()
  local rows = rows_of(table.concat({
    "diff --git a/my notes/plain name.txt b/my notes/plain name.txt",
    "index 7898192..422c2b7 100644",
    "--- a/my notes/plain name.txt\t",
    "+++ b/my notes/plain name.txt\t",
    "@@ -1,3 +1,4 @@",
    " one",
    "+two",
  }, "\n"))
  assert_eq(rows[1], "my notes/plain name.txt:2:+two", "path must not end in a tab")
end)

test("a second file starts over with its own name and numbering", function()
  local rows = rows_of(table.concat({
    "diff --git a/first.txt b/first.txt",
    "index 1111111..2222222 100644",
    "--- a/first.txt",
    "+++ b/first.txt",
    "@@ -40,2 +40,3 @@",
    " keep",
    "+added in first",
    "diff --git a/second.txt b/second.txt",
    "index 3333333..4444444 100644",
    "--- a/second.txt",
    "+++ b/second.txt",
    "@@ -1 +1 @@",
    "-was",
    "+is",
  }, "\n"))
  assert_eq(rows[1], "first.txt:41:+added in first", "first file")
  -- The second file's `---` / `+++` lines must not be read as changes of
  -- the first, nor its rows numbered from where the first left off.
  assert_eq(#rows, 3, "header lines of the second file are not rows")
  assert_eq(rows[2], "second.txt:1:-was", "second file, removed line")
  assert_eq(rows[3], "second.txt:1:+is", "second file, added line")
end)

test("a deleted file's lines are listed under its old name", function()
  local rows = rows_of(table.concat({
    "diff --git a/gone.txt b/gone.txt",
    "deleted file mode 100644",
    "index 3e75765..0000000",
    "--- a/gone.txt",
    "+++ /dev/null",
    "@@ -1,2 +0,0 @@",
    "-first",
    "-second",
  }, "\n"))
  assert_eq(#rows, 2, "both removed lines are rows")
  assert_eq(rows[1], "gone.txt:1:-first", "old name, and never line 0")
end)

test("colours are ignored for parsing and kept in the row", function()
  local green, cyan, reset = "\27[32m", "\27[36m", "\27[m"
  local rows = rows_of(table.concat({
    "\27[1mdiff --git a/c.txt b/c.txt" .. reset,
    "\27[1mindex 1111111..2222222 100644" .. reset,
    "\27[1m--- a/c.txt" .. reset,
    "\27[1m+++ b/c.txt" .. reset,
    cyan .. "@@ -1 +1,2 @@" .. reset,
    " a",
    green .. "+b" .. reset,
  }, "\n"))
  assert_eq(rows[1], "c.txt:2:" .. green .. "+b" .. reset, "git's colouring reaches the picker")
end)

_H.finish({ style = "results", exit = "os" })
