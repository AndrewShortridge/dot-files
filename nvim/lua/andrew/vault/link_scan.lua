--- Shared scanning primitives for link detection and text matching.
---
--- Provides common utilities used by autolink.lua (inline suggestions),
--- unlinked.lua (batch auto-linking), and potentially other modules.
--- Centralizes code that was previously duplicated across modules.

local render_arena = require("andrew.vault.render_arena")
local pat = require("andrew.vault.patterns")
local memo = require("andrew.vault.memoize")

local M = {}

-- Forward declaration; initialized after build_code_exclusion_fn is defined
local _code_exclusion_check

-- Delegate frontmatter range detection to frontmatter_parser's cached parse,
-- converting from 1-indexed to 0-indexed. Eliminates redundant boundary scan.

--- Count whitespace-delimited words in a string.
---@param s string
---@return number
function M.word_count(s)
  local n = 0
  for _ in s:gmatch("%S+") do n = n + 1 end
  return n
end

-- ---------------------------------------------------------------------------
-- Code exclusion (treesitter-based)
-- ---------------------------------------------------------------------------

--- Build a function to check if a (row, col) is inside a code block/span.
--- Uses treesitter to detect fenced code blocks, indented code blocks, and
--- inline code spans. Returns a closure for fast repeated checking.
---@param bufnr number
---@return fun(row: number, col: number): boolean
--- @param bufnr number
--- @return fun(row: number, col: number): boolean
local function build_code_exclusion_fn(bufnr)
  local ranges = {}

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if ok and parser then
    local tree = parser:parse()[1]
    if tree then
      local root = tree:root()

      for _, query_str in ipairs({
        "(fenced_code_block) @code",
        "(indented_code_block) @code",
      }) do
        local qok, query = pcall(vim.treesitter.query.parse, "markdown", query_str)
        if qok and query then
          for _, node in query:iter_captures(root, bufnr, 0, -1) do
            local sr, sc, er, ec = node:range()
            ranges[#ranges + 1] = { sr, sc, er, ec }
          end
        end
      end
    end
  end

  local iok, iparser = pcall(vim.treesitter.get_parser, bufnr, "markdown_inline")
  if iok and iparser then
    local itrees = iparser:parse()
    for _, itree in ipairs(itrees) do
      local iroot = itree:root()
      local cs_ok, cs_query = pcall(vim.treesitter.query.parse, "markdown_inline", "(code_span) @code")
      if cs_ok and cs_query then
        for _, node in cs_query:iter_captures(iroot, bufnr, 0, -1) do
          local sr, sc, er, ec = node:range()
          ranges[#ranges + 1] = { sr, sc, er, ec }
        end
      end
    end
  end

  local row_set = {}
  local boundary_rows = {}

  for _, r in ipairs(ranges) do
    local sr, er = r[1], r[3]
    for row = sr + 1, er - 1 do
      row_set[row] = true
    end
    if not boundary_rows[sr] then boundary_rows[sr] = {} end
    boundary_rows[sr][#boundary_rows[sr] + 1] = r
    if er ~= sr then
      if not boundary_rows[er] then boundary_rows[er] = {} end
      boundary_rows[er][#boundary_rows[er] + 1] = r
    end
  end

  return function(row, col)
    if row_set[row] then return true end
    local boundaries = boundary_rows[row]
    if not boundaries then return false end
    for _, r in ipairs(boundaries) do
      local sr, sc, er, ec = r[1], r[2], r[3], r[4]
      if row == sr and row == er and col >= sc and col < ec then return true end
      if row == sr and row ~= er and col >= sc then return true end
      if row == er and row ~= sr and col < ec then return true end
    end
    return false
  end
end

_code_exclusion_check = memo.new(memo.changedtick, build_code_exclusion_fn, "code_exclusion")
memo.register_buf_cleanup(_code_exclusion_check)

function M.build_code_exclusion(bufnr)
  return _code_exclusion_check:get(bufnr)
end

-- ---------------------------------------------------------------------------
-- Frontmatter detection
-- ---------------------------------------------------------------------------

--- Find frontmatter range (0-indexed line numbers).
--- Delegates to frontmatter_parser's cached parse to avoid redundant scanning.
---@param bufnr number
---@return number|nil start_line, number|nil end_line
function M.get_frontmatter_range(bufnr)
  local fm = require("andrew.vault.frontmatter_parser").parse_buffer_cached(bufnr)
  if not fm then return nil, nil end
  return fm.start_line - 1, fm.end_line - 1
end

--- Clear changedtick caches for a buffer.
---@param bufnr number
function M.clear_cache(bufnr)
  _code_exclusion_check:invalidate(bufnr)
end

local cleanup = require("andrew.vault.resource_cleanup")
local _augroup = vim.api.nvim_create_augroup("VaultLinkScan", { clear = true })
cleanup.on_buf_delete(_augroup, function(bufnr) M.clear_cache(bufnr) end, { pattern = "*.md" })

-- ---------------------------------------------------------------------------
-- Link range detection
-- ---------------------------------------------------------------------------

--- Build a list of byte ranges on a line that are inside wikilinks, embeds,
--- markdown links, or URLs. Matches overlapping these ranges are skipped.
---@param line string
---@return {start_col: number, end_col: number}[]  0-indexed byte ranges
function M.get_link_ranges(line)
  local ranges = {}

  -- Wikilinks: [[...]] and ![[...]]
  pat.scan_all_links(line, function(_inner, start_col, end_col, _is_embed)
    ranges[#ranges + 1] = { start_col = start_col - 1, end_col = end_col }
  end)

  -- Markdown links: [text](url)
  local pos = 1
  while true do
    local s, e = line:find(pat.MARKDOWN_LINK, pos)
    if not s then break end
    if s > 1 and line:sub(s - 1, s - 1) == "[" then
      pos = s + 1
    else
      ranges[#ranges + 1] = { start_col = s - 1, end_col = e }
      pos = e + 1
    end
  end

  -- Bare URLs: https://...
  pos = 1
  while true do
    local s, e = line:find(require("andrew.vault.link_utils").URL_PAT, pos)
    if not s then break end
    ranges[#ranges + 1] = { start_col = s - 1, end_col = e }
    pos = e + 1
  end

  return ranges
end

--- Check if a byte range overlaps any of the exclusion ranges.
---@param start_col number 0-indexed
---@param end_col number 0-indexed (exclusive)
---@param ranges {start_col: number, end_col: number}[]
---@return boolean
function M.overlaps_range(start_col, end_col, ranges)
  for _, r in ipairs(ranges) do
    if start_col < r.end_col and end_col > r.start_col then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Word boundary check
-- ---------------------------------------------------------------------------

--- Check if a match at (start_pos, end_pos) in a line has valid word boundaries.
--- start_pos and end_pos are 1-indexed byte positions (Lua string convention).
---@param line string
---@param start_pos number 1-indexed start of match
---@param end_pos number 1-indexed end of match (inclusive)
---@return boolean
local function has_word_boundaries(line, start_pos, end_pos)
  if start_pos > 1 then
    local prev = line:sub(start_pos - 1, start_pos - 1)
    if prev:match("[%w_]") then
      return false
    end
  end
  if end_pos < #line then
    local next_char = line:sub(end_pos + 1, end_pos + 1)
    if next_char:match("[%w_]") then
      return false
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Buffer-level name scanning
-- ---------------------------------------------------------------------------

--- Scan a buffer for mentions of vault note names.
--- Implements the shared scanning algorithm used by both autolink.lua
--- (inline suggestions) and unlinked.lua (batch auto-linking).
---
--- The algorithm:
--- 1. Gets vault index name cache
--- 2. Splits names into multi-word (sorted longest first) and single-word sets
--- 3. Iterates buffer lines in the specified range
--- 4. Skips frontmatter, heading lines, empty lines
--- 5. For each line: gets link ranges, builds position tracking, scans
---    multi-word names (longest first, greedy), then single-word names
--- 6. Applies code exclusion, link overlap, word boundary, position overlap,
---    and self-mention checks
---
---@param bufnr number
---@param opts? { start_line?: number, end_line?: number, min_name_length?: number, exclude_names?: string[] }
---@return { row: number, start_col: number, end_col: number, text: string, note_name: string }[]
function M.scan_buffer_names(bufnr, opts)
  opts = opts or {}
  local min_name_length = opts.min_name_length or 3

  local arena_scope = render_arena.begin_scope()

  -- Build exclude set from opts (arena: per-call intermediate)
  local exclude_set = render_arena.alloc_table(arena_scope)
  if opts.exclude_names then
    for _, name in ipairs(opts.exclude_names) do
      exclude_set[name:lower()] = true
    end
  end

  -- Lazy-require to avoid circular dependencies
  local vault_index = require("andrew.vault.vault_index")
  local link_utils = require("andrew.vault.link_utils")

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    render_arena.end_scope(arena_scope)
    return {}
  end

  local fname = vim.api.nvim_buf_get_name(bufnr)

  local name_cache = idx:get_name_cache()
  local names_map = name_cache.names

  -- Build name lists: multi-word sorted longest first, single-word as hash set
  -- (arena: per-call intermediates, don't escape)
  local multi_words = render_arena.alloc_table(arena_scope)
  local single_set = render_arena.alloc_table(arena_scope)
  for lower_name in pairs(names_map) do
    if #lower_name >= min_name_length and not exclude_set[lower_name] then
      local wc = M.word_count(lower_name)
      if wc == 1 then
        single_set[lower_name] = true
      else
        multi_words[#multi_words + 1] = lower_name
      end
    end
  end
  table.sort(multi_words, function(a, b) return #a > #b end)

  -- Determine line range
  local start_line = opts.start_line or 0
  local end_line = opts.end_line or vim.api.nvim_buf_line_count(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
  local is_in_code = M.build_code_exclusion(bufnr)
  local fm_start, fm_end = M.get_frontmatter_range(bufnr)

  -- Current buffer's own note name — exclude self-mentions
  local self_name = link_utils.get_basename(fname):lower()

  local matches = {} -- NOTE: escapes scope, NOT from arena

  for i, line in ipairs(lines) do
    local row = start_line + i - 1 -- 0-indexed absolute row

    -- Skip frontmatter
    if fm_start and fm_end and row >= fm_start and row <= fm_end then
      goto next_line
    end

    -- Skip heading lines (uses M.is_heading_line pattern inline for hot-loop perf)
    if line:match("^#+ ") then goto next_line end

    -- Skip empty lines
    if #line == 0 then goto next_line end

    local lower_line = line:lower()
    local link_ranges = M.get_link_ranges(line)

    -- Column bitset: per-line ephemeral (arena)
    local occupied_cols = render_arena.alloc_table(arena_scope)

    local function mark_position(s, e)
      for col = s, e - 1 do
        occupied_cols[col] = true
      end
    end

    local function is_position_taken(s, e)
      for col = s, e - 1 do
        if occupied_cols[col] then return true end
      end
      return false
    end

    --- Try to record a match at [start_col, end_col) for note_name.
    --- Returns true if the match was accepted (passes all exclusion checks).
    local function try_add_match(s, e, note_name)
      if not has_word_boundaries(line, s, e) then return false end
      local start_col = s - 1 -- 0-indexed
      local end_col = e       -- 0-indexed exclusive
      if
        M.overlaps_range(start_col, end_col, link_ranges)
        or is_in_code(row, start_col)
        or is_position_taken(start_col, end_col)
        or note_name == self_name
      then
        return false
      end
      matches[#matches + 1] = {
        row = row,
        start_col = start_col,
        end_col = end_col,
        text = line:sub(s, e),
        note_name = note_name,
      }
      mark_position(start_col, end_col)
      return true
    end

    -- Phase 1: Multi-word names (longest first, greedy)
    for _, mw_name in ipairs(multi_words) do
      local search_start = 1
      while true do
        local s, e = lower_line:find(mw_name, search_start, true)
        if not s then break end
        try_add_match(s, e, mw_name)
        search_start = e + 1
      end
    end

    -- Phase 2: Single-word names (hash set lookup per word)
    local word_start = 1
    while word_start <= #line do
      local ws = line:find("[%w_]", word_start)
      if not ws then break end
      local we = line:find("[^%w_]", ws)
      if not we then we = #line + 1 end

      local lower_word = line:sub(ws, we - 1):lower()
      if single_set[lower_word] and #lower_word >= min_name_length then
        try_add_match(ws, we - 1, lower_word)
      end

      word_start = we
    end

    ::next_line::
  end

  render_arena.end_scope(arena_scope)
  return matches
end

-- =============================================================================
-- Line-array based context exclusion (for disk-file scanning, e.g., ripgrep results)
-- =============================================================================

--- Check if a line is inside a fenced code block (line-array based).
---@param lines string[]
---@param target_line number 1-indexed line number
---@return boolean
function M.is_in_fenced_code_lines(lines, target_line)
  local in_fence = false
  for i = 1, target_line do
    local line = lines[i]
    if pat.is_code_fence(line) then
      in_fence = not in_fence
    end
  end
  return in_fence
end

--- Check if a line is inside YAML frontmatter (line-array based).
---@param lines string[]
---@param target_line number 1-indexed line number
---@return boolean
function M.is_in_frontmatter_lines(lines, target_line)
  if #lines == 0 or lines[1] ~= "---" then return false end
  if target_line <= 1 then return true end
  for i = 2, #lines do
    if lines[i] == "---" or lines[i] == "..." then
      return target_line <= i
    end
  end
  -- Unclosed frontmatter — treat everything as inside
  return true
end

--- Check if a byte position is inside an inline code span (backtick-delimited).
--- Uses regex matching for disk-file context (no treesitter available).
---@param line string
---@param pos number 1-indexed byte position
---@return boolean
function M.is_inside_code_span(line, pos)
  local search_start = 1
  while search_start <= #line do
    local tick_start, tick_end = line:find("`+", search_start)
    if not tick_start then break end
    local ticks = line:sub(tick_start, tick_end)
    local close_start, close_end = line:find(ticks, tick_end + 1, true)
    if not close_start then break end
    if pos > tick_end and pos <= close_start then
      return true
    end
    search_start = close_end + 1
  end
  return false
end

--- Check if a line is a markdown heading.
--- NOTE: This pattern is intentionally duplicated in line_parse_cache.lua
--- (which avoids requires for hot-path performance). Keep in sync.
---@param line string
---@return boolean
function M.is_heading_line(line)
  return line:match("^#+ ") ~= nil
end

return M
