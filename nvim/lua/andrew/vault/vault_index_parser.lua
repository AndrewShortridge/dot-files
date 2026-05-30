-- vault_index_parser.lua — Single-pass file parsing for vault index
-- Pure functions with no VaultIndex state dependency.
-- Only requires leaf utilities: slug, block_patterns, patterns, log.

local P = {}

local slug = require("andrew.vault.slug")
local block_patterns = require("andrew.vault.block_patterns")
local pat = require("andrew.vault.patterns")
local filter_utils = require("andrew.vault.filter_utils")
local date_utils = require("andrew.vault.date_utils")
local text_utils = require("andrew.vault.text_utils")
local log = require("andrew.vault.vault_log").scope("index.parser")

local is_iso_date = date_utils.is_iso_date

-- String intern pools for cross-entry deduplication.
-- FM keys like "type", "status" and tags like "project" repeat across notes;
-- interning shares one Lua string object instead of N identical copies.
local string_intern = require("andrew.vault.string_intern")
local _pools = {
  tags = string_intern.new(500),
  fm_keys = string_intern.new(200),
  fm_values = string_intern.new(2000),
  lowercase = string_intern.new(5000),
}

local function intern(s)
  if type(s) ~= "string" then return s end
  return string_intern.intern(_pools.fm_values, s)
end

local function intern_key(s)
  if type(s) ~= "string" then return s end
  return string_intern.intern(_pools.fm_keys, s)
end

local function intern_tag(s)
  return string_intern.intern(_pools.tags, s)
end

local function intern_lower(s)
  return string_intern.intern_lower(_pools.lowercase, s)
end

--- Strip surrounding single or double quotes from a string.
local function strip_quotes(s)
  if #s >= 2 and
    ((s:sub(1, 1) == '"' and s:sub(-1) == '"') or
     (s:sub(1, 1) == "'" and s:sub(-1) == "'")) then
    return s:sub(2, -2)
  end
  return s
end

