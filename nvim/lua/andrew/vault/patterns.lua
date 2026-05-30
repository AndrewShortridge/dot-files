--- Centralized pattern definitions for the vault plugin.
--- Single source of truth — all modules require patterns from here.
---
--- Inspired by Zed's LazyLock<Regex> static pattern definitions
--- and the existing block_patterns.lua module.

local M = {}

-- ---------------------------------------------------------------------------
-- Wikilinks
-- ---------------------------------------------------------------------------
M.WIKILINK = "%[%[(.-)%]%]"
M.WIKILINK_EXACT = "^%[%[(.-)%]%]$"
M.WIKILINK_OPEN = "%[%["
M.WIKILINK_INNER = "%[%[([^%]]+)%]%]"
M.WIKILINK_WITH_POS = "()%[%[(.-)%]%]()"
M.WIKILINK_POS_INNER = "()%[%[([^%]]+)%]%]"
M.EMBED = "!%[%[(.-)%]%]"
M.EMBED_OPEN = "!%[%["
M.EMBED_INNER = "!%[%[([^%]]+)%]%]"
M.EMBED_DETECT = "!%[%[.-%]%]"
M.WIKILINK_DETECT = "%[%[.-%]%]"
M.EMBED_POS = "()!%[%["

-- Wikilink component parsing (used in link_utils.parse_target)
M.LINK_PIPE = "^(.+)|(.+)$"
M.LINK_SELF_HEADING_BLOCK = "^#([^%^]+)%^(.+)$"
M.LINK_NAME_HEADING_BLOCK = "^([^#%^]+)#([^%^]+)%^(.+)$"
M.LINK_NAME_BLOCK = "^([^#%^]+)%^(.+)$"
M.LINK_NAME_HEADING = "^([^#%^]+)#(.+)$"
M.LINK_ALIAS = "%|([^%]]+)%]%]"
M.LINK_TARGET = "%[%[([^|%]]+)%]%]"
M.LINK_TARGETS_SIMPLE = "%[%[([^%]|#]+)"

-- ---------------------------------------------------------------------------
-- Tags
-- ---------------------------------------------------------------------------
M.TAG = "#([%w_%-][%w_%-/]*)"
M.TAG_COMPLETION = "#([%w_/-]*)$"
M.TAG_TRIGGER = "[%s^]#[%w_/-]*$"

-- ---------------------------------------------------------------------------
-- Headings
-- ---------------------------------------------------------------------------
M.HEADING = "^(#+)%s+(.*)"
M.HEADING_TEXT = "^#+%s+(.*)"

-- ---------------------------------------------------------------------------
-- Inline fields
-- ---------------------------------------------------------------------------
M.INLINE_FIELD_BRACKET = "%[([%w_%-]+)::%s*(.-)%]"
M.INLINE_FIELD_PAREN = "%(([%w_%-]+)::%s*(.-)%)"
M.INLINE_FIELD_STANDALONE = "^([%w_%-]+)::%s*(.*)"
M.INLINE_FIELD_LIST_ITEM = "^(%s*[-*]%s+)([%w_%-]+)::%s*(.*)"
M.INLINE_FIELD_STANDALONE_GMATCH = "([%w_%-]+)::%s*(.-)%s*$"
M.INLINE_FIELD_DELIM = "::"

-- ---------------------------------------------------------------------------
-- Frontmatter
-- ---------------------------------------------------------------------------
M.FM_OPEN = "^%-%-%-$"
M.FM_OPEN_LINE = "^%-%-%-\n"
M.FM_CLOSE = "\n%-%-%-\n"
M.FM_CLOSE_EOF = "\n%-%-%-$"
M.FM_KEY_VALUE = "^([%w_%-]+):%s*(.*)"
M.FM_KEY_PREFIX = "^([%w_%-]+):"
M.FM_LIST_ITEM = "^%s+%- (.*)"
M.FM_LIST_ITEM_CHECK = "^%s+%- "

-- ---------------------------------------------------------------------------
-- Tasks
-- ---------------------------------------------------------------------------
M.TASK_CHECKBOX = "^(.*%- %[)(.)(%].*)$"
M.TASK_DETECT = "^%s*[-*] %[(.)%] "
M.TASK_TEXT = "^%s*[-*] %[.%] (.*)"

-- ---------------------------------------------------------------------------
-- Block IDs (mirrors block_patterns.lua for consolidation)
-- ---------------------------------------------------------------------------
M.BLOCK_ID = "%^([%w%-]+)%s*$"
M.BLOCK_ID_STRIP = "%s*%^[%w%-]+%s*$"

-- ---------------------------------------------------------------------------
-- Code fences
-- ---------------------------------------------------------------------------
M.CODE_FENCE_BACKTICK = "^%s*```"
M.CODE_FENCE_TILDE = "^%s*~~~"

