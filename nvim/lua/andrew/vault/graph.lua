local engine = require("andrew.vault.engine")
local notify = require("andrew.vault.notify")
local ui = require("andrew.vault.ui")
local config = require("andrew.vault.config")
local log = require("andrew.vault.vault_log").scope("graph")
local collect = require("andrew.vault.graph.collect")
local render = require("andrew.vault.graph.render")
local display_width = require("andrew.vault.text_utils").display_width
local link_utils = require("andrew.vault.link_utils")

local M = {}

-- Highlight groups defined centrally by vault/colors.lua

-- Re-export search_result_graph from extracted module (lazy-loaded on first call)
function M.search_result_graph(...)
  return require("andrew.vault.graph.search_graph").search_result_graph(...)
end

-- ---------------------------------------------------------------------------
-- Public: local_graph()
-- ---------------------------------------------------------------------------

function M.local_graph()
  local graph_filter = require("andrew.vault.graph_filter")

  local note_name = engine.current_note_name()
  if not note_name then
    notify.no_filename()
    return
  end

  -- Check that we are inside the vault
  if not engine.is_vault_buf(0) then
    notify.not_vault_file()
    return
  end

  local state = graph_filter.state
  local predicate = graph_filter.build_predicate(state)

  -- Continuation: once forward_links and backlinks are collected, render the graph.
  -- Extracted so both sync (depth<=1) and async (multi-hop) paths can share it.
  local function render_graph_with_links(fwd, bk)
    local forward_links, backlinks = fwd, bk

    -- Apply toggle filters
  if not state.show_unresolved then
    local function filter_unresolved(list)
      local out = {}
      for _, entry in ipairs(list) do
        if entry.path then out[#out + 1] = entry end
      end
      return out
    end
    forward_links = filter_unresolved(forward_links)
    backlinks = filter_unresolved(backlinks)
  end

  -- Disambiguate entries that share the same display name
  collect.disambiguate_names(forward_links)
  collect.disambiguate_names(backlinks)

  -- Compute window dimensions
  local screen = ui.get_screen_dims()
  local total_width = math.floor(screen.width * config.graph.float_width_ratio)
  local link_count = math.max(#backlinks, #forward_links)
  -- lines: border + header + empty + link_rows + empty + border + summary = link_count + 6
  local content_height = link_count + 6
  if link_count == 0 then
    content_height = 7 -- includes the "(no connections)" line
  end
  -- Add lines for filter status bar
  local show_filter_bar = config.graph.show_filter_bar
  if show_filter_bar then
    content_height = content_height + 2
  end
  local max_height = math.floor(screen.height * config.graph.float_height_ratio)
  local win_height = math.min(content_height, max_height)

  -- Render
  local rendered_lines, highlights, line_to_note = render.render_graph(note_name, backlinks, forward_links, total_width)

  -- Append filter status bar
  if show_filter_bar then
    local filter_status = graph_filter.format_status(state)
    local status_line = "  Filters: " .. filter_status
    rendered_lines[#rendered_lines + 1] = status_line
    highlights[#highlights + 1] = { #rendered_lines - 1, 0, #status_line, "VaultGraphCount" }

    local hints_line = "  [f] filter  [u] unresolved  [+/-] depth  [r] reset  [p] presets  [s] search  [?] help"
    rendered_lines[#rendered_lines + 1] = hints_line
    highlights[#highlights + 1] = { #rendered_lines - 1, 0, #hints_line, "VaultGraphDivider" }
  end

  -- Create floating display via shared UI module
  local float = ui.create_float_display({
    title = "Local Graph: " .. note_name,
    lines = rendered_lines,
    width = total_width,
    height = win_height,
    cursor_line = true,
  })
  local buf = float.buf
  local win = float.win

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("vault_graph")
  for _, hl in ipairs(highlights) do
    local row, col_start, col_end, group = hl[1], hl[2], hl[3], hl[4]
    if row < #rendered_lines then
      local ok, err = pcall(vim.api.nvim_buf_add_highlight, buf, ns, group, row, col_start, col_end)
      if not ok then log.debug("highlight failed at row %d: %s", row, err) end
    end
  end

  -- Store context for keymaps
  local graph_ctx = {
    win = win,
    buf = buf,
    total_width = total_width,
    line_to_note = line_to_note,
    source_buf_name = buf_path,
  }

  -- Helper: navigate to a note by absolute path, or offer to create it
  local function navigate_to(path, unresolved_name)
    if path and path ~= "" then
      float.close()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      return
    end

    if unresolved_name and unresolved_name ~= "" then
      vim.ui.select({ "Create note", "Cancel" }, {
        prompt = "'" .. unresolved_name .. "' does not exist:",
      }, function(choice)
        if choice == "Create note" then
          local buf_dir = link_utils.lua_dirname(graph_ctx.source_buf_name)
          local new_path
          if engine.is_vault_path(buf_dir) then
            new_path = buf_dir .. "/" .. unresolved_name .. ".md"
          else
            new_path = engine.vault_path .. "/" .. unresolved_name .. ".md"
          end
          local dir = link_utils.lua_dirname(new_path)
          vim.fn.mkdir(dir, "p")
          float.close()
          vim.cmd("edit " .. vim.fn.fnameescape(new_path))
          -- Update vault index for the new file
          local vault_index = package.loaded["andrew.vault.vault_index"]
          if vault_index then
            local idx = vault_index.current()
            if idx then idx:update_file(new_path) end
          end
          notify.note_created(unresolved_name)
        end
      end)
      return
    end

    notify.info("no link on this line")
  end

  -- Helper: resolve navigation target from cursor position using stored paths
  -- Returns: path (or nil), unresolved_name (or nil)
  local function target_from_cursor()
    local cursor = vim.api.nvim_win_get_cursor(graph_ctx.win)
    local entry = graph_ctx.line_to_note[cursor[1]]
    if not entry then
      return nil, nil
    end
    local half = math.floor(graph_ctx.total_width / 2)
    -- Determine which side the cursor is on
    local line_text = vim.api.nvim_buf_get_lines(graph_ctx.buf, cursor[1] - 1, cursor[1], false)[1]
    local col_display = display_width(line_text:sub(1, cursor[2]))
    local on_left = col_display < half

    if on_left then
      return entry.backlink, entry.backlink_name
    else
      return entry.forward, entry.forward_name
    end
  end

  -- <CR>: navigate to the note on the current line, or create if unresolved
  vim.keymap.set("n", "<CR>", function()
    local path, unresolved_name = target_from_cursor()
    navigate_to(path, unresolved_name)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Follow graph link (create if unresolved)",
  })

  -- gf: same as <CR>
  vim.keymap.set("n", "gf", function()
    local path, unresolved_name = target_from_cursor()
    navigate_to(path, unresolved_name)
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Follow graph link (create if unresolved)",
  })

  -- f: open filter panel
  vim.keymap.set("n", "f", function()
    graph_filter.open_filter_ui(function()
      float.close()
      M.local_graph()
    end)
  end, { buffer = buf, nowait = true, silent = true, desc = "Open filter panel" })

  -- +: increase depth
  vim.keymap.set("n", "+", function()
    state.depth = math.min(state.depth + 1, config.graph.max_depth)
    float.close()
    M.local_graph()
  end, { buffer = buf, nowait = true, silent = true, desc = "Increase depth" })

  -- -: decrease depth
  vim.keymap.set("n", "-", function()
    state.depth = math.max(state.depth - 1, 1)
    float.close()
    M.local_graph()
  end, { buffer = buf, nowait = true, silent = true, desc = "Decrease depth" })

  -- r: reset filters
  vim.keymap.set("n", "r", function()
    graph_filter.state = graph_filter.default_state()
    float.close()
    M.local_graph()
  end, { buffer = buf, nowait = true, silent = true, desc = "Reset filters" })

  -- p: load preset
  vim.keymap.set("n", "p", function()
    graph_filter.open_preset_picker(function()
      float.close()
      M.local_graph()
    end)
  end, { buffer = buf, nowait = true, silent = true, desc = "Load preset" })

  -- P: save preset
  vim.keymap.set("n", "P", function()
    graph_filter.save_preset_prompt()
  end, { buffer = buf, nowait = true, silent = true, desc = "Save preset" })

  -- u: toggle unresolved link visibility
  vim.keymap.set("n", "u", function()
    state.show_unresolved = not state.show_unresolved
    float.close()
    M.local_graph()
  end, { buffer = buf, nowait = true, silent = true, desc = "Toggle unresolved links" })

  -- ?: show help
  vim.keymap.set("n", "?", function()
    graph_filter.show_help()
  end, { buffer = buf, nowait = true, silent = true, desc = "Show help" })

  -- s: search within graph nodes
  if config.graph.graph_to_search then
    vim.keymap.set("n", "s", function()
      -- Collect all file paths visible in the current graph
      local paths = {}
      local seen = {}
      for _, entry in pairs(graph_ctx.line_to_note) do
        if entry.backlink and not seen[entry.backlink] then
          seen[entry.backlink] = true
          paths[#paths + 1] = entry.backlink
        end
        if entry.forward and not seen[entry.forward] then
          seen[entry.forward] = true
          paths[#paths + 1] = entry.forward
        end
      end
      -- Include center note
      if graph_ctx.source_buf_name and not seen[graph_ctx.source_buf_name] then
        paths[#paths + 1] = graph_ctx.source_buf_name
      end

      float.close()
      require("andrew.vault.search").search_in_files(paths)
    end, { buffer = buf, nowait = true, silent = true, desc = "Search within graph nodes" })
  end
  end -- render_graph_with_links

  if state.depth <= 1 then
    -- Standard single-hop collection with filter applied (sync, fast)
    local forward_links = collect.collect_forward_links()
    local backlinks_list = collect.collect_backlinks(note_name)

    -- Strip current note from both lists (self-references)
    local function filter_self(list)
      local out = {}
      for _, entry in ipairs(list) do
        if entry.name ~= note_name and entry.path ~= buf_path then
          out[#out + 1] = entry
        end
      end
      return out
    end
    forward_links = filter_self(forward_links)
    backlinks_list = filter_self(backlinks_list)

    -- Apply filter predicates
    forward_links = graph_filter.apply(forward_links, predicate)
    backlinks_list = graph_filter.apply(backlinks_list, predicate)

    render_graph_with_links(forward_links, backlinks_list)
  else
    -- Multi-hop collection via vault index (async, cooperative yielding)
    graph_filter.collect_at_depth_async(buf_path, state.depth, predicate,
      function(forward_links, backlinks_list, truncated)
        if truncated then
          notify.info(string.format("results truncated at %d nodes (max_nodes cap)", config.graph.max_nodes))
        end
        render_graph_with_links(forward_links, backlinks_list)
      end)
  end
end

-- ---------------------------------------------------------------------------
return M
