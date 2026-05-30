local engine = require("andrew.vault.engine")
local link_scan = require("andrew.vault.link_scan")
local vault_index = require("andrew.vault.vault_index")
local config = require("andrew.vault.config")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("autolink")

local M = {}


M.enabled = config.autolink.enabled or false
M.ns = vim.api.nvim_create_namespace("vault_autolink")

-- ---------------------------------------------------------------------------
-- Vault index readiness check
-- ---------------------------------------------------------------------------

--- Check if the vault index is ready for scanning.
---@return boolean
local function index_ready()
  local idx = vault_index.current()
  return idx ~= nil and idx:is_ready()
end

-- ---------------------------------------------------------------------------
-- Match tracking (extmark id -> match info)
-- ---------------------------------------------------------------------------

---@class AutoLinkMatch
---@field row number 0-indexed
---@field start_col number 0-indexed byte position
---@field end_col number 0-indexed byte position (exclusive)
---@field text string the matched text from the buffer (original case)
---@field note_name string the note name (lowercase key)
---@field extmark_id number

---@type table<number, AutoLinkMatch>
local matches_by_extmark = {}
local _cache_hits = 0
local _cache_misses = 0
local _cache_evictions = 0

-- ---------------------------------------------------------------------------
-- Core scan and apply
-- ---------------------------------------------------------------------------

--- Clear all autolink hints from a buffer.
---@param bufnr number
---@param start_line? number 0-indexed, inclusive (nil = full clear)
---@param end_line? number 0-indexed, exclusive (nil = full clear)
local function clear(bufnr, start_line, end_line)
  local range_start, range_end
  if start_line and end_line then
    range_start = { start_line, 0 }
    range_end = { end_line, 0 }
  else
    range_start = 0
    range_end = -1
  end
  -- Remove dict entries for this buffer's extmarks before clearing namespace
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, range_start, range_end, {})
  for _, mark in ipairs(marks) do
    if matches_by_extmark[mark[1]] then _cache_evictions = _cache_evictions + 1 end
    matches_by_extmark[mark[1]] = nil
  end
  if start_line and end_line then
    for _, mark in ipairs(marks) do
      vim.api.nvim_buf_del_extmark(bufnr, M.ns, mark[1])
    end
  else
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

--- Scan buffer lines and apply autolink hints.
---@param bufnr number
---@param opts? { visible_only?: boolean }
local function apply(bufnr, opts)
  if not M.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  if not engine.is_vault_buf(bufnr) then
    clear(bufnr)
    return
  end

  opts = opts or {}
  local ranges = opts.invalid_ranges

  -- If we have invalid_ranges from region tracker, do range-scoped clear+scan
  if ranges and #ranges > 0 then
    for _, range in ipairs(ranges) do
      clear(bufnr, range.start_line, range.end_line)
    end
  else
    clear(bufnr)
  end

  -- Bail if vault index not ready
  if not index_ready() then return end

  -- Determine line range (0-indexed start, exclusive end for scan_buffer_names)
  -- When invalid_ranges is provided, restrict scan to their bounding box
  -- to avoid creating duplicate extmarks in valid regions.
  local start_line, end_line
  if ranges and #ranges > 0 then
    start_line = ranges[1].start_line
    end_line = ranges[#ranges].end_line
  elseif opts.visible_only then
    local viewport = require("andrew.vault.viewport")
    start_line, end_line = viewport.get_margin_range(bufnr)
  else
    start_line = 0
    end_line = vim.api.nvim_buf_line_count(bufnr)
  end

  -- Delegate scanning to shared algorithm
  local scan_matches = link_scan.scan_buffer_names(bufnr, {
    start_line = start_line,
    end_line = end_line,
    min_name_length = config.autolink.min_name_length,
    exclude_names = config.autolink.exclude_names,
  })

  -- Place extmarks for each match
  local rt = ranges and #ranges > 0 and require("andrew.vault.region_tracker") or nil
  for _, m in ipairs(scan_matches) do
    -- When using invalid_ranges, only place extmarks within them
    -- (not in valid gaps between ranges) to avoid duplicate extmarks
    if rt and not rt.is_line_in_ranges(m.row, ranges) then goto continue_match end

    local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, m.row, m.start_col, {
      end_col = m.end_col,
      hl_group = "VaultAutoLinkHint",
      hl_mode = "combine",
      priority = 180,
      virt_text = { { " [[", "VaultAutoLinkIcon" } },
      virt_text_pos = "inline",
      virt_text_hide = true,
    })

    matches_by_extmark[extmark_id] = {
      row = m.row,
      start_col = m.start_col,
      end_col = m.end_col,
      text = m.text,
      note_name = m.note_name,
      extmark_id = extmark_id,
    }
    ::continue_match::
  end
end

-- ---------------------------------------------------------------------------
-- Accept suggestion
-- ---------------------------------------------------------------------------

