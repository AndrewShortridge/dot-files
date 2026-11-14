-- =============================================================================
-- Statusline: project name and pretty file path
-- =============================================================================
-- Two lualine components, ported from craftzdog's dotfiles
-- (lua/craftzdog/utils/lualine.lua), which trimmed them from LazyVim's:
--
--   root_name()    the project root's directory name, shown only while the
--                  root is not the working directory -- i.e. only when the
--                  path beside it would otherwise not say which project the
--                  file belongs to
--   pretty_path()  the file's path with the file name in bold, turning to the
--                  MatchParen colour while the buffer has unsaved changes, and
--                  a lock behind it when the buffer cannot be written
--
-- The project root is andrew.utils.root.project(): the nearest directory
-- holding a project marker.
--
-- Where this departs from his:
--
-- * A file outside the working directory is shown relative to its project
--   root (LazyVim's rule). His leaves the absolute path.
-- * The file name is coloured with lualine highlights (`create_hl`), which
--   take whatever they do not set from the section they sit in. His are bare
--   `%#Bold#` / `%#MatchParen#` groups, which know nothing of the section.
-- * An unnamed buffer reads "[No Name]", as it did before; his shows nothing.

local M = {}

local root = require("andrew.utils.root")

local ROOT_ICON = "\u{f126d}"
local READONLY_ICON = "\u{f033e}" -- nf-md-lock

---@param path string
---@return string absolute path with symlinks resolved where the path exists
local function resolved(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

--- 'statusline' reads `%` as the start of an item.
---@param text string
---@return string
local function escaped(text)
  return (text:gsub("%%", "%%%%"))
end

--- Name of the buffer's project root, or nil while that root is the working
--- directory.
---@param buffer? integer
---@return string?
function M.root_name_unless_cwd(buffer)
  local project_root = root.project(buffer)
  if project_root == resolved(vim.uv.cwd()) then
    return nil
  end
  return vim.fs.basename(project_root)
end

--- The buffer's path as shown: relative to the working directory when the
--- file is under it, else to its project root, else to the home directory.
--- A name that is not a file path (term://, a plugin's scheme) is returned
--- whole as the file part.
---@param buffer? integer
---@return string directory with its trailing slash, or ""
---@return string filename
function M.display_parts(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buffer)
  if name == "" then
    return "", "[No Name]"
  end
  if name:sub(1, 1) ~= "/" or name:find("^%a[%w+.-]*://") then
    return "", name
  end

  local path = resolved(name)
  local shown = vim.fn.fnamemodify(path, ":~")
  for _, base in ipairs({ resolved(vim.uv.cwd()), root.project(buffer) }) do
    if vim.startswith(path, base .. "/") then
      shown = path:sub(#base + 2)
      break
    end
  end
  return shown:match("^(.*/)") or "", shown:match("[^/]*$")
end

---@param group string
---@return string? "#rrggbb"
local function foreground_of(group)
  local foreground = vim.api.nvim_get_hl(0, { name = group, link = false }).fg
  return foreground and ("#%06x"):format(foreground) or nil
end

---@param color table lualine colour for the name, e.g. { fg = "#61afef" }
---@return table lualine component
function M.root_name(color)
  return {
    function()
      -- `cond` below keeps this from being drawn while there is no name.
      return ROOT_ICON .. " " .. escaped(M.root_name_unless_cwd() or "")
    end,
    cond = function()
      return M.root_name_unless_cwd() ~= nil
    end,
    color = color,
  }
end

---@return table lualine component
function M.pretty_path()
  return {
    function(component)
      -- Colour functions are re-evaluated by lualine on every draw, so the
      -- modified colour follows a colourscheme change.
      component.filename_highlight = component.filename_highlight
        or component:create_hl({ gui = "bold" }, "filename")
      component.modified_highlight = component.modified_highlight
        or component:create_hl(function()
          return { fg = foreground_of("MatchParen"), gui = "bold" }
        end, "modified")

      local directory, filename = M.display_parts()
      local filename_highlight = vim.bo.modified and component.modified_highlight
        or component.filename_highlight
      local is_readonly = vim.bo.readonly or not vim.bo.modifiable

      return escaped(directory)
        .. component:format_hl(filename_highlight)
        .. escaped(filename)
        .. component:get_default_hl()
        .. (is_readonly and (" " .. READONLY_ICON) or "")
    end,
  }
end

return M
