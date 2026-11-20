-- copy-mode.lua - the Neovim half of kitty's copy mode. Sourced by copy-mode.sh,
-- which kitty launches in an overlay over the window being copied from.
--
-- kitty hands over a snapshot of that window: its scrollback and screen, one
-- screen row at a time, with the escape sequences for the colours it was
-- drawn in. Every row becomes one line of a read-only buffer, its escape
-- sequences removed. A row's colours are worked out from those sequences only
-- when the row is drawn, so opening costs one pass over the snapshot that
-- does no more than cut it into lines. The overlay opens on the rows the
-- window was showing, cursor where the terminal's cursor was, with hybrid
-- line numbers in the gutter. Nothing is ever sent back to the window.
--
-- The user's whole Neovim config is loaded, so motions, search, text objects
-- and plugins are the usual ones. Differences from an ordinary buffer:
--   * `q` or `<Esc>` in Normal mode leaves copy mode.
--   * A yank that reaches the system clipboard leaves copy mode (tmux's
--     copy-selection-and-cancel). `"ay` and friends stay.
--   * A yank across rows kitty soft-wrapped yields the unwrapped text, as it
--     would in tmux. The rows themselves stay split: `$`, `w` and `/` see
--     screen rows, not logical lines.
--   * `[[` and `]]` jump between shell prompts (the OSC 133 marks kitty keeps
--     in the snapshot).
--
-- Inputs, both set up by copy-mode.sh / kitty's `launch`:
--   fd 3              the snapshot, as kitty writes it for
--                     --stdin-add-formatting --stdin-add-line-wrap-markers.
--                     Every row ends in "\r"; a "\n" follows unless the row
--                     soft-wraps into the next. Each row starts with SGR
--                     reset, so its colours depend on nothing before it; a
--                     hyperlink (OSC 8) left open runs on into the next row.
--   $KITTY_PIPE_DATA  "{scrolled_by}:{cursor_x},{cursor_y}:{lines},{columns}",
--                     cursor 1-based, of the window at the time of the snapshot.

local SNAPSHOT_FD = 3

local api = vim.api
local lpeg = vim.lpeg
local P, R, Cg, Cp, Cs, Ct = lpeg.P, lpeg.R, lpeg.Cg, lpeg.Cp, lpeg.Cs, lpeg.Ct

local ESC = P("\27")
local ST = P("\7") + ESC * "\\"
local TEXT = (1 - ESC) ^ 1

--- An escape sequence in a row: CSI (SGR) or OSC (hyperlink, prompt mark).
---@param capture fun(pattern: vim.lpeg.Pattern, name: string): vim.lpeg.Pattern what to keep of its parts
---@return vim.lpeg.Pattern
local function sequence(capture)
  local csi = ESC * "[" * capture(R("0?") ^ 0, "params") * R(" /") ^ 0 * capture(R("@~"), "final")
  local osc = ESC * "]" * capture((1 - ST) ^ 0, "osc") * ST
  return csi + osc
end

-- A row without its escape sequences: the text of its buffer line.
local strip = Cs((TEXT + sequence(function(pattern)
  return pattern
end) / "" + 1) ^ 0)

-- A row's escape sequences as { start, stop, params, final } (CSI) or
-- { start, stop, osc }, where [start, stop) are the bytes of the row it takes.
local sequences = Ct((TEXT + Ct(Cg(Cp(), "start") * sequence(Cg) * Cg(Cp(), "stop")) + 1) ^ 0)

---@class copy_mode.Snapshot
---@field rows string[] the rows, oldest first, escape sequences included
---@field wrapped table<integer, true> rows that soft-wrap into the next
---@field open_link table<integer, string> rows that start inside a hyperlink, and its target

