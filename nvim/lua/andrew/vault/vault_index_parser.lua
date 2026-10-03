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
  -- Fast path: a line with no backtick has no inline-code span to strip, so it
  -- is returned verbatim. This skips the per-character scan below for the ~60%
  -- of lines that contain no backtick (byte-identical result — the char loop
  -- would copy each char unchanged anyway). find(..., plain) is a single C-side
  -- memchr; far cheaper than building a result table char-by-char.
  if not line:find("`", 1, true) then return line end

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

--- Strip fenced code blocks (multi-line) and inline code spans (single-line),
--- returning the canonical one-entry-per-line stripped representation.
--- Fenced lines (and the fence delimiters themselves) become "".
--- This is the single shared primitive: callers compute it ONCE per parse and
--- pass the array to extract_tags/extract_links (and the task-tag sub-scan) so
--- they iterate pre-stripped lines instead of re-stripping the whole content.
--- (extract_inline_fields is intentionally NOT fence-aware and strips per-line
--- itself, so it does not consume this array.)
--- Takes the already-split raw line array (callers split content/body once for
--- the line-based extractors anyway, so reusing it avoids a redundant
--- vim.split). The result is one stripped entry per source line, fence lines
--- (and fence delimiters) emptied — byte-identical to splitting the joined
--- stripped string but without re-emitting a trailing empty match.
---@param raw_lines string[] Raw source lines (one entry per source line)
---@return string[] stripped lines (one entry per source line)
local function strip_code_blocks_lines(raw_lines)
  local lines = {}
  local in_fence = false
  for _, line in ipairs(raw_lines) do
    if pat.is_code_fence(line) then
      in_fence = not in_fence
      lines[#lines + 1] = ""
    elseif in_fence then
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = strip_inline_code(line)
    end
  end
  return lines
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
---@param fm_fields table
---@param stripped_body_lines string[] Body lines, code-stripped once by caller.
local function extract_tags(fm_fields, stripped_body_lines)
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

  -- Tags are line-local (never span lines), so scanning each pre-stripped line
  -- is byte-identical to scanning the joined stripped string.
  for _, line in ipairs(stripped_body_lines) do
    for pos, tag in line:gmatch(pat.TAG) do
      -- Left-boundary check: rejects the '#' inside [[Note#Heading]],
      -- ![[Note#Details]] and https://x.com#frag (phantom tags).
      if pat.tag_boundary_ok(line, pos) and not tag:match("^%d+$") then
        add_tag_with_parents(tag_set, tag)
      end
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
---@param stripped_content_lines string[] Content lines, code-stripped once by caller.
local function extract_links(stripped_content_lines)
  local links = {}

  -- Skip empty stripped lines to exactly mirror the prior gmatch(LINE_NONEMPTY)
  -- behavior. Wikilinks/embeds are line-local, so per-line scanning matches.
  for _, line in ipairs(stripped_content_lines) do
    if line ~= "" then
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
---@param lines? string[] Pre-split RAW lines (avoids redundant vim.split)
---@param stripped_lines? string[] Body lines, code-stripped once by caller (for tag sub-scan)
local function extract_tasks(body, lines, stripped_lines)
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
        -- Tag sub-scan: reuse the pre-stripped body line (the "- [x] " prefix
        -- contains no #tags, so a stripped full-line yields the same tags as the
        -- prior strip_inline_code(text)). Fall back to stripping text if the
        -- caller did not supply stripped lines.
        local clean_text = stripped_lines and stripped_lines[line_num]
          or strip_inline_code(text)
        for pos, tag in clean_text:gmatch(pat.TAG) do
          -- Same left-boundary check as the body-tag scan above.
          if pat.tag_boundary_ok(clean_text, pos) and not tag:match("^%d+$") then
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

--- Accumulate a page-level inline field value under a key.
--- Scalar-or-list shape (mirrors frontmatter): first occurrence stores the
--- trimmed string scalar; second+ occurrence promotes to an array (document
--- order, duplicates kept). Keys are case-preserved.
---@param fields table
---@param key string
---@param value string raw (untrimmed) value
local function add_field(fields, key, value)
  local v = vim.trim(value)
  local existing = fields[key]
  if existing == nil then
    fields[key] = v
  elseif type(existing) == "table" then
    existing[#existing + 1] = v
  else
    -- Promote scalar -> list, preserving the first value's position.
    fields[key] = { existing, v }
  end
end

--- Extract inline fields from body text.
--- NOTE: this extractor is deliberately NOT fence-aware. It strips only inline
--- code spans per line (via strip_inline_code), so a `key:: value` written
--- inside a fenced ``` / ~~~ code block IS still extracted — matching the
--- historical behavior. It therefore does NOT consume the shared fence-aware
--- stripped_body_lines (which blanks whole fenced regions).
---@param raw_body_lines string[] Raw body lines
local function extract_inline_fields(raw_body_lines)
  local fields = {}
  for i = 1, #raw_body_lines do
    local raw = raw_body_lines[i]
    -- Mirror the prior gmatch(LINE_NONEMPTY): empty lines yield nothing.
    if raw == "" then goto continue end
    -- TASK_DETECT runs on the RAW line (the "- [ ]" prefix is never inside
    -- backticks, but matching raw preserves today's semantics exactly).
    if raw:match(pat.TASK_DETECT) then goto continue end
    -- Strip inline code spans so fields inside backticks are ignored (per-line,
    -- NOT fence-aware — see function note).
    local clean = strip_inline_code(raw)
    -- Standalone (whole-line) field: `key:: value` at the start of the line
    -- (after optional list marker / indentation), at most one per line. Anchored
    -- so prose containing bracket/paren fields (e.g. "see [genre:: rock]") is not
    -- mis-captured as a standalone value swallowing the rest of the line.
    local skey, sval = clean:match("^%s*[-*]?%s*([%w_%-]+)::%s*(.-)%s*$")
    if skey and not skey:match("^https?$") then
      add_field(fields, skey, sval)
    end
    for key, value in clean:gmatch(pat.INLINE_FIELD_BRACKET) do
      add_field(fields, key, value)
    end
    for key, value in clean:gmatch(pat.INLINE_FIELD_PAREN) do
      add_field(fields, key, value)
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
--- When old_entry is supplied, each named field falls back to old_entry[k]
--- when fields[k] is nil (explicit nil check, NOT `or`, to respect a caller
--- that intentionally sets a value). This lets entry_from_old pass only its
--- stat updates + overrides without first shallow-copying old_entry, and — by
--- enumerating only these stored keys — never forwards the lazy metatable-
--- derived keys (abs_path, tag_set, basename, …) that _apply_entry_mt
--- recomputes. Single-arg calls (parse_content) read fields[k] verbatim.
---@param fields table Entry field values (rel_path, stat fields, parsed data, etc.)
---@param old_entry table|nil Prior entry to inherit unset named fields from
---@return VaultIndexEntry
function P.make_entry(fields, old_entry)
  local function pick(k)
    local v = fields[k]
    if v ~= nil then return v end
    return old_entry and old_entry[k] or nil
  end
  return {
    rel_path = pick("rel_path"),
    rel_stem = pick("rel_stem"),
    rel_stem_lower = pick("rel_stem_lower"),
    mtime = pick("mtime"),
    size = pick("size"),
    ctime = pick("ctime"),
    frontmatter = pick("frontmatter"),
    aliases = pick("aliases"),
    tags = pick("tags"),
    headings = pick("headings"),
    block_ids = pick("block_ids"),
    outlinks = pick("outlinks"),
    tasks = pick("tasks"),
    inline_fields = pick("inline_fields"),
    day = pick("day"),
    created_ts = pick("created_ts"),
    modified_ts = pick("modified_ts"),
    day_ts = pick("day_ts"),
    content_hash = pick("content_hash"),
    _chunks = pick("_chunks"),
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

  -- Split once per slice and share the arrays across the line-based extractors,
  -- instead of each extractor splitting internally (content was split twice
  -- today — once for headings, once for block_ids). The boundary is load-
  -- bearing: heading/block_id line numbers are 1-indexed into FULL content
  -- (frontmatter included), while extract_tasks() numbers relative to the body
  -- (normalised to file-absolute just below). So content_lines and body_lines
  -- must NOT be swapped between extractors.
  local content_lines = vim.split(content, "\n", { plain = true })
  local body_lines = vim.split(body, "\n", { plain = true })

  -- Compute the code-stripped, line-split representation ONCE per parse, then
  -- share it with the fence-aware line-based extractors instead of each
  -- re-stripping. The content-vs-body boundary is load-bearing: stripped
  -- CONTENT lines feed links, stripped BODY lines feed tags/task-tags. Never
  -- swap them. (Inline fields are NOT fence-aware and strip per-line on their
  -- own — they do not consume the shared array.)
  --
  -- body is a strict line-suffix of content (split_frontmatter slices on a
  -- \n---\n boundary), so the stripped body is just the tail of the stripped
  -- content. Alias when there is no frontmatter (body == content, parse_chunk's
  -- non-FM trick), otherwise slice off the leading offset frontmatter lines.
  -- This is byte-identical to a separate strip(body_lines) for all real
  -- frontmatter: the YAML delimiter `---` is not a code fence, so the FM region
  -- never toggles fence state.
  local stripped_content_lines = strip_code_blocks_lines(content_lines)
  local offset = #content_lines - #body_lines
  local stripped_body_lines
  if offset == 0 then
    stripped_body_lines = stripped_content_lines
  else
    stripped_body_lines = {}
    for i = offset + 1, #stripped_content_lines do
      stripped_body_lines[#stripped_body_lines + 1] = stripped_content_lines[i]
    end
  end

  local tags = extract_tags(fm_fields, stripped_body_lines)
  local headings = extract_headings(content, content_lines)
  local block_ids = extract_block_ids(content, content_lines)
  local outlinks = extract_links(stripped_content_lines)
  local tasks = extract_tasks(body, body_lines, stripped_body_lines)
  -- extract_tasks() numbers lines relative to `body`, but every other entry
  -- field is file-absolute (headings, block_ids) and so are the task lines
  -- produced by parse_chunk() below -- one index must not carry two
  -- conventions. Normalise here so every consumer gets a real file line: task
  -- pickers/previews (tasks.lua, task_notify.lua), :VaultOverdue, kanban
  -- <CR>/m/M (set_task_status silently no-ops on the wrong line), timeline
  -- <CR>, task-tree <CR> and its [n/m %] virtual text, calendar.lua's jump
  -- sites and DQL TASK results.
  if offset > 0 then
    for _, t in ipairs(tasks) do
      t.line = t.line + offset
    end
  end
  local inline_fields = extract_inline_fields(body_lines)

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

  -- Compute the code-stripped representation ONCE for this chunk. chunk_lines is
  -- already the per-line array (content == table.concat(chunk_lines, "\n")), so
  -- reuse it directly. Links scan stripped content lines; tags/task-tags scan
  -- stripped body lines (body == content for non-FM chunks, "" for the FM
  -- chunk). Inline fields strip per-line themselves (NOT fence-aware).
  local stripped_content_lines = strip_code_blocks_lines(chunk_lines)
  local outlinks = extract_links(stripped_content_lines)

  -- Determine body: frontmatter chunks have no body
  local body = fm_fields and "" or content
  local body_lines = fm_fields and nil or chunk_lines
  -- For non-FM chunks body == content, so the stripped arrays coincide.
  local stripped_body_lines = fm_fields and {} or stripped_content_lines

  local tags = extract_tags(fm_fields or {}, stripped_body_lines)

  local tasks = {}
  if body ~= "" then
    tasks = extract_tasks(body, body_lines, stripped_body_lines)
    if line_offset > 0 then
      for _, t in ipairs(tasks) do
        t.line = t.line + line_offset
      end
    end
  end

  local inline_fields = body ~= ""
    and extract_inline_fields(body_lines) or {}

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
