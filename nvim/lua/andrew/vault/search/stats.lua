local config = require("andrew.vault.config")
local filter_utils = require("andrew.vault.filter_utils")
local notify = require("andrew.vault.notify")

local M = {}

-- Cache: aggregate_field_values results keyed by field_name, invalidated by generation
local _agg_cache = { gen = 0, fields = {} }

--- Count unique files in a result set (excluding group headers).
---@param entries string[]
---@param group_mode? string
---@return number
function M.count_unique_files(entries, group_mode)
  local search_group = require("andrew.vault.search_group")
  local seen = {}
  local count = 0
  for _, entry in ipairs(entries) do
    if not (group_mode and search_group.is_header(entry)) then
      local file = require("andrew.vault.search_filter").extract_rg_file(entry)
      if not seen[file] then
        seen[file] = true
        count = count + 1
      end
    end
  end
  return count
end

--- Count non-header entries in a result set.
---@param entries string[]
---@param group_mode? string
---@return number
function M.count_matches(entries, group_mode)
  if not group_mode then return #entries end
  local search_group = require("andrew.vault.search_group")
  local count = 0
  for _, entry in ipairs(entries) do
    if not search_group.is_header(entry) then
      count = count + 1
    end
  end
  return count
end

--- Format a stats summary string for search results.
---@param entries string[]
---@param group_mode? string
---@param elapsed_ms number
---@return string
function M.format_stats(entries, group_mode, elapsed_ms)
  local file_count = M.count_unique_files(entries, group_mode)
  local match_count = M.count_matches(entries, group_mode)
  return string.format(
    "%d match%s in %d file%s (%dms)",
    match_count, match_count == 1 and "" or "es",
    file_count, file_count == 1 and "" or "s",
    elapsed_ms
  )
end

--- Build the full list of known field names for suggestion/correction.
---@return string[]
function M.get_known_fields()
  local fields = {}
  -- Builtin fields from config
  for _, f in ipairs(config.search.builtin_fields) do
    fields[#fields + 1] = f
  end
  -- Field aliases
  for alias, _ in pairs(config.search.field_aliases) do
    fields[#fields + 1] = alias
  end
  -- Task prefixes
  for _, prefix in ipairs({
    "task", "task-todo", "task-done",
    "task-due", "task-priority", "task-tag",
    "task-state", "task-repeat", "task-completion",
    "task-scheduled",
  }) do
    fields[#fields + 1] = prefix
  end
  -- Special prefixes
  for _, special in ipairs({ "has", "graph", "group" }) do
    fields[#fields + 1] = special
  end
  return fields
end

--- Collect all field AST nodes from an AST tree.
---@param ast table
---@return table[] field_nodes (each has .name, can be mutated for auto-correct)
function M.collect_field_nodes(ast)
  if not ast then return {} end
  local nodes = {}
  if ast.type == "field" then
    nodes[#nodes + 1] = ast
  elseif ast.type == "and" or ast.type == "or" then
    vim.list_extend(nodes, M.collect_field_nodes(ast.left))
    vim.list_extend(nodes, M.collect_field_nodes(ast.right))
  elseif ast.type == "not" then
    vim.list_extend(nodes, M.collect_field_nodes(ast.operand))
  end
  return nodes
end

--- Check field names in the AST and warn about probable typos.
--- When auto_correct is enabled, mutates the AST in-place to fix field names.
---@param ast table
---@param idx table VaultIndex
function M.warn_unknown_fields(ast, idx)
  if not config.search or config.search.field_correction == false then return end
  local correction = config.search.field_correction or {}
  if correction.enabled == false then return end

  local known = M.get_known_fields()
  -- Add frontmatter keys observed in the index
  if idx and idx.all_frontmatter_keys then
    local fm_keys = idx:all_frontmatter_keys()
    if fm_keys then
      vim.list_extend(known, fm_keys)
    end
  end

  local field_nodes = M.collect_field_nodes(ast)
  local known_set = {}
  for _, f in ipairs(known) do known_set[f:lower()] = true end

  local search_query = require("andrew.vault.search_query")
  local max_dist = correction.max_distance or 2
  local auto_correct = correction.auto_correct == true
  for _, node in ipairs(field_nodes) do
    if not known_set[node.name:lower()] then
      local suggestion = search_query.suggest_field(node.name, known, max_dist)
      if suggestion then
        if auto_correct then
          local original = node.name
          node.name = suggestion
          notify.info(string.format("auto-corrected '%s' to '%s'", original, suggestion))
        else
          notify.warn(string.format("unknown field '%s' -- did you mean '%s'?", node.name, suggestion))
        end
      end
    end
  end
end

--- Aggregate all unique values for a field name from the vault index.
--- Returns values sorted by frequency (most common first).
---@param field_name string
---@return string[]
function M.aggregate_field_values(field_name)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return {} end

  local gen = idx._generation or 0
  if not filter_utils.is_cache_gen_valid(_agg_cache, gen) then
    _agg_cache = { gen = gen, fields = {} }
  end
  if _agg_cache.fields[field_name] then
    return _agg_cache.fields[field_name]
  end

  local counts = {}  -- value -> count

  local snap_files = idx:snapshot_files()
  for _, entry in pairs(snap_files) do
    local val = nil
    -- Check frontmatter
    if entry.frontmatter and entry.frontmatter[field_name] ~= nil then
      val = entry.frontmatter[field_name]
    end
    -- Check inline_fields
    if val == nil and entry.inline_fields and entry.inline_fields[field_name] ~= nil then
      val = entry.inline_fields[field_name]
    end
    -- Check field aliases
    if val == nil then
      local aliases = config.search.field_aliases
      local alias_path = aliases[field_name]
      if alias_path then
        local v = entry
        for part in alias_path:gmatch("[^%.]+") do
          if type(v) ~= "table" then v = nil; break end
          v = v[part]
        end
        val = v
      end
    end

    if val ~= nil then
      -- Handle list values (e.g., tags stored as arrays)
      if type(val) == "table" then
        for _, v in ipairs(val) do
          local sv = tostring(v)
          counts[sv] = (counts[sv] or 0) + 1
        end
      else
        local sv = tostring(val)
        counts[sv] = (counts[sv] or 0) + 1
      end
    end
  end

  -- Sort by frequency (descending), then alphabetically
  local sorted = {}
  for v, c in pairs(counts) do
    sorted[#sorted + 1] = { value = v, count = c }
  end
  table.sort(sorted, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.value < b.value
  end)

  local result = {}
  for _, item in ipairs(sorted) do
    result[#result + 1] = item.value
  end
  _agg_cache.fields[field_name] = result
  return result
end

return M