-- ---------------------------------------------------------------------------
-- Dates
-- ---------------------------------------------------------------------------
M.ISO_DATE = "^%d%d%d%d%-%d%d%-%d%d$"
M.ISO_DATE_MD = "^%d%d%d%d%-%d%d%-%d%d%.md$"
M.ISO_DATE_CAPTURE = "^(%d%d%d%d%-%d%d%-%d%d)%.md$"
M.ISO_DATE_PARTS = "(%d+)-(%d+)-(%d+)"
M.ISO_DATETIME_FULL = "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)"
M.ISO_DATETIME_SHORT = "^(%d%d%d%d)-(%d%d)-(%d%d)"
M.ISO_DATE_PREFIX = "^(%d%d%d%d%-%d%d%-%d%d)"
M.RELATIVE_DURATION = "^(%d+)d$"

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------
M.HIGHLIGHT = "==[^=]+=="

-- ---------------------------------------------------------------------------
-- Footnotes
-- ---------------------------------------------------------------------------
M.FOOTNOTE_REF = "%[%^([%w_-]+)%]"
M.FOOTNOTE_DEF = "^%[%^([%w_-]+)%]:%s?(.*)"
M.FOOTNOTE_ID = "%[%^(%d+)%]"
M.FOOTNOTE_CONT = "^%s%s%s%s(.*)"
M.FOOTNOTE_CONT_TAB = "^\t(.*)"

-- ---------------------------------------------------------------------------
-- URLs
-- ---------------------------------------------------------------------------
M.URL = "https?://[%w%-%.%_%~%:%/%?#%[%]@!%$&'%(%)%*%+,;=%%]+"

-- ---------------------------------------------------------------------------
-- Line iteration
-- ---------------------------------------------------------------------------
M.LINE = "[^\n]*"
M.LINE_NONEMPTY = "[^\n]+"
M.LINE_CAPTURE = "(.-)\n"
M.LINE_WITH_NEWLINE = "([^\n]*)\n?"

-- ---------------------------------------------------------------------------
-- Slug construction (gsub patterns)
-- ---------------------------------------------------------------------------
M.SLUG_STRIP_SPECIAL = "[^%w%s%-]"
M.SLUG_COLLAPSE_SPACES = "%s+"
M.SLUG_COLLAPSE_DASHES = "%-+"
M.SLUG_TRIM_LEADING = "^%-+"
M.SLUG_TRIM_TRAILING = "%-+$"

-- ---------------------------------------------------------------------------
-- Common list/CSV
-- ---------------------------------------------------------------------------
M.CSV_ITEM = "[^,]+"
M.CSV_ITEM_COMPLEX = '[^,%[%]"]+' -- for list items with bracket/quote delimiters

-- ---------------------------------------------------------------------------
-- Path
-- ---------------------------------------------------------------------------
M.PARENT_PATH = "^(.+)/[^/]+$"
M.BASENAME = "([^/]+)$"
M.BASENAME_NO_EXT = "^(.+)%.[^.]+$"
M.PATH_SEGMENT = "[^/]+"
M.DOTTED_SEGMENT = "[^%.]+"
M.WORD_SEGMENT = "%S+"
M.MD_EXTENSION = "%.md$"

-- ---------------------------------------------------------------------------
-- Regex escaping
-- ---------------------------------------------------------------------------
M.LUA_SPECIAL_CHARS = "([%.%+%*%?%[%]%^%$%(%)%{%}%|\\])"
M.LUA_PATTERN_ESCAPE = "[%(%)%.%%%+%-%*%?%[%]%^%$]"

-- ---------------------------------------------------------------------------
-- Markdown links (non-wiki)
-- ---------------------------------------------------------------------------
M.MARKDOWN_LINK = "%[.-%]%(.-%)"

-- ---------------------------------------------------------------------------
-- Prefilter (for string.find quick checks before full pattern match)
-- ---------------------------------------------------------------------------
M.HAS_WIKILINK = "%[%["
M.HAS_EMBED = "!%[%["
M.HAS_TAG = "#"
M.HAS_HEADING = "^#"
M.HAS_INLINE_FIELD = "::"
M.HAS_HIGHLIGHT = "=="

-- ===========================================================================
-- Pre-bound Iterator Factories
-- ===========================================================================

--- Return an iterator over all wikilink inner content in a line.
---@param line string
---@return fun(): string?
function M.gmatch_wikilinks(line)
  return line:gmatch(M.WIKILINK_INNER)
end

--- Return an iterator over all embed inner content in a line.
---@param line string
---@return fun(): string?
function M.gmatch_embeds(line)
  return line:gmatch(M.EMBED_INNER)
end

--- Return an iterator over all inline fields (bracket form) in text.
---@param text string
---@return fun(): string?, string?
function M.gmatch_inline_fields(text)
  return text:gmatch(M.INLINE_FIELD_BRACKET)
end

--- Return an iterator over all lines in a string.
---@param text string
---@return fun(): string?
function M.gmatch_lines(text)
  return text:gmatch(M.LINE)