---@return copy_mode.Snapshot
local function read_snapshot()
  local file = assert(io.open("/dev/fd/" .. SNAPSHOT_FD, "rb"), "copy-mode: no snapshot on fd 3; run via copy-mode.sh")
  local data = file:read("*a")
  file:close()

  local rows, wrapped, open_link = {}, {}, {}
  local count, from, link = 0, 1, nil
  while from <= #data do
    local cr = data:find("\r", from, true)
    local row = data:sub(from, (cr or #data + 1) - 1)
    count = count + 1
    rows[count] = row
    open_link[count] = link
    if row:find("\27]8;", 1, true) then
      -- The last OSC 8 of the row: its target, empty when it closes a link.
      local target = row:match(".*\27%]8;[^;]*;([^\27\7]*)")
      link = target ~= "" and target or nil
    end

    if not cr then
      break
    elseif data:byte(cr + 1) == 10 then
      from = cr + 2
    else
      -- kitty ends the last row with the bare "\r" too; nothing follows it.
      wrapped[count] = cr < #data or nil
      from = cr + 1
    end
  end
  return { rows = rows, wrapped = wrapped, open_link = open_link }
end

--- Put the snapshot's text in the current buffer: one line per row.
---@param rows string[]
---@return integer buf
local function show(rows)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_get_current_buf()

  local text = {}
  for index = 1, #rows do
    text[index] = strip:match(rows[index])
  end

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  api.nvim_buf_set_name(buf, "[Copy mode]")
  -- kitty keeps a tab as a tab; it stood for the cells up to the next multiple of 8.
  vim.bo[buf].tabstop = 8

  -- The gutter is line numbers and nothing else: its columns come out of the row's.
  vim.wo[win].number = true
  vim.wo[win].relativenumber = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].wrap = false
  vim.wo[win].list = false
  return buf
end

-- xterm's colours 0-15, for those the colorscheme leaves out of g:terminal_color_N.
local ANSI_COLOURS = {
  0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
  0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
}

--- A colour of the 256-colour palette. 0-15 are Neovim's terminal colours, not
--- kitty's theme; the rest are the values kitty uses unless configured otherwise.
---@param index integer 0-255
---@return integer|string colour as nvim_set_hl() takes it
local function palette(index)
  if index < 16 then
    return vim.g["terminal_color_" .. index] or ANSI_COLOURS[index + 1]
  elseif index < 232 then
    local function level(step)
      return step == 0 and 0 or 55 + 40 * step
    end
    index = index - 16
    return level(math.floor(index / 36)) * 0x10000 + level(math.floor(index / 6) % 6) * 0x100 + level(index % 6)
  end
  return (8 + 10 * (index - 232)) * 0x010101
end

--- The colour of an SGR 38, 48 or 58, in kitty's spelling: ":5:n" or ":2:r:g:b".
---@param spec string the parameter after its code
---@return integer|string|nil
local function extended_colour(spec)
  local index = spec:match("^:5:(%d+)$")
  if index then
    return palette(tonumber(index))
  end
  local red, green, blue = spec:match("^:2:(%d+):(%d+):(%d+)$")
  if red then
    return tonumber(red) * 0x10000 + tonumber(green) * 0x100 + tonumber(blue)
  end
end

-- SGR 4:1 to 4:5, as nvim_set_hl() names them.
local UNDERLINES = { "underline", "underdouble", "undercurl", "underdotted", "underdashed" }

--- Apply an SGR sequence to the attributes in force.
---@param attrs vim.api.keyset.highlight changed in place
---@param params string the sequence's parameters, e.g. "22;1;38:2:255:128:0"
local function apply_sgr(attrs, params)
  for code, sub in (params == "" and "0" or params):gmatch("(%d+)([%d:]*)") do
    code = tonumber(code)
    if code == 0 then
      for field in pairs(attrs) do
        attrs[field] = nil
      end
    elseif code == 1 then
      attrs.bold = true
    elseif code == 2 then
      attrs.dim = true
    elseif code == 22 then
      attrs.bold, attrs.dim = nil, nil
    elseif code == 3 or code == 23 then
      attrs.italic = code == 3 or nil
    elseif code == 4 or code == 24 then
      for _, style in ipairs(UNDERLINES) do
        attrs[style] = nil
      end
      -- A bare 4 is a straight underline; 4:0 is none.
      local style = code == 4 and UNDERLINES[tonumber(sub:sub(2)) or 1]
      if style then
        attrs[style] = true
      end
    elseif code == 7 or code == 27 then
      attrs.reverse = code == 7 or nil
    elseif code == 9 or code == 29 then
      attrs.strikethrough = code == 9 or nil
    elseif code >= 30 and code <= 37 then
      attrs.fg = palette(code - 30)
    elseif code == 38 then
      attrs.fg = extended_colour(sub)
    elseif code == 39 then
      attrs.fg = nil
    elseif code >= 40 and code <= 47 then
      attrs.bg = palette(code - 40)
    elseif code == 48 then
      attrs.bg = extended_colour(sub)
    elseif code == 49 then
      attrs.bg = nil
    elseif code == 58 then
      attrs.sp = extended_colour(sub)
    elseif code == 59 then
      attrs.sp = nil
    elseif code >= 90 and code <= 97 then
      attrs.fg = palette(code - 90 + 8)
    elseif code >= 100 and code <= 107 then
      attrs.bg = palette(code - 100 + 8)
    end
  end
end

local ATTRIBUTES = vim.list_extend({ "fg", "bg", "sp", "bold", "dim", "italic", "reverse", "strikethrough" }, UNDERLINES)

--- Colour the buffer's lines as their rows were, each when it is drawn.
---@param buf integer
---@param snapshot copy_mode.Snapshot
local function colour(buf, snapshot)
  -- Highlight groups live in their own namespace, where `:colorscheme` does
  -- not clear them.
  local namespace = api.nvim_create_namespace("kitty.copy-mode")
  api.nvim_set_hl_ns(namespace)

  local groups = {} ---@type table<string, string> attributes -> highlight group
  local group_count = 0

  ---@param attrs vim.api.keyset.highlight
  ---@return string? group none for text in the default colours
  local function group_for(attrs)
    if next(attrs) == nil then
      return nil
    end
    local key = {}
    for index, attribute in ipairs(ATTRIBUTES) do
      key[index] = tostring(attrs[attribute] or "")
    end
    local id = table.concat(key, ",")
    if not groups[id] then
      group_count = group_count + 1
      groups[id] = "KittyCopyMode" .. group_count
      api.nvim_set_hl(namespace, groups[id], attrs)
    end
    return groups[id]
  end

  ---@alias copy_mode.Span { [1]: integer, [2]: integer, [3]: string?, [4]: string? } byte columns [from, to), highlight group, hyperlink
  local spans = {} ---@type table<integer, copy_mode.Span[]> by row, once drawn

  ---@param row integer
  ---@return copy_mode.Span[]
  local function spans_of(row)
    if spans[row] then
      return spans[row]
    end
    local raw = snapshot.rows[row]
    local found = {} ---@type copy_mode.Span[]
    local attrs = {} ---@type vim.api.keyset.highlight
    local group, link = nil, snapshot.open_link[row]
    local from, removed = 0, 0 -- start of the run of text being read; bytes of escape sequences before it

    local function close(to)
      if (group or link) and to > from then
        found[#found + 1] = { from, to, group, link }
      end
      from = to
    end

    for _, seq in ipairs(sequences:match(raw)) do
      close(seq.start - 1 - removed)
      removed = removed + seq.stop - seq.start
      if seq.osc then
        local target = seq.osc:match("^8;[^;]*;(.*)$")
        if target then
          link = target ~= "" and target or nil
        end
      elseif seq.final == "m" then
        apply_sgr(attrs, seq.params)
        group = group_for(attrs)
      end
    end
    close(#raw - removed)

    spans[row] = found
    return found
  end

  api.nvim_set_decoration_provider(namespace, {
    on_win = function(_, _, drawn)
      return drawn == buf
    end,
    on_line = function(_, _, _, line)
      for _, span in ipairs(spans_of(line + 1)) do
        api.nvim_buf_set_extmark(buf, namespace, line, span[1], {
          end_col = span[2],
          hl_group = span[3],
          url = span[4],
          ephemeral = true,
        })
      end
    end,
  })
end

--- Show the rows the kitty window was showing, cursor on the terminal's cursor.
---@param row_count integer
local function restore_view(row_count)
  -- The tabline and the statusline (for the mode) stay, as in any Neovim.
  vim.o.cmdheight = 0

  local scrolled_by, cursor_x, cursor_y, lines = (vim.env.KITTY_PIPE_DATA or ""):match("^(%d+):(%d+),(%d+):(%d+),%d+$")
  if not scrolled_by then
    vim.cmd("normal! G")
    return
  end
  scrolled_by, cursor_x, cursor_y, lines = tonumber(scrolled_by), tonumber(cursor_x), tonumber(cursor_y), tonumber(lines)

  -- The screen is the last `lines` rows of the snapshot; kitty was scrolled
  -- `scrolled_by` rows up from there.
  local screen_top = math.max(row_count - lines + 1, 1)
  local kitty_top = math.max(screen_top - scrolled_by, 1)

  -- The bars cover screen rows rather than push them: the view starts as far
  -- down as the window does (below the tabline), so every row that still
  -- shows is on the screen line kitty had it on.
  local top = kitty_top + vim.fn.win_screenpos(0)[1] - 1
  local height = api.nvim_win_get_height(0)
  local cursor_row = screen_top + cursor_y - 1
  if cursor_row > kitty_top + lines - 1 then
    -- Scrolled back far enough that the cursor is off kitty's screen.
    cursor_row, cursor_x = math.min(top + height - 1, row_count), 1
  elseif cursor_row > top + height - 1 then
    -- On a row the statusline covers: move the view down to it.
    top = cursor_row - height + 1
  elseif cursor_row < top then
    -- On a row the tabline covers: move the view up to it.
    top = cursor_row
  end

  -- 'scrolloff' would scroll the view to keep context around the cursor.
  vim.wo.scrolloff = 0
  vim.wo.sidescrolloff = 0
  api.nvim_win_set_cursor(0, { cursor_row, 0 })
  vim.cmd("normal! " .. cursor_x .. "|")
  vim.fn.winrestview({ topline = top, leftcol = 0 })
end

--- Buffer-local behaviour of copy mode.
---@param buf integer
---@param snapshot copy_mode.Snapshot
local function attach(buf, snapshot)
  local function leave()
    vim.cmd("qall!")
  end

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, leave, { buffer = buf, nowait = true, desc = "Leave copy mode" })
  end

  local prompts ---@type integer[]? rows a shell prompt starts on, once asked for

  --- Move to the [count]th prompt above or below the cursor, or as far that
  --- way as there are prompts.
  ---@param step -1|1
  local function jump_to_prompt(step)
    if not prompts then
      prompts = {}
      for row, raw in ipairs(snapshot.rows) do
        if raw:find("\27]133;A", 1, true) then
          prompts[#prompts + 1] = row
        end
      end
    end

    local here = api.nvim_win_get_cursor(0)[1]
    local left, target = vim.v.count1, nil
    for index = step > 0 and 1 or #prompts, step > 0 and #prompts or 1, step do
      if left > 0 and (prompts[index] - here) * step > 0 then
        target = prompts[index]
        left = left - 1
      end
    end
    if target then
      api.nvim_win_set_cursor(0, { target, 0 })
    end
  end

  vim.keymap.set({ "n", "x", "o" }, "[[", function()
    jump_to_prompt(-1)
  end, { buffer = buf, desc = "Jump [count] shell prompts backward" })
  vim.keymap.set({ "n", "x", "o" }, "]]", function()
    jump_to_prompt(1)
  end, { buffer = buf, desc = "Jump [count] shell prompts forward" })

  -- The view was restored with 'scrolloff' off. Hand it back to the user's
  -- setting as soon as they move.
  local start = api.nvim_win_get_cursor(0)
  local scrolloff_autocmd
  scrolloff_autocmd = api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local cursor = api.nvim_win_get_cursor(0)
      if cursor[1] == start[1] and cursor[2] == start[2] then
        return
      end
      vim.wo.scrolloff = -1
      vim.wo.sidescrolloff = -1
      api.nvim_del_autocmd(scrolloff_autocmd)
    end,
  })

  api.nvim_create_autocmd("TextYankPost", {
    buffer = buf,
    callback = function()
      local event = vim.v.event
      if event.operator ~= "y" then
        return
      end

      -- Where a yank without a register name goes ('clipboard').
      local register = event.regname
      if register == "" then
        local clipboard = vim.opt.clipboard:get()
        register = vim.tbl_contains(clipboard, "unnamedplus") and "+"
          or vim.tbl_contains(clipboard, "unnamed") and "*"
          or '"'
      end

      -- Undo kitty's soft wraps. Every yanked row but the last runs to the
      -- end of its buffer line; where that row wraps into the next, drop the
      -- line break.
      if event.regtype == "v" or event.regtype == "V" then
        local first_row = vim.fn.line("'[")
        local unwrapped, pending = {}, nil
        for index, text in ipairs(event.regcontents) do
          text = (pending or "") .. text
          if snapshot.wrapped[first_row + index - 1] and index < #event.regcontents then
            pending = text
          else
            unwrapped[#unwrapped + 1] = text
            pending = nil
          end
        end
        if #unwrapped < #event.regcontents then
          vim.fn.setreg(register, unwrapped, event.regtype)
        end
      end

      if register == "+" or register == "*" then
        vim.schedule(leave)
      end
    end,
  })
end

local snapshot = read_snapshot()
local buf = show(snapshot.rows)
colour(buf, snapshot)
restore_view(#snapshot.rows)
attach(buf, snapshot)
