--- Dataview-compatible query API for Obsidian vault in Neovim.
---
--- This module creates the `dv` execution environment that Lua code blocks
--- use to query vault data and produce render items. It mirrors the Obsidian
--- DataviewJS API surface, adapted for Lua.
---
--- Usage:
---   local api = require("andrew.vault.query.api")
---   local results, err = api.execute_block(code, index, current_file_path)

local types = require("andrew.vault.query.types")

local M = {}

-- Metatable for arrays returned by string:split() — adds :slice() support
-- needed by transpiled DataviewJS code.
local _split_array_mt = {
  __index = {
    slice = function(self, start, stop)
      start = math.max(1, start or 1)
      stop = math.min(#self, stop or #self)
      local out = {}
      for i = start, stop do
        out[#out + 1] = self[i]
      end
      return setmetatable(out, getmetatable(self))
    end,
  },
}

-- Add string.split so JS-transpiled `str:split(sep)` works
if not string.split then
  string.split = function(s, sep)
    return setmetatable(vim.split(s, sep), _split_array_mt)
  end
end

-- ---------------------------------------------------------------------------
-- Field resolution helper
-- ---------------------------------------------------------------------------

--- Resolve a dot-path field like `"file.name"` on an object.
---@param obj table
---@param field string
---@return any
local function resolve_field(obj, field)
  if obj == nil then
    return nil
  end
  local current = obj
  for segment in field:gmatch("[^%.]+") do
    if type(current) ~= "table" then
      return nil
    end
    current = current[segment]
  end
  return current
end

-- ---------------------------------------------------------------------------
-- PageArray
-- ---------------------------------------------------------------------------
-- A thin wrapper around a plain array that adds chainable query methods while
-- preserving natural numeric indexing, `#`, and `ipairs` compatibility.
--
-- Data is stored directly as numeric keys in the table.  Methods live on the
-- metatable so they never collide with numeric indices.
-- ---------------------------------------------------------------------------

local PageArray = {}

--- Metatable: numeric keys come from the table itself, named keys fall through
--- to the PageArray method table. Also supports `.length` for JS compatibility.
PageArray.__index = function(self, key)
  if key == "length" then
    return rawget(self, "_len")
  end
  return PageArray[key]
end

--- Length operator returns the stored count.
PageArray.__len = function(self)
  return rawget(self, "_len")
end

--- Create a new PageArray wrapping `data`.
---@param data table|nil  array of items (pages, tasks, anything)
---@return table PageArray
function PageArray.new(data)
  data = data or {}
  local self = setmetatable({}, PageArray)
  for i, v in ipairs(data) do
    rawset(self, i, v)
  end
  rawset(self, "_len", #data)
  return self
end

--- Filter items, keeping only those for which `fn` returns truthy.
---@param fn function(item) -> bool
---@return table PageArray
function PageArray:where(fn)
  local out = {}
  for i = 1, self._len do
    local item = rawget(self, i)
    if fn(item) then
      out[#out + 1] = item
    end
  end
  return PageArray.new(out)
end

--- Alias for `:where()`.
PageArray.filter = PageArray.where

--- Sort items.
---
--- If `fn_or_field` is a function it is used as a less-than comparator.
--- If it is a string the items are sorted by that field (dot-paths like
--- `"file.name"` are supported).  `dir` may be `"asc"` (default) or `"desc"`.
---
--- Always returns a *new* PageArray; the original is not mutated.
---@param fn_or_field function|string
---@param dir string|nil  "asc" or "desc"
---@return table PageArray
function PageArray:sort(fn_or_field, dir)
  local copy = {}
  for i = 1, self._len do
    copy[#copy + 1] = rawget(self, i)
  end

  if type(fn_or_field) == "function" then
    table.sort(copy, fn_or_field)
  elseif type(fn_or_field) == "string" then
    local field = fn_or_field
    local descending = dir == "desc"
    table.sort(copy, function(a, b)
      local va = resolve_field(a, field)
      local vb = resolve_field(b, field)
      local cmp = types.compare(va, vb)
      if descending then
        return cmp > 0
      end
      return cmp < 0
    end)
  end

  return PageArray.new(copy)
end

--- Map each item through `fn` and return a plain Lua array (not a PageArray).
---@param fn function(item) -> any
---@return table
function PageArray:map(fn)
  local out = {}
  for i = 1, self._len do
    out[#out + 1] = fn(rawget(self, i))
  end
  return out
end

--- Map each item through `fn` (which must return a table) and concatenate all
--- results into a single flat array.
---@param fn function(item) -> table
---@return table
function PageArray:flatMap(fn)
  local out = {}
  for i = 1, self._len do
    local result = fn(rawget(self, i))
    if type(result) == "table" then
      for _, v in ipairs(result) do
        out[#out + 1] = v
      end
    end
  end
  return out
end

--- Return a new PageArray with at most `n` items.
---@param n number
---@return table PageArray
function PageArray:limit(n)
  local out = {}
  local count = math.min(n, self._len)
  for i = 1, count do
    out[#out + 1] = rawget(self, i)
  end
  return PageArray.new(out)
end

--- Return a slice from index `start` to `stop` (1-indexed, inclusive).
---@param start number
---@param stop number|nil  defaults to last item
---@return table PageArray
function PageArray:slice(start, stop)
  start = math.max(1, start or 1)
  stop = math.min(self._len, stop or self._len)
  local out = {}
  for i = start, stop do
    out[#out + 1] = rawget(self, i)
  end
  return PageArray.new(out)
end

--- Number of items.
---@return number
function PageArray:count()
  return self._len
end

--- First item, or nil.
function PageArray:first()
  return rawget(self, 1)
end

--- Last item, or nil.
function PageArray:last()
  if self._len == 0 then
    return nil
  end
  return rawget(self, self._len)
end

--- Return the raw underlying array.
---@return table
function PageArray:array()
  local out = {}
  for i = 1, self._len do
    out[#out + 1] = rawget(self, i)
  end
  return out
end

--- Alias for `:array()` (Dataview compatibility).
PageArray.values = PageArray.array

--- Group items by a key derived from each item.
---
--- If `fn_or_field` is a function it is called with each item and should
--- return the grouping key.  If it is a string the item's field (dot-path
--- supported) is used as the key.
---
--- Returns an array of `{ key = value, rows = PageArray }`.
---@param fn_or_field function|string
---@return table[]
function PageArray:groupBy(fn_or_field)
  local key_fn
  if type(fn_or_field) == "function" then
    key_fn = fn_or_field
  else
    local field = fn_or_field
    key_fn = function(item)
      return resolve_field(item, field)
    end
  end

  -- Preserve insertion order with a separate list of keys.
  local groups = {}
  local order = {}
  for i = 1, self._len do
    local item = rawget(self, i)
    local raw_key = key_fn(item)
    local k = tostring(raw_key or "")
    if not groups[k] then
      groups[k] = { key = raw_key, rows = {} }
      order[#order + 1] = k
    end
    local rows = groups[k].rows
    rows[#rows + 1] = item
  end

  local result = {}
  for _, k in ipairs(order) do
    local g = groups[k]
    g.rows = PageArray.new(g.rows)
    result[#result + 1] = g
  end
  return result
end

--- forEach -- iterate over items, calling `fn` on each.
---@param fn function(item, index)
function PageArray:forEach(fn)
  for i = 1, self._len do
    fn(rawget(self, i), i)
  end
end

-- ---------------------------------------------------------------------------
-- Source string parser
-- ---------------------------------------------------------------------------
-- Parses Dataview source strings like:
--   '"Projects"'
--   '"Projects" OR "Areas"'
--   '#tag'
--   '#tag AND "Folder"'
-- ---------------------------------------------------------------------------

--- Parse a single atomic source token starting at position `pos`.
---@param source string
---@param pos number
---@return table node, number new_pos
local function parse_atom(source, pos)
  -- Skip whitespace.
  pos = source:find("%S", pos) or (#source + 1)
  if pos > #source then
    return nil, pos
  end

  -- Quoted folder name: "FolderName"
  if source:sub(pos, pos) == '"' then
    local close = source:find('"', pos + 1, true)
    if not close then
      -- Unterminated quote -- take the rest of the string.
      local path = source:sub(pos + 1)
      return { type = "folder", path = vim.trim(path) }, #source + 1
    end
    local path = source:sub(pos + 1, close - 1)
    return { type = "folder", path = path }, close + 1
  end

  -- Tag: #tag or #tag/subtag
  if source:sub(pos, pos) == "#" then
    local tag_end = source:find("[%s%)]+", pos + 1) or (#source + 1)
    local tag = source:sub(pos + 1, tag_end - 1)
    return { type = "tag", tag = tag }, tag_end
  end

  -- Unrecognised token -- skip past it.
  local next_space = source:find("%s", pos) or (#source + 1)
  return nil, next_space
end

--- Parse a full source expression (supports OR / AND).
---@param source string
---@return table|nil  source_node tree
local function parse_source(source)
  if source == nil or source == "" then
    return nil
  end

  source = vim.trim(source)
  if source == "" then
    return nil
  end

  local left, pos = parse_atom(source, 1)
  if left == nil then
    return nil
  end

  while pos <= #source do
    -- Skip whitespace.
    pos = source:find("%S", pos) or (#source + 1)
    if pos > #source then
      break
    end

    -- Check for OR / AND keywords.
    local keyword = source:match("^(%a+)", pos)
    if keyword then
      local upper = keyword:upper()
      if upper == "OR" or upper == "AND" then
        pos = pos + #keyword
        local right
        right, pos = parse_atom(source, pos)
        if right then
          left = { type = upper:lower(), left = left, right = right }
        end
      else
        -- Unknown keyword, skip.
        pos = pos + #keyword
      end
    else
      break
    end
  end

  return left
end

-- ---------------------------------------------------------------------------
-- Ensure arrays within page objects are wrapped as PageArrays
-- ---------------------------------------------------------------------------

--- Recursively wrap known array fields in a page so that methods like
--- `:where()` are available on them (e.g. `page.file.tasks`).
---@param page table
---@return table  the same page, mutated
local function ensure_wrapped(page)
  if page == nil then
    return page
  end
  local file = page.file
  if file then
    if file.tasks and getmetatable(file.tasks) ~= PageArray then
      file.tasks = PageArray.new(file.tasks)
    end
    if file.lists and getmetatable(file.lists) ~= PageArray then
      file.lists = PageArray.new(file.lists)
    end
    if file.outlinks and getmetatable(file.outlinks) ~= PageArray then
      file.outlinks = PageArray.new(file.outlinks)
    end
    if file.inlinks and getmetatable(file.inlinks) ~= PageArray then
      file.inlinks = PageArray.new(file.inlinks)
    end
    if file.etags and getmetatable(file.etags) ~= PageArray then
      file.etags = PageArray.new(file.etags)
    end
    if file.tags and getmetatable(file.tags) ~= PageArray then
      file.tags = PageArray.new(file.tags)
    end
  end
  return page
end

--- Wrap every page in a list.
---@param pages table[]
---@return table[]
local function ensure_all_wrapped(pages)
  for _, p in ipairs(pages) do
    ensure_wrapped(p)
  end
  return pages
end

-- ---------------------------------------------------------------------------
-- Output collector
-- ---------------------------------------------------------------------------

local OutputCollector = {}
OutputCollector.__index = OutputCollector

function OutputCollector.new()
  return setmetatable({ _items = {} }, OutputCollector)
end

function OutputCollector:add(item)
  self._items[#self._items + 1] = item
end

--- Return the accumulated render items.
---@return table[]
function OutputCollector:get_results()
  return self._items
end

-- ---------------------------------------------------------------------------
-- Environment factory
-- ---------------------------------------------------------------------------

--- Create the sandboxed execution environment containing the `dv` API.
---
---@param index table        Index object (implements all_pages, resolve_source, etc.)
---@param current_file_path string  Absolute path of the file containing the code block.
---@return table env          The sandbox environment table.
---@return table output       OutputCollector with `:get_results()`.
function M.create_env(index, current_file_path)
  local output = OutputCollector.new()

  -- ----- dv object --------------------------------------------------------

  local dv = {}

  -- Query methods -----------------------------------------------------------

  --- Return a PageArray of pages matching `source`.
  --- `source` uses Dataview syntax: `'"Projects"'`, `'#tag'`,
  --- `'"A" OR "B"'`, or `nil` for all pages.
  ---@param source string|nil
  ---@return table PageArray
  function dv.pages(source)
    local pages
    if source == nil or vim.trim(source) == "" then
      pages = index:all_pages()
    else
      local node = parse_source(source)
      if node == nil then
        pages = index:all_pages()
      else
        pages = index:resolve_source(node)
      end
    end
    return PageArray.new(ensure_all_wrapped(pages))
  end

  --- Return the Page for the file that contains this query block.
  ---@return table|nil
  function dv.current()
    local page = index:current_page(current_file_path)
    if page then
      ensure_wrapped(page)
    end
    return page
  end

  --- Return a single Page by path (relative or bare filename).
  ---@param path string
  ---@return table|nil
  function dv.page(path)
    if type(path) ~= "string" then
      return nil
    end
    local page = index:get_page(path)
    if page then
      ensure_wrapped(page)
    end
    return page
  end

  -- Output methods ----------------------------------------------------------

  --- Render a table.
  ---@param headers string[]   Column headers.
  ---@param rows    table[]    Array of row arrays.
  function dv.table(headers, rows)
    if type(headers) ~= "table" then
      error("dv.table(): first argument must be a table of header strings", 2)
    end
    output:add({ type = "table", headers = headers, rows = rows or {} })
  end

  --- Render a bullet list.
  ---@param items table  Array of items (strings or any value).
  function dv.list(items)
    if type(items) ~= "table" then
      error("dv.list(): argument must be a table", 2)
    end
    output:add({ type = "list", items = items })
  end

  --- Render a paragraph of text.
  ---@param text string
  function dv.paragraph(text)
    output:add({ type = "paragraph", text = tostring(text) })
  end

  --- Render a header.
  ---@param level number  1--6
  ---@param text  string
  function dv.header(level, text)
    level = math.max(1, math.min(6, tonumber(level) or 1))
    output:add({ type = "header", level = level, text = tostring(text) })
  end

  --- Render a span (same as paragraph in terminal context).
  ---@param text string
  function dv.span(text)
    output:add({ type = "paragraph", text = tostring(text) })
  end

  --- Generic element -- treated as a paragraph.
  ---@param _tag    string  ignored (HTML tag name)
  ---@param content any
  function dv.el(_tag, content)
    output:add({ type = "paragraph", text = tostring(content) })
  end

  -- Utility methods ---------------------------------------------------------

  --- Parse a date string and return a Date object.
  ---
  --- Recognised inputs: `"today"`, `"tomorrow"`, `"yesterday"`,
  --- ISO dates like `"2026-02-18"`, etc.
  ---@param str string
  ---@return table|nil Date
  function dv.date(str)
    if type(str) ~= "string" then
      return nil
    end
    local lower = str:lower()
    if lower == "today" or lower == "now" then
      return types.Date.today()
    elseif lower == "tomorrow" then
      local d = types.Date.today()
      if d and d.add_days then
        return d:add_days(1)
      end
      return types.Date.parse(os.date("%Y-%m-%d", os.time() + 86400))
    elseif lower == "yesterday" then
      local d = types.Date.today()
      if d and d.add_days then
        return d:add_days(-1)
      end
      return types.Date.parse(os.date("%Y-%m-%d", os.time() - 86400))
    end
    return types.Date.parse(str)
  end

  --- Parse a duration string and return a Duration object.
  ---@param str string
  ---@return table|nil Duration
  function dv.dur(str)
    return types.Duration.parse(str)
  end

  --- Create a Link object.
  ---@param path    string
  ---@param embed   boolean|nil  default false
  ---@param display string|nil
  ---@return table Link
  function dv.file_link(path, embed, display)
    return types.Link.new(path, display, embed or false)
  end

  --- Create a Link (camelCase alias for Dataview compatibility).
  dv.fileLink = dv.file_link

  --- Compare two values and return -1, 0, or 1.
  ---@param a any
  ---@param b any
  ---@return number
  function dv.compare(a, b)
    return types.compare(a, b)
  end

  -- ----- sandbox environment -----------------------------------------------

  local env = {
    dv = dv,

    -- Standard Lua (safe subset) -------------------------------------------
    string    = string,
    table     = table,
    math      = math,
    os        = { date = os.date, time = os.time, clock = os.clock, difftime = os.difftime },
    tonumber  = tonumber,
    tostring  = tostring,
    type      = type,
    pairs     = pairs,
    ipairs    = ipairs,
    next      = next,
    select    = select,
    unpack    = unpack or table.unpack,
    pcall     = pcall,
    xpcall    = xpcall,
    error     = error,
    assert    = assert,
    rawget    = rawget,
    rawset    = rawset,
    setmetatable = setmetatable,
    getmetatable = getmetatable,

    -- Neovim utilities (curated) -------------------------------------------
    vim = {
      tbl_keys        = vim.tbl_keys,
      tbl_values      = vim.tbl_values,
      tbl_contains    = vim.tbl_contains,
      tbl_deep_extend = vim.tbl_deep_extend,
      tbl_map         = vim.tbl_map,
      tbl_filter      = vim.tbl_filter,
      split           = vim.split,
      trim            = vim.trim,
      startswith      = vim.startswith,
      endswith        = vim.endswith,
      inspect         = vim.inspect,
    },

    --- `print()` inside a code block appends a paragraph to the output.
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
      end
      dv.paragraph(table.concat(parts, "\t"))
    end,

    -- Built-in utility functions ---------------------------------------------

    --- Return true if `str` starts with `prefix`.
    ---@param str    string
    ---@param prefix string
    ---@return boolean
    startsWith = function(str, prefix)
      return vim.startswith(str, prefix)
    end,

    --- Return true if `str` ends with `suffix`.
    ---@param str    string
    ---@param suffix string
    ---@return boolean
    endsWith = function(str, suffix)
      return vim.endswith(str, suffix)
    end,

    --- Return a new list with duplicates removed (order preserved).
    ---@param list table
    ---@return table
    unique = function(list)
      local seen = {}
      local out = {}
      for _, v in ipairs(list) do
        local key = tostring(v)
        if not seen[key] then
          seen[key] = true
          out[#out + 1] = v
        end
      end
      return out
    end,

    --- Return the number of items in a list/table.
    ---@param list table
    ---@return number
    count = function(list)
      return #list
    end,
  }

  return env, output
end

-- ---------------------------------------------------------------------------
-- Convenience executor
-- ---------------------------------------------------------------------------

--- Compile and run a Lua code block in a sandboxed `dv` environment.
---
---@param code              string  Lua source code.
---@param index             table   Index object.
---@param current_file_path string  Absolute path of the containing file.
---@return table|nil results  Array of render items, or nil on error.
---@return string|nil err     Error message, or nil on success.
function M.execute_block(code, index, current_file_path)
  if type(code) ~= "string" or code == "" then
    return nil, "execute_block: code must be a non-empty string"
  end

  local env, output = M.create_env(index, current_file_path)

  -- Compile the code.
  local fn, compile_err = loadstring(code, "vault-query")
  if not fn then
    return nil, "Syntax error in vault query block:\n" .. tostring(compile_err)
  end

  -- Apply the sandbox.
  setfenv(fn, env)

  -- Execute.
  local ok, result_or_err = pcall(fn)
  if not ok then
    return nil, "Runtime error in vault query block:\n" .. tostring(result_or_err)
  end

  local results = output:get_results()

  -- If the code returned a value (e.g. inline `return expr`) and nothing
  -- was written to the output collector, wrap the return value as text.
  if #results == 0 and result_or_err ~= nil then
    results[1] = { type = "paragraph", text = tostring(result_or_err) }
  end

  return results, nil
end

-- ---------------------------------------------------------------------------
-- Expose PageArray for external use (e.g. by renderers or tests)
-- ---------------------------------------------------------------------------
M.PageArray = PageArray

-- Expose the source parser for testing.
M.parse_source = parse_source

return M
