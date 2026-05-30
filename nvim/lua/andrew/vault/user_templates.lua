local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")
local pickers = require("andrew.vault.pickers")
local notify = require("andrew.vault.notify")
local sort_utils = require("andrew.vault.sort_utils")
local pat = require("andrew.vault.patterns")

local M = {}

-- Cache of parsed user templates, keyed by vault_path.
-- Each entry is { templates = {...}, mtime = number }.
---@type table<string, { templates: UserTemplate[], dir_mtime: number }>
M._cache = {}
local _cache_hits = 0
local _cache_misses = 0
local _cache_evictions = 0

-- =============================================================================
-- Types
-- =============================================================================

---@class UserTemplatePrompt
---@field key string           Variable name for {{key}} substitution
---@field prompt string        Prompt text shown to user
---@field type? string         "input"|"select"|"project"|"area"|"domain" (default: "input")
---@field options? string[]    Options for type="select"
---@field default? string      Default value for type="input"

---@class UserTemplate
---@field name string                Display name in picker
---@field desc? string               Description shown in picker
---@field dest? string               Destination dir (supports {{var}} interpolation)
---@field filename? string           Output filename (supports {{var}} interpolation)
---@field template_type string       "note" or "insert"
---@field prompts UserTemplatePrompt[]
---@field note_frontmatter? table    YAML frontmatter to prepend to rendered note
---@field body string                Template body (raw markdown with {{var}} placeholders)
---@field source_path string         Absolute path to the .md template file

-- =============================================================================
-- Parsing
-- =============================================================================

--- Build a UserTemplate struct from parsed metadata and body.
---@param abs_path string
---@param meta table
---@param body string
---@return UserTemplate
local function build_template(abs_path, meta, body)
  local basename = link_utils.get_basename(abs_path)

  -- Build prompts list
  local prompts = {}
  if meta.prompts and type(meta.prompts) == "table" then
    for _, p in ipairs(meta.prompts) do
      if type(p) == "table" and p.key and p.prompt then
        prompts[#prompts + 1] = {
          key = tostring(p.key),
          prompt = tostring(p.prompt),
          type = p.type and tostring(p.type) or "input",
          options = p.options,
          default = p.default and tostring(p.default) or nil,
        }
      end
    end
  end

  -- If no prompts declared but body contains {{title}}, auto-add a title prompt
  if #prompts == 0 and body:find("{{title}}") then
    prompts[#prompts + 1] = {
      key = "title",
      prompt = "Note title",
      type = "input",
    }
  end

  return {
    name = meta.template_name or basename,
    desc = meta.template_desc,
    dest = meta.template_dest,
    filename = meta.template_filename or "{{title}}",
    template_type = meta.template_type or "note",
    prompts = prompts,
    note_frontmatter = meta.frontmatter,
    body = body,
    source_path = abs_path,
  }
end

--- Parse a user template .md file into a UserTemplate struct.
---@param abs_path string  Absolute path to the template .md file
---@return UserTemplate|nil
function M.parse_template(abs_path)
  local raw = engine.read_file(abs_path)
  if not raw or raw == "" then
    return nil
  end

  -- Try to parse YAML frontmatter
  local body = raw

  local fm_start, fm_end = raw:find(pat.FM_OPEN_LINE)
  if fm_start then
    local close_start, close_end = raw:find(pat.FM_CLOSE, fm_end)
    if not close_start then
      -- Try end-of-file close (no trailing newline after ---)
      close_start, close_end = raw:find(pat.FM_CLOSE_EOF, fm_end)
    end
    if close_start then
      local yaml_str = raw:sub(fm_end + 1, close_start - 1)
      body = raw:sub(close_end + 1)
      -- Strip leading blank line from body
      body = body:gsub("^\n", "")

      local meta = M._parse_template_yaml(yaml_str)
      return build_template(abs_path, meta or {}, body)
    end
  end

  -- No frontmatter found
  return build_template(abs_path, {}, body)
end

