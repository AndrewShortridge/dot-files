-- copy-mode.lua - the Neovim half of kitty's copy mode. Sourced by copy-mode.sh,
-- which kitty launches in an overlay over the window being copied from.
--
-- kitty hands over a snapshot of that window: its scrollback and screen, one
-- screen row at a time, with the SGR colours it was drawn in. The snapshot is
-- fed to a terminal buffer, so Neovim's own terminal emulator renders it and
-- every screen row becomes one buffer line. The overlay then opens on the
-- rows the window was showing, cursor where the terminal's cursor was, with
-- hybrid line numbers in the gutter. Nothing is ever sent back to the window.
--
-- The user's whole Neovim config is loaded, so motions, search, text objects
-- and plugins are the usual ones. Differences from an ordinary buffer:
--   * `q` or `<Esc>` in Normal mode leaves copy mode.
--   * A yank that reaches the system clipboard leaves copy mode (tmux's
--     copy-selection-and-cancel). `"ay` and friends stay.
--   * A yank across rows kitty soft-wrapped yields the unwrapped text, as it
--     would in tmux. The rows themselves stay split: `$`, `w` and `/` see
--     screen rows, not logical lines.
--   * `[[` and `]]` jump between shell prompts (Neovim's terminal reads the
--     OSC 133 marks kitty keeps in the snapshot).
--
-- Inputs, both set up by copy-mode.sh / kitty's `launch`:
--   fd 3              the snapshot. Rows end in "\r\n"; a row that soft-wraps
--                     into the next ends in a bare "\r"
--                     (--stdin-add-line-wrap-markers).
--   $KITTY_PIPE_DATA  "{scrolled_by}:{cursor_x},{cursor_y}:{lines},{columns}",
--                     cursor 1-based, of the window at the time of the snapshot.

local SNAPSHOT_FD = 3

-- 'scrollback' cannot go higher, so a terminal buffer holds at most this many
-- rows above its screen. A longer snapshot loses its oldest rows.
local MAX_SCROLLBACK = 1000000

---@param row string a snapshot row, escape sequences included
---@return string text the characters the row shows
local function strip_escapes(row)
  local text = row
    :gsub("\27%][^\7\27]*\7", "") -- OSC ... BEL
    :gsub("\27%].-\27\\", "") -- OSC ... ST (hyperlinks, prompt marks)
    :gsub("\27%[[0-?]*[ -/]*[@-~]", "") -- CSI (SGR)
  return text
end

