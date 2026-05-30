--- Search result grouping for advanced vault search.
---
--- Takes flat result entries (rel_paths or ripgrep lines) and the vault index,
--- groups them by a specified field, and returns an ordered list with
--- ANSI-formatted group header lines interleaved.

local M = {}

local filter_utils = require("andrew.vault.filter_utils")
local link_utils = require("andrew.vault.link_utils")
local search_filter = require("andrew.vault.search_filter")

local ANSI = require("andrew.vault.ansi")

--- Sentinel prefix for group header lines.
--- Used to identify and skip headers in fzf actions.
M.HEADER_PREFIX = "\x01\x01"

--- Supported grouping modes.
M.MODES = {
  "folder",
  "type",
  "tag",
  "date",
  "month",
  "created",
  "status",
  "none",
}

--- Resolve the group key for a single result entry.
---@param rel_path string    vault-relative path
---@param mode string        grouping mode
---@param idx table          vault index instance
---@param spec? table        additional options (field, reverse)
---@return string key        group key (used for sorting/bucketing)
---@return string label      human-readable group label
function M.resolve_group_key(rel_path, mode, idx, spec)
  local file_entry = idx.files and idx.files[rel_path]

  if mode == "folder" then
    local dirname = link_utils.lua_dirname(rel_path)
    local folder = file_entry and file_entry.folder or (dirname ~= rel_path and dirname or "")
    if folder == "" then folder = "(root)" end
    return folder, folder
  end

  if mode == "type" then
    local t = file_entry and file_entry.frontmatter and file_entry.frontmatter.type
    if not t or t == "" then return "\xff(no type)", "(no type)" end
    return t:lower(), t
  end

  if mode == "tag" then
    if not file_entry or not file_entry.tags or #file_entry.tags == 0 then
      return "\xff(untagged)", "(untagged)"
    end
    local prefix = spec and spec.field
    if prefix then
      for _, tag in ipairs(file_entry.tags) do
        if tag:sub(1, #prefix) == prefix then
          return tag, tag
        end
      end
      return "\xff(no " .. prefix .. " tag)", "(no " .. prefix .. " tag)"
    end
    local first = file_entry.tags[1]
    local tag_level = spec and spec.tag_level or "prefix"
    if tag_level == "full" then
      return first, first
    end
    local top = first:match("^([^/]+)") or first
    return top, top
  end

  if mode == "date" or mode == "month" then
    local ts = file_entry and file_entry.mtime
    if not ts then return "\xff(unknown date)", "(unknown date)" end
    if mode == "date" then
      local d = os.date("%Y-%m-%d", ts)
      return d, d
    else
      local m = os.date("%Y-%m", ts)
      return m, os.date("%B %Y", ts)
    end
  end

  if mode == "created" then
    local ts = file_entry and filter_utils.get_entry_timestamp(file_entry, "created", 12)
    if not ts then return "\xff(unknown)", "(unknown)" end
    local d = os.date("%Y-%m-%d", ts)
    return d, d
  end

  if mode == "status" then
    local s = file_entry and (
      (file_entry.frontmatter and file_entry.frontmatter.status)
      or (file_entry.inline_fields and file_entry.inline_fields.status)
    )
    if not s or s == "" then return "\xff(no status)", "(no status)" end
    return s:lower(), s
  end

  -- Generic: try frontmatter field
  if file_entry and file_entry.frontmatter and file_entry.frontmatter[mode] then
    local v = tostring(file_entry.frontmatter[mode])
    return v:lower(), v
  end

  return "\xff(unknown)", "(unknown)"
end

--- Group flat result entries by the specified mode.
---
--- Returns a GroupResult with interleaved ANSI-formatted header lines
--- and original entry lines, ready for fzf_exec.
---
---@param entries string[]    flat result entries from resolve_query()
---@param mode string         grouping mode (one of M.MODES)
---@param idx table           vault index instance
---@param spec? table         additional grouping options
---@return table { entries: string[], group_count: number, total_count: number }
function M.group_entries(entries, mode, idx, spec)
  spec = spec or {}

  if mode == "none" or not mode then
    return { entries = entries, group_count = 0, total_count = #entries }
  end

  -- Phase 1: Bucket entries by group key
  local buckets = {}      -- key -> { label, entries[] }
  local key_order = {}    -- insertion-ordered keys
  local key_seen = {}

  for _, entry in ipairs(entries) do
    local rel_path = search_filter.extract_rg_file(entry)
    local key, label = M.resolve_group_key(rel_path, mode, idx, spec)

    if not key_seen[key] then
      key_seen[key] = true
      key_order[#key_order + 1] = key
      buckets[key] = { label = label, entries = {} }
    end
    local bucket = buckets[key]
    bucket.entries[#bucket.entries + 1] = entry
  end

  -- Phase 2: Sort groups
  if mode == "date" or mode == "month" or mode == "created" then
    local reverse = spec.reverse ~= false  -- default true for dates
    table.sort(key_order, function(a, b)
      if reverse then return a > b else return a < b end
    end)
  else
    -- Alphabetical, but push "\xff..." sentinel keys to the end
    table.sort(key_order, function(a, b)
      local a_sentinel = a:sub(1, 1) == "\xff"
      local b_sentinel = b:sub(1, 1) == "\xff"
      if a_sentinel ~= b_sentinel then return b_sentinel end
      return a < b
    end)
  end

  -- Phase 3: Interleave headers and entries
  local result = {}
  local group_count = #key_order

  for _, key in ipairs(key_order) do
    local bucket = buckets[key]
    local count = #bucket.entries
    local header = string.format(
      "%s%s%s%s  %s(%d)%s",
      M.HEADER_PREFIX,
      ANSI.bold, ANSI.blue, bucket.label,
      ANSI.dim, count, ANSI.reset
    )
    result[#result + 1] = header

    for _, entry in ipairs(bucket.entries) do
      result[#result + 1] = entry
    end
  end

  return {
    entries = result,
    group_count = group_count,
    total_count = #entries,
  }
end

--- Check if a selected fzf line is a group header (non-file entry).
---@param line string
---@return boolean
function M.is_header(line)
  return line:sub(1, #M.HEADER_PREFIX) == M.HEADER_PREFIX
end

--- Filter out group header lines from fzf selections, keeping only file entries.
---@param selected string[]|nil selected lines from fzf
---@return string[] filtered non-header lines
function M.filter_selected(selected)
  if not selected then return {} end
  local filtered = {}
  for _, line in ipairs(selected) do
    if not M.is_header(line) then
      filtered[#filtered + 1] = line
    end
  end
  return filtered
end

return M
