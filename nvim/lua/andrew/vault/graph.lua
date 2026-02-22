local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")
local wikilinks = require("andrew.vault.wikilinks")

local M = {}

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

local function define_highlights()
  local function hi(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  hi("VaultGraphTitle", "Title")
  hi("VaultGraphDivider", "FloatBorder")
  hi("VaultGraphBacklink", "Function")
  hi("VaultGraphForwardlink", "String")
  hi("VaultGraphConnector", "NonText")
  hi("VaultGraphCount", "Comment")
  -- Dark blue for links whose target file exists on disk
  vim.api.nvim_set_hl(0, "VaultGraphExistingLink", { default = true, fg = "#3b82f6", bold = true })
end

-- ---------------------------------------------------------------------------
-- Link helpers
-- ---------------------------------------------------------------------------

--- Resolve a link name to an absolute file path, or nil.
--- Delegates to wikilinks module for case-insensitive, cached resolution.
---@param name string
---@return string|nil
local resolve_link = wikilinks.resolve_link

--- Disambiguate link entries that share the same display name by replacing
--- their name with the vault-relative path (without extension).
---@param entries {name: string, path: string|nil}[]
---@return {name: string, path: string|nil}[]
local function disambiguate_names(entries)
  local groups = {}
  for _, entry in ipairs(entries) do
    local key = entry.name:lower()
    if not groups[key] then
      groups[key] = {}
    end
    groups[key][#groups[key] + 1] = entry
  end
  for _, group in pairs(groups) do
    if #group > 1 then
      for _, entry in ipairs(group) do
        if entry.path then
          local rel = engine.vault_relative(entry.path) or entry.path
          entry.name = vim.fn.fnamemodify(rel, ":r")
        end
      end
    end
  end
  return entries
end

--- Collect forward links from the current buffer (deduplicated, sorted).
--- Extracts the note name portion, stripping heading (#), block (^), and alias (|) parts.
--- Also skips embed syntax (![[...]]) prefix and inline field patterns ([key:: value]).
---@return {name: string, path: string|nil}[] link entries with display name and resolved path
local function collect_forward_links()
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local seen = {} -- keyed by resolved path or lowercase name for dedup
  local links = {}
  local in_frontmatter = false
  local frontmatter_done = false
  local in_code_fence = false
  for idx, line in ipairs(buf_lines) do
    -- Track YAML frontmatter (--- delimited, must start at line 1)
    if not frontmatter_done then
      if idx == 1 and line:match("^%-%-%-$") then
        in_frontmatter = true
        goto next_line
      elseif in_frontmatter then
        if line:match("^%-%-%-$") then
          in_frontmatter = false
          frontmatter_done = true
        end
        goto next_line
      else
        frontmatter_done = true
      end
    end

    -- Track fenced code blocks
    if line:match("^%s*```") or line:match("^%s*~~~") then
      in_code_fence = not in_code_fence
      goto next_line
    end
    if in_code_fence then goto next_line end

    do
      local search_start = 1
      while true do
        local s, e = line:find("%[%[(.-)%]%]", search_start)
        if not s then break end
        local inner = line:sub(s + 2, e - 2)
        search_start = e + 1

        -- Skip inline field patterns: [key:: value]
        if inner:match("^[%w_%-]+::") then goto next_link end

        -- Skip embed syntax ![[...]]
        if s > 1 and line:sub(s - 1, s - 1) == "!" then goto next_link end

        -- Extract just the note name: strip |alias, #heading, ^block
        local name = link_utils.link_name(inner)
        if name == "" then goto next_link end

        -- Skip heading-only or block-only references (no file target)
        if name:match("^[#%^]") then goto next_link end

        -- Extract display basename and resolve to full path
        local display = name:match("([^/]+)$") or name
        local path = resolve_link(display)
        local key = path or display:lower()
        if not seen[key] then
          seen[key] = true
          links[#links + 1] = { name = display, path = path }
        end

        ::next_link::
      end
    end

    ::next_line::
  end
  table.sort(links, function(a, b) return a.name:lower() < b.name:lower() end)
  return links
end

--- Collect backlinks by searching the vault with ripgrep (synchronous).
---@param note_name string
---@return {name: string, path: string}[] link entries with display name and absolute path
local function collect_backlinks(note_name)
  -- Use list form to avoid shell escaping issues; -F for fixed-string matching
  local results = vim.fn.systemlist({
    "rg", "--no-heading", "-l", "-F",
    "[[" .. note_name,
    engine.vault_path,
    "--glob", "*.md",
  })
  if vim.v.shell_error ~= 0 then
    -- rg returns 1 when no matches found; that is not an error for us
    results = {}
  end

  local current_path = vim.api.nvim_buf_get_name(0)
  local backlinks = {}
  local seen = {}
  for _, path in ipairs(results) do
    -- Normalise to absolute and skip the current file
    local abs = vim.fn.fnamemodify(path, ":p")
    if abs ~= current_path then
      -- Deduplicate by absolute path (not stem) so same-named files in
      -- different directories each get their own entry.
      if not seen[abs] then
        seen[abs] = true
        local stem = vim.fn.fnamemodify(abs, ":t:r")
        backlinks[#backlinks + 1] = { name = stem, path = abs }
      end
    end
  end
  table.sort(backlinks, function(a, b) return a.name:lower() < b.name:lower() end)
  return backlinks
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Return the display width of a UTF-8 string (each codepoint = 1 cell).
--- This is a simplified version that assumes no wide (CJK) characters.
---@param s string
---@return number
local function display_width(s)
  return vim.fn.strdisplaywidth(s)
end

--- Build the ASCII graph lines and collect metadata for highlights / actions.
--- All layout math uses display-width columns; highlight byte offsets are
--- derived from Lua string.find (which operates on bytes).
---@param note_name string
---@param backlinks {name: string, path: string|nil}[]
---@param forward_links {name: string, path: string|nil}[]
---@param total_width number  display columns
---@return string[] lines, table[] highlight_ranges, table<number, {backlink: string|nil, forward: string|nil}> line_to_note
local function render_graph(note_name, backlinks, forward_links, total_width)
  local lines = {}
  local highlights = {} -- { line (0-indexed), col_start, col_end, group } (byte offsets)
  local line_to_note = {} -- 1-indexed line -> { backlink = path|nil, forward = path|nil }

  local half = math.floor(total_width / 2)

  -- Box-drawing literals and their display widths
  local connector_in  = " \u{2500}\u{2500}\u{2500}\u{2500}\u{2524}" -- " ────┤"
  local connector_out = "\u{251C}\u{2500}\u{2500}\u{2500}\u{2500} " -- "├──── "
  local divider_char  = "\u{2502}" -- "│"
  local border_char   = "\u{2501}" -- "━"

  local connector_in_dw  = display_width(connector_in)   -- 6
  local connector_out_dw = display_width(connector_out)   -- 6
  local divider_dw       = display_width(divider_char)    -- 1

  local function add_hl(line_idx, col_start, col_end, group)
    highlights[#highlights + 1] = { line_idx, col_start, col_end, group }
  end

  --- Add highlight by finding a literal substring in the line (byte positions).
  local function hl_find(row_0, line_str, needle, group, search_from)
    local s, e = line_str:find(needle, search_from or 1, true)
    if s then
      add_hl(row_0, s - 1, e, group)
    end
  end

  -- Top border
  local border_line = string.rep(border_char, total_width)
  lines[#lines + 1] = border_line
  add_hl(0, 0, #border_line, "VaultGraphDivider")

  -- Column headers (labels are ASCII; divider is multibyte)
  local lbl_back = "Backlinks"
  local lbl_fwd = "Forward Links"
  local left_header = string.rep(" ", math.max(0, half - #lbl_back - 1)) .. lbl_back
  local gap_left = half - display_width(left_header)
  local header_line = left_header
    .. string.rep(" ", math.max(1, gap_left))
    .. divider_char
    .. "   "
    .. lbl_fwd
  lines[#lines + 1] = header_line
  do
    local row_0 = #lines - 1
    hl_find(row_0, header_line, lbl_back, "VaultGraphDivider")
    hl_find(row_0, header_line, lbl_fwd, "VaultGraphDivider")
    hl_find(row_0, header_line, divider_char, "VaultGraphDivider")
  end

  -- Empty line with just the divider
  local empty_div = string.rep(" ", half) .. divider_char
  lines[#lines + 1] = empty_div
  add_hl(#lines - 1, half, half + #divider_char, "VaultGraphDivider")

  -- Link rows: pair up backlinks and forward links side by side
  local max_rows = math.max(#backlinks, #forward_links)
  for i = 1, max_rows do
    local bl = backlinks[i]
    local fl = forward_links[i]

    local left_part, right_part
    local bl_display, fl_display
    if bl then
      -- Available display columns for the name on the left side
      local avail = half - connector_in_dw
      bl_display = bl.name
      local name_dw = display_width(bl_display)
      if name_dw > avail then
        -- Truncate (simple byte truncation is fine for ASCII note names)
        bl_display = bl_display:sub(1, avail - 1) .. "\u{2026}"
        name_dw = display_width(bl_display)
      end
      local pad = math.max(0, avail - name_dw)
      left_part = string.rep(" ", pad) .. bl_display .. connector_in
    else
      -- No backlink: just draw the center divider
      left_part = string.rep(" ", half - divider_dw) .. divider_char
    end

    if fl then
      local avail = half - connector_out_dw - 1
      fl_display = fl.name
      local name_dw = display_width(fl_display)
      if name_dw > avail then
        fl_display = fl_display:sub(1, avail - 1) .. "\u{2026}"
      end
      right_part = connector_out .. fl_display
    else
      right_part = ""
    end

    -- When bl is present, left_part ends with ────┤ which serves as the divider.
    -- When bl is absent, left_part ends with │ at the center column.
    local line_str = left_part .. right_part

    lines[#lines + 1] = line_str
    local row = #lines - 1 -- 0-indexed for highlights

    -- Store navigation targets (absolute paths for direct file opening).
    local line_1idx = #lines
    if bl or fl then
      line_to_note[line_1idx] = {
        backlink = bl and bl.path or nil,
        forward = fl and fl.path or nil,
      }
    end

    -- Highlights for this row (byte positions via string.find)
    if bl then
      -- Only highlight the name if the target file exists on disk
      -- Use bl_display (the possibly-truncated text actually in the line)
      if bl.path then
        hl_find(row, line_str, bl_display, "VaultGraphExistingLink")
      end
      hl_find(row, line_str, connector_in, "VaultGraphConnector")
    else
      hl_find(row, line_str, divider_char, "VaultGraphDivider")
    end

    if fl then
      hl_find(row, line_str, connector_out, "VaultGraphConnector")
      -- Only highlight the name if the target file exists on disk
      -- Use fl_display (the possibly-truncated text actually in the line)
      if fl.path then
        hl_find(row, line_str, fl_display, "VaultGraphExistingLink", #left_part)
      end
    end
  end

  -- If no links at all, show a message
  if max_rows == 0 then
    local msg = "(no connections)"
    local pad = math.max(0, math.floor((total_width - #msg) / 2))
    local msg_line = string.rep(" ", pad) .. msg
    lines[#lines + 1] = msg_line
    add_hl(#lines - 1, pad, pad + #msg, "VaultGraphCount")
  end

  -- Empty line with divider
  lines[#lines + 1] = empty_div
  add_hl(#lines - 1, half, half + #divider_char, "VaultGraphDivider")

  -- Bottom border
  lines[#lines + 1] = border_line
  add_hl(#lines - 1, 0, #border_line, "VaultGraphDivider")

  -- Summary line
  local summary = string.format(
    "  %d backlink%s",
    #backlinks,
    #backlinks == 1 and "" or "s"
  )
  local summary_right = string.format(
    "%d forward link%s",
    #forward_links,
    #forward_links == 1 and "" or "s"
  )
  local summary_line = summary
    .. string.rep(" ", math.max(1, half - #summary))
    .. divider_char
    .. "  "
    .. summary_right
  lines[#lines + 1] = summary_line
  add_hl(#lines - 1, 0, #summary_line, "VaultGraphCount")

  return lines, highlights, line_to_note
end

-- ---------------------------------------------------------------------------
-- Public: local_graph()
-- ---------------------------------------------------------------------------

function M.local_graph()
  local note_name = engine.current_note_name()
  if not note_name then
    vim.notify("Vault: buffer has no filename", vim.log.levels.WARN)
    return
  end

  -- Check that we are inside the vault
  local buf_path = vim.api.nvim_buf_get_name(0)
  if not engine.is_vault_path(buf_path) then
    vim.notify("Vault: current file is not in the vault", vim.log.levels.WARN)
    return
  end

  define_highlights()

  local forward_links = collect_forward_links()
  local backlinks = collect_backlinks(note_name)

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
  backlinks = filter_self(backlinks)

  -- Disambiguate entries that share the same display name
  disambiguate_names(forward_links)
  disambiguate_names(backlinks)

  -- Compute window dimensions
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local total_width = math.floor(ui.width * 0.8)
  local link_count = math.max(#backlinks, #forward_links)
  -- lines: border + header + empty + link_rows + empty + border + summary = link_count + 6
  local content_height = link_count + 6
  if link_count == 0 then
    content_height = 7 -- includes the "(no connections)" line
  end
  local max_height = math.floor(ui.height * 0.6)
  local win_height = math.min(content_height, max_height)

  -- Render
  local rendered_lines, highlights, line_to_note = render_graph(note_name, backlinks, forward_links, total_width)

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered_lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("vault_graph")
  for _, hl in ipairs(highlights) do
    local row, col_start, col_end, group = hl[1], hl[2], hl[3], hl[4]
    if row < #rendered_lines then
      pcall(vim.api.nvim_buf_add_highlight, buf, ns, group, row, col_start, col_end)
    end
  end

  -- Open floating window
  local row = math.floor((ui.height - win_height) / 2)
  local col = math.floor((ui.width - total_width) / 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = total_width,
    height = win_height,
    style = "minimal",
    border = "rounded",
    title = " Local Graph: " .. note_name .. " ",
    title_pos = "center",
  })

  -- Window options
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  -- Store context for keymaps
  local graph_ctx = {
    win = win,
    buf = buf,
    total_width = total_width,
    line_to_note = line_to_note,
  }

  -- Helper: close the graph window
  local function close_graph()
    if vim.api.nvim_win_is_valid(graph_ctx.win) then
      vim.api.nvim_win_close(graph_ctx.win, true)
    end
  end

  -- Helper: navigate to a note by absolute path
  local function navigate_to(path)
    if not path or path == "" then
      vim.notify("Vault: no link on this line", vim.log.levels.INFO)
      return
    end
    close_graph()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end

  -- Keymaps --

  -- q / Esc: close
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close_graph, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "Close graph",
    })
  end

  -- Helper: resolve navigation target from cursor position using stored paths
  local function target_from_cursor()
    local cursor = vim.api.nvim_win_get_cursor(graph_ctx.win)
    local entry = graph_ctx.line_to_note[cursor[1]]
    if not entry then
      return nil
    end
    local half = math.floor(graph_ctx.total_width / 2)
    if entry.backlink and entry.forward then
      -- Convert byte offset to display column for correct comparison
      -- (box-drawing chars are multi-byte but single display column)
      local line_text = vim.api.nvim_buf_get_lines(graph_ctx.buf, cursor[1] - 1, cursor[1], false)[1]
      local col_display = vim.fn.strdisplaywidth(line_text:sub(1, cursor[2]))
      return col_display < half and entry.backlink or entry.forward
    end
    return entry.backlink or entry.forward
  end

  -- <CR>: navigate to the note on the current line
  vim.keymap.set("n", "<CR>", function()
    navigate_to(target_from_cursor())
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Follow graph link",
  })

  -- gf: same as <CR>
  vim.keymap.set("n", "gf", function()
    navigate_to(target_from_cursor())
  end, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "Follow graph link",
  })
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  vim.api.nvim_create_user_command("VaultGraph", function()
    M.local_graph()
  end, { desc = "Vault: local graph view" })

  local group = vim.api.nvim_create_augroup("VaultGraph", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vG", function()
        M.local_graph()
      end, { buffer = ev.buf, desc = "Vault: local graph", silent = true })
    end,
  })
end

return M