end

--- Return an iterator over non-empty lines in a string.
---@param text string
---@return fun(): string?
function M.gmatch_lines_nonempty(text)
  return text:gmatch(M.LINE_NONEMPTY)
end

--- Return an iterator over all tags in text.
---@param text string
---@return fun(): string?
function M.gmatch_tags(text)
  return text:gmatch(M.TAG)
end

--- Return an iterator over CSV items.
---@param text string
---@return fun(): string?
function M.gmatch_csv(text)
  return text:gmatch(M.CSV_ITEM)
end

--- Return an iterator over path segments.
---@param path string
---@return fun(): string?
function M.gmatch_path_segments(path)
  return path:gmatch(M.PATH_SEGMENT)
end

--- Check if a line is a code fence opener.
--- Handles both backtick and tilde fences.
---@param line string
---@return boolean
function M.is_code_fence(line)
  return line:match(M.CODE_FENCE_BACKTICK) ~= nil
    or line:match(M.CODE_FENCE_TILDE) ~= nil
end

-- ===========================================================================
-- Bracket-Matching Scanners
-- ===========================================================================

--- Scan for wikilinks by matching brackets (handles edge cases that gmatch misses).
--- Skips embeds (lines starting with ! before [[).
---@param line string
---@param callback fun(inner: string, start_col: number, end_col: number): boolean?
---   Return true to stop scanning.
function M.scan_wikilinks(line, callback)
  local pos = 1
  while pos <= #line do
    local open_start, open_end = line:find(M.WIKILINK_OPEN, pos, false)
    if not open_start then break end
    -- Skip if preceded by ! (that's an embed, not a wikilink)
    if open_start > 1 and line:byte(open_start - 1) == 33 then -- '!'
      pos = open_start + 2
    else
      local close_start, close_end = line:find("]]", open_end + 1, true)
      if not close_start then break end
      local inner = line:sub(open_end + 1, close_start - 1)
      if callback(inner, open_start, close_end) then return end
      pos = close_end + 1
    end
  end
end

--- Same as scan_wikilinks but for embed syntax (![[...]]).
---@param line string
---@param callback fun(inner: string, start_col: number, end_col: number): boolean?
function M.scan_embeds(line, callback)
  local pos = 1
  while pos <= #line do
    local open_start, open_end = line:find(M.EMBED_OPEN, pos, false)
    if not open_start then break end
    local close_start, close_end = line:find("]]", open_end + 1, true)
    if not close_start then break end
    local inner = line:sub(open_end + 1, close_start - 1)
    if callback(inner, open_start, close_end) then return end
    pos = close_end + 1
  end
end

--- Scan for both wikilinks and embeds, distinguishing between them.
---@param line string
---@param callback fun(inner: string, start_col: number, end_col: number, is_embed: boolean): boolean?
function M.scan_all_links(line, callback)
  local pos = 1
  while pos <= #line do
    local open_start, open_end = line:find(M.WIKILINK_OPEN, pos, false)
    if not open_start then break end
    local is_embed = open_start > 1 and line:byte(open_start - 1) == 33
    if is_embed then open_start = open_start - 1 end
    local close_start, close_end = line:find("]]", open_end + 1, true)
    if not close_start then break end
    local inner = line:sub(open_end + 1, close_start - 1)
    if callback(inner, open_start, close_end, is_embed) then return end
    pos = close_end + 1
  end
end

-- ===========================================================================
-- vim.regex() Cache
-- ===========================================================================

local _regex_cache = {}
local _regex_count = 0
local _regex_max = 100

--- Get or compile a vim.regex() object.
--- Cached by pattern string, bounded to patterns.regex_cache_size entries.
---@param pattern string Vim regex pattern
---@return vim.regex Compiled regex object
function M.vim_regex(pattern)
  local cached = _regex_cache[pattern]
  if cached then return cached end

  if _regex_count >= _regex_max then
    _regex_cache = {}
    _regex_count = 0
  end

  local ok, regex = pcall(vim.regex, pattern)
  if not ok then
    error("patterns: invalid vim.regex pattern: " .. pattern .. " — " .. regex)
  end

  _regex_cache[pattern] = regex
  _regex_count = _regex_count + 1
  return regex
end

--- Configure the regex cache size limit.
---@param max_size number
function M.configure(max_size)
  if max_size then _regex_max = max_size end
end

-- ===========================================================================
-- Debug Introspection
-- ===========================================================================

--- Return cache statistics for :VaultCacheStats integration.
---@return table
function M.stats()
  -- Count only string constants (pattern definitions), not functions
  local pattern_count = 0
  for _, v in pairs(M) do
    if type(v) == "string" then pattern_count = pattern_count + 1 end
  end
  return {
    regex_cache_size = _regex_count,
    regex_cache_max = _regex_max,
    pattern_constants = pattern_count,
  }
end

return M