--- Minimal YAML parser for template frontmatter.
--- Handles the subset of YAML used in template metadata: scalars, lists, maps.
--- This avoids depending on external YAML libraries.
---@param yaml_str string
---@return table
function M._parse_template_yaml(yaml_str)
  -- Strategy: try vim.system with yq first (fast, correct).
  -- If yq is not available, fall back to the simple line parser.

  if vim.fn.executable("yq") == 1 then
    local result = vim.system(
      { "yq", "-o", "json", "." },
      { stdin = yaml_str, text = true }
    ):wait()
    if result.code == 0 and result.stdout and result.stdout ~= "" then
      local ok, parsed = pcall(vim.json.decode, result.stdout)
      if ok and type(parsed) == "table" then
        return parsed
      end
    end
    -- yq failed or returned bad data — fall back to simple parser
    return M._parse_yaml_simple(yaml_str)
  end

  -- Fallback: minimal line-based parser for flat fields + simple lists
  return M._parse_yaml_simple(yaml_str)
end

--- Simple line-based YAML parser sufficient for template metadata.
--- Handles: scalar fields, simple lists (- item), nested maps (one level).
--- Does NOT handle: multi-line strings, anchors, aliases, complex nesting.
---@param yaml_str string
---@return table
function M._parse_yaml_simple(yaml_str)
  local result = {}
  local current_key = nil
  local current_list = nil
  local current_map = nil
  local current_map_list = nil

  for line in (yaml_str .. "\n"):gmatch("([^\n]*)\n") do -- variant of pat.LINE_WITH_NEWLINE (newline required, not optional)
    -- Skip comments and blank lines
    if line:match("^%s*#") or line:match("^%s*$") then
      goto continue
    end

    local indent = #(line:match("^(%s*)") or "")

    -- Top-level key: value
    if indent == 0 then
      -- Close any open list/map
      if current_list and current_key then
        result[current_key] = current_list
        current_list = nil
      end
      if current_map_list and current_key then
        result[current_key] = current_map_list
        current_map_list = nil
      end
      current_map = nil

      local key, value = line:match(pat.FM_KEY_VALUE)
      if key then
        current_key = key
        value = vim.trim(value)
        if value == "" then
          -- Could be start of a list or map — wait for next lines
        elseif value:match("^%[") then
          -- Inline list: [a, b, c]
          local items = {}
          for item in value:gmatch(pat.CSV_ITEM_COMPLEX) do
            item = vim.trim(item)
            if item ~= "" then
              items[#items + 1] = item
            end
          end
          result[key] = items
          current_key = nil
        else
          -- Remove surrounding quotes if present
          value = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          result[key] = value
          current_key = nil
        end
      end
    elseif indent >= 2 and current_key then
      local trimmed = vim.trim(line)

      -- List item with map value (prompts list): "- key: value"
      if trimmed:match("^%- %w") then
        local after_dash = trimmed:sub(3)
        local k, v = after_dash:match("^([%w_%-]+):%s*(.*)")
        if k then
          -- Start of a new map entry in a list
          if not current_map_list then
            current_map_list = {}
          end
          current_map = { [k] = vim.trim(v):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1") }
          current_map_list[#current_map_list + 1] = current_map
        else
          -- Simple list item: "- value"
          if not current_list then
            current_list = {}
          end
          local val = trimmed:sub(3)
          val = val:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          current_list[#current_list + 1] = val
        end
      elseif current_map then
        -- Continuation of map entry (nested key: value under a list item)
        local k, v = trimmed:match("^([%w_%-]+):%s*(.*)")
        if k then
          v = vim.trim(v)
          -- Handle inline list in map value: options: ["a", "b"]
          if v:match("^%[") then
            local items = {}
            for item in v:gmatch(pat.CSV_ITEM_COMPLEX) do
              item = vim.trim(item)
              if item ~= "" then
                items[#items + 1] = item
              end
            end
            current_map[k] = items
          else
            current_map[k] = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          end
        end
      elseif not current_list then
        -- Could be a nested map (frontmatter field)
        local k, v = trimmed:match("^([%w_%-]+):%s*(.*)")
        if k then
          if not result[current_key] or type(result[current_key]) ~= "table" then
            result[current_key] = {}
          end
          v = vim.trim(v)
          if v ~= "" then
            result[current_key][k] = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          end
        elseif trimmed:match("^%- ") then
          -- List under a map key
          if not result[current_key] or type(result[current_key]) ~= "table" then
            result[current_key] = {}
          end
          -- If it's a list (not a map), convert
          if not result[current_key][1] then
            -- Check if it's already a map by looking for string keys
            local has_string_keys = false
            for rk, _ in pairs(result[current_key]) do
              if type(rk) == "string" then has_string_keys = true; break end
            end
            if has_string_keys then
              -- Mixed map + list not supported; skip
              goto continue
            end
          end
          local val = trimmed:sub(3):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          result[current_key][#result[current_key] + 1] = val
        end
      end
    end

    ::continue::
  end

  -- Close any trailing list/map
  if current_list and current_key then
    result[current_key] = current_list
  end
  if current_map_list and current_key then
    result[current_key] = current_map_list
  end

  return result
end

-- =============================================================================
-- Template Directory Scanning
-- =============================================================================

--- Get the absolute path to the user templates directory for the current vault.
---@return string
function M.templates_dir()
  return engine.vault_path .. "/" .. config.user_templates.dir
end

--- Scan the vault's templates directory and return parsed UserTemplate objects.
--- Results are cached per vault; cache is invalidated when the directory mtime changes.
---@return UserTemplate[]
function M.list()
  if not config.user_templates.enabled then
    return {}
  end

  local dir = M.templates_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  -- Check directory mtime for cache invalidation
  local stat = vim.uv.fs_stat(dir)
  local dir_mtime = stat and stat.mtime.sec or 0

  local cached = M._cache[engine.vault_path]
  if cached and cached.dir_mtime == dir_mtime then
    _cache_hits = _cache_hits + 1
    return cached.templates
  end
  _cache_misses = _cache_misses + 1
  if cached then _cache_evictions = _cache_evictions + 1 end

  -- Scan directory for .md files
  local entries = {}
  local handle = vim.uv.fs_scandir(dir)
  if handle then
    while true do
      local name, _ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      entries[#entries + 1] = name
    end
  end
  local md_names = {}
  for _, name in ipairs(entries) do
    if name:match(pat.MD_EXTENSION) then
      md_names[#md_names + 1] = name
    end
  end

  if #md_names == 0 then
    M._cache[engine.vault_path] = { templates = {}, dir_mtime = dir_mtime }
    return {}
  end

  local templates = {}

  for _, name in ipairs(md_names) do
    local abs_path = dir .. "/" .. name
    local tpl = M.parse_template(abs_path)
    if tpl then
      templates[#templates + 1] = tpl
    end
  end

  sort_utils.sort_by_name(templates)
  M._cache[engine.vault_path] = {
    templates = templates,
    dir_mtime = dir_mtime,
  }
  return templates
end

--- Force-reload the user template cache for the current vault.
function M.reload()
  M._cache[engine.vault_path] = nil
  local templates = M.list()
  notify.info("reloaded " .. #templates .. " user template(s) from " .. config.user_templates.dir .. "/")
end

-- =============================================================================
-- Template Execution
-- =============================================================================

--- Collect prompt values from the user for a user template.
--- Must be called from within engine.run() (coroutine context).
---@param template UserTemplate
---@return table<string, string>|nil  vars table, or nil if user cancelled
function M.collect_prompts(template)
  local vars = {}

  for _, p in ipairs(template.prompts) do
    local value

    if p.type == "select" and p.options then
      value = engine.select(p.options, { prompt = p.prompt })
    elseif p.type == "project" then
      value = pickers.project(engine)
    elseif p.type == "area" then
      value = pickers.area(engine)
    elseif p.type == "domain" then
      value = pickers.domain(engine)
    else
      -- Default: text input
      value = engine.input({ prompt = p.prompt, default = p.default or "" })
    end

    if value == nil then
      -- User cancelled
      return nil
    end

    -- project_or_none returns false for "None" — convert to empty string
    if value == false then
      value = ""
    end

    vars[p.key] = tostring(value)
  end

  return vars
end

--- Build the output frontmatter YAML string from the template's frontmatter map.
--- Supports {{variable}} interpolation in values.
---@param fm_map table  The note_frontmatter field from the template
---@param vars table    Variable values for interpolation
---@return string
function M.build_frontmatter(fm_map, vars)
  local lines = { "---" }

  for key, value in pairs(fm_map) do
    if type(value) == "table" then
      -- List value
      lines[#lines + 1] = key .. ":"
      for _, item in ipairs(value) do
        local rendered = engine.substitute(tostring(item), vars)
        lines[#lines + 1] = "  - " .. rendered
      end
    else
      local rendered = engine.substitute(tostring(value), vars)
      lines[#lines + 1] = key .. ": " .. rendered
    end
  end

  lines[#lines + 1] = "---"
  return table.concat(lines, "\n") .. "\n"
end

--- Run a user template to create a new note.
--- Must be called from within engine.run() (coroutine context).
---@param template UserTemplate
function M.run_note(template)
  local vars = M.collect_prompts(template)
  if not vars then return end

  -- Add built-in date variable for convenience
  vars.date = vars.date or engine.today()

  -- Build frontmatter
  local fm_str = ""
  if template.note_frontmatter then
    fm_str = M.build_frontmatter(template.note_frontmatter, vars)
  end

  -- Render body
  local rendered_body = engine.substitute(template.body, vars)

  -- Compute destination
  local dest_dir = template.dest
  if dest_dir then
    dest_dir = engine.substitute(dest_dir, vars)
  end

  local filename = engine.substitute(template.filename or "{{title}}", vars)
  -- Sanitize filename
  filename = filename:gsub(":", " -"):gsub("/", "-"):gsub("[%*%?|<>]", "")

  local rel_path
  if dest_dir and dest_dir ~= "" then
    rel_path = dest_dir .. "/" .. filename
  else
    rel_path = filename
  end

  -- Combine frontmatter + body
  local content = fm_str
  if fm_str ~= "" and not rendered_body:match("^\n") then
    content = content .. "\n"
  end
  content = content .. rendered_body

  engine.write_note(rel_path, content)
end

--- Run a user template in "insert" mode — inserts rendered body at cursor.
--- Must be called from within engine.run() (coroutine context).
---@param template UserTemplate
function M.run_insert(template)
  local vars = M.collect_prompts(template)
  if not vars then return end

  vars.date = vars.date or engine.today()

  -- Render body
  local rendered = engine.substitute(template.body, vars)

  -- Split into lines and insert at cursor
  local lines = vim.split(rendered, "\n", { plain = true })

  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, row, row, false, lines)

  -- Move cursor to first non-empty inserted line
  for idx, line in ipairs(lines) do
    if line ~= "" then
      vim.api.nvim_win_set_cursor(0, { row + idx, #line })
      break
    end
  end

  notify.info("inserted template " .. template.name)
end

--- Run a user template (dispatches based on template_type).
--- Must be called from within engine.run() (coroutine context).
---@param template UserTemplate
function M.run(template)
  if template.template_type == "insert" then
    M.run_insert(template)
  else
    M.run_note(template)
  end
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup()
  -- Commands and palette registrations are in init.lua (lazy stubs).

  -- Register with cache registry for automatic invalidation
  engine.register_cache({
    name = "user_templates",
    module = "andrew.vault.user_templates",
    invalidate = function()
      for _ in pairs(M._cache) do _cache_evictions = _cache_evictions + 1 end
      M._cache = {}
    end,
    invalidate_file = function(abs_path)
      local dir = M.templates_dir()
      if vim.startswith(abs_path, dir) then
        if M._cache[engine.vault_path] then _cache_evictions = _cache_evictions + 1 end
        M._cache[engine.vault_path] = nil
      end
    end,
    stats = function()
      local cached = M._cache[engine.vault_path]
      return {
        entries = cached and #cached.templates or 0,
        vault = engine.vault_path,
      }
    end,
  })

  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "user_templates",
      get_size = function()
        local cached = M._cache[engine.vault_path]
        return cached and #cached.templates or 0
      end,
      get_capacity = function() return nil end,
      get_hits = function() return _cache_hits end,
      get_misses = function() return _cache_misses end,
      get_evictions = function() return _cache_evictions end,
    })
  end
end

return M
