local config = require("andrew.vault.config")

local M = {}

--- Wrap value in quotes if it contains spaces, then prepend prefix.
local function quoted_candidate(prefix, value)
  if value:find(" ") then
    return prefix .. '"' .. value .. '"'
  end
  return prefix .. value
end


--- Generate completion candidates for advanced search input.
---@param lead string current word being typed
---@return string[] candidates
function M._complete_advanced(lead)
  local stats = require("andrew.vault.search.stats")
  local completion_base = require("andrew.vault.completion_base")
  local candidates = {}
  local idx = completion_base.get_ready_index()
  local idx_ready = idx ~= nil

  -- Field names (builtin + aliases + special prefixes)
  for _, f in ipairs(stats.get_known_fields()) do
    local candidate = f .. ":"
    if vim.startswith(candidate, lead) then
      candidates[#candidates + 1] = candidate
    end
  end

  -- Boolean operators
  local lead_upper = lead:upper()
  for _, kw in ipairs({ "AND", "OR", "NOT" }) do
    if vim.startswith(kw, lead_upper) then
      candidates[#candidates + 1] = kw
    end
  end

  -- graph: operator completion
  if lead:match("^graph:") then
    local prefix = "graph:"
    local rest = lead:sub(#prefix + 1)
    local graph_completions = {
      "depth=1", "depth=2", "depth=3",
      "dir=forward", "dir=backward", "dir=both",
      "neighbors", "extended",
    }
    for _, c in ipairs(graph_completions) do
      if vim.startswith(c, rest) then
        candidates[#candidates + 1] = prefix .. c
      end
    end
  end

  -- After group: suggest grouping modes
  if lead:match("^group:") then
    local prefix = "group:"
    local rest = lead:sub(#prefix + 1)
    local search_group = require("andrew.vault.search_group")
    for _, mode in ipairs(search_group.MODES) do
      if vim.startswith(mode, rest) then
        candidates[#candidates + 1] = prefix .. mode
      end
    end
  end

  -- After has: suggest targets
  if lead:match("^has:") then
    local prefix = "has:"
    local rest = lead:sub(#prefix + 1)
    local has_targets = config.search.has_targets
    for _, target in ipairs(has_targets) do
      if vim.startswith(target, rest) then
        candidates[#candidates + 1] = prefix .. target
      end
    end
  end

  -- After type: suggest note types
  if lead:match("^type:") then
    local prefix = "type:"
    local rest = lead:sub(#prefix + 1)
    for _, t in ipairs(config.note_types or {}) do
      if vim.startswith(t, rest) then
        candidates[#candidates + 1] = prefix .. t
      end
    end
  end

  -- After status: suggest status values
  if lead:match("^status:") then
    local prefix = "status:"
    local rest = lead:sub(#prefix + 1):lower()
    for _, s in ipairs(config.status_values or {}) do
      if vim.startswith(s:lower(), rest) then
        candidates[#candidates + 1] = quoted_candidate(prefix, s)
      end
    end
  end

  -- After tag: or task-tag: suggest tags from index; also tag exclusions
  if idx_ready then
    local all_tags = idx:all_tags()

    for _, tag_prefix in ipairs({ "tag:", "task-tag:" }) do
      local pat = "^" .. tag_prefix:gsub("%-", "%%-")
      if lead:match(pat) then
        local rest = lead:sub(#tag_prefix + 1)
        for _, t in ipairs(all_tags) do
          if vim.startswith(t, rest) then
            candidates[#candidates + 1] = tag_prefix .. t
          end
        end
      end
    end

    -- After tag:xxx, suggest exclusion tags
    if lead:match("^tag:.+,$") or lead:match("^tag:.+,%-$") then
      local base_part = lead:match("^(tag:[^,]+)")
      if base_part then
        local base_tag = base_part:sub(5) -- strip "tag:"
        local base_tag_lower_slash = base_tag:lower() .. "/"
        for _, t in ipairs(all_tags) do
          local t_lower = t:lower()
          if vim.startswith(t_lower, base_tag_lower_slash) then
            local subtag = t:sub(#base_tag + 2) -- relative subtag name
            candidates[#candidates + 1] = base_part .. ",-" .. subtag
          end
        end
      end
    end
  end

  -- After links-to: or linked-from: suggest note names from index (cached)
  for _, link_prefix in ipairs({ "links-to:", "linked-from:" }) do
    local pat = "^" .. link_prefix:gsub("%-", "%%-")
    if lead:match(pat) then
      local rest_lower = lead:sub(#link_prefix + 1):lower()
      local names = idx_ready and idx:sorted_names() or {}
      for _, n in ipairs(names) do
        if vim.startswith(n.name_lower, rest_lower) then
          candidates[#candidates + 1] = quoted_candidate(link_prefix, n.name)
        end
      end
    end
  end

  -- After links-to:NoteName# or linked-from:NoteName# suggest headings
  for _, link_prefix in ipairs({ "links-to:", "linked-from:" }) do
    local pat = "^" .. link_prefix:gsub("%-", "%%-") .. ".+#"
    if lead:match(pat) then
      local note_name = lead:match("^" .. link_prefix:gsub("%-", "%%-") .. "(.+)#")
      if note_name then
        -- Strip quotes if present
        local was_quoted = note_name:match('^"') ~= nil
        note_name = note_name:gsub('^"', ""):gsub('"$', "")
        -- Extract partial heading text after # for filtering
        local partial_heading = lead:match("#(.*)$") or ""
        local partial_lower = partial_heading:lower()
        if idx_ready then
          local abs_paths = idx:resolve_name(note_name)
          if abs_paths and #abs_paths > 0 then
            local heading_entry = idx:get_entry_by_abs(abs_paths[1])
            if heading_entry and heading_entry.headings then
              -- Build prefix with properly balanced quotes
              local prefix_str
              if was_quoted then
                prefix_str = link_prefix .. '"' .. note_name .. '"#'
              else
                prefix_str = link_prefix .. note_name .. "#"
              end
              for _, h in ipairs(heading_entry.headings) do
                if vim.startswith(h.text_lower, partial_lower) then
                  candidates[#candidates + 1] = prefix_str .. h.text
                end
              end
            end
          end
        end
      end
    end
  end

  -- After alias: suggest known aliases from index
  if lead:match("^alias:") then
    local prefix = "alias:"
    local rest = lead:sub(#prefix + 1):lower()
    if idx_ready then
      for _, a in ipairs(idx:all_aliases()) do
        if vim.startswith(a, rest) then
          candidates[#candidates + 1] = quoted_candidate(prefix, a)
        end
      end
    end
  end

  -- After task-state: suggest state labels
  if lead:match("^task%-state:") then
    local prefix = "task-state:"
    local rest = lead:sub(#prefix + 1)
    for _, state in ipairs(config.task_states) do
      if vim.startswith(state.label, rest) then
        candidates[#candidates + 1] = quoted_candidate(prefix, state.label)
      end
    end
  end

  -- After task-priority: suggest priority values
  if lead:match("^task%-priority:") then
    local prefix = "task-priority:"
    local rest = lead:sub(#prefix + 1)
    for _, p in ipairs(config.priority_values) do
      local ps = tostring(p)
      if vim.startswith(ps, rest) then
        candidates[#candidates + 1] = prefix .. ps
      end
    end
  end

  -- After task-due:, task-completion:, task-scheduled: suggest date shortcuts
  local date_task_prefixes = { "task-due:", "task-completion:", "task-scheduled:" }
  for _, dp in ipairs(date_task_prefixes) do
    if lead:match("^" .. dp:gsub("%-", "%%-")) then
      local rest = lead:sub(#dp + 1)
      for _, shortcut in ipairs({
        "today", "yesterday", "this-week", "last-week",
        "this-month", "last-month", "<7d", "<30d", "<today",
      }) do
        if vim.startswith(shortcut, rest) then
          candidates[#candidates + 1] = dp .. shortcut
        end
      end
    end
  end

  -- Generic field value completion: if lead is "fieldname:partial" and no
  -- specific handler matched above, aggregate values from the vault index.
  if #candidates == 0 and lead:find(":", 1, true) then
    local colon = lead:find(":", 1, true)
    local field_name = lead:sub(1, colon - 1):lower()
    local prefix = lead:sub(1, colon)
    local rest = lead:sub(colon + 1):lower()

    -- Skip fields already handled above
    local handled = {
      type = true, status = true, tag = true, has = true,
      group = true, graph = true,
      ["links-to"] = true, ["linked-from"] = true, alias = true,
      ["task-state"] = true, ["task-priority"] = true,
      ["task-due"] = true, ["task-completion"] = true,
      ["task-scheduled"] = true, ["task-tag"] = true,
      ["task-repeat"] = true,
      task = true, ["task-todo"] = true, ["task-done"] = true,
    }
    if not handled[field_name] then
      -- Check config-defined enums first
      local enums = config.search.field_enums
      if enums[field_name] then
        for _, v in ipairs(enums[field_name]) do
          if vim.startswith(v:lower(), rest) then
            candidates[#candidates + 1] = quoted_candidate(prefix, v)
          end
        end
      else
        -- Aggregate from index
        local values = stats.aggregate_field_values(field_name)
        for _, v in ipairs(values) do
          if vim.startswith(v:lower(), rest) then
            candidates[#candidates + 1] = quoted_candidate(prefix, v)
          end
        end
      end
    end
  end

  return candidates
end

return M
