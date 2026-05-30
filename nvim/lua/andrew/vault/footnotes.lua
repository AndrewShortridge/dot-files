local config = require("andrew.vault.config")
local ui = require("andrew.vault.ui")
local cleanup = require("andrew.vault.resource_cleanup")
local notify = require("andrew.vault.notify")
local log = require("andrew.vault.vault_log").scope("footnotes")
local text_utils = require("andrew.vault.text_utils")
local display_width = text_utils.display_width
local hl_coord = require("andrew.vault.highlight_coordinator")
local render_arena = require("andrew.vault.render_arena")
local parse_cache = require("andrew.vault.line_parse_cache")
local pat = require("andrew.vault.patterns")

local M = {}
M.enabled = true

local function notify_no_footnotes()
  notify.info("no footnotes in buffer")
end

local ns = vim.api.nvim_create_namespace("VaultFootnote")
local footnotes_visible = {} -- bufnr -> boolean
local _fn_cache = {} -- bufnr -> { tick, fn_map }
local viewport = require("andrew.vault.viewport")

-- Clean up _fn_cache entries when buffers are deleted to prevent memory leak
cleanup.on_buf_delete(
  vim.api.nvim_create_augroup("VaultFootnoteCacheCleanup", { clear = true }),
  function(bufnr)
    _fn_cache[bufnr] = nil
    footnotes_visible[bufnr] = nil
  end,
  { pattern = "*.md" }
)

-- ============================================================================
-- Patterns
-- ============================================================================

local REF_PAT = pat.FOOTNOTE_REF
local DEF_PAT = pat.FOOTNOTE_DEF
local CONT_PAT = pat.FOOTNOTE_CONT
local CONT_TAB_PAT = pat.FOOTNOTE_CONT_TAB

-- ============================================================================
-- Parsing
-- ============================================================================

--- Find the footnote identifier under or near the cursor.
---@return string|nil footnote id (without [^ and ])
---@return number|nil start column (1-indexed)
---@return number|nil end column (1-indexed)
local function get_footnote_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  local start = 1
  while true do
    local s, e, id = line:find(REF_PAT, start)
    if not s then return nil end
    if col >= s and col <= e then
      return id, s, e
    end
    start = e + 1
  end
end

