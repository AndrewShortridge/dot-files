--- Task hierarchy visualization for the vault plugin.
--- Provides subtask tree building, completion tracking, virtual text on parent
--- tasks, and a dedicated tree view float (:VaultTaskTree).
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local cleanup = require("andrew.vault.resource_cleanup")
local filter_utils = require("andrew.vault.filter_utils")
local notify = require("andrew.vault.notify")
local ui = require("andrew.vault.ui")
local task_utils = require("andrew.vault.task_utils")
local vault_index = require("andrew.vault.vault_index")
local log = require("andrew.vault.vault_log").scope("task_hierarchy")

local M = {}

local ns = vim.api.nvim_create_namespace("vault_task_hierarchy")

--- Per-buffer debounce timers for render scheduling.
---@type table<number, uv_timer_t>
local _timers = {}

--- Per-file fold state in the tree view (LRU-bounded).
local lru = require("andrew.vault.lru_cache")
local _fold_state = lru.new(config.cache.fold_state_max or 500)

--- Per-buffer vtext cache: bufnr -> { gen = number, rel_path = string, roots = table[] }
---@type table<number, {gen: number, rel_path: string, roots: table[]}>
local _vtext_cache = {}

--- Per-buffer render frame caches (dual-frame expiry).
local FrameCache = require("andrew.vault.frame_cache")
local _frame_caches = {} -- bufnr → FrameCache

local function get_frame_cache(bufnr)
  return FrameCache.buf_get(_frame_caches, bufnr)
end

-- ---------------------------------------------------------------------------
-- Tree building
-- ---------------------------------------------------------------------------

