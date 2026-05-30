local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")
local wikilinks = require("andrew.vault.wikilinks")
local sort_utils = require("andrew.vault.sort_utils")
local pat = require("andrew.vault.patterns")

local M = {}

local sort_by_name = sort_utils.sort_by_name

--- Disambiguate link entries that share the same display name by replacing
--- their name with the vault-relative path (without extension).
---@param entries {name: string, path: string|nil}[]
---@return {name: string, path: string|nil}[]
function M.disambiguate_names(entries)
  local groups = {}
  for _, entry in ipairs(entries) do
    local key = entry.name:lower()
    if not groups[key] then
      groups[key] = {}
    end
    groups[key][#groups[key] + 1] = entry
  end
  for _, group in pairs(groups) do
    if #group > 1 then
      for _, entry in ipairs(group) do
        if entry.path then
          local rel = engine.vault_relative(entry.path) or entry.path
          entry.name = link_utils.rel_to_stem(rel)
        end
      end
    end
  end
  return entries
end

--- Collect forward links from the current buffer (deduplicated, sorted).
--- Extracts the note name portion, stripping heading (#), block (^), and alias (|) parts.
--- Also skips embed syntax (![[...]]) prefix and inline field patterns ([key:: value]).
---@return {name: string, path: string|nil}[] link entries with display name and resolved path
function M.collect_forward_links()
  local resolve_link = wikilinks.resolve_link
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local seen = {} -- keyed by resolved path or lowercase name for dedup
  local resolved_names = {} -- track resolved names during collection
  local links = {}
  local in_frontmatter = false
  local frontmatter_done = false
  local in_code_fence = false
  for idx, line in ipairs(buf_lines) do
    -- Track YAML frontmatter (--- delimited, must start at line 1)
    if not frontmatter_done then
      if idx == 1 and line:match(pat.FM_OPEN) then
        in_frontmatter = true
        goto next_line
      elseif in_frontmatter then
        if line:match(pat.FM_OPEN) then
          in_frontmatter = false
          frontmatter_done = true
        end
        goto next_line
      else
        frontmatter_done = true
      end
    end

    -- Track fenced code blocks
    if link_utils.is_fence_delimiter(line) then
      in_code_fence = not in_code_fence
      goto next_line
    end
    if in_code_fence then goto next_line end

    pat.scan_wikilinks(line, function(inner)
      -- Skip inline field patterns: [key:: value]
      if inner:match("^[%w_%-]+::") then return end

      -- Extract just the note name: strip |alias, #heading, ^block
      local name = link_utils.parse_target(inner).name
      if name == "" then return end

      -- Skip heading-only or block-only references (no file target)
      if name:match("^[#%^]") then return end

      -- Extract display basename and resolve to full path
      local display = link_utils.get_tail(name)
      local path = resolve_link(display)
      local name_key = display:lower()
      if path then
        if seen[path] then return end
        seen[path] = true
        resolved_names[name_key] = true
      end
      if not path and seen[name_key] then return end
      seen[name_key] = true
      links[#links + 1] = { name = display, path = path }
    end)

    ::next_line::
  end
  -- Drop unresolved entries when a resolved entry with the same name exists
  local deduped = {}
  for _, entry in ipairs(links) do
    if entry.path or not resolved_names[entry.name:lower()] then
      deduped[#deduped + 1] = entry
    end
  end
  sort_by_name(deduped)
  return deduped
end

--- Collect backlinks using the vault index (O(1) lookup).
--- Returns empty when the index is not yet ready (non-blocking).
---@param note_name string
---@return {name: string, path: string}[] link entries with display name and absolute path
function M.collect_backlinks(note_name)
  local current_path = vim.api.nvim_buf_get_name(0)

  -- Try vault index first
  local idx = require("andrew.vault.vault_index").current()
  if idx and idx:is_ready() then
    local entry = idx:get_entry_by_abs(current_path)
    if entry then
      local inlinks = idx:get_inlinks(entry.rel_path)
      local backlinks = {}
      local seen = {}
      for _, inlink in ipairs(inlinks) do
        local source_rel = inlink.path .. ".md"
        local source_entry = idx:get_entry(source_rel)
        if source_entry and source_entry.abs_path ~= current_path and not seen[source_entry.abs_path] then
          seen[source_entry.abs_path] = true
          backlinks[#backlinks + 1] = { name = inlink.display, path = source_entry.abs_path }
        end
      end
      sort_by_name(backlinks)
      return backlinks
    end
  end

  -- Fallback: index not ready — return empty rather than blocking on ripgrep.
  -- The vault index is the sole source of truth (Phase 6); once it finishes
  -- its async build the next graph open will have full backlink data.
  return {}
end

return M
