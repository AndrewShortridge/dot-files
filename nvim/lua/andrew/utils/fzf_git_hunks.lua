-- =============================================================================
-- fzf-lua Git Hunks: turning `git diff` output into picker rows
-- =============================================================================
-- Replaces the row parser of fzf-lua's `git_hunks` picker (`<leader>gd`), which
-- the picker feeds one line of `git diff` at a time and which answers with a
-- `file:line:text` row for every added or removed line.
--
-- fzf-lua's own (make_entry.git_hunk, as of ded1c96) reads the new-file line
-- number with a pattern that insists on `@@ -a,b +c,d @@`. git leaves the
-- count off when it is 1 -- `@@ -1 +1,2 @@`, `@@ -0,0 +1 @@` -- which is every
-- change at the top of a short file and every new one-line file. On such a
-- header the number comes back nil, the next line does arithmetic on it, and
-- the error empties the WHOLE picker, not just that file's rows.
--
-- Wired up in plugins/fzf-lua.lua (`git.hunks.fn_transform`). It runs inside
-- Neovim rather than in fzf-lua's headless helper process, which does not have
-- this config on its runtimepath.

local M = {}

--- Parser state for one picker, keyed by its options table: a diff is one
--- stream of calls, and fzf-lua hands the same table to each of them.
---@type table<table, { file: string?, old_file: string?, line: integer? }>
local state_by_picker = setmetatable({}, { __mode = "k" })

--- Path from a `--- a/path` / `+++ b/path` header line. The prefix letter
--- varies (`a`/`b`, or `i`/`w`/`c` with diff.mnemonicPrefix), and git ends
--- the line with a tab when the path contains a space.
---@param header_line string
---@param marker string the three-character marker, as a Lua pattern
---@return string?
local function header_path(header_line, marker)
  return header_line:match("^" .. marker .. " %l/(.-)\t?$")
end

--- One line of `git diff` in, one picker row out (or nil for a line that is
--- not a change).
---@param diff_line string as git printed it, colours included
---@param picker_opts table the picker's options
---@return string?
function M.to_entry(diff_line, picker_opts)
  local state = state_by_picker[picker_opts]
  if not state then
    state = {}
    state_by_picker[picker_opts] = state
  end

  local text = diff_line:gsub("\27%[[%d;]*m", "")
  local marker = text:sub(1, 1)

  if text:find("^diff ") then
    state.file, state.old_file, state.line = nil, nil, nil
    return nil
  end

  if marker == "@" then
    -- The count after either start line is optional. A combined (merge) diff
    -- header, `@@@ ... @@@`, does not match and leaves the file skipped.
    state.line = tonumber(text:match("^@@ %-%d+,?%d* %+(%d+)"))
    return nil
  end

  if not state.line then
    -- Still in the file header. These two lines also start with - and +.
    state.old_file = header_path(text, "%-%-%-") or state.old_file
    state.file = header_path(text, "%+%+%+") or state.file
    return nil
  end

  local entry
  if marker == "+" or marker == "-" then
    -- A deleted file has `+++ /dev/null`; its rows go under the old name.
    local file = state.file or state.old_file
    local file_column = file and require("fzf-lua.make_entry").file(file, picker_opts)
    if file_column then
      entry = ("%s:%d:%s"):format(file_column, math.max(state.line, 1), diff_line)
    end
  end
  if marker == " " or marker == "+" then
    state.line = state.line + 1
  end
  return entry
end

return M