--- Read the full content of a footnote definition, including continuation lines.
--- Returns the content as an array of strings (one per line), with the definition
--- marker stripped from the first line and indentation stripped from continuations.
---@param buf_lines string[] all buffer lines
---@param def_lnum number 1-indexed line number of the [^id]: definition
---@return string[] content lines
---@return number end_lnum 1-indexed last line of the definition block
local function read_definition_content(buf_lines, def_lnum)
  local first_line = buf_lines[def_lnum]
  if not first_line then return {}, def_lnum end

  local _, content_start = first_line:match(DEF_PAT)
  if not content_start then return {}, def_lnum end

  local lines = {}
  -- First line: text after [^id]:
  local trimmed = vim.trim(content_start)
  if trimmed ~= "" then
    lines[#lines + 1] = trimmed
  end

  -- Continuation lines: indented by 4 spaces or 1 tab
  local lnum = def_lnum + 1
  while lnum <= #buf_lines do
    local line = buf_lines[lnum]
    -- Stop at blank lines (end of footnote block)
    if line:match("^%s*$") then
      break
    end
    -- Check for continuation indentation
    local cont = line:match(CONT_PAT)
    if not cont then
      cont = line:match(CONT_TAB_PAT)
    end
    if cont then
      lines[#lines + 1] = cont
      lnum = lnum + 1
    else
      -- Non-indented, non-blank line: end of definition
      break
    end
  end

  return lines, lnum - 1
end

--- Scan the buffer and build a complete footnote map.
--- Returns tables mapping footnote IDs to their references and definitions.
---@param bufnr number
---@return table footnote_map { [id] = { refs = {{lnum, col}...}, def_lnum = number|nil, def_content = string[], def_end_lnum = number|nil } }
local function parse_all_footnotes(bufnr)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local map = {}

  for i, line in ipairs(buf_lines) do
    -- Check for definition first (definitions start at column 0)
    local def_id = line:match(DEF_PAT)
    if def_id then
      if not map[def_id] then
        map[def_id] = { refs = {}, def_lnum = nil, def_content = {}, def_end_lnum = nil }
      end
      local content, end_lnum = read_definition_content(buf_lines, i)
      map[def_id].def_lnum = i
      map[def_id].def_content = content
      map[def_id].def_end_lnum = end_lnum
    end

    -- Find all references on this line (including on definition lines — a definition
    -- line contains a reference-like pattern as part of its own syntax, but we only
    -- count references that are NOT the definition marker itself)
    local start = 1
    while true do
      local s, e, ref_id = line:find(REF_PAT, start)
      if not s then break end

      -- Skip if this is the definition marker itself: [^id]: at start of line
      local is_def_marker = (s == 1) and line:sub(e + 1, e + 1) == ":"
      if not is_def_marker then
        if not map[ref_id] then
          map[ref_id] = { refs = {}, def_lnum = nil, def_content = {}, def_end_lnum = nil }
        end
        table.insert(map[ref_id].refs, { lnum = i, col = s })
      end

      start = e + 1
    end
  end

  return map
end

--- Cached version of parse_all_footnotes using changedtick invalidation.
---@param bufnr number
---@return table footnote_map
local function parse_all_footnotes_cached(bufnr)
  return hl_coord.cached_value(_fn_cache, bufnr, parse_all_footnotes)
end

--- Get the definition content for a specific footnote ID in the current buffer.
---@param bufnr number
---@param id string footnote identifier
---@return string[]|nil content lines, nil if definition not found
---@return number|nil def_lnum 1-indexed definition line number
local function get_definition_for_id(bufnr, id)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local escaped = vim.pesc(id)
  local pattern = "^%[%^" .. escaped .. "%]:"

  for i, line in ipairs(buf_lines) do
    if line:match(pattern) then
      local content, _ = read_definition_content(buf_lines, i)
      return content, i
    end
  end
  return nil, nil
end

-- ============================================================================
-- Public: jump (existing, unchanged)
-- ============================================================================

--- Jump between footnote reference and definition.
--- If on a definition `[^id]:`, jump to first reference `[^id]`.
--- If on a reference `[^id]`, jump to the definition `[^id]:`.
function M.jump()
  local id = get_footnote_at_cursor()
  if not id then
    notify.info("no footnote under cursor")
    return
  end

  local line = vim.api.nvim_get_current_line()
  local is_definition = line:match("^%[%^" .. vim.pesc(id) .. "%]:")

  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  if is_definition then
    -- Jump to first reference (not a definition)
    local pattern = "%[%^" .. vim.pesc(id) .. "%]"
    for i, l in ipairs(buf_lines) do
      if not l:match("^%[%^" .. vim.pesc(id) .. "%]:") then
        local s = l:find(pattern)
        if s then
          vim.api.nvim_win_set_cursor(0, { i, s - 1 })
          return
        end
      end
    end
    notify.info("no reference found for [^" .. id .. "]")
  else
    -- Jump to definition
    local pattern = "^%[%^" .. vim.pesc(id) .. "%]:"
    for i, l in ipairs(buf_lines) do
      if l:match(pattern) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
    notify.info("no definition found for [^" .. id .. "]")
  end
end

-- ============================================================================
-- Public: list (enhanced — shows definition preview)
-- ============================================================================

--- List all footnotes in current buffer via fzf-lua, with definition previews.
function M.list()
  local bufnr = vim.api.nvim_get_current_buf()
  local fn_map = parse_all_footnotes_cached(bufnr)

  if next(fn_map) == nil then
    notify_no_footnotes()
    return
  end

  -- Build sorted list of entries
  local entries = {}
  local ids = vim.tbl_keys(fn_map)
  table.sort(ids, function(a, b)
    -- Sort numeric IDs numerically, then alphabetically
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    if na then return true end
    if nb then return false end
    return a < b
  end)

  for _, id in ipairs(ids) do
    local info = fn_map[id]
    local ref_count = #info.refs
    local first_ref_lnum = info.refs[1] and info.refs[1].lnum or 0

    local status = ""
    if ref_count == 0 then
      status = " [ORPHAN DEF]"
    elseif not info.def_lnum then
      status = " [NO DEF]"
    end

    local preview = ""
    if #info.def_content > 0 then
      -- Show first line of definition, truncated
      local first_line = info.def_content[1]
      if #first_line > 60 then
        first_line = first_line:sub(1, 57) .. "..."
      end
      preview = " :: " .. first_line
    end

    local display_lnum = info.def_lnum or first_ref_lnum
    entries[#entries + 1] = {
      display = string.format(
        "%d: [^%s] (%d ref%s)%s%s",
        display_lnum,
        id,
        ref_count,
        ref_count == 1 and "" or "s",
        status,
        preview
      ),
      lnum = display_lnum,
    }
  end

  if #entries == 0 then
    notify_no_footnotes()
    return
  end

  local display_list = {}
  for _, e in ipairs(entries) do
    display_list[#display_list + 1] = e.display
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(display_list, {
    prompt = "Footnotes> ",
    actions = {
      ["default"] = function(selected)
        if selected[1] then
          local lnum = tonumber(selected[1]:match("^(%d+):"))
          if lnum then
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
          end
        end
      end,
    },
  })
end

-- ============================================================================
-- Rendering: virtual text inline footnote content
-- ============================================================================

--- Build a footnote header border line.
---@param id string footnote identifier
---@param suffix string|nil optional annotation
---@return string
local function footnote_header(id, suffix)
  local label = " [^" .. id .. "]"
  if suffix then
    label = label .. " " .. suffix
  end
  label = label .. " "
  local prefix_w = 2
  local border_w = config.footnotes.border_width
  local tail_w = math.max(4, border_w - prefix_w - display_width(label))
  return string.rep("\u{2500}", prefix_w) .. label .. string.rep("\u{2500}", tail_w)
end

--- Build a footnote footer border line.
---@return string
local function footnote_footer()
  return string.rep("\u{2500}", config.footnotes.border_width)
end

local FrameCache = require("andrew.vault.frame_cache")

--- Render footnote definition content as virtual text below each reference.
---@param opts? { silent?: boolean, full?: boolean, bufnr?: number, arena?: integer, frame_cache?: table }
function M.render_footnotes(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local full = opts.full ~= false -- default to full render
  local fc = opts.frame_cache
  local fc_tick = fc and vim.api.nvim_buf_get_changedtick(bufnr)

  -- Determine clear/render range
  local range_start, range_end
  local inv_ranges = opts.invalid_ranges
  if inv_ranges and #inv_ranges > 0 then
    -- Region-scoped clear: only clear within invalid ranges
    for _, range in ipairs(inv_ranges) do
      vim.api.nvim_buf_clear_namespace(bufnr, ns, range.start_line, range.end_line)
    end
    -- Clear bounding box for render scope; rendering loop uses
    -- inv_ranges for precise filtering (see ref_row check below)
    range_start = inv_ranges[1].start_line
    range_end = inv_ranges[#inv_ranges].end_line
  elseif opts.start_line and opts.end_line then
    -- Explicit range (prefetch zones): 1-indexed → 0-indexed for extmark API
    range_start = opts.start_line - 1
    range_end = opts.end_line
    vim.api.nvim_buf_clear_namespace(bufnr, ns, range_start, range_end)
  elseif full then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    range_start = 0
    range_end = vim.api.nvim_buf_line_count(bufnr)
  else
    range_start, range_end = viewport.get_margin_range(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, range_start, range_end)
  end

  -- Always parse full buffer (definitions may be outside viewport)
  local fn_map = parse_all_footnotes_cached(bufnr)
  if next(fn_map) == nil then
    footnotes_visible[bufnr] = false
    if not opts.silent then
      notify_no_footnotes()
    end
    return
  end

  local fn_config = config.footnotes or {}
  local max_lines = fn_config.max_lines or 5
  local border_hl = "VaultFootnoteBorder"
  local content_hl = "VaultFootnoteContent"
  local orphan_hl = "VaultFootnoteOrphan"

  local rendered_count = 0
  local parent_arena = opts.arena
  local arena_scope = parent_arena or render_arena.begin_scope()

  --- Render a single footnote reference at the given 0-indexed row.
  ---@param id string footnote identifier
  ---@param info table entry from fn_map
  ---@param ref_row number 0-indexed row
  local function render_ref_at(id, info, ref_row)
    -- Frame cache lookup (tick in key ensures content changes invalidate)
    if fc then
      local cache_key = bufnr .. ":" .. fc_tick .. ":" .. ref_row .. ":" .. id
      local cached = fc:get(cache_key)
      if cached then
        vim.api.nvim_buf_set_extmark(bufnr, ns, ref_row, 0, {
          virt_lines = cached.virt_lines,
          virt_lines_above = false,
        })
        rendered_count = rendered_count + 1
        return
      end
    end

    local virt_lines = render_arena.alloc_table(arena_scope)

    if #info.def_content > 0 then
      -- Header
      virt_lines[#virt_lines + 1] = { { footnote_header(id), border_hl } }

      -- Content lines (capped by max_lines)
      local line_count = math.min(#info.def_content, max_lines)
      for j = 1, line_count do
        virt_lines[#virt_lines + 1] = { { "  " .. info.def_content[j], content_hl } }
      end

      -- Truncation indicator
      if #info.def_content > max_lines then
        virt_lines[#virt_lines + 1] = {
          { "  \u{22ef} (" .. (#info.def_content - max_lines) .. " more line" ..
            (#info.def_content - max_lines == 1 and "" or "s") .. ")", border_hl },
        }
      end

      -- Footer
      virt_lines[#virt_lines + 1] = { { footnote_footer(), border_hl } }
      rendered_count = rendered_count + 1
    elseif not info.def_lnum then
      -- No definition exists: show orphan indicator
      virt_lines[#virt_lines + 1] = {
        { footnote_header(id, "(no definition)"), orphan_hl },
      }
    end

    if #virt_lines > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, ref_row, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
      })
      -- Store deep copy in frame cache (not arena-allocated)
      if fc then
        local cache_key = bufnr .. ":" .. fc_tick .. ":" .. ref_row .. ":" .. id
        fc:set(cache_key, { virt_lines = FrameCache.copy_virt_lines(virt_lines) })
      end
    end
  end

  local ok, err = pcall(function()
    -- Use pipeline token positions for reference iteration
    local lpc = require("andrew.vault.line_parse_cache")
    local iter = lpc.pipeline_token_iter(bufnr, "footnote")
    if iter then
      for line_nr, token in iter do
        if not token.subtype then -- references only, not definitions
          local id = token.captures[1]
          local info = fn_map[id]
          if info then
            local ref_row = line_nr -- already 0-indexed
            if ref_row >= range_start and ref_row < range_end then
              -- When using invalid_ranges, only render refs within them
              -- (not in valid gaps between ranges) to avoid duplicate extmarks
              local should_render = not inv_ranges
                or require("andrew.vault.region_tracker").is_line_in_ranges(ref_row, inv_ranges)
              if should_render then
                render_ref_at(id, info, ref_row)
              end
            end
          end
        end
      end
    end

    footnotes_visible[bufnr] = true

    if not opts.silent then
      local orphan_count = 0
      for _, info in pairs(fn_map) do
        if #info.refs > 0 and not info.def_lnum then
          orphan_count = orphan_count + 1
        end
      end

      local parts = render_arena.alloc_table(arena_scope)
      if rendered_count > 0 then
        parts[#parts + 1] = rendered_count .. " footnote(s) rendered"
      end
      if orphan_count > 0 then
        parts[#parts + 1] = orphan_count .. " missing definition(s)"
      end
      if #parts > 0 then
        notify.info(table.concat(parts, ", "))
      end
    end
  end)

  if not parent_arena then
    render_arena.end_scope(arena_scope)
  end
  if not ok then
    log.error("render_footnotes failed: %s", err)
  end
end

--- Coordinated update entry point (called by highlight_coordinator).
---@param bufnr number
---@param _code_excl fun  accepted but unused (footnotes don't use code exclusion)
---@param opts table { full: boolean, prefetch?: boolean, start_line?: number, end_line?: number }
function M.coordinated_update(bufnr, _code_excl, opts)
  if not M.enabled then return end
  local ranges = opts and opts.invalid_ranges
  if ranges and #ranges == 0 then return end -- nothing to do
  M.render_footnotes({
    bufnr = bufnr,
    full = opts.full,
    silent = true,
    arena = opts.arena,
    frame_cache = opts.frame_cache,
    start_line = opts.start_line,
    end_line = opts.end_line,
    invalid_ranges = ranges,
  })
end

--- Clear all footnote virtual text from the current buffer.
function M.clear_footnotes()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  footnotes_visible[bufnr] = false
end

--- Toggle footnote rendering on/off in the current buffer.
function M.toggle_footnotes()
  local bufnr = vim.api.nvim_get_current_buf()
  if footnotes_visible[bufnr] then
    M.clear_footnotes()
  else
    M.render_footnotes()
  end
end

-- ============================================================================
-- Floating preview for footnote under cursor
-- ============================================================================

--- Show a floating preview of the footnote definition under the cursor.
--- Designed to be called from preview.lua's preview() function as a fallback
--- when no wikilink is detected.
---@return boolean true if a footnote was found and previewed
function M.preview_footnote()
  local id = get_footnote_at_cursor()
  if not id then
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local content, def_lnum = get_definition_for_id(bufnr, id)

  local all_lines
  local title = "[^" .. id .. "]"

  if content and #content > 0 then
    all_lines = content
  elseif def_lnum then
    all_lines = { "(empty footnote definition)" }
  else
    all_lines = { "[No definition found for [^" .. id .. "]]" }
  end

  -- Compute float dimensions
  local fn_config = config.footnotes or {}
  local max_width = config.preview.max_width
  local max_height = fn_config.preview_max_lines or config.preview.max_lines
  local width = math.min(math.max(text_utils.max_display_width(all_lines), 20), max_width)
  local height = math.min(#all_lines, max_height)

  -- Open floating preview via shared display helper
  local float = ui.create_float_display({
    title = { { " " .. title .. " ", "VaultFootnoteRef" } },
    lines = all_lines,
    width = width,
    height = height,
    enter = false,
    relative = "cursor",
    row = 1,
    col = 0,
    close_keymaps = false, -- auto-closed on cursor move, no interactive close needed
  })

  local win = float.win
  local buf = float.buf

  -- Window options (shared markdown float setup)
  ui.setup_markdown_float_opts(win)

  -- Set filetype, treesitter, and render-markdown
  ui.setup_and_render_markdown(buf, win)

  -- Auto-close on cursor move or leaving the buffer
  local parent_buf = vim.api.nvim_get_current_buf()
  local augroup = vim.api.nvim_create_augroup("VaultFootnotePreviewClose", { clear = true })

  local function close()
    cleanup.close_augroup(augroup)
    cleanup.close_win_buf(win, buf)
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = parent_buf,
    once = true,
    callback = close,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    buffer = parent_buf,
    once = true,
    callback = close,
  })

  return true
end

-- ============================================================================
-- Orphan detection
-- ============================================================================

--- Find orphaned footnotes: references without definitions and definitions
--- without references. Shows results in a notification.
function M.orphans()
  local bufnr = vim.api.nvim_get_current_buf()
  local fn_map = parse_all_footnotes_cached(bufnr)

  if next(fn_map) == nil then
    notify_no_footnotes()
    return
  end

  local orphan_refs = {}   -- refs with no definition
  local orphan_defs = {}   -- definitions with no references

  for id, info in pairs(fn_map) do
    if #info.refs > 0 and not info.def_lnum then
      orphan_refs[#orphan_refs + 1] = id
    end
    if info.def_lnum and #info.refs == 0 then
      orphan_defs[#orphan_defs + 1] = id
    end
  end

  table.sort(orphan_refs)
  table.sort(orphan_defs)

  if #orphan_refs == 0 and #orphan_defs == 0 then
    notify.info("all footnotes are properly linked")
    return
  end

  local lines = { "Footnote Orphans:" }
  if #orphan_refs > 0 then
    lines[#lines + 1] = "  References without definitions:"
    for _, id in ipairs(orphan_refs) do
      local info = fn_map[id]
      local lnums = {}
      for _, ref in ipairs(info.refs) do
        lnums[#lnums + 1] = tostring(ref.lnum)
      end
      lines[#lines + 1] = "    [^" .. id .. "] at line(s) " .. table.concat(lnums, ", ")
    end
  end
  if #orphan_defs > 0 then
    lines[#lines + 1] = "  Definitions without references:"
    for _, id in ipairs(orphan_defs) do
      local info = fn_map[id]
      lines[#lines + 1] = "    [^" .. id .. "]: at line " .. info.def_lnum
    end
  end

  notify.info_lines(lines)
end

-- Register with highlight coordinator for automatic rendering with frame cache support.
-- Priority 70: after autolink (60), before heavier modules.
-- supports_prefetch: footnotes can render in prefetch zones via start_line/end_line.
hl_coord.register("footnotes", M.coordinated_update, function() return M.enabled end, 70, { supports_prefetch = true })

return M
