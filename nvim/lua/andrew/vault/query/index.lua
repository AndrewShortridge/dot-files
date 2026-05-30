local link_utils = require("andrew.vault.link_utils")
local pat = require("andrew.vault.patterns")
local types = require("andrew.vault.query.types")
local vault_index = require("andrew.vault.vault_index")
local log = require("andrew.vault.vault_log").scope("query/index")

local Date = types.Date
local Link = types.Link

local M = {}

-- =============================================================================
-- Index
-- =============================================================================

M.Index = {}
M.Index.__index = M.Index

--- Create a new vault index.
---@param vault_path string absolute path to vault root
---@return table Index instance (not yet built)
function M.Index.new(vault_path)
  local self = setmetatable({}, M.Index)
  self.vault_path = vault_path:gsub("/$", "") -- strip trailing slash
  self.pages = {}                              -- rel_path -> page
  return self
end

--- Synchronously build the index from the vault index.
---@return table self
function M.Index:build_sync()
  return self:build_from_vault_index()
end

--- Build the query index directly from the vault index.
---@return table self
function M.Index:build_from_vault_index()
  local vi = vault_index.current()

  self.pages = {}
  self._mtimes = {}

  if vi and vi:is_ready() then
    local files = vi:snapshot_files()
    for rel_path, entry in pairs(files) do
      local page = self:_entry_to_page(entry)
      self.pages[rel_path] = page
      self._mtimes[rel_path] = entry.mtime
    end

    -- Populate inlinks from vault_index (single source of truth for resolution)
    self:_populate_inlinks_from_vi(vi)
  end

  return self
end

