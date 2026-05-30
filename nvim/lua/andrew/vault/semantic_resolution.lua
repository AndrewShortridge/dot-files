--- Layer 2: Semantic Resolution — resolves parsed tokens against vault state.
---
--- Cached separately from Layer 1 because resolution can be invalidated
--- independently (e.g., when vault_index._generation changes without any
--- buffer edits). Uses vault_index for link resolution and tag validation.

local M = {}

---@class ResolvedToken
---@field token table the source LineToken from Layer 1
---@field line_nr number 0-indexed
---@field status string "valid"|"broken"|"external"|"ambiguous"|"unknown"
---@field target? string resolved file path
---@field metadata? table additional type-specific data

---@type table<number, { gen: number, resolved: table<number, ResolvedToken[]> }>
local _cache = {}

--- Resolve a single wikilink token against the vault.
--- Uses wikilinks.resolve_link() for full resolution (index + path-like + temporal aliases),
--- matching the behavior of wikilink_highlights.lua's legacy code path.
---@param token table LineToken
---@param link_utils table link_utils module
---@param line_nr number 0-indexed
---@return ResolvedToken
local function resolve_wikilink(token, link_utils, line_nr)
  local link_text = token.captures and token.captures[1]
  if not link_text then
    return { token = token, line_nr = line_nr, status = "unknown" }
  end

  -- Skip URL-like content
  if link_text:match("^https?://") then
    return { token = token, line_nr = line_nr, status = "external" }
  end

  local parsed = link_utils.parse_target(link_text)
  local target = parsed.name
  local heading = parsed.heading
  local block_id = parsed.block_id
  local alias = parsed.alias

  -- Self-reference (empty target)
  if not target or target == "" then
    return {
      token = token,
      line_nr = line_nr,
      status = "valid",
      metadata = { self_ref = true, heading = heading, block_id = block_id, alias = alias },
    }
  end

  -- Use the full wikilinks.resolve_link() for parity with legacy code
  -- (handles path-like links, temporal aliases, and index resolution)
  local wikilinks = require("andrew.vault.wikilinks")
  local resolved_path = wikilinks.resolve_link(target)

  if resolved_path then
    return {
      token = token,
      line_nr = line_nr,
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
      token = token,
      line_nr = line_nr,
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
    buf = { gen = 0, resolved = {} }
    _cache[bufnr] = buf
  end
  buf.gen = index and index._generation or 0

  local lu = require("andrew.vault.link_utils")

  local function resolve_line(ln)
    local line_tokens = parse_cache.get_line_tokens(bufnr, ln)
    local resolved = {}
    for _, tok in ipairs(line_tokens) do
      if tok.type == "wikilink" then
        resolved[#resolved + 1] = resolve_wikilink(tok, lu, ln)
      elseif tok.type == "tag" then
        resolved[#resolved + 1] = resolve_tag(tok, ln)
      else
        -- Passthrough: tasks, embeds, footnotes, headings, highlights, block_ids
        -- don't need index resolution
        resolved[#resolved + 1] = { token = tok, line_nr = ln, status = "valid" }
      end
    end
    buf.resolved[ln] = resolved
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

--- Get resolved tokens for a line.
---@param bufnr number
---@param line_nr number 0-indexed
---@return ResolvedToken[]
function M.get_resolved(bufnr, line_nr)
  local buf = _cache[bufnr]
  if not buf then return {} end
  return buf.resolved[line_nr] or {}
end

--- Check if resolution cache is stale (index generation changed).
---@param bufnr number
---@param current_gen number
---@return boolean
function M.is_stale(bufnr, current_gen)
  local buf = _cache[bufnr]
  return not buf or buf.gen ~= current_gen
end

--- Invalidate all cached data for a buffer.
---@param bufnr number
function M.invalidate(bufnr)
  _cache[bufnr] = nil
end

return M
