-- tag_tree.lua — Tag hierarchy tree builder for the vault tag tree picker.
-- Pure data transformation module: builds a tree from flat tag counts,
-- flattens it into ANSI-colored entries for fzf-lua display.

local M = {}

local ANSI = require("andrew.vault.ansi")

local HL_TO_ANSI = {
  VaultTagProject = ANSI.blue .. ANSI.bold,
  VaultTagStatus  = ANSI.green .. ANSI.bold,
  VaultTagType    = ANSI.yellow .. ANSI.bold,
  VaultTagPerson  = ANSI.cyan .. ANSI.bold,
  VaultTag        = ANSI.magenta .. ANSI.bold,
}

---@class TagTreeNode
---@field name string       Segment name (e.g., "alpha", not "project/alpha")
---@field full_tag string   Full slash-separated path (e.g., "project/alpha")
---@field count number      Files directly tagged with this exact tag
---@field total number      Files tagged with this tag or any descendant
---@field children table<string, TagTreeNode>
---@field depth number      Nesting level (0 = root)

--- Apply ANSI color to a tag name based on its category prefix.
---@param name string Display segment name
---@param full_tag string Full tag path for category matching
---@return string
function M.colorize_tag(name, full_tag)
  local tag_highlights = require("andrew.vault.tag_highlights")
  local cat = tag_highlights.find_tag_category(full_tag)
  if cat then
    local ansi = HL_TO_ANSI[cat.highlight] or (ANSI.magenta .. ANSI.bold)
    return ansi .. name .. ANSI.reset
  end
  return ANSI.magenta .. ANSI.bold .. name .. ANSI.reset
end

local function dim(text)
  return ANSI.dim .. text .. ANSI.reset
end

--- Build a tag tree from tag counts.
---@param tag_counts table<string, number> full_tag -> direct file count
---@return table<string, TagTreeNode> root children
function M.build_tree(tag_counts)
  local root = {}

  for tag, count in pairs(tag_counts) do
    local segments = vim.split(tag, "/", { plain = true })
    segments = vim.tbl_filter(function(s) return s ~= "" end, segments)
    local current_level = root
    local path_so_far = ""

    for i, segment in ipairs(segments) do
      path_so_far = i == 1 and segment or (path_so_far .. "/" .. segment)
      if not current_level[segment] then
        current_level[segment] = {
          name = segment,
          full_tag = path_so_far,
          count = 0,
          total = 0,
          children = {},
          depth = i - 1,
        }
      end
      local node = current_level[segment]
      if i == #segments then
        node.count = count
      end
      current_level = node.children
    end
  end

  -- Bottom-up totals
  local function compute_totals(children)
    for _, node in pairs(children) do
      compute_totals(node.children)
      local child_total = 0
      for _, child in pairs(node.children) do
        child_total = child_total + child.total
      end
      node.total = node.count + child_total
    end
  end
  compute_totals(root)

  return root
end

--- Flatten the tree into fzf-lua display entries.
---@param root table<string, TagTreeNode>
---@param collapsed table<string, boolean>|nil Set of collapsed full_tags
---@return string[] entries ANSI-formatted display strings
function M.flatten(root, collapsed)
  collapsed = collapsed or {}
  local entries = {}

  local ok, config = pcall(require, "andrew.vault.config")
  local tree_cfg = (ok and config.tag_tree) or {}
  local sort_mode = tree_cfg.sort or "alpha"
  local min_count = tree_cfg.min_count or 0
  local show_totals = tree_cfg.show_totals ~= false  -- default true

  local function sorted_keys(tbl)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    if sort_mode == "count" then
      table.sort(keys, function(a, b)
        return tbl[a].total > tbl[b].total
      end)
    else
      table.sort(keys)
    end
    return keys
  end

  local function walk(children, depth)
    for _, key in ipairs(sorted_keys(children)) do
      local node = children[key]
      local has_children = next(node.children) ~= nil

      -- Skip nodes below min_count (but keep if total meets threshold)
      if min_count > 0 and node.total < min_count and node.count < min_count then
        goto continue
      end

      local is_collapsed = collapsed[node.full_tag] or false

      local indent = string.rep("  ", depth)
      local icon
      if has_children then
        icon = is_collapsed and "▸ " or "▾ "
      else
        icon = "  "
      end

      local colored = M.colorize_tag(node.name, node.full_tag)

      -- Show "direct/total" when they differ and show_totals is on
      local count_str
      if show_totals and node.count ~= node.total and has_children then
        count_str = "(" .. node.count .. "/" .. node.total .. ")"
      else
        count_str = "(" .. node.count .. ")"
      end

      entries[#entries + 1] = string.format(
        "%s\t%s%s%s  %s",
        node.full_tag,
        indent,
        icon,
        colored,
        dim(count_str)
      )

      if has_children and not is_collapsed then
        walk(node.children, depth + 1)
      end

      ::continue::
    end
  end

  walk(root, 0)
  return entries
end

return M
