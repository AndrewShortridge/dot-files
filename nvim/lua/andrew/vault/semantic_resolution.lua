--- Layer 2: Semantic Resolution — resolves parsed tokens against vault state.
---
--- Cached separately from Layer 1 because resolution can be invalidated
--- independently (e.g., when vault_index._generation changes without any
--- buffer edits). Uses vault_index for link resolution and tag validation.

-- wikilinks/link_utils pull in the full engine graph; requiring them at module
-- top would force that load whenever semantic_resolution is required (breaking
-- standalone loads where engine isn't bootstrapped yet). Resolve them lazily on
-- first use and memoize in upvalues, so per-token resolution is an upvalue read
-- (no require()) without eager load-time coupling.
local _wikilinks, _link_utils
local function get_wikilinks()
  if not _wikilinks then _wikilinks = require("andrew.vault.wikilinks") end
  return _wikilinks
end
local function get_link_utils()
  if not _link_utils then _link_utils = require("andrew.vault.link_utils") end
  return _link_utils
end

local M = {}

---@class ResolvedToken
---@field token table the source LineToken from Layer 1
---@field line_nr number 0-indexed
---@field status string "valid"|"broken"|"external"|"ambiguous"|"unknown"
---@field target? string resolved file path
---@field metadata? table additional type-specific data

--- `tok_src[ln]` = the source token-array object `resolved[ln]` was built from
--- (line_parse_cache hands back the IDENTICAL table for unchanged lines, so an
--- object-identity match means the line's tokens are byte-identical → reuse the
--- prior wrappers verbatim instead of re-allocating ResolvedToken tables).
--- `link_gen[ln]` = the index generation a line was built at, recorded ONLY for
--- wikilink-bearing lines (link resolution targets can change without the line
--- text changing); absent for pure-passthrough lines, which never read the index.
---@type table<number, { gen: number, resolved: table<number, ResolvedToken[]>, tok_src: table<number, table>, link_gen: table<number, number> }>
local _cache = {}

--- Per-generation wikilink resolution memo (additional layer BENEATH the
--- per-line tok_src/link_gen identity guard in M.resolve). Keyed on raw
--- `link_text`; the entire table is dropped when the index generation advances,
--- so a generation bump can never serve a stale resolution. The same
--- `[[Note]]` appearing on multiple lines (or many times in one pass) resolves
--- once per generation instead of once per occurrence.
--- Values store the per-link resolution shape `{ status, target, metadata }`
--- WITHOUT the per-token `token`/`line_nr` fields (those are line-specific and
--- re-attached at call time), so a memo hit produces a result byte-identical to
--- a fresh computation for that line's token.
local _resolve_memo = {}
local _resolve_memo_gen = nil

--- Compute the link-text-dependent resolution payload for a wikilink.
--- This is the ONLY part of wikilink resolution that depends on the link text
--- and the vault index (parse_target + resolve_link); it is independent of the
--- token object and line number, which makes it safe to memoize per-generation.
--- Returns a payload shaped `{ status, target?, metadata? }` (no token/line_nr).
---@param link_text string
---@return { status: string, target?: string, metadata?: table }
local function compute_wikilink_payload(link_text)
  local link_utils = get_link_utils()

  -- Skip URL-like content
  if link_text:match("^https?://") then
    return { status = "external" }
  end

  local parsed = link_utils.parse_target(link_text)
  local target = parsed.name
  local heading = parsed.heading
  local block_id = parsed.block_id
  local alias = parsed.alias

  -- Self-reference (empty target)
  if not target or target == "" then
    return {
      status = "valid",
      metadata = { self_ref = true, heading = heading, block_id = block_id, alias = alias },
    }
  end

  -- Use the full wikilinks.resolve_link() for parity with legacy code
  -- (handles path-like links, temporal aliases, and index resolution)
  local resolved_path = get_wikilinks().resolve_link(target)

  if resolved_path then
    return {
      status = "valid",
      target = resolved_path,
      metadata = {
        heading = heading,
        block_id = block_id,
        alias = alias,
        parsed_name = target,
      },
    }
  else
    return {
      status = "broken",
      metadata = {
        link_text = target,
        heading = heading,
        block_id = block_id,
        alias = alias,
      },
    }
  end
end

--- Resolve a single wikilink token against the vault.
--- Uses wikilinks.resolve_link() for full resolution (index + path-like + temporal aliases),
--- matching the behavior of wikilink_highlights.lua's legacy code path.
---
--- The link-text/index-dependent payload is memoized per index generation in
--- `_resolve_memo` (keyed on raw link_text). The per-token `token`/`line_nr`
--- fields are re-attached from the (cheap, line-specific) arguments on every
--- call, so a memo hit produces a ResolvedToken byte-identical to a fresh
--- computation for this token.
---@param token table LineToken
---@param line_nr number 0-indexed
---@param cur_gen number index generation this resolution is bound to
---@return ResolvedToken
local function resolve_wikilink(token, line_nr, cur_gen)
  local link_text = token.captures and token.captures[1]
  if not link_text then
    return { token = token, line_nr = line_nr, status = "unknown" }
  end

  -- Drop the memo wholesale when the generation advances; a stale resolution
  -- must never survive an index change.
  if cur_gen ~= _resolve_memo_gen then
    _resolve_memo = {}
    _resolve_memo_gen = cur_gen
  end

  local payload = _resolve_memo[link_text]
  if payload == nil then
    payload = compute_wikilink_payload(link_text)
    _resolve_memo[link_text] = payload
  end

  return {
    token = token,
    line_nr = line_nr,
    status = payload.status,
    target = payload.target,
    metadata = payload.metadata,
  }
end

--- Resolve a tag token (passthrough — category is determined at render time
--- by pipeline_consumers via tag_highlights.find_tag_category()).
---@param token table LineToken
---@param line_nr number 0-indexed
---@return ResolvedToken
local function resolve_tag(token, line_nr)
  return {
    token = token,
    line_nr = line_nr,
    status = "valid",
  }
end

--- Resolve all tokens for specific lines.
---@param bufnr number
---@param line_nrs number[]|nil lines to resolve (nil = all cached)
---@param parse_cache table Line parse cache module (Layer 1)
---@param index table vault_index instance
function M.resolve(bufnr, line_nrs, parse_cache, index)
  local buf = _cache[bufnr]
  if not buf then
    buf = { gen = 0, resolved = {}, tok_src = {}, link_gen = {} }
    _cache[bufnr] = buf
  end
  buf.gen = index and index._generation or 0
  local cur_gen = buf.gen

  local function resolve_line(ln)
    local line_tokens = parse_cache.get_line_tokens(bufnr, ln)

    -- Reuse the prior wrappers verbatim when the source token array is the SAME
    -- object (unchanged line text). Pure-passthrough lines (no wikilink) never
    -- read the index, so identity alone is sufficient; wikilink-bearing lines
    -- also require the index generation to match (link targets can change
    -- without the line text changing).
    local prev = buf.resolved[ln]
    if prev ~= nil and buf.tok_src[ln] == line_tokens then
      local lg = buf.link_gen[ln]
      if lg == nil or lg == cur_gen then return end
    end

    local resolved = {}
    local has_link = false
    for _, tok in ipairs(line_tokens) do
      if tok.type == "wikilink" then
        has_link = true
        resolved[#resolved + 1] = resolve_wikilink(tok, ln, cur_gen)
      elseif tok.type == "tag" then
        resolved[#resolved + 1] = resolve_tag(tok, ln)
      else
        -- Passthrough: tasks, embeds, footnotes, headings, highlights, block_ids
        -- don't need index resolution
        resolved[#resolved + 1] = { token = tok, line_nr = ln, status = "valid" }
      end
    end
    buf.resolved[ln] = resolved
    buf.tok_src[ln] = line_tokens
    buf.link_gen[ln] = has_link and cur_gen or nil
  end

  if line_nrs then
    for _, ln in ipairs(line_nrs) do
      resolve_line(ln)
    end
  else
    -- Resolve all cached lines (used when index generation changes or full reparse)
    local cache_data = parse_cache._get_cache()
    local buf_parse = cache_data[bufnr]
    if buf_parse then
      for ln in pairs(buf_parse.lines) do
        resolve_line(ln)
      end
    end
  end
end

-- Shared immutable sentinel for the no-tokens case. Callers MUST treat the
-- returned list as read-only (verified: transform_pipeline and linkdiag both
-- iterate without mutating), so one frozen empty table is reused for every miss
-- instead of allocating a fresh {} per call. The __newindex guard makes any
-- future caller that tries to mutate it fail loudly rather than silently
-- corrupting shared state.
local EMPTY = setmetatable({}, {
  __newindex = function() error("semantic.get_resolved sentinel is read-only") end,
})

--- Get resolved tokens for a line.
---@param bufnr number
---@param line_nr number 0-indexed
---@return ResolvedToken[]
function M.get_resolved(bufnr, line_nr)
  local buf = _cache[bufnr]
  if not buf then return EMPTY end
  return buf.resolved[line_nr] or EMPTY
end

--- Check if resolution cache is stale (index generation changed).
---@param bufnr number
---@param current_gen number
---@return boolean
function M.is_stale(bufnr, current_gen)
  local buf = _cache[bufnr]
  return not buf or buf.gen ~= current_gen
end

--- Renumber resolved-token cache entries after an insert/delete of `delta`
--- rows at `start_row`. Renumbers the `resolved` map keys AND bumps each
--- ResolvedToken.line_nr (stored inside the value, read by linkdiag) so the
--- cache stays consistent with the buffer for the next incremental resolve.
---@param bufnr number
---@param start_row number 0-indexed row where the shift begins (post-edit)
---@param delta number net rows inserted (>0) or deleted (<0)
function M.shift_lines(bufnr, start_row, delta)
  if delta == 0 then return end
  local buf = _cache[bufnr]
  if not buf or not buf.resolved then return end
  local resolved = buf.resolved
  -- tok_src/link_gen mirror resolved's keys and MUST move in lockstep so the
  -- identity-reuse key stays bound to the correct line after an insert/delete.
  local tok_src = buf.tok_src
  local link_gen = buf.link_gen

  local function bump(list)
    if not list then return end
    for _, rt in ipairs(list) do
      rt.line_nr = rt.line_nr + delta
    end
  end

  local keys = {}
  for ln in pairs(resolved) do
    if ln >= start_row then keys[#keys + 1] = ln end
  end

  if delta > 0 then
    table.sort(keys, function(a, b) return a > b end)
    for _, ln in ipairs(keys) do
      bump(resolved[ln])
      resolved[ln + delta] = resolved[ln]
      resolved[ln] = nil
      tok_src[ln + delta] = tok_src[ln]
      tok_src[ln] = nil
      link_gen[ln + delta] = link_gen[ln]
      link_gen[ln] = nil
    end
  else
    table.sort(keys, function(a, b) return a < b end)
    for _, ln in ipairs(keys) do
      local dst = ln + delta -- delta < 0
      if dst >= start_row then
        bump(resolved[ln])
        resolved[dst] = resolved[ln]
        tok_src[dst] = tok_src[ln]
        link_gen[dst] = link_gen[ln]
      end
      resolved[ln] = nil
      tok_src[ln] = nil
      link_gen[ln] = nil
    end
  end
end

--- Invalidate all cached data for a buffer.
---@param bufnr number
function M.invalidate(bufnr)
  _cache[bufnr] = nil
end

return M
