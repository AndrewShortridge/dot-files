-- sidebar_tags.lua — Tag tree panel for the vault sidebar
-- Shows the full tag hierarchy with expand/collapse and file counts.

local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")
local vault_index = require("andrew.vault.vault_index")
local tag_tree_builder = require("andrew.vault.tag_tree")
local tag_highlights_mod = require("andrew.vault.tag_highlights")
local log = require("andrew.vault.vault_log").scope("sidebar_tags")

local M = {}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- Set of collapsed tag paths (persists across re-renders within a session).
---@type table<string, boolean>
local _collapsed = {}

--- Map from display line number to full tag path (for interaction).
---@type table<number, string>
local _line_to_tag = {}

--- The last rendered tree root (for toggle operations).
---@type table|nil
local _last_root = nil

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Render a single tag tree node into display lines (recursive).
---@param node table TagTreeNode
---@param depth number Indentation level
---@param lines string[] Accumulator for display lines
---@param highlights table[] Accumulator for highlight entries
---@param start_line number Global line offset for _line_to_tag mapping
---@param width number Available width
local function render_node(node, depth, lines, highlights, start_line, width)
  local has_children = next(node.children) ~= nil
  local is_collapsed = _collapsed[node.full_tag] or false

  local indent = string.rep("  ", depth)
  local icon = has_children and (is_collapsed and "\u{25B8} " or "\u{25BE} ") or "  "

  -- Count string
  local count_str
  local tree_cfg = config.tag_tree
  local show_totals = tree_cfg.show_totals ~= false
  if show_totals and node.count ~= node.total and has_children then
    count_str = " (" .. node.count .. "/" .. node.total .. ")"
  else
    count_str = " (" .. node.count .. ")"
  end

  local display = indent .. icon .. node.name .. count_str
  local line_idx = #lines
  lines[#lines + 1] = display

  -- Register line-to-tag mapping
  _line_to_tag[start_line + #lines] = node.full_tag

  -- Highlights
  local tag_start = #indent + #icon
  local tag_end = tag_start + #node.name

  -- Tag name: use category-based highlight if configured
  local tag_hl = "VaultSidebarTag"
  local cat = tag_highlights_mod.find_tag_category(node.full_tag)
  if cat then
    tag_hl = cat.highlight
  end

  highlights[#highlights + 1] = { line_idx, tag_start, tag_end, tag_hl }

  -- Count: dimmed
  highlights[#highlights + 1] = { line_idx, tag_end, #display, "VaultSidebarCount" }

  -- Recurse into children if expanded
  if has_children and not is_collapsed then
    local sort_mode = tree_cfg.sort or "alpha"
    local keys = {}
    for k in pairs(node.children) do keys[#keys + 1] = k end
    if sort_mode == "count" then
      table.sort(keys, function(a, b)
        return node.children[a].total > node.children[b].total
      end)
    else
      table.sort(keys)
    end

    for _, key in ipairs(keys) do
      local child = node.children[key]
      local min_count = tree_cfg.min_count or 0
      if min_count <= 0 or child.total >= min_count or child.count >= min_count then
        render_node(child, depth + 1, lines, highlights, start_line, width)
      end
    end
  end
end

--- Render the tag tree panel content.
---@param buf number
---@param width number
---@param source_buf number (unused for tags — vault-global view)
---@param start_line number
---@param ns number
function M.render(buf, width, source_buf, start_line, ns)
  _line_to_tag = {}

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    local msg = "  (vault index not ready)"
    vim.api.nvim_buf_set_lines(buf, start_line, -1, false, { "", msg })
    local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_line + 1, 0, {
      end_col = #msg,
      hl_group = "VaultSidebarEmpty",
    })
    if not ok then log.debug("extmark failed at row %d: %s", start_line + 1, err) end
    return
  end

  local tag_counts = idx:tags_with_counts()
  if not next(tag_counts) then
    local msg = "  (no tags found)"
    vim.api.nvim_buf_set_lines(buf, start_line, -1, false, { "", msg })
    local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, ns, start_line + 1, 0, {
      end_col = #msg,
      hl_group = "VaultSidebarEmpty",
    })
    if not ok then log.debug("extmark failed at row %d: %s", start_line + 1, err) end
    return
  end

  local root = tag_tree_builder.build_tree(tag_counts)
  _last_root = root

  local lines = {}
  local highlights = {}

  -- Header
  local total_tags = 0
  for _ in pairs(tag_counts) do total_tags = total_tags + 1 end
  local header = " " .. total_tags .. " tags"
  lines[#lines + 1] = header
  highlights[#highlights + 1] = { 0, 0, #header, "VaultSidebarHeader" }
  lines[#lines + 1] = ""

  -- Render tree nodes
  local sort_mode = config.tag_tree.sort or "alpha"
  local keys = {}
  for k in pairs(root) do keys[#keys + 1] = k end
  if sort_mode == "count" then
    table.sort(keys, function(a, b) return root[a].total > root[b].total end)
  else
    table.sort(keys)
  end

  for _, key in ipairs(keys) do
    render_node(root[key], 0, lines, highlights, start_line, width)
  end

  -- Write to buffer
  vim.api.nvim_buf_set_lines(buf, start_line, -1, false, lines)

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    local row = start_line + hl[1]
    local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
    if not ok then log.debug("extmark failed at row %d: %s", row, err) end
  end
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

function M.setup_keymaps(buf, _source_win)
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Enter: search notes with this tag
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local tag = _line_to_tag[cursor[1]]
    if not tag then return end
    require("andrew.vault.tags").search_tag(tag)
  end, vim.tbl_extend("force", opts, { desc = "Search notes with tag" }))

  -- Space / l: toggle expand/collapse
  vim.keymap.set("n", "<Space>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local tag = _line_to_tag[cursor[1]]
    if not tag then return end
    _collapsed[tag] = not _collapsed[tag]
    require("andrew.vault.sidebar").render()
  end, vim.tbl_extend("force", opts, { desc = "Toggle expand/collapse" }))

  vim.keymap.set("n", "l", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local tag = _line_to_tag[cursor[1]]
    if not tag then return end
    if _collapsed[tag] then
      _collapsed[tag] = false
      require("andrew.vault.sidebar").render()
    end
  end, vim.tbl_extend("force", opts, { desc = "Expand node" }))

  vim.keymap.set("n", "h", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local tag = _line_to_tag[cursor[1]]
    if not tag then return end
    if not _collapsed[tag] then
      _collapsed[tag] = true
      require("andrew.vault.sidebar").render()
    else
      -- Collapse parent: find parent tag
      local parent = link_utils.lua_dirname(tag)
      if parent ~= tag then
        _collapsed[parent] = true
        require("andrew.vault.sidebar").render()
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "Collapse node or go to parent" }))

  -- zo: expand all
  vim.keymap.set("n", "zo", function()
    _collapsed = {}
    require("andrew.vault.sidebar").render()
  end, vim.tbl_extend("force", opts, { desc = "Expand all" }))

  -- zc: collapse all
  vim.keymap.set("n", "zc", function()
    if _last_root then
      local function collapse_all(children)
        for _, node in pairs(children) do
          if next(node.children) then
            _collapsed[node.full_tag] = true
            collapse_all(node.children)
          end
        end
      end
      collapse_all(_last_root)
      require("andrew.vault.sidebar").render()
    end
  end, vim.tbl_extend("force", opts, { desc = "Collapse all" }))
end

return M
