local config = require("andrew.vault.config")
local filter_utils = require("andrew.vault.filter_utils")
local link_utils = require("andrew.vault.link_utils")
local notify = require("andrew.vault.notify")
local string_intern = require("andrew.vault.string_intern")
local ui = require("andrew.vault.ui")

local _lowercase_pool = string_intern.new(5000)

local M = {}

-- ---------------------------------------------------------------------------
-- Data collection (single pass)
-- ---------------------------------------------------------------------------

---@class VaultStatsData
---@field total_notes number
---@field total_tags number
---@field total_outlinks number
---@field total_inlinks number
---@field orphan_count number
---@field orphan_pct number
---@field broken_link_count number
---@field broken_link_notes number
---@field top_connected { name: string, rel_path: string, degree: number }[]
---@field tag_counts { tag: string, count: number }[]
---@field type_counts table<string, number>
---@field folder_counts table<string, number>
---@field month_counts table<string, number>
---@field task_counts table<string, number>
---@field task_total number
---@field total_aliases number
---@field total_headings number
---@field total_block_ids number
---@field avg_outlinks number
---@field avg_tags number

--- Compute all vault statistics from the index in a single pass.
--- When summary tree is available, aggregate counts (file, tag, task, link,
--- heading, alias, block_id, folder) are served from the tree in O(1).
--- Per-entry iteration is still needed for broken links, orphans, connectivity,
--- type/month distributions, and total inlinks.
---@param idx VaultIndex
---@return VaultStatsData
function M.compute(idx)
  local files = idx:snapshot_files()
  local inlinks = idx._inlinks

  -- O(1) aggregate counts from summary tree
  local tree_root = idx._summary_tree:query("")
  local total_notes = tree_root.file_count
  local total_outlinks = tree_root.link_count
  local total_headings = tree_root.heading_count
  local total_aliases = tree_root.alias_count
  local total_block_ids = tree_root.block_id_count
  local task_total = tree_root.task_count
  local task_counts = tree_root.task_status_counts
  local tag_file_counts = tree_root.tag_file_counts

  -- Folder counts from tree root children (O(C_root))
  local folder_counts = {}
  for name, child in pairs(idx._summary_tree.root.children) do
    if not child.is_leaf then
      folder_counts[name] = child.file_count
    else
      folder_counts["(root)"] = (folder_counts["(root)"] or 0) + 1
    end
  end

  -- Total tag references from tree (O(T) where T = unique tags)
  local total_tags_refs = 0
  for _, count in pairs(tree_root.tag_counts) do
    total_tags_refs = total_tags_refs + count
  end

  -- Fields that require per-entry iteration
  local orphan_count = 0
  local broken_link_count = 0
  local broken_link_notes = 0
  local type_counts = {}
  local month_counts = {}
  local degree_map = {}

  for rel_path, entry in pairs(files) do
    -- Inlinks + degree
    local in_count = #(inlinks[rel_path] or {})
    local out_count = #entry.outlinks
    degree_map[rel_path] = {
      name = entry.basename,
      degree = in_count + out_count,
    }

    -- Orphan: zero inbound links
    if in_count == 0 then
      orphan_count = orphan_count + 1
    end

    -- Broken links: check each outlink target
    local has_broken = false
    for _, link in ipairs(entry.outlinks) do
      local lower = string_intern.intern(_lowercase_pool, filter_utils.normalize_link_name(link.path or ""))
      if lower then
        local name = link_utils.rel_to_stem(lower)
        local basename = link_utils.get_basename(name)
        local resolved = idx:resolve_name(basename)
        if not resolved or #resolved == 0 then
          resolved = idx:resolve_name(name)
        end
        if not resolved or #resolved == 0 then
          broken_link_count = broken_link_count + 1
          has_broken = true
        end
      end
    end
    if has_broken then
      broken_link_notes = broken_link_notes + 1
    end

    -- Type (from frontmatter)
    local note_type = entry.frontmatter and entry.frontmatter.type
    if note_type then
      local t = tostring(note_type)
      type_counts[t] = (type_counts[t] or 0) + 1
    else
      type_counts["(untyped)"] = (type_counts["(untyped)"] or 0) + 1
    end

    -- Monthly activity
    local month_key = nil
    if entry.day then
      month_key = entry.day:sub(1, 7)
    elseif entry.ctime and entry.ctime > 0 then
      month_key = os.date("%Y-%m", entry.ctime)
    end
    if month_key then
      month_counts[month_key] = (month_counts[month_key] or 0) + 1
    end
  end

  -- Build sorted tag list (top N)
  local tag_list = {}
  for tag, count in pairs(tag_file_counts) do
    tag_list[#tag_list + 1] = { tag = tag, count = count }
  end
  table.sort(tag_list, function(a, b) return a.count > b.count end)

  -- Build sorted top-connected list
  local connected = {}
  for rel_path, info in pairs(degree_map) do
    if info.degree > 0 then
      connected[#connected + 1] = {
        name = info.name,
        rel_path = rel_path,
        degree = info.degree,
      }
    end
  end
  table.sort(connected, function(a, b) return a.degree > b.degree end)

  -- Unique tag count
  local unique_tag_count = vim.tbl_count(tag_file_counts)

  -- Total inlinks (sum across all files)
  local total_inlinks = 0
  for _, links in pairs(inlinks) do
    total_inlinks = total_inlinks + #links
  end

  return {
    total_notes = total_notes,
    total_tags = unique_tag_count,
    total_outlinks = total_outlinks,
    total_inlinks = total_inlinks,
    orphan_count = orphan_count,
    orphan_pct = total_notes > 0 and (orphan_count / total_notes * 100) or 0,
    broken_link_count = broken_link_count,
    broken_link_notes = broken_link_notes,
    top_connected = connected,
    tag_counts = tag_list,
    type_counts = type_counts,
    folder_counts = folder_counts,
    month_counts = month_counts,
    task_counts = task_counts,
    task_total = task_total,
    total_aliases = total_aliases,
    total_headings = total_headings,
    total_block_ids = total_block_ids,
    avg_outlinks = total_notes > 0 and (total_outlinks / total_notes) or 0,
    avg_tags = total_notes > 0 and (total_tags_refs / total_notes) or 0,
  }
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

--- Task status label lookup (mirrors config.task_states).
local TASK_LABELS = {}
for _, state in ipairs(config.task_states) do
  TASK_LABELS[state.mark] = state.label
end

--- Format a number with thousand separators.
---@param n number
---@return string
local function fmt_num(n)
  if n < 1000 then return tostring(n) end
  local s = string.format("%d", n)
  local result = ""
  local len = #s
  for i = 1, len do
    if i > 1 and (len - i + 1) % 3 == 0 then
      result = result .. ","
    end
    result = result .. s:sub(i, i)
  end
  return result
end

--- Build the formatted lines and highlight annotations for the dashboard.
---@param data VaultStatsData
---@return string[] lines
---@return { line: number, hl: string, col_start: number, col_end: number }[] highlights
function M.format(data)
  local lines = {}
  local highlights = {}

  local function add(text)
    lines[#lines + 1] = text
  end

  local function add_hl(text, hl_group)
    local line_idx = #lines
    lines[#lines + 1] = text
    highlights[#highlights + 1] = {
      line = line_idx,
      hl = hl_group,
      col_start = 0,
      col_end = -1,
    }
  end

  local function add_separator()
    add("")
  end

  -- ===== OVERVIEW =====
  add_hl("  Overview", "Title")
  add(string.rep("-", config.stats.separator_width))
  add(string.format("  Notes:       %s", fmt_num(data.total_notes)))
  add(string.format("  Unique tags: %s", fmt_num(data.total_tags)))
  add(string.format("  Outlinks:    %s  (avg %.1f/note)", fmt_num(data.total_outlinks), data.avg_outlinks))
  add(string.format("  Inlinks:     %s", fmt_num(data.total_inlinks)))
  add(string.format("  Aliases:     %s", fmt_num(data.total_aliases)))
  add(string.format("  Headings:    %s", fmt_num(data.total_headings)))
  add(string.format("  Block IDs:   %s", fmt_num(data.total_block_ids)))
  add(string.format("  Avg tags:    %.1f/note", data.avg_tags))

  add_separator()

  -- ===== HEALTH =====
  add_hl("  Health", "Title")
  add(string.rep("-", config.stats.separator_width))

  -- Orphans
  local orphan_hl = data.orphan_pct > 30 and "DiagnosticWarn" or "DiagnosticInfo"
  local orphan_line = string.format(
    "  Orphans:      %s / %s  (%.0f%%)",
    fmt_num(data.orphan_count), fmt_num(data.total_notes), data.orphan_pct
  )
  add_hl(orphan_line, orphan_hl)

  -- Broken links
  if data.broken_link_count > 0 then
    add_hl(
      string.format(
        "  Broken links: %s across %s note(s)",
        fmt_num(data.broken_link_count), fmt_num(data.broken_link_notes)
      ),
      "DiagnosticError"
    )
  else
    add_hl("  Broken links: 0", "DiagnosticOk")
  end

  add_separator()

  -- ===== MOST CONNECTED =====
  add_hl("  Most Connected Notes (top 10)", "Title")
  add(string.rep("-", config.stats.separator_width))

  local max_connected = math.min(10, #data.top_connected)
  for i = 1, max_connected do
    local item = data.top_connected[i]
    add(string.format("  %2d. %-30s %3d links", i, item.name, item.degree))
  end
  if max_connected == 0 then
    add("  (no connected notes)")
  end

  add_separator()

  -- ===== TAG DISTRIBUTION =====
  add_hl("  Tag Distribution (top 15)", "Title")
  add(string.rep("-", config.stats.separator_width))

  local max_tags = math.min(15, #data.tag_counts)
  if max_tags > 0 then
    -- Find max count for bar chart scaling
    local max_count = data.tag_counts[1].count
    for i = 1, max_tags do
      local item = data.tag_counts[i]
      local bar_len = math.max(1, math.floor(item.count / max_count * 20))
      local bar = string.rep("*", bar_len)
      add(string.format("  #%-20s %4d  %s", item.tag, item.count, bar))
    end
  else
    add("  (no tags)")
  end

  add_separator()

  -- ===== NOTES BY TYPE =====
  add_hl("  Notes by Type", "Title")
  add(string.rep("-", config.stats.separator_width))

  -- Sort types by count descending
  local type_list = {}
  for t, count in pairs(data.type_counts) do
    type_list[#type_list + 1] = { name = t, count = count }
  end
  table.sort(type_list, function(a, b) return a.count > b.count end)

  for _, item in ipairs(type_list) do
    add(string.format("  %-20s %4d", item.name, item.count))
  end
  if #type_list == 0 then
    add("  (no frontmatter types)")
  end

  add_separator()

  -- ===== NOTES BY FOLDER =====
  add_hl("  Notes by Folder", "Title")
  add(string.rep("-", config.stats.separator_width))

  local folder_list = {}
  for folder, count in pairs(data.folder_counts) do
    folder_list[#folder_list + 1] = { name = folder, count = count }
  end
  table.sort(folder_list, function(a, b) return a.count > b.count end)

  for _, item in ipairs(folder_list) do
    add(string.format("  %-20s %4d", item.name, item.count))
  end
  if #folder_list == 0 then
    add("  (no folders)")
  end

  add_separator()

  -- ===== ACTIVITY TIMELINE =====
  add_hl("  Activity (notes per month)", "Title")
  add(string.rep("-", config.stats.separator_width))

  -- Sort months chronologically and show last 12
  local month_list = {}
  for month, count in pairs(data.month_counts) do
    month_list[#month_list + 1] = { month = month, count = count }
  end
  table.sort(month_list, function(a, b) return a.month > b.month end)

  local max_months = math.min(12, #month_list)
  if max_months > 0 then
    -- Find max for bar scaling (within displayed range)
    local max_month_count = 0
    for i = 1, max_months do
      if month_list[i].count > max_month_count then
        max_month_count = month_list[i].count
      end
    end
    -- Display newest first
    for i = 1, max_months do
      local item = month_list[i]
      local bar_len = math.max(1, math.floor(item.count / max_month_count * 20))
      local bar = string.rep("|", bar_len)
      add(string.format("  %s  %4d  %s", item.month, item.count, bar))
    end
    if #month_list > max_months then
      add(string.format("  ... and %d earlier months", #month_list - max_months))
    end
  else
    add("  (no date information)")
  end

  add_separator()

  -- ===== TASKS =====
  add_hl("  Tasks", "Title")
  add(string.rep("-", config.stats.separator_width))

  if data.task_total > 0 then
    add(string.format("  Total: %s", fmt_num(data.task_total)))
    -- Sort task statuses by the order in config.task_states
    for _, state in ipairs(config.task_states) do
      local count = data.task_counts[state.mark] or 0
      if count > 0 then
        local pct = data.task_total > 0 and (count / data.task_total * 100) or 0
        add(string.format("  [%s] %-15s %4d  (%.0f%%)", state.mark, state.label, count, pct))
      end
    end
    -- Any statuses not in config (custom marks)
    for mark, count in pairs(data.task_counts) do
      if not TASK_LABELS[mark] then
        add(string.format("  [%s] %-15s %4d", mark, "(custom)", count))
      end
    end
  else
    add("  (no tasks)")
  end

  add_separator()
  add("  Press q or <Esc> to close")

  return lines, highlights
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

--- Open the vault statistics dashboard.
function M.show()
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()

  if not idx or not idx:is_ready() then
    notify.index_not_ready()
    return
  end

  local start_time = vim.uv.hrtime()
  local data = M.compute(idx)
  local lines, highlights = M.format(data)
  local elapsed_ms = (vim.uv.hrtime() - start_time) / 1e6

  -- Append timing info
  lines[#lines] = string.format(
    "  Computed in %.1fms | Press q or <Esc> to close",
    elapsed_ms
  )

  local float = ui.create_float_display({
    title = "Vault Statistics",
    lines = lines,
    cursor_line = false,
  })

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(float.buf, -1, hl.hl, hl.line, hl.col_start, hl.col_end)
  end
end

-- ---------------------------------------------------------------------------
return M
