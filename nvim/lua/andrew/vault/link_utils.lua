local slug_mod = require("andrew.vault.slug")
local file_cache = require("andrew.vault.file_cache")
local pat = require("andrew.vault.patterns")

local M = {}

--- Common link patterns — delegated to centralized patterns module.
M.WIKILINK_PAT = pat.WIKILINK
M.WIKILINK_EXACT_PAT = pat.WIKILINK_EXACT
M.URL_PAT = pat.URL

--- Parse the inner content of a wikilink [[inner]].
--- Handles: name, name#heading, name^block, name#heading^block, name|alias, and combinations.
--- Normalizes escaped pipes (\\|).
--- @param inner string  The text between [[ and ]]
--- @return { name: string, heading: string|nil, block_id: string|nil, alias: string|nil }
function M.parse_target(inner)
  -- Normalize escaped pipes: in Markdown tables, \| is used to prevent
  -- the pipe from being parsed as a column delimiter. For wikilink parsing
  -- purposes, \| is equivalent to | (alias separator).
  inner = inner:gsub("\\|", "|")

  -- Extract alias (after |)
  local target_part, alias = inner:match(pat.LINK_PIPE)
  if not target_part then
    target_part = inner
  end

  -- Parse name#heading^block_id
  local name, heading, block_id

  -- Handle self-referencing links: #heading, #heading^block, ^block
  if target_part:byte(1) == 35 then
    local h2, b2 = target_part:match(pat.LINK_SELF_HEADING_BLOCK)
    if h2 then
      name, heading, block_id = "", h2, b2
    else
      name, heading = "", target_part:sub(2)
    end
  elseif target_part:byte(1) == 94 then
    name, block_id = "", target_part:sub(2)
  else
    -- Try all combinations
    local n, h, b = target_part:match(pat.LINK_NAME_HEADING_BLOCK)
    if n then
      name, heading, block_id = n, h, b
    else
      n, b = target_part:match(pat.LINK_NAME_BLOCK)
      if n then
        name, block_id = n, b
      else
        n, h = target_part:match(pat.LINK_NAME_HEADING)
        if n then
          name, heading = n, h
        else
          name = target_part
        end
      end
    end
  end

  return {
    name = vim.trim(name or ""),
    heading = heading and vim.trim(heading) or nil,
    block_id = block_id and vim.trim(block_id) or nil,
    alias = alias and vim.trim(alias) or nil,
  }
end

--- Extract the filename stem (no directory, no extension) from a path.
--- Pure Lua equivalent of `vim.fn.fnamemodify(path, ":t:r")`.
--- @param path string  Absolute or relative file path
--- @return string  Filename without directory or extension (e.g. "My Note")
function M.get_basename(path)
  local tail = path:match(pat.BASENAME) or path
  return tail:match(pat.BASENAME_NO_EXT) or tail
end

--- Extract the filename (with extension) from a path.
--- Pure Lua equivalent of `vim.fn.fnamemodify(path, ":t")`.
--- @param path string  Absolute or relative file path
--- @return string  Filename with extension (e.g. "My Note.md")
function M.get_tail(path)
  return path:match(pat.BASENAME) or path
end

--- Strip the .md extension from a relative path to get the stem.
--- Centralises the `rel_path:gsub("%.md$", "")` pattern used across the vault.
---@param rel_path string
---@return string
function M.rel_to_stem(rel_path)
  return (rel_path:gsub(pat.MD_EXTENSION, ""))
end