--- Find the autolink suggestion nearest to the cursor.
---@param bufnr number
---@return AutoLinkMatch|nil
local function find_suggestion_at_cursor(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local col = cursor[2] -- 0-indexed

  -- Get all extmarks on the cursor row
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, { row, 0 }, { row, -1 }, { details = true })

  local best = nil
  local best_dist = math.huge

  for _, mark in ipairs(marks) do
    local id = mark[1]
    local match = matches_by_extmark[id]
    if match then
      _cache_hits = _cache_hits + 1
      -- Check if cursor is within or adjacent to the match span
      if col >= match.start_col and col <= match.end_col then
        return match -- Exact hit
      end
      -- Track nearest
      local dist = math.min(math.abs(col - match.start_col), math.abs(col - match.end_col))
      if dist < best_dist and dist <= 3 then
        best_dist = dist
        best = match
      end
    else
      _cache_misses = _cache_misses + 1
    end
  end

  return best
end

--- Accept the autolink suggestion at the cursor position.
--- Wraps the matched text in [[...]].
function M.accept()
  local bufnr = vim.api.nvim_get_current_buf()
  local match = find_suggestion_at_cursor(bufnr)
  if not match then
    notify.info("no auto-link suggestion at cursor")
    return
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, match.row, match.row + 1, false)[1]
  if not line then return end

  -- Build the replacement text
  local original_text = line:sub(match.start_col + 1, match.end_col)

  -- Check if buffer text case matches the note name case
  -- If different, we could use [[NoteName|displayed text]] but for simplicity
  -- we just wrap with the buffer text (Obsidian resolves case-insensitively)
  local replacement = "[[" .. original_text .. "]]"

  -- Replace the text on the line
  local new_line = line:sub(1, match.start_col) .. replacement .. line:sub(match.end_col + 1)
  vim.api.nvim_buf_set_lines(bufnr, match.row, match.row + 1, false, { new_line })

  -- Move cursor to end of the inserted link
  local new_col = match.start_col + #replacement
  vim.api.nvim_win_set_cursor(0, { match.row + 1, new_col - 1 })

  -- Remove this specific extmark
  local ok, err = pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, match.extmark_id)
  if not ok then log.debug("failed to delete extmark %d: %s", match.extmark_id, err) end
  matches_by_extmark[match.extmark_id] = nil
end

