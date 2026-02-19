local types = require("andrew.vault.query.types")

local Date = types.Date
local Link = types.Link

local M = {}

-- Directories to skip during filesystem traversal
local SKIP_DIRS = {
  [".obsidian"] = true,
  [".git"] = true,
  [".trash"] = true,
  ["node_modules"] = true,
}

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

--- Synchronously scan all .md files and build the index.
---@return table self
function M.Index:build_sync()
  self.pages = {}
  self:_walk(self.vault_path, "")
  self:_compute_inlinks()
  return self
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
    for _, pt in ipairs(page.file.tags) do
      if pt == tag or pt:sub(1, #tag + 1) == tag .. "/" then
        result[#result + 1] = page
        break
      end
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
-- Filesystem walking (private)
-- =============================================================================

--- Recursively walk a directory, indexing all .md files.
---@param abs_dir string absolute directory path
---@param rel_dir string directory path relative to vault root (empty string for root)
function M.Index:_walk(abs_dir, rel_dir)
  local handle = vim.uv.fs_scandir(abs_dir)
  if not handle then
    return
  end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end

    local abs_path = abs_dir .. "/" .. name
    local rel_path = (rel_dir == "") and name or (rel_dir .. "/" .. name)

    if ftype == "directory" then
      if not SKIP_DIRS[name] then
        self:_walk(abs_path, rel_path)
      end
    elseif ftype == "file" and name:match("%.md$") then
      self:_index_file(abs_path, rel_path)
    end
  end
end

--- Index a single markdown file.
---@param abs_path string absolute file path
---@param rel_path string path relative to vault root
function M.Index:_index_file(abs_path, rel_path)
  local stat = vim.uv.fs_stat(abs_path)
  if not stat then
    return
  end

  local content = self:_read_file(abs_path)
  if not content then
    return
  end

  local name = rel_path:match("([^/]+)%.md$") or rel_path:gsub("%.md$", "")
  local folder = rel_path:match("^(.+)/[^/]+$") or ""
  local path_no_ext = rel_path:gsub("%.md$", "")

  -- Parse file contents
  local frontmatter, body = self:_split_frontmatter(content)
  local fm_fields = self:_parse_frontmatter(frontmatter)
  local body_fields = self:_extract_inline_fields(body)
  local tags = self:_extract_tags(fm_fields, body)
  local outlinks = self:_extract_links(content)
  local tasks, lists = self:_extract_tasks_and_lists(body)

  -- Parse date from filename if present
  local day = nil
  local date_match = name:match("^(%d%d%d%d%-%d%d%-%d%d)")
  if date_match then
    day = Date.parse(date_match)
  end

  -- Build the file sub-table
  local file = {
    name = name,
    path = rel_path,
    folder = folder,
    ext = ".md",
    link = Link.new(path_no_ext, name, false),
    ctime = self:_stat_to_date(stat.birthtime),
    mtime = self:_stat_to_date(stat.mtime),
    size = stat.size,
    tags = tags,
    outlinks = outlinks,
    inlinks = {},  -- populated later by _compute_inlinks
    tasks = tasks,
    lists = lists,
    day = day,
  }

  -- Build page: file table + frontmatter fields + inline body fields
  local page = { file = file }

  for k, v in pairs(fm_fields) do
    if k ~= "tags" then
      page[k] = v
    end
  end
  for k, v in pairs(body_fields) do
    page[k] = v
  end

  self.pages[rel_path] = page
end

--- Read a file's full contents.
---@param abs_path string
---@return string|nil
function M.Index:_read_file(abs_path)
  local file = io.open(abs_path, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

--- Convert a libuv stat time table to a Date.
---@param t table { sec, nsec } or number
---@return table Date
function M.Index:_stat_to_date(t)
  local sec = type(t) == "table" and t.sec or t
  if not sec or sec == 0 then
    return Date.today()
  end
  local d = os.date("*t", sec)
  return Date.new(d.year, d.month, d.day, d.hour, d.min, d.sec)
end

-- =============================================================================
-- Frontmatter parsing (private)
-- =============================================================================

--- Split file content into frontmatter string and body string.
---@param content string full file content
---@return string frontmatter (empty if none)
---@return string body (everything after frontmatter)
function M.Index:_split_frontmatter(content)
  -- Frontmatter must start at the very beginning of the file
  if not content:match("^%-%-%-\r?\n") then
    return "", content
  end

  -- Find the closing ---
  local _, fm_end = content:find("\n%-%-%-\r?\n", 4)
  if not fm_end then
    -- Try closing --- at end of file
    _, fm_end = content:find("\n%-%-%-\r?$", 4)
    if not fm_end then
      return "", content
    end
  end

  local fm_start = content:find("\n", 1) + 1  -- skip opening ---
  local fm_text = content:sub(fm_start, fm_end):gsub("\n%-%-%-\r?\n?$", "")
  local body = content:sub(fm_end + 1)

  return fm_text, body
end

--- Parse a simple YAML-like frontmatter block into a table.
---@param text string frontmatter text (without --- delimiters)
---@return table fields
function M.Index:_parse_frontmatter(text)
  if text == "" then
    return {}
  end

  local fields = {}
  local lines = vim.split(text, "\n", { plain = true })
  local i = 1

  while i <= #lines do
    local line = lines[i]

    -- Match top-level key: value
    local key, value = line:match("^([%w_%-]+):%s*(.*)")
    if key then
      value = vim.trim(value)

      if value == "" then
        -- Could be a block list: check if next lines are indented "- item"
        local list = {}
        while i + 1 <= #lines and lines[i + 1]:match("^%s+%- ") do
          i = i + 1
          local item = lines[i]:match("^%s+%- (.*)")
          if item then
            list[#list + 1] = self:_parse_scalar(vim.trim(item))
          end
        end
        if #list > 0 then
          fields[key] = list
        end
        -- If no list items followed, leave as nil (empty value)
      elseif value:sub(1, 1) == "[" and value:sub(-1) == "]" then
        -- Inline array: [item1, item2, item3]
        fields[key] = self:_parse_inline_array(value)
      else
        fields[key] = self:_parse_scalar(value)
      end
    end

    i = i + 1
  end

  return fields
end

--- Parse an inline YAML array like "[item1, item2, item3]".
---@param text string the full bracketed string
---@return table list of parsed values
function M.Index:_parse_inline_array(text)
  local inner = text:sub(2, -2) -- strip [ and ]
  local items = {}
  -- Split on commas, respecting quoted strings
  for item in self:_iter_csv(inner) do
    items[#items + 1] = self:_parse_scalar(vim.trim(item))
  end
  return items
end

--- Iterate over comma-separated values, respecting quotes.
---@param text string
---@return function iterator yielding each value string
function M.Index:_iter_csv(text)
  local pos = 1
  return function()
    if pos > #text then
      return nil
    end

    local ch = text:sub(pos, pos)
    local value

    -- Skip leading whitespace
    while ch == " " or ch == "\t" do
      pos = pos + 1
      if pos > #text then return nil end
      ch = text:sub(pos, pos)
    end

    if ch == '"' or ch == "'" then
      -- Quoted value: find matching close quote
      local quote = ch
      local start = pos + 1
      local end_pos = text:find(quote, start, true)
      if end_pos then
        value = text:sub(start, end_pos - 1)
        pos = end_pos + 1
      else
        value = text:sub(start)
        pos = #text + 1
      end
      -- Skip comma after quoted value
      local next_comma = text:find(",", pos, true)
      if next_comma then
        pos = next_comma + 1
      else
        pos = #text + 1
      end
    else
      -- Unquoted: read until comma or end
      local next_comma = text:find(",", pos, true)
      if next_comma then
        value = text:sub(pos, next_comma - 1)
        pos = next_comma + 1
      else
        value = text:sub(pos)
        pos = #text + 1
      end
    end

    return vim.trim(value)
  end
end

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

  -- Date: YYYY-MM-DD (optionally with time)
  local y, m, d = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y then
    local parsed = Date.parse(text)
    if parsed then return parsed end
  end

  -- Numbers
  local num = tonumber(text)
  if num then
    return num
  end

  -- Wikilink in frontmatter value: [[Something]]
  local link_path = text:match("^%[%[(.-)%]%]$")
  if link_path then
    local lp, ld = link_path:match("^(.-)%|(.+)$")
    if lp then
      return Link.new(lp, ld, false)
    else
      local display = link_path:match("([^/]+)$") or link_path
      return Link.new(link_path, display, false)
    end
  end

  return text
end

-- =============================================================================
-- Inline field extraction (private)
-- =============================================================================

--- Extract inline Dataview fields from the body text.
--- Patterns: `key:: value`, `[key:: value]`, `(key:: value)`
---@param body string note body (without frontmatter)
---@return table fields
function M.Index:_extract_inline_fields(body)
  local fields = {}

  for line in body:gmatch("[^\n]+") do
    -- Skip lines that are task items (those are handled separately)
    if line:match("^%s*[-*] %[.%] ") then
      goto continue
    end

    -- Standalone: `key:: value` at start of line or after text
    for key, value in line:gmatch("([%w_%-]+)::%s*(.-)%s*$") do
      if not key:match("^https?$") then
        fields[key] = self:_parse_scalar(vim.trim(value))
      end
    end

    -- Bracketed: `[key:: value]`
    for key, value in line:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
      fields[key] = self:_parse_scalar(vim.trim(value))
    end

    -- Parenthesized: `(key:: value)`
    for key, value in line:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
      fields[key] = self:_parse_scalar(vim.trim(value))
    end

    ::continue::
  end

  return fields
end

-- =============================================================================
-- Tag extraction (private)
-- =============================================================================

--- Extract all tags from frontmatter fields and body text.
---@param fm_fields table parsed frontmatter
---@param body string note body
---@return string[] tags without # prefix, including parent expansions
function M.Index:_extract_tags(fm_fields, body)
  local tag_set = {}

  -- Tags from frontmatter
  local fm_tags = fm_fields.tags
  if type(fm_tags) == "table" then
    for _, t in ipairs(fm_tags) do
      local tag = tostring(t):gsub("^#", "")
      self:_add_tag_with_parents(tag_set, tag)
    end
  elseif type(fm_tags) == "string" then
    local tag = fm_tags:gsub("^#", "")
    self:_add_tag_with_parents(tag_set, tag)
  end

  -- Tags from body: #tag-name or #tag/subtag
  -- Avoid matching inside code blocks and code spans
  local clean_body = self:_strip_code_blocks(body)
  for tag in clean_body:gmatch("#([%w_%-][%w_%-/]*)") do
    -- Exclude pure numbers (e.g., #123 is not a tag)
    if not tag:match("^%d+$") then
      self:_add_tag_with_parents(tag_set, tag)
    end
  end

  -- Convert set to sorted list
  local tags = {}
  for tag in pairs(tag_set) do
    tags[#tags + 1] = tag
  end
  table.sort(tags)
  return tags
end

--- Add a tag and all its parent segments to a set.
--- e.g., "project/active/urgent" adds "project/active/urgent", "project/active", "project"
---@param set table tag set (tag -> true)
---@param tag string
function M.Index:_add_tag_with_parents(set, tag)
  set[tag] = true
  -- Add parent tags
  local parent = tag
  while true do
    parent = parent:match("^(.+)/[^/]+$")
    if not parent then break end
    set[parent] = true
  end
end

-- =============================================================================
-- Link extraction (private)
-- =============================================================================

--- Extract all wikilinks and embeds from file content.
---@param content string full file content
---@return table[] list of Link objects
function M.Index:_extract_links(content)
  local links = {}
  local clean = self:_strip_code_blocks(content)

  -- Match embeds: ![[...]] and wikilinks: [[...]]
  -- Process embeds first so we don't double-match
  for embed_content in clean:gmatch("!%[%[(.-)%]%]") do
    local path, display = embed_content:match("^(.-)%|(.+)$")
    if not path then
      path = embed_content
      display = embed_content:match("([^/]+)$") or embed_content
    end
    -- Strip any heading/block references for the display
    local clean_display = display:match("^([^#]+)") or display
    links[#links + 1] = Link.new(path, vim.trim(clean_display), true)
  end

  -- Match wikilinks: [[...]] but not ![[...]]
  -- Use a pattern that finds [[ not preceded by !
  for line in clean:gmatch("[^\n]+") do
    local search_start = 1
    while true do
      local s, e = line:find("%[%[(.-)%]%]", search_start)
      if not s then break end

      -- Check that this is not an embed (preceded by !)
      local is_embed = (s > 1) and (line:sub(s - 1, s - 1) == "!")
      if not is_embed then
        local inner = line:sub(s + 2, e - 2)
        -- Skip if it looks like an inline field: [key:: value]
        if not inner:match("^[%w_%-]+::") then
          local path, display = inner:match("^(.-)%|(.+)$")
          if not path then
            path = inner
            display = inner:match("([^/]+)$") or inner
          end
          -- Strip heading/block references from display
          local clean_display = display:match("^([^#]+)") or display
          links[#links + 1] = Link.new(path, vim.trim(clean_display), false)
        end
      end

      search_start = e + 1
    end
  end

  return links
end

-- =============================================================================
-- Task and list extraction (private)
-- =============================================================================

--- Extract tasks and list items from the body text.
---@param body string note body
---@return table[] tasks
---@return table[] lists (all list items including tasks)
function M.Index:_extract_tasks_and_lists(body)
  local tasks = {}
  local lists = {}

  local lines = vim.split(body, "\n", { plain = true })
  -- Track whether we are inside a code fence
  local in_code_fence = false

  for line_num, line in ipairs(lines) do
    -- Toggle code fence state
    if line:match("^%s*```") then
      in_code_fence = not in_code_fence
    end
    if in_code_fence then
      goto continue
    end

    -- Check for list items: lines starting with - or * (possibly indented)
    local list_marker = line:match("^(%s*[-*]) ")
    if list_marker then
      -- Check if it's a task: - [ ] or * [ ]
      local status_char = line:match("^%s*[-*] %[(.)%] ")
      if status_char then
        local text = line:match("^%s*[-*] %[.%] (.*)")
        if text then
          local task = self:_parse_task(text, status_char, line_num)
          tasks[#tasks + 1] = task
          lists[#lists + 1] = {
            text = text,
            line = line_num,
            task = true,
          }
        end
      else
        -- Plain list item
        local text = line:match("^%s*[-*] (.*)")
        if text then
          lists[#lists + 1] = {
            text = text,
            line = line_num,
            task = false,
          }
        end
      end
    end

    ::continue::
  end

  return tasks, lists
end

--- Parse a task line into a task object.
---@param text string task text (without the "- [ ] " prefix)
---@param status_char string the character inside the brackets
---@param line_num number 1-indexed line number
---@return table task
function M.Index:_parse_task(text, status_char, line_num)
  local completed = (status_char == "x" or status_char == "X")

  local task = {
    text = text,
    completed = completed,
    status = status_char,
    line = line_num,
    due = nil,
    priority = nil,
    tags = {},
  }

  -- Extract inline fields from task text: [key:: value]
  for key, value in text:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
    local parsed = self:_parse_scalar(vim.trim(value))
    task[key] = parsed
  end

  -- Also handle parenthesized inline fields: (key:: value)
  for key, value in text:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
    local parsed = self:_parse_scalar(vim.trim(value))
    task[key] = parsed
  end

  -- Extract tags from task text
  local tag_set = {}
  for tag in text:gmatch("#([%w_%-][%w_%-/]*)") do
    if not tag:match("^%d+$") then
      self:_add_tag_with_parents(tag_set, tag)
    end
  end
  local tags = {}
  for tag in pairs(tag_set) do
    tags[#tags + 1] = tag
  end
  table.sort(tags)
  task.tags = tags

  return task
end

-- =============================================================================
-- Inlink computation (private)
-- =============================================================================

--- After all files are indexed, compute inlinks for every page.
--- For each page's outlinks, find the target page and register an inlink.
function M.Index:_compute_inlinks()
  -- Build a lookup by name and path (without .md extension) for link resolution
  local by_name = {} -- lowercase filename -> page
  local by_path = {} -- lowercase relative path without ext -> page

  for _, page in pairs(self.pages) do
    local lower_name = page.file.name:lower()
    -- If multiple pages share a name, the lookup is ambiguous; store first found
    if not by_name[lower_name] then
      by_name[lower_name] = page
    end

    local lower_path = page.file.path:gsub("%.md$", ""):lower()
    by_path[lower_path] = page
  end

  -- Resolve each outlink and add inlinks
  for _, source_page in pairs(self.pages) do
    for _, link in ipairs(source_page.file.outlinks) do
      local target = self:_resolve_link(link, by_name, by_path)
      if target and target.file.path ~= source_page.file.path then
        -- Add source as an inlink of target
        target.file.inlinks[#target.file.inlinks + 1] =
          Link.new(
            source_page.file.path:gsub("%.md$", ""),
            source_page.file.name,
            false
          )
      end
    end
  end
end

--- Resolve a Link to its target page.
---@param link table Link object
---@param by_name table lowercase name -> page
---@param by_path table lowercase path (no ext) -> page
---@return table|nil target page
function M.Index:_resolve_link(link, by_name, by_path)
  local raw = link.path or ""
  -- Strip heading/block references: "Page#heading" -> "Page"
  raw = raw:match("^([^#]+)") or raw
  raw = vim.trim(raw)

  if raw == "" then
    return nil
  end

  local lower = raw:lower()

  -- Try exact path match first (relative path without extension)
  if by_path[lower] then
    return by_path[lower]
  end

  -- Try with .md stripped if someone typed it
  local without_md = lower:gsub("%.md$", "")
  if by_path[without_md] then
    return by_path[without_md]
  end

  -- Try by filename only (Obsidian's shortest-path resolution)
  local name_only = lower:match("([^/]+)$") or lower
  if by_name[name_only] then
    return by_name[name_only]
  end

  return nil
end

-- =============================================================================
-- Utility (private)
-- =============================================================================

--- Strip fenced code blocks and inline code from text to avoid
--- extracting tags/links from inside code.
---@param text string
---@return string cleaned text
function M.Index:_strip_code_blocks(text)
  -- Remove fenced code blocks: ```...```
  text = text:gsub("```.-```", "")
  -- Remove inline code: `...`
  text = text:gsub("`[^`]+`", "")
  return text
end

return M
