# Feature 10: `ui.create_float_input()` / `ui.create_float_display()`

## Dependencies
- **None** — standalone UI utility.
- **Depended on by:** Nothing directly

## Problem

### 10a: Input floats — near-identical in capture.lua and quicktask.lua
- `capture.lua:8-77` (`open_capture_window`) — 60x3 float, enter to submit, q/Esc to cancel, BufLeave autocmd
- `quicktask.lua:60-114` (`M.quick_task` inline) — 60x1 float, same key structure

Both share ~90% identical code:
- UI size query + centering math
- Buffer creation with `bufhidden = "wipe"`
- `nvim_open_win` with identical options (relative, style, border, title, title_pos)
- `vim.cmd("startinsert")`
- `closed` guard boolean
- Close function with `nvim_win_is_valid` + `nvim_win_close`
- `<CR>` keymap for submit
- `q` and `<Esc>` keymaps for cancel
- `BufLeave` autocmd for auto-cancel

Minor differences: height (3 vs 1), filetype setting, submit modes (n vs {n,i}), `stopinsert` call.

### 10b: Display floats — near-identical in graph.lua and calendar.lua
- `graph.lua:420-469` — scratch buffer, centered float, `bufhidden=wipe/buftype=nofile/swapfile=false`, `style=minimal/border=rounded`, q/Esc close keymaps
- `calendar.lua:457-488` — identical pattern

Both share ~80% identical code for creating read-only floating windows.

## Files to Modify
1. **CREATE** `lua/andrew/vault/ui.lua` — New shared UI utility module
2. `lua/andrew/vault/capture.lua` — Replace `open_capture_window` with `ui.create_float_input`
3. `lua/andrew/vault/quicktask.lua` — Replace inline float creation with `ui.create_float_input`
4. `lua/andrew/vault/graph.lua` — Replace inline float creation with `ui.create_float_display`
5. `lua/andrew/vault/calendar.lua` — Replace inline float creation with `ui.create_float_display`

## Implementation Steps

### Step 1: Create `lua/andrew/vault/ui.lua`

```lua
local M = {}

--- Create a centered floating input window.
--- @param opts { title: string, width?: number, height?: number, filetype?: string, on_submit: fun(lines: string[]), submit_modes?: string[] }
--- @return { buf: number, win: number, close: fun() }
function M.create_float_input(opts)
  local width = opts.width or 60
  local height = opts.height or 1
  local ui = vim.api.nvim_list_uis()[1]
  local col = math.floor((ui.width - width) / 2)
  local row = math.floor((ui.height - height) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
  })

  vim.cmd("startinsert")

  local closed = false
  local function close(submit)
    if closed then return end
    closed = true
    if submit and opts.on_submit then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      opts.on_submit(lines)
    end
    vim.cmd("stopinsert")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local submit_modes = opts.submit_modes or { "n" }
  vim.keymap.set(submit_modes, "<CR>", function() close(true) end, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", function() close(false) end, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", function() close(false) end, { buffer = buf, silent = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function() close(false) end,
  })

  return { buf = buf, win = win, close = close }
end

--- Create a centered floating display window (read-only).
--- @param opts { title: string, lines: string[], width?: number, height?: number, enter?: boolean, cursor_line?: boolean }
--- @return { buf: number, win: number, close: fun() }
function M.create_float_display(opts)
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local width = opts.width or math.floor(ui.width * 0.8)
  local height = opts.height or math.min(#opts.lines + 2, math.floor(ui.height * 0.8))
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false

  local enter = opts.enter ~= false -- default true
  local win = vim.api.nvim_open_win(buf, enter, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
  })

  if opts.cursor_line ~= nil then
    vim.wo[win].cursorline = opts.cursor_line
  end
  vim.wo[win].wrap = false

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
  end

  return { buf = buf, win = win, close = close }
end

return M
```

### Step 2: Update capture.lua

Delete `open_capture_window` (lines 8-77). Replace with:

```lua
local ui = require("andrew.vault.ui")

-- In M.capture():
local float = ui.create_float_input({
  title = "Quick Capture",
  width = 60,
  height = 3,
  filetype = "markdown",
  on_submit = function(lines)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then return end
    -- existing append logic...
  end,
})
```

### Step 3: Update quicktask.lua

Delete inline float creation (lines 60-114). Replace with:

```lua
local ui = require("andrew.vault.ui")

function M.quick_task()
  ui.create_float_input({
    title = "Quick Task",
    width = 60,
    height = 1,
    submit_modes = { "n", "i" },
    on_submit = function(lines)
      local title = vim.trim(lines[1] or "")
      if title == "" then return end
      -- existing build_note and write logic...
    end,
  })
end
```

### Step 4: Update graph.lua

Delete inline float creation (lines ~420-510). Replace with:

```lua
local ui = require("andrew.vault.ui")

local float = ui.create_float_display({
  title = "Graph: " .. note_name,
  lines = rendered_lines,
  cursor_line = true,
})

-- Add graph-specific keymaps on float.buf after creation:
vim.keymap.set("n", "<CR>", function()
  -- navigate to link under cursor
end, { buffer = float.buf, silent = true })
```

### Step 5: Update calendar.lua

Delete inline float creation (lines ~457-530). Replace with:

```lua
local ui = require("andrew.vault.ui")

local float = ui.create_float_display({
  title = "Calendar",
  lines = calendar_lines,
  width = 34,
  height = 16,
  cursor_line = false,
})
state.buf = float.buf
state.win = float.win

-- Add calendar-specific keymaps and settings on float.buf/float.win...
vim.wo[float.win].number = false
vim.wo[float.win].relativenumber = false
vim.wo[float.win].signcolumn = "no"
```

## Testing
- `VaultCapture` — enter text, press Enter → appends to daily log
- `VaultCapture` — press Esc → cancels without appending
- `VaultQuickTask` — enter title, press Enter (in insert mode) → creates task note
- `VaultGraph` — opens centered float, q closes, Enter navigates
- `VaultCalendar` — opens centered float, navigation keys work, q closes
- Edge case: resize terminal then open a float — verify centering

## Estimated Impact
- **Lines removed:** ~125
- **Lines added:** ~80
- **Net reduction:** ~45 lines
- **Benefit:** Future floats (if any) get the same consistent behavior for free
