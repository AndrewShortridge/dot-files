--- smart-paste.lua — Smart paste: URL/note-as-link for markdown visual paste
local M = {}

local vault_index = nil  -- lazy-loaded to avoid circular deps

--- Check if a string looks like a URL suitable for a markdown link.
--- Matches http://, https://, and bare www. prefixes.
---@param s string  The candidate string (trimmed, single-line)
---@return boolean
function M.is_url(s)
  if not s or s == "" then
    return false
  end
  -- Standard http(s) URL
  if s:match("^https?://[%w]") then
    return true
  end
  -- Bare www prefix (browsers often copy without protocol)
  if s:match("^www%.[%w]") then
    return true
  end
  return false
end

--- Normalize a URL for use in a markdown link.
--- Adds https:// to bare www. URLs.
---@param url string
---@return string
function M.normalize_url(url)
  if url:match("^www%.") then
    return "https://" .. url
  end
  return url
end

--- Check if a string resolves to a vault note name via the vault index.
--- Returns the canonical note name (without .md) if found, nil otherwise.
---@param s string  The candidate string (trimmed, single-line)
---@return string|nil
function M.resolve_vault_note(s)
  if not s or s == "" then
    return nil
  end
  -- Reject strings that look like URLs or paths
  if s:match("[/\\]") or s:match("^https?://") or s:match("^www%.") then
    return nil
  end
  -- Lazy-load vault_index (avoids requiring it at module load time)
  if not vault_index then
    local ok, vi = pcall(require, "andrew.vault.vault_index")
    if not ok then
      return nil
    end
    vault_index = vi
  end
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    return nil
  end
  -- Strip .md extension if the user copied "Note.md"
  local name = s:gsub("%.md$", "")
  -- Reject empty or whitespace-only after stripping
  if vim.trim(name) == "" then
    return nil
  end
  local paths = idx:resolve_name(name)
  if paths and #paths > 0 then
    return name
  end
  return nil
end

--- Detect what kind of link the clipboard content should produce.
---@param clipboard string  The raw clipboard text
---@return "url"|"note"|nil  The content type
---@return string|nil        The cleaned value (normalized URL or note name)
function M.detect(clipboard)
  if not clipboard then
    return nil, nil
  end
  -- Trim whitespace and collapse to single line
  local trimmed = vim.trim(clipboard)
  -- Reject multi-line clipboard (URLs and note names are single-line)
  if trimmed:find("\n") then
    return nil, nil
  end
  -- Check URL first (higher priority)
  if M.is_url(trimmed) then
    return "url", M.normalize_url(trimmed)
  end
  -- Check vault note name
  local note_name = M.resolve_vault_note(trimmed)
  if note_name then
    return "note", note_name
  end
  return nil, nil
end

--- Build selection info from row/col bounds.
---@param start_row number
---@param start_col number
---@param end_row number
---@param end_col number
---@return { text: string, row: number, start_col: number, end_col: number, line: string }|nil
local function selection_from_bounds(start_row, start_col, end_row, end_col)
  if start_row ~= end_row then
    return nil -- multi-line not supported for link text
  end

  local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
  if not line then
    return nil
  end

  -- Handle linewise selection: end_col can be very large (2147483647)
  if end_col >= #line then
    end_col = #line
  end

  local text = line:sub(start_col, end_col)
  return {
    text = text,
    row = start_row,
    start_col = start_col,
    end_col = end_col,
    line = line,
  }
end

--- Get the visual selection text and position from '< '> marks.
--- Must be called AFTER exiting visual mode (marks are set).
---@return { text: string, row: number, start_col: number, end_col: number, line: string }|nil
local function get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  return selection_from_bounds(start_pos[2], start_pos[3], end_pos[2], end_pos[3])
end

--- Perform smart paste: replace visual selection with a link using clipboard content.
--- Returns true if a smart paste was performed, false if it should fall through.
---@param opts? { force: boolean, range: number[] }
---   force: always attempt (for <leader>mP)
---   range: {start_row, start_col, end_row, end_col} pre-captured selection bounds
---@return boolean
function M.smart_paste(opts)
  opts = opts or {}

  -- Check per-buffer opt-out (only for auto mode, not forced)
  if not opts.force then
    local auto = vim.b.smart_paste_auto
    if auto == false then
      return false
    end
  end

  -- Read the system clipboard (+ register)
  local clipboard = vim.fn.getreg("+")
  if not clipboard or clipboard == "" then
    if opts.force then
      vim.notify("Smart paste: clipboard is empty", vim.log.levels.WARN)
    end
    return false
  end

  local content_type, value = M.detect(clipboard)
  if not content_type then
    if opts.force then
      vim.notify("Smart paste: clipboard is not a URL or vault note", vim.log.levels.WARN)
    end
    return false
  end

  -- Get the visual selection — prefer pre-captured range, fall back to marks
  local sel
  if opts.range then
    sel = selection_from_bounds(opts.range[1], opts.range[2], opts.range[3], opts.range[4])
  else
    sel = get_visual_selection()
  end
  if not sel then
    if opts.force then
      vim.notify("Smart paste: multi-line selections not supported for links", vim.log.levels.WARN)
    end
    return false
  end

  -- Build the replacement text
  local replacement
  if content_type == "url" then
    replacement = "[" .. sel.text .. "](" .. value .. ")"
  elseif content_type == "note" then
    replacement = "[[" .. value .. "|" .. sel.text .. "]]"
  end

  -- Replace the selection on the line
  local new_line = sel.line:sub(1, sel.start_col - 1) .. replacement .. sel.line:sub(sel.end_col + 1)
  vim.api.nvim_buf_set_lines(0, sel.row - 1, sel.row, false, { new_line })

  -- Position cursor at end of the inserted link
  local end_pos = sel.start_col - 1 + #replacement - 1
  vim.api.nvim_win_set_cursor(0, { sel.row, end_pos })

  -- Notify (briefly) what was done
  local type_label = content_type == "url" and "URL" or "note"
  vim.notify("Smart paste: linked as " .. type_label, vim.log.levels.INFO)

  return true
end

return M
