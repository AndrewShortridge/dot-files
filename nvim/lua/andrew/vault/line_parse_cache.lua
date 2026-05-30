--- Layer 1: Line Parse Cache — LPEG single-pass tokenizer for all vault token types.
---
--- Replaces 5 independent pattern scans (wikilink, tag, highlight, footnote, embed)
--- with one LPEG tokenizer per line. Tokens are cached per-line and invalidated
--- incrementally via Layer 0 (line_tracker).
---
--- Line-level content dedup (config.pipeline.content_dedup) skips re-tokenization
--- for lines whose text hasn't changed (Lua string interning makes == O(1)).

local pat = require("andrew.vault.patterns")

local M = {}

---@class LineToken
---@field type string "wikilink"|"tag"|"embed"|"footnote"|"highlight"|"inline_field"|"task"|"heading"|"block_id"
---@field start_col number 0-indexed byte offset
---@field end_col number 0-indexed byte offset (exclusive)
---@field text string raw matched text
---@field subtype? string e.g. "embed_image", "footnote_def"
---@field captures? table type-specific parsed fields

---@type table<number, { tick: number, lines: table<number, LineToken[]>, texts: table<number, string> }>
local _cache = {}

--- Tags must be preceded by whitespace, start of line, or certain punctuation.
---@param line string
---@param pos number 1-indexed position of the `#`
---@return boolean
local function valid_tag_start(line, pos)
  if pos <= 1 then return true end
  local prev = line:sub(pos - 1, pos - 1)
  return prev:match("[%s%(%)%[%]{},;:\"']") ~= nil
end

--- Check if a tag-like match is actually a CSS hex color.
---@param tag string the text after #
---@return boolean
local function is_hex_color(tag)
  if not tag:match("^[0-9a-fA-F]+$") then return false end
  local len = #tag
  return len == 3 or len == 6 or len == 8
end

--- Footnote reference pattern: [^id] where id is alphanumeric, hyphens, or underscores.
--- Single source of truth — also used by footnotes.lua.
M.FOOTNOTE_REF_PAT = pat.FOOTNOTE_REF
local FOOTNOTE_REF_PAT = M.FOOTNOTE_REF_PAT

--- Check if a byte position overlaps any consumed range.
---@param col0 number 0-indexed start
---@param col1 number 0-indexed exclusive end
---@param consumed table[] sorted list of {start, end} pairs
---@return boolean
local function overlaps_consumed(col0, col1, consumed)
  for _, r in ipairs(consumed) do
    if col0 < r[2] and col1 > r[1] then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- LPEG Tokenizer — single-pass scanner compiled once at module load
-- Falls back to legacy string.find tokenizer if LPEG unavailable or disabled.
-- ---------------------------------------------------------------------------

local has_lpeg, lpeg = pcall(require, "lpeg")
local P, R, S, C, Cp, Ct, Cc
if has_lpeg then
  P, R, S, C, Cp, Ct, Cc = lpeg.P, lpeg.R, lpeg.S, lpeg.C, lpeg.Cp, lpeg.Ct, lpeg.Cc
end

-- LPEG patterns (only constructed if LPEG is available)
local lpeg_scanner
if has_lpeg then
  -- Individual token patterns (order = priority: first match at a position wins)
  local embed    = P"![[" * (1 - P"]]")^1 * P"]]"
  local wikilink = (-P"!" * P"[[") * (1 - P"]]")^1 * P"]]"
  local footnote = P"[^" * (R"az" + R"AZ" + R"09" + S"_-")^1 * P"]"
  local highlight_mark = P"==" * (1 - P"==")^1 * P"=="
  local tag_body = (R"az" + R"AZ") * (R"az" + R"AZ" + R"09" + S"_/-")^0
  local tag_pat  = P"#" * tag_body

  --- Build a capture that produces {start_pos, matched_text, end_pos, type_name}
  local function token_cap(type_name, pattern)
    return Ct(Cp() * C(pattern) * Cp() * Cc(type_name))
  end

  local token = token_cap("embed", embed)
              + token_cap("wikilink", wikilink)
              + token_cap("footnote", footnote)
              + token_cap("highlight", highlight_mark)
              + token_cap("tag", tag_pat)

  lpeg_scanner = Ct((token + P(1))^0)
