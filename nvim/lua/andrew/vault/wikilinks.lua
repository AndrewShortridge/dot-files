local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local link_utils = require("andrew.vault.link_utils")
local vault_index = require("andrew.vault.vault_index")
local file_cache = require("andrew.vault.file_cache")
local notify = require("andrew.vault.notify")
local pat = require("andrew.vault.patterns")
local log = require("andrew.vault.vault_log").scope("wikilinks")

local M = {}

local LBRACKET = 91 -- string.byte("[")

--- Check if a link name looks like a relative or folder-qualified path.
---@param name string
---@return boolean
local function is_path_like(name)
  return name:match("^%.%.?/") ~= nil -- starts with ./ or ../
    or name:find("/") ~= nil -- contains any /
end

--- Try to resolve a path-like link name relative to the current buffer's directory.
--- Falls back to vault root for folder-qualified paths.
--- Probes with and without .md extension.
---@param name string  The link name (e.g., "./Sibling", "../Parent/Note", "Sub/Note")
---@param bufnr number|nil  Buffer to resolve relative to (defaults to current)
---@return string|nil  Absolute path if found, nil otherwise
local function resolve_relative(name, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then return nil end
  local buf_dir = link_utils.lua_dirname(bufname)

  --- Probe a base directory + relative name, trying both as-is and with .md.
  ---@param base string  absolute directory path
  ---@return string|nil
  local function probe(base)
    local candidate = vim.fs.normalize(base .. "/" .. name)

    -- Try exact path first (handles names with explicit extension)
    if vim.uv.fs_stat(candidate) then
      return candidate
    end

    -- Try with .md extension appended
    local with_ext = candidate .. ".md"
    if vim.uv.fs_stat(with_ext) then
      return with_ext
    end

    return nil
  end

  -- 1. Resolve relative to the current buffer's directory
  local result = probe(buf_dir)
  if result then return result end

  -- 2. For folder-qualified paths (not explicit ./ or ../),
  --    also try relative to the vault root (Obsidian behavior)
  if not name:match("^%.%.?/") then
    result = probe(engine.vault_path)
    if result then return result end
  end

  return nil
end

--- Find a block reference (^block-id) in a file.
--- Returns the 1-indexed line number if found, nil otherwise.
---@param path string absolute file path
---@param block_id string the block identifier (without the ^ prefix)
---@return number|nil
local function find_block_in_file(path, block_id)
  local lines = file_cache.read(path)
  if not lines then
    return nil
  end
  for line_num, line in ipairs(lines) do
    -- Block IDs appear as ^identifier at the end of a line
    if line:match("%^" .. vim.pesc(block_id) .. "%s*$") then
      return line_num
    end
  end
  return nil
end

--- Weekday name to os.date wday number (Sunday=1 .. Saturday=7).
---@type table<string, number>
local WEEKDAYS = {
  sunday = 1, monday = 2, tuesday = 3, wednesday = 4,
  thursday = 5, friday = 6, saturday = 7,
}

--- Resolve a temporal alias to the absolute path of a daily log.
--- Returns nil if the name is not a recognized temporal alias.
--- Does NOT check whether the file exists — callers decide how to handle missing files.
--- NOTE: This is a fallback — resolve_link() checks the vault index first, so a vault
--- note whose name matches a temporal alias (e.g. "today") will shadow the alias.
---@param name string link name (e.g., "today", "last monday")
---@return string|nil abs_path to the daily log file
---@return string|nil date in YYYY-MM-DD format (for callers that need it)
local function resolve_temporal(name)
  local cfg = config.temporal_aliases
  if not cfg or not cfg.enabled then
    return nil, nil
  end

  local lower = vim.trim(name):lower()

  -- 1) Check static aliases (today, yesterday, tomorrow)
  local offset = cfg.aliases[lower]
  if offset then
    local date = engine.date_offset(offset)
    local path = engine.vault_path .. "/" .. config.dirs.log .. "/" .. date .. ".md"
    return path, date
  end

  -- 2) Check relative weekday aliases (last monday, next friday)
  if cfg.relative_weekdays then
    local direction, weekday_name = lower:match("^(last)%s+(%a+)$")
    if not direction then
      direction, weekday_name = lower:match("^(next)%s+(%a+)$")
    end
    if direction and weekday_name then
      local target_wday = WEEKDAYS[weekday_name]
      if target_wday then
        local today_ts = os.time()
        local today_wday = tonumber(os.date("%w", today_ts)) + 1 -- os.date %w is 0-indexed
        local diff
        if direction == "last" then
          diff = today_wday - target_wday
          -- When diff is 0 (same weekday), "last X" means the previous week's X,
          -- not today. The <= 0 guard handles both same-day (0) and wrap-around
          -- (negative) cases by adding 7. Do NOT weaken to < 0.
          if diff <= 0 then diff = diff + 7 end
          diff = -diff
        else -- "next"
          diff = target_wday - today_wday
          -- When diff is 0 (same weekday), "next X" means next week's X,
          -- not today. The <= 0 guard handles both same-day (0) and wrap-around
          -- (negative) cases by adding 7. Do NOT weaken to < 0.
          if diff <= 0 then diff = diff + 7 end
        end
        local date = engine.date_offset(diff)
        local path = engine.vault_path .. "/" .. config.dirs.log .. "/" .. date .. ".md"
        return path, date
      end
    end
  end

  return nil, nil
