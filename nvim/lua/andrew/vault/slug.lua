-- slug.lua — Pure heading-to-slug conversion.
-- Dependencies: lru_cache (zero external deps), config.

local lru = require("andrew.vault.lru_cache")
local config = require("andrew.vault.config")
local pat = require("andrew.vault.patterns")

local M = {}

local _slug_cache = lru.new(config.cache.slug_max)

--- Convert heading text to a URL-safe slug for anchor matching.
--- Matches Obsidian's heading anchor format.
---@param text string  The heading text (without the # prefix)
---@return string
function M.heading_to_slug(text)
  local cached = _slug_cache:get(text)
  if cached then return cached end

  local slug = text:lower()
    :gsub(pat.SLUG_STRIP_SPECIAL, "")
    :gsub(pat.SLUG_COLLAPSE_SPACES, "-")
    :gsub(pat.SLUG_COLLAPSE_DASHES, "-")
    :gsub(pat.SLUG_TRIM_LEADING, "")
    :gsub(pat.SLUG_TRIM_TRAILING, "")

  _slug_cache:put(text, slug)

  return slug
end

return M