--- Strip inline code spans from a single line.
--- Handles variable-length backtick delimiters: `, ``, ```, etc.
--- Replaces each code span with spaces of equal length to preserve byte offsets.
---@param line string
---@return string line with code spans replaced by spaces
local function strip_inline_code(line)
  local result = {}
  local pos = 1
  local len = #line

  while pos <= len do
    -- Count consecutive backticks at current position
    local bt_start = pos
    while pos <= len and line:sub(pos, pos) == "`" do
      pos = pos + 1
    end
    local bt_len = pos - bt_start

    if bt_len == 0 then
      -- Not a backtick: copy character as-is
      result[#result + 1] = line:sub(pos, pos)
      pos = pos + 1
    else
      -- We found bt_len backticks. Look for matching closing sequence.
      local closer = ("`"):rep(bt_len)
      local close_start = line:find(closer, pos, true)

      if close_start then
        -- Found matching closer: blank out the entire span (open + content + close)
        local span_len = (close_start + bt_len) - bt_start
        result[#result + 1] = (" "):rep(span_len)
        pos = close_start + bt_len
      else
        -- No matching closer: these backticks are literal text
        result[#result + 1] = line:sub(bt_start, bt_start + bt_len - 1)
        -- pos is already advanced past the backticks
      end
    end
  end

  return table.concat(result)
end

--- Strip fenced code blocks (multi-line) and inline code spans (single-line).
local function strip_code_blocks(text)
  local lines = {}
  local in_fence = false
  for line in text:gmatch(pat.LINE) do
    if pat.is_code_fence(line) then
      in_fence = not in_fence
      lines[#lines + 1] = ""
    elseif in_fence then
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = strip_inline_code(line)
    end
  end
  return table.concat(lines, "\n")
end

--- Split content into frontmatter and body.
local function split_frontmatter(content)
  if not content:match(pat.FM_OPEN_LINE) then
    return "", content
  end
  local _, fm_end = content:find(pat.FM_CLOSE, 4)
  if not fm_end then
    _, fm_end = content:find(pat.FM_CLOSE_EOF, 4)
    if not fm_end then
      return "", content
    end
  end
  local fm_start = content:find("\n", 1) + 1
  local fm_text = content:sub(fm_start, fm_end):gsub("\n%-%-%-\n?$", "")
  local body = content:sub(fm_end + 1)
  return fm_text, body
end

--- Parse YAML-like frontmatter into a table.
local function parse_frontmatter(text)
  if text == "" then return {} end
  local fields = {}
  local lines = vim.split(text, "\n", { plain = true })
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local key, value = line:match(pat.FM_KEY_VALUE)
    if key then
      value = vim.trim(value)
      if value == "" then
        local list = {}
        while i + 1 <= #lines and lines[i + 1]:match(pat.FM_LIST_ITEM_CHECK) do
          i = i + 1
          local item = lines[i]:match(pat.FM_LIST_ITEM)
          if item then
            local v = strip_quotes(vim.trim(item))
            v = intern(v)
            list[#list + 1] = v
          end
        end
        if #list > 0 then
          fields[intern_key(key)] = list
        end
      elseif value:sub(1, 1) == "[" and value:sub(-1) == "]" then
        -- Inline array
        local inner = value:sub(2, -2)
        local items = {}
        for item in inner:gmatch(pat.CSV_ITEM) do
          local v = strip_quotes(vim.trim(item))
          v = intern(v)
          if v ~= "" then
            items[#items + 1] = v
          end
        end
        fields[intern_key(key)] = items
      else
        value = strip_quotes(value)
        -- Booleans
        if value == "true" then value = true
        elseif value == "false" then value = false
        else
          local num = tonumber(value)
          if num then value = num end
        end
        fields[intern_key(key)] = intern(value)
      end
    end
    i = i + 1
  end
  return fields
end

--- Add a tag and all its parent segments to a set.
local function add_tag_with_parents(set, tag)
  set[intern_tag(tag)] = true
  local parent = tag
  while true do
    parent = parent:match(pat.PARENT_PATH)
    if not parent then break end
    set[intern_tag(parent)] = true
  end
end

--- Extract tags from frontmatter and body.
local function extract_tags(fm_fields, body)
  local tag_set = {}

  local fm_tags = fm_fields.tags
  if type(fm_tags) == "table" then
    for _, t in ipairs(fm_tags) do
      local tag = tostring(t):gsub("^#", "")
      add_tag_with_parents(tag_set, tag)
    end
  elseif type(fm_tags) == "string" then
    local tag = fm_tags:gsub("^#", "")
    add_tag_with_parents(tag_set, tag)
  end

  local clean_body = strip_code_blocks(body)
  for tag in clean_body:gmatch(pat.TAG) do
    if not tag:match("^%d+$") then
      add_tag_with_parents(tag_set, tag)
    end
  end

  local tags = {}
  for tag in pairs(tag_set) do
    tags[#tags + 1] = tag
  end
  table.sort(tags)
  return tags
end

--- Extract headings from content.
---@param content string Full content (used when lines not provided)
---@param lines? string[] Pre-split lines (avoids redundant vim.split)
local function extract_headings(content, lines)
  local headings = {}
  lines = lines or vim.split(content, "\n", { plain = true })
  for line_num, line in ipairs(lines) do
    local level_str, text = line:match(pat.HEADING)
    if text then
      text = text:gsub("%s+$", "")
      local hslug = slug.heading_to_slug(text)
      headings[#headings + 1] = {
        text = text,
        text_lower = intern_lower(text),
        slug = hslug,
        level = #level_str,
        line = line_num,
      }
    end
  end
  return headings
end

--- Extract block IDs from content with associated text and line numbers.
---@param content string Full content (used when lines not provided)
---@param lines? string[] Pre-split lines (avoids redundant vim.split)
---@return table[] Array of { id: string, text: string, line: number }
local function extract_block_ids(content, lines)
  return block_patterns.extract_from_content(content, lines)
end

--- Build a link entry with pre-computed lowercase fields.
local function make_link_entry(path, display, is_embed)
  local clean_display = display:match("^([^#]+)") or display
  local raw_name_lower = filter_utils.normalize_link_name(path) or ""
  local name_lower = string_intern.intern(_pools.lowercase, raw_name_lower)
  local stem_lower = string_intern.intern(_pools.lowercase, name_lower:gsub(pat.MD_EXTENSION, ""))
  local basename_lower = string_intern.intern(_pools.lowercase, stem_lower:match(pat.BASENAME) or stem_lower)
  return {
    path = path,
    display = vim.trim(clean_display),
    embed = is_embed,
    _name_lower = name_lower,
    stem_lower = stem_lower,
    basename_lower = basename_lower,
  }
end

--- Extract wikilinks and embeds from content.
local function extract_links(content)
  local links = {}
  local clean = strip_code_blocks(content)

  for line in clean:gmatch(pat.LINE_NONEMPTY) do
    pat.scan_all_links(line, function(inner, _, _, is_embed)
      inner = inner:gsub("\\|", "|")
      -- Skip inline fields (e.g. [[key:: value]]) for non-embeds
      if not is_embed and inner:match("^[%w_%-]+::") then return end
      local path, display = inner:match("^(.-)%|(.+)$")
      if not path then
        path = inner
        display = inner:match(pat.BASENAME) or inner
      end
      links[#links + 1] = make_link_entry(path, display, is_embed)
    end)
  end

  return links
end

--- Parse inline fields from task text.
--- Extracts [key:: value] and (key:: value) patterns and returns structured metadata.
---@param text string task text (everything after "- [x] ")
---@return table fields { due?, priority?, repeat_rule?, completion?, scheduled?, fields? }
local function parse_task_fields(text)
  local result = {}
  local extra = {}

  -- Strip inline code spans so fields inside backticks are ignored
  local clean = strip_inline_code(text)

  for key, value in clean:gmatch(pat.INLINE_FIELD_BRACKET) do
    local k = key:lower()
    value = vim.trim(value)

    if k == "due" then
      if is_iso_date(value) then
        result.due = value
      end
    elseif k == "priority" then
      local n = tonumber(value)
      if n then
        result.priority = n
      end
    elseif k == "repeat" then
      if value ~= "" then
        result.repeat_rule = value
      end
    elseif k == "completion" then
      if is_iso_date(value) then
        result.completion = value
      end
    elseif k == "scheduled" then
      if is_iso_date(value) then
        result.scheduled = value
      end
    else
      if value ~= "" then
        extra[k] = value
      end
    end
  end

  -- Also check (key:: value) parenthesized form
  for key, value in clean:gmatch(pat.INLINE_FIELD_PAREN) do
    local k = key:lower()
    value = vim.trim(value)
    if k == "due" and is_iso_date(value) then
      result.due = result.due or value
    elseif k == "priority" then
      result.priority = result.priority or tonumber(value)
    elseif k == "repeat" and value ~= "" then
      result.repeat_rule = result.repeat_rule or value
    elseif k == "completion" and is_iso_date(value) then
      result.completion = result.completion or value
    elseif k == "scheduled" and is_iso_date(value) then
      result.scheduled = result.scheduled or value
    elseif value ~= "" then
      extra[k] = extra[k] or value
    end
  end

  if next(extra) then
    result.fields = extra
  end

  return result
end

P.parse_task_fields = parse_task_fields

--- Extract tasks from body text.
---@param body string Body content (used when lines not provided)
---@param lines? string[] Pre-split lines (avoids redundant vim.split)
local function extract_tasks(body, lines)
  local tasks = {}
  lines = lines or vim.split(body, "\n", { plain = true })
  local in_code_fence = false

  for line_num, line in ipairs(lines) do
    if pat.is_code_fence(line) then
      in_code_fence = not in_code_fence
    end
    if in_code_fence then goto continue end

    local status_char = line:match(pat.TASK_DETECT)
    if status_char then
      local text = line:match(pat.TASK_TEXT)
      if text then
        local completed = (status_char == "x" or status_char == "X")
        local indent = #(line:match("^(%s*)") or "")
        local indent_level = math.floor(indent / 2)
        local task_tags = {}
        local clean_text = strip_inline_code(text)
        for tag in clean_text:gmatch(pat.TAG) do
          if not tag:match("^%d+$") then
            task_tags[#task_tags + 1] = intern_tag(tag)
          end
        end
        local task_meta = parse_task_fields(text)
        -- Build pre-lowered tag set for O(1) case-insensitive lookups
        local tags_lower = {}
        for _, tag in ipairs(task_tags) do
          tags_lower[intern_lower(tag)] = true
        end
        tasks[#tasks + 1] = {
          text = text,
          text_lower = text and intern_lower(text) or nil,
          status = status_char,
          completed = completed,
          line = line_num,
          indent_level = indent_level,
          tags = task_tags,
          tags_lower = tags_lower,
          due = task_meta.due,
          priority = task_meta.priority,
          repeat_rule = task_meta.repeat_rule,
          repeat_rule_lower = task_meta.repeat_rule and intern_lower(task_meta.repeat_rule) or nil,
          completion = task_meta.completion,
          scheduled = task_meta.scheduled,
          fields = task_meta.fields,
        }
      end
    end

    ::continue::
  end

  return tasks
end

--- Extract inline fields from body text.
local function extract_inline_fields(body)
  local fields = {}
  for line in body:gmatch(pat.LINE_NONEMPTY) do
    if line:match(pat.TASK_DETECT) then goto continue end
    -- Strip inline code spans so fields inside backticks are ignored
    local clean = strip_inline_code(line)
    for key, value in clean:gmatch(pat.INLINE_FIELD_STANDALONE_GMATCH) do
      if not key:match("^https?$") then
        fields[key] = vim.trim(value)
      end
    end
    for key, value in clean:gmatch(pat.INLINE_FIELD_BRACKET) do
      fields[key] = vim.trim(value)
    end
    for key, value in clean:gmatch(pat.INLINE_FIELD_PAREN) do
      fields[key] = vim.trim(value)
    end
    ::continue::
  end
  return fields
end

--- Extract aliases from parsed frontmatter fields.
---@param fm_fields table
---@return string[]
local function extract_aliases(fm_fields)
  local aliases = {}
  local raw_aliases = fm_fields.aliases
  if type(raw_aliases) == "table" then
    for _, a in ipairs(raw_aliases) do
      aliases[#aliases + 1] = intern_lower(tostring(a))
    end
  elseif type(raw_aliases) == "string" then
    aliases[#aliases + 1] = intern_lower(raw_aliases)
  end
  return aliases
end

--- Compute file-level identity fields from rel_path (immutable per file).
---@param rel_path string
---@return string rel_stem, string rel_stem_lower, string|nil day, number|nil day_ts
local function compute_file_identity(rel_path)
  local rel_stem = rel_path:gsub(pat.MD_EXTENSION, "")
  local rel_stem_lower = intern_lower(rel_stem)
  local basename = rel_path:match("([^/]+)%.md$") or rel_stem
  local day = basename:match(pat.ISO_DATE_PREFIX)
  local day_ts = day and date_utils.parse_iso_datetime(day) or nil
  return rel_stem, rel_stem_lower, day, day_ts
end

--- Extract created/modified timestamps from parsed frontmatter fields.
---@param fm_fields table
---@return number|nil created_ts, number|nil modified_ts
local function extract_timestamps(fm_fields)
  local created_ts = fm_fields.created
    and date_utils.parse_iso_datetime(tostring(fm_fields.created))
    or nil
  local modified_ts = fm_fields.modified
    and date_utils.parse_iso_datetime(tostring(fm_fields.modified))
    or nil
  return created_ts, modified_ts
end

--- Construct a VaultIndexEntry from components.
--- Single source of truth for the entry table shape.
---@param fields table Entry field values (rel_path, stat fields, parsed data, etc.)
---@return VaultIndexEntry
function P.make_entry(fields)
  return {
    rel_path = fields.rel_path,
    rel_stem = fields.rel_stem,
    rel_stem_lower = fields.rel_stem_lower,
    mtime = fields.mtime,
    size = fields.size,
    ctime = fields.ctime,
    frontmatter = fields.frontmatter,
    aliases = fields.aliases,
    tags = fields.tags,
    headings = fields.headings,
    block_ids = fields.block_ids,
    outlinks = fields.outlinks,
    tasks = fields.tasks,
    inline_fields = fields.inline_fields,
    day = fields.day,
    created_ts = fields.created_ts,
    modified_ts = fields.modified_ts,
    day_ts = fields.day_ts,
    content_hash = fields.content_hash,
    _chunks = fields._chunks,
  }
end

--- Parse frontmatter from content without parsing the body.
--- Lightweight alternative to parse_content() for when only FM fields are needed.
---@param content string Normalized file content
---@return table fm_fields, string[] aliases, number|nil created_ts, number|nil modified_ts
function P.parse_frontmatter_only(content)
  local fm_text = split_frontmatter(content)
  local fm_fields = parse_frontmatter(fm_text)
  local aliases = extract_aliases(fm_fields)
  local created_ts, modified_ts = extract_timestamps(fm_fields)
  return fm_fields, aliases, created_ts, modified_ts
end

--- Parse pre-read, normalized content into a VaultIndexEntry.
--- Avoids redundant file I/O when the caller already has the content.
---@param content string Normalized file content (line endings already handled)
---@param rel_path string
---@param stat table
---@return VaultIndexEntry
function P.parse_content(content, rel_path, stat)
  local fm_text, body = split_frontmatter(content)
  local fm_fields = parse_frontmatter(fm_text)
  local aliases = extract_aliases(fm_fields)

  local tags = extract_tags(fm_fields, body)
  local headings = extract_headings(content)
  local block_ids = extract_block_ids(content)
  local outlinks = extract_links(content)
  local tasks = extract_tasks(body)
  local inline_fields = extract_inline_fields(body)

  local rel_stem, rel_stem_lower, day, day_ts = compute_file_identity(rel_path)
  local created_ts, modified_ts = extract_timestamps(fm_fields)

  -- Derived fields (abs_path, basename, basename_lower, folder, tag_set,
  -- heading_slugs, block_id_set) are NOT stored here — they are computed
  -- lazily via __index metatable set by vault_index.lua.
  return P.make_entry({
    rel_path = rel_path,
    rel_stem = rel_stem,
    rel_stem_lower = rel_stem_lower,
    mtime = stat.mtime.sec,
    size = stat.size,
    ctime = stat.birthtime and stat.birthtime.sec or nil,
    frontmatter = fm_fields,
    aliases = aliases,
    tags = tags,
    headings = headings,
    block_ids = block_ids,
    outlinks = outlinks,
    tasks = tasks,
    inline_fields = inline_fields,
    day = day,
    created_ts = created_ts,
    modified_ts = modified_ts,
    day_ts = day_ts,
  })
end

--- Expose compute_file_identity for use by build module.
P.compute_file_identity = compute_file_identity

--- Read and normalize a file's content.
--- Shared I/O helper used by parse_file() and vault_index_build's parse_file_chunked().
---@param abs_path string
---@return string|nil content Normalized content, or nil on failure
---@return string|nil err Error message on failure
function P.read_file(abs_path)
  local f, io_err = io.open(abs_path, "r")
  if not f then
    log.debug("cannot open: %s: %s", abs_path, io_err or "unknown")
    return nil, "cannot open " .. abs_path .. ": " .. (io_err or "unknown")
  end
  local content = f:read("*a")
  f:close()
  if not content then
    return nil, "read returned nil for " .. abs_path
  end
  return text_utils.normalize_line_endings(content)
end

--- Parse a single file into a VaultIndexEntry.
---@param abs_path string
---@param rel_path string
---@param stat table
---@return VaultIndexEntry|nil
---@return string|nil err
function P.parse_file(abs_path, rel_path, stat)
  local content, err = P.read_file(abs_path)
  if not content then
    return nil, err
  end
  return P.parse_content(content, rel_path, stat)
end

--- Parse a chunk of lines into partial entry data (headings, block_ids, outlinks, tasks, inline_fields, tags).
--- Line numbers in the returned data are file-absolute (offset by start_line).
--- Reuses the same extract_* functions as parse_file() and applies line offsets to results.
---@param chunk_lines string[] Lines within this chunk
---@param start_line number 1-indexed first line of this chunk in the original file
---@param fm_fields table|nil Parsed frontmatter fields (only passed for frontmatter chunk)
---@return table parsed_data { headings, block_ids, outlinks, tasks, inline_fields, tags }
function P.parse_chunk(chunk_lines, start_line, fm_fields)
  -- Join once for gmatch-based extractors (links, tags, inline_fields).
  -- Pass chunk_lines directly to line-based extractors to avoid re-splitting.
  local content = table.concat(chunk_lines, "\n")
  local line_offset = start_line - 1

  -- Line-based extractors: pass pre-split chunk_lines to avoid redundant vim.split
  local headings = extract_headings(content, chunk_lines)
  if line_offset > 0 then
    for _, h in ipairs(headings) do
      h.line = h.line + line_offset
    end
  end

  local block_ids = extract_block_ids(content, chunk_lines)
  if line_offset > 0 then
    for _, b in ipairs(block_ids) do
      b.line = b.line + line_offset
    end
  end

  -- gmatch-based extractors: use content string
  local outlinks = extract_links(content)

  -- Determine body: frontmatter chunks have no body
  local body = fm_fields and "" or content
  local body_lines = fm_fields and nil or chunk_lines

  local tags = extract_tags(fm_fields or {}, body)

  local tasks = {}
  if body ~= "" then
    tasks = extract_tasks(body, body_lines)
    if line_offset > 0 then
      for _, t in ipairs(tasks) do
        t.line = t.line + line_offset
      end
    end
  end

  local inline_fields = body ~= "" and extract_inline_fields(body) or {}

  return {
    headings = headings,
    block_ids = block_ids,
    outlinks = outlinks,
    tasks = tasks,
    inline_fields = inline_fields,
    tags = tags,
  }
end

--- Reset all string intern pools (called on full index rebuild).
function P.reset_intern_pool()
  for _, pool in pairs(_pools) do
    string_intern.clear(pool)
    string_intern.reset_stats(pool)
  end
end

--- Return stats for all intern pools (for debug display).
--- @return table<string, table>
function P.intern_pool_stats()
  local stats = {}
  for name, pool in pairs(_pools) do
    stats[name] = string_intern.stats(pool)
  end
  return stats
end

--- Configure intern pool capacities from config values.
--- @param opts table { tag_pool_max?, fm_key_pool_max?, fm_value_pool_max?, lowercase_pool_max? }
function P.configure_pools(opts)
  if opts.tag_pool_max then _pools.tags._max = opts.tag_pool_max end
  if opts.fm_key_pool_max then _pools.fm_keys._max = opts.fm_key_pool_max end
  if opts.fm_value_pool_max then _pools.fm_values._max = opts.fm_value_pool_max end
  if opts.lowercase_pool_max then _pools.lowercase._max = opts.lowercase_pool_max end
end

return P
