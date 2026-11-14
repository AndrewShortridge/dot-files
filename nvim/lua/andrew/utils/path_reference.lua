-- =============================================================================
-- Path references: copy "which file" or "which lines" for an agent prompt
-- =============================================================================
-- From Normal mode the current file's path is copied on its own. From Visual
-- mode the selected lines are added as a range, `path#L10-L24` (the form
-- GitHub uses in its URLs): a reference a coding agent can open at the right
-- place without the text being pasted in. The range is by line whatever the
-- kind of selection; a selection within one line is `#L10`.
--
-- After craftzdog's dotfiles (yank_relative_path_with_line /
-- yank_absolute_path_with_line in lua/craftzdog/utils/editor.lua). His work
-- from Normal mode only and always append the cursor line, `path#L12`; here a
-- line number means "these lines were selected" and nothing else.
--
-- Also unlike his, a buffer that is not a file is refused with a warning. His
-- copies a bare `#L12` for an unnamed buffer.

local M = {}

local VISUAL_MODES = { v = true, V = true, ["\22"] = true }
local NOT_A_FILE_BUFFER_TYPES = { nofile = true, prompt = true, quickfix = true, terminal = true }

--- The `#L…` suffix for the active Visual selection, or "" when there is none.
---@return string
local function selected_lines_suffix()
  if not VISUAL_MODES[vim.fn.mode()] then
    return ""
  end
  -- "v" is the end of the selection the cursor is NOT on (:help line()).
  local cursor_line, other_end_line = vim.fn.line("."), vim.fn.line("v")
  local first_line = math.min(cursor_line, other_end_line)
  local last_line = math.max(cursor_line, other_end_line)
  return first_line == last_line and ("#L" .. first_line)
    or ("#L" .. first_line .. "-L" .. last_line)
end

--- The reference for the current buffer, or nil when it is not a file.
---@param path_modifier ":."|":p" relative to the working directory, or absolute
---@return string?
function M.build(path_modifier)
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or NOT_A_FILE_BUFFER_TYPES[vim.bo.buftype] then
    return nil
  end

  -- ":." leaves a file outside the working directory absolute, which is the
  -- only form that still finds it.
  return vim.fn.fnamemodify(name, path_modifier) .. selected_lines_suffix()
end

--- Copy the reference to the system clipboard and say what was copied. Leaves
--- Visual mode, as a yank does.
---@param path_modifier ":."|":p"
function M.yank(path_modifier)
  local reference = M.build(path_modifier)
  if VISUAL_MODES[vim.fn.mode()] then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  if not reference then
    vim.notify("No path to yank: this buffer is not a file", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", reference)
  vim.notify("Yanked: " .. reference, vim.log.levels.INFO)
end

return M
