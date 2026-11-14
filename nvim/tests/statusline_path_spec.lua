-- Spec for the statusline's project name and file path:
--   * andrew.utils.root.project()   -- the project root, by markers alone
--   * andrew.utils.statusline_path  -- what lualine_c shows of it
--
-- WHAT THIS IS GUARDING
--
-- 1. The marker list. Besides the seven code-project markers it has to know a
--    notes vault: `.obsidian` (Obsidian) and `.zennotes` (ZenNotes). A vault
--    with neither `.git` nor `lua` would otherwise have no root at all.
-- 2. NEAREST marker wins. A package inside a git repository is its own
--    project; returning the outermost marker names every file after the repo.
-- 3. A file that is not on disk yet. Its path cannot be resolved, and falling
--    back to the working directory names a new file after the wrong project.
-- 4. The project name is shown only while the root is NOT the working
--    directory -- in each of the three ways that can be: the root above the
--    cwd, below it, and beside it.
-- 5. The path's base. Relative to the cwd when the file is under it; relative
--    to the project root when it is not, never the bare absolute path.
--
-- Real directories under a temp dir, real :cd, real buffers.
--
-- Run with: nvim --headless -u NONE -l tests/statusline_path_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq = _H.test, _H.assert_eq

package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local root = require("andrew.utils.root")
local statusline_path = require("andrew.utils.statusline_path")

-- Resolved, because /tmp is a symlink on some systems and every path the
-- modules return is.
local sandbox = vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h")) .. "/statusline_path_spec"
vim.fn.delete(sandbox, "rf")

--- Create `relative_path` under the sandbox; a trailing slash makes a directory.
local function make(relative_path)
  local path = sandbox .. "/" .. relative_path
  if relative_path:sub(-1) == "/" then
    vim.fn.mkdir(path, "p")
  else
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "content" }, path)
  end
  return (path:gsub("/$", ""))
end

make("repo/.git/")
make("repo/top.txt")
make("repo/src/main.lua")
make("repo/packages/web/package.json")
make("repo/packages/web/src/index.js")
make("obsidian/.obsidian/")
make("obsidian/Notes/idea.md")
make("zennotes/.zennotes/")
make("zennotes/Notes/idea.md")
make("elsewhere/")

--- Edit `relative_path` with the working directory at `working_directory`
--- (both relative to the sandbox).
local function open(relative_path, working_directory)
  vim.cmd("silent! %bwipeout!")
  root.project_cache = {}
  vim.cmd.cd(vim.fn.fnameescape(sandbox .. "/" .. working_directory))
  vim.cmd.edit(vim.fn.fnameescape(sandbox .. "/" .. relative_path))
end

local function shown_path()
  local directory, filename = statusline_path.display_parts()
  return directory .. filename
end

test("the nearest marker is the project root", function()
  open("repo/src/main.lua", "repo")
  assert_eq(root.project(), sandbox .. "/repo", "a file in the repository:")

  open("repo/packages/web/src/index.js", "repo")
  assert_eq(root.project(), sandbox .. "/repo/packages/web", "a file in a package inside it:")
end)

test("Obsidian and ZenNotes vaults are projects", function()
  open("obsidian/Notes/idea.md", "elsewhere")
  assert_eq(root.project(), sandbox .. "/obsidian", "a note in an Obsidian vault:")

  open("zennotes/Notes/idea.md", "elsewhere")
  assert_eq(root.project(), sandbox .. "/zennotes", "a note in a ZenNotes vault:")
end)

test("a file not written yet belongs to the project of its directory", function()
  open("repo/src/not_on_disk.lua", "elsewhere")
  assert_eq(root.project(), sandbox .. "/repo", "project root:")
  assert_eq(shown_path(), "src/not_on_disk.lua", "path shown:")
end)

test("without a marker the project root is the working directory, and follows :cd", function()
  -- A marker list of our own: the real one could match something above the
  -- temp directory on the machine running this.
  local real_markers = root.project_markers
  root.project_markers = { ".statusline-path-spec-marker" }

  open("repo/top.txt", "elsewhere")
  assert_eq(root.project(), sandbox .. "/elsewhere", "before :cd:")
  vim.cmd.cd(vim.fn.fnameescape(sandbox .. "/obsidian"))
  assert_eq(root.project(), sandbox .. "/obsidian", "after :cd:")

  root.project_markers = real_markers
end)

test("the project name is hidden while the root is the working directory", function()
  open("repo/src/main.lua", "repo")
  assert_eq(statusline_path.root_name_unless_cwd(), nil, "root is the cwd:")
end)

test("the project name is shown whenever the root is not the working directory", function()
  open("repo/src/main.lua", "repo/src")
  assert_eq(statusline_path.root_name_unless_cwd(), "repo", "cwd below the root:")

  open("repo/src/main.lua", "")
  assert_eq(statusline_path.root_name_unless_cwd(), "repo", "cwd above the root:")

  open("repo/src/main.lua", "elsewhere")
  assert_eq(statusline_path.root_name_unless_cwd(), "repo", "cwd beside the root:")
end)

test("the path is relative to the working directory when the file is under it", function()
  open("repo/src/main.lua", "repo")
  assert_eq(shown_path(), "src/main.lua", "cwd is the root:")

  open("repo/src/main.lua", "repo/src")
  assert_eq(shown_path(), "main.lua", "cwd below the root:")

  open("repo/src/main.lua", "")
  assert_eq(shown_path(), "repo/src/main.lua", "cwd above the root:")
end)

test("the path is relative to the project root when the file is outside the working directory", function()
  open("repo/packages/web/src/index.js", "elsewhere")
  assert_eq(shown_path(), "src/index.js", "path shown:")
  assert_eq(statusline_path.root_name_unless_cwd(), "web", "beside the project name:")
end)

test("the file name is split from its directory", function()
  open("repo/src/main.lua", "repo")
  local directory, filename = statusline_path.display_parts()
  assert_eq(directory, "src/", "directory part:")
  assert_eq(filename, "main.lua", "file part:")

  open("repo/top.txt", "repo")
  directory, filename = statusline_path.display_parts()
  assert_eq(directory, "", "directory part of a file in the cwd:")
  assert_eq(filename, "top.txt", "its file part:")
end)

test("buffers that are not files are named whole", function()
  vim.cmd("silent! %bwipeout!")
  local directory, filename = statusline_path.display_parts()
  assert_eq(directory .. "|" .. filename, "|[No Name]", "unnamed buffer:")

  vim.api.nvim_buf_set_name(0, "scheme://host/some/thing")
  directory, filename = statusline_path.display_parts()
  assert_eq(directory .. "|" .. filename, "|scheme://host/some/thing", "a plugin's URI buffer:")
end)

vim.cmd("silent! %bwipeout!")
vim.cmd.cd(vim.fn.fnameescape(vim.fn.stdpath("config")))
vim.fn.delete(sandbox, "rf")
_H.finish()