--- Accept all autolink suggestions on the current line.
function M.accept_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, { row, 0 }, { row, -1 }, { details = true })

  -- Collect matches on this line, sorted by column descending
  -- (replace right-to-left so byte offsets remain valid)
  local line_matches = {}
  for _, mark in ipairs(marks) do
    local id = mark[1]
    local match = matches_by_extmark[id]
    if match then
      _cache_hits = _cache_hits + 1
      line_matches[#line_matches + 1] = match
    else
      _cache_misses = _cache_misses + 1
    end
  end

  if #line_matches == 0 then
    notify.info("no auto-link suggestions on this line")
    return
  end

  table.sort(line_matches, function(a, b) return a.start_col > b.start_col end)

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then return end

  for _, match in ipairs(line_matches) do
    local original_text = line:sub(match.start_col + 1, match.end_col)
    local replacement = "[[" .. original_text .. "]]"
    line = line:sub(1, match.start_col) .. replacement .. line:sub(match.end_col + 1)
    local ok2, err2 = pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, match.extmark_id)
    if not ok2 then log.debug("failed to delete extmark %d: %s", match.extmark_id, err2) end
    matches_by_extmark[match.extmark_id] = nil
  end

  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { line })
  notify.info(("accepted %d auto-link(s)"):format(#line_matches))
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    apply(vim.api.nvim_get_current_buf())
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      clear(buf)
    end
  end
  notify.toggle("auto-link suggestions", M.enabled)
end

-- ---------------------------------------------------------------------------
-- Coordinated update (highlight coordinator integration)
-- ---------------------------------------------------------------------------

--- Called by the highlight coordinator to update autolink highlights.
--- Delegates to apply(); code_excl is not used directly (link_scan builds its
--- own code-exclusion set internally, cached per changedtick).
---@param bufnr number
---@param _code_excl table  unused — kept for coordinator API conformance
---@param opts { full?: boolean }
function M.coordinated_update(bufnr, _code_excl, opts)
  if not M.enabled then return end
  -- Use invalid_ranges from region tracker when available
  local ranges = opts and opts.invalid_ranges
  if ranges and #ranges == 0 then return end -- nothing to do
  apply(bufnr, { visible_only = not opts.full, invalid_ranges = ranges })
end

-- ---------------------------------------------------------------------------
-- Debug
-- ---------------------------------------------------------------------------

--- Show debug information about current autolink state.
function M.debug()
  local idx = vault_index.current()
  local bufnr = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, 0, -1, { details = true })

  -- Compute name stats on demand
  local single_count, multi_count, total_count = 0, 0, 0
  if idx and idx:is_ready() then
    local name_cache = idx:get_name_cache()
    for lower_name in pairs(name_cache.names) do
      if #lower_name >= 3 then
        total_count = total_count + 1
        local wc = link_scan.word_count(lower_name)
        if wc == 1 then
          single_count = single_count + 1
        else
          multi_count = multi_count + 1
        end
      end
    end
  end

  local info = {
    "Auto-Link Debug",
    "=====================",
    "Enabled: " .. tostring(M.enabled),
    "Single-word names: " .. single_count,
    "Multi-word names: " .. multi_count,
    "Total indexed names: " .. total_count,
    "Active suggestions: " .. #marks,
    "Index generation: " .. tostring(idx and idx._generation or "N/A"),
    "",
    "Active suggestions:",
  }

  for _, mark in ipairs(marks) do
    local id = mark[1]
    local match = matches_by_extmark[id]
    if match then
      info[#info + 1] = string.format(
        '  L%d:%d-%d  "%s"  -> %s',
        match.row + 1,
        match.start_col,
        match.end_col,
        match.text,
        match.note_name
      )
    end
  end

  notify.info_lines(info)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local palette = require("andrew.vault.command_palette")

  engine.register_cache({
    name = "autolink_index",
    module = "andrew.vault.autolink",
    invalidate = function()
      -- link_scan.scan_buffer_names() reads vault index directly;
      -- no local cache to invalidate. Trigger a re-render instead.
      if M.enabled then
        local bufnr = vim.api.nvim_get_current_buf()
        if vim.api.nvim_buf_is_valid(bufnr) then
          apply(bufnr)
        end
      end
    end,
    stats = function()
      local idx = vault_index.current()
      return {
        ready = idx ~= nil and idx:is_ready(),
        generation = idx and idx._generation or -1,
        vault = engine.vault_path,
      }
    end,
  })

  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "autolink_index",
      get_size = function()
        local count = 0
        for _ in pairs(matches_by_extmark) do count = count + 1 end
        return count
      end,
      get_capacity = function() return nil end,
      get_hits = function() return _cache_hits end,
      get_misses = function() return _cache_misses end,
      get_evictions = function() return _cache_evictions end,
    })
  end

  local cleanup = require("andrew.vault.resource_cleanup")
  local group = vim.api.nvim_create_augroup("VaultAutoLink", { clear = true })

  -- Clean up on buffer delete
  cleanup.on_buf_delete(group, clear, { pattern = "*.md" })

  -- Commands
  vim.api.nvim_create_user_command("VaultAutoLinkToggle", function()
    M.toggle()
  end, { desc = "Toggle auto-link suggestions" })

  vim.api.nvim_create_user_command("VaultAutoLinkRefresh", function()
    apply(vim.api.nvim_get_current_buf())
  end, { desc = "Refresh auto-link suggestions in current buffer" })

  vim.api.nvim_create_user_command("VaultAutoLinkAccept", function()
    M.accept()
  end, { desc = "Accept auto-link suggestion at cursor" })

  vim.api.nvim_create_user_command("VaultAutoLinkAcceptLine", function()
    M.accept_line()
  end, { desc = "Accept all auto-link suggestions on current line" })

  vim.api.nvim_create_user_command("VaultAutoLinkDebug", function()
    M.debug()
  end, { desc = "Show auto-link debug info" })

  -- FileType autocmd removed: now dispatched via event_dispatch.lua

  -- Palette registrations
  palette.register_command("VaultAutoLinkToggle", "Toggle auto-link suggestions", "Links", M.toggle, "<leader>va")
  palette.register_command("VaultAutoLinkRefresh", "Refresh auto-link suggestions in current buffer", "Links", function()
    apply(vim.api.nvim_get_current_buf())
  end)
  palette.register_command("VaultAutoLinkAccept", "Accept auto-link suggestion at cursor", "Links", M.accept, "<leader>vA")
  palette.register_command("VaultAutoLinkAcceptLine", "Accept all auto-link suggestions on current line", "Links", M.accept_line, "<leader>vgA")
  palette.register_command("VaultAutoLinkDebug", "Show auto-link debug info", "Links", M.debug)

  local coordinator = require("andrew.vault.highlight_coordinator")
  coordinator.register("autolink", M.coordinated_update, function() return M.enabled end, 60)
end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "<leader>va", function()
    M.toggle()
  end, {
    buffer = ev.buf,
    desc = "AutoLink: toggle suggestions",
    silent = true,
  })
  vim.keymap.set("n", "<leader>vA", function()
    M.accept()
  end, {
    buffer = ev.buf,
    desc = "AutoLink: accept suggestion at cursor",
    silent = true,
  })
  vim.keymap.set("n", "<leader>vgA", function()
    M.accept_line()
  end, {
    buffer = ev.buf,
    desc = "AutoLink: accept all on line",
    silent = true,
  })
end

return M
