local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local ui = require("andrew.vault.ui")
local log = require("andrew.vault.vault_log").scope("graph")
local text_utils = require("andrew.vault.text_utils")

local M = {}

--- Render a graph of connections between a set of search result files.
---@param file_set table<string, boolean> abs_path -> true
---@param query_label string display label for the graph title
function M.search_result_graph(file_set, query_label)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    notify.index_not_ready()
    return
  end

  local filter_utils = require("andrew.vault.filter_utils")
  local resolve = filter_utils.create_memoized_resolver(idx)

  -- Build connection list between files in the result set
  local connections = {} -- { from_name, from_path, to_name, to_path }
  local seen_edges = {} -- dedup key

  for abs_path in pairs(file_set) do
    local entry = idx:get_entry_by_abs(abs_path)
    if entry then
      for _, link in ipairs(entry.outlinks) do
        local target_rel = resolve(link.path or "")
        if target_rel then
          local target_entry = idx:get_entry(target_rel)
          if target_entry and file_set[target_entry.abs_path] then
            local edge_key = abs_path .. "->" .. target_entry.abs_path
            if not seen_edges[edge_key] then
              seen_edges[edge_key] = true
              connections[#connections + 1] = {
                from = entry.basename,
                from_path = abs_path,
                to = target_entry.basename,
                to_path = target_entry.abs_path,
              }
            end
          end
        end
      end
    end
  end

  -- Count unique files
  local file_count = 0
  for _ in pairs(file_set) do file_count = file_count + 1 end

  -- Build display lines
  local lines = {}
  local highlights = {}
  local line_to_note = {}

  if #connections == 0 then
    lines[#lines + 1] = "  (no connections among " .. file_count .. " notes)"
    highlights[#highlights + 1] = { 0, 0, #lines[1], "VaultGraphCount" }
  else
    for _, conn in ipairs(connections) do
      local line = "  " .. conn.from .. " \u{2500}\u{2500}\u{2500}\u{2500} " .. conn.to
      lines[#lines + 1] = line
      local row = #lines - 1
      -- Highlight names
      local from_s, from_e = line:find(conn.from, 1, true)
      if from_s then
        highlights[#highlights + 1] = { row, from_s - 1, from_e, "VaultGraphExistingLink" }
      end
      local to_s, to_e = line:find(conn.to, from_e or 1, true)
      if to_s then
        highlights[#highlights + 1] = { row, to_s - 1, to_e, "VaultGraphExistingLink" }
      end
      line_to_note[#lines] = {
        backlink = conn.from_path,
        forward = conn.to_path,
      }
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  " .. #connections .. " connections among " .. file_count .. " notes"
  highlights[#highlights + 1] = { #lines - 1, 0, #lines[#lines], "VaultGraphCount" }

  -- Display
  local screen = ui.get_screen_dims()
  local max_width = text_utils.max_display_width(lines)
  local total_width = math.min(math.max(max_width + 4, 40), math.floor(screen.width * config.graph.float_width_ratio))
  local win_height = math.min(#lines, math.floor(screen.height * config.graph.float_height_ratio))

  local title = "Search Result Graph"
  if query_label and query_label ~= "" then
    title = title .. ": " .. query_label:sub(1, 40)
  end

  local float = ui.create_float_display({
    title = title,
    lines = lines,
    width = total_width,
    height = win_height,
    cursor_line = true,
  })

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("vault_graph_search")
  for _, hl in ipairs(highlights) do
    local row, col_start, col_end, group = hl[1], hl[2], hl[3], hl[4]
    if row < #lines then
      local ok, err = pcall(vim.api.nvim_buf_add_highlight, float.buf, ns, group, row, col_start, col_end)
      if not ok then log.debug("highlight failed at row %d: %s", row, err) end
    end
  end

  -- Navigation: <CR> follows link under cursor
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(float.win)
    local entry = line_to_note[cursor[1]]
    if entry then
      -- Navigate to the "to" note (right side) by default
      local path = entry.forward or entry.backlink
      if path then
        float.close()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      end
    end
  end, { buffer = float.buf, nowait = true, silent = true })

  -- q / Esc to close
  vim.keymap.set("n", "q", function() float.close() end, { buffer = float.buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", function() float.close() end, { buffer = float.buf, nowait = true, silent = true })
end

return M