end

--- Resolution order: relative path → vault index → temporal alias.
--- Vault index matches take precedence over temporal aliases, so a note named
--- "today" or "last monday" will shadow the corresponding temporal alias.
--- This is intentional — explicit vault notes should win over generated paths.
--- @param link_name string
--- @param bufnr? number
--- @return string|nil path
--- @return string|nil err  Reason string on failure
local function resolve_link(link_name, bufnr)
  -- Try relative/folder-qualified path resolution first
  if is_path_like(link_name) then
    local path = resolve_relative(link_name, bufnr)
    if path then return path, nil end
  end

  -- Fall through to vault index name-based resolution
  local abs_path = link_utils.resolve_note_via_index(link_name)
  if abs_path then
    return abs_path, nil
  end
  -- Provide specific error when the index itself isn't available
  local idx = vault_index.current()
  if not idx then
    return nil, "vault index not initialized"
  elseif not idx:is_ready() then
    return nil, "vault index still building"
  end

  -- Fallback: temporal alias resolution
  local temporal_path = resolve_temporal(link_name)
  if temporal_path then
    return temporal_path, nil
  end

  return nil, "no matching note found"
end

--- Get markdown link [text](destination) under cursor.
--- Falls back to closest link on line when conceal shifts cursor positions.
---@return string|nil destination portion of the link
local function get_mdlink_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  local closest_dest = nil
  local closest_dist = math.huge
  local start = 1
  while true do
    local s, e, dest = line:find("%[.-%]%((.-)%)", start)
    if not s then
      break
    end
    -- Exact match: cursor inside the link span
    if col >= s and col <= e then
      return dest
    end
    -- Track closest link as fallback (handles concealed offsets)
    local dist = math.min(math.abs(col - s), math.abs(col - e))
    if dist < closest_dist then
      closest_dist = dist
      closest_dest = dest
    end
    start = e + 1
  end

  -- If no exact match but a link exists nearby on this line, use it
  if closest_dest and closest_dist <= 5 then
    return closest_dest
  end
  return nil
end

--- Get bare URL under cursor.
---@return string|nil
local function get_url_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local pattern = link_utils.URL_PAT
  local start = 1
  while true do
    local s, e = line:find(pattern, start)
    if not s then
      return nil
    end
    if col >= s and col <= e then
      return line:sub(s, e)
    end
    start = e + 1
  end
end