--- Convert a vault index entry into the page format used by the query system.
---@param entry table VaultIndexEntry from vault_index
---@return table page
function M.Index:_entry_to_page(entry)
  local path_no_ext = link_utils.rel_to_stem(entry.rel_path)

  -- Convert outlinks from plain tables to Link objects, preserving pre-computed fields
  local outlinks = {}
  for _, ol in ipairs(entry.outlinks or {}) do
    local link = Link.new(ol.path, ol.display, ol.embed)
    link._name_lower = ol._name_lower
    link.stem_lower = ol.stem_lower
    link.basename_lower = ol.basename_lower
    outlinks[#outlinks + 1] = link
  end

  -- Convert tasks: the vault index stores them in a compatible structure,
  -- but we ensure the format matches what the query system expects.
  local tasks = {}
  for _, t in ipairs(entry.tasks or {}) do
    tasks[#tasks + 1] = {
      text = t.text,
      completed = t.completed,
      status = t.status,
      line = t.line,
      tags = t.tags or {},
    }
  end

  -- Parse day from the vault index entry
  local day = nil
  if entry.day then
    day = Date.parse(entry.day)
  end

  -- Build the file sub-table
  local file = {
    name = entry.basename,
    name_lower = entry.basename_lower,
    path = entry.rel_path,
    folder = entry.folder,
    ext = ".md",
    link = Link.new(path_no_ext, entry.basename, false),
    ctime = self:_timestamp_to_date(entry.ctime),
    mtime = self:_timestamp_to_date(entry.mtime),
    size = entry.size,
    tags = entry.tags or {},
    tag_set = entry.tag_set or {},
    outlinks = outlinks,
    inlinks = {},  -- populated later by _populate_inlinks_from_vi
    tasks = tasks,
    lists = {},    -- vault index does not track plain list items
    day = day,
  }

  -- Build page: file table + frontmatter fields + inline fields
  local page = { file = file }

  if entry.frontmatter then
    for k, v in pairs(entry.frontmatter) do
      if k ~= "tags" then
        -- Re-parse scalar values so Dates/Links/numbers are proper types
        page[k] = self:_parse_scalar_from_vi(v)
      end
    end
  end

  if entry.inline_fields then
    for k, v in pairs(entry.inline_fields) do
      page[k] = self:_parse_scalar_from_vi(v)
    end
  end

  -- Aliases are stored at page level (used by query expressions)
  if entry.aliases and #entry.aliases > 0 then
    page.aliases = entry.aliases
  end

  return page
end

--- Convert a unix timestamp (seconds) to a Date object.
--- Used when building pages from vault index entries.
---@param ts number|nil unix timestamp in seconds
---@return table Date
function M.Index:_timestamp_to_date(ts)
  if not ts or ts == 0 then
    return Date.today()
  end
  local d = os.date("*t", ts)
  return Date.new(d.year, d.month, d.day, d.hour, d.min, d.sec)
end

--- Re-parse a value from the vault index into the rich types expected by the
--- query system. The vault index stores frontmatter/inline values as plain
--- strings, numbers, booleans, and tables (after simple YAML parsing), but
--- does not wrap dates in Date objects or wikilinks in Link objects.
---@param val any
---@return any
function M.Index:_parse_scalar_from_vi(val)
  if type(val) == "string" then
    return self:_parse_scalar(val)
  elseif type(val) == "table" then
    -- Could be an array of values; re-parse each element
    local arr = {}
    local is_array = true
    for k, v in pairs(val) do
      if type(k) ~= "number" then
        is_array = false
        break
      end
    end
    if is_array then
      for _, v in ipairs(val) do
        arr[#arr + 1] = self:_parse_scalar_from_vi(v)
      end
      return arr
    end
    return val
  end
  -- numbers, booleans, nil pass through
  return val
end

--- Incrementally update the index by rebuilding from the vault index.
---@return table self
function M.Index:update_incremental()
  return self:build_from_vault_index()
end

--- Get a page by its vault-relative path.
---@param rel_path string e.g. "Projects/Alpha/Dashboard.md"
---@return table|nil page
function M.Index:get_page(rel_path)
  return self.pages[rel_path]
end

--- Return all indexed pages as a list.
---@return table[] list of pages
function M.Index:all_pages()
  local result = {}
  for _, page in pairs(self.pages) do
    result[#result + 1] = page
  end
  return result
end

--- Return pages whose file.folder starts with the given folder prefix.
---@param folder string e.g. "Projects"
---@return table[] list of pages
function M.Index:pages_in_folder(folder)
  -- Normalise: strip trailing slash
  folder = folder:gsub("/$", "")
  local result = {}
  for _, page in pairs(self.pages) do
    local pf = page.file.folder
    if pf == folder or pf:sub(1, #folder + 1) == folder .. "/" then
      result[#result + 1] = page
    end
  end
  return result
end

--- Return pages that have the given tag (without #).
--- Matches exact tags and parent-tag relationships:
--- tag "project" matches pages with "project" or "project/active".
---@param tag string tag without # prefix
---@return table[] list of pages
function M.Index:pages_with_tag(tag)
  local result = {}
  for _, page in pairs(self.pages) do
    if vault_index.tag_matches(page.file.tags, tag) then
      result[#result + 1] = page
    end
  end
  return result
end

--- Resolve a source AST node from the Dataview parser into a list of pages.
---@param node table source AST node
---@return table[] list of pages
function M.Index:resolve_source(node)
  if node.type == "folder" then
    return self:pages_in_folder(node.path)
  elseif node.type == "tag" then
    return self:pages_with_tag(node.tag)
  elseif node.type == "or" then
    return self:_set_union(
      self:resolve_source(node.left),
      self:resolve_source(node.right)
    )
  elseif node.type == "and" then
    return self:_set_intersect(
      self:resolve_source(node.left),
      self:resolve_source(node.right)
    )
  elseif node.type == "not" then
    return self:_set_diff(self:all_pages(), self:resolve_source(node.operand))
  else
    log.warn("resolve_source: unknown node type: %s", tostring(node.type))
    return {}
  end
end

--- Given an absolute file path, find the corresponding page in the index.
---@param abs_path string absolute filesystem path
---@return table|nil page
function M.Index:current_page(abs_path)
  local prefix = self.vault_path .. "/"
  if abs_path:sub(1, #prefix) ~= prefix then
    return nil
  end
  local rel_path = abs_path:sub(#prefix + 1)
  return self.pages[rel_path]
end

-- =============================================================================
-- Set operations (private)
-- =============================================================================

--- Union of two page lists, deduplicated by file.path.
function M.Index:_set_union(a, b)
  local seen = {}
  local result = {}
  for _, page in ipairs(a) do
    if not seen[page.file.path] then
      seen[page.file.path] = true
      result[#result + 1] = page
    end
  end
  for _, page in ipairs(b) do
    if not seen[page.file.path] then
      seen[page.file.path] = true
      result[#result + 1] = page
    end
  end
  return result
end

--- Intersection of two page lists.
function M.Index:_set_intersect(a, b)
  local set = {}
  for _, page in ipairs(b) do
    set[page.file.path] = true
  end
  local result = {}
  for _, page in ipairs(a) do
    if set[page.file.path] then
      result[#result + 1] = page
    end
  end
  return result
end

--- Difference: pages in a that are not in b.
function M.Index:_set_diff(a, b)
  local set = {}
  for _, page in ipairs(b) do
    set[page.file.path] = true
  end
  local result = {}
  for _, page in ipairs(a) do
    if not set[page.file.path] then
      result[#result + 1] = page
    end
  end
  return result
end

-- =============================================================================
-- Scalar parsing (private)
-- =============================================================================

--- Parse a scalar YAML value into the appropriate Lua type.
---@param text string trimmed value text
---@return any
function M.Index:_parse_scalar(text)
  if text == "" then
    return nil
  end

  -- Strip surrounding quotes
  if (#text >= 2) and
     ((text:sub(1, 1) == '"' and text:sub(-1) == '"') or
      (text:sub(1, 1) == "'" and text:sub(-1) == "'")) then
    return text:sub(2, -2)
  end

  -- Booleans
  if text == "true" then return true end
  if text == "false" then return false end

  -- Date: YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS (and similar datetime formats)
  if text:match(pat.ISO_DATE) or text:match("^%d%d%d%d%-%d%d%-%d%d[T ]") then
    local parsed = Date.parse(text)
    if parsed then return parsed end
  end

  -- Numbers
  local num = tonumber(text)
  if num then
    return num
  end

  -- Wikilink in frontmatter value: [[Something]]
  local link_path = text:match(link_utils.WIKILINK_EXACT_PAT)
  if link_path then
    local lp, ld = link_path:match("^(.-)%|(.+)$")
    if lp then
      return Link.new(lp, ld, false)
    else
      local display = link_utils.get_tail(link_path)
      return Link.new(link_path, display, false)
    end
  end

  return text
end

-- =============================================================================
-- Inlink population from vault_index (private)
-- =============================================================================

--- Populate inlinks for every page from the vault index's pre-computed inlinks.
--- The vault index is the single source of truth for link resolution and inlink
--- computation; we simply convert its plain-table inlinks into Link objects.
---@param vi table VaultIndex instance
function M.Index:_populate_inlinks_from_vi(vi)
  for rel_path, page in pairs(self.pages) do
    local vi_inlinks = vi:get_inlinks(rel_path)
    local inlinks = {}
    for _, il in ipairs(vi_inlinks) do
      local link = Link.new(il.path, il.display, il.embed or false)
      link.path_lower = il.path_lower
      inlinks[#inlinks + 1] = link
    end
    page.file.inlinks = inlinks
  end
end

return M
