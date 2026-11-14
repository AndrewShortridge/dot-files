--- Search-time directory exclusions for vault searches.
---
--- An Obsidian vault carries two folders whose contents are never what you want
--- back from a search: `.obsidian/` (the app's own JSON/CSS/JS configuration) and
--- the templates folder (placeholder scaffolding whose filenames -- README.md,
--- Home.md, CLAUDE.md -- collide head-on with real notes).
---
--- WHY THIS IS SEPARATE FROM `config.index.skip_dirs`
---
--- skip_dirs removes a directory from the index entirely, which also removes it
--- from wikilink resolution, backlinks, completion, tasks and the graph. That is
--- correct for `.obsidian` (no .md files at all) but wrong for templates: a
--- template is a real note that you still want to open, link to with
--- `[[Some Template]]`, and -- crucially -- still want :VaultLinkCheck to report
--- broken links inside. So templates stay INDEXED and are filtered out at search
--- time only.
---
--- Matching is case-insensitive and applies to any directory segment at any depth,
--- mirroring skip_dirs' bare-name semantics. Case-insensitivity is load-bearing
--- here: `config.user_templates.dir` says "templates" while the folder on disk is
--- "Templates", so a case-sensitive match would silently exclude nothing.
---
--- The filename itself is never matched -- only directory components -- so a note
--- called `Templates.md` at the vault root is still searchable.

local M = {}

-- Memoized derivations, keyed on the identity of config.search.exclude_dirs.
-- Reassigning that table (as specs do) invalidates automatically; there is no
-- reset() to forget to call.
local _src = nil
local _set = nil
local _rg_args = nil
local _rg_opts = nil
local _fzf_patterns = nil

--- Turn a directory name into a case-insensitive Lua pattern fragment.
--- "Templates" -> "[Tt][Ee][Mm][Pp][Ll][Aa][Tt][Ee][Ss]", ".obsidian" -> "%.[Oo]..."
---@param name string
---@return string
local function ci_pattern(name)
  return (name:gsub("%a", function(c)
    return "[" .. c:upper() .. c:lower() .. "]"
  end):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", function(c)
    -- Escape Lua magic characters, but leave the [Xx] classes built above intact.
    if c == "[" or c == "]" then return c end
    return "%" .. c
  end))
end

local function rebuild()
  local src = require("andrew.vault.config").search.exclude_dirs or {}
  if src == _src then return end
  _src = src

  _set = {}
  _rg_args = {}
  _rg_opts = {}
  _fzf_patterns = {}

  for _, name in ipairs(src) do
    if type(name) == "string" and name ~= "" then
      _set[name:lower()] = true

      -- `**/X/**` matches X at the vault root AND at any depth (verified against
      -- ripgrep). --iglob rather than --glob so the match is case-insensitive.
      local glob = "!**/" .. name .. "/**"
      _rg_args[#_rg_args + 1] = "--iglob"
      _rg_args[#_rg_args + 1] = glob
      _rg_opts[#_rg_opts + 1] = '--iglob "' .. glob .. '"'

      -- fzf-lua matches these Lua patterns against the cwd-relative path, so a
      -- leading-segment and an any-depth form are both needed.
      local p = ci_pattern(name)
      _fzf_patterns[#_fzf_patterns + 1] = "^" .. p .. "/"
      _fzf_patterns[#_fzf_patterns + 1] = "/" .. p .. "/"
    end
  end
end

--- Is this vault-relative path inside an excluded directory?
---@param rel_path string|nil vault-relative path, e.g. "Templates/Book.md"
---@return boolean
function M.is_excluded(rel_path)
  if not rel_path then return false end
  rebuild()
  if not next(_set) then return false end
  -- Walk directory segments only; everything after the last "/" is the filename.
  local from = 1
  while true do
    local slash = rel_path:find("/", from, true)
    if not slash then return false end
    if _set[rel_path:sub(from, slash - 1):lower()] then return true end
    from = slash + 1
  end
end

--- Are any exclusions configured at all?
---@return boolean
function M.active()
  rebuild()
  return next(_set) ~= nil
end

--- Exclusion flags for an argv-style ripgrep call (vim.system).
---@return string[] flat list of { "--iglob", "!**/X/**", ... }
function M.rg_args()
  rebuild()
  return _rg_args
end

--- Exclusion flags as a shell-style option string, for fzf-lua's `rg_opts`.
---@return string "" when nothing is excluded, else a leading-space-free fragment
function M.rg_opts()
  rebuild()
  return table.concat(_rg_opts, " ")
end

--- Lua patterns for fzf-lua's `file_ignore_patterns`.
--- Unlike every other fzf-lua string option, this one APPENDS across the
--- call-site / provider / global layers rather than replacing.
---@return string[]
function M.fzf_patterns()
  rebuild()
  return _fzf_patterns
end

--- Filter a rel_path -> entry map, dropping excluded notes.
--- Returns the original table untouched when nothing is excluded, so the common
--- no-op case costs nothing.
---@param files table<string, table>
---@return table<string, table>
function M.filter_files(files)
  if not files or not M.active() then return files end
  local out = {}
  for rel_path, entry in pairs(files) do
    if not M.is_excluded(rel_path) then
      out[rel_path] = entry
    end
  end
  return out
end

return M