local function follow_link()
  -- 1) Wikilink: [[target]] or [[target|alias]] or [[target#heading]] or [[target^block-id]]
  local details = link_utils.get_wikilink_under_cursor()
  if details then
    -- Same-file reference: [[#heading]] or [[^block-id]]
    if details.name == "" and (details.heading or details.block_id) then
      if details.heading then
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local line = link_utils.find_heading_line(lines, details.heading)
        if line then
          vim.api.nvim_win_set_cursor(0, { line, 0 })
          vim.cmd("normal! zz")
          return
        end
        notify.heading_not_found(details.heading)
      elseif details.block_id then
        local path = vim.api.nvim_buf_get_name(0)
        local block_line = find_block_in_file(path, details.block_id)
        if block_line then
          vim.api.nvim_win_set_cursor(0, { block_line, 0 })
          vim.cmd("normal! zz")
        else
          notify.block_not_found(details.block_id)
        end
      end
      return
    end

    -- Normal cross-file wikilink
    if details.name ~= "" then
      local link = details.name
      local path, resolve_err = resolve_link(link)
      if path then
        vim.cmd("edit " .. vim.fn.fnameescape(path))

        -- Jump to heading if specified
        if details.heading then
          -- Prefer vault index (pre-computed slugs, no regex scan)
          local rel = engine.vault_relative(path)
          local line = rel and link_utils.find_heading_line_indexed(rel, details.heading)
          if not line then
            -- Fallback: scan buffer lines directly
            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            line = link_utils.find_heading_line(lines, details.heading)
          end
          if line then
            vim.api.nvim_win_set_cursor(0, { line, 0 })
            vim.cmd("normal! zz")
          end
        end

        -- Jump to block reference if specified
        if details.block_id then
          local block_line = find_block_in_file(path, details.block_id)
          if block_line then
            vim.api.nvim_win_set_cursor(0, { block_line, 0 })
            vim.cmd("normal! zz")
          else
            notify.block_not_found(details.block_id)
          end
        end
      else
        log.debug("resolve_link(%s) failed: %s", link, resolve_err or "unknown")
        -- Check if this is a temporal alias that should auto-create a daily log
        local temporal_path, temporal_date = resolve_temporal(link)
        if temporal_path and temporal_date then
          local navigate = require("andrew.vault.navigate")
          navigate.open_daily_by_date(temporal_date, true)
          return
        end

        -- Create new notes: respect relative paths, otherwise use buffer directory
        local new_path
        if is_path_like(link) then
          local buf_dir = link_utils.lua_dirname(vim.api.nvim_buf_get_name(0))
          new_path = vim.fs.normalize(buf_dir .. "/" .. link)
          if not new_path:match(pat.MD_EXTENSION) then
            new_path = new_path .. ".md"
          end
          -- Ensure the new path is within the vault
          if not engine.is_vault_path(new_path) then
            new_path = engine.vault_path .. "/" .. link .. ".md"
          end
        else
          local buf_dir = link_utils.lua_dirname(vim.api.nvim_buf_get_name(0))
          if engine.is_vault_path(buf_dir) then
            new_path = buf_dir .. "/" .. link .. ".md"
          else
            new_path = engine.vault_path .. "/" .. link .. ".md"
          end
        end
        local dir = link_utils.lua_dirname(new_path)
        vim.fn.mkdir(dir, "p")
        vim.cmd("edit " .. vim.fn.fnameescape(new_path))
        -- Update vault index for the new file
        local idx = vault_index.current()
        if idx then idx:update_file(new_path) end
        notify.note_created(link)
      end
      return
    end
  end

  -- 2) Markdown link: [text](url-or-path) or [text](#anchor)
  local dest = get_mdlink_under_cursor()
  if dest then
    if dest:match("^https?://") then
      vim.ui.open(dest)
    else
      -- Split into file path and anchor: "file.md#anchor" or "#anchor"
      local file_part, anchor = dest:match("^(.-)#(.+)$")
      if not anchor then
        file_part = dest
      end

      -- Navigate to file if specified
      if file_part and file_part ~= "" then
        local buf_dir = link_utils.lua_dirname(vim.api.nvim_buf_get_name(0))
        local target = buf_dir .. "/" .. file_part
        if vim.fn.filereadable(target) == 1 then
          vim.cmd("edit " .. vim.fn.fnameescape(target))
        else
          notify.file_not_found(file_part)
          return
        end
      end

      -- Jump to anchor heading if present
      if anchor then
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local line = link_utils.find_heading_line(lines, anchor)
        if line then
          vim.api.nvim_win_set_cursor(0, { line, 0 })
          vim.cmd("normal! zz")
          return
        end
        notify.heading_not_found(anchor)
      end
    end
    return
  end

  -- 3) Bare URL under cursor
  local url = get_url_under_cursor()
  if url then
    vim.ui.open(url)
    return
  end

  -- 4) Fall back to normal gf
  local ok, _ = pcall(vim.cmd, "normal! gF")
  if not ok then
    local ok2, err2 = pcall(vim.cmd, "normal! gf")
    if not ok2 then log.debug("gf fallback failed: %s", err2) end
  end
end

--- Find all link positions on a single line (wikilinks and markdown links).
--- Returns positions sorted by column.
---@param line string
---@return number[] sorted 1-indexed column positions
local function find_links_on_line(line)
  local cols = {}
  -- Find wikilinks: [[...]]
  pat.scan_wikilinks(line, function(inner, start_col, end_col)
    cols[#cols + 1] = start_col
  end)
  -- Find markdown links: [text](url) — but skip wikilinks (preceded by [)
  pos = 1
  while true do
    local s = line:find(pat.MARKDOWN_LINK, pos)
    if not s then break end
    if s > 1 and line:byte(s - 1) == LBRACKET then
      pos = s + 1
    else
      cols[#cols + 1] = s
      pos = s + 1
    end
  end
  table.sort(cols)
  return cols
end

--- Jump to the next or previous link without scanning the entire buffer.
--- Scans lazily from cursor position with early exit; wraps around at
--- buffer boundaries (end→start for forward, start→end for backward).
---@param direction 1|-1
local function jump_link(direction)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local n = #lines
  if n == 0 then return end

  local cur_row, cur_col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local cur_col = cur_col0 + 1 -- 1-indexed

  if direction == 1 then
    -- Forward: scan from current line to end, then wrap 1..current line
    for i = cur_row, n do
      local cols = find_links_on_line(lines[i])
      for _, c in ipairs(cols) do
        if i > cur_row or c > cur_col then
          vim.api.nvim_win_set_cursor(0, { i, c - 1 })
          return
        end
      end
    end
    -- Wrap around: scan from start to current position
    for i = 1, cur_row do
      local cols = find_links_on_line(lines[i])
      for _, c in ipairs(cols) do
        if i < cur_row or c <= cur_col then
          vim.api.nvim_win_set_cursor(0, { i, c - 1 })
          return
        end
      end
    end
  else
    -- Backward: scan from current line to start, then wrap end..current line
    for i = cur_row, 1, -1 do
      local cols = find_links_on_line(lines[i])
      for j = #cols, 1, -1 do
        local c = cols[j]
        if i < cur_row or c < cur_col then
          vim.api.nvim_win_set_cursor(0, { i, c - 1 })
          return
        end
      end
    end
    -- Wrap around: scan from end to current position
    for i = n, cur_row, -1 do
      local cols = find_links_on_line(lines[i])
      for j = #cols, 1, -1 do
        local c = cols[j]
        if i > cur_row or c >= cur_col then
          vim.api.nvim_win_set_cursor(0, { i, c - 1 })
          return
        end
      end
    end
  end
end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
  vim.keymap.set("n", "gf", follow_link, {
    buffer = ev.buf,
    desc = "Vault: follow link (wiki/markdown/URL)",
    silent = true,
  })
  vim.keymap.set("n", "gx", follow_link, {
    buffer = ev.buf,
    desc = "Vault: open link in browser or follow",
    silent = true,
  })
  vim.keymap.set("n", "]o", function()
    jump_link(1)
  end, {
    buffer = ev.buf,
    desc = "Vault: next link",
    silent = true,
  })
  vim.keymap.set("n", "[o", function()
    jump_link(-1)
  end, {
    buffer = ev.buf,
    desc = "Vault: previous link",
    silent = true,
  })
end

function M.setup()
  -- FileType autocmd removed: now dispatched via event_dispatch.lua

end

-- Expose for use by other vault modules (embed, preview, etc.)
M.resolve_link = resolve_link
M.find_block_in_file = find_block_in_file

return M
