--- Person note helpers for the vault's People/ folder.
---
--- Provides listing, existence checks and non-interactive stub creation for
--- person notes. Stub creation deliberately writes straight to disk (via
--- engine.write_file) instead of engine.write_note so that callers can create
--- many notes at once without opening a buffer per note.
---
--- The interactive, prompt-driven person note lives in
--- lua/andrew/vault/templates/person.lua; this module is its headless sibling
--- and keeps the same frontmatter field order.
local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")

local M = {}

--- Absolute path of the People/ directory.
--- Resolved on every call because engine.vault_path can change at runtime.
---@return string
local function people_dir()
  return engine.vault_path .. "/" .. config.dirs.people
end

--- Strip characters that are unsafe in filenames.
--- Mirrors the sanitization in templates/literature.lua.
---@param name string
---@return string
local function sanitize(name)
  return (name:gsub(":", " -"):gsub("/", "-"):gsub("[%*%?|]", ""))
end

--- Absolute path of the note backing a person name (including .md).
---@param name string
---@return string
local function abs_path(name)
  return engine.vault_path .. "/" .. M.rel_path(name) .. ".md"
end

--- Sorted display names of existing person notes.
--- Basenames of People/*.md with the extension stripped.
---@return string[] names  empty table if People/ does not exist
function M.list_names()
  local names = {}
  local handle = vim.uv.fs_scandir(people_dir())
  if handle then
    while true do
      local entry, ftype = vim.uv.fs_scandir_next(handle)
      if not entry then break end
      if ftype == "file" and entry:sub(-3) == ".md" then
        names[#names + 1] = entry:sub(1, -4)
      end
    end
  end

  table.sort(names)
  return names
end

--- Quote a value for use inside a YAML wikilink list item.
---
--- Double quotes are preferred: they match the existing Library corpus and the
--- Obsidian Templater template, and they carry an apostrophe (O'Malley)
--- without escaping. Single quotes cannot -- YAML escapes an embedded
--- apostrophe by doubling it, and the index's strip_quotes does NOT un-double,
--- so 'Sean O''Malley' would be indexed and linked as "Sean O''Malley" and
--- never resolve to the person note.
---@param value string
---@return string quoted  including the surrounding quote characters
function M.yaml_quote(value)
  value = tostring(value)
  if not value:find('["\\]') then
    return '"' .. value .. '"'
  end
  -- Contains a double quote or backslash: single-quote instead, doubling any
  -- apostrophe. Vanishingly rare in a person's name.
  return "'" .. value:gsub("'", "''") .. "'"
end

--- Vault-relative path of a person note, WITHOUT the .md extension.
--- Example: "People/Rongbo Wang".
---@param name string
---@return string
function M.rel_path(name)
  return config.dirs.people .. "/" .. sanitize(name)
end

--- Does the person note already exist on disk?
---@param name string
---@return boolean
function M.exists(name)
  if type(name) ~= "string" or name == "" then return false end
  return vim.uv.fs_stat(abs_path(name)) ~= nil
end

--- Create a stub person note if it does not already exist.
--- Never opens a buffer; the file is written directly and registered with the
--- vault index so links to it resolve immediately.
---@param name string
---@param opts? { aliases?: string[] }
---@return string status  "created" | "exists" | "error"
function M.create_stub(name, opts)
  if type(name) ~= "string" or vim.trim(name) == "" then return "error" end
  if M.exists(name) then return "exists" end

  opts = opts or {}

  local aliases = ""
  if type(opts.aliases) == "table" and #opts.aliases > 0 then
    aliases = "aliases:\n"
    for _, alias in ipairs(opts.aliases) do
      aliases = aliases .. "  - " .. M.yaml_quote(alias) .. "\n"
    end
  end

  local fm = "---\n"
    .. "type: person\n"
    .. "name: " .. name .. "\n"
    .. aliases
    .. "role: \n"
    .. "institution: \n"
    .. "email: \n"
    .. "created: " .. engine.today() .. "\n"
    .. "tags:\n"
    .. "  - person\n"
    .. "---\n"

  -- Mirrors the opening line of templates/person.lua so stubs and fully
  -- prompted person notes look the same.
  local body = "# "
    .. name
    .. "\n\n"
    .. "<!-- Auto-created person stub: fill in role / institution / email. -->\n\n"
    .. "## Notes\n"

  local path = abs_path(name)
  if not engine.write_file(path, fm .. "\n" .. body) then
    return "error"
  end

  local idx = require("andrew.vault.vault_index").current()
  if idx then idx:update_file(path) end

  return "created"
end

return M