--- Build a parent-child tree from a flat, line-ordered task list.
--- Each returned node gains `.children` (list) and `.parent_line` (number|nil).
---@param tasks table[] flat task list sorted by line number
---@return table[] roots  top-level tasks (indent_level == 0)
function M.build_tree(tasks)
  -- Shallow-copy each task so we don't mutate the index data.
  local nodes = {}
  for i, t in ipairs(tasks) do
    nodes[i] = vim.tbl_extend("force", {}, t, { children = {}, parent_line = nil })
  end

  local roots = {}
  -- Stack of ancestor nodes; top of stack is the most recent potential parent.
  local stack = {}

  for _, node in ipairs(nodes) do
    -- Pop until we find a node whose indent_level is strictly less than ours.
    while #stack > 0 and stack[#stack].indent_level >= node.indent_level do
      stack[#stack] = nil
    end

    if #stack == 0 then
      -- Root task
      roots[#roots + 1] = node
    else
      local parent = stack[#stack]
      node.parent_line = parent.line
      parent.children[#parent.children + 1] = node
    end

    stack[#stack + 1] = node
  end

  return roots
end

-- ---------------------------------------------------------------------------
-- Completion stats
-- ---------------------------------------------------------------------------

--- Recursively compute (done, total) counts for a task node.
--- Leaf tasks contribute 1; branch tasks aggregate their children.
---@param task table  a tree node produced by build_tree
---@return number done
---@return number total
function M.completion_stats(task)
  if #task.children == 0 then
    return task.completed and 1 or 0, 1
  end

  local done, total = 0, 0
  for _, child in ipairs(task.children) do
    local d, t = M.completion_stats(child)
    done = done + d
    total = total + t
  end
  return done, total
end

-- ---------------------------------------------------------------------------
-- Virtual text rendering (in normal buffers)
-- ---------------------------------------------------------------------------

--- Render completion percentage virtual text on parent tasks in the given buffer.
---@param bufnr number
function M.render_completion_vtext(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local region_tracker = require("andrew.vault.region_tracker")
  local tracker = region_tracker.get(bufnr, "task_hierarchy")
  local invalid_ranges = tracker:get_invalid_ranges()

  -- Skip if everything is valid (no edits since last render)
  if #invalid_ranges == 0 then return end

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return end

  local bufpath = vim.api.nvim_buf_get_name(bufnr)
  local rel_path = engine.vault_relative(bufpath)
  if not rel_path then return end

  local entry = idx.files[rel_path]
  if not entry or not entry.tasks or #entry.tasks == 0 then return end

  -- Use generation-cached tree to avoid rebuilding when index hasn't changed.
  local gen = idx._generation or 0
  local cached = _vtext_cache[bufnr]
  local roots
  if filter_utils.is_cache_gen_valid(cached, gen) and cached.rel_path == rel_path then
    roots = cached.roots
  else
    roots = M.build_tree(entry.tasks)
    _vtext_cache[bufnr] = { gen = gen, rel_path = rel_path, roots = roots }
  end

  local fc = get_frame_cache(bufnr)

  --- Find the last descendant line of a root task (1-indexed).
  local function last_descendant_line(node)
    local max_line = node.line
    for _, child in ipairs(node.children) do
      local child_last = last_descendant_line(child)
      if child_last > max_line then max_line = child_last end
    end
    return max_line
  end

  -- Render root tasks whose subtree span overlaps any invalid range.
  -- A child task edit must trigger re-render of the parent root's vtext.
  local ok, err = pcall(function()
    for _, root in ipairs(roots) do
      if #root.children > 0 then
        local root_line_0 = root.line - 1 -- 0-indexed
        local last_line_0 = last_descendant_line(root) - 1 -- 0-indexed
        if tracker:has_invalid_in_range(root_line_0, last_line_0 + 1) then
          -- Clear existing extmark at root line before re-rendering
          local existing = vim.api.nvim_buf_get_extmarks(
            bufnr, ns,
            { root_line_0, 0 },
            { root_line_0, -1 },
            {}
          )
          for _, mark in ipairs(existing) do
            vim.api.nvim_buf_del_extmark(bufnr, ns, mark[1])
          end

          local done, total = M.completion_stats(root)
          local label, hl

          local cache_key = fc and (bufnr .. ":" .. root.line .. ":" .. done .. ":" .. total)
          local cached_vtext = cache_key and fc:get(cache_key)
          if cached_vtext then
            label, hl = cached_vtext.label, cached_vtext.hl
          else
            local pct = math.floor(done / total * 100 + 0.5)
            label = string.format(" [%d/%d %d%%]", done, total, pct)
            hl = (pct == 100) and "VaultHierarchyComplete" or "VaultHierarchyProgress"
            if fc then fc:set(cache_key, { label = label, hl = hl }) end
          end

          vim.api.nvim_buf_set_extmark(bufnr, ns, root_line_0, 0, {
            virt_text = { { label, hl } },
            virt_text_pos = "eol",
            hl_mode = "combine",
          })
        end
      end
    end
  end)

  -- Mark ranges valid only on success — if rendering failed, ranges
  -- stay dirty so the next cycle retries them.
  if ok then
    region_tracker.mark_ranges_valid(bufnr, invalid_ranges, "task_hierarchy")
  else
    log.error("render_completion_vtext failed: %s", err)
  end

  if fc then fc:finish_frame() end
end

-- ---------------------------------------------------------------------------
-- Debounced render scheduling
-- ---------------------------------------------------------------------------

--- Schedule a debounced render of completion virtual text.
--- Debounce handles burst coalescing; scheduler handles priority ordering
--- (DEFERRED ensures this doesn't compete with user-visible work).
---@param bufnr number
function M._schedule_render(bufnr)
  if not config.hierarchy.show_completion_vtext then return end
  _timers[bufnr] = cleanup.debounce(_timers[bufnr], config.hierarchy.debounce_ms, function()
    local scheduler = require("andrew.vault.work_scheduler")
    scheduler.cancel_domain("task-hierarchy:" .. bufnr)
    scheduler.schedule(scheduler.DEFERRED, function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.render_completion_vtext(bufnr)
      end
    end, { domain = "task-hierarchy:" .. bufnr, label = "vtext-render" })
  end)
end

-- ---------------------------------------------------------------------------
-- Checkbox display helper
-- ---------------------------------------------------------------------------

local checkbox = task_utils.checkbox

-- ---------------------------------------------------------------------------
-- Tree view (dedicated float)
-- ---------------------------------------------------------------------------

--- Render a single task tree node into lines/highlights, recursively.
---@param node table tree node
---@param lines string[] accumulator
---@param highlights table[] accumulator for {line_idx, col_start, col_end, hl}
---@param card_positions table[] accumulator for navigation
---@param prefix string connector prefix for children
---@param is_last boolean whether this is the last sibling
---@param is_root boolean whether this is a root node
---@param file_path string source file (for jump target)
---@param fold_map table<number, boolean> fold state map for this file
local function render_node(node, lines, highlights, card_positions, prefix, is_last, is_root, file_path, fold_map)
  local row = #lines  -- 0-indexed line in the float buffer

  if is_root then
    -- Root / parent display
    local done, total = M.completion_stats(node)
    local has_children = #node.children > 0
    local collapsed = fold_map[node.line] == true

    local icon = ""
    if has_children then
      icon = collapsed and "▶ " or "▼ "
    else
      icon = "  "
    end

    local cb = checkbox(node.status)
    local stats_str = ""
    if has_children then
      local pct = math.floor(done / total * 100 + 0.5)
      stats_str = string.format("  [%d/%d %d%%]", done, total, pct)
    end

    local line = icon .. cb .. " " .. node.text .. stats_str
    lines[#lines + 1] = line

    -- Highlights
    local hl_icon = has_children and "VaultHierarchyParent" or "Comment"
    highlights[#highlights + 1] = { row, 0, #icon, hl_icon }
    if has_children and done == total then
      highlights[#highlights + 1] = { row, #line - #stats_str, #line, "VaultHierarchyComplete" }
    elseif has_children then
      highlights[#highlights + 1] = { row, #line - #stats_str, #line, "VaultHierarchyProgress" }
    end

    card_positions[#card_positions + 1] = {
      row = row,
      abs_path = file_path,
      line = node.line,
      is_root = true,
      node_line = node.line,
    }

    -- Render children if expanded
    if has_children and not collapsed then
      for i, child in ipairs(node.children) do
        local child_is_last = (i == #node.children)
        render_node(child, lines, highlights, card_positions, "  ", child_is_last, false, file_path, fold_map)
      end
    end
  else
    -- Child node
    local connector = is_last and "└─ " or "├─ "
    local cb = checkbox(node.status)
    local line = prefix .. connector .. cb .. " " .. node.text
    lines[#lines + 1] = line

    -- Connector highlight
    highlights[#highlights + 1] = { row, 0, #prefix + #connector, "VaultHierarchyConnector" }

    card_positions[#card_positions + 1] = {
      row = row,
      abs_path = file_path,
      line = node.line,
      is_root = false,
      node_line = node.line,
    }

    -- Recurse into grandchildren
    if #node.children > 0 then
      local child_prefix = prefix .. (is_last and "   " or "│  ")
      for i, child in ipairs(node.children) do
        local child_is_last = (i == #node.children)
        render_node(child, lines, highlights, card_positions, child_prefix, child_is_last, false, file_path, fold_map)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Generation-cached file entries for tree view
-- ---------------------------------------------------------------------------

local _tree_cache = task_utils.gen_cache(function(idx)
  if not idx:is_ready() then return { entries = {}, lookup = {} } end

  local entries = {}
  local files = idx:snapshot_files()
  for rel_path, entry in pairs(files) do
    if entry.tasks and #entry.tasks > 1 then
      local roots = M.build_tree(entry.tasks)
      local has_hierarchy = false
      for _, root in ipairs(roots) do
        if #root.children > 0 then
          has_hierarchy = true
          break
        end
      end
      if has_hierarchy then
        entries[#entries + 1] = {
          rel_path = rel_path,
          abs_path = entry.abs_path,
          roots = roots,
        }
      end
    end
  end

  table.sort(entries, function(a, b) return a.rel_path < b.rel_path end)

  local lookup = {}
  for _, fe in ipairs(entries) do
    lookup[fe.abs_path] = fe
  end

  return { entries = entries, lookup = lookup }
end)

--- Collect file entries with task hierarchies, cached by vault index generation.
---@return table[] file_entries
---@return table<string, table> lookup  abs_path -> file_entry
local function collect_file_entries_cached()
  local result = _tree_cache.get()
  if not result then return {}, {} end
  return result.entries, result.lookup
end

--- Apply highlight entries to a float buffer.
---@param buf number buffer handle
---@param highlights table[] list of {row, col_start, col_end, hl_group}
local function apply_highlights(buf, highlights)
  for _, hl in ipairs(highlights) do
    local row, col_start, col_end, group = hl[1], hl[2], hl[3], hl[4]
    if row < vim.api.nvim_buf_line_count(buf) then
      vim.api.nvim_buf_add_highlight(buf, ns, group, row, col_start, col_end)
    end
  end
end

--- Show a dedicated floating tree view of all vault task hierarchies.
function M.show_tree()
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    notify.index_not_ready()
    return
  end

  local file_entries, file_entry_lookup = collect_file_entries_cached()

  if #file_entries == 0 then
    notify.info("no task hierarchies found in vault")
    return
  end

  -- Initialize fold state for files that don't have it yet.
  local default_collapsed = (config.hierarchy.default_fold == "collapsed")
  for _, fe in ipairs(file_entries) do
    if not _fold_state:get(fe.rel_path) then
      _fold_state:put(fe.rel_path, {})
    end
    -- Ensure all roots have fold state.
    local fm = _fold_state:get(fe.rel_path)
    for _, root in ipairs(fe.roots) do
      if #root.children > 0 and fm[root.line] == nil then
        fm[root.line] = default_collapsed
      end
    end
  end

  -- Build display content from file_entries into lines/highlights/card_positions.
  local function build_display()
    local l, hl, cp = {}, {}, {}
    for fi, fe in ipairs(file_entries) do
      if fi > 1 then
        l[#l + 1] = ""
      end
      local header = "  " .. fe.rel_path
      local header_row = #l
      l[#l + 1] = header
      hl[#hl + 1] = { header_row, 0, #header, "Comment" }
      l[#l + 1] = string.rep("─", math.min(#header + 4, 60))
      hl[#hl + 1] = { #l - 1, 0, #l[#l], "VaultHierarchyConnector" }

      local fold_map = _fold_state:get(fe.rel_path) or {}
      for _, root in ipairs(fe.roots) do
        if #root.children > 0 then
          render_node(root, l, hl, cp, "", true, true, fe.abs_path, fold_map)
        end
      end
    end
    return l, hl, cp
  end

  local lines, highlights, card_positions = build_display()

  -- Create the float.
  local float = ui.create_float_display({
    title = "Task Hierarchy",
    lines = lines,
    cursor_line = true,
  })

  -- Apply highlights.
  apply_highlights(float.buf, highlights)

  -- Build O(1) row index for card lookup
  local row_index = filter_utils.build_row_index(card_positions)

  -- Helper: find card_position for current cursor line (O(1) via row index).
  local function card_at_cursor()
    local cursor_row = vim.api.nvim_win_get_cursor(float.win)[1] - 1  -- 0-indexed
    return row_index[cursor_row]
  end

  -- Helper: find the file_entry for a card_position (O(1) via lookup table).
  local function file_entry_for(abs_path)
    return file_entry_lookup[abs_path]
  end

  -- Helper: get fold state map for the root task at cursor.
  local function fold_state_at_cursor()
    local cp = card_at_cursor()
    if not cp or not cp.is_root then return nil, nil end
    local fe = file_entry_for(cp.abs_path)
    if not fe then return nil, nil end
    local fm = _fold_state:get(fe.rel_path)
    return cp, fm
  end

  -- Re-render the tree view (after fold toggling).
  local function refresh()
    local cursor_pos = vim.api.nvim_win_get_cursor(float.win)

    lines, highlights, card_positions = build_display()

    -- Update buffer.
    vim.bo[float.buf].modifiable = true
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)
    vim.bo[float.buf].modifiable = false

    -- Rebuild row index after card_positions changed.
    row_index = filter_utils.build_row_index(card_positions)

    -- Re-apply highlights.
    vim.api.nvim_buf_clear_namespace(float.buf, ns, 0, -1)
    apply_highlights(float.buf, highlights)

    -- Restore cursor (clamped).
    local max_line = vim.api.nvim_buf_line_count(float.buf)
    local new_row = math.min(cursor_pos[1], max_line)
    vim.api.nvim_win_set_cursor(float.win, { new_row, 0 })
  end

  -- Keymaps --

  local buf = float.buf
  local kopts = { buffer = buf, nowait = true, silent = true }

  -- <CR> jump to source
  vim.keymap.set("n", "<CR>", function()
    local cp = card_at_cursor()
    if not cp then return end
    float.close()
    vim.cmd("edit " .. vim.fn.fnameescape(cp.abs_path))
    vim.api.nvim_win_set_cursor(0, { cp.line, 0 })
    vim.cmd("normal! zz")
  end, kopts)

  -- <Tab> toggle collapse for root tasks
  vim.keymap.set("n", "<Tab>", function()
    local cp, fm = fold_state_at_cursor()
    if not fm or fm[cp.node_line] == nil then return end
    fm[cp.node_line] = not fm[cp.node_line]
    refresh()
  end, kopts)

  -- zo - expand
  vim.keymap.set("n", "zo", function()
    local cp, fm = fold_state_at_cursor()
    if not fm or not fm[cp.node_line] then return end
    fm[cp.node_line] = false
    refresh()
  end, kopts)

  -- zc - collapse
  vim.keymap.set("n", "zc", function()
    local cp, fm = fold_state_at_cursor()
    if not fm or fm[cp.node_line] == nil then return end
    fm[cp.node_line] = true
    refresh()
  end, kopts)

  -- zR - expand all
  vim.keymap.set("n", "zR", function()
    for _, fm in _fold_state:entries() do
      for k, _ in pairs(fm) do
        fm[k] = false
      end
    end
    refresh()
  end, kopts)

  -- zM - collapse all
  vim.keymap.set("n", "zM", function()
    for _, fm in _fold_state:entries() do
      for k, _ in pairs(fm) do
        fm[k] = true
      end
    end
    refresh()
  end, kopts)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local palette = require("andrew.vault.command_palette")

  -- Commands
  vim.api.nvim_create_user_command("VaultTaskTree", function()
    M.show_tree()
  end, { desc = "Show task hierarchy tree view" })

  -- Keymap
  vim.keymap.set("n", "<leader>vxh", function()
    M.show_tree()
  end, { desc = "Tasks: hierarchy tree", silent = true })

  -- Autocmds for virtual text rendering
  local augroup = vim.api.nvim_create_augroup("VaultTaskHierarchy", { clear = true })

  local function on_vault_md_change(ev)
    if not config.hierarchy.show_completion_vtext then return end
    if not engine.is_vault_buf(ev.buf) then return end
    M._schedule_render(ev.buf)
  end

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = augroup,
    pattern = "*.md",
    callback = on_vault_md_change,
  })

  -- TextChanged autocmd removed: now dispatched via event_dispatch.lua

  -- Clean up timers when buffers are deleted.
  cleanup.on_buf_delete(augroup, function(bufnr)
    cleanup.close_timer_in(_timers, bufnr)
    _vtext_cache[bufnr] = nil
    _frame_caches[bufnr] = nil
    -- Clear extmarks: use pcall since buffer may already be fully wiped
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  end)

  -- VimLeavePre autocmd removed: now dispatched via event_dispatch.lua

  -- Register with engine cache system.
  engine.register_cache({
    name = "task_hierarchy",
    module = "andrew.vault.task_hierarchy",
    invalidate = function()
      _fold_state:clear()
      _vtext_cache = {}
      _frame_caches = {}
      _tree_cache.invalidate()
    end,
    invalidate_file = function(abs_path)
      local rel = engine.vault_relative(abs_path)
      if rel then
        _fold_state:remove(rel)
        -- Clear vtext_cache and frame_cache entries for buffers showing this file
        for bufnr, entry in pairs(_vtext_cache) do
          if entry.rel_path == rel then
            _vtext_cache[bufnr] = nil
            _frame_caches[bufnr] = nil
          end
        end
      end
    end,
    stats = function()
      return {
        entries = _fold_state:size(),
        vtext_cached_bufs = vim.tbl_count(_vtext_cache),
      }
    end,
  })

  -- Register with memory profiler.
  local profiler = require("andrew.vault.memory_profiler")
  profiler.register_cache({
    name = "task_hierarchy",
    get_size = function()
      return _fold_state:size() + (_tree_cache.get() and 1 or 0)
    end,
    get_capacity = function() return nil end,
    get_hits = function() return _tree_cache.get_hits() end,
    get_misses = function() return _tree_cache.get_misses() end,
    get_evictions = function() return 0 end,
  })

  profiler.register_cache({
    name = "task_hierarchy_frame_caches",
    get_size = function()
      local total = 0
      for _, fc in pairs(_frame_caches) do
        total = total + fc:size()
      end
      return total
    end,
    get_capacity = function() return config.render_cache.max_entries_per_frame end,
    get_hits = function()
      local total = 0
      for _, fc in pairs(_frame_caches) do
        total = total + fc:get_stats().hits
      end
      return total
    end,
    get_misses = function()
      local total = 0
      for _, fc in pairs(_frame_caches) do
        total = total + fc:get_stats().misses
      end
      return total
    end,
    get_evictions = function()
      local total = 0
      for _, fc in pairs(_frame_caches) do
        total = total + fc:get_stats().evictions
      end
      return total
    end,
  })

  -- Palette registrations
  palette.register_command("VaultTaskTree", "Show task hierarchy tree view", "Tasks", M.show_tree, "<leader>vxh")
end

--- Accessor for debug commands to inspect frame cache state.
---@param bufnr number
---@return table|nil  FrameCache instance or nil
function M.get_frame_cache(bufnr)
  return _frame_caches[bufnr]
end

--- Called by event_dispatch.lua on VimLeavePre for cleanup.
function M.teardown()
  for bufnr, _ in pairs(_timers) do
    cleanup.close_timer_in(_timers, bufnr)
  end
  _frame_caches = {}
  -- Clear extmarks from all cached buffers (previously missing from teardown)
  for bufnr, _ in pairs(_vtext_cache) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
    end
  end
end

return M