---@return string[] rows snapshot rows, oldest first, escape sequences included
---@return table<integer, true> wrapped indexes of rows that soft-wrap into the next
local function read_snapshot()
  local file = assert(io.open("/dev/fd/" .. SNAPSHOT_FD, "rb"), "copy-mode: no snapshot on fd 3; run via copy-mode.sh")
  local data = file:read("*a")
  file:close()

  local rows, wrapped = {}, {}
  for row, terminator in data:gmatch("([^\r\n]*)(\r?\n?)") do
    if row == "" and terminator == "" then
      break -- end of data: gmatch yields one empty match there
    end
    rows[#rows + 1] = row
    if terminator == "\r" then
      wrapped[#rows] = true
    end
  end
  -- kitty ends the last row with the bare "\r" too; nothing follows it.
  wrapped[#rows] = nil

  local excess = #rows - MAX_SCROLLBACK
  if excess > 0 then
    rows = vim.list_slice(rows, excess + 1)
    local kept = {}
    for index in pairs(wrapped) do
      if index > excess then
        kept[index - excess] = true
      end
    end
    wrapped = kept
  end
  return rows, wrapped
end

--- Turn the current (empty) buffer into a terminal showing `rows`, then close
--- the terminal's channel.
---
--- A terminal is as wide as its window's text area and re-wraps its screen
--- whenever that width changes -- which the number gutter would do. A closed
--- terminal no longer resizes, so the gutter is switched on only afterwards.
---@param rows string[]
---@return integer buf
local function render(rows)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()

  -- No gutter while the terminal sizes itself: it must be as wide as the
  -- window kitty took the rows from, or full-width rows would wrap.
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""

  -- Room for every row. Has to be set before the terminal exists: a terminal
  -- picks up a new 'scrollback' only at its next redraw, and rows fed before
  -- that fall off the default 10000.
  vim.bo[buf].scrollback = math.max(#rows, 1)
  local channel = vim.api.nvim_open_term(buf, {})
  -- Autowrap off (DECAWM): should Neovim measure a character wider than kitty
  -- did, the row loses its last cell instead of spilling into a row of its
  -- own, which would shift every row after it.
  vim.api.nvim_chan_send(channel, "\27[?7l" .. table.concat(rows, "\r\n"))

  -- The terminal writes its rows into the buffer from a timer. Wait until the
  -- last row with any text has arrived, then freeze.
  local last_text_row
  for index = #rows, 1, -1 do
    if strip_escapes(rows[index]):find("%S") then
      last_text_row = index
      break
    end
  end
  vim.wait(10000, function()
    return vim.api.nvim_buf_line_count(buf) >= #rows
      and (not last_text_row or vim.api.nvim_buf_get_lines(buf, last_text_row - 1, last_text_row, false)[1] ~= "")
  end, 5)

  local closed = false
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function()
      closed = true
    end,
  })
  vim.fn.chanclose(channel)
  vim.wait(1000, function()
    return closed
  end, 5)
  -- Neovim's "[Terminal closed]" notice, and the line it adds to hold the
  -- notice when the last row has text.
  vim.api.nvim_buf_clear_namespace(buf, vim.api.nvim_create_namespace("nvim.terminal.exitmsg"), 0, -1)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, #rows, -1, false, {})
  vim.bo[buf].modifiable = false

  vim.wo[win].number = true
  vim.wo[win].relativenumber = true
  vim.wo[win].wrap = false
  return buf
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
  local height = vim.api.nvim_win_get_height(0)
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
  vim.api.nvim_win_set_cursor(0, { cursor_row, 0 })
  vim.cmd("normal! " .. cursor_x .. "|")
  vim.fn.winrestview({ topline = top, leftcol = 0 })
end

--- Buffer-local behaviour of copy mode.
---@param buf integer
---@param rows string[]
---@param wrapped table<integer, true>
local function attach(buf, rows, wrapped)
  local function leave()
    vim.cmd("qall!")
  end

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, leave, { buffer = buf, nowait = true, desc = "Leave copy mode" })
  end

  -- Terminal mode has no use here, and on a closed terminal the next keypress
  -- in it wipes the buffer. The keys that enter it do nothing; anything else
  -- that gets there (:startinsert) is sent straight back, though the cursor
  -- has by then jumped to the terminal's own.
  for _, key in ipairs({ "i", "I", "a", "A" }) do
    vim.keymap.set("n", key, "<Nop>", { buffer = buf, desc = "Copy mode is read-only" })
  end
  vim.api.nvim_create_autocmd("TermEnter", {
    buffer = buf,
    command = "stopinsert",
  })

  -- The view was restored with 'scrolloff' off. Hand it back to the user's
  -- setting as soon as they move.
  local start = vim.api.nvim_win_get_cursor(0)
  local scrolloff_autocmd
  scrolloff_autocmd = vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      if cursor[1] == start[1] and cursor[2] == start[2] then
        return
      end
      vim.wo.scrolloff = -1
      vim.wo.sidescrolloff = -1
      vim.api.nvim_del_autocmd(scrolloff_autocmd)
    end,
  })

  vim.api.nvim_create_autocmd("TextYankPost", {
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
      -- line break. The terminal buffer has trimmed the row's trailing
      -- blanks, so those come back from the snapshot.
      if event.regtype == "v" or event.regtype == "V" then
        local first_row = vim.fn.line("'[")
        local unwrapped, pending = {}, nil
        local changed = false
        for index, text in ipairs(event.regcontents) do
          local row = first_row + index - 1
          if pending then
            text = pending .. text
            pending = nil
          end
          if wrapped[row] and index < #event.regcontents then
            local full = strip_escapes(rows[row])
            local shown = vim.fn.getline(row)
            if vim.startswith(full, shown) then
              text = text .. full:sub(#shown + 1)
            end
            pending = text
            changed = true
          else
            unwrapped[#unwrapped + 1] = text
          end
        end
        if changed then
          vim.fn.setreg(register, unwrapped, event.regtype)
        end
      end

      if register == "+" or register == "*" then
        vim.schedule(leave)
      end
    end,
  })
end

local rows, wrapped = read_snapshot()
local buf = render(rows)
restore_view(#rows)
attach(buf, rows, wrapped)