end

--- Extract type-specific captures from matched text.
---@param ttype string
---@param text string
---@return table?
local function extract_captures(ttype, text)
  if ttype == "embed" then
    return { text:sub(4, -3) } -- strip ![[ and ]]
  elseif ttype == "wikilink" then
    return { text:sub(3, -3) } -- strip [[ and ]]
  elseif ttype == "footnote" then
    return { text:match(FOOTNOTE_REF_PAT) }
  elseif ttype == "highlight" then
    return { text:sub(3, -3) } -- strip == and ==
  elseif ttype == "tag" then
    return { text:sub(2) } -- strip #
  elseif ttype == "heading" then
    local hashes = text:match("^(#+)")
    return { level = hashes and #hashes or 1 }
  elseif ttype == "task" then
    local state = text:match("%[([ xX/-])%]")
    return { state = state or " " }
  elseif ttype == "block_id" then
    local id = text:match("%^(blk%-[%w]+)")
    return { id = id }
  end
  return nil
end

--- Detect footnote definition: [^id] at column 0 followed by ':'
---@param line_text string
---@param start_pos number 1-indexed
---@param end_pos number 1-indexed exclusive
---@return string?
local function detect_footnote_subtype(line_text, start_pos, end_pos)
  if start_pos == 1 and end_pos - 1 < #line_text and line_text:sub(end_pos, end_pos) == ":" then
    return "footnote_def"
  end
  return nil
end

-- Lazily cached inline_fields module (avoids pcall per line in hot path)
local _inline_fields_mod
local function get_inline_fields()
  if _inline_fields_mod == nil then
    local ok, mod = pcall(require, "andrew.vault.inline_fields")
    _inline_fields_mod = (ok and mod and mod.parse_line) and mod or false
  end
  return _inline_fields_mod
end

--- Collect inline field tokens from a line, appending to `tokens`.
--- Optionally checks overlap against `consumed` ranges.
---@param line_text string
---@param line_nr number
---@param code_excl fun(row: number, col: number): boolean
---@param tokens LineToken[]
---@param consumed table[]|nil consumed ranges for overlap check (nil = skip check)
local function collect_inline_fields(line_text, line_nr, code_excl, tokens, consumed)
  if not line_text:find("::", 1, true) then return end
  local mod = get_inline_fields()
  if not mod then return end
  local fields = mod.parse_line(line_text, line_nr)
  for _, field in ipairs(fields) do
    if not code_excl(line_nr, field.col_key_start) then
      if not consumed or not overlaps_consumed(field.col_start, field.col_end, consumed) then
        if consumed then consumed[#consumed + 1] = { field.col_start, field.col_end } end
        tokens[#tokens + 1] = {
          type = "inline_field",
          start_col = field.col_start,
          end_col = field.col_end,
          text = line_text:sub(field.col_start + 1, field.col_end),
          captures = { field },
        }
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Legacy tokenizer — 9-pass string.find/match approach (fallback)
-- ---------------------------------------------------------------------------

--- Legacy tokenizer using sequential string.find loops.
--- Used when LPEG is unavailable or config.pipeline.use_lpeg is false.
---@param line_text string
---@param line_nr number 0-indexed
---@param code_excl fun(row: number, col: number): boolean
---@return LineToken[]
local function tokenize_line_legacy(line_text, line_nr, code_excl)
  local tokens = {}
  local consumed = {} -- sorted list of {start, end} pairs (0-indexed)

  -- Pass 1: Embeds ![[...]]
  pat.scan_embeds(line_text, function(inner, start_col, end_col)
    local col0, col1 = start_col - 1, end_col -- 0-indexed, exclusive end
    if not overlaps_consumed(col0, col1, consumed) then
      consumed[#consumed + 1] = { col0, col1 }
      local text = line_text:sub(start_col, end_col)
      tokens[#tokens + 1] = {
        type = "embed",
        start_col = col0,
        end_col = col1,
        text = text,
        captures = extract_captures("embed", text),
      }
    end
  end)

  -- Pass 2: Wikilinks [[...]] (skip if preceded by !)
  pat.scan_wikilinks(line_text, function(inner, start_col, end_col)
    local col0, col1 = start_col - 1, end_col -- 0-indexed, exclusive end
    if not overlaps_consumed(col0, col1, consumed) then
      consumed[#consumed + 1] = { col0, col1 }
      local text = line_text:sub(start_col, end_col)
      tokens[#tokens + 1] = {
        type = "wikilink",
        start_col = col0,
        end_col = col1,
        text = text,
        captures = extract_captures("wikilink", text),
      }
    end
  end)

  -- Pass 3: Footnotes [^id]
  local pos = 1
  while true do
    local s, e, id = line_text:find(FOOTNOTE_REF_PAT, pos)
    if not s then break end
    local col0, col1 = s - 1, e
    if not overlaps_consumed(col0, col1, consumed) then
      consumed[#consumed + 1] = { col0, col1 }
      local text = line_text:sub(s, e)
      local subtype = detect_footnote_subtype(line_text, s, e + 1)
      tokens[#tokens + 1] = {
        type = "footnote",
        start_col = col0,
        end_col = col1,
        text = text,
        subtype = subtype,
        captures = { id },
      }
    end
    pos = e + 1
  end

  -- Pass 4: Highlights ==text==
  -- Match ==...== where content may contain single = but not ==
  -- (mirrors LPEG: P"==" * (1 - P"==")^1 * P"==")
  pos = 1
  while true do
    local s = line_text:find("==", pos, true)
    if not s then break end
    -- Scan for closing == that isn't part of ===
    local inner_start = s + 2
    local close = line_text:find("==", inner_start, true)
    if not close or close == inner_start then
      pos = s + 2
      goto continue_hl
    end
    local e = close + 1 -- inclusive end of closing ==
    local col0, col1 = s - 1, e
    if not overlaps_consumed(col0, col1, consumed) then
      if not code_excl(line_nr, col0) then
        consumed[#consumed + 1] = { col0, col1 }
        local text = line_text:sub(s, e)
        tokens[#tokens + 1] = {
          type = "highlight",
          start_col = col0,
          end_col = col1,
          text = text,
          captures = extract_captures("highlight", text),
        }
      end
    end
    pos = e + 1
    ::continue_hl::
  end

  -- Pass 5: Tags #tag (skip on heading lines)
  local is_heading_line = line_text:match("^#+ ") ~= nil
  if not is_heading_line then
    pos = 1
    while true do
      local hash = line_text:find("#", pos, true)
      if not hash then break end
      local tag_name = line_text:match("^([a-zA-Z][a-zA-Z0-9_/-]*)", hash + 1)
      if tag_name then
        if valid_tag_start(line_text, hash) and not is_hex_color(tag_name) then
          local col0 = hash - 1
          local col1 = col0 + 1 + #tag_name
          if not overlaps_consumed(col0, col1, consumed) then
            if not code_excl(line_nr, col0) then
              consumed[#consumed + 1] = { col0, col1 }
              local text = line_text:sub(hash, hash + #tag_name)
              tokens[#tokens + 1] = {
                type = "tag",
                start_col = col0,
                end_col = col1,
                text = text,
                captures = { tag_name },
              }
            end
          end
        end
        pos = hash + 1 + #tag_name
      else
        pos = hash + 1
      end
    end
  end

  -- Pass 6: Tasks — single SOL check
  local task_prefix, task_state = line_text:match("^(%s*[-*] %[)([ xX/-])%]")
  if task_prefix then
    local col1 = #task_prefix + 2
    tokens[#tokens + 1] = {
      type = "task",
      start_col = 0,
      end_col = col1,
      text = line_text:sub(1, col1),
      captures = { state = task_state },
    }
  end

  -- Pass 7: Headings — single SOL check
  local heading_hashes = line_text:match("^(#+)%s")
  if heading_hashes then
    local col1 = #heading_hashes + 1
    tokens[#tokens + 1] = {
      type = "heading",
      start_col = 0,
      end_col = col1,
      text = line_text:sub(1, col1),
      captures = { level = #heading_hashes },
    }
  end

  -- Pass 8: Inline fields (delegated to inline_fields.parse_line)
  collect_inline_fields(line_text, line_nr, code_excl, tokens, consumed)

  -- Pass 9: Block IDs — single EOL check
  local blk_id = line_text:match("%^(blk%-[%w]+)%s*$")
  if blk_id then
    local blk_start = line_text:find("%^blk%-[%w]+%s*$")
    if blk_start then
      local col0 = blk_start - 1
      local col1 = col0 + 1 + #blk_id
      tokens[#tokens + 1] = {
        type = "block_id",
        start_col = col0,
        end_col = col1,
        text = line_text:sub(blk_start, blk_start + #blk_id),
        captures = { id = blk_id },
      }
    end
  end

  table.sort(tokens, function(a, b) return a.start_col < b.start_col end)
  return tokens
end

-- ---------------------------------------------------------------------------
-- LPEG tokenizer wrapper
-- ---------------------------------------------------------------------------

--- LPEG-based tokenizer. Produces tokens in document order (no sort needed).
--- Post-filters: tag validation (hex color, predecessor char), code exclusion.
--- Inline fields delegated to inline_fields.parse_line().
---@param line_text string
---@param line_nr number 0-indexed
---@param code_excl fun(row: number, col: number): boolean
---@return LineToken[]
local function tokenize_line_lpeg(line_text, line_nr, code_excl)
  local raw = lpeg_scanner:match(line_text)
  if not raw or #raw == 0 then
    -- No LPEG-matchable tokens; still check inline fields + structural tokens
    local tokens = {}
    collect_inline_fields(line_text, line_nr, code_excl, tokens, nil)
    -- Structural tokens (SOL/EOL patterns) — must check even with no LPEG matches
    local heading_hashes = line_text:match("^(#+)%s")
    if heading_hashes then
      local col1 = #heading_hashes + 1
      tokens[#tokens + 1] = {
        type = "heading",
        start_col = 0,
        end_col = col1,
        text = line_text:sub(1, col1),
        captures = { level = #heading_hashes },
      }
    end
    local task_prefix, task_state = line_text:match("^(%s*[-*] %[)([ xX/-])%]")
    if task_prefix then
      local col1 = #task_prefix + 2
      tokens[#tokens + 1] = {
        type = "task",
        start_col = 0,
        end_col = col1,
        text = line_text:sub(1, col1),
        captures = { state = task_state },
      }
    end
    local blk_id = line_text:match("%^(blk%-[%w]+)%s*$")
    if blk_id then
      local blk_start = line_text:find("%^blk%-[%w]+%s*$")
      if blk_start then
        local col0 = blk_start - 1
        local col1 = col0 + 1 + #blk_id
        tokens[#tokens + 1] = {
          type = "block_id",
          start_col = col0,
          end_col = col1,
          text = line_text:sub(blk_start, blk_start + #blk_id),
          captures = { id = blk_id },
        }
      end
    end
    if #tokens > 1 then
      table.sort(tokens, function(a, b) return a.start_col < b.start_col end)
    end
    return tokens
  end

  local tokens = {}
  local consumed = {} -- still needed for inline field overlap check
  -- NOTE: heading detection duplicated with link_scan.is_heading_line() —
  -- accepted: this module avoids requires for hot-path performance.
  local is_heading_line = line_text:match("^#+ ") ~= nil

  for _, t in ipairs(raw) do
    local start_pos, text, end_pos, ttype = t[1], t[2], t[3], t[4]
    local col0 = start_pos - 1  -- 0-indexed
    local col1 = end_pos - 1    -- 0-indexed exclusive

    -- Per-type filtering
    if ttype == "tag" then
      if is_heading_line then goto continue end
      if not valid_tag_start(line_text, start_pos) then goto continue end
      local tag_name = text:sub(2)
      if is_hex_color(tag_name) then goto continue end
    end

    -- Code exclusion (skip for wikilinks, embeds, footnotes — mirrors current behavior)
    local skip_code_excl = (ttype == "embed" or ttype == "wikilink" or ttype == "footnote")
    if not skip_code_excl and code_excl(line_nr, col0) then
      goto continue
    end

    consumed[#consumed + 1] = { col0, col1 }
    local token = {
      type = ttype,
      start_col = col0,
      end_col = col1,
      text = text,
      captures = extract_captures(ttype, text),
    }

    -- Footnote definition detection
    if ttype == "footnote" then
      token.subtype = detect_footnote_subtype(line_text, start_pos, end_pos)
    end

    tokens[#tokens + 1] = token

    ::continue::
  end

  -- Inline fields (delegated to inline_fields.parse_line, with overlap check)
  collect_inline_fields(line_text, line_nr, code_excl, tokens, consumed)

  -- Structural tokens: heading, task, block_id (SOL/EOL patterns)
  -- These are position-dependent and handled outside the LPEG scanner.

  -- Heading: ^(#+) at start of line
  local heading_hashes = line_text:match("^(#+)%s")
  if heading_hashes then
    local col1 = #heading_hashes + 1 -- include the trailing space
    table.insert(tokens, 1, {
      type = "heading",
      start_col = 0,
      end_col = col1,
      text = line_text:sub(1, col1),
      captures = { level = #heading_hashes },
    })
  end

  -- Task: ^%s*[-*] [( xX/-)] at start of line
  local task_prefix, task_state = line_text:match("^(%s*[-*] %[)([ xX/-])%]")
  if task_prefix then
    local col0 = 0
    local col1 = #task_prefix + 2 -- includes state char and ]
    tokens[#tokens + 1] = {
      type = "task",
      start_col = col0,
      end_col = col1,
      text = line_text:sub(1, col1),
      captures = { state = task_state },
    }
  end

  -- Block ID: ^(blk-XXXX) at end of line (allows trailing whitespace)
  local blk_id = line_text:match("%^(blk%-[%w]+)%s*$")
  if blk_id then
    local blk_start = line_text:find("%^blk%-[%w]+%s*$")
    if blk_start then
      local col0 = blk_start - 1
      local col1 = col0 + 1 + #blk_id -- ^ + id
      tokens[#tokens + 1] = {
        type = "block_id",
        start_col = col0,
        end_col = col1,
        text = line_text:sub(blk_start, blk_start + #blk_id),
        captures = { id = blk_id },
      }
    end
  end

  -- LPEG produces tokens in document order; inline fields and structural
  -- tokens appended at end may interleave — sort only if needed.
  if #tokens > 1 then
    local needs_sort = false
    for i = 2, #tokens do
      if tokens[i].start_col < tokens[i - 1].start_col then
        needs_sort = true
        break
      end
    end
    if needs_sort then
      table.sort(tokens, function(a, b) return a.start_col < b.start_col end)
    end
  end

  return tokens
end

-- ---------------------------------------------------------------------------
-- Public tokenizer — dispatches to LPEG or legacy based on availability + config
-- ---------------------------------------------------------------------------

--- Tokenize a single line, producing all token types.
--- Uses LPEG single-pass tokenizer when available and enabled, otherwise
--- falls back to legacy 9-pass string.find tokenizer.
---@param line_text string
---@param line_nr number 0-indexed line number
---@param code_excl fun(row: number, col: number): boolean
---@return LineToken[]
function M.tokenize_line(line_text, line_nr, code_excl)
  local cfg = require("andrew.vault.config")
  local use_lpeg = cfg.pipeline and cfg.pipeline.use_lpeg
  if use_lpeg == nil then use_lpeg = true end
  if use_lpeg and has_lpeg then
    return tokenize_line_lpeg(line_text, line_nr, code_excl)
  end
  return tokenize_line_legacy(line_text, line_nr, code_excl)
end

--- Report which tokenizer mode is active.
---@return string "lpeg" or "legacy"
function M.tokenizer_mode()
  local cfg = require("andrew.vault.config")
  local use_lpeg = cfg.pipeline and cfg.pipeline.use_lpeg
  if use_lpeg == nil then use_lpeg = true end
  if use_lpeg and has_lpeg then return "lpeg" end
  return "legacy"
end

--- Pipeline stats: tracks reparsed vs skipped lines per update() call.
---@type { total_dirty: number, reparsed: number, skipped: number }
M._stats = { total_dirty = 0, reparsed = 0, skipped = 0 }

--- Get cached tokens for a line (populated by update()).
---@param bufnr number
---@param line_nr number 0-indexed
---@return LineToken[]
function M.get_line_tokens(bufnr, line_nr)
  local buf_cache = _cache[bufnr]
  if not buf_cache then return {} end
  return buf_cache.lines[line_nr] or {}
end

--- Evict cached lines outside the visible range when cache exceeds max size.
--- Keeps lines closest to the viewport, evicting the furthest first.
---@param buf_cache table { tick: number, lines: table<number, LineToken[]>, texts: table<number, string> }
---@param bufnr number
---@param max_lines number
local function evict_if_needed(buf_cache, bufnr, max_lines)
  if max_lines <= 0 then return end
  local count = 0
  for _ in pairs(buf_cache.lines) do
    count = count + 1
  end
  if count <= max_lines then return end

  -- Find visible center for proximity-based eviction
  local center
  local ok, vp = pcall(function()
    local viewport = require("andrew.vault.viewport")
    return viewport.get_range()
  end)
  if ok and vp then
    center = math.floor(((vp.first - 1) + (vp.last - 1)) / 2) -- 0-indexed
  else
    center = 0
  end

  -- Collect all line numbers and sort by distance from center (furthest first)
  local line_nrs = vim.tbl_keys(buf_cache.lines)
  table.sort(line_nrs, function(a, b)
    return math.abs(a - center) > math.abs(b - center)
  end)

  -- Evict until under limit (both tokens and texts)
  local to_evict = count - max_lines
  for i = 1, to_evict do
    local ln = line_nrs[i]
    buf_cache.lines[ln] = nil
    if buf_cache.texts then
      buf_cache.texts[ln] = nil
    end
  end
end

--- Re-parse specific lines and update the cache.
--- Called by the pipeline coordinator after Layer 0 identifies dirty lines.
--- Enhancement 2: When content_dedup is enabled, skips re-tokenization for
--- lines whose text hasn't changed (Lua string interning makes == O(1)).
---@param bufnr number
---@param line_nrs number[]|nil 0-indexed line numbers to re-parse (nil = all)
---@param code_excl fun(row: number, col: number): boolean
---@return number reparse_count number of lines actually re-tokenized
function M.update(bufnr, line_nrs, code_excl)
  local buf_cache = _cache[bufnr]
  if not buf_cache then
    buf_cache = { tick = 0, lines = {}, texts = {} }
    _cache[bufnr] = buf_cache
  end
  -- Ensure texts table exists (upgrade from old cache format)
  if not buf_cache.texts then
    buf_cache.texts = {}
  end
  buf_cache.tick = vim.api.nvim_buf_get_changedtick(bufnr)

  local cfg = require("andrew.vault.config")
  local dedup = cfg.pipeline and cfg.pipeline.content_dedup
  if dedup == nil then dedup = true end

  local reparse_count = 0

  if not line_nrs then
    -- Full parse: get all lines
    local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_lines = {}
    local new_texts = {}
    for i, text in ipairs(all_lines) do
      local ln = i - 1
      if dedup and buf_cache.texts[ln] == text then
        -- Content unchanged: reuse cached tokens
        new_lines[ln] = buf_cache.lines[ln]
      else
        new_lines[ln] = M.tokenize_line(text, ln, code_excl)
        reparse_count = reparse_count + 1
      end
      new_texts[ln] = text
    end
    buf_cache.lines = new_lines
    buf_cache.texts = new_texts
  else
    -- Incremental: only re-parse dirty lines with changed content
    for _, ln in ipairs(line_nrs) do
      local text = vim.api.nvim_buf_get_lines(bufnr, ln, ln + 1, false)[1]
      if text then
        if dedup and buf_cache.texts[ln] == text then
          -- Content unchanged: skip tokenization entirely
          goto continue
        end
        buf_cache.lines[ln] = M.tokenize_line(text, ln, code_excl)
        buf_cache.texts[ln] = text
        reparse_count = reparse_count + 1
      else
        buf_cache.lines[ln] = nil
        buf_cache.texts[ln] = nil
      end
      ::continue::
    end
  end

  -- Evict overflow lines (outside visible range) when cache exceeds max size
  local max = cfg.pipeline and cfg.pipeline.line_cache_max or 10000
  evict_if_needed(buf_cache, bufnr, max)

  -- Update stats for debug reporting
  local total_dirty = line_nrs and #line_nrs or (vim.api.nvim_buf_line_count(bufnr))
  M._stats.total_dirty = M._stats.total_dirty + total_dirty
  M._stats.reparsed = M._stats.reparsed + reparse_count
  M._stats.skipped = M._stats.skipped + (total_dirty - reparse_count)

  return reparse_count
end

--- Invalidate all cached data for a buffer.
---@param bufnr number
function M.invalidate(bufnr)
  _cache[bufnr] = nil
end

--- Iterate all cached tokens of a given type for a buffer.
---@param bufnr number
---@param token_type string
---@return fun(): number?, LineToken? iterator yielding (line_nr, token)
function M.iter_tokens(bufnr, token_type)
  local buf_cache = _cache[bufnr]
  if not buf_cache then return function() end end

  local line_nrs = vim.tbl_keys(buf_cache.lines)
  table.sort(line_nrs)
  local li, ti = 1, 0

  return function()
    while li <= #line_nrs do
      local ln = line_nrs[li]
      local line_tokens = buf_cache.lines[ln]
      ti = ti + 1
      while ti <= #line_tokens do
        if line_tokens[ti].type == token_type then
          return ln, line_tokens[ti]
        end
        ti = ti + 1
      end
      li = li + 1
      ti = 0
    end
  end
end

--- Get the internal cache (for Layer 2 iteration).
--- @return table<number, { tick: number, lines: table<number, LineToken[]>, texts: table<number, string> }>
function M._get_cache()
  return _cache
end

--- Convenience helper: acquire the pipeline parse cache and return an iterator
--- over tokens of the given type for `bufnr`, or nil when the pipeline / cache
--- is not available.  Eliminates repeated pcall + _get_cache + guard boilerplate.
---@param bufnr number buffer handle
---@param token_type string e.g. "wikilink", "tag", "highlight", "embed", "footnote"
---@return fun(): number?, LineToken?|nil iterator or nil if cache not warm
function M.pipeline_token_iter(bufnr, token_type)
  local p_ok, pipeline = pcall(require, "andrew.vault.transform_pipeline")
  if not p_ok then return nil end
  local parse_cache = pipeline.get_parse_cache()
  local cache_data = parse_cache._get_cache()
  if not cache_data[bufnr] then return nil end
  return parse_cache.iter_tokens(bufnr, token_type)
end

return M