--- Check if a line is a fenced code block delimiter (``` or ~~~).
--- Detects both backtick and tilde fences with optional leading whitespace.
---@param line string
---@return boolean
function M.is_fence_delimiter(line)
  return pat.is_code_fence(line)
end

--- Extract all wikilinks from a single line of markdown.
--- Returns structured link info for each [[...]] and ![[...]] found.
---@param line string
---@return {name: string, heading: string|nil, block_id: string|nil, embed: boolean}[]
function M.extract_line_links(line)
  local links = {}
  -- Track embed positions to avoid double-matching with wikilink pass
  local embed_positions = {}
  for s_pos in line:gmatch(pat.EMBED_POS) do
    embed_positions[s_pos] = true
  end
  -- Extract embeds
  for inner in line:gmatch(pat.EMBED_INNER) do
    local parsed = M.parse_target(inner)
    links[#links + 1] = {
      name = parsed.name,
      heading = parsed.heading,
      block_id = parsed.block_id,
      embed = true,
    }
  end
  -- Extract regular wikilinks (skip embeds)
  for s_pos, inner in line:gmatch(pat.WIKILINK_POS_INNER) do
    if not embed_positions[s_pos - 1] then
      local parsed = M.parse_target(inner)
      links[#links + 1] = {
        name = parsed.name,
        heading = parsed.heading,
        block_id = parsed.block_id,
        embed = false,
      }
    end
  end
  return links
end

--- Convert a markdown heading to a URL-safe slug/anchor.
--- Matches Obsidian's heading anchor format.
--- Delegates to slug.lua which maintains its own LRU cache.
--- @param text string  The heading text (without the # prefix)
--- @return string
M.heading_to_slug = slug_mod.heading_to_slug

--- Find the 1-based line number of a heading matching the given slug.
---@param lines string[] file/buffer lines
---@param heading string heading text (will be slugified for comparison)
---@return number|nil line_number 1-based line number, or nil if not found
function M.find_heading_line(lines, heading)
  local target_slug = M.heading_to_slug(heading)
  for i, l in ipairs(lines) do
    -- Fast check: skip non-heading lines without regex
    if l:byte(1) ~= 35 then goto continue end -- 35 = '#'
    local text = l:match(pat.HEADING_TEXT)
    if text and M.heading_to_slug(text) == target_slug then
      return i
    end
    ::continue::
  end
  return nil
end

--- Find the 1-based line number of a heading using pre-computed vault index data.
--- Preferred for cross-file lookups where the file is not in a buffer.
--- Falls back to nil if the index is unavailable or stale.
---@param rel_path string relative path within the vault (e.g. "notes/foo.md")
---@param heading string heading text (will be slugified for comparison)
---@return number|nil line_number 1-based line number, or nil if not found
function M.find_heading_line_indexed(rel_path, heading)
  local vi = require("andrew.vault.vault_index")
  local idx = vi.current()
  if not idx or not idx:is_ready() then return nil end
  local entry = idx.files[rel_path]
  if not entry or not entry.headings then return nil end

  local target_slug = M.heading_to_slug(heading)
  for _, h in ipairs(entry.headings) do
    if h.slug == target_slug then
      return h.line
    end
  end
  return nil
end

--- Find the wikilink at a given column position on a line.
--- Returns nil if no wikilink spans that column.
--- @param line string  The line text to search
--- @param col number   1-indexed column position
--- @return { name: string, heading: string|nil, block_id: string|nil, alias: string|nil }|nil
local function get_wikilink_on_line(line, col)
  local result
  pat.scan_wikilinks(line, function(inner, start_col, end_col)
    if col >= start_col and col <= end_col then
      result = M.parse_target(inner)
      return true -- stop scanning
    end
  end)
  return result
end

--- Get the wikilink under the cursor, fully parsed.
--- Returns nil if cursor is not on a wikilink.
--- @return { name: string, heading: string|nil, block_id: string|nil, alias: string|nil }|nil
function M.get_wikilink_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  return get_wikilink_on_line(line, col)
end

--- Get the wikilink under the cursor in an arbitrary buffer/window.
--- @param buf number  Buffer number
--- @param win number  Window number
--- @return { name: string, heading: string|nil, block_id: string|nil, alias: string|nil }|nil
function M.get_wikilink_in_buf(buf, win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local line_idx = cursor[1] - 1
  local col = cursor[2] + 1
  local lines = vim.api.nvim_buf_get_lines(buf, line_idx, line_idx + 1, false)
  if #lines == 0 then return nil end
  return get_wikilink_on_line(lines[1], col)
end

--- Read all lines from a source (file path or lines array).
--- File paths are read through file_cache (mtime-validated LRU) to avoid
--- redundant disk I/O across preview, embed, and export operations.
--- @param source string|string[]  Absolute file path or array of lines
--- @return string[]|nil  Lines array, or nil on read failure
local function read_all_lines(source)
  if type(source) == "table" then
    return source
  end
  return file_cache.read(source)
end

--- Extract lines under a heading from a pre-read lines array (pure, no I/O).
--- @param all_lines string[]  File content as array of lines
--- @param heading string  Heading text to match (without # prefix)
--- @return string[]|nil  Lines including the heading line, or nil if not found
local function extract_heading_lines(all_lines, heading)
  local lines = {}
  local capturing = false
  local target_level = nil
  local target_slug = M.heading_to_slug(heading)

  for _, line in ipairs(all_lines) do
    if capturing then
      -- Fast check: only test heading regex on lines starting with #
      if line:byte(1) == 35 then -- 35 = '#'
        local level_str = line:match("^(#+)%s+")
        if level_str and #level_str <= target_level then
          break
        end
      end
      lines[#lines + 1] = line
    else
      -- Fast check: skip non-heading lines without regex
      if line:byte(1) ~= 35 then goto continue end -- 35 = '#'
      local level_str, text = line:match(pat.HEADING)
      if text and M.heading_to_slug(vim.trim(text)) == target_slug then
        target_level = #level_str
        capturing = true
        lines[#lines + 1] = line
      end
      ::continue::
    end
  end

  if #lines == 0 then return nil end
  return lines
end

--- Read lines under a specific heading from a markdown file or lines array.
--- Returns lines from the heading through the next same-or-higher-level heading (exclusive).
--- For file paths, uses section-level caching (mtime-validated) via file_cache.
--- @param source string|string[]  Absolute file path or array of lines
--- @param heading string  Heading text to match (without # prefix)
--- @return string[]  Lines including the heading line itself, or empty table if not found
function M.read_heading_section(source, heading)
  if type(source) == "table" then
    return extract_heading_lines(source, heading) or {}
  end
  -- File path: use section cache (caches extracted heading by path+heading+mtime)
  return file_cache.get_section(source, heading, extract_heading_lines) or {}
end

--- Extract the paragraph containing a block reference from pre-read lines (pure, no I/O).
--- @param all_lines string[]  File content as array of lines
--- @param block_id string  Block ID (without ^ prefix)
--- @return string[]|nil  Paragraph lines with block-id stripped, or nil if not found
local function extract_block_lines(all_lines, block_id)
  local paragraphs = {}
  local current = {}
  for _, line in ipairs(all_lines) do
    if line:match("^%s*$") then
      if #current > 0 then
        paragraphs[#paragraphs + 1] = current
        current = {}
      end
    else
      current[#current + 1] = line
    end
  end
  if #current > 0 then
    paragraphs[#paragraphs + 1] = current
  end

  local escaped = vim.pesc(block_id)
  for _, para in ipairs(paragraphs) do
    for _, line in ipairs(para) do
      if line:match("%^" .. escaped .. "%s*$") then
        local result = {}
        for _, l in ipairs(para) do
          result[#result + 1] = l:gsub("%s*%^" .. escaped .. "%s*$", "")
        end
        return result
      end
    end
  end

  return nil
end

--- Read the paragraph containing a block reference (^block-id) from a file or lines array.
--- Returns the paragraph lines with the block-id marker stripped.
--- For file paths, uses section-level caching (mtime-validated) via file_cache.
--- @param source string|string[]  Absolute file path or array of lines
--- @param block_id string  Block ID (without ^ prefix)
--- @return string[]  Paragraph lines, or empty table if not found
function M.read_block_content(source, block_id)
  if type(source) == "table" then
    local result = extract_block_lines(source, block_id)
    if not result then return nil, "block not found: ^" .. tostring(block_id) end
    return result
  end
  -- File path: use section cache (caches extracted block by path+blockid+mtime)
  local result = file_cache.get_section(source, "^" .. block_id, function(lines, fragment)
    return extract_block_lines(lines, fragment:sub(2)) -- strip leading ^ from cache key
  end)
  if not result then return nil, "block not found: ^" .. tostring(block_id) end
  return result
end

--- Extract all headings from a markdown source.
--- Returns both a slug lookup set and an ordered list of raw heading texts.
--- @param source string|string[]  Absolute file path or array of lines
--- @return table<string, boolean> slug_set  Maps heading slugs to true
--- @return string[] raw_headings  Ordered list of heading texts (without # prefix)
function M.extract_headings(source)
  local all_lines = read_all_lines(source)
  if not all_lines then return {}, {} end

  local slugs = {}
  local headings = {}
  for _, line in ipairs(all_lines) do
    if line:byte(1) ~= 35 then goto continue end -- 35 = '#'
    local heading_text = line:match(pat.HEADING_TEXT)
    if heading_text then
      heading_text = heading_text:gsub("%s+$", "")
      headings[#headings + 1] = heading_text
      slugs[M.heading_to_slug(heading_text)] = true
    end
    ::continue::
  end
  return slugs, headings
end

--- Resolve content lines for a heading, block, or full-file reference.
--- Shared logic used by preview, embed, and other modules.
--- @param details { heading: string|nil, block_id: string|nil }
--- @param source string|string[]  Absolute file path or array of lines
--- @param opts? { max_lines: number|nil }  Optional line limit for full-file reads
--- @return string[] lines  Resolved content (or error placeholder)
--- @return boolean truncated  True if content was cut short by max_lines
function M.resolve_content(details, source, opts)
  opts = opts or {}
  local max_lines = opts.max_lines

  if details.heading then
    local lines = M.read_heading_section(source, details.heading)
    if #lines == 0 then
      return { "[Heading not found: #" .. details.heading .. "]" }, false
    end
    if max_lines and #lines > max_lines then
      local capped = {}
      for i = 1, max_lines do capped[i] = lines[i] end
      return capped, true
    end
    return lines, false
  end

  if details.block_id then
    local lines = M.read_block_content(source, details.block_id)
    if not lines or #lines == 0 then
      return { "[Block not found: ^" .. details.block_id .. "]" }, false
    end
    if max_lines and #lines > max_lines then
      local capped = {}
      for i = 1, max_lines do capped[i] = lines[i] end
      return capped, true
    end
    return lines, false
  end

  -- Full file/buffer content
  local limit = max_lines
  local lines
  local truncated = false
  if type(source) == "table" then
    if limit then
      lines = {}
      for i = 1, math.min(#source, limit) do lines[i] = source[i] end
      truncated = #source > limit
    else
      lines = source
    end
  else
    lines = file_cache.read(source, limit)
    if not lines then lines = {} end
    truncated = limit ~= nil and #lines >= limit
  end
  if #lines == 0 then
    return { "[Could not read file]" }, false
  end
  return lines, truncated
end

--- Replace the note name in a wikilink text, preserving heading/alias/block suffixes.
--- @param link_text string  Full wikilink text including [[ ]] brackets
--- @param new_name string  New note name to substitute
--- @return string|nil  The modified wikilink, or nil if link_text is malformed
function M.replace_link_note(link_text, new_name)
  local inner = link_text:match(pat.WIKILINK_EXACT)
  if not inner then return nil end
  local rest = inner:match("^[^|#^]+(.*)")
  if rest then
    return "[[" .. new_name .. rest .. "]]"
  end
  return "[[" .. new_name .. "]]"
end

--- Replace the heading anchor in a wikilink text, preserving note name and alias.
--- @param link_text string  Full wikilink text including [[ ]] brackets
--- @param new_heading string  New heading text to substitute
--- @return string|nil  The modified wikilink, or nil if link_text is malformed
function M.replace_link_heading(link_text, new_heading)
  local inner = link_text:match(pat.WIKILINK_EXACT)
  if not inner then return nil end
  local before_hash = inner:match("^([^#]+)")
  local after_heading = inner:match("#[^|^]+(.*)$") or ""
  return "[[" .. (before_hash or "") .. "#" .. new_heading .. after_heading .. "]]"
end

--- Pick the closest path to the current buffer by proximity scoring.
--- Uses character-by-character prefix matching against the current buffer's directory.
--- @param paths string[]  Array of absolute file paths
--- @return string  The path with the best proximity score
--- Pure Lua dirname (avoids vim.fn cross-language call).
---@param path string absolute or relative file path
---@return string directory portion of the path
local function lua_dirname(path)
  return path:match(pat.PARENT_PATH) or path
end

M.lua_dirname = lua_dirname

--- Extract the display name from a raw wikilink string.
--- Handles [[target|alias]] (returns alias), [[target]] (returns basename),
--- and path-qualified links [[Sub/Note]] (returns "Note").
---@param raw string  raw wikilink text including brackets, or plain text
---@return string display name
function M.wikilink_display_name(raw)
  local alias = raw:match(pat.LINK_ALIAS)
  if alias then return vim.trim(alias) end
  local target = raw:match(pat.LINK_TARGET)
  if target then return target:match("([^/]+)$") or target end
  return raw
end

function M.pick_closest(paths)
  if #paths == 1 then
    return paths[1]
  end
  local current_dir = vim.fn.expand("%:p:h")
  local best_path = paths[1]
  local best_score = math.huge
  for _, path in ipairs(paths) do
    local dir = lua_dirname(path)
    -- Byte-level comparison: zero allocations
    local min_len = math.min(#dir, #current_dir)
    local common = 0
    for i = 1, min_len do
      if dir:byte(i) == current_dir:byte(i) then
        common = common + 1
      else
        break
      end
    end
    local score = (#dir - common) + (#current_dir - common)
    if score < best_score then
      best_score = score
      best_path = path
    end
  end
  return best_path
end

--- Resolve a note name to its absolute path and vault index entry.
--- Uses the vault index for name/alias resolution and pick_closest for disambiguation.
--- Lazy-requires vault_index to avoid circular dependencies.
--- @param name string  Note name (basename or alias)
--- @return string|nil abs_path  Absolute path of the resolved note
--- @return VaultIndexEntry|nil entry  The vault index entry, if available
function M.resolve_note_via_index(name)
  local vi = require("andrew.vault.vault_index")
  local idx = vi.current()
  if not idx or not idx:is_ready() then return nil, nil end

  local paths = idx:resolve_name(name)
  if not paths or #paths == 0 then return nil, nil end

  local abs_path = M.pick_closest(paths)

  -- Look up the index entry from the resolved path
  local prefix = idx.vault_path .. "/"
  if abs_path:sub(1, #prefix) == prefix then
    local rel_path = abs_path:sub(#prefix + 1)
    local entry = idx.files[rel_path]
    if entry then return abs_path, entry end
  end

  return abs_path, nil
end

return M
